`timescale 1ns / 1ps

module dut_64x64_axis_wrapper_env;
  import dut_64x64_axis_wrapper_vip_pkg::*;

  localparam time CLK_PERIOD = 10ns;
  localparam int DUT_OUT_DEPTH = 16;

  logic clk = 1'b0;
  logic rstn = 1'b0;

  wire [127:0] s_axis_tdata;
  wire         s_axis_tvalid;
  wire         s_axis_tready;
  wire         s_axis_tlast;
  wire [15:0]  s_axis_tkeep;

  wire [127:0] m_axis_tdata;
  wire         m_axis_tvalid;
  wire         m_axis_tready;
  wire         m_axis_tlast;
  wire [15:0]  m_axis_tkeep;

  always #(CLK_PERIOD / 2) clk = ~clk;

  task automatic apply_reset(input int active_cycles = 20, input int settle_cycles = 2);
    $display(
      "[ENV] %0t asserting reset for %0d cycles, settle=%0d",
      $time,
      active_cycles,
      settle_cycles
    );
    rstn <= 1'b0;
    repeat (active_cycles) @(posedge clk);
    rstn <= 1'b1;
    $display("[ENV] %0t deasserted reset", $time);
    repeat (settle_cycles) @(posedge clk);
    $display("[ENV] %0t reset sequence complete", $time);
  endtask

  dut_64x64_axis_wrapper #(
    .OUT_DEPTH(DUT_OUT_DEPTH)
  ) dut (
    .clk(clk),
    .rstn(rstn),
    .s_axis_tdata(s_axis_tdata),
    .s_axis_tvalid(s_axis_tvalid),
    .s_axis_tready(s_axis_tready),
    .s_axis_tlast(s_axis_tlast),
    .s_axis_tkeep(s_axis_tkeep),
    .m_axis_tdata(m_axis_tdata),
    .m_axis_tvalid(m_axis_tvalid),
    .m_axis_tready(m_axis_tready),
    .m_axis_tlast(m_axis_tlast),
    .m_axis_tkeep(m_axis_tkeep)
  );

  axi4stream_vip_v1_1_15_top #(
    .C_AXI4STREAM_SIGNAL_SET(AXIS_VIP_SIGNAL_SET),
    .C_AXI4STREAM_INTERFACE_MODE(0),
    .C_AXI4STREAM_DATA_WIDTH(AXIS_VIP_DATA_WIDTH),
    .C_AXI4STREAM_USER_BITS_PER_BYTE(AXIS_VIP_USER_BITS_PER_BYTE),
    .C_AXI4STREAM_ID_WIDTH(AXIS_VIP_ID_WIDTH),
    .C_AXI4STREAM_DEST_WIDTH(AXIS_VIP_DEST_WIDTH),
    .C_AXI4STREAM_USER_WIDTH(AXIS_VIP_USER_WIDTH),
    .C_AXI4STREAM_HAS_ARESETN(AXIS_VIP_HAS_ARESETN)
  ) in_axis_vip (
    .aclk(clk),
    .aresetn(rstn),
    .aclken(1'b1),
    .s_axis_tvalid(1'b0),
    .s_axis_tready(),
    .s_axis_tdata('0),
    .s_axis_tstrb('0),
    .s_axis_tkeep('0),
    .s_axis_tlast(1'b0),
    .s_axis_tid('0),
    .s_axis_tdest('0),
    .s_axis_tuser('0),
    .m_axis_tvalid(s_axis_tvalid),
    .m_axis_tready(s_axis_tready),
    .m_axis_tdata(s_axis_tdata),
    .m_axis_tstrb(),
    .m_axis_tkeep(s_axis_tkeep),
    .m_axis_tlast(s_axis_tlast),
    .m_axis_tid(),
    .m_axis_tdest(),
    .m_axis_tuser()
  );

  axi4stream_vip_v1_1_15_top #(
    .C_AXI4STREAM_SIGNAL_SET(AXIS_VIP_SIGNAL_SET),
    .C_AXI4STREAM_INTERFACE_MODE(2),
    .C_AXI4STREAM_DATA_WIDTH(AXIS_VIP_DATA_WIDTH),
    .C_AXI4STREAM_USER_BITS_PER_BYTE(AXIS_VIP_USER_BITS_PER_BYTE),
    .C_AXI4STREAM_ID_WIDTH(AXIS_VIP_ID_WIDTH),
    .C_AXI4STREAM_DEST_WIDTH(AXIS_VIP_DEST_WIDTH),
    .C_AXI4STREAM_USER_WIDTH(AXIS_VIP_USER_WIDTH),
    .C_AXI4STREAM_HAS_ARESETN(AXIS_VIP_HAS_ARESETN)
  ) out_axis_vip (
    .aclk(clk),
    .aresetn(rstn),
    .aclken(1'b1),
    .s_axis_tvalid(m_axis_tvalid),
    .s_axis_tready(m_axis_tready),
    .s_axis_tdata(m_axis_tdata),
    .s_axis_tstrb('0),
    .s_axis_tkeep(m_axis_tkeep),
    .s_axis_tlast(m_axis_tlast),
    .s_axis_tid('0),
    .s_axis_tdest('0),
    .s_axis_tuser('0),
    .m_axis_tvalid(),
    .m_axis_tready(1'b0),
    .m_axis_tdata(),
    .m_axis_tstrb(),
    .m_axis_tkeep(),
    .m_axis_tlast(),
    .m_axis_tid(),
    .m_axis_tdest(),
    .m_axis_tuser()
  );
endmodule
