// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Binds the pinmux formal environment into pinmux. `.*` connects every environment port to the
// pinmux port of the same name, so a port removed from pinmux is an elaboration error; a port
// added to pinmux must be added to the environment as an input too. The internal nets the checks
// observe are connected by name. TargetCfg is the bound pinmux's own target configuration.

`default_nettype none

module pinmux_fpv_env_bind;

  bind pinmux pinmux_fpv_env #(
    .TargetCfg (TargetCfg)
  ) u_fpv_env (
    // Internal nets: the register block's hardware interface, the sampled TAP straps and the
    // alert sender's request and test inputs.
    .reg2hw_i     (reg2hw),
    .hw2reg_i     (hw2reg),
    .tap_strap_i  (u_pinmux_strap_sampling.tap_strap_q),
    .alert_req_i  (alerts[0]),
    .alert_test_i (alert_test[0]),

    // Internal nets: the USB wakeup module's ports, clock and reset.
    .aon_wake_clk_i                    (u_usbdev_aon_wake.clk_aon_i),
    .aon_wake_rst_ni                   (u_usbdev_aon_wake.rst_aon_ni),
    .aon_wake_usb_dp_i                 (u_usbdev_aon_wake.usb_dp_i),
    .aon_wake_usb_dn_i                 (u_usbdev_aon_wake.usb_dn_i),
    .aon_wake_usb_sense_i              (u_usbdev_aon_wake.usb_sense_i),
    .aon_wake_usbdev_dppullup_en_i     (u_usbdev_aon_wake.usbdev_dppullup_en_i),
    .aon_wake_usbdev_dnpullup_en_i     (u_usbdev_aon_wake.usbdev_dnpullup_en_i),
    .aon_wake_suspend_req_aon_i        (u_usbdev_aon_wake.suspend_req_aon_i),
    .aon_wake_wake_ack_aon_i           (u_usbdev_aon_wake.wake_ack_aon_i),
    .aon_wake_usb_dppullup_en_o        (u_usbdev_aon_wake.usb_dppullup_en_o),
    .aon_wake_usb_dnpullup_en_o        (u_usbdev_aon_wake.usb_dnpullup_en_o),
    .aon_wake_wake_req_aon_o           (u_usbdev_aon_wake.wake_req_aon_o),
    .aon_wake_bus_not_idle_aon_o       (u_usbdev_aon_wake.bus_not_idle_aon_o),
    .aon_wake_bus_reset_aon_o          (u_usbdev_aon_wake.bus_reset_aon_o),
    .aon_wake_sense_lost_aon_o         (u_usbdev_aon_wake.sense_lost_aon_o),
    .aon_wake_wake_detect_active_aon_o (u_usbdev_aon_wake.wake_detect_active_aon_o),

    // Every pinmux port, by name.
    .*
  );

endmodule : pinmux_fpv_env_bind

`default_nettype wire
