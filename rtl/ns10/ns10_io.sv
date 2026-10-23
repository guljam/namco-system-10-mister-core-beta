//============================================================================
//  Namco System 10 main board I/O on EXP3 (0x1FA00000-0x1FBFFFFF)
//  (MAME namcos10.cpp namcos10_map_inner, no EXIO board, no CD-ROM)
//
//  0x1FB40000-5FFFF  MEM(M) bank register (passed to the ROM board)
//  0x1FBA0000  SYSTEM   0xFF00 | ~dip
//  0x1FBA0002  EXIO ident: always 3 without an EXIO board
//  0x1FBA0004  IN1 low, 0x1FBA0006 IN1 high (active low)
//  0x1FBA0008  I2C clock, 0x1FBA000A I2C data (MAME byte-ACK device)
//  0x1FBA0012-19 int ack (clear bit (a-0x12)/2), 0x1FBA001A int status
//  0x1FBF0000  CD unknown: 1
//  I/O timer: int |= 8 and an IRQ10 pulse, at 100 Hz (MAME) or 2x VBlank.
//  The real IRQ10 source is unknown (MAME: TODO). The Driller input library stores IN1 on every
//  other IRQ10, so 2x VBlank = exactly one input sample per frame (docs/fixes-2026-10-23.md).
//  Driller sets (irq10_late) take the two IRQ10 at 5/8 and 7/8 of the frame, after both players'
//  updates (versus P2 ends up to ~6.5 ms after VBlank), for Drill (Auto) (docs/fixes-2026-10-24.md).
//============================================================================

module ns10_io
(
	input             clk,         // clk_1x (33.8688 MHz)
	input             reset,

	input             rd,
	input             wr,
	input      [20:0] addr,
	input      [15:0] wdata,
	output reg [15:0] rdata,

	input       [7:0] dip,         // 1 = switch on
	input      [31:0] in1,         // active low, MAME IN1 layout

	input             irq10_vbl,   // IRQ10 source: 0 = 100 Hz timer, 1 = 2x VBlank (1/4 and 3/4 of the frame)
	input             irq10_late,  // 2x VBlank at 5/8 and 7/8 of the frame
	input             vblank,      // GPU VBLANK interrupt line
	output reg        irq10,

	output            bank_rd,
	output            bank_wr,
	output     [15:0] bank_off,

	// savestate: 4 registers, read one clock after ss_addr
	input       [1:0] ss_addr,
	input      [31:0] ss_din,
	input             ss_wr,
	output reg [31:0] ss_dout
);

