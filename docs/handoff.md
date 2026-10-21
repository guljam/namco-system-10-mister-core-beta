# Handoff (2026-10-19)

## Status
- **No play-affecting graphics or sound problem known in the ported sets** (user play tests up to 2026-10-19): Mr. Driller G, Mr. Driller 2 (mrdrilr2j), Gamshara, Star Trigon. The earlier "blue lines / frozen graphics after a MiSTer soft reboot" did not come back with the faster GPU (eda46d1) over several soft resets and core switches - most likely a side effect of the GPU overrun. Watch for it in further play.
  - Mr. Driller G: user (played the real NS10) rates it "almost identical to the real board".
  - mrdrilr2 / mrdrilr2u (World / US) not tested yet.
- **NVRAM** (settings / rankings): `rtl/ns10/ns10_nvram.sv`, MRA `<nvram index="2">` -> `.nvm` file; saved when the OSD is opened.
- **Core name SYSTEM10**: rbf `Arcade-SYSTEM10_<date>.rbf` in `_Arcade/cores`, MRA `<rbf>SYSTEM10</rbf>` (same scheme as the SYSTEM12 core), OSD / config name `SYSTEM10`. The Quartus project and top file stay `NAMCOS10`.
- **Two Quartus revisions** (one source, Verilog macro `NS10_DEBUG`):
  - `NAMCOS10` (default, debug): OSD CPU Turbo / Turbo Cache / Interlace Drawing / Trace GPU 10 s / Interlace Field Lock, PSX error overlay (EA, ED ... top left), GPU trace (`ns10_gtrace`), JTAG probes (`ns10_probe`: SPUT, GTRC). Bug fixing / HW tests always use this one.
  - `NAMCOS10_release`: no `NS10_DEBUG` -> those OSD items removed and fixed at their defaults (Turbo High, Cache Full, Interlace Drawing PSX, Field Lock On), no error overlay, no trace, no probes (`ns10_probe` compiles to nothing). "Pause when OSD is open" stays. Built only when the user asks for a release build.
- Releases: see "Releases" below.
- `NAMCOS10.qsf` / `NAMCOS10_release.qsf` are expanded by Quartus on every compile (device / pin assignments) - commit only intended edits, not the expansion.

