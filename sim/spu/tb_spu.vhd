-- SPU testbench: 24 voices playing (pitch 4x -> voice cache misses), DDR3 model with a fixed latency
-- (stands in for the GPU-pause waits of the psx_top arbiter), DMA sample upload that asks for the next
-- block only when the SPU FIFO is empty (like the core DMA). Reports per-sample load (probe "SPUT"),
-- max stash, dropped-sample events (sound_timeout) and upload progress (DDR3 writes).
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use STD.textio.all;
use work.tb_probe_pkg.all;

entity tb_spu is
   generic
   (
      LAT      : integer := 8;      -- DDR3 ack latency in clk2x cycles
      SAMPLES  : integer := 3000    -- samples with the upload running
   );
end entity;

architecture arch of tb_spu is
   constant T1 : time := 29.525 ns;   -- 33.8688 MHz

   signal clk1x, clk2x   : std_logic := '0';
   signal clk2xIndex     : std_logic := '0';
   signal clk1xToggle, clk1xToggle2x : std_logic := '0';
   signal reset          : std_logic := '1';

   signal bus_addr       : unsigned(9 downto 0) := (others => '0');
   signal bus_dataWrite  : std_logic_vector(15 downto 0) := (others => '0');
   signal bus_write      : std_logic := '0';
   signal bus_dataRead   : std_logic_vector(15 downto 0);

   signal spu_dmaRequest : std_logic;
   signal dma_write      : std_logic := '0';
   signal dma_writedata  : std_logic_vector(15 downto 0) := (others => '0');
   signal sound_timeout  : std_logic;
   signal spu_tick       : std_logic;

   signal mem_request    : std_logic;
   signal mem_BURSTCNT   : std_logic_vector(7 downto 0);
   signal mem_ADDR       : std_logic_vector(19 downto 0);
   signal mem_WE, mem_RD : std_logic;
   signal mem_DIN        : std_logic_vector(63 downto 0);
   signal mem_BE         : std_logic_vector(7 downto 0);
   signal baddata, words : integer := 0;
   signal mem_ack        : std_logic := '0';
   signal mem_DOUT_READY : std_logic := '0';

   signal writes, reads, timeouts, ticks : integer := 0;
   signal blocks         : integer := 0;
