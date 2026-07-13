#!/usr/bin/env python3
"""Run imported/workload programs on the rtl core, with optional golden check."""

from __future__ import annotations

import argparse
import csv
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(Path(__file__).resolve().parent))
from golden_rv32im import (  # noqa: E402
    GoldenRV32IM,
    compare_commit_stream,
    load_hex_words,
)

RTL_FILES = [
    "pkg_cpu.sv",
    "core.sv",
    "branch_predictor.sv",
    "fetch.sv",
    "instr_mem.sv",
    "ifq.sv",
    "if_id_reg.sv",
    "decode.sv",
    "id_rn_reg.sv",
    "dispatch_reg.sv",
    "backend.sv",
    "rename_dispatch.sv",
    "arf.sv",
    "rat.sv",
    "rat_checkpoints.sv",
    "rob.sv",
    "rs.sv",
    "lsq.sv",
    "dmem.sv",
    "cdb_arbiter.sv",
    "alu.sv",
    "mul.sv",
    "div.sv",
    "branch_unit.sv",
    "commit_recovery.sv",
    "early_recovery.sv",
    "mem/ideal_imem_bridge.sv",
    "mem/dram_model_simple.sv",
    "mem/dram_model_banked.sv",
    "mem/dram_model.sv",
    "mem/mem_arbiter.sv",
    "mem/dcache.sv",
    "mem/icache.sv",
]


