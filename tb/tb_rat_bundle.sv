`timescale 1ns/1ps
// ============================================================================
// tb_rat_bundle.sv -- WIDTH-lane RAT rename/commit priority checks.
// Run with WIDTH >= 4.  The default WIDTH=1 build reports SKIP.
// ============================================================================
module tb_rat_bundle;
  import pkg_cpu::*;

  logic clk = 1'b0, rst = 1'b1;
  reg_idx_t raddr1 [WIDTH], raddr2 [WIDTH];
  rat_entry_t rdata1 [WIDTH], rdata2 [WIDTH];
  valid_bundle_t ren_we = '0, cm_we = '0;
  reg_idx_t ren_addr [WIDTH], cm_addr [WIDTH];
  rob_tag_t ren_tag [WIDTH], cm_tag [WIDTH];
  rob_tag_t ckpt_save_tag [WIDTH];

  int errors = 0;

  initial begin
    for (int i = 0; i < WIDTH; i++) ckpt_save_tag[i] = '0;
  end

  rat dut (
    .clk(clk), .rst(rst),
    .ckpt_save_en('0), .ckpt_save_tag(ckpt_save_tag),
    .ckpt_restore_en(1'b0), .ckpt_restore_tag('0),
    .ckpt_invalidate('0),
    .raddr1(raddr1), .rdata1(rdata1), .raddr2(raddr2), .rdata2(rdata2),
    .ren_we(ren_we), .ren_addr(ren_addr), .ren_tag(ren_tag),
    .cm_we(cm_we), .cm_addr(cm_addr), .cm_tag(cm_tag)
  );

  always #5 clk = ~clk;

  task automatic defaults();
    ren_we = '0;
    cm_we = '0;
    for (int i = 0; i < WIDTH; i++) begin
      raddr1[i] = '0;
      raddr2[i] = '0;
      ren_addr[i] = '0;
      ren_tag[i] = '0;
      cm_addr[i] = '0;
      cm_tag[i] = '0;
    end
  endtask

  task automatic chk(input string name, input bit cond);
    if (!cond) begin $display("FAIL %s", name); errors++; end
    else       begin $display("ok   %s", name); end
  endtask

  task automatic read1(input int lane, input reg_idx_t addr);
    raddr1[lane] = addr;
    #1;
  endtask

  generate
    if (WIDTH >= 4) begin : gen_bundle_test
      initial begin
        defaults();
        rst = 1'b1; repeat (2) @(posedge clk); rst = 1'b0; @(negedge clk);

        @(negedge clk);
        defaults();
        ren_we[3:0] = 4'b1111;
        ren_addr[0] = 5'd1; ren_tag[0] = 5'd4;
        ren_addr[1] = 5'd2; ren_tag[1] = 5'd5;
        ren_addr[2] = 5'd1; ren_tag[2] = 5'd6;
        ren_addr[3] = 5'd3; ren_tag[3] = 5'd7;
        @(posedge clk); #1; defaults();

        read1(0, 5'd1);
        chk("younger rename lane wins", rdata1[0].valid && (rdata1[0].tag == 5'd6));
        read1(1, 5'd2);
        chk("independent rename lane", rdata1[1].valid && (rdata1[1].tag == 5'd5));

        @(negedge clk);
        defaults();
        cm_we[2:0] = 3'b111;
        cm_addr[0] = 5'd1; cm_tag[0] = 5'd4;
        cm_addr[1] = 5'd2; cm_tag[1] = 5'd5;
        cm_addr[2] = 5'd3; cm_tag[2] = 5'd7;
        @(posedge clk); #1; defaults();

        read1(0, 5'd1);
        chk("stale commit ignored", rdata1[0].valid && (rdata1[0].tag == 5'd6));
        read1(1, 5'd2);
        chk("matching commit clears", !rdata1[1].valid);
        read1(2, 5'd3);
        chk("another matching commit clears", !rdata1[2].valid);

        @(negedge clk);
        defaults();
        cm_we[0] = 1'b1; cm_addr[0] = 5'd1; cm_tag[0] = 5'd6;
        ren_we[1] = 1'b1; ren_addr[1] = 5'd1; ren_tag[1] = 5'd9;
        ren_we[3] = 1'b1; ren_addr[3] = 5'd1; ren_tag[3] = 5'd10;
        @(posedge clk); #1; defaults();

        read1(0, 5'd1);
        chk("rename beats commit and youngest wins", rdata1[0].valid && (rdata1[0].tag == 5'd10));

        @(negedge clk);
        defaults();
        rst = 1'b1;
        @(posedge clk); #1; rst = 1'b0; defaults();

        read1(0, 5'd1);
        chk("rst clears old map", !rdata1[0].valid);
        read1(1, 5'd4);
        chk("rst clears rename target", !rdata1[1].valid);

        if (errors == 0) $display("TB_RAT_BUNDLE: PASS");
        else             $display("TB_RAT_BUNDLE: FAIL (%0d errors)", errors);
        $finish;
      end
    end else begin : gen_skip
      initial begin
        $display("TB_RAT_BUNDLE: SKIP (WIDTH=%0d)", WIDTH);
        $finish;
      end
    end
  endgenerate
endmodule
