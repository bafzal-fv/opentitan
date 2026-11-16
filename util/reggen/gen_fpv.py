# Copyright lowRISC contributors (OpenTitan project).
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
# # Lint as: python3
#
"""Generate FPV CSR read and write assertions from IpBlock
"""

import logging as log
import os.path

import yaml
from mako import exceptions  # type: ignore
from mako.template import Template  # type: ignore
import importlib.resources
from typing import List, Optional

from reggen.ip_block import IpBlock


def gen_fpv(block: IpBlock, outdir: str,
            chk_depend: Optional[List[str]] = None) -> int:
    """Generate the FPV CSR collateral of block into outdir

    For each device interface this writes the legacy <block>_csr_assert_fpv
    module and, from the same register model, the CSR checker
    <block>_csr_chk and its bind file. Two
    core files are written: lowrisc:fpv:<block>_csr_assert (legacy) and
    lowrisc:fpv:<block>_csr_chk. chk_depend lists extra cores the checker
    core depends on, normally the IP's register package core, so that the
    package is compiled before the checker.
    """
    # Read Register templates
    fpv_csr_tpl = Template(
        filename=str(importlib.resources.files('reggen') / "fpv_csr.sv.tpl"))
    csr_chk_tpl = Template(
        filename=str(importlib.resources.files('reggen') / "csr_chk.sv.tpl"))
    csr_chk_bind_tpl = Template(
        filename=str(importlib.resources.files('reggen') / "csr_chk_bind.sv.tpl"))

    device_hier_paths = block.bus_interfaces.device_hier_paths

    # Generate a module with CSR assertions for each device interface. For a
    # device interface with no name, we generate <block>_csr_assert_fpv. For a
    # named interface, we generate <block>_<ifname>_csr_assert_fpv.
    lblock = block.name.lower()
    alias_impl = '_' + block.alias_impl if block.alias_impl else ''
    generated: List[str] = []
    chk_generated: List[str] = []
    for if_name, rb in block.reg_blocks.items():
        if not rb.flat_regs:
            # No registers to check!
            continue

        hier_path = device_hier_paths[if_name]
        if_suffix = '' if if_name is None else '_' + if_name.lower()
        reg_block_path = hier_path + if_suffix

        mod_base = lblock + if_suffix
        mod_name = mod_base + '_csr_assert_fpv'
        filename = mod_name + '.sv'
        generated.append(filename)
        reg_top_path = os.path.join(outdir, filename)
        with open(reg_top_path, 'w', encoding='UTF-8') as fout:
            try:
                fout.write(
                    fpv_csr_tpl.render(block=block,
                                       reg_block_path=reg_block_path,
                                       mod_base=mod_base,
                                       if_name=if_name,
                                       rb=rb))
            except:  # noqa F722 for template Exception handling
                log.error(exceptions.text_error_template().render())
                return 1

        # The CSR checker and its bind, from the same
        # register model. The register block module name follows gen_rtl.
        reg_top_name = mod_base + alias_impl + '_reg_top'
        outputs = [(csr_chk_tpl, mod_base + '_csr_chk.sv', chk_generated),
                   (csr_chk_bind_tpl, mod_base + '_csr_chk_bind.sv',
                    chk_generated)]
        for tpl, filename, files in outputs:
            files.append(filename)
            with open(os.path.join(outdir, filename), 'w',
                      encoding='UTF-8') as fout:
                try:
                    fout.write(tpl.render(block=block,
                                          reg_block_path=reg_block_path,
                                          mod_base=mod_base,
                                          mod_name=reg_top_name,
                                          if_name=if_name,
                                          rb=rb))
                except:  # noqa F722 for template Exception handling
                    log.error(exceptions.text_error_template().render())
                    return 1

    # Generate a fusesoc core file that points at the files we've just
    # generated.
    core_data = {
        'name': "lowrisc:fpv:{}_csr_assert".format(lblock),
        'filesets': {
            'files_dv': {
                'depend': [
                    "lowrisc:tlul:headers",
                    "lowrisc:prim:assert",
                ],
                'files': generated,
                'file_type': 'systemVerilogSource'
            },
        },
        'targets': {
            'default': {
                'filesets': [
                    'files_dv',
                ],
            },
        },
    }
    core_file_path = os.path.join(outdir, lblock + '_csr_assert_fpv.core')
    with open(core_file_path, 'w') as core_file:
        core_file.write('CAPI=2:\n')
        yaml.dump(core_data, core_file, encoding='utf-8')

    # The checker's core: the SV files.
    chk_core_data = {
        'name': "lowrisc:fpv:{}_csr_chk".format(lblock),
        'filesets': {
            'files_dv': {
                'depend': ["lowrisc:dv:csr_chk"] + list(chk_depend or []),
                'files': chk_generated,
                'file_type': 'systemVerilogSource'
            },
        },
        'targets': {
            'default': {
                'filesets': [
                    'files_dv',
                ],
            },
        },
    }
    chk_core_path = os.path.join(outdir, lblock + '_csr_chk.core')
    with open(chk_core_path, 'w') as core_file:
        core_file.write('CAPI=2:\n')
        yaml.dump(chk_core_data, core_file, encoding='utf-8')

    return 0
