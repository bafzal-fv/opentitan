// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// A model of the RMW filter, written from the spec, one operation at a time. A read of tag bit b
// becomes a Get of the meta word W and answers Bit(W, b). A write of tag t becomes the same Get
// and, only when the bit would change, a write-back of Upd(W, b, t); then the answer. The
// properties compare the filter's two ports with these outputs.
//
// One state, step_q, says how far the operation op_q got: its Get owed, its Get's answer awaited,
// W known, its write-back's answer awaited, that answer arrived. A downstream answer counts in the
// cycle it arrives; none arrives in the cycle the operation is accepted (contract C10).
//
// Signal names: upstream_op is the request presented upstream; x_d is the next value of x_q;
// *_stored a value an earlier cycle recorded, *_now a value arriving in this cycle.
module tpchk_rmw_model
  import tlul_pkg::*;
  import tpchk_pkg::*;
(
  input  logic     clk_i,
  input  logic     rst_ni,

  // RMW filter, upstream
  input  tl_h2d_t  rmw_h2d_i,
  input  logic     rmw_tag_i,
  input  bit_sel_t rmw_bit_sel_i,
  input  ev_t      rmw_ev_i,

  // RMW filter, downstream
  input  tl_d2h_t  tags_d2h_i,
  input  ev_t      tags_ev_i,

  // The operation accepted before this cycle, and how far it got
  output step_e    step_o,
  output op_t      op_o,

  // What each port may do now: upstream, accept a new request (REQ_RMW_10); downstream, present
  // the Get of get_op, which may be the request presented upstream and not yet accepted, or the
  // write-back of Upd(W, b, t)
  output logic     rmw_req_rdy_allowed_o,
  output logic     tags_get_vld_allowed_o,
  output op_t      get_op_o,
  output logic     upstream_get_vld_allowed_o,
  output logic     tags_writeback_vld_allowed_o,
  output word_t    writeback_word_o,

  // What the operation's answer depends on: its Get's answer (arrived now or before, its error,
  // faulty when a write's has a bad integrity and no d_error, the word W, whether
  // Bit(W, b) == t), whether a write-back is needed, and the write-back's answer
  output logic     rsp_get_answered_o,
  output logic     rsp_get_err_o,
  output logic     rsp_get_faulty_o,
  output word_t    rsp_word_o,
  output logic     rsp_tag_unchanged_o,
  output logic     rsp_writeback_needed_o,
  output logic     rsp_writeback_answered_o,
  output logic     rsp_writeback_err_o,
  output tl_d_op_e rsp_writeback_op_o,

  // Fault causes since reset, now included ([ToO] Error Handling): a meta SRAM answer taken with
  // d_error, or with a bad response or data integrity
  output logic     device_err_seen_o,
  output logic     intg_err_seen_o
);

  ///////////////////
  // The operation //
  ///////////////////

  // The operation accepted before this cycle, and how far it got
  step_e step_q, step_d;
  op_t   op_q, op_d;

  // The request presented upstream, as an operation
  op_t upstream_op;
  always_comb begin : proc_upstream_op
    upstream_op         = '0;
    upstream_op.wr      = !is_get(rmw_h2d_i);
    upstream_op.addr    = rmw_h2d_i.a_address;
    upstream_op.bit_sel = rmw_bit_sel_i;
    upstream_op.tag     = rmw_tag_i;
    upstream_op.src     = rmw_h2d_i.a_source;
  end

  // REQ_RMW_10: no operation unanswered, or the only one, a read, answered now.
  logic rmw_req_rdy_allowed;
  assign rmw_req_rdy_allowed = (step_q == StepIdle) || (!op_q.wr && rmw_ev_i.rsp_fire);

  ////////////////////
  // Downstream Get //
  ////////////////////

  // The operation's Get, still owed, or the Get of the request presented upstream, which then
  // passes combinationally ([ToO] Timing).
  logic pending_get_vld_allowed;
  logic upstream_get_vld_allowed;
  logic tags_get_vld_allowed;
  op_t  get_op;
  assign pending_get_vld_allowed  = step_q == StepGetOwed;
  assign upstream_get_vld_allowed = !pending_get_vld_allowed && rmw_ev_i.req_vld &&
                                    rmw_req_rdy_allowed;
  assign tags_get_vld_allowed     = pending_get_vld_allowed || upstream_get_vld_allowed;
  assign get_op                   = pending_get_vld_allowed ? op_q : upstream_op;

  logic pending_get_sent_now;
  logic upstream_get_sent_now;
  assign pending_get_sent_now  = pending_get_vld_allowed  && tags_ev_i.req_fire;
  assign upstream_get_sent_now = upstream_get_vld_allowed && tags_ev_i.req_fire;

  // The Get's answer, recorded earlier or arriving now, and what it means for the bit
  logic  get_stored;
  logic  get_answer_now;
  logic  get_answered;
  logic  get_err;
  word_t word;
  logic  tag_unchanged;
  logic  writeback_needed;
  assign get_stored       = step_q inside {StepFilled, StepWriteBackSent, StepWriteBackAcked};
  assign get_answer_now   = (step_q == StepWaitFill) && tags_ev_i.rsp_vld;
  assign get_answered     = get_stored || get_answer_now;
  assign get_err          = get_stored ? op_q.get_err : tags_d2h_i.d_error;
  assign word             = get_stored ? op_q.word    : tags_d2h_i.d_data;
  assign tag_unchanged    = bit_of(word, op_q.bit_sel) == op_q.tag;
  assign writeback_needed = op_q.wr && get_answered && !get_err && !tag_unchanged;

  // A faulty Get answer: a write's, without d_error but with a bad response or data integrity.
  // The spec does not say what the filter does with a corrupted read, and the integrity fault
  // raises the alert anyway, so the checks leave that write free from here on.
  logic tags_intg_bad;
  logic get_intg_bad;
  logic get_faulty;
  assign tags_intg_bad = !is_rsp_intg_ok(tags_d2h_i) || !is_d_data_intg_ok(tags_d2h_i);
  assign get_intg_bad  = get_stored ? op_q.get_intg_bad : tags_intg_bad;
  assign get_faulty    = op_q.wr && get_answered && !get_err && get_intg_bad;

  ///////////////////////////
  // Downstream write-back //
  ///////////////////////////

  // The write-back follows the Get's answer, in a later cycle: one request channel.
  logic tags_writeback_vld_allowed;
  logic writeback_sent_now;
  assign tags_writeback_vld_allowed = (step_q == StepFilled) && writeback_needed;
  assign writeback_sent_now         = tags_writeback_vld_allowed && tags_ev_i.req_fire;

  // The write-back's answer, recorded earlier or arriving now
  logic     writeback_stored;
  logic     writeback_answer_now;
  logic     writeback_answered;
  logic     writeback_err;
  tl_d_op_e writeback_op;
  assign writeback_stored     = step_q == StepWriteBackAcked;
  assign writeback_answer_now = (step_q == StepWriteBackSent) && tags_ev_i.rsp_vld;
  assign writeback_answered   = writeback_stored || writeback_answer_now;
  assign writeback_err        = writeback_stored ? op_q.writeback_err : tags_d2h_i.d_error;
  assign writeback_op         = writeback_stored ? op_q.writeback_op  : tags_d2h_i.d_opcode;

  ////////////////
  // Next state //
  ////////////////

  always_comb begin : proc_op_next
    step_d = step_q;
    op_d   = op_q;
    if (rmw_ev_i.req_fire) begin
      // A new operation is accepted, after any pending one is answered now. Its Get may pass
      // downstream at once; its Get's answer comes a cycle or more later (contract C10).
      step_d = upstream_get_sent_now ? StepWaitFill : StepGetOwed;
      op_d   = upstream_op;
    end else if ((step_q != StepIdle) && rmw_ev_i.rsp_fire) begin
      // The operation is answered and leaves.
      step_d = StepIdle;
      op_d   = '0;
    end else begin
      // The operation moves on with this cycle's event.
      unique case (step_q)
        // Its Get is taken downstream.
        StepGetOwed: begin
          if (pending_get_sent_now) step_d = StepWaitFill;
        end

        // Its Get's answer arrives: keep W, its d_error and its integrity.
        StepWaitFill: begin
          if (get_answer_now) begin
            step_d            = StepFilled;
            op_d.get_err      = tags_d2h_i.d_error;
            op_d.get_intg_bad = tags_intg_bad;
            op_d.word         = tags_d2h_i.d_data;
          end
        end

        // Its write-back is taken downstream.
        StepFilled: begin
          if (writeback_sent_now) step_d = StepWriteBackSent;
        end

        // The write-back's answer arrives: keep its d_error and d_opcode.
        StepWriteBackSent: begin
          if (writeback_answer_now) begin
            step_d             = StepWriteBackAcked;
            op_d.writeback_err = tags_d2h_i.d_error;
            op_d.writeback_op  = tags_d2h_i.d_opcode;
          end
        end

        // No operation, or one waiting only for its answer to be taken upstream.
        default: ;
      endcase
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin : proc_op_regs
    if (!rst_ni) begin
      step_q <= StepIdle;
      op_q   <= '0;
    end else begin
      step_q <= step_d;
      op_q   <= op_d;
    end
  end

  //////////////////
  // Fault causes //
  //////////////////

  logic device_err_seen_q, device_err_seen_d;
  logic intg_err_seen_q, intg_err_seen_d;
  assign device_err_seen_d = device_err_seen_q || (tags_ev_i.rsp_fire && tags_d2h_i.d_error);
  assign intg_err_seen_d   = intg_err_seen_q   || (tags_ev_i.rsp_fire && tags_intg_bad);

  always_ff @(posedge clk_i or negedge rst_ni) begin : proc_err_seen
    if (!rst_ni) begin
      device_err_seen_q <= 1'b0;
      intg_err_seen_q   <= 1'b0;
    end else begin
      device_err_seen_q <= device_err_seen_d;
      intg_err_seen_q   <= intg_err_seen_d;
    end
  end

  /////////////
  // Outputs //
  /////////////

  assign step_o                       = step_q;
  assign op_o                         = op_q;
  assign rmw_req_rdy_allowed_o        = rmw_req_rdy_allowed;
  assign tags_get_vld_allowed_o       = tags_get_vld_allowed;
  assign get_op_o                     = get_op;
  assign upstream_get_vld_allowed_o   = upstream_get_vld_allowed;
  assign tags_writeback_vld_allowed_o = tags_writeback_vld_allowed;
  assign writeback_word_o             = upd(word, op_q.bit_sel, op_q.tag);
  assign rsp_get_answered_o           = get_answered;
  assign rsp_get_err_o                = get_err;
  assign rsp_get_faulty_o             = get_faulty;
  assign rsp_word_o                   = word;
  assign rsp_tag_unchanged_o          = tag_unchanged;
  assign rsp_writeback_needed_o       = writeback_needed;
  assign rsp_writeback_answered_o     = writeback_answered;
  assign rsp_writeback_err_o          = writeback_err;
  assign rsp_writeback_op_o           = writeback_op;
  assign device_err_seen_o            = device_err_seen_d;
  assign intg_err_seen_o              = intg_err_seen_d;

endmodule
