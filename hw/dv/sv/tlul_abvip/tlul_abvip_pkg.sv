// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// tlul_abvip_pkg: configuration type of the TL-UL assertion-based VIP (ABVIP).
// Data path: none; a type package. Obligations: none.
// Spec: none; it names the ABVIP's three roles.
// Naming: CamelCase role names, each a verb and the end of the link it decides.
package tlul_abvip_pkg;

  // The end the ABVIP plays; CheckBoth: both ends are the DUT, every rule asserted.
  typedef enum logic [1:0] {
    PlayHost,
    PlayDevice,
    CheckBoth
  } role_e;

endpackage
