#!/bin/sh
# usage: sim/ns10/run_nvload.sh [+noinval]   (DDR3 fast load: settings region rebuild, tb_nvload.sv)
MS=/c/intelFPGA_lite/17.0/modelsim_ase/win32aloem
cd "$(dirname "$0")"
[ -d work ] || $MS/vlib work
$MS/vlog -sv -quiet ../../rtl/ns10/ns10_nvload.sv ../../rtl/ns10/ns10_nvram.sv ../../rtl/ns10/ns10_romcache.sv \
	../../rtl/ns10/ns10_ddram_arb.sv tb_nvload.sv || exit 1
# wall clock limit 15 min (CLAUDE.md) (the tb also has a sim time limit and stall watchdogs)
timeout 900 $MS/vsim -c -quiet -L altera_mf_ver tb_nvload $1 -do "run -all; quit -f" || echo "vsim exit $? (124 = 15 min wall clock timeout)"
