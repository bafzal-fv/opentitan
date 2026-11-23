// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// revchk_checker: checker 3 (revocation engine): every check, and no assumption. The TL-UL rules
//   of the ports the testbench plays sit in revchk_env_rules's ABVIPs; the CheckBoth ABVIPs here
//   assert them on the links between real blocks. Bound into cheriot_mem_sys by
//   revchk_checker_bind, in FPV and in simulation.
// Data path: ports -> port events -> engine model (with the tracker), the engine's tag filter's
//   checker (tfchk_checker, shared with checker 1) -> the properties, one banner section per
//   testpoint: start, status, epoch, interrupt, sweep, done, decision, clear, watch, errors, then
//   contracts, alert causes and environment covers.
// Figure: cheriot_mem_sys_fpv_revocation_uarch.adoc, figures/src/revchk_layers.svg.
// Obligations: every check and cover of the testplan's Checker 3 section, and checker 3's parts of
//   contracts, alert_causes, tlul_protocol and environment (check map in the TB status doc).
// Spec: testplan, Checker 3; TB architecture, Checker 3; checker 3 uarch.
// Naming: ports named after the spec's ports or the block at the other end; <port>_ev a port's
//   events; trk the tracked capability; x_d next value, x_q current value.
module revchk_checker
  import tlul_pkg::*;
  import tlul_abvip_pkg::*;
  import tpchk_pkg::*;
  import revchk_pkg::*;
  import cheriot_mem_sys_reg_pkg::*;
#(
  parameter run_e Run = RunV1  // the run: its formal-only checks
) (
  input  logic                         clk_i,
  input  logic                         rst_ni,
  input  prim_mubi_pkg::mubi4_t        cheriot_ena_i,
  // The register file: its outputs (free, within contract C20), and the engine's writes into it
  input  cheriot_mem_sys_regs_reg2hw_t reg2hw_i,
  input  cheriot_mem_sys_regs_hw2reg_t hw2reg_i,
  // The interrupt
  input  logic                         intr_i,
  // cored_tl_d with its tag sideband
  input  tl_h2d_t                      core_h2d_i,
  input  logic                         core_tag_i,
  input  tl_d2h_t                      core_d2h_i,
  // The engine's read port, in front of its TRVK filter
  input  tl_h2d_t                      rd_h2d_i,
  input  tl_d2h_t                      rd_d2h_i,
  // The TRVK filter's downstream port, with the answers' tag
  input  tl_h2d_t                      trvk_h2d_i,
  input  tl_d2h_t                      trvk_d2h_i,
  input  logic                         trvk_tag_rsp_i,
  // The engine's clear port, in front of its socket
  input  tl_h2d_t                      clr_h2d_i,
  input  tl_d2h_t                      clr_d2h_i,
  // The engine's tag filter's device port, the socket's output
  input  tl_h2d_t                      tf_h2d_i,
  input  logic                         tf_tag_i,
  input  tl_d2h_t                      tf_d2h_i,
  input  logic                         tf_tag_rsp_i,
  // tbre_tl_h, to xbar_main
  input  tl_h2d_t                      xbar_h2d_i,
  input  tl_d2h_t                      xbar_d2h_i,
  // The bitmap port, to the engine's access checker
  input  tl_h2d_t                      bm_h2d_i,
  input  tl_d2h_t                      bm_d2h_i,
  // 2:1 tag arbiter inputs: 0 the core's tag filter, 1 the engine's
  input  tl_h2d_t                      m_h2d_i [2],
  input  logic                         m_tag_i [2],
  input  bit_sel_t                     m_bit_sel_i [2],
  input  tl_d2h_t                      m_d2h_i [2],
  input  logic                         m_tag_rsp_i [2],
  // Arbiter output, before the tag clear squash; the RMW filter upstream, after it
  input  tl_h2d_t                      arb_h2d_i,
  input  logic                         arb_tag_i,
  input  bit_sel_t                     arb_bit_sel_i,
  input  tl_h2d_t                      rmw_h2d_i,
  input  tl_d2h_t                      rmw_d2h_i,
  // The alert logic's fault inputs: the engine's four, the RMW filter's (any), all nine (any);
  // and the alert sender's request
  input  logic [3:0]                   engine_fault_i,
  input  logic                         rmw_fault_i,
  input  logic                         fault_any_i,
  input  logic                         alert_req_i
);

  // The tracked capability's index (D44) and the request the engine tag filter's tracker follows.
  // FPV: undriven, so the formal tool picks them in every cycle. Simulation: the first capability
  // of every sweep, and the next request whenever that tracker is free.
`ifdef FPV_ON
  /* verilator lint_off UNDRIVEN */
  num_t k;
  logic tf_pick;
  /* verilator lint_on UNDRIVEN */
`else
  num_t k;
  logic tf_pick;
  assign k       = '0;
  assign tf_pick = 1'b1;
