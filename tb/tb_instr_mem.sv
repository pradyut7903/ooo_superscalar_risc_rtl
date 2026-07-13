`timescale 1ns/1ps
// ============================================================================
// tb_instr_mem.sv -- self-checking unit test for the synchronous instr_mem.
//
// Loads a hand-encoded RV32IM image and checks the
// exact instruction words at each PC plus the end-of-program valid boundary.
// Because the read is registered, we present a PC and check the output on the
// FOLLOWING clock edge.
// ============================================================================
module tb_instr_mem;
  import pkg_cpu::*;

  logic   clk = 1'b0;
  logic   rst = 1'b1;
  pc_bundle_t    pc = '{default:'0};
  valid_bundle_t valid;
  instr_bundle_t word;

  instr_mem #(.DEFAULT_IMAGE("rv32_smoke.imem.hex")) dut (
    .clk(clk), .rst(rst), .en(1'b1), .pc(pc), .valid(valid), .word(word)
  );

  always #5 clk = ~clk;   // 100 MHz

  int errors = 0;

  // Present `p`, let the registered read capture it on the next posedge, check.
  task automatic check(input pc_t p, input logic exp_valid,
                       input logic [31:0] exp_word, input string name);
    @(negedge clk);
    pc = '{default:'0};
    pc[0] = p;
    @(posedge clk);   // mem captures mem[pc] here
    #1;               // settle after the edge
    if (valid[0] !== exp_valid) begin
      $display("FAIL %-12s pc=%h  valid=%0b exp_valid=%0b", name, p, valid[0], exp_valid);
      errors++;
    end else if (exp_valid && (word[0] !== exp_word)) begin
      $display("FAIL %-12s pc=%h  word=%h exp=%h", name, p, word[0], exp_word);
      errors++;
    end else begin
      $display("ok   %-12s pc=%h  valid=%0b word=%h", name, p, valid[0], word[0]);
    end
  endtask

  initial begin
    repeat (2) @(posedge clk);
    rst = 1'b0;

    // rv32_smoke.imem.hex (hand-encoded RV32IM):
    //   0x00  addi x1, x0, 5    -> 00500093
    //   0x04  addi x2, x0, 3    -> 00300113
    //   0x08  add  x3, x1, x2   -> 002081B3
    //   0x0C  sub  x4, x3, x1   -> 40118233
    //   0x10  mul  x5, x1, x2   -> 022082B3
    check('h00, 1'b1, 32'h00500093, "addi");
    check('h04, 1'b1, 32'h00300113, "addi2");
    check('h08, 1'b1, 32'h002081B3, "add");
    check('h0C, 1'b1, 32'h40118233, "sub");
    check('h10, 1'b1, 32'h022082B3, "mul");
    check('h14, 1'b0, 32'h0,        "end-of-prog");

    if (errors == 0) $display("TB_INSTR_MEM: PASS");
    else             $display("TB_INSTR_MEM: FAIL (%0d errors)", errors);
    $finish;
  end
endmodule
