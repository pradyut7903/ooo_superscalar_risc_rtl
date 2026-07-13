`timescale 1ns/1ps
// ============================================================================
// rename_dispatch.sv -- Bundle rename / operand-resolve / dispatch stage.
//
// This is the first widened backend boundary.  It accepts a WIDTH-lane decoded
// uop bundle and processes lanes in program order combinationally, so younger
// lanes see older same-cycle destination renames.
//
// The surrounding pipeline uses a prefix-count handshake:
//   * uop_accept_count tells the upstream queue/register how many leading lanes
//     were accepted this cycle.
//   * dispatch_fire[lane]=1 marks accepted non-NOP uops; accepted NOPs are
//     consumed without ROB/RAT/RS/LSQ side effects.
// ============================================================================
module rename_dispatch
  import pkg_cpu::*;
(
  // decoded uop bundle from dispatch register
  input  valid_bundle_t uop_valid,
  output logic [$clog2(WIDTH+1)-1:0] uop_accept_count,
  input  uop_bundle_t   uop_in,

  // CDB bypass for same-cycle producer completion
  input  cdb_bus_t cdb_in,

  // ARF combinational reads
  output reg_idx_t arf_raddr1 [WIDTH],
  input  data_t    arf_rdata1 [WIDTH],
  output reg_idx_t arf_raddr2 [WIDTH],
  input  data_t    arf_rdata2 [WIDTH],

  // RAT combinational reads + synchronous rename writes
  output reg_idx_t      rat_raddr1 [WIDTH],
  input  rat_entry_t    rat_rdata1 [WIDTH],
  output reg_idx_t      rat_raddr2 [WIDTH],
  input  rat_entry_t    rat_rdata2 [WIDTH],
  output valid_bundle_t rat_ren_we,
  output reg_idx_t      rat_ren_addr [WIDTH],
  output rob_tag_t      rat_ren_tag  [WIDTH],

  // ROB allocation + operand reads by producer tag
  output valid_bundle_t rob_alloc_en,
  output logic          rob_alloc_rd_used [WIDTH],
  output reg_idx_t      rob_alloc_dest [WIDTH],
  output logic          rob_alloc_is_control [WIDTH],
  output logic          rob_alloc_is_store [WIDTH],
  output pc_t           rob_alloc_pc [WIDTH],
  input  rob_tag_t      rob_alloc_tag [WIDTH],
  input  logic [$clog2(ROB_DEPTH+1)-1:0] rob_free_count,

  output rob_tag_t rob_rd_tag1 [WIDTH],
  input  logic     rob_rd_done1 [WIDTH],
  input  data_t    rob_rd_val1  [WIDTH],
  output rob_tag_t rob_rd_tag2 [WIDTH],
  input  logic     rob_rd_done2 [WIDTH],
  input  data_t    rob_rd_val2  [WIDTH],

  // RS dispatch path
  output valid_bundle_t rs_dispatch_valid,
  input  valid_bundle_t rs_dispatch_ready,
  output uop_bundle_t   rs_dispatch_uop,
  output rob_tag_t      rs_dispatch_tag [WIDTH],
  output operand_t      rs_dispatch_src1 [WIDTH],
  output operand_t      rs_dispatch_src2 [WIDTH],

  // LSQ dispatch path
  output valid_bundle_t lsq_dispatch_valid,
  input  valid_bundle_t lsq_dispatch_ready,
  output uop_bundle_t   lsq_dispatch_uop,
  output rob_tag_t      lsq_dispatch_tag [WIDTH],
  output operand_t      lsq_dispatch_base [WIDTH],
  output operand_t      lsq_dispatch_store_data [WIDTH],

  // optional observability for an enclosing pipeline controller
  output valid_bundle_t dispatch_fire,

  // RAT checkpoint save (control ops) + suppress dispatch on recovery
  output valid_bundle_t ckpt_save_en,
  output rob_tag_t      ckpt_save_tag [WIDTH],
  input  logic          recover_en
);

  valid_bundle_t lane_is_nop;
  valid_bundle_t lane_is_mem;
  valid_bundle_t lane_is_rs_uop;
  valid_bundle_t lane_target_ready;
  valid_bundle_t lane_same_cycle_src1;
  valid_bundle_t lane_same_cycle_src2;

  rat_entry_t rat_src1_eff [WIDTH];
  rat_entry_t rat_src2_eff [WIDTH];
  operand_t src1_operand [WIDTH];
  operand_t src2_operand [WIDTH];

  logic [$clog2(WIDTH+1)-1:0] rob_needed_count;

  function automatic operand_t resolve_operand(
    input logic       used,
    input rat_entry_t rat_entry,
    input logic       same_cycle_producer,
    input data_t      arf_value,
    input logic       rob_done,
    input data_t      rob_value,
    input cdb_bus_t   cdb
  );
    operand_t opnd;

    opnd = '0;
    if (!used) begin
      opnd.ready = 1'b1;
      opnd.value = '0;
      opnd.tag   = '0;
    end else if (!rat_entry.valid) begin
      opnd.ready = 1'b1;
      opnd.value = arf_value;
      opnd.tag   = '0;
    end else begin
      opnd.tag = rat_entry.tag;
      opnd.ready = 1'b0;
      opnd.value = '0;
      for (int c = 0; c < CDB_WIDTH; c++) begin
        if (cdb[c].valid && (cdb[c].tag == rat_entry.tag)) begin
          opnd.ready = 1'b1;
          opnd.value = cdb[c].data;
        end
      end
      if (!opnd.ready && !same_cycle_producer && rob_done) begin
        opnd.ready = 1'b1;
        opnd.value = rob_value;
      end
    end

    return opnd;
  endfunction

  always_comb begin
    rob_needed_count = '0;
    uop_accept_count = '0;

    if (!recover_en) begin
      for (int i = 0; i < WIDTH; i++) begin
        // Squash computational writes to x0 (rd_used=0): no ROB/RS. Real addi x0,x0,0
        // must not allocate a never-completing ROB entry. Mem/BR still allocate.
        lane_is_nop[i] = (uop_in[i].op == UOP_NOP) ||
                         (!uop_in[i].rd_used &&
                          ((uop_in[i].fu == FU_ALU) ||
                           (uop_in[i].fu == FU_MUL) ||
                           (uop_in[i].fu == FU_DIV)));
        lane_is_mem[i] = (uop_in[i].fu == FU_MEM);
        lane_is_rs_uop[i] = (uop_in[i].fu == FU_ALU) ||
                            (uop_in[i].fu == FU_MUL) ||
                            (uop_in[i].fu == FU_DIV) ||
                            (uop_in[i].fu == FU_BR);

        lane_target_ready[i] = lane_is_nop[i] ? 1'b1 :
                               lane_is_mem[i] ? lsq_dispatch_ready[i] :
                               lane_is_rs_uop[i] ? rs_dispatch_ready[i] :
                               1'b0;

        if (uop_valid[i] && (int'(uop_accept_count) == i)) begin
          logic can_accept_lane;
          logic [$clog2(WIDTH+1)-1:0] next_rob_needed;

          next_rob_needed = rob_needed_count;
          if (!lane_is_nop[i]) next_rob_needed = rob_needed_count + 1'b1;

          can_accept_lane = lane_is_nop[i] ||
                            (lane_target_ready[i] &&
                             ({{($clog2(ROB_DEPTH+1)-$clog2(WIDTH+1)){1'b0}}, next_rob_needed} <= rob_free_count));

          if (can_accept_lane) begin
            uop_accept_count = uop_accept_count + 1'b1;
            rob_needed_count = next_rob_needed;
          end
        end
      end
    end else begin
      for (int i = 0; i < WIDTH; i++) begin
        lane_is_nop[i] = 1'b1;
        lane_is_mem[i] = 1'b0;
        lane_is_rs_uop[i] = 1'b0;
        lane_target_ready[i] = 1'b1;
      end
    end

    for (int i = 0; i < WIDTH; i++) begin
      dispatch_fire[i] = uop_valid[i] && (i < uop_accept_count) && !lane_is_nop[i];

      arf_raddr1[i] = uop_in[i].rs1;
      arf_raddr2[i] = uop_in[i].rs2;
      rat_raddr1[i] = uop_in[i].rs1;
      rat_raddr2[i] = uop_in[i].rs2;

      rat_src1_eff[i] = rat_rdata1[i];
      rat_src2_eff[i] = rat_rdata2[i];
      lane_same_cycle_src1[i] = 1'b0;
      lane_same_cycle_src2[i] = 1'b0;

      for (int j = 0; j < i; j++) begin
        if (dispatch_fire[j] && uop_in[j].rd_used && (uop_in[j].rd != '0) &&
            uop_in[i].rs1_used && (uop_in[j].rd == uop_in[i].rs1)) begin
          rat_src1_eff[i].valid = 1'b1;
          rat_src1_eff[i].tag = rob_alloc_tag[j];
          lane_same_cycle_src1[i] = 1'b1;
        end

        if (dispatch_fire[j] && uop_in[j].rd_used && (uop_in[j].rd != '0) &&
            uop_in[i].rs2_used && (uop_in[j].rd == uop_in[i].rs2)) begin
          rat_src2_eff[i].valid = 1'b1;
          rat_src2_eff[i].tag = rob_alloc_tag[j];
          lane_same_cycle_src2[i] = 1'b1;
        end
      end

      rob_rd_tag1[i] = rat_src1_eff[i].tag;
      rob_rd_tag2[i] = rat_src2_eff[i].tag;

      src1_operand[i] = resolve_operand(uop_in[i].rs1_used, rat_src1_eff[i],
                                        lane_same_cycle_src1[i], arf_rdata1[i],
                                        rob_rd_done1[i], rob_rd_val1[i], cdb_in);
      src2_operand[i] = resolve_operand(uop_in[i].rs2_used, rat_src2_eff[i],
                                        lane_same_cycle_src2[i], arf_rdata2[i],
                                        rob_rd_done2[i], rob_rd_val2[i], cdb_in);

      rob_alloc_en[i] = dispatch_fire[i];
      rob_alloc_rd_used[i] = uop_in[i].rd_used;
      rob_alloc_dest[i] = uop_in[i].rd;
      rob_alloc_is_control[i] = uop_in[i].is_branch || uop_in[i].is_jump;
      rob_alloc_is_store[i] = uop_in[i].is_store;
      rob_alloc_pc[i] = uop_in[i].pc;

      rat_ren_we[i] = dispatch_fire[i] && uop_in[i].rd_used;
      rat_ren_addr[i] = uop_in[i].rd;
      rat_ren_tag[i] = rob_alloc_tag[i];

      ckpt_save_en[i] = dispatch_fire[i] && (uop_in[i].is_branch || uop_in[i].is_jump);
      ckpt_save_tag[i] = rob_alloc_tag[i];

      rs_dispatch_valid[i] = dispatch_fire[i] && lane_is_rs_uop[i];
      rs_dispatch_uop[i] = uop_in[i];
      rs_dispatch_tag[i] = rob_alloc_tag[i];
      rs_dispatch_src1[i] = src1_operand[i];
      rs_dispatch_src2[i] = src2_operand[i];

      lsq_dispatch_valid[i] = dispatch_fire[i] && lane_is_mem[i];
      lsq_dispatch_uop[i] = uop_in[i];
      lsq_dispatch_tag[i] = rob_alloc_tag[i];
      lsq_dispatch_base[i] = src1_operand[i];
      lsq_dispatch_store_data[i] = src2_operand[i];
    end
  end

endmodule
