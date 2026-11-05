# cheriot_mem_sys FPV testbench

Formal property verification (FPV) of the CHERIoT memory subsystem, `hw/ip/cheriot_mem_sys`. The
testbench is one FPV top and one checker bound into the design; the checker holds one sub-checker
per region of the design. Checker 1, the tag path, is built and documented here; checkers 2 (meta
access) and 3 (revocation engine) have their requirements, testplan and TB architecture here.

## How the testbench is laid out

<img src="doc/tb_arch/figures/cheriot_mem_sys_tb_arch_figures.svg#fig2" alt="The FPV top: the design whole, with one checker bound into it" width="820" height="522">

| Layer | Files | What it does |
|---|---|---|
| FPV top | `cheriot_mem_sys_fpv_env.sv` | Instantiates `cheriot_mem_sys` whole, with every input free: the formal tool picks each input in every cycle. |
| Bound checker | `cheriot_mem_sys_fpv_checker.sv`, `cheriot_mem_sys_fpv_checker_bind.sv` | Bound into `cheriot_mem_sys` as `u_fpv_checker`. Its ports are every port of `cheriot_mem_sys` and the internal nets the checkers observe. It only wires: one instance per checker. The bind is the only file with RTL net names. |
| Checker | `tag_path/tpchk_*.sv` | The checks (asserts), the covers, the models and tracker, and the rules on what the neighbours send. |
| Rules | `cheriot_mem_sys_fpv_rule.svh` | `ENV_RULE`: an assumption when `FPV_ON` is defined, an assertion otherwise, so the same bind checks the rules in a simulation. |
| TL-UL protocol | `hw/dv/sv/tlul_abvip/` | The TL-UL ABVIP (assertion-based VIP): one instance per TL-UL port. It assumes the rules of the end the testbench plays and asserts the end the design drives. |
| Formal tasks | kept outside this repository | One build of the whole design. Each checker gets its own tasks (`task_TagPath_Main` and others): each copies only its checker's properties and cuts the blocks outside the checker's boundary. |
| dvsim | `cheriot_mem_sys_fpv_cfgs.hjson`, `cheriot_mem_sys_fpv_common_cfg.hjson` | OpenTitan's FPV flow, one dvsim run per formal task. |
| Tools | `tools/` | Lint and the formal file list (`verify.sh`, `cheriot_mem_sys_rtl.f`); the uarch's check map against the testplan and the SV (`checkmap.py`). |

| Checker | Region of the design | Folder |
|---|---|---|
| 1, tag path | Core tag filter, WTRC, 2:1 tag arbiter (`cheriot_socket_m1`), RMW filter | `tag_path/` |
| 2, meta access | The four access checkers and the 4:1 arbiter in front of `meta_sram_tl` | `meta_access/` |
| 3, revocation engine | Engine, its TRVK filter and tag filter, sweep control, interrupt, core write watch | `revocation/` |

The checkers depend on each other through contracts: one checker proves a property on a shared
interface, and the other assumes it. The TB architecture lists them, in its Contracts section.

## Run it

1. Start the non-hermetic EDA shell at the repo root, which has Verilator and the formal tool:

   ```sh
   nix develop .#eda.nonhermetic
   ```

2. Lint checker 1, then lint the whole FPV top and write the formal file list:

   ```sh
   cd hw/ip/cheriot_mem_sys/fpv
   tools/verify.sh
   CHECKER=memsys tools/verify.sh
   ```

3. Run the proofs with dvsim, one run per formal task:

   ```sh
   dvsim hw/ip/cheriot_mem_sys/fpv/cheriot_mem_sys_fpv_cfgs.hjson          # batch
   dvsim hw/ip/cheriot_mem_sys/fpv/cheriot_mem_sys_fpv_cfgs.hjson --gui    # the Jasper GUI
   ```

   The formal tool's task script is kept outside this repository.

| dvsim run | Formal task |
|---|---|
| `cheriot_mem_sys_tag_path_main_fpv` | `task_TagPath_Main`: every check of checker 1 but the liveness ones |

   The task script also makes checker 1's two liveness tasks (`task_TagPath_TagsRspTaken`,
   `task_TagPath_EveryReqAnswered`) and the register-file unit's tasks in the same
   session; prove them there, or add a dvsim entry to run one as a regression.

## Add a checker

1. Read the checker's section of the testplan and of the TB architecture: its boundary, its
   environment and the contracts it proves or assumes.
2. Write its uarch in `doc/tb_arch/`, in the layout of the checker 1 uarch, and get it agreed
   before writing SV.
3. Make its folder (`meta_access/` or `revocation/`), with a short prefix for its files: the
   package and the checker (checks, covers, rules with `ENV_RULE`, an ABVIP on each TL-UL port).
4. Wire it in: its instance in `cheriot_mem_sys_fpv_checker.sv`, which has every port of
   `cheriot_mem_sys` already, and a port there for each internal net it observes; those nets in
   `cheriot_mem_sys_fpv_checker_bind.sv`; its files in `cheriot_mem_sys_fpv.core`; a case in
   `tools/verify.sh`; an entry in `CHECKERS` in `tools/checkmap.py`; one dvsim entry per task in
   `cheriot_mem_sys_fpv_cfgs.hjson`. Each file has a comment where the new checker goes.
5. Check it: `tools/verify.sh` with the new case, then `CHECKER=memsys tools/verify.sh`; check the
   map (`python3 tools/checkmap.py <testplan> <uarch> <folder>`). Prove the covers first, then the
   asserts.

## Docs

Read them in this order.

| Doc | What it holds |
|---|---|
| [Design architecture](doc/design_arch/cheriot_mem_sys_design_arch.adoc) | How the subsystem works, from zero; the requirements of the whole subsystem; the assumptions |
| [TB architecture](doc/tb_arch/cheriot_mem_sys_tb_arch.adoc) | The three checkers, their boundaries and environments, the contracts between them, the proof order |
| [FPV testplan](doc/testplan/cheriot_mem_sys_fpv_testplan.adoc) | Every testpoint of every checker: the rule, the checks, the cases, the edge cases, the run |
| [Checker 1 uarch](doc/tb_arch/cheriot_mem_sys_fpv_tag_path_uarch.adoc) | How checker 1 is built and how each check is performed, testpoint by testpoint |
| [TL-UL ABVIP uarch](../../../dv/sv/tlul_abvip/doc/tlul_abvip_uarch.adoc) | The ABVIP's rules, roles and parameters, and how to put it on a port |
