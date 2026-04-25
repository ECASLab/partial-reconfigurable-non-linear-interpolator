`timescale 1ns / 1ps

package dut_64x64_axis_wrapper_scoreboard_pkg;
  import axi4stream_vip_pkg::*;
  import dut_64x64_axis_wrapper_test_pkg::*;

  class dut_64x64_axis_wrapper_scoreboard;
    protected dut_64x64_axis_expected_beat_t expected_q[$];
    protected int checked_count;
    protected int error_count;

    function new();
      reset();
    endfunction

    function void reset();
      expected_q.delete();
      checked_count = 0;
      error_count = 0;
    endfunction

    function void expect_result(input logic [63:0] a, input logic [63:0] b, input bit last);
      dut_64x64_axis_expected_beat_t exp;

      exp.data = predict_result(a, b);
      exp.keep = AXIS_FULL_KEEP;
      exp.last = last;

      expected_q.push_back(exp);
    endfunction

    function int pending_count();
      return expected_q.size();
    endfunction

    function int get_checked_count();
      return checked_count;
    endfunction

    function int get_error_count();
      return error_count;
    endfunction

    function void check_output(input axi4stream_monitor_transaction monitor_item);
      dut_64x64_axis_expected_beat_t exp;
      xil_axi4stream_data_beat raw_data;
      xil_axi4stream_strb_beat raw_keep;
      logic [127:0] actual_data;
      logic [15:0] actual_keep;
      bit actual_last;

      raw_data = monitor_item.get_data_beat();
      raw_keep = monitor_item.get_keep_beat();
      actual_data = raw_data[127:0];
      actual_keep = raw_keep[15:0];
      actual_last = monitor_item.get_last();

      if (expected_q.size() == 0) begin
        error_count++;
        $error(
          "Unexpected output beat: data=0x%032h keep=0x%04h last=%0b",
          actual_data,
          actual_keep,
          actual_last
        );
        return;
      end

      exp = expected_q.pop_front();
      checked_count++;

      if ((actual_data !== exp.data) || (actual_keep !== exp.keep) || (actual_last !== exp.last)) begin
        error_count++;
        $error(
          "Beat %0d mismatch: expected data=0x%032h keep=0x%04h last=%0b, got data=0x%032h keep=0x%04h last=%0b",
          checked_count,
          exp.data,
          exp.keep,
          exp.last,
          actual_data,
          actual_keep,
          actual_last
        );
      end
    endfunction

    function void final_check(input string test_name);
      if (error_count != 0) begin
        $fatal(1, "[%s] Scoreboard reported %0d mismatches", test_name, error_count);
      end

      if (expected_q.size() != 0) begin
        $fatal(1, "[%s] Scoreboard still has %0d pending beats", test_name, expected_q.size());
      end
    endfunction
  endclass
endpackage
