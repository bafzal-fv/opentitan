// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// The one checker bound into cheriot_mem_sys. It only wires: every port of the design and the
// internal nets the checkers observe come in here, and each checker gets the ones it needs.
// Checker 1 watches the tag path and the register-file unit the registers. Each checker holds its
// own rules on what its neighbours send, so this module works unchanged in a formal build (rules
// assumed) and in a simulation build (rules asserted). Checker 2 (meta access) and checker 3 (the
// revocation engine) join here once their SV is written and agreed.
//
// A port is named after the design net or interface it carries, with the channel (h2d, d2h) for
// a TL-UL one; the checkers' own ports keep the names the spec uses.
module cheriot_mem_sys_fpv_checker
  import tlul_abvip_pkg::*;
(
  // Clock, reset and the mode
  input  logic                  clk_i,
  input  logic                  rst_ni,
  input  prim_mubi_pkg::mubi4_t cheriot_ena_i,

  // cored_tl_d with its tag sideband, and cored_tl_h
  input  tlul_pkg::tl_h2d_t     cored_tl_d_h2d_i,
  input  logic                  cored_tag_h2d_i,
  input  tlul_pkg::tl_d2h_t     cored_tl_d_d2h_i,
  input  logic                  cored_tag_d2h_i,
  input  tlul_pkg::tl_h2d_t     cored_tl_h_h2d_i,
  input  tlul_pkg::tl_d2h_t     cored_tl_h_d2h_i,

  // The 2:1 tag arbiter's inputs and output, and the RMW filter upstream (after the squash)
  input  tlul_pkg::tl_h2d_t     tag_mux_in_tl_h2d_i [2],
  input  logic                  tag_mux_in_tag_h2d_i [2],
  input  logic [4:0]            tag_mux_in_bit_sel_i [2],
  input  tlul_pkg::tl_d2h_t     tag_mux_in_tl_d2h_i [2],
  input  logic                  tag_mux_in_tag_d2h_i [2],
  input  tlul_pkg::tl_h2d_t     rmw_sock_tl_h2d_i,
  input  logic                  rmw_tag_h2d_i,
  input  logic [4:0]            rmw_bit_sel_i,
  input  tlul_pkg::tl_h2d_t     rmw_tl_h2d_i,
  input  tlul_pkg::tl_d2h_t     rmw_tl_d2h_i,
  input  logic                  rmw_tag_d2h_i,

  // The tag port: the RMW filter downstream, the tag access checker upstream
  input  tlul_pkg::tl_h2d_t     tags_tl_h2d_i,
  input  tlul_pkg::tl_d2h_t     tags_tl_d2h_i,

  // The fault inputs of the alert logic, and the alert sender's request
  input  logic                  wtrc_fault_i,
  input  logic                  rmw_dev_fault_i,
  input  logic                  rmw_intg_fault_i,
  input  logic                  alert_req_i,

  // Checker 2's ports, wired for it already: the bitmap ports (the core's TRVK filter,
  // xbar_main's window, the engine), the 4:1 arbiter's inputs and meta_sram_tl. Unused until it
  // joins.
  /* verilator lint_off UNUSEDSIGNAL */
  input  tlul_pkg::tl_h2d_t     corerevbm_tl_h2d_i,
  input  tlul_pkg::tl_d2h_t     corerevbm_tl_d2h_i,
  input  tlul_pkg::tl_h2d_t     revbm_tl_d_h2d_i,
  input  tlul_pkg::tl_d2h_t     revbm_tl_d_d2h_i,
  input  tlul_pkg::tl_h2d_t     tbre_revbm_tl_h2d_i,
  input  tlul_pkg::tl_d2h_t     tbre_revbm_tl_d2h_i,

  // The 4:1 arbiter's inputs, and meta_sram_tl
  input  tlul_pkg::tl_h2d_t     meta_mux_in_tl_h2d_i [4],
  input  tlul_pkg::tl_d2h_t     meta_mux_in_tl_d2h_i [4],
  input  tlul_pkg::tl_h2d_t     meta_sram_tl_h2d_i,
  input  tlul_pkg::tl_d2h_t     meta_sram_tl_d2h_i,
  /* verilator lint_on UNUSEDSIGNAL */
  // regs_tl_d and the register file's two sides: to the hardware, from the hardware
  input  tlul_pkg::tl_h2d_t                             regs_tl_d_h2d_i,
  input  tlul_pkg::tl_d2h_t                             regs_tl_d_d2h_i,
  input  cheriot_mem_sys_reg_pkg::cheriot_mem_sys_regs_reg2hw_t reg2hw_i,
  input  cheriot_mem_sys_reg_pkg::cheriot_mem_sys_regs_hw2reg_t hw2reg_i
);

  // The buses at the edge of the subsystem are watched here, not inside one checker, because
  // they belong to the whole subsystem: every checker sees the same instance and the same rules
  // (TB architecture, "Where each bus checker sits"). In a formal build the testbench plays the
  // far end of each bus; in a simulation build the real neighbour drives it, so the same
  // instance asserts both ends and assumes nothing.
