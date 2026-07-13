# Architecture

This is a 4-wide out-of-order RV32IM core in SystemVerilog. Fetch and commit
are in order; issue and complete are not. There is no physical register file:
the rename tag is a ROB index, values sit in the ROB until they commit into
the ARF, and dependents wake on the CDB.

Defaults live in `rtl/pkg_cpu.sv` (`WIDTH=4`, `CDB_WIDTH=4`). The top module is
`rtl/core.sv`.

---

## Modules

### Frontend


| Module                    | What it does                                                                                         |
| ------------------------- | ---------------------------------------------------------------------------------------------------- |
| `branch_predictor`        | gshare PHT + BTB. Predicts taken/target for fetch. Updated at commit.                                |
| `fetch`                   | Pulls up to `WIDTH` instructions per cycle from the I-side, attaches predictions, handles redirects. |
| `ifq`                     | Instruction fetch queue between fetch and decode.                                                    |
| `decode`                  | Combinational RV32IM decode to micro-ops. Illegal / system / fence → NOP.                            |
| `dispatch_reg`            | Holds a decoded bundle; pops a prefix of lanes accepted by the backend.                              |
| `if_id_reg` / `id_rn_reg` | Pipeline registers on the frontend path (timing boundaries).                                         |


### Backend control


| Module            | What it does                                                                                                                        |
| ----------------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| `backend`         | Wires rename, ROB/RAT/ARF, RS, LSQ, FUs, CDB, and recovery.                                                                         |
| `rename_dispatch` | Renames a bundle in lane order, resolves operands, allocates ROB entries, sends ops to RS or LSQ. Prefix accept count backpressure. |
| `rat`             | Maps each arch reg to ARF or an in-flight ROB tag.                                                                                  |
| `rat_checkpoints` | Snapshots of the RAT taken on control-flow rename; restored on mispredict.                                                          |
| `arf`             | Architectural register file. Written only at commit. `x0` is hardwired 0.                                                           |
| `rob`             | Reorder buffer. Allocates tags, tracks done/control/store state, commits in order, grants store-commit permission.                  |
| `rs`              | Reservation station for ALU/MUL/DIV/branch. CDB wakeup; issues ready ops to FUs.                                                    |
| `cdb_arbiter`     | Picks up to `CDB_WIDTH` producer results per cycle and broadcasts them.                                                             |
| `early_recovery`  | On mispredict resolve: redirect PC, restore RAT checkpoint, squash younger speculative state.                                       |
| `commit_recovery` | Stub left for older TBs; idle under early recovery.                                                                                 |


### Execute


| Module        | What it does                                                 |
| ------------- | ------------------------------------------------------------ |
| `alu`         | Integer ALU / LUI / AUIPC. Latency `ALU_STAGES`.             |
| `mul`         | RV32M multiply. Latency `MUL_STAGES`.                        |
| `div`         | RV32M div/rem. Latency `DIV_STAGES`.                         |
| `branch_unit` | Evaluates branches/jumps; reports taken, target, mispredict. |


### Memory


| Module      | What it does                                                                                                                                                                                                     |
| ----------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `lsq`       | OoO load/store queue plus committed store buffer. Loads forward from older LSQ stores and the SB (including partial byte merge). Stores complete into the ROB when they enter the SB; the SB drains to D$ later. |
| `dmem`      | Ideal multi-port data memory for unit tests / ideal mem mode.                                                                                                                                                    |
| `instr_mem` | Ideal instruction memory for ideal I-side mode.                                                                                                                                                                  |


### Cache / DRAM (`rtl/mem/`)


| Module              | What it does                                                   |
| ------------------- | -------------------------------------------------------------- |
| `icache`            | Non-blocking I-cache with MSHRs.                               |
| `dcache`            | Non-blocking D-cache with MSHRs; up to 2 UFP ports.            |
| `mem_arbiter`       | Shares DRAM between I$ and D$ (one grant/cycle, D$ preferred). |
| `dram_model`        | Wrapper selecting simple or banked DRAM.                       |
| `dram_model_simple` | Fixed `DRAM_LAT_CYCLES` line latency (default for studies).    |
| `dram_model_banked` | SDRAM-like open-row timing model.                              |
| `ideal_imem_bridge` | Adapts ideal instr mem to the fetch port when caches are off.  |


### Shared package


| Module    | What it does                                                                                        |
| --------- | --------------------------------------------------------------------------------------------------- |
| `pkg_cpu` | Widths, depths, FU counts, cache/DRAM knobs, opcodes, and the structs that cross module boundaries. |


---

## Salient features

**ROB-tag rename, no PRF.**  
The RAT points at either the ARF or a ROB entry. Completions write the ROB and
broadcast `{tag, data}` on the CDB. Commit copies the value into the ARF and
clears the RAT if it still points at that tag.

**Superscalar bundles.**  
Fetch, decode, rename, dispatch, mem request, and commit are all `WIDTH`-lane.
The CDB is separately sized (`CDB_WIDTH`). Handshake is prefix-based: the
backend can take lanes `0..N-1` and leave the rest held.

**Tomasulo issue.**  
Non-memory ops wait in the RS; memory ops wait in the LSQ. Both wake from the
CDB. Ready ops issue to pipelined FUs or to the data cache.

**Committed store buffer.**  
A store that has ROB commit permission enqueues into an SB FIFO and frees its
LSQ entry immediately (`store_complete`). The ROB can retire without waiting
on D$. The SB drains in order in the background and is not killed by branch
recovery. Loads check older LSQ stores, then the SB, then memory.

**Store-to-load forwarding.**  
Full coverage forwards without a mem read. Partial coverage issues a normal
load and merges forwarded bytes on the response.

**Early branch recovery.**  
When the branch unit reports a mispredict, fetch redirects, the matching RAT
checkpoint is restored, and only instructions younger than that branch are
squashed in ROB/RS/LSQ/FUs. Commit of the branch only trains the predictor; it
does not flush the pipe.

**Cached memory path (default).**  
Split non-blocking I$ and D$ with MSHRs, secondary-miss merge, and a shared
DRAM model. Tagged D-side responses (`mem_id`) so completes can return
out of order. Ideal `dmem`/`instr_mem` remain for bring-up and unit tests.

**ISA scope.**  
RV32IM user integer code only. No CSRs, traps, atomics, or real fences.
Misaligned accesses are not trapped; byte/half masks are handled in the LSQ
word path.

