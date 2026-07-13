`timescale 1ns/1ps
// ============================================================================
// lsq.sv -- Out-of-order Load/Store Queue + committed store buffer.
//
// RS-like memory scheduler:
//   * entries allocate into free slots in dispatch-lane order
//   * operands wake from the CDB broadcast bus
//   * loads may issue out of order when older stores are safe
//   * up to WIDTH memory requests can issue per cycle
//   * committed stores enqueue into an SB FIFO (depth STORE_BUF_DEPTH);
//     ROB store_complete fires on enqueue; LSQ entry frees immediately
//   * SB drains in-order to D$ in the background (not squashed on recovery)
//   * load visibility: older LSQ stores, then SB, then mem; partial merge OK
// ============================================================================
module lsq
  import pkg_cpu::*;
(
  input  logic     clk,
  input  logic     rst,
  input  logic     flush,
  input  logic     squash_en,
  input  rob_tag_t squash_tag,
  input  rob_tag_t rob_head,

  // dispatch / allocate. Ready is prefix-based.
  input  valid_bundle_t dispatch_valid,
  output valid_bundle_t dispatch_ready,
  input  uop_bundle_t   dispatch_uop,
  input  rob_tag_t      dispatch_tag [WIDTH],
  input  operand_t      dispatch_base [WIDTH],
  input  operand_t      dispatch_store_data [WIDTH],

  // CDB wakeup
  input  cdb_bus_t cdb_in,

  // store retirement permission from commit, oldest-to-youngest prefix.
  input  valid_bundle_t commit_store_valid,
  input  rob_tag_t      commit_store_tag [WIDTH],

  // data memory request bundle (tagged)
  output valid_bundle_t mem_req_valid,
  input  valid_bundle_t mem_req_ready,
  output valid_bundle_t mem_req_write,
  output data_t         mem_req_addr [WIDTH],
  output data_t         mem_req_wdata [WIDTH],
  output logic [3:0]    mem_req_wstrb [WIDTH],
  output mem_id_t       mem_req_id [WIDTH],

  // data memory load/store response bundle (matched by id)
  input  valid_bundle_t mem_resp_valid,
  input  data_t         mem_resp_rdata [WIDTH],
  input  mem_id_t       mem_resp_id [WIDTH],

  // load write-back
  input  logic cdb_ready [NUM_LSQ],
  output cdb_t out_cdb [NUM_LSQ],

  // ROB completion for stores after SB enqueue (not after D$ resp)
  output valid_bundle_t store_complete_valid,
  output rob_tag_t      store_complete_tag [WIDTH],

  output logic     full,
  output logic     empty
);

  typedef enum logic [1:0] {
    ST_WAIT     = 2'd0,
    ST_MEM_RESP = 2'd1,
    ST_CDB_WAIT = 2'd2
  } state_e;

  localparam int AGE_W   = 16;
  localparam int SB_CNT_W = $clog2(STORE_BUF_DEPTH + 1);

  logic     busy       [LSQ_DEPTH];
  state_e   state      [LSQ_DEPTH];
  uop_t     uop_q      [LSQ_DEPTH];
  rob_tag_t tag_q      [LSQ_DEPTH];
  logic [AGE_W-1:0] age_q [LSQ_DEPTH];

  logic     base_ready [LSQ_DEPTH];
  logic     data_ready [LSQ_DEPTH];
  rob_tag_t base_tag   [LSQ_DEPTH];
  rob_tag_t data_tag   [LSQ_DEPTH];
  data_t    base_value [LSQ_DEPTH];
  data_t    data_value [LSQ_DEPTH];
  data_t    load_data  [LSQ_DEPTH];
  logic     partial_fwd_en   [LSQ_DEPTH];
  data_t    partial_fwd_word [LSQ_DEPTH];
  logic [3:0] partial_fwd_mask [LSQ_DEPTH];

  // Committed store buffer (survives squash/flush; clears on rst only).
  logic              sb_valid  [STORE_BUF_DEPTH];
  logic              sb_issued [STORE_BUF_DEPTH];
  data_t             sb_addr   [STORE_BUF_DEPTH];
  data_t             sb_wdata  [STORE_BUF_DEPTH];
  logic [3:0]        sb_wstrb  [STORE_BUF_DEPTH];
  logic [STORE_BUF_W-1:0] sb_head;
  logic [STORE_BUF_W-1:0] sb_tail;
  logic [SB_CNT_W-1:0]    sb_count;

  logic [AGE_W-1:0] next_age;

  logic [WIDTH-1:0][LSQ_W-1:0] alloc_idx;
  logic [WIDTH-1:0][AGE_W-1:0] alloc_age;

  logic load_can_mem [LSQ_DEPTH];
  logic load_can_fwd [LSQ_DEPTH];
  data_t load_fwd_value [LSQ_DEPTH];
  data_t load_partial_word [LSQ_DEPTH];
  logic [3:0] load_partial_mask [LSQ_DEPTH];

  logic [WIDTH-1:0][LSQ_W-1:0] store_sel_idx;
  logic [WIDTH-1:0]            store_sel_valid;
  logic [WIDTH-1:0][LSQ_W-1:0] load_mem_sel_idx;
  logic [WIDTH-1:0]            load_mem_sel_valid;
  logic [WIDTH-1:0][LSQ_W-1:0] load_fwd_sel_idx;
  logic [WIDTH-1:0]            load_fwd_sel_valid;
  logic [NUM_LSQ-1:0][LSQ_W-1:0] cdb_sel_idx;
  logic [NUM_LSQ-1:0]            cdb_sel_valid;

  logic [WIDTH-1:0][STORE_BUF_W-1:0] sb_drain_idx;
  logic [WIDTH-1:0]                  sb_drain_valid;

  valid_bundle_t dispatch_fire;
  valid_bundle_t store_enqueue_fire;
  valid_bundle_t sb_drain_fire;
  valid_bundle_t load_mem_fire;
  valid_bundle_t load_fwd_fire;
  logic [NUM_LSQ-1:0] load_cdb_fire;

  function automatic logic operand_ready_now(input logic ready, input rob_tag_t tag);
    operand_ready_now = ready;
    for (int i = 0; i < CDB_WIDTH; i++) begin
      if (cdb_in[i].valid && (tag == cdb_in[i].tag)) operand_ready_now = 1'b1;
    end
  endfunction

  function automatic data_t operand_value_now(input logic ready, input data_t value, input rob_tag_t tag);
    operand_value_now = value;
    if (!ready) begin
      for (int i = 0; i < CDB_WIDTH; i++) begin
        if (cdb_in[i].valid && (tag == cdb_in[i].tag)) operand_value_now = cdb_in[i].data;
      end
    end
  endfunction

  function automatic logic age_before(input logic [AGE_W-1:0] a, input logic [AGE_W-1:0] b);
    age_before = ((b - a) < (AGE_W'(1) << (AGE_W-1)));
  endfunction

  function automatic logic [3:0] access_mask(input memsz_e size, input logic [1:0] addr_low);
    unique case (size)
      SZ_B:    access_mask = 4'b0001 << addr_low;
      SZ_H:    access_mask = addr_low[1] ? 4'b1100 : 4'b0011;
      default: access_mask = 4'b1111;
    endcase
  endfunction

  function automatic data_t store_wdata(input data_t value, input memsz_e size, input logic [1:0] addr_low);
    unique case (size)
      SZ_B:    store_wdata = {4{value[7:0]}} << (8 * addr_low);
      SZ_H:    store_wdata = {2{value[15:0]}} << (16 * addr_low[1]);
      default: store_wdata = value;
    endcase
  endfunction

  function automatic data_t load_extend(
    input data_t  word,
    input memsz_e size,
    input logic   is_unsigned,
    input logic [1:0] addr_low
  );
    logic [7:0]  b;
    logic [15:0] h;

    b = word >> (8 * addr_low);
    h = addr_low[1] ? word[31:16] : word[15:0];

    unique case (size)
      SZ_B:    load_extend = is_unsigned ? {24'd0, b} : {{24{b[7]}}, b};
      SZ_H:    load_extend = is_unsigned ? {16'd0, h} : {{16{h[15]}}, h};
      default: load_extend = word;
    endcase
  endfunction

  function automatic logic same_word(input data_t a, input data_t b);
    same_word = (a[31:2] == b[31:2]);
  endfunction

  function automatic logic [1:0] addr_low(input data_t addr);
    addr_low = addr[1:0];
  endfunction

  function automatic logic commit_matches(input rob_tag_t tag);
    commit_matches = 1'b0;
    for (int lane = 0; lane < WIDTH; lane++) begin
      if (commit_store_valid[lane] && (commit_store_tag[lane] == tag)) begin
        commit_matches = 1'b1;
      end
    end
  endfunction

  always_comb begin
    int free_count;
    int accepted;
    logic prefix_ok;
    logic [LSQ_DEPTH-1:0] chosen_free;
    logic any_lsq;

    any_lsq = 1'b0;
    free_count = 0;
    for (int i = 0; i < LSQ_DEPTH; i++) begin
      if (busy[i]) any_lsq = 1'b1;
      else free_count++;
    end
    empty = !any_lsq && (sb_count == '0);
    full  = (free_count == 0);

    chosen_free = '0;
    accepted = 0;
    prefix_ok = 1'b1;
    dispatch_ready = '0;
    alloc_idx = '0;
    alloc_age = '0;

    // RS-style prefix ready: assert ready even when valid=0 so rename can accept.
    for (int lane = 0; lane < WIDTH; lane++) begin
      if (!dispatch_valid[lane]) begin
        dispatch_ready[lane] = prefix_ok;
      end else if (prefix_ok && (accepted < free_count)) begin
        logic found;
        found = 1'b0;
        dispatch_ready[lane] = 1'b1;
        for (int i = 0; i < LSQ_DEPTH; i++) begin
          if (!found && !busy[i] && !chosen_free[i]) begin
            found = 1'b1;
            chosen_free[i] = 1'b1;
            alloc_idx[lane] = LSQ_W'(i);
            alloc_age[lane] = next_age + AGE_W'(accepted);
            accepted++;
          end
        end
        if (!found) begin
          dispatch_ready[lane] = 1'b0;
          prefix_ok = 1'b0;
        end
      end else begin
        dispatch_ready[lane] = 1'b0;
        prefix_ok = 1'b0;
      end
    end

    dispatch_fire = dispatch_valid & dispatch_ready;
  end

  // Per-load safety and forwarding eligibility (LSQ stores, then SB).
  always_comb begin
    for (int i = 0; i < LSQ_DEPTH; i++) begin
      logic  blocked;
      logic  any_overlap;
      logic [3:0] covered_mask;
      logic [3:0] lsq_cover;
      logic [3:0] load_mask;
      logic [AGE_W-1:0] byte_age0, byte_age1, byte_age2, byte_age3;
      data_t load_addr;
      data_t fwd_word;

      load_can_mem[i] = 1'b0;
      load_can_fwd[i] = 1'b0;
      load_fwd_value[i] = '0;
      load_partial_word[i] = '0;
      load_partial_mask[i] = 4'b0000;

      blocked = 1'b0;
      any_overlap = 1'b0;
      covered_mask = 4'b0000;
      lsq_cover = 4'b0000;
      byte_age0 = '0;
      byte_age1 = '0;
      byte_age2 = '0;
      byte_age3 = '0;
      load_addr = base_value[i] + uop_q[i].imm;
      load_mask = access_mask(uop_q[i].mem_size, load_addr[1:0]);
      fwd_word = '0;

      if (busy[i] && (state[i] == ST_WAIT) && uop_q[i].is_load && base_ready[i]) begin
        for (int j = 0; j < LSQ_DEPTH; j++) begin
          if (busy[j] && uop_q[j].is_store && age_before(age_q[j], age_q[i])) begin
            data_t store_addr;
            data_t swdata;
            logic [3:0] smask;
            logic [3:0] overlap;

            if (!base_ready[j] || !data_ready[j]) begin
              blocked = 1'b1;
            end else begin
              store_addr = base_value[j] + uop_q[j].imm;
              smask      = access_mask(uop_q[j].mem_size, store_addr[1:0]);
              overlap    = same_word(store_addr, load_addr) ? (smask & load_mask) : 4'b0000;

              if (overlap != 4'b0000) begin
                any_overlap = 1'b1;
                swdata = store_wdata(data_value[j], uop_q[j].mem_size, store_addr[1:0]);
                if (overlap[0] && (!covered_mask[0] || age_before(byte_age0, age_q[j]))) begin
                  fwd_word[7:0] = swdata[7:0];
                  byte_age0 = age_q[j];
                  covered_mask[0] = 1'b1;
                end
                if (overlap[1] && (!covered_mask[1] || age_before(byte_age1, age_q[j]))) begin
                  fwd_word[15:8] = swdata[15:8];
                  byte_age1 = age_q[j];
                  covered_mask[1] = 1'b1;
                end
                if (overlap[2] && (!covered_mask[2] || age_before(byte_age2, age_q[j]))) begin
                  fwd_word[23:16] = swdata[23:16];
                  byte_age2 = age_q[j];
                  covered_mask[2] = 1'b1;
                end
                if (overlap[3] && (!covered_mask[3] || age_before(byte_age3, age_q[j]))) begin
                  fwd_word[31:24] = swdata[31:24];
                  byte_age3 = age_q[j];
                  covered_mask[3] = 1'b1;
                end
              end
            end
          end
        end

        lsq_cover = covered_mask;

        // SB fills only LSQ-uncovered bytes; oldest→youngest so later SB wins.
        for (int s = 0; s < STORE_BUF_DEPTH; s++) begin
          if (SB_CNT_W'(s) < sb_count) begin
            automatic int unsigned sb_i;
            automatic logic [3:0] smask;
            automatic logic [3:0] overlap;
            sb_i = int'((sb_head + STORE_BUF_W'(s)) % STORE_BUF_DEPTH);
            if (sb_valid[sb_i]) begin
              smask = sb_wstrb[sb_i];
              overlap = same_word(sb_addr[sb_i], load_addr) ? (smask & load_mask) : 4'b0000;
              if (overlap != 4'b0000) begin
                any_overlap = 1'b1;
                if (overlap[0] && !lsq_cover[0]) begin
                  fwd_word[7:0] = sb_wdata[sb_i][7:0];
                  covered_mask[0] = 1'b1;
                end
                if (overlap[1] && !lsq_cover[1]) begin
                  fwd_word[15:8] = sb_wdata[sb_i][15:8];
                  covered_mask[1] = 1'b1;
                end
                if (overlap[2] && !lsq_cover[2]) begin
                  fwd_word[23:16] = sb_wdata[sb_i][23:16];
                  covered_mask[2] = 1'b1;
                end
                if (overlap[3] && !lsq_cover[3]) begin
                  fwd_word[31:24] = sb_wdata[sb_i][31:24];
                  covered_mask[3] = 1'b1;
                end
              end
            end
          end
        end

        if (!blocked) begin
          if ((covered_mask & load_mask) == load_mask) begin
            load_can_fwd[i] = 1'b1;
            load_fwd_value[i] = load_extend(fwd_word, uop_q[i].mem_size,
                                            uop_q[i].mem_unsigned, load_addr[1:0]);
          end else if (!any_overlap) begin
            load_can_mem[i] = 1'b1;
          end else begin
            load_can_mem[i] = 1'b1;
            load_partial_word[i] = fwd_word;
            load_partial_mask[i] = covered_mask & load_mask;
          end
        end
      end
    end
  end

  always_comb begin
    logic [LSQ_DEPTH-1:0] chosen_store;
    logic [LSQ_DEPTH-1:0] chosen_load_mem;
    logic [LSQ_DEPTH-1:0] chosen_load_fwd;
    logic [LSQ_DEPTH-1:0] chosen_cdb;
    logic [STORE_BUF_DEPTH-1:0] chosen_sb_drain;
    int req_lane;
    int sb_slots_taken;
    int unsigned sb_idx;

    chosen_store = '0;
    chosen_load_mem = '0;
    chosen_load_fwd = '0;
    chosen_cdb = '0;
    chosen_sb_drain = '0;
    store_sel_idx = '0;
    store_sel_valid = '0;
    load_mem_sel_idx = '0;
    load_mem_sel_valid = '0;
    load_fwd_sel_idx = '0;
    load_fwd_sel_valid = '0;
    cdb_sel_idx = '0;
    cdb_sel_valid = '0;
    sb_drain_idx = '0;
    sb_drain_valid = '0;

    sb_slots_taken = 0;
    for (int lane = 0; lane < WIDTH; lane++) begin
      for (int i = 0; i < LSQ_DEPTH; i++) begin
        if (busy[i] && (state[i] == ST_WAIT) && uop_q[i].is_store &&
            base_ready[i] && data_ready[i] && commit_matches(tag_q[i]) &&
            !chosen_store[i] &&
            (sb_count + SB_CNT_W'(sb_slots_taken) < SB_CNT_W'(STORE_BUF_DEPTH)) &&
            (!store_sel_valid[lane] || age_before(age_q[i], age_q[store_sel_idx[lane]]))) begin
          store_sel_valid[lane] = 1'b1;
          store_sel_idx[lane] = LSQ_W'(i);
        end
      end
      if (store_sel_valid[lane]) begin
        chosen_store[store_sel_idx[lane]] = 1'b1;
        sb_slots_taken++;
      end
    end

    for (int lane = 0; lane < WIDTH; lane++) begin
      for (int i = 0; i < LSQ_DEPTH; i++) begin
        if (load_can_fwd[i] && !chosen_load_fwd[i] &&
            (!load_fwd_sel_valid[lane] || age_before(age_q[i], age_q[load_fwd_sel_idx[lane]]))) begin
          load_fwd_sel_valid[lane] = 1'b1;
          load_fwd_sel_idx[lane] = LSQ_W'(i);
        end
      end
      if (load_fwd_sel_valid[lane]) chosen_load_fwd[load_fwd_sel_idx[lane]] = 1'b1;
    end

    for (int lane = 0; lane < WIDTH; lane++) begin
      for (int i = 0; i < LSQ_DEPTH; i++) begin
        if (load_can_mem[i] && !chosen_load_mem[i] && !chosen_load_fwd[i] &&
            (!load_mem_sel_valid[lane] || age_before(age_q[i], age_q[load_mem_sel_idx[lane]]))) begin
          load_mem_sel_valid[lane] = 1'b1;
          load_mem_sel_idx[lane] = LSQ_W'(i);
        end
      end
      if (load_mem_sel_valid[lane]) chosen_load_mem[load_mem_sel_idx[lane]] = 1'b1;
    end

    for (int lane = 0; lane < NUM_LSQ; lane++) begin
      for (int i = 0; i < LSQ_DEPTH; i++) begin
        if (busy[i] && (state[i] == ST_CDB_WAIT) && !chosen_cdb[i] &&
            (!cdb_sel_valid[lane] || age_before(age_q[i], age_q[cdb_sel_idx[lane]]))) begin
          cdb_sel_valid[lane] = 1'b1;
          cdb_sel_idx[lane] = LSQ_W'(i);
        end
      end
      if (cdb_sel_valid[lane]) chosen_cdb[cdb_sel_idx[lane]] = 1'b1;
    end

    // Oldest unissued SB entries first (in-order drain).
    for (int lane = 0; lane < WIDTH; lane++) begin
      for (int s = 0; s < STORE_BUF_DEPTH; s++) begin
        if (!sb_drain_valid[lane] && (SB_CNT_W'(s) < sb_count)) begin
          sb_idx = int'((sb_head + STORE_BUF_W'(s)) % STORE_BUF_DEPTH);
          if (sb_valid[sb_idx] && !sb_issued[sb_idx] && !chosen_sb_drain[sb_idx]) begin
            sb_drain_valid[lane] = 1'b1;
            sb_drain_idx[lane] = STORE_BUF_W'(sb_idx);
          end
        end
      end
      if (sb_drain_valid[lane]) chosen_sb_drain[sb_drain_idx[lane]] = 1'b1;
    end

    mem_req_valid = '0;
    mem_req_write = '0;
    mem_req_addr = '{default:'0};
    mem_req_wdata = '{default:'0};
    mem_req_wstrb = '{default:'0};
    mem_req_id = '{default:'0};
    store_enqueue_fire = store_sel_valid;
    sb_drain_fire = '0;
    load_mem_fire = '0;
    load_fwd_fire = load_fwd_sel_valid;
    load_cdb_fire = '0;

    req_lane = 0;
    for (int sel = 0; sel < WIDTH; sel++) begin
      if (sb_drain_valid[sel] && (req_lane < WIDTH)) begin
        automatic int unsigned di;
        di = int'(sb_drain_idx[sel]);
        mem_req_valid[req_lane] = 1'b1;
        mem_req_write[req_lane] = 1'b1;
        mem_req_addr[req_lane]  = sb_addr[di];
        mem_req_wdata[req_lane] = sb_wdata[di];
        mem_req_wstrb[req_lane] = sb_wstrb[di];
        mem_req_id[req_lane]    = mem_id_t'(LSQ_DEPTH + di);
        sb_drain_fire[sel] = mem_req_ready[req_lane];
        req_lane++;
      end
    end

    for (int sel = 0; sel < WIDTH; sel++) begin
      if (load_mem_sel_valid[sel] && (req_lane < WIDTH)) begin
        data_t addr;
        addr = base_value[load_mem_sel_idx[sel]] + uop_q[load_mem_sel_idx[sel]].imm;
        mem_req_valid[req_lane] = 1'b1;
        mem_req_write[req_lane] = 1'b0;
        mem_req_addr[req_lane]  = addr;
        mem_req_wdata[req_lane] = '0;
        mem_req_wstrb[req_lane] = 4'b0000;
        mem_req_id[req_lane]    = mem_id_t'(load_mem_sel_idx[sel]);
        load_mem_fire[sel] = mem_req_ready[req_lane];
        req_lane++;
      end
    end

    for (int lane = 0; lane < NUM_LSQ; lane++) begin
      load_cdb_fire[lane] = cdb_sel_valid[lane] && cdb_ready[lane];
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      next_age <= '0;
      out_cdb  <= '{default:'0};
      store_complete_valid <= '0;
      store_complete_tag <= '{default:'0};
      sb_head  <= '0;
      sb_tail  <= '0;
      sb_count <= '0;
      for (int i = 0; i < STORE_BUF_DEPTH; i++) begin
        sb_valid[i]  <= 1'b0;
        sb_issued[i] <= 1'b0;
        sb_addr[i]   <= '0;
        sb_wdata[i]  <= '0;
        sb_wstrb[i]  <= 4'b0000;
      end
      for (int i = 0; i < LSQ_DEPTH; i++) begin
        busy[i]       <= 1'b0;
        state[i]      <= ST_WAIT;
        uop_q[i]      <= '0;
        tag_q[i]      <= '0;
        age_q[i]      <= '0;
        base_ready[i] <= 1'b0;
        data_ready[i] <= 1'b0;
        base_tag[i]   <= '0;
        data_tag[i]   <= '0;
        base_value[i] <= '0;
        data_value[i] <= '0;
        load_data[i]  <= '0;
        partial_fwd_en[i]   <= 1'b0;
        partial_fwd_word[i] <= '0;
        partial_fwd_mask[i] <= 4'b0000;
      end
    end else begin
      logic [STORE_BUF_W-1:0] n_head, n_tail;
      logic [SB_CNT_W-1:0]    n_count;
      logic                   n_valid  [STORE_BUF_DEPTH];
      logic                   n_issued [STORE_BUF_DEPTH];

      n_head  = sb_head;
      n_tail  = sb_tail;
      n_count = sb_count;
      for (int i = 0; i < STORE_BUF_DEPTH; i++) begin
        n_valid[i]  = sb_valid[i];
        n_issued[i] = sb_issued[i];
      end

      out_cdb <= '{default:'0};
      store_complete_valid <= '0;
      store_complete_tag <= '{default:'0};

      if (flush) begin
        // Speculative LSQ only; committed SB continues draining.
        next_age <= '0;
        for (int i = 0; i < LSQ_DEPTH; i++) begin
          busy[i]       <= 1'b0;
          state[i]      <= ST_WAIT;
          uop_q[i]      <= '0;
          tag_q[i]      <= '0;
          age_q[i]      <= '0;
          base_ready[i] <= 1'b0;
          data_ready[i] <= 1'b0;
          base_tag[i]   <= '0;
          data_tag[i]   <= '0;
          base_value[i] <= '0;
          data_value[i] <= '0;
          load_data[i]  <= '0;
          partial_fwd_en[i]   <= 1'b0;
          partial_fwd_word[i] <= '0;
          partial_fwd_mask[i] <= 4'b0000;
        end
      end else begin
        if (squash_en) begin
          for (int i = 0; i < LSQ_DEPTH; i++) begin
            if (busy[i] && rob_is_younger(rob_head, tag_q[i], squash_tag)) begin
              busy[i]  <= 1'b0;
              state[i] <= ST_WAIT;
              partial_fwd_en[i]   <= 1'b0;
              partial_fwd_word[i] <= '0;
              partial_fwd_mask[i] <= 4'b0000;
            end
          end
        end

        for (int i = 0; i < LSQ_DEPTH; i++) begin
          for (int lane = 0; lane < CDB_WIDTH; lane++) begin
            if (cdb_in[lane].valid && busy[i] && !base_ready[i] &&
                (base_tag[i] == cdb_in[lane].tag)) begin
              base_ready[i] <= 1'b1;
              base_value[i] <= cdb_in[lane].data;
            end
            if (cdb_in[lane].valid && busy[i] && !data_ready[i] &&
                (data_tag[i] == cdb_in[lane].tag)) begin
              data_ready[i] <= 1'b1;
              data_value[i] <= cdb_in[lane].data;
            end
          end
        end

        for (int lane = 0; lane < WIDTH; lane++) begin
          if (store_enqueue_fire[lane]) begin
            automatic int unsigned sidx;
            automatic data_t addr;
            sidx = int'(store_sel_idx[lane]);
            addr = base_value[sidx] + uop_q[sidx].imm;
            sb_addr[n_tail]  <= addr;
            sb_wdata[n_tail] <= store_wdata(data_value[sidx], uop_q[sidx].mem_size, addr[1:0]);
            sb_wstrb[n_tail] <= access_mask(uop_q[sidx].mem_size, addr[1:0]);
            n_valid[n_tail]  = 1'b1;
            n_issued[n_tail] = 1'b0;
            store_complete_valid[lane] <= 1'b1;
            store_complete_tag[lane]   <= tag_q[sidx];
            busy[sidx]  <= 1'b0;
            state[sidx] <= ST_WAIT;
            n_tail  = STORE_BUF_W'(n_tail + STORE_BUF_W'(1));
            n_count = SB_CNT_W'(n_count + SB_CNT_W'(1));
          end
        end

        for (int lane = 0; lane < WIDTH; lane++) begin
          if (load_mem_fire[lane]) begin
            automatic int unsigned midx;
            midx = int'(load_mem_sel_idx[lane]);
            state[midx] <= ST_MEM_RESP;
            if (load_partial_mask[midx] != 4'b0000) begin
              partial_fwd_en[midx]   <= 1'b1;
              partial_fwd_word[midx] <= load_partial_word[midx];
              partial_fwd_mask[midx] <= load_partial_mask[midx];
            end else begin
              partial_fwd_en[midx]   <= 1'b0;
              partial_fwd_word[midx] <= '0;
              partial_fwd_mask[midx] <= 4'b0000;
            end
          end

          if (load_fwd_fire[lane]) begin
            load_data[load_fwd_sel_idx[lane]] <= load_fwd_value[load_fwd_sel_idx[lane]];
            state[load_fwd_sel_idx[lane]]     <= ST_CDB_WAIT;
          end
        end

        for (int lane = 0; lane < NUM_LSQ; lane++) begin
          if (load_cdb_fire[lane]) begin
            out_cdb[lane].valid <= 1'b1;
            out_cdb[lane].tag   <= tag_q[cdb_sel_idx[lane]];
            out_cdb[lane].data  <= load_data[cdb_sel_idx[lane]];
            busy[cdb_sel_idx[lane]] <= 1'b0;
            state[cdb_sel_idx[lane]] <= ST_WAIT;
            partial_fwd_en[cdb_sel_idx[lane]]   <= 1'b0;
            partial_fwd_word[cdb_sel_idx[lane]] <= '0;
            partial_fwd_mask[cdb_sel_idx[lane]] <= 4'b0000;
          end
        end

        for (int lane = 0; lane < WIDTH; lane++) begin
          if (dispatch_fire[lane]) begin
            busy[alloc_idx[lane]]       <= 1'b1;
            state[alloc_idx[lane]]      <= ST_WAIT;
            uop_q[alloc_idx[lane]]      <= dispatch_uop[lane];
            tag_q[alloc_idx[lane]]      <= dispatch_tag[lane];
            age_q[alloc_idx[lane]]      <= alloc_age[lane];
            base_ready[alloc_idx[lane]] <= operand_ready_now(dispatch_base[lane].ready, dispatch_base[lane].tag);
            data_ready[alloc_idx[lane]] <= dispatch_uop[lane].is_load ? 1'b1 :
                                    operand_ready_now(dispatch_store_data[lane].ready, dispatch_store_data[lane].tag);
            base_tag[alloc_idx[lane]]   <= dispatch_base[lane].tag;
            data_tag[alloc_idx[lane]]   <= dispatch_store_data[lane].tag;
            base_value[alloc_idx[lane]] <= operand_value_now(dispatch_base[lane].ready,
                                                             dispatch_base[lane].value,
                                                             dispatch_base[lane].tag);
            data_value[alloc_idx[lane]] <= operand_value_now(dispatch_store_data[lane].ready,
                                                             dispatch_store_data[lane].value,
                                                             dispatch_store_data[lane].tag);
            load_data[alloc_idx[lane]]  <= '0;
            partial_fwd_en[alloc_idx[lane]]   <= 1'b0;
            partial_fwd_word[alloc_idx[lane]] <= '0;
            partial_fwd_mask[alloc_idx[lane]] <= 4'b0000;
          end
        end
        begin
          logic [AGE_W-1:0] dispatch_count;
          dispatch_count = '0;
          for (int lane = 0; lane < WIDTH; lane++) begin
            if (dispatch_fire[lane]) dispatch_count++;
          end
          if (dispatch_count != '0) begin
            next_age <= next_age + dispatch_count;
          end
        end
      end

      // SB drain / response handling continues through flush.
      for (int lane = 0; lane < WIDTH; lane++) begin
        if (sb_drain_fire[lane]) begin
          n_issued[sb_drain_idx[lane]] = 1'b1;
        end
        if (mem_resp_valid[lane]) begin
          automatic int unsigned rid;
          rid = int'(mem_resp_id[lane]);
          if (rid >= LSQ_DEPTH) begin
            automatic int unsigned sb_i;
            sb_i = rid - LSQ_DEPTH;
            if (sb_i < STORE_BUF_DEPTH) begin
              n_valid[sb_i]  = 1'b0;
              n_issued[sb_i] = 1'b0;
            end
          end else if (!flush && busy[rid] && (state[rid] == ST_MEM_RESP) && uop_q[rid].is_load) begin
            automatic data_t merged;
            merged = mem_resp_rdata[lane];
            if (partial_fwd_en[rid]) begin
              if (partial_fwd_mask[rid][0]) merged[7:0]   = partial_fwd_word[rid][7:0];
              if (partial_fwd_mask[rid][1]) merged[15:8]  = partial_fwd_word[rid][15:8];
              if (partial_fwd_mask[rid][2]) merged[23:16] = partial_fwd_word[rid][23:16];
              if (partial_fwd_mask[rid][3]) merged[31:24] = partial_fwd_word[rid][31:24];
            end
            load_data[rid] <= load_extend(merged,
                                          uop_q[rid].mem_size,
                                          uop_q[rid].mem_unsigned,
                                          addr_low(base_value[rid] + uop_q[rid].imm));
            state[rid] <= ST_CDB_WAIT;
            partial_fwd_en[rid]   <= 1'b0;
            partial_fwd_word[rid] <= '0;
            partial_fwd_mask[rid] <= 4'b0000;
          end
        end
      end

      for (int k = 0; k < STORE_BUF_DEPTH; k++) begin
        if ((n_count != '0) && !n_valid[n_head]) begin
          n_head  = STORE_BUF_W'(n_head + STORE_BUF_W'(1));
          n_count = SB_CNT_W'(n_count - SB_CNT_W'(1));
        end
      end

      sb_head  <= n_head;
      sb_tail  <= n_tail;
      sb_count <= n_count;
      for (int i = 0; i < STORE_BUF_DEPTH; i++) begin
        sb_valid[i]  <= n_valid[i];
        sb_issued[i] <= n_issued[i];
      end
    end
  end

endmodule
