#!/bin/sh
# Sim-only copies of RTL files in gen/ (run.sh, ghdl.sh). The RTL itself is not changed.
R=../../rtl
rm -rf gen; mkdir gen
# RTL debug file output (R: ramdisk) off
sed 's/: if 1 = 1 generate/: if 1 = 0 generate/' $R/gpu_vram2cpu.vhd > gen/gpu_vram2cpu.vhd
# gpu.vhd: debug output off, + dbg_perf port for the testbench counters
# (request size, pixel write, poly / rect / pipeline VRAM request, pipeline stall)
sed -e 's/: if 1 = 1 generate/: if 1 = 0 generate/' \
    -e '/^      dbg_gpu              : out/a\      dbg_perf             : out std_logic_vector(36 downto 0);' \
    -e "/^   dbg_gpu <= ce/a\\   dbg_perf <= std_logic_vector(pipeline_reqVRAMYPos) \& std_logic_vector(pipeline_reqVRAMXPos) \& std_logic_vector(pipeline_reqVRAMSize) \& pixelWrite \& poly_reqVRAMEnable \& rect_reqVRAMEnable \& pipeline_reqVRAMEnable \& pipeline_stall \& '0';" \
    $R/gpu.vhd > gen/gpu.vhd
# display line math goes negative outside the display range; hardware wraps, GHDL bound checks are fatal
sed -e 's/to_unsigned(/to_unsigned_w(/g' \
    -e '/^architecture arch of gpu_videoout_async is/a\   function to_unsigned_w(v : integer; n : natural) return unsigned is begin return to_unsigned(v mod 2**n, n); end function;' \
    $R/gpu_videoout_async.vhd > gen/gpu_videoout_async.vhd
# negative x start compared as natural against the unsigned drawing area (fatal bound check in GHDL)
sed 's/if (to_integer(xStart(43 downto 32)) > drawingAreaRight) then/if (to_integer(xStart(43 downto 32)) > to_integer(drawingAreaRight)) then/' \
    $R/gpu_poly.vhd > gen/gpu_poly.vhd
# GHDL rejects to_integer() actuals on the ranged y ports of the overlay / crosshair (display only)
sed -E 's/((i_pixel_out_y|ypos_cross|ypos_screen|ypos_gun) *=> *)to_integer\([^)]*\)/\10/' $R/gpu_videoout.vhd > gen/gpu_videoout.vhd
# files in compile order
GPU_FILES="$R/dpram.vhd $R/divider.vhd $R/pGPU.vhd $R/mul32u.vhd $R/mul9s.vhd \
   $R/gpu_fillVram.vhd $R/gpu_cpu2vram.vhd $R/gpu_vram2vram.vhd gen/gpu_vram2cpu.vhd $R/gpu_line.vhd $R/gpu_rect.vhd \
   gen/gpu_poly.vhd $PP $R/gpu_overlay.vhd $R/gpu_dither.vhd gen/gpu_videoout_async.vhd $R/gpu_videoout_sync.vhd \
   $R/gpu_crosshair.vhd $R/justifier_sensor.vhd gen/gpu_videoout.vhd gen/gpu.vhd tb_gpu.vhd"
