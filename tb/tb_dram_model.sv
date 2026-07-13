`timescale 1ns/1ps
// ============================================================================
// tb_dram_model.sv -- Directed tests for multi-outstanding DRAM.
// ============================================================================
module tb_dram_model;
  import pkg_cpu::*;

  logic clk = 1'b0, rst = 1'b1;
  logic req_valid = 1'b0, req_ready, req_is_instr = 1'b0, req_write = 1'b0;
  data_t req_line_addr = '0;
  cache_line_t req_wdata = '0;
  dram_id_t req_id = '0;
  logic resp_valid;
  cache_line_t resp_rdata;
  dram_id_t resp_id;
  int errors = 0;

  dram_model #(.LAT(3), .IMEM_IMAGE(""), .DMEM_IMAGE("")) dut (
    .clk(clk), .rst(rst),
    .req_valid(req_valid), .req_ready(req_ready),
    .req_is_instr(req_is_instr), .req_write(req_write),
    .req_line_addr(req_line_addr), .req_wdata(req_wdata), .req_id(req_id),
    .resp_valid(resp_valid), .resp_rdata(resp_rdata), .resp_id(resp_id)
  );

  always #5 clk = ~clk;

  task automatic issue(
    input logic is_instr, input logic is_write,
    input data_t addr, input cache_line_t wdata, input dram_id_t id
  );
    @(negedge clk);
    while (!req_ready) @(negedge clk);
    req_valid = 1'b1;
    req_is_instr = is_instr;
    req_write = is_write;
    req_line_addr = addr;
    req_wdata = wdata;
    req_id = id;
    @(posedge clk);
    @(negedge clk);
    req_valid = 1'b0;
  endtask

  task automatic wait_resp(input dram_id_t expect_id, output cache_line_t rdata);
    for (int k = 0; k < 64; k++) begin
      @(posedge clk);
      if (resp_valid) begin
        if (resp_id !== expect_id) begin
          $display("FAIL resp id got=%h exp=%h", resp_id, expect_id);
          errors++;
        end
        rdata = resp_rdata;
        return;
      end
    end
    $display("FAIL timeout DRAM resp");
    errors++;
    rdata = '0;
  endtask

  initial begin
    cache_line_t line, rline;
    dram_id_t id0, id1;
    repeat (3) @(posedge clk);
    rst = 1'b0;

    id0 = dram_id_t'({1'b1, DRAM_MSHR_IDX_W'(0)});
    id1 = dram_id_t'({1'b1, DRAM_MSHR_IDX_W'(1)});

    line = '0;
    line[31:0] = 32'hA5A5_1234;
    line[63:32] = 32'hDEAD_BEEF;
    issue(1'b0, 1'b1, 32'h0000_0040, line, id0);
    wait_resp(id0, rline);
    $display("ok   dram write");

    issue(1'b0, 1'b0, 32'h0000_0040, '0, id0);
    wait_resp(id0, rline);
    if (rline[31:0] !== 32'hA5A5_1234 || rline[63:32] !== 32'hDEAD_BEEF) begin
      $display("FAIL D readback got %h", rline);
      errors++;
    end else $display("ok   dram write/read");

    // Two outstanding reads to different lines
    issue(1'b0, 1'b0, 32'h0000_0040, '0, id0);
    issue(1'b0, 1'b0, 32'h0000_0060, '0, id1);
    wait_resp(id0, rline);
    wait_resp(id1, rline);
    $display("ok   multi-outstanding");

    issue(1'b1, 1'b0, 32'h0, '0, dram_id_t'(0));
    wait_resp(dram_id_t'(0), rline);
    if (rline[31:0] !== INSTR_INVALID) begin
      $display("FAIL empty I line");
      errors++;
    end else $display("ok   dram I empty");

    if (errors == 0) $display("TB_DRAM_MODEL: PASS");
    else             $display("TB_DRAM_MODEL: FAIL (%0d)", errors);
    $finish;
  end
endmodule
