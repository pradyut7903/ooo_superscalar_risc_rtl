# rtl_v2 Structure Sizing Study

- Started: 2026-07-12 22:40:40 UTC
- Elapsed: 429.1 min
- Status: COMPLETE
- Machine class held fixed: `WIDTH=4`, baseline `CDB_WIDTH=4`
- Memory: `MEM_SYSTEM_CACHED`, `**DRAM_MODEL_SIMPLE**` (pinned; baseline file DRAM_MODEL=0, SIMPLE=0)
- Geomean IPC over study suite (`branch`, `custom_riscv`, `riscv_mem`, `ilp_loop`, `matmul8`, `mem_stream`, `mix_bench`)
-  Big-6 geomean (`custom_riscv`, `riscv_mem`, `ilp_loop`, `matmul8`, `mem_stream`, `mix_bench`)

## Method

1. **Baseline** — checked-in `pkg_cpu.sv` (with DRAM pinned SIMPLE).
2. **One-at-a-time (OAT)** — each meaningful knob swept independently.
3. **Coordinate ascent** — walk axes by OAT sensitivity; accept improving values.

`pkg_cpu.sv` is restored after the study. Raw rows: `sizing/verif_ipc_sizing.csv`, checkpoint `sizing/verif_ipc_sizing.json`.

## Baseline

- Study geomean: **0.522264**
- Big-6 geomean: **0.539857**


| Program      | IPC      | Cycles | Commits | D$ miss |
| ------------ | -------- | ------ | ------- | ------- |
| branch       | 0.428109 | 19154  | 8200    | 0       |
| custom_riscv | 0.493518 | 26151  | 12906   | 26      |
| riscv_mem    | 0.539840 | 16579  | 8950    | 26      |
| ilp_loop     | 0.665492 | 61562  | 40969   | 0       |
| matmul8      | 0.568174 | 13693  | 7780    | 24      |
| mem_stream   | 0.597107 | 165076 | 98568   | 32      |
| mix_bench    | 0.411557 | 114854 | 47269   | 16      |


## OAT summary (best value per axis)


| Axis               | Baseline | Best | Best study geo | Δ vs baseline |
| ------------------ | -------- | ---- | -------------- | ------------- |
| `CACHE_LINE_BYTES` | 32       | 64   | 0.544648       | +0.022384     |
| `MUL_STAGES`       | 3        | 2    | 0.530375       | +0.008112     |
| `PHT_SIZE`         | 1024     | 256  | 0.522850       | +0.000586     |
| `DRAM_LAT_CYCLES`  | 10       | 5    | 0.522746       | +0.000482     |
| `NUM_ALU`          | 2        | 3    | 0.522282       | +0.000018     |
| `ROB_DEPTH`        | 32       | 16   | 0.522264       | +0.000000     |
| `RS_DEPTH`         | 32       | 16   | 0.522264       | +0.000000     |
| `LSQ_DEPTH`        | 32       | 16   | 0.522264       | +0.000000     |
| `IFQ_DEPTH`        | 32       | 8    | 0.522264       | +0.000000     |
| `STORE_BUF_DEPTH`  | 8        | 4    | 0.522264       | +0.000000     |
| `CDB_WIDTH`        | 4        | 2    | 0.522264       | +0.000000     |
| `NUM_MUL`          | 1        | 1    | 0.522264       | +0.000000     |
| `NUM_DIV`          | 1        | 1    | 0.522264       | +0.000000     |
| `NUM_LSQ`          | 2        | 2    | 0.522264       | +0.000000     |
| `DIV_STAGES`       | 10       | 5    | 0.522264       | +0.000000     |
| `BTB_SIZE`         | 256      | 64   | 0.522264       | +0.000000     |
| `DCACHE_SETS`      | 16       | 8    | 0.522264       | +0.000000     |
| `DCACHE_WAYS`      | 4        | 2    | 0.522264       | +0.000000     |
| `ICACHE_SETS`      | 16       | 8    | 0.522264       | +0.000000     |
| `ICACHE_WAYS`      | 4        | 2    | 0.522264       | +0.000000     |
| `DCACHE_MSHR`      | 4        | 2    | 0.522264       | +0.000000     |
| `ICACHE_MSHR`      | 2        | 1    | 0.522264       | +0.000000     |
| `DRAM_OUTSTANDING` | 4        | 2    | 0.522264       | +0.000000     |
| `DCACHE_UFP_PORTS` | 2        | 2    | 0.522264       | +0.000000     |
| `MSHR_WAITERS`     | 4        | 2    | 0.522264       | +0.000000     |


