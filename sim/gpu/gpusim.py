"""Inputs / results for sim/gpu/tb_gpu.vhd.

    python gpusim.py prep <mame gpu.log> <vram.bin> <outdir> [field] [--prog]
        gpu.log from tools/mame/tap_gpu.lua with NS10_FULL=1, vram.bin = 2 MB MAME gpu_ram dumped at the
        first VBL of the log. Writes <outdir>/cmd.txt (GP0 stream of field <field>, default 0) and vram_in.hex.
        --prog: progressive display (no interlace line skip; draw order independent of the field timing).
    python gpusim.py stats <log.txt>               per-op clk2x cycles (header to next header), total
    python gpusim.py cmp <a.hex> <b.hex> [diff.png]
"""
import struct
import sys
from collections import defaultdict


def prep(log, vram, out, field=0, prog=False):
    words = []
    n = -1
    skip = 0
    for line in open(log):
        p = line.split()
        if len(p) != 4:
            continue
        kind, d = p[2], int(p[3], 16)
        if kind == "VBL":
            n += 1
            if n > field:
                break
            continue
        if n != field:
            continue
        if kind in ("GP0", "PAR", "GP0CPU"):
            if kind != "PAR" and 0xA0 <= (d >> 24) <= 0xBF:
                skip = 2   # CPU->VRAM: the data goes by DMA block mode, not in the log
                continue
            if skip:
                skip -= 1
                continue
            words.append(f"0 {d:08X}")
        elif kind == "GP1" and (d >> 24) in (0x05, 0x06, 0x07):
            words.append(f"1 {d:08X}")
    head = ["1 00000000", "1 06C60260", "1 07040010", "1 08000007" if prog else "1 08000027",
            "1 05000000", "1 03000000", "W 200"]
    open(f"{out}/cmd.txt", "w").write("\n".join(head + words) + "\n")
    d = open(vram, "rb").read()
    with open(f"{out}/vram_in.hex", "w") as f:
        for (w,) in struct.iter_unpack("<Q", d):
            f.write(f"{w:016X}\n")
    print(f"{len(words)} words -> {out}/cmd.txt")


def stats(path):
    hdr, fields, end = [], [], None
    for line in open(path):
        p = line.split()
        if p[0] == "H":
            hdr.append((int(p[1]), int(p[2], 16) >> 24, [int(x) for x in p[3:]]))
        elif p[0] == "F":
            fields.append(int(p[1]))
        elif p[0] == "E":
            end = int(p[1])
    per = defaultdict(list)
    cnt = defaultdict(lambda: [0] * 5)
    for (c, op, k), (c2, _, k2) in zip(hdr, hdr[1:] + [(end, 0, hdr[-1][2])]):
        per[op].append(c2 - c)
        for i in range(min(len(k), len(k2))):
            cnt[op][i] += k2[i] - k[i]
    tot = end - hdr[0][0]
    print(f"headers {len(hdr)}, total {tot} clk2x = {tot / 67737.6:.2f} ms")
    print(" op   count     mean clk   sum share   per prim: stall  tex  clut  lines  pixels")
    for op, v in sorted(per.items(), key=lambda kv: -sum(kv[1]))[:10]:
        n = len(v)
        k = "  ".join(f"{x / n:6.1f}" for x in cnt[op]) if hdr[0][2] else ""
        print(f" {op:02X}  {n:6d}  {sum(v) / n:10.1f}  {100 * sum(v) / tot:5.1f} %   {k}")


def load(path):
    return [int(x, 16) for x in open(path)]


def cmp(a, b, png=None):
    A, B = load(a), load(b)
    diff = [i for i in range(len(A)) if A[i] != B[i]]
    px = 0
    for i in diff:
        for k in range(4):
            if (A[i] >> (16 * k)) & 0xFFFF != (B[i] >> (16 * k)) & 0xFFFF:
                px += 1
    print(f"differing pixels: {px}")
    if png and diff:
        from PIL import Image
        im = Image.new("RGB", (1024, 1024))
        for i in diff:
            for k in range(4):
                if (A[i] >> (16 * k)) & 0xFFFF != (B[i] >> (16 * k)) & 0xFFFF:
                    hw = (i % (1 << 17)) * 4 + k + (512 * 1024 if i >= (1 << 17) else 0)
                    im.putpixel((hw % 1024, hw // 1024), (255, 0, 0))
        im.save(png)


if __name__ == "__main__":
    a = sys.argv[1:]
    if not a:
        print(__doc__)
    elif a[0] == "prep":
        rest = [x for x in a[4:] if x != "--prog"]
        prep(a[1], a[2], a[3], int(rest[0]) if rest else 0, "--prog" in a)
    elif a[0] == "stats":
        stats(a[1])
    elif a[0] == "cmp":
        cmp(a[1], a[2], a[3] if len(a) > 3 else None)
