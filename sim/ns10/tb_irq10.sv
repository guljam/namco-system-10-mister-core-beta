//============================================================================
//  ns10_io IRQ10 source (100 Hz / 2x VBlank) with the Mr. Driller input
//  model (MAME, 2026-10-23): on IRQ10 the game reads IN1 low (0x1FBA0004)
//  after an ISR latency and stores it on every other IRQ10 (random parity),
//  acks 0x1FBA0018; each frame it copies the latest stored sample shortly
//  after VBlank (0.1..3 ms jitter). Real clock 33.8688 MHz.
//  Checks (2x VBlank): IRQ10 at 1/4 and 3/4 of the frame, or 5/8 and 7/8
//  (irq10_late, Driller sets), every 17 ms tap is seen. 100 Hz: period.
//  Drill (Auto) (ns10_autofire): tb_autofire.sv.
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
reg         late = 0;                      // 2x VBlank at 5/8, 7/8
reg         vblank = 0;
wire        irq10;
reg         tap = 0;

wire [31:0] in1 = ~{27'd0, tap, 4'd0};

ns10_io io(.clk(clk), .reset(reset), .rd(rd), .wr(wr), .addr(addr), .wdata(wdata), .rdata(rdata),
	.dip(8'd0), .in1(in1), .irq10_vbl(mode), .irq10_late(late), .vblank(vblank), .irq10(irq10),
	.bank_rd(), .bank_wr(), .bank_off(), .ss_addr(2'd0), .ss_din(32'd0), .ss_wr(1'b0), .ss_dout());

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
reg     seen = 0;
reg     tap_hit = 0;
always @(posedge clk) if (vblank) fork : copy
	begin
		#((100 + $urandom % 2900) * 1000);
		seen = stored;
		if (seen) tap_hit = 1;
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

// IRQ10 positions in the frame: at a / 8 or b / 8 of the frame before
task check_phase(input integer a, input integer b);
	begin
		for (i = 0; i < 40; i++) begin
			@(posedge clk); while (!irq10) @(posedge clk);
			d = $time - vb_t;                  // time after the last VBlank
			q = (vb_t - vb_t_1) / 8;           // 1/8 of the frame before (fper)
			if (!((d > a * q - 300 && d < a * q + 300) || (d > b * q - 300 && d < b * q + 300)))
				fail($sformatf("IRQ10 %0t ns after VBlank, frame/8 = %0t, expected %0d/8 or %0d/8", d, q, a, b));
		end
	end
endtask

task check_taps(input string name);
	begin
		lost = 0;
		for (i = 0; i < 40; i++) begin
			wait_ms(40 + $urandom % 30);
			#($urandom % 16683000);
			tap_hit = 0;
			tap = 1; wait_ms(17); tap = 0;
			wait_ms(25);                       // pad copy of the last frame
			if (!tap_hit) lost = lost + 1;
		end
		$display("%s 17 ms taps: %0d / 40 lost", name, lost);
	end
endtask

initial begin
	parity = $urandom % 2;
	$display("game stores IRQ10 calls with parity %0d", parity);
	repeat (10) @(posedge clk);
	reset = 0;
	wait_ms(100);

	// 1. 2x VBlank: IRQ10 positions in the frame
	check_phase(2, 6);
	p_irq = nirq;
	wait_ms(1000);
	$display("2x VBlank: %0d IRQ10 in 1 s", nirq - p_irq);
	if (nirq - p_irq < 118 || nirq - p_irq > 122) fail("2x VBlank IRQ10 rate");

	// 2. 40 taps of 17 ms (just over one frame) at random phase: all seen by the game
	check_taps("2x VBlank");
	if (lost != 0) fail("17 ms tap lost at 2x VBlank");

	// 3. Driller sets: 5/8 and 7/8, same rate, taps
	late = 1;
	wait_ms(50);
	check_phase(5, 7);
	p_irq = nirq;
	wait_ms(1000);
	$display("2x VBlank late: %0d IRQ10 in 1 s", nirq - p_irq);
	if (nirq - p_irq < 118 || nirq - p_irq > 122) fail("2x VBlank late IRQ10 rate");
	check_taps("2x VBlank late");
	if (lost != 0) fail("17 ms tap lost at 2x VBlank late");
	late = 0;

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
	check_taps("100 Hz");
	$display("(100 Hz taps: reference)");

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
