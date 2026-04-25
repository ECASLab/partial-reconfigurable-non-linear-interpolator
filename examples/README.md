# Final Project

This project contains:

- RTL for a generic `dut_64x64` compute block with an AXI4-Stream wrapper
- Two DUT implementations for the individual flow:
  - `mul`
  - `xor`
- A multi-DUT block design flow that instantiates both `mul` and `xor`
- AXI VIP based simulation
- Baremetal software flows for Kria K26
- JTAG and SD-card boot flows for the K26 software examples

All generated artifacts are written under `build/`.

## Supported Configurations

- `EXAMPLE_MAKE=individual`
  - One DUT in the design
  - Supported `DUT` values: `mul`, `xor`
- `EXAMPLE_MAKE=multi`
  - Both multiplier and XOR accelerators in the design
  - `DUT` is not used by the hardware flow
- `EXAMPLE_MAKE=dfx`
  - K26-only DFX hardware flow with one reconfigurable partition
  - Default PR configuration uses `mul`
  - Alternate PR configuration registers `xor`
- Supported `PART` values:
  - `xck26-sfvc784-2LV-c` for Kria K26
  - `xcu250-figd2104-2L-e` for Alveo U250

Notes:

- The software, JTAG, and SD boot flows are intended for `xck26-sfvc784-2LV-c`.
- The U250 flow is a hardware-only flow in the current project.
- The DFX software flow supports both an external PR sequence and an in-app `xilfpga` partial-load path.

## Tool Requirements

The following tools should be in `PATH`:

- `vivado`
- `xvlog`
- `xelab`
- `xsct`
- `bootgen`

The project was developed around the Vivado/Vitis 2023.2 flow.

## Common Variables

Most commands are controlled with these variables:

- `EXAMPLE_MAKE=individual|multi|dfx`
- `DUT=mul|xor`
- `PART=xck26-sfvc784-2LV-c|xcu250-figd2104-2L-e`
- `VIVADO_JOBS=<n>`

Examples in this README assume you are running commands from `final-project/`.

## Most Important Commands

Sanity check:

```bash
make check EXAMPLE_MAKE=individual DUT=mul PART=xck26-sfvc784-2LV-c
```

Package the custom DUT IP only:

```bash
make dut-ip DUT=mul PART=xck26-sfvc784-2LV-c
make dut-ip DUT=xor PART=xck26-sfvc784-2LV-c
```

Run the hardware BD flow:

```bash
make batch EXAMPLE_MAKE=individual DUT=mul PART=xck26-sfvc784-2LV-c
make batch EXAMPLE_MAKE=individual DUT=xor PART=xck26-sfvc784-2LV-c
make batch EXAMPLE_MAKE=multi PART=xck26-sfvc784-2LV-c
make batch EXAMPLE_MAKE=dfx PART=xck26-sfvc784-2LV-c
```

Generate bitstream and XSA:

```bash
make bitstream-xsa EXAMPLE_MAKE=individual DUT=mul PART=xck26-sfvc784-2LV-c VIVADO_JOBS=4
make bitstream-xsa EXAMPLE_MAKE=multi PART=xck26-sfvc784-2LV-c VIVADO_JOBS=4
make bitstream-xsa EXAMPLE_MAKE=dfx PART=xck26-sfvc784-2LV-c VIVADO_JOBS=4
```

Run AXI VIP simulation:

```bash
make sim DUT=mul
make sim DUT=xor
make sim-backpressure DUT=mul
make sim-backpressure DUT=xor
```

Build baremetal software:

```bash
make sw-build EXAMPLE_MAKE=individual DUT=mul PART=xck26-sfvc784-2LV-c
make sw-build EXAMPLE_MAKE=multi PART=xck26-sfvc784-2LV-c
make sw-build EXAMPLE_MAKE=dfx PART=xck26-sfvc784-2LV-c
```

Run through JTAG:

```bash
make sw-run-jtag EXAMPLE_MAKE=individual DUT=mul PART=xck26-sfvc784-2LV-c
make sw-run-jtag EXAMPLE_MAKE=multi PART=xck26-sfvc784-2LV-c
make sw-run-jtag EXAMPLE_MAKE=dfx PART=xck26-sfvc784-2LV-c
```

Package SD boot image:

```bash
make sw-sd-boot EXAMPLE_MAKE=individual DUT=mul PART=xck26-sfvc784-2LV-c
make sw-sd-boot EXAMPLE_MAKE=multi PART=xck26-sfvc784-2LV-c
make sw-sd-boot EXAMPLE_MAKE=dfx PART=xck26-sfvc784-2LV-c
```

Cleanup:

```bash
make sim-clean-all
make sw-clean EXAMPLE_MAKE=multi PART=xck26-sfvc784-2LV-c
make clean
```

