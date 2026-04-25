SHELL := /bin/bash

VIVADO ?= vivado
VIVADO_JOBS ?= 4

ROOT_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/../..)
FLOW_DIR := $(ROOT_DIR)/scripts/pwl_dfx
BD_SCRIPT := $(FLOW_DIR)/pwl_dfx_bd_flow.tcl
IP_SCRIPT := $(FLOW_DIR)/pwl_dfx_dut_ip_flow.tcl
RP_AREA_SCRIPT := $(FLOW_DIR)/report_rp_area.tcl
CATALOG_SCRIPT := $(ROOT_DIR)/scripts/pwl_dut_catalog.tcl
AREA_SCRIPT := $(ROOT_DIR)/scripts/extract_pwl_area.py
IMPL_SCRIPT := $(ROOT_DIR)/scripts/impl_export_flow.tcl
BUILD_DIR := $(ROOT_DIR)/build
LOG_DIR := $(BUILD_DIR)/logs

FLOW_NAME := pwl_dfx
PART_K26 := xck26-sfvc784-2LV-c
SUPPORTED_PARTS := $(PART_K26)
PART ?= $(PART_K26)
RM_DUTS ?= all
SUPPORTED_RM_DUTS := exp sigmoid exp_f16 sigmoid_f16
COMMA := ,
RM_DUT_LIST := $(strip $(subst $(COMMA), ,$(RM_DUTS)))

COMPONENT_XML_exp := $(ROOT_DIR)/HW/build/vitis_hls/pwl_pwl_nonuniform_pwl_function_exponential_use_float32/solution/impl/ip/component.xml
COMPONENT_XML_sigmoid := $(ROOT_DIR)/HW/build/vitis_hls/pwl_pwl_nonuniform_pwl_function_sigmoid_use_float32/solution/impl/ip/component.xml
COMPONENT_XML_exp_f16 := $(ROOT_DIR)/HW/build/vitis_hls/pwl_pwl_nonuniform_pwl_function_exponential_use_float16/solution/impl/ip/component.xml
COMPONENT_XML_sigmoid_f16 := $(ROOT_DIR)/HW/build/vitis_hls/pwl_pwl_nonuniform_pwl_function_sigmoid_use_float16/solution/impl/ip/component.xml

ifeq ($(RM_DUTS),all)
SELECTED_RM_DUTS := $(SUPPORTED_RM_DUTS)
else
SELECTED_RM_DUTS := $(RM_DUT_LIST)
INVALID_RM_DUTS := $(filter-out $(SUPPORTED_RM_DUTS),$(SELECTED_RM_DUTS))
ifneq ($(INVALID_RM_DUTS),)
$(error Unsupported RM_DUTS value(s) '$(INVALID_RM_DUTS)'. Supported RM_DUTS values: all,exp,sigmoid,exp_f16,sigmoid_f16)
endif
endif

SELECTED_COMPONENT_XMLS := $(foreach dut,$(SELECTED_RM_DUTS),$(COMPONENT_XML_$(dut)))

ifneq ($(filter $(PART),$(SUPPORTED_PARTS)),$(PART))
$(error Unsupported PART '$(PART)'. Supported PARTs: $(SUPPORTED_PARTS))
endif

.PHONY: help check batch bitstream-xsa gui gui-auto tcl-auto rp-area-report area-report

help:
	@echo "PWL DFX hardware flow targets:"
	@echo "  make -C scripts/pwl_dfx batch PART=$(PART_K26) RM_DUTS=$(RM_DUTS)"
	@echo "  make -C scripts/pwl_dfx bitstream-xsa PART=$(PART_K26) RM_DUTS=$(RM_DUTS) VIVADO_JOBS=$(VIVADO_JOBS)"
	@echo "  make -C scripts/pwl_dfx gui PART=$(PART_K26) RM_DUTS=$(RM_DUTS)"
	@echo "  make -C scripts/pwl_dfx tcl-auto PART=$(PART_K26) RM_DUTS=$(RM_DUTS)"
	@echo "  make -C scripts/pwl_dfx rp-area-report PART=$(PART_K26)"
	@echo "  make -C scripts/pwl_dfx area-report PART=$(PART_K26)"
	@echo "  RM_DUTS can be: all, exp,sigmoid,exp_f16,sigmoid_f16 (comma-separated subset)"

