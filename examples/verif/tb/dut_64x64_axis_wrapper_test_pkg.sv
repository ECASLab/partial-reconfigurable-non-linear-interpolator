`timescale 1ns / 1ps

package dut_64x64_axis_wrapper_test_pkg;
  parameter logic [15:0] AXIS_FULL_KEEP = 16'hFFFF;

  typedef struct packed {
    logic [63:0] a;
    logic [63:0] b;
    bit          last;
  } dut_64x64_axis_input_beat_t;

  typedef struct packed {
    logic [127:0] data;
    logic [15:0]  keep;
    bit           last;
  } dut_64x64_axis_expected_beat_t;

  function automatic logic [127:0] pack_operands(input logic [63:0] a, input logic [63:0] b);
    return {a, b};
  endfunction

  function automatic string dut_model_name();
`ifdef DUT_MODEL_MUL
    return "mul";
`elsif DUT_MODEL_XOR
    return "xor";
`else
    return "unknown";
`endif
  endfunction

  function automatic logic [127:0] predict_result(input logic [63:0] a, input logic [63:0] b);
`ifdef DUT_MODEL_MUL
    logic [127:0] a_ext;
    logic [127:0] b_ext;

    a_ext = {64'd0, a};
    b_ext = {64'd0, b};

    return a_ext * b_ext;
`elsif DUT_MODEL_XOR
    return {64'd0, (a ^ b)};
`else
    return 128'hX;
`endif
  endfunction
endpackage