## OAT detail

### `ROB_DEPTH`


| Value | Study geomean   |
| ----- | --------------- |
| 16    | 0.522264 ← best |
| 32    | 0.522264        |
| 64    | 0.522264        |
| 128   | 0.522264        |


### `RS_DEPTH`


| Value | Study geomean   |
| ----- | --------------- |
| 16    | 0.522264 ← best |
| 32    | 0.522264        |
| 64    | 0.522264        |
| 128   | 0.522264        |


### `LSQ_DEPTH`


| Value | Study geomean   |
| ----- | --------------- |
| 16    | 0.522264 ← best |
| 32    | 0.522264        |
| 64    | 0.522264        |


### `IFQ_DEPTH`


| Value | Study geomean   |
| ----- | --------------- |
| 8     | 0.522264 ← best |
| 16    | 0.522264        |
| 32    | 0.522264        |
| 64    | 0.522264        |


### `STORE_BUF_DEPTH`


| Value | Study geomean   |
| ----- | --------------- |
| 4     | 0.522264 ← best |
| 8     | 0.522264        |
| 16    | 0.522264        |
| 32    | 0.522264        |


### `CDB_WIDTH`


| Value | Study geomean   |
| ----- | --------------- |
| 2     | 0.522264 ← best |
| 3     | 0.522264        |
| 4     | 0.522264        |
| 6     | 0.522264        |


### `NUM_ALU`


| Value | Study geomean   |
| ----- | --------------- |
| 3     | 0.522282 ← best |
| 4     | 0.522282        |
| 2     | 0.522264        |
| 1     | 0.522157        |


### `NUM_MUL`


| Value | Study geomean   |
| ----- | --------------- |
| 1     | 0.522264 ← best |
| 2     | 0.522264        |


### `NUM_DIV`


| Value | Study geomean   |
| ----- | --------------- |
| 1     | 0.522264 ← best |
| 2     | 0.522264        |


### `NUM_LSQ`


| Value | Study geomean   |
| ----- | --------------- |
| 2     | 0.522264 ← best |
| 1     | 0.522258        |


### `MUL_STAGES`


| Value | Study geomean   |
| ----- | --------------- |
| 2     | 0.530375 ← best |
| 3     | 0.522264        |
| 4     | 0.522264        |


### `DIV_STAGES`


| Value | Study geomean   |
| ----- | --------------- |
| 5     | 0.522264 ← best |
| 10    | 0.522264        |
| 15    | 0.522264        |


### `PHT_SIZE`


| Value | Study geomean   |
| ----- | --------------- |
| 256   | 0.522850 ← best |
| 512   | 0.522537        |
| 1024  | 0.522264        |
| 2048  | 0.521931        |


### `BTB_SIZE`


| Value | Study geomean   |
| ----- | --------------- |
| 64    | 0.522264 ← best |
| 128   | 0.522264        |
| 256   | 0.522264        |
| 512   | 0.522264        |


### `CACHE_LINE_BYTES`


| Value | Study geomean   |
| ----- | --------------- |
| 64    | 0.544648 ← best |
| 32    | 0.522264        |
| 16    | 0.520960        |


### `DCACHE_SETS`


| Value | Study geomean   |
| ----- | --------------- |
| 8     | 0.522264 ← best |
| 16    | 0.522264        |
| 32    | 0.522264        |
| 64    | 0.522264        |


### `DCACHE_WAYS`


