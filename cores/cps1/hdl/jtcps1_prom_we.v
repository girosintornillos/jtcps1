/*  This file is part of JTCPS1.
    JTCPS1 program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    JTCPS1 program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with JTCPS1.  If not, see <http://www.gnu.org/licenses/>.

    Author: Jose Tejada Gomez. Twitter: @topapate
    Version: 1.0
    Date: 30-1-2020 */

module jtcps1_prom_we #(
parameter        CPS=1, // 1, 15, or 2
                 REGSIZE=24, // This is defined at _game level
parameter [21:0] CPU_OFFSET =22'h0,
                 SND_OFFSET =22'h0,
                 PCM_OFFSET =22'h0,
                 GFX_OFFSET =22'h0,
parameter [ 5:0] CFG_BYTE   =6'd39, // location of the byte with encoder information
parameter        EEPROM_AW  = 7
)(
    input                clk,
    input                downloading,
(*keep*)    input      [24:0]    ioctl_addr,    // max 32 MB
(*keep*)    input      [ 7:0]    ioctl_data,
    output     [ 7:0]    ioctl_data2sd,
(*keep*)    input                ioctl_wr,
    input                ioctl_ram,
    output reg [21:0]    prog_addr,
    output     [15:0]    prog_data,
    output reg [ 1:0]    prog_mask, // active low
    output reg [ 1:0]    prog_ba,
    output reg           prog_we,
    output reg           prom_we,   // for Q-Sound internal ROM
    input                prog_rdy,
    output reg           cfg_we,
    output               dwnld_busy,
    // EEPROM
    output reg [15:0]    dump_din,
    input      [15:0]    dump_dout,
    output     [EEPROM_AW-1:0]    dump_addr,
    output reg           dump_we,
    // Kabuki decoder (CPS 1.5)
    output               kabuki_we,
    // CPS2 keys
    output reg           cps2_key_we,
    output reg [ 1:0]    joymode
);

assign dwnld_busy = downloading;

// The start position header has 16 bytes, from which 6 are actually used and
// 10 are reserved
localparam START_BYTES   = 8,
           START_HEADER  = 16,
           STARTW        = 8*START_BYTES;

localparam [24:0] FULL_HEADER   = 25'd64,
                  KABUKI_HEADER = 25'd48,
                  KABUKI_END    = KABUKI_HEADER + 25'd11,
                  CPS2_KEYS     = 25'd44,
                  CPS2_END      = 25'd64;

localparam [ 5:0] JOY_BYTE      = 6'h28;

reg  [STARTW-1:0] starts;
wire       [15:0] snd_start, pcm_start, gfx_start, qsnd_start, qsnd_end;
reg        [ 7:0] pre_data;
reg        [ 1:0] kabuki_sr; // For 96MHz the write pulse must last two cycles

