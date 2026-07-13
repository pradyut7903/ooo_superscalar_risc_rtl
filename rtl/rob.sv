`timescale 1ns/1ps
// ============================================================================
// rob.sv -- Reorder Buffer with WIDTH-lane allocate and commit.
//
// Selective squash (early branch recovery): free entries younger than
// squash_tag and set tail to squash_tag+1. Older entries and the branch
// itself remain. Full flush still wipes the ROB (rst-style only).
// ============================================================================
module rob
  import pkg_cpu::*;
(
  input  logic clk,
  input  logic rst,
  input  logic flush,

  input  logic          squash_en,
  input  rob_tag_t      squash_tag,

  input  valid_bundle_t alloc_en,
  input  logic          alloc_rd_used [WIDTH],
  input  reg_idx_t      alloc_dest [WIDTH],
  input  logic          alloc_is_control [WIDTH],
  input  logic          alloc_is_store [WIDTH],
  input  pc_t           alloc_pc [WIDTH],
  output rob_tag_t      alloc_tag [WIDTH],
  output logic          full,
  output logic [$clog2(ROB_DEPTH+1)-1:0] free_count,

  input  cdb_bus_t wb_cdb,

  input  valid_bundle_t complete_en,
  input  rob_tag_t      complete_tag [WIDTH],
  input  logic     complete2_en,
  input  rob_tag_t complete2_tag,

  input  logic     br_resolve_en,
  input  rob_tag_t br_resolve_tag,
  input  logic     br_mispredict,
  input  logic     br_taken,
  input  pc_t      br_target,
  input  pc_t      br_redirect_pc,

  input  rob_tag_t rd_tag1 [WIDTH],
  output logic     rd_done1 [WIDTH],
  output data_t    rd_val1 [WIDTH],
  input  rob_tag_t rd_tag2 [WIDTH],
  output logic     rd_done2 [WIDTH],
  output data_t    rd_val2 [WIDTH],

  output valid_bundle_t commit_valid,
  output rob_tag_t      commit_tag [WIDTH],
  output logic          commit_rd_used [WIDTH],
  output reg_idx_t      commit_dest [WIDTH],
  output data_t         commit_value [WIDTH],
  output logic          commit_is_control [WIDTH],
  output logic          commit_mispredict [WIDTH],
  output pc_t           commit_pc [WIDTH],
  output logic          commit_taken [WIDTH],
  output pc_t           commit_target [WIDTH],
  output pc_t           commit_redirect_pc [WIDTH],
  input  valid_bundle_t commit_do,
  output valid_bundle_t commit_store_valid,
  output rob_tag_t      commit_store_tag [WIDTH],
  output logic          empty,

  output rob_tag_t      rob_head,
  output logic [ROB_DEPTH-1:0] slot_freed
);

  localparam int CNT_W = $clog2(ROB_DEPTH + 1);

  logic     rob_done        [ROB_DEPTH];
  logic     rob_rd_used     [ROB_DEPTH];
  logic     rob_is_control  [ROB_DEPTH];
  logic     rob_is_store    [ROB_DEPTH];
  logic     rob_mispredict  [ROB_DEPTH];
  reg_idx_t rob_dest        [ROB_DEPTH];
  data_t    rob_value       [ROB_DEPTH];
  pc_t      rob_pc          [ROB_DEPTH];
  logic     rob_taken       [ROB_DEPTH];
  pc_t      rob_target      [ROB_DEPTH];
  pc_t      rob_redirect_pc [ROB_DEPTH];

  rob_tag_t head, tail;
  logic [CNT_W-1:0] count;

  logic [CNT_W-1:0] alloc_count;
  logic [CNT_W-1:0] commit_count;

  function automatic rob_tag_t wrap_add(input rob_tag_t base, input int unsigned off);
    int unsigned tmp;
    begin
      tmp = int'(base) + off;
      if (tmp >= ROB_DEPTH) tmp = tmp - ROB_DEPTH;
      wrap_add = rob_tag_t'(tmp[ROB_W-1:0]);
    end
  endfunction

  function automatic logic in_flight(input rob_tag_t tag);
    return (count != 0) && (rob_age_from_head(head, tag) < count);
  endfunction

  assign full       = (count == ROB_DEPTH);
  assign empty      = (count == '0);
  assign free_count = ROB_DEPTH[CNT_W-1:0] - count;
  assign rob_head   = head;

  always_comb begin
    for (int lane = 0; lane < WIDTH; lane++) begin
      rd_done1[lane] = rob_done[rd_tag1[lane]];
      rd_val1[lane]  = rob_value[rd_tag1[lane]];
      rd_done2[lane] = rob_done[rd_tag2[lane]];
      rd_val2[lane]  = rob_value[rd_tag2[lane]];
    end
  end

  always_comb begin
    int unsigned prior_allocs;
    int unsigned idx;
    logic stop_commit;
    logic stop_store;

    prior_allocs = 0;
    for (int lane = 0; lane < WIDTH; lane++) begin
      alloc_tag[lane] = wrap_add(tail, prior_allocs);
      if (alloc_en[lane]) prior_allocs++;
    end

    alloc_count = prior_allocs[CNT_W-1:0];

    stop_commit = 1'b0;
    for (int lane = 0; lane < WIDTH; lane++) begin
      idx = int'(head) + lane;
      if (idx >= ROB_DEPTH) idx = idx - ROB_DEPTH;

      commit_valid[lane]       = 1'b0;
      commit_tag[lane]         = rob_tag_t'(idx[ROB_W-1:0]);
      commit_rd_used[lane]     = 1'b0;
      commit_dest[lane]        = '0;
      commit_value[lane]       = '0;
      commit_is_control[lane]  = 1'b0;
      commit_mispredict[lane]  = 1'b0;
      commit_pc[lane]          = '0;
      commit_taken[lane]       = 1'b0;
      commit_target[lane]      = '0;
      commit_redirect_pc[lane] = '0;

      if (!stop_commit && (lane < count) && rob_done[idx]) begin
        commit_valid[lane]       = 1'b1;
        commit_rd_used[lane]     = rob_rd_used[idx];
        commit_dest[lane]        = rob_dest[idx];
        commit_value[lane]       = rob_value[idx];
        commit_is_control[lane]  = rob_is_control[idx];
        commit_mispredict[lane]  = rob_mispredict[idx];
        commit_pc[lane]          = rob_pc[idx];
        commit_taken[lane]       = rob_taken[idx];
        commit_target[lane]      = rob_target[idx];
        commit_redirect_pc[lane] = rob_redirect_pc[idx];

        if (rob_is_control[idx] && rob_mispredict[idx]) begin
          stop_commit = 1'b1;
        end
      end else begin
        stop_commit = 1'b1;
      end
    end

    stop_store = 1'b0;
    for (int lane = 0; lane < WIDTH; lane++) begin
      idx = int'(head) + lane;
      if (idx >= ROB_DEPTH) idx = idx - ROB_DEPTH;

      commit_store_valid[lane] = 1'b0;
      commit_store_tag[lane]   = rob_tag_t'(idx[ROB_W-1:0]);

      if (!stop_store && (lane < count)) begin
        if (rob_done[idx]) begin
          if (rob_is_control[idx] && rob_mispredict[idx]) begin
            stop_store = 1'b1;
          end
        end else if (rob_is_store[idx]) begin
          commit_store_valid[lane] = 1'b1;
        end else begin
          stop_store = 1'b1;
        end
      end else begin
        stop_store = 1'b1;
      end
    end

    commit_count = '0;
    for (int lane = 0; lane < WIDTH; lane++) begin
      if (commit_do[lane] && commit_valid[lane] && (int'(commit_count) == lane)) begin
        commit_count = commit_count + 1'b1;
      end
    end

    slot_freed = '0;
    for (int lane = 0; lane < WIDTH; lane++) begin
      if (commit_do[lane] && commit_valid[lane])
        slot_freed[commit_tag[lane]] = 1'b1;
    end
    if (squash_en) begin
      for (int i = 0; i < ROB_DEPTH; i++) begin
        if (in_flight(rob_tag_t'(i)) &&
            rob_is_younger(head, rob_tag_t'(i), squash_tag))
          slot_freed[i] = 1'b1;
      end
    end
  end

  always_ff @(posedge clk) begin
    if (rst || flush) begin
      head  <= '0;
      tail  <= '0;
      count <= '0;
      for (int i = 0; i < ROB_DEPTH; i++) begin
        rob_done[i]        <= 1'b0;
        rob_rd_used[i]     <= 1'b0;
        rob_is_control[i]  <= 1'b0;
        rob_is_store[i]    <= 1'b0;
        rob_mispredict[i]  <= 1'b0;
        rob_dest[i]        <= '0;
        rob_value[i]       <= '0;
        rob_pc[i]          <= '0;
        rob_taken[i]       <= 1'b0;
        rob_target[i]      <= '0;
        rob_redirect_pc[i] <= '0;
      end
    end else begin
      automatic int unsigned alloc_idx;
      automatic logic [CNT_W-1:0] surv;

      if (!squash_en) begin
        for (int lane = 0; lane < WIDTH; lane++) begin
          if (alloc_en[lane]) begin
            alloc_idx = int'(alloc_tag[lane]);
            rob_done[alloc_idx]        <= 1'b0;
            rob_rd_used[alloc_idx]     <= alloc_rd_used[lane];
            rob_is_control[alloc_idx]  <= alloc_is_control[lane];
            rob_is_store[alloc_idx]    <= alloc_is_store[lane];
            rob_mispredict[alloc_idx]  <= 1'b0;
            rob_dest[alloc_idx]        <= alloc_dest[lane];
            rob_value[alloc_idx]       <= '0;
            rob_pc[alloc_idx]          <= alloc_pc[lane];
            rob_taken[alloc_idx]       <= 1'b0;
            rob_target[alloc_idx]      <= '0;
            rob_redirect_pc[alloc_idx] <= '0;
          end
        end
      end

      for (int i = 0; i < CDB_WIDTH; i++) begin
        if (wb_cdb[i].valid) begin
          rob_value[wb_cdb[i].tag] <= wb_cdb[i].data;
          rob_done[wb_cdb[i].tag]  <= 1'b1;
        end
      end

      for (int lane = 0; lane < WIDTH; lane++) begin
        if (complete_en[lane]) begin
          rob_done[complete_tag[lane]] <= 1'b1;
        end
      end

      if (complete2_en) begin
        rob_done[complete2_tag] <= 1'b1;
      end

      if (br_resolve_en) begin
        rob_mispredict[br_resolve_tag]  <= br_mispredict;
        rob_taken[br_resolve_tag]       <= br_taken;
        rob_target[br_resolve_tag]      <= br_target;
        rob_redirect_pc[br_resolve_tag] <= br_redirect_pc;
      end

      if (squash_en) begin
        for (int i = 0; i < ROB_DEPTH; i++) begin
          if (in_flight(rob_tag_t'(i)) &&
              rob_is_younger(head, rob_tag_t'(i), squash_tag)) begin
            rob_done[i]        <= 1'b0;
            rob_rd_used[i]     <= 1'b0;
            rob_is_control[i]  <= 1'b0;
            rob_is_store[i]    <= 1'b0;
            rob_mispredict[i]  <= 1'b0;
            rob_dest[i]        <= '0;
            rob_value[i]       <= '0;
            rob_pc[i]          <= '0;
            rob_taken[i]       <= 1'b0;
            rob_target[i]      <= '0;
            rob_redirect_pc[i] <= '0;
          end
        end
        tail <= wrap_add(squash_tag, 1);
        surv = CNT_W'(rob_age_from_head(head, squash_tag)) + 1'b1;
        if (commit_count >= surv)
          count <= '0;
        else
          count <= surv - commit_count;
      end else begin
        if (alloc_count != '0)
          tail <= wrap_add(tail, alloc_count);
        count <= count + alloc_count - commit_count;
      end

      if (commit_count != '0)
        head <= wrap_add(head, commit_count);
    end
  end

endmodule