wire a_bank = (addr[20:17] == 4'hA);                 // 0x140000-0x15FFFF
wire a_io   = (addr[20:5] == 16'hD000);              // 0x1A0000-0x1A001F
wire a_cd   = (addr[20:4] == 17'h1F000);             // 0x1F0000-0x1F000F

assign bank_rd  = rd & a_bank;
assign bank_wr  = wr & a_bank;
assign bank_off = addr[16:1];

// ------------------------------------------------------------------ 100 Hz timer
localparam integer TIMER_PERIOD = 338688;            // 33868800 / 100
reg [18:0] tcnt;
reg [15:0] intr;

// ------------------------------------------------------------------ 2x VBlank: IRQ10 at 1/4 and 3/4 of the
// last frame length after each VBlank, away from the game's pad copy right after VBlank
localparam integer FRAME_NOM = 565050;               // 33868800 / 59.94
reg        vbl_1;
reg [19:0] fcnt, fper;
wire       vbl_rise = vblank & ~vbl_1;
wire       vbl_tick = irq10_late ?
	((fcnt == {1'b0, fper[19:1]} + {3'b000, fper[19:3]}) || (fcnt == fper - {3'b000, fper[19:3]})) :
	((fcnt == {2'b00, fper[19:2]}) || (fcnt == {2'b00, fper[19:2]} + {1'b0, fper[19:1]}));

// ------------------------------------------------------------------ I2C (MAME i2c_update)
localparam I2_IDLE = 2'd0, I2_BYTE = 2'd1, I2_ACK1 = 2'd2, I2_ACK0 = 2'd3;
reg  [1:0] i2_mode;
reg  [3:0] i2_bit;                                   // 7..0, 15 = done
reg        host_clk, host_dat, dev_dat;
reg        prev_clk, prev_dat;

wire       nclk  = (a_io && addr[4:1] == 4'd4 && wr) ? wdata[0] : host_clk;
wire       ndat  = (a_io && addr[4:1] == 4'd5 && wr) ? wdata[0] : host_dat;
wire       c     = nclk;                             // device clock is always 1
wire       d     = ndat & dev_dat;

always @(posedge clk) begin
	case (ss_addr)
		2'd0: ss_dout <= {2'd0, tcnt, i2_mode, i2_bit, host_clk, host_dat, dev_dat, prev_clk, prev_dat};
		2'd1: ss_dout <= {15'd0, vbl_1, intr};
		2'd2: ss_dout <= {12'd0, fcnt};
		2'd3: ss_dout <= {12'd0, fper};
	endcase
end

always @(posedge clk) begin
	irq10 <= 0;
	if (reset) begin
		tcnt     <= 0;
		intr     <= 0;
		vbl_1    <= 0;
		fcnt     <= 0;
		fper     <= FRAME_NOM[19:0];
		i2_mode  <= I2_IDLE;
		i2_bit   <= 0;
		host_clk <= 1;
		host_dat <= 1;
		dev_dat  <= 1;
		prev_clk <= 1;
		prev_dat <= 1;
	end else begin
		tcnt <= tcnt + 1'd1;
		if (tcnt == TIMER_PERIOD - 1) tcnt <= 0;

		vbl_1 <= vblank;
		if (vbl_rise) begin
			fcnt <= 0;
			fper <= fcnt;
		end else if (~&fcnt)
			fcnt <= fcnt + 1'd1;

		if (irq10_vbl ? (vbl_tick && !vbl_rise) : (tcnt == TIMER_PERIOD - 1)) begin
			intr[3]  <= 1;
			irq10    <= 1;
		end

		if (rd) begin
			rdata <= 16'h0000;
			if (a_io) case (addr[4:1])
				4'd0:  rdata <= {8'hFF, ~dip};
				4'd1:  rdata <= 16'h0003;
				4'd2:  rdata <= in1[15:0];
				4'd3:  rdata <= in1[31:16];
				4'd4:  rdata <= {15'd0, host_clk};
				4'd5:  rdata <= {15'd0, host_dat & dev_dat};
				4'd13: rdata <= intr;
				default: ;
			endcase
			if (a_cd) rdata <= 16'h0001;
		end

		if (wr && a_io) begin
			if (addr[4:1] >= 4'd9 && addr[4:1] <= 4'd12) intr[addr[4:1] - 4'd9] <= 1'b0;
		end

		if (wr && a_io && (addr[4:1] == 4'd4 || addr[4:1] == 4'd5)) begin
			host_clk <= nclk;
			host_dat <= ndat;
			if (c != prev_clk || d != prev_dat) begin
				prev_clk <= c;
				prev_dat <= d;
				case (i2_mode)
					I2_IDLE: if (c && !d) begin
						i2_bit  <= 4'd7;
						i2_mode <= I2_BYTE;
					end
					I2_BYTE: begin
						if (c && d && !prev_dat)
							i2_mode <= I2_IDLE;
						else if (c && !prev_clk) begin
							i2_bit <= i2_bit - 1'd1;
							if (i2_bit == 4'd0) begin
								i2_mode  <= I2_ACK1;
								dev_dat  <= 0;
								prev_dat <= 0;
							end
						end
					end
					I2_ACK1: if (c && !prev_clk) i2_mode <= I2_ACK0;
					I2_ACK0: if (!c && prev_clk) begin
						dev_dat  <= 1;
						prev_dat <= ndat;
						i2_bit   <= 4'd7;
						i2_mode  <= I2_BYTE;
					end
				endcase
			end
		end

		// savestate load
		if (ss_wr) begin
			case (ss_addr)
				2'd0: {tcnt, i2_mode, i2_bit, host_clk, host_dat, dev_dat, prev_clk, prev_dat} <= ss_din[29:0];
				2'd1: {vbl_1, intr} <= ss_din[16:0];
				2'd2: fcnt <= ss_din[19:0];
				2'd3: fper <= ss_din[19:0];
			endcase
		end
	end
end

endmodule
