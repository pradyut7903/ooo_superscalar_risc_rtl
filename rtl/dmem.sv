`timescale 1ns/1ps
// ============================================================================
// dmem.sv -- Ideal tagged data memory (bring-up / MEM_SYSTEM_IDEAL shim).
//
// WIDTH-port, synchronous, byte-addressed data memory for the LSQ.
// Internally word-organized, with byte-lane write strobes for SB/SH/SW.
//
// Contract:
//   * mem_req_ready[lane] is always high
//   * load response appears one cycle after a read request and echoes req id
//   * stores update selected byte lanes at the request clock edge
//   * out-of-range loads return resp_valid=0; out-of-range stores are ignored
//
// Optional initialization via +dmem=<file>, one 32-bit word per line.
// ============================================================================
module dmem
  import pkg_cpu::*;
  #(parameter string DEFAULT_IMAGE = "")
(
  input  logic     clk,
  input  logic     rst,

  input  valid_bundle_t mem_req_valid,
  output valid_bundle_t mem_req_ready,
  input  valid_bundle_t mem_req_write,
  input  data_t         mem_req_addr [WIDTH],
  input  data_t         mem_req_wdata [WIDTH],
  input  logic [3:0]    mem_req_wstrb [WIDTH],
  input  mem_id_t       mem_req_id [WIDTH],

  output valid_bundle_t mem_resp_valid,
  output data_t         mem_resp_rdata [WIDTH],
  output mem_id_t       mem_resp_id [WIDTH]
);

  localparam int WORD_IDX_W = $clog2(DMEM_WORDS);

  data_t mem [DMEM_WORDS];

  string dmem_file;
  initial begin
    for (int i = 0; i < DMEM_WORDS; i++) mem[i] = '0;
    if ($value$plusargs("dmem=%s", dmem_file)) begin
      $readmemh(dmem_file, mem);
      $display("[dmem] loaded image: %s", dmem_file);
    end else if (DEFAULT_IMAGE != "") begin
      dmem_file = DEFAULT_IMAGE;
      $readmemh(dmem_file, mem);
      $display("[dmem] loaded default image: %s", dmem_file);
    end
  end

  logic [DMEM_ADDR_W-1:0] byte_addr [WIDTH];
  logic [DMEM_ADDR_W-3:0] word_idx_full [WIDTH];
  logic [WORD_IDX_W-1:0]  word_idx [WIDTH];
  logic                   in_range [WIDTH];
  logic                   read_fire [WIDTH];
  logic                   write_fire [WIDTH];

  assign mem_req_ready = '1;

  always_comb begin
    for (int lane = 0; lane < WIDTH; lane++) begin
      byte_addr[lane]     = mem_req_addr[lane][DMEM_ADDR_W-1:0];
      word_idx_full[lane] = byte_addr[lane][DMEM_ADDR_W-1:2];
      word_idx[lane]      = word_idx_full[lane][WORD_IDX_W-1:0];
      in_range[lane]      = (word_idx_full[lane] < DMEM_WORDS);
      read_fire[lane]     = mem_req_valid[lane] && mem_req_ready[lane] && !mem_req_write[lane];
      write_fire[lane]    = mem_req_valid[lane] && mem_req_ready[lane] && mem_req_write[lane] && in_range[lane];
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      mem_resp_valid <= '0;
      for (int lane = 0; lane < WIDTH; lane++) begin
        mem_resp_rdata[lane] <= '0;
        mem_resp_id[lane]    <= '0;
      end
    end else begin
      for (int lane = 0; lane < WIDTH; lane++) begin
        mem_resp_valid[lane] <= (read_fire[lane] && in_range[lane]) || write_fire[lane];
        mem_resp_rdata[lane] <= (read_fire[lane] && in_range[lane]) ? mem[word_idx[lane]] : '0;
        mem_resp_id[lane]    <= mem_req_id[lane];

        if (write_fire[lane]) begin
          if (mem_req_wstrb[lane][0]) mem[word_idx[lane]][7:0]   <= mem_req_wdata[lane][7:0];
          if (mem_req_wstrb[lane][1]) mem[word_idx[lane]][15:8]  <= mem_req_wdata[lane][15:8];
          if (mem_req_wstrb[lane][2]) mem[word_idx[lane]][23:16] <= mem_req_wdata[lane][23:16];
          if (mem_req_wstrb[lane][3]) mem[word_idx[lane]][31:24] <= mem_req_wdata[lane][31:24];
        end
      end
    end
  end

endmodule
