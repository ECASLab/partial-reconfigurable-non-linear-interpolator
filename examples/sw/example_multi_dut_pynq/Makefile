SHELL := /bin/bash

PYTHON ?= python3
PART ?= xck26-sfvc784-2LV-c

PROJECT_DIR := ../..
SW_DIR := $(PROJECT_DIR)/sw/example_multi_dut_pynq
APP_SRC := $(SW_DIR)/app/main.py
BUILD_ROOT := $(PROJECT_DIR)/build/sw_pynq_multi_dut
APP_NAME := multi_dut_pynq.py
STAGED_APP := $(BUILD_ROOT)/$(APP_NAME)
PART_TAG := $(subst .,_,$(subst -,_,$(PART)))
PROJ_NAME := my_proj_multi_dut_$(PART_TAG)
BIT_FILE := $(PROJECT_DIR)/build/vivado_multi_dut/$(PART_TAG)/$(PROJ_NAME)/$(PROJ_NAME).runs/impl_1/design_1_wrapper.bit
HWH_FILE := $(PROJECT_DIR)/build/vivado_multi_dut/$(PART_TAG)/$(PROJ_NAME)/$(PROJ_NAME).gen/sources_1/bd/design_1/hw_handoff/design_1.hwh
DELIVERABLES_ROOT := $(PROJECT_DIR)/deliverables/sw_pynq_multi_dut
DELIVERABLE_APP := $(DELIVERABLES_ROOT)/$(APP_NAME)
DELIVERABLE_BIT := $(DELIVERABLES_ROOT)/design_1_wrapper.bit
DELIVERABLE_HWH := $(DELIVERABLES_ROOT)/design_1_wrapper.hwh

.PHONY: sw-pynq-multi-check sw-pynq-multi-build sw-pynq-multi-deliver-check sw-pynq-multi-deliver sw-pynq-multi-clean

sw-pynq-multi-check:
	@command -v "$(PYTHON)" >/dev/null 2>&1 || { echo "ERROR: Python interpreter not found: $(PYTHON)"; exit 1; }
	@test -f "$(APP_SRC)" || { echo "ERROR: App source not found: $(APP_SRC)"; exit 1; }
	@mkdir -p "$(BUILD_ROOT)"
	@echo "Python: $$(command -v "$(PYTHON)")"
	@echo "App source: $(APP_SRC)"
	@echo "Staged app: $(STAGED_APP)"

sw-pynq-multi-build: sw-pynq-multi-check
	"$(PYTHON)" -m py_compile "$(APP_SRC)"
	install -m 755 "$(APP_SRC)" "$(STAGED_APP)"
	@echo "Staged multi-DUT PYNQ app at $(STAGED_APP)"

sw-pynq-multi-deliver-check:
	@test -f "$(STAGED_APP)" || { \
		echo "ERROR: Staged PYNQ app not found: $(STAGED_APP)"; \
		echo "Run 'make sw-pynq-multi-build' first or use 'make sw-pynq-multi-deliver' to stage and copy in one step."; \
		exit 1; \
	}
	@test -f "$(BIT_FILE)" || { \
		echo "ERROR: Multi-DUT bitstream not found: $(BIT_FILE)"; \
		echo "Run 'make bitstream-xsa EXAMPLE_MAKE=multi PART=$(PART)' first."; \
		exit 1; \
	}
	@test -f "$(HWH_FILE)" || { \
		echo "ERROR: Multi-DUT HWH metadata not found: $(HWH_FILE)"; \
		echo "Run 'make bitstream-xsa EXAMPLE_MAKE=multi PART=$(PART)' first."; \
		exit 1; \
	}
	@mkdir -p "$(DELIVERABLES_ROOT)"
	@echo "Deliverables root: $(DELIVERABLES_ROOT)"
	@echo "App source: $(STAGED_APP)"
	@echo "Bitstream source: $(BIT_FILE)"
	@echo "HWH source: $(HWH_FILE)"

sw-pynq-multi-deliver: sw-pynq-multi-build sw-pynq-multi-deliver-check
	install -m 755 "$(STAGED_APP)" "$(DELIVERABLE_APP)"
	install -m 644 "$(BIT_FILE)" "$(DELIVERABLE_BIT)"
	install -m 644 "$(HWH_FILE)" "$(DELIVERABLE_HWH)"
	@echo "Copied app to $(DELIVERABLE_APP)"
	@echo "Copied bitstream to $(DELIVERABLE_BIT)"
	@echo "Copied HWH metadata to $(DELIVERABLE_HWH)"

sw-pynq-multi-clean:
	rm -rf "$(BUILD_ROOT)"
	rm -rf "$(SW_DIR)/app/__pycache__"
