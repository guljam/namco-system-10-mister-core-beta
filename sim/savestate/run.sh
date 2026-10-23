#!/bin/sh
# Savestate round trip sim (GHDL, MSYS2 mingw64): psx_mister + NS10 BIOS, save slot 0, restore, compare. See tb_ss.tmpl.
#   ./run.sh bios <game>                  # ghdl/bios_<game>.bin from the MAME ROM zip (tools/ns10model.py), e.g. mrdrilr2j
#   ./run.sh compile                      # RTL of the working tree
#   ./run.sh sim <game> <out> [t_save_us] [n_instr]
#        modes of tb_ss.tmpl: empty in parallel with save, then load from the save's slot file
# Every run: 15 min wall clock limit (timeout 900) + in-bench sim time limit and stall watchdog.
export PATH=/c/msys64/mingw64/bin:$PATH
cd "$(dirname "$0")"
O="--std=08 -frelaxed -fsynopsys -Wno-hide -Wno-shared -Wno-binding"
set -e
mkdir -p ghdl
case "$1" in
bios)
   python mktb.py bios "$2" ghdl/bios_$2.bin ;;
compile)
   R=gen/rtl; rm -rf gen; mkdir -p $R
   cp ../../rtl/*.vhd ../../rtl/psx.qip $R/
   # GHDL fixes as in sim/cpu/run.sh (sim copies only)
   sed -i 's/: if 1 = 1 generate/: if 1 = 0 generate/' $R/*.vhd
   sed -i -e 's/to_unsigned(/to_unsigned_w(/g' \
       -e '/^architecture arch of gpu_videoout_async is/a\   function to_unsigned_w(v : integer; n : natural) return unsigned is begin return to_unsigned(v mod 2**n, n); end function;' \
       $R/gpu_videoout_async.vhd
   sed -i 's/if (to_integer(xStart(43 downto 32)) > drawingAreaRight) then/if (to_integer(xStart(43 downto 32)) > to_integer(drawingAreaRight)) then/' $R/gpu_poly.vhd
   sed -i -E 's/((i_pixel_out_y|ypos_cross|ypos_screen|ypos_gun) *=> *)to_integer\([^)]*\)/\10/' $R/gpu_videoout.vhd
   sed -i -E 's/to_unsigned\(to_integer\((joypad[12]\.Analog1[XY]) \+ 128\), 8\)/to_unsigned(to_integer(\1) + 128, 8)/' $R/psx_top.vhd
   sed -i '0,/^   end record;/s//&\n   signal tb_cpu_done : std_logic;\n   signal tb_cpu_export : cpu_export_type;/' $R/export.vhd
   sed -i 's/^   gexport : if is_simu = .1. generate/   tb_cpu_done <= cpu_done; tb_cpu_export <= cpu_export;\n   gexport : if 1 = 0 generate/' $R/psx_top.vhd
   L=/c/intelFPGA_lite/17.0/quartus/eda/sim_lib
   [ -f ghdl/altera_mf-obj08.cf ] || ghdl -a $O --workdir=ghdl --work=altera_mf $L/altera_mf_components.vhd $L/altera_mf.vhd
   rm -rf ghdl/w ghdl/mem; mkdir -p ghdl/w ghdl/mem
   ghdl -a $O --workdir=ghdl/mem --work=mem -Pghdl $R/RamMLAB.vhd $R/dpram.vhd $R/SyncFifo.vhd $R/SyncFifoFallThrough.vhd \
      $R/SyncFifoFallThroughMLAB.vhd $R/SyncRam.vhd $R/SyncRamDual.vhd $R/SyncRamDualNotPow2.vhd $R/SyncRamDualByteEnable.vhd
   FILES=$(grep -o "[A-Za-z0-9_]*.vhd" $R/psx.qip | sed "s%^%$R/%")
   python simpatch.py $R/savestates.vhd
   python mktb.py tb $R ghdl/w/tb_ss.vhd
   ghdl -a $O --workdir=ghdl/w -Pghdl -Pghdl/mem -Pghdl/w $FILES sdram_model3x.vhd ghdl/w/tb_ss.vhd
   ghdl -e $O --workdir=ghdl/w -Pghdl -Pghdl/mem -Pghdl/w -o ghdl/tb_ss.exe tb_ss ;;
sim)
   G="-gBIOSFILE=ghdl/bios_$2.bin -gT_SAVE_US=${4:-300} -gN_INSTR=${5:-1000} -gSLOTFILE=$3_slot.txt --ieee-asserts=disable"
   ( timeout 900 ./ghdl/tb_ss.exe -gMODE=empty -gOUTNAME=$3_e $G > $3_e.log 2>&1 || true ) &
   timeout 900 ./ghdl/tb_ss.exe -gMODE=save -gOUTNAME=$3_s $G > $3_s.log 2>&1 || true
   timeout 900 ./ghdl/tb_ss.exe -gMODE=load -gOUTNAME=$3_l $G > $3_l.log 2>&1 || true
   wait
   for m in s e l; do echo "== $3_$m"; grep -v "(report note): t=" $3_$m.log | tail -12; grep "(report note): t=" $3_$m.log | tail -1; done
   python cmptr.py $3_s_a.txt $3_l_b.txt
   ;;
esac
