# Final Project

This repository implements piecewise-linear (PWL) interpolators for FPGA deployment on the Kria K26. The project is organized around three stages:

1. Generate the interpolator IP in `HW/` with Vitis HLS.
2. Build a Vivado bitstream for one of the hardware integration flows under `scripts/`.
3. Package runnable software + bitstreams under `deliverables/` for board deployment.

All generated artifacts are written under `build/` inside `final-project/`.

## Repository Layout

- `HW/`: HLS implementation of the PWL interpolators, coefficient headers, testbench, and HLS export flow.
- `scripts/individual/`: Vivado flow for a single interpolator in the design.
- `scripts/multi_dut/`: Vivado flow for a static design containing both interpolators at once.
- `scripts/pwl_dfx/`: Vivado DFX flow with one reconfigurable partition and multiple reconfigurable modules.
- `SW/pwl_individual/`: PYNQ host app packaging for the individual flow.
- `SW/pwl_multi_dut_pynq/`: PYNQ host app packaging for the multi-DUT flow.
- `SW/pwl_dfx_pynq/`: PYNQ host app packaging for the DFX flow.
- `deliverables/`: board-ready artifacts copied from the build outputs.

## Supported Interpolators

The shared interpolator catalog supports the following DUT identifiers:

- `exp`: nonuniform exponential, Float32
- `sigmoid`: nonuniform sigmoid, Float32
- `exp_f16`: nonuniform exponential, Float16
- `sigmoid_f16`: nonuniform sigmoid, Float16

These identifiers are used consistently across the HLS exports, Vivado flows, and software packaging targets.

## Tool Requirements

The current flows assume the following tools are available in `PATH`:

- `vitis_hls`
- `vivado`
- `python3`

The checked-in scripts target the Kria K26 part:

- `xck26-sfvc784-2LV-c`

## 1. Generate The Interpolators In `HW/`

The `HW/` directory produces the HLS IP cores consumed by the downstream Vivado flows. The Makefile can generate coefficients, compile the C++ testbench, and export the selected HLS design.

Run make targets from the repository root (use `-C <dir>` with `make` as shown).

### Common HLS Targets

```bash
make -C HW gen_coeffs PWL_MODE=nonuniform PWL_FUNCTION=exponential PWL_PRECISION=float32
make -C HW run        PWL_MODE=nonuniform PWL_FUNCTION=exponential PWL_PRECISION=float32
make -C HW vitis      PWL_MODE=nonuniform PWL_FUNCTION=exponential PWL_PRECISION=float32
```

To generate the four interpolators used by the hardware flows (from repository root):

```bash
make -C HW vitis PWL_MODE=nonuniform PWL_FUNCTION=exponential PWL_PRECISION=float32
make -C HW vitis PWL_MODE=nonuniform PWL_FUNCTION=sigmoid     PWL_PRECISION=float32
make -C HW vitis PWL_MODE=nonuniform PWL_FUNCTION=exponential PWL_PRECISION=float16
make -C HW vitis PWL_MODE=nonuniform PWL_FUNCTION=sigmoid     PWL_PRECISION=float16
```

The resulting exported IP appears under:

- `HW/build/vitis_hls/pwl_pwl_nonuniform_pwl_function_exponential_use_float32/`
- `HW/build/vitis_hls/pwl_pwl_nonuniform_pwl_function_sigmoid_use_float32/`
- `HW/build/vitis_hls/pwl_pwl_nonuniform_pwl_function_exponential_use_float16/`
- `HW/build/vitis_hls/pwl_pwl_nonuniform_pwl_function_sigmoid_use_float16/`

Each downstream Vivado Makefile checks for the corresponding `solution/impl/ip/component.xml` before launching synthesis and implementation.

## 2. Generate Bitstreams

After the required HLS exports exist, choose one of the hardware integration flows below.

### A. Individual Flow

Build a design containing a single interpolator:

```bash
make -C scripts/individual bitstream-xsa DUT=exp PART=xck26-sfvc784-2LV-c VIVADO_JOBS=4
make -C scripts/individual bitstream-xsa DUT=sigmoid PART=xck26-sfvc784-2LV-c VIVADO_JOBS=4
```

Outputs are written under:

- `build/vivado/<dut>/xck26_sfvc784_2LV_c/`

The generated full bitstream is located at:

- `build/vivado/<dut>/xck26_sfvc784_2LV_c/my_proj_<dut>_xck26_sfvc784_2LV_c/my_proj_<dut>_xck26_sfvc784_2LV_c.runs/impl_1/design_1_wrapper.bit`

### B. Multi-DUT Flow

Build a static design that instantiates both interpolators at once:

