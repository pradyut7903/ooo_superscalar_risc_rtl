`timescale 1ns/1ps
// ============================================================================
// rat.sv -- Register Alias Table (the rename map; no physical register file).
//
// Update priority:
//   1. rst
//   2. checkpoint restore (early branch recovery)
//   3. commit clears (tag match)
//   4. rename writes (younger lanes win)
//
// Control checkpoints are saved in the same cycle as rename using a shadow map
// so each control lane snapshots the map after that lane's rename write.
// ============================================================================
module rat
  import pkg_cpu::*;
(
  input  logic clk,
  input  logic rst,

  input  reg_idx_t   raddr1 [WIDTH],
  output rat_entry_t rdata1 [WIDTH],
  input  reg_idx_t   raddr2 [WIDTH],
  output rat_entry_t rdata2 [WIDTH],

  input  valid_bundle_t ren_we,
  input  reg_idx_t      ren_addr [WIDTH],
  input  rob_tag_t      ren_tag  [WIDTH],

  input  valid_bundle_t cm_we,
  input  reg_idx_t      cm_addr [WIDTH],
  input  rob_tag_t      cm_tag  [WIDTH],

  input  valid_bundle_t ckpt_save_en,
  input  rob_tag_t      ckpt_save_tag [WIDTH],

  input  logic          ckpt_restore_en,
  input  rob_tag_t      ckpt_restore_tag,

  input  logic [ROB_DEPTH-1:0] ckpt_invalidate
);

  rat_entry_t map [NUM_REGS];

  // Shadow next-map for same-cycle checkpoint save (combinational).
  rat_entry_t next_map [NUM_REGS];
  valid_bundle_t save_en_c;
  rob_tag_t      save_tag_c [WIDTH];
  rat_entry_t    save_map_c [WIDTH][NUM_REGS];
  rat_entry_t    restore_map [NUM_REGS];
  logic          restore_hit;

  rat_checkpoints u_ckpt (
    .clk(clk), .rst(rst),
    .save_en(save_en_c), .save_tag(save_tag_c), .save_map(save_map_c),
    .cm_we(cm_we), .cm_addr(cm_addr), .cm_tag(cm_tag),
    .restore_tag(ckpt_restore_tag),
    .restore_map(restore_map), .restore_hit(restore_hit),
    .invalidate(ckpt_invalidate)
  );

  always_comb begin
    for (int lane = 0; lane < WIDTH; lane++) begin
      rdata1[lane] = (raddr1[lane] == '0) ? '{valid: 1'b0, tag: '0} : map[raddr1[lane]];
      rdata2[lane] = (raddr2[lane] == '0) ? '{valid: 1'b0, tag: '0} : map[raddr2[lane]];
    end

    for (int i = 0; i < NUM_REGS; i++)
      next_map[i] = map[i];

    for (int lane = 0; lane < WIDTH; lane++) begin
      if (cm_we[lane] && (cm_addr[lane] != '0) &&
          next_map[cm_addr[lane]].valid &&
          (next_map[cm_addr[lane]].tag == cm_tag[lane])) begin
        next_map[cm_addr[lane]] = '{valid: 1'b0, tag: '0};
      end
    end

    save_en_c = '0;
    for (int lane = 0; lane < WIDTH; lane++) begin
      save_tag_c[lane] = ckpt_save_tag[lane];
      for (int r = 0; r < NUM_REGS; r++)
        save_map_c[lane][r] = '{valid: 1'b0, tag: '0};

      if (ren_we[lane] && (ren_addr[lane] != '0))
        next_map[ren_addr[lane]] = '{valid: 1'b1, tag: ren_tag[lane]};
      next_map[0] = '{valid: 1'b0, tag: '0};

      if (ckpt_save_en[lane] && !ckpt_restore_en) begin
        save_en_c[lane] = 1'b1;
        for (int r = 0; r < NUM_REGS; r++)
          save_map_c[lane][r] = next_map[r];
      end
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      for (int i = 0; i < NUM_REGS; i++)
        map[i] <= '{valid: 1'b0, tag: '0};
    end else if (ckpt_restore_en) begin
      // Apply checkpoint when present. Always scrub aliases to ROB tags freed
      // this cycle (squash or commit): restore reads checkpoints before the
      // same-edge commit/invalidate update, so a just-retired producer can
      // otherwise be revived.
      for (int i = 0; i < NUM_REGS; i++) begin
        automatic rat_entry_t e;
        e = restore_hit ? restore_map[i] : next_map[i];
        if ((i == 0) || (e.valid && ckpt_invalidate[e.tag]))
          map[i] <= '{valid: 1'b0, tag: '0};
        else
          map[i] <= e;
      end
    end else begin
      for (int i = 0; i < NUM_REGS; i++)
        map[i] <= next_map[i];
    end
  end

endmodule
