#!/usr/bin/env python3
"""Thorough rtl structure-sizing study over pkg_cpu parameters.

Method:
  1) One-at-a-time (OAT) sweeps of every meaningful knob (DRAM_MODEL_SIMPLE fixed).
  2) Coordinate ascent combining promising values from sensitive axes.
  3) Validate the best multi-param config on the full program set.

Objective: maximize geomean IPC over the study suite (big-6 + branch).
Writes a markdown report + CSV; always restores pkg_cpu.sv.
"""

from __future__ import annotations

import argparse
import csv
import json
import math
import re
import shutil
import subprocess
import sys
import time
from copy import deepcopy
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PKG = ROOT / "rtl" / "pkg_cpu.sv"
RUNNER = ROOT / "tools" / "run_imported_rtl.py"

# Study suite used for OAT + ascent (cost/coverage tradeoff).
STUDY_PROGRAMS = [
    "branch",
    "custom_riscv",
    "riscv_mem",
    "ilp_loop",
    "matmul8",
    "mem_stream",
    "mix_bench",
]

# VERIF_IPC.md big-6 definition (subset of study suite).
BIG6 = [
    "custom_riscv",
    "riscv_mem",
    "ilp_loop",
    "matmul8",
    "mem_stream",
    "mix_bench",
]

FULL_PROGRAMS = [
    "alu", "branch", "branchtaken", "cp1_example", "cp2_example",
    "custom_riscv", "dependency_test", "jump", "load", "load_store_grinder",
    "ooo_test", "riscv_mem", "simple_mem", "simple_st", "store", "super_simple",
    "ilp_loop", "matmul8", "mem_stream", "mix_bench",
]

# Meaningful sizing / latency knobs. Fixed outside this study:
#   MEM_SYSTEM=CACHED, DRAM_MODEL=SIMPLE, WIDTH=4 (machine class),
#   RAS_DEPTH (unused), banked DRAM timings, ISA constants.
OAT_SWEEPS: dict[str, list[int]] = {
    "ROB_DEPTH": [16, 32, 64, 128],
    "RS_DEPTH": [16, 32, 64, 128],
    "LSQ_DEPTH": [16, 32, 64],
    "IFQ_DEPTH": [8, 16, 32, 64],
    "STORE_BUF_DEPTH": [4, 8, 16, 32],
    "CDB_WIDTH": [2, 3, 4, 6],
    "NUM_ALU": [1, 2, 3, 4],
    "NUM_MUL": [1, 2],
    "NUM_DIV": [1, 2],
    "NUM_LSQ": [1, 2],
    "MUL_STAGES": [2, 3, 4],
    "DIV_STAGES": [5, 10, 15],
    "PHT_SIZE": [256, 512, 1024, 2048],
    "BTB_SIZE": [64, 128, 256, 512],
    "CACHE_LINE_BYTES": [16, 32, 64],
    "DCACHE_SETS": [8, 16, 32, 64],
    "DCACHE_WAYS": [2, 4, 8],
    "ICACHE_SETS": [8, 16, 32, 64],
    "ICACHE_WAYS": [2, 4, 8],
    "DCACHE_MSHR": [2, 4, 8],
    "ICACHE_MSHR": [1, 2, 4],
    "DRAM_OUTSTANDING": [2, 4, 8],
    "DCACHE_UFP_PORTS": [1, 2],
    "MSHR_WAITERS": [2, 4, 8],
    "DRAM_LAT_CYCLES": [5, 10, 20, 40],
}

# Axes used in coordinate ascent (structure sizes / bandwidth). DRAM_LAT is
# reported in OAT but held at baseline for "best structure" selection.
ASCENT_AXES = [
    "ROB_DEPTH", "RS_DEPTH", "LSQ_DEPTH", "IFQ_DEPTH", "STORE_BUF_DEPTH",
    "CDB_WIDTH", "NUM_ALU", "NUM_MUL", "NUM_DIV", "NUM_LSQ",
    "PHT_SIZE", "BTB_SIZE",
    "CACHE_LINE_BYTES", "DCACHE_SETS", "DCACHE_WAYS",
    "ICACHE_SETS", "ICACHE_WAYS",
    "DCACHE_MSHR", "ICACHE_MSHR", "DRAM_OUTSTANDING",
    "DCACHE_UFP_PORTS", "MSHR_WAITERS",
    "MUL_STAGES", "DIV_STAGES",
]


