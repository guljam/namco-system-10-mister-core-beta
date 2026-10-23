//============================================================================
//  Debug: 10 s GPU / DMA / IRQ event trace into DDR3 (tools/gputrace.py).
//
//  Started by 'trig' (OSD) or the In-System Sources and Probes instance
//  "GTRC" (source bit 0). Entries go to DDR3 byte 0x3A000000 (max 32 MB),
//  readable from MiSTer Linux through /dev/mem. 'text' is shown at the top
//  left while 'text_on': "REC n" (seconds left) while recording, then "DONE ".
//
//  Entry (64 bit): [63:60] type, [59:34] time (clk2x / 16 since the start),
//                  [33] GPU activeLineLSB, [32] GPU inVsync, [31:0] data.
//  1 GP0 header (word, NOP 00 not logged)   2 GP0 parameter of 02/80/A0/C0
//  3 end of 02/80/A0/C0 {opcode, words}     4 GP1 write
//  5/6/7 DMA2 MADR/BCR/CHCR write           8 DICR write
//  9 IRQ write {addr[3:0], data[27:0]}      A vblank start {GP0 headers, GPUSTAT reads}
//  B vblank start {DMA2 words[19:0], CPU GP0 writes[9:0], GPU idle, FIFO empty}
//  C GPU FIFO full                          D DMA2 burst start  E DMA2 burst end {words}
//  F control: data[31:28] 0 start {cfg[15:0], run[7:0]}, 1 end {lost[5:0], beats[21:0]},
//              2 DMA4 (SPU) write {reg[27:26] 0 MADR / 1 BCR / 2 CHCR, data[25:0]},
//              3 EXP3 write {addr[19:16], addr[7:0], data[15:0]} (MEM(M) bank 0x1FB4xxxx),
//              4 vblank: EXP1 reads (16 bit strobes) since the last vblank,
//              5 vblank: clk2x with the EXP1 wait (ROM board busy) since the last vblank,
//              6 Drill (Auto) state (ns10_autofire dbg[27:0]) on a change and at each vblank
//  Unused slots of the last burst are 0. The probe returns
//  {state[1:0], lost != 0, 7'd0, beats written[21:0]}.
//============================================================================

module ns10_gtrace #(parameter [25:0] TPS = 26'd4233600)   // ticks per second (67.7376 MHz / 16)
(
	input             clk,           // clk_2x

	input      [39:0] dbg_gpu,
	input      [43:0] dbg_bus,
	input             e1_rd,         // NS10 EXP1 / EXP3 bus (clk1x strobes)
	input             e1_wait,
	input             e3_wr,
	input      [20:0] e3_addr,
	input      [15:0] e3_data,
	input             trig,
	input      [27:0] af,            // ns10_autofire dbg (clk1x)
	input      [15:0] cfg,

	output reg        t_req = 0,
	output     [28:0] t_addr,
	output     [63:0] t_din,
	input       [2:0] t_beat,
	input             t_done,

	output reg [39:0] text,
	output            text_on
);

localparam [28:0] BASE     = 29'h07400000;           // byte 0x3A000000
localparam [21:0] MAXBEATS = 22'h3FF000;             // 32 MB, room for the FIFO contents

// ------------------------------------------------------------------ control state
localparam [1:0] C_IDLE = 2'd0, C_RUN = 2'd1, C_FLUSH = 2'd2, C_DONE = 2'd3;
reg   [1:0] cst = C_IDLE;
reg   [7:0] run = 0;
reg   [3:0] tdiv = 0;
reg  [25:0] tick = 0;
reg  [25:0] sub = 0;
reg   [3:0] sec = 0;
reg  [21:0] wptr = 0;        // beats written
reg   [5:0] lost = 0;
reg         end_req = 0;

wire  [0:0] jtrig;
reg   [2:0] trig_s = 0;
reg   [1:0] jtrig_s = 0;
wire        start = (trig_s[2:1] == 2'b01) || (jtrig_s == 2'b01);

ns10_probe #(.ID("GTRC")) probe
(
	.probe({32'd0, cst, |lost, 7'd0, wptr}),
	.source(jtrig)
);

