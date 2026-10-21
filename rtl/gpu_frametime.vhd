-- NS10 debug: frame time overlay data (replaces the upstream fps counter).
-- NS10 games show one VRAM buffer (interlaced fields) and write GP1(05) once per game frame with the same
-- address, 0.2..3.7 ms after vblank (HW trace 2026-10-21). The upstream fps counter counted address changes
-- and always showed 0.
--   timeBCD : average GP1(05) write interval of the last 1 s window, 4 BCD digits "dd.dd" ms, x"FFFF" = no write
--   slow    : a vblank passed without the GP1(05) write the game normally does (frame missed), held 1 s
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity gpu_frametime is
   port
   (
      clk1x                : in  std_logic;
      ce                   : in  std_logic;
      reset                : in  std_logic;

      vblank               : in  std_logic;  -- irq_VBLANK (rising edge used)
      dispWrite            : in  std_logic;  -- GP1(05) write

      timeBCD              : out unsigned(15 downto 0) := (others => '1');
      slow                 : out std_logic := '0'
   );
end entity;

architecture arch of gpu_frametime is

   constant SECOND         : integer := 33868799;

   -- 10 us tick: 33868800 / 100000 = 338.688 = 42336 / 125 clocks
   signal tick_acc         : integer range 0 to 42335 := 0;
   signal elapsed          : unsigned(16 downto 0) := (others => '0');  -- 10 us since the last write, saturating
   signal sum              : unsigned(17 downto 0) := (others => '0');
   signal count            : unsigned(7 downto 0) := (others => '0');
   signal first_seen       : std_logic := '0';

   signal vbl_since        : unsigned(3 downto 0) := (others => '0');  -- vblanks since the last write
   signal kmin             : unsigned(3 downto 0) := (others => '1');  -- fewest vblanks per frame in this window
   signal kref             : unsigned(3 downto 0) := x"1";             -- normal vblanks per frame (last window)

   signal vblank_1         : std_logic := '0';
   signal sec_cnt          : integer range 0 to SECOND := 0;
   signal slow_cnt         : integer range 0 to SECOND := 0;

   -- average = sum / count (restoring division), then binary to BCD
   signal phase            : integer range 0 to 2 := 0;
   signal div_i            : integer range 0 to 17 := 0;
   signal div_n            : unsigned(17 downto 0) := (others => '0');
   signal div_d            : unsigned(7 downto 0) := (others => '0');
   signal div_r            : unsigned(8 downto 0) := (others => '0');
   signal bcd_v            : unsigned(17 downto 0) := (others => '0');
   signal bcd_stage        : integer range 0 to 3 := 3;
   signal bcd_dig          : unsigned(15 downto 0) := (others => '0');

begin

   slow <= '1' when (slow_cnt > 0) else '0';

   process (clk1x)
      variable r_v : unsigned(8 downto 0);
   begin
      if rising_edge(clk1x) then

         if (reset = '1') then

            tick_acc   <= 0;
            elapsed    <= (others => '0');
            sum        <= (others => '0');
            count      <= (others => '0');
            first_seen <= '0';
            vbl_since  <= (others => '0');
            kmin       <= (others => '1');
            kref       <= x"1";
            sec_cnt    <= 0;
            slow_cnt   <= 0;
            phase      <= 0;
            timeBCD    <= (others => '1');

         elsif (ce = '1') then

            if (tick_acc + 125 >= 42336) then
               tick_acc <= tick_acc + 125 - 42336;
               if (elapsed /= 2**17 - 1) then elapsed <= elapsed + 1; end if;
            else
               tick_acc <= tick_acc + 125;
            end if;

            if (slow_cnt > 0) then slow_cnt <= slow_cnt - 1; end if;

            vblank_1 <= vblank;
            if (vblank = '1' and vblank_1 = '0') then
               if (vbl_since /= 15) then vbl_since <= vbl_since + 1; end if;
               if (first_seen = '1' and vbl_since >= kref) then
                  slow_cnt <= SECOND;
               end if;
            end if;

            if (dispWrite = '1') then
               first_seen <= '1';
               elapsed    <= (others => '0');
               vbl_since  <= (others => '0');
               if (first_seen = '1') then
                  if (('0' & sum) + elapsed > 2**18 - 1) then sum <= (others => '1'); else sum <= sum + elapsed; end if;
                  if (count /= 255) then count <= count + 1; end if;
                  if (vbl_since < kmin) then kmin <= vbl_since; end if;
               end if;
            end if;

            -- 1 s window
            if (sec_cnt = SECOND) then
               sec_cnt <= 0;
               sum     <= (others => '0');
               count   <= (others => '0');
               kmin    <= (others => '1');
               if (count = 0) then
                  timeBCD <= (others => '1');
               else
                  if (kmin = 0) then kref <= x"1"; else kref <= kmin; end if;
                  phase <= 1;
                  div_i <= 17;
                  div_n <= sum;
                  div_d <= count;
                  div_r <= (others => '0');
               end if;
            else
               sec_cnt <= sec_cnt + 1;
            end if;

            case (phase) is
               when 0 => null;

               when 1 =>
                  r_v := div_r(7 downto 0) & div_n(div_i);
                  if (r_v >= div_d) then
                     div_r        <= r_v - div_d;
                     div_n(div_i) <= '1';
                  else
                     div_r        <= r_v;
                     div_n(div_i) <= '0';
                  end if;
                  if (div_i = 0) then
                     phase     <= 2;
                     bcd_stage <= 3;
                     bcd_dig   <= (others => '0');
                  else
                     div_i <= div_i - 1;
                  end if;

               when 2 =>
                  if (bcd_stage = 3) then
                     if (div_n > 9999) then
                        bcd_v <= to_unsigned(9999, 18);
                     else
                        bcd_v <= div_n;
                     end if;
                     bcd_stage <= 2;
                  elsif (bcd_stage = 2 and bcd_v >= 1000) then
                     bcd_v <= bcd_v - 1000; bcd_dig(15 downto 12) <= bcd_dig(15 downto 12) + 1;
                  elsif (bcd_stage = 2) then
                     bcd_stage <= 1;
                  elsif (bcd_stage = 1 and bcd_v >= 100) then
                     bcd_v <= bcd_v - 100; bcd_dig(11 downto 8) <= bcd_dig(11 downto 8) + 1;
                  elsif (bcd_stage = 1) then
                     bcd_stage <= 0;
                  elsif (bcd_v >= 10) then
                     bcd_v <= bcd_v - 10; bcd_dig(7 downto 4) <= bcd_dig(7 downto 4) + 1;
                  else
                     timeBCD <= bcd_dig(15 downto 4) & bcd_v(3 downto 0);
                     phase   <= 0;
                  end if;
            end case;

         end if;
      end if;
   end process;

end architecture;
