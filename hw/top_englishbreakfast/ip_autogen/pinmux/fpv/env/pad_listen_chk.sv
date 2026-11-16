// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Checker for one pad in the input direction: every peripheral input whose select names this pad
// reads the pad's value in the same cycle (MIO_PERIPH_INSEL, theory of operation "Muxing
// Matrix"). An input the pad's allowed list excludes reads 0 instead; the list is all ones unless
// the top restricts the matrix, so those checks exist only where a pair is excluded. While a TAP
// may own the pad (taken_i), another checker decides what the inputs read.
//
// Naming: taken_i is "a TAP may own this pad"; periph_sel_i[i] is "input i selects this pad".

// The resets are asynchronous in the flops and a disable condition in the properties.
/* verilator lint_off SYNCASYNCNET */
module pad_listen_chk #(
  parameter int unsigned          NPeriphIn     = 1,
  parameter logic [NPeriphIn-1:0] PeriphAllowed = '1   // inputs that may select this pad
) (
  input logic                 clk_i,
  input logic                 rst_ni,
  input logic                 taken_i,       // a TAP may own this pad
  input logic [NPeriphIn-1:0] periph_in_i,   // what each peripheral input reads
  input logic [NPeriphIn-1:0] periph_sel_i,  // input i selects this pad
  input logic                 pad_in_i       // the pad's value
);

  default clocking @(posedge clk_i); endclocking
  default disable iff (!rst_ni);

  for (genvar i = 0; i < NPeriphIn; i++) begin : gen_periph
    if (PeriphAllowed[i]) begin : gen_allowed
      // An input that selects this pad reads the pad's value, in the same cycle.
      // REQ_IN_03, 05; pad_listen: sees selected pad; [REG] MIO_PERIPH_INSEL
      assert_PadListen_SeesSelectedPad : assert property (periph_sel_i[i] && !taken_i |->
                                                          periph_in_i[i] == pad_in_i);
    end else begin : gen_excluded
      // An input whose select names a pad its list excludes reads 0.
      // REQ_EG2_01; sparse_insel: illegal select reads zero; [RFC]
      assert_PadListen_IllegalSelReadsZero : assert property (periph_sel_i[i] |->
                                                              periph_in_i[i] == 1'b0);
    end
  end

  // Every input allowed to select this pad selects it at once.
  // REQ_IN_03; pad_listen: shared pad
  cover_PadListen_AllAllowedSel : cover property (
      (periph_sel_i & PeriphAllowed) == PeriphAllowed && !taken_i);

  // An input selects this pad while the pad changes.
  // REQ_IN_03; pad_listen: pad toggles
  cover_PadListen_PadToggle : cover property (|periph_sel_i && !taken_i && $changed(pad_in_i));

endmodule : pad_listen_chk
