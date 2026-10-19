//============================================================================
//  NS10 settings NVRAM (MRA <nvram index="2">, MiSTer .nvm file).
//
//  The games keep settings / rankings / bookkeeping on the ROM board itself
//  (MAME namcos10.cpp):
//    MEM(M): program flash 0x40000-0x43FFF (16 KB, inside the 64 KB erase block)
//    MEM(N): NAND0 block 1 = ROM bytes 0x4200-0x83FF (16896 bytes)
//  The region lives in the DDR3 ROM image like the rest of the ROM. This
//  module keeps a BRAM copy of it (every ROM cache write into the region,
//  ROM / nvram download or game write, also goes here) so the HPS can read it
//  back at its own pace. A game write into the region requests a save; the
//  MiSTer menu saves when the OSD is opened next (or with "Save settings").
//  The .nvm file holds the region bytes in ROM file order.
//============================================================================

module ns10_nvram
(
	input             clk,
	input       [1:0] board_type,

	// ROM cache write snoop
	input             wr,
	input      [22:0] beat,
	input      [63:0] wdata,
	input       [7:0] be,
	input             game,          // write comes from the ROM board (not a download)

	output     [22:0] base,          // first beat of the region
	output            hit,           // 'beat' is inside the region

	// HPS upload (ioctl_addr in bytes)
	input      [14:0] up_addr,
	output     [15:0] up_data,

	output reg        save_req
);

localparam BT_MEMM = 2'd0;

assign base = (board_type == BT_MEMM) ? 23'h008000 : 23'h000840;
wire [22:0] size = (board_type == BT_MEMM) ? 23'h000800 : 23'h000840;
wire [22:0] off  = beat - base;
assign hit = (beat >= base) && (off < size);

wire [63:0] q;

// 2112 x 64 with byte enables, registered read address and output
altsyncram #(
	.operation_mode("DUAL_PORT"), .width_a(64), .widthad_a(12), .numwords_a(2112), .width_byteena_a(8),
	.width_b(64), .widthad_b(12), .numwords_b(2112), .address_reg_b("CLOCK0"), .outdata_reg_b("CLOCK0"),
	.read_during_write_mode_mixed_ports("DONT_CARE"), .lpm_type("altsyncram"), .intended_device_family("Cyclone V")
) ram (
	.clock0(clk),
	.address_a(off[11:0]), .data_a(wdata), .wren_a(wr && hit), .byteena_a(be),
	.address_b(up_addr[14:3]), .q_b(q)
);

always @(posedge clk) save_req <= wr && hit && game;

assign up_data = q[{up_addr[2:1], 4'b0000} +: 16];

endmodule