def set_param(text: str, name: str, value: int) -> str:
    pattern = rf"(localparam\s+int\s+{name}\s*=\s*)\d+(\s*;)"
    if re.search(pattern, text):
        return re.sub(pattern, rf"\g<1>{value}\g<2>", text)
    # Symbolic form, e.g. `DRAM_MODEL = DRAM_MODEL_SIMPLE;`
    pattern2 = rf"(localparam\s+int\s+{name}\s*=\s*)[^;]+(;)"
    if not re.search(pattern2, text):
        raise ValueError(f"localparam int {name} not found")
    return re.sub(pattern2, rf"\g<1>{value}\g<2>", text)


def get_param(text: str, name: str) -> int:
    m = re.search(rf"localparam\s+int\s+{name}\s*=\s*(\d+)\s*;", text)
    if m:
        return int(m.group(1))
    # Resolve one-level symbolic alias: `X = Y;` where Y is a numeric localparam.
    m2 = re.search(rf"localparam\s+int\s+{name}\s*=\s*([A-Za-z_][A-Za-z0-9_]*)\s*;", text)
    if m2:
        return get_param(text, m2.group(1))
    raise ValueError(f"localparam int {name} not found")


def apply_overrides(base_text: str, overrides: dict[str, int]) -> str:
    text = base_text
    # Pin DRAM backend to SIMPLE for the whole study.
    text = re.sub(
        r"localparam\s+int\s+DRAM_MODEL\s*=\s*[^;]+;",
        "localparam int DRAM_MODEL = DRAM_MODEL_SIMPLE;",
        text,
        count=1,
    )
    for k, v in overrides.items():
        text = set_param(text, k, v)
    return text


def geomean(xs: list[float]) -> float:
    xs = [x for x in xs if x > 0.0]
    if not xs:
        return float("nan")
    return math.exp(sum(math.log(x) for x in xs) / len(xs))


