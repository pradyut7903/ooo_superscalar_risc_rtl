`timescale 1ns/1ps
// ============================================================================
// tb_rename_dispatch_bundle.sv -- WIDTH-lane intra-cycle rename checks.
// Run with WIDTH >= 2.  The default WIDTH=1 build reports SKIP.
// ============================================================================
module tb_rename_dispatch_bundle;
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

  task automatic chk(input string name, input bit cond);
    if (!cond) begin $display("FAIL %s", name); errors++; end
    else       begin $display("ok   %s", name); end
  endtask

  generate
    if (WIDTH >= 2) begin : gen_bundle_test
      task automatic defaults();
        uop_valid = '0;
        cdb_in = '{default:'0};
        rs_dispatch_ready = '1;
        lsq_dispatch_ready = '1;
        rob_free_count = ROB_DEPTH;
        for (int i = 0; i < WIDTH; i++) begin
          uop_in[i] = '0;
          uop_in[i].fu = FU_ALU;
          uop_in[i].op = ALU_ADD;
          uop_in[i].rs1_used = 1'b1;
          uop_in[i].rs1 = 5'd0;
          uop_in[i].rs2_used = 1'b0;
          uop_in[i].rd_used = 1'b1;
          uop_in[i].rd = reg_idx_t'(i + 1);
          arf_rdata1[i] = 32'h1000 + i;
          arf_rdata2[i] = 32'h2000 + i;
          rat_rdata1[i] = '{valid: 1'b0, tag: '0};
          rat_rdata2[i] = '{valid: 1'b0, tag: '0};
          rob_alloc_tag[i] = rob_tag_t'(7 + i);
          rob_rd_done1[i] = 1'b1;
          rob_rd_done2[i] = 1'b1;
          rob_rd_val1[i] = 32'hAAAA_0000 + i;
          rob_rd_val2[i] = 32'hBBBB_0000 + i;
        end
      endtask

      initial begin
        defaults();
        uop_valid[1:0] = 2'b11;
        uop_in[0].rd = 5'd1;
        uop_in[1].rs1 = 5'd1;
        uop_in[1].rd = 5'd2;
        #1;
        chk("two-lane bundle accepted", (uop_accept_count == 2) && (&dispatch_fire[1:0]));
        chk("lane1 sees lane0 tag", !rs_dispatch_src1[1].ready &&
                                      (rs_dispatch_src1[1].tag == 5'd7));
        chk("same-cycle producer suppresses stale ROB done",
            rs_dispatch_src1[1].value != 32'hAAAA_0001);
        chk("lane RAT writes", rat_ren_we[0] && (rat_ren_tag[0] == 5'd7) &&
                               rat_ren_we[1] && (rat_ren_tag[1] == 5'd8));

        defaults();
        uop_valid[1:0] = 2'b11;
        uop_in[0].fu = FU_MUL;
        uop_in[0].op = MD_MUL;
        uop_in[0].rs1 = 5'd1;
        uop_in[0].rs2 = 5'd2;
        uop_in[0].rd = 5'd3;
        uop_in[1].fu = FU_MEM;
        uop_in[1].op = MEM_SW;
        uop_in[1].is_store = 1'b1;
        uop_in[1].rs1_used = 1'b1;
        uop_in[1].rs1 = 5'd0;
        uop_in[1].rs2_used = 1'b1;
        uop_in[1].rs2 = 5'd3;
        uop_in[1].rd_used = 1'b0;
        uop_in[1].rd = '0;
        #1;
        chk("mul/store bundle accepted", (uop_accept_count == 2) && (&dispatch_fire[1:0]));
        chk("store data waits on same-cycle mul tag",
            lsq_dispatch_valid[1] && !lsq_dispatch_store_data[1].ready &&
            (lsq_dispatch_store_data[1].tag == 5'd7));

        if (WIDTH >= 4) begin
          defaults();
          uop_valid[3:0] = 4'b1111;
          uop_in[0].rd = 5'd1;
          uop_in[1].rd = 5'd2;
          uop_in[2].rd = 5'd1;
          uop_in[3].rs1 = 5'd1;
          uop_in[3].rd = 5'd4;
          #1;
          chk("four-lane bundle accepted", (uop_accept_count == 4) && (&dispatch_fire[3:0]));
          chk("youngest older same-cycle rename wins", !rs_dispatch_src1[3].ready &&
                                                    (rs_dispatch_src1[3].tag == 5'd9));

          rob_free_count = 3; #1;
          chk("insufficient ROB slots accepts prefix", (uop_accept_count == 3) &&
                                                   (dispatch_fire[2:0] == 3'b111) && !dispatch_fire[3]);
        end

        defaults();
        uop_valid[1:0] = 2'b11;
        rs_dispatch_ready[1] = 1'b0;
        #1;
        chk("target backpressure accepts prefix", (uop_accept_count == 1) &&
                                                  dispatch_fire[0] && !dispatch_fire[1]);

        if (errors == 0) $display("TB_RENAME_DISPATCH_BUNDLE: PASS");
        else             $display("TB_RENAME_DISPATCH_BUNDLE: FAIL (%0d errors)", errors);
        $finish;
      end
    end else begin : gen_skip
      initial begin
        $display("TB_RENAME_DISPATCH_BUNDLE: SKIP (WIDTH=%0d)", WIDTH);
        $finish;
      end
    end
  endgenerate
endmodule
