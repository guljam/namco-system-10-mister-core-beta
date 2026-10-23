#!/bin/sh
# BIOS boot trace (GHDL, MSYS2 mingw64): kseg0 BIOS fetch as i-cache line fill vs the old uncached fetch.
#   ./run.sh compile base|new        # base: rtl/memorymux.vhd from git REF (default HEAD), new: working tree
#   ./run.sh sim <game> [t_us]       # both builds in parallel, then cmpboot.py base.txt new.txt
#                                    # BIOS image: ../savestate/ghdl/bios_<game>.bin (../savestate/run.sh bios <game>)
# Every run: 15 min wall clock limit (timeout 900) + in-bench sim time limit and stall watchdog.
export PATH=/c/msys64/mingw64/bin:$PATH
cd "$(dirname "$0")"
O="--std=08 -frelaxed -fsynopsys -Wno-hide -Wno-shared -Wno-binding"
set -e
case "$1" in
compile)
   V=$2; R=gen_$V/rtl; rm -rf gen_$V; mkdir -p $R
   cp ../../rtl/*.vhd ../../rtl/psx.qip $R/
   if [ "$V" = base ]; then git show ${REF:-HEAD}:rtl/memorymux.vhd > $R/memorymux.vhd; fi
   # GHDL fixes as in sim/savestate/run.sh (sim copies only)
   sed -i 's/: if 1 = 1 generate/: if 1 = 0 generate/' $R/*.vhd
   sed -i -e 's/to_unsigned(/to_unsigned_w(/g' \
       -e '/^architecture arch of gpu_videoout_async is/a\   function to_unsigned_w(v : integer; n : natural) return unsigned is begin return to_unsigned(v mod 2**n, n); end function;' \
       $R/gpu_videoout_async.vhd
   sed -i 's/if (to_integer(xStart(43 downto 32)) > drawingAreaRight) then/if (to_integer(xStart(43 downto 32)) > to_integer(drawingAreaRight)) then/' $R/gpu_poly.vhd
   sed -i -E 's/((i_pixel_out_y|ypos_cross|ypos_screen|ypos_gun) *=> *)to_integer\([^)]*\)/\10/' $R/gpu_videoout.vhd
   sed -i -E 's/to_unsigned\(to_integer\((joypad[12]\.Analog1[XY]) \+ 128\), 8\)/to_unsigned(to_integer(\1) + 128, 8)/' $R/psx_top.vhd
   sed -i '0,/^   end record;/s//&\n   signal tb_cpu_done : std_logic;\n   signal tb_cpu_export : cpu_export_type;/' $R/export.vhd
   sed -i 's/^   gexport : if is_simu = .1. generate/   tb_cpu_done <= cpu_done; tb_cpu_export <= cpu_export;\n   gexport : if 1 = 0 generate/' $R/psx_top.vhd
   G=ghdl_$V; L=/c/intelFPGA_lite/17.0/quartus/eda/sim_lib
   mkdir -p $G
   [ -f $G/altera_mf-obj08.cf ] || ghdl -a $O --workdir=$G --work=altera_mf $L/altera_mf_components.vhd $L/altera_mf.vhd
   rm -rf $G/w $G/mem; mkdir -p $G/w $G/mem
   ghdl -a $O --workdir=$G/mem --work=mem -P$G $R/RamMLAB.vhd $R/dpram.vhd $R/SyncFifo.vhd $R/SyncFifoFallThrough.vhd \
      $R/SyncFifoFallThroughMLAB.vhd $R/SyncRam.vhd $R/SyncRamDual.vhd $R/SyncRamDualNotPow2.vhd $R/SyncRamDualByteEnable.vhd
   FILES=$(grep -o "[A-Za-z0-9_]*.vhd" $R/psx.qip | sed "s%^%$R/%")
   python ../savestate/mktb.py tb $R $G/w/tb_boot.vhd tb_boot.tmpl
   ghdl -a $O --workdir=$G/w -P$G -P$G/mem -P$G/w $FILES ../savestate/sdram_model3x.vhd $G/w/tb_boot.vhd
   ghdl -e $O --workdir=$G/w -P$G -P$G/mem -P$G/w -o $G/tb_boot.exe tb_boot ;;
sim)
   B=../savestate/ghdl/bios_$2.bin
   G="-gBIOSFILE=$B -gT_US=${3:-5000} --ieee-asserts=disable"
   ( timeout 900 ./ghdl_base/tb_boot.exe -gOUTNAME=base $G > base.log 2>&1 || echo "base: exit $?" ) &
   timeout 900 ./ghdl_new/tb_boot.exe -gOUTNAME=new $G > new.log 2>&1 || echo "new: exit $?"
   wait
   for v in base new; do echo "== $v"; grep -E "t=|DONE|FAIL|regions" $v.log | tail -8; done
   python cmpboot.py base.txt new.txt
   ;;
esac
