// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// The TL-UL assertion-based VIP: the TileLink Uncached Lightweight rules of one link, as
// OpenTitan uses it. Put one on a port and choose its Role: PlayHost assumes the host's rules
// and asserts the device's, PlayDevice the reverse, and CheckBoth asserts both ends, for a link
// between two real blocks. It decodes each request, keeps the list of outstanding requests and
// derives every rule from that list, so a rule reads the same way whichever end it is applied to.
//
// Spec tags in the comments: [TL] TileLink 1.9.3; [TLUL] hw/ip/tlul/README.md; [TLPC]
// hw/ip/tlul/doc/TlulProtocolChecker.md. In these comments a beat is "presented" in a cycle where
// its valid is high, whether or not ready is; a beat that stays valid and unchanged until it is
// accepted, which [TL] Section 5.1 calls presented, is "held" here. Properties are named
// <Feature>_<Name>; their labels add assume_, assert_ or cover_. x_d is the next value of x_q.
// README.md beside this file lists every rule with its source and says how to put the ABVIP on a
// port.
module tlul_abvip
  import tlul_abvip_pkg::*;
  import tlul_pkg::tl_h2d_t;
  import tlul_pkg::tl_d2h_t;
  import tlul_pkg::tl_d_op_e;
  import tlul_pkg::Get;
  import tlul_pkg::PutFullData;
  import tlul_pkg::PutPartialData;
  import tlul_pkg::AccessAck;
  import tlul_pkg::AccessAckData;
