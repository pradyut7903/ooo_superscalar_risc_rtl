`timescale 1ns/1ps
// ============================================================================
// tb_lsq_ooo_stress.sv -- deeper ordering/forwarding checks for rtl_v2 LSQ.
// ============================================================================
module tb_lsq_ooo_stress;
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
  bit saw_load_mem_read;
  data_t saw_load_mem_addr;

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

  // Latch load mem requests (valid only in the issue cycle before ST_MEM_RESP).
  always @(posedge clk) begin
    if (!rst) begin
      for (int lane = 0; lane < WIDTH; lane++) begin
        if (mem_req_valid[lane] && !mem_req_write[lane]) begin
          saw_load_mem_read <= 1'b1;
          saw_load_mem_addr <= mem_req_addr[lane];
        end
      end
    end
  end

  task automatic op_ready(output operand_t opnd, input data_t value);
    opnd.ready = 1'b1; opnd.tag = '0; opnd.value = value;
  endtask

  task automatic dispatch_mem(input bit is_load, input memsz_e size, input bit unsign,
                              input rob_tag_t tag, input data_t base,
                              input data_t imm, input data_t store_data);
    operand_t base_op;
    operand_t data_op;
    op_ready(base_op, base);
    op_ready(data_op, store_data);

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
    dispatch_base[0] = base_op;
    dispatch_store_data[0] = data_op;
    dispatch_valid[0] = 1'b1;
    @(posedge clk); #1;
    if (!dispatch_ready[0]) begin
      $display("FAIL dispatch not ready tag=%0d", tag);
      errors++;
    end
    dispatch_valid = '0;
  endtask

  task automatic wait_cdb(input string name, input rob_tag_t tag, input data_t data);
    repeat (16) begin
      @(posedge clk); #1;
      for (int lane = 0; lane < NUM_LSQ; lane++) begin
        if (out_cdb[lane].valid) begin
          if ((out_cdb[lane].tag !== tag) || (out_cdb[lane].data !== data)) begin
          $display("FAIL %-24s tag=%0d data=%h exp_tag=%0d exp=%h",
                   name, out_cdb[lane].tag, out_cdb[lane].data, tag, data);
          errors++;
          end else begin
            $display("ok   %-24s tag=%0d data=%h", name, out_cdb[lane].tag, out_cdb[lane].data);
          end
          return;
        end
      end
    end
    $display("FAIL %-24s no CDB result", name);
    errors++;
  endtask

  task automatic chk_saw_mem_read(input string name, input data_t addr);
    if (!saw_load_mem_read || (saw_load_mem_addr !== addr)) begin
      $display("FAIL %-24s saw_mem=%0b addr=%0d exp=%0d",
               name, saw_load_mem_read, saw_load_mem_addr, addr);
      errors++;
    end else $display("ok   %-24s mem read addr=%0d", name, addr);
  endtask

  task automatic commit_store(input string name, input rob_tag_t tag);
    @(negedge clk);
    commit_store_valid = '0;
    commit_store_valid[0] = 1'b1;
    commit_store_tag[0] = tag;
    begin
      automatic bit got = 1'b0;
      for (int k = 0; k < 8; k++) begin
        @(posedge clk); #1;
        if (k == 0) commit_store_valid = '0;
        if (store_complete_valid[0] && (store_complete_tag[0] === tag)) begin
          got = 1'b1; break;
        end
      end
      if (!got) begin
        $display("FAIL %-24s complete valid=%0b tag=%0d", name, store_complete_valid[0], store_complete_tag[0]);
        errors++;
      end else $display("ok   %-24s tag=%0d", name, store_complete_tag[0]);
    end
  endtask

  initial begin
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

    // Seed uncovered bytes with a committed SW, then sb+lh while store is
    // still in-flight: forward byte0 from sb, byte1 from mem, before commit.
    dispatch_mem(1'b0, SZ_W, 1'b0, 5'd20, 32'd120, 32'd0, 32'h0000_AB00);
    commit_store("seed word @120", 5'd20);
    saw_load_mem_read = 1'b0;
    saw_load_mem_addr = '0;
    dispatch_mem(1'b0, SZ_B, 1'b0, 5'd1, 32'd120, 32'd0, 32'h0000_0080);
    dispatch_mem(1'b1, SZ_H, 1'b0, 5'd2, 32'd120, 32'd0, '0);
    wait_cdb("partial merge before commit", 5'd2, 32'hffff_ab80);
    chk_saw_mem_read("partial issued mem", 32'd120);
    commit_store("partial store commit", 5'd1);

    // sb then lw: one forwarded byte, three from mem.
    dispatch_mem(1'b0, SZ_W, 1'b0, 5'd21, 32'd200, 32'd0, 32'h1122_3344);
    commit_store("seed word @200", 5'd21);
    saw_load_mem_read = 1'b0;
    saw_load_mem_addr = '0;
    dispatch_mem(1'b0, SZ_B, 1'b0, 5'd10, 32'd200, 32'd0, 32'h0000_00FE);
    dispatch_mem(1'b1, SZ_W, 1'b0, 5'd11, 32'd200, 32'd0, '0);
    wait_cdb("sb+lw partial merge", 5'd11, 32'h1122_33fe);
    chk_saw_mem_read("sb+lw issued mem", 32'd200);
    commit_store("sb+lw store commit", 5'd10);

    // When multiple older stores cover the same byte, the youngest older store
    // is the value the load must see.
    dispatch_mem(1'b0, SZ_B, 1'b0, 5'd3, 32'd132, 32'd0, 32'h0000_0011);
    dispatch_mem(1'b0, SZ_B, 1'b0, 5'd4, 32'd132, 32'd0, 32'h0000_0022);
    dispatch_mem(1'b1, SZ_B, 1'b1, 5'd5, 32'd132, 32'd0, '0);
    wait_cdb("youngest store wins", 5'd5, 32'h0000_0022);

    // A younger store to the same address must not affect an older load.
    dispatch_mem(1'b1, SZ_B, 1'b1, 5'd6, 32'd144, 32'd0, '0);
    dispatch_mem(1'b0, SZ_B, 1'b0, 5'd7, 32'd144, 32'd0, 32'h0000_0099);
    wait_cdb("younger store ignored", 5'd6, 32'h0000_0000);

    // Forwarding result must wait if the CDB arbiter applies backpressure.
    for (int lane = 0; lane < NUM_LSQ; lane++) cdb_ready[lane] = 1'b0;
    dispatch_mem(1'b0, SZ_W, 1'b0, 5'd8, 32'd160, 32'd0, 32'hdead_beef);
    dispatch_mem(1'b1, SZ_W, 1'b0, 5'd9, 32'd160, 32'd0, '0);
    repeat (4) begin
      @(posedge clk); #1;
      for (int lane = 0; lane < NUM_LSQ; lane++) begin
        if (out_cdb[lane].valid) begin
        $display("FAIL cdb backpressure produced result while not ready");
        errors++;
        end
      end
    end
    $display("ok   cdb backpressure held");
    for (int lane = 0; lane < NUM_LSQ; lane++) cdb_ready[lane] = 1'b1;
    wait_cdb("forward after cdb ready", 5'd9, 32'hdead_beef);

    if (errors == 0) $display("TB_LSQ_OOO_STRESS: PASS");
    else             $display("TB_LSQ_OOO_STRESS: FAIL (%0d errors)", errors);
    $finish;
  end
endmodule
