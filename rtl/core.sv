`timescale 1ns/1ps
// ============================================================================
// core.sv -- RV32IM OoO core with ideal or cached memory system.
// ============================================================================
module core
  import pkg_cpu::*;
  #(parameter string IMEM_IMAGE = "",
    parameter string DMEM_IMAGE = "")
(
  input  logic clk,
  input  logic rst,

  output logic     commit_valid,
  output rob_tag_t commit_tag,
  output logic     commit_rd_used,
  output reg_idx_t commit_rd,
  output data_t    commit_value,
  output valid_bundle_t commit_valid_bundle,
  output rob_tag_t      commit_tag_bundle [WIDTH],
  output logic          commit_rd_used_bundle [WIDTH],
  output reg_idx_t      commit_rd_bundle [WIDTH],
  output data_t         commit_value_bundle [WIDTH],

  output logic halted,
  output logic cdb_overflow
);

  logic   fetch_valid, fetch_ready, fetch_eop;
  logic [$clog2(WIDTH+1)-1:0] fetch_count;
  pc_bundle_t    fetch_pc;
  instr_bundle_t fetch_instr;
  valid_bundle_t fetch_pred_taken;
  pc_bundle_t    fetch_pred_target;

  logic          imem_req_valid, imem_req_ready, imem_resp_valid;
  pc_t           imem_req_pc;
  valid_bundle_t imem_resp_word_valid;
  instr_bundle_t imem_resp_word;
  pc_bundle_t    imem_resp_pc;
  logic [$clog2(WIDTH+1)-1:0] imem_resp_count;
  pc_bundle_t    pred_lookup_pc;
  valid_bundle_t pred_taken;
  pc_bundle_t    pred_target;

  valid_bundle_t ifq_valid;
  pc_bundle_t    ifq_pc;
  instr_bundle_t ifq_instr;
  valid_bundle_t ifq_pred_taken;
  pc_bundle_t    ifq_pred_target;
  logic          ifq_full, ifq_empty;
  logic [$clog2(WIDTH+1)-1:0] ifq_pop_count;
  logic [$clog2(WIDTH+1)-1:0] ifq_decode_count;

  uop_bundle_t decoded_raw_uop;
  uop_bundle_t decoded_uop;
  valid_bundle_t dispatch_in_valid;
  logic dispatch_in_ready;
  valid_bundle_t dispatch_valid;
  logic [$clog2(WIDTH+1)-1:0] dispatch_accept_count;
  uop_bundle_t dispatch_uop;

  logic backend_flush;
  logic redirect_valid;
  pc_t  redirect_pc;
  logic backend_empty;
  valid_bundle_t bp_update_valid;
  pc_bundle_t    bp_update_pc;
  valid_bundle_t bp_update_taken;
  pc_bundle_t    bp_update_target;

  valid_bundle_t mem_req_valid, mem_req_ready, mem_req_write;
  data_t         mem_req_addr [WIDTH], mem_req_wdata [WIDTH];
  logic [3:0]    mem_req_wstrb [WIDTH];
  mem_id_t       mem_req_id [WIDTH];
  valid_bundle_t mem_resp_valid;
  data_t         mem_resp_rdata [WIDTH];
  mem_id_t       mem_resp_id [WIDTH];

  logic eop_seen;

  branch_predictor u_branch_predictor (
    .clk(clk), .rst(rst),
    .fetch_pc(pred_lookup_pc),
    .pred_taken(pred_taken),
    .pred_target(pred_target),
    .update_valid(bp_update_valid),
    .update_pc(bp_update_pc),
    .update_taken(bp_update_taken),
    .update_target(bp_update_target)
  );

  fetch u_fetch (
    .clk(clk), .rst(rst),
    .redirect_valid(redirect_valid), .redirect_pc(redirect_pc),
    .pred_taken(pred_taken), .pred_target(pred_target),
    .imem_req_valid(imem_req_valid), .imem_req_ready(imem_req_ready),
    .imem_req_pc(imem_req_pc),
    .imem_resp_valid(imem_resp_valid),
    .imem_resp_word_valid(imem_resp_word_valid),
    .imem_resp_word(imem_resp_word),
    .imem_resp_pc(imem_resp_pc),
    .imem_resp_count(imem_resp_count),
    .pred_lookup_pc(pred_lookup_pc),
    .out_count(fetch_count), .out_valid(fetch_valid), .out_eop(fetch_eop),
    .out_pc(fetch_pc), .out_instr(fetch_instr),
    .out_pred_taken(fetch_pred_taken), .out_pred_target(fetch_pred_target),
    .out_ready(fetch_ready)
  );

  ifq u_ifq (
    .clk(clk), .rst(rst), .flush(backend_flush),
    .push_count(fetch_count), .push_ready(fetch_ready),
    .push_pc(fetch_pc), .push_instr(fetch_instr),
    .push_pred_taken(fetch_pred_taken), .push_pred_target(fetch_pred_target),
    .pop_count(ifq_pop_count),
    .out_valid(ifq_valid), .out_pc(ifq_pc), .out_instr(ifq_instr),
    .out_pred_taken(ifq_pred_taken), .out_pred_target(ifq_pred_target),
    .full(ifq_full), .empty(ifq_empty)
  );

  always_comb begin
    ifq_decode_count = '0;
    for (int i = 0; i < WIDTH; i++) begin
      if (ifq_valid[i]) ifq_decode_count = ifq_decode_count + 1'b1;
    end
  end

  for (genvar lane = 0; lane < WIDTH; lane++) begin : g_decode
    decode u_decode (
      .inst(ifq_instr[lane]),
      .pc(ifq_pc[lane]),
      .uop(decoded_raw_uop[lane])
    );
  end

  always_comb begin
    dispatch_in_valid = ifq_valid;
    for (int i = 0; i < WIDTH; i++) begin
      decoded_uop[i] = decoded_raw_uop[i];
      decoded_uop[i].pred_taken  = ifq_pred_taken[i];
      decoded_uop[i].pred_target = ifq_pred_target[i];
    end
  end

  assign ifq_pop_count = (dispatch_in_ready && (ifq_decode_count != '0)) ? ifq_decode_count : '0;

  dispatch_reg u_dispatch_reg (
    .clk(clk), .rst(rst), .flush(backend_flush),
    .in_valid(dispatch_in_valid), .in_ready(dispatch_in_ready),
    .in_uop(decoded_uop),
    .out_valid(dispatch_valid), .out_accept_count(dispatch_accept_count),
    .out_uop(dispatch_uop)
  );

  backend #(.DMEM_IMAGE(DMEM_IMAGE)) u_backend (
    .clk(clk), .rst(rst), .flush_in(1'b0),
    .uop_valid(dispatch_valid), .uop_accept_count(dispatch_accept_count), .uop_in(dispatch_uop),
    .flush(backend_flush), .redirect_valid(redirect_valid), .redirect_pc(redirect_pc),
    .commit_valid(commit_valid), .commit_tag(commit_tag),
    .commit_rd_used(commit_rd_used), .commit_rd(commit_rd), .commit_value(commit_value),
    .commit_valid_bundle(commit_valid_bundle), .commit_tag_bundle(commit_tag_bundle),
    .commit_rd_used_bundle(commit_rd_used_bundle), .commit_rd_bundle(commit_rd_bundle),
    .commit_value_bundle(commit_value_bundle),
    .bp_update_valid(bp_update_valid), .bp_update_pc(bp_update_pc),
    .bp_update_taken(bp_update_taken), .bp_update_target(bp_update_target),
    .mem_req_valid(mem_req_valid), .mem_req_ready(mem_req_ready),
    .mem_req_write(mem_req_write), .mem_req_addr(mem_req_addr),
    .mem_req_wdata(mem_req_wdata), .mem_req_wstrb(mem_req_wstrb),
    .mem_req_id(mem_req_id),
    .mem_resp_valid(mem_resp_valid), .mem_resp_rdata(mem_resp_rdata),
    .mem_resp_id(mem_resp_id),
    .backend_empty(backend_empty), .cdb_overflow(cdb_overflow)
  );

  // ---------------- memory system ----------------
  generate
    if (MEM_SYSTEM == MEM_SYSTEM_IDEAL) begin : g_ideal_mem
      ideal_imem_bridge #(.DEFAULT_IMAGE(IMEM_IMAGE)) u_imem (
        .clk(clk), .rst(rst), .flush(backend_flush || redirect_valid),
        .req_valid(imem_req_valid), .req_ready(imem_req_ready), .req_pc(imem_req_pc),
        .resp_valid(imem_resp_valid), .resp_word_valid(imem_resp_word_valid),
        .resp_word(imem_resp_word), .resp_pc(imem_resp_pc),
        .resp_count(imem_resp_count)
      );
      dmem #(.DEFAULT_IMAGE(DMEM_IMAGE)) u_dmem (
        .clk(clk), .rst(rst),
        .mem_req_valid(mem_req_valid), .mem_req_ready(mem_req_ready),
        .mem_req_write(mem_req_write), .mem_req_addr(mem_req_addr),
        .mem_req_wdata(mem_req_wdata), .mem_req_wstrb(mem_req_wstrb),
        .mem_req_id(mem_req_id),
        .mem_resp_valid(mem_resp_valid), .mem_resp_rdata(mem_resp_rdata),
        .mem_resp_id(mem_resp_id)
      );
    end else begin : g_cached_mem
      logic        i_line_req_valid, i_line_req_ready, i_line_resp_valid;
      data_t       i_line_req_addr;
      cache_line_t i_line_resp_rdata;
      logic [DRAM_MSHR_IDX_W-1:0] i_line_req_mshr, i_line_resp_mshr;

      logic        d_line_req_valid, d_line_req_ready, d_line_req_write, d_line_resp_valid;
      data_t       d_line_req_addr;
      cache_line_t d_line_req_wdata, d_line_resp_rdata;
      logic [DRAM_MSHR_IDX_W-1:0] d_line_req_mshr, d_line_resp_mshr;

      logic        dram_req_valid, dram_req_ready, dram_req_is_instr, dram_req_write;
      data_t       dram_req_addr;
      cache_line_t dram_req_wdata;
      dram_id_t    dram_req_id;
      logic        dram_resp_valid;
      cache_line_t dram_resp_rdata;
      dram_id_t    dram_resp_id;

      icache u_icache (
        .clk(clk), .rst(rst), .flush(backend_flush || redirect_valid),
        .req_valid(imem_req_valid), .req_ready(imem_req_ready), .req_pc(imem_req_pc),
        .resp_valid(imem_resp_valid), .resp_word_valid(imem_resp_word_valid),
        .resp_word(imem_resp_word), .resp_pc(imem_resp_pc),
        .resp_count(imem_resp_count),
        .line_req_valid(i_line_req_valid), .line_req_ready(i_line_req_ready),
        .line_req_addr(i_line_req_addr), .line_req_mshr(i_line_req_mshr),
        .line_resp_valid(i_line_resp_valid), .line_resp_rdata(i_line_resp_rdata),
        .line_resp_mshr(i_line_resp_mshr)
      );

      dcache u_dcache (
        .clk(clk), .rst(rst), .flush(1'b0),
        .mem_req_valid(mem_req_valid), .mem_req_ready(mem_req_ready),
        .mem_req_write(mem_req_write), .mem_req_addr(mem_req_addr),
        .mem_req_wdata(mem_req_wdata), .mem_req_wstrb(mem_req_wstrb),
        .mem_req_id(mem_req_id),
        .mem_resp_valid(mem_resp_valid), .mem_resp_rdata(mem_resp_rdata),
        .mem_resp_id(mem_resp_id),
        .line_req_valid(d_line_req_valid), .line_req_ready(d_line_req_ready),
        .line_req_write(d_line_req_write), .line_req_addr(d_line_req_addr),
        .line_req_wdata(d_line_req_wdata), .line_req_mshr(d_line_req_mshr),
        .line_resp_valid(d_line_resp_valid), .line_resp_rdata(d_line_resp_rdata),
        .line_resp_mshr(d_line_resp_mshr)
      );

      mem_arbiter u_arb (
        .clk(clk), .rst(rst),
        .i_req_valid(i_line_req_valid), .i_req_ready(i_line_req_ready),
        .i_req_write(1'b0), .i_req_addr(i_line_req_addr), .i_req_wdata('0),
        .i_req_mshr(i_line_req_mshr),
        .i_resp_valid(i_line_resp_valid), .i_resp_rdata(i_line_resp_rdata),
        .i_resp_mshr(i_line_resp_mshr),
        .d_req_valid(d_line_req_valid), .d_req_ready(d_line_req_ready),
        .d_req_write(d_line_req_write), .d_req_addr(d_line_req_addr),
        .d_req_wdata(d_line_req_wdata), .d_req_mshr(d_line_req_mshr),
        .d_resp_valid(d_line_resp_valid), .d_resp_rdata(d_line_resp_rdata),
        .d_resp_mshr(d_line_resp_mshr),
        .dram_req_valid(dram_req_valid), .dram_req_ready(dram_req_ready),
        .dram_req_is_instr(dram_req_is_instr), .dram_req_write(dram_req_write),
        .dram_req_addr(dram_req_addr), .dram_req_wdata(dram_req_wdata),
        .dram_req_id(dram_req_id),
        .dram_resp_valid(dram_resp_valid), .dram_resp_rdata(dram_resp_rdata),
        .dram_resp_id(dram_resp_id)
      );

      dram_model #(.IMEM_IMAGE(IMEM_IMAGE), .DMEM_IMAGE(DMEM_IMAGE)) u_dram (
        .clk(clk), .rst(rst),
        .req_valid(dram_req_valid), .req_ready(dram_req_ready),
        .req_is_instr(dram_req_is_instr), .req_write(dram_req_write),
        .req_line_addr(dram_req_addr), .req_wdata(dram_req_wdata),
        .req_id(dram_req_id),
        .resp_valid(dram_resp_valid), .resp_rdata(dram_resp_rdata),
        .resp_id(dram_resp_id)
      );
    end
  endgenerate

  always_ff @(posedge clk) begin
    if (rst || backend_flush) begin
      eop_seen <= 1'b0;
    end else if (fetch_eop && fetch_ready) begin
      eop_seen <= 1'b1;
    end
  end

  assign halted = eop_seen && !fetch_valid && ifq_empty && (dispatch_valid == '0) && backend_empty;

endmodule
