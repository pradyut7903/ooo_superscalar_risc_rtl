`timescale 1ns/1ps
// ============================================================================
// tb_fetch.sv -- self-checking test for fetch + instr_mem together.
//
// Loads rv32_smoke.imem.hex (5 instructions at PC 0,4,8,12,16) and checks:
//   1. the instruction stream comes out in order, with correct pc + word
//   2. valid drops after the last instruction (end-of-program)
//   3. a stall (out_ready=0) holds the current instruction unchanged
//   4. a redirect jumps fetch to the new PC
// ============================================================================
module tb_fetch;
  import pkg_cpu::*;

  logic   clk = 1'b0;
  logic   rst = 1'b1;
  logic   redirect_valid = 1'b0;
  pc_t    redirect_pc    = '0;
  valid_bundle_t pred_taken = '0;
  pc_bundle_t    pred_target = '{default:'0};
  logic   out_ready      = 1'b1;
  logic [$clog2(WIDTH+1)-1:0] out_count;
  logic   out_valid;
  logic   out_eop;
  pc_bundle_t out_pc;
  instr_bundle_t out_instr;
  valid_bundle_t out_pred_taken;
  pc_bundle_t out_pred_target;

  // fetch <-> imem wiring
  logic imem_req_valid, imem_req_ready, imem_resp_valid;
  pc_t imem_req_pc;
  valid_bundle_t imem_resp_word_valid;
  instr_bundle_t imem_resp_word;
  pc_bundle_t imem_resp_pc;
  logic [$clog2(WIDTH+1)-1:0] imem_resp_count;
  pc_bundle_t pred_lookup_pc;

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
    .out_count(out_count), .out_valid(out_valid), .out_eop(out_eop), .out_pc(out_pc), .out_instr(out_instr),
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

  int errors = 0;
  pc_t    p;
  instr_t w;
  bit     got;

  localparam logic [31:0] PROG [0:4] = '{
    32'h00500093, 32'h00300113, 32'h002081B3, 32'h40118233, 32'h022082B3
  };

  // Accept the next instruction by sampling the valid/ready handshake AT the
  // clock edge (before NBA updates), so a back-to-back stream isn't sampled one
  // instruction ahead. got=0 if no handshake within 40 cycles.
  task automatic accept(output pc_t op, output instr_t ow, output bit ogot);
    ogot = 1'b0;
    for (int k = 0; k < 40; k++) begin
      @(posedge clk);
      if (out_valid && out_ready) begin
        op = out_pc[0]; ow = out_instr[0]; ogot = 1'b1; return;
      end
    end
  endtask

  initial begin
    rst = 1'b1; out_ready = 1'b1; redirect_valid = 1'b0;
    pred_taken = '0; pred_target = '{default:'0};
    if (WIDTH != 1) begin
      $display("TB_FETCH: SKIP (WIDTH=%0d; covered by tb_fetch_bundle)", WIDTH);
      $finish;
    end
    repeat (3) @(posedge clk);
    rst = 1'b0;

    // ---- Phase 1: ordered instruction stream ----
    for (int i = 0; i < 5; i++) begin
      accept(p, w, got);
      if (!got)               begin $display("FAIL stream[%0d]: no instruction", i); errors++; end
      else if (p !== i*4)     begin $display("FAIL stream[%0d] pc got=%h exp=%h", i, p, i*4); errors++; end
      else if (w !== PROG[i]) begin $display("FAIL stream[%0d] instr got=%h exp=%h", i, w, PROG[i]); errors++; end
      else                    $display("ok   stream[%0d] pc=%h instr=%h", i, p, w);
    end

    // ---- Phase 2: end-of-program ----
    accept(p, w, got);
    if (got) begin $display("FAIL end-of-prog: got pc=%h", p); errors++; end
    else     $display("ok   end-of-program");

    // ---- Phase 3: restart via redirect to 0, then stall-hold ----
    @(negedge clk); redirect_valid = 1'b1; redirect_pc = '0;
    @(negedge clk); redirect_valid = 1'b0;
    out_ready = 1'b0;                       // refuse to consume
    for (int k = 0; k < 10; k++) begin @(posedge clk); #1; if (out_valid) break; end
    if (!(out_valid && out_pc[0] == 0 && out_instr[0] == PROG[0]))
      begin $display("FAIL stall: first valid pc=%h instr=%h", out_pc[0], out_instr[0]); errors++; end
    repeat (3) begin
      @(posedge clk); #1;
      if (!(out_valid && out_pc[0] == 0 && out_instr[0] == PROG[0]))
        begin $display("FAIL stall-hold pc=%h instr=%h", out_pc[0], out_instr[0]); errors++; end
    end
    $display("ok   stall-hold (pc=0 held while out_ready=0)");
    out_ready = 1'b1;

    // ---- Phase 4: redirect mid-stream to PC=8 ----
    @(negedge clk); redirect_valid = 1'b1; redirect_pc = 32'd8;
    @(negedge clk); redirect_valid = 1'b0;
    accept(p, w, got);
    if (!(got && p == 32'd8 && w == PROG[2]))
      begin $display("FAIL redirect: got pc=%h instr=%h", p, w); errors++; end
    else $display("ok   redirect-to-8 pc=%h instr=%h", p, w);

    if (errors == 0) $display("TB_FETCH: PASS");
    else             $display("TB_FETCH: FAIL (%0d errors)", errors);
    $finish;
  end
endmodule
