//============================================================================
//  NS10 Drill (Auto): Button1 autofire synced to the Mr. Driller 2 / G landing
//
//  The game digs only on a new press (pad edge) and only once the player
//  stands with no cooldown (MAME traces, docs/fixes-2026-10-24.md). A fixed
//  on/off pattern misses the landing frame whenever the fall takes an odd
//  number of frames. So the drill is released while the player falls or waits
//  out the cooldown, and right after the game saw it pressed, and pressed
//  otherwise: a new press on the landing frame, on/off every frame standing.
//  Same algorithm as GroovyMAME namcos10.cpp drill_auto_fire (autofirefix).
//
//  The game state comes from shadow copies of 8 RAM words, updated from the
//  CPU writes and data reads on the SDRAM bus (the game reads all of them every
//  frame, so they also come back after a savestate load). The game stores one
//  IRQ10 read per frame; ns10_io puts both after the players' updates.
//
//  Release or OSD open: off at once.
//============================================================================

module ns10_autofire
(
	input            clk,
	input            reset,

	input      [1:0] game,         // 0 = none, 1 = Mr. Driller 2 (all regions), 2 = Mr. Driller G
	input            osd,          // OSD open: no autofire
	input      [1:0] btn,          // Drill (Auto) held, P2 P1
	output     [1:0] fire,         // Drill level to OR into Button1, P2 P1
	output    [27:0] dbg,          // debug trace: {pad P2 P1, fire, btn, versus, side, st1, st0, cooldown 1, cooldown 0}

	// PSX main RAM bus (SDRAM channel side, clk domain)
	input            ram_req,
	input            ram_rnw,
	input            ram_dma,
	input            ram_cache,
	input     [24:0] ram_addr,     // byte address, [24:23] = 0: main RAM
	input      [3:0] ram_be,
	input     [31:0] ram_wdata,
	input            ram_rdack,
	input     [31:0] ram_rdata
);

// ------------------------------------------------------------------ watched words (physical word addresses)
// 0/1 pad cur P1/P2 (bits 31:16, drill = bit 25), 2 mode, 3 side (s16 in 15:0),
// 4/5 player struct 0/1 state word (1 = standing, 2 = falling), 6/7 struct 0/1 word 0 (cooldown = bits 15:8)
localparam N = 8;
reg [21:2] wa[0:N-1];
reg  [7:0] vs0, vs1;               // versus game modes

always @(*) begin
	case (game)
	2'd2: begin   // Mr. Driller G: pad 0x80337DF0 (+0x10), struct 0x80369B40 (+0x1B4), state +0xD8
		wa[0] = 22'h337DF4 >> 2; wa[1] = 22'h337E04 >> 2; wa[2] = 22'h369B38 >> 2; wa[3] = 22'h2EF0E4 >> 2;
		wa[4] = 22'h369C18 >> 2; wa[5] = 22'h369DCC >> 2; wa[6] = 22'h369B40 >> 2; wa[7] = 22'h369CF4 >> 2;
		vs0 = 8'h0A; vs1 = 8'h12;  // Survival, Race
	end
	default: begin  // Mr. Driller 2: pad 0x8023F948 (+0x10), struct 0x80271698 (+0x180), state +0xA4
		wa[0] = 22'h23F94C >> 2; wa[1] = 22'h23F95C >> 2; wa[2] = 22'h271690 >> 2; wa[3] = 22'h20AD0C >> 2;
		wa[4] = 22'h27173C >> 2; wa[5] = 22'h2718BC >> 2; wa[6] = 22'h271698 >> 2; wa[7] = 22'h271818 >> 2;
		vs0 = 8'h0A; vs1 = 8'h0A;
	end
	endcase
end

// ------------------------------------------------------------------ shadow words
reg [31:0] sh[0:N-1];
reg [21:2] rd_a;
reg        rd_pend;

wire main = (ram_addr[24:23] == 2'b00);

always @(posedge clk) begin
	if (reset) begin
		for (int i = 0; i < N; i++) sh[i] <= 0;
		rd_pend <= 0;
	end else begin
		// one CPU request is outstanding at a time; the read data comes with ram_rdack
		if (ram_rdack && rd_pend) begin
			rd_pend <= 0;
			for (int i = 0; i < N; i++) if (rd_a == wa[i]) sh[i] <= ram_rdata;
		end
		if (ram_req) begin
			rd_a    <= ram_addr[21:2];
			rd_pend <= ram_rnw && !ram_dma && !ram_cache && main;
			if (!ram_rnw && !ram_dma && main)
				for (int i = 0; i < N; i++) if (ram_addr[21:2] == wa[i])
					for (int b = 0; b < 4; b++) if (ram_be[b]) sh[i][b*8 +: 8] <= ram_wdata[b*8 +: 8];
		end
	end
end

// ------------------------------------------------------------------ fire
wire versus = (sh[2] == {24'd0, vs0}) || (sh[2] == {24'd0, vs1});
wire side   = (sh[3][15:0] != 16'd0);   // a 1P game on the P2 side

// player struct falling, or standing with cooldown left
wire [1:0] blk = {
	(sh[5] == 32'd2) || (sh[5] == 32'd1 && sh[7][15:8] != 8'd0),
	(sh[4] == 32'd2) || (sh[4] == 32'd1 && sh[6][15:8] != 8'd0)
};

// P1 / P2 in the game: versus = struct 0 / 1; 1P = struct 0 on its side; else plain on/off
wire [1:0] p_blk = {versus ? blk[1] : (side & blk[0]), (versus | ~side) & blk[0]};

reg [1:0] fire_r;
assign fire = fire_r;

always @(posedge clk)
	fire_r <= (reset || osd || game == 2'd0) ? 2'b00 : btn & ~{sh[1][25], sh[0][25]} & ~p_blk;

assign dbg = {sh[1][25], sh[0][25], fire_r, btn, versus, side, sh[5][1:0], sh[4][1:0], sh[7][15:8], sh[6][15:8]};

endmodule
