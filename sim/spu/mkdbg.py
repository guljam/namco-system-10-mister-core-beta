# sim debug: copy a spu.vhd and add a write log of the voice MLABs (sample number, addr, data) per clock
import sys, os
src, dst, clk = sys.argv[1], sys.argv[2], sys.argv[3]
os.makedirs(os.path.dirname(dst), exist_ok=True)
s = open(src, encoding='latin-1').read()
mon = f'''
   -- synthesis translate_off
   process ({clk})
      file f : text open write_mode is "ghdl/wlog_{clk}.txt";
      variable l : line;
      variable smp : integer := 0;
   begin
      if rising_edge({clk}) then
         if (sampleticks = 0) then smp := smp + 1; write(l, integer'image(smp) & " S " & integer'image(stashedSamples) & " " & std_logic'image(FifoIn_Empty)); writeline(f, l); end if;
         if (RamVoice_write = '1') then write(l, integer'image(smp) & " V " & integer'image(to_integer(RamVoice_addrA)) & " " & to_hstring(RamVoice_dataA)); writeline(f, l); end if;
         if (RamVoiceVolumes_write = '1') then write(l, integer'image(smp) & " O " & integer'image(to_integer(RamVoiceVolumes_addrA)) & " " & to_hstring(RamVoiceVolumes_dataA)); writeline(f, l); end if;
         if (RamVoiceRecord_write = '1') then write(l, integer'image(smp) & " R " & integer'image(to_integer(RamVoiceRecord_addrA)) & " " & to_hstring(RamVoiceRecord_dataA)); writeline(f, l); end if;
         if (ram_request = '1') then write(l, integer'image(smp) & " M " & std_logic'image(ram_rnw) & " " & to_hstring(ram_Adr) & " " & to_hstring(ram_dataWrite)); writeline(f, l); end if;
         if (ram_done = '1') then write(l, integer'image(smp) & " D " & to_hstring(ram_dataRead)); writeline(f, l); end if;
      end if;
   end process;
   -- synthesis translate_on
'''
i = s.rindex('end architecture')
s = s[:i] + mon + s[i:]
open(dst, 'w', encoding='latin-1', newline='').write(s)
