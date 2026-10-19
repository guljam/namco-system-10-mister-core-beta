"""Bit-exact Python reference model of the Namco System 10 ROM boards.

Mirrors MAME's namcos10.cpp (MEM(M) / MEM(N)), nandflash.cpp (K9F2808U0B) and
ns10crypt.cpp so the RTL can be checked against it, and so the model itself can be
checked against real MAME traces (see replay()).

Trace line format (tools/mame/tap_exp1.lua, NS10_NORLE=1):
    <time> <R|W> <addr32> <data32> <mask32> pc=<pc>
"""
import sys
import zipfile

ROMDIR = "D:/0ROMS/MAME 0.288 ROMs (merged)"


def parity(x):
    return bin(x).count("1") & 1


def bit(x, n):
    return (x >> n) & 1


def bitswap16(v, order):
    """MAME bitswap<16>(v, b15, b14, ..., b0): result bit 15 = v bit order[0]."""
    r = 0
    for i, src in enumerate(order):
        r |= bit(v, src) << (15 - i)
    return r


# --------------------------------------------------------------------------- decrypters

class Type1Decrypter:
    """MEM(M) (mrdrilr2) decrypter: previous cipher/plain word + 8-bit word counter."""
    U = 16
    INIT_SBOX = [U, U, U, 0, 4, 9, U, U, U, 8, U, 1, U, 9, U, 5]

    def __init__(self):
        self.active = False
        self.mask = 0
        self.counter = 0

    def activate(self, iv):
        self.mask = self.INIT_SBOX[iv]
        self.counter = 0
        self.active = True

    def deactivate(self):
        self.active = False

    def decrypt(self, c):
        k = self.counter
        p = self.mask ^ bitswap16(c, (9, 13, 15, 7, 14, 8, 6, 10, 11, 12, 3, 5, 0, 1, 4, 2))
        nbs = ((bit(k, 4)) << 15) ^ \
              ((bit(c, 2) ^ bit(c, 5)) << 14) ^ \
              ((bit(c, 0)) << 13) ^ \
              ((bit(c, 4) | bit(c, 5)) << 12) ^ \
              ((bit(k, 0)) << 11) ^ \
              ((bit(c, 6)) << 10) ^ \
              ((bit(c, 4) & bit(k, 1)) << 8) ^ \
              ((bit(k, 3)) << 6) ^ \
              ((bit(c, 3) | bit(k, 7)) << 5) ^ \
              ((bit(c, 2) ^ bit(k, 3)) << 4) ^ \
              ((bit(k, 2)) << 3) ^ \
              ((bit(c, 7) & bit(k, 7)) << 2) ^ \
              ((bit(k, 5)) << 1) ^ \
              ((bit(c, 7) | bit(k, 1)) << 0)
        self.mask = (nbs ^ bitswap16(c, (6, 11, 3, 1, 13, 5, 15, 10, 2, 9, 8, 4, 0, 12, 7, 14))
                     ^ bitswap16(p, (9, 7, 5, 2, 14, 4, 13, 8, 0, 15, 10, 1, 3, 6, 12, 11)) ^ 0xecbe) & 0xffff
        self.counter = (self.counter + 1) & 0xff  # MAME counter is uint8 wide in practice (bits 0..7 used)
        return p


