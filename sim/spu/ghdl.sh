#!/bin/sh
# SPU testbench (GHDL, MSYS2 mingw64). Uses the altera_mf / mem libraries built by sim/gpu/ghdl.sh.
#   ./ghdl.sh compile <name> [spu.vhd]      # default rtl/spu.vhd
#   ./ghdl.sh sim <name> <LAT> [SAMPLES]
export PATH=/c/msys64/mingw64/bin:$PATH
R=../../rtl
L=../gpu/ghdl
O="--std=08 -frelaxed -fsynopsys -Wno-hide -Wno-shared -Wno-binding"
set -e
if [ "$1" = compile ]; then
   rm -rf ghdl/$2; mkdir -p ghdl/$2
   ghdl -a $O --workdir=ghdl/$2 -P$L probe_stub.vhd $R/dpram.vhd $R/spu_gauss.vhd $R/spu_ram.vhd ${3:-$R/spu.vhd} tb_spu.vhd
   ghdl -e $O --workdir=ghdl/$2 -P$L -o ghdl/tb_$2.exe tb_spu
else
   ./ghdl/tb_$2.exe -gLAT=$3 -gSAMPLES=${4:-3000} --ieee-asserts=disable 2>&1 | grep -v "assertion note"
fi
