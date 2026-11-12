-- Video output window test (GHDL, sim/gpu/ghdl_video.sh): real GPU RTL in 512x480i, display range
-- GP1(06) X1..X2 (generics), VRAM all non-black. Models the NAMCOS10.sv video_aspect block for both
-- "Side Borders" settings and measures per line: DE width, black pixels at the left / right edge of DE,
-- non-black GPU pixels lost outside DE.
--   Keep : fixed PSX-core window (hb_start_lut / hb_end_lut), expect 563 wide (GitHub issue: 30 + 512 + 21)
--   Crop : DE = GPU hblank, expect exactly X2-X1 / 5 = 512 wide, 0 black edge pixels, 0 lost pixels
--   Cent : Keep width, window centred on the GPU drawn area, expect 563 wide, left/right black differ <= 1
-- Limits: sim time 80 ms (4 fields of 16.7 ms), stall watchdog (no ce_pix / no DE line for 2 ms) -> failure.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_video is
   generic
   (
      X1 : integer := 16#260#;
      X2 : integer := 16#C60#
   );
end entity;

architecture sim of tb_video is

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

   signal hs, vs, hbl, vbl, ce_pix, ilace : std_logic;
   signal r, g, b         : std_logic_vector(7 downto 0);
   signal hres            : std_logic_vector(2 downto 0);

   signal cycle         : integer := 0;
   signal done          : boolean := false;

   type t_lut is array(0 to 7) of integer;
   constant HB_START_LUT : t_lut := (63, 50, 36, 31, 24, 0, 0, 0);   -- NAMCOS10.sv hb_start_lut
   constant HB_END_LUT   : t_lut := (767, 613, 441, 383, 305, 0, 0, 0);