## Hardware Flow

### 1. Individual Flow

This flow builds a design with one accelerator:

- `DUT=mul`
- `DUT=xor`

Run:

```bash
make batch EXAMPLE_MAKE=individual DUT=mul PART=xck26-sfvc784-2LV-c
```

To generate a bitstream and XSA:

```bash
make bitstream-xsa EXAMPLE_MAKE=individual DUT=mul PART=xck26-sfvc784-2LV-c VIVADO_JOBS=4
```

Generated outputs:

- DUT IP repo:
  - `build/vivado/<dut>/<part_tag>/ip_repo/`
- Vivado project root:
  - `build/vivado/<dut>/<part_tag>/my_proj_<dut>_<part_tag>/`
- Bitstream:
  - `build/vivado/<dut>/<part_tag>/my_proj_<dut>_<part_tag>/my_proj_<dut>_<part_tag>.runs/impl_1/design_1_wrapper.bit`
- XSA:
  - `build/vivado/<dut>/<part_tag>/export/my_proj_<dut>_<part_tag>.xsa`

K26 example:

- `build/vivado/mul/xck26_sfvc784_2LV_c/export/my_proj_mul_xck26_sfvc784_2LV_c.xsa`

### 2. Multi-DUT Flow

This flow builds a design with both accelerators in the same BD.

Run:

```bash
make batch EXAMPLE_MAKE=multi PART=xck26-sfvc784-2LV-c
```

To generate a bitstream and XSA:

```bash
make bitstream-xsa EXAMPLE_MAKE=multi PART=xck26-sfvc784-2LV-c VIVADO_JOBS=4
```

Generated outputs:

- Vivado project root:
  - `build/vivado_multi_dut/<part_tag>/my_proj_multi_dut_<part_tag>/`
- Bitstream:
  - `build/vivado_multi_dut/<part_tag>/my_proj_multi_dut_<part_tag>/my_proj_multi_dut_<part_tag>.runs/impl_1/design_1_wrapper.bit`
- XSA:
  - `build/vivado_multi_dut/<part_tag>/export/my_proj_multi_dut_<part_tag>.xsa`

K26 example:

- `build/vivado_multi_dut/xck26_sfvc784_2LV_c/export/my_proj_multi_dut_xck26_sfvc784_2LV_c.xsa`

### 3. DFX Flow

This flow builds a K26 design with:

- One reconfigurable partition boundary outside the BD
- AXIS DFX decouplers on the RP input and output interfaces
- An AXI GPIO for decouple control plus combined decouple status readback
- A second AXI GPIO that drives the active-low RP reset output
- A default `mul` reconfigurable module and an alternate `xor` reconfigurable module

Run:

```bash
make batch EXAMPLE_MAKE=dfx PART=xck26-sfvc784-2LV-c
```

To generate a full bitstream and XSA for the default configuration:

```bash
make bitstream-xsa EXAMPLE_MAKE=dfx PART=xck26-sfvc784-2LV-c VIVADO_JOBS=4
```

Generated outputs:

- Vivado project root:
  - `build/vivado_dfx/<part_tag>/my_proj_dfx_<part_tag>/`
- Generated RP/top RTL:
  - `build/vivado_dfx/<part_tag>/generated_dfx_src/`
- Full bitstream for the active configuration:
  - `build/vivado_dfx/<part_tag>/my_proj_dfx_<part_tag>/my_proj_dfx_<part_tag>.runs/impl_1/`

K26 example:

- `build/vivado_dfx/xck26_sfvc784_2LV_c/my_proj_dfx_xck26_sfvc784_2LV_c/`

Known issue:

- In the K26 DFX flow, Vivado/Vitis 2023.2 may print `WARNING::74 - Unsupported FPGA device name 'xck26-sfvc784-2LV-c'` while generating `.mmi` files through `write_mem_info`.
- This warning comes from the Xilinx memdata / `updatemem` path, not from placement, routing, or `write_bitstream`.
- Full bitstreams, partial bitstreams, and XSAs may still be generated successfully even when this warning appears.
- Treat `.mmi` generation and `updatemem`-based memory update flows on K26 as a known limitation that may require extra validation or a tool-specific workaround.

## Verification Flow

The simulation flow uses AXI VIP and shared testbench logic.

Run smoke tests:

```bash
make sim DUT=mul
make sim DUT=xor
```

Run backpressure tests:

```bash
make sim-backpressure DUT=mul
make sim-backpressure DUT=xor
```

Generated outputs:

- Simulation work area:
  - `build/sim/<dut>/work/`
- Logs:
  - `build/sim/<dut>/logs/`

Useful log files:

