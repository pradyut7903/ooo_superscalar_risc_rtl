`timescale 1ns/1ps
// ============================================================================
// icache.sv -- Non-blocking read-only instruction cache (MSHR).
// Fetch: one PC request; returns up to WIDTH words from the line.
// ============================================================================
module icache
  import pkg_cpu::*;
(
  input  logic clk,
  input  logic rst,
  input  logic flush,

  input  logic        req_valid,
  output logic        req_ready,
  input  pc_t         req_pc,
  output logic        resp_valid,
  output valid_bundle_t resp_word_valid,
  output instr_bundle_t resp_word,
  output pc_bundle_t    resp_pc,
  output logic [$clog2(WIDTH+1)-1:0] resp_count,

  output logic                 line_req_valid,
  input  logic                 line_req_ready,
  output data_t                line_req_addr,
  output logic [DRAM_MSHR_IDX_W-1:0] line_req_mshr,
  input  logic                 line_resp_valid,
  input  cache_line_t          line_resp_rdata,
  input  logic [DRAM_MSHR_IDX_W-1:0] line_resp_mshr
);

  localparam int SETS = ICACHE_SETS;
  localparam int WAYS = ICACHE_WAYS;
  localparam int SET_W = $clog2(SETS);
  localparam int TAG_W = 32 - CACHE_OFFSET_W - SET_W;
  localparam int WAY_W = $clog2(WAYS);
  localparam int LINE_WORDS = CACHE_LINE_BYTES / 4;
  localparam int MSHRS = ICACHE_MSHR;
  localparam int MSHR_W = (MSHRS > 1) ? $clog2(MSHRS) : 1;

  logic             valid_bits [SETS][WAYS];
  logic             way_reserved [SETS][WAYS];
  logic [TAG_W-1:0] tags       [SETS][WAYS];
  cache_line_t      data_arr   [SETS][WAYS];
  logic             lru_mat    [SETS][WAYS][WAYS];

  logic            m_valid [MSHRS];
  pc_t             m_pc    [MSHRS];
  data_t           m_line  [MSHRS];
  logic [SET_W-1:0] m_set  [MSHRS];
  logic [TAG_W-1:0] m_tag  [MSHRS];
  logic [WAY_W-1:0] m_way  [MSHRS];
  logic            m_fill_sent [MSHRS];
  logic            m_drop  [MSHRS];
  logic            m_has_waiter [MSHRS]; // CPU waiting on this fill

  // Pipe: latched request for compare
  logic        pipe_valid;
  pc_t         pipe_pc;
  logic [SET_W-1:0] pipe_set;
  logic [TAG_W-1:0] pipe_tag;

  // Hit response pending
  logic        hit_pend;
  cache_line_t hit_line;
  pc_t         hit_pc;
  logic        hit_drop;

  int unsigned hit_count, miss_count;

  function automatic logic [SET_W-1:0] idx_of(input pc_t a);
    return a[CACHE_OFFSET_W +: SET_W];
  endfunction
  function automatic logic [TAG_W-1:0] tag_of(input pc_t a);
    return a[31 -: TAG_W];
  endfunction
  function automatic data_t line_align_pc(input pc_t a);
    return data_t'({a[31:CACHE_OFFSET_W], {CACHE_OFFSET_W{1'b0}}});
  endfunction

  function automatic logic pick_victim(
      input logic [SET_W-1:0] s,
      output logic [WAY_W-1:0] way
  );
    logic [WAY_W-1:0] inv, lru;
    logic found_inv, found_lru, row_zero;
    found_inv = 1'b0; found_lru = 1'b0; inv = '0; lru = '0;
    for (int w = 0; w < WAYS; w++)
      if (!found_inv && !valid_bits[s][w] && !way_reserved[s][w]) begin
        inv = WAY_W'(w); found_inv = 1'b1;
      end
    if (found_inv) begin way = inv; return 1'b1; end
    for (int w = 0; w < WAYS; w++) begin
      row_zero = 1'b1;
      for (int j = 0; j < WAYS; j++) if (lru_mat[s][w][j]) row_zero = 1'b0;
      if (!found_lru && valid_bits[s][w] && !way_reserved[s][w] && row_zero) begin
        lru = WAY_W'(w); found_lru = 1'b1;
      end
    end
    if (found_lru) begin way = lru; return 1'b1; end
    way = '0;
    return 1'b0;
  endfunction

  logic hit;
  logic [WAY_W-1:0] hit_way;
  always_comb begin
    hit = 1'b0; hit_way = '0;
    for (int w = 0; w < WAYS; w++)
      if (valid_bits[pipe_set][w] && !way_reserved[pipe_set][w] &&
          tags[pipe_set][w] == pipe_tag) begin
        hit = 1'b1; hit_way = WAY_W'(w);
      end
  end

  logic mshr_hit, mshr_free;
  logic [MSHR_W-1:0] mshr_hit_idx, mshr_free_idx;
  always_comb begin
    mshr_hit = 1'b0; mshr_hit_idx = '0;
    mshr_free = 1'b0; mshr_free_idx = '0;
    for (int i = 0; i < MSHRS; i++) begin
      if (m_valid[i] && m_line[i] == line_align_pc(pipe_pc)) begin
        mshr_hit = 1'b1; mshr_hit_idx = MSHR_W'(i);
      end
      if (!mshr_free && !m_valid[i]) begin
        mshr_free = 1'b1; mshr_free_idx = MSHR_W'(i);
      end
    end
  end

  logic line_sel_valid;
  logic [MSHR_W-1:0] line_sel_idx;
  always_comb begin
    line_sel_valid = 1'b0; line_sel_idx = '0;
    for (int i = 0; i < MSHRS; i++)
      if (!line_sel_valid && m_valid[i] && !m_fill_sent[i]) begin
        line_sel_valid = 1'b1; line_sel_idx = MSHR_W'(i);
      end
  end

  assign line_req_valid = line_sel_valid;
  assign line_req_addr  = m_line[line_sel_idx];
  assign line_req_mshr  = DRAM_MSHR_IDX_W'(line_sel_idx);

  // Fetch may issue when no pipe and no hit_pend (one outstanding CPU req)
  assign req_ready = !pipe_valid && !hit_pend;

  task automatic emit_bundle(input pc_t pc, input cache_line_t line);
    int unsigned base_w, max_w, n;
    base_w = int'(pc[CACHE_OFFSET_W-1:2]);
    max_w = LINE_WORDS - base_w;
    n = (max_w < WIDTH) ? max_w : WIDTH;
    resp_count <= ($bits(resp_count))'(n);
    for (int lane = 0; lane < WIDTH; lane++) begin
      resp_pc[lane] <= pc + pc_t'(lane * 4);
      if (lane < n) begin
        resp_word[lane] <= line[(base_w + lane)*32 +: 32];
        resp_word_valid[lane] <= (line[(base_w + lane)*32 +: 32] != INSTR_INVALID);
      end else begin
        resp_word[lane] <= INSTR_INVALID;
        resp_word_valid[lane] <= 1'b0;
      end
    end
  endtask

  always_ff @(posedge clk) begin
    if (rst) begin
      pipe_valid <= 1'b0; pipe_pc <= '0; pipe_set <= '0; pipe_tag <= '0;
      hit_pend <= 1'b0; hit_line <= '0; hit_pc <= '0; hit_drop <= 1'b0;
      resp_valid <= 1'b0; resp_word_valid <= '0; resp_count <= '0;
      hit_count <= 0; miss_count <= 0;
      for (int i = 0; i < WIDTH; i++) begin
        resp_word[i] <= INSTR_INVALID; resp_pc[i] <= '0;
      end
      for (int s = 0; s < SETS; s++)
        for (int w = 0; w < WAYS; w++) begin
          valid_bits[s][w] <= 1'b0; way_reserved[s][w] <= 1'b0;
          tags[s][w] <= '0; data_arr[s][w] <= '0;
          for (int j = 0; j < WAYS; j++) lru_mat[s][w][j] <= 1'b0;
        end
      for (int i = 0; i < MSHRS; i++) begin
        m_valid[i] <= 1'b0; m_pc[i] <= '0; m_line[i] <= '0;
        m_set[i] <= '0; m_tag[i] <= '0; m_way[i] <= '0;
        m_fill_sent[i] <= 1'b0; m_drop[i] <= 1'b0; m_has_waiter[i] <= 1'b0;
      end
    end else begin
      resp_valid <= 1'b0;

      if (flush) begin
        if (hit_pend) hit_drop <= 1'b1;
        pipe_valid <= 1'b0;
        for (int i = 0; i < MSHRS; i++) begin
          if (m_valid[i]) begin
            m_drop[i] <= 1'b1;
            m_has_waiter[i] <= 1'b0;
          end
        end
      end

      // Accept
      if (req_valid && req_ready && !flush) begin
        pipe_valid <= 1'b1;
        pipe_pc <= req_pc;
        pipe_set <= idx_of(req_pc);
        pipe_tag <= tag_of(req_pc);
      end

      // Hit pending emit
      if (hit_pend) begin
        if (!hit_drop && !flush) begin
          resp_valid <= 1'b1;
          emit_bundle(hit_pc, hit_line);
        end
        hit_pend <= 1'b0;
        hit_drop <= 1'b0;
      end

      // Compare
      if (pipe_valid && !flush) begin
        pipe_valid <= 1'b0;
        if (hit) begin
          hit_count <= hit_count + 1;
          for (int j = 0; j < WAYS; j++) begin
            lru_mat[pipe_set][hit_way][j] <= 1'b1;
            lru_mat[pipe_set][j][hit_way] <= 1'b0;
          end
          lru_mat[pipe_set][hit_way][hit_way] <= 1'b0;
          hit_pend <= 1'b1;
          hit_line <= data_arr[pipe_set][hit_way];
          hit_pc <= pipe_pc;
          hit_drop <= 1'b0;
        end else if (mshr_hit) begin
          // Secondary: attach waiter if none
          m_has_waiter[mshr_hit_idx] <= 1'b1;
          m_pc[mshr_hit_idx] <= pipe_pc;
          m_drop[mshr_hit_idx] <= 1'b0;
        end else if (mshr_free) begin
          automatic logic [WAY_W-1:0] vw;
          automatic logic got;
          got = pick_victim(pipe_set, vw);
          if (!got) begin
            pipe_valid <= 1'b1;
          end else begin
            miss_count <= miss_count + 1;
            m_valid[mshr_free_idx] <= 1'b1;
            m_pc[mshr_free_idx] <= pipe_pc;
            m_line[mshr_free_idx] <= line_align_pc(pipe_pc);
            m_set[mshr_free_idx] <= pipe_set;
            m_tag[mshr_free_idx] <= pipe_tag;
            m_way[mshr_free_idx] <= vw;
            m_fill_sent[mshr_free_idx] <= 1'b0;
            m_drop[mshr_free_idx] <= 1'b0;
            m_has_waiter[mshr_free_idx] <= 1'b1;
            way_reserved[pipe_set][vw] <= 1'b1;
          end
        end else begin
          pipe_valid <= 1'b1; // backpressure
        end
      end else if (pipe_valid && flush) begin
        pipe_valid <= 1'b0;
      end

      if (line_req_valid && line_req_ready)
        m_fill_sent[line_sel_idx] <= 1'b1;

      if (line_resp_valid) begin
        automatic logic [MSHR_W-1:0] mi;
        mi = MSHR_W'(line_resp_mshr);
        if (m_valid[mi]) begin
          data_arr[m_set[mi]][m_way[mi]] <= line_resp_rdata;
          valid_bits[m_set[mi]][m_way[mi]] <= 1'b1;
          tags[m_set[mi]][m_way[mi]] <= m_tag[mi];
          way_reserved[m_set[mi]][m_way[mi]] <= 1'b0;
          for (int j = 0; j < WAYS; j++) begin
            lru_mat[m_set[mi]][m_way[mi]][j] <= 1'b1;
            lru_mat[m_set[mi]][j][m_way[mi]] <= 1'b0;
          end
          lru_mat[m_set[mi]][m_way[mi]][m_way[mi]] <= 1'b0;
          if (m_has_waiter[mi] && !m_drop[mi] && !flush) begin
            resp_valid <= 1'b1;
            emit_bundle(m_pc[mi], line_resp_rdata);
          end
          m_valid[mi] <= 1'b0;
          m_has_waiter[mi] <= 1'b0;
        end
      end
    end
  end

endmodule
