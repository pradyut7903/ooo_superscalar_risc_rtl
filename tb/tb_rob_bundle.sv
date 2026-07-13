`timescale 1ns/1ps
// ============================================================================
// tb_rob_bundle.sv -- WIDTH-lane ROB allocate/commit checks.
// Run with WIDTH >= 4.  The default WIDTH=1 build reports SKIP.
// ============================================================================
module tb_rob_bundle;
  import pkg_cpu::*;

  logic clk = 1'b0, rst = 1'b1, flush = 1'b0;

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
    .squash_en(1'b0), .squash_tag('0),
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

  task automatic chk(input string name, input bit cond);
    if (!cond) begin $display("FAIL %s", name); errors++; end
    else       begin $display("ok   %s", name); end
  endtask

  task automatic clear_inputs();
    alloc_en = '0;
    commit_do = '0;
    wb_cdb = '{default:'0};
    complete_en = '0;
    complete2_en = 1'b0;
    br_resolve_en = 1'b0;
    for (int i = 0; i < WIDTH; i++) begin
      alloc_rd_used[i] = 1'b0;
      alloc_is_control[i] = 1'b0;
      alloc_is_store[i] = 1'b0;
      alloc_pc[i] = '0;
      alloc_dest[i] = '0;
      complete_tag[i] = '0;
      rd_tag1[i] = '0;
      rd_tag2[i] = '0;
    end
  endtask

  task automatic alloc4(input reg_idx_t d0, input reg_idx_t d1,
                        input reg_idx_t d2, input reg_idx_t d3);
    @(negedge clk);
    clear_inputs();
    alloc_en[3:0] = 4'b1111;
    alloc_rd_used[0] = 1'b1; alloc_dest[0] = d0;
    alloc_rd_used[1] = 1'b1; alloc_dest[1] = d1;
    alloc_rd_used[2] = 1'b1; alloc_dest[2] = d2;
    alloc_rd_used[3] = 1'b1; alloc_dest[3] = d3;
    #1;
    @(posedge clk); #1; clear_inputs();
  endtask

  task automatic wb_pair(input rob_tag_t t0, input data_t v0,
                         input rob_tag_t t1, input data_t v1);
    @(negedge clk);
    wb_cdb = '{default:'0};
    wb_cdb[0].valid = 1'b1; wb_cdb[0].tag = t0; wb_cdb[0].data = v0;
    wb_cdb[1].valid = 1'b1; wb_cdb[1].tag = t1; wb_cdb[1].data = v1;
    @(posedge clk); #1; wb_cdb = '{default:'0};
  endtask

  generate
    if (WIDTH >= 4) begin : gen_bundle_test
      initial begin
        clear_inputs();
        rst = 1'b1; repeat (2) @(posedge clk); rst = 1'b0; @(negedge clk); #1;
        chk("empty after reset", empty && (free_count == ROB_DEPTH));

        alloc4(5'd1, 5'd2, 5'd3, 5'd4);
        chk("next tags after alloc4", (alloc_tag[0] == 5'd4) && (alloc_tag[1] == 5'd5) &&
                                      (alloc_tag[2] == 5'd6) && (alloc_tag[3] == 5'd7));
        chk("free count after alloc4", free_count == ROB_DEPTH-4);

        wb_pair(5'd1, 32'h20, 5'd3, 32'h40);
        @(negedge clk); #1;
        chk("commit stops at not-done head", commit_valid == '0);

        wb_pair(5'd0, 32'h10, 5'd2, 32'h30);
        @(negedge clk); #1;
        chk("four commit lanes valid", commit_valid[3:0] == 4'b1111);
        chk("commit lane data", (commit_dest[0] == 5'd1) && (commit_value[0] == 32'h10) &&
                                (commit_dest[3] == 5'd4) && (commit_value[3] == 32'h40));

        commit_do[3:0] = 4'b1111;
        @(posedge clk); #1; commit_do = '0;
        @(negedge clk); #1;
        chk("empty after four-wide commit", empty && (free_count == ROB_DEPTH));

        alloc4(5'd5, 5'd6, 5'd7, 5'd8);
        wb_pair(5'd4, 32'h50, 5'd5, 32'h60);
        @(negedge clk);
        clear_inputs();
        alloc_en[1:0] = 2'b11;
        alloc_rd_used[0] = 1'b1; alloc_dest[0] = 5'd9;
        alloc_rd_used[1] = 1'b1; alloc_dest[1] = 5'd10;
        commit_do[1:0] = 2'b11;
        #1;
        chk("simultaneous alloc tags after tail", (alloc_tag[0] == 5'd8) && (alloc_tag[1] == 5'd9));
        @(posedge clk); #1; clear_inputs();
        @(negedge clk); #1;
        chk("count after simultaneous commit2 alloc2", free_count == ROB_DEPTH-4);

        flush = 1'b1; @(posedge clk); #1; flush = 1'b0;
        @(negedge clk); #1;
        chk("empty after flush", empty);

        @(negedge clk);
        clear_inputs();
        alloc_en[3:0] = 4'b1111;
        alloc_rd_used[0] = 1'b1; alloc_dest[0] = 5'd11;
        alloc_rd_used[1] = 1'b0; alloc_dest[1] = '0; alloc_is_control[1] = 1'b1;
        alloc_rd_used[2] = 1'b1; alloc_dest[2] = 5'd13;
        alloc_rd_used[3] = 1'b1; alloc_dest[3] = 5'd14;
        @(posedge clk); #1; clear_inputs();
        wb_pair(5'd0, 32'hA0, 5'd2, 32'hC0);
        wb_pair(5'd1, 32'hB0, 5'd3, 32'hD0);
        @(negedge clk);
        br_resolve_en = 1'b1;
        br_resolve_tag = 5'd1;
        br_mispredict = 1'b1;
        br_redirect_pc = 32'h80;
        complete2_en = 1'b1;
        complete2_tag = 5'd1;
        @(posedge clk); #1; br_resolve_en = 1'b0; complete2_en = 1'b0;
        @(negedge clk); #1;
        chk("mispredict branch truncates commit", commit_valid[3:0] == 4'b0011);
        chk("branch lane metadata", commit_is_control[1] && commit_mispredict[1] &&
                                    (commit_redirect_pc[1] == 32'h80));
        commit_do[3:0] = 4'b1111;
        @(posedge clk); #1; commit_do = '0;
        @(negedge clk); #1;
        chk("younger lanes after mispredict did not commit", !empty && (free_count == ROB_DEPTH-2));

        flush = 1'b1; @(posedge clk); #1; flush = 1'b0;
        @(negedge clk);
        clear_inputs();
        alloc_en[3:0] = 4'b1111;
        for (int i = 0; i < 4; i++) begin
          alloc_is_store[i] = 1'b1;
        end
        @(posedge clk); #1; clear_inputs();
        @(negedge clk); #1;
        chk("four store grants valid", commit_store_valid[3:0] == 4'b1111);
        chk("four store grant tags ordered", (commit_store_tag[0] == 5'd0) &&
                                             (commit_store_tag[3] == 5'd3));
        @(negedge clk);
        complete_en[3:0] = 4'b1111;
        for (int i = 0; i < 4; i++) complete_tag[i] = rob_tag_t'(i);
        @(posedge clk); #1; complete_en = '0;
        @(negedge clk); #1;
        chk("completed stores commit four-wide", commit_valid[3:0] == 4'b1111);

        if (errors == 0) $display("TB_ROB_BUNDLE: PASS");
        else             $display("TB_ROB_BUNDLE: FAIL (%0d errors)", errors);
        $finish;
      end
    end else begin : gen_skip
      initial begin
        $display("TB_ROB_BUNDLE: SKIP (WIDTH=%0d)", WIDTH);
        $finish;
      end
    end
  endgenerate
endmodule