wire rec = (cst == C_RUN);
assign text_on = (cst != C_IDLE);

// ------------------------------------------------------------------ taps
wire        g_ce    = dbg_gpu[39];
wire        g_wv    = dbg_gpu[32] & g_ce;
wire        g_idle  = dbg_gpu[33];
wire        g_done  = dbg_gpu[34] & g_ce;
wire        g_full  = dbg_gpu[35];
wire        g_lsb   = dbg_gpu[36];
wire        g_vs    = dbg_gpu[37];
wire        g_empty = dbg_gpu[38];
wire [31:0] g_word  = dbg_gpu[31:0];
wire  [7:0] g_op    = g_word[31:24];

wire        b_gw    = dbg_bus[39];
wire        b_gr    = dbg_bus[40];
wire        b_dw    = dbg_bus[41];
wire        b_iw    = dbg_bus[42];
wire        b_dmaw  = dbg_bus[43];
wire  [6:0] b_addr  = dbg_bus[38:32];
wire [31:0] b_data  = dbg_bus[31:0];

// entry: {type, time, activeLineLSB, inVsync, data}
wire [27:0] etm = {tick, g_lsb, g_vs};
function [63:0] ent(input [3:0] t, input [27:0] tm, input [31:0] d);
	ent = {t, tm, d};
endfunction

// ------------------------------------------------------------------ event slots, one drained per clock
localparam NS = 12;
localparam S_G = 0, S_DONE = 1, S_BUS = 2, S_DMA = 3, S_FA = 4, S_FB = 5, S_FULL = 6, S_CTL = 7, S_E3 = 8, S_X1 = 9, S_X2 = 10, S_AF = 11;
reg  [NS-1:0] pend = 0;
reg    [63:0] slot[NS];

