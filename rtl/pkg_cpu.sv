// ============================================================================
// pkg_cpu.sv  --  Central type & parameter package for the RV32IM OoO core.
//
// Single source of truth for:
//   * machine dimensions (ROB/RS/LSQ depths, register count, data width, ...)
//   * the RV32IM instruction-encoding constants (opcodes, funct3, funct7)
//   * the decoded micro-op and the structs that cross module boundaries
//     (CDB result, resolved operand, RAT entry)
//
// ISA: RV32IM, user-level integer subset (no CSRs / traps / fences / atomics).
//
// Engine contract:
//   * NO physical register file.  The RAT maps a logical reg to either the ARF
//     (committed) or an in-flight ROB id -- the "tag".  Result values live in
//     the ROB until commit, then move to the ARF.  A CDB broadcast carries
//     {tag = rob_id, value}; waiting consumers wake on a tag match.
//   * x0 is hardwired to 0.
//   * Recovery is EXECUTE-TIME selective squash with RAT checkpoints:
//     on branch mispredict resolve, restore the RAT snapshot for that ROB tag,
//     redirect fetch, and squash only younger-than-branch speculative state.
//     Commit of the mispredicted control updates the predictor only (no flush).
// ============================================================================
`timescale 1ns/1ps
`ifndef PKG_CPU_SV
`define PKG_CPU_SV

package pkg_cpu;

  // -------------------------------------------------------------------------
  // Machine dimensions
  // -------------------------------------------------------------------------
  localparam int XLEN     = 32;                 // RV32
  localparam int DATA_W   = XLEN;
  localparam int NUM_REGS = 32;                 // x0..x31  (x0 == 0)
  localparam int REG_W    = $clog2(NUM_REGS);   // 5

  localparam int ROB_DEPTH = 32;
  localparam int ROB_W     = $clog2(ROB_DEPTH); // 5  (== rename tag == CDB tag)
  localparam int RS_DEPTH  = 32;
  localparam int RS_W      = $clog2(RS_DEPTH);
  localparam int LSQ_DEPTH = 32;
  localparam int LSQ_W     = $clog2(LSQ_DEPTH);
  localparam int IFQ_DEPTH = 32;
  // Committed store buffer: ROB retires on SB enqueue; D$ drain is async.
  localparam int STORE_BUF_DEPTH = 8;
  localparam int STORE_BUF_W     = $clog2(STORE_BUF_DEPTH);

  // Superscalar width (default 4-wide with matching CDB bandwidth).
  localparam int WIDTH     = 4;
  // Number of results broadcast per cycle from the CDB arbiter to the ROB and
  // wakeup logic.  This is intentionally independent from dispatch width.
  localparam int CDB_WIDTH = 4;

  // Program counter / instruction stream
  localparam int              PC_W       = 32;
  localparam int              INSTR_W    = 32;    // RV32 fixed 32-bit instructions
  localparam logic [PC_W-1:0] RESET_PC   = 'h0;   // address of the first instruction
  localparam int              IMEM_DEPTH = 4096;  // instruction-memory slots (words)

  // Data memory (byte-addressed, M5)
  localparam int DMEM_WORDS  = 16384;             // 64 KB
  localparam int DMEM_ADDR_W = $clog2(DMEM_WORDS * 4);

  // Execution resources (M3).  Multi-cycle ops are PIPELINED units: accept one
  // op per cycle, result emerges *_STAGES cycles later.  Depth is the knob.
  localparam int NUM_ALU    = 2;
  localparam int NUM_MUL    = 1;
  localparam int NUM_DIV    = 1;
  localparam int NUM_BR     = 1;
  localparam int NUM_LSQ    = 2;     // load CDB producers; memory ports remain WIDTH-wide
  localparam int NUM_CDB_PRODUCERS = NUM_ALU + NUM_MUL + NUM_DIV + NUM_BR + NUM_LSQ;
  localparam int ALU_STAGES = 1;     // single-cycle ALU (one pipeline register)
  localparam int MUL_STAGES = 3;
  localparam int DIV_STAGES = 10;

  // Front-end predictor (M7)
  localparam int PHT_SIZE  = 1024;
  localparam int BTB_SIZE  = 256;
  localparam int RAS_DEPTH = 16;

  // -------------------------------------------------------------------------
  // Memory subsystem (split I/D L1 + shared DRAM arbiter)
  //   MEM_SYSTEM_IDEAL  : legacy always-ready tagged dmem + sync instr_mem
  //   MEM_SYSTEM_CACHED : non-blocking I$/D$ (MSHR) + mem_arbiter + dram_model
  // -------------------------------------------------------------------------
  localparam int MEM_SYSTEM_IDEAL  = 0;
  localparam int MEM_SYSTEM_CACHED = 1;
  localparam int MEM_SYSTEM = MEM_SYSTEM_CACHED;

  localparam int CACHE_LINE_BYTES = 32;
  localparam int CACHE_LINE_BITS  = CACHE_LINE_BYTES * 8; // 256
  localparam int CACHE_OFFSET_W   = $clog2(CACHE_LINE_BYTES); // 5
  localparam int DCACHE_SETS = 16;
  localparam int DCACHE_WAYS = 4;
  localparam int ICACHE_SETS = 16;
  localparam int ICACHE_WAYS = 4;
  localparam int DRAM_LAT_CYCLES = 10;

  // DRAM backend behind mem_arbiter (behavioral / sim-only):
  //   DRAM_MODEL_SIMPLE : fixed DRAM_LAT_CYCLES per line, DRAM_OUTSTANDING slots
  //   DRAM_MODEL_BANKED : SDRAM-like banks + open-row timing (cycle-accurate)
  localparam int DRAM_MODEL_SIMPLE = 0;
  localparam int DRAM_MODEL_BANKED = 1;
  localparam int DRAM_MODEL = DRAM_MODEL_SIMPLE;

  // Banked model timing (cycles). Defaults sized so a closed-row miss is
  // roughly DRAM_LAT_CYCLES (tRP+tRCD+tCL ≈ 10) and an open-row hit is tCL.
  localparam int DRAM_BA_WIDTH     = 4;   // 16 banks
  localparam int DRAM_RA_WIDTH     = 20;
  localparam int DRAM_CL_CYCLES    = 4;   // column / CAS
  localparam int DRAM_tRCD_CYCLES  = 3;   // activate -> r/w
  localparam int DRAM_tRP_CYCLES   = 3;   // precharge
  localparam int DRAM_tRAS_CYCLES  = 7;   // activate -> precharge min
  localparam int DRAM_tRC_CYCLES   = 10;  // activate -> activate same bank
  localparam int DRAM_tRRD_CYCLES  = 2;   // activate -> activate different bank
  localparam int DRAM_tWR_CYCLES   = 3;   // write recovery
  localparam int DRAM_QUEUE_SIZE   = 16;

  // Non-blocking cache / DRAM outstanding
  localparam int DCACHE_MSHR       = 4;
  localparam int ICACHE_MSHR       = 2;
  localparam int DRAM_OUTSTANDING  = 4;
  localparam int DCACHE_UFP_PORTS  = 2;   // 1..2 realistic dual-ported UFP
  // (capped at 2 in dcache.sv — see ARCH_SPEC)
  localparam int MSHR_WAITERS      = 4;   // CPU ops queued per MSHR (secondary miss)
  localparam int DRAM_MSHR_IDX_W   =
      (DCACHE_MSHR >= ICACHE_MSHR)
          ? ((DCACHE_MSHR > 1) ? $clog2(DCACHE_MSHR) : 1)
          : ((ICACHE_MSHR > 1) ? $clog2(ICACHE_MSHR) : 1);
  localparam int DRAM_ID_W = 1 + DRAM_MSHR_IDX_W; // {client, mshr_idx}

  // Mem request/response ID: LSQ entry index, or LSQ_DEPTH+sb_idx for SB drain.
  localparam int MEM_ID_W = $clog2(LSQ_DEPTH + STORE_BUF_DEPTH);

  // -------------------------------------------------------------------------
  // Convenience typedefs
  // -------------------------------------------------------------------------
  typedef logic [DATA_W-1:0]  data_t;
  typedef logic [PC_W-1:0]    pc_t;
  typedef logic [INSTR_W-1:0] instr_t;
  typedef logic [REG_W-1:0]   reg_idx_t;
  typedef logic [ROB_W-1:0]   rob_tag_t;   // ROB id == rename tag == CDB tag
  typedef logic [MEM_ID_W-1:0] mem_id_t;
  typedef logic [DRAM_ID_W-1:0] dram_id_t;
  typedef logic [CACHE_LINE_BITS-1:0] cache_line_t;

  // Distance of tag from ROB head in the in-flight window (0 = oldest).
  function automatic logic [ROB_W-1:0] rob_age_from_head(
      input rob_tag_t head, input rob_tag_t tag);
    return rob_tag_t'(tag - head);
  endfunction

  // True iff tag_a is strictly younger than tag_b (both relative to head).
  function automatic logic rob_is_younger(
      input rob_tag_t head, input rob_tag_t tag_a, input rob_tag_t tag_b);
    return rob_age_from_head(head, tag_a) > rob_age_from_head(head, tag_b);
  endfunction

  typedef logic [WIDTH-1:0] valid_bundle_t;
  typedef pc_t              pc_bundle_t       [WIDTH];
  typedef instr_t           instr_bundle_t    [WIDTH];
  typedef rob_tag_t         rob_tag_bundle_t  [WIDTH];
  typedef mem_id_t          mem_id_bundle_t   [WIDTH];

  // "No instruction" sentinel for empty imem slots: 0xFFFFFFFF has opcode bits
  // 7'b1111111, which is not a valid RISC-V opcode, so it never collides with a
  // real instruction.  imem reports valid=0 for it (end-of-program marker).
  localparam instr_t INSTR_INVALID = '1;

  // =========================================================================
  // RV32IM instruction-encoding constants (RISC-V Unprivileged ISA).
  //   Fixed fields, same position in every format:
  //     opcode = inst[6:0]   rd = inst[11:7]   funct3 = inst[14:12]
  //     rs1 = inst[19:15]    rs2 = inst[24:20] funct7 = inst[31:25]
  //   Formats (differ only in how the immediate is assembled):
  //     R, I, S, B, U, J
  // =========================================================================
  // Major opcodes -- inst[6:0]
  localparam logic [6:0] OPC_LUI     = 7'b0110111;
  localparam logic [6:0] OPC_AUIPC   = 7'b0010111;
  localparam logic [6:0] OPC_JAL     = 7'b1101111;
  localparam logic [6:0] OPC_JALR    = 7'b1100111;
  localparam logic [6:0] OPC_BRANCH  = 7'b1100011;
  localparam logic [6:0] OPC_LOAD    = 7'b0000011;
  localparam logic [6:0] OPC_STORE   = 7'b0100011;
  localparam logic [6:0] OPC_OPIMM   = 7'b0010011;   // ALU reg, imm
  localparam logic [6:0] OPC_OP      = 7'b0110011;   // ALU reg, reg  + M-extension
  localparam logic [6:0] OPC_MISCMEM = 7'b0001111;   // fence  -> treated as NOP
  localparam logic [6:0] OPC_SYSTEM  = 7'b1110011;   // ecall/ebreak/csr -> NOP (skipped)

  // funct3 -- branches (opcode BRANCH)
  localparam logic [2:0] F3_BEQ = 3'b000, F3_BNE  = 3'b001,
                         F3_BLT = 3'b100, F3_BGE  = 3'b101,
                         F3_BLTU= 3'b110, F3_BGEU = 3'b111;
  // funct3 -- loads (opcode LOAD)
  localparam logic [2:0] F3_LB = 3'b000, F3_LH = 3'b001, F3_LW = 3'b010,
                         F3_LBU= 3'b100, F3_LHU= 3'b101;
  // funct3 -- stores (opcode STORE)
  localparam logic [2:0] F3_SB = 3'b000, F3_SH = 3'b001, F3_SW = 3'b010;
  // funct3 -- integer ALU (opcode OP / OP-IMM)
  localparam logic [2:0] F3_ADD_SUB = 3'b000,  // ADD/ADDI; SUB (OP + funct7=ALT)
                         F3_SLL      = 3'b001,
                         F3_SLT      = 3'b010,
                         F3_SLTU     = 3'b011,
                         F3_XOR      = 3'b100,
                         F3_SR       = 3'b101,  // SRL/SRA, SRLI/SRAI (funct7/imm[30])
                         F3_OR       = 3'b110,
                         F3_AND      = 3'b111;
  // funct3 -- M extension (opcode OP, funct7 = MULDIV)
  localparam logic [2:0] F3_MUL = 3'b000, F3_MULH = 3'b001, F3_MULHSU = 3'b010,
                         F3_MULHU= 3'b011, F3_DIV  = 3'b100, F3_DIVU   = 3'b101,
                         F3_REM  = 3'b110, F3_REMU = 3'b111;
  // funct7 distinguishers -- inst[31:25]
  localparam logic [6:0] F7_BASE   = 7'b0000000,  // ADD, SRL, SLLI, SRLI ...
                         F7_ALT    = 7'b0100000,  // SUB, SRA, SRAI (bit 30 set)
                         F7_MULDIV = 7'b0000001;  // M extension

  // -------------------------------------------------------------------------
  // Functional-unit class
  // -------------------------------------------------------------------------
  typedef enum logic [2:0] {
    FU_ALU = 3'd0,   // integer ALU (incl. LUI/AUIPC, immediate forms)
    FU_MUL = 3'd1,
    FU_DIV = 3'd2,
    FU_MEM = 3'd3,   // loads / stores -> LSQ
    FU_BR  = 3'd4    // branches + JAL/JALR
  } fu_e;

  // -------------------------------------------------------------------------
  // Decoded operation -- what the functional unit actually computes.
  // (Immediate forms like ADDI reuse ALU_ADD with src2_is_imm=1.)
  // -------------------------------------------------------------------------
  typedef enum logic [5:0] {
    // integer ALU
    ALU_ADD, ALU_SUB, ALU_SLL, ALU_SLT, ALU_SLTU,
    ALU_XOR, ALU_SRL, ALU_SRA, ALU_OR,  ALU_AND,
    ALU_LUI, ALU_AUIPC,
    // M extension
    MD_MUL, MD_MULH, MD_MULHSU, MD_MULHU,
    MD_DIV, MD_DIVU, MD_REM, MD_REMU,
    // branches / jumps
    BR_EQ, BR_NE, BR_LT, BR_GE, BR_LTU, BR_GEU,
    BR_JAL, BR_JALR,
    // memory
    MEM_LB, MEM_LH, MEM_LW, MEM_LBU, MEM_LHU,
    MEM_SB, MEM_SH, MEM_SW,
    // bubble / illegal -> no architectural effect
    UOP_NOP
  } op_e;

  // memory access size
  typedef enum logic [1:0] { SZ_B = 2'd0, SZ_H = 2'd1, SZ_W = 2'd2 } memsz_e;

  // -------------------------------------------------------------------------
  // Decoded micro-op: the instruction descriptor flowing decode -> commit.
  // RISC-V is clean: rs1/rs2/rd are real register sources/dest in fixed spots.
  //   loads : addr = rs1 + imm, write rd
  //   stores: addr = rs1 + imm, data = rs2, no rd
  //   branch: compare rs1,rs2, target = pc + imm
  //   JAL   : target = pc + imm, rd = pc+4
  //   JALR  : target = (rs1 + imm) & ~1, rd = pc+4
  // -------------------------------------------------------------------------
  typedef struct packed {
    pc_t      pc;
    op_e      op;
    fu_e      fu;

    logic     rs1_used;
    reg_idx_t rs1;
    logic     rs2_used;
    reg_idx_t rs2;

    logic     rd_used;       // writes a register (false for stores/branches/NOP or rd==x0)
    reg_idx_t rd;

    data_t    imm;           // sign-extended immediate (built by decode per format)
    logic     src2_is_imm;   // ALU 2nd operand is the immediate (OP-IMM forms)

    // memory
    logic     is_load;
    logic     is_store;
    memsz_e   mem_size;
    logic     mem_unsigned;  // LBU / LHU (zero-extend instead of sign-extend)

    // control
    logic     is_branch;     // conditional branch
    logic     is_jump;       // JAL / JALR (unconditional)

    // front-end prediction (filled from M4/M7; zero during bring-up)
    logic     pred_taken;
    pc_t      pred_target;
  } uop_t;

  typedef uop_t uop_bundle_t [WIDTH];

  // -------------------------------------------------------------------------
  // Common Data Bus result (one result-bus lane)
  // -------------------------------------------------------------------------
  typedef struct packed {
    logic     valid;
    rob_tag_t tag;           // producing instruction's ROB id
    data_t    data;
  } cdb_t;

  typedef cdb_t cdb_bus_t [CDB_WIDTH];

  // -------------------------------------------------------------------------
  // Resolved source operand (rename/dispatch -> RS)
  //   ready=1 : value is final (from ARF or an already-done ROB entry)
  //   ready=0 : wait for `tag` on the CDB, then capture data
  // -------------------------------------------------------------------------
  typedef struct packed {
    logic     ready;
    rob_tag_t tag;
    data_t    value;
  } operand_t;

  typedef operand_t operand_bundle_t [WIDTH];

  // -------------------------------------------------------------------------
  // RAT entry (no PRF -> this IS the rename map)
  //   valid=0 : logical reg lives in the ARF (committed)
  //   valid=1 : logical reg renamed to in-flight ROB id `tag`
  // -------------------------------------------------------------------------
  typedef struct packed {
    logic     valid;
    rob_tag_t tag;
  } rat_entry_t;

endpackage : pkg_cpu

`endif  // PKG_CPU_SV
