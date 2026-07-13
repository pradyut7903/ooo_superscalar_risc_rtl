`timescale 1ns/1ps
// ============================================================================
// tb_rat.sv -- lane-0 regression for bundled RAT + checkpoint restore.
// ============================================================================
module tb_rat;
  import pkg_cpu::*;

  logic clk = 1'b0, rst = 1'b1;
  reg_idx_t raddr1 [WIDTH], raddr2 [WIDTH];
  rat_entry_t rdata1 [WIDTH], rdata2 [WIDTH];
  valid_bundle_t ren_we = '0, cm_we = '0;
  reg_idx_t ren_addr [WIDTH], cm_addr [WIDTH];
  rob_tag_t ren_tag [WIDTH], cm_tag [WIDTH];
  valid_bundle_t ckpt_save_en = '0;
  rob_tag_t ckpt_save_tag [WIDTH];
  logic ckpt_restore_en = 1'b0;
  rob_tag_t ckpt_restore_tag = '0;
  logic [ROB_DEPTH-1:0] ckpt_invalidate = '0;

  rat dut (
    .clk(clk), .rst(rst),
    .raddr1(raddr1), .rdata1(rdata1), .raddr2(raddr2), .rdata2(rdata2),
    .ren_we(ren_we), .ren_addr(ren_addr), .ren_tag(ren_tag),
    .cm_we(cm_we), .cm_addr(cm_addr), .cm_tag(cm_tag),
    .ckpt_save_en(ckpt_save_en), .ckpt_save_tag(ckpt_save_tag),
    .ckpt_restore_en(ckpt_restore_en), .ckpt_restore_tag(ckpt_restore_tag),
    .ckpt_invalidate(ckpt_invalidate)
  );

  always #5 clk = ~clk;
  int errors = 0;

  task automatic defaults();
    ren_we = '0;
    cm_we = '0;
    ckpt_save_en = '0;
    ckpt_restore_en = 1'b0;
    ckpt_invalidate = '0;
    for (int i = 0; i < WIDTH; i++) begin
      raddr1[i] = '0;
      raddr2[i] = '0;
      ren_addr[i] = '0;
      ren_tag[i] = '0;
      cm_addr[i] = '0;
      cm_tag[i] = '0;
      ckpt_save_tag[i] = '0;
    end
  endtask

  task automatic do_rename(input logic [4:0] a, input logic [4:0] tg);
    @(negedge clk); defaults(); ren_we[0] = 1'b1; ren_addr[0] = a; ren_tag[0] = tg;
    @(posedge clk); #1; defaults();
  endtask

  task automatic do_commit(input logic [4:0] a, input logic [4:0] tg);
    @(negedge clk); defaults(); cm_we[0] = 1'b1; cm_addr[0] = a; cm_tag[0] = tg;
    @(posedge clk); #1; defaults();
  endtask

  task automatic chk(input string name, input logic [4:0] a,
                     input logic ev, input logic [4:0] et);
    raddr1[0] = a; #1;
    if (rdata1[0].valid !== ev)
      begin $display("FAIL %-24s valid got=%0b exp=%0b", name, rdata1[0].valid, ev); errors++; end
    else if (ev && (rdata1[0].tag !== et))
      begin $display("FAIL %-24s tag got=%0d exp=%0d", name, rdata1[0].tag, et); errors++; end
    else $display("ok   %-24s valid=%0b tag=%0d", name, rdata1[0].valid, rdata1[0].tag);
  endtask

  initial begin
    defaults();
    rst = 1'b1; repeat (2) @(posedge clk); rst = 1'b0; @(negedge clk);

    chk("reset x1", 5'd1, 1'b0, 5'd0);

    do_rename(5'd1, 5'd5);
    do_rename(5'd2, 5'd7);
    chk("x1 -> rob5", 5'd1, 1'b1, 5'd5);
    chk("x2 -> rob7", 5'd2, 1'b1, 5'd7);

    do_commit(5'd1, 5'd5);
    chk("x1 committed", 5'd1, 1'b0, 5'd0);

    do_commit(5'd2, 5'd9);
    chk("x2 stale-commit", 5'd2, 1'b1, 5'd7);

    do_rename(5'd3, 5'd4);
    @(negedge clk);
    defaults();
    cm_we[0] = 1'b1; cm_addr[0] = 5'd3; cm_tag[0] = 5'd4;
    ren_we[0] = 1'b1; ren_addr[0] = 5'd3; ren_tag[0] = 5'd2;
    @(posedge clk); #1; defaults();
    chk("x3 rename-beats-commit", 5'd3, 1'b1, 5'd2);

    // Checkpoint: rename x4 under tag 8 while saving ckpt for control tag 3
    @(negedge clk); defaults();
    ren_we[0] = 1'b1; ren_addr[0] = 5'd4; ren_tag[0] = 5'd8;
    ckpt_save_en[0] = 1'b1; ckpt_save_tag[0] = 5'd3;
    @(posedge clk); #1; defaults();
    // Younger rename after checkpoint
    do_rename(5'd4, 5'd9);
    chk("x4 younger rename", 5'd4, 1'b1, 5'd9);
    // Older producer in the checkpoint commits before restore
    do_commit(5'd4, 5'd8);
    chk("live map still younger", 5'd4, 1'b1, 5'd9);
    @(negedge clk); defaults();
    ckpt_restore_en = 1'b1; ckpt_restore_tag = 5'd3;
    @(posedge clk); #1; defaults();
    chk("x4 restore after commit", 5'd4, 1'b0, 5'd0);

    do_rename(5'd0, 5'd12);
    chk("x0 always-ARF", 5'd0, 1'b0, 5'd0);

    if (errors == 0) $display("TB_RAT: PASS");
    else             $display("TB_RAT: FAIL (%0d errors)", errors);
    $finish;
  end
endmodule