```bash
make -C scripts/multi_dut bitstream-xsa PART=xck26-sfvc784-2LV-c EXP_DUT=exp SIGMOID_DUT=sigmoid VIVADO_JOBS=4
```

For the Float16 configuration:

```bash
make -C scripts/multi_dut bitstream-xsa PART=xck26-sfvc784-2LV-c EXP_DUT=exp_f16 SIGMOID_DUT=sigmoid_f16 VIVADO_JOBS=4
```

Outputs are written under:

- `build/vivado_multi_dut/xck26_sfvc784_2LV_c/`

### C. DFX Flow

Build the reconfigurable design with one RP and one or more RMs:

```bash
make -C scripts/pwl_dfx bitstream-xsa PART=xck26-sfvc784-2LV-c RM_DUTS=all VIVADO_JOBS=4
```

To build only a subset of reconfigurable modules:

```bash
make -C scripts/pwl_dfx bitstream-xsa PART=xck26-sfvc784-2LV-c RM_DUTS=exp,sigmoid
make -C scripts/pwl_dfx bitstream-xsa PART=xck26-sfvc784-2LV-c RM_DUTS=exp_f16,sigmoid_f16
```

Outputs are written under:

- `build/vivado_pwl_dfx/xck26_sfvc784_2LV_c/`

This flow produces both:

- full bitstreams for each RM configuration
- partial bitstreams for each selected RM

Optional area reports can be generated with:

```bash
make -C scripts/multi_dut area-report PART=xck26-sfvc784-2LV-c
make -C scripts/pwl_dfx area-report  PART=xck26-sfvc784-2LV-c
```

## 3. Package Deliverables

Once the bitstreams exist, the software packaging flows under `SW/` copy the host application and the required bitstream metadata into `deliverables/`.

### Individual PYNQ Deliverables

```bash
make -C SW/pwl_individual deliver PART=xck26-sfvc784-2LV-c
```

This produces:

- `deliverables/sw_pynq_pwl_individual/`

with:

- `pwl_pynq.py`
- per-DUT `design_1_wrapper.bit`
- per-DUT `design_1_wrapper.hwh`

### Multi-DUT PYNQ Deliverables

```bash
make -C SW/pwl_multi_dut_pynq deliver PART=xck26-sfvc784-2LV-c EXP_DUT=exp SIGMOID_DUT=sigmoid
```

This produces:

- `deliverables/sw_pynq_pwl_multi_dut/`

with:

- `pwl_multi_dut_pynq.py`
- `design_1_wrapper.bit`
- `design_1_wrapper.hwh`
- `README.md`

### DFX PYNQ Deliverables

```bash
make -C SW/pwl_dfx_pynq deliver PART=xck26-sfvc784-2LV-c RMS=exp,sigmoid,exp_f16,sigmoid_f16
```

This produces:

- `deliverables/sw_pynq_pwl_dfx/`

with:

- `pwl_dfx_pynq.py`
- one full `.bit` + `.hwh` for each selected RM
- one partial `.bit` for each selected RM
- `README.md`

## Recommended End-To-End Sequence

From the repository root, a typical full build for the PYNQ flows is:

```bash
make -C HW vitis PWL_MODE=nonuniform PWL_FUNCTION=exponential PWL_PRECISION=float32
make -C HW vitis PWL_MODE=nonuniform PWL_FUNCTION=sigmoid     PWL_PRECISION=float32
make -C HW vitis PWL_MODE=nonuniform PWL_FUNCTION=exponential PWL_PRECISION=float16
make -C HW vitis PWL_MODE=nonuniform PWL_FUNCTION=sigmoid     PWL_PRECISION=float16

make -C scripts/multi_dut bitstream-xsa PART=xck26-sfvc784-2LV-c EXP_DUT=exp SIGMOID_DUT=sigmoid VIVADO_JOBS=4
make -C SW/pwl_multi_dut_pynq deliver PART=xck26-sfvc784-2LV-c EXP_DUT=exp SIGMOID_DUT=sigmoid
```

For the reconfigurable flow:

```bash
make -C scripts/pwl_dfx bitstream-xsa PART=xck26-sfvc784-2LV-c RM_DUTS=all VIVADO_JOBS=4
make -C SW/pwl_dfx_pynq deliver PART=xck26-sfvc784-2LV-c RMS=exp,sigmoid,exp_f16,sigmoid_f16
```

## Cleaning

To remove generated HLS outputs:

```bash
make -C HW clean
```

To remove staged software packaging outputs:

```bash
make -C SW/pwl_individual clean
make -C SW/pwl_multi_dut_pynq clean
make -C SW/pwl_dfx_pynq clean
```

The Vivado hardware build directories under `build/` can be removed manually if a full rebuild is desired.
