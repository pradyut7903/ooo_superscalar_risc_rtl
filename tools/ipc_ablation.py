#!/usr/bin/env python3
"""Ablation: NUM_LSQ x DCACHE_UFP_PORTS IPC matrix for rtl."""

from __future__ import annotations

import argparse
import csv
import math
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PKG = ROOT / "rtl" / "pkg_cpu.sv"
RUNNER = ROOT / "tools" / "run_imported_rtl.py"

DEFAULT_PROGRAMS = [
    "alu", "branch", "branchtaken", "cp1_example", "cp2_example",
    "custom_riscv", "dependency_test", "jump", "load", "load_store_grinder",
    "ooo_test", "riscv_mem", "simple_mem", "simple_st", "store", "super_simple",
    "ilp_loop", "matmul8", "mem_stream", "mix_bench",
]

CONFIGS = [
    ("base", 1, 1),
    ("lsq2", 2, 1),
    ("ufp2", 1, 2),
    ("both", 2, 2),
]


def set_param(text: str, name: str, value: int) -> str:
    pattern = rf"(localparam\s+int\s+{name}\s*=\s*)\d+(\s*;)"
    if not re.search(pattern, text):
        raise ValueError(f"localparam int {name} not found")
    return re.sub(pattern, rf"\g<1>{value}\g<2>", text)


def geomean(xs: list[float]) -> float:
    if not xs:
        return float("nan")
    return math.exp(sum(math.log(x) for x in xs) / len(xs))


