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
  name: "pinmux"
  // The planned functional checks of the pinmux FPV environment. A testpoint
  // lists the requirements it closes under `features`; each is defined, with its
  // sources and the reason its checks prove it, in pinmux_fpv_requirements.hjson.
  // The register block is checked by the generated CSR checker (imported testplan).
  import_testplans: ["hw/dv/tools/dvsim/testplans/fpv_csr_testplan.hjson"]
  testpoints: [
    {
      name: pad_listen
      desc: '''Every peripheral input reads what its select names.

            | Check | Kind | Planned assertion | Requirements it decides |
            |---|---|---|---|
            | reads tie 0 | forward | `assert_PadListen_ReadsTie0` | REQ_IN_01, REQ_IN_06 |
            | reads tie 1 | forward | `assert_PadListen_ReadsTie1` | REQ_IN_02 |
            | reads selected pad | forward | `assert_PadListen_ReadsSelectedPad` | REQ_IN_03 |
            | no pad reads 0 | legal | `assert_PadListen_NoPadReads0` | REQ_IN_04 |
            | DIO reads its pad | forward | `assert_PadListen_DIOReadsItsPad` | REQ_IN_05 |
            | no claim here | none: out of scope | - | - |

            Requirements: [5](../doc/fpv/requirements.md#input-selection), each with its sources and the reason its checks prove it.'''
      stage: V1
      priority: "1"
      tests: []
      features: ["REQ_IN_01", "REQ_IN_02", "REQ_IN_03", "REQ_IN_04", "REQ_IN_05"]
    }
    {
      name: pad_output
      desc: '''Every awake pad drives what its select names.

            | Check | Kind | Planned assertion | Requirements it decides |
            |---|---|---|---|
            | tie 0 drives 0 | forward | `assert_PadOutput_Tie0Drives0` | REQ_OUT_01a, REQ_OUT_01b, REQ_SLP_08 |
            | tie 1 drives 1 | forward | `assert_PadOutput_Tie1Drives1` | REQ_OUT_02a, REQ_OUT_02b, REQ_SLP_08 |
            | select 2 is high-Z | forward | `assert_PadOutput_Select2IsHighZ` | REQ_OUT_03a, REQ_OUT_03b, REQ_OUT_07, REQ_SLP_08 |
            | drives selected output | forward | `assert_PadOutput_DrivesSelectedOutput` | REQ_OUT_04a, REQ_OUT_04b, REQ_SLP_08 |
            | no output is high-Z | legal | `assert_PadOutput_NoOutputIsHighZ` | REQ_OUT_05a, REQ_OUT_05b, REQ_SLP_08 |
            | DIO drives its peripheral | forward | `assert_PadOutput_DIODrivesItsPeripheral` | REQ_OUT_06a, REQ_OUT_06b, REQ_SLP_08 |
            | no claim here | none: out of scope | - | - |

            Requirements: [12](../doc/fpv/requirements.md#output-selection), each with its sources and the reason its checks prove it.'''
      stage: V1
      priority: "1"
      tests: []
      features: ["REQ_OUT_01a", "REQ_OUT_01b", "REQ_OUT_02a", "REQ_OUT_02b", "REQ_OUT_03a", "REQ_OUT_03b", "REQ_OUT_04a", "REQ_OUT_04b", "REQ_OUT_05a", "REQ_OUT_05b", "REQ_OUT_06a", "REQ_OUT_06b"]
    }
    {
      name: pad_sleep
      desc: '''A pad takes its sleep mode at sleep entry and holds it until software releases it.

            | Check | Kind | Planned assertion | Requirements it decides |
            |---|---|---|---|
            | bit set at entry | forward | `assert_PadSleep_BitSetAtEntry` | REQ_SLP_01 |
            | bit set only at entry | backward | `assert_PadSleep_BitSetOnlyAtEntry` | REQ_SLP_02 |
            | bit holds until cleared | stable | `assert_PadSleep_BitHoldsUntilCleared` | REQ_SLP_07 |
            | clear releases | forward | `assert_PadSleep_ClearReleases` | REQ_SLP_07 |
            | clear wins | forward | `assert_PadSleep_ClearWins` | REQ_SLP_09 |
            | tie low in sleep | forward | `assert_PadSleep_TieLowInSleep` | REQ_SLP_03a, REQ_SLP_03b, REQ_SLP_10b |
            | tie high in sleep | forward | `assert_PadSleep_TieHighInSleep` | REQ_SLP_04a, REQ_SLP_04b, REQ_SLP_10b |
            | high-Z in sleep | forward | `assert_PadSleep_HighZInSleep` | REQ_SLP_05a, REQ_SLP_05b, REQ_SLP_10b |
            | keep holds | stable | `assert_PadSleep_KeepHolds` | REQ_SLP_06a, REQ_SLP_06b, REQ_SLP_10b |
            | mode write while held | stable | `assert_PadSleep_ModeWriteWhileHeld` | REQ_SLP_10a |

            Requirements: [14](../doc/fpv/requirements.md#sleep-retention), each with its sources and the reason its checks prove it.'''
      stage: V2
      priority: "2"
      tests: []
      features: ["REQ_SLP_01", "REQ_SLP_02", "REQ_SLP_03a", "REQ_SLP_03b", "REQ_SLP_04a", "REQ_SLP_04b", "REQ_SLP_05a", "REQ_SLP_05b", "REQ_SLP_06a", "REQ_SLP_06b", "REQ_SLP_07", "REQ_SLP_09", "REQ_SLP_10a", "REQ_SLP_10b"]
    }
    {
      name: pad_attr
      desc: '''A pad gets exactly the attributes its register reads back.

            | Check | Kind | Planned assertion | Requirements it decides |
            |---|---|---|---|
            | pad gets read-back | both | `assert_PadAttr_PadGetsReadBack` | REQ_ATTR_01a, REQ_ATTR_01b, REQ_ATTR_01c, REQ_ATTR_01d, REQ_ATTR_01e, REQ_ATTR_01f, REQ_ATTR_01g, REQ_ATTR_01h, REQ_ATTR_01i, REQ_ATTR_01j, REQ_ATTR_02a, REQ_ATTR_02b, REQ_ATTR_02c, REQ_ATTR_02d, REQ_ATTR_02e, REQ_ATTR_02f, REQ_ATTR_02g, REQ_ATTR_02h, REQ_ATTR_02i, REQ_ATTR_02j |
            | invert reads back | forward | `assert_PadAttr_InvertReadsBack` | REQ_ATTR_03 |
            | open drain reads back | forward | `assert_PadAttr_OpenDrainReadsBack` | REQ_ATTR_04 |
            | virtual open drain reads back | forward | `assert_PadAttr_VirtualOpenDrainReadsBack` | REQ_ATTR_05 |
            | no open drain elsewhere | legal | `assert_PadAttr_NoOpenDrainElsewhere` | REQ_ATTR_06 |
            | no virtual open drain elsewhere | legal | `assert_PadAttr_NoVirtualOpenDrainElsewhere` | REQ_ATTR_07 |
            | supported bits read back | forward | `assert_PadAttr_SupportedBitsReadBack` | REQ_ATTR_08c, REQ_ATTR_08d, REQ_ATTR_08e, REQ_ATTR_08f, REQ_ATTR_08g, REQ_ATTR_08h, REQ_ATTR_08i |
            | unsupported bits read 0 | legal | `assert_PadAttr_UnsupportedBitsRead0` | REQ_ATTR_09c, REQ_ATTR_09d, REQ_ATTR_09e, REQ_ATTR_09f, REQ_ATTR_09g, REQ_ATTR_09h, REQ_ATTR_09i |
            | reset attributes | forward | `assert_PadAttr_ResetAttributes` | REQ_ATTR_10 |
            | read-back changes only on a write | stable | `assert_PadAttr_ReadBackChangesOnlyOnAWrite` | REQ_REG_01a |

            Requirements: [40](../doc/fpv/requirements.md#pad-attributes), each with its sources and the reason its checks prove it.'''
      stage: V2
      priority: "2"
      tests: []
      features: ["REQ_ATTR_01a", "REQ_ATTR_01b", "REQ_ATTR_01c", "REQ_ATTR_01d", "REQ_ATTR_01e", "REQ_ATTR_01f", "REQ_ATTR_01g", "REQ_ATTR_01h", "REQ_ATTR_01i", "REQ_ATTR_01j", "REQ_ATTR_02a", "REQ_ATTR_02b", "REQ_ATTR_02c", "REQ_ATTR_02d", "REQ_ATTR_02e", "REQ_ATTR_02f", "REQ_ATTR_02g", "REQ_ATTR_02h", "REQ_ATTR_02i", "REQ_ATTR_02j", "REQ_ATTR_03", "REQ_ATTR_04", "REQ_ATTR_05", "REQ_ATTR_06", "REQ_ATTR_07", "REQ_ATTR_08c", "REQ_ATTR_08d", "REQ_ATTR_08e", "REQ_ATTR_08f", "REQ_ATTR_08g", "REQ_ATTR_08h", "REQ_ATTR_08i", "REQ_ATTR_09c", "REQ_ATTR_09d", "REQ_ATTR_09e", "REQ_ATTR_09f", "REQ_ATTR_09g", "REQ_ATTR_09h", "REQ_ATTR_09i", "REQ_ATTR_10"]
    }
    {
      name: regwen
      desc: '''A closed attribute lock freezes the pad's attributes.

            | Check | Kind | Planned assertion | Requirements it decides |
            |---|---|---|---|
            | locked attribute holds | stable | `assert_Regwen_LockedAttributeHolds` | REQ_LOCK_03a |
            | locked read-back holds | stable | `assert_Regwen_LockedReadBackHolds` | REQ_LOCK_03b, REQ_LOCK_02 |

            Requirements: [2](../doc/fpv/requirements.md#register-locks), each with its sources and the reason its checks prove it.'''
      stage: V2
      priority: "2"
      tests: []
      features: ["REQ_LOCK_03a", "REQ_LOCK_03b"]
    }
    {
      name: bus
      desc: '''Every request is answered by the TL-UL rules, and a failed one changes nothing.

            | Check | Kind | Planned assertion | Requirements it decides |
            |---|---|---|---|
            | device rules | forward | `assert_Bus_DeviceRules` | REQ_BUS_01a, REQ_BUS_01b |
            | errors as the register checker predicts | both | through other checks | REQ_BUS_01c, REQ_BUS_10a, REQ_BUS_10b, REQ_BUS_10c, REQ_BUS_10d, REQ_BUS_10e |
            | response codes correct | forward | `assert_Bus_ResponseCodesCorrect` | REQ_BUS_02a, REQ_BUS_02b |
            | failed request errors | forward | `assert_Bus_FailedRequestErrors` | REQ_BUS_03 |
            | failed write changes nothing | stable | `assert_Bus_FailedWriteChangesNothing` | REQ_BUS_04 |
            | error write changes nothing | stable | through other checks | REQ_BUS_11 |

            Requirements: [13](../doc/fpv/requirements.md#register-block-and-bus), each with its sources and the reason its checks prove it.'''
      stage: V2
      priority: "2"
      tests: []
      features: ["REQ_BUS_01a", "REQ_BUS_01b", "REQ_BUS_01c", "REQ_BUS_02a", "REQ_BUS_02b", "REQ_BUS_03", "REQ_BUS_04", "REQ_BUS_10a", "REQ_BUS_10b", "REQ_BUS_10c", "REQ_BUS_10d", "REQ_BUS_10e", "REQ_BUS_11"]
    }
    {
      name: alert
      desc: '''The fatal alert follows a failed request or an alert test, and nothing else.

            | Check | Kind | Planned assertion | Requirements it decides |
            |---|---|---|---|
            | failed request alerts | forward | `assert_Alert_FailedRequestAlerts` | REQ_BUS_05 |
            | fatal alert repeats | forward | `assert_Alert_FatalAlertRepeats` | REQ_BUS_06 |
            | test sends an event | forward | `assert_Alert_TestSendsAnEvent` | REQ_BUS_07 |
            | no alert without a cause | backward | `assert_Alert_NoAlertWithoutACause` | REQ_BUS_07, REQ_BUS_08, REQ_BUS_09 |

            Requirements: [5](../doc/fpv/requirements.md#register-block-and-bus), each with its sources and the reason its checks prove it.'''
      stage: V2S
      priority: "2"
      tests: []
      features: ["REQ_BUS_05", "REQ_BUS_06", "REQ_BUS_07", "REQ_BUS_08", "REQ_BUS_09"]
    }
    {
      name: wakeup
      desc: '''A detector writes its cause bit on its pattern, and only then.

            | Check | Kind | Planned assertion | Requirements it decides |
            |---|---|---|---|
            | posedge sets cause | forward | `assert_Wakeup_PosedgeSetsCause` | REQ_WKUP_13a, REQ_WKUP_13b, REQ_WKUP_06a, REQ_WKUP_11, REQ_WKUP_14 |
            | negedge sets cause | forward | `assert_Wakeup_NegedgeSetsCause` | REQ_WKUP_07a, REQ_WKUP_14 |
            | edge sets cause | forward | `assert_Wakeup_EdgeSetsCause` | REQ_WKUP_01, REQ_WKUP_02, REQ_WKUP_04, REQ_WKUP_05, REQ_WKUP_08a, REQ_WKUP_14 |
            | timed high sets cause | forward | `assert_Wakeup_TimedHighSetsCause` | REQ_WKUP_01, REQ_WKUP_09a, REQ_WKUP_14 |
            | timed low sets cause | forward | `assert_Wakeup_TimedLowSetsCause` | REQ_WKUP_01, REQ_WKUP_03, REQ_WKUP_10a, REQ_WKUP_14 |
            | no false cause | backward | `assert_Wakeup_NoFalseCause` | REQ_WKUP_01, REQ_WKUP_02, REQ_WKUP_03, REQ_WKUP_04, REQ_WKUP_05, REQ_WKUP_13a, REQ_WKUP_13b, REQ_WKUP_06b, REQ_WKUP_07b, REQ_WKUP_08b, REQ_WKUP_09b, REQ_WKUP_10b, REQ_WKUP_11, REQ_WKUP_12, REQ_WKUP_15 |
            | set lands | forward | `assert_Wakeup_SetLands` | REQ_WKUP_14 |
            | cause rises only on a set | backward | `assert_Wakeup_CauseRisesOnlyOnASet` | REQ_WKUP_15 |

            Requirements: [21](../doc/fpv/requirements.md#wakeup-detectors), each with its sources and the reason its checks prove it.'''
      stage: V2
      priority: "1"
      tests: []
      features: ["REQ_WKUP_01", "REQ_WKUP_02", "REQ_WKUP_03", "REQ_WKUP_04", "REQ_WKUP_05", "REQ_WKUP_13a", "REQ_WKUP_13b", "REQ_WKUP_06a", "REQ_WKUP_06b", "REQ_WKUP_07a", "REQ_WKUP_07b", "REQ_WKUP_08a", "REQ_WKUP_08b", "REQ_WKUP_09a", "REQ_WKUP_09b", "REQ_WKUP_10a", "REQ_WKUP_10b", "REQ_WKUP_11", "REQ_WKUP_12", "REQ_WKUP_14", "REQ_WKUP_15"]
    }
    {
      name: wakeup_cause
      desc: '''A cause bit holds until software clears it, and the request follows the bits.

            | Check | Kind | Planned assertion | Requirements it decides |
            |---|---|---|---|
            | hardware only sets cause | stable | `assert_WakeupCause_HardwareOnlySetsCause` | REQ_WKUP_16 |
            | cause holds until cleared | stable | `assert_WakeupCause_CauseHoldsUntilCleared` | REQ_WKUP_16 |
            | set and clear together | forward | `assert_WakeupCause_SetAndClearTogether` | REQ_WKUP_17 |
            | request follows cause | forward | `assert_WakeupCause_RequestFollowsCause` | REQ_WKUP_18a |
            | no request without cause | backward | `assert_WakeupCause_NoRequestWithoutCause` | REQ_WKUP_18b |

            Requirements: [4](../doc/fpv/requirements.md#wakeup-detectors), each with its sources and the reason its checks prove it.'''
      stage: V2
      priority: "2"
      tests: []
      features: ["REQ_WKUP_16", "REQ_WKUP_17", "REQ_WKUP_18a", "REQ_WKUP_18b"]
    }
    {
      name: wakeup_sync
      desc: '''Every write to the AON fields and every clear reaches the AON logic in bounded time.

            | Check | Kind | Planned assertion | Requirements it decides |
            |---|---|---|---|
            | write lands | forward | `assert_WakeupSync_WriteLands` | REQ_WKUP_19a, REQ_WKUP_19b, REQ_WKUP_19c |
            | no change without a write | backward | `assert_WakeupSync_NoChangeWithoutAWrite` | REQ_WKUP_19a, REQ_WKUP_19b, REQ_WKUP_19c |
            | clear lands | forward | `assert_WakeupSync_ClearLands` | REQ_WKUP_19d |
            | no clear without a write | backward | `assert_WakeupSync_NoClearWithoutAWrite` | REQ_WKUP_19d |
            | landed clear clears cause | forward | `assert_WakeupSync_LandedClearClearsCause` | REQ_WKUP_19d |
            | writes land in order | forward | `assert_WakeupSync_WritesLandInOrder` | REQ_WKUP_20a, REQ_WKUP_20b |

            Requirements: [6](../doc/fpv/requirements.md#wakeup-detectors), each with its sources and the reason its checks prove it.'''
      stage: V2
      priority: "2"
      tests: []
      features: ["REQ_WKUP_19a", "REQ_WKUP_19b", "REQ_WKUP_19c", "REQ_WKUP_19d", "REQ_WKUP_20a", "REQ_WKUP_20b"]
    }
% if usb:
    {
      name: usb_conn
      desc: '''Every module port carries the pinmux signal of the same role.

            | Check | Kind | Planned assertion | Requirements it decides |
            |---|---|---|---|
            | D+ pull-up enable in | both | `assert_UsbConn_DpPullUpEnableIn` | REQ_USB_01a |
            | D- pull-up enable in | both | `assert_UsbConn_DnPullUpEnableIn` | REQ_USB_01b |
            | suspend request in | both | `assert_UsbConn_SuspendRequestIn` | REQ_USB_01c |
            | wake acknowledge in | both | `assert_UsbConn_WakeAcknowledgeIn` | REQ_USB_01d |
            | D+ pull-up enable out | both | `assert_UsbConn_DpPullUpEnableOut` | REQ_USB_02a |
            | D- pull-up enable out | both | `assert_UsbConn_DnPullUpEnableOut` | REQ_USB_02b |
            | bus not idle out | both | `assert_UsbConn_BusNotIdleOut` | REQ_USB_02c |
            | bus reset out | both | `assert_UsbConn_BusResetOut` | REQ_USB_02d |
            | sense lost out | both | `assert_UsbConn_SenseLostOut` | REQ_USB_02e |
            | active out | both | `assert_UsbConn_ActiveOut` | REQ_USB_02f |
            | wake request out | both | `assert_UsbConn_WakeRequestOut` | REQ_USB_03 |
            | module on AON clock | both | `assert_UsbConn_ModuleOnAONClock` | REQ_USB_04a |
            | module on AON reset | none: out of scope | - | REQ_USB_04b |
            | bus inputs | both | `assert_UsbConn_BusInputs` | REQ_USB_05a, REQ_USB_05b, REQ_USB_05c |

            Requirements: [16](../doc/fpv/requirements.md#usb-wakeup), each with its sources and the reason its checks prove it.'''
      stage: V2
      priority: "2"
      tests: []
      features: ["REQ_USB_01a", "REQ_USB_01b", "REQ_USB_01c", "REQ_USB_01d", "REQ_USB_02a", "REQ_USB_02b", "REQ_USB_02c", "REQ_USB_02d", "REQ_USB_02e", "REQ_USB_02f", "REQ_USB_03", "REQ_USB_04a", "REQ_USB_04b", "REQ_USB_05a", "REQ_USB_05b", "REQ_USB_05c"]
    }
% endif
% if strap:
    {
      name: strap
      desc: '''The TAP straps sample as the life cycle allows and hold otherwise.

            | Check | Kind | Planned assertion | Requirements it decides |
            |---|---|---|---|
            | pulse samples the straps | forward | `assert_Strap_PulseSamplesTheStraps` | REQ_STRAP_01, REQ_STRAP_02a, REQ_STRAP_02b, REQ_STRAP_06, REQ_TAP_05 |
            | straps follow the pads | forward | `assert_Strap_StrapsFollowThePads` | REQ_STRAP_03 |
            | straps hold | stable | `assert_Strap_StrapsHold` | REQ_STRAP_04, REQ_STRAP_05, REQ_STRAP_06, REQ_STRAP_08, REQ_TAP_05 |
            | unsampled strap reads 0 | forward | `assert_Strap_UnsampledStrapReads0` | REQ_STRAP_06 |
            | straps kept by an NDM reset | none: out of scope | - | REQ_STRAP_07 |

            Requirements: [9](../doc/fpv/requirements.md#strap-sampling), each with its sources and the reason its checks prove it.'''
      stage: V2S
      priority: "1"
      tests: []
      features: ["REQ_STRAP_01", "REQ_STRAP_02a", "REQ_STRAP_02b", "REQ_STRAP_03", "REQ_STRAP_04", "REQ_STRAP_05", "REQ_STRAP_06", "REQ_STRAP_07", "REQ_STRAP_08"]
    }
% endif
% if strap:
    {
      name: dft_strap
      desc: '''The DFT straps are sampled once at boot in the test states and held.

            | Check | Kind | Planned assertion | Requirements it decides |
            |---|---|---|---|
            | pulse samples DFT straps | forward | `assert_DftStrap_PulseSamplesDFTStraps` | REQ_DFT_01a, REQ_DFT_01b |
            | DFT straps held | stable | `assert_DftStrap_DFTStrapsHeld` | REQ_DFT_02a, REQ_DFT_02b |
            | zero until sampled | backward | `assert_DftStrap_ZeroUntilSampled` | REQ_DFT_03 |

            Requirements: [5](../doc/fpv/requirements.md#dft-straps), each with its sources and the reason its checks prove it.'''
      stage: V2S
      priority: "2"
      tests: []
      features: ["REQ_DFT_01a", "REQ_DFT_01b", "REQ_DFT_02a", "REQ_DFT_02b", "REQ_DFT_03"]
    }
% endif
% if strap:
    {
      name: latch
      desc: '''The debug enable is taken at boot, cleared by life cycle, kept otherwise.

            | Check | Kind | Planned assertion | Requirements it decides |
            |---|---|---|---|
            | Off from full reset | forward | `assert_Latch_OffFromFullReset` | REQ_DBG_08 |
            | pulse samples debug enable | forward | `assert_Latch_PulseSamplesDebugEnable` | REQ_DBG_01a, REQ_DBG_01b, REQ_DBG_06, REQ_DBG_07a, REQ_TAP_05 |
            | On only at a pulse | backward | `assert_Latch_OnOnlyAtAPulse` | REQ_DBG_01b, REQ_DBG_07b, REQ_DBG_08 |
            | clear turns Off | forward | `assert_Latch_ClearTurnsOff` | REQ_DBG_03, REQ_DBG_04, REQ_DBG_05, REQ_DBG_07b, REQ_DBG_09 |
            | latch holds | stable | `assert_Latch_LatchHolds` | REQ_DBG_02, REQ_DBG_06, REQ_DBG_07a |
            | output On or Off | legal | `assert_Latch_OutputOnOrOff` | REQ_DBG_07a, REQ_DBG_07b |

            Requirements: [11](../doc/fpv/requirements.md#latched-debug-enable), each with its sources and the reason its checks prove it.'''
      stage: V2S
      priority: "1"
      tests: []
      features: ["REQ_DBG_01a", "REQ_DBG_01b", "REQ_DBG_02", "REQ_DBG_03", "REQ_DBG_04", "REQ_DBG_05", "REQ_DBG_06", "REQ_DBG_07a", "REQ_DBG_07b", "REQ_DBG_08", "REQ_DBG_09"]
    }
% endif
% if strap:
    {
      name: jtag
      desc: '''The TAP the straps ask for gets the pads only while life cycle allows it.

            | Check | Kind | Planned assertion | Requirements it decides |
            |---|---|---|---|
            | connected TAP gets the pads | forward | `assert_Jtag_ConnectedTAPGetsThePads` | REQ_TAP_01a, REQ_TAP_01b, REQ_TAP_01c, REQ_TAP_01d, REQ_TAP_02a, REQ_TAP_03a${on(rram, ', REQ_RRAM_06')} |
            | cut TAP gets zero | backward | `assert_Jtag_CutTAPGetsZero` | REQ_TAP_02b, REQ_TAP_03b, REQ_TAP_04, REQ_TAP_05${on(rram, ', REQ_RRAM_06')} |
            | only On opens | legal | through other checks | REQ_TAP_05 |
            | scan TRST follows reset | waits on a specification question | `assert_Jtag_ScanTRSTFollowsReset` | REQ_TAP_13 |

            Requirements: [11](../doc/fpv/requirements.md#tap-selection-and-the-jtag-pads), each with its sources and the reason its checks prove it.'''
      stage: V2S
      priority: "1"
      tests: []
      features: ["REQ_TAP_01a", "REQ_TAP_01b", "REQ_TAP_01c", "REQ_TAP_01d", "REQ_TAP_02a", "REQ_TAP_02b", "REQ_TAP_03a", "REQ_TAP_03b", "REQ_TAP_04", "REQ_TAP_05", "REQ_TAP_13"]
    }
% endif
% if rram:
    {
      name: rram_tap
      desc: '''The RRAM TAP gets the JTAG pads on straps 00 only while its register and life cycle allow it.

            | Check | Kind | Planned assertion | Requirements it decides |
            |---|---|---|---|
            | connected RRAM TAP gets the pads | forward | `assert_RramTap_ConnectedRRAMTAPGetsThePads` | REQ_RRAM_01 |
            | cut RRAM TAP gets TMS and TDI 0 | backward | `assert_RramTap_CutRRAMTAPGetsTMSAndTDI0` | REQ_RRAM_02, REQ_RRAM_04, REQ_RRAM_07 |
            | only True and On open | legal | through other checks | REQ_RRAM_04 |
            | TCK stops after deselection | waits on a specification question | `assert_RramTap_TCKStopsAfterDeselection` | REQ_RRAM_03, REQ_RRAM_08 |
            | RRAM TAP kept through a transition | stable | `assert_RramTap_RRAMTAPKeptThroughATransition` | REQ_RRAM_07 |
            | cut until the register is written | backward | `assert_RramTap_CutUntilTheRegisterIsWritten` | REQ_RRAM_05 |

            Requirements: [8](../doc/fpv/requirements.md#rram-tap), each with its sources and the reason its checks prove it.'''
      stage: V2S
      priority: "2"
      tests: []
      features: ["REQ_RRAM_01", "REQ_RRAM_02", "REQ_RRAM_03", "REQ_RRAM_04", "REQ_RRAM_05", "REQ_RRAM_06", "REQ_RRAM_07", "REQ_RRAM_08"]
    }
% endif
% if strap:
    {
      name: jtag_pad
      desc: '''While a TAP is connected, the five JTAG pads belong to it.

            | Check | Kind | Planned assertion | Requirements it decides |
            |---|---|---|---|
            | JTAG pad in sleep mode | waits on a specification question | `assert_JtagPad_JTAGPadInSleepMode` | REQ_TAP_11 |
            | TDO pad drives the TAP | forward | `assert_JtagPad_TDOPadDrivesTheTAP` | REQ_TAP_06a, REQ_TAP_06b |
            | input pads not driven | forward | `assert_JtagPad_InputPadsNotDriven` | REQ_TAP_07 |
            | JTAG attributes zero | forward | `assert_JtagPad_JTAGAttributesZero` | REQ_TAP_08 |
            | attribute registers untouched | stable | `assert_JtagPad_AttributeRegistersUntouched` | REQ_TAP_09 |
            | peripheral view of an owned pad | none: out of scope | - | REQ_TAP_10 |

            Requirements: [7](../doc/fpv/requirements.md#tap-selection-and-the-jtag-pads), each with its sources and the reason its checks prove it.'''
      stage: V2S
      priority: "2"
      tests: []
      features: ["REQ_TAP_06a", "REQ_TAP_06b", "REQ_TAP_07", "REQ_TAP_08", "REQ_TAP_09", "REQ_TAP_10", "REQ_TAP_11"]
    }
% endif
    {
      name: reset_state
      desc: '''Every input reads 0 and every awake MIO pad is high-Z after reset.

            No check of its own: follows from other testpoints.

            Requirements: [2](../doc/fpv/requirements.md#input-selection), each with its sources and the reason its checks prove it.'''
      stage: V2
      priority: "2"
      tests: []
      features: ["REQ_IN_06", "REQ_OUT_07"]
    }
    {
      name: sleep_release
      desc: '''A pad whose status bit is 0 drives what its select names.

            No check of its own: follows from other testpoints.

            Requirements: [1](../doc/fpv/requirements.md#sleep-retention), each with its sources and the reason its checks prove it.'''
      stage: V2
      priority: "2"
      tests: []
      features: ["REQ_SLP_08"]
    }
% if usb:
    {
      name: usb_module
      desc: '''The USB wakeup module behaves as usbdev's spec says.

            No check of its own: usbdev's tests.

            Requirements: [1](../doc/fpv/requirements.md#usb-wakeup), each with its sources and the reason its checks prove it.'''
      stage: V2
      priority: "2"
      tests: []
      features: ["REQ_USB_06"]
    }
% endif
% if strap:
    {
      name: jtag_ndm
      desc: '''An NDM reset keeps a connected RISC-V TAP.

            | Check | Kind | Planned assertion | Requirements it decides |
            |---|---|---|---|
            | TAP kept by an NDM reset | none: out of scope | - | REQ_TAP_12 |

            Requirements: [1](../doc/fpv/requirements.md#tap-selection-and-the-jtag-pads), each with its sources and the reason its checks prove it.'''
      stage: V2S
      priority: "2"
      tests: []
      features: ["REQ_TAP_12"]
    }
% endif
  ]
}
