`timescale 1ns/1ps
// ============================================================================
// cdb_arbiter.sv -- Common Data Bus arbiter.
//
// Arbitrates a generalized producer array down to the parameterized CDB
// broadcast bus.  The backend packs producer lanes in this order:
//   ALU[NUM_ALU], MUL[NUM_MUL], DIV[NUM_DIV], BR[NUM_BR], LSQ[NUM_LSQ]
// ============================================================================
module cdb_arbiter
  import pkg_cpu::*;
(
  input  logic clk,
  input  logic rst,
  input  logic flush,

  input  cdb_t producer_cdb [NUM_CDB_PRODUCERS],
  output logic producer_ready [NUM_CDB_PRODUCERS],

  output cdb_bus_t out_cdb,
  output logic overflow
);

  localparam int LANE_W = (NUM_CDB_PRODUCERS <= 1) ? 1 : $clog2(NUM_CDB_PRODUCERS);

  typedef logic [LANE_W-1:0] lane_idx_t;

  cdb_t      pending_cdb   [NUM_CDB_PRODUCERS];
  logic      pending_valid [NUM_CDB_PRODUCERS];
  cdb_t      blocked_cdb   [NUM_CDB_PRODUCERS];
  logic      blocked_valid [NUM_CDB_PRODUCERS];
  lane_idx_t rr_ptr;

  cdb_t lane_cdb [NUM_CDB_PRODUCERS];
  logic request  [NUM_CDB_PRODUCERS];
  logic grant    [NUM_CDB_PRODUCERS];
  logic ready    [NUM_CDB_PRODUCERS];

  lane_idx_t sel_idx   [CDB_WIDTH];
  logic      sel_valid [CDB_WIDTH];
  logic      selected  [NUM_CDB_PRODUCERS];

  function automatic lane_idx_t next_lane(input lane_idx_t lane);
    int unsigned tmp;
    begin
      tmp = int'(lane) + 1;
      if (tmp >= NUM_CDB_PRODUCERS) tmp = 0;
      next_lane = lane_idx_t'(tmp[LANE_W-1:0]);
    end
  endfunction

  always_comb begin
    for (int i = 0; i < NUM_CDB_PRODUCERS; i++) begin
      lane_cdb[i] = pending_valid[i] ? pending_cdb[i] : producer_cdb[i];
      request[i]  = pending_valid[i] || producer_cdb[i].valid;
    end
  end

  always_comb begin
    for (int i = 0; i < NUM_CDB_PRODUCERS; i++) selected[i] = 1'b0;

    for (int slot = 0; slot < CDB_WIDTH; slot++) begin
      sel_valid[slot] = 1'b0;
      sel_idx[slot]   = rr_ptr;

      for (int offset = 0; offset < NUM_CDB_PRODUCERS; offset++) begin
        int idx;

        idx = (int'(rr_ptr) + offset) % NUM_CDB_PRODUCERS;
        if (request[idx] && !selected[idx] && !sel_valid[slot]) begin
          sel_valid[slot] = 1'b1;
          sel_idx[slot]   = lane_idx_t'(idx[LANE_W-1:0]);
          selected[idx]   = 1'b1;
        end
      end
    end
  end

  always_comb begin
    for (int i = 0; i < NUM_CDB_PRODUCERS; i++) begin
      grant[i] = 1'b0;
      ready[i] = !pending_valid[i];
    end

    for (int slot = 0; slot < CDB_WIDTH; slot++) begin
      if (sel_valid[slot]) begin
        grant[sel_idx[slot]] = 1'b1;
        ready[sel_idx[slot]] = 1'b1;
      end
    end

    for (int i = 0; i < NUM_CDB_PRODUCERS; i++) begin
      producer_ready[i] = ready[i];
    end
  end

  always_comb begin
    for (int slot = 0; slot < CDB_WIDTH; slot++) begin
      out_cdb[slot] = sel_valid[slot] ? lane_cdb[sel_idx[slot]] : '0;
    end
  end

  always_ff @(posedge clk) begin
    if (rst || flush) begin
      rr_ptr   <= '0;
      overflow <= 1'b0;
      for (int i = 0; i < NUM_CDB_PRODUCERS; i++) begin
        pending_valid[i] <= 1'b0;
        pending_cdb[i]   <= '0;
        blocked_valid[i] <= 1'b0;
        blocked_cdb[i]   <= '0;
      end
    end else begin
      for (int slot = 0; slot < CDB_WIDTH; slot++) begin
        if (sel_valid[slot]) rr_ptr <= next_lane(sel_idx[slot]);
      end

      for (int i = 0; i < NUM_CDB_PRODUCERS; i++) begin
        if (producer_cdb[i].valid && !ready[i]) begin
          if (blocked_valid[i] && (producer_cdb[i] != blocked_cdb[i])) overflow <= 1'b1;
          blocked_valid[i] <= 1'b1;
          blocked_cdb[i]   <= producer_cdb[i];
        end else begin
          blocked_valid[i] <= 1'b0;
          blocked_cdb[i]   <= '0;
        end

        if (pending_valid[i]) begin
          if (grant[i]) begin
            if (producer_cdb[i].valid) begin
              pending_valid[i] <= 1'b1;
              pending_cdb[i]   <= producer_cdb[i];
            end else begin
              pending_valid[i] <= 1'b0;
              pending_cdb[i]   <= '0;
            end
          end
        end else begin
          if (producer_cdb[i].valid && !grant[i]) begin
            pending_valid[i] <= 1'b1;
            pending_cdb[i]   <= producer_cdb[i];
          end
        end
      end
    end
  end

endmodule
