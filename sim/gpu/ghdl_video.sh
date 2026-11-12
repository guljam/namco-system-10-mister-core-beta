#!/bin/sh
# Video window test (tb_video.vhd): ./ghdl_video.sh [X1 X2]  (hex, default 260 C60). MSYS2 MINGW64 GHDL.
export PATH=/c/msys64/mingw64/bin:$PATH
cd "$(dirname "$0")"
R=../../rtl
O="--std=08 -frelaxed -fsynopsys -Wno-hide -Wno-shared -Wno-binding"
set -e
[ -f ghdl/mem-obj08.cf ] || { echo "run ./ghdl.sh compile <lib> once first (altera_mf / mem libraries)"; exit 1; }
PP=$R/gpu_pixelpipeline.vhd
. ./gen.sh
rm -rf ghdl/video; mkdir -p ghdl/video
ghdl -a $O --workdir=ghdl/video -Pghdl $(echo $GPU_FILES | sed 's/tb_gpu.vhd/tb_video.vhd/')
ghdl -e $O --workdir=ghdl/video -Pghdl -o ghdl/tb_video.exe tb_video
# wall clock limit 15 min (CLAUDE.md); the tb has an 80 ms sim time limit and a stall watchdog
timeout 900 ./ghdl/tb_video.exe -gX1=$((0x${1:-260})) -gX2=$((0x${2:-C60})) --ieee-asserts=disable 2>&1 | grep -E "field|Keep|Crop|Cent|RESULT|FAIL|error" || echo "exit $? (124 = 15 min timeout)"
