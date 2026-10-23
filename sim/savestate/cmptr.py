"""Compare the instruction trace after the save (A) with the one after the restore (B).
Register sums from the first line; PC / opcode from line 4: the CPU's export-only pipeline registers (pcOld2..4,
opcode3 / 4, synthesis translate_off) are not part of the upstream savestate, the first 3 exports after a restore
show their old values."""
import sys

a = [l.split()[:3] for l in open(sys.argv[1])]
b = [l.split()[:3] for l in open(sys.argv[2])]
n = min(len(a), len(b))
d = next((i for i in range(n) if a[i][2] != b[i][2] or (i >= 3 and a[i][:2] != b[i][:2])), None)
print(f"trace A {len(a)} / B {len(b)}: " + ("identical" if d is None else f"first difference at {d}: {a[d]} | {b[d]}"))
