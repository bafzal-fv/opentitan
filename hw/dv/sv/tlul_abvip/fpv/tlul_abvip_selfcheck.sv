// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// The ABVIP's own check, on one free TL-UL link with no design behind it: one instance per role
// watches the same link, so every rule one instance assumes another one asserts. A rule that
// contradicts itself, or forbids all traffic, shows up here before the ABVIP goes onto a design
// port. The covers show that long legal traces exist; the lane-row checks pin the request rules
// to the byte-lane examples of README.md and to the protocol checker's sizeMatchesMask. Its own
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
  // The ABVIP's parameters, passed unchanged to all three instances
  parameter int unsigned SrcW                 = 2,
  parameter int unsigned MaxOutstanding       = 2 ** SrcW,
  parameter bit          DeviceSameCycleRsp   = 1'b1,
  parameter int unsigned DeviceMaxOutstanding = MaxOutstanding,
  parameter int unsigned DeviceRspBound       = 0,
  parameter bit          DeviceInOrderRsp     = 1'b0,
  parameter bit          DeviceRspHeld        = 1'b0,
  parameter bit          HostReqHeld          = 1'b0,
  parameter bit          Liveness             = 1'b0,

  // The width of the outstanding count u_host exports
  localparam int unsigned CntW                = $clog2(MaxOutstanding + 1)
) (
  // Clock and reset
  input logic    clk_i,
  input logic    rst_ni,

  // The link: free inputs, watched by all three instances
  input tl_h2d_t h2d_i,
  input tl_d2h_t d2h_i
);

  // The link's widths from top_pkg: bytes in a data word, the size field, and the address offset
  // within a word.
  localparam int unsigned BusBytes = top_pkg::TL_DBW;
  localparam int unsigned SizeW    = top_pkg::TL_SZW;
  localparam int unsigned OffsetW  = $clog2(BusBytes);

  // The lane rows below are written for a 32-bit data bus: four byte lanes.
  if (BusBytes != 4) begin : gen_bad_bus_bytes
    $error("tlul_abvip_selfcheck: the lane rows need TL_DBW = 4");
  end

  default clocking @(posedge clk_i); endclocking
  /* verilator lint_off SYNCASYNCNET */
  default disable iff (!rst_ni);
  /* verilator lint_on SYNCASYNCNET */

  /////////////////////////////////
  // Three ABVIPs on one link    //
  /////////////////////////////////

  // The spec events u_host exports: a request taken, an answer taken, and the count of
  // outstanding requests.
  logic            a_fire;
  logic            d_fire;
  logic [CntW-1:0] outstanding_cnt;

  // Plays the host: assumes the host's rules, so the tool presents only legal requests, and
  // asserts the device's.
  /* verilator lint_off PINCONNECTEMPTY */
  tlul_abvip #(
    .Role                (PlayHost),
    .SrcW                (SrcW),
    .MaxOutstanding      (MaxOutstanding),
    .DeviceSameCycleRsp  (DeviceSameCycleRsp),
    .DeviceMaxOutstanding(DeviceMaxOutstanding),
    .DeviceRspBound      (DeviceRspBound),
    .DeviceInOrderRsp    (DeviceInOrderRsp),
    .DeviceRspHeld       (DeviceRspHeld),
    .HostReqHeld         (HostReqHeld),
    .Liveness            (Liveness)
  ) u_host (
    .clk_i,
    .rst_ni,
    .h2d_i,
    .d2h_i,
    .a_fire_o         (a_fire),
    .d_fire_o         (d_fire),
    .outstanding_cnt_o(outstanding_cnt),
    .oldest_src_o     ()
  );

  // Plays the device: assumes the device's rules, so the tool gives only legal answers, and
  // asserts the host's. Its spec events equal u_host's; nothing reads them.
  tlul_abvip #(
    .Role                (PlayDevice),
    .SrcW                (SrcW),
    .MaxOutstanding      (MaxOutstanding),
    .DeviceSameCycleRsp  (DeviceSameCycleRsp),
    .DeviceMaxOutstanding(DeviceMaxOutstanding),
    .DeviceRspBound      (DeviceRspBound),
    .DeviceInOrderRsp    (DeviceInOrderRsp),
    .DeviceRspHeld       (DeviceRspHeld),
    .HostReqHeld         (HostReqHeld),
    .Liveness            (Liveness)
  ) u_device (
    .clk_i,
    .rst_ni,
    .h2d_i,
    .d2h_i,
    .a_fire_o         (),
    .d_fire_o         (),
    .outstanding_cnt_o(),
    .oldest_src_o     ()
  );

  // Asserts every rule on the same link: each one is assumed by u_host or u_device.
  tlul_abvip #(
    .Role                (CheckBoth),
    .SrcW                (SrcW),
    .MaxOutstanding      (MaxOutstanding),
    .DeviceSameCycleRsp  (DeviceSameCycleRsp),
    .DeviceMaxOutstanding(DeviceMaxOutstanding),
    .DeviceRspBound      (DeviceRspBound),
    .DeviceInOrderRsp    (DeviceInOrderRsp),
    .DeviceRspHeld       (DeviceRspHeld),
    .HostReqHeld         (HostReqHeld),
    .Liveness            (Liveness)
  ) u_check (
    .clk_i,
    .rst_ni,
    .h2d_i,
    .d2h_i,
    .a_fire_o         (),
    .d_fire_o         (),
    .outstanding_cnt_o(),
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
  localparam int unsigned DrainCycles = DeviceMaxOutstanding;

  // Answers taken so far, saturating at RspGoal.
  logic [RspCntW-1:0] rsp_cnt_q;
  logic [RspCntW-1:0] rsp_cnt_d;
  logic               rsp_goal_met;
  assign rsp_goal_met = (rsp_cnt_q == RspCntW'(RspGoal));
  assign rsp_cnt_d    = (d_fire && !rsp_goal_met) ? rsp_cnt_q + 1'b1 : rsp_cnt_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin : proc_rsp_cnt
    if (!rst_ni) rsp_cnt_q <= '0;
    else         rsp_cnt_q <= rsp_cnt_d;
  end

  // A request and an answer taken in the same cycle.
  logic streaming;
  assign streaming = a_fire && d_fire;

  // The list of outstanding requests at the device's limit, or empty.
  logic list_full;
  logic list_empty;
  assign list_full  = (outstanding_cnt == CntW'(DeviceMaxOutstanding));
  assign list_empty = (outstanding_cnt == '0);

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
    logic                valid;
    tl_a_op_e            opcode;
    logic [OffsetW-1:0]  offset;
    logic [SizeW-1:0]    size;
    logic [BusBytes-1:0] mask;
  } row_t;

  row_t a_row;
  assign a_row = '{valid:  h2d_i.a_valid,
                   opcode: h2d_i.a_opcode,
                   offset: h2d_i.a_address[OffsetW-1:0],
                   size:   h2d_i.a_size,
                   mask:   h2d_i.a_mask};

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
  logic row_get_part_mask;
  logic row_get_no_mask;
  logic row_bad_opcode;
  logic row_get_size3;
  logic row_unaligned;
  logic row_mask_outside;
  logic row_full_missing;
  logic row_get_gap;
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
  logic a_full_mask_kind;
  logic mask_count_right;
  assign a_full_mask_kind = h2d_i.a_valid &&
                            ((h2d_i.a_opcode == Get) || (h2d_i.a_opcode == PutFullData));
  assign mask_count_right = ($countones(h2d_i.a_mask) == (32'd1 << h2d_i.a_size));

  assert_Self_SizeMatchesMask : assert property (a_full_mask_kind |-> mask_count_right);

endmodule