def run(cmd: list[str], cwd: Path) -> tuple[int, str]:
    proc = subprocess.run(
        subprocess.list2cmdline(cmd),
        cwd=cwd,
        text=True,
        shell=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    return proc.returncode, proc.stdout


def tb_text(
    module_name: str,
    imem: str,
    dmem: str,
    timeout: int,
    trace: bool = False,
    trace_commits: bool = False,
    dump_golden: bool = False,
    golden_full: bool = False,
) -> str:
    commit_dump = ""
    if dump_golden:
        full = ""
        if golden_full:
            full = """
          $display("GOLDEN_COMMIT rd_used=%0b rd=%0d value=%h",
                   commit_rd_used_bundle[lane], commit_rd_bundle[lane],
                   commit_value_bundle[lane]);
"""
        commit_dump = f"""
      begin
        logic [31:0] dig_n;
        dig_n = golden_digest;
        for (int lane = 0; lane < WIDTH; lane++) begin
          if (commit_valid_bundle[lane]) begin
            logic [31:0] v;
            logic        used;
            used = commit_rd_used_bundle[lane];
            v = used ? commit_value_bundle[lane] : 32'h0;
            dig_n = dig_n
                ^ ({{27'b0, used ? commit_rd_bundle[lane] : 5'd0}} << 1)
                ^ {{31'b0, used}}
                ^ v;
            dig_n = dig_n ^ (dig_n << 1 | dig_n >> 31);
{full}
          end
        end
        golden_digest <= dig_n;
      end
"""
    # ... rest built below
    extra_trace = ""
    if trace:
        commit_trace = ""
        if trace_commits:
            commit_trace = """
      for (int lane = 0; lane < WIDTH; lane++) begin
        if (commit_valid_bundle[lane]) begin
          $display("TRACE commit lane=%0d tag=%0d rd_used=%0b rd=%0d value=%h",
                   lane, commit_tag_bundle[lane], commit_rd_used_bundle[lane],
                   commit_rd_bundle[lane], commit_value_bundle[lane]);
        end
      end
"""
        extra_trace = commit_trace + """
      if (dut.u_backend.u_branch.br_resolve_valid) begin
        $display("TRACE branch tag=%0d target=%h mis=%0b",
                 dut.u_backend.u_branch.br_resolve_tag,
                 dut.u_backend.u_branch.br_redirect_pc,
                 dut.u_backend.u_branch.br_mispredict);
      end
      if (dut.redirect_valid) begin
        $display("TRACE recovery redirect=%h", dut.redirect_pc);
      end
"""
    always_block = ""
    digest_decl = ""
    if dump_golden or trace:
        if dump_golden:
            digest_decl = "  logic [31:0] golden_digest = 32'h0;\n"
        always_block = f"""
  always @(posedge clk) begin
    if (rst) begin
      {"golden_digest <= 32'h0;" if dump_golden else ""}
    end else begin
{commit_dump}{extra_trace}
    end
  end
"""
    digest_print = ""
    if dump_golden:
        digest_print = """
        $display("GOLDEN_DIGEST commits=%0d digest=%h", commits, golden_digest);
"""
    return f"""`timescale 1ns/1ps
module {module_name};
  import pkg_cpu::*;

  logic clk = 1'b0;
  logic rst = 1'b1;
  logic commit_valid;
  rob_tag_t commit_tag;
  logic commit_rd_used;
  reg_idx_t commit_rd;
  data_t commit_value;
  valid_bundle_t commit_valid_bundle;
  rob_tag_t commit_tag_bundle [WIDTH];
  logic commit_rd_used_bundle [WIDTH];
  reg_idx_t commit_rd_bundle [WIDTH];
  data_t commit_value_bundle [WIDTH];
  logic halted;
  logic cdb_overflow;
  int commits = 0;
  int cycles = 0;
  int redirects = 0;
  int errors = 0;
{digest_decl}
  core #(.IMEM_IMAGE("{imem}"), .DMEM_IMAGE("{dmem}")) dut (
    .clk(clk), .rst(rst),
    .commit_valid(commit_valid), .commit_tag(commit_tag),
    .commit_rd_used(commit_rd_used), .commit_rd(commit_rd), .commit_value(commit_value),
    .commit_valid_bundle(commit_valid_bundle), .commit_tag_bundle(commit_tag_bundle),
    .commit_rd_used_bundle(commit_rd_used_bundle), .commit_rd_bundle(commit_rd_bundle),
    .commit_value_bundle(commit_value_bundle),
    .halted(halted), .cdb_overflow(cdb_overflow)
  );

  always #5 clk = ~clk;

  always @(posedge clk) begin
    if (rst) begin
      commits <= 0;
      cycles <= 0;
      redirects <= 0;
    end else begin
      int n;
      n = 0;
      for (int lane = 0; lane < WIDTH; lane++) begin
        if (commit_valid_bundle[lane]) n++;
      end
      commits <= commits + n;
      cycles <= cycles + 1;
      if (dut.redirect_valid) redirects <= redirects + 1;
    end
  end
{always_block}
  initial begin
    repeat (3) @(posedge clk);
    rst = 1'b0;

    for (int k = 0; k < {timeout}; k++) begin
      @(posedge clk); #1;
      if (halted) begin
        real ipc;
        int ih, im, dh, dm;
        ih = 0; im = 0; dh = 0; dm = 0;
        if (cdb_overflow) begin
          $display("FAIL cdb_overflow");
          errors++;
        end
        if (commits == 0) begin
          $display("FAIL no commits");
          errors++;
        end
        if (MEM_SYSTEM == MEM_SYSTEM_CACHED) begin
          ih = dut.g_cached_mem.u_icache.hit_count;
          im = dut.g_cached_mem.u_icache.miss_count;
          dh = dut.g_cached_mem.u_dcache.hit_count;
          dm = dut.g_cached_mem.u_dcache.miss_count;
        end
        ipc = (cycles > 0) ? (1.0 * commits) / cycles : 0.0;
        $display("STATS name={module_name} commits=%0d cycles=%0d ipc=%f redirects=%0d cdb_overflow=%0b icache_hit=%0d icache_miss=%0d dcache_hit=%0d dcache_miss=%0d",
                 commits, cycles, ipc, redirects, cdb_overflow, ih, im, dh, dm);
{digest_print}
        if (errors == 0) $display("TB_IMPORTED_{module_name}: PASS commits=%0d", commits);
        else             $display("TB_IMPORTED_{module_name}: FAIL (%0d errors)", errors);
        $finish;
      end
    end

    $display("FAIL halt timeout commits=%0d cycles=%0d cdb_overflow=%0b", commits, cycles, cdb_overflow);
    $display("TB_IMPORTED_{module_name}: FAIL (timeout)");
    $finish;
  end
endmodule
"""


def golden_digest(commits) -> tuple[int, int]:
    digest = 0
    for c in commits:
        rd_used = bool(c.rd_used) if hasattr(c, "rd_used") else bool(c.get("rd_used", 0))
        rd = int(c.rd) if hasattr(c, "rd") else int(c.get("rd", 0))
        value = int(c.value) if hasattr(c, "value") else int(c.get("value", 0))
        if not rd_used:
            rd = 0
            value = 0
        value &= 0xFFFF_FFFF
        digest ^= ((rd & 0x1F) << 1) & 0xFFFF_FFFF
        digest ^= (1 if rd_used else 0) & 0xFFFF_FFFF
        digest ^= value
        digest = (digest ^ (((digest << 1) | (digest >> 31)) & 0xFFFF_FFFF)) & 0xFFFF_FFFF
    return len(commits), digest


def parse_golden_digest(sim_out: str) -> tuple[int | None, int | None]:
    for line in sim_out.splitlines():
        if line.startswith("GOLDEN_DIGEST "):
            commits = digest = None
            for tok in line.split()[1:]:
                if tok.startswith("commits="):
                    commits = int(tok.split("=", 1)[1])
                elif tok.startswith("digest="):
                    digest = int(tok.split("=", 1)[1], 16)
            return commits, digest
    return None, None


def parse_golden_commits(sim_out: str) -> list[dict]:
    commits = []
    for line in sim_out.splitlines():
        if not line.startswith("GOLDEN_COMMIT "):
            continue
        fields: dict[str, object] = {}
        for tok in line.split()[1:]:
            if "=" not in tok:
                continue
            k, v = tok.split("=", 1)
            if k == "value":
                fields[k] = int(v, 16)
            else:
                fields[k] = int(v, 0)
        commits.append(fields)
    return commits


def write_md(path: Path, stats_rows: list[dict], timeout: int, title: str) -> None:
    lines = [
        f"# {title}",
        "",
        "Generated by `tools/run_imported_rtl.py --write-md`.",
        "",
        "## Configuration",
        "",
        "- Defaults from `pkg_cpu.sv` (WIDTH/CDB_WIDTH, ROB/RS/LSQ, caches, DRAM_LAT)",
        f"- Sim timeout: {timeout} cycles",
        "",
        "## Program results",
        "",
        "| Program | Result | Golden | Commits | Cycles | IPC | Redirects | I$ hit | I$ miss | D$ hit | D$ miss |",
        "|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|",
    ]
    for s in stats_rows:
        lines.append(
            "| {program} | {result} | {golden} | {commits} | {cycles} | {ipc} | {redirects} | {ih} | {im} | {dh} | {dm} |".format(
                program=s.get("program", "?"),
                result=s.get("result", "?"),
                golden=s.get("golden", "-"),
                commits=s.get("commits", "-"),
                cycles=s.get("cycles", "-"),
                ipc=s.get("ipc", "-"),
                redirects=s.get("redirects", "-"),
                ih=s.get("icache_hit", "-"),
                im=s.get("icache_miss", "-"),
                dh=s.get("dcache_hit", "-"),
                dm=s.get("dcache_miss", "-"),
            )
        )
    lines += [
        "",
        "## Notes",
        "",
        "- **IPC** = committed instructions / cycles from reset release to halt.",
        "- **Golden** compares RTL commit `(rd_used, rd, value)` stream to `tools/golden_rv32im.py`.",
        "",
    ]
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> int:
    rtl_root = ROOT
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--manifest",
        type=Path,
        action="append",
        default=None,
        help="Manifest CSV (repeatable). Default: imported + workloads_hex",
    )
    parser.add_argument("--rtl", type=Path, default=rtl_root / "rtl")
    parser.add_argument("--build", type=Path, default=rtl_root / "build" / "sim" / "imported")
    parser.add_argument("--timeout", type=int, default=2_000_000)
    parser.add_argument("--only", nargs="*", default=None)
    parser.add_argument("--trace", action="store_true")
    parser.add_argument("--trace-commits", action="store_true")
    parser.add_argument("--golden", action="store_true", help="Compare vs golden_rv32im digest/stream")
    parser.add_argument(
        "--golden-full",
        action="store_true",
        help="Also dump/compare full commit stream (slow on large programs)",
    )
    parser.add_argument("--write-md", type=Path, default=None)
    parser.add_argument("--md-title", type=str, default="rtl Verification & IPC Report")
    args = parser.parse_args()
    if args.golden_full:
        args.golden = True

    if args.manifest is None:
        args.manifest = [
            rtl_root / "tb" / "imported" / "manifest.csv",
            rtl_root / "tb" / "workloads_hex" / "manifest.csv",
        ]

    args.build.mkdir(parents=True, exist_ok=True)
    run_all = args.build / "run_all.tcl"
    run_all.write_text("run all\nexit\n")

    rows: list[dict[str, str]] = []
    for man in args.manifest:
        if not man.exists():
            print(f"WARN skip missing manifest {man}")
            continue
        with man.open(newline="") as f:
            rows.extend(list(csv.DictReader(f)))

    if args.only:
        keep = set(args.only)
        rows = [r for r in rows if r["name"] in keep]

    failed: list[str] = []
    stats_rows: list[dict[str, str]] = []
    rtl_paths = [str((args.rtl / name).resolve()) for name in RTL_FILES]

    for row in rows:
        name = row["name"]
        module_name = "tb_imported_" + re.sub(r"[^A-Za-z0-9_]", "_", name)
        imem_src = Path(row["imem"])
        dmem_src = Path(row["dmem"])

        def resolve_hex(p: Path) -> Path:
            if p.is_absolute() and p.exists():
                return p
            candidates = [
                Path.cwd() / p,
                ROOT / p,  # ooo_rtl/...
                ROOT.parent / p,  # repo-root relative ooo_rtl/...
                ROOT / "tb" / "imported" / p.name,
                ROOT / "tb" / "workloads_hex" / p.name,
            ]
            for c in candidates:
                if c.exists():
                    return c.resolve()
            return candidates[0].resolve()

        imem_src = resolve_hex(imem_src)
        dmem_src = resolve_hex(dmem_src)
        if not imem_src.exists() or not dmem_src.exists():
            print(f"FAIL missing hex for {name}: {imem_src} / {dmem_src}")
            failed.append(f"{name}:missing_hex")
            stats_rows.append({"program": name, "result": "FAIL", "golden": "SKIP"})
            continue

        imem_name = imem_src.name
        dmem_name = dmem_src.name
        shutil.copyfile(imem_src, args.build / imem_name)
        shutil.copyfile(dmem_src, args.build / dmem_name)

        # Pre-run golden for expected commit count / stream.
        golden_ok = "-"
        model = None
        if args.golden:
            model = GoldenRV32IM(load_hex_words(imem_src), load_hex_words(dmem_src))
            model.run()

        tb_path = args.build / f"{module_name}.sv"
        tb_path.write_text(
            tb_text(
                module_name,
                imem_name,
                dmem_name,
                args.timeout,
                args.trace,
                args.trace_commits,
                dump_golden=args.golden,
                golden_full=args.golden_full,
            )
        )

        print(f"===== {name} =====", flush=True)
        code, out = run(["xvlog", "--sv", *rtl_paths, str(tb_path.resolve())], args.build)
        if code != 0:
            print(out)
            failed.append(f"{name}:xvlog")
            stats_rows.append({"program": name, "result": "FAIL", "golden": "SKIP"})
            continue

        snap = f"{module_name}_snap"
        code, out = run(
            ["xelab", module_name, "-s", snap, "-timescale", "1ns/1ps", "-mt", "off"],
            args.build,
        )
        if code != 0:
            print(out)
            failed.append(f"{name}:xelab")
            stats_rows.append({"program": name, "result": "FAIL", "golden": "SKIP"})
            continue

        code, out = run(["xsim", snap, "-tclbatch", "run_all.tcl"], args.build)
        interesting = [
            line
            for line in out.splitlines()
            if "TB_IMPORTED_" in line
            or line.startswith("FAIL ")
            or line.startswith("TRACE ")
            or line.startswith("STATS ")
            or line.startswith("GOLDEN_")
        ]
        # Keep GOLDEN_COMPARE summary only in printed interesting (not every commit).
        print_lines = [ln for ln in interesting if not ln.startswith("GOLDEN_COMMIT ")]
        print("\n".join(print_lines), flush=True)

        fields: dict[str, str] = {"program": name, "result": "PASS", "golden": golden_ok}
        for line in out.splitlines():
            if line.startswith("STATS "):
                for tok in line.split():
                    if "=" in tok:
                        k, v = tok.split("=", 1)
                        fields[k] = v

        sim_pass = code == 0 and any("PASS" in ln for ln in print_lines if "TB_IMPORTED_" in ln)
        if not sim_pass:
            fields["result"] = "FAIL"
            failed.append(f"{name}:xsim")

        if args.golden and model is not None and fields["result"] == "PASS":
            g_n, g_dig = golden_digest(model.commits)
            r_n, r_dig = parse_golden_digest(out)
            errs: list[str] = []
            if r_n is None or r_dig is None:
                errs.append("missing GOLDEN_DIGEST from RTL")
            else:
                if r_n != g_n:
                    errs.append(f"commit count mismatch golden={g_n} rtl={r_n}")
                if r_dig != g_dig:
                    errs.append(f"digest mismatch golden={g_dig:08x} rtl={r_dig:08x}")
            if args.golden_full:
                rtl_commits = parse_golden_commits(out)
                errs.extend(compare_commit_stream(model.commits, rtl_commits))
            if errs:
                fields["golden"] = "FAIL"
                fields["result"] = "FAIL"
                failed.append(f"{name}:golden")
                print("GOLDEN_COMPARE: FAIL")
                for e in errs[:12]:
                    print(" ", e)
            else:
                fields["golden"] = "PASS"
                print(f"GOLDEN_COMPARE: PASS commits={g_n} digest={g_dig:08x}")

        stats_rows.append(fields)

    if args.write_md is not None:
        md_path = args.write_md
        if not md_path.is_absolute():
            # Prefer repo-root-relative path if it starts with ooo_rtl/
            cand = Path.cwd() / md_path
            md_path = cand if not str(md_path).startswith("rtl") else (rtl_root / md_path)
        write_md(md_path, stats_rows, args.timeout, args.md_title)
        print(f"Wrote {md_path}", flush=True)

    if failed:
        print("FAILED:", ", ".join(failed))
        return 1
    print("ALL IMPORTED rtl PROGRAMS PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
