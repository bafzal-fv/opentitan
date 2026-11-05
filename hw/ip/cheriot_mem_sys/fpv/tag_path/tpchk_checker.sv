// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Checker 1, the tag path: the core's tag filter with its WTRC, the 2:1 tag arbiter and the RMW
// filter. Two models predict from the spec what each block must send; the properties compare the
// ports with the predictions, one section per testpoint of the testplan, in five groups: tag
// filter, WTRC, arbiter, RMW filter, then the alerts and the contracts other checkers rely on.
// The rules at the end say what the neighbours send: a TL-UL ABVIP on each of the four ports the
// testbench plays, plus the few rules this design needs on top (ENV_RULE: assumed in formal,
// asserted in simulation; the fairness rules exist in formal only). Two more ABVIPs check TL-UL
// on the links between real blocks.
//
// Ports keep the spec's names; <port>_ev carries a port's events; u_<model> are the models.
`include "cheriot_mem_sys_fpv_rule.svh"

module tpchk_checker
  import tlul_pkg::*;
  import tlul_abvip_pkg::*;
  import tpchk_pkg::*;
(
  input  logic                  clk_i,
  input  logic                  rst_ni,
  input  prim_mubi_pkg::mubi4_t cheriot_ena_i,

  // cored_tl_d with its tag sideband, cored_tl_h
  input  tl_h2d_t               core_h2d_i,
  input  logic                  core_tag_i,
  input  tl_d2h_t               core_d2h_i,
  input  logic                  core_tag_rsp_i,
  input  tl_h2d_t               xbar_h2d_i,
  input  tl_d2h_t               xbar_d2h_i,

  // What the two bus checkers in the shared checker see on those two ports: the cycles a core
  // request is accepted and a core answer taken, and how many requests xbar_main still owes.
  input  logic                  core_a_fire_i,
  input  logic                  core_d_fire_i,
  input  logic [2:0]            xbar_num_out_i,

  // 2:1 tag arbiter inputs: 0 the core's tag filter, 1 the engine's
  input  tl_h2d_t               m_h2d_i [2],
  input  logic                  m_tag_i [2],
  input  bit_sel_t              m_bit_sel_i [2],
  input  tl_d2h_t               m_d2h_i [2],
  input  logic                  m_tag_rsp_i [2],

  // Arbiter output, RMW filter upstream (after the squash) and downstream
  input  tl_h2d_t               arb_h2d_i,
  input  logic                  arb_tag_i,
  input  bit_sel_t              arb_bit_sel_i,
  input  tl_h2d_t               rmw_h2d_i,
  input  tl_d2h_t               rmw_d2h_i,
  input  logic                  rmw_tag_rsp_i,
  input  tl_h2d_t               tags_h2d_i,
  input  tl_d2h_t               tags_d2h_i,

  // Fault inputs of the alert logic, and the alert sender's request
  input  logic                  wtrc_fault_i,
  input  logic                  rmw_dev_fault_i,
  input  logic                  rmw_intg_fault_i,

  // Read only by the liveness checks, which only formal builds compile.
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic                  alert_req_i
  /* verilator lint_on UNUSEDSIGNAL */
);

  // The core request the tracker follows. FPV: undriven, so the formal tool picks it in every
  // cycle. Simulation: 1, so the tracker follows the next request whenever it is free.
`ifdef FPV_ON
  /* verilator lint_off UNDRIVEN */
  logic pick;
  /* verilator lint_on UNDRIVEN */
