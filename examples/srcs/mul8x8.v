`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 02/16/2026 10:52:30 PM
// Design Name: 
// Module Name: mul8x8
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////


module mul8x8(
    input wire [7:0] a,
    input wire [7:0] b,
    output wire [15:0] o
    );
    
    assign o = a * b;
endmodule
