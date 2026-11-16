// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Checker for one wakeup detector, on the always-on clock. It models the pad PADSEL names (seen
// two AON cycles late), the optional filter and the pattern MODE asks for: an edge, or a level held
// for CNT_TH samples, a count the spec leaves open by one, so a set request is due at the later
// count and allowed from the earlier. Each detection gets a set request on the cause bit's port
// within WkLat AON cycles, and every set request answers a detection of the last WkLat cycles that
// no earlier set answered. Disabling the detector drops a waiting detection's obligation.
//
// Naming: x is this AON cycle's value, x_q the stored one; hi_run counts samples at the level the
// timed mode waits for, this one included.

// The resets are asynchronous in the flops and a disable condition in the properties.
/* verilator lint_off SYNCASYNCNET */
module wkup_detector_chk
  import pinmux_pkg::*;
  import pinmux_reg_pkg::*;
#(
  parameter int unsigned PadselW = $bits(pinmux_reg2hw_wkup_detector_padsel_mreg_t),
  parameter int unsigned WkLat   = 4   // DV reading: AON cycles from a detection to its set request
) (
  input logic                    clk_aon_i,
  input logic                    rst_aon_ni,

  // Pads
  input logic [NMioPads-1:0]     mio_in_i,
  input logic [NDioPads-1:0]     dio_in_i,

  // The detector's configuration as the AON domain holds it
  input logic                    en_i,       // WKUP_DETECTOR_EN
  input logic [2:0]              mode_i,     // WKUP_DETECTOR.MODE
  input logic                    filter_i,   // WKUP_DETECTOR.FILTER
  input logic                    miodio_i,   // WKUP_DETECTOR.MIODIO
  input logic [PadselW-1:0]      padsel_i,   // WKUP_DETECTOR_PADSEL
  input logic [WkupCntWidth-1:0] th_i,       // WKUP_DETECTOR_CNT_TH

  // No claim while the selected pad is not wakeup capable (EG2; 0 on tops without the list)
  input logic                    no_claim_i,

  // The cause bit's hardware write port
  input logic                    cause_de_i,
  input logic                    cause_d_i
);

  default clocking @(posedge clk_aon_i); endclocking
  default disable iff (!rst_aon_ni || no_claim_i);

  // WKUP_DETECTOR.MODE values the checker decodes.
  localparam logic [2:0] ModeNegedge   = 3'd1;
  localparam logic [2:0] ModeEdge      = 3'd2;
  localparam logic [2:0] ModeTimedHigh = 3'd3;
  localparam logic [2:0] ModeTimedLow  = 3'd4;

  // One bit wider than CNT_TH, so the later count of 255 is reachable.
  localparam int unsigned RunW = WkupCntWidth + 1;
  typedef logic [RunW-1:0] run_t;

  // An obligation's age, up to WkLat + 1.
  localparam int unsigned AgeW = $clog2(WkLat + 2);

  /////////////////////
  // Watched value   //
  /////////////////////

  // [REG] WKUP_DETECTOR_PADSEL: with MIODIO 0, 0 and 1 are constants and 2 + p is MIO pad p;
  // with MIODIO 1, n is DIO pad n; any other value watches 0.
  function automatic logic watched_value(logic miodio, logic [PadselW-1:0] padsel,
                                         logic [NMioPads-1:0] mio, logic [NDioPads-1:0] dio);
    if (!miodio) begin
      if (padsel == PadselW'(1)) return 1'b1;
      for (int p = 0; p < NMioPads; p++) begin
        if (32'(padsel) == p + 2) return mio[p];
      end
    end else begin
      for (int n = 0; n < NDioPads; n++) begin
        if (32'(padsel) == n) return dio[n];
      end
    end
    return 1'b0;
  endfunction

  // The pad is asynchronous to the AON clock: the detector sees it two AON cycles later;
  // every stage starts at 0 after reset.
  logic       watched, sampled;
  logic [1:0] sync_q;

  assign watched = watched_value(miodio_i, padsel_i, mio_in_i, dio_in_i);

  always_ff @(posedge clk_aon_i or negedge rst_aon_ni) begin
    if (!rst_aon_ni) sync_q <= '0;
    else             sync_q <= {sync_q[0], watched};
  end

  assign sampled = sync_q[1];

  ///////////////
  // Filter    //
  ///////////////

  // [REG] FILTER: a value counts once it is the same for this sample and the three before; it
  // runs whatever EN (REQ_WKUP_18).
  logic [2:0] last3_q;
  logic       filter_q, all_same, filtered, filtered_q;

  always_ff @(posedge clk_aon_i or negedge rst_aon_ni) begin
    if (!rst_aon_ni) last3_q <= '0;
    else             last3_q <= {last3_q[1:0], sampled};
  end

  // Four equal samples: all ones or all zeros.
  assign all_same = &{last3_q, sampled} || ~|{last3_q, sampled};

  // The last value that held for four samples in a row.
  always_ff @(posedge clk_aon_i or negedge rst_aon_ni) begin
    if (!rst_aon_ni)   filter_q <= 1'b0;
    else if (all_same) filter_q <= sampled;
  end

  // The live sample passes when filtering is off or it has already held four samples.
  assign filtered = (!filter_i || all_same) ? sampled : filter_q;

  always_ff @(posedge clk_aon_i or negedge rst_aon_ni) begin
    if (!rst_aon_ni) filtered_q <= 1'b0;
    else             filtered_q <= filtered;
  end

  ////////////////
  // Patterns   //
  ////////////////

  logic rise, fall;

  assign rise = filtered && !filtered_q;
  assign fall = !filtered && filtered_q;

  // Samples in a row at the level the timed mode waits for, saturating; 0 while disabled.
  logic want_level;
  run_t hi_run, run_q;

  assign want_level = mode_i == ModeTimedHigh;
  assign hi_run     = (en_i && filtered == want_level) ?
                      ((run_q == '1) ? run_q : run_q + 1'b1) : '0;

  always_ff @(posedge clk_aon_i or negedge rst_aon_ni) begin
    if (!rst_aon_ni) run_q <= '0;
    else             run_q <= hi_run;
  end

  // CNT_TH of 0 reads as 1.
  run_t th;

  assign th = (th_i == '0) ? run_t'(1) : run_t'(th_i);

  logic timed, edge_mode_rise, edge_mode_fall, det_rise, det_fall, det_timed, det_timed_late;

  assign timed          = mode_i inside {ModeTimedHigh, ModeTimedLow};

  // Modes 0, 2 and the out-of-range values 5 to 7 watch for a rise ([REG] "default to Posedge").
  assign edge_mode_rise = !timed && mode_i != ModeNegedge;
  assign edge_mode_fall = mode_i inside {ModeNegedge, ModeEdge};

  // Detections of the enabled detector; det_timed_late is the later timed count, CNT_TH + 1,
  // since the spec reads both ways ([REG] "for CNT_TH cycles", [TP] "longer than").
  assign det_rise       = en_i && edge_mode_rise && rise;
  assign det_fall       = en_i && edge_mode_fall && fall;
  assign det_timed      = en_i && timed && hi_run == th;
  assign det_timed_late = en_i && timed && hi_run == th + 1'b1;

  logic det, cause_set;

  assign det       = det_rise || det_fall || det_timed;
  assign cause_set = cause_de_i && cause_d_i;

  ////////////////////////
  // Backward credits   //
  ////////////////////////

  // Detections of the last WkLat AON cycles that no set request answered yet: a set request
  // answers the oldest one; a credit expires after WkLat cycles.
  logic [WkLat-1:0] credit_q, credit_d;

  always_comb begin
    logic [WkLat:0] all;
    logic           taken;
    all   = {credit_q, det};  // all[WkLat] is the oldest; all[1] is last cycle's detection

    // A timed credit still open at the later count moves there: one detection, one credit.
    if (det_timed_late && credit_q[0]) begin
      all[1] = 1'b0;
      all[0] = 1'b1;
    end
    taken = 1'b0;
    if (cause_set) begin
      for (int k = WkLat; k >= 0; k--) begin
        if (!taken && all[k]) begin
          all[k] = 1'b0;
          taken  = 1'b1;
        end
      end
    end
    credit_d = all[WkLat-1:0];
  end

  always_ff @(posedge clk_aon_i or negedge rst_aon_ni) begin
    if (!rst_aon_ni) credit_q <= '0;
    else             credit_q <= credit_d;
  end

  ////////////////////////
  // Forward obligations //
  ////////////////////////

  // One obligation per check: opened by a detection with no set request that cycle (a timed one at
  // the later count, unless set at the earlier), closed by a set request, dropped on disable.
  logic timed_late_open, cause_set_q, disabled_now;

  assign timed_late_open = det_timed_late && !cause_set && !cause_set_q;
  assign disabled_now    = !en_i;

  always_ff @(posedge clk_aon_i or negedge rst_aon_ni) begin
    if (!rst_aon_ni) cause_set_q <= 1'b0;
    else             cause_set_q <= cause_set;
  end

  logic [3:0]           open_now, pending_q;
  logic [3:0][AgeW-1:0] age_q;

  // Bit 0 rise, 1 fall, 2 timed high, 3 timed low: the order of the four checks below.
  assign open_now = {det_timed_late && mode_i == ModeTimedLow  && timed_late_open,
                     det_timed_late && mode_i == ModeTimedHigh && timed_late_open,
                     det_fall && !cause_set,
                     det_rise && !cause_set};

  for (genvar c = 0; c < 4; c++) begin : gen_obligation
    always_ff @(posedge clk_aon_i or negedge rst_aon_ni) begin
      if (!rst_aon_ni) begin
        pending_q[c] <= 1'b0;
        age_q[c]     <= '0;
      end else if (pending_q[c] && (cause_set || disabled_now)) begin
        pending_q[c] <= 1'b0;
      end else if (pending_q[c]) begin
        age_q[c]     <= age_q[c] + 1'b1;
      end else if (open_now[c]) begin
        pending_q[c] <= 1'b1;
        age_q[c]     <= AgeW'(1);
      end
    end
  end

  ////////////////
  // Properties //
  ////////////////

  // A detected rise (modes 0, 2, 5 to 7) gets a set request within WkLat AON cycles.
  // REQ_WKUP_06, 08, 11; wakeup: posedge sets cause; [REG] MODE
  assert_Wakeup_PosedgeSetsCause : assert property (pending_q[0] && !cause_set |->
                                                    32'(age_q[0]) < WkLat);

  // A detected fall (modes 1, 2) gets a set request within WkLat AON cycles.
  // REQ_WKUP_07, 08; wakeup: negedge sets cause; [REG] MODE
  assert_Wakeup_NegedgeSetsCause : assert property (pending_q[1] && !cause_set |->
                                                    32'(age_q[1]) < WkLat);

  // A high level held CNT_TH + 1 samples gets a set request; one at CNT_TH is allowed.
  // REQ_WKUP_09; wakeup: timed high sets cause; [REG] MODE TimedHigh
  assert_Wakeup_TimedHighSetsCause : assert property (pending_q[2] && !cause_set |->
                                                      32'(age_q[2]) < WkLat);

  // A low level held CNT_TH + 1 samples gets a set request; one at CNT_TH is allowed.
  // REQ_WKUP_10; wakeup: timed low sets cause; [REG] MODE TimedLow
  assert_Wakeup_TimedLowSetsCause : assert property (pending_q[3] && !cause_set |->
                                                     32'(age_q[3]) < WkLat);

  // Every set request answers a detection of the enabled detector not yet answered.
  // REQ_WKUP_12, 13; wakeup: no false cause; [REG] WKUP_CAUSE
  assert_Wakeup_NoFalseCause : assert property (cause_set |-> det || |credit_q);

  // Hardware only ever writes 1 to the cause bit.
  // REQ_WKUP_14; wakeup: hw only sets cause; [REG] WKUP_CAUSE rw0c
  assert_Wakeup_HwOnlySetsCause : assert property (cause_de_i |-> cause_d_i);

  ////////////
  // Covers //
  ////////////

  // The detector asks to set its cause bit.
  // REQ_WKUP_06; wakeup: cause set
  cover_Wakeup_CauseSet : cover property (cause_set);

  // The set request comes at the latency bound.
  // REQ_WKUP_06; wakeup: latency at the bound
  cover_Wakeup_LatencyAtBound : cover property (pending_q[0] && 32'(age_q[0]) == WkLat &&
                                                cause_set);

  // A timed detection right after the detector is enabled.
  // REQ_WKUP_09; wakeup: cause right after enable
  cover_Wakeup_CauseAfterEnable : cover property ($rose(en_i) && filtered && mode_i ==
                                                  ModeTimedHigh);

  // A set with an out-of-range mode.
  // REQ_WKUP_11; wakeup: mode out of range
  cover_Wakeup_ModeOutOfRange : cover property (cause_set && mode_i > ModeTimedLow);

  // A timed detection with threshold 0.
  // REQ_WKUP_09; wakeup: threshold zero
  cover_Wakeup_TimedThZero : cover property (det_timed && th_i == '0);

  // The filter drops a level held only three samples.
  // REQ_WKUP_04; wakeup: glitch filtered
  cover_Wakeup_GlitchFiltered : cover property (filter_i && en_i && last3_q == 3'b011 &&
                                                !sampled && !filtered);

  // A detector watches a DIO pad and sets its cause.
  // REQ_WKUP_02; wakeup: DIO pad watched
  cover_Wakeup_DioWatched : cover property (miodio_i && cause_set);

  // A disabled detector's pending detection.
  // REQ_WKUP_12; wakeup: disable before the set
  cover_Wakeup_DisableBeforeSet : cover property (pending_q[0] && disabled_now);

endmodule : wkup_detector_chk