## Fixes (HW bring-up, 2026-10-18), in commit order
| Commit | Problem seen on HW | Cause / fix |
|---|---|---|
| fd08fe5 | Blue screen + 4 grey squares, SIO1 `spec77 ... CODE=903` | NS10 BIOS runs from **kseg0** (0x9FC2xxxx). PSX core i-cache data RAM is filled only by SDRAM `ch1_cache` bursts; a single BIOS fetch marked the tag valid -> stale instructions. `memorymux.vhd`: BIOS fetch keeps `mem_oldtagvalids`. Same bug as System573_MiSTer psx_patches/0005. |
| dfa2da4 | mrdrilrg: BIOS `yshi_nand_table_check ... the table for device 0 is wrong` | MAME "share3": **board RAM 0x1F500000-0x1F5FFFFF** (16 KB SRAM, NAND block table) for non-MEM(M) boards. `ns10_romboard.sv` S_SRAM_RD + byte enables; new `exp1_be` port memorymux -> psx_top -> psx_mister -> top. |
| a708bdf | Graphics badly broken (mrdrilrg) | NS10 GPU has **2 MB VRAM (1024 rows)**, PSX core wraps Y at 512. Applied System573_MiSTer psx_patches **0012-0021** (CLUT cache fixes + 0021 10-bit Y, rows 512-1023 at DDR3 0x30800000) to gpu*.vhd. User confirmed fixed. |
| 5d5de28 | Sound slow / low pitch | GroovyMAME namcos10: SPU (CXD2938Q) clock 101.4912 MHz / 2, 768 clocks per sample = **66.15 kHz**. `spu.vhd`: sample period 768 -> **512 clk1x** (`sampleticks < 511`, savestate idle check `< 504`). |
| 5d5de28 | Then: periodic stutter, pitch dips < 1 s | At 512 clk/sample the SPU overran. mrdrilrg reverb work area starts at **0x67FC0** -> outside the 64 KB on-chip reverb BRAM -> uncached DDR3. `spu_ram.vhd`: reverb BRAM **128 KB (0x60000-0x7FFFF)**. Stutter gone (user confirmed). |
| 29105e9 | Stage 13 ("13열 상급") slowdown, interlace half-frame ghosting | NS10 CPU = 101.4912/2 = **50.7456 MHz (1.5x PSX)**; core stays at 33.8688 MHz. OSD **CPU Turbo** = PSX core turbo modes (status[82:81], 0 = High = default). High removes the slowdown. |
| 29105e9 | (found while enabling turbo) | `cpu.vhd`: data cache took *all* writes incl. I/O / EXP (watchdog 0x1FB60000, board RAM 0x1F500000) and aliased them onto RAM lines. Now only writes < 0x800000. |
| 8450096 | mrdrilrg attract: 1-2 broken frames at scene cuts with Turbo High | See "Open issues". OSD **Turbo Cache (High) Full/Half** (status[83]), default Full. |
| 8450096 | 480p hack: missing sprites, background through, scanline-only gfx | PSX 480p hack uses 512-line buffers + draw heuristics, incompatible with 2 MB VRAM / this game -> option removed (`interlaced480pHack(0)`). Use OSD Deinterlacing **Bob**. |
| 86f4540 | - | Gamshara config (tools/ns10model.py GAMSHARA, ns10cfg.py, mkmra.py). |
| (2026-10-19) | mrdrilrg scene-cut glitch with Cache Full (Open issue 1) | PSY-Q libetc `VSync()` -> `v_wait(Vcount+1, 1)` has an iteration timeout `sll a1,a1,15` (32768 loops). MAME uses ~29000 per field; Cache Full is ~13 % faster -> times out before vblank, after a loading frame mid-field -> flip + draw list straddles vblank. `cpu.vhd`: while TURBO_CACHE=1 the instruction word 0x00052BC0 is fetched as 0x00052C00 (shift 16) on i-cache fill and uncached fetch (word occurs once, in v_wait, in mrdrilrg / mrdrilr2 / gamshara / startrgn). HW trace at the cut: pre-vblank timeouts 160 -> 0, mid-field flips 1 -> 0. Cache Auto mode removed. User confirmed: both attract glitch scenes fixed, no stage 13 slowdown. |
| (2026-10-19) | - | NVRAM save, Star Trigon config / MRA (ns10model.py STARTRGN, ns10cfg.py, mkmra.py), GPU trace (OSD "Trace GPU 10 s"). |

## CPU Turbo levels (NAMCOS10.sv, `turbo = ~status[82:81]`)
| OSD | TURBO_MEM | TURBO_CACHE | TURBO_CACHE50 | TURBO_COMP | mrdrilrg result |
|---|---|---|---|---|---|
| High + Cache Full (default) | 1 | 1 | 0 | 1 | stage 13 smooth (scene-cut glitch fixed by the VSync patch) |
| High + Cache Half | 1 | 1 | 1 | 1 | no glitch, very slight stage 13 stutter |
| Medium | 1 | 1 | 1 | 0 | no glitch, slight stutter |
| Low | 1 | 0 | 0 | 0 | no glitch, slight stutter |
| Off | 0 | 0 | 0 | 0 | stage 13 slowdown |
- Turbo is **not cycle exact** (removes waits / shortens ops at 33.8688 MHz instead of a 1.5x clock). User decision: prioritise MAME's code and accept this limit. MAME itself clocks the root counters at 33.8688 MHz (rcnt.cpp TODO for 50 MHz boards).
- A 50 MHz CPU clock is not realistic (PSX core slack ~0.1-0.3 ns at 33.8688 MHz).

## GPU fixes (2026-10-19)
| Commit | Problem seen on HW | Cause / fix |
|---|---|---|
| 03258f0 | Star Trigon / Gamshara 480i graphics break (half-field stripes, blinking) | NS10 GPU runs at 1.5x the PSX GPU (MAME 50.7456 MHz vs 33.8688); the core GPU overran the field and the interlace draw parity flipped mid-frame. OSD **Interlace Field Lock** (status[86], default On): `gpu.vhd` latches `activeLineLSB` for the drawers only while the GPU is idle. |
| cba4156 | Remaining breakage | Texture cache miss fills the rest of the cache row in one DDR3 burst. |
| eda46d1 | Gamshara title still broken (draw 17.9 ms / field 16.7) | A texture miss also reads the next 3 texture rows (step 2 when interlaced, up/down from the previous miss row) back to back in one DDR3 latency. GHDL sim: title 17.73 -> 14.11 ms, select 12.90 -> 11.37 ms, pixel-identical. User: all graphics fixed. |

