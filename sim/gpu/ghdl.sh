#!/bin/sh
# GHDL (MSYS2 mingw64, LLVM backend) variant of run.sh, ~9x faster than ModelSim ASE. Run from an MSYS2 MINGW64 shell.
#   ./ghdl.sh compile <lib> [pixelpipeline.vhd]
#   ./ghdl.sh sim <lib> <dir> [LAT] [FIELDLOCK]
export PATH=/c/msys64/mingw64/bin:$PATH
R=../../rtl
O="--std=08 -frelaxed -fsynopsys -Wno-hide -Wno-shared -Wno-binding"
set -e
if [ "$1" = compile ]; then
   PP=${3:-$R/gpu_pixelpipeline.vhd}
   mkdir -p ghdl
   if [ ! -f ghdl/mem-obj08.cf ]; then
      L=/c/intelFPGA_lite/17.0/quartus/eda/sim_lib
      ghdl -a $O --workdir=ghdl --work=altera_mf $L/altera_mf_components.vhd $L/altera_mf.vhd
      ghdl -a $O --workdir=ghdl --work=mem -Pghdl $R/RamMLAB.vhd $R/dpram.vhd $R/SyncFifo.vhd $R/SyncFifoFallThrough.vhd
   fi
   rm -rf ghdl/$2; mkdir -p ghdl/$2
   . ./gen.sh
   ghdl -a $O --workdir=ghdl/$2 -Pghdl $GPU_FILES
   ghdl -e $O --workdir=ghdl/$2 -Pghdl -o ghdl/tb_$2.exe tb_gpu
else
   D=$3
   ./ghdl/tb_$2.exe -gCMDFILE=$D/cmd.txt -gVRAMIN=$D/vram_in.hex -gVRAMOUT=$D/vram_$2.hex -gLOGFILE=$D/log_$2.txt \
      -gLAT=${4:-14} -gFIELDLOCK="'${5:-1}'" --ieee-asserts=disable 2>&1 | grep -v "^.*(assertion note)" | tail -3
fi
