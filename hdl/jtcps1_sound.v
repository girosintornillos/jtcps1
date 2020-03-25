/*  This file is part of JTCPS1.
    JTCPS1 program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    JTCPS1 program is distributed in the hope that it will be useful,
(*keep*)     but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with JTCPS1.  If not, see <http://www.gnu.org/licenses/>.

    Author: Jose Tejada Gomez. Twitter: @topapate
    Version: 1.0
    Date: 28-1-2020 */

module jtcps1_sound(
    input           rst,
    input           clk,    

    // Interface with main CPU
    input   [7:0]   snd_latch0,
    input   [7:0]   snd_latch1,

    input            enable_adpcm,
    input            enable_fm,

    // ROM
    output  reg [15:0]  rom_addr,
(*keep*)    output  reg         rom_cs,
    input       [ 7:0]  rom_data,
(*keep*)    input               rom_ok,

    // ADPCM ROM
    output      [17:0]       adpcm_addr,
    output                   adpcm_cs,
    input       [ 7:0]       adpcm_data,
    input                    adpcm_ok,

    // Sound output
    output reg signed [15:0] left,
    output reg signed [15:0] right,
    output                   sample
);

wire pre_fm, pre_fm2, cen_oki, nc, cpu_cen;
reg  cen_fm, cen_fm2;
wire signed [13:0] adpcm_snd;
wire signed [15:0] fm_left, fm_right;

