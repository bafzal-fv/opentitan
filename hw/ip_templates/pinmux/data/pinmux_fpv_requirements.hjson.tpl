// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
<%
top_title = {'earlgrey': 'Earl Grey', 'darjeeling': 'Darjeeling',
             'englishbreakfast': 'English Breakfast'}.get(topname, topname)
eg_top = topname == 'earlgrey'
usb = enable_usb_wakeup
strap = enable_strap_sampling
rram = enable_rram_tap  # the RRAM TAP on TAP strap value 0
# The largest value of each select field, from its width in pinmux.hjson.tpl.
insel_max = 2 ** (n_mio_pads + 1).bit_length() - 1
outsel_max = 2 ** (n_mio_periph_out + 2).bit_length() - 1
padsel_max = 2 ** max(n_mio_pads + 1, n_dio_pads - 1).bit_length() - 1
def n(base, with_usb=0, with_strap=0, with_rram=0):
    return (base + (with_usb if usb else 0) + (with_strap if strap else 0)
            + (with_rram if rram else 0))
def free(lo, hi):
    if lo > hi:
        return 'above {} (no such value on this top)'.format(hi)
    return str(lo) if lo == hi else '{} to {}'.format(lo, hi)
def eg(text, other=''):
    return text if eg_top else other
def on(flag, text):
    return text if flag else ''
