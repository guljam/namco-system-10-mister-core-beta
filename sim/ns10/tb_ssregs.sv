// Savestate register round trip of the NS10 board modules (ns10_romboard type 17 0x0000-0x241F,
// ns10_crypt 0x2440-0x2444, ns10_io 0x2450-0x2453): every savestate address is written with all ones,
// all zeros and random values while the board is idle, and read back the way savestates.vhd does
// (address held, data one clock later). Implemented bits = read of all ones; a random write must read
// back as (value & implemented) | (read of all zeros). I/O counters (tcnt, fcnt) run: +-4 tolerance.
// Watchdog: sim time limit. Run: sim/ns10/run_ssregs.sh
`timescale 1ns/1ps
module tb_ssregs;

reg clk = 0;
always #14.76 clk = ~clk;
reg reset = 1;

reg  [13:0] ss_addr = 0;
reg  [31:0] ss_din = 0;
reg         ss_wr = 0;
wire [31:0] rb_q, cr_q, io_q;

wire        c_active, c_busy;
ns10_crypt crypt
(
	.clk(clk), .reset(reset),
	.dec_type(2'd2), .unscramble_map(64'hFEDCBA9876543210), .data_xor(16'd0), .t2_xmask(16'd0), .t2_nlmask(16'd0),
	.t2_use_ivtab(1'b0), .ivtab_we(1'b0), .ivtab_addr(4'd0), .ivtab_data(16'd0), .row_we(1'b0), .row_addr(5'd0), .row_data(96'd0),
	.switch_we(1'b0), .switch_data(16'd0), .active(c_active),
	.dec_req(1'b0), .dec_in(16'd0), .dec_out(), .busy(c_busy),
	.us_in(16'd0), .us_out(),
	.ss_addr(ss_addr[2:0]), .ss_din(ss_din), .ss_wr(ss_wr && ss_addr[13:4] == 10'h244), .ss_dout(cr_q)
);

ns10_io io
(
	.clk(clk), .reset(reset),
	.rd(1'b0), .wr(1'b0), .addr(21'd0), .wdata(16'd0), .rdata(),
	.dip(8'd0), .in1(32'hFFFFFFFF), .irq10_vbl(1'b1), .vblank(1'b0), .irq10(),
	.bank_rd(), .bank_wr(), .bank_off(),
	.ss_addr(ss_addr[1:0]), .ss_din(ss_din), .ss_wr(ss_wr && ss_addr[13:4] == 10'h245), .ss_dout(io_q)
);

ns10_romboard rb
(
	.clk(clk), .reset(reset),
	.board_type(2'd1), .nand_count(4'd2), .nand_stride(26'h0420000), .nand_pages(17'h10000), .nand_id1(8'h76),
	.rd(1'b0), .wr(1'b0), .addr(23'd0), .wdata(16'd0), .be(2'b11), .rdata(), .busy(),
	.bank_rd(1'b0), .bank_wr(1'b0), .bank_off(16'd0),
	.crypt_switch_we(), .crypt_switch_data(), .crypt_active(c_active), .crypt_busy(c_busy), .crypt_req(), .crypt_in(), .crypt_out(16'd0),
	.us_in(), .us_out(16'd0),
	.rq_rd(), .rq_wr(), .rq_beat(), .rq_wdata(), .rq_be(), .rq_busy(1'b0), .rq_valid(1'b0), .rq_data(64'd0),
	.boot_start(1'b0), .boot_busy(), .bw_req(), .bw_addr(), .bw_data(), .bw_done(1'b0),
	.ss_active(1'b1), .ss_addr(ss_addr), .ss_din(ss_din), .ss_wr(ss_wr), .ss_dout(rb_q)
);

// read mux as in NAMCOS10.sv (registered select of the previous address)
reg [1:0] sel;
always @(posedge clk) sel <= (ss_addr[13:4] == 10'h244) ? 2'd1 : (ss_addr[13:4] == 10'h245) ? 2'd2 : 2'd0;
wire [31:0] q = (sel == 2'd1) ? cr_q : (sel == 2'd2) ? io_q : rb_q;

task automatic wr32(input [13:0] a, input [31:0] d);
	@(posedge clk); ss_addr <= a; ss_din <= d; ss_wr <= 1;
	@(posedge clk); ss_wr <= 0;
endtask

task automatic rd32(input [13:0] a, output [31:0] d);
	@(posedge clk); ss_addr <= a;
	@(posedge clk); @(posedge clk); #1 d = q;
endtask

// I/O counter fields: r0 [29:11] tcnt, r2 [19:0] fcnt
function automatic [31:0] cnt_mask(input [13:0] a);
	cnt_mask = (a == 14'h2450) ? 32'h3FFFF800 : (a == 14'h2452) ? 32'h000FFFFF : 32'd0;
endfunction

integer errors = 0, checked = 0, n, k;
reg [31:0] m1, m0, r, v, e, cm;
reg [13:0] a;
integer lsb;

task automatic check(input [13:0] a);
	wr32(a, 32'hFFFFFFFF); rd32(a, m1);
	wr32(a, 32'h00000000); rd32(a, m0);
	cm = cnt_mask(a);
	m1 = m1 | cm;   // a running counter written with all ones may wrap at its period
	for (k = 0; k < 4; k++) begin
		r = $urandom;
		wr32(a, r); rd32(a, v);
		e = (r & m1) | m0;
		if (cm != 0) begin
			// counter field: written value + up to 4 counts (the read is a few clocks after the write)
			lsb = (a == 14'h2450) ? 11 : 0;
			if (((v & ~cm) != (e & ~cm)) || ((((v & cm) >> lsb) - ((r & m1 & cm) >> lsb)) & (cm >> lsb)) > 4) begin
				if (errors < 20) $display("MISMATCH %h: wrote %h read %h (ones %h zeros %h)", a, r, v, m1, m0);
				errors++;
			end
		end else if (v !== e) begin
			if (errors < 20) $display("MISMATCH %h: wrote %h read %h expected %h (ones %h zeros %h)", a, r, v, e, m1, m0);
			errors++;
		end
		checked++;
	end
endtask

initial begin
	#100000000 $display("FAIL: sim time limit"); $finish;
end

initial begin
	repeat (10) @(posedge clk);
	reset <= 0;
	repeat (10) @(posedge clk);
	// board RAM: words; NAND page register: bytes (every 7th address, all ones / zeros / random each)
	for (n = 0; n < 14'h2000; n += 7) check(n);
	check(14'h1FFF);
	for (n = 14'h2000; n < 14'h2400; n += 3) check(n);
	check(14'h23FF);
	// registers
	for (n = 14'h2400; n < 14'h2420; n++) begin
		check(n);
		wr32(n, 32'hFFFFFFFF); rd32(n, m1);
		$display("romboard reg %h: implemented bits %h", n[13:0], m1);
	end
	for (n = 14'h2440; n < 14'h2445; n++) check(n);
	for (n = 14'h2450; n < 14'h2454; n++) check(n);
	// width summary
	wr32(14'h0005, 32'hFFFFFFFF); rd32(14'h0005, m1); $display("board RAM word bits %h", m1);
	wr32(14'h2005, 32'hFFFFFFFF); rd32(14'h2005, m1); $display("page register bits %h", m1);
	for (n = 14'h2440; n < 14'h2445; n++) begin wr32(n, 32'hFFFFFFFF); rd32(n, m1); $display("crypt %h bits %h", n[13:0], m1); end
	for (n = 14'h2450; n < 14'h2454; n++) begin wr32(n, 32'hFFFFFFFF); rd32(n, m1); $display("io %h bits %h", n[13:0], m1); end
	if (errors == 0) $display("PASS: %0d checks", checked);
	else $display("FAIL: %0d of %0d checks", errors, checked);
	$finish;
end

endmodule
