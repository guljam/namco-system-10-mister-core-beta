//============================================================================
//  Namco System 10 for MiSTer
//
//  PSX core: Copyright (C) 2019 Robert Peip, MiSTer port (C) 2019 Sorgelig
//  NS10 board (rtl/ns10): ROM boards MEM(M)/MEM(N), main board I/O
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//============================================================================
//
//  Loading (MRA):
//    ioctl index 0: ROM image -> DDR3 0x35000000 (tools/ns10cfg.py rom_image layout; the PSX
//    GPU uses 0x30000000-0x343FFFFF, savestates 0x3E000000)
//    ioctl index 1: config blob (tools/ns10cfg.py blob, rtl/ns10/ns10_cfg.sv)
//  After both, the ROM board builds the 4 MB BIOS image in SDRAM 0x800000
//  (CPU 0x1FC00000) and the CPU leaves reset.

module emu
(
	`include "sys/emu_ports.vh"
);

assign HDMI_FREEZE = 1'b0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = status[41];

assign ADC_BUS  = 'Z;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign USER_OUT = '1;

assign AUDIO_S   = 1;
assign AUDIO_MIX = status[8:7];

assign LED_USER  = rom_download | boot_busy;
assign LED_DISK  = 0;
assign LED_POWER = 0;
assign BUTTONS   = 0;
assign VGA_SCALER= 0;

assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;

wire [ 3:0] frameindex;
wire [11:0] DisplayWidth;
wire [11:0] DisplayHeight;
wire [ 9:0] DisplayOffsetX;
wire [ 8:0] DisplayOffsetY;

assign FB_BASE    = {8'h30, frameindex, DisplayOffsetY, DisplayOffsetX, 1'b0};
assign FB_EN      = video_fbmode;
assign FB_FORMAT  = video_fb24 ? 5'b00101 : 5'b01100;
assign FB_WIDTH   = DisplayWidth;
assign FB_HEIGHT  = DisplayHeight;
assign FB_STRIDE  = 14'd2048;
assign FB_FORCE_BLANK = 0;


///////////////////////  CLOCK/RESET  ///////////////////////////////////

wire pll_locked;
wire clk_1x;
wire clk_2x;
wire clk_3x;
wire clk_vid;

pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_1x),
	.outclk_1(clk_2x),
	.outclk_2(clk_3x),
	.locked(pll_locked)
);

pll2 pll2
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_vid),
   .reconfig_to_pll(reconfig_to_pll),
	.reconfig_from_pll(reconfig_from_pll)
);

wire [63:0] reconfig_to_pll;
wire [63:0] reconfig_from_pll;

pll_cfg pll_cfg
(
	.mgmt_clk(CLK_50M),
	.mgmt_reset(0),
	.mgmt_waitrequest(),
	.mgmt_read(0),
	.mgmt_readdata(),
	.mgmt_write(0),
	.mgmt_address(0),
	.mgmt_writedata(0),
	.reconfig_to_pll(reconfig_to_pll),
	.reconfig_from_pll(reconfig_from_pll)
);

wire reset_or = RESET | buttons[1] | status[0] | rom_download | cfg_download | nv_download;

////////////////////////////  HPS I/O  //////////////////////////////////

// Status Bit Map: (0..31 => "O", 32..63 => "o")
// 0         1         2         3          4         5         6          7         8         9
// 01234567890123456789012345678901 23456789012345678901234567890123 45678901234567890123456789012345
// 0123456789ABCDEFGHIJKLMNOPQRSTUV 0123456789ABCDEFGHIJKLMNOPQRSTUV
// X      XX                        XXXX     X                      X                XXXXXX  X
// 96..104: Test switch, DIP SW1
// 81..86, 89: debug build only (NS10_DEBUG, revision NAMCOS10); the release revision NAMCOS10_release
//         runs them at their defaults (Turbo High, Cache Full, Interlace Drawing PSX, Field Lock On, ROM Bus Wait MAME)

`ifdef NS10_DEBUG
localparam [0:0] DEBUG = 1;
`else
localparam [0:0] DEBUG = 0;
`endif

`include "build_id.v"
parameter CONF_STR = {
	"SYSTEM10;;",
	"-;",
	"P1,Video & Audio;",
	"P1-;",
	"P1O[33:32],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"P1O[35:34],Scale,Normal,V-Integer,Narrower HV-Integer,Wider HV-Integer;",
	"P1O[41],Deinterlacing,Weave,Bob;",
	"P1O[8:7],Stereo Mix,None,25%,50%,100%;",
	"P2,DIP Switches;",
	"P2-;",
	"P2O[96],Test,Off,On;",
	"P2O[97],SW1:1,Off,On;",
	"P2O[98],SW1:2,Off,On;",
	"P2O[99],SW1:3,Off,On;",
	"P2O[100],SW1:4,Off,On;",
	"P2O[101],SW1:5,Off,On;",
	"P2O[102],SW1:6,Off,On;",
	"P2O[103],SW1:7,Off,On;",
	"P2O[104],SW1:8,Off,On;",
	"-;",
`ifdef NS10_DEBUG
	"O[82:81],CPU Turbo,High,Medium,Low,Off;",
	"O[83],Turbo Cache (High),Full,Half;",  // Half: slight stage 13 stutter (Full scene cut glitch fixed in cpu.vhd, VSync timeout)
	"O[84],Interlace Drawing,PSX,MAME;",            // debug: MAME draws both fields (startrgn / gamshara breakage test)
	"T[85],Trace GPU 10 s;",                        // debug: rtl/ns10/ns10_gtrace.sv, tools/gputrace.py
	"O[86],Interlace Field Lock,On,Off;",           // GPU 1.5x slower than NS10: overrunning frame keeps its field (startrgn / gamshara)
	"O[89],ROM Bus Wait,MAME,PSX;",                  // PSX: EXP1 memctrl delays as on a PSX (A/B test of the mrdrilr2j scene load stutter)
`endif
	"O[64],Pause when OSD is open,Off,On;",
	"-;",
	"R0,Reset;",
	"J1,Button1,Button2,Button3,Button4,Button5,Button6,Start,Coin,Pause,Service;",
	"jn,A,B,X,Y,L,R,Start,Select,L3,R3;",
	"V,v",`BUILD_DATE
};

