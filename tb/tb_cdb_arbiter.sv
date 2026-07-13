`timescale 1ns/1ps
// ============================================================================
// tb_cdb_arbiter.sv -- self-checking unit test for the generic CDB arbiter.
// ============================================================================
module tb_cdb_arbiter;
  import pkg_cpu::*;

  localparam int PROD_ALU0 = 0;
  localparam int PROD_MUL0 = PROD_ALU0 + NUM_ALU;
  localparam int PROD_DIV0 = PROD_MUL0 + NUM_MUL;
  localparam int PROD_BR0  = PROD_DIV0 + NUM_DIV;
  localparam int PROD_LSQ0 = PROD_BR0 + NUM_BR;

  logic clk = 1'b0, rst = 1'b1, flush = 1'b0;
  cdb_t producer_cdb [NUM_CDB_PRODUCERS];
  logic producer_ready [NUM_CDB_PRODUCERS];
  cdb_bus_t out_cdb;
  logic overflow;
  int errors = 0;

  cdb_arbiter dut (
    .clk(clk), .rst(rst), .flush(flush),
    .producer_cdb(producer_cdb),
    .producer_ready(producer_ready),
    .out_cdb(out_cdb), .overflow(overflow)
  );

  always #5 clk = ~clk;

  task automatic clear_inputs();
    for (int i = 0; i < NUM_CDB_PRODUCERS; i++) producer_cdb[i] = '0;
  endtask

  task automatic set_cdb(input int lane, input rob_tag_t tag, input data_t data);
    producer_cdb[lane].valid = 1'b1;
    producer_cdb[lane].tag = tag;
    producer_cdb[lane].data = data;
  endtask

  task automatic chk_slot(input int slot, input string name, input rob_tag_t tag, input data_t data);
    #1;
    if (!out_cdb[slot].valid || (out_cdb[slot].tag !== tag) || (out_cdb[slot].data !== data)) begin
      $display("FAIL %-24s slot=%0d valid=%0b tag=%0d data=%h exp_tag=%0d exp=%h",
               name, slot, out_cdb[slot].valid, out_cdb[slot].tag, out_cdb[slot].data, tag, data);
      errors++;
    end else begin
      $display("ok   %-24s slot=%0d tag=%0d data=%h", name, slot, out_cdb[slot].tag, out_cdb[slot].data);
    end
  endtask

  initial begin
    clear_inputs();
    repeat (2) @(posedge clk); rst = 1'b0;

    @(negedge clk);
    set_cdb(PROD_ALU0, 5'd1, 32'h1111);
    set_cdb(PROD_MUL0, 5'd2, 32'h2222);
    chk_slot(0, "grant alu0", 5'd1, 32'h1111);
    if (CDB_WIDTH > 1) chk_slot(1, "grant mul0", 5'd2, 32'h2222);
    @(posedge clk); #1; clear_inputs();
    if (CDB_WIDTH == 1) chk_slot(0, "pending mul0", 5'd2, 32'h2222);
    @(posedge clk); #1;
    if (overflow) begin $display("FAIL overflow on two granted results"); errors++; end
    else          $display("ok   no overflow on two granted results");

    @(negedge clk); flush = 1'b1; @(posedge clk); #1; flush = 1'b0;
    @(negedge clk);
    clear_inputs();
    set_cdb(PROD_ALU0, 5'd3, 32'h3333);
    if (NUM_ALU > 1) set_cdb(PROD_ALU0 + 1, 5'd4, 32'h4444);
    else             set_cdb(PROD_MUL0, 5'd4, 32'h4444);
    set_cdb(PROD_DIV0, 5'd5, 32'h5555);
    chk_slot(0, "grant first of three", 5'd3, 32'h3333);
    if (CDB_WIDTH > 1) chk_slot(1, "grant second of three", 5'd4, 32'h4444);
    if (CDB_WIDTH > 2) chk_slot(2, "grant third of three", 5'd5, 32'h5555);
    @(posedge clk); #1; clear_inputs();
    if (CDB_WIDTH <= 2) begin
      chk_slot(0, "buffered third", 5'd5, 32'h5555);
    end
    @(posedge clk); #1;
    if (overflow) begin $display("FAIL overflow on buffered third"); errors++; end
    else          $display("ok   no overflow on buffered third");

    @(negedge clk); flush = 1'b1; @(posedge clk); #1; flush = 1'b0;
    @(negedge clk);
    clear_inputs();
    set_cdb(PROD_BR0, 5'd6, 32'h6666);
    set_cdb(PROD_LSQ0, 5'd7, 32'h7777);
    chk_slot(0, "grant branch lane", 5'd6, 32'h6666);
    if (CDB_WIDTH > 1) chk_slot(1, "grant lsq lane", 5'd7, 32'h7777);
    @(posedge clk); #1; clear_inputs();

    if (errors == 0) $display("TB_CDB_ARBITER: PASS");
    else             $display("TB_CDB_ARBITER: FAIL (%0d errors)", errors);
    $finish;
  end
endmodule
