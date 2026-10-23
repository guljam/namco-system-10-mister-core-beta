# Mr. Driller 2 / G sync autofire (Drill (Auto)) and the IRQ10 input rate

This is a record of the "sync autofire" (synchro rapid fire) work for Mr. Driller 2 / Mr. Driller G in the Namco System 10 (NS10) MiSTer core.
It covers how the game reads input, why the IRQ10 rate matters, how it was measured and fixed, and how to reproduce it.
The goal is that another developer or AI can reproduce the results from this document alone, or port the feature to another emulator or core.

Korean version: `docs/rapid-fire-irq.md`.
Related commits: `e147f68` (Drill (Auto), 25/s), `f94157c` (IRQ10 2xVBlank as the default).
Work log (Korean): `docs/fixes-2026-10-23.md`.

---

## 1. Summary

- A real-hardware sync autofire unit flips the button on/off at every vsync. If the game reads input every frame, that gives exactly 30 presses/s.
- Driller 2 / G read IN1 in the **IRQ10 interrupt**, and **store only every other sample** (game ROM code).
  So **the rate at which the game takes input = IRQ10 rate / 2**.
- MAME fires IRQ10 at **100 Hz**. This is a placeholder with no source (there is a TODO comment next to it).
  So the game reads input at 50 Hz, and on a 60 fps screen about 10 frames per second get no new input.
  The result is 25 presses/s with "a frame missing now and then".
- If IRQ10 fires at **2x VBlank (twice per frame, 119.88 Hz)**, the game stores input **exactly once per frame**.
  The autofire then flips every frame, giving **29.97 presses/s**. This matched the user's real-hardware experience (Driller G) and real-hardware autofire videos.
- The core default is 2xVBlank (fixed in the release build). Only the debug build has an OSD choice, `IRQ10 (Input)` (2xVBlank / 100Hz).
- **The actual IRQ10 rate on real hardware has not been measured.** 2xVBlank was chosen from ROM evidence, the user's hands-on feel, and video comparison.

---

## 2. NS10 input hardware (what the game sees)

| Address | Contents |
|---|---|
| `0x1FBA0004` | IN1 low 16 bits, active low. P1: bits 0-3 directions, **bit 4 = Button1 (Drill)**, bits 5, 6 buttons, bit 7 Start |
| `0x1FBA0006` | IN1 high 16 bits |
| `0x1FBA001A` | Interrupt status. **Bit 3 = I/O interrupt (IRQ10)** |
| `0x1FBA0012`-`0x1FBA0018` | Interrupt acknowledge. Write address `(a-0x12)/2` = the bit to clear. IRQ10 is `0x1FBA0018` |

- IRQ10 is the PS1 CPU's external interrupt input (I_STAT bit 10; on a PS1 this is the light gun pin). On NS10 the board logic drives it.
- It is **separate** from the GPU VBLANK interrupt (IRQ0, 59.94 Hz). The VBLANK rate does not tell you the IRQ10 rate.
- These games do not use the PS1 controller port (SIO). So the PS1 console's "read the pad every frame" behavior does not apply.
- Note: IN1 is at `0x1FBA0004`, not `0x1FA00004` (a wrong address used early on).

Core implementation: `rtl/ns10/ns10_io.sv` (EXP3 region; `exp3_addr[20:1] == 20'hD0002` is the IN1 low read).

---

## 3. How the game ROM handles input

Checked by dumping RAM in MAME 0.289 and disassembling it with capstone. Both games use the same library.

| | mrdrilr2j (Driller 2) | mrdrilrg (Driller G) |
|---|---|---|
| Interrupt dispatcher (reads `0x1FBA001A`) | `0x8016BB64` | `0x8029654C` |
| Two-phase function (called by the dispatcher) | `0x8016DF0C` | calls the input function near `0x80297DF8` |
| IN1 read function | `0x8016CEB4` | `0x80296C08` |
| IRQ10 call counter (passed as the argument) | `0x802CE100` | (gp-relative) |
| Pad struct | `0x802CE158` (+0x20 P1 current, +0x22 sticky OR) | `0x803C9AD0` |
| Pad variable the game copies every frame | `0x8023F94E` (Drill = `0x0200`) | (not found; `0x803C9AF0` used for measurement) |

