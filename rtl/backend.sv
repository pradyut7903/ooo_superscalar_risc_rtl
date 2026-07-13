`timescale 1ns/1ps
// ============================================================================
// backend.sv -- Out-of-order backend spine.
//
// Wires rename/dispatch, ARF/RAT/ROB, RS/LSQ, execution units, CDB arbiter,
// data memory, commit, and execute-time early branch recovery.
// ============================================================================
module backend
  import pkg_cpu::*;
  #(parameter string DMEM_IMAGE = "")
(
  input  logic clk,
  input  logic rst,
  input  logic flush_in,

  // decoded uop bundle from dispatch
  input  valid_bundle_t uop_valid,
  output logic [$clog2(WIDTH+1)-1:0] uop_accept_count,
  input  uop_bundle_t uop_in,

  // early recovery to frontend (redirect + frontend flush)
  output logic flush,
  output logic redirect_valid,
  output pc_t  redirect_pc,

  // commit observability
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

  // committed branch predictor update bundle
  output valid_bundle_t bp_update_valid,
  output pc_t           bp_update_pc [WIDTH],
  output valid_bundle_t bp_update_taken,
  output pc_t           bp_update_target [WIDTH],

  // Tagged D-memory port (to ideal dmem or dcache)
  output valid_bundle_t mem_req_valid,
  input  valid_bundle_t mem_req_ready,
  output valid_bundle_t mem_req_write,
  output data_t         mem_req_addr [WIDTH],
  output data_t         mem_req_wdata [WIDTH],
  output logic [3:0]    mem_req_wstrb [WIDTH],
  output mem_id_t       mem_req_id [WIDTH],
  input  valid_bundle_t mem_resp_valid,
  input  data_t         mem_resp_rdata [WIDTH],
  input  mem_id_t       mem_resp_id [WIDTH],

  output logic backend_empty,
  output logic cdb_overflow
);

  logic global_flush;
  logic recover_en;
  rob_tag_t recover_tag;
  pc_t recover_pc;
  logic squash_en;
  rob_tag_t squash_tag;
  rob_tag_t rob_head;
  logic [ROB_DEPTH-1:0] rob_slot_freed;

  valid_bundle_t ckpt_save_en;
  rob_tag_t      ckpt_save_tag [WIDTH];

  // ARF/RAT/ROB rename wires.
  valid_bundle_t rename_uop_valid;
  uop_bundle_t   rename_uop_in;
  valid_bundle_t rename_dispatch_fire;

  reg_idx_t arf_raddr1 [WIDTH], arf_raddr2 [WIDTH];
  data_t    arf_rdata1 [WIDTH], arf_rdata2 [WIDTH];
  valid_bundle_t arf_wen;
  reg_idx_t      arf_waddr [WIDTH];
  data_t         arf_wdata [WIDTH];

  reg_idx_t      rat_raddr1 [WIDTH], rat_raddr2 [WIDTH];
  rat_entry_t    rat_rdata1 [WIDTH], rat_rdata2 [WIDTH];
  valid_bundle_t rat_ren_we;
  reg_idx_t      rat_ren_addr [WIDTH];
  rob_tag_t      rat_ren_tag [WIDTH];
  valid_bundle_t rat_cm_we;
  reg_idx_t      rat_cm_addr [WIDTH];
  rob_tag_t      rat_cm_tag [WIDTH];

  valid_bundle_t rob_alloc_en;
  logic          rob_alloc_rd_used [WIDTH];
  reg_idx_t      rob_alloc_dest [WIDTH];
  logic          rob_alloc_is_control [WIDTH];
  logic          rob_alloc_is_store [WIDTH];
  pc_t           rob_alloc_pc [WIDTH];
  rob_tag_t      rob_alloc_tag [WIDTH];
  logic          rob_full;
  logic [$clog2(ROB_DEPTH+1)-1:0] rob_free_count;

  rob_tag_t rob_rd_tag1 [WIDTH], rob_rd_tag2 [WIDTH];
  logic     rob_rd_done1 [WIDTH], rob_rd_done2 [WIDTH];
  data_t    rob_rd_val1 [WIDTH], rob_rd_val2 [WIDTH];

  valid_bundle_t rob_commit_valid;
  rob_tag_t      rob_commit_tag [WIDTH];
  logic          rob_commit_rd_used [WIDTH];
  reg_idx_t      rob_commit_dest [WIDTH];
  data_t         rob_commit_value [WIDTH];
  logic          rob_commit_is_control [WIDTH];
  logic          rob_commit_mispredict [WIDTH];
  pc_t           rob_commit_pc [WIDTH];
  logic          rob_commit_taken [WIDTH];
  pc_t           rob_commit_target [WIDTH];
  pc_t           rob_commit_redirect_pc [WIDTH];
  logic     rob_empty;
  valid_bundle_t rob_commit_do;
  valid_bundle_t rob_commit_store_valid;
  rob_tag_t      rob_commit_store_tag [WIDTH];

  // RS dispatch/issue
  valid_bundle_t rs_dispatch_valid, rs_dispatch_ready;
  uop_bundle_t   rs_dispatch_uop;
  rob_tag_t      rs_dispatch_tag [WIDTH];
  operand_t      rs_dispatch_src1 [WIDTH], rs_dispatch_src2 [WIDTH];

  logic     rs_alu_valid [NUM_ALU];
  logic     rs_mul_valid [NUM_MUL];
  logic     rs_div_valid [NUM_DIV];
  logic     rs_br_valid;
  logic     alu_in_ready [NUM_ALU];
  logic     mul_in_ready [NUM_MUL];
  logic     div_in_ready [NUM_DIV];
  logic     br_in_ready;
  uop_t     alu_uop [NUM_ALU];
  uop_t     mul_uop [NUM_MUL];
  uop_t     div_uop [NUM_DIV];
  uop_t     br_uop;
  rob_tag_t alu_tag [NUM_ALU];
  rob_tag_t mul_tag [NUM_MUL];
  rob_tag_t div_tag [NUM_DIV];
  rob_tag_t br_tag;
  data_t    alu_src1_value [NUM_ALU], alu_src2_value [NUM_ALU];
  data_t    mul_src1_value [NUM_MUL], mul_src2_value [NUM_MUL];
  data_t    div_src1_value [NUM_DIV], div_src2_value [NUM_DIV];
  data_t    br_src1_value, br_src2_value;
  logic     rs_full, rs_empty;

  // LSQ
  valid_bundle_t lsq_dispatch_valid, lsq_dispatch_ready;
  uop_bundle_t   lsq_dispatch_uop;
  rob_tag_t      lsq_dispatch_tag [WIDTH];
  operand_t      lsq_dispatch_base [WIDTH], lsq_dispatch_store_data [WIDTH];
  valid_bundle_t lsq_store_complete_valid;
  rob_tag_t      lsq_store_complete_tag [WIDTH];
  logic     lsq_full, lsq_empty;

  // CDB lanes
  cdb_t alu_cdb [NUM_ALU];
  cdb_t mul_cdb [NUM_MUL];
  cdb_t div_cdb [NUM_DIV];
  cdb_t br_cdb;
  cdb_t lsq_cdb [NUM_LSQ];
  cdb_bus_t cdb;
  cdb_t cdb_producer [NUM_CDB_PRODUCERS];
  logic cdb_producer_ready [NUM_CDB_PRODUCERS];
  logic alu_cdb_ready [NUM_ALU];
  logic mul_cdb_ready [NUM_MUL];
  logic div_cdb_ready [NUM_DIV];
  logic br_cdb_ready;
  logic lsq_cdb_ready [NUM_LSQ];

  localparam int CDB_ALU0 = 0;
  localparam int CDB_MUL0 = CDB_ALU0 + NUM_ALU;
  localparam int CDB_DIV0 = CDB_MUL0 + NUM_MUL;
  localparam int CDB_BR0  = CDB_DIV0 + NUM_DIV;
  localparam int CDB_LSQ0 = CDB_BR0 + NUM_BR;

  // Branch resolution
  logic     br_resolve_valid;
  rob_tag_t br_resolve_tag;
  logic     br_mispredict;
  pc_t      br_redirect_pc;
  logic     br_taken;
  pc_t      br_target;
  logic     br_complete_valid;
  rob_tag_t br_complete_tag;
  logic     br_valid_unused;
  rob_tag_t br_tag_unused;

  // Full backend wipe only on external flush_in (unused today) or rst paths.
  assign global_flush = flush_in;
  // Frontend flush follows early redirect.
  assign flush = redirect_valid;

  assign commit_valid   = rob_commit_valid[0];
  assign commit_tag     = rob_commit_tag[0];
  assign commit_rd_used = rob_commit_rd_used[0];
  assign commit_rd      = rob_commit_dest[0];
  assign commit_value   = rob_commit_value[0];

  assign commit_valid_bundle = rob_commit_valid;
  for (genvar cm_lane = 0; cm_lane < WIDTH; cm_lane++) begin : g_commit_obs
    assign commit_tag_bundle[cm_lane]     = rob_commit_tag[cm_lane];
    assign commit_rd_used_bundle[cm_lane] = rob_commit_rd_used[cm_lane];
    assign commit_rd_bundle[cm_lane]      = rob_commit_dest[cm_lane];
    assign commit_value_bundle[cm_lane]   = rob_commit_value[cm_lane];
    assign bp_update_valid[cm_lane]       = rob_commit_valid[cm_lane] && rob_commit_do[cm_lane] &&
                                            rob_commit_is_control[cm_lane];
    assign bp_update_pc[cm_lane]          = rob_commit_pc[cm_lane];
    assign bp_update_taken[cm_lane]       = rob_commit_taken[cm_lane];
    assign bp_update_target[cm_lane]      = rob_commit_target[cm_lane];
  end
  assign backend_empty  = rob_empty && rs_empty && lsq_empty;

  always_comb begin
    for (int i = 0; i < NUM_CDB_PRODUCERS; i++) begin
      cdb_producer[i] = '0;
    end

    for (int i = 0; i < NUM_ALU; i++) begin
      cdb_producer[CDB_ALU0 + i] = alu_cdb[i];
      alu_cdb_ready[i] = cdb_producer_ready[CDB_ALU0 + i];
    end
    for (int i = 0; i < NUM_MUL; i++) begin
      cdb_producer[CDB_MUL0 + i] = mul_cdb[i];
      mul_cdb_ready[i] = cdb_producer_ready[CDB_MUL0 + i];
    end
    for (int i = 0; i < NUM_DIV; i++) begin
      cdb_producer[CDB_DIV0 + i] = div_cdb[i];
      div_cdb_ready[i] = cdb_producer_ready[CDB_DIV0 + i];
    end

    br_cdb_ready = cdb_producer_ready[CDB_BR0];
    cdb_producer[CDB_BR0] = br_cdb;

    for (int i = 0; i < NUM_LSQ; i++) begin
      cdb_producer[CDB_LSQ0 + i] = lsq_cdb[i];
      lsq_cdb_ready[i] = cdb_producer_ready[CDB_LSQ0 + i];
    end
  end

  always_comb begin
    rename_uop_valid = uop_valid;
    rename_uop_in = uop_in;

    for (int i = 0; i < WIDTH; i++) begin
      rat_cm_we[i] = rob_commit_valid[i] && rob_commit_do[i] && rob_commit_rd_used[i];
      rat_cm_addr[i] = rob_commit_dest[i];
      rat_cm_tag[i] = rob_commit_tag[i];
      arf_wen[i] = rob_commit_valid[i] && rob_commit_do[i] && rob_commit_rd_used[i];
      arf_waddr[i] = rob_commit_dest[i];
      arf_wdata[i] = rob_commit_value[i];
    end

    rob_commit_do = rob_commit_valid;
  end

  rename_dispatch u_rename_dispatch (
    .uop_valid(rename_uop_valid), .uop_accept_count(uop_accept_count), .uop_in(rename_uop_in),
    .cdb_in(cdb),
    .arf_raddr1(arf_raddr1), .arf_rdata1(arf_rdata1),
    .arf_raddr2(arf_raddr2), .arf_rdata2(arf_rdata2),
    .rat_raddr1(rat_raddr1), .rat_rdata1(rat_rdata1),
    .rat_raddr2(rat_raddr2), .rat_rdata2(rat_rdata2),
    .rat_ren_we(rat_ren_we), .rat_ren_addr(rat_ren_addr), .rat_ren_tag(rat_ren_tag),
    .rob_alloc_en(rob_alloc_en), .rob_alloc_rd_used(rob_alloc_rd_used),
    .rob_alloc_dest(rob_alloc_dest), .rob_alloc_is_control(rob_alloc_is_control),
    .rob_alloc_is_store(rob_alloc_is_store), .rob_alloc_pc(rob_alloc_pc),
    .rob_alloc_tag(rob_alloc_tag), .rob_free_count(rob_free_count),
    .rob_rd_tag1(rob_rd_tag1), .rob_rd_done1(rob_rd_done1), .rob_rd_val1(rob_rd_val1),
    .rob_rd_tag2(rob_rd_tag2), .rob_rd_done2(rob_rd_done2), .rob_rd_val2(rob_rd_val2),
    .rs_dispatch_valid(rs_dispatch_valid), .rs_dispatch_ready(rs_dispatch_ready),
    .rs_dispatch_uop(rs_dispatch_uop), .rs_dispatch_tag(rs_dispatch_tag),
    .rs_dispatch_src1(rs_dispatch_src1), .rs_dispatch_src2(rs_dispatch_src2),
    .lsq_dispatch_valid(lsq_dispatch_valid), .lsq_dispatch_ready(lsq_dispatch_ready),
    .lsq_dispatch_uop(lsq_dispatch_uop), .lsq_dispatch_tag(lsq_dispatch_tag),
    .lsq_dispatch_base(lsq_dispatch_base), .lsq_dispatch_store_data(lsq_dispatch_store_data),
    .dispatch_fire(rename_dispatch_fire),
    .ckpt_save_en(ckpt_save_en), .ckpt_save_tag(ckpt_save_tag),
    .recover_en(recover_en)
  );

  arf u_arf (
    .clk(clk), .rst(rst),
    .raddr1(arf_raddr1), .rdata1(arf_rdata1),
    .raddr2(arf_raddr2), .rdata2(arf_rdata2),
    .wen(arf_wen), .waddr(arf_waddr), .wdata(arf_wdata)
  );

  rat u_rat (
    .clk(clk), .rst(rst),
    .raddr1(rat_raddr1), .rdata1(rat_rdata1),
    .raddr2(rat_raddr2), .rdata2(rat_rdata2),
    .ren_we(rat_ren_we), .ren_addr(rat_ren_addr), .ren_tag(rat_ren_tag),
    .cm_we(rat_cm_we), .cm_addr(rat_cm_addr), .cm_tag(rat_cm_tag),
    .ckpt_save_en(ckpt_save_en), .ckpt_save_tag(ckpt_save_tag),
    .ckpt_restore_en(recover_en), .ckpt_restore_tag(recover_tag),
    .ckpt_invalidate(rob_slot_freed)
  );

  rob u_rob (
    .clk(clk), .rst(rst), .flush(global_flush),
    .squash_en(squash_en), .squash_tag(squash_tag),
    .alloc_en(rob_alloc_en), .alloc_rd_used(rob_alloc_rd_used),
    .alloc_dest(rob_alloc_dest), .alloc_is_control(rob_alloc_is_control),
    .alloc_is_store(rob_alloc_is_store), .alloc_pc(rob_alloc_pc),
    .alloc_tag(rob_alloc_tag), .full(rob_full), .free_count(rob_free_count),
    .wb_cdb(cdb),
    .complete_en(lsq_store_complete_valid), .complete_tag(lsq_store_complete_tag),
    .complete2_en(br_complete_valid && !br_cdb.valid), .complete2_tag(br_complete_tag),
    .br_resolve_en(br_resolve_valid), .br_resolve_tag(br_resolve_tag),
    .br_mispredict(br_mispredict), .br_taken(br_taken), .br_target(br_target),
    .br_redirect_pc(br_redirect_pc),
    .rd_tag1(rob_rd_tag1), .rd_done1(rob_rd_done1), .rd_val1(rob_rd_val1),
    .rd_tag2(rob_rd_tag2), .rd_done2(rob_rd_done2), .rd_val2(rob_rd_val2),
    .commit_valid(rob_commit_valid), .commit_tag(rob_commit_tag),
    .commit_rd_used(rob_commit_rd_used), .commit_dest(rob_commit_dest),
    .commit_value(rob_commit_value), .commit_is_control(rob_commit_is_control),
    .commit_mispredict(rob_commit_mispredict),
    .commit_pc(rob_commit_pc), .commit_taken(rob_commit_taken),
    .commit_target(rob_commit_target),
    .commit_redirect_pc(rob_commit_redirect_pc),
    .commit_do(rob_commit_do),
    .commit_store_valid(rob_commit_store_valid),
    .commit_store_tag(rob_commit_store_tag),
    .empty(rob_empty),
    .rob_head(rob_head),
    .slot_freed(rob_slot_freed)
  );

  rs u_rs (
    .clk(clk), .rst(rst), .flush(global_flush),
    .squash_en(squash_en), .squash_tag(squash_tag), .rob_head(rob_head),
    .dispatch_valid(rs_dispatch_valid), .dispatch_ready(rs_dispatch_ready),
    .dispatch_uop(rs_dispatch_uop), .dispatch_tag(rs_dispatch_tag),
    .dispatch_src1(rs_dispatch_src1), .dispatch_src2(rs_dispatch_src2),
    .cdb_in(cdb),
    .alu_valid(rs_alu_valid), .alu_ready(alu_in_ready),
    .alu_uop(alu_uop), .alu_tag(alu_tag),
    .alu_src1_value(alu_src1_value), .alu_src2_value(alu_src2_value),
    .mul_valid(rs_mul_valid), .mul_ready(mul_in_ready),
    .mul_uop(mul_uop), .mul_tag(mul_tag),
    .mul_src1_value(mul_src1_value), .mul_src2_value(mul_src2_value),
    .div_valid(rs_div_valid), .div_ready(div_in_ready),
    .div_uop(div_uop), .div_tag(div_tag),
    .div_src1_value(div_src1_value), .div_src2_value(div_src2_value),
    .br_valid(rs_br_valid), .br_ready(br_in_ready),
    .br_uop(br_uop), .br_tag(br_tag),
    .br_src1_value(br_src1_value), .br_src2_value(br_src2_value),
    .full(rs_full), .empty(rs_empty)
  );

  lsq u_lsq (
    .clk(clk), .rst(rst), .flush(global_flush),
    .squash_en(squash_en), .squash_tag(squash_tag), .rob_head(rob_head),
    .dispatch_valid(lsq_dispatch_valid), .dispatch_ready(lsq_dispatch_ready),
    .dispatch_uop(lsq_dispatch_uop), .dispatch_tag(lsq_dispatch_tag),
    .dispatch_base(lsq_dispatch_base), .dispatch_store_data(lsq_dispatch_store_data),
    .cdb_in(cdb),
    .commit_store_valid(rob_commit_store_valid),
    .commit_store_tag(rob_commit_store_tag),
    .mem_req_valid(mem_req_valid), .mem_req_ready(mem_req_ready),
    .mem_req_write(mem_req_write), .mem_req_addr(mem_req_addr),
    .mem_req_wdata(mem_req_wdata), .mem_req_wstrb(mem_req_wstrb),
    .mem_req_id(mem_req_id),
    .mem_resp_valid(mem_resp_valid), .mem_resp_rdata(mem_resp_rdata),
    .mem_resp_id(mem_resp_id),
    .cdb_ready(lsq_cdb_ready), .out_cdb(lsq_cdb),
    .store_complete_valid(lsq_store_complete_valid),
    .store_complete_tag(lsq_store_complete_tag),
    .full(lsq_full), .empty(lsq_empty)
  );

  generate
    for (genvar i = 0; i < NUM_ALU; i++) begin : gen_alu
      alu u_alu (
        .clk(clk), .rst(rst), .flush(global_flush),
        .squash_en(squash_en), .squash_tag(squash_tag), .rob_head(rob_head),
        .in_valid(rs_alu_valid[i]), .in_ready(alu_in_ready[i]),
        .in_uop(alu_uop[i]), .in_tag(alu_tag[i]),
        .src1_value(alu_src1_value[i]), .src2_value(alu_src2_value[i]),
        .cdb_ready(alu_cdb_ready[i]), .out_cdb(alu_cdb[i])
      );
    end

    for (genvar i = 0; i < NUM_MUL; i++) begin : gen_mul
      mul u_mul (
        .clk(clk), .rst(rst), .flush(global_flush),
        .squash_en(squash_en), .squash_tag(squash_tag), .rob_head(rob_head),
        .in_valid(rs_mul_valid[i]), .in_ready(mul_in_ready[i]),
        .in_uop(mul_uop[i]), .in_tag(mul_tag[i]),
        .src1_value(mul_src1_value[i]), .src2_value(mul_src2_value[i]),
        .cdb_ready(mul_cdb_ready[i]), .out_cdb(mul_cdb[i])
      );
    end

    for (genvar i = 0; i < NUM_DIV; i++) begin : gen_div
      div u_div (
        .clk(clk), .rst(rst), .flush(global_flush),
        .squash_en(squash_en), .squash_tag(squash_tag), .rob_head(rob_head),
        .in_valid(rs_div_valid[i]), .in_ready(div_in_ready[i]),
        .in_uop(div_uop[i]), .in_tag(div_tag[i]),
        .src1_value(div_src1_value[i]), .src2_value(div_src2_value[i]),
        .cdb_ready(div_cdb_ready[i]), .out_cdb(div_cdb[i])
      );
    end
  endgenerate

  branch_unit u_branch (
    .clk(clk), .rst(rst), .flush(global_flush),
    .squash_en(squash_en), .squash_tag(squash_tag), .rob_head(rob_head),
    .in_valid(rs_br_valid), .in_ready(br_in_ready),
    .in_uop(br_uop), .in_tag(br_tag),
    .src1_value(br_src1_value), .src2_value(br_src2_value),
    .cdb_ready(br_cdb_ready), .out_cdb(br_cdb),
    .br_valid(br_valid_unused), .br_tag(br_tag_unused),
    .br_taken(br_taken), .br_target(br_target),
    .br_mispredict(br_mispredict),
    .br_resolve_valid(br_resolve_valid), .br_resolve_tag(br_resolve_tag),
    .br_redirect_pc(br_redirect_pc),
    .complete_valid(br_complete_valid), .complete_tag(br_complete_tag)
  );

  cdb_arbiter u_cdb_arbiter (
    .clk(clk), .rst(rst), .flush(global_flush),
    .producer_cdb(cdb_producer),
    .producer_ready(cdb_producer_ready),
    .out_cdb(cdb), .overflow(cdb_overflow)
  );

  early_recovery u_early_recovery (
    .br_resolve_valid(br_resolve_valid),
    .br_mispredict(br_mispredict),
    .br_resolve_tag(br_resolve_tag),
    .br_redirect_pc(br_redirect_pc),
    .recover_en(recover_en),
    .recover_tag(recover_tag),
    .recover_pc(recover_pc),
    .squash_en(squash_en),
    .squash_tag(squash_tag),
    .redirect_valid(redirect_valid),
    .redirect_pc(redirect_pc)
  );

endmodule
