//============================================================================
//  crt_sync testbench: PSX async videoout sync timing (3413 clocks per line,
//  HSync 252 clocks; 240p: 263 lines, VSync line 242; 480i: fields of 263 /
//  262 lines, VSync at line 243 half a line in / line 242 at the line start).
//  For each setting: every output HSync / VSync rise must come D + 1 clocks
//  after an input rise (D from the crt_sync formula, computed here
//  independently; enabled with D = 0 too), pulse widths unchanged, and the output VSync intervals must
//  repeat the input intervals (480i field offset kept). Disabled = passthrough.
//  Composite sync (sys_top csync, used for YPbPr sync on Y): the set of csync
//  pulse widths of the output must equal the input's, and every output VSync
//  must start at the same place against HSync as in the input (same clock as an
//  HSync rise, or half a line in), else the CRT sees a malformed VSync line.
//  Watchdogs: sim time limit, and per setting a minimum number of checked edges.
//============================================================================
`timescale 1ns/1ps

module tb_crt_sync;

reg clk = 0;
always #9.31 clk = ~clk;
longint cyc = 0;
always @(posedge clk) cyc <= cyc + 1;

// ------------------------------------------------------------------ sync generator
localparam int L = 3413;
reg        i480 = 0;
reg        field = 0;           // 480i: 0 = 263 line field (VSync half a line in), 1 = 262 line field
int        h = 0, v = 0;
reg        hs_in = 0, vs_in = 0;
int        vs_line, vs_h;

always @(posedge clk) begin
	if (h == L - 1) begin
		h <= 0;
		if (v == ((i480 && field) ? 261 : 262)) begin
			v <= 0;
			field <= i480 ? ~field : 1'b0;
		end else v <= v + 1;
	end else h <= h + 1;
	hs_in <= (h < 252);
	vs_line = (i480 && !field) ? 243 : 242;
	vs_h    = (i480 && !field) ? L / 2 : 0;
	if (v == vs_line && h == vs_h) vs_in <= 1;
	if (v == vs_line + 3 && h == vs_h) vs_in <= 0;
end

// ------------------------------------------------------------------ DUT
reg              enable = 0, vline = 0;
reg signed [4:0] hpos = 0, vpos = 0;
wire             hs_out, vs_out;

crt_sync dut
(
	.clk(clk), .enable(enable), .hpos(hpos), .vpos(vpos), .vline(vline),
	.hs_in(hs_in), .vs_in(vs_in), .hs_out(hs_out), .vs_out(vs_out)
);

wire cs_in, cs_out;
csync csync_in (clk, hs_in,  vs_in,  cs_in);      // sys/sys_top.v module, extracted by run.sh
csync csync_out(clk, hs_out, vs_out, cs_out);

// ------------------------------------------------------------------ monitors
// every output rise must come exactly off + 1 clocks after some input rise (off < 0: before the
// following one), and every output pulse must be as wide as the input pulses
reg     hs_in_d = 0, vs_in_d = 0, hs_out_d = 0, vs_out_d = 0;
bit     rec = 0;
longint hout_r = 0, vout_r = 0, hin_r = 0, vin_r = 0;
int     hin_w = 0, vin_w = 0;
bit     hin_set[longint], vin_set[longint];
longint hout_q[$], vout_q[$];
int     hout_wq[$], vout_wq[$];
longint vin_q[$];
reg     cs_in_d = 0, cs_out_d = 0;
longint csi_t = 0, cso_t = 0;
bit     csi_w[string], cso_w[string];             // "level:width" pulses seen, recorded window
longint hout_last = 0;
int     vs_ph_bad = 0;

always @(posedge clk) begin
	hs_in_d <= hs_in; vs_in_d <= vs_in; hs_out_d <= hs_out; vs_out_d <= vs_out;
	if (hs_in & ~hs_in_d) begin hin_r = cyc; if (rec) hin_set[cyc] = 1; end
	if (~hs_in & hs_in_d) hin_w = cyc - hin_r;
	if (vs_in & ~vs_in_d) begin vin_r = cyc; vin_q.push_back(cyc); if (rec) vin_set[cyc] = 1; end
	if (~vs_in & vs_in_d) vin_w = cyc - vin_r;
	if (hs_out & ~hs_out_d) begin hout_r = cyc; if (rec) hout_q.push_back(cyc); end
	if (~hs_out & hs_out_d && rec) hout_wq.push_back(cyc - hout_r);
	if (vs_out & ~vs_out_d) begin vout_r = cyc; if (rec) vout_q.push_back(cyc); end
	if (~vs_out & vs_out_d && rec) vout_wq.push_back(cyc - vout_r);
	cs_in_d <= cs_in; cs_out_d <= cs_out;
	if (cs_in != cs_in_d) begin if (rec) csi_w[$sformatf("%0d:%0d", cs_in_d, cyc - csi_t)] = 1; csi_t = cyc; end
	if (cs_out != cs_out_d) begin if (rec) cso_w[$sformatf("%0d:%0d", cs_out_d, cyc - cso_t)] = 1; cso_t = cyc; end
	// VSync start against HSync: same clock as an HSync rise or half a line later (480i field)
	if (hs_out & ~hs_out_d) hout_last = cyc;
	if (vs_out & ~vs_out_d && rec && !(cyc == hout_last || cyc - hout_last == L / 2)) begin
		if (vs_ph_bad < 4) $display("  VS out at %0d: %0d clocks after the last HS rise (0 or %0d expected)", cyc, cyc - hout_last, L / 2);
		vs_ph_bad++;
	end
end

// ------------------------------------------------------------------ watchdog
localparam longint SIM_LIMIT_NS = 64'd3_000_000_000;   // 3 s sim time (whole run ~2.1 s)
initial begin
	#(SIM_LIMIT_NS);
	$display("TIMEOUT: sim time limit reached");
	$display("FAIL");
	$finish;
end

// ------------------------------------------------------------------ settings
int fails = 0;

task automatic run(input bit p480, input bit en, input int hp, input int vp, input bit vl);
	int bad = 0, nh, nv, ch = 0, cv = 0;
	longint oh, ov, vi0, vi1;
	i480 = p480; enable = en; hpos = hp; vpos = vp; vline = vl;
	rec = 0;
	repeat (3) @(posedge vs_in);                     // periods measured, delays settled
	hin_set.delete(); vin_set.delete(); hout_q.delete(); vout_q.delete(); hout_wq.delete(); vout_wq.delete();
	csi_w.delete(); cso_w.delete(); vs_ph_bad = 0;
	rec = 1;
	repeat (6) @(posedge vs_in);
	rec = 0;
	vi0 = vin_q[$] - vin_q[$-1]; vi1 = vin_q[$-1] - vin_q[$-2];
	oh  = en ? -16 * hp : 0;
	ov  = en ? -16 * hp - vp * L + (vl ? L : 0) : 0;
	nh  = hout_q.size(); nv = vout_q.size();
	// skip the first / last outputs whose input rise lies outside the recorded window
	for (int i = 2; i < nh - 2; i++) begin
		ch++;
		if (!hin_set.exists(hout_q[i] - (en ? oh + 1 : 0))) begin
			if (bad < 4) $display("  HS out at %0d: no input rise %0d clocks before", hout_q[i], en ? oh + 1 : 0);
			bad++;
		end
	end
	for (int i = 1; i < nv - 1; i++) begin
		cv++;
		if (!vin_set.exists(vout_q[i] - (en ? ov + 1 : 0))) begin
			if (bad < 4) $display("  VS out at %0d: no input rise %0d clocks before", vout_q[i], en ? ov + 1 : 0);
			bad++;
		end
	end
	foreach (hout_wq[i]) if (i > 0 && hout_wq[i] != hin_w) begin if (bad < 4) $display("  HS width %0d, input %0d", hout_wq[i], hin_w); bad++; end
	foreach (vout_wq[i]) if (i > 0 && vout_wq[i] != vin_w) begin if (bad < 4) $display("  VS width %0d, input %0d", vout_wq[i], vin_w); bad++; end
	foreach (cso_w[k]) if (!csi_w.exists(k)) begin if (bad < 8) $display("  csync out has a %s pulse (level:clocks) not in the input", k); bad++; end
	foreach (csi_w[k]) if (!cso_w.exists(k)) begin if (bad < 8) $display("  csync in has a %s pulse (level:clocks) missing in the output", k); bad++; end
	bad += vs_ph_bad;
	$display("%s en %0d hpos %3d vpos %3d vline %0d: offset H %0d V %0d, VS intervals %0d / %0d, %0d HS / %0d VS checked, csync widths %0d/%0d, %0d bad",
		p480 ? "480i" : "240p", en, hp, vp, vl, oh, ov, vi1, vi0, ch, cv, csi_w.num(), cso_w.num(), bad);
	if (bad || ch < 1000 || cv < 3) begin
		if (ch < 1000 || cv < 3) $display("  STALL: too few output edges");
		fails++;
	end
endtask

initial begin
	$display("start");
	for (int m = 0; m < 2; m++) begin
		run(m, 0, 0, 0, 0);
		run(m, 1, 0, 0, 0);
		run(m, 1, 5, 3, 0);
		run(m, 1, -7, -10, 1);
		run(m, 1, 15, -16, 0);
		run(m, 1, -16, 15, 1);
		run(m, 1, 0, 0, 1);       // H-Size only (HW: CRT jitter before the fix)
		run(m, 1, 0, 3, 0);       // V-Position only
		run(m, 1, 0, -5, 1);
	end
	if (fails) $display("FAIL (%0d)", fails); else $display("PASS");
	$finish;
end

endmodule