def run_suite(programs: list[str], build: Path, timeout: int) -> list[dict[str, str]]:
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
    if proc.returncode != 0 and not rows:
        print(proc.stdout[-4000:], file=sys.stderr)
        raise RuntimeError(f"runner failed rc={proc.returncode}")
    return rows


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--timeout", type=int, default=2_000_000)
    ap.add_argument("--build", type=Path, default=ROOT / "build" / "ablation")
    ap.add_argument("--programs", nargs="*", default=DEFAULT_PROGRAMS)
    ap.add_argument("--md", type=Path, default=ROOT / "docs" / "VERIF_IPC_ABLATION.md")
    ap.add_argument("--csv", type=Path, default=ROOT / "docs" / "verif_ipc_ablation.csv")
    args = ap.parse_args()

    orig = PKG.read_text(encoding="utf-8")
    args.build.mkdir(parents=True, exist_ok=True)
    all_rows: list[dict[str, str]] = []

    try:
        for name, nlsq, ufp in CONFIGS:
            print(f"\n=== CONFIG {name} NUM_LSQ={nlsq} DCACHE_UFP_PORTS={ufp} ===", flush=True)
            text = set_param(orig, "NUM_LSQ", nlsq)
            text = set_param(text, "DCACHE_UFP_PORTS", ufp)
            PKG.write_text(text, encoding="utf-8")
            build = args.build / name
            if build.exists():
                shutil.rmtree(build)
            build.mkdir(parents=True)
            rows = run_suite(args.programs, build, args.timeout)
            for r in rows:
                r["config"] = name
                r["NUM_LSQ"] = str(nlsq)
                r["DCACHE_UFP_PORTS"] = str(ufp)
                all_rows.append(r)
                print(
                    f"  {r['program']}: {r.get('result')} ipc={r.get('ipc', '?')}",
                    flush=True,
                )
    finally:
        PKG.write_text(orig, encoding="utf-8")

    # CSV
    fields = [
        "config", "NUM_LSQ", "DCACHE_UFP_PORTS", "program", "result",
        "commits", "cycles", "ipc", "redirects",
        "icache_hit", "icache_miss", "dcache_hit", "dcache_miss",
    ]
    with args.csv.open("w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=fields, extrasaction="ignore")
        w.writeheader()
        for r in all_rows:
            w.writerow(r)

    # Index by config/program
    by: dict[str, dict[str, dict[str, str]]] = {}
    for r in all_rows:
        by.setdefault(r["config"], {})[r["program"]] = r

    base = by.get("base", {})
    lines: list[str] = []
    lines.append("# rtl IPC Ablation (NUM_LSQ × DCACHE_UFP_PORTS)\n")
    lines.append("Correctness fixes held constant. Fetch outstanding remains parked.\n")
    lines.append("| Config | NUM_LSQ | DCACHE_UFP_PORTS | Meaning |")
    lines.append("|---|---:|---:|---|")
    lines.append("| base | 1 | 1 | old perf knobs |")
    lines.append("| lsq2 | 2 | 1 | load CDB only |")
    lines.append("| ufp2 | 1 | 2 | dual UFP only |")
    lines.append("| both | 2 | 2 | new default |")
    lines.append("")

    lines.append("## Per-program IPC\n")
    hdr = "| Program | base | lsq2 | ufp2 | both | best Δ vs base |"
    lines.append(hdr)
    lines.append("|---|---:|---:|---:|---:|---|")

    bottleneck_rows: list[str] = []
    for prog in args.programs:
        vals: dict[str, float] = {}
        cells = [prog]
        for cfg, _, _ in CONFIGS:
            r = by.get(cfg, {}).get(prog)
            if r and r.get("result") == "PASS" and "ipc" in r:
                v = float(r["ipc"])
                vals[cfg] = v
                cells.append(f"{v:.6f}")
            else:
                cells.append("FAIL")
        base_v = vals.get("base")
        best_note = "-"
        if base_v is not None and vals:
            best_cfg = max(vals.keys(), key=lambda c: vals[c])
            best_d = vals[best_cfg] - base_v
            best_note = f"{best_cfg} ({best_d:+.4f})"
            # bottleneck heuristic
            r_both = by.get("both", {}).get(prog, {})
            redirects = int(r_both.get("redirects", "0") or 0)
            commits = int(float(r_both.get("commits", "1") or 1))
            dh = int(r_both.get("dcache_hit", "0") or 0)
            dm = int(r_both.get("dcache_miss", "0") or 0)
            d_tot = dh + dm
            miss_rate = (dm / d_tot) if d_tot else 0.0
            red_rate = redirects / commits if commits else 0.0
            d_lsq = vals.get("lsq2", base_v) - base_v
            d_ufp = vals.get("ufp2", base_v) - base_v
            if red_rate > 0.05:
                label = "branch/recovery"
            elif d_tot == 0 and vals.get("both", 0) < 0.75:
                label = "fetch-bound (parked)"
            elif miss_rate > 0.05:
                label = "miss/DRAM"
            elif d_ufp >= d_lsq and d_ufp > 0.002:
                label = "D$ hit / UFP"
            elif d_lsq > 0.002:
                label = "load CDB"
            else:
                label = "mixed / other"
            bottleneck_rows.append(
                f"| {prog} | {label} | {best_cfg} | {best_d:+.4f} | "
                f"redir={red_rate:.3f} dmiss={miss_rate:.3f} |"
            )
        cells.append(best_note)
        lines.append("| " + " | ".join(cells) + " |")

    lines.append("")
    lines.append("## Geomean IPC by config\n")
    lines.append("| Config | geomean all | geomean big6* |")
    lines.append("|---|---:|---:|")
    big6 = {"ilp_loop", "mem_stream", "matmul8", "mix_bench", "custom_riscv", "branch"}
    for cfg, _, _ in CONFIGS:
        ipcs = []
        big = []
        for prog, r in by.get(cfg, {}).items():
            if r.get("result") == "PASS" and "ipc" in r:
                v = float(r["ipc"])
                if v > 0:
                    ipcs.append(v)
                    if prog in big6:
                        big.append(v)
        lines.append(
            f"| {cfg} | {geomean(ipcs):.6f} | {geomean(big):.6f} |"
        )
    lines.append("")
    lines.append("\\* big6 = ilp_loop, mem_stream, matmul8, mix_bench, custom_riscv, branch")
    lines.append("")
    lines.append("## Suspected bottleneck (on `both` + ablation deltas)\n")
    lines.append("| Program | Suspected bottleneck | Best config | Δ IPC vs base | Signals |")
    lines.append("|---|---|---|---:|---|")
    lines.extend(bottleneck_rows)
    lines.append("")

    args.md.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"\nWrote {args.md}")
    print(f"Wrote {args.csv}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
