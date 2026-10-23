//============================================================================
//  NS10 Drill (Auto): Button1 autofire synced to the game's input sampling
//
//  Mr. Driller 2 / G read IN1 (0x1FBA0004) in the 100 Hz IRQ10 handler but
//  store only every other sample, so the game sees inputs at 50 Hz (MAME,
//  tools/mame/tap_input.lua). Toggling every 2nd IN1 low read gives every
//  stored sample the opposite level of the one before: 25 presses/s, none lost,
//  whichever of the two reads the game keeps. A vblank toggle (30 Hz) would
//  alias to ~20 irregular presses/s.
//
//  Press: on at once, first toggle after 2 reads (one of them is stored).
//  Release or OSD open: off at once; held over OSD close restarts with on.
//============================================================================

module ns10_autofire
(
	input            clk,
	input            reset,

	input            in_rd,        // CPU read of IN1 low (one or more clocks per access)
	input            osd,          // OSD open: no autofire
	input      [1:0] btn,          // Drill (Auto) held, P2 P1
	output reg [1:0] fire          // Drill level to OR into Button1, P2 P1
);

reg       in_rd_1;
reg [1:0] act_1;
reg [1:0] cnt;                     // reads since the last toggle, per player

wire       sample = in_rd & ~in_rd_1;
wire [1:0] act    = btn & {2{~osd}};

always @(posedge clk) begin
	in_rd_1 <= in_rd;
	act_1   <= act;
	for (int p = 0; p < 2; p++) begin
		if (reset || !act[p]) begin
			fire[p] <= 0;
			cnt[p]  <= 0;
		end else if (!act_1[p]) begin
			fire[p] <= 1;
			cnt[p]  <= 0;
		end else if (sample) begin
			// the read in this clock latches the current level (ns10_io rdata)
			cnt[p] <= ~cnt[p];
			if (cnt[p]) fire[p] <= ~fire[p];
		end
	end
end

endmodule
