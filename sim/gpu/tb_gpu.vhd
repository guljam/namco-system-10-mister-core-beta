-- GPU draw-speed / regression testbench (NS10): feeds a GP0/GP1 command file (sim/gpu/gpusim.py prep),
-- VRAM preloaded from a MAME dump, DDR3 modelled as a pipelined read port with fixed latency LAT (clk2x).
-- Logs every GP0 command header with its clk2x cycle and the interlace field changes, dumps VRAM at the end.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.std_logic_textio.all;
use std.textio.all;

entity tb_gpu is
   generic
   (
      CMDFILE   : string    := "cmd.txt";
      VRAMIN    : string    := "vram_in.hex";
      VRAMOUT   : string    := "vram_out.hex";
      LOGFILE   : string    := "log.txt";
      LAT       : integer   := 14;
      FIELDLOCK : std_logic := '1'
   );
end entity;

architecture sim of tb_gpu is

   signal clk2x         : std_logic := '1';
   signal clk1x         : std_logic := '1';
   signal clkvid        : std_logic := '1';
   signal clk1xToggle   : std_logic := '0';
   signal clk1xToggle2x : std_logic := '0';
   signal clk2xIndex    : std_logic := '0';
   signal reset         : std_logic := '1';

   signal bus_addr      : unsigned(3 downto 0) := (others => '0');
   signal bus_dataWrite : std_logic_vector(31 downto 0) := (others => '0');
   signal bus_write     : std_logic := '0';

   signal dbg_gpu       : std_logic_vector(39 downto 0);
   signal dbg_perf      : std_logic_vector(36 downto 0);

   signal vram_BUSY       : std_logic := '0';
   signal vram_DOUT       : std_logic_vector(63 downto 0) := (others => '0');
   signal vram_DOUT_READY : std_logic := '0';
   signal vram_BURSTCNT   : std_logic_vector(7 downto 0);
   signal vram_ADDR       : std_logic_vector(27 downto 0);
   signal vram_DIN        : std_logic_vector(63 downto 0);
   signal vram_BE         : std_logic_vector(7 downto 0);
   signal vram_WE         : std_logic;
   signal vram_RD         : std_logic;

   signal cycle         : integer := 0;
   signal feed_done     : std_logic := '0';
   signal dump          : std_logic := '0';

