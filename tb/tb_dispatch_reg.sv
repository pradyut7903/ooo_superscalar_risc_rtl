`timescale 1ns/1ps
// ============================================================================
// tb_dispatch_reg.sv -- self-checking test for decode-to-dispatch bundle reg.
// ============================================================================
module tb_dispatch_reg;
  import pkg_cpu::*;

  logic clk = 1'b0, rst = 1'b1, flush = 1'b0;
  valid_bundle_t in_valid = '0, out_valid;
  logic in_ready;
  logic [$clog2(WIDTH+1)-1:0] out_accept_count = '0;
  uop_bundle_t in_uop, out_uop;
  int errors = 0;

  dispatch_reg dut (
    .clk(clk), .rst(rst), .flush(flush),
    .in_valid(in_valid), .in_ready(in_ready), .in_uop(in_uop),
    .out_valid(out_valid), .out_accept_count(out_accept_count), .out_uop(out_uop)
  );

  always #5 clk = ~clk;

  task automatic clear_input();
    in_valid = '0;
    for (int i = 0; i < WIDTH; i++) begin
      in_uop[i] = '0;
      in_uop[i].op = UOP_NOP;
      in_uop[i].fu = FU_ALU;
    end
  endtask

  task automatic chk(input string name, input bit cond);
    if (!cond) begin $display("FAIL %s", name); errors++; end
    else       begin $display("ok   %s", name); end
  endtask

  initial begin
    clear_input();
    repeat (2) @(posedge clk);
    rst = 1'b0;
    @(negedge clk); #1;
    chk("reset empty", out_valid == '0);

    @(negedge clk);
    in_valid[0] = 1'b1;
    in_uop[0] = '0;
    in_uop[0].op = ALU_ADD;
    in_uop[0].fu = FU_ALU;
    in_uop[0].rd = 5'd3;
    @(posedge clk); #1;
    clear_input();
    chk("capture lane0", out_valid[0] && (out_uop[0].op == ALU_ADD) && (out_uop[0].rd == 5'd3));

    out_accept_count = '0;
    @(negedge clk);
    in_valid[0] = 1'b1;
    in_uop[0] = '0;
    in_uop[0].op = ALU_SUB;
    in_uop[0].fu = FU_ALU;
    in_uop[0].rd = 5'd4;
    @(posedge clk); #1;
    chk("hold when not ready", out_valid[0] && (out_uop[0].op == ALU_ADD) && !in_ready);
    clear_input();

    out_accept_count = 1;
    @(posedge clk); #1;
    out_accept_count = '0;
    chk("release to empty", out_valid == '0);

    if (WIDTH > 1) begin
      @(negedge clk);
      in_valid[0] = 1'b1;
      in_valid[1] = 1'b1;
      in_uop[0] = '0; in_uop[0].op = ALU_ADD; in_uop[0].rd = 5'd1;
      in_uop[1] = '0; in_uop[1].op = ALU_SUB; in_uop[1].rd = 5'd2;
      @(posedge clk); #1;
      clear_input();
      chk("capture bundle", out_valid[0] && out_valid[1] &&
                            (out_uop[0].rd == 5'd1) && (out_uop[1].rd == 5'd2));
      out_accept_count = 1;
      @(posedge clk); #1;
      out_accept_count = '0;
      chk("partial pop compacts", out_valid[0] && !out_valid[1] && (out_uop[0].rd == 5'd2));
      out_accept_count = 1;
      @(posedge clk); #1;
      out_accept_count = '0;
      chk("bundle released", out_valid == '0);
    end

    @(negedge clk);
    in_valid[0] = 1'b1;
    in_uop[0] = '0;
    in_uop[0].op = ALU_XOR;
    @(posedge clk); #1;
    flush = 1'b1;
    @(posedge clk); #1;
    flush = 1'b0;
    chk("flush clears", out_valid == '0);

    if (errors == 0) $display("TB_DISPATCH_REG: PASS");
    else             $display("TB_DISPATCH_REG: FAIL (%0d errors)", errors);
    $finish;
  end
endmodule
