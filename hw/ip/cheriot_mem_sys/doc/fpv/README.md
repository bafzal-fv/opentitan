# CHERIoT memory subsystem FPV testplan

This page is the plan of a new FPV environment for the CHERIoT memory subsystem in Earl Grey.
The environment proves the requirements of the tag path, the access rules of the meta SRAM, the revocation engine and the registers.
[Scope](#scope) lists what it checks and what it leaves out.
Every assertion traces to a requirement, and every requirement names its source.

## The CHERIoT memory subsystem in Earl Grey
A CHERIoT capability is 65 bits wide: a 32-bit pointer, 32 bits of metadata and one validity tag bit.
OpenTitan's bus is 32 bits wide, so the core moves a capability in two accesses and carries the tag on a sideband signal next to the bus.
The subsystem sits between the CHERIoT-capable Ibex core and the main crossbar `xbar_main`.
It stores the tags, and the revocation bitmap of the heap, in a meta SRAM.
The input `cheriot_ena_i` selects the mode: CHERIoT mode when it is `MuBi4True`, and ePMP mode for any other value.
The top's configuration sets the address ranges of the main SRAM, the NVM and the meta SRAM ([Parameters](requirements.md#parameters)).
The subsystem does these jobs with its neighbours:

* With the Ibex core, it splits each data access into a data access towards the crossbar and a tag access towards the meta SRAM, and it joins the two answers.
  It also answers the core's reads of the revocation bitmap, which the core makes on every capability load.
* With `xbar_main`, it forwards the data half of each access, serves the register interface and the window onto the revocation bitmap, and lets the revocation engine read the SRAMs and the NVM.
* With the meta SRAM controller, it merges four requesters onto the one port `meta_sram_tl`: the tag path, the core's bitmap reads, the engine's bitmap reads and the system's bitmap window.
  An access checker in front of each requester lets through only full-word accesses to the region that the requester owns.
* On its own, a background revocation engine sweeps a range of capabilities and clears the tag of each capability whose base is revoked.
  The engine raises the interrupt `tbre_done` when a sweep ends.
* To the alert handler, it reports the fatal alert `fatal_fault`.

![The CHERIoT memory subsystem and its neighbours, drawn for Earl Grey: the signals it exchanges with each, and the FPV boundary at its ports](cheriot_mem_sys_fpv_system.svg)

The environment sits at the subsystem's own ports.
It drives every input and checks every output.
The table lists the ports of each neighbour and what the environment does with them.
It also lists the clock and the reset, which the figure leaves out.
An input marked free can take any value in any cycle.

| Neighbour | Ports: subsystem inputs; outputs | In the environment |
|---|---|---|
| Ibex core | `cored_tl_d` requests, `cored_tag_h2d`, `corerevbm_tl` requests; `cored_tl_d` answers, `cored_tag_d2h`, `corerevbm_tl` answers | Core rules assumed ([Assumptions](#assumptions)); answers checked |
| Mode switch in `rv_core_ibex` | `cheriot_ena_i` | Any 4-bit value, the same from reset ([Constraints](#constraints)) |
| Main crossbar `xbar_main` | `regs_tl_d` requests, `revbm_tl_d` requests, `cored_tl_h` answers, `tbre_tl_h` answers; `regs_tl_d` answers, `revbm_tl_d` answers, `cored_tl_h` requests, `tbre_tl_h` requests | TL-UL host rules assumed on the requests it sends, device rules on the answers it sends ([Assumptions](#assumptions)); the subsystem's answers and requests checked |
| Meta SRAM controller | `meta_sram_tl` answers; `meta_sram_tl` requests | Device rules assumed ([Assumptions](#assumptions)); requests checked |
| Alert handler | `alert_rx_i`; `alert_tx_o` | `alert_rx_i` free; the request that reaches the alert sender checked, and not the handshake on the pair |
| Interrupt controller | `intr_tbre_done_o` | Checked |
| Clock and reset managers | `clk_i`, `rst_ni` | One clock; every proof starts with the reset applied ([Proofs](#proofs)) |

## How the plan fits together
The plan is a chain of four parts.
Each part points to the next, so a specification section leads to the assertions that check it, and a failing assertion leads back to the specification text.

1. **Specification.**
   The documents that say what the subsystem must do: [Sources](#sources) lists them.
2. **Requirements** ([requirements.md](requirements.md)).
   239 statements of what the subsystem must do, in 15 groups, one group per feature.
   Each requirement names its source.
3. **Testpoints** ([testplan](../../data/cheriot_mem_sys_fpv_testplan.hjson)).
   41 entries of the testplan.
   A testpoint is one behaviour of a feature that must be shown to hold, written as one or two sentences, with the requirements it covers.
   A testpoint is not a module of the testbench.
   The module that proves it is a checker, and one checker proves one or more testpoints ([Feature checkers](#feature-checkers)).
4. **Checks.**
   153 checks, the rows of the testpoints' check tables.
   A check is a sentence that says what must hold.
   Each has a planned assertion, named `assert_<Testpoint>_<Check>`.
   A requirement names the checks that decide it, and why.

Two more words describe the testbench.
A checker is a module that holds the assertions of one part of the subsystem ([Feature checkers](#feature-checkers)).
A proof is one run of the formal tool on the assertions of one checker, or of a part of them ([Proofs](#proofs)).
The design also has access checkers.
They are blocks of the subsystem and not part of the testbench.

### One example through the chain
| Step | Example |
|---|---|
| Specification | [Tag Filter](../theory_of_operation.md#tag-filter); [cheriot.rst, Data Memory Tag Interface](../../../../vendor/lowrisc_ibex/doc/03_reference/cheriot.rst) |
| Requirement | [REQ_TF_02a](requirements.md#req_tf_02a): In CHERIoT mode, a 64-bit-aligned read to a tagged region that the core hints as a capability load shall issue a meta request. |
| Testpoint | [`tf_lookup`](../../data/cheriot_mem_sys_fpv_testplan.hjson#tf_lookup): A request that needs a tag issues exactly one meta request, in the same cycle. Every other request issues none. |
| Checker | The tag path checker, the module that holds the assertions of `tf_lookup` |
| Check | *lookup in same cycle*, one of the 3 checks of `tf_lookup` (*lookup in same cycle*, *no unneeded lookup*, *lookup carries valid integrity*) |
| Planned assertion | `assert_TfLookup_LookupInSameCycle` |
| Why the check proves the requirement | For every request that needs a lookup, the check requires its meta request. A hinted aligned read to a tagged region in CHERIoT mode is one, so a missing lookup fails it. |

### Sources
Each requirement names its source: a section, a register or a configuration key of the documents below.
Where none of these documents states the rule, the requirement says so.

| Source | Documents | What the plan takes from them |
|---|---|---|
| The block specification | [theory of operation](../theory_of_operation.md), [interfaces](../interfaces.md), [programmer's guide](../programmers_guide.md), [registers](../registers.md), [overview](../../README.md), [block description](../../data/cheriot_mem_sys.hjson) | The rules of every datapath block, register, alert and countermeasure |
| The core | [Ibex CHERIoT extension](../../../../vendor/lowrisc_ibex/doc/03_reference/cheriot.rst), [Ibex load-store unit](../../../../vendor/lowrisc_ibex/doc/03_reference/load_store_unit.rst), CHERIoT architecture specification v1.0 | What the core sends and expects: the tag signals, the order of its accesses, the capability rules |
| Common rules | [TL-UL](../../../tlul/README.md), [TL-UL protocol checker](../../../tlul/doc/TlulProtocolChecker.md), [comportability](../../../../../doc/contributing/hw/comportability/README.md), TileLink specification 1.9.3 | Bus handshakes and answers, interrupts and register behaviour |

### Check kinds
The testplan gives each check a kind:

| Kind | What it says |
|---|---|
| `forward` | When the cause happens, the design responds, and in time. |
| `backward` | The design responds only when the cause happened. |
| `both` | The check holds in both directions: the design responds when the cause happens, and only then. |
| `safety` | The condition holds in every cycle, whatever came before. |
| `liveness` | Something must happen at some point, for example that every request is accepted and answered. The check needs the neighbours to accept and answer too ([Assumptions](#assumptions)). |
| `stable` | A value does not change without its cause. |

## Scope
### Features
The table names the part of the testbench that checks each feature of the subsystem.

| Feature | Checked by |
|---|---|
| The core's tag filter, including the capability store to the NVM that the WTRC handles | The tag path checker |
| The 2:1 tag arbiter and the RMW filter | The tag path checker |
| The access checkers and the 4:1 arbiter in front of `meta_sram_tl`, and the protection of the tag store | The meta access checker |
| The revocation engine: start, status and interrupt, the sweep, the decision and the tag clears, the watch on the core's writes, errors | The revocation engine checker |
| Register access rules: the sweep registers, the interrupt state, the request rate and the alert on a request with a broken integrity code | The register checker |
| The fatal alert | The tag path checker for the faults of the tag path, the revocation engine checker for the faults of the engine |
| The reset value and the access type of every register field, and the alert test | The register tests and the alert test of the simulation testbench |
| The TL-UL protocol on every port | The TL-UL ABVIP |
| The tag read after a write, the absence of a deadlock and a revoked capability's tag after a sweep | The checks of the checkers above, combined |

[Testbench architecture](#testbench-architecture) describes each of these parts.

### Security countermeasures
The block description lists the security countermeasures of the subsystem.
OpenTitan's testplan for them is [`cheriot_mem_sys_sec_cm_testplan.hjson`](../../data/cheriot_mem_sys_sec_cm_testplan.hjson).
The table shows what each countermeasure is and which testpoints of this plan check the behaviour behind it.
Each testpoint is due at the stage of its feature ([Sign-off criteria per stage](#sign-off-criteria-per-stage)), so the testpoints of one countermeasure can sit at different stages.
The testpoints of the fatal alert and of the protection of the tag store are due at stage V2S.

| Countermeasure | What it is | Testpoints |
|---|---|---|
| `BUS.INTEGRITY` | End-to-end bus integrity. Every request that the subsystem generates carries a valid command integrity code. | `tf_lookup`, `rmw_read`, `tbre_sweep`, `tbre_decision` |
| `MEM.SW_NOACCESS` | The capability tag store is not memory mapped. No request outside its requester's region reaches the meta SRAM. | `meta_refuse`, `tag_isolation` |
| `INTERSIG.MUBI` | The mode enable is a multi-bit signal. Any value other than `MuBi4True` is ePMP mode, which the meta SRAM does not serve. | `tf_lookup`, `meta_refuse`, `tag_isolation` |

### Out of scope
The plan leaves out the cases below.
Each point gives the reason.

* **The TL-UL integrity functions.**
  The environment computes the integrity codes it expects with the same functions that the design uses.
  It therefore checks that the subsystem encodes the right fields and that it rejects a wrong code.
  It does not check that the functions compute the right code.
* **A core that breaks its own access order.**
  The core loads and stores a capability as two words in a fixed order.
  The proofs assume this order ([Assumptions](#assumptions)), so they never present a request out of the order.
  The plan therefore has no check for the alert that the subsystem raises for such a request ([REQ_WTRC_12](requirements.md#req_wtrc_12)).
* **The lockstep countermeasures and the end-to-end part of bus integrity.**
  The block description marks `LOGIC.SHADOW` and `CORED_TAG.INTERSIG.MUBI` as not implemented, and it says that `BUS.INTEGRITY` relies on `LOGIC.SHADOW`.
  No document states what these countermeasures require.
  The plan checks the integrity rules that the documents give for each port, and it has no requirement for the lockstep.

## Testbench architecture
This is the planned architecture.
The formal top is the whole `cheriot_mem_sys`, with Earl Grey's parameters.
One environment module, `cheriot_mem_sys_fpv_env`, holds the design with every input free.
One checker module, `cheriot_mem_sys_fpv_checker`, is bound into it.
A bound module is attached to the design and reads its signals, and the design itself stays unchanged.
The checker module reads every port of the subsystem and these internal signals:

* the ports between the blocks of the tag path and of the revocation engine, such as the input and the output of the 2:1 tag arbiter;
* the register file's outputs to the hardware and the hardware's writes into the registers;
* the fault inputs of the alert logic and the request that reaches the alert sender.

Each rule that the environment makes about a neighbour is written once.
The formal tool assumes it, and a simulation of the same bind asserts it.

![The FPV environment bound into the subsystem, drawn for Earl Grey: the blocks each checker watches, and the TL-UL ABVIP on each port](cheriot_mem_sys_fpv_tb.svg)

The environment has one shared part and four checkers.
The shared part is described first.

### TL-UL ABVIP
`tlul_abvip` is a set of TL-UL protocol assertions for formal.
ABVIP stands for assertion-based verification IP.
An instance sits on each TL-UL port of the subsystem and plays one of three roles:

* **Plays the host.**
  The instance assumes that the host follows the TL-UL rules and asserts that the device follows them.
  It sits on the ports where a neighbour sends requests.
* **Plays the device.**
  The instance does the reverse, on the ports where a neighbour answers.
* **Checks both ends.**
  The instance assumes nothing and asserts every rule.
  It sits on a link between two blocks of the subsystem, where both ends are real.

An instance holds the rules of TL-UL only.
A rule that is specific to this design, such as which addresses hold capabilities or the order of a capability's two words, is an assumption on top of the instance ([Assumptions](#assumptions)).
The testpoint `tlul_protocol` holds the one check that the TL-UL rules hold on every port.

### Feature checkers
| Checker | What it checks | Testpoints it proves |
|---|---|---|
| Tag path checker | The core's tag filter with the WTRC, the 2:1 tag arbiter and the RMW filter, and the alert on a tag path fault | `tf_*`, `wtrc_*`, `arb_*`, `rmw_*`, `tag_alerts` |
| Meta access checker | The four access checkers and the 4:1 arbiter onto `meta_sram_tl`, and the protection of the tag store | `meta_*`, `tag_isolation` |
| Revocation engine checker | The engine with its TRVK filter and tag filter, the sweep control and the interrupt, the watch on the core's writes, and the alert on an engine fault | `tbre_*` |
| Register checker | The register file: the locks while a sweep runs, the interrupt state, the request rate and the alert on a request with a broken integrity code | `csr` |

Each checker also proves its part of `contracts` and `alert_causes` ([Contracts between checkers](#contracts-between-checkers)).
The testpoints `tag_read_after_write`, `tag_no_deadlock` and `rev_end_to_end` have no assertions of their own.
Each follows from the checks of the checkers that cover its path, from port to port, and the testplan names those checks.
The tag read after a write also relies on one assumption: the meta SRAM returns the word last written ([Assumptions](#assumptions)).
The testpoint `alert_test` is decided by the alert test of the simulation testbench.
The meta access checker repeats its checks for each of the four requester ports.
Each assertion has the name that its check plans, such as `assert_TfMetaRequest_TagWordAndBit`.

### Register checker
The register checker proves the register file on its own.
The real register file is the only block in the proof, and the hardware side of the registers is free, so the proof holds for every behaviour of the engine.
The checker keeps a model of the value that `TBRE_STATUS.busy` holds, which is the hardware's last write.
The model also gives the data that a good read of `TBRE_BASE_ADDR`, `TBRE_NUM_CAPS`, `TBRE_REGWEN` or `TBRE_STATUS.busy` must return.
A good request is a whole aligned word with valid command and data integrity.
The checks claim nothing about the data of any other request, which the register file may answer with an error.
The register tests of the simulation testbench run with CHERIoT mode off and leave out `TBRE_START`.
They therefore never see the hardware lower `TBRE_REGWEN`.
The register checker covers that case.

### Independence from the RTL
Each assertion compares the design with an expected value, for example the tag word that an address maps to.
If a checker took such a value from the RTL, a wrong value in the RTL would be wrong on both sides, and the assertion would still pass.
The environment therefore takes its expected values from the documents, except for the values named after the table.

| Expected value | Where the environment takes it from |
|---|---|
| The address ranges of the regions | The parameters of `interfaces.md` |
| The tag word and bit of an address, and the revocation word and bit of a heap address | The meta SRAM address map of the theory of operation |
| The swept capabilities of a sweep and the starts that are taken | The revocation engine section of the theory of operation |
| A capability's base and whether it is a sealing capability | The CHERIoT architecture specification, which the environment decodes itself |
| Which accesses an access checker lets through | The access checkers section of the theory of operation |
| TL-UL integrity codes | The integrity functions of `tlul_pkg`, in the RTL |

The integrity codes come from the RTL, which is why the integrity functions are [out of scope](#out-of-scope).
The environment also takes the port types and widths, the multi-bit mode constants and the register offsets from the RTL's packages, as the definition of the interface it connects to.

## Verification strategy
Three words describe how the proofs are set up:

* An **abstraction** lets a part of the design, or its start state, take more values than it really can, or leaves a part out, so that one proof covers more cases.
  It removes no real behaviour.
* A **constraint** narrows what the proofs explore.
  Each constraint says what it leaves unchecked.
* An **assumption** is a rule that the environment makes the neighbours of the subsystem follow.
  Each assumption names the document that gives the rule, or says that no specification gives it.

### Proofs
The whole subsystem in one proof may never finish, so the plan splits it by feature.
Each feature proof holds the real blocks of one checker and cuts the blocks outside it ([Abstractions](#abstractions)).
Every proof starts with the reset applied.

| Proof | Checker | Testpoints | Real blocks | Cut blocks |
|---|---|---|---|---|
| Tag path | Tag path checker | `tf_*`, `wtrc_*`, `arb_*`, `rmw_*`, `tag_alerts` | The core's tag filter with the WTRC, the 2:1 tag arbiter, the RMW filter, the core write watch, the alert logic | The access checkers, the 4:1 arbiter, the revocation engine, the register file |
| Meta access | Meta access checker | `meta_*`, `tag_isolation` | The four access checkers, the 4:1 arbiter | The tag path, the revocation engine, the register file |
| Revocation engine | Revocation engine checker | `tbre_*` | The engine with its filters, the sweep control, the core write watch, the 2:1 tag arbiter, the alert logic | The core's tag filter, the RMW filter, the access checkers, the 4:1 arbiter; the register file follows a model |
| Register block | Register checker | `csr` | The register file | Everything else |
| Whole subsystem | All checkers | Every assertion of the four checkers, contracts included | Every block | None |
| The design's own assertions | None: the assertions written in the RTL | - | As in the feature proof that holds them | As in that proof |

A check runs in a proof of its own where it needs an assumption that would narrow the other checks of its checker, or where proving it with them would close a cycle of contracts.
The checks of kind `liveness` are the usual case.
A proof counts as proven only when every contract that it assumes is proven ([Contracts between checkers](#contracts-between-checkers)).
The whole-subsystem proof assumes only the rules on the subsystem's own ports.
It shows that the contracts and the rules on the internal neighbours were the right ones.
The sweep of the engine and the number of capabilities make its state space deep, so it runs to a bounded depth first, and its result names the depth.

### Abstractions
The proofs use the abstractions below.
Each table says what the design really does, what the proof does instead, and why the result still holds for the real design.

| Abstraction | A block outside the checker is cut |
|---|---|
| In the design | Every block produces its outputs from its own logic. |
| In the proof | The block is left out and its outputs take any value that its neighbour is allowed to produce. A contract limits them where a check needs it. |
| What it gains | Each checker is small enough to converge, and the blocks that a checker watches stay real. |
| Why it is sound | The free outputs include every value of the real block, so an assertion that holds for all of them holds for the real block too. |
| What it hides | Whether the block produces the right values. The checker that holds the block proves that, through a contract. |
| Used in | Every feature proof |

| Abstraction | The register file follows a model in the revocation engine proof |
|---|---|
| In the design | The register file drives the engine from its registers, and the engine writes the status registers. |
| In the proof | The register file is cut. Its outputs follow its rules: the sweep range is locked while `TBRE_REGWEN` is 0, the start strobe comes only while it is 1, the interrupt state rises only on a set request, and `TBRE_STATUS.busy` shows what the engine wrote. |
| What it gains | The engine proof has no register bus, so it is smaller. |
| Why it is sound | The register checker proves that the real register file follows these rules for every behaviour of the engine. |
| What it hides | The lock and the status that software reads through `regs_tl_d`. The register checker checks them. |
| Used in | The revocation engine proof |

| Abstraction | The epoch count starts at any value |
|---|---|
| In the design | `TBRE_EPOCH` starts at 0 and counts the sweeps that end without an error. |
| In the proof | The count starts at any value. |
| What it gains | The proof reaches the wrap of the count without running every sweep before it. |
| Why it is sound | Every value is one that the count reaches after enough sweeps, so the start values include every state that the real design reaches. |
| What it hides | The reset value of the count. The register tests of the simulation testbench check it. |
| Used in | The revocation engine proof |

### Contracts between checkers
A contract is a property that one checker assumes about a block it cuts and that another checker proves on the real block.
The testpoint `contracts` holds the checks that prove them.
Two examples are that the engine's tag filter keeps a request unchanged until it is accepted, and that the RMW filter accepts and answers every request.
No proof assumes a contract that was proven with its own help.
The proofs therefore run in an order: a proof starts when the contracts it assumes are proven by earlier proofs, and the checks that need none run first.

### Constraints
Each constraint makes the proofs shorter.
Its last sentence says what it leaves unchecked.

* **The mode enable keeps its value from reset** (`cheriot_ena_i`).
  The mode enable is driven by a write-once switch in `rv_core_ibex` ([Block Diagram](../theory_of_operation.md#block-diagram)), and a proof takes each of its 16 values.
  No document says what the subsystem does with an access that is in flight when the mode enable changes.
  The proofs therefore do not check the change from one value to another.
* **No parameter is reduced.**
  The instance parameters are already small: two outstanding accesses and 32-bit words.
  The proofs run at these values, so a requirement that depends on a larger instance stays unchecked.

### Assumptions
The environment assumes the rules below about the neighbours of the subsystem.
Every other input is free.
This includes every address, opcode, size, mask, data value and tag sideband that TL-UL allows, every `d_error`, every integrity value, a broken one included, and any content of a meta SRAM word.

* **The core keeps a request unchanged until the subsystem accepts it** (`cored_tl_d`, `cored_tag_h2d`).
  The Ibex load-store unit documents this for its own request signal ([load_store_unit.rst, Data-Side Memory Interface](../../../../vendor/lowrisc_ibex/doc/03_reference/load_store_unit.rst)).
  No document restates it for `cored_tl_d`.
* **The core has at most two requests outstanding** (`cored_tl_d`).
  The load-store unit never issues more than two outstanding halves of a split access ([Tag Filter](../theory_of_operation.md#tag-filter)).
* **The core loads and stores a capability in sequence** (`cored_tl_d`).
  It reads the lower word and then, as the next request, the upper word ([cheriot.rst, Data Memory Tag Interface](../../../../vendor/lowrisc_ibex/doc/03_reference/cheriot.rst)).
  Each read is a full word with the tag sideband set ([load_store_unit.rst, Data-Side Memory Interface](../../../../vendor/lowrisc_ibex/doc/03_reference/load_store_unit.rst)).
  It stores a capability to the NVM as two words and issues nothing else until the second is answered ([Write-to-Read-and-Compare Filter (WTRC)](../theory_of_operation.md#write-to-read-and-compare-filter-wtrc)).
* **A write narrower than a whole word carries tag 0** (`cored_tag_h2d`).
  Only a store of a tagged capability sets a tag (CHERIoT architecture specification v1.0, section 7.7).
* **`xbar_main` answers the subsystem's data requests in request order** (`cored_tl_h`).
  The load-store unit assumes this ([load_store_unit.rst, Protocol](../../../../vendor/lowrisc_ibex/doc/03_reference/load_store_unit.rst)).
  No specification states it for the engine's reads on `tbre_tl_h`, so the environment assumes it there too.
* **`xbar_main` answers a request in a later cycle, and holds an answer unchanged until the subsystem takes it** (`cored_tl_h`).
  No specification states these two rules.
  They follow what the Earl Grey crossbar and its adapters do.
* **The meta SRAM answers a request in a later cycle, in request order, and holds each answer unchanged until taken** (`meta_sram_tl`).
  No specification states these rules.
  They follow what the Earl Grey meta SRAM controller does.
  This assumption applies only to the proof of the contract that the tag port answers in order.
* **The meta SRAM returns, for a read, the word last written to that address** (`meta_sram_tl`).
  The plan does not model the memory, so the end-to-end tag requirements follow from the checks of the tag path only under this rule.
* **The neighbours follow the TL-UL rules.**
  A device returns the request's source ID in its answer ([Source ID requirements for device elements](../../../tlul/README.md#source-id-requirements-for-device-elements)).
  A host uses only the low bits of the source ID and leaves the top bits free for the bits that the arbiters add ([Source ID requirements for host elements](../../../tlul/README.md#source-id-requirements-for-host-elements), [Source ID growth](../../../tlul/README.md#source-id-growth)).
* **The neighbours eventually accept a request and answer it, and a host eventually takes an answer** (`cored_tl_h`, `tbre_tl_h`, `meta_sram_tl`, `revbm_tl_d`, `corerevbm_tl`).
  The rule is TileLink's rule against deadlock (TileLink specification 1.9.3, section 5, page 29).
  Only the checks of kind `liveness` need it.

The design's own assertions are proven as targets, and the plan never uses them as assumptions.

### Vacuity and covers
An assertion can pass for a bad reason: its trigger never happens, or an assumption blocks the case that it is about.
Such a pass is vacuous and proves nothing.
The plan uses covers to find these cases.
A cover asks the formal tool for one trace in which a named event happens.
Every proof runs its covers before its assertions.

| Covers | What a reached cover shows | What it means when the cover is not reached |
|---|---|---|
| One per assertion, on the assertion's trigger | The trigger happens under the assumptions of its proof, so the assertion is tested. | The assertion passes without a test. Its requirement does not close ([Sign-off criteria per stage](#sign-off-criteria-per-stage)). |
| One per assumption | The assumption allows the case that it is about. Examples are two outstanding core requests, a capability store of two words, each of the 16 values of the mode enable and two answers in order on `cored_tl_h`. | The assumption is too tight. |
| One per contract that a proof assumes | The assumed property happens in that proof. | The assumption is too tight. |

### Sign-off criteria per stage
The stages are OpenTitan's [verification stages for FPV](../../../../../doc/project_governance/development_stages.md).
A requirement closes when its checks are proven and their covers are reached.
Every proof that those checks rely on must be proven too.

| Stage | OpenTitan's main criteria (the full list: verification stages for FPV) | In this plan |
|---|---|---|
| V1 | Testplan completed and reviewed; the design bound to the assertion modules, with the interface assertion monitors hooked up; known-value assertions on the outputs; the assertions of the main functional path implemented and passing; each input and output part of at least one assertion; a regression set up. | The testpoints of the tag path in its plain mode: `tf_forward`, `tf_lookup`, `tf_meta_request`, `tf_sticky_tag`, `arb_forward`, `arb_return`, `rmw_read`, `rmw_write_skip`, `rmw_write_back`, `meta_forward` and `meta_return`. This path is what the block exists for. The TL-UL ABVIP is bound. |
| V2 | This document complete; all functional assertions written and enabled; the assumptions specified and reviewed; 90 % of the properties proven; 90 % code coverage and 75 % cone-of-influence coverage. | Every other functional testpoint, the checks of `contracts` and `tlul_protocol`, and the register checker. |
| V2S | All checks of the security countermeasures passing. | `tf_errors`, `wtrc_faults`, `rmw_errors`, `tag_alerts`, `meta_refuse`, `tag_isolation`, `tbre_errors`, `alert_causes` and `alert_test`. |
| V3 | All assertions proven, with reviewed assumptions; 100 % code and cone-of-influence coverage. | Every testpoint. |

## Building and running tests
The environment's [dvsim](https://github.com/lowRISC/dvsim) entry is `cheriot_mem_sys_fpv`, in the formal configuration of Earl Grey.

## Requirements
[requirements.md](requirements.md) holds the 239 requirements, for reading.
[`cheriot_mem_sys_fpv_requirements.hjson`](../../data/cheriot_mem_sys_fpv_requirements.hjson) holds the same rows as data.
235 of them state a rule the specification gives (kind `spec`).
4 state a rule that no specification gives (kind `RTL`).
These follow the design's present behaviour.

The requirements that no check of this plan decides, by what decides them:

* **Out of scope** ([Out of scope](#out-of-scope)): [REQ_WTRC_12](requirements.md#req_wtrc_12).
* **The alert sender's own testbench** ([prim_alert_rxtx_fatal_tb.sv](../../../prim/fpv/tb/prim_alert_rxtx_fatal_tb.sv)): [REQ_TAG_10](requirements.md#req_tag_10).
* **The register tests of the simulation testbench** ([csr_testplan.hjson](../../../../dv/tools/dvsim/testplans/csr_testplan.hjson)): [REQ_TBRE_04b](requirements.md#req_tbre_04b), [REQ_TBRE_36b](requirements.md#req_tbre_36b), [REQ_REG_01a](requirements.md#req_reg_01a), [REQ_REG_01b](requirements.md#req_reg_01b), [REQ_ALT_01](requirements.md#req_alt_01).
* **The alert test of the simulation testbench** ([alert_test_testplan.hjson](../../../../dv/tools/dvsim/testplans/alert_test_testplan.hjson)): [REQ_ALT_02](requirements.md#req_alt_02), [REQ_ALT_03a](requirements.md#req_alt_03a), [REQ_ALT_03b](requirements.md#req_alt_03b).

## Testplan
[Testplan](../../data/cheriot_mem_sys_fpv_testplan.hjson)
