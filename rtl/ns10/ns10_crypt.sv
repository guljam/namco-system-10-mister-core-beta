//============================================================================
//  Namco System 10 ROM board data path: unscrambler + decrypters
//
//  Behaviour follows MAME ns10crypt.cpp (bit-exact model: tools/ns10model.py).
//
//  type 1 (mrdrilr2): fixed logic, counter based, combinational.
//  type 2 (all other MEM(N) games): generic engine.
//     plain = cipher ^ mask
//     prev_c/prev_p shift in the new words (48 bits are significant)
//     mask[j] = parity(E[j] & prev_c) ^ parity(D[j] & prev_p) ^ xmask[j]
//     mask   ^= C * XOR_k( P(A_k) & P(B_k) ),  P(X) = parity(Xc & prev_c ^ Xp & prev_p)
//  The 16 linear rows and the 10 factor rows (A0,B0..A4,B4) live in a row RAM
//  (96 bits per row: {p_mask, c_mask}) and are evaluated two rows per clock, so
//  the next mask is ready 13 clocks after a decrypt. 'busy' covers that time.
//============================================================================

module ns10_crypt
(
	input             clk,
	input             reset,

	// configuration
	input       [1:0] dec_type,        // 0 none, 1 type 1, 2 type 2
	input      [63:0] unscramble_map,  // 16 x 4 bit: [4*k+3:4*k] = source bit of result bit k
	input      [15:0] data_xor,
	input      [15:0] t2_xmask,
	input      [15:0] t2_nlmask,       // C: output bits of the nonlinear term
	input             t2_use_ivtab,
	input             ivtab_we,
	input       [3:0] ivtab_addr,
	input      [15:0] ivtab_data,
	input             row_we,
	input       [4:0] row_addr,        // 0..15 linear rows, 16..25 factor rows
	input      [95:0] row_data,        // {p_mask[47:0], c_mask[47:0]}

	// crypto switch register write
	input             switch_we,
	input      [15:0] switch_data,
	output            active,

	// data path
	input             dec_req,         // one cipher word, only while !busy
	input      [15:0] dec_in,
	output reg [15:0] dec_out,         // valid the clock after dec_req, stays until next dec_req
	output            busy,

	// unscrambler (combinational)
	input      [15:0] us_in,
	output     [15:0] us_out           // unscramble(us_in ^ data_xor)
);

// ------------------------------------------------------------------ unscrambler
wire [15:0] us_x = us_in ^ data_xor;
genvar gi;
generate
	for (gi = 0; gi < 16; gi = gi + 1) begin : g_us
		assign us_out[gi] = us_x[unscramble_map[4*gi +: 4]];
	end
endgenerate

