"""Generate tb_ss.vhd (psx_mister port map from <rtl>/psx_mister.vhd) and the NS10 BIOS image.

    python mktb.py tb <rtl dir> <out.vhd> [template]   # default template tb_ss.tmpl
    python mktb.py bios <game> <out.bin>        # BIOS bytes in CPU order, as the boot copy puts them in SDRAM
"""
import os
import re
import sys

CONN = {
    "clk1x": "clk1x", "clk2x": "clk2x", "clk3x": "clk3x", "clkvid": "clkvid", "reset": "reset",
    "TURBO_MEM": "TURBO_MEM", "TURBO_COMP": "TURBO_COMP", "TURBO_CACHE": "TURBO_CACHE", "TURBO_CACHE50": "TURBO_CACHE50",
    "cpuSpeed": "CPUSPEED", "fieldLock": "'1'", "SPUon": "'1'", "videoout_on": "'1'", "ackSnac": "'1'",
    "exp1_dataRead": 'x"FFFF"', "exp1_wait": "'0'", "exp3_dataRead": 'x"FFFF"', "exp3_wait": "'0'",
    "spuram_done": "'0'", "hps_busy": "'0'", "pause": "'0'",
    "save_state": "save_state", "load_state": "load_state", "savestate_number": "ss_slot", "state_loaded": "state_loaded",
    "increaseSSHeaderCount": "'0'", "ns10ss_idle": "'1'", "ns10ss_nvaddr": "NVADDR",
}
SIGNALS = ["exp1_addr", "exp1_read", "exp1_write", "exp1_dataWrite", "exp3_addr", "exp3_read", "exp3_write", "exp3_dataWrite"]


def tb(rtl, out, template=None):
    src = open(os.path.join(rtl, "psx_mister.vhd")).read()
    ent = src[src.index("entity psx_mister"):src.index("end entity")]
    ports = re.findall(r"^\s*(\w+)\s*:\s*(in|out|buffer)\s+([^;\n]+?)\s*(?::=[^;\n]*)?;?\s*(?:--.*)?$", ent, re.M)
    lines = []
    for name, d, typ in ports:
        if name in CONN:
            v = CONN[name]
        elif name in SIGNALS or name.startswith("ram_") or name.startswith("DDRAM_") or (name.startswith("ns10ss_") and name not in ("ns10ss_idle", "ns10ss_nvaddr")) or name in (
                "cache_wr", "cache_data", "cache_addr", "dma_wr", "dma_reqprocessed", "dma_data"):
            v = name
        elif d in ("out", "buffer"):
            v = "open"
        else:
            t = typ.lower()
            if t.startswith(("std_logic_vector", "unsigned", "signed")):
                v = "(others => '0')"
            elif t.startswith("std_logic"):
                v = "'0'"
            elif t.startswith("integer"):
                v = "0"
            else:
                raise ValueError(name + " " + typ)
        lines.append(f"      {name:22s} => {v},")
    lines[-1] = lines[-1].rstrip(",")
    tmpl = open(template or os.path.join(os.path.dirname(os.path.abspath(__file__)), "tb_ss.tmpl")).read()
    open(out, "w").write(tmpl.replace("@PORTMAP@", "\n".join(lines)))


def bios(game, out):
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "tools"))
    import ns10cfg
    import ns10model as m
    g = ns10cfg.GAMES[game]
    board = ns10cfg.make_board(game, "none")
    if g["board"] == 1:
        b = m.memn_bios(board.nands[0].data, g["order"], g["data_xor"])
    else:
        b = m.memm_bios(board.flash.data, g["order"])
    open(out, "wb").write(bytes(b))
    print(f"{out}: {len(b)} bytes")


if __name__ == "__main__":
    {"tb": tb, "bios": bios}[sys.argv[1]](*sys.argv[2:])
