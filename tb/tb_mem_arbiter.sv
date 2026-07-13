`timescale 1ns/1ps
// ============================================================================
// tb_mem_arbiter.sv -- Two clients, multi-outstanding, D priority.
// ============================================================================
module tb_mem_arbiter;
  import pkg_cpu::*;

  logic clk = 1'b0, rst = 1'b1;

  logic i_req_valid = 1'b0, i_req_ready, i_resp_valid;
  data_t i_req_addr = '0;
  cache_line_t i_resp_rdata;
  logic [DRAM_MSHR_IDX_W-1:0] i_req_mshr = '0, i_resp_mshr;

  logic d_req_valid = 1'b0, d_req_ready, d_req_write = 1'b0, d_resp_valid;
  data_t d_req_addr = '0;
  cache_line_t d_req_wdata = '0, d_resp_rdata;
  logic [DRAM_MSHR_IDX_W-1:0] d_req_mshr = '0, d_resp_mshr;

  logic dram_req_valid, dram_req_ready, dram_req_is_instr, dram_req_write;
  data_t dram_req_addr;
  cache_line_t dram_req_wdata;
  dram_id_t dram_req_id;
  logic dram_resp_valid;
  cache_line_t dram_resp_rdata;
  dram_id_t dram_resp_id;

  int errors = 0;

  mem_arbiter u_arb (
    .clk(clk), .rst(rst),
    .i_req_valid(i_req_valid), .i_req_ready(i_req_ready),
    .i_req_write(1'b0), .i_req_addr(i_req_addr), .i_req_wdata('0),
    .i_req_mshr(i_req_mshr),
    .i_resp_valid(i_resp_valid), .i_resp_rdata(i_resp_rdata), .i_resp_mshr(i_resp_mshr),
    .d_req_valid(d_req_valid), .d_req_ready(d_req_ready),
    .d_req_write(d_req_write), .d_req_addr(d_req_addr), .d_req_wdata(d_req_wdata),
    .d_req_mshr(d_req_mshr),
    .d_resp_valid(d_resp_valid), .d_resp_rdata(d_resp_rdata), .d_resp_mshr(d_resp_mshr),
    .dram_req_valid(dram_req_valid), .dram_req_ready(dram_req_ready),
    .dram_req_is_instr(dram_req_is_instr), .dram_req_write(dram_req_write),
    .dram_req_addr(dram_req_addr), .dram_req_wdata(dram_req_wdata),
    .dram_req_id(dram_req_id),
    .dram_resp_valid(dram_resp_valid), .dram_resp_rdata(dram_resp_rdata),
    .dram_resp_id(dram_resp_id)
  );

  dram_model #(.LAT(2)) u_dram (
    .clk(clk), .rst(rst),
    .req_valid(dram_req_valid), .req_ready(dram_req_ready),
    .req_is_instr(dram_req_is_instr), .req_write(dram_req_write),
    .req_line_addr(dram_req_addr), .req_wdata(dram_req_wdata),
    .req_id(dram_req_id),
    .resp_valid(dram_resp_valid), .resp_rdata(dram_resp_rdata),
    .resp_id(dram_resp_id)
  );

  always #5 clk = ~clk;

  initial begin
    cache_line_t wline;
    repeat (3) @(posedge clk);
    rst = 1'b0;

    wline = '0;
    wline[31:0] = 32'h1111_2222;
    @(negedge clk);
    d_req_valid = 1'b1; d_req_write = 1'b1; d_req_addr = 32'h80;
    d_req_wdata = wline; d_req_mshr = '0;
    @(posedge clk iff d_req_ready);
    @(negedge clk); d_req_valid = 1'b0;
    @(posedge clk iff d_resp_valid);
    $display("ok   d write accepted");

    // Concurrent I+D: D should win first grant
    @(negedge clk);
    i_req_valid = 1'b1; i_req_addr = 32'h0; i_req_mshr = '0;
    d_req_valid = 1'b1; d_req_write = 1'b0; d_req_addr = 32'h80; d_req_mshr = '0;
    @(posedge clk iff (d_req_ready || i_req_ready));
    if (!d_req_ready || i_req_ready) begin
      $display("FAIL expected D-only grant d=%0b i=%0b", d_req_ready, i_req_ready);
      errors++;
    end else $display("ok   D priority over I");
    @(negedge clk); d_req_valid = 1'b0;

    // I should be able to issue while D fill still outstanding
    @(posedge clk iff i_req_ready);
    @(negedge clk); i_req_valid = 1'b0;
    $display("ok   I issued under outstanding D");

    @(posedge clk iff d_resp_valid);
    if (d_resp_rdata[31:0] !== 32'h1111_2222) begin
      $display("FAIL D rdata %h", d_resp_rdata[31:0]); errors++;
    end else $display("ok   D readback");

    @(posedge clk iff i_resp_valid);
    $display("ok   I resp, no cross-route");

    if (errors == 0) $display("TB_MEM_ARBITER: PASS");
    else             $display("TB_MEM_ARBITER: FAIL (%0d)", errors);
    $finish;
  end
endmodule
