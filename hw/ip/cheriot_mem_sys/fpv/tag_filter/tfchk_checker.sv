// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// tfchk_checker: the tag filter's checks, tf_forward to tf_flow, against the tag filter model;
//   shared by checker 1 (the core's tag filter) and checker 3 (the engine's), each instance with
//   its tag filter's configuration (D40). No assumption. It passes the model's predictions on, for
//   its parent's own checks (checker 1's WTRC checks).
// Data path: the tag filter's three ports -> port events -> tfchk_model (with its tracker) -> the
//   properties, one banner section per testpoint.
// Figure: cheriot_mem_sys_fpv_tag_path_uarch.adoc, figures/src/tpchk_tf_model_omc.svg.
// Obligations: the testplan's tf_* checks; in checker 3, tbre_clear's tag filter checks hold (all
//   of them) and its write answered once.
// Spec: testplan tf_forward to tf_flow, tbre_clear; [ToO] Tag Filter, WTRC, Revocation Engine.
// Naming: ports named after the block at the other end: the requester (the core, or the engine's
//   socket), xbar_main, the arbiter (m_); <port>_ev a port's events.
module tfchk_checker
  import tlul_pkg::*;
  import tpchk_pkg::*;
#(
  parameter bit    NvmCapStores  = 1'b1,    // the filter has a WTRC: the core's
  parameter bit    TagOnlyWrites = 1'b0,    // writes reach only the meta port: the engine's
  parameter bit    CoverCases    = 1'b1,    // the testplan's tf_* cases: on the core's filter only
  parameter live_e RunLive       = LiveOff  // liveness run B: tf_flow's two liveness checks
) (
  input  logic                  clk_i,
  input  logic                  rst_ni,
  input  prim_mubi_pkg::mubi4_t cheriot_ena_i,
  // The request the tracker follows: free in FPV
  input  logic                  pick_i,
  // The requester's port, with its tag sideband
  input  tl_h2d_t               requester_h2d_i,
  input  logic                  requester_tag_i,
  input  tl_d2h_t               requester_d2h_i,
  input  logic                  requester_tag_rsp_i,
  // The host port, to xbar_main
  input  tl_h2d_t               xbar_h2d_i,
  input  tl_d2h_t               xbar_d2h_i,
  // The meta port, to an input of the 2:1 tag arbiter
  input  tl_h2d_t               m_h2d_i,
  input  logic                  m_tag_i,
  input  bit_sel_t              m_bit_sel_i,
  input  tl_d2h_t               m_d2h_i,
  input  logic                  m_tag_rsp_i,
  // The model's predictions (tfchk_model)
  output idx_t                  pres_idx_o,
  output ent_t                  pres_o,
  output logic                  head_vld_o,
  output ent_t                  head_o,
  output logic                  head_xbar_answered_o,
  output logic                  head_xbar_bad_intg_o,
  output logic                  head_match_o,
  output logic                  head_meta_answered_o,
  output logic                  head_meta_err_o,
  output logic                  head_tag_wr_o,
  output logic                  head_tag_wr_maybe_o,
  output capture_e              capture_o,
  output logic                  pop_o,
  output logic                  xbar_answer_vld_o,
  output ent_t                  xbar_answer_ent_o,
  output logic                  tag_wr_owed_o,
  output logic                  tag_wr_maybe_owed_o,
  output addr_t                 tag_wr_addr_o,
  output logic                  meta_is_tag_wr_o,
  output cap_e                  cap_state_o,
  output addr_t                 cap_addr_o,
  output logic                  word_cause_now_o,
  output logic                  out_of_seq_cause_now_o,
  output logic                  cause_seen_o
);

  default clocking @(posedge clk_i); endclocking
  /* verilator lint_off SYNCASYNCNET */
  default disable iff (!rst_ni);
  /* verilator lint_on SYNCASYNCNET */

  logic ena;
  assign ena = is_ena(cheriot_ena_i);

  logic pick;
  assign pick = pick_i;

  /////////////////
  // Port events //
  /////////////////

  // [TLUL] Signals: a beat passes in a cycle where valid and ready are both high.
  ev_t requester_ev, xbar_ev, m_ev;
  assign requester_ev = port_ev(requester_h2d_i, requester_d2h_i);
  assign xbar_ev      = port_ev(xbar_h2d_i, xbar_d2h_i);
  assign m_ev         = port_ev(m_h2d_i, m_d2h_i);

  ///////////
  // Model //
  ///////////

  logic    head_vld, head_xbar_answered, head_xbar_err, head_xbar_bad_intg, head_match;
  idx_t    pres_idx;
  logic    head_meta_answered, head_meta_err, head_tag_chk, head_tag;
  logic    head_tag_wr, head_tag_wr_maybe;
  logic    capture_tag, capture_wr, pop, xbar_answer_vld;
  logic    tag_wr_owed, tag_wr_maybe_owed, meta_is_tag_wr;
  logic    word_cause_now, out_of_seq_cause_now, cause_seen;
  ent_t    pres, head, xbar_answer_ent;
  capture_e capture;
  logic    trk_head, trk_xbar_answered;
  tl_d2h_t trk_xbar_answer;
  addr_t   tag_wr_addr, cap_addr;
  cap_e    cap_state;

  tfchk_model #(
    .NvmCapStores(NvmCapStores)
  ) u_tf_model (
    .clk_i,
    .rst_ni,
    .pick_i                 (pick),
    .requester_h2d_i,
    .requester_tag_i,
    .requester_d2h_i,
    .requester_ev_i         (requester_ev),
    .ena_i                  (ena),
    .xbar_d2h_i,
    .xbar_ev_i              (xbar_ev),
    .m_h2d_i,
    .m_tag_i,
    .m_bit_sel_i,
    .m_d2h_i,
    .m_tag_rsp_i,
    .m_ev_i                 (m_ev),
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
    .capture_o              (capture),
    .capture_tag_o          (capture_tag),
    .capture_wr_o           (capture_wr),
    .pop_o                  (pop),
    .xbar_answer_vld_o      (xbar_answer_vld),
    .xbar_answer_ent_o      (xbar_answer_ent),
    .tag_wr_owed_o          (tag_wr_owed),
    .tag_wr_maybe_owed_o    (tag_wr_maybe_owed),
    .tag_wr_addr_o          (tag_wr_addr),
    .meta_is_tag_wr_o       (meta_is_tag_wr),
    .cap_state_o            (cap_state),
    .cap_addr_o             (cap_addr),
    .word_cause_now_o       (word_cause_now),
    .out_of_seq_cause_now_o (out_of_seq_cause_now),
    .cause_seen_o           (cause_seen),
    .trk_head_o             (trk_head),
    .trk_xbar_answered_o    (trk_xbar_answered),
    .trk_xbar_answer_o      (trk_xbar_answer)
  );

  ///////////////////////////////////////
  // Tag filter: tf_forward to tf_flow //
  ///////////////////////////////////////

  // A request that reaches xbar_main: all, except a write to a filter with tag-only writes.
  function automatic logic is_host(ent_t e);
    return !(TagOnlyWrites && is_wr_kind(e.kind));
  endfunction

  logic pres_cap_store;
  logic head_cap_store;
  logic pres_host;
  logic head_host;
  logic head_parts;
  logic m_is_lookup;
  logic merged;
  assign pres_cap_store = pres.kind == KindCapStore;
  assign head_cap_store = head.kind == KindCapStore;
  assign pres_host      = is_host(pres);
  assign head_host      = is_host(head);
  // Every part of the head's answer has arrived: the xbar answer if it has one, and the meta
  // answer if looked up.
  assign head_parts     = (!head_host || head_xbar_answered) &&
                          (!head.lookup || head_meta_answered);
  // A meta request that is no WTRC tag write: the presented request's lookup.
  assign m_is_lookup    = m_ev.req_vld && !tag_wr_owed &&
                          !(tag_wr_maybe_owed && meta_is_tag_wr);
  // Only the meta answer has an error: the tag filter merges it into d_error.
  assign merged         = head.lookup && head_meta_err && !(head_host && head_xbar_err);

  /////////////////////////////////////////////
  // tf_forward: every access forwarded once //
  /////////////////////////////////////////////

  // A request presented and not yet forwarded is on the host port in the same cycle, unchanged.
  // tf_forward: forwarded unchanged (CHK_TF_FORWARD_01)
  // tbre_clear: tag filter checks hold (CHK_TBRE_CLEAR_03)
  assert_TfReq_ForwardedUnchanged : assert property (requester_ev.req_vld && !pres.xbar_sent &&
    !pres_cap_store && pres_host |-> xbar_ev.req_vld && is_same_a(xbar_h2d_i, requester_h2d_i));
  // Every host request is a presented request not yet forwarded: none invented, none sent twice.
  // tf_forward: no extra host request (CHK_TF_FORWARD_02)
  // tbre_clear: tag filter checks hold (CHK_TBRE_CLEAR_03)
  // tbre_clear: write answered once (CHK_TBRE_CLEAR_04)
  assert_TfReq_NoExtraXbarReq : assert property (xbar_ev.req_vld |->
    requester_ev.req_vld && !pres.xbar_sent && pres_host);
  // The answer's fields equal those of the host port's answer.
  // tf_forward: answer has host fields (CHK_TF_FORWARD_04)
  // tbre_clear: tag filter checks hold (CHK_TBRE_CLEAR_03)
  assert_TfReq_RspHasXbarFields : assert property (requester_ev.rsp_vld && trk_head &&
    !head_cap_store && head_host |->
    trk_xbar_answered && (requester_d2h_i.d_opcode == trk_xbar_answer.d_opcode) &&
    (requester_d2h_i.d_size == trk_xbar_answer.d_size) &&
    (requester_d2h_i.d_source == trk_xbar_answer.d_source) &&
    (requester_d2h_i.d_data == trk_xbar_answer.d_data) &&
    (requester_d2h_i.d_user.data_intg == trk_xbar_answer.d_user.data_intg) &&
    (merged || (requester_d2h_i.d_user.rsp_intg == trk_xbar_answer.d_user.rsp_intg)));
  // Once every part of an answer has arrived, the answer is presented in that cycle.
  // tf_forward: answer on last part (CHK_TF_FORWARD_05)
  // tbre_clear: tag filter checks hold (CHK_TBRE_CLEAR_03)
  assert_TfReq_RspOnLastPart : assert property (head_vld && !head_cap_store && head_parts |->
    requester_ev.rsp_vld);
  // An answer is presented only once its last part has arrived, never before.
  // tf_forward: answer on last part (CHK_TF_FORWARD_05)
  // tbre_clear: tag filter checks hold (CHK_TBRE_CLEAR_03)
  assert_TfReq_RspNotEarly : assert property (requester_ev.rsp_vld && head_vld &&
    !head_cap_store |->
    head_parts);
  // A request is accepted only once its host request was taken, in that cycle or before.
  // tf_forward: accepted after forwarded (CHK_TF_FORWARD_03)
  // tbre_clear: tag filter checks hold (CHK_TBRE_CLEAR_03)
  assert_TfReq_AcceptedAfterXbar : assert property (requester_ev.req_fire |->
    xbar_ev.req_fire || pres.xbar_sent || !pres_host);

  if (CoverCases) begin : gen_tf_forward_cases
    // An unhinted Get to the main SRAM is accepted.
    // tf_forward: case Get to SRAM
    cover_TfReq_GetToSram : cover property (requester_ev.req_fire &&
      is_get(requester_h2d_i) && !requester_tag_i && is_main_sram(requester_h2d_i.a_address));
    // A plain store to the NVM, PutFullData with tag 0, is accepted.
    // tf_forward: case plain store to NVM
    cover_TfReq_PutToNvmTag0 : cover property (requester_ev.req_fire &&
      (requester_h2d_i.a_opcode == PutFullData) && !requester_tag_i &&
      is_nvm(requester_h2d_i.a_address));
    // A one-byte PutPartialData to the main SRAM is accepted.
    // tf_forward: case byte store to SRAM
    cover_TfReq_ByteToSram : cover property (requester_ev.req_fire &&
      (requester_h2d_i.a_opcode == PutPartialData) && (requester_h2d_i.a_size == 2'd0) &&
      is_main_sram(requester_h2d_i.a_address));
    // A Get to a peripheral, outside both tagged regions, is accepted.
    // tf_forward: case Get to peripheral
    cover_TfReq_GetToPeriph : cover property (requester_ev.req_fire &&
      is_get(requester_h2d_i) && !is_tagged(requester_h2d_i.a_address));
    // W1 of a capability load is accepted while W0 is still unanswered.
    // tf_forward: case W1 while W0 open
    cover_TfReq_W1WhileW0Open : cover property (requester_ev.req_fire &&
      (pres.kind == KindLoadW1) && head_vld && (head.kind == KindLoadW0) && (pres_idx != '0));
    // The host port stalls with a_ready 0 while the meta port takes the lookup.
    // tf_forward: case host port stalls
    cover_TfReq_XbarStalls : cover property (requester_ev.req_vld && pres.lookup &&
      m_ev.req_fire && !xbar_ev.req_fire && !pres.xbar_sent);
    // The meta port stalls while the host port takes the request.
    // tf_forward: case meta port stalls
    cover_TfReq_MetaStalls : cover property (requester_ev.req_vld && pres.lookup &&
      xbar_ev.req_fire && !m_ev.req_fire && !pres.meta_sent);
    // Answer order: a part arrives in the cycle it is first offered. A meta answer taken
    // earlier arrived earlier; so did a host answer taken earlier, or one offered and not
    // taken in the cycle before (the host must hold it).

    // An answer's meta part arrives before its host part.
    // tf_forward: case meta answer first
    cover_TfReq_MetaRspFirst : cover property (requester_ev.rsp_vld && head_vld &&
      head.lookup && head.meta_answered && !head.xbar_answered &&
      !$past(xbar_ev.rsp_vld && !xbar_ev.rsp_fire));
    // An answer's host part arrives before its meta part.
    // tf_forward: case host answer first
    cover_TfReq_XbarRspFirst : cover property (requester_ev.rsp_vld && head_vld &&
      head.lookup && !head.meta_answered &&
      (head.xbar_answered || $past(xbar_ev.rsp_vld && !xbar_ev.rsp_fire)));
    // An answer's host and meta parts arrive in the same cycle.
    // tf_forward: case both parts together
    cover_TfReq_RspPartsTogether : cover property (requester_ev.rsp_vld && head_vld &&
      head.lookup && !head.meta_answered && !head.xbar_answered &&
      !$past(xbar_ev.rsp_vld && !xbar_ev.rsp_fire));
    // The host port's answer to a request carries d_error.
    // tf_forward: edge case host answer error
    cover_TfReq_XbarRspErr : cover property (requester_ev.rsp_vld && head_vld &&
      !head_cap_store && head_xbar_err);
    // Requests are accepted in two consecutive cycles.
    // tf_forward: edge case back to back
    cover_TfReq_BackToBack : cover property (requester_ev.req_fire ##1
      requester_ev.req_fire);
    // A second request is presented in the cycle the first is answered.
    // tf_forward: edge case request in answer cycle
    cover_TfReq_PresentedOnRsp : cover property (requester_ev.req_vld && pop &&
      (pres_idx != '0));
  end

  ////////////////////////////////////////
  // tf_lookup: when a tag is looked up //
  ////////////////////////////////////////

  // A request with Lookup(r) has its meta request in the same cycle.
  // tf_lookup: lookup in same cycle (CHK_TF_LOOKUP_01)
  // tbre_clear: tag filter checks hold (CHK_TBRE_CLEAR_03)
  // tbre_clear: write answered once (CHK_TBRE_CLEAR_04)
  assert_TfLookup_MetaReqSameCycle : assert property (requester_ev.req_vld && pres.lookup &&
    !pres.meta_sent && !tag_wr_owed && !tag_wr_maybe_owed |-> m_ev.req_vld);
  // Every meta request belongs to a presented request with Lookup(r), at most one per request.
  // tf_lookup: no unneeded lookup (CHK_TF_LOOKUP_02)
  // tbre_clear: tag filter checks hold (CHK_TBRE_CLEAR_03)
  // tbre_clear: write answered once (CHK_TBRE_CLEAR_04)
  assert_TfLookup_NoUnneededLookup : assert property (m_is_lookup |->
    requester_ev.req_vld && pres.lookup && !pres.meta_sent);

  if (CoverCases) begin : gen_tf_lookup_cases
    // Cases: one input varied from the first, an unhinted Get to the main SRAM.
    function automatic logic is_req(tl_a_op_e op, addr_t a, logic tag);
      return requester_ev.req_fire && (requester_h2d_i.a_opcode == op) &&
             (requester_h2d_i.a_address == a) && (requester_tag_i == tag);
    endfunction

    // In CHERIoT mode, a hinted Get of W0 at 0x1000_1238 is accepted.
    // tf_lookup: case hinted W0 Get
    cover_TfLookup_HintedW0Get : cover property (ena && is_req(Get, 32'h1000_1238, 1'b1));
    // In CHERIoT mode, a hinted Get of W1 at 0x1000_123C is accepted.
    // tf_lookup: case hinted W1 Get
    cover_TfLookup_HintedW1Get : cover property (ena && is_req(Get, 32'h1000_123C, 1'b1));
    // In CHERIoT mode, an unhinted Get at 0x1000_1238 is accepted.
    // tf_lookup: case unhinted Get
    cover_TfLookup_UnhintedGet : cover property (ena && is_req(Get, 32'h1000_1238, 1'b0));
    // In CHERIoT mode, a word store (sw) at 0x1000_1238 with tag 0 is accepted.
    // tf_lookup: case word store
    cover_TfLookup_StoreWord : cover property (ena && is_req(PutFullData, 32'h1000_1238, 1'b0));
    // In CHERIoT mode, a byte store (sb) at 0x1000_1239 with tag 0 is accepted.
    // tf_lookup: case byte store
    cover_TfLookup_StoreByte : cover property (ena &&
      is_req(PutPartialData, 32'h1000_1239, 1'b0));
    // In CHERIoT mode, a capability store (csc) at 0x1000_1238 with tag 1 is accepted.
    // tf_lookup: case capability store
    cover_TfLookup_CapStore : cover property (ena && is_req(PutFullData, 32'h1000_1238, 1'b1));
    // In CHERIoT mode, a hinted Get at 0x3000_0400, in the NVM, is accepted.
    // tf_lookup: case NVM capability load
    cover_TfLookup_NvmCapLoad : cover property (ena && is_req(Get, 32'h3000_0400, 1'b1));
    // In CHERIoT mode, an NVM capability store at 0x3000_0400 with tag 1 is accepted.
    // tf_lookup: case NVM capability store
    cover_TfLookup_NvmCapStore : cover property (ena && is_req(PutFullData, 32'h3000_0400, 1'b1));
    // In CHERIoT mode, an NVM word store at 0x3000_0400 with tag 0 is accepted.
    // tf_lookup: case NVM word store
    cover_TfLookup_NvmStoreWord : cover property (ena && is_req(PutFullData, 32'h3000_0400, 1'b0));
    // In CHERIoT mode, a hinted Get of the peripheral at 0x4000_0000 is accepted.
    // tf_lookup: case peripheral Get
    cover_TfLookup_PeriphGet : cover property (ena && is_req(Get, 32'h4000_0000, 1'b1));
    // In CHERIoT mode, a tag-0 store to the bitmap window at 0x1100_0100 is accepted.
    // tf_lookup: case bitmap store
    cover_TfLookup_BitmapStore : cover property (ena && is_req(PutFullData, 32'h1100_0100, 1'b0));
    // With cheriot_ena_i at MuBi4False, a hinted Get at 0x1000_1238 is accepted.
    // tf_lookup: case ePMP mode
    cover_TfLookup_ModeFalse : cover property ((cheriot_ena_i == prim_mubi_pkg::MuBi4False) &&
      is_req(Get, 32'h1000_1238, 1'b1));
    // With cheriot_ena_i at the invalid value 4'h0, a hinted Get at 0x1000_1238 is accepted.
    // tf_lookup: case invalid mode
    cover_TfLookup_ModeInvalid : cover property (
      (cheriot_ena_i == prim_mubi_pkg::mubi4_t'(4'h0)) && is_req(Get, 32'h1000_1238, 1'b1));

    // Truth table: access row r (hinted W0 Get, hinted W1 Get, plain Get, write tag 0,
    // write tag 1) by region column c (CHERIoT main SRAM, CHERIoT NVM, CHERIoT other, ePMP);
    // one cover per row and column.
    function automatic logic is_row(int unsigned r);
      logic wr;
      wr = is_wr(requester_h2d_i);
      return (r == 0) ? (is_get(requester_h2d_i) &&  requester_tag_i &&  is_w0(requester_h2d_i)) :
             (r == 1) ? (is_get(requester_h2d_i) &&  requester_tag_i && !is_w0(requester_h2d_i)) :
             (r == 2) ? (is_get(requester_h2d_i) && !requester_tag_i)                       :
             (r == 3) ? (wr && !requester_tag_i)                                        :
                        (wr &&  requester_tag_i);
    endfunction
    function automatic logic is_col(int unsigned c);
      addr_t a;
      a = requester_h2d_i.a_address;
      return (c == 0) ? (ena && is_main_sram(a)) :
             (c == 1) ? (ena && is_nvm(a))       :
             (c == 2) ? (ena && !is_tagged(a))   :
                        !ena;
    endfunction
    for (genvar r = 0; r < 5; r++) begin : gen_tt_row
      for (genvar c = 0; c < 4; c++) begin : gen_tt_col
        // An access of each truth table row is accepted in each region and mode column.
        // tf_lookup: truth table
        cover_TfLookup_TruthTableCell : cover property (requester_ev.req_fire && is_row(r) &&
          is_col(c));
      end
    end

    // Edge cases: first and last capability of each region, one beyond, the seam.
    localparam addr_t EdgeAddr [10] = '{32'h0FFF_FFF8, 32'h1000_0000, 32'h1002_FFF8, 32'h1003_0000,
                                        32'h2FFF_FFF8, 32'h3000_0000, 32'h301F_FFF8, 32'h3020_0000,
                                        32'h1001_FFF8, 32'h1002_0000};
    for (genvar k = 0; k < 10; k++) begin : gen_edge_addr
      // A read or write at each region edge, one capability beyond it, or the seam is accepted.
      // tf_lookup: edge case region edge address
      cover_TfLookup_RegionEdgeAddr : cover property (ena && requester_ev.req_fire &&
        (requester_h2d_i.a_address == EdgeAddr[k]) &&
        (is_wr(requester_h2d_i) || is_get(requester_h2d_i)));
    end

    // Edge cases: every cheriot_ena_i value v, one cover per value.
    for (genvar v = 0; v < 16; v++) begin : gen_edge_ena
      // A request to a tagged region is accepted with each of the 16 cheriot_ena_i values.
      // tf_lookup: edge case Every mode value
      cover_TfLookup_EveryModeValue : cover property (
        (cheriot_ena_i == prim_mubi_pkg::mubi4_t'(v)) &&
        requester_ev.req_fire && is_tagged(requester_h2d_i.a_address));
    end
  end

  ///////////////////////////////////////////////////////
  // tf_meta_request: which word, which bit, which tag //
  ///////////////////////////////////////////////////////

  // Every lookup's meta request carries the tag word and tag bit of the request's address.
  // tf_meta_request: tag word and bit (CHK_TF_META_REQUEST_01)
  // tbre_clear: tag filter checks hold (CHK_TBRE_CLEAR_03)
  assert_TfMetaReq_TagWordAndBit : assert property (m_is_lookup |->
    (m_h2d_i.a_address == tag_word(requester_h2d_i.a_address)) &&
    (m_bit_sel_i == tag_bit(requester_h2d_i.a_address)));
  // A write's meta request carries the write's tag as the tag to write.
  // tf_meta_request: write carries its tag (CHK_TF_META_REQUEST_02)
  // tbre_clear: tag filter checks hold (CHK_TBRE_CLEAR_03)
  assert_TfMetaReq_WrCarriesTag : assert property (m_is_lookup && is_wr(requester_h2d_i) |->
    m_tag_i == requester_tag_i);
  // A read's meta request is a Get, a write's is not.
  // tf_meta_request: Get only for a read (CHK_TF_META_REQUEST_03)
  // tbre_clear: tag filter checks hold (CHK_TBRE_CLEAR_03)
  assert_TfMetaReq_GetOnlyForRead : assert property (m_is_lookup |->
    (m_h2d_i.a_opcode == Get) == is_get(requester_h2d_i));

  if (CoverCases) begin : gen_tf_meta_request_cases
    function automatic logic is_meta(addr_t a, addr_t w, bit_sel_t b);
      return m_ev.req_fire && !tag_wr_owed && (requester_h2d_i.a_address == a) &&
             (m_h2d_i.a_address == w) && (m_bit_sel_i == b);
    endfunction

    // A request at 0x1000_1238, W0, makes a meta request for word 0x1100_8C48, bit 7.
    // tf_meta_request: case W0, bit 7
    cover_TfMetaReq_W0Bit7 : cover property (is_meta(32'h1000_1238, 32'h1100_8C48, 5'd7));
    // A request at 0x1000_123C, W1, makes a meta request for word 0x1100_8C48, bit 7.
    // tf_meta_request: case W1, bit 7
    cover_TfMetaReq_W1Bit7 : cover property (is_meta(32'h1000_123C, 32'h1100_8C48, 5'd7));
    // A byte store inside the capability at 0x1000_1238 uses word 0x1100_8C48, bit 7.
    // tf_meta_request: case byte in capability
    cover_TfMetaReq_ByteInCap : cover property (m_ev.req_fire && !tag_wr_owed &&
      (requester_h2d_i.a_opcode == PutPartialData) && (requester_h2d_i.a_address > 32'h1000_1238) &&
      (requester_h2d_i.a_address <= 32'h1000_123F) && (m_h2d_i.a_address == 32'h1100_8C48) &&
      (m_bit_sel_i == 5'd7));
    // A request at the next capability, 0x1000_1240, makes a meta request for 0x1100_8C48, bit 8.
    // tf_meta_request: case next capability, bit 8
    cover_TfMetaReq_NextCapBit8 : cover property (is_meta(32'h1000_1240, 32'h1100_8C48, 5'd8));
    // A request at the first main SRAM capability, 0x1000_0000, uses word 0x1100_8C00, bit 0.
    // tf_meta_request: case first SRAM capability
    cover_TfMetaReq_FirstSramCap : cover property (is_meta(32'h1000_0000, 32'h1100_8C00, 5'd0));
    // A request at 0x1001_FFF8, just below the seam, uses word 0x1100_93FC, bit 31.
    // tf_meta_request: case seam
    cover_TfMetaReq_SeamBit31 : cover property (is_meta(32'h1001_FFF8, 32'h1100_93FC, 5'd31));
    // A request at 0x1002_0000, just above the seam, uses word 0x1100_9400, bit 0.
    // tf_meta_request: case seam
    cover_TfMetaReq_SeamBit0 : cover property (is_meta(32'h1002_0000, 32'h1100_9400, 5'd0));
    // A request at the last main SRAM capability, 0x1002_FFF8, uses word 0x1100_97FC, bit 31.
    // tf_meta_request: case last SRAM capability
    cover_TfMetaReq_LastSramCap : cover property (is_meta(32'h1002_FFF8, 32'h1100_97FC, 5'd31));
    // A request at the first NVM capability, 0x3000_0000, uses word 0x1100_0C00, bit 0.
    // tf_meta_request: case NVM capabilities
    cover_TfMetaReq_FirstNvmCap : cover property (is_meta(32'h3000_0000, 32'h1100_0C00, 5'd0));
    // A request at 0x3000_0400 in the NVM uses word 0x1100_0C10, bit 0.
    // tf_meta_request: case NVM capabilities
    cover_TfMetaReq_NvmExampleCap : cover property (is_meta(32'h3000_0400, 32'h1100_0C10, 5'd0));
    // A request at the last NVM capability, 0x301F_FFF8, uses word 0x1100_8BFC, bit 31.
    // tf_meta_request: case NVM capabilities
    cover_TfMetaReq_LastNvmCap : cover property (is_meta(32'h301F_FFF8, 32'h1100_8BFC, 5'd31));
    // A plain store (sw, sh or sb) makes a meta request with tag 0 to write.
    // tf_meta_request: case plain store, tag 0
    cover_TfMetaReq_PlainStoreTag0 : cover property (m_ev.req_fire && !tag_wr_owed &&
      is_wr(requester_h2d_i) && !requester_tag_i && !m_tag_i);
    // A capability store of a tagged capability makes a meta request with tag 1 to write.
    // tf_meta_request: case capability store, tag 1
    cover_TfMetaReq_CapStoreTag1 : cover property (m_ev.req_fire && !tag_wr_owed &&
      (requester_h2d_i.a_opcode == PutFullData) && requester_tag_i && m_tag_i);
    // A full-word store to the main SRAM makes a meta request with tag 0 to write.
    // tf_meta_request: case capability store, tag 0
    cover_TfMetaReq_CapStoreTag0 : cover property (m_ev.req_fire && !tag_wr_owed &&
      (requester_h2d_i.a_opcode == PutFullData) && is_main_sram(requester_h2d_i.a_address) &&
      !m_tag_i);
  end

  //////////////////////////////////////////////////////
  // tf_sticky_tag: the tag returned with each answer //
  //////////////////////////////////////////////////////

  // The tag of every checked answer equals the value the sticky-tag rule gives.
  // tf_sticky_tag: answer tag follows rule (CHK_TF_STICKY_TAG_01)
  // tbre_clear: tag filter checks hold (CHK_TBRE_CLEAR_03)
  assert_TfStickyTag_RspTagFollowsRule : assert property (requester_ev.rsp_vld && head_vld &&
    !head_cap_store &&
    head_tag_chk |-> requester_tag_rsp_i == head_tag);
  // A W1 answer with no W0 tag captured returns tag 0.
  // tf_sticky_tag: a check the testplan has retired (open item in the checker 3 uarch)
  assert_TfStickyTag_LoneW1Untagged : assert property (requester_ev.rsp_vld && head_vld &&
    (head.kind == KindLoadW1) && (capture == CaptureNone) |-> !requester_tag_rsp_i);
  // A write answered between W0 and W1 leaves W1 its W0 tag.
  // tf_sticky_tag: a check the testplan has retired (open item in the checker 3 uarch)
  assert_TfStickyTag_KeptOverWrite : assert property (requester_ev.rsp_vld && head_vld &&
    (head.kind == KindLoadW1) && (capture == CaptureHeld) && capture_wr |->
    requester_tag_rsp_i == capture_tag);

  if (CoverCases) begin : gen_tf_sticky_tag_cases
    logic ans_w0;
    logic ans_w1;
    assign ans_w0 = requester_ev.rsp_fire && head_vld && (head.kind == KindLoadW0);
    assign ans_w1 = requester_ev.rsp_fire && head_vld && (head.kind == KindLoadW1);

    // A capability load from the main SRAM returns tag 1 on W0 and then on W1.
    // tf_sticky_tag: case SRAM capability, tag 1
    cover_TfStickyTag_SramCapTag1 : cover property ((ans_w0 && requester_tag_rsp_i &&
      is_main_sram(head.addr)) ##[1:$] (ans_w1 && requester_tag_rsp_i));
    // A capability load from the main SRAM returns tag 0 on W0 and then on W1.
    // tf_sticky_tag: case SRAM capability, tag 0
    cover_TfStickyTag_SramCapTag0 : cover property ((ans_w0 && (requester_tag_rsp_i == 1'b0) &&
      is_main_sram(head.addr)) ##[1:$] (ans_w1 && (requester_tag_rsp_i == 1'b0)));
    // A capability load from the NVM returns tag 1 on W0 and then on W1.
    // tf_sticky_tag: case NVM capability, tag 1
    cover_TfStickyTag_NvmCapTag1 : cover property ((ans_w0 && requester_tag_rsp_i &&
      is_nvm(head.addr)) ##[1:$] (ans_w1 && requester_tag_rsp_i));
    // A plain load of a word in a tagged region is answered.
    // tf_sticky_tag: case word load
    cover_TfStickyTag_LoadWord : cover property (requester_ev.rsp_fire && head_vld &&
      (head.kind == KindRead) && is_tagged(head.addr));
    // A load of a tagged region is answered in ePMP mode.
    // tf_sticky_tag: case load in ePMP mode
    cover_TfStickyTag_LoadInEpmpMode : cover property (!ena && requester_ev.rsp_fire && head_vld &&
      (head.kind == KindRead) && is_tagged(head.addr));
    // A load of a peripheral address is answered in CHERIoT mode.
    // tf_sticky_tag: case peripheral load
    cover_TfStickyTag_PeriphLoad : cover property (ena && requester_ev.rsp_fire && head_vld &&
      (head.kind == KindRead) && !is_tagged(head.addr));
    // A store's answer is taken.
    // tf_sticky_tag: case store answer
    cover_TfStickyTag_StoreRsp : cover property (requester_ev.rsp_fire && head_vld &&
      (head.kind == KindWrite));
    // W0 of a capability load is answered with d_error, then W1 is answered.
    // tf_sticky_tag: case W0 error, then W1
    cover_TfStickyTag_W0ErrThenW1 : cover property ((ans_w0 && requester_d2h_i.d_error) ##[1:$]
      ans_w1);
    // A W1 answer comes with no W0 tag captured.
    // tf_sticky_tag: a check the testplan has retired (open item in the checker 3 uarch)
    cover_TfStickyTag_LoneW1Rsp : cover property (ans_w1 && (capture == CaptureNone));
    // W1 is answered after a write was answered between W0 and W1.
    // tf_sticky_tag: a check the testplan has retired (open item in the checker 3 uarch)
    cover_TfStickyTag_WrBetweenWords : cover property (ans_w1 && (capture == CaptureHeld) &&
      capture_wr);
  end

  //////////////////////////////////////////////
  // tf_errors: errors and response integrity //
  //////////////////////////////////////////////

  logic ans_chk;
  logic exp_err;
  assign ans_chk = requester_ev.rsp_vld && head_vld && !head_cap_store && head_parts;
  assign exp_err = (head_host && head_xbar_err) || (head.lookup && head_meta_err);

  // An answer whose host answer or joined meta answer has an error carries d_error.
  // tf_errors: error when a part has one (CHK_TF_ERRORS_01)
  // tbre_clear: tag filter checks hold (CHK_TBRE_CLEAR_03)
  assert_TfErr_CauseGivesErr : assert property (ans_chk && exp_err |-> requester_d2h_i.d_error);
  // An answer with d_error has a host answer or a joined meta answer with an error.
  // tf_errors: no error without a cause (CHK_TF_ERRORS_02)
  // tbre_clear: tag filter checks hold (CHK_TBRE_CLEAR_03)
  assert_TfErr_NoErrWithoutCause : assert property (ans_chk && requester_d2h_i.d_error |-> exp_err);
  // When only the meta answer has an error, the answer's response integrity matches the host's.
  // tf_errors: merged error keeps integrity (CHK_TF_ERRORS_03)
  // tbre_clear: tag filter checks hold (CHK_TBRE_CLEAR_03)
  assert_TfErr_MergedErrKeepsIntg : assert property (requester_ev.rsp_vld && trk_head &&
    !head_cap_store &&
    head_host && merged |-> is_rsp_intg_ok(requester_d2h_i) == is_rsp_intg_ok(trk_xbar_answer));

  if (CoverCases) begin : gen_tf_errors_cases
    // A read and a write for each truth table row (xbar error, lookup, meta
    // error), row 4 twice: xbar response integrity valid, then broken.
    for (genvar w = 0; w < 2; w++) begin : gen_err_kind
      logic taken;
      assign taken = requester_ev.rsp_fire && head_vld && !head_cap_store &&
                     (is_wr_kind(head.kind) == (w == 1));
      // A read or a write is answered with no host error and no lookup.
      // tf_errors: truth table
      cover_TfErr_TruthRow1 : cover property (taken && !head.lookup && !head_xbar_err);
      // A read or a write is answered with a host error and no lookup.
      // tf_errors: truth table
      cover_TfErr_TruthRow2 : cover property (taken && !head.lookup &&  head_xbar_err);
      // A looked-up read or write is answered with no host error and no meta error.
      // tf_errors: truth table
      cover_TfErr_TruthRow3 : cover property (taken &&  head.lookup && !head_xbar_err &&
        !head_meta_err);
      // Only the meta error sets d_error, and the host's response integrity is valid.
      // tf_errors: truth table
      cover_TfErr_TruthRow4IntgOk : cover property (taken && merged && trk_head &&
        is_rsp_intg_ok(trk_xbar_answer));
      // Only the meta error sets d_error, and the host's response integrity is broken.
      // tf_errors: truth table
      cover_TfErr_TruthRow4IntgBad : cover property (taken && merged && trk_head &&
        !is_rsp_intg_ok(trk_xbar_answer));
      // A looked-up read or write is answered with a host error and no meta error.
      // tf_errors: truth table
      cover_TfErr_TruthRow5 : cover property (taken &&  head.lookup &&  head_xbar_err &&
        !head_meta_err);
      // A looked-up read or write is answered with both a host error and a meta error.
      // tf_errors: truth table
      cover_TfErr_TruthRow6 : cover property (taken &&  head.lookup &&  head_xbar_err &&
         head_meta_err);
    end
  end

  ///////////////////////////////////////
  // tf_flow: no stall, no lost answer //
  ///////////////////////////////////////

  // The meta port's d_ready is 1 in every cycle a meta answer is offered.
  // tf_flow: meta answer taken (CHK_TF_FLOW_01)
  // tbre_clear: tag filter checks hold (CHK_TBRE_CLEAR_03)
  assert_TfFlow_MetaRspTaken : assert property (m_ev.rsp_vld |-> m_h2d_i.d_ready);
  // An answer is offered only while an accepted request waits for it, so none is answered twice.
  // tf_flow: no extra answer (CHK_TF_FLOW_02)
  // tbre_clear: tag filter checks hold (CHK_TBRE_CLEAR_03)
  // tbre_clear: write answered once (CHK_TBRE_CLEAR_04)
  assert_TfFlow_NoExtraRsp : assert property (requester_ev.rsp_vld |-> head_vld);
  // Liveness (run B): every request presented is accepted, and the oldest
  // accepted request is answered, so every accepted request is (answers in order: contract C6).
  if (RunLive == LiveB) begin : gen_live_b_tf
`ifdef FPV_ON
`ifndef VERILATOR
    // Every presented request is accepted, at some point.
    // tf_flow: request eventually accepted (CHK_TF_FLOW_03)
    // tbre_clear: tag filter checks hold (CHK_TBRE_CLEAR_03)
    assert_TfFlow_ReqEventuallyAccepted : assert property (requester_ev.req_vld |->
      s_eventually requester_ev.req_fire);
    // Every accepted request is answered, at some point.
    // tf_flow: request eventually answered (CHK_TF_FLOW_04)
    // tbre_clear: tag filter checks hold (CHK_TBRE_CLEAR_03)
    assert_TfFlow_ReqEventuallyAnswered : assert property (head_vld |-> s_eventually pop);
`endif
`endif
  end

  if (CoverCases) begin : gen_tf_flow_cases
    // A second request is accepted while the first is still unanswered.
    // tf_flow: case two outstanding
    cover_TfFlow_TwoOutstanding : cover property (requester_ev.req_fire && head_vld &&
      (pres_idx != '0));
    // With no request presented, pres_idx is the number of stored entries: 2 is a full FIFO.
    logic head_waits;  // the head's xbar answer has not arrived
    assign head_waits = head_vld && !head_xbar_answered;
    // A meta answer arrives while the FIFO is full, with two requests outstanding.
    // tf_flow: case meta FIFO full
    cover_TfFlow_MetaFifoFull : cover property (m_ev.rsp_vld && head_vld &&
      (pres_idx == 2'd2) && !requester_ev.req_vld);
    // A host answer is held for several cycles while meta answers arrive.
    // tf_flow: case host answer held
    cover_TfFlow_XbarRspHeld : cover property ((head_waits && m_ev.rsp_vld) ##1
      head_waits [*2]);
  end

  ///////////////////////////////////////////////////////////////////
  // tbre_clear: a write to a filter with tag-only writes answered //
  ///////////////////////////////////////////////////////////////////

  if (TagOnlyWrites) begin : gen_tag_only_writes
    // A write is answered once, with AccessAck, its own source and its meta answer's d_error.
    // tbre_clear: write answered once (CHK_TBRE_CLEAR_04)
    assert_TbreClear_WrAnsweredAccessAck : assert property (requester_ev.rsp_vld && head_vld &&
      is_wr_kind(head.kind) && head_parts |->
      (requester_d2h_i.d_opcode == AccessAck) && (requester_d2h_i.d_source == head.src) &&
      (requester_d2h_i.d_error == head_meta_err));
  end

  /////////////
  // Outputs //
  /////////////

  assign pres_idx_o             = pres_idx;
  assign pres_o                 = pres;
  assign head_vld_o             = head_vld;
  assign head_o                 = head;
  assign head_xbar_answered_o   = head_xbar_answered;
  assign head_xbar_bad_intg_o   = head_xbar_bad_intg;
  assign head_match_o           = head_match;
  assign head_meta_answered_o   = head_meta_answered;
  assign head_meta_err_o        = head_meta_err;
  assign head_tag_wr_o          = head_tag_wr;
  assign head_tag_wr_maybe_o    = head_tag_wr_maybe;
  assign capture_o              = capture;
  assign pop_o                  = pop;
  assign xbar_answer_vld_o      = xbar_answer_vld;
  assign xbar_answer_ent_o      = xbar_answer_ent;
  assign tag_wr_owed_o          = tag_wr_owed;
  assign tag_wr_maybe_owed_o    = tag_wr_maybe_owed;
  assign tag_wr_addr_o          = tag_wr_addr;
  assign meta_is_tag_wr_o       = meta_is_tag_wr;
  assign cap_state_o            = cap_state;
  assign cap_addr_o             = cap_addr;
  assign word_cause_now_o       = word_cause_now;
  assign out_of_seq_cause_now_o = out_of_seq_cause_now;
  assign cause_seen_o           = cause_seen;

endmodule
