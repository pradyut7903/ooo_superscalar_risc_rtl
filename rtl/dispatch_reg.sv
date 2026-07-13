`timescale 1ns/1ps
// ============================================================================
// dispatch_reg.sv -- Decode-to-dispatch bundle pipeline register.
//
// Superscalar prefix-pop contract:
//   * captures a decoded bundle when empty, or when the held bundle is fully
//     popped this cycle
//   * downstream supplies out_accept_count for a program-order prefix
//   * partial pops compact the remaining held lanes toward lane 0
// ============================================================================
module dispatch_reg
  import pkg_cpu::*;
(
  input  logic clk,
  input  logic rst,
  input  logic flush,

  input  valid_bundle_t in_valid,
  output logic          in_ready,
  input  uop_bundle_t   in_uop,

  output valid_bundle_t out_valid,
  input  logic [$clog2(WIDTH+1)-1:0] out_accept_count,
  output uop_bundle_t   out_uop
);

  logic holding;
  logic [$clog2(WIDTH+1)-1:0] held_count;
  logic full_pop;

  always_comb begin
    held_count = '0;
    for (int i = 0; i < WIDTH; i++) begin
      if (out_valid[i]) held_count = held_count + 1'b1;
    end
  end

  assign full_pop = holding && (out_accept_count >= held_count);
  assign in_ready = !holding || full_pop;

  always_ff @(posedge clk) begin
    if (rst || flush) begin
      holding   <= 1'b0;
      out_valid <= '0;
      for (int i = 0; i < WIDTH; i++) begin
        out_uop[i]    <= '0;
        out_uop[i].op <= UOP_NOP;
        out_uop[i].fu <= FU_ALU;
      end
    end else if (!holding || full_pop) begin
      out_valid <= in_valid;
      out_uop   <= in_uop;
      holding   <= (in_valid != '0);
    end else if (out_accept_count != '0) begin
      valid_bundle_t next_valid;
      uop_bundle_t next_uop;

      next_valid = '0;
      for (int i = 0; i < WIDTH; i++) begin
        next_uop[i] = '0;
        next_uop[i].op = UOP_NOP;
        next_uop[i].fu = FU_ALU;
      end

      for (int i = 0; i < WIDTH; i++) begin
        int src;
        src = i + int'(out_accept_count);
        if (src < WIDTH) begin
          next_valid[i] = out_valid[src];
          next_uop[i] = out_uop[src];
        end
      end

      out_valid <= next_valid;
      out_uop <= next_uop;
      holding <= (next_valid != '0);
    end
  end

endmodule
