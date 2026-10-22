//============================================================================
//  DDR3 fast load: settings region rebuild (ns10_nvload) testbench.
//
//  Per board type (MEM(M) / MEM(N)) and with / without a .nvm:
//   1. ROM image region = pattern A, read through the ROM cache (lines cached)
//   2. DDR3 rewritten behind the cache (Main_MiSTer fast load) = pattern C,
//      .nvm staging area = pattern B, ROM cache inval pulse (rom_end)
//   3. ns10_nvload from staging (.nvm) or from the region itself
//   4. check: DDR3 region and the ns10_nvram BRAM (HPS save port) hold B / C,
//      no save request, nothing outside the region written
//  plusargs: +noinval (no inval pulse: the stale-line check must then fail)
//============================================================================
`timescale 1ns/1ps

module tb_nvload;

reg clk1x = 0, clk2x = 0;
always #7.38 clk2x = ~clk2x;
always @(posedge clk2x) clk1x <= ~clk1x;

// ------------------------------------------------------------------ DDR3 model (as tb_ns10)
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
localparam [22:0] NV_STAGE = 23'h7F0000;

reg         rnd_busy;
always @(posedge clk2x) rnd_busy <= ($urandom % 4) == 0;
assign ddr_busy = rnd_busy;

integer     q_left = 0;
reg  [28:0] q_addr;
integer     lat = 0;
integer     wr_outside = 0;
reg  [22:0] reg_lo, reg_hi;
always @(posedge clk2x) begin
	ddr_dout_ready <= 0;
	if (ddr_rd && !ddr_busy) begin
		q_left = ddr_burstcnt;
		q_addr = ddr_addr - ROM_BEAT;
		lat    = 6 + ($urandom % 8);
	end
	if (ddr_we && !ddr_busy) begin
		if ((ddr_addr - ROM_BEAT) < reg_lo || (ddr_addr - ROM_BEAT) >= reg_hi) wr_outside = wr_outside + 1;
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
reg arb_rst = 1;                 // arbiter registers have no initial values in simulation (FPGA: power-up 0)
initial begin repeat (8) @(posedge clk2x); arb_rst <= 0; end

reg   [1:0] board_type = 0;
reg         nv_loaded = 0;
reg         nvl_start = 0, inval = 0;
wire        nvl_busy, nvl_rd, nvl_wr;
wire [22:0] nvl_beat, nv_base;
wire [63:0] nvl_wdata;
wire        rq_busy, rq_valid;
wire [63:0] rq_data;

ns10_nvload nvl
(
	.clk(clk1x), .start(nvl_start),
	.src(nv_loaded ? NV_STAGE : nv_base), .dst(nv_base), .count((board_type == 2'd0) ? 12'h800 : 12'h840),
	.busy(nvl_busy),
	.rq_rd(nvl_rd), .rq_wr(nvl_wr), .rq_beat(nvl_beat), .rq_wdata(nvl_wdata),
	.rq_busy(rq_busy), .rq_valid(rq_valid), .rq_data(rq_data)
);

// testbench requester (cache warm-up reads), muxed like the ROM board in NAMCOS10.sv
reg         t_rd = 0;
reg  [22:0] t_beat;
wire        nvl_mode = nvl_start | nvl_busy;
wire        rq_rd    = nvl_mode ? nvl_rd : t_rd;
wire        rq_wr    = nvl_mode ? nvl_wr : 1'b0;
wire [22:0] rq_beat  = nvl_mode ? nvl_beat : t_beat;
wire [63:0] rq_wdata = nvl_wdata;

wire        nv_hit, save_req;
reg  [14:0] up_addr = 0;
wire [15:0] up_data;

ns10_nvram nvram
(
	.clk(clk1x), .board_type(board_type),
	.wr(rq_wr), .beat(rq_beat), .wdata(rq_wdata), .be(8'hFF), .game(~nvl_mode),
	.base(nv_base), .hit(nv_hit),
	.up_addr(up_addr), .up_data(up_data),
	.save_req(save_req)
);

wire        cl_req, cl_we, cl_ack, cl_rvalid;
wire [28:0] cl_addr;
wire [63:0] cl_din, cl_rdata;
wire  [7:0] cl_be;

ns10_romcache cache
(
	.clk1x(clk1x), .clk2x(clk2x), .reset(arb_rst), .inval(inval), .ddr_base(ROM_BEAT),
	.rq_rd(rq_rd), .rq_wr(rq_wr), .rq_beat(rq_beat), .rq_wdata(rq_wdata), .rq_be(8'hFF),
	.rq_busy(rq_busy), .rd_valid(rq_valid), .rd_data(rq_data),
	.c_req(cl_req), .c_we(cl_we), .c_addr(cl_addr), .c_din(cl_din), .c_be(cl_be),
	.c_ack(cl_ack), .c_rvalid(cl_rvalid), .c_rdata(cl_rdata)
);

ns10_ddram_arb arb
(
	.clk(clk2x), .rst(arb_rst),
	.ddr_busy(ddr_busy), .ddr_burstcnt(ddr_burstcnt), .ddr_addr(ddr_addr), .ddr_dout(ddr_dout),
	.ddr_dout_ready(ddr_dout_ready), .ddr_rd(ddr_rd), .ddr_din(ddr_din), .ddr_be(ddr_be), .ddr_we(ddr_we),
	.psx_busy(), .psx_burstcnt(8'd1), .psx_addr(29'd0), .psx_dout(), .psx_dout_ready(),
	.psx_rd(1'b0), .psx_din(64'd0), .psx_be(8'd0), .psx_we(1'b0),
	.c_req(cl_req), .c_we(cl_we), .c_addr(cl_addr), .c_din(cl_din), .c_be(cl_be),
	.c_ack(cl_ack), .c_rvalid(cl_rvalid), .c_rdata(cl_rdata),
	.t_req(1'b0), .t_addr(29'd0), .t_din(64'd0), .t_beat(), .t_done()
);

integer saves = 0;
always @(posedge clk1x) if (save_req) saves = saves + 1;

// rd_valid is a one-clock pulse: latch it for the stimulus
reg got_valid = 0;
reg clr_valid = 0;
always @(posedge clk1x) begin
	if (rq_valid) got_valid <= 1;
	else if (clr_valid) got_valid <= 0;
end

// ------------------------------------------------------------------ watchdogs
// sim time limit (whole run needs well under 20 ms) and a stall limit for every wait loop
localparam longint SIM_LIMIT_NS = 64'd50_000_000;
initial begin
	#(SIM_LIMIT_NS);
	$display("TIMEOUT: sim time limit %0d ns reached (nvl_busy %b, rq_busy %b)", SIM_LIMIT_NS, nvl_busy, rq_busy);
	$display("FAIL");
	$finish;
end

task automatic wait_until(input string what, input int max_clk, ref logic cond);
	int n = 0;
	while (!cond) begin
		@(posedge clk1x);
		n++;
		if (n > max_clk) begin
			$display("STALL: %s not seen after %0d clocks at %0t (nvl_busy %b, rq_busy %b, cache state %0d pending %b c_req %b c_ack %b, q_left %0d)",
				what, max_clk, $time, nvl_busy, rq_busy, cache.state, cache.pending, cl_req, cl_ack, q_left);
			$display("FAIL");
			$finish;
		end
	end
endtask

// ------------------------------------------------------------------ patterns
function [63:0] pat(input [7:0] p, input [22:0] i);
	pat = {p, i[22:0], 1'b0, ~i[22:0], ~p} ^ {8{p}};
endfunction

logic   rq_idle, nvl_idle;
assign  rq_idle  = ~rq_busy;
assign  nvl_idle = ~nvl_busy;
reg  [63:0] rd_hold;
always @(posedge clk1x) if (rq_valid) rd_hold <= rq_data;

integer fails = 0;
bit     noinval;

task automatic run_case(input [1:0] bt, input bit nvm);
	reg  [22:0] base, size;
	reg  [63:0] want, q;
	integer     bad_ddr, bad_bram, t0;
	board_type = bt;
	nv_loaded  = nvm;
	@(posedge clk1x);
	base = nv_base;
	size = (bt == 0) ? 23'h800 : 23'h840;
	reg_lo = base; reg_hi = base + size;

	// 1. pattern A in the region (and one line either side), warm the cache on the first lines
	for (int i = -8; i < int'(size) + 8; i++) rom[base + i] = pat(8'hA0, base + i);
	for (int i = 0; i < 16; i++) begin
		repeat (4) @(posedge clk1x);
		wait_until("cache idle", 10000, rq_idle);
		clr_valid <= 1; t_rd <= 1; t_beat <= base + i;
		@(posedge clk1x); clr_valid <= 0; t_rd <= 0;
		@(posedge clk1x);                // got_valid clear has landed
		wait_until($sformatf("warm-up rd_valid %0d", i), 10000, got_valid);
		if (rd_hold !== pat(8'hA0, base + i)) begin $display("warm-up read wrong at %06X", base + i); fails++; end
	end
	repeat (100) @(posedge clk1x);   // prefetch done
	$display("  cached after warm-up: line %05X v%b, line %05X v%b (region lines %05X..)",
		cache.tag[0], cache.tvalid[0], cache.tag[1], cache.tvalid[1], base[22:3]);

	// 2. fast load behind the cache: region = C, staging = B
	for (int i = 0; i < int'(size); i++) begin
		rom[base + i]     = pat(8'hC0, base + i);
		rom[NV_STAGE + i] = pat(8'hB0, i);
	end
	if (!noinval) begin
		@(posedge clk1x); inval <= 1;
		@(posedge clk1x); inval <= 0;
	end

	// stale line check: beat 8 (line 1, cached with A) must now read C
	repeat (4) @(posedge clk1x);
	wait_until("cache idle", 10000, rq_idle);
	clr_valid <= 1; t_rd <= 1; t_beat <= base + 8;
	@(posedge clk1x); clr_valid <= 0; t_rd <= 0;
	@(posedge clk1x);
	wait_until("stale check rd_valid", 10000, got_valid);
	if (rd_hold !== pat(8'hC0, base + 8)) begin
		$display("  STALE: beat %06X read %016X (old ROM data) after the fast load", base + 8, rd_hold);
		fails++;
	end
	repeat (100) @(posedge clk1x);

	// 3. rebuild
	saves = 0; wr_outside = 0;
	@(posedge clk1x); nvl_start <= 1;
	@(posedge clk1x); nvl_start <= 0;
	t0 = $time;
	@(posedge clk1x);
	wait_until("nvload done", 2_000_000, nvl_idle);
	repeat (100) @(posedge clk1x);   // last write reaches DDR3

	// 4. checks
	bad_ddr = 0; bad_bram = 0;
	for (int i = 0; i < int'(size); i++) begin
		want = nvm ? pat(8'hB0, i) : pat(8'hC0, base + i);
		if (rom[base + i] !== want) begin
			if (bad_ddr < 4) $display("  DDR3 %06X got %016X want %016X", base + i, rom[base + i], want);
			bad_ddr++;
		end
		for (int w = 0; w < 4; w++) begin
			up_addr <= {i[11:0], w[1:0], 1'b0};
			repeat (3) @(posedge clk1x);
			if (up_data !== want[16*w +: 16]) begin
				if (bad_bram < 4) $display("  BRAM beat %03X word %0d got %04X want %04X", i, w, up_data, want[16*w +: 16]);
				bad_bram++;
			end
		end
	end
	if (rom[base - 1] !== pat(8'hA0, base - 1) || rom[base + size] !== pat(8'hA0, base + size)) begin
		$display("  neighbour beats changed"); bad_ddr++;
	end
	$display("board %0d nvm %0d: %0d beats in %0d us, DDR3 bad %0d, BRAM bad %0d, save_req %0d, writes outside %0d",
		bt, nvm, size, ($time - t0) / 1000, bad_ddr, bad_bram, saves, wr_outside);
	if (bad_ddr || bad_bram || saves || wr_outside) fails++;
endtask

initial begin
	noinval = $test$plusargs("noinval");
	repeat (20) @(posedge clk1x);
	$display("start");
	run_case(0, 1);
	run_case(0, 0);
	run_case(1, 1);
	run_case(1, 0);
	if (fails) $display("FAIL (%0d)", fails); else $display("PASS");
	$finish;
end

endmodule