- `build/sim/<dut>/logs/xvlog.log`
- `build/sim/<dut>/logs/xelab_smoke.log`
- `build/sim/<dut>/logs/axsim_smoke.log`
- `build/sim/<dut>/logs/xelab_backpressure.log`
- `build/sim/<dut>/logs/axsim_backpressure.log`

## Software Flow

The software flow is intended for the Kria K26 because it depends on the Zynq MPSoC PS.

### 1. Individual Baremetal App

Run:

```bash
make sw-build EXAMPLE_MAKE=individual DUT=mul PART=xck26-sfvc784-2LV-c
```

Generated outputs:

- Workspace:
  - `build/sw/<dut>/<part_tag>/workspace/`
- App ELF:
  - `build/sw/<dut>/<part_tag>/workspace/dut64_dma_smoke/Debug/dut64_dma_smoke.elf`
- Generated PS init Tcl:
  - `build/sw/<dut>/<part_tag>/workspace/dut64_platform/hw/psu_init.tcl`

### 2. Multi-DUT Baremetal App

Run:

```bash
make sw-build EXAMPLE_MAKE=multi PART=xck26-sfvc784-2LV-c
```

Generated outputs:

- Workspace:
  - `build/sw/multi_dut/<part_tag>/workspace/`
- App ELF:
  - `build/sw/multi_dut/<part_tag>/workspace/dut64_multi_dma_cli/Debug/dut64_multi_dma_cli.elf`
- Generated PS init Tcl:
  - `build/sw/multi_dut/<part_tag>/workspace/dut64_multi_platform/hw/psu_init.tcl`

K26 multi-DUT example:

- `build/sw/multi_dut/xck26_sfvc784_2LV_c/workspace/dut64_multi_dma_cli/Debug/dut64_multi_dma_cli.elf`

### 3. DFX Baremetal App

Run:

```bash
make sw-build EXAMPLE_MAKE=dfx PART=xck26-sfvc784-2LV-c
```

Generated outputs:

- Workspace:
  - `build/sw/dfx/<part_tag>/workspace/`
- App ELF:
  - `build/sw/dfx/<part_tag>/workspace/dut64_dfx_dma_cli/Debug/dut64_dfx_dma_cli.elf`
- Generated PS init Tcl:
  - `build/sw/dfx/<part_tag>/workspace/dut64_dfx_platform/hw/psu_init.tcl`

The DFX app assumes the full bitstream boots with the default `mul` RM loaded. It:

- releases the active-low RP reset on startup
- controls the decouple GPIO and reads back the combined decouple status
- provides CLI helpers to prepare the RP for external partial reconfiguration and resume operation after loading `mul` or `xor`
- can also call `xilfpga` directly to load a partial bitstream image that is already staged in memory

For the in-app `xilfpga` paths:

- `l` / `k` load a partial image that is already staged in memory and prompt for address plus byte size.
- `u` / `i` load a partial `.bit` file from the FAT SD-card partition. Use a path such as `0:/u_rp_rp_mul_partial.bit`, or enter just the filename to default to `0:/`.

Both paths run decouple -> reset -> `XFpga_BitStream_Load(..., XFPGA_PARTIAL_EN)` -> release reset -> clear decouple.

This app still supports the original external-PR flow too.

The K26 software examples use UART output. Open a serial terminal at:

- `115200 8N1`

## End Programming and Boot

### JTAG Boot

This flow is convenient for interactive development.

What it does:

- programs the PL with the generated bitstream
- initializes PS/DDR using `psu_init.tcl`
- downloads the application ELF to `A53-0`
- starts execution

Requirements:

- board connected over JTAG
- `hw_server` reachable
- K26 build artifacts already generated
- optional serial terminal at `115200 8N1`

Run:

```bash
make sw-run-jtag EXAMPLE_MAKE=individual DUT=mul PART=xck26-sfvc784-2LV-c
make sw-run-jtag EXAMPLE_MAKE=multi PART=xck26-sfvc784-2LV-c
make sw-run-jtag EXAMPLE_MAKE=dfx PART=xck26-sfvc784-2LV-c
```

Important generated files used by the JTAG flow:

- Individual bitstream:
  - `build/vivado/<dut>/<part_tag>/my_proj_<dut>_<part_tag>/my_proj_<dut>_<part_tag>.runs/impl_1/design_1_wrapper.bit`
- Individual `psu_init.tcl`:
  - `build/sw/<dut>/<part_tag>/workspace/dut64_platform/hw/psu_init.tcl`
- Individual ELF:
  - `build/sw/<dut>/<part_tag>/workspace/dut64_dma_smoke/Debug/dut64_dma_smoke.elf`

- Multi-DUT bitstream:
  - `build/vivado_multi_dut/<part_tag>/my_proj_multi_dut_<part_tag>/my_proj_multi_dut_<part_tag>.runs/impl_1/design_1_wrapper.bit`
