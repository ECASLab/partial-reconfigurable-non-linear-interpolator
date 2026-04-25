SHELL := /bin/bash

PYTHON ?= python3
PART ?= xck26-sfvc784-2LV-c
EXP_DUT ?= exp
SIGMOID_DUT ?= sigmoid

ROOT_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/../..)
APP_DIR := $(ROOT_DIR)/SW/pwl_multi_dut_pynq
APP_SRC := $(APP_DIR)/app/main.py
README_SRC := $(APP_DIR)/README.md
BUILD_ROOT := $(ROOT_DIR)/build/sw_pynq_pwl_multi_dut
APP_NAME := pwl_multi_dut_pynq.py
STAGED_APP := $(BUILD_ROOT)/$(APP_NAME)
PART_TAG := $(subst .,_,$(subst -,_,$(PART)))
ifeq ($(EXP_DUT),exp)
else ifeq ($(EXP_DUT),exp_f16)
else
$(error Unsupported EXP_DUT '$(EXP_DUT)'. Supported EXP_DUT values: exp exp_f16)
endif

ifeq ($(SIGMOID_DUT),sigmoid)
else ifeq ($(SIGMOID_DUT),sigmoid_f16)
else
$(error Unsupported SIGMOID_DUT '$(SIGMOID_DUT)'. Supported SIGMOID_DUT values: sigmoid sigmoid_f16)
endif

ifneq ($(EXP_DUT),exp)
PROJ_SUFFIX := _$(EXP_DUT)_$(SIGMOID_DUT)
else ifneq ($(SIGMOID_DUT),sigmoid)
PROJ_SUFFIX := _$(EXP_DUT)_$(SIGMOID_DUT)
else
PROJ_SUFFIX :=
endif

PROJ_NAME := my_proj_multi_dut$(PROJ_SUFFIX)_$(PART_TAG)
BIT_FILE := $(ROOT_DIR)/build/vivado_multi_dut/$(PART_TAG)/$(PROJ_NAME)/$(PROJ_NAME).runs/impl_1/design_1_wrapper.bit
HWH_FILE := $(ROOT_DIR)/build/vivado_multi_dut/$(PART_TAG)/$(PROJ_NAME)/$(PROJ_NAME).gen/sources_1/bd/design_1/hw_handoff/design_1.hwh
DELIVERABLES_ROOT := $(ROOT_DIR)/deliverables/sw_pynq_pwl_multi_dut
DELIVERABLE_APP := $(DELIVERABLES_ROOT)/$(APP_NAME)
DELIVERABLE_README := $(DELIVERABLES_ROOT)/README.md
DELIVERABLE_BIT := $(DELIVERABLES_ROOT)/design_1_wrapper.bit
DELIVERABLE_HWH := $(DELIVERABLES_ROOT)/design_1_wrapper.hwh

.PHONY: help check build deliver-check deliver clean

help:
	@echo "PWL multi-DUT PYNQ software targets:"
	@echo "  make -C SW/pwl_multi_dut_pynq check PART=$(PART) EXP_DUT=$(EXP_DUT) SIGMOID_DUT=$(SIGMOID_DUT)"
	@echo "  make -C SW/pwl_multi_dut_pynq build PART=$(PART) EXP_DUT=$(EXP_DUT) SIGMOID_DUT=$(SIGMOID_DUT)"
	@echo "  make -C SW/pwl_multi_dut_pynq deliver PART=$(PART) EXP_DUT=$(EXP_DUT) SIGMOID_DUT=$(SIGMOID_DUT)"
	@echo "  make -C SW/pwl_multi_dut_pynq clean"

check:
	@command -v "$(PYTHON)" >/dev/null 2>&1 || { echo "ERROR: Python interpreter not found: $(PYTHON)"; exit 1; }
	@test -f "$(APP_SRC)" || { echo "ERROR: App source not found: $(APP_SRC)"; exit 1; }
	@test -f "$(README_SRC)" || { echo "ERROR: README source not found: $(README_SRC)"; exit 1; }
	@mkdir -p "$(BUILD_ROOT)"
	@echo "Python: $$(command -v "$(PYTHON)")"
	@echo "App source: $(APP_SRC)"
	@echo "Staged app: $(STAGED_APP)"
	@echo "Configured exponential-slot DUT: $(EXP_DUT)"
	@echo "Configured sigmoid-slot DUT: $(SIGMOID_DUT)"

build: check
	"$(PYTHON)" -m py_compile "$(APP_SRC)"
	@rm -f "$(STAGED_APP)"
	install -m 755 "$(APP_SRC)" "$(STAGED_APP)"
	@echo "Staged PWL multi-DUT PYNQ app at $(STAGED_APP)"

deliver-check:
	@test -f "$(STAGED_APP)" || { \
		echo "ERROR: Staged PYNQ app not found: $(STAGED_APP)"; \
		echo "Run 'make -C SW/pwl_multi_dut_pynq build' first or use 'make -C SW/pwl_multi_dut_pynq deliver'."; \
		exit 1; \
	}
	@test -f "$(BIT_FILE)" || { \
		echo "ERROR: Multi-DUT bitstream not found: $(BIT_FILE)"; \
		echo "Run 'make -C scripts/multi_dut bitstream-xsa PART=$(PART)' first."; \
		exit 1; \
	}
	@test -f "$(HWH_FILE)" || { \
		echo "ERROR: Multi-DUT HWH metadata not found: $(HWH_FILE)"; \
		echo "Run 'make -C scripts/multi_dut bitstream-xsa PART=$(PART)' first."; \
		exit 1; \
	}
	@mkdir -p "$(DELIVERABLES_ROOT)"
	@echo "Deliverables root: $(DELIVERABLES_ROOT)"
	@echo "Staged app: $(STAGED_APP)"
	@echo "Bitstream source: $(BIT_FILE)"
	@echo "HWH source: $(HWH_FILE)"

deliver: build deliver-check
	install -m 755 "$(STAGED_APP)" "$(DELIVERABLE_APP)"
	install -m 644 "$(README_SRC)" "$(DELIVERABLE_README)"
	install -m 644 "$(BIT_FILE)" "$(DELIVERABLE_BIT)"
	install -m 644 "$(HWH_FILE)" "$(DELIVERABLE_HWH)"
	@echo "Copied app to $(DELIVERABLE_APP)"
	@echo "Copied README to $(DELIVERABLE_README)"
	@echo "Copied bitstream to $(DELIVERABLE_BIT)"
	@echo "Copied HWH metadata to $(DELIVERABLE_HWH)"

clean:
	rm -rf "$(BUILD_ROOT)"
	rm -rf "$(APP_DIR)/app/__pycache__"
