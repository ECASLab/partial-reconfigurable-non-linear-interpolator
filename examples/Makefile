SHELL := /bin/bash

# Vivado executable (override if needed: make VIVADO=/path/to/vivado ...)
VIVADO ?= vivado
VIVADO_JOBS ?= 4
BOOTGEN ?= bootgen
PYTHON ?= python3

# Project paths
PROJECT_DIR := .
IP_SCRIPT   := $(PROJECT_DIR)/scripts/example_dut_ip_flow.tcl
IMPL_SCRIPT := $(PROJECT_DIR)/scripts/example_impl_export_flow.tcl
BUILD_DIR   := $(PROJECT_DIR)/build
LOG_DIR     := $(BUILD_DIR)/logs
HW_EXAMPLE_DIR := $(PROJECT_DIR)/scripts/example_individual
HW_EXAMPLE_BD_SCRIPT := $(HW_EXAMPLE_DIR)/example_bd_flow.tcl
HW_EXAMPLE_MAKE_DIR := $(HW_EXAMPLE_DIR)
HW_MULTI_EXAMPLE_DIR := $(PROJECT_DIR)/scripts/example_multi_dut
HW_MULTI_EXAMPLE_BD_SCRIPT := $(HW_MULTI_EXAMPLE_DIR)/example_bd_flow.tcl
HW_MULTI_EXAMPLE_MAKE_DIR := $(HW_MULTI_EXAMPLE_DIR)
HW_DFX_EXAMPLE_DIR := $(PROJECT_DIR)/scripts/example_dfx
HW_DFX_EXAMPLE_BD_SCRIPT := $(HW_DFX_EXAMPLE_DIR)/example_bd_flow.tcl
HW_DFX_EXAMPLE_MAKE_DIR := $(HW_DFX_EXAMPLE_DIR)
VERIF_MAKE_DIR := $(PROJECT_DIR)/verif
SW_INDIVIDUAL_EXAMPLE_MAKE_DIR := $(PROJECT_DIR)/sw/example_individual
SW_MULTI_EXAMPLE_MAKE_DIR := $(PROJECT_DIR)/sw/example_multi_dut
SW_DFX_EXAMPLE_MAKE_DIR := $(PROJECT_DIR)/sw/example_dfx
SW_CYNQ_EXAMPLE_MAKE_DIR := $(PROJECT_DIR)/sw/example_individual_cynq
SW_PYNQ_EXAMPLE_MAKE_DIR := $(PROJECT_DIR)/sw/example_individual_pynq
SW_PYNQ_MULTI_EXAMPLE_MAKE_DIR := $(PROJECT_DIR)/sw/example_multi_dut_pynq
SW_PYNQ_DFX_EXAMPLE_MAKE_DIR := $(PROJECT_DIR)/sw/example_dfx_pynq
DUT ?= mul
EXAMPLE_MAKE ?= individual
PART_K26 := xck26-sfvc784-2LV-c
PART_U250 := xcu250-figd2104-2L-e
SUPPORTED_PARTS := $(PART_K26) $(PART_U250)
PART ?= $(PART_K26)
PART_TAG := $(subst .,_,$(subst -,_,$(PART)))
VIVADO_DUT_BUILD_DIR := $(BUILD_DIR)/vivado/$(DUT)/$(PART_TAG)

ifeq ($(EXAMPLE_MAKE),individual)
HW_SELECTED_DIR := $(HW_EXAMPLE_DIR)
HW_SELECTED_BD_SCRIPT := $(HW_EXAMPLE_BD_SCRIPT)
HW_SELECTED_MAKE_DIR := $(HW_EXAMPLE_MAKE_DIR)
SW_SELECTED_MAKE_DIR := $(SW_INDIVIDUAL_EXAMPLE_MAKE_DIR)
EXAMPLE_SUPPORTED_PARTS := $(SUPPORTED_PARTS)
else ifeq ($(EXAMPLE_MAKE),multi)
HW_SELECTED_DIR := $(HW_MULTI_EXAMPLE_DIR)
HW_SELECTED_BD_SCRIPT := $(HW_MULTI_EXAMPLE_BD_SCRIPT)
HW_SELECTED_MAKE_DIR := $(HW_MULTI_EXAMPLE_MAKE_DIR)
SW_SELECTED_MAKE_DIR := $(SW_MULTI_EXAMPLE_MAKE_DIR)
EXAMPLE_SUPPORTED_PARTS := $(SUPPORTED_PARTS)
else ifeq ($(EXAMPLE_MAKE),dfx)
HW_SELECTED_DIR := $(HW_DFX_EXAMPLE_DIR)
HW_SELECTED_BD_SCRIPT := $(HW_DFX_EXAMPLE_BD_SCRIPT)
HW_SELECTED_MAKE_DIR := $(HW_DFX_EXAMPLE_MAKE_DIR)
SW_SELECTED_MAKE_DIR := $(SW_DFX_EXAMPLE_MAKE_DIR)
EXAMPLE_SUPPORTED_PARTS := $(PART_K26)
else
$(error Unsupported EXAMPLE_MAKE '$(EXAMPLE_MAKE)'. Supported values: individual multi dfx)
endif

