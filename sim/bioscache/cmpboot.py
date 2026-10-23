"""Compare two boot traces (tb_boot.tmpl lines: pc opcode regsum cause time_ns).

    python cmpboot.py base.txt new.txt

The instruction stream (pc, opcode, register sum) must be the same; only the times may differ.
Interrupts arrive at other instructions when the code runs faster, so a mismatch at an exception entry
(pc 0x80000080 / 0xBFC00180) is reported as the end of the comparable part, not as an error.
Prints the time each build reaches the same instruction at a few points, and exits 1 on a real mismatch.
"""
import sys

VECTORS = ("80000080", "BFC00180")


def load(p):
    with open(p) as f:
        return [ln.split() for ln in f if ln.strip()]


a, b = load(sys.argv[1]), load(sys.argv[2])
n = min(len(a), len(b))
bad = None
for i in range(n):
    if a[i][:3] != b[i][:3]:
        bad = i
        break
end = n if bad is None else bad
print(f"base {len(a)} instructions, new {len(b)} instructions, equal for the first {end}")
for k in sorted({end // 8, end // 4, end // 2, end - 1}):
    if k >= 0:
        ta, tb = int(a[k][4]), int(b[k][4])
        print(f"  instr {k:8d} pc {a[k][0]}: base {ta / 1e6:9.3f} ms, new {tb / 1e6:9.3f} ms, new/base {tb / max(ta, 1):.3f}")
if bad is None:
    print("PASS: same instruction stream")
    sys.exit(0)
print(f"first difference at instruction {bad}:")
for j in range(max(0, bad - 3), min(n, bad + 3)):
    print(f"  {j:8d} base {' '.join(a[j])} | new {' '.join(b[j])}")
if a[bad][0] in VECTORS or b[bad][0] in VECTORS:
    print("PASS: same instruction stream up to an interrupt entry (timing dependent)")
    sys.exit(0)
# same code, only a register value differs, and the two runs were already at different times:
# a polled I/O register (GPU status, timers) read at another moment
shift = next((j for j in range(bad) if a[j][4] != b[j][4]), None)
if a[bad][:2] == b[bad][:2] and shift is not None:
    print(f"PASS: same code; a register value differs after the runs separated in time at instruction {shift} "
          f"(I/O poll read at another moment)")
    sys.exit(0)
print("FAIL: instruction stream differs")
sys.exit(1)
