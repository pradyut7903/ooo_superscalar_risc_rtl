`timescale 1ns/1ps
// ============================================================================
// tb_arf.sv -- self-checking unit test for the architectural register file.
// ============================================================================
module tb_arf;
  import pkg_cpu::*;

  logic clk = 1'b0;
  logic rst = 1'b1;
  reg_idx_t raddr1 [WIDTH], raddr2 [WIDTH];
  data_t rdata1 [WIDTH], rdata2 [WIDTH];

  valid_bundle_t wen = '0;
  reg_idx_t waddr [WIDTH];
  data_t wdata [WIDTH];

  arf dut (
    .clk(clk), .rst(rst),
    .raddr1(raddr1), .rdata1(rdata1),
    .raddr2(raddr2), .rdata2(rdata2),
    .wen(wen), .waddr(waddr), .wdata(wdata)
  );

  always #5 clk = ~clk;
  int errors = 0;

  task automatic clear_writes();
    wen = '0;
    for (int i = 0; i < WIDTH; i++) begin
      waddr[i] = '0;
      wdata[i] = '0;
    end
  endtask

  task automatic wr(input logic [4:0] a, input logic [31:0] d);
    @(negedge clk);
    clear_writes();
    wen[0] = 1'b1; waddr[0] = a; wdata[0] = d;
    @(posedge clk); #1; clear_writes();
  endtask

  task automatic chk(input string name, input data_t got, input data_t exp);
    if (got !== exp) begin $display("FAIL %-26s got=%h exp=%h", name, got, exp); errors++; end
    else                  $display("ok   %-26s = %h", name, got);
  endtask

  initial begin
    clear_writes();
    rst = 1'b1;
    repeat (2) @(posedge clk); rst = 1'b0; @(negedge clk);

    for (int i = 0; i < WIDTH; i++) begin raddr1[i] = '0; raddr2[i] = '0; end
    raddr1[0] = 5'd1; raddr2[0] = 5'd31; #1;
    chk("reset x1", rdata1[0], 32'h0);
    chk("reset x31", rdata2[0], 32'h0);

    wr(5'd1,  32'hDEAD_BEEF);
    wr(5'd2,  32'h1234_5678);
    wr(5'd31, 32'hCAFE_0001);
    raddr1[0] = 5'd1; raddr2[0] = 5'd2; #1;
    chk("x1", rdata1[0], 32'hDEAD_BEEF);
    chk("x2", rdata2[0], 32'h1234_5678);
    raddr1[0] = 5'd31; #1;
    chk("x31", rdata1[0], 32'hCAFE_0001);

    wr(5'd0, 32'hFFFF_FFFF);
    raddr1[0] = 5'd0; #1;
    chk("x0 read", rdata1[0], 32'h0);

    @(negedge clk); raddr1[0] = 5'd7; #1;
    chk("x7 pre-write", rdata1[0], 32'h0);
    clear_writes();
    wen[0] = 1'b1; waddr[0] = 5'd7; wdata[0] = 32'hA5A5_5A5A;
    #1;
    chk("x7 same-cycle(old)", rdata1[0], 32'h0);
    @(posedge clk); #1; clear_writes();
    chk("x7 next-cycle(new)", rdata1[0], 32'hA5A5_5A5A);

    if (WIDTH >= 4) begin
      @(negedge clk);
      clear_writes();
      wen[3:0] = 4'b1111;
      waddr[0] = 5'd8;  wdata[0] = 32'h0000_0008;
      waddr[1] = 5'd9;  wdata[1] = 32'h0000_0009;
      waddr[2] = 5'd8;  wdata[2] = 32'h2222_0008;
      waddr[3] = 5'd10; wdata[3] = 32'h0000_0010;
      @(posedge clk); #1; clear_writes();
      raddr1[0] = 5'd8; raddr2[0] = 5'd9; #1;
      chk("younger write wins x8", rdata1[0], 32'h2222_0008);
      chk("bundle write x9", rdata2[0], 32'h0000_0009);
      raddr1[0] = 5'd10; #1;
      chk("bundle write x10", rdata1[0], 32'h0000_0010);
    end

    if (errors == 0) $display("TB_ARF: PASS");
    else             $display("TB_ARF: FAIL (%0d errors)", errors);
    $finish;
  end
endmodule
