// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Pad-output harness: what every pad drives awake and asleep, its attributes and their register
// locks, and the bus port's error answers and alert. Awake, a pad drives what MIO_OUTSEL names (a
// DIO pad its own peripheral). At a sleep entry with the pad's sleep enable set, the pinmux asks to
// set its sleep status bit; the pad then shows its sleep value until software clears it. A pad gets
// the attributes software reads back. The checks skip the five JTAG pads while a TAP may own them.
// Lock, bus and alert checks are proven in the register-lock tasks, others in the pad-output task.
//
// Pads are numbered MIO 0 to NMioPads-1, then DIO NMioPads to NMioPads+NDioPads-1. Attribute
// vectors follow the field order of *_PAD_ATTR: invert, virtual_od_en, pull_en, pull_select,
// keeper_en, schmitt_en, od_en, input_disable, slew_rate (2 bits), drive_strength (4 bits).

// The resets are asynchronous in the flops and a disable condition in the properties.
/* verilator lint_off SYNCASYNCNET */
module pinmux_output_harness
  import pinmux_pkg::*;
  import pinmux_reg_pkg::*;
  import pinmux_fpv_regmap_pkg::*;
  import prim_pad_wrapper_pkg::*;
#(
  parameter target_cfg_t TargetCfg    = DefaultTargetCfg,  // pad types and pad indices
  parameter int          TapStrap0Pad = -1,                // MIO pad of TAP strap 0 (-1: none)

  // Outputs each MIO pad may drive. All ones: any output on any pad (EG2 restricts it).
  parameter logic [NMioPads-1:0][NMioPeriphOut-1:0] MioOutAllowed = '1
) (
  input logic                          clk_i,
  input logic                          rst_ni,
  input prim_mubi_pkg::mubi4_t         scanmode_i,
  input logic                          sleep_en_i,          // from the power manager (level)
  input logic                          tap_connected_i,     // a TAP may own the JTAG pads

  // Peripheral outputs and pads
  input logic      [NMioPeriphOut-1:0] periph_to_mio_i,
  input logic      [NMioPeriphOut-1:0] periph_to_mio_oe_i,
  input logic      [NDioPads-1:0]      periph_to_dio_i,
  input logic      [NDioPads-1:0]      periph_to_dio_oe_i,
  input logic      [NMioPads-1:0]      mio_out_o,
  input logic      [NMioPads-1:0]      mio_oe_o,
  input pad_attr_t [NMioPads-1:0]      mio_attr_o,
  input logic      [NDioPads-1:0]      dio_out_o,
  input logic      [NDioPads-1:0]      dio_oe_o,
  input pad_attr_t [NDioPads-1:0]      dio_attr_o,

  // Register block's hardware interface
  input pinmux_reg2hw_t                reg2hw_i,
  input pinmux_hw2reg_t                hw2reg_i,

  // Bus events and the bus record (from the environment top)
  input logic                          tl_a_fire_i,
  input logic                          tl_d_fire_i,
  input logic                          tl_d_error_i,
  input logic                          wr_done_i,
  input logic      [BlockAw-1:0]       wr_addr_i,
  input logic      [3:0]               wr_mask_i,
  input logic      [31:0]              wr_data_i,
  input logic                          rd_done_i,
  input logic      [31:0]              rd_data_i,
  input logic                          malformed_i,          // a malformed request taken
  input logic                          malformed_answered_i, // its answer
  input logic                          test_req_i,           // a test write taken

  // Alert sender inputs (internal nets)
  input logic                          alert_req_i,
  input logic                          alert_test_i
);

  default clocking @(posedge clk_i); endclocking
  default disable iff (!rst_ni);

  localparam int unsigned NPads       = NMioPads + NDioPads;
  localparam int unsigned OutselWidth = $bits(pinmux_reg2hw_mio_outsel_mreg_t);
  localparam int unsigned AttrW       = 14;
  localparam int unsigned AlertLat    = 2;  // DV reading: cycles, test write to its pulse
  localparam int unsigned AgeW        = $clog2(AlertLat + 1);

  typedef struct packed {
    logic out;
    logic oe;
  } drive_t;

  /////////////////
  // Environment //
  /////////////////

  // Scan mode is off: the pad checks describe mission mode; scan mode is the DFT flow's to verify.
  assume_PadOutput_ScanModeOff : assume property (scanmode_i != prim_mubi_pkg::MuBi4True);

  /////////////
  // Adapter //
  /////////////

  drive_t [NPads-1:0]                     pad;               // what each pad drives
  logic   [NMioPads-1:0][OutselWidth-1:0] outsel;            // MIO_OUTSEL
  logic   [NPads-1:0]                     asleep;            // the pad's sleep status bit
  logic   [NPads-1:0]                     sleep_en;          // *_PAD_SLEEP_EN
  logic   [NPads-1:0][1:0]                sleep_mode;        // *_PAD_SLEEP_MODE
  logic   [NPads-1:0]                     status_de;         // hardware writes the status bit
  logic   [NPads-1:0]                     status_d;          // the value it writes
  logic   [NPads-1:0][AttrW-1:0]          attr_wmask;        // attribute bits software writes now
  logic   [NPads-1:0][AttrW-1:0]          attr_wdata;        // the value it writes
  logic   [NPads-1:0][AttrW-1:0]          attr_pad;          // attributes at the pad
  logic   [NPads-1:0][AttrW-1:0]          attr_rdback;       // what software reads back

  function automatic logic [AttrW-1:0] attr_of_pad(pad_attr_t a);
    return {a.drive_strength, a.slew_rate, a.input_disable, a.od_en, a.schmitt_en, a.keep_en,
            a.pull_select, a.pull_en, a.virt_od_en, a.invert};
  endfunction

  for (genvar p = 0; p < NMioPads; p++) begin : gen_mio_adapter
    assign pad[p]        = '{out: mio_out_o[p], oe: mio_oe_o[p]};
    assign outsel[p]     = reg2hw_i.mio_outsel[p].q;
    assign asleep[p]     = reg2hw_i.mio_pad_sleep_status[p].q;
    assign sleep_en[p]   = reg2hw_i.mio_pad_sleep_en[p].q;
    assign sleep_mode[p] = reg2hw_i.mio_pad_sleep_mode[p].q;
    assign status_de[p]  = hw2reg_i.mio_pad_sleep_status[p].de;
    assign status_d[p]   = hw2reg_i.mio_pad_sleep_status[p].d;
    assign attr_pad[p]   = attr_of_pad(mio_attr_o[p]);
    assign attr_wmask[p] = {{4{reg2hw_i.mio_pad_attr[p].drive_strength.qe}},
                            {2{reg2hw_i.mio_pad_attr[p].slew_rate.qe}},
                            reg2hw_i.mio_pad_attr[p].input_disable.qe,
                            reg2hw_i.mio_pad_attr[p].od_en.qe,
                            reg2hw_i.mio_pad_attr[p].schmitt_en.qe,
                            reg2hw_i.mio_pad_attr[p].keeper_en.qe,
                            reg2hw_i.mio_pad_attr[p].pull_select.qe,
                            reg2hw_i.mio_pad_attr[p].pull_en.qe,
                            reg2hw_i.mio_pad_attr[p].virtual_od_en.qe,
                            reg2hw_i.mio_pad_attr[p].invert.qe};
    assign attr_wdata[p] = {reg2hw_i.mio_pad_attr[p].drive_strength.q,
                            reg2hw_i.mio_pad_attr[p].slew_rate.q,
                            reg2hw_i.mio_pad_attr[p].input_disable.q,
                            reg2hw_i.mio_pad_attr[p].od_en.q,
                            reg2hw_i.mio_pad_attr[p].schmitt_en.q,
                            reg2hw_i.mio_pad_attr[p].keeper_en.q,
                            reg2hw_i.mio_pad_attr[p].pull_select.q,
                            reg2hw_i.mio_pad_attr[p].pull_en.q,
                            reg2hw_i.mio_pad_attr[p].virtual_od_en.q,
                            reg2hw_i.mio_pad_attr[p].invert.q};
    assign attr_rdback[p] = {hw2reg_i.mio_pad_attr[p].drive_strength.d,
                             hw2reg_i.mio_pad_attr[p].slew_rate.d,
                             hw2reg_i.mio_pad_attr[p].input_disable.d,
                             hw2reg_i.mio_pad_attr[p].od_en.d,
                             hw2reg_i.mio_pad_attr[p].schmitt_en.d,
                             hw2reg_i.mio_pad_attr[p].keeper_en.d,
                             hw2reg_i.mio_pad_attr[p].pull_select.d,
                             hw2reg_i.mio_pad_attr[p].pull_en.d,
                             hw2reg_i.mio_pad_attr[p].virtual_od_en.d,
                             hw2reg_i.mio_pad_attr[p].invert.d};
  end

  for (genvar n = 0; n < NDioPads; n++) begin : gen_dio_adapter
    localparam int unsigned P = NMioPads + n;
    assign pad[P]        = '{out: dio_out_o[n], oe: dio_oe_o[n]};
    assign asleep[P]     = reg2hw_i.dio_pad_sleep_status[n].q;
    assign sleep_en[P]   = reg2hw_i.dio_pad_sleep_en[n].q;
    assign sleep_mode[P] = reg2hw_i.dio_pad_sleep_mode[n].q;
    assign status_de[P]  = hw2reg_i.dio_pad_sleep_status[n].de;
    assign status_d[P]   = hw2reg_i.dio_pad_sleep_status[n].d;
    assign attr_pad[P]   = attr_of_pad(dio_attr_o[n]);
    assign attr_wmask[P] = {{4{reg2hw_i.dio_pad_attr[n].drive_strength.qe}},
                            {2{reg2hw_i.dio_pad_attr[n].slew_rate.qe}},
                            reg2hw_i.dio_pad_attr[n].input_disable.qe,
                            reg2hw_i.dio_pad_attr[n].od_en.qe,
                            reg2hw_i.dio_pad_attr[n].schmitt_en.qe,
                            reg2hw_i.dio_pad_attr[n].keeper_en.qe,
                            reg2hw_i.dio_pad_attr[n].pull_select.qe,
                            reg2hw_i.dio_pad_attr[n].pull_en.qe,
                            reg2hw_i.dio_pad_attr[n].virtual_od_en.qe,
                            reg2hw_i.dio_pad_attr[n].invert.qe};
    assign attr_wdata[P] = {reg2hw_i.dio_pad_attr[n].drive_strength.q,
                            reg2hw_i.dio_pad_attr[n].slew_rate.q,
                            reg2hw_i.dio_pad_attr[n].input_disable.q,
                            reg2hw_i.dio_pad_attr[n].od_en.q,
                            reg2hw_i.dio_pad_attr[n].schmitt_en.q,
                            reg2hw_i.dio_pad_attr[n].keeper_en.q,
                            reg2hw_i.dio_pad_attr[n].pull_select.q,
                            reg2hw_i.dio_pad_attr[n].pull_en.q,
                            reg2hw_i.dio_pad_attr[n].virtual_od_en.q,
                            reg2hw_i.dio_pad_attr[n].invert.q};
    assign attr_rdback[P] = {hw2reg_i.dio_pad_attr[n].drive_strength.d,
                             hw2reg_i.dio_pad_attr[n].slew_rate.d,
                             hw2reg_i.dio_pad_attr[n].input_disable.d,
                             hw2reg_i.dio_pad_attr[n].od_en.d,
                             hw2reg_i.dio_pad_attr[n].schmitt_en.d,
                             hw2reg_i.dio_pad_attr[n].keeper_en.d,
                             hw2reg_i.dio_pad_attr[n].pull_select.d,
                             hw2reg_i.dio_pad_attr[n].pull_en.d,
                             hw2reg_i.dio_pad_attr[n].virtual_od_en.d,
                             hw2reg_i.dio_pad_attr[n].invert.d};
  end

  // The five JTAG pads, from the top's pad indices: one bit set per pad.
  localparam logic [NPads-1:0] JtagPads = (1 << TargetCfg.tck_idx)  |
                                          (1 << TargetCfg.tms_idx)  |
                                          (1 << TargetCfg.trst_idx) |
                                          (1 << TargetCfg.tdi_idx)  |
                                          (1 << TargetCfg.tdo_idx);

  // taken(p): a TAP may own pad p.
  logic [NPads-1:0] taken;
  assign taken = tap_connected_i ? JtagPads : '0;

  // Attribute reset value ([REG] MIO_PAD_ATTR): 0, except pull_en on the TAP strap 0 pad.
  function automatic logic [NPads-1:0][AttrW-1:0] attr_reset_value();
    attr_reset_value = '0;
    for (int p = 0; p < NMioPads; p++) begin
      if (p == TapStrap0Pad) attr_reset_value[p][2] = 1'b1;
    end
  endfunction
  localparam logic [NPads-1:0][AttrW-1:0] AttrRst = attr_reset_value();

  // Inversion may not be omitted on a digital pad ([ToO] Generic Pad Wrapper).
  function automatic logic [NPads-1:0] invert_required();
    for (int p = 0; p < NMioPads; p++) begin
      invert_required[p] = TargetCfg.mio_pad_type[p] != AnalogIn0;
    end
    for (int n = 0; n < NDioPads; n++) begin
      invert_required[NMioPads + n] = TargetCfg.dio_pad_type[n] != AnalogIn0;
    end
  endfunction
  localparam logic [NPads-1:0] InvertRequired = invert_required();

  // 1 in the first cycle after any reset.
  logic first_cycle_q;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) first_cycle_q <= 1'b1;
    else         first_cycle_q <= 1'b0;
  end

  ////////////////
  // Output mux //
  ////////////////

  // MIO_OUTSEL: "0: tie constantly to zero, 1: tie constantly to 1, 2: high-Z, >=3: peripheral
  // outputs (i.e., add 3 to the native peripheral pad index)"; larger selects drive nothing.
  function automatic drive_t outsel_drive(logic [OutselWidth-1:0]   sel,
                                          logic [NMioPeriphOut-1:0] out,
                                          logic [NMioPeriphOut-1:0] oe);
    if (sel == 0) return '{out: 1'b0, oe: 1'b1};
    if (sel == 1) return '{out: 1'b1, oe: 1'b1};
    for (int k = 0; k < NMioPeriphOut; k++) begin
      if (sel == k + 3) return '{out: out[k], oe: oe[k]};
    end
    return '{out: 1'b0, oe: 1'b0};
  endfunction

  // The select field can hold codes past the last peripheral output.
  localparam bit HasOutOfRange = 2 ** OutselWidth > 3 + NMioPeriphOut;

  for (genvar p = 0; p < NMioPads; p++) begin : gen_mio_pad
    drive_t expected;
    logic   selects_periph, selects_excluded, awake;
    assign expected         = outsel_drive(outsel[p], periph_to_mio_i, periph_to_mio_oe_i);
    assign selects_periph   = outsel[p] inside {[3 : 2 + NMioPeriphOut]};
    assign selects_excluded = selects_periph && !MioOutAllowed[p][outsel[p] - 3];
    assign awake            = !asleep[p] && !taken[p];

    // Awake, a pad drives what MIO_OUTSEL selects.
    // REQ_OUT_01 to 06; pad_output: drives selection; [REG] MIO_OUTSEL
    assert_PadOutput_DrivesSelection : assert property (awake && !selects_excluded |->
                                                        pad[p] == expected);

    if (MioOutAllowed[p] != '1) begin : gen_sparse
      // Awake, a pad whose select names an output its list excludes is not driven.
      // REQ_EG2_02; sparse_outsel: illegal output disables pad; [RFC]
      assert_PadOutput_IllegalOutDisablesPad : assert property (awake && selects_excluded |->
                                                                !pad[p].oe);
    end

    // A pad selects constant 0.
    // REQ_OUT_01; pad_output: select tie 0
    cover_PadOutput_SelTie0 : cover property (awake && outsel[p] == 0);

    // A pad selects constant 1.
    // REQ_OUT_02; pad_output: select tie 1
    cover_PadOutput_SelTie1 : cover property (awake && outsel[p] == 1);

    // A pad selects high-Z.
    // REQ_OUT_03; pad_output: select high-Z
    cover_PadOutput_SelHighZ : cover property (awake && outsel[p] == 2);

    // A pad selects a peripheral output.
    // REQ_OUT_04; pad_output: peripheral select
    cover_PadOutput_SelPeriph : cover property (awake && selects_periph);

    if (HasOutOfRange) begin : gen_out_of_range
      // A pad has a select past the last output.
      // REQ_OUT_05; pad_output: select out of range
      cover_PadOutput_SelOutOfRange : cover property (awake &&
                                                      outsel[p] >= 3 + NMioPeriphOut);
    end

    // The selected peripheral turns the pad's output enable on.
    // REQ_OUT_04; pad_output: peripheral oe toggle
    cover_PadOutput_PeriphOeToggle : cover property (awake && selects_periph && $rose(pad[p].oe));
  end

  for (genvar n = 0; n < NDioPads; n++) begin : gen_dio_pad
    // Awake, a DIO pad drives its own peripheral's output and enable.
    // REQ_OUT_06; pad_output: DIO driven by peripheral; [ToO] MIO and DIO Signal Categories
    assert_PadOutput_DioDrivenByPeriph : assert property (
        !asleep[NMioPads + n] && !taken[NMioPads + n] |->
        dio_out_o[n] == periph_to_dio_i[n] && dio_oe_o[n] == periph_to_dio_oe_i[n]);
  end

  /////////////////////
  // Sleep retention //
  /////////////////////

  // Sleep modes ([REG] *_PAD_SLEEP_MODE): 0 tie-low, 1 tie-high, 2 high-Z, 3 keep the value
  // driven in the cycle of the set request.
  function automatic drive_t sleep_drive(logic [1:0] mode, drive_t now);
    if (mode == 0) return '{out: 1'b0, oe: 1'b1};
    if (mode == 1) return '{out: 1'b1, oe: 1'b1};
    if (mode == 2) return '{out: 1'b0, oe: 1'b0};
    return now;
  endfunction

  // A sleep entry is a rise of sleep_en_i after reset; a level already 1 when reset ends is no
  // entry, so the previous value starts at 1.
  logic sleep_en_q, entry;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) sleep_en_q <= 1'b1;
    else         sleep_en_q <= sleep_en_i;
  end

  assign entry = sleep_en_i && !sleep_en_q;

  for (genvar p = 0; p < NPads; p++) begin : gen_pad_sleep
    // Status register and bit of each pad, for the software clear.
    localparam addr_t       StatusAddr = (p < NMioPads) ?
                                         reg_addr(MioSleepStatusBase, p / 32) :
                                         reg_addr(DioSleepStatusBase, (p - NMioPads) / 32);
    localparam int unsigned StatusBit  = (p < NMioPads) ? p % 32 : (p - NMioPads) % 32;

    logic   activate, hw_set, activate_pending_q;
    logic   apply_q, hold_q, set_since_req_q;
    drive_t sleep_value_q, pad_q;
    assign activate = entry && sleep_en[p];
    assign hw_set   = status_de[p] && status_d[p];

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        activate_pending_q <= 1'b0;
        apply_q            <= 1'b0;
        hold_q             <= 1'b0;
        set_since_req_q    <= 1'b0;
        sleep_value_q      <= '0;
        pad_q              <= '0;
      end else begin
        activate_pending_q <= activate && !hw_set;  // the request may come one cycle later
        apply_q            <= hw_set && !taken[p];
        hold_q             <= asleep[p] && !hw_set && !taken[p];
        // A set request in the cycle a bus request is accepted or later, until the next one:
        // the clear lands at the accept, the answer may come cycles later (d_ready low).
        set_since_req_q    <= tl_a_fire_i ? hw_set : (set_since_req_q || hw_set);
        sleep_value_q      <= sleep_drive(sleep_mode[p], pad[p]);
        pad_q              <= pad[p];
      end
    end

    // At an entry with the enable, the pinmux asks to set the status bit, that cycle or the next.
    // REQ_SLP_01; pad_sleep: status set on entry; [REG] *_PAD_SLEEP_EN
    assert_PadSleep_StatusSetOnEntry : assert property (activate_pending_q |-> hw_set);

    // It asks only for an entry with the enable, once; checked from the second cycle, since the
    // init-value abstraction frees the enable in the first, a state its reset value 0 never gives.
    // REQ_SLP_02; pad_sleep: status set on entry; [REG] *_PAD_SLEEP_EN
    assert_PadSleep_StatusSetOnlyOnEntry : assert property (!first_cycle_q && hw_set |->
                                                            activate || activate_pending_q);

    // Hardware never asks to clear a status bit.
    // REQ_SLP_03; pad_sleep: no hardware clear; [REG] rw0c
    assert_PadSleep_NoHwClear : assert property (status_de[p] |-> status_d[p]);

    // The cycle after a set request, the pad shows its sleep value.
    // REQ_SLP_05, 06; pad_sleep: applied on entry; [REG] *_PAD_SLEEP_MODE
    assert_PadSleep_AppliedOnEntry : assert property (apply_q && asleep[p] && !taken[p] |->
                                                      pad[p] == sleep_value_q);

    // While the bit stays 1 and no set comes, the pad keeps its value.
    // REQ_SLP_07; pad_sleep: held until cleared; [PG] Sleep Features
    assert_PadSleep_HeldUntilCleared : assert property (hold_q && asleep[p] && !taken[p] |->
                                                        pad[p] == pad_q);

    // An accepted software write of 0 to the bit, with no set from its accept to its answer,
    // clears it.
    // REQ_SLP_04, 08; pad_sleep: software clear releases; [REG] rw0c
    assert_PadSleep_SoftwareClearReleases : assert property (
        wr_done_i && wr_addr_i == StatusAddr && wr_mask_i[StatusBit / 8] &&
        !wr_data_i[StatusBit] && !set_since_req_q && !hw_set |-> !asleep[p]);

    // A second entry while the pad is already asleep.
    // REQ_SLP_05; pad_sleep: re-entry
    cover_PadSleep_ReEntry : cover property (asleep[p] && hw_set);

    // Keep mode captures a high-Z pad.
    // REQ_SLP_06; pad_sleep: keep high-Z
    cover_PadSleep_KeepHighZ : cover property (hw_set && sleep_mode[p] == 3 && !pad[p].oe);

    // Software releases a sleeping pad.
    // REQ_SLP_08; pad_sleep: release
    cover_PadSleep_Release : cover property ($fell(asleep[p]));
  end

  ////////////////////
  // Pad attributes //
  ////////////////////

  // *_PAD_ATTR is WARL: a pad keeps a fixed set of bits; inversion is always kept. Kept and
  // dropped are measured at the read-back.
  for (genvar p = 0; p < NPads; p++) begin : gen_pad_attr
    logic [AttrW-1:0] wrote_0_q, wrote_1_q, attr_q, kept_q, dropped_q, not_written;
    logic             taken_q;
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        wrote_0_q <= '0;
        wrote_1_q <= '0;
        attr_q    <= '0;
        kept_q    <= '0;
        dropped_q <= '0;
        taken_q   <= 1'b0;
      end else begin
        wrote_0_q <= attr_wmask[p] & ~attr_wdata[p];
        wrote_1_q <= attr_wmask[p] &  attr_wdata[p];
        attr_q    <= attr_pad[p];
        kept_q    <= kept_q    | (wrote_1_q &  attr_rdback[p]);
        dropped_q <= dropped_q | (wrote_1_q & ~attr_rdback[p]);
        taken_q   <= taken[p];
      end
    end

    assign not_written = ~(wrote_0_q | wrote_1_q);

    // The pad gets the attributes software reads back.
    // REQ_ATTR_01; pad_attr: readback matches pad; [PG] Pad Attributes
    assert_PadAttr_ReadbackMatchesPad : assert property (!taken[p] |->
                                                         attr_rdback[p] == attr_pad[p]);

    // A bit written 0 is 0 at the pad.
    // REQ_ATTR_02; pad_attr: written zero stays zero; [PG] WARL
    assert_PadAttr_WrittenZeroStaysZero : assert property (!taken[p] |->
                                                           (attr_pad[p] & wrote_0_q) == '0);

    // A bit's support never changes: a written 1 is always kept or always dropped.
    // REQ_ATTR_03; pad_attr: mask fixed; [PG] WARL
    assert_PadAttr_MaskFixed : assert property ((kept_q & dropped_q) == '0);

    // A bit nothing writes keeps its value.
    // REQ_ATTR_05; pad_attr: unwritten bits hold
    assert_PadAttr_UnwrittenBitsHold : assert property (
        !first_cycle_q && !taken_q && !taken[p] |->
        (attr_pad[p] & not_written) == (attr_q & not_written));

    // Out of reset the attributes are their reset value.
    // REQ_ATTR_06; pad_attr: reset value; [REG] MIO_PAD_ATTR resval
    assert_PadAttr_ResetValue : assert property (first_cycle_q && !taken[p] |->
                                                 attr_pad[p] == AttrRst[p]);

    if (InvertRequired[p]) begin : gen_invert
      // A 1 written to the invert bit is kept.
      // REQ_ATTR_04; pad_attr: invert write kept; [ToO] Generic Pad Wrapper
      assert_PadAttr_InvertWriteKept : assert property (wrote_1_q[0] && !taken[p] |->
                                                        attr_pad[p][0]);
    end

    // A written 1 is kept on some bit.
    // REQ_ATTR_03; pad_attr: some bit kept
    cover_PadAttr_SomeBitKept : cover property (|kept_q);

    // A written 1 is dropped on some bit.
    // REQ_ATTR_03; pad_attr: some bit dropped
    cover_PadAttr_SomeBitDropped : cover property (|dropped_q);

    // Software writes a 0 to a bit.
    // REQ_ATTR_02; pad_attr: written zero
    cover_PadAttr_WrittenZero : cover property (|wrote_0_q && !taken[p]);
  end

  ////////////////////
  // Register locks //
  ////////////////////

  // Reads and writes share the bus record's one address, and these registers are on the main
  // clock, so no write is ever in flight.

  // MIO_OUTSEL_REGWEN[p] locks MIO_OUTSEL[p].
  for (genvar p = 0; p < NMioPads; p++) begin : gen_lock_outsel
    regwen_chk #(
      .AddrW      (BlockAw),
      .Width      (OutselWidth),
      .RegwenAddr (reg_addr(OutselRegwenBase, p)),
      .RegAddr    ({addr_t'(0), reg_addr(OutselBase, p)})
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
      .in_flight_i (1'b0),
      .value_i     (outsel[p])
    );
  end

  // *_PAD_ATTR_REGWEN[p] locks *_PAD_ATTR[p]; the value is what software reads back, and
  // pad_attr decides which written bits land.
  for (genvar p = 0; p < NPads; p++) begin : gen_lock_attr
    localparam addr_t RegwenAddr = (p < NMioPads) ? reg_addr(MioAttrRegwenBase, p) :
                                                    reg_addr(DioAttrRegwenBase, p - NMioPads);
    regwen_chk #(
      .AddrW        (BlockAw),
      .Width        (AttrW),
      .RegwenAddr   (RegwenAddr),
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
      .in_flight_i (1'b0),
      .value_i     (attr_rdback[p])
    );
  end

  // *_PAD_SLEEP_REGWEN[p] locks *_PAD_SLEEP_EN[p] and *_PAD_SLEEP_MODE[p], not the status.
  for (genvar p = 0; p < NPads; p++) begin : gen_lock_sleep
    localparam bit    Mio        = p < NMioPads;
    localparam int    Idx        = Mio ? p : p - NMioPads;
    localparam addr_t RegwenAddr = reg_addr(Mio ? MioSleepRegwenBase : DioSleepRegwenBase, Idx);
    localparam addr_t EnAddr     = reg_addr(Mio ? MioSleepEnBase : DioSleepEnBase, Idx);
    localparam addr_t ModeAddr   = reg_addr(Mio ? MioSleepModeBase : DioSleepModeBase, Idx);
    regwen_chk #(
      .AddrW      (BlockAw),
      .Width      (3),
      .RegwenAddr (RegwenAddr),
      .NumRegs    (2),
      .RegAddr    ({ModeAddr, EnAddr}),
      .Reg0Width  (1),
      .Reg1Width  (2)
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
      .in_flight_i (1'b0),
      .value_i     ({sleep_mode[p], sleep_en[p]})
    );
  end

  /////////
  // Bus //
  /////////

  // The software view on the main clock: every field software writes, and the external attribute
  // and alert-test write strobes. Hardware-written and always-on fields are another rule's.
  localparam int unsigned AttrQeW = NPads * AttrW;
  logic [AttrQeW-1:0] attr_strobes;
  for (genvar p = 0; p < NPads; p++) begin : gen_attr_strobes
    assign attr_strobes[p * AttrW +: AttrW] = attr_wmask[p];
  end

  // The range ends at :0, not -1:0: one bit more, for the alert-test strobe.
  logic [$bits(reg2hw_i.mio_periph_insel) + $bits(reg2hw_i.mio_outsel) +
         $bits(reg2hw_i.mio_pad_sleep_en) + $bits(reg2hw_i.mio_pad_sleep_mode) +
         $bits(reg2hw_i.dio_pad_sleep_en) + $bits(reg2hw_i.dio_pad_sleep_mode) +
         $bits(reg2hw_i.wkup_detector_padsel) + AttrQeW:0] software_view;
  assign software_view = {reg2hw_i.mio_periph_insel, reg2hw_i.mio_outsel,
                          reg2hw_i.mio_pad_sleep_en, reg2hw_i.mio_pad_sleep_mode,
                          reg2hw_i.dio_pad_sleep_en, reg2hw_i.dio_pad_sleep_mode,
                          reg2hw_i.wkup_detector_padsel, attr_strobes,
                          reg2hw_i.alert_test.qe};

  // A malformed request gets an error answer.
  // REQ_BUS_02; bus: malformed request refused; [TLUL] Explicit Error Cases
  assert_Bus_MalformedRequestRefused : assert property (malformed_answered_i |-> tl_d_error_i);

  // A malformed request changes no field software can write and fires no alert test.
  // REQ_BUS_02; bus: malformed write changes nothing; [TLUL] Explicit Error Cases
  assert_Bus_MalformedWriteIgnored : assert property (malformed_i |=> $stable(software_view));

  // A malformed request is answered.
  // REQ_BUS_02; bus: undefined opcode
  cover_Bus_MalformedAnswered : cover property (malformed_answered_i);

  ///////////
  // Alert //
  ///////////

  // The test input: each test write gives one pulse within AlertLat (it may come in the cycle the
  // request is taken), none without one, and none once the test enable is cleared.

  // The TB's own copy of ALERT_TEST.regwen, whose bit AlertTestRegwenBit is in byte lane 3.
  logic test_en_q;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) test_en_q <= 1'b1;
    else if (wr_done_i && wr_addr_i == AlertTestAddr && wr_mask_i[3] &&
             !wr_data_i[AlertTestRegwenBit]) test_en_q <= 1'b0;
  end

  logic            test_take, test_pending_q;
  logic [AgeW-1:0] test_age_q;
  assign test_take = test_req_i && test_en_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      test_pending_q <= 1'b0;
      test_age_q     <= '0;
    end else if (test_take && !alert_test_i) begin
      test_pending_q <= 1'b1;
      test_age_q     <= '0;
    end else if (test_pending_q && (alert_test_i || (tl_d_fire_i && tl_d_error_i))) begin
      test_pending_q <= 1'b0;  // answered by the pulse, or refused with an error
    end else if (test_pending_q) begin
      test_age_q     <= test_age_q + 1'b1;
    end
  end

  // A test write gives a pulse on the alert test input within AlertLat.
  // REQ_BUS_03; alert: alert test raises alert; [REG] ALERT_TEST
  assert_Alert_TestRaisesAlert : assert property (test_pending_q |->
                                                  test_age_q < AlertLat);

  // No test pulse without a pending test write: one write, one pulse.
  // REQ_BUS_04; alert: no alert without cause; [IF] fatal_fault
  assert_Alert_NoTestWithoutWrite : assert property (alert_test_i |->
                                                     test_take || test_pending_q);

  // Once software clears the test enable, no test pulse.
  // REQ_BUS_03; alert: locked alert test silent; [REG] ALERT_TEST.regwen
  assert_Alert_LockedTestSilent : assert property (!test_en_q |-> !alert_test_i);

  // The request input: no alert request on a bus that has been quiet since reset. Which codes are
  // bad waits on the integrity scheme.
  logic any_request_q;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni)          any_request_q <= 1'b0;
    else if (tl_a_fire_i) any_request_q <= 1'b1;
  end

  // No alert request on a bus quiet since reset.
  // REQ_BUS_04; alert: no alert without cause; [IF] fatal_fault
  assert_Alert_NoRequestOnQuietBus : assert property (alert_req_i |->
                                                      any_request_q || tl_a_fire_i);

  // A test write raises a test pulse.
  // REQ_BUS_03; alert: alert test
  cover_Alert_TestPulse : cover property (alert_test_i);

  // A write of 0 to the test enable, then a test write.
  // REQ_BUS_03; alert: test after lock
  cover_Alert_TestAfterLock : cover property (!test_en_q && test_req_i);

endmodule : pinmux_output_harness
