`timescale 1ns/1ps
// ============================================================================
// tb_rs.sv -- self-checking unit test for the reservation station.
// ============================================================================
module tb_rs;
  import pkg_cpu::*;

  logic clk = 1'b0, rst = 1'b1, flush = 1'b0;
  logic squash_en = 1'b0;
  rob_tag_t squash_tag = '0;
  rob_tag_t rob_head = '0;
  valid_bundle_t dispatch_valid = '0, dispatch_ready;
  uop_bundle_t dispatch_uop;
  rob_tag_t dispatch_tag [WIDTH];
  operand_t dispatch_src1 [WIDTH], dispatch_src2 [WIDTH];
  cdb_bus_t cdb_in;

  logic alu_valid [NUM_ALU], alu_ready [NUM_ALU];
  logic mul_valid [NUM_MUL], mul_ready [NUM_MUL];
  logic div_valid [NUM_DIV], div_ready [NUM_DIV];
  logic br_valid, br_ready = 1'b0;
  uop_t alu_uop [NUM_ALU], mul_uop [NUM_MUL], div_uop [NUM_DIV], br_uop;
  rob_tag_t alu_tag [NUM_ALU], mul_tag [NUM_MUL], div_tag [NUM_DIV], br_tag;
  data_t alu_src1_value [NUM_ALU], alu_src2_value [NUM_ALU];
  data_t mul_src1_value [NUM_MUL], mul_src2_value [NUM_MUL];
  data_t div_src1_value [NUM_DIV], div_src2_value [NUM_DIV];
  data_t br_src1_value, br_src2_value;
  logic full, empty;
  int errors = 0;

  rs dut (
    .clk(clk), .rst(rst), .flush(flush),
    .squash_en(squash_en), .squash_tag(squash_tag), .rob_head(rob_head),
    .dispatch_valid(dispatch_valid), .dispatch_ready(dispatch_ready),
    .dispatch_uop(dispatch_uop), .dispatch_tag(dispatch_tag),
    .dispatch_src1(dispatch_src1), .dispatch_src2(dispatch_src2),
    .cdb_in(cdb_in),
    .alu_valid(alu_valid), .alu_ready(alu_ready), .alu_uop(alu_uop), .alu_tag(alu_tag),
    .alu_src1_value(alu_src1_value), .alu_src2_value(alu_src2_value),
    .mul_valid(mul_valid), .mul_ready(mul_ready), .mul_uop(mul_uop), .mul_tag(mul_tag),
    .mul_src1_value(mul_src1_value), .mul_src2_value(mul_src2_value),
    .div_valid(div_valid), .div_ready(div_ready), .div_uop(div_uop), .div_tag(div_tag),
    .div_src1_value(div_src1_value), .div_src2_value(div_src2_value),
    .br_valid(br_valid), .br_ready(br_ready), .br_uop(br_uop), .br_tag(br_tag),
    .br_src1_value(br_src1_value), .br_src2_value(br_src2_value),
    .full(full), .empty(empty)
  );

  always #5 clk = ~clk;

  task automatic op_ready(output operand_t opnd, input data_t value);
    opnd.ready = 1'b1; opnd.tag = '0; opnd.value = value;
  endtask

  task automatic op_wait(output operand_t opnd, input rob_tag_t tag);
    opnd.ready = 1'b0; opnd.tag = tag; opnd.value = '0;
  endtask

  task automatic clear_inputs();
    dispatch_valid = '0;
    cdb_in = '{default:'0};
    br_ready = 1'b0;
    for (int i = 0; i < WIDTH; i++) begin
      dispatch_uop[i] = '0;
      dispatch_uop[i].op = UOP_NOP;
      dispatch_uop[i].fu = FU_ALU;
      dispatch_tag[i] = '0;
      dispatch_src1[i] = '0;
      dispatch_src2[i] = '0;
    end
    for (int i = 0; i < NUM_ALU; i++) alu_ready[i] = 1'b0;
    for (int i = 0; i < NUM_MUL; i++) mul_ready[i] = 1'b0;
    for (int i = 0; i < NUM_DIV; i++) div_ready[i] = 1'b0;
  endtask

  task automatic chk(input string name, input bit cond);
    if (!cond) begin $display("FAIL %s", name); errors++; end
    else       begin $display("ok   %s", name); end
  endtask

  initial begin
    clear_inputs();
    repeat (2) @(posedge clk); rst = 1'b0; @(negedge clk);

    dispatch_uop[0] = '0; dispatch_uop[0].fu = FU_ALU; dispatch_uop[0].op = ALU_ADD;
    dispatch_tag[0] = 5'd3; op_ready(dispatch_src1[0], 32'd10); op_ready(dispatch_src2[0], 32'd20);
    dispatch_valid[0] = 1'b1; @(posedge clk); #1; dispatch_valid = '0;
    chk("ready ALU issue", alu_valid[0] && (alu_tag[0] == 5'd3) &&
                           (alu_src1_value[0] == 32'd10) && (alu_src2_value[0] == 32'd20));
    alu_ready[0] = 1'b1; @(posedge clk); #1; clear_inputs();
    chk("empty after ALU issue", empty);

    @(negedge clk);
    cdb_in[0].valid = 1'b1;
    cdb_in[0].tag = '0;
    cdb_in[0].data = 32'hfeed_beef;
    dispatch_uop[0] = '0; dispatch_uop[0].fu = FU_ALU; dispatch_uop[0].op = ALU_ADD;
    dispatch_tag[0] = 5'd4;
    op_ready(dispatch_src1[0], 32'd0);
    op_ready(dispatch_src2[0], 32'd1);
    dispatch_valid[0] = 1'b1;
    @(posedge clk); #1; dispatch_valid = '0; cdb_in = '{default:'0};
    chk("ready operand ignores same-cycle CDB tag0",
        alu_valid[0] && (alu_tag[0] == 5'd4) &&
        (alu_src1_value[0] == 32'd0) && (alu_src2_value[0] == 32'd1));
    alu_ready[0] = 1'b1; @(posedge clk); #1; clear_inputs();
    chk("empty after tag0 bypass check", empty);

    @(negedge clk);
    dispatch_uop[0] = '0; dispatch_uop[0].fu = FU_MUL; dispatch_uop[0].op = MD_MUL;
    dispatch_tag[0] = 5'd8; op_wait(dispatch_src1[0], 5'd12); op_ready(dispatch_src2[0], 32'd7);
    dispatch_valid[0] = 1'b1; @(posedge clk); #1; dispatch_valid = '0;
    chk("waiting MUL not issued", !mul_valid[0]);
    @(negedge clk); cdb_in[0].valid = 1'b1; cdb_in[0].tag = 5'd12; cdb_in[0].data = 32'd6;
    @(posedge clk); #1; cdb_in = '{default:'0};
    @(posedge clk); #1;
    chk("CDB wake to MUL", mul_valid[0] && (mul_src1_value[0] == 32'd6) &&
                            (mul_src2_value[0] == 32'd7));
    mul_ready[0] = 1'b1; @(posedge clk); #1; clear_inputs();
    chk("empty after MUL issue", empty);

    if ((WIDTH >= 4) && (NUM_ALU >= 2)) begin
      @(negedge clk);
      clear_inputs();
      dispatch_valid[3:0] = 4'b1111;
      for (int i = 0; i < 4; i++) begin
        dispatch_uop[i] = '0;
        dispatch_uop[i].fu = FU_ALU;
        dispatch_uop[i].op = ALU_ADD;
        dispatch_tag[i] = rob_tag_t'(10 + i);
        op_ready(dispatch_src1[i], data_t'(100 + i));
        op_ready(dispatch_src2[i], data_t'(200 + i));
      end
      #1;
      chk("four-lane dispatch ready", dispatch_ready[3:0] == 4'b1111);
      @(posedge clk); #1; dispatch_valid = '0;
      chk("two ALU issue lanes valid", alu_valid[0] && alu_valid[1] &&
                                      (alu_tag[0] == 5'd10) && (alu_tag[1] == 5'd11));
      alu_ready[0] = 1'b1;
      alu_ready[1] = 1'b1;
      @(posedge clk); #1; clear_inputs();
      chk("remaining ALUs issue next", alu_valid[0] && alu_valid[1] &&
                                      (alu_tag[0] == 5'd12) && (alu_tag[1] == 5'd13));
      alu_ready[0] = 1'b1;
      alu_ready[1] = 1'b1;
      @(posedge clk); #1; clear_inputs();
      chk("empty after bundle ALUs", empty);
    end

    // Selective squash: kill younger waiting entry, keep older ready
    @(negedge clk);
    clear_inputs();
    rob_head = '0;
    alu_ready[0] = 1'b0;
    if (NUM_ALU > 1) alu_ready[1] = 1'b0;
    dispatch_uop[0] = '0; dispatch_uop[0].fu = FU_ALU; dispatch_uop[0].op = ALU_ADD;
    dispatch_tag[0] = 5'd1;
    op_ready(dispatch_src1[0], 32'd3); op_ready(dispatch_src2[0], 32'd4);
    dispatch_uop[1] = '0; dispatch_uop[1].fu = FU_ALU; dispatch_uop[1].op = ALU_ADD;
    dispatch_tag[1] = 5'd3;
    op_wait(dispatch_src1[1], 5'd20); op_ready(dispatch_src2[1], 32'd1);
    dispatch_valid[0] = 1'b1; dispatch_valid[1] = 1'b1;
    @(posedge clk); #1; dispatch_valid = '0;
    @(negedge clk);
    squash_en = 1'b1; squash_tag = 5'd1;
    @(posedge clk); #1; squash_en = 1'b0;
    @(negedge clk);
    alu_ready[0] = 1'b1;
    #1;
    chk("squash keeps older ready issue", alu_valid[0] && (alu_tag[0] == 5'd1));
    @(posedge clk); #1; clear_inputs();
    chk("squash killed younger", empty);

    if (errors == 0) $display("TB_RS: PASS");
    else             $display("TB_RS: FAIL (%0d errors)", errors);
    $finish;
  end
endmodule