wire  [1:0] buttons;
wire [127:0] status;
wire        forced_scandoubler;
wire        ioctl_download;
wire [26:0] ioctl_addr;
wire [15:0] ioctl_dout;
wire        ioctl_wr;
wire  [7:0] ioctl_index;
reg         ioctl_wait = 0;
wire        ioctl_upload;
wire        nv_save_req;
wire [15:0] nv_up_data;

wire [31:0] joy;
wire [31:0] joy2;

wire [21:0] gamma_bus;
wire        DIRECT_VIDEO;

hps_io #(.CONF_STR(CONF_STR), .WIDE(1)) hps_io
(
	.clk_sys(clk_1x),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(EXT_BUS),

	.buttons(buttons),
	.forced_scandoubler(forced_scandoubler),

	.joystick_0(joy),
	.joystick_1(joy2),

	.status(status),
	.status_in(128'd0),
	.status_set(1'b0),
	.status_menumask(16'd0),
	.info_req(1'b0),

	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_wr(ioctl_wr),
	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_wait(ioctl_wait),

	.ioctl_upload(ioctl_upload),
	.ioctl_upload_req(nv_save_req),
	.ioctl_upload_index(8'd2),
	.ioctl_din(nv_up_data),

	.gamma_bus(gamma_bus),

	.direct_video(DIRECT_VIDEO)
);

wire [35:0] EXT_BUS;

hps_ext hps_ext
(
	.clk_sys(clk_1x),
	.EXT_BUS(EXT_BUS),
	.heartbeat()
);

//////////////////////////  ROM / CONFIG DOWNLOAD  //////////////////////

// MRA order: config (1), nvram (2, only if a .nvm exists), ROM (0). The ROM
// download leaves the nvram region alone when a .nvm was loaded.
reg rom_download, cfg_download, nv_download;
reg nv_loaded = 0;
always @(posedge clk_1x) begin
	rom_download <= ioctl_download & (ioctl_index == 0);
	cfg_download <= ioctl_download & (ioctl_index == 1);
	nv_download  <= ioctl_download & (ioctl_index == 2);
	if (cfg_download) nv_loaded <= 0;
	if (nv_download)  nv_loaded <= 1;
end

// ROM image / nvram into DDR3 through the ROM cache, one 64 bit beat per 4 words
reg  [63:0] dl_data;
reg  [22:0] dl_beat;
reg         dl_wr = 0;
wire [22:0] nv_base;
wire        nv_hit_dl;

always @(posedge clk_1x) begin
	dl_wr <= 0;
	if (rom_download | nv_download) begin
		if (ioctl_wr) begin
			dl_data[{ioctl_addr[2:1], 4'd0} +: 16] <= ioctl_dout;
			if (ioctl_addr[2:1] == 2'd3) begin
				dl_wr      <= ~(rom_download & nv_loaded & nv_hit_dl);
				dl_beat    <= nv_download ? nv_base + ioctl_addr[25:3] : ioctl_addr[25:3];
				ioctl_wait <= 1;
			end
		end
		if (ioctl_wait & ~dl_wr & ~rq_busy) ioctl_wait <= 0;
	end else begin
		ioctl_wait <= 0;
	end
end

// boot: BIOS image build after ROM + config are loaded
reg rom_loaded = 0, cfg_loaded = 0, need_boot = 0, boot_start = 0;
reg rom_download_1, cfg_download_1;
wire boot_busy;

always @(posedge clk_1x) begin
	rom_download_1 <= rom_download;
	cfg_download_1 <= cfg_download;
	boot_start     <= 0;
	if (rom_download_1 & ~rom_download) begin rom_loaded <= 1; need_boot <= 1; end
	if (cfg_download_1 & ~cfg_download) begin cfg_loaded <= 1; need_boot <= 1; end
	if (need_boot & rom_loaded & cfg_loaded & ~reset & ~boot_busy) begin
		boot_start <= 1;
		need_boot  <= 0;
	end
end

////////////////////////////  PAUSE and RESET  ///////////////////////////
reg paused = 0;
reg reset = 0;
reg buttonpause_1 = 0;
reg button_paused = 0;

always @(posedge clk_1x) begin
   paused <= 0;
   if (status[64] & OSD_STATUS) paused <= 1;

   buttonpause_1 <= joy[12];
   if (joy[12] & ~buttonpause_1) button_paused <= ~button_paused;
   if (button_paused) paused <= 1;

   reset <= reset_or;
end

wire [1:0] turbo = DEBUG ? ~status[82:81] : 2'b11;  // status 0 High, 1 Medium, 2 Low, 3 Off

wire cpu_reset = reset | need_boot | boot_start | boot_busy | ~(rom_loaded & cfg_loaded);

////////////////////////////  NS10 BOARD  ///////////////////////////////

wire  [1:0] board_type, dec_type;
wire  [3:0] nand_count;
wire [15:0] data_xor, xmask, nlmask, ivtab_data;
wire [63:0] unscramble_map;
wire        use_ivtab, ivtab_we, row_we;
wire  [7:0] nand_id1;
wire [25:0] nand_stride;
wire [16:0] nand_pages;
wire  [3:0] ivtab_addr;
wire  [4:0] row_addr;
wire [95:0] row_data;

ns10_cfg ns10_cfg
(
	.clk(clk_1x), .wr(cfg_download & ioctl_wr), .addr(ioctl_addr[8:0]), .data(ioctl_dout),
	.board_type(board_type), .nand_count(nand_count), .data_xor(data_xor), .unscramble_map(unscramble_map),
	.dec_type(dec_type), .use_ivtab(use_ivtab), .xmask(xmask), .nlmask(nlmask), .nand_id1(nand_id1),
	.nand_stride(nand_stride), .nand_pages(nand_pages),
	.ivtab_we(ivtab_we), .ivtab_addr(ivtab_addr), .ivtab_data(ivtab_data),
	.row_we(row_we), .row_addr(row_addr), .row_data(row_data)
);

wire [22:0] exp1_addr;
wire [15:0] exp1_dataWrite, exp1_dataRead;
wire  [1:0] exp1_be;
wire        exp1_read, exp1_write, exp1_wait;
wire [20:0] exp3_addr;
wire [15:0] exp3_dataWrite, exp3_dataRead;
wire        exp3_read, exp3_write;
wire        dbg_io_write;
wire [13:0] dbg_io_addr;
wire [15:0] dbg_io_data;
wire        irq10;

wire        bank_rd, bank_wr;
wire [15:0] bank_off;

// MAME IN1, active low
wire [31:0] in1 = ~{
	joy[13] | joy2[13],  status[96],  joy[11], joy2[11],  4'd0,
	joy2[9], joy2[8], joy2[7], 1'b0,  joy[9], joy[8], joy[7], 1'b0,
	joy2[10], joy2[6:4], joy2[3:0],
	joy[10],  joy[6:4],  joy[3:0]
};

ns10_io ns10_io
(
	.clk(clk_1x), .reset(cpu_reset),
	.rd(exp3_read), .wr(exp3_write), .addr(exp3_addr), .wdata(exp3_dataWrite), .rdata(exp3_dataRead),
	.dip({status[97], status[98], status[99], status[100], status[101], status[102], status[103], status[104]}),
	.in1(in1), .irq10(irq10),
	.bank_rd(bank_rd), .bank_wr(bank_wr), .bank_off(bank_off)
);

wire        sw_we, c_active, c_busy, c_req;
wire [15:0] sw_data, c_in, c_out, us_in, us_out;

ns10_crypt ns10_crypt
(
	.clk(clk_1x), .reset(cpu_reset),
	.dec_type(dec_type), .unscramble_map(unscramble_map), .data_xor(data_xor),
	.t2_xmask(xmask), .t2_nlmask(nlmask), .t2_use_ivtab(use_ivtab),
	.ivtab_we(ivtab_we), .ivtab_addr(ivtab_addr), .ivtab_data(ivtab_data),
	.row_we(row_we), .row_addr(row_addr), .row_data(row_data),
	.switch_we(sw_we), .switch_data(sw_data), .active(c_active),
	.dec_req(c_req), .dec_in(c_in), .dec_out(c_out), .busy(c_busy),
	.us_in(us_in), .us_out(us_out)
);

wire        rb_rd, rb_wr, rq_busy, rq_valid;
wire [22:0] rb_beat;
wire [63:0] rb_wdata, rq_data;
wire  [7:0] rb_be;
wire        bw_req;
wire [21:0] bw_addr;
wire [31:0] bw_data;
wire        sdramCh3_done;

ns10_romboard ns10_romboard
(
	.clk(clk_1x), .reset(reset),
	.board_type(board_type), .nand_count(nand_count), .nand_stride(nand_stride), .nand_pages(nand_pages), .nand_id1(nand_id1),
	.rd(exp1_read), .wr(exp1_write), .addr(exp1_addr), .wdata(exp1_dataWrite), .be(exp1_be), .rdata(exp1_dataRead), .busy(exp1_wait),
	.bank_rd(bank_rd), .bank_wr(bank_wr), .bank_off(bank_off),
	.crypt_switch_we(sw_we), .crypt_switch_data(sw_data), .crypt_active(c_active), .crypt_busy(c_busy),
	.crypt_req(c_req), .crypt_in(c_in), .crypt_out(c_out), .us_in(us_in), .us_out(us_out),
	.rq_rd(rb_rd), .rq_wr(rb_wr), .rq_beat(rb_beat), .rq_wdata(rb_wdata), .rq_be(rb_be),
	.rq_busy(rq_busy), .rq_valid(rq_valid), .rq_data(rq_data),
	.boot_start(boot_start), .boot_busy(boot_busy),
	.bw_req(bw_req), .bw_addr(bw_addr), .bw_data(bw_data), .bw_done(sdramCh3_done)
);

wire        dl_mode  = rom_download | nv_download;
wire        rq_wr    = dl_mode ? dl_wr : rb_wr;
wire [22:0] rq_beat  = dl_mode ? dl_beat : rb_beat;
wire [63:0] rq_wdata = dl_mode ? dl_data : rb_wdata;
wire  [7:0] rq_be    = dl_mode ? 8'hFF : rb_be;

// settings NVRAM: BRAM copy of the region for the HPS save
wire        nv_hit;
assign      nv_hit_dl = (ioctl_addr[25:3] >= nv_base) && (ioctl_addr[25:3] - nv_base < ((board_type == 2'd0) ? 23'h800 : 23'h840));

ns10_nvram ns10_nvram
(
	.clk(clk_1x), .board_type(board_type),
	.wr(rq_wr), .beat(rq_beat), .wdata(rq_wdata), .be(rq_be), .game(~dl_mode),
	.base(nv_base), .hit(nv_hit),
	.up_addr(ioctl_addr[14:0]), .up_data(nv_up_data),
	.save_req(nv_save_req)
);

wire        cl_req, cl_we, cl_ack, cl_rvalid;
wire [28:0] cl_addr;
wire [63:0] cl_din, cl_rdata;
wire  [7:0] cl_be;

ns10_romcache ns10_romcache
(
	.clk1x(clk_1x), .clk2x(clk_2x), .reset(1'b0), .ddr_base(29'h06A00000),
	.rq_rd(dl_mode ? 1'b0 : rb_rd),
	.rq_wr(rq_wr),
	.rq_beat(rq_beat),
	.rq_wdata(rq_wdata),
	.rq_be(rq_be),
	.rq_busy(rq_busy), .rd_valid(rq_valid), .rd_data(rq_data),
	.c_req(cl_req), .c_we(cl_we), .c_addr(cl_addr), .c_din(cl_din), .c_be(cl_be),
	.c_ack(cl_ack), .c_rvalid(cl_rvalid), .c_rdata(cl_rdata)
);

wire        psx_ddr_busy, psx_ddr_rd, psx_ddr_we, psx_ddr_dout_ready;
wire  [7:0] psx_ddr_burstcnt, psx_ddr_be;
wire [28:0] psx_ddr_addr;
wire [63:0] psx_ddr_din, psx_ddr_dout;

ns10_ddram_arb ns10_ddram_arb
(
	.clk(clk_2x), .rst(1'b0),
	.ddr_busy(DDRAM_BUSY), .ddr_burstcnt(DDRAM_BURSTCNT), .ddr_addr(DDRAM_ADDR), .ddr_dout(DDRAM_DOUT),
	.ddr_dout_ready(DDRAM_DOUT_READY), .ddr_rd(DDRAM_RD), .ddr_din(DDRAM_DIN), .ddr_be(DDRAM_BE), .ddr_we(DDRAM_WE),
	.psx_busy(psx_ddr_busy), .psx_burstcnt(psx_ddr_burstcnt), .psx_addr(psx_ddr_addr), .psx_dout(psx_ddr_dout),
	.psx_dout_ready(psx_ddr_dout_ready), .psx_rd(psx_ddr_rd), .psx_din(psx_ddr_din), .psx_be(psx_ddr_be), .psx_we(psx_ddr_we),
	.c_req(cl_req), .c_we(cl_we), .c_addr(cl_addr), .c_din(cl_din), .c_be(cl_be),
	.c_ack(cl_ack), .c_rvalid(cl_rvalid), .c_rdata(cl_rdata),
	.t_req(gt_req), .t_addr(gt_addr), .t_din(gt_din), .t_beat(gt_beat), .t_done(gt_done)
);

// debug: 10 s GPU / DMA / IRQ trace into DDR3 0x3A000000 (OSD "Trace GPU 10 s", tools/gputrace.py)
wire        gt_req, gt_done, gt_text_on;
wire [28:0] gt_addr;
wire [63:0] gt_din;
wire  [2:0] gt_beat;
wire [39:0] gt_text;
wire [39:0] dbg_gpu;
wire [43:0] dbg_bus;
wire        cache_half = DEBUG && (turbo == 2'b10 || (turbo == 2'b11 && status[83]));

`ifdef NS10_DEBUG
ns10_gtrace ns10_gtrace
(
	.clk(clk_2x),
	.dbg_gpu(dbg_gpu), .dbg_bus(dbg_bus), .trig(status[85]),
	.e1_rd(exp1_read), .e1_wait(exp1_wait), .e3_wr(exp3_write), .e3_addr(exp3_addr), .e3_data(exp3_dataWrite),
	.cfg({status[89], 10'd0, cache_half, 1'b0, status[83], turbo}),
	.t_req(gt_req), .t_addr(gt_addr), .t_din(gt_din), .t_beat(gt_beat), .t_done(gt_done),
	.text(gt_text), .text_on(gt_text_on)
);
`else
assign gt_req     = 0;
assign gt_addr    = 0;
assign gt_din     = 0;
assign gt_text    = 0;
assign gt_text_on = 0;
`endif

////////////////////////////  SYSTEM  ///////////////////////////////////

psx_mister
psx
(
   .clk1x(clk_1x),
   .clk2x(clk_2x),
   .clk3x(clk_3x),
   .clkvid(clk_vid),
   .reset(cpu_reset),
   .isPaused(),
   // commands
   .pause(paused),
   .hps_busy(0),
   .loadExe(0),
   .exe_initial_pc(0),
   .exe_initial_gp(0),
   .exe_load_address(0),
   .exe_file_size(0),
   .exe_stackpointer(0),
   .fastboot(0),
   .ram8mb(0),
   // NS10 CPU runs at 50.7456 MHz (1.5 x PSX): PSX core turbo modes as in PSX.sv, default High
   .TURBO_MEM(turbo > 0),
   .TURBO_COMP(turbo == 2'b11),
   .TURBO_CACHE(turbo[1]),
   .TURBO_CACHE50(cache_half),
   .REPRODUCIBLEGPUTIMING(0),
   .INSTANTSEEK(0),
   .FORCECDSPEED(0),
   .LIMITREADSPEED(0),
   .IGNORECDDMATIMING(0),
   .ditherOff(0),
   .interlaced480pHack(0),  // PSX heuristic, breaks mrdrilrg (2 MB VRAM, 512 line hack buffers)
   .showGunCrosshairs(0),
   .enableNeGconRumble(0),
   .fpscountOn(DEBUG), // debug: frame time (ms, GP1(05) interval) top left, red while frames are missed
   .cdslowOn(0),
   .testSeek(0),
   .pauseOnCDSlow(0),
   .errorOn(DEBUG), // debug: PSX core error overlay (EA / ED ... top left)
   .LBAOn(gt_text_on),
   .LBAtext(gt_text),
   .drawAllLines(DEBUG && status[84]),
   .fieldLock(!DEBUG || !status[86]),
   .romBusFast(!DEBUG || !status[89]),
   .PATCHSERIAL(0),
   .noTexture(0),
   .textureFilter(0),
   .textureFilterStrength(0),
   .textureFilter2DOff(0),
   .dither24(0),
   .render24(0),
   .drawSlow(0),
   .syncVideoOut(0),
   .syncInterlace(0),
   .rotate180(0),
   .fixedVBlank(0),
   .vCrop(0),
   .hCrop(0),
   .SPUon(1),
   .SPUIRQTrigger(0),
   .SPUSDRAM(0),
   .REVERBOFF(0),
   .REPRODUCIBLESPUDMA(0),
   .WIDESCREEN(0),
   .oldGPU(0),
   // NS10 busses
   .exp1_addr(exp1_addr),
   .exp1_dataWrite(exp1_dataWrite),
   .exp1_be(exp1_be),
   .exp1_read(exp1_read),
   .exp1_write(exp1_write),
   .exp1_dataRead(exp1_dataRead),
   .exp1_wait(exp1_wait),
   .exp3_addr(exp3_addr),
   .exp3_dataWrite(exp3_dataWrite),
   .exp3_read(exp3_read),
   .exp3_write(exp3_write),
   .exp3_dataRead(exp3_dataRead),
   .exp3_wait(1'b0),
   .dbg_io_write(dbg_io_write),
   .dbg_io_addr(dbg_io_addr),
   .dbg_io_data(dbg_io_data),
   .dbg_gpu(dbg_gpu),
   .dbg_bus(dbg_bus),
   .irq10(irq10),
   // RAM/BIOS interface
   .biosregion(2'b00),
   .ram_refresh(sdr_refresh),
   .ram_dataWrite(sdr_sdram_din),
   .ram_dataRead32(sdr_sdram_dout32),
   .ram_Adr(sdram_addr),
   .ram_cntDMA(sdram_cntDMA),
   .ram_be(sdram_be),
   .ram_rnw(sdram_rnw),
   .ram_ena(sdram_req),
   .ram_dma(sdram_dma),
   .ram_cache(sdram_cache),
   .ram_done(sdram_ack),
   .ram_dmafifo_adr  (sdram_dmafifo_adr),
   .ram_dmafifo_data (sdram_dmafifo_data),
   .ram_dmafifo_empty(sdram_dmafifo_empty),
   .ram_dmafifo_read (sdram_dmafifo_read),
   .cache_wr(cache_wr),
   .cache_data(cache_data),
   .cache_addr(cache_addr),
   .dma_wr(dma_wr),
   .dma_reqprocessed(dma_reqprocessed),
   .dma_data(dma_data),
   // vram/ddr3
   .DDRAM_BUSY      (psx_ddr_busy      ),
   .DDRAM_BURSTCNT  (psx_ddr_burstcnt  ),
   .DDRAM_ADDR      (psx_ddr_addr      ),
   .DDRAM_DOUT      (psx_ddr_dout      ),
   .DDRAM_DOUT_READY(psx_ddr_dout_ready),
   .DDRAM_RD        (psx_ddr_rd        ),
   .DDRAM_DIN       (psx_ddr_din       ),
   .DDRAM_BE        (psx_ddr_be        ),
   .DDRAM_WE        (psx_ddr_we        ),
   // cd
   .region          (2'b00),
   .region_out      (),
   .hasCD           (0),
   .LIDopen         (0),
   .fastCD          (0),
   .trackinfo_data  (0),
   .trackinfo_addr  (0),
   .trackinfo_write (0),
   .resetFromCD     (),
   .cd_hps_req      (),
   .cd_hps_lba      (),
   .cd_hps_ack      (0),
   .cd_hps_write    (0),
   .cd_hps_data     (0),
   // spuram
   .spuram_dataWrite(),
   .spuram_Adr      (),
   .spuram_be       (),
   .spuram_rnw      (),
   .spuram_ena      (),
   .spuram_dataRead (0),
   .spuram_done     (0),
   // memcard
   .memcard_changed (),
   .saving_memcard  (),
   .memcard1_load   (0),
   .memcard2_load   (0),
   .memcard_save    (0),
   .memcard1_mounted   (0),
   .memcard1_available (0),
   .memcard1_rd     (),
   .memcard1_wr     (),
   .memcard1_lba    (),
   .memcard1_ack    (0),
   .memcard1_write  (0),
   .memcard1_addr   (0),
   .memcard1_dataIn (0),
   .memcard1_dataOut(),
   .memcard2_mounted   (0),
   .memcard2_available (0),
   .memcard2_rd     (),
   .memcard2_wr     (),
   .memcard2_lba    (),
   .memcard2_ack    (0),
   .memcard2_write  (0),
   .memcard2_addr   (0),
   .memcard2_dataIn (0),
   .memcard2_dataOut(),
   // video
   .videoout_on     (1),
   .isPal           (0),
   .pal60           (0),
   .hsync           (hs),
   .vsync           (vs),
   .hblank          (hbl),
   .vblank          (vbl),
   .DisplayWidth    (DisplayWidth),
   .DisplayHeight   (DisplayHeight),
   .DisplayOffsetX  (DisplayOffsetX),
   .DisplayOffsetY  (DisplayOffsetY),
   .video_ce        (ce_pix),
   .video_interlace (video_interlace),
   .video_r         (r),
   .video_g         (g),
   .video_b         (b),
   .video_isPal     (video_isPal),
   .video_fbmode    (video_fbmode),
   .video_fb24      (video_fb24),
   .video_hResMode  (video_hResMode),
   .video_frameindex(frameindex),
   //Keys (no PSX pads on NS10)
   .DSAltSwitchMode(0),
   .PadPortEnable1 (0),
   .PadPortDigital1(0),
   .PadPortAnalog1 (0),
   .PadPortMouse1  (0),
   .PadPortGunCon1 (0),
   .PadPortNeGcon1 (0),
   .PadPortWheel1  (0),
   .PadPortDS1     (0),
   .PadPortJustif1 (0),
   .PadPortStick1  (0),
   .PadPortPopn1   (0),
   .PadPortEnable2 (0),
   .PadPortDigital2(0),
   .PadPortAnalog2 (0),
   .PadPortMouse2  (0),
   .PadPortGunCon2 (0),
   .PadPortNeGcon2 (0),
   .PadPortWheel2  (0),
   .PadPortDS2     (0),
   .PadPortJustif2 (0),
   .PadPortStick2  (0),
   .PadPortPopn2   (0),
   .KeyTriangle(0),
   .KeyCircle  (0),
   .KeyCross   (0),
   .KeySquare  (0),
   .KeySelect  (0),
   .KeyStart   (0),
   .KeyRight   (0),
   .KeyLeft    (0),
   .KeyUp      (0),
   .KeyDown    (0),
   .KeyR1      (0),
   .KeyR2      (0),
   .KeyR3      (0),
   .KeyL1      (0),
   .KeyL2      (0),
   .KeyL3      (0),
   .ToggleDS   (0),
   .Analog1XP1(0),
   .Analog1YP1(0),
   .Analog2XP1(0),
   .Analog2YP1(0),
   .Analog1XP2(0),
   .Analog1YP2(0),
   .Analog2XP2(0),
   .Analog2YP2(0),
   .Analog1XP3(0),
   .Analog1YP3(0),
   .Analog2XP3(0),
   .Analog2YP3(0),
   .Analog1XP4(0),
   .Analog1YP4(0),
   .Analog2XP4(0),
   .Analog2YP4(0),
   .RumbleDataP1(),
   .RumbleDataP2(),
   .RumbleDataP3(),
   .RumbleDataP4(),
   .padMode(),
   .MouseEvent(0),
   .MouseLeft(0),
   .MouseRight(0),
   .MouseX(0),
   .MouseY(0),
   .multitap(0),
   .multitapDigital(0),
   .multitapAnalog(0),
   //snac
   .snacPort1(0),
   .snacPort2(0),
   .selectedPort1Snac(),
   .selectedPort2Snac(),
   .irq10Snac(0),
   .transmitValueSnac(),
   .clk9Snac(),
   .receiveBufferSnac(0),
   .beginTransferSnac(),
   .actionNextSnac(0),
   .receiveValidSnac(0),
   .ackSnac(1),
   .snacMC(0),

   //sound
	.sound_out_left(AUDIO_L),
	.sound_out_right(AUDIO_R),
   //savestates
   .increaseSSHeaderCount (0),
   .save_state            (0),
   .load_state            (0),
   .savestate_number      (0),
   .state_loaded          (),
   .validSStates          (),
   .rewind_on             (0),
   .rewind_active         (0),
   //cheats
   .cheat_clear(0),
   .cheats_enabled(0),
   .cheat_on(0),
   .cheat_in(0),
   .cheats_active(),

   .Cheats_BusAddr(),
   .Cheats_BusRnW(),
   .Cheats_BusByteEnable(),
   .Cheats_BusWriteData(),
   .Cheats_Bus_ena(),
   .Cheats_BusReadData(),
   .Cheats_BusDone(0)
);

////////////////////////////  MEMORY  ///////////////////////////////////

wire         sdr_refresh;
wire  [31:0] sdr_sdram_din;
wire  [31:0] sdr_sdram_dout32;
wire  [24:0] sdram_addr;
wire   [1:0] sdram_cntDMA;
wire   [3:0] sdram_be;
wire         sdram_req;
wire         sdram_ack;
wire         sdram_readack;
wire         sdram_writeack;
wire         sdram_rnw;
wire         sdram_dma;
wire         sdram_cache;
wire [ 3:0]  cache_wr;
wire [31:0]  cache_data;
wire [ 7:0]  cache_addr;
wire         dma_wr;
wire         dma_reqprocessed;
wire [31:0]  dma_data;

wire  [22:0] sdram_dmafifo_adr;
wire  [31:0] sdram_dmafifo_data;
wire         sdram_dmafifo_empty;
wire         sdram_dmafifo_read;

assign sdram_ack = sdram_readack | sdram_writeack;

sdram sdram
(
   .SDRAM_DQ   (SDRAM_DQ),
   .SDRAM_A    (SDRAM_A),
   .SDRAM_DQML (SDRAM_DQML),
   .SDRAM_DQMH (SDRAM_DQMH),
   .SDRAM_BA   (SDRAM_BA),
   .SDRAM_nCS  (SDRAM_nCS),
   .SDRAM_nWE  (SDRAM_nWE),
   .SDRAM_nRAS (SDRAM_nRAS),
   .SDRAM_nCAS (SDRAM_nCAS),
   .SDRAM_CKE  (SDRAM_CKE),
   .SDRAM_CLK  (SDRAM_CLK),

   .SDRAM_EN(1),
	.init(~pll_locked),
	.clk(clk_3x),
	.clk_base(clk_1x),

	.refreshForce(sdr_refresh),

	.ch1_addr(sdram_addr),
	.ch1_din(),
	.ch1_dout(),
	.ch1_dout32(sdr_sdram_dout32),
	.ch1_req(sdram_req & sdram_rnw),
	.ch1_rnw(1'b1),
	.ch1_dma(sdram_dma),
	.ch1_cntDMA(sdram_cntDMA),
	.ch1_cache(sdram_cache),
	.ch1_ready(sdram_readack),
	.cache_wr(cache_wr),
	.cache_data(cache_data),
	.cache_addr(cache_addr),
	.dma_wr(dma_wr),
	.dma_reqprocessed(dma_reqprocessed),
	.dma_data(dma_data),

	.ch2_addr (sdram_addr),
	.ch2_din  (sdr_sdram_din),
	.ch2_dout (),
	.ch2_req  (sdram_req & ~sdram_rnw),
	.ch2_rnw  (1'b0),
	.ch2_be   (sdram_be),
	.ch2_ready(sdram_writeack),

	// BIOS image writes from the ROM board boot copy (SDRAM 0x800000 = CPU 0x1FC00000)
	.ch3_addr (27'h0800000 | bw_addr),
	.ch3_din  (bw_data),
	.ch3_dout (),
	.ch3_req  (bw_req),
	.ch3_rnw  (1'b0),
	.ch3_be   (4'b1111),
	.ch3_ready(sdramCh3_done),

	.dmafifo_adr  (sdram_dmafifo_adr),
	.dmafifo_data (sdram_dmafifo_data),
	.dmafifo_empty(sdram_dmafifo_empty),
	.dmafifo_read (sdram_dmafifo_read)
);

assign DDRAM_CLK = clk_2x;

////////////////////////////  VIDEO  ////////////////////////////////////

assign CLK_VIDEO = clk_vid;

wire hs, vs, hbl, vbl, video_interlace, video_isPal, video_fbmode, video_fb24;

wire [2:0] video_hResMode;

wire ce_pix;
wire [7:0] r,g,b;

typedef struct {
	logic [7:0] red;
	logic [7:0] green;
	logic [7:0] blue;
	logic       hs;
	logic       vs;
	logic       hb;
	logic       vb;
	logic       interlace;
} vid_info;

vid_info video_aspect;
vid_info video_gamma;

assign CE_PIXEL = ce_pix;
assign VGA_R    = video_gamma.red;
assign VGA_G    = video_gamma.green;
assign VGA_B    = video_gamma.blue;
assign VGA_VS   = video_gamma.vs;
assign VGA_HS   = video_gamma.hs;
assign VGA_DE   = ~(video_gamma.vb | video_gamma.hb);
assign VGA_F1   = video_aspect.interlace;
assign VGA_SL = 0;
logic [11:0] aspect_x, aspect_y;

wire [1:0] ar = status[33:32];
video_freak video_freak
(
	.*,
	.VGA_DE_IN(VGA_DE),
	.VGA_DE(),

	.ARX((!ar) ? aspect_x : (ar - 1'd1)),
	.ARY((!ar) ? aspect_y : 12'd0),
	.CROP_SIZE(0),
	.CROP_OFF(0),
	.SCALE(status[35:34])
);

// Res  Div Padding
// 256  10  +25
// 320  8   +32
// 368  7   +37
// 512  5   +51
// 640  4   +64

localparam reg [23:0] aspect_ratio_lut_ntsc[128] = '{
    24'h37015B, 24'h2B4113, 24'h1A10A7, 24'hEB45EF, 24'hA00411, 24'hF8365B, 24'hA31435, 24'h6A42C3,
    24'h85D381, 24'hF8F691, 24'h581257, 24'h1860A7, 24'hFD56D4, 24'h6EF303, 24'h497202, 24'hDA1601,
    24'hF8D6E6, 24'h8513B7, 24'hB014F3, 24'h3C51B5, 24'h3971A3, 24'hC02583, 24'hD09606, 24'h4E1245,
    24'hFEF776, 24'hC555D0, 24'hBD559D, 24'hE686E1, 24'hF7C771, 24'hC4F5F4, 24'h655315, 24'hB5158B,
    24'h2C015B, 24'h1750B9, 24'hC74637, 24'hF857CB, 24'h89B459, 24'h800411, 24'hC87668, 24'hA21536,
    24'hFB3820, 24'h443238, 24'hE17761, 24'hFD3856, 24'h207113, 24'h204113, 24'h3941EB, 24'hE6F7C8,
    24'h28015B, 24'hD55745, 24'hD21733, 24'hE9F810, 24'hC0A6AD, 24'h99955A, 24'hA0359D, 24'h7FF482,
    24'hD5B792, 24'hE5C82F, 24'hF558C9, 24'h35D1F0, 24'h6EF404, 24'h93155A, 24'h5BF35D, 24'h9F75DD,
    24'h6E0411, 24'h2DF1B5, 24'h44D292, 24'h1160A7, 24'hB4F6D4, 24'hD49810, 24'hD057F1, 24'h91B595,
    24'hB006C7, 24'hF959A6, 24'hE338D6, 24'hC1378D, 24'hC557C0, 24'hF579B0, 24'h7E1500, 24'hABD6D9,
    24'hFE3A2E, 24'hD3D886, 24'h54736A, 24'hFF3A5E, 24'hE19935, 24'hF42A03, 24'h356233, 24'hFEBA8B,
    24'h957637, 24'hEFAA03, 24'h43F2DA, 24'hA6F70A, 24'h20015B, 24'h24D191, 24'h72E4E9, 24'hC1E853,
    24'hDC097D, 24'hD09909, 24'hFE8B13, 24'hD5E959, 24'hFEFB31, 24'h2B81EB, 24'h8A5620, 24'h2B91F0,
    24'h2AF1EB, 24'hD3F982, 24'hED9AB4, 24'h163101, 24'h724531, 24'hDCBA12, 24'hC50907, 24'hFB7B92,
    24'h580411, 24'hFDDBC7, 24'hAA77F1, 24'hD259D7, 24'h2ED233, 24'h2431B5, 24'hC1992B, 24'h20F191,
    24'h7665A7, 24'h42D334, 24'hD09A0A, 24'hF17BAB, 24'hFFFC6B, 24'h6B653B, 24'h5153FA, 24'hFD9C73
};

logic [11:0] h_pos, v_pos, vb_pos, v_total;
logic [11:0] hb_start_lut[8];
logic [11:0] hb_end_lut[8];
logic [11:0] hb_start, hb_end;

// FIXME: this should be adjusted if hsync changes size to maintain center
assign hb_start_lut = '{12'd63,  12'd50,  12'd36,  12'd31,  12'd24,  12'd0, 12'd0, 12'd0};
assign hb_end_lut =   '{12'd767, 12'd613, 12'd441, 12'd383, 12'd305, 12'd0, 12'd0, 12'd0};

always_comb begin
	hb_start = hb_start_lut[video_hResMode];
	hb_end = hb_end_lut[video_hResMode];
end

always_ff @(posedge CLK_VIDEO) if (CE_PIXEL) begin
	logic old_vb;
	old_vb <= vbl;
	video_aspect.hs <= hs;
	video_aspect.vs <= vs;
	video_aspect.vb <= vbl;
	video_aspect.interlace <= video_interlace;
	video_aspect.red <= (vbl || hbl) ? 8'd0 : r;
	video_aspect.green <= (vbl || hbl) ? 8'd0 : g;
	video_aspect.blue <= (vbl || hbl) ? 8'd0 : b;
	{aspect_x, aspect_y} <= aspect_ratio_lut_ntsc[v_total];

	VGA_DISABLE <= 0;

	h_pos <= h_pos + 1'd1;
	if (~old_vb && vbl)
		vb_pos <= 0;

	if (video_aspect.hs && ~hs) begin
		h_pos <= 0;
		if (~vbl)
			v_pos <= v_pos + 1'd1;
		else
			vb_pos <= vb_pos + 1'd1;
	end

	if (~video_aspect.vs && vs) begin
		v_pos <= 0;

		if (v_pos < 128)
			v_total <= 6'd0;
		else if (v_pos > 255)
			v_total <= 7'd127;
		else
			v_total <= v_pos - 8'd128;
	end

	if (vb_pos > 135)
		video_aspect.vb <= 0;

	if (h_pos == hb_start)
		video_aspect.hb <= 0;
	if (h_pos == hb_end)
		video_aspect.hb <= 1;

end

assign gamma_bus[21] = 1;
gamma_corr gamma(
	.clk_sys(gamma_bus[20]),
	.clk_vid(CLK_VIDEO),
	.ce_pix(CE_PIXEL),

	.gamma_en(gamma_bus[19]),
	.gamma_wr(gamma_bus[18]),
	.gamma_wr_addr(gamma_bus[17:8]),
	.gamma_value(gamma_bus[7:0]),

	.HSync(video_aspect.hs),
	.VSync(video_aspect.vs),
	.HBlank(video_aspect.hb),
	.VBlank(video_aspect.vb),
	.RGB_in({video_aspect.red,video_aspect.green,video_aspect.blue}),

	.HSync_out(video_gamma.hs),
	.VSync_out(video_gamma.vs),
	.HBlank_out(video_gamma.hb),
	.VBlank_out(video_gamma.vb),
	.RGB_out({video_gamma.red,video_gamma.green,video_gamma.blue})
);

endmodule