// ------------------------------------------------------------------ switch
reg        act;
reg  [3:0] iv;
assign active = act & (dec_type != 2'd0);

// ------------------------------------------------------------------ type 1
reg  [15:0] t1_mask;
reg   [7:0] t1_cnt;

function [4:0] t1_init(input [3:0] i);
	case (i)
		4'h3: t1_init = 5'd0;  4'h4: t1_init = 5'd4;  4'h5: t1_init = 5'd9;
		4'h9: t1_init = 5'd8;  4'hB: t1_init = 5'd1;  4'hD: t1_init = 5'd9;
		4'hF: t1_init = 5'd5;  default: t1_init = 5'd16;
	endcase
endfunction

// MAME bitswap<16>(v, b15..b0)
`define BS16(v,a,b,c,d,e,f,g,h,i,j,k,l,m,n,o,p) {v[a],v[b],v[c],v[d],v[e],v[f],v[g],v[h],v[i],v[j],v[k],v[l],v[m],v[n],v[o],v[p]}

wire [15:0] c1 = dec_in;
wire [15:0] t1_plain = t1_mask ^ `BS16(c1, 9,13,15,7,14,8,6,10,11,12,3,5,0,1,4,2);
wire  [7:0] k = t1_cnt;
wire [15:0] t1_nbs = { k[4], c1[2]^c1[5], c1[0], c1[4]|c1[5], k[0], c1[6], 1'b0, c1[4]&k[1],
                       1'b0, k[3], c1[3]|k[7], c1[2]^k[3], k[2], c1[7]&k[7], k[5], c1[7]|k[1] };
wire [15:0] t1_next = t1_nbs ^ `BS16(c1, 6,11,3,1,13,5,15,10,2,9,8,4,0,12,7,14)
                             ^ `BS16(t1_plain, 9,7,5,2,14,4,13,8,0,15,10,1,3,6,12,11) ^ 16'hECBE;

// ------------------------------------------------------------------ type 2
reg  [47:0] pc, pp;
reg  [15:0] t2_mask;
reg  [15:0] ivtab[16];

// row RAMs: even rows and odd rows, read two per clock
reg  [95:0] rows_e[16];
reg  [95:0] rows_o[16];
reg  [95:0] re, ro;
reg   [3:0] rrd;

always @(posedge clk) begin
	if (row_we & ~row_addr[0]) rows_e[row_addr[4:1]] <= row_data;
	if (row_we &  row_addr[0]) rows_o[row_addr[4:1]] <= row_data;
	re <= rows_e[rrd];
	ro <= rows_o[rrd];
	if (ivtab_we) ivtab[ivtab_addr] <= ivtab_data;
end

function prow(input [95:0] r, input [47:0] c, input [47:0] p);
	prow = ^((r[47:0] & c) ^ (r[95:48] & p));
endfunction

wire [3:0] sb = (iv == 4'd0)  ? 4'd0  : (iv == 4'd1)  ? 4'd12 : (iv == 4'd2)  ? 4'd13 : (iv == 4'd3)  ? 4'd6  :
                (iv == 4'd4)  ? 4'd2  : (iv == 4'd5)  ? 4'd4  : (iv == 4'd6)  ? 4'd9  : (iv == 4'd7)  ? 4'd8  :
                (iv == 4'd8)  ? 4'd11 : (iv == 4'd9)  ? 4'd1  : (iv == 4'd10) ? 4'd7  : (iv == 4'd11) ? 4'd15 :
                (iv == 4'd12) ? 4'd10 : (iv == 4'd13) ? 4'd5  : (iv == 4'd14) ? 4'd14 : 4'd3;

reg   [4:0] step;      // 0 idle, 1..14 evaluation pipeline
reg  [15:0] acc;
reg         nl_acc;
wire        t2_busy = (step != 5'd0);
assign busy = t2_busy;

wire [15:0] t2_plain = dec_in ^ t2_mask;

always @(posedge clk) begin
	if (reset) begin
		act     <= 0;
		iv      <= 0;
		step    <= 0;
		t1_mask <= 0;
		t1_cnt  <= 0;
		pc      <= 0;
		pp      <= 0;
		t2_mask <= 0;
		dec_out <= 0;
	end else begin
		if (dec_req) begin
			if (dec_type == 2'd1) begin
				dec_out <= t1_plain;
				t1_mask <= t1_next;
				t1_cnt  <= t1_cnt + 1'd1;
			end else begin
				dec_out <= t2_plain;
				pc      <= {pc[31:0], dec_in};
				pp      <= {pp[31:0], t2_plain};
				rrd     <= 0;
				step    <= 5'd1;
			end
		end

		// evaluation: step n reads row pair n-1 (registered), result available at step n+1
		if (step >= 5'd1 && step <= 5'd14) begin
			rrd  <= rrd + 1'd1;
			step <= (step == 5'd14) ? 5'd0 : step + 1'd1;
			if (step >= 5'd2) begin
				// pair index (step-2): rows 2*(step-2), 2*(step-2)+1
				if (step <= 5'd9) begin
					acc[{step[2:0] - 3'd2, 1'b0}] <= prow(re, pc, pp);
					acc[{step[2:0] - 3'd2, 1'b1}] <= prow(ro, pc, pp);
				end else begin
					// factor pair k = step-10 : A_k = even row, B_k = odd row
					nl_acc <= nl_acc ^ (prow(re, pc, pp) & prow(ro, pc, pp));
				end
			end else begin
				nl_acc <= 0;
			end
			if (step == 5'd14) t2_mask <= acc ^ t2_xmask ^ ((nl_acc ^ (prow(re, pc, pp) & prow(ro, pc, pp))) ? t2_nlmask : 16'd0);
		end

		// after the evaluation: an activation wins over a mask update still in flight
		if (switch_we) begin
			act <= switch_data[15];
			if (switch_data[15]) begin
				iv      <= switch_data[3:0];
				t1_mask <= {11'd0, t1_init(switch_data[3:0])};
				t1_cnt  <= 0;
				pp      <= 0;
				t2_mask <= 0;
				step    <= 0;
				if (t2_use_ivtab) pc <= {32'd0, ivtab[switch_data[3:0]]};
			end
		end
		// default iv (bitswap of INIT_SBOX) needs iv registered first: one clock later
		if (switch_we & switch_data[15] & ~t2_use_ivtab) step <= 5'd31;
		if (step == 5'd31) begin
			pc   <= {32'd0, sb[3], 2'b00, sb[2], sb[1], 2'b00, sb[0], 8'd0};
			step <= 0;
		end
	end
end

endmodule
