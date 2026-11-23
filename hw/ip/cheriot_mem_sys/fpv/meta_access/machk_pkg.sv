// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Definitions shared by the checker 2 modules: the four requester ports in front of the meta
// SRAM, the meta-word regions, and the functions that say whether a request is legal, the way
// the testplan defines it (Ena, InRegion, FullWord, Legal). Predicates read as questions;
// formulas keep the testplan's names.
package machk_pkg;
  import tlul_pkg::*;

  typedef logic [top_pkg::TL_AW-1:0]  addr_t;
  typedef logic [top_pkg::TL_AIW-1:0] src_t;

  /////////////////////
  // Requester ports //
  /////////////////////

  // A requester port, named after the block at its other end and numbered by the 4:1 arbiter
  // input the Bind wires it to (testplan, Checker 2).
  typedef enum logic [1:0] {
    InTrvk = 2'd0,  // corerevbm_tl: the core's TRVK filter
    InRmw  = 2'd1,  // the tag port: the RMW filter's downstream port
    InXbar = 2'd2,  // revbm_tl_d, the bitmap window: software, through xbar_main
    InTbre = 2'd3   // the engine's bitmap port: its TRVK filter
  } port_e;

  // [TLUL] Source ID growth: the 4:1 arbiter adds two bits at the bottom, so a requester's source
  // keeps its low SrcW bits through it; assumption A9 and contracts C12, C13 keep the top two at 0.
  localparam int unsigned SrcW = top_pkg::TL_AIW - 2;
  // Requests outstanding on one port: at most one per source, 2^SrcW.
  typedef logic [SrcW:0] cnt_t;

  // The tracker of one port (formal-verification skill, Symbolic tracking).
  typedef enum logic {
    TrkIdle,  // no request followed
    TrkOn     // the followed request is taken, its answer not yet taken
  } trk_e;

  ////////////////////////
  // Regions of the map //
  ////////////////////////

  // [IF] Parameters, Earl Grey.
  localparam addr_t MainSramBase = 32'h1000_0000;
  localparam addr_t MainSramTop  = 32'h1003_0000;
  localparam addr_t NvmBase      = 32'h3000_0000;
  localparam addr_t NvmTop       = 32'h3020_0000;
  localparam addr_t MetaBase     = 32'h1100_0000;

  // [ToO] Metadata Encoding: one 32-bit meta word covers 256 bytes.
  localparam addr_t BytesPerWord = 32'd256;
  // [ToO] Meta SRAM Address Map: the bitmap, then the NVM tags, then the main SRAM tags.
  localparam addr_t BitmapBytes  = (MainSramTop - MainSramBase) / BytesPerWord * 32'd4;
  localparam addr_t NvmTagBytes  = (NvmTop - NvmBase) / BytesPerWord * 32'd4;
  localparam addr_t MainTagBytes = (MainSramTop - MainSramBase) / BytesPerWord * 32'd4;
  localparam addr_t TagBase      = MetaBase + BitmapBytes;
  localparam addr_t MetaTop      = TagBase + NvmTagBytes + MainTagBytes;

  // The revocation bitmap, the region of the three bitmap ports.
  function automatic logic is_bitmap(addr_t a);
    return (a >= MetaBase) && (a < TagBase);
  endfunction

  // Both capability tag regions, the region of the tag port.
  function automatic logic is_tag_region(addr_t a);
    return (a >= TagBase) && (a < MetaTop);
  endfunction

  // InRegion: address a lies in port p's region.
  function automatic logic in_region(port_e p, addr_t a);
    return (p == InRmw) ? is_tag_region(a) : is_bitmap(a);
  endfunction

  // The first and the last word of port p's region.
  function automatic addr_t region_first(port_e p);
    return (p == InRmw) ? TagBase : MetaBase;
  endfunction

  function automatic addr_t region_last(port_e p);
    return (p == InRmw) ? (MetaTop - 32'd4) : (TagBase - 32'd4);
  endfunction

  //////////////
  // Requests //
  //////////////

  // Ena: CHERIoT mode, cheriot_ena_i == MuBi4True; any other value is ePMP mode.
  function automatic logic is_ena(prim_mubi_pkg::mubi4_t e);
    return e == prim_mubi_pkg::MuBi4True;
  endfunction

  // FullWord: a_size 2 at a word-aligned address.
  function automatic logic is_full_word(tl_h2d_t r);
    return (r.a_size == 2'd2) && (r.a_address[1:0] == 2'b00);
  endfunction

  // A Get or a PutFullData.
  function automatic logic is_get_or_put_full(tl_h2d_t r);
    return (r.a_opcode == Get) || (r.a_opcode == PutFullData);
  endfunction

  // Legal: request r on port p meets all four conditions.
  function automatic logic is_legal(port_e p, tl_h2d_t r, logic ena);
    return ena && in_region(p, r.a_address) && is_full_word(r) && is_get_or_put_full(r);
  endfunction

  // The row of meta_refuse's truth table: Ena, in region, full word, Get or PutFullData.
  function automatic logic [3:0] legal_row(port_e p, tl_h2d_t r, logic ena);
    return {ena, in_region(p, r.a_address), is_full_word(r), is_get_or_put_full(r)};
  endfunction

  /////////////////////////
  // Sources and answers //
  /////////////////////////

  // The forwarded source ID: (a_source << 2) | p, kept to 8 bits ([TLUL] Source ID growth).
  function automatic src_t fwd_source(src_t s, port_e p);
    return {s[SrcW-1:0], p};
  endfunction

  // The port a source on meta_sram_tl names: its two low bits.
  function automatic port_e port_of(src_t s);
    return port_e'(s[1:0]);
  endfunction

  // The d_source an answer leaves the arbiter with: the two bits shifted off, zeros shifted in.
  function automatic src_t ret_source(src_t s);
    return {2'b00, s[top_pkg::TL_AIW-1:2]};
  endfunction

  ///////////////////////
  // Fields and events //
  ///////////////////////

  // Spec events of one TL-UL port ([TLUL]: a beat passes when valid and ready are both high).
  typedef struct packed {
    logic req_vld;
    logic req_taken;
    logic rsp_vld;
    logic rsp_taken;
  } ev_t;

  function automatic ev_t ev_of(tl_h2d_t h2d, tl_d2h_t d2h);
    ev_t ev;
    ev.req_vld   = h2d.a_valid;
    ev.req_taken = h2d.a_valid && d2h.a_ready;
    ev.rsp_vld   = d2h.d_valid;
    ev.rsp_taken = d2h.d_valid && h2d.d_ready;
    return ev;
  endfunction

  // Every A-channel field except a_source.
  function automatic logic is_same_a_but_source(tl_h2d_t x, tl_h2d_t y);
    return (x.a_opcode == y.a_opcode) && (x.a_param == y.a_param) && (x.a_size == y.a_size) &&
           (x.a_address == y.a_address) && (x.a_mask == y.a_mask) &&
           (x.a_data == y.a_data) && (x.a_user == y.a_user);
  endfunction

  // Every A-channel field: a request stays presented while they all hold ([TL] §5.1).
  function automatic logic [$bits(tl_h2d_t)-3:0] a_fields(tl_h2d_t x);
    return {x.a_opcode, x.a_param, x.a_size, x.a_source, x.a_address, x.a_mask, x.a_data,
            x.a_user};
  endfunction

  // Every D-channel field: an answer that waits stays the same answer.
  function automatic logic is_same_d(tl_d2h_t x, tl_d2h_t y);
    return (x.d_opcode == y.d_opcode) && (x.d_param == y.d_param) && (x.d_size == y.d_size) &&
           (x.d_source == y.d_source) && (x.d_sink == y.d_sink) && (x.d_data == y.d_data) &&
           (x.d_user == y.d_user) && (x.d_error == y.d_error);
  endfunction

  // Every D-channel field except d_source; d_data only in an AccessAckData ([TLUL] d_opcode:
  // "data valid on d_data").
  function automatic logic is_same_d_but_source(tl_d2h_t x, tl_d2h_t y);
    return (x.d_opcode == y.d_opcode) && (x.d_param == y.d_param) && (x.d_size == y.d_size) &&
           (x.d_sink == y.d_sink) && (x.d_user == y.d_user) && (x.d_error == y.d_error) &&
           ((y.d_opcode != AccessAckData) || (x.d_data == y.d_data));
  endfunction

  // A good response integrity: tlul_pkg's own code, as in checker 1, since the spec gives none;
  // only a cover reads it.
  function automatic logic is_rsp_intg_ok(tl_d2h_t s);
    return s.d_user.rsp_intg == get_rsp_intg(s);
  endfunction

endpackage
