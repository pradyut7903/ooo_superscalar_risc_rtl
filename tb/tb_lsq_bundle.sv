`timescale 1ns/1ps
// ============================================================================
// tb_lsq_bundle.sv -- WIDTH-lane LSQ dispatch checks.
// Run with WIDTH >= 2.  The default WIDTH=1 build reports SKIP.
// ============================================================================
module tb_lsq_bundle;
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

  task automatic clear_dispatch();
    dispatch_valid = '0;
    for (int i = 0; i < WIDTH; i++) begin
      dispatch_uop[i] = '0;
      dispatch_uop[i].op = UOP_NOP;
      dispatch_uop[i].fu = FU_MEM;
      dispatch_tag[i] = '0;
      dispatch_base[i] = '0;
      dispatch_store_data[i] = '0;
      commit_store_tag[i] = '0;
    end
    for (int i = 0; i < NUM_LSQ; i++) cdb_ready[i] = 1'b1;
  endtask

  task automatic chk(input string name, input bit cond);
    if (!cond) begin $display("FAIL %s", name); errors++; end
    else       begin $display("ok   %s", name); end
  endtask

  task automatic wait_cdb(input string name, input rob_tag_t tag, input data_t data);
    repeat (12) begin
      @(posedge clk); #1;
      for (int lane = 0; lane < NUM_LSQ; lane++) begin
        if (out_cdb[lane].valid) begin
          chk(name, (out_cdb[lane].tag == tag) && (out_cdb[lane].data == data));
          return;
        end
      end
    end
    $display("FAIL %s no CDB result", name);
    errors++;
  endtask

  generate
    if (WIDTH >= 2) begin : gen_bundle_test
      initial begin
        clear_dispatch();
        repeat (2) @(posedge clk); rst = 1'b0;

        @(negedge clk);
        clear_dispatch();
        dispatch_valid[1:0] = 2'b11;

        dispatch_uop[0] = '0;
        dispatch_uop[0].fu = FU_MEM;
        dispatch_uop[0].is_store = 1'b1;
        dispatch_uop[0].mem_size = SZ_W;
        dispatch_uop[0].imm = 32'd0;
        dispatch_tag[0] = 5'd1;
        op_ready(dispatch_base[0], 32'd0);
        op_ready(dispatch_store_data[0], 32'h1357_9bdf);

        dispatch_uop[1] = '0;
        dispatch_uop[1].fu = FU_MEM;
        dispatch_uop[1].is_load = 1'b1;
        dispatch_uop[1].mem_size = SZ_W;
        dispatch_uop[1].imm = 32'd0;
        dispatch_tag[1] = 5'd2;
        op_ready(dispatch_base[1], 32'd0);
        dispatch_store_data[1] = '0;

        #1;
        chk("two-lane dispatch ready", dispatch_ready[1:0] == 2'b11);
        @(posedge clk); #1; clear_dispatch();
        wait_cdb("same-cycle store forward", 5'd2, 32'h1357_9bdf);

        @(negedge clk); commit_store_valid = '0; commit_store_valid[0] = 1'b1; commit_store_tag[0] = 5'd1;
        begin
          automatic bit got = 1'b0;
          for (int k = 0; k < 8; k++) begin
            @(posedge clk); #1;
            if (k == 0) commit_store_valid = '0;
            if (store_complete_valid[0] && (store_complete_tag[0] == 5'd1)) begin
              got = 1'b1; break;
            end
          end
          chk("older store completes", got);
        end

        @(negedge clk);
        clear_dispatch();
        dispatch_valid[1:0] = 2'b11;

        dispatch_uop[0] = '0;
        dispatch_uop[0].fu = FU_MEM;
        dispatch_uop[0].is_store = 1'b1;
        dispatch_uop[0].mem_size = SZ_W;
        dispatch_uop[0].imm = 32'd0;
        dispatch_tag[0] = 5'd9;
        op_ready(dispatch_base[0], 32'd64);
        op_wait(dispatch_store_data[0], 5'd8);

        dispatch_uop[1] = '0;
        dispatch_uop[1].fu = FU_MEM;
        dispatch_uop[1].is_load = 1'b1;
        dispatch_uop[1].mem_size = SZ_W;
        dispatch_uop[1].imm = 32'd0;
        dispatch_tag[1] = 5'd10;
        op_ready(dispatch_base[1], 32'd64);
        dispatch_store_data[1] = '0;

        #1;
        chk("unresolved store/load dispatch ready", dispatch_ready[1:0] == 2'b11);
        @(posedge clk); #1; clear_dispatch();
        repeat (3) begin
          @(posedge clk); #1;
          chk("load waits for unresolved same-address store", out_cdb[0].valid == 1'b0);
        end
        @(negedge clk);
        cdb_in[0].valid = 1'b1;
        cdb_in[0].tag = 5'd8;
        cdb_in[0].data = 32'h2468_ace0;
        @(posedge clk); #1;
        cdb_in = '{default:'0};
        wait_cdb("wake then forward", 5'd10, 32'h2468_ace0);

        @(negedge clk); commit_store_valid = '0; commit_store_valid[0] = 1'b1; commit_store_tag[0] = 5'd9;
        begin
          automatic bit got = 1'b0;
          for (int k = 0; k < 8; k++) begin
            @(posedge clk); #1;
            if (k == 0) commit_store_valid = '0;
            if (store_complete_valid[0] && (store_complete_tag[0] == 5'd9)) begin
              got = 1'b1; break;
            end
          end
          chk("woken store completes", got);
        end

        if (WIDTH >= 4) begin
          @(negedge clk);
          clear_dispatch();
          dispatch_valid[3:0] = 4'b1111;
          for (int i = 0; i < 4; i++) begin
            dispatch_uop[i] = '0;
            dispatch_uop[i].fu = FU_MEM;
            dispatch_uop[i].is_load = 1'b1;
            dispatch_uop[i].mem_size = SZ_W;
            dispatch_uop[i].imm = 32'(i * 4);
            dispatch_tag[i] = rob_tag_t'(5'd4 + i);
            op_ready(dispatch_base[i], 32'd256);
            dispatch_store_data[i] = '0;
          end
          #1;
          chk("four load dispatch ready", dispatch_ready[3:0] == 4'b1111);
          @(posedge clk); #1; clear_dispatch();
          @(negedge clk); #1;
          chk("four load requests issue", mem_req_valid[3:0] == 4'b1111);
          chk("four load requests are reads", mem_req_write[3:0] == 4'b0000);
          repeat (4) @(posedge clk);

          @(negedge clk);
          clear_dispatch();
          dispatch_valid[3:0] = 4'b1111;
          for (int i = 0; i < 4; i++) begin
            dispatch_uop[i] = '0;
            dispatch_uop[i].fu = FU_MEM;
            dispatch_uop[i].is_store = 1'b1;
            dispatch_uop[i].mem_size = SZ_W;
            dispatch_uop[i].imm = 32'(i * 4);
            dispatch_tag[i] = rob_tag_t'(5'd12 + i);
            op_ready(dispatch_base[i], 32'd512);
            op_ready(dispatch_store_data[i], 32'h1000_0000 + i);
          end
          #1;
          chk("four store dispatch ready", dispatch_ready[3:0] == 4'b1111);
          @(posedge clk); #1; clear_dispatch();
          @(negedge clk);
          commit_store_valid = '0;
          for (int i = 0; i < 4; i++) begin
            commit_store_valid[i] = 1'b1;
            commit_store_tag[i] = rob_tag_t'(5'd12 + i);
          end
          @(posedge clk); #1; commit_store_valid = '0;
          // SB enqueue completes ROB on the commit-grant cycle (no D$ wait).
          chk("four stores complete", store_complete_valid[3:0] == 4'b1111);
          chk("store completion tags ordered",
              (store_complete_tag[0] == 5'd12) && (store_complete_tag[3] == 5'd15));
        end

        if (errors == 0) $display("TB_LSQ_BUNDLE: PASS");
        else             $display("TB_LSQ_BUNDLE: FAIL (%0d errors)", errors);
        $finish;
      end
    end else begin : gen_skip
      initial begin
        $display("TB_LSQ_BUNDLE: SKIP (WIDTH=%0d)", WIDTH);
        $finish;
      end
    end
  endgenerate
endmodule
