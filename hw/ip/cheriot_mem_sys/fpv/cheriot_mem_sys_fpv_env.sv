// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// The FPV top: cheriot_mem_sys as the design under test, with every input left free so that the
// formal tool drives it in every cycle. The checker is not instantiated here; it is bound into
// the design by cheriot_mem_sys_fpv_checker_bind.sv, so the same top serves formal and simulation.
// The checker's rules on what the neighbours send keep the free inputs legal.
module cheriot_mem_sys_fpv_env
  import cheriot_mem_sys_reg_pkg::*;
(
  // Clock, reset and the mode
  input  logic                                      clk_i,
  input  logic                                      rst_ni,
  input  prim_mubi_pkg::mubi4_t                     cheriot_ena_i,

  // The engine's interrupt and the fatal alert
  output logic                                      intr_tbre_done_o,
  input  prim_alert_pkg::alert_rx_t [NumAlerts-1:0] alert_rx_i,
  output prim_alert_pkg::alert_tx_t [NumAlerts-1:0] alert_tx_o,

  // regs_tl_d: the registers
  input  tlul_pkg::tl_h2d_t                         regs_tl_d_i,
  output tlul_pkg::tl_d2h_t                         regs_tl_d_o,

  // cored_tl_d with its tag sideband: the core's data port
  input  tlul_pkg::tl_h2d_t                         cored_tl_d_i,
  input  logic                                      cored_tag_h2d_i,
  output tlul_pkg::tl_d2h_t                         cored_tl_d_o,
  output logic                                      cored_tag_d2h_o,

  // corerevbm_tl and revbm_tl_d: the bitmap ports of the core's TRVK filter and of xbar_main
  input  tlul_pkg::tl_h2d_t                         corerevbm_tl_i,
  output tlul_pkg::tl_d2h_t                         corerevbm_tl_o,
  input  tlul_pkg::tl_h2d_t                         revbm_tl_d_i,
  output tlul_pkg::tl_d2h_t                         revbm_tl_d_o,

  // cored_tl_h and tbre_tl_h: the host ports to xbar_main
  output tlul_pkg::tl_h2d_t                         cored_tl_h_o,
  input  tlul_pkg::tl_d2h_t                         cored_tl_h_i,
  output tlul_pkg::tl_h2d_t                         tbre_tl_h_o,
  input  tlul_pkg::tl_d2h_t                         tbre_tl_h_i,

  // meta_sram_tl
  output tlul_pkg::tl_h2d_t                         meta_sram_tl_o,
  input  tlul_pkg::tl_d2h_t                         meta_sram_tl_i
);

  // Every input of the FPV top is free: the formal tool picks it in every cycle.
  cheriot_mem_sys u_dut (.*);

endmodule

