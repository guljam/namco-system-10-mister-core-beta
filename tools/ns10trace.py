"""Debug: read the EXP1/EXP3 access trace (rtl/ns10/ns10_trace.sv) over JTAG and
compare it with a MAME tap_exp1.lua trace.

    python tools/ns10trace.py read <out.txt> [skip]   # builds up to 8450096 only (TRC RAM replaced by tools/gputrace.py)
    python tools/ns10trace.py cmp <hw.txt> <mame.log> [first]
    python tools/ns10trace.py spu [clear]             # SPU per-sample timing probe "SPUT"
    python tools/ns10trace.py spu2 [clear]            # SPU transfer words / dropped samples / stash probe "SPU2"

The core must already be running on the MiSTer (loaded from the SD card); the
USB-Blaster talks to the FPGA's JTAG hub.
"""
import os
import subprocess
import sys
import tempfile
import time

STP = r"C:\intelFPGA_lite\17.0\quartus\bin64\quartus_stp.exe"
HW = r"USB-Blaster \[USB-0\]"
DEV = "@2: 5CSEBA6(.|ES)/5CSEMA6/.. (0x02D020DD)"
DEPTH = 8192


def tcl(script):
    with tempfile.NamedTemporaryFile("w", suffix=".tcl", delete=False) as f:
        f.write(script)
    try:
        r = subprocess.run([STP, "-t", f.name], capture_output=True, text=True)
    finally:
        os.unlink(f.name)
    return r.stdout


def sp_cmd(cmd):
    return f'start_insystem_source_probe -hardware_name "{HW}" -device_name "{DEV}"\n{cmd}\nend_insystem_source_probe\n'


def read(out, skip=None):
    if skip is not None:
        v = f"{skip:08X}"
        tcl(sp_cmd(f"write_source_data -instance_index 0 -value 1{v} -value_in_hex\n"
                   f"after 100\nwrite_source_data -instance_index 0 -value 0{v} -value_in_hex"))
        time.sleep(20)
    o = tcl(sp_cmd('puts "COUNT [read_probe_data -instance_index 0 -value_in_hex]"') +
            f'begin_memory_edit -hardware_name "{HW}" -device_name "{DEV}"\n'
            f'puts "MEM [read_content_from_memory -instance_index 0 -start_address 0 -word_count {DEPTH} -content_in_hex]"\n'
            'end_memory_edit\n')
    count = int(o.split("COUNT ")[1].split()[0], 16)
    mem = o.split("MEM ")[1].split()[0]
    words = [int(mem[i:i + 16], 16) for i in range(0, len(mem), 16)]
    if words[0] == 0 or (words[-1] and (words[-1] & 0x3FFFFF) < (words[0] & 0x3FFFFF)):
        words = words[::-1]     # the editor returns the highest address first
    with open(out, "w") as f:
        f.write(f"# count {count}\n")
        for w in words:
            if w == 0:
                break
            e3, wr, act = w >> 63, (w >> 62) & 1, (w >> 61) & 1
            addr, data, t = (w >> 38) & 0x7FFFFF, (w >> 22) & 0xFFFF, w & 0x3FFFFF
            bus = "IO" if e3 and wr and addr >> 21 == 3 else ("E3" if e3 else "E1")
            if bus == "IO":
                addr = 0x1F800000 | (addr & 0x3FFF)
            f.write(f"{bus} {'W' if wr else 'R'} {addr:06X} {data:04X} a={act} t={t * 1024 / 33868800:.6f}\n")
    print(f"count {count}, {len(words)} words -> {out}")


