// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Strap and TAP harness: TAP strap sampling, the DFT straps, the latched debug enable, TAP
// selection and the JTAG pads while a TAP is connected ([ToO] Strap Sampling and TAP Isolation,
// Non-debug Module Reset). Each life cycle input is read over two cycles, so a one-cycle On is
// left undecided. It models the TAP the sampled straps and their gates select, checks each TAP
// with a jtag_tap_chk and tells the pad harnesses when a TAP may own the JTAG pads. The strap task
// checks the design's sampled straps; the TAP task checks TAP selection with them cut free.
//
// x_on is "x On for two cycles", x_may "x On in this cycle or the one before"; a credit window
// counts the cycles since the event that allows a change; N = MaxLat + 1. The wait counters read 0
// in the cycle after their event, so MaxLat - 1 is cycle t + MaxLat.

// The resets are asynchronous in the flops and a disable condition in the properties.
/* verilator lint_off SYNCASYNCNET */
module pinmux_jtag_harness
  import pinmux_pkg::*;
  import pinmux_reg_pkg::*;
  import pinmux_fpv_regmap_pkg::*;
  import lc_ctrl_pkg::*;
  import jtag_pkg::*;
#(
  parameter int unsigned TckIdx       = 0,  // pad indices into {DIO, MIO}
  parameter int unsigned TmsIdx       = 0,
  parameter int unsigned TrstIdx      = 0,
  parameter int unsigned TdiIdx       = 0,
  parameter int unsigned TdoIdx       = 0,
  parameter int unsigned TapStrap0Idx = 0,
  parameter int unsigned TapStrap1Idx = 0,
  parameter int unsigned DftStrap0Idx = 0,
  parameter int unsigned DftStrap1Idx = 0,
  parameter int unsigned MaxLat       = 4   // DV reading: cycle bound on strap, latch, TAP delays
) (
  input logic                   clk_i,
  input logic                   rst_ni,
  input logic                   rst_sys_ni,

  // Life cycle
  input lc_tx_t                 lc_dft_en_i,
  input lc_tx_t                 lc_hw_debug_en_i,
  input lc_tx_t                 lc_check_byp_en_i,
  input lc_tx_t                 lc_escalate_en_i,
  input lc_tx_t                 lc_hw_debug_clr_i,
  input lc_tx_t                 pinmux_hw_debug_en_o,

  // Power manager, DFT, scan
  input logic                   strap_en_i,
  input logic                   dft_hold_tap_sel_i,
  input prim_mubi_pkg::mubi4_t  scanmode_i,
  input dft_strap_test_req_t    dft_strap_test_o,

  // Pads and peripheral inputs
  input logic [NMioPads-1:0]    mio_in_i,
  input logic [NDioPads-1:0]    dio_in_i,
  input logic [NMioPads-1:0]    mio_out_o,
  input logic [NMioPads-1:0]    mio_oe_o,
  input prim_pad_wrapper_pkg::pad_attr_t [NMioPads-1:0] mio_attr_o,
  input logic [NDioPads-1:0]    dio_out_o,
  input logic [NDioPads-1:0]    dio_oe_o,
  input logic [NMioPeriphIn-1:0] mio_to_periph_o,

  // Register block's hardware interface and the bus record
  input pinmux_reg2hw_t         reg2hw_i,
  input pinmux_hw2reg_t         hw2reg_i,
  input logic                   wr_done_i,
  input logic [BlockAw-1:0]     wr_addr_i,

  // TAPs
  input jtag_req_t              lc_jtag_o,
  input jtag_rsp_t              lc_jtag_i,
  input jtag_req_t              rv_jtag_o,
  input jtag_rsp_t              rv_jtag_i,
  input jtag_req_t              dft_jtag_o,
  input jtag_rsp_t              dft_jtag_i,

  // Sampled TAP straps (internal, from the bind)
  input logic [NTapStraps-1:0]  tap_strap_i,

  // A TAP may own the JTAG pads (to the pad harnesses)
  output logic                  tap_connected_o
);

  default clocking @(posedge clk_i); endclocking
  default disable iff (!rst_sys_ni);

  localparam int unsigned N          = MaxLat + 1;
  localparam int unsigned NumPadsAll = NMioPads + NDioPads;
  localparam int unsigned AgeW       = $clog2(N + 2);

  // [ToO] TAP table: the sampled straps {strap 1, strap 0} that ask for each TAP.
  localparam logic [1:0] LcTapCode  = 2'b01;
  localparam logic [1:0] RvTapCode  = 2'b10;
  localparam logic [1:0] DftTapCode = 2'b11;

  if (TckIdx >= NMioPads || TmsIdx >= NMioPads || TrstIdx >= NMioPads || TdiIdx >= NMioPads ||
      TdoIdx >= NMioPads) begin : gen_jtag_pads_not_mio
    $error("pinmux_jtag_harness: the JTAG pad checks expect the five JTAG pads on MIO");
  end

  // A saturating age counter, restarted by an event.
  function automatic logic [AgeW-1:0] age_next(logic event_now, logic [AgeW-1:0] age);
    if (event_now) return '0;
    return (age < N + 1) ? age + 1'b1 : age;
  endfunction

  ////////////////////////
  // Life cycle windows //
  ////////////////////////

  // [TP] "On (Off) for the past two clock cycles due to the synchronizer": steadily On
  // when On in both cycles before, may be On when On in either. Other values mean disable ([LC]).
  lc_tx_t dft_q, dbg_q, byp_q, esc_q, clr_q;
  lc_tx_t dft_q2, dbg_q2, byp_q2, esc_q2, clr_q2;

  always_ff @(posedge clk_i or negedge rst_sys_ni) begin
    if (!rst_sys_ni) begin
      dft_q  <= Off;
      dbg_q  <= Off;
      byp_q  <= Off;
      esc_q  <= Off;
      clr_q  <= Off;
      dft_q2 <= Off;
      dbg_q2 <= Off;
      byp_q2 <= Off;
      esc_q2 <= Off;
      clr_q2 <= Off;
    end else begin
      dft_q  <= lc_dft_en_i;
      dbg_q  <= lc_hw_debug_en_i;
      byp_q  <= lc_check_byp_en_i;
      esc_q  <= lc_escalate_en_i;
      clr_q  <= lc_hw_debug_clr_i;
      dft_q2 <= dft_q;
      dbg_q2 <= dbg_q;
      byp_q2 <= byp_q;
      esc_q2 <= esc_q;
      clr_q2 <= clr_q;
    end
  end

  logic dft_on, dft_may, dbg_on, dbg_may, clear, clear_may, latched;
  assign dft_on    = dft_q == On && dft_q2 == On;
  assign dft_may   = dft_q == On || dft_q2 == On;
  assign dbg_on    = dbg_q == On && dbg_q2 == On;
  assign dbg_may   = dbg_q == On || dbg_q2 == On;
  assign clear     = (byp_q == On && byp_q2 == On) ||
                     (esc_q == On && esc_q2 == On) ||
                     (clr_q == On && clr_q2 == On);
  assign clear_may = byp_q == On || byp_q2 == On || esc_q == On || esc_q2 == On ||
                     clr_q == On || clr_q2 == On;
  assign latched   = pinmux_hw_debug_en_o == On;

  //////////
  // Pads //
  //////////

  logic [NumPadsAll-1:0] pad_in, pad_out, pad_oe;
  assign pad_in  = {dio_in_i,  mio_in_i};
  assign pad_out = {dio_out_o, mio_out_o};
  assign pad_oe  = {dio_oe_o,  mio_oe_o};

  jtag_req_t pad_req;
  assign pad_req = '{tck: pad_in[TckIdx], tms: pad_in[TmsIdx], trst_n: pad_in[TrstIdx],
                     tdi: pad_in[TdiIdx]};

  logic strap0, strap1, dft_strap0, dft_strap1;
  assign strap0     = pad_in[TapStrap0Idx];
  assign strap1     = pad_in[TapStrap1Idx];
  assign dft_strap0 = pad_in[DftStrap0Idx];
  assign dft_strap1 = pad_in[DftStrap1Idx];

  /////////////////
  // Environment //
  /////////////////

  // Whether strap_en_i has pulsed since the full reset.
  logic pulsed_q;

  always_ff @(posedge clk_i or negedge rst_sys_ni) begin
    if (!rst_sys_ni)     pulsed_q <= 1'b0;
    else if (strap_en_i) pulsed_q <= 1'b1;
  end

  // The power manager pulses strap_en_i once per full reset.
  assume_Strap_PulseOnlyOnce : assume property (pulsed_q |-> !strap_en_i);

  // The TAP model: the row of each TAP, with its gate On (sel) or maybe On (sel_may).
  logic sel_lc, sel_rv, sel_dft, sel_may_dft;
  assign sel_lc      = tap_strap_i == LcTapCode;
  assign sel_rv      = tap_strap_i == RvTapCode  && latched;
  assign sel_dft     = tap_strap_i == DftTapCode && dft_on;
  assign sel_may_dft = tap_strap_i == DftTapCode && dft_may;

  // The DFT TAP holds the selection only while it may be connected.
  assume_Strap_HoldOnlyWithDft : assume property (dft_hold_tap_sel_i |-> sel_may_dft);

  //////////////////////////
  // TAP ownership window //
  //////////////////////////

  // A TAP may own the JTAG pads now or did in the last MaxLat cycles (tap_connected_o);
  // the pad harnesses leave the five pads to the JTAG pad checks then.
  logic              any_sel_may;
  logic [MaxLat-1:0] any_sel_may_q;
  assign any_sel_may = sel_lc || sel_rv || sel_may_dft;

  always_ff @(posedge clk_i or negedge rst_sys_ni) begin
    if (!rst_sys_ni) any_sel_may_q <= '0;
    else             any_sel_may_q <= {any_sel_may_q[MaxLat-2:0], any_sel_may};
  end

  assign tap_connected_o = any_sel_may || |any_sel_may_q;

  /////////////////
  // Debug latch //
  /////////////////

  // Events that allow the latch to rise (a pulse with the debug enable maybe On and no clear) and
  // to fall (a clear maybe On), with their credit windows.
  logic            set_event, set_allowed, fall_allowed, latched_q, first_cycle_q;
  logic [AgeW-1:0] set_age_q, clear_age_q, set_wait_q, clear_wait_q;
  logic            set_wait_vld_q, clear_wait_vld_q;
  assign set_event = strap_en_i && dbg_on && !clear_may;

  always_ff @(posedge clk_i or negedge rst_sys_ni) begin
    if (!rst_sys_ni) begin
      set_age_q        <= '1;
      clear_age_q      <= '1;
      latched_q        <= 1'b0;
      first_cycle_q    <= 1'b1;
      set_wait_vld_q   <= 1'b0;
      set_wait_q       <= '0;
      clear_wait_vld_q <= 1'b0;
      clear_wait_q     <= '0;
    end else begin
      set_age_q     <= age_next(strap_en_i && dbg_may && !clear, set_age_q);
      clear_age_q   <= age_next(clear_may, clear_age_q);
      latched_q     <= latched;
      first_cycle_q <= 1'b0;

      // Forward set: a set event, then no clear for MaxLat cycles.
      if (set_event)                      {set_wait_vld_q, set_wait_q} <= {1'b1, AgeW'(0)};
      else if (clear_may)                 set_wait_vld_q <= 1'b0;
      else if (set_wait_vld_q)            set_wait_q <= age_next(1'b0, set_wait_q);

      // Forward clear: a clear, then no pulse for MaxLat cycles. A held clear keeps its wait
      // running; a pulse ends it, and a clear still held starts a new one.
      if (clear && !clear_wait_vld_q)     {clear_wait_vld_q, clear_wait_q} <= {1'b1, AgeW'(0)};
      else if (strap_en_i)                clear_wait_vld_q <= 1'b0;
      else if (clear_wait_vld_q)          clear_wait_q <= age_next(1'b0, clear_wait_q);
    end
  end

  assign set_allowed  = (strap_en_i && dbg_may && !clear) || set_age_q < N;
  assign fall_allowed = clear_may || clear_age_q < N;

  // A pulse that samples debug On, with no clear for MaxLat cycles, turns the latch On.
  // REQ_DBGEN_01; latch: sets on pulse; [ToO] "samples the lc_hw_debug_en state"
  assert_Latch_SetsOnPulse : assert property (set_wait_vld_q && set_wait_q >= MaxLat - 1 |->
                                              latched);

  // A clear at On, with no pulse for MaxLat cycles, turns the latch off.
  // REQ_DBGEN_03, 04; latch: clears on LC change; [ToO] "invalidates the sampled"
  assert_Latch_ClearsOnLcChange : assert property (clear_wait_vld_q &&
                                                   clear_wait_q >= MaxLat - 1 |-> !latched);

  // The latch rises only within N cycles after a pulse that may sample debug On.
  // REQ_DBGEN_01, 02, 05; latch: rises only on set; [ToO]
  assert_Latch_RisesOnlyOnSet : assert property (latched && !latched_q |-> set_allowed);

  // The latch falls only within N cycles after a clear that may be On.
  // REQ_DBGEN_05; latch: falls only when allowed; [LC] "all others meaning disable"
  assert_Latch_FallsOnlyWhenAllowed : assert property (!latched && latched_q |-> fall_allowed);

  // Out of a full reset the latch is not On.
  // REQ_DBGEN_02; latch: rises only on set; [IF] pinmux_hw_debug_en
  assert_Latch_OffAfterFullReset : assert property (first_cycle_q |-> !latched);

  ///////////////////
  // TAP selection //
  ///////////////////

  logic scan, tdo_awake;
  assign scan      = scanmode_i == prim_mubi_pkg::MuBi4True;
  assign tdo_awake = !reg2hw_i.mio_pad_sleep_status[TdoIdx].q;

  // One checker per TAP. Only the DFT TAP's gate is read over two cycles, so only its sel_may_i
  // differs from its sel_i.
  jtag_tap_chk #(.MaxLat (MaxLat)) u_lc (
    .clk_i, .rst_ni, .rst_sys_ni,
    .sel_i (sel_lc), .sel_may_i (sel_lc), .scan_i (scan), .tdo_awake_i (tdo_awake),
    .pad_req_i (pad_req), .tdo_out_i (pad_out[TdoIdx]), .tdo_oe_i (pad_oe[TdoIdx]),
    .tap_req_i (lc_jtag_o), .tap_rsp_i (lc_jtag_i)
  );

  jtag_tap_chk #(.MaxLat (MaxLat)) u_rv (
    .clk_i, .rst_ni, .rst_sys_ni,
    .sel_i (sel_rv), .sel_may_i (sel_rv), .scan_i (scan), .tdo_awake_i (tdo_awake),
    .pad_req_i (pad_req), .tdo_out_i (pad_out[TdoIdx]), .tdo_oe_i (pad_oe[TdoIdx]),
    .tap_req_i (rv_jtag_o), .tap_rsp_i (rv_jtag_i)
  );

  jtag_tap_chk #(.MaxLat (MaxLat)) u_dft (
    .clk_i, .rst_ni, .rst_sys_ni,
    .sel_i (sel_dft), .sel_may_i (sel_may_dft), .scan_i (scan), .tdo_awake_i (tdo_awake),
    .pad_req_i (pad_req), .tdo_out_i (pad_out[TdoIdx]), .tdo_oe_i (pad_oe[TdoIdx]),
    .tap_req_i (dft_jtag_o), .tap_rsp_i (dft_jtag_i)
  );

  // Never two TAPs clocked at once.
  // REQ_TAP_06; jtag: at most one TAP; [SEC] TAP.MUX.LC_GATED
  assert_Jtag_AtMostOneTap : assert property ($onehot0({lc_jtag_o.tck, rv_jtag_o.tck,
                                                        dft_jtag_o.tck}));

  // The LC TAP is connected, then the DFT TAP.
  // REQ_TAP_01, 03; jtag: switch LC to DFT
  cover_Jtag_SwitchLcToDft : cover property (sel_lc ##1 sel_dft);

  // A clear drops a connected RV TAP.
  // REQ_DBGEN_03; latch: clear drops RV TAP
  cover_Latch_ClearDropsRvTap : cover property (sel_rv && clear);

  ////////////////////
  // Strap sampling //
  ////////////////////

  // Take conditions ([ToO] strap table): at the pulse (strap 1 only with debug On and no
  // clear), and while sampling is continuous: DFT On, no hold, no debug condition.
  logic cont, cont_may;
  logic [1:0] take, take_may, pad_strap;
  assign cont        = dft_on && !dft_hold_tap_sel_i;
  assign cont_may    = dft_may && !dft_hold_tap_sel_i;
  assign take[0]     = strap_en_i || cont;
  assign take_may[0] = strap_en_i || cont_may;
  assign take[1]     = (strap_en_i && dbg_on && !clear_may) || cont;
  assign take_may[1] = (strap_en_i && dbg_may && !clear) || cont_may;
  assign pad_strap   = {strap1, strap0};

  for (genvar s = 0; s < 2; s++) begin : gen_strap
    logic            boot_vld_q, boot_val_q, take_seen_q, pad_q;
    logic [AgeW-1:0] boot_age_q, stable_run_q, age_0_q, age_1_q, live_run;

    // Cycles of continuous sampling, this one included, in which the pad kept its value.
    assign live_run = !cont                   ? '0 :
                      pad_strap[s] == pad_q   ? age_next(1'b0, stable_run_q) : 1;

    logic            boot_take;
    assign boot_take = strap_en_i && take[s];

    always_ff @(posedge clk_i or negedge rst_sys_ni) begin
      if (!rst_sys_ni) begin
        boot_vld_q   <= 1'b0;
        boot_val_q   <= 1'b0;
        boot_age_q   <= '0;
        take_seen_q  <= 1'b0;
        pad_q        <= 1'b0;
        stable_run_q <= '0;
        age_0_q      <= '1;
        age_1_q      <= '1;
      end else begin
        // The value a pulse took, until another take may happen.
        if (boot_take)                       {boot_vld_q, boot_val_q, boot_age_q} <=
                                             {1'b1, pad_strap[s], AgeW'(0)};
        else if (take_may[s])                boot_vld_q <= 1'b0;
        else if (boot_age_q < MaxLat)   boot_age_q <= boot_age_q + 1'b1;
        if (take_may[s])                     take_seen_q <= 1'b1;
        pad_q        <= pad_strap[s];
        stable_run_q <= live_run;

        // Cycles since a take may have seen the pad at 0, and at 1.
        age_0_q      <= age_next(take_may[s] && !pad_strap[s], age_0_q);
        age_1_q      <= age_next(take_may[s] &&  pad_strap[s], age_1_q);
      end
    end

    // A strap a pulse took is the pad value of the pulse cycle, from MaxLat cycles on.
    // REQ_STRAP_01, 02; strap: bit 0 sampled at boot, bit 1 sampled at boot; [ToO] strap table;
    // DV reading: a strap is sampled at most MaxLat cycles after its pulse.
    assert_Strap_SampledAtBoot : assert property (boot_vld_q && boot_age_q >= MaxLat - 1 |->
                                                  tap_strap_i[s] == boot_val_q);

    // With the pad unchanged over N cycles of continuous sampling, the strap is the pad's value.
    // REQ_STRAP_03; strap: bit 0 sampled live, bit 1 sampled live; [ToO] "Sampled continuously";
    // DV reading: with continuous sampling, a strap follows its pad within N cycles.
    assert_Strap_SampledLive : assert property (live_run >= N |->
                                                tap_strap_i[s] == pad_strap[s]);

    // A strap changes only to a value its pad had in a cycle of the last MaxLat that may take it.
    // REQ_STRAP_02, 04, 06; strap: stable when unsampled
    assert_Strap_StableWhenUnsampled : assert property (
        !first_cycle_q && $changed(tap_strap_i[s]) |->
        tap_strap_i[s] ? (take_may[s] && pad_strap[s]) || age_1_q < MaxLat
                       : (take_may[s] && !pad_strap[s]) || age_0_q < MaxLat);

    // A strap no take may have sampled since the full reset reads 0.
    // REQ_STRAP_05; strap: bit 0 zero unsampled, bit 1 zero unsampled
    assert_Strap_ZeroUnsampled : assert property (!take_seen_q && !take_may[s] |->
                                                  !tap_strap_i[s]);
  end

  // A boot sample in DEV.
  // REQ_STRAP_01; strap: boot sample in DEV
  cover_Strap_BootSampleInDev : cover property (strap_en_i && dbg_on && !dft_may);

  // Continuous sampling changes both straps in one cycle.
  // REQ_STRAP_03; strap: continuous follows pads
  cover_Strap_ContinuousBoth : cover property (cont && $changed(tap_strap_i[0]) &&
                                               $changed(tap_strap_i[1]));

  ////////////////
  // DFT straps //
  ////////////////

  // The first pulse after a full reset with the DFT enable On takes the DFT strap pads; the
  // output then holds until the next full reset ([ToO] strap table "Once at boot").
  logic            dft_vld_q, dft_may_pulse, first_dft;
  logic [1:0]      dft_val_q;
  logic [AgeW-1:0] dft_age_q, dft_may_age_q;
  assign first_dft     = strap_en_i && !pulsed_q && dft_on;
  assign dft_may_pulse = strap_en_i && !pulsed_q && dft_may;

  always_ff @(posedge clk_i or negedge rst_sys_ni) begin
    if (!rst_sys_ni) begin
      dft_vld_q     <= 1'b0;
      dft_val_q     <= '0;
      dft_age_q     <= '0;
      dft_may_age_q <= '1;
    end else begin
      if (first_dft) {dft_vld_q, dft_val_q, dft_age_q} <= {1'b1, dft_strap1, dft_strap0,
                                                           AgeW'(0)};
      else if (dft_vld_q && dft_age_q < MaxLat) dft_age_q <= dft_age_q + 1'b1;
      dft_may_age_q <= age_next(dft_may_pulse, dft_may_age_q);
    end
  end

  // From MaxLat cycles after the first DFT On pulse, the output is valid with that cycle's pads.
  // REQ_DFT_01; dft_strap: DFT straps sampled at first sample; [ToO]
  assert_DftStrap_SampledAtFirstPulse : assert property (
      dft_vld_q && dft_age_q >= MaxLat - 1 |->
      dft_strap_test_o.valid && dft_strap_test_o.straps == dft_val_q);

  // Once valid, the output holds until the next reset.
  // REQ_DFT_02; dft_strap: DFT output held;
  // [ToO] "Once at boot"
  assert_DftStrap_OutputHeld : assert property (dft_strap_test_o.valid |=>
                                                $stable(dft_strap_test_o));

  // The output turns valid only within N cycles after a first pulse with DFT maybe On.
  // REQ_DFT_03; dft_strap: DFT output invalid before first sample; [ToO]
  assert_DftStrap_InvalidBeforeSample : assert property (
      !first_cycle_q && $rose(dft_strap_test_o.valid) |-> dft_may_pulse || dft_may_age_q < N);

  // Right after a full reset, with no pulse that may take the DFT straps, the output is invalid.
  // REQ_DFT_03; dft_strap: DFT output invalid before first sample; [ToO]
  assert_DftStrap_InvalidAtReset : assert property (first_cycle_q && !dft_may_pulse |->
                                                    !dft_strap_test_o.valid);

  // A test chip boot samples the DFT straps.
  // REQ_DFT_01; dft_strap: test chip boot
  cover_DftStrap_TestChipBoot : cover property (first_dft);

  ///////////////
  // JTAG pads //
  ///////////////

  // While some TAP's row has held for N cycles, the five JTAG pads belong to it; the checks below
  // say what that means for each pad ([ToO] JTAG IOs; DV reads it as: the pinmux drives none of
  // TCK, TMS, TDI and TRST_N, and peripherals read 0 on all five).
  localparam int unsigned NJtagPads = 5;
  localparam int unsigned JtagPad [NJtagPads] = '{TckIdx, TmsIdx, TrstIdx, TdiIdx, TdoIdx};
  localparam int unsigned AttrW = 14;  // *_PAD_ATTR fields

  // sel_n per TAP row: that row has held for N cycles, this one included; a switch to another
  // row starts that row's count again.
  logic [2:0]           row_sel, row_sel_n;
  logic [2:0][AgeW-1:0] sel_run_q;
  logic                 any_sel_n;
  assign row_sel = {sel_dft, sel_rv, sel_lc};

  for (genvar r = 0; r < 3; r++) begin : gen_sel_run
    always_ff @(posedge clk_i or negedge rst_sys_ni) begin
      if (!rst_sys_ni) sel_run_q[r] <= '0;
      else             sel_run_q[r] <= !row_sel[r] ? '0 : age_next(1'b0, sel_run_q[r]);
    end

    assign row_sel_n[r] = row_sel[r] && sel_run_q[r] >= N - 1;
  end

  assign any_sel_n = |row_sel_n;

  for (genvar j = 0; j < NJtagPads; j++) begin : gen_jtag_pad
    localparam int unsigned P = JtagPad[j];

    // A JTAG pad's attributes are zero while a TAP is connected, asleep or not.
    // REQ_JTAG_02; jtag_pad: JTAG pad attributes zero; [ToO] JTAG IOs
    assert_JtagPad_AttrZero : assert property (any_sel_n |-> mio_attr_o[P] == '0);

    // The pad's attribute fields as the hardware returns them to the register block.
    logic [AttrW-1:0] rdback;
    assign rdback = {hw2reg_i.mio_pad_attr[P].drive_strength.d,
                     hw2reg_i.mio_pad_attr[P].slew_rate.d,
                     hw2reg_i.mio_pad_attr[P].input_disable.d,
                     hw2reg_i.mio_pad_attr[P].od_en.d,
                     hw2reg_i.mio_pad_attr[P].schmitt_en.d,
                     hw2reg_i.mio_pad_attr[P].keeper_en.d,
                     hw2reg_i.mio_pad_attr[P].pull_select.d,
                     hw2reg_i.mio_pad_attr[P].pull_en.d,
                     hw2reg_i.mio_pad_attr[P].virtual_od_en.d,
                     hw2reg_i.mio_pad_attr[P].invert.d};

    // The attribute register changes only on a software write: the gating keeps it.
    // REQ_JTAG_02; jtag_pad: gating keeps registers; [ToO] JTAG IOs
    assert_JtagPad_GatingKeepsRegisters : assert property (!first_cycle_q && $changed(rdback) |->
        wr_done_i && wr_addr_i == reg_addr(MioAttrBase, P));

    // A peripheral input that selects a JTAG pad reads 0 while a TAP is connected.
    // REQ_JTAG_03; jtag_pad: peripherals read zero on JTAG pads
    for (genvar i = 0; i < NMioPeriphIn; i++) begin : gen_input
      // Select values 0 and 1 are the constants, so MIO pad P is select value P + 2.
      assert_JtagPad_PeriphReadsZero : assert property (
          any_sel_n && reg2hw_i.mio_periph_insel[i].q == P + 2 |->
          !mio_to_periph_o[i]);
    end

    if (P != TdoIdx) begin : gen_input_pad
      logic awake;
      assign awake = !reg2hw_i.mio_pad_sleep_status[P].q;

      // While awake, the pinmux does not drive TCK, TMS, TDI or TRST_N.
      // REQ_JTAG_04; jtag_pad: JTAG input pads undriven
      assert_JtagPad_InputPadUndriven : assert property (any_sel_n && awake |->
                                                         !pad_out[P] && !pad_oe[P]);
    end
  end

  // The LC TAP takes the pads.
  // REQ_JTAG_01 to 04; jtag_pad: LC TAP takes pads
  cover_JtagPad_LcTakesPads : cover property (sel_lc && any_sel_n);

endmodule : pinmux_jtag_harness
