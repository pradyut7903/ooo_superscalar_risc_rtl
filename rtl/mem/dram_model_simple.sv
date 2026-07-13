`timescale 1ns/1ps
// ============================================================================
// dram_model_simple.sv -- Fixed-latency Harvard DRAM (line interface).
// Supports up to DRAM_OUTSTANDING concurrent transactions; echoes dram_id_t.
// ============================================================================
module dram_model_simple
  import pkg_cpu::*;
  #(
    parameter string IMEM_IMAGE = "",
    parameter string DMEM_IMAGE = "",
    parameter int LAT = DRAM_LAT_CYCLES
  )
(
  input  logic clk,
  input  logic rst,

  input  logic        req_valid,
  output logic        req_ready,
  input  logic        req_is_instr,
  input  logic        req_write,
  input  data_t       req_line_addr,
  input  cache_line_t req_wdata,
  input  dram_id_t    req_id,

  output logic        resp_valid,
  output cache_line_t resp_rdata,
  output dram_id_t    resp_id
);

  localparam int LINE_WORDS = CACHE_LINE_BYTES / 4;
  localparam int I_WORDS = IMEM_DEPTH;
  localparam int D_WORDS = DMEM_WORDS;
  localparam int SLOTS = DRAM_OUTSTANDING;

  instr_t imem [I_WORDS];
  data_t  dmem [D_WORDS];

  string imem_file, dmem_file;
  initial begin
    for (int i = 0; i < I_WORDS; i++) imem[i] = INSTR_INVALID;
    for (int i = 0; i < D_WORDS; i++) dmem[i] = '0;
    if ($value$plusargs("imem=%s", imem_file)) begin
      $readmemh(imem_file, imem);
      $display("[dram] loaded imem: %s", imem_file);
    end else if (IMEM_IMAGE != "") begin
      $readmemh(IMEM_IMAGE, imem);
      $display("[dram] loaded default imem: %s", IMEM_IMAGE);
    end
    if ($value$plusargs("dmem=%s", dmem_file)) begin
      $readmemh(dmem_file, dmem);
      $display("[dram] loaded dmem: %s", dmem_file);
    end else if (DMEM_IMAGE != "") begin
      $readmemh(DMEM_IMAGE, dmem);
      $display("[dram] loaded default dmem: %s", DMEM_IMAGE);
    end
  end

  typedef enum logic [1:0] { ST_EMPTY = 2'd0, ST_WAIT = 2'd1, ST_DONE = 2'd2 } slot_e;

  slot_e       slot_st    [SLOTS];
  logic [15:0] slot_cnt   [SLOTS];
  logic        slot_is_instr [SLOTS];
  logic        slot_write [SLOTS];
  data_t       slot_addr  [SLOTS];
  cache_line_t slot_wdata [SLOTS];
  dram_id_t    slot_id    [SLOTS];
  cache_line_t slot_rdata [SLOTS];

  function automatic int unsigned line_base_word(input data_t addr);
    line_base_word = int'(addr[31:CACHE_OFFSET_W]) * LINE_WORDS;
  endfunction

  function automatic cache_line_t read_line(input logic is_instr, input data_t addr);
    cache_line_t line;
    int unsigned base;
    base = line_base_word(addr);
    line = '0;
    for (int w = 0; w < LINE_WORDS; w++) begin
      if (is_instr) begin
        if ((base + w) < I_WORDS) line[w*32 +: 32] = imem[base + w];
        else                      line[w*32 +: 32] = INSTR_INVALID;
      end else begin
        if ((base + w) < D_WORDS) line[w*32 +: 32] = dmem[base + w];
        else                      line[w*32 +: 32] = '0;
      end
    end
    return line;
  endfunction

  function automatic void do_write(input data_t addr, input cache_line_t wdata);
    for (int w = 0; w < LINE_WORDS; w++) begin
      if ((line_base_word(addr) + w) < D_WORDS)
        dmem[line_base_word(addr) + w] = wdata[w*32 +: 32];
    end
  endfunction

  int free_idx, done_idx;
  always_comb begin
    free_idx = -1;
    done_idx = -1;
    for (int i = 0; i < SLOTS; i++) begin
      if (free_idx < 0 && slot_st[i] == ST_EMPTY) free_idx = i;
      if (done_idx < 0 && slot_st[i] == ST_DONE)  done_idx = i;
    end
    req_ready = (free_idx >= 0);
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      resp_valid <= 1'b0;
      resp_rdata <= '0;
      resp_id <= '0;
      for (int i = 0; i < SLOTS; i++) begin
        slot_st[i] <= ST_EMPTY;
        slot_cnt[i] <= '0;
        slot_is_instr[i] <= 1'b0;
        slot_write[i] <= 1'b0;
        slot_addr[i] <= '0;
        slot_wdata[i] <= '0;
        slot_id[i] <= '0;
        slot_rdata[i] <= '0;
      end
    end else begin
      resp_valid <= 1'b0;

      // Advance waiting slots.
      for (int i = 0; i < SLOTS; i++) begin
        if (slot_st[i] == ST_WAIT) begin
          if (slot_cnt[i] <= 16'd1) begin
            if (slot_write[i] && !slot_is_instr[i])
              do_write(slot_addr[i], slot_wdata[i]);
            slot_rdata[i] <= slot_write[i] ? '0 : read_line(slot_is_instr[i], slot_addr[i]);
            slot_st[i] <= ST_DONE;
          end else begin
            slot_cnt[i] <= slot_cnt[i] - 16'd1;
          end
        end
      end

      // Accept (may reuse a slot freed below only next cycle — fine).
      if (req_valid && (free_idx >= 0)) begin
        automatic data_t aligned;
        aligned = {req_line_addr[31:CACHE_OFFSET_W], {CACHE_OFFSET_W{1'b0}}};
        slot_is_instr[free_idx] <= req_is_instr;
        slot_write[free_idx] <= req_write;
        slot_addr[free_idx] <= aligned;
        slot_wdata[free_idx] <= req_wdata;
        slot_id[free_idx] <= req_id;
        if (LAT <= 1) begin
          if (req_write && !req_is_instr)
            do_write(req_line_addr, req_wdata);
          slot_rdata[free_idx] <= req_write ? '0 : read_line(req_is_instr, req_line_addr);
          slot_st[free_idx] <= ST_DONE;
        end else begin
          slot_cnt[free_idx] <= 16'(LAT - 1);
          slot_st[free_idx] <= ST_WAIT;
        end
      end

      // One response per cycle.
      if (done_idx >= 0) begin
        resp_valid <= 1'b1;
        resp_rdata <= slot_rdata[done_idx];
        resp_id <= slot_id[done_idx];
        slot_st[done_idx] <= ST_EMPTY;
      end
    end
  end

endmodule
