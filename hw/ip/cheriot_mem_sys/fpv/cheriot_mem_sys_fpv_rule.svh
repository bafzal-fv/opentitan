// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// ENV_RULE: how a checker states a rule on what its neighbours send. In a formal build (FPV_ON)
// the rule is an assumption, so the tool drives only the traffic the rule allows. In a simulation
// build the same rule is an assertion, so the real neighbours are checked against what the proof
// relied on. The label is the same in both builds: a formal task picks rules up by name, and a
// simulation failure names the rule that broke.

`ifndef CHERIOT_MEM_SYS_FPV_RULE_SVH
`define CHERIOT_MEM_SYS_FPV_RULE_SVH

`ifdef FPV_ON
`define ENV_RULE(__name, __prop) __name : assume property (__prop);
`else
`define ENV_RULE(__name, __prop) __name : assert property (__prop);
`endif

`endif  // CHERIOT_MEM_SYS_FPV_RULE_SVH
