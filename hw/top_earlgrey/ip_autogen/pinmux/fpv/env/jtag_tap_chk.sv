// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Checker for one TAP (life cycle, RISC-V or DFT), connected to the JTAG pads exactly while its
// row of the TAP table holds ([ToO] Strap Sampling and TAP Isolation). Once the row has held for N
// cycles, the TAP's request carries the pads and the TDO pad, while awake, its response (a DV
// reading); once the row has been off for N cycles, the request is all zero. In scan mode a
// connected TAP's TRST_N follows rst_ni instead of its pad. The rules are off while rst_sys_ni,
// the TAP logic's own reset, is low.
//
// sel_i is this TAP's row of the TAP table with its gate On for two cycles; sel_may_i the same
// with the gate On in one of them; N = MaxLat + 1.

// The resets are asynchronous in the flops and a disable condition in the properties.
/* verilator lint_off SYNCASYNCNET */
module jtag_tap_chk
  import jtag_pkg::*;
#(
  parameter int unsigned MaxLat = 4  // DV reading: cycles a TAP's request takes to follow its row
) (
  input logic      clk_i,
  input logic      rst_ni,       // TRST_N follows it in scan mode
  input logic      rst_sys_ni,
  input logic      sel_i,
  input logic      sel_may_i,
  input logic      scan_i,       // scanmode_i is True
  input logic      tdo_awake_i,  // the TDO pad's sleep status bit is 0

  // Pads
  input jtag_req_t pad_req_i,
  input logic      tdo_out_i,
  input logic      tdo_oe_i,

  // The TAP
  input jtag_req_t tap_req_i,
  input jtag_rsp_t tap_rsp_i
);

  default clocking @(posedge clk_i); endclocking
  default disable iff (!rst_sys_ni);

  localparam int unsigned N    = MaxLat + 1;
  localparam int unsigned RunW = $clog2(N + 1);

  // Cycles in a row the row has held (sel_run) and been off (idle_run), saturating at N, and
  // whether the row may have held since the reset (sel_seen).
  logic [RunW-1:0] sel_run_q, idle_run_q;
  logic            sel_seen_q;

  always_ff @(posedge clk_i or negedge rst_sys_ni) begin
    if (!rst_sys_ni) begin
      sel_run_q  <= '0;
      idle_run_q <= '0;
      sel_seen_q <= 1'b0;
    end else begin
      sel_run_q  <= !sel_i     ? '0 : (sel_run_q  < N ? sel_run_q  + 1'b1 : sel_run_q);
      idle_run_q <=  sel_may_i ? '0 : (idle_run_q < N ? idle_run_q + 1'b1 : idle_run_q);
      if (sel_may_i) sel_seen_q <= 1'b1;
    end
  end

  logic sel_n, idle_n;
  assign sel_n  = sel_i && sel_run_q >= N - 1;        // held for the last N cycles
  assign idle_n = !sel_may_i && idle_run_q >= N - 1;  // off for the last N cycles

  // The request's TRST_N: the pad out of scan mode, rst_ni in scan mode.
  logic trst_expected;
  assign trst_expected = scan_i ? rst_ni : pad_req_i.trst_n;

  // A connected TAP's request carries the pads.
  // REQ_TAP_01, 02, 03; jtag: pads drive connected TAP; [TP] *JtagWoScanmode_A
  assert_Jtag_PadsDriveConnectedTap : assert property (sel_n |->
      tap_req_i.tck == pad_req_i.tck && tap_req_i.tms == pad_req_i.tms &&
      tap_req_i.tdi == pad_req_i.tdi && (scan_i || tap_req_i.trst_n == pad_req_i.trst_n));

  // While awake, the TDO pad carries the connected TAP's response.
  // REQ_JTAG_01; jtag: TDO from connected TAP; [TP] *JtagI_A
  assert_Jtag_TdoFromConnectedTap : assert property (sel_n && tdo_awake_i |->
      tdo_out_i == tap_rsp_i.tdo && tdo_oe_i == tap_rsp_i.tdo_oe);

  // With scan mode on, a connected TAP's TRST_N follows rst_ni.
  // REQ_TAP_07; jtag: scan TRST follows reset; [TP] *JtagWScanmode_A
  assert_Jtag_ScanTrstFollowsReset : assert property (sel_n && scan_i |->
                                                      tap_req_i.trst_n == rst_ni);

  // A TAP whose row has been off for N cycles gets an all-zero request.
  // REQ_TAP_02 to 05, 08; jtag: unconnected TAP idle; [TP] *JtagODefault_A
  assert_Jtag_UnconnectedTapIdle : assert property (idle_n |-> tap_req_i == '0);

  // A TAP gets no request before its row ever may have held.
  // REQ_TAP_05; jtag: no request before connect; [ToO] TAP table
  assert_Jtag_NoReqBeforeConnect : assert property (tap_req_i != '0 |->
                                                    sel_may_i || sel_seen_q);

  // Every request bit is 0 or its pad bit; TRST_N in scan mode follows the reset instead.
  // REQ_TAP_01 to 03; jtag: request only from pads; [TP] *JtagOBackward_A
  assert_Jtag_ReqOnlyFromPads : assert property (
      (!tap_req_i.tck || tap_req_i.tck == pad_req_i.tck) &&
      (!tap_req_i.tms || tap_req_i.tms == pad_req_i.tms) &&
      (!tap_req_i.tdi || tap_req_i.tdi == pad_req_i.tdi) &&
      (!tap_req_i.trst_n || tap_req_i.trst_n == trst_expected));

  // A connected TAP sees TCK high.
  // REQ_TAP_01; jtag: connected TCK high
  cover_Jtag_ConnectedTckHigh : cover property (sel_n && tap_req_i.tck);

endmodule : jtag_tap_chk
