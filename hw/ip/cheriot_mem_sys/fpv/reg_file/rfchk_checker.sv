// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// The register-file unit: proves that the register file's outputs to the engine follow the
// register-file model the other checkers rely on (contract C20), and checks the register rows the
// generic CSR tests cannot reach: the lock, the start strobe, the interrupt state, the read side
// and the request rate. It runs on the real register file with everything else cut, so the
// hardware side (hw2reg) is free. Its one rule is a TL-UL ABVIP playing the host on regs_tl_d;
// nothing is assumed on the hardware side. Register offsets and fields come from
// cheriot_mem_sys_reg_pkg, generated from the register hjson.
//
// reg2hw_i is the register file's side towards the hardware, hw2reg_i the side from it; x_d is
// the next value of x_q.
`include "cheriot_mem_sys_fpv_rule.svh"

module rfchk_checker
  import tlul_pkg::*;
  import tlul_abvip_pkg::*;
  import cheriot_mem_sys_reg_pkg::*;
(
  input  logic                          clk_i,
  input  logic                          rst_ni,

  // regs_tl_d
  input  tl_h2d_t                       regs_h2d_i,
  input  tl_d2h_t                       regs_d2h_i,

  // The register file's two sides
  input  cheriot_mem_sys_regs_reg2hw_t  reg2hw_i,
  input  cheriot_mem_sys_regs_hw2reg_t  hw2reg_i
);

  // [REGS] TBRE_STATUS: busy bit 0, start_err bit 8, sweep_err bit 9. TBRE_BASE_ADDR bits 31:3.
  localparam int unsigned BusyBit     = 0;
  localparam int unsigned StartErrBit = 8;
  localparam int unsigned SweepErrBit = 9;

  default clocking @(posedge clk_i); endclocking
  /* verilator lint_off SYNCASYNCNET */
  default disable iff (!rst_ni);
  /* verilator lint_on SYNCASYNCNET */

  /////////////////
  // Port events //
  /////////////////

  logic req_fire, rsp_fire, wr_req, rd_req;
  assign req_fire = regs_h2d_i.a_valid && regs_d2h_i.a_ready;
  assign rsp_fire = regs_d2h_i.d_valid && regs_h2d_i.d_ready;
  assign wr_req   = req_fire && (regs_h2d_i.a_opcode inside {PutFullData, PutPartialData});
  assign rd_req   = req_fire && (regs_h2d_i.a_opcode == Get);

  ////////////
  // Decode //
  ////////////

  // The register a request names: its offset in the register window ([REGS]).
  logic [RegsAw-1:0] off;
  assign off = regs_h2d_i.a_address[RegsAw-1:0];

  // A request the register file answers without error: a whole aligned word with valid command
  // integrity, and valid data integrity on a write ([TLUL] Usage of User Bits; [REGS]: a register
  // write must cover the field). Any other request may be answered with d_error, and the checks
  // below claim nothing for its data.
  logic word_req, intg_ok, good_rd, good_wr;
  assign word_req = (regs_h2d_i.a_size == top_pkg::TL_SZW'(2)) &&
                    (regs_h2d_i.a_address[1:0] == 2'b00) && (&regs_h2d_i.a_mask);
  assign intg_ok  = (regs_h2d_i.a_user.cmd_intg == get_cmd_intg(regs_h2d_i)) &&
                    (regs_h2d_i.a_user.data_intg == get_data_intg(regs_h2d_i.a_data));
  assign good_rd  = rd_req && word_req && intg_ok;
  assign good_wr  = wr_req && word_req && intg_ok;

  logic wr_base, wr_num, wr_start, wr_intr_state, wr_status;
  assign wr_base       = wr_req && (off == CHERIOT_MEM_SYS_TBRE_BASE_ADDR_OFFSET);
  assign wr_num        = wr_req && (off == CHERIOT_MEM_SYS_TBRE_NUM_CAPS_OFFSET);
  assign wr_start      = wr_req && (off == CHERIOT_MEM_SYS_TBRE_START_OFFSET);
  assign wr_intr_state = wr_req && (off == CHERIOT_MEM_SYS_INTR_STATE_OFFSET);
  assign wr_status     = wr_req && (off == CHERIOT_MEM_SYS_TBRE_STATUS_OFFSET);

  // TBRE_REGWEN as software reads it: the value the hardware presents ([REGS] ro, "Low while the
  // revocation engine is active").
  logic regwen;
  assign regwen = hw2reg_i.tbre_regwen.d;

  // The interrupt logic's set request, and software's write of 1 to INTR_STATE.tbre_done (rw1c).
  logic intr_set, intr_w1c;
  assign intr_set = hw2reg_i.intr_state.de && hw2reg_i.intr_state.d;
  assign intr_w1c = wr_intr_state && regs_h2d_i.a_data[0];

  // The hardware's set of a sticky error in the cycle software writes 1 to clear it. The spec does
  // not say which wins; raised with the designers.
  logic start_err_collision, sweep_err_collision;
  assign start_err_collision = hw2reg_i.tbre_status.start_err.de && hw2reg_i.tbre_status.start_err.d
                               && wr_status && regs_h2d_i.a_data[StartErrBit];
  assign sweep_err_collision = hw2reg_i.tbre_status.sweep_err.de && hw2reg_i.tbre_status.sweep_err.d
                               && wr_status && regs_h2d_i.a_data[SweepErrBit];

  /////////////////////////////////////////////////////////
  // Model: what a read of each checked register returns //
  /////////////////////////////////////////////////////////

  // TBRE_STATUS.busy holds what the engine last wrote ([REGS] hwo): the register file's flop of
  // the hardware's write, so the value a read taken in cycle t returns is the write of cycle t-1.
  logic busy_d, busy_q;
  assign busy_d = hw2reg_i.tbre_status.busy.de ? hw2reg_i.tbre_status.busy.d : busy_q;

  // The answer to a good read: expected data under a mask of the bits the model knows. At most one
  // request is outstanding on the port (REQ_REG_02), so the next answer taken is this read's.
  logic                      rd_pending_d, rd_pending_q;
  logic [top_pkg::TL_DW-1:0] exp_data_d, exp_data_q, exp_mask_d, exp_mask_q;
  always_comb begin
    rd_pending_d = rd_pending_q;
    exp_data_d   = exp_data_q;
    exp_mask_d   = exp_mask_q;
    if (good_rd) begin
      rd_pending_d = 1'b1;
      exp_data_d   = '0;
      exp_mask_d   = '0;
      case (off)
        CHERIOT_MEM_SYS_TBRE_BASE_ADDR_OFFSET: begin  // bits 2:0 read as zero (REQ_TBRE_06)
          exp_data_d = {reg2hw_i.tbre_base_addr.q, 3'b000};
          exp_mask_d = '1;
        end
        CHERIOT_MEM_SYS_TBRE_NUM_CAPS_OFFSET: begin
          exp_data_d = {1'b0, reg2hw_i.tbre_num_caps.q};
          exp_mask_d = '1;
        end
        CHERIOT_MEM_SYS_TBRE_REGWEN_OFFSET: begin
          exp_data_d = {31'b0, regwen};
          exp_mask_d = '1;
        end
        CHERIOT_MEM_SYS_TBRE_STATUS_OFFSET: begin     // busy only: the sticky bits' set-or-clear
                                                      // collision is open with the designers
          exp_data_d[BusyBit] = busy_q;
          exp_mask_d[BusyBit] = 1'b1;
        end
        default: rd_pending_d = 1'b0;
      endcase
    end else if (rsp_fire) begin
      rd_pending_d = 1'b0;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      busy_q       <= 1'b0;
      rd_pending_q <= 1'b0;
      exp_data_q   <= '0;
      exp_mask_q   <= '0;
    end else begin
      busy_q       <= busy_d;
      rd_pending_q <= rd_pending_d;
      exp_data_q   <= exp_data_d;
      exp_mask_q   <= exp_mask_d;
    end
  end

  ///////////////////////////////////////////////////
  // csr: the lock, TBRE_REGWEN (REQ_TBRE_05, C20) //
  ///////////////////////////////////////////////////

  // The two sweep registers do not change in a cycle after one with TBRE_REGWEN 0.
  // REQ_TBRE_05; contract C20; csr locked base stable
  assert_RegFile_LockedBaseStable : assert property (
    !regwen |=> $stable(reg2hw_i.tbre_base_addr.q));

  // csr locked num stable
  assert_RegFile_LockedNumStable : assert property (
    !regwen |=> $stable(reg2hw_i.tbre_num_caps.q));

  // A write to TBRE_START while locked gives no strobe, now or next cycle (the port takes a
  // request at most every other cycle, so the next cycle holds no other write). The cycle after
  // is counted in a flop: Verilator cannot lint ## inside an implication.
  // REQ_TBRE_05; csr locked start no strobe
  logic locked_start_wr_q;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) locked_start_wr_q <= 1'b0;
    else         locked_start_wr_q <= wr_start && !regwen;
  end
  assert_RegFile_LockedStartNoStrobe : assert property (
    (wr_start && !regwen) || locked_start_wr_q |-> !reg2hw_i.tbre_start.qe);

  /////////////////////////////////
  // csr: the start strobe (C20) //
  /////////////////////////////////

  // A strobe comes only from a write to TBRE_START while unlocked (backward).
  // contract C20; csr start strobe only unlocked
  assert_RegFile_StartStrobeOnlyUnlocked : assert property (
    reg2hw_i.tbre_start.qe |-> regwen && wr_start);

  // A good write to TBRE_START while unlocked strobes, with the bit written (forward).
  // contract C20; csr start strobe on write
  assert_RegFile_StartStrobeOnWrite : assert property (
    good_wr && wr_start && regwen |->
      reg2hw_i.tbre_start.qe && (reg2hw_i.tbre_start.q == regs_h2d_i.a_data[0]));

  //////////////////////////////////////////////////////////////////////
  // csr: the sweep registers keep what software wrote (REQ_TBRE_06) //
  //////////////////////////////////////////////////////////////////////

  // A good write while unlocked lands the cycle after (forward).
  // REQ_TBRE_06; csr base written
  assert_RegFile_BaseWritten : assert property (
    good_wr && wr_base && regwen |=>
      reg2hw_i.tbre_base_addr.q == $past(regs_h2d_i.a_data[31:3]));

  // csr num written
  assert_RegFile_NumWritten : assert property (
    good_wr && wr_num && regwen |=>
      reg2hw_i.tbre_num_caps.q == $past(regs_h2d_i.a_data[30:0]));

  // A change comes only from a write to that register while unlocked (backward).
  // REQ_TBRE_06; csr base changes only by write
  assert_RegFile_BaseChangesOnlyByWrite : assert property (
    !$stable(reg2hw_i.tbre_base_addr.q) |-> $past(wr_base && regwen));

  // csr num changes only by write
  assert_RegFile_NumChangesOnlyByWrite : assert property (
    !$stable(reg2hw_i.tbre_num_caps.q) |-> $past(wr_num && regwen));

  //////////////////////////////////////////////////
  // csr: INTR_STATE.tbre_done (REQ_TBRE_29, C20) //
  //////////////////////////////////////////////////

  // The state rises only in the cycle after a set request (backward).
  // contract C20; csr intr set by set request
  assert_RegFile_IntrSetBySetReq : assert property (
    $rose(reg2hw_i.intr_state.q) |-> $past(intr_set));

  // A set request with no clear in its cycle sets the state (forward).
  // contract C20; csr intr set takes
  assert_RegFile_IntrSetTakes : assert property (
    intr_set && !intr_w1c |=> reg2hw_i.intr_state.q);

  // The state stays set until software writes 1 to it.
  // REQ_TBRE_29; csr intr stays set
  assert_RegFile_IntrStaysSet : assert property (
    reg2hw_i.intr_state.q && !intr_w1c |=> reg2hw_i.intr_state.q);

  // A write of 1 in the cycle of a set request leaves it clear: the clear wins.
  // REQ_TBRE_29; csr intr clear wins
  assert_RegFile_IntrClearWins : assert property (
    good_wr && intr_w1c && intr_set |=> !reg2hw_i.intr_state.q);

  ///////////////////////////////////////////
  // csr: the read side (REQ_TBRE_06, C20) //
  ///////////////////////////////////////////

  // A good read of a checked register is answered without error, with the register's value:
  // TBRE_BASE_ADDR with bits 2:0 zero, TBRE_NUM_CAPS, TBRE_REGWEN, and TBRE_STATUS.busy holding
  // what the engine last wrote.
  // REQ_TBRE_06; contract C20; csr read returns register
  assert_RegFile_ReadReturnsRegister : assert property (
    rsp_fire && rd_pending_q |->
      !regs_d2h_i.d_error && ((regs_d2h_i.d_data & exp_mask_q) == (exp_data_q & exp_mask_q)));

  ////////////////////////////////////////
  // csr: the request rate (REQ_REG_02) //
  ////////////////////////////////////////

  // The register interface takes a request at most every other cycle.
  // REQ_REG_02; csr request every other cycle
  assert_RegFile_ReqEveryOtherCycle : assert property (
    req_fire |=> !req_fire);

  ////////////
  // Covers //
  ////////////

  // csr write while locked: a good write to each sweep register while TBRE_REGWEN is 0
  cover_RegFile_BaseWriteLocked   : cover property (good_wr && wr_base && !regwen);
  cover_RegFile_NumWriteLocked    : cover property (good_wr && wr_num && !regwen);
  cover_RegFile_StartWriteLocked  : cover property (good_wr && wr_start && !regwen);

  // csr write while unlocked
  cover_RegFile_BaseWriteUnlocked : cover property (good_wr && wr_base && regwen);
  cover_RegFile_NumWriteUnlocked  : cover property (good_wr && wr_num && regwen);
  cover_RegFile_StartTaken        : cover property (good_wr && wr_start && regwen &&
                                                    regs_h2d_i.a_data[0]);

  // csr lock seen: TBRE_REGWEN low (it resets high), then high again
  cover_RegFile_Locked            : cover property ($rose(regwen));

  // csr set and clear in one cycle: INTR_STATE
  cover_RegFile_IntrSetAndClear   : cover property (good_wr && intr_w1c && intr_set);

  // csr status read: a good read of TBRE_STATUS answered with busy set
  cover_RegFile_StatusReadBusy    : cover property (
    rsp_fire && rd_pending_q && exp_mask_q[BusyBit] && regs_d2h_i.d_data[BusyBit]);

  // csr sticky error set and cleared in one cycle: reachable; which wins is open with the designers
  cover_RegFile_StartErrSetAndClear : cover property (good_wr && start_err_collision);
  cover_RegFile_SweepErrSetAndClear : cover property (good_wr && sweep_err_collision);

  /////////////////////////////////////////////////////////////////
  // Rules: what the host on regs_tl_d sends (TL-UL ABVIP, host) //
  /////////////////////////////////////////////////////////////////

  // In FPV the ABVIP plays the host (assumes its rules, asserts the register file's); in
  // simulation the real host drives the port, so the ABVIP checks both ends. No other rule: the
  // hardware side (hw2reg) stays free, so contract C20 holds for every engine behaviour.
`ifdef FPV_ON
  localparam role_e HostRole = PlayHost;
`else
  localparam role_e HostRole = CheckBoth;
`endif
  /* verilator lint_off PINCONNECTEMPTY */
  tlul_abvip #(.Role(HostRole)) u_abvip_regs (
    .clk_i, .rst_ni, .h2d_i(regs_h2d_i), .d2h_i(regs_d2h_i),
    .a_fire_o(), .d_fire_o(), .num_outstanding_o(), .oldest_src_o());
  /* verilator lint_on PINCONNECTEMPTY */

endmodule