class Type2Decrypter:
    """MEM(N) decrypter. Linear GF(2) masks over the previous 3 cipher/plain words,
    plus a per-game nonlinear term."""
    INIT_SBOX = [0, 12, 13, 6, 2, 4, 9, 8, 11, 1, 7, 15, 10, 5, 14, 3]

    def __init__(self, emask, dmask, xmask, nonlinear, iv_table=None):
        self.emask, self.dmask, self.xmask = emask, dmask, xmask
        self.nonlinear = nonlinear
        self.iv_table = iv_table
        self.active = False
        self.mask = 0
        self.pc = 0  # previous cipherwords (48 bits used)
        self.pp = 0  # previous plainwords

    def activate(self, iv):
        if self.iv_table is not None:
            self.pc = self.iv_table[iv]
        else:
            s = self.INIT_SBOX[iv]
            # bitswap(INIT_SBOX[iv], 3, 16, 16, 2, 1, 16, 16, 0, 16...) -> 16-bit value, bit16 = 0
            self.pc = (bit(s, 3) << 15) | (bit(s, 2) << 12) | (bit(s, 1) << 11) | (bit(s, 0) << 8)
        self.pp = 0
        self.mask = 0
        self.active = True

    def deactivate(self):
        self.active = False

    def decrypt(self, c):
        p = c ^ self.mask
        M64 = (1 << 64) - 1
        self.pc = ((self.pc << 16) ^ c) & M64
        self.pp = ((self.pp << 16) ^ p) & M64
        m = 0
        for j in range(15, -1, -1):
            m <<= 1
            m ^= parity(self.emask[j] & self.pc)
            m ^= parity(self.dmask[j] & self.pp)
        m ^= self.xmask
        m ^= self.nonlinear(self.pc, self.pp)
        self.mask = m & 0xffff
        return p


# --------------------------------------------------------------------------- NAND

class Nand:
    """Samsung K9F2808U0B as modelled by MAME nandflash.cpp (no sequential row read)."""
    PAGE = 0x210

    def __init__(self, data, num_pages):
        self.data = bytearray(data)
        self.num_pages = num_pages
        self.mode = "INIT"
        self.pm = "A"
        self.page = 0
        self.byte = 0
        self.ptr = 0
        self.status = 0xC0
        self.id = (0xEC, 0x73)
        self.pagereg = bytearray(b"\xff" * self.PAGE)
        self.prog_count = 0

    def command(self, d):
        if d == 0xFF:
            self.mode, self.pm = "INIT", "A"
            self.status = (self.status & 0x80) | 0x40
        elif d == 0x00:
            self.mode, self.pm, self.ptr = "READ", "A", 0
        elif d == 0x01:
            self.mode, self.pm, self.ptr = "READ", "B", 0
        elif d == 0x50:
            self.mode, self.pm, self.ptr = "READ", "C", 0
        elif d == 0x80:
            self.mode, self.ptr, self.prog_count = "PROGRAM", 0, 0
            self.pagereg = bytearray(b"\xff" * self.PAGE)
        elif d in (0x10, 0x15):
            if self.mode == "PROGRAM":
                base = self.page * self.PAGE
                for i in range(self.PAGE):
                    self.data[base + i] &= self.pagereg[i]
                self.status = (self.status & 0x80) | 0x40
            self.mode = "INIT"
        elif d == 0x60:
            self.mode, self.page, self.ptr = "ERASE", 0, 0
        elif d == 0xD0:
            if self.mode == "ERASE":
                base = (self.page & ~31) * self.PAGE
                self.data[base:base + 32 * self.PAGE] = b"\xff" * (32 * self.PAGE)
                self.status = (self.status & 0x80) | 0x40
                if self.pm == "B":
                    self.pm = "A"
            self.mode = "INIT"
        elif d == 0x70:
            self.mode = "STATUS"
        elif d == 0x90:
            self.mode, self.ptr = "ID", 0
        else:
            self.mode = "INIT"

    def address(self, d):
        if self.mode in ("READ", "PROGRAM"):
            if self.ptr == 0:
                self.page = 0
                if self.pm == "A":
                    self.byte = d
                elif self.pm == "B":
                    self.byte = d + 256
                    self.pm = "A"
                else:
                    self.byte = (d & 0x0F) + 512
            elif self.ptr < 3:
                sh = (self.ptr - 1) * 8
                self.page = (self.page & ~(0xFF << sh)) | (d << sh)
            self.ptr += 1
        elif self.mode == "ERASE":
            if self.ptr < 2:
                sh = self.ptr * 8
                self.page = (self.page & ~(0xFF << sh)) | (d << sh)
            self.ptr += 1
        elif self.mode == "ID":
            if self.ptr == 0:
                self.byte = d
            self.ptr += 1

    def read(self):
        if self.mode == "READ":
            if self.byte < self.PAGE and self.page < self.num_pages:
                r = self.data[self.page * self.PAGE + self.byte]
            else:
                r = 0xFF
            self.byte += 1
            return r
        if self.mode == "STATUS":
            return self.status & 0xC1
        if self.mode == "ID":
            r = self.id[self.byte] if self.byte < 2 else 0
            self.byte += 1
            return r
        return 0

    def write(self, d):
        if self.mode == "PROGRAM":
            if self.prog_count < self.PAGE:
                self.pagereg[self.byte] = d
            self.prog_count += 1
            self.byte += 1
            if self.byte == self.PAGE:
                self.byte = 512 if self.pm == "C" else 0


