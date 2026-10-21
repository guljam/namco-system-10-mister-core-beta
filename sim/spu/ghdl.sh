#!/bin/sh
# SPU testbench (GHDL, MSYS2 mingw64). Uses the altera_mf / mem libraries built by sim/gpu/ghdl.sh.
#   ./ghdl.sh compile <name> [src dir]       # spu.vhd, spu_ram.vhd, spu_gauss.vhd from <src dir> (default rtl)
#   ./ghdl.sh sim <name> <LAT> [SAMPLES] [OUTF]
#      OUTF: one line "left right" per computed sample (compare two builds with cmp)
#   gen/base = the clk1x SPU before the clk2x change (git show 21a4960:rtl/<file>)
#   python mkdbg.py <spu.vhd> gen/<name>/spu.vhd <clk1x|clk2x>   # copy with a per-clock log (ghdl/wlog_<clk>.txt) of
#      voice RAM writes / SPU RAM requests / stash per sample, to find where two builds diverge
export PATH=/c/msys64/mingw64/bin:$PATH
R=../../rtl
L=../gpu/ghdl
O="--std=08 -frelaxed -fsynopsys -Wno-hide -Wno-shared -Wno-binding"
set -e
if [ "$1" = compile ]; then
   S=${3:-$R}
   rm -rf ghdl/$2; mkdir -p ghdl/$2
   ghdl -a $O --workdir=ghdl/$2 -P$L probe_stub.vhd $R/dpram.vhd $S/spu_gauss.vhd $S/spu_ram.vhd $S/spu.vhd tb_spu.vhd
   ghdl -e $O --workdir=ghdl/$2 -P$L -o ghdl/tb_$2.exe tb_spu
else
   ./ghdl/tb_$2.exe -gLAT=$3 -gSAMPLES=${4:-3000} -gOUTF=${5:-none} --ieee-asserts=disable 2>&1 | grep -v "assertion note"
fi
