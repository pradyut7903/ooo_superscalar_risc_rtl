`timescale 1ns/1ps
// ============================================================================
// dcache.sv -- Non-blocking write-back / write-allocate data cache (MSHR).
//
// UFP: up to min(DCACHE_UFP_PORTS, 2) true dual-accept compare pipes.
// Victim ways reserved from allocate until fill install / MSHR free.
// Secondary miss deferred if that MSHR completes fill the same cycle.
// Same-cycle multi-port MSHR/waiter updates use shadow state.
// UFP drain is single-flight; additional filled MSHRs wait on m_ufp_pending.
// ============================================================================
module dcache
  import pkg_cpu::*;
(
  input  logic clk,
  input  logic rst,
  input  logic flush,

  input  valid_bundle_t mem_req_valid,
  output valid_bundle_t mem_req_ready,
  input  valid_bundle_t mem_req_write,
  input  data_t         mem_req_addr [WIDTH],
  input  data_t         mem_req_wdata [WIDTH],
  input  logic [3:0]    mem_req_wstrb [WIDTH],
  input  mem_id_t       mem_req_id [WIDTH],

  output valid_bundle_t mem_resp_valid,
  output data_t         mem_resp_rdata [WIDTH],
  output mem_id_t       mem_resp_id [WIDTH],

  output logic                 line_req_valid,
  input  logic                 line_req_ready,
  output logic                 line_req_write,
  output data_t                line_req_addr,
  output cache_line_t          line_req_wdata,
  output logic [DRAM_MSHR_IDX_W-1:0] line_req_mshr,
  input  logic                 line_resp_valid,
  input  cache_line_t          line_resp_rdata,
  input  logic [DRAM_MSHR_IDX_W-1:0] line_resp_mshr
);

  localparam int SETS = DCACHE_SETS;
  localparam int WAYS = DCACHE_WAYS;
  localparam int SET_W = $clog2(SETS);
  localparam int TAG_W = 32 - CACHE_OFFSET_W - SET_W;
  localparam int WAY_W = $clog2(WAYS);
  localparam int MSHRS = DCACHE_MSHR;
  localparam int MSHR_W = (MSHRS > 1) ? $clog2(MSHRS) : 1;
  localparam int WQ = MSHR_WAITERS;
  localparam int PORTS = (DCACHE_UFP_PORTS < 1) ? 1 :
                         (DCACHE_UFP_PORTS > 2) ? 2 : DCACHE_UFP_PORTS;

  logic             valid_bits [SETS][WAYS];
  logic             dirty_bits [SETS][WAYS];
  logic             way_reserved [SETS][WAYS];
  logic [TAG_W-1:0] tags       [SETS][WAYS];
  cache_line_t      data_arr   [SETS][WAYS];
  logic             lru_mat    [SETS][WAYS][WAYS];

  logic                m_valid      [MSHRS];
  data_t               m_line_addr  [MSHRS];
  logic [SET_W-1:0]    m_set        [MSHRS];
  logic [TAG_W-1:0]    m_tag        [MSHRS];
  logic [WAY_W-1:0]    m_way        [MSHRS];
  logic                m_needs_wb   [MSHRS];
  logic                m_wb_sent    [MSHRS];
  logic                m_wb_done    [MSHRS];
  logic                m_fill_sent  [MSHRS];
  cache_line_t         m_wb_line    [MSHRS];
  logic                m_drop_ufp   [MSHRS];
  logic                m_ufp_pending[MSHRS]; // fill installed; waiting for drain slot
  cache_line_t         m_fill_line  [MSHRS];

  logic                w_valid [MSHRS][WQ];
  logic                w_write [MSHRS][WQ];
  data_t               w_addr  [MSHRS][WQ];
  data_t               w_wdata [MSHRS][WQ];
  logic [3:0]          w_wstrb [MSHRS][WQ];
  mem_id_t             w_id    [MSHRS][WQ];
  logic [$clog2(WQ+1)-1:0] w_count [MSHRS];

  logic        pipe_valid [PORTS];
  logic        pipe_write [PORTS];
  data_t       pipe_addr  [PORTS];
  data_t       pipe_wdata [PORTS];
  logic [3:0]  pipe_wstrb [PORTS];
  mem_id_t     pipe_id    [PORTS];
  logic [SET_W-1:0] pipe_set [PORTS];
  logic [TAG_W-1:0] pipe_tag [PORTS];

  logic        hit_pend_valid [PORTS];
  data_t       hit_pend_rdata [PORTS];
  mem_id_t     hit_pend_id    [PORTS];
  logic        hit_pend_drop  [PORTS];

  logic                drain_active;
  logic [MSHR_W-1:0]   drain_mshr;
  logic [$clog2(WQ+1)-1:0] drain_idx;
  cache_line_t         drain_line;

  int unsigned hit_count;
  int unsigned miss_count;

  function automatic data_t line_align(input data_t a);
    return {a[31:CACHE_OFFSET_W], {CACHE_OFFSET_W{1'b0}}};
  endfunction
  function automatic logic [SET_W-1:0] idx_of(input data_t a);
    return a[CACHE_OFFSET_W +: SET_W];
  endfunction
  function automatic logic [TAG_W-1:0] tag_of(input data_t a);
    return a[31 -: TAG_W];
  endfunction
  function automatic data_t word_from_line(input cache_line_t line, input data_t addr);
    return line[int'(addr[CACHE_OFFSET_W-1:2])*32 +: 32];
  endfunction
  function automatic cache_line_t apply_store(input cache_line_t line, input data_t addr,
                                              input data_t wdata, input logic [3:0] wstrb);
    cache_line_t out;
    data_t word;
    int unsigned widx;
    out = line;
    widx = int'(addr[CACHE_OFFSET_W-1:2]);
    word = out[widx*32 +: 32];
    if (wstrb[0]) word[7:0]   = wdata[7:0];
    if (wstrb[1]) word[15:8]  = wdata[15:8];
    if (wstrb[2]) word[23:16] = wdata[23:16];
    if (wstrb[3]) word[31:24] = wdata[31:24];
    out[widx*32 +: 32] = word;
    return out;
  endfunction

  function automatic logic pick_victim(
      input logic [SET_W-1:0] s,
      output logic [WAY_W-1:0] way
  );
    logic [WAY_W-1:0] inv, lru;
    logic found_inv, found_lru, row_zero;
    found_inv = 1'b0; found_lru = 1'b0; inv = '0; lru = '0;
    for (int w = 0; w < WAYS; w++) begin
      if (!found_inv && !valid_bits[s][w] && !way_reserved[s][w]) begin
        inv = WAY_W'(w); found_inv = 1'b1;
      end
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

  logic mshr_hit [PORTS];
  logic [MSHR_W-1:0] mshr_hit_idx [PORTS];
  logic mshr_free_comb;
  logic [MSHR_W-1:0] mshr_free_idx_comb;
  logic fill_completing;
  logic [MSHR_W-1:0] fill_mi;

  always_comb begin
    fill_completing = 1'b0;
    fill_mi = '0;
    if (line_resp_valid) begin
      fill_mi = MSHR_W'(line_resp_mshr);
      if (m_valid[fill_mi] && m_fill_sent[fill_mi] &&
          !(m_needs_wb[fill_mi] && m_wb_sent[fill_mi] && !m_wb_done[fill_mi]))
        fill_completing = 1'b1;
    end

    mshr_free_comb = 1'b0; mshr_free_idx_comb = '0;
    for (int i = 0; i < MSHRS; i++) begin
      if (!mshr_free_comb && !m_valid[i]) begin
        mshr_free_comb = 1'b1; mshr_free_idx_comb = MSHR_W'(i);
      end
    end

    for (int p = 0; p < PORTS; p++) begin
      mshr_hit[p] = 1'b0; mshr_hit_idx[p] = '0;
      if (pipe_valid[p]) begin
        for (int i = 0; i < MSHRS; i++) begin
          if (m_valid[i] && (m_line_addr[i] == line_align(pipe_addr[p]))) begin
            mshr_hit[p] = 1'b1; mshr_hit_idx[p] = MSHR_W'(i);
          end
        end
      end
    end
  end

  logic line_sel_valid;
  logic [MSHR_W-1:0] line_sel_idx;
  logic line_sel_is_wb;
  always_comb begin
    line_sel_valid = 1'b0; line_sel_idx = '0; line_sel_is_wb = 1'b0;
    for (int i = 0; i < MSHRS; i++)
      if (!line_sel_valid && m_valid[i] && m_needs_wb[i] && !m_wb_sent[i]) begin
        line_sel_valid = 1'b1; line_sel_idx = MSHR_W'(i); line_sel_is_wb = 1'b1;
      end
    for (int i = 0; i < MSHRS; i++)
      if (!line_sel_valid && m_valid[i] && (!m_needs_wb[i] || m_wb_done[i]) && !m_fill_sent[i]) begin
        line_sel_valid = 1'b1; line_sel_idx = MSHR_W'(i); line_sel_is_wb = 1'b0;
      end
  end

  assign line_req_valid = line_sel_valid && !drain_active;
  assign line_req_write = line_sel_is_wb;
  assign line_req_mshr  = DRAM_MSHR_IDX_W'(line_sel_idx);
  assign line_req_addr  = line_sel_is_wb
      ? data_t'({tags[m_set[line_sel_idx]][m_way[line_sel_idx]], m_set[line_sel_idx],
                 {CACHE_OFFSET_W{1'b0}}})
      : m_line_addr[line_sel_idx];
  assign line_req_wdata = m_wb_line[line_sel_idx];

  logic pipe_free [PORTS];
  int accept_lane [PORTS];
  always_comb begin
    mem_req_ready = '0;
    for (int p = 0; p < PORTS; p++) begin
      pipe_free[p] = !pipe_valid[p] && !hit_pend_valid[p];
      accept_lane[p] = -1;
    end
    if (!drain_active) begin
      automatic int next_p;
      next_p = 0;
      for (int lane = 0; lane < WIDTH; lane++) begin
        if (mem_req_valid[lane]) begin
          while (next_p < PORTS && !pipe_free[next_p]) next_p++;
          if (next_p < PORTS) begin
            accept_lane[next_p] = lane;
            mem_req_ready[lane] = 1'b1;
            next_p++;
          end
        end
      end
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      drain_active <= 1'b0; drain_mshr <= '0; drain_idx <= '0; drain_line <= '0;
      mem_resp_valid <= '0;
      hit_count <= 0; miss_count <= 0;
      for (int p = 0; p < PORTS; p++) begin
        pipe_valid[p] <= 1'b0; pipe_write[p] <= 1'b0;
        pipe_addr[p] <= '0; pipe_wdata[p] <= '0; pipe_wstrb[p] <= '0; pipe_id[p] <= '0;
        pipe_set[p] <= '0; pipe_tag[p] <= '0;
        hit_pend_valid[p] <= 1'b0; hit_pend_rdata[p] <= '0;
        hit_pend_id[p] <= '0; hit_pend_drop[p] <= 1'b0;
      end
      for (int lane = 0; lane < WIDTH; lane++) begin
        mem_resp_rdata[lane] <= '0; mem_resp_id[lane] <= '0;
      end
      for (int s = 0; s < SETS; s++)
        for (int w = 0; w < WAYS; w++) begin
          valid_bits[s][w] <= 1'b0; dirty_bits[s][w] <= 1'b0;
          way_reserved[s][w] <= 1'b0; tags[s][w] <= '0; data_arr[s][w] <= '0;
          for (int j = 0; j < WAYS; j++) lru_mat[s][w][j] <= 1'b0;
        end
      for (int i = 0; i < MSHRS; i++) begin
        m_valid[i] <= 1'b0;
        m_line_addr[i] <= '0; m_set[i] <= '0; m_tag[i] <= '0; m_way[i] <= '0;
        m_needs_wb[i] <= 1'b0; m_wb_sent[i] <= 1'b0; m_wb_done[i] <= 1'b0;
        m_fill_sent[i] <= 1'b0; m_wb_line[i] <= '0; m_drop_ufp[i] <= 1'b0;
        m_ufp_pending[i] <= 1'b0; m_fill_line[i] <= '0;
        w_count[i] <= '0;
        for (int q = 0; q < WQ; q++) begin
          w_valid[i][q] <= 1'b0; w_write[i][q] <= 1'b0;
          w_addr[i][q] <= '0; w_wdata[i][q] <= '0; w_wstrb[i][q] <= '0; w_id[i][q] <= '0;
        end
      end
    end else begin
      automatic logic [WAY_W-1:0] vw, hw;
      automatic logic got_victim, is_hit, need_wb;
      automatic logic [MSHR_W-1:0] mi, free_i, hit_mi;
      automatic cache_line_t line;
      automatic logic any_store, saw_mshr, drain_busy;
      automatic logic [$clog2(WQ+1)-1:0] wc_shadow [MSHRS];
      automatic logic m_valid_shadow [MSHRS];
      automatic data_t m_line_shadow [MSHRS];
      automatic int resp_slot, q;

      mem_resp_valid <= '0;
      resp_slot = 0;
      drain_busy = drain_active;
      for (int i = 0; i < MSHRS; i++) begin
        wc_shadow[i] = w_count[i];
        m_valid_shadow[i] = m_valid[i];
        m_line_shadow[i] = m_line_addr[i];
      end
      // First free MSHR from shadow (updated after each alloc this cycle).
      free_i = '0;
      begin
        automatic logic found_free;
        found_free = 1'b0;
        for (int i = 0; i < MSHRS; i++) begin
          if (!found_free && !m_valid_shadow[i]) begin
            free_i = MSHR_W'(i); found_free = 1'b1;
          end
        end
      end

      if (flush) begin
        for (int p = 0; p < PORTS; p++) begin
          if (hit_pend_valid[p]) hit_pend_drop[p] <= 1'b1;
          pipe_valid[p] <= 1'b0;
        end
        for (int i = 0; i < MSHRS; i++) begin
          if (m_valid[i]) m_drop_ufp[i] <= 1'b1;
          m_ufp_pending[i] <= 1'b0;
          w_count[i] <= '0;
          for (int qq = 0; qq < WQ; qq++) w_valid[i][qq] <= 1'b0;
        end
        if (drain_active) drain_active <= 1'b0;
      end

      if (!flush) begin
        for (int p = 0; p < PORTS; p++) begin
          if (accept_lane[p] >= 0) begin
            pipe_valid[p] <= 1'b1;
            pipe_write[p] <= mem_req_write[accept_lane[p]];
            pipe_addr[p]  <= mem_req_addr[accept_lane[p]];
            pipe_wdata[p] <= mem_req_wdata[accept_lane[p]];
            pipe_wstrb[p] <= mem_req_wstrb[accept_lane[p]];
            pipe_id[p]    <= mem_req_id[accept_lane[p]];
            pipe_set[p]   <= idx_of(mem_req_addr[accept_lane[p]]);
            pipe_tag[p]   <= tag_of(mem_req_addr[accept_lane[p]]);
          end
        end
      end

      for (int p = 0; p < PORTS; p++) begin
        if (hit_pend_valid[p]) begin
          if (hit_pend_drop[p] || flush) begin
            hit_pend_valid[p] <= 1'b0;
            hit_pend_drop[p] <= 1'b0;
          end else if (resp_slot < WIDTH) begin
            mem_resp_valid[resp_slot] <= 1'b1;
            mem_resp_rdata[resp_slot] <= hit_pend_rdata[p];
            mem_resp_id[resp_slot]    <= hit_pend_id[p];
            resp_slot++;
            hit_pend_valid[p] <= 1'b0;
            hit_pend_drop[p] <= 1'b0;
          end
          // else: keep hit_pend until a resp lane is free
        end
      end

      // Ports processed in order with shadow MSHR/waiter state so same-cycle
      // dual UFP ops do not collide on one waiter slot or miss a fresh alloc.
      for (int p = 0; p < PORTS; p++) begin
        if (pipe_valid[p] && !flush) begin
          pipe_valid[p] <= 1'b0;
          is_hit = 1'b0; hw = '0;
          for (int w = 0; w < WAYS; w++) begin
            if (valid_bits[pipe_set[p]][w] && !way_reserved[pipe_set[p]][w] &&
                (tags[pipe_set[p]][w] == pipe_tag[p])) begin
              is_hit = 1'b1; hw = WAY_W'(w);
            end
          end

          saw_mshr = 1'b0; hit_mi = '0;
          for (int i = 0; i < MSHRS; i++) begin
            if (m_valid_shadow[i] &&
                (m_line_shadow[i] == line_align(pipe_addr[p]))) begin
              saw_mshr = 1'b1; hit_mi = MSHR_W'(i);
            end
          end

          if (is_hit) begin
            hit_count <= hit_count + 1;
            for (int j = 0; j < WAYS; j++) begin
              lru_mat[pipe_set[p]][hw][j] <= 1'b1;
              lru_mat[pipe_set[p]][j][hw] <= 1'b0;
            end
            lru_mat[pipe_set[p]][hw][hw] <= 1'b0;
            if (pipe_write[p]) begin
              if (resp_slot < WIDTH) begin
                data_arr[pipe_set[p]][hw] <=
                    apply_store(data_arr[pipe_set[p]][hw], pipe_addr[p],
                                pipe_wdata[p], pipe_wstrb[p]);
                dirty_bits[pipe_set[p]][hw] <= 1'b1;
                mem_resp_valid[resp_slot] <= 1'b1;
                mem_resp_id[resp_slot] <= pipe_id[p];
                mem_resp_rdata[resp_slot] <= '0;
                resp_slot++;
              end else begin
                pipe_valid[p] <= 1'b1; // resp backpressure
              end
            end else begin
              hit_pend_valid[p] <= 1'b1;
              hit_pend_rdata[p] <= word_from_line(data_arr[pipe_set[p]][hw], pipe_addr[p]);
              hit_pend_id[p] <= pipe_id[p];
              hit_pend_drop[p] <= 1'b0;
            end
          end else if (saw_mshr) begin
            if (fill_completing && (hit_mi == fill_mi)) begin
              pipe_valid[p] <= 1'b1;
            end else if (wc_shadow[hit_mi] < WQ[$clog2(WQ+1)-1:0]) begin
              q = int'(wc_shadow[hit_mi]);
              w_valid[hit_mi][q] <= 1'b1;
              w_write[hit_mi][q] <= pipe_write[p];
              w_addr[hit_mi][q]  <= pipe_addr[p];
              w_wdata[hit_mi][q] <= pipe_wdata[p];
              w_wstrb[hit_mi][q] <= pipe_wstrb[p];
              w_id[hit_mi][q]    <= pipe_id[p];
              wc_shadow[hit_mi] = wc_shadow[hit_mi] + 1'b1;
              w_count[hit_mi] <= wc_shadow[hit_mi];
            end else begin
              pipe_valid[p] <= 1'b1;
            end
          end else begin
            // Allocate a free MSHR from the intra-cycle shadow (multi-alloc OK).
            begin
              automatic logic found_free;
              found_free = 1'b0; free_i = '0;
              for (int i = 0; i < MSHRS; i++) begin
                if (!found_free && !m_valid_shadow[i]) begin
                  free_i = MSHR_W'(i); found_free = 1'b1;
                end
              end
              if (!found_free) begin
                pipe_valid[p] <= 1'b1;
              end else begin
                got_victim = pick_victim(pipe_set[p], vw);
                if (!got_victim) begin
                  pipe_valid[p] <= 1'b1;
                end else begin
                  miss_count <= miss_count + 1;
                  mi = free_i;
                  need_wb = valid_bits[pipe_set[p]][vw] && dirty_bits[pipe_set[p]][vw];
                  m_valid[mi] <= 1'b1;
                  m_line_addr[mi] <= line_align(pipe_addr[p]);
                  m_set[mi] <= pipe_set[p];
                  m_tag[mi] <= pipe_tag[p];
                  m_way[mi] <= vw;
                  m_needs_wb[mi] <= need_wb;
                  m_wb_sent[mi] <= 1'b0;
                  m_wb_done[mi] <= !need_wb;
                  m_fill_sent[mi] <= 1'b0;
                  m_wb_line[mi] <= data_arr[pipe_set[p]][vw];
                  m_drop_ufp[mi] <= 1'b0;
                  m_ufp_pending[mi] <= 1'b0;
                  way_reserved[pipe_set[p]][vw] <= 1'b1;
                  w_valid[mi][0] <= 1'b1;
                  w_write[mi][0] <= pipe_write[p];
                  w_addr[mi][0]  <= pipe_addr[p];
                  w_wdata[mi][0] <= pipe_wdata[p];
                  w_wstrb[mi][0] <= pipe_wstrb[p];
                  w_id[mi][0]    <= pipe_id[p];
                  w_count[mi] <= 1;
                  wc_shadow[mi] = 1;
                  m_valid_shadow[mi] = 1'b1;
                  m_line_shadow[mi] = line_align(pipe_addr[p]);
                  for (int qq = 1; qq < WQ; qq++) w_valid[mi][qq] <= 1'b0;
                end
              end
            end
          end
        end else if (pipe_valid[p] && flush) begin
          pipe_valid[p] <= 1'b0;
        end
      end

      if (line_req_valid && line_req_ready) begin
        if (line_sel_is_wb) m_wb_sent[line_sel_idx] <= 1'b1;
        else                m_fill_sent[line_sel_idx] <= 1'b1;
      end

      // Drain BEFORE fill so a same-cycle / next-cycle fill cannot strand waiters.
      if (drain_busy) begin
        mi = drain_mshr;
        if (drain_idx < w_count[mi] && w_valid[mi][int'(drain_idx)]) begin
          if (m_drop_ufp[mi]) begin
            if (drain_idx + 1'b1 >= w_count[mi]) begin
              drain_active <= 1'b0;
              drain_idx <= '0;
              drain_busy = 1'b0;
              m_valid[mi] <= 1'b0;
              m_ufp_pending[mi] <= 1'b0;
              way_reserved[m_set[mi]][m_way[mi]] <= 1'b0;
              w_count[mi] <= '0;
              for (int qq = 0; qq < WQ; qq++) w_valid[mi][qq] <= 1'b0;
            end else begin
              drain_idx <= drain_idx + 1'b1;
            end
          end else if (resp_slot < WIDTH) begin
            mem_resp_valid[resp_slot] <= 1'b1;
            mem_resp_id[resp_slot] <= w_id[mi][int'(drain_idx)];
            if (w_write[mi][int'(drain_idx)])
              mem_resp_rdata[resp_slot] <= '0;
            else
              mem_resp_rdata[resp_slot] <=
                  word_from_line(drain_line, w_addr[mi][int'(drain_idx)]);
            resp_slot++;
            if (drain_idx + 1'b1 >= w_count[mi]) begin
              drain_active <= 1'b0;
              drain_idx <= '0;
              drain_busy = 1'b0;
              m_valid[mi] <= 1'b0;
              m_ufp_pending[mi] <= 1'b0;
              way_reserved[m_set[mi]][m_way[mi]] <= 1'b0;
              w_count[mi] <= '0;
              for (int qq = 0; qq < WQ; qq++) w_valid[mi][qq] <= 1'b0;
            end else begin
              drain_idx <= drain_idx + 1'b1;
            end
          end
        end else begin
          drain_active <= 1'b0;
          drain_busy = 1'b0;
          m_valid[mi] <= 1'b0;
          m_ufp_pending[mi] <= 1'b0;
          way_reserved[m_set[mi]][m_way[mi]] <= 1'b0;
        end
      end

      if (line_resp_valid) begin
        mi = MSHR_W'(line_resp_mshr);
        if (m_valid[mi]) begin
          if (m_needs_wb[mi] && m_wb_sent[mi] && !m_wb_done[mi]) begin
            m_wb_done[mi] <= 1'b1;
          end else if (m_fill_sent[mi]) begin
            line = line_resp_rdata;
            any_store = 1'b0;
            for (int qq = 0; qq < WQ; qq++) begin
              if (w_valid[mi][qq] && w_write[mi][qq]) begin
                line = apply_store(line, w_addr[mi][qq], w_wdata[mi][qq], w_wstrb[mi][qq]);
                any_store = 1'b1;
              end
            end
            data_arr[m_set[mi]][m_way[mi]] <= line;
            valid_bits[m_set[mi]][m_way[mi]] <= 1'b1;
            tags[m_set[mi]][m_way[mi]] <= m_tag[mi];
            dirty_bits[m_set[mi]][m_way[mi]] <= any_store;
            way_reserved[m_set[mi]][m_way[mi]] <= 1'b0;
            m_fill_line[mi] <= line;
            for (int j = 0; j < WAYS; j++) begin
              lru_mat[m_set[mi]][m_way[mi]][j] <= 1'b1;
              lru_mat[m_set[mi]][j][m_way[mi]] <= 1'b0;
            end
            lru_mat[m_set[mi]][m_way[mi]][m_way[mi]] <= 1'b0;
            if (!m_drop_ufp[mi] && w_count[mi] != 0) begin
              if (!drain_busy) begin
                drain_active <= 1'b1;
                drain_mshr <= mi;
                drain_idx <= '0;
                drain_line <= line;
                drain_busy = 1'b1;
                m_ufp_pending[mi] <= 1'b0;
              end else begin
                // Drain slot busy — queue this MSHR for UFP completion.
                m_ufp_pending[mi] <= 1'b1;
              end
            end else begin
              m_valid[mi] <= 1'b0;
              m_ufp_pending[mi] <= 1'b0;
              w_count[mi] <= '0;
              for (int qq = 0; qq < WQ; qq++) w_valid[mi][qq] <= 1'b0;
            end
          end
        end
      end

      // After a drain finishes, start the next pending UFP drain if any.
      if (!drain_busy) begin
        for (int i = 0; i < MSHRS; i++) begin
          if (!drain_busy && m_ufp_pending[i] && m_valid[i] && !m_drop_ufp[i] &&
              (w_count[i] != 0)) begin
            drain_active <= 1'b1;
            drain_mshr <= MSHR_W'(i);
            drain_idx <= '0;
            drain_line <= m_fill_line[i];
            drain_busy = 1'b1;
            m_ufp_pending[i] <= 1'b0;
          end
        end
      end
    end
  end

endmodule
