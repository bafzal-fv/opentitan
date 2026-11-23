// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// revchk_pkg: the testplan's definitions and algebra that checker 3 (revocation engine) adds to
//   checker 1's tpchk_pkg, which it imports for addresses, tags, events and integrity.
// Data path: none; constants, types and functions that every checker 3 module imports.
// Figure: cheriot_mem_sys_fpv_revocation_uarch.adoc, section "Definitions in the testbench".
// Obligations: none; the formulas the properties compare against.
// Spec: the checker 3 testplan's Terms (base, sealing capability, revocable base, revocation word
//   and bit, revoked, taken start, N) and the subsystem testplan's Terms; [ISA] §7.12, §7.13.3,
//   CLC; [ToO] Revocation Engine.
// Naming: predicates read as questions (is_*); formulas keep the testplan's names.
package revchk_pkg;
  import tlul_pkg::*;
  import tpchk_pkg::*;

  // [HJSON] TBRE_NUM_CAPS bits 30:0; TBRE_EPOCH bits 31:1 count the sweeps.
  typedef logic [30:0] num_t;
  typedef logic [30:0] epoch_cnt_t;

  //////////////////////////////
  // Regions and bitmap words //
  //////////////////////////////

  // [ToO] Meta SRAM Address Map: the revocation bitmap is the first table of the meta SRAM.
  localparam addr_t RevBmBase = MetaBase;
  localparam addr_t RevBmTop  = MetaBase + RevBmBytes;

  // RTop(a): the top (exclusive) of the tagged region holding a.
  function automatic addr_t region_top(addr_t a);
    return is_main_sram(a) ? MainSramTop : NvmTop;
  endfunction

  // Cap(a) = a & ~7.
  function automatic addr_t cap_of(addr_t a);
    return {a[top_pkg::TL_AW-1:3], 3'b000};
  endfunction

  // RevWord(a), for Revocable(a).
  function automatic addr_t rev_word(addr_t a);
    return RevBmBase + (((a - MainSramBase) >> 8) << 2);
  endfunction

  // RevBit(a).
  function automatic bit_sel_t rev_bit(addr_t a);
    return bit_sel_t'((a - MainSramBase) >> 3);
  endfunction

  function automatic logic is_bitmap_word(addr_t a);
    return (a >= RevBmBase) && (a < RevBmTop);
  endfunction

  //////////////////
  // Capabilities //
  //////////////////

  // [ISA] Figure 7.2: the fields of the metadata word W1.
  function automatic logic [5:0] cap_perms(word_t w1);
    return w1[30:25];
  endfunction

  // Base(c), [ISA] §7.13.3 and Sail getCapBoundsBits: the testplan's four steps.
  function automatic addr_t cap_base(word_t w0, word_t w1);
    logic [3:0] exp_field;
    logic [8:0] b;
    logic [5:0] e;
    logic [8:0] a_mid;
    addr_t      a_top;
    addr_t      c_b;
    exp_field = w1[21:18];
    b         = w1[8:0];
    e         = (exp_field == 4'd15) ? 6'd24 : {2'b00, exp_field};
    a_mid     = 9'((w0 >> e) & 32'h1FF);
    a_top     = w0 >> (e + 6'd9);
    c_b       = (a_mid < b) ? '1 : '0;
    return ((a_top + c_b) << (e + 6'd9)) | (addr_t'(b) << e);
  endfunction

  // The base decode's correction c_b is -1: a_mid < B (testplan Base, step 3).
  function automatic logic is_cb_neg(word_t w0, word_t w1);
    logic [5:0] e;
    e = (w1[21:18] == 4'd15) ? 6'd24 : {2'b00, w1[21:18]};
    return 9'((w0 >> e) & 32'h1FF) < w1[8:0];
  endfunction

  // Sealing(c) = p[4:3] == 0 and p[2:0] != 0 ([ISA] CLC, isSealingCap).
  function automatic logic is_sealing(word_t w1);
    logic [5:0] p;
    p = cap_perms(w1);
    return (p[4:3] == 2'b00) && (p[2:0] != 3'b000);
  endfunction

  // Revocable(a) = MainSram(a).
  function automatic logic is_revocable(addr_t a);
    return is_main_sram(a);
  endfunction

  ///////////
  // Sweep //
  ///////////

  // TakenStart's three conditions: Ena, NUM != 0, Tagged(BASE).
  function automatic logic is_taken_start(logic ena, addr_t base, num_t num);
    return ena && (num != '0) && is_tagged(base);
  endfunction

  // N = min(NUM, (RTop(BASE) - BASE) / 8), for a taken start.
  function automatic num_t sweep_caps(addr_t base, num_t num);
    addr_t room;
    room = (region_top(base) - base) >> 3;
    return (addr_t'(num) < room) ? num : num_t'(room);
  endfunction

  /////////////////////////////
  // Requests and responses  //
  /////////////////////////////

  // FullWord(r) and Get(r).
  function automatic logic is_full_get(tl_h2d_t r);
    return (r.a_opcode == Get) && (r.a_size == 2'd2) && (r.a_address[1:0] == 2'b00);
  endfunction

  // Malformed(s), for the answer to a full-word Get.
  function automatic logic is_malformed_read(tl_d2h_t s);
    return (s.d_opcode != AccessAckData) || (s.d_size != 2'd2);
  endfunction

  // IntgOk(s): the response integrity and the data integrity match.
  function automatic logic is_intg_ok(tl_d2h_t s);
    return is_rsp_intg_ok(s) && is_d_data_intg_ok(s);
  endfunction

  // A failed answer to a read of the engine: an error, a broken integrity or (V3) malformed.
  function automatic logic is_failed_read(tl_d2h_t s);
    return s.d_error || !is_intg_ok(s) || is_malformed_read(s);
  endfunction

  /////////////////////////////////
  // Runs and tracked capability //
  /////////////////////////////////

  // The tracked capability's phases (uarch, Engine model, What the model remembers).
  typedef enum logic [2:0] {
    TrkIdle,      // nothing tracked in this sweep
    TrkRead,      // W0 and W1 read; until W1's answer reaches the TRVK filter
    TrkLookup,    // the TRVK filter holds W1's answer: the lookup window
    TrkDecided,   // W1's answer left the TRVK filter: Revoked(trk) is known
    TrkClear,     // the clear is presented; until its answer at the clear port
    TrkResolved   // every part answered; the sweep may end
  } trk_e;

  // The runs of checker 3 (uarch, Environment, runs).
  typedef enum logic [2:0] {
    RunSafeA,  // contracts C3a, C3b, C11, C21 for checker 1: no contract of checker 1 assumed
    RunV1,     // safety B: every safety check, with contracts C6 and C7
    RunV3,     // V1 without the answer-shape rules on tbre_tl_h and the bitmap port
    RunV4,     // V1 with one mode switch to MuBi4True while idle
    RunLiveA,  // contract C5
    RunLiveB   // tbre_done's sweep ends, with assumption A10, contracts C1, C2
  } run_e;

endpackage