#(
  // Which end the ABVIP plays, the low source bits that name a request at this port, and how many
  // requests the port may have outstanding at once.
  parameter role_e       Role                 = PlayHost,
  parameter int unsigned SrcW                 = top_pkg::TL_AIW,
  parameter int unsigned MaxOutstanding       = 2 ** SrcW,

  // The device's contract. Each default is the spec's rule; a port that tightens one says why
  // where it sets it.
  parameter bit          DeviceSameCycleRsp   = 1'b1,  // 0: no answer in its request's cycle
  parameter int unsigned DeviceMaxOutstanding = MaxOutstanding,  // the device's own limit
  parameter int unsigned DeviceRspBound       = 0,  // >0: most cycles without an answer
  parameter bit          DeviceInOrderRsp     = 1'b0,  // 1: answers come back in request order
  parameter bit          DeviceRspHeld        = 1'b0,  // 1: an answer offered stays unchanged

  // The host's contract, on the same terms as the device's above.
  parameter bit          HostReqHeld          = 1'b0,  // 1: a request offered stays unchanged

  // 1 adds the [TL] forward progress rules (liveness), which only a formal tool reads.
  parameter bit          Liveness             = 1'b0,

  // Width of the outstanding count.
  localparam int unsigned CntW               = $clog2(MaxOutstanding + 1)
) (
  // Clock and reset
  input  logic            clk_i,
  input  logic            rst_ni,

  // The link: watched, never driven
  input  tl_h2d_t         h2d_i,
  input  tl_d2h_t         d2h_i,

  // Spec events, for the project's adapter and its own assumptions on top
  output logic            a_fire_o,
  output logic            d_fire_o,
  output logic [CntW-1:0] outstanding_cnt_o,
  output logic [SrcW-1:0] oldest_src_o
);

  // Interface widths, from top_pkg; the largest a_size covers the bus width ([TL] Section 7.2.1).
  localparam int unsigned AddrW     = top_pkg::TL_AW;
  localparam int unsigned BusBytes  = top_pkg::TL_DBW;
  localparam int unsigned SizeW     = top_pkg::TL_SZW;
  localparam int unsigned SrcFieldW = top_pkg::TL_AIW;
  localparam int unsigned OffsetW   = $clog2(BusBytes);
  localparam int unsigned MaxSize   = OffsetW;
  localparam int unsigned IdxW      = (MaxOutstanding > 1) ? $clog2(MaxOutstanding) : 1;

  // The largest answer bound: it keeps the age counter at 17 bits or fewer.
  localparam int unsigned MaxRspBound = 2 ** 16;

  if (SrcW < 1 || SrcW > SrcFieldW) begin : gen_bad_src_w
    $error("tlul_abvip: SrcW must be 1 to TL_AIW");
  end

  if (DeviceMaxOutstanding < 1 || DeviceMaxOutstanding > MaxOutstanding) begin : gen_bad_device_max
    $error("tlul_abvip: DeviceMaxOutstanding must be 1 to MaxOutstanding");
  end

  if (DeviceRspBound > MaxRspBound) begin : gen_bad_rsp_bound
    $error("tlul_abvip: DeviceRspBound must be 0 to 2**16");
  end

  if (MaxOutstanding < 1 || MaxOutstanding > 2 ** SrcW) begin : gen_bad_max_outstanding
    $error("tlul_abvip: MaxOutstanding must be 1 to 2**SrcW");
  end

  if (Role != PlayHost && Role != PlayDevice && Role != CheckBoth) begin : gen_bad_role
    $error("tlul_abvip: Role must be PlayHost, PlayDevice or CheckBoth");
  end

  default clocking @(posedge clk_i); endclocking
  /* verilator lint_off SYNCASYNCNET */
  default disable iff (!rst_ni);
  /* verilator lint_on SYNCASYNCNET */

  ////////////////
  // Handshakes //
  ////////////////

  // [TL] Section 4.1: "A beat is exchanged only when both ready and valid are HIGH."
  logic a_fire;
  logic d_fire;
  assign a_fire = h2d_i.a_valid && d2h_i.a_ready;
  assign d_fire = d2h_i.d_valid && h2d_i.d_ready;

  // A beat waits while its valid is high and the other end's ready is low.
  logic a_waits;
  logic d_waits;
  assign a_waits = h2d_i.a_valid && !d2h_i.a_ready;
  assign d_waits = d2h_i.d_valid && !h2d_i.d_ready;

  // Every field of the request and of the answer, without valid and ready: a beat that waits is
  // the same beat while these do not change.
  logic [$bits(tl_h2d_t)-3:0] a_fields;
  logic [$bits(tl_d2h_t)-3:0] d_fields;
  assign a_fields = {h2d_i.a_opcode, h2d_i.a_param, h2d_i.a_size, h2d_i.a_source,
                     h2d_i.a_address, h2d_i.a_mask, h2d_i.a_data, h2d_i.a_user};
  assign d_fields = {d2h_i.d_opcode, d2h_i.d_param, d2h_i.d_size, d2h_i.d_source,
                     d2h_i.d_sink, d2h_i.d_data, d2h_i.d_user, d2h_i.d_error};

  // [TL] Section 3.2.2: valid may go high only after the first rising edge where reset is low.
  logic past_first_edge_q;
  logic past_first_edge_d;
  logic at_first_edge;
  assign past_first_edge_d = 1'b1;
  assign at_first_edge     = !past_first_edge_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin : proc_first_edge
    if (!rst_ni) past_first_edge_q <= 1'b0;
    else         past_first_edge_q <= past_first_edge_d;
  end

  ////////////////////
  // Request decode //
  ////////////////////

  // [TL] Section 4.5: the active lanes are the 2^size bytes from the address offset.
  function automatic logic [BusBytes-1:0] active_lanes(logic [OffsetW-1:0] offset,
                                                       logic [SizeW-1:0]   size);
    int unsigned first, bytes;
    logic [BusBytes-1:0] lanes;
    first = 32'(offset);
    bytes = 32'd1 << size;
    for (int unsigned k = 0; k < BusBytes; k++) begin
      lanes[k] = (k >= first) && (k < first + bytes);
    end
    return lanes;
  endfunction

  // [TL] Section 4.5: (address & (2^size - 1)) = 0.
  function automatic logic is_aligned(logic [AddrW-1:0] address, logic [SizeW-1:0] size);
    logic [AddrW-1:0] low_bits;
    low_bits = (AddrW'(1'b1) << size) - AddrW'(1'b1);
    return (address & low_bits) == '0;
  endfunction

  // The set bits of a mask form one run.
  function automatic logic is_contiguous(logic [BusBytes-1:0] mask);
    int unsigned runs;
    logic lower_lane_set;
    runs = 0;
    lower_lane_set = 1'b0;
    for (int unsigned k = 0; k < BusBytes; k++) begin
      if (mask[k] && !lower_lane_set) runs++;
      lower_lane_set = mask[k];
    end
    return runs <= 1;
  endfunction

  // The request's opcode: one predicate per TL-UL request opcode.
  logic a_is_get;
  logic a_is_full;
  logic a_is_partial;
  assign a_is_get     = (h2d_i.a_opcode == Get);
  assign a_is_full    = (h2d_i.a_opcode == PutFullData);
  assign a_is_partial = (h2d_i.a_opcode == PutPartialData);

  // The request presented now: its active lanes and what the host rules and covers test of it.
  logic [BusBytes-1:0] a_lanes;
  logic                a_opcode_legal;
  logic                a_param_zero;
  logic                a_size_legal;
  logic                a_aligned;
  logic                a_mask_in_lanes;
  logic                a_needs_full_mask;
  logic                a_mask_full;
  logic                a_mask_contiguous;
  assign a_lanes           = active_lanes(h2d_i.a_address[OffsetW-1:0], h2d_i.a_size);
  assign a_opcode_legal    = a_is_get || a_is_full || a_is_partial;
  assign a_param_zero      = (h2d_i.a_param == '0);
  assign a_size_legal      = (h2d_i.a_size <= SizeW'(MaxSize));
  assign a_aligned         = is_aligned(h2d_i.a_address, h2d_i.a_size);
  assign a_mask_in_lanes   = ((h2d_i.a_mask & ~a_lanes) == '0);
  assign a_needs_full_mask = a_is_get || a_is_full;
  assign a_mask_full       = (h2d_i.a_mask == a_lanes);
  assign a_mask_contiguous = is_contiguous(h2d_i.a_mask);

  // [TLUL] Source ID requirements: the low SrcW bits identify a request at this port.
  logic [SrcW-1:0] a_src;
  logic [SrcW-1:0] d_src;
  assign a_src = h2d_i.a_source[SrcW-1:0];
  assign d_src = d2h_i.d_source[SrcW-1:0];

  //////////////////////
  // Outstanding list //
  //////////////////////

  // One outstanding request: what its answer must match ([TL] Section 7, Table 15; Section 7.2.4).
  typedef struct packed {
    logic [SrcW-1:0]    source;
    logic               is_get;
    logic [SizeW-1:0]   size;
    logic [OffsetW-1:0] offset;
  } req_t;

  req_t a_req;
  assign a_req = '{source: a_src, is_get: a_is_get, size: h2d_i.a_size,
                   offset: h2d_i.a_address[OffsetW-1:0]};

  // Set by the answer decode below: which entry the answer names, what leaves, what joins.
  logic [IdxW-1:0] d_idx;
  logic            rsp_leaves;
  logic            req_joins;

  // outstanding_q[0] is the oldest; entries at outstanding_cnt_q and above are zero.
  req_t [MaxOutstanding-1:0] outstanding_q;
  req_t [MaxOutstanding-1:0] outstanding_d;
  logic [CntW-1:0]           outstanding_cnt_q;
  logic [CntW-1:0]           outstanding_cnt_d;

  // Remove first (the entries above the answered one move down), then append at the tail.
  logic [CntW-1:0] kept_cnt;
  logic            full_after_leave;
  assign kept_cnt         = outstanding_cnt_q - CntW'(rsp_leaves);
  assign full_after_leave = (kept_cnt == CntW'(MaxOutstanding));

  for (genvar i = 0; i < MaxOutstanding; i++) begin : gen_list
    req_t kept;
    logic joins_here;
    logic kept_here;
    if (i == MaxOutstanding - 1) begin : gen_top
      assign kept = outstanding_q[i];
    end else begin : gen_below
      logic moves_down;
      assign moves_down = rsp_leaves && (IdxW'(i) >= d_idx);
      assign kept       = moves_down ? outstanding_q[i+1] : outstanding_q[i];
    end
    assign joins_here       = req_joins && (CntW'(i) == kept_cnt);
    assign kept_here        = (CntW'(i) < kept_cnt);
    assign outstanding_d[i] = joins_here ? a_req :
                              kept_here  ? kept  :
                                           '0;
  end
  assign outstanding_cnt_d = kept_cnt + CntW'(req_joins && !full_after_leave);

  always_ff @(posedge clk_i or negedge rst_ni) begin : proc_outstanding_list
    if (!rst_ni) begin
      outstanding_q     <= '0;
      outstanding_cnt_q <= '0;
    end else begin
      outstanding_q     <= outstanding_d;
      outstanding_cnt_q <= outstanding_cnt_d;
    end
  end

  // The list holds at least one request.
  logic any_outstanding;
  assign any_outstanding = (outstanding_cnt_q != '0);

  // Entry i is outstanding and has the answer's source (d_hit) or the request's (a_hit).
  logic [MaxOutstanding-1:0] d_hit;
  logic [MaxOutstanding-1:0] a_hit;
  for (genvar i = 0; i < MaxOutstanding; i++) begin : gen_hit
    logic in_use;
    assign in_use   = (CntW'(i) < outstanding_cnt_q);
    assign d_hit[i] = in_use && (outstanding_q[i].source == d_src);
    assign a_hit[i] = in_use && (outstanding_q[i].source == a_src);
  end

  // The oldest entry with the answer's source.
  function automatic logic [IdxW-1:0] oldest_hit(logic [MaxOutstanding-1:0] hit);
    logic [IdxW-1:0] idx;
    idx = '0;
    for (int i = MaxOutstanding - 1; i >= 0; i--) begin
      if (hit[i]) idx = IdxW'(i);
    end
    return idx;
  endfunction

  ///////////////////
  // Answer decode //
  ///////////////////

  // [TL] Section 4.2: an answer names an outstanding request, or else the request presented now.
  logic d_in_list;
  logic d_same_cycle;
  logic d_has_req;
  logic d_names_oldest;
  logic a_src_outstanding;
  assign d_in_list         = |d_hit;
  assign d_idx             = oldest_hit(d_hit);
  assign d_same_cycle      = !d_in_list && h2d_i.a_valid && (a_src == d_src);
  assign d_has_req         = d_in_list || d_same_cycle;
  assign d_names_oldest    = any_outstanding && (outstanding_q[0].source == d_src);
  assign a_src_outstanding = |a_hit;

  // The request the answer names: it decides the answer's opcode, size and data lanes.
  logic                d_req_is_get;
  logic [SizeW-1:0]    d_req_size;
  logic [BusBytes-1:0] d_req_lanes;
  tl_d_op_e            d_exp_opcode;
  assign d_req_is_get = d_in_list ? outstanding_q[d_idx].is_get : a_is_get;
  assign d_req_size   = d_in_list ? outstanding_q[d_idx].size   : h2d_i.a_size;
  assign d_req_lanes  = d_in_list ? active_lanes(outstanding_q[d_idx].offset, d_req_size) :
                                    a_lanes;
  assign d_exp_opcode = d_req_is_get ? AccessAckData : AccessAck;

  // The answer presented now: what the device rules and covers test of it.
  logic d_opcode_right;
  logic d_size_right;
  logic d_param_zero;
  logic d_has_data;
  assign d_opcode_right = (d2h_i.d_opcode == d_exp_opcode);
  assign d_size_right   = (d2h_i.d_size == d_req_size);
  assign d_param_zero   = (d2h_i.d_param == '0);
  assign d_has_data     = (d2h_i.d_opcode == AccessAckData);

  // The answer taken leaves the list; the request accepted joins it, unless answered now.
  assign rsp_leaves = d_fire && d_in_list;
  assign req_joins  = a_fire && !(d_fire && d_same_cycle);

  ////////////////////////
  // Outstanding limits //
  ////////////////////////

  // [TLPC]: up to 2^TL_AIW requests in flight; MaxOutstanding sets the port's limit. A port that
  // needs fewer says why where it sets the parameter: a smaller limit constrains the host.
  logic a_fits;
  assign a_fits = (outstanding_cnt_q < CntW'(MaxOutstanding)) || rsp_leaves;

  // The device's own limit: a request joins the list only if it has room for it.
  logic device_fits;
  assign device_fits = (outstanding_cnt_q < CntW'(DeviceMaxOutstanding)) || rsp_leaves;

  //////////////////
  // Answer bound //
  //////////////////

  // The device's answer bound: how many cycles the oldest request has waited with no answer
  // presented for it. 0 while the list is empty, when a new oldest arrives, and held while its
  // answer is presented (the host's d_ready does not count); saturates at the bound.
  localparam int unsigned BoundW = (DeviceRspBound > 1) ? $clog2(DeviceRspBound + 1) : 1;
  logic [BoundW-1:0] oldest_age_q;
  logic [BoundW-1:0] oldest_age_d;
  logic              oldest_presented;
  logic              oldest_leaves;
  assign oldest_presented = d2h_i.d_valid && d_names_oldest;
  assign oldest_leaves    = d_fire && d_names_oldest;

  // The next cycle starts with an empty list or with a new oldest request; the age is at the bound.
  logic empty_next;
  logic new_oldest_next;
  logic age_at_bound;
  assign empty_next      = (outstanding_cnt_d == '0);
  assign new_oldest_next = !any_outstanding || oldest_leaves;
  assign age_at_bound    = (oldest_age_q == BoundW'(DeviceRspBound));
  assign oldest_age_d    = (empty_next || new_oldest_next)     ? '0 :
                           (oldest_presented || age_at_bound)  ? oldest_age_q :
                                                                 oldest_age_q + 1'b1;

  always_ff @(posedge clk_i or negedge rst_ni) begin : proc_oldest_age
    if (!rst_ni) oldest_age_q <= '0;
    else         oldest_age_q <= oldest_age_d;
  end

  if (DeviceRspBound == 0) begin : gen_no_rsp_bound
    logic unused_oldest_age;
    assign unused_oldest_age = ^oldest_age_q;
  end

  ////////////////////
  // Data lane bits //
  ////////////////////

  // Each lane's byte of a data word, for the X checks.
  function automatic logic [8*BusBytes-1:0] lane_bits(logic [BusBytes-1:0] lanes);
    logic [8*BusBytes-1:0] bits;
    for (int unsigned k = 0; k < BusBytes; k++) begin
      bits[8*k +: 8] = {8{lanes[k]}};
    end
    return bits;
  endfunction

  ///////////////////////////////////////
  // Host rules: A channel and d_ready //
  ///////////////////////////////////////

  // A presented request carries one of the three TL-UL request opcodes.
  // [TL] Section 7; [TLPC] legalAOpcode.
  property Req_OpcodeLegal;
    h2d_i.a_valid |-> a_opcode_legal;
  endproperty

  // A presented request has a_param 0.
  // [TL] Section 7.2.1: "a_param is currently reserved ... and must be 0."
  property Req_ParamZero;
    h2d_i.a_valid |-> a_param_zero;
  endproperty

  // A presented request's size is no larger than the bus width.
  // [TL] Section 7.2.1: "a_size cannot be larger than the width of the physical data bus."
  property Req_SizeFitsBus;
    h2d_i.a_valid |-> a_size_legal;
  endproperty

  // A presented request's address is aligned to its size.
  // [TL] Section 7.2.1: "a_address must be aligned to a_size".
  property Req_Aligned;
    h2d_i.a_valid |-> a_aligned;
  endproperty

  // A presented request's mask is low on every inactive byte lane.
  // [TL] Section 4.5: "the mask must always be LOW for all inactive byte lanes".
  property Req_MaskInLanes;
    h2d_i.a_valid |-> a_mask_in_lanes;
  endproperty

  // A presented Get or PutFullData marks every active lane in its mask.
  // [TL] Section 4.5: all but PutPartialData mark every active lane.
  property Req_FullMask;
    h2d_i.a_valid && a_needs_full_mask |-> a_mask_full;
  endproperty

  // A presented request's source is not the source of a request still outstanding.
  // [TL] Section 6.4: a source stays outstanding through the cycle its answer is received.
  property Src_Unique;
    h2d_i.a_valid |-> !a_src_outstanding;
  endproperty

  // A request is presented only while fewer than MaxOutstanding are outstanding, or one leaves.
  // [TLPC]: up to 2^TL_AIW outstanding requests; MaxOutstanding is the port's limit.
  property Src_WithinMaxOutstanding;
    h2d_i.a_valid |-> a_fits;
  endproperty

  // a_valid is low in the first cycle after reset.
  // [TL] Section 3.2.2: a_valid is low as reset ends.
`ifdef FPV_ON
  property Req_NoValidAtReset;
    at_first_edge |-> !h2d_i.a_valid;
  endproperty
`else
  // The simulation form also looks at the last reset edge, which a formal trace does not contain.
  property Req_NoValidAtReset;
    at_first_edge |-> !$past(h2d_i.a_valid) && !h2d_i.a_valid;
  endproperty
`endif

  // A request the device has not accepted yet is offered again, unchanged, in the next cycle.
  // Host contract, on with HostReqHeld: [TL] Section 4.1 lets a sender withdraw or change a beat
  // that was not accepted, so a port that sets it says why.
  property Req_Held;
    a_waits |=> h2d_i.a_valid && $stable(a_fields);
  endproperty

  /////////////////////////////////////////
  // Device rules: D channel and a_ready //
  /////////////////////////////////////////

  // An answer is presented only for an outstanding request or the request presented now.
  // [TL] Section 5.1: "it is illegal to receive a response without receiving the request".
  property Src_RspHasReq;
    d2h_i.d_valid |-> d_has_req;
  endproperty

  // An answer's opcode matches its request: AccessAckData for a Get, AccessAck for a write.
  // [TL] Section 7, Table 15.
  property Rsp_OpcodeMatchesReq;
    d2h_i.d_valid && d_has_req |-> d_opcode_right;
  endproperty

  // An answer's size is its request's size.
  // [TL] Section 7.2.4: "d_size and a_size must always correspond."
  property Rsp_SizeMatchesReq;
    d2h_i.d_valid && d_has_req |-> d_size_right;
  endproperty

  // A presented answer has d_param 0.
  // [TL] Section 7.2.4, Section 7.2.5: d_param must be 0.
  property Rsp_ParamZero;
    d2h_i.d_valid |-> d_param_zero;
  endproperty

  // An answer taken in its request's cycle comes with that request accepted.
  // [TL] Section 4.2.
  property Rsp_SameCycleTaken;
    d_fire && d_same_cycle |-> a_fire;
  endproperty

  // d_valid is low in the first cycle after reset.
  // [TL] Section 3.2.2: d_valid is low as reset ends.
`ifdef FPV_ON
  property Rsp_NoValidAtReset;
    at_first_edge |-> !d2h_i.d_valid;
  endproperty
`else
  // The simulation form also looks at the last reset edge, as for a_valid.
  property Rsp_NoValidAtReset;
    at_first_edge |-> !$past(d2h_i.d_valid) && !d2h_i.d_valid;
  endproperty
`endif

  // The five device contracts below are stricter than TileLink and hold only for a device known
  // to behave so; a port that sets one of these parameters says why.

  // A device that answers in request order names the oldest request it still owes.
  // Device contract, on with DeviceInOrderRsp: [TL] Section 6.5 allows any order.
  property Rsp_InOrder;
    d2h_i.d_valid && any_outstanding |-> d_names_oldest;
  endproperty

  // An answer the host has not taken yet is offered again, unchanged, in the next cycle.
  // Device contract, on with DeviceRspHeld.
  property Rsp_Held;
    d_waits |=> d2h_i.d_valid && $stable(d_fields);
  endproperty

  // An answer needs a request accepted in an earlier cycle, never the one presented now.
  // Device contract, on with DeviceSameCycleRsp 0.
  property Rsp_NotSameCycle;
    d2h_i.d_valid |-> !d_same_cycle;
  endproperty

  // The device accepts a request only while it has room for it.
  // Device contract, on with DeviceMaxOutstanding below MaxOutstanding.
  property Src_WithinDeviceMaxOutstanding;
    req_joins |-> device_fits;
  endproperty

  // The oldest request spends at most DeviceRspBound cycles without its answer presented.
  // Device contract, on with DeviceRspBound above 0.
  property Rsp_WithinBound;
    any_outstanding |-> oldest_presented || (oldest_age_q < BoundW'(DeviceRspBound));
  endproperty

  ///////////////////////////////////////////////
  // Known values ([TLPC] Known), asserts only //
  ///////////////////////////////////////////////

  // a_valid is never X out of reset.
  // [TLPC] aKnown.
  property Req_ValidKnown;
    !$isunknown(h2d_i.a_valid);
  endproperty

  // The request's fields are not X while a_valid is high.
  // [TLPC] aKnown.
  property Req_FieldsKnown;
    h2d_i.a_valid |->
      !$isunknown({h2d_i.a_opcode, h2d_i.a_param, h2d_i.a_size, h2d_i.a_source, h2d_i.a_address,
                   h2d_i.a_mask, h2d_i.a_user});
  endproperty

  // The data bytes a write marks in its mask are not X.
  // [TLPC] aDataKnown.
  property Req_DataKnown;
    h2d_i.a_valid && (a_is_full || a_is_partial) |->
      !$isunknown(h2d_i.a_data & lane_bits(h2d_i.a_mask));
  endproperty

  // d_ready is never X out of reset.
  // [TLPC] dReadyKnown.
  property Req_DReadyKnown;
    !$isunknown(h2d_i.d_ready);
  endproperty

  // d_valid is never X out of reset.
  // [TLPC] dKnown.
  property Rsp_ValidKnown;
    !$isunknown(d2h_i.d_valid);
  endproperty

  // The answer's fields are not X while d_valid is high.
  // [TLPC] dKnown.
  property Rsp_FieldsKnown;
    d2h_i.d_valid |->
      !$isunknown({d2h_i.d_opcode, d2h_i.d_param, d2h_i.d_size, d2h_i.d_source, d2h_i.d_sink,
                   d2h_i.d_error, d2h_i.d_user});
  endproperty

  // An AccessAckData's data bytes in its request's active lanes are not X.
  // [TLPC] dDataKnown.
  property Rsp_DataKnown;
    d2h_i.d_valid && d_has_req && d_has_data |->
      !$isunknown(d2h_i.d_data & lane_bits(d_req_lanes));
  endproperty

  // a_ready is never X out of reset.
  // [TLPC] aReadyKnown.
  property Rsp_AReadyKnown;
    !$isunknown(d2h_i.a_ready);
  endproperty

  //////////////////////////////////////////////////////////////
  // Forward progress ([TL] Section 5), liveness, formal only //
  //////////////////////////////////////////////////////////////

`ifdef FPV_ON
`ifndef VERILATOR

  // A beat is held while valid stays high and its fields do not change until it is accepted
  // ([TL] Section 5.1, "present a beat").

  // An answer's obligation ends: it is taken, withdrawn or changed.
  property d_beat_ends;
    h2d_i.d_ready || !d2h_i.d_valid || !$stable(d_fields);
  endproperty

  // The answer shown now is held: valid and fields stay until it is taken; the host need not.
  property rsp_held_until_taken;
    h2d_i.d_ready or nexttime ((d2h_i.d_valid && $stable(d_fields)) until_with h2d_i.d_ready);
  endproperty

  // [TL] Section 5 rule 3 exemption: a request's obligation also ends while the device's answer
  // is held.
  property a_beat_ends;
    (d2h_i.a_ready || !h2d_i.a_valid || !$stable(a_fields)) or (d_waits and rsp_held_until_taken);
  endproperty

  // The oldest outstanding request's answer is shown and held until taken.
  property oldest_rsp_held;
    (d2h_i.d_valid && d_names_oldest) and rsp_held_until_taken;
  endproperty

  // The host eventually takes an answer that is held.
  // [TL] Section 5 rule 3i.
  property Live_HostTakesRsp;
    d2h_i.d_valid |-> s_eventually (d_beat_ends);
  endproperty

  // The device eventually accepts a held request, unless its own answer is held.
  // [TL] Section 5 rule 3i.
  property Live_DeviceAcceptsReq;
    h2d_i.a_valid |-> s_eventually (a_beat_ends);
  endproperty

  // The oldest outstanding request's answer is eventually held until taken.
  // [TL] Section 5 rule 3ii.
  property Live_DeviceAnswersReq;
    any_outstanding |-> s_eventually (oldest_rsp_held);
  endproperty
`endif
`endif

  //////////////////////////////////////////////////////////////////
  // Roles: assume_ on the end the ABVIP plays, assert_ the DUT's //
  //////////////////////////////////////////////////////////////////

  // PlayHost: the tool drives only legal requests; the DUT's answers are checked.
  if (Role == PlayHost) begin : gen_play_host
    assume_Req_OpcodeLegal                  : assume property (Req_OpcodeLegal);
    assume_Req_ParamZero                    : assume property (Req_ParamZero);
    assume_Req_SizeFitsBus                  : assume property (Req_SizeFitsBus);
    assume_Req_Aligned                      : assume property (Req_Aligned);
    assume_Req_MaskInLanes                  : assume property (Req_MaskInLanes);
    assume_Req_FullMask                     : assume property (Req_FullMask);
    assume_Src_Unique                       : assume property (Src_Unique);
    assume_Src_WithinMaxOutstanding         : assume property (Src_WithinMaxOutstanding);
    assume_Req_NoValidAtReset               : assume property (Req_NoValidAtReset);
    if (HostReqHeld) begin : gen_req_held
      assume_Req_Held                       : assume property (Req_Held);
    end
    if (DeviceInOrderRsp) begin : gen_in_order
      assert_Rsp_InOrder                    : assert property (Rsp_InOrder);
    end
    if (DeviceRspHeld) begin : gen_rsp_held
      assert_Rsp_Held                       : assert property (Rsp_Held);
    end
    assert_Src_RspHasReq                    : assert property (Src_RspHasReq);
    assert_Rsp_OpcodeMatchesReq             : assert property (Rsp_OpcodeMatchesReq);
    assert_Rsp_SizeMatchesReq               : assert property (Rsp_SizeMatchesReq);
    assert_Rsp_ParamZero                    : assert property (Rsp_ParamZero);
    if (DeviceSameCycleRsp) begin : gen_same_cycle
      assert_Rsp_SameCycleTaken             : assert property (Rsp_SameCycleTaken);
    end else begin : gen_next_cycle
      assert_Rsp_NotSameCycle               : assert property (Rsp_NotSameCycle);
    end
    if (DeviceMaxOutstanding < MaxOutstanding) begin : gen_device_limit
      assert_Src_WithinDeviceMaxOutstanding : assert property (Src_WithinDeviceMaxOutstanding);
    end
    if (DeviceRspBound > 0) begin : gen_rsp_bound
      assert_Rsp_WithinBound                : assert property (Rsp_WithinBound);
    end
    assert_Rsp_NoValidAtReset               : assert property (Rsp_NoValidAtReset);
    assert_Rsp_ValidKnown                   : assert property (Rsp_ValidKnown);
    assert_Rsp_FieldsKnown                  : assert property (Rsp_FieldsKnown);
    assert_Rsp_DataKnown                    : assert property (Rsp_DataKnown);
    assert_Rsp_AReadyKnown                  : assert property (Rsp_AReadyKnown);
    if (Liveness) begin : gen_live
`ifdef FPV_ON
`ifndef VERILATOR
      assume_Live_HostTakesRsp              : assume property (Live_HostTakesRsp);
      assert_Live_DeviceAcceptsReq          : assert property (Live_DeviceAcceptsReq);
      assert_Live_DeviceAnswersReq          : assert property (Live_DeviceAnswersReq);
`endif
`endif
    end

  // PlayDevice: the tool drives only legal answers; the DUT's requests are checked.
  end else if (Role == PlayDevice) begin : gen_play_device
    assert_Req_OpcodeLegal                  : assert property (Req_OpcodeLegal);
    assert_Req_ParamZero                    : assert property (Req_ParamZero);
    assert_Req_SizeFitsBus                  : assert property (Req_SizeFitsBus);
    assert_Req_Aligned                      : assert property (Req_Aligned);
    assert_Req_MaskInLanes                  : assert property (Req_MaskInLanes);
    assert_Req_FullMask                     : assert property (Req_FullMask);
    assert_Src_Unique                       : assert property (Src_Unique);
    assert_Src_WithinMaxOutstanding         : assert property (Src_WithinMaxOutstanding);
    assert_Req_NoValidAtReset               : assert property (Req_NoValidAtReset);
    if (HostReqHeld) begin : gen_req_held
      assert_Req_Held                       : assert property (Req_Held);
    end
    if (DeviceInOrderRsp) begin : gen_in_order
      assume_Rsp_InOrder                    : assume property (Rsp_InOrder);
    end
    if (DeviceRspHeld) begin : gen_rsp_held
      assume_Rsp_Held                       : assume property (Rsp_Held);
    end
    assume_Src_RspHasReq                    : assume property (Src_RspHasReq);
    assume_Rsp_OpcodeMatchesReq             : assume property (Rsp_OpcodeMatchesReq);
    assume_Rsp_SizeMatchesReq               : assume property (Rsp_SizeMatchesReq);
    assume_Rsp_ParamZero                    : assume property (Rsp_ParamZero);
    if (DeviceSameCycleRsp) begin : gen_same_cycle
      assume_Rsp_SameCycleTaken             : assume property (Rsp_SameCycleTaken);
    end else begin : gen_next_cycle
      assume_Rsp_NotSameCycle               : assume property (Rsp_NotSameCycle);
    end
    if (DeviceMaxOutstanding < MaxOutstanding) begin : gen_device_limit
      assume_Src_WithinDeviceMaxOutstanding : assume property (Src_WithinDeviceMaxOutstanding);
    end
    if (DeviceRspBound > 0) begin : gen_rsp_bound
      assume_Rsp_WithinBound                : assume property (Rsp_WithinBound);
    end
    assume_Rsp_NoValidAtReset               : assume property (Rsp_NoValidAtReset);
    assert_Req_ValidKnown                   : assert property (Req_ValidKnown);
    assert_Req_FieldsKnown                  : assert property (Req_FieldsKnown);
    assert_Req_DataKnown                    : assert property (Req_DataKnown);
    assert_Req_DReadyKnown                  : assert property (Req_DReadyKnown);
    if (Liveness) begin : gen_live
`ifdef FPV_ON
`ifndef VERILATOR
      assert_Live_HostTakesRsp              : assert property (Live_HostTakesRsp);
      assume_Live_DeviceAcceptsReq          : assume property (Live_DeviceAcceptsReq);
      assume_Live_DeviceAnswersReq          : assume property (Live_DeviceAnswersReq);
`endif
`endif
    end

  // CheckBoth: both ends are the DUT, so every rule is checked and none assumed.
  end else begin : gen_check_both
    assert_Req_OpcodeLegal                  : assert property (Req_OpcodeLegal);
    assert_Req_ParamZero                    : assert property (Req_ParamZero);
    assert_Req_SizeFitsBus                  : assert property (Req_SizeFitsBus);
    assert_Req_Aligned                      : assert property (Req_Aligned);
    assert_Req_MaskInLanes                  : assert property (Req_MaskInLanes);
    assert_Req_FullMask                     : assert property (Req_FullMask);
    assert_Src_Unique                       : assert property (Src_Unique);
    assert_Src_WithinMaxOutstanding         : assert property (Src_WithinMaxOutstanding);
    assert_Req_NoValidAtReset               : assert property (Req_NoValidAtReset);
    if (HostReqHeld) begin : gen_req_held
      assert_Req_Held                       : assert property (Req_Held);
    end
    if (DeviceInOrderRsp) begin : gen_in_order
      assert_Rsp_InOrder                    : assert property (Rsp_InOrder);
    end
    if (DeviceRspHeld) begin : gen_rsp_held
      assert_Rsp_Held                       : assert property (Rsp_Held);
    end
    assert_Src_RspHasReq                    : assert property (Src_RspHasReq);
    assert_Rsp_OpcodeMatchesReq             : assert property (Rsp_OpcodeMatchesReq);
    assert_Rsp_SizeMatchesReq               : assert property (Rsp_SizeMatchesReq);
    assert_Rsp_ParamZero                    : assert property (Rsp_ParamZero);
    if (DeviceSameCycleRsp) begin : gen_same_cycle
      assert_Rsp_SameCycleTaken             : assert property (Rsp_SameCycleTaken);
    end else begin : gen_next_cycle
      assert_Rsp_NotSameCycle               : assert property (Rsp_NotSameCycle);
    end
    if (DeviceMaxOutstanding < MaxOutstanding) begin : gen_device_limit
      assert_Src_WithinDeviceMaxOutstanding : assert property (Src_WithinDeviceMaxOutstanding);
    end
    if (DeviceRspBound > 0) begin : gen_rsp_bound
      assert_Rsp_WithinBound                : assert property (Rsp_WithinBound);
    end
    assert_Rsp_NoValidAtReset               : assert property (Rsp_NoValidAtReset);
    assert_Req_ValidKnown                   : assert property (Req_ValidKnown);
    assert_Req_FieldsKnown                  : assert property (Req_FieldsKnown);
    assert_Req_DataKnown                    : assert property (Req_DataKnown);
    assert_Req_DReadyKnown                  : assert property (Req_DReadyKnown);
    assert_Rsp_ValidKnown                   : assert property (Rsp_ValidKnown);
    assert_Rsp_FieldsKnown                  : assert property (Rsp_FieldsKnown);
    assert_Rsp_DataKnown                    : assert property (Rsp_DataKnown);
    assert_Rsp_AReadyKnown                  : assert property (Rsp_AReadyKnown);
    if (Liveness) begin : gen_live
`ifdef FPV_ON
`ifndef VERILATOR
      assert_Live_HostTakesRsp              : assert property (Live_HostTakesRsp);
      assert_Live_DeviceAcceptsReq          : assert property (Live_DeviceAcceptsReq);
      assert_Live_DeviceAnswersReq          : assert property (Live_DeviceAnswersReq);
`endif
`endif
    end
  end

  ////////////
  // Covers //
  ////////////

  // Every opcode, size, wait and answer kind, and the list's limits, on every port.

  // A Get is accepted.
  cover_Req_Get : cover property (a_fire && a_is_get);

  // A PutFullData is accepted.
  cover_Req_PutFull : cover property (a_fire && a_is_full);

  // A PutPartialData is accepted.
  cover_Req_PutPartial : cover property (a_fire && a_is_partial);

  // A PutPartialData whose mask has a gap between its set lanes is accepted.
  cover_Req_MaskGap : cover property (a_fire && a_is_partial && !a_mask_contiguous);

  // A request waits: a_valid is high and a_ready low.
  cover_Req_Waits : cover property (a_waits);

  // A request and an answer wait in the same cycle.
  cover_Req_WaitsOnRsp : cover property (a_waits && d_waits);

  // A waiting request is withdrawn: a_valid falls before the request is accepted.
  if (!HostReqHeld) begin : gen_cover_withdrawn
    cover_Req_Withdrawn : cover property (a_waits ##1 (h2d_i.a_valid == 1'b0));
  end

  // The first cycle after reset is reached.
  cover_Req_FirstEdge : cover property (at_first_edge);

  if (DeviceSameCycleRsp) begin : gen_cover_same_cycle
    // An answer is taken in the cycle its request is presented.
    cover_Src_SameCycle : cover property (d_fire && d_same_cycle);

    // An answer is presented for the request presented now, while that request waits.
    cover_Src_RspWhileWaits : cover property (d2h_i.d_valid && d_same_cycle && a_waits);
  end

  // A source is reused: the cycle after an answer is taken, a request with its source is accepted.
  cover_Src_Reuse : cover property (rsp_leaves ##1 a_fire && (a_src == $past(d_src)));

  // The list holds as many requests as the device's limit.
  cover_Src_Full : cover property (outstanding_cnt_q == CntW'(DeviceMaxOutstanding));

  // An AccessAckData is taken.
  cover_Rsp_AckData : cover property (d_fire && d_has_req && d_has_data);

  // An AccessAck is taken.
  cover_Rsp_Ack : cover property (d_fire && (d2h_i.d_opcode == AccessAck));

  // An answer with d_error set is taken.
  cover_Rsp_Error : cover property (d_fire && d2h_i.d_error);

  // An answer to a request accepted in an earlier cycle is taken.
  cover_Rsp_FromList : cover property (d_fire && d_in_list);

  // An answer to a request other than the oldest is taken.
  if (DeviceMaxOutstanding > 1 && !DeviceInOrderRsp) begin : gen_cover_out_of_order
    cover_Rsp_OutOfOrder : cover property (d_fire && d_in_list && !d_names_oldest);
  end

  // An answer waits: d_valid is high and d_ready low.
  cover_Rsp_Waits : cover property (d_waits);

  // The oldest request's answer is presented in the last cycle the answer bound allows, so the
  // age counter reaches the bound.
  if (DeviceRspBound > 0) begin : gen_cover_at_bound
    cover_Rsp_AtBound : cover property (oldest_presented && age_at_bound);
  end

  // A request of each size, up to the bus width, is accepted.
  for (genvar s = 0; s <= MaxSize; s++) begin : gen_cover_size
    cover_Req_Size : cover property (a_fire && (h2d_i.a_size == SizeW'(s)));
  end

  /////////////////
  // Spec events //
  /////////////////

  assign a_fire_o          = a_fire;
  assign d_fire_o          = d_fire;
  assign outstanding_cnt_o = outstanding_cnt_q;
  assign oldest_src_o      = outstanding_q[0].source;

endmodule
