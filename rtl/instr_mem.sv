`timescale 1ns/1ps
// ============================================================================
// instr_mem.sv -- Instruction memory (synchronous, BRAM-style, 1-cycle read).
//
// A ROM of 32-bit RV32IM instructions.  Fetch presents a bundle of PCs; each
// lane reads one word.  The read is REGISTERED -- data appears one clock AFTER
// the PCs are presented.  Empty / past-the-end slots read as INSTR_INVALID and
// assert valid=0, which is how fetch detects end-of-program.
//
// Loaded at time 0 via $readmemh from the +imem=<file> plusarg.
//
// Convention used across the core: clk = rising edge, rst = active-high sync.
// ============================================================================
module instr_mem
  import pkg_cpu::*;
  #(parameter string DEFAULT_IMAGE = "")
(
  input  logic   clk,
  input  logic   rst,
  input  logic   en,      // read clock-enable (BRAM CE): hold the output when low
  input  pc_bundle_t    pc,
  output valid_bundle_t valid,   // registered: real instruction per lane
  output instr_bundle_t word     // registered: instruction per lane
);

  instr_t mem [IMEM_DEPTH];

  // ---- image load (time 0) --------------------------------------------------
  string imem_file;
  initial begin
    for (int i = 0; i < IMEM_DEPTH; i++) mem[i] = INSTR_INVALID;
    if ($value$plusargs("imem=%s", imem_file)) begin
      $readmemh(imem_file, mem);
      $display("[imem] loaded image: %s", imem_file);
    end else if (DEFAULT_IMAGE != "") begin
      imem_file = DEFAULT_IMAGE;
      $readmemh(imem_file, mem);
      $display("[imem] loaded default image: %s", imem_file);
    end else begin
      $display("[imem] WARNING: no +imem=<file> plusarg; instruction memory is empty");
    end
  end

  // ---- combinational address decode -----------------------------------------
  localparam int IDX_W = $clog2(IMEM_DEPTH);
  logic [PC_W-1:0] word_idx [WIDTH];
  logic            in_range [WIDTH];
  instr_t          rdata    [WIDTH];

  always_comb begin
    for (int i = 0; i < WIDTH; i++) begin
      word_idx[i] = (pc[i] - RESET_PC) >> 2;
      in_range[i] = (pc[i] >= RESET_PC) && (word_idx[i] < IMEM_DEPTH);
      rdata[i]    = in_range[i] ? mem[word_idx[i][IDX_W-1:0]] : INSTR_INVALID;
    end
  end

  // ---- registered (1-cycle) read -- the BRAM-style output ------------------
  always_ff @(posedge clk) begin
    if (rst) begin
      for (int i = 0; i < WIDTH; i++) begin
        word[i]  <= INSTR_INVALID;
        valid[i] <= 1'b0;
      end
    end else if (en) begin
      for (int i = 0; i < WIDTH; i++) begin
        word[i]  <= rdata[i];
        valid[i] <= in_range[i] && (rdata[i] != INSTR_INVALID);
      end
    end
    // else: en low -> hold output (stalled stage)
  end

endmodule