ifneq ($(filter $(PART),$(EXAMPLE_SUPPORTED_PARTS)),$(PART))
$(error Unsupported PART '$(PART)' for EXAMPLE_MAKE '$(EXAMPLE_MAKE)'. Supported PARTs: $(EXAMPLE_SUPPORTED_PARTS))
endif

.PHONY: help check dut-ip batch gui gui-auto tcl tcl-auto \
	bitstream-xsa \
	sim-check sim-prepare sim-compile sim-run sim sim-backpressure sim-clean sim-clean-all \
	sw-check sw-platform sw-app sw-build sw-run-jtag sw-sd-boot sw-clean \
	sw-cynq-check sw-cynq-build sw-cynq-deliver-check sw-cynq-deliver sw-cynq-clean \
	sw-pynq-check sw-pynq-build sw-pynq-deliver-check sw-pynq-deliver sw-pynq-clean \
	sw-pynq-multi-check sw-pynq-multi-build sw-pynq-multi-deliver-check sw-pynq-multi-deliver sw-pynq-multi-clean \
	sw-pynq-dfx-check sw-pynq-dfx-build sw-pynq-dfx-deliver-check sw-pynq-dfx-deliver sw-pynq-dfx-clean \
	clean

help:
	@echo "Available targets:"
	@echo "  make check   - Verify Vivado, Tcl scripts, and selected PART are available"
	@echo "  make dut-ip DUT=mul PART=$(PART_K26) - Package the AXI-wrapped multiplier implementation as custom IP"
	@echo "  make dut-ip DUT=xor PART=$(PART_K26) - Package the AXI-wrapped XOR implementation as custom IP"
	@echo "  make batch EXAMPLE_MAKE=individual DUT=mul PART=$(PART_K26) - Run the individual BD flow for Kria K26"
	@echo "  make batch EXAMPLE_MAKE=multi PART=$(PART_K26) - Run the multi-DUT BD flow for Kria K26"
	@echo "  make batch EXAMPLE_MAKE=dfx PART=$(PART_K26) - Run the DFX BD flow for Kria K26"
	@echo "  make batch EXAMPLE_MAKE=individual DUT=mul PART=$(PART_U250) - Run the individual BD flow for Alveo U250"
	@echo "  make batch EXAMPLE_MAKE=multi PART=$(PART_U250) - Run the multi-DUT BD flow for Alveo U250"
	@echo "  make bitstream-xsa EXAMPLE_MAKE=individual DUT=mul PART=$(PART_K26) VIVADO_JOBS=$(VIVADO_JOBS) - Run synth/impl/write_bitstream and export XSA"
	@echo "  make bitstream-xsa EXAMPLE_MAKE=multi PART=$(PART_K26) VIVADO_JOBS=$(VIVADO_JOBS) - Run synth/impl/write_bitstream and export multi-DUT XSA"
	@echo "  make bitstream-xsa EXAMPLE_MAKE=dfx PART=$(PART_K26) VIVADO_JOBS=$(VIVADO_JOBS) - Run synth/impl/write_bitstream for the default DFX configuration and export XSA"
	@echo "  make gui EXAMPLE_MAKE=individual DUT=mul PART=$(PART_K26) - Run Vivado in GUI mode for the individual flow"
	@echo "  make gui EXAMPLE_MAKE=multi PART=$(PART_K26) - Run Vivado in GUI mode for the multi-DUT flow"
	@echo "  make gui EXAMPLE_MAKE=dfx PART=$(PART_K26) - Run Vivado in GUI mode for the DFX flow"
	@echo "  make gui-auto - Run Vivado GUI with the selected EXAMPLE_MAKE flow"
	@echo "  make tcl     - Start Vivado in Tcl-shell mode"
	@echo "  make tcl-auto EXAMPLE_MAKE=individual DUT=mul PART=$(PART_K26) - Start Vivado Tcl mode for the individual flow"
	@echo "  make tcl-auto EXAMPLE_MAKE=multi PART=$(PART_K26) - Start Vivado Tcl mode for the multi-DUT flow"
	@echo "  make tcl-auto EXAMPLE_MAKE=dfx PART=$(PART_K26) - Start Vivado Tcl mode for the DFX flow"
	@echo "  make sim DUT=mul     - Delegate to $(VERIF_MAKE_DIR)/Makefile and run the smoke test"
	@echo "  make sim DUT=xor     - Delegate to $(VERIF_MAKE_DIR)/Makefile and run the smoke test"
	@echo "  make sim-backpressure DUT=mul - Delegate to $(VERIF_MAKE_DIR)/Makefile and run the backpressure test"
	@echo "  make sim-backpressure DUT=xor - Delegate to $(VERIF_MAKE_DIR)/Makefile and run the backpressure test"
	@echo "  make sim-clean DUT=mul - Delegate to $(VERIF_MAKE_DIR)/Makefile and remove sim artifacts"
	@echo "  make sim-clean-all   - Delegate to $(VERIF_MAKE_DIR)/Makefile and remove all sim artifacts"
	@echo "  make sw-build EXAMPLE_MAKE=individual DUT=mul PART=$(PART_K26) - Build the example_individual baremetal A53 app"
	@echo "  make sw-build EXAMPLE_MAKE=multi PART=$(PART_K26) - Build the example_multi_dut baremetal A53 app"
	@echo "  make sw-build EXAMPLE_MAKE=dfx PART=$(PART_K26) - Build the DFX-aware baremetal A53 app"
	@echo "  make sw-run-jtag EXAMPLE_MAKE=individual DUT=mul PART=$(PART_K26) - Program PL and run the example_individual app"
	@echo "  make sw-run-jtag EXAMPLE_MAKE=multi PART=$(PART_K26) - Program PL and run the example_multi_dut app"
	@echo "  make sw-run-jtag EXAMPLE_MAKE=dfx PART=$(PART_K26) - Program PL and run the DFX-aware app"
	@echo "  make sw-sd-boot EXAMPLE_MAKE=individual DUT=mul PART=$(PART_K26) - Build BOOT.BIN for SD-card boot"
	@echo "  make sw-sd-boot EXAMPLE_MAKE=multi PART=$(PART_K26) - Build BOOT.BIN for SD-card boot"
	@echo "  make sw-sd-boot EXAMPLE_MAKE=dfx PART=$(PART_K26) - Build BOOT.BIN for SD-card boot"
	@echo "  make sw-cynq-build - Build the Linux/CYNQ individual app using the installed CYNQ package"
	@echo "  make sw-cynq-deliver PART=$(PART_K26) - Copy the CYNQ source, binary, and all available DUT bitstreams to deliverables"
	@echo "  make sw-cynq-clean - Remove the Linux/CYNQ app binary"
	@echo "  make sw-pynq-build - Syntax-check and stage the Python/PYNQ individual app"
	@echo "  make sw-pynq-deliver PART=$(PART_K26) - Copy the PYNQ app and all available DUT bitstream/HWH metadata to deliverables"
	@echo "  make sw-pynq-clean - Remove staged Python/PYNQ app artifacts"
	@echo "  make sw-pynq-multi-build PART=$(PART_K26) - Syntax-check and stage the Python/PYNQ multi-DUT app"
	@echo "  make sw-pynq-multi-deliver PART=$(PART_K26) - Copy the multi-DUT PYNQ app plus bitstream/HWH metadata to deliverables"
	@echo "  make sw-pynq-multi-clean - Remove staged Python/PYNQ multi-DUT artifacts"
	@echo "  make sw-pynq-dfx-build PART=$(PART_K26) - Syntax-check and stage the Python/PYNQ DFX app"
	@echo "  make sw-pynq-dfx-deliver PART=$(PART_K26) - Copy the PYNQ DFX app plus renamed full and partial bitstreams to deliverables"
	@echo "  make sw-pynq-dfx-clean - Remove staged Python/PYNQ DFX artifacts"
	@echo "  make sw-clean EXAMPLE_MAKE=individual DUT=mul PART=$(PART_K26) - Remove generated individual software artifacts"
	@echo "  make sw-clean EXAMPLE_MAKE=multi PART=$(PART_K26) - Remove generated multi-DUT software artifacts"
	@echo "  make sw-clean EXAMPLE_MAKE=dfx PART=$(PART_K26) - Remove generated DFX software artifacts"
	@echo "  make batch DUT=mul   - Run Vivado in batch mode with the multiplier implementation"
	@echo "  make batch DUT=xor   - Run Vivado in batch mode with the XOR implementation"
	@echo "  EXAMPLE_MAKE values: individual multi dfx"
	@echo "  Supported PARTs: $(PART_K26) (Kria K26), $(PART_U250) (Alveo U250)"
	@echo "  make clean   - Remove Vivado logs/jou and build outputs"

