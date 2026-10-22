//============================================================================
//  NS10 settings region rebuild after a ROM load.
//
//  DDR3 fast loading (MRA <rom address="0x35000000">): Main_MiSTer copies the
//  ROM image straight into DDR3, so no ROM write passes the ROM cache and the
//  ns10_nvram BRAM copy of the settings region never sees the ROM data. The
//  copy would also overwrite a .nvm that was downloaded before the ROM.
//
//  So the .nvm download (ioctl index 2) goes to a staging area above the ROM
//  image, and when the ROM download has ended this block copies the region
//  beat by beat through the ROM cache: from the staging area if a .nvm was
//  loaded, otherwise from the ROM image onto itself. Each write lands in DDR3
//  and in the ns10_nvram BRAM. The same path works for a normal ioctl ROM
//  download (older Main_MiSTer ignores the address attribute).
//
//  ROM cache request port as used by ns10_romboard: one-clock rq_rd / rq_wr
//  pulses while rq_busy is low, rd_valid when rd_data holds the read beat.
//============================================================================

module ns10_nvload
(
	input             clk,
	input             start,         // one clock: ROM download ended
	input      [22:0] src,           // first source beat (staging or the region itself)
	input      [22:0] dst,           // first beat of the region
	input      [11:0] count,         // region size in beats
	output            busy,

	output reg        rq_rd,
	output reg        rq_wr,
	output reg [22:0] rq_beat,
	output reg [63:0] rq_wdata,
	input             rq_busy,
	input             rq_valid,
	input      [63:0] rq_data
);

typedef enum logic [1:0] { S_IDLE, S_RD, S_RDW, S_WR } state_t;
state_t state = S_IDLE;

reg  [22:0] s_beat, d_beat;
reg  [11:0] left;

assign busy = (state != S_IDLE);

always @(posedge clk) begin
	rq_rd <= 0;
	rq_wr <= 0;

	case (state)
		S_IDLE: if (start) begin
			s_beat <= src;
			d_beat <= dst;
			left   <= count;
			state  <= S_RD;
		end

		S_RD: if (!rq_busy && !rq_rd && !rq_wr) begin
			if (left == 0) begin
				state <= S_IDLE;
			end else begin
				rq_rd   <= 1;
				rq_beat <= s_beat;
				state   <= S_RDW;
			end
		end

		S_RDW: if (rq_valid) begin
			rq_wdata <= rq_data;
			state    <= S_WR;
		end

		S_WR: if (!rq_busy && !rq_rd && !rq_wr) begin
			rq_wr   <= 1;
			rq_beat <= d_beat;
			s_beat  <= s_beat + 1'd1;
			d_beat  <= d_beat + 1'd1;
			left    <= left - 1'd1;
			state   <= S_RD;
		end

		default: state <= S_IDLE;
	endcase
end

endmodule
