// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// A model of the core's tag filter and its WTRC, written from the spec. For each request on
// cored_tl_d it records what kind of access it is, whether a tag lookup is due and where the
// request sits in a WTRC sequence; it joins the xbar answer and the meta answer in order and
// predicts the tag and the error of the oldest entry's answer. A tracker follows one request,
// chosen by the free input pick_i, to its xbar answer, so the properties can compare one answer
// field by field without keeping a queue of answers.
//
// Signal names: x_d is the next value of x_q; trk_ the tracked request; *_now an event of this
// cycle; *_eff the stored value, or this cycle's event when there is one; e the entries as they
// stand this cycle, with the presented request's entry already made.
module tpchk_tf_model
  import tlul_pkg::*;
  import tpchk_pkg::*;
(
  input  logic     clk_i,
  input  logic     rst_ni,

  // The request the tracker follows: free in FPV
  input  logic     pick_i,

  // cored_tl_d
  input  tl_h2d_t  core_h2d_i,
  input  logic     core_tag_i,
  input  tl_d2h_t  core_d2h_i,
  input  ev_t      core_ev_i,
  input  logic     ena_i,

  // cored_tl_h
  input  tl_d2h_t  xbar_d2h_i,
  input  ev_t      xbar_ev_i,

  // the tag filter's meta port
  input  tl_h2d_t  m_h2d_i,
  input  logic     m_tag_i,
  input  bit_sel_t m_bit_sel_i,
  input  tl_d2h_t  m_d2h_i,
  input  logic     m_tag_rsp_i,
  input  ev_t      m_ev_i,

  // The request presented on cored_tl_d
  output idx_t     pres_idx_o,
  output ent_t     pres_o,

  // The oldest entry: its answer is due next on cored_tl_d
  output logic     head_vld_o,
  output ent_t     head_o,
  output logic     head_xbar_answered_o,
  output logic     head_xbar_err_o,
  output logic     head_xbar_bad_intg_o,
  output logic     head_match_o,
  output logic     head_meta_answered_o,
  output logic     head_meta_err_o,
  output logic     head_tag_chk_o,
  output logic     head_tag_o,
  output logic     head_tag_wr_o,
  output logic     head_tag_wr_maybe_o,
  output capture_e capture_o,
  output logic     capture_tag_o,
  output logic     capture_wr_o,
  output logic     pop_o,

  // Xbar answer pairing
  output logic     xbar_answer_vld_o,
  output ent_t     xbar_answer_ent_o,

  // The meta request presented now is an owed or possible WTRC tag write
  output logic     tag_wr_owed_o,
  output logic     tag_wr_maybe_owed_o,
  output addr_t    tag_wr_addr_o,
  output logic     meta_is_tag_wr_o,

  // The WTRC sequence as the presented request sees it, and the open capability
  output cap_e     cap_state_o,
  output addr_t    cap_addr_o,

  // WTRC fault causes ([ToO] Error Handling)
  output logic     word_cause_now_o,
  output logic     out_of_seq_cause_now_o,
  output logic     cause_seen_o,

  // The tracked request
  output logic     trk_head_o,           // it is the oldest entry
  output logic     trk_xbar_answered_o,  // its xbar answer was taken, or is presented now
  output tl_d2h_t  trk_xbar_answer_o     // that xbar answer
);

  /////////////////////////////////////////
  // The request presented on cored_tl_d //
  /////////////////////////////////////////

  // Two entries are kept between cycles; within a cycle a third is the request presented in the
  // cycle the oldest answer is taken (A2).
  ent_t ent_q [2];
  logic pres_q;
  cap_e cap_q;
  addr_t cap_addr_q;
  logic match0_q;
  logic seq_broken_q;

  idx_t cnt;
  logic alloc;
  idx_t pres_idx;
  assign cnt      = idx_t'(ent_q[0].vld) + idx_t'(ent_q[1].vld);
  assign alloc    = core_ev_i.req_vld && !pres_q;

  // The presented request's entry is the last valid one, or the next free one when it is made.
  assign pres_idx = pres_q ? (cnt - idx_t'(1)) : cnt;

  // In the cycle W1 is answered, a new request is judged against CapIdle ([ToO] WTRC).
  logic head_q_w1;
  logic w1_done_now;
  cap_e cap_eff;
  assign head_q_w1   = ent_q[0].vld && (ent_q[0].kind == KindCapStore) && ent_q[0].w1 &&
                       !ent_q[0].out_of_seq;
  assign w1_done_now = core_ev_i.rsp_fire && head_q_w1;
  assign cap_eff     = w1_done_now ? CapIdle : cap_q;

  kind_e new_kind;
  logic  new_cap_store;
  logic  new_w1;
  logic  new_same_cap;
  logic  new_out_of_seq;
  assign new_kind       = req_kind(core_h2d_i, core_tag_i, ena_i);
  assign new_cap_store  = new_kind == KindCapStore;
  assign new_w1         = !is_w0(core_h2d_i);
  assign new_same_cap   = is_same_cap(core_h2d_i.a_address, cap_addr_q);

  // Out of sequence ([ToO] WTRC): a W0 when a capability is open; a W1 that is not the open
  // capability's W1; any other request while W0 or W1 is taken.
  assign new_out_of_seq = (new_cap_store && !new_w1) ? (cap_eff != CapIdle)                  :
                          (new_cap_store &&  new_w1) ? !((cap_eff == CapW0) && new_same_cap) :
                                                       (cap_eff == CapW0) || (cap_eff == CapW1);

  ent_t new_ent;
  always_comb begin
    new_ent             = '0;
    new_ent.vld         = 1'b1;
    new_ent.kind        = new_kind;
    new_ent.lookup      = is_lookup(core_h2d_i, core_tag_i, ena_i);
    new_ent.w1          = new_w1;
    new_ent.addr        = core_h2d_i.a_address;
    new_ent.src         = core_h2d_i.a_source;
    new_ent.out_of_seq  = new_out_of_seq;
    new_ent.fault       = new_cap_store && (new_out_of_seq || !is_full_put(core_h2d_i) ||
                                            !is_cmd_intg_ok(core_h2d_i) ||
                                            !is_a_data_intg_ok(core_h2d_i));
    new_ent.full_in_seq = is_full_put(core_h2d_i) && !new_out_of_seq;
    new_ent.data        = core_h2d_i.a_data;
    new_ent.data_intg   = core_h2d_i.a_user.data_intg;
  end

  // The entries as they stand this cycle.
  ent_t e [NumEnt];
  always_comb begin
    e[0] = ent_q[0];
    e[1] = ent_q[1];
    e[2] = '0;
    if (alloc) e[pres_idx] = new_ent;
  end

  ////////////////////////////
  // Xbar answers, in order //
  ////////////////////////////

  // A7: xbar_main answers in request order, so a xbar answer belongs to the oldest entry whose
  // xbar request was taken and whose xbar answer was not.
  logic              xbar_sent_now;
  logic [NumEnt-1:0] xbar_sent_eff;
  logic [NumEnt-1:0] xbar_waiting;
  assign xbar_sent_now = xbar_ev_i.req_fire && core_ev_i.req_vld;
  for (genvar i = 0; i < NumEnt; i++) begin : gen_xbar_waiting
    assign xbar_sent_eff[i] = e[i].xbar_sent || (xbar_sent_now && (pres_idx == idx_t'(i)));
    assign xbar_waiting[i]  = e[i].vld && xbar_sent_eff[i] && !e[i].xbar_answered;
  end

  logic xbar_answer_vld;
  idx_t xbar_answer_idx;
  logic xbar_answer_fire;
  assign xbar_answer_vld  = xbar_ev_i.rsp_vld && (xbar_waiting != '0);
  assign xbar_answer_idx  = oldest(xbar_waiting);
  assign xbar_answer_fire = xbar_answer_vld && xbar_ev_i.rsp_fire;

  ent_t xbar_answer_ent;
  logic xbar_answer_eq;
  logic xbar_answer_match;
  logic xbar_answer_bad_intg;
  assign xbar_answer_ent      = e[xbar_answer_idx];
  assign xbar_answer_eq       = (xbar_answer_ent.data == xbar_d2h_i.d_data) &&
                                (xbar_answer_ent.data_intg == xbar_d2h_i.d_user.data_intg);

  // Match(w) = ReadOk and FullPut and InSeq and Data == NvmData and DataIntg == NvmDataIntg.
  assign xbar_answer_match    = !xbar_d2h_i.d_error && xbar_answer_ent.full_in_seq &&
                                xbar_answer_eq;
  assign xbar_answer_bad_intg = !is_rsp_intg_ok(xbar_d2h_i);

  ////////////////////
  // WTRC tag write //
  ////////////////////

  // W1's NVM answer turns into the tag write when W0 and W1 both matched with no fault
  // ([ToO] WTRC table, row W1). After an out-of-sequence request the spec leaves the open
  // capability's tag write open: it may be issued, and is not required (tag_wr_maybe).
  logic xbar_answer_w1;
  logic w1_ok;
  logic tag_wr_set_now;
  logic tag_wr_maybe_set_now;
  assign xbar_answer_w1       = (xbar_answer_ent.kind == KindCapStore) && xbar_answer_ent.w1 &&
                                !xbar_answer_ent.out_of_seq;
  assign w1_ok                = xbar_answer_w1 && match0_q && xbar_answer_match &&
                                !xbar_answer_ent.fault && !xbar_answer_bad_intg;
  assign tag_wr_set_now       = xbar_answer_vld && w1_ok && !seq_broken_q;
  assign tag_wr_maybe_set_now = xbar_answer_vld && w1_ok &&  seq_broken_q;

  logic [NumEnt-1:0] tag_wr_eff;
  logic [NumEnt-1:0] tag_wr_maybe_eff;
  logic [NumEnt-1:0] owed;
  logic [NumEnt-1:0] maybe;
  for (genvar i = 0; i < NumEnt; i++) begin : gen_tag_wr
    logic set_here;
    logic maybe_set_here;
    assign set_here            = tag_wr_set_now       && (xbar_answer_idx == idx_t'(i));
    assign maybe_set_here      = tag_wr_maybe_set_now && (xbar_answer_idx == idx_t'(i));
    assign tag_wr_eff[i]       = e[i].tag_wr       || set_here;
    assign tag_wr_maybe_eff[i] = e[i].tag_wr_maybe || maybe_set_here;
    assign owed[i]             = e[i].vld && tag_wr_eff[i]       && !e[i].meta_sent;
    assign maybe[i]            = e[i].vld && tag_wr_maybe_eff[i] && !e[i].meta_sent;
  end

  // An owed tag write outlives its entry. The core's answer to W1 retires the entry, and the tag
  // write may leave the meta port a cycle later, so the obligation is held in a register of its
  // own and cleared when the tag write is sent. Without it the tag write is read as the next
  // request's lookup, and every tf_lookup and tf_meta_request check fires at once.
  logic tag_wr_pend_q, tag_wr_pend_d;
  logic tag_wr_maybe_pend_q, tag_wr_maybe_pend_d;
  logic tag_wr_sent;

  logic tag_wr_owed;
  logic tag_wr_maybe_owed;
  assign tag_wr_owed       = (owed  != '0) || tag_wr_pend_q;
  assign tag_wr_maybe_owed = (maybe != '0) || tag_wr_maybe_pend_q;

  assign tag_wr_sent         = m_ev_i.req_fire && meta_req_is_tag_wr;
  assign tag_wr_pend_d       = (tag_wr_pend_q       || tag_wr_set_now)       && !tag_wr_sent;
  assign tag_wr_maybe_pend_d = (tag_wr_maybe_pend_q || tag_wr_maybe_set_now) && !tag_wr_sent;

  addr_t   tag_wr_addr;
  bit_sel_t tag_wr_bit;
  logic    meta_is_tag_wr;
  assign tag_wr_addr    = tag_word(cap_addr_q);
  assign tag_wr_bit     = tag_bit(cap_addr_q);

  // The meta request presented now has the tag write's fields.
  assign meta_is_tag_wr = (m_h2d_i.a_opcode != Get) && m_tag_i &&
                          (m_h2d_i.a_address == tag_wr_addr) && (m_bit_sel_i == tag_wr_bit);

  ///////////////////////////////
  // Meta requests and answers //
  ///////////////////////////////

  // The meta port takes an owed tag write first ([ToO] WTRC: "ahead of any lookup"), else the
  // presented request's lookup.
  logic              meta_req_is_tag_wr;
  logic [NumEnt-1:0] meta_sent_now;
  logic [NumEnt-1:0] meta_sent_eff;
  logic [NumEnt-1:0] meta_waiting;
  assign meta_req_is_tag_wr = tag_wr_owed || (tag_wr_maybe_owed && meta_is_tag_wr);
  for (genvar i = 0; i < NumEnt; i++) begin : gen_meta
    logic is_lookup_now;
    assign is_lookup_now    = core_ev_i.req_vld && (pres_idx == idx_t'(i)) && e[i].lookup &&
                              !e[i].meta_sent;
    assign meta_sent_now[i] = m_ev_i.req_fire &&
                              (meta_req_is_tag_wr ? (owed[i] || maybe[i]) : is_lookup_now);
    assign meta_sent_eff[i] = e[i].meta_sent || meta_sent_now[i];
    assign meta_waiting[i]  = e[i].vld && meta_sent_eff[i] && !e[i].meta_answered;
  end

  // Meta answers come back in meta request order; the port takes each one when offered
  // (REQ_TF_14), so an answer arrives when it is presented.
  logic meta_answer_vld;
  idx_t meta_answer_idx;
  assign meta_answer_vld = m_ev_i.rsp_vld && (meta_waiting != '0);
  assign meta_answer_idx = oldest(meta_waiting);

  //////////////////////
  // The oldest entry //
  //////////////////////

  logic head_accepted_now;
  logic head_vld;
  logic head_xbar_answer_now;
  logic head_meta_answer_now;
  assign head_accepted_now    = core_ev_i.req_fire && (pres_idx == '0);
  assign head_vld             = e[0].vld && (e[0].accepted || head_accepted_now);
  assign head_xbar_answer_now = xbar_answer_vld && (xbar_answer_idx == '0);
  assign head_meta_answer_now = meta_answer_vld && (meta_answer_idx == '0);

  logic head_xbar_answered;
  logic head_xbar_err;
  logic head_xbar_bad_intg;
  logic head_match;
  logic head_meta_answered;
  logic head_meta_err;
  logic head_meta_tag;
  assign head_xbar_answered = e[0].xbar_answered || head_xbar_answer_now;
  assign head_xbar_err      = e[0].xbar_answered ? e[0].xbar_err      : xbar_d2h_i.d_error;
  assign head_xbar_bad_intg = e[0].xbar_answered ? e[0].xbar_bad_intg : xbar_answer_bad_intg;
  assign head_match         = e[0].xbar_answered ? e[0].match         : xbar_answer_match;
  assign head_meta_answered = e[0].meta_answered || head_meta_answer_now;
  assign head_meta_err      = e[0].meta_answered ? e[0].meta_err      : m_d2h_i.d_error;
  assign head_meta_tag      = e[0].meta_answered ? e[0].meta_tag      : m_tag_rsp_i;

  ////////////////////////
  // Capture of the tag //
  ////////////////////////

  capture_e capture_q, capture_d;
  logic capture_tag_q, capture_tag_d;

  // A write was answered while the capture was held (REQ_TF_11b).
  logic capture_wr_q, capture_wr_d;

  // The tag the head's answer must carry ([ToO] Tag Filter; testplan tf_sticky_tag).
  logic head_tag;
  logic head_tag_chk;
  assign head_tag     = (e[0].kind == KindLoadW0) ? head_meta_tag                                 :
                        (e[0].kind == KindLoadW1) ? ((capture_q == CaptureHeld) && capture_tag_q) :
                                                    1'b0;

  // REQ_TF_08: an error answer's tag is not checked; the spec leaves CaptureUnknown open.
  assign head_tag_chk = !((e[0].kind == KindLoadW0) && core_d2h_i.d_error) &&
                        !((e[0].kind == KindLoadW1) && (capture_q == CaptureUnknown));

  logic pop;
  assign pop = core_ev_i.rsp_fire && head_vld;

  always_comb begin
    capture_d     = capture_q;
    capture_tag_d = capture_tag_q;
    capture_wr_d  = capture_wr_q;
    if (pop) begin
      unique case (e[0].kind)
        KindLoadW0: begin
          capture_d     = CaptureHeld;
          capture_tag_d = head_meta_tag;
          capture_wr_d  = 1'b0;
        end
        KindLoadW1: begin
          capture_d     = CaptureNone;
          capture_tag_d = 1'b0;
          capture_wr_d  = 1'b0;
        end
        KindRead:   capture_d    = (capture_q == CaptureHeld) ? CaptureUnknown : capture_q;
        default:    capture_wr_d = capture_wr_q || (capture_q == CaptureHeld);
      endcase
    end
  end

  //////////////////
  // Next entries //
  //////////////////

  ent_t ent_d [2];
  always_comb begin
    ent_t n [NumEnt];
    n = e;
    for (int i = 0; i < NumEnt; i++) begin
      if (xbar_sent_now && (pres_idx == idx_t'(i))) n[i].xbar_sent = 1'b1;
      if (xbar_answer_fire && (xbar_answer_idx == idx_t'(i))) begin
        n[i].xbar_answered = 1'b1;
        n[i].xbar_err      = xbar_d2h_i.d_error;
        n[i].xbar_bad_intg = xbar_answer_bad_intg;
        n[i].match         = xbar_answer_match;
      end
      if (tag_wr_set_now       && (xbar_answer_idx == idx_t'(i))) n[i].tag_wr       = 1'b1;
      if (tag_wr_maybe_set_now && (xbar_answer_idx == idx_t'(i))) n[i].tag_wr_maybe = 1'b1;
      if (meta_sent_now[i]) n[i].meta_sent = 1'b1;
      if (meta_answer_vld && (meta_answer_idx == idx_t'(i))) begin
        n[i].meta_answered = 1'b1;
        n[i].meta_err      = m_d2h_i.d_error;
        n[i].meta_tag      = m_tag_rsp_i;
      end
      if (core_ev_i.req_fire && (pres_idx == idx_t'(i))) n[i].accepted = 1'b1;
    end
    ent_d[0] = pop ? n[1] : n[0];
    ent_d[1] = pop ? n[2] : n[1];
  end

  logic pres_d;
  assign pres_d = core_ev_i.req_vld && !core_ev_i.req_fire;

  ///////////////////
  // WTRC sequence //
  ///////////////////

  ent_t pres_ent;
  logic tag_wr_taken_now;
  logic w0_answer_now;
  assign pres_ent         = e[pres_idx];
  assign tag_wr_taken_now = m_ev_i.req_fire && meta_req_is_tag_wr;
  assign w0_answer_now    = xbar_answer_vld && (xbar_answer_ent.kind == KindCapStore) &&
                            !xbar_answer_ent.w1;

  // Another request out of sequence while a capability is open leaves its tag write open.
  logic breaks_open_cap;
  logic cap_w0_taken_now;
  logic cap_w1_taken_now;
  assign breaks_open_cap  = alloc && new_out_of_seq && !(new_cap_store && !new_w1) &&
                            (cap_eff != CapIdle);
  assign cap_w0_taken_now = core_ev_i.req_fire && (pres_ent.kind == KindCapStore) && !pres_ent.w1;
  assign cap_w1_taken_now = core_ev_i.req_fire && (pres_ent.kind == KindCapStore) && pres_ent.w1 &&
                            !pres_ent.out_of_seq;

  cap_e  cap_d;
  addr_t cap_addr_d;
  logic  match0_d;
  logic  seq_broken_d;
  always_comb begin
    cap_d        = cap_eff;
    cap_addr_d   = cap_addr_q;
    match0_d     = match0_q;
    seq_broken_d = seq_broken_q;
    if (breaks_open_cap) seq_broken_d = 1'b1;
    if (w0_answer_now) begin
      match0_d = xbar_answer_match && !xbar_answer_ent.fault && !xbar_answer_bad_intg;
    end

    // "A W0 taken always opens a capability, and W1's answer closes it."
    if (cap_w0_taken_now) begin
      cap_d        = CapW0;
      cap_addr_d   = pres_ent.addr;
      match0_d     = 1'b0;
      seq_broken_d = 1'b0;
    end else if (cap_w1_taken_now) begin
      cap_d = CapW1;
    end
    if (tag_wr_taken_now) cap_d = CapTagWr;
  end

  //////////////////
  // Fault causes //
  //////////////////

  // [ToO] Error Handling: a capability store word out of sequence, partial, with a bad command or
  // data integrity, or a bad NVM response integrity; any other request out of sequence.
  logic word_cause_now;
  logic out_of_seq_cause_now;
  logic cause_seen_q, cause_seen_d;
  assign word_cause_now       = (alloc && new_ent.fault) ||
                                (xbar_answer_vld && (xbar_answer_ent.kind == KindCapStore) &&
                                 xbar_answer_bad_intg);
  assign out_of_seq_cause_now = alloc && !new_cap_store && new_out_of_seq;
  assign cause_seen_d         = cause_seen_q || word_cause_now || out_of_seq_cause_now;

  ///////////
  // State //
  ///////////

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      ent_q         <= '{'0, '0};
      pres_q        <= 1'b0;
      capture_q     <= CaptureNone;
      capture_tag_q <= 1'b0;
      capture_wr_q  <= 1'b0;
      cap_q         <= CapIdle;
      cap_addr_q    <= '0;
      match0_q      <= 1'b0;
      seq_broken_q  <= 1'b0;
      cause_seen_q  <= 1'b0;
      tag_wr_pend_q       <= 1'b0;
      tag_wr_maybe_pend_q <= 1'b0;
    end else begin
      ent_q         <= ent_d;
      pres_q        <= pres_d;
      capture_q     <= capture_d;
      capture_tag_q <= capture_tag_d;
      capture_wr_q  <= capture_wr_d;
      cap_q         <= cap_d;
      cap_addr_q    <= cap_addr_d;
      match0_q      <= match0_d;
      seq_broken_q  <= seq_broken_d;
      cause_seen_q  <= cause_seen_d;
      tag_wr_pend_q       <= tag_wr_pend_d;
      tag_wr_maybe_pend_q <= tag_wr_maybe_pend_d;
    end
  end

  /////////////
  // Tracker //
  /////////////

  // Follows one core request, chosen by the solver (pick_i), to compare its answer with its
  // xbar answer field by field (tf_forward A3, tf_errors A3).
  typedef enum logic {TrkIdle, TrkOn} trk_e;

  trk_e    trk_q, trk_d;
  idx_t    trk_idx_q, trk_idx_d;
  logic    trk_answered_q, trk_answered_d;
  tl_d2h_t trk_xbar_answer_q, trk_xbar_answer_d;

  // Start on the chosen request's first cycle; its index moves down as the head leaves.
  logic trk_start;
  logic trk_on;
  idx_t trk_idx;
  assign trk_start = (trk_q == TrkIdle) && alloc && pick_i;
  assign trk_on    = (trk_q == TrkOn) || trk_start;
  assign trk_idx   = trk_start ? pres_idx : trk_idx_q;

  // The xbar answer presented now is the tracked request's.
  logic trk_xbar_answer_now;
  assign trk_xbar_answer_now = trk_on && xbar_answer_vld && (xbar_answer_idx == trk_idx);

  logic trk_head;
  logic trk_end;
  assign trk_head = trk_on && (trk_idx == '0);
  assign trk_end  = trk_head && pop;

  logic trk_xbar_answer_fire;
  assign trk_xbar_answer_fire = trk_xbar_answer_now && xbar_ev_i.rsp_fire;

  assign trk_d             = trk_end   ? TrkIdle :
                             trk_start ? TrkOn   :
                                         trk_q;
  assign trk_idx_d         = (pop && (trk_idx != '0)) ? (trk_idx - idx_t'(1)) : trk_idx;
  assign trk_answered_d    = trk_end ? 1'b0 : (trk_answered_q || trk_xbar_answer_fire);
  assign trk_xbar_answer_d = trk_xbar_answer_fire ? xbar_d2h_i : trk_xbar_answer_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      trk_q             <= TrkIdle;
      trk_idx_q         <= '0;
      trk_answered_q    <= 1'b0;
      trk_xbar_answer_q <= '0;
    end else begin
      trk_q             <= trk_d;
      trk_idx_q         <= trk_idx_d;
      trk_answered_q    <= trk_answered_d;
      trk_xbar_answer_q <= trk_xbar_answer_d;
    end
  end

  assign trk_head_o          = trk_head;
  assign trk_xbar_answered_o = trk_answered_q || trk_xbar_answer_now;
  assign trk_xbar_answer_o   = trk_answered_q ? trk_xbar_answer_q : xbar_d2h_i;

  /////////////
  // Outputs //
  /////////////

  assign pres_idx_o             = pres_idx;
  assign pres_o                 = e[pres_idx];
  assign head_vld_o             = head_vld;
  assign head_o                 = e[0];
  assign head_xbar_answered_o   = head_xbar_answered;
  assign head_xbar_err_o        = head_xbar_err;
  assign head_xbar_bad_intg_o   = head_xbar_bad_intg;
  assign head_match_o           = head_match;
  assign head_meta_answered_o   = head_meta_answered;
  assign head_meta_err_o        = head_meta_err;
  assign head_tag_chk_o         = head_tag_chk;
  assign head_tag_o             = head_tag;
  assign head_tag_wr_o          = tag_wr_eff[0];
  assign head_tag_wr_maybe_o    = tag_wr_maybe_eff[0];
  assign capture_o              = capture_q;
  assign capture_tag_o          = capture_tag_q;
  assign capture_wr_o           = capture_wr_q;
  assign pop_o                  = pop;
  assign xbar_answer_vld_o      = xbar_answer_vld;
  assign xbar_answer_ent_o      = xbar_answer_ent;
  assign tag_wr_owed_o          = tag_wr_owed;
  assign tag_wr_maybe_owed_o    = tag_wr_maybe_owed;
  assign tag_wr_addr_o          = tag_wr_addr;
  assign meta_is_tag_wr_o       = meta_is_tag_wr;
  assign cap_state_o            = cap_eff;
  assign cap_addr_o             = cap_addr_q;
  assign word_cause_now_o       = word_cause_now;
  assign out_of_seq_cause_now_o = out_of_seq_cause_now;
  assign cause_seen_o           = cause_seen_d;

endmodule
