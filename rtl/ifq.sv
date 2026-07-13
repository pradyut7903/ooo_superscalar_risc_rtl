`timescale 1ns/1ps
// ============================================================================
// ifq.sv -- Instruction Fetch Queue.
//
// Fetch can push up to WIDTH instructions per cycle, and decode can pop up to
// WIDTH queued instructions per cycle.  Both sides operate on program-order
// prefixes.
//
// Queue order is program order.  out_valid is a prefix: if out_valid[i] is 0,
// all younger lanes are also 0.
// ============================================================================
module ifq
  import pkg_cpu::*;
  #(parameter int DEPTH = IFQ_DEPTH)
(
  input  logic clk,
  input  logic rst,
  input  logic flush,

  // bundle fetch push, prefix count in 0..WIDTH
  input  logic [$clog2(WIDTH+1)-1:0] push_count,
  output logic                       push_ready,
  input  pc_bundle_t                 push_pc,
  input  instr_bundle_t              push_instr,
  input  valid_bundle_t              push_pred_taken,
  input  pc_bundle_t                 push_pred_target,

  // bundle pop, prefix count in 0..WIDTH
  input  logic [$clog2(WIDTH+1)-1:0] pop_count,
  output valid_bundle_t              out_valid,
  output pc_bundle_t                 out_pc,
  output instr_bundle_t              out_instr,
  output valid_bundle_t              out_pred_taken,
  output pc_bundle_t                 out_pred_target,

  output logic full,
  output logic empty
);

  localparam int PTR_W = (DEPTH <= 1) ? 1 : $clog2(DEPTH);
  localparam int CNT_W = $clog2(DEPTH + 1);

  typedef logic [PTR_W-1:0] ptr_t;
  typedef logic [CNT_W-1:0] cnt_t;

  pc_t    pc_q          [DEPTH];
  instr_t instr_q       [DEPTH];
  logic   pred_taken_q  [DEPTH];
  pc_t    pred_target_q [DEPTH];

  ptr_t head;
  ptr_t tail;
  cnt_t count;

  cnt_t push_req;
  cnt_t push_fire_count;
  cnt_t pop_req;
  cnt_t pop_fire_count;

  function automatic ptr_t add_ptr(input ptr_t base, input int unsigned offset);
    int unsigned sum;
    begin
      sum = int'(base) + offset;
      while (sum >= DEPTH) sum -= DEPTH;
      add_ptr = ptr_t'(sum);
    end
  endfunction

  always_comb begin
    for (int i = 0; i < WIDTH; i++) begin
      ptr_t idx;

      idx = add_ptr(head, i);
      out_valid[i]       = (count > cnt_t'(i));
      out_pc[i]          = pc_q[idx];
      out_instr[i]       = instr_q[idx];
      out_pred_taken[i]  = pred_taken_q[idx];
      out_pred_target[i] = pred_target_q[idx];
    end
  end

  assign full  = (count == DEPTH);
  assign empty = (count == '0);

  always_comb begin
    push_req = cnt_t'(push_count);
    pop_req = cnt_t'(pop_count);
    if (pop_req > count) pop_fire_count = count;
    else                 pop_fire_count = pop_req;
  end

  assign push_ready = ((cnt_t'(DEPTH) - count + pop_fire_count) >= push_req);
  assign push_fire_count = push_ready ? push_req : '0;

  always_ff @(posedge clk) begin
    if (rst || flush) begin
      head  <= '0;
      tail  <= '0;
      count <= '0;
      for (int i = 0; i < DEPTH; i++) begin
        pc_q[i]          <= '0;
        instr_q[i]       <= INSTR_INVALID;
        pred_taken_q[i]  <= 1'b0;
        pred_target_q[i] <= '0;
      end
    end else begin
      for (int i = 0; i < WIDTH; i++) begin
        if (push_fire_count > cnt_t'(i)) begin
          ptr_t idx;

          idx = add_ptr(tail, i);
          pc_q[idx]          <= push_pc[i];
          instr_q[idx]       <= push_instr[i];
          pred_taken_q[idx]  <= push_pred_taken[i];
          pred_target_q[idx] <= push_pred_target[i];
        end
      end

      head <= add_ptr(head, pop_fire_count);
      tail <= add_ptr(tail, push_fire_count);

      count <= count + push_fire_count - pop_fire_count;
    end
  end

endmodule