assign snd_start  = starts[15: 0];
assign pcm_start  = starts[31:16];
assign gfx_start  = starts[47:32];
assign qsnd_start = starts[63:48];
assign qsnd_end   = starts[63:48]+16'h7;
assign prog_data  = {2{pre_data}};
`ifdef CPS15
assign kabuki_we  = kabuki_sr[0];
`else
assign kabuki_we  = 0;
`endif

wire [24:0] bulk_addr = ioctl_addr - FULL_HEADER; // the header is excluded
wire [24:0] cpu_addr  = bulk_addr ; // the header is excluded
wire [24:0] snd_addr  = bulk_addr - { snd_start[14:0], 10'd0 };
wire [24:0] pcm_addr  = bulk_addr - { pcm_start[14:0], 10'd0 };
reg  [24:0] gfx_addr;
reg  [ 1:0] gfx_bank;

wire is_cps    = ioctl_addr > 7 && ioctl_addr < (REGSIZE+START_HEADER);
wire is_kabuki = ioctl_addr >= KABUKI_HEADER && ioctl_addr < KABUKI_END;
wire is_cps2   = ioctl_addr >= CPS2_KEYS && ioctl_addr < CPS2_END;
wire is_cpu    = bulk_addr[24:10] < snd_start;
wire is_snd    = bulk_addr[24:10] < pcm_start  && bulk_addr[24:10] >=snd_start;
wire is_oki    = bulk_addr[24:10] < gfx_start  && bulk_addr[24:10] >=pcm_start;
wire is_gfx    = bulk_addr[24:10] < qsnd_start && bulk_addr[24:10] >=gfx_start;
wire is_qsnd   = ioctl_addr >= FULL_HEADER && bulk_addr[24:10] >=qsnd_start; // Q-Sound ROM

reg       decrypt, pang3, pang3_bit;
reg [7:0] pang3_decrypt;

//localparam SWM=19, SWL=3;
//localparam SWM=24, SWL=2;
localparam SWM=24, SWL=4;

always @(*) begin
    gfx_addr  = bulk_addr - { gfx_start[14:0], 10'd0 };
`ifdef CPS2
    // CPS2 address lines are scrambled
    gfx_addr = { gfx_addr[24:21], gfx_addr[3], gfx_addr[20:4], gfx_addr[2:0] };
    gfx_bank = {1'b1, gfx_addr[23]};
`else
    gfx_bank  = 2'b11;
`endif
end


// The decryption is literally copied from MAME, it is up to
// the synthesizer to optimize the code. And it will.
always @(*) begin
    if( CPS==1 ) begin
        pang3 = is_cpu && cpu_addr[19] && decrypt  && (cpu_addr[0]^pang3_bit);
        pang3_decrypt =
            (((((((ioctl_data[0] ? 8'h04 : 8'h00)  ^
                  (ioctl_data[1] ? 8'h21 : 8'h00)) ^
                  (ioctl_data[2] ? 8'h01 : 8'h00)) ^
                  (ioctl_data[3] ? 8'h00 : 8'h50)) ^
                  (ioctl_data[4] ? 8'h40 : 8'h00)) ^
                  (ioctl_data[5] ? 8'h06 : 8'h00)) ^
                  (ioctl_data[6] ? 8'h08 : 8'h00)) ^
                  (ioctl_data[7] ? 8'h00 : 8'h88);
    end else begin
        pang3 = 0;
        pang3_decrypt = 8'd0;
    end
end

always @(posedge clk) begin
    if ( ioctl_wr && !ioctl_ram ) begin
        pre_data  <= pang3 ?
            pang3_decrypt : ioctl_data;
        prog_mask <= !ioctl_addr[0] ? 2'b10 : 2'b01;
        prog_addr <= is_cpu ? bulk_addr[22:1] + CPU_OFFSET : (
                     is_snd ?  snd_addr[22:1] + SND_OFFSET : (
                     is_oki ?  pcm_addr[22:1] + PCM_OFFSET :
                     is_gfx ?  gfx_addr[22:1] + GFX_OFFSET : {9'd0, bulk_addr[12:0]}));
        prog_ba   <= is_cpu ? 2'd0 : ( is_gfx ? gfx_bank : 2'd1 );
        if( is_kabuki )
            kabuki_sr <= 2'b11;
        if( is_cps2 ) begin
            cps2_key_we <= 1;
        end
        if( ioctl_addr < START_BYTES[24:0] ) begin
            starts  <= { ioctl_data, starts[STARTW-1:8] };
            cfg_we  <= 1'b0;
            prog_we <= 1'b0;
            prom_we <= 1'b0;
        end else begin
            if( is_cps ) begin
                cfg_we    <= 1'b1;
                prog_we   <= 1'b0;
                prom_we   <= 1'b0;
                if( ioctl_addr[5:0] == CFG_BYTE )
                    {decrypt, pang3_bit} <= ioctl_data[7:6];
            end else if(ioctl_addr>=FULL_HEADER) begin
                cfg_we    <= 1'b0;
                prog_we   <= ~is_qsnd;
                prom_we   <=  is_qsnd;
            end else if( ioctl_addr[5:0] == JOY_BYTE ) begin
                joymode <= ioctl_data[1:0]; // only CPS2
            end
        end
    end
    else begin
        cps2_key_we <= 0;
        if(!downloading || prog_rdy) prog_we  <= 1'b0;
        if( !downloading ) begin
            decrypt    <= 0;
            prom_we    <= 0;
            // dwnld_busy <= 0;
        end
        kabuki_sr <= kabuki_sr>>1;
        cfg_we    <= 0;
    end
end

// EEPROM 16 bit parallel interface <-> 8 bit dump interface
assign dump_addr = ioctl_addr[EEPROM_AW:1];
assign ioctl_data2sd = ioctl_addr[0] ? dump_dout[15:8] : dump_dout[7:0];

initial begin
    dump_we  = 0;
    dump_din = 16'd0;
end

always @(posedge clk) begin
    dump_we <= 0;
    if (ioctl_wr && ioctl_ram) begin
        dump_we <= 1;
        if(ioctl_addr[0]) begin
            dump_din[15:8] <= ioctl_data;
        end else begin
            dump_din[7:0] <= ioctl_data;
        end
    end
end

endmodule