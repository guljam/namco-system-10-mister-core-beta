// Konami GV MiSTer core: CRT H-Size for the native 15 kHz analog output.
//
// Resizes the picture horizontally by resampling each line from a line buffer, while blanking,
// DE and the sync pulses stay native - the monitor keeps its lock and the timing the game sees is
// untouched.  Line N is written at the native pixel rate and read back during line N+1 with a
// pixel period scaled by (32 + hsize) / 32 about the centre of the active area:
//
//   hsize > 0 : wider picture (edges run into the blanking and are cut)
//   hsize < 0 : narrower picture (black borders)
//   hsize = 0 or enable = 0 : exact combinational passthrough (no line delay)
//
// The read position is an exact integer accumulator restarted every line, so every line uses the
// same pixel pattern (no shimmer, no blending).  The native pixel period (video clocks per pixel)
// and the active width are measured from ce_pix / hblank, so all PSX/GV display widths work.
// The one-line delay is compensated by the caller (VSync one line later).
//
// GPL-2.0 (part of Konami_GV_MiSTer); independent implementation.
// Copied unchanged from Tenkomori_Shooting_MiSTer rtl/crt_hsize.sv (beta 20261018) for the NS10
// core; the picture position (H-Position / V-Position) is rtl/crt_sync.sv instead of crt_shift.sv.

module gv_crt_hsize
(
	input             clk,
	input             ce_pix,
	input             enable,
	input  signed [4:0] hsize,
	input             hb,
	input       [7:0] r_in,
	input       [7:0] g_in,
	input       [7:0] b_in,
	output      [7:0] r_out,
	output      [7:0] g_out,
	output      [7:0] b_out,
	output            active        // resampling in use (one-line delay present)
);

assign active = enable & (hsize != 5'sd0);

// ---------------------------------------------------------------- line buffer (2 x 1024 x 24)
reg  [23:0] mem [0:2047];
reg  [23:0] q = 24'd0;
reg   [9:0] wx = 10'd0;
reg         wbank = 1'b0;
reg  [10:0] raddr = 11'd0;
always @(posedge clk) begin
	if (ce_pix & ~hb) mem[{wbank, wx}] <= {r_in, g_in, b_in};
	q <= mem[raddr];
end

// ---------------------------------------------------------------- measurement (write side)
reg         hb_d = 1'b1;
reg   [9:0] wlen = 10'd0;          // active pixels of the last written line
reg   [3:0] dper = 4'd8;          // video clocks per pixel
reg   [3:0] dcnt = 4'd0;
always @(posedge clk) begin
	hb_d <= hb;
	if (ce_pix) begin
		dcnt <= 4'd1;
		if (~hb & dcnt != 4'd0) dper <= dcnt;
	end else if (dcnt != 4'd15) begin
		dcnt <= dcnt + 1'd1;
	end
	if (ce_pix & ~hb) wx <= wx + 1'd1;
	if (hb & ~hb_d) begin              // end of the active line: hand it to the reader
		wlen  <= wx;
		wx    <= 10'd0;
		wbank <= ~wbank;
	end
end

// ---------------------------------------------------------------- read side
// src_pixel(c) = floor((c*32 + Wc*k/2) / (a*D)), a = 32 + k, Wc = wlen*D, c = clocks since DE start
wire signed [6:0]  a    = 7'sd32 + hsize;
// Registered: dper / wlen / hsize change at most once per line, so one clock of latency is harmless
// and keeps the multipliers out of the per-pixel accumulator path (timing).
reg         [10:0] aD   = 11'd0;                                     // <= 42 * 15
reg         [13:0] wc   = 14'd0;                                     // active clocks
reg  signed [19:0] acc0 = 20'sd0;
always @(posedge clk) begin
	aD   <= a[5:0] * dper;
	wc   <= wlen * dper;
	acc0 <= ($signed({1'b0, wc}) * hsize) >>> 1;
end

reg  signed [19:0] rem = 20'sd0;
reg  signed [11:0] p = 12'sd0;
reg                rbank = 1'b0;
reg                in_line = 1'b0;
reg                prep = 1'b0;

always @(posedge clk) begin
	if (hb & ~hb_d) begin                    // start preparing the next line (reads the bank just written)
		rbank <= wbank;
		p     <= 12'sd0;
		rem   <= acc0;
		prep  <= 1'b1;
	end else if (prep & hb) begin            // floor division by repeated add/subtract during blanking
		if (rem < 0) begin
			rem <= rem + $signed({9'd0, aD});
			p   <= p - 1'd1;
		end else if (rem >= $signed({9'd0, aD})) begin
			rem <= rem - $signed({9'd0, aD});
			p   <= p + 1'd1;
		end else begin
			prep <= 1'b0;
		end
	end

	in_line <= ~hb;
	if (~hb) begin
		prep <= 1'b0;
		if (rem + 20'sd32 >= $signed({9'd0, aD})) begin
			rem <= rem + 20'sd32 - $signed({9'd0, aD});
			p   <= p + 1'd1;
		end else begin
			rem <= rem + 20'sd32;
		end
	end
	raddr <= {rbank, p[9:0]};
end

reg in_q1 = 1'b0;
always @(posedge clk) in_q1 <= ~hb & (p >= 0) & (p < $signed({2'b00, wlen}));
reg in_q2 = 1'b0;
always @(posedge clk) in_q2 <= in_q1;

wire [23:0] rs = (in_q2 & ~hb) ? q : 24'd0;

assign r_out = active ? rs[23:16] : r_in;
assign g_out = active ? rs[15:8]  : g_in;
assign b_out = active ? rs[7:0]   : b_in;

endmodule
