`timescale 1ns/1ps
// ============================================================================
// dram_model_banked.sv -- Cycle-accurate banked SDRAM-style DRAM model.
//
// Same line ports as dram_model_simple (full cache line / request, 1 resp/cycle).
 // Inspired by ECE411 banked_memory (open-page, per-bank row, tRCD/tCL/tRP/...),
// but clocked (no # delays) so IPC stays cycle-deterministic under xsim.
//
// Limitations (same spirit as the reference TB model):
//   - No refresh
//   - Open-page only (no auto-precharge policy)
// ============================================================================
module dram_model_banked
  import pkg_cpu::*;
  #(
    parameter string IMEM_IMAGE = "",
    parameter string DMEM_IMAGE = ""
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
  localparam int NUM_BANKS = 1 << DRAM_BA_WIDTH;
  localparam int QSIZE = DRAM_QUEUE_SIZE;
  localparam int OFFSET_W = CACHE_OFFSET_W;
  // addr = {row, bank, offset}; bank sits just above the line offset.
  localparam int BANK_LO = OFFSET_W;
  localparam int BANK_HI = OFFSET_W + DRAM_BA_WIDTH - 1;
  localparam int ROW_LO  = OFFSET_W + DRAM_BA_WIDTH;

  instr_t imem [I_WORDS];
  data_t  dmem [D_WORDS];

  string imem_file, dmem_file;
  initial begin
    for (int i = 0; i < I_WORDS; i++) imem[i] = INSTR_INVALID;
    for (int i = 0; i < D_WORDS; i++) dmem[i] = '0;
    if ($value$plusargs("imem=%s", imem_file)) begin
      $readmemh(imem_file, imem);
      $display("[dram_banked] loaded imem: %s", imem_file);
    end else if (IMEM_IMAGE != "") begin
      $readmemh(IMEM_IMAGE, imem);
      $display("[dram_banked] loaded default imem: %s", IMEM_IMAGE);
    end
    if ($value$plusargs("dmem=%s", dmem_file)) begin
      $readmemh(dmem_file, dmem);
      $display("[dram_banked] loaded dmem: %s", dmem_file);
    end else if (DMEM_IMAGE != "") begin
      $readmemh(DMEM_IMAGE, dmem);
      $display("[dram_banked] loaded default dmem: %s", DMEM_IMAGE);
    end
  end

  function automatic int unsigned line_base_word(input data_t addr);
    line_base_word = int'(addr[31:CACHE_OFFSET_W]) * LINE_WORDS;
  endfunction

  function automatic int unsigned get_bank(input data_t addr);
    get_bank = int'(addr[BANK_HI:BANK_LO]);
  endfunction

  function automatic int get_row(input data_t addr);
    // Signed so "closed" can use -1; row field may be wider than DRAM_RA_WIDTH
    // in the address — take the low DRAM_RA_WIDTH bits of the row field.
    get_row = int'(addr[ROW_LO +: DRAM_RA_WIDTH]);
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

  // -------------------------------------------------------------------------
  // Request queue
  // -------------------------------------------------------------------------
  typedef enum logic [1:0] {
    Q_EMPTY = 2'd0,
    Q_WAIT  = 2'd1,  // queued, not yet scheduled onto a bank
    Q_BUSY  = 2'd2,  // bank timing in progress
    Q_DONE  = 2'd3
  } q_st_e;

  q_st_e       q_st       [QSIZE];
  logic        q_is_instr [QSIZE];
  logic        q_write    [QSIZE];
  data_t       q_addr     [QSIZE];
  cache_line_t q_wdata    [QSIZE];
  dram_id_t    q_id       [QSIZE];
  cache_line_t q_rdata    [QSIZE];
  logic [15:0] q_cnt      [QSIZE];  // remaining cycles while Q_BUSY
  int          q_bank     [QSIZE];

  // Per-bank open-page + timing countdowns (cycles remaining)
  int signed   active_row [NUM_BANKS];
  logic [15:0] tRAS_cnt   [NUM_BANKS];
  logic [15:0] tRC_cnt    [NUM_BANKS];
  logic [15:0] bank_busy  [NUM_BANKS]; // cycles until bank can start a new cmd
  logic [15:0] tRRD_cnt;

  int free_qi, done_qi;
  int q_occupancy;
  always_comb begin
    free_qi = -1;
    done_qi = -1;
    q_occupancy = 0;
    for (int i = 0; i < QSIZE; i++) begin
      if (q_st[i] != Q_EMPTY) q_occupancy++;
      if (free_qi < 0 && q_st[i] == Q_EMPTY) free_qi = i;
      if (done_qi < 0 && q_st[i] == Q_DONE)  done_qi = i;
    end
    req_ready = (free_qi >= 0);
  end

  // Prefer open-row hits when scanning the wait queue for a bank (like theirs).
  function automatic int pick_for_bank(input int bank);
    int hit_idx, any_idx;
    hit_idx = -1;
    any_idx = -1;
    for (int i = 0; i < QSIZE; i++) begin
      if (q_st[i] == Q_WAIT && q_bank[i] == bank) begin
        if (any_idx < 0) any_idx = i;
        if (active_row[bank] >= 0 && get_row(q_addr[i]) == active_row[bank]) begin
          hit_idx = i;
          break;
        end
      end
    end
    return (hit_idx >= 0) ? hit_idx : any_idx;
  endfunction

  function automatic int unsigned schedule_latency(
      input int row,
      input logic is_write,
      input logic [15:0] ras_left,
      input logic [15:0] rc_left,
      input logic [15:0] rrd_left,
      input int cur_row
  );
    int unsigned pre_done;
    int unsigned act_start;
    int unsigned lat;
    pre_done = 0;
    if (cur_row >= 0 && cur_row != row) begin
      pre_done = int'(ras_left) + DRAM_tRP_CYCLES;
    end
    if (cur_row != row) begin
      act_start = pre_done;
      if (int'(rrd_left) > act_start) act_start = int'(rrd_left);
      if (int'(rc_left)  > act_start) act_start = int'(rc_left);
      lat = act_start + DRAM_tRCD_CYCLES;
    end else begin
      lat = 0; // open-row hit
    end
    lat += is_write ? DRAM_tWR_CYCLES : DRAM_CL_CYCLES;
    if (lat == 0) lat = 1;
    return lat;
  endfunction

  always_ff @(posedge clk) begin
    if (rst) begin
      resp_valid <= 1'b0;
      resp_rdata <= '0;
      resp_id <= '0;
      tRRD_cnt <= '0;
      for (int b = 0; b < NUM_BANKS; b++) begin
        active_row[b] <= -1;
        tRAS_cnt[b] <= '0;
        tRC_cnt[b] <= '0;
        bank_busy[b] <= '0;
      end
      for (int i = 0; i < QSIZE; i++) begin
        q_st[i] <= Q_EMPTY;
        q_is_instr[i] <= 1'b0;
        q_write[i] <= 1'b0;
        q_addr[i] <= '0;
        q_wdata[i] <= '0;
        q_id[i] <= '0;
        q_rdata[i] <= '0;
        q_cnt[i] <= '0;
        q_bank[i] <= 0;
      end
    end else begin : seq
      int qi, row, cur_row, b;
      int unsigned lat;
      logic [15:0] next_tRRD;
      logic activated_any;
      logic do_activate;
      data_t aligned;

      resp_valid <= 1'b0;
      next_tRRD = (tRRD_cnt != '0) ? (tRRD_cnt - 16'd1) : 16'd0;
      activated_any = 1'b0;

      for (b = 0; b < NUM_BANKS; b++) begin
        if (tRAS_cnt[b] != '0) tRAS_cnt[b] <= tRAS_cnt[b] - 16'd1;
        if (tRC_cnt[b]  != '0) tRC_cnt[b]  <= tRC_cnt[b]  - 16'd1;
        if (bank_busy[b] != '0) bank_busy[b] <= bank_busy[b] - 16'd1;
      end

      for (int i = 0; i < QSIZE; i++) begin
        if (q_st[i] == Q_BUSY) begin
          if (q_cnt[i] <= 16'd1) begin
            if (q_write[i] && !q_is_instr[i])
              do_write(q_addr[i], q_wdata[i]);
            q_rdata[i] <= q_write[i] ? '0 : read_line(q_is_instr[i], q_addr[i]);
            q_st[i] <= Q_DONE;
          end else begin
            q_cnt[i] <= q_cnt[i] - 16'd1;
          end
        end
      end

      for (b = 0; b < NUM_BANKS; b++) begin
        if (bank_busy[b] == '0) begin
          qi = pick_for_bank(b);
          if (qi >= 0) begin
            row = get_row(q_addr[qi]);
            cur_row = active_row[b];
            lat = schedule_latency(row, q_write[qi],
                                   tRAS_cnt[b], tRC_cnt[b], tRRD_cnt, cur_row);
            do_activate = (cur_row != row);

            if (do_activate) begin
              active_row[b] <= row;
              tRAS_cnt[b] <= 16'(DRAM_tRAS_CYCLES);
              tRC_cnt[b]  <= 16'(DRAM_tRC_CYCLES);
              activated_any = 1'b1;
            end

            q_st[qi] <= Q_BUSY;
            q_cnt[qi] <= 16'(lat);
            bank_busy[b] <= 16'(lat);
          end
        end
      end

      if (activated_any)
        tRRD_cnt <= 16'(DRAM_tRRD_CYCLES);
      else
        tRRD_cnt <= next_tRRD;

      if (req_valid && (free_qi >= 0)) begin
        aligned = {req_line_addr[31:CACHE_OFFSET_W], {CACHE_OFFSET_W{1'b0}}};
        q_is_instr[free_qi] <= req_is_instr;
        q_write[free_qi] <= req_write;
        q_addr[free_qi] <= aligned;
        q_wdata[free_qi] <= req_wdata;
        q_id[free_qi] <= req_id;
        q_bank[free_qi] <= get_bank(aligned);
        q_st[free_qi] <= Q_WAIT;
      end

      if (done_qi >= 0) begin
        resp_valid <= 1'b1;
        resp_rdata <= q_rdata[done_qi];
        resp_id <= q_id[done_qi];
        q_st[done_qi] <= Q_EMPTY;
      end
    end
  end

endmodule