`ifdef FPV_ON
  localparam role_e HostRole   = PlayHost;
  localparam role_e DeviceRole = PlayDevice;
`else
  localparam role_e HostRole   = CheckBoth;
  localparam role_e DeviceRole = CheckBoth;
`endif

  logic       core_a_fire;
  logic       core_d_fire;
  logic [2:0] xbar_num_out;

  /* verilator lint_off PINCONNECTEMPTY */
  // The core's data port. MaxOutstanding 2 is assumption A2 ([ToO] Tag Filter: "Ibex's LSU,
  // which never issues more than two outstanding split-access halves"): a third request is
  // presented only in the cycle an answer is taken. HostReqHeld: the core holds a request until
  // it is accepted (assumption A1). DevSameCycleRsp 0: the subsystem never answers in the cycle
  // it accepts the request, asserted here because the tool plays the host.
  tlul_abvip #(.Role(HostRole), .MaxOutstanding(2), .DevSameCycleRsp(1'b0),
               .HostReqHeld(1'b1)) u_abvip_core (
    .clk_i, .rst_ni, .h2d_i(cored_tl_d_h2d_i), .d2h_i(cored_tl_d_d2h_i),
    .a_fire_o(core_a_fire), .d_fire_o(core_d_fire), .num_outstanding_o(), .oldest_src_o());

  // The host port to xbar_main. MaxOutstanding 4 only sizes the list: the tag filter forwards
  // each core request once, so assumption A2 keeps the requests here at three or fewer.
  // DevSameCycleRsp 0, DevInOrderRsp, DevRspHeld: xbar_main answers in a later cycle, in request
  // order, and holds each answer until taken (assumptions A14, A7 and A15). HostReqHeld: the
  // subsystem holds its request until accepted.
  tlul_abvip #(.Role(DeviceRole), .MaxOutstanding(4), .DevSameCycleRsp(1'b0),
               .DevInOrderRsp(1'b1), .DevRspHeld(1'b1), .HostReqHeld(1'b1)) u_abvip_xbar (
    .clk_i, .rst_ni, .h2d_i(cored_tl_h_h2d_i), .d2h_i(cored_tl_h_d2h_i),
    .a_fire_o(), .d_fire_o(), .num_outstanding_o(xbar_num_out), .oldest_src_o());
  /* verilator lint_on PINCONNECTEMPTY */

  // Checker 1, the tag path.
  tpchk_checker u_tpchk_checker (
    .clk_i,
    .rst_ni,
    .cheriot_ena_i,
    .core_h2d_i       (cored_tl_d_h2d_i),
    .core_tag_i       (cored_tag_h2d_i),
    .core_d2h_i       (cored_tl_d_d2h_i),
    .core_tag_rsp_i   (cored_tag_d2h_i),
    .xbar_h2d_i       (cored_tl_h_h2d_i),
    .xbar_d2h_i       (cored_tl_h_d2h_i),
    .core_a_fire_i    (core_a_fire),
    .core_d_fire_i    (core_d_fire),
    .xbar_num_out_i   (xbar_num_out),
    .m_h2d_i          (tag_mux_in_tl_h2d_i),
    .m_tag_i          (tag_mux_in_tag_h2d_i),
    .m_bit_sel_i      (tag_mux_in_bit_sel_i),
    .m_d2h_i          (tag_mux_in_tl_d2h_i),
    .m_tag_rsp_i      (tag_mux_in_tag_d2h_i),
    .arb_h2d_i        (rmw_sock_tl_h2d_i),
    .arb_tag_i        (rmw_tag_h2d_i),
    .arb_bit_sel_i    (rmw_bit_sel_i),
    .rmw_h2d_i        (rmw_tl_h2d_i),
    .rmw_d2h_i        (rmw_tl_d2h_i),
    .rmw_tag_rsp_i    (rmw_tag_d2h_i),
    .tags_h2d_i       (tags_tl_h2d_i),
    .tags_d2h_i       (tags_tl_d2h_i),
    .wtrc_fault_i,
    .rmw_dev_fault_i,
    .rmw_intg_fault_i,
    .alert_req_i
  );

  // The register-file unit: contract C20 and the register rows the generic CSR tests cannot reach.
  rfchk_checker u_rfchk_checker (
    .clk_i,
    .rst_ni,
    .regs_h2d_i (regs_tl_d_h2d_i),
    .regs_d2h_i (regs_tl_d_d2h_i),
    .reg2hw_i,
    .hw2reg_i
  );

endmodule
