`timescale 1ns/1ps
// ============================================================================
// tb_fetch_bundle.sv -- bundle fetch behavior test.
//
// Intended to be run with WIDTH >= 4.  With WIDTH == 1 it skips, because the
// scalar fetch tests cover that configuration.
// ============================================================================
module tb_fetch_bundle;
  import pkg_cpu::*;

  logic clk = 1'b0;
  logic rst = 1'b1;
  logic redirect_valid = 1'b0;
  pc_t  redirect_pc = '0;
  valid_bundle_t pred_taken = '0;
  pc_bundle_t pred_target = '{default:'0};
  logic out_ready = 1'b1;

  logic [$clog2(WIDTH+1)-1:0] out_count;
  logic out_valid, out_eop;
  pc_bundle_t out_pc;
  instr_bundle_t out_instr;
  valid_bundle_t out_pred_taken;
  pc_bundle_t out_pred_target;

  logic imem_req_valid, imem_req_ready, imem_resp_valid;
  pc_t imem_req_pc;
  valid_bundle_t imem_resp_word_valid;
  instr_bundle_t imem_resp_word;
  pc_bundle_t imem_resp_pc;
  logic [$clog2(WIDTH+1)-1:0] imem_resp_count;
  pc_bundle_t pred_lookup_pc;

  localparam logic [31:0] PROG [0:4] = '{
    32'h00500093, 32'h00300113, 32'h002081B3, 32'h40118233, 32'h022082B3
  };

  int errors = 0;

  fetch u_fetch (
    .clk(clk), .rst(rst),
    .redirect_valid(redirect_valid), .redirect_pc(redirect_pc),
    .pred_taken(pred_taken), .pred_target(pred_target),
    .imem_req_valid(imem_req_valid), .imem_req_ready(imem_req_ready),
    .imem_req_pc(imem_req_pc),
    .imem_resp_valid(imem_resp_valid),
    .imem_resp_word_valid(imem_resp_word_valid),
    .imem_resp_word(imem_resp_word),
    .imem_resp_pc(imem_resp_pc),
    .imem_resp_count(imem_resp_count),
    .pred_lookup_pc(pred_lookup_pc),
    .out_count(out_count), .out_valid(out_valid), .out_eop(out_eop),
    .out_pc(out_pc), .out_instr(out_instr),
    .out_pred_taken(out_pred_taken), .out_pred_target(out_pred_target),
    .out_ready(out_ready)
  );

  ideal_imem_bridge #(.DEFAULT_IMAGE("rv32_smoke.imem.hex")) u_imem (
    .clk(clk), .rst(rst), .flush(redirect_valid),
    .req_valid(imem_req_valid), .req_ready(imem_req_ready), .req_pc(imem_req_pc),
    .resp_valid(imem_resp_valid), .resp_word_valid(imem_resp_word_valid),
    .resp_word(imem_resp_word), .resp_pc(imem_resp_pc),
    .resp_count(imem_resp_count)
  );

  always #5 clk = ~clk;

  task automatic wait_output();
    #1;
    if (out_valid || out_eop) return;
    for (int k = 0; k < 40; k++) begin
      @(posedge clk); #1;
      if (out_valid || out_eop) return;
    end
    $display("FAIL output timeout");
    errors++;
  endtask

  task automatic chk_lane(input int lane, input pc_t pc, input instr_t instr);
    if (!out_valid || (out_pc[lane] !== pc) || (out_instr[lane] !== instr)) begin
      $display("FAIL lane%0d got pc=%h instr=%h exp pc=%h instr=%h",
               lane, out_pc[lane], out_instr[lane], pc, instr);
      errors++;
    end else begin
      $display("ok   lane%0d pc=%h instr=%h", lane, out_pc[lane], out_instr[lane]);
    end
  endtask

  initial begin
    if (WIDTH < 4) begin
      $display("TB_FETCH_BUNDLE: SKIP (WIDTH=%0d)", WIDTH);
      $finish;
    end

    repeat (3) @(posedge clk);
    rst = 1'b0;

    // Four valid instructions from PC 0, no EOP yet because PC 16 is valid.
    wait_output();
    if (out_count !== 4 || out_eop) begin
      $display("FAIL first bundle count=%0d eop=%0b", out_count, out_eop);
      errors++;
    end
    for (int i = 0; i < 4; i++) chk_lane(i, pc_t'(4 * i), PROG[i]);

    // Next bundle starts at PC 16, includes one valid instruction, then EOP.
    @(posedge clk); #1;
    wait_output();
    if (out_count !== 1 || !out_eop) begin
      $display("FAIL eop bundle count=%0d eop=%0b", out_count, out_eop);
      errors++;
    end
    chk_lane(0, 32'h10, PROG[4]);

    // Redirect clears stopped EOP state.  Predict lane 1 taken from PC 0 to PC
    // 16, so the first returned bundle includes lanes 0 and 1 only.
    @(negedge clk);
    redirect_valid = 1'b1;
    redirect_pc = '0;
    @(negedge clk);
    redirect_valid = 1'b0;

    forever begin
      pred_taken = '0;
      pred_target = '{default:'0};
      if (pred_lookup_pc[0] == 32'h0) begin
        pred_taken[1] = 1'b1;
        pred_target[1] = 32'h10;
      end
      @(posedge clk); #1;
      if (out_valid || out_eop) break;
    end

    if (out_count !== 2 || out_eop || !out_pred_taken[1] || (out_pred_target[1] !== 32'h10)) begin
      $display("FAIL predicted bundle count=%0d eop=%0b pred1=%0b target1=%h",
               out_count, out_eop, out_pred_taken[1], out_pred_target[1]);
      errors++;
    end
    chk_lane(0, 32'h0, PROG[0]);
    chk_lane(1, 32'h4, PROG[1]);

    @(posedge clk); #1;
    wait_output();
    if (out_count !== 1 || !out_eop) begin
      $display("FAIL predicted target/eop count=%0d eop=%0b", out_count, out_eop);
      errors++;
    end
    chk_lane(0, 32'h10, PROG[4]);

    if (errors == 0) $display("TB_FETCH_BUNDLE: PASS");
    else             $display("TB_FETCH_BUNDLE: FAIL (%0d errors)", errors);
    $finish;
  end
endmodule
