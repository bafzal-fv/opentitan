// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// A model of the RMW filter, written from the spec, one operation at a time. A read of tag bit b
// becomes a Get of the meta word W and answers Bit(W, b). A write of tag t becomes the same Get
// and, only when the bit would change, a write-back of Upd(W, b, t); then the answer. The
// properties compare the filter's two ports with these outputs. cur is the operation accepted
// before this cycle; x_d is the next value of x_q.
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

  // Expected behaviour
  output op_t      cur_o,          // the operation accepted before this cycle
  output logic     can_take_o,     // REQ_RMW_10: a new request may be accepted now
  output logic     get_slot_o,     // the downstream request may be a Get now
  output op_t      get_op_o,       // ... of this operation
  output logic     get_slot_new_o, // ... for the request presented upstream, not yet accepted
  output logic     wb_slot_o,      // the downstream request may be the write-back now
  output word_t    wb_word_o,      // Upd(W, b, t)
  output op_t      ans_op_o,       // the operation an upstream answer now belongs to
  output logic     ans_op_vld_o,
  output logic     ans_get_in_o,   // its Get answer arrived, now or before
  output logic     ans_get_err_o,
  output logic     ans_faulty_o,   // a write whose Get answer is faulty: bad integrity, no d_error
  output word_t    ans_word_o,
  output logic     ans_bit_eq_o,   // Bit(W, b) == t
  output logic     ans_wb_need_o,  // a write whose bit differs, Get answer without error
  output logic     ans_wb_in_o,    // its write-back's answer arrived, now or before
  output logic     ans_wb_err_o,
  output tl_d_op_e ans_wb_op_o,

  // Fault causes since reset, now included ([ToO] Error Handling)
  output logic     dev_err_seen_o, // a meta SRAM answer taken with d_error
  output logic     intg_err_seen_o // ... with a bad response or data integrity
);

  op_t cur_q;

  // The request presented upstream, as an operation.
  op_t pres;
  always_comb begin
    pres         = '0;
    pres.vld     = 1'b1;
    pres.wr      = !is_get(rmw_h2d_i);
    pres.addr    = rmw_h2d_i.a_address;
    pres.bit_sel = rmw_bit_sel_i;
    pres.tag     = rmw_tag_i;
    pres.src     = rmw_h2d_i.a_source;
  end

  // REQ_RMW_10: no operation unanswered, or the only one, a read, answered now.
  logic can_take;
  assign can_take = !cur_q.vld || (!cur_q.wr && rmw_ev_i.rsp_fire);

  // Downstream slots: the current operation's owed Get or write-back, or the Get of the request
  // presented upstream, which then passes combinationally ([ToO] Timing).
  logic get_slot_cur;
  logic get_slot_new;
  logic get_slot;
  op_t  get_op;
  assign get_slot_cur = cur_q.vld && !cur_q.get_taken;
  assign get_slot_new = !get_slot_cur && rmw_ev_i.req_vld && can_take;
  assign get_slot     = get_slot_cur || get_slot_new;
  assign get_op       = get_slot_cur ? cur_q : pres;

  // The operation this cycle's answers belong to: the current one, or one accepted now and
  // answered in the same cycle.
  logic new_now;
  op_t  a;
  logic a_vld;
  assign new_now = !cur_q.vld && rmw_ev_i.req_fire;
  assign a_vld   = cur_q.vld || new_now;
  always_comb begin
    a = cur_q.vld ? cur_q : pres;
    if (new_now) a.get_taken = get_slot_new && tags_ev_i.req_fire;
  end

  logic  get_ans_now;
  logic  get_in;
  logic  get_err;
  word_t word;
  logic  bit_eq;
  logic  wb_need;
  assign get_ans_now = a_vld && tags_ev_i.rsp_vld && a.get_taken && !a.get_in;
  assign get_in      = a.get_in || get_ans_now;
  assign get_err     = a.get_in ? a.get_err : tags_d2h_i.d_error;
  assign word        = a.get_in ? a.word    : tags_d2h_i.d_data;
  assign bit_eq      = bit_of(word, a.bit_sel) == a.tag;
  assign wb_need     = a.wr && get_in && !get_err && !bit_eq;

  // A faulty Get answer: a write's, without d_error but with a bad response or data integrity.
  // The spec does not say what the filter does with a corrupted read, and the integrity fault
  // raises the alert anyway, so the checks leave that write free from here on.
  logic tags_intg_bad;
  logic get_intg_bad;
  logic faulty;
  assign tags_intg_bad = !is_rsp_intg_ok(tags_d2h_i) || !is_d_data_intg_ok(tags_d2h_i);
  assign get_intg_bad  = a.get_in ? a.get_intg_bad : tags_intg_bad;
  assign faulty        = a.wr && get_in && !get_err && get_intg_bad;

  // The write-back follows the Get's answer, in a later cycle: one request channel.
  logic wb_slot;
  assign wb_slot = cur_q.vld && cur_q.get_taken && wb_need && !cur_q.wb_taken;

  logic     wb_ans_now;
  logic     wb_in;
  logic     wb_err;
  tl_d_op_e wb_op;
  assign wb_ans_now = a_vld && tags_ev_i.rsp_vld && a.wb_taken && !a.wb_in;
  assign wb_in      = a.wb_in || wb_ans_now;
  assign wb_err     = a.wb_in ? a.wb_err : tags_d2h_i.d_error;
  assign wb_op      = a.wb_in ? a.wb_op  : tags_d2h_i.d_opcode;

  // Next operation.
  op_t cur_d;
  always_comb begin
    cur_d = cur_q;
    if (get_slot_cur && tags_ev_i.req_fire) cur_d.get_taken = 1'b1;
    if (cur_q.vld && get_ans_now) begin
      cur_d.get_in       = 1'b1;
      cur_d.get_err      = tags_d2h_i.d_error;
      cur_d.get_intg_bad = tags_intg_bad;
      cur_d.word         = tags_d2h_i.d_data;
    end
    if (wb_slot && tags_ev_i.req_fire) cur_d.wb_taken = 1'b1;
    if (cur_q.vld && wb_ans_now) begin
      cur_d.wb_in  = 1'b1;
      cur_d.wb_err = tags_d2h_i.d_error;
      cur_d.wb_op  = tags_d2h_i.d_opcode;
    end
    if (cur_q.vld && rmw_ev_i.rsp_fire) cur_d = '0;
    if (rmw_ev_i.req_fire) begin
      cur_d           = pres;
      cur_d.get_taken = get_slot_new && tags_ev_i.req_fire;
      if (new_now && get_ans_now) begin
        cur_d.get_in       = 1'b1;
        cur_d.get_err      = tags_d2h_i.d_error;
        cur_d.get_intg_bad = tags_intg_bad;
        cur_d.word         = tags_d2h_i.d_data;
      end
      if (new_now && rmw_ev_i.rsp_fire) cur_d = '0;
    end
  end

  logic dev_err_seen_q, dev_err_seen_d;
  logic intg_err_seen_q, intg_err_seen_d;
  assign dev_err_seen_d  = dev_err_seen_q || (tags_ev_i.rsp_fire && tags_d2h_i.d_error);
  assign intg_err_seen_d = intg_err_seen_q ||
                           (tags_ev_i.rsp_fire && (!is_rsp_intg_ok(tags_d2h_i) ||
                                                   !is_d_data_intg_ok(tags_d2h_i)));

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      cur_q           <= '0;
      dev_err_seen_q  <= 1'b0;
      intg_err_seen_q <= 1'b0;
    end else begin
      cur_q           <= cur_d;
      dev_err_seen_q  <= dev_err_seen_d;
      intg_err_seen_q <= intg_err_seen_d;
    end
  end

  assign cur_o           = cur_q;
  assign can_take_o      = can_take;
  assign get_slot_o      = get_slot;
  assign get_op_o        = get_op;
  assign get_slot_new_o  = get_slot_new;
  assign wb_slot_o       = wb_slot;
  assign wb_word_o       = upd(word, cur_q.bit_sel, cur_q.tag);
  assign ans_op_o        = a;
  assign ans_op_vld_o    = a_vld;
  assign ans_get_in_o    = get_in;
  assign ans_get_err_o   = get_err;
  assign ans_faulty_o    = faulty;
  assign ans_word_o      = word;
  assign ans_bit_eq_o    = bit_eq;
  assign ans_wb_need_o   = wb_need;
  assign ans_wb_in_o     = wb_in;
  assign ans_wb_err_o    = wb_err;
  assign ans_wb_op_o     = wb_op;
  assign dev_err_seen_o  = dev_err_seen_d;
  assign intg_err_seen_o = intg_err_seen_d;

endmodule