# --------------------------------------------------------------------------- boards

class MemN:
    def __init__(self, nands, unscramble_order, decrypter, data_xor=0xAAAA):
        self.nands = nands
        self.order = unscramble_order
        self.dec = decrypter
        self.data_xor = data_xor
        self.ctrl = 0
        self.idx = 0
        self.addr = 0

    def unscramble(self, v):
        return bitswap16(v, self.order)

    def nand(self):
        return self.nands[self.idx] if self.idx < len(self.nands) else None

    def crypto_w(self, d):
        if self.dec is None:
            return
        if d & 0x8000:
            self.dec.activate(d & 0xF)
        else:
            self.dec.deactivate()

    def data_r(self):
        n = self.nand()
        if n is None:
            return 0xFFFF
        raw = (n.read() << 8)
        raw |= n.read()
        if self.dec is not None and self.dec.active:
            return self.dec.decrypt(raw)
        if self.idx == 0 and ((self.addr >> 8) & 0xFFFF) >> 5 < 2:
            return raw
        return self.unscramble(raw ^ self.data_xor)

    def write16(self, a, d):
        a &= 0x0FFFFFFF
        if a in (0xF300000, 0xF380000):
            self.crypto_w(d)
        elif a == 0xF410000:
            n = self.nand()
            if n:
                n.command(d & 0xFF)
        elif a == 0xF420000:
            n = self.nand()
            if n:
                n.address(d & 0xFF)
            self.addr = (self.addr & 0xFFFF00) | (d & 0xFF)
        elif a == 0xF430000:
            n = self.nand()
            if n:
                n.address(d & 0xFF)
            self.addr = (self.addr & 0xFF00FF) | ((d & 0xFF) << 8)
        elif a == 0xF440000:
            n = self.nand()
            if n:
                n.address(d & 0xFF)
            self.addr = (self.addr & 0x00FFFF) | ((d & 0xFF) << 16)
        elif a == 0xF450000:
            n = self.nand()
            if n:
                n.write(d >> 8)
                n.write(d & 0xFF)
        elif a == 0xF460000:
            if (self.ctrl & 4) == 0:
                self.idx = d
        elif a == 0xF470000:
            self.ctrl = d

    def read16(self, a):
        a &= 0x0FFFFFFF
        if a == 0xF400000:
            return 0  # RnB as MAME models it (ready after every op)
        if a == 0xF450000:
            return self.data_r()
        if a == 0xF470000:
            return self.ctrl & 0xFFFF
        return None  # not a MEM(N) register


