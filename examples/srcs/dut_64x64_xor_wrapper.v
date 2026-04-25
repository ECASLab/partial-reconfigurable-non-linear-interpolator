`timescale 1ns / 1ps

module dut_64x64(
    input  wire         clk,
    input  wire         rstn,
    input  wire         valid_i,
    input  wire [63:0]  a,
    input  wire [63:0]  b,
    output wire         valid_o,
    output wire [127:0] o
    );

    xor64x64_pipelined u_xor64x64 (
        .clk     (clk),
        .rstn    (rstn),
        .valid_i (valid_i),
        .a       (a),
        .b       (b),
        .valid_o (valid_o),
        .o       (o)
    );

endmodule
