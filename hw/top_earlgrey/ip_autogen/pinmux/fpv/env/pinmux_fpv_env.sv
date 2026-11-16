// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Top of the pinmux formal environment, bound into pinmux by pinmux_fpv_env_bind. It takes every
// pinmux port as an input, with the same names and template flags, plus the few internal nets the
// checks observe. It holds what every checker shares at the edge of the design: the TL-UL
// assertion-based VIP on the bus port and a record of each bus request and its answer. Each
// feature is checked in its own harness, one per proof task.
//
// tl_* are the bus events the VIP exports; wr_*, rd_* describe a write or read in the cycle of its
// answer; a malformed request has an undefined opcode, or an address, size and mask that disagree.

module pinmux_fpv_env
  import pinmux_pkg::*;
  import pinmux_reg_pkg::*;
  import prim_pad_wrapper_pkg::*;
  import pinmux_fpv_regmap_pkg::AlertTestAddr;
#(
  parameter target_cfg_t TargetCfg = DefaultTargetCfg
) (
  // The pinmux ports, under their own names: the bind connects them with .*.
  input                            clk_i,
  input                            rst_ni,
  input                            rst_sys_ni,
  input  prim_mubi_pkg::mubi4_t    scanmode_i,
  input                            clk_aon_i,
  input                            rst_aon_ni,
  input                            pin_wkup_req_o,
  input                            usb_wkup_req_o,
  input                            sleep_en_i,
  input                            strap_en_i,
  input  lc_ctrl_pkg::lc_tx_t      lc_dft_en_i,
  input  lc_ctrl_pkg::lc_tx_t      lc_hw_debug_clr_i,
  input  lc_ctrl_pkg::lc_tx_t      lc_hw_debug_en_i,
  input  lc_ctrl_pkg::lc_tx_t      lc_check_byp_en_i,
  input  lc_ctrl_pkg::lc_tx_t      lc_escalate_en_i,
  input  lc_ctrl_pkg::lc_tx_t      pinmux_hw_debug_en_o,
  input  dft_strap_test_req_t      dft_strap_test_o,
  input                            dft_hold_tap_sel_i,
  input  jtag_pkg::jtag_req_t      lc_jtag_o,
  input  jtag_pkg::jtag_rsp_t      lc_jtag_i,
  input  jtag_pkg::jtag_req_t      rv_jtag_o,
  input  jtag_pkg::jtag_rsp_t      rv_jtag_i,
  input  jtag_pkg::jtag_req_t      dft_jtag_o,
  input  jtag_pkg::jtag_rsp_t      dft_jtag_i,
  input                            usbdev_dppullup_en_i,
  input                            usbdev_dnpullup_en_i,
  input                            usb_dppullup_en_o,
  input                            usb_dnpullup_en_o,
  input                            usbdev_suspend_req_i,
  input                            usbdev_wake_ack_i,
  input                            usbdev_bus_not_idle_o,
  input                            usbdev_bus_reset_o,
  input                            usbdev_sense_lost_o,
  input                            usbdev_wake_detect_active_o,
  input  tlul_pkg::tl_h2d_t        tl_i,
  input  tlul_pkg::tl_d2h_t        tl_o,
  input        [NMioPeriphOut-1:0] periph_to_mio_i,
  input        [NMioPeriphOut-1:0] periph_to_mio_oe_i,
  input  logic [NMioPeriphIn-1:0]  mio_to_periph_o,
  input        [NDioPads-1:0]      periph_to_dio_i,
  input        [NDioPads-1:0]      periph_to_dio_oe_i,
  input  logic [NDioPads-1:0]      dio_to_periph_o,
  input  prim_pad_wrapper_pkg::pad_attr_t [NMioPads-1:0] mio_attr_o,
  input  logic                            [NMioPads-1:0] mio_out_o,
  input  logic                            [NMioPads-1:0] mio_oe_o,
  input                                   [NMioPads-1:0] mio_in_i,
  input  prim_pad_wrapper_pkg::pad_attr_t [NDioPads-1:0] dio_attr_o,
  input  logic                            [NDioPads-1:0] dio_out_o,
  input  logic                            [NDioPads-1:0] dio_oe_o,
  input                                   [NDioPads-1:0] dio_in_i,

  // Ports no check reads yet: the strap override has no effect in this configuration, and the
  // alert handshake belongs to the alert sender's own proof.
  /* verilator lint_off UNUSEDSIGNAL */
  input                            strap_en_override_i,
  input  prim_alert_pkg::alert_rx_t [NumAlerts-1:0] alert_rx_i,
  input  prim_alert_pkg::alert_tx_t [NumAlerts-1:0] alert_tx_o,
  /* verilator lint_on UNUSEDSIGNAL */

  // Internal pinmux nets, connected by the bind (not ports of pinmux): the sampled TAP straps and
  // the alert sender's request and test inputs.
  input  logic           [NTapStraps-1:0] tap_strap_i,
  input  logic                            alert_req_i,
  input  logic                            alert_test_i,

  // Internal: the clock, reset and ports of the USB wakeup module, usbdev_aon_wake.
  input  logic                            aon_wake_clk_i,
  input  logic                            aon_wake_rst_ni,
  input  logic                            aon_wake_usb_dp_i,
  input  logic                            aon_wake_usb_dn_i,
  input  logic                            aon_wake_usb_sense_i,
  input  logic                            aon_wake_usbdev_dppullup_en_i,
  input  logic                            aon_wake_usbdev_dnpullup_en_i,
  input  logic                            aon_wake_suspend_req_aon_i,
  input  logic                            aon_wake_wake_ack_aon_i,
  input  logic                            aon_wake_usb_dppullup_en_o,
  input  logic                            aon_wake_usb_dnpullup_en_o,
  input  logic                            aon_wake_wake_req_aon_o,
  input  logic                            aon_wake_bus_not_idle_aon_o,
  input  logic                            aon_wake_bus_reset_aon_o,
  input  logic                            aon_wake_sense_lost_aon_o,
  input  logic                            aon_wake_wake_detect_active_aon_o,

  // Internal: the register block's hardware interface.
  input  pinmux_reg2hw_t                  reg2hw_i,
  input  pinmux_hw2reg_t                  hw2reg_i
);

  /////////////////
  // Environment //
  /////////////////

  // The bus events the VIP exports: a request taken, an answer taken.
  logic tl_a_fire;
  logic tl_d_fire;

  // The VIP plays the host: it assumes the host's rules on tl_i and checks the device's on tl_o,
  // one request at a time, answered the next cycle (the CSR checker's own proof shows it; asserted
  // again).
  tlul_abvip #(
    .Role              (tlul_abvip_pkg::PlayHost),
    .DevSameCycleRsp   (1'b0),
    .DevMaxOutstanding (1),
    .DevRspBound       (1)
  ) u_tl (
    .clk_i,
    .rst_ni,
    .h2d_i             (tl_i),
    .d2h_i             (tl_o),
    .a_fire_o          (tl_a_fire),
    .d_fire_o          (tl_d_fire),
    /* verilator lint_off PINCONNECTEMPTY */
    .num_outstanding_o (),
    .oldest_src_o      ()
    /* verilator lint_on PINCONNECTEMPTY */
  );

  //////////////////
  // Bus requests //
  //////////////////

  // A malformed request: an undefined opcode, or a size, address and mask that disagree.
  function automatic logic is_malformed(tlul_pkg::tl_h2d_t req);
    logic [3:0] lanes;
    if (!(req.a_opcode inside {tlul_pkg::Get, tlul_pkg::PutFullData,
                               tlul_pkg::PutPartialData})) return 1'b1;
    if (req.a_size > 2) return 1'b1;

    // Active byte lanes of the request, from its size and address ([TLUL] Explicit Error Cases).
    unique case (req.a_size)
      2'd0:    lanes = 4'b0001 << req.a_address[1:0];
      2'd1:    lanes = req.a_address[0] ? 4'b0000 : (4'b0011 << req.a_address[1:0]);
      default: lanes = (req.a_address[1:0] == 2'b00) ? 4'b1111 : 4'b0000;
    endcase
    if (lanes == '0) return 1'b1;                       // misaligned for its size
    if ((req.a_mask & ~lanes) != '0) return 1'b1;       // a lane outside the access

    // A full write uses every lane of its access.
    if (req.a_opcode == tlul_pkg::PutFullData && req.a_mask != lanes) return 1'b1;
    return 1'b0;
  endfunction

  // The request the register block holds (one at a time), until its answer.
  logic               req_vld_q;
  logic               req_write_q;
  logic               req_malformed_q;
  logic [BlockAw-1:0] req_addr_q;
  logic [3:0]         req_mask_q;
  logic [31:0]        req_data_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin : proc_req
    if (!rst_ni) begin
      req_vld_q       <= 1'b0;
      req_write_q     <= 1'b0;
      req_malformed_q <= 1'b0;
      req_addr_q      <= '0;
      req_mask_q      <= '0;
      req_data_q      <= '0;
    end else if (tl_a_fire) begin
      req_vld_q       <= 1'b1;
      req_write_q     <= tl_i.a_opcode inside {tlul_pkg::PutFullData, tlul_pkg::PutPartialData};
      req_malformed_q <= is_malformed(tl_i);
      req_addr_q      <= tl_i.a_address[BlockAw-1:0];
      req_mask_q      <= tl_i.a_mask;
      req_data_q      <= tl_i.a_data;
    end else if (tl_d_fire) begin
      req_vld_q       <= 1'b0;
    end
  end

  // A write or read the register block accepted, in the cycle of its answer: a write whose answer
  // carries an error changes nothing (the CSR checker's error rule).
  logic wr_done;
  logic rd_done;
  assign wr_done = tl_d_fire && req_vld_q && req_write_q && !req_malformed_q && !tl_o.d_error;
  assign rd_done = tl_d_fire && req_vld_q && !req_write_q && !req_malformed_q && !tl_o.d_error;

  // A malformed request, in the cycle it is taken and in the cycle of its answer.
  logic malformed_taken;
  logic malformed_answered;
  assign malformed_taken    = tl_a_fire && is_malformed(tl_i);
  assign malformed_answered = tl_d_fire && req_vld_q && req_malformed_q;

  // A well-formed write of 1 to ALERT_TEST.fatal_fault, taken this cycle.
  logic test_req;
  assign test_req = tl_a_fire && !is_malformed(tl_i) &&
                    tl_i.a_opcode inside {tlul_pkg::PutFullData, tlul_pkg::PutPartialData} &&
                    tl_i.a_address[BlockAw-1:0] == AlertTestAddr &&
                    tl_i.a_mask[0] && tl_i.a_data[0];

  ///////////////
  // Harnesses //
  ///////////////

  // A TAP may own the five JTAG pads (tap_connected), from the jtag harness.
  logic tap_connected;

  // Input selection: every peripheral input reads the pad or constant its select names.
  pinmux_listen_harness #(
    .TargetCfg (TargetCfg)
  ) u_listen (
    .clk_i,
    .rst_ni,
    .scanmode_i,
    .tap_connected_i (tap_connected),
    .mio_in_i,
    .dio_in_i,
    .mio_to_periph_o,
    .dio_to_periph_o,
    .reg2hw_i,
    .wr_done_i       (wr_done),
    .wr_addr_i       (req_addr_q),
    .wr_mask_i       (req_mask_q),
    .wr_data_i       (req_data_q),
    .rd_done_i       (rd_done),
    .rd_data_i       (tl_o.d_data)
  );

  // Pad output, sleep retention, attributes, register locks, bus errors and the alert.
  pinmux_output_harness #(
    .TargetCfg    (TargetCfg),
    .TapStrap0Pad (TargetCfg.tap_strap0_idx)
  ) u_output (
    .clk_i,
    .rst_ni,
    .scanmode_i,
    .sleep_en_i,
    .tap_connected_i      (tap_connected),
    .periph_to_mio_i,
    .periph_to_mio_oe_i,
    .periph_to_dio_i,
    .periph_to_dio_oe_i,
    .mio_out_o,
    .mio_oe_o,
    .mio_attr_o,
    .dio_out_o,
    .dio_oe_o,
    .dio_attr_o,
    .reg2hw_i,
    .hw2reg_i,
    .tl_d_fire_i          (tl_d_fire),
    .tl_d_error_i         (tl_o.d_error),
    .tl_a_fire_i          (tl_a_fire),
    .wr_done_i            (wr_done),
    .wr_addr_i            (req_addr_q),
    .wr_mask_i            (req_mask_q),
    .wr_data_i            (req_data_q),
    .rd_done_i            (rd_done),
    .rd_data_i            (tl_o.d_data),
    .malformed_i          (malformed_taken),
    .malformed_answered_i (malformed_answered),
    .test_req_i           (test_req),
    .alert_req_i,
    .alert_test_i
  );

  // Wakeup detectors, the wake request and the wakeup register locks.
  pinmux_wakeup_harness u_wakeup (
    .clk_aon_i,
    .rst_aon_ni,
    .clk_i,
    .rst_ni,
    .scanmode_i,
    .mio_in_i,
    .dio_in_i,
    .pin_wkup_req_o,
    .reg2hw_i,
    .hw2reg_i,
    .tl_i,
    .wr_done_i (wr_done),
    .wr_addr_i (req_addr_q),
    .wr_mask_i (req_mask_q),
    .wr_data_i (req_data_q),
    .rd_done_i (rd_done),
    .rd_data_i (tl_o.d_data)
  );

  // USB wakeup module: its ports, clock and reset wired to the pinmux's (wiring only).
  pinmux_usb_harness #(
    .UsbDpIdx    (TargetCfg.usb_dp_idx),
    .UsbDnIdx    (TargetCfg.usb_dn_idx),
    .UsbSenseIdx (TargetCfg.usb_sense_idx)
  ) u_usb (
    .clk_i,
    .clk_aon_i,
    .rst_aon_ni,
    .mio_to_periph_o,
    .dio_to_periph_o,
    .usbdev_dppullup_en_i,
    .usbdev_dnpullup_en_i,
    .usbdev_suspend_req_i,
    .usbdev_wake_ack_i,
    .usb_dppullup_en_o,
    .usb_dnpullup_en_o,
    .usb_wkup_req_o,
    .usbdev_bus_not_idle_o,
    .usbdev_bus_reset_o,
    .usbdev_sense_lost_o,
    .usbdev_wake_detect_active_o,
    .aon_wake_clk_i,
    .aon_wake_rst_ni,
    .aon_wake_usb_dp_i,
    .aon_wake_usb_dn_i,
    .aon_wake_usb_sense_i,
    .aon_wake_usbdev_dppullup_en_i,
    .aon_wake_usbdev_dnpullup_en_i,
    .aon_wake_suspend_req_aon_i,
    .aon_wake_wake_ack_aon_i,
    .aon_wake_usb_dppullup_en_o,
    .aon_wake_usb_dnpullup_en_o,
    .aon_wake_wake_req_aon_o,
    .aon_wake_bus_not_idle_aon_o,
    .aon_wake_bus_reset_aon_o,
    .aon_wake_sense_lost_aon_o,
    .aon_wake_wake_detect_active_aon_o
  );

  // Strap sampling, the debug latch, the TAP selection, the DFT straps and the JTAG pads.
  pinmux_jtag_harness #(
    .TckIdx       (TargetCfg.tck_idx),
    .TmsIdx       (TargetCfg.tms_idx),
    .TrstIdx      (TargetCfg.trst_idx),
    .TdiIdx       (TargetCfg.tdi_idx),
    .TdoIdx       (TargetCfg.tdo_idx),
    .TapStrap0Idx (TargetCfg.tap_strap0_idx),
    .TapStrap1Idx (TargetCfg.tap_strap1_idx),
    .DftStrap0Idx (TargetCfg.dft_strap0_idx),
    .DftStrap1Idx (TargetCfg.dft_strap1_idx)
  ) u_jtag (
    .clk_i,
    .rst_ni,
    .rst_sys_ni,
    .lc_dft_en_i,
    .lc_hw_debug_en_i,
    .lc_check_byp_en_i,
    .lc_escalate_en_i,
    .lc_hw_debug_clr_i,
    .pinmux_hw_debug_en_o,
    .strap_en_i,
    .dft_hold_tap_sel_i,
    .scanmode_i,
    .dft_strap_test_o,
    .mio_in_i,
    .dio_in_i,
    .mio_out_o,
    .mio_oe_o,
    .mio_attr_o,
    .dio_out_o,
    .dio_oe_o,
    .mio_to_periph_o,
    .reg2hw_i,
    .hw2reg_i,
    .wr_done_i         (wr_done),
    .wr_addr_i         (req_addr_q),
    .lc_jtag_o,
    .lc_jtag_i,
    .rv_jtag_o,
    .rv_jtag_i,
    .dft_jtag_o,
    .dft_jtag_i,
    .tap_strap_i,
    .tap_connected_o   (tap_connected)
  );

endmodule : pinmux_fpv_env
