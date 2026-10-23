"""NS10 core configuration blob, DDR3 ROM image and RTL testbench vectors.

    python tools/ns10cfg.py blob  <game> <out.bin>
    python tools/ns10cfg.py tbvec <game> <trace> <nvdir> <outdir>

Blob layout: see rtl/ns10/ns10_cfg.sv. The type 2 nonlinear term is stored as
up to five products of two parity factors P(X) = parity(Xc & pc ^ Xp & pp),
times one output mask C; every entry is checked against the MAME formula
(ns10model lambda) on random states.
"""
import os
import random
import struct
import sys

import ns10model as m

GAMES = {
    "mrdrilrg": dict(
        board=1, data_xor=0xAAAA, order=m.MRDRILRG["order"], dec=2,
        emask=m.MRDRILRG["emask"], dmask=m.MRDRILRG["dmask"], xmask=m.MRDRILRG["xmask"],
        iv=m.MRDRILRG["iv"], nlref=m.MRDRILRG["nonlinear"],
        nl_c=0x11,
        nl=[((0x120100400000, 0x120100400000), (0x11800020000, 0x11800020000))],
        nand_count=3, nand_size=0x1080000, nand_id1=0x73,
    ),
    "gamshara": dict(
        board=1, data_xor=0xAAAA, order=m.GAMSHARA["order"], dec=2,
        emask=m.GAMSHARA["emask"], dmask=m.GAMSHARA["dmask"], xmask=m.GAMSHARA["xmask"],
        iv=None, nlref=m.GAMSHARA["nonlinear"],
        nl_c=0x0004,
        nl=[((0x80, 0x80), (0x2000, 0x2000))],
        nand_count=2, nand_size=0x1080000, nand_id1=0x73,
    ),
    "startrgn": dict(
        board=1, data_xor=0xAAAA, order=m.STARTRGN["order"], dec=2,
        emask=m.STARTRGN["emask"], dmask=m.STARTRGN["dmask"], xmask=m.STARTRGN["xmask"],
        iv=None, nlref=m.STARTRGN["nonlinear"],
        nl_c=0x0010,
        nl=[((0x1000, 0x1000), (0x4000, 0x4000))],
        nand_count=2, nand_size=0x1080000, nand_id1=0x73,
    ),
    "mrdrilr2j": dict(board=0, data_xor=0xAAAA, order=m.MRDRILR2_ORDER, dec=1, variant="mrdrilr2j/dr21vera.1a"),
    "mrdrilr2":  dict(board=0, data_xor=0xAAAA, order=m.MRDRILR2_ORDER, dec=1, variant="dr22vera.1a"),
    "mrdrilr2u": dict(board=0, data_xor=0xAAAA, order=m.MRDRILR2_ORDER, dec=1, variant="mrdrilr2u/dr23vera.1a"),
}


def check_nonlinear(g, n=20000):
    rnd = random.Random(1)
    for _ in range(n):
        pc, pp = rnd.getrandbits(48), rnd.getrandbits(48)
        acc = 0
        for (ac, ap), (bc, bp) in g["nl"]:
            acc ^= m.parity(ac & pc ^ ap & pp) & m.parity(bc & pc ^ bp & pp)
        want = g["nlref"](pc, pp) & 0xFFFF
        if (g["nl_c"] if acc else 0) != want:
            raise SystemExit(f"nonlinear term mismatch pc={pc:012x} pp={pp:012x}")


