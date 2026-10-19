//============================================================================
//  DDR3 port arbiter: PSX master (priority, combinational passthrough) and the
//  NS10 ROM board client (8 beat burst reads, single beat writes).
//
//  Same scheme as System573_MiSTer s573_ddram_arb: the client only gets the bus
//  when the PSX side is completely quiet (no command, no read beats in flight,
//  not inside a write burst). While the client command is on the bus the PSX
//  side sees BUSY. The first BURSTCNT beats returned after a client read are the
//  client's (the port is in-order and no PSX read was pending), they are hidden
//  from the PSX side.
//
//  Client handshake is 4-phase level (req/ack) from the clk_1x domain; this
//  module runs on DDRAM_CLK (clk_2x, same PLL, edge aligned).
//
//  Debug trace client (clk_2x domain, lowest priority): 8 beat write bursts,
//  t_din is the data of beat t_beat; t_done pulses after the last beat and
//  t_req must be low the cycle after t_done.
//============================================================================

module ns10_ddram_arb
(
	input             clk,
	input             rst,

	// real DDRAM port
	input             ddr_busy,
	output      [7:0] ddr_burstcnt,
	output     [28:0] ddr_addr,
	input      [63:0] ddr_dout,
	input             ddr_dout_ready,
	output            ddr_rd,
	output     [63:0] ddr_din,
	output      [7:0] ddr_be,
	output            ddr_we,

	// PSX master
	output            psx_busy,
	input       [7:0] psx_burstcnt,
	input      [28:0] psx_addr,
	output     [63:0] psx_dout,
	output            psx_dout_ready,
	input             psx_rd,
	input      [63:0] psx_din,
	input       [7:0] psx_be,
	input             psx_we,

	// NS10 client
	input             c_req,
	input             c_we,
	input      [28:0] c_addr,
	input      [63:0] c_din,
	input       [7:0] c_be,
	output reg        c_ack = 0,
	output reg        c_rvalid,
	output reg [63:0] c_rdata,

	// debug trace writer
	input             t_req,
	input      [28:0] t_addr,
	input      [63:0] t_din,
	output      [2:0] t_beat,
	output reg        t_done
);

localparam [2:0] D_IDLE = 3'd0, D_CMD = 3'd1, D_DATA = 3'd2, D_END = 3'd3, D_TDATA = 3'd4, D_TEND = 3'd5;
localparam [7:0] C_BURST = 8'd8;

reg  [2:0] dstate = D_IDLE;
reg  [3:0] beats = 0;
reg [11:0] rd_pend = 0;
reg  [7:0] wr_rem = 0;

wire psx_rd_acc = psx_rd & ~psx_busy;
wire psx_wr_acc = psx_we & ~psx_busy;
wire psx_rdy    = ddr_dout_ready & (dstate != D_DATA);
wire psx_idle   = ~psx_rd & ~psx_we & (rd_pend == 12'd0) & (wr_rem == 8'd0);

wire c_own = (dstate == D_CMD);
wire t_own = (dstate == D_TDATA);

assign ddr_addr       = t_own ? t_addr : c_own ? c_addr : psx_addr;
assign ddr_burstcnt   = t_own ? C_BURST : c_own ? (c_we ? 8'd1 : C_BURST) : psx_burstcnt;
assign ddr_din        = t_own ? t_din : c_own ? c_din : psx_din;
assign ddr_be         = t_own ? 8'hFF : c_own ? (c_we ? c_be : 8'hFF) : psx_be;
assign ddr_rd         = t_own ? 1'b0 : c_own ? ~c_we : psx_rd;
assign ddr_we         = t_own ? 1'b1 : c_own ?  c_we : psx_we;

assign psx_busy       = ddr_busy | c_own | t_own;
assign t_beat         = beats[2:0];
assign psx_dout       = ddr_dout;
assign psx_dout_ready = psx_rdy;

always @(posedge clk) begin
	c_rvalid <= 0;
	t_done   <= 0;
	if (rst) begin
		dstate  <= D_IDLE;
		rd_pend <= 0;
		wr_rem  <= 0;
		c_ack   <= 0;
	end else begin
		rd_pend <= rd_pend + (psx_rd_acc ? {4'd0, psx_burstcnt} : 12'd0) - (psx_rdy ? 12'd1 : 12'd0);
		if (psx_wr_acc) wr_rem <= (wr_rem == 8'd0) ? (psx_burstcnt - 8'd1) : (wr_rem - 8'd1);

		case (dstate)
			D_IDLE: if (c_req & ~c_ack & psx_idle) dstate <= D_CMD;
			else if (t_req & psx_idle) begin
				beats  <= 0;
				dstate <= D_TDATA;
			end
			D_CMD: if (!ddr_busy) begin
				beats <= 0;
				if (c_we) begin
					c_ack  <= 1;
					dstate <= D_END;
				end else
					dstate <= D_DATA;
			end
			D_DATA: if (ddr_dout_ready) begin
				c_rvalid <= 1;
				c_rdata  <= ddr_dout;
				beats    <= beats + 1'd1;
				if (beats == C_BURST[3:0] - 1'd1) begin
					c_ack  <= 1;
					dstate <= D_END;
				end
			end
			D_END: if (~c_req) begin
				c_ack  <= 0;
				dstate <= D_IDLE;
			end
			D_TDATA: if (!ddr_busy) begin
				beats <= beats + 1'd1;
				if (beats == C_BURST[3:0] - 1'd1) begin
					t_done <= 1;
					dstate <= D_TEND;
				end
			end
			D_TEND: dstate <= D_IDLE;
			default: dstate <= D_IDLE;
		endcase
	end
end

endmodule