Flow (Driller 2 addresses):

1. IRQ10 → the dispatcher `0x8016BB64` sees bit 3 of `0x1FBA001A` and calls `0x8016DF0C(count)`.
   It then writes `0x1FBA0018` to acknowledge and increments count.
2. `0x8016DF0C` alternates between two phases on `count & 1`.
   - **Even calls**: the input function `0x8016CEB4(count)` reads IN1 and **stores it**. It then updates a pad buffer in PS1 pad
     library format (status 0xFF = no pad, etc.) and handles outputs (lamps etc.).
   - **Odd calls**: the input function **reads IN1 and discards it** (`a0&1` → branch to `0x8016D208`). Only the output
     auto-off countdown (64 ticks, `0x802D63EC`) runs.
3. The main loop copies the last stored sample to the game variable (`0x8023F94E`) **once per frame, right after VBLANK (before the GP1(05) write)**.

Confirmation experiments (MAME, single-sample pulse sweep):
- 10 ms single-sample Drill pulses were injected at many phases. All 43 on one parity were ignored; all 42 on the other
  parity were seen, regardless of phase.
- An ISR-level measurement also showed both games storing exactly 50 out of 100 calls.

Other uses of IRQ10 (what a rate change can affect):
- Game speed, time display and sound do not use IRQ10.
- A communication state-machine timeout: counter `0x802D63E4` below 0x79 (121) = wait, otherwise timeout (`0x80174634`).
  That is 1.0 s at 120 Hz and 1.2 s at 100 Hz.
- An output auto-off of 64 ticks (counted down on odd calls only).
- A debug print (`0x8016BE08`).

---

## 4. What changes with the IRQ10 rate

The game always stores input at half the IRQ10 rate.

| IRQ10 | Input stored | Per frame | Real-HW vsync autofire (flip every frame) | Core Drill (Auto) (flip every 2 IN1 reads) |
|---|---|---|---|---|
| 2xVBlank (119.88 Hz) | 59.94 Hz | once every frame | 30/s, exact | **30/s, flips every frame** |
| 100 Hz (MAME) | 50 Hz | ~10 frames/s without new input | ~20/s, irregular (aliasing) | 25/s, a frame repeats now and then |
| 1xVBlank (59.94 Hz) | 29.97 Hz | once every 2 frames | **no autofire** (always the same value stored) | 15/s (2 frames on, 2 frames off) |

- The user has used a vsync autofire unit on a real Driller G and it worked as autofire. So the real rate is not 1xVBlank.
- At 100 Hz that unit would have given an irregular ~20/s (measured in MAME: 19.98/s).
- Normal input is affected too. In simulation, 17 ms taps (just over one frame) were lost 7 times out of 40 at 100 Hz,
  and 0 times at 2xVBlank.

---

## 5. Evidence for the real-hardware IRQ10 rate

Nothing is confirmed. These are the grounds for the choice.

1. **MAME's 100 Hz is a placeholder.**
   - `src/mame/namco/namcos10.cpp`: `TIMER(config, "io_timer").configure_periodic(..., attotime::from_hz(100));`
   - It came in with the 2023 refactor commit `ec6b3d2b5542`, directly under this comment:
     `TODO: Trace main PCB to see where JAMMA I/O goes and/or how int10 can be triggered (SM10MA3?)`
   - No System 10 IRQ10 hardware information was found on the web either.
2. **ROM hints (pointing to 120 Hz, not proof)**
   - The even phase updates a buffer in PS1 pad library format. On a PS1 that buffer is refreshed every frame, so a design
     where IRQ10/2 = one frame is the natural reading.
   - The communication timeout is "more than 120 ticks", which is exactly 1 second at 120 Hz.