function signed [15:0] sum_snd;
    input               enable_fm;
    input               enable_adpcm;
    input signed [15:0] fm;
    input signed [13:0] adpcm;
    sum_snd = (enable_fm ? { {1{fm[15]}}, fm[15:1]  } : 16'd0) + 
        (enable_adpcm ? {    adpcm[13]  , adpcm, adpcm[12] } : 16'd0 );
endfunction

always @(posedge clk) begin
    left  <= sum_snd( enable_fm, enable_adpcm, fm_left,  adpcm_snd );  
    right <= sum_snd( enable_fm, enable_adpcm, fm_right, adpcm_snd );  
end

jtframe_cen3p57 u_fmcen(
    .clk        (  clk       ),       // 48 MHz
    .cen_3p57   (  pre_fm    ),
    .cen_1p78   (  pre_fm2   )
);

jtframe_frac_cen u_okicen(
    .clk        (  clk              ),
    .n          ( 10'd1             ),
    .m          ( 10'd48            ),
    .cen        ( { nc, cen_oki }   ),
    .cenb       (                   )
);

// Make JT51 clock enable happen at the same time than the CPU's
always @(posedge clk) begin
    { cen_fm, cen_fm2 } <= { pre_fm, pre_fm2 };
end

(*keep*) wire [15:0] A;
(*keep*) reg  fm_cs, latch0_cs, latch1_cs, ram_cs, oki_cs, oki7_cs, bank_cs;
(*keep*) reg  oki7;
(*keep*) wire mreq_n, int_n;
wire WRn, oki_wrn;

reg  bank;
wire  io_cs = !mreq_n && A[15:12] == 4'b1111;

wire [7:0] oki_dout;

assign oki_wrn = ~(oki_cs & ~WRn);

always @(posedge clk) begin
    rom_cs    <= !mreq_n && (!A[15] || A[15:14]==2'b10);
    rom_addr  <= A[15] ? { 1'b1, bank, A[13:0] } : { 1'b0, A[14:0] };
    ram_cs    <= !mreq_n && A[15:12] == 4'b1101;
    fm_cs     <= io_cs && A[3:1]==3'd0;
    oki_cs    <= io_cs && A[3:1]==3'd1;
    bank_cs   <= io_cs && A[3:1]==3'd2;
    oki7_cs   <= io_cs && A[3:1]==3'd3;
    latch0_cs <= io_cs && A[3:1]==3'd4;
    latch1_cs <= io_cs && A[3:1]==3'd5;
end

wire rd_n;
wire wr_n;

wire RAM_we = ram_cs && !WRn;
wire [7:0] ram_dout, dout, fm_dout;

assign WRn = wr_n | mreq_n;

always @(posedge clk, posedge rst) begin
    if(rst) begin
        bank <= 1'b0;
        oki7 <= 1'b0;
    end else begin
        if(bank_cs) bank <= dout[0];
        if(oki7_cs) oki7 <= dout[0];
    end
end

jtframe_ram #(.aw(11)) u_ram(
    .clk    ( clk      ),
    .cen    ( 1'b1     ),
    .data   ( dout     ),
    .addr   ( A[10:0]  ),
    .we     ( RAM_we   ),
    .q      ( ram_dout )
);

// As we operate much faster than cen_fm, the input data mux is done
// in two clock cycles. Data will always be ready before next cen_fm pulse
// 
reg [7:0] din, cmd_latch, dev_latch, mem_latch;
reg       latch_cs, dev_cs, mem_cs;

always @(posedge clk) begin
    cmd_latch <= latch0_cs ? snd_latch0 : snd_latch1;
    latch_cs  <= latch1_cs | latch0_cs;
    dev_latch <= fm_cs ? fm_dout : oki_dout;
    dev_cs    <= fm_cs | oki_cs;
    mem_latch <= ram_cs ? ram_dout : rom_data;
    mem_cs    <= ram_cs | rom_cs;
    case( 1'b1 )
        dev_cs:    din <= dev_latch;
        latch_cs:  din <= cmd_latch;
        mem_cs:    din <= mem_latch;
        default:   din <= 8'hff;
    endcase
end

wire iorq_n, m1_n;
(*keep*) wire irq_ack = !iorq_n && !m1_n;

jtframe_z80_romwait u_cpu(
    .rst_n      ( ~rst        ),
    .clk        ( clk         ),
    .cen        ( pre_fm      ),
    .cpu_cen    ( cpu_cen     ),
    .int_n      ( int_n       ),
    .nmi_n      ( 1'b1        ),
    .busrq_n    ( 1'b1        ),
    .m1_n       ( m1_n        ),
    .mreq_n     ( mreq_n      ),
    .iorq_n     ( iorq_n      ),
    .rd_n       ( rd_n        ),
    .wr_n       ( wr_n        ),
    .rfsh_n     (             ),
    .halt_n     (             ),
    .busak_n    (             ),
    .A          ( A           ),
    .din        ( din         ),
    .dout       ( dout        ),
    // manage access to ROM data from SDRAM
    .rom_cs     ( rom_cs      ),
    .rom_ok     ( rom_ok      )
);

jt51 u_jt51(
    .rst        ( rst       ), // reset
    .clk        ( clk       ), // main clock
    .cen        ( cen_fm    ),
    .cen_p1     ( cen_fm2   ),
    .cs_n       ( !fm_cs    ), // chip select
    .wr_n       ( WRn       ), // write
    .a0         ( A[0]      ),
    .din        ( dout      ), // data in
    .dout       ( fm_dout   ), // data out
    .ct1        (           ),
    .ct2        (           ),
    .irq_n      ( int_n     ),  // I do not synchronize this signal
    // Low resolution output (same as real chip)
    .sample     ( sample    ), // marks new output sample
    .left       (           ),
    .right      (           ),
    // Full resolution output
    .xleft      ( fm_left   ),
    .xright     ( fm_right  ),
    // unsigned outputs for sigma delta converters, full resolution
    .dacleft    (           ),
    .dacright   (           )
);

assign adpcm_cs = 1'b1;

jt6295 u_adpcm(
    .rst        ( rst       ),
    .clk        ( clk       ),
    .cen        ( cen_oki   ),
    .ss         ( oki7      ),
    // CPU interface
    .wrn        ( oki_wrn   ),  // active low
    .din        ( dout      ),
    .dout       ( oki_dout  ),
    // ROM interface
    .rom_addr   ( adpcm_addr),
    .rom_data   ( adpcm_data),
    .rom_ok     ( adpcm_ok  ),
    // Sound output
    .sound      ( adpcm_snd )
);

endmodule