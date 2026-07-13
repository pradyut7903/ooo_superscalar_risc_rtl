`timescale 1ns/1ps
// ============================================================================
// tb_rename_dispatch.sv -- lane-0 regression for bundle rename/dispatch.
// ============================================================================
module tb_rename_dispatch;
  import pkg_cpu::*;

  valid_bundle_t uop_valid, dispatch_fire;
  logic [$clog2(WIDTH+1)-1:0] uop_accept_count;
  uop_bundle_t uop_in;
  cdb_bus_t cdb_in;

  reg_idx_t arf_raddr1 [WIDTH], arf_raddr2 [WIDTH];
  data_t arf_rdata1 [WIDTH], arf_rdata2 [WIDTH];
  reg_idx_t rat_raddr1 [WIDTH], rat_raddr2 [WIDTH];
  rat_entry_t rat_rdata1 [WIDTH], rat_rdata2 [WIDTH];
  valid_bundle_t rat_ren_we;
  reg_idx_t rat_ren_addr [WIDTH];
  rob_tag_t rat_ren_tag [WIDTH];

  valid_bundle_t rob_alloc_en;
  logic rob_alloc_rd_used [WIDTH];
  logic rob_alloc_is_control [WIDTH];
  logic rob_alloc_is_store [WIDTH];
  pc_t rob_alloc_pc [WIDTH];
  reg_idx_t rob_alloc_dest [WIDTH];
  rob_tag_t rob_alloc_tag [WIDTH];
  logic [$clog2(ROB_DEPTH+1)-1:0] rob_free_count;
  rob_tag_t rob_rd_tag1 [WIDTH], rob_rd_tag2 [WIDTH];
  logic rob_rd_done1 [WIDTH], rob_rd_done2 [WIDTH];
  data_t rob_rd_val1 [WIDTH], rob_rd_val2 [WIDTH];

  valid_bundle_t rs_dispatch_valid, rs_dispatch_ready;
  uop_bundle_t rs_dispatch_uop;
  rob_tag_t rs_dispatch_tag [WIDTH];
  operand_t rs_dispatch_src1 [WIDTH], rs_dispatch_src2 [WIDTH];

  valid_bundle_t lsq_dispatch_valid, lsq_dispatch_ready;
  uop_bundle_t lsq_dispatch_uop;
  rob_tag_t lsq_dispatch_tag [WIDTH];
  operand_t lsq_dispatch_base [WIDTH], lsq_dispatch_store_data [WIDTH];

  int errors = 0;

  rename_dispatch dut (
    .uop_valid(uop_valid), .uop_accept_count(uop_accept_count), .uop_in(uop_in), .cdb_in(cdb_in),
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
    .dispatch_fire(dispatch_fire),
    .ckpt_save_en(), .ckpt_save_tag(),
    .recover_en(1'b0)
  );

  task automatic defaults();
    uop_valid = '0;
    cdb_in = '{default:'0};
    rs_dispatch_ready = '1;
    lsq_dispatch_ready = '1;
    rob_free_count = ROB_DEPTH;
    for (int i = 0; i < WIDTH; i++) begin
      uop_in[i] = '0; uop_in[i].op = UOP_NOP; uop_in[i].fu = FU_ALU;
      arf_rdata1[i] = 32'h1111_0001; arf_rdata2[i] = 32'h2222_0002;
      rat_rdata1[i] = '{valid: 1'b0, tag: '0};
      rat_rdata2[i] = '{valid: 1'b0, tag: '0};
      rob_alloc_tag[i] = rob_tag_t'(13 + i);
      rob_rd_done1[i] = 1'b0; rob_rd_done2[i] = 1'b0;
      rob_rd_val1[i] = 32'hAAAA_0001; rob_rd_val2[i] = 32'hBBBB_0002;
    end
  endtask

  task automatic chk(input string name, input bit cond);
    if (!cond) begin $display("FAIL %s", name); errors++; end
    else       begin $display("ok   %s", name); end
  endtask

  initial begin
    defaults(); #1;

    uop_valid[0] = 1'b1;
    uop_in[0] = '0; uop_in[0].fu = FU_ALU; uop_in[0].op = ALU_ADD;
    uop_in[0].rs1_used = 1'b1; uop_in[0].rs1 = 5'd1;
    uop_in[0].rs2_used = 1'b1; uop_in[0].rs2 = 5'd2;
    uop_in[0].rd_used = 1'b1; uop_in[0].rd = 5'd5;
    #1;
    chk("ALU accepted", (uop_accept_count == 1) && dispatch_fire[0]);
    chk("read addrs", (arf_raddr1[0] == 5'd1) && (rat_raddr2[0] == 5'd2));
    chk("ROB alloc", rob_alloc_en[0] && rob_alloc_rd_used[0] && (rob_alloc_dest[0] == 5'd5));
    chk("RAT rename", rat_ren_we[0] && (rat_ren_addr[0] == 5'd5) && (rat_ren_tag[0] == 5'd13));
    chk("RS route", rs_dispatch_valid[0] && !lsq_dispatch_valid[0] && (rs_dispatch_tag[0] == 5'd13));
    chk("ARF operands", rs_dispatch_src1[0].ready && (rs_dispatch_src1[0].value == 32'h1111_0001) &&
                        rs_dispatch_src2[0].ready && (rs_dispatch_src2[0].value == 32'h2222_0002));

    rat_rdata1[0] = '{valid: 1'b1, tag: 5'd6};
    rob_rd_done1[0] = 1'b0; cdb_in = '{default:'0}; #1;
    chk("waiting ROB operand", !rs_dispatch_src1[0].ready && (rs_dispatch_src1[0].tag == 5'd6));

    cdb_in[0].valid = 1'b1; cdb_in[0].tag = 5'd6; cdb_in[0].data = 32'hCDB0_0006; #1;
    chk("CDB bypass operand", rs_dispatch_src1[0].ready && (rs_dispatch_src1[0].value == 32'hCDB0_0006));

    cdb_in = '{default:'0}; rob_rd_done1[0] = 1'b1; rob_rd_val1[0] = 32'h0B0B_0006; #1;
    chk("ROB done operand", rs_dispatch_src1[0].ready && (rs_dispatch_src1[0].value == 32'h0B0B_0006));

    defaults();
    uop_valid[0] = 1'b1;
    uop_in[0] = '0; uop_in[0].fu = FU_MEM; uop_in[0].op = MEM_SW; uop_in[0].is_store = 1'b1;
    uop_in[0].rs1_used = 1'b1; uop_in[0].rs1 = 5'd3;
    uop_in[0].rs2_used = 1'b1; uop_in[0].rs2 = 5'd4;
    uop_in[0].rd_used = 1'b0;
    arf_rdata1[0] = 32'h1000; arf_rdata2[0] = 32'hDEAD_BEEF; #1;
    chk("LSQ route", lsq_dispatch_valid[0] && !rs_dispatch_valid[0] && (lsq_dispatch_tag[0] == 5'd13));
    chk("LSQ operands", lsq_dispatch_base[0].value == 32'h1000 &&
                        lsq_dispatch_store_data[0].value == 32'hDEAD_BEEF);
    chk("store not control", !rob_alloc_is_control[0]);

    uop_in[0].is_store = 1'b0; uop_in[0].is_branch = 1'b1; uop_in[0].fu = FU_BR; uop_in[0].op = BR_EQ; #1;
    chk("branch alloc control", rob_alloc_is_control[0]);

    rob_free_count = '0; #1;
    chk("ROB full stalls", (uop_accept_count == 0) && !dispatch_fire[0] && !lsq_dispatch_valid[0]);

    defaults();
    uop_valid[0] = 1'b1; uop_in[0] = '0; uop_in[0].op = UOP_NOP; uop_in[0].fu = FU_ALU;
    rob_free_count = '0; rs_dispatch_ready[0] = 1'b0; #1;
    chk("NOP consumes without side effects", (uop_accept_count == 1) && !dispatch_fire[0] &&
                                      !rob_alloc_en[0] && !rat_ren_we[0] && !rs_dispatch_valid[0]);

    if (errors == 0) $display("TB_RENAME_DISPATCH: PASS");
    else             $display("TB_RENAME_DISPATCH: FAIL (%0d errors)", errors);
    $finish;
  end
endmodule
