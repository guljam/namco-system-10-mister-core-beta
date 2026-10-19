#!/bin/sh
# GPU testbench: ./run.sh compile <lib> [pixelpipeline.vhd]   (lib = work directory name, e.g. new / old)
#                ./run.sh sim <lib> <dir> [LAT] [FIELDLOCK]       (dir holds cmd.txt + vram_in.hex)
MS=/c/intelFPGA_lite/17.0/modelsim_ase/win32aloem
R=../../rtl
set -e
if [ "$1" = compile ]; then
   PP=${3:-$R/gpu_pixelpipeline.vhd}
   [ -d mem ] || { $MS/vlib mem; $MS/vmap altera_mf /c/intelFPGA_lite/17.0/modelsim_ase/altera/vhdl/altera_mf >/dev/null;
                   $MS/vcom -quiet -2008 -work mem $R/RamMLAB.vhd $R/dpram.vhd $R/SyncFifo.vhd $R/SyncFifoFallThrough.vhd; }
   rm -rf $2; $MS/vlib $2
   . ./gen.sh
   $MS/vcom -quiet -2008 -work $2 $GPU_FILES
else
   D=$3
   $MS/vsim -c -quiet -work $2 tb_gpu -GCMDFILE=$D/cmd.txt -GVRAMIN=$D/vram_in.hex -GVRAMOUT=$D/vram_$2.hex \
      -GLOGFILE=$D/log_$2.txt -GLAT=${4:-14} -GFIELDLOCK=${5:-1} -do "run -all; quit -f" | grep -v "^# //" | tail -5
fi