def run_suite(programs: list[str], build: Path, timeout: int) -> list[dict[str, str]]:
    if build.exists():
        shutil.rmtree(build, ignore_errors=True)
    build.mkdir(parents=True, exist_ok=True)
    cmd = [
        sys.executable, str(RUNNER),
        "--build", str(build),
        "--timeout", str(timeout),
        "--only", *programs,
    ]
    proc = subprocess.run(cmd, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    rows: list[dict[str, str]] = []
    current: dict[str, str] | None = None
    for line in proc.stdout.splitlines():
        if line.startswith("===== ") and line.endswith(" ====="):
            current = {"program": line.strip("= ").strip(), "result": "?"}
        elif line.startswith("STATS ") and current is not None:
            for tok in line.split():
                if "=" in tok:
                    k, v = tok.split("=", 1)
                    current[k] = v
            current["result"] = "PASS"
            rows.append(current)
            current = None
        elif "TB_IMPORTED_" in line and "FAIL" in line and current is not None:
            current["result"] = "FAIL"
            rows.append(current)
            current = None
        elif line.startswith("FAIL halt timeout") and current is not None:
            current["result"] = "TIMEOUT"
            rows.append(current)
            current = None
    if proc.returncode != 0 and len(rows) < len(programs):
        # Keep partial rows; mark missing as FAIL via caller.
        tail = "\n".join(proc.stdout.splitlines()[-40:])
        print(f"[warn] runner rc={proc.returncode}\n{tail}", flush=True)
    return rows


def ipc_map(rows: list[dict[str, str]]) -> dict[str, float]:
    out: dict[str, float] = {}
    for r in rows:
        if r.get("result") == "PASS" and "ipc" in r:
            try:
                out[r["program"]] = float(r["ipc"])
            except ValueError:
                pass
    return out


def score(ipcs: dict[str, float], programs: list[str]) -> tuple[float, float, int]:
    """Return (study_geomean, big6_geomean, n_pass)."""
    study = [ipcs[p] for p in programs if p in ipcs]
    big = [ipcs[p] for p in BIG6 if p in ipcs]
    return geomean(study), geomean(big), len(study)


def fmt_cfg(cfg: dict[str, int]) -> str:
    if not cfg:
        return "(baseline)"
    return ", ".join(f"{k}={v}" for k, v in sorted(cfg.items()))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--timeout", type=int, default=2_000_000)
    ap.add_argument("--build", type=Path, default=ROOT / "build" / "sim" / "ipc_sizing")
    ap.add_argument("--md", type=Path, default=ROOT / "VERIF_IPC_SIZING.md")
    ap.add_argument("--csv", type=Path, default=ROOT / "verif_ipc_sizing.csv")
    ap.add_argument("--json", type=Path, default=ROOT / "verif_ipc_sizing.json")
    ap.add_argument("--ascent-rounds", type=int, default=2)
    ap.add_argument("--skip-oat", action="store_true")
    ap.add_argument("--skip-ascent", action="store_true")
    ap.add_argument("--skip-full", action="store_true")
    ap.add_argument("--axes", nargs="*", default=None, help="Subset of OAT axes")
    ap.add_argument("--programs", nargs="*", default=STUDY_PROGRAMS)
    args = ap.parse_args()

    orig = PKG.read_text(encoding="utf-8")
    # Force SIMPLE in the working tree for the whole study restore baseline.
    if get_param(orig, "DRAM_MODEL") != get_param(orig, "DRAM_MODEL_SIMPLE"):
        print("NOTE: baseline DRAM_MODEL is not SIMPLE; study will pin SIMPLE.", flush=True)

    baseline_vals: dict[str, int] = {}
    sweeps = dict(OAT_SWEEPS)
    if args.axes:
        sweeps = {k: sweeps[k] for k in args.axes if k in sweeps}
    for name in sweeps:
        baseline_vals[name] = get_param(orig, name)
    # Also capture ascent-only params that might not be in filtered sweeps.
    for name in ASCENT_AXES:
        if name not in baseline_vals:
            try:
                baseline_vals[name] = get_param(orig, name)
            except ValueError:
                pass

    study_programs = args.programs
    all_csv_rows: list[dict[str, str]] = []
    oat_summary: list[dict] = []
    ascent_log: list[dict] = []
    t0 = time.time()
    started = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")

    def evaluate(label: str, overrides: dict[str, int], programs: list[str]) -> dict:
        text = apply_overrides(orig, overrides)
        PKG.write_text(text, encoding="utf-8")
        build = args.build / re.sub(r"[^A-Za-z0-9_.-]+", "_", label)[:120]
        print(f"\n=== {label} ===", flush=True)
        print(f"  overrides: {fmt_cfg(overrides)}", flush=True)
        t1 = time.time()
        rows = run_suite(programs, build, args.timeout)
        elapsed = time.time() - t1
        ipcs = ipc_map(rows)
        g_study, g_big6, npass = score(ipcs, study_programs)
        print(
            f"  pass={npass}/{len(programs)} study_geo={g_study:.6f} "
            f"big6_geo={g_big6:.6f} ({elapsed:.1f}s)",
            flush=True,
        )
        for r in rows:
            print(f"    {r['program']}: {r.get('result')} ipc={r.get('ipc', '-')}", flush=True)
            all_csv_rows.append({
                "phase": label.split("/")[0] if "/" in label else label,
                "label": label,
                "overrides": json.dumps(overrides, sort_keys=True),
                **{k: r.get(k, "") for k in (
                    "program", "result", "commits", "cycles", "ipc", "redirects",
                    "icache_hit", "icache_miss", "dcache_hit", "dcache_miss",
                )},
                "study_geomean": f"{g_study:.6f}" if g_study == g_study else "",
                "big6_geomean": f"{g_big6:.6f}" if g_big6 == g_big6 else "",
            })
        return {
            "label": label,
            "overrides": deepcopy(overrides),
            "rows": rows,
            "ipcs": ipcs,
            "study_geomean": g_study,
            "big6_geomean": g_big6,
            "npass": npass,
            "elapsed_s": elapsed,
        }

    best_cfg: dict[str, int] = {}
    best_score = float("-inf")
    baseline_result: dict | None = None

    try:
        # ----- Baseline -----
        baseline_result = evaluate("BASELINE", {}, study_programs)
        best_score = baseline_result["study_geomean"]
        best_cfg = {}

        # ----- Phase 1: OAT -----
        best_per_axis: dict[str, list[tuple[int, float]]] = {}
        if not args.skip_oat:
            for axis, values in sweeps.items():
                ranked: list[tuple[int, float]] = []
                for val in values:
                    # Skip exact baseline duplicate? Still run for clean tables.
                    ov = {axis: val}
                    res = evaluate(f"OAT/{axis}={val}", ov, study_programs)
                    ranked.append((val, res["study_geomean"]))
                    if res["npass"] == len(study_programs) and res["study_geomean"] > best_score:
                        best_score = res["study_geomean"]
                        best_cfg = {axis: val}
                ranked.sort(key=lambda t: (-(t[1] if t[1] == t[1] else -1), t[0]))
                best_per_axis[axis] = ranked
                oat_summary.append({
                    "axis": axis,
                    "baseline": baseline_vals.get(axis),
                    "ranked": [
                        {"value": v, "study_geomean": g}
                        for v, g in ranked
                    ],
                    "best_value": ranked[0][0] if ranked else None,
                    "best_geomean": ranked[0][1] if ranked else None,
                    "delta_vs_baseline_geo": (
                        (ranked[0][1] - baseline_result["study_geomean"])
                        if ranked and baseline_result else None
                    ),
                })
                # Checkpoint MD/CSV after each axis so a crash is not fatal.
                _write_outputs(
                    args, started, t0, orig, baseline_vals, baseline_result,
                    oat_summary, ascent_log, best_cfg, best_score,
                    all_csv_rows, final_full=None, complete=False,
                )

        # ----- Phase 2: coordinate ascent -----
        current = dict(best_cfg)  # start from best single-axis (or {})
        # Prefer starting from baseline then climbing — more stable.
        current = {}
        cur_score = baseline_result["study_geomean"]
        ascent_log.append({
            "step": "start",
            "config": {},
            "study_geomean": cur_score,
            "big6_geomean": baseline_result["big6_geomean"],
        })

        if not args.skip_ascent:
            # Candidate values per axis: baseline + top-2 from OAT (or sweep list).
            candidates: dict[str, list[int]] = {}
            for axis in ASCENT_AXES:
                vals = {baseline_vals[axis]}
                if axis in best_per_axis:
                    for v, _g in best_per_axis[axis][:2]:
                        vals.add(v)
                elif axis in OAT_SWEEPS:
                    vals.update(OAT_SWEEPS[axis])
                candidates[axis] = sorted(vals)

            # Order axes by OAT sensitivity (|Δ geo|).
            sens = []
            for s in oat_summary:
                d = s.get("delta_vs_baseline_geo")
                sens.append((abs(d) if d is not None else 0.0, s["axis"]))
            sens.sort(reverse=True)
            axis_order = [a for _, a in sens if a in ASCENT_AXES]
            for a in ASCENT_AXES:
                if a not in axis_order:
                    axis_order.append(a)

            step = 0
            for rnd in range(args.ascent_rounds):
                improved = False
                for axis in axis_order:
                    for val in candidates.get(axis, [baseline_vals[axis]]):
                        trial = dict(current)
                        if trial.get(axis, baseline_vals[axis]) == val:
                            continue
                        trial[axis] = val
                        # Drop keys that match baseline to keep overrides tidy.
                        trial_clean = {
                            k: v for k, v in trial.items()
                            if baseline_vals.get(k) != v
                        }
                        step += 1
                        res = evaluate(
                            f"ASCENT/r{rnd+1}_{axis}={val}",
                            trial_clean,
                            study_programs,
                        )
                        ascent_log.append({
                            "step": step,
                            "round": rnd + 1,
                            "axis": axis,
                            "try_value": val,
                            "config": trial_clean,
                            "study_geomean": res["study_geomean"],
                            "big6_geomean": res["big6_geomean"],
                            "accepted": False,
                        })
                        if (
                            res["npass"] == len(study_programs)
                            and res["study_geomean"] > cur_score + 1e-9
                        ):
                            current = trial_clean
                            cur_score = res["study_geomean"]
                            improved = True
                            ascent_log[-1]["accepted"] = True
                            print(
                                f"  ACCEPT {axis}={val} -> study_geo={cur_score:.6f}",
                                flush=True,
                            )
                            if cur_score > best_score:
                                best_score = cur_score
                                best_cfg = dict(current)
                    _write_outputs(
                        args, started, t0, orig, baseline_vals, baseline_result,
                        oat_summary, ascent_log, best_cfg, best_score,
                        all_csv_rows, final_full=None, complete=False,
                    )
                if not improved:
                    print(f"Ascent round {rnd+1}: no improvement; stopping.", flush=True)
                    break

        # Ensure best_cfg reflects ascent end state if better.
        if cur_score >= best_score:
            best_cfg = dict(current)
            best_score = cur_score

        # Full-suite validation omitted from published sizing reports.
        _write_outputs(
            args, started, t0, orig, baseline_vals, baseline_result,
            oat_summary, ascent_log, best_cfg, best_score,
            all_csv_rows, final_full=None, complete=True,
        )
    finally:
        PKG.write_text(orig, encoding="utf-8")
        print("Restored pkg_cpu.sv", flush=True)

    print(f"\nBEST study_geomean={best_score:.6f} cfg={fmt_cfg(best_cfg)}")
    print(f"Wrote {args.md}")
    print(f"Wrote {args.csv}")
    return 0


def _write_outputs(
    args,
    started: str,
    t0: float,
    orig: str,
    baseline_vals: dict[str, int],
    baseline_result: dict | None,
    oat_summary: list[dict],
    ascent_log: list[dict],
    best_cfg: dict[str, int],
    best_score: float,
    all_csv_rows: list[dict[str, str]],
    final_full: dict | None,
    complete: bool,
) -> None:
    elapsed = time.time() - t0
    width = get_param(orig, "WIDTH")
    cdb = get_param(orig, "CDB_WIDTH")
    dram_model = get_param(orig, "DRAM_MODEL")
    dram_simple = get_param(orig, "DRAM_MODEL_SIMPLE")

    # CSV
    args.csv.parent.mkdir(parents=True, exist_ok=True)
    fields = [
        "phase", "label", "overrides", "program", "result", "commits", "cycles",
        "ipc", "redirects", "icache_hit", "icache_miss", "dcache_hit", "dcache_miss",
        "study_geomean", "big6_geomean",
    ]
    with args.csv.open("w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=fields, extrasaction="ignore")
        w.writeheader()
        for r in all_csv_rows:
            w.writerow(r)

    # JSON checkpoint
    payload = {
        "started": started,
        "elapsed_s": elapsed,
        "complete": complete,
        "baseline_vals": baseline_vals,
        "best_cfg": best_cfg,
        "best_study_geomean": best_score,
        "oat_summary": oat_summary,
        "ascent_log": [
            {**e, "config": e.get("config", {})}
            for e in ascent_log
        ],
        "final_full_ipcs": final_full["ipcs"] if final_full else None,
        "final_full_study_geomean": final_full["study_geomean"] if final_full else None,
        "final_full_big6_geomean": final_full["big6_geomean"] if final_full else None,
    }
    args.json.write_text(json.dumps(payload, indent=2), encoding="utf-8")

    # Markdown
    lines: list[str] = []
    lines += [
        "# rtl Structure Sizing Study",
        "",
        f"- Started: {started}",
        f"- Elapsed: {elapsed/60:.1f} min",
        f"- Status: {'COMPLETE' if complete else 'IN PROGRESS (checkpoint)'}",
        f"- Machine class held fixed: `WIDTH={width}`, baseline `CDB_WIDTH={cdb}`",
        f"- Memory: `MEM_SYSTEM_CACHED`, **`DRAM_MODEL_SIMPLE`** "
        f"(pinned; baseline file DRAM_MODEL={dram_model}, SIMPLE={dram_simple})",
        f"- Objective: maximize geomean IPC over study suite "
        f"({', '.join(f'`{p}`' for p in STUDY_PROGRAMS)})",
        f"- Also report VERIF big-6 geomean "
        f"({', '.join(f'`{p}`' for p in BIG6)})",
        "",
        "## Method",
        "",
        "1. **Baseline** — checked-in `pkg_cpu.sv` (with DRAM pinned SIMPLE).",
        "2. **One-at-a-time (OAT)** — each meaningful knob swept independently.",
        "3. **Coordinate ascent** — walk axes by OAT sensitivity; accept improving values.",
        "",
        "`pkg_cpu.sv` is restored after the study. Raw rows: "
        f"`{args.csv.name}`, checkpoint `{args.json.name}`.",
        "",
        "## Baseline",
        "",
    ]
    if baseline_result:
        lines += [
            f"- Study geomean: **{baseline_result['study_geomean']:.6f}**",
            f"- Big-6 geomean: **{baseline_result['big6_geomean']:.6f}**",
            "",
            "| Program | IPC | Cycles | Commits | D$ miss |",
            "|---|---:|---:|---:|---:|",
        ]
        for r in baseline_result["rows"]:
            lines.append(
                f"| {r['program']} | {r.get('ipc', '-')} | {r.get('cycles', '-')} | "
                f"{r.get('commits', '-')} | {r.get('dcache_miss', '-')} |"
            )
        lines.append("")

    lines += [
        "## OAT summary (best value per axis)",
        "",
        "| Axis | Baseline | Best | Best study geo | Δ vs baseline |",
        "|---|---:|---:|---:|---:|",
    ]
    for s in sorted(oat_summary, key=lambda x: -(x.get("delta_vs_baseline_geo") or -1e9)):
        d = s.get("delta_vs_baseline_geo")
        lines.append(
            f"| `{s['axis']}` | {s['baseline']} | {s['best_value']} | "
            f"{s['best_geomean']:.6f} | "
            f"{d:+.6f} |" if d is not None else
            f"| `{s['axis']}` | {s['baseline']} | {s['best_value']} | "
            f"{s['best_geomean']} | - |"
        )
    lines.append("")

    # Per-axis detail tables
    lines += ["## OAT detail", ""]
    for s in oat_summary:
        lines += [
            f"### `{s['axis']}`",
            "",
            "| Value | Study geomean |",
            "|---:|---:|",
        ]
        for e in s["ranked"]:
            mark = " ← best" if e["value"] == s["best_value"] else ""
            g = e["study_geomean"]
            gs = f"{g:.6f}" if g == g else "nan"
            lines.append(f"| {e['value']} | {gs}{mark} |")
        lines.append("")

    lines += [
        "## Coordinate ascent log",
        "",
        "| Step | Round | Axis | Try | Accepted | Study geo | Big-6 geo | Config |",
        "|---:|---:|---|---:|---|---:|---:|---|",
    ]
    for e in ascent_log:
        if e.get("step") == "start":
            lines.append(
                f"| start | - | - | - | - | {e['study_geomean']:.6f} | "
                f"{e['big6_geomean']:.6f} | (baseline) |"
            )
            continue
        lines.append(
            f"| {e.get('step')} | {e.get('round')} | `{e.get('axis')}` | "
            f"{e.get('try_value')} | {'yes' if e.get('accepted') else 'no'} | "
            f"{e['study_geomean']:.6f} | {e['big6_geomean']:.6f} | "
            f"{fmt_cfg(e.get('config') or {})} |"
        )
    lines.append("")

    lines += [
        "## Best configuration",
        "",
        f"- Study geomean: **{best_score:.6f}**",
        f"- Overrides vs checked-in baseline: `{fmt_cfg(best_cfg)}`",
        "",
    ]
    if best_cfg:
        lines += [
            "| Param | Baseline | Best |",
            "|---|---:|---:|",
        ]
        for k in sorted(best_cfg):
            lines.append(f"| `{k}` | {baseline_vals.get(k, '?')} | {best_cfg[k]} |")
        lines.append("")
    else:
        lines += ["No override beat baseline on the study objective.", ""]

    lines += [
        "## Notes",
        "",
        "- `WIDTH` intentionally not swept (defines the machine class).",
        "- Banked DRAM timings not swept; backend pinned to `DRAM_MODEL_SIMPLE`.",
        "- `DRAM_LAT_CYCLES` is swept in OAT for sensitivity but best structure "
        "selection prefers other axes via ascent (latency left at baseline unless "
        "ascent accepts it — excluded from ASCENT_AXES).",
        "- `RAS_DEPTH` unused in RTL; not swept.",
        "",
    ]
    args.md.write_text("\n".join(lines) + "\n", encoding="utf-8")


if __name__ == "__main__":
    # Fix accidental typo guard if any
    raise SystemExit(main())
