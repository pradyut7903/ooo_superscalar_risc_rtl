`timescale 1ns/1ps
// ============================================================================
// early_recovery.sv -- Execute-time mispredict recovery decision.
//
// When the branch unit resolves a mispredict, assert recover/redirect/squash.
// Commit-time predictor updates remain in the backend; this module does not
// flush on commit.
// ============================================================================
module early_recovery
  import pkg_cpu::*;
(
  input  logic     br_resolve_valid,
  input  logic     br_mispredict,
  input  rob_tag_t br_resolve_tag,
  input  pc_t      br_redirect_pc,

  output logic     recover_en,
  output rob_tag_t recover_tag,
  output pc_t      recover_pc,
  output logic     squash_en,
  output rob_tag_t squash_tag,
  output logic     redirect_valid,
  output pc_t      redirect_pc
);

  wire recover = br_resolve_valid && br_mispredict;

  assign recover_en     = recover;
  assign recover_tag    = br_resolve_tag;
  assign recover_pc     = br_redirect_pc;
  assign squash_en      = recover;
  assign squash_tag     = br_resolve_tag;
  assign redirect_valid = recover;
  assign redirect_pc    = br_redirect_pc;

endmodule
