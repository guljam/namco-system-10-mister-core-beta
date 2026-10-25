`timescale 1ns/1ps

module tb_irq10;

    // ------------------------------------------------------------------ parameters
    localparam int CLK_HZ     = 33_868_800;
    localparam int TICK       = CLK_HZ / 100;       // 338688 cycles -> 100 Hz
    localparam int FRAME      = 564_000;            // vblank period in cycles (deliberately not 565000)
    localparam int VBL_HIGH   = 20_000;             // vblank high time
    localparam int FIRST_RISE = 1_000;              // first vblank rising edge
    localparam int LEN_A      = 3_000_000;          // phase A length
    localparam int LEN_B      = 6_000_000;          // phase B length
    localparam int WATCHDOG   = 1_000_000;          // max cycles between IRQ10 pulses
    localparam int CYC_LIMIT  = 12_000_000;         // absolute cycle limit
    localparam int OFF_1Q     = FRAME / 4;          // 141000
    localparam int OFF_3Q     = 3 * (FRAME / 4);    // 423000
    localparam int TOL        = 2;                  // allowed offset error

    // ------------------------------------------------------------------ clock and cycle counter
    logic clk = 1'b0;
    always #(29.525 / 2.0) clk = ~clk;              // 29.525 ns period = 33.8688 MHz

    int cyc = 0;
    always @(posedge clk) cyc <= cyc + 1;

    // ------------------------------------------------------------------ DUT inputs
    logic        reset      = 1'b1;
    logic [23:0] addr       = 24'd0;
    logic [31:0] wdata      = 32'd0;
    logic  [3:0] wmask      = 4'd0;
    logic  [1:0] size       = 2'd0;
    logic        rd         = 1'b0;
    logic        wr         = 1'b0;
    logic  [7:0] dsw        = 8'd0;
    logic [31:0] in1        = 32'hFFFF_FFFF;
    logic  [7:0] exio_ident = 8'hFF;
    logic  [8:0] gun_x0     = 9'd0;
    logic  [8:0] gun_y0     = 9'd0;
    logic  [8:0] gun_x1     = 9'd0;
    logic  [8:0] gun_y1     = 9'd0;
    logic        irq10_vbl  = 1'b0;
    logic        cd_intrq   = 1'b0;

    // vblank is a pure function of the cycle counter. The DUT samples the pre-edge value at each
    // rising edge, so the generated edges are exactly FRAME cycles apart (no delta-cycle races).
    logic vblank;
    assign vblank = (((cyc + FRAME - FIRST_RISE) % FRAME) < VBL_HIGH);

    wire        irq10;
    wire [31:0] rdata;

    s10_io dut (
        .clk        (clk),
        .reset      (reset),
        .addr       (addr),
        .wdata      (wdata),
        .wmask      (wmask),
        .size       (size),
        .rd         (rd),
        .wr         (wr),
        .rdata      (rdata),
        .dsw        (dsw),
        .in1        (in1),
        .exio_ident (exio_ident),
        .gun_x0     (gun_x0),
        .gun_y0     (gun_y0),
        .gun_x1     (gun_x1),
        .gun_y1     (gun_y1),
        .irq10_vbl  (irq10_vbl),
        .vblank     (vblank),
        .cd_intrq   (cd_intrq),
        .irq10      (irq10)
    );

    // ------------------------------------------------------------------ checker state
    int   last_pulse = 0;                           // cycle of the most recent IRQ10 pulse
    logic vbl_q      = 1'b0;                        // previous vblank value seen by the checker
    int   tmp        = 0;

    // phase A (100 Hz timer)
    int a_cnt   = 0;
    int a_first = -1;
    int a_prev  = -1;
    int a_min   = 0;
    int a_max   = 0;

    // phase B (2x VBlank)
    int b_start  = 0;
    int b_skip   = 0;
    int b_rise   = -1;                              // cycle of the last vblank rising edge
    int b_pf     = 0;                               // pulses in the current frame
    int b_frames = 0;
    int b_pulses = 0;
    int b_mino   = 0;
    int b_maxo   = 0;
    int b_q1     = 0;
    int b_q3     = 0;

    // phase C (CD-ROM INTRQ)
    int cd_at  = -1;
    bit cd_done = 1'b0;

    initial begin : main
        int phase = 0;

        forever begin
            @(posedge clk);

            // ---------------- global watchdogs
            if (cyc > CYC_LIMIT) begin
                $display("FAIL absolute cycle limit %0d exceeded", CYC_LIMIT);
                $finish;
            end
            if ((cyc - last_pulse) > WATCHDOG) begin
                $display("FAIL watchdog: no IRQ10 pulse for %0d cycles", WATCHDOG);
                $finish;
            end

            if (cyc == 10) reset = 1'b0;

            if (irq10) last_pulse = cyc;

            if (phase == 0) begin
                // ------------------------------------------------ phase A: 100 Hz timer
                if (irq10) begin
                    a_cnt = a_cnt + 1;
                    if (a_first < 0) begin
                        a_first = cyc;
                    end else begin
                        tmp = cyc - a_prev;
                        if (tmp != TICK) begin
                            $display("FAIL phase A: pulse spacing %0d cycles, expected %0d",
                                     tmp, TICK);
                            $finish;
                        end
                        if (a_cnt == 2) begin
                            a_min = tmp;
                            a_max = tmp;
                        end else begin
                            if (tmp < a_min) a_min = tmp;
                            if (tmp > a_max) a_max = tmp;
                        end
                    end
                    a_prev = cyc;
                end
                if (cyc >= LEN_A) begin
                    $display("Phase A (100 Hz timer): pulses=%0d first_cycle=%0d min_spacing=%0d max_spacing=%0d",
                             a_cnt, a_first, a_min, a_max);
                    if (a_cnt < 8) begin
                        $display("FAIL phase A: only %0d pulses, expected at least 8", a_cnt);
                        $finish;
                    end
                    irq10_vbl = 1'b1;               // synchronous switch to 2x VBlank mode
                    b_start   = cyc;
                    b_skip    = cyc + 2 * FRAME;    // ignore the first two frames after the switch
                    phase     = 1;
                end
            end else if (phase == 1) begin
                // ------------------------------------------------ phase B: 2x VBlank
                if (vblank && !vbl_q) begin
                    if (b_rise >= b_skip) begin
                        if (b_pf != 2) begin
                            $display("FAIL phase B: frame starting at cycle %0d has %0d pulses, expected 2",
                                     b_rise, b_pf);
                            $finish;
                        end
                        b_frames = b_frames + 1;
                    end
                    b_rise = cyc;
                    b_pf   = 0;
                end
                if (irq10 && (b_rise >= b_skip)) begin
                    tmp = cyc - b_rise;
                    if ((tmp >= OFF_1Q - TOL) && (tmp <= OFF_1Q + TOL)) begin
                        b_q1 = b_q1 + 1;
                    end else if ((tmp >= OFF_3Q - TOL) && (tmp <= OFF_3Q + TOL)) begin
                        b_q3 = b_q3 + 1;
                    end else begin
                        $display("FAIL phase B: pulse offset %0d cycles, expected %0d or %0d (+-%0d)",
                                 tmp, OFF_1Q, OFF_3Q, TOL);
                        $finish;
                    end
                    if (b_pulses == 0) begin
                        b_mino = tmp;
                        b_maxo = tmp;
                    end else begin
                        if (tmp < b_mino) b_mino = tmp;
                        if (tmp > b_maxo) b_maxo = tmp;
                    end
                    b_pulses = b_pulses + 1;
                    b_pf     = b_pf + 1;
                end
                if (cyc >= (b_start + LEN_B)) begin
                    $display("Phase B (2x VBlank): frames=%0d pulses=%0d min_offset=%0d max_offset=%0d quarter_pulses=%0d three_quarter_pulses=%0d",
                             b_frames, b_pulses, b_mino, b_maxo, b_q1, b_q3);
                    if (b_frames == 0) begin
                        $display("FAIL phase B: no complete frame checked");
                        $finish;
                    end
                    if (b_pulses == 0) begin
                        $display("FAIL phase B: no pulse checked");
                        $finish;
                    end
                    if (b_q1 == 0) begin
                        $display("FAIL phase B: no 1/4-frame pulse observed");
                        $finish;
                    end
                    if (b_q3 == 0) begin
                        $display("FAIL phase B: no 3/4-frame pulse observed");
                        $finish;
                    end
                    phase = 2;
                end
            end else begin
                // ------------------------------------------------ phase C: CD-ROM INTRQ
                if (cd_at < 0) begin
                    // align: only assert once the last (vblank generated) pulse is well in the past
                    if ((cyc - last_pulse) > 2000) begin
                        cd_at    = cyc;
                        cd_intrq = 1'b1;
                    end
                end else begin
                    if (cyc == (cd_at + 100)) cd_intrq = 1'b0;

                    if (!cd_done && irq10) begin
                        tmp = cyc - cd_at;
                        if ((tmp >= 0) && (tmp <= 3)) begin
                            cd_done = 1'b1;
                            $display("Phase C (CD-ROM INTRQ): IRQ10 pulse %0d cycle(s) after cd_intrq rise", tmp);
                            $display("PASS");
                            $finish;
                        end else begin
                            $display("FAIL phase C: first IRQ10 pulse %0d cycles after cd_intrq rise, expected <= 3",
                                     tmp);
                            $finish;
                        end
                    end

                    if (!cd_done && (cyc > (cd_at + 20))) begin
                        $display("FAIL phase C: no IRQ10 pulse within 3 cycles of cd_intrq rise");
                        $finish;
                    end
                end
            end

            vbl_q = vblank;
        end
    end

endmodule
