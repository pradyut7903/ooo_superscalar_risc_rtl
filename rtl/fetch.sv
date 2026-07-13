`timescale 1ns/1ps
// ============================================================================
// fetch.sv -- In-order bundle fetch with variable-latency IMEM.
//
// PC advances on response (not request) so line-boundary truncations do not
// skip instructions. imem_resp_count is the number of in-line words; invalid
// within that window is end-of-program.
// ============================================================================
module fetch
  import pkg_cpu::*;
(
  input  logic clk,
  input  logic rst,

  input  logic redirect_valid,
  input  pc_t  redirect_pc,

  input  valid_bundle_t pred_taken,
  input  pc_bundle_t    pred_target,

  output logic          imem_req_valid,
  input  logic          imem_req_ready,
  output pc_t           imem_req_pc,
  input  logic          imem_resp_valid,
  input  valid_bundle_t imem_resp_word_valid,
  input  instr_bundle_t imem_resp_word,
  input  pc_bundle_t    imem_resp_pc,
  input  logic [$clog2(WIDTH+1)-1:0] imem_resp_count,

  output pc_bundle_t    pred_lookup_pc,

  output logic [$clog2(WIDTH+1)-1:0] out_count,
  output logic                       out_valid,
  output logic                       out_eop,
  output pc_bundle_t                 out_pc,
  output instr_bundle_t              out_instr,
  output valid_bundle_t              out_pred_taken,
  output pc_bundle_t                 out_pred_target,
  input  logic                       out_ready
);

  pc_t  pc_q;
  logic stopped;
  logic req_outstanding;

  valid_bundle_t req_pred_taken;
  pc_bundle_t    req_pred_target;

  logic                       buf_valid;
  logic                       buf_eop;
  logic [$clog2(WIDTH+1)-1:0] buf_count;
  pc_bundle_t                 buf_pc;
  instr_bundle_t              buf_instr;
  valid_bundle_t              buf_pred_taken;
  pc_bundle_t                 buf_pred_target;

  logic can_request;
  logic fire_req;

  always_comb begin
    for (int i = 0; i < WIDTH; i++) begin
      pred_lookup_pc[i] = pc_q + pc_t'(4 * i);
    end
  end

  assign can_request = !stopped && !req_outstanding && !buf_valid;
  assign imem_req_valid = can_request;
  assign imem_req_pc = pc_q;
  assign fire_req = imem_req_valid && imem_req_ready;

  assign out_valid = buf_valid && (buf_count != '0);
  assign out_eop = buf_valid && buf_eop;
  assign out_count = buf_valid ? buf_count : '0;
  assign out_pc = buf_pc;
  assign out_instr = buf_instr;
  assign out_pred_taken = buf_pred_taken;
  assign out_pred_target = buf_pred_target;

  always_ff @(posedge clk) begin
    if (rst) begin
      pc_q <= RESET_PC;
      stopped <= 1'b0;
      req_outstanding <= 1'b0;
      req_pred_taken <= '0;
      req_pred_target <= '{default:'0};
      buf_valid <= 1'b0;
      buf_eop <= 1'b0;
      buf_count <= '0;
      buf_pc <= '{default:'0};
      buf_instr <= '{default:INSTR_INVALID};
      buf_pred_taken <= '0;
      buf_pred_target <= '{default:'0};
    end else if (redirect_valid) begin
      pc_q <= redirect_pc;
      stopped <= 1'b0;
      req_outstanding <= 1'b0;
      buf_valid <= 1'b0;
      buf_eop <= 1'b0;
      buf_count <= '0;
    end else begin
      if (fire_req) begin
        req_outstanding <= 1'b1;
        req_pred_taken <= pred_taken;
        req_pred_target <= pred_target;
      end

      if (req_outstanding && imem_resp_valid) begin
        logic [$clog2(WIDTH+1)-1:0] cnt;
        logic eop;
        logic taken;
        pc_t next_pc;
        cnt = '0;
        eop = 1'b0;
        taken = 1'b0;
        next_pc = pc_q;
        for (int i = 0; i < WIDTH; i++) begin
          buf_pc[i] <= imem_resp_pc[i];
          buf_instr[i] <= imem_resp_word[i];
          buf_pred_taken[i] <= req_pred_taken[i];
          buf_pred_target[i] <= req_pred_target[i];
        end
        for (int i = 0; i < WIDTH; i++) begin
          if (i >= int'(imem_resp_count)) begin
            break;
          end
          if (!imem_resp_word_valid[i]) begin
            eop = 1'b1;
            break;
          end
          cnt = cnt + 1'b1;
          if (req_pred_taken[i]) begin
            next_pc = req_pred_target[i];
            taken = 1'b1;
            break;
          end
        end
        if (!eop && !taken) begin
          next_pc = pc_q + pc_t'(4 * int'(cnt));
        end
        buf_count <= cnt;
        buf_eop <= eop;
        buf_valid <= 1'b1;
        req_outstanding <= 1'b0;
        pc_q <= next_pc;
      end

      if (buf_valid && out_ready) begin
        buf_valid <= 1'b0;
        if (buf_eop) stopped <= 1'b1;
      end
    end
  end

endmodule