check:
	@command -v "$(VIVADO)" >/dev/null 2>&1 || { echo "ERROR: Vivado not found in PATH"; exit 1; }
	@test -f "$(HW_SELECTED_BD_SCRIPT)" || { echo "ERROR: Tcl script not found: $(HW_SELECTED_BD_SCRIPT)"; exit 1; }
	@test -f "$(IP_SCRIPT)" || { echo "ERROR: Tcl script not found: $(IP_SCRIPT)"; exit 1; }
	@test -f "$(IMPL_SCRIPT)" || { echo "ERROR: Tcl script not found: $(IMPL_SCRIPT)"; exit 1; }
	@test -f "$(HW_SELECTED_MAKE_DIR)/Makefile" || { echo "ERROR: Makefile not found: $(HW_SELECTED_MAKE_DIR)/Makefile"; exit 1; }
	@if [ -n "$(SW_SELECTED_MAKE_DIR)" ]; then \
		test -f "$(SW_SELECTED_MAKE_DIR)/Makefile" || { echo "ERROR: Makefile not found: $(SW_SELECTED_MAKE_DIR)/Makefile"; exit 1; }; \
	fi
	@mkdir -p "$(LOG_DIR)"
	@echo "Vivado: $$(command -v "$(VIVADO)")"
	@echo "Selected example flow: $(EXAMPLE_MAKE)"
	@echo "Selected BD Script: $(HW_SELECTED_BD_SCRIPT)"
	@echo "DUT IP Script: $(IP_SCRIPT)"
	@echo "Impl Script: $(IMPL_SCRIPT)"
	@echo "Part: $(PART)"