`endif

  default clocking @(posedge clk_i); endclocking
  /* verilator lint_off SYNCASYNCNET */
  default disable iff (!rst_ni);
  /* verilator lint_on SYNCASYNCNET */

  /////////////////
  // Port events //
  /////////////////

  // [TLUL] Signals: a beat passes in a cycle where valid and ready are both high.
  ev_t core_ev, rd_ev, trvk_ev, clr_ev, tf_ev, xbar_ev, bm_ev, arb_ev, rmw_ev;
  ev_t m_ev [2];
  assign core_ev = port_ev(core_h2d_i, core_d2h_i);
  assign rd_ev   = port_ev(rd_h2d_i, rd_d2h_i);
  assign trvk_ev = port_ev(trvk_h2d_i, trvk_d2h_i);
  assign clr_ev  = port_ev(clr_h2d_i, clr_d2h_i);
  assign tf_ev   = port_ev(tf_h2d_i, tf_d2h_i);
  assign xbar_ev = port_ev(xbar_h2d_i, xbar_d2h_i);
  assign bm_ev   = port_ev(bm_h2d_i, bm_d2h_i);
  assign m_ev[0] = port_ev(m_h2d_i[0], m_d2h_i[0]);
  assign m_ev[1] = port_ev(m_h2d_i[1], m_d2h_i[1]);
  // The squash only rewrites an engine clear's opcode: arbiter output and RMW filter upstream
  // share a_ready and the D channel.
  assign arb_ev  = port_ev(arb_h2d_i, rmw_d2h_i);
  assign rmw_ev  = port_ev(rmw_h2d_i, rmw_d2h_i);

  // The registers, by their [HJSON] names. TBRE_REGWEN and TBRE_EPOCH are hwext: what the engine
  // drives is what software reads. A set request is a field's write enable with the value 1.
  logic       ena;
  logic       start;          // a TBRE_START strobe, written 1
  addr_t      base;           // TBRE_BASE_ADDR; bits 2:0 read 0
  num_t       num;            // TBRE_NUM_CAPS
  logic       regwen;         // TBRE_REGWEN
  logic       epoch_active;   // TBRE_EPOCH.active
  epoch_cnt_t epoch_count;    // TBRE_EPOCH.count
  logic       start_err_set;
  logic       sweep_err_set;
  logic       intr_set;       // the set request for INTR_STATE.tbre_done
  logic       intr_test;      // an INTR_TEST strobe, written 1
  logic       intr_state;
  logic       intr_enable;
  assign ena           = is_ena(cheriot_ena_i);
  assign start         = reg2hw_i.tbre_start.qe && reg2hw_i.tbre_start.q;
  assign base          = {reg2hw_i.tbre_base_addr.q, 3'b000};
  assign num           = reg2hw_i.tbre_num_caps.q;
  assign regwen        = hw2reg_i.tbre_regwen.d;
  assign epoch_active  = hw2reg_i.tbre_epoch.active.d;
  assign epoch_count   = hw2reg_i.tbre_epoch.count.d;
  assign start_err_set = hw2reg_i.tbre_status.start_err.de && hw2reg_i.tbre_status.start_err.d;
  assign sweep_err_set = hw2reg_i.tbre_status.sweep_err.de && hw2reg_i.tbre_status.sweep_err.d;
  assign intr_set      = hw2reg_i.intr_state.de && hw2reg_i.intr_state.d;
  assign intr_test     = reg2hw_i.intr_test.qe && reg2hw_i.intr_test.q;
  assign intr_state    = reg2hw_i.intr_state.q;
  assign intr_enable   = reg2hw_i.intr_enable.q;

  logic engine_fault;
  assign engine_fault = |engine_fault_i;

  //////////////////
  // Engine model //
  //////////////////

  logic       active, regwen_q, regwen_rose, regwen_fell, taken_start, ignored_start;
  logic       taken_start_q, busy, start_err_owed, start_err_due, sweep_err_owed, sweep_err_due;
  logic       cause_now, alert_cause_seen, sweep_failed;
  // Read only by tbre_errors' bad answer raises fault, which only formal builds compile.
  /* verilator lint_off UNUSEDSIGNAL */
  logic       alert_cause_now;
  /* verilator lint_on UNUSEDSIGNAL */
  logic [4:0] causes;
  logic       lookup_new, held_unlooked, held_one, inflight_fits, core_two_out;
  addr_t      sweep_base, sweep_top;
  trk_e       trk_phase;
  logic       trk_on, trk_words_taken, trk_words_ans, trk_tag, trk_in_window, trk_w1_departs;
  logic       trk_needs_lookup, trk_lookup_match, trk_lk_ans_now, trk_rev_set, trk_lk_fail;
  logic       trk_read_err, trk_words_bad, trk_decided, trk_revoked, trk_clear_due;
  logic       trk_clr_new, trk_clr_seen, trk_watch_start, trk_in_watch, trk_touch;
  logic       trk_watch_touched, trk_stale_touched, trk_arrive, trk_arrived, trk_resolved;
  addr_t      trk, trk_base;
  word_t      trk_w0, trk_w1;

  revchk_engine_model u_engine_model (
    .clk_i,
    .rst_ni,
    .k_i                 (k),
    .ena_i               (ena),
    .start_i             (start),
    .base_i              (base),
    .num_i               (num),
    .regwen_i            (regwen),
    .busy_de_i           (hw2reg_i.tbre_status.busy.de),
    .busy_d_i            (hw2reg_i.tbre_status.busy.d),
    .start_err_set_i     (start_err_set),
    .sweep_err_set_i     (sweep_err_set),
    .core_h2d_i,
    .core_ev_i           (core_ev),
    .rd_h2d_i,
    .rd_d2h_i,
    .rd_ev_i             (rd_ev),
    .trvk_h2d_i,
    .trvk_d2h_i,
    .trvk_tag_rsp_i,
    .trvk_ev_i           (trvk_ev),
    .clr_h2d_i,
    .clr_d2h_i,
    .clr_ev_i            (clr_ev),
    .xbar_h2d_i,
    .xbar_d2h_i,
    .xbar_ev_i           (xbar_ev),
    .bm_h2d_i,
    .bm_d2h_i,
    .bm_ev_i             (bm_ev),
    .m1_d2h_i            (m_d2h_i[1]),
    .m1_ev_i             (m_ev[1]),
    .arb_h2d_i,
    .arb_bit_sel_i,
    .arb_ev_i            (arb_ev),
    .rmw_fault_i,
    .active_o            (active),
    .regwen_q_o          (regwen_q),
    .regwen_rose_o       (regwen_rose),
    .regwen_fell_o       (regwen_fell),
    .taken_start_o       (taken_start),
    .ignored_start_o     (ignored_start),
    .taken_start_q_o     (taken_start_q),
    .sweep_base_o        (sweep_base),
    .sweep_top_o         (sweep_top),
    .busy_o              (busy),
    .start_err_owed_o    (start_err_owed),
    .start_err_due_o     (start_err_due),
    .sweep_err_owed_o    (sweep_err_owed),
    .sweep_err_due_o     (sweep_err_due),
    .cause_now_o         (cause_now),
    .causes_o            (causes),
    .alert_cause_now_o   (alert_cause_now),
    .alert_cause_seen_o  (alert_cause_seen),
    .sweep_failed_o      (sweep_failed),
    .lookup_new_o        (lookup_new),
    .held_unlooked_o     (held_unlooked),
    .held_one_o          (held_one),
    .inflight_fits_o     (inflight_fits),
    .core_two_out_o      (core_two_out),
    .trk_phase_o         (trk_phase),
    .trk_on_o            (trk_on),
    .trk_o               (trk),
    .trk_words_taken_o   (trk_words_taken),
    .trk_words_ans_o     (trk_words_ans),
    .trk_w0_o            (trk_w0),
    .trk_w1_o            (trk_w1),
    .trk_tag_o           (trk_tag),
    .trk_in_window_o     (trk_in_window),
    .trk_w1_departs_o    (trk_w1_departs),
    .trk_needs_lookup_o  (trk_needs_lookup),
    .trk_lookup_match_o  (trk_lookup_match),
    .trk_lk_ans_now_o    (trk_lk_ans_now),
    .trk_rev_set_o       (trk_rev_set),
    .trk_lk_fail_o       (trk_lk_fail),
    .trk_base_o          (trk_base),
    .trk_read_err_o      (trk_read_err),
    .trk_words_bad_o     (trk_words_bad),
    .trk_decided_o       (trk_decided),
    .trk_revoked_o       (trk_revoked),
    .trk_clear_due_o     (trk_clear_due),
    .trk_clr_new_o       (trk_clr_new),
    .trk_clr_seen_o      (trk_clr_seen),
    .trk_watch_start_o   (trk_watch_start),
    .trk_in_watch_o      (trk_in_watch),
    .trk_touch_o         (trk_touch),
    .trk_watch_touched_o (trk_watch_touched),
    .trk_stale_touched_o (trk_stale_touched),
    .trk_arrive_o        (trk_arrive),
    .trk_arrived_o       (trk_arrived),
    .trk_resolved_o      (trk_resolved)
  );

  // The engine's tag filter, against the tag filter model shared with checker 1 (D40): no WTRC,
  // tag-only writes. tbre_clear's tag filter checks hold are every tf_* check of this instance;
  // its write answered once checks a write's answer.
  logic     tf_head_vld;
  ent_t     tf_head;
  logic     tf_head_meta_err;
  capture_e tf_capture;

  /* verilator lint_off PINCONNECTEMPTY */
  tfchk_checker #(
    .NvmCapStores (1'b0),
    .TagOnlyWrites(1'b1),
    .CoverCases   (1'b0),
    .RunLive      ((Run == RunLiveB) ? LiveB : LiveOff)
  ) u_tf_checker (
    .clk_i,
    .rst_ni,
    .cheriot_ena_i,
    .pick_i                 (tf_pick),
    .requester_h2d_i        (tf_h2d_i),
    .requester_tag_i        (tf_tag_i),
    .requester_d2h_i        (tf_d2h_i),
    .requester_tag_rsp_i    (tf_tag_rsp_i),
    .xbar_h2d_i,
    .xbar_d2h_i,
    .m_h2d_i                (m_h2d_i[1]),
    .m_tag_i                (m_tag_i[1]),
    .m_bit_sel_i            (m_bit_sel_i[1]),
    .m_d2h_i                (m_d2h_i[1]),
    .m_tag_rsp_i            (m_tag_rsp_i[1]),
    .pres_idx_o             (),
    .pres_o                 (),
    .head_vld_o             (tf_head_vld),
    .head_o                 (tf_head),
    .head_xbar_answered_o   (),
    .head_xbar_bad_intg_o   (),
    .head_match_o           (),
    .head_meta_answered_o   (),
    .head_meta_err_o        (tf_head_meta_err),
    .head_tag_wr_o          (),
    .head_tag_wr_maybe_o    (),
    .capture_o              (tf_capture),
    .pop_o                  (),
    .xbar_answer_vld_o      (),
    .xbar_answer_ent_o      (),
    .tag_wr_owed_o          (),
    .tag_wr_maybe_owed_o    (),
    .tag_wr_addr_o          (),
    .meta_is_tag_wr_o       (),
    .cap_state_o            (),
    .cap_addr_o             (),
    .word_cause_now_o       (),
    .out_of_seq_cause_now_o (),
    .cause_seen_o           ()
  );
  /* verilator lint_on PINCONNECTEMPTY */

  /////////////////////////////
  // Outstanding and history //
  /////////////////////////////

  // Reads on tbre_tl_h, lookups on the bitmap port, clears on the clear port: accepted, not yet
  // answered, after this cycle's events (tbre_status's REGWEN rises only when resolved,
  // tbre_sweep's at most two outstanding).
  logic [1:0] xbar_out_q, xbar_out_d, bm_out_q, bm_out_d, clr_out_q, clr_out_d;
  assign xbar_out_d = xbar_out_q + 2'(xbar_ev.req_fire) - 2'(xbar_ev.rsp_fire);
  assign bm_out_d   = bm_out_q + 2'(bm_ev.req_fire) - 2'(bm_ev.rsp_fire);
  assign clr_out_d  = clr_out_q + 2'(clr_ev.req_fire) - 2'(clr_ev.rsp_fire);

  // For covers: a sweep has started, and a start_err or sweep_err set request came, since reset.
  logic swept_q, start_err_was_set_q, sweep_err_was_set_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      xbar_out_q          <= '0;
      bm_out_q            <= '0;
      clr_out_q           <= '0;
      swept_q             <= 1'b0;
      start_err_was_set_q <= 1'b0;
      sweep_err_was_set_q <= 1'b0;
    end else begin
      xbar_out_q          <= xbar_out_d;
      bm_out_q            <= bm_out_d;
      clr_out_q           <= clr_out_d;
      swept_q             <= swept_q || taken_start;
      start_err_was_set_q <= start_err_was_set_q || start_err_set;
      sweep_err_was_set_q <= sweep_err_was_set_q || sweep_err_set;
    end
  end

  // BASE <= a < BASE + 8N of the sweep.
  function automatic logic in_sweep(addr_t a);
    return (a >= sweep_base) && (a < sweep_top);
  endfunction

  ////////////////////////////////////////////
  // tbre_start: which starts start a sweep //
  ////////////////////////////////////////////

  // A taken start makes the engine active in the next cycle.
  // tbre_start: taken start activates (CHK_TBRE_START_01)
  // tbre_status: REGWEN low after start (CHK_TBRE_STATUS_01)
  assert_TbreStart_TakenStartActivates : assert property (taken_start |=> !regwen);
  // TBRE_REGWEN falls only in the cycle after a taken start, so an ignored start starts no sweep.
  // tbre_start: REGWEN falls only on start (CHK_TBRE_START_02)
  assert_TbreStart_RegwenFallsOnStart : assert property (regwen_fell |-> taken_start_q);
  // After an ignored start, TBRE_REGWEN stays 1, the epoch stays the same and busy is 0.
  // tbre_start: ignored start changes nothing (CHK_TBRE_START_03)
  assert_TbreStart_IgnoredChangesNothing : assert property (ignored_start |=>
    regwen && $stable(epoch_count) && !busy);
  // An ignored start's start_err set request comes no later than the next cycle.
  // tbre_start: error set next cycle (CHK_TBRE_START_05)
  assert_TbreStart_ErrSetNextCycle : assert property (start_err_due |-> start_err_set);
  // A start_err set request comes only after an ignored start that has not had one yet.
  // tbre_start: error only after ignored start (CHK_TBRE_START_06)
  assert_TbreStart_ErrOnlyIfIgnored : assert property (start_err_set |->
    ignored_start || start_err_owed);
`ifdef FPV_ON
`ifndef VERILATOR
  // An ignored start is followed by a start_err set request, at some point.
  // tbre_start: ignored start sets error (CHK_TBRE_START_04)
  assert_TbreStart_IgnoredSetsErr : assert property (ignored_start |-> s_eventually start_err_set);
`endif
`endif

  // Cases: one input varied from the taken start BASE 0x1000_0000, NUM 1, CHERIoT mode.
  function automatic logic is_start(addr_t b, num_t n, prim_mubi_pkg::mubi4_t e);
    return start && regwen && (base == b) && (num == n) && (cheriot_ena_i == e);
  endfunction
  localparam prim_mubi_pkg::mubi4_t True = prim_mubi_pkg::MuBi4True;

  // A start with BASE 0x3000_0000, in the NVM, starts a sweep.
  // tbre_start: case NVM base
  cover_TbreStart_NvmRange : cover property (is_start(32'h3000_0000, 31'd1, True));
  // A start at the last main SRAM capability, 0x1002_FFF8, sweeps one capability.
  // tbre_start: case last SRAM capability
  cover_TbreStart_LastSramCap : cover property (is_start(32'h1002_FFF8, 31'd1, True));
  // A start with BASE at the main SRAM top, 0x1003_0000, is ignored.
  // tbre_start: case SRAM top
  cover_TbreStart_SramTop : cover property (is_start(32'h1003_0000, 31'd1, True));
  // A start with BASE 0x0FFF_FFF8, just below the main SRAM, is ignored.
  // tbre_start: case below SRAM
  cover_TbreStart_BelowSram : cover property (is_start(32'h0FFF_FFF8, 31'd1, True));
  // A start with BASE 0x2FFF_FFF8, just below the NVM, is ignored.
  // tbre_start: case below NVM
  cover_TbreStart_BelowNvm : cover property (is_start(32'h2FFF_FFF8, 31'd1, True));
  // A start with BASE at the NVM top, 0x3020_0000, is ignored.
  // tbre_start: case NVM top
  cover_TbreStart_NvmTop : cover property (is_start(32'h3020_0000, 31'd1, True));
  // A start with BASE in the meta SRAM, 0x1100_0000, is ignored.
  // tbre_start: case meta SRAM base
  cover_TbreStart_MetaSramBase : cover property (is_start(32'h1100_0000, 31'd1, True));
  // A start with BASE at a peripheral, 0x4000_0000, is ignored.
  // tbre_start: case peripheral base
  cover_TbreStart_PeriphBase : cover property (is_start(32'h4000_0000, 31'd1, True));
  // A start with TBRE_NUM_CAPS 0 is ignored.
  // tbre_start: case zero capabilities
  cover_TbreStart_NumCapsZero : cover property (is_start(32'h1000_0000, 31'd0, True));
  // A start with TBRE_NUM_CAPS 0x7FFF_FFFF starts a sweep, with N clipped.
  // tbre_start: case largest NUM
  cover_TbreStart_NumCapsMax : cover property (is_start(32'h1000_0000, 31'h7FFF_FFFF, True));
  // A start with the CHERIoT mode MuBi4False is ignored.
  // tbre_start: case ePMP mode
  cover_TbreStart_ModeFalse : cover property (is_start(32'h1000_0000, 31'd1,
    prim_mubi_pkg::MuBi4False));
  // A start with an invalid cheriot_ena_i, 4'h0, is ignored.
  // tbre_start: case invalid mode
  cover_TbreStart_ModeInvalid : cover property (is_start(32'h1000_0000, 31'd1,
    prim_mubi_pkg::mubi4_t'(4'h0)));

  // The truth table: row r of Ena, NUM != 0, Tagged(BASE), Ena the top bit, is cover r.
  for (genvar r = 0; r < 8; r++) begin : gen_start_row
    // Each of the eight start conditions is reached, one cover per truth table row.
    // tbre_start: truth table
    cover_TbreStart_TruthTableRow : cover property (start && regwen &&
      ({ena, num != '0, is_tagged(base)} == 3'(r)));
  end

  // A write of 0 to TBRE_START changes nothing.
  // tbre_start: edge case write of 0
  cover_TbreStart_WriteZero : cover property (reg2hw_i.tbre_start.qe &&
    !reg2hw_i.tbre_start.q && regwen);
  // A second start with no register write between sweeps the same range again.
  // tbre_start: edge case same range again
  cover_TbreStart_SameRangeAgain : cover property (taken_start && swept_q &&
    (base == sweep_base) && (base + addr_t'({sweep_caps(base, num), 3'b000}) == sweep_top));
  // An ignored start while start_err is already set sends a set request again.
  // tbre_start: edge case error again
  cover_TbreStart_ErrAgain : cover property (ignored_start && start_err_was_set_q);

  //////////////////////////////////////////////////
  // tbre_status: active, busy and the first read //
  //////////////////////////////////////////////////

  // TBRE_REGWEN rises only once the tracked capability is resolved and no access is outstanding.
  // tbre_status: REGWEN rises only when resolved (CHK_TBRE_STATUS_02)
  assert_TbreStatus_RegwenOnlyWhenResolved : assert property (regwen_rose |->
    (!trk_on || trk_resolved) && (xbar_out_d == '0) && (bm_out_d == '0) && (clr_out_d == '0));
  // The busy field the engine last wrote is the inverse of TBRE_REGWEN in the cycle before.
  // tbre_status: busy follows REGWEN (CHK_TBRE_STATUS_03)
  assert_TbreStatus_BusyNotRegwen : assert property (busy == !regwen_q);
  // In every cycle, TBRE_EPOCH.active is the inverse of TBRE_REGWEN.
  // tbre_status: active follows REGWEN (CHK_TBRE_STATUS_04)
  assert_TbreStatus_ActiveNotRegwen : assert property (epoch_active == !regwen);

  logic sweep_one;  // a sweep of one capability
  assign sweep_one = sweep_top == sweep_base + 32'd8;
  // The engine runs a sweep of one capability.
  // tbre_status: case sweep of one
  cover_TbreStatus_SweepOfOne : cover property (regwen_rose && sweep_one);
  // A sweep of two capabilities has both words in flight at once.
  // tbre_status: case two in flight
  cover_TbreStatus_TwoInFlight : cover property (active && (sweep_top == sweep_base + 32'd16) &&
    (xbar_out_q == 2'd2));
  // A sweep's last capability needs a clear, so the clear's answer arrives last.
  // tbre_status: case last capability cleared
  cover_TbreStatus_LastCapCleared : cover property (regwen_rose && trk_on && trk_clr_seen &&
    (trk == sweep_top - 32'd8));
  // Each phase of the tracked capability, one cover per phase.
  for (genvar p = 0; p < 6; p++) begin : gen_trk_phase
    // The tracked capability reaches each phase, from TrkIdle to TrkResolved.
    // tbre_status: case each tracking phase
    cover_TbreStatus_EachTrackPhase : cover property (trk_phase == trk_e'(p));
  end
  // The tracked capability is the first in its sweep.
  // tbre_status: case tracked first
  // tbre_sweep: case tracked first
  cover_TbreStatus_TrackedFirst : cover property (regwen_rose && trk_on && !sweep_one &&
    (trk == sweep_base));
  // The tracked capability is in the middle of its sweep.
  // tbre_status: case tracked in middle
  // tbre_sweep: case tracked in middle
  cover_TbreStatus_TrackedMiddle : cover property (regwen_rose && trk_on && (trk > sweep_base) &&
    (trk < sweep_top - 32'd8));
  // The tracked capability is the last in its sweep.
  // tbre_status: case tracked last
  // tbre_sweep: case tracked last
  cover_TbreStatus_TrackedLast : cover property (regwen_rose && trk_on && !sweep_one &&
    (trk == sweep_top - 32'd8));
  // A reset in the middle of a sweep (the default disable is off for this cover only).
  logic in_reset;
  assign in_reset = !rst_ni;
  // A reset comes in the middle of a sweep.
  // tbre_status: case reset mid sweep
  cover_TbreStatus_ResetMidSweep : cover property (disable iff (1'b0) active ##1 in_reset);

  //////////////////////////////////////////////////////////
  // tbre_epoch: the epoch counts sweeps without an error //
  //////////////////////////////////////////////////////////

  logic active_fell;  // TBRE_EPOCH.active falls: the engine stops being active
  assign active_fell = $fell(epoch_active);

  // When TBRE_EPOCH.active falls, the count steps by 1 unless the sweep had an error cause.
  // tbre_epoch: steps unless error (CHK_TBRE_EPOCH_01)
  assert_TbreEpoch_StepsUnlessCause : assert property (active_fell |->
    epoch_count == $past(epoch_count) + epoch_cnt_t'(!sweep_failed));
  // The count stays the same in every cycle where TBRE_EPOCH.active does not fall.
  // tbre_epoch: count stable otherwise (CHK_TBRE_EPOCH_02)
  assert_TbreEpoch_StableOtherwise : assert property (!active_fell |-> $stable(epoch_count));

  logic clean_end;  // a sweep ends with no cause
  assign clean_end = active_fell && !sweep_failed;
  // A sweep with no error is counted: the epoch goes 4, 5, 6.
  // tbre_epoch: case clean sweep
  cover_TbreEpoch_CleanSweep : cover property (clean_end);
  // A sweep with a read answered with d_error is not counted: the epoch goes 4, 5, 4.
  // tbre_epoch: case read error
  cover_TbreEpoch_ReadErr : cover property ((active && causes[4]) ##[1:$] active_fell);
  // A sweep with a bitmap lookup error, which raises an alert, is not counted.
  // tbre_epoch: case bitmap error
  cover_TbreEpoch_BitmapErr : cover property ((active && causes[1]) ##[1:$] active_fell);
  // An ignored start leaves the epoch at 4.
  // tbre_epoch: case ignored start
  cover_TbreEpoch_IgnoredStart : cover property (ignored_start);
  // An ignored start in the cycle after a sweep ends leaves the epoch at 6.
  // tbre_epoch: case ignored after end
  cover_TbreEpoch_IgnoredAfterEnd : cover property (active_fell ##1 ignored_start);
  // A clean sweep is counted even with sweep_err left set by an earlier sweep.
  // tbre_epoch: case error left set
  cover_TbreEpoch_ErrLeftSet : cover property (taken_start && sweep_err_was_set_q ##[1:$]
    clean_end);
  // An error in the cycle TBRE_EPOCH.active falls keeps the sweep from being counted.
  // tbre_epoch: case error at end
  cover_TbreEpoch_ErrAtEnd : cover property (active_fell && cause_now);
  // The count wraps from 2^31 - 1 to 0.
  // tbre_epoch: edge case count wraps
  cover_TbreEpoch_CountWraps : cover property (clean_end && (epoch_count == '0));

  //////////////////////////////
  // tbre_intr: the interrupt //
  //////////////////////////////

  // INTR_STATE gets a set request when TBRE_REGWEN rises and when INTR_TEST is written with 1.
  // tbre_intr: sweep end or test sets (CHK_TBRE_INTR_01)
  assert_TbreIntr_EndOrTestSets : assert property (regwen_rose || intr_test |-> intr_set);
  // INTR_STATE gets a set request only when a sweep ends or INTR_TEST is written with 1.
  // tbre_intr: set only on end or test (CHK_TBRE_INTR_02)
  assert_TbreIntr_SetOnlyThen : assert property (intr_set |-> regwen_rose || intr_test);
  // The interrupt line is INTR_STATE and INTR_ENABLE, of this cycle or of the cycle before.
  // tbre_intr: line follows state (CHK_TBRE_INTR_03)
  assert_TbreIntr_LineFollowsState : assert property ((intr_i == (intr_state && intr_enable)) ||
    (intr_i == $past(intr_state && intr_enable)));

  // A sweep ends with INTR_ENABLE set.
  // tbre_intr: case end, enabled
  cover_TbreIntr_EndEnabled : cover property (regwen_rose && intr_enable);
  // A sweep ends with INTR_ENABLE clear.
  // tbre_intr: case end, disabled
  cover_TbreIntr_EndDisabled : cover property (regwen_rose && !intr_enable);
  // Software writes 1 to INTR_TEST.
  // tbre_intr: case test write
  cover_TbreIntr_TestWrite : cover property (intr_test);
  // An INTR_TEST write comes in the cycle a sweep ends.
  // tbre_intr: case test at end
  cover_TbreIntr_TestAtEnd : cover property (intr_test && regwen_rose);
  // A sweep ends with an error.
  // tbre_intr: case end with error
  cover_TbreIntr_EndWithErr : cover property (regwen_rose && sweep_failed);
  logic line_due;  // INTR_STATE and INTR_ENABLE set, the line still low
  assign line_due = intr_state && intr_enable && !intr_i;
  // The interrupt line rises the cycle after INTR_STATE and INTR_ENABLE are both set.
  // tbre_intr: case line next cycle
  cover_TbreIntr_LineNextCycle : cover property (line_due ##1 intr_i);

  //////////////////////////////////////////////////
  // tbre_sweep: exactly the swept words are read //
  //////////////////////////////////////////////////

  // Both words of the tracked capability are read before TBRE_REGWEN rises.
  // tbre_sweep: both words read (CHK_TBRE_SWEEP_02)
  assert_TbreSweep_BothWordsRead : assert property (regwen_rose && trk_on |-> trk_words_taken);
  // Every request on tbre_tl_h is a full-word Get inside the swept range, sent while active.
  // tbre_sweep: Gets inside sweep (CHK_TBRE_SWEEP_03)
  assert_TbreSweep_GetsInsideSweep : assert property (xbar_ev.req_vld |->
    active && is_full_get(xbar_h2d_i) && in_sweep(xbar_h2d_i.a_address));
  // At most two reads are outstanding on tbre_tl_h, and no outstanding a_source is reused.
  // tbre_sweep: at most two outstanding (CHK_TBRE_SWEEP_04)
  assert_TbreSweep_AtMostTwoOut : assert property (xbar_out_q <= 2'd2);
  // The hint is set on every Get at the engine's tag filter.
  // tbre_sweep: Gets carry hint (CHK_TBRE_SWEEP_05)
  assert_TbreSweep_GetsCarryHint : assert property (tf_ev.req_vld && is_get(tf_h2d_i) |-> tf_tag_i);

  function automatic logic is_sweep_end(addr_t b, addr_t t);
    return regwen_rose && (sweep_base == b) && (sweep_top == t);
  endfunction

  // A sweep from 0x1001_FFF0 crosses from the main SRAM into the second SRAM.
  // tbre_sweep: case across seam
  cover_TbreSweep_AcrossSeam : cover property (is_sweep_end(32'h1001_FFF0, 32'h1002_0010));
  // A sweep of 5 from 0x1002_FFF0 is clipped to 2 at the SRAM top, 0x1003_0000.
  // tbre_sweep: case clipped at top
  cover_TbreSweep_ClippedAtTop : cover property (is_sweep_end(32'h1002_FFF0, 32'h1003_0000));
  // A sweep reads the last capability below the emulated OTP pages, 0x301F_F5F8.
  // tbre_sweep: case below OTP pages
  cover_TbreSweep_BelowOtpPages : cover property (is_sweep_end(32'h301F_F5F8, 32'h301F_F600));
  // A sweep reads a single capability, N = 1.
  // tbre_sweep: case one capability
  cover_TbreSweep_OneCap : cover property (regwen_rose && sweep_one);
  // Two sweep reads are in flight at once.
  // tbre_sweep: case two in flight
  cover_TbreSweep_TwoInFlight : cover property (xbar_out_q == 2'd2);
  // The sweep reads the last main SRAM word, 0x1002_FFFC.
  // tbre_sweep: edge case last SRAM word
  cover_TbreSweep_LastSramCap : cover property (xbar_ev.req_fire &&
    (xbar_h2d_i.a_address == 32'h1002_FFFC));
  // The sweep reads the last NVM word, 0x301F_FFFC.
  // tbre_sweep: edge case last NVM word
  cover_TbreSweep_LastNvmCap : cover property (xbar_ev.req_fire &&
    (xbar_h2d_i.a_address == 32'h301F_FFFC));
  // An NVM sweep with BASE 0x301F_FFF0, NUM 4 and N 2 ends near the top.
  // tbre_sweep: edge case NVM top
  cover_TbreSweep_NvmTop : cover property (is_sweep_end(32'h301F_FFF0, 32'h3020_0000));

  /////////////////////////////////
  // tbre_done: every sweep ends //
  /////////////////////////////////

  if (Run == RunLiveB) begin : gen_live_b_done
`ifdef FPV_ON
`ifndef VERILATOR
    // After a taken start, TBRE_REGWEN returns to 1 at some point.
    // tbre_done: sweep ends (CHK_TBRE_DONE_01)
    assert_TbreDone_SweepEnds : assert property (taken_start |=> s_eventually regwen);
`endif
`endif
  end

  // A sweep of one capability ends.
  // tbre_done: case one-capability sweep
  cover_TbreDone_OneCapSweep : cover property (regwen_rose && trk_on && sweep_one);
  // A sweep with a clear ends.
  // tbre_done: case sweep with clear
  cover_TbreDone_SweepWithClear : cover property (regwen_rose && trk_on && trk_clr_seen);
  // A sweep with a read error ends.
  // tbre_done: case sweep with read error
  cover_TbreDone_SweepWithReadErr : cover property (regwen_rose && trk_on && trk_read_err);

  ///////////////////////////////////////////////////
  // tbre_decision: which capabilities are revoked //
  ///////////////////////////////////////////////////

  // A tracked capability needing a lookup gets a Get of its base's bitmap word while W1 waits.
  // tbre_decision: lookup when needed (CHK_TBRE_DECISION_02)
  assert_TbreDecision_LookupWhenNeeded : assert property (trk_w1_departs && trk_needs_lookup |->
    trk_lookup_match);
  // No lookup is made for a tracked capability whose base lies outside the main SRAM.
  // tbre_decision: no lookup outside main SRAM (CHK_TBRE_DECISION_03)
  assert_TbreDecision_NoLookupWhileHeld : assert property (lookup_new && trk_in_window &&
    held_one &&
    trk_words_ans |-> is_revocable(trk_base));
  // Every lookup is a full-word Get of a bitmap word, sent while a W1 answer awaits its lookup.
  // tbre_decision: lookup is bitmap Get (CHK_TBRE_DECISION_04)
  assert_TbreDecision_LookupIsBitmapGet : assert property (lookup_new |->
    is_full_get(bm_h2d_i) && is_bitmap_word(bm_h2d_i.a_address) && held_unlooked);
  // The model's two places hold every read in flight, as the spec allows up to two words.
  // tbre_decision: lookup is bitmap Get (CHK_TBRE_DECISION_04)
  assert_TbreDecision_InFlightFits : assert property (inflight_fits);
  // By the sweep's end, a revoked tracked capability left untouched has had its clear sent.
  // tbre_decision: revoked gets cleared (CHK_TBRE_DECISION_05)
  assert_TbreDecision_RevokedGetsCleared : assert property (regwen_rose && trk_on &&
    trk_clear_due |->
    trk_clr_seen);
  // Every clear is sent while active and lies inside a swept capability.
  // tbre_decision: clear only if revoked (CHK_TBRE_DECISION_06)
  assert_TbreDecision_ClearInsideSweep : assert property (clr_ev.req_vld |->
    active && in_sweep(clr_h2d_i.a_address));
  // A clear of the tracked capability comes only once it is decided and revoked.
  // tbre_decision: clear only if revoked (CHK_TBRE_DECISION_06)
  assert_TbreDecision_ClearOnlyIfRevoked : assert property (trk_clr_new && !trk_words_bad |->
    trk_decided && trk_revoked);

  // The decision, seen when W1's answer leaves the TRVK filter, read without a faulty answer.
  logic       dec;
  logic [5:0] p;
  assign dec = trk_w1_departs && trk_words_ans && !trk_read_err && !trk_words_bad;
  assign p   = cap_perms(trk_w1);

  // The truth table: row r of Tag, Sealing, Revocable(Base), RevSet (Tag the top bit) is cover r,
  // with the lookup, if any, answered without error.
  for (genvar r = 0; r < 16; r++) begin : gen_decision_row
    // Each row of the decision truth table is reached, with any lookup answered without error.
    // tbre_decision: truth table
    cover_TbreDecision_TruthTableRow : cover property (dec && !trk_lk_fail &&
      ({trk_tag, is_sealing(trk_w1), is_revocable(trk_base), trk_rev_set} == 4'(r)));
  end

  // Bitmap word w and the parity o of the base's bit, cover 2w + o, for a tagged,
  // non-sealing capability with a revocable base.
  localparam word_t BmWord [4] = '{32'h0000_0000, 32'hFFFF_FFFF, 32'hAAAA_AAAA, 32'h5555_5555};
  for (genvar w = 0; w < 4; w++) begin : gen_bm_word
    for (genvar o = 0; o < 2; o++) begin : gen_parity
      // Each of four bitmap word patterns is looked up, with the base's bit even and odd.
      // tbre_decision: case bitmap word and parity
      cover_TbreDecision_BitmapWord : cover property (trk_lk_ans_now && trk_tag &&
        !is_sealing(trk_w1) && (bm_d2h_i.d_data == BmWord[w]) &&
        (rev_bit(trk_base)[0] == 1'(o)));
    end
  end

  // The permission formats ([ISA] Figure 7.4), tagged, base revocable, bit set.
  logic dec_set;
  assign dec_set = dec && trk_tag && is_revocable(trk_base) && trk_rev_set;
  // A tagged capability with read-write memory permissions and its bit set is decided.
  // tbre_decision: case permission set
  cover_TbreDecision_PermMemRw : cover property (dec_set && (p[4:3] == 2'b11));
  // A tagged capability with read-only memory permissions and its bit set is decided.
  // tbre_decision: case permission set
  cover_TbreDecision_PermMemRo : cover property (dec_set && (p[4:2] == 3'b101));
  // A tagged capability with write-only memory permissions and its bit set is decided.
  // tbre_decision: case permission set
  cover_TbreDecision_PermMemWo : cover property (dec_set && (p[4:0] == 5'b10000));
  // A tagged capability with data-only permissions and its bit set is decided.
  // tbre_decision: case permission set
  cover_TbreDecision_PermDataOnly : cover property (dec_set && (p[4:2] == 3'b100) &&
    (p[1:0] != 2'b00));
  // A tagged, executable capability with its bit set is decided.
  // tbre_decision: case permission set
  cover_TbreDecision_PermExec : cover property (dec_set && (p[4:3] == 2'b01));
  // A tagged sealing capability with only the SE permission and its bit set is decided.
  // tbre_decision: case permission set
  cover_TbreDecision_PermSealSe : cover property (dec_set && (p[4:0] == 5'b00010));
  // A tagged sealing capability with only the US permission and its bit set is decided.
  // tbre_decision: case permission set
  cover_TbreDecision_PermSealUs : cover property (dec_set && (p[4:0] == 5'b00001));
  // A tagged sealing capability with only the U0 permission and its bit set is decided.
  // tbre_decision: case permission set
  cover_TbreDecision_PermSealU0 : cover property (dec_set && (p[4:0] == 5'b00100));
  // A tagged sealing capability with SE, US and U0 and its bit set is decided.
  // tbre_decision: case permission set
  cover_TbreDecision_PermSealAll : cover property (dec_set && (p[4:0] == 5'b00111));
  // A tagged capability with no permissions and its bit set is decided.
  // tbre_decision: case no permissions
  cover_TbreDecision_NoPerms : cover property (dec_set && (p[4:0] == 5'b00000));

  // The base at the main SRAM's edges and seam, in the NVM, below and above the main SRAM,
  // at a peripheral; a tagged, non-sealing capability.
  localparam addr_t EdgeBase [9] = '{32'h1000_0000, 32'h1002_FFF8, 32'h1001_FFF8, 32'h1002_0000,
                                     32'h3000_0000, 32'h0FFF_FFF8, 32'h1003_0000, 32'h1003_8000,
                                     32'h4000_0000};
  for (genvar b = 0; b < 9; b++) begin : gen_edge_base
    // A tagged, non-sealing capability is decided with its base at each region edge.
    // tbre_decision: case base at edge
    cover_TbreDecision_BaseAtEdge : cover property (dec && trk_tag && !is_sealing(trk_w1) &&
      (trk_base == EdgeBase[b]));
  end

  // A sealed memory capability, otype not 0, with its bit set is decided.
  // tbre_decision: case sealed capability
  cover_TbreDecision_SealedCap : cover property (dec_set && (p[4:3] != 2'b00) &&
    (trk_w1[24:22] != 3'd0));
  // A capability with base 0x1000_4000, at the start of its granule, is decided.
  // tbre_decision: case granule offset 0
  cover_TbreDecision_BaseGranule0 : cover property (dec_set && (trk_base == 32'h1000_4000));
  // A capability with base 0x1000_4007, at the end of the same granule, is decided.
  // tbre_decision: case granule offset 7
  cover_TbreDecision_BaseGranule7 : cover property (dec_set && (trk_base == 32'h1000_4007));
  // A capability at 0x1000_4210 with base 0x1000_41F0 is decided with its base's bit set.
  // tbre_decision: case Base bit set
  cover_TbreDecision_BaseBitSet : cover property (dec && trk_tag && (trk_w0 == 32'h1000_4210) &&
    (trk_base == 32'h1000_41F0) && trk_rev_set);
  // A capability at 0x1000_4210 with base 0x1000_41F0 is decided with its base's bit clear.
  // tbre_decision: case base bit clear
  cover_TbreDecision_BaseBitClear : cover property (dec && trk_tag && (trk_w0 == 32'h1000_4210) &&
    (trk_base == 32'h1000_41F0) && !trk_rev_set && !trk_lk_fail);
  // A tagged capability whose base decode correction is 0 is decided.
  // tbre_decision: case base correction
  cover_TbreDecision_BaseCorrectZero : cover property (dec && trk_tag &&
    !is_cb_neg(trk_w0, trk_w1));
  // A tagged capability whose base decode correction is -1 is decided.
  // tbre_decision: case base correction
  cover_TbreDecision_BaseCorrectNeg : cover property (dec && trk_tag && is_cb_neg(trk_w0, trk_w1));
  // A tagged capability with exponent 0 is decided.
  // tbre_decision: case exponent
  cover_TbreDecision_ExponentZero : cover property (dec && trk_tag && (trk_w1[21:18] == 4'd0));
  // A tagged capability with exponent 4 is decided.
  // tbre_decision: case exponent
  cover_TbreDecision_ExponentFour : cover property (dec && trk_tag && (trk_w1[21:18] == 4'd4));
  // A tagged capability with exponent 14 is decided.
  // tbre_decision: case exponent
  cover_TbreDecision_ExponentFourteen : cover property (dec && trk_tag && (trk_w1[21:18] == 4'd14));
  // A tagged capability with exponent field 15, so e = 24, is decided.
  // tbre_decision: case exponent
  cover_TbreDecision_ExponentFifteen : cover property (dec && trk_tag && (trk_w1[21:18] == 4'd15));
  // A capability stored in the NVM with a main SRAM base is decided.
  // tbre_decision: case stored in NVM
  cover_TbreDecision_StoredInNvm : cover property (dec && trk_tag && is_nvm(trk) &&
    is_revocable(trk_base));

  ///////////////////////////////////////////////////////
  // tbre_clear: the clear and the engine's tag filter //
  ///////////////////////////////////////////////////////

  // The meta request on input 1 that the tracked capability's clear makes: the engine's tag filter
  // presents the clear on its device port, and its meta request in the same cycle (tf_lookup's
  // lookup in same cycle and no unneeded lookup, in u_tf_checker).
  logic trk_clr_meta;
  logic trk_clr_meta_sent_q, trk_clr_meta_sent_d;
  assign trk_clr_meta        = trk_on && m_ev[1].req_vld && tf_ev.req_vld && is_wr(tf_h2d_i) &&
                               (tf_h2d_i.a_address[31:3] == trk[31:3]);
  assign trk_clr_meta_sent_d = taken_start ? 1'b0 :
                               (trk_clr_meta_sent_q || (trk_clr_meta && m_ev[1].req_fire));
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      trk_clr_meta_sent_q <= 1'b0;
    end else begin
      trk_clr_meta_sent_q <= trk_clr_meta_sent_d;
    end
  end

  // The tracked capability's clear leaves on arbiter input 1 as a tag 0 write to its tag bit.
  // tbre_clear: clears tracked bit once (CHK_TBRE_CLEAR_01)
  assert_TbreClear_ClearsTrackedBit : assert property (trk_clr_meta |->
    is_wr(m_h2d_i[1]) && !m_tag_i[1] && (m_h2d_i[1].a_address == tag_word(trk)) &&
    (m_bit_sel_i[1] == tag_bit(trk)));
  // No second clear of the tracked capability follows in the same sweep.
  // tbre_clear: clears tracked bit once (CHK_TBRE_CLEAR_01)
  assert_TbreClear_ClearedOnce : assert property (trk_clr_meta |-> !trk_clr_meta_sent_q);
  // Every write the engine's tag filter presents on arbiter input 1 carries tag 0.
  // tbre_clear: writes tag 0 (CHK_TBRE_CLEAR_02)
  assert_TbreClear_WritesTag0 : assert property (m_ev[1].req_vld && is_wr(m_h2d_i[1]) |->
    !m_tag_i[1]);

  logic trk_clr_taken;
  assign trk_clr_taken = trk_clr_meta && m_ev[1].req_fire;
  // The engine clears a capability stored in the main SRAM.
  // tbre_clear: case SRAM capability
  cover_TbreClear_SramCap : cover property (trk_clr_taken && is_main_sram(trk));
  // The engine clears a capability stored in the NVM, such as one at 0x3000_0400.
  // tbre_clear: case NVM capability
  cover_TbreClear_NvmCap : cover property (trk_clr_taken && (trk == 32'h3000_0400) &&
    (m_h2d_i[1].a_address == 32'h1100_0C10) && (m_bit_sel_i[1] == 5'd0));
  // The engine clears the last main SRAM capability: word 0x1100_97FC, bit 31.
  // tbre_clear: case last SRAM capability
  cover_TbreClear_LastSramCap : cover property (trk_clr_taken && (trk == 32'h1002_FFF8) &&
    (m_h2d_i[1].a_address == 32'h1100_97FC) && (m_bit_sel_i[1] == 5'd31));
  // The engine clears the last NVM capability a sweep can read, 0x301F_F5F8.
  // tbre_clear: case last NVM capability
  cover_TbreClear_LastNvmCap : cover property (trk_clr_taken && (trk == 32'h301F_F5F8));
  // A clear is answered with d_error.
  // tbre_clear: case clear answer error
  cover_TbreClear_ClearRspErr : cover property (tf_ev.rsp_fire && tf_head_vld &&
    is_wr_kind(tf_head.kind) && tf_head_meta_err);
  // A clear is answered between the two reads of the next capability.
  // tbre_clear: case between reads
  cover_TbreClear_BetweenReads : cover property (tf_ev.rsp_fire && tf_head_vld &&
    is_wr_kind(tf_head.kind) && (tf_capture == CaptureHeld));

  ////////////////////////////////////////////////////////////
  // tbre_watch: a capability the core writes keeps its tag //
  ////////////////////////////////////////////////////////////

  // A clear at the RMW filter: the arbiter forwards a write from input 1.
  logic clear_at_rmw;
  assign clear_at_rmw = rmw_ev.req_vld && arb_h2d_i.a_source[0] && is_wr(arb_h2d_i);

  // The tracked capability's clear is sent only if no core write touched it in Watch(trk).
  // tbre_watch: clear only if untouched (CHK_TBRE_WATCH_01)
  assert_TbreWatch_ClearOnlyIfUntouched : assert property (trk_clr_new |-> !trk_watch_touched);
  // A clear touched in Stale(trk) reaches the RMW filter as a Get of the same word and bit.
  // tbre_watch: stale clear becomes read (CHK_TBRE_WATCH_02)
  assert_TbreWatch_StaleBecomesRead : assert property (trk_arrive && trk_stale_touched |->
    is_get(rmw_h2d_i) && (rmw_h2d_i.a_address == tag_word(trk)) &&
    (arb_bit_sel_i == tag_bit(trk)));
  // A clear not touched in Stale(trk) reaches the RMW filter as a write of tag 0.
  // tbre_watch: fresh clear stays write (CHK_TBRE_WATCH_03)
  assert_TbreWatch_FreshStaysWrite : assert property (trk_arrive && !trk_stale_touched |->
    is_same_a(rmw_h2d_i, arb_h2d_i));
  // A clear at the RMW filter that is not accepted is presented again, unchanged, next cycle.
  // tbre_watch: clear held unchanged (CHK_TBRE_WATCH_04)
  assert_TbreWatch_ClearHeldUnchanged : assert property (clear_at_rmw && !rmw_ev.req_fire |=>
    rmw_ev.req_vld && is_same_a(rmw_h2d_i, $past(rmw_h2d_i)) &&
    is_same_a(arb_h2d_i, $past(arb_h2d_i)) && $stable(arb_tag_i) && $stable(arb_bit_sel_i));

  // Which core writes touch c = 0x1000_1238.
  localparam addr_t WatchCap = 32'h1000_1238;  // the testplan's c
  function automatic logic is_core_wr(tl_a_op_e op, logic [1:0] size, addr_t a, logic tag);
    return core_ev.req_vld && (core_h2d_i.a_opcode == op) && (core_h2d_i.a_size == size) &&
           (core_h2d_i.a_address == a) && (core_tag_i == tag);
  endfunction
  logic c_watched;
  assign c_watched = (trk == WatchCap) && trk_in_watch;

  // A word store to 0x1000_123C, W1 of the capability, touches it.
  // tbre_watch: case word store to W1
  cover_TbreWatch_StoreWordW1 : cover property (c_watched &&
    is_core_wr(PutFullData, 2'd2, WatchCap + 32'd4, 1'b0));
  // A byte store to 0x1000_123B touches the capability.
  // tbre_watch: case byte store
  cover_TbreWatch_StoreByte : cover property (c_watched &&
    is_core_wr(PutPartialData, 2'd0, WatchCap + 32'd3, 1'b0));
  // A capability store's W0 to 0x1000_1238 touches the capability.
  // tbre_watch: case capability store W0
  cover_TbreWatch_CapStoreW0 : cover property (c_watched &&
    is_core_wr(PutFullData, 2'd2, WatchCap, 1'b1));
  // A capability store's W1 to 0x1000_123C touches the capability.
  // tbre_watch: case capability store W1
  cover_TbreWatch_CapStoreW1 : cover property (c_watched &&
    is_core_wr(PutFullData, 2'd2, WatchCap + 32'd4, 1'b1));
  // A word store to the next capability, 0x1000_1240, lets the clear go ahead.
  // tbre_watch: case next capability written
  cover_TbreWatch_NextCapTouched : cover property ((c_watched &&
    is_core_wr(PutFullData, 2'd2, WatchCap + 32'd8, 1'b0)) ##[1:$] trk_clr_new);
  // A core write that is presented but not yet accepted touches the capability.
  // tbre_watch: case write not yet accepted
  cover_TbreWatch_ClearNotAccepted : cover property (c_watched && trk_touch && core_ev.req_vld &&
    !core_ev.req_fire && is_wr(core_h2d_i) &&
    (core_h2d_i.a_address[31:3] == WatchCap[31:3]));
  logic c_out_early;    // a write to c accepted and unanswered, before the watch
  logic c_taken_early;  // a write to c accepted before the watch
  assign c_out_early   = (trk == WatchCap) && !trk_in_watch && trk_touch && !core_ev.req_vld;
  assign c_taken_early = (trk == WatchCap) && !trk_in_watch && core_ev.req_fire &&
                         is_wr(core_h2d_i) && (core_h2d_i.a_address[31:3] == WatchCap[31:3]);
  // A write accepted before the watch and answered inside it touches the capability.
  // tbre_watch: case answered inside window
  cover_TbreWatch_RspInsideWindow : cover property (c_out_early ##[1:$]
    (c_watched && core_ev.rsp_fire));
  // A write answered before the watch started lets the clear go ahead.
  // tbre_watch: case answered before window
  cover_TbreWatch_RspBeforeWindow : cover property (c_taken_early ##[1:$] trk_clr_new);
  // A touch in the cycle W0's read is presented on the engine's read port stops the clear.
  // tbre_watch: case touch with W0 read
  cover_TbreWatch_TouchWithW0Read : cover property (trk_watch_start && trk_touch);
  // A touch in the last cycle before the clear is presented stops the clear.
  // tbre_watch: case touch just before clear
  cover_TbreWatch_TouchJustBefore : cover property ((trk_in_watch && trk_touch) ##1 trk_clr_new);
  // A touch in the cycle the clear is presented turns the clear into a read.
  // tbre_watch: case touch with clear
  cover_TbreWatch_TouchWithClear : cover property (trk_clr_new && trk_touch);
  // A touch as the clear reaches the RMW filter leaves it a write, ahead of the core's write.
  // tbre_watch: case touch at arrival
  cover_TbreWatch_TouchAtArrival : cover property (trk_arrive && trk_touch);
  // A touch while the clear is held at the RMW filter reaches the filter after the clear.
  // tbre_watch: case touch while held
  cover_TbreWatch_TouchWhileHeld : cover property (trk_arrived && clear_at_rmw && trk_touch &&
    (arb_h2d_i.a_address == tag_word(trk)) && (arb_bit_sel_i == tag_bit(trk)));
  // With two capabilities in flight, a core write touches one of them.
  // tbre_watch: edge case two in flight
  cover_TbreWatch_TwoInFlight : cover property (trk_in_watch && trk_touch &&
    (xbar_out_q == 2'd2) && (xbar_h2d_i.a_address[31:3] != trk[31:3]));
  logic core_wr_waits;  // a core write presented and not accepted
  logic core_quiet;     // no core request presented
  assign core_wr_waits = core_ev.req_vld && !core_ev.req_fire && is_wr(core_h2d_i);
  assign core_quiet    = !core_ev.req_vld;
  // A core write is presented and withdrawn before it is accepted.
  // tbre_watch: edge case write withdrawn
  cover_TbreWatch_WriteWithdrawn : cover property ((trk_in_watch && trk_touch && core_wr_waits) ##1
    core_quiet);

  ///////////////////////////////////////////////////////////////
  // tbre_errors: what fails a sweep and what raises the alert //
  ///////////////////////////////////////////////////////////////

  // A d_error on the answer to a read of the tracked capability on tbre_tl_h means no clear for it.
  // tbre_errors: read error, no clear (CHK_TBRE_ERRORS_01)
  assert_TbreErr_ReadErrNoClear : assert property (trk_clr_new |-> !trk_read_err);
  // Each cause's sweep_err set request comes no later than the cycle after the cause.
  // tbre_errors: error set next cycle (CHK_TBRE_ERRORS_03)
  assert_TbreErr_ErrSetNextCycle : assert property (sweep_err_due |-> sweep_err_set);
  // An RMW filter fault input raised while active raises the alert request in that cycle.
  // tbre_errors: RMW fault raises alert (CHK_TBRE_ERRORS_05)
  assert_TbreErr_RmwFaultRaisesAlert : assert property (rmw_fault_i && active |-> alert_req_i);
  // A sweep_err set request comes only while a cause has not had one yet.
  // tbre_errors: error only for a cause (CHK_TBRE_ERRORS_06)
  assert_TbreErr_ErrOnlyForCause : assert property (sweep_err_set |->
    cause_now || sweep_err_owed);
`ifdef FPV_ON
`ifndef VERILATOR
  // Each cause in the engine's error table is followed by a sweep_err set request, at some point.
  // tbre_errors: cause sets sweep error (CHK_TBRE_ERRORS_02)
  assert_TbreErr_CauseSetsErr : assert property (cause_now |-> s_eventually sweep_err_set);
  // A bad-integrity or malformed answer on tbre_tl_h, or a failed lookup, raises an engine fault.
  // tbre_errors: bad answer raises fault (CHK_TBRE_ERRORS_04)
  assert_TbreErr_BadRspRaisesFault : assert property (alert_cause_now |->
    s_eventually engine_fault);
`endif
`endif

  // Each cause alone.
  logic one_cause;
  assign one_cause = $onehot(causes);
  // A sweep read gets a d_error answer on tbre_tl_h, with no other cause.
  // tbre_errors: case sweep read error
  cover_TbreErr_SweepReadErr : cover property (one_cause && causes[4]);
  // An answer on tbre_tl_h has a broken integrity, with no other cause.
  // tbre_errors: case host bad integrity
  cover_TbreErr_XbarBadIntg : cover property (one_cause && xbar_ev.rsp_fire &&
    !is_intg_ok(xbar_d2h_i));
  // The meta answer to a tag read comes with d_error, with no other cause.
  // tbre_errors: case tag read error
  cover_TbreErr_TagReadErr : cover property (tf_ev.rsp_fire && tf_head_vld &&
    (tf_head.kind == KindLoadW0) && tf_head_meta_err);
  // The meta answer to a clear comes with d_error, with no other cause.
  // tbre_errors: case clear error
  cover_TbreErr_ClearErr : cover property (tf_ev.rsp_fire && tf_head_vld &&
    is_wr_kind(tf_head.kind) && tf_head_meta_err);
  // A bitmap lookup gets a d_error answer, with no other cause.
  // tbre_errors: case bitmap error
  cover_TbreErr_BitmapErr : cover property (one_cause && bm_ev.rsp_fire &&
    bm_d2h_i.d_error);
  // The RMW filter raises a fault while the engine is active, with no other cause.
  // tbre_errors: case RMW fault
  cover_TbreErr_RmwFault : cover property (one_cause && causes[0]);
  // A bitmap lookup answer has a broken integrity.
  // tbre_errors: case bitmap bad integrity
  cover_TbreErr_BitmapBadIntg : cover property (one_cause && bm_ev.rsp_fire &&
    !is_intg_ok(bm_d2h_i));
  // A malformed answer arrives on tbre_tl_h.
  // tbre_errors: case host malformed answer
  cover_TbreErr_XbarMalformed : cover property (xbar_ev.rsp_fire &&
    is_malformed_read(xbar_d2h_i));
  // A bitmap lookup gets a malformed answer.
  // tbre_errors: case bitmap malformed answer
  cover_TbreErr_BitmapMalformed : cover property (bm_ev.rsp_fire &&
    is_malformed_read(bm_d2h_i));
  // A cause hits the first capability of a sweep.
  // tbre_errors: case error on first capability
  cover_TbreErr_OnFirstCap : cover property (trk_w1_departs && trk_read_err &&
    (trk == sweep_base) && !sweep_one);
  // A cause hits the last capability of a sweep.
  // tbre_errors: case error on last capability
  cover_TbreErr_OnLastCap : cover property (trk_w1_departs && trk_read_err &&
    (trk == sweep_top - 32'd8) && !sweep_one);
  // Two causes come in the same cycle.
  // tbre_errors: case two causes at once
  cover_TbreErr_TwoCausesAtOnce : cover property ($countones(causes) >= 2);
  // A sweep of the emulated OTP pages, BASE 0x301F_F600, gets a read error.
  // tbre_errors: case OTP pages read
  cover_TbreErr_OtpPagesRead : cover property (causes[4] && (sweep_base == 32'h301F_F600));
  // The RMW filter raises a fault while the engine is inactive.
  // tbre_errors: edge case RMW fault while idle
  cover_TbreErr_RmwFaultIdle : cover property (rmw_fault_i && !active);
  // A cause comes while sweep_err is still set from an earlier sweep.
  // tbre_errors: edge case error already set
  cover_TbreErr_ErrAlreadySet : cover property (cause_now && sweep_err_was_set_q);

  ////////////////////////////////////////////////
  // contracts: proven in checker 3, for others //
  ////////////////////////////////////////////////

  // The engine's tag filter holds its meta request, tag and bit select until accepted.
  // contracts: engine meta request held (contract C3a) (CHK_CONTRACTS_03)
  assert_Contracts_EngineMetaReqHeld : assert property (m_ev[1].req_vld && !m_ev[1].req_fire |=>
    m_ev[1].req_vld && is_same_a(m_h2d_i[1], $past(m_h2d_i[1])) && $stable(m_tag_i[1]) &&
    $stable(m_bit_sel_i[1]));
  // The engine's tag filter takes every meta answer in the cycle it is offered.
  // contracts: engine meta answer taken (contract C3b) (CHK_CONTRACTS_04)
  assert_Contracts_EngineMetaRspTaken : assert property (m_ev[1].rsp_vld |-> m_h2d_i[1].d_ready);
  // The engine's tag filter addresses whole meta words: bits 1:0 of a_address are 0.
  // contracts: engine addresses whole words (contract C11) (CHK_CONTRACTS_12)
  assert_Contracts_EngineWordAddr : assert property (m_ev[1].req_vld |->
    m_h2d_i[1].a_address[1:0] == 2'b00);
  // The engine's and the register file's fault inputs rise only after one of their causes.
  // contracts: engine faults have causes (contract C9) (CHK_CONTRACTS_10)
  assert_Contracts_EngineFaultCaused : assert property (engine_fault |-> alert_cause_seen);
  // Contract C5, liveness run A: the bitmap port takes every answer offered.
  if (Run == RunLiveA) begin : gen_live_a
`ifdef FPV_ON
`ifndef VERILATOR
    // On the engine's bitmap port, every answer offered is taken, at some point.
    // contracts: bitmap answer taken (contract C5) (CHK_CONTRACTS_06)
    assert_Contracts_BitmapRspTaken : assert property (bm_ev.rsp_vld |->
      s_eventually bm_ev.rsp_fire);
`endif
`endif
  end

  // The engine's tag filter's meta request waits to be taken.
  // contracts: engine meta request held (contract C3a) (CHK_CONTRACTS_03)
  cover_Contracts_EngineMetaReqWaiting : cover property (m_ev[1].req_vld && !m_ev[1].req_fire);
  // A meta answer is offered to the engine's tag filter.
  // contracts: engine meta answer taken (contract C3b) (CHK_CONTRACTS_04)
  cover_Contracts_EngineMetaRspOffered : cover property (m_ev[1].rsp_vld);
  // An answer on the engine's bitmap port waits to be taken.
  // contracts: bitmap answer taken (contract C5) (CHK_CONTRACTS_06)
  cover_Contracts_BitmapRspOffered : cover property (bm_ev.rsp_vld && !bm_h2d_i.d_ready);
  // One of the engine's fault inputs rises.
  // contracts: engine faults have causes (contract C9) (CHK_CONTRACTS_10)
  cover_Contracts_EngineFault : cover property (engine_fault);
  // The engine's tag filter presents a meta request.
  // contracts: engine addresses whole words (contract C11) (CHK_CONTRACTS_12)
  cover_Contracts_EngineMetaReq : cover property (m_ev[1].req_vld);
  // The engine's tag filter's meta request is taken.
  // contracts: engine meta port follows TL-UL (contract C21) (CHK_CONTRACTS_13)
  cover_Contracts_EngineMetaTaken : cover property (m_ev[1].req_fire);

  ////////////////////////////////////////////////////////////
  // alert_causes: the alert only with a fault input raised //
  ////////////////////////////////////////////////////////////

  // The alert request rises only in a cycle where one of the nine alert fault inputs is raised.
  // alert_causes: alert only on a fault (CHK_ALERT_CAUSES_01)
  assert_AlertCauses_AlertOnlyOnFault : assert property (alert_req_i |-> fault_any_i);

  ///////////////////////////////////////////////////////////
  // environment: every assumption of checker 3 can be met //
  ///////////////////////////////////////////////////////////

  // Two core requests are outstanding on cored_tl_d at once.
  // environment: case core two outstanding, for assumption A2
  cover_Env_CoreTwoOutstanding : cover property (core_ev.req_fire && core_two_out);
  // Each cheriot_ena_i value v, with a start, one cover per value.
  for (genvar v = 0; v < 16; v++) begin : gen_env_ena
    // A TBRE_START write of 1 comes with each of the 16 cheriot_ena_i values.
    // environment: case every mode value, for assumption A6
    cover_Env_EveryModeValue : cover property ((cheriot_ena_i == prim_mubi_pkg::mubi4_t'(v)) &&
      start);
  end
  // An answer on tbre_tl_h is taken with two requests outstanding.
  // environment: case engine read answers in order, for assumption A12
  cover_Env_TbreRspInOrder : cover property (xbar_ev.rsp_fire && (xbar_out_q == 2'd2));
  // An answer on cored_tl_d is taken with two outstanding, from the cut tag filter.
  // environment: case core answers in order, for contract C6
  cover_Env_CoreRspInOrder : cover property (core_ev.rsp_fire && core_two_out);
  // A meta request waits on the 2:1 tag arbiter's input 0.
  // environment: case input 0 meta request waits, for contract C7
  cover_Env_Input0MetaWaits : cover property (m_ev[0].req_vld && !m_ev[0].req_fire);
  // Software writes TBRE_START, raising its strobe.
  // environment: case start strobe
  cover_Env_StartStrobe : cover property (reg2hw_i.tbre_start.qe);
  // TBRE_BASE_ADDR changes after a cycle with TBRE_REGWEN 1.
  // environment: case base address changes
  cover_Env_BaseAddrChanges : cover property (regwen_q && !$stable(base));
  // INTR_STATE rises from 0 to 1.
  // environment: case interrupt state rises
  cover_Env_IntrStateRises : cover property ($rose(intr_state));
  // A core write is presented and then withdrawn; checker 3 has no hold rule on cored_tl_d.
  // environment: case core write withdrawn
  cover_Env_CoreWrWithdrawn : cover property (core_wr_waits ##1 core_quiet);

  /////////////////////////////////////////////////////////////////
  // tlul_protocol: TL-UL rules on the links between real blocks //
  /////////////////////////////////////////////////////////////////

  // tlul_protocol's TL-UL rules hold and contract C21 on arbiter input 1; the same on the
  // engine's four internal links: CheckBoth asserts every TL-UL rule on both channels and assumes
  // nothing, so it also runs in simulation. Input 1 uses SrcW 7: the arbiter keeps 7 bits of
  // a_source.
  // MaxOutstanding 2 on the read port and the TRVK downstream port: "Up to two words are in
  // flight" ([ToO]).
  /* verilator lint_off PINCONNECTEMPTY */
  tlul_abvip #(.Role(CheckBoth), .SrcW(7)) u_abvip_m1 (
    .clk_i, .rst_ni, .h2d_i(m_h2d_i[1]), .d2h_i(m_d2h_i[1]),
    .a_fire_o(), .d_fire_o(), .num_outstanding_o(), .oldest_src_o());

  tlul_abvip #(.Role(CheckBoth), .MaxOutstanding(2)) u_abvip_rd (
    .clk_i, .rst_ni, .h2d_i(rd_h2d_i), .d2h_i(rd_d2h_i),
    .a_fire_o(), .d_fire_o(), .num_outstanding_o(), .oldest_src_o());

  tlul_abvip #(.Role(CheckBoth), .MaxOutstanding(2)) u_abvip_trvk (
    .clk_i, .rst_ni, .h2d_i(trvk_h2d_i), .d2h_i(trvk_d2h_i),
    .a_fire_o(), .d_fire_o(), .num_outstanding_o(), .oldest_src_o());

  tlul_abvip #(.Role(CheckBoth)) u_abvip_clr (
    .clk_i, .rst_ni, .h2d_i(clr_h2d_i), .d2h_i(clr_d2h_i),
    .a_fire_o(), .d_fire_o(), .num_outstanding_o(), .oldest_src_o());

  tlul_abvip #(.Role(CheckBoth)) u_abvip_tf (
    .clk_i, .rst_ni, .h2d_i(tf_h2d_i), .d2h_i(tf_d2h_i),
    .a_fire_o(), .d_fire_o(), .num_outstanding_o(), .oldest_src_o());
  /* verilator lint_on PINCONNECTEMPTY */

endmodule
