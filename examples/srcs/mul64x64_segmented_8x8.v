`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 02/11/2026 09:09:29 PM
// Design Name: 
// Module Name: mul64x64_segmented_8x8
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


module mul64x64_segmented_8x8(
    input  wire         clk,
    input  wire         rstn,
    input  wire         valid_i,
    input  wire [63:0]  a,
    input  wire [63:0]  b,
    output reg          valid_o,
    output reg  [127:0] o
    );
    
    parameter N = 8;
    
    // Logic to split the data into chunks of 8 bits
    
    wire [N-1:0] a_partial [((64+N-1)/N)-1:0];
    wire [N-1:0] b_partial [((64+N-1)/N)-1:0];
    
    genvar partial_var, a_var, b_var;
    
    generate
        for (partial_var = 0; partial_var < N; partial_var = partial_var + 1) begin
            assign a_partial[partial_var] = a[partial_var*N +: N];
            assign b_partial[partial_var] = b[partial_var*N +: N];
        end
    endgenerate
    
    // Apply a distributive rule for the smaller chunks of a and b. Depending of which chunk
    // we are using to operate right now, a shift need to be inserted
    
    wire [127:0] partial_prod [N*N-1:0];
    reg [127:0] partial_prod_reg [N*N-1:0];

    generate
        for (a_var = 0; a_var < N; a_var = a_var + 1) begin
            for (b_var = 0; b_var < N; b_var = b_var + 1) begin
                // Fill bits that contain actual data
                
                mul8x8 mul (
                    .a(a_partial[a_var]),
                    .b(b_partial[b_var]),
                    .o(partial_prod[a_var*N + b_var][(a_var + b_var) * N +: N * 2])
                );

                // Fill bits with 0's below the valid data
                if (a_var + b_var > 0) begin
                    assign partial_prod[a_var*N + b_var][((a_var + b_var) * N) - 1 : 0] = 'b0;
                end
                // Fill bits with 0's above the valid data
                if (a_var + b_var < (N * 2) - 2) begin
                    assign partial_prod[a_var*N + b_var][127 : ((a_var + b_var) * N) + (N * 2)] = 'b0;
                end
                
                // Add registers to help timing after partial products
                
                always @(posedge clk) begin
                    if (!rstn) begin
                        partial_prod_reg[a_var*N + b_var] <= 0;
                    end
                    else begin
                        partial_prod_reg[a_var*N + b_var] <= partial_prod[a_var*N + b_var];
                    end
                end
            end
        end
    endgenerate

    // Add intermediate additions to help timing when adding partial products
    
    reg [127:0] partial_sum_0;
    reg [127:0] partial_sum_0_reg;
    reg [127:0] partial_sum_1;
    reg [127:0] partial_sum_1_reg;
    reg [127:0] partial_sum_2;
    reg [127:0] partial_sum_2_reg;
    reg [127:0] partial_sum_3;
    reg [127:0] partial_sum_3_reg;
    reg [127:0] final_sum;
    integer i;
    
    always @* begin
        partial_sum_0 = 128'b0;
        partial_sum_1 = 128'b0;
        partial_sum_2 = 128'b0;
        partial_sum_3 = 128'b0;
        for (i = 0; i < 16; i = i + 1) begin
            partial_sum_0 = partial_sum_0 +  partial_prod_reg[i];
        end
        for (i = 16; i < 32; i = i + 1) begin
            partial_sum_1 = partial_sum_1 +  partial_prod_reg[i];
        end
        for (i = 32; i < 48; i = i + 1) begin
            partial_sum_2 = partial_sum_2 +  partial_prod_reg[i];
        end
        for (i = 48; i < N*N; i = i + 1) begin
            partial_sum_3 = partial_sum_3 +  partial_prod_reg[i];
        end
    end
    
    always @(posedge clk) begin
        if (~rstn) begin
            partial_sum_0_reg <= 0;
            partial_sum_1_reg <= 0;
            partial_sum_2_reg <= 0;
            partial_sum_3_reg <= 0;
            final_sum <= 0;
        end
        else begin
            partial_sum_0_reg <= partial_sum_0;
            partial_sum_1_reg <= partial_sum_1;
            partial_sum_2_reg <= partial_sum_2;
            partial_sum_3_reg <= partial_sum_3;
            final_sum <= partial_sum_0_reg + partial_sum_1_reg + partial_sum_2_reg + partial_sum_3_reg;
        end
    end
    
    reg valid_q0, valid_q1, valid_q2;

    always @(posedge clk) begin
        if (~rstn) begin
            o <= 0;
            valid_q0 <= 0;
            valid_q1 <= 0;
            valid_q2 <= 0;
            valid_o <= 0;
        end
        else begin
            o <= final_sum;
            valid_q0 <= valid_i;
            valid_q1 <= valid_q0;
            valid_q2 <= valid_q1;
            valid_o <= valid_q2;
        end
    end
    
endmodule