// lowest pending index wins
wire [NS-1:0] dsel = pend & ~(pend - 1'd1);
wire [NS-1:0] busy = pend & ~dsel;   // a new event into one of these slots is lost
reg    [63:0] dslot;
integer i;
always @(*) begin
	dslot = 64'd0;
	for (i = 0; i < NS; i = i + 1) if (dsel[i]) dslot = slot[i];
end

reg   [1:0] par_left;
reg         vram_cmd;
reg   [7:0] vram_op;
reg  [23:0] vram_words;
reg  [15:0] f_hdr, f_stat;
reg  [19:0] f_dma;
reg   [9:0] f_gp0;
reg         vs_1, full_1;
reg         e1_rd_1, e3_wr_1;
reg  [27:0] af_1;
reg  [27:0] x_rd, x_wait;
reg         dma_on;
reg   [7:0] dma_gap;
reg  [31:0] dma_burst;

// FIFO
reg  [63:0] fram[1024];
reg   [9:0] fwa = 0, fra = 0;
reg  [10:0] fcnt = 0;
reg  [63:0] fq;
reg         fpush = 0;
reg  [63:0] fdin;
wire        fpop;

// DDR3 writer
localparam [2:0] W_IDLE = 3'd0, W_LOAD = 3'd1, W_CAP = 3'd2, W_REQ = 3'd3, W_WAIT = 3'd4;
reg   [2:0] wst = W_IDLE;
reg  [63:0] buf8[8];
reg   [3:0] lidx;

assign t_addr = BASE + {7'd0, wptr};
assign t_din  = buf8[t_beat];

assign fpop = (wst == W_LOAD) && (fcnt != 0);

always @(posedge clk) begin
	if (fpush) fram[fwa] <= fdin;
	fq <= fram[fra];
end

// put an event into slot s (counted as lost if the slot still holds an undrained one)
`define ADD(s, e) begin if (busy[s] && lost != 6'h3F) lost <= lost + 1'd1; pend[s] <= 1; slot[s] <= e; end

always @(posedge clk) begin
	trig_s  <= {trig_s[1:0], trig};
	jtrig_s <= {jtrig_s[0], jtrig[0]};

	// ---------------------------------------------------------------- time
	tdiv <= tdiv + 1'd1;
	if (tdiv == 4'd15) begin
		tick <= tick + 1'd1;
		if (sub == TPS - 1'd1) begin sub <= 0; if (sec != 4'd15) sec <= sec + 1'd1; end
		else sub <= sub + 1'd1;
	end

	// ---------------------------------------------------------------- drain (before the events: a new event re-arms its slot)
	fpush <= 0;
	if (pend != 0) begin
		pend <= pend & ~dsel;
		if (fcnt < 11'd1016) begin
			fpush <= 1;
			fdin  <= dslot;
		end else if (lost != 6'h3F)
			lost <= lost + 1'd1;
	end

	vs_1    <= g_vs;
	full_1  <= g_full;
	e1_rd_1 <= e1_rd;
	e3_wr_1 <= e3_wr;
	af_1    <= af;

	if (rec) begin
		// ------------------------------------------------------------ GPU
		if (g_wv) begin
			if (g_idle) begin
				if (g_op != 8'h00) begin
					`ADD(S_G, ent(4'h1, etm, g_word));
					if (f_hdr != 16'hFFFF) f_hdr <= f_hdr + 1'd1;
				end
				vram_cmd   <= (g_op == 8'h02) || (g_op >= 8'h80 && g_op <= 8'hDF);
				vram_op    <= g_op;
				vram_words <= 0;
				par_left   <= (g_op >= 8'h80 && g_op <= 8'h9F) ? 2'd3 :
				              ((g_op == 8'h02) || (g_op >= 8'hA0 && g_op <= 8'hDF)) ? 2'd2 : 2'd0;
			end else begin
				if (vram_words != 24'hFFFFFF) vram_words <= vram_words + 1'd1;
				if (par_left != 2'd0) begin
					par_left <= par_left - 1'd1;
					`ADD(S_G, ent(4'h2, etm, g_word));
				end
			end
		end
		if (g_done && vram_cmd) begin
			vram_cmd <= 0;
			`ADD(S_DONE, ent(4'h3, etm, {vram_op, vram_words}));
		end

		// ------------------------------------------------------------ CPU bus
		if (b_gw && b_addr == 7'h4) `ADD(S_BUS, ent(4'h4, etm, b_data));
		if (b_gw && b_addr == 7'h0 && f_gp0 != 10'h3FF) f_gp0 <= f_gp0 + 1'd1;
		if (b_gr && b_addr == 7'h4 && f_stat != 16'hFFFF) f_stat <= f_stat + 1'd1;
		if (b_dw && (b_addr == 7'h20 || b_addr == 7'h24 || b_addr == 7'h28 || b_addr == 7'h74))
			`ADD(S_BUS, ent((b_addr == 7'h20) ? 4'h5 : (b_addr == 7'h24) ? 4'h6 : (b_addr == 7'h28) ? 4'h7 : 4'h8, etm, b_data));
		if (b_iw) `ADD(S_BUS, ent(4'h9, etm, {b_addr[3:0], b_data[27:0]}));
		if (b_dw && (b_addr == 7'h40 || b_addr == 7'h44 || b_addr == 7'h48))
			`ADD(S_BUS, ent(4'hF, etm, {4'h2, b_addr[3:2], b_data[25:0]}));

		// ------------------------------------------------------------ NS10 ROM board bus
		if (e3_wr && !e3_wr_1) `ADD(S_E3, ent(4'hF, etm, {4'h3, e3_addr[19:16], e3_addr[7:0], e3_data}));
		if (e1_rd && !e1_rd_1 && x_rd != 28'hFFFFFFF) x_rd <= x_rd + 1'd1;
		if (e1_wait && x_wait != 28'hFFFFFFF) x_wait <= x_wait + 1'd1;

		// ------------------------------------------------------------ DMA2 bursts (gap >= 256 clk2x ends a burst)
		if (b_dmaw) begin
			if (f_dma != 20'hFFFFF) f_dma <= f_dma + 1'd1;
			dma_gap   <= 0;
			dma_burst <= dma_on ? dma_burst + 1'd1 : 32'd1;
			if (!dma_on) begin
				dma_on <= 1;
				`ADD(S_DMA, ent(4'hD, etm, 32'd0));
			end
		end else if (dma_on) begin
			if (dma_gap == 8'hFF) begin
				dma_on <= 0;
				`ADD(S_DMA, ent(4'hE, etm, dma_burst));
			end else
				dma_gap <= dma_gap + 1'd1;
		end

		// ------------------------------------------------------------ vblank, FIFO full
		if (g_vs && !vs_1) begin
			`ADD(S_FA, ent(4'hA, etm, {f_hdr, f_stat}));
			`ADD(S_FB, ent(4'hB, etm, {f_dma, f_gp0, g_idle, g_empty}));
			`ADD(S_X1, ent(4'hF, etm, {4'h4, x_rd}));
			`ADD(S_X2, ent(4'hF, etm, {4'h5, x_wait}));
			f_hdr <= 0; f_stat <= 0; f_dma <= 0; f_gp0 <= 0;
			x_rd <= 0; x_wait <= 0;
		end
		if (g_full && !full_1) `ADD(S_FULL, ent(4'hC, etm, 32'd0));
		if (af != af_1 || (g_vs && !vs_1)) `ADD(S_AF, ent(4'hF, etm, {4'h6, af}));
	end

	// ---------------------------------------------------------------- control
	case (cst)
		C_IDLE, C_DONE: if (start) begin
			cst  <= C_RUN;
			run  <= run + 1'd1;
			lost <= 0;
			wptr <= 0;
			tdiv <= 0; tick <= 0; sub <= 0; sec <= 0;
			f_hdr <= 0; f_stat <= 0; f_dma <= 0; f_gp0 <= 0;
			x_rd <= 0; x_wait <= 0;
			vram_cmd <= 0; par_left <= 0; dma_on <= 0;
			pend[S_CTL] <= 1;
			slot[S_CTL] <= {4'hF, 26'd0, 2'b00, 4'h0, 4'h0, cfg, run + 1'd1};
		end
		C_RUN: if (sec == 4'd10 || wptr >= MAXBEATS) begin
			cst     <= C_FLUSH;
			end_req <= 1;
		end
		C_FLUSH: begin
			if (end_req && !pend[S_CTL]) begin
				end_req <= 0;
				`ADD(S_CTL, ent(4'hF, etm, {4'h1, lost, wptr}));
			end
			if (!end_req && pend == 0 && fcnt == 0 && !fpush && wst == W_IDLE) cst <= C_DONE;
		end
		default: ;
	endcase

	// ---------------------------------------------------------------- status text
	case (cst)
		C_RUN:   text <= {"REC ", 8'h30 + ((sec < 4'd10) ? (4'd9 - sec) : 4'd0)};
		C_FLUSH: text <= "REC 0";
		default: text <= "DONE ";
	endcase

	// ---------------------------------------------------------------- FIFO pointers
	fcnt <= fcnt + (fpush ? 11'd1 : 11'd0) - (fpop ? 11'd1 : 11'd0);
	if (fpush) fwa <= fwa + 1'd1;
	if (fpop)  fra <= fra + 1'd1;

	// ---------------------------------------------------------------- DDR3 writer, 8 entries per burst
	case (wst)
		W_IDLE: begin
			lidx <= 0;
			if (fcnt >= 11'd8 || (cst == C_FLUSH && !end_req && pend == 0 && !fpush && fcnt != 0)) wst <= W_LOAD;
		end
		W_LOAD: begin
			if (fcnt == 0) begin
				// flush: pad the burst
				buf8[lidx[2:0]] <= 64'd0;
				lidx <= lidx + 1'd1;
				if (lidx == 4'd7) wst <= W_REQ;
			end else
				wst <= W_CAP;      // fq holds the popped entry next clock
		end
		W_CAP: begin
			buf8[lidx[2:0]] <= fq;
			lidx <= lidx + 1'd1;
			wst  <= (lidx == 4'd7) ? W_REQ : W_LOAD;
		end
		W_REQ: begin
			t_req <= 1;
			wst   <= W_WAIT;
		end
		W_WAIT: if (t_done) begin
			t_req <= 0;
			wptr  <= wptr + 22'd8;
			wst   <= W_IDLE;
		end
		default: wst <= W_IDLE;
	endcase
end

endmodule

`undef ADD
