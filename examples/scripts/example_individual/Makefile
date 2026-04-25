SHELL := /bin/bash

VIVADO ?= vivado
VIVADO_JOBS ?= 4

PROJECT_DIR := ../..
FLOW_DIR := $(PROJECT_DIR)/scripts/example_individual
BD_SCRIPT := $(FLOW_DIR)/example_bd_flow.tcl
IP_SCRIPT := $(PROJECT_DIR)/scripts/example_dut_ip_flow.tcl
IMPL_SCRIPT := $(PROJECT_DIR)/scripts/example_impl_export_flow.tcl
BUILD_DIR := $(PROJECT_DIR)/build
LOG_DIR := $(BUILD_DIR)/logs

DUT ?= mul
PART_K26 := xck26-sfvc784-2LV-c
PART_U250 := xcu250-figd2104-2L-e
SUPPORTED_PARTS := $(PART_K26) $(PART_U250)
PART ?= $(PART_K26)

ifneq ($(filter $(PART),$(SUPPORTED_PARTS)),$(PART))
$(error Unsupported PART '$(PART)'. Supported PARTs: $(SUPPORTED_PARTS))
endif

.PHONY: help check batch bitstream-xsa gui gui-auto tcl-auto

help:
	@echo "Example individual hardware flow targets:"
	@echo "  make batch DUT=mul PART=$(PART_K26)"
	@echo "  make batch DUT=xor PART=$(PART_K26)"
	@echo "  make bitstream-xsa DUT=mul PART=$(PART_K26) VIVADO_JOBS=$(VIVADO_JOBS)"
	@echo "  make gui DUT=mul PART=$(PART_K26)"
	@echo "  make tcl-auto DUT=mul PART=$(PART_K26)"

check:
	@command -v "$(VIVADO)" >/dev/null 2>&1 || { echo "ERROR: Vivado not found in PATH"; exit 1; }
	@test -f "$(BD_SCRIPT)" || { echo "ERROR: Tcl script not found: $(BD_SCRIPT)"; exit 1; }
	@test -f "$(IP_SCRIPT)" || { echo "ERROR: Tcl script not found: $(IP_SCRIPT)"; exit 1; }
	@test -f "$(IMPL_SCRIPT)" || { echo "ERROR: Tcl script not found: $(IMPL_SCRIPT)"; exit 1; }
	@mkdir -p "$(LOG_DIR)"
	@echo "Vivado: $$(command -v "$(VIVADO)")"
	@echo "Example BD Script: $(BD_SCRIPT)"
	@echo "Shared DUT IP Script: $(IP_SCRIPT)"
	@echo "Shared Impl Script: $(IMPL_SCRIPT)"
	@echo "Part: $(PART)"

batch: check
	"$(VIVADO)" -mode batch -source "$(BD_SCRIPT)" -tclargs "$(DUT)" "$(PART)" \
		-log "$(LOG_DIR)/vivado_bd_batch.log" \
		-journal "$(LOG_DIR)/vivado_bd_batch.jou"

bitstream-xsa: check
	"$(VIVADO)" -mode batch -source "$(IMPL_SCRIPT)" -tclargs "$(DUT)" "$(PART)" "$(VIVADO_JOBS)" "$(BD_SCRIPT)" \
		-log "$(LOG_DIR)/vivado_bitstream_xsa.log" \
		-journal "$(LOG_DIR)/vivado_bitstream_xsa.jou"

gui: check
	"$(VIVADO)" -mode gui -source "$(BD_SCRIPT)" -tclargs "$(DUT)" "$(PART)" \
		-log "$(LOG_DIR)/vivado_gui.log" \
		-journal "$(LOG_DIR)/vivado_gui.jou"

gui-auto: gui

tcl-auto: check
	@echo "Using script: $(BD_SCRIPT)"; \
	"$(VIVADO)" -mode tcl -source "$(BD_SCRIPT)" -tclargs "$(DUT)" "$(PART)"
