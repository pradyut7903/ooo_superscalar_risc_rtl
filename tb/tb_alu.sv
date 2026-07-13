`timescale 1ns/1ps
// ============================================================================
// tb_alu.sv -- self-checking unit test for the integer ALU.
// ============================================================================
module tb_alu;
  import pkg_cpu::*;

  logic clk = 1'b0, rst = 1'b1, flush = 1'b0;
  logic in_valid = 1'b0, in_ready;
  uop_t in_uop;
  rob_tag_t in_tag = '0;
  data_t src1_value = '0, src2_value = '0;
  logic cdb_ready = 1'b1;
  cdb_t out_cdb;
  int errors = 0;

  alu dut (
    .clk(clk), .rst(rst), .flush(flush),
    .squash_en(1'b0), .squash_tag('0), .rob_head('0),
    .in_valid(in_valid), .in_ready(in_ready), .in_uop(in_uop), .in_tag(in_tag),
    .src1_value(src1_value), .src2_value(src2_value),
    .cdb_ready(cdb_ready), .out_cdb(out_cdb)
  );

  always #5 clk = ~clk;

  task automatic chk(input string name, input data_t got, input data_t exp);
    if (got !== exp) begin $display("FAIL %-18s got=%h exp=%h", name, got, exp); errors++; end
    else                  $display("ok   %-18s = %h", name, got);
  endtask

  task automatic issue_chk(input string name, input op_e op, input data_t a, input data_t b,
                           input data_t imm, input bit use_imm, input pc_t pc,
                           input data_t exp);
    @(negedge clk);
    in_uop = '0; in_uop.fu = FU_ALU; in_uop.op = op; in_uop.rd_used = 1'b1;
    in_uop.imm = imm; in_uop.src2_is_imm = use_imm; in_uop.pc = pc;
    in_tag = 5'd7; src1_value = a; src2_value = b; in_valid = 1'b1; cdb_ready = 1'b1;
    @(posedge clk); #1; in_valid = 1'b0;
    if (!out_cdb.valid || (out_cdb.tag !== 5'd7)) begin
      $display("FAIL %-18s cdb valid/tag", name); errors++;
    end else chk(name, out_cdb.data, exp);
  endtask

  initial begin
    in_uop = '0;
    repeat (2) @(posedge clk); rst = 1'b0;

    issue_chk("add",   ALU_ADD,   32'd10, 32'd5,  '0, 0, '0, 32'd15);
    issue_chk("sub",   ALU_SUB,   32'd10, 32'd5,  '0, 0, '0, 32'd5);
    issue_chk("sll",   ALU_SLL,   32'h1,  32'd4,  '0, 0, '0, 32'h10);
    issue_chk("slt",   ALU_SLT,   32'hFFFF_FFFF, 32'd1, '0, 0, '0, 32'd1);
    issue_chk("sltu",  ALU_SLTU,  32'hFFFF_FFFF, 32'd1, '0, 0, '0, 32'd0);
    issue_chk("sra",   ALU_SRA,   32'h8000_0000, 32'd4, '0, 0, '0, 32'hF800_0000);
    issue_chk("addi",  ALU_ADD,   32'd3,  '0, 32'd9, 1, '0, 32'd12);
    issue_chk("lui",   ALU_LUI,   '0,     '0, 32'h1234_5000, 1, '0, 32'h1234_5000);
    issue_chk("auipc", ALU_AUIPC, '0,     '0, 32'h1000, 1, 32'h2000, 32'h3000);

    @(posedge clk); #1; // drain the previous accepted result
    @(negedge clk);
    cdb_ready = 1'b0; in_valid = 1'b1; in_uop.op = ALU_ADD; src1_value = 32'd1; src2_value = 32'd2;
    #1; if (in_ready) begin $display("FAIL stall in_ready high"); errors++; end
    @(posedge clk); #1; if (out_cdb.valid) begin $display("FAIL stalled issue produced result"); errors++; end
    cdb_ready = 1'b1; in_valid = 1'b0;

    if (errors == 0) $display("TB_ALU: PASS");
    else             $display("TB_ALU: FAIL (%0d errors)", errors);
    $finish;
  end
endmodule
