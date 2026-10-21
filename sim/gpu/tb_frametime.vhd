-- gpu_frametime unit test (GHDL): 59.94 Hz vblank, GP1(05) 0.2 / 2.6 ms after vblank like HW
--   0..2.5 s 60 fps, 2.5 s one frame missed, 4.0..7.5 s 30 fps, 7.5 s on no writes
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity tb_frametime is
end entity;

architecture arch of tb_frametime is
   constant T     : time := 1 sec / 33868800;
   signal clk1x   : std_logic := '0';
   signal vblank  : std_logic := '0';
   signal wr      : std_logic := '0';
   signal bcd     : unsigned(15 downto 0);
   signal slow    : std_logic;
   signal done    : boolean := false;

   function tstr(v : time) return string is begin return integer'image(v / 100 us) & "00us"; end function;
begin
   clk1x <= not clk1x after T / 2 when not done;

   idut : entity work.gpu_frametime
   port map (clk1x => clk1x, ce => '1', reset => '0', vblank => vblank, dispWrite => wr, timeBCD => bcd, slow => slow);

   process
      variable n : integer := 0;
      variable t0 : time;
   begin
      while now < 9.1 sec loop
         t0 := now;
         -- vblank pulse (several clocks wide like irq_VBLANK may be)
         wait until rising_edge(clk1x); vblank <= '1';
         for i in 1 to 3 loop wait until rising_edge(clk1x); end loop;
         vblank <= '0';
         if (n mod 2 = 0) then wait for 0.2 ms; else wait for 2.6 ms; end if;
         wait until rising_edge(clk1x);
         if (now < 2.5 sec or now > 2.52 sec) and (now < 4.0 sec or n mod 2 = 0) and now < 7.5 sec then
            wr <= '1'; wait until rising_edge(clk1x); wr <= '0';
         end if;
         n := n + 1;
         wait for (t0 + 1 sec / 59.94) - now;
      end loop;
      done <= true;
      wait;
   end process;

   process (bcd, slow)
   begin
      report "t=" & tstr(now) & " time " & integer'image(to_integer(bcd(15 downto 12))) & integer'image(to_integer(bcd(11 downto 8))) & "." &
         integer'image(to_integer(bcd(7 downto 4))) & integer'image(to_integer(bcd(3 downto 0))) & " slow " & std_logic'image(slow);
   end process;
end architecture;
