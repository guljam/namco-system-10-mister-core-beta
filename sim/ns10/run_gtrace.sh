#!/bin/sh
# ns10_gtrace unit test (ModelSim): VSync() idle events (F/7 enter/leave, F/8 idle per vblank)
MS=/c/intelFPGA_lite/17.0/modelsim_ase/win32aloem
cd "$(dirname "$0")"
[ -d work ] || $MS/vlib work
$MS/vlog -sv -quiet ../../rtl/ns10/ns10_probe.sv ../../rtl/ns10/ns10_gtrace.sv tb_gtrace.sv || exit 1
# wall clock limit 15 min (CLAUDE.md); the tb has a sim time limit and a stall watchdog
timeout 900 $MS/vsim -c -quiet tb_gtrace -do "run -all; quit -f" || echo "vsim exit $? (124 = 15 min wall clock timeout)"
