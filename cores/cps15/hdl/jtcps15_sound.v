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
    Date: 19-9-2020 */

module jtcps15_sound(
    input             rst,
    input             clk96,
    input             clk48,
    input             cen8,
    input             vol_up,
    input             vol_down,
    // Decode keys
    input      [31:0] swap_key1,
    input      [31:0] swap_key2,
    input      [15:0] addr_key,
    input      [ 7:0] xor_key,

    // Interface with main CPU
    input      [23:1] main_addr,
    input      [ 7:0] main_dout,
    output reg [ 7:0] main_din,
    input             main_ldswn,
    input             main_buse_n,
    output            main_busakn,

    // ROM
    output reg [18:0] rom_addr, // 512 kByte
    output reg        rom_cs,
    input      [ 7:0] rom_data,
    input             rom_ok,

    // QSound sample ROM
    output reg [22:0] qsnd_addr, // max 8 MB.
    output            qsnd_cs,
    input      [ 7:0] qsnd_data,
    input             qsnd_ok,

    // ROM programming interface
    input      [12:0] prog_addr,
    input      [ 7:0] prog_data,
    input             prog_we,

    // Sound output
    output reg signed [15:0] left,
    output reg signed [15:0] right,
    output reg               sample
);

wire        cpu_cen, cen_extra;
wire [ 7:0] dec_dout, ram_dout, cpu_dout, bus_din;
wire [15:0] A, bus_A;
reg  [ 3:0] bank;
reg  [ 7:0] cpu_din;
reg         rstn, rom_ok2;
reg         ram_cs, bank_cs, qsnd_wr, qsnd_rd;
wire        ram_we, main_we, int_n, mreq_n, wr_n, rd_n;
wire        busrq_n, busak_n, halt_n, z80_buswn;
wire        bus_wrn, bus_mreqn, main_busn;
reg         main_busn_dly;

// QSound registers
reg        [23:0] cpu2dsp;
reg               dsp_irq; // UR6B in schematics
reg        [12:0] vol; // volume moves in 2dB steps
reg        [ 1:0] dsp_datasel;
reg signed [15:0] reg_left, reg_right;

// DSP16 wires
wire [15:0] dsp_ab, dsp_rb_din, dsp_pbus_out, dsp_serout;
reg  [15:0] dsp_pbus_in;
wire        dsp_pods_n, dsp_pids_n;
wire        dsp_do, dsp_ock, dsp_doen;
wire        dsp_iack, dsp_ext_rq;
reg         dsp_rst;
wire        dsp_psel, dsp_sadd, dsp_rdy_n;
wire        dsp_cen_cko;
reg         cen_dsp;
wire        cen60, cen30;

reg         last_pids_n;

`ifndef NODSP
assign      dsp_rdy_n = ~(dsp_irq | dsp_iack);

reg [3:0] dsp_miss;

jtframe_frac_cen #(.W(2)) u_dsp_cen(
    .clk    ( clk96   ),
    .n      ( 10'd5   ),    // numerator
    .m      ( 10'd8   ),    // denominator
    .cen    ( {cen30, cen60 }  ),
    .cenb   (         )     // 180 shifted
);


always @(posedge clk96, posedge rst) begin
    if( rst ) begin
        cen_dsp  <= 1;
        dsp_miss <= 4'd0;
    end else begin
        if( cen60 ) begin
            if(qsnd_ok | ~dsp_ext_rq )
                cen_dsp <= 1;
            else begin
                cen_dsp <= 0;
                if( dsp_miss!=4'hf ) dsp_miss <= dsp_miss+4'd1;
            end
        end else begin
            if( dsp_miss == 4'd0 )
                cen_dsp <= 0;
            else if( qsnd_ok | ~dsp_ext_rq ) begin
                cen_dsp <= 1;
                dsp_miss <= dsp_miss - 4'd1;
            end
        end
    end
end

`else
reg rdy_reads, last_rd;
assign      dsp_rdy_n = rdy_reads;

always @(posedge clk48, posedge rst) begin
    if( rst ) begin
        rdy_reads <= 0;
        last_rd   <= 0;
    end else begin
        last_rd <= qsnd_rd;
        if( !qsnd_rd && last_rd ) rdy_reads <= ~rdy_reads;
    end
