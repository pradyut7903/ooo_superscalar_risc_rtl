`timescale 1ns/1ps
// ============================================================================
// tb_rob.sv -- lane-0 regression for the bundled reorder buffer.
// ============================================================================
module tb_rob;
  import pkg_cpu::*;

  logic clk = 1'b0, rst = 1'b1, flush = 1'b0;
  logic squash_en = 1'b0;
  rob_tag_t squash_tag = '0;

  valid_bundle_t alloc_en = '0;
  logic alloc_rd_used [WIDTH];
  logic alloc_is_control [WIDTH];
  logic alloc_is_store [WIDTH];
  pc_t alloc_pc [WIDTH];
  reg_idx_t alloc_dest [WIDTH];
  rob_tag_t alloc_tag [WIDTH];
  logic full;
  logic [$clog2(ROB_DEPTH+1)-1:0] free_count;

  cdb_bus_t wb_cdb = '{default:'0};
  valid_bundle_t complete_en = '0;
  rob_tag_t complete_tag [WIDTH];
  logic complete2_en = 1'b0;
  rob_tag_t complete2_tag = '0;
  logic br_resolve_en = 1'b0;
  rob_tag_t br_resolve_tag = '0;
  logic br_mispredict = 1'b0;
  pc_t br_redirect_pc = '0;

  rob_tag_t rd_tag1 [WIDTH], rd_tag2 [WIDTH];
  logic rd_done1 [WIDTH], rd_done2 [WIDTH];
  data_t rd_val1 [WIDTH], rd_val2 [WIDTH];

  valid_bundle_t commit_valid;
  rob_tag_t commit_tag [WIDTH];
  logic commit_rd_used [WIDTH];
  reg_idx_t commit_dest [WIDTH];
  data_t commit_value [WIDTH];
  logic commit_is_control [WIDTH];
  logic commit_mispredict [WIDTH];
  pc_t commit_pc [WIDTH];
  logic commit_taken [WIDTH];
  pc_t commit_target [WIDTH];
  pc_t commit_redirect_pc [WIDTH];
  valid_bundle_t commit_do = '0;
  valid_bundle_t commit_store_valid;
  rob_tag_t commit_store_tag [WIDTH];
  logic empty;

  int errors = 0;

  rob dut (
    .clk(clk), .rst(rst), .flush(flush),
    .squash_en(squash_en), .squash_tag(squash_tag),
    .alloc_en(alloc_en), .alloc_rd_used(alloc_rd_used),
    .alloc_dest(alloc_dest), .alloc_is_control(alloc_is_control),
    .alloc_is_store(alloc_is_store), .alloc_pc(alloc_pc),
    .alloc_tag(alloc_tag), .full(full), .free_count(free_count),
    .wb_cdb(wb_cdb),
    .complete_en(complete_en), .complete_tag(complete_tag),
    .complete2_en(complete2_en), .complete2_tag(complete2_tag),
    .br_resolve_en(br_resolve_en), .br_resolve_tag(br_resolve_tag),
    .br_mispredict(br_mispredict), .br_taken(1'b0), .br_target('0),
    .br_redirect_pc(br_redirect_pc),
    .rd_tag1(rd_tag1), .rd_done1(rd_done1), .rd_val1(rd_val1),
    .rd_tag2(rd_tag2), .rd_done2(rd_done2), .rd_val2(rd_val2),
    .commit_valid(commit_valid), .commit_tag(commit_tag),
    .commit_rd_used(commit_rd_used), .commit_dest(commit_dest),
    .commit_value(commit_value), .commit_is_control(commit_is_control),
    .commit_mispredict(commit_mispredict),
    .commit_pc(commit_pc), .commit_taken(commit_taken), .commit_target(commit_target),
    .commit_redirect_pc(commit_redirect_pc),
    .commit_do(commit_do),
    .commit_store_valid(commit_store_valid),
    .commit_store_tag(commit_store_tag),
    .empty(empty), .rob_head(), .slot_freed()
  );

  always #5 clk = ~clk;

  task automatic clear_alloc();
    alloc_en = '0;
    for (int i = 0; i < WIDTH; i++) begin
      alloc_rd_used[i] = 1'b0;
      alloc_dest[i] = '0;
      alloc_is_control[i] = 1'b0;
      alloc_is_store[i] = 1'b0;
      alloc_pc[i] = '0;
      complete_tag[i] = '0;
      rd_tag1[i] = '0;
      rd_tag2[i] = '0;
    end
  endtask

  task automatic alloc(input logic ru, input logic [4:0] d,
                       input logic [4:0] exp_tag, input bit check_tag);
    @(negedge clk);
    clear_alloc();
    alloc_en[0] = 1'b1; alloc_rd_used[0] = ru; alloc_dest[0] = d;
    alloc_is_control[0] = 1'b0; alloc_is_store[0] = 1'b0; #1;
    if (check_tag && (alloc_tag[0] !== exp_tag))
      begin $display("FAIL alloc tag got=%0d exp=%0d", alloc_tag[0], exp_tag); errors++; end
    @(posedge clk); #1; clear_alloc();
  endtask

  task automatic alloc_control(input logic [4:0] exp_tag);
    @(negedge clk);
    clear_alloc();
    alloc_en[0] = 1'b1; alloc_rd_used[0] = 1'b0; alloc_dest[0] = '0;
    alloc_is_control[0] = 1'b1; alloc_is_store[0] = 1'b0; #1;
    if (alloc_tag[0] !== exp_tag)
      begin $display("FAIL control alloc tag got=%0d exp=%0d", alloc_tag[0], exp_tag); errors++; end
    @(posedge clk); #1; clear_alloc();
  endtask

  task automatic br_resolve(input logic [4:0] tg, input logic mis, input pc_t redir);
    @(negedge clk);
    br_resolve_en = 1'b1; br_resolve_tag = tg; br_mispredict = mis; br_redirect_pc = redir;
    @(posedge clk); #1; br_resolve_en = 1'b0;
  endtask

  task automatic wb(input logic [4:0] tg, input logic [31:0] v);
    @(negedge clk);
    wb_cdb = '{default:'0};
    wb_cdb[0].valid = 1'b1; wb_cdb[0].tag = tg; wb_cdb[0].data = v;
    @(posedge clk); #1; wb_cdb = '{default:'0};
  endtask

  task automatic wb2(input logic [4:0] tg0, input logic [31:0] v0,
                     input logic [4:0] tg1, input logic [31:0] v1);
    @(negedge clk);
    wb_cdb = '{default:'0};
    wb_cdb[0].valid = 1'b1; wb_cdb[0].tag = tg0; wb_cdb[0].data = v0;
    wb_cdb[1].valid = 1'b1; wb_cdb[1].tag = tg1; wb_cdb[1].data = v1;
    @(posedge clk); #1; wb_cdb = '{default:'0};
  endtask

  task automatic complete(input logic [4:0] tg);
    @(negedge clk); complete_en = '0; complete_en[0] = 1'b1; complete_tag[0] = tg;
    @(posedge clk); #1; complete_en = '0;
  endtask

  task automatic alloc_store(input logic [4:0] exp_tag);
    @(negedge clk);
    clear_alloc();
    alloc_en[0] = 1'b1; alloc_rd_used[0] = 1'b0; alloc_dest[0] = '0;
    alloc_is_control[0] = 1'b0; alloc_is_store[0] = 1'b1; #1;
    if (alloc_tag[0] !== exp_tag)
      begin $display("FAIL store alloc tag got=%0d exp=%0d", alloc_tag[0], exp_tag); errors++; end
    @(posedge clk); #1; clear_alloc();
  endtask

  task automatic complete2(input logic [4:0] tg);
    @(negedge clk); complete2_en = 1'b1; complete2_tag = tg;
    @(posedge clk); #1; complete2_en = 1'b0;
  endtask

  task automatic commit_chk(input string name, input logic [4:0] ed, input logic [31:0] ev);
    @(negedge clk); #1;
    if (!commit_valid[0])          begin $display("FAIL %-14s: head not valid", name); errors++; end
    else begin
      if (commit_dest[0]  !== ed)  begin $display("FAIL %-14s dest got=%0d exp=%0d", name, commit_dest[0], ed); errors++; end
      if (commit_value[0] !== ev)  begin $display("FAIL %-14s val got=%h exp=%h", name, commit_value[0], ev); errors++; end
      else $display("ok   %-14s dest=%0d value=%h", name, commit_dest[0], commit_value[0]);
    end
    commit_do[0] = 1'b1; @(posedge clk); #1; commit_do = '0;
  endtask

  task automatic expect_no_commit(input string name);
    #1;
    if (commit_valid[0]) begin $display("FAIL %-14s: unexpected commit (dest=%0d)", name, commit_dest[0]); errors++; end
    else $display("ok   %-14s (head correctly waiting)", name);
  endtask

  initial begin
    clear_alloc();
    rst = 1'b1; repeat (2) @(posedge clk); rst = 1'b0; @(negedge clk); #1;
    if (!empty) begin $display("FAIL not empty after reset"); errors++; end

    alloc(1'b1, 5'd5, 5'd0, 1'b1);
    alloc(1'b1, 5'd6, 5'd1, 1'b1);
    alloc(1'b1, 5'd7, 5'd2, 1'b1);

    rd_tag1[0] = 5'd1; #1;
    if (rd_done1[0]) begin $display("FAIL tag1 should be pending"); errors++; end
    else $display("ok   tag1 pending");

    expect_no_commit("head0 pending");

    wb(5'd2, 32'h0000_2222);
    rd_tag1[0] = 5'd2; #1;
    if (!rd_done1[0] || (rd_val1[0] !== 32'h0000_2222)) begin $display("FAIL tag2 read after wb"); errors++; end
    else $display("ok   tag2 done=1 val=2222");
    expect_no_commit("head0 still");

    wb(5'd0, 32'h0000_AAAA);
    commit_chk("commit tag0", 5'd5, 32'h0000_AAAA);
    expect_no_commit("head1 pending");

    wb2(5'd1, 32'h0000_BBBB, 5'd2, 32'h0000_2222);
    commit_chk("commit tag1", 5'd6, 32'h0000_BBBB);
    commit_chk("commit tag2", 5'd7, 32'h0000_2222);

    @(negedge clk); #1;
    if (!empty) begin $display("FAIL not empty after draining"); errors++; end
    else $display("ok   empty after in-order drain");

    alloc(1'b0, 5'd0, 5'd3, 1'b1);
    expect_no_commit("complete pending");
    complete(5'd3);
    @(negedge clk); #1;
    if (!commit_valid[0] || commit_rd_used[0]) begin
      $display("FAIL complete-only commit valid=%0b rd_used=%0b", commit_valid[0], commit_rd_used[0]);
      errors++;
    end else $display("ok   complete-only commit");
    commit_do[0] = 1'b1; @(posedge clk); #1; commit_do = '0;

    alloc_control(5'd4);
    expect_no_commit("branch pending");
    br_resolve(5'd4, 1'b1, 32'h0000_0040);
    complete2(5'd4);
    @(negedge clk); #1;
    if (!commit_valid[0] || !commit_is_control[0] || !commit_mispredict[0] ||
        (commit_redirect_pc[0] !== 32'h40)) begin
      $display("FAIL branch metadata valid=%0b ctrl=%0b mis=%0b redir=%h",
               commit_valid[0], commit_is_control[0], commit_mispredict[0], commit_redirect_pc[0]);
      errors++;
    end else $display("ok   branch metadata at commit");
    commit_do[0] = 1'b1; @(posedge clk); #1; commit_do = '0;

    alloc_store(5'd5);
    @(negedge clk); #1;
    if (!commit_store_valid[0] || (commit_store_tag[0] !== 5'd5) || commit_valid[0]) begin
      $display("FAIL store grant valid=%0b tag=%0d commit_valid=%0b",
               commit_store_valid[0], commit_store_tag[0], commit_valid[0]);
      errors++;
    end else $display("ok   store commit permission tag=%0d", commit_store_tag[0]);
    complete(5'd5);
    @(negedge clk); #1;
    if (!commit_valid[0] || commit_rd_used[0]) begin
      $display("FAIL completed store commit valid=%0b rd_used=%0b", commit_valid[0], commit_rd_used[0]);
      errors++;
    end else $display("ok   completed store can commit");
    commit_do[0] = 1'b1; @(posedge clk); #1; commit_do = '0;

    for (int i = 0; i < ROB_DEPTH-1; i++) alloc(1'b1, 5'd1, 5'd0, 1'b0);
    @(negedge clk); #1;
    if (full) begin $display("FAIL full asserted early (after %0d)", ROB_DEPTH-1); errors++; end
    else $display("ok   not full after %0d allocs", ROB_DEPTH-1);
    alloc(1'b1, 5'd1, 5'd0, 1'b0);
    @(negedge clk); #1;
    if (!full) begin $display("FAIL not full after %0d allocs", ROB_DEPTH); errors++; end
    else $display("ok   full after %0d allocs", ROB_DEPTH);

    @(negedge clk); flush = 1'b1; @(posedge clk); #1; flush = 1'b0;
    @(negedge clk); #1;
    if (!empty) begin $display("FAIL not empty after flush"); errors++; end
    else $display("ok   empty after flush");

    // Selective squash: keep older + branch, drop younger
    alloc(1'b1, 5'd1, 5'd0, 1'b1); // tag 0
    alloc_control(5'd1);           // tag 1 branch
    alloc(1'b1, 5'd2, 5'd2, 1'b1); // tag 2 younger
    alloc(1'b1, 5'd3, 5'd3, 1'b1); // tag 3 younger
    @(negedge clk);
    squash_en = 1'b1; squash_tag = 5'd1;
    @(posedge clk); #1; squash_en = 1'b0;
    @(negedge clk); #1;
    if (free_count !== ROB_DEPTH - 2) begin
      $display("FAIL squash free_count=%0d expect %0d", free_count, ROB_DEPTH - 2);
      errors++;
    end else $display("ok   squash truncates younger (free=%0d)", free_count);
    wb(5'd0, 32'h1111_0001);
    commit_chk("commit older after squash", 5'd1, 32'h1111_0001);
    br_resolve(5'd1, 1'b1, 32'h80);
    complete2(5'd1);
    @(negedge clk); #1;
    if (!commit_valid[0] || !commit_is_control[0]) begin
      $display("FAIL branch survivor not ready to commit");
      errors++;
    end else $display("ok   branch survives squash");
    commit_do[0] = 1'b1; @(posedge clk); #1; commit_do = '0;
    @(negedge clk); #1;
    if (!empty) begin $display("FAIL not empty after squash drain"); errors++; end
    else $display("ok   empty after squash drain");

    if (errors == 0) $display("TB_ROB: PASS");
    else             $display("TB_ROB: FAIL (%0d errors)", errors);
    $finish;
  end
endmodule