check:
	@command -v "$(VIVADO)" >/dev/null 2>&1 || { echo "ERROR: Vivado not found in PATH"; exit 1; }
	@test -f "$(BD_SCRIPT)" || { echo "ERROR: Tcl script not found: $(BD_SCRIPT)"; exit 1; }
	@test -f "$(IP_SCRIPT)" || { echo "ERROR: Tcl script not found: $(IP_SCRIPT)"; exit 1; }
	@test -f "$(RP_AREA_SCRIPT)" || { echo "ERROR: Tcl script not found: $(RP_AREA_SCRIPT)"; exit 1; }
	@test -f "$(CATALOG_SCRIPT)" || { echo "ERROR: Tcl script not found: $(CATALOG_SCRIPT)"; exit 1; }
	@test -f "$(AREA_SCRIPT)" || { echo "ERROR: Area extractor script not found: $(AREA_SCRIPT)"; exit 1; }
	@test -f "$(IMPL_SCRIPT)" || { echo "ERROR: Tcl script not found: $(IMPL_SCRIPT)"; exit 1; }
	@for component_xml in $(SELECTED_COMPONENT_XMLS); do \
		test -f "$$component_xml" || { echo "ERROR: Exported HLS IP not found: $$component_xml"; exit 1; }; \
	done
	@mkdir -p "$(LOG_DIR)"
	@echo "Vivado: $$(command -v "$(VIVADO)")"
	@echo "PWL DFX BD Script: $(BD_SCRIPT)"
	@echo "PWL DUT IP Script: $(IP_SCRIPT)"
	@echo "PWL DFX RP Area Script: $(RP_AREA_SCRIPT)"
	@echo "Shared DUT catalog Script: $(CATALOG_SCRIPT)"
	@echo "Shared Impl Script: $(IMPL_SCRIPT)"
	@echo "Selected RMs: $(SELECTED_RM_DUTS)"
	@for component_xml in $(SELECTED_COMPONENT_XMLS); do \
		echo "Selected RM HLS IP: $$component_xml"; \
	done
	@echo "Part: $(PART)"

batch: check
	"$(VIVADO)" -mode batch -source "$(BD_SCRIPT)" -tclargs "$(FLOW_NAME)" "$(PART)" "$(RM_DUTS)" \
		-log "$(LOG_DIR)/vivado_pwl_dfx_bd_batch.log" \
		-journal "$(LOG_DIR)/vivado_pwl_dfx_bd_batch.jou"

bitstream-xsa: check
	"$(VIVADO)" -mode batch -source "$(IMPL_SCRIPT)" -tclargs "$(FLOW_NAME)" "$(PART)" "$(VIVADO_JOBS)" "$(BD_SCRIPT)" "$(RM_DUTS)" \
		-log "$(LOG_DIR)/vivado_pwl_dfx_bitstream_xsa.log" \
		-journal "$(LOG_DIR)/vivado_pwl_dfx_bitstream_xsa.jou"

gui: check
	"$(VIVADO)" -mode gui -source "$(BD_SCRIPT)" -tclargs "$(FLOW_NAME)" "$(PART)" "$(RM_DUTS)" \
		-log "$(LOG_DIR)/vivado_pwl_dfx_gui.log" \
		-journal "$(LOG_DIR)/vivado_pwl_dfx_gui.jou"

gui-auto: gui

tcl-auto: check
	@echo "Using script: $(BD_SCRIPT)"; \
	"$(VIVADO)" -mode tcl -source "$(BD_SCRIPT)" -tclargs "$(FLOW_NAME)" "$(PART)" "$(RM_DUTS)"

rp-area-report: check
	"$(VIVADO)" -mode batch -source "$(RP_AREA_SCRIPT)" -tclargs "$(FLOW_NAME)" "$(PART)" \
		-log "$(LOG_DIR)/vivado_pwl_dfx_rp_area.log" \
		-journal "$(LOG_DIR)/vivado_pwl_dfx_rp_area.jou"

area-report: rp-area-report
	python3 "$(AREA_SCRIPT)" --repo-root "$(ROOT_DIR)" --flow dfx --part "$(PART)"
