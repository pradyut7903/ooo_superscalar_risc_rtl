`timescale 1ns/1ps
// ============================================================================
// tb_icache.sv -- Miss/hit + N×N matrix LRU directed tests.
// ============================================================================
module tb_icache;
  import pkg_cpu::*;

  logic clk = 1'b0, rst = 1'b1, flush = 1'b0;
  logic req_valid = 1'b0, req_ready, resp_valid;
  pc_t req_pc = '0;
  valid_bundle_t resp_word_valid;
  instr_bundle_t resp_word;
  pc_bundle_t resp_pc;
  logic [$clog2(WIDTH+1)-1:0] resp_count;

  logic line_req_valid, line_req_ready, line_resp_valid;
  data_t line_req_addr;
  cache_line_t line_resp_rdata;
  logic [DRAM_MSHR_IDX_W-1:0] line_req_mshr, line_resp_mshr;

  logic dram_req_valid, dram_req_ready, dram_req_is_instr, dram_req_write;
  data_t dram_req_addr;
  cache_line_t dram_req_wdata, dram_resp_rdata;
  dram_id_t dram_req_id, dram_resp_id;
  logic dram_resp_valid;

  int errors = 0;
  data_t last_fill_addr;
  int fill_count;

  localparam pc_t SET_STRIDE = pc_t'(ICACHE_SETS * CACHE_LINE_BYTES);

  icache u_ic (
    .clk(clk), .rst(rst), .flush(flush),
    .req_valid(req_valid), .req_ready(req_ready), .req_pc(req_pc),
    .resp_valid(resp_valid), .resp_word_valid(resp_word_valid),
    .resp_word(resp_word), .resp_pc(resp_pc), .resp_count(resp_count),
    .line_req_valid(line_req_valid), .line_req_ready(line_req_ready),
    .line_req_addr(line_req_addr), .line_req_mshr(line_req_mshr),
    .line_resp_valid(line_resp_valid), .line_resp_rdata(line_resp_rdata),
    .line_resp_mshr(line_resp_mshr)
  );

  mem_arbiter u_arb (
    .clk(clk), .rst(rst),
    .i_req_valid(line_req_valid), .i_req_ready(line_req_ready),
    .i_req_write(1'b0), .i_req_addr(line_req_addr), .i_req_wdata('0),
    .i_req_mshr(line_req_mshr),
    .i_resp_valid(line_resp_valid), .i_resp_rdata(line_resp_rdata),
    .i_resp_mshr(line_resp_mshr),
    .d_req_valid(1'b0), .d_req_ready(), .d_req_write(1'b0),
    .d_req_addr('0), .d_req_wdata('0), .d_req_mshr('0),
    .d_resp_valid(), .d_resp_rdata(), .d_resp_mshr(),
    .dram_req_valid(dram_req_valid), .dram_req_ready(dram_req_ready),
    .dram_req_is_instr(dram_req_is_instr), .dram_req_write(dram_req_write),
    .dram_req_addr(dram_req_addr), .dram_req_wdata(dram_req_wdata),
    .dram_req_id(dram_req_id),
    .dram_resp_valid(dram_resp_valid), .dram_resp_rdata(dram_resp_rdata),
    .dram_resp_id(dram_resp_id)
  );

  dram_model #(.LAT(2)) u_dram (
    .clk(clk), .rst(rst),
    .req_valid(dram_req_valid), .req_ready(dram_req_ready),
    .req_is_instr(dram_req_is_instr), .req_write(dram_req_write),
    .req_line_addr(dram_req_addr), .req_wdata(dram_req_wdata),
    .req_id(dram_req_id),
    .resp_valid(dram_resp_valid), .resp_rdata(dram_resp_rdata),
    .resp_id(dram_resp_id)
  );

  always #5 clk = ~clk;

  always @(posedge clk) begin
    if (!rst && line_req_valid && line_req_ready) begin
      last_fill_addr <= line_req_addr;
      fill_count <= fill_count + 1;
    end
  end

  task automatic fetch_at(input pc_t pc, output instr_t word);
    @(negedge clk);
    req_pc = pc;
    req_valid = 1'b1;
    while (!req_ready) @(posedge clk);
    @(posedge clk);
    @(negedge clk);
    req_valid = 1'b0;
    for (int k = 0; k < 200; k++) begin
      @(posedge clk);
      if (resp_valid) begin
        word = resp_word[0];
        return;
      end
    end
    $display("FAIL icache timeout pc=%h", pc);
    errors++;
    word = INSTR_INVALID;
  endtask

  initial begin
    instr_t w;
    pc_t p0, p1, p2, p3, p4;
    int fills_before;

    // Seed unique instruction words. Leave word0 as smoke until LRU section.
    for (int i = 0; i < IMEM_DEPTH; i++) u_dram.g_simple.u.imem[i] = INSTR_INVALID;
    u_dram.g_simple.u.imem[0] = 32'h00500093;
    for (int k = 1; k < 5; k++) begin
      int unsigned base;
      base = (k * int'(SET_STRIDE)) / 4;
      if (base < IMEM_DEPTH)
        u_dram.g_simple.u.imem[base] = 32'h11110000 + k;
    end

    fill_count = 0;
    last_fill_addr = '0;
    repeat (3) @(posedge clk);
    rst = 1'b0;

    fetch_at(32'h0, w);
    if (w !== 32'h00500093) begin
      $display("FAIL miss fill word=%h", w); errors++;
    end else $display("ok   icache miss fill");

    fills_before = fill_count;
    fetch_at(32'h0, w);
    if (w !== 32'h00500093) begin
      $display("FAIL hit word=%h", w); errors++;
    end else if (fill_count != fills_before) begin
      $display("FAIL hit caused line fill"); errors++;
    end else $display("ok   icache hit");

    if (resp_count == '0) begin
      $display("FAIL resp_count=0"); errors++;
    end

    // ---- LRU ----
    if (ICACHE_WAYS < 4) begin
      $display("TB_ICACHE: SKIP LRU (WAYS=%0d)", ICACHE_WAYS);
    end else begin
      // Reseed set-conflicting lines including PC 0.
      for (int k = 0; k < 5; k++) begin
        int unsigned base;
        base = (k * int'(SET_STRIDE)) / 4;
        if (base < IMEM_DEPTH)
          u_dram.g_simple.u.imem[base] = 32'h11110000 + k;
      end

      rst = 1'b1;
      fill_count = 0;
      repeat (2) @(posedge clk);
      rst = 1'b0;
      repeat (2) @(posedge clk);

      p0 = '0;
      p1 = SET_STRIDE;
      p2 = SET_STRIDE * 2;
      p3 = SET_STRIDE * 3;
      p4 = SET_STRIDE * 4;

      fetch_at(p0, w);
      fetch_at(p1, w);
      fetch_at(p2, w);
      fetch_at(p3, w);
      // Touch p1,p2,p3 => p0 LRU
      fetch_at(p1, w);
      fetch_at(p2, w);
      fetch_at(p3, w);

      fills_before = fill_count;
      fetch_at(p4, w); // should miss and replace p0
      if (fill_count != fills_before + 1) begin
        $display("FAIL LRU expected one fill for p4 got +%0d", fill_count - fills_before);
        errors++;
      end else if (last_fill_addr !== p4) begin
        $display("FAIL LRU fill addr=%h exp=%h", last_fill_addr, p4); errors++;
      end else $display("ok   LRU miss fill for newest");

      if (w !== (32'h11110000 + 4)) begin
        $display("FAIL LRU p4 word=%h", w); errors++;
      end

      // p1 should still hit (no new fill)
      fills_before = fill_count;
      fetch_at(p1, w);
      if (fill_count != fills_before) begin
        $display("FAIL LRU p1 should hit"); errors++;
      end else if (w !== (32'h11110000 + 1)) begin
        $display("FAIL LRU p1 word=%h", w); errors++;
      end else $display("ok   LRU retained younger line");

      // p0 should miss (evicted)
      fills_before = fill_count;
      fetch_at(p0, w);
      if (fill_count != fills_before + 1) begin
        $display("FAIL LRU p0 should miss after eviction"); errors++;
      end else if (w !== 32'h11110000) begin
        $display("FAIL LRU reloaded p0 word=%h", w); errors++;
      end else $display("ok   LRU victim reloaded");
    end

    if (errors == 0) $display("TB_ICACHE: PASS");
    else             $display("TB_ICACHE: FAIL (%0d)", errors);
    $finish;
  end
endmodule
