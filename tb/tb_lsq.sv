`timescale 1ns/1ps
// ============================================================================
// tb_lsq.sv -- self-checking unit test for LSQ + dmem.
// ============================================================================
module tb_lsq;
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

  task automatic dispatch_mem(input bit is_load, input memsz_e size, input bit unsign,
                              input rob_tag_t tag, input data_t base, input data_t imm,
                              input data_t store_data);
    @(negedge clk);
    dispatch_valid = '0;
    dispatch_uop[0] = '0; dispatch_uop[0].fu = FU_MEM; dispatch_uop[0].is_load = is_load;
    dispatch_uop[0].is_store = !is_load; dispatch_uop[0].mem_size = size;
    dispatch_uop[0].mem_unsigned = unsign; dispatch_uop[0].imm = imm;
    dispatch_tag[0] = tag; op_ready(dispatch_base[0], base); op_ready(dispatch_store_data[0], store_data);
    dispatch_valid[0] = 1'b1;
    @(posedge clk); #1; dispatch_valid = '0;
  endtask

  task automatic wait_cdb(input string name, input rob_tag_t tag, input data_t data);
    repeat (8) begin
      @(posedge clk); #1;
      for (int lane = 0; lane < NUM_LSQ; lane++) begin
        if (out_cdb[lane].valid) begin
          if ((out_cdb[lane].tag !== tag) || (out_cdb[lane].data !== data)) begin
          $display("FAIL %-16s tag=%0d data=%h exp_tag=%0d exp=%h",
                   name, out_cdb[lane].tag, out_cdb[lane].data, tag, data); errors++;
          end else $display("ok   %-16s tag=%0d data=%h", name, out_cdb[lane].tag, out_cdb[lane].data);
          return;
        end
      end
    end
    $display("FAIL %-16s no CDB result", name); errors++;
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
    repeat (2) @(posedge clk); rst = 1'b0;

    dispatch_mem(1'b0, SZ_W, 1'b0, 5'd1, 32'd0, 32'd0, 32'hAABB_CCDD);
    @(negedge clk); commit_store_valid = '0; commit_store_valid[0] = 1'b1; commit_store_tag[0] = 5'd1;
    begin
      automatic bit got = 1'b0;
      for (int k = 0; k < 8; k++) begin
        @(posedge clk); #1;
        if (store_complete_valid[0] && (store_complete_tag[0] === 5'd1)) begin
          got = 1'b1;
          break;
        end
      end
      if (!got) begin
        $display("FAIL store completion valid=%0b tag=%0d", store_complete_valid[0], store_complete_tag[0]);
        errors++;
      end else $display("ok   store completion tag=%0d", store_complete_tag[0]);
    end
    commit_store_valid = '0;
    repeat (2) @(posedge clk);

    dispatch_mem(1'b1, SZ_W, 1'b0, 5'd2, 32'd0, 32'd0, '0);
    wait_cdb("lw", 5'd2, 32'hAABB_CCDD);

    dispatch_mem(1'b1, SZ_B, 1'b0, 5'd3, 32'd0, 32'd1, '0);
    wait_cdb("lb sign", 5'd3, 32'hFFFF_FFCC);

    dispatch_mem(1'b1, SZ_B, 1'b1, 5'd4, 32'd0, 32'd2, '0);
    wait_cdb("lbu", 5'd4, 32'h0000_00BB);

    dispatch_mem(1'b1, SZ_H, 1'b0, 5'd5, 32'd0, 32'd2, '0);
    wait_cdb("lh sign", 5'd5, 32'hFFFF_AABB);

    if (errors == 0) $display("TB_LSQ: PASS");
    else             $display("TB_LSQ: FAIL (%0d errors)", errors);
    $finish;
  end
endmodule
