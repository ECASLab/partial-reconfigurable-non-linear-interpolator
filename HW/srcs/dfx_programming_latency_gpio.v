`timescale 1ns / 1ps

// Measures the time that the reconfigurable region stays both isolated and held
// in reset. This brackets the software-triggered partial reconfiguration window.
//
// GPIO bit layout:
//   gpio_value[0]    = current shutdown status
//   gpio_value[31:1] = last completed reconfiguration window length in clk cycles
module dfx_programming_latency_gpio #(
    parameter integer COUNTER_WIDTH = 31
) (
    input  wire                   clk,
    input  wire                   resetn,
    input  wire                   rp_resetn,
    input  wire                   shutdown_status,
    output wire [COUNTER_WIDTH:0] gpio_value
);

    localparam [COUNTER_WIDTH-1:0] COUNTER_MAX = {COUNTER_WIDTH{1'b1}};

    reg [COUNTER_WIDTH-1:0] active_cycles = {COUNTER_WIDTH{1'b0}};
    reg [COUNTER_WIDTH-1:0] last_cycles = {COUNTER_WIDTH{1'b0}};
    reg measurement_active = 1'b0;

    wire measure_window = shutdown_status & ~rp_resetn;

    always @(posedge clk) begin
        if (!resetn) begin
            active_cycles <= {COUNTER_WIDTH{1'b0}};
            last_cycles <= {COUNTER_WIDTH{1'b0}};
            measurement_active <= 1'b0;
        end else if (!measurement_active) begin
            active_cycles <= {COUNTER_WIDTH{1'b0}};
            if (measure_window) begin
                measurement_active <= 1'b1;
            end
        end else if (measure_window) begin
            if (active_cycles != COUNTER_MAX) begin
                active_cycles <= active_cycles + 1'b1;
            end
        end else begin
            last_cycles <= active_cycles;
            active_cycles <= {COUNTER_WIDTH{1'b0}};
            measurement_active <= 1'b0;
        end
    end

    assign gpio_value = {last_cycles, shutdown_status};

endmodule
