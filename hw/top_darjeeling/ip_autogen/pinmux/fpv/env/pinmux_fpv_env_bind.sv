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
    .alert_req_i  (alerts[0]),
    .alert_test_i (alert_test[0]),

    // Every pinmux port, by name.
    .*
  );

endmodule : pinmux_fpv_env_bind

`default_nettype wire
