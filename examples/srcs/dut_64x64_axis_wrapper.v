module dut_64x64_axis_wrapper #(
    parameter integer OUT_DEPTH   = 16    // output FIFO depth (power-of-two recommended)
)(
    input  wire         clk,
    input  wire         rstn,

    // AXI4-Stream input: {a,b} from DMA MM2S or upstream
    input  wire [127:0] s_axis_tdata,
    input  wire         s_axis_tvalid,
    output wire         s_axis_tready,
    input  wire         s_axis_tlast,   // optional, can ignore
    input  wire [15:0]  s_axis_tkeep,   // optional, can ignore

    // AXI4-Stream output: o to DMA S2MM or downstream
    output wire [127:0] m_axis_tdata,
    output wire         m_axis_tvalid,
    input  wire         m_axis_tready,
    output wire         m_axis_tlast,
    output wire [15:0]  m_axis_tkeep
);

    // -----------------------------
    // Unpack input payload
    // -----------------------------
    wire [63:0] a_in = s_axis_tdata[127:64];
    wire [63:0] b_in = s_axis_tdata[63:0];

    // -----------------------------
    // Output FIFO (simple reg FIFO)
    // -----------------------------
    localparam integer OUT_AW = $clog2(OUT_DEPTH);

    reg [127:0] out_fifo_data [0:OUT_DEPTH-1];
    reg         out_fifo_last [0:OUT_DEPTH-1];
    reg         meta_fifo_last [0:OUT_DEPTH-1];

    reg [OUT_AW:0] wr_ptr;   // +1 bit to detect full/empty
    reg [OUT_AW:0] rd_ptr;
    reg [OUT_AW:0] meta_wr_ptr;
    reg [OUT_AW:0] meta_rd_ptr;
    reg [OUT_AW:0] inflight_count;

    wire fifo_empty = (wr_ptr == rd_ptr);
    wire fifo_full  = (wr_ptr[OUT_AW-1:0] == rd_ptr[OUT_AW-1:0]) &&
                      (wr_ptr[OUT_AW]     != rd_ptr[OUT_AW]);
    wire meta_empty = (meta_wr_ptr == meta_rd_ptr);
    wire meta_full  = (meta_wr_ptr[OUT_AW-1:0] == meta_rd_ptr[OUT_AW-1:0]) &&
                      (meta_wr_ptr[OUT_AW]     != meta_rd_ptr[OUT_AW]);
    wire [OUT_AW:0] fifo_level = wr_ptr - rd_ptr;
    wire [OUT_AW+1:0] pending_outputs = {1'b0, fifo_level} + inflight_count;

    // AXIS output signals driven from FIFO head
    assign m_axis_tvalid = !fifo_empty;
    assign m_axis_tdata  = out_fifo_data[rd_ptr[OUT_AW-1:0]];
    assign m_axis_tlast  = out_fifo_last[rd_ptr[OUT_AW-1:0]];
    assign m_axis_tkeep  = 16'hFFFF; // 128-bit fully valid

    wire pop_out = m_axis_tvalid && m_axis_tready;

    always @(posedge clk) begin
        if (!rstn) begin
            rd_ptr <= {(OUT_AW+1){1'b0}};
        end else if (pop_out) begin
            rd_ptr <= rd_ptr + 1'b1;
        end
    end

    // -----------------------------
    // Core instance
    // -----------------------------
    reg         core_valid_i;
    reg [63:0]  core_a;
    reg [63:0]  core_b;
    wire        core_valid_o;
    wire [127:0] core_o;

    dut_64x64 u_core (
        .clk     (clk),
        .rstn    (rstn),
        .valid_i (core_valid_i),
        .a       (core_a),
        .b       (core_b),
        .valid_o (core_valid_o),
        .o       (core_o)
    );

    // -----------------------------
    // Track TLAST in acceptance order so the wrapper stays agnostic to DUT latency.
    // This assumes the DUT returns exactly one output per accepted input, in order.
    // -----------------------------
    wire accept_in = s_axis_tvalid && s_axis_tready;
    wire push_meta = accept_in;
    wire pop_meta = core_valid_o && !meta_empty;
    wire core_last_aligned = meta_fifo_last[meta_rd_ptr[OUT_AW-1:0]];

    // -----------------------------
    // Input acceptance policy
    // Since core cannot stall, only accept an input when we’re confident we can
    // buffer its output later. Reserve FIFO space for the current in-flight core
    // results so a burst of backpressure cannot drop outputs.
    // -----------------------------
    assign s_axis_tready = (pending_outputs < OUT_DEPTH) && !meta_full;

    always @(posedge clk) begin
        if (!rstn) begin
            core_valid_i <= 1'b0;
            core_a       <= 64'b0;
            core_b       <= 64'b0;
            inflight_count <= {(OUT_AW+1){1'b0}};
            meta_wr_ptr  <= {(OUT_AW+1){1'b0}};
            meta_rd_ptr  <= {(OUT_AW+1){1'b0}};
        end else begin
            core_valid_i <= accept_in;
            if (accept_in) begin
                core_a <= a_in;
                core_b <= b_in;
                meta_fifo_last[meta_wr_ptr[OUT_AW-1:0]] <= s_axis_tlast;
            end

            case ({accept_in, core_valid_o})
                2'b10: inflight_count <= inflight_count + 1'b1;
                2'b01: inflight_count <= inflight_count - 1'b1;
                default: inflight_count <= inflight_count;
            endcase

            case ({push_meta, pop_meta})
                2'b10: meta_wr_ptr <= meta_wr_ptr + 1'b1;
                2'b01: meta_rd_ptr <= meta_rd_ptr + 1'b1;
                2'b11: begin
                    meta_wr_ptr <= meta_wr_ptr + 1'b1;
                    meta_rd_ptr <= meta_rd_ptr + 1'b1;
                end
                default: ;
            endcase
        end
    end

    // -----------------------------
    // Push core outputs into FIFO
    // -----------------------------
    wire push_out = core_valid_o && !fifo_full && !meta_empty;

    // If this ever happens, you are dropping results.
    // With the current policy (tready deassert when full), it should not happen.
    // But keep OUT_DEPTH reasonable to handle DMA backpressure bursts.
    // You can add an assertion here in simulation if you want.

    always @(posedge clk) begin
        if (!rstn) begin
            wr_ptr <= {(OUT_AW+1){1'b0}};
        end else if (push_out) begin
            out_fifo_data[wr_ptr[OUT_AW-1:0]] <= core_o;
            // Option A: preserve packetization:
            out_fifo_last[wr_ptr[OUT_AW-1:0]] <= core_last_aligned;
            // Option B: treat every beat as last:
            // out_fifo_last[wr_ptr[OUT_AW-1:0]] <= 1'b1;

            wr_ptr <= wr_ptr + 1'b1;
        end
    end

endmodule
