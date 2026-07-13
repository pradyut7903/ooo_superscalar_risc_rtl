`timescale 1ns/1ps
// ============================================================================
// id_rn_reg.sv -- Pipeline register between decode and rename/dispatch.
//
// Decode is combinational.  This register captures the decoded uop and attaches
// the prediction metadata carried by IF/ID.
// ============================================================================
module id_rn_reg
  import pkg_cpu::*;
(
  input  logic clk,
  input  logic rst,
  input  logic flush,

  input  logic in_valid,
  output logic in_ready,
  input  uop_t in_uop,
  input  logic in_pred_taken,
  input  pc_t  in_pred_target,

  output logic out_valid,
  input  logic out_ready,
  output uop_t out_uop
);

  logic advance;
  uop_t next_uop;

  assign advance = out_ready || !out_valid;
  assign in_ready = advance;

  always_comb begin
    next_uop = in_uop;
    next_uop.pred_taken  = in_pred_taken;
    next_uop.pred_target = in_pred_target;
  end

  always_ff @(posedge clk) begin
    if (rst || flush) begin
      out_valid <= 1'b0;
      out_uop   <= '0;
      out_uop.op <= UOP_NOP;
      out_uop.fu <= FU_ALU;
    end else if (advance) begin
      out_valid <= in_valid;
      out_uop   <= next_uop;
    end
  end

endmodule
