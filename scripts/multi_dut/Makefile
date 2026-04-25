SHELL := /bin/bash

VIVADO ?= vivado
VIVADO_JOBS ?= 4

ROOT_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/../..)
FLOW_DIR := $(ROOT_DIR)/scripts/multi_dut
BD_SCRIPT := $(FLOW_DIR)/bd_flow.tcl
IMPL_SCRIPT := $(ROOT_DIR)/scripts/impl_export_flow.tcl
BUILD_DIR := $(ROOT_DIR)/build
LOG_DIR := $(BUILD_DIR)/logs

FLOW_NAME := multi_dut
PART_K26 := xck26-sfvc784-2LV-c
SUPPORTED_PARTS := $(PART_K26)
PART ?= $(PART_K26)
EXP_DUT ?= exp
SIGMOID_DUT ?= sigmoid

ifeq ($(EXP_DUT),exp)
EXP_HLS_CORE := pwl_pwl_nonuniform_pwl_function_exponential_use_float32
else ifeq ($(EXP_DUT),exp_f16)
EXP_HLS_CORE := pwl_pwl_nonuniform_pwl_function_exponential_use_float16
else
$(error Unsupported EXP_DUT '$(EXP_DUT)'. Supported EXP_DUT values: exp exp_f16)
endif

ifeq ($(SIGMOID_DUT),sigmoid)
SIGMOID_HLS_CORE := pwl_pwl_nonuniform_pwl_function_sigmoid_use_float32
else ifeq ($(SIGMOID_DUT),sigmoid_f16)
SIGMOID_HLS_CORE := pwl_pwl_nonuniform_pwl_function_sigmoid_use_float16
else
$(error Unsupported SIGMOID_DUT '$(SIGMOID_DUT)'. Supported SIGMOID_DUT values: sigmoid sigmoid_f16)
endif

CATALOG_SCRIPT := $(ROOT_DIR)/scripts/pwl_dut_catalog.tcl
AREA_SCRIPT := $(ROOT_DIR)/scripts/extract_pwl_area.py
EXP_COMPONENT_XML := $(ROOT_DIR)/HW/build/vitis_hls/$(EXP_HLS_CORE)/solution/impl/ip/component.xml
SIGMOID_COMPONENT_XML := $(ROOT_DIR)/HW/build/vitis_hls/$(SIGMOID_HLS_CORE)/solution/impl/ip/component.xml

ifneq ($(filter $(PART),$(SUPPORTED_PARTS)),$(PART))
$(error Unsupported PART '$(PART)'. Supported PARTs: $(SUPPORTED_PARTS))
endif

.PHONY: help check batch bitstream-xsa gui gui-auto tcl-auto area-report

help:
	@echo "PWL multi-DUT hardware flow targets:"
	@echo "  make -C scripts/multi_dut batch PART=$(PART_K26) EXP_DUT=$(EXP_DUT) SIGMOID_DUT=$(SIGMOID_DUT)"
	@echo "  make -C scripts/multi_dut bitstream-xsa PART=$(PART_K26) EXP_DUT=$(EXP_DUT) SIGMOID_DUT=$(SIGMOID_DUT) VIVADO_JOBS=$(VIVADO_JOBS)"
	@echo "  make -C scripts/multi_dut gui PART=$(PART_K26) EXP_DUT=$(EXP_DUT) SIGMOID_DUT=$(SIGMOID_DUT)"
	@echo "  make -C scripts/multi_dut tcl-auto PART=$(PART_K26) EXP_DUT=$(EXP_DUT) SIGMOID_DUT=$(SIGMOID_DUT)"
	@echo "  make -C scripts/multi_dut area-report PART=$(PART_K26)"

check:
	@command -v "$(VIVADO)" >/dev/null 2>&1 || { echo "ERROR: Vivado not found in PATH"; exit 1; }
	@test -f "$(BD_SCRIPT)" || { echo "ERROR: Tcl script not found: $(BD_SCRIPT)"; exit 1; }
	@test -f "$(IMPL_SCRIPT)" || { echo "ERROR: Tcl script not found: $(IMPL_SCRIPT)"; exit 1; }
	@test -f "$(CATALOG_SCRIPT)" || { echo "ERROR: Tcl script not found: $(CATALOG_SCRIPT)"; exit 1; }
	@test -f "$(AREA_SCRIPT)" || { echo "ERROR: Area extractor script not found: $(AREA_SCRIPT)"; exit 1; }
	@test -f "$(EXP_COMPONENT_XML)" || { echo "ERROR: Exported exponential HLS IP not found: $(EXP_COMPONENT_XML)"; exit 1; }
	@test -f "$(SIGMOID_COMPONENT_XML)" || { echo "ERROR: Exported sigmoid HLS IP not found: $(SIGMOID_COMPONENT_XML)"; exit 1; }
	@mkdir -p "$(LOG_DIR)"
	@echo "Vivado: $$(command -v "$(VIVADO)")"
	@echo "PWL multi-DUT BD Script: $(BD_SCRIPT)"
	@echo "Shared implementation Script: $(IMPL_SCRIPT)"
	@echo "Shared DUT catalog Script: $(CATALOG_SCRIPT)"
	@echo "Configured exponential-slot DUT: $(EXP_DUT)"
	@echo "Configured sigmoid-slot DUT: $(SIGMOID_DUT)"
	@echo "Exponential HLS IP: $(EXP_COMPONENT_XML)"
	@echo "Sigmoid HLS IP: $(SIGMOID_COMPONENT_XML)"
	@echo "Part: $(PART)"

batch: check
	"$(VIVADO)" -mode batch -source "$(BD_SCRIPT)" -tclargs "$(FLOW_NAME)" "$(PART)" "$(EXP_DUT)" "$(SIGMOID_DUT)" \
		-log "$(LOG_DIR)/vivado_pwl_multi_dut_bd_batch.log" \
		-journal "$(LOG_DIR)/vivado_pwl_multi_dut_bd_batch.jou"

bitstream-xsa: check
	"$(VIVADO)" -mode batch -source "$(IMPL_SCRIPT)" -tclargs "$(FLOW_NAME)" "$(PART)" "$(VIVADO_JOBS)" "$(BD_SCRIPT)" "$(EXP_DUT)" "$(SIGMOID_DUT)" \
		-log "$(LOG_DIR)/vivado_pwl_multi_dut_bitstream_xsa.log" \
		-journal "$(LOG_DIR)/vivado_pwl_multi_dut_bitstream_xsa.jou"

gui: check
	"$(VIVADO)" -mode gui -source "$(BD_SCRIPT)" -tclargs "$(FLOW_NAME)" "$(PART)" "$(EXP_DUT)" "$(SIGMOID_DUT)" \
		-log "$(LOG_DIR)/vivado_pwl_multi_dut_gui.log" \
		-journal "$(LOG_DIR)/vivado_pwl_multi_dut_gui.jou"

gui-auto: gui

tcl-auto: check
	@echo "Using script: $(BD_SCRIPT)"; \
	"$(VIVADO)" -mode tcl -source "$(BD_SCRIPT)" -tclargs "$(FLOW_NAME)" "$(PART)" "$(EXP_DUT)" "$(SIGMOID_DUT)"

area-report: check
	python3 "$(AREA_SCRIPT)" --repo-root "$(ROOT_DIR)" --flow multi_dut --part "$(PART)"
