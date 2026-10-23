#!/bin/sh
# Savestate register round trip of ns10_romboard / ns10_crypt / ns10_io (tb_ssregs.sv), ModelSim ASE.
MS=/c/intelFPGA_lite/17.0/modelsim_ase/win32aloem
cd "$(dirname "$0")"
[ -d work ] || $MS/vlib work
$MS/vlog -sv -quiet ../../rtl/ns10/ns10_io.sv ../../rtl/ns10/ns10_crypt.sv ../../rtl/ns10/ns10_romboard.sv tb_ssregs.sv || exit 1
# wall clock limit 15 min (CLAUDE.md); the tb has a sim time limit
timeout 900 $MS/vsim -c -quiet tb_ssregs -do "run -all; quit -f" || echo "vsim exit $? (124 = 15 min wall clock timeout)"