end
`endif

`ifdef SIMULATION
wire bank_access = rom_cs & A[15];
`endif

assign ram_we      = ram_cs && !bus_wrn;
assign bus_A       = main_busn ?        A : main_addr[16:1];
assign bus_wrn     = main_busn ?     wr_n : main_ldswn;
assign bus_din     = main_busn ? cpu_dout : main_dout;
assign bus_mreqn   = main_busn & mreq_n;
assign main_busakn = main_busn_dly | (rom_cs & ~rom_ok2);

always @(posedge clk48) begin
    main_din <= cpu_din; // bus output
    main_busn_dly <= main_busn;
end

always @(negedge clk48) begin
    rstn <= ~rst;
end

always @(posedge clk48, posedge rst) begin
    if ( rst ) begin
        rom_cs    <= 0;
        rom_ok2   <= 0;
        rom_addr  <= 16'd0;
        ram_cs    <= 0;
        bank_cs   <= 0;
        qsnd_wr   <= 0;
        qsnd_rd   <= 0;
    end else begin
        rom_ok2  <= rom_ok;
        rom_cs   <= !bus_mreqn && (!bus_A[15] || bus_A[15:14]==2'b10);
        if(!bus_mreqn)
            rom_addr <= bus_A[15] ? ({ 1'b0, bank, bus_A[13:0] } + 19'h8000) : { 4'b0, bus_A[14:0] };
        ram_cs   <= !bus_mreqn && (bus_A[15:12] == 4'hc || bus_A[15:12]==4'hf);
        qsnd_wr  <= !bus_mreqn && !bus_wrn && (bus_A[15:12] == 4'hd && bus_A[2:0]<=3'd2);
        bank_cs  <= !bus_mreqn && !bus_wrn && (bus_A[15:12] == 4'hd && bus_A[2:0]==3'd3);
        qsnd_rd  <= !bus_mreqn && !rd_n && (bus_A[15:12] == 4'hd && bus_A[2:0]==3'd7);
    end
end

// wire qs0l_w = qsnd_wr && A[2:0]==2'd0;
// wire qs0h_w = qsnd_wr && A[2:0]==2'd1;
wire qs1l_w = qsnd_wr && A[2:0]==2'd2;
reg [23:0] cpu2dsp_s;

always @(posedge clk48, posedge rst) begin
    if ( rst ) begin
        bank    <= 4'd0;
        cpu2dsp <= 24'd0;
        dsp_rst <= 1;
    end else begin
        if( bank_cs ) begin
            bank    <= bus_din[3:0];
            dsp_rst <= ~bus_din[7];
        end
        if( qsnd_wr ) begin
            case( A[2:0] )
                2'd0: cpu2dsp[15: 8] <= bus_din; // data word MSB
                2'd1: cpu2dsp[ 7: 0] <= bus_din; // data word LSB
                2'd2: cpu2dsp[23:16] <= bus_din; // address
                default:;
            endcase // A[2:0]
        end
    end
end

always @(*) begin
    cpu_din =  rom_cs ? ( A[15] ? rom_data : dec_dout ) : (
               ram_cs ? ram_dout : (
              qsnd_rd ? { dsp_rdy_n, 3'b111, bank } : 8'hff
              ));
end

jtcps15_z80buslock u_buslock(
    .clk        ( clk48            ),
    .rst        ( rst              ),
    .cen8       ( cen8             ),
    .busrq_n    ( busrq_n          ),
    .busak_n    ( busak_n          ),
    // Signals from M68000
    .buse_n     ( main_buse_n      ),
    .m68_addr   ( main_addr[23:12] ),
    .m68_buswen ( main_ldswn       ),
    .z80_buswn  ( z80_buswn        ),
    .m68_busakn ( main_busn        )
);

jtcps15_z80int u_z80int(
    .clk    ( clk48     ),
    .rst    ( rst       ),
    .cen8   ( cen8      ),
    .m1_n   ( m1_n      ),
    .iorq_n ( iorq_n    ),
    .int_n  ( int_n     )
);

jtcps15_z80wait u_extrawait(
    .clk    ( clk48     ),
    .rst    ( rst       ),
    .cen8   ( cen8      ),
    .m1_n   ( m1_n      ),
    .addr   ( A[15:12]  ),
    .cen_cpu( cen_extra )
);

jtframe_ram #(.aw(13)) u_z80ram( // 8 kB!
    .clk    ( clk48         ),
    .cen    ( 1'b1          ),
    .data   ( bus_din      ),
    .addr   ( bus_A[12:0]   ),
    .we     ( ram_we        ),
    .q      ( ram_dout      )
);

jtframe_kabuki /*#(.LATCH(1)) */ u_kabuki(
    .rst_n      ( rstn        ),
    .clk        ( clk48       ),
    .m1_n       ( m1_n        ),
    .mreq_n     ( mreq_n      ),
    .rd_n       ( rd_n        ),
    .addr       ( A           ),
    .din        ( rom_data    ),
    // Decode keys
    .swap_key1  ( swap_key1   ),
    .swap_key2  ( swap_key2   ),
    .addr_key   ( addr_key    ),
    .xor_key    ( xor_key     ),
    .dout       ( dec_dout    )
);

jtframe_z80_romwait #(0) u_cpu(
    .rst_n      ( rstn        ),
    .clk        ( clk48       ),
    .cen        ( cen_extra   ),
    .cpu_cen    ( cpu_cen     ),
    .int_n      ( int_n       ),
    .nmi_n      ( 1'b1        ),
    .busrq_n    ( busrq_n     ),
    .m1_n       ( m1_n        ),
    .mreq_n     ( mreq_n      ),
    .iorq_n     ( iorq_n      ),
    .rd_n       ( rd_n        ),
    .wr_n       ( wr_n        ),
    .rfsh_n     (             ),
    .halt_n     ( halt_n      ),
    .busak_n    ( busak_n     ),
    .A          ( A           ),
    .din        ( cpu_din     ),
    .dout       ( cpu_dout    ),
    // manage access to ROM data from SDRAM
    .rom_cs     ( rom_cs      ),
    .rom_ok     ( rom_ok & rom_ok2     )
);

reg last_vol_up, last_vol_down;
reg last_sadd, last_pods_n, last_psel;
reg audio_ws;
reg dsp_dsel96;

// DSP16 glue logic
always @(posedge clk48, posedge rst) begin
    if ( rst ) begin
        dsp_irq    <= 0;
        dsp_datasel<= 2'd0;
    end else begin
        last_pids_n <= dsp_pids_n;
        if( qs1l_w ) begin
            dsp_irq <= 1; // read MSB
            dsp_datasel <= 2'b11;
        end else begin
            if( dsp_pids_n && !last_pids_n ) begin
                dsp_irq <= 0; // read LSB
                dsp_datasel <= dsp_datasel>>1;
            end
        end
    end
end

reg signed [15:0] pre_l, pre_r;
reg [11:0] sample_cnt;
(*keep*) reg [23:0] sample_cnt2;

always @(posedge clk96, posedge rst) begin
    if( rst ) begin
        sample_cnt <= 12'd0;
        sample_cnt2<= 24'd0;
        cpu2dsp_s  <= 24'd0;
    end else begin
        if( sample ) sample_cnt2 <= sample_cnt2 + 1'd1;
        if( dsp_irq ) cpu2dsp_s <= cpu2dsp;
        if( sample ) begin
            sample_cnt <= 12'd0;
            if( !sample_cnt2[23] ) begin // forces saving of sample_cnt2 signal
                left  <= (left>>>1) + (pre_l>>>1);
                right <= (right>>>1) + (pre_r>>>1);
            end
        end else
            if(sample_cnt!=12'hFFF) sample_cnt <= sample_cnt + 12'd1;
        if( sample_cnt == 12'd3996 ) begin
            left <= pre_l;
            right <= pre_r;
        end
    end
end

always @(posedge clk96, posedge rst) begin
    if ( rst ) begin
        vol        <= 13'b0;   // I think the volume is never actually read by the DSP
        audio_ws   <= 0;
        qsnd_addr  <= 23'd0;
        sample     <= 0;
        pre_l      <= 16'd0;
        pre_r      <= 16'd0;
        dsp_dsel96 <= 0;
    end else begin
        last_pods_n <= dsp_pods_n;
        last_psel   <= dsp_psel;
        dsp_dsel96  <= dsp_datasel[1];
        // volume control
        last_vol_up   <= vol_up;
        last_vol_down <= vol_down;
        // latch sound data
        last_sadd <= dsp_sadd;
        if( !dsp_sadd && last_sadd ) begin
            audio_ws <= dsp_psel;
            // data is taken directly in parallel. The serial
            // interface is bypassed for simplificty
            if( !dsp_psel )
                reg_left  <= dsp_serout;
            else
                reg_right <= dsp_serout;
        end
        if( !last_psel && dsp_psel ) begin
            pre_l <= reg_left;
            pre_r <= reg_right;
            sample <= 1;
        end else begin
            sample <= 0;
        end
        // latch QSound ROM address
        if( dsp_pods_n && !last_pods_n) begin
            qsnd_addr[15:0] <= dsp_pbus_out;
        end
        if( dsp_ab[15] && dsp_cen_cko ) begin
            qsnd_addr[22:16] <= dsp_ab[6:0];/*{ dsp_ab[2:0], dsp_ab[4], dsp_ab[5],
                dsp_ab[6], dsp_ab[7] };*/
        end
    end
end

always @(*) begin
    dsp_pbus_in = dsp_dsel96 ? {8'd0, cpu2dsp_s[23:16]} : cpu2dsp_s[15:0];
end

`ifndef NODSP
wire        dsp_fault;

