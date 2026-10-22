//============================================================================
//  NS10 board testbench: config blob -> boot copy (checked against the MAME
//  BIOS image) -> MAME bus trace replay (every read checked).
//  Files from tools/ns10cfg.py tbvec: cfg.bin rom_tb.bin bios_tb.bin vec.txt
//  plusargs: +dir=<path> +max=<vectors>
//============================================================================
`timescale 1ns/1ps

module tb_ns10;

reg clk1x = 0, clk2x = 0;
always #7.38 clk2x = ~clk2x;
always @(posedge clk2x) clk1x <= ~clk1x;

reg reset = 1;

// ------------------------------------------------------------------ DDR3 model (8 beat bursts, random busy)
reg  [63:0] rom[0:8388607];
wire        ddr_busy;
wire  [7:0] ddr_burstcnt;
wire [28:0] ddr_addr;
reg  [63:0] ddr_dout;
reg         ddr_dout_ready;
wire        ddr_rd, ddr_we;
wire [63:0] ddr_din;
wire  [7:0] ddr_be;

localparam [28:0] ROM_BEAT = 29'h06A00000;

reg         rnd_busy;
always @(posedge clk2x) rnd_busy <= ($urandom % 4) == 0;
assign ddr_busy = rnd_busy;

integer     q_left = 0;
reg  [28:0] q_addr;
integer     lat = 0;
always @(posedge clk2x) begin
	ddr_dout_ready <= 0;
	if (ddr_rd && !ddr_busy) begin
		if (q_left != 0) begin $display("DDR: read while busy"); $stop; end
		q_left = ddr_burstcnt;
		q_addr = ddr_addr - ROM_BEAT;
		lat    = 6 + ($urandom % 8);
	end
	if (ddr_we && !ddr_busy) begin
		for (int b = 0; b < 8; b++)
			if (ddr_be[b]) rom[ddr_addr - ROM_BEAT][8*b +: 8] = ddr_din[8*b +: 8];
	end
	if (q_left != 0) begin
		if (lat != 0) lat = lat - 1;
		else if (($urandom % 3) != 0) begin
			ddr_dout       <= rom[q_addr];
			ddr_dout_ready <= 1;
			q_addr = q_addr + 1;
			q_left = q_left - 1;
		end
	end
end

// ------------------------------------------------------------------ DUT
reg         cfg_wr = 0;
reg   [8:0] cfg_addr;
reg  [15:0] cfg_data;

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

ns10_cfg cfg
(
	.clk(clk1x), .wr(cfg_wr), .addr(cfg_addr), .data(cfg_data),
	.board_type(board_type), .nand_count(nand_count), .data_xor(data_xor), .unscramble_map(unscramble_map),
	.dec_type(dec_type), .use_ivtab(use_ivtab), .xmask(xmask), .nlmask(nlmask), .nand_id1(nand_id1),
	.nand_stride(nand_stride), .nand_pages(nand_pages),
	.ivtab_we(ivtab_we), .ivtab_addr(ivtab_addr), .ivtab_data(ivtab_data),
	.row_we(row_we), .row_addr(row_addr), .row_data(row_data)
);

reg         e1_rd = 0, e1_wr = 0, e3_rd = 0, e3_wr = 0;
reg  [22:0] e_addr;
reg  [15:0] e_wdata;
wire [15:0] e1_rdata, e3_rdata;
wire        e1_busy;

wire        bank_rd, bank_wr;
wire [15:0] bank_off;
wire        irq10;

ns10_io io
(
	.clk(clk1x), .reset(reset),
	.rd(e3_rd), .wr(e3_wr), .addr(e_addr[20:0]), .wdata(e_wdata), .rdata(e3_rdata),
	.dip(8'h00), .in1(32'hFFFFFFFF), .irq10(irq10),
	.bank_rd(bank_rd), .bank_wr(bank_wr), .bank_off(bank_off)
);

wire        sw_we, c_active, c_busy, c_req;
wire [15:0] sw_data, c_in, c_out, us_in, us_out;

ns10_crypt crypt
(
	.clk(clk1x), .reset(reset),
	.dec_type(dec_type), .unscramble_map(unscramble_map), .data_xor(data_xor),
	.t2_xmask(xmask), .t2_nlmask(nlmask), .t2_use_ivtab(use_ivtab),
	.ivtab_we(ivtab_we), .ivtab_addr(ivtab_addr), .ivtab_data(ivtab_data),
	.row_we(row_we), .row_addr(row_addr), .row_data(row_data),
	.switch_we(sw_we), .switch_data(sw_data), .active(c_active),
	.dec_req(c_req), .dec_in(c_in), .dec_out(c_out), .busy(c_busy),
	.us_in(us_in), .us_out(us_out)
);

wire        rq_rd, rq_wr, rq_busy, rq_valid;
wire [22:0] rq_beat;
wire [63:0] rq_wdata, rq_data;
wire  [7:0] rq_be;
reg         boot_start = 0;
wire        boot_busy, bw_req;
wire [21:0] bw_addr;
wire [31:0] bw_data;
reg         bw_done = 0;

ns10_romboard board
(
	.clk(clk1x), .reset(reset),
	.board_type(board_type), .nand_count(nand_count), .nand_stride(nand_stride), .nand_pages(nand_pages), .nand_id1(nand_id1),
	.rd(e1_rd), .wr(e1_wr), .addr(e_addr), .wdata(e_wdata), .be(2'b11), .rdata(e1_rdata), .busy(e1_busy),
	.bank_rd(bank_rd), .bank_wr(bank_wr), .bank_off(bank_off),
	.crypt_switch_we(sw_we), .crypt_switch_data(sw_data), .crypt_active(c_active), .crypt_busy(c_busy),
	.crypt_req(c_req), .crypt_in(c_in), .crypt_out(c_out), .us_in(us_in), .us_out(us_out),
	.rq_rd(rq_rd), .rq_wr(rq_wr), .rq_beat(rq_beat), .rq_wdata(rq_wdata), .rq_be(rq_be),
	.rq_busy(rq_busy), .rq_valid(rq_valid), .rq_data(rq_data),
	.boot_start(boot_start), .boot_busy(boot_busy),
	.bw_req(bw_req), .bw_addr(bw_addr), .bw_data(bw_data), .bw_done(bw_done)
);

wire        cl_req, cl_we, cl_ack, cl_rvalid;
wire [28:0] cl_addr;
wire [63:0] cl_din, cl_rdata;
wire  [7:0] cl_be;

ns10_romcache cache
(
	.clk1x(clk1x), .clk2x(clk2x), .reset(reset), .inval(1'b0), .ddr_base(ROM_BEAT),
	.rq_rd(rq_rd), .rq_wr(rq_wr), .rq_beat(rq_beat), .rq_wdata(rq_wdata), .rq_be(rq_be),
	.rq_busy(rq_busy), .rd_valid(rq_valid), .rd_data(rq_data),
	.c_req(cl_req), .c_we(cl_we), .c_addr(cl_addr), .c_din(cl_din), .c_be(cl_be),
	.c_ack(cl_ack), .c_rvalid(cl_rvalid), .c_rdata(cl_rdata)
);

ns10_ddram_arb arb
(
	.clk(clk2x), .rst(reset),
	.ddr_busy(ddr_busy), .ddr_burstcnt(ddr_burstcnt), .ddr_addr(ddr_addr), .ddr_dout(ddr_dout),
	.ddr_dout_ready(ddr_dout_ready), .ddr_rd(ddr_rd), .ddr_din(ddr_din), .ddr_be(ddr_be), .ddr_we(ddr_we),
	.psx_busy(), .psx_burstcnt(8'd1), .psx_addr(29'd0), .psx_dout(), .psx_dout_ready(),
	.psx_rd(1'b0), .psx_din(64'd0), .psx_be(8'd0), .psx_we(1'b0),
	.c_req(cl_req), .c_we(cl_we), .c_addr(cl_addr), .c_din(cl_din), .c_be(cl_be),
	.c_ack(cl_ack), .c_rvalid(cl_rvalid), .c_rdata(cl_rdata)
);

// ------------------------------------------------------------------ BIOS check
reg  [31:0] bios[0:1048575];
integer     bios_bad = 0;
always @(posedge clk1x) begin
	bw_done <= 0;
	if (bw_req) begin
		if (bw_data !== bios[bw_addr[21:2]]) begin
			bios_bad = bios_bad + 1;
			if (bios_bad <= 10) $display("BIOS MISMATCH %06X got %08X want %08X", bw_addr, bw_data, bios[bw_addr[21:2]]);
		end
		bw_done <= 1;
	end
end

// ------------------------------------------------------------------ watchdog: sim time limit (+limit_ms=, default 2000 ms)
integer limit_ms;
initial begin
	if (!$value$plusargs("limit_ms=%d", limit_ms)) limit_ms = 2000;
	#(longint'(limit_ms) * 1_000_000);
	$display("TIMEOUT: sim time limit %0d ms reached", limit_ms);
	$display("FAIL");
	$finish;
end

// ------------------------------------------------------------------ stimulus
string      dir;
integer     fd, r, nvec, bad, checked, maxv;
string      rw;
reg  [31:0] a;
reg  [15:0] mk, d, got;
integer     chk, dbg;
longint     lat_sum = 0, lat_n = 0, cyc;
reg   [7:0] cb[0:'h183];

initial begin
	if (!$value$plusargs("dir=%s", dir)) dir = ".";
	if (!$value$plusargs("max=%d", maxv)) maxv = 0;
	if (!$value$plusargs("dbg=%d", dbg)) dbg = -1;

	fd = $fopen({dir, "/rom_tb.bin"}, "rb");
	r = $fread(rom, fd);
	$fclose(fd);
	$display("ROM: %0d bytes", r);

	fd = $fopen({dir, "/bios_tb.bin"}, "rb");
	r = $fread(bios, fd);
	$fclose(fd);

	fd = $fopen({dir, "/cfg.bin"}, "rb");
	r = $fread(cb, fd);
	$fclose(fd);

	repeat (10) @(posedge clk1x);
	for (int i = 0; i < 'h184; i += 2) begin
		cfg_wr   <= 1;
		cfg_addr <= i;
		cfg_data <= {cb[i + 1], cb[i]};
		@(posedge clk1x);
	end
	cfg_wr <= 0;
	repeat (4) @(posedge clk1x);
	reset <= 0;
	@(posedge clk1x);

	boot_start <= 1;
	@(posedge clk1x);
	boot_start <= 0;
	@(posedge clk1x);
	cyc = 0;
	while (boot_busy) begin
		@(posedge clk1x); cyc++;
		if (cyc > 20_000_000) begin $display("STALL: boot copy busy after %0d clk1x", cyc); $display("FAIL"); $finish; end
	end
	$display("boot copy done at %t, %0d BIOS mismatches", $time, bios_bad);

	fd = $fopen({dir, "/vec.txt"}, "r");
	nvec = 0; bad = 0; checked = 0;
	while (!$feof(fd) && (maxv == 0 || nvec < maxv)) begin
		r = $fscanf(fd, "%s %h %h %h %d\n", rw, a, mk, d, chk);
		if (r != 5) break;
		nvec++;
		e_addr  <= a[22:0];
		e_wdata <= d;
		if (a < 32'h1F800000) begin
			if (rw == "R") e1_rd <= 1; else e1_wr <= 1;
		end else begin
			if (rw == "R") e3_rd <= 1; else e3_wr <= 1;
		end
		@(posedge clk1x);
		e1_rd <= 0; e1_wr <= 0; e3_rd <= 0; e3_wr <= 0;
		@(posedge clk1x);
		cyc = 1;
		while (e1_busy) begin
			@(posedge clk1x); cyc++;
			if (cyc > 100_000) begin $display("STALL: vec %0d %s %08X busy after %0d clk1x", nvec, rw, a, cyc); $display("FAIL"); $finish; end
		end
		if (rw == "R" && a < 32'h1F800000) begin lat_sum += cyc; lat_n++; end
		if (rw == "R" && chk) begin
			got = (a < 32'h1F800000) ? e1_rdata : e3_rdata;
			checked++;
			if (((got ^ d) & mk) != 0) begin
				bad++;
				if (bad <= 20) $display("MISMATCH vec %0d: R %08X want %04X got %04X", nvec, a, d, got);
			end
		end
		if (dbg >= 0 && nvec >= dbg)
			$display("vec %0d %s %08X d=%04X got=%04X raw=%04X act=%b pc=%012X pp=%012X mask=%04X iv=%X",
				nvec, rw, a, d, got, board.raw, crypt.active, crypt.pc, crypt.pp, crypt.t2_mask, crypt.iv);
		if (nvec % 200000 == 0) $display("%0d vectors, %0d mismatches", nvec, bad);
	end
	$display("EXP1 reads %0d, clk1x from strobe to data %0d, average %0.3f", lat_n, lat_sum, real'(lat_sum) / lat_n);
	$display("RESULT: %0d vectors, %0d reads checked, %0d mismatches, %0d BIOS mismatches", nvec, checked, bad, bios_bad);
	$finish;
end

endmodule
