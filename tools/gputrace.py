"""GPU / DMA / IRQ trace (rtl/ns10/ns10_gtrace.sv) from the MiSTer.

    python tools/gputrace.py start                 # start a 10 s trace over JTAG (or OSD "Trace GPU 10 s")
    python tools/gputrace.py status                # JTAG probe: state, beats written
    python tools/gputrace.py fetch <out.bin>       # copy the trace from DDR3 0x3A000000 (SSH + /dev/mem)
    python tools/gputrace.py dump <in.bin> [out.txt]
    python tools/gputrace.py fields <in.bin> [out.txt]   # one line per vblank
    python tools/gputrace.py rombus <in.bin> [out.txt]   # one line per vblank: flips, EXP1 reads / wait, SPU stream
    python tools/gputrace.py drill <in.bin> [out.txt]    # Drill (Auto): state changes and IRQ10 acks per vblank
    python tools/gputrace.py frames <in.bin> [out.txt]   # per field: CPU idle in VSync(), GP1(05) latency, summary

Entry: [63:60] type, [59:34] time (clk2x/16), [33] activeLineLSB, [32] inVsync, [31:0] data.
"""
import ftplib
import io
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(__file__))
import deploy      # noqa: E402  (ssh, host settings)
import ns10trace   # noqa: E402  (JTAG tcl helpers)

TICK = 16 / 67737600.0
NAMES = {1: "GP0", 2: "PAR", 3: "END", 4: "GP1", 5: "MADR2", 6: "BCR2", 7: "CHCR2", 8: "DICR",
         9: "IRQW", 0xA: "VBL", 0xB: "VBL2", 0xC: "FIFOFULL", 0xD: "DMA+", 0xE: "DMA-", 0xF: "CTL"}

REMOTE = r'''
import mmap, os, struct
fd = os.open("/dev/mem", os.O_RDONLY | os.O_SYNC)
m = mmap.mmap(fd, 32 << 20, mmap.MAP_SHARED, mmap.PROT_READ, offset=0x3A000000)
n = 0
while n < (32 << 20) // 8:
    chunk = m[n * 8:(n + 4096) * 8]
    words = struct.unpack("<%dQ" % (len(chunk) // 8), chunk)
    end = [i for i, w in enumerate(words) if (w >> 60) == 0xF and ((w >> 28) & 0xF) == 1]
    if end:
        n += end[0] + 1
        break
    n += len(words)
open("/tmp/gtrace.bin", "wb").write(m[:n * 8])
print(n)
'''


def jtag_probe(write=None):
    hw, dev = ns10trace.HW, ns10trace.DEV
    o = ns10trace.tcl(f'set hw "{hw}"\nset dev "{dev}"\n'
                      'foreach i [get_insystem_source_probe_instance_info -hardware_name $hw -device_name $dev] {\n'
                      ' if {[lindex $i 3] == "GTRC"} { set pi [lindex $i 0] } }\n'
                      'start_insystem_source_probe -hardware_name $hw -device_name $dev\n'
                      'puts "GTRC [read_probe_data -instance_index $pi -value_in_hex]"\n' +
                      ('write_source_data -instance_index $pi -value 1\nafter 10\nwrite_source_data -instance_index $pi -value 0\n'
                       if write else '') +
                      'end_insystem_source_probe\n')
    v = int(o.split("GTRC ")[1].split()[0], 16)
    st = ["idle", "recording", "flushing", "done"][(v >> 30) & 3]
    print(f"state {st}, beats {v & 0x3FFFFF}, lost {'yes' if (v >> 29) & 1 else 'no'}" + (" -- started" if write else ""))


def fetch(out):
    ftp = ftplib.FTP(deploy.HOST, deploy.USER, deploy.PW, timeout=60)
    ftp.storbinary("STOR /tmp/gtfetch.py", io.BytesIO(REMOTE.encode()))
    n = deploy.ssh("python3 /tmp/gtfetch.py")
    print(f"{n.strip()} entries")
    with open(out, "wb") as f:
        ftp.retrbinary("RETR /tmp/gtrace.bin", f.write)
    ftp.quit()
    print(f"-> {out}")