## Open issues
1. **FIXED 2026-10-19 (VSync timeout, see Fixes)** - kept for history. **Attract scene-cut glitch with Cache Full** (mrdrilrg): 45-47 s after the BIOS colour-bar screen (coffee/TV -> news anchor) and 1:06-1:08 (transformation scene); repeats every attract loop.
   - Present with Turbo COMP on and off; absent with Medium / Low / Off / Cache Half -> trigger is the full-rate data cache (CPU speed), not COMP.
   - Not weave deinterlacing (still there with Bob).
   - MAME (frames captured 25-60 s, `scratchpad/mame_snap`) shows clean single-frame cuts. The game never swaps display buffers: GP1 05 = 0 every frame (single buffer, 480i, GPU draws only the non-displayed field).
   - Code review found no stale-data path in the dcache (CPU write is visible next cycle, loads stall following loads/stores, all DMA RAM writes update the cache). Likely a CPU-vs-GPU speed balance effect (core GPU VRAM in DDR3). Root-causing would need a frame-level CPU/DMA/GPU command trace vs MAME at the cut.
2. **EA FIXED 2026-10-19 (spu.vhd: no RAM data transfer while samples are stashed)**: Gamshara's sample upload 24-26 s after load pushed every sample to ~536 clk (budget 512, idle load ~492-500) -> stash 15 -> dropped samples -> EA. Now max stash 1 during the upload (probe), upload throttled by the DMA FIFO-empty request. Short 1-sample overruns remain (inaudible). **SPU overruns still counted** (inaudible): probe "SPUT" shows ~100-300 overruns/s, max ~850-900 clk per sample (budget 512), max stash 1. Dominated by **voice cache misses (up to ~460 clk/sample)**: each miss waits until the GPU reaches a pause point in the psx_top DDR3 arbiter (`WAITGPUPAUSED`). Boot (sample upload) still reaches stash 15 -> PSX error overlay shows **EA** after 2+ resets (sound plays normally).
   - **Tried and failed: SPU RAM in main SDRAM** (SPUSDRAM=1 on sdram ch3 at 0x1000000): uncached 16-bit accesses at lowest SDRAM priority behind the CPU -> max 2600 clk/sample, stash 15 constantly. Also SDRAM mode forces 24 clk per voice slot (`spu.vhd` `voiceCounter >= 23`) = 576 > 512 -> SPU never idle -> savestate module reset loop on boot (black screen, error **EF**). Reverted.
   - Ideas not tried: prefetch the next voice line, give the SPU priority / a shorter GPU pause in the DDR3 arbiter, batch several misses per GPU pause.
   - (The "Boot still reaches stash 15 -> EA" note above is from before the 2026-10-19 fix.)
   - **REGRESSION FIXED 2026-10-21 (Star Trigon hung black after the boot screen, EA)**: during Star Trigon's boot the SPU is behind even without transfers (HW probe: 540-577 clk/sample, stash stuck at 15). The 7577f5b rule (transfer only at stash 0) then never transferred again -> the boot sample upload never finished. Now: full rate at stash 0 or 15 (at 15 samples are dropped anyway = old behaviour), otherwise one transfer word per sample (last voice slot) so the upload always progresses. GHDL `sim/spu` (DDR3 latency sweep, upload data check) reproduced the hang (and showed that "stash 0 or 15" alone still hangs when the stash hovers at 1-14). HW: Star Trigon boots to attract (135 dropped samples during the boot upload -> EA latched, inaudible, 0 afterwards); Gamshara upload max stash 1 / 0 drops (EA fix kept); Driller G / Driller 2 OK.
