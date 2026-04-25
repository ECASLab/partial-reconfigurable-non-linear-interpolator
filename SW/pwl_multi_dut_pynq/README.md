# PWL Multi-DUT PYNQ App

This folder contains a PYNQ host application for the `scripts/multi_dut` hardware flow.

The overlay instantiates both PWL HLS kernel slots at once:

- `pwl_exp_0`
- `pwl_sigmoid_0`

Each slot exposes its own AXI-Lite control interface and AXI master memory ports. Each slot can now host either the float32 or float16 implementation of that function:

- exponential slot: `exp` or `exp_f16`
- sigmoid slot: `sigmoid` or `sigmoid_f16`

The app uses `Overlay(...)` metadata to locate the two IP instances, packs input/output words according to each slot precision, validates the hardware outputs against software references, and can sample either a PYNQ power rail or a Linux `hwmon` power sensor before and during repeated DUT execution windows.

## Files

- `app/main.py`: PYNQ application that can run `exp`, `sigmoid`, or both kernels from the same overlay.
- `Makefile`: stages the application and copies the app plus the generated bitstream/HWH into the root-level `deliverables/` folder.

## Usage

From the repository root:

```bash
make -C SW/pwl_multi_dut_pynq build
make -C SW/pwl_multi_dut_pynq deliver
make -C SW/pwl_multi_dut_pynq deliver EXP_DUT=exp_f16 SIGMOID_DUT=sigmoid_f16
```

This creates:

```text
deliverables/sw_pynq_pwl_multi_dut
```

The deliverables include:

- `pwl_multi_dut_pynq.py`
- `README.md`
- `design_1_wrapper.bit`
- `design_1_wrapper.hwh`

Example execution on the target board:

```bash
python3 pwl_multi_dut_pynq.py
python3 pwl_multi_dut_pynq.py --dut exp
python3 pwl_multi_dut_pynq.py --dut sigmoid
python3 pwl_multi_dut_pynq.py --exp-dut-id exp_f16 --sigmoid-dut-id sigmoid_f16
python3 pwl_multi_dut_pynq.py --dut exp --exp-dut-id exp_f16
python3 pwl_multi_dut_pynq.py --dut exp --iterations 100
python3 pwl_multi_dut_pynq.py --dut exp --random-input-count 256
python3 pwl_multi_dut_pynq.py --dut sigmoid --random-input-count 512 --random-seed 7
python3 pwl_multi_dut_pynq.py --dut sigmoid --iterations 200 --power-rail VCCINT
python3 pwl_multi_dut_pynq.py --dut sigmoid --iterations 200 --power-rail hwmon:ina260_u14:power1_input
python3 pwl_multi_dut_pynq.py --summary-file /home/xilinx/jupyter_notebooks/pwl_multi_dut_run.txt
python3 pwl_multi_dut_pynq.py --list-rails
python3 pwl_multi_dut_pynq.py --inputs=-8,-4,-1,0,1,4,8
python3 pwl_multi_dut_pynq.py --no-program
```

## Power Measurement

The app can estimate rail power for each requested DUT by:

- sampling the selected rail during an idle window before each iteration
- running the DUT once for that iteration while sampling the same rail
- repeating that measurement pair for `--iterations`
- reporting per-iteration idle/active/delta power and an average across all iterations for that DUT

To compare against the DFX flow, the summary also reports:

- `avg_active_window_ms`
- `avg_kernel_ms`
- `avg_validation_ms`
- `avg_host_overhead_ms`

If `--power-rail` is omitted, the app tries to auto-select a PL/core rail such as `VCCINT`. Use `--list-rails` on the PYNQ board to inspect the exact rail names exposed by that image.

On boards where `pynq.get_rails()` is empty, the app falls back to Linux `hwmon` power sources such as `hwmon:ina260_u14:power1_input`. The measurement window is synchronized in software with each DUT iteration: idle samples are collected immediately before a run, then active samples are collected while the kernel is executing. This is not cycle-accurate; it is limited by Linux scheduling and the telemetry sensor update rate.

Use `--random-input-count N` to generate a larger randomized input vector inside the selected DUT input range. Add `--random-seed` if you want the same randomized test set on repeated runs.

For float16 overlays, the app automatically packs two logical samples per 32-bit AXI word and pads the kernel `size` up to an even element count when needed. Validation still runs on the original unpadded logical inputs.

At the end of each run, the app writes the final summary lines to `pwl_multi_dut_pynq_summary.txt` next to the script by default. Use `--summary-file` to choose a different output path.