begin

   clk2x  <= not clk2x  after 7381 ps when not done;   -- 67.7376 MHz
   clkvid <= not clkvid after 9312 ps when not done;   -- 53.693175 MHz
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
      LBAtext               => x"2020202020",
      fieldLock             => '1',
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
      video_hsync           => hs,
      video_vsync           => vs,
      video_hblank          => hbl,
      video_vblank          => vbl,
      video_ce              => ce_pix,
      video_interlace       => ilace,
      video_r               => r,
      video_g               => g,
      video_b               => b,
      video_hResMode        => hres,
      loading_savestate     => '0',
      SS_reset              => '0',
      SS_DataWrite          => (others => '0'),
      SS_Adr                => (others => '0'),
      SS_wren_GPU           => '0',
      SS_wren_Timing        => '0',
      SS_rden_GPU           => '0',
      SS_rden_Timing        => '0'
   );

   -- DDR3: every read returns magenta pixels (0x7C1F), fixed latency 14 clk2x, bursts in order
   process
      type t_q is array(0 to 63) of integer;
      variable q_cnt  : t_q;
      variable q_time : t_q;
      variable q_rd   : integer := 0;
      variable q_wr   : integer := 0;
      variable beat   : integer := 0;
   begin
      loop
         wait until rising_edge(clk2x);
         vram_DOUT_READY <= '0';
         if (vram_RD = '1') then
            q_cnt(q_wr mod 64)  := to_integer(unsigned(vram_BURSTCNT));
            q_time(q_wr mod 64) := cycle + 14;
            q_wr := q_wr + 1;
         end if;
         if (q_rd /= q_wr and cycle >= q_time(q_rd mod 64)) then
            vram_DOUT       <= x"7C1F7C1F7C1F7C1F";
            vram_DOUT_READY <= '1';
            beat := beat + 1;
            if (beat = q_cnt(q_rd mod 64)) then
               beat := 0;
               q_rd := q_rd + 1;
            end if;
         end if;
      end loop;
   end process;

   -- GP1: reset, 512x480i NTSC (0x26), display range, vertical range 16..256, display start 0, display on
   process
      procedure gp1(d : std_logic_vector(31 downto 0)) is
      begin
         bus_addr      <= x"4";
         bus_dataWrite <= d;
         bus_write     <= '1';
         wait until rising_edge(clk1x);
         bus_write     <= '0';
         wait until rising_edge(clk1x);
      end procedure;
   begin
      wait until reset = '0';
      for i in 0 to 99 loop wait until rising_edge(clk1x); end loop;
      gp1(x"00000000");
      gp1(x"08000026");
      gp1(x"06" & std_logic_vector(to_unsigned(X2, 12)) & std_logic_vector(to_unsigned(X1, 12)));
      gp1(x"07040010");
      gp1(x"05000000");
      gp1(x"03000000");
      wait;
   end process;

   -- NAMCOS10.sv video_aspect model (both Side Borders settings) + per line measurement
   process
      type t_mode is record
         hb, vb, de_1 : std_logic;
         blk          : std_logic;   -- registered pixel is black
         w, lead, run : integer;     -- DE width, leading black, current black run
         lost         : integer;     -- non-black pixels outside DE (this line)
         n, nbad      : integer;     -- DE lines, lines with unexpected shape
         wmin, wmax   : integer;
         lmin, lmax, tmin, tmax, lostsum : integer;
      end record;
      type t_modes is array(0 to 2) of t_mode;   -- 0 = Keep, 1 = Crop, 2 = Keep (centred)
      variable m       : t_modes;
      variable hs_1    : std_logic := '0';
      variable h_pos   : integer := 0;
      variable vis     : std_logic;
      variable nonblk  : boolean;
      variable gpu_w   : integer := 0;   -- GPU drawn pixels this line (hblank = 0)
      variable gpu_wl  : integer := 0;
      variable fields  : integer := 0;
      variable vs_1    : std_logic := '0';
      variable idle    : integer := 0;
      variable last_de : time := 0 ns;
      variable expect  : integer;
      variable fail    : boolean := false;
      constant NAMES   : string(1 to 12) := "KeepCropCent";
      variable hbl_1   : std_logic := '1';
      variable gpu_hs, gpu_he, hw, cs : integer := 0;
   begin
      for k in 0 to 2 loop
         m(k) := (hb => '1', vb => '1', de_1 => '0', blk => '1', w => 0, lead => 0, run => 0, lost => 0, n => 0, nbad => 0,
                  wmin => 9999, wmax => 0, lmin => 9999, lmax => 0, tmin => 9999, tmax => 0, lostsum => 0);
      end loop;
      expect := (X2 - X1) / 5;
      loop
         wait until rising_edge(clkvid);
         if (now > 80 ms) then
            report "FAIL: sim time limit 80 ms" severity failure;
         end if;
         if (ce_pix = '1') then idle := 0; else idle := idle + 1; end if;
         if (idle > 100000 or (now > 5 ms and now - last_de > 2 ms)) then
            report "FAIL: stall watchdog (no ce_pix or no DE line for 2 ms)" severity failure;
         end if;

         if (ce_pix = '1') then
            nonblk := (r /= x"00" or g /= x"00" or b /= x"00");
            if (hbl = '0') then gpu_w := gpu_w + 1; end if;

            for k in 0 to 2 loop
               -- DE / pixel of the previous ce (what the registered outputs show now)
               vis := not (m(k).hb or m(k).vb);
               if (vis = '1') then
                  if (m(k).de_1 = '0') then m(k).w := 0; m(k).lead := 0; m(k).run := 0; end if;
                  m(k).w := m(k).w + 1;
                  if (m(k).blk = '1') then
                     m(k).run := m(k).run + 1;
                     if (m(k).lead = m(k).w - 1) then m(k).lead := m(k).w; end if;
                  else
                     m(k).run := 0;
                  end if;
               elsif (m(k).blk = '0') then
                  m(k).lost := m(k).lost + 1;
               end if;
               if (vis = '0' and m(k).de_1 = '1') then   -- end of a DE line
                  m(k).n := m(k).n + 1;
                  if (m(k).w < m(k).wmin) then m(k).wmin := m(k).w; end if;
                  if (m(k).w > m(k).wmax) then m(k).wmax := m(k).w; end if;
                  if (m(k).lead < m(k).lmin) then m(k).lmin := m(k).lead; end if;
                  if (m(k).lead > m(k).lmax) then m(k).lmax := m(k).lead; end if;
                  if (m(k).run < m(k).tmin) then m(k).tmin := m(k).run; end if;
                  if (m(k).run > m(k).tmax) then m(k).tmax := m(k).run; end if;
                  if (k = 1 and (m(k).w /= expect or m(k).lead /= 0 or m(k).run /= 0)) then m(k).nbad := m(k).nbad + 1; end if;
                  last_de := now;
               end if;
               m(k).de_1 := vis;
            end loop;

            -- registers of the always_ff @(posedge CLK_VIDEO) if (CE_PIXEL) block
            hw := HB_END_LUT(to_integer(unsigned(hres))) - HB_START_LUT(to_integer(unsigned(hres)));
            if (gpu_he > gpu_hs and gpu_hs + gpu_he >= hw) then cs := (gpu_hs + gpu_he - hw) / 2;
            else cs := HB_START_LUT(to_integer(unsigned(hres))); end if;
            for k in 0 to 2 loop
               m(k).vb  := vbl;
               m(k).blk := '1' when (vbl = '1' or hbl = '1' or not nonblk) else '0';
               if (k = 1) then
                  m(k).hb := hbl;
               elsif (k = 2) then
                  if (h_pos = cs)      then m(k).hb := '0'; end if;
                  if (h_pos = cs + hw) then m(k).hb := '1'; end if;
               else
                  if (h_pos = HB_START_LUT(to_integer(unsigned(hres)))) then m(k).hb := '0'; end if;
                  if (h_pos = HB_END_LUT(to_integer(unsigned(hres))))   then m(k).hb := '1'; end if;
               end if;
            end loop;
            if (vbl = '0' and hbl_1 = '1' and hbl = '0') then gpu_hs := h_pos; end if;
            if (vbl = '0' and hbl_1 = '0' and hbl = '1') then gpu_he := h_pos; end if;
            hbl_1 := hbl;
            if (hs_1 = '1' and hs = '0') then
               h_pos := 0;
               -- per line: lost pixels, GPU width
               for k in 0 to 2 loop
                  m(k).lostsum := m(k).lostsum + m(k).lost;
                  m(k).lost := 0;
               end loop;
               if (gpu_w > 0) then gpu_wl := gpu_w; end if;
               gpu_w := 0;
            else
               h_pos := h_pos + 1;
            end if;
            hs_1 := hs;
         end if;

         if (vs = '1' and vs_1 = '0') then
            fields := fields + 1;
            report "field " & integer'image(fields) & " interlace=" & std_logic'image(ilace) & " hres=" & integer'image(to_integer(unsigned(hres)))
                   & " GPU line width=" & integer'image(gpu_wl);
            if (fields = 4) then
               for k in 0 to 2 loop
                  report NAMES(k * 4 + 1 to k * 4 + 4) & ": DE lines=" & integer'image(m(k).n)
                         & " width=" & integer'image(m(k).wmin) & ".." & integer'image(m(k).wmax)
                         & " left black=" & integer'image(m(k).lmin) & ".." & integer'image(m(k).lmax)
                         & " right black=" & integer'image(m(k).tmin) & ".." & integer'image(m(k).tmax)
                         & " lost pixels=" & integer'image(m(k).lostsum);
               end loop;
               -- fields 2..3 measured (the first field may start mid-frame)
               if (m(1).nbad /= 0 or m(1).lostsum /= 0 or m(0).lostsum /= 0 or m(1).wmin /= expect or m(1).wmax /= expect
                   or m(2).lostsum /= 0 or m(2).wmin /= m(0).wmin or m(2).wmax /= m(0).wmax or m(2).lmin /= m(2).lmax or m(2).tmin /= m(2).tmax
                   or abs(m(2).lmin - m(2).tmin) > 1) then
                  fail := true;
               end if;
               if (fail) then
                  report "RESULT: FAIL (Crop expected width " & integer'image(expect) & ", bad lines=" & integer'image(m(1).nbad) & ")" severity failure;
               else
                  report "RESULT: PASS (Crop width " & integer'image(expect) & ", no black edges, no lost pixels; centred borders differ <= 1)";
               end if;
               done <= true;
               wait;
            end if;
            if (fields = 1) then   -- restart the counters after the first (partial) field
               for k in 0 to 2 loop
                  m(k).n := 0; m(k).nbad := 0; m(k).wmin := 9999; m(k).wmax := 0; m(k).lmin := 9999; m(k).lmax := 0;
                  m(k).tmin := 9999; m(k).tmax := 0; m(k).lostsum := 0;
               end loop;
            end if;
         end if;
         vs_1 := vs;
      end loop;
   end process;

end architecture;