def blob(name):
    g = GAMES[name]
    b = bytearray(0x184)
    b[0] = g["board"]
    b[1] = g.get("nand_count", 0)
    struct.pack_into("<H", b, 0x02, g["data_xor"])
    b[0x04:0x14] = bytes(g["order"])
    b[0x14] = g["dec"]
    if g["dec"] == 2:
        check_nonlinear(g)
        b[0x15] = 1 if g.get("iv") else 0
        struct.pack_into("<HH", b, 0x16, g["xmask"], g["nl_c"])
        for i, v in enumerate(g.get("iv") or [0] * 16):
            struct.pack_into("<H", b, 0x20 + 2 * i, v)
        rows = [(g["emask"][j], g["dmask"][j]) for j in range(16)]
        for a, bb in g["nl"]:
            rows += [a, bb]
        rows += [(0, 0)] * (26 - len(rows))
        for i, (c, p) in enumerate(rows):
            b[0x40 + 12 * i:0x40 + 12 * i + 6] = c.to_bytes(6, "little")
            b[0x46 + 12 * i:0x46 + 12 * i + 6] = p.to_bytes(6, "little")
    if name.startswith("mrdrilr"):
        b[0x15] |= 2   # Button2 = Drill (Auto), rtl/ns10/ns10_autofire.sv
    if g["board"] == 1:
        b[0x1A] = g["nand_id1"]
        struct.pack_into("<I", b, 0x1C, g["nand_size"])
        struct.pack_into("<I", b, 0x180, g["nand_size"] // m.Nand.PAGE)
    return bytes(b)


def make_board(name, nvdir):
    nvdir = None if nvdir == "none" else nvdir
    if name == "mrdrilrg":
        return m.make_mrdrilrg(nvdir)
    if name == "gamshara":
        return m.make_gamshara(nvdir)
    if name == "startrgn":
        return m.make_startrgn(nvdir)
    return m.make_mrdrilr2(GAMES[name]["variant"], nvdir)


def rom_image(board):
    """DDR3 ROM layout: MEM(N) NANDs back to back, MEM(M) flash + data ROMs at 8 MB."""
    if isinstance(board, m.MemN):
        return b"".join(bytes(n.data) for n in board.nands)
    return bytes(board.flash.data) + bytes(board.datarom)


def tbvec(name, trace, nvdir, outdir):
    os.makedirs(outdir, exist_ok=True)
    board = make_board(name, nvdir)
    rom = rom_image(board)
    rom += b"\xff" * (-len(rom) % 8)
    # $fread fills each 64 bit element MSB first: store every beat byte reversed
    with open(os.path.join(outdir, "rom_tb.bin"), "wb") as f:
        f.write(b"".join(rom[i:i + 8][::-1] for i in range(0, len(rom), 8)))
    with open(os.path.join(outdir, "cfg.bin"), "wb") as f:
        f.write(blob(name))
    g = GAMES[name]
    if g["board"] == 1:
        bios = m.memn_bios(board.nands[0].data, g["order"], g["data_xor"])
    else:
        bios = m.memm_bios(board.flash.data, g["order"])
    with open(os.path.join(outdir, "bios_tb.bin"), "wb") as f:
        f.write(b"".join(bios[i:i + 4][::-1] for i in range(0, len(bios), 4)))

    # bus vectors: <R|W> <addr> <mask16> <data16> <check>
    n = 0
    with open(trace) as fi, open(os.path.join(outdir, "vec.txt"), "w") as fo:
        for line in fi:
            p = line.split()
            if len(p) < 6 or p[1] not in ("R", "W"):
                continue
            a, d, mk = int(p[2], 16), int(p[3], 16), int(p[4], 16)
            if not (0x1F000000 <= a < 0x1F800000 or 0x1FA00000 <= a < 0x1FC00000):
                continue
            for sh in (0, 16):
                hm = (mk >> sh) & 0xFFFF
                if not hm:
                    continue
                ha, hd = a + sh // 8, (d >> sh) & 0xFFFF
                chk = 1
                if 0x1FBA001A <= ha < 0x1FBA001C:
                    chk = 0       # int status depends on the 100 Hz timer phase
                if isinstance(board, m.MemM) and (ha < 0x1F800000 or 0x1FB40000 <= ha < 0x1FB60000):
                    # run the model along to find flash status polls during MAME's erase timer
                    board.flash.now = float(p[0])
                    board.flash.timed_read = False
                    if p[1] == "W":
                        board.write16(ha, hd)
                    else:
                        board.read16(ha)
                        if board.flash.timed_read:
                            chk = 0
                fo.write(f"{p[1]} {ha:08X} {hm:04X} {hd:04X} {chk}\n")
                n += 1
    print(f"{name}: {len(rom)} ROM bytes, {n} vectors -> {outdir}")


if __name__ == "__main__":
    cmd = sys.argv[1]
    if cmd == "blob":
        open(sys.argv[3], "wb").write(blob(sys.argv[2]))
    elif cmd == "tbvec":
        tbvec(sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5])
