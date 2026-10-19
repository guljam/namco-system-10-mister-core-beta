"""GPU / DMA / IRQ trace (rtl/ns10/ns10_gtrace.sv) from the MiSTer.

    python tools/gputrace.py start                 # start a 10 s trace over JTAG (or OSD "Trace GPU 10 s")
    python tools/gputrace.py status                # JTAG probe: state, beats written
    python tools/gputrace.py fetch <out.bin>       # copy the trace from DDR3 0x3A000000 (SSH + /dev/mem)
    python tools/gputrace.py dump <in.bin> [out.txt]
    python tools/gputrace.py fields <in.bin> [out.txt]   # one line per vblank

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
    return f"{d:08X}"


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
        elif t == 0xF:
            f.write(f"{s * 1000:10.2f}  {decode(t, d)}\n")


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