def entries(path):
    data = open(path, "rb").read()
    for (w,) in struct.iter_unpack("<Q", data[:len(data) // 8 * 8]):
        t = w >> 60
        if t == 0:
            continue
        yield t, ((w >> 34) & 0x3FFFFFF) * TICK, (w >> 33) & 1, (w >> 32) & 1, w & 0xFFFFFFFF


def decode(t, d):
    if t == 1:
        return f"{d:08X} op {d >> 24:02X}"
    if t == 3:
        return f"op {d >> 24:02X} words {d & 0xFFFFFF}"
    if t == 4:
        return f"{d:08X} cmd {d >> 24:02X}"
    if t == 9:
        return f"{'I_STAT' if (d >> 28) == 0 else 'I_MASK' if (d >> 28) == 4 else hex(d >> 28)} {d & 0xFFFFFFF:04X}"
    if t == 0xA:
        return f"headers {d >> 16} gpustat_reads {d & 0xFFFF}"
    if t == 0xB:
        return f"dma2_words {d >> 12} cpu_gp0 {(d >> 2) & 0x3FF} gpu_idle {(d >> 1) & 1} fifo_empty {d & 1}"
    if t == 0xE:
        return f"words {d}"
    if t == 0xF:
        sub = d >> 28
        if sub == 0:
            return f"START run {d & 0xFF} cfg {(d >> 8) & 0xFFFF:04X}"
        if sub == 1:
            return f"END lost {(d >> 22) & 0x3F} beats {d & 0x3FFFFF}"
        if sub == 2:
            return f"DMA4 {('MADR', 'BCR', 'CHCR', '?')[(d >> 26) & 3]} {d & 0x3FFFFFF:07X}"
        if sub == 3:
            return f"EXP3 W {0x1FA00000 + (((d >> 24) & 0xF) << 16) + ((d >> 16) & 0xFF):08X} {d & 0xFFFF:04X}"
        if sub == 4:
            return f"EXP1 reads {d & 0xFFFFFFF}"
        if sub == 5:
            return f"EXP1 wait clk2x {d & 0xFFFFFFF}"
        if sub == 6:
            return "AF " + af_text(d)
        if sub == 7:
            return "VSYNC enter" if d & 1 else "VSYNC leave"
        if sub == 8:
            return f"VSYNC idle {(d & 0xFFFFFFF) / 67737.6:.3f} ms"
    return f"{d:08X}"


def af_text(d):
    """ns10_autofire dbg: {pad P2 P1, fire P2 P1, btn P2 P1, versus, side, st1, st0, cooldown 1, cooldown 0}"""
    return (f"pad {(d >> 26) & 3:02b} fire {(d >> 24) & 3:02b} btn {(d >> 22) & 3:02b} vs {(d >> 21) & 1} "
            f"side {(d >> 20) & 1} st1 {(d >> 18) & 3} st0 {(d >> 16) & 3} cd1 {(d >> 8) & 0xFF} cd0 {d & 0xFF}")


def drill(path, out=None):
    """Drill (Auto): per vblank, the autofire state changes (ms after the vblank) and the IRQ10 acks
    (EXP3 write 0x1FBA0018: the ISR that read IN1 just before)."""
    f = open(out, "w") if out else sys.stdout
    vbl = None
    for t, s, lsb, vs, d in entries(path):
        if t == 0xA:
            vbl = s
            f.write(f"{s * 1000:10.3f} VBL\n")
        elif vbl is None:
            continue
        elif t == 0xF and (d >> 28) == 6:
            f.write(f"{s * 1000:10.3f}   +{(s - vbl) * 1000:6.3f}  AF {af_text(d)}\n")
        elif t == 0xF and (d >> 28) == 3 and ((d >> 24) & 0xF) == 0xA and ((d >> 16) & 0xFF) == 0x18:
            f.write(f"{s * 1000:10.3f}   +{(s - vbl) * 1000:6.3f}  IRQ10 ack\n")


def percentile(sorted_list, p):
    """Nearest-rank percentile (p in 0..100) of a sorted list."""
    if not sorted_list:
        return 0.0
    k = int(p * len(sorted_list) + 99) // 100 - 1
    return sorted_list[max(0, min(len(sorted_list) - 1, k))]


def nearest(items, t, tol=0.002):
    """Value of the (time, value) entry closest to time t (s) within tol, or None."""
    best = None
    for s, v in items:
        if abs(s - t) <= tol and (best is None or abs(s - t) < best[0]):
            best = (abs(s - t), v)
    return best[1] if best else None


def frames(path, out=None):
    """Per field: CPU idle in VSync() (ms), GP1(05) write after the vblank (ms), first VSync() entry
    (ms before the vblank), EXP1 reads; then a summary."""
    f = open(out, "w") if out else sys.stdout
    vbl, gp1, enter, idles, exp1 = [], [], [], [], []
    for t, s, lsb, vs, d in entries(path):
        if t == 0xA:
            vbl.append(s)
        elif t == 4 and (d >> 24) == 5:
            gp1.append(s)
        elif t == 0xF and (d >> 28) == 7:
            if d & 1:
                enter.append(s)
        elif t == 0xF and (d >> 28) == 8:
            idles.append((s, (d & 0xFFFFFFF) / 67737.6))
        elif t == 0xF and (d >> 28) == 4:
            exp1.append((s, d & 0xFFFFFFF))

    f.write("     t(ms)    len   idle  n latencies (ms)                           enter-vbl  e1reads\n")
    rows = []
    for j in range(len(vbl) - 1):
        t0, t1 = vbl[j], vbl[j + 1]
        g = [x for x in gp1 if t0 <= x < t1]
        lat = [(x - t0) * 1000 for x in g]
        ent = [x for x in enter if (g[-1] if g else t0) <= x < t1]
        before = (t1 - ent[0]) * 1000 if ent else None
        idle = nearest(idles, t1)
        e1 = nearest(exp1, t1)
        rows.append((t0, (t1 - t0) * 1000, idle, lat, before, e1))
        txt = ",".join("%.2f" % x for x in lat)
        idl = "     -" if idle is None else "%6.3f" % idle
        bf = "     -" if before is None else "%6.2f" % before
        f.write(f"{t0 * 1000:10.2f} {(t1 - t0) * 1000:6.3f} {idl} {len(lat):2d} {txt:40s} {bf} "
                f"{'-' if e1 is None else e1:>8}\n")

    if not rows:
        return
    ln = sorted(r[1] for r in rows)
    f.write(f"\nfields {len(rows)}: length min {ln[0]:.3f} mean {sum(ln) / len(ln):.3f} max {ln[-1]:.3f} ms\n")

    miss = [r[0] * 1000 for r in rows if not r[3]]
    multi = [r[0] * 1000 for r in rows if len(r[3]) > 1]
    f.write(f"no GP1(05) write (missed frame): {len(miss)}" +
            "".join(" %.2f" % x for x in miss[:20]) + (" ..." if len(miss) > 20 else "") + "\n")
    f.write(f"more than one GP1(05) write: {len(multi)}" +
            "".join(" %.2f" % x for x in multi[:20]) + (" ..." if len(multi) > 20 else "") + "\n")

    idl = sorted(r[2] for r in rows if r[2] is not None)
    if idl:
        f.write(f"idle (ms): min {idl[0]:.3f} p1 {percentile(idl, 1):.3f} p5 {percentile(idl, 5):.3f} "
                f"median {percentile(idl, 50):.3f} mean {sum(idl) / len(idl):.3f} max {idl[-1]:.3f}\n")
        f.write("lowest idle (start ms, idle ms):\n")
        for r in sorted((r for r in rows if r[2] is not None), key=lambda r: r[2])[:10]:
            f.write(f"{r[0] * 1000:10.2f} {r[2]:6.3f}\n")
        f.write("idle histogram (1 ms buckets):\n")
        for b in range(17):
            if b < 16:
                n = sum(1 for x in idl if b <= x < b + 1)
                name = f"{b:2d}-{b + 1:2d}"
            else:
                n = sum(1 for x in idl if x >= 16)
                name = "  >=16"
            f.write(f"  {name} {n:5d} {'#' * min(n, 60)}\n")

    lat_all = sorted(x for r in rows for x in r[3])
    if lat_all:
        f.write(f"GP1(05) latency after vblank (ms): min {lat_all[0]:.3f} "
                f"median {percentile(lat_all, 50):.3f} max {lat_all[-1]:.3f}\n")

    if gp1:
        f.write("gpu_frametime overlay, 1 s windows from the first vblank (average of consecutive\n"
                "GP1(05) write intervals whose later write lies in the window):\n")
        t0 = vbl[0]
        for w in range(int((gp1[-1] - t0) / 1.0) + 1):
            ws, we = t0 + w, t0 + w + 1.0
            iv = [(gp1[i + 1] - gp1[i]) * 1000 for i in range(len(gp1) - 1) if ws <= gp1[i + 1] < we]
            if iv:
                f.write(f"{ws * 1000:10.2f} {int(sum(iv) / len(iv) * 100) / 100:7.2f} ms  n {len(iv):3d}\n")
            else:
                f.write(f"{ws * 1000:10.2f} FFFF      n   0\n")


def dump(path, out=None):
    f = open(out, "w") if out else sys.stdout
    for t, s, lsb, vs, d in entries(path):
        f.write(f"{s * 1000:10.4f} ms L{lsb}{'V' if vs else ' '} {NAMES.get(t, t):8s} {decode(t, d)}\n")


def fields(path, out=None):
    """One line per vblank: GP0 headers / VRAM commands / DMA2 bursts since the previous vblank,
    time of the last GP0 header after the vblank (GPU still busy with the previous field?)."""
    f = open(out, "w") if out else sys.stdout
    f.write("     t(ms)  L  hdr  stat dma2w  gp0  idle  vram-cmds(op@ms)          dma2(start ms+words)  last GP0 header (ms after previous vblank)\n")
    vram, dma, last_vbl, last_hdr, dma_start = [], [], None, None, None
    pending = None
    for t, s, lsb, vs, d in entries(path):
        if t == 1:
            last_hdr = s
            if (d >> 24) == 0x02 or 0x80 <= (d >> 24) <= 0xDF:
                vram.append(f"{d >> 24:02X}@{s * 1000:.2f}")
        elif t == 0xD:
            dma_start = s
        elif t == 0xE:
            dma.append(f"{dma_start * 1000 if dma_start is not None else 0:.2f}+{d}")
        elif t == 0xA:
            pending = (s, lsb, d >> 16, d & 0xFFFF)
        elif t == 0xB and pending:
            s0, l0, hdr, stat = pending
            spill = f"{(last_hdr - last_vbl) * 1000:.2f}" if last_vbl is not None and last_hdr and last_hdr > last_vbl else "-"
            f.write(f"{s0 * 1000:10.2f}  {l0} {hdr:5d} {stat:5d} {d >> 12:5d} {(d >> 2) & 0x3FF:4d}  {(d >> 1) & 1}/{d & 1}  "
                    f"{' '.join(vram)[:40]:40s} {' '.join(dma)[:30]:30s} {spill}\n")
            vram, dma, last_vbl, pending = [], [], s0, None
        elif t == 0xC:
            f.write(f"{s * 1000:10.2f}  GPU FIFO FULL\n")
        elif t == 0xF and (d >> 28) <= 1:
            f.write(f"{s * 1000:10.2f}  {decode(t, d)}\n")


def rombus(path, out=None):
    """One line per vblank: GP1(05) flips, EXP1 16 bit reads and ROM board wait (clk1x) since the
    previous vblank, MEM(M) bank writes, SPU IRQ acks and DMA4 (SPU stream) starts in that field."""
    f = open(out, "w") if out else sys.stdout
    f.write("     t(ms)  flip  e1reads  e1wait(clk1x)  wait/read  bankw  spuirq  dma4 starts (ms)\n")
    flips = bankw = spuirq = 0
    dma4, rd, vbl = [], None, None
    for t, s, lsb, vs, d in entries(path):
        if t == 4 and (d >> 24) == 5:
            flips += 1
        elif t == 9 and (d >> 28) == 0 and not (d & 0x200):
            spuirq += 1
        elif t == 0xF and (d >> 28) == 3 and ((d >> 24) & 0xF) == 4:
            bankw += 1
        elif t == 0xF and (d >> 28) == 2 and ((d >> 26) & 3) == 2 and (d & 0x1000000):
            dma4.append(f"{s * 1000:.2f}")
        elif t == 0xF and (d >> 28) == 4:
            rd, vbl = d & 0xFFFFFFF, s
        elif t == 0xF and (d >> 28) == 5 and rd is not None:
            w = (d & 0xFFFFFFF) / 2
            f.write(f"{vbl * 1000:10.2f}  {flips:4d}  {rd:7d}  {w:13.0f}  {w / rd if rd else 0:9.2f}  "
                    f"{bankw:5d}  {spuirq:6d}  {' '.join(dma4)}\n")
            flips = bankw = spuirq = 0
            dma4, rd = [], None


if __name__ == "__main__":
    a = sys.argv[1:]
    if not a:
        print(__doc__)
    elif a[0] == "start":
        jtag_probe(write=True)
    elif a[0] == "status":
        jtag_probe()
    elif a[0] == "fetch":
        fetch(a[1])
    elif a[0] == "dump":
        dump(a[1], a[2] if len(a) > 2 else None)
    elif a[0] == "fields":
        fields(a[1], a[2] if len(a) > 2 else None)
    elif a[0] == "rombus":
        rombus(a[1], a[2] if len(a) > 2 else None)
    elif a[0] == "drill":
        drill(a[1], a[2] if len(a) > 2 else None)
    elif a[0] == "frames":
        frames(a[1], a[2] if len(a) > 2 else None)
