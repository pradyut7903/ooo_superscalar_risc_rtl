`timescale 1ns/1ps
// ============================================================================
// decode.sv -- RV32IM instruction decoder (pure combinational).
//
// Takes a 32-bit instruction + its PC, produces the engine's uop_t: operation,
// functional unit, register sources/dest (+ used flags), the per-format
// sign-extended immediate, and load/store/branch/jump info.
//
// RISC-V regularity -- same bit positions in every format:
//   opcode=inst[6:0]  rd=inst[11:7]  funct3=inst[14:12]
//   rs1=inst[19:15]   rs2=inst[24:20] funct7=inst[31:25]
// Only the immediate assembly differs per format (R/I/S/B/U/J).
//
// FENCE / ECALL / EBREAK / illegal decode to UOP_NOP (no architectural effect).
// Illegal OP/OP-IMM funct7 encodings and JALR with funct3!=000 also become NOP.
// Writes to x0 are squashed (rd_used cleared) since x0 is hardwired 0.
// ============================================================================
module decode
  import pkg_cpu::*;
(
  input  instr_t inst,
  input  pc_t    pc,
  output uop_t   uop
);

  data_t imm_i, imm_s, imm_b, imm_u, imm_j;

  always_comb begin
    // ---- per-format immediates (sign-extended to 32 bits) ----
    imm_i = {{20{inst[31]}}, inst[31:20]};
    imm_s = {{20{inst[31]}}, inst[31:25], inst[11:7]};
    imm_b = {{19{inst[31]}}, inst[31], inst[7], inst[30:25], inst[11:8], 1'b0};
    imm_u = {inst[31:12], 12'b0};
    imm_j = {{11{inst[31]}}, inst[31], inst[19:12], inst[20], inst[30:21], 1'b0};

    // ---- defaults: a NOP that touches nothing ----
    uop          = '0;
    uop.pc       = pc;
    uop.op       = UOP_NOP;
    uop.fu       = FU_ALU;
    uop.rd       = inst[11:7];
    uop.rs1      = inst[19:15];
    uop.rs2      = inst[24:20];
    uop.mem_size = SZ_W;

    unique case (inst[6:0])
      // -------- integer reg, immediate (I-type) --------
      OPC_OPIMM: begin
        uop.fu          = FU_ALU;
        uop.rd_used     = 1'b1;
        uop.rs1_used    = 1'b1;
        uop.src2_is_imm = 1'b1;
        uop.imm         = imm_i;
        unique case (inst[14:12])
          F3_ADD_SUB: uop.op = ALU_ADD;                       // ADDI
          F3_SLL: begin
            // SLLI: funct7 must be 0000000; shamt is inst[24:20]
            if (inst[31:25] == F7_BASE) uop.op = ALU_SLL;
            else begin
              uop.op = UOP_NOP; uop.rd_used = 1'b0; uop.rs1_used = 1'b0; uop.src2_is_imm = 1'b0;
            end
          end
          F3_SLT:     uop.op = ALU_SLT;                       // SLTI
          F3_SLTU:    uop.op = ALU_SLTU;                      // SLTIU
          F3_XOR:     uop.op = ALU_XOR;                       // XORI
          F3_SR: begin
            // SRLI: funct7=0000000; SRAI: funct7=0100000
            if (inst[31:25] == F7_BASE)      uop.op = ALU_SRL;
            else if (inst[31:25] == F7_ALT)  uop.op = ALU_SRA;
            else begin
              uop.op = UOP_NOP; uop.rd_used = 1'b0; uop.rs1_used = 1'b0; uop.src2_is_imm = 1'b0;
            end
          end
          F3_OR:      uop.op = ALU_OR;                        // ORI
          F3_AND:     uop.op = ALU_AND;                       // ANDI
          default:    begin
            uop.op = UOP_NOP; uop.rd_used = 1'b0; uop.rs1_used = 1'b0; uop.src2_is_imm = 1'b0;
          end
        endcase
      end

      // -------- integer reg, reg (R-type) + M extension --------
      OPC_OP: begin
        uop.rd_used  = 1'b1;
        uop.rs1_used = 1'b1;
        uop.rs2_used = 1'b1;
        if (inst[31:25] == F7_MULDIV) begin
          unique case (inst[14:12])
            F3_MUL:    begin uop.op = MD_MUL;    uop.fu = FU_MUL; end
            F3_MULH:   begin uop.op = MD_MULH;   uop.fu = FU_MUL; end
            F3_MULHSU: begin uop.op = MD_MULHSU; uop.fu = FU_MUL; end
            F3_MULHU:  begin uop.op = MD_MULHU;  uop.fu = FU_MUL; end
            F3_DIV:    begin uop.op = MD_DIV;    uop.fu = FU_DIV; end
            F3_DIVU:   begin uop.op = MD_DIVU;   uop.fu = FU_DIV; end
            F3_REM:    begin uop.op = MD_REM;    uop.fu = FU_DIV; end
            F3_REMU:   begin uop.op = MD_REMU;   uop.fu = FU_DIV; end
            default:   begin
              uop.op = UOP_NOP; uop.rd_used = 1'b0; uop.rs1_used = 1'b0; uop.rs2_used = 1'b0;
            end
          endcase
        end else begin
          uop.fu = FU_ALU;
          unique case (inst[14:12])
            F3_ADD_SUB: begin
              if (inst[31:25] == F7_BASE)      uop.op = ALU_ADD;
              else if (inst[31:25] == F7_ALT)  uop.op = ALU_SUB;
              else begin
                uop.op = UOP_NOP; uop.rd_used = 1'b0; uop.rs1_used = 1'b0; uop.rs2_used = 1'b0;
              end
            end
            F3_SLL: begin
              if (inst[31:25] == F7_BASE) uop.op = ALU_SLL;
              else begin
                uop.op = UOP_NOP; uop.rd_used = 1'b0; uop.rs1_used = 1'b0; uop.rs2_used = 1'b0;
              end
            end
            F3_SLT: begin
              if (inst[31:25] == F7_BASE) uop.op = ALU_SLT;
              else begin
                uop.op = UOP_NOP; uop.rd_used = 1'b0; uop.rs1_used = 1'b0; uop.rs2_used = 1'b0;
              end
            end
            F3_SLTU: begin
              if (inst[31:25] == F7_BASE) uop.op = ALU_SLTU;
              else begin
                uop.op = UOP_NOP; uop.rd_used = 1'b0; uop.rs1_used = 1'b0; uop.rs2_used = 1'b0;
              end
            end
            F3_XOR: begin
              if (inst[31:25] == F7_BASE) uop.op = ALU_XOR;
              else begin
                uop.op = UOP_NOP; uop.rd_used = 1'b0; uop.rs1_used = 1'b0; uop.rs2_used = 1'b0;
              end
            end
            F3_SR: begin
              if (inst[31:25] == F7_BASE)      uop.op = ALU_SRL;
              else if (inst[31:25] == F7_ALT)  uop.op = ALU_SRA;
              else begin
                uop.op = UOP_NOP; uop.rd_used = 1'b0; uop.rs1_used = 1'b0; uop.rs2_used = 1'b0;
              end
            end
            F3_OR: begin
              if (inst[31:25] == F7_BASE) uop.op = ALU_OR;
              else begin
                uop.op = UOP_NOP; uop.rd_used = 1'b0; uop.rs1_used = 1'b0; uop.rs2_used = 1'b0;
              end
            end
            F3_AND: begin
              if (inst[31:25] == F7_BASE) uop.op = ALU_AND;
              else begin
                uop.op = UOP_NOP; uop.rd_used = 1'b0; uop.rs1_used = 1'b0; uop.rs2_used = 1'b0;
              end
            end
            default: begin
              uop.op = UOP_NOP; uop.rd_used = 1'b0; uop.rs1_used = 1'b0; uop.rs2_used = 1'b0;
            end
          endcase
        end
      end

      // -------- loads (I-type) --------
      OPC_LOAD: begin
        uop.fu       = FU_MEM;
        uop.is_load  = 1'b1;
        uop.rd_used  = 1'b1;
        uop.rs1_used = 1'b1;
        uop.imm      = imm_i;
        unique case (inst[14:12])
          F3_LB:  begin uop.op = MEM_LB;  uop.mem_size = SZ_B; uop.mem_unsigned = 1'b0; end
          F3_LH:  begin uop.op = MEM_LH;  uop.mem_size = SZ_H; uop.mem_unsigned = 1'b0; end
          F3_LW:  begin uop.op = MEM_LW;  uop.mem_size = SZ_W; uop.mem_unsigned = 1'b0; end
          F3_LBU: begin uop.op = MEM_LBU; uop.mem_size = SZ_B; uop.mem_unsigned = 1'b1; end
          F3_LHU: begin uop.op = MEM_LHU; uop.mem_size = SZ_H; uop.mem_unsigned = 1'b1; end
          default:begin uop.op = UOP_NOP; uop.is_load = 1'b0; uop.rd_used = 1'b0; uop.rs1_used = 1'b0; end
        endcase
      end

      // -------- stores (S-type) --------
      OPC_STORE: begin
        uop.fu       = FU_MEM;
        uop.is_store = 1'b1;
        uop.rs1_used = 1'b1;   // base
        uop.rs2_used = 1'b1;   // data
        uop.imm      = imm_s;
        unique case (inst[14:12])
          F3_SB: begin uop.op = MEM_SB; uop.mem_size = SZ_B; end
          F3_SH: begin uop.op = MEM_SH; uop.mem_size = SZ_H; end
          F3_SW: begin uop.op = MEM_SW; uop.mem_size = SZ_W; end
          default:begin uop.op = UOP_NOP; uop.is_store = 1'b0; uop.rs1_used = 1'b0; uop.rs2_used = 1'b0; end
        endcase
      end

      // -------- conditional branches (B-type) --------
      OPC_BRANCH: begin
        uop.fu        = FU_BR;
        uop.is_branch = 1'b1;
        uop.rs1_used  = 1'b1;
        uop.rs2_used  = 1'b1;
        uop.imm       = imm_b;
        unique case (inst[14:12])
          F3_BEQ:  uop.op = BR_EQ;
          F3_BNE:  uop.op = BR_NE;
          F3_BLT:  uop.op = BR_LT;
          F3_BGE:  uop.op = BR_GE;
          F3_BLTU: uop.op = BR_LTU;
          F3_BGEU: uop.op = BR_GEU;
          default: begin uop.op = UOP_NOP; uop.is_branch = 1'b0; uop.rs1_used = 1'b0; uop.rs2_used = 1'b0; end
        endcase
      end

      // -------- JAL (J-type) --------
      OPC_JAL: begin
        uop.fu      = FU_BR;
        uop.is_jump = 1'b1;
        uop.op      = BR_JAL;
        uop.rd_used = 1'b1;    // link = pc + 4
        uop.imm     = imm_j;
      end

      // -------- JALR (I-type) --------
      OPC_JALR: begin
        if (inst[14:12] == 3'b000) begin
          uop.fu       = FU_BR;
          uop.is_jump  = 1'b1;
          uop.op       = BR_JALR;
          uop.rd_used  = 1'b1;   // link = pc + 4
          uop.rs1_used = 1'b1;   // base
          uop.imm      = imm_i;
        end
        // else: illegal funct3 -> keep default UOP_NOP
      end

      // -------- LUI (U-type) --------
      OPC_LUI: begin
        uop.fu          = FU_ALU;
        uop.op          = ALU_LUI;
        uop.rd_used     = 1'b1;
        uop.src2_is_imm = 1'b1;
        uop.imm         = imm_u;
      end

      // -------- AUIPC (U-type) --------
      OPC_AUIPC: begin
        uop.fu          = FU_ALU;
        uop.op          = ALU_AUIPC;
        uop.rd_used     = 1'b1;
        uop.src2_is_imm = 1'b1;
        uop.imm         = imm_u;
      end

      // FENCE / SYSTEM / illegal -> NOP (defaults already set)
      default: ;
    endcase

    // x0 is hardwired 0: a write to it has no effect, so never rename it.
    if (uop.rd == '0) uop.rd_used = 1'b0;
  end

endmodule
