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
// cycle, and *_at[i] the same event at entry i; *_so_far the stored value, or this cycle's event
// when there is one; entry the entries as they stand this cycle, with the presented request's
// entry already made.
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
  output idx_t     presented_idx_o,
  output entry_t   presented_o,

  // The oldest entry: its answer is due next on cored_tl_d
  output logic     head_vld_o,
  output entry_t   head_o,
  output logic     head_xbar_answered_o,
  output logic     head_xbar_err_o,
  output logic     head_xbar_bad_intg_o,
  output logic     head_match_o,
  output logic     head_meta_answered_o,
  output logic     head_meta_err_o,
  output logic     head_tag_checked_o,
  output logic     head_tag_o,
  output logic     head_tag_wr_o,
  output logic     head_tag_wr_maybe_o,
  output capture_e capture_o,
  output logic     capture_tag_o,
  output logic     capture_wr_o,
  output logic     pop_o,

  // Xbar answer pairing
  output logic     xbar_answer_vld_o,
  output entry_t   xbar_answer_entry_o,

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

  /////////////
  // Entries //
  /////////////

  // Two entries are kept between cycles; within a cycle a third is the request presented in the
  // cycle the oldest answer is taken (A2).
  entry_t entries_q [2];
  entry_t entries_d [2];

  // A request was presented in the last cycle and not accepted: its entry is already made
  logic presented_q, presented_d;

  // The entries kept, and a request presented for the first time now
  idx_t entry_cnt;
  logic new_req;
  assign entry_cnt = idx_t'(entries_q[0].vld) + idx_t'(entries_q[1].vld);
  assign new_req   = core_ev_i.req_vld && !presented_q;

  // The presented request's entry is the last valid one, or the next free one when it is made.
  idx_t presented_idx;
  assign presented_idx = presented_q ? (entry_cnt - idx_t'(1)) : entry_cnt;

  ///////////////////////////////////
  // The capability store sequence //
  ///////////////////////////////////

  // Where the sequence stands ([ToO] WTRC). The next values are computed at the end of the
  // module, once the events that move them are known.
  cap_e  cap_state_q, cap_state_d;

  // The open capability's address, from its W0
  addr_t cap_addr_q, cap_addr_d;

  // W0 matched the NVM with no fault, so its W1 may set the tag
  logic  w0_matched_q, w0_matched_d;

  // A request out of sequence came while the capability was open
  logic  seq_broken_q, seq_broken_d;

  // In the cycle W1 is answered, a new request already sees the sequence closed ([ToO] WTRC).
  logic stored_head_is_w1;
  logic w1_answered_now;
  cap_e cap_state;
  assign stored_head_is_w1 = entries_q[0].vld && (entries_q[0].kind == KindCapStore) &&
                             entries_q[0].w1 && !entries_q[0].out_of_seq;
  assign w1_answered_now   = core_ev_i.rsp_fire && stored_head_is_w1;
  assign cap_state         = w1_answered_now ? CapIdle : cap_state_q;

  /////////////////////
  // The new request //
  /////////////////////

  // What the presented request is, decoded the way the spec describes it
  kind_e new_kind;
  logic  new_cap_store;
  logic  new_w1;
  logic  new_cap_w0;
  logic  new_same_cap;
  assign new_kind      = req_kind(core_h2d_i, core_tag_i, ena_i);
  assign new_cap_store = new_kind == KindCapStore;
  assign new_w1        = !is_w0(core_h2d_i);
  assign new_cap_w0    = new_cap_store && !new_w1;
  assign new_same_cap  = is_same_cap(core_h2d_i.a_address, cap_addr_q);

  // Out of sequence ([ToO] WTRC), judged against the sequence as the new request sees it.
  logic new_out_of_seq;
  always_comb begin : proc_new_out_of_seq
    new_out_of_seq = 1'b0;
    unique case (cap_state)
      // No capability open: only a W1 is out of sequence.
      CapIdle:  new_out_of_seq = new_cap_store && new_w1;

      // W0 taken: only the W1 of the same capability may follow.
      CapW0:    new_out_of_seq = !(new_cap_store && new_w1 && new_same_cap);

      // W1 taken: nothing may come until W1 is answered.
      CapW1:    new_out_of_seq = 1'b1;

      // W1's tag write sent: any request but a capability store may come.
      CapTagWr: new_out_of_seq = new_cap_store;
    endcase
  end

  // The presented request's entry, made in its first cycle. A capability store word is a fault
  // when it is out of sequence, partial, or has a bad command or data integrity ([ToO] Error
  // Handling).
  entry_t new_entry;
  always_comb begin : proc_new_entry
    new_entry             = '0;
    new_entry.vld         = 1'b1;
    new_entry.kind        = new_kind;
    new_entry.lookup      = is_lookup(core_h2d_i, core_tag_i, ena_i);
    new_entry.w1          = new_w1;
    new_entry.addr        = core_h2d_i.a_address;
    new_entry.src         = core_h2d_i.a_source;
    new_entry.out_of_seq  = new_out_of_seq;
    new_entry.fault       = new_cap_store && (new_out_of_seq || !is_full_put(core_h2d_i) ||
                                              !is_cmd_intg_ok(core_h2d_i) ||
                                              !is_a_data_intg_ok(core_h2d_i));
    new_entry.full_in_seq = is_full_put(core_h2d_i) && !new_out_of_seq;
    new_entry.data        = core_h2d_i.a_data;
    new_entry.data_intg   = core_h2d_i.a_user.data_intg;
  end

  // The entries as they stand this cycle: the kept ones, and the new request's once it is made.
  entry_t entry [NumEnt];
  always_comb begin : proc_entry
    entry[0] = entries_q[0];
    entry[1] = entries_q[1];
    entry[2] = '0;
    if (new_req) entry[presented_idx] = new_entry;
  end

  ////////////////////////////
  // Xbar answers, in order //
  ////////////////////////////

  // A7: xbar_main answers in request order, so a xbar answer belongs to the oldest entry whose
  // xbar request was taken and whose xbar answer was not.
  logic              xbar_sent_now;
  logic [NumEnt-1:0] xbar_sent_at;
  logic [NumEnt-1:0] xbar_sent_so_far;
  logic [NumEnt-1:0] xbar_waiting;
  assign xbar_sent_now = xbar_ev_i.req_fire && core_ev_i.req_vld;
  for (genvar i = 0; i < NumEnt; i++) begin : gen_xbar_waiting
    assign xbar_sent_at[i]     = xbar_sent_now && (presented_idx == idx_t'(i));
    assign xbar_sent_so_far[i] = entry[i].xbar_sent || xbar_sent_at[i];
    assign xbar_waiting[i]     = entry[i].vld && xbar_sent_so_far[i] && !entry[i].xbar_answered;
  end

  // The xbar answer presented now, and the entry it belongs to
  logic              xbar_answer_vld;
  idx_t              xbar_answer_idx;
  logic              xbar_answer_fire;
  logic [NumEnt-1:0] xbar_answer_at;
  assign xbar_answer_vld  = xbar_ev_i.rsp_vld && (xbar_waiting != '0);
  assign xbar_answer_idx  = oldest(xbar_waiting);
  assign xbar_answer_fire = xbar_answer_vld && xbar_ev_i.rsp_fire;
  for (genvar i = 0; i < NumEnt; i++) begin : gen_xbar_answer_at
    assign xbar_answer_at[i] = xbar_answer_fire && (xbar_answer_idx == idx_t'(i));
  end

  entry_t xbar_answer_entry;
  logic   xbar_answer_cap_store;
  logic   xbar_answer_same_data;
  logic   xbar_answer_match;
  logic   xbar_answer_bad_intg;
  assign xbar_answer_entry     = entry[xbar_answer_idx];
  assign xbar_answer_cap_store = xbar_answer_entry.kind == KindCapStore;
  assign xbar_answer_same_data = (xbar_answer_entry.data == xbar_d2h_i.d_data) &&
                                 (xbar_answer_entry.data_intg == xbar_d2h_i.d_user.data_intg);

  // Match(w) = ReadOk and FullPut and InSeq and Data == NvmData and DataIntg == NvmDataIntg.
  assign xbar_answer_match     = !xbar_d2h_i.d_error && xbar_answer_entry.full_in_seq &&
                                 xbar_answer_same_data;
  assign xbar_answer_bad_intg  = !is_rsp_intg_ok(xbar_d2h_i);

  ////////////////////
  // WTRC tag write //
  ////////////////////

  // W1's NVM answer turns into the tag write when W0 and W1 both matched with no fault
  // ([ToO] WTRC table, row W1). After an out-of-sequence request the spec leaves the open
  // capability's tag write open: it may be issued, and is not required (tag_wr_maybe).
  logic xbar_answer_w1;
  logic both_words_matched;
  logic tag_wr_set_now;
  logic tag_wr_maybe_set_now;
  assign xbar_answer_w1       = xbar_answer_cap_store && xbar_answer_entry.w1 &&
                                !xbar_answer_entry.out_of_seq;
  assign both_words_matched   = xbar_answer_w1 && w0_matched_q && xbar_answer_match &&
                                !xbar_answer_entry.fault && !xbar_answer_bad_intg;
  assign tag_wr_set_now       = xbar_answer_vld && both_words_matched && !seq_broken_q;
  assign tag_wr_maybe_set_now = xbar_answer_vld && both_words_matched &&  seq_broken_q;

  // Per entry: the tag write is set now, owed or possible so far, and owed or possible and not
  // yet sent to the meta port
  logic [NumEnt-1:0] tag_wr_set_at;
  logic [NumEnt-1:0] tag_wr_maybe_set_at;
  logic [NumEnt-1:0] tag_wr_so_far;
  logic [NumEnt-1:0] tag_wr_maybe_so_far;
  logic [NumEnt-1:0] entry_owes_tag_wr;
  logic [NumEnt-1:0] entry_may_tag_wr;
  for (genvar i = 0; i < NumEnt; i++) begin : gen_tag_wr
    assign tag_wr_set_at[i]       = tag_wr_set_now       && (xbar_answer_idx == idx_t'(i));
    assign tag_wr_maybe_set_at[i] = tag_wr_maybe_set_now && (xbar_answer_idx == idx_t'(i));
    assign tag_wr_so_far[i]       = entry[i].tag_wr       || tag_wr_set_at[i];
    assign tag_wr_maybe_so_far[i] = entry[i].tag_wr_maybe || tag_wr_maybe_set_at[i];
    assign entry_owes_tag_wr[i]   = entry[i].vld && tag_wr_so_far[i]       && !entry[i].meta_sent;
    assign entry_may_tag_wr[i]    = entry[i].vld && tag_wr_maybe_so_far[i] && !entry[i].meta_sent;
  end

  // Where the open capability's tag lives, and whether the meta request presented now has the
  // tag write's fields
  addr_t    tag_wr_addr;
  bit_sel_t tag_wr_bit;
  logic     meta_is_tag_wr;
  assign tag_wr_addr    = tag_word(cap_addr_q);
  assign tag_wr_bit     = tag_bit(cap_addr_q);
  assign meta_is_tag_wr = (m_h2d_i.a_opcode != Get) && m_tag_i &&
                          (m_h2d_i.a_address == tag_wr_addr) && (m_bit_sel_i == tag_wr_bit);

  // An owed tag write outlives its entry. The core's answer to W1 retires the entry, and the tag
  // write may leave the meta port a cycle later, so the obligation is held in a register of its
  // own and cleared when the tag write is sent. Without it the tag write is read as the next
  // request's lookup, and every tf_lookup and tf_meta_request check fires at once.
  logic tag_wr_pend_q, tag_wr_pend_d;
  logic tag_wr_maybe_pend_q, tag_wr_maybe_pend_d;

  logic tag_wr_owed;
  logic tag_wr_maybe_owed;
  assign tag_wr_owed       = (entry_owes_tag_wr != '0) || tag_wr_pend_q;
  assign tag_wr_maybe_owed = (entry_may_tag_wr  != '0) || tag_wr_maybe_pend_q;

  // The meta port takes an owed tag write first ([ToO] WTRC: "ahead of any lookup"), else the
  // presented request's lookup.
  logic meta_req_is_tag_wr;
  logic tag_wr_sent;
  assign meta_req_is_tag_wr  = tag_wr_owed || (tag_wr_maybe_owed && meta_is_tag_wr);
  assign tag_wr_sent         = m_ev_i.req_fire && meta_req_is_tag_wr;
  assign tag_wr_pend_d       = (tag_wr_pend_q       || tag_wr_set_now)       && !tag_wr_sent;
  assign tag_wr_maybe_pend_d = (tag_wr_maybe_pend_q || tag_wr_maybe_set_now) && !tag_wr_sent;

  always_ff @(posedge clk_i or negedge rst_ni) begin : proc_tag_wr_pend
    if (!rst_ni) begin
      tag_wr_pend_q       <= 1'b0;
      tag_wr_maybe_pend_q <= 1'b0;
    end else begin
      tag_wr_pend_q       <= tag_wr_pend_d;
      tag_wr_maybe_pend_q <= tag_wr_maybe_pend_d;
    end
  end

  ///////////////////////////////
  // Meta requests and answers //
  ///////////////////////////////

  // Per entry: its lookup or tag write is sent now, was sent so far, and waits for its answer
  logic [NumEnt-1:0] meta_sent_now;
  logic [NumEnt-1:0] meta_sent_so_far;
  logic [NumEnt-1:0] meta_waiting;
  for (genvar i = 0; i < NumEnt; i++) begin : gen_meta
    // The presented request's lookup, not yet sent, or this entry's tag write
    logic lookup_due;
    logic tag_wr_due;
    assign lookup_due          = core_ev_i.req_vld && (presented_idx == idx_t'(i)) &&
                                 entry[i].lookup && !entry[i].meta_sent;
    assign tag_wr_due          = entry_owes_tag_wr[i] || entry_may_tag_wr[i];
    assign meta_sent_now[i]    = m_ev_i.req_fire && (meta_req_is_tag_wr ? tag_wr_due : lookup_due);
    assign meta_sent_so_far[i] = entry[i].meta_sent || meta_sent_now[i];
    assign meta_waiting[i]     = entry[i].vld && meta_sent_so_far[i] && !entry[i].meta_answered;
  end

  // Meta answers come back in meta request order; the port takes each one when offered
  // (REQ_TF_14), so an answer arrives when it is presented.
  logic              meta_answer_vld;
  idx_t              meta_answer_idx;
  logic [NumEnt-1:0] meta_answer_at;
  assign meta_answer_vld = m_ev_i.rsp_vld && (meta_waiting != '0);
  assign meta_answer_idx = oldest(meta_waiting);
  for (genvar i = 0; i < NumEnt; i++) begin : gen_meta_answer_at
    assign meta_answer_at[i] = meta_answer_vld && (meta_answer_idx == idx_t'(i));
  end

  //////////////////////
  // The oldest entry //
  //////////////////////

  // The head is a request accepted on cored_tl_d; pop is its answer taken, so it leaves.
  logic head_accepted_now;
  logic head_vld;
  logic pop;
  assign head_accepted_now = core_ev_i.req_fire && (presented_idx == '0);
  assign head_vld          = entry[0].vld && (entry[0].accepted || head_accepted_now);
  assign pop               = core_ev_i.rsp_fire && head_vld;

  // The head's xbar and meta answers: stored, or presented now
  logic head_xbar_answer_now;
  logic head_meta_answer_now;
  assign head_xbar_answer_now = xbar_answer_vld && (xbar_answer_idx == '0);
  assign head_meta_answer_now = meta_answer_vld && (meta_answer_idx == '0);

  logic head_xbar_stored;
  logic head_meta_stored;
  logic head_xbar_answered;
  logic head_xbar_err;
  logic head_xbar_bad_intg;
  logic head_match;
  logic head_meta_answered;
  logic head_meta_err;
  logic head_meta_tag;
  assign head_xbar_stored   = entry[0].xbar_answered;
  assign head_meta_stored   = entry[0].meta_answered;
  assign head_xbar_answered = head_xbar_stored || head_xbar_answer_now;
  assign head_xbar_err      = head_xbar_stored ? entry[0].xbar_err      : xbar_d2h_i.d_error;
  assign head_xbar_bad_intg = head_xbar_stored ? entry[0].xbar_bad_intg : xbar_answer_bad_intg;
  assign head_match         = head_xbar_stored ? entry[0].match         : xbar_answer_match;
  assign head_meta_answered = head_meta_stored || head_meta_answer_now;
  assign head_meta_err      = head_meta_stored ? entry[0].meta_err      : m_d2h_i.d_error;
  assign head_meta_tag      = head_meta_stored ? entry[0].meta_tag      : m_tag_rsp_i;

  ////////////////////////
  // Capture of the tag //
  ////////////////////////

  // The capture of a capability load's tag, between its W0 and its W1 ([ToO] Tag Filter)
  capture_e capture_q, capture_d;
  logic     capture_tag_q, capture_tag_d;

  // A write was answered while the capture was held (REQ_TF_11b).
  logic     capture_wr_q, capture_wr_d;

  // The tag the head's answer must carry ([ToO] Tag Filter; testplan tf_sticky_tag).
  logic head_load_w0;
  logic head_load_w1;
  logic head_tag;
  logic head_tag_checked;
  assign head_load_w0 = entry[0].kind == KindLoadW0;
  assign head_load_w1 = entry[0].kind == KindLoadW1;
  assign head_tag     = head_load_w0 ? head_meta_tag                                 :
                        head_load_w1 ? ((capture_q == CaptureHeld) && capture_tag_q) :
                                       1'b0;

  // An error answer's tag is not checked (REQ_TF_08); the spec leaves CaptureUnknown open.
  assign head_tag_checked = !(head_load_w0 && core_d2h_i.d_error) &&
                            !(head_load_w1 && (capture_q == CaptureUnknown));

  // W0's answer holds its tag for W1, W1's answer clears it, a plain read answered in between
  // makes it unknown, and a write answered in between is remembered.
  always_comb begin : proc_capture
    capture_d     = capture_q;
    capture_tag_d = capture_tag_q;
    capture_wr_d  = capture_wr_q;
    if (pop) begin
      unique case (entry[0].kind)
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

        // A write: plain, or a capability store
        default:    capture_wr_d = capture_wr_q || (capture_q == CaptureHeld);
      endcase
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin : proc_capture_regs
    if (!rst_ni) begin
      capture_q     <= CaptureNone;
      capture_tag_q <= 1'b0;
      capture_wr_q  <= 1'b0;
    end else begin
      capture_q     <= capture_d;
      capture_tag_q <= capture_tag_d;
      capture_wr_q  <= capture_wr_d;
    end
  end

  //////////////////
  // Next entries //
  //////////////////

  // The presented request is accepted now
  logic [NumEnt-1:0] accepted_at;
  for (genvar i = 0; i < NumEnt; i++) begin : gen_accepted_at
    assign accepted_at[i] = core_ev_i.req_fire && (presented_idx == idx_t'(i));
  end

  // Each entry records the events of this cycle; when the head leaves, the others move down.
  always_comb begin : proc_entry_next
    entry_t entry_next [NumEnt];
    entry_next = entry;
    for (int i = 0; i < NumEnt; i++) begin
      if (xbar_sent_at[i])        entry_next[i].xbar_sent    = 1'b1;
      if (xbar_answer_at[i]) begin
        entry_next[i].xbar_answered = 1'b1;
        entry_next[i].xbar_err      = xbar_d2h_i.d_error;
        entry_next[i].xbar_bad_intg = xbar_answer_bad_intg;
        entry_next[i].match         = xbar_answer_match;
      end
      if (tag_wr_set_at[i])       entry_next[i].tag_wr       = 1'b1;
      if (tag_wr_maybe_set_at[i]) entry_next[i].tag_wr_maybe = 1'b1;
      if (meta_sent_now[i])       entry_next[i].meta_sent    = 1'b1;
      if (meta_answer_at[i]) begin
        entry_next[i].meta_answered = 1'b1;
        entry_next[i].meta_err      = m_d2h_i.d_error;
        entry_next[i].meta_tag      = m_tag_rsp_i;
      end
      if (accepted_at[i])         entry_next[i].accepted     = 1'b1;
    end
    entries_d[0] = pop ? entry_next[1] : entry_next[0];
    entries_d[1] = pop ? entry_next[2] : entry_next[1];
  end

  // A request presented now and not accepted keeps its entry in the next cycle.
  assign presented_d = core_ev_i.req_vld && !core_ev_i.req_fire;

  always_ff @(posedge clk_i or negedge rst_ni) begin : proc_entry_regs
    if (!rst_ni) begin
      entries_q   <= '{'0, '0};
      presented_q <= 1'b0;
    end else begin
      entries_q   <= entries_d;
      presented_q <= presented_d;
    end
  end

  ///////////////////////////////////////////////
  // The capability store sequence: next state //
  ///////////////////////////////////////////////

  // The presented request's entry, and the WTRC events of this cycle
  entry_t presented_entry;
  logic   presented_cap_store;
  logic   cap_w0_taken_now;
  logic   cap_w1_taken_now;
  logic   w0_answer_now;
  assign presented_entry     = entry[presented_idx];
  assign presented_cap_store = presented_entry.kind == KindCapStore;
  assign cap_w0_taken_now    = core_ev_i.req_fire && presented_cap_store && !presented_entry.w1;
  assign cap_w1_taken_now    = core_ev_i.req_fire && presented_cap_store && presented_entry.w1 &&
                               !presented_entry.out_of_seq;
  assign w0_answer_now       = xbar_answer_vld && xbar_answer_cap_store && !xbar_answer_entry.w1;

  // Another request out of sequence while a capability is open leaves its tag write open.
  logic breaks_open_cap;
  assign breaks_open_cap = new_req && new_out_of_seq && !new_cap_w0 && (cap_state != CapIdle);

  // A W0 taken opens a capability and its W1 follows. W1's tag write, once sent, waits for W1's
  // answer, which closes the capability (cap_state).
  assign cap_state_d = tag_wr_sent      ? CapTagWr :
                       cap_w0_taken_now ? CapW0    :
                       cap_w1_taken_now ? CapW1    :
                                          cap_state;

  assign cap_addr_d = cap_w0_taken_now ? presented_entry.addr : cap_addr_q;

  // A new W0 starts unmatched; its NVM answer decides the match.
  logic w0_answer_ok;
  assign w0_answer_ok = xbar_answer_match && !xbar_answer_entry.fault && !xbar_answer_bad_intg;
  assign w0_matched_d = cap_w0_taken_now ? 1'b0         :
                        w0_answer_now    ? w0_answer_ok :
                                           w0_matched_q;

  // After a request out of sequence, the open capability's tag write is allowed, not owed. A new
  // W0 starts a clean sequence.
  assign seq_broken_d = cap_w0_taken_now ? 1'b0 :
                        breaks_open_cap  ? 1'b1 :
                                           seq_broken_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin : proc_cap_regs
    if (!rst_ni) begin
      cap_state_q  <= CapIdle;
      cap_addr_q   <= '0;
      w0_matched_q <= 1'b0;
      seq_broken_q <= 1'b0;
    end else begin
      cap_state_q  <= cap_state_d;
      cap_addr_q   <= cap_addr_d;
      w0_matched_q <= w0_matched_d;
      seq_broken_q <= seq_broken_d;
    end
  end

  //////////////////
  // Fault causes //
  //////////////////

  // [ToO] Error Handling: a capability store word out of sequence, partial, with a bad command or
  // data integrity, or a bad NVM response integrity; any other request out of sequence.
  logic word_cause_now;
  logic out_of_seq_cause_now;
  logic cause_seen_q, cause_seen_d;
  assign word_cause_now       = (new_req && new_entry.fault) ||
                                (xbar_answer_vld && xbar_answer_cap_store && xbar_answer_bad_intg);
  assign out_of_seq_cause_now = new_req && !new_cap_store && new_out_of_seq;
  assign cause_seen_d         = cause_seen_q || word_cause_now || out_of_seq_cause_now;

  always_ff @(posedge clk_i or negedge rst_ni) begin : proc_cause_seen
    if (!rst_ni) begin
      cause_seen_q <= 1'b0;
    end else begin
      cause_seen_q <= cause_seen_d;
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
  assign trk_start = (trk_q == TrkIdle) && new_req && pick_i;
  assign trk_on    = (trk_q == TrkOn) || trk_start;
  assign trk_idx   = trk_start ? presented_idx : trk_idx_q;

  // The xbar answer presented now is the tracked request's.
  logic trk_xbar_answer_now;
  logic trk_xbar_answer_fire;
  assign trk_xbar_answer_now  = trk_on && xbar_answer_vld && (xbar_answer_idx == trk_idx);
  assign trk_xbar_answer_fire = trk_xbar_answer_now && xbar_ev_i.rsp_fire;

  // The tracked request is the head, and its answer is taken now
  logic trk_head;
  logic trk_end;
  assign trk_head = trk_on && (trk_idx == '0);
  assign trk_end  = trk_head && pop;

  assign trk_d             = trk_end   ? TrkIdle :
                             trk_start ? TrkOn   :
                                         trk_q;
  assign trk_idx_d         = (pop && (trk_idx != '0)) ? (trk_idx - idx_t'(1)) : trk_idx;
  assign trk_answered_d    = trk_end ? 1'b0 : (trk_answered_q || trk_xbar_answer_fire);
  assign trk_xbar_answer_d = trk_xbar_answer_fire ? xbar_d2h_i : trk_xbar_answer_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin : proc_trk_regs
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

  assign presented_idx_o        = presented_idx;
  assign presented_o            = presented_entry;
  assign head_vld_o             = head_vld;
  assign head_o                 = entry[0];
  assign head_xbar_answered_o   = head_xbar_answered;
  assign head_xbar_err_o        = head_xbar_err;
  assign head_xbar_bad_intg_o   = head_xbar_bad_intg;
  assign head_match_o           = head_match;
  assign head_meta_answered_o   = head_meta_answered;
  assign head_meta_err_o        = head_meta_err;
  assign head_tag_checked_o     = head_tag_checked;
  assign head_tag_o             = head_tag;
  assign head_tag_wr_o          = tag_wr_so_far[0];
  assign head_tag_wr_maybe_o    = tag_wr_maybe_so_far[0];
  assign capture_o              = capture_q;
  assign capture_tag_o          = capture_tag_q;
  assign capture_wr_o           = capture_wr_q;
  assign pop_o                  = pop;
  assign xbar_answer_vld_o      = xbar_answer_vld;
  assign xbar_answer_entry_o    = xbar_answer_entry;
  assign tag_wr_owed_o          = tag_wr_owed;
  assign tag_wr_maybe_owed_o    = tag_wr_maybe_owed;
  assign tag_wr_addr_o          = tag_wr_addr;
  assign meta_is_tag_wr_o       = meta_is_tag_wr;
  assign cap_state_o            = cap_state;
  assign cap_addr_o             = cap_addr_q;
  assign word_cause_now_o       = word_cause_now;
  assign out_of_seq_cause_now_o = out_of_seq_cause_now;
  assign cause_seen_o           = cause_seen_d;

endmodule