assign qsnd_cs = 1;

jtdsp16 u_dsp16(
    .rst        ( dsp_rst       ),
    .clk        ( clk96         ),
    .clk_en     ( cen_dsp       ),

    .cen_cko    ( dsp_cen_cko   ),
    .ab         ( dsp_ab        ),  // address bus
    .rb_din     ( { qsnd_data, 8'h0 } ),  // ROM data bus
    .ext_rq     ( dsp_ext_rq    ),
    // Parallel I/O
    .pbus_in    ( dsp_pbus_in   ),
    .pbus_out   ( dsp_pbus_out  ),
    .pods_n     ( dsp_pods_n    ),  // parallel output data strobe
    .pids_n     ( dsp_pids_n    ),  // parallel input  data strobe
    // Serial output
    .sdo        ( dsp_do        ),  // serial data output
    .ock        ( dsp_ock       ),  // output clock
    .doen       ( dsp_doen      ),  // data output enable
    .sadd       ( dsp_sadd      ),  // serial address
    .psel       ( dsp_psel      ),  // peripheral select
    .ser_out    ( dsp_serout    ),
        // Unused by QSound firmware:
    .ose        (               ),  // output shift register empty
    .old        (               ),  // output load
    .ibf        (               ),  // input buffer full
    .di         (               ),  // serial data input
    .ick        (               ),  // serial data input clock
    .ild        (               ),  // serial data input load
    // interrupts
    .irq        ( dsp_irq       ),  // interrupt
    .iack       ( dsp_iack      ),  // interrupt acknowledgement
    // ROM programming interface
    .prog_addr  ( prog_addr     ),
    .prog_data  ( prog_data     ),
    .prog_we    ( prog_we       ),
    // Debug
    .fault      ( dsp_fault     )
);
`else
assign dsp_pbus_out = 16'd0;
assign dsp_pods_n   = 1;
assign dsp_pids_n   = 1;
assign dsp_do       = 1;
assign dsp_ock      = 1;
assign dsp_doen     = 0;
assign dsp_sadd     = 0;
assign dsp_psel     = 0;
assign dsp_ab       = 16'd0;
assign qsnd_cs      = 0;
`endif

endmodule

//////////////////////////// Small modules only instantiated by jtcps15_sound

module jtcps15_z80int(
    input      clk,
    input      rst,
    input      cen8,
    input      m1_n,
    input      iorq_n,
    output reg int_n
);

reg  [14:0] cnt;
wire        cntover = cnt==15'd31999;

always @(posedge clk, posedge rst) begin
    if( rst ) begin
        cnt   <= 15'd0;
        int_n <= 1;
    end else if(cen8) begin
        cnt <= cntover ? 15'd0 : (cnt+15'd1);
        if( !m1_n && !iorq_n )
            int_n <= 1;
        else
            if( cntover ) int_n <= 0;

    end
end

endmodule

// There is an extra cycle for memory OP access above 4000
// This could be to give extra time to Kabuki decode logic

module jtcps15_z80wait(
    input         clk,
    input         rst,
    input         cen8,
    input         m1_n,
    input [15:12] addr,
    output        cen_cpu
);

reg idle;

assign cen_cpu = cen8 & ~idle;

always @(posedge clk, posedge rst) begin
    if( rst )
        idle <= 0;
    else if(cen8) begin
        if( addr>=4'h4 && !m1_n && !idle )
            idle <= 1;
    end
end

endmodule

// M68000 requests and gets the bus in a synchronous way

module jtcps15_z80buslock(
    input         clk,
    input         rst,
    input         cen8,
    output        busrq_n,
    input         busak_n,
    // Signals from M68000
    input         buse_n,   // request from M68000
    input [23:12] m68_addr,
    input         m68_buswen,
    output        z80_buswn,
    output        m68_busakn
);

parameter CPS2=0;

reg  [1:0] latch;

wire shared_addr = CPS2 ? m68_addr[23:16]==8'h61 : (
                   (m68_addr[23:12]>=12'hf18 && m68_addr[23:12]<12'hf1a ) ||
                   (m68_addr[23:12]>=12'hf1e && m68_addr[23:12]<12'hf20 ) );

assign z80_buswn = m68_buswen | m68_busakn;
assign busrq_n   = buse_n; // | ~shared_addr;
assign m68_busakn= latch[1];

always @(posedge clk, posedge rst) begin
    if( rst )
        latch <= 2'b11;
    else begin
        if( buse_n )
            latch<=2'b11;
        else if(cen8) begin
            latch <= { latch[0], busrq_n | busak_n };
        end
    end
end

endmodule