3. PSX error overlay codes seen: **ED** (errorCPU2, a CPU stall >= 512 cycles - normal with the NS10 ROM bus waits, harmless), **EA** (SPU timeout, see 2), **EF** (only with the failed SDRAM build).
4. **FIXED 2026-10-19 (03258f0, cba4156, eda46d1, see Fixes)** - kept for history. **Star Trigon / Gamshara graphics** (user report 2026-10-19): Star Trigon attract parts blink every ~0.2 s, stage select shows one field with black lines; Gamshara character select has missing/broken parts. Same with CPU Turbo Off.
   - Both are single-buffered 480i (GP1 05 always 0, draw area 0,0-639,479) and rely on the GPU skipping the displayed field's lines.
   - HW GPU trace: one frame takes median 14.9 ms / max 19.3 ms of GPU time (field 16.7 ms); GPU busy at vblank in 266/600 fields (Turbo Off), 96/600 (High), mrdrilrg 1/599. When the field changes mid-draw the rest lands in the other field's lines. MAME's GPU is instant.
   - Gamshara character select (user trace): GPU busy at vblank 462/599, frame starts 1.46 ms after vblank, draw median 15.3 ms -> overruns the field by ~0.1 ms median; GPU time mostly op 65 sprites (~393/frame, 15 us each), op 66, op 2E. A ~10 % faster GPU may be enough.
   - Ruled out: 2 MB VRAM paths (10-bit Y, texpage bit 11, cache tags), the 573 GPU patch options (all off), the VSync timeout.
   - Debug OSD **Interlace Drawing PSX/MAME** (status[84], gpu.vhd `drawAllLines`): MAME = draw both fields; on HW it only turns the stripes into tearing - not a fix. Keep PSX.
   - Open: is the real CXD8561CQ faster, or is the core GPU slowed by DDR3 sharing with the NS10 ROM / SPU? Next: GPU per-primitive time and DDR3 waits in a Star Trigon frame.

## Debug instrumentation (debug revision only unless noted)
- `NAMCOS10.sv`: `localparam DEBUG` from `NS10_DEBUG`; `errorOn(DEBUG)`, debug OSD items in an `ifdef NS10_DEBUG` block of CONF_STR, `ns10_gtrace` instance.
- `rtl/ns10/ns10_gtrace.sv`: 10 s GPU/DMA/IRQ/VBL trace into DDR3, OSD "Trace GPU 10 s" or JTAG; `tools/gputrace.py` (start / fetch / dump / fields), MAME counterpart `tools/mame/tap_gpu.lua` (NS10_GPULOG, NS10_T0/T1, NS10_FULL=1 with all GP0 words). MiSTer watcher `/media/fat/ns10_gtwatch.py` saves finished traces to `/media/fat/ns10_traces` (compares the first 256 bytes; restart it after a MiSTer reboot).
- `rtl/ns10/ns10_probe.sv` (64-bit In-System Sources and Probes wrapper; empty without NS10_DEBUG) and the "SPUT" probe in `rtl/spu.vhd`; `tools/ns10trace.py spu [clear]` (overruns, max clk/sample, RAM wait per sample voice/write/other, max stash).
- Probe "SPU2" in `rtl/spu.vhd`: `tools/ns10trace.py spu2 [clear]` (transfer words and dropped samples since clear, current stash, FIFO empty flags, transfer mode) - shows whether an SPU upload is progressing.
- SPU testbench `sim/spu` (GHDL `ghdl.sh compile <name> [spu.vhd]` / `ghdl.sh sim <name> <LAT> [SAMPLES]`; needs the libraries from `sim/gpu/ghdl.sh compile`): 24 voices playing, DDR3 model with fixed latency, DMA upload with data check.
- Old trace taps `dbg_io_*` / `dbg_cpu_*` / `dbg_gpu` / `dbg_bus` ports in memorymux.vhd / psx_top.vhd / psx_mister.vhd (unloaded in the release revision -> removed by synthesis).
- GPU testbench `sim/gpu` (GHDL `ghdl.sh` / ModelSim `run.sh`, inputs from MAME logs + VRAM dumps via `gpusim.py`); DDR3 latency 8 matches the HW trace.
- `tools/gpumodel.py`: DuckStation GPU timing model (PSX and NS10 1.5x) over MAME NS10_FULL logs.

