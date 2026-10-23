#!/bin/sh
# usage: sim/ns10/run_autofire.sh [seed]  - ns10_autofire (landing-synced Drill (Auto)) + ns10_io, Mr. Driller game model
MS=/c/intelFPGA_lite/17.0/modelsim_ase/win32aloem
cd "$(dirname "$0")"
[ -d work ] || $MS/vlib work
$MS/vlog -sv -quiet ../../rtl/ns10/ns10_io.sv ../../rtl/ns10/ns10_autofire.sv tb_autofire.sv || exit 1
# wall clock limit 15 min (CLAUDE.md); the tb has a sim time limit and a no-VBlank watchdog
timeout 900 $MS/vsim -c -quiet tb_autofire -sv_seed "${1:-1}" -do "run -all; quit -f" || echo "vsim exit $? (124 = 15 min wall clock timeout)"
