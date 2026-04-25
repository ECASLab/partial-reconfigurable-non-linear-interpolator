`timescale 1ns / 1ps

package dut_64x64_axis_wrapper_vip_pkg;
  import axi4stream_vip_pkg::*;

  // Signal-set bits: {TUSER, TDEST, TID, TLAST, TKEEP, TSTRB, TDATA, TREADY}
  parameter xil_axi4stream_sigset_t AXIS_VIP_SIGNAL_SET = 8'b00011011;
  parameter int AXIS_VIP_DATA_WIDTH = 128;
  parameter int AXIS_VIP_ID_WIDTH = 0;
  parameter int AXIS_VIP_DEST_WIDTH = 0;
  parameter int AXIS_VIP_USER_WIDTH = 0;
  parameter int AXIS_VIP_USER_BITS_PER_BYTE = 0;
  parameter int AXIS_VIP_HAS_ARESETN = 1;

  typedef axi4stream_mst_agent #(
    AXIS_VIP_SIGNAL_SET,
    AXIS_VIP_DEST_WIDTH,
    AXIS_VIP_DATA_WIDTH,
    AXIS_VIP_ID_WIDTH,
    AXIS_VIP_USER_WIDTH,
    AXIS_VIP_USER_BITS_PER_BYTE,
    AXIS_VIP_HAS_ARESETN
  ) dut_64x64_axis_in_vip_mst_t;

  typedef axi4stream_slv_agent #(
    AXIS_VIP_SIGNAL_SET,
    AXIS_VIP_DEST_WIDTH,
    AXIS_VIP_DATA_WIDTH,
    AXIS_VIP_ID_WIDTH,
    AXIS_VIP_USER_WIDTH,
    AXIS_VIP_USER_BITS_PER_BYTE,
    AXIS_VIP_HAS_ARESETN
  ) dut_64x64_axis_out_vip_slv_t;
endpackage