class IntelFlash:
    """Intel 28F640J5 as modelled by MAME intelfsh.cpp (16 bit, maker 0x89, device 0x15).
    Block erase: status 0x00, then 0x80 after MAME's 1 s timer (trace time in self.now)."""

    def __init__(self, data):
        self.data = bytearray(data)
        self.mode = "NORMAL"
        self.status = 0x80
        self.master_lock = 0
        self.wb_count = 0
        self.wb = []
        self.wb_start = 0
        self.now = 0.0
        self.erase_done = None   # time of the pending erase timer

    def tick(self):
        if self.erase_done is not None and self.now > self.erase_done + 1e-6:  # trace time has 1 us resolution
            self.erase_done = None
            if self.mode == "READSTATUS":
                self.status = 0x80

    def read(self, word):
        self.tick()
        # status read while MAME's erase timer runs (the RTL finishes erases at once)
        self.timed_read = self.mode == "READSTATUS" and self.erase_done is not None
        if self.mode in ("READSTATUS", "WB2"):
            return self.status
        if self.mode == "WB1":
            return 0x80
        if self.mode == "READID":
            return {0: 0x89, 1: 0x15, 3: self.master_lock}.get(word & 0xFF, 0)
        return self.data[2 * word] | (self.data[2 * word + 1] << 8)

    def write(self, word, d):
        self.tick()
        m = self.mode
        if m in ("NORMAL", "READSTATUS", "READID"):
            c = d & 0xFF
            if c in (0xF0, 0xFF):
                self.mode = "NORMAL"
            elif c == 0x90:
                self.mode = "READID"
            elif c in (0x40, 0x10):
                self.mode = "WRITEPART1"
            elif c == 0x50:
                self.status, self.mode = 0x80, "READSTATUS"
            elif c == 0x20:
                self.mode = "CLEARPART1"
            elif c == 0x60:
                self.mode = "SETMASTER"
            elif c == 0x70:
                self.mode = "READSTATUS"
            elif c == 0xE8:
                self.mode = "WB1"
        elif m == "WRITEPART1":
            self.data[2 * word], self.data[2 * word + 1] = d & 0xFF, d >> 8
            self.status, self.mode = 0x80, "READSTATUS"
        elif m == "CLEARPART1":
            if d & 0xFF == 0xD0:
                base = (2 * word) & ~0xFFFF
                self.data[base:base + 0x10000] = bytes([0xFF]) * 0x10000
                self.status, self.mode = 0x00, "READSTATUS"
                self.erase_done = self.now + 1.0
        elif m == "SETMASTER":
            if d & 0xFF == 0xF1:
                self.master_lock = 1
            elif d & 0xFF == 0xD0:
                self.master_lock = 0
            self.mode = "READSTATUS"
        elif m == "WB1":
            self.wb_count = min(d, 0xF) + 1
            self.wb = []
            self.status, self.mode = 0x80, "WB2"
        elif m == "WB2":
            if len(self.wb) < self.wb_count:
                if not self.wb:
                    self.wb_start = word
                if word >= self.wb_start + self.wb_count:
                    self.status, self.mode = 0x30, "READSTATUS"
                else:
                    self.wb.append(d)
            else:
                if d & 0xFF == 0xD0:
                    for i, v in enumerate(self.wb):
                        w = self.wb_start + i
                        self.data[2 * w], self.data[2 * w + 1] = v & 0xFF, v >> 8
                    self.status = 0x80
                else:
                    self.status = 0x30
                self.mode = "READSTATUS"


class MemM:
    def __init__(self, flash, data_rom, unscramble_order, decrypter):
        self.flash = IntelFlash(flash)
        self.nandrom = bytes(flash)
        self.datarom = data_rom
        self.order = unscramble_order
        self.dec = decrypter
        self.bank = 0
        self.direct = 0

    def unscramble(self, v):
        return bitswap16(v, self.order)

    def write16(self, a, d):
        a &= 0x0FFFFFFF
        if a == 0xF300000:
            if d & 0x8000:
                self.dec.activate(d & 0xF)
            else:
                self.dec.deactivate()
        elif 0xFB40000 <= a < 0xFB60000:
            self.bank = (a - 0xFB40000) >> 1
            self.direct = 1 if self.bank >= 0x10 else 0
        elif 0xF400000 <= a < 0xF600000:
            if self.direct == 0:
                self.flash.write((a - 0xF400000) >> 1, d)  # MAME nand_w ignores the bank

    def read16(self, a):
        a &= 0x0FFFFFFF
        if 0xFB40000 <= a < 0xFB60000:
            self.direct = 1
            return 0
        if 0xF400000 <= a < 0xF600000:
            off = (a - 0xF400000) >> 1
            if self.direct == 0:
                return self.flash.read(0x100000 * self.bank + off)
            if self.bank < 0x10:
                w = 0x100000 * self.bank + off
                src = self.nandrom
            else:
                w = 0x100000 * (self.bank - 0x10) + off
                src = self.datarom
            v = src[2 * w] | (src[2 * w + 1] << 8) if 2 * w + 1 < len(src) else 0
            if self.dec.active:
                return self.dec.decrypt(v)
            if self.bank < 0x10:
                v = self.unscramble(v ^ 0xAAAA)
            return v
        return None