| Value | Study geomean   |
| ----- | --------------- |
| 2     | 0.522264 ← best |
| 4     | 0.522264        |
| 8     | 0.522264        |


### `ICACHE_SETS`


| Value | Study geomean   |
| ----- | --------------- |
| 8     | 0.522264 ← best |
| 16    | 0.522264        |
| 32    | 0.522264        |
| 64    | 0.522264        |


### `ICACHE_WAYS`


| Value | Study geomean   |
| ----- | --------------- |
| 2     | 0.522264 ← best |
| 4     | 0.522264        |
| 8     | 0.522264        |


### `DCACHE_MSHR`


| Value | Study geomean   |
| ----- | --------------- |
| 2     | 0.522264 ← best |
| 4     | 0.522264        |
| 8     | 0.522264        |


### `ICACHE_MSHR`


| Value | Study geomean   |
| ----- | --------------- |
| 1     | 0.522264 ← best |
| 2     | 0.522264        |
| 4     | 0.522264        |


### `DRAM_OUTSTANDING`


| Value | Study geomean   |
| ----- | --------------- |
| 2     | 0.522264 ← best |
| 4     | 0.522264        |
| 8     | 0.522264        |


### `DCACHE_UFP_PORTS`


| Value | Study geomean   |
| ----- | --------------- |
| 2     | 0.522264 ← best |
| 1     | 0.515439        |


### `MSHR_WAITERS`


| Value | Study geomean   |
| ----- | --------------- |
| 2     | 0.522264 ← best |
| 4     | 0.522264        |
| 8     | 0.522264        |


### `DRAM_LAT_CYCLES`


| Value | Study geomean   |
| ----- | --------------- |
| 5     | 0.522746 ← best |
| 10    | 0.522264        |
| 40    | 0.517867        |
| 20    | 0.513882        |


## Coordinate ascent log


