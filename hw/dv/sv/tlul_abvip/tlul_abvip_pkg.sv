// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// The roles of the TL-UL ABVIP: which end of the link it plays. PlayHost assumes the host's rules
// and asserts the device's; PlayDevice the reverse; CheckBoth asserts both, for a link whose two
// ends are real blocks.
package tlul_abvip_pkg;

  typedef enum logic [1:0] {
    PlayHost,
    PlayDevice,
    CheckBoth
  } role_e;

endpackage
