// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// The pinmux register map as the formal environment computes it from the register spec: the
// order of the register families in pinmux.hjson (rendered as registers.md), one 32-bit word per
// register, and the instance's counts. The environment decodes bus writes and reads with these
// offsets instead of the generated register package, so a wrong offset in the design is not
// shared by the checks. Only the counts come from the instance's configuration.
//
// <Family>Base is the offset of a family's register 0; reg_addr(<Family>Base, i) the offset of
// its register i.

// Not every constant is used by every top's environment.
/* verilator lint_off UNUSEDPARAM */
package pinmux_fpv_regmap_pkg;

  import pinmux_reg_pkg::BlockAw;
  import pinmux_reg_pkg::NMioPeriphIn;
  import pinmux_reg_pkg::NMioPads;
  import pinmux_reg_pkg::NDioPads;
  import pinmux_reg_pkg::NWkupDetect;

  typedef logic [BlockAw-1:0] addr_t;

  // Registers of the MIO and DIO sleep status families: 32 pads per register.
  localparam int unsigned NMioStatusRegs  = (NMioPads + 31) / 32;
  localparam int unsigned NDioStatusRegs  = (NDioPads + 31) / 32;

  // Offset of each family's register 0, in the order of the register spec.
  localparam addr_t AlertTestAddr         = '0;
  localparam addr_t InselRegwenBase       = AlertTestAddr + 4;
  localparam addr_t InselBase             = InselRegwenBase + addr_t'(4 * NMioPeriphIn);
  localparam addr_t OutselRegwenBase      = InselBase + addr_t'(4 * NMioPeriphIn);
  localparam addr_t OutselBase            = OutselRegwenBase + addr_t'(4 * NMioPads);
  localparam addr_t MioAttrRegwenBase     = OutselBase + addr_t'(4 * NMioPads);
  localparam addr_t MioAttrBase           = MioAttrRegwenBase + addr_t'(4 * NMioPads);
  localparam addr_t DioAttrRegwenBase     = MioAttrBase + addr_t'(4 * NMioPads);
  localparam addr_t DioAttrBase           = DioAttrRegwenBase + addr_t'(4 * NDioPads);
  localparam addr_t MioSleepStatusBase    = DioAttrBase + addr_t'(4 * NDioPads);
  localparam addr_t MioSleepRegwenBase    = MioSleepStatusBase + addr_t'(4 * NMioStatusRegs);
  localparam addr_t MioSleepEnBase        = MioSleepRegwenBase + addr_t'(4 * NMioPads);
  localparam addr_t MioSleepModeBase      = MioSleepEnBase + addr_t'(4 * NMioPads);
  localparam addr_t DioSleepStatusBase    = MioSleepModeBase + addr_t'(4 * NMioPads);
  localparam addr_t DioSleepRegwenBase    = DioSleepStatusBase + addr_t'(4 * NDioStatusRegs);
  localparam addr_t DioSleepEnBase        = DioSleepRegwenBase + addr_t'(4 * NDioPads);
  localparam addr_t DioSleepModeBase      = DioSleepEnBase + addr_t'(4 * NDioPads);
  localparam addr_t WkupRegwenBase        = DioSleepModeBase + addr_t'(4 * NDioPads);
  localparam addr_t WkupEnBase            = WkupRegwenBase + addr_t'(4 * NWkupDetect);
  localparam addr_t WkupDetectorBase      = WkupEnBase + addr_t'(4 * NWkupDetect);
  localparam addr_t WkupCntThBase         = WkupDetectorBase + addr_t'(4 * NWkupDetect);
  localparam addr_t WkupPadselBase        = WkupCntThBase + addr_t'(4 * NWkupDetect);
  localparam addr_t WkupCauseAddr         = WkupPadselBase + addr_t'(4 * NWkupDetect);

  // Offset of register i of a family whose register 0 is at base.
  function automatic addr_t reg_addr(addr_t base, int unsigned i);
    return base + addr_t'(4 * i);
  endfunction

  // Field positions the checks decode from write data ([REG] field tables).
  localparam int unsigned AlertTestFatalBit  = 0;   // ALERT_TEST.fatal_fault
  localparam int unsigned AlertTestRegwenBit = 31;  // ALERT_TEST.regwen
  localparam int unsigned DetectorModeLsb    = 0;   // WKUP_DETECTOR.MODE, bits 2:0
  localparam int unsigned DetectorFilterBit  = 3;   // WKUP_DETECTOR.FILTER
  localparam int unsigned DetectorMiodioBit  = 4;   // WKUP_DETECTOR.MIODIO

endpackage : pinmux_fpv_regmap_pkg
/* verilator lint_on UNUSEDPARAM */
