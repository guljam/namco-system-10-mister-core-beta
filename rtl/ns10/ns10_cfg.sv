//============================================================================
//  NS10 per-game configuration blob (MRA rom index 1, written by
//  tools/ns10cfg.py), loaded through the 16 bit ioctl bus (little endian).
//
//  0x000      board type (0 MEM(M), 1 MEM(N))
//  0x001      NAND count
//  0x002-003  data xor
//  0x004-013  unscramble order, MAME bitswap<16> argument order
//  0x014      decrypter type (0 none, 1 type 1, 2 type 2)
//  0x015      flags: bit 0 = iv table present, bit 1 = Button2 is Drill (Auto) (Driller sets)
//  0x016-017  type 2 xmask
//  0x018-019  type 2 nonlinear output mask C
//  0x01A      NAND ID byte 1
//  0x01C-01F  NAND stride in bytes
//  0x020-03F  iv table, 16 words
//  0x040-177  26 rows x 12 bytes: 48 bit cipher mask, 48 bit plain mask
//  0x180-183  pages per NAND
//============================================================================

module ns10_cfg
(
	input             clk,
	input             wr,
	input       [8:0] addr,          // byte address, even
	input      [15:0] data,

	output reg  [1:0] board_type,
	output reg  [3:0] nand_count,
	output reg [15:0] data_xor,
	output reg [63:0] unscramble_map,
	output reg  [1:0] dec_type,
	output reg        use_ivtab,
	output reg [15:0] xmask,
	output reg [15:0] nlmask,
	output reg  [7:0] nand_id1,
	output reg [25:0] nand_stride,
	output reg [16:0] nand_pages,
	output reg        af_b2,

	output reg        ivtab_we,
	output reg  [3:0] ivtab_addr,
	output reg [15:0] ivtab_data,
	output reg        row_we,
	output reg  [4:0] row_addr,
	output reg [95:0] row_data
);

reg  [2:0] rw;               // word inside a row
reg [79:0] rbuf;

always @(posedge clk) begin
	ivtab_we <= 0;
	row_we   <= 0;
	if (wr) begin
		case (addr)
			9'h000: begin board_type <= data[1:0]; nand_count <= data[11:8]; end
			9'h002: data_xor <= data;
			9'h014: begin dec_type <= data[1:0]; use_ivtab <= data[8]; af_b2 <= data[9]; end
			9'h016: xmask  <= data;
			9'h018: nlmask <= data;
			9'h01A: nand_id1 <= data[7:0];
			9'h01C: nand_stride[15:0]  <= data;
			9'h01E: nand_stride[25:16] <= data[9:0];
			9'h180: nand_pages[15:0] <= data;
			9'h182: nand_pages[16]   <= data[0];
			default: ;
		endcase
		// order byte i (result bit 15-i) at 0x004+i
		if (addr >= 9'h004 && addr < 9'h014) begin
			unscramble_map[4*(15 - (addr - 9'h004))     +: 4] <= data[3:0];
			unscramble_map[4*(15 - (addr - 9'h004) - 1) +: 4] <= data[11:8];
		end
		if (addr >= 9'h020 && addr < 9'h040) begin
			ivtab_we   <= 1;
			ivtab_addr <= addr[4:1];
			ivtab_data <= data;
		end
		if (addr == 9'h040) begin
			rw       <= 3'd1;
			row_addr <= 5'd0;
			rbuf[15:0] <= data;
		end else if (addr > 9'h040 && addr < 9'h178) begin
			if (rw == 3'd5) begin
				row_we   <= 1;
				row_data <= {data, rbuf};
				rw       <= 0;
			end else begin
				rbuf[16*rw +: 16] <= data;
				rw <= rw + 1'd1;
			end
			if (rw == 3'd0) row_addr <= row_addr + 1'd1;
		end
	end
end

endmodule
