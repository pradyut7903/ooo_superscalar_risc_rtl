`timescale 1ns/1ps
// ============================================================================
// tb_decode.sv -- self-checking unit test for the RV32IM decoder.
//
// Drives hand-encoded instructions (one per RISC-V format + M-extension + the
// x0-write rule) and checks the decoded uop fields against expected values.
// decode is pure combinational, so no clock is needed.
// ============================================================================
module tb_decode;
  import pkg_cpu::*;

  instr_t inst;
  pc_t    pc;
  uop_t   uop;

  decode dut (.inst(inst), .pc(pc), .uop(uop));

  int errors = 0;

  task automatic expect_uop(
      input string       name,
      input op_e         eop,
      input fu_e         efu,
      input logic        erd_u,  input logic [4:0] erd,
      input logic        ers1_u, input logic [4:0] ers1,
      input logic        ers2_u, input logic [4:0] ers2,
      input logic [31:0] eimm);
    logic ok;
    #1;
    ok = 1'b1;
    if (uop.op       !== eop)    begin $display("FAIL %-6s op  got=%0d exp=%0d", name, uop.op, eop);              ok = 0; end
    if (uop.fu       !== efu)    begin $display("FAIL %-6s fu  got=%0d exp=%0d", name, uop.fu, efu);              ok = 0; end
    if (uop.rd_used  !== erd_u)  begin $display("FAIL %-6s rd_used got=%0b exp=%0b", name, uop.rd_used,  erd_u);  ok = 0; end
    if (erd_u  && (uop.rd  !== erd))  begin $display("FAIL %-6s rd  got=%0d exp=%0d", name, uop.rd,  erd);        ok = 0; end
    if (uop.rs1_used !== ers1_u) begin $display("FAIL %-6s rs1_used got=%0b exp=%0b", name, uop.rs1_used, ers1_u);ok = 0; end
    if (ers1_u && (uop.rs1 !== ers1)) begin $display("FAIL %-6s rs1 got=%0d exp=%0d", name, uop.rs1, ers1);       ok = 0; end
    if (uop.rs2_used !== ers2_u) begin $display("FAIL %-6s rs2_used got=%0b exp=%0b", name, uop.rs2_used, ers2_u);ok = 0; end
    if (ers2_u && (uop.rs2 !== ers2)) begin $display("FAIL %-6s rs2 got=%0d exp=%0d", name, uop.rs2, ers2);       ok = 0; end
    if (uop.imm      !== eimm)   begin $display("FAIL %-6s imm got=%h exp=%h", name, uop.imm, eimm);              ok = 0; end
    if (ok) $display("ok   %-6s op=%0d fu=%0d rd=%0d imm=%h", name, uop.op, uop.fu, uop.rd, uop.imm);
    else errors++;
  endtask

  initial begin
    pc = 32'h0000_0000;

    //                          name    op        fu       rd_u rd     rs1_u rs1    rs2_u rs2    imm
    inst = 32'h00500093; expect_uop("addi", ALU_ADD, FU_ALU, 1,5'd1, 1,5'd0, 0,5'd0, 32'd5);
    inst = 32'h002081B3; expect_uop("add",  ALU_ADD, FU_ALU, 1,5'd3, 1,5'd1, 1,5'd2, 32'd0);
    inst = 32'h40118233; expect_uop("sub",  ALU_SUB, FU_ALU, 1,5'd4, 1,5'd3, 1,5'd1, 32'd0);
    inst = 32'h022082B3; expect_uop("mul",  MD_MUL,  FU_MUL, 1,5'd5, 1,5'd1, 1,5'd2, 32'd0);
    inst = 32'h0080A303; expect_uop("lw",   MEM_LW,  FU_MEM, 1,5'd6, 1,5'd1, 0,5'd0, 32'd8);
    inst = 32'h0020A623; expect_uop("sw",   MEM_SW,  FU_MEM, 0,5'd0, 1,5'd1, 1,5'd2, 32'd12);
    inst = 32'h00208463; expect_uop("beq",  BR_EQ,   FU_BR,  0,5'd0, 1,5'd1, 1,5'd2, 32'd8);
    inst = 32'h010000EF; expect_uop("jal",  BR_JAL,  FU_BR,  1,5'd1, 0,5'd0, 0,5'd0, 32'd16);
    inst = 32'h123453B7; expect_uop("lui",  ALU_LUI, FU_ALU, 1,5'd7, 0,5'd0, 0,5'd0, 32'h12345000);
    inst = 32'h00000013; expect_uop("nop0", ALU_ADD, FU_ALU, 0,5'd0, 1,5'd0, 0,5'd0, 32'd0); // addi x0,x0,0

    // Legal shifts
    inst = 32'h00509093; expect_uop("slli", ALU_SLL, FU_ALU, 1,5'd1, 1,5'd1, 0,5'd0, 32'd5); // slli x1,x1,5
    inst = 32'h4050d093; expect_uop("srai", ALU_SRA, FU_ALU, 1,5'd1, 1,5'd1, 0,5'd0, 32'h405); // srai (imm includes f7)

    // Illegal encodings must become NOP (no side effects)
    inst = 32'hA0509093; #1; // slli-like with bad funct7
    if (uop.op !== UOP_NOP || uop.rd_used || uop.rs1_used)
      begin $display("FAIL illegal slli funct7"); errors++; end
    inst = 32'hA00000B3; #1; // add-like with bad funct7
    if (uop.op !== UOP_NOP || uop.rd_used || uop.rs1_used || uop.rs2_used)
      begin $display("FAIL illegal add funct7"); errors++; end
    inst = 32'h00001067; #1; // jalr with funct3!=0
    if (uop.op !== UOP_NOP || uop.is_jump || uop.rd_used || uop.rs1_used)
      begin $display("FAIL illegal jalr funct3"); errors++; end

    // ---- extra flag checks ----
    inst = 32'h0080A303; #1; if (!uop.is_load)        begin $display("FAIL lw is_load");       errors++; end
                             if (uop.mem_size !== SZ_W) begin $display("FAIL lw mem_size");     errors++; end
    inst = 32'h0020A623; #1; if (!uop.is_store)       begin $display("FAIL sw is_store");      errors++; end
    inst = 32'h00208463; #1; if (!uop.is_branch)      begin $display("FAIL beq is_branch");    errors++; end
    inst = 32'h010000EF; #1; if (!uop.is_jump)        begin $display("FAIL jal is_jump");      errors++; end
    inst = 32'h00500093; #1; if (!uop.src2_is_imm)    begin $display("FAIL addi src2_is_imm"); errors++; end

    if (errors == 0) $display("TB_DECODE: PASS");
    else             $display("TB_DECODE: FAIL (%0d errors)", errors);
    $finish;
  end
endmodule