# --------------------------------------------------------------------------- game configs

def gf2(x):
    return parity(x)


MRDRILRG = dict(
    zip="mrdrilrg.zip",
    nands=["0.8e", "1.8d", "2.7e"],
    order=(0xe, 0xc, 0xf, 0xd, 0xa, 0x9, 0x8, 0xb, 0x4, 0x5, 0x6, 0x7, 0x0, 0x1, 0x3, 0x2),
    emask=[0x0000115c68620401, 0x0000008102802094, 0x00000081a65270a8, 0x0000000000810010,
           0x00004c2c080f3059, 0x00000081470a9500, 0x000000816a123009, 0x00000081a2b23038,
           0x00002d18a06b9000, 0x000001186c02000c, 0x00000081a2b2704c, 0x0000702811016302,
           0x00000081470a1122, 0x0000000000006200, 0x00009170ac403013, 0x0000000000001044],
    xmask=0x0000,
    nonlinear=lambda pc, pp: (1 & gf2((pc ^ pp) & 0x120100400000) & gf2((pc ^ pp) & 0x11800020000)) * 0x11,
    iv=[0x0000, 0x0000, 0x0000, 0x2000, 0x801a, 0x6000, 0x0002, 0x0000,
        0x0000, 0x0018, 0x0000, 0x0420, 0x0000, 0x8800, 0x0000, 0xc000],
)
MRDRILRG["dmask"] = MRDRILRG["emask"]

GAMSHARA = dict(
    zip="gamshara.zip",
    nands=["10021a_e.8e", "10021a.8d"],
    order=(0xd, 0xc, 0xf, 0xe, 0x8, 0x9, 0xb, 0xa, 0x5, 0x7, 0x4, 0x6, 0x0, 0x1, 0x2, 0x3),
    emask=[0x0000000000000028, 0x0000cae83f389fd9, 0x0000000000001000, 0x0000000042823402,
           0x0000cae8736a0592, 0x0000cae8736a8596, 0x000000008b4095b9, 0x0000000000002100,
           0x0000000004018228, 0x0000000000000042, 0x0000000000000818, 0x0000000000004010,
           0x000000008b4099f1, 0x00000000044bce08, 0x00000000000000c1, 0x0000000042823002],
    dmask=[0x0000000000000028, 0x00000904c2048dd9, 0x0000000000008000, 0x0000000054021002,
           0x00000904e0078592, 0x00000904e00785b2, 0x00000000440097f9, 0x0000000000002104,
           0x0000000029018308, 0x0000000000000042, 0x0000000000000850, 0x0000000000004012,
           0x000000004400d1f1, 0x000000006001ce08, 0x00000000000000c8, 0x0000000054023002],
    xmask=0x25ab,
    nonlinear=lambda pc, pp: (((pc ^ pp) >> 7) & ((pc ^ pp) >> 13) & 1) << 2,
    iv=None,
)

