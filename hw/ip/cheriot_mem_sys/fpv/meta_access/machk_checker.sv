// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Checker 2, the path to the meta SRAM: the four access checkers and the 4:1 arbiter between the
// requester ports and meta_sram_tl. Per port it counts and tracks requests and predicts the
// round-robin order; the properties compare the ports with the predictions, one section per
// testpoint: requests, answers and flow, then the contracts other checkers rely on. The rules at
// the end say what the neighbours send: a TL-UL ABVIP on each of the five ports the testbench
// plays, plus the rules this design needs on top (ENV_RULE: assumed in formal, asserted in
// simulation; the fairness rules exist in formal only). Four more ABVIPs check TL-UL on the links
// between the access checkers and the arbiter.
//
// Ports are named after the block at the other end; arrays are indexed by the port's arbiter
// input (InTrvk, InRmw, InXbar, InTbre); x_d is the next value of x_q.
`include "cheriot_mem_sys_fpv_rule.svh"

module machk_checker
  import tlul_pkg::*;
  import tlul_abvip_pkg::*;
  import machk_pkg::*;
#(
  localparam int unsigned NumPorts = 4
) (
  // Clock, reset and the mode
  input  logic                  clk_i,
  input  logic                  rst_ni,
  input  prim_mubi_pkg::mubi4_t cheriot_ena_i,
  // The four requester ports
  input  tl_h2d_t               trvk_h2d_i,
  input  tl_d2h_t               trvk_d2h_i,
  input  tl_h2d_t               rmw_h2d_i,
  input  tl_d2h_t               rmw_d2h_i,
  input  tl_h2d_t               xbar_h2d_i,
  input  tl_d2h_t               xbar_d2h_i,
  input  tl_h2d_t               tbre_h2d_i,
  input  tl_d2h_t               tbre_d2h_i,
  // The checked streams: the access checkers' outputs, the 4:1 arbiter's inputs
  input  tl_h2d_t               stream_h2d_i [NumPorts],
  input  tl_d2h_t               stream_d2h_i [NumPorts],
  // meta_sram_tl
  input  tl_h2d_t               meta_h2d_i,
  input  tl_d2h_t               meta_d2h_i
);

  // [TLUL] tlul_socket_m1, round robin over four inputs: at most three others before a waiting one.
  localparam int unsigned MaxOtherGrants = NumPorts - 1;

  // The testplan's example values, each by the case that uses it.
  localparam addr_t                 BitmapWord = 32'h1100_0100;  // tag port reads bitmap
  localparam addr_t                 TagWord    = 32'h1100_8C48;  // software reads tag word
  localparam src_t                  MetaSrc    = 8'h56;          // worked example
  localparam src_t                  WindowSrc  = 8'h15;          // worked example
  localparam src_t                  TopSrc     = 8'h3F;          // top source assumption A9 leaves
  localparam prim_mubi_pkg::mubi4_t EnaInvalid = prim_mubi_pkg::mubi4_t'(4'h0);  // invalid mode

  // The request each port's tracker follows: free in FPV, so the tool picks it; the next one in
  // simulation.
`ifdef FPV_ON
  /* verilator lint_off UNDRIVEN */
  logic [NumPorts-1:0] pick;
  /* verilator lint_on UNDRIVEN */