3. **User's hands-on feel on real hardware**: 25/s (100 Hz) felt like "a frame is missing now and then". 2xVBlank was "clearly more consistent and smoother".
4. **Comparison with real-hardware autofire videos (YouTube)**: 2xVBlank is much closer (user's judgment).

To confirm, measure the IRQ10 signal (or the interval of bit 3 in `0x1FBA001A`) on a real NS10 board.

---

## 6. Implementation

### 6.1 Drill (Auto) key — `rtl/ns10/ns10_autofire.sv`

Requirements (user decisions):
- Add a key mapping entry **Drill (Auto)**. It is named only in the Driller MRAs. No OSD setting and no default mapping.
- Autofire only while held; stop at once on release. OR'ed with the normal Drill.
- No autofire while the OSD is open.

Algorithm:
- **Count the CPU's IN1 low reads (rising edge) and flip on every 2nd read.** Not time-based and not vsync-based.
  - The game stores only one of every two IRQ10s (which one is decided at boot). Flipping every 2 reads makes every stored
    value the opposite of the previous one, whichever parity is stored.
  - The flip happens in the clock where that read latches its value, so the value read is the one before the flip
    (`ns10_io` latches on the `rd` clock).
- On press: on at once (the first "on" lasts 2 reads, so the first shot is never lost).
- Release, OSD open, or reset: off at once. If the key is still held when the OSD closes, it restarts from "on".
- P1 and P2 are independent.
- Because it follows the game's actual input reads, it gives "flip per stored sample" regardless of IRQ10 rate, CPU Turbo
  or slowdown. That is why this module became 30/s unchanged when IRQ10 was switched to 2xVBlank.

Wiring (`NAMCOS10.sv`):

```systemverilog
// J1 11th button "Button1 (Auto)" = joy bit 14 (added at the end so existing mapping bits are unchanged)
ns10_autofire ns10_autofire
(
	.clk(clk_1x), .reset(cpu_reset),
	.in_rd(exp3_read && exp3_addr[20:1] == 20'hD0002),   // 0x1FBA0004
	.osd(OSD_STATUS),
	.btn({joy2[14], joy[14]}),
	.fire(af_fire)
);
// IN1: P1 bit 4 = joy[4] | af_fire[0], P2 bit 12 = joy2[4] | af_fire[1]
```

MRA: `tools/mkmra.py` appends `Drill (Auto)` to `<buttons>` only in the `mrdrilr*` MRAs.
Other games' MRAs have 10 button names, so the 11th button does not show up for them.

### 6.2 IRQ10 2xVBlank — `rtl/ns10/ns10_io.sv`

```systemverilog
localparam integer TIMER_PERIOD = 338688;            // 33868800 / 100 (MAME 100 Hz)
localparam integer FRAME_NOM    = 565050;            // 33868800 / 59.94 (initial value after reset)
reg        vbl_1;
reg [19:0] fcnt, fper;                               // clocks since VBLANK, last frame length
wire       vbl_rise = vblank & ~vbl_1;
wire       vbl_tick = (fcnt == fper/4) || (fcnt == fper/4 + fper/2);

	vbl_1 <= vblank;
	if (vbl_rise) begin fcnt <= 0; fper <= fcnt; end
	else if (~&fcnt) fcnt <= fcnt + 1'd1;           // saturates (no VBLANK -> no IRQ10)

	if (irq10_vbl ? (vbl_tick && !vbl_rise) : (tcnt == TIMER_PERIOD - 1)) begin
		intr[3] <= 1;                               // 0x1FBA001A bit 3
		irq10   <= 1;                               // PS1 IRQ10 pulse
	end
```

Design reasons:
- **Locked to VBLANK**: a free-running 119.88 Hz timer drifts slightly against the real frame period (interlaced 263/262-line
  fields etc.), so now and then a frame gets 0 or 2 stores. Re-aligning at every VBLANK always gives exactly 2 IRQs per frame.
- **At 1/4 and 3/4 of the frame**: the game copies the pad right after VBLANK. An IRQ at the same moment as VBLANK could
  make the order of copy and store jitter, so positions away from the copy point were chosen.
- **Measures the last frame length (`fper`)**: stays correct if the video mode changes.
- Which point (1/4 or 3/4) becomes the "store phase" depends on the parity of the game's counter at boot. The difference in
  input latency is at most half a frame.

Signal wiring:
- `rtl/psx_top.vhd`: `vblank_irq <= irq_VBLANK;`. The same clk1x signal as the IRQ0 input of irq.vhd.
- `rtl/psx_mister.vhd`: passes the `vblank_irq` port through.
- `NAMCOS10.sv`: `.irq10_vbl(!DEBUG || !status[87]), .vblank(vblank_irq)`.
  - Release revision: always 2xVBlank, no OSD item.
  - Debug revision: `"O[87],IRQ10 (Input),2xVBlank,100Hz;"` inside `` `ifdef NS10_DEBUG `` (the first entry is the default).

### 6.3 Checklist for porting to another emulator or core

1. Make the IRQ10 (I/O interrupt) source fire twice per frame, anchored to VBLANK (MAME example: the §7.2 patch).
   Set interrupt status bit 3 and pulse IRQ10 together.
2. Make the autofire based on **the number of IN1 reads by the game** (flip every 2nd read), not on time.
   At 2xVBlank a vsync flip also gives 30/s, but the read-based version is optimal at any IRQ10 rate.
3. Verify with the game variable: at each GP1(05) write, check that bit `0x0200` of `0x8023F94E` (Driller 2) changes every frame.

---

## 7. Experiments and how to reproduce

### 7.1 MAME Lua measurement tool — `tools/mame/tap_input.lua`

Taps IN1 reads to inject input or an autofire model. At every GP1(05) write it reads the game's pad variable and prints
"presses seen by the game" and "frames that repeated the last value".

| Environment variable | Meaning |
|---|---|
| `NS10_INLOG` | log path |
| `NS10_T1` | exit time (s) |
| `NS10_INJ` | `"t0,t1,hexmask;..."` press these IN1 bits (active low) in the window |
| `NS10_AF` | `"t0,t1"` hold P1 Drill (Auto) in the window |
| `NS10_AFMODE` | `read`: flip every 2 IN1 reads (same as the core), `vbl`: flip on every GP1(05) (vsync autofire unit) |
| `NS10_PAD` | game variable to read every frame (hex). Driller 2 `8023F94E`, Driller G `803C9AF0` |
| `NS10_SNAP` | `"t,t,..."` snapshot times. Repeat a time to capture consecutive frames |

Example, Driller 2 during play (coin 25 s, start 27 s, menu/stage select 29-37 s, autofire 58-75 s):

```sh
NS10_INLOG=af.log NS10_T1=75 NS10_AF="58,75" NS10_AFMODE=read NS10_PAD=8023F94E \
NS10_INJ="25,25.3,20000000;27,27.3,80;29,29.3,10;31,31.3,10;33,33.3,10;35,35.3,10;37,37.3,10" \
./namcos10.exe mrdrilr2j -rompath "<roms>" -inipath <ini dir (ui.ini: skip_warnings 1)> \
  -nvram_directory <empty dir> -nothrottle -video none -sound none -skip_gameinfo \
  -autoboot_script tools/mame/tap_input.lua
# Output: mode read: N presses seen by the game in F frames (r/s), K frames repeated the last value
```

Entering test mode SWITCH TEST: `NS10_INJ="8,40,40000000;30,30.2,4;32,32.2,10"`
(TEST switch bit 30, down bit 2, Drill bit 4. The test menu appears about 30 s after a first boot on Driller 2, about 15 s on G.)

MAME Lua notes:
- psxcpu RAM taps do not fire. Read RAM values with `read_u16` inside I/O tap callbacks.
- Keep state in globals (locals of the autoboot chunk are garbage collected and the taps vanish).
- Pass a ui.ini with `skip_warnings 1` through `-inipath` so the run does not stop at the warning screen.

### 7.2 Reproducing 2xVBlank in MAME — `tools/mame/irq10_vbl2.py`

Patches `namcos10.cpp` in a **copy** of the MAME source.
- With environment variable `NS10_IRQ10=vbl2`, the screen VBLANK callback measures the last frame length and timers fire
  IRQ10 at 1/4 and 3/4 of it (`m_int |= 8; m_io_update_interrupt(1);`). The original 100 Hz timer callback is ignored.
- Without the variable it behaves like stock MAME.

```sh
python tools/mame/irq10_vbl2.py <mame copy>/src/mame/namco/namcos10.cpp
# needs MSYS2 UCRT64 and OS=Windows_NT
OS=Windows_NT MSYSTEM=UCRT64 bash -lc 'export OS=Windows_NT MINGW64=/ucrt64; cd <mame copy> && make SUBTARGET=namcos10 SOURCES=src/mame/namco/namcos10.cpp -j16'
NS10_IRQ10=vbl2 ./namcos10.exe mrdrilr2j ...
```

The copy built for this work is kept at `D:\scratch_mame_irq` (at the user's request, as reference material). The user's own MAME folder was not modified.

### 7.3 ModelSim simulation

| Script | Contents |
|---|---|
| `sim/ns10/run_autofire.sh [seed]` (`tb_autofire.sv`) | Autofire module alone. Reads every 10 ms ±0.3 ms, every other one stored, consumed by 59.94 Hz frames. Checks: 25/s, alternation, first shot, off at once on release / OSD / reset, P1/P2 independent, 300 random taps |
| `sim/ns10/run_irq10.sh [seed]` (`tb_irq10.sv`) | Real `ns10_io` + `ns10_autofire` at 33.8688 MHz. VBLANK with alternating 263/262-line fields. Game model: read 2-52 µs after IRQ10, every other one stored, ack write, pad copy 0.1-3 ms after VBLANK. Checks: 2xVBlank IRQ positions (1/4, 3/4 ±300 ns), rate per second, 30/s, 0 repeated frames, 0 lost 17 ms taps, 100 Hz period, mode switching |

Both have a sim-time limit, a no-input / no-IRQ watchdog and a 15-minute wall-clock limit (`timeout 900`). `run_irq10.sh` takes about 10 minutes.

---

## 8. Results

### 8.1 Simulation (`run_irq10.sh` seed 1, PASS)

| Item | 2xVBlank | 100 Hz |
|---|---|---|
| IRQ10 | 119/s, at 1/4 and 3/4 of the frame | 99/s, 10 ms period |
| Drill (Auto) | 29.97/s, 0 repeated frames | 25.11/s, 30 repeated frames in 3 s |
| 17 ms taps lost | 0/40 | 7/40 |

### 8.2 MAME, actual game code

| Game / measured variable | 100 Hz | 2xVBlank |
|---|---|---|
| mrdrilr2j / `0x8023F94E` (during play) | 25.01/s, 163 repeats in 978 frames | 29.91/s, 1 repeat |
| mrdrilrg / `0x803C9AF0` (menu to start) | 24.97/s, 156 repeats in 929 frames | 29.91/s, 1 repeat |
| (reference) vsync autofire model `AFMODE=vbl`, mrdrilr2j, 100 Hz | 19.98/s, irregular | — |
| (reference) flip on every IN1 read, 100 Hz | 0 (the stored value never changes) | — |

- The single repeated frame at 2xVBlank is a scene change where the game did not write GP1(05) for 200 ms. It is unrelated to the autofire.
- Menus, stage / character select, play and test mode screens were identical in both modes.
  JVS CABINET OPTIONS was greyed out in both, so the communication timeout path does not differ.
- In the same time, the 2xVBlank run drilled deeper (26 m → 33 m).

### 8.3 Other games (checked before changing the default)

- Gamshara and Star Trigon also read IN1 on every IRQ10 (100/s → about 120/s).
- Over 70 seconds the screens were identical in both modes: Gamshara title / ranking / demo / play, Star Trigon title / profile / player and mode select.

### 8.4 Real hardware (user, MiSTer)

- 100 Hz (25/s): feels similar to a real-hardware autofire unit, but drills fast and then slows slightly when a frame goes missing now and then.
- 2xVBlank (30/s): clearly more consistent and smoother. Much closer to real-hardware autofire videos.
- In-game behavior is the same on Driller 2 and G.

---

## 9. An easy comparison on hardware: SWITCH TEST

Turn on the DIP Test switch and enter SWITCH TEST. Holding Drill (Auto) changes `1P:0000` / `1P:0200` at the top.

| | 100 Hz | 2xVBlank |
|---|---|---|
| Driller 2 (MiSTer, real screen) | flickers fast | **looks constantly held** |
| Driller G (MiSTer, real screen) | flickers fast | flickers fast |
| Both games (MAME, consecutive frames) | irregular (the same value lasts 2 frames in places) | **alternates exactly every frame** |

Interpretation (Driller 2):
- The test screen is 640x480 interlaced and single-buffered (GP1(05) = `05000000`).
- In interlaced drawing the PS1 GPU **skips the lines of the field being displayed**. With an exact flip every frame,
  one field always gets 0200 and the other always gets 0000. The two fields combine into a steady picture ("constantly held").
- At 100 Hz the flip phase slides against the frames, so the flicker shows.
- So "looks constantly held" is actually the sign of an exact flip every frame. An exact 30 Hz autofire on real hardware should look the same.
- MAME's GPU draws every line, so it does not show this effect.
- Why Driller G flickers in both settings was not checked (probably a difference in how its test screen is drawn).
  In MAME, G also alternates exactly every frame at 2xVBlank.

---

## 10. Known limitations and open questions

- **The real-hardware IRQ10 rate is unconfirmed.** Update this document and `ns10_io.sv` when a hardware measurement is available.
- **Slowdown frames**: when the game misses a frame, two inputs are stored in between, and one autofire shot can be lost at that moment.
  Real hardware should behave the same by design.
- **Input latency phase**: whether 1/4 or 3/4 is the store phase is decided at boot. The difference is at most half a frame.
- **Pause / VBLANK stopped**: when VBLANK stops, `fcnt` saturates and IRQ10 stops too. In 100 Hz mode it keeps firing.
- **Saved debug OSD value**: the entry order was swapped, so a value saved as 2xVBlank in an older debug build reads as 100Hz in later debug builds.
- **Do not combine with MiSTer's built-in autofire**: enabling both on the same button makes them interfere.
- **Existing key mappings**: users with a saved SYSTEM10 mapping need to map Drill (Auto) once.
- **MAME autofire plugin**: it was not accurate on this game (per the user). Real hardware is the reference for autofire feel.

---

## 11. Current status (2026-10-23)

- Committed on `main`: `e147f68` (Drill (Auto)), `f94157c` (2xVBlank default, sim / MAME tools, docs).
- Real-hardware A/B check done by the user with the debug build `Arcade-SYSTEM10_20261023.rbf`.
- The release build is not final yet.
  - The SEED 4 build had an HDMI scaler (ascal) setup slack of -0.048 ns.
  - Work was stopped after the user reported an OSD menu display problem in the release build (submenus shown expanded).

---

## 12. Files

| File | Role |
|---|---|
| `rtl/ns10/ns10_autofire.sv` | Drill (Auto): flip every 2 IN1 reads |
| `rtl/ns10/ns10_io.sv` | IN1 / interrupt registers, IRQ10 generation (100 Hz / 2xVBlank) |
| `rtl/psx_top.vhd`, `rtl/psx_mister.vhd` | Bring the GPU VBLANK interrupt (`vblank_irq`) out |
| `NAMCOS10.sv` | J1 11th button, autofire OR, IRQ10 mode select (debug OSD `O[87]`) |
| `tools/mkmra.py`, `releases/_Arcade/*.mra` | `Drill (Auto)` button name only in the Driller MRAs |
| `sim/ns10/tb_autofire.sv`, `run_autofire.sh` | Autofire module simulation |
| `sim/ns10/tb_irq10.sv`, `run_irq10.sh` | IRQ10 + autofire integrated simulation |
| `tools/mame/tap_input.lua` | MAME input injection / measuring the autofire the game sees |
| `tools/mame/irq10_vbl2.py` | 2xVBlank IRQ10 patch for a MAME copy |
| `docs/rapid-fire-irq.md` | Korean version of this document |
| `docs/fixes-2026-10-23.md` | Work log in Korean (requirements, decisions, build records) |