STARTRGN = dict(
    zip="startrgn.zip",
    nands=["stt1a_0.bin", "stt1a_1.bin"],
    order=(0xe, 0xd, 0xc, 0xf, 0x9, 0xb, 0x8, 0xa, 0x4, 0x5, 0x6, 0x7, 0x0, 0x3, 0x2, 0x1),
    emask=[0x00003e4bfe92c6a9, 0x000000000000010c, 0x00003e4b7bd6c4aa, 0x0000b1a904b8fab8,
           0x0000000000000080, 0x0000000000008c00, 0x0000b1a9b2f0b4cd, 0x000000006c100828,
           0x000000006c100838, 0x0000b1a9d3913fcd, 0x000000006161aa00, 0x0000000000006040,
           0x0000000000000420, 0x0000000000001801, 0x00003e4b7bd6deab, 0x0000000000000105],
    dmask=[0x000012021f00c6a8, 0x0000000000000008, 0x000012020b1046aa, 0x000012001502fea8,
           0x0000000000002000, 0x0000000000008800, 0x000012001e02b4cd, 0x000000002c0008aa,
           0x000000002c00083a, 0x000012003f027ecd, 0x0000000021008a00, 0x0000000000002040,
           0x0000000000000428, 0x0000000000001001, 0x000012020b10ceab, 0x0000000000000144],
    xmask=0x8c46,
    nonlinear=lambda pc, pp: (((pc ^ pp) >> 12) & ((pc ^ pp) >> 14) & 1) << 4,
    iv=None,
)

MRDRILR2_ORDER = (0xc, 0xd, 0xf, 0xe, 0xb, 0xa, 0x9, 0x8, 0x7, 0x6, 0x4, 0x1, 0x2, 0x5, 0x0, 0x3)


def load_zip(name, members):
    with zipfile.ZipFile(f"{ROMDIR}/{name}") as z:
        return [z.read(m) for m in members]


def load_nvram(nvdir, names, fallback):
    """MAME keeps flash/NAND contents as NVRAM; a trace recorded with saved settings only
    replays bit-exact when the model starts from the same image."""
    if not nvdir:
        return fallback
    import os
    out = []
    for n, fb in zip(names, fallback):
        f = os.path.join(nvdir, n)
        out.append(open(f, "rb").read() if os.path.exists(f) else fb)
    return out


