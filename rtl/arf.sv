`timescale 1ns/1ps
// ============================================================================
// arf.sv -- Architectural Register File (x0..x31, x0 hardwired 0).
//
// The committed register state: written only at commit, read by operand-resolve
// during rename.  Built as a flip-flop array (NOT BRAM) because it needs several
// combinational read ports in the same cycle plus WIDTH synchronous commit
// writes.
//
// Reads are combinational (asynchronous); the write is synchronous.  x0 always
// reads 0 and is never written.  No internal write->read bypass: a value written
// this cycle becomes visible to reads next cycle.  (The rename/commit protocol
// accounts for this -- an in-flight producer is read from the ROB by tag, not
// the ARF, so a just-committed value is never needed from the ARF same-cycle.)
// ============================================================================
module arf
  import pkg_cpu::*;
(
  input  logic     clk,
  input  logic     rst,

  // combinational read ports (operand-resolve)
  input  reg_idx_t raddr1 [WIDTH],
  output data_t    rdata1 [WIDTH],
  input  reg_idx_t raddr2 [WIDTH],
  output data_t    rdata2 [WIDTH],

  // synchronous write ports (commit)
  input  valid_bundle_t wen,
  input  reg_idx_t      waddr [WIDTH],
  input  data_t         wdata [WIDTH]
);

  data_t regs [NUM_REGS];

  // combinational reads; x0 reads as 0
  always_comb begin
    for (int lane = 0; lane < WIDTH; lane++) begin
      rdata1[lane] = (raddr1[lane] == '0) ? '0 : regs[raddr1[lane]];
      rdata2[lane] = (raddr2[lane] == '0) ? '0 : regs[raddr2[lane]];
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      for (int i = 0; i < NUM_REGS; i++) regs[i] <= '0;
    end else begin
      for (int lane = 0; lane < WIDTH; lane++) begin
        if (wen[lane] && (waddr[lane] != '0)) begin
          regs[waddr[lane]] <= wdata[lane];
        end
      end
      regs[0] <= '0;
    end
  end

endmodule
