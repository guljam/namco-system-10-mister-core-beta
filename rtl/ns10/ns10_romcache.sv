//============================================================================
//  NS10 ROM cache: two 64 byte lines in front of the DDR3 ROM image.
//
//  The ROM board reads mostly sequentially (NAND pages, MEM(M) bank windows),
//  so after every demand access the next line is prefetched into the other
//  slot. One request at a time; rd_valid pulses when rd_data holds the beat.
//  Writes go straight to DDR3 and invalidate a cached copy of that line.
//
//  rq_beat is a 64 bit beat index inside the ROM area (byte address >> 3).
//============================================================================

module ns10_romcache
(
	input             clk1x,
	input             clk2x,
	input             reset,

	input      [28:0] ddr_base,      // beat address of ROM byte 0

	input             rq_rd,
	input             rq_wr,
	input      [22:0] rq_beat,
	input      [63:0] rq_wdata,
	input       [7:0] rq_be,
	output            rq_busy,
	output reg        rd_valid,
	output     [63:0] rd_data,

	// arbiter client (clk2x side)
	output reg        c_req,
	output reg        c_we,
	output reg [28:0] c_addr,
	output reg [63:0] c_din,
	output reg  [7:0] c_be,
	input             c_ack,
	input             c_rvalid,
	input      [63:0] c_rdata
);

// ------------------------------------------------------------------ line RAM (write clk2x, read clk1x)
reg  [63:0] lram[16];
reg   [2:0] wcnt;
reg   [3:0] lram_raddr;
reg  [63:0] lram_q;
reg         fill_slot;

// clk2x: fill beats go to {fill_slot, wcnt}; the counter restarts between requests
always @(posedge clk2x) begin
	if (c_rvalid & ~c_we) begin
		lram[{fill_slot, wcnt}] <= c_rdata;
		wcnt <= wcnt + 1'd1;
	end
	if (~c_req) wcnt <= 0;
end

always @(posedge clk1x) lram_q <= lram[lram_raddr];
assign rd_data = lram_q;

// ------------------------------------------------------------------ clk1x control
reg  [19:0] tag[2];
reg   [1:0] tvalid;
reg         mru;                 // slot of the last demand access
reg  [19:0] fill_tag;
reg         fill_is_pf;          // current engine operation is a prefetch fill

typedef enum logic [2:0] { S_IDLE, S_LOOKUP, S_READ, S_WAITACK, S_WAITREL } state_t;
state_t state;

reg  [22:0] beat;
reg         is_wr;
reg  [63:0] wdata;
reg   [7:0] wbe;
reg         pending;             // a demand request waits behind the engine

wire        hit0 = tvalid[0] & (tag[0] == beat[22:3]);
wire        hit1 = tvalid[1] & (tag[1] == beat[22:3]);
wire        hit  = hit0 | hit1;
wire        hslot = hit1;

wire [19:0] next_line = beat[22:3] + 1'd1;
wire        next_cached = (tvalid[0] & (tag[0] == next_line)) | (tvalid[1] & (tag[1] == next_line));

assign rq_busy = pending | (state != S_IDLE && !(state == S_WAITACK && fill_is_pf) && !(state == S_WAITREL && fill_is_pf));

always @(posedge clk1x) begin
	rd_valid <= 0;
	if (reset) begin
		state   <= S_IDLE;
		tvalid  <= 2'b00;
		c_req   <= 0;
		pending <= 0;
		mru     <= 0;
	end else begin
		if (rq_rd | rq_wr) begin
			beat    <= rq_beat;
			is_wr   <= rq_wr;
			wdata   <= rq_wdata;
			wbe     <= rq_be;
			pending <= 1;
		end

		case (state)
			S_IDLE: if (pending) begin
				pending <= 0;
				state   <= S_LOOKUP;
			end

			S_LOOKUP: begin
				if (is_wr) begin
					// write through to DDR3, drop a cached copy of the line
					if (hit0) tvalid[0] <= 0;
					if (hit1) tvalid[1] <= 0;
					c_we   <= 1;
					c_addr <= ddr_base + beat;
					c_din  <= wdata;
					c_be   <= wbe;
					c_req  <= 1;
					fill_is_pf <= 0;
					state  <= S_WAITACK;
				end else if (hit) begin
					lram_raddr <= {hslot, beat[2:0]};
					mru        <= hslot;
					state      <= S_READ;
				end else begin
					fill_slot  <= ~mru;
					fill_tag   <= beat[22:3];
					tvalid[~mru] <= 0;
					c_we       <= 0;
					c_addr     <= ddr_base + {beat[22:3], 3'b000};
					c_req      <= 1;
					fill_is_pf <= 0;
					state      <= S_WAITACK;
				end
			end

			S_READ: begin
				rd_valid <= 1;
				state    <= S_IDLE;
				// prefetch the following line into the other slot
				if (~next_cached) begin
					fill_slot  <= ~mru;
					fill_tag   <= next_line;
					tvalid[~mru] <= 0;
					c_we       <= 0;
					c_addr     <= ddr_base + {next_line, 3'b000};
					c_req      <= 1;
					fill_is_pf <= 1;
					state      <= S_WAITACK;
				end
			end

			S_WAITACK: if (c_ack) begin
				c_req <= 0;
				if (~c_we) begin
					tag[fill_slot]    <= fill_tag;
					tvalid[fill_slot] <= 1;
				end
				state <= S_WAITREL;
			end

			S_WAITREL: if (~c_ack) begin
				if (fill_is_pf) begin
					state <= S_IDLE;
				end else if (is_wr) begin
					state <= S_IDLE;
				end else begin
					state <= S_LOOKUP;   // demand fill done: now it hits
				end
				fill_is_pf <= 0;
			end

			default: state <= S_IDLE;
		endcase
	end
end

endmodule
