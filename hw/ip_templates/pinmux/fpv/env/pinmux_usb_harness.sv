// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// USB wakeup harness: the pinmux only wires usbdev's wakeup module (usbdev_aon_wake), so every
// module port must carry the pinmux signal of the same role, and the module must run on the
// always-on clock and reset. The module's logic is removed in this task (usbdev verifies it), so
// its outputs are free and each equality decides its wire in both directions. The clock and reset
// checks sample on clk_i: they tell the clocks apart only in the run with a slower AON clock.
//
// Naming: aon_wake_<port> is the value at port <port> of usbdev_aon_wake (from the bind); the
// other names are pinmux ports.

// The resets are asynchronous in the flops and a disable condition in the properties.
/* verilator lint_off SYNCASYNCNET */
module pinmux_usb_harness
  import pinmux_reg_pkg::*;
#(
  parameter int unsigned UsbDpIdx    = 0,  // DIO index of USB D+
  parameter int unsigned UsbDnIdx    = 0,  // DIO index of USB D-
  parameter int unsigned UsbSenseIdx = 0   // MIO peripheral input of the VBUS sense
) (
  input logic                    clk_i,
  input logic                    clk_aon_i,
  input logic                    rst_aon_ni,

  // Pinmux ports
  input logic [NMioPeriphIn-1:0] mio_to_periph_o,
  input logic [NDioPads-1:0]     dio_to_periph_o,
  input logic                    usbdev_dppullup_en_i,
  input logic                    usbdev_dnpullup_en_i,
  input logic                    usbdev_suspend_req_i,
  input logic                    usbdev_wake_ack_i,
  input logic                    usb_dppullup_en_o,
  input logic                    usb_dnpullup_en_o,
  input logic                    usb_wkup_req_o,
  input logic                    usbdev_bus_not_idle_o,
  input logic                    usbdev_bus_reset_o,
  input logic                    usbdev_sense_lost_o,
  input logic                    usbdev_wake_detect_active_o,

  // usbdev_aon_wake ports (from the bind)
  input logic                    aon_wake_clk_i,
  input logic                    aon_wake_rst_ni,
  input logic                    aon_wake_usb_dp_i,
  input logic                    aon_wake_usb_dn_i,
  input logic                    aon_wake_usb_sense_i,
  input logic                    aon_wake_usbdev_dppullup_en_i,
  input logic                    aon_wake_usbdev_dnpullup_en_i,
  input logic                    aon_wake_suspend_req_aon_i,
  input logic                    aon_wake_wake_ack_aon_i,
  input logic                    aon_wake_usb_dppullup_en_o,
  input logic                    aon_wake_usb_dnpullup_en_o,
  input logic                    aon_wake_wake_req_aon_o,
  input logic                    aon_wake_bus_not_idle_aon_o,
  input logic                    aon_wake_bus_reset_aon_o,
  input logic                    aon_wake_sense_lost_aon_o,
  input logic                    aon_wake_wake_detect_active_aon_o
);

  default clocking @(posedge clk_aon_i); endclocking
  default disable iff (!rst_aon_ni);

  ///////////////////////////
  // Into the wake module  //
  ///////////////////////////

  // The USB D+ pad value reaches the wake module.
  // REQ_USB_01; usb_conn: dp routed; [USB] AON/Wake Interface Pins
  assert_UsbConn_DpRouted : assert property (aon_wake_usb_dp_i == dio_to_periph_o[UsbDpIdx]);

  // The USB D- pad value reaches the wake module.
  // REQ_USB_01; usb_conn: dn routed; [USB] AON/Wake Interface Pins
  assert_UsbConn_DnRouted : assert property (aon_wake_usb_dn_i == dio_to_periph_o[UsbDnIdx]);

  // The VBUS sense input reaches the wake module (the source is a DV reading).
  // REQ_USB_01; usb_conn: sense routed; [USB]
  assert_UsbConn_SenseRouted : assert property (aon_wake_usb_sense_i ==
                                                mio_to_periph_o[UsbSenseIdx]);

  // usbdev's D+ pull-up enable reaches the wake module.
  // REQ_USB_01; usb_conn: dp pullup in routed; [IF] usbdev_dppullup_en
  assert_UsbConn_DpPullupInRouted : assert property (aon_wake_usbdev_dppullup_en_i ==
                                                     usbdev_dppullup_en_i);

  // usbdev's D- pull-up enable reaches the wake module.
  // REQ_USB_01; usb_conn: dn pullup in routed; [IF] usbdev_dnpullup_en
  assert_UsbConn_DnPullupInRouted : assert property (aon_wake_usbdev_dnpullup_en_i ==
                                                     usbdev_dnpullup_en_i);

  // usbdev's suspend request reaches the wake module.
  // REQ_USB_01; usb_conn: suspend req routed; [IF] usbdev_suspend_req
  assert_UsbConn_SuspendReqRouted : assert property (aon_wake_suspend_req_aon_i ==
                                                     usbdev_suspend_req_i);

  // usbdev's wake acknowledge reaches the wake module.
  // REQ_USB_01; usb_conn: wake ack routed; [IF] usbdev_wake_ack
  assert_UsbConn_WakeAckRouted : assert property (aon_wake_wake_ack_aon_i == usbdev_wake_ack_i);

  ////////////////////////////
  // Out of the wake module //
  ////////////////////////////

  // The wake module's D+ pull-up enable reaches the pad.
  // REQ_USB_02; usb_conn: dp pullup out routed; [IF] usb_dppullup_en
  assert_UsbConn_DpPullupOutRouted : assert property (usb_dppullup_en_o ==
                                                      aon_wake_usb_dppullup_en_o);

  // The wake module's D- pull-up enable reaches the pad.
  // REQ_USB_02; usb_conn: dn pullup out routed; [IF] usb_dnpullup_en
  assert_UsbConn_DnPullupOutRouted : assert property (usb_dnpullup_en_o ==
                                                      aon_wake_usb_dnpullup_en_o);

  // The wake module's wake request is usb_wkup_req_o (the output is a DV reading).
  // REQ_USB_02; usb_conn: wake req routed; [IF] usb_wkup_req
  assert_UsbConn_WakeReqRouted : assert property (usb_wkup_req_o == aon_wake_wake_req_aon_o);

  // The wake module's bus-not-idle reaches usbdev.
  // REQ_USB_02; usb_conn: bus not idle routed; [IF] usbdev_bus_not_idle
  assert_UsbConn_BusNotIdleRouted : assert property (usbdev_bus_not_idle_o ==
                                                     aon_wake_bus_not_idle_aon_o);

  // The wake module's bus reset reaches usbdev.
  // REQ_USB_02; usb_conn: bus reset routed; [IF] usbdev_bus_reset
  assert_UsbConn_BusResetRouted : assert property (usbdev_bus_reset_o ==
                                                   aon_wake_bus_reset_aon_o);

  // The wake module's sense-lost reaches usbdev.
  // REQ_USB_02; usb_conn: sense lost routed; [IF] usbdev_sense_lost
  assert_UsbConn_SenseLostRouted : assert property (usbdev_sense_lost_o ==
                                                    aon_wake_sense_lost_aon_o);

  // The wake module's wake-detect-active reaches usbdev.
  // REQ_USB_02; usb_conn: wake detect active routed; [IF] usbdev_wake_detect_active
  assert_UsbConn_WakeDetectRouted : assert property (usbdev_wake_detect_active_o ==
                                                     aon_wake_wake_detect_active_aon_o);

  ///////////////////////
  // Clock and reset   //
  ///////////////////////

  // The wake module runs on clk_aon_i in every cycle, reset included.
  // REQ_USB_03; usb_conn: AON clock and reset routed; [REG] clocking; [USB] AON/Wake Clocking
  assert_UsbConn_AonClockRouted : assert property (@(posedge clk_i) disable iff (1'b0)
                                                   aon_wake_clk_i == clk_aon_i);

  // The wake module is reset by rst_aon_ni in every cycle, reset included.
  // REQ_USB_03; usb_conn: AON clock and reset routed; [REG] clocking; [USB] AON/Wake Clocking
  assert_UsbConn_AonResetRouted : assert property (@(posedge clk_i) disable iff (1'b0)
                                                   aon_wake_rst_ni == rst_aon_ni);

  // D+ and D- change at the wake module's inputs.
  // REQ_USB_01; usb_conn: USB pads toggle
  cover_UsbConn_PadsToggle : cover property ($changed(aon_wake_usb_dp_i) &&
                                             $changed(aon_wake_usb_dn_i));

  // The wake module raises its wake request.
  // REQ_USB_02; usb_conn: wake request
  cover_UsbConn_WakeRequest : cover property ($rose(usb_wkup_req_o));

endmodule : pinmux_usb_harness
