// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Checker for one register lock (a *_REGWEN register) and the registers it protects. Software
// locks by writing 0 to bit 0; a write of 1 has no effect (rw0c), so only a reset unlocks. The
// checker builds its own copy of the lock from the accepted writes, never reading the design's
// lock flop, so a lock wired to the wrong register shows as a protected value that changes while
// the copy says locked. It also checks that a write accepted while unlocked lands.
//
// value_i holds one or two protected registers side by side, the first at bit 0. CheckLanding is
// 0 for a register whose value another rule decides (the attribute registers legalise their
// writes). in_flight_i marks the cycles an always-on register's write may still land in.

// The resets are asynchronous in the flops and a disable condition in the properties.
/* verilator lint_off SYNCASYNCNET */
module regwen_chk #(
  parameter int unsigned           AddrW        = 12,
  parameter int unsigned           Width        = 1,
  parameter logic [AddrW-1:0]      RegwenAddr   = '0,
  parameter bit                    CheckLanding = 1'b1,
  parameter int unsigned           NumRegs      = 1,
  parameter logic [1:0][AddrW-1:0] RegAddr      = '0,
  parameter int unsigned           Reg0Width    = Width,
  parameter int unsigned           Reg1Width    = 0
) (
  input logic             clk_i,
  input logic             rst_ni,

  // An accepted write, in its answer cycle: offset, byte enables and data
  input logic             wr_done_i,
  input logic [AddrW-1:0] wr_addr_i,
  input logic [3:0]       wr_mask_i,
  input logic [31:0]      wr_data_i,

  // A read answered without an error, in its answer cycle
  input logic             rd_done_i,
  input logic [AddrW-1:0] rd_addr_i,
  input logic [31:0]      rd_data_i,

  // A write to a protected always-on register is still crossing to its clock domain
  input logic             in_flight_i,

  // The protected registers' values, as the pinmux logic reads them
  input logic [Width-1:0] value_i
);

  default clocking @(posedge clk_i); endclocking
  default disable iff (!rst_ni);

  /////////////////
  // Lock model  //
  /////////////////

  // A locking write: accepted, byte 0 enabled, bit 0 written 0. A write that leaves byte 0 out
  // writes no bit 0.
  logic lock_write, lock_read, locked_q;
  assign lock_write = wr_done_i && wr_addr_i == RegwenAddr && wr_mask_i[0] && !wr_data_i[0];
  assign lock_read  = rd_done_i && rd_addr_i == RegwenAddr;

  // The checker's copy of the lock: set by a locking write, cleared only by reset.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni)         locked_q <= 1'b0;
    else if (lock_write) locked_q <= 1'b1;
  end

  ////////////////
  // Properties //
  ////////////////

  // A read of the lock returns 1 until a write of 0 is accepted, then 0 until reset.
  // REQ_LOCK_01, 02, 03; regwen: reads lock state; [REG] *_REGWEN rw0c, resval 1
  assert_Regwen_ReadsLockState : assert property (lock_read |-> rd_data_i[0] == !locked_q);

  // While locked the protected registers do not change, save an earlier write still in flight.
  // REQ_LOCK_04; regwen: locked never changes; [REG] "not writable anymore"
  assert_Regwen_LockedNeverChanges : assert property (locked_q && !in_flight_i |=>
                                                      $stable(value_i));

  if (CheckLanding) begin : gen_landing
    // A write lands in its answer cycle: the register updates in the cycle after the request is
    // taken, which is the answer cycle under the register block's one-cycle answer contract.
    for (genvar k = 0; k < NumRegs; k++) begin : gen_reg
      // Register k's bits in value_i: register 0 from bit 0, register 1 just above it.
      localparam int unsigned Lsb = (k == 0) ? 0 : Reg0Width;
      localparam int unsigned W   = (k == 0) ? Reg0Width : Reg1Width;

      // An accepted write to register k, byte 0 enabled, while unlocked.
      logic lands;
      assign lands = wr_done_i && wr_addr_i == RegAddr[k] && wr_mask_i[0] && !locked_q;

      // A write accepted while unlocked becomes the register's value.
      // REQ_LOCK_05; regwen: unlocked write lands; [REG] *_REGWEN, [RG] hardware access
      assert_Regwen_UnlockedWriteLands : assert property (lands |->
                                                         value_i[Lsb +: W] == wr_data_i[W-1:0]);
    end
  end

  ////////////
  // Covers //
  ////////////

  // Software changes a protected register while unlocked.
  // REQ_LOCK_05; regwen: unlocked write
  cover_Regwen_UnlockedWrite : cover property ($changed(value_i) && !$past(locked_q));

  // Software reads a lock that is locked.
  // REQ_LOCK_02; regwen: read locked
  cover_Regwen_ReadLocked : cover property (lock_read && locked_q);

  // Software reads a lock that is still open.
  // REQ_LOCK_01; regwen: read before any write of 0
  cover_Regwen_ReadUnlocked : cover property (lock_read && !locked_q);

endmodule : regwen_chk
