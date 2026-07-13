`timescale 1ns/1ps
// ============================================================================
// rat_checkpoints.sv -- Per-ROB-tag RAT map snapshots for early branch recovery.
//
// Instantiated inside rat.sv. Saves are presented already post-rename for each
// control lane; restores are combinational reads of stored maps.
//
// While a checkpoint is live, commit clears matching tags inside every valid
// snapshot so a later restore cannot revive a ROB tag that already retired.
// ============================================================================
module rat_checkpoints
  import pkg_cpu::*;
(
  input  logic clk,
  input  logic rst,

  input  valid_bundle_t save_en,
  input  rob_tag_t      save_tag [WIDTH],
  input  rat_entry_t    save_map [WIDTH][NUM_REGS],

  input  valid_bundle_t cm_we,
  input  reg_idx_t      cm_addr [WIDTH],
  input  rob_tag_t      cm_tag  [WIDTH],

  input  rob_tag_t      restore_tag,
  output rat_entry_t    restore_map [NUM_REGS],
  output logic          restore_hit,

  input  logic [ROB_DEPTH-1:0] invalidate
);

  rat_entry_t ckpt_map [ROB_DEPTH][NUM_REGS];
  logic       ckpt_valid [ROB_DEPTH];

  always_comb begin
    restore_hit = ckpt_valid[restore_tag];
    for (int r = 0; r < NUM_REGS; r++)
      restore_map[r] = ckpt_map[restore_tag][r];
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      for (int t = 0; t < ROB_DEPTH; t++) begin
        ckpt_valid[t] <= 1'b0;
        for (int r = 0; r < NUM_REGS; r++)
          ckpt_map[t][r] <= '{valid: 1'b0, tag: '0};
      end
    end else begin
      for (int t = 0; t < ROB_DEPTH; t++)
        if (invalidate[t]) ckpt_valid[t] <= 1'b0;

      // Keep live checkpoints coherent with architectural commits.
      for (int t = 0; t < ROB_DEPTH; t++) begin
        if (ckpt_valid[t] && !invalidate[t]) begin
          for (int lane = 0; lane < WIDTH; lane++) begin
            if (cm_we[lane] && (cm_addr[lane] != '0) &&
                ckpt_map[t][cm_addr[lane]].valid &&
                (ckpt_map[t][cm_addr[lane]].tag == cm_tag[lane])) begin
              ckpt_map[t][cm_addr[lane]] <= '{valid: 1'b0, tag: '0};
            end
          end
        end
      end

      for (int lane = 0; lane < WIDTH; lane++) begin
        if (save_en[lane]) begin
          ckpt_valid[save_tag[lane]] <= 1'b1;
          for (int r = 0; r < NUM_REGS; r++)
            ckpt_map[save_tag[lane]][r] <= save_map[lane][r];
        end
      end
    end
  end

endmodule