batch gui gui-auto tcl-auto bitstream-xsa:
	$(MAKE) -C "$(HW_SELECTED_MAKE_DIR)" $@ DUT="$(DUT)" PART="$(PART)" VIVADO="$(VIVADO)" VIVADO_JOBS="$(VIVADO_JOBS)"

dut-ip: check
	@mkdir -p "$(LOG_DIR)"
	"$(VIVADO)" -mode batch -source "$(IP_SCRIPT)" -tclargs "$(DUT)" "$(PART)" "$(VIVADO_DUT_BUILD_DIR)" \
		-log "$(LOG_DIR)/vivado_dut_ip.log" \
		-journal "$(LOG_DIR)/vivado_dut_ip.jou"

tcl: check
	"$(VIVADO)" -mode tcl

sim-check sim-prepare sim-compile sim-run sim sim-backpressure sim-clean sim-clean-all:
	$(MAKE) -C "$(VERIF_MAKE_DIR)" $@

sw-check sw-platform sw-app sw-build sw-run-jtag sw-sd-boot sw-clean:
	@test -n "$(SW_SELECTED_MAKE_DIR)" || { echo "ERROR: Software flow is not available for EXAMPLE_MAKE=$(EXAMPLE_MAKE)"; exit 1; }
	$(MAKE) -C "$(SW_SELECTED_MAKE_DIR)" $@ DUT="$(DUT)" PART="$(PART)" BOOTGEN="$(BOOTGEN)"

sw-cynq-check sw-cynq-build sw-cynq-deliver-check sw-cynq-deliver sw-cynq-clean:
	$(MAKE) -C "$(SW_CYNQ_EXAMPLE_MAKE_DIR)" $@ CXX="$(CXX)" DUT="$(DUT)" PART="$(PART)"

sw-pynq-check sw-pynq-build sw-pynq-deliver-check sw-pynq-deliver sw-pynq-clean:
	$(MAKE) -C "$(SW_PYNQ_EXAMPLE_MAKE_DIR)" $@ PYTHON="$(PYTHON)" DUT="$(DUT)" PART="$(PART)"

sw-pynq-multi-check sw-pynq-multi-build sw-pynq-multi-deliver-check sw-pynq-multi-deliver sw-pynq-multi-clean:
	$(MAKE) -C "$(SW_PYNQ_MULTI_EXAMPLE_MAKE_DIR)" $@ PYTHON="$(PYTHON)" PART="$(PART)"

sw-pynq-dfx-check sw-pynq-dfx-build sw-pynq-dfx-deliver-check sw-pynq-dfx-deliver sw-pynq-dfx-clean:
	$(MAKE) -C "$(SW_PYNQ_DFX_EXAMPLE_MAKE_DIR)" $@ PYTHON="$(PYTHON)" PART="$(PART)"

clean: sim-clean-all
	rm -rf "$(BUILD_DIR)"
	rm -rf "$(PROJECT_DIR)"/vivado*.log "$(PROJECT_DIR)"/vivado*.jou "$(PROJECT_DIR)"/.Xil
