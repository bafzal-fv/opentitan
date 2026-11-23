// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// revchk_env: the FPV top of checker 3: cheriot_mem_sys, with every input of it a free input; and,
//   after it, the bind that adds the assumptions (revchk_env_rules), in FPV only.
//   revchk_checker_bind adds the checker. A simulation that checks the assumptions binds
//   revchk_env_rules itself.
// Data path: free inputs -> cheriot_mem_sys; revchk_env_rules keeps them, and the outputs of the
//   blocks the task removes, legal; revchk_checker checks what cheriot_mem_sys does.
// Figure: cheriot_mem_sys_fpv_revocation_uarch.adoc, figures/src/revchk_layers.svg.
// Obligations: none; wiring only.
// Spec: TB architecture, Checker 3; checker 3 uarch, Testbench structure.
// Naming: the ports are cheriot_mem_sys's own; in the bind, RTL names on the right, spec names
//   on the left. Define REVCHK_RUN to revchk_pkg::RunSafeA, RunV3, RunV4, RunLiveA or RunLiveB for
//   another run than V1.
module revchk_env
  import cheriot_mem_sys_reg_pkg::*;
(
  input  logic                                      clk_i,
  input  logic                                      rst_ni,
  input  prim_mubi_pkg::mubi4_t                     cheriot_ena_i,
  output logic                                      intr_tbre_done_o,
  input  prim_alert_pkg::alert_rx_t [NumAlerts-1:0] alert_rx_i,
  output prim_alert_pkg::alert_tx_t [NumAlerts-1:0] alert_tx_o,
  input  tlul_pkg::tl_h2d_t                         regs_tl_d_i,
  output tlul_pkg::tl_d2h_t                         regs_tl_d_o,
  input  tlul_pkg::tl_h2d_t                         cored_tl_d_i,
  input  logic                                      cored_tag_h2d_i,
  output tlul_pkg::tl_d2h_t                         cored_tl_d_o,
  output logic                                      cored_tag_d2h_o,
  input  tlul_pkg::tl_h2d_t                         corerevbm_tl_i,
  output tlul_pkg::tl_d2h_t                         corerevbm_tl_o,
  input  tlul_pkg::tl_h2d_t                         revbm_tl_d_i,
  output tlul_pkg::tl_d2h_t                         revbm_tl_d_o,
  output tlul_pkg::tl_h2d_t                         cored_tl_h_o,
  input  tlul_pkg::tl_d2h_t                         cored_tl_h_i,
  output tlul_pkg::tl_h2d_t                         tbre_tl_h_o,
  input  tlul_pkg::tl_d2h_t                         tbre_tl_h_i,
  output tlul_pkg::tl_h2d_t                         meta_sram_tl_o,
  input  tlul_pkg::tl_d2h_t                         meta_sram_tl_i
);

  // Every input of the FPV top is free: the formal tool picks it in every cycle.
  cheriot_mem_sys u_dut (.*);

endmodule

// The bind of the assumptions.
`ifndef REVCHK_RUN
  `define REVCHK_RUN revchk_pkg::RunV1
`endif

// No implicit nets: a misspelt RTL name fails instead of creating a floating wire.
`default_nettype none

bind cheriot_mem_sys revchk_env_rules #(
  .Run (`REVCHK_RUN)
) u_revchk_env_rules (
  .clk_i,
  .rst_ni,
  .cheriot_ena_i,
  // The register file (u_reg_regs), blackboxed: its outputs, and the engine's writes its rules read
  .reg2hw_i     (reg2hw),
  .regwen_i     (hw2reg.tbre_regwen.d),
  .intr_set_i   (hw2reg.intr_state.de && hw2reg.intr_state.d),
  // cored_tl_d: the core and the cut core's tag filter (u_cheriot_tag_filter)
  .core_h2d_i   (cored_tl_d_i),
  .core_d2h_i   (cored_tl_d_o),
  // 2:1 tag arbiter (u_cheriot_socket_m1) input 0: the cut core's tag filter
  .m0_h2d_i     (tag_mux_in_tl_h2d[0]),
  .m0_tag_i     (tag_mux_in_tag_h2d[0]),
  .m0_bit_sel_i (tag_mux_in_bit_sel[0]),
  .m0_d2h_i     (tag_mux_in_tl_d2h[0]),
  // tbre_tl_h
  .xbar_h2d_i   (tbre_tl_h_o),
  .xbar_d2h_i   (tbre_tl_h_i),
  // The bitmap port (u_cheriot_access_check_tbre, blackboxed)
  .bm_h2d_i     (tbre_revbm_tl_h2d),
  .bm_d2h_i     (tbre_revbm_tl_d2h),
  // The RMW filter (u_cheriot_rmw_filter, blackboxed) upstream, after the tag clear squash
  .rmw_h2d_i    (rmw_tl_h2d),
  .rmw_d2h_i    (rmw_tl_d2h)
);

`default_nettype wire