| Step  | Round | Axis               | Try  | Accepted | Study geo | Big-6 geo | Config                                                     |
| ----- | ----- | ------------------ | ---- | -------- | --------- | --------- | ---------------------------------------------------------- |
| start | -     | -                  | -    | -        | 0.522264  | 0.539857  | (baseline)                                                 |
| 1     | 1     | `CACHE_LINE_BYTES` | 64   | no       | 0.544648  | 0.571515  | CACHE_LINE_BYTES=64                                        |
| 2     | 1     | `MUL_STAGES`       | 2    | yes      | 0.530375  | 0.549652  | MUL_STAGES=2                                               |
| 3     | 1     | `MUL_STAGES`       | 3    | no       | 0.522264  | 0.539857  | (baseline)                                                 |
| 4     | 1     | `PHT_SIZE`         | 256  | yes      | 0.530909  | 0.550216  | MUL_STAGES=2, PHT_SIZE=256                                 |
| 5     | 1     | `PHT_SIZE`         | 512  | no       | 0.530657  | 0.549936  | MUL_STAGES=2, PHT_SIZE=512                                 |
| 6     | 1     | `PHT_SIZE`         | 1024 | no       | 0.530375  | 0.549652  | MUL_STAGES=2                                               |
| 7     | 1     | `NUM_ALU`          | 3    | yes      | 0.530926  | 0.550231  | MUL_STAGES=2, NUM_ALU=3, PHT_SIZE=256                      |
| 8     | 1     | `NUM_ALU`          | 4    | no       | 0.530926  | 0.550231  | MUL_STAGES=2, NUM_ALU=4, PHT_SIZE=256                      |
| 9     | 1     | `STORE_BUF_DEPTH`  | 4    | no       | 0.530926  | 0.550231  | MUL_STAGES=2, NUM_ALU=3, PHT_SIZE=256, STORE_BUF_DEPTH=4   |
| 10    | 1     | `RS_DEPTH`         | 16   | no       | 0.530926  | 0.550231  | MUL_STAGES=2, NUM_ALU=3, PHT_SIZE=256, RS_DEPTH=16         |
| 11    | 1     | `ROB_DEPTH`        | 16   | no       | 0.530926  | 0.550231  | MUL_STAGES=2, NUM_ALU=3, PHT_SIZE=256, ROB_DEPTH=16        |
| 12    | 1     | `NUM_MUL`          | 2    | no       | 0.530926  | 0.550231  | MUL_STAGES=2, NUM_ALU=3, NUM_MUL=2, PHT_SIZE=256           |
| 13    | 1     | `NUM_LSQ`          | 1    | no       | 0.530919  | 0.550224  | MUL_STAGES=2, NUM_ALU=3, NUM_LSQ=1, PHT_SIZE=256           |
| 14    | 1     | `NUM_DIV`          | 2    | no       | 0.530926  | 0.550231  | MUL_STAGES=2, NUM_ALU=3, NUM_DIV=2, PHT_SIZE=256           |
| 15    | 1     | `MSHR_WAITERS`     | 2    | no       | 0.530926  | 0.550231  | MSHR_WAITERS=2, MUL_STAGES=2, NUM_ALU=3, PHT_SIZE=256      |
| 16    | 1     | `LSQ_DEPTH`        | 16   | no       | 0.530926  | 0.550231  | LSQ_DEPTH=16, MUL_STAGES=2, NUM_ALU=3, PHT_SIZE=256        |
| 17    | 1     | `IFQ_DEPTH`        | 8    | no       | 0.530926  | 0.550231  | IFQ_DEPTH=8, MUL_STAGES=2, NUM_ALU=3, PHT_SIZE=256         |
| 18    | 1     | `IFQ_DEPTH`        | 16   | no       | 0.530926  | 0.550231  | IFQ_DEPTH=16, MUL_STAGES=2, NUM_ALU=3, PHT_SIZE=256        |
| 19    | 1     | `ICACHE_WAYS`      | 2    | no       | 0.530926  | 0.550231  | ICACHE_WAYS=2, MUL_STAGES=2, NUM_ALU=3, PHT_SIZE=256       |
| 20    | 1     | `ICACHE_SETS`      | 8    | no       | 0.530926  | 0.550231  | ICACHE_SETS=8, MUL_STAGES=2, NUM_ALU=3, PHT_SIZE=256       |
| 21    | 1     | `ICACHE_MSHR`      | 1    | no       | 0.530926  | 0.550231  | ICACHE_MSHR=1, MUL_STAGES=2, NUM_ALU=3, PHT_SIZE=256       |
| 22    | 1     | `DRAM_OUTSTANDING` | 2    | no       | 0.530926  | 0.550231  | DRAM_OUTSTANDING=2, MUL_STAGES=2, NUM_ALU=3, PHT_SIZE=256  |
| 23    | 1     | `DIV_STAGES`       | 5    | no       | 0.530926  | 0.550231  | DIV_STAGES=5, MUL_STAGES=2, NUM_ALU=3, PHT_SIZE=256        |
| 24    | 1     | `DCACHE_WAYS`      | 2    | no       | 0.530926  | 0.550231  | DCACHE_WAYS=2, MUL_STAGES=2, NUM_ALU=3, PHT_SIZE=256       |
| 25    | 1     | `DCACHE_UFP_PORTS` | 1    | no       | 0.523919  | 0.541769  | DCACHE_UFP_PORTS=1, MUL_STAGES=2, NUM_ALU=3, PHT_SIZE=256  |
| 26    | 1     | `DCACHE_SETS`      | 8    | no       | 0.530926  | 0.550231  | DCACHE_SETS=8, MUL_STAGES=2, NUM_ALU=3, PHT_SIZE=256       |
| 27    | 1     | `DCACHE_MSHR`      | 2    | no       | 0.530926  | 0.550231  | DCACHE_MSHR=2, MUL_STAGES=2, NUM_ALU=3, PHT_SIZE=256       |
| 28    | 1     | `CDB_WIDTH`        | 2    | no       | 0.530921  | 0.550231  | CDB_WIDTH=2, MUL_STAGES=2, NUM_ALU=3, PHT_SIZE=256         |
| 29    | 1     | `CDB_WIDTH`        | 3    | no       | 0.530926  | 0.550231  | CDB_WIDTH=3, MUL_STAGES=2, NUM_ALU=3, PHT_SIZE=256         |
| 30    | 1     | `BTB_SIZE`         | 64   | no       | 0.530926  | 0.550231  | BTB_SIZE=64, MUL_STAGES=2, NUM_ALU=3, PHT_SIZE=256         |
| 31    | 1     | `BTB_SIZE`         | 128  | no       | 0.530926  | 0.550231  | BTB_SIZE=128, MUL_STAGES=2, NUM_ALU=3, PHT_SIZE=256        |
| 32    | 2     | `CACHE_LINE_BYTES` | 64   | no       | 0.555106  | 0.584600  | CACHE_LINE_BYTES=64, MUL_STAGES=2, NUM_ALU=3, PHT_SIZE=256 |
| 33    | 2     | `MUL_STAGES`       | 3    | no       | 0.522866  | 0.540499  | NUM_ALU=3, PHT_SIZE=256                                    |
| 34    | 2     | `PHT_SIZE`         | 512  | no       | 0.530675  | 0.549952  | MUL_STAGES=2, NUM_ALU=3, PHT_SIZE=512                      |
| 35    | 2     | `PHT_SIZE`         | 1024 | no       | 0.530394  | 0.549670  | MUL_STAGES=2, NUM_ALU=3                                    |
| 36    | 2     | `NUM_ALU`          | 2    | no       | 0.530909  | 0.550216  | MUL_STAGES=2, PHT_SIZE=256                                 |
| 37    | 2     | `NUM_ALU`          | 4    | no       | 0.530926  | 0.550231  | MUL_STAGES=2, NUM_ALU=4, PHT_SIZE=256                      |
| 38    | 2     | `STORE_BUF_DEPTH`  | 4    | no       | 0.530926  | 0.550231  | MUL_STAGES=2, NUM_ALU=3, PHT_SIZE=256, STORE_BUF_DEPTH=4   |
| 39    | 2     | `RS_DEPTH`         | 16   | no       | 0.530926  | 0.550231  | MUL_STAGES=2, NUM_ALU=3, PHT_SIZE=256, RS_DEPTH=16         |
| 40    | 2     | `ROB_DEPTH`        | 16   | no       | 0.530926  | 0.550231  | MUL_STAGES=2, NUM_ALU=3, PHT_SIZE=256, ROB_DEPTH=16        |
| 41    | 2     | `NUM_MUL`          | 2    | no       | 0.530926  | 0.550231  | MUL_STAGES=2, NUM_ALU=3, NUM_MUL=2, PHT_SIZE=256           |
| 42    | 2     | `NUM_LSQ`          | 1    | no       | 0.530919  | 0.550224  | MUL_STAGES=2, NUM_ALU=3, NUM_LSQ=1, PHT_SIZE=256           |
| 43    | 2     | `NUM_DIV`          | 2    | no       | 0.530926  | 0.550231  | MUL_STAGES=2, NUM_ALU=3, NUM_DIV=2, PHT_SIZE=256           |
| 44    | 2     | `MSHR_WAITERS`     | 2    | no       | 0.530926  | 0.550231  | MSHR_WAITERS=2, MUL_STAGES=2, NUM_ALU=3, PHT_SIZE=256      |
| 45    | 2     | `LSQ_DEPTH`        | 16   | no       | 0.530926  | 0.550231  | LSQ_DEPTH=16, MUL_STAGES=2, NUM_ALU=3, PHT_SIZE=256        |
| 46    | 2     | `IFQ_DEPTH`        | 8    | no       | 0.530926  | 0.550231  | IFQ_DEPTH=8, MUL_STAGES=2, NUM_ALU=3, PHT_SIZE=256         |
| 47    | 2     | `IFQ_DEPTH`        | 16   | no       | 0.530926  | 0.550231  | IFQ_DEPTH=16, MUL_STAGES=2, NUM_ALU=3, PHT_SIZE=256        |
| 48    | 2     | `ICACHE_WAYS`      | 2    | no       | 0.530926  | 0.550231  | ICACHE_WAYS=2, MUL_STAGES=2, NUM_ALU=3, PHT_SIZE=256       |
| 49    | 2     | `ICACHE_SETS`      | 8    | no       | 0.530926  | 0.550231  | ICACHE_SETS=8, MUL_STAGES=2, NUM_ALU=3, PHT_SIZE=256       |
| 50    | 2     | `ICACHE_MSHR`      | 1    | no       | 0.530926  | 0.550231  | ICACHE_MSHR=1, MUL_STAGES=2, NUM_ALU=3, PHT_SIZE=256       |
| 51    | 2     | `DRAM_OUTSTANDING` | 2    | no       | 0.530926  | 0.550231  | DRAM_OUTSTANDING=2, MUL_STAGES=2, NUM_ALU=3, PHT_SIZE=256  |
| 52    | 2     | `DIV_STAGES`       | 5    | no       | 0.530926  | 0.550231  | DIV_STAGES=5, MUL_STAGES=2, NUM_ALU=3, PHT_SIZE=256        |
| 53    | 2     | `DCACHE_WAYS`      | 2    | no       | 0.530926  | 0.550231  | DCACHE_WAYS=2, MUL_STAGES=2, NUM_ALU=3, PHT_SIZE=256       |
| 54    | 2     | `DCACHE_UFP_PORTS` | 1    | no       | 0.523919  | 0.541769  | DCACHE_UFP_PORTS=1, MUL_STAGES=2, NUM_ALU=3, PHT_SIZE=256  |
| 55    | 2     | `DCACHE_SETS`      | 8    | no       | 0.530926  | 0.550231  | DCACHE_SETS=8, MUL_STAGES=2, NUM_ALU=3, PHT_SIZE=256       |
| 56    | 2     | `DCACHE_MSHR`      | 2    | no       | 0.530926  | 0.550231  | DCACHE_MSHR=2, MUL_STAGES=2, NUM_ALU=3, PHT_SIZE=256       |
| 57    | 2     | `CDB_WIDTH`        | 2    | no       | 0.530921  | 0.550231  | CDB_WIDTH=2, MUL_STAGES=2, NUM_ALU=3, PHT_SIZE=256         |
| 58    | 2     | `CDB_WIDTH`        | 3    | no       | 0.530926  | 0.550231  | CDB_WIDTH=3, MUL_STAGES=2, NUM_ALU=3, PHT_SIZE=256         |
| 59    | 2     | `BTB_SIZE`         | 64   | no       | 0.530926  | 0.550231  | BTB_SIZE=64, MUL_STAGES=2, NUM_ALU=3, PHT_SIZE=256         |
| 60    | 2     | `BTB_SIZE`         | 128  | no       | 0.530926  | 0.550231  | BTB_SIZE=128, MUL_STAGES=2, NUM_ALU=3, PHT_SIZE=256        |


## Best configuration

- Study geomean: **0.530926**
- Overrides vs checked-in baseline: `MUL_STAGES=2, NUM_ALU=3, PHT_SIZE=256`


| Param        | Baseline | Best |
| ------------ | -------- | ---- |
| `MUL_STAGES` | 3        | 2    |
| `NUM_ALU`    | 2        | 3    |
| `PHT_SIZE`   | 1024     | 256  |


## Notes

- `WIDTH` intentionally not swept (defines the machine class).
- Banked DRAM timings not swept; backend pinned to `DRAM_MODEL_SIMPLE`.
- `DRAM_LAT_CYCLES` is swept in OAT for sensitivity but best structure selection prefers other axes via ascent (latency left at baseline unless ascent accepts it — excluded from ASCENT_AXES).
- `RAS_DEPTH` unused in RTL; not swept.

