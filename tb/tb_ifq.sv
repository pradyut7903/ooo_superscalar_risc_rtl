`timescale 1ns/1ps
// ============================================================================
// tb_ifq.sv -- self-checking test for the instruction fetch queue.
// ============================================================================
module tb_ifq;
  import pkg_cpu::*;

  localparam int DEPTH = 4;

  logic clk = 1'b0, rst = 1'b1, flush = 1'b0;
  logic push_ready;
  logic [$clog2(WIDTH+1)-1:0] push_count = '0;
  pc_bundle_t push_pc = '{default:'0};
  instr_bundle_t push_instr = '{default:INSTR_INVALID};
  valid_bundle_t push_pred_taken = '0;
  pc_bundle_t push_pred_target = '{default:'0};

  logic [$clog2(WIDTH+1)-1:0] pop_count = '0;
  valid_bundle_t out_valid;
  pc_bundle_t out_pc;
  instr_bundle_t out_instr;
  valid_bundle_t out_pred_taken;
  pc_bundle_t out_pred_target;
  logic full, empty;
  int errors = 0;

  ifq #(.DEPTH(DEPTH)) dut (
    .clk(clk), .rst(rst), .flush(flush),
    .push_count(push_count), .push_ready(push_ready),
    .push_pc(push_pc), .push_instr(push_instr),
    .push_pred_taken(push_pred_taken), .push_pred_target(push_pred_target),
    .pop_count(pop_count),
    .out_valid(out_valid), .out_pc(out_pc), .out_instr(out_instr),
    .out_pred_taken(out_pred_taken), .out_pred_target(out_pred_target),
    .full(full), .empty(empty)
  );

  always #5 clk = ~clk;

  task automatic push(input pc_t pc, input instr_t instr, input logic pred, input pc_t target);
    @(negedge clk);
    push_count = 1'b1;
    push_pc = '{default:'0};
    push_instr = '{default:INSTR_INVALID};
    push_pred_taken = '0;
    push_pred_target = '{default:'0};
    push_pc[0] = pc;
    push_instr[0] = instr;
    push_pred_taken[0] = pred;
    push_pred_target[0] = target;
    pop_count = '0;
    if (!push_ready) begin
      $display("FAIL push pc=%h while not ready", pc);
      errors++;
    end
    @(posedge clk); #1;
    push_count = '0;
  endtask

  task automatic pop1(input string name, input pc_t pc, input instr_t instr,
                      input logic pred, input pc_t target);
    @(negedge clk); #1;
    if (!out_valid[0] || (out_pc[0] !== pc) || (out_instr[0] !== instr) ||
        (out_pred_taken[0] !== pred) || (out_pred_target[0] !== target)) begin
      $display("FAIL %-18s valid=%0b pc=%h instr=%h pred=%0b target=%h exp_pc=%h exp_instr=%h",
               name, out_valid[0], out_pc[0], out_instr[0], out_pred_taken[0],
               out_pred_target[0], pc, instr);
      errors++;
    end else begin
      $display("ok   %-18s pc=%h instr=%h", name, out_pc[0], out_instr[0]);
    end
    pop_count = 1'b1;
    @(posedge clk); #1;
    pop_count = '0;
  endtask

  task automatic chk_lane(input int lane, input string name, input pc_t pc, input instr_t instr);
    #1;
    if (!out_valid[lane] || (out_pc[lane] !== pc) || (out_instr[lane] !== instr)) begin
      $display("FAIL %-18s lane=%0d valid=%0b pc=%h instr=%h exp_pc=%h exp_instr=%h",
               name, lane, out_valid[lane], out_pc[lane], out_instr[lane], pc, instr);
      errors++;
    end else begin
      $display("ok   %-18s lane=%0d pc=%h instr=%h", name, lane, out_pc[lane], out_instr[lane]);
    end
  endtask

  initial begin
    repeat (2) @(posedge clk);
    rst = 1'b0;
    @(negedge clk); #1;
    if (!empty || full || out_valid[0]) begin
      $display("FAIL reset state empty=%0b full=%0b valid0=%0b", empty, full, out_valid[0]);
      errors++;
    end else $display("ok   reset empty");

    push(32'h0, 32'h1111_0001, 1'b0, 32'h4);
    push(32'h4, 32'h2222_0002, 1'b1, 32'h40);
    pop1("pop first", 32'h0, 32'h1111_0001, 1'b0, 32'h4);
    pop1("pop second", 32'h4, 32'h2222_0002, 1'b1, 32'h40);
    @(negedge clk); #1;
    if (!empty) begin $display("FAIL empty after pops"); errors++; end
    else        $display("ok   empty after pops");

    if (WIDTH > 1) begin
      @(negedge clk);
      push_count = 2;
      push_pc = '{default:'0};
      push_instr = '{default:INSTR_INVALID};
      push_pred_taken = '0;
      push_pred_target = '{default:'0};
      push_pc[0] = 32'h08;
      push_instr[0] = 32'h8888_0008;
      push_pc[1] = 32'h0c;
      push_instr[1] = 32'h9999_000c;
      @(posedge clk); #1;
      push_count = '0;
      pop1("multi-push lane0", 32'h08, 32'h8888_0008, 1'b0, '0);
      pop1("multi-push lane1", 32'h0c, 32'h9999_000c, 1'b0, '0);

      push(32'h08, 32'h8888_0008, 1'b0, 32'h0c);
      push(32'h0c, 32'h9999_000c, 1'b0, 32'h10);
      push(32'h10, 32'haaaa_0010, 1'b0, 32'h14);
      @(negedge clk);
      chk_lane(0, "bundle lane0", 32'h08, 32'h8888_0008);
      chk_lane(1, "bundle lane1", 32'h0c, 32'h9999_000c);
      pop_count = 2;
      @(posedge clk); #1;
      pop_count = '0;
      pop1("bundle remains", 32'h10, 32'haaaa_0010, 1'b0, 32'h14);
      @(negedge clk); #1;
      if (!empty) begin $display("FAIL empty after bundle pop"); errors++; end
      else        $display("ok   empty after bundle pop");
    end

    // Fill the queue and verify backpressure.
    push(32'h10, 32'haaaa_0010, 1'b0, 32'h14);
    push(32'h14, 32'hbbbb_0014, 1'b0, 32'h18);
    push(32'h18, 32'hcccc_0018, 1'b0, 32'h1c);
    push(32'h1c, 32'hdddd_001c, 1'b0, 32'h20);
    @(negedge clk); push_count = 1'b1; #1;
    if (!full || push_ready) begin
      $display("FAIL full/backpressure full=%0b push_ready=%0b", full, push_ready);
      errors++;
    end else $display("ok   full backpressure");
    push_count = '0;

    // Simultaneous pop+push while full should be accepted and preserve order.
    @(negedge clk);
    push_count = 1'b1;
    push_pc = '{default:'0};
    push_instr = '{default:INSTR_INVALID};
    push_pred_taken = '0;
    push_pred_target = '{default:'0};
    push_pc[0] = 32'h20;
    push_instr[0] = 32'heeee_0020;
    push_pred_taken[0] = 1'b1;
    push_pred_target[0] = 32'h80;
    pop_count = 1'b1;
    #1;
    if (!push_ready) begin $display("FAIL full pop+push not ready"); errors++; end
    @(posedge clk); #1;
    push_count = '0;
    pop_count = '0;

    pop1("wrap pop 14", 32'h14, 32'hbbbb_0014, 1'b0, 32'h18);
    pop1("wrap pop 18", 32'h18, 32'hcccc_0018, 1'b0, 32'h1c);
    pop1("wrap pop 1c", 32'h1c, 32'hdddd_001c, 1'b0, 32'h20);
    pop1("wrap pop new", 32'h20, 32'heeee_0020, 1'b1, 32'h80);

    push(32'h30, 32'h3333_0030, 1'b0, 32'h34);
    @(negedge clk); flush = 1'b1;
    @(posedge clk); #1; flush = 1'b0;
    @(negedge clk); #1;
    if (!empty || out_valid[0]) begin
      $display("FAIL flush did not empty queue");
      errors++;
    end else $display("ok   flush empty");

    if (errors == 0) $display("TB_IFQ: PASS");
    else             $display("TB_IFQ: FAIL (%0d errors)", errors);
    $finish;
  end
endmodule
