`timescale 1ns/1ps
// ============================================================================
// tb_div.sv -- self-checking unit test for the RV32M divide unit.
// ============================================================================
module tb_div;
  import pkg_cpu::*;

  logic clk = 1'b0, rst = 1'b1, flush = 1'b0;
  logic in_valid = 1'b0, in_ready, cdb_ready = 1'b1;
  uop_t in_uop;
  rob_tag_t in_tag = '0;
  data_t src1_value = '0, src2_value = '0;
  cdb_t out_cdb;
  int errors = 0;

  div dut (
    .clk(clk), .rst(rst), .flush(flush),
    .squash_en(1'b0), .squash_tag('0), .rob_head('0),
    .in_valid(in_valid), .in_ready(in_ready), .in_uop(in_uop), .in_tag(in_tag),
    .src1_value(src1_value), .src2_value(src2_value), .cdb_ready(cdb_ready), .out_cdb(out_cdb)
  );

  always #5 clk = ~clk;

  task automatic issue_chk(input string name, input op_e op, input data_t a, input data_t b, input data_t exp);
    @(negedge clk);
    in_uop = '0; in_uop.fu = FU_DIV; in_uop.op = op; in_uop.rd_used = 1'b1;
    in_tag = 5'd4; src1_value = a; src2_value = b; in_valid = 1'b1; cdb_ready = 1'b1;
    @(posedge clk); #1; in_valid = 1'b0;
    repeat (DIV_STAGES-1) @(posedge clk);
    #1;
    if (!out_cdb.valid || (out_cdb.tag !== 5'd4) || (out_cdb.data !== exp)) begin
      $display("FAIL %-14s valid=%0b tag=%0d data=%h exp=%h",
               name, out_cdb.valid, out_cdb.tag, out_cdb.data, exp); errors++;
    end else $display("ok   %-14s = %h", name, out_cdb.data);
  endtask

  task automatic expect_cdb(input string name, input rob_tag_t tag, input data_t exp);
    #1;
    if (!out_cdb.valid || (out_cdb.tag !== tag) || (out_cdb.data !== exp)) begin
      $display("FAIL %-14s valid=%0b tag=%0d data=%h exp_tag=%0d exp=%h",
               name, out_cdb.valid, out_cdb.tag, out_cdb.data, tag, exp);
      errors++;
    end else $display("ok   %-14s tag=%0d data=%h", name, out_cdb.tag, out_cdb.data);
  endtask

  task automatic wait_cdb(input string name, input rob_tag_t tag, input data_t exp);
    bit seen;
    seen = 1'b0;
    for (int i = 0; i < DIV_STAGES + 4; i++) begin
      #1;
      if (out_cdb.valid) begin
        seen = 1'b1;
        if ((out_cdb.tag !== tag) || (out_cdb.data !== exp)) begin
          $display("FAIL %-14s tag=%0d data=%h exp_tag=%0d exp=%h",
                   name, out_cdb.tag, out_cdb.data, tag, exp);
          errors++;
        end else $display("ok   %-14s tag=%0d data=%h", name, out_cdb.tag, out_cdb.data);
        break;
      end
      @(posedge clk);
    end
    if (!seen) begin
      $display("FAIL %-14s no CDB result", name);
      errors++;
    end
  endtask

  task automatic issue_one(input rob_tag_t tag, input data_t a, input data_t b);
    @(negedge clk);
    in_uop = '0; in_uop.fu = FU_DIV; in_uop.op = MD_DIVU; in_uop.rd_used = 1'b1;
    in_tag = tag; src1_value = a; src2_value = b; in_valid = 1'b1; cdb_ready = 1'b1;
    @(posedge clk); #1;
  endtask

  task automatic pipeline_throughput_chk();
    repeat (DIV_STAGES) @(posedge clk);
    issue_one(5'd1, 32'd20, 32'd2);
    issue_one(5'd2, 32'd30, 32'd3);
    issue_one(5'd3, 32'd44, 32'd4);
    in_valid = 1'b0;
    wait_cdb("pipe result0", 5'd1, 32'd10);
    @(posedge clk); expect_cdb("pipe result1", 5'd2, 32'd10);
    @(posedge clk); expect_cdb("pipe result2", 5'd3, 32'd11);
  endtask

  initial begin
    in_uop = '0; repeat (2) @(posedge clk); rst = 1'b0;

    issue_chk("div",       MD_DIV,  32'hFFFF_FFF4, 32'd3, 32'hFFFF_FFFC);
    issue_chk("divu",      MD_DIVU, 32'd20,        32'd3, 32'd6);
    issue_chk("rem",       MD_REM,  32'hFFFF_FFF4, 32'd5, 32'hFFFF_FFFE);
    issue_chk("remu",      MD_REMU, 32'd20,        32'd3, 32'd2);
    issue_chk("div-by-0",  MD_DIV,  32'd9,         32'd0, 32'hFFFF_FFFF);
    issue_chk("rem-by-0",  MD_REM,  32'd9,         32'd0, 32'd9);
    issue_chk("overflow",  MD_DIV,  32'h8000_0000, 32'hFFFF_FFFF, 32'h8000_0000);
    pipeline_throughput_chk();

    if (errors == 0) $display("TB_DIV: PASS");
    else             $display("TB_DIV: FAIL (%0d errors)", errors);
    $finish;
  end
endmodule