begin

   clk1x <= not clk1x after T1 / 2;
   clk2x <= not clk2x after T1 / 4;

   process (clk1x) begin if rising_edge(clk1x) then clk1xToggle <= not clk1xToggle; end if; end process;
   process (clk2x)
   begin
      if rising_edge(clk2x) then
         clk1xToggle2x <= clk1xToggle;
         clk2xIndex    <= '0';
         if (clk1xToggle2x = clk1xToggle) then clk2xIndex <= '1'; end if;
      end if;
   end process;

   idut : entity work.spu
   port map
   (
      clk1x => clk1x, clk2x => clk2x, clk2xIndex => clk2xIndex, ce => '1', reset => reset,
      SPUon => '1', SPUIRQTrigger => '0', useSDRAM => '0', REPRODUCIBLESPUIRQ => '0', REPRODUCIBLESPUDMA => '0',
      REVERBOFF => '0', cpuPaused => '0', spu_tick => spu_tick, cd_left => (others => '0'), cd_right => (others => '0'),
      irqOut => open, sound_timeout => sound_timeout, sound_out_left => open, sound_out_right => open,
      bus_addr => bus_addr, bus_dataWrite => bus_dataWrite, bus_read => '0', bus_write => bus_write, bus_dataRead => bus_dataRead,
      spu_dmaRequest => spu_dmaRequest, dma_read => '0', dma_readdata => open, dma_write => dma_write, dma_writedata => dma_writedata,
      sdram_dataWrite => open, sdram_Adr => open, sdram_be => open, sdram_rnw => open, sdram_ena => open,
      sdram_dataRead => (others => '0'), sdram_done => '0',
      mem_request => mem_request, mem_BURSTCNT => mem_BURSTCNT, mem_ADDR => mem_ADDR, mem_DIN => mem_DIN, mem_BE => mem_BE,
      mem_WE => mem_WE, mem_RD => mem_RD, mem_ack => mem_ack, mem_DOUT => (others => '0'), mem_DOUT_READY => mem_DOUT_READY,
      SS_reset => '0', loading_savestate => '0', SS_DataWrite => (others => '0'), SS_Adr => (others => '0'),
      SS_wren => '0', SS_rden => '0', SS_DataRead => open, SS_idle => open,
      SS_RAM_dataWrite => (others => '0'), SS_RAM_Adr => (others => '0'), SS_RAM_request => '0', SS_RAM_rnw => '0',
      SS_RAM_dataRead => open, SS_RAM_done => open
   );

   -- DDR3: ack after LAT clk2x, read data (zeros = endless ADPCM) one beat per clk2x after the ack
   process (clk2x)
      type t_st is (S_IDLE, S_ACK, S_DATA, S_LOW);
      variable st  : t_st := S_IDLE;
      variable cnt : integer := 0;
      variable beats : integer := 0;
      variable wi, nw, nb : integer := 0;
   begin
      if rising_edge(clk2x) then
         mem_ack        <= '0';
         mem_DOUT_READY <= '0';
         case st is
            when S_IDLE =>
               if mem_request = '1' then st := S_ACK; cnt := LAT; end if;
            when S_ACK =>
               if cnt > 0 then
                  cnt := cnt - 1;
               else
                  mem_ack <= '1';
                  if mem_WE = '1' then
                     writes <= writes + 1; st := S_LOW;
                     -- upload check: word n at 0x10000 + 2n holds n mod 64
                     for i in 0 to 3 loop
                        if mem_BE(2 * i) = '1' then
                           wi := (to_integer(unsigned(mem_ADDR)) - 16#10000#) / 2 + i;
                           nw := nw + 1;
                           if wi < 0 or to_integer(unsigned(mem_DIN(16 * i + 15 downto 16 * i))) /= wi mod 64 then nb := nb + 1; end if;
                        end if;
                     end loop;
                     words <= nw; baddata <= nb;
                  else
                     reads <= reads + 1; beats := to_integer(unsigned(mem_BURSTCNT)); st := S_DATA;
                  end if;
               end if;
            when S_DATA =>
               mem_DOUT_READY <= '1';
               beats := beats - 1;
               if beats = 0 then st := S_LOW; end if;
            when S_LOW =>
               if mem_request = '0' then st := S_IDLE; end if;
         end case;
      end if;
   end process;

   process (clk1x)
   begin
      if rising_edge(clk1x) then
         if sound_timeout = '1' then timeouts <= timeouts + 1; end if;
         if spu_tick = '1' then ticks <= ticks + 1; end if;
      end if;
   end process;

   process
      variable to_base : integer := 0;
      procedure wr(a : integer; d : integer) is
      begin
         wait until rising_edge(clk1x);
         bus_addr <= to_unsigned(a, 10); bus_dataWrite <= std_logic_vector(to_unsigned(d, 16)); bus_write <= '1';
         wait until rising_edge(clk1x);
         bus_write <= '0';
         for i in 1 to 4 loop wait until rising_edge(clk1x); end loop;
      end procedure;
      procedure samples_wait(n : integer) is
         variable t0 : integer;
      begin
         t0 := ticks;
         while ticks < t0 + n loop wait until rising_edge(clk1x); end loop;
      end procedure;
      procedure report_probe(name : string) is
         variable l : line;
      begin
         write(l, string'("LAT=") & integer'image(LAT) & " " & name &
               ": max cycles/sample " & integer'image(to_integer(unsigned(probe_sig(47 downto 36)))) &
               ", max voice wait " & integer'image(to_integer(unsigned(probe_sig(35 downto 24)))) &
               ", overruns " & integer'image(to_integer(unsigned(probe_sig(63 downto 48)))) &
               ", max stash " & integer'image(to_integer(unsigned(probe_sig(3 downto 0)))) &
               ", sound_timeout clk " & integer'image(timeouts - to_base) &
               ", DDR3 reads " & integer'image(reads) & ", writes " & integer'image(writes) &
               ", upload blocks " & integer'image(blocks) & ", words written " & integer'image(words) & " bad " & integer'image(baddata) &
               " | SPU2 xfers " & integer'image(to_integer(unsigned(probe2_sig(63 downto 32)))) &
               " drops " & integer'image(to_integer(unsigned(probe2_sig(31 downto 12)))) &
               " stash " & integer'image(to_integer(unsigned(probe2_sig(11 downto 8)))) &
               " fifoInEmpty " & std_logic'image(probe2_sig(3)));
         writeline(output, l);
      end procedure;
      variable t0 : integer;
   begin
      for i in 1 to 20 loop wait until rising_edge(clk1x); end loop;
      reset <= '0';
      for i in 1 to 20 loop wait until rising_edge(clk1x); end loop;
      wr(16#1AA#, 16#C000#);                -- SPU on, unmute
      wr(16#180#, 16#3FFF#); wr(16#182#, 16#3FFF#);
      for v in 0 to 23 loop
         wr(v * 16 + 0, 16#1000#); wr(v * 16 + 2, 16#1000#);
         wr(v * 16 + 4, 16#3FFF# - v * 16#180#);   -- pitch 4x .. 1.8x (misses spread out)
         wr(v * 16 + 6, 16#1000# + v * 16#400#);   -- start address (8 byte units)
         wr(v * 16 + 8, 16#00FF#); wr(v * 16 + 10, 16#0000#);
      end loop;
      wr(16#188#, 16#FFFF#); wr(16#18A#, 16#00FF#);   -- key on 24 voices
      samples_wait(300);
      probe_clear <= '1'; wait until rising_edge(clk1x); probe_clear <= '0';
      to_base := timeouts;
      samples_wait(500);
      report_probe("playing");

      -- DMA upload to 0x10000: mode 10, 64 words per request (FIFO empty)
      probe_clear <= '1'; wait until rising_edge(clk1x); probe_clear <= '0';
      to_base := timeouts;
      wr(16#1A6#, 16#2000#);
      wr(16#1AA#, 16#C020#);
      t0 := ticks;
      while ticks < t0 + SAMPLES loop
         wait until rising_edge(clk1x);
         if spu_dmaRequest = '1' then
            for w in 0 to 63 loop
               dma_write <= '1'; dma_writedata <= std_logic_vector(to_unsigned(w, 16));
               wait until rising_edge(clk1x);
               dma_write <= '0';
               wait until rising_edge(clk1x);
            end loop;
            blocks <= blocks + 1;
            for i in 1 to 4 loop wait until rising_edge(clk1x); end loop;
         end if;
      end loop;
      report_probe("upload");
      std.env.stop;
   end process;

end architecture;