def make_mrdrilrg(nvdir=None):
    g = MRDRILRG
    datas = load_nvram(nvdir, ["nand0", "nand1", "nand2"], load_zip(g["zip"], g["nands"]))
    nands = [Nand(d, len(d) // Nand.PAGE) for d in datas]
    dec = Type2Decrypter(g["emask"], g["dmask"], g["xmask"], g["nonlinear"], g["iv"])
    return MemN(nands, g["order"], dec)


def make_gamshara(nvdir=None):
    g = GAMSHARA
    datas = load_nvram(nvdir, ["nand0", "nand1"], load_zip(g["zip"], g["nands"]))
    nands = [Nand(d, len(d) // Nand.PAGE) for d in datas]
    dec = Type2Decrypter(g["emask"], g["dmask"], g["xmask"], g["nonlinear"], g["iv"])
    return MemN(nands, g["order"], dec)


def make_startrgn(nvdir=None):
    g = STARTRGN
    datas = load_nvram(nvdir, ["nand0", "nand1"], load_zip(g["zip"], g["nands"]))
    nands = [Nand(d, len(d) // Nand.PAGE) for d in datas]
    dec = Type2Decrypter(g["emask"], g["dmask"], g["xmask"], g["nonlinear"], g["iv"])
    return MemN(nands, g["order"], dec)


def make_mrdrilr2(variant="mrdrilr2j/dr21vera.1a", nvdir=None):
    flash, ma1, ma2 = load_zip("mrdrilr2.zip", [variant, "dr21ma1.1d", "dr21ma2.2d"])
    m = MemM(flash, ma1 + ma2, MRDRILR2_ORDER, Type1Decrypter())
    # MAME splits the chip: direct (decoded) reads use the ROM region, flash-mode reads
    # use the NVRAM copy. Real hardware has one chip; the FPGA keeps one copy.
    nv = load_nvram(nvdir, ["nand"], [None])[0]
    if nv is not None:
        # intelfsh NVRAM files hold big-endian words; the ROM region is little-endian
        nv = bytes(b for i in range(0, len(nv), 2) for b in (nv[i + 1], nv[i]))
    m.flash = IntelFlash(nv if nv is not None else flash)
    return m


# --------------------------------------------------------------------------- BIOS images

def memn_bios(nand0, order, xor=0xAAAA):
    """Replicates namcos10_memn_state::memn_driver_init (4 MB BIOS window image)."""
    bios = bytearray(b"\x55" * 0x400000)

    def copy(dst, start_page, npages):
        for page in range(start_page, start_page + npages):
            base = page * 0x210
            for i in range(0, 0x200, 2):
                w = (nand0[base + i] << 8) | nand0[base + i + 1]
                w = bitswap16(w ^ xor, order)
                bios[dst] = w & 0xFF
                bios[dst + 1] = w >> 8
                dst += 2
    copy(0, 0x40, 0xE0)
    copy(0x20000, 0x120, 0x1F00)
    return bios


def memm_bios(flash, order):
    bios = bytearray(b"\x55" * 0x400000)
    for i in range(0, 0x62000, 2):
        w = flash[i] | (flash[i + 1] << 8)
        w = bitswap16(w ^ 0xAAAA, order)
        bios[i] = w & 0xFF
        bios[i + 1] = w >> 8
    return bios


# --------------------------------------------------------------------------- trace replay

def replay(board, path, limit=None, report=10):
    """Feed every board-register access from a MAME trace through the model and compare
    each read value with what MAME returned. Returns (reads_checked, mismatches)."""
    checked = bad = 0
    with open(path) as f:
        for n, line in enumerate(f):
            if limit and n >= limit:
                break
            parts = line.split()
            if len(parts) < 6 or parts[1] not in ("R", "W"):
                continue
            rw, a, d, m = parts[1], int(parts[2], 16), int(parts[3], 16), int(parts[4], 16)
            if isinstance(board, MemM):
                board.flash.now = float(parts[0])
            if not (0x1F000000 <= a < 0x1F800000 or 0x1FB40000 <= a < 0x1FB60000):
                continue
            halves = []
            if m & 0x0000FFFF:
                halves.append((a, d & 0xFFFF))
            if m & 0xFFFF0000:
                halves.append((a + 2, (d >> 16) & 0xFFFF))
            for ha, hd in halves:
                if rw == "W":
                    board.write16(ha, hd)
                else:
                    got = board.read16(ha)
                    if got is None:
                        continue
                    checked += 1
                    if got != hd:
                        bad += 1
                        if bad <= report:
                            print(f"MISMATCH line {n}: {line.strip()} model={got:04X}")
    return checked, bad


if __name__ == "__main__":
    game, trace = sys.argv[1], sys.argv[2]
    nvdir = sys.argv[3] if len(sys.argv) > 3 else None
    board = make_mrdrilrg(nvdir) if game == "mrdrilrg" else make_mrdrilr2(nvdir=nvdir)
    c, b = replay(board, trace)
    print(f"{game}: {c} reads checked, {b} mismatches")


def check_bios(bios, path):
    """Compare every BIOS-window read in a trace with the generated 4 MB image."""
    checked = bad = 0
    with open(path) as f:
        for line in f:
            parts = line.split()
            if len(parts) < 6 or parts[1] != "R":
                continue
            a = int(parts[2], 16)
            if not 0x1FC00000 <= a < 0x20000000:
                continue
            d, m = int(parts[3], 16), int(parts[4], 16)
            o = a - 0x1FC00000
            w = int.from_bytes(bios[o:o + 4], "little")
            checked += 1
            if (w ^ d) & m:
                bad += 1
                if bad <= 5:
                    print(f"BIOS MISMATCH {line.strip()} model={w:08X}")
    return checked, bad
