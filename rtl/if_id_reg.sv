`timescale 1ns/1ps
// ============================================================================
// if_id_reg.sv -- Pipeline register between fetch and decode.
// ============================================================================
module if_id_reg
  import pkg_cpu::*;
(
  input  logic   clk,
  input  logic   rst,
  input  logic   flush,

  input  logic   in_valid,
  output logic   in_ready,
  input  pc_t    in_pc,
  input  instr_t in_instr,
  input  logic   in_pred_taken,
  input  pc_t    in_pred_target,

  output logic   out_valid,
  input  logic   out_ready,
  output pc_t    out_pc,
  output instr_t out_instr,
  output logic   out_pred_taken,
  output pc_t    out_pred_target
);

  logic advance;

  assign advance = out_ready || !out_valid;
  assign in_ready = advance;

  always_ff @(posedge clk) begin
    if (rst || flush) begin
      out_valid       <= 1'b0;
      out_pc          <= '0;
      out_instr       <= INSTR_INVALID;
      out_pred_taken  <= 1'b0;
      out_pred_target <= '0;
    end else if (advance) begin
      out_valid       <= in_valid;
      out_pc          <= in_pc;
      out_instr       <= in_instr;
      out_pred_taken  <= in_pred_taken;
      out_pred_target <= in_pred_target;
    end
  end

endmodule
