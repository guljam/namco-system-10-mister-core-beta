#!/bin/sh
# usage: sim/crt/run.sh   (rtl/crt_sync.sv against PSX 240p / 480i sync timing, tb_crt_sync.sv)
MS=/c/intelFPGA_lite/17.0/modelsim_ase/win32aloem
cd "$(dirname "$0")"
[ -d work ] || $MS/vlib work
# csync: the composite sync module of sys/sys_top.v (YPbPr sync on Y), taken verbatim except that
# its 'assign csync' line moves below the reg declarations (ModelSim rejects the forward reference)
sed -n '/^module csync/,/^endmodule/p' ../../sys/sys_top.v | tr -d '\r' |
	awk '/^assign csync/ { a = $0; next } /^endmodule/ { print a } { print }' > work/csync.v
$MS/vlog -sv -quiet ../../rtl/crt_sync.sv work/csync.v tb_crt_sync.sv || exit 1
# wall clock limit 15 min (CLAUDE.md) (the tb also has a sim time limit and an edge-count stall check)
timeout 900 $MS/vsim -c -quiet tb_crt_sync -do "run -all; quit -f" || echo "vsim exit $? (124 = 15 min wall clock timeout)"