- Multi-DUT `psu_init.tcl`:
  - `build/sw/multi_dut/<part_tag>/workspace/dut64_multi_platform/hw/psu_init.tcl`
- Multi-DUT ELF:
  - `build/sw/multi_dut/<part_tag>/workspace/dut64_multi_dma_cli/Debug/dut64_multi_dma_cli.elf`

- DFX bitstream:
  - `build/vivado_dfx/<part_tag>/my_proj_dfx_<part_tag>/my_proj_dfx_<part_tag>.runs/impl_1/dut_64x64_axis_dfx_top.bit`
- DFX `psu_init.tcl`:
  - `build/sw/dfx/<part_tag>/workspace/dut64_dfx_platform/hw/psu_init.tcl`
- DFX ELF:
  - `build/sw/dfx/<part_tag>/workspace/dut64_dfx_dma_cli/Debug/dut64_dfx_dma_cli.elf`

### SD Card Boot

This flow packages a standalone boot image for the K26.

What it does:

- rebuilds the standalone software workspace if needed
- creates FSBL and PMUFW
- packages:
  - FSBL
  - PMUFW
  - PL bitstream
  - baremetal ELF
- writes them into a single `BOOT.BIN`

Run:

```bash
make sw-sd-boot EXAMPLE_MAKE=individual DUT=mul PART=xck26-sfvc784-2LV-c
make sw-sd-boot EXAMPLE_MAKE=multi PART=xck26-sfvc784-2LV-c
make sw-sd-boot EXAMPLE_MAKE=dfx PART=xck26-sfvc784-2LV-c
```

Generated outputs:

- Individual SD card directory:
  - `build/sw/<dut>/<part_tag>/sd_card/`
- Individual boot image:
  - `build/sw/<dut>/<part_tag>/sd_card/BOOT.BIN`

- Multi-DUT SD card directory:
  - `build/sw/multi_dut/<part_tag>/sd_card/`
- Multi-DUT boot image:
  - `build/sw/multi_dut/<part_tag>/sd_card/BOOT.BIN`

- DFX SD card directory:
  - `build/sw/dfx/<part_tag>/sd_card/`
- DFX boot image:
  - `build/sw/dfx/<part_tag>/sd_card/BOOT.BIN`

The `sd_card/` directory also keeps:

- `boot.bif`
- `fsbl.elf`
- `pmufw.elf`
- the app ELF
- the copied bitstream

For the DFX software flow, the `sd_card/` directory also copies any generated `*_partial.bit` files that sit next to the full bitstream. Copy those partial files to the FAT partition as regular files if you want the running app to load them with the `u` / `i` menu commands.

K26 multi-DUT example:

- `build/sw/multi_dut/xck26_sfvc784_2LV_c/sd_card/BOOT.BIN`

How to use `BOOT.BIN`:

1. Set the board or carrier to SD boot mode.
2. Format the boot partition as FAT or FAT32.
3. Copy `BOOT.BIN` to the root of that boot partition.
4. Power cycle or reset the board.

Notes:

- `psu_init.tcl` is a JTAG flow artifact and is not used during SD boot.
- During SD boot, the PS boot ROM loads `BOOT.BIN`, then FSBL loads PMUFW, configures the PL, and starts the baremetal app.
- Boot mode switch or jumper details depend on the carrier board. Use the carrier board documentation for the exact SD-boot switch setting.

## Useful Generated Paths

Common logs:

- `build/logs/`

Simulation:

- `build/sim/<dut>/logs/`

Individual hardware:

- `build/vivado/<dut>/<part_tag>/`

Multi-DUT hardware:

- `build/vivado_multi_dut/<part_tag>/`

Individual software:

- `build/sw/<dut>/<part_tag>/`

Multi-DUT software:

- `build/sw/multi_dut/<part_tag>/`

## Quick Start Examples

Multiplier on K26, full flow:

```bash
make bitstream-xsa EXAMPLE_MAKE=individual DUT=mul PART=xck26-sfvc784-2LV-c VIVADO_JOBS=4
make sw-build EXAMPLE_MAKE=individual DUT=mul PART=xck26-sfvc784-2LV-c
make sw-run-jtag EXAMPLE_MAKE=individual DUT=mul PART=xck26-sfvc784-2LV-c
```

Multi-DUT on K26, SD boot:

```bash
make bitstream-xsa EXAMPLE_MAKE=multi PART=xck26-sfvc784-2LV-c VIVADO_JOBS=4
make sw-build EXAMPLE_MAKE=multi PART=xck26-sfvc784-2LV-c
make sw-sd-boot EXAMPLE_MAKE=multi PART=xck26-sfvc784-2LV-c
```
