`timescale 1ns/1ps
// ============================================================================
// mem_arbiter.sv -- Shared line-port arbiter between I-cache and D-cache.
//
// Two clients only. Up to DRAM_OUTSTANDING in-flight DRAM transactions.
// DRAM id = {client, mshr_idx}: client 0 = I$, 1 = D$.
// D-cache prioritized when both request.
// ============================================================================
module mem_arbiter
  import pkg_cpu::*;
(
  input  logic clk,
  input  logic rst,

  // I-cache line port
  input  logic                 i_req_valid,
  output logic                 i_req_ready,
  input  logic                 i_req_write,
  input  data_t                i_req_addr,
  input  cache_line_t          i_req_wdata,
  input  logic [DRAM_MSHR_IDX_W-1:0] i_req_mshr,
  output logic                 i_resp_valid,
  output cache_line_t          i_resp_rdata,
  output logic [DRAM_MSHR_IDX_W-1:0] i_resp_mshr,

  // D-cache line port
  input  logic                 d_req_valid,
  output logic                 d_req_ready,
  input  logic                 d_req_write,
  input  data_t                d_req_addr,
  input  cache_line_t          d_req_wdata,
  input  logic [DRAM_MSHR_IDX_W-1:0] d_req_mshr,
  output logic                 d_resp_valid,
  output cache_line_t          d_resp_rdata,
  output logic [DRAM_MSHR_IDX_W-1:0] d_resp_mshr,

  // DRAM
  output logic        dram_req_valid,
  input  logic        dram_req_ready,
  output logic        dram_req_is_instr,
  output logic        dram_req_write,
  output data_t       dram_req_addr,
  output cache_line_t dram_req_wdata,
  output dram_id_t    dram_req_id,
  input  logic        dram_resp_valid,
  input  cache_line_t dram_resp_rdata,
  input  dram_id_t    dram_resp_id
);

  localparam int SLOTS = DRAM_OUTSTANDING;

  logic        sb_valid [SLOTS];
  dram_id_t    sb_id    [SLOTS];

  int free_sb;
  int n_inflight;
  always_comb begin
    free_sb = -1;
    n_inflight = 0;
    for (int i = 0; i < SLOTS; i++) begin
      if (sb_valid[i]) n_inflight++;
      else if (free_sb < 0) free_sb = i;
    end
  end

  logic can_issue;
  logic grant_d, grant_i;
  assign can_issue = (free_sb >= 0) && dram_req_ready;
  assign grant_d = can_issue && d_req_valid;
  assign grant_i = can_issue && i_req_valid && !d_req_valid;

  assign d_req_ready = grant_d;
  assign i_req_ready = grant_i;

  assign dram_req_valid = grant_d || grant_i;
  assign dram_req_is_instr = grant_i;
  assign dram_req_write = grant_d ? d_req_write : 1'b0;
  assign dram_req_addr  = grant_d ? d_req_addr  : i_req_addr;
  assign dram_req_wdata = grant_d ? d_req_wdata : i_req_wdata;
  assign dram_req_id    = grant_d
      ? dram_id_t'({1'b1, d_req_mshr})
      : dram_id_t'({1'b0, i_req_mshr});

  wire resp_is_d = dram_resp_id[DRAM_ID_W-1];
  assign i_resp_valid = dram_resp_valid && !resp_is_d;
  assign d_resp_valid = dram_resp_valid &&  resp_is_d;
  assign i_resp_rdata = dram_resp_rdata;
  assign d_resp_rdata = dram_resp_rdata;
  assign i_resp_mshr  = dram_resp_id[DRAM_MSHR_IDX_W-1:0];
  assign d_resp_mshr  = dram_resp_id[DRAM_MSHR_IDX_W-1:0];

  always_ff @(posedge clk) begin
    if (rst) begin
      for (int i = 0; i < SLOTS; i++) begin
        sb_valid[i] <= 1'b0;
        sb_id[i] <= '0;
      end
    end else begin
      if (dram_req_valid && dram_req_ready && (free_sb >= 0)) begin
        sb_valid[free_sb] <= 1'b1;
        sb_id[free_sb] <= dram_req_id;
      end
      if (dram_resp_valid) begin
        for (int i = 0; i < SLOTS; i++) begin
          if (sb_valid[i] && (sb_id[i] == dram_resp_id))
            sb_valid[i] <= 1'b0;
        end
      end
    end
  end

endmodule
