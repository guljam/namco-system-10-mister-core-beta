//============================================================================
//  ns10_autofire (landing-synced Drill (Auto)) + ns10_io (IRQ10 2x VBlank at
//  5/8, 7/8) with a Mr. Driller game model on the PSX RAM bus (MAME traces,
//  docs/fixes-2026-10-24.md). Frames are shortened (FRAME clocks).
//  Game model per frame:
//    IRQ10 ISR reads IN1, stores every other call (random parity).
//    VBlank + 0.5..1.5 %: pad copy, cur / prev per player, pad word write (sh).
//    Player update (P1 struct 0 at 1..2 %, P2 struct 1 at 20..39 % of the frame):
//      reads state / word 0 / mode / side; standing: cooldown (sb) or dig
//      check (edge of its pad); a dig falls after 3..8 frames for 3..12 frames;
//      X block: 5 hits with a 1..3 frame cooldown each, then the fall.
//  Noise: DMA writes, i-cache line reads and other CPU traffic on the bus,
//  DMA / cache garbage on the watched words.
//  Check: with Drill (Auto) held, every first ready frame (landing or
//  cooldown end) sees a new press; P1 / P2 / versus / 1P on the P2 side /
//  Driller G; refresh from reads after an autofire reset (savestate); OSD,
//  release and game 0 off. Limits: sim time limit, no-VBlank watchdog.
//============================================================================
`timescale 1ns/1ps

module tb_autofire;

localparam integer FRAME = 20000;           // clocks per frame (real: 565050)

reg clk = 0;
always #14.7638 clk = ~clk;                 // 33.8688 MHz

reg         reset = 1, af_reset = 1;
reg         rd = 0, wr = 0;
reg  [20:0] addr = 0;
reg  [15:0] wdata = 0;
wire [15:0] rdata;
reg         vblank = 0;
wire        irq10;
reg   [1:0] game = 1;
reg         osd = 0;
reg   [1:0] btn = 0;
wire  [1:0] fire;

reg         ram_req = 0, ram_rnw = 1, ram_dma = 0, ram_cache = 0, ram_rdack = 0;
reg  [24:0] ram_addr = 0;
reg   [3:0] ram_be = 0;
reg  [31:0] ram_wdata = 0, ram_rdata = 0;

wire [31:0] in1 = ~{19'd0, fire[1], 7'd0, fire[0], 4'd0};

ns10_io io(.clk(clk), .reset(reset), .rd(rd), .wr(wr), .addr(addr), .wdata(wdata), .rdata(rdata),
	.dip(8'd0), .in1(in1), .irq10_vbl(1'b1), .irq10_late(1'b1), .vblank(vblank), .irq10(irq10),
	.bank_rd(), .bank_wr(), .bank_off(), .ss_addr(2'd0), .ss_din(32'd0), .ss_wr(1'b0), .ss_dout());

ns10_autofire dut(.clk(clk), .reset(af_reset), .game(game), .osd(osd), .btn(btn), .fire(fire),
	.ram_req(ram_req), .ram_rnw(ram_rnw), .ram_dma(ram_dma), .ram_cache(ram_cache), .ram_addr(ram_addr),
	.ram_be(ram_be), .ram_wdata(ram_wdata), .ram_rdack(ram_rdack), .ram_rdata(ram_rdata));

integer errors = 0;
task fail(input string s); begin $display("FAIL %0t ns: %s", $time, s); errors = errors + 1; end endtask

// ------------------------------------------------------------------ game addresses (physical)
reg [21:0] A_PAD[0:1], A_ST[0:1], A_W0[0:1], A_MODE, A_SIDE;
task set_game(input integer g); begin
	game = g;
	if (g == 2) begin
		A_PAD[0] = 22'h337DF4; A_PAD[1] = 22'h337E04; A_MODE = 22'h369B38; A_SIDE = 22'h2EF0E4;
		A_W0[0] = 22'h369B40; A_W0[1] = 22'h369CF4; A_ST[0] = 22'h369C18; A_ST[1] = 22'h369DCC;
	end else begin
		A_PAD[0] = 22'h23F94C; A_PAD[1] = 22'h23F95C; A_MODE = 22'h271690; A_SIDE = 22'h20AD0C;
		A_W0[0] = 22'h271698; A_W0[1] = 22'h271818; A_ST[0] = 22'h27173C; A_ST[1] = 22'h2718BC;
	end
end endtask

// ------------------------------------------------------------------ RAM bus model (one request at a time)
reg [31:0] mem [0:(1 << 20) - 1];
initial for (int i = 0; i < (1 << 20); i++) mem[i] = 0;
function [31:0] mrd(input [21:0] a); mrd = mem[a[21:2]]; endfunction
reg bus_busy = 0;
task automatic bus_get; begin while (bus_busy) @(posedge clk); bus_busy = 1; end endtask

task automatic bus_wr(input [21:0] a, input [3:0] be, input [31:0] d, input dma);
	reg [31:0] o;
	begin
		bus_get;
		@(posedge clk); #1;
		ram_req = 1; ram_rnw = 0; ram_dma = dma; ram_cache = 0; ram_addr = {3'b000, a[21:2], 2'b00}; ram_be = be; ram_wdata = d;
		if (!dma) begin
			o = mrd(a);
			for (int b = 0; b < 4; b++) if (be[b]) o[b*8 +: 8] = d[b*8 +: 8];
			mem[a[21:2]] = o;
		end
		@(posedge clk); #1 ram_req = 0;
		repeat (2 + $urandom % 6) @(posedge clk);
		bus_busy = 0;
	end
endtask

task automatic bus_rd(input [21:0] a, input cache, input dma, output [31:0] d);
	begin
		bus_get;
		@(posedge clk); #1;
		ram_req = 1; ram_rnw = 1; ram_dma = dma; ram_cache = cache; ram_addr = {3'b000, a[21:2], 2'b00};
		@(posedge clk); #1 ram_req = 0;
		repeat (3 + $urandom % 12) @(posedge clk);
		#1 ram_rdack = 1; ram_rdata = (cache || dma) ? $urandom : mrd(a); d = mrd(a);
		@(posedge clk); #1 ram_rdack = 0; ram_rdata = $urandom;
		bus_busy = 0;
	end
endtask

task automatic cpu_wr(input [21:0] a, input [3:0] be, input [31:0] d); bus_wr(a, be, d, 0); endtask
task automatic cpu_rd(input [21:0] a, output [31:0] d); bus_rd(a, 0, 0, d); endtask

function watched(input [21:0] a);
	watched = (a[21:2] == A_PAD[0][21:2]) || (a[21:2] == A_PAD[1][21:2]) || (a[21:2] == A_ST[0][21:2]) || (a[21:2] == A_ST[1][21:2]) ||
	          (a[21:2] == A_W0[0][21:2]) || (a[21:2] == A_W0[1][21:2]) || (a[21:2] == A_MODE[21:2]) || (a[21:2] == A_SIDE[21:2]);
endfunction

// noise: other CPU traffic, DMA writes and i-cache reads, also on the watched words (garbage)
reg noise_on = 0;
initial forever begin
	reg [31:0] d;
	reg [21:0] a;
	repeat (50 + $urandom % 400) @(posedge clk);
	if (noise_on) begin
		a = ($urandom % 4 == 0) ? (($urandom % 2) ? A_ST[$urandom % 2] : A_PAD[$urandom % 2]) : ($urandom & 22'h3FFFFC);
		case ($urandom % 4)
			0: bus_wr(a, 4'hF, $urandom, 1);                           // DMA write
			1: bus_rd(a, 1, 0, d);                                     // i-cache line read
			2: bus_rd(a, 0, 1, d);                                     // DMA read
			3: if (!watched(a)) cpu_wr(a, 4'hF, $urandom);         // the game never writes garbage there
		endcase
	end
end

// ------------------------------------------------------------------ VBlank
integer nframe = 0;
time    vb_t = 0;
initial begin
	repeat (1000) @(posedge clk);
	forever begin
		repeat (FRAME - 1 - ($urandom % 3)) @(posedge clk);
		#1 vblank = 1; vb_t = $time;
		@(posedge clk); #1 vblank = 0;
		nframe = nframe + 1;
	end
end

// ------------------------------------------------------------------ IRQ10 ISR: read IN1, store every other call
integer parity, ncall = 0;
reg [1:0] stored = 0;
integer bad_phase = 0;
always @(posedge clk) if (irq10) fork : isr
	begin
		// IRQ10 at 5/8 or 7/8 of the frame
		if (nframe > 2 && !((($time - vb_t) > FRAME * 29.5 * 5 / 8 - 300 && ($time - vb_t) < FRAME * 29.6 * 5 / 8 + 300) ||
		                   (($time - vb_t) > FRAME * 29.5 * 7 / 8 - 300 && ($time - vb_t) < FRAME * 29.6 * 7 / 8 + 300)))
			bad_phase = bad_phase + 1;
		repeat (20 + $urandom % 300) @(posedge clk);      // ISR latency
		#1 rd = 1; addr = 21'h1A0004;
		@(posedge clk); #1 rd = 0;
		if ((ncall % 2) == parity) stored = {~rdata[12], ~rdata[4]};
		ncall = ncall + 1;
		repeat (10) @(posedge clk);
		#1 wr = 1; addr = 21'h1A0018; wdata = 0;
		@(posedge clk); #1 wr = 0;
	end
join_none

// ------------------------------------------------------------------ game
reg  [1:0] cur = 0, prev = 0;
reg        versus = 0, side = 0;
integer    st[0:1], cd[0:1], tmr[0:1], hits[0:1];
reg  [1:0] xblock = 0;                      // X block mode per struct (5 hits)
reg  [1:0] was_ready = 0;
integer    first_ready[0:1], first_hit[0:1], digs[0:1], lands[0:1];
reg        measure = 0;
reg  [1:0] active = 0;                      // structs in the game
string     why[0:1];
reg        dbg = 0;                         // per-frame model trace

task automatic set_mode(input integer mode, input integer sd); begin
	cpu_wr(A_MODE, 4'hF, mode);
	cpu_wr(A_SIDE, 4'h3, sd);
end endtask

// pad of struct s: versus = pad s, 1P = the side's pad
function integer pad_of(input integer s); pad_of = versus ? s : side; endfunction

task automatic player_update(input integer s);
	reg [31:0] d;
	integer p;
	begin
		p = pad_of(s);
		cpu_rd(A_ST[s], d);
		cpu_rd(A_W0[s], d);
		if (dbg) $display("  m%0d L%0d D%0d f%0d s%0d st %0d cd %0d tmr %0d hits %0d cur %b prev %b sh st %h w0 %h pad %h side %h mode %h",
			measure, lands[s], digs[s], nframe, s, st[s], cd[s], tmr[s], hits[s], cur, prev, dut.sh[4], dut.sh[6], dut.sh[0], dut.sh[3], dut.sh[2]);
		if (st[s] == 1) begin
			if (cd[s] != 0) begin
				cd[s] = cd[s] - 1;
				why[s] = $sformatf("cooldown %0d at frame %0d", cd[s], nframe);
				cpu_wr(A_W0[s], 4'b0010, cd[s] << 8);
				was_ready[s] = 0;
			end else begin
				// dig check: a new press of its pad
				if (!was_ready[s] && measure) begin
					first_ready[s] = first_ready[s] + 1;
					if (cur[p] && !prev[p]) first_hit[s] = first_hit[s] + 1;
					else $display("  miss frame %0d struct %0d pad %0d: cur %b prev %b, last %s, sh st %0d w0 %h mode %h side %h pad %h",
						nframe, s, p, cur, prev, why[s], dut.sh[4 + s], dut.sh[6 + s], dut.sh[2], dut.sh[3], dut.sh[p]);
				end
				was_ready[s] = 1;
				if (cur[p] && !prev[p] && tmr[s] == 0) begin
					if (measure) digs[s] = digs[s] + 1;
					if (xblock[s] && hits[s] < 4) begin
						hits[s] = hits[s] + 1;
						cd[s] = 1 + $urandom % 3;               // cooldown after an X block hit
						cpu_wr(A_W0[s], 4'b0010, cd[s] << 8);
						was_ready[s] = 0;
					end else begin
						hits[s] = 0;
						tmr[s] = 3 + $urandom % 6;              // the block breaks, then the fall
					end
				end else if (tmr[s] != 0) begin
					tmr[s] = tmr[s] - 1;
					if (tmr[s] == 0) begin
						st[s] = 2; tmr[s] = 3 + $urandom % 10;
						cpu_wr(A_ST[s], 4'hF, 2);
						was_ready[s] = 0;
						xblock[s] = ($urandom % 3 == 0);
					end
				end
			end
		end else if (st[s] == 2) begin
			tmr[s] = tmr[s] - 1;
			if (tmr[s] == 0) begin
				st[s] = 1;
				cd[s] = ($urandom % 8 == 0) ? 2 : 0;          // sometimes a cooldown at the landing
				why[s] = $sformatf("landing cd %0d at frame %0d", cd[s], nframe);
				cpu_wr(A_ST[s], 4'hF, 1);
				cpu_wr(A_W0[s], 4'b0010, cd[s] << 8);
				if (measure) lands[s] = lands[s] + 1;
			end
		end
	end
endtask

reg game_on = 0;
always @(posedge clk) if (vblank && game_on) fork : frame
	reg [31:0] d;
	begin
		repeat (FRAME / 200 + $urandom % (FRAME / 100)) @(posedge clk);
		prev = cur; cur = stored;
		for (int p = 0; p < 2; p++) cpu_wr(A_PAD[p], 4'b1100, {6'd0, cur[p], 9'd0, 16'h0});
		cpu_rd(A_MODE, d);
		cpu_rd(A_SIDE, d);
		if (active[0]) player_update(0);
		if (active[1]) begin
			while (($time - vb_t) < FRAME * 29.5 * (20 + $urandom % 19) / 100) @(posedge clk);
			player_update(1);
		end
	end
join_none

// watchdogs
initial forever begin
	#1_000_000;
	if ($time - vb_t > 5 * FRAME * 30 && $time > 1_000_000) begin fail("watchdog: no VBlank"); $finish; end
end
initial begin
	#(5.0 * 1e9);
	fail("sim time limit 5 s");
	$finish;
end

task frames(input integer n); begin repeat (n) begin @(posedge vblank); end end endtask

// both structs standing, no cooldown, in the model and in RAM
task init_players;
	begin
		for (int s = 0; s < 2; s++) begin
			st[s] = 1; cd[s] = 0; tmr[s] = 0; hits[s] = 0;
			cpu_wr(A_ST[s], 4'hF, 1); cpu_wr(A_W0[s], 4'hF, 0);
		end
	end
endtask

task run_case(input string name, input integer g, input integer mode, input integer sd, input [1:0] act, input [1:0] held, input integer n);
	begin
		set_game(g);
		versus = (g == 2) ? (mode == 'h0A || mode == 'h12) : (mode == 'h0A);
		side = sd;
		set_mode(mode, sd);
		init_players;
		active = act;
		btn = held;
		frames(5);
		measure_frames(name, act, n);
	end
endtask

task measure_frames(input string name, input [1:0] act, input integer n);
	begin
		for (int s = 0; s < 2; s++) begin first_ready[s] = 0; first_hit[s] = 0; digs[s] = 0; lands[s] = 0; end
		measure = 1;
		frames(n);
		measure = 0;
		for (int s = 0; s < 2; s++) if (act[s]) begin
			$display("%s struct %0d: %0d landings, %0d digs, first ready frames %0d, new press there %0d",
				name, s, lands[s], digs[s], first_ready[s], first_hit[s]);
			if (first_ready[s] < 20) fail({name, ": too few ready frames"});
			if (first_hit[s] != first_ready[s]) fail({name, ": a first ready frame without a new press"});
		end
	end
endtask

integer i, on, off;
reg [31:0] d;

initial begin
	parity = $urandom % 2;
	$display("game stores IRQ10 calls with parity %0d", parity);
	set_game(1);
	repeat (10) @(posedge clk);
	reset = 0; af_reset = 0;
	frames(3);
	game_on = 1;
	noise_on = 1;

	run_case("DR2 1P P1 side",        1, 'h0C, 0, 2'b01, 2'b01, 400);
	run_case("DR2 1P P2 side",        1, 'h0C, 1, 2'b01, 2'b10, 400);
	run_case("DR2 versus",            1, 'h0A, 0, 2'b11, 2'b11, 400);
	run_case("DRG 1P mode 11",        2, 'h0B, 0, 2'b01, 2'b01, 400);
	run_case("DRG versus Race",       2, 'h12, 0, 2'b11, 2'b11, 400);
	run_case("DRG versus Survival",   2, 'h0A, 0, 2'b11, 2'b11, 300);

	// player not in the game (1P on the P1 side, P2 held): plain on/off every frame
	set_game(1); versus = 0; side = 0; set_mode('h0C, 0); init_players; active = 2'b01; btn = 2'b10;
	frames(5);
	on = 0; off = 0;
	for (i = 0; i < 100; i++) begin frames(1); repeat (FRAME / 50) @(posedge clk); if (cur[1] == prev[1]) off = off + 1; else on = on + 1; end
	$display("P2 not in the game: %0d / 100 frames changed", on);
	if (off != 0) fail("P2 not in the game: not on/off every frame");

	// savestate: the autofire shadows are lost while the game keeps its state; reads refresh them
	set_mode('h0C, 0); active = 2'b01; btn = 2'b01;
	frames(5);
	#1 af_reset = 1; repeat (5) @(posedge clk); #1 af_reset = 0;
	measure_frames("DR2 after shadow reset", 2'b01, 400);

	// OSD, release, game 0: off at once
	btn = 2'b11; osd = 1;
	repeat (3) @(posedge clk);
	for (i = 0; i < 3 * FRAME; i++) begin @(posedge clk); if (fire != 0) begin fail("fire with the OSD open"); break; end end
	osd = 0;
	frames(3);
	btn = 0;
	repeat (3) @(posedge clk);
	for (i = 0; i < 3 * FRAME; i++) begin @(posedge clk); if (fire != 0) begin fail("fire after release"); break; end end
	btn = 2'b11; game = 0;
	repeat (3) @(posedge clk);
	for (i = 0; i < 3 * FRAME; i++) begin @(posedge clk); if (fire != 0) begin fail("fire with game 0"); break; end end

	if (bad_phase != 0) fail($sformatf("%0d IRQ10 not at 5/8 or 7/8 of the frame", bad_phase));
	$display("frames %0d, IRQ10 calls %0d", nframe, ncall);
	if (errors == 0) $display("PASS"); else $display("FAILED: %0d errors", errors);
	$finish;
end

endmodule
