#!/bin/sh
# usage: sim/ns10/run_irq10.sh [seed]  - ns10_io IRQ10 100 Hz / 2x VBlank (1/4,3/4 and 5/8,7/8), Mr. Driller input model
MS=/c/intelFPGA_lite/17.0/modelsim_ase/win32aloem
cd "$(dirname "$0")"
[ -d work ] || $MS/vlib work
$MS/vlog -sv -quiet ../../rtl/ns10/ns10_io.sv tb_irq10.sv || exit 1
# wall clock limit 15 min (CLAUDE.md); the tb has a sim time limit and a no-IRQ10 watchdog
timeout 900 $MS/vsim -c -quiet tb_irq10 -sv_seed "${1:-1}" -do "run -all; quit -f" || echo "vsim exit $? (124 = 15 min wall clock timeout)"
