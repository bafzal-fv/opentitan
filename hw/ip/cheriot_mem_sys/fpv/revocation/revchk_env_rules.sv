// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// revchk_env_rules: every assumption of checker 3: a TL-UL ABVIP on each port the testbench plays,
//   the register file rules (contract C20) and the rules on top of the ABVIPs. Bound into
//   cheriot_mem_sys by the bind in revchk_env.sv.
// Data path: none; it constrains what the tool drives: the register file's outputs, the core's
//   requests and the cut tag filter's answers on cored_tl_d, the cut tag filter's meta requests,
//   xbar_main's answers, the access checker's bitmap answers and the RMW filter's answers.
// Figure: cheriot_mem_sys_fpv_revocation_uarch.adoc, figures/src/revchk_layers.svg.
// Obligations: none of its own; each assume_ names its design architecture row (An) or contract
//   (Cn). The ABVIPs assert TL-UL on what the design sends on these ports (tlul_protocol's
//   TL-UL rules hold).
// Spec: designer review, assumptions A2, A6, A9, A10, A12; TB architecture, contracts C1, C2,
//   C6, C7, C20; checker 3 uarch, Environment and Register file model; tlul_abvip uarch.
// Naming: assume_<An or Cn>_<Rule>; x_d next value, x_q current value.
module revchk_env_rules
  import tlul_pkg::*;
  import tlul_abvip_pkg::*;
  import tpchk_pkg::*;
  import revchk_pkg::*;
  import cheriot_mem_sys_reg_pkg::*;