`else
  logic [NumPorts-1:0] pick;
  assign pick = '1;
`endif

  default clocking @(posedge clk_i); endclocking
  /* verilator lint_off SYNCASYNCNET */
  default disable iff (!rst_ni);
  /* verilator lint_on SYNCASYNCNET */

  /////////////////
  // Port events //
  /////////////////

  // The requester ports as arrays, by input.
  tl_h2d_t port_h2d [NumPorts];
  tl_d2h_t port_d2h [NumPorts];
  assign port_h2d[InTrvk] = trvk_h2d_i;
  assign port_d2h[InTrvk] = trvk_d2h_i;
  assign port_h2d[InRmw]  = rmw_h2d_i;
  assign port_d2h[InRmw]  = rmw_d2h_i;
  assign port_h2d[InXbar] = xbar_h2d_i;
  assign port_d2h[InXbar] = xbar_d2h_i;
  assign port_h2d[InTbre] = tbre_h2d_i;
  assign port_d2h[InTbre] = tbre_d2h_i;

  // [TLUL] Signals: a beat passes in a cycle where valid and ready are both high.
  ev_t port_ev   [NumPorts];
  ev_t stream_ev [NumPorts];
  ev_t meta_ev;
  for (genvar p = 0; p < NumPorts; p++) begin : gen_ev
    assign port_ev[p]   = ev_of(port_h2d[p], port_d2h[p]);
    assign stream_ev[p] = ev_of(stream_h2d_i[p], stream_d2h_i[p]);
  end
  assign meta_ev = ev_of(meta_h2d_i, meta_d2h_i);

  ////////////
  // Decode //
  ////////////

  logic ena;
  assign ena = is_ena(cheriot_ena_i);

  // The port a request on meta_sram_tl came from, and the port an answer there goes to.
  port_e meta_port, answer_port;
  assign meta_port   = port_of(meta_h2d_i.a_source);
  assign answer_port = port_of(meta_d2h_i.d_source);

  logic [NumPorts-1:0] legal;          // the request port p presents is legal
  logic [NumPorts-1:0] legal_vld;      // port p presents a legal request
  logic [NumPorts-1:0] others_legal;   // another port presents a legal request
  logic [NumPorts-1:0] meta_is_fwd;    // meta_sram_tl presents port p's request, forwarded
  logic [NumPorts-1:0] meta_req_from;  // meta_sram_tl presents a request that names port p
  logic [NumPorts-1:0] meta_rsp_to;    // meta_sram_tl presents an answer that names port p
  /* verilator lint_off UNUSEDSIGNAL */
  logic [NumPorts-1:0] req_settled;    // port p's request is taken, or withdrawn
  logic [$bits(tl_h2d_t)-3:0] req_fields [NumPorts];  // the A fields port p presents
  /* verilator lint_on UNUSEDSIGNAL */
  for (genvar p = 0; p < NumPorts; p++) begin : gen_decode
    assign legal[p]         = is_legal(port_e'(p), port_h2d[p], ena);
    assign legal_vld[p]     = port_ev[p].req_vld && legal[p];
    assign others_legal[p]  = |(legal_vld & ~(NumPorts'(1) << p));
    assign meta_is_fwd[p]   = is_same_a_but_source(meta_h2d_i, port_h2d[p]) &&
                              (meta_h2d_i.a_source == fwd_source(port_h2d[p].a_source, port_e'(p)));
    assign meta_req_from[p] = meta_ev.req_vld && (meta_port == port_e'(p));
    assign meta_rsp_to[p]   = meta_ev.rsp_vld && (answer_port == port_e'(p));
    assign req_settled[p]   = port_ev[p].req_taken || !port_ev[p].req_vld;
    assign req_fields[p]    = a_fields(port_h2d[p]);
  end

  ///////////////////////////////////////
  // cover_terms: what the covers name //
  ///////////////////////////////////////

  // A request is taken on some port.
  logic any_taken;
  assign any_taken = port_ev[InTrvk].req_taken || port_ev[InRmw].req_taken ||
                     port_ev[InXbar].req_taken || port_ev[InTbre].req_taken;

  // Per port, a request taken that is legal but for one condition ([TP] meta_refuse, Cases).
  logic [NumPorts-1:0] full_get;       // a full-word Get in CHERIoT mode
  logic [NumPorts-1:0] taken_no_mode;  // legal but for the mode
  logic [NumPorts-1:0] taken_top, taken_below, taken_byte, taken_half, taken_partial;
  for (genvar p = 0; p < NumPorts; p++) begin : gen_cover_terms
    logic in_mode, in_own, word_op;
    assign in_mode = port_ev[p].req_taken && ena;
    assign in_own  = in_mode && in_region(port_e'(p), port_h2d[p].a_address);
    assign word_op = is_full_word(port_h2d[p]) && is_get_or_put_full(port_h2d[p]);
    assign full_get[p]      = in_mode && is_full_word(port_h2d[p]) &&
                              (port_h2d[p].a_opcode == Get);
    assign taken_no_mode[p] = port_ev[p].req_taken && !ena && word_op &&
                              in_region(port_e'(p), port_h2d[p].a_address);
    assign taken_top[p]     = in_mode && word_op && (port_h2d[p].a_address == MetaTop);
    assign taken_below[p]   = in_mode && word_op && (port_h2d[p].a_address == MetaBase - 32'd4);
    assign taken_byte[p]    = in_own && (port_h2d[p].a_opcode == Get) &&
                              (port_h2d[p].a_size == 2'd0);
    assign taken_half[p]    = in_own && (port_h2d[p].a_opcode == Get) &&
                              (port_h2d[p].a_size == 2'd1);
    assign taken_partial[p] = in_own && (port_h2d[p].a_opcode == PutPartialData) &&
                              (port_h2d[p].a_size == 2'd2) && (port_h2d[p].a_mask == 4'hF);
  end

  ///////////////////////////////////////////////
  // counts: requests outstanding on each port //
  ///////////////////////////////////////////////

  // Requests taken on port p whose answers were not yet taken there.
  cnt_t outstanding_q [NumPorts], outstanding_d [NumPorts];
  for (genvar p = 0; p < NumPorts; p++) begin : gen_out
    assign outstanding_d[p] = outstanding_q[p] + cnt_t'(port_ev[p].req_taken) -
                              cnt_t'(port_ev[p].rsp_taken);

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) outstanding_q[p] <= '0;
      else         outstanding_q[p] <= outstanding_d[p];
    end
  end

  ////////////////////////////////////
  // trackers: one request per port //
  ////////////////////////////////////

  // One tracker per port: the picked request, from taken until its answer is taken (TL08).
  trk_e                trk_q [NumPorts], trk_d [NumPorts];
  src_t                trk_src_q [NumPorts], trk_src_d [NumPorts];
  logic [NumPorts-1:0] trk_legal_q, trk_legal_d;  // it was legal
  logic [NumPorts-1:0] trk_start;                 // the tracked request is taken now
  logic [NumPorts-1:0] trk_live;                  // a tracked request exists in this cycle
  src_t                trk_src [NumPorts];
  logic [NumPorts-1:0] trk_legal;
  logic [NumPorts-1:0] trk_rsp;                   // its answer is presented
  logic [NumPorts-1:0] trk_end;                   // its answer is taken
  for (genvar p = 0; p < NumPorts; p++) begin : gen_trk
    assign trk_start[p]   = (trk_q[p] == TrkIdle) && pick[p] && port_ev[p].req_taken;
    assign trk_live[p]    = (trk_q[p] == TrkOn) || trk_start[p];
    assign trk_src[p]     = (trk_q[p] == TrkOn) ? trk_src_q[p] : port_h2d[p].a_source;
    assign trk_legal[p]   = (trk_q[p] == TrkOn) ? trk_legal_q[p] : legal[p];
    assign trk_rsp[p]     = trk_live[p] && port_ev[p].rsp_vld &&
                            (port_d2h[p].d_source == trk_src[p]);
    assign trk_end[p]     = trk_rsp[p] && port_ev[p].rsp_taken;
    assign trk_d[p]       = (trk_live[p] && !trk_end[p]) ? TrkOn : TrkIdle;
    assign trk_src_d[p]   = trk_start[p] ? port_h2d[p].a_source : trk_src_q[p];
    assign trk_legal_d[p] = trk_start[p] ? legal[p] : trk_legal_q[p];

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        trk_q[p]       <= TrkIdle;
        trk_src_q[p]   <= '0;
        trk_legal_q[p] <= 1'b0;
      end else begin
        trk_q[p]       <= trk_d[p];
        trk_src_q[p]   <= trk_src_d[p];
        trk_legal_q[p] <= trk_legal_d[p];
      end
    end
  end

  // Contract C10: the tag port's requests still unanswered when its tracked request was taken.
  cnt_t rmw_ahead_q, rmw_ahead_d;
  cnt_t rmw_ahead_start;  // at its acceptance: the older ones, less one answered in that cycle
  logic rmw_older_taken;  // an answer that is not the tracked request's is taken on the tag port
  assign rmw_older_taken = port_ev[InRmw].rsp_taken && !trk_rsp[InRmw];
  assign rmw_ahead_start = outstanding_q[InRmw] - cnt_t'(rmw_older_taken);
  assign rmw_ahead_d     = trk_start[InRmw]                       ? rmw_ahead_start    :
                           rmw_older_taken && (rmw_ahead_q != '0) ? rmw_ahead_q - 1'b1 :
                                                                    rmw_ahead_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) rmw_ahead_q <= '0;
    else         rmw_ahead_q <= rmw_ahead_d;
  end

  ///////////////////////////////////////////////
  // round_robin: grants while a request waits //
  ///////////////////////////////////////////////

  // Round robin: requests of the other inputs taken while checked stream i's request waits.
  logic [1:0]          others_q [NumPorts], others_d [NumPorts];
  logic [NumPorts-1:0] stream_waits;   // checked stream i presents a request not taken
  logic [NumPorts-1:0] other_taken;    // meta_sram_tl takes another input's request
  for (genvar i = 0; i < NumPorts; i++) begin : gen_rr
    logic below_max;  // the count can still grow
    assign below_max       = others_q[i] != 2'(MaxOtherGrants);
    assign stream_waits[i] = stream_ev[i].req_vld && !stream_ev[i].req_taken;
    assign other_taken[i]  = meta_ev.req_taken && (meta_port != port_e'(i));
    assign others_d[i]     = !stream_waits[i]            ? 2'd0               :
                             other_taken[i] && below_max ? others_q[i] + 2'd1 :
                                                           others_q[i];

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) others_q[i] <= '0;
      else         others_q[i] <= others_d[i];
    end
  end

  /////////////////////////////////////////////////////////////////////////
  // meta_forward: a legal request reaches the meta SRAM once, unchanged //
  /////////////////////////////////////////////////////////////////////////

  for (genvar p = 0; p < NumPorts; p++) begin : gen_fwd
    // A legal request taken on port p is taken on meta_sram_tl in the same cycle, as forwarded.
    // meta_forward: legal request forwarded (CHK_META_FORWARD_01)
    assert_MetaReq_LegalReqForwarded : assert property (port_ev[p].req_taken && legal[p] |->
      meta_ev.req_taken && meta_req_from[p] && meta_is_fwd[p]);
    // A legal request alone among the ports is on meta_sram_tl in the cycle it is presented.
    // meta_forward: legal request forwarded (CHK_META_FORWARD_01)
    assert_MetaReq_AloneSameCycle : assert property (legal_vld[p] && !others_legal[p] |->
      meta_req_from[p] && meta_is_fwd[p]);
    // A request on meta_sram_tl naming port p is port p's request, forwarded, taken with it.
    // meta_forward: no extra meta SRAM request (CHK_META_FORWARD_02)
    assert_MetaReq_FromNamedPort : assert property (meta_req_from[p] |->
      port_ev[p].req_vld && meta_is_fwd[p] && (meta_ev.req_taken == port_ev[p].req_taken));

    // A legal Get is taken on each port.
    // meta_forward: case legal Get
    cover_MetaReq_LegalGet : cover property (port_ev[p].req_taken && legal[p] &&
      (port_h2d[p].a_opcode == Get));
    // A legal PutFullData is taken on each port.
    // meta_forward: case legal Put
    cover_MetaReq_LegalPut : cover property (port_ev[p].req_taken && legal[p] &&
      (port_h2d[p].a_opcode == PutFullData));
    // A legal request to the first word of its port's region is taken on each port.
    // meta_forward: edge case region first word
    cover_MetaReq_RegionFirstWord : cover property (port_ev[p].req_taken && legal[p] &&
      (port_h2d[p].a_address == region_first(port_e'(p))));
    // A legal request to the last word of its port's region is taken on each port.
    // meta_forward: edge case region last word
    cover_MetaReq_RegionLastWord : cover property (port_ev[p].req_taken && legal[p] &&
      (port_h2d[p].a_address == region_last(port_e'(p))));
  end

  // Two ports present legal requests in the same cycle.
  // meta_forward: case two ports at once
  cover_MetaReq_TwoPortsAtOnce : cover property ($countones(legal_vld) == 2);
  // Three ports present legal requests in the same cycle.
  // meta_forward: case three ports at once
  cover_MetaReq_ThreePortsAtOnce : cover property ($countones(legal_vld) == 3);
  // All four ports present legal requests in the same cycle.
  // meta_forward: case four ports at once
  cover_MetaReq_FourPortsAtOnce : cover property ($countones(legal_vld) == 4);

  ////////////////////////////////////////////////////////////////////////////////
  // meta_refuse: an illegal request is answered with an error, never forwarded //
  ////////////////////////////////////////////////////////////////////////////////

  // A request on meta_sram_tl lies in the region of the port it came from.
  // meta_refuse: in own region (CHK_META_REFUSE_01)
  assert_MetaRefuse_InOwnRegion : assert property (meta_ev.req_vld |->
    in_region(meta_port, meta_h2d_i.a_address));
  // Every request on meta_sram_tl comes in CHERIoT mode.
  // meta_refuse: only in CHERIoT mode (CHK_META_REFUSE_02)
  assert_MetaRefuse_OnlyInCheriotMode : assert property (meta_ev.req_vld |-> ena);
  // Every request on meta_sram_tl is a full-word access.
  // meta_refuse: only full words (CHK_META_REFUSE_03)
  assert_MetaRefuse_OnlyFullWord : assert property (meta_ev.req_vld |-> is_full_word(meta_h2d_i));
  // Every request on meta_sram_tl is a Get or a PutFullData.
  // meta_refuse: only Get or PutFullData (CHK_META_REFUSE_04)
  assert_MetaRefuse_OnlyGetOrPut : assert property (meta_ev.req_vld |->
    is_get_or_put_full(meta_h2d_i));

  for (genvar p = 0; p < NumPorts; p++) begin : gen_refuse
    // The answer to a request that is not legal carries d_error.
    // meta_refuse: illegal request gets error (CHK_META_REFUSE_05)
    assert_MetaRefuse_IllegalGetsErr : assert property (trk_rsp[p] && !trk_legal[p] |->
      port_d2h[p].d_error);
    // That answer carries a valid response integrity and, for a Get, a valid data integrity: a
    // denial software can cause must not become an integrity fault at the requester.
    // meta_refuse: error answer carries valid integrity (CHK_META_REFUSE_06)
    assert_MetaRefuse_ErrRspIntgValid : assert property (trk_rsp[p] && !trk_legal[p] |->
      (port_d2h[p].d_user.rsp_intg == get_rsp_intg(port_d2h[p])) &&
      ((port_d2h[p].d_opcode != AccessAckData) ||
       (port_d2h[p].d_user.data_intg == get_data_intg(port_d2h[p].d_data))));

    // One cover per truth table row r and port p.
    for (genvar r = 0; r < 16; r++) begin : gen_row
      // A request of each legality truth table row is taken on each port.
      // meta_refuse: truth table
      cover_MetaRefuse_TruthTableRow : cover property (port_ev[p].req_taken &&
        (legal_row(port_e'(p), port_h2d[p], ena) == 4'(r)));
    end
    // A full-word Get of the bitmap's last word, 0x1100_0BFC, is taken on each port.
    // meta_refuse: edge case bitmap last word
    cover_MetaRefuse_BitmapLastWord : cover property (full_get[p] &&
      (port_h2d[p].a_address == TagBase - 32'd4));
    // A full-word Get of the first tag word, 0x1100_0C00, is taken on each port.
    // meta_refuse: edge case tag first word
    cover_MetaRefuse_TagFirstWord : cover property (full_get[p] &&
      (port_h2d[p].a_address == TagBase));
    // A refused request on each port is answered a cycle or more after it was taken.
    // meta_refuse: edge case Late answer
    cover_MetaRefuse_LateRsp : cover property ((trk_q[p] == TrkOn) && trk_end[p] &&
      !trk_legal_q[p]);
  end

  // A request is taken with cheriot_ena_i at MuBi4False.
  // meta_refuse: case ePMP mode
  cover_MetaRefuse_ModeFalse : cover property (|taken_no_mode &&
    (cheriot_ena_i == prim_mubi_pkg::MuBi4False));
  // A request is taken with cheriot_ena_i at the invalid value 4'h0.
  // meta_refuse: case invalid mode
  cover_MetaRefuse_ModeInvalid : cover property (|taken_no_mode &&
    (cheriot_ena_i == EnaInvalid));
  // The tag port reads the bitmap word 0x1100_0100 with a full-word Get.
  // meta_refuse: case tag port reads bitmap
  cover_MetaRefuse_RmwReadsBitmap : cover property (full_get[InRmw] &&
    (port_h2d[InRmw].a_address == BitmapWord));
  // Port revbm_tl_d reads the tag word 0x1100_8C48 with a full-word Get.
  // meta_refuse: case software reads tag word
  cover_MetaRefuse_XbarReadsTag : cover property (full_get[InXbar] &&
    (port_h2d[InXbar].a_address == TagWord));
  // A request to the meta SRAM top, 0x1100_9800, is taken on some port.
  // meta_refuse: case outside the meta SRAM
  cover_MetaRefuse_AboveRegion : cover property (|taken_top);
  // A request just below the meta SRAM base, 0x10FF_FFFC, is taken on some port.
  // meta_refuse: case outside the meta SRAM
  cover_MetaRefuse_BelowRegion : cover property (|taken_below);
  // A one-byte Get, a_size 0, is taken on some port.
  // meta_refuse: case sub-word Get
  cover_MetaRefuse_ByteAccess : cover property (|taken_byte);
  // A two-byte Get, a_size 1, is taken on some port.
  // meta_refuse: case sub-word Get
  cover_MetaRefuse_HalfWordAccess : cover property (|taken_half);
  // A PutPartialData of all four bytes is taken on some port.
  // meta_refuse: case partial Put
  cover_MetaRefuse_PartialPut : cover property (|taken_partial);

  //////////////////////////////////////////////////////////////////
  // tag_isolation: the tag store is reached only by the tag path //
  //////////////////////////////////////////////////////////////////

  // A request on meta_sram_tl from the tag port lies in 0x1100_0C00-0x1100_97FF.
  // tag_isolation: tag port in tag regions (CHK_TAG_ISOLATION_01)
  assert_TagIsolation_InTagRegions : assert property (meta_req_from[InRmw] |->
    is_tag_region(meta_h2d_i.a_address));
  // A request on meta_sram_tl from the tag port comes only in CHERIoT mode.
  // tag_isolation: tag port only in CHERIoT mode (CHK_TAG_ISOLATION_02)
  assert_TagIsolation_OnlyInCheriotMode : assert property (meta_req_from[InRmw] |-> ena);
  // A request on meta_sram_tl from any other port lies outside 0x1100_0C00-0x1100_97FF.
  // tag_isolation: other ports never reach tags (CHK_TAG_ISOLATION_03)
  assert_TagIsolation_OtherPortsNoTags : assert property (meta_ev.req_vld &&
    !meta_req_from[InRmw] |->
    !is_tag_region(meta_h2d_i.a_address));

  // One cover per cheriot_ena_i value v.
  for (genvar v = 0; v < 16; v++) begin : gen_tag_ena
    // A tag port request is taken with each of the 16 cheriot_ena_i values.
    // tag_isolation: case every mode value
    cover_TagIsolation_EveryModeValue : cover property (port_ev[InRmw].req_taken &&
      (cheriot_ena_i == prim_mubi_pkg::mubi4_t'(v)));
  end
  // Port revbm_tl_d has a request to the first tag word, 0x1100_0C00, taken.
  // tag_isolation: case software at first tag word
  cover_TagIsolation_XbarFirstTagWord : cover property (port_ev[InXbar].req_taken &&
    (port_h2d[InXbar].a_address == TagBase));
  // Port revbm_tl_d has a request to the tag word 0x1100_8C48 taken.
  // tag_isolation: case software at middle tag word
  cover_TagIsolation_XbarMidTagWord : cover property (port_ev[InXbar].req_taken &&
    (port_h2d[InXbar].a_address == TagWord));
  // Port revbm_tl_d has a request to the last tag word, 0x1100_97FC, taken.
  // tag_isolation: case software at last tag word
  cover_TagIsolation_XbarLastTagWord : cover property (port_ev[InXbar].req_taken &&
    (port_h2d[InXbar].a_address == MetaTop - 32'd4));
  // Port corerevbm_tl has a request to the first tag word, 0x1100_0C00, taken.
  // tag_isolation: case core TRVK at tag word
  cover_TagIsolation_TrvkFirstTagWord : cover property (port_ev[InTrvk].req_taken &&
    (port_h2d[InTrvk].a_address == TagBase));
  // The engine's bitmap port has a request to the first tag word, 0x1100_0C00, taken.
  // tag_isolation: case engine at tag word
  cover_TagIsolation_TbreFirstTagWord : cover property (port_ev[InTbre].req_taken &&
    (port_h2d[InTbre].a_address == TagBase));

  //////////////////////////////////////////////////////////////
  // meta_return: each answer to its own requester, unchanged //
  //////////////////////////////////////////////////////////////

  for (genvar p = 0; p < NumPorts; p++) begin : gen_ret
    // An answer on meta_sram_tl with d_source = s is presented at port s & 3 in the same cycle.
    // meta_return: answer to its port (CHK_META_RETURN_01)
    assert_MetaRsp_ToItsPort : assert property (meta_rsp_to[p] |-> port_ev[p].rsp_vld);
    // The answer at the port carries d_source shifted right by two.
    // meta_return: source shifted back (CHK_META_RETURN_02)
    assert_MetaRsp_SourceShiftedBack : assert property (meta_rsp_to[p] |->
      port_d2h[p].d_source == ret_source(meta_d2h_i.d_source));
    // Every other D-channel field reaches the port unchanged.
    // meta_return: fields unchanged (CHK_META_RETURN_03)
    assert_MetaRsp_FieldsUnchanged : assert property (meta_rsp_to[p] |->
      is_same_d_but_source(port_d2h[p], meta_d2h_i));
    // The meta SRAM's answer is taken exactly when its port takes it.
    // meta_return: taken with its port (CHK_META_RETURN_04)
    assert_MetaRsp_TakenWithPort : assert property (meta_rsp_to[p] |->
      meta_h2d_i.d_ready == port_h2d[p].d_ready);
    // The answer at port p to a legal request is the meta SRAM's answer to it.
    // meta_return: only the meta SRAM's answer (CHK_META_RETURN_05)
    assert_MetaRsp_IsMetaSramRsp : assert property (trk_rsp[p] && trk_legal[p] |->
      meta_ev.rsp_vld && (meta_d2h_i.d_source == fwd_source(trk_src[p], port_e'(p))));
    // Each port takes a meta SRAM answer.
    // meta_return: case answer to each port
    cover_MetaRsp_ToEachPort : cover property (meta_rsp_to[p] && meta_ev.rsp_taken);
    // A legal request on each port is answered a cycle or more after it was taken.
    // meta_return: case late answer
    cover_MetaRsp_LateRsp : cover property ((trk_q[p] == TrkOn) && trk_end[p] &&
      trk_legal_q[p]);
  end
  // Answers go to the tag port and then to the engine's port in consecutive cycles.
  // meta_return: case ports back to back
  cover_MetaRsp_PortsBackToBack : cover property ((meta_ev.rsp_taken && meta_rsp_to[InRmw]) ##1
    (meta_ev.rsp_taken && meta_rsp_to[InTbre]));
  // An answer with d_source 0x56 returns to port 2 as 0x15.
  // meta_return: case worked example
  cover_MetaRsp_WorkedExample : cover property (meta_ev.rsp_taken &&
    (meta_d2h_i.d_source == MetaSrc) && port_ev[InXbar].rsp_vld &&
    (port_d2h[InXbar].d_source == WindowSrc));
  // An answer returns d_source 0x3F, every bit a port may use; the top two bits stay free.
  // meta_return: edge case source top bits
  cover_MetaRsp_SourceTopBit : cover property (meta_ev.rsp_taken &&
    (ret_source(meta_d2h_i.d_source) == TopSrc));
  // An answer with d_error is taken.
  // meta_return: edge case error answer
  cover_MetaRsp_ErrRsp : cover property (meta_ev.rsp_taken && meta_d2h_i.d_error);
  // An answer with a broken response integrity is taken.
  // meta_return: edge case bad response integrity
  cover_MetaRsp_BadRspIntg : cover property (meta_ev.rsp_taken &&
    !is_rsp_intg_ok(meta_d2h_i));

  ////////////////////////////////////////////////////
  // meta_flow: round robin, every request answered //
  ////////////////////////////////////////////////////

  for (genvar i = 0; i < NumPorts; i++) begin : gen_flow
    localparam port_e Next1 = port_e'((i + 1) % NumPorts);
    localparam port_e Next2 = port_e'((i + 2) % NumPorts);
    localparam port_e Next3 = port_e'((i + 3) % NumPorts);
    // While stream i waits, the other streams get at most MaxOtherGrants grants.
    // meta_flow: round robin bound (CHK_META_FLOW_01)
    assert_MetaFlow_RoundRobinBound : assert property (stream_waits[i] && other_taken[i] |->
      others_q[i] != 2'(MaxOtherGrants));
    // Stream i waits while each other stream is granted once, then is granted itself.
    // meta_flow: case waits for three
    cover_MetaFlow_WaitsForThree : cover property (
      (stream_waits[i] && meta_ev.req_taken && (meta_port == Next1)) ##1
      (stream_waits[i] && meta_ev.req_taken && (meta_port == Next2)) ##1
      (stream_waits[i] && meta_ev.req_taken && (meta_port == Next3)) ##1
      stream_ev[i].req_taken);
  end
  // All four host ports of the arbiter present requests in the same cycle.
  // meta_flow: case all four present
  cover_MetaFlow_AllFourPresent : cover property (stream_ev[InTrvk].req_vld &&
    stream_ev[InRmw].req_vld && stream_ev[InXbar].req_vld && stream_ev[InTbre].req_vld);

  // Formal only, in task_MetaAccess_Main: a held request is accepted, with only the meta SRAM's
  // acceptance assumed. A request ends taken, withdrawn or changed: only a held one must be
  // accepted ([TL] §5.1).
`ifdef FPV_ON
`ifndef VERILATOR
  for (genvar p = 0; p < NumPorts; p++) begin : gen_live_a_flow
    // A request on a requester port is accepted at some point, unless withdrawn or changed first.
    // meta_flow: request eventually accepted (CHK_META_FLOW_04)
    assert_MetaFlow_ReqEventuallyAccepted : assert property (port_ev[p].req_vld |->
      s_eventually (req_settled[p] || !$stable(req_fields[p])));
  end
`endif
`endif
  // Formal only, in task_MetaAccess_MetaRspInOrder: every accepted request is answered, with
  // assumption A10 in full and contracts C4, C5.
`ifdef FPV_ON
`ifndef VERILATOR
  for (genvar p = 0; p < NumPorts; p++) begin : gen_live_b_flow
    // Every accepted request is answered, at some point.
    // meta_flow: request eventually answered (CHK_META_FLOW_03)
    assert_MetaFlow_ReqEventuallyAnswered : assert property ((trk_q[p] == TrkOn) |->
      s_eventually trk_rsp[p]);
  end
`endif
`endif

  ////////////////////////////////////
  // contracts: proven in checker 2 //
  ////////////////////////////////////

  // On the tag port, an answer comes only while a request is outstanding, never early.
  // contracts: tag port answers in order (contract C10) (CHK_CONTRACTS_11)
  assert_Contracts_TagsRspLater : assert property (port_ev[InRmw].rsp_vld |->
    outstanding_q[InRmw] != '0);
  // On the tag port, the tracked request is answered exactly when no older request is unanswered.
  // contracts: tag port answers in order (contract C10) (CHK_CONTRACTS_11)
  assert_Contracts_TagsRspInOrder : assert property ((trk_q[InRmw] == TrkOn) &&
    port_ev[InRmw].rsp_vld |->
    (port_d2h[InRmw].d_source == trk_src_q[InRmw]) == (rmw_ahead_q == '0));
  // On the tag port, an answer not taken stays offered and unchanged.
  // contracts: tag port answers in order (contract C10) (CHK_CONTRACTS_11)
  assert_Contracts_TagsRspHeld : assert property (port_ev[InRmw].rsp_vld &&
    !port_ev[InRmw].rsp_taken |=>
    port_ev[InRmw].rsp_vld && is_same_d(port_d2h[InRmw], $past(port_d2h[InRmw])));
  // Cover tag port answer waits: an answer on the tag port waits to be taken.
  // contracts: tag port answers in order (contract C10) (CHK_CONTRACTS_11)
  cover_Contracts_TagsRspWaits : cover property (port_ev[InRmw].rsp_vld &&
    !port_ev[InRmw].rsp_taken);
  // Cover older answer first: an older answer is taken on the tag port while the tracked one waits.
  // contracts: tag port answers in order (contract C10) (CHK_CONTRACTS_11)
  cover_Contracts_OlderRspFirst : cover property ((trk_q[InRmw] == TrkOn) &&
    (rmw_ahead_q != '0) && port_ev[InRmw].rsp_taken);
  // Cover tracked answer last: the tracked request's answer comes with no older one left.
  // contracts: tag port answers in order (contract C10) (CHK_CONTRACTS_11)
  cover_Contracts_TrackedRspLast : cover property ((trk_q[InRmw] == TrkOn) &&
    (rmw_ahead_q == '0) && trk_end[InRmw]);

  // Contract C1: a request is taken unless withdrawn or changed ([TL] §5.1); answers come. The
  // asserts are formal only, with assumption A10 in full and contracts C4, C5.
  for (genvar p = 0; p < NumPorts; p++) begin : gen_c1
    // A request waits on a requester port.
    // contracts: access request accepted and answered (contract C1) (CHK_CONTRACTS_01)
    cover_Contracts_AccessReqWaiting : cover property (port_ev[p].req_vld && !port_ev[p].req_taken);
  end
`ifdef FPV_ON
`ifndef VERILATOR
  for (genvar p = 0; p < NumPorts; p++) begin : gen_live_b_c1
    // On each requester port, a request held is accepted, unless withdrawn or changed.
    // contracts: access request accepted and answered (contract C1) (CHK_CONTRACTS_01)
    assert_Contracts_AccessReqAccepted : assert property (port_ev[p].req_vld |->
      s_eventually (req_settled[p] || !$stable(req_fields[p])));
    // On each requester port, while requests are outstanding, an answer comes.
    // contracts: access request accepted and answered (contract C1) (CHK_CONTRACTS_01)
    assert_Contracts_AccessReqAnswered : assert property (outstanding_q[p] != '0 |->
      s_eventually port_ev[p].rsp_vld);
  end
`endif
`endif

  /////////////////////////////////////////////////////////////////////////////
  // rules: what the neighbours send (assumed in FPV, checked in simulation) //
  /////////////////////////////////////////////////////////////////////////////

  // A TL-UL ABVIP on each of the five ports the testbench plays, and the rules on top of them,
  // each naming its assumption (designer review) or contract. FPV: the ABVIP plays that end
  // (its rules assumed, the design's asserted) and ENV_RULE assumes. Simulation: the real
  // neighbour drives the port, so the ABVIP asserts both ends and ENV_RULE asserts. Liveness: the
  // ABVIPs' TL17-TL19 ([TL] §5), formal only, copied by task_MetaAccess_MetaRspInOrder; on the rmw
  // and tbre ports TL17 is contracts C4, C5.
`ifdef FPV_ON
  localparam role_e HostRole   = PlayHost;
  localparam role_e DeviceRole = PlayDevice;
`else
  localparam role_e HostRole   = CheckBoth;
  localparam role_e DeviceRole = CheckBoth;
`endif

  logic [8:0] meta_num_out;
  logic [7:0] meta_oldest;

  /* verilator lint_off PINCONNECTEMPTY */
  // The four requesters, SrcW 6: the 4:1 arbiter keeps six bits of a_source ([TLUL], TL08).
  tlul_abvip #(.Role(HostRole), .SrcW(SrcW), .Liveness(1'b1)) u_abvip_trvk (
    .clk_i, .rst_ni, .h2d_i(trvk_h2d_i), .d2h_i(trvk_d2h_i),
    .a_fire_o(), .d_fire_o(), .num_outstanding_o(), .oldest_src_o());

  // The tag port's and the engine's hosts are cut: their host rules are the proposed contracts
  // C12 and C13.
  tlul_abvip #(.Role(HostRole), .SrcW(SrcW), .Liveness(1'b1)) u_abvip_rmw (
    .clk_i, .rst_ni, .h2d_i(rmw_h2d_i), .d2h_i(rmw_d2h_i),
    .a_fire_o(), .d_fire_o(), .num_outstanding_o(), .oldest_src_o());

  tlul_abvip #(.Role(HostRole), .SrcW(SrcW), .Liveness(1'b1)) u_abvip_xbar (
    .clk_i, .rst_ni, .h2d_i(xbar_h2d_i), .d2h_i(xbar_d2h_i),
    .a_fire_o(), .d_fire_o(), .num_outstanding_o(), .oldest_src_o());

  tlul_abvip #(.Role(HostRole), .SrcW(SrcW), .Liveness(1'b1)) u_abvip_tbre (
    .clk_i, .rst_ni, .h2d_i(tbre_h2d_i), .d2h_i(tbre_d2h_i),
    .a_fire_o(), .d_fire_o(), .num_outstanding_o(), .oldest_src_o());

  // meta_sram_tl: the meta SRAM. MaxOutstanding stays at 256, which only sizes the list.
  tlul_abvip #(.Role(DeviceRole), .Liveness(1'b1)) u_abvip_meta (
    .clk_i, .rst_ni, .h2d_i(meta_h2d_i), .d2h_i(meta_d2h_i),
    .a_fire_o(), .d_fire_o(), .num_outstanding_o(meta_num_out), .oldest_src_o(meta_oldest));
  /* verilator lint_on PINCONNECTEMPTY */

  // The TRVK filter's a_source keeps its top two bits 0 for the 4:1 arbiter.
  // assumption A9
  `ENV_RULE(assume_Env_TrvkSourceLow, trvk_h2d_i.a_valid |->
    trvk_h2d_i.a_source[top_pkg::TL_AIW-1 -: 2] == 2'b00)
  // xbar_main's bitmap a_source keeps its top two bits 0 for the 4:1 arbiter.
  // assumption A9
  `ENV_RULE(assume_Env_XbarSourceLow, xbar_h2d_i.a_valid |->
    xbar_h2d_i.a_source[top_pkg::TL_AIW-1 -: 2] == 2'b00)
  // The RMW filter's a_source keeps its top two bits 0 for the 4:1 arbiter.
  // contract C12, proposed
  `ENV_RULE(assume_Contracts_RmwSourceLow, rmw_h2d_i.a_valid |->
    rmw_h2d_i.a_source[top_pkg::TL_AIW-1 -: 2] == 2'b00)
  // The engine's bitmap a_source keeps its top two bits 0 for the 4:1 arbiter.
  // contract C13, proposed
  `ENV_RULE(assume_Contracts_TbreSourceLow, tbre_h2d_i.a_valid |->
    tbre_h2d_i.a_source[top_pkg::TL_AIW-1 -: 2] == 2'b00)

  // The CHERIoT mode keeps its value from reset.
  // assumption A6
  `ENV_RULE(assume_Env_ModeStable, $stable(cheriot_ena_i))

  // The meta SRAM answer rules (assumption A16): answers come later, in request order, held until
  // taken. Only the task that proves the in-order contract copies them: the main task must not
  // rely on an answer order that no spec rule states yet (raised with the designers).

  // The meta SRAM answers only while a request is outstanding.
  // assumption A16
  `ENV_RULE(assume_Env_MetaRspLater, meta_d2h_i.d_valid |-> meta_num_out != '0)
  // The meta SRAM answers in request order.
  // assumption A16
  `ENV_RULE(assume_Env_MetaRspInOrder, meta_d2h_i.d_valid |->
    meta_d2h_i.d_source == meta_oldest)
  // The meta SRAM holds an answer, unchanged, until it is taken.
  // assumption A16
  `ENV_RULE(assume_Env_MetaRspHeld, meta_d2h_i.d_valid && !meta_h2d_i.d_ready |=>
    meta_d2h_i.d_valid && is_same_d(meta_d2h_i, $past(meta_d2h_i)))

  // Assumption A10's acceptance half, in both tasks: the meta SRAM accepts every request offered,
  // with no exemption, which is the held-request requirement's condition as written (whether the
  // spec means an exemption is raised with the designers). Formal only: a simulation ends, so an
  // eventuality still open at its end proves nothing.
`ifdef FPV_ON
`ifndef VERILATOR
  // The meta SRAM accepts every request offered, at some point.
  // assumption A10
  assume_Env_MetaAcceptsReq : assume property (meta_h2d_i.a_valid |->
    s_eventually meta_d2h_i.a_ready);
`endif
`endif

  ///////////////////////////////////////////////////////////
  // environment: every assumption of checker 2 can be met //
  ///////////////////////////////////////////////////////////

  // One cover per cheriot_ena_i value v, with a request taken on some port.
  for (genvar v = 0; v < 16; v++) begin : gen_env_ena
    // A request is accepted with each of the 16 cheriot_ena_i values.
    // environment: case every mode value, for assumption A6
    cover_Env_EveryModeValue : cover property (any_taken &&
      (cheriot_ena_i == prim_mubi_pkg::mubi4_t'(v)));
  end
  // One cover per port p: a request with the top source assumption A9 and contracts C12, C13 leave.
  for (genvar p = 0; p < NumPorts; p++) begin : gen_env_src
    // A request with a_source 0x3F, the top source left free, is taken on each port.
    // environment: case source top bit, for assumption A9
    cover_Env_SourceTopBit : cover property (port_ev[p].req_taken &&
      (port_h2d[p].a_source == TopSrc));
  end
  // An answer on the tag port is taken.
  // environment: case contract witness, for contract C4
  cover_Env_TagsRspTaken : cover property (port_ev[InRmw].rsp_taken);
  // An answer on the engine's bitmap port is taken.
  // environment: case contract witness, for contract C5
  cover_Env_BitmapRspTaken : cover property (port_ev[InTbre].rsp_taken);

  ////////////////////////////////////////
  // TL-UL rules on the checked streams //
  ////////////////////////////////////////

  // tlul_protocol, TL-UL rules hold, on the checked streams: CheckBoth assumes nothing; SrcW 6.
  /* verilator lint_off PINCONNECTEMPTY */
  for (genvar i = 0; i < NumPorts; i++) begin : gen_stream_abvip
    tlul_abvip #(.Role(CheckBoth), .SrcW(SrcW)) u_abvip_stream (
      .clk_i, .rst_ni, .h2d_i(stream_h2d_i[i]), .d2h_i(stream_d2h_i[i]),
      .a_fire_o(), .d_fire_o(), .num_outstanding_o(), .oldest_src_o());
  end
  /* verilator lint_on PINCONNECTEMPTY */

endmodule
