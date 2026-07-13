`timescale 1ns/1ps
// ============================================================================
// tb_core.sv -- end-to-end smoke test for fetch/decode/backend core.
// ============================================================================
module tb_core;
  import pkg_cpu::*;

  logic clk = 1'b0;
  logic rst = 1'b1;
  logic commit_valid;
  rob_tag_t commit_tag;
  logic commit_rd_used;
  reg_idx_t commit_rd;
  data_t commit_value;
  valid_bundle_t commit_valid_bundle;
  rob_tag_t commit_tag_bundle [WIDTH];
  logic commit_rd_used_bundle [WIDTH];
  reg_idx_t commit_rd_bundle [WIDTH];
  data_t commit_value_bundle [WIDTH];
  logic halted;
  logic cdb_overflow;

  logic cap_rd_used [16];
  reg_idx_t cap_rd  [16];
  data_t cap_value  [16];
  int cap_count = 0;
  int errors = 0;

  core #(.IMEM_IMAGE("core_smoke.imem.hex")) dut (
    .clk(clk), .rst(rst),
    .commit_valid(commit_valid), .commit_tag(commit_tag),
    .commit_rd_used(commit_rd_used), .commit_rd(commit_rd), .commit_value(commit_value),
    .commit_valid_bundle(commit_valid_bundle), .commit_tag_bundle(commit_tag_bundle),
    .commit_rd_used_bundle(commit_rd_used_bundle), .commit_rd_bundle(commit_rd_bundle),
    .commit_value_bundle(commit_value_bundle),
    .halted(halted), .cdb_overflow(cdb_overflow)
  );

  always #5 clk = ~clk;

  always @(posedge clk) begin
    int wr_idx;
    if (rst) begin
      cap_count <= 0;
    end else begin
      wr_idx = cap_count;
      for (int i = 0; i < WIDTH; i++) begin
        if (commit_valid_bundle[i]) begin
          cap_rd_used[wr_idx] <= commit_rd_used_bundle[i];
          cap_rd[wr_idx]      <= commit_rd_bundle[i];
          cap_value[wr_idx]   <= commit_value_bundle[i];
          wr_idx++;
        end
      end
      cap_count <= wr_idx;
    end
  end

  task automatic wait_halted();
    for (int k = 0; k < 5000; k++) begin
      @(posedge clk); #1;
      if (halted) return;
    end
    $display("FAIL halt timeout"); errors++;
  endtask

  task automatic chk_commit(input int idx, input string name,
                            input bit rd_used, input reg_idx_t rd, input data_t value);
    if (cap_rd_used[idx] !== rd_used) begin
      $display("FAIL %-12s rd_used got=%0b exp=%0b", name, cap_rd_used[idx], rd_used);
      errors++;
    end else if (rd_used && ((cap_rd[idx] !== rd) || (cap_value[idx] !== value))) begin
      $display("FAIL %-12s rd=%0d value=%h exp_rd=%0d exp=%h",
               name, cap_rd[idx], cap_value[idx], rd, value);
      errors++;
    end else begin
      if (rd_used) $display("ok   %-12s x%0d=%h", name, cap_rd[idx], cap_value[idx]);
      else         $display("ok   %-12s no-rd", name);
    end
  endtask

  initial begin
    repeat (3) @(posedge clk);
    rst = 1'b0;

    wait_halted();

    if (cap_count !== 5) begin
      $display("FAIL commit count got=%0d exp=5", cap_count);
      errors++;
    end

    chk_commit(0, "addi x1", 1'b1, 5'd1, 32'd5);
    chk_commit(1, "addi x2", 1'b1, 5'd2, 32'd8);
    chk_commit(2, "mul x3",  1'b1, 5'd3, 32'd40);
    chk_commit(3, "sw",      1'b0, 5'd0, '0);
    chk_commit(4, "lw x4",   1'b1, 5'd4, 32'd40);

    if (cdb_overflow) begin $display("FAIL cdb_overflow asserted"); errors++; end

    if (errors == 0) $display("TB_CORE: PASS");
    else             $display("TB_CORE: FAIL (%0d errors)", errors);
    $finish;
  end
endmodule
