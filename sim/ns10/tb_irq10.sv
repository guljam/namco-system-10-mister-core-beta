//============================================================================
//  ns10_io IRQ10 source (100 Hz / 2x VBlank) + ns10_autofire with the
//  Mr. Driller input model (MAME, 2026-10-23): on IRQ10 the game reads IN1
//  low (0x1FBA0004) after an ISR latency and stores it on every other IRQ10
//  (random parity), acks 0x1FBA0018; each frame it copies the latest stored
//  sample shortly after VBlank (0.1..3 ms jitter). Real clock 33.8688 MHz.
//  Checks (2x VBlank): IRQ10 at 1/4 and 3/4 of the frame, Drill (Auto)
//  alternates every frame (29.97/s), every 17 ms tap is seen. 100 Hz: period.
//  Limits: sim time limit, no-IRQ10 watchdog.
//============================================================================
`timescale 1ns/1ps

module tb_irq10;

reg clk = 0;
always #14.7638 clk = ~clk;                // 33.8688 MHz

reg         reset = 1;
reg         rd = 0, wr = 0;
reg  [20:0] addr = 0;
reg  [15:0] wdata = 0;
wire [15:0] rdata;
reg         mode = 1;                      // 1 = 2x VBlank
reg         vblank = 0;
wire        irq10;
reg         btn = 0, tap = 0;
wire  [1:0] fire;

wire [31:0] in1 = ~{27'd0, tap | fire[0], 4'd0};

ns10_io io(.clk(clk), .reset(reset), .rd(rd), .wr(wr), .addr(addr), .wdata(wdata), .rdata(rdata),
	.dip(8'd0), .in1(in1), .irq10_vbl(mode), .vblank(vblank), .irq10(irq10),
	.bank_rd(), .bank_wr(), .bank_off());

ns10_autofire af(.clk(clk), .reset(reset), .in_rd(rd && addr[20:1] == 20'hD0002), .osd(1'b0),
	.btn({1'b0, btn}), .fire(fire));

integer errors = 0;
task fail(input string s); begin $display("FAIL %0t ns: %s", $time, s); errors = errors + 1; end endtask

// ------------------------------------------------------------------ VBlank: NTSC fields 263 / 262 lines
// (3413 video clocks per line at 53.69 MHz = 2153 CPU clocks), 1 clock pulse as irq_VBLANK
integer   vb_len = 0;
time      vb_t = 0, vb_t_1 = 0;
initial begin
	integer n;
	n = 0;
	repeat (1000) @(posedge clk);
	forever begin
		vb_len = (n[0] ? 262 : 263) * 2153;
		repeat (vb_len - 1) @(posedge clk);
		#1 vblank = 1;
		vb_t_1 = vb_t; vb_t = $time;
		@(posedge clk); #1 vblank = 0;
		n = n + 1;
	end
end

// ------------------------------------------------------------------ IRQ10 timing checks
time    irq_t = 0, irq_t_1 = 0;
integer nirq = 0;
always @(posedge clk) if (irq10) begin
	irq_t_1 = irq_t; irq_t = $time;
	nirq = nirq + 1;
end

// ------------------------------------------------------------------ game: ISR read / store / ack
integer parity;
integer ncall = 0;
reg     stored = 0;
reg     store_ev = 0;
always @(posedge clk) if (irq10) fork : isr
	begin
		repeat (60 + $urandom % 1700) @(posedge clk);      // ISR latency 2..52 us
		#1 rd = 1; addr = 21'h1A0004;
		@(posedge clk); #1 rd = 0;
		if ((ncall % 2) == parity) begin stored = ~rdata[4]; store_ev = ~store_ev; end
		ncall = ncall + 1;
		repeat (20) @(posedge clk);
		#1 wr = 1; addr = 21'h1A0018; wdata = 0;
		@(posedge clk); #1 wr = 0;
	end
join_none

// pad copy once per frame, 0.1..3 ms after VBlank
reg     seen = 0, seen_1 = 0;
integer presses = 0, frames = 0, same = 0, taps_seen = 0;
reg     tap_hit = 0;
reg     count_on = 0;
always @(posedge clk) if (vblank) fork : copy
	begin
		#((100 + $urandom % 2900) * 1000);
		seen_1 = seen;
		seen   = stored;
		if (count_on) begin
			frames = frames + 1;
			if (seen && !seen_1) presses = presses + 1;
			if (seen == seen_1) same = same + 1;
		end
		if (seen) tap_hit = 1;                // btn off: stored = tap only
	end
join_none

// watchdogs
initial forever begin
	#10_000_000;
	if ($time - irq_t > 50_000_000 && $time > 50_000_000) begin fail("watchdog: no IRQ10 for 50 ms"); $finish; end
end
initial begin
	#(40.0 * 1e9);
	fail("sim time limit 40 s");
	$finish;
end

task wait_ms(input integer ms); begin #(ms * 1000000.0); end endtask

integer i, p_irq, lost, after;
time    d, q;

initial begin
	parity = $urandom % 2;
	$display("game stores IRQ10 calls with parity %0d", parity);
	repeat (10) @(posedge clk);
	reset = 0;
	wait_ms(100);

	// 1. 2x VBlank: IRQ10 positions in the frame
	for (i = 0; i < 40; i++) begin
		@(posedge clk); while (!irq10) @(posedge clk);
		d = $time - vb_t;                      // time after the last VBlank
		q = (vb_t - vb_t_1) / 4;               // 1/4 of the frame before (fper)
		if (!((d > q - 300 && d < q + 300) || (d > 3 * q - 300 && d < 3 * q + 300)))
			fail($sformatf("IRQ10 %0t ns after VBlank, frame/4 = %0t", d, q));
	end
	p_irq = nirq;
	wait_ms(1000);
	$display("2x VBlank: %0d IRQ10 in 1 s", nirq - p_irq);
	if (nirq - p_irq < 118 || nirq - p_irq > 122) fail("2x VBlank IRQ10 rate");

	// 2. Drill (Auto) held 3 s: the game sees on / off every frame
	#1 btn = 1;
	wait_ms(200);
	count_on = 1; presses = 0; frames = 0; same = 0;
	wait_ms(3000);
	count_on = 0;
	$display("2x VBlank Drill (Auto) 3 s: %0d presses in %0d frames (%0.2f/s), %0d frames repeated the last value",
		presses, frames, presses * 59.94 / frames, same);
	if (same != 0) fail("frames without a new autofire level");
	if (presses * 59.94 / frames < 29.5 || presses * 59.94 / frames > 30.5) fail("2x VBlank autofire not 30/s");
	#1 btn = 0;
	wait_ms(100);
	if (seen) fail("game still sees drill after release");

	// 3. 40 taps of 17 ms (just over one frame) at random phase: all seen by the game
	lost = 0;
	for (i = 0; i < 40; i++) begin
		wait_ms(40 + $urandom % 30);
		#($urandom % 16683000);
		tap_hit = 0;
		tap = 1; wait_ms(17); tap = 0;
		wait_ms(25);                           // pad copy of the last frame
		if (!tap_hit) lost = lost + 1;
	end
	$display("2x VBlank 17 ms taps: %0d / 40 lost", lost);
	if (lost != 0) fail("17 ms tap lost at 2x VBlank");

	// 4. 100 Hz (MAME): period, and the same taps for reference
	mode = 0;
	wait_ms(50);
	@(posedge clk); while (!irq10) @(posedge clk);
	q = $time;
	@(posedge clk); while (!irq10) @(posedge clk);
	if ($time - q < 9_999_000 || $time - q > 10_001_000) fail($sformatf("100 Hz period %0t ns", $time - q));
	p_irq = nirq;
	wait_ms(1000);
	$display("100 Hz: %0d IRQ10 in 1 s", nirq - p_irq);
	if (nirq - p_irq < 99 || nirq - p_irq > 101) fail("100 Hz IRQ10 rate");
	#1 btn = 1;
	wait_ms(200);
	count_on = 1; presses = 0; frames = 0; same = 0;
	wait_ms(3000);
	count_on = 0;
	#1 btn = 0;
	$display("100 Hz Drill (Auto) 3 s: %0d presses in %0d frames (%0.2f/s), %0d frames repeated the last value (reference)",
		presses, frames, presses * 59.94 / frames, same);
	if (presses * 59.94 / frames < 24.5 || presses * 59.94 / frames > 25.5) fail("100 Hz autofire not 25/s");
	lost = 0;
	for (i = 0; i < 40; i++) begin
		wait_ms(40 + $urandom % 30);
		#($urandom % 16683000);
		tap_hit = 0;
		tap = 1; wait_ms(17); tap = 0;
		wait_ms(25);
		if (!tap_hit) lost = lost + 1;
	end
	$display("100 Hz 17 ms taps: %0d / 40 lost (reference)", lost);

	// 5. back to 2x VBlank: still two IRQ10 per frame
	mode = 1;
	wait_ms(100);
	p_irq = nirq;
	wait_ms(500);
	if (nirq - p_irq < 59 || nirq - p_irq > 61) fail($sformatf("2x VBlank after switching back: %0d IRQ10 in 0.5 s", nirq - p_irq));

	$display("IRQ10 %0d, ISR calls %0d", nirq, ncall);
	if (errors == 0) $display("PASS"); else $display("FAILED: %0d errors", errors);
	$finish;
end

endmodule
