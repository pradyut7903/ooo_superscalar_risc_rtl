`timescale 1ns/1ps
// ============================================================================
// branch_predictor.sv -- Bundle gshare branch predictor.
//
// Direction: global-history XOR PC-indexed 2-bit saturating counters.
// Target: direct-mapped BTB indexed by PC.  A branch predicts taken only when
// the direction counter says taken and the BTB tag matches, so every taken
// prediction has a concrete target.
//
// Training is commit-time and bundle-shaped.  The backend supplies committed
// control instructions in program order, and the predictor updates the PHT,
// BTB, and global history oldest-to-youngest.
// ============================================================================
module branch_predictor
  import pkg_cpu::*;
(
  input  logic clk,
  input  logic rst,

  input  pc_bundle_t    fetch_pc,
  output valid_bundle_t pred_taken,
  output pc_bundle_t    pred_target,

  input  valid_bundle_t update_valid,
  input  pc_bundle_t    update_pc,
  input  valid_bundle_t update_taken,
  input  pc_bundle_t    update_target
);

  localparam int GHR_W = $clog2(PHT_SIZE);
  localparam int BTB_IDX_W = $clog2(BTB_SIZE);
  localparam int BTB_TAG_W = PC_W - 2 - BTB_IDX_W;

  logic [GHR_W-1:0] ghr;
  logic [1:0]       pht [PHT_SIZE];
  logic             btb_valid [BTB_SIZE];
  logic [BTB_TAG_W-1:0] btb_tag [BTB_SIZE];
  pc_t              btb_target [BTB_SIZE];

  function automatic logic [GHR_W-1:0] pht_idx(input pc_t pc, input logic [GHR_W-1:0] hist);
    pht_idx = pc[GHR_W+1:2] ^ hist;
  endfunction

  function automatic logic [BTB_IDX_W-1:0] btb_idx(input pc_t pc);
    btb_idx = pc[BTB_IDX_W+1:2];
  endfunction

  function automatic logic [BTB_TAG_W-1:0] btb_pc_tag(input pc_t pc);
    btb_pc_tag = pc[PC_W-1:BTB_IDX_W+2];
  endfunction

  always_comb begin
    for (int i = 0; i < WIDTH; i++) begin
      pred_target[i] = fetch_pc[i] + 32'd4;
      pred_taken[i]  = (pht[pht_idx(fetch_pc[i], ghr)] >= 2'b10) &&
                       btb_valid[btb_idx(fetch_pc[i])] &&
                       (btb_tag[btb_idx(fetch_pc[i])] == btb_pc_tag(fetch_pc[i]));
      if (pred_taken[i]) begin
        pred_target[i] = btb_target[btb_idx(fetch_pc[i])];
      end
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      ghr <= '0;
      for (int i = 0; i < PHT_SIZE; i++) begin
        pht[i] <= 2'b01;
      end
      for (int i = 0; i < BTB_SIZE; i++) begin
        btb_valid[i] <= 1'b0;
        btb_tag[i] <= '0;
        btb_target[i] <= '0;
      end
    end else begin
      logic [GHR_W-1:0] hist;
      hist = ghr;
      for (int lane = 0; lane < WIDTH; lane++) begin
        if (update_valid[lane]) begin
          logic [GHR_W-1:0] pi;
          logic [BTB_IDX_W-1:0] bi;
          pi = pht_idx(update_pc[lane], hist);
          bi = btb_idx(update_pc[lane]);

          if (update_taken[lane]) begin
            if (pht[pi] != 2'b11) pht[pi] <= pht[pi] + 2'b01;
            btb_valid[bi] <= 1'b1;
            btb_tag[bi] <= btb_pc_tag(update_pc[lane]);
            btb_target[bi] <= update_target[lane];
          end else begin
            if (pht[pi] != 2'b00) pht[pi] <= pht[pi] - 2'b01;
          end

          hist = {hist[GHR_W-2:0], update_taken[lane]};
        end
      end
      ghr <= hist;
    end
  end

endmodule
