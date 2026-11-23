// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// revchk_engine_model: what the revocation engine must do, from the spec: the sweep a start sets,
//   the status fields it owes, the error causes, the core writes in flight, the reads in flight
//   through the TRVK filter, and one tracked capability per sweep, from its start to its clear.
// Data path: start and register writes, port events -> sweep, causes, core writes, reads in flight,
//   tracked capability (reads, tag, words, lookup, decision, clear, windows) -> the predictions the
//   checker's properties compare.
// Figure: cheriot_mem_sys_fpv_revocation_uarch.adoc, figures/src/revchk_engine_model_omc.svg.
// Obligations: none; revchk_checker's properties compare the ports with these outputs.
// Spec: [ToO] Revocation Engine, Error Handling; checker 3 testplan, Terms.
// Naming: x_d next value, x_q current value; trk the tracked capability; index 0 is W0, 1 is W1;
//   *_now an event of this cycle; *_eff the stored value, or this cycle's event.
module revchk_engine_model
  import tlul_pkg::*;
  import tpchk_pkg::*;
  import revchk_pkg::*;
(
  input  logic     clk_i,
  input  logic     rst_ni,
  // The capability the tracker follows, as an index into the sweep: free in FPV
  input  num_t     k_i,
  // The mode
  input  logic     ena_i,
  // Software, through the register file model: a TBRE_START strobe written 1, and the registers
  input  logic     start_i,
  input  addr_t    base_i,
  input  num_t     num_i,
  // The engine's writes into the register file
  input  logic     regwen_i,
  input  logic     busy_de_i,
  input  logic     busy_d_i,
  input  logic     start_err_set_i,
  input  logic     sweep_err_set_i,
  // cored_tl_d
  input  tl_h2d_t  core_h2d_i,
  input  ev_t      core_ev_i,
  // The engine's read port
  input  tl_h2d_t  rd_h2d_i,
  input  tl_d2h_t  rd_d2h_i,
  input  ev_t      rd_ev_i,
  // The TRVK downstream port
  input  tl_h2d_t  trvk_h2d_i,
  input  tl_d2h_t  trvk_d2h_i,
  input  logic     trvk_tag_rsp_i,
  input  ev_t      trvk_ev_i,
  // The engine's clear port
  input  tl_h2d_t  clr_h2d_i,
  input  tl_d2h_t  clr_d2h_i,
  input  ev_t      clr_ev_i,
  // tbre_tl_h
  input  tl_h2d_t  xbar_h2d_i,
  input  tl_d2h_t  xbar_d2h_i,
  input  ev_t      xbar_ev_i,
  // The bitmap port
  input  tl_h2d_t  bm_h2d_i,
  input  tl_d2h_t  bm_d2h_i,
  input  ev_t      bm_ev_i,
  // Arbiter input 1 (the engine's tag filter's meta port), and the arbiter's output
  input  tl_d2h_t  m1_d2h_i,
  input  ev_t      m1_ev_i,
  input  tl_h2d_t  arb_h2d_i,
  input  bit_sel_t arb_bit_sel_i,
  input  ev_t      arb_ev_i,
  // The RMW filter's fault inputs to the alert, any of them
  input  logic     rmw_fault_i,
  // The sweep
  output logic     active_o,
  output logic     regwen_q_o,
  output logic     regwen_rose_o,
  output logic     regwen_fell_o,
  output logic     taken_start_o,
  output logic     ignored_start_o,
  output logic     taken_start_q_o,
  output addr_t    sweep_base_o,
  output addr_t    sweep_top_o,
  // The status fields
  output logic     busy_o,
  output logic     start_err_owed_o,
  output logic     start_err_due_o,
  output logic     sweep_err_owed_o,
  output logic     sweep_err_due_o,
  // Error causes ([ToO] Error Handling)
  output logic     cause_now_o,
  output logic [4:0] causes_o,
  output logic     alert_cause_now_o,
  output logic     alert_cause_seen_o,
  output logic     sweep_failed_o,
  // Reads in flight through the TRVK filter (D42)
  output logic     lookup_new_o,
  output logic     held_unlooked_o,
  output logic     held_one_o,
  output logic     inflight_fits_o,
  // Core writes in flight
  output logic     core_two_out_o,
  // The tracked capability
  output trk_e     trk_phase_o,
  output logic     trk_on_o,
  output addr_t    trk_o,
  output logic     trk_words_taken_o,
  output logic     trk_words_ans_o,
  output word_t    trk_w0_o,
  output word_t    trk_w1_o,
  output logic     trk_tag_o,
  output logic     trk_in_window_o,
  output logic     trk_w1_departs_o,
  output logic     trk_needs_lookup_o,
  output logic     trk_lookup_match_o,
  output logic     trk_lk_ans_now_o,
  output logic     trk_rev_set_o,
  output logic     trk_lk_fail_o,
  output addr_t    trk_base_o,
  output logic     trk_read_err_o,
  output logic     trk_words_bad_o,
  output logic     trk_decided_o,
  output logic     trk_revoked_o,
  output logic     trk_clear_due_o,
  output logic     trk_clr_new_o,
  output logic     trk_clr_seen_o,
  output logic     trk_watch_start_o,
  output logic     trk_in_watch_o,
  output logic     trk_touch_o,
  output logic     trk_watch_touched_o,
  output logic     trk_stale_touched_o,
  output logic     trk_arrive_o,
  output logic     trk_arrived_o,
  output logic     trk_resolved_o
);

  ///////////
  // Sweep //
  ///////////

  // [ToO]: active "from the cycle after a taken start until every capability of the sweep is
  // resolved", while TBRE_REGWEN is low.
  logic active;
  assign active = !regwen_i;

  // TBRE_REGWEN resets to 1 ([REGS]).
  logic regwen_q;
  logic regwen_rose;
  logic regwen_fell;
  assign regwen_rose = regwen_i && !regwen_q;
  assign regwen_fell = !regwen_i && regwen_q;

  // TakenStart and IgnoredStart: a write of 1 to TBRE_START while TBRE_REGWEN is 1.
  logic start_ok;
  logic taken_start;
  logic ignored_start;
  assign start_ok      = is_taken_start(ena_i, base_i, num_i);
  assign taken_start   = start_i && regwen_i && start_ok;
  assign ignored_start = start_i && regwen_i && !start_ok;

  logic taken_start_q;

  // BASE and N of the sweep, fixed at its taken start.
  addr_t base_q, base_d;
  num_t  n_q, n_d;
  assign base_d = taken_start ? base_i                     : base_q;
  assign n_d    = taken_start ? sweep_caps(base_i, num_i) : n_q;

  // The swept range ends at BASE + 8N, at most RTop(BASE).
  addr_t sweep_top;
  assign sweep_top = base_q + addr_t'({n_q, 3'b000});

  ///////////////////
  // Status fields //
  ///////////////////

  // The busy field holds what the engine last wrote into it (contract C20); 0 after reset.
  logic busy_q, busy_d;
  assign busy_d = busy_de_i ? busy_d_i : busy_q;

  // tbre_start's error only after ignored start: a start_err set request needs an ignored start
  // not yet followed by one; a set request in the start's own cycle counts. Its error set next
  // cycle: one is due by the cycle after the start.
  logic start_err_owed_q, start_err_owed_d;
  logic start_err_due_q, start_err_due_d;
  assign start_err_owed_d = ignored_start ? (start_err_owed_q || !start_err_set_i) :
                                            (start_err_owed_q && !start_err_set_i);
  assign start_err_due_d  = ignored_start && !start_err_set_i;

  //////////////////
  // Error causes //
  //////////////////

  // [ToO] Error Handling, the engine's rows. An answer counts in the cycle it is taken.
  logic xbar_ans_err;    // d_error on an answer on tbre_tl_h (REQ_TBRE_32b)
  logic xbar_ans_fault;  // broken integrity or (V3) malformed, on tbre_tl_h (REQ_TBRE_33a)
  logic meta_ans_err;    // d_error on a meta answer to the engine's tag filter (REQ_TBRE_33a)
  logic bm_ans_fail;     // a failed bitmap lookup (REQ_TBRE_34b)
  logic rmw_fault_on;    // an RMW filter fault input while active (REQ_TBRE_35a)
  assign xbar_ans_err   = xbar_ev_i.rsp_fire && xbar_d2h_i.d_error;
  assign xbar_ans_fault = xbar_ev_i.rsp_fire &&
                          (!is_intg_ok(xbar_d2h_i) || is_malformed_read(xbar_d2h_i));
  assign meta_ans_err   = m1_ev_i.rsp_fire && m1_d2h_i.d_error;
  assign bm_ans_fail    = bm_ev_i.rsp_fire && is_failed_read(bm_d2h_i);
  assign rmw_fault_on   = rmw_fault_i && active;

  logic cause_now;
  logic alert_cause_now;
  assign cause_now       = xbar_ans_err || xbar_ans_fault || meta_ans_err || bm_ans_fail ||
                           rmw_fault_on;
  // The causes of the engine's own fault inputs; an RMW filter fault is its own input.
  assign alert_cause_now = xbar_ans_fault || bm_ans_fail;

  // tbre_errors' error only for a cause and error set next cycle: the same credit and due flag as
  // start_err's.
  logic sweep_err_owed_q, sweep_err_owed_d;
  logic sweep_err_due_q, sweep_err_due_d;
  assign sweep_err_owed_d = cause_now ? (sweep_err_owed_q || !sweep_err_set_i) :
                                        (sweep_err_owed_q && !sweep_err_set_i);
  assign sweep_err_due_d  = cause_now && !sweep_err_set_i;

  // tbre_epoch's steps unless error: a cause from the taken start until the cycle active falls,
  // that cycle included.
  logic sweep_err_seen_q, sweep_err_seen_d;
  logic sweep_failed;
  assign sweep_err_seen_d = taken_start ? cause_now : (sweep_err_seen_q || cause_now);
  assign sweep_failed     = sweep_err_seen_q || cause_now;

  // Contract C9: an engine cause of the alert since reset, this cycle included.
  logic alert_cause_seen_q, alert_cause_seen_d;
  assign alert_cause_seen_d = alert_cause_seen_q || alert_cause_now;

  /////////////////////////
  // Core writes watched //
  /////////////////////////

  // [ToO]: "every write the core presents on cored_tl_d, and every write it accepted there until
  // the write is answered". Up to two accepted requests (assumption A2); answers come in request
  // order (contract C6), so an answer frees the oldest. A write in its answer's cycle still counts.
  typedef struct packed {
    logic        vld;
    logic        wr;
    logic [28:0] cap;  // a_address bits 31:3: the capability
  } core_req_t;

  core_req_t core_q [2], core_d [2];
  always_comb begin
    core_req_t n [3];
    n[0] = core_q[0];
    n[1] = core_q[1];
    n[2] = '0;
    if (core_ev_i.req_fire) begin
      if (!n[0].vld) begin
        n[0] = '{vld: 1'b1, wr: is_wr(core_h2d_i), cap: core_h2d_i.a_address[31:3]};
      end else if (!n[1].vld) begin
        n[1] = '{vld: 1'b1, wr: is_wr(core_h2d_i), cap: core_h2d_i.a_address[31:3]};
      end else begin
        n[2] = '{vld: 1'b1, wr: is_wr(core_h2d_i), cap: core_h2d_i.a_address[31:3]};
      end
    end
    core_d[0] = core_ev_i.rsp_fire ? n[1] : n[0];
    core_d[1] = core_ev_i.rsp_fire ? n[2] : n[1];
  end

  /////////////////////
  // Reads in flight //
  /////////////////////

  // Every read between the engine's read port and the TRVK downstream port, by word: its source on
  // each port, whether its answer reached the TRVK filter, whether a lookup was made while the TRVK
  // filter held it (D42). The two ports may take a read in either order. "Up to two words are in
  // flight, each read with a source ID of its own" ([ToO]).
  typedef struct packed {
    logic        vld;
    logic [29:0] word;        // a_address bits 31:2; bit 0 set for a W1
    logic        rd_taken;
    src_t        rd_src;
    logic        trvk_taken;
    src_t        trvk_src;
    logic        arrived;     // its answer reached the TRVK filter
    logic        looked_up;   // a lookup was presented while the TRVK filter held it
  } flight_t;

  // The place for word w: its entry, else the first free one, else 2.
  function automatic logic [1:0] place_of(flight_t f [2], logic [29:0] w);
    return (f[0].vld && (f[0].word == w)) ? 2'd0 :
           (f[1].vld && (f[1].word == w)) ? 2'd1 :
           !f[0].vld                      ? 2'd0 :
           !f[1].vld                      ? 2'd1 :
                                            2'd2;
  endfunction

  // A lookup is new in its first cycle presented.
  logic bm_waits_q, bm_waits_d;
  logic lookup_new;
  assign bm_waits_d = bm_ev_i.req_vld && !bm_ev_i.req_fire;
  assign lookup_new = bm_ev_i.req_vld && !bm_waits_q;

  flight_t    fl_q [2], fl_d [2];
  logic       held_unlooked;  // the TRVK filter holds a W1 answer that has had no lookup yet
  logic [1:0] held_cnt;       // the W1 answers it holds
  logic       fl_fits;        // every read taken found its place
  always_comb begin
    flight_t    n [2];
    logic [1:0] p;
    logic       done;
    n       = fl_q;
    fl_fits = 1'b1;
    p       = '0;
    // Reads taken: on the read port, then on the TRVK downstream port (one entry per word).
    if (rd_ev_i.req_fire) begin
      p = place_of(n, rd_h2d_i.a_address[31:2]);
      if (p == 2'd2) begin
        fl_fits = 1'b0;
      end else begin
        n[p[0]].vld      = 1'b1;
        n[p[0]].word     = rd_h2d_i.a_address[31:2];
        n[p[0]].rd_taken = 1'b1;
        n[p[0]].rd_src   = rd_h2d_i.a_source;
      end
    end
    if (trvk_ev_i.req_fire) begin
      p = place_of(n, trvk_h2d_i.a_address[31:2]);
      if (p == 2'd2) begin
        fl_fits = 1'b0;
      end else begin
        n[p[0]].vld        = 1'b1;
        n[p[0]].word       = trvk_h2d_i.a_address[31:2];
        n[p[0]].trvk_taken = 1'b1;
        n[p[0]].trvk_src   = trvk_h2d_i.a_source;
      end
    end
    // Answers reaching the TRVK filter.
    for (int i = 0; i < 2; i++) begin
      if (trvk_ev_i.rsp_fire && fl_q[i].trvk_taken &&
          (fl_q[i].trvk_src == trvk_d2h_i.d_source)) begin
        n[i].arrived = 1'b1;
      end
    end
    // W1 answers held, before this cycle's departures: the departure cycle is in the window.
    held_unlooked = 1'b0;
    held_cnt      = '0;
    for (int i = 0; i < 2; i++) begin
      if (n[i].vld && n[i].word[0] && n[i].arrived) begin
        held_cnt      = held_cnt + 2'd1;
        held_unlooked = held_unlooked || !n[i].looked_up;
      end
    end
    // A new lookup belongs to the first held W1 answer without one.
    done = 1'b0;
    for (int i = 0; i < 2; i++) begin
      if (lookup_new && !done && n[i].vld && n[i].word[0] && n[i].arrived &&
          !n[i].looked_up) begin
        n[i].looked_up = 1'b1;
        done           = 1'b1;
      end
    end
    // Answers leaving on the read port free their entry.
    for (int i = 0; i < 2; i++) begin
      if (rd_ev_i.rsp_fire && fl_q[i].rd_taken && (fl_q[i].rd_src == rd_d2h_i.d_source)) begin
        n[i] = '0;
      end
    end
    fl_d = n;
  end

  ///////////////////////////////
  // Tracked capability: start //
  ///////////////////////////////

  // At each taken start the tracker follows BASE + 8k, if k < N; any other k tracks nothing (D44).
  logic        trk_start;
  logic        trk_on_q, trk_on_d;
  logic [28:0] trk_cap_q, trk_cap_d;
  addr_t       trk_new;
  assign trk_new   = base_i + addr_t'({k_i, 3'b000});
  assign trk_start = taken_start && (k_i < sweep_caps(base_i, num_i));
  // The sweep ends when TBRE_REGWEN rises.
  assign trk_on_d  = trk_start                 ? 1'b1  :
                     regwen_rose               ? 1'b0  :
                                                 trk_on_q;
  assign trk_cap_d = trk_start ? trk_new[31:3] : trk_cap_q;

  addr_t trk;
  assign trk = {trk_cap_q, 3'b000};

  // Word i of trk: a_address bits 31:2 are {trk, i}.
  function automatic logic is_trk_word(addr_t a, logic [28:0] cap, logic i);
    return (a[31:3] == cap) && (a[2] == i);
  endfunction

  ///////////////////////////////////////
  // Tracked capability: reads by port //
  ///////////////////////////////////////

  // Per word and per port: the read taken, its source, and its answer taken. A word's answer is
  // matched by source ([ToO]: each read "with a source ID of its own").
  logic [1:0] rd_taken_q, rd_taken_d, rd_ans_q, rd_ans_d;
  logic [1:0] trvk_taken_q, trvk_taken_d, trvk_ans_q, trvk_ans_d;
  logic [1:0] xbar_taken_q, xbar_taken_d, xbar_ans_q, xbar_ans_d;
  src_t       rd_src_q [2], rd_src_d [2];
  src_t       trvk_src_q [2], trvk_src_d [2];
  src_t       xbar_src_q [2], xbar_src_d [2];

  logic [1:0] rd_ans_now;    // word i's answer leaves on the read port now
  logic [1:0] trvk_ans_now;  // word i's answer reaches the TRVK filter now
  logic [1:0] xbar_ans_now;  // word i's answer is taken on tbre_tl_h now
  for (genvar i = 0; i < 2; i++) begin : gen_trk_port
    logic rd_req;
    logic trvk_req;
    logic xbar_req;
    assign rd_req   = trk_on_q && rd_ev_i.req_fire &&
                      is_trk_word(rd_h2d_i.a_address, trk_cap_q, 1'(i));
    assign trvk_req = trk_on_q && trvk_ev_i.req_fire &&
                      is_trk_word(trvk_h2d_i.a_address, trk_cap_q, 1'(i));
    assign xbar_req = trk_on_q && xbar_ev_i.req_fire && is_full_get(xbar_h2d_i) &&
                      is_trk_word(xbar_h2d_i.a_address, trk_cap_q, 1'(i));

    assign rd_ans_now[i]   = rd_ev_i.rsp_fire && rd_taken_q[i] && !rd_ans_q[i] &&
                             (rd_d2h_i.d_source == rd_src_q[i]);
    assign trvk_ans_now[i] = trvk_ev_i.rsp_fire && trvk_taken_q[i] && !trvk_ans_q[i] &&
                             (trvk_d2h_i.d_source == trvk_src_q[i]);
    assign xbar_ans_now[i] = xbar_ev_i.rsp_fire && xbar_taken_q[i] && !xbar_ans_q[i] &&
                             (xbar_d2h_i.d_source == xbar_src_q[i]);

    // The first read of each word counts.
    assign rd_taken_d[i]   = trk_start ? 1'b0 : (rd_taken_q[i] || rd_req);
    assign trvk_taken_d[i] = trk_start ? 1'b0 : (trvk_taken_q[i] || trvk_req);
    assign xbar_taken_d[i] = trk_start ? 1'b0 : (xbar_taken_q[i] || xbar_req);
    assign rd_src_d[i]     = (rd_req && !rd_taken_q[i])     ? rd_h2d_i.a_source   : rd_src_q[i];
    assign trvk_src_d[i]   = (trvk_req && !trvk_taken_q[i]) ? trvk_h2d_i.a_source : trvk_src_q[i];
    assign xbar_src_d[i]   = (xbar_req && !xbar_taken_q[i]) ? xbar_h2d_i.a_source : xbar_src_q[i];
    assign rd_ans_d[i]     = trk_start ? 1'b0 : (rd_ans_q[i] || rd_ans_now[i]);
    assign trvk_ans_d[i]   = trk_start ? 1'b0 : (trvk_ans_q[i] || trvk_ans_now[i]);
    assign xbar_ans_d[i]   = trk_start ? 1'b0 : (xbar_ans_q[i] || xbar_ans_now[i]);
  end

  ///////////////////////////////////////////
  // Tracked capability: its tag and words //
  ///////////////////////////////////////////

  // The words as tbre_tl_h answered them, with d_error and whether the answer was faulty.
  word_t      data_q [2], data_d [2];
  logic [1:0] err_q, err_d, bad_q, bad_d;
  word_t      data [2];
  logic [1:0] err;
  logic [1:0] bad;
  for (genvar i = 0; i < 2; i++) begin : gen_trk_word
    assign data[i]   = xbar_ans_now[i] ? xbar_d2h_i.d_data : data_q[i];
    assign err[i]    = xbar_ans_now[i] ? xbar_d2h_i.d_error : err_q[i];
    assign bad[i]    = xbar_ans_now[i] ? !is_intg_ok(xbar_d2h_i) || is_malformed_read(xbar_d2h_i) :
                                         bad_q[i];
    assign data_d[i] = data[i];
    assign err_d[i]  = trk_start ? 1'b0 : err[i];
    assign bad_d[i]  = trk_start ? 1'b0 : bad[i];
  end

  // Tag(trk): the tag the engine's tag filter returns with W0's answer, at the TRVK filter.
  logic tag_q, tag_d;
  logic tag;
  assign tag   = trvk_ans_now[0] ? trvk_tag_rsp_i : tag_q;
  assign tag_d = trk_start ? 1'b0 : tag;

  logic  words_ans;  // both words answered on tbre_tl_h
  logic  read_err;   // REQ_TBRE_32a: either word answered with d_error
  logic  words_bad;  // either word's answer had a broken integrity or was malformed: no rule
  addr_t trk_base;
  logic  needs_lookup;
  assign words_ans    = (xbar_ans_q[0] || xbar_ans_now[0]) && (xbar_ans_q[1] || xbar_ans_now[1]);
  assign read_err     = err[0] || err[1];
  assign words_bad    = bad[0] || bad[1];
  assign trk_base     = cap_base(data[0], data[1]);
  // REQ_TBRE_17: a lookup is needed for a tagged, non-sealing capability with a revocable base.
  assign needs_lookup = words_ans && !read_err && !words_bad && tag && !is_sealing(data[1]) &&
                        is_revocable(trk_base);

  ////////////////////////////////////
  // Tracked capability: the lookup //
  ////////////////////////////////////

  // The lookup window: from W1's answer reaching the TRVK filter to its leaving on the read port,
  // both cycles included (D42, Q41).
  logic in_window;
  logic w1_departs;
  assign in_window  = (trvk_ans_q[1] || trvk_ans_now[1]) && !rd_ans_q[1];
  assign w1_departs = rd_ans_now[1];

  // tbre_decision's lookup when needed: a full-word Get of the revocation word of the tracked
  // capability's base, presented in the window.
  logic lookup_match_q, lookup_match_d;
  logic lookup_match_now;
  logic lookup_match;
  assign lookup_match_now = trk_on_q && words_ans && lookup_new && in_window &&
                            is_full_get(bm_h2d_i) && (bm_h2d_i.a_address == rev_word(trk_base));
  assign lookup_match     = lookup_match_q || lookup_match_now;
  assign lookup_match_d   = trk_start ? 1'b0 : lookup_match;

  // Its answer, matched by the source the matching lookup was taken with.
  logic lk_taken_q, lk_taken_d, lk_ans_q, lk_ans_d, rev_set_q, rev_set_d, lk_fail_q, lk_fail_d;
  src_t lk_src_q, lk_src_d;
  logic lk_req;
  logic lk_ans_now;
  assign lk_req     = lookup_match && !lk_taken_q && bm_ev_i.req_fire &&
                      (bm_h2d_i.a_address == rev_word(trk_base));
  assign lk_ans_now = bm_ev_i.rsp_fire && lk_taken_q && !lk_ans_q &&
                      (bm_d2h_i.d_source == lk_src_q);
  assign lk_taken_d = trk_start ? 1'b0 : (lk_taken_q || lk_req);
  assign lk_src_d   = lk_req ? bm_h2d_i.a_source : lk_src_q;
  assign lk_ans_d   = trk_start ? 1'b0 : (lk_ans_q || lk_ans_now);

  // RevSet(trk) and LookupFail(trk).
  logic rev_set;
  logic lk_fail;
  assign rev_set   = lk_ans_now ? bit_of(bm_d2h_i.d_data, rev_bit(trk_base)) : rev_set_q;
  assign lk_fail   = lk_ans_now ? is_failed_read(bm_d2h_i)                    : lk_fail_q;
  assign rev_set_d = trk_start ? 1'b0 : rev_set;
  assign lk_fail_d = trk_start ? 1'b0 : lk_fail;

  //////////////////////////////////////
  // Tracked capability: the decision //
  //////////////////////////////////////

  // Revoked(trk) = Tag and not Sealing and Revocable(Base) and (RevSet or LookupFail), for a
  // capability read without error ([TP] Revoked).
  logic decided;
  logic revoked;
  assign decided = rd_ans_q[1] || w1_departs;
  assign revoked = words_ans && !read_err && tag && !is_sealing(data[1]) &&
                   is_revocable(trk_base) && (rev_set || lk_fail);

  ///////////////////////////////////////////////
  // Tracked capability: the clear and windows //
  ///////////////////////////////////////////////

  // The core writes that touch trk now: Touch(w, trk).
  logic touch;
  logic touch_pres;
  logic touch_out;
  assign touch_pres = core_ev_i.req_vld && is_wr(core_h2d_i) &&
                      (core_h2d_i.a_address[31:3] == trk_cap_q);
  assign touch_out  = (core_q[0].vld && core_q[0].wr && (core_q[0].cap == trk_cap_q)) ||
                      (core_q[1].vld && core_q[1].wr && (core_q[1].cap == trk_cap_q));
  assign touch      = trk_on_q && (touch_pres || touch_out);

  // The clear of trk: a request in its 8 bytes on the engine's clear port, in its first cycle.
  logic clr_seen_q, clr_seen_d;
  logic clr_new;
  assign clr_new    = trk_on_q && clr_ev_i.req_vld && !clr_seen_q &&
                      (clr_h2d_i.a_address[31:3] == trk_cap_q);
  assign clr_seen_d = trk_start ? 1'b0 : (clr_seen_q || clr_new);

  // Watch(trk): from W0's read presented on the read port until the cycle before the clear.
  logic watch_on_q, watch_on_d;
  logic watch_now;
  logic watch_touched_q, watch_touched_d;
  assign watch_now       = watch_on_q || (trk_on_q && rd_ev_i.req_vld &&
                                          is_trk_word(rd_h2d_i.a_address, trk_cap_q, 1'b0));
  assign watch_on_d      = trk_start ? 1'b0 : watch_now;
  assign watch_touched_d = trk_start ? 1'b0 :
                           (watch_touched_q || (touch && watch_now && !clr_seen_q && !clr_new));

  // The clear reaches the RMW filter: the arbiter forwards input 1's write to TagWord(trk),
  // TagBit(trk) (Fwd(r, 1): a_source bit 0 is 1).
  logic arrived_q, arrived_d;
  logic arrive_now;
  assign arrive_now = (clr_seen_q || clr_new) && !arrived_q && arb_ev_i.req_vld &&
                      arb_h2d_i.a_source[0] && is_wr(arb_h2d_i) &&
                      (arb_h2d_i.a_address == tag_word(trk)) && (arb_bit_sel_i == tag_bit(trk));
  assign arrived_d  = trk_start ? 1'b0 : (arrived_q || arrive_now);

  // Stale(trk): from the clear presented until the cycle before it reaches the RMW filter (D43).
  logic stale_touched_q, stale_touched_d;
  assign stale_touched_d = trk_start ? 1'b0 :
                           (stale_touched_q ||
                            (touch && (clr_seen_q || clr_new) && !arrived_q && !arrive_now));

  // The clear's answer at the clear port, by the source it was taken with.
  logic clr_taken_q, clr_taken_d, clr_ans_q, clr_ans_d;
  src_t clr_src_q, clr_src_d;
  logic clr_req;
  logic clr_ans_now;
  assign clr_req     = (clr_seen_q || clr_new) && !clr_taken_q && clr_ev_i.req_fire &&
                       (clr_h2d_i.a_address[31:3] == trk_cap_q);
  assign clr_ans_now = clr_ev_i.rsp_fire && clr_taken_q && !clr_ans_q &&
                       (clr_d2h_i.d_source == clr_src_q);
  assign clr_taken_d = trk_start ? 1'b0 : (clr_taken_q || clr_req);
  assign clr_src_d   = clr_req ? clr_h2d_i.a_source : clr_src_q;
  assign clr_ans_d   = trk_start ? 1'b0 : (clr_ans_q || clr_ans_now);

  // A clear is due for a revoked capability read without a faulty answer and not touched in Watch.
  logic clear_due;
  assign clear_due = revoked && !words_bad && !watch_touched_q;

  // Resolved(trk) (proposed, Q16): both words answered on the read port, and its clear answered
  // if one was presented or is due.
  logic resolved;
  assign resolved = (rd_ans_q[0] || rd_ans_now[0]) && decided &&
                    ((clr_seen_q || clr_new) ? (clr_ans_q || clr_ans_now) : !clear_due);

  // The phase, derived from what has happened.
  trk_e phase;
  assign phase = !trk_on_q                 ? TrkIdle     :
                 resolved                  ? TrkResolved :
                 (clr_seen_q || clr_new)   ? TrkClear    :
                 decided                   ? TrkDecided  :
                 in_window                 ? TrkLookup   :
                                             TrkRead;

  ///////////
  // State //
  ///////////

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      regwen_q           <= 1'b1;
      taken_start_q      <= 1'b0;
      base_q             <= '0;
      n_q                <= '0;
      busy_q             <= 1'b0;
      start_err_owed_q   <= 1'b0;
      start_err_due_q    <= 1'b0;
      sweep_err_owed_q   <= 1'b0;
      sweep_err_due_q    <= 1'b0;
      sweep_err_seen_q   <= 1'b0;
      alert_cause_seen_q <= 1'b0;
      core_q             <= '{'0, '0};
      bm_waits_q         <= 1'b0;
      fl_q               <= '{'0, '0};
      trk_on_q           <= 1'b0;
      trk_cap_q          <= '0;
      rd_taken_q         <= '0;
      trvk_taken_q       <= '0;
      xbar_taken_q       <= '0;
      rd_ans_q           <= '0;
      trvk_ans_q         <= '0;
      xbar_ans_q         <= '0;
      rd_src_q           <= '{'0, '0};
      trvk_src_q         <= '{'0, '0};
      xbar_src_q         <= '{'0, '0};
      data_q             <= '{'0, '0};
      err_q              <= '0;
      bad_q              <= '0;
      tag_q              <= 1'b0;
      lookup_match_q     <= 1'b0;
      lk_taken_q         <= 1'b0;
      lk_src_q           <= '0;
      lk_ans_q           <= 1'b0;
      rev_set_q          <= 1'b0;
      lk_fail_q          <= 1'b0;
      clr_seen_q         <= 1'b0;
      watch_on_q         <= 1'b0;
      watch_touched_q    <= 1'b0;
      arrived_q          <= 1'b0;
      stale_touched_q    <= 1'b0;
      clr_taken_q        <= 1'b0;
      clr_src_q          <= '0;
      clr_ans_q          <= 1'b0;
    end else begin
      regwen_q           <= regwen_i;
      taken_start_q      <= taken_start;
      base_q             <= base_d;
      n_q                <= n_d;
      busy_q             <= busy_d;
      start_err_owed_q   <= start_err_owed_d;
      start_err_due_q    <= start_err_due_d;
      sweep_err_owed_q   <= sweep_err_owed_d;
      sweep_err_due_q    <= sweep_err_due_d;
      sweep_err_seen_q   <= sweep_err_seen_d;
      alert_cause_seen_q <= alert_cause_seen_d;
      core_q             <= core_d;
      bm_waits_q         <= bm_waits_d;
      fl_q               <= fl_d;
      trk_on_q           <= trk_on_d;
      trk_cap_q          <= trk_cap_d;
      rd_taken_q         <= rd_taken_d;
      trvk_taken_q       <= trvk_taken_d;
      xbar_taken_q       <= xbar_taken_d;
      rd_ans_q           <= rd_ans_d;
      trvk_ans_q         <= trvk_ans_d;
      xbar_ans_q         <= xbar_ans_d;
      rd_src_q           <= rd_src_d;
      trvk_src_q         <= trvk_src_d;
      xbar_src_q         <= xbar_src_d;
      data_q             <= data_d;
      err_q              <= err_d;
      bad_q              <= bad_d;
      tag_q              <= tag_d;
      lookup_match_q     <= lookup_match_d;
      lk_taken_q         <= lk_taken_d;
      lk_src_q           <= lk_src_d;
      lk_ans_q           <= lk_ans_d;
      rev_set_q          <= rev_set_d;
      lk_fail_q          <= lk_fail_d;
      clr_seen_q         <= clr_seen_d;
      watch_on_q         <= watch_on_d;
      watch_touched_q    <= watch_touched_d;
      arrived_q          <= arrived_d;
      stale_touched_q    <= stale_touched_d;
      clr_taken_q        <= clr_taken_d;
      clr_src_q          <= clr_src_d;
      clr_ans_q          <= clr_ans_d;
    end
  end

  /////////////
  // Outputs //
  /////////////

  assign active_o            = active;
  assign regwen_q_o          = regwen_q;
  assign regwen_rose_o       = regwen_rose;
  assign regwen_fell_o       = regwen_fell;
  assign taken_start_o       = taken_start;
  assign ignored_start_o     = ignored_start;
  assign taken_start_q_o     = taken_start_q;
  assign sweep_base_o        = base_q;
  assign sweep_top_o         = sweep_top;
  assign busy_o              = busy_q;
  assign start_err_owed_o    = start_err_owed_q;
  assign start_err_due_o     = start_err_due_q;
  assign sweep_err_owed_o    = sweep_err_owed_q;
  assign sweep_err_due_o     = sweep_err_due_q;
  assign cause_now_o         = cause_now;
  assign causes_o            = {xbar_ans_err, xbar_ans_fault, meta_ans_err, bm_ans_fail,
                                rmw_fault_on};
  assign alert_cause_now_o   = alert_cause_now;
  assign alert_cause_seen_o  = alert_cause_seen_d;
  assign sweep_failed_o      = sweep_failed;
  assign lookup_new_o        = lookup_new;
  assign held_unlooked_o     = held_unlooked;
  assign held_one_o          = held_cnt == 2'd1;
  assign inflight_fits_o     = fl_fits;
  assign core_two_out_o      = core_q[0].vld && core_q[1].vld;
  assign trk_phase_o         = phase;
  assign trk_on_o            = trk_on_q;
  assign trk_o               = trk;
  assign trk_words_taken_o   = xbar_taken_q[0] && xbar_taken_q[1];
  assign trk_words_ans_o     = words_ans;
  assign trk_w0_o            = data[0];
  assign trk_w1_o            = data[1];
  assign trk_tag_o           = tag;
  assign trk_in_window_o     = trk_on_q && in_window;
  assign trk_w1_departs_o    = trk_on_q && w1_departs;
  assign trk_needs_lookup_o  = needs_lookup;
  assign trk_lookup_match_o  = lookup_match;
  assign trk_lk_ans_now_o    = trk_on_q && lk_ans_now;
  assign trk_rev_set_o       = rev_set;
  assign trk_lk_fail_o       = lk_fail;
  assign trk_base_o          = trk_base;
  assign trk_read_err_o      = read_err;
  assign trk_words_bad_o     = words_bad;
  assign trk_decided_o       = decided;
  assign trk_revoked_o       = revoked;
  assign trk_clear_due_o     = clear_due;
  assign trk_clr_new_o       = clr_new;
  assign trk_clr_seen_o      = clr_seen_q;
  assign trk_watch_start_o   = watch_now && !watch_on_q;
  assign trk_in_watch_o      = watch_now && !clr_seen_q && !clr_new;
  assign trk_touch_o         = touch;
  assign trk_watch_touched_o = watch_touched_q;
  assign trk_stale_touched_o = stale_touched_q;
  assign trk_arrive_o        = arrive_now;
  assign trk_arrived_o       = arrived_q;
  assign trk_resolved_o      = resolved;

endmodule
