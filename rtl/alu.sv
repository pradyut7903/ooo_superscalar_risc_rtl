`timescale 1ns/1ps
// ============================================================================
// alu.sv -- Integer ALU functional unit.
//
// Pipelined, throughput-one execution unit for the RV32I ALU operations decoded
// into op_e.  The input carries the decoded uop, its destination ROB tag, and
// already-resolved source values.  The result is returned on a single CDB lane
// after ALU_STAGES cycles.
//
// Immediate forms use uop.imm when uop.src2_is_imm is set.  LUI ignores src1;
// AUIPC uses uop.pc + uop.imm.
// ============================================================================
module alu
  import pkg_cpu::*;
(
  input  logic     clk,
  input  logic     rst,
  input  logic     flush,
  input  logic     squash_en,
  input  rob_tag_t squash_tag,
  input  rob_tag_t rob_head,

  // issue
  input  logic     in_valid,
  output logic     in_ready,
  input  uop_t     in_uop,
  input  rob_tag_t in_tag,
  input  data_t    src1_value,
  input  data_t    src2_value,

  // write-back
  input  logic     cdb_ready,
  output cdb_t     out_cdb
);

  localparam int STAGES = (ALU_STAGES < 1) ? 1 : ALU_STAGES;

  data_t rhs;
  data_t result;

  assign in_ready = cdb_ready;  // output backpressure freezes the whole pipe
  assign rhs      = in_uop.src2_is_imm ? in_uop.imm : src2_value;

  always_comb begin
    unique case (in_uop.op)
      ALU_ADD:   result = src1_value + rhs;
      ALU_SUB:   result = src1_value - rhs;
      ALU_SLL:   result = src1_value << rhs[4:0];
      ALU_SLT:   result = ($signed(src1_value) < $signed(rhs)) ? 32'd1 : 32'd0;
      ALU_SLTU:  result = (src1_value < rhs) ? 32'd1 : 32'd0;
      ALU_XOR:   result = src1_value ^ rhs;
      ALU_SRL:   result = src1_value >> rhs[4:0];
      ALU_SRA:   result = $signed(src1_value) >>> rhs[4:0];
      ALU_OR:    result = src1_value | rhs;
      ALU_AND:   result = src1_value & rhs;
      ALU_LUI:   result = in_uop.imm;
      ALU_AUIPC: result = in_uop.pc + in_uop.imm;
      default:   result = '0;
    endcase
  end

  logic     pipe_valid [STAGES];
  rob_tag_t pipe_tag   [STAGES];
  data_t    pipe_data  [STAGES];

  wire issue_ok = !(squash_en && rob_is_younger(rob_head, in_tag, squash_tag));
  wire issue_fire = in_valid && in_ready && issue_ok && (in_uop.fu == FU_ALU) &&
                    in_uop.rd_used && (in_uop.op != UOP_NOP);

  always_ff @(posedge clk) begin
    if (rst || flush) begin
      for (int i = 0; i < STAGES; i++) begin
        pipe_valid[i] <= 1'b0;
        pipe_tag[i]   <= '0;
        pipe_data[i]  <= '0;
      end
    end else if (cdb_ready) begin
      pipe_valid[0] <= issue_fire;
      pipe_tag[0]   <= in_tag;
      pipe_data[0]  <= result;

      for (int i = 1; i < STAGES; i++) begin
        pipe_valid[i] <= pipe_valid[i-1];
        pipe_tag[i]   <= pipe_tag[i-1];
        pipe_data[i]  <= pipe_data[i-1];
      end

      if (squash_en) begin
        for (int i = 0; i < STAGES; i++) begin
          if (pipe_valid[i] && rob_is_younger(rob_head, pipe_tag[i], squash_tag))
            pipe_valid[i] <= 1'b0;
          if (i == 0 && issue_fire && rob_is_younger(rob_head, in_tag, squash_tag))
            pipe_valid[0] <= 1'b0;
        end
      end
    end else if (squash_en) begin
      for (int i = 0; i < STAGES; i++) begin
        if (pipe_valid[i] && rob_is_younger(rob_head, pipe_tag[i], squash_tag))
          pipe_valid[i] <= 1'b0;
      end
    end
  end

  assign out_cdb.valid = pipe_valid[STAGES-1] &&
      !(squash_en && rob_is_younger(rob_head, pipe_tag[STAGES-1], squash_tag));
  assign out_cdb.tag   = pipe_tag[STAGES-1];
  assign out_cdb.data  = pipe_data[STAGES-1];

endmodule
