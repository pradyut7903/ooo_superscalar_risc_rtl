`timescale 1ns/1ps
// ============================================================================
// ideal_imem_bridge.sv -- Adapt sync instr_mem to fetch req/resp interface.
// ============================================================================
module ideal_imem_bridge
  import pkg_cpu::*;
  #(parameter string DEFAULT_IMAGE = "")
(
  input  logic clk,
  input  logic rst,
  input  logic flush,

  input  logic          req_valid,
  output logic          req_ready,
  input  pc_t           req_pc,
  output logic          resp_valid,
  output valid_bundle_t resp_word_valid,
  output instr_bundle_t resp_word,
  output pc_bundle_t    resp_pc,
  output logic [$clog2(WIDTH+1)-1:0] resp_count
);

  pc_bundle_t imem_pc;
  logic imem_en;
  instr_bundle_t imem_word;
  valid_bundle_t imem_valid;

  typedef enum logic [0:0] { S_IDLE = 1'b0, S_WAIT = 1'b1 } state_e;
  state_e state;
  pc_t hold_pc;

  instr_mem #(.DEFAULT_IMAGE(DEFAULT_IMAGE)) u_imem (
    .clk(clk), .rst(rst), .en(imem_en), .pc(imem_pc),
    .valid(imem_valid), .word(imem_word)
  );

  assign req_ready = (state == S_IDLE);
  assign imem_en = (state == S_IDLE) ? (req_valid && req_ready) : 1'b0;

  always_comb begin
    for (int i = 0; i < WIDTH; i++) begin
      imem_pc[i] = ((state == S_IDLE) ? req_pc : hold_pc) + pc_t'(4 * i);
    end
  end

  always_ff @(posedge clk) begin
    if (rst || flush) begin
      state <= S_IDLE;
      hold_pc <= '0;
      resp_valid <= 1'b0;
      resp_word_valid <= '0;
      resp_count <= '0;
      for (int i = 0; i < WIDTH; i++) begin
        resp_word[i] <= INSTR_INVALID;
        resp_pc[i] <= '0;
      end
    end else begin
      resp_valid <= 1'b0;
      unique case (state)
        S_IDLE: begin
          if (req_valid && req_ready) begin
            hold_pc <= req_pc;
            state <= S_WAIT;
          end
        end
        S_WAIT: begin
          resp_valid <= 1'b1;
          resp_count <= ($bits(resp_count))'(WIDTH);
          for (int i = 0; i < WIDTH; i++) begin
            resp_pc[i] <= hold_pc + pc_t'(4 * i);
            resp_word[i] <= imem_word[i];
            resp_word_valid[i] <= imem_valid[i];
          end
          state <= S_IDLE;
        end
      endcase
    end
  end

endmodule
