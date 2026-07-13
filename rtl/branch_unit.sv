`timescale 1ns/1ps
// ============================================================================
// branch_unit.sv -- Branch/jump execution unit.
//
// Resolves conditional branches and jumps on a dedicated ROB sideband.
// JAL/JALR also produce the link value (pc + 4) on the CDB when rd_used is set.
// ============================================================================
module branch_unit
  import pkg_cpu::*;
(
  input  logic     clk,
  input  logic     rst,
  input  logic     flush,
  input  logic     squash_en,
  input  rob_tag_t squash_tag,
  input  rob_tag_t rob_head,

  input  logic     in_valid,
  output logic     in_ready,
  input  uop_t     in_uop,
  input  rob_tag_t in_tag,
  input  data_t    src1_value,
  input  data_t    src2_value,

  input  logic     cdb_ready,
  output cdb_t     out_cdb,

  output logic     br_valid,
  output rob_tag_t br_tag,
  output logic     br_taken,
  output pc_t      br_target,
  output logic     br_mispredict,
  output logic     br_resolve_valid,
  output rob_tag_t br_resolve_tag,
  output pc_t      br_redirect_pc,

  output logic     complete_valid,
  output rob_tag_t complete_tag
);

  logic  is_br_op;
  logic  is_jump_op;
  logic  needs_link;
  logic  taken;
  pc_t   target;
  data_t link_value;
  logic  holding_cdb;

  assign is_jump_op = (in_uop.op == BR_JAL) || (in_uop.op == BR_JALR);
  assign is_br_op = (in_uop.op == BR_EQ) || (in_uop.op == BR_NE) ||
                    (in_uop.op == BR_LT) || (in_uop.op == BR_GE) ||
                    (in_uop.op == BR_LTU) || (in_uop.op == BR_GEU) ||
                    is_jump_op;
  assign needs_link = is_jump_op && in_uop.rd_used;
  assign link_value = in_uop.pc + 32'd4;

  assign holding_cdb = out_cdb.valid && !cdb_ready;
  assign in_ready = !holding_cdb;

  always_comb begin
    unique case (in_uop.op)
      BR_EQ:   taken = (src1_value == src2_value);
      BR_NE:   taken = (src1_value != src2_value);
      BR_LT:   taken = ($signed(src1_value) < $signed(src2_value));
      BR_GE:   taken = ($signed(src1_value) >= $signed(src2_value));
      BR_LTU:  taken = (src1_value < src2_value);
      BR_GEU:  taken = (src1_value >= src2_value);
      BR_JAL,
      BR_JALR: taken = 1'b1;
      default: taken = 1'b0;
    endcase

    if (in_uop.op == BR_JALR) target = (src1_value + in_uop.imm) & 32'hFFFF_FFFE;
    else                      target = in_uop.pc + in_uop.imm;
  end

  wire issue_ok = !(squash_en && rob_is_younger(rob_head, in_tag, squash_tag));
  wire issue_fire = in_valid && in_ready && issue_ok && (in_uop.fu == FU_BR) && is_br_op;

  always_ff @(posedge clk) begin
    if (rst || flush) begin
      out_cdb.valid <= 1'b0;
      out_cdb.tag   <= '0;
      out_cdb.data  <= '0;
      br_valid      <= 1'b0;
      br_tag        <= '0;
      br_taken      <= 1'b0;
      br_target     <= '0;
      br_mispredict <= 1'b0;
      br_resolve_valid <= 1'b0;
      br_resolve_tag   <= '0;
      br_redirect_pc   <= '0;
      complete_valid <= 1'b0;
      complete_tag   <= '0;
    end else if (squash_en && out_cdb.valid &&
                 rob_is_younger(rob_head, out_cdb.tag, squash_tag)) begin
      out_cdb.valid <= 1'b0;
      br_valid <= 1'b0;
      br_mispredict <= 1'b0;
      br_resolve_valid <= 1'b0;
      complete_valid <= 1'b0;
    end else if (holding_cdb) begin
      // Hold link CDB until arbiter accepts.
    end else if (issue_fire) begin
      out_cdb.valid <= needs_link;
      out_cdb.tag   <= in_tag;
      out_cdb.data  <= link_value;

      br_valid      <= 1'b1;
      br_tag        <= in_tag;
      br_taken      <= taken;
      br_target     <= taken ? target : (in_uop.pc + 32'd4);
      br_mispredict <= (taken != in_uop.pred_taken) ||
                       (taken && (target != in_uop.pred_target));
      br_resolve_valid <= 1'b1;
      br_resolve_tag   <= in_tag;
      br_redirect_pc   <= taken ? target : (in_uop.pc + 32'd4);
      complete_valid <= 1'b1;
      complete_tag   <= in_tag;
    end else begin
      out_cdb.valid <= 1'b0;
      br_valid <= 1'b0;
      br_mispredict <= 1'b0;
      br_resolve_valid <= 1'b0;
      complete_valid <= 1'b0;
    end
  end

endmodule
