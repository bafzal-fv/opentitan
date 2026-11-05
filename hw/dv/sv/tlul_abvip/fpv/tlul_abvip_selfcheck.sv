// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// The ABVIP's own check, on one free TL-UL link with no design behind it: one instance per role
// watches the same link, so every rule one instance assumes another one asserts. A rule that
// contradicts itself, or forbids all traffic, shows up here before the ABVIP goes onto a design
// port. The covers show that long legal traces exist; the lane-row checks pin the request rules
// to the byte-lane table in the uarch and to the protocol checker's sizeMatchesMask. Its own
// properties are named cover_Self_<Name> and assert_Self_<Name>; x_d is the next value of x_q.
module tlul_abvip_selfcheck
  import tlul_abvip_pkg::*;
  import tlul_pkg::tl_h2d_t;
  import tlul_pkg::tl_d2h_t;
  import tlul_pkg::tl_a_op_e;
  import tlul_pkg::Get;
  import tlul_pkg::PutFullData;
  import tlul_pkg::PutPartialData;
#(
  parameter int unsigned SrcW              = 2,
  parameter int unsigned MaxOutstanding    = 2 ** SrcW,
  parameter bit          DevSameCycleRsp   = 1'b1,
  parameter int unsigned DevMaxOutstanding = MaxOutstanding,
  parameter int unsigned DevRspBound       = 0,
  parameter bit          DevInOrderRsp     = 1'b0,
  parameter bit          DevRspHeld        = 1'b0,
  parameter bit          HostReqHeld       = 1'b0,
  parameter bit          Liveness          = 1'b0,
  localparam int unsigned CntW             = $clog2(MaxOutstanding + 1)
) (
  // Clock and reset
  input logic    clk_i,
  input logic    rst_ni,

  // The link: free inputs, watched by all three instances
  input tl_h2d_t h2d_i,
  input tl_d2h_t d2h_i
);

  localparam int unsigned DBW = top_pkg::TL_DBW;
  localparam int unsigned SZW = top_pkg::TL_SZW;
  localparam int unsigned OffW = $clog2(DBW);

  // The lane rows below are the uarch's 32-bit table: four byte lanes.
  if (DBW != 4) begin : gen_bad_dbw
    $error("tlul_abvip_selfcheck: the lane rows need TL_DBW = 4");
  end

  default clocking @(posedge clk_i); endclocking
  /* verilator lint_off SYNCASYNCNET */
  default disable iff (!rst_ni);
  /* verilator lint_on SYNCASYNCNET */

  /////////////////////////////////
  // Three ABVIPs on one link    //
  /////////////////////////////////

  logic            a_fire, d_fire;
  logic [CntW-1:0] num_outstanding;

  /* verilator lint_off PINCONNECTEMPTY */
  tlul_abvip #(
    .Role             (PlayHost),
    .SrcW             (SrcW),
    .MaxOutstanding   (MaxOutstanding),
    .DevSameCycleRsp  (DevSameCycleRsp),
    .DevMaxOutstanding(DevMaxOutstanding),
    .DevRspBound      (DevRspBound),
    .DevInOrderRsp    (DevInOrderRsp),
    .DevRspHeld       (DevRspHeld),
    .HostReqHeld      (HostReqHeld),
    .Liveness         (Liveness)
  ) u_host (
    .clk_i,
    .rst_ni,
    .h2d_i,
    .d2h_i,
    .a_fire_o         (a_fire),
    .d_fire_o         (d_fire),
    .num_outstanding_o(num_outstanding),
    .oldest_src_o     ()
  );

  // Its spec events equal u_host's; nothing reads them.
  tlul_abvip #(
    .Role             (PlayDevice),
    .SrcW             (SrcW),
    .MaxOutstanding   (MaxOutstanding),
    .DevSameCycleRsp  (DevSameCycleRsp),
    .DevMaxOutstanding(DevMaxOutstanding),
    .DevRspBound      (DevRspBound),
    .DevInOrderRsp    (DevInOrderRsp),
    .DevRspHeld       (DevRspHeld),
    .HostReqHeld      (HostReqHeld),
    .Liveness         (Liveness)
  ) u_device (
    .clk_i,
    .rst_ni,
    .h2d_i,
    .d2h_i,
    .a_fire_o         (),
    .d_fire_o         (),
    .num_outstanding_o(),
    .oldest_src_o     ()
  );

  // Asserts every rule on the same link: each one is assumed by u_host or u_device.
  tlul_abvip #(
    .Role             (CheckBoth),
    .SrcW             (SrcW),
    .MaxOutstanding   (MaxOutstanding),
    .DevSameCycleRsp  (DevSameCycleRsp),
    .DevMaxOutstanding(DevMaxOutstanding),
    .DevRspBound      (DevRspBound),
    .DevInOrderRsp    (DevInOrderRsp),
    .DevRspHeld       (DevRspHeld),
    .HostReqHeld      (HostReqHeld),
    .Liveness         (Liveness)
  ) u_check (
    .clk_i,
    .rst_ni,
    .h2d_i,
    .d2h_i,
    .a_fire_o         (),
    .d_fire_o         (),
    .num_outstanding_o(),
    .oldest_src_o     ()
  );
  /* verilator lint_on PINCONNECTEMPTY */

  /////////////////////////////////
  // Witness covers: long traces //
  /////////////////////////////////

  // The longest witness: this many answers taken.
  localparam int unsigned RspGoal = 8;
  localparam int unsigned RspCntW = $clog2(RspGoal + 1);

  // A list full to the device's limit drains in that many cycles, one answer per cycle.
  localparam int unsigned DrainCycles = DevMaxOutstanding;

  // Answers taken so far, saturating at RspGoal.
  logic [RspCntW-1:0] num_rsp_q, num_rsp_d;
  logic               rsp_goal_met;
  assign rsp_goal_met = (num_rsp_q == RspCntW'(RspGoal));
  assign num_rsp_d    = (d_fire && !rsp_goal_met) ? num_rsp_q + 1'b1 : num_rsp_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) num_rsp_q <= '0;
    else         num_rsp_q <= num_rsp_d;
  end

  logic streaming, list_full, list_empty;
  assign streaming  = a_fire && d_fire;
  assign list_full  = (num_outstanding == CntW'(DevMaxOutstanding));
  assign list_empty = (num_outstanding == '0);

  // RspGoal answers taken: the rules together allow long legal traces.
  cover_Self_EightRsp   : cover property (rsp_goal_met);

  // Four requests accepted in four cycles in a row.
  cover_Self_BackToBack : cover property (a_fire ##1 a_fire ##1 a_fire ##1 a_fire);

  // A request and an answer in every cycle, four cycles in a row.
  cover_Self_Streaming  : cover property (streaming ##1 streaming ##1 streaming ##1 streaming);

  // The list fills to the device's limit, then drains to empty.
  cover_Self_FillDrain  : cover property (list_full ##[1:DrainCycles] list_empty);

  ///////////////////////////////////////////////////
  // Lane rows: the byte-lane table, under u_host  //
  ///////////////////////////////////////////////////

  // The request presented, as a row of the table: opcode, address offset, size, mask.
  typedef struct packed {
    logic            valid;
    tl_a_op_e        opcode;
    logic [OffW-1:0] offset;
    logic [SZW-1:0]  size;
    logic [DBW-1:0]  mask;
  } row_t;

  row_t a_row;
  assign a_row = '{valid: h2d_i.a_valid, opcode: h2d_i.a_opcode, offset: h2d_i.a_address[OffW-1:0],
                   size: h2d_i.a_size, mask: h2d_i.a_mask};

  // Legal rows: u_host's assumptions let the tool present each one.
  cover_Self_RowGetWord     : cover property (a_row == row_t'{1'b1, Get, 2'd0, 2'd2, 4'b1111});
  cover_Self_RowPartialByte : cover property (a_row == row_t'{1'b1, PutPartialData, 2'd1, 2'd0,
                                                               4'b0010});
  cover_Self_RowPartialHalf : cover property (a_row == row_t'{1'b1, PutPartialData, 2'd2, 2'd1,
                                                               4'b1100});
  cover_Self_RowPartialGap  : cover property (a_row == row_t'{1'b1, PutPartialData, 2'd0, 2'd2,
                                                               4'b1001});
  cover_Self_RowFullByte    : cover property (a_row == row_t'{1'b1, PutFullData, 2'd3, 2'd0,
                                                               4'b1000});

  // Illegal rows: u_host's assumptions never let the tool present one.
  logic row_get_part_mask, row_get_no_mask, row_bad_opcode, row_get_size3;
  logic row_unaligned, row_mask_outside, row_full_missing, row_get_gap;
  assign row_get_part_mask = (a_row == row_t'{1'b1, Get, 2'd2, 2'd1, 4'b0100});
  assign row_get_no_mask   = (a_row == row_t'{1'b1, Get, 2'd0, 2'd2, 4'b0000});
  assign row_bad_opcode    = (a_row == row_t'{1'b1, tl_a_op_e'(3'h2), 2'd0, 2'd2, 4'b1111});
  assign row_get_size3     = (a_row == row_t'{1'b1, Get, 2'd0, 2'd3, 4'b1111});
  assign row_unaligned     = (a_row == row_t'{1'b1, PutPartialData, 2'd1, 2'd1, 4'b0110});
  assign row_mask_outside  = (a_row == row_t'{1'b1, PutPartialData, 2'd2, 2'd0, 4'b0001});
  assign row_full_missing  = (a_row == row_t'{1'b1, PutFullData, 2'd0, 2'd2, 4'b0111});
  assign row_get_gap       = (a_row == row_t'{1'b1, Get, 2'd0, 2'd2, 4'b0101});

  assert_Self_RowGetPartMask : assert property (!row_get_part_mask);
  assert_Self_RowGetNoMask   : assert property (!row_get_no_mask);
  assert_Self_RowBadOpcode   : assert property (!row_bad_opcode);
  assert_Self_RowGetSize3    : assert property (!row_get_size3);
  assert_Self_RowUnaligned   : assert property (!row_unaligned);
  assert_Self_RowMaskOutside : assert property (!row_mask_outside);
  assert_Self_RowFullMissing : assert property (!row_full_missing);
  assert_Self_RowGetGap      : assert property (!row_get_gap);

  // [TLPC] sizeMatchesMask, written apart from the ABVIP's lanes: 2^a_size marked lanes.
  logic a_full_mask_kind, mask_count_right;
  assign a_full_mask_kind = h2d_i.a_valid &&
                            ((h2d_i.a_opcode == Get) || (h2d_i.a_opcode == PutFullData));
  assign mask_count_right = ($countones(h2d_i.a_mask) == (32'd1 << h2d_i.a_size));

  assert_Self_SizeMatchesMask : assert property (a_full_mask_kind |-> mask_count_right);

endmodule