%>\
{
  name: "pinmux_fpv"
  // The top the plan was written for and checked on. Other tops render it from the
  // same template with their own parameters; their requirements are not reviewed.
  written_for: "earlgrey"
  rendered_for: "${topname}"
  spec_commit: "5b8df2b85493add710eb5b8af7d6c263ce9acb87"
  terms: [
    {
      name: '''`n`'''
      desc: '''MIO peripheral input (0 to ${n_mio_periph_in - 1})'''
    }
    {
      name: '''`k`'''
      desc: '''MIO peripheral output (0 to ${n_mio_periph_out - 1})'''
    }
    {
      name: '''`p`'''
      desc: '''MIO pad (0 to ${n_mio_pads - 1})'''
    }
    {
      name: '''`d`'''
      desc: '''DIO pad (0 to ${n_dio_pads - 1})'''
    }
    {
      name: '''Watched signal'''
      desc: '''The pad input that `MIODIO` and `PADSEL` pick'''
    }
    {
      name: '''Forwarded value'''
      desc: '''The watched signal sampled each `clk_aon_i` cycle, through the filter when `FILTER` is 1'''
    }
% if strap:
    {
      name: '''Full reset'''
      desc: '''`rst_sys_ni` ([Non-debug Module Reset](hw/top_earlgrey/ip_autogen/pinmux/doc/theory_of_operation.md#non-debug-module-reset))'''
    }
% endif
% if strap:
    {
      name: '''NDM reset'''
      desc: '''A reset that asserts `rst_ni` and `rst_aon_ni`, not `rst_sys_ni` ([Non-debug Module Reset](hw/top_earlgrey/ip_autogen/pinmux/doc/theory_of_operation.md#non-debug-module-reset))'''
    }
% endif
% if strap:
    {
      name: '''On, Off'''
      desc: '''On is 4'b0101 and Off 4'b1010, the life cycle controller's values ([Control Signal Propagation](hw/ip/lc_ctrl/doc/interfaces.md#control-signal-propagation))'''
    }
% endif
% if strap:
    {
      name: '''The latch'''
      desc: '''The latched debug enable, seen on `pinmux_hw_debug_en_o` and through the RISC-V TAP'''
    }
% endif
% if strap:
    {
      name: '''A clear'''
      desc: '''`lc_hw_debug_clr_i`, `lc_check_byp_en_i` or `lc_escalate_en_i` at any value other than Off ([Non-debug Module Reset](hw/top_earlgrey/ip_autogen/pinmux/doc/theory_of_operation.md#non-debug-module-reset); [Control Signal Propagation](hw/ip/lc_ctrl/doc/interfaces.md#control-signal-propagation) for the debug clear and the escalation input); it turns the latch Off'''
    }
% endif
% if strap:
    {
      name: '''Connected'''
      desc: '''A TAP is connected while the TAP straps name it and its gate is open: the life cycle TAP at straps 01; the RISC-V TAP at straps 10 while the latch is On; the DFT TAP at straps 11 while `lc_dft_en_i` is On; on a top with the RRAM TAP (`enable_rram_tap`), the RRAM TAP at straps 00 while `RRAM_JTAG_SEL` is `kMultiBitBool4True` and `lc_nvm_debug_en_i` is On; at straps 00, no TAP otherwise ([Strap Sampling and TAP Isolation](hw/top_${topname}/ip_autogen/pinmux/doc/theory_of_operation.md#strap-sampling-and-tap-isolation), [Non-debug Module Reset](hw/top_earlgrey/ip_autogen/pinmux/doc/theory_of_operation.md#non-debug-module-reset))'''
    }
% endif
  ]
  groups: [
    {
      name: '''Input selection'''
      conditions: [
        '''every row holds in every cycle, except for a JTAG pad while a TAP owns it.'''
      ]
      requirements: [
        {
          name: REQ_IN_01
          desc: '''MIO peripheral input `n` shall read 0 while `MIO_PERIPH_INSEL_n` is 0.'''
          source: [
            '''!!MIO_PERIPH_INSEL.IN'''
          ]
          kind: "spec"
          testpoint: "pad_listen"
          checks: ["CHK_PAD_LISTEN_01 reads tie 0 (assert_PadListen_ReadsTie0)"]
          why: '''In every cycle the check compares each MIO peripheral input whose select is 0 with 0. An input that reads a pad or 1 under select 0, even for one cycle, fails it.'''
          milestone: "V1"
          priority: "1"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_IN_02
          desc: '''MIO peripheral input `n` shall read 1 while `MIO_PERIPH_INSEL_n` is 1.'''
          source: [
            '''!!MIO_PERIPH_INSEL.IN'''
          ]
          kind: "spec"
          testpoint: "pad_listen"
          checks: ["CHK_PAD_LISTEN_02 reads tie 1 (assert_PadListen_ReadsTie1)"]
          why: '''In every cycle the check compares each MIO peripheral input whose select is 1 with 1. An input that reads a pad or 0 under select 1 fails it.'''
          milestone: "V1"
          priority: "1"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_IN_03
          desc: '''MIO peripheral input `n` shall read the input of MIO pad `p`, in the same cycle, while `MIO_PERIPH_INSEL_n` is 2 + `p` (`p` from 0 to ${n_mio_pads - 1}).'''
          source: [
            '''!!MIO_PERIPH_INSEL.IN'''
            '''[top_${topname}_pinmux.ipconfig.hjson `n_mio_pads`](hw/top_${topname}/ip_autogen/pinmux/data/top_${topname}_pinmux.ipconfig.hjson)'''
          ]
          kind: "spec"
          testpoint: "pad_listen"
          checks: ["CHK_PAD_LISTEN_03 reads selected pad (assert_PadListen_ReadsSelectedPad)"]
          why: '''For each select from 2 to ${n_mio_pads + 1} the check compares the input with `mio_in_i` of pad select minus 2, in the same cycle. An input that reads another pad, or the right pad a cycle late, differs in some cycle and fails it.'''
          milestone: "V1"
          priority: "1"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_IN_04
          desc: '''MIO peripheral input `n` shall read 0 while `MIO_PERIPH_INSEL_n` is ${free(n_mio_pads + 2, insel_max)}, the values that name no pad.'''
          source: [
            '''!!MIO_PERIPH_INSEL'''
            '''[top_${topname}_pinmux.ipconfig.hjson `n_mio_pads`](hw/top_${topname}/ip_autogen/pinmux/data/top_${topname}_pinmux.ipconfig.hjson)'''
          ]
          kind: "RTL"
          testpoint: "pad_listen"
          checks: ["CHK_PAD_LISTEN_04 no pad reads 0 (assert_PadListen_NoPadReads0)"]
          why: '''For selects ${free(n_mio_pads + 2, insel_max)}, which name no pad, the check compares the input with 0. An input that reads a pad there, for example by wrapping the select around, or reads 1, fails it.'''
          milestone: "V1"
          priority: "1"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_IN_05
          desc: '''DIO peripheral input `d` shall read the input of DIO pad `d`, in the same cycle, whatever the registers hold.'''
          source: [
            '''[MIO and DIO Signal Categories](hw/top_${topname}/ip_autogen/pinmux/doc/theory_of_operation.md#mio-and-dio-signal-categories)'''
          ]
          kind: "spec"
          testpoint: "pad_listen"
          checks: ["CHK_PAD_LISTEN_05 DIO reads its pad (assert_PadListen_DIOReadsItsPad)"]
          why: '''The check compares each DIO peripheral input with its own pad's `dio_in_i` in the same cycle, whatever the registers hold. An input that reads another DIO pad, depends on a register or lags by a cycle fails it.'''
          milestone: "V1"
          priority: "1"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_IN_06
          desc: '''After reset, every MIO peripheral input shall read 0 until software writes its select.'''
          source: [
            '''[Pinmux Configuration](hw/top_${topname}/ip_autogen/pinmux/doc/programmers_guide.md#pinmux-configuration)'''
            '''[MIO and DIO Signal Categories](hw/top_${topname}/ip_autogen/pinmux/doc/theory_of_operation.md#mio-and-dio-signal-categories)'''
            '''!!MIO_PERIPH_INSEL.IN'''
          ]
          kind: "spec"
          testpoint: "reset_state"
          checks: ["CHK_PAD_LISTEN_01 reads tie 0 (assert_PadListen_ReadsTie0)"]
          why: '''The generated register checker keeps each input select at its reset value 0 until software writes it, and _reads tie 0_ (CHK_PAD_LISTEN_01) makes an input whose select is 0 read 0 in the same cycle. An input that reads 1 before its select is written fails one of the two.'''
          milestone: "V2"
          priority: "2"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
      ]
    }
    {
      name: '''Output selection'''
      conditions: [
        '''every row holds while the pad's sleep mode is not active (Sleep retention) and no TAP owns the pad.'''
      ]
      requirements: [
        {
          name: REQ_OUT_01a
          desc: '''The output of MIO pad `p` shall be 0 while `MIO_OUTSEL_p` is 0.'''
          source: [
            '''!!MIO_OUTSEL.OUT'''
          ]
          kind: "spec"
          testpoint: "pad_output"
          checks: ["CHK_PAD_OUTPUT_01 tie 0 drives 0 (assert_PadOutput_Tie0Drives0)"]
          why: '''While an awake pad's select is 0, the check compares the pad's output with 0 in every cycle. A pad that puts 1 or a peripheral's data on its output there fails it.'''
          milestone: "V1"
          priority: "1"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_OUT_01b
          desc: '''The output enable of MIO pad `p` shall be 1 while `MIO_OUTSEL_p` is 0, so the pad drives 0.'''
          source: [
            '''!!MIO_OUTSEL.OUT'''
          ]
          kind: "spec"
          testpoint: "pad_output"
          checks: ["CHK_PAD_OUTPUT_01 tie 0 drives 0 (assert_PadOutput_Tie0Drives0)"]
          why: '''Under select 0 the check compares the pad's output enable with 1 in every cycle. A pad left high-Z, or following a peripheral's enable, under select 0 fails it.'''
          milestone: "V1"
          priority: "1"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_OUT_02a
          desc: '''The output of MIO pad `p` shall be 1 while `MIO_OUTSEL_p` is 1.'''
          source: [
            '''!!MIO_OUTSEL.OUT'''
          ]
          kind: "spec"
          testpoint: "pad_output"
          checks: ["CHK_PAD_OUTPUT_02 tie 1 drives 1 (assert_PadOutput_Tie1Drives1)"]
          why: '''While an awake pad's select is 1, the check compares the pad's output with 1 in every cycle. A pad that puts 0 or a peripheral's data on its output there fails it.'''
          milestone: "V1"
          priority: "1"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_OUT_02b
          desc: '''The output enable of MIO pad `p` shall be 1 while `MIO_OUTSEL_p` is 1, so the pad drives 1.'''
          source: [
            '''!!MIO_OUTSEL.OUT'''
          ]
          kind: "spec"
          testpoint: "pad_output"
          checks: ["CHK_PAD_OUTPUT_02 tie 1 drives 1 (assert_PadOutput_Tie1Drives1)"]
          why: '''Under select 1 the check compares the pad's output enable with 1 in every cycle. A pad left high-Z, or following a peripheral's enable, under select 1 fails it.'''
          milestone: "V1"
          priority: "1"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_OUT_03a
          desc: '''The output enable of MIO pad `p` shall be 0 while `MIO_OUTSEL_p` is 2: the pad is high-Z.'''
          source: [
            '''!!MIO_OUTSEL.OUT'''
          ]
          kind: "spec"
          testpoint: "pad_output"
          checks: ["CHK_PAD_OUTPUT_03 select 2 is high-Z (assert_PadOutput_Select2IsHighZ)"]
          why: '''While an awake pad's select is 2, the check compares the pad's output enable with 0 in every cycle. A pad that drives under select 2, even for one cycle, fails it.'''
          milestone: "V1"
          priority: "1"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_OUT_03b
          desc: '''The output of MIO pad `p` shall be 0 while `MIO_OUTSEL_p` is 2.'''
          source: [
            '''!!MIO_OUTSEL.OUT'''
          ]
          kind: "spec"
          testpoint: "pad_output"
          checks: ["CHK_PAD_OUTPUT_03 select 2 is high-Z (assert_PadOutput_Select2IsHighZ)"]
          why: '''Under select 2 the check compares the pad's output with 0 in every cycle. A pad that puts 1 or a peripheral's data on its output while high-Z fails it.'''
          milestone: "V1"
          priority: "1"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_OUT_04a
          desc: '''MIO pad `p` shall carry peripheral output `k`, in the same cycle, while `MIO_OUTSEL_p` is 3 + `k` (`k` from 0 to ${n_mio_periph_out - 1}).'''
          source: [
            '''!!MIO_OUTSEL.OUT'''
            '''[Muxing Matrix](hw/top_${topname}/ip_autogen/pinmux/doc/theory_of_operation.md#muxing-matrix)'''
            '''[top_${topname}_pinmux.ipconfig.hjson `n_mio_periph_out`](hw/top_${topname}/ip_autogen/pinmux/data/top_${topname}_pinmux.ipconfig.hjson)'''
          ]
          kind: "spec"
          testpoint: "pad_output"
          checks: ["CHK_PAD_OUTPUT_04 drives selected output (assert_PadOutput_DrivesSelectedOutput)"]
          why: '''For each select from 3 to ${n_mio_periph_out + 2} the check compares the pad's output with `periph_to_mio_i[k]`, `k` the select minus 3, in the same cycle. A pad that carries another output's data, or the right data a cycle late, fails it.'''
          milestone: "V1"
          priority: "1"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_OUT_04b
          desc: '''MIO pad `p` shall carry output enable `k`, in the same cycle, while `MIO_OUTSEL_p` is 3 + `k` (`k` from 0 to ${n_mio_periph_out - 1}).'''
          source: [
            '''!!MIO_OUTSEL.OUT'''
            '''[Muxing Matrix](hw/top_${topname}/ip_autogen/pinmux/doc/theory_of_operation.md#muxing-matrix)'''
            '''[top_${topname}_pinmux.ipconfig.hjson `n_mio_periph_out`](hw/top_${topname}/ip_autogen/pinmux/data/top_${topname}_pinmux.ipconfig.hjson)'''
          ]
          kind: "spec"
          testpoint: "pad_output"
          checks: ["CHK_PAD_OUTPUT_04 drives selected output (assert_PadOutput_DrivesSelectedOutput)"]
          why: '''The check compares the pad's output enable with `periph_to_mio_oe_i[k]` in the same cycle, together with the data. A pad that pairs one output's data with another output's enable, or lags the enable by a cycle, fails it.'''
          milestone: "V1"
          priority: "1"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_OUT_05a
          desc: '''The output enable of MIO pad `p` shall be 0 while `MIO_OUTSEL_p` is ${free(n_mio_periph_out + 3, outsel_max)}, the values that name no peripheral output: the pad is high-Z.'''
          source: [
            '''!!MIO_OUTSEL'''
            '''[top_${topname}_pinmux.ipconfig.hjson `n_mio_periph_out`](hw/top_${topname}/ip_autogen/pinmux/data/top_${topname}_pinmux.ipconfig.hjson)'''
          ]
          kind: "RTL"
          testpoint: "pad_output"
          checks: ["CHK_PAD_OUTPUT_05 no output is high-Z (assert_PadOutput_NoOutputIsHighZ)"]
          why: '''For selects ${free(n_mio_periph_out + 3, outsel_max)}, which name no output, the check compares the pad's output enable with 0. A pad that drives there, for example by wrapping the select onto a real output, fails it.'''
          milestone: "V1"
          priority: "1"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_OUT_05b
          desc: '''The output of MIO pad `p` shall be 0 while `MIO_OUTSEL_p` is ${free(n_mio_periph_out + 3, outsel_max)}, the values that name no peripheral output.'''
          source: [
            '''!!MIO_OUTSEL'''
            '''[top_${topname}_pinmux.ipconfig.hjson `n_mio_periph_out`](hw/top_${topname}/ip_autogen/pinmux/data/top_${topname}_pinmux.ipconfig.hjson)'''
          ]
          kind: "RTL"
          testpoint: "pad_output"
          checks: ["CHK_PAD_OUTPUT_05 no output is high-Z (assert_PadOutput_NoOutputIsHighZ)"]
          why: '''For selects ${free(n_mio_periph_out + 3, outsel_max)} the check compares the pad's output with 0. A pad that puts 1 or any output's data on its output there fails it.'''
          milestone: "V1"
          priority: "1"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_OUT_06a
          desc: '''DIO pad `d` shall carry its peripheral's output, in the same cycle.'''
          source: [
            '''[MIO and DIO Signal Categories](hw/top_${topname}/ip_autogen/pinmux/doc/theory_of_operation.md#mio-and-dio-signal-categories)'''
          ]
          kind: "spec"
          testpoint: "pad_output"
          checks: ["CHK_PAD_OUTPUT_06 DIO drives its peripheral (assert_PadOutput_DIODrivesItsPeripheral)"]
          why: '''The check compares each awake DIO pad's output with its own peripheral's, `periph_to_dio_i[d]`, in the same cycle, whatever the registers hold. A pad that carries another peripheral, depends on a register or lags by a cycle fails it.'''
          milestone: "V1"
          priority: "1"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_OUT_06b
          desc: '''DIO pad `d` shall carry its peripheral's output enable, in the same cycle.'''
          source: [
            '''[MIO and DIO Signal Categories](hw/top_${topname}/ip_autogen/pinmux/doc/theory_of_operation.md#mio-and-dio-signal-categories)'''
          ]
          kind: "spec"
          testpoint: "pad_output"
          checks: ["CHK_PAD_OUTPUT_06 DIO drives its peripheral (assert_PadOutput_DIODrivesItsPeripheral)"]
          why: '''The check compares each awake DIO pad's output enable with `periph_to_dio_oe_i[d]` in the same cycle, whatever the registers hold. A pad that takes another peripheral's enable, or lags by a cycle, fails it.'''
          milestone: "V1"
          priority: "1"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_OUT_07
          desc: '''After reset, every MIO pad shall be high-Z until software writes its select.'''
          source: [
            '''[MIO and DIO Signal Categories](hw/top_${topname}/ip_autogen/pinmux/doc/theory_of_operation.md#mio-and-dio-signal-categories)'''
            '''[Pinmux Configuration](hw/top_${topname}/ip_autogen/pinmux/doc/programmers_guide.md#pinmux-configuration)'''
            '''!!MIO_OUTSEL.OUT'''
          ]
          kind: "spec"
          testpoint: "reset_state"
          checks: ["CHK_PAD_OUTPUT_03 select 2 is high-Z (assert_PadOutput_Select2IsHighZ)"]
          why: '''The generated register checker keeps each output select at its reset value 2 until software writes it, and _select 2 is high-Z_ (CHK_PAD_OUTPUT_03) makes an awake pad that no TAP owns drive (0, 0) on select 2. A pad that drives before its select is written fails one of the two; an asleep pad and a JTAG pad a TAP owns are decided by the sleep and JTAG pad checks.'''
          milestone: "V2"
          priority: "2"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
      ]
    }
    {
      name: '''Pad attributes'''
      conditions: [
        '''every row holds in every cycle, asleep or awake, except on a JTAG pad while a TAP owns it. "Written" means a write the register block accepts, its lock open (Register locks); "reads back" means what a read of the register returns. A pad type "keeps" an attribute bit when its pads implement that bit ([Pad Attributes](hw/top_${topname}/ip_autogen/pinmux/doc/programmers_guide.md#pad-attributes)); which bits a type keeps is fixed, the same on every pad of the type and for good. A one-bit field is kept when its bit is; each bit of `slew_rate` and `drive_strength` is kept or not on its own, as "certain pads may only support two drive-strength bits, instead of four" ([Pad Attributes](hw/top_${topname}/ip_autogen/pinmux/doc/programmers_guide.md#pad-attributes)). Every pad keeps `invert` ([Generic Pad Wrapper](hw/top_${topname}/ip_autogen/pinmux/doc/theory_of_operation.md#generic-pad-wrapper)).'''
      ]
      requirements: [
        {
          name: REQ_ATTR_01a
          desc: '''The attribute output of MIO pad `p` shall equal, in field `invert`, what `MIO_PAD_ATTR_p` reads back.'''
          source: [
            '''!!MIO_PAD_ATTR.invert'''
            '''[Type RW HWExt](util/reggen/README.md#type-rw-hwext)'''
            '''[Generic Pad Wrapper](hw/top_${topname}/ip_autogen/pinmux/doc/theory_of_operation.md#generic-pad-wrapper)'''
          ]
          kind: "spec"
          testpoint: "pad_attr"
          checks: ["CHK_PAD_ATTR_01 pad gets read-back (assert_PadAttr_PadGetsReadBack)"]
          why: '''In every cycle the check compares field `invert` of `mio_attr_o` for the pad with the same field of what a read of `MIO_PAD_ATTR_p` returns. A pad that inverts while the register reads 0, or the reverse, or takes the bit a cycle late, fails it.'''
          milestone: "V2"
          priority: "2"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_ATTR_01b
          desc: '''The attribute output of MIO pad `p` shall equal, in field `virtual_od_en`, what `MIO_PAD_ATTR_p` reads back.'''
          source: [
            '''!!MIO_PAD_ATTR.virtual_od_en'''
            '''[Type RW HWExt](util/reggen/README.md#type-rw-hwext)'''
            '''[Generic Pad Wrapper](hw/top_${topname}/ip_autogen/pinmux/doc/theory_of_operation.md#generic-pad-wrapper)'''
          ]
          kind: "spec"
          testpoint: "pad_attr"
          checks: ["CHK_PAD_ATTR_01 pad gets read-back (assert_PadAttr_PadGetsReadBack)"]
          why: '''In every cycle the check compares field `virtual_od_en` of the pad's `mio_attr_o` with the same field of the read-back of `MIO_PAD_ATTR_p`. A pad that gets a virtual open drain the register does not show, or loses one it shows, fails it.'''
          milestone: "V2"
          priority: "2"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_ATTR_01c
          desc: '''The attribute output of MIO pad `p` shall equal, in field `pull_en`, what `MIO_PAD_ATTR_p` reads back.'''
          source: [
            '''!!MIO_PAD_ATTR.pull_en'''
            '''[Type RW HWExt](util/reggen/README.md#type-rw-hwext)'''
            '''[Generic Pad Wrapper](hw/top_${topname}/ip_autogen/pinmux/doc/theory_of_operation.md#generic-pad-wrapper)'''
          ]
          kind: "spec"
          testpoint: "pad_attr"
          checks: ["CHK_PAD_ATTR_01 pad gets read-back (assert_PadAttr_PadGetsReadBack)"]
          why: '''In every cycle the check compares field `pull_en` of the pad's `mio_attr_o` with the same field of the read-back of `MIO_PAD_ATTR_p`. A pad that gets a pull the register does not show, or loses one it shows, fails it.'''
          milestone: "V2"
          priority: "2"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_ATTR_01d
          desc: '''The attribute output of MIO pad `p` shall equal, in field `pull_select`, what `MIO_PAD_ATTR_p` reads back.'''
          source: [
            '''!!MIO_PAD_ATTR.pull_select'''
            '''[Type RW HWExt](util/reggen/README.md#type-rw-hwext)'''
            '''[Generic Pad Wrapper](hw/top_${topname}/ip_autogen/pinmux/doc/theory_of_operation.md#generic-pad-wrapper)'''
          ]
          kind: "spec"
          testpoint: "pad_attr"
          checks: ["CHK_PAD_ATTR_01 pad gets read-back (assert_PadAttr_PadGetsReadBack)"]
          why: '''In every cycle the check compares field `pull_select` of the pad's `mio_attr_o` with the same field of the read-back of `MIO_PAD_ATTR_p`. A pad pulled the other way from what the register shows fails it.'''
          milestone: "V2"
          priority: "2"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_ATTR_01e
          desc: '''The attribute output of MIO pad `p` shall equal, in field `keeper_en`, what `MIO_PAD_ATTR_p` reads back.'''
          source: [
            '''!!MIO_PAD_ATTR.keeper_en'''
            '''[Type RW HWExt](util/reggen/README.md#type-rw-hwext)'''
            '''[Generic Pad Wrapper](hw/top_${topname}/ip_autogen/pinmux/doc/theory_of_operation.md#generic-pad-wrapper)'''
          ]
          kind: "spec"
          testpoint: "pad_attr"
          checks: ["CHK_PAD_ATTR_01 pad gets read-back (assert_PadAttr_PadGetsReadBack)"]
          why: '''In every cycle the check compares field `keeper_en` of the pad's `mio_attr_o` with the same field of the read-back of `MIO_PAD_ATTR_p`. A pad whose keeper is on while the register shows it off, or the reverse, fails it.'''
          milestone: "V2"
          priority: "2"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_ATTR_01f
          desc: '''The attribute output of MIO pad `p` shall equal, in field `schmitt_en`, what `MIO_PAD_ATTR_p` reads back.'''
          source: [
            '''!!MIO_PAD_ATTR.schmitt_en'''
            '''[Type RW HWExt](util/reggen/README.md#type-rw-hwext)'''
            '''[Generic Pad Wrapper](hw/top_${topname}/ip_autogen/pinmux/doc/theory_of_operation.md#generic-pad-wrapper)'''
          ]
          kind: "spec"
          testpoint: "pad_attr"
          checks: ["CHK_PAD_ATTR_01 pad gets read-back (assert_PadAttr_PadGetsReadBack)"]
          why: '''In every cycle the check compares field `schmitt_en` of the pad's `mio_attr_o` with the same field of the read-back of `MIO_PAD_ATTR_p`. A pad whose Schmitt trigger differs from what the register shows fails it.'''
          milestone: "V2"
          priority: "2"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_ATTR_01g
          desc: '''The attribute output of MIO pad `p` shall equal, in field `od_en`, what `MIO_PAD_ATTR_p` reads back.'''
          source: [
            '''!!MIO_PAD_ATTR.od_en'''
            '''[Type RW HWExt](util/reggen/README.md#type-rw-hwext)'''
            '''[Generic Pad Wrapper](hw/top_${topname}/ip_autogen/pinmux/doc/theory_of_operation.md#generic-pad-wrapper)'''
          ]
          kind: "spec"
          testpoint: "pad_attr"
          checks: ["CHK_PAD_ATTR_01 pad gets read-back (assert_PadAttr_PadGetsReadBack)"]
          why: '''In every cycle the check compares field `od_en` of the pad's `mio_attr_o` with the same field of the read-back of `MIO_PAD_ATTR_p`. A pad set to open drain while the register shows push-pull, or the reverse, fails it.'''
          milestone: "V2"
          priority: "2"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_ATTR_01h
          desc: '''The attribute output of MIO pad `p` shall equal, in field `input_disable`, what `MIO_PAD_ATTR_p` reads back.'''
          source: [
            '''!!MIO_PAD_ATTR.input_disable'''
            '''[Type RW HWExt](util/reggen/README.md#type-rw-hwext)'''
            '''[Generic Pad Wrapper](hw/top_${topname}/ip_autogen/pinmux/doc/theory_of_operation.md#generic-pad-wrapper)'''
          ]
          kind: "spec"
          testpoint: "pad_attr"
          checks: ["CHK_PAD_ATTR_01 pad gets read-back (assert_PadAttr_PadGetsReadBack)"]
          why: '''In every cycle the check compares field `input_disable` of the pad's `mio_attr_o` with the same field of the read-back of `MIO_PAD_ATTR_p`. A pad whose input is cut off while the register shows it on, or the reverse, fails it.'''
          milestone: "V2"
          priority: "2"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_ATTR_01i
          desc: '''The attribute output of MIO pad `p` shall equal, in field `slew_rate`, what `MIO_PAD_ATTR_p` reads back.'''
          source: [
            '''!!MIO_PAD_ATTR.slew_rate'''
            '''[Type RW HWExt](util/reggen/README.md#type-rw-hwext)'''
            '''[Generic Pad Wrapper](hw/top_${topname}/ip_autogen/pinmux/doc/theory_of_operation.md#generic-pad-wrapper)'''
          ]
          kind: "spec"
          testpoint: "pad_attr"
          checks: ["CHK_PAD_ATTR_01 pad gets read-back (assert_PadAttr_PadGetsReadBack)"]
          why: '''In every cycle the check compares both bits of field `slew_rate` of the pad's `mio_attr_o` with the read-back of `MIO_PAD_ATTR_p`. A pad that gets another slew rate than the register shows fails it.'''
          milestone: "V2"
          priority: "2"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_ATTR_01j
          desc: '''The attribute output of MIO pad `p` shall equal, in field `drive_strength`, what `MIO_PAD_ATTR_p` reads back.'''
          source: [
            '''!!MIO_PAD_ATTR.drive_strength'''
            '''[Type RW HWExt](util/reggen/README.md#type-rw-hwext)'''
            '''[Generic Pad Wrapper](hw/top_${topname}/ip_autogen/pinmux/doc/theory_of_operation.md#generic-pad-wrapper)'''
          ]
          kind: "spec"
          testpoint: "pad_attr"
          checks: ["CHK_PAD_ATTR_01 pad gets read-back (assert_PadAttr_PadGetsReadBack)"]
          why: '''In every cycle the check compares the four bits of field `drive_strength` of the pad's `mio_attr_o` with the read-back of `MIO_PAD_ATTR_p`. A pad that gets another drive strength than the register shows fails it.'''
          milestone: "V2"
          priority: "2"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_ATTR_02a
          desc: '''The attribute output of DIO pad `d` shall equal, in field `invert`, what `DIO_PAD_ATTR_d` reads back.'''
          source: [
            '''!!DIO_PAD_ATTR.invert'''
            '''[Type RW HWExt](util/reggen/README.md#type-rw-hwext)'''
            '''[Generic Pad Wrapper](hw/top_${topname}/ip_autogen/pinmux/doc/theory_of_operation.md#generic-pad-wrapper)'''
          ]
          kind: "spec"
          testpoint: "pad_attr"
          checks: ["CHK_PAD_ATTR_01 pad gets read-back (assert_PadAttr_PadGetsReadBack)"]
          why: '''In every cycle the check compares field `invert` of `dio_attr_o` for the pad with the same field of what a read of `DIO_PAD_ATTR_d` returns. A pad that inverts while the register reads 0, or the reverse, or takes the bit a cycle late, fails it.'''
          milestone: "V2"
          priority: "2"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_ATTR_02b
          desc: '''The attribute output of DIO pad `d` shall equal, in field `virtual_od_en`, what `DIO_PAD_ATTR_d` reads back.'''
          source: [
            '''!!DIO_PAD_ATTR.virtual_od_en'''
            '''[Type RW HWExt](util/reggen/README.md#type-rw-hwext)'''
            '''[Generic Pad Wrapper](hw/top_${topname}/ip_autogen/pinmux/doc/theory_of_operation.md#generic-pad-wrapper)'''
          ]
          kind: "spec"
          testpoint: "pad_attr"
          checks: ["CHK_PAD_ATTR_01 pad gets read-back (assert_PadAttr_PadGetsReadBack)"]
          why: '''In every cycle the check compares field `virtual_od_en` of the pad's `dio_attr_o` with the same field of the read-back of `DIO_PAD_ATTR_d`. A pad that gets a virtual open drain the register does not show, or loses one it shows, fails it.'''
          milestone: "V2"
          priority: "2"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_ATTR_02c
          desc: '''The attribute output of DIO pad `d` shall equal, in field `pull_en`, what `DIO_PAD_ATTR_d` reads back.'''
          source: [
            '''!!DIO_PAD_ATTR.pull_en'''
            '''[Type RW HWExt](util/reggen/README.md#type-rw-hwext)'''
            '''[Generic Pad Wrapper](hw/top_${topname}/ip_autogen/pinmux/doc/theory_of_operation.md#generic-pad-wrapper)'''
          ]
          kind: "spec"
          testpoint: "pad_attr"
          checks: ["CHK_PAD_ATTR_01 pad gets read-back (assert_PadAttr_PadGetsReadBack)"]
          why: '''In every cycle the check compares field `pull_en` of the pad's `dio_attr_o` with the same field of the read-back of `DIO_PAD_ATTR_d`. A pad that gets a pull the register does not show, or loses one it shows, fails it.'''
          milestone: "V2"
          priority: "2"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_ATTR_02d
          desc: '''The attribute output of DIO pad `d` shall equal, in field `pull_select`, what `DIO_PAD_ATTR_d` reads back.'''
          source: [
            '''!!DIO_PAD_ATTR.pull_select'''
            '''[Type RW HWExt](util/reggen/README.md#type-rw-hwext)'''
            '''[Generic Pad Wrapper](hw/top_${topname}/ip_autogen/pinmux/doc/theory_of_operation.md#generic-pad-wrapper)'''
          ]
          kind: "spec"
          testpoint: "pad_attr"
          checks: ["CHK_PAD_ATTR_01 pad gets read-back (assert_PadAttr_PadGetsReadBack)"]
          why: '''In every cycle the check compares field `pull_select` of the pad's `dio_attr_o` with the same field of the read-back of `DIO_PAD_ATTR_d`. A pad pulled the other way from what the register shows fails it.'''
          milestone: "V2"
          priority: "2"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_ATTR_02e
          desc: '''The attribute output of DIO pad `d` shall equal, in field `keeper_en`, what `DIO_PAD_ATTR_d` reads back.'''
          source: [
            '''!!DIO_PAD_ATTR.keeper_en'''
            '''[Type RW HWExt](util/reggen/README.md#type-rw-hwext)'''
            '''[Generic Pad Wrapper](hw/top_${topname}/ip_autogen/pinmux/doc/theory_of_operation.md#generic-pad-wrapper)'''
          ]
          kind: "spec"
          testpoint: "pad_attr"
          checks: ["CHK_PAD_ATTR_01 pad gets read-back (assert_PadAttr_PadGetsReadBack)"]
          why: '''In every cycle the check compares field `keeper_en` of the pad's `dio_attr_o` with the same field of the read-back of `DIO_PAD_ATTR_d`. A pad whose keeper is on while the register shows it off, or the reverse, fails it.'''
          milestone: "V2"
          priority: "2"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_ATTR_02f
          desc: '''The attribute output of DIO pad `d` shall equal, in field `schmitt_en`, what `DIO_PAD_ATTR_d` reads back.'''
          source: [
            '''!!DIO_PAD_ATTR.schmitt_en'''
            '''[Type RW HWExt](util/reggen/README.md#type-rw-hwext)'''
            '''[Generic Pad Wrapper](hw/top_${topname}/ip_autogen/pinmux/doc/theory_of_operation.md#generic-pad-wrapper)'''
          ]
          kind: "spec"
          testpoint: "pad_attr"
          checks: ["CHK_PAD_ATTR_01 pad gets read-back (assert_PadAttr_PadGetsReadBack)"]
          why: '''In every cycle the check compares field `schmitt_en` of the pad's `dio_attr_o` with the same field of the read-back of `DIO_PAD_ATTR_d`. A pad whose Schmitt trigger differs from what the register shows fails it.'''
          milestone: "V2"
          priority: "2"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_ATTR_02g
          desc: '''The attribute output of DIO pad `d` shall equal, in field `od_en`, what `DIO_PAD_ATTR_d` reads back.'''
          source: [
            '''!!DIO_PAD_ATTR.od_en'''
            '''[Type RW HWExt](util/reggen/README.md#type-rw-hwext)'''
            '''[Generic Pad Wrapper](hw/top_${topname}/ip_autogen/pinmux/doc/theory_of_operation.md#generic-pad-wrapper)'''
          ]
          kind: "spec"
          testpoint: "pad_attr"
          checks: ["CHK_PAD_ATTR_01 pad gets read-back (assert_PadAttr_PadGetsReadBack)"]
          why: '''In every cycle the check compares field `od_en` of the pad's `dio_attr_o` with the same field of the read-back of `DIO_PAD_ATTR_d`. A pad set to open drain while the register shows push-pull, or the reverse, fails it.'''
          milestone: "V2"
          priority: "2"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_ATTR_02h
          desc: '''The attribute output of DIO pad `d` shall equal, in field `input_disable`, what `DIO_PAD_ATTR_d` reads back.'''
          source: [
            '''!!DIO_PAD_ATTR.input_disable'''
            '''[Type RW HWExt](util/reggen/README.md#type-rw-hwext)'''
            '''[Generic Pad Wrapper](hw/top_${topname}/ip_autogen/pinmux/doc/theory_of_operation.md#generic-pad-wrapper)'''
          ]
          kind: "spec"
          testpoint: "pad_attr"
          checks: ["CHK_PAD_ATTR_01 pad gets read-back (assert_PadAttr_PadGetsReadBack)"]
          why: '''In every cycle the check compares field `input_disable` of the pad's `dio_attr_o` with the same field of the read-back of `DIO_PAD_ATTR_d`. A pad whose input is cut off while the register shows it on, or the reverse, fails it.'''
          milestone: "V2"
          priority: "2"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_ATTR_02i
          desc: '''The attribute output of DIO pad `d` shall equal, in field `slew_rate`, what `DIO_PAD_ATTR_d` reads back.'''
          source: [
            '''!!DIO_PAD_ATTR.slew_rate'''
            '''[Type RW HWExt](util/reggen/README.md#type-rw-hwext)'''
            '''[Generic Pad Wrapper](hw/top_${topname}/ip_autogen/pinmux/doc/theory_of_operation.md#generic-pad-wrapper)'''
          ]
          kind: "spec"
          testpoint: "pad_attr"
          checks: ["CHK_PAD_ATTR_01 pad gets read-back (assert_PadAttr_PadGetsReadBack)"]
          why: '''In every cycle the check compares both bits of field `slew_rate` of the pad's `dio_attr_o` with the read-back of `DIO_PAD_ATTR_d`. A pad that gets another slew rate than the register shows fails it.'''
          milestone: "V2"
          priority: "2"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_ATTR_02j
          desc: '''The attribute output of DIO pad `d` shall equal, in field `drive_strength`, what `DIO_PAD_ATTR_d` reads back.'''
          source: [
            '''!!DIO_PAD_ATTR.drive_strength'''
            '''[Type RW HWExt](util/reggen/README.md#type-rw-hwext)'''
            '''[Generic Pad Wrapper](hw/top_${topname}/ip_autogen/pinmux/doc/theory_of_operation.md#generic-pad-wrapper)'''
          ]
          kind: "spec"
          testpoint: "pad_attr"
          checks: ["CHK_PAD_ATTR_01 pad gets read-back (assert_PadAttr_PadGetsReadBack)"]
          why: '''In every cycle the check compares the four bits of field `drive_strength` of the pad's `dio_attr_o` with the read-back of `DIO_PAD_ATTR_d`. A pad that gets another drive strength than the register shows fails it.'''
          milestone: "V2"
          priority: "2"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_ATTR_03
          desc: '''The `invert` field of every pad shall read back as written.'''
          source: [
            '''[Generic Pad Wrapper](hw/top_${topname}/ip_autogen/pinmux/doc/theory_of_operation.md#generic-pad-wrapper)'''
          ]
          kind: "spec"
          testpoint: "pad_attr"
          checks: ["CHK_PAD_ATTR_02 invert reads back (assert_PadAttr_InvertReadsBack)"]
          why: '''On every pad type, from the pad's first attribute write on, the check compares the `invert` bit of the read-back with the `invert` bit of the last attribute write. A pad type that drops inversion, reading 0 after a write of 1, fails it; with _pad gets read-back_ (CHK_PAD_ATTR_01) the pad then inverts as written.'''
          milestone: "V2"
          priority: "2"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_ATTR_04
          desc: '''The `od_en` field of a BidirOd pad shall read back as written.'''
          source: [
            '''[Open drain / virtual open drain](hw/top_earlgrey/doc/design/README.md#open-drain--virtual-open-drain)'''
            '''[top_${topname}.hjson${eg(' `pinout.pads`')}](hw/top_${topname}/data/top_${topname}.hjson)'''
          ]
          kind: "spec"
          testpoint: "pad_attr"
          checks: ["CHK_PAD_ATTR_03 open drain reads back (assert_PadAttr_OpenDrainReadsBack)"]
          why: '''On every BidirOd pad, from the pad's first attribute write on, the check compares the `od_en` bit of the read-back with the `od_en` bit of the pad's last attribute write. A BidirOd pad whose `od_en` reads 0 after a write of 1, or keeps an older value, fails it.'''
          milestone: "V2"
          priority: "2"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_ATTR_05
          desc: '''The `virtual_od_en` field of a BidirStd pad shall read back as written.'''
          source: [
            '''[Open drain / virtual open drain](hw/top_earlgrey/doc/design/README.md#open-drain--virtual-open-drain)'''
            '''[top_${topname}.hjson${eg(' `pinout.pads`')}](hw/top_${topname}/data/top_${topname}.hjson)'''
          ]
          kind: "spec"
          testpoint: "pad_attr"
          checks: ["CHK_PAD_ATTR_04 virtual open drain reads back (assert_PadAttr_VirtualOpenDrainReadsBack)"]
          why: '''On every BidirStd pad, from the pad's first attribute write on, the check compares the `virtual_od_en` bit of the read-back with the `virtual_od_en` bit of the pad's last attribute write. A BidirStd pad whose `virtual_od_en` reads 0 after a write of 1, or keeps an older value, fails it.'''
          milestone: "V2"
          priority: "2"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_ATTR_06
          desc: '''The `od_en` field of every pad not of type BidirOd shall read back 0.'''
          source: [
            '''[Open drain / virtual open drain](hw/top_earlgrey/doc/design/README.md#open-drain--virtual-open-drain)'''
            '''[Pad Attributes](hw/top_${topname}/ip_autogen/pinmux/doc/programmers_guide.md#pad-attributes)'''
            '''[top_${topname}.hjson${eg(' `pinout.pads`')}](hw/top_${topname}/data/top_${topname}.hjson)'''
          ]
          kind: "spec"
          testpoint: "pad_attr"
          checks: ["CHK_PAD_ATTR_05 no open drain elsewhere (assert_PadAttr_NoOpenDrainElsewhere)"]
          why: '''On every pad not of type BidirOd, the check compares the `od_en` bit of the read-back with 0 in every cycle, whatever software wrote. A pad of another type that stores and returns a written `od_en` bit fails it.'''
          milestone: "V2"
          priority: "2"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_ATTR_07
          desc: '''The `virtual_od_en` field of every pad not of type BidirStd shall read back 0.'''
          source: [
            '''[Open drain / virtual open drain](hw/top_earlgrey/doc/design/README.md#open-drain--virtual-open-drain)'''
            '''[Pad Attributes](hw/top_${topname}/ip_autogen/pinmux/doc/programmers_guide.md#pad-attributes)'''
            '''[top_${topname}.hjson${eg(' `pinout.pads`')}](hw/top_${topname}/data/top_${topname}.hjson)'''
          ]
          kind: "spec"
          testpoint: "pad_attr"
          checks: ["CHK_PAD_ATTR_06 no virtual open drain elsewhere (assert_PadAttr_NoVirtualOpenDrainElsewhere)"]
          why: '''On every pad not of type BidirStd, the check compares the `virtual_od_en` bit of the read-back with 0 in every cycle, whatever software wrote. A pad of another type that stores and returns a written `virtual_od_en` bit fails it.'''
          milestone: "V2"
          priority: "2"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_ATTR_08c
          desc: '''The field `pull_en` shall read back as written where the pad's type keeps the field.'''
          source: [
            '''!!MIO_PAD_ATTR'''
            '''[Pad Attributes](hw/top_${topname}/ip_autogen/pinmux/doc/programmers_guide.md#pad-attributes)'''
            '''[top_${topname}.hjson${eg(' `pinout.pads`')}](hw/top_${topname}/data/top_${topname}.hjson)'''
          ]
          kind: "spec"
          testpoint: "pad_attr"
          checks: ["CHK_PAD_ATTR_07 supported bits read back (assert_PadAttr_SupportedBitsReadBack)"]
          why: '''Per pad type the check requires the `pull_en` bit of the read-back to read 0 when written 0, and to read 1 for a write of 1 on every pad of the type once one pad of the type has done so. A kept bit that reads 1 after a write of 0, or 0 after a write of 1 in a later cycle or on another pad of the type, fails it.'''
          milestone: "V2"
          priority: "2"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_ATTR_08d
          desc: '''The field `pull_select` shall read back as written where the pad's type keeps the field.'''
          source: [
            '''!!MIO_PAD_ATTR'''
            '''[Pad Attributes](hw/top_${topname}/ip_autogen/pinmux/doc/programmers_guide.md#pad-attributes)'''
            '''[top_${topname}.hjson${eg(' `pinout.pads`')}](hw/top_${topname}/data/top_${topname}.hjson)'''
          ]
          kind: "spec"
          testpoint: "pad_attr"
          checks: ["CHK_PAD_ATTR_07 supported bits read back (assert_PadAttr_SupportedBitsReadBack)"]
          why: '''Per pad type the check requires the `pull_select` bit of the read-back to read 0 when written 0, and to read 1 for a write of 1 on every pad of the type once one pad of the type has done so. A kept bit that reads 1 after a write of 0, or 0 after a write of 1 in a later cycle or on another pad of the type, fails it.'''
          milestone: "V2"
          priority: "2"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_ATTR_08e
          desc: '''The field `keeper_en` shall read back as written where the pad's type keeps the field.'''
          source: [
            '''!!MIO_PAD_ATTR'''
            '''[Pad Attributes](hw/top_${topname}/ip_autogen/pinmux/doc/programmers_guide.md#pad-attributes)'''
            '''[top_${topname}.hjson${eg(' `pinout.pads`')}](hw/top_${topname}/data/top_${topname}.hjson)'''
          ]
          kind: "spec"
          testpoint: "pad_attr"
          checks: ["CHK_PAD_ATTR_07 supported bits read back (assert_PadAttr_SupportedBitsReadBack)"]
          why: '''Per pad type the check requires the `keeper_en` bit of the read-back to read 0 when written 0, and to read 1 for a write of 1 on every pad of the type once one pad of the type has done so. A kept bit that reads 1 after a write of 0, or 0 after a write of 1 in a later cycle or on another pad of the type, fails it.'''
          milestone: "V2"
          priority: "2"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_ATTR_08f
          desc: '''The field `schmitt_en` shall read back as written where the pad's type keeps the field.'''
          source: [
            '''!!MIO_PAD_ATTR'''
            '''[Pad Attributes](hw/top_${topname}/ip_autogen/pinmux/doc/programmers_guide.md#pad-attributes)'''
            '''[top_${topname}.hjson${eg(' `pinout.pads`')}](hw/top_${topname}/data/top_${topname}.hjson)'''
          ]
          kind: "spec"
          testpoint: "pad_attr"
          checks: ["CHK_PAD_ATTR_07 supported bits read back (assert_PadAttr_SupportedBitsReadBack)"]
          why: '''Per pad type the check requires the `schmitt_en` bit of the read-back to read 0 when written 0, and to read 1 for a write of 1 on every pad of the type once one pad of the type has done so. A kept bit that reads 1 after a write of 0, or 0 after a write of 1 in a later cycle or on another pad of the type, fails it.'''
          milestone: "V2"
          priority: "2"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_ATTR_08g
          desc: '''The field `input_disable` shall read back as written where the pad's type keeps the field.'''
          source: [
            '''!!MIO_PAD_ATTR'''
            '''[Pad Attributes](hw/top_${topname}/ip_autogen/pinmux/doc/programmers_guide.md#pad-attributes)'''
            '''[top_${topname}.hjson${eg(' `pinout.pads`')}](hw/top_${topname}/data/top_${topname}.hjson)'''
          ]
          kind: "spec"
          testpoint: "pad_attr"
          checks: ["CHK_PAD_ATTR_07 supported bits read back (assert_PadAttr_SupportedBitsReadBack)"]
          why: '''Per pad type the check requires the `input_disable` bit of the read-back to read 0 when written 0, and to read 1 for a write of 1 on every pad of the type once one pad of the type has done so. A kept bit that reads 1 after a write of 0, or 0 after a write of 1 in a later cycle or on another pad of the type, fails it.'''
          milestone: "V2"
          priority: "2"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_ATTR_08h
          desc: '''Each bit of the field `slew_rate` shall read back as written where the pad's type keeps that bit.'''
          source: [
            '''!!MIO_PAD_ATTR'''
            '''[Pad Attributes](hw/top_${topname}/ip_autogen/pinmux/doc/programmers_guide.md#pad-attributes)'''
            '''[top_${topname}.hjson${eg(' `pinout.pads`')}](hw/top_${topname}/data/top_${topname}.hjson)'''
          ]
          kind: "spec"
          testpoint: "pad_attr"
          checks: ["CHK_PAD_ATTR_07 supported bits read back (assert_PadAttr_SupportedBitsReadBack)"]
          why: '''Per pad type and per bit of `slew_rate`, the check requires the bit of the read-back to read 0 when written 0, and to read 1 for a write of 1 on every pad of the type once one pad of the type has done so. A kept bit that reads 1 after a write of 0, or 0 after a write of 1 in a later cycle or on another pad of the type, fails it.'''
          milestone: "V2"
          priority: "2"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_ATTR_08i
          desc: '''Each bit of the field `drive_strength` shall read back as written where the pad's type keeps that bit.'''
          source: [
            '''!!MIO_PAD_ATTR'''
            '''[Pad Attributes](hw/top_${topname}/ip_autogen/pinmux/doc/programmers_guide.md#pad-attributes)'''
            '''[top_${topname}.hjson${eg(' `pinout.pads`')}](hw/top_${topname}/data/top_${topname}.hjson)'''
          ]
          kind: "spec"
          testpoint: "pad_attr"
          checks: ["CHK_PAD_ATTR_07 supported bits read back (assert_PadAttr_SupportedBitsReadBack)"]
          why: '''Per pad type and per bit of `drive_strength`, the check requires the bit of the read-back to read 0 when written 0, and to read 1 for a write of 1 on every pad of the type once one pad of the type has done so. A kept bit that reads 1 after a write of 0, or 0 after a write of 1 in a later cycle or on another pad of the type, fails it.'''
          milestone: "V2"
          priority: "2"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_ATTR_09c
          desc: '''The field `pull_en` shall read back 0 where the pad's type does not keep the field.'''
          source: [
            '''[Pad Attributes](hw/top_${topname}/ip_autogen/pinmux/doc/programmers_guide.md#pad-attributes)'''
            '''[top_${topname}.hjson${eg(' `pinout.pads`')}](hw/top_${topname}/data/top_${topname}.hjson)'''
          ]
          kind: "spec"
          testpoint: "pad_attr"
          checks: ["CHK_PAD_ATTR_08 unsupported bits read 0 (assert_PadAttr_UnsupportedBitsRead0)"]
          why: '''Per pad type the check requires the `pull_en` bit of the read-back to read 0 when written 0, and to read 0 on every pad of the type, whatever is written, once a write of 1 has read 0 on one pad of the type. A bit not kept that reads 1 after a write of 0, or 1 after a write of 1 in a later cycle or on another pad of the type, fails it.'''
          milestone: "V2"
          priority: "2"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_ATTR_09d
          desc: '''The field `pull_select` shall read back 0 where the pad's type does not keep the field.'''
          source: [
            '''[Pad Attributes](hw/top_${topname}/ip_autogen/pinmux/doc/programmers_guide.md#pad-attributes)'''
            '''[top_${topname}.hjson${eg(' `pinout.pads`')}](hw/top_${topname}/data/top_${topname}.hjson)'''
          ]
          kind: "spec"
          testpoint: "pad_attr"
          checks: ["CHK_PAD_ATTR_08 unsupported bits read 0 (assert_PadAttr_UnsupportedBitsRead0)"]
          why: '''Per pad type the check requires the `pull_select` bit of the read-back to read 0 when written 0, and to read 0 on every pad of the type, whatever is written, once a write of 1 has read 0 on one pad of the type. A bit not kept that reads 1 after a write of 0, or 1 after a write of 1 in a later cycle or on another pad of the type, fails it.'''
          milestone: "V2"
          priority: "2"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_ATTR_09e
          desc: '''The field `keeper_en` shall read back 0 where the pad's type does not keep the field.'''
          source: [
            '''[Pad Attributes](hw/top_${topname}/ip_autogen/pinmux/doc/programmers_guide.md#pad-attributes)'''
            '''[top_${topname}.hjson${eg(' `pinout.pads`')}](hw/top_${topname}/data/top_${topname}.hjson)'''
          ]
          kind: "spec"
          testpoint: "pad_attr"
          checks: ["CHK_PAD_ATTR_08 unsupported bits read 0 (assert_PadAttr_UnsupportedBitsRead0)"]
          why: '''Per pad type the check requires the `keeper_en` bit of the read-back to read 0 when written 0, and to read 0 on every pad of the type, whatever is written, once a write of 1 has read 0 on one pad of the type. A bit not kept that reads 1 after a write of 0, or 1 after a write of 1 in a later cycle or on another pad of the type, fails it.'''
          milestone: "V2"
          priority: "2"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_ATTR_09f
          desc: '''The field `schmitt_en` shall read back 0 where the pad's type does not keep the field.'''
          source: [
            '''[Pad Attributes](hw/top_${topname}/ip_autogen/pinmux/doc/programmers_guide.md#pad-attributes)'''
            '''[top_${topname}.hjson${eg(' `pinout.pads`')}](hw/top_${topname}/data/top_${topname}.hjson)'''
          ]
          kind: "spec"
          testpoint: "pad_attr"
          checks: ["CHK_PAD_ATTR_08 unsupported bits read 0 (assert_PadAttr_UnsupportedBitsRead0)"]
          why: '''Per pad type the check requires the `schmitt_en` bit of the read-back to read 0 when written 0, and to read 0 on every pad of the type, whatever is written, once a write of 1 has read 0 on one pad of the type. A bit not kept that reads 1 after a write of 0, or 1 after a write of 1 in a later cycle or on another pad of the type, fails it.'''
          milestone: "V2"
          priority: "2"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_ATTR_09g
          desc: '''The field `input_disable` shall read back 0 where the pad's type does not keep the field.'''
          source: [
            '''[Pad Attributes](hw/top_${topname}/ip_autogen/pinmux/doc/programmers_guide.md#pad-attributes)'''
            '''[top_${topname}.hjson${eg(' `pinout.pads`')}](hw/top_${topname}/data/top_${topname}.hjson)'''
          ]
          kind: "spec"
          testpoint: "pad_attr"
          checks: ["CHK_PAD_ATTR_08 unsupported bits read 0 (assert_PadAttr_UnsupportedBitsRead0)"]
          why: '''Per pad type the check requires the `input_disable` bit of the read-back to read 0 when written 0, and to read 0 on every pad of the type, whatever is written, once a write of 1 has read 0 on one pad of the type. A bit not kept that reads 1 after a write of 0, or 1 after a write of 1 in a later cycle or on another pad of the type, fails it.'''
          milestone: "V2"
          priority: "2"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_ATTR_09h
          desc: '''Each bit of the field `slew_rate` shall read back 0 where the pad's type does not keep that bit.'''
          source: [
            '''[Pad Attributes](hw/top_${topname}/ip_autogen/pinmux/doc/programmers_guide.md#pad-attributes)'''
            '''[top_${topname}.hjson${eg(' `pinout.pads`')}](hw/top_${topname}/data/top_${topname}.hjson)'''
          ]
          kind: "spec"
          testpoint: "pad_attr"
          checks: ["CHK_PAD_ATTR_08 unsupported bits read 0 (assert_PadAttr_UnsupportedBitsRead0)"]
          why: '''Per pad type and per bit of `slew_rate`, the check requires the bit of the read-back to read 0 when written 0, and to read 0 on every pad of the type, whatever is written, once a write of 1 has read 0 on one pad of the type. A bit not kept that reads 1 after a write of 0, or 1 after a write of 1 in a later cycle or on another pad of the type, fails it.'''
          milestone: "V2"
          priority: "2"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_ATTR_09i
          desc: '''Each bit of the field `drive_strength` shall read back 0 where the pad's type does not keep that bit.'''
          source: [
            '''[Pad Attributes](hw/top_${topname}/ip_autogen/pinmux/doc/programmers_guide.md#pad-attributes)'''
            '''[top_${topname}.hjson${eg(' `pinout.pads`')}](hw/top_${topname}/data/top_${topname}.hjson)'''
          ]
          kind: "spec"
          testpoint: "pad_attr"
          checks: ["CHK_PAD_ATTR_08 unsupported bits read 0 (assert_PadAttr_UnsupportedBitsRead0)"]
          why: '''Per pad type and per bit of `drive_strength`, the check requires the bit of the read-back to read 0 when written 0, and to read 0 on every pad of the type, whatever is written, once a write of 1 has read 0 on one pad of the type. A bit not kept that reads 1 after a write of 0, or 1 after a write of 1 in a later cycle or on another pad of the type, fails it.'''
          milestone: "V2"
          priority: "2"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_ATTR_10
          desc: '''After reset, every pad's attribute output shall be its reset value, with the fields its type does not keep at 0. ${eg("Every field's reset value is 0, except `pull_en` of MIO pad 30 (IOC8, TAP strap 0), which is 1.", "Every field's reset value is 0, except the fields the `attrs` of the pad's entry in the top description set.")}'''
          source: [
            '''!!MIO_PAD_ATTR'''
            '''!!DIO_PAD_ATTR'''
            '''[top_${topname}.hjson${eg(' `pinout`')}](hw/top_${topname}/data/top_${topname}.hjson)'''
            '''[top_${topname}.hjson${eg(' `pinout.pads IOC8`')}](hw/top_${topname}/data/top_${topname}.hjson)'''
            '''[top_${topname}.hjson${eg(' `targets.asic.pinmux.special_signals tap0`')}](hw/top_${topname}/data/top_${topname}.hjson)'''
          ]
          kind: "spec"
          testpoint: "pad_attr"
          checks: ["CHK_PAD_ATTR_09 reset attributes (assert_PadAttr_ResetAttributes)"]
          why: '''${eg("Until the pad's first attribute write after reset, the check compares the pad's attribute output with the reset attributes: 0 in every field but `pull_en` on MIO pad 30, with each field the pad's type does not keep at 0; the kept fields are the ones _supported bits read back_ (CHK_PAD_ATTR_07) holds the type to. A pad that leaves reset with another value, with a field its type does not keep at 1, or pad 30 without its pull where its type keeps `pull_en`, fails it.", 'Not written for this top.')}'''
          milestone: "V2"
          priority: "2"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
      ]
    }
    {
      name: '''Sleep retention'''
      conditions: [
        '''"pad" is MIO pad `p` or DIO pad `d`; "status bit" is its bit in `MIO_PAD_SLEEP_STATUS` or `DIO_PAD_SLEEP_STATUS`; "sleep entry" is a rise of `sleep_en_i`. The mode rows hold while no TAP owns the pad and the sleep mode is unchanged since sleep entry.'''
      ]
      requirements: [
        {
          name: REQ_SLP_01
          desc: '''At sleep entry, the status bit of every pad whose sleep enable is 1 shall become 1, unless a software clear of that bit lands in the same cycle (`REQ_SLP_09`).'''
          source: [
            '''!!MIO_PAD_SLEEP_EN.EN'''
            '''[Sleep Features](hw/top_${topname}/ip_autogen/pinmux/doc/programmers_guide.md#sleep-features)'''
          ]
          kind: "spec"
          testpoint: "pad_sleep"
          checks: ["CHK_PAD_SLEEP_01 bit set at entry (assert_PadSleep_BitSetAtEntry)"]
          why: '''For every sleep entry with the pad's sleep enable at 1 and no software clear of its status bit, the check requires the bit to be 1 in the next cycle. A bit that stays 0, or rises a cycle late, fails it; a cycle with a clear is decided by _clear wins_ (CHK_PAD_SLEEP_05).'''
          milestone: "V2"
          priority: "2"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_SLP_02
          desc: '''A status bit shall become 1 only at sleep entry, and only if the pad's sleep enable is 1.'''
          source: [
            '''!!MIO_PAD_SLEEP_STATUS.EN'''
            '''[Sleep Features](hw/top_${topname}/ip_autogen/pinmux/doc/programmers_guide.md#sleep-features)'''
          ]
          kind: "spec"
          testpoint: "pad_sleep"
          checks: ["CHK_PAD_SLEEP_02 bit set only at entry (assert_PadSleep_BitSetOnlyAtEntry)"]
          why: '''For every rise of a status bit the check requires a sleep entry with the pad's sleep enable at 1 in the cycle before. A bit that rises with the enable at 0, without a rise of `sleep_en_i`, or while `sleep_en_i` merely stays high, fails it.'''
          milestone: "V2"
          priority: "2"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_SLP_03a
          desc: '''While its status bit is 1 and its sleep mode is 0, a pad's output shall be 0.'''
          source: [
            '''!!MIO_PAD_SLEEP_MODE.OUT'''
            '''[Sleep Features](hw/top_${topname}/ip_autogen/pinmux/doc/programmers_guide.md#sleep-features)'''
          ]
          kind: "spec"
          testpoint: "pad_sleep"
          checks: ["CHK_PAD_SLEEP_06 tie low in sleep (assert_PadSleep_TieLowInSleep)"]
          why: '''While the status bit is 1 and the mode taken at the entry is 0, the check compares the output of a pad no TAP owns with 0 in the same cycle. A pad that still carries its peripheral or its select's drive fails it.'''
          milestone: "V2"
          priority: "2"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_SLP_03b
          desc: '''While its status bit is 1 and its sleep mode is 0, a pad's output enable shall be 1, so the pad drives 0.'''
          source: [
            '''!!MIO_PAD_SLEEP_MODE.OUT'''
            '''[Sleep Features](hw/top_${topname}/ip_autogen/pinmux/doc/programmers_guide.md#sleep-features)'''
          ]
          kind: "spec"
          testpoint: "pad_sleep"
          checks: ["CHK_PAD_SLEEP_06 tie low in sleep (assert_PadSleep_TieLowInSleep)"]
          why: '''While held in mode 0, the check compares the output enable of a pad no TAP owns with 1. A pad left high-Z, or following its peripheral's enable, fails it.'''
          milestone: "V2"
          priority: "2"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_SLP_04a
          desc: '''While its status bit is 1 and its sleep mode is 1, a pad's output shall be 1.'''
          source: [
            '''!!MIO_PAD_SLEEP_MODE.OUT'''
          ]
          kind: "spec"
          testpoint: "pad_sleep"
          checks: ["CHK_PAD_SLEEP_07 tie high in sleep (assert_PadSleep_TieHighInSleep)"]
          why: '''While the status bit is 1 and the mode taken at the entry is 1, the check compares the output of a pad no TAP owns with 1 in the same cycle. A pad that still carries its peripheral or its select's drive fails it.'''
          milestone: "V2"
          priority: "2"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_SLP_04b
          desc: '''While its status bit is 1 and its sleep mode is 1, a pad's output enable shall be 1, so the pad drives 1.'''
          source: [
            '''!!MIO_PAD_SLEEP_MODE.OUT'''
          ]
          kind: "spec"
          testpoint: "pad_sleep"
          checks: ["CHK_PAD_SLEEP_07 tie high in sleep (assert_PadSleep_TieHighInSleep)"]
          why: '''While held in mode 1, the check compares the output enable of a pad no TAP owns with 1. A pad left high-Z, or following its peripheral's enable, fails it.'''
          milestone: "V2"
          priority: "2"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_SLP_05a
          desc: '''While its status bit is 1 and its sleep mode is 2, a pad's output enable shall be 0: the pad is high-Z.'''
          source: [
            '''!!MIO_PAD_SLEEP_MODE.OUT'''
          ]
          kind: "spec"
          testpoint: "pad_sleep"
          checks: ["CHK_PAD_SLEEP_08 high-Z in sleep (assert_PadSleep_HighZInSleep)"]
          why: '''While the status bit is 1 and the mode taken at the entry is 2, the check compares the output enable of a pad no TAP owns with 0 in the same cycle. A pad that keeps driving in sleep fails it.'''
          milestone: "V2"
          priority: "2"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_SLP_05b
          desc: '''While its status bit is 1 and its sleep mode is 2, a pad's output shall be 0.'''
          source: [
            '''!!MIO_PAD_SLEEP_MODE.OUT'''
          ]
          kind: "spec"
          testpoint: "pad_sleep"
          checks: ["CHK_PAD_SLEEP_08 high-Z in sleep (assert_PadSleep_HighZInSleep)"]
          why: '''While held in mode 2, the check compares the output of a pad no TAP owns with 0. A pad that leaves its peripheral's data or 1 on its output fails it.'''
          milestone: "V2"
          priority: "2"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_SLP_06a
          desc: '''While its status bit is 1 and its sleep mode is 3, a pad shall keep the output it drove in the last cycle before the bit became 1.'''
          source: [
            '''!!MIO_PAD_SLEEP_MODE.OUT'''
            '''[Retention Logic](hw/top_${topname}/ip_autogen/pinmux/doc/theory_of_operation.md#retention-logic)'''
          ]
          kind: "spec"
          testpoint: "pad_sleep"
          checks: ["CHK_PAD_SLEEP_09 keep holds (assert_PadSleep_KeepHolds)"]
          why: '''While the status bit is 1 and the mode taken at the entry is 3, the check compares the output of a pad no TAP owns with the output it drove in the last cycle before the bit became 1. A pad that follows its peripheral or its select, or keeps the value of another cycle, fails it. No specification states which output a JTAG pad that a TAP owned in that last cycle keeps, so the check claims none for it.'''
          milestone: "V2"
          priority: "2"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_SLP_06b
          desc: '''While its status bit is 1 and its sleep mode is 3, a pad shall keep the output enable it drove in the last cycle before the bit became 1.'''
          source: [
            '''!!MIO_PAD_SLEEP_MODE.OUT'''
            '''[Retention Logic](hw/top_${topname}/ip_autogen/pinmux/doc/theory_of_operation.md#retention-logic)'''
          ]
          kind: "spec"
          testpoint: "pad_sleep"
          checks: ["CHK_PAD_SLEEP_09 keep holds (assert_PadSleep_KeepHolds)"]
          why: '''While held in mode 3, the check compares the output enable of a pad no TAP owns with the one it drove in the last cycle before the bit became 1. A pad that turns high-Z after driving, or starts to drive after being high-Z, fails it. No specification states which enable a JTAG pad that a TAP owned in that last cycle keeps, so the check claims none for it.'''
          milestone: "V2"
          priority: "2"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_SLP_07
          desc: '''Once 1, a status bit shall stay 1 until software writes 0 to it, whatever `sleep_en_i`, the sleep enable and the peripheral do.'''
          source: [
            '''!!MIO_PAD_SLEEP_STATUS.EN'''
            '''[Retention Logic](hw/top_${topname}/ip_autogen/pinmux/doc/theory_of_operation.md#retention-logic)'''
          ]
          kind: "spec"
          testpoint: "pad_sleep"
          checks: ["CHK_PAD_SLEEP_03 bit holds until cleared (assert_PadSleep_BitHoldsUntilCleared)", "CHK_PAD_SLEEP_04 clear releases (assert_PadSleep_ClearReleases)"]
          why: '''The check _bit holds until cleared_ (CHK_PAD_SLEEP_03) requires a bit at 1 to be 1 in the next cycle unless software clears it, whatever `sleep_en_i`, the sleep enable and the peripherals do; a bit that falls when sleep ends, or on a write of 1, fails it. The check _clear releases_ (CHK_PAD_SLEEP_04) requires a software clear to give 0 in the next cycle, so the bit ends at the clear and not later.'''
          milestone: "V2"
          priority: "2"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_SLP_08
          desc: '''While its status bit is 0, a pad shall drive what it drives awake: an MIO pad what its output select names, a DIO pad the output and output enable of its own peripheral.'''
          source: [
            '''[Retention Logic](hw/top_${topname}/ip_autogen/pinmux/doc/theory_of_operation.md#retention-logic)'''
            '''[Sleep Features](hw/top_${topname}/ip_autogen/pinmux/doc/programmers_guide.md#sleep-features)'''
          ]
          kind: "spec"
          testpoint: "sleep_release"
          checks: ["CHK_PAD_OUTPUT_01 tie 0 drives 0 (assert_PadOutput_Tie0Drives0)", "CHK_PAD_OUTPUT_02 tie 1 drives 1 (assert_PadOutput_Tie1Drives1)", "CHK_PAD_OUTPUT_03 select 2 is high-Z (assert_PadOutput_Select2IsHighZ)", "CHK_PAD_OUTPUT_04 drives selected output (assert_PadOutput_DrivesSelectedOutput)", "CHK_PAD_OUTPUT_05 no output is high-Z (assert_PadOutput_NoOutputIsHighZ)", "CHK_PAD_OUTPUT_06 DIO drives its peripheral (assert_PadOutput_DIODrivesItsPeripheral)"]
          why: '''Each holds in every cycle the pad is awake, its status bit at 0, whether the bit was never set or was cleared; together they cover every select and every DIO pad. A pad that still drives the value of its sleep mode in a cycle its bit reads 0 fails the check of its select; a JTAG pad a TAP owns is decided by the JTAG pad checks.'''
          milestone: "V2"
          priority: "2"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_SLP_09
          desc: '''When sleep entry sets a status bit in the cycle software writes 0 to that bit, the bit shall end 0: software's clear wins.'''
          source: [
            '''!!MIO_PAD_SLEEP_STATUS'''
            '''[Type RW](util/reggen/README.md#type-rw)'''
            '''[Simultaneous SW and HW access](util/reggen/README.md#simultaneous-sw-and-hw-access)'''
          ]
          kind: "spec"
          testpoint: "pad_sleep"
          checks: ["CHK_PAD_SLEEP_05 clear wins (assert_PadSleep_ClearWins)"]
          why: '''For a cycle with both a sleep entry, the pad's sleep enable at 1, and a software clear of the bit, the check requires the bit to be 0 in the next cycle. A design that lets the hardware set win fails it.'''
          milestone: "V2"
          priority: "2"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_SLP_10a
          desc: '''A write to a pad's sleep mode while its status bit is 1 shall leave the pad as it is.'''
          source: [
            '''[Retention Logic](hw/top_${topname}/ip_autogen/pinmux/doc/theory_of_operation.md#retention-logic)'''
            '''[Sleep Features](hw/top_${topname}/ip_autogen/pinmux/doc/programmers_guide.md#sleep-features)'''
          ]
          kind: "spec"
          testpoint: "pad_sleep"
          checks: ["CHK_PAD_SLEEP_10 mode write while held (assert_PadSleep_ModeWriteWhileHeld)"]
          why: '''After a write to the sleep mode while the bit is 1, the check requires the pad to keep driving the sleep value of the mode taken at the entry. A design that applies the new mode at once changes the pad's drive and fails it.'''
          milestone: "V2"
          priority: "2"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_SLP_10b
          desc: '''After a write to a pad's sleep mode while its status bit is 1, the new mode shall act at the next sleep entry.'''
          source: [
            '''[Retention Logic](hw/top_${topname}/ip_autogen/pinmux/doc/theory_of_operation.md#retention-logic)'''
            '''[Sleep Features](hw/top_${topname}/ip_autogen/pinmux/doc/programmers_guide.md#sleep-features)'''
          ]
          kind: "spec"
          testpoint: "pad_sleep"
          checks: ["CHK_PAD_SLEEP_06 tie low in sleep (assert_PadSleep_TieLowInSleep)", "CHK_PAD_SLEEP_07 tie high in sleep (assert_PadSleep_TieHighInSleep)", "CHK_PAD_SLEEP_08 high-Z in sleep (assert_PadSleep_HighZInSleep)", "CHK_PAD_SLEEP_09 keep holds (assert_PadSleep_KeepHolds)"]
          why: '''Each of the four sleep mode checks compares a held pad's drive with the sleep value of the mode the register held at the sleep entry that set its bit, so after a release the next entry takes the mode written while held. A design that keeps the old mode, or never takes the new one, drives the wrong sleep value and fails one of them. That the register holds the written mode is checked by the generated register checker.'''
          milestone: "V2"
          priority: "2"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
      ]
    }
    {
      name: '''Register locks'''
      conditions: [
        '''"lock" is one bit of a `*_REGWEN` register; it locks the registers of the same index. The rule that a locked pad's attributes do not change (`REQ_LOCK_03a`, `REQ_LOCK_03b`) holds except on a JTAG pad while a TAP owns it.'''
      ]
      requirements: [
        {
          name: REQ_LOCK_01a
          desc: '''Every lock shall read 1 after reset.'''
          source: [
            '''the register description: the `EN` field of each `*_REGWEN`, e.g. !!MIO_PAD_ATTR_REGWEN.EN `resval: "1"`, on `clk_i` with `rst_ni` ([pinmux.hjson `clocking`](hw/top_${topname}/ip_autogen/pinmux/data/pinmux.hjson))'''
            '''[Configuration and Register Definition File Format](util/reggen/README.md#configuration-and-register-definition-file-format)'''
          ]
          kind: "spec"
          testpoint: "fpv_csr_rw"
          checks: ["the generated CSR checker"]
          why: '''After reset the generated register checker expects every lock at its reset value 1, bit 31 of `ALERT_TEST` included, and compares each lock's value and read with it; a lock that leaves reset at 0 fails the first compare.'''
          milestone: "V2"
          priority: "2"
          security: true
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_LOCK_01b
          desc: '''Once software writes 0 to a lock, the lock shall stay 0 until reset.'''
          source: [
            '''[Configuration and Register Definition File Format](util/reggen/README.md#configuration-and-register-definition-file-format)'''
            '''[Pad Attributes](hw/top_${topname}/ip_autogen/pinmux/doc/programmers_guide.md#pad-attributes)'''
          ]
          kind: "spec"
          testpoint: "fpv_csr_rw"
          checks: ["the generated CSR checker"]
          why: '''The generated register checker predicts each lock as `rw0c`: an accepted write of 0 clears it and nothing sets it; a lock that returns to 1 before a reset fails the compare.'''
          milestone: "V2"
          priority: "2"
          security: true
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_LOCK_01c
          desc: '''A write of 1 to a lock that is 0 shall not reopen it.'''
          source: [
            '''the register description: each lock `rw0c`'''
            '''[Configuration and Register Definition File Format](util/reggen/README.md#configuration-and-register-definition-file-format)'''
            '''[Pinmux Configuration](hw/top_${topname}/ip_autogen/pinmux/doc/programmers_guide.md#pinmux-configuration)'''
          ]
          kind: "spec"
          testpoint: "fpv_csr_rw"
          checks: ["the generated CSR checker"]
          why: '''The generated register checker predicts each lock as `rw0c`, which keeps a closed lock at 0 over a write of 1; a lock that such a write reopens fails the compare.'''
          milestone: "V2"
          priority: "2"
          security: true
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_LOCK_02
          desc: '''While a lock is 0, a write to a register it locks shall leave that register unchanged.'''
          source: [
            '''!!MIO_PERIPH_INSEL_REGWEN.EN'''
            '''[Configuration and Register Definition File Format](util/reggen/README.md#configuration-and-register-definition-file-format)'''
          ]
          kind: "spec"
          testpoint: "fpv_csr_rw"
          checks: ["CHK_REGWEN_02 locked read-back holds (assert_Regwen_LockedReadBackHolds)"]
          why: '''The generated register checker holds each register whose lock reads 0 over every write to it; a register that takes such a write fails it. The attribute registers, whose value the pinmux supplies, are decided by _locked read-back holds_ (CHK_REGWEN_02) on every pad, a JTAG pad a TAP owns included: a locked attribute register whose read-back changes fails it.'''
          milestone: "V2"
          priority: "2"
          security: true
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_LOCK_03a
          desc: '''While a pad's attribute lock is 0, its attribute output shall not change.'''
          source: [
            '''!!MIO_PAD_ATTR_REGWEN.EN'''
            '''[Pad Attributes](hw/top_${topname}/ip_autogen/pinmux/doc/programmers_guide.md#pad-attributes)'''
          ]
          kind: "spec"
          testpoint: "regwen"
          checks: ["CHK_REGWEN_01 locked attribute holds (assert_Regwen_LockedAttributeHolds)"]
          why: '''It compares the pad's attribute output in each cycle its lock is 0 with the output in the next cycle, on a pad that is not a JTAG pad a TAP owns. Any change, from a write or from anything else, fails it.'''
          milestone: "V2"
          priority: "2"
          security: true
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_LOCK_03b
          desc: '''While a pad's attribute lock is 0, what its attribute register reads back shall not change.'''
          source: [
            '''!!MIO_PAD_ATTR_REGWEN.EN'''
            '''[Pad Attributes](hw/top_${topname}/ip_autogen/pinmux/doc/programmers_guide.md#pad-attributes)'''
          ]
          kind: "spec"
          testpoint: "regwen"
          checks: ["CHK_REGWEN_02 locked read-back holds (assert_Regwen_LockedReadBackHolds)"]
          why: '''It compares what the pad's attribute register reads back in each cycle its lock is 0 with the read-back in the next cycle, on every pad, a JTAG pad a TAP owns included. A locked register that takes a write, whole or in part, fails it.'''
          milestone: "V2"
          priority: "2"
          security: true
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
      ]
    }
    {
      name: '''Register block and bus'''
      conditions: [
        '''a "failed request" is a request whose command integrity code does not match, or a write whose data integrity code does not match ([Usage of User Bits](hw/ip/tlul/README.md#usage-of-user-bits): the data code covers "the write data"). A read whose only mismatch is in its data code is not a failed request, and no row checks its response or its alert. The "in-band reset" is the alert handler's re-initialization, during which it puts a signal integrity error on its ping and acknowledge pairs on purpose ([Employed Solution](hw/top_earlgrey/ip_autogen/alert_handler/doc/theory_of_operation.md#employed-solution)). The sender's answer to it, a signal integrity error on `alert_tx_o` and then a return to idle ([Employed Solution](hw/top_earlgrey/ip_autogen/alert_handler/doc/theory_of_operation.md#employed-solution)), has no row: the sender is the shared primitive `prim_alert_sender` (`rtl/pinmux.sv`:143-147), whose own upstream FPV drives the in-band reset and checks the return to idle (`hw/ip/prim/fpv/tb/prim_alert_rxtx_*`, `InBandInitFromReceiverToSender_A`). The alert rows read `alert_tx_o`, with an alert handler. An "illegal combination of address, size and mask" is a request whose address, size and mask do not correspond as TileLink requires (TileLink 1.9.3 p. 49-51: "a_size, a_address and a_mask are required to correspond with one another"): an address not aligned to its size (p. 51: "a_address must be aligned to a_size"), a size above 2, a mask bit set on a byte lane outside the access, or a `PutFullData` whose mask leaves a lane of the access 0. [Explicit Error Cases](hw/ip/tlul/README.md#explicit-error-cases) lists the last three "for example"; the unaligned address is verification's reading.'''
      ]
      requirements: [
        {
          name: REQ_REG_01a
          desc: '''Every register field shall take software's reads and writes as the access type of its register description entry says, for every request not answered with an error and, for a write, while the lock of its register reads 1 or it has no lock.'''
          source: [
            '''the register description: each field's `swaccess`, e.g. !!MIO_PAD_SLEEP_STATUS `swaccess: "rw0c"`'''
            '''[Configuration and Register Definition File Format](util/reggen/README.md#configuration-and-register-definition-file-format)'''
          ]
          kind: "spec"
          testpoint: "fpv_csr_rw"
          checks: ["CHK_PAD_ATTR_10 read-back changes only on a write (assert_PadAttr_ReadBackChangesOnlyOnAWrite)"]
          why: '''The generated register checker predicts each field from its access type and each request whose integrity codes are correct, and compares the field and every read with it; a field that takes a write its type or a closed lock refuses fails it. The attribute registers keep no value of their own (the pinmux supplies it), so their storage is decided by _read-back changes only on a write_ (CHK_PAD_ATTR_10): a read-back that changes with no accepted write to the pad's attribute register before it fails it. A write refused for its integrity code and the hardware set of a sleep status bit are left to the pinmux's own bus and sleep checks.'''
          milestone: "V2"
          priority: "2"
          security: true
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_REG_01b
          desc: '''Every register field shall read its register description reset value after reset.'''
          source: [
            '''the register description: each field's `resval`, e.g. !!MIO_PAD_SLEEP_STATUS.EN `resval: "0"`'''
            '''[Configuration and Register Definition File Format](util/reggen/README.md#configuration-and-register-definition-file-format)'''
          ]
          kind: "spec"
          testpoint: "fpv_csr_rw"
          checks: ["the generated CSR checker"]
          why: '''After reset the generated register checker expects each field at its reset value; a field that leaves reset with another value fails the first compare. The attribute registers, whose value the pinmux supplies, are left to _reset attributes_ (CHK_PAD_ATTR_09).'''
          milestone: "V2"
          priority: "2"
          security: true
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_BUS_01a
          desc: '''The pinmux shall answer every request with one response, and only one.'''
          source: [
            '''TileLink 1.9.3 p. 39: "Receipt of request messages must result in the eventual receipt of a response message by the requestor."; p. 30: "it is illegal to receive a response without receiving the request."; p. 46: "In TL-UL, every message fits within a single beat"'''
          ]
          kind: "spec"
          testpoint: "bus"
          checks: ["CHK_BUS_01 device rules (assert_Bus_DeviceRules)"]
          why: '''The TL-UL VIP's device rules match each response on the pinmux's port to an open request. A request left without a response, or a second response to one request, fails them.'''
          milestone: "V2"
          priority: "2"
          security: true
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_BUS_01b
          desc: '''The pinmux shall answer every request by the TL-UL rules with a response that carries the request's source ID.'''
          source: [
            '''[Source ID requirements for device elements](hw/ip/tlul/README.md#source-id-requirements-for-device-elements)'''
          ]
          kind: "spec"
          testpoint: "bus"
          checks: ["CHK_BUS_01 device rules (assert_Bus_DeviceRules)"]
          why: '''The TL-UL VIP's device rules hold every response to the TL-UL handshake and compare its `d_source` with its request's `a_source`. A response that carries another source ID fails them.'''
          milestone: "V2"
          priority: "2"
          security: true
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_BUS_01c
          desc: '''The pinmux shall answer with an error only a request that fails its integrity check, has an undefined opcode, has an illegal combination of address, size and mask, is a write of 8 or 16 bits not aligned to a word, is a write narrower than its register, or targets an address no register maps; a read whose only mismatch is in its data integrity code may get either answer.'''
          source: [
            '''[Explicit Error Cases](hw/ip/tlul/README.md#explicit-error-cases)'''
            '''[Error responses](util/reggen/README.md#error-responses)'''
          ]
          kind: "spec"
          testpoint: "bus"
          checks: ["CHK_BUS_02 errors as the register checker predicts"]
          why: '''It requires `d_error` 1 on a request that is not a failed request exactly when one of the listed causes holds, as the generated register checker's error checks predict; a read whose only fault is its data integrity code may get either answer, so the check leaves it out. A good request answered with an error fails it; a failed request is a listed cause, so its error never does.'''
          milestone: "V2"
          priority: "2"
          security: true
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_BUS_02a
          desc: '''Every response shall carry the response integrity code over its op code, size and error.'''
          source: [
            '''[Usage of User Bits](hw/ip/tlul/README.md#usage-of-user-bits)'''
            '''[pinmux.hjson `countermeasures` BUS.INTEGRITY](hw/top_${topname}/ip_autogen/pinmux/data/pinmux.hjson)'''
          ]
          kind: "spec"
          testpoint: "bus"
          checks: ["CHK_BUS_03 response codes correct (assert_Bus_ResponseCodesCorrect)"]
          why: '''It recomputes the response code from each response's opcode, size and error with the encoder both ends of the link share, and compares it with the code sent. A code over other fields, or a stale one, fails it.'''
          milestone: "V2"
          priority: "2"
          security: true
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_BUS_02b
          desc: '''Every response shall carry the data integrity code over its data.'''
          source: [
            '''[Usage of User Bits](hw/ip/tlul/README.md#usage-of-user-bits)'''
            '''[pinmux.hjson `countermeasures` BUS.INTEGRITY](hw/top_${topname}/ip_autogen/pinmux/data/pinmux.hjson)'''
          ]
          kind: "spec"
          testpoint: "bus"
          checks: ["CHK_BUS_03 response codes correct (assert_Bus_ResponseCodesCorrect)"]
          why: '''It recomputes the data code over each response's data with the encoder both ends of the link share, and compares it with the code sent. A code computed over other data fails it.'''
          milestone: "V2"
          priority: "2"
          security: true
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_BUS_03
          desc: '''A failed request shall get an error response.'''
          source: [
            '''[Usage of User Bits](hw/ip/tlul/README.md#usage-of-user-bits)'''
            '''[cip_base_vseq](hw/dv/sv/cip_lib/README.md#cip_base_vseq)'''
          ]
          kind: "RTL"
          testpoint: "bus"
          checks: ["CHK_BUS_04 failed request errors (assert_Bus_FailedRequestErrors)"]
          why: '''It requires `d_error` 1 on the response to every failed request: a bad command code, or a write with a bad data code. A design that answers a tampered request as a good one fails it.'''
          milestone: "V2"
          priority: "2"
          security: true
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_BUS_04
          desc: '''A failed write shall change no register.'''
          source: [
            '''[Usage of User Bits](hw/ip/tlul/README.md#usage-of-user-bits)'''
          ]
          kind: "RTL"
          testpoint: "bus"
          checks: ["CHK_BUS_05 failed write changes nothing (assert_Bus_FailedWriteChangesNothing)"]
          why: '''It holds every register over a failed write, the attribute registers by their read-back; a status bit takes only its hardware set. An AON field with an earlier write still crossing is left to _no change without a write_ (CHK_WAKEUP_SYNC_02), which lets it take only that write; a failed write that lands fails one of the two.'''
          milestone: "V2"
          priority: "2"
          security: true
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_BUS_05
          desc: '''Outside the alert handler's in-band reset, a failed request shall raise the fatal alert `fatal_fault`.'''
          source: [
            '''[pinmux.hjson `alert_list` fatal_fault](hw/top_${topname}/ip_autogen/pinmux/data/pinmux.hjson)'''
            '''[Employed Solution](hw/top_earlgrey/ip_autogen/alert_handler/doc/theory_of_operation.md#employed-solution)'''
          ]
          kind: "spec"
          testpoint: "alert"
          checks: ["CHK_ALERT_01 failed request alerts (assert_Alert_FailedRequestAlerts)"]
          why: '''It requires an alert event on `alert_tx_o` within 40 cycles of every failed request, the alert handler answering by the alert protocol. A design that ignores a tampered request, or alerts late, fails it.'''
          milestone: "V2S"
          priority: "2"
          security: true
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_BUS_06
          desc: '''Outside the alert handler's in-band reset, once raised, the fatal alert shall be sent again and again until reset.'''
          source: [
            '''[Alerts per Module](doc/contributing/hw/comportability/README.md#alerts-per-module)'''
            '''[Employed Solution](hw/top_earlgrey/ip_autogen/alert_handler/doc/theory_of_operation.md#employed-solution)'''
          ]
          kind: "spec"
          testpoint: "alert"
          checks: ["CHK_ALERT_02 fatal alert repeats (assert_Alert_FatalAlertRepeats)"]
          why: '''After a failed request it requires an alert event within 40 cycles of every cycle, until reset. A sender that stops after one event, or after the handler's answer, fails it.'''
          milestone: "V2S"
          priority: "2"
          security: true
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_BUS_07
          desc: '''Outside the alert handler's in-band reset, a write of 1 to `ALERT_TEST` bit 0 not answered with an error, while its bit 31 is 1, shall send one alert event.'''
          source: [
            '''`doc/registers.md`:668: "Write 1 to trigger one alert event of this kind."'''
            '''[Test Alert Register Creation](doc/contributing/hw/comportability/README.md#test-alert-register-creation)'''
            '''[Employed Solution](hw/top_earlgrey/ip_autogen/alert_handler/doc/theory_of_operation.md#employed-solution)'''
          ]
          kind: "spec"
          testpoint: "alert"
          checks: ["CHK_ALERT_03 test sends an event (assert_Alert_TestSendsAnEvent)", "CHK_ALERT_04 no alert without a cause (assert_Alert_NoAlertWithoutACause)"]
          why: '''The check _test sends an event_ (CHK_ALERT_03) requires each alert test's credit to be used up by an alert event within 40 cycles; _no alert without a cause_ (CHK_ALERT_04) lets each event use up one credit, so one test gives one event. A lost test fails _test sends an event_, and a second event for one test fails _no alert without a cause_.'''
          milestone: "V2S"
          priority: "2"
          security: true
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_BUS_08
          desc: '''Outside the alert handler's in-band reset, while `ALERT_TEST` bit 31 is 0, a write to its bit 0 that is not a failed request shall send no alert.'''
          source: [
            '''`doc/registers.md`:666: "Write 0 to disable alert testing until the next reset."'''
            '''[Employed Solution](hw/top_earlgrey/ip_autogen/alert_handler/doc/theory_of_operation.md#employed-solution)'''
          ]
          kind: "spec"
          testpoint: "alert"
          checks: ["CHK_ALERT_04 no alert without a cause (assert_Alert_NoAlertWithoutACause)"]
          why: '''A write of bit 0 while bit 31 of `ALERT_TEST` is 0 sets no test credit, so an alert event that follows it with no other cause finds no credit and fails the check. After a read whose only fault is its data integrity code, which may raise the alert or not, the check claims nothing until reset.'''
          milestone: "V2S"
          priority: "2"
          security: true
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_BUS_09
          desc: '''Outside the alert handler's in-band reset and apart from answering a ping, the fatal alert shall be sent only after a failed request or an alert test; a read whose only mismatch is in its data integrity code may raise it or not.'''
          source: [
            '''[pinmux.hjson `alert_list` fatal_fault](hw/top_${topname}/ip_autogen/pinmux/data/pinmux.hjson)'''
            '''[Employed Solution](hw/top_earlgrey/ip_autogen/alert_handler/doc/theory_of_operation.md#employed-solution)'''
          ]
          kind: "spec"
          testpoint: "alert"
          checks: ["CHK_ALERT_04 no alert without a cause (assert_Alert_NoAlertWithoutACause)"]
          why: '''It allows an alert event only after a failed request since reset, or against a ping or test credit, each event using up one credit and a ping's credit lapsing 40 cycles after its ping. An event with no failed request, test or ping behind it fails the check. After a read whose only fault is its data integrity code, which may raise the alert or not, the check claims nothing until reset.'''
          milestone: "V2S"
          priority: "2"
          security: true
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_BUS_10a
          desc: '''A request with an *undefined opcode* shall get an error response.'''
          source: [
            '''[Usage of Opcode, Size and Mask](hw/ip/tlul/README.md#usage-of-opcode-size-and-mask)'''
            '''[Error responses](util/reggen/README.md#error-responses)'''
          ]
          kind: "spec"
          testpoint: "bus"
          checks: ["CHK_BUS_02 errors as the register checker predicts"]
          why: '''The generated register checker's error checks require `d_error` 1 on a request with an undefined opcode, and an error only for a listed cause. A block that serves such a request, or refuses a good one, fails them; the run leaves opcodes free.'''
          milestone: "V2"
          priority: "2"
          security: true
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_BUS_10b
          desc: '''A request with an *illegal combination of address, size and mask*, as the Scope above defines it, shall get an error response.'''
          source: [
            '''[Explicit Error Cases](hw/ip/tlul/README.md#explicit-error-cases)'''
            '''TileLink 1.9.3 p. 51: "a_address must be aligned to a_size."'''
          ]
          kind: "spec"
          testpoint: "bus"
          checks: ["CHK_BUS_02 errors as the register checker predicts"]
          why: '''The generated register checker's error checks require `d_error` 1 on a request with a size above 2, a lane outside the access, a full write with a lane at 0, or an address not aligned to its size. Masks are contiguous in the run, so the checker's either-way rule for a non-contiguous mask never applies; a block that answers such a request without an error fails them.'''
          milestone: "V2"
          priority: "2"
          security: true
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_BUS_10c
          desc: '''A *write of 8 or 16 bits to an address not aligned to a word* shall get an error response.'''
          source: [
            '''[Error responses](util/reggen/README.md#error-responses)'''
            '''[Explicit Error Cases](hw/ip/tlul/README.md#explicit-error-cases)'''
          ]
          kind: "spec"
          testpoint: "bus"
          checks: ["CHK_BUS_02 errors as the register checker predicts"]
          why: '''The generated register checker's error checks require `d_error` 1 on an 8 or 16 bit write to an address not aligned to a word. A block that answers such a write without an error fails them.'''
          milestone: "V2"
          priority: "2"
          security: true
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_BUS_10d
          desc: '''A *write narrower than its register*, whose width the location of its fields sets, shall get an error response.'''
          source: [
            '''[Error responses](util/reggen/README.md#error-responses)'''
          ]
          kind: "spec"
          testpoint: "bus"
          checks: ["CHK_BUS_02 errors as the register checker predicts"]
          why: '''The generated register checker's error checks require `d_error` 1 on a write narrower than its register, the register's width set by its fields in the register description. A block that answers such a write without an error fails them.'''
          milestone: "V2"
          priority: "2"
          security: true
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_BUS_10e
          desc: '''A request to an *address no register maps*, within the address bits the register block decodes, shall get an error response.'''
          source: [
            '''[Explicit Error Cases](hw/ip/tlul/README.md#explicit-error-cases)'''
            '''[Error responses](util/reggen/README.md#error-responses)'''
          ]
          kind: "spec"
          testpoint: "bus"
          checks: ["CHK_BUS_02 errors as the register checker predicts"]
          why: '''The generated register checker's error checks require `d_error` 1 on a request to an address within the decoded bits that no register maps. A block that answers such a request without an error fails them.'''
          milestone: "V2"
          priority: "2"
          security: true
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_BUS_11
          desc: '''A write answered with an error for any reason other than a failed integrity check shall change no register.'''
          source: [
            '''[cip_base_vseq](hw/dv/sv/cip_lib/README.md#cip_base_vseq)'''
            '''[Error responses](util/reggen/README.md#error-responses)'''
          ]
          kind: "spec"
          testpoint: "bus"
          checks: ["CHK_BUS_06 error write changes nothing"]
          why: '''It holds every register over a write answered with an error: the generated register checker the stored fields, _read-back changes only on a write_ (CHK_PAD_ATTR_10) the attribute registers it leaves out (`hwext`), and _no change without a write_ (CHK_WAKEUP_SYNC_02) and _no clear without a write_ (CHK_WAKEUP_SYNC_04) the AON fields and cause bits. A block that lets such a write land fails one of them.'''
          milestone: "V2"
          priority: "2"
          security: true
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
      ]
    }
    {
      name: '''Wakeup detectors'''
      conditions: [
        '''`w` is a detector (0 to ${n_wkup_detect - 1}); a cycle is a `clk_aon_i` cycle (watched signal, forwarded value: terms).'''
        '''Register values are those the AON logic holds once a write has crossed.'''
        '''The rows hold with scan mode not True.'''
        '''They hold with the mode unchanged while enabled; the other fields may change while enabled.'''
        '''They hold whatever `sleep_en_i` does.'''
        '''They hold whatever `clk_i` does, stopped included: in sleep "only the wakeup detector logic will be actively clocked" ([Retention and Wakeup Features](hw/top_${topname}/ip_autogen/pinmux/doc/theory_of_operation.md#retention-and-wakeup-features)).'''
        '''They are checked from the filter's fourth sample after `rst_aon_ni`.'''
        '''The timed rows (`REQ_WKUP_09a` to `REQ_WKUP_10b`) hold for `CNT_TH` 1 and above: no spec says what a timed detector does with 0, the reset value.'''
      ]
      requirements: [
        {
          name: REQ_WKUP_01
          desc: '''With `MIODIO` 0, the watched signal shall be MIO pad `PADSEL` - 2 for `PADSEL` 2 to ${n_mio_pads + 1}, and the constant 0 or 1 for `PADSEL` 0 or 1.'''
          source: [
            '''!!MIO_PERIPH_INSEL.IN'''
            '''!!WKUP_DETECTOR.MIODIO'''
            '''!!WKUP_DETECTOR_PADSEL.SEL'''
            '''[Retention and Wakeup Features](hw/top_${topname}/ip_autogen/pinmux/doc/theory_of_operation.md#retention-and-wakeup-features)'''
            '''[Wakeup Detectors](hw/top_${topname}/ip_autogen/pinmux/doc/theory_of_operation.md#wakeup-detectors)'''
            '''[top_${topname}_pinmux.ipconfig.hjson `n_mio_pads`](hw/top_${topname}/ip_autogen/pinmux/data/top_${topname}_pinmux.ipconfig.hjson)'''
          ]
          kind: "spec"
          testpoint: "wakeup"
          checks: ["CHK_WAKEUP_03 edge sets cause (assert_Wakeup_EdgeSetsCause)", "CHK_WAKEUP_04 timed high sets cause (assert_Wakeup_TimedHighSetsCause)", "CHK_WAKEUP_05 timed low sets cause (assert_Wakeup_TimedLowSetsCause)", "CHK_WAKEUP_06 no false cause (assert_Wakeup_NoFalseCause)"]
          why: '''The checks read the pattern on the forwarded value of the MIO pad or constant the select names: a detector on another pad misses this pad's edge or fires on the other's, and a constant read at the wrong level misses a timed detection or makes a false one.'''
          milestone: "V2"
          priority: "1"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_WKUP_02
          desc: '''With `MIODIO` 1, the watched signal shall be DIO pad `PADSEL` for `PADSEL` 0 to ${n_dio_pads - 1}.'''
          source: [
            '''!!WKUP_DETECTOR.MIODIO'''
            '''!!WKUP_DETECTOR_PADSEL.SEL'''
            '''[MIO and DIO Signal Categories](hw/top_${topname}/ip_autogen/pinmux/doc/theory_of_operation.md#mio-and-dio-signal-categories)'''
            '''[top_${topname}_pinmux.ipconfig.hjson `n_dio_pads`](hw/top_${topname}/ip_autogen/pinmux/data/top_${topname}_pinmux.ipconfig.hjson)'''
          ]
          kind: "spec"
          testpoint: "wakeup"
          checks: ["CHK_WAKEUP_03 edge sets cause (assert_Wakeup_EdgeSetsCause)", "CHK_WAKEUP_06 no false cause (assert_Wakeup_NoFalseCause)"]
          why: '''The checks read the pattern on the forwarded value of the DIO pad the select names: a detector on another pad misses an edge of this one or fires on an edge of the other.'''
          milestone: "V2"
          priority: "1"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_WKUP_03
          desc: '''A `PADSEL` that names no pad (${free(n_mio_pads + 2, padsel_max)} with `MIODIO` 0, ${free(n_dio_pads, padsel_max)} with `MIODIO` 1) shall give the watched signal 0.'''
          source: [
            '''!!WKUP_DETECTOR_PADSEL.SEL'''
            '''[top_${topname}_pinmux.ipconfig.hjson `n_mio_pads`, `n_dio_pads`](hw/top_${topname}/ip_autogen/pinmux/data/top_${topname}_pinmux.ipconfig.hjson)'''
          ]
          kind: "spec"
          testpoint: "wakeup"
          checks: ["CHK_WAKEUP_05 timed low sets cause (assert_Wakeup_TimedLowSetsCause)", "CHK_WAKEUP_06 no false cause (assert_Wakeup_NoFalseCause)"]
          why: '''A select that names no pad watches 0: in mode 4 a detector that reads 1 never fires, and one that reads a pad fires on its edges or its level 1, which no pattern of 0 answers.'''
          milestone: "V2"
          priority: "1"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_WKUP_04
          desc: '''With `FILTER` 0, the forwarded value shall be the watched signal as sampled at each `clk_aon_i` edge.'''
          source: [
            '''[Wakeup Detectors](hw/top_${topname}/ip_autogen/pinmux/doc/theory_of_operation.md#wakeup-detectors)'''
          ]
          kind: "spec"
          testpoint: "wakeup"
          checks: ["CHK_WAKEUP_03 edge sets cause (assert_Wakeup_EdgeSetsCause)", "CHK_WAKEUP_06 no false cause (assert_Wakeup_NoFalseCause)"]
          why: '''With `FILTER` 0 the forwarded value is the pad as sampled: a detector that drops a sample misses an edge, and one that sees a level the pad never had fires with no pattern; a delay of up to 4 cycles is allowed.'''
          milestone: "V2"
          priority: "1"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_WKUP_05
          desc: '''With `FILTER` 1, the forwarded value shall take a new value only once 4 samples in a row have had it.'''
          source: [
            '''!!WKUP_DETECTOR.FILTER'''
          ]
          kind: "spec"
          testpoint: "wakeup"
          checks: ["CHK_WAKEUP_03 edge sets cause (assert_Wakeup_EdgeSetsCause)", "CHK_WAKEUP_06 no false cause (assert_Wakeup_NoFalseCause)"]
          why: '''A level held for 4 samples is an edge of the forwarded value and a 3-sample glitch is none: a filter that needs more samples misses the 4-sample level, and one that needs fewer fires on the glitch.'''
          milestone: "V2"
          priority: "1"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_WKUP_06a
          desc: '''An enabled detector in mode 0 (Posedge) shall detect every rise of the forwarded value.'''
          source: [
            '''!!WKUP_DETECTOR.MODE'''
            '''[Wakeup Detectors](hw/top_${topname}/ip_autogen/pinmux/doc/theory_of_operation.md#wakeup-detectors)'''
          ]
          kind: "spec"
          testpoint: "wakeup"
          checks: ["CHK_WAKEUP_01 posedge sets cause (assert_Wakeup_PosedgeSetsCause)"]
          why: '''It wants a hardware write of 1 to bit `w` of `WKUP_CAUSE` within 8 cycles of each rise of the forwarded value at which `EN` is 1 and stays 1 for 4 more cycles: a detector that misses a rise, a one-sample pulse included, fails it.'''
          milestone: "V2"
          priority: "1"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_WKUP_06b
          desc: '''An enabled detector in mode 0 (Posedge) shall detect only at a rise of the forwarded value.'''
          source: [
            '''!!WKUP_DETECTOR.MODE'''
            '''[Wakeup Detectors](hw/top_${topname}/ip_autogen/pinmux/doc/theory_of_operation.md#wakeup-detectors)'''
          ]
          kind: "spec"
          testpoint: "wakeup"
          checks: ["CHK_WAKEUP_06 no false cause (assert_Wakeup_NoFalseCause)"]
          why: '''In mode 0 it refuses a hardware write of 1 to a cause bit at 0 that no rise of the forwarded value, seen up to 4 cycles late with `EN` 1, answers: a detector that also fires on a fall fails it.'''
          milestone: "V2"
          priority: "1"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_WKUP_07a
          desc: '''An enabled detector in mode 1 (Negedge) shall detect every fall of the forwarded value.'''
          source: [
            '''!!WKUP_DETECTOR.MODE'''
          ]
          kind: "spec"
          testpoint: "wakeup"
          checks: ["CHK_WAKEUP_02 negedge sets cause (assert_Wakeup_NegedgeSetsCause)"]
          why: '''It wants a hardware write of 1 to bit `w` of `WKUP_CAUSE` within 8 cycles of each fall of the forwarded value at which `EN` is 1 and stays 1 for 4 more cycles: a detector that misses a fall fails it.'''
          milestone: "V2"
          priority: "1"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_WKUP_07b
          desc: '''An enabled detector in mode 1 (Negedge) shall detect only at a fall of the forwarded value.'''
          source: [
            '''!!WKUP_DETECTOR.MODE'''
          ]
          kind: "spec"
          testpoint: "wakeup"
          checks: ["CHK_WAKEUP_06 no false cause (assert_Wakeup_NoFalseCause)"]
          why: '''In mode 1 it refuses a hardware write of 1 to a cause bit at 0 that no fall of the forwarded value answers: a detector that fires on a rise fails it.'''
          milestone: "V2"
          priority: "1"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_WKUP_08a
          desc: '''An enabled detector in mode 2 (Edge) shall detect every change of the forwarded value.'''
          source: [
            '''!!WKUP_DETECTOR.MODE'''
          ]
          kind: "spec"
          testpoint: "wakeup"
          checks: ["CHK_WAKEUP_03 edge sets cause (assert_Wakeup_EdgeSetsCause)"]
          why: '''It wants a hardware write of 1 to bit `w` of `WKUP_CAUSE` within 8 cycles of each rise and each fall of the forwarded value at which `EN` is 1 and stays 1 for 4 more cycles: a detector that sees only one direction fails it.'''
          milestone: "V2"
          priority: "1"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_WKUP_08b
          desc: '''An enabled detector in mode 2 (Edge) shall detect only at a change of the forwarded value.'''
          source: [
            '''!!WKUP_DETECTOR.MODE'''
          ]
          kind: "spec"
          testpoint: "wakeup"
          checks: ["CHK_WAKEUP_06 no false cause (assert_Wakeup_NoFalseCause)"]
          why: '''In mode 2 it refuses a hardware write of 1 to a cause bit at 0 that no rise or fall of the forwarded value answers: a detector that fires on a steady pad fails it.'''
          milestone: "V2"
          priority: "1"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_WKUP_09a
          desc: '''An enabled detector in mode 3 (TimedHigh) shall detect when the forwarded value has been 1 for `CNT_TH` cycles in a row.'''
          source: [
            '''!!WKUP_DETECTOR.MODE'''
            '''!!WKUP_DETECTOR_CNT_TH.TH'''
            '''[Wakeup Detectors](hw/top_${topname}/ip_autogen/pinmux/doc/theory_of_operation.md#wakeup-detectors)'''
            '''[top_${topname}_pinmux.ipconfig.hjson `wkup_cnt_width`](hw/top_${topname}/ip_autogen/pinmux/data/top_${topname}_pinmux.ipconfig.hjson)'''
          ]
          kind: "spec"
          testpoint: "wakeup"
          checks: ["CHK_WAKEUP_04 timed high sets cause (assert_Wakeup_TimedHighSetsCause)"]
          why: '''It counts the cycles in a row with `EN` 1 and the forwarded value 1, and asks for a hardware write of 1 to the cause bit within 8 cycles once the count reaches `CNT_TH` + 1, the later of the two counts, `CNT_TH` or `CNT_TH` + 1, that the specification's wording allows: a detector that never fires, or fires later, fails it. It makes no claim on a level that began while `EN` was 0, as no specification says whether those cycles count.'''
          milestone: "V2"
          priority: "1"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_WKUP_09b
          desc: '''An enabled detector in mode 3 (TimedHigh) shall *never detect* while the forwarded value has been 1 for fewer than `CNT_TH` cycles in a row.'''
          source: [
            '''!!WKUP_DETECTOR.MODE'''
            '''[top_${topname}_pinmux.ipconfig.hjson `wkup_cnt_width`](hw/top_${topname}/ip_autogen/pinmux/data/top_${topname}_pinmux.ipconfig.hjson)'''
          ]
          kind: "spec"
          testpoint: "wakeup"
          checks: ["CHK_WAKEUP_06 no false cause (assert_Wakeup_NoFalseCause)"]
          why: '''In mode 3 it refuses a hardware write of 1 to the cause bit while the forwarded value has been 1 for fewer than `CNT_TH` cycles in a row with `EN` 1: a detector that fires early fails it. It makes no claim on a level that began while `EN` was 0, as no specification says whether those cycles count.'''
          milestone: "V2"
          priority: "1"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_WKUP_10a
          desc: '''An enabled detector in mode 4 (TimedLow) shall detect when the forwarded value has been 0 for `CNT_TH` cycles in a row.'''
          source: [
            '''!!WKUP_DETECTOR.MODE'''
            '''!!WKUP_DETECTOR_CNT_TH.TH'''
            '''[Wakeup Detectors](hw/top_${topname}/ip_autogen/pinmux/doc/theory_of_operation.md#wakeup-detectors)'''
            '''[top_${topname}_pinmux.ipconfig.hjson `wkup_cnt_width`](hw/top_${topname}/ip_autogen/pinmux/data/top_${topname}_pinmux.ipconfig.hjson)'''
          ]
          kind: "spec"
          testpoint: "wakeup"
          checks: ["CHK_WAKEUP_05 timed low sets cause (assert_Wakeup_TimedLowSetsCause)"]
          why: '''It counts the cycles in a row with `EN` 1 and the forwarded value 0, and asks for a hardware write of 1 to the cause bit within 8 cycles once the count reaches `CNT_TH` + 1, the later of the two counts, `CNT_TH` or `CNT_TH` + 1, that the specification's wording allows: a detector that never fires, or fires later, fails it. It makes no claim on a level that began while `EN` was 0, as no specification says whether those cycles count.'''
          milestone: "V2"
          priority: "1"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_WKUP_10b
          desc: '''An enabled detector in mode 4 (TimedLow) shall *never detect* while the forwarded value has been 0 for fewer than `CNT_TH` cycles in a row.'''
          source: [
            '''!!WKUP_DETECTOR.MODE'''
            '''[top_${topname}_pinmux.ipconfig.hjson `wkup_cnt_width`](hw/top_${topname}/ip_autogen/pinmux/data/top_${topname}_pinmux.ipconfig.hjson)'''
          ]
          kind: "spec"
          testpoint: "wakeup"
          checks: ["CHK_WAKEUP_06 no false cause (assert_Wakeup_NoFalseCause)"]
          why: '''In mode 4 it refuses a hardware write of 1 to the cause bit while the forwarded value has been 0 for fewer than `CNT_TH` cycles in a row with `EN` 1: a detector that fires early fails it. It makes no claim on a level that began while `EN` was 0, as no specification says whether those cycles count.'''
          milestone: "V2"
          priority: "1"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_WKUP_11
          desc: '''An enabled detector in mode 5, 6 or 7 shall detect exactly the rises of the forwarded value, as in mode 0 (Posedge).'''
          source: [
            '''!!WKUP_DETECTOR.MODE'''
          ]
          kind: "spec"
          testpoint: "wakeup"
          checks: ["CHK_WAKEUP_01 posedge sets cause (assert_Wakeup_PosedgeSetsCause)", "CHK_WAKEUP_06 no false cause (assert_Wakeup_NoFalseCause)"]
          why: '''Both checks read `MODE` 5, 6 and 7 as mode 0: a detector there that misses a rise fails _posedge sets cause_ (CHK_WAKEUP_01), and one that fires on a fall or a level fails _no false cause_ (CHK_WAKEUP_06).'''
          milestone: "V2"
          priority: "1"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_WKUP_12
          desc: '''A detector whose enable is 0 shall detect nothing.'''
          source: [
            '''!!WKUP_DETECTOR_EN.EN'''
          ]
          kind: "spec"
          testpoint: "wakeup"
          checks: ["CHK_WAKEUP_06 no false cause (assert_Wakeup_NoFalseCause)"]
          why: '''It refuses a hardware write of 1 to a cause bit at 0 that no pattern seen with `EN` 1 answers: a disabled detector that fires on its pattern fails it. An edge within 4 cycles of an enable change may set the bit or not.'''
          milestone: "V2"
          priority: "1"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_WKUP_13a
          desc: '''The sampling shall run while the detector is disabled, so that enabling the detector does not restart it.'''
          source: [
            '''None: the theory of operation and the register description are silent'''
          ]
          kind: "RTL"
          testpoint: "wakeup"
          checks: ["CHK_WAKEUP_06 no false cause (assert_Wakeup_NoFalseCause)", "CHK_WAKEUP_01 posedge sets cause (assert_Wakeup_PosedgeSetsCause)"]
          why: '''The checks sample the pad whatever `EN` is, so a pad steady at 1 before the enable is no rise: a detector whose sampling restarts at the enable sees one and sets the cause bit, which _no false cause_ (CHK_WAKEUP_06) refuses. The check _posedge sets cause_ (CHK_WAKEUP_01) wants a rise that completes just after the enable to be detected.'''
          milestone: "V2"
          priority: "1"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_WKUP_13b
          desc: '''The filter shall run while the detector is disabled, so that enabling the detector does not restart it.'''
          source: [
            '''None: the theory of operation and the register description are silent'''
          ]
          kind: "RTL"
          testpoint: "wakeup"
          checks: ["CHK_WAKEUP_06 no false cause (assert_Wakeup_NoFalseCause)", "CHK_WAKEUP_01 posedge sets cause (assert_Wakeup_PosedgeSetsCause)"]
          why: '''The checks' filter counts samples whatever `EN` is: a filter that restarts at the enable turns a pad steady at 1 into a new rise and sets the cause bit, which _no false cause_ (CHK_WAKEUP_06) refuses. The check _posedge sets cause_ (CHK_WAKEUP_01) wants a rise whose 4 samples span the enable to be detected.'''
          milestone: "V2"
          priority: "1"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_WKUP_14
          desc: '''When an enabled detector detects, bit `w` of `WKUP_CAUSE` shall become 1.'''
          source: [
            '''[Wakeup Detectors](hw/top_${topname}/ip_autogen/pinmux/doc/theory_of_operation.md#wakeup-detectors)'''
            '''!!WKUP_CAUSE.CAUSE'''
            '''[Wakeup Features](hw/top_${topname}/ip_autogen/pinmux/doc/programmers_guide.md#wakeup-features)'''
            '''[top_${topname}_pinmux.ipconfig.hjson `n_wkup_detect`](hw/top_${topname}/ip_autogen/pinmux/data/top_${topname}_pinmux.ipconfig.hjson)'''
          ]
          kind: "spec"
          testpoint: "wakeup"
          checks: ["CHK_WAKEUP_01 posedge sets cause (assert_Wakeup_PosedgeSetsCause)", "CHK_WAKEUP_02 negedge sets cause (assert_Wakeup_NegedgeSetsCause)", "CHK_WAKEUP_03 edge sets cause (assert_Wakeup_EdgeSetsCause)", "CHK_WAKEUP_04 timed high sets cause (assert_Wakeup_TimedHighSetsCause)", "CHK_WAKEUP_05 timed low sets cause (assert_Wakeup_TimedLowSetsCause)", "CHK_WAKEUP_07 set lands (assert_Wakeup_SetLands)"]
          why: '''The five mode checks (CHK_WAKEUP_01 to CHK_WAKEUP_05) want a hardware write of 1 to bit `w` within 8 cycles of each detection, and _set lands_ (CHK_WAKEUP_07) wants the bit 1 in the next cycle: a detection that never reaches bit `w`, or reaches another bit, fails them. A set in the cycle software's clear of the bit lands ends 0, as `REQ_WKUP_17` says.'''
          milestone: "V2"
          priority: "1"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_WKUP_15
          desc: '''Bit `w` of `WKUP_CAUSE` shall become 1 only when detector `w` detects.'''
          source: [
            '''!!WKUP_CAUSE.CAUSE'''
            '''[top_${topname}_pinmux.ipconfig.hjson `n_wkup_detect`](hw/top_${topname}/ip_autogen/pinmux/data/top_${topname}_pinmux.ipconfig.hjson)'''
          ]
          kind: "spec"
          testpoint: "wakeup"
          checks: ["CHK_WAKEUP_06 no false cause (assert_Wakeup_NoFalseCause)", "CHK_WAKEUP_08 cause rises only on a set (assert_Wakeup_CauseRisesOnlyOnASet)"]
          why: '''The check _no false cause_ (CHK_WAKEUP_06) refuses a hardware write of 1 to bit `w` at 0 that no pattern of detector `w` answers, and _cause rises only on a set_ (CHK_WAKEUP_08) refuses a rise of bit `w` with no such write in the cycle before: a set with no detection, a detection wired to another bit, or a bit raised by a software write of 1 fails one of them.'''
          milestone: "V2"
          priority: "1"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_WKUP_16
          desc: '''Once 1, a cause bit shall stay 1 until software's clear of it lands, whatever the detector, its enable and the pad do.'''
          source: [
            '''!!WKUP_CAUSE'''
            '''!!WKUP_CAUSE.CAUSE'''
            '''[Wakeup Features](hw/top_${topname}/ip_autogen/pinmux/doc/programmers_guide.md#wakeup-features)'''
            '''[Wakeup Recording](hw/top_${topname}/ip_autogen/pwrmgr/doc/theory_of_operation.md#wakeup-recording)'''
          ]
          kind: "spec"
          testpoint: "wakeup_cause"
          checks: ["CHK_WAKEUP_CAUSE_02 cause holds until cleared (assert_WakeupCause_CauseHoldsUntilCleared)", "CHK_WAKEUP_CAUSE_01 hardware only sets cause (assert_WakeupCause_HardwareOnlySetsCause)"]
          why: '''The check _cause holds until cleared_ (CHK_WAKEUP_CAUSE_02) allows a fall of the bit only in the cycle after software's clear of it lands or at `rst_aon_ni`, and _hardware only sets cause_ (CHK_WAKEUP_CAUSE_01) refuses a hardware write of 0 to the bit at 1 with no clear landing. A bit dropped when its detector is disabled, changes mode or sees its pad change fails _cause holds until cleared_, and _hardware only sets cause_ too when hardware writes the 0.'''
          milestone: "V2"
          priority: "2"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_WKUP_17
          desc: '''When a detection sets a cause bit in the cycle software's clear of it lands, the bit shall end 0: software's clear wins.'''
          source: [
            '''!!WKUP_CAUSE'''
            '''[Type RW](util/reggen/README.md#type-rw)'''
            '''[Simultaneous SW and HW access](util/reggen/README.md#simultaneous-sw-and-hw-access)'''
          ]
          kind: "spec"
          testpoint: "wakeup_cause"
          checks: ["CHK_WAKEUP_CAUSE_03 set and clear together (assert_WakeupCause_SetAndClearTogether)"]
          why: '''It takes every cycle in which a hardware write of 1 to a cause bit meets software's clear of the same bit landing, and wants the bit 0 in the next cycle: a register that lets the set win keeps the bit at 1 and fails it.'''
          milestone: "V2"
          priority: "2"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_WKUP_18a
          desc: '''`pin_wkup_req_o` shall be 1 while at least one cause bit is 1.'''
          source: [
            '''[Inter-Module Signals](hw/top_${topname}/ip_autogen/pinmux/doc/interfaces.md#inter-module-signals)'''
            '''[Wakeup Detectors](hw/top_${topname}/ip_autogen/pinmux/doc/theory_of_operation.md#wakeup-detectors)'''
            '''[Wakeup Recording](hw/top_${topname}/ip_autogen/pwrmgr/doc/theory_of_operation.md#wakeup-recording)'''
            '''[top_${topname}_pinmux.ipconfig.hjson `n_wkup_detect`](hw/top_${topname}/ip_autogen/pinmux/data/top_${topname}_pinmux.ipconfig.hjson)'''
          ]
          kind: "spec"
          testpoint: "wakeup_cause"
          checks: ["CHK_WAKEUP_CAUSE_04 request follows cause (assert_WakeupCause_RequestFollowsCause)"]
          why: '''It wants `pin_wkup_req_o` 1 within 2 cycles of any cause bit rising, and 1 while any cause bit has held 1 for 3 cycles in a row: a request that leaves out one of the eight bits, or drops while a bit is still 1, fails it.'''
          milestone: "V2"
          priority: "2"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_WKUP_18b
          desc: '''`pin_wkup_req_o` shall be 0 while every cause bit is 0.'''
          source: [
            '''[Inter-Module Signals](hw/top_${topname}/ip_autogen/pinmux/doc/interfaces.md#inter-module-signals)'''
            '''[Wakeup Detectors](hw/top_${topname}/ip_autogen/pinmux/doc/theory_of_operation.md#wakeup-detectors)'''
            '''[Wakeup Recording](hw/top_${topname}/ip_autogen/pwrmgr/doc/theory_of_operation.md#wakeup-recording)'''
            '''[top_${topname}_pinmux.ipconfig.hjson `n_wkup_detect`](hw/top_${topname}/ip_autogen/pinmux/data/top_${topname}_pinmux.ipconfig.hjson)'''
          ]
          kind: "spec"
          testpoint: "wakeup_cause"
          checks: ["CHK_WAKEUP_CAUSE_05 no request without cause (assert_WakeupCause_NoRequestWithoutCause)"]
          why: '''It wants `pin_wkup_req_o` 0 once every cause bit has been 0 for 3 cycles in a row: a request that stays 1 after the last bit is cleared, or rises on a pattern that set no bit, fails it.'''
          milestone: "V2"
          priority: "2"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_WKUP_19a
          desc: '''A write to a detector's enable shall reach the AON logic within a bounded time.'''
          source: [
            '''!!WKUP_DETECTOR_EN'''
            '''!!WKUP_DETECTOR'''
            '''!!WKUP_DETECTOR_CNT_TH'''
            '''!!WKUP_CAUSE'''
            '''[Wakeup Features](hw/top_${topname}/ip_autogen/pinmux/doc/programmers_guide.md#wakeup-features)'''
          ]
          kind: "spec"
          testpoint: "wakeup_sync"
          checks: ["CHK_WAKEUP_SYNC_01 write lands (assert_WakeupSync_WriteLands)", "CHK_WAKEUP_SYNC_02 no change without a write (assert_WakeupSync_NoChangeWithoutAWrite)"]
          why: '''For `EN`, _write lands_ (CHK_WAKEUP_SYNC_01) wants the AON copy to hold the written value within 4 cycles of each write accepted with its lock open, until the next one lands, and _no change without a write_ (CHK_WAKEUP_SYNC_02) allows a change only to a written value not yet landed. An enable write lost, late or landing another value fails _write lands_; a change no write explains fails _no change without a write_.'''
          milestone: "V2"
          priority: "2"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_WKUP_19b
          desc: '''A write to a detector's configuration shall reach the AON logic within a bounded time.'''
          source: [
            '''!!WKUP_DETECTOR_EN'''
            '''!!WKUP_DETECTOR'''
            '''!!WKUP_DETECTOR_CNT_TH'''
            '''!!WKUP_CAUSE'''
            '''[Wakeup Features](hw/top_${topname}/ip_autogen/pinmux/doc/programmers_guide.md#wakeup-features)'''
          ]
          kind: "spec"
          testpoint: "wakeup_sync"
          checks: ["CHK_WAKEUP_SYNC_01 write lands (assert_WakeupSync_WriteLands)", "CHK_WAKEUP_SYNC_02 no change without a write (assert_WakeupSync_NoChangeWithoutAWrite)"]
          why: '''For `MODE`, `FILTER` and `MIODIO`, each its own field, _write lands_ (CHK_WAKEUP_SYNC_01) wants the AON copy to hold the written value within 4 cycles of each write accepted with its lock open, until the next one lands, and _no change without a write_ (CHK_WAKEUP_SYNC_02) allows a change only to a written value not yet landed. A configuration write lost, late or landing another value fails _write lands_; a field that changes with no write behind it fails _no change without a write_.'''
          milestone: "V2"
          priority: "2"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_WKUP_19c
          desc: '''A write to a detector's threshold shall reach the AON logic within a bounded time.'''
          source: [
            '''!!WKUP_DETECTOR_EN'''
            '''!!WKUP_DETECTOR'''
            '''!!WKUP_DETECTOR_CNT_TH'''
            '''!!WKUP_CAUSE'''
            '''[Wakeup Features](hw/top_${topname}/ip_autogen/pinmux/doc/programmers_guide.md#wakeup-features)'''
          ]
          kind: "spec"
          testpoint: "wakeup_sync"
          checks: ["CHK_WAKEUP_SYNC_01 write lands (assert_WakeupSync_WriteLands)", "CHK_WAKEUP_SYNC_02 no change without a write (assert_WakeupSync_NoChangeWithoutAWrite)"]
          why: '''For `CNT_TH`, _write lands_ (CHK_WAKEUP_SYNC_01) wants the AON copy to hold the written value within 4 cycles of each write accepted with its lock open, until the next one lands, and _no change without a write_ (CHK_WAKEUP_SYNC_02) allows a change only to a written value not yet landed. A threshold write lost, late or landing another value fails _write lands_; a threshold that changes with no write behind it fails _no change without a write_.'''
          milestone: "V2"
          priority: "2"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_WKUP_19d
          desc: '''A clear of `WKUP_CAUSE` shall reach the AON logic within a bounded time.'''
          source: [
            '''!!WKUP_DETECTOR_EN'''
            '''!!WKUP_DETECTOR'''
            '''!!WKUP_DETECTOR_CNT_TH'''
            '''!!WKUP_CAUSE'''
            '''[Wakeup Features](hw/top_${topname}/ip_autogen/pinmux/doc/programmers_guide.md#wakeup-features)'''
          ]
          kind: "spec"
          testpoint: "wakeup_sync"
          checks: ["CHK_WAKEUP_SYNC_03 clear lands (assert_WakeupSync_ClearLands)", "CHK_WAKEUP_SYNC_05 landed clear clears cause (assert_WakeupSync_LandedClearClearsCause)", "CHK_WAKEUP_SYNC_04 no clear without a write (assert_WakeupSync_NoClearWithoutAWrite)"]
          why: '''The check _clear lands_ (CHK_WAKEUP_SYNC_03) wants each software clear of bit `w` of `WKUP_CAUSE` to land in the AON logic within 10 cycles, _landed clear clears cause_ (CHK_WAKEUP_SYNC_05) wants the bit 0 in the cycle after it lands, and _no clear without a write_ (CHK_WAKEUP_SYNC_04) refuses a clear landing with no software clear behind it. A clear lost, late or landing without effect fails _clear lands_ or _landed clear clears cause_; a write of 1 that clears fails _no clear without a write_.'''
          milestone: "V2"
          priority: "2"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_WKUP_20a
          desc: '''A write to a detector's *configuration* accepted before a write to its enable shall hold in the AON logic no later than that enable write.'''
          source: [
            '''!!WKUP_DETECTOR_EN'''
          ]
          kind: "spec"
          testpoint: "wakeup_sync"
          checks: ["CHK_WAKEUP_SYNC_06 writes land in order (assert_WakeupSync_WritesLandInOrder)"]
          why: '''It compares the AON cycles in which a configuration write and a later enable write land: an enable that holds before the configuration fails it.'''
          milestone: "V2"
          priority: "2"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_WKUP_20b
          desc: '''A write to a detector's *threshold* accepted before a write to its enable shall hold in the AON logic no later than that enable write.'''
          source: [
            '''!!WKUP_DETECTOR_EN'''
          ]
          kind: "spec"
          testpoint: "wakeup_sync"
          checks: ["CHK_WAKEUP_SYNC_06 writes land in order (assert_WakeupSync_WritesLandInOrder)"]
          why: '''It compares the AON cycles in which a threshold write and a later enable write land: an enable that holds before the threshold fails it.'''
          milestone: "V2"
          priority: "2"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
      ]
    }
% if usb:
    {
      name: '''USB wakeup'''
      conditions: [
        '''the module is usbdev's AON/Wake module, placed in the pinmux as usbdev is not in the AON power domain ([USB Wakeup Detection Module](hw/top_earlgrey/ip_autogen/pinmux/doc/theory_of_operation.md#usb-wakeup-detection-module)); what it does is usbdev's spec and testbench (`REQ_USB_06`), and the other rows check how it is connected. A pinmux port and a port of the module have the same role when usbdev's docs give the module's port the job of the port the top connects to the pinmux port:'''
      ]
      requirements: [
        {
          name: REQ_USB_01a
          desc: '''`usbdev_dppullup_en` shall reach the module's input of the same role unchanged, in the same cycle.'''
          source: [
            '''[Inter-Module Signals](hw/top_${topname}/ip_autogen/pinmux/doc/interfaces.md#inter-module-signals)'''
            '''[top_${topname}.hjson${eg(' `inter_module.connect usbdev.usb_dp_pullup`')}](hw/top_${topname}/data/top_${topname}.hjson)'''
            '''[top_${topname}_pinmux.ipconfig.hjson `enable_usb_wakeup`](hw/top_${topname}/ip_autogen/pinmux/data/top_${topname}_pinmux.ipconfig.hjson)'''
          ]
          kind: "spec"
          testpoint: "usb_conn"
          checks: ["CHK_USB_CONN_01 D+ pull-up enable in (assert_UsbConn_DpPullUpEnableIn)"]
          why: '''It compares the module's `usbdev_dppullup_en_i` port with `usbdev_dppullup_en` in every cycle: a port tied off, inverted, fed through a flop or from another signal differs in some cycle and fails it.'''
          milestone: "V2"
          priority: "2"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_USB_01b
          desc: '''`usbdev_dnpullup_en` shall reach the module's input of the same role unchanged, in the same cycle.'''
          source: [
            '''[Inter-Module Signals](hw/top_${topname}/ip_autogen/pinmux/doc/interfaces.md#inter-module-signals)'''
            '''[top_${topname}.hjson${eg(' `inter_module.connect usbdev.usb_dn_pullup`')}](hw/top_${topname}/data/top_${topname}.hjson)'''
            '''[top_${topname}_pinmux.ipconfig.hjson `enable_usb_wakeup`](hw/top_${topname}/ip_autogen/pinmux/data/top_${topname}_pinmux.ipconfig.hjson)'''
          ]
          kind: "spec"
          testpoint: "usb_conn"
          checks: ["CHK_USB_CONN_02 D- pull-up enable in (assert_UsbConn_DnPullUpEnableIn)"]
          why: '''It compares the module's `usbdev_dnpullup_en_i` port with `usbdev_dnpullup_en` in every cycle: a port tied off, inverted, fed through a flop or from another signal, the D+ pull-up enable included, differs in some cycle and fails it.'''
          milestone: "V2"
          priority: "2"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_USB_01c
          desc: '''`usbdev_suspend_req` shall reach the module's input of the same role unchanged, in the same cycle.'''
          source: [
            '''[Inter-Module Signals](hw/top_${topname}/ip_autogen/pinmux/doc/interfaces.md#inter-module-signals)'''
            '''[top_${topname}.hjson${eg(' `inter_module.connect usbdev.usb_aon_suspend_req`')}](hw/top_${topname}/data/top_${topname}.hjson)'''
            '''[top_${topname}_pinmux.ipconfig.hjson `enable_usb_wakeup`](hw/top_${topname}/ip_autogen/pinmux/data/top_${topname}_pinmux.ipconfig.hjson)'''
          ]
          kind: "spec"
          testpoint: "usb_conn"
          checks: ["CHK_USB_CONN_03 suspend request in (assert_UsbConn_SuspendRequestIn)"]
          why: '''It compares the module's suspend request port with `usbdev_suspend_req` in every cycle: a request routed to another port, or delayed, fails it, a one-cycle pulse included.'''
          milestone: "V2"
          priority: "2"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_USB_01d
          desc: '''`usbdev_wake_ack` shall reach the module's input of the same role unchanged, in the same cycle.'''
          source: [
            '''[Inter-Module Signals](hw/top_${topname}/ip_autogen/pinmux/doc/interfaces.md#inter-module-signals)'''
            '''[top_${topname}.hjson${eg(' `inter_module.connect usbdev.usb_aon_wake_ack`')}](hw/top_${topname}/data/top_${topname}.hjson)'''
            '''[top_${topname}_pinmux.ipconfig.hjson `enable_usb_wakeup`](hw/top_${topname}/ip_autogen/pinmux/data/top_${topname}_pinmux.ipconfig.hjson)'''
          ]
          kind: "spec"
          testpoint: "usb_conn"
          checks: ["CHK_USB_CONN_04 wake acknowledge in (assert_UsbConn_WakeAcknowledgeIn)"]
          why: '''It compares the module's wake acknowledge port with `usbdev_wake_ack` in every cycle: an acknowledge routed to another port, or delayed, fails it.'''
          milestone: "V2"
          priority: "2"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_USB_02a
          desc: '''The module's pull-up enable of the same role shall reach `usb_dppullup_en` unchanged, in the same cycle.'''
          source: [
            '''[Inter-Module Signals](hw/top_${topname}/ip_autogen/pinmux/doc/interfaces.md#inter-module-signals)'''
            '''[top_${topname}.hjson${eg(' `inter_module.external pinmux.usb_dppullup_en`')}](hw/top_${topname}/data/top_${topname}.hjson)'''
            '''[top_${topname}_pinmux.ipconfig.hjson `enable_usb_wakeup`](hw/top_${topname}/ip_autogen/pinmux/data/top_${topname}_pinmux.ipconfig.hjson)'''
          ]
          kind: "spec"
          testpoint: "usb_conn"
          checks: ["CHK_USB_CONN_05 D+ pull-up enable out (assert_UsbConn_DpPullUpEnableOut)"]
          why: '''It compares `usb_dppullup_en` with the module's `usb_dppullup_en_o` port in every cycle: an output driven from usbdev's own pull-up enable, from the D- port or through a flop differs in some cycle and fails it.'''
          milestone: "V2"
          priority: "2"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_USB_02b
          desc: '''The module's pull-up enable of the same role shall reach `usb_dnpullup_en` unchanged, in the same cycle.'''
          source: [
            '''[Inter-Module Signals](hw/top_${topname}/ip_autogen/pinmux/doc/interfaces.md#inter-module-signals)'''
            '''[top_${topname}.hjson${eg(' `inter_module.external pinmux.usb_dnpullup_en`')}](hw/top_${topname}/data/top_${topname}.hjson)'''
            '''[top_${topname}_pinmux.ipconfig.hjson `enable_usb_wakeup`](hw/top_${topname}/ip_autogen/pinmux/data/top_${topname}_pinmux.ipconfig.hjson)'''
          ]
          kind: "spec"
          testpoint: "usb_conn"
          checks: ["CHK_USB_CONN_06 D- pull-up enable out (assert_UsbConn_DnPullUpEnableOut)"]
          why: '''It compares `usb_dnpullup_en` with the module's `usb_dnpullup_en_o` port in every cycle: an output driven from usbdev's own pull-up enable, from the D+ port or through a flop differs in some cycle and fails it.'''
          milestone: "V2"
          priority: "2"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_USB_02c
          desc: '''The module's event of the same role, one of its three events, shall reach `usbdev_bus_not_idle` unchanged, in the same cycle.'''
          source: [
            '''[Inter-Module Signals](hw/top_${topname}/ip_autogen/pinmux/doc/interfaces.md#inter-module-signals)'''
            '''[top_${topname}.hjson${eg(' `inter_module.connect usbdev.usb_aon_bus_not_idle`')}](hw/top_${topname}/data/top_${topname}.hjson)'''
            '''[top_${topname}_pinmux.ipconfig.hjson `enable_usb_wakeup`](hw/top_${topname}/ip_autogen/pinmux/data/top_${topname}_pinmux.ipconfig.hjson)'''
          ]
          kind: "spec"
          testpoint: "usb_conn"
          checks: ["CHK_USB_CONN_07 bus not idle out (assert_UsbConn_BusNotIdleOut)"]
          why: '''It compares `usbdev_bus_not_idle` with the module's resume event port in every cycle: taking the bus reset or VBUS lost event instead fails it in a cycle where the two events differ.'''
          milestone: "V2"
          priority: "2"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_USB_02d
          desc: '''The module's event of the same role, one of its three events, shall reach `usbdev_bus_reset` unchanged, in the same cycle.'''
          source: [
            '''[Inter-Module Signals](hw/top_${topname}/ip_autogen/pinmux/doc/interfaces.md#inter-module-signals)'''
            '''[top_${topname}.hjson${eg(' `inter_module.connect usbdev.usb_aon_bus_reset`')}](hw/top_${topname}/data/top_${topname}.hjson)'''
            '''[top_${topname}_pinmux.ipconfig.hjson `enable_usb_wakeup`](hw/top_${topname}/ip_autogen/pinmux/data/top_${topname}_pinmux.ipconfig.hjson)'''
          ]
          kind: "spec"
          testpoint: "usb_conn"
          checks: ["CHK_USB_CONN_08 bus reset out (assert_UsbConn_BusResetOut)"]
          why: '''It compares `usbdev_bus_reset` with the module's bus reset event port in every cycle: taking the resume or VBUS lost event instead fails it in a cycle where the two events differ.'''
          milestone: "V2"
          priority: "2"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_USB_02e
          desc: '''The module's event of the same role, one of its three events, shall reach `usbdev_sense_lost` unchanged, in the same cycle.'''
          source: [
            '''[Inter-Module Signals](hw/top_${topname}/ip_autogen/pinmux/doc/interfaces.md#inter-module-signals)'''
            '''[top_${topname}.hjson${eg(' `inter_module.connect usbdev.usb_aon_sense_lost`')}](hw/top_${topname}/data/top_${topname}.hjson)'''
            '''[top_${topname}_pinmux.ipconfig.hjson `enable_usb_wakeup`](hw/top_${topname}/ip_autogen/pinmux/data/top_${topname}_pinmux.ipconfig.hjson)'''
          ]
          kind: "spec"
          testpoint: "usb_conn"
          checks: ["CHK_USB_CONN_09 sense lost out (assert_UsbConn_SenseLostOut)"]
          why: '''It compares `usbdev_sense_lost` with the module's VBUS lost event port in every cycle: taking the resume or bus reset event instead fails it in a cycle where the two events differ.'''
          milestone: "V2"
          priority: "2"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_USB_02f
          desc: '''The module's active state shall reach `usbdev_wake_detect_active` unchanged, in the same cycle.'''
          source: [
            '''[Inter-Module Signals](hw/top_${topname}/ip_autogen/pinmux/doc/interfaces.md#inter-module-signals)'''
            '''[top_${topname}.hjson${eg(' `inter_module.connect pinmux.usbdev_wake_detect_active`')}](hw/top_${topname}/data/top_${topname}.hjson)'''
            '''[top_${topname}_pinmux.ipconfig.hjson `enable_usb_wakeup`](hw/top_${topname}/ip_autogen/pinmux/data/top_${topname}_pinmux.ipconfig.hjson)'''
          ]
          kind: "spec"
          testpoint: "usb_conn"
          checks: ["CHK_USB_CONN_10 active out (assert_UsbConn_ActiveOut)"]
          why: '''It compares `usbdev_wake_detect_active` with the module's `wake_detect_active_aon_o` port in every cycle: a value from another port, or delayed, fails it.'''
          milestone: "V2"
          priority: "2"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_USB_03
          desc: '''`usb_wkup_req` shall be the module's wake request, unchanged, in the same cycle.'''
          source: [
            '''[Inter-Module Signals](hw/top_${topname}/ip_autogen/pinmux/doc/interfaces.md#inter-module-signals)'''
            '''[top_${topname}_pinmux.ipconfig.hjson `enable_usb_wakeup`](hw/top_${topname}/ip_autogen/pinmux/data/top_${topname}_pinmux.ipconfig.hjson)'''
          ]
          kind: "spec"
          testpoint: "usb_conn"
          checks: ["CHK_USB_CONN_11 wake request out (assert_UsbConn_WakeRequestOut)"]
          why: '''It compares `usb_wkup_req` with the module's `wake_req_aon_o` port in every cycle: a request from another signal, or through a flop, fails it, a one-cycle pulse included.'''
          milestone: "V2"
          priority: "2"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_USB_04a
          desc: '''The module shall run on `clk_aon_i`.'''
          source: [
            '''[Inter-Module Signals](hw/top_${topname}/ip_autogen/pinmux/doc/interfaces.md#inter-module-signals)'''
            '''[USB Wakeup Detection Module](hw/top_earlgrey/ip_autogen/pinmux/doc/theory_of_operation.md#usb-wakeup-detection-module)'''
            '''[AON/Wake Clocking](hw/ip/usbdev/doc/theory_of_operation.md#aonwake-clocking)'''
            '''[top_${topname}_pinmux.ipconfig.hjson `enable_usb_wakeup`](hw/top_${topname}/ip_autogen/pinmux/data/top_${topname}_pinmux.ipconfig.hjson)'''
          ]
          kind: "spec"
          testpoint: "usb_conn"
          checks: ["CHK_USB_CONN_12 module on AON clock (assert_UsbConn_ModuleOnAONClock)"]
          why: '''It compares the module's clock with `clk_aon_i` in every cycle; the run clocks `clk_aon_i` slower than `clk_i`, so a module on `clk_i` fails it.'''
          milestone: "V2"
          priority: "2"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_USB_04b
          desc: '''The module shall be reset by `rst_aon_ni`.'''
          source: [
            '''[pinmux.hjson `clocking`](hw/top_${topname}/ip_autogen/pinmux/data/pinmux.hjson)'''
            '''[top_${topname}_pinmux.ipconfig.hjson `enable_usb_wakeup`](hw/top_${topname}/ip_autogen/pinmux/data/top_${topname}_pinmux.ipconfig.hjson)'''
            '''[AON/Wake Clocking](hw/ip/usbdev/doc/theory_of_operation.md#aonwake-clocking)'''
          ]
          kind: "spec"
          testpoint: "usb_conn"
          checks: []
          why: '''Not covered by formal: reset behaviour is out of scope. Every run holds both resets released, so a module reset by `rst_ni` would pass the wiring checks.'''
          milestone: "V2"
          priority: "2"
          security: false
          state: "${eg('open: no check in this plan', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_USB_05a
          desc: '''The module's D+ input shall be usbdev's input as the pinmux delivers it: ${eg('the DIO pad USB_P', 'the DIO pad of USB D+')}.'''
          source: [
            '''[AON/Wake Interface Pins](hw/ip/usbdev/doc/theory_of_operation.md#aonwake-interface-pins)'''
            '''[top_${topname}.hjson${eg(' `pinout.pads USB_P`')}](hw/top_${topname}/data/top_${topname}.hjson)'''
            '''[top_${topname}.hjson${eg(' `pinmux`')}](hw/top_${topname}/data/top_${topname}.hjson)'''
            '''[top_${topname}.hjson${eg(' `pinmux.signals`')}](hw/top_${topname}/data/top_${topname}.hjson)'''
            '''[top_${topname}_pinmux.ipconfig.hjson `enable_usb_wakeup`](hw/top_${topname}/ip_autogen/pinmux/data/top_${topname}_pinmux.ipconfig.hjson)'''
          ]
          kind: "spec"
          testpoint: "usb_conn"
          checks: ["CHK_USB_CONN_14 bus inputs (assert_UsbConn_BusInputs)"]
          why: '''${eg("It compares the module's D+ input with the DIO pad USB_P in every cycle: an input taken from USB_N or another pad, or through a flop, fails it.", 'Not written for this top.')}'''
          milestone: "V2"
          priority: "2"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_USB_05b
          desc: '''The module's D- input shall be usbdev's input as the pinmux delivers it: ${eg('the DIO pad USB_N', 'the DIO pad of USB D-')}.'''
          source: [
            '''[AON/Wake Interface Pins](hw/ip/usbdev/doc/theory_of_operation.md#aonwake-interface-pins)'''
            '''[top_${topname}.hjson${eg(' `pinout.pads USB_N`')}](hw/top_${topname}/data/top_${topname}.hjson)'''
            '''[top_${topname}.hjson${eg(' `pinmux`')}](hw/top_${topname}/data/top_${topname}.hjson)'''
            '''[top_${topname}.hjson${eg(' `pinmux.signals`')}](hw/top_${topname}/data/top_${topname}.hjson)'''
            '''[top_${topname}_pinmux.ipconfig.hjson `enable_usb_wakeup`](hw/top_${topname}/ip_autogen/pinmux/data/top_${topname}_pinmux.ipconfig.hjson)'''
          ]
          kind: "spec"
          testpoint: "usb_conn"
          checks: ["CHK_USB_CONN_14 bus inputs (assert_UsbConn_BusInputs)"]
          why: '''${eg("It compares the module's D- input with the DIO pad USB_N in every cycle: an input taken from USB_P or another pad, or through a flop, fails it.", 'Not written for this top.')}'''
          milestone: "V2"
          priority: "2"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_USB_05c
          desc: '''The module's VBUS input shall be usbdev's input as the pinmux delivers it: the muxed input `sense` after its input select.'''
          source: [
            '''[AON/Wake Interface Pins](hw/ip/usbdev/doc/theory_of_operation.md#aonwake-interface-pins)'''
            '''[top_${topname}.hjson${eg(' `pinmux`')}](hw/top_${topname}/data/top_${topname}.hjson)'''
            '''[top_${topname}.hjson${eg(' `pinmux.signals`')}](hw/top_${topname}/data/top_${topname}.hjson)'''
            '''[top_${topname}_pinmux.ipconfig.hjson `enable_usb_wakeup`](hw/top_${topname}/ip_autogen/pinmux/data/top_${topname}_pinmux.ipconfig.hjson)'''
          ]
          kind: "spec"
          testpoint: "usb_conn"
          checks: ["CHK_USB_CONN_14 bus inputs (assert_UsbConn_BusInputs)"]
          why: '''It compares the module's VBUS input with usbdev's sense input after its input select in every cycle: a VBUS taken from a fixed pad, before the select, differs once the select names another pad and fails it.'''
          milestone: "V2"
          priority: "2"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_USB_06
          desc: '''The module shall activate on the suspend request, hold the pull-ups, report resume, bus reset and VBUS loss, and release on the wake acknowledge, as usbdev's spec says.'''
          source: [
            '''[Optional external AON/Wake functionality](hw/ip/usbdev/doc/theory_of_operation.md#optional-external-aonwake-functionality)'''
            '''[top_${topname}_pinmux.ipconfig.hjson `enable_usb_wakeup`](hw/top_${topname}/ip_autogen/pinmux/data/top_${topname}_pinmux.ipconfig.hjson)'''
          ]
          kind: "spec"
          testpoint: "usb_module"
          checks: ["usbdev's tests"]
          why: '''Out of scope here: usbdev's own testbench decides the module's behaviour, by its tests `usbdev_aon_wake_resume`, `_reset` and `_disconnect`. This plan checks only that the module is wired to the pinmux's ports and pads.'''
          milestone: "V2"
          priority: "2"
          security: false
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
      ]
    }
% endif
% if strap:
    {
      name: '''Strap sampling'''
      conditions: [
        '''the TAP straps are seen through the TAP that connects; full reset and NDM reset: terms. Life cycle conditions follow the life cycle definition table ([Manufacturing States](doc/security/specs/device_life_cycle/README.md#manufacturing-states)), after the delay before a life cycle input counts.${eg(" The pads named are Earlgrey's.", '')}'''
      ]
      requirements: [
        {
          name: REQ_STRAP_01
          desc: '''At each `strap_en_i` pulse while `dft_hold_tap_sel_i` is 0, TAP strap 0 shall take ${eg("pad IOC8's value (MIO 30)", "its pad's value")}, in every life cycle state.'''
          source: [
            '''[Strap Sampling and TAP Isolation](hw/top_${topname}/ip_autogen/pinmux/doc/theory_of_operation.md#strap-sampling-and-tap-isolation)'''
            '''[top_${topname}.hjson${eg(' `targets.asic.pinmux.special_signals tap0`')}](hw/top_${topname}/data/top_${topname}.hjson)'''
            '''[top_${topname}_pinmux.ipconfig.hjson `enable_strap_sampling`](hw/top_${topname}/ip_autogen/pinmux/data/top_${topname}_pinmux.ipconfig.hjson)'''
          ]
          kind: "spec"
          testpoint: "strap"
          checks: ["CHK_STRAP_01 pulse samples the straps (assert_Strap_PulseSamplesTheStraps)"]
          why: '''${eg('At every strap pulse with `dft_hold_tap_sel_i` at 0, whatever the life cycle inputs, the check compares strap 0 in the next cycle with MIO 30 (IOC8) of the pulse cycle or of the cycle after it: the one value where the pad holds it in both cycles, either value where the two differ. A strap 0 that misses the pulse, or takes another pad or a value from neither cycle, fails it.', 'Not written for this top.')}'''
          milestone: "V2S"
          priority: "1"
          security: true
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_STRAP_02a
          desc: '''At each `strap_en_i` pulse while `dft_hold_tap_sel_i` is 0, TAP strap 1 shall take ${eg("pad IOC5's value (MIO 27)", "its pad's value")} if the live `lc_hw_debug_en_i` is On. Where both straps sample their pads while `lc_dft_en_i` is On and `dft_hold_tap_sel_i` is 0 (`REQ_STRAP_03`), that sampling takes precedence.'''
          source: [
            '''[Strap Sampling and TAP Isolation](hw/top_${topname}/ip_autogen/pinmux/doc/theory_of_operation.md#strap-sampling-and-tap-isolation)'''
            '''[top_${topname}.hjson${eg(' `targets.asic.pinmux.special_signals tap1`')}](hw/top_${topname}/data/top_${topname}.hjson)'''
            '''[top_${topname}_pinmux.ipconfig.hjson `enable_strap_sampling`](hw/top_${topname}/ip_autogen/pinmux/data/top_${topname}_pinmux.ipconfig.hjson)'''
            '''[Manufacturing States](doc/security/specs/device_life_cycle/README.md#manufacturing-states)'''
          ]
          kind: "spec"
          testpoint: "strap"
          checks: ["CHK_STRAP_01 pulse samples the straps (assert_Strap_PulseSamplesTheStraps)"]
          why: '''${eg('With `dft_hold_tap_sel_i` at 0 and `lc_hw_debug_en_i` On for the two cycles before the pulse, the check compares strap 1 in the next cycle with MIO 27 (IOC5) of the pulse cycle or of the cycle after it, the one value where the pad holds it in both; a strap 1 that keeps its old value fails it. While `lc_dft_en_i` is On the strap follows its pad instead, which _straps follow the pads_ (CHK_STRAP_02) decides.', 'Not written for this top.')}'''
          milestone: "V2S"
          priority: "1"
          security: true
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_STRAP_02b
          desc: '''At each `strap_en_i` pulse, TAP strap 1 shall keep its value if the live `lc_hw_debug_en_i` is not On. Where both straps sample their pads while `lc_dft_en_i` is On and `dft_hold_tap_sel_i` is 0 (`REQ_STRAP_03`), that sampling takes precedence.'''
          source: [
            '''[Strap Sampling and TAP Isolation](hw/top_${topname}/ip_autogen/pinmux/doc/theory_of_operation.md#strap-sampling-and-tap-isolation)'''
            '''[top_${topname}.hjson${eg(' `targets.asic.pinmux.special_signals tap1`')}](hw/top_${topname}/data/top_${topname}.hjson)'''
            '''[top_${topname}_pinmux.ipconfig.hjson `enable_strap_sampling`](hw/top_${topname}/ip_autogen/pinmux/data/top_${topname}_pinmux.ipconfig.hjson)'''
            '''[Manufacturing States](doc/security/specs/device_life_cycle/README.md#manufacturing-states)'''
          ]
          kind: "spec"
          testpoint: "strap"
          checks: ["CHK_STRAP_01 pulse samples the straps (assert_Strap_PulseSamplesTheStraps)"]
          why: '''${eg('With `dft_hold_tap_sel_i` at 0 and neither `lc_hw_debug_en_i` nor `lc_dft_en_i` On in the two cycles before the pulse, the check asserts strap 1 unchanged in the next cycle, whatever IOC5 carries. A PROD chip whose strap 1 takes its pad fails it.', 'Not written for this top.')}'''
          milestone: "V2S"
          priority: "1"
          security: true
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_STRAP_03
          desc: '''While `lc_dft_en_i` is On and `dft_hold_tap_sel_i` is 0, both TAP straps shall take their pads' values of the cycle before.'''
          source: [
            '''[Strap Sampling and TAP Isolation](hw/top_${topname}/ip_autogen/pinmux/doc/theory_of_operation.md#strap-sampling-and-tap-isolation)'''
            '''[top_${topname}.hjson${eg(' `targets.asic.pinmux.special_signals`')}](hw/top_${topname}/data/top_${topname}.hjson)'''
            '''[top_${topname}_pinmux.ipconfig.hjson `enable_strap_sampling`](hw/top_${topname}/ip_autogen/pinmux/data/top_${topname}_pinmux.ipconfig.hjson)'''
            '''[Manufacturing States](doc/security/specs/device_life_cycle/README.md#manufacturing-states)'''
          ]
          kind: "spec"
          testpoint: "strap"
          checks: ["CHK_STRAP_02 straps follow the pads (assert_Strap_StrapsFollowThePads)"]
          why: '''${eg('While `lc_dft_en_i` has been On for the two cycles before and `dft_hold_tap_sel_i` is 0, the check compares both straps with MIO 30 and MIO 27 of the cycle before, a strap pulse cycle included, whatever `lc_hw_debug_en_i` is. A strap that holds, or a strap 1 that stops following its pad, fails it.', 'Not written for this top.')}'''
          milestone: "V2S"
          priority: "1"
          security: true
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_STRAP_04
          desc: '''While `dft_hold_tap_sel_i` is 1, the TAP straps shall keep their values, at a `strap_en_i` pulse too.'''
          source: [
            '''[Strap Sampling and TAP Isolation](hw/top_${topname}/ip_autogen/pinmux/doc/theory_of_operation.md#strap-sampling-and-tap-isolation)'''
            '''[top_${topname}_pinmux.ipconfig.hjson `enable_strap_sampling`](hw/top_${topname}/ip_autogen/pinmux/data/top_${topname}_pinmux.ipconfig.hjson)'''
          ]
          kind: "spec"
          testpoint: "strap"
          checks: ["CHK_STRAP_03 straps hold (assert_Strap_StrapsHold)"]
          why: '''While `dft_hold_tap_sel_i` is 1, the check asserts both straps unchanged in the next cycle, at a strap pulse and with `lc_dft_en_i` On too. A design that samples during the hold fails it.'''
          milestone: "V2S"
          priority: "1"
          security: true
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_STRAP_05
          desc: '''Outside a `strap_en_i` pulse, and outside the sampling while `lc_dft_en_i` is On and `dft_hold_tap_sel_i` is 0 (`REQ_STRAP_03`), the TAP straps shall keep their values.'''
          source: [
            '''[Strap Sampling and TAP Isolation](hw/top_${topname}/ip_autogen/pinmux/doc/theory_of_operation.md#strap-sampling-and-tap-isolation)'''
            '''[top_${topname}_pinmux.ipconfig.hjson `enable_strap_sampling`](hw/top_${topname}/ip_autogen/pinmux/data/top_${topname}_pinmux.ipconfig.hjson)'''
          ]
          kind: "spec"
          testpoint: "strap"
          checks: ["CHK_STRAP_03 straps hold (assert_Strap_StrapsHold)"]
          why: '''${eg('With no strap pulse and `lc_dft_en_i` not On in the two cycles before, the check asserts both straps unchanged whatever the pads do. A strap that follows IOC5 or IOC8 after boot, when software uses them as GPIOs, fails it.', 'Not written for this top.')}'''
          milestone: "V2S"
          priority: "1"
          security: true
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_STRAP_06
          desc: '''A TAP strap never sampled since the last full reset shall read 0.'''
          source: [
            '''[Strap Sampling and TAP Isolation](hw/top_${topname}/ip_autogen/pinmux/doc/theory_of_operation.md#strap-sampling-and-tap-isolation)'''
            '''[top_${topname}_pinmux.ipconfig.hjson `enable_strap_sampling`](hw/top_${topname}/ip_autogen/pinmux/data/top_${topname}_pinmux.ipconfig.hjson)'''
          ]
          kind: "RTL"
          testpoint: "strap"
          checks: ["CHK_STRAP_04 unsampled strap reads 0 (assert_Strap_UnsampledStrapReads0)", "CHK_STRAP_01 pulse samples the straps (assert_Strap_PulseSamplesTheStraps)", "CHK_STRAP_03 straps hold (assert_Strap_StrapsHold)"]
          why: '''The check _unsampled strap reads 0_ (CHK_STRAP_04) asserts both straps 0 in full reset and in every cycle after it until a sample, whatever the pads carry; a strap that leaves reset at 1, or takes a pad with no sample, fails it. A strap 1 that a PROD boot leaves unsampled keeps that 0 through the kept half of _pulse samples the straps_ (CHK_STRAP_01) and through _straps hold_ (CHK_STRAP_03).'''
          milestone: "V2S"
          priority: "1"
          security: true
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_STRAP_07
          desc: '''An NDM reset shall leave both TAP straps unchanged.'''
          source: [
            '''[Non-debug Module Reset](hw/top_earlgrey/ip_autogen/pinmux/doc/theory_of_operation.md#non-debug-module-reset)'''
            '''[Reset Request Handling](hw/top_${topname}/ip_autogen/pwrmgr/doc/theory_of_operation.md#reset-request-handling)'''
            '''[top_${topname}.hjson${eg(' `resets.nodes lc_io_div4`')}](hw/top_${topname}/data/top_${topname}.hjson)'''
            '''[top_${topname}.hjson${eg(' `resets.nodes sys_io_div4`')}](hw/top_${topname}/data/top_${topname}.hjson)'''
            '''[top_${topname}.hjson${eg(' `module.pinmux`')}](hw/top_${topname}/data/top_${topname}.hjson)'''
            '''[top_${topname}_pinmux.ipconfig.hjson `enable_strap_sampling`](hw/top_${topname}/ip_autogen/pinmux/data/top_${topname}_pinmux.ipconfig.hjson)'''
          ]
          kind: "spec"
          testpoint: "strap"
          checks: []
          why: '''Not covered by formal: reset behaviour is out of scope.'''
          milestone: "V2S"
          priority: "1"
          security: true
          state: "${eg('open: no check in this plan', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_STRAP_08
          desc: '''With `SecVolatileRawUnlockEn` 0${eg(', the Earlgrey value,', ',')} `strap_en_override_i` shall not change the straps.'''
          source: [
            '''[Inter-Module Signals](hw/top_${topname}/ip_autogen/pinmux/doc/interfaces.md#inter-module-signals)'''
            '''[pinmux.hjson `param_list` SecVolatileRawUnlockEn](hw/top_${topname}/ip_autogen/pinmux/data/pinmux.hjson)'''
            '''[Volatile `RAW` -> `TEST_UNLOCKED0` Transition](hw/ip/lc_ctrl/doc/programmers_guide.md#volatile-raw---test_unlocked0-transition)'''
            '''[top_${topname}_pinmux.ipconfig.hjson `enable_strap_sampling`](hw/top_${topname}/ip_autogen/pinmux/data/top_${topname}_pinmux.ipconfig.hjson)'''
          ]
          kind: "spec"
          testpoint: "strap"
          checks: ["CHK_STRAP_03 straps hold (assert_Strap_StrapsHold)"]
          why: '''The input `strap_en_override_i` takes any value in any cycle of the proof, and the check asserts the straps unchanged whenever no sample is due, through every override value. A strap that samples when the override rises fails it.'''
          milestone: "V2S"
          priority: "1"
          security: true
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
      ]
    }
% endif
% if strap:
    {
      name: '''Latched debug enable'''
      conditions: [
        '''the latch, On and Off are as terms defines them.'''
      ]
      requirements: [
        {
          name: REQ_DBG_01a
          desc: '''At each `strap_en_i` pulse, the latch shall take On if `lc_hw_debug_en_i` is On.'''
          source: [
            '''[Non-debug Module Reset](hw/top_earlgrey/ip_autogen/pinmux/doc/theory_of_operation.md#non-debug-module-reset)'''
            '''[Inter-Module Signals](hw/top_${topname}/ip_autogen/pinmux/doc/interfaces.md#inter-module-signals)'''
            '''[top_${topname}_pinmux.ipconfig.hjson `enable_strap_sampling`](hw/top_${topname}/ip_autogen/pinmux/data/top_${topname}_pinmux.ipconfig.hjson)'''
          ]
          kind: "spec"
          testpoint: "latch"
          checks: ["CHK_LATCH_02 pulse samples debug enable (assert_Latch_PulseSamplesDebugEnable)"]
          why: '''At a strap pulse with `lc_hw_debug_en_i` On for the two cycles before, `lc_hw_debug_clr_i`, `lc_check_byp_en_i` and `lc_escalate_en_i` at Off for the two cycles before, the check compares `pinmux_hw_debug_en_o` with On in the next cycle. A latch that misses the pulse stays Off and fails it.'''
          milestone: "V2S"
          priority: "1"
          security: true
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_DBG_01b
          desc: '''At each `strap_en_i` pulse, the latch shall take Off if `lc_hw_debug_en_i` is not On.'''
          source: [
            '''[Non-debug Module Reset](hw/top_earlgrey/ip_autogen/pinmux/doc/theory_of_operation.md#non-debug-module-reset)'''
            '''[Inter-Module Signals](hw/top_${topname}/ip_autogen/pinmux/doc/interfaces.md#inter-module-signals)'''
            '''[top_${topname}_pinmux.ipconfig.hjson `enable_strap_sampling`](hw/top_${topname}/ip_autogen/pinmux/data/top_${topname}_pinmux.ipconfig.hjson)'''
          ]
          kind: "spec"
          testpoint: "latch"
          checks: ["CHK_LATCH_02 pulse samples debug enable (assert_Latch_PulseSamplesDebugEnable)", "CHK_LATCH_03 On only at a pulse (assert_Latch_OnOnlyAtAPulse)"]
          why: '''The check _pulse samples debug enable_ (CHK_LATCH_02) compares the output with Off after a strap pulse with `lc_hw_debug_en_i` On in neither of the two cycles before and the three clear inputs at Off. The check _On only at a pulse_ (CHK_LATCH_03) fails any rise to On other than after a strap pulse with the debug enable On in one of the two cycles before, so a latch that follows the debug enable when it turns On later fails too.'''
          milestone: "V2S"
          priority: "1"
          security: true
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_DBG_02
          desc: '''With no `strap_en_i` pulse, no clear and no full reset, the latch shall keep its value, through an NDM reset too.'''
          source: [
            '''[Non-debug Module Reset](hw/top_earlgrey/ip_autogen/pinmux/doc/theory_of_operation.md#non-debug-module-reset)'''
            '''[top_${topname}.hjson${eg(' `resets.nodes lc_io_div4`')}](hw/top_${topname}/data/top_${topname}.hjson)'''
            '''[top_${topname}.hjson${eg(' `resets.nodes sys_io_div4`')}](hw/top_${topname}/data/top_${topname}.hjson)'''
            '''[top_${topname}.hjson${eg(' `module.pinmux`')}](hw/top_${topname}/data/top_${topname}.hjson)'''
            '''[top_${topname}_pinmux.ipconfig.hjson `enable_strap_sampling`](hw/top_${topname}/ip_autogen/pinmux/data/top_${topname}_pinmux.ipconfig.hjson)'''
          ]
          kind: "spec"
          testpoint: "latch"
          checks: ["CHK_LATCH_05 latch holds (assert_Latch_LatchHolds)"]
          why: '''With no strap pulse, `lc_hw_debug_clr_i`, `lc_check_byp_en_i` and `lc_escalate_en_i` at Off in the two cycles before, the check asserts the output unchanged; a latch that drops, or follows the live debug enable, fails it. The NDM reset half is not covered: resets after the start of the run are out of scope.'''
          milestone: "V2S"
          priority: "1"
          security: true
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_DBG_03
          desc: '''`lc_hw_debug_clr_i` at any value other than Off shall turn the latch Off.'''
          source: [
            '''[Non-debug Module Reset](hw/top_earlgrey/ip_autogen/pinmux/doc/theory_of_operation.md#non-debug-module-reset)'''
            '''[lc_ctrl.hjson `inter_signal_list` lc_hw_debug_clr](hw/ip/lc_ctrl/data/lc_ctrl.hjson)'''
            '''[HW_DEBUG_CLR](hw/ip/lc_ctrl/doc/theory_of_operation.md#hw_debug_clr)'''
            '''[Control Signal Propagation](hw/ip/lc_ctrl/doc/interfaces.md#control-signal-propagation)'''
            '''[top_${topname}_pinmux.ipconfig.hjson `enable_strap_sampling`](hw/top_${topname}/ip_autogen/pinmux/data/top_${topname}_pinmux.ipconfig.hjson)'''
          ]
          kind: "spec"
          testpoint: "latch"
          checks: ["CHK_LATCH_04 clear turns Off (assert_Latch_ClearTurnsOff)"]
          why: '''The check compares the output with Off in the cycle after `lc_hw_debug_clr_i` has been at any value other than Off, On included, for two cycles. A latch that stays On, or clears only at On, fails it.'''
          milestone: "V2S"
          priority: "1"
          security: true
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_DBG_04
          desc: '''`lc_check_byp_en_i` at any value other than Off shall turn the latch Off.'''
          source: [
            '''[Non-debug Module Reset](hw/top_earlgrey/ip_autogen/pinmux/doc/theory_of_operation.md#non-debug-module-reset)'''
            '''[Inter-Module Signals](hw/top_${topname}/ip_autogen/pinmux/doc/interfaces.md#inter-module-signals)'''
            '''[top_${topname}_pinmux.ipconfig.hjson `enable_strap_sampling`](hw/top_${topname}/ip_autogen/pinmux/data/top_${topname}_pinmux.ipconfig.hjson)'''
          ]
          kind: "spec"
          testpoint: "latch"
          checks: ["CHK_LATCH_04 clear turns Off (assert_Latch_ClearTurnsOff)"]
          why: '''The check compares the output with Off in the cycle after `lc_check_byp_en_i` has been at any value other than Off, On included, for two cycles. A latch that stays On through a life cycle transition, or clears only at On, fails it.'''
          milestone: "V2S"
          priority: "1"
          security: true
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_DBG_05
          desc: '''`lc_escalate_en_i` at any value other than Off shall turn the latch Off.'''
          source: [
            '''[Non-debug Module Reset](hw/top_earlgrey/ip_autogen/pinmux/doc/theory_of_operation.md#non-debug-module-reset)'''
            '''[Control Signal Propagation](hw/ip/lc_ctrl/doc/interfaces.md#control-signal-propagation)'''
            '''[top_${topname}_pinmux.ipconfig.hjson `enable_strap_sampling`](hw/top_${topname}/ip_autogen/pinmux/data/top_${topname}_pinmux.ipconfig.hjson)'''
          ]
          kind: "spec"
          testpoint: "latch"
          checks: ["CHK_LATCH_04 clear turns Off (assert_Latch_ClearTurnsOff)"]
          why: '''The check compares the output with Off in the cycle after `lc_escalate_en_i` has been at any of its 15 values other than Off for two cycles. A latch that ignores an escalation, or clears only at On, fails it.'''
          milestone: "V2S"
          priority: "1"
          security: true
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_DBG_06
          desc: '''`lc_hw_debug_clr_i` and `lc_check_byp_en_i` at Off shall not turn the latch Off.'''
          source: [
            '''[Non-debug Module Reset](hw/top_earlgrey/ip_autogen/pinmux/doc/theory_of_operation.md#non-debug-module-reset)'''
            '''[top_${topname}_pinmux.ipconfig.hjson `enable_strap_sampling`](hw/top_${topname}/ip_autogen/pinmux/data/top_${topname}_pinmux.ipconfig.hjson)'''
          ]
          kind: "spec"
          testpoint: "latch"
          checks: ["CHK_LATCH_05 latch holds (assert_Latch_LatchHolds)", "CHK_LATCH_02 pulse samples debug enable (assert_Latch_PulseSamplesDebugEnable)"]
          why: '''With `lc_hw_debug_clr_i` and `lc_check_byp_en_i` at Off, _latch holds_ (CHK_LATCH_05) asserts the output unchanged outside a strap pulse and _pulse samples debug enable_ (CHK_LATCH_02) asserts On after a pulse with the debug enable On. A latch cleared by an Off value fails one of them.'''
          milestone: "V2S"
          priority: "1"
          security: true
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_DBG_07a
          desc: '''`pinmux_hw_debug_en_o` shall be On while the latch is On.'''
          source: [
            '''[Inter-Module Signals](hw/top_${topname}/ip_autogen/pinmux/doc/interfaces.md#inter-module-signals)'''
            '''[pinmux.hjson `countermeasures` PINMUX_HW_DEBUG_EN.INTERSIG.MUBI](hw/top_${topname}/ip_autogen/pinmux/data/pinmux.hjson)'''
            '''[top_${topname}_pinmux.ipconfig.hjson `enable_strap_sampling`](hw/top_${topname}/ip_autogen/pinmux/data/top_${topname}_pinmux.ipconfig.hjson)'''
          ]
          kind: "spec"
          testpoint: "latch"
          checks: ["CHK_LATCH_06 output On or Off (assert_Latch_OutputOnOrOff)", "CHK_LATCH_02 pulse samples debug enable (assert_Latch_PulseSamplesDebugEnable)", "CHK_LATCH_05 latch holds (assert_Latch_LatchHolds)"]
          why: '''The latch is seen only on `pinmux_hw_debug_en_o`: _pulse samples debug enable_ (CHK_LATCH_02) and _latch holds_ (CHK_LATCH_05) compare it with On after an On sample and while held, and _output On or Off_ (CHK_LATCH_06) rejects the 14 other encodings. An output that shows anything but On while the latch is On fails one of them.'''
          milestone: "V2S"
          priority: "1"
          security: true
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_DBG_07b
          desc: '''`pinmux_hw_debug_en_o` shall be Off while the latch is not On.'''
          source: [
            '''[Inter-Module Signals](hw/top_${topname}/ip_autogen/pinmux/doc/interfaces.md#inter-module-signals)'''
            '''[pinmux.hjson `countermeasures` PINMUX_HW_DEBUG_EN.INTERSIG.MUBI](hw/top_${topname}/ip_autogen/pinmux/data/pinmux.hjson)'''
            '''[top_${topname}_pinmux.ipconfig.hjson `enable_strap_sampling`](hw/top_${topname}/ip_autogen/pinmux/data/top_${topname}_pinmux.ipconfig.hjson)'''
          ]
          kind: "spec"
          testpoint: "latch"
          checks: ["CHK_LATCH_06 output On or Off (assert_Latch_OutputOnOrOff)", "CHK_LATCH_03 On only at a pulse (assert_Latch_OnOnlyAtAPulse)", "CHK_LATCH_04 clear turns Off (assert_Latch_ClearTurnsOff)"]
          why: '''The check _output On or Off_ (CHK_LATCH_06) rejects every value but On and Off, _On only at a pulse_ (CHK_LATCH_03) any On the latch did not take at a strap pulse, and _clear turns Off_ (CHK_LATCH_04) anything but Off after a clear. An output at another encoding, or On while the latch is Off, fails one of them.'''
          milestone: "V2S"
          priority: "1"
          security: true
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_DBG_08
          desc: '''After a full reset, the latch shall be Off until the next `strap_en_i` pulse.'''
          source: [
            '''[Inter-Module Signals](hw/top_${topname}/ip_autogen/pinmux/doc/interfaces.md#inter-module-signals)'''
            '''[lc_ctrl.hjson `inter_signal_list` lc_hw_debug_en](hw/ip/lc_ctrl/data/lc_ctrl.hjson)'''
            '''[top_${topname}.hjson${eg(' `resets.nodes lc_io_div4`')}](hw/top_${topname}/data/top_${topname}.hjson)'''
            '''[top_${topname}.hjson${eg(' `resets.nodes sys_io_div4`')}](hw/top_${topname}/data/top_${topname}.hjson)'''
            '''[top_${topname}.hjson${eg(' `module.pinmux`')}](hw/top_${topname}/data/top_${topname}.hjson)'''
            '''[top_${topname}_pinmux.ipconfig.hjson `enable_strap_sampling`](hw/top_${topname}/ip_autogen/pinmux/data/top_${topname}_pinmux.ipconfig.hjson)'''
          ]
          kind: "spec"
          testpoint: "latch"
          checks: ["CHK_LATCH_01 Off from full reset (assert_Latch_OffFromFullReset)", "CHK_LATCH_03 On only at a pulse (assert_Latch_OnOnlyAtAPulse)"]
          why: '''The check _Off from full reset_ (CHK_LATCH_01) asserts Off in every cycle of a full reset, and _On only at a pulse_ (CHK_LATCH_03) fails any rise to On before a strap pulse with the debug enable On. Together they keep the output Off from the reset to the next pulse.'''
          milestone: "V2S"
          priority: "1"
          security: true
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_DBG_09
          desc: '''A clear in the cycle of a `strap_en_i` pulse shall leave the latch Off.'''
          source: [
            '''[Non-debug Module Reset](hw/top_earlgrey/ip_autogen/pinmux/doc/theory_of_operation.md#non-debug-module-reset)'''
            '''[top_${topname}_pinmux.ipconfig.hjson `enable_strap_sampling`](hw/top_${topname}/ip_autogen/pinmux/data/top_${topname}_pinmux.ipconfig.hjson)'''
          ]
          kind: "spec"
          testpoint: "latch"
          checks: ["CHK_LATCH_04 clear turns Off (assert_Latch_ClearTurnsOff)"]
          why: '''The check covers a clear at the strap pulse too: with `lc_hw_debug_clr_i`, `lc_check_byp_en_i` or `lc_escalate_en_i` at a value other than Off for the two cycles before the pulse, the output must be Off in the next cycle even with `lc_hw_debug_en_i` On. A latch where the sample wins over the clear fails it. A clear that begins in the pulse cycle is not decided, as no specification states how soon a clear acts.'''
          milestone: "V2S"
          priority: "1"
          security: true
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
      ]
    }
% endif
% if strap:
    {
      name: '''TAP selection and the JTAG pads'''
      conditions: [
        '''the JTAG pads are ${eg('IOR3 TCK, IOR0 TMS, IOR2 TDI, IOR4 TRST_N, IOR1 TDO (MIO 38, 35, 37, 39, 36; ', 'the pads the top description assigns to TCK, TMS, TDI, TRST_N and TDO (')}[top_${topname}.hjson${eg(' `targets.asic.pinmux.special_signals`')}](hw/top_${topname}/data/top_${topname}.hjson)). The rows hold once the straps and life cycle inputs have held for the delay of the input synchronizers; which reset drives a connected TAP's TRST_N in scan mode is open (`REQ_TAP_13`). A connected TAP: terms.'''
      ]
      requirements: [
        {
          name: REQ_TAP_01a
          desc: '''With TAP straps 01, `lc_jtag_o` shall carry TCK from its pad, in every life cycle state.'''
          source: [
            '''[Strap Sampling and TAP Isolation](hw/top_${topname}/ip_autogen/pinmux/doc/theory_of_operation.md#strap-sampling-and-tap-isolation)'''
            '''[top_${topname}.hjson${eg(' `inter_module.connect pinmux.lc_jtag`')}](hw/top_${topname}/data/top_${topname}.hjson)'''
            '''[top_${topname}.hjson${eg(' `targets.asic.pinmux.special_signals`')}](hw/top_${topname}/data/top_${topname}.hjson)'''
            '''[top_${topname}_pinmux.ipconfig.hjson `enable_strap_sampling`](hw/top_${topname}/ip_autogen/pinmux/data/top_${topname}_pinmux.ipconfig.hjson)'''
          ]
          kind: "spec"
          testpoint: "jtag"
          checks: ["CHK_JTAG_01 connected TAP gets the pads (assert_Jtag_ConnectedTAPGetsThePads)"]
          why: '''${eg('With TAP straps 01 the life cycle TAP is connected in every life cycle state, and the check compares the `tck` field of `lc_jtag_o` with MIO 38 (IOR3) in the same cycle, in scan mode too. A TCK from another pad, a cycle late or blocked by the life cycle state fails it.', 'Not written for this top.')}'''
          milestone: "V2S"
          priority: "1"
          security: true
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_TAP_01b
          desc: '''With TAP straps 01, `lc_jtag_o` shall carry TMS from its pad, in every life cycle state.'''
          source: [
            '''[Strap Sampling and TAP Isolation](hw/top_${topname}/ip_autogen/pinmux/doc/theory_of_operation.md#strap-sampling-and-tap-isolation)'''
            '''[top_${topname}.hjson${eg(' `inter_module.connect pinmux.lc_jtag`')}](hw/top_${topname}/data/top_${topname}.hjson)'''
            '''[top_${topname}.hjson${eg(' `targets.asic.pinmux.special_signals`')}](hw/top_${topname}/data/top_${topname}.hjson)'''
            '''[top_${topname}_pinmux.ipconfig.hjson `enable_strap_sampling`](hw/top_${topname}/ip_autogen/pinmux/data/top_${topname}_pinmux.ipconfig.hjson)'''
          ]
          kind: "spec"
          testpoint: "jtag"
          checks: ["CHK_JTAG_01 connected TAP gets the pads (assert_Jtag_ConnectedTAPGetsThePads)"]
          why: '''${eg('With TAP straps 01, the check compares the `tms` field of `lc_jtag_o` with MIO 35 (IOR0) in the same cycle, in every life cycle state and in scan mode. A TMS from another pad or a cycle late fails it.', 'Not written for this top.')}'''
          milestone: "V2S"
          priority: "1"
          security: true
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_TAP_01c
          desc: '''With TAP straps 01, `lc_jtag_o` shall carry TDI from its pad, in every life cycle state.'''
          source: [
            '''[Strap Sampling and TAP Isolation](hw/top_${topname}/ip_autogen/pinmux/doc/theory_of_operation.md#strap-sampling-and-tap-isolation)'''
            '''[top_${topname}.hjson${eg(' `inter_module.connect pinmux.lc_jtag`')}](hw/top_${topname}/data/top_${topname}.hjson)'''
            '''[top_${topname}.hjson${eg(' `targets.asic.pinmux.special_signals`')}](hw/top_${topname}/data/top_${topname}.hjson)'''
            '''[top_${topname}_pinmux.ipconfig.hjson `enable_strap_sampling`](hw/top_${topname}/ip_autogen/pinmux/data/top_${topname}_pinmux.ipconfig.hjson)'''
          ]
          kind: "spec"
          testpoint: "jtag"
          checks: ["CHK_JTAG_01 connected TAP gets the pads (assert_Jtag_ConnectedTAPGetsThePads)"]
          why: '''${eg('With TAP straps 01, the check compares the `tdi` field of `lc_jtag_o` with MIO 37 (IOR2) in the same cycle, in every life cycle state and in scan mode. A TDI from another pad or a cycle late fails it.', 'Not written for this top.')}'''
          milestone: "V2S"
          priority: "1"
          security: true
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_TAP_01d
          desc: '''With TAP straps 01, `lc_jtag_o` shall carry TRST_N from its pad, in every life cycle state.'''
          source: [
            '''[Strap Sampling and TAP Isolation](hw/top_${topname}/ip_autogen/pinmux/doc/theory_of_operation.md#strap-sampling-and-tap-isolation)'''
            '''[top_${topname}.hjson${eg(' `inter_module.connect pinmux.lc_jtag`')}](hw/top_${topname}/data/top_${topname}.hjson)'''
            '''[top_${topname}.hjson${eg(' `targets.asic.pinmux.special_signals`')}](hw/top_${topname}/data/top_${topname}.hjson)'''
            '''[top_${topname}_pinmux.ipconfig.hjson `enable_strap_sampling`](hw/top_${topname}/ip_autogen/pinmux/data/top_${topname}_pinmux.ipconfig.hjson)'''
          ]
          kind: "spec"
          testpoint: "jtag"
          checks: ["CHK_JTAG_01 connected TAP gets the pads (assert_Jtag_ConnectedTAPGetsThePads)"]
          why: '''${eg('Outside scan mode the check compares the `trst_n` field of `lc_jtag_o` with MIO 39 (IOR4) in the same cycle; a TAP held in reset, or released, against its pad fails it. In scan mode no specification states which reset TRST_N follows, so the field is not compared there.', 'Not written for this top.')}'''
          milestone: "V2S"
          priority: "1"
          security: true
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_TAP_02a
          desc: '''With TAP straps 10, `rv_jtag_o` shall carry the four input pads while the latch is On.'''
          source: [
            '''[Strap Sampling and TAP Isolation](hw/top_${topname}/ip_autogen/pinmux/doc/theory_of_operation.md#strap-sampling-and-tap-isolation)'''
            '''[Non-debug Module Reset](hw/top_earlgrey/ip_autogen/pinmux/doc/theory_of_operation.md#non-debug-module-reset)'''
            '''[Inter-Module Signals](hw/top_${topname}/ip_autogen/pinmux/doc/interfaces.md#inter-module-signals)'''
            '''[top_${topname}.hjson${eg(' `inter_module.connect pinmux.rv_jtag`')}](hw/top_${topname}/data/top_${topname}.hjson)'''
            '''[top_${topname}.hjson${eg(' `targets.asic.pinmux.special_signals`')}](hw/top_${topname}/data/top_${topname}.hjson)'''
            '''[top_${topname}_pinmux.ipconfig.hjson `enable_strap_sampling`](hw/top_${topname}/ip_autogen/pinmux/data/top_${topname}_pinmux.ipconfig.hjson)'''
          ]
          kind: "spec"
          testpoint: "jtag"
          checks: ["CHK_JTAG_01 connected TAP gets the pads (assert_Jtag_ConnectedTAPGetsThePads)"]
          why: '''With TAP straps 10 and `pinmux_hw_debug_en_o` On, the check compares the four fields of `rv_jtag_o` with the JTAG pads in the same cycle; a RISC-V TAP left unconnected fails it. In scan mode TRST_N waits on `REQ_TAP_13`.'''
          milestone: "V2S"
          priority: "1"
          security: true
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_TAP_02b
          desc: '''With TAP straps 10, `rv_jtag_o` shall not carry the four input pads while the latch is Off.'''
          source: [
            '''[Strap Sampling and TAP Isolation](hw/top_${topname}/ip_autogen/pinmux/doc/theory_of_operation.md#strap-sampling-and-tap-isolation)'''
            '''[Non-debug Module Reset](hw/top_earlgrey/ip_autogen/pinmux/doc/theory_of_operation.md#non-debug-module-reset)'''
            '''[Inter-Module Signals](hw/top_${topname}/ip_autogen/pinmux/doc/interfaces.md#inter-module-signals)'''
            '''[top_${topname}.hjson${eg(' `inter_module.connect pinmux.rv_jtag`')}](hw/top_${topname}/data/top_${topname}.hjson)'''
            '''[top_${topname}.hjson${eg(' `targets.asic.pinmux.special_signals`')}](hw/top_${topname}/data/top_${topname}.hjson)'''
            '''[top_${topname}_pinmux.ipconfig.hjson `enable_strap_sampling`](hw/top_${topname}/ip_autogen/pinmux/data/top_${topname}_pinmux.ipconfig.hjson)'''
          ]
          kind: "spec"
          testpoint: "jtag"
          checks: ["CHK_JTAG_02 cut TAP gets zero (assert_Jtag_CutTAPGetsZero)"]
          why: '''With TAP straps 10 and `pinmux_hw_debug_en_o` Off the RISC-V TAP is not connected, and the check asserts all four fields of `rv_jtag_o` 0. A TAP that still sees the pads after the latch is cleared, or that follows the live debug enable, fails it.'''
          milestone: "V2S"
          priority: "1"
          security: true
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_TAP_03a
          desc: '''With TAP straps 11, `dft_jtag_o` shall carry the four input pads while `lc_dft_en_i` is On.'''
          source: [
            '''[Strap Sampling and TAP Isolation](hw/top_${topname}/ip_autogen/pinmux/doc/theory_of_operation.md#strap-sampling-and-tap-isolation)'''
            '''[pinmux.hjson `countermeasures` TAP.MUX.LC_GATED](hw/top_${topname}/ip_autogen/pinmux/data/pinmux.hjson)'''
            '''[top_${topname}.hjson${eg(' `inter_module.top`')}](hw/top_${topname}/data/top_${topname}.hjson)'''
            '''[top_${topname}.hjson${eg(' `targets.asic.pinmux.special_signals`')}](hw/top_${topname}/data/top_${topname}.hjson)'''
            '''[top_${topname}_pinmux.ipconfig.hjson `enable_strap_sampling`](hw/top_${topname}/ip_autogen/pinmux/data/top_${topname}_pinmux.ipconfig.hjson)'''
          ]
          kind: "spec"
          testpoint: "jtag"
          checks: ["CHK_JTAG_01 connected TAP gets the pads (assert_Jtag_ConnectedTAPGetsThePads)"]
          why: '''With TAP straps 11 and `lc_dft_en_i` On for the two cycles before, the check compares the four fields of `dft_jtag_o` with the JTAG pads in the same cycle; a DFT TAP left unconnected in a test state fails it. In scan mode TRST_N waits on `REQ_TAP_13`.'''
          milestone: "V2S"
          priority: "1"
          security: true
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_TAP_03b
          desc: '''With TAP straps 11, `dft_jtag_o` shall not carry the four input pads while `lc_dft_en_i` is Off.'''
          source: [
            '''[Strap Sampling and TAP Isolation](hw/top_${topname}/ip_autogen/pinmux/doc/theory_of_operation.md#strap-sampling-and-tap-isolation)'''
            '''[pinmux.hjson `countermeasures` TAP.MUX.LC_GATED](hw/top_${topname}/ip_autogen/pinmux/data/pinmux.hjson)'''
            '''[top_${topname}.hjson${eg(' `inter_module.top`')}](hw/top_${topname}/data/top_${topname}.hjson)'''
            '''[top_${topname}.hjson${eg(' `targets.asic.pinmux.special_signals`')}](hw/top_${topname}/data/top_${topname}.hjson)'''
            '''[top_${topname}_pinmux.ipconfig.hjson `enable_strap_sampling`](hw/top_${topname}/ip_autogen/pinmux/data/top_${topname}_pinmux.ipconfig.hjson)'''
          ]
          kind: "spec"
          testpoint: "jtag"
          checks: ["CHK_JTAG_02 cut TAP gets zero (assert_Jtag_CutTAPGetsZero)"]
          why: '''With TAP straps 11 and `lc_dft_en_i` not On in the two cycles before, the check asserts `dft_jtag_o` all 0. A DFT TAP reachable in a PROD or DEV chip fails it.'''
          milestone: "V2S"
          priority: "1"
          security: true
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_TAP_04
          desc: '''Each of the life cycle, RISC-V and DFT TAPs shall receive an all-zero request while it is not connected.'''
          source: [
            '''[Strap Sampling and TAP Isolation](hw/top_${topname}/ip_autogen/pinmux/doc/theory_of_operation.md#strap-sampling-and-tap-isolation)'''
            '''[top_${topname}.hjson${eg(' `inter_module.connect`')}](hw/top_${topname}/data/top_${topname}.hjson)'''
            '''[top_${topname}.hjson${eg(' `inter_module.top`')}](hw/top_${topname}/data/top_${topname}.hjson)'''
            '''[top_${topname}_pinmux.ipconfig.hjson `enable_strap_sampling`](hw/top_${topname}/ip_autogen/pinmux/data/top_${topname}_pinmux.ipconfig.hjson)'''
          ]
          kind: "spec"
          testpoint: "jtag"
          checks: ["CHK_JTAG_02 cut TAP gets zero (assert_Jtag_CutTAPGetsZero)"]
          why: '''Outside scan mode, in every cycle, each of the life cycle, RISC-V and DFT TAPs that the straps do not name, or whose gate is not open, must see all four fields 0. A second TAP sharing the pads, or a TAP left connected after its gate closes, fails it.'''
          milestone: "V2S"
          priority: "1"
          security: true
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_TAP_05
          desc: '''`lc_dft_en_i` and `lc_hw_debug_en_i` shall count as On only at 4'b0101, in strap sampling, the latch and TAP selection.'''
          source: [
            '''[Control Signal Propagation](hw/ip/lc_ctrl/doc/interfaces.md#control-signal-propagation)'''
            '''[pinmux.hjson `countermeasures` LC_DFT_EN.INTERSIG.MUBI](hw/top_${topname}/ip_autogen/pinmux/data/pinmux.hjson)'''
            '''[top_${topname}_pinmux.ipconfig.hjson `enable_strap_sampling`](hw/top_${topname}/ip_autogen/pinmux/data/top_${topname}_pinmux.ipconfig.hjson)'''
          ]
          kind: "spec"
          testpoint: "jtag"
          checks: ["CHK_JTAG_03 only On opens", "CHK_JTAG_02 cut TAP gets zero (assert_Jtag_CutTAPGetsZero)", "CHK_STRAP_01 pulse samples the straps (assert_Strap_PulseSamplesTheStraps)", "CHK_STRAP_03 straps hold (assert_Strap_StrapsHold)", "CHK_LATCH_02 pulse samples debug enable (assert_Latch_PulseSamplesDebugEnable)"]
          why: '''The checks _only On opens_ (CHK_JTAG_03), _cut TAP gets zero_ (CHK_JTAG_02), _pulse samples the straps_ (CHK_STRAP_01), _straps hold_ (CHK_STRAP_03) and _pulse samples debug enable_ (CHK_LATCH_02) count `lc_dft_en_i` and `lc_hw_debug_en_i` as On only at 4'b0101, with both inputs free over all 16 values. A gate, a strap sample or a latch that opens on one of the 15 other values gives a request, a strap change or an On output that one of them forbids.'''
          milestone: "V2S"
          priority: "1"
          security: true
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_TAP_06a
          desc: '''While a TAP is connected, ${eg('pad IOR1', 'the TDO pad')} shall drive the TAP's TDO.'''
          source: [
            '''[top_${topname}.hjson${eg(' `targets.asic.pinmux.special_signals tdo`')}](hw/top_${topname}/data/top_${topname}.hjson)'''
            '''[JTAG](hw/ip/rv_dm/doc/interfaces.md#jtag)'''
            '''[Security Countermeasures](hw/ip/lc_ctrl/doc/interfaces.md#security-countermeasures)'''
            '''[top_${topname}_pinmux.ipconfig.hjson `enable_strap_sampling`](hw/top_${topname}/ip_autogen/pinmux/data/top_${topname}_pinmux.ipconfig.hjson)'''
          ]
          kind: "spec"
          testpoint: "jtag_pad"
          checks: ["CHK_JTAG_PAD_02 TDO pad drives the TAP (assert_JtagPad_TDOPadDrivesTheTAP)"]
          why: '''While a TAP is connected and the pad awake, the check compares `mio_out_o[36]` with the `tdo` of the connected TAP's response in the same cycle, `rram_jtag_i` for a connected RRAM TAP. A pad that drives its selected peripheral, another TAP's TDO or a late value fails it; a pad in sleep mode waits on `REQ_TAP_11`.'''
          milestone: "V2S"
          priority: "2"
          security: true
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_TAP_06b
          desc: '''While a TAP is connected, ${eg('pad IOR1', 'the TDO pad')} shall drive the TAP's output enable.'''
          source: [
            '''[top_${topname}.hjson${eg(' `targets.asic.pinmux.special_signals tdo`')}](hw/top_${topname}/data/top_${topname}.hjson)'''
            '''[JTAG](hw/ip/rv_dm/doc/interfaces.md#jtag)'''
            '''[Security Countermeasures](hw/ip/lc_ctrl/doc/interfaces.md#security-countermeasures)'''
            '''[top_${topname}_pinmux.ipconfig.hjson `enable_strap_sampling`](hw/top_${topname}/ip_autogen/pinmux/data/top_${topname}_pinmux.ipconfig.hjson)'''
          ]
          kind: "spec"
          testpoint: "jtag_pad"
          checks: ["CHK_JTAG_PAD_02 TDO pad drives the TAP (assert_JtagPad_TDOPadDrivesTheTAP)"]
          why: '''While a TAP is connected and the pad awake, the check compares `mio_oe_o[36]` with the `tdo_oe` of the connected TAP's response in the same cycle. A TDO driven while the TAP releases it, or left undriven while the TAP drives, fails it; sleep mode waits on `REQ_TAP_11`.'''
          milestone: "V2S"
          priority: "2"
          security: true
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_TAP_07
          desc: '''While a TAP is connected, ${eg('pads IOR0, IOR2, IOR3 and IOR4', 'the TMS, TDI, TCK and TRST_N pads')} shall have output enable 0.'''
          source: [
            '''The TAPs' standard JTAG port takes TCK, TMS, TRST_N and TDI as pad inputs and drives only TDO and its enable (the rv_dm docs `interfaces.md`:84, 89-94'''
            '''[Security Countermeasures](hw/ip/lc_ctrl/doc/interfaces.md#security-countermeasures)'''
            '''[top_${topname}.hjson${eg(' `targets.asic.pinmux.special_signals`')}](hw/top_${topname}/data/top_${topname}.hjson)'''
            '''[top_${topname}_pinmux.ipconfig.hjson `enable_strap_sampling`](hw/top_${topname}/ip_autogen/pinmux/data/top_${topname}_pinmux.ipconfig.hjson)'''
          ]
          kind: "spec"
          testpoint: "jtag_pad"
          checks: ["CHK_JTAG_PAD_03 input pads not driven (assert_JtagPad_InputPadsNotDriven)"]
          why: '''${eg('While a TAP is connected and the pads awake, the check asserts `mio_oe_o` 0 on MIO 35, 37, 38 and 39 whatever their output selects hold. A pad that still drives a peripheral against the debugger fails it; sleep mode waits on `REQ_TAP_11`.', 'Not written for this top.')}'''
          milestone: "V2S"
          priority: "2"
          security: true
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_TAP_08
          desc: '''While a TAP is connected, every attribute of the five JTAG pads shall be 0.'''
          source: [
            '''[Strap Sampling and TAP Isolation](hw/top_${topname}/ip_autogen/pinmux/doc/theory_of_operation.md#strap-sampling-and-tap-isolation)'''
            '''[top_${topname}.hjson${eg(' `targets.asic.pinmux.special_signals`')}](hw/top_${topname}/data/top_${topname}.hjson)'''
            '''[top_${topname}_pinmux.ipconfig.hjson `enable_strap_sampling`](hw/top_${topname}/ip_autogen/pinmux/data/top_${topname}_pinmux.ipconfig.hjson)'''
          ]
          kind: "spec"
          testpoint: "jtag_pad"
          checks: ["CHK_JTAG_PAD_04 JTAG attributes zero (assert_JtagPad_JTAGAttributesZero)"]
          why: '''${eg('While a TAP is connected and the pads awake, the check asserts every field of `mio_attr_o` 0 on MIO 35 to 39, with the attribute registers at any value. A pull-up, an inversion or a Schmitt trigger left on a JTAG pad fails it.', 'Not written for this top.')}'''
          milestone: "V2S"
          priority: "2"
          security: true
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_TAP_09
          desc: '''Connecting a TAP shall not change the JTAG pads' attribute registers.'''
          source: [
            '''[Strap Sampling and TAP Isolation](hw/top_${topname}/ip_autogen/pinmux/doc/theory_of_operation.md#strap-sampling-and-tap-isolation)'''
            '''[top_${topname}.hjson${eg(' `targets.asic.pinmux.special_signals`')}](hw/top_${topname}/data/top_${topname}.hjson)'''
            '''[top_${topname}_pinmux.ipconfig.hjson `enable_strap_sampling`](hw/top_${topname}/ip_autogen/pinmux/data/top_${topname}_pinmux.ipconfig.hjson)'''
          ]
          kind: "spec"
          testpoint: "jtag_pad"
          checks: ["CHK_JTAG_PAD_05 attribute registers untouched (assert_JtagPad_AttributeRegistersUntouched)"]
          why: '''In every cycle the check lets the read-back of each of the five pads' attribute registers change only by a software write. A design that clears or overwrites a register when a TAP connects or is disconnected fails it.'''
          milestone: "V2S"
          priority: "2"
          security: true
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_TAP_10
          desc: '''While a TAP is connected, a peripheral input that selects a JTAG pad shall read 0 or the pad.'''
          source: [
            '''[Strap Sampling and TAP Isolation](hw/top_${topname}/ip_autogen/pinmux/doc/theory_of_operation.md#strap-sampling-and-tap-isolation)'''
            '''[top_${topname}.hjson${eg(' `targets.asic.pinmux.special_signals`')}](hw/top_${topname}/data/top_${topname}.hjson)'''
            '''[top_${topname}_pinmux.ipconfig.hjson `enable_strap_sampling`](hw/top_${topname}/ip_autogen/pinmux/data/top_${topname}_pinmux.ipconfig.hjson)'''
          ]
          kind: "RTL"
          testpoint: "jtag_pad"
          checks: []
          why: '''Out of scope: no spec states a value, so either value meets the spec.'''
          milestone: "V2S"
          priority: "2"
          security: true
          state: "${eg('open: no check in this plan', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_TAP_11
          desc: '''While a TAP is connected and a JTAG pad's sleep mode is active, the pad shall carry one of two candidate outcomes, not yet decided: the TAP's signals, as the existing pinmux FPV testplan's JTAG rows want, or its sleep value, as the existing pinmux FPV testplan's sleep rows want.'''
          source: [
            '''[Retention Logic](hw/top_${topname}/ip_autogen/pinmux/doc/theory_of_operation.md#retention-logic)'''
            '''[Sleep Features](hw/top_${topname}/ip_autogen/pinmux/doc/programmers_guide.md#sleep-features)'''
            '''[Debug](hw/top_${topname}/ip_autogen/pwrmgr/doc/theory_of_operation.md#debug)'''
            '''[top_${topname}.hjson${eg(' `targets.asic.pinmux.special_signals`')}](hw/top_${topname}/data/top_${topname}.hjson)'''
            '''[top_${topname}_pinmux.ipconfig.hjson `enable_strap_sampling`](hw/top_${topname}/ip_autogen/pinmux/data/top_${topname}_pinmux.ipconfig.hjson)'''
          ]
          kind: "RTL"
          testpoint: "jtag_pad"
          checks: []
          why: '''No specification orders a pad's sleep mode against a connected TAP, so _JTAG pad in sleep mode_ (CHK_JTAG_PAD_01) waits on that answer.'''
          milestone: "V2S"
          priority: "2"
          security: true
          state: "${eg('open: no check in this plan', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_TAP_12
          desc: '''An NDM reset with no clear shall leave a connected RISC-V TAP connected.'''
          source: [
            '''[Life Cycle Control](hw/ip/rv_dm/doc/interfaces.md#life-cycle-control)'''
            '''[Non-debug Module Reset](hw/top_earlgrey/ip_autogen/pinmux/doc/theory_of_operation.md#non-debug-module-reset)'''
            '''[lc_ctrl.hjson `inter_signal_list` lc_hw_debug_en](hw/ip/lc_ctrl/data/lc_ctrl.hjson)'''
            '''[top_${topname}.hjson${eg(' `resets.nodes lc_io_div4`')}](hw/top_${topname}/data/top_${topname}.hjson)'''
            '''[top_${topname}.hjson${eg(' `resets.nodes sys_io_div4`')}](hw/top_${topname}/data/top_${topname}.hjson)'''
            '''[top_${topname}.hjson${eg(' `module.pinmux`')}](hw/top_${topname}/data/top_${topname}.hjson)'''
            '''[top_${topname}.hjson${eg(' `inter_module.connect pinmux.rv_jtag`')}](hw/top_${topname}/data/top_${topname}.hjson)'''
            '''[top_${topname}_pinmux.ipconfig.hjson `enable_strap_sampling`](hw/top_${topname}/ip_autogen/pinmux/data/top_${topname}_pinmux.ipconfig.hjson)'''
          ]
          kind: "spec"
          testpoint: "jtag_ndm"
          checks: []
          why: '''Not covered by formal: reset behaviour is out of scope.'''
          milestone: "V2S"
          priority: "2"
          security: true
          state: "${eg('open: no check in this plan', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_TAP_13
          desc: '''In scan mode, a connected TAP's TRST_N shall follow one of the pinmux's resets; which one is open.'''
          source: [
            '''[Strap Sampling and TAP Isolation](hw/top_${topname}/ip_autogen/pinmux/doc/theory_of_operation.md#strap-sampling-and-tap-isolation)'''
            '''[JTAG](hw/ip/rv_dm/doc/interfaces.md#jtag)'''
            '''[Security Countermeasures](hw/ip/lc_ctrl/doc/interfaces.md#security-countermeasures)'''
          ]
          kind: "RTL"
          testpoint: "jtag"
          checks: []
          why: '''No specification states which reset a connected TAP's TRST_N follows in scan mode, so _scan TRST follows reset_ (CHK_JTAG_04) waits on that answer.'''
          milestone: "V2S"
          priority: "1"
          security: true
          state: "${eg('open: no check in this plan', 'open: not reviewed for this top')}"
        }
      ]
    }
% endif
% if rram:
    {
      name: '''RRAM TAP'''
      conditions: [
        '''a top with the RRAM TAP ([top_${topname}_pinmux.ipconfig.hjson](hw/top_${topname}/ip_autogen/pinmux/data/top_${topname}_pinmux.ipconfig.hjson) `enable_rram_tap`; `top_${topname}.hjson`:1812-1813); a top without it has no row here, and its TAP straps 00 select no TAP ([Strap Sampling and TAP Isolation](hw/top_${topname}/ip_autogen/pinmux/doc/theory_of_operation.md#strap-sampling-and-tap-isolation)). The RRAM TAP's port is `rram_jtag`, wired to `rram_macro` ([Inter-Module Signals](hw/top_${topname}/ip_autogen/pinmux/doc/interfaces.md#inter-module-signals); [top_${topname}.hjson${eg(' `inter_module.connect pinmux.rv_jtag`')}](hw/top_${topname}/data/top_${topname}.hjson), [top_${topname}.hjson${eg(' `inter_module.connect.lc_ctrl.lc_dft_en`')}](hw/top_${topname}/data/top_${topname}.hjson)). `RRAM_JTAG_SEL` is a 4-bit multi-bit `rw` field with no lock and reset value `kMultiBitBool4False` (!!RRAM_JTAG_SEL); the register rows `REQ_REG_01a` and `REQ_REG_01b` cover its access and reset value. No doc names the reset that clears it; verification infers `rst_ni`, the reset of the main clock `clk_i` ([pinmux.hjson `clocking`](hw/top_${topname}/ip_autogen/pinmux/data/pinmux.hjson)). The JTAG pad rows of hold for the RRAM TAP too: it is a connected TAP (terms). The rows hold once the straps and `lc_nvm_debug_en_i` have held for the delay of the input synchronizers.'''
      ]
      requirements: [
        {
          name: REQ_RRAM_01
          desc: '''With TAP straps 00, `rram_jtag_o` shall carry the four input pads while `RRAM_JTAG_SEL` is `kMultiBitBool4True` and `lc_nvm_debug_en_i` is On.'''
          source: [
            '''[Strap Sampling and TAP Isolation](hw/top_${topname}/ip_autogen/pinmux/doc/theory_of_operation.md#strap-sampling-and-tap-isolation)'''
            '''[Inter-Module Signals](hw/top_${topname}/ip_autogen/pinmux/doc/interfaces.md#inter-module-signals)'''
            '''[pinmux.hjson `countermeasures` TAP.MUX.LC_GATED](hw/top_${topname}/ip_autogen/pinmux/data/pinmux.hjson)'''
            '''!!RRAM_JTAG_SEL'''
            '''[top_${topname}.hjson${eg(' `inter_module.connect pinmux.rram_jtag`')}](hw/top_${topname}/data/top_${topname}.hjson)'''
            '''[top_${topname}.hjson${eg(' `targets.asic.pinmux.special_signals`')}](hw/top_${topname}/data/top_${topname}.hjson)'''
            '''[top_${topname}_pinmux.ipconfig.hjson `enable_rram_tap`](hw/top_${topname}/ip_autogen/pinmux/data/top_${topname}_pinmux.ipconfig.hjson)'''
          ]
          kind: "spec"
          testpoint: "rram_tap"
          checks: ["CHK_RRAM_TAP_01 connected RRAM TAP gets the pads (assert_RramTap_ConnectedRRAMTAPGetsThePads)"]
          why: '''${eg('With TAP straps 00, `RRAM_JTAG_SEL` at `kMultiBitBool4True` and `lc_nvm_debug_en_i` On for the two cycles before, the check compares the four fields of `rram_jtag_o` with MIO 38, 35, 37 and 39 in the same cycle. An RRAM TAP left unconnected, fed from another pad or a cycle late fails it.', 'Not written for this top.')}'''
          milestone: "V2S"
          priority: "2"
          security: true
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_RRAM_02
          desc: '''While the RRAM TAP is not connected, `rram_jtag_o` shall carry TMS 0 and TDI 0.'''
          source: [
            '''[Strap Sampling and TAP Isolation](hw/top_${topname}/ip_autogen/pinmux/doc/theory_of_operation.md#strap-sampling-and-tap-isolation)'''
            '''!!RRAM_JTAG_SEL'''
            '''[Inter-Module Signals](hw/top_${topname}/ip_autogen/pinmux/doc/interfaces.md#inter-module-signals)'''
            '''[top_${topname}_pinmux.ipconfig.hjson `enable_rram_tap`](hw/top_${topname}/ip_autogen/pinmux/data/top_${topname}_pinmux.ipconfig.hjson)'''
          ]
          kind: "spec"
          testpoint: "rram_tap"
          checks: ["CHK_RRAM_TAP_02 cut RRAM TAP gets TMS and TDI 0 (assert_RramTap_CutRRAMTAPGetsTMSAndTDI0)"]
          why: '''In every cycle the RRAM TAP is cut, from the release of `rst_ni` on, the check asserts the `tms` and `tdi` fields of `rram_jtag_o` 0 whatever the JTAG pads carry. It leaves out the cycles in which the TAP is neither connected nor cut, the two after `lc_nvm_debug_en_i` changes and those after a strap sample taken in such a window, as no specification gives how soon a life cycle input or a strap sample acts. A TAP that still sees TMS or TDI from its pads after the straps, the register or `lc_nvm_debug_en_i` deselect it fails it.'''
          milestone: "V2S"
          priority: "2"
          security: true
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_RRAM_03
          desc: '''One clock cycle after the RRAM TAP stops being connected, the TCK of `rram_jtag_o` shall stop.'''
          source: [
            '''[Strap Sampling and TAP Isolation](hw/top_${topname}/ip_autogen/pinmux/doc/theory_of_operation.md#strap-sampling-and-tap-isolation)'''
            '''[top_${topname}_pinmux.ipconfig.hjson `enable_rram_tap`](hw/top_${topname}/ip_autogen/pinmux/data/top_${topname}_pinmux.ipconfig.hjson)'''
          ]
          kind: "spec"
          testpoint: "rram_tap"
          checks: []
          why: '''No specification states which clock the one clock cycle before TCK stops is counted in, nor what a stopped TCK holds, so _TCK stops after deselection_ (CHK_RRAM_TAP_04) waits on that answer.'''
          milestone: "V2S"
          priority: "2"
          security: true
          state: "${eg('open: no check in this plan', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_RRAM_04
          desc: '''`lc_nvm_debug_en_i` shall count as On only at 4'b0101 in the RRAM TAP's selection.'''
          source: [
            '''[Control Signal Propagation](hw/ip/lc_ctrl/doc/interfaces.md#control-signal-propagation)'''
            '''[pinmux.hjson `countermeasures` LC_NVM_DEBUG_EN.INTERSIG.MUBI](hw/top_${topname}/ip_autogen/pinmux/data/pinmux.hjson)'''
            '''[top_${topname}_pinmux.ipconfig.hjson `enable_rram_tap`](hw/top_${topname}/ip_autogen/pinmux/data/top_${topname}_pinmux.ipconfig.hjson)'''
          ]
          kind: "spec"
          testpoint: "rram_tap"
          checks: ["CHK_RRAM_TAP_03 only True and On open", "CHK_RRAM_TAP_02 cut RRAM TAP gets TMS and TDI 0 (assert_RramTap_CutRRAMTAPGetsTMSAndTDI0)"]
          why: '''The check _cut RRAM TAP gets TMS and TDI 0_ (CHK_RRAM_TAP_02) counts `lc_nvm_debug_en_i` as On only at 4'b0101, with the input free over all its values: held at any other value, the TAP is cut. A design that connects the RRAM TAP on a value other than On gives TMS or TDI from the pads, which the check forbids. It leaves out the two cycles after the input changes, as no specification gives how soon a life cycle input acts.'''
          milestone: "V2S"
          priority: "2"
          security: true
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_RRAM_05
          desc: '''After a reset, the RRAM TAP shall not be connected until software writes `kMultiBitBool4True` to `RRAM_JTAG_SEL`.'''
          source: [
            '''[Strap Sampling and TAP Isolation](hw/top_${topname}/ip_autogen/pinmux/doc/theory_of_operation.md#strap-sampling-and-tap-isolation)'''
            '''!!RRAM_JTAG_SEL'''
            '''[top_${topname}_pinmux.ipconfig.hjson `enable_rram_tap`](hw/top_${topname}/ip_autogen/pinmux/data/top_${topname}_pinmux.ipconfig.hjson)'''
          ]
          kind: "spec"
          testpoint: "rram_tap"
          checks: ["CHK_RRAM_TAP_06 cut until the register is written (assert_RramTap_CutUntilTheRegisterIsWritten)"]
          why: '''The check _cut until the register is written_ (CHK_RRAM_TAP_06) asserts the `tms` and `tdi` fields of `rram_jtag_o` 0 from the release of `rst_ni` up to the first accepted write to `RRAM_JTAG_SEL`, whatever the straps and `lc_nvm_debug_en_i` are; a TAP connected after a reset before that write fails it. Whether the generated register checker's checks cover this register is open; this check does not depend on it.'''
          milestone: "V2S"
          priority: "2"
          security: true
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_RRAM_06
          desc: '''`RRAM_JTAG_SEL` and `lc_nvm_debug_en_i` shall not change which of the life cycle, RISC-V and DFT TAPs is connected, nor what it receives.'''
          source: [
            '''[Strap Sampling and TAP Isolation](hw/top_${topname}/ip_autogen/pinmux/doc/theory_of_operation.md#strap-sampling-and-tap-isolation)'''
            '''!!RRAM_JTAG_SEL'''
            '''[top_${topname}_pinmux.ipconfig.hjson `enable_rram_tap`](hw/top_${topname}/ip_autogen/pinmux/data/top_${topname}_pinmux.ipconfig.hjson)'''
          ]
          kind: "spec"
          testpoint: "rram_tap"
          checks: ["CHK_JTAG_01 connected TAP gets the pads (assert_Jtag_ConnectedTAPGetsThePads)", "CHK_JTAG_02 cut TAP gets zero (assert_Jtag_CutTAPGetsZero)"]
          why: '''The checks _connected TAP gets the pads_ (CHK_JTAG_01) and _cut TAP gets zero_ (CHK_JTAG_02) decide the life cycle, RISC-V and DFT TAPs from the straps and their own gates, with `RRAM_JTAG_SEL` and `lc_nvm_debug_en_i` free over all their values. A design in which either connects, cuts or changes the request of one of the three fails one of them.'''
          milestone: "V2S"
          priority: "2"
          security: true
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_RRAM_07
          desc: '''`lc_check_byp_en_i` and the latch shall not change whether the RRAM TAP is connected.'''
          source: [
            '''[Strap Sampling and TAP Isolation](hw/top_${topname}/ip_autogen/pinmux/doc/theory_of_operation.md#strap-sampling-and-tap-isolation)'''
            '''[Non-debug Module Reset](hw/top_earlgrey/ip_autogen/pinmux/doc/theory_of_operation.md#non-debug-module-reset)'''
            '''[top_${topname}_pinmux.ipconfig.hjson `enable_rram_tap`](hw/top_${topname}/ip_autogen/pinmux/data/top_${topname}_pinmux.ipconfig.hjson)'''
          ]
          kind: "spec"
          testpoint: "rram_tap"
          checks: ["CHK_RRAM_TAP_05 RRAM TAP kept through a transition (assert_RramTap_RRAMTAPKeptThroughATransition)", "CHK_RRAM_TAP_02 cut RRAM TAP gets TMS and TDI 0 (assert_RramTap_CutRRAMTAPGetsTMSAndTDI0)"]
          why: '''The check _RRAM TAP kept through a transition_ (CHK_RRAM_TAP_05) asserts the request still equal to the JTAG pads while `lc_check_byp_en_i` is not Off or the latched debug enable is Off, and _cut RRAM TAP gets TMS and TDI 0_ (CHK_RRAM_TAP_02) holds with both free, so neither connects it. A design that cuts the RRAM TAP during a transition, as it cuts the RISC-V TAP, fails the first.'''
          milestone: "V2S"
          priority: "2"
          security: true
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_RRAM_08
          desc: '''While the RRAM TAP is not connected, before its first connection too, `rram_jtag_o` shall carry a TCK and a TRST_N whose values no spec states yet.'''
          source: [
            '''[Strap Sampling and TAP Isolation](hw/top_${topname}/ip_autogen/pinmux/doc/theory_of_operation.md#strap-sampling-and-tap-isolation)'''
            '''[Inter-Module Signals](hw/top_${topname}/ip_autogen/pinmux/doc/interfaces.md#inter-module-signals)'''
            '''[top_${topname}_pinmux.ipconfig.hjson `enable_rram_tap`](hw/top_${topname}/ip_autogen/pinmux/data/top_${topname}_pinmux.ipconfig.hjson)'''
          ]
          kind: "RTL"
          testpoint: "rram_tap"
          checks: []
          why: '''No specification states what TCK and TRST_N carry while the RRAM TAP is not connected, before its first connection too, so _TCK stops after deselection_ (CHK_RRAM_TAP_04) waits on that answer.'''
          milestone: "V2S"
          priority: "2"
          security: true
          state: "${eg('open: no check in this plan', 'open: not reviewed for this top')}"
        }
      ]
    }
% endif
% if strap:
    {
      name: '''DFT straps'''
      conditions: [
        '''`dft_strap_test_o` holds a valid bit and the straps, ${eg('bit 0 from IOR5 (MIO 40) and bit 1 from IOR7 (MIO 42)', 'bit 0 and bit 1 from the two DFT strap pads of the top description')} ([earlier FPV testplan: DftStrapTestO_A](hw/top_${topname}/ip_autogen/pinmux/data/pinmux_fpv_testplan.hjson); [top_${topname}.hjson${eg(' `targets.asic.pinmux.special_signals`')}](hw/top_${topname}/data/top_${topname}.hjson)).'''
      ]
      requirements: [
        {
          name: REQ_DFT_01a
          desc: '''At a `strap_en_i` pulse with `lc_dft_en_i` On, `dft_strap_test_o` shall take valid 1.'''
          source: [
            '''[Strap Sampling and TAP Isolation](hw/top_${topname}/ip_autogen/pinmux/doc/theory_of_operation.md#strap-sampling-and-tap-isolation)'''
            '''[Inter-Module Signals](hw/top_${topname}/ip_autogen/pinmux/doc/interfaces.md#inter-module-signals)'''
            '''[top_${topname}.hjson${eg(' `targets.asic.pinmux.special_signals`')}](hw/top_${topname}/data/top_${topname}.hjson)'''
            '''[top_${topname}_pinmux.ipconfig.hjson `enable_strap_sampling`](hw/top_${topname}/ip_autogen/pinmux/data/top_${topname}_pinmux.ipconfig.hjson)'''
            '''[Manufacturing States](doc/security/specs/device_life_cycle/README.md#manufacturing-states)'''
          ]
          kind: "spec"
          testpoint: "dft_strap"
          checks: ["CHK_DFT_STRAP_01 pulse samples DFT straps (assert_DftStrap_PulseSamplesDFTStraps)"]
          why: '''At a strap pulse with `lc_dft_en_i` On for the two cycles before, the check asserts the valid bit 1 from the next cycle. A design that misses the pulse leaves it 0 and fails.'''
          milestone: "V2S"
          priority: "2"
          security: true
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_DFT_01b
          desc: '''At a `strap_en_i` pulse with `lc_dft_en_i` On, the straps of `dft_strap_test_o` shall take the DFT strap pads' values.'''
          source: [
            '''[Strap Sampling and TAP Isolation](hw/top_${topname}/ip_autogen/pinmux/doc/theory_of_operation.md#strap-sampling-and-tap-isolation)'''
            '''[Inter-Module Signals](hw/top_${topname}/ip_autogen/pinmux/doc/interfaces.md#inter-module-signals)'''
            '''[top_${topname}.hjson${eg(' `targets.asic.pinmux.special_signals`')}](hw/top_${topname}/data/top_${topname}.hjson)'''
            '''[top_${topname}_pinmux.ipconfig.hjson `enable_strap_sampling`](hw/top_${topname}/ip_autogen/pinmux/data/top_${topname}_pinmux.ipconfig.hjson)'''
            '''[Manufacturing States](doc/security/specs/device_life_cycle/README.md#manufacturing-states)'''
          ]
          kind: "spec"
          testpoint: "dft_strap"
          checks: ["CHK_DFT_STRAP_01 pulse samples DFT straps (assert_DftStrap_PulseSamplesDFTStraps)"]
          why: '''${eg('At a strap pulse with `lc_dft_en_i` On for the two cycles before, the check compares the two straps in the next cycle with MIO 40 (IOR5, bit 0) and MIO 42 (IOR7, bit 1) of the pulse cycle or of the cycle after it, the one value where a pad holds it in both. A swapped or inverted strap, or a value from neither cycle, fails it.', 'Not written for this top.')}'''
          milestone: "V2S"
          priority: "2"
          security: true
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_DFT_02a
          desc: '''Once valid, `dft_strap_test_o` shall keep valid 1 until a full reset.'''
          source: [
            '''[Strap Sampling and TAP Isolation](hw/top_${topname}/ip_autogen/pinmux/doc/theory_of_operation.md#strap-sampling-and-tap-isolation)'''
            '''[Non-debug Module Reset](hw/top_earlgrey/ip_autogen/pinmux/doc/theory_of_operation.md#non-debug-module-reset)'''
            '''[top_${topname}.hjson${eg(' `resets.nodes lc_io_div4`')}](hw/top_${topname}/data/top_${topname}.hjson)'''
            '''[top_${topname}.hjson${eg(' `resets.nodes sys_io_div4`')}](hw/top_${topname}/data/top_${topname}.hjson)'''
            '''[top_${topname}.hjson${eg(' `module.pinmux`')}](hw/top_${topname}/data/top_${topname}.hjson)'''
            '''[top_${topname}_pinmux.ipconfig.hjson `enable_strap_sampling`](hw/top_${topname}/ip_autogen/pinmux/data/top_${topname}_pinmux.ipconfig.hjson)'''
          ]
          kind: "spec"
          testpoint: "dft_strap"
          checks: ["CHK_DFT_STRAP_02 DFT straps held (assert_DftStrap_DFTStrapsHeld)"]
          why: '''Once the valid bit is 1, the check asserts the output unchanged into every next cycle that is not in full reset, whatever `lc_dft_en_i` and the pads do. A valid bit that drops when the test enable goes Off fails it.'''
          milestone: "V2S"
          priority: "2"
          security: true
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_DFT_02b
          desc: '''Once valid, `dft_strap_test_o` shall keep its straps until a full reset.'''
          source: [
            '''[Strap Sampling and TAP Isolation](hw/top_${topname}/ip_autogen/pinmux/doc/theory_of_operation.md#strap-sampling-and-tap-isolation)'''
            '''[Non-debug Module Reset](hw/top_earlgrey/ip_autogen/pinmux/doc/theory_of_operation.md#non-debug-module-reset)'''
            '''[top_${topname}.hjson${eg(' `resets.nodes lc_io_div4`')}](hw/top_${topname}/data/top_${topname}.hjson)'''
            '''[top_${topname}.hjson${eg(' `resets.nodes sys_io_div4`')}](hw/top_${topname}/data/top_${topname}.hjson)'''
            '''[top_${topname}.hjson${eg(' `module.pinmux`')}](hw/top_${topname}/data/top_${topname}.hjson)'''
            '''[top_${topname}_pinmux.ipconfig.hjson `enable_strap_sampling`](hw/top_${topname}/ip_autogen/pinmux/data/top_${topname}_pinmux.ipconfig.hjson)'''
          ]
          kind: "spec"
          testpoint: "dft_strap"
          checks: ["CHK_DFT_STRAP_02 DFT straps held (assert_DftStrap_DFTStrapsHeld)"]
          why: '''Once the valid bit is 1, the check asserts the two straps unchanged into every next cycle that is not in full reset. A strap that keeps following its pad while `lc_dft_en_i` stays On fails it.'''
          milestone: "V2S"
          priority: "2"
          security: true
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
        {
          name: REQ_DFT_03
          desc: '''Before a sample at a `strap_en_i` pulse with `lc_dft_en_i` On, `dft_strap_test_o` shall be all 0, whatever the DFT strap pads carry.'''
          source: [
            '''[chip_testplan.hjson `testpoints.desc`](hw/top_earlgrey/data/chip_testplan.hjson)'''
            '''[top_${topname}.hjson${eg(' `targets.asic.pinmux.special_signals`')}](hw/top_${topname}/data/top_${topname}.hjson)'''
            '''[top_${topname}_pinmux.ipconfig.hjson `enable_strap_sampling`](hw/top_${topname}/ip_autogen/pinmux/data/top_${topname}_pinmux.ipconfig.hjson)'''
          ]
          kind: "spec"
          testpoint: "dft_strap"
          checks: ["CHK_DFT_STRAP_03 zero until sampled (assert_DftStrap_ZeroUntilSampled)"]
          why: '''Until a strap pulse with `lc_dft_en_i` On in either of the two cycles before, the check asserts every bit of `dft_strap_test_o` 0 with the strap pads free. A valid bit set by a PROD boot, or a pad value leaking through, fails it.'''
          milestone: "V2S"
          priority: "2"
          security: true
          state: "${eg('open', 'open: not reviewed for this top')}"
        }
      ]
    }
% endif
  ]
}
