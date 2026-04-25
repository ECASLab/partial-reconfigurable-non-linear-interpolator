SHELL := /bin/bash

VIVADO ?= vivado
VIVADO_JOBS ?= 4

PROJECT_DIR := ../..
FLOW_DIR := $(PROJECT_DIR)/scripts/individual
BD_SCRIPT := $(FLOW_DIR)/bd_flow.tcl
IMPL_SCRIPT := $(PROJECT_DIR)/scripts/impl_export_flow.tcl
BUILD_DIR := $(PROJECT_DIR)/build
LOG_DIR := $(BUILD_DIR)/logs

DUT ?= exp
PART_K26 := xck26-sfvc784-2LV-c
SUPPORTED_PARTS := $(PART_K26)
PART ?= $(PART_K26)

ifneq ($(filter $(PART),$(SUPPORTED_PARTS)),$(PART))
$(error Unsupported PART '$(PART)'. Supported PARTs: $(SUPPORTED_PARTS))
endif

.PHONY: help check batch bitstream-xsa gui gui-auto tcl-auto

help:
	@echo "PWL individual hardware flow targets:"
	@echo "  make batch DUT=exp PART=$(PART_K26)"
	@echo "  make batch DUT=sigmoid PART=$(PART_K26)"
	@echo "  make bitstream-xsa DUT=exp PART=$(PART_K26) VIVADO_JOBS=$(VIVADO_JOBS)"
	@echo "  make bitstream-xsa DUT=sigmoid PART=$(PART_K26) VIVADO_JOBS=$(VIVADO_JOBS)"
	@echo "  make gui DUT=exp PART=$(PART_K26)"
	@echo "  make tcl-auto DUT=exp PART=$(PART_K26)"

check:
	@command -v "$(VIVADO)" >/dev/null 2>&1 || { echo "ERROR: Vivado not found in PATH"; exit 1; }
	@test -f "$(BD_SCRIPT)" || { echo "ERROR: Tcl script not found: $(BD_SCRIPT)"; exit 1; }
	@test -f "$(IMPL_SCRIPT)" || { echo "ERROR: Tcl script not found: $(IMPL_SCRIPT)"; exit 1; }
	@mkdir -p "$(LOG_DIR)"
	@echo "Vivado: $$(command -v "$(VIVADO)")"
	@echo "PWL individual BD Script: $(BD_SCRIPT)"
	@echo "PWL implementation Script: $(IMPL_SCRIPT)"
	@echo "Part: $(PART)"
	@echo "DUT: $(DUT)"

batch: check
	"$(VIVADO)" -mode batch -source "$(BD_SCRIPT)" -tclargs "$(DUT)" "$(PART)" \
		-log "$(LOG_DIR)/vivado_pwl_individual_bd_batch.log" \
		-journal "$(LOG_DIR)/vivado_pwl_individual_bd_batch.jou"

bitstream-xsa: check
	"$(VIVADO)" -mode batch -source "$(IMPL_SCRIPT)" -tclargs "$(DUT)" "$(PART)" "$(VIVADO_JOBS)" "$(BD_SCRIPT)" \
		-log "$(LOG_DIR)/vivado_pwl_individual_bitstream_xsa.log" \
		-journal "$(LOG_DIR)/vivado_pwl_individual_bitstream_xsa.jou"

gui: check
	"$(VIVADO)" -mode gui -source "$(BD_SCRIPT)" -tclargs "$(DUT)" "$(PART)" \
		-log "$(LOG_DIR)/vivado_pwl_individual_gui.log" \
		-journal "$(LOG_DIR)/vivado_pwl_individual_gui.jou"

gui-auto: gui

tcl-auto: check
	@echo "Using script: $(BD_SCRIPT)"; \
	"$(VIVADO)" -mode tcl -source "$(BD_SCRIPT)" -tclargs "$(DUT)" "$(PART)"
