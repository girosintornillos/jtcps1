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
    Date: 28-1-2021 */


module jtcps2_raster(
    input              rst,
    input              clk,
    input              pxl_cen,

    input              frame_start,
    input              line_start,

    // interface with CPU
    input       [ 2:0] cnt_sel,
    input              wrn,
    input       [15:0] cpu_dout,
    output reg  [ 8:0] cnt_dout,

    output reg         raster       // raster event
);

wire [8:0] dout0, dout1, dout2, din;
wire [2:0] we, zero;
wire       en_in;
wire       restart, step;
reg        cnt4;
wire       cen4;

assign cen4  = pxl_cen & cnt4;
assign en_in = cpu_dout[15];
assign din   = cpu_dout[8:0];
assign we    = {3{~wrn}} & cnt_sel;

assign restart = pxl_cen && frame_start;
assign step    = pxl_cen && line_start;

always @(posedge clk) begin
    cnt_dout <= cnt_sel[0] ? dout0 : (cnt_sel[1] ? dout1 : dout2);
    raster   <= zero[2] & (|zero[1:0]);
    if( pxl_cen ) cnt4 <= ~cnt4;
end

initial begin
    cnt4 <= 0;
end

jtcps2_raster_cnt u_cnt0(
    .rst    ( rst       ),
    .clk    ( clk       ),
    .cen4   ( cen4      ),

    .restart( restart   ),
    .step   ( step      ),

    .we     ( we[0]     ),
    .en_in  ( en_in     ),
    .din    ( din       ),
    .dout   ( dout0     ),

    .zero   ( zero[0]   )
);

jtcps2_raster_cnt u_cnt1(
    .rst    ( rst       ),
    .clk    ( clk       ),
    .cen4   ( cen4      ),

    .restart( restart   ),
    .step   ( step      ),

    .we     ( we[1]     ),
    .en_in  ( en_in     ),
    .din    ( din       ),
    .dout   ( dout1     ),

    .zero   ( zero[1]   )
);

jtcps2_raster_cnt u_cnt2(
    .rst    ( rst       ),
    .clk    ( clk       ),
    .cen4   ( cen4      ),

    .restart( restart   ),
    .step   ( step      ),

    .we     ( we[2]     ),
    .en_in  ( en_in     ),
    .din    ( din       ),
    .dout   ( dout2     ),

    .zero   ( zero[2]   )
);
endmodule

module jtcps2_raster_cnt(
    input              rst,
    input              clk,
    input              cen4,

    input              restart,
    input              step,

    input              we,
    input              en_in,
    input       [ 8:0] din,
    output reg  [ 8:0] dout,

    output reg         zero       // raster event
);

reg  [8:0] cnt_start, cnt;
reg        enable;

always @(posedge clk, posedge rst) begin
    if( rst ) begin
        cnt       <= ~9'd0;
        cnt_start <= ~9'd0;
        dout      <= ~9'd0;
        enable    <= 0;
    end else begin
        zero <= cnt == 9'd0;
        if(cen4) dout <= enable ? cnt : cnt_start;
        if( we ) begin
            cnt_start <= din;
            enable    <= en_in;
        end
        if( we )
            cnt <= din;
        else if( restart || !enable )
            cnt <= cnt_start;
        else if( enable && step )
            cnt <= cnt-9'd1;
    end
end

endmodule