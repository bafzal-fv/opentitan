#!/bin/bash
# Copyright lowRISC contributors (OpenTitan project).
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
#
# Lint a checker with and without FPV_ON, then elaborate the FPV top with its binds in every build
# (sim and FPV, each run). Prints every error, and the warnings of the testbench's own files (the
# checker and the TL-UL ABVIP); the RTL's own warnings are left out. Each checker holds its rules
# (ENV_RULE, cheriot_mem_sys_fpv_rule.svh).
#   tools/verify.sh [checker folder]                          checker 1 (tag path)
#   CHECKER=memsys tools/verify.sh [fpv folder]               the shared top: every checker in one
#     FPV top and one bound checker; also writes its Jasper file list (OUT)
# Environment: VERILATOR (default verilator on PATH; the docs' results are from 5.048), OUT (default
# scratch/cheriot_mem_sys_fpv at the repo root). A new checker adds its case below
# (fpv/README.md, Add a checker).
set -u
FPV=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
REPO=$(cd "$FPV/../../../.." && pwd)
OT=$REPO/hw
AB=$OT/dv/sv/tlul_abvip
V=${VERILATOR:-verilator}
RTL_F=$FPV/tools/cheriot_mem_sys_rtl.f
# The RTL's include folders, and the FPV folder for ENV_RULE (cheriot_mem_sys_fpv_rule.svh).
FPV_INC=$FPV
INC="-I$OT/ip/prim/rtl -I$OT/ip/prim_generic/rtl -I$FPV_INC"
CHECKER=${CHECKER:-tag_path}
case $CHECKER in
  tag_path)
    P=tpchk
    TP=${1:-$FPV/tag_path}
    OWN_FILES="tpchk_pkg.sv tpchk_tf_model.sv tpchk_rmw_model.sv tpchk_checker.sv"
    # Lint only: checker 1's FPV top and binds are the one environment's (CHECKER=memsys).
    RUNS=()
    ;;
  reg_file)
    P=rfchk
    TP=${1:-$FPV/reg_file}
    OWN_FILES="rfchk_checker.sv"
    RUNS=()
    ;;
  memsys)
    # The one environment: each checker's modules with its rules, the one checker, the FPV top and
    # the checker's bind; one build, simulation and formal.
    P=cheriot_mem_sys_fpv
    # Absolute: the Jasper file list it writes is read from OUT.
    TP=$(realpath "${1:-$FPV}")
    FPV_INC=$TP
    INC="-I$OT/ip/prim/rtl -I$OT/ip/prim_generic/rtl -I$FPV_INC"
    OWN_FILES="tag_path/tpchk_pkg.sv tag_path/tpchk_tf_model.sv tag_path/tpchk_rmw_model.sv
               tag_path/tpchk_checker.sv reg_file/rfchk_checker.sv cheriot_mem_sys_fpv_checker.sv"
    # One build holds every check of every checker: each Jasper task copies its own, no define.
    RUNS=("")
    ;;
  *)
    echo "unknown CHECKER: $CHECKER (tag_path, reg_file or memsys)"
    exit 2
    ;;
esac
# The RTL and its packages, from the RTL file list, made absolute.
RTL=$(grep -v '^//\|^+incdir' "$RTL_F" | sed "s|^|$REPO/|")
INCDIRS=$(grep '^+incdir+' "$RTL_F" | sed "s|^+incdir+|+incdir+$REPO/|")
PKGS=$(echo "$RTL" | grep '_pkg\.sv$')
CHK="$AB/tlul_abvip_pkg.sv $AB/tlul_abvip.sv"
for f in $OWN_FILES; do
  CHK="$CHK $TP/$f"
done
# The testbench's own files: the folder linted (wherever it is) and the ABVIP.
OWN="$TP/|dv/sv/tlul_abvip/"

# Left out by design: unused bits of a whole TL-UL struct passed to a signal or a function (the
# checks read some fields only), and Verilator's closing count of the warnings.
FOUND=$(mktemp)
show() {
  grep -E "^%Error|^%Warning-[A-Z0-9_]+: .*($OWN)" |
    grep -v -E 'Bits of (signal|function variable) are not used|Exiting due to [0-9]+ warning' |
    tee -a "$FOUND"
}

echo "== $($V --version); lint: --lint-only -Wall; elaborate: --lint-only -Wno-fatal" \
  "-Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM"
for d in "" "+define+FPV_ON"; do
  echo "== lint ${P}_checker ${d:-sim}"
  # shellcheck disable=SC2086
  $V --lint-only -Wall $d $INC $PKGS $CHK --top-module ${P}_checker 2>&1 | show
done
for d in "" "+define+FPV_ON"; do
  for r in ${RUNS[@]+"${RUNS[@]}"}; do
    echo "== elab ${d:-sim} ${r:-no run define}"
    # shellcheck disable=SC2086
    $V --lint-only -Wno-fatal -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM $d $r $INC \
      $RTL $CHK $TP/${P}_env.sv $TP/${P}_checker_bind.sv --top-module ${P}_env 2>&1 | show
  done
done
# The shared top's Jasper file list: the files just checked, in the same order.
if [ "$CHECKER" = memsys ]; then
  OUT=${OUT:-$REPO/scratch/cheriot_mem_sys_fpv}
  mkdir -p "$OUT"
  { echo "$INCDIRS"; echo "+incdir+$FPV_INC"; echo "$RTL"
    for f in $CHK $TP/${P}_env.sv $TP/${P}_checker_bind.sv; do echo "$f"; done
  } > "$OUT/$P.scr"
  echo "== file list: $OUT/$P.scr"
fi
if [ -s "$FOUND" ]; then
  echo "RESULT: FAIL ($(wc -l < "$FOUND") lines above)"
  rm -f "$FOUND"
  exit 1
fi
rm -f "$FOUND"
echo "RESULT: PASS"
