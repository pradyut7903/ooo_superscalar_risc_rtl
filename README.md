# RV32IM Out-of-Order Core

Superscalar (default 4-wide) Tomasulo-style RV32IM CPU in SystemVerilog:
reorder buffer, reservation stations, LSQ with committed store buffer,
execute-time branch recovery with RAT checkpoints, and a non-blocking
cached memory system.

## Repository layout

```text
rtl/              Core + FU RTL and mem/ (I$/D$/DRAM/arbiter)
tb/               Unit + core testbenches, hex programs, regression script
  imported/       Directed / imported RV32 programs (.s + .imem.hex/.dmem.hex)
  workloads/      Larger hand-written workloads (.s)
  workloads_hex/
tools/            Assembler, golden model, IPC runners
sizing/           Structure sizing study report + raw data
ARCHITECTURE.md   Module list and salient features
```

## Quick start (Vivado xsim)

**Unit / core regression**

```powershell
cd tb
.\run_regression.ps1
# optional: -Tests tb_core,tb_lsq -KeepGoing
```

**Imported + workload programs (with golden)**

```powershell
cd <repo-root>
python tools/run_imported_rtl.py --golden
# subset: python tools/run_imported_rtl.py --golden --only branch matmul8
```

**Assemble a program**

```powershell
python tools/asm_to_hex.py path\to\prog.s -o path\to\out_dir
```

Requires Vivado `xvlog` / `xelab` / `xsim` on `PATH`.

## Architecture

See [ARCHITECTURE.md](ARCHITECTURE.md).

## ISA contract

RV32IM user-level integer only (no CSRs, traps, atomics, or real fences).
`x0` hardwired to 0. Rename uses ROB tags (no physical register file).

## Key parameters (`rtl/pkg_cpu.sv`)


| Knob                                   | Default | Notes                               |
| -------------------------------------- | ------- | ----------------------------------- |
| `WIDTH` / `CDB_WIDTH`                  | 4 / 4   | Dispatch / CDB bandwidth            |
| `ROB_DEPTH` / `RS_DEPTH` / `LSQ_DEPTH` | 32      | Scheduler sizes                     |
| `STORE_BUF_DEPTH`                      | 8       | Retire stores without waiting on D$ |
| `NUM_ALU` / `NUM_LSQ`                  | 2 / 2   | Execute / load CDB producers        |
| `DCACHE_UFP_PORTS`                     | 2       | Dual-ported D$ (capped at 2)        |
| `DRAM_MODEL`                           | SIMPLE  | Fixed-latency DRAM for studies      |


## Structure sizing study

One-at-a-time sweeps + coordinate ascent over `pkg_cpu` knobs (WIDTH=4 held
fixed), under cached L1s with `**DRAM_MODEL_SIMPLE**`. Reported metric:
geomean IPC on the workload suite
(`custom_riscv`, `riscv_mem`, `ilp_loop`, `matmul8`, `mem_stream`,
`mix_bench`). Full report: [sizing/VERIF_IPC_SIZING.md](sizing/VERIF_IPC_SIZING.md).


|                                | Workload geomean IPC |
| ------------------------------ | -------------------- |
| Baseline (checked-in defaults) | 0.540                |
| **Best**                       | **0.550**            |


**Best configuration** (overrides vs checked-in defaults):


| Param        | Baseline | Best    |
| ------------ | -------- | ------- |
| `MUL_STAGES` | 3        | **2**   |
| `NUM_ALU`    | 2        | **3**   |
| `PHT_SIZE`   | 1024     | **256** |


Largest OAT wins were `CACHE_LINE_BYTES=64` and `MUL_STAGES=2`; ascent kept the
mul/ALU/PHT set above (64 B lines was strong in OAT but not locked in as the
accepted multi-param config). Queue depths / MSHRs were flat on this suite.

### Best config + banked DRAM

Same overrides with `DRAM_MODEL_BANKED` (SDRAM-like open-row timing) —
same workload suite. Detail:
[sizing/VERIF_IPC_BEST_BANKED.md](sizing/VERIF_IPC_BEST_BANKED.md).


|                          | Workload geomean IPC |
| ------------------------ | -------------------- |
| Best + SIMPLE DRAM MODEL | 0.550                |
| Best + BANKED DRAM MODEL | **0.550**            |



| Program      | IPC (BANKED) |
| ------------ | ------------ |
| custom_riscv | 0.494        |
| riscv_mem    | 0.541        |
| ilp_loop     | 0.666        |
| matmul8      | 0.569        |
| mem_stream   | 0.597        |
| mix_bench    | 0.458        |


Banked vs simple is essentially same on this suite (miss traffic is light / already  
amortized); IPC matches the SIMPLE best within noise.

## License

Add your preferred license before publishing.