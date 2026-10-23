//============================================================================
//  Namco System 10 ROM boards (MAME namcos10.cpp, bit-exact model in
//  tools/ns10model.py)
//
//  MEM(M)  (board_type 0): Intel 28F640J5 flash 8 MB at ROM 0x000000,
//          data ROMs at ROM 0x800000, 1 MWord windows at 0x1F400000 selected
//          by the bank register at 0x1FB40000 + 2*bank, type 1 decrypter.
//  MEM(N)  (board_type 1): up to 8 Samsung K9F2808U0B/K9F5608U0D NANDs at
//          ROM idx*nand_stride, 528 byte pages, command/address/data registers
//          at 0x1F41xxxx..0x1F47xxxx, type 2 decrypter.
//  Not MEM(M): board RAM at 0x1F500000-0x1F5FFFFF (BIOS NAND block table),
//          16 KB mirrored.
//
//  All ROM bytes live in DDR3 (ns10_romcache). Bus accesses arrive as one
//  clock strobes; 'busy' (= EXP1 wait) is raised the clock after a strobe
//  that needs more than one clock and drops when rdata is valid.
//
//  The boot copy builds the 4 MB BIOS image in SDRAM the way MAME's driver
//  init does (MEM(N): NAND0 pages 0x40.. / 0x120.., MEM(M): flash 0..0x61FFF,
//  unscramble(w ^ xor), rest 0x55). 'reset' must be the board (cold) reset,
//  not the CPU reset: the CPU is held while boot_busy is set.
//
//  Savestate (type 17 dword index, only while the CPU is paused and the board
//  is idle): 0x0000-0x1FFF board RAM words, 0x2000-0x23FF NAND page register
//  bytes, 0x2400-0x241F registers. ss_dout is valid one clock after ss_addr.
//============================================================================

module ns10_romboard
(
	input             clk,
	input             reset,

	// configuration
	input       [1:0] board_type,
	input       [3:0] nand_count,
	input      [25:0] nand_stride,
	input      [16:0] nand_pages,
	input       [7:0] nand_id1,

	// EXP1 bus (0x1F000000-0x1F7FFFFF)
	input             rd,
	input             wr,
	input      [22:0] addr,
	input      [15:0] wdata,
	input       [1:0] be,            // write byte lanes; odd address: byte in wdata[7:0]
	output reg [15:0] rdata,
	output            busy,

	// MEM(M) bank register window (0x1FB40000-0x1FB5FFFF), word offset
	input             bank_rd,
	input             bank_wr,
	input      [15:0] bank_off,

	// crypt block
	output reg        crypt_switch_we,
	output reg [15:0] crypt_switch_data,
	input             crypt_active,
	input             crypt_busy,
	output reg        crypt_req,
	output reg [15:0] crypt_in,
	input      [15:0] crypt_out,
	output reg [15:0] us_in,
	input      [15:0] us_out,

	// ROM cache
	output reg        rq_rd,
	output reg        rq_wr,
	output reg [22:0] rq_beat,
	output reg [63:0] rq_wdata,
	output reg  [7:0] rq_be,
	input             rq_busy,
	input             rq_valid,
	input      [63:0] rq_data,

	// boot copy: BIOS image to SDRAM
	input             boot_start,
	output            boot_busy,
	output reg        bw_req,
	output reg [21:0] bw_addr,
	output reg [31:0] bw_data,
	input             bw_done,

	// savestate
	input             ss_active,
	input      [13:0] ss_addr,
	input      [31:0] ss_din,
	input             ss_wr,
	output     [31:0] ss_dout
);

localparam BT_MEMM = 2'd0, BT_MEMN = 2'd1;

// ======================================================================== MEM(M) state
reg   [4:0] bank;
reg         direct;
// Intel flash
localparam FM_NORMAL = 3'd0, FM_STATUS = 3'd1, FM_ID = 3'd2, FM_WRITE = 3'd3, FM_CLEAR = 3'd4,
           FM_MASTER = 3'd5, FM_WB1 = 3'd6, FM_WB2 = 3'd7;
reg   [2:0] fmode;
reg   [7:0] fstatus;
reg         master_lock;
reg  [15:0] wb[16];                  // write buffer (command E8)
reg   [4:0] wb_count, wb_n;
reg  [19:0] wb_start;
reg  [19:0] fp_word;                 // word program: flash word (bank ignored), data
reg  [15:0] fp_data;
reg         fp_wb;                   // program comes from the write buffer

