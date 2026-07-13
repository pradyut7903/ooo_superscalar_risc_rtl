`timescale 1ns/1ps
// ============================================================================
// rs.sv -- Reservation Station.
//
// Accepts up to WIDTH non-memory uops per cycle using a prefix-ready contract.
// Issues up to NUM_ALU ALU uops, NUM_MUL MUL uops, NUM_DIV DIV uops, and one
// branch/jump uop per cycle.  Within each FU class, lower RS index wins first.
// ============================================================================
module rs
  import pkg_cpu::*;
(
  input  logic clk,
  input  logic rst,
  input  logic flush,
  input  logic squash_en,
  input  rob_tag_t squash_tag,
  input  rob_tag_t rob_head,

  // dispatch / allocate.  Ready is prefix-based: once a valid lane cannot be
  // accepted, no younger valid lane is accepted.
  input  valid_bundle_t dispatch_valid,
  output valid_bundle_t dispatch_ready,
  input  uop_bundle_t   dispatch_uop,
  input  rob_tag_t      dispatch_tag [WIDTH],
  input  operand_t      dispatch_src1 [WIDTH],
  input  operand_t      dispatch_src2 [WIDTH],

  // CDB wakeup
  input  cdb_bus_t cdb_in,

  // ALU issue
  output logic     alu_valid [NUM_ALU],
  input  logic     alu_ready [NUM_ALU],
  output uop_t     alu_uop [NUM_ALU],
  output rob_tag_t alu_tag [NUM_ALU],
  output data_t    alu_src1_value [NUM_ALU],
  output data_t    alu_src2_value [NUM_ALU],

  // MUL issue
  output logic     mul_valid [NUM_MUL],
  input  logic     mul_ready [NUM_MUL],
  output uop_t     mul_uop [NUM_MUL],
  output rob_tag_t mul_tag [NUM_MUL],
  output data_t    mul_src1_value [NUM_MUL],
  output data_t    mul_src2_value [NUM_MUL],

  // DIV issue
  output logic     div_valid [NUM_DIV],
  input  logic     div_ready [NUM_DIV],
  output uop_t     div_uop [NUM_DIV],
  output rob_tag_t div_tag [NUM_DIV],
  output data_t    div_src1_value [NUM_DIV],
  output data_t    div_src2_value [NUM_DIV],

  // branch/jump issue
  output logic     br_valid,
  input  logic     br_ready,
  output uop_t     br_uop,
  output rob_tag_t br_tag,
  output data_t    br_src1_value,
  output data_t    br_src2_value,

  output logic full,
  output logic empty
);

  logic     busy       [RS_DEPTH];
  uop_t     uop_q      [RS_DEPTH];
  rob_tag_t tag_q      [RS_DEPTH];
  logic     src1_ready [RS_DEPTH];
  logic     src2_ready [RS_DEPTH];
  rob_tag_t src1_tag   [RS_DEPTH];
  rob_tag_t src2_tag   [RS_DEPTH];
  data_t    src1_value [RS_DEPTH];
  data_t    src2_value [RS_DEPTH];

  logic [RS_DEPTH-1:0] free_mask;
  logic [RS_DEPTH-1:0] alloc_slot_valid;
  logic [RS_DEPTH-1:0] alu_sel_mask;
  logic [RS_DEPTH-1:0] mul_sel_mask;
  logic [RS_DEPTH-1:0] div_sel_mask;
  logic [WIDTH-1:0][RS_W-1:0] alloc_idx;
  logic [NUM_ALU-1:0][RS_W-1:0] alu_idx;
  logic [NUM_MUL-1:0][RS_W-1:0] mul_idx;
  logic [NUM_DIV-1:0][RS_W-1:0] div_idx;
  logic [RS_W-1:0] br_idx;
  logic br_found;

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

  function automatic logic entry_ready(input int idx);
    entry_ready = busy[idx] && src1_ready[idx] && src2_ready[idx];
  endfunction

  always_comb begin
    int accepted;
    int free_count;
    logic prefix_ok;
    logic [RS_DEPTH-1:0] chosen_free;

    free_mask = '0;
    empty = 1'b1;
    free_count = 0;
    for (int i = 0; i < RS_DEPTH; i++) begin
      if (busy[i]) empty = 1'b0;
      if (!busy[i]) begin
        free_mask[i] = 1'b1;
        free_count++;
      end
    end

    full = (free_count == 0);
    dispatch_ready = '0;
    alloc_idx = '0;
    alloc_slot_valid = '0;
    chosen_free = '0;
    accepted = 0;
    prefix_ok = 1'b1;

    for (int lane = 0; lane < WIDTH; lane++) begin
      if (!dispatch_valid[lane]) begin
        dispatch_ready[lane] = prefix_ok;
      end else if (prefix_ok && (accepted < free_count)) begin
        logic found_slot;
        dispatch_ready[lane] = 1'b1;
        found_slot = 1'b0;
        for (int s = 0; s < RS_DEPTH; s++) begin
          if (!found_slot && !busy[s] && !chosen_free[s]) begin
            alloc_idx[lane] = RS_W'(s);
            found_slot = 1'b1;
          end
        end
        alloc_slot_valid[alloc_idx[lane]] = 1'b1;
        chosen_free[alloc_idx[lane]] = 1'b1;
        accepted++;
      end else begin
        dispatch_ready[lane] = 1'b0;
        prefix_ok = 1'b0;
      end
    end

    alu_sel_mask = '0;
    for (int lane = 0; lane < NUM_ALU; lane++) begin
      alu_valid[lane] = 1'b0;
      alu_idx[lane] = '0;
      alu_uop[lane] = '0;
      alu_tag[lane] = '0;
      alu_src1_value[lane] = '0;
      alu_src2_value[lane] = '0;
      for (int i = 0; i < RS_DEPTH; i++) begin
        if (!alu_valid[lane] && !alu_sel_mask[i] && entry_ready(i) && (uop_q[i].fu == FU_ALU)) begin
          alu_valid[lane] = 1'b1;
          alu_idx[lane] = RS_W'(i);
          alu_sel_mask[i] = 1'b1;
        end
      end
      if (alu_valid[lane]) begin
        alu_uop[lane] = uop_q[alu_idx[lane]];
        alu_tag[lane] = tag_q[alu_idx[lane]];
        alu_src1_value[lane] = src1_value[alu_idx[lane]];
        alu_src2_value[lane] = src2_value[alu_idx[lane]];
      end
    end

    mul_sel_mask = '0;
    for (int lane = 0; lane < NUM_MUL; lane++) begin
      mul_valid[lane] = 1'b0;
      mul_idx[lane] = '0;
      mul_uop[lane] = '0;
      mul_tag[lane] = '0;
      mul_src1_value[lane] = '0;
      mul_src2_value[lane] = '0;
      for (int i = 0; i < RS_DEPTH; i++) begin
        if (!mul_valid[lane] && !mul_sel_mask[i] && entry_ready(i) && (uop_q[i].fu == FU_MUL)) begin
          mul_valid[lane] = 1'b1;
          mul_idx[lane] = RS_W'(i);
          mul_sel_mask[i] = 1'b1;
        end
      end
      if (mul_valid[lane]) begin
        mul_uop[lane] = uop_q[mul_idx[lane]];
        mul_tag[lane] = tag_q[mul_idx[lane]];
        mul_src1_value[lane] = src1_value[mul_idx[lane]];
        mul_src2_value[lane] = src2_value[mul_idx[lane]];
      end
    end

    div_sel_mask = '0;
    for (int lane = 0; lane < NUM_DIV; lane++) begin
      div_valid[lane] = 1'b0;
      div_idx[lane] = '0;
      div_uop[lane] = '0;
      div_tag[lane] = '0;
      div_src1_value[lane] = '0;
      div_src2_value[lane] = '0;
      for (int i = 0; i < RS_DEPTH; i++) begin
        if (!div_valid[lane] && !div_sel_mask[i] && entry_ready(i) && (uop_q[i].fu == FU_DIV)) begin
          div_valid[lane] = 1'b1;
          div_idx[lane] = RS_W'(i);
          div_sel_mask[i] = 1'b1;
        end
      end
      if (div_valid[lane]) begin
        div_uop[lane] = uop_q[div_idx[lane]];
        div_tag[lane] = tag_q[div_idx[lane]];
        div_src1_value[lane] = src1_value[div_idx[lane]];
        div_src2_value[lane] = src2_value[div_idx[lane]];
      end
    end

    br_valid = 1'b0;
    br_idx = '0;
    br_uop = '0;
    br_tag = '0;
    br_src1_value = '0;
    br_src2_value = '0;
    br_found = 1'b0;
    for (int i = 0; i < RS_DEPTH; i++) begin
      if (!br_found && entry_ready(i) && (uop_q[i].fu == FU_BR)) begin
        br_found = 1'b1;
        br_valid = 1'b1;
        br_idx = RS_W'(i);
      end
    end
    if (br_valid) begin
      br_uop = uop_q[br_idx];
      br_tag = tag_q[br_idx];
      br_src1_value = src1_value[br_idx];
      br_src2_value = src2_value[br_idx];
    end
  end

  always_ff @(posedge clk) begin
    if (rst || flush) begin
      for (int i = 0; i < RS_DEPTH; i++) begin
        busy[i]       <= 1'b0;
        uop_q[i]      <= '0;
        tag_q[i]      <= '0;
        src1_ready[i] <= 1'b0;
        src2_ready[i] <= 1'b0;
        src1_tag[i]   <= '0;
        src2_tag[i]   <= '0;
        src1_value[i] <= '0;
        src2_value[i] <= '0;
      end
    end else begin
      for (int i = 0; i < RS_DEPTH; i++) begin
        for (int lane = 0; lane < CDB_WIDTH; lane++) begin
          if (cdb_in[lane].valid && busy[i] && !src1_ready[i] &&
              (src1_tag[i] == cdb_in[lane].tag)) begin
            src1_ready[i] <= 1'b1;
            src1_value[i] <= cdb_in[lane].data;
          end
          if (cdb_in[lane].valid && busy[i] && !src2_ready[i] &&
              (src2_tag[i] == cdb_in[lane].tag)) begin
            src2_ready[i] <= 1'b1;
            src2_value[i] <= cdb_in[lane].data;
          end
        end
      end

      for (int lane = 0; lane < NUM_ALU; lane++) begin
        if (alu_valid[lane] && alu_ready[lane]) busy[alu_idx[lane]] <= 1'b0;
      end
      for (int lane = 0; lane < NUM_MUL; lane++) begin
        if (mul_valid[lane] && mul_ready[lane]) busy[mul_idx[lane]] <= 1'b0;
      end
      for (int lane = 0; lane < NUM_DIV; lane++) begin
        if (div_valid[lane] && div_ready[lane]) busy[div_idx[lane]] <= 1'b0;
      end
      if (br_valid && br_ready) busy[br_idx] <= 1'b0;

      if (squash_en) begin
        for (int i = 0; i < RS_DEPTH; i++) begin
          if (busy[i] && rob_is_younger(rob_head, tag_q[i], squash_tag))
            busy[i] <= 1'b0;
        end
      end

      for (int lane = 0; lane < WIDTH; lane++) begin
        if (dispatch_valid[lane] && dispatch_ready[lane] && !squash_en) begin
          busy[alloc_idx[lane]]       <= 1'b1;
          uop_q[alloc_idx[lane]]      <= dispatch_uop[lane];
          tag_q[alloc_idx[lane]]      <= dispatch_tag[lane];
          src1_ready[alloc_idx[lane]] <= operand_ready_now(dispatch_src1[lane].ready, dispatch_src1[lane].tag);
          src2_ready[alloc_idx[lane]] <= operand_ready_now(dispatch_src2[lane].ready, dispatch_src2[lane].tag);
          src1_tag[alloc_idx[lane]]   <= dispatch_src1[lane].tag;
          src2_tag[alloc_idx[lane]]   <= dispatch_src2[lane].tag;
          src1_value[alloc_idx[lane]] <= operand_value_now(dispatch_src1[lane].ready,
                                                           dispatch_src1[lane].value,
                                                           dispatch_src1[lane].tag);
          src2_value[alloc_idx[lane]] <= operand_value_now(dispatch_src2[lane].ready,
                                                           dispatch_src2[lane].value,
                                                           dispatch_src2[lane].tag);
        end
      end
    end
  end

endmodule
