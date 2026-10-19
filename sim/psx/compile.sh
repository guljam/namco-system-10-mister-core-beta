#!/bin/sh
# Compile the PSX VHDL core with ModelSim ASE (syntax/elaboration check and sim base).
MS=/c/intelFPGA_lite/17.0/modelsim_ase/win32aloem
R=../../rtl
set -e
rm -rf work mem
$MS/vlib work; $MS/vlib mem
$MS/vmap altera_mf /c/intelFPGA_lite/17.0/modelsim_ase/altera/vhdl/altera_mf >/dev/null
$MS/vcom -quiet -2008 -work mem $R/RamMLAB.vhd $R/dpram.vhd $R/SyncFifo.vhd $R/SyncFifoFallThrough.vhd $R/SyncFifoFallThroughMLAB.vhd $R/SyncRam.vhd $R/SyncRamDual.vhd $R/SyncRamDualNotPow2.vhd $R/SyncRamDualByteEnable.vhd
FILES=$(grep -o "[A-Za-z0-9_]*.vhd" $R/psx.qip | sed "s%^%$R/%")
$MS/vcom -quiet -2008 -work work $FILES