`else
  logic pick;
  assign pick = 1'b1;
`endif

  default clocking @(posedge clk_i); endclocking
  /* verilator lint_off SYNCASYNCNET */
  default disable iff (!rst_ni);
  /* verilator lint_on SYNCASYNCNET */

  logic ena;
  assign ena = is_ena(cheriot_ena_i);

  /////////////////
  // Port events //
  /////////////////

  // [TLUL] Signals: a beat passes in a cycle where valid and ready are both high.
  ev_t core_ev, xbar_ev, arb_ev, rmw_ev, tags_ev;
  ev_t m_ev [2];

  assign core_ev = port_ev(core_h2d_i, core_d2h_i);
  assign xbar_ev = port_ev(xbar_h2d_i, xbar_d2h_i);
  assign m_ev[0] = port_ev(m_h2d_i[0], m_d2h_i[0]);
  assign m_ev[1] = port_ev(m_h2d_i[1], m_d2h_i[1]);

  // The squash only rewrites an engine clear's opcode: arbiter output and RMW filter upstream
  // share a_ready and the D channel.
  assign arb_ev  = port_ev(arb_h2d_i, rmw_d2h_i);
  assign rmw_ev  = port_ev(rmw_h2d_i, rmw_d2h_i);
  assign tags_ev = port_ev(tags_h2d_i, tags_d2h_i);

  ////////////
  // Models //
  ////////////

  logic    head_vld, head_xbar_answered, head_xbar_err, head_xbar_bad_intg, head_match;
  idx_t    pres_idx;
  logic    head_meta_answered, head_meta_err, head_tag_chk, head_tag;
  logic    head_tag_wr, head_tag_wr_maybe;
  logic    pop, xbar_answer_vld;
  logic    tag_wr_owed, tag_wr_maybe_owed, meta_is_tag_wr;
  logic    word_cause_now, cause_seen;
  ent_t    pres, head, xbar_answer_ent;
  logic    trk_head, trk_xbar_answered;
  tl_d2h_t trk_xbar_answer;
  addr_t   tag_wr_addr;
  cap_e    cap_state;

  // The model's capture and out-of-order outputs are read only by the checks on broken core
  // sequences, which are out of scope: the core never issues them (testplan, tf_sticky_tag and
  // wtrc_faults).
  /* verilator lint_off PINCONNECTEMPTY */
  tpchk_tf_model u_tf_model (
    .clk_i,
    .rst_ni,
    .pick_i                 (pick),
    .core_h2d_i,
    .core_tag_i,
    .core_d2h_i,
    .core_ev_i              (core_ev),
    .ena_i                  (ena),
    .xbar_d2h_i,
    .xbar_ev_i              (xbar_ev),
    .m_h2d_i                (m_h2d_i[0]),
    .m_tag_i                (m_tag_i[0]),
    .m_bit_sel_i             (m_bit_sel_i[0]),
    .m_d2h_i                (m_d2h_i[0]),
    .m_tag_rsp_i            (m_tag_rsp_i[0]),
    .m_ev_i                 (m_ev[0]),
    .pres_idx_o             (pres_idx),
    .pres_o                 (pres),
    .head_vld_o             (head_vld),
    .head_o                 (head),
    .head_xbar_answered_o   (head_xbar_answered),
    .head_xbar_err_o        (head_xbar_err),
    .head_xbar_bad_intg_o   (head_xbar_bad_intg),
    .head_match_o           (head_match),
    .head_meta_answered_o   (head_meta_answered),
    .head_meta_err_o        (head_meta_err),
    .head_tag_chk_o         (head_tag_chk),
    .head_tag_o             (head_tag),
    .head_tag_wr_o          (head_tag_wr),
    .head_tag_wr_maybe_o    (head_tag_wr_maybe),
    .capture_o              (),
    .capture_tag_o          (),
    .capture_wr_o           (),
    .pop_o                  (pop),
    .xbar_answer_vld_o      (xbar_answer_vld),
    .xbar_answer_ent_o      (xbar_answer_ent),
    .tag_wr_owed_o          (tag_wr_owed),
    .tag_wr_maybe_owed_o    (tag_wr_maybe_owed),
    .tag_wr_addr_o          (tag_wr_addr),
    .meta_is_tag_wr_o       (meta_is_tag_wr),
    .cap_state_o            (cap_state),
    .cap_addr_o             (),
    .word_cause_now_o       (word_cause_now),
    .out_of_seq_cause_now_o (),
    .cause_seen_o           (cause_seen),
    .trk_head_o             (trk_head),
    .trk_xbar_answered_o    (trk_xbar_answered),
    .trk_xbar_answer_o      (trk_xbar_answer)
  );
  /* verilator lint_on PINCONNECTEMPTY */

  op_t      cur, get_op, ans_op;
  logic     can_take, get_slot, get_slot_new, wb_slot, ans_op_vld, ans_get_in, ans_get_err;
  logic     ans_bit_eq, ans_wb_need, ans_wb_in, ans_wb_err, dev_err_seen, intg_err_seen;
  logic     ans_faulty;
  word_t    wb_word, ans_word;
  tl_d_op_e ans_wb_op;

  tpchk_rmw_model u_rmw_model (
    .clk_i,
    .rst_ni,
    .rmw_h2d_i,
    .rmw_tag_i      (arb_tag_i),
    .rmw_bit_sel_i   (arb_bit_sel_i),
    .rmw_ev_i       (rmw_ev),
    .tags_d2h_i,
    .tags_ev_i      (tags_ev),
    .cur_o          (cur),
    .can_take_o     (can_take),
    .get_slot_o     (get_slot),
    .get_op_o       (get_op),
    .get_slot_new_o (get_slot_new),
    .wb_slot_o      (wb_slot),
    .wb_word_o      (wb_word),
    .ans_op_o       (ans_op),
    .ans_op_vld_o   (ans_op_vld),
    .ans_get_in_o   (ans_get_in),
    .ans_get_err_o  (ans_get_err),
    .ans_faulty_o   (ans_faulty),
    .ans_word_o     (ans_word),
    .ans_bit_eq_o   (ans_bit_eq),
    .ans_wb_need_o  (ans_wb_need),
    .ans_wb_in_o    (ans_wb_in),
    .ans_wb_err_o   (ans_wb_err),
    .ans_wb_op_o    (ans_wb_op),
    .dev_err_seen_o (dev_err_seen),
    .intg_err_seen_o(intg_err_seen)
  );

  ///////////////////////////////////////
  // Tag filter: tf_forward to tf_flow //
  ///////////////////////////////////////

  logic pres_cap_store;
  logic head_cap_store;
  logic head_parts;
  logic m_is_lookup;
  logic merged;
  assign pres_cap_store = pres.kind == KindCapStore;
  assign head_cap_store = head.kind == KindCapStore;

  // Every part of the head's answer has arrived: the xbar answer, and the meta answer if looked up.
  assign head_parts     = head_xbar_answered && (!head.lookup || head_meta_answered);

  // A meta request that is no WTRC tag write: the presented request's lookup.
  assign m_is_lookup    = m_ev[0].req_vld && !tag_wr_owed &&
                          !(tag_wr_maybe_owed && meta_is_tag_wr);

  // Only the meta answer has an error: the tag filter merges it into d_error.
  assign merged         = head.lookup && head_meta_err && !head_xbar_err;

  // Above each property: what it checks, in one sentence; then the testplan entry it implements
  // (the testpoint with its check letter or cover number) and the requirements it closes.

  /////////////////////////////////////////////
  // tf_forward: every access forwarded once //
  /////////////////////////////////////////////

  // A request presented and not yet forwarded is on the host port in the same cycle, unchanged.
  // REQ_TF_01b, 16a; tf_forward A1
  assert_TfReq_ForwardedUnchanged : assert property (core_ev.req_vld && !pres.xbar_sent &&
    !pres_cap_store |-> xbar_ev.req_vld && is_same_a(xbar_h2d_i, core_h2d_i));

  // Every host request is a presented request not yet forwarded: none invented, none sent twice.
  // REQ_TF_01a, 01c; tf_forward A2
  assert_TfReq_NoExtraXbarReq : assert property (xbar_ev.req_vld |->
    core_ev.req_vld && !pres.xbar_sent);

  // The answer's fields equal those of the host port's answer.
  // REQ_TF_07; tf_forward A3
  assert_TfReq_RspHasXbarFields : assert property (core_ev.rsp_vld && trk_head &&
    !head_cap_store |->
    trk_xbar_answered && is_same_rsp_payload(core_d2h_i, trk_xbar_answer) &&
    (merged || (core_d2h_i.d_user.rsp_intg == trk_xbar_answer.d_user.rsp_intg)));

  // Once every part of an answer has arrived, the answer is presented in that cycle.
  // REQ_TF_16b; tf_forward A4
  assert_TfReq_RspOnLastPart : assert property (head_vld && !head_cap_store && head_parts |->
    core_ev.rsp_vld);

  // An answer is presented only once its last part has arrived, never before.
  // REQ_TF_16b; tf_forward A4
  assert_TfReq_RspNotEarly : assert property (core_ev.rsp_vld && head_vld &&
    !head_cap_store |->
    head_parts);

  // A request is accepted only once its host request was taken, in that cycle or before.
  // REQ_TF_01a; tf_forward A5
  assert_TfReq_AcceptedAfterXbar : assert property (core_ev.req_fire |->
    xbar_ev.req_fire || pres.xbar_sent);

  // An unhinted Get to the main SRAM is accepted.
  // tf_forward C1
  cover_TfReq_GetToSram : cover property (core_ev.req_fire && is_get(core_h2d_i) &&
    !core_tag_i && is_main_sram(core_h2d_i.a_address));

  // A plain store to the NVM, PutFullData with tag 0, is accepted.
  // tf_forward C2
  cover_TfReq_PutToNvmTag0 : cover property (core_ev.req_fire &&
    (core_h2d_i.a_opcode == PutFullData) && !core_tag_i && is_nvm(core_h2d_i.a_address));

  // A one-byte PutPartialData to the main SRAM is accepted.
  // tf_forward C3
  cover_TfReq_ByteToSram : cover property (core_ev.req_fire &&
    (core_h2d_i.a_opcode == PutPartialData) && (core_h2d_i.a_size == 2'd0) &&
    is_main_sram(core_h2d_i.a_address));

  // A Get to a peripheral, outside both tagged regions, is accepted.
  // tf_forward C4
  cover_TfReq_GetToPeriph : cover property (core_ev.req_fire && is_get(core_h2d_i) &&
    !is_tagged(core_h2d_i.a_address));

  // W1 of a capability load is accepted while W0 is still unanswered.
  // tf_forward C5
  cover_TfReq_W1WhileW0Open : cover property (core_ev.req_fire &&
    (pres.kind == KindLoadW1) && head_vld && (head.kind == KindLoadW0) && (pres_idx != '0));

  // The host port stalls with a_ready 0 while the meta port takes the lookup.
  // tf_forward C6
  cover_TfReq_XbarStalls : cover property (core_ev.req_vld && pres.lookup &&
    m_ev[0].req_fire && !xbar_ev.req_fire && !pres.xbar_sent);

  // The meta port stalls while the host port takes the request.
  // tf_forward C7
  cover_TfReq_MetaStalls : cover property (core_ev.req_vld && pres.lookup &&
    xbar_ev.req_fire && !m_ev[0].req_fire && !pres.meta_sent);

  // Answer order: a part arrives in the cycle it is first offered. A meta answer taken
  // earlier arrived earlier; so did a host answer taken earlier, or one offered and not
  // taken in the cycle before (the host must hold it).

  // An answer's meta part arrives before its host part.
  // tf_forward C8
  cover_TfReq_MetaRspFirst : cover property (core_ev.rsp_vld && head_vld &&
    head.lookup && head.meta_answered && !head.xbar_answered &&
    !$past(xbar_ev.rsp_vld && !xbar_ev.rsp_fire));

  // An answer's host part arrives before its meta part.
  // tf_forward C9
  cover_TfReq_XbarRspFirst : cover property (core_ev.rsp_vld && head_vld &&
    head.lookup && !head.meta_answered &&
    (head.xbar_answered || $past(xbar_ev.rsp_vld && !xbar_ev.rsp_fire)));

  // An answer's host and meta parts arrive in the same cycle.
  // tf_forward C10
  cover_TfReq_RspPartsTogether : cover property (core_ev.rsp_vld && head_vld &&
    head.lookup && !head.meta_answered && !head.xbar_answered &&
    !$past(xbar_ev.rsp_vld && !xbar_ev.rsp_fire));

  // The host port's answer to a request carries d_error.
  // tf_forward C11
  cover_TfReq_XbarRspErr : cover property (core_ev.rsp_vld && head_vld &&
    !head_cap_store && head_xbar_err);

  // Requests are accepted in two consecutive cycles.
  // tf_forward C12
  cover_TfReq_BackToBack : cover property (core_ev.req_fire ##1 core_ev.req_fire);

  // A second request is presented in the cycle the first is answered.
  // tf_forward C13
  cover_TfReq_PresentedOnRsp : cover property (core_ev.req_vld && pop &&
    (pres_idx != '0));

  ////////////////////////////////////////
  // tf_lookup: when a tag is looked up //
  ////////////////////////////////////////

  // A request with Lookup(r) has its meta request in the same cycle.
  // REQ_TF_02, 03; tf_lookup A1
  assert_TfLookup_MetaReqSameCycle : assert property (core_ev.req_vld && pres.lookup &&
    !pres.meta_sent && !tag_wr_owed && !tag_wr_maybe_owed |-> m_ev[0].req_vld);

  // Every meta request belongs to a presented request with Lookup(r), at most one per request.
  // REQ_TF_04; tf_lookup A2
  assert_TfLookup_NoUnneededLookup : assert property (m_is_lookup |->
    core_ev.req_vld && pres.lookup && !pres.meta_sent);

  // Every lookup presented on the meta port carries a valid command integrity: nothing else
  // checks it (the TL-UL ABVIP leaves every integrity field free).
  // REQ_TF_17; tf_lookup lookup carries valid integrity
  assert_TfLookup_ReqIntgValid : assert property (m_ev[0].req_vld |->
    m_h2d_i[0].a_user.cmd_intg == get_cmd_intg(m_h2d_i[0]));

  // Cases C1-C13: one input varied from C1.
  function automatic logic is_req(tl_a_op_e op, addr_t a, logic tag);
    return core_ev.req_fire && (core_h2d_i.a_opcode == op) && (core_h2d_i.a_address == a) &&
           (core_tag_i == tag);
  endfunction

  // In CHERIoT mode, a hinted Get of W0 at 0x1000_1238 is accepted.
  // tf_lookup C1
  cover_TfLookup_HintedW0Get : cover property (ena && is_req(Get, 32'h1000_1238, 1'b1));

  // In CHERIoT mode, a hinted Get of W1 at 0x1000_123C is accepted.
  // tf_lookup C2
  cover_TfLookup_HintedW1Get : cover property (ena && is_req(Get, 32'h1000_123C, 1'b1));

  // In CHERIoT mode, an unhinted Get at 0x1000_1238 is accepted.
  // tf_lookup C3
  cover_TfLookup_UnhintedGet : cover property (ena && is_req(Get, 32'h1000_1238, 1'b0));

  // In CHERIoT mode, a word store (sw) at 0x1000_1238 with tag 0 is accepted.
  // tf_lookup C4
  cover_TfLookup_StoreWord : cover property (ena && is_req(PutFullData, 32'h1000_1238, 1'b0));

  // In CHERIoT mode, a byte store (sb) at 0x1000_1239 with tag 0 is accepted.
  // tf_lookup C5
  cover_TfLookup_StoreByte : cover property (ena &&
    is_req(PutPartialData, 32'h1000_1239, 1'b0));

  // In CHERIoT mode, a capability store (csc) at 0x1000_1238 with tag 1 is accepted.
  // tf_lookup C6
  cover_TfLookup_CapStore : cover property (ena && is_req(PutFullData, 32'h1000_1238, 1'b1));

  // In CHERIoT mode, a hinted Get at 0x3000_0400, in the NVM, is accepted.
  // tf_lookup C7
  cover_TfLookup_NvmCapLoad : cover property (ena && is_req(Get, 32'h3000_0400, 1'b1));

  // In CHERIoT mode, an NVM capability store at 0x3000_0400 with tag 1 is accepted.
  // tf_lookup C8
  cover_TfLookup_NvmCapStore : cover property (ena && is_req(PutFullData, 32'h3000_0400, 1'b1));

  // In CHERIoT mode, an NVM word store at 0x3000_0400 with tag 0 is accepted.
  // tf_lookup C9
  cover_TfLookup_NvmStoreWord : cover property (ena && is_req(PutFullData, 32'h3000_0400, 1'b0));

  // In CHERIoT mode, a hinted Get of the peripheral at 0x4000_0000 is accepted.
  // tf_lookup C10
  cover_TfLookup_PeriphGet : cover property (ena && is_req(Get, 32'h4000_0000, 1'b1));

  // In CHERIoT mode, a tag-0 store to the bitmap window at 0x1100_0100 is accepted.
  // tf_lookup C11
  cover_TfLookup_BitmapStore : cover property (ena && is_req(PutFullData, 32'h1100_0100, 1'b0));

  // With cheriot_ena_i at MuBi4False, a hinted Get at 0x1000_1238 is accepted.
  // tf_lookup C12
  cover_TfLookup_ModeFalse : cover property ((cheriot_ena_i == prim_mubi_pkg::MuBi4False) &&
    is_req(Get, 32'h1000_1238, 1'b1));

  // With cheriot_ena_i at the invalid value 4'h0, a hinted Get at 0x1000_1238 is accepted.
  // tf_lookup C13
  cover_TfLookup_ModeInvalid : cover property ((cheriot_ena_i == prim_mubi_pkg::mubi4_t'(4'h0)) &&
    is_req(Get, 32'h1000_1238, 1'b1));

  // Truth table C14-C33: access row r (hinted W0 Get, hinted W1 Get, plain Get, write tag 0,
  // write tag 1) by region column c (CHERIoT main SRAM, CHERIoT NVM, CHERIoT other, ePMP);
  // cover C(14 + 4r + c).
  function automatic logic is_row(int unsigned r);
    logic wr;
    wr = is_wr(core_h2d_i);
    return (r == 0) ? (is_get(core_h2d_i) &&  core_tag_i &&  is_w0(core_h2d_i)) :
           (r == 1) ? (is_get(core_h2d_i) &&  core_tag_i && !is_w0(core_h2d_i)) :
           (r == 2) ? (is_get(core_h2d_i) && !core_tag_i)                       :
           (r == 3) ? (wr && !core_tag_i)                                        :
                      (wr &&  core_tag_i);
  endfunction
  function automatic logic is_col(int unsigned c);
    addr_t a;
    a = core_h2d_i.a_address;
    return (c == 0) ? (ena && is_main_sram(a)) :
           (c == 1) ? (ena && is_nvm(a))       :
           (c == 2) ? (ena && !is_tagged(a))   :
                      !ena;
  endfunction
  for (genvar r = 0; r < 5; r++) begin : gen_tt_row
    for (genvar c = 0; c < 4; c++) begin : gen_tt_col

      // An access of each truth table row is accepted in each region and mode column.
      // tf_lookup C14-C33
      cover_TfLookup_TruthTableCell : cover property (core_ev.req_fire && is_row(r) && is_col(c));
    end
  end

  // Edge cases C34-C43: first and last capability of each region, one beyond, the seam.
  localparam addr_t EdgeAddr [10] = '{32'h0FFF_FFF8, 32'h1000_0000, 32'h1002_FFF8, 32'h1003_0000,
                                      32'h2FFF_FFF8, 32'h3000_0000, 32'h301F_FFF8, 32'h3020_0000,
                                      32'h1001_FFF8, 32'h1002_0000};
  for (genvar k = 0; k < 10; k++) begin : gen_edge_addr

    // A read or write at each region edge, one capability beyond it, or the seam is accepted.
    // tf_lookup C34-C43
    cover_TfLookup_RegionEdgeAddr : cover property (ena && core_ev.req_fire &&
      (core_h2d_i.a_address == EdgeAddr[k]) && (is_wr(core_h2d_i) || is_get(core_h2d_i)));
  end

  // Edge cases C44-C59: every cheriot_ena_i value v, cover C(44 + v).
  for (genvar v = 0; v < 16; v++) begin : gen_edge_ena

    // A request to a tagged region is accepted with each of the 16 cheriot_ena_i values.
    // tf_lookup C44-C59
    cover_TfLookup_EveryModeValue : cover property ((cheriot_ena_i == prim_mubi_pkg::mubi4_t'(v)) &&
      core_ev.req_fire && is_tagged(core_h2d_i.a_address));
  end

  ///////////////////////////////////////////////////////
  // tf_meta_request: which word, which bit, which tag //
  ///////////////////////////////////////////////////////

  // Every lookup's meta request carries the tag word and tag bit of the request's address.
  // REQ_TF_05a, 05b; tf_meta_request A1
  assert_TfMetaReq_TagWordAndBit : assert property (m_is_lookup |->
    (m_h2d_i[0].a_address == tag_word(core_h2d_i.a_address)) &&
    (m_bit_sel_i[0] == tag_bit(core_h2d_i.a_address)));

  // A write's meta request carries the write's tag as the tag to write.
  // REQ_TF_06; tf_meta_request A2
  assert_TfMetaReq_WrCarriesTag : assert property (m_is_lookup && is_wr(core_h2d_i) |->
    m_tag_i[0] == core_tag_i);

  // A read's meta request is a Get; a write's is not, so the RMW filter writes its tag.
  // REQ_TF_06; tf_meta_request A3
  assert_TfMetaReq_GetOnlyForRead : assert property (m_is_lookup |->
    (m_h2d_i[0].a_opcode == Get) == is_get(core_h2d_i));

  function automatic logic is_meta(addr_t a, addr_t w, bit_sel_t b);
    return m_ev[0].req_fire && !tag_wr_owed && (core_h2d_i.a_address == a) &&
           (m_h2d_i[0].a_address == w) && (m_bit_sel_i[0] == b);
  endfunction

  // A request at 0x1000_1238, W0, makes a meta request for word 0x1100_8C48, bit 7.
  // tf_meta_request C1
  cover_TfMetaReq_W0Bit7 : cover property (is_meta(32'h1000_1238, 32'h1100_8C48, 5'd7));

  // A request at 0x1000_123C, W1, makes a meta request for word 0x1100_8C48, bit 7.
  // tf_meta_request C2
  cover_TfMetaReq_W1Bit7 : cover property (is_meta(32'h1000_123C, 32'h1100_8C48, 5'd7));

  // A byte store inside the capability at 0x1000_1238 uses word 0x1100_8C48, bit 7.
  // tf_meta_request C3
  cover_TfMetaReq_ByteInCap : cover property (m_ev[0].req_fire && !tag_wr_owed &&
    (core_h2d_i.a_opcode == PutPartialData) && (core_h2d_i.a_address > 32'h1000_1238) &&
    (core_h2d_i.a_address <= 32'h1000_123F) && (m_h2d_i[0].a_address == 32'h1100_8C48) &&
    (m_bit_sel_i[0] == 5'd7));

  // A request at the next capability, 0x1000_1240, makes a meta request for 0x1100_8C48, bit 8.
  // tf_meta_request C4
  cover_TfMetaReq_NextCapBit8 : cover property (is_meta(32'h1000_1240, 32'h1100_8C48, 5'd8));

  // A request at the first main SRAM capability, 0x1000_0000, uses word 0x1100_8C00, bit 0.
  // tf_meta_request C5
  cover_TfMetaReq_FirstSramCap : cover property (is_meta(32'h1000_0000, 32'h1100_8C00, 5'd0));

  // A request at 0x1001_FFF8, just below the seam, uses word 0x1100_93FC, bit 31.
  // tf_meta_request C6
  cover_TfMetaReq_SeamBit31 : cover property (is_meta(32'h1001_FFF8, 32'h1100_93FC, 5'd31));

  // A request at 0x1002_0000, just above the seam, uses word 0x1100_9400, bit 0.
  // tf_meta_request C6
  cover_TfMetaReq_SeamBit0 : cover property (is_meta(32'h1002_0000, 32'h1100_9400, 5'd0));

  // A request at the last main SRAM capability, 0x1002_FFF8, uses word 0x1100_97FC, bit 31.
  // tf_meta_request C7
  cover_TfMetaReq_LastSramCap : cover property (is_meta(32'h1002_FFF8, 32'h1100_97FC, 5'd31));

  // A request at the first NVM capability, 0x3000_0000, uses word 0x1100_0C00, bit 0.
  // tf_meta_request C8
  cover_TfMetaReq_FirstNvmCap : cover property (is_meta(32'h3000_0000, 32'h1100_0C00, 5'd0));

  // A request at 0x3000_0400 in the NVM uses word 0x1100_0C10, bit 0.
  // tf_meta_request C8
  cover_TfMetaReq_NvmExampleCap : cover property (is_meta(32'h3000_0400, 32'h1100_0C10, 5'd0));

  // A request at the last NVM capability, 0x301F_FFF8, uses word 0x1100_8BFC, bit 31.
  // tf_meta_request C8
  cover_TfMetaReq_LastNvmCap : cover property (is_meta(32'h301F_FFF8, 32'h1100_8BFC, 5'd31));

  // A plain store (sw, sh or sb) makes a meta request with tag 0 to write.
  // tf_meta_request C9
  cover_TfMetaReq_PlainStoreTag0 : cover property (m_ev[0].req_fire && !tag_wr_owed &&
    is_wr(core_h2d_i) && !core_tag_i && !m_tag_i[0]);

  // A capability store of a tagged capability makes a meta request with tag 1 to write.
  // tf_meta_request C10
  cover_TfMetaReq_CapStoreTag1 : cover property (m_ev[0].req_fire && !tag_wr_owed &&
    (core_h2d_i.a_opcode == PutFullData) && core_tag_i && m_tag_i[0]);

  // A full-word store to the main SRAM makes a meta request with tag 0 to write.
  // tf_meta_request C11
  cover_TfMetaReq_CapStoreTag0 : cover property (m_ev[0].req_fire && !tag_wr_owed &&
    (core_h2d_i.a_opcode == PutFullData) && is_main_sram(core_h2d_i.a_address) && !m_tag_i[0]);

  //////////////////////////////////////////////////////
  // tf_sticky_tag: the tag returned with each answer //
  //////////////////////////////////////////////////////

  // The tag of every checked answer equals the value the sticky-tag rule gives.
  // REQ_TF_08, 09, 11a, 11c; tf_sticky_tag A1
  assert_TfStickyTag_RspTagFollowsRule : assert property (core_ev.rsp_vld && head_vld &&
    !head_cap_store &&
    head_tag_chk |-> core_tag_rsp_i == head_tag);

  logic ans_w0;
  logic ans_w1;
  assign ans_w0 = core_ev.rsp_fire && head_vld && (head.kind == KindLoadW0);
  assign ans_w1 = core_ev.rsp_fire && head_vld && (head.kind == KindLoadW1);

  // A plain (unhinted) read of the upper word answered right after a capability load's W1 with
  // tag 1 returns 0: the capture was cleared (REQ_TF_10).
  // tf_sticky_tag upper word after load
  // The cycle after is counted in a flop: Verilator cannot lint ## in a cover with a negation.
  logic w1_tag1_q;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) w1_tag1_q <= 1'b0;
    else         w1_tag1_q <= ans_w1 && core_tag_rsp_i;
  end
  cover_TfStickyTag_UpperWordAfterLoad : cover property (w1_tag1_q && core_ev.rsp_fire &&
    head_vld && (head.kind != KindLoadW0) && (head.kind != KindLoadW1) && head.w1 &&
    !core_tag_rsp_i);

  // A capability load from the main SRAM returns tag 1 on W0 and then on W1.
  // tf_sticky_tag C1
  cover_TfStickyTag_SramCapTag1 : cover property ((ans_w0 && core_tag_rsp_i &&
    is_main_sram(head.addr)) ##[1:$] (ans_w1 && core_tag_rsp_i));

  // A capability load from the main SRAM returns tag 0 on W0 and then on W1.
  // tf_sticky_tag C2
  cover_TfStickyTag_SramCapTag0 : cover property ((ans_w0 && (core_tag_rsp_i == 1'b0) &&
    is_main_sram(head.addr)) ##[1:$] (ans_w1 && (core_tag_rsp_i == 1'b0)));

  // A capability load from the NVM returns tag 1 on W0 and then on W1.
  // tf_sticky_tag C3
  cover_TfStickyTag_NvmCapTag1 : cover property ((ans_w0 && core_tag_rsp_i &&
    is_nvm(head.addr)) ##[1:$] (ans_w1 && core_tag_rsp_i));

  // A plain load of a word in a tagged region is answered.
  // tf_sticky_tag C4
  cover_TfStickyTag_LoadWord : cover property (core_ev.rsp_fire && head_vld &&
    (head.kind == KindRead) && is_tagged(head.addr));

  // A load of a tagged region is answered in ePMP mode.
  // tf_sticky_tag C5
  cover_TfStickyTag_LoadInEpmpMode : cover property (!ena && core_ev.rsp_fire && head_vld &&
    (head.kind == KindRead) && is_tagged(head.addr));

  // A load of a peripheral address is answered in CHERIoT mode.
  // tf_sticky_tag C6
  cover_TfStickyTag_PeriphLoad : cover property (ena && core_ev.rsp_fire && head_vld &&
    (head.kind == KindRead) && !is_tagged(head.addr));

  // A store's answer is taken.
  // tf_sticky_tag C7
  cover_TfStickyTag_StoreRsp : cover property (core_ev.rsp_fire && head_vld &&
    (head.kind == KindWrite));

  // W0 of a capability load is answered with d_error, then W1 is answered.
  // tf_sticky_tag C8
  cover_TfStickyTag_W0ErrThenW1 : cover property ((ans_w0 && core_d2h_i.d_error) ##[1:$] ans_w1);

  //////////////////////////////////////////////
  // tf_errors: errors and response integrity //
  //////////////////////////////////////////////

  logic ans_chk;
  logic exp_err;
  assign ans_chk = core_ev.rsp_vld && head_vld && !head_cap_store && head_parts;
  assign exp_err = head_xbar_err || (head.lookup && head_meta_err);

  // An answer whose host answer or joined meta answer has an error carries d_error.
  // REQ_TF_12a; tf_errors A1
  assert_TfErr_CauseGivesErr : assert property (ans_chk && exp_err |-> core_d2h_i.d_error);

  // An answer with d_error has a host answer or a joined meta answer with an error.
  // REQ_TF_12b; tf_errors A2
  assert_TfErr_NoErrWithoutCause : assert property (ans_chk && core_d2h_i.d_error |-> exp_err);

  // When only the meta answer has an error, the answer's response integrity matches the host's.
  // REQ_TF_13; tf_errors A3
  assert_TfErr_MergedErrKeepsIntg : assert property (core_ev.rsp_vld && trk_head &&
    !head_cap_store &&
    merged |-> is_rsp_intg_ok(core_d2h_i) == is_rsp_intg_ok(trk_xbar_answer));

  // C1-C7 for a read, C8-C14 for a write: the truth table rows (xbar error, lookup, meta
  // error), row 4 twice: xbar response integrity valid, then broken.
  for (genvar w = 0; w < 2; w++) begin : gen_err_kind
    logic taken;
    assign taken = core_ev.rsp_fire && head_vld && !head_cap_store &&
                   (is_wr_kind(head.kind) == (w == 1));

    // A read or a write is answered with no host error and no lookup.
    // tf_errors C1, C8
    cover_TfErr_TruthRow1 : cover property (taken && !head.lookup && !head_xbar_err);

    // A read or a write is answered with a host error and no lookup.
    // tf_errors C2, C9
    cover_TfErr_TruthRow2 : cover property (taken && !head.lookup &&  head_xbar_err);

    // A looked-up read or write is answered with no host error and no meta error.
    // tf_errors C3, C10
    cover_TfErr_TruthRow3 : cover property (taken &&  head.lookup && !head_xbar_err &&
      !head_meta_err);

    // Only the meta error sets d_error, and the host's response integrity is valid.
    // tf_errors C4, C11
    cover_TfErr_TruthRow4IntgOk : cover property (taken && merged && trk_head &&
      is_rsp_intg_ok(trk_xbar_answer));

    // Only the meta error sets d_error, and the host's response integrity is broken.
    // tf_errors C5, C12
    cover_TfErr_TruthRow4IntgBad : cover property (taken && merged && trk_head &&
      !is_rsp_intg_ok(trk_xbar_answer));

    // A looked-up read or write is answered with a host error and no meta error.
    // tf_errors C6, C13
    cover_TfErr_TruthRow5 : cover property (taken &&  head.lookup &&  head_xbar_err &&
      !head_meta_err);

    // A looked-up read or write is answered with both a host error and a meta error.
    // tf_errors C7, C14
    cover_TfErr_TruthRow6 : cover property (taken &&  head.lookup &&  head_xbar_err &&
       head_meta_err);
  end

  ///////////////////////////////////////
  // tf_flow: no stall, no lost answer //
  ///////////////////////////////////////

  // The meta port's d_ready is 1 in every cycle a meta answer is offered.
  // REQ_TF_14; tf_flow A1
  assert_TfFlow_MetaRspTaken : assert property (m_ev[0].rsp_vld |-> m_h2d_i[0].d_ready);

  // An answer is offered only while an accepted request waits for it, so none is answered twice.
  // REQ_TF_15b; tf_flow A2
  assert_TfFlow_NoExtraRsp : assert property (core_ev.rsp_vld |-> head_vld);

  // REQ_TF_15a, REQ_TF_15b, liveness (run B): every request presented is accepted, and the oldest
  // accepted request is answered, so every accepted request is (answers in order: contract C6).
`ifdef FPV_ON
`ifndef VERILATOR

  // Every presented request is accepted, at some point.
  // REQ_TF_15a; tf_flow A3
  assert_TfFlow_ReqEventuallyAccepted : assert property (core_ev.req_vld |->
    s_eventually core_ev.req_fire);

  // Every accepted request is answered, at some point.
  // REQ_TF_15b; tf_flow A4
  assert_TfFlow_ReqEventuallyAnswered : assert property (head_vld |-> s_eventually pop);
`endif
`endif

  // A second request is accepted while the first is still unanswered.
  // tf_flow C1
  cover_TfFlow_TwoOutstanding : cover property (core_ev.req_fire && head_vld &&
    (pres_idx != '0));

  // With no request presented, pres_idx is the number of stored entries: 2 is a full FIFO.
  logic head_waits;     // the head's xbar answer has not arrived
  logic engine_at_rmw;  // the engine's tag filter's request is at the RMW filter
  assign head_waits    = head_vld && !head_xbar_answered;
  assign engine_at_rmw = rmw_ev.req_vld && rmw_h2d_i.a_source[0];

  // A meta answer arrives while the FIFO is full, with two requests outstanding.
  // tf_flow C2
  cover_TfFlow_MetaFifoFull : cover property (m_ev[0].rsp_vld && head_vld &&
    (pres_idx == 2'd2) && !core_ev.req_vld);

  // A host answer is held for several cycles while meta answers arrive.
  // tf_flow C3
  cover_TfFlow_XbarRspHeld : cover property ((head_waits && m_ev[0].rsp_vld) ##1
    head_waits [*2]);

  // The engine waits at the RMW filter while a core meta answer waits for its host answer.
  // tf_flow C4
  cover_TfFlow_DeadlockPrecondition : cover property (head_waits && head.lookup &&
    head_meta_answered && engine_at_rmw);

  /////////////////////////////////////////////////
  // WTRC: wtrc_store, wtrc_compare, wtrc_faults //
  /////////////////////////////////////////////////

  logic head_vld_cap_store;
  logic head_w0;
  logic head_w1;
  logic head_faulty;
  logic ans;
  assign head_vld_cap_store = head_vld && (head.kind == KindCapStore);
  assign head_w0            = head_vld_cap_store && !head.w1;
  assign head_w1            = head_vld_cap_store && head.w1 && !head.out_of_seq;
  assign head_faulty        = head.fault || head_xbar_bad_intg;
  assign ans                = core_ev.rsp_vld;

  ///////////////////////////////////////////////////////////////////
  // wtrc_store: a capability store to the NVM reads, never writes //
  ///////////////////////////////////////////////////////////////////

  // A capability store word goes to cored_tl_h only as a full-word Get of the word it targets.
  // REQ_WTRC_01; wtrc_store A1
  assert_WtrcStore_SentAsFullGet : assert property (core_ev.req_vld && pres_cap_store &&
    !pres.xbar_sent |->
    xbar_ev.req_vld && (xbar_h2d_i.a_opcode == Get) && (xbar_h2d_i.a_size == 2'd2) &&
    (xbar_h2d_i.a_address == {core_h2d_i.a_address[top_pkg::TL_AW-1:2], 2'b00}));

  // The Get sent for a capability store word has a valid command integrity.
  // REQ_WTRC_02; wtrc_store A2
  assert_WtrcStore_GetCmdIntgValid : assert property (xbar_ev.req_vld && core_ev.req_vld &&
    pres_cap_store |-> is_cmd_intg_ok(xbar_h2d_i));

  // No meta request is presented for a capability store word, except W1's tag write.
  // REQ_WTRC_03; wtrc_store A3
  assert_WtrcStore_NoTagLookup : assert property (core_ev.req_vld && pres_cap_store |->
    !m_ev[0].req_vld || tag_wr_owed || (tag_wr_maybe_owed && meta_is_tag_wr));

  // Each capability store word is answered AccessAck, untagged, to its a_source, integrity valid.
  // REQ_WTRC_05; wtrc_store A4
  assert_WtrcStore_UntaggedAccessAck : assert property (ans && head_vld_cap_store |->
    (core_d2h_i.d_opcode == AccessAck) && !core_tag_rsp_i &&
    (core_d2h_i.d_source == head.src) && is_rsp_intg_ok(core_d2h_i));

  logic cap_store_taken;
  assign cap_store_taken = core_ev.req_fire && pres_cap_store;

  // In CHERIoT mode, a capability store's W0 to 0x3000_0400 is accepted.
  // wtrc_store C1
  cover_WtrcStore_NvmW0Taken : cover property (cap_store_taken && !pres.w1 &&
    (core_h2d_i.a_address == 32'h3000_0400));

  // In CHERIoT mode, a capability store's W1 to 0x3000_0404 is accepted.
  // wtrc_store C2
  cover_WtrcStore_NvmW1Taken : cover property (cap_store_taken &&  pres.w1 &&
    (core_h2d_i.a_address == 32'h3000_0404));

  // In CHERIoT mode, a plain word store to the NVM is accepted.
  // wtrc_store C3
  cover_WtrcStore_NvmStoreWord : cover property (core_ev.req_fire && ena &&
    (pres.kind == KindWrite) && is_nvm(core_h2d_i.a_address));

  // In CHERIoT mode, a store to the main SRAM is accepted with a tag lookup, as a csc is.
  // wtrc_store C4
  cover_WtrcStore_SramCapStore : cover property (core_ev.req_fire && ena &&
    (pres.kind == KindWrite) && is_main_sram(core_h2d_i.a_address) && pres.lookup);

  // In ePMP mode, a PutFullData to the NVM is accepted.
  // wtrc_store C5
  cover_WtrcStore_EpmpNvmStore : cover property (core_ev.req_fire && !ena &&
    (core_h2d_i.a_opcode == PutFullData) && is_nvm(core_h2d_i.a_address));

  // A capability store to the first NVM capability, 0x3000_0000, is accepted.
  // wtrc_store C6
  cover_WtrcStore_FirstNvmCap : cover property (cap_store_taken &&
    (core_h2d_i.a_address == 32'h3000_0000));

  // A capability store to the last NVM capability, 0x301F_FFF8, is accepted.
  // wtrc_store C7
  cover_WtrcStore_LastNvmCap : cover property (cap_store_taken &&
    (core_h2d_i.a_address == 32'h301F_FFF8));

  ////////////////////////////////////////////
  // wtrc_compare: which stores set the tag //
  ////////////////////////////////////////////

  // W0's answer carries d_error exactly when W0 does not match the NVM.
  // REQ_WTRC_04a, 04b; wtrc_compare A1
  assert_WtrcCompare_W0ErrOnMismatch : assert property (ans && head_w0 && !head_faulty &&
    head_xbar_answered |-> core_d2h_i.d_error == !head_match);

  // While a tag write is owed, the meta port carries only that tag write.
  // REQ_WTRC_06; wtrc_compare A2
  assert_WtrcCompare_OnlyOwedTagWr : assert property (m_ev[0].req_vld && tag_wr_owed |->
    meta_is_tag_wr);

  // W1 is answered only after the tag write's answer, with its d_error.
  // REQ_WTRC_06, 07; wtrc_compare A3
  assert_WtrcCompare_W1AfterTagWr : assert property (ans && head_w1 && head_tag_wr |->
    head_meta_answered && (core_d2h_i.d_error == head_meta_err));

  // When W0 or W1 did not match, W1's answer has d_error and no tag write is owed.
  // REQ_WTRC_08; wtrc_compare A4
  assert_WtrcCompare_W1ErrOnMismatch : assert property (ans && head_w1 && !head_faulty &&
    head_xbar_answered && !head_tag_wr && !head_tag_wr_maybe |-> core_d2h_i.d_error);

  // The WTRC's fault input rises only after one of its causes has occurred since reset.
  // REQ_WTRC_09, REQ_TAG_10, contract C8; wtrc_compare A5, contracts A8
  assert_WtrcCompare_NoAlertWithoutCause : assert property (wtrc_fault_i |-> cause_seen);

  // A capability store word is answered only once its NVM answer is in.
  // REQ_WTRC_04a, 04b, 08; wtrc_compare A6
  assert_WtrcCompare_RspAfterNvm : assert property (ans && head_vld_cap_store |->
    head_xbar_answered);

  logic w0_ans;
  logic w1_ans;
  assign w0_ans = core_ev.rsp_fire && head_w0 && !head_faulty;
  assign w1_ans = core_ev.rsp_fire && head_w1 && !head_faulty;

  // Both words match, and W1 is answered after an error-free tag write of tag 1.
  // wtrc_compare C1
  cover_WtrcCompare_BothMatchTagOk : cover property (w1_ans && head_tag_wr && !head_meta_err);

  // Both words match, and W1 is answered after a tag write that returns an error.
  // wtrc_compare C2
  cover_WtrcCompare_BothMatchTagErr : cover property (w1_ans && head_tag_wr &&  head_meta_err);

  // A W1 answered without a tag write had a mismatch in W0 or in itself; the model's Match of
  // each word tells which.

  // W0 matches the NVM and W1 does not.
  // wtrc_compare C3
  cover_WtrcCompare_W1Mismatch : cover property ((w0_ans && head_match) ##[1:$]
    (w1_ans && (head_match == 1'b0)));

  // W0 does not match the NVM and W1 does.
  // wtrc_compare C4
  cover_WtrcCompare_W0Mismatch : cover property ((w0_ans && (head_match == 1'b0)) ##[1:$]
    (w1_ans && head_match));

  // Neither W0 nor W1 matches the NVM.
  // wtrc_compare C5
  cover_WtrcCompare_BothMismatch : cover property ((w0_ans && (head_match == 1'b0)) ##[1:$]
    (w1_ans && (head_match == 1'b0)));

  // C6-C9 for W0, C10-C13 for W1: one cause of a mismatch at a time, seen when the word's NVM
  // answer arrives on cored_tl_h.
  for (genvar w = 0; w < 2; w++) begin : gen_cause
    logic nvm_ans;
    word_t diff;
    assign nvm_ans = xbar_answer_vld && (xbar_answer_ent.kind == KindCapStore) &&
                     !xbar_answer_ent.out_of_seq && !xbar_answer_ent.fault &&
                     (xbar_answer_ent.w1 == (w == 1));
    assign diff    = xbar_answer_ent.data ^ xbar_d2h_i.d_data;

    // The NVM read for W0 or W1 is answered with d_error.
    // wtrc_compare C6, C10
    cover_WtrcCompare_NvmReadErr : cover property (nvm_ans && xbar_d2h_i.d_error);

    // W0's or W1's data differ from the NVM's in bit 0 only.
    // wtrc_compare C7, C11
    cover_WtrcCompare_DataDiffBit0 : cover property (nvm_ans && !xbar_d2h_i.d_error &&
      (diff == 32'h0000_0001));

    // W0's or W1's data differ from the NVM's in bit 31 only.
    // wtrc_compare C8, C12
    cover_WtrcCompare_DataDiffBit31 : cover property (nvm_ans && !xbar_d2h_i.d_error &&
      (diff == 32'h8000_0000));

    // W0's or W1's data equal the NVM's, but the data integrity differs.
    // wtrc_compare C9, C13
    cover_WtrcCompare_IntgDiffOnly : cover property (nvm_ans && !xbar_d2h_i.d_error &&
      (diff == '0) &&
      (xbar_answer_ent.data_intg != xbar_d2h_i.d_user.data_intg));
  end

  // The tag write for the last NVM capability, 0x301F_FFF8, goes to word 0x1100_8BFC, bit 31.
  // wtrc_compare C14
  cover_WtrcCompare_LastNvmTagWr : cover property (m_ev[0].req_fire && tag_wr_owed &&
    (tag_wr_addr == 32'h1100_8BFC) && (m_bit_sel_i[0] == 5'd31));

  // A W0 presented in the cycle the previous capability's W1 is answered.
  // wtrc_compare C15
  cover_WtrcCompare_W0OnW1Rsp : cover property (core_ev.req_vld && pres_cap_store &&
    !pres.w1 && core_ev.rsp_fire && head_w1);

  ///////////////////////////////////////////////
  // wtrc_faults: what the core cannot produce //
  ///////////////////////////////////////////////

  // A faulty capability store word is answered with d_error.
  // REQ_WTRC_10; wtrc_faults A1
  assert_WtrcFaults_FaultyWordErr : assert property (ans && head_vld_cap_store && head_faulty &&
    head_xbar_answered |-> core_d2h_i.d_error);
`ifdef FPV_ON
`ifndef VERILATOR

  // A faulty capability store word raises the alert request, at some point.
  // REQ_WTRC_11; wtrc_faults A2
  assert_WtrcFaults_FaultyWordAlert : assert property (word_cause_now |-> s_eventually alert_req_i);
`endif
`endif

  // Each cover reaches one row of the case table (testplan, wtrc_faults), in that row's state.
  // The rows for a store or load out of the core's access order (cases C1-C9, check A3) are out
  // of scope: the core never issues them, so the environment cannot reach them.

  // W1 arrives after W0 with a bad data integrity.
  // wtrc_faults C10
  cover_WtrcFaults_BadDataIntg : cover property (word_cause_now && !pres.out_of_seq &&
    pres.w1 && (cap_state == CapW0) && !is_a_data_intg_ok(core_h2d_i));

  // W0 arrives with no capability store open and a bad command integrity.
  // wtrc_faults C11
  cover_WtrcFaults_BadCmdIntg : cover property (word_cause_now && !pres.out_of_seq &&
    !pres.w1 && (cap_state == CapIdle) && !is_cmd_intg_ok(core_h2d_i));

  // W0's NVM answer arrives with a bad response integrity.
  // wtrc_faults C12
  cover_WtrcFaults_BadNvmRspIntg : cover property (ans && head_vld_cap_store && !head.w1 &&
    head_xbar_bad_intg);

  // A W0 is accepted in sequence in the cycle the previous W1 is answered.
  // wtrc_faults C13
  cover_WtrcFaults_W0OnW1Rsp : cover property (core_ev.req_fire && pres_cap_store &&
    !pres.w1 && !pres.out_of_seq && core_ev.rsp_fire);

  ////////////////////////////////////////////////////
  // 2:1 arbiter: arb_forward, arb_return, arb_flow //
  ////////////////////////////////////////////////////

  // The arbiter output is Fwd(r, i) of input i's request r.
  function automatic logic is_fwd(logic i);
    return is_same_a_but_source(arb_h2d_i, m_h2d_i[i]) &&
           (arb_h2d_i.a_source == fwd_source(m_h2d_i[i].a_source, i)) &&
           (arb_tag_i == m_tag_i[i]) && (arb_bit_sel_i == m_bit_sel_i[i]);
  endfunction

  logic out_in;  // the input named by the output's a_source bit 0
  logic ans_in;  // the input named by the answer's d_source bit 0
  assign out_in = arb_h2d_i.a_source[0];
  assign ans_in = rmw_d2h_i.d_source[0];

  /////////////////////////////////////////////////////////////////
  // arb_forward: each request forwarded once, with its sideband //
  /////////////////////////////////////////////////////////////////

  // A1 and C8-C11 on each input i (a loop rather than a free index, so a simulation checks both).
  for (genvar i = 0; i < 2; i++) begin : gen_in_fwd

    // A request accepted on input i leaves the arbiter in the same cycle, as Fwd(r, i).
    // REQ_ARB_01, 03, 04; arb_forward A1
    assert_ArbReq_KeepsOwnSideband : assert property (m_ev[i].req_fire |->
      arb_ev.req_fire && is_fwd(1'(i)));

    // A request with source 0x00 is accepted on each input.
    // arb_forward C8
    cover_ArbReq_SourceZero : cover property (m_ev[i].req_fire &&
      (m_h2d_i[i].a_source == 8'h00));

    // The largest source each requester sends: 7 bits on input 1, 5 on input 0 (A9).
    if (i == 1) begin : gen_src_max

      // A request with source 0x7F is accepted on each input.
      // arb_forward C9
      cover_ArbReq_Source7F : cover property (m_ev[i].req_fire &&
        (m_h2d_i[i].a_source == 8'h7F));
    end else begin : gen_src_max

      // A request with source 0x1F is accepted on each input.
      // arb_forward C12
      cover_ArbReq_Source1F : cover property (m_ev[i].req_fire &&
        (m_h2d_i[i].a_source == 8'h1F));
    end

    // A request with bit select 0 is accepted on each input.
    // arb_forward C10
    cover_ArbReq_BitSel0 : cover property (m_ev[i].req_fire && (m_bit_sel_i[i] == 5'd0));

    // A request with bit select 31 is accepted on each input.
    // arb_forward C11
    cover_ArbReq_BitSel31 : cover property (m_ev[i].req_fire &&
      (m_bit_sel_i[i] == 5'd31));
  end

  // A request leaving the arbiter is Fwd(r, i) of the input it names, accepted in that cycle.
  // REQ_ARB_01, 02; arb_forward A2
  assert_ArbReq_FromNamedInput : assert property (arb_ev.req_vld |->
    m_ev[out_in].req_vld && is_fwd(out_in) && (arb_ev.req_fire == m_ev[out_in].req_fire));

  // A request from input 0 reaches the RMW filter exactly as it leaves the arbiter.
  // REQ_ARB_11; arb_forward A3
  assert_ArbReq_CoreReqUnchanged : assert property (arb_ev.req_vld && (out_in == 1'b0) |->
    rmw_h2d_i == arb_h2d_i);

  // Input 0's request is accepted with no request on input 1.
  // arb_forward C1
  cover_ArbReq_Input0Alone : cover property (m_ev[0].req_fire && !m_ev[1].req_vld);

  // Input 1's request is accepted with no request on input 0.
  // arb_forward C2
  cover_ArbReq_Input1Alone : cover property (m_ev[1].req_fire && !m_ev[0].req_vld);

  // Both inputs request at once, and input 0's request is accepted.
  // arb_forward C3
  cover_ArbReq_BothInput0Wins : cover property (m_ev[0].req_fire && m_ev[1].req_vld);

  // Both inputs request at once, and input 1's request is accepted.
  // arb_forward C4
  cover_ArbReq_BothInput1Wins : cover property (m_ev[1].req_fire && m_ev[0].req_vld);

  // Input 1 has requests accepted in two consecutive cycles.
  // arb_forward C6
  cover_ArbReq_Input1BackToBack : cover property (m_ev[1].req_fire ##1 m_ev[1].req_fire);

  // A write of tag 1 to bit 7 on input 0 and a read of bit 8 on input 1 come together.
  // arb_forward C7
  cover_ArbReq_WorkedExample : cover property (m_ev[0].req_vld && m_ev[1].req_vld &&
    (m_h2d_i[0].a_opcode != Get) && m_tag_i[0] && (m_bit_sel_i[0] == 5'd7) &&
    (m_h2d_i[1].a_opcode == Get) && (m_bit_sel_i[1] == 5'd8));

  /////////////////////////////////////////////////////
  // arb_return: each answer to the input that asked //
  /////////////////////////////////////////////////////

  // REQ_ARB_05: an answer at input i is the RMW filter's answer naming i.
  for (genvar i = 0; i < 2; i++) begin : gen_in_ret

    // An answer at input i is the RMW filter's answer of that cycle, with d_source & 1 == i.
    // REQ_ARB_05; arb_return A1
    assert_ArbRsp_ToItsInput : assert property (m_ev[i].rsp_vld |->
      rmw_ev.rsp_vld && (ans_in == 1'(i)));
  end

  // The answer at the input carries the RMW filter's d_source shifted right by one.
  // REQ_ARB_06; arb_return A2
  assert_ArbRsp_SourceShiftedBack : assert property (rmw_ev.rsp_vld |->
    m_d2h_i[ans_in].d_source == (rmw_d2h_i.d_source >> 1));

  // Every other D-channel field and the tag reach the input unchanged.
  // REQ_ARB_07; arb_return A3
  assert_ArbRsp_FieldsUnchanged : assert property (rmw_ev.rsp_vld |->
    is_same_d_but_source(m_d2h_i[ans_in], rmw_d2h_i) && (m_tag_rsp_i[ans_in] == rmw_tag_rsp_i));

  // The RMW filter's answer is taken in the cycle its input takes it, and only then: none lost.
  // REQ_ARB_05; arb_return A4
  assert_ArbRsp_TakenWithInput : assert property (rmw_ev.rsp_vld |->
    rmw_h2d_i.d_ready == m_h2d_i[ans_in].d_ready);

  // An answer to input 0 is taken.
  // arb_return C1
  cover_ArbRsp_ToInput0 : cover property (rmw_ev.rsp_fire && (ans_in == 1'b0));

  // An answer to input 1 is taken.
  // arb_return C2
  cover_ArbRsp_ToInput1 : cover property (rmw_ev.rsp_fire && (ans_in == 1'b1));

  // Answers to input 0 and then to input 1 are taken in consecutive cycles.
  // arb_return C3
  cover_ArbRsp_AlternateInputs : cover property ((rmw_ev.rsp_fire && (ans_in == 1'b0)) ##1
    (rmw_ev.rsp_fire && (ans_in == 1'b1)));

  // An answer with d_source 0x02 is taken: it goes to input 0 as 0x01.
  // arb_return C4
  cover_ArbRsp_Source02ToInput0 : cover property (rmw_ev.rsp_fire &&
    (rmw_d2h_i.d_source == 8'h02));

  // An answer with d_source 0x03 is taken: it goes to input 1 as 0x01.
  // arb_return C5
  cover_ArbRsp_Source03ToInput1 : cover property (rmw_ev.rsp_fire &&
    (rmw_d2h_i.d_source == 8'h03));

  /////////////////////////////////////////////
  // arb_flow: no added cycle, no starvation //
  /////////////////////////////////////////////

  for (genvar i = 0; i < 2; i++) begin : gen_in_flow

    // A request alone on one input reaches the RMW filter in the cycle it is presented.
    // REQ_ARB_09; arb_flow A1
    assert_ArbFlow_AloneSameCycle : assert property (m_ev[i].req_vld && !m_ev[1 - i].req_vld |->
      arb_ev.req_vld && is_fwd(1'(i)));

    // REQ_ARB_08, liveness: a request held on input i is eventually accepted, given the RMW
    // filter keeps accepting (contract C2, proven here).
`ifdef FPV_ON
`ifndef VERILATOR

    // A request held on either input is accepted, at some point.
    // REQ_ARB_08; arb_flow A3
    assert_ArbFlow_NoStarvation : assert property (m_ev[i].req_vld |->
      s_eventually m_ev[i].req_fire);
`endif
`endif
  end

  // The RMW filter's answer with d_source = s is presented at input s & 1 in the same cycle.
  // REQ_ARB_10; arb_flow A2
  assert_ArbFlow_RspAtOnce : assert property (rmw_ev.rsp_vld |-> m_ev[ans_in].rsp_vld);

  // Input 0 presents a request while input 1 presents none.
  // arb_flow C1
  cover_ArbFlow_Input0Alone : cover property (m_ev[0].req_vld && !m_ev[1].req_vld);

  // Input 1 presents a request while input 0 presents none.
  // arb_flow C2
  cover_ArbFlow_Input1Alone : cover property (m_ev[1].req_vld && !m_ev[0].req_vld);

  // C3: input 1 presents in every cycle while input 0 waits, here for three cycles; then input 0
  // is taken.
  logic in0_waits_on_in1;
  assign in0_waits_on_in1 = m_ev[0].req_vld && !m_ev[0].req_fire && m_ev[1].req_vld;

  // Input 0 waits three cycles while input 1 presents, then input 0 is accepted.
  // arb_flow C3
  cover_ArbFlow_StarvationCase : cover property (in0_waits_on_in1 [*3] ##1
    (m_ev[0].req_fire && m_ev[1].req_vld));

  ////////////////////////////////////////
  // RMW filter: rmw_read to rmw_errors //
  ////////////////////////////////////////

  logic dn_get;      // the downstream request presented now is a Get slot's
  logic dn_wb;       // ... the write-back's
  logic up_ans;      // an answer is presented upstream
  logic cur_wr_done; // the current write's Get answered: bit known
  logic wb_ans_now;  // the write-back's answer is presented downstream now
  assign dn_get      = tags_ev.req_vld && get_slot;
  assign dn_wb       = tags_ev.req_vld && wb_slot;
  assign up_ans      = rmw_ev.rsp_vld && ans_op_vld;
  assign cur_wr_done = cur.vld && cur.wr && ans_get_in;
  assign wb_ans_now  = tags_ev.rsp_vld && ans_op_vld && ans_op.wb_taken;

  //////////////////////////////////////
  // rmw_read: a read returns its bit //
  //////////////////////////////////////

  // A read's downstream request is a Get of its meta word, with its a_source.
  // REQ_RMW_01; rmw_read A1
  assert_RmwRead_GetOfMetaWord : assert property (dn_get && !get_op.wr |->
    (tags_h2d_i.a_opcode == Get) && (tags_h2d_i.a_address == get_op.addr) &&
    (tags_h2d_i.a_source == get_op.src));

  // A read's answer without d_error has the tag Bit(W, b), with W the word of its Get answer.
  // REQ_RMW_02; rmw_read A2
  assert_RmwRead_ReturnsTagBit : assert property (up_ans && !ans_op.wr |->
    ans_get_in && (ans_get_err || (rmw_tag_rsp_i == bit_of(ans_word, ans_op.bit_sel))));

  // A read presented as the previous read is answered, downstream ready, is accepted then.
  // REQ_RMW_11; rmw_read A3
  assert_RmwRead_BackToBackAccepted : assert property (rmw_ev.req_vld && is_get(rmw_h2d_i) &&
    cur.vld && !cur.wr && rmw_ev.rsp_fire && tags_d2h_i.a_ready |-> rmw_ev.req_fire);

  // Every Get the RMW filter sends downstream, for a read or for a write, carries a valid command
  // integrity: nothing else checks it.
  // REQ_RMW_18; rmw_read Get carries valid integrity
  assert_RmwRead_GetIntgValid : assert property (dn_get |->
    tags_h2d_i.a_user.cmd_intg == get_cmd_intg(tags_h2d_i));

  logic rd_ans;
  assign rd_ans = rmw_ev.rsp_fire && ans_op_vld && !ans_op.wr && !ans_get_err;

  // A read is answered from the meta word 0x0000_0000.
  // rmw_read C1
  cover_RmwRead_WordAllZeros : cover property (rd_ans && (ans_word == 32'h0000_0000));

  // A read is answered from the meta word 0xFFFF_FFFF.
  // rmw_read C2
  cover_RmwRead_WordAllOnes : cover property (rd_ans && (ans_word == 32'hFFFF_FFFF));

  // A read is answered from the meta word 0xAAAA_AAAA.
  // rmw_read C3
  cover_RmwRead_WordAAAA : cover property (rd_ans && (ans_word == 32'hAAAA_AAAA));

  // A read is answered from the meta word 0x5555_5555.
  // rmw_read C4
  cover_RmwRead_Word5555 : cover property (rd_ans && (ans_word == 32'h5555_5555));

  // A read is answered from a meta word with only the selected bit set.
  // rmw_read C5
  cover_RmwRead_WordOneBit : cover property (rd_ans &&
    (ans_word == upd('0, ans_op.bit_sel, 1'b1)));

  // A read with bit select 0 is answered.
  // rmw_read C6
  cover_RmwRead_BitSel0 : cover property (rd_ans && (ans_op.bit_sel == 5'd0));

  // A read with bit select 7 is answered.
  // rmw_read C7
  cover_RmwRead_BitSel7 : cover property (rd_ans && (ans_op.bit_sel == 5'd7));

  // A read with bit select 31 is answered.
  // rmw_read C8
  cover_RmwRead_BitSel31 : cover property (rd_ans && (ans_op.bit_sel == 5'd31));

  // A read is answered in the cycle the next read is accepted.
  // rmw_read C9
  cover_RmwRead_ReadsBackToBack : cover property (rd_ans && rmw_ev.req_fire && is_get(rmw_h2d_i));

  /////////////////////////////////////////////////
  // rmw_write_skip: an equal bit is not written //
  /////////////////////////////////////////////////

  // A write's first downstream request is a full-word Get of its meta word.
  // REQ_RMW_03; rmw_write_skip A1
  assert_RmwWrSkip_FullWordGetFirst : assert property (dn_get && get_op.wr |->
    (tags_h2d_i.a_opcode == Get) && (tags_h2d_i.a_address == get_op.addr) &&
    (tags_h2d_i.a_size == 2'd2) && (tags_h2d_i.a_mask == 4'hF));

  // Here and in the next check, a write whose Get answer is faulty is left free: the spec does
  // not say what the filter does with a corrupted read, and the integrity fault raises the alert.

  // No write-back is presented for a write whose Get answer has its bit equal to the tag.
  // REQ_RMW_04; rmw_write_skip A2
  assert_RmwWrSkip_NoWriteBack : assert property (tags_ev.req_vld && !ans_faulty |->
    !(cur_wr_done && !ans_get_err && ans_bit_eq));

  // A write whose Get answer has its bit equal to the tag is answered with AccessAck.
  // REQ_RMW_05; rmw_write_skip A3
  assert_RmwWrSkip_AnsweredAccessAck : assert property (up_ans && ans_op.wr && ans_get_in &&
    !ans_get_err && !ans_faulty && ans_bit_eq |-> rmw_d2h_i.d_opcode == AccessAck);

  // A write is answered only once its Get's answer has arrived.
  // REQ_RMW_03, 05; rmw_write_skip A4
  assert_RmwWrSkip_RspAfterGetRsp : assert property (up_ans && ans_op.wr |-> ans_get_in);

  logic wr_ans_eq;
  assign wr_ans_eq = rmw_ev.rsp_fire && ans_op_vld && ans_op.wr && ans_get_in &&
                     !ans_get_err && ans_bit_eq;

  // A write of tag 0 to a bit that is already 0 is answered.
  // rmw_write_skip C1
  cover_RmwWrSkip_BitAndTag0 : cover property (wr_ans_eq && !ans_op.tag);

  // A write of tag 1 to a bit that is already 1 is answered.
  // rmw_write_skip C2
  cover_RmwWrSkip_BitAndTag1 : cover property (wr_ans_eq &&  ans_op.tag);

  // A write from the core's tag filter (arbiter input 0) sends its Get.
  // REQ_RMW_03; rmw_write_skip C3
  cover_RmwWrSkip_CoreWrGet : cover property (dn_get && get_op.wr && !get_op.src[0]);

  // A write from the engine's tag filter (arbiter input 1) sends its Get.
  // REQ_RMW_03; rmw_write_skip C4
  cover_RmwWrSkip_EngineWrGet : cover property (dn_get && get_op.wr && get_op.src[0]);

  /////////////////////////////////////////////////////////
  // rmw_write_back: a changed bit is written back alone //
  /////////////////////////////////////////////////////////

  // In the write-back checks below, a write whose Get answer is faulty is left free for the same
  // reason; for the source check, on its write-back only.

  // The write-back of a write whose bit differs carries the word Upd(W, b, t).
  // REQ_RMW_06; rmw_write_back A1
  assert_RmwWrBack_CarriesUpdatedWord : assert property (dn_wb && !ans_faulty |->
    tags_h2d_i.a_data == wb_word);

  // The write-back is a full-word PutFullData to the same meta word, both integrities valid.
  // REQ_RMW_07; rmw_write_back A2
  assert_RmwWrBack_FullPutSameWord : assert property (dn_wb && !ans_faulty |->
    (tags_h2d_i.a_opcode == PutFullData) && (tags_h2d_i.a_address == cur.addr) &&
    (tags_h2d_i.a_size == 2'd2) && (tags_h2d_i.a_mask == 4'hF) &&
    is_cmd_intg_ok(tags_h2d_i) && is_a_data_intg_ok(tags_h2d_i));

  // A write with a write-back is answered with that write-back's answer, in the same cycle.
  // REQ_RMW_08; rmw_write_back A3
  assert_RmwWrBack_RspPassedUp : assert property (up_ans && ans_wb_need && !ans_faulty |->
    wb_ans_now && (rmw_d2h_i.d_opcode == ans_wb_op) && (rmw_d2h_i.d_error == ans_wb_err));

  // Every downstream request of a write carries the write's a_source.
  // REQ_RMW_09; rmw_write_back A4
  assert_RmwWrBack_KeepsWrSource : assert property ((dn_get && get_op.wr) ||
    (dn_wb && !ans_faulty) |-> tags_h2d_i.a_source == (dn_wb ? cur.src : get_op.src));

  logic wb_taken;
  assign wb_taken = tags_ev.req_fire && wb_slot;

  // A write-back clears bit 7 of the meta word 0x0000_0080.
  // rmw_write_back C1
  cover_RmwWrBack_ClearBit7 : cover property (wb_taken && (ans_word == 32'h0000_0080) &&
    (cur.bit_sel == 5'd7) && !cur.tag);

  // A write-back sets bit 8 of the meta word 0x0000_0080.
  // rmw_write_back C2
  cover_RmwWrBack_SetBit8 : cover property (wb_taken && (ans_word == 32'h0000_0080) &&
    (cur.bit_sel == 5'd8) && cur.tag);

  // A write-back clears bit 31 of the meta word 0xFFFF_FFFF.
  // rmw_write_back C3
  cover_RmwWrBack_ClearBit31 : cover property (wb_taken && (ans_word == 32'hFFFF_FFFF) &&
    (cur.bit_sel == 5'd31) && !cur.tag);

  // A write-back sets bit 0 of the meta word 0x0000_0000.
  // rmw_write_back C4
  cover_RmwWrBack_SetBit0 : cover property (wb_taken && (ans_word == 32'h0000_0000) &&
    (cur.bit_sel == 5'd0) && cur.tag);

  // A write-back sets bit 0 of the meta word 0xAAAA_AAAA.
  // rmw_write_back C5
  cover_RmwWrBack_SetBitInAAAA : cover property (wb_taken && (ans_word == 32'hAAAA_AAAA) &&
    (cur.bit_sel == 5'd0) && cur.tag);

  // A write-back writes tag 1 over a stored 0.
  // rmw_write_back C6
  cover_RmwWrBack_Tag1OverStored0 : cover property (wb_taken &&  cur.tag);

  // A write-back writes tag 0 over a stored 1.
  // rmw_write_back C7
  cover_RmwWrBack_Tag0OverStored1 : cover property (wb_taken && !cur.tag);

  ////////////////////////////////////////////
  // rmw_single_op: one operation at a time //
  ////////////////////////////////////////////

  // A request is accepted only when the filter is free, or as its one unanswered read is answered.
  // REQ_RMW_10; rmw_single_op A1
  assert_RmwSingleOp_OneAtATime : assert property (rmw_ev.req_fire |-> can_take);

  // Every downstream request is the Get of the current or presented request, or an owed write-back.
  // REQ_RMW_16; rmw_single_op A2
  assert_RmwSingleOp_NothingElseDownstream : assert property (tags_ev.req_vld |->
    get_slot || wb_slot || (cur.vld && cur.get_taken && ans_faulty));

  // A Get for a presented request is taken only in the cycle that request is accepted.
  // REQ_RMW_16; rmw_single_op A2
  assert_RmwSingleOp_GetWithAccept : assert property (tags_ev.req_fire && get_slot_new |->
    rmw_ev.req_fire);

  // An answer is presented upstream only while an operation is unanswered.
  // REQ_RMW_15; rmw_single_op A3
  assert_RmwSingleOp_OneRspPerOp : assert property (rmw_ev.rsp_vld |-> ans_op_vld);

  // REQ_RMW_15, liveness: an accepted operation is answered, given the meta SRAM answers
  // (contract C1).
  // Contract C2's second half (contracts A2).
`ifdef FPV_ON
`ifndef VERILATOR

  // Every accepted request is answered, at some point, given the meta SRAM answers.
  // REQ_RMW_15, contract C2; rmw_single_op A4, contracts A2
  assert_RmwSingleOp_EveryOpAnswered : assert property (cur.vld |->
    s_eventually rmw_ev.rsp_fire);
`endif
`endif

  logic up_wr_taken;
  logic up_rd_waits;
  logic up_core_taken;
  logic up_tbre_taken;
  assign up_wr_taken   = rmw_ev.req_fire && !is_get(rmw_h2d_i);
  assign up_rd_waits   = rmw_ev.req_vld && is_get(rmw_h2d_i) && cur.vld && cur.wr;
  assign up_core_taken = rmw_ev.req_fire && (rmw_h2d_i.a_source[0] == 1'b0);
  assign up_tbre_taken = rmw_ev.req_fire &&  rmw_h2d_i.a_source[0];

  // A write is accepted, and later a read waits to be accepted.
  // rmw_single_op C1
  cover_RmwSingleOp_WriteThenRead : cover property (up_wr_taken ##[1:$] up_rd_waits);

  // A read is accepted right behind a previous read.
  // rmw_single_op C2
  cover_RmwSingleOp_ReadsBackToBack : cover property (rmw_ev.req_fire && is_get(rmw_h2d_i) &&
    cur.vld && !cur.wr);

  // A write is accepted, and later another write.
  // rmw_single_op C3
  cover_RmwSingleOp_WriteThenWrite : cover property (up_wr_taken ##[1:$] up_wr_taken);

  // A request from the core's tag filter is accepted, and later one from the engine's.
  // rmw_single_op C4
  cover_RmwSingleOp_FiltersInterleaved : cover property (up_core_taken ##[1:$] up_tbre_taken);

  ///////////////////////////////
  // rmw_errors: device errors //
  ///////////////////////////////

  // No write-back is presented for a write whose Get answer has d_error.
  // REQ_RMW_13; rmw_errors A1
  assert_RmwErr_GetErrStopsWrite : assert property (tags_ev.req_vld |->
    !(cur_wr_done && ans_get_err));

  // An operation whose downstream answer has d_error is answered upstream with d_error.
  // REQ_RMW_14; rmw_errors A2
  assert_RmwErr_ErrPassedUp : assert property (up_ans && !ans_faulty &&
    ((ans_get_in && ans_get_err) || (ans_wb_in && ans_wb_err)) |-> rmw_d2h_i.d_error);

  // An answer upstream has d_error only when its Get's or its write-back's answer has d_error.
  // REQ_RMW_17; rmw_errors A3
  assert_RmwErr_NoErrWithoutCause : assert property (up_ans && !ans_faulty && rmw_d2h_i.d_error |->
    (ans_get_in && ans_get_err) || (ans_wb_in && ans_wb_err));

  logic err_ans;
  assign err_ans = rmw_ev.rsp_fire && ans_op_vld;

  // A read's Get answer has d_error, and the read is answered.
  // rmw_errors C1
  cover_RmwErr_ReadRspErr : cover property (err_ans && !ans_op.wr && ans_get_err);

  // A write's Get answer has d_error, with the bit equal to the tag.
  // rmw_errors C2
  cover_RmwErr_GetErrBitEqual : cover property (err_ans && ans_op.wr && ans_get_err &&
    ans_bit_eq);

  // A write's Get answer has d_error, with the bit different from the tag.
  // rmw_errors C3
  cover_RmwErr_GetErrBitDiffers : cover property (err_ans && ans_op.wr && ans_get_err &&
    !ans_bit_eq);

  // A write-back's answer has d_error.
  // rmw_errors C4
  cover_RmwErr_WriteBackErr : cover property (err_ans && ans_wb_in && ans_wb_err);

  //////////////////////////////////////////////
  // Alerts, contracts and environment covers //
  //////////////////////////////////////////////

  logic tag_err;
  logic tag_intg_bad;
  assign tag_err      = tags_ev.rsp_fire && tags_d2h_i.d_error;
  assign tag_intg_bad = tags_ev.rsp_fire &&
                        (!is_rsp_intg_ok(tags_d2h_i) || !is_d_data_intg_ok(tags_d2h_i));

  ///////////////////////////////////////////////////////
  // tag_alerts: the tag path's faults raise the alert //
  ///////////////////////////////////////////////////////

`ifdef FPV_ON
`ifndef VERILATOR

  // A meta SRAM answer taken with d_error raises the alert request, at some point.
  // REQ_TAG_07; tag_alerts A1
  assert_TagAlerts_DevErrRaisesAlert : assert property (tag_err |-> s_eventually alert_req_i);

  // A meta SRAM answer taken with a broken rsp_intg or data_intg raises the alert request too.
  // REQ_TAG_08; tag_alerts A2
  assert_TagAlerts_IntgErrRaisesAlert : assert property (tag_intg_bad |-> s_eventually alert_req_i);
`endif
`endif

  // The meta SRAM answers a read's Get with d_error.
  // tag_alerts C1
  cover_TagAlerts_ReadRspErr : cover property (tag_err && cur.vld && !cur.wr);

  // The meta SRAM answers a write's Get with d_error.
  // tag_alerts C2
  cover_TagAlerts_WrGetErr : cover property (tag_err && cur.vld && cur.wr &&
    !cur.get_in);

  // The meta SRAM answers a write-back with d_error.
  // tag_alerts C3
  cover_TagAlerts_WriteBackErr : cover property (tag_err && cur.vld && cur.wb_taken);

  // A meta SRAM answer is taken with a broken rsp_intg.
  // tag_alerts C4
  cover_TagAlerts_BadRspIntg : cover property (tags_ev.rsp_fire && !is_rsp_intg_ok(tags_d2h_i));

  // A meta SRAM answer is taken with a broken data_intg.
  // tag_alerts C5
  cover_TagAlerts_BadDataIntg : cover property (tags_ev.rsp_fire &&
    !is_d_data_intg_ok(tags_d2h_i));

  // A meta SRAM answer is taken with both rsp_intg and data_intg broken.
  // tag_alerts C6
  cover_TagAlerts_BothIntgBad : cover property (tags_ev.rsp_fire &&
    !is_rsp_intg_ok(tags_d2h_i) && !is_d_data_intg_ok(tags_d2h_i));

  // A write's Get is answered with a broken integrity and no d_error: a faulty Get answer.
  // tag_alerts C7
  cover_TagAlerts_WrGetIntgBad : cover property (tag_intg_bad && !tags_d2h_i.d_error &&
    cur.vld && cur.wr && !cur.get_in);

  ////////////////////////////////////
  // contracts: proven in checker 1 //
  ////////////////////////////////////

  // Each answer on cored_tl_d names the oldest unanswered core request.
  // contract C6; contracts A6
  assert_Contracts_CoreRspInOrder : assert property (core_ev.rsp_vld && head_vld |->
    core_d2h_i.d_source == head.src);

  // The core's tag filter holds its meta request, tag and bit select until they are taken.
  // contract C7; contracts A7
  assert_Contracts_CoreMetaReqHeld : assert property (m_ev[0].req_vld && !m_ev[0].req_fire |=>
    m_ev[0].req_vld && is_same_a(m_h2d_i[0], $past(m_h2d_i[0])) && $stable(m_tag_i[0]) &&
    $stable(m_bit_sel_i[0]));

  // C4, liveness run A (assumes C3b only): the RMW filter takes every answer offered downstream.
`ifdef FPV_ON
`ifndef VERILATOR

  // On the RMW filter's downstream port, every answer offered is taken, at some point.
  // contract C4; contracts A4
  assert_Contracts_TagsRspTaken : assert property (tags_ev.rsp_vld |->
    s_eventually tags_ev.rsp_fire);
`endif
`endif

  // C2, liveness run B (assumes C1, which checker 2 proves assuming C4): the RMW filter accepts
  // every request presented upstream; that it answers each is rmw_single_op A4.
`ifdef FPV_ON
`ifndef VERILATOR

  // On the RMW filter's upstream port, every request presented is accepted, at some point.
  // contract C2; contracts A2
  assert_Contracts_RmwReqAccepted : assert property (rmw_ev.req_vld |->
    s_eventually rmw_ev.req_fire);
`endif
`endif

  // The RMW filter's device fault input rises only after a device error since reset.
  // contract C8; contracts A8
  assert_Contracts_RmwDevFaultCaused : assert property (rmw_dev_fault_i |-> dev_err_seen);

  // The RMW filter's integrity fault input rises only after an integrity error since reset.
  // contract C8; contracts A8
  assert_Contracts_RmwIntgFaultCaused : assert property (rmw_intg_fault_i |-> intg_err_seen);

  // A request waits at the RMW filter's upstream port.
  // contracts C2
  cover_Contracts_RmwReqWaiting : cover property (rmw_ev.req_vld && !rmw_ev.req_fire);

  // An answer on the RMW filter's downstream port waits to be taken.
  // contracts C4
  cover_Contracts_TagsRspOffered : cover property (tags_ev.rsp_vld && !tags_h2d_i.d_ready);

  // A core answer is taken with two due; with no request presented, pres_idx counts them.
  // contracts C6
  cover_Contracts_CoreTwoOutstanding : cover property (core_ev.rsp_fire && !core_ev.req_vld &&
    (pres_idx == 2'd2));

  // The core's tag filter's meta request waits to be taken.
  // contracts C7
  cover_Contracts_CoreMetaReqWaiting : cover property (m_ev[0].req_vld && !m_ev[0].req_fire);

  // The RMW filter raises its device fault input.
  // contracts C8
  cover_Contracts_RmwDevFault : cover property (rmw_dev_fault_i);

  // The RMW filter raises its integrity fault input.
  // contracts C8
  cover_Contracts_RmwIntgFault : cover property (rmw_intg_fault_i);

  /////////////////////////////////////////////////////////////////////////////
  // rules: what the neighbours send (assumed in FPV, checked in simulation) //
  /////////////////////////////////////////////////////////////////////////////

  // A TL-UL ABVIP on each port the testbench plays, and the rules on top of them, each naming the
  // assumption (An) of the design architecture or the contract (Cn) it implements. In formal the
  // ABVIP plays that end (its rules assumed, the design's asserted) and ENV_RULE assumes. In
  // simulation the real neighbour drives the port, so the ABVIP asserts both ends and ENV_RULE
  // asserts. A MaxOutstanding below 2^SrcW limits what the port may do, so each one cites its
  // basis.
`ifdef FPV_ON
  localparam role_e HostRole   = PlayHost;
  localparam role_e DeviceRole = PlayDevice;
`else
  localparam role_e HostRole   = CheckBoth;
  localparam role_e DeviceRole = CheckBoth;
`endif

  logic [2:0] tags_num_out;

  /* verilator lint_off PINCONNECTEMPTY */
  // Arbiter input 1: the engine's tag filter. SrcW 7: the arbiter keeps 7 bits of a_source
  // ([TLUL] Source ID growth), so the engine's waiting requests differ in those bits (TL08).
  // HostReqHeld: the engine holds its meta request until accepted (contract C3a, its TileLink
  // half). DevSameCycleRsp 0: the 2:1 arbiter never answers in the cycle it accepts a request.
  tlul_abvip #(.Role(HostRole), .SrcW(7), .DevSameCycleRsp(1'b0),
               .HostReqHeld(1'b1)) u_abvip_m1 (
    .clk_i, .rst_ni, .h2d_i(m_h2d_i[1]), .d2h_i(m_d2h_i[1]),
    .a_fire_o(), .d_fire_o(), .num_outstanding_o(), .oldest_src_o());

  // RMW filter downstream: the tag access checker. MaxOutstanding 4 only sizes the list: the RMW
  // filter does one operation at a time (rmw_single_op). DevSameCycleRsp 0: the tag access checker
  // answers a cycle or more after it takes the request (contract C10), so the ABVIP assumes no
  // same-cycle answer and makes no same-cycle covers.
  // DevInOrderRsp, DevRspHeld: the tag access checker answers in request order and holds each
  // answer until taken (contract C10, with DevSameCycleRsp 0 its third part).
  tlul_abvip #(.Role(DeviceRole), .MaxOutstanding(4), .DevSameCycleRsp(1'b0),
               .DevInOrderRsp(1'b1), .DevRspHeld(1'b1), .HostReqHeld(1'b1)) u_abvip_tags (
    .clk_i, .rst_ni, .h2d_i(tags_h2d_i), .d2h_i(tags_d2h_i),
    .a_fire_o(), .d_fire_o(), .num_outstanding_o(tags_num_out), .oldest_src_o());
  /* verilator lint_on PINCONNECTEMPTY */

  // A core request's tag sideband stays unchanged until the request is accepted. The TileLink
  // fields are the ABVIP's HostReqHeld; the tag is not a TileLink field, so it is held here.
  // assumption A1: the spec gives no rule for it; raised with the designers
  `ENV_RULE(assume_Env_CoreTagHeld, core_h2d_i.a_valid && !core_a_fire_i |=>
    core_h2d_i.a_valid && $stable(core_tag_i))

  // xbar_main answers in a later cycle than the one it takes the request in.
  // assumption A14: true of top_earlgrey's xbar, not yet a spec rule; raised with the designers
  `ENV_RULE(assume_Env_XbarRspLater, xbar_d2h_i.d_valid |-> xbar_num_out_i != '0)

  // The engine's tag filter holds its tag and bit select until the request is taken. The
  // TileLink fields are the ABVIP's HostReqHeld; these two are sideband, so they are held here.
  // contract C3a, proven in checker 3
  `ENV_RULE(assume_Contracts_EngineMetaSideHeld, m_h2d_i[1].a_valid && !m_d2h_i[1].a_ready |=>
    m_h2d_i[1].a_valid && $stable(m_tag_i[1]) && $stable(m_bit_sel_i[1]))

  // The engine's tag filter addresses whole meta words.
  // contract C11, proven in checker 3
  `ENV_RULE(assume_Contracts_EngineWordAddr, m_h2d_i[1].a_valid |->
    m_h2d_i[1].a_address[1:0] == 2'b00)

  // The engine's tag filter leaves the top bit of a_source clear: the 2:1 arbiter writes the
  // input number there, and its own idInRange assertion requires it. TileLink itself allows any
  // source, so the ABVIP's SrcW 7 does not give this; it only makes waiting requests differ in
  // the low seven bits.
  // contract C22, proven in checker 3
  `ENV_RULE(assume_Contracts_EngineSourceLow, m_h2d_i[1].a_valid |->
    m_h2d_i[1].a_source[7] == 1'b0)

  // Copied only by the two tasks that need it: in task_TagPath_Main it would leave the checks on a
  // waiting engine answer vacuous.

  // The engine's tag filter takes every meta answer in the cycle it is offered.
  // contract C3b, proven in checker 3
  `ENV_RULE(assume_Contracts_EngineMetaRspTaken, m_d2h_i[1].d_valid |-> m_h2d_i[1].d_ready)

  // The tag access checker answers in a later cycle than it takes the request.
  // contract C10, proven in checker 2
  `ENV_RULE(assume_Contracts_TagsRspLater, tags_d2h_i.d_valid |-> tags_num_out != '0)

  // The core (A3-A6, A9).
  logic is_hinted;
  logic is_cap_store;
  assign is_hinted    = is_hint(core_h2d_i, core_tag_i);
  assign is_cap_store = is_nvm_cap_store(core_h2d_i, core_tag_i, ena);

  // Core requests accepted whose answers were not yet taken.
  logic [1:0] core_outstanding_q, core_outstanding_d;
  assign core_outstanding_d = core_outstanding_q + 2'(core_a_fire_i) - 2'(core_d_fire_i);

  // The core's a_source leaves its top three bits free for the arbiters.
  // assumption A9: raised with the designers
  `ENV_RULE(assume_Env_CoreSourceLow, core_h2d_i.a_valid |->
    core_h2d_i.a_source[top_pkg::TL_AIW-1 -: 3] == 3'b000)

  // A3: a capability load is a hinted full-word read of W0, then, as the next request, of W0 + 4.
  logic  ld_w1_due_q, ld_w1_due_d;
  addr_t ld_w0_addr_q, ld_w0_addr_d;
  logic  ld_w0_taken;
  assign ld_w0_taken  = core_a_fire_i && is_hinted && is_w0(core_h2d_i);
  assign ld_w1_due_d  = ld_w0_taken ? 1'b1        :
                        core_a_fire_i ? 1'b0        :
                                      ld_w1_due_q;
  assign ld_w0_addr_d = ld_w0_taken ? core_h2d_i.a_address : ld_w0_addr_q;

  // A4: a capability store to the NVM is W0 then W1, two full words; nothing else until W1 is
  // answered.
  typedef enum logic [1:0] {CapStoreIdle, CapStoreW0, CapStoreW1} cap_store_e;
  cap_store_e cap_store_q, cap_store_d;
  addr_t      cap_store_addr_q, cap_store_addr_d;
  logic       cap_store_w1_done;
  logic       cap_store_same_cap;
  assign cap_store_w1_done  = (cap_store_q == CapStoreW1) && core_d_fire_i &&
                              (core_outstanding_q == 2'd1);
  assign cap_store_same_cap = is_same_cap(core_h2d_i.a_address, cap_store_addr_q);
  always_comb begin
    cap_store_d      = cap_store_w1_done ? CapStoreIdle : cap_store_q;
    cap_store_addr_d = cap_store_addr_q;
    if (core_a_fire_i && is_cap_store && is_w0(core_h2d_i)) begin
      cap_store_d      = CapStoreW0;
      cap_store_addr_d = core_h2d_i.a_address;
    end else if (core_a_fire_i && is_cap_store) begin
      cap_store_d = CapStoreW1;
    end
  end

  // A hinted (capability) load reads a full word.
  // assumption A3
  `ENV_RULE(assume_Env_LoadFullWord, core_h2d_i.a_valid && is_hinted |->
    core_h2d_i.a_size == 2'd2)

  // After a capability load's W0, the next request is its W1.
  // assumption A3
  `ENV_RULE(assume_Env_LoadW1Next, ld_w1_due_q && core_h2d_i.a_valid |->
    is_hinted && (core_h2d_i.a_address == ld_w0_addr_q + 32'd4))

  // A hinted W1 comes only right after its W0.
  // assumption A3
  `ENV_RULE(assume_Env_LoadW1Only, core_h2d_i.a_valid && is_hinted &&
    !is_w0(core_h2d_i) |-> ld_w1_due_q)

  // A capability store to the NVM writes full words.
  // assumption A4
  `ENV_RULE(assume_Env_StoreFullWord, core_h2d_i.a_valid && is_cap_store |->
    is_full_put(core_h2d_i))

  // A capability store's W0 comes only when no store is open or the last ends.
  // assumption A4
  `ENV_RULE(assume_Env_StoreW0First, core_h2d_i.a_valid && is_cap_store &&
    is_w0(core_h2d_i) |-> (cap_store_q == CapStoreIdle) || cap_store_w1_done)

  // After a capability store's W0, the next request is W1 of the same capability.
  // assumption A4
  `ENV_RULE(assume_Env_StoreW1Next, (cap_store_q == CapStoreW0) && core_h2d_i.a_valid |->
    is_cap_store && !is_w0(core_h2d_i) && cap_store_same_cap)

  // A capability store's W1 comes only after its W0, for the same capability.
  // assumption A4
  `ENV_RULE(assume_Env_StoreW1Only, core_h2d_i.a_valid && is_cap_store &&
    !is_w0(core_h2d_i) |-> (cap_store_q == CapStoreW0) && cap_store_same_cap)

  // After a capability store's W1, nothing else comes until W1 is answered.
  // assumption A4
  `ENV_RULE(assume_Env_QuietUntilW1Rsp, (cap_store_q == CapStoreW1) && core_h2d_i.a_valid |->
    cap_store_w1_done)

  // A partial write carries tag 0.
  // assumption A5
  `ENV_RULE(assume_Env_PartialWrUntagged, core_h2d_i.a_valid &&
    (core_h2d_i.a_opcode == PutPartialData) |-> !core_tag_i)

  // The CHERIoT mode keeps its value from reset.
  // assumption A6
  `ENV_RULE(assume_Env_ModeStable, $stable(cheriot_ena_i))

  // Fairness, copied only by task_TagPath_EveryReqAnswered: A10 with P5 (the condition of
  // REQ_TF_15a/b and REQ_RMW_15; DV reading): the core takes its answers, xbar_main accepts and
  // answers. C1 (contract, checker 2, which assumes C4 from task_TagPath_TagsRspTaken): the tag
  // access checker accepts and answers. Formal only: a simulation ends, so an eventuality still
  // open at its end proves nothing.
`ifdef FPV_ON
`ifndef VERILATOR

  // The core takes every answer offered to it, at some point.
  // testplan proposal P5, for assumption A10
  assume_Env_CoreTakesRsp : assume property (core_d2h_i.d_valid |->
    s_eventually core_h2d_i.d_ready);

  // xbar_main accepts every request offered, at some point.
  // assumption A10
  assume_Env_XbarAcceptsReq : assume property (xbar_h2d_i.a_valid |->
    s_eventually xbar_d2h_i.a_ready);

  // xbar_main answers every request it took, at some point.
  // assumption A10
  assume_Env_XbarAnswersReq : assume property (xbar_num_out_i != '0 |->
    s_eventually xbar_d2h_i.d_valid);

  // The access checker accepts every request presented, at some point.
  // contract C1, proven in checker 2
  assume_Contracts_AccessReqAccepted : assume property (tags_h2d_i.a_valid |->
    s_eventually tags_d2h_i.a_ready);

  // The access checker answers every request it accepted, at some point.
  // contract C1, proven in checker 2
  assume_Contracts_AccessReqAnswered : assume property (tags_num_out != '0 |->
    s_eventually tags_d2h_i.d_valid);
`endif
`endif

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      core_outstanding_q <= '0;
      ld_w1_due_q        <= 1'b0;
      ld_w0_addr_q       <= '0;
      cap_store_q        <= CapStoreIdle;
      cap_store_addr_q   <= '0;
    end else begin
      core_outstanding_q <= core_outstanding_d;
      ld_w1_due_q        <= ld_w1_due_d;
      ld_w0_addr_q       <= ld_w0_addr_d;
      cap_store_q        <= cap_store_d;
      cap_store_addr_q   <= cap_store_addr_d;
    end
  end

  ///////////////////////////////////////////////////////////
  // environment: every assumption of checker 1 can be met //
  ///////////////////////////////////////////////////////////

  // Two core requests are outstanding on cored_tl_d at once.
  // environment C1, for assumption A2
  cover_Env_CoreTwoOutstanding : cover property (core_ev.req_fire && head_vld &&
    (pres_idx != '0));

  // A capability load's W1 is accepted right after its W0.
  // environment C2, for assumption A3
  cover_Env_LoadW1Next : cover property ((core_ev.req_fire &&
    (pres.kind == KindLoadW0)) ##1 (core_ev.req_fire && (pres.kind == KindLoadW1)));
  logic cap_store_w0_taken;
  logic cap_store_w1_taken;
  logic m1_waits;
  assign cap_store_w0_taken = core_ev.req_fire && (pres.kind == KindCapStore) && !pres.w1;
  assign cap_store_w1_taken = core_ev.req_fire && (pres.kind == KindCapStore) &&  pres.w1;
  assign m1_waits           = m_ev[1].req_vld && !m_ev[1].req_fire;

  // A capability store's W0 and then its W1 are accepted.
  // environment C3, for assumption A4
  cover_Env_StoreW0ThenW1 : cover property (cap_store_w0_taken ##[1:$] cap_store_w1_taken);

  // C4-C19: each cheriot_ena_i value v, cover C(4 + v).
  for (genvar v = 0; v < 16; v++) begin : gen_env_ena

    // A request is accepted with each of the 16 cheriot_ena_i values.
    // environment C4-C19, for assumption A6
    cover_Env_EveryModeValue : cover property ((cheriot_ena_i == prim_mubi_pkg::mubi4_t'(v)) &&
      core_ev.req_fire);
  end

  // Two host answers come in order on cored_tl_h.
  // environment C20, for assumption A7
  cover_Env_XbarRspInOrder : cover property (xbar_ev.rsp_fire ##[1:$] xbar_ev.rsp_fire);

  // A core request uses a_source 0x1F, its top free bit.
  // environment C22, for assumption A9
  cover_Env_SourceTopBit : cover property (core_ev.req_fire &&
    (core_h2d_i.a_source == 8'h1F) && core_tag_i && ena);

  // The engine's tag filter's meta request waits a cycle, then is taken.
  // environment C23
  cover_Env_EngineMetaReqHeld : cover property (m1_waits ##1 m_ev[1].req_fire);

  // The engine's tag filter takes a meta answer.
  // environment C23
  cover_Env_EngineMetaRspTaken : cover property (m_ev[1].rsp_fire);

  // An answer on the RMW filter's downstream port is taken.
  // environment C23
  cover_Env_TagsReqAnswered : cover property (tags_ev.rsp_fire);

  //////////////////////////////////////////////////
  // TL-UL rules on the links between real blocks //
  //////////////////////////////////////////////////

  // tlul_protocol A1 on the two links whose ends are both real: CheckBoth asserts every TL-UL rule
  // on both channels and assumes nothing, so it also runs in simulation. Arbiter input 0 uses
  // SrcW 7, as input 1 does: the arbiter keeps 7 bits of a_source ([TLUL] Source ID growth). The
  // RMW filter upstream keeps the defaults: behind the arbiter all 8 bits come back.
  /* verilator lint_off PINCONNECTEMPTY */
  // Both ends are the design, so these two are asserted, never assumed.
  tlul_abvip #(.Role(CheckBoth), .SrcW(7), .DevSameCycleRsp(1'b0),
               .HostReqHeld(1'b1)) u_abvip_m0 (
    .clk_i, .rst_ni, .h2d_i(m_h2d_i[0]), .d2h_i(m_d2h_i[0]),
    .a_fire_o(), .d_fire_o(), .num_outstanding_o(), .oldest_src_o());

  tlul_abvip #(.Role(CheckBoth), .DevSameCycleRsp(1'b0), .HostReqHeld(1'b1)) u_abvip_rmw (
    .clk_i, .rst_ni, .h2d_i(rmw_h2d_i), .d2h_i(rmw_d2h_i),
    .a_fire_o(), .d_fire_o(), .num_outstanding_o(), .oldest_src_o());
  /* verilator lint_on PINCONNECTEMPTY */

endmodule