def probe(pid, clear=False):
    """Read (and optionally clear) an ns10_probe In-System Sources and Probes instance by its ID."""
    o = tcl(f'set hw "{HW}"\nset dev "{DEV}"\n'
            'foreach i [get_insystem_source_probe_instance_info -hardware_name $hw -device_name $dev] {\n'
            f' if {{[lindex $i 3] == "{pid}"}} {{ set pi [lindex $i 0] }} }}\n'
            'start_insystem_source_probe -hardware_name $hw -device_name $dev\n'
            f'puts "{pid} [read_probe_data -instance_index $pi -value_in_hex]"\n' +
            ('write_source_data -instance_index $pi -value 1\nafter 10\nwrite_source_data -instance_index $pi -value 0\n'
             if clear else '') +
            'end_insystem_source_probe\n')
    return int(o.split(f"{pid} ")[1].split()[0], 16)


def spu(clear=False):
    """SPU timing probe (rtl/spu.vhd, In-System Sources and Probes instance "SPUT")."""
    v = probe("SPUT", clear)
    print(f"overruns {v >> 48}, max cycles/sample {(v >> 36) & 0xFFF}, max RAM wait per sample: "
          f"voice {(v >> 24) & 0xFFF}, write {(v >> 12) & 0xFFF}, other ~{((v >> 4) & 0xFF) * 16}, "
          f"max stashed {v & 0xF}" + (" -- cleared" if clear else ""))


def spu2(clear=False):
    """SPU transfer probe "SPU2": transfer words and dropped samples since clear, current stash / FIFO state."""
    v = probe("SPU2", clear)
    print(f"transfer words {v >> 32}, dropped samples {(v >> 12) & 0xFFFFF}, stash now {(v >> 8) & 0xF}, "
          f"FIFO in empty {(v >> 3) & 1}, FIFO out empty {(v >> 2) & 1}, transfer mode {v & 3}" +
          (" -- cleared" if clear else ""))


def mame_bus(log):
    """MAME tap lines -> 16 bit bus accesses as the core sees them."""
    for line in open(log):
        p = line.split()
        if len(p) < 6 or p[1] not in "RW":
            continue
        a, d, m = int(p[2], 16), int(p[3], 16), int(p[4], 16)
        if 0x1F000000 <= a < 0x1F800000:
            bus, ba = "E1", a & 0x7FFFFF
        elif 0x1FA00000 <= a < 0x1FC00000:
            bus, ba = "E3", a & 0x1FFFFF
        else:
            continue
        for lane in (0, 2):
            lm = (m >> (8 * lane)) & 0xFFFF
            if lm == 0:
                continue
            off = lane + (1 if lm == 0xFF00 else 0)
            yield bus, p[1], ba + off, (d >> (8 * lane)) & 0xFFFF, lm, p[0], p[5]


def cmp(hw, log, first=0):
    hwl = [l.split() for l in open(hw) if not l.startswith("#")]
    shown = 0
    for i, (h, m) in enumerate(zip(hwl, list_from(mame_bus(log), first, len(hwl)))):
        bus, rw, a, d, lm, t, pc = m
        same = h[0] == bus and h[1] == rw and int(h[2], 16) == a
        if same and rw == "R":
            same = ((int(h[3], 16) ^ d) & lm) == 0
        if not same:
            print(f"#{first + i}: hw {' '.join(h)} | mame {bus} {rw} {a:06X} {d & lm:04X} t={t} {pc}")
            shown += 1
            if shown >= 20:
                break
    if shown == 0:
        print(f"{len(hwl)} accesses match")


def list_from(gen, first, n):
    out = []
    for i, x in enumerate(gen):
        if i >= first:
            out.append(x)
            if len(out) >= n:
                break
    return out


if __name__ == "__main__":
    if sys.argv[1] == "spu":
        spu(len(sys.argv) > 2)
    elif sys.argv[1] == "spu2":
        spu2(len(sys.argv) > 2)
    elif sys.argv[1] == "read":
        read(sys.argv[2], int(sys.argv[3], 0) if len(sys.argv) > 3 else None)
    else:
        cmp(sys.argv[2], sys.argv[3], int(sys.argv[4], 0) if len(sys.argv) > 4 else 0)