// ======================================================================== MEM(N) state
localparam NM_INIT = 3'd0, NM_READ = 3'd1, NM_PROG = 3'd2, NM_ERASE = 3'd3, NM_STATUS = 3'd4, NM_ID = 3'd5;
localparam PM_A = 2'd0, PM_B = 2'd1, PM_C = 2'd2;

reg   [2:0] idx;
reg  [15:0] ctrl;
reg  [23:0] nand_address;            // MAME m_nand_address (block 0/1 bypass test)

reg   [2:0] n_mode  [8];
reg   [1:0] n_pm    [8];
reg  [15:0] n_page  [8];
reg  [11:0] n_byte  [8];
reg   [1:0] n_ptr   [8];
reg   [7:0] n_status[8];
reg  [10:0] prog_count;

wire        dev_ok   = ({1'b0, idx} < nand_count);
wire  [2:0] cm       = n_mode[idx];
wire  [1:0] cpm      = n_pm[idx];
wire [15:0] cpage    = n_page[idx];
wire [11:0] cbyte    = n_byte[idx];
wire  [1:0] cptr     = n_ptr[idx];

// device base, page offset
wire [25:0] dev_base   = nand_stride * idx;
wire [25:0] page_off   = {cpage, 9'd0} + {cpage, 4'd0};
wire [25:0] nand_byte  = dev_base + page_off + cbyte;
wire        nand_rd_in = (cbyte < 12'd528) && ({1'b0, cpage} < nand_pages);

// page register (528 bytes)
reg   [7:0] pagereg[1024];
reg   [9:0] pr_addr;
reg   [7:0] pr_wdata;
reg         pr_we;
reg   [7:0] pr_q;
wire        ss_pr_we = ss_wr && (ss_addr[13:10] == 4'b1000);
always @(posedge clk) begin
	if (ss_pr_we) pagereg[ss_addr[9:0]] <= ss_din[7:0];
	else if (pr_we) pagereg[pr_addr] <= pr_wdata;
	pr_q <= pagereg[ss_active ? ss_addr[9:0] : pr_addr];
end

// ======================================================================== board RAM (0x1F500000)
wire        a_sram  = (board_type != BT_MEMM) && (addr[22:20] == 3'b101);
wire        sram_we = wr && a_sram;
wire        sram_wl = sram_we && !addr[0] && be[0];
wire        sram_wh = sram_we && (addr[0] || be[1]);
wire  [7:0] sram_dh = addr[0] ? wdata[7:0] : wdata[15:8];
reg   [7:0] sram_lo[8192], sram_hi[8192];
reg  [15:0] sram_q;
wire        ss_sram_we = ss_wr && !ss_addr[13];
wire [12:0] sram_wa = ss_sram_we ? ss_addr[12:0] : addr[13:1];
wire [12:0] sram_ra = ss_active ? ss_addr[12:0] : addr[13:1];

always @(posedge clk) begin
	if (sram_wl | ss_sram_we) sram_lo[sram_wa] <= ss_sram_we ? ss_din[7:0]  : wdata[7:0];
	if (sram_wh | ss_sram_we) sram_hi[sram_wa] <= ss_sram_we ? ss_din[15:8] : sram_dh;
	sram_q <= {sram_hi[sram_ra], sram_lo[sram_ra]};
end

// ======================================================================== main FSM
typedef enum logic [4:0] {
	S_IDLE,
	S_NWR2,          // MEM(N) data write: low byte into the page register
	S_NRD_BYTE,      // MEM(N) data read: produce one byte
	S_NRD_WAIT,
	S_MRD_WAIT,      // MEM(M) raw word read
	S_SRAM_RD,       // board RAM read
	S_RAW_DONE,      // raw word complete: decrypt / unscramble
	S_CRYPT_WAIT,
	S_CRYPT_OUT1,
	S_CRYPT_OUT2,
	S_PR_CLEAR,      // NAND 0x80: page register := FF
	S_PROG_RD,       // NAND 0x10: beat read-modify-write loop
	S_PROG_RDW,
	S_PROG_AND,
	S_ERASE,         // NAND 0xD0 / flash D0: FF fill
	S_WB_COMMIT,     // flash E8 ... D0: write buffer to the array
	S_FPROG_RD,      // flash word program: read-modify-write
	S_FPROG_RDW,
	S_CACHE_WAIT,    // wait for a posted cache write
	S_BOOT,          // boot copy
	S_BOOT_RD,
	S_BOOT_RDW,
	S_BOOT_US1,
	S_BOOT_US2,
	S_BOOT_WR,
	S_BOOT_WRW
} state_t;
state_t state;

assign busy = (state != S_IDLE);

reg         boot_act;
assign boot_busy = boot_act;

reg         second;          // MEM(N) data read: producing the low byte
reg  [15:0] raw;
reg   [1:0] post;            // 0 raw, 1 decrypt or unscramble, 3 decrypt or raw
reg         bypass;          // MEM(N) block 0/1 bypass
reg         use_crypt;
reg  [25:0] op_byte;         // ROM byte address of the current operation
reg  [12:0] op_cnt;
reg   [2:0] lane;
reg  [63:0] beatbuf;
// last beat read through the cache: sequential MEM(M) window reads hit it without a cache round trip
reg         lat_v;
reg  [22:0] lat_beat;
reg  [63:0] lat_data;
reg   [9:0] pr_base;
reg         prog_next;
reg   [7:0] wlo;
wire [20:0] wb_end  = wb_start + wb_count;
wire [19:0] wb_addr = wb_start + op_cnt[3:0];

// boot copy
reg  [21:0] b_off;           // BIOS byte offset, step 4
reg  [31:0] b_word;
reg         b_fill;

wire  [7:0] beat_byte = rq_data[{op_byte[2:0], 3'b000} +: 8];

// address decode (EXP1 offsets)
wire        a_word0  = (addr[15:1] == 15'd0);
wire        a_crypt  = a_word0 && ((addr[22:16] == 7'h30) || (board_type == BT_MEMN && addr[22:16] == 7'h38));
wire        a_mwin   = (addr[22:21] == 2'b10);               // 0x400000-0x5FFFFF
wire [19:0] woff     = addr[20:1];
wire [21:0] fl_word  = {bank[1:0], woff};                   // flash word inside 8 MB
wire [25:0] mm_byte  = bank[4] ? (26'h0800000 + {1'b0, bank[3:0], woff, 1'b0}) : {3'd0, fl_word, 1'b0};

// next NAND byte pointer while writing the page register
function [11:0] next_pbyte(input [11:0] b, input [1:0] pm);
	if (b + 1'd1 == 12'd528) next_pbyte = (pm == PM_C) ? 12'd512 : 12'd0;
	else                     next_pbyte = b + 1'd1;
endfunction

wire [16:0] boot_page = (b_off < 22'h20000) ? ({4'd0, b_off[21:9]} + 17'h40) : ({4'd0, b_off[21:9]} + 17'h20);
wire [25:0] boot_nand = {boot_page, 9'd0} + {boot_page, 4'd0} + {17'd0, b_off[8:0]};

// ======================================================================== savestate registers (0x2400 + r)
wire        ss_rg_we = ss_wr && (ss_addr[13:5] == 9'h120);
wire  [4:0] ss_r     = ss_addr[4:0];
wire  [2:0] ss_dev   = ss_addr[2:0];
wire  [3:0] ss_wbk   = ss_r[3:0] - 4'd2;           // write buffer pair 0..7 (r 2..9)
reg  [31:0] ss_rg_q;
reg         ss_a13, ss_pr;

always @(posedge clk) begin
	ss_a13 <= ss_addr[13];
	ss_pr  <= (ss_addr[13:10] == 4'b1000);
	ss_rg_q <= 32'd0;
	casez (ss_r)
		5'd0:     ss_rg_q <= {4'd0, bank, direct, fmode, fstatus, master_lock, wb_count, wb_n};
		5'd1:     ss_rg_q <= {12'd0, wb_start};
		5'd2, 5'd3, 5'd4, 5'd5, 5'd6, 5'd7, 5'd8, 5'd9:
		          ss_rg_q <= {wb[{ss_wbk[2:0], 1'b1}], wb[{ss_wbk[2:0], 1'b0}]};
		5'd10:    ss_rg_q <= {13'd0, idx, ctrl};
		5'd11:    ss_rg_q <= {8'd0, nand_address};
		5'd12:    ss_rg_q <= {21'd0, prog_count};
		5'b10???: ss_rg_q <= {1'b0, n_mode[ss_dev], n_pm[ss_dev], n_ptr[ss_dev], n_status[ss_dev], n_page[ss_dev]};
		5'b11???: ss_rg_q <= {20'd0, n_byte[ss_dev]};
		default: ;
	endcase
end

assign ss_dout = !ss_a13 ? {16'd0, sram_q} : ss_pr ? {24'd0, pr_q} : ss_rg_q;

integer i;

always @(posedge clk) begin
	rq_rd           <= 0;
	rq_wr           <= 0;
	crypt_req       <= 0;
	crypt_switch_we <= 0;
	pr_we           <= 0;
	bw_req          <= 0;

	if (reset) begin
		state        <= S_IDLE;
		boot_act     <= 0;
		bank         <= 0;
		direct       <= 0;
		fmode        <= FM_NORMAL;
		fstatus      <= 8'h80;
		master_lock  <= 0;
		idx          <= 0;
		ctrl         <= 0;
		nand_address <= 0;
		prog_next    <= 0;
		lat_v        <= 0;
		for (i = 0; i < 8; i = i + 1) begin
			n_mode[i]   <= NM_INIT;
			n_pm[i]     <= PM_A;
			n_page[i]   <= 0;
			n_byte[i]   <= 0;
			n_ptr[i]    <= 0;
			n_status[i] <= 8'hC0;
		end
	end else begin

		// ---------------------------------------------------------------- MEM(M) bank register window (EXP3)
		if (board_type == BT_MEMM) begin
			if (bank_wr) begin
				bank   <= bank_off[4:0];
				direct <= (bank_off >= 16'h10);
			end
			if (bank_rd) direct <= 1;
		end

		case (state)

		// ================================================================ idle: decode a bus strobe
		S_IDLE: begin
			if (boot_start) begin
				boot_act <= 1;
				b_off    <= 0;
				state    <= S_BOOT;
			end

			if (wr) begin
				lat_v <= 0;             // any write may start a flash program / erase
				if (a_crypt) begin
					crypt_switch_we   <= 1;
					crypt_switch_data <= wdata;
				end

				// ------------------------------------------------ MEM(M): Intel 28F640J5 command / data
				if (board_type == BT_MEMM && a_mwin && !direct) begin
					// writes ignore the bank (MAME namcos10_memm_state::nand_w)
					case (fmode)
						FM_WRITE: begin
							// programming only clears bits (MAME intelfsh: m_data &= data)
							fp_word  <= woff;
							fp_data  <= wdata;
							fp_wb    <= 0;
							fstatus  <= 8'h80;
							fmode    <= FM_STATUS;
							state    <= S_FPROG_RD;
						end
						FM_CLEAR: if (wdata[7:0] == 8'hD0) begin
							// 64 KB block; MAME reports 0x00 for 1 s, here the erase is done at once
							op_byte <= {5'd0, woff[19:15], 16'd0};
							op_cnt  <= 13'd8191;
							state   <= S_ERASE;
							fstatus <= 8'h80;
							fmode   <= FM_STATUS;
						end
						FM_MASTER: begin
							if (wdata[7:0] == 8'hF1) master_lock <= 1;
							if (wdata[7:0] == 8'hD0) master_lock <= 0;
							fmode <= FM_STATUS;
						end
						FM_WB1: begin
							wb_count <= (wdata > 16'h000F) ? 5'd16 : {1'b0, wdata[3:0]} + 5'd1;
							wb_n     <= 0;
							fstatus  <= 8'h80;
							fmode    <= FM_WB2;
						end
						FM_WB2: begin
							if (wb_n < wb_count) begin
								if (wb_n == 5'd0) wb_start <= woff;
								if (wb_n != 5'd0 && {1'b0, woff} >= wb_end) begin
									fstatus <= 8'h30;
									fmode   <= FM_STATUS;
								end else begin
									wb[wb_n[3:0]] <= wdata;
									wb_n <= wb_n + 1'd1;
								end
							end else begin
								if (wdata[7:0] == 8'hD0) begin
									fstatus <= 8'h80;
									op_cnt  <= 0;
									state   <= S_WB_COMMIT;
								end else
									fstatus <= 8'h30;
								fmode <= FM_STATUS;
							end
						end
						default: case (wdata[7:0])
							8'hF0, 8'hFF: fmode <= FM_NORMAL;
							8'h90:        fmode <= FM_ID;
							8'h40, 8'h10: fmode <= FM_WRITE;
							8'h50:        begin fstatus <= 8'h80; fmode <= FM_STATUS; end
							8'h20:        fmode <= FM_CLEAR;
							8'h60:        fmode <= FM_MASTER;
							8'h70:        fmode <= FM_STATUS;
							8'hE8:        fmode <= FM_WB1;
							default: ;
						endcase
					endcase
				end

				// ------------------------------------------------ MEM(N) registers
				if (board_type == BT_MEMN && a_word0) begin
					case (addr[22:16])
						7'h41: if (dev_ok) begin
							case (wdata[7:0])
								8'h80: begin
									n_mode[idx] <= NM_PROG;
									n_ptr[idx]  <= 0;
									prog_count  <= 0;
									pr_addr     <= 0;
									state       <= S_PR_CLEAR;
								end
								8'h10, 8'h15: begin
									n_mode[idx] <= NM_INIT;
									if (cm == NM_PROG) begin
										n_status[idx] <= (n_status[idx] & 8'h80) | 8'h40;
										op_byte <= dev_base + page_off;
										pr_base <= 0;
										op_cnt  <= 13'd65;
										state   <= S_PROG_RD;
									end
								end
								8'hD0: begin
									n_mode[idx] <= NM_INIT;
									if (cm == NM_ERASE) begin
										n_status[idx] <= (n_status[idx] & 8'h80) | 8'h40;
										if (cpm == PM_B) n_pm[idx] <= PM_A;
										op_byte <= dev_base + {cpage[15:5], 5'd0, 9'd0} + {cpage[15:5], 5'd0, 4'd0};
										op_cnt  <= 13'd2111;
										state   <= S_ERASE;
									end
								end
								8'hFF: begin n_mode[idx] <= NM_INIT; n_pm[idx] <= PM_A; n_status[idx] <= (n_status[idx] & 8'h80) | 8'h40; end
								8'h00: begin n_mode[idx] <= NM_READ; n_pm[idx] <= PM_A; n_ptr[idx] <= 0; end
								8'h01: begin n_mode[idx] <= NM_READ; n_pm[idx] <= PM_B; n_ptr[idx] <= 0; end
								8'h50: begin n_mode[idx] <= NM_READ; n_pm[idx] <= PM_C; n_ptr[idx] <= 0; end
								8'h60: begin n_mode[idx] <= NM_ERASE; n_page[idx] <= 0; n_ptr[idx] <= 0; end
								8'h70: n_mode[idx] <= NM_STATUS;
								8'h90: begin n_mode[idx] <= NM_ID; n_ptr[idx] <= 0; end
								default: n_mode[idx] <= NM_INIT;
							endcase
						end
						7'h42, 7'h43, 7'h44: begin
							if (addr[22:16] == 7'h42) nand_address[7:0]   <= wdata[7:0];
							if (addr[22:16] == 7'h43) nand_address[15:8]  <= wdata[7:0];
							if (addr[22:16] == 7'h44) nand_address[23:16] <= wdata[7:0];
							if (dev_ok) begin
								case (cm)
									NM_READ, NM_PROG: begin
										if (cptr == 2'd0) begin
											n_page[idx] <= 0;
											case (cpm)
												PM_A:    n_byte[idx] <= {4'd0, wdata[7:0]};
												PM_B:    begin n_byte[idx] <= {4'd0, wdata[7:0]} + 12'd256; n_pm[idx] <= PM_A; end
												default: n_byte[idx] <= {8'd0, wdata[3:0]} + 12'd512;
											endcase
										end
										else if (cptr == 2'd1) n_page[idx][7:0]  <= wdata[7:0];
										else if (cptr == 2'd2) n_page[idx][15:8] <= wdata[7:0];
										if (cptr != 2'd3) n_ptr[idx] <= cptr + 1'd1;
									end
									NM_ERASE: begin
										if (cptr == 2'd0)      n_page[idx][7:0]  <= wdata[7:0];
										else if (cptr == 2'd1) n_page[idx][15:8] <= wdata[7:0];
										if (cptr != 2'd3) n_ptr[idx] <= cptr + 1'd1;
									end
									NM_ID: begin
										if (cptr == 2'd0) n_byte[idx] <= {4'd0, wdata[7:0]};
										if (cptr != 2'd3) n_ptr[idx] <= cptr + 1'd1;
									end
									default: ;
								endcase
							end
						end
						7'h45: if (dev_ok && cm == NM_PROG) begin
							// high byte first, low byte next clock
							if (prog_count < 11'd528) begin
								pr_we    <= 1;
								pr_addr  <= cbyte[9:0];
								pr_wdata <= wdata[15:8];
							end
							prog_count  <= prog_count + 1'd1;
							n_byte[idx] <= next_pbyte(cbyte, cpm);
							wlo   <= wdata[7:0];
							state <= S_NWR2;
						end
						7'h46: if ((ctrl & 16'd4) == 16'd0) idx <= wdata[2:0];
						7'h47: ctrl <= wdata;
						default: ;
					endcase
				end
			end

			if (rd) begin
				rdata <= 16'h0000;
				if (a_sram) state <= S_SRAM_RD;
				// ------------------------------------------------ MEM(M) window
				if (board_type == BT_MEMM && a_mwin) begin
					if (!direct) begin
						case (fmode)
							FM_ID:             rdata <= (fl_word[7:0] == 8'd0) ? 16'h0089 : (fl_word[7:0] == 8'd1) ? 16'h0015 :
							                            (fl_word[7:0] == 8'd3) ? {15'd0, master_lock} : 16'h0000;
							FM_STATUS, FM_WB2: rdata <= {8'd0, fstatus};
							FM_WB1:            rdata <= 16'h0080;
							default: begin
								op_byte <= {3'd0, fl_word, 1'b0};
								rq_rd   <= 1;
								rq_beat <= fl_word[21:2];
								post    <= 2'd0;
								state   <= S_MRD_WAIT;
							end
						endcase
					end else begin
						post   <= bank[4] ? 2'd3 : 2'd1;
						bypass <= 0;
						if (!bank[4] && bank[3:2] != 2'd0) begin
							raw   <= 16'h0000;           // beyond the 8 MB flash
							state <= S_RAW_DONE;
						end else if (lat_v && lat_beat == mm_byte[25:3]) begin
							op_byte <= mm_byte;
							raw     <= lat_data[{mm_byte[2:1], 4'b0000} +: 16];
							state   <= S_RAW_DONE;
						end else begin
							op_byte <= mm_byte;
							rq_rd   <= 1;
							rq_beat <= mm_byte[25:3];
							state   <= S_MRD_WAIT;
						end
					end
				end
				// ------------------------------------------------ MEM(N) registers
				if (board_type == BT_MEMN && a_word0) begin
					case (addr[22:16])
						7'h40: rdata <= 16'h0000;   // RnB: always ready, the bus waits instead
						7'h45: begin
							if (!dev_ok) rdata <= 16'hFFFF;
							else begin
								second <= 0;
								post   <= 2'd1;
								bypass <= (idx == 3'd0) && (nand_address[23:14] == 10'd0);
								state  <= S_NRD_BYTE;
							end
						end
						7'h47: rdata <= ctrl;
						default: ;
					endcase
				end
			end
		end

		// ================================================================ MEM(N) data write, low byte
		S_NWR2: begin
			if (prog_count < 11'd528) begin
				pr_we    <= 1;
				pr_addr  <= cbyte[9:0];
				pr_wdata <= wlo;
			end
			prog_count  <= prog_count + 1'd1;
			n_byte[idx] <= next_pbyte(cbyte, cpm);
			state       <= S_IDLE;
		end

		// ================================================================ MEM(N) data read
		S_NRD_BYTE: begin
			case (cm)
				NM_READ: begin
					if (cbyte != 12'hFFF) n_byte[idx] <= cbyte + 1'd1;
					if (nand_rd_in) begin
						op_byte <= nand_byte;
						rq_rd   <= 1;
						rq_beat <= nand_byte[25:3];
						state   <= S_NRD_WAIT;
					end else begin
						if (second) begin raw[7:0]  <= 8'hFF; state <= S_RAW_DONE; end
						else        begin raw[15:8] <= 8'hFF; second <= 1; end
					end
				end
				NM_STATUS: begin
					if (second) begin raw[7:0]  <= n_status[idx] & 8'hC1; state <= S_RAW_DONE; end
					else        begin raw[15:8] <= n_status[idx] & 8'hC1; second <= 1; end
				end
				NM_ID: begin
					if (cbyte != 12'hFFF) n_byte[idx] <= cbyte + 1'd1;
					if (second) begin raw[7:0]  <= (cbyte == 12'd0) ? 8'hEC : (cbyte == 12'd1) ? nand_id1 : 8'h00; state <= S_RAW_DONE; end
					else        begin raw[15:8] <= (cbyte == 12'd0) ? 8'hEC : (cbyte == 12'd1) ? nand_id1 : 8'h00; second <= 1; end
				end
				default: begin
					if (second) begin raw[7:0]  <= 8'h00; state <= S_RAW_DONE; end
					else        begin raw[15:8] <= 8'h00; second <= 1; end
				end
			endcase
		end

		S_NRD_WAIT: if (rq_valid) begin
			if (second) begin
				raw[7:0] <= beat_byte;
				state    <= S_RAW_DONE;
			end else begin
				raw[15:8] <= beat_byte;
				second    <= 1;
				state     <= S_NRD_BYTE;
			end
		end

		// ================================================================ MEM(M) raw word
		S_MRD_WAIT: if (rq_valid) begin
			raw      <= rq_data[{op_byte[2:1], 4'b0000} +: 16];
			lat_v    <= 1;
			lat_beat <= rq_beat;
			lat_data <= rq_data;
			state    <= S_RAW_DONE;
		end

		// ================================================================ post processing
		S_SRAM_RD: begin
			rdata <= sram_q;
			state <= S_IDLE;
		end

		S_RAW_DONE: begin
			if (post == 2'd0) begin
				rdata <= raw;
				state <= S_IDLE;
			end else if (crypt_active) begin
				state <= S_CRYPT_WAIT;
			end else if (post == 2'd3 || bypass) begin
				rdata <= raw;
				state <= S_IDLE;
			end else begin
				us_in     <= raw;
				use_crypt <= 0;
				state     <= S_CRYPT_OUT2;
			end
		end

		S_CRYPT_WAIT: if (!crypt_busy) begin
			crypt_req <= 1;
			crypt_in  <= raw;
			use_crypt <= 1;
			state     <= S_CRYPT_OUT1;
		end

		S_CRYPT_OUT1: state <= S_CRYPT_OUT2;    // decrypter output register updates

		S_CRYPT_OUT2: begin
			rdata <= use_crypt ? crypt_out : us_out;
			state <= S_IDLE;
		end

		// ================================================================ NAND page register clear
		S_PR_CLEAR: begin
			pr_we    <= 1;
			pr_wdata <= 8'hFF;
			if (pr_we) pr_addr <= pr_addr + 1'd1;
			if (pr_we && pr_addr == 10'd527) begin
				pr_we <= 0;
				state <= S_IDLE;
			end
		end

		// ================================================================ NAND program: data &= pagereg, per beat
		S_PROG_RD: if (!rq_busy && !rq_wr) begin
			rq_rd   <= 1;
			rq_beat <= op_byte[25:3];
			pr_addr <= pr_base;
			state   <= S_PROG_RDW;
		end

		S_PROG_RDW: if (rq_valid) begin
			beatbuf <= rq_data;
			lane    <= 0;
			pr_addr <= pr_base + 1'd1;      // pr_q holds pagereg[pr_base] now
			state   <= S_PROG_AND;
		end

		S_PROG_AND: begin
			beatbuf[{lane, 3'b000} +: 8] <= beatbuf[{lane, 3'b000} +: 8] & pr_q;
			pr_addr <= pr_addr + 1'd1;
			lane    <= lane + 1'd1;
			if (lane == 3'd7) begin
				rq_wr     <= 1;
				rq_beat   <= op_byte[25:3];
				rq_wdata  <= {beatbuf[63:56] & pr_q, beatbuf[55:0]};
				rq_be     <= 8'hFF;
				op_byte   <= op_byte + 26'd8;
				pr_base   <= pr_base + 10'd8;
				prog_next <= (op_cnt != 13'd0);
				op_cnt    <= op_cnt - 1'd1;
				state     <= S_CACHE_WAIT;
			end
		end

		// ================================================================ FF fill (erase)
		S_ERASE: if (!rq_busy && !rq_wr) begin
			rq_wr    <= 1;
			rq_beat  <= op_byte[25:3];
			rq_wdata <= 64'hFFFFFFFFFFFFFFFF;
			rq_be    <= 8'hFF;
			op_byte  <= op_byte + 26'd8;
			if (op_cnt == 13'd0) state <= S_CACHE_WAIT;
			else op_cnt <= op_cnt - 1'd1;
		end

		S_WB_COMMIT: begin
			fp_word <= wb_addr;
			fp_data <= wb[op_cnt[3:0]];
			fp_wb   <= 1;
			state   <= S_FPROG_RD;
		end

		// ================================================================ flash word program: data &= wdata
		S_FPROG_RD: if (!rq_busy && !rq_wr) begin
			rq_rd   <= 1;
			rq_beat <= {3'd0, fp_word[19:2]};
			state   <= S_FPROG_RDW;
		end

		S_FPROG_RDW: if (rq_valid) begin
			rq_wr    <= 1;
			rq_wdata <= {4{rq_data[{fp_word[1:0], 4'd0} +: 16] & fp_data}};
			rq_be    <= 8'h03 << {fp_word[1:0], 1'b0};
			if (fp_wb && op_cnt[4:0] + 1'd1 != wb_count) begin
				op_cnt <= op_cnt + 1'd1;
				state  <= S_WB_COMMIT;
			end else
				state  <= S_CACHE_WAIT;
		end

		S_CACHE_WAIT: if (!rq_busy && !rq_wr) begin
			if (prog_next) begin
				prog_next <= 0;
				state     <= S_PROG_RD;
			end else
				state <= S_IDLE;
		end

		// ================================================================ boot copy: 4 MB BIOS image
		S_BOOT: begin
			b_fill <= 1;
			if (board_type == BT_MEMN) begin
				if (b_off < 22'h1C000 || b_off >= 22'h20000) begin
					op_byte <= boot_nand;
					b_fill  <= 0;
				end
			end else if (board_type == BT_MEMM) begin
				if (b_off < 22'h62000) begin
					op_byte <= {4'd0, b_off};
					b_fill  <= 0;
				end
			end
			state <= S_BOOT_RD;
		end

		S_BOOT_RD: begin
			if (b_fill) begin
				b_word <= 32'h55555555;
				state  <= S_BOOT_WR;
			end else if (!rq_busy && !rq_wr) begin
				rq_rd   <= 1;
				rq_beat <= op_byte[25:3];
				state   <= S_BOOT_RDW;
			end
		end

		S_BOOT_RDW: if (rq_valid) begin
			beatbuf <= rq_data;
			// NAND words are big endian byte pairs, flash words little endian
			us_in   <= (board_type == BT_MEMN) ? {rq_data[{op_byte[2], 5'd0} +: 8], rq_data[{op_byte[2], 5'd8} +: 8]}
			                                   :  rq_data[{op_byte[2], 5'd0} +: 16];
			state   <= S_BOOT_US1;
		end

		S_BOOT_US1: begin
			b_word[15:0] <= us_out;
			us_in <= (board_type == BT_MEMN) ? {beatbuf[{op_byte[2], 5'd16} +: 8], beatbuf[{op_byte[2], 5'd24} +: 8]}
			                                 :  beatbuf[{op_byte[2], 5'd16} +: 16];
			state <= S_BOOT_US2;
		end

		S_BOOT_US2: begin
			b_word[31:16] <= us_out;
			state <= S_BOOT_WR;
		end

		S_BOOT_WR: begin
			bw_req  <= 1;
			bw_addr <= b_off;
			bw_data <= b_word;
			state   <= S_BOOT_WRW;
		end

		S_BOOT_WRW: if (bw_done) begin
			if (b_off == 22'h3FFFFC) begin
				boot_act <= 0;
				state    <= S_IDLE;
			end else begin
				b_off <= b_off + 22'd4;
				state <= S_BOOT;
			end
		end

		default: state <= S_IDLE;
		endcase

		// savestate load (CPU paused, board idle)
		if (ss_rg_we) begin
			casez (ss_r)
				5'd0: begin
					{bank, direct, fmode, fstatus, master_lock, wb_count, wb_n} <= ss_din[27:0];
					lat_v <= 0;
				end
				5'd1:  wb_start <= ss_din[19:0];
				5'd2, 5'd3, 5'd4, 5'd5, 5'd6, 5'd7, 5'd8, 5'd9: begin
					wb[{ss_wbk[2:0], 1'b0}] <= ss_din[15:0];
					wb[{ss_wbk[2:0], 1'b1}] <= ss_din[31:16];
				end
				5'd10: {idx, ctrl} <= ss_din[18:0];
				5'd11: nand_address <= ss_din[23:0];
				5'd12: prog_count <= ss_din[10:0];
				5'b10???: {n_mode[ss_dev], n_pm[ss_dev], n_ptr[ss_dev], n_status[ss_dev], n_page[ss_dev]} <= ss_din[30:0];
				5'b11???: n_byte[ss_dev] <= ss_din[11:0];
				default: ;
			endcase
		end
	end
end

endmodule
