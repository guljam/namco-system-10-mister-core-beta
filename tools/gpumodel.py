"""DuckStation GPU draw-time model over a MAME tap_gpu.lua NS10_FULL=1 log.
Per field (VBL to VBL): GPU ticks (DuckStation units: 2 per 33.8688 MHz sysclk = 67.7376 MHz,
same as the PSX core clk2x), -> ms at PSX speed and at NS10 speed (GPU 50.7456 MHz = 1.5x).
usage: python tools/gpumodel.py <gpu.log> [t0] [t1] [-v]
Log: NS10_FULL=1 NS10_GPULOG=<gpu.log> namcos10.exe <set> -autoboot_script tools/mame/tap_gpu.lua
"""
import sys
from collections import Counter, defaultdict

PSX = 67.7376e6
NS10 = PSX * 1.5


def s11(v):
    v &= 0x7FF
    return v - 0x800 if v & 0x400 else v


class Model:
    def __init__(self):
        self.e1 = 0
        self.area = (0, 0, 1023, 511)
        self.off = (0, 0)
        self.mask_check = 0
        self.gp1_08 = 0x08000027   # 480i (log window starts after the GP1 08 write)
        self.clut = None
        self.ticks = 0
        self.per = Counter()
        self.cnt = Counter()
        self.px = Counter()

    def skip(self):
        return (self.gp1_08 & 0x24) == 0x24 and not (self.e1 >> 10) & 1

    def tmode(self):
        return (self.e1 >> 7) & 3

    def add(self, op, t, px=0, n=0):
        self.ticks += t
        self.per[op] += t
        self.cnt[op] += n
        self.px[op] += px

    def clamp(self, x, y):
        l, t, r, b = self.area
        return min(max(x, l), r + 1), min(max(y, t), b + 1)

    def clut_load(self, op, pal):
        tm = self.tmode()
        if tm < 2 and (pal, tm) != self.clut:
            self.clut = (pal, tm)
            self.add(op, 256 if tm == 1 else 16)

    def packet(self, w):
        op = w[0] >> 24
        if op == 0xE1:
            self.e1 = w[0]
        elif op == 0xE3:
            self.area = (w[0] & 0x3FF, (w[0] >> 10) & 0x3FF, self.area[2], self.area[3])
        elif op == 0xE4:
            self.area = (self.area[0], self.area[1], w[0] & 0x3FF, (w[0] >> 10) & 0x3FF)
        elif op == 0xE5:
            self.off = (s11(w[0]), s11(w[0] >> 11))
        elif op == 0xE6:
            self.mask_check = (w[0] >> 1) & 1
        elif op == 0x02 and len(w) >= 3:
            wd = ((w[2] & 0x3FF) + 15) & ~15
            ht = (w[2] >> 16) & 0x1FF
            self.add(op, 46 + ((wd // 8) + 9) * ht, wd * ht, 1)
        elif 0x20 <= op <= 0x3F:
            quad, shaded, tex, semi = op & 8, op & 0x10, op & 4, op & 2
            nv = 4 if quad else 3
            pv = 1 + (1 if tex else 0) + (1 if shaded else 0)
            vs, uvs = [], []
            i = 1
            for k in range(nv):
                if shaded and k > 0:
                    i += 1
                if i >= len(w):
                    return
                vs.append((s11(w[i]) + self.off[0], s11(w[i] >> 16) + self.off[1]))
                i += 1
                if tex:
                    if i < len(w):
                        uvs.append(w[i])
                    i += 1
            if tex and uvs:
                self.clut_load(op, uvs[0] >> 16)
                if len(uvs) > 1:
                    self.e1 = (self.e1 & ~0x9FF) | ((uvs[1] >> 16) & 0x9FF)
            setup = [[[46, 226], [334, 496]], [[82, 262], [370, 532]]][1 if quad else 0][1 if shaded else 0][1 if tex else 0]
            self.add(op, setup, 0, 1)
            tris = [(vs[0], vs[1], vs[2])] + ([(vs[2], vs[1], vs[3])] if quad else [])
            for a, b, c in tris:
                a, b, c = self.clamp(*a), self.clamp(*b), self.clamp(*c)
                px = abs((a[0] * b[1] + b[0] * c[1] + c[0] * a[1] - a[0] * c[1] - b[0] * a[1] - c[0] * b[1]) // 2)
                p = px
                if tex:
                    p += p
                if semi or self.mask_check:
                    p += (p + 1) // 2
                if self.skip():
                    p //= 2
                self.add(op, p, px)
        elif 0x40 <= op <= 0x5F:
            self.add(op, 16 + 50, 0, 1)
        elif 0x60 <= op <= 0x7F:
            tex, semi, size = op & 4, op & 2, (op >> 3) & 3
            if len(w) < 2:
                return
            x, y = s11(w[1]) + self.off[0], s11(w[1] >> 16) + self.off[1]
            i = 2
            if tex:
                if i < len(w):
                    self.clut_load(op, w[i] >> 16)
                i += 1
            if size == 0:
                if i >= len(w):
                    return
                wd, ht = w[i] & 0x3FF, (w[i] >> 16) & 0x1FF
            else:
                wd = ht = [0, 1, 8, 16][size]
            l, t, r, b = self.area
            dw = max(0, min(x + wd, r + 1) - max(x, l))
            dh = max(0, min(y + ht, b + 1) - max(y, t))
            tpr = dw
            if tex:
                tm = self.tmode()
                if tm == 0:
                    tpr += dw
                elif tm == 1:
                    tpr += (dw // 4) * 8 if dw > 128 else ((dw // 4) * (4 * (128 // dw)) if dw * dh > 2048 else dw)
                else:
                    tpr += (dw // 2) * 8 if dw > 128 else ((dw // 4) * (8 * (128 // dw)) if dw * dh > 1024 else dw)
            if semi or self.mask_check:
                tpr += (dw + 1) // 2
            if self.skip():
                dh = max(dh // 2, 1) if dh else 0
            self.add(op, 16, 0, 1)
            self.add(op, tpr * dh, dw * dh)
        elif 0x80 <= op <= 0x9F and len(w) >= 4:
            wd = ((w[3] & 0x3FF) - 1) % 1024 + 1
            ht = (((w[3] >> 16) & 0x3FF) - 1) % 512 + 1
            self.add(op, wd * ht * 2, wd * ht, 1)


def plen(op):
    if 0x20 <= op <= 0x3F:
        nv = 4 if op & 8 else 3
        per = 1 + (1 if op & 4 else 0) + (1 if op & 0x10 else 0)
        return nv * per - (1 if op & 0x10 else 0)
    if 0x40 <= op <= 0x5F:
        return 3 if op & 0x10 else 2
    if 0x60 <= op <= 0x7F:
        return 1 + (1 if op & 4 else 0) + (1 if ((op >> 3) & 3) == 0 else 0)
    if op == 0x02 or 0xA0 <= op <= 0xDF:
        return 2
    if 0x80 <= op <= 0x9F:
        return 3
    return 0


def main():
    path = sys.argv[1]
    t0 = float(sys.argv[2]) if len(sys.argv) > 2 else 0
    t1 = float(sys.argv[3]) if len(sys.argv) > 3 else 1e9
    verbose = "-v" in sys.argv
    m = Model()
    fields = []
    pkt = None          # DMA walk packet
    cpu = []            # CPU GP0 packet in progress
    cpu_skip = 0
    total_per = Counter()
    total_cnt = Counter()
    total_px = Counter()

    def flush():
        nonlocal pkt
        if pkt:
            m.packet(pkt)
            pkt = None

    for line in open(path):
        p = line.split()
        if len(p) != 4:
            continue
        t, kind, d = float(p[0]), p[2], int(p[3], 16)
        if kind == "PAR":
            if pkt is not None:
                pkt.append(d)
            continue
        flush()
        if kind == "GP0":
            pkt = [d]
        elif kind == "GP0CPU":
            if cpu_skip:
                cpu_skip -= 1
                continue
            cpu.append(d)
            if len(cpu) == 1 + plen(cpu[0] >> 24):
                m.packet(cpu)
                if 0xA0 <= cpu[0] >> 24 <= 0xBF:
                    wd, ht = cpu[2] & 0xFFFF, cpu[2] >> 16
                    cpu_skip = (wd * ht + 1) // 2
                cpu = []
        elif kind == "GP1":
            if d >> 24 == 0x08:
                m.gp1_08 = d
            elif d >> 24 == 0x01:
                cpu, cpu_skip = [], 0
        elif kind == "VBL":
            if t0 <= t < t1:
                fields.append((t, m.ticks, m.per.copy(), m.skip()))
                total_per.update(m.per)
                total_cnt.update(m.cnt)
                total_px.update(m.px)
            m.ticks = 0
            m.per, m.cnt, m.px = Counter(), Counter(), Counter()
    flush()

    tk = sorted(f[1] for f in fields if f[1] > 0)
    if not tk:
        print("no fields")
        return
    def pct(q):
        return tk[min(len(tk) - 1, int(q * len(tk)))]
    print(f"fields {len(fields)} with draws {len(tk)}  interlace-skip {sum(1 for f in fields if f[3])}")
    for name, q in (("median", 0.5), ("p90", 0.9), ("max", 1.0)):
        v = pct(q) if q < 1 else tk[-1]
        print(f"  {name:6s} {v:9d} ticks  PSX {v / PSX * 1e3:6.2f} ms  NS10 {v / NS10 * 1e3:6.2f} ms")
    print(f"  fields over 16.68 ms: PSX {sum(1 for v in tk if v / PSX > 0.01668)}  NS10 {sum(1 for v in tk if v / NS10 > 0.01668)}")
    tot = sum(total_per.values())
    n = len(tk)
    print("  per op (avg per field): count, ticks, share, avg pixels")
    for op, v in total_per.most_common(12):
        c = total_cnt[op]
        print(f"   {op:02X}  {c / n:7.1f}  {v / n:9.0f}  {100 * v / tot:5.1f} %  px/prim {total_px[op] / max(c, 1):8.1f}")
    if verbose:
        for t, v, per, sk in fields:
            print(f"{t:9.3f} {v:8d} {v / PSX * 1e3:6.2f} {v / NS10 * 1e3:6.2f}")


if __name__ == "__main__":
    main()
