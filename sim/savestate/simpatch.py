"""Sim copy only: the savestate saves / restores the edges of the big memories, so a round trip fits the 15 min limit.
Kept dword ranges (same in save and load, the slot layout stays the hardware one):
  SPU RAM  0-0xFFF, 0x17C00-0x187FF, 0x1F800-0x1FFFF   (on-chip capture, DDR3 part, on-chip reverb)
  VRAM     0-0xFFF, 0x3F000-0x40FFF, 0x7F000-0x7FFFF   (rows 0.., 504-519, 1016-1023: both DDR3 halves)
  RAM      0-0x3FFF, 0xFC000-0xFFFFF                   (low 64 KB, top 64 KB of the 4 MB: SS_Adr bit 19)
    python simpatch.py <savestates.vhd>"""
import sys

p = sys.argv[1]
s = open(p, newline='').read().replace('\r\n', '\n')


def rep(a, b):
    global s
    assert s.count(a) == 1, a
    s = s.replace(a, b)


rep("""   -- NS10: VRAM dword index -> DDR3 dword address""", """   -- sim: skipped dwords after the beat with this count (tb_ss.tmpl checks the kept ranges)
   function sim_skip(t : integer; c : integer) return integer is
   begin
      if (t = 14 and c = 16#1000#)  then return 16#17C00# - 16#1000#;  end if;
      if (t = 14 and c = 16#18800#) then return 16#1F800# - 16#18800#; end if;
      if (t = 15 and c = 16#1000#)  then return 16#3F000# - 16#1000#;  end if;
      if (t = 15 and c = 16#41000#) then return 16#7F000# - 16#41000#; end if;
      if (t = 16 and c = 16#4000#)  then return 16#FC000# - 16#4000#;  end if;
      return 0;
   end function;
   function sim_unit(t : integer) return integer is
   begin
      if (t = 14) then return 2; end if;   -- SPU RAM address in halfwords
      return 1;
   end function;

   -- NS10: VRAM dword index -> DDR3 dword address""")
# save
rep("""            when SAVEMEMORY_WRITE =>
               if (DDR3_busy = '0') then
                  ddr3_ADDR_save <= std_logic_vector(unsigned(ddr3_ADDR_save) + 2);
                  if (count < maxcount) then
                     state        <= SAVEMEMORY_STARTREAD;
                     count        <= count + 2;""", """            when SAVEMEMORY_WRITE =>
               if (DDR3_busy = '0') then
                  ddr3_ADDR_save <= std_logic_vector(unsigned(ddr3_ADDR_save) + 2 + sim_skip(savetype_counter, count));
                  if (count < maxcount) then
                     state        <= SAVEMEMORY_STARTREAD;
                     count        <= count + 2 + sim_skip(savetype_counter, count);
                     RAMAddrNext  <= RAMAddrNext + sim_skip(savetype_counter, count) * sim_unit(savetype_counter);""")
# load
rep("""                  ddr3_ADDR  <= std_logic_vector(unsigned(ddr3_ADDR_save) + 2);
                  if (count < maxcount) then
                     state          <= LOADMEMORY_READ;
                     count          <= count + 2;""", """                  ddr3_ADDR  <= std_logic_vector(unsigned(ddr3_ADDR_save) + 2 + sim_skip(savetype_counter, count));
                  if (count < maxcount) then
                     state          <= LOADMEMORY_READ;
                     count          <= count + 2 + sim_skip(savetype_counter, count);
                     RAMAddrNext    <= RAMAddrNext + sim_skip(savetype_counter, count) * sim_unit(savetype_counter);""")
open(p, 'w', newline='').write(s)
print(p + ": sim skip ranges")
