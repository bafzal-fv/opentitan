// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Binds the checker into cheriot_mem_sys, in formal and in simulation. This is the one file that
// names the design's internal nets (on the right of each connection): a renamed net is fixed
// here and nowhere else.

// No implicit nets: a misspelt RTL name fails instead of creating a floating wire.
`default_nettype none

bind cheriot_mem_sys cheriot_mem_sys_fpv_checker u_fpv_checker (
  .clk_i,
  .rst_ni,
  .cheriot_ena_i,

  // cored_tl_d with its tag sideband, and cored_tl_h
  .cored_tl_d_h2d_i     (cored_tl_d_i),
  .cored_tag_h2d_i,
  .cored_tl_d_d2h_i     (cored_tl_d_o),
  .cored_tag_d2h_i      (cored_tag_d2h_o),
  .cored_tl_h_h2d_i     (cored_tl_h_o),
  .cored_tl_h_d2h_i     (cored_tl_h_i),

  // 2:1 tag arbiter (u_cheriot_socket_m1) inputs and output; the RMW filter
  // (u_cheriot_rmw_filter) upstream, after the tag clear squash
  .tag_mux_in_tl_h2d_i  (tag_mux_in_tl_h2d),
  .tag_mux_in_tag_h2d_i (tag_mux_in_tag_h2d),
  .tag_mux_in_bit_sel_i (tag_mux_in_bit_sel),
  .tag_mux_in_tl_d2h_i  (tag_mux_in_tl_d2h),
  .tag_mux_in_tag_d2h_i (tag_mux_in_tag_d2h),
  .rmw_sock_tl_h2d_i    (rmw_sock_tl_h2d),
  .rmw_tag_h2d_i        (rmw_tag_h2d),
  .rmw_bit_sel_i        (rmw_bit_sel),
  .rmw_tl_h2d_i         (rmw_tl_h2d),
  .rmw_tl_d2h_i         (rmw_tl_d2h),
  .rmw_tag_d2h_i        (rmw_tag_d2h),

  // The tag port: u_cheriot_rmw_filter downstream, u_cheriot_access_check_tags upstream
  .tags_tl_h2d_i        (tags_tl_h2d),
  .tags_tl_d2h_i        (tags_tl_d2h),

  // Fault inputs of the alert logic, and the alert sender's request
  .wtrc_fault_i         (cheriot_fatal_error.wtrc_error),
  .rmw_dev_fault_i      (cheriot_fatal_error.rmw_error),
  .rmw_intg_fault_i     (cheriot_fatal_error.meta_sram_intg ||
                         cheriot_fatal_error.meta_sram_data_intg),
  .alert_req_i          (u_prim_alert_sender_fatal_fault.alert_req_i),

  // The bitmap ports: the core's TRVK filter, xbar_main's window, the engine (u_cheriot_tbre)
  .corerevbm_tl_h2d_i   (corerevbm_tl_i),
  .corerevbm_tl_d2h_i   (corerevbm_tl_o),
  .revbm_tl_d_h2d_i     (revbm_tl_d_i),
  .revbm_tl_d_d2h_i     (revbm_tl_d_o),
  .tbre_revbm_tl_h2d_i  (tbre_revbm_tl_h2d),
  .tbre_revbm_tl_d2h_i  (tbre_revbm_tl_d2h),

  // The 4:1 arbiter's (u_tlul_socket_m1) inputs: the four access checkers' outputs; meta_sram_tl
  .meta_mux_in_tl_h2d_i (meta_mux_in_tl_h2d),
  .meta_mux_in_tl_d2h_i (meta_mux_in_tl_d2h),
  .meta_sram_tl_h2d_i   (meta_sram_tl_o),
  .meta_sram_tl_d2h_i   (meta_sram_tl_i),

  // regs_tl_d and the register file's (u_reg_regs) two sides
  .regs_tl_d_h2d_i      (regs_tl_d_i),
  .regs_tl_d_d2h_i      (regs_tl_d_o),
  .reg2hw_i             (reg2hw),
  .hw2reg_i             (hw2reg)
);

`default_nettype wire
