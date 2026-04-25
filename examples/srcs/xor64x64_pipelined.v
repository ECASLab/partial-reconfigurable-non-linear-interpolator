`timescale 1ns / 1ps

module xor64x64_pipelined(
    input  wire         clk,
    input  wire         rstn,
    input  wire         valid_i,
    input  wire [63:0]  a,
    input  wire [63:0]  b,
    output reg          valid_o,
    output reg  [127:0] o
    );

    reg [127:0] result_q0;
    reg [127:0] result_q1;
    reg [127:0] result_q2;
    reg         valid_q0;
    reg         valid_q1;
    reg         valid_q2;

    always @(posedge clk) begin
        if (!rstn) begin
            result_q0 <= 128'b0;
            result_q1 <= 128'b0;
            result_q2 <= 128'b0;
            o         <= 128'b0;
            valid_q0  <= 1'b0;
            valid_q1  <= 1'b0;
            valid_q2  <= 1'b0;
            valid_o   <= 1'b0;
        end else begin
            if (valid_i) begin
                result_q0 <= {64'd0, (a ^ b)};
            end else begin
                result_q0 <= 128'd0;
            end

            result_q1 <= result_q0;
            result_q2 <= result_q1;
            o         <= result_q2;

            valid_q0 <= valid_i;
            valid_q1 <= valid_q0;
            valid_q2 <= valid_q1;
            valid_o  <= valid_q2;
        end
    end

endmodule