## How to work with the HW
- Debug build: `C:\intelFPGA_lite\17.0\quartus\bin64\quartus_sh --flow compile NAMCOS10 -c NAMCOS10` (~20 min) -> `output_files/NAMCOS10.rbf`. Only edit sources after "Analysis & Synthesis" has elaborated, never run a second quartus process on the project.
- Release build (only on request): `quartus_sh --flow compile NAMCOS10 -c NAMCOS10_release` -> `output_files/NAMCOS10_release.rbf`, copy to `releases/_Arcade/cores/Arcade-SYSTEM10_<date>.rbf` (not uploaded to the MiSTer).
- Deploy (debug build): `python tools/deploy.py "Mr. Driller G (Japan, DRG1 Ver.A).mra"` (FTP `Arcade-SYSTEM10_<date>.rbf` + all MRAs from `releases/_Arcade`, removes old `NAMCOS10_*` / `Arcade-SYSTEM10_*` rbfs, then `load_core` over SSH/plink). ROM download + boot ~60-90 s.
- Screenshot: `echo screenshot > /dev/MiSTer_cmd` -> `/media/fat/screenshots/<setname>/`.
- MRAs: `python tools/mkmra.py` (config blob from `tools/ns10cfg.py`). ROM zips on the MiSTer: `/media/fat/games/mame` (incl. gamshara.zip).
- MAME reference: `D:\github_clones\mame\namcos10.exe <set> -rompath "D:/0ROMS/MAME 0.288 ROMs (merged)"`; useful Lua: per-frame `manager.machine.video:snapshot()`, write taps on 0x1F801814 (GP1) / 0x1F801050 (SIO1); `-debug -debugger none` + `debugger:command('dasm ...')` for disassembly.
- Timing of the mrdrilrg attract loop in MAME is ~7 s earlier than counted from the BIOS screen on HW (news cut MAME 38.9 s vs HW 45-47 s).
- Several files are CRLF (spu.vhd, NAMCOS10.sv, ns10_romboard.sv, ns10model.py, ns10cfg.py ...): edit with tools that keep line endings; `sed -i` converts to LF.

## Next steps
1. User keeps play testing (debug build for fixes); test mrdrilr2 / mrdrilr2u.
2. Follow-up candidates (accuracy closer to MAME / the real NS10; none needed for current play):
   - **CPU timing**: Turbo is not cycle exact (PSX core at 33.8688 MHz with waits removed vs NS10 50.7456 MHz). Calibrate against MAME per frame (e.g. `v_wait` iterations per field: MAME ~29000, compare HW), then replace the v_wait instruction patch (`cpu.vhd`, 0x00052BC0 -> shift 16) with a turbo setting that matches MAME's instructions per field.
   - **GPU timing**: the core GPU is now faster than the PSX GPU on textured sprites (multi-row texture fetch) but still PSX speed for semi-transparent polys (one DDR3 background read per line, op 2E ~30 per poly), CLUT loads (wait for pipeline drain) and fills. Overlapping those brings frame times closer to the 1.5x NS10 model (`tools/gpumodel.py`); with enough margin Field Lock becomes a no-op (measure GPU busy at vblank with the trace).
   - **SPU**: on clk2x since branch spu-fix (2026-10-21): 1024 clk2x per sample, idle load 640-755, HW 4 games x 2 min 0 drops, max stash 1 (rare 1-sample overruns from 13-16 us voice cache miss waits under GPU load). Before: 512 clk1x per sample. Voice block prefetch or SPU priority in the psx_top DDR3 arbiter would remove the remaining overruns.
   - **NS10 ROM bus waits**: ED (CPU stall >= 512 cycles) comes from EXP1 ROM reads waiting on DDR3 behind the GPU. Compare the EXP1 wait timing with MAME's namcos10 ROM access (`tools/ns10trace.py cmp`) and give ROM reads priority if they are slower than MAME.
   - **Root counters / vblank timing**: MAME clocks the root counters at 33.8688 MHz (rcnt TODO for 50 MHz boards) - the core matches MAME; revisit only if MAME changes.

## Releases
- 2026-10-19: `releases/_Arcade/cores/Arcade-SYSTEM10_20261019.rbf` (revision NAMCOS10_release).
- 2026-10-21: `releases/_Arcade/cores/Arcade-SYSTEM10_20261021.rbf` (revision NAMCOS10_release, Star Trigon boot hotfix). SEED 1 gave a core hold violation (-0.013 ns, SPU voice record MLAB write address) -> `NAMCOS10_release.qsf` SEED 2: core clocks clean, HDMI `ascal` setup -0.128 ns (slow 85C only). HW: Star Trigon / Gamshara / Driller G / Driller 2 boot and display OK.
- Debug revision build of b5efdaa (not deployed): compiles, but placement-dependent violations: HDMI `ascal` setup -0.254 ns and hold -0.251 ns from the HPS f2sdram FFs into GPU line RAM / texture cache RAM inputs (the release revision of the same source passes). On the next debug build check timing first; if it repeats, change `SEED` in NAMCOS10.qsf.

## Notes
- MAME helpers: `tools/mame/tap_exp1.lua` (EXP traces, NS10_NORLE=1 for full).
- `NUM_PARALLEL_PROCESSORS ALL` already set (Quartus 17 uses 16 of 20 cores).
- Never push; commit locally per step.
