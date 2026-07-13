#!/usr/bin/env python3
"""IPC sensitivity sweeps over rtl pkg_cpu parameters.

Patches `pkg_cpu.sv` localparam ints one axis at a time (restoring after each
config), runs a small representative program set, and writes a markdown report.
"""

from __future__ import annotations

import argparse
import csv
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PKG = ROOT / "rtl" / "pkg_cpu.sv"
RUNNER = ROOT / "tools" / "run_imported_rtl.py"

# Representative set: short + long loop + mem-heavy + mix.
DEFAULT_PROGRAMS = ["branch", "ilp_loop", "mem_stream", "matmul8", "mix_bench", "custom_riscv"]

SWEEPS: dict[str, list[int]] = {
    "ROB_DEPTH": [16, 32, 64],
    "RS_DEPTH": [16, 32, 64],
    "LSQ_DEPTH": [16, 32, 64],
    "IFQ_DEPTH": [8, 16, 32],
    "CDB_WIDTH": [2, 4],
    "NUM_ALU": [1, 2, 4],
    "DCACHE_SETS": [8, 16, 32, 64],
    "ICACHE_SETS": [8, 16, 32, 64],
    "DCACHE_WAYS": [2, 4],
    "ICACHE_WAYS": [2, 4],
    "DRAM_LAT_CYCLES": [5, 10, 20, 40],
    "CACHE_LINE_BYTES": [16, 32, 64],
}


def set_param(text: str, name: str, value: int) -> str:
    pattern = rf"(localparam\s+int\s+{name}\s*=\s*)\d+(\s*;)"
    if not re.search(pattern, text):
        raise ValueError(f"localparam int {name} not found")
    return re.sub(pattern, rf"\g<1>{value}\g<2>", text)


def run_suite(programs: list[str], build: Path, timeout: int) -> list[dict[str, str]]:
    cmd = [
        sys.executable,
        str(RUNNER),
        "--build",
        str(build),
        "--timeout",
        str(timeout),
        "--only",
        *programs,
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
        print(proc.stdout[-4000:])
    return rows


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--programs", nargs="*", default=DEFAULT_PROGRAMS)
    parser.add_argument("--timeout", type=int, default=2_000_000)
    parser.add_argument("--out-md", type=Path, default=ROOT / "docs" / "VERIF_IPC_SENSITIVITY.md")
    parser.add_argument("--out-csv", type=Path, default=ROOT / "docs" / "verif_ipc_sensitivity.csv")
    parser.add_argument("--axes", nargs="*", default=None, help="Subset of sweep axis names")
    parser.add_argument("--quick", action="store_true", help="Fewer points / programs")
    args = parser.parse_args()

    programs = args.programs
    sweeps = dict(SWEEPS)
    if args.quick:
        programs = ["ilp_loop", "mem_stream", "matmul8"]
        sweeps = {
            "ROB_DEPTH": [16, 32, 64],
            "RS_DEPTH": [16, 32],
            "LSQ_DEPTH": [16, 32],
            "CDB_WIDTH": [2, 4],
            "NUM_ALU": [1, 2, 4],
            "DCACHE_SETS": [8, 16, 32],
            "ICACHE_SETS": [8, 16, 32],
            "DRAM_LAT_CYCLES": [5, 10, 20],
            "CACHE_LINE_BYTES": [16, 32],
        }
    if args.axes:
        sweeps = {k: sweeps[k] for k in args.axes if k in sweeps}

    orig = PKG.read_text(encoding="utf-8")
    # Snapshot baseline params from the file.
    baseline: dict[str, int] = {}
    for name in sweeps:
        m = re.search(rf"localparam\s+int\s+{name}\s*=\s*(\d+)\s*;", orig)
        if not m:
            print(f"skip missing {name}")
            continue
        baseline[name] = int(m.group(1))

    results: list[dict[str, str]] = []
    build_root = ROOT / "build" / "sim" / "ipc_sweep"

    try:
        # Baseline first.
        print("=== BASELINE ===", flush=True)
        rows = run_suite(programs, build_root / "baseline", args.timeout)
        for r in rows:
            results.append({"axis": "BASELINE", "value": "-", **r})

        for axis, values in sweeps.items():
            for val in values:
                if baseline.get(axis) == val and axis != "CDB_WIDTH":
                    # Still run; useful confirmation. Keep all points.
                    pass
                print(f"=== {axis}={val} ===", flush=True)
                text = set_param(orig, axis, val)
                # Keep cache geometry consistent when sweeping one side's sets/ways
                # only when the twin param exists with same default intent — leave independent.
                if axis == "CACHE_LINE_BYTES":
                    # OFFSET_W is derived; no extra patch.
                    pass
                PKG.write_text(text, encoding="utf-8")
                rows = run_suite(programs, build_root / f"{axis}_{val}", args.timeout)
                for r in rows:
                    results.append({"axis": axis, "value": str(val), **r})
    finally:
        PKG.write_text(orig, encoding="utf-8")

    # CSV
    args.out_csv.parent.mkdir(parents=True, exist_ok=True)
    fieldnames = [
        "axis", "value", "program", "result", "commits", "cycles", "ipc",
        "redirects", "icache_hit", "icache_miss", "dcache_hit", "dcache_miss",
    ]
    with args.out_csv.open("w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=fieldnames, extrasaction="ignore")
        w.writeheader()
        for r in results:
            w.writerow(r)

    # Markdown
    w_m = re.search(r"localparam int WIDTH\s*=\s*(\d+)", orig)
    c_m = re.search(r"localparam int CDB_WIDTH\s*=\s*(\d+)", orig)
    width_s = w_m.group(1) if w_m else "?"
    cdb_s = c_m.group(1) if c_m else "?"
    lines = [
        "# rtl IPC Sensitivity Study",
        "",
        "One-parameter sweeps from the checked-in `pkg_cpu.sv` baseline "
        f"(WIDTH={width_s}, CDB_WIDTH={cdb_s}).",
        "",
        "Programs: " + ", ".join(f"`{p}`" for p in programs),
        "",
        "## Results",
        "",
        "| Axis | Value | Program | Result | Commits | Cycles | IPC | Redirects | I$ hit/miss | D$ hit/miss |",
        "|---|---:|---|---|---:|---:|---:|---:|---|---|",
    ]
    for r in results:
        ih = r.get("icache_hit", "-")
        im = r.get("icache_miss", "-")
        dh = r.get("dcache_hit", "-")
        dm = r.get("dcache_miss", "-")
        lines.append(
            f"| {r.get('axis')} | {r.get('value')} | {r.get('program')} | {r.get('result')} | "
            f"{r.get('commits', '-')} | {r.get('cycles', '-')} | {r.get('ipc', '-')} | "
            f"{r.get('redirects', '-')} | {ih}/{im} | {dh}/{dm} |"
        )
    lines += [
        "",
        "## Method",
        "",
        "- Each axis is swept independently; other params stay at baseline.",
        "- `pkg_cpu.sv` is restored after the study.",
        "- IPC from RTL STATS lines (commits/cycles to halt).",
        "",
        f"CSV: `{args.out_csv.as_posix()}`",
        "",
    ]
    args.out_md.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"Wrote {args.out_md}")
    print(f"Wrote {args.out_csv}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
