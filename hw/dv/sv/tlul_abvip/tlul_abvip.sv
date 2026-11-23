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
// hw/ip/tlul/doc/TlulProtocolChecker.md. "Presented" follows [TL] §5.1: valid is high, whether
// or not ready is. Properties are named <Feature>_<Name>; their labels add assume_, assert_ or
// cover_. x_d is the next value of x_q.
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
  parameter role_e       Role              = PlayHost,
  parameter int unsigned SrcW              = top_pkg::TL_AIW,
  parameter int unsigned MaxOutstanding    = 2 ** SrcW,

  // The device's contract, set only with a basis (TL28, TL29): the defaults hold the spec's rules.
  parameter bit          DevSameCycleRsp   = 1'b1,  // 0: no answer in its request's cycle
  parameter int unsigned DevMaxOutstanding = MaxOutstanding,  // requests the device holds at once
  parameter int unsigned DevRspBound       = 0,  // >0: cycles the device has to present an answer
  parameter bit          DevInOrderRsp     = 1'b0,  // 1: answers come back in request order
  parameter bit          DevRspHeld        = 1'b0,  // 1: an answer offered stays unchanged
  // The host's contract, on the same terms as the device's above.
  parameter bit          HostReqHeld       = 1'b0,  // 1: a request offered stays unchanged
  parameter bit          Liveness          = 1'b0,  // 1: [TL] forward progress rules, formal only
  localparam int unsigned CntW             = $clog2(MaxOutstanding + 1)
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
  output logic [CntW-1:0] num_outstanding_o,
  output logic [SrcW-1:0] oldest_src_o
);

  // Interface widths ([PKG]); the largest a_size covers the bus width ([TL] §7.2.1).
  localparam int unsigned AW      = top_pkg::TL_AW;
  localparam int unsigned DBW     = top_pkg::TL_DBW;
  localparam int unsigned SZW     = top_pkg::TL_SZW;
  localparam int unsigned AIW     = top_pkg::TL_AIW;
  localparam int unsigned OffW    = $clog2(DBW);
  localparam int unsigned MaxSize = OffW;
  localparam int unsigned IdxW    = (MaxOutstanding > 1) ? $clog2(MaxOutstanding) : 1;

  if (SrcW < 1 || SrcW > AIW) begin : gen_bad_src_w
    $error("tlul_abvip: SrcW must be 1 to TL_AIW");
  end

  if (DevMaxOutstanding < 1 || DevMaxOutstanding > MaxOutstanding) begin : gen_bad_dev_max
    $error("tlul_abvip: DevMaxOutstanding must be 1 to MaxOutstanding");
  end

  if (DevRspBound > 2 ** 16) begin : gen_bad_rsp_bound
    $error("tlul_abvip: DevRspBound must be 0 to 2**16");
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

  // [TL] §4.1: a beat is accepted in a cycle where valid and ready are both high.
  logic a_fire, d_fire;
  assign a_fire = h2d_i.a_valid && d2h_i.a_ready;
  assign d_fire = d2h_i.d_valid && h2d_i.d_ready;

  // A beat waits while its valid is high and the other end's ready is low.
  logic a_waits, d_waits;
  assign a_waits = h2d_i.a_valid && !d2h_i.a_ready;
  assign d_waits = d2h_i.d_valid && !h2d_i.d_ready;

  // [TL] §3.2.2: valid may go high only after the first rising edge where reset is low.
  logic past_first_edge_q, past_first_edge_d, at_first_edge;
  assign past_first_edge_d = 1'b1;
  assign at_first_edge     = !past_first_edge_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) past_first_edge_q <= 1'b0;
    else         past_first_edge_q <= past_first_edge_d;
  end

  ////////////////////
  // Request decode //
  ////////////////////

  // [TL] §4.5: the active lanes are the 2^size bytes from the address offset.
  function automatic logic [DBW-1:0] active_lanes(logic [OffW-1:0] offset, logic [SZW-1:0] size);
    int unsigned first, bytes;
    logic [DBW-1:0] lanes;
    first = 32'(offset);
    bytes = 32'd1 << size;
    for (int unsigned k = 0; k < DBW; k++) begin
      lanes[k] = (k >= first) && (k < first + bytes);
    end
    return lanes;
  endfunction

  // [TL] §4.5: (address & (2^size - 1)) = 0.
  function automatic logic is_aligned(logic [AW-1:0] address, logic [SZW-1:0] size);
    logic [AW-1:0] low_bits;
    low_bits = (AW'(1'b1) << size) - AW'(1'b1);
    return (address & low_bits) == '0;
  endfunction

  // The set bits of a mask form one run.
  function automatic logic is_contiguous(logic [DBW-1:0] mask);
    int unsigned runs;
    logic prev;
    runs = 0;
    prev = 1'b0;
    for (int unsigned k = 0; k < DBW; k++) begin
      if (mask[k] && !prev) runs++;
      prev = mask[k];
    end
    return runs <= 1;
  endfunction

  // Each lane's byte of a data word, for the X checks.
  // Every A-channel field: a request that waits is still the same request.
  function automatic logic same_request(tl_h2d_t x, tl_h2d_t y);
    return (x.a_opcode == y.a_opcode) && (x.a_param == y.a_param) && (x.a_size == y.a_size) &&
           (x.a_source == y.a_source) && (x.a_address == y.a_address) &&
           (x.a_mask == y.a_mask) && (x.a_data == y.a_data) && (x.a_user == y.a_user);
  endfunction

  // Every D-channel field: an answer that waits is still the same answer.
  function automatic logic same_answer(tl_d2h_t x, tl_d2h_t y);
    return (x.d_opcode == y.d_opcode) && (x.d_param == y.d_param) && (x.d_size == y.d_size) &&
           (x.d_source == y.d_source) && (x.d_sink == y.d_sink) && (x.d_data == y.d_data) &&
           (x.d_user == y.d_user) && (x.d_error == y.d_error);
  endfunction

  function automatic logic [8*DBW-1:0] lane_bits(logic [DBW-1:0] lanes);
    logic [8*DBW-1:0] bits;
    for (int unsigned k = 0; k < DBW; k++) begin
      bits[8*k +: 8] = {8{lanes[k]}};
    end
    return bits;
  endfunction

  logic a_is_get, a_is_full, a_is_partial;
  assign a_is_get     = (h2d_i.a_opcode == Get);
  assign a_is_full    = (h2d_i.a_opcode == PutFullData);
  assign a_is_partial = (h2d_i.a_opcode == PutPartialData);

  logic [DBW-1:0] a_lanes;
  logic           a_opcode_legal, a_param_zero, a_size_legal, a_aligned;
  logic           a_mask_in_lanes, a_needs_full_mask, a_mask_full, a_mask_contig;
  assign a_lanes           = active_lanes(h2d_i.a_address[OffW-1:0], h2d_i.a_size);
  assign a_opcode_legal    = a_is_get || a_is_full || a_is_partial;
  assign a_param_zero      = (h2d_i.a_param == '0);
  assign a_size_legal      = (h2d_i.a_size <= SZW'(MaxSize));
  assign a_aligned         = is_aligned(h2d_i.a_address, h2d_i.a_size);
  assign a_mask_in_lanes   = ((h2d_i.a_mask & ~a_lanes) == '0);
  assign a_needs_full_mask = a_is_get || a_is_full;
  assign a_mask_full       = (h2d_i.a_mask == a_lanes);
  assign a_mask_contig     = is_contiguous(h2d_i.a_mask);

  // [TLUL] Source ID requirements: the low SrcW bits identify a request at this port.
  logic [SrcW-1:0] a_src, d_src;
  assign a_src = h2d_i.a_source[SrcW-1:0];
  assign d_src = d2h_i.d_source[SrcW-1:0];

  //////////////////////
  // Outstanding list //
  //////////////////////

  // One outstanding request: what its answer must match ([TL] §7, Table 15; §7.2.4).
  typedef struct packed {
    logic [SrcW-1:0] source;
    logic            is_get;
    logic [SZW-1:0]  size;
    logic [OffW-1:0] offset;
  } req_t;

  req_t a_req;
  assign a_req = '{source: a_src, is_get: a_is_get, size: h2d_i.a_size,
                   offset: h2d_i.a_address[OffW-1:0]};

  // Set by the answer decode below: which entry the answer names, what leaves, what joins.
  logic [IdxW-1:0] d_idx;
  logic            rsp_leaves, req_joins;

  // outstanding_q[0] is the oldest; entries at num_outstanding_q and above are zero.
  req_t [MaxOutstanding-1:0] outstanding_q, outstanding_d;
  logic [CntW-1:0]           num_outstanding_q, num_outstanding_d;

  // Remove first (the entries above the answered one move down), then append at the tail.
  logic [CntW-1:0] num_kept;
  logic            full_after_leave;
  assign num_kept         = num_outstanding_q - CntW'(rsp_leaves);
  assign full_after_leave = (num_kept == CntW'(MaxOutstanding));

  for (genvar i = 0; i < MaxOutstanding; i++) begin : gen_list
    req_t kept;
    logic joins_here, kept_here;
    if (i == MaxOutstanding - 1) begin : gen_top
      assign kept = outstanding_q[i];
    end else begin : gen_below
      logic moves_down;
      assign moves_down = rsp_leaves && (IdxW'(i) >= d_idx);
      assign kept       = moves_down ? outstanding_q[i+1] : outstanding_q[i];
    end
    assign joins_here       = req_joins && (CntW'(i) == num_kept);
    assign kept_here        = (CntW'(i) < num_kept);
    assign outstanding_d[i] = joins_here ? a_req :
                              kept_here  ? kept  :
                                           '0;
  end
  assign num_outstanding_d = num_kept + CntW'(req_joins && !full_after_leave);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      outstanding_q     <= '0;
      num_outstanding_q <= '0;
    end else begin
      outstanding_q     <= outstanding_d;
      num_outstanding_q <= num_outstanding_d;
    end
  end

  // Entry i is outstanding and has the answer's source (d_hit) or the request's (a_hit).
  logic [MaxOutstanding-1:0] d_hit, a_hit;
  for (genvar i = 0; i < MaxOutstanding; i++) begin : gen_hit
    logic in_use;
    assign in_use   = (CntW'(i) < num_outstanding_q);
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

  // [TL] §4.2: an answer names an outstanding request, or else the request presented now.
  logic any_outstanding, d_in_list, d_same_cycle, d_has_req, d_names_oldest;
  logic a_src_outstanding;
  assign any_outstanding   = (num_outstanding_q != '0);
  assign d_in_list         = |d_hit;
  assign d_idx             = oldest_hit(d_hit);
  assign d_same_cycle      = !d_in_list && h2d_i.a_valid && (a_src == d_src);
  assign d_has_req         = d_in_list || d_same_cycle;
  assign d_names_oldest    = any_outstanding && (outstanding_q[0].source == d_src);

  // d_names_oldest feeds the out-of-order cover and the liveness rule only; DevMaxOutstanding 1
  // leaves the cover out.
  logic unused_names_oldest;
  assign unused_names_oldest = d_names_oldest;
  assign a_src_outstanding = |a_hit;

  // The request the answer names: it decides the answer's opcode, size and data lanes.
  logic           d_req_is_get;
  logic [SZW-1:0] d_req_size;
  logic [DBW-1:0] d_req_lanes;
  tl_d_op_e       d_exp_opcode;
  assign d_req_is_get = d_in_list ? outstanding_q[d_idx].is_get : a_is_get;
  assign d_req_size   = d_in_list ? outstanding_q[d_idx].size   : h2d_i.a_size;
  assign d_req_lanes  = d_in_list ? active_lanes(outstanding_q[d_idx].offset, d_req_size) :
                                    a_lanes;
  assign d_exp_opcode = d_req_is_get ? AccessAckData : AccessAck;

  logic d_opcode_right, d_size_right, d_param_zero, d_has_data;
  assign d_opcode_right = (d2h_i.d_opcode == d_exp_opcode);
  assign d_size_right   = (d2h_i.d_size == d_req_size);
  assign d_param_zero   = (d2h_i.d_param == '0);
  assign d_has_data     = (d2h_i.d_opcode == AccessAckData);

  // The answer taken leaves the list; the request accepted joins it, unless answered now.
  assign rsp_leaves = d_fire && d_in_list;
  assign req_joins  = a_fire && !(d_fire && d_same_cycle);

  // [TLPC]: up to 2^TL_AIW requests in flight; MaxOutstanding sets the port's limit. A port that
  // needs fewer says why where it sets the parameter: a smaller limit constrains the host.
  logic a_fits;
  assign a_fits = (num_outstanding_q < CntW'(MaxOutstanding)) || rsp_leaves;

  // The device's own limit (TL29): a request joins the list only if it has room for it.
  logic dev_fits;
  assign dev_fits = (num_outstanding_q < CntW'(DevMaxOutstanding)) || rsp_leaves;

  // The device's answer bound (TL30): how many cycles the oldest request has waited with no answer
  // presented for it. 0 while the list is empty, when a new oldest arrives, and held while its
  // answer is presented (the host's d_ready does not count); saturates at the bound.
  localparam int unsigned BoundW = (DevRspBound > 1) ? $clog2(DevRspBound + 1) : 1;
  logic [BoundW-1:0] oldest_age_q, oldest_age_d;
  logic              oldest_presented, oldest_leaves;
  assign oldest_presented = d2h_i.d_valid && d_names_oldest;
  assign oldest_leaves    = d_fire && d_names_oldest;
  assign oldest_age_d = (num_outstanding_d == '0)               ? '0 :
                        (!any_outstanding || oldest_leaves)     ? '0 :
                        oldest_presented                        ? oldest_age_q :
                        (oldest_age_q == BoundW'(DevRspBound))  ? oldest_age_q :
                                                                  oldest_age_q + 1'b1;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) oldest_age_q <= '0;
    else         oldest_age_q <= oldest_age_d;
  end

  if (DevRspBound == 0) begin : gen_no_rsp_bound
    logic unused_oldest_age;
    assign unused_oldest_age = ^oldest_age_q;
  end

  ///////////////////////////////////////
  // Host rules: A channel and d_ready //
  ///////////////////////////////////////

  // [TL] §7: the three TL-UL request opcodes; [TLPC] legalAOpcode.
  property Req_Opcode;
    h2d_i.a_valid |-> a_opcode_legal;
  endproperty

  // [TL] §7.2.1: "a_param is currently reserved ... and must be 0."
  property Req_Param;
    h2d_i.a_valid |-> a_param_zero;
  endproperty

  // [TL] §7.2.1: "a_size cannot be larger than the width of the physical data bus."
  property Req_Size;
    h2d_i.a_valid |-> a_size_legal;
  endproperty

  // [TL] §7.2.1: "a_address must be aligned to a_size".
  property Req_Aligned;
    h2d_i.a_valid |-> a_aligned;
  endproperty

  // [TL] §4.5: "the mask must always be LOW for all inactive byte lanes".
  property Req_MaskInLanes;
    h2d_i.a_valid |-> a_mask_in_lanes;
  endproperty

  // [TL] §4.5: all but PutPartialData mark every active lane.
  property Req_FullMask;
    h2d_i.a_valid && a_needs_full_mask |-> a_mask_full;
  endproperty

  // [TL] §6.4: a source stays outstanding through the cycle its answer is received.
  property Src_Unique;
    h2d_i.a_valid |-> !a_src_outstanding;
  endproperty

  // [TLPC]: "up to 2^TL_AIW outstanding requests"; MaxOutstanding is the port's limit.
  property Src_MaxOutstanding;
    h2d_i.a_valid |-> a_fits;
  endproperty

  // [TL] §3.2.2: a_valid is low as reset ends. The simulation form also looks at the last reset
  // edge, which a formal trace does not contain.
  property Req_NoValidAtReset;
`ifdef FPV_ON
    at_first_edge |-> !h2d_i.a_valid;
`else
    at_first_edge |-> !$past(h2d_i.a_valid) && !h2d_i.a_valid;
`endif
  endproperty

  /////////////////////////////////////////
  // Device rules: D channel and a_ready //
  /////////////////////////////////////////

  // [TL] §5.1: "it is illegal to receive a response without receiving the request".
  property Src_RspHasReq;
    d2h_i.d_valid |-> d_has_req;
  endproperty

  // [TL] §7, Table 15: a Get is answered by AccessAckData, a write by AccessAck.
  property Rsp_Opcode;
    d2h_i.d_valid && d_has_req |-> d_opcode_right;
  endproperty

  // [TL] §7.2.4: "d_size and a_size must always correspond."
  property Rsp_Size;
    d2h_i.d_valid && d_has_req |-> d_size_right;
  endproperty

  // [TL] §7.2.4, §7.2.5: d_param must be 0.
  property Rsp_Param;
    d2h_i.d_valid |-> d_param_zero;
  endproperty

  // A device that answers in request order names the oldest request it still owes. TileLink
  // allows any order, so this holds only where the port says the device keeps to one.
  property Rsp_InOrder;
    d2h_i.d_valid && any_outstanding |-> d_names_oldest;
  endproperty

  // An answer the host has not taken yet is offered again, unchanged, in the next cycle.
  property Rsp_Held;
    d2h_i.d_valid && !h2d_i.d_ready |=> d2h_i.d_valid && same_answer(d2h_i, $past(d2h_i));
  endproperty

  // A request the device has not accepted yet is offered again, unchanged, in the next cycle.
  property Req_Held;
    h2d_i.a_valid && !d2h_i.a_ready |=> h2d_i.a_valid && same_request(h2d_i, $past(h2d_i));
  endproperty

  // [TL] §4.2: an answer taken in its request's cycle needs that request accepted.
  property Rsp_SameCycleTaken;
    d_fire && d_same_cycle |-> a_fire;
  endproperty

  // The three device contracts below are stricter than TileLink and hold only for a device known
  // to behave so; a port that sets one of these parameters says why. With DevSameCycleRsp 0, an
  // answer needs a request accepted in an earlier cycle.
  property Rsp_NotSameCycle;
    d2h_i.d_valid |-> !d_same_cycle;
  endproperty

  // With DevMaxOutstanding below MaxOutstanding, the device accepts a request only while it has
  // room for it.
  property Src_DevMaxOutstanding;
    req_joins |-> dev_fits;
  endproperty

  // With DevRspBound above 0, the oldest request waits fewer than DevRspBound cycles before its
  // answer is presented.
  property Rsp_WithinBound;
    any_outstanding |-> oldest_presented || (oldest_age_q < BoundW'(DevRspBound));
  endproperty

  // [TL] §3.2.2: d_valid is low as reset ends; the simulation form also looks at the last reset
  // edge, as above.
  property Rsp_NoValidAtReset;
`ifdef FPV_ON
    at_first_edge |-> !d2h_i.d_valid;
`else
    at_first_edge |-> !$past(d2h_i.d_valid) && !d2h_i.d_valid;
`endif
  endproperty

  ///////////////////////////////////////////////
  // Known values ([TLPC] Known), asserts only //
  ///////////////////////////////////////////////

  // Jasper reports $isunknown of a signal as false, so these check only in simulation.
  // [TLPC] aKnown: a_valid is never X (except during reset).
  property Req_ValidKnown;
    !$isunknown(h2d_i.a_valid);
  endproperty

  // [TLPC] aKnown: the request's fields are not X while a_valid is high.
  property Req_FieldsKnown;
    h2d_i.a_valid |->
      !$isunknown({h2d_i.a_opcode, h2d_i.a_param, h2d_i.a_size, h2d_i.a_source, h2d_i.a_address,
                   h2d_i.a_mask, h2d_i.a_user});
  endproperty

  // [TLPC] aDataKnown: the bytes a write marks.
  property Req_DataKnown;
    h2d_i.a_valid && (a_is_full || a_is_partial) |->
      !$isunknown(h2d_i.a_data & lane_bits(h2d_i.a_mask));
  endproperty

  // [TLPC] dReadyKnown: d_ready is never X (except during reset).
  property Req_DReadyKnown;
    !$isunknown(h2d_i.d_ready);
  endproperty

  // [TLPC] dKnown: d_valid is never X (except during reset).
  property Rsp_ValidKnown;
    !$isunknown(d2h_i.d_valid);
  endproperty

  // [TLPC] dKnown: the answer's fields are not X while d_valid is high.
  property Rsp_FieldsKnown;
    d2h_i.d_valid |->
      !$isunknown({d2h_i.d_opcode, d2h_i.d_param, d2h_i.d_size, d2h_i.d_source, d2h_i.d_sink,
                   d2h_i.d_error, d2h_i.d_user});
  endproperty

  // [TLPC] dDataKnown: the bytes the Get's active lanes cover.
  property Rsp_DataKnown;
    d2h_i.d_valid && d_has_req && d_has_data |->
      !$isunknown(d2h_i.d_data & lane_bits(d_req_lanes));
  endproperty

  // [TLPC] aReadyKnown: a_ready is never X (except during reset).
  property Rsp_AReadyKnown;
    !$isunknown(d2h_i.a_ready);
  endproperty

  //////////////////////////////////////////////////////
  // Forward progress ([TL] §5), liveness, formal only //
  //////////////////////////////////////////////////////

`ifdef FPV_ON
`ifndef VERILATOR

  // A beat is held while valid stays high and its fields do not change ([TL] §5.1 "presented").
  logic [$bits(tl_h2d_t)-2:0] a_fields;
  logic [$bits(tl_d2h_t)-2:0] d_fields;
  assign a_fields = {h2d_i.a_opcode, h2d_i.a_param, h2d_i.a_size, h2d_i.a_source,
                     h2d_i.a_address, h2d_i.a_mask, h2d_i.a_data, h2d_i.a_user};
  assign d_fields = {d2h_i.d_opcode, d2h_i.d_param, d2h_i.d_size, d2h_i.d_source,
                     d2h_i.d_sink, d2h_i.d_data, d2h_i.d_user, d2h_i.d_error};

  // An answer's obligation ends: it is taken, withdrawn or changed.
  property d_beat_ends;
    h2d_i.d_ready || !d2h_i.d_valid || !$stable(d_fields);
  endproperty

  // The answer shown now is held: valid and fields stay until it is taken; the host need not.
  property rsp_held_until_taken;
    h2d_i.d_ready or nexttime ((d2h_i.d_valid && $stable(d_fields)) until_with h2d_i.d_ready);
  endproperty

  // [TL] §5 rule 3 exemption: a request's obligation also ends while the device's answer is held.
  property a_beat_ends;
    (d2h_i.a_ready || !h2d_i.a_valid || !$stable(a_fields)) or (d_waits and rsp_held_until_taken);
  endproperty

  // The oldest outstanding request's answer is shown and held until taken.
  property oldest_rsp_held;
    (d2h_i.d_valid && d_names_oldest) and rsp_held_until_taken;
  endproperty

  // [TL] §5 rule 3i: the host eventually takes an answer that is held.
  property Live_HostTakesRsp;
    d2h_i.d_valid |-> s_eventually (d_beat_ends);
  endproperty

  // [TL] §5 rule 3i: the device eventually accepts a held request, unless its own answer is held.
  property Live_DevAcceptsReq;
    h2d_i.a_valid |-> s_eventually (a_beat_ends);
  endproperty

  // [TL] §5 rule 3ii: the oldest outstanding request's answer is eventually held until taken.
  property Live_DevAnswersReq;
    any_outstanding |-> s_eventually (oldest_rsp_held);
  endproperty
`endif
`endif

  /////////////////////////////////////////////////////////////////
  // Roles: assume_ on the end the ABVIP plays, assert_ the DUT's //
  /////////////////////////////////////////////////////////////////

  // PlayHost: the tool drives only legal requests; the DUT's answers are checked.
  if (Role == PlayHost) begin : gen_play_host
    assume_Req_Opcode          : assume property (Req_Opcode);
    assume_Req_Param           : assume property (Req_Param);
    assume_Req_Size            : assume property (Req_Size);
    assume_Req_Aligned         : assume property (Req_Aligned);
    assume_Req_MaskInLanes     : assume property (Req_MaskInLanes);
    assume_Req_FullMask        : assume property (Req_FullMask);
    assume_Src_Unique          : assume property (Src_Unique);
    assume_Src_MaxOutstanding  : assume property (Src_MaxOutstanding);
    assume_Req_NoValidAtReset  : assume property (Req_NoValidAtReset);
    if (HostReqHeld) begin : gen_req_held
      assume_Req_Held            : assume property (Req_Held);
    end
    if (DevInOrderRsp) begin : gen_in_order
      assert_Rsp_InOrder         : assert property (Rsp_InOrder);
    end
    if (DevRspHeld) begin : gen_rsp_held
      assert_Rsp_Held            : assert property (Rsp_Held);
    end
    assert_Src_RspHasReq       : assert property (Src_RspHasReq);
    assert_Rsp_Opcode          : assert property (Rsp_Opcode);
    assert_Rsp_Size            : assert property (Rsp_Size);
    assert_Rsp_Param           : assert property (Rsp_Param);
    if (DevSameCycleRsp) begin : gen_same_cycle
      assert_Rsp_SameCycleTaken  : assert property (Rsp_SameCycleTaken);
    end else begin : gen_next_cycle
      assert_Rsp_NotSameCycle    : assert property (Rsp_NotSameCycle);
    end
    if (DevMaxOutstanding < MaxOutstanding) begin : gen_dev_limit
      assert_Src_DevMaxOutstanding : assert property (Src_DevMaxOutstanding);
    end
    if (DevRspBound > 0) begin : gen_rsp_bound
      assert_Rsp_WithinBound       : assert property (Rsp_WithinBound);
    end
    assert_Rsp_NoValidAtReset  : assert property (Rsp_NoValidAtReset);
    assert_Rsp_ValidKnown      : assert property (Rsp_ValidKnown);
    assert_Rsp_FieldsKnown     : assert property (Rsp_FieldsKnown);
    assert_Rsp_DataKnown       : assert property (Rsp_DataKnown);
    assert_Rsp_AReadyKnown     : assert property (Rsp_AReadyKnown);
    if (Liveness) begin : gen_live
`ifdef FPV_ON
`ifndef VERILATOR
      assume_Live_HostTakesRsp  : assume property (Live_HostTakesRsp);
      assert_Live_DevAcceptsReq : assert property (Live_DevAcceptsReq);
      assert_Live_DevAnswersReq : assert property (Live_DevAnswersReq);
`endif
`endif
    end

  // PlayDevice: the tool drives only legal answers; the DUT's requests are checked.
  end else if (Role == PlayDevice) begin : gen_play_device
    assert_Req_Opcode          : assert property (Req_Opcode);
    assert_Req_Param           : assert property (Req_Param);
    assert_Req_Size            : assert property (Req_Size);
    assert_Req_Aligned         : assert property (Req_Aligned);
    assert_Req_MaskInLanes     : assert property (Req_MaskInLanes);
    assert_Req_FullMask        : assert property (Req_FullMask);
    assert_Src_Unique          : assert property (Src_Unique);
    assert_Src_MaxOutstanding  : assert property (Src_MaxOutstanding);
    assert_Req_NoValidAtReset  : assert property (Req_NoValidAtReset);
    if (HostReqHeld) begin : gen_req_held
      assert_Req_Held            : assert property (Req_Held);
    end
    if (DevInOrderRsp) begin : gen_in_order
      assume_Rsp_InOrder         : assume property (Rsp_InOrder);
    end
    if (DevRspHeld) begin : gen_rsp_held
      assume_Rsp_Held            : assume property (Rsp_Held);
    end
    assume_Src_RspHasReq       : assume property (Src_RspHasReq);
    assume_Rsp_Opcode          : assume property (Rsp_Opcode);
    assume_Rsp_Size            : assume property (Rsp_Size);
    assume_Rsp_Param           : assume property (Rsp_Param);
    if (DevSameCycleRsp) begin : gen_same_cycle
      assume_Rsp_SameCycleTaken  : assume property (Rsp_SameCycleTaken);
    end else begin : gen_next_cycle
      assume_Rsp_NotSameCycle    : assume property (Rsp_NotSameCycle);
    end
    if (DevMaxOutstanding < MaxOutstanding) begin : gen_dev_limit
      assume_Src_DevMaxOutstanding : assume property (Src_DevMaxOutstanding);
    end
    if (DevRspBound > 0) begin : gen_rsp_bound
      assume_Rsp_WithinBound       : assume property (Rsp_WithinBound);
    end
    assume_Rsp_NoValidAtReset  : assume property (Rsp_NoValidAtReset);
    assert_Req_ValidKnown      : assert property (Req_ValidKnown);
    assert_Req_FieldsKnown     : assert property (Req_FieldsKnown);
    assert_Req_DataKnown       : assert property (Req_DataKnown);
    assert_Req_DReadyKnown     : assert property (Req_DReadyKnown);
    if (Liveness) begin : gen_live
`ifdef FPV_ON
`ifndef VERILATOR
      assert_Live_HostTakesRsp  : assert property (Live_HostTakesRsp);
      assume_Live_DevAcceptsReq : assume property (Live_DevAcceptsReq);
      assume_Live_DevAnswersReq : assume property (Live_DevAnswersReq);
`endif
`endif
    end

  // CheckBoth: both ends are the DUT, so every rule is checked and none assumed.
  end else begin : gen_check_both
    assert_Req_Opcode          : assert property (Req_Opcode);
    assert_Req_Param           : assert property (Req_Param);
    assert_Req_Size            : assert property (Req_Size);
    assert_Req_Aligned         : assert property (Req_Aligned);
    assert_Req_MaskInLanes     : assert property (Req_MaskInLanes);
    assert_Req_FullMask        : assert property (Req_FullMask);
    assert_Src_Unique          : assert property (Src_Unique);
    assert_Src_MaxOutstanding  : assert property (Src_MaxOutstanding);
    assert_Req_NoValidAtReset  : assert property (Req_NoValidAtReset);
    if (HostReqHeld) begin : gen_req_held
      assert_Req_Held            : assert property (Req_Held);
    end
    if (DevInOrderRsp) begin : gen_in_order
      assert_Rsp_InOrder         : assert property (Rsp_InOrder);
    end
    if (DevRspHeld) begin : gen_rsp_held
      assert_Rsp_Held            : assert property (Rsp_Held);
    end
    assert_Src_RspHasReq       : assert property (Src_RspHasReq);
    assert_Rsp_Opcode          : assert property (Rsp_Opcode);
    assert_Rsp_Size            : assert property (Rsp_Size);
    assert_Rsp_Param           : assert property (Rsp_Param);
    if (DevSameCycleRsp) begin : gen_same_cycle
      assert_Rsp_SameCycleTaken  : assert property (Rsp_SameCycleTaken);
    end else begin : gen_next_cycle
      assert_Rsp_NotSameCycle    : assert property (Rsp_NotSameCycle);
    end
    if (DevMaxOutstanding < MaxOutstanding) begin : gen_dev_limit
      assert_Src_DevMaxOutstanding : assert property (Src_DevMaxOutstanding);
    end
    if (DevRspBound > 0) begin : gen_rsp_bound
      assert_Rsp_WithinBound       : assert property (Rsp_WithinBound);
    end
    assert_Rsp_NoValidAtReset  : assert property (Rsp_NoValidAtReset);
    assert_Req_ValidKnown      : assert property (Req_ValidKnown);
    assert_Req_FieldsKnown     : assert property (Req_FieldsKnown);
    assert_Req_DataKnown       : assert property (Req_DataKnown);
    assert_Req_DReadyKnown     : assert property (Req_DReadyKnown);
    assert_Rsp_ValidKnown      : assert property (Rsp_ValidKnown);
    assert_Rsp_FieldsKnown     : assert property (Rsp_FieldsKnown);
    assert_Rsp_DataKnown       : assert property (Rsp_DataKnown);
    assert_Rsp_AReadyKnown     : assert property (Rsp_AReadyKnown);
    if (Liveness) begin : gen_live
`ifdef FPV_ON
`ifndef VERILATOR
      assert_Live_HostTakesRsp  : assert property (Live_HostTakesRsp);
      assert_Live_DevAcceptsReq : assert property (Live_DevAcceptsReq);
      assert_Live_DevAnswersReq : assert property (Live_DevAnswersReq);
`endif
`endif
    end
  end

  ////////////
  // Covers //
  ////////////

  // Every opcode, size, wait and answer kind, and the list's limits, on every port.
  cover_Req_Get           : cover property (a_fire && a_is_get);
  cover_Req_PutFull       : cover property (a_fire && a_is_full);
  cover_Req_PutPartial    : cover property (a_fire && a_is_partial);
  cover_Req_MaskGap       : cover property (a_fire && a_is_partial && !a_mask_contig);
  cover_Req_Waits         : cover property (a_waits);
  cover_Req_WaitsOnRsp    : cover property (a_waits && d_waits);
  if (!HostReqHeld) begin : gen_cover_withdrawn
    cover_Req_Withdrawn     : cover property (a_waits ##1 (h2d_i.a_valid == 1'b0));
  end
  cover_Req_FirstEdge     : cover property (at_first_edge);
  if (DevSameCycleRsp) begin : gen_cover_same_cycle
    cover_Src_SameCycle     : cover property (d_fire && d_same_cycle);
    cover_Src_RspWhileWaits : cover property (d2h_i.d_valid && d_same_cycle && a_waits);
  end
  cover_Src_Reuse         : cover property (rsp_leaves ##1 a_fire && (a_src == $past(d_src)));
  cover_Src_Full          : cover property (num_outstanding_q == CntW'(DevMaxOutstanding));
  cover_Rsp_AckData       : cover property (d_fire && d_has_req && d_has_data);
  cover_Rsp_Ack           : cover property (d_fire && (d2h_i.d_opcode == AccessAck));
  cover_Rsp_Error         : cover property (d_fire && d2h_i.d_error);
  cover_Rsp_FromList      : cover property (d_fire && d_in_list);
  if (DevMaxOutstanding > 1 && !DevInOrderRsp) begin : gen_cover_out_of_order
    cover_Rsp_OutOfOrder    : cover property (d_fire && d_in_list && !d_names_oldest);
  end
  cover_Rsp_Waits         : cover property (d_waits);

  for (genvar s = 0; s <= MaxSize; s++) begin : gen_cover_size
    cover_Req_Size : cover property (a_fire && (h2d_i.a_size == SZW'(s)));
  end

  /////////////////
  // Spec events //
  /////////////////

  assign a_fire_o          = a_fire;
  assign d_fire_o          = d_fire;
  assign num_outstanding_o = num_outstanding_q;
  assign oldest_src_o      = outstanding_q[0].source;

endmodule
