// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Wakeup harness: the eight wakeup detectors, their cause bits and the wake request. Each detector
// is checked by a wkup_detector_chk on the always-on clock. This harness checks that the cause bits
// are 0 out of reset and change only when a set request or a software clear lands, that
// pin_wkup_req_o is their OR, that every detector setting software writes reaches the always-on
// domain within AonLat, and the wakeup register locks. It assumes that software changes a
// detector's settings only while it has the detector disabled, and that scan mode is off.
//
// Clocks: the detectors and the cause bits are on clk_aon_i, the default clock; the bus, the locks
// and the landing windows are on clk_i, and their properties name that clock.

// The resets are asynchronous in the flops and a disable condition in the properties.
/* verilator lint_off SYNCASYNCNET */
module pinmux_wakeup_harness
  import pinmux_pkg::*;
  import pinmux_reg_pkg::*;
  import pinmux_fpv_regmap_pkg::*;
#(
  parameter int unsigned WkLat  = 4,  // DV reading: AON cycles, detection to set request
  parameter int unsigned AonLat = 4,  // DV reading: AON cycles, write to landing in AON logic

  // Pads a detector may watch. All ones: every pad is wakeup capable (EG2 restricts it).
  parameter logic [NMioPads-1:0] MioWkupCapable = '1,
  parameter logic [NDioPads-1:0] DioWkupCapable = '1
) (
  input logic                  clk_aon_i,
  input logic                  rst_aon_ni,
  input logic                  clk_i,
  input logic                  rst_ni,
  input prim_mubi_pkg::mubi4_t scanmode_i,

  // Pads and the wake request
  input logic [NMioPads-1:0]   mio_in_i,
  input logic [NDioPads-1:0]   dio_in_i,
  input logic                  pin_wkup_req_o,

  // Register block's hardware interface
  input pinmux_reg2hw_t        reg2hw_i,
  input pinmux_hw2reg_t        hw2reg_i,

  // The bus request (for the settings assumption) and the bus record (from the environment top)
  input tlul_pkg::tl_h2d_t     tl_i,
  input logic                  wr_done_i,
  input logic [BlockAw-1:0]    wr_addr_i,
  input logic [3:0]            wr_mask_i,
  input logic [31:0]           wr_data_i,
  input logic                  rd_done_i,
  input logic [31:0]           rd_data_i
);

  // No default disable iff: the scan-mode rule has none, so each property names its reset.
  default clocking @(posedge clk_aon_i); endclocking

  // clk_i cycles per AON cycle: the formal run clocks clk_aon_i at a fifth of clk_i.
  localparam int unsigned AonRatio = 5;

  // AonLat AON cycles in clk_i cycles.
  localparam int unsigned LandCycles = AonLat * AonRatio;
  localparam int unsigned LandW      = $clog2(LandCycles + 2);

  // Widths of PADSEL and of one detector's settings as the lock check compares them.
  localparam int unsigned PadselW    = $bits(pinmux_reg2hw_wkup_detector_padsel_mreg_t);
  localparam int unsigned CfgW       = 1 + 3 + 1 + 1 + WkupCntWidth + PadselW;

  ////////////
  // Adapter //
  ////////////

  // Each detector's settings and cause bit, as the register block holds them.
  logic [NWkupDetect-1:0]                   en, filter, miodio, cause;
  logic [NWkupDetect-1:0][2:0]              mode;
  logic [NWkupDetect-1:0][WkupCntWidth-1:0] th;
  logic [NWkupDetect-1:0][PadselW-1:0]      padsel;

  for (genvar k = 0; k < NWkupDetect; k++) begin : gen_adapter
    assign en[k]     = reg2hw_i.wkup_detector_en[k].q;
    assign mode[k]   = reg2hw_i.wkup_detector[k].mode.q;
    assign filter[k] = reg2hw_i.wkup_detector[k].filter.q;
    assign miodio[k] = reg2hw_i.wkup_detector[k].miodio.q;
    assign th[k]     = reg2hw_i.wkup_detector_cnt_th[k].q;
    assign padsel[k] = reg2hw_i.wkup_detector_padsel[k].q;
    assign cause[k]  = reg2hw_i.wkup_cause[k].q;
  end

  // A request on the bus that writes register addr.
  function automatic logic writes(tlul_pkg::tl_h2d_t req, addr_t addr);
    return req.a_valid && req.a_address[BlockAw-1:0] == addr &&
           req.a_opcode inside {tlul_pkg::PutFullData, tlul_pkg::PutPartialData};
  endfunction

  /////////////////
  // Environment //
  /////////////////

  // Scan mode is off: in scan mode a scan clock pad reads 0 to the detectors.
  assume_Wakeup_ScanModeOff : assume property (scanmode_i != prim_mubi_pkg::MuBi4True);

  // Software's view of each detector's enable: its last accepted write.
  logic [NWkupDetect-1:0] en_written_q;

  for (genvar k = 0; k < NWkupDetect; k++) begin : gen_software_enable
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) en_written_q[k] <= 1'b0;
      else if (wr_done_i && wr_addr_i == reg_addr(WkupEnBase, k) && wr_mask_i[0])
        en_written_q[k] <= wr_data_i[0];
    end

    // Settings change only while software has the detector off; a later access waits for the write.
    assume_Wakeup_ConfigOnlyWhileOff : assume property (@(posedge clk_i) disable iff (!rst_ni)
        en_written_q[k] |-> !(writes(tl_i, reg_addr(WkupDetectorBase, k)) ||
                              writes(tl_i, reg_addr(WkupCntThBase, k)) ||
                              writes(tl_i, reg_addr(WkupPadselBase, k))));
  end

  ///////////////
  // Detectors //
  ///////////////

  for (genvar k = 0; k < NWkupDetect; k++) begin : gen_detect
    // A pad that is not wakeup capable (EG2): no claim is made on it.
    logic no_claim;

    if (MioWkupCapable == '1 && DioWkupCapable == '1) begin : gen_all_capable
      assign no_claim = 1'b0;
    end else begin : gen_sparse
      // PADSEL 2 + p is MIO pad p; with MIODIO set, n is DIO pad n.
      always_comb begin
        no_claim = 1'b0;
        for (int p = 0; p < NMioPads; p++) begin
          if (!miodio[k] && padsel[k] == p + 2 && !MioWkupCapable[p]) no_claim = 1'b1;
        end
        for (int n = 0; n < NDioPads; n++) begin
          if (miodio[k] && padsel[k] == n && !DioWkupCapable[n]) no_claim = 1'b1;
        end
      end
    end

    wkup_detector_chk #(
      .PadselW (PadselW),
      .WkLat   (WkLat)
    ) u_detector (
      .clk_aon_i,
      .rst_aon_ni,
      .mio_in_i,
      .dio_in_i,
      .en_i       (en[k]),
      .mode_i     (mode[k]),
      .filter_i   (filter[k]),
      .miodio_i   (miodio[k]),
      .padsel_i   (padsel[k]),
      .th_i       (th[k]),
      .no_claim_i (no_claim),
      .cause_de_i (hw2reg_i.wkup_cause[k].de),
      .cause_d_i  (hw2reg_i.wkup_cause[k].d)
    );
  end

  /////////////////////////
  // Cause bits, request //
  /////////////////////////

  // pin_wkup_req_o is the OR of the cause bits.
  // REQ_WKUP_15; wakeup: req is any cause; [TP] AonWkupO_A
  assert_Wakeup_ReqIsAnyCause : assert property (disable iff (!rst_aon_ni)
                                                 pin_wkup_req_o == (cause != '0));

  // The first cycle after reset, in each clock domain: a past value there is the reset's.
  logic first_cycle_q;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) first_cycle_q <= 1'b1;
    else         first_cycle_q <= 1'b0;
  end

  logic first_aon_cycle_q;
  always_ff @(posedge clk_aon_i or negedge rst_aon_ni) begin
    if (!rst_aon_ni) first_aon_cycle_q <= 1'b1;
    else             first_aon_cycle_q <= 1'b0;
  end

  // Every cause bit is 0 out of reset.
  // REQ_WKUP_13; wakeup: cause reset value; [REG] WKUP_CAUSE resval 0
  assert_Wakeup_CauseResetValue : assert property (disable iff (!rst_aon_ni)
                                                   first_aon_cycle_q |-> cause == '0);

  for (genvar k = 0; k < NWkupDetect; k++) begin : gen_cause
    logic set, set_q, clear_written;
    logic             clear_pending_q, set_seen_q, was_set_q, landed_q;
    logic [LandW-1:0] clear_age_q;

    assign set           = hw2reg_i.wkup_cause[k].de && hw2reg_i.wkup_cause[k].d;
    assign clear_written = wr_done_i && wr_addr_i == WkupCauseAddr && wr_mask_i[0] &&
                           !wr_data_i[k];

    always_ff @(posedge clk_aon_i or negedge rst_aon_ni) begin
      if (!rst_aon_ni) set_q <= 1'b0;
      else             set_q <= set;
    end

    // A software clear of the bit, accepted and not yet past its landing window.
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        clear_pending_q <= 1'b0;
        clear_age_q     <= '0;
        set_seen_q      <= 1'b0;
        was_set_q       <= 1'b0;
        landed_q        <= 1'b0;
      end else if (clear_written) begin
        clear_pending_q <= 1'b1;
        clear_age_q     <= '0;
        set_seen_q      <= set;
        was_set_q       <= cause[k];
        landed_q        <= 1'b0;
      end else if (clear_pending_q && clear_age_q < LandCycles) begin
        clear_age_q     <= clear_age_q + 1'b1;
        set_seen_q      <= set_seen_q || set;

        // The clear has landed once a bit that was 1 at the write reads 0.
        landed_q        <= landed_q || (was_set_q && !cause[k]);
      end else begin
        clear_pending_q <= 1'b0;
      end
    end

    // A set request makes the cause bit 1 in the next AON cycle unless a clear may still land.
    // REQ_WKUP_13; wakeup: cause set lands; [RG] hardware update
    assert_Wakeup_CauseSetLands : assert property (disable iff (!rst_aon_ni)
        set && !(clear_pending_q && !landed_q) |=> cause[k]);

    // The cause bit rises only when a set lands.
    // REQ_WKUP_13, 14; wakeup: cause changes only on a landed write; [REG] WKUP_CAUSE
    assert_Wakeup_CauseRisesOnlyOnSet : assert property (disable iff (!rst_aon_ni)
                                                         $rose(cause[k]) |-> set_q);

    // The cause bit falls only when a clear lands.
    // REQ_WKUP_13, 14; wakeup: cause changes only on a landed write; [REG] WKUP_CAUSE
    assert_Wakeup_CauseFallsOnlyOnClear : assert property (@(posedge clk_i) disable iff (!rst_ni)
        !first_cycle_q && $fell(cause[k]) |-> clear_pending_q);

    // A software write of 0 clears the bit within AonLat; windows with a set are left out.
    // REQ_WKUP_14; wakeup: software clear clears cause; [REG] rw0c
    assert_Wakeup_SoftwareClearClears : assert property (@(posedge clk_i) disable iff (!rst_ni)
        clear_pending_q && clear_age_q == LandCycles && !set_seen_q && !set && !set_q
        |-> !cause[k]);
  end

  //////////////////////////
  // AON settings landing //
  //////////////////////////

  // Every setting software writes to an AON-synced detector register is the value the AON domain
  // holds within AonLat: the landing half of the crossing (REQ_REG_04), proven here.
  for (genvar k = 0; k < NWkupDetect; k++) begin : gen_landing
    logic [2:0]             wrote, pending_q;
    logic [2:0][LandW-1:0]  age_q;
    logic [WkupCntWidth+4:0] expect_q [3];
    logic [WkupCntWidth+4:0] held [3];

    // Accepted writes to detector k's EN, DETECTOR and CNT_TH registers.
    assign wrote[0] = wr_done_i && wr_addr_i == reg_addr(WkupEnBase, k) && wr_mask_i[0];
    assign wrote[1] = wr_done_i && wr_addr_i == reg_addr(WkupDetectorBase, k) && wr_mask_i[0];
    assign wrote[2] = wr_done_i && wr_addr_i == reg_addr(WkupCntThBase, k) && wr_mask_i[0];

    // What the AON domain holds for each of the three, in the layout of the written data.
    assign held[0]  = en[k];
    assign held[1]  = {miodio[k], filter[k], mode[k]};
    assign held[2]  = th[k];

    for (genvar r = 0; r < 3; r++) begin : gen_reg
      always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
          pending_q[r] <= 1'b0;
          age_q[r]     <= '0;
          expect_q[r]  <= '0;
        end else if (wrote[r]) begin
          pending_q[r] <= 1'b1;
          age_q[r]     <= '0;
          expect_q[r]  <= (r == 0) ? wr_data_i[0] :
                          (r == 1) ? wr_data_i[4:0] :
                                     wr_data_i[WkupCntWidth-1:0];
        end else if (pending_q[r] && age_q[r] < LandCycles) begin
          age_q[r]     <= age_q[r] + 1'b1;
        end else begin
          pending_q[r] <= 1'b0;
        end
      end

      // The AON domain holds the written setting at the end of the landing window.
      // REQ_REG_04; wakeup: AON config lands; [REG] async
      assert_Wakeup_AonConfigLands : assert property (@(posedge clk_i) disable iff (!rst_ni)
          pending_q[r] && age_q[r] == LandCycles |-> held[r] == expect_q[r]);
    end
  end

  ////////////////////
  // Register locks //
  ////////////////////

  // WKUP_DETECTOR_REGWEN[k] locks detector k's settings. A write accepted while unlocked may
  // still be crossing when the lock closes (in_flight); the landing is checked above.
  for (genvar k = 0; k < NWkupDetect; k++) begin : gen_lock
    logic             lock_open_q, wrote_unlocked;
    logic             in_flight_q;
    logic [LandW-1:0] in_flight_age_q;

    localparam addr_t EnAddr       = reg_addr(WkupEnBase, k);
    localparam addr_t DetectorAddr = reg_addr(WkupDetectorBase, k);
    localparam addr_t CntThAddr    = reg_addr(WkupCntThBase, k);

    assign wrote_unlocked = wr_done_i && lock_open_q &&
                            wr_addr_i inside {EnAddr, DetectorAddr, CntThAddr};

    // The lock closes on a write of 0 to the detector's REGWEN.
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) lock_open_q <= 1'b1;
      else if (wr_done_i && wr_addr_i == reg_addr(WkupRegwenBase, k) && wr_mask_i[0] &&
               !wr_data_i[0]) lock_open_q <= 1'b0;
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        in_flight_q     <= 1'b0;
        in_flight_age_q <= '0;
      end else if (wrote_unlocked) begin
        in_flight_q     <= 1'b1;
        in_flight_age_q <= '0;
      end else if (in_flight_q && in_flight_age_q < LandCycles) begin
        in_flight_age_q <= in_flight_age_q + 1'b1;
      end else begin
        in_flight_q     <= 1'b0;
      end
    end

    // The environment top records one address for reads and writes alike.
    regwen_chk #(
      .AddrW        (BlockAw),
      .Width        (CfgW),
      .RegwenAddr   (reg_addr(WkupRegwenBase, k)),
      .CheckLanding (1'b0)
    ) u_regwen (
      .clk_i,
      .rst_ni,
      .wr_done_i,
      .wr_addr_i,
      .wr_mask_i,
      .wr_data_i,
      .rd_done_i,
      .rd_addr_i   (wr_addr_i),
      .rd_data_i,
      .in_flight_i (in_flight_q || wrote_unlocked),
      .value_i     ({en[k], mode[k], filter[k], miodio[k], th[k], padsel[k]})
    );
  end

  ////////////
  // Covers //
  ////////////

  // Detector 0 sets its cause in timed mode with threshold 255 (about 260 AON cycles deep).
  // REQ_WKUP_09; wakeup: threshold 255
  cover_Wakeup_TimedTh255 : cover property (disable iff (!rst_aon_ni)
      hw2reg_i.wkup_cause[0].de && mode[0] == 3'd3 && th[0] == '1);

  // The wake request rises.
  // REQ_WKUP_15; wakeup: request rises
  cover_Wakeup_ReqRise : cover property (disable iff (!rst_aon_ni) $rose(pin_wkup_req_o));

  // A software clear lands.
  // REQ_WKUP_14; wakeup: software clear
  cover_Wakeup_SoftwareClear : cover property (@(posedge clk_i) disable iff (!rst_ni)
                                               !first_cycle_q && $fell(cause[0]));

endmodule : pinmux_wakeup_harness
