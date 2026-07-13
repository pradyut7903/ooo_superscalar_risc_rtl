`timescale 1ns/1ps
// ============================================================================
// tb_lsq_ooo.sv -- out-of-order LSQ and store-to-load forwarding tests.
// ============================================================================
module tb_lsq_ooo;
  import pkg_cpu::*;

  logic clk = 1'b0, rst = 1'b1, flush = 1'b0;
  valid_bundle_t dispatch_valid = '0, dispatch_ready;
  uop_bundle_t dispatch_uop;
  rob_tag_t dispatch_tag [WIDTH];
  operand_t dispatch_base [WIDTH], dispatch_store_data [WIDTH];
  cdb_bus_t cdb_in = '{default:'0};
  cdb_t out_cdb [NUM_LSQ];
  valid_bundle_t commit_store_valid = '0;
  rob_tag_t commit_store_tag [WIDTH];
  valid_bundle_t mem_req_valid, mem_req_ready, mem_req_write, mem_resp_valid;
  data_t mem_req_addr [WIDTH], mem_req_wdata [WIDTH], mem_resp_rdata [WIDTH];
  logic [3:0] mem_req_wstrb [WIDTH];
  mem_id_t mem_req_id [WIDTH], mem_resp_id [WIDTH];
  logic cdb_ready [NUM_LSQ];
  logic full, empty;
  valid_bundle_t store_complete_valid;
  rob_tag_t store_complete_tag [WIDTH];
  int errors = 0;

  lsq u_lsq (
    .clk(clk), .rst(rst), .flush(flush),
    .squash_en(1'b0), .squash_tag('0), .rob_head('0),
    .dispatch_valid(dispatch_valid), .dispatch_ready(dispatch_ready),
    .dispatch_uop(dispatch_uop), .dispatch_tag(dispatch_tag),
    .dispatch_base(dispatch_base), .dispatch_store_data(dispatch_store_data),
    .cdb_in(cdb_in),
    .commit_store_valid(commit_store_valid), .commit_store_tag(commit_store_tag),
    .mem_req_valid(mem_req_valid), .mem_req_ready(mem_req_ready),
    .mem_req_write(mem_req_write), .mem_req_addr(mem_req_addr),
    .mem_req_wdata(mem_req_wdata), .mem_req_wstrb(mem_req_wstrb),
    .mem_req_id(mem_req_id),
    .mem_resp_valid(mem_resp_valid), .mem_resp_rdata(mem_resp_rdata),
    .mem_resp_id(mem_resp_id),
    .cdb_ready(cdb_ready), .out_cdb(out_cdb),
    .store_complete_valid(store_complete_valid), .store_complete_tag(store_complete_tag),
    .full(full), .empty(empty)
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

  task automatic op_ready(output operand_t opnd, input data_t value);
    opnd.ready = 1'b1; opnd.tag = '0; opnd.value = value;
  endtask

  task automatic op_wait(output operand_t opnd, input rob_tag_t tag);
    opnd.ready = 1'b0; opnd.tag = tag; opnd.value = '0;
  endtask

  task automatic dispatch_mem(input bit is_load, input memsz_e size, input bit unsign,
                              input rob_tag_t tag, input operand_t base,
                              input data_t imm, input operand_t store_data);
    @(negedge clk);
    dispatch_valid = '0;
    dispatch_uop[0] = '0;
    dispatch_uop[0].fu = FU_MEM;
    dispatch_uop[0].is_load = is_load;
    dispatch_uop[0].is_store = !is_load;
    dispatch_uop[0].mem_size = size;
    dispatch_uop[0].mem_unsigned = unsign;
    dispatch_uop[0].imm = imm;
    dispatch_tag[0] = tag;
    dispatch_base[0] = base;
    dispatch_store_data[0] = store_data;
    dispatch_valid[0] = 1'b1;
    @(posedge clk); #1;
    if (!dispatch_ready[0]) begin
      $display("FAIL dispatch not ready tag=%0d", tag);
      errors++;
    end
    dispatch_valid = '0;
  endtask

  task automatic pulse_cdb(input rob_tag_t tag, input data_t data);
    @(negedge clk);
    cdb_in[0].valid = 1'b1;
    cdb_in[0].tag = tag;
    cdb_in[0].data = data;
    @(posedge clk); #1;
    cdb_in = '{default:'0};
  endtask

  task automatic wait_cdb(input string name, input rob_tag_t tag, input data_t data);
    repeat (12) begin
      @(posedge clk); #1;
      for (int lane = 0; lane < NUM_LSQ; lane++) begin
        if (out_cdb[lane].valid) begin
          if ((out_cdb[lane].tag !== tag) || (out_cdb[lane].data !== data)) begin
          $display("FAIL %-22s tag=%0d data=%h exp_tag=%0d exp=%h",
                   name, out_cdb[lane].tag, out_cdb[lane].data, tag, data);
          errors++;
          end else begin
            $display("ok   %-22s tag=%0d data=%h", name, out_cdb[lane].tag, out_cdb[lane].data);
          end
          return;
        end
      end
    end
    $display("FAIL %-22s no CDB result", name);
    errors++;
  endtask

  task automatic expect_quiet(input string name, input int cycles);
    repeat (cycles) begin
      bit any_cdb;
      bit any_mem;
      data_t first_addr;
      @(posedge clk); #1;
      any_cdb = 1'b0;
      any_mem = 1'b0;
      first_addr = '0;
      for (int lane = 0; lane < NUM_LSQ; lane++) begin
        any_cdb |= out_cdb[lane].valid;
        if (mem_req_valid[lane]) begin
          any_mem = 1'b1;
          first_addr = mem_req_addr[lane];
        end
      end
      if (any_cdb || any_mem) begin
        $display("FAIL %-22s unexpected cdb=%0b mem_req=%0b write=%0b addr=%h",
                 name, any_cdb, any_mem, mem_req_write[0], first_addr);
        errors++;
        return;
      end
    end
    $display("ok   %-22s quiet", name);
  endtask

  initial begin
    operand_t rdy_base, rdy_data, wait_data, load_base;

    dispatch_valid = '0;
    for (int i = 0; i < WIDTH; i++) begin
      dispatch_uop[i] = '0;
      dispatch_base[i] = '0;
      dispatch_store_data[i] = '0;
      dispatch_tag[i] = '0;
      commit_store_tag[i] = '0;
    end
    for (int i = 0; i < NUM_LSQ; i++) cdb_ready[i] = 1'b1;
    repeat (2) @(posedge clk);
    rst = 1'b0;

    // A younger load to the same word forwards from an older uncommitted store.
    op_ready(rdy_base, 32'd0);
    op_ready(rdy_data, 32'h1122_3344);
    dispatch_mem(1'b0, SZ_W, 1'b0, 5'd1, rdy_base, 32'd0, rdy_data);
    dispatch_mem(1'b1, SZ_W, 1'b0, 5'd2, rdy_base, 32'd0, '0);
    wait_cdb("forward word", 5'd2, 32'h1122_3344);

    // Retire the forwarded store so it no longer blocks later checks.
    @(negedge clk); commit_store_valid = '0; commit_store_valid[0] = 1'b1; commit_store_tag[0] = 5'd1;
    begin
      automatic bit got = 1'b0;
      for (int k = 0; k < 8; k++) begin
        @(posedge clk); #1;
        if (k == 0) commit_store_valid = '0;
        if (store_complete_valid[0] && (store_complete_tag[0] === 5'd1)) begin
          got = 1'b1; break;
        end
      end
      if (!got) begin
        $display("FAIL store1 complete valid=%0b tag=%0d", store_complete_valid[0], store_complete_tag[0]);
        errors++;
      end else $display("ok   store1 complete tag=%0d", store_complete_tag[0]);
    end

    // A load waits behind an older store whose data is not yet resolved, even
    // when that store's address is different.
    op_ready(rdy_base, 32'd16);
    op_wait(wait_data, 5'd10);
    dispatch_mem(1'b0, SZ_W, 1'b0, 5'd3, rdy_base, 32'd0, wait_data);
    op_ready(load_base, 32'd32);
    dispatch_mem(1'b1, SZ_W, 1'b0, 5'd4, load_base, 32'd0, '0);
    expect_quiet("wait unresolved store", 4);

    pulse_cdb(5'd10, 32'hCAFE_BABE);
    wait_cdb("load after wake", 5'd4, 32'h0000_0000);

    // The same older store is resolved but still uncommitted.  A younger load
    // to a nonmatching address may issue out of order.
    op_ready(load_base, 32'd64);
    dispatch_mem(1'b1, SZ_W, 1'b0, 5'd5, load_base, 32'd0, '0);
    wait_cdb("ooo nonmatch load", 5'd5, 32'h0000_0000);

    @(negedge clk); commit_store_valid = '0; commit_store_valid[0] = 1'b1; commit_store_tag[0] = 5'd3;
    begin
      automatic bit got = 1'b0;
      for (int k = 0; k < 8; k++) begin
        @(posedge clk); #1;
        if (k == 0) commit_store_valid = '0;
        if (store_complete_valid[0] && (store_complete_tag[0] === 5'd3)) begin
          got = 1'b1; break;
        end
      end
      if (!got) begin
        $display("FAIL store3 complete valid=%0b tag=%0d", store_complete_valid[0], store_complete_tag[0]);
        errors++;
      end else $display("ok   store3 complete tag=%0d", store_complete_tag[0]);
    end

    // Byte stores forward only their covered byte and loads apply sign/zero extension.
    op_ready(rdy_base, 32'd80);
    op_ready(rdy_data, 32'h0000_0080);
    dispatch_mem(1'b0, SZ_B, 1'b0, 5'd6, rdy_base, 32'd0, rdy_data);
    dispatch_mem(1'b1, SZ_B, 1'b0, 5'd7, rdy_base, 32'd0, '0);
    wait_cdb("forward lb", 5'd7, 32'hffff_ff80);
    dispatch_mem(1'b1, SZ_B, 1'b1, 5'd8, rdy_base, 32'd0, '0);
    wait_cdb("forward lbu", 5'd8, 32'h0000_0080);

    @(negedge clk); commit_store_valid = '0; commit_store_valid[0] = 1'b1; commit_store_tag[0] = 5'd6;
    begin
      automatic bit got = 1'b0;
      for (int k = 0; k < 8; k++) begin
        @(posedge clk); #1;
        if (k == 0) commit_store_valid = '0;
        if (store_complete_valid[0] && (store_complete_tag[0] === 5'd6)) begin
          got = 1'b1; break;
        end
      end
      if (!got) begin
        $display("FAIL store6 complete valid=%0b tag=%0d", store_complete_valid[0], store_complete_tag[0]);
        errors++;
      end else $display("ok   store6 complete tag=%0d", store_complete_tag[0]);
    end

    if (errors == 0) $display("TB_LSQ_OOO: PASS");
    else             $display("TB_LSQ_OOO: FAIL (%0d errors)", errors);
    $finish;
  end
endmodule
