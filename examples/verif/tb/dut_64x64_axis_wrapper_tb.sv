`timescale 1ns / 1ps

module dut_64x64_axis_wrapper_tb #(
  parameter int TESTCASE_ID = 0
);
  import axi4stream_vip_pkg::*;
  import dut_64x64_axis_wrapper_vip_pkg::*;
  import dut_64x64_axis_wrapper_test_pkg::*;
  import dut_64x64_axis_wrapper_scoreboard_pkg::*;

  localparam int TESTCASE_SMOKE = 0;
  localparam int TESTCASE_BACKPRESSURE = 1;
  localparam bit TB_LOG_ENABLE = 1'b1;

  dut_64x64_axis_wrapper_env tb_env();

  dut_64x64_axis_in_vip_mst_t in_agent;
  dut_64x64_axis_out_vip_slv_t out_agent;
  dut_64x64_axis_wrapper_scoreboard scoreboard;
  int tx_count;
  int rx_count;

  task automatic log_message(input string message);
    if (TB_LOG_ENABLE) begin
      $display("[TB] %0t %s", $time, message);
    end
  endtask

  task automatic log_tx(
    input int beat_idx,
    input logic [63:0] a,
    input logic [63:0] b,
    input logic [127:0] expected_product,
    input bit last
  );
    if (TB_LOG_ENABLE) begin
      $display(
        "[TB][TX %0d] %0t a=0x%016h b=0x%016h expected=0x%032h last=%0b",
        beat_idx,
        $time,
        a,
        b,
        expected_product,
        last
      );
    end
  endtask

  task automatic log_rx(
    input int beat_idx,
    input logic [127:0] data,
    input logic [15:0] keep,
    input bit last
  );
    if (TB_LOG_ENABLE) begin
      $display(
        "[TB][RX %0d] %0t data=0x%032h keep=0x%04h last=%0b",
        beat_idx,
        $time,
        data,
        keep,
        last
      );
    end
  endtask

  task automatic init_vips();
    in_agent = new("in_agent", tb_env.in_axis_vip.IF);
    out_agent = new("out_agent", tb_env.out_axis_vip.IF);

    in_agent.vif_proxy.set_dummy_drive_type(XIL_AXI4STREAM_VIF_DRIVE_NONE);
    out_agent.vif_proxy.set_dummy_drive_type(XIL_AXI4STREAM_VIF_DRIVE_NONE);

    in_agent.set_agent_tag("Input AXI4-Stream VIP");
    out_agent.set_agent_tag("Output AXI4-Stream VIP");

    in_agent.set_verbosity(0);
    out_agent.set_verbosity(0);

    in_agent.start_master();
    out_agent.start_slave();
    log_message($sformatf("Selected DUT model: %s", dut_model_name()));
    log_message("AXI4-Stream VIP agents started");
  endtask

  task automatic set_no_backpressure();
    axi4stream_ready_gen ready_gen;

    ready_gen = out_agent.driver.create_ready("ready_no_backpressure");
    ready_gen.set_ready_policy(XIL_AXI4STREAM_READY_GEN_NO_BACKPRESSURE);
    out_agent.driver.send_tready(ready_gen);
    log_message("Configured output ready policy: no backpressure");
  endtask

  task automatic set_osc_backpressure(input int low_time = 3, input int high_time = 2);
    axi4stream_ready_gen ready_gen;

    ready_gen = out_agent.driver.create_ready("ready_oscillating");
    ready_gen.set_ready_policy(XIL_AXI4STREAM_READY_GEN_OSC);
    ready_gen.set_low_time(low_time);
    ready_gen.set_high_time(high_time);
    out_agent.driver.send_tready(ready_gen);
    log_message(
      $sformatf(
        "Configured output ready policy: oscillating low=%0d high=%0d",
        low_time,
        high_time
      )
    );
  endtask

  task automatic send_operands(input logic [63:0] a, input logic [63:0] b, input bit last);
    axi4stream_transaction tx;
    xil_axi4stream_data_beat data_beat;
    xil_axi4stream_strb_beat keep_beat;
    logic [127:0] expected_result;

    tx = in_agent.driver.create_transaction($sformatf("dut_%016h_%016h", a, b));
    data_beat = '0;
    keep_beat = '0;
    data_beat[127:0] = pack_operands(a, b);
    keep_beat[15:0] = AXIS_FULL_KEEP;
    expected_result = predict_result(a, b);

    tx.set_data_beat(data_beat);
    tx.set_keep_beat(keep_beat);
    tx.set_last(last);

    scoreboard.expect_result(a, b, last);
    tx_count++;
    log_tx(tx_count, a, b, expected_result, last);
    in_agent.driver.send(tx);
  endtask

  task automatic collect_outputs();
    axi4stream_monitor_transaction monitor_item;
    xil_axi4stream_data_beat raw_data;
    xil_axi4stream_strb_beat raw_keep;
    logic [127:0] actual_data;
    logic [15:0] actual_keep;
    bit actual_last;

    forever begin
      out_agent.monitor.item_collected_port.get(monitor_item);
      raw_data = monitor_item.get_data_beat();
      raw_keep = monitor_item.get_keep_beat();
      actual_data = raw_data[127:0];
      actual_keep = raw_keep[15:0];
      actual_last = monitor_item.get_last();
      rx_count++;
      log_rx(rx_count, actual_data, actual_keep, actual_last);
      scoreboard.check_output(monitor_item);
    end
  endtask

  task automatic wait_for_scoreboard(input string test_name, input int timeout_cycles);
    repeat (timeout_cycles) begin
      if (scoreboard.pending_count() == 0) begin
        repeat (5) @(posedge tb_env.clk);
        scoreboard.final_check(test_name);
        return;
      end

      @(posedge tb_env.clk);
    end

    scoreboard.final_check(test_name);
  endtask

  task automatic run_smoke_test();
    tx_count = 0;
    rx_count = 0;
    log_message("Running smoke test");

    scoreboard.reset();
    tb_env.apply_reset();
    set_no_backpressure();

    send_operands(64'h0000_0000_0000_0000, 64'h0000_0000_0000_0000, 1'b0);
    send_operands(64'h0000_0000_0000_0001, 64'h0000_0000_0000_0001, 1'b0);
    send_operands(64'h0000_0000_0000_0002, 64'h0000_0000_0000_0003, 1'b0);
    send_operands(64'hFFFF_FFFF_FFFF_FFFF, 64'h0000_0000_0000_0002, 1'b0);
    send_operands(64'h0123_4567_89AB_CDEF, 64'hFEDC_BA98_7654_3210, 1'b1);

    wait_for_scoreboard("smoke", 200);
  endtask

  task automatic run_backpressure_test();
    int i;
    logic [63:0] a;
    logic [63:0] b;

    tx_count = 0;
    rx_count = 0;
    log_message("Running backpressure test");

    scoreboard.reset();
    tb_env.apply_reset();
    set_osc_backpressure(4, 2);

    for (i = 0; i < 12; i++) begin
      a = 64'h1000_0000_0000_0000 + i;
      b = 64'h0000_0000_0000_0011 + (i * 64'd5);
      send_operands(a, b, (i == 11));
    end

    wait_for_scoreboard("backpressure", 500);
  endtask

  initial begin
    string testcase_name;

    scoreboard = new();
    init_vips();

    fork
      collect_outputs();
    join_none

    if (TESTCASE_ID == TESTCASE_SMOKE) begin
      testcase_name = "smoke";
      run_smoke_test();
    end else if (TESTCASE_ID == TESTCASE_BACKPRESSURE) begin
      testcase_name = "backpressure";
      run_backpressure_test();
    end else begin
      $fatal(1, "Unknown TESTCASE_ID=%0d", TESTCASE_ID);
    end

    $display(
      "[TB] TESTCASE=%s passed, checked %0d beats",
      testcase_name,
      scoreboard.get_checked_count()
    );
    $finish;
  end
endmodule
