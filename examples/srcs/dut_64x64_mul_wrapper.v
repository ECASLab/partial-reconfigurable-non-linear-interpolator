`timescale 1ns / 1ps

// Multiplier implementation selected when the verification flow uses DUT=mul.
module dut_64x64(
    input  wire         clk,
    input  wire         rstn,
    input  wire         valid_i,
    input  wire [63:0]  a,
    input  wire [63:0]  b,
    output wire         valid_o,
    output wire [127:0] o
);
    mul64x64_segmented_8x8 u_mul64x64 (
        .clk     (clk),
        .rstn    (rstn),
        .valid_i (valid_i),
        .a       (a),
        .b       (b),
        .valid_o (valid_o),
        .o       (o)
    );
endmodule
