`timescale 1ns/1ps
//============================================================================
//  ns10_gtrace unit test (ModelSim)
//
//  TPS = 200: one trace second = 200 * 16 = 3200 clocks, the trace ends by
//  itself after 10 such seconds (32000 clocks).  clk (clk_2x) period 14.76 ns.
//
//  Field generator, 300 clocks per field (counter fc):
//    dbg_gpu[37] = g_vs (inVsync) high for fc = 0..19
//    cpu_vs      high for fc = 150..199 and 210..289 (130 clocks per field)
//
//  trig is high for 10 clocks at clock 1000.
//  The DDR3 side is a stub: 8 beats per burst, t_done for exactly one clock.
//
//  After 'DONE ': number of type A (vblank) entries, F/7 enter/leave pairs,
//  F/8 idle clocks per vblank (130) and the single F/1 END entry (lost = 0).
//============================================================================
module tb_gtrace;

localparam [25:0] TPS  = 26'd200;      // ticks per trace second
localparam [28:0] BASE = 29'h07400000; // DDR3 trace base (byte 0x3A000000)
localparam real   TP   = 14.76;        // clk_2x period in ns

localparam [39:0] DONE_TXT = 40'h444F4E4520;   // "DONE "

// ------------------------------------------------------------------ clock
reg clk = 1'b0;
always #(TP / 2.0) clk = ~clk;

// ------------------------------------------------------------------ DUT
reg  [39:0] dbg_gpu = 40'd0;
reg  [43:0] dbg_bus = 44'd0;
reg         e1_rd   = 1'b0;
reg         e1_wait = 1'b0;
reg         e3_wr   = 1'b0;
reg  [20:0] e3_addr = 21'd0;
reg  [15:0] e3_data = 16'd0;
reg         trig    = 1'b0;
reg  [27:0] af      = 28'd0;
reg         cpu_vs  = 1'b0;
reg  [15:0] cfg     = 16'h1234;

wire        t_req;
wire [28:0] t_addr;
wire [63:0] t_din;
reg   [2:0] t_beat = 3'd0;
reg         t_done = 1'b0;
wire [39:0] text;
wire        text_on;

ns10_gtrace #(.TPS(TPS)) dut
(
	.clk(clk),
	.dbg_gpu(dbg_gpu),
	.dbg_bus(dbg_bus),
	.e1_rd(e1_rd),
	.e1_wait(e1_wait),
	.e3_wr(e3_wr),
	.e3_addr(e3_addr),
	.e3_data(e3_data),
	.trig(trig),
	.af(af),
	.cpu_vs(cpu_vs),
	.cfg(cfg),
	.t_req(t_req),
	.t_addr(t_addr),
	.t_din(t_din),
	.t_beat(t_beat),
	.t_done(t_done),
	.text(text),
	.text_on(text_on)
);

// ------------------------------------------------------------------ stimulus
// free running clock counter and the 300 clk field generator
reg  [31:0] clkcnt = 32'd0;
reg  [8:0]  fc     = 9'd0;

always @(negedge clk) begin
	clkcnt      <= clkcnt + 32'd1;
	fc          <= (fc == 9'd299) ? 9'd0 : fc + 9'd1;
	dbg_gpu[37] <= (fc < 9'd20);                                  // g_vs / inVsync
	cpu_vs      <= ((fc >= 9'd150) && (fc < 9'd200)) ||
	               ((fc >= 9'd210) && (fc < 9'd290));             // 50 + 80 = 130 clk
	trig        <= (clkcnt >= 32'd1000) && (clkcnt < 32'd1010);   // 10 clk pulse
end

// ------------------------------------------------------------------ DDR3 stub
localparam integer MEMSZ = 300000;
reg  [63:0] mem [0:MEMSZ-1];
integer beats_stored = 0;
integer store_clk    = 0;
integer bursts       = 0;

initial begin : mem_init
	integer i;
	for (i = 0; i < MEMSZ; i = i + 1) mem[i] = 64'd0;
end

// one burst at a time; t_din is combinational from t_beat, so drive t_beat on
// the negedge and capture t_din just after the following posedge
initial begin : ddr_stub
	integer b, base;
	t_beat = 3'd0;
	t_done = 1'b0;
	forever begin
		@(negedge clk);
		if (t_req) begin
			base = {7'd0, t_addr[21:0]};
			for (b = 0; b < 8; b = b + 1) begin
				t_beat = b[2:0];
				@(posedge clk);
				#1;
				if ((base + b) < MEMSZ) mem[base + b] = t_din;
				beats_stored = beats_stored + 1;
				store_clk    = clkcnt;
				@(negedge clk);
			end
			bursts = bursts + 1;
			t_done = 1'b1;          // exactly one clock
			@(posedge clk);
			@(negedge clk);
			t_done = 1'b0;
			while (t_req) @(negedge clk);
		end
	end
end

// ------------------------------------------------------------------ watchdog
initial begin : wd_time
	#200000000;                     // 200 ms
	$fatal(1, "simulation time limit (200 ms) exceeded");
end

initial begin : wd_stall
	forever begin
		@(negedge clk);
		if (text_on && (text !== DONE_TXT) && ((clkcnt - store_clk) > 32'd20000))
			$fatal(1, "no DDR3 beat stored for 20000 clocks");
	end
end

// ------------------------------------------------------------------ checks
reg [8*80-1:0] reason = 0;

task chk(input logic cond, input [8*80-1:0] msg);
	begin
		if (cond) begin
			$display("ERROR: %0s", msg);
			if (reason == 0) reason = msg;
		end
	end
endtask

initial begin : check
	integer i, nent, nA, n7e, n7l, n8, n8c, nend;
	integer vmin, vmax, lval;
	reg [63:0] e;
	reg [3:0]  typ;
	reg [31:0] dat;
	integer    v;

	reason = 0;

	wait (text_on === 1'b1);
	// ignore the single clock where text is still "DONE " from C_IDLE
	wait (text !== DONE_TXT);
	wait (text === DONE_TXT);
	repeat (20) @(posedge clk);

	nent = 0; nA = 0; n7e = 0; n7l = 0; n8 = 0; n8c = 0; nend = 0;
	vmin = 1000000; vmax = -1; lval = -1;

	for (i = 0; i < beats_stored; i = i + 1) begin
		e = mem[i];
		if (e != 64'd0) begin                        // skip the burst padding
			nent = nent + 1;
			typ  = e[63:60];
			dat  = e[31:0];
			if (typ == 4'hA)
				nA = nA + 1;
			else if (typ == 4'hF) begin
				case (dat[31:28])
					4'h1: begin
						nend = nend + 1;
						lval = dat[27:22];
					end
					4'h7: if (dat[0]) n7e = n7e + 1;
					      else        n7l = n7l + 1;
					4'h8: begin
						// the first value after the start may be partial
						if (n8 != 0) begin
							v    = dat[27:0];
							n8c  = n8c + 1;
							if (v < vmin) vmin = v;
							if (v > vmax) vmax = v;
						end
						n8 = n8 + 1;
					end
					default: ;
				endcase
			end
		end
	end

	chk(nA < 90, "too few type A vblank entries (< 90)");
	chk(n8 < (nA - 1), "too few F/8 idle entries");
	chk((vmin < 129) || (vmax > 131), "F/8 idle clocks per vblank not 130");
	chk((n7e < (2 * nA - 2)) || (n7e > (2 * nA + 2)), "F/7 enter count not ~2 per vblank");
	chk(((n7e - n7l) > 1) || ((n7l - n7e) > 1), "F/7 enter/leave count mismatch");
	chk(nend != 1, "F/1 END entry count != 1");
	chk(lval != 0, "F/1 END lost field != 0");

	$display("beats stored       : %0d (%0d bursts)", beats_stored, bursts);
	$display("entries (non zero) : %0d", nent);
	$display("type A vblank      : %0d", nA);
	$display("F/7 enter / leave  : %0d / %0d", n7e, n7l);
	$display("F/8 entries        : %0d (checked %0d)", n8, n8c);
	$display("F/8 idle min / max : %0d / %0d", vmin, vmax);
	$display("F/1 END / lost     : %0d / %0d", nend, lval);

	if (reason == 0) $display("PASS");
	else             $display("FAIL: %0s", reason);
	$finish;
end

endmodule