begin

   clk2x  <= not clk2x  after 7381 ps;   -- 67.7376 MHz
   clkvid <= not clkvid after 9312 ps;   -- 53.693175 MHz
   reset  <= '0' after 2 us;

   process (clk2x)
   begin
      if rising_edge(clk2x) then
         clk1x <= not clk1x;
      end if;
   end process;

   process (clk1x)
   begin
      if rising_edge(clk1x) then
         clk1xToggle <= not clk1xToggle;
      end if;
   end process;

   process (clk2x)
   begin
      if rising_edge(clk2x) then
         cycle         <= cycle + 1;
         clk1xToggle2x <= clk1xToggle;
         clk2xIndex    <= '0';
         if (clk1xToggle2x = clk1xToggle) then
            clk2xIndex <= '1';
         end if;
      end if;
   end process;

   igpu : entity work.gpu
   port map
   (
      clk1x                 => clk1x,
      clk2x                 => clk2x,
      clk2xIndex            => clk2xIndex,
      clkvid                => clkvid,
      ce                    => '1',
      reset                 => reset,
      savestate_busy        => '0',
      system_paused         => '0',
      ditherOff             => '0',
      interlaced480pHack    => '0',
      REPRODUCIBLEGPUTIMING => '0',
      videoout_on           => '1',
      isPal                 => '0',
      pal60                 => '0',
      fpscountOn            => '0',
      noTexture             => '0',
      textureFilter         => "00",
      textureFilterStrength => "00",
      textureFilter2DOff    => '0',
      dither24              => '0',
      render24              => '0',
      drawSlow              => '0',
      debugmodeOn           => '0',
      syncVideoOut          => '0',
      syncInterlace         => '0',
      rotate180             => '0',
      fixedVBlank           => '0',
      vCrop                 => "00",
      hCrop                 => '0',
      oldGPU                => '0',
      Gun1CrosshairOn       => '0',
      Gun1X                 => (others => '0'),
      Gun1Y_scanlines       => (others => '0'),
      Gun1offscreen         => '0',
      Gun2CrosshairOn       => '0',
      Gun2X                 => (others => '0'),
      Gun2Y_scanlines       => (others => '0'),
      Gun2offscreen         => '0',
      cdSlow                => '0',
      errorOn               => '0',
      errorEna              => '0',
      errorCode             => (others => '0'),
      LBAOn                 => '0',
      LBAtext               => x"2020202020",   -- spaces: the overlay indexes its font even when off
      fieldLock             => FIELDLOCK,
      dbg_gpu               => dbg_gpu,
      dbg_perf              => dbg_perf,
      bus_addr              => bus_addr,
      bus_dataWrite         => bus_dataWrite,
      bus_read              => '0',
      bus_write             => bus_write,
      dmaOn                 => '0',
      DMA_GPU_waiting       => '0',
      DMA_GPU_writeEna      => '0',
      DMA_GPU_readEna       => '0',
      DMA_GPU_write         => (others => '0'),
      vram_pause            => '0',
      vram_BUSY             => vram_BUSY,
      vram_DOUT             => vram_DOUT,
      vram_DOUT_READY       => vram_DOUT_READY,
      vram_BURSTCNT         => vram_BURSTCNT,
      vram_ADDR             => vram_ADDR,
      vram_DIN              => vram_DIN,
      vram_BE               => vram_BE,
      vram_WE               => vram_WE,
      vram_RD               => vram_RD,
      loading_savestate     => '0',
      SS_reset              => '0',
      SS_DataWrite          => (others => '0'),
      SS_Adr                => (others => '0'),
      SS_wren_GPU           => '0',
      SS_wren_Timing        => '0',
      SS_rden_GPU           => '0',
      SS_rden_Timing        => '0'
   );

   -- DDR3: 2 MB VRAM (page 0x00 rows 0-511, page 0x08 rows 512-1023), reads in order, first beat LAT cycles after the command
   process
      type t_mem is array(0 to 2**18 - 1) of std_logic_vector(63 downto 0);
      type t_q   is array(0 to 63) of integer;
      variable mem    : t_mem;
      variable q_idx  : t_q;
      variable q_cnt  : t_q;
      variable q_time : t_q;
      variable q_rd   : integer := 0;
      variable q_wr   : integer := 0;
      variable beat   : integer := 0;
      variable idx    : integer;
      variable w      : std_logic_vector(63 downto 0);
      file     f      : text;
      variable l      : line;

      impure function index(a : std_logic_vector(27 downto 0)) return integer is
      begin
         if (a(27 downto 20) = x"00") then return to_integer(unsigned(a(19 downto 3)));
         elsif (a(27 downto 20) = x"08") then return 2**17 + to_integer(unsigned(a(19 downto 3)));
         else return -1; end if;
      end function;
   begin
      file_open(f, VRAMIN, read_mode);
      for i in 0 to 2**18 - 1 loop
         readline(f, l);
         hread(l, mem(i));
      end loop;
      file_close(f);

      loop
         wait until rising_edge(clk2x);
         vram_DOUT_READY <= '0';
         if (vram_RD = '1') then
            q_idx(q_wr mod 64)  := index(vram_ADDR);
            q_cnt(q_wr mod 64)  := to_integer(unsigned(vram_BURSTCNT));
            q_time(q_wr mod 64) := cycle + LAT;
            q_wr := q_wr + 1;
         end if;
         if (vram_WE = '1') then
            idx := index(vram_ADDR);
            if (idx >= 0) then
               w := mem(idx);
               for b in 0 to 7 loop
                  if (vram_BE(b) = '1') then w(b * 8 + 7 downto b * 8) := vram_DIN(b * 8 + 7 downto b * 8); end if;
               end loop;
               mem(idx) := w;
            end if;
         end if;
         if (q_rd /= q_wr and cycle >= q_time(q_rd mod 64)) then
            idx := q_idx(q_rd mod 64);
            if (idx >= 0) then vram_DOUT <= mem(idx + beat); else vram_DOUT <= (others => '0'); end if;
            vram_DOUT_READY <= '1';
            beat := beat + 1;
            if (beat = q_cnt(q_rd mod 64)) then
               beat := 0;
               q_rd := q_rd + 1;
            end if;
         end if;
         if (dump = '1') then
            file_open(f, VRAMOUT, write_mode);
            for i in 0 to 2**18 - 1 loop
               hwrite(l, mem(i));
               writeline(f, l);
            end loop;
            file_close(f);
            report "VRAM dumped" severity note;
            std.env.stop;
         end if;
      end loop;
   end process;

   -- command feed: "0 <hex>" GP0 word, "1 <hex>" GP1 word, "W <dec>" wait clk1x cycles
   process
      file     f    : text;
      variable l    : line;
      variable k    : character;
      variable sp   : character;
      variable d    : std_logic_vector(31 downto 0);
      variable n    : integer;
   begin
      wait until reset = '0';
      for i in 0 to 99 loop wait until rising_edge(clk1x); end loop;
      file_open(f, CMDFILE, read_mode);
      while not endfile(f) loop
         readline(f, l);
         read(l, k);
         read(l, sp);
         if (k = 'W') then
            read(l, n);
            for i in 1 to n loop wait until rising_edge(clk1x); end loop;
         else
            hread(l, d);
            if (k = '0') then
               while (dbg_gpu(35) = '1') loop wait until rising_edge(clk1x); end loop;
               bus_addr <= x"0";
            else
               bus_addr <= x"4";
            end if;
            bus_dataWrite <= d;
            bus_write     <= '1';
            wait until rising_edge(clk1x);
            bus_write     <= '0';
            wait until rising_edge(clk1x);
         end if;
      end loop;
      file_close(f);
      feed_done <= '1';
      wait;
   end process;

   -- log: "H <cycle> <word> <counters>" command header, "F <cycle> <lsb>" field change, "E <cycle>" all done
   -- counters (cumulative): pipeline stall cycles, texture / CLUT fetches, rect+poly line reads, pixels written
   -- "R <cycle> <x> <y> <size>" every pixel pipeline VRAM request (texture / CLUT)
   blog : block
      -- dbg_perf: port added to the sim copy of gpu.vhd (run.sh / ghdl.sh)
      alias pipe_stall is dbg_perf(1);
      alias pipe_req   is dbg_perf(2);
      alias rect_req   is dbg_perf(3);
      alias poly_req   is dbg_perf(4);
      alias pix_wr     is dbg_perf(5);
      signal pipe_size : unsigned(10 downto 0);
   begin
   pipe_size <= unsigned(dbg_perf(16 downto 6));
   process
      file     f     : text;
      variable l     : line;
      variable lsb   : std_logic := '0';
      variable idle  : integer := 0;
      variable c_stall, c_tex, c_pal, c_line, c_pix : integer := 0;
      variable req_1 : std_logic := '0';
   begin
      file_open(f, LOGFILE, write_mode);
      loop
         wait until rising_edge(clk2x);
         if (pipe_stall = '1') then c_stall := c_stall + 1; end if;
         if (pipe_req = '1' and req_1 = '0') then
            write(l, string'("R ")); write(l, cycle); write(l, string'(" ")); write(l, to_integer(unsigned(dbg_perf(26 downto 17))));
            write(l, string'(" ")); write(l, to_integer(unsigned(dbg_perf(36 downto 27)))); write(l, string'(" ")); write(l, to_integer(pipe_size));
            writeline(f, l);
            if (pipe_size = 16 or pipe_size >= 64) then c_pal := c_pal + 1; else c_tex := c_tex + 1; end if;
         end if;
         if ((rect_req = '1' or poly_req = '1') and req_1 = '0') then c_line := c_line + 1; end if;
         req_1 := pipe_req or rect_req or poly_req;
         if (pix_wr = '1') then c_pix := c_pix + 1; end if;
         if (dbg_gpu(32) = '1' and dbg_gpu(33) = '1' and dbg_gpu(31 downto 24) /= x"00") then
            write(l, string'("H ")); write(l, cycle); write(l, string'(" ")); hwrite(l, dbg_gpu(31 downto 0));
            write(l, string'(" ")); write(l, c_stall); write(l, string'(" ")); write(l, c_tex); write(l, string'(" ")); write(l, c_pal);
            write(l, string'(" ")); write(l, c_line); write(l, string'(" ")); write(l, c_pix);
            writeline(f, l);
         end if;
         if (dbg_gpu(36) /= lsb) then
            lsb := dbg_gpu(36);
            write(l, string'("F ")); write(l, cycle); write(l, string'(" ")); write(l, lsb); writeline(f, l);
         end if;
         if (feed_done = '1' and dbg_gpu(33) = '1' and dbg_gpu(38) = '1' and vram_RD = '0' and vram_WE = '0') then
            idle := idle + 1;
         else
            idle := 0;
         end if;
         if (idle = 4000) then
            write(l, string'("E ")); write(l, cycle - 4000); writeline(f, l);
            file_close(f);
            dump <= '1';
            wait;
         end if;
      end loop;
   end process;
   end block;

end architecture;
