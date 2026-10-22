//============================================================================
//  CRT Adjust: picture position on the native 15 kHz analog output.
//
//  Moves the picture on a CRT by delaying HSync / VSync against the unchanged
//  pixel stream (blanking, DE and the timing the game sees stay native, so
//  the HDMI scaler, which frames the picture by DE, is not affected).
//
//  Each sync pulse is re-issued a fixed time after its input pulse: HSync
//  -hpos * 16 clocks, VSync -hpos * 16 - vpos * line + vline * line clocks,
//  negative offsets taken from the next period (= earlier). A time shift keeps
//  the rest of the sync waveform, in particular the half-line VSync offset of
//  the PSX GPU's 480i fields (gpu_videoout_async: 263 / 262 line fields, VSync
//  half a line later in one of them). The VSync-to-VSync interval alternates
//  there, so the period a negative offset is taken from is the one two pulses
//  back (equal to the last one for 240p). Moving VSync to whole HSync edges instead (as for
//  240p only cores) would merge the two fields on the CRT.
//
//    hpos  : signed steps of 16 clocks (640 wide: 4 pixels, 320 wide: 2), + = right
//    vpos  : signed lines, + = down
//    vline : 1 = delay VSync one more line (CRT H-Size line buffer delay)
//
//  While enabled both syncs always pass the same one clock register stage (an
//  offset of 0 included), so HSync and VSync keep their relative timing: PSX
//  VSync starts on the same clock as an HSync (or half a line in). One clock
//  apart, the sys_top csync (YPbPr sync on Y) gets a one clock glitch and a
//  malformed first VSync line, and the CRT jitters (H-Position 0 with H-Size or
//  V-Position set). Disabled = exact passthrough.
//
//  Periods and pulse widths are measured from the incoming syncs (clk =
//  CLK_VIDEO), so all PSX display modes (NTSC / PAL, 240p / 480i) work.
//============================================================================

module crt_sync
(
	input              clk,
	input              enable,
	input signed [4:0] hpos,
	input signed [4:0] vpos,
	input              vline,
	input              hs_in,
	input              vs_in,
	output             hs_out,
	output             vs_out
);

wire [20:0] lper;                // line period in clocks
reg  signed [22:0] oh = 0, ov = 0;

always @(posedge clk) begin
	if (!enable || lper == 0) begin
		oh <= 0;
		ov <= 0;
	end else begin
		oh <= -(hpos * 23'sd16);
		ov <= -(hpos * 23'sd16) - vpos * $signed({2'b00, lper}) + (vline ? $signed({2'b00, lper}) : 23'sd0);
	end
end

wire hs_d, vs_d;
crt_sync_dly hdly(.clk(clk), .off(oh), .sig(hs_in), .per(lper), .out(hs_d));
crt_sync_dly vdly(.clk(clk), .off(ov), .sig(vs_in), .per(),     .out(vs_d));

assign hs_out = enable ? hs_d : hs_in;
assign vs_out = enable ? vs_d : vs_in;

endmodule

// One periodic sync signal shifted by off clocks: each input pulse starts a
// countdown of off mod (predicted next period) clocks, then an output pulse of
// the measured width. The output always comes off + 1 clocks after the input
// (off = 0: the input one clock late), so two syncs keep their alignment. |off| < period.
module crt_sync_dly
(
	input                     clk,
	input signed       [22:0] off,
	input                     sig,
	output             [20:0] per,
	output                    out
);

reg        sig_d = 0;
reg [20:0] cnt = 0, p1 = 0, width = 0;
reg [20:0] d = 0, start_cd = 0, on_left = 0;
reg        start_pend = 0, o = 0;

// Delay for the next pulse, registered, so at an input rise it still uses p1 from before the
// rise: the period before the one just ended. For a negative offset the pulse belongs |off|
// before the following rise, i.e. one period after this one: for 240p every period is the
// same, for 480i they alternate and the following period equals the one before the last.
wire signed [22:0] pr = $signed({2'b00, p1});

always @(posedge clk) begin
	sig_d <= sig;

	d <= (off < 0) ? off + pr : (off >= pr) ? off - pr : off;

	if (sig & ~sig_d) begin
		p1  <= cnt + 1'd1;
		cnt <= 0;
		start_cd   <= (d == 0) ? 21'd1 : d;
		start_pend <= 1;
	end else begin
		if (~&cnt) cnt <= cnt + 1'd1;
		if (start_pend) begin
			if (start_cd <= 1) begin
				start_pend <= 0;
				o          <= 1;
				on_left    <= width;
			end else begin
				start_cd <= start_cd - 1'd1;
			end
		end
	end
	if (~sig & sig_d) width <= cnt + 1'd1;

	if (o) begin
		if (on_left <= 1) o <= 0;
		else on_left <= on_left - 1'd1;
	end
end

assign per = p1;
assign out = (off == 0) ? sig_d : o;

endmodule
