`timescale 1ns/1ps
// ============================================================================
// tb_backend.sv -- smoke test for the scalar backend spine.
// ============================================================================
module tb_backend;
  import pkg_cpu::*;

  logic clk = 1'b0, rst = 1'b1, flush_in = 1'b0;
  valid_bundle_t uop_valid = '0;
  logic [$clog2(WIDTH+1)-1:0] uop_accept_count;
  uop_bundle_t uop_in;
  logic flush, redirect_valid, cdb_overflow, backend_empty;
  pc_t redirect_pc;
  logic commit_valid, commit_rd_used;
  rob_tag_t commit_tag;
  reg_idx_t commit_rd;
  data_t commit_value;
  valid_bundle_t commit_valid_bundle;
  rob_tag_t commit_tag_bundle [WIDTH];
  logic commit_rd_used_bundle [WIDTH];
  reg_idx_t commit_rd_bundle [WIDTH];
  data_t commit_value_bundle [WIDTH];
  valid_bundle_t bp_update_valid, bp_update_taken;
  pc_t bp_update_pc [WIDTH], bp_update_target [WIDTH];
  valid_bundle_t mem_req_valid, mem_req_ready, mem_req_write, mem_resp_valid;
  data_t mem_req_addr [WIDTH], mem_req_wdata [WIDTH], mem_resp_rdata [WIDTH];
  logic [3:0] mem_req_wstrb [WIDTH];
  mem_id_t mem_req_id [WIDTH], mem_resp_id [WIDTH];
  logic cap_rd_used [16];
  reg_idx_t cap_rd  [16];
  data_t cap_value  [16];
  int cap_count = 0;
  int errors = 0;

  backend dut (
    .clk(clk), .rst(rst), .flush_in(flush_in),
    .uop_valid(uop_valid), .uop_accept_count(uop_accept_count), .uop_in(uop_in),
    .flush(flush), .redirect_valid(redirect_valid), .redirect_pc(redirect_pc),
    .commit_valid(commit_valid), .commit_tag(commit_tag),
    .commit_rd_used(commit_rd_used), .commit_rd(commit_rd), .commit_value(commit_value),
    .commit_valid_bundle(commit_valid_bundle), .commit_tag_bundle(commit_tag_bundle),
    .commit_rd_used_bundle(commit_rd_used_bundle), .commit_rd_bundle(commit_rd_bundle),
    .commit_value_bundle(commit_value_bundle),
    .bp_update_valid(bp_update_valid), .bp_update_pc(bp_update_pc),
    .bp_update_taken(bp_update_taken), .bp_update_target(bp_update_target),
    .mem_req_valid(mem_req_valid), .mem_req_ready(mem_req_ready),
    .mem_req_write(mem_req_write), .mem_req_addr(mem_req_addr),
    .mem_req_wdata(mem_req_wdata), .mem_req_wstrb(mem_req_wstrb),
    .mem_req_id(mem_req_id),
    .mem_resp_valid(mem_resp_valid), .mem_resp_rdata(mem_resp_rdata),
    .mem_resp_id(mem_resp_id),
    .backend_empty(backend_empty), .cdb_overflow(cdb_overflow)
  );

  dmem u_dmem (
    .clk(clk), .rst(rst),
    .mem_req_valid(mem_req_valid), .mem_req_ready(mem_req_ready),
    .mem_req_write(mem_req_write), .mem_req_addr(mem_req_addr),
    .mem_req_wdata(mem_req_wdata), .mem_req_wstrb(mem_req_wstrb),
    .mem_req_id(mem_req_id),
    .mem_resp_valid(mem_resp_valid), .mem_resp_rdata(mem_resp_rdata),
    .mem_resp_id(mem_resp_id)
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

  task automatic issue_current();
    for (int k = 0; k < 100; k++) begin
      @(negedge clk);
      uop_valid = '0;
      uop_valid[0] = 1'b1;
      #1;
      if (uop_accept_count != '0) begin
        @(posedge clk); #1;
        uop_valid = '0;
        for (int i = 0; i < WIDTH; i++) begin
          uop_in[i] = '0; uop_in[i].op = UOP_NOP; uop_in[i].fu = FU_ALU;
        end
        return;
      end
      @(posedge clk); #1;
    end
    $display("FAIL issue timeout"); errors++;
  endtask

  task automatic issue_addi(input reg_idx_t rd, input reg_idx_t rs1, input data_t imm);
    uop_in[0] = '0;
    uop_in[0].op = ALU_ADD; uop_in[0].fu = FU_ALU;
    uop_in[0].rs1_used = 1'b1; uop_in[0].rs1 = rs1;
    uop_in[0].rd_used = (rd != '0); uop_in[0].rd = rd;
    uop_in[0].imm = imm; uop_in[0].src2_is_imm = 1'b1;
    issue_current();
  endtask

  task automatic issue_mul(input reg_idx_t rd, input reg_idx_t rs1, input reg_idx_t rs2);
    uop_in[0] = '0;
    uop_in[0].op = MD_MUL; uop_in[0].fu = FU_MUL;
    uop_in[0].rs1_used = 1'b1; uop_in[0].rs1 = rs1;
    uop_in[0].rs2_used = 1'b1; uop_in[0].rs2 = rs2;
    uop_in[0].rd_used = (rd != '0); uop_in[0].rd = rd;
    issue_current();
  endtask

  task automatic issue_sw(input reg_idx_t base, input reg_idx_t data_reg, input data_t imm);
    uop_in[0] = '0;
    uop_in[0].op = MEM_SW; uop_in[0].fu = FU_MEM;
    uop_in[0].rs1_used = 1'b1; uop_in[0].rs1 = base;
    uop_in[0].rs2_used = 1'b1; uop_in[0].rs2 = data_reg;
    uop_in[0].imm = imm; uop_in[0].is_store = 1'b1; uop_in[0].mem_size = SZ_W;
    issue_current();
  endtask

  task automatic issue_lw(input reg_idx_t rd, input reg_idx_t base, input data_t imm);
    uop_in[0] = '0;
    uop_in[0].op = MEM_LW; uop_in[0].fu = FU_MEM;
    uop_in[0].rs1_used = 1'b1; uop_in[0].rs1 = base;
    uop_in[0].rd_used = (rd != '0); uop_in[0].rd = rd;
    uop_in[0].imm = imm; uop_in[0].is_load = 1'b1; uop_in[0].mem_size = SZ_W;
    issue_current();
  endtask

  task automatic wait_commits(input int n);
    for (int k = 0; k < 2000; k++) begin
      @(posedge clk); #1;
      if (cap_count >= n) return;
    end
    $display("FAIL commit timeout got=%0d exp=%0d", cap_count, n); errors++;
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
    for (int i = 0; i < WIDTH; i++) begin
      uop_in[i] = '0; uop_in[i].op = UOP_NOP; uop_in[i].fu = FU_ALU;
    end
    repeat (3) @(posedge clk); rst = 1'b0;

    issue_addi(5'd1, 5'd0, 32'd5);       // x1 = 5
    issue_addi(5'd2, 5'd1, 32'd3);       // x2 = x1 + 3 = 8
    issue_mul(5'd3, 5'd1, 5'd2);         // x3 = 40
    issue_sw(5'd0, 5'd3, 32'd0);         // mem[0] = 40
    issue_lw(5'd4, 5'd0, 32'd0);         // x4 = mem[0]
    wait_commits(5);
    chk_commit(0, "addi x1", 1'b1, 5'd1, 32'd5);
    chk_commit(1, "addi x2", 1'b1, 5'd2, 32'd8);
    chk_commit(2, "mul x3",  1'b1, 5'd3, 32'd40);
    chk_commit(3, "sw",      1'b0, 5'd0, '0);
    chk_commit(4, "lw x4",   1'b1, 5'd4, 32'd40);

    if (cdb_overflow) begin $display("FAIL cdb_overflow asserted"); errors++; end

    if (errors == 0) $display("TB_BACKEND: PASS");
    else             $display("TB_BACKEND: FAIL (%0d errors)", errors);
    $finish;
  end
endmodule
