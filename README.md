# Namco System 10 for MiSTer FPGA

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

## License

See `LICENSE`.