#(
  parameter run_e Run = RunV1  // safety A drops contracts C6, C7; V4 relaxes assumption A6;
                               // liveness B adds assumption A10, contracts C1, C2
) (
  input  logic                         clk_i,
  input  logic                         rst_ni,
  input  prim_mubi_pkg::mubi4_t        cheriot_ena_i,
  // The register file, blackboxed: its outputs, and the two engine writes its rules read
  input  cheriot_mem_sys_regs_reg2hw_t reg2hw_i,
  input  logic                         regwen_i,
  input  logic                         intr_set_i,
  // cored_tl_d: both ends played
  input  tl_h2d_t                      core_h2d_i,
  input  tl_d2h_t                      core_d2h_i,
  // 2:1 tag arbiter input 0: the core's tag filter, cut
  input  tl_h2d_t                      m0_h2d_i,
  input  logic                         m0_tag_i,
  input  bit_sel_t                     m0_bit_sel_i,
  input  tl_d2h_t                      m0_d2h_i,
  // tbre_tl_h
  input  tl_h2d_t                      xbar_h2d_i,
  input  tl_d2h_t                      xbar_d2h_i,
  // The bitmap port: the engine's access checker, blackboxed
  input  tl_h2d_t                      bm_h2d_i,
  input  tl_d2h_t                      bm_d2h_i,
  // The RMW filter upstream: the RMW filter, blackboxed
  input  tl_h2d_t                      rmw_h2d_i,
  input  tl_d2h_t                      rmw_d2h_i
);

  default clocking @(posedge clk_i); endclocking
  /* verilator lint_off SYNCASYNCNET */
  default disable iff (!rst_ni);
  /* verilator lint_on SYNCASYNCNET */

  ////////////////////////////////////////////
  // TL-UL ABVIP on every port the TB plays //
  ////////////////////////////////////////////

  // Role names the end the testbench plays: that end's rules are assumed, the other end's
  // asserted. MaxOutstanding below 2^SrcW limits the port, so it needs a basis (ABVIP D4).
  logic [1:0] core_tf_num_out;
  logic [7:0] core_tf_oldest;
  logic [8:0] xbar_num_out;
  logic [7:0] xbar_oldest;
  // Read only by the liveness rules, which only formal builds compile.
  /* verilator lint_off UNUSEDSIGNAL */
  logic [8:0] bm_num_out;
  logic [8:0] rmw_num_out;
  /* verilator lint_on UNUSEDSIGNAL */

  /* verilator lint_off PINCONNECTEMPTY */
  // cored_tl_d, the core's end: MaxOutstanding 2 is assumption A2 ([ToO] Tag Filter: "Ibex's LSU,
  // which never issues more than two outstanding split-access halves").
  tlul_abvip #(.Role(PlayHost), .MaxOutstanding(2)) u_abvip_core (
    .clk_i, .rst_ni, .h2d_i(core_h2d_i), .d2h_i(core_d2h_i),
    .a_fire_o(), .d_fire_o(), .num_outstanding_o(), .oldest_src_o());

  // cored_tl_d, the cut tag filter's end (D46): MaxOutstanding 2 only sizes the list
  // (assumption A2).
  tlul_abvip #(.Role(PlayDevice), .MaxOutstanding(2)) u_abvip_core_tf (
    .clk_i, .rst_ni, .h2d_i(core_h2d_i), .d2h_i(core_d2h_i),
    .a_fire_o(), .d_fire_o(), .num_outstanding_o(core_tf_num_out), .oldest_src_o(core_tf_oldest));

  // Arbiter input 0: plays the cut core's tag filter. SrcW 7: the arbiter keeps 7 bits of a_source,
  // so its waiting requests differ in those bits (assumption A9, Src_Unique).
  tlul_abvip #(.Role(PlayHost), .SrcW(7)) u_abvip_m0 (
    .clk_i, .rst_ni, .h2d_i(m0_h2d_i), .d2h_i(m0_d2h_i),
    .a_fire_o(), .d_fire_o(), .num_outstanding_o(), .oldest_src_o());

  // tbre_tl_h: plays xbar_main.
  tlul_abvip #(.Role(PlayDevice)) u_abvip_xbar (
    .clk_i, .rst_ni, .h2d_i(xbar_h2d_i), .d2h_i(xbar_d2h_i),
    .a_fire_o(), .d_fire_o(), .num_outstanding_o(xbar_num_out), .oldest_src_o(xbar_oldest));

  // The bitmap port: plays the engine's access checker.
  tlul_abvip #(.Role(PlayDevice)) u_abvip_bitmap (
    .clk_i, .rst_ni, .h2d_i(bm_h2d_i), .d2h_i(bm_d2h_i),
    .a_fire_o(), .d_fire_o(), .num_outstanding_o(bm_num_out), .oldest_src_o());

  // The RMW filter upstream: plays the RMW filter.
  tlul_abvip #(.Role(PlayDevice)) u_abvip_rmw (
    .clk_i, .rst_ni, .h2d_i(rmw_h2d_i), .d2h_i(rmw_d2h_i),
    .a_fire_o(), .d_fire_o(), .num_outstanding_o(rmw_num_out), .oldest_src_o());
  /* verilator lint_on PINCONNECTEMPTY */

  /////////////////////////////////////
  // Port rules on top of the ABVIPs //
  /////////////////////////////////////

  // Assumption A6: the mode keeps its value from reset. V4 (D48; [TB] D3 (b)): one switch, to
  // MuBi4True, while the engine is idle and no start is written in that cycle.
  logic switched_q;
  if (Run == RunV4) begin : gen_v4
    logic start;  // a TBRE_START strobe written 1
    assign start = reg2hw_i.tbre_start.qe && reg2hw_i.tbre_start.q;
    // The CHERIoT mode switches at most once.
    // assumption A6
    assume_Env_ModeSwitchesOnce : assume property (!$stable(cheriot_ena_i) |->
      !switched_q && (cheriot_ena_i == prim_mubi_pkg::MuBi4True) && regwen_i && !start);
  end else begin : gen_stable
    // The CHERIoT mode keeps its value from reset.
    // assumption A6
    assume_Env_ModeStable : assume property ($stable(cheriot_ena_i));
  end

  // xbar_main answers the engine's reads in request order.
  // assumption A12 (DV reading, open question Q23)
  assume_Env_TbreRspInOrder : assume property (xbar_d2h_i.d_valid && (xbar_num_out != '0) |->
    xbar_d2h_i.d_source == xbar_oldest);

  // Contracts C6 and C7 (proven in checker 1), in every run but safety A, which proves checker 1's
  // own assumptions, contracts C3a, C3b, C11, C21, and so may assume none of checker 1's contracts.
  if (Run != RunSafeA) begin : gen_c6_c7
    // The cut core tag filter answers the core in request order.
    // contract C6, proven in checker 1
    assume_Contracts_CoreRspInOrder : assume property (core_d2h_i.d_valid &&
      (core_tf_num_out != '0) |->
      core_d2h_i.d_source == core_tf_oldest);
    // The core's tag filter holds its meta request, tag and bit select until taken.
    // contract C7, proven in checker 1 (spec gap, open question Q12)
    assume_Contracts_CoreMetaReqHeld : assume property (m0_h2d_i.a_valid && !m0_d2h_i.a_ready |=>
      m0_h2d_i.a_valid && is_same_a(m0_h2d_i, $past(m0_h2d_i)) && $stable(m0_tag_i) &&
      $stable(m0_bit_sel_i));
  end

  ///////////////////////////////////
  // The register file model (C20) //
  ///////////////////////////////////

  // [HJSON] TBRE_REGWEN locks TBRE_BASE_ADDR, TBRE_NUM_CAPS and TBRE_START; [REGS] INTR_STATE is
  // rw1c. Every other output of the register file is free (R4).
  logic regwen_q;
  logic intr_set_q;

  // TBRE_BASE_ADDR changes only after a cycle with TBRE_REGWEN 1.
  // contract C20, register file model, rule R1
  assume_Contracts_BaseLockedWhileBusy : assume property (!regwen_q |->
    $stable(reg2hw_i.tbre_base_addr.q));
  // TBRE_NUM_CAPS changes only after a cycle with TBRE_REGWEN 1.
  // contract C20, register file model, rule R1
  assume_Contracts_NumLockedWhileBusy : assume property (!regwen_q |->
    $stable(reg2hw_i.tbre_num_caps.q));
  // The TBRE_START strobe comes only in a cycle with TBRE_REGWEN 1.
  // contract C20, register file model, rule R2
  assume_Contracts_StartOnlyWhenIdle : assume property (reg2hw_i.tbre_start.qe |-> regwen_i);
  // INTR_STATE.tbre_done rises only in the cycle after its set request.
  // contract C20, register file model, rule R3
  assume_Contracts_IntrSetAfterReq : assume property ($rose(reg2hw_i.intr_state.q) |-> intr_set_q);

  ////////////////////////////////
  // Liveness B: fairness rules //
  ////////////////////////////////

  // Assumption A10 (the condition of REQ_TBRE_37; DV reading, Q24): xbar_main accepts and answers.
  // Contract C1 (checker 2): the engine's access checker accepts the lookups and answers. Contract
  // C2 (checker 1): the RMW filter accepts and answers. Formal only: a simulation ends.
  if (Run == RunLiveB) begin : gen_live_b
`ifdef FPV_ON
`ifndef VERILATOR
    // xbar_main accepts every request offered, at some point.
    // assumption A10
    assume_Env_XbarAcceptsReq : assume property (xbar_h2d_i.a_valid |->
      s_eventually xbar_d2h_i.a_ready);
    // xbar_main answers every request it took, at some point.
    // assumption A10
    assume_Env_XbarAnswersReq : assume property (xbar_num_out != '0 |->
      s_eventually xbar_d2h_i.d_valid);
    // The access checker accepts every request presented, at some point.
    // contract C1, proven in checker 2
    assume_Contracts_AccessReqAccepted : assume property (bm_h2d_i.a_valid |->
      s_eventually bm_d2h_i.a_ready);
    // The access checker answers every request it accepted, at some point.
    // contract C1, proven in checker 2
    assume_Contracts_AccessReqAnswered : assume property (bm_num_out != '0 |->
      s_eventually bm_d2h_i.d_valid);
    // The RMW filter accepts every request presented, at some point.
    // contract C2, proven in checker 1
    assume_Contracts_RmwReqAccepted : assume property (rmw_h2d_i.a_valid |->
      s_eventually rmw_d2h_i.a_ready);
    // The RMW filter answers every request it accepted, at some point.
    // contract C2, proven in checker 1
    assume_Contracts_RmwReqAnswered : assume property (rmw_num_out != '0 |->
      s_eventually rmw_d2h_i.d_valid);
`endif
`endif
  end

  ///////////
  // State //
  ///////////

  // TBRE_REGWEN resets to 1 ([REGS]).
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      regwen_q   <= 1'b1;
      intr_set_q <= 1'b0;
      switched_q <= 1'b0;
    end else begin
      regwen_q   <= regwen_i;
      intr_set_q <= intr_set_i;
      switched_q <= switched_q || !$stable(cheriot_ena_i);
    end
  end

endmodule
