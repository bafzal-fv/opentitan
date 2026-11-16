// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// csr_chk_pkg: the register access rules of the register tool manual, as pure functions. The
//   generated CSR checkers (<ip>_csr_chk, from util/reggen/csr_chk.sv.tpl) call them to predict
//   the content of every field from the bus and from the hardware interface.
// Data path: none; functions.
// Obligations: none of its own; every field prediction of a generated checker reads them.
// Spec: util/reggen/README.md, "Register definitions per type" and "Simultaneous SW and HW
//   access" (the next value per software access type, software first on a collision); "Type RC"
//   (a read clears); regwen (open at 1, a multi-bit one only at its True encoding).
// Naming: sw_access_e values are the hjson swaccess keys in CamelCase.
package csr_chk_pkg;

  // Width of a register and of the bus data, the register tool's default.
  localparam int unsigned DataW = top_pkg::TL_DW;

  // The hjson swaccess key of a field.
  typedef enum logic [3:0] {
    SwNone,
    SwRo,
    SwRc,
    SwRw,
    SwR0w1c,
    SwRw1s,
    SwRw1c,
    SwRw0c,
    SwWo
  } sw_access_e;

  // Content after a software write of wd to a field holding q. Types software cannot write keep q.
  function automatic logic [DataW-1:0] sw_next(sw_access_e access, logic [DataW-1:0] q,
                                               logic [DataW-1:0] wd);
    case (access)
      SwRw, SwWo:      return wd;
      SwRw1c, SwR0w1c: return q & ~wd;
      SwRw0c:          return q & wd;
      SwRw1s:          return q | wd;
      default:         return q;
    endcase
  endfunction

  // Content a hardware update leaves: d when de is set, else q. On a cycle with a software write
  // too, the software rule applies on top of this value ("the software updated value is used").
  function automatic logic [DataW-1:0] hw_next(logic de, logic [DataW-1:0] d,
                                               logic [DataW-1:0] q);
    return de ? d : q;
  endfunction

  // What a read returns for a field holding q: its content, or zero for the types that read as
  // zero (wo, r0w1c) and for a field software cannot access.
  function automatic logic [DataW-1:0] rd_value(sw_access_e access, logic [DataW-1:0] q);
    case (access)
      SwWo, SwR0w1c, SwNone: return '0;
      default:               return q;
    endcase
  endfunction

  // Does a read clear the field?
  function automatic logic clears_on_read(sw_access_e access);
    return access == SwRc;
  endfunction

  // Is a REGWEN holding q open: a one-bit REGWEN at 1; a multi-bit one only at its True encoding.
  function automatic logic regwen_open(logic mubi, int unsigned width, logic [DataW-1:0] q);
    if (!mubi) return q[0];
    case (width)
      4:       return q[3:0]  == prim_mubi_pkg::MuBi4True;
      8:       return q[7:0]  == prim_mubi_pkg::MuBi8True;
      12:      return q[11:0] == prim_mubi_pkg::MuBi12True;
      16:      return q[15:0] == prim_mubi_pkg::MuBi16True;
      default: return 1'b0;
    endcase
  endfunction

  // Is a write with byte enables be permitted on a register whose fields need the bytes in
  // permit: every needed byte must be enabled ("writes of size smaller than register size" err).
  function automatic logic wr_permitted(logic [DataW/8-1:0] be, logic [DataW/8-1:0] permit);
    return (permit & ~be) == '0;
  endfunction

endpackage
