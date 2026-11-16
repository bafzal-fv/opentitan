// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Input-selection harness: every peripheral input reads the pad or constant its MIO_PERIPH_INSEL
// value names, and every DIO input reads its own pad. It decodes each select into one bit per
// pad and hands each pad to a pad_listen_chk; the constant and out-of-range selects are checked
// here. On the five JTAG pads the checks stand aside while a TAP may own them (the jtag harness
// says when); what the inputs read then is the JTAG pad checks' job. It also holds one lock
// checker per MIO_PERIPH_INSEL_REGWEN, proven in the register-lock task.
//
// Pads are numbered MIO 0 to NMioPads-1, then DIO NMioPads to NMioPads+NDioPads-1, the order of
// the top's pad indices.

// The resets are asynchronous in the flops and a disable condition in the properties.
/* verilator lint_off SYNCASYNCNET */
module pinmux_listen_harness
  import pinmux_pkg::*;
  import pinmux_reg_pkg::*;
  import pinmux_fpv_regmap_pkg::*;
#(
  parameter target_cfg_t TargetCfg = DefaultTargetCfg,

  // Inputs that may select each MIO pad. All ones: any input, any pad (EG2 restricts it).
  parameter logic [NMioPads-1:0][NMioPeriphIn-1:0] MioPeriphAllowed = '1
) (
  input logic                    clk_i,
  input logic                    rst_ni,
  input prim_mubi_pkg::mubi4_t   scanmode_i,

  // A TAP may own the JTAG pads (from the jtag harness)
  input logic                    tap_connected_i,

  // Pads and peripheral inputs
  input logic [NMioPads-1:0]     mio_in_i,
  input logic [NDioPads-1:0]     dio_in_i,
  input logic [NMioPeriphIn-1:0] mio_to_periph_o,
  input logic [NDioPads-1:0]     dio_to_periph_o,

  // Register values and the bus record (from the environment top)
  input pinmux_reg2hw_t          reg2hw_i,
  input logic                    wr_done_i,
  input logic [BlockAw-1:0]      wr_addr_i,
  input logic [3:0]              wr_mask_i,
  input logic [31:0]             wr_data_i,
  input logic                    rd_done_i,
  input logic [31:0]             rd_data_i
);

  default clocking @(posedge clk_i); endclocking
  default disable iff (!rst_ni);

  localparam int unsigned NPads            = NMioPads + NDioPads;
  localparam int unsigned PeriphInselWidth = $bits(pinmux_reg2hw_mio_periph_insel_mreg_t);

  /////////////////
  // Environment //
  /////////////////

  // Scan mode is off: the pad checks describe mission mode; scan mode is the DFT flow's to verify.
  assume_PadListen_ScanModeOff : assume property (scanmode_i != prim_mubi_pkg::MuBi4True);

  /////////////
  // Adapter //
  /////////////

  // MIO_PERIPH_INSEL of every peripheral input.
  logic [NMioPeriphIn-1:0][PeriphInselWidth-1:0] insel;
  for (genvar i = 0; i < NMioPeriphIn; i++) begin : gen_insel
    assign insel[i] = reg2hw_i.mio_periph_insel[i].q;
  end

  // Every pad's value by pad number: MIO pads first, then DIO pads.
  logic [NPads-1:0] pad_in;
  assign pad_in = {dio_in_i, mio_in_i};

  // The five JTAG pads, from the top's pad indices: one bit set per pad.
  localparam logic [NPads-1:0] JtagPads = (NPads'(1) << TargetCfg.tck_idx)  |
                                          (NPads'(1) << TargetCfg.tms_idx)  |
                                          (NPads'(1) << TargetCfg.trst_idx) |
                                          (NPads'(1) << TargetCfg.tdi_idx)  |
                                          (NPads'(1) << TargetCfg.tdo_idx);

  // MIO_PERIPH_INSEL: "0: tie constantly to zero, 1: tie constantly to 1, >=2: MIO pads (i.e.,
  // add 2 to the native MIO pad index)". Values past the last pad are out of range.
  logic [NMioPads-1:0][NMioPeriphIn-1:0] mio_sel;  // mio_sel[p][i]: input i selects pad p
  logic [NMioPeriphIn-1:0]               sel_tie0, sel_tie1, sel_out_of_range;
  always_comb begin
    for (int i = 0; i < NMioPeriphIn; i++) begin
      sel_tie0[i]         = insel[i] == PeriphInselWidth'(0);
      sel_tie1[i]         = insel[i] == PeriphInselWidth'(1);
      sel_out_of_range[i] = 32'(insel[i]) >= 2 + NMioPads;
      for (int p = 0; p < NMioPads; p++) begin
        mio_sel[p][i] = 32'(insel[i]) == p + 2;
      end
    end
  end

  ///////////////////
  // MIO pads      //
  ///////////////////

  // One checker per MIO pad; on a JTAG pad it stands aside while a TAP may own the pad.
  for (genvar p = 0; p < NMioPads; p++) begin : gen_mio_pad_listen
    pad_listen_chk #(
      .NPeriphIn     (NMioPeriphIn),
      .PeriphAllowed (MioPeriphAllowed[p])
    ) u_pad_listen (
      .clk_i,
      .rst_ni,
      .taken_i      (tap_connected_i && JtagPads[p]),
      .periph_in_i  (mio_to_periph_o),
      .periph_sel_i (mio_sel[p]),
      .pad_in_i     (pad_in[p])
    );
  end

  ///////////////////////////
  // Constant selections   //
  ///////////////////////////

  for (genvar i = 0; i < NMioPeriphIn; i++) begin : gen_mio_const
    // An input whose select is 0 reads constant 0.
    // REQ_IN_01; pad_listen: tie 0 reads zero; [REG] MIO_PERIPH_INSEL
    assert_PadListen_Tie0ReadsZero : assert property (sel_tie0[i] |->
                                                      mio_to_periph_o[i] == 1'b0);

    // An input whose select is 1 reads constant 1.
    // REQ_IN_02; pad_listen: tie 1 reads one; [REG] MIO_PERIPH_INSEL
    assert_PadListen_Tie1ReadsOne : assert property (sel_tie1[i] |->
                                                     mio_to_periph_o[i] == 1'b1);

    // An input whose select names no pad reads 0.
    // REQ_IN_04; pad_listen: bad select reads zero; [TP] InSelOOB_A
    assert_PadListen_BadSelReadsZero : assert property (sel_out_of_range[i] |->
                                                        mio_to_periph_o[i] == 1'b0);
  end

  ///////////////////
  // DIO pads      //
  ///////////////////

  // DIO input n reads DIO pad n ("MIO and DIO Signal Categories").
  for (genvar n = 0; n < NDioPads; n++) begin : gen_dio_pad_listen
    pad_listen_chk #(
      .NPeriphIn (1)
    ) u_pad_listen (
      .clk_i,
      .rst_ni,
      .taken_i      (tap_connected_i && JtagPads[NMioPads + n]),
      .periph_in_i  (dio_to_periph_o[n]),
      .periph_sel_i (1'b1),
      .pad_in_i     (pad_in[NMioPads + n])
    );
  end

  ////////////////////
  // Register locks //
  ////////////////////

  // MIO_PERIPH_INSEL_REGWEN[i] locks MIO_PERIPH_INSEL[i]; proven in the register-lock task.
  for (genvar i = 0; i < NMioPeriphIn; i++) begin : gen_lock_insel
    regwen_chk #(
      .AddrW      (BlockAw),
      .Width      (PeriphInselWidth),
      .RegwenAddr (reg_addr(InselRegwenBase, i)),
      // One protected register: the second RegAddr entry is unused.
      .RegAddr    ({addr_t'(0), reg_addr(InselBase, i)})
    ) u_regwen (
      .clk_i,
      .rst_ni,
      .wr_done_i,
      .wr_addr_i,
      .wr_mask_i,
      .wr_data_i,
      .rd_done_i,
      // The environment top's wr_addr_i is the offset of the request answered, read or write.
      .rd_addr_i   (wr_addr_i),
      .rd_data_i,
      .in_flight_i (1'b0),
      .value_i     (insel[i])
    );
  end

endmodule : pinmux_listen_harness
