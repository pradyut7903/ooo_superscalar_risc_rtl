`timescale 1ns/1ps
// ============================================================================
// commit_recovery.sv -- Legacy commit-time recovery (disabled).
//
// Early execute-time recovery owns flush/redirect. This module remains for
// TB compatibility and always drives idle.
// ============================================================================
module commit_recovery
  import pkg_cpu::*;
(
  input  logic commit_valid,
  input  logic commit_do,
  input  logic commit_is_control,
  input  logic commit_mispredict,
  input  pc_t  commit_redirect_pc,

  output logic flush,
  output logic redirect_valid,
  output pc_t  redirect_pc
);

  assign flush          = 1'b0;
  assign redirect_valid = 1'b0;
  assign redirect_pc    = '0;

endmodule
