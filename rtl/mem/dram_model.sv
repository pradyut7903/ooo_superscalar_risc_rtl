`timescale 1ns/1ps
// ============================================================================
// dram_model.sv -- DRAM backend wrapper (gated by DRAM_MODEL in pkg_cpu).
//
//   DRAM_MODEL_SIMPLE : fixed DRAM_LAT_CYCLES, multi-outstanding slots
//   DRAM_MODEL_BANKED : banked open-page SDRAM-style timing (cycle-accurate)
//
// Same ports either way so caches / arbiter / TBs stay unchanged.
// ============================================================================
module dram_model
  import pkg_cpu::*;
  #(
    parameter string IMEM_IMAGE = "",
    parameter string DMEM_IMAGE = "",
    parameter int LAT = DRAM_LAT_CYCLES
  )
(
  input  logic clk,
  input  logic rst,

  input  logic        req_valid,
  output logic        req_ready,
  input  logic        req_is_instr,
  input  logic        req_write,
  input  data_t       req_line_addr,
  input  cache_line_t req_wdata,
  input  dram_id_t    req_id,

  output logic        resp_valid,
  output cache_line_t resp_rdata,
  output dram_id_t    resp_id
);

  generate
    if (DRAM_MODEL == DRAM_MODEL_BANKED) begin : g_banked
      dram_model_banked #(
        .IMEM_IMAGE(IMEM_IMAGE),
        .DMEM_IMAGE(DMEM_IMAGE)
      ) u (
        .clk(clk), .rst(rst),
        .req_valid(req_valid), .req_ready(req_ready),
        .req_is_instr(req_is_instr), .req_write(req_write),
        .req_line_addr(req_line_addr), .req_wdata(req_wdata),
        .req_id(req_id),
        .resp_valid(resp_valid), .resp_rdata(resp_rdata), .resp_id(resp_id)
      );
      // LAT unused in banked mode (timing from DRAM_*_CYCLES params).
    end else begin : g_simple
      dram_model_simple #(
        .IMEM_IMAGE(IMEM_IMAGE),
        .DMEM_IMAGE(DMEM_IMAGE),
        .LAT(LAT)
      ) u (
        .clk(clk), .rst(rst),
        .req_valid(req_valid), .req_ready(req_ready),
        .req_is_instr(req_is_instr), .req_write(req_write),
        .req_line_addr(req_line_addr), .req_wdata(req_wdata),
        .req_id(req_id),
        .resp_valid(resp_valid), .resp_rdata(resp_rdata), .resp_id(resp_id)
      );
    end
  endgenerate

endmodule
