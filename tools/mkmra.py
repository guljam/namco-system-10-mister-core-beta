"""Write the NS10 MRA files (releases/_Arcade). ROM index 0 is the DDR3 ROM image in
ns10cfg.rom_image order, index 1 the config blob (inline hex), nvram index 2 the
settings region (rtl/ns10/ns10_nvram.sv). Order: config, nvram, ROM - the core
needs the board type for the nvram and the nvram before the BIOS boot copy.
The ROM uses the DDR3 fast load (address attribute: Main_MiSTer copies the image
into DDR3 itself); an older Main_MiSTer ignores it and streams the ROM instead."""
import os

import ns10cfg

OUT = os.path.join(os.path.dirname(__file__), "..", "releases", "_Arcade")

# name, setname, year, zip list, [(part, crc)], cfg game
MRAS = [
    ("Mr. Driller G (Japan, DRG1 Ver.A)", "mrdrilrg", 2001, "mrdrilrg.zip",
     [("0.8e", "4b61ac62"), ("1.8d", "c87b5e86"), ("2.7e", "e0a9339f")], "mrdrilrg"),
    # MEM(N), 2 NANDs, type 2 decrypter (S-box IV); not tested on HW yet
    ("Gamshara (20020912A, 10021 Ver.A)", "gamshara", 2002, "gamshara.zip",
     [("10021a_e.8e", "1413b7d2"), ("10021a.8d", "73669ff7")], "gamshara"),
    # MEM(N), 2 NANDs, type 2 decrypter; one button, no P2
    ("Star Trigon (Japan, STT1 Ver.A)", "startrgn", 2002, "startrgn.zip",
     [("stt1a_0.bin", "1e090644"), ("stt1a_1.bin", "aa527694")], "startrgn"),
    ("Mr. Driller 2 (Japan, DR21 Ver.A)", "mrdrilr2j", 2000, "mrdrilr2j.zip|mrdrilr2.zip",
     [("dr21vera.1a", "03e0241e"), ("dr21ma1.1d", "26dc6f55"), ("dr21ma2.2d", "702556ff")], "mrdrilr2j"),
    ("Mr. Driller 2 (World, DR22 Ver.A)", "mrdrilr2", 2000, "mrdrilr2.zip",
     [("dr22vera.1a", "140eafb6"), ("dr21ma1.1d", "26dc6f55"), ("dr21ma2.2d", "702556ff")], "mrdrilr2"),
    ("Mr. Driller 2 (US, DR23 Ver.A)", "mrdrilr2u", 2000, "mrdrilr2u.zip|mrdrilr2.zip",
     [("dr23vera.1a", "5f32b6fb"), ("dr21ma1.1d", "26dc6f55"), ("dr21ma2.2d", "702556ff")], "mrdrilr2u"),
    # not a MAME 0.288 set: alternate DR22 flash dump (CRC f2633388), unverified
    ("Mr. Driller 2 (DR22 Ver.A, alt flash dump, unverified)", "mrdrlr2j", 2000, "mrdrlr2j.zip|mrdrilr2.zip",
     [("dr22vera.1a", "f2633388"), ("dr21ma1.1d", "26dc6f55"), ("dr21ma2.2d", "702556ff")], "mrdrilr2"),
]


# key mapping names per core button (J1 order), and the default map: Main_MiSTer gives the default list to the
# named ("-" skipped) buttons in order; an empty entry = no default (Drill (Auto), Pause, Service, Savestates)
BUTTONS = {
    "gamshara": ("Button 1,Button 2,Button 3,-,-,-", "A,B,X,Start,Select"),
    "startrgn": ("Button 1,-,-,-,-,-", "A,Start,Select"),
    # Driller sets: Button2 = Drill (Auto) (config flag, rtl/ns10/ns10_autofire.sv)
    "driller": ("Drill,Drill (Auto),-,-,-,-", "A,,Start,Select"),
}
SYS_BUTTONS = "Start,Coin,Pause,Service,-,Savestates"

# settings region size: MEM(M) flash 0x40000-0x43FFF, MEM(N) NAND0 block 1 (0x4200-0x83FF)
NVRAM_SIZE = {0: 16384, 1: 16896}


def mra(name, setname, year, zips, parts, game):
    blob = ns10cfg.blob(game)
    hexlines = "\n".join("\t\t" + " ".join(f"{b:02X}" for b in blob[i:i + 32]) for i in range(0, len(blob), 32))
    partlines = "\n".join(f'\t\t<part name="{p}" crc="{c}"/>' for p, c in parts)
    return f"""<misterromdescription>
	<name>{name}</name>
	<setname>{setname}</setname>
	<year>{year}</year>
	<manufacturer>{"Mitchell" if game == "gamshara" else "Namco"}</manufacturer>
	<rbf>SYSTEM10</rbf>
	<buttons names="{BUTTONS.get(game, BUTTONS["driller"])[0]},{SYS_BUTTONS}" default="{BUTTONS.get(game, BUTTONS["driller"])[1]}"/>

	<!-- ioctl index 1: board configuration (tools/ns10cfg.py blob {game}) -->
	<rom index="1">
		<part>
{hexlines}
		</part>
	</rom>
	<!-- ioctl index 2: settings / rankings / bookkeeping stored on the ROM board -->
	<nvram index="2" size="{NVRAM_SIZE[ns10cfg.GAMES[game]["board"]]}"/>
	<!-- ioctl index 0: ROM board image -> DDR3 0x35000000 (fast load: Main_MiSTer copies it there) -->
	<rom index="0" zip="{zips}" md5="none" address="0x35000000">
{partlines}
	</rom>
</misterromdescription>
"""


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    for m in MRAS:
        fn = os.path.join(OUT, m[0].replace(":", "") + ".mra")
        with open(fn, "w", newline="\n") as f:
            f.write(mra(*m))
        print(fn)
