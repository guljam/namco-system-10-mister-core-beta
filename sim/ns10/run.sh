#!/bin/sh
# usage: sim/ns10/run.sh <vector dir from tools/ns10cfg.py tbvec> [max vectors]
MS=/c/intelFPGA_lite/17.0/modelsim_ase/win32aloem
cd "$(dirname "$0")"
[ -d work ] || $MS/vlib work
$MS/vlog -sv -quiet ../../rtl/ns10/ns10_cfg.sv ../../rtl/ns10/ns10_io.sv ../../rtl/ns10/ns10_crypt.sv \
	../../rtl/ns10/ns10_romboard.sv ../../rtl/ns10/ns10_romcache.sv ../../rtl/ns10/ns10_ddram_arb.sv tb_ns10.sv || exit 1
# wall clock limit 15 min (CLAUDE.md); the tb has a sim time limit (+limit_ms=) and stall watchdogs
timeout 900 $MS/vsim -c -quiet tb_ns10 +dir="$1" +max="${2:-0}" $3 -do "run -all; quit -f" || echo "vsim exit $? (124 = 15 min wall clock timeout)"
