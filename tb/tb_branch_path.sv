`timescale 1ns/1ps
// ============================================================================
// tb_branch_path.sv -- tests gshare predictor, pipeline regs, and recovery.
// ============================================================================
module tb_branch_path;
  import pkg_cpu::*;

  logic clk = 1'b0, rst = 1'b1, flush = 1'b0;
  pc_bundle_t fetch_pc = '{default:'0};
  valid_bundle_t pred_taken;
  pc_bundle_t pred_target;
  valid_bundle_t update_valid = '0;
  pc_bundle_t update_pc = '{default:'0};
  valid_bundle_t update_taken = '0;
  pc_bundle_t update_target = '{default:'0};

  logic if_in_valid, if_in_ready, if_out_valid, if_out_ready = 1'b1;
  pc_t if_in_pc, if_out_pc, if_in_pred_target, if_out_pred_target;
  instr_t if_in_instr, if_out_instr;
  logic if_in_pred_taken, if_out_pred_taken;

  logic rn_in_valid, rn_in_ready, rn_out_valid, rn_out_ready = 1'b1;
  uop_t rn_in_uop, rn_out_uop;

  logic rec_flush, redirect_valid;
  pc_t redirect_pc;
  int errors = 0;

  branch_predictor u_bp (
    .clk(clk), .rst(rst),
    .fetch_pc(fetch_pc), .pred_taken(pred_taken), .pred_target(pred_target),
    .update_valid(update_valid), .update_pc(update_pc),
    .update_taken(update_taken), .update_target(update_target)
  );

  if_id_reg u_ifid (
    .clk(clk), .rst(rst), .flush(flush),
    .in_valid(if_in_valid), .in_ready(if_in_ready),
    .in_pc(if_in_pc), .in_instr(if_in_instr),
    .in_pred_taken(if_in_pred_taken), .in_pred_target(if_in_pred_target),
    .out_valid(if_out_valid), .out_ready(if_out_ready),
    .out_pc(if_out_pc), .out_instr(if_out_instr),
    .out_pred_taken(if_out_pred_taken), .out_pred_target(if_out_pred_target)
  );

  id_rn_reg u_idrn (
    .clk(clk), .rst(rst), .flush(flush),
    .in_valid(rn_in_valid), .in_ready(rn_in_ready),
    .in_uop(rn_in_uop), .in_pred_taken(if_out_pred_taken),
    .in_pred_target(if_out_pred_target),
    .out_valid(rn_out_valid), .out_ready(rn_out_ready), .out_uop(rn_out_uop)
  );

  early_recovery u_rec (
    .br_resolve_valid(1'b1), .br_mispredict(1'b1),
    .br_resolve_tag('0), .br_redirect_pc(32'h0040_0000),
    .recover_en(rec_flush), .recover_tag(), .recover_pc(),
    .squash_en(), .squash_tag(),
    .redirect_valid(redirect_valid), .redirect_pc(redirect_pc)
  );

  always #5 clk = ~clk;

  task automatic chk(input string name, input bit cond);
    if (!cond) begin $display("FAIL %s", name); errors++; end
    else       begin $display("ok   %s", name); end
  endtask

  initial begin
    if_in_valid = 1'b0; if_in_pc = '0; if_in_instr = '0;
    if_in_pred_taken = 1'b0; if_in_pred_target = '0;
    rn_in_valid = 1'b0; rn_in_uop = '0;

    repeat (2) @(posedge clk); rst = 1'b0;

    fetch_pc[0] = 32'h1000;
    #1;
    chk("predict not taken", !pred_taken[0] && (pred_target[0] == 32'h1004));
    chk("recovery redirect", rec_flush && redirect_valid && (redirect_pc == 32'h0040_0000));

    fetch_pc[0] = 32'h1000;
    repeat ($clog2(PHT_SIZE) + 1) begin
      @(negedge clk);
      update_valid = '0;
      update_valid[0] = 1'b1;
      update_pc[0] = 32'h1000;
      update_taken[0] = 1'b1;
      update_target[0] = 32'h2000;
      @(posedge clk); #1;
    end
    update_valid = '0;
    #1;
    chk("gshare predicts trained taken", pred_taken[0] && (pred_target[0] == 32'h2000));

    @(negedge clk);
    if_in_valid = 1'b1; if_in_pc = 32'h20; if_in_instr = 32'h0050_0093;
    if_in_pred_taken = 1'b1; if_in_pred_target = 32'h80;
    @(posedge clk); #1; if_in_valid = 1'b0;
    chk("if/id capture", if_out_valid && (if_out_pc == 32'h20) &&
                         (if_out_instr == 32'h0050_0093) &&
                         if_out_pred_taken && (if_out_pred_target == 32'h80));

    @(negedge clk);
    rn_in_valid = 1'b1; rn_in_uop = '0; rn_in_uop.op = BR_EQ; rn_in_uop.fu = FU_BR;
    @(posedge clk); #1; rn_in_valid = 1'b0;
    chk("id/rn pred attach", rn_out_valid && rn_out_uop.pred_taken &&
                             (rn_out_uop.pred_target == 32'h80));

    @(negedge clk); flush = 1'b1;
    @(posedge clk); #1; flush = 1'b0;
    chk("flush clears regs", !if_out_valid && !rn_out_valid);

    if (errors == 0) $display("TB_BRANCH_PATH: PASS");
    else             $display("TB_BRANCH_PATH: FAIL (%0d errors)", errors);
    $finish;
  end
endmodule
