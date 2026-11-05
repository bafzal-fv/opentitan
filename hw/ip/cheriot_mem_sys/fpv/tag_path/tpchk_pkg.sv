// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Definitions shared by the checker 1 modules: the address regions and the tag-word layout of the
// Earl Grey memory map, the kinds of request, and the functions that decode a request the way the
// spec describes it. Predicates read as questions (is_main_sram); formulas keep the names the
// testplan uses, so a property can be read against its testpoint.
package tpchk_pkg;
  import tlul_pkg::*;

  typedef logic [top_pkg::TL_AW-1:0]  addr_t;
  typedef logic [top_pkg::TL_DW-1:0]  word_t;
  typedef logic [top_pkg::TL_AIW-1:0] src_t;
  typedef logic [4:0]                 bit_sel_t;
  typedef logic [DataIntgWidth-1:0]   data_intg_t;

  ///////////////////////////
  // Regions and tag words //
  ///////////////////////////

  // [IF] Parameters, Earl Grey.
  localparam addr_t MainSramBase = 32'h1000_0000;
  localparam addr_t MainSramTop  = 32'h1003_0000;
  localparam addr_t NvmBase      = 32'h3000_0000;
  localparam addr_t NvmTop       = 32'h3020_0000;
  localparam addr_t MetaBase     = 32'h1100_0000;

  // [ToO] Metadata Encoding: one 32-bit meta word covers 256 bytes.
  localparam addr_t BytesPerWord = 32'd256;

  // [ToO] Meta SRAM Address Map: the bitmap, then the NVM tags, then the main SRAM tags.
  localparam addr_t RevBmBytes   = (MainSramTop - MainSramBase) / BytesPerWord * 32'd4;
  localparam addr_t NvmTagBase   = MetaBase + RevBmBytes;
  localparam addr_t MainTagBase  = NvmTagBase + (NvmTop - NvmBase) / BytesPerWord * 32'd4;

  function automatic logic is_main_sram(addr_t a);
    return (a >= MainSramBase) && (a < MainSramTop);
  endfunction

  function automatic logic is_nvm(addr_t a);
    return (a >= NvmBase) && (a < NvmTop);
  endfunction

  function automatic logic is_tagged(addr_t a);
    return is_main_sram(a) || is_nvm(a);
  endfunction

  function automatic addr_t region_offset(addr_t a);
    return is_main_sram(a) ? (a - MainSramBase) : (a - NvmBase);
  endfunction

  // TagWord(a).
  function automatic addr_t tag_word(addr_t a);
    addr_t table_base;
    table_base = is_main_sram(a) ? MainTagBase : NvmTagBase;
    return table_base + ((region_offset(a) >> 8) << 2);
  endfunction

  // TagBit(a): the capability's index within the 256 bytes its meta word covers, from the low
  // bits of the offset. The spec does not state the bit order; this reading is DV's, raised with
  // the designers.
  function automatic bit_sel_t tag_bit(addr_t a);
    return bit_sel_t'(region_offset(a) >> 3);
  endfunction

  // Two addresses in one 8-byte capability.
  function automatic logic is_same_cap(addr_t a, addr_t b);
    return a[top_pkg::TL_AW-1:3] == b[top_pkg::TL_AW-1:3];
  endfunction

  ////////////////////
  // Words and bits //
  ////////////////////

  // Bit(W, b).
  function automatic logic bit_of(word_t w, bit_sel_t b);
    return w[b];
  endfunction

  // Upd(W, b, t): bit b set to t, every other bit kept.
  function automatic word_t upd(word_t w, bit_sel_t b, logic t);
    word_t res;
    res    = w;
    res[b] = t;
    return res;
  endfunction

  //////////////
  // Requests //
  //////////////

  // Ena: CHERIoT mode, cheriot_ena_i == MuBi4True; any other value is ePMP mode.
  function automatic logic is_ena(prim_mubi_pkg::mubi4_t e);
    return e == prim_mubi_pkg::MuBi4True;
  endfunction

  function automatic logic is_get(tl_h2d_t r);
    return r.a_opcode == Get;
  endfunction

  // Wr(r).
  function automatic logic is_wr(tl_h2d_t r);
    return (r.a_opcode == PutFullData) || (r.a_opcode == PutPartialData);
  endfunction

  // W0(r): address bit 2 is 0.
  function automatic logic is_w0(tl_h2d_t r);
    return r.a_address[2] == 1'b0;
  endfunction

  // Hint(r): a Get with the tag sideband set, the capability-load hint.
  function automatic logic is_hint(tl_h2d_t r, logic tag);
    return is_get(r) && tag;
  endfunction

  // A full-word PutFullData ([ToO] WTRC).
  function automatic logic is_full_put(tl_h2d_t r);
    return (r.a_opcode == PutFullData) && (r.a_size == 2'd2);
  endfunction

  // NvmCapStore(r).
  function automatic logic is_nvm_cap_store(tl_h2d_t r, logic tag, logic ena);
    return ena && is_wr(r) && is_nvm(r.a_address) && tag;
  endfunction

  // Lookup(r).
  function automatic logic is_lookup(tl_h2d_t r, logic tag, logic ena);
    logic hinted_w0;
    hinted_w0 = is_hint(r, tag) && is_w0(r);
    return ena && is_tagged(r.a_address) && (hinted_w0 || is_wr(r)) &&
           !is_nvm_cap_store(r, tag, ena);
  endfunction

  // The kinds of request the tag rules tell apart ([ToO] Tag Filter, WTRC).
  typedef enum logic [2:0] {
    KindRead,     // any other read
    KindLoadW0,   // Lookup(r) and Get(r): W0 of a capability load
    KindLoadW1,   // Get, Hint, Tagged, Ena, W1: W1 of a capability load
    KindWrite,    // a write that is not a capability store to the NVM
    KindCapStore  // NvmCapStore(r)
  } kind_e;

  // [ToO] WTRC: the capability store sequence.
  typedef enum logic [1:0] {
    CapIdle,   // no capability open
    CapW0,     // W0 taken, waiting for its W1
    CapW1,     // W1 taken, neither answered nor turned into a tag write yet
    CapTagWr   // W1's tag write issued, waiting for W1's answer
  } cap_e;

  // The capture of a capability load's tag ([ToO] Tag Filter).
  typedef enum logic [1:0] {
    CaptureNone,     // cleared: a lone W1 gets 0
    CaptureHeld,     // W0's tag, for the next W1
    CaptureUnknown   // a plain read was answered between W0 and W1: the spec is open, not checked
  } capture_e;

  // Core requests in flight within a cycle: two outstanding, and one presented in the cycle the
  // oldest answer is taken (A2).
  localparam int unsigned NumEnt = 3;
  typedef logic [1:0] idx_t;

  // The oldest entry with its bit set: the lowest index.
  function automatic idx_t oldest(logic [NumEnt-1:0] m);
    return m[0] ? idx_t'(0) :
           m[1] ? idx_t'(1) :
                  idx_t'(2);
  endfunction

  // One core request, from its first cycle on cored_tl_d until its answer is taken.
  typedef struct packed {
    logic       vld;

    // What the request is: set in its first cycle, never changed.
    kind_e      kind;
    logic       lookup;         // Lookup(r)
    logic       w1;             // address bit 2 is 1
    addr_t      addr;
    src_t       src;
    logic       out_of_seq;     // presented out of the capability store sequence
    logic       fault;          // capability store word: partial, out of sequence or bad integrity
    logic       full_in_seq;    // capability store word: full-word PutFullData, in sequence
    word_t      data;           // capability store word: Data(w)
    data_intg_t data_intg;      // and DataIntg(w)

    // How far it has got: set as each event happens, with what the event carried.
    logic       accepted;       // accepted on cored_tl_d
    logic       xbar_sent;      // its xbar request was taken on cored_tl_h
    logic       xbar_answered;  // its xbar answer was taken
    logic       xbar_err;       // with d_error
    logic       xbar_bad_intg;  // with a bad response integrity
    logic       match;          // capability store word: Match(w)
    logic       tag_wr;         // W1: its tag write is owed or sent
    logic       tag_wr_maybe;   // W1: after a broken sequence, a tag write may be issued
    logic       meta_sent;      // its lookup, or W1's tag write, was taken by the meta port
    logic       meta_answered;  // its meta answer arrived
    logic       meta_err;       // with d_error
    logic       meta_tag;       // and this tag
  } ent_t;

  // One RMW filter operation: a request accepted upstream, until its answer is taken there.
  typedef struct packed {
    logic     vld;
    logic     wr;         // a write: its tag is to be written
    addr_t    addr;       // the meta word
    bit_sel_t  bit_sel;
    logic     tag;
    src_t     src;
    logic     get_taken;  // its Get was taken downstream
    logic     get_in;     // the Get's answer arrived
    logic     get_err;
    logic     get_intg_bad; // ... with a bad response or data integrity
    word_t    word;       // W: the word the Get read
    logic     wb_taken;   // its write-back was taken downstream
    logic     wb_in;      // the write-back's answer arrived
    logic     wb_err;
    tl_d_op_e wb_op;
  } op_t;

  function automatic kind_e req_kind(tl_h2d_t r, logic tag, logic ena);
    logic is_load_w1;
    is_load_w1 = is_hint(r, tag) && is_tagged(r.a_address) && ena && !is_w0(r);
    return is_nvm_cap_store(r, tag, ena)       ? KindCapStore :
           is_wr(r)                            ? KindWrite    :
           is_lookup(r, tag, ena)              ? KindLoadW0   :
           is_load_w1                          ? KindLoadW1   :
                                                 KindRead;
  endfunction

  function automatic logic is_wr_kind(kind_e k);
    return (k == KindWrite) || (k == KindCapStore);
  endfunction

  ///////////////////////
  // Fields and events //
  ///////////////////////

  // Spec events of one TL-UL port ([TLUL]: a beat passes when valid and ready are both high).
  typedef struct packed {
    logic req_vld;
    logic req_fire;
    logic rsp_vld;
    logic rsp_fire;
  } ev_t;

  function automatic ev_t port_ev(tl_h2d_t h2d, tl_d2h_t d2h);
    ev_t ev;
    ev.req_vld  = h2d.a_valid;
    ev.req_fire = h2d.a_valid && d2h.a_ready;
    ev.rsp_vld  = d2h.d_valid;
    ev.rsp_fire = d2h.d_valid && h2d.d_ready;
    return ev;
  endfunction

  // Every A-channel field except a_source.
  function automatic logic is_same_a_but_source(tl_h2d_t x, tl_h2d_t y);
    return (x.a_opcode == y.a_opcode) && (x.a_param == y.a_param) && (x.a_size == y.a_size) &&
           (x.a_address == y.a_address) && (x.a_mask == y.a_mask) &&
           (x.a_data == y.a_data) && (x.a_user == y.a_user);
  endfunction

  function automatic logic is_same_a(tl_h2d_t x, tl_h2d_t y);
    return is_same_a_but_source(x, y) && (x.a_source == y.a_source);
  endfunction

  // Every D-channel field: an answer that waits stays the same answer.
  function automatic logic is_same_d(tl_d2h_t x, tl_d2h_t y);
    return (x.d_opcode == y.d_opcode) && (x.d_param == y.d_param) && (x.d_size == y.d_size) &&
           (x.d_source == y.d_source) && (x.d_sink == y.d_sink) && (x.d_data == y.d_data) &&
           (x.d_user == y.d_user) && (x.d_error == y.d_error);
  endfunction

  // The answer fields the tag filter passes through from the host port's answer. The response
  // integrity is compared separately: a meta error merged into d_error changes it.
  function automatic logic is_same_rsp_payload(tl_d2h_t x, tl_d2h_t y);
    return (x.d_opcode == y.d_opcode) && (x.d_size == y.d_size) && (x.d_source == y.d_source) &&
           (x.d_data == y.d_data) && (x.d_user.data_intg == y.d_user.data_intg);
  endfunction

  // Every D-channel field except d_source.
  // d_data counts only in an AccessAckData ([TLUL] d_opcode: "data valid on d_data").
  function automatic logic is_same_d_but_source(tl_d2h_t x, tl_d2h_t y);
    return (x.d_opcode == y.d_opcode) && (x.d_param == y.d_param) && (x.d_size == y.d_size) &&
           (x.d_sink == y.d_sink) && (x.d_user == y.d_user) && (x.d_error == y.d_error) &&
           ((y.d_opcode != AccessAckData) || (x.d_data == y.d_data));
  endfunction

  // Fwd(r, i)'s a_source: (a_source << 1) | i, kept to 8 bits ([TLUL] Source ID growth).
  function automatic src_t fwd_source(src_t s, logic i);
    return {s[top_pkg::TL_AIW-2:0], i};
  endfunction

  ///////////////
  // Integrity //
  ///////////////

  // The spec gives no integrity code (the bus integrity scheme is "to be filled in"), so the
  // functions of the RTL package are the reference here, trusted until the designers confirm
  // them. The same function computes and checks each code, so a bug in it would hide on both
  // sides; that is the price of having no spec to compute from.
  function automatic logic is_cmd_intg_ok(tl_h2d_t r);
    return r.a_user.cmd_intg == get_cmd_intg(r);
  endfunction

  function automatic logic is_a_data_intg_ok(tl_h2d_t r);
    return r.a_user.data_intg == get_data_intg(r.a_data);
  endfunction

  function automatic logic is_rsp_intg_ok(tl_d2h_t s);
    return s.d_user.rsp_intg == get_rsp_intg(s);
  endfunction

  function automatic logic is_d_data_intg_ok(tl_d2h_t s);
    return s.d_user.data_intg == get_data_intg(s.d_data);
  endfunction

endpackage
