//============================================================================
//  ns10_autofire testbench with the Mr. Driller input model measured in MAME:
//  IRQ10 reads IN1 every 10 ms (+-0.3 ms jitter), the game stores every other
//  read (parity random per run), each vblank (59.94 Hz, random phase) the game
//  takes the latest stored sample. The clock is scaled: 1 clk = 10 us.
//  Checks: 25 presses/s seen by the game, stored samples alternate while held,
//  first stored sample after a press is on, release / OSD off at once, P1/P2
//  independent. Limits: sim time limit and a no-read watchdog.
//============================================================================
`timescale 1us/1ns

module tb_autofire;

reg clk = 0;
always #5 clk = ~clk;                      // 10 us

reg       reset = 1;
reg       in_rd = 0;
reg       osd = 0;
reg [1:0] btn = 0;
wire [1:0] fire;

ns10_autofire dut(.clk(clk), .reset(reset), .in_rd(in_rd), .osd(osd), .btn(btn), .fire(fire));

integer errors = 0;
task fail(input string s); begin $display("FAIL %0t us: %s", $time, s); errors = errors + 1; end endtask

// ------------------------------------------------------------------ game model
integer parity;                            // which reads the game stores
integer nread = 0;
reg [1:0] stored = 0;                      // latest stored sample (game pad cur)
reg [1:0] last_stored = 0;
integer   nstored = 0;
reg [1:0] seen = 0, seen_1 = 0;            // per frame
integer   presses[2];
integer   since_press_ms[2];
reg [1:0] first_pending = 0;               // a press happened, first stored sample not checked yet
reg [1:0] alt_check = 0;                   // held long enough: stored samples must alternate
time      last_read_t = 0;

// IRQ10: one IN1 low read per 10 ms (+-0.3 ms), 1..3 clocks long; the level the CPU gets
// is the value in the clock where in_rd rises (ns10_io latches rdata on rd)
initial begin : reads
	integer w, len;
	#1000;
	forever begin
		w = 1000 + ($urandom % 61) - 30;    // 10 ms +- 0.3 ms in 10 us clocks
		repeat (w) @(posedge clk);
		#1 in_rd = 1;
		@(posedge clk);
		begin : latch
			reg [1:0] lvl;
			lvl = fire;                     // before this edge's update (sampled at #1 after it)
			nread = nread + 1;
			last_read_t = $time;
			if ((nread % 2) == parity) begin
				for (int p = 0; p < 2; p++) begin
					if (alt_check[p] && lvl[p] == stored[p]) fail($sformatf("P%0d stored sample did not alternate (read %0d)", p + 1, nread));
					if (first_pending[p]) begin
						if (btn[p] && !osd && !lvl[p]) fail($sformatf("P%0d first stored sample after press is off", p + 1));
						first_pending[p] = 0;
						if (btn[p] && !osd) alt_check[p] = 1;
					end
				end
				stored = lvl;
				nstored = nstored + 1;
			end
		end
		len = $urandom % 3;
		repeat (len) @(posedge clk);
		#1 in_rd = 0;
	end
end

// vblank: game takes the latest stored sample, counts presses (rising edges)
initial begin : frames
	real t;
	t = 2000.0 + ($urandom % 16683);
	forever begin
		#(t - $realtime);
		seen_1 = seen;
		seen   = stored;
		for (int p = 0; p < 2; p++) if (seen[p] && !seen_1[p]) presses[p] = presses[p] + 1;
		t = t + 16683.33;                   // 59.94 Hz
	end
end

// watchdogs: no IN1 read for 1 s of sim time, total sim time limit
initial begin
	forever begin
		#100000;
		if ($time - last_read_t > 1000000 && $time > 2000000) begin fail("watchdog: no IN1 read for 1 s"); $finish; end
	end
end
initial begin
	#(120 * 1000000);
	fail("sim time limit 120 s");
	$finish;
end

// ------------------------------------------------------------------ helpers
task press(input integer p); begin
	@(posedge clk); #2 btn[p] = 1; first_pending[p] = 1;
end endtask
task release_(input integer p); begin
	@(posedge clk); #2 btn[p] = 0; alt_check[p] = 0; first_pending[p] = 0;
	@(posedge clk); #1 if (fire[p]) fail($sformatf("P%0d fire still on after release", p + 1));
end endtask
task wait_ms(input integer ms); begin #(ms * 1000); end endtask

integer p0, p1;

initial begin
	parity = $urandom % 2;
	presses[0] = 0; presses[1] = 0;
	$display("game stores reads with parity %0d", parity);
	repeat (10) @(posedge clk);
	reset = 0;
	wait_ms(100);

	// 1. P1 held 10 s: 25 presses/s, stored samples alternate
	press(0);
	@(posedge clk); #1 if (!fire[0]) fail("P1 not on right after press");
	wait_ms(500);
	p0 = presses[0];
	wait_ms(10000);
	p1 = presses[0] - p0;
	$display("P1 held 10 s: %0d presses seen by the game (%0.2f/s)", p1, p1 / 10.0);
	if (p1 < 249 || p1 > 251) fail("P1 rate not 25/s");
	if (fire[1]) fail("P2 fired while only P1 held");
	release_(0);
	wait_ms(100);
	if (seen[0]) fail("game still sees P1 drill 100 ms after release");

	// 2. OSD open while held: off; OSD closed with button held: on at once
	press(0);
	wait_ms(300);
	@(posedge clk); #2 osd = 1; alt_check[0] = 0;
	@(posedge clk); #1 if (fire[0]) fail("fire on while OSD open");
	wait_ms(500);
	if (fire[0]) fail("fire on while OSD open (500 ms)");
	@(posedge clk); #2 osd = 0; first_pending[0] = 1; alt_check[0] = 0;
	@(posedge clk); #1 if (!fire[0]) fail("not on right after OSD close with button held");
	wait_ms(300);
	release_(0);

	// 3. P1 and P2 together, independent phases, both 25/s
	press(0);
	wait_ms(7);
	press(1);
	wait_ms(500);
	p0 = presses[0]; p1 = presses[1];
	wait_ms(4000);
	$display("P1+P2 held 4 s: P1 %0d, P2 %0d presses", presses[0] - p0, presses[1] - p1);
	if (presses[0] - p0 < 99 || presses[0] - p0 > 101) fail("P1 rate not 25/s with P2 held");
	if (presses[1] - p1 < 99 || presses[1] - p1 > 101) fail("P2 rate not 25/s");
	release_(0);
	release_(1);

	// 4. 300 random taps (5..200 ms) at random times: first stored sample of each is on
	for (int i = 0; i < 300; i++) begin
		wait_ms(5 + $urandom % 60);
		press(0);
		wait_ms(5 + $urandom % 195);
		release_(0);
	end

	// 5. reset while held: off
	press(0);
	wait_ms(50);
	@(posedge clk); #2 reset = 1;
	@(posedge clk); #1 if (fire[0]) fail("fire on during reset");
	@(posedge clk); #2 reset = 0;
	release_(0);

	$display("reads %0d, stored %0d", nread, nstored);
	if (errors == 0) $display("PASS"); else $display("FAILED: %0d errors", errors);
	$finish;
end

endmodule
