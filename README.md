# Namco System 10 for MiSTer FPGA (beta core)

Namco System 10 arcade core (core name `SYSTEM10`) for MiSTer, built on the PSX core.

## For users

Copy the contents of `releases/_Arcade` to the root of your MiSTer SD card:

- `releases/_Arcade/cores/Arcade-SYSTEM10_<date>.rbf` -> `/media/fat/_Arcade/cores/`
- `releases/_Arcade/*.mra` -> `/media/fat/_Arcade/`
- MAME ROM zips (not included) -> `/media/fat/games/mame/`

## For developers

- Quartus Prime Lite 17.0, open `NAMCOS10.qpf`.
- Revision `NAMCOS10` (default) is the debug build (debug OSD items, error overlay, GPU trace, JTAG probes).
- Revision `NAMCOS10_release` is the release build (`NS10_DEBUG` not defined).
- `rtl/` core sources, `rtl/ns10/` System 10 specific logic, `sys/` MiSTer framework.
- `sim/` testbenches, `tools/` Python models/trace tools/MRA generator (`mkmra.py`), `docs/` development notes.

## Supported games

Currently only the following games are supported:

- Mr. Driller 2 (`mrdrlr2j`, `mrdrilr2j`, `mrdrilr2u`, `mrdrilr2`)
- Mr. Driller G (`mrdrilrg`)
- Star Trigon (`startrgn`)
- Gamshara (`gamshara`)

Support for additional games is uncertain. Future updates will focus on bug fixes and core improvements.

## Limitations

- Tested only on the QMTECH MiSTer board. It is unknown whether it works on the DE10-Nano.
- This core was not made by analyzing real hardware.
- It may not be cycle accurate.

## Issues found

- ~~Graphics freeze when resetting or running cores under specific conditions~~ (It appears my monitor may be failing to receive the sync signal intermittently when `vsync_adjust=2` is set. I haven't tested this on another monitor (though it works fine on a CRT monitor)
- ~~There is a very brief stutter in the Mr. Driller 2 demo section (likely due to performance issues).~~
- ~~Unable to read score data from NVRAM in Mr. Driller 2~~ (I misunderstood the "today" ranking; the NVRAM operation is fine.)
- ~~The "Star Trigon" game is not working; it functioned correctly during testing, but the issue arose because it was released without proper verification following the final modifications.~~

## Additional notes

- Created with Claude Opus 5.5.
- Based on the MiSTer PSX core and the MAME `namcos10.cpp` driver code.
- I am not a professional developer. I am approaching this AI-generated core very conservatively and carefully, out of consideration for existing professional core developers. If controversy arises over AI-generated cores, I will delete this repository.

## License

This project is a derivative work and is distributed under the GNU GPL v2 (see `LICENSE`).

- Based on the MiSTer PSX core (GPL v2), https://github.com/MiSTer-devel/PSX_MiSTer
- Hardware behavior was referenced from the MAME `namcos10.cpp` driver (MAME project).
- `sys/` is the MiSTer framework; original copyright notices are kept in each file.
- Game ROMs and BIOS are not included and are not distributed.
