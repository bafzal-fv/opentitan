// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// revchk_checker_bind: binds checker 3's checker into cheriot_mem_sys, in FPV and in simulation.
// Data path: cheriot_mem_sys ports, internal nets and the engine's internal ports ->
//   revchk_checker's spec-named ports.
// Figure: cheriot_mem_sys_fpv_revocation_uarch.adoc, figures/src/revchk_boundary.svg.
// Obligations: none; wiring only. With revchk_env, the only files with RTL names.
// Spec: TB architecture, Checker 3; checker 3 uarch, Testbench structure and Simulation.
// Naming: RTL names on the right, spec names on the left. Define REVCHK_RUN to a revchk_pkg::run_e
//   value for another run than V1 (formal only).
`ifndef REVCHK_RUN
  `define REVCHK_RUN revchk_pkg::RunV1
`endif

// No implicit nets: a misspelt RTL name fails instead of creating a floating wire.
`default_nettype none

bind cheriot_mem_sys revchk_checker #(
  .Run(`REVCHK_RUN)
) u_revchk_checker (
  .clk_i,
  .rst_ni,
  .cheriot_ena_i,
  // The register file (u_reg_regs): its outputs and the engine's writes into it; the interrupt
  .reg2hw_i       (reg2hw),
  .hw2reg_i       (hw2reg),
  .intr_i         (intr_tbre_done_o),
  // cored_tl_d with its tag sideband
  .core_h2d_i     (cored_tl_d_i),
  .core_tag_i     (cored_tag_h2d_i),
  .core_d2h_i     (cored_tl_d_o),
  // The engine (u_cheriot_tbre): its read port, the TRVK filter's downstream port (socket input
  // 0), its clear port (socket input 1), its tag filter's device port (the socket's output)
  .rd_h2d_i       (u_cheriot_tbre.mover_r_tl_h2d),
  .rd_d2h_i       (u_cheriot_tbre.mover_r_tl_d2h),
  .trvk_h2d_i     (u_cheriot_tbre.sock_tl_h2d[0]),
  .trvk_d2h_i     (u_cheriot_tbre.sock_tl_d2h[0]),
  .trvk_tag_rsp_i (u_cheriot_tbre.sock_tag_d2h[0]),
  .clr_h2d_i      (u_cheriot_tbre.sock_tl_h2d[1]),
  .clr_d2h_i      (u_cheriot_tbre.sock_tl_d2h[1]),
  .tf_h2d_i       (u_cheriot_tbre.filter_tl_h2d),
  .tf_tag_i       (u_cheriot_tbre.filter_tag_h2d),
  .tf_d2h_i       (u_cheriot_tbre.filter_tl_d2h),
  .tf_tag_rsp_i   (u_cheriot_tbre.filter_tag_d2h),
  // tbre_tl_h; the bitmap port
  .xbar_h2d_i     (tbre_tl_h_o),
  .xbar_d2h_i     (tbre_tl_h_i),
  .bm_h2d_i       (tbre_revbm_tl_h2d),
  .bm_d2h_i       (tbre_revbm_tl_d2h),
  // 2:1 tag arbiter (u_cheriot_socket_m1) inputs: 0 the core's tag filter, 1 the engine's
  .m_h2d_i        (tag_mux_in_tl_h2d),
  .m_tag_i        (tag_mux_in_tag_h2d),
  .m_bit_sel_i    (tag_mux_in_bit_sel),
  .m_d2h_i        (tag_mux_in_tl_d2h),
  .m_tag_rsp_i    (tag_mux_in_tag_d2h),
  // Arbiter output; the tag clear squash; the RMW filter (u_cheriot_rmw_filter) upstream
  .arb_h2d_i      (rmw_sock_tl_h2d),
  .arb_tag_i      (rmw_tag_h2d),
  .arb_bit_sel_i  (rmw_bit_sel),
  .rmw_h2d_i      (rmw_tl_h2d),
  .rmw_d2h_i      (rmw_tl_d2h),
  // The alert logic's fault inputs, and the alert sender's own request input ([TB] D12)
  .engine_fault_i ({cheriot_fatal_error.tbre_mover_error,
                    cheriot_fatal_error.tbre_revbm_intg,
                    cheriot_fatal_error.tbre_revbm_data_intg,
                    cheriot_fatal_error.tbre_revbm_error}),
  .rmw_fault_i    (cheriot_fatal_error.rmw_error || cheriot_fatal_error.meta_sram_intg ||
                   cheriot_fatal_error.meta_sram_data_intg),
  .fault_any_i    (|cheriot_fatal_error),
  .alert_req_i    (u_prim_alert_sender_fatal_fault.alert_req_i)
);

`default_nettype wire
