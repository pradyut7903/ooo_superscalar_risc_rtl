`timescale 1ns/1ps
// ============================================================================
// tb_dcache.sv -- Hit/miss/WA/WB + N×N matrix LRU directed tests.
// ============================================================================
module tb_dcache;
  import pkg_cpu::*;

  logic clk = 1'b0, rst = 1'b1, flush = 1'b0;
  valid_bundle_t mem_req_valid = '0, mem_req_ready, mem_req_write = '0, mem_resp_valid;
  data_t mem_req_addr [WIDTH], mem_req_wdata [WIDTH], mem_resp_rdata [WIDTH];
  logic [3:0] mem_req_wstrb [WIDTH];
  mem_id_t mem_req_id [WIDTH], mem_resp_id [WIDTH];

  logic line_req_valid, line_req_ready, line_req_write, line_resp_valid;
  data_t line_req_addr;
  cache_line_t line_req_wdata, line_resp_rdata;
  logic [DRAM_MSHR_IDX_W-1:0] line_req_mshr, line_resp_mshr;

  logic dram_req_valid, dram_req_ready, dram_req_is_instr, dram_req_write;
  data_t dram_req_addr;
  cache_line_t dram_req_wdata;
  dram_id_t dram_req_id, dram_resp_id;
  logic dram_resp_valid;
  cache_line_t dram_resp_rdata;

  int errors = 0;
  data_t last_wb_addr;
  bit saw_wb;

  // Same-set stride: SETS * line bytes
  localparam data_t SET_STRIDE = data_t'(DCACHE_SETS * CACHE_LINE_BYTES);

  dcache u_dc (
    .clk(clk), .rst(rst), .flush(flush),
    .mem_req_valid(mem_req_valid), .mem_req_ready(mem_req_ready),
    .mem_req_write(mem_req_write), .mem_req_addr(mem_req_addr),
    .mem_req_wdata(mem_req_wdata), .mem_req_wstrb(mem_req_wstrb),
    .mem_req_id(mem_req_id),
    .mem_resp_valid(mem_resp_valid), .mem_resp_rdata(mem_resp_rdata),
    .mem_resp_id(mem_resp_id),
    .line_req_valid(line_req_valid), .line_req_ready(line_req_ready),
    .line_req_write(line_req_write), .line_req_addr(line_req_addr),
    .line_req_wdata(line_req_wdata), .line_req_mshr(line_req_mshr),
    .line_resp_valid(line_resp_valid), .line_resp_rdata(line_resp_rdata),
    .line_resp_mshr(line_resp_mshr)
  );

  mem_arbiter u_arb (
    .clk(clk), .rst(rst),
    .i_req_valid(1'b0), .i_req_ready(), .i_req_write(1'b0),
    .i_req_addr('0), .i_req_wdata('0), .i_req_mshr('0),
    .i_resp_valid(), .i_resp_rdata(), .i_resp_mshr(),
    .d_req_valid(line_req_valid), .d_req_ready(line_req_ready),
    .d_req_write(line_req_write), .d_req_addr(line_req_addr),
    .d_req_wdata(line_req_wdata), .d_req_mshr(line_req_mshr),
    .d_resp_valid(line_resp_valid), .d_resp_rdata(line_resp_rdata),
    .d_resp_mshr(line_resp_mshr),
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
    if (!rst && line_req_valid && line_req_ready && line_req_write) begin
      last_wb_addr <= line_req_addr;
      saw_wb <= 1'b1;
    end
  end

  task automatic cpu_op(
    input logic is_write, input data_t addr, input data_t wdata,
    input logic [3:0] wstrb, input mem_id_t id,
    output data_t rdata, output mem_id_t rid
  );
    @(negedge clk);
    mem_req_valid = '0;
    mem_req_valid[0] = 1'b1;
    mem_req_write[0] = is_write;
    mem_req_addr[0] = addr;
    mem_req_wdata[0] = wdata;
    mem_req_wstrb[0] = wstrb;
    mem_req_id[0] = id;
    for (int k = 0; k < 200; k++) begin
      @(posedge clk);
      #1;
      if (mem_req_ready[0]) begin
        @(negedge clk);
        mem_req_valid = '0;
        break;
      end
    end
    for (int k = 0; k < 400; k++) begin
      @(posedge clk);
      if (mem_resp_valid[0]) begin
        rdata = mem_resp_rdata[0];
        rid = mem_resp_id[0];
        return;
      end
    end
    $display("FAIL cpu_op timeout addr=%h", addr);
    errors++;
    rdata = '0; rid = '0;
  endtask

  initial begin
    data_t rdata;
    mem_id_t rid;
    data_t a0, a1, a2, a3, a4;
    for (int i = 0; i < WIDTH; i++) begin
      mem_req_addr[i] = '0;
      mem_req_wdata[i] = '0;
      mem_req_wstrb[i] = 4'hF;
      mem_req_id[i] = '0;
    end
    last_wb_addr = '0;
    saw_wb = 1'b0;
    repeat (3) @(posedge clk);
    rst = 1'b0;

    // ---- basic hit/miss ----
    cpu_op(1'b1, 32'h100, 32'hCAFEBABE, 4'hF, mem_id_t'(1), rdata, rid);
    if (rid !== mem_id_t'(1)) begin $display("FAIL store id"); errors++; end
    else $display("ok   miss store");

    cpu_op(1'b0, 32'h100, '0, 4'h0, mem_id_t'(2), rdata, rid);
    if (rdata !== 32'hCAFEBABE || rid !== mem_id_t'(2)) begin
      $display("FAIL hit load got %h id=%0d", rdata, rid); errors++;
    end else $display("ok   hit load");

    cpu_op(1'b1, 32'h104, 32'h11223344, 4'hF, mem_id_t'(3), rdata, rid);
    cpu_op(1'b0, 32'h104, '0, 4'h0, mem_id_t'(4), rdata, rid);
    if (rdata !== 32'h11223344) begin
      $display("FAIL hit store/load %h", rdata); errors++;
    end else $display("ok   hit store");

    // ---- N×N matrix LRU ----
    // Flush cache by reset so set 0 starts empty.
    rst = 1'b1;
    saw_wb = 1'b0;
    repeat (2) @(posedge clk);
    rst = 1'b0;
    repeat (2) @(posedge clk);

    if (DCACHE_WAYS < 4) begin
      $display("TB_DCACHE: SKIP LRU (WAYS=%0d)", DCACHE_WAYS);
    end else begin
      a0 = 32'h0;
      a1 = SET_STRIDE;
      a2 = SET_STRIDE * 2;
      a3 = SET_STRIDE * 3;
      a4 = SET_STRIDE * 4;

      // Fill 4 ways of set 0 (install order => a0 becomes LRU after later touches).
      cpu_op(1'b1, a0, 32'hA000_0000, 4'hF, mem_id_t'(10), rdata, rid);
      cpu_op(1'b1, a1, 32'hA111_1111, 4'hF, mem_id_t'(11), rdata, rid);
      cpu_op(1'b1, a2, 32'hA222_2222, 4'hF, mem_id_t'(12), rdata, rid);
      cpu_op(1'b1, a3, 32'hA333_3333, 4'hF, mem_id_t'(13), rdata, rid);

      // Touch a1,a2,a3 so a0 is LRU.
      cpu_op(1'b0, a1, '0, 4'h0, mem_id_t'(14), rdata, rid);
      cpu_op(1'b0, a2, '0, 4'h0, mem_id_t'(15), rdata, rid);
      cpu_op(1'b0, a3, '0, 4'h0, mem_id_t'(16), rdata, rid);

      saw_wb = 1'b0;
      // Miss on a4: must writeback dirty a0 then allocate a4.
      cpu_op(1'b1, a4, 32'hA444_4444, 4'hF, mem_id_t'(17), rdata, rid);
      if (!saw_wb) begin
        $display("FAIL LRU expected writeback of victim"); errors++;
      end else if (last_wb_addr !== a0) begin
        $display("FAIL LRU victim wb addr=%h exp=%h", last_wb_addr, a0); errors++;
      end else $display("ok   LRU evicted oldest (wb %h)", last_wb_addr);

      // a1..a3 still hit; a0 misses (refills from DRAM after WB).
      cpu_op(1'b0, a1, '0, 4'h0, mem_id_t'(18), rdata, rid);
      if (rdata !== 32'hA111_1111) begin
        $display("FAIL LRU retained a1 got %h", rdata); errors++;
      end
      cpu_op(1'b0, a4, '0, 4'h0, mem_id_t'(19), rdata, rid);
      if (rdata !== 32'hA444_4444) begin
        $display("FAIL LRU new line a4 got %h", rdata); errors++;
      end else $display("ok   LRU new line present");

      // a0 should still be readable from DRAM after writeback.
      cpu_op(1'b0, a0, '0, 4'h0, mem_id_t'(20), rdata, rid);
      if (rdata !== 32'hA000_0000) begin
        $display("FAIL LRU reloaded a0 got %h", rdata); errors++;
      end else $display("ok   LRU victim reloaded from DRAM");
    end

    // ---- dual-UFP same-cycle store-store hit merge (same line, diff words) ----
    if (DCACHE_UFP_PORTS >= 2 && WIDTH >= 2) begin
      data_t r0, r1;
      bit got0, got1;
      rst = 1'b1;
      repeat (2) @(posedge clk);
      rst = 1'b0;
      repeat (2) @(posedge clk);

      // Install line with known pattern, then dual hit-stores in one cycle.
      cpu_op(1'b1, 32'h400, 32'h1111_1111, 4'hF, mem_id_t'(40), rdata, rid);
      cpu_op(1'b1, 32'h404, 32'h2222_2222, 4'hF, mem_id_t'(41), rdata, rid);

      @(negedge clk);
      mem_req_valid = '0;
      mem_req_valid[0] = 1'b1;
      mem_req_valid[1] = 1'b1;
      mem_req_write[0] = 1'b1;
      mem_req_write[1] = 1'b1;
      mem_req_addr[0] = 32'h400;
      mem_req_addr[1] = 32'h404;
      mem_req_wdata[0] = 32'hAAAA_AAAA;
      mem_req_wdata[1] = 32'hBBBB_BBBB;
      mem_req_wstrb[0] = 4'hF;
      mem_req_wstrb[1] = 4'hF;
      mem_req_id[0] = mem_id_t'(42);
      mem_req_id[1] = mem_id_t'(43);
      for (int k = 0; k < 50; k++) begin
        @(posedge clk); #1;
        if (mem_req_ready[0] && mem_req_ready[1]) begin
          @(negedge clk);
          mem_req_valid = '0;
          break;
        end
      end
      // Wait for both store acks
      got0 = 1'b0; got1 = 1'b0;
      for (int k = 0; k < 50; k++) begin
        @(posedge clk);
        for (int lane = 0; lane < WIDTH; lane++) begin
          if (mem_resp_valid[lane]) begin
            if (mem_resp_id[lane] == mem_id_t'(42)) got0 = 1'b1;
            if (mem_resp_id[lane] == mem_id_t'(43)) got1 = 1'b1;
          end
        end
        if (got0 && got1) break;
      end
      if (!got0 || !got1) begin
        $display("FAIL dual store-hit ack got0=%0d got1=%0d", got0, got1);
        errors++;
      end

      cpu_op(1'b0, 32'h400, '0, 4'h0, mem_id_t'(44), rdata, rid);
      if (rdata !== 32'hAAAA_AAAA) begin
        $display("FAIL dual store-hit word0 got %h exp AAAAAAAA", rdata);
        errors++;
      end
      cpu_op(1'b0, 32'h404, '0, 4'h0, mem_id_t'(45), rdata, rid);
      if (rdata !== 32'hBBBB_BBBB) begin
        $display("FAIL dual store-hit word1 got %h exp BBBBBBBB", rdata);
        errors++;
      end else if (got0 && got1)
        $display("ok   dual-UFP same-cycle store-store hit merge");
    end

    // ---- dual-UFP same-cycle secondary miss (PORTS>=2) ----
    if (DCACHE_UFP_PORTS >= 2 && WIDTH >= 2) begin
      data_t r0, r1;
      bit got0, got1;
      rst = 1'b1;
      repeat (2) @(posedge clk);
      rst = 1'b0;
      repeat (2) @(posedge clk);

      // Primary miss on line 0x200
      cpu_op(1'b0, 32'h200, '0, 4'h0, mem_id_t'(30), rdata, rid);
      // After fill, force a fresh miss again then dual secondary in one cycle:
      // invalidate via reset and miss once to allocate MSHR, then dual-load.
      rst = 1'b1;
      repeat (2) @(posedge clk);
      rst = 1'b0;
      repeat (2) @(posedge clk);

      // Kick primary miss (single lane), leave it in-flight, then dual secondary.
      @(negedge clk);
      mem_req_valid = '0;
      mem_req_valid[0] = 1'b1;
      mem_req_write[0] = 1'b0;
      mem_req_addr[0] = 32'h300;
      mem_req_id[0] = mem_id_t'(31);
      for (int k = 0; k < 50; k++) begin
        @(posedge clk); #1;
        if (mem_req_ready[0]) begin
          @(negedge clk);
          mem_req_valid = '0;
          break;
        end
      end
      // Same cycle: two loads to same line (secondary merge must not collide)
      @(negedge clk);
      mem_req_valid = '0;
      mem_req_valid[0] = 1'b1;
      mem_req_valid[1] = 1'b1;
      mem_req_write[0] = 1'b0;
      mem_req_write[1] = 1'b0;
      mem_req_addr[0] = 32'h300;
      mem_req_addr[1] = 32'h304;
      mem_req_id[0] = mem_id_t'(32);
      mem_req_id[1] = mem_id_t'(33);
      for (int k = 0; k < 50; k++) begin
        @(posedge clk); #1;
        if (mem_req_ready[0] && mem_req_ready[1]) begin
          @(negedge clk);
          mem_req_valid = '0;
          break;
        end
      end
      got0 = 1'b0; got1 = 1'b0; r0 = '0; r1 = '0;
      for (int k = 0; k < 400; k++) begin
        @(posedge clk);
        for (int lane = 0; lane < WIDTH; lane++) begin
          if (mem_resp_valid[lane]) begin
            if (mem_resp_id[lane] == mem_id_t'(32)) begin got0 = 1'b1; r0 = mem_resp_rdata[lane]; end
            if (mem_resp_id[lane] == mem_id_t'(33)) begin got1 = 1'b1; r1 = mem_resp_rdata[lane]; end
            if (mem_resp_id[lane] == mem_id_t'(31)) begin /* primary */ end
          end
        end
        if (got0 && got1) break;
      end
      if (!got0 || !got1)
        begin $display("FAIL dual secondary timeout got0=%0d got1=%0d", got0, got1); errors++; end
      else $display("ok   dual-UFP same-cycle secondary");
    end

    if (errors == 0) $display("TB_DCACHE: PASS");
    else             $display("TB_DCACHE: FAIL (%0d)", errors);
    $finish;
  end
endmodule
