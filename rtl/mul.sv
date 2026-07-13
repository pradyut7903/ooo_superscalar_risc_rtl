`timescale 1ns/1ps
// ============================================================================
// mul.sv -- RV32M multiply functional unit.
// ============================================================================
module mul
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
  output cdb_t     out_cdb
);

  localparam int STAGES = (MUL_STAGES < 1) ? 1 : MUL_STAGES;

  data_t result;

  assign in_ready = cdb_ready;

  always_comb begin
    logic [63:0]        prod_uu;
    logic signed [63:0] prod_ss;
    logic signed [65:0] prod_su;

    prod_uu = src1_value * src2_value;
    prod_ss = $signed(src1_value) * $signed(src2_value);
    prod_su = $signed({src1_value[31], src1_value}) *
              $signed({1'b0, src2_value});

    unique case (in_uop.op)
      MD_MUL:    result = prod_uu[31:0];
      MD_MULH:   result = prod_ss[63:32];
      MD_MULHSU: result = prod_su[63:32];
      MD_MULHU:  result = prod_uu[63:32];
      default:   result = '0;
    endcase
  end

  logic     pipe_valid [STAGES];
  rob_tag_t pipe_tag   [STAGES];
  data_t    pipe_data  [STAGES];

  wire issue_ok = !(squash_en && rob_is_younger(rob_head, in_tag, squash_tag));
  wire issue_fire = in_valid && in_ready && issue_ok && (in_uop.fu == FU_MUL) && in_uop.rd_used &&
                    ((in_uop.op == MD_MUL) || (in_uop.op == MD_MULH) ||
                     (in_uop.op == MD_MULHSU) || (in_uop.op == MD_MULHU));

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
