SHELL := /bin/bash

PYTHON ?= python3
PART ?= xck26-sfvc784-2LV-c

PROJECT_DIR := ../..
SW_DIR := $(PROJECT_DIR)/sw/example_dfx_pynq
APP_SRC := $(SW_DIR)/app/main.py
BUILD_ROOT := $(PROJECT_DIR)/build/sw_pynq_dfx
APP_NAME := dfx_pynq.py
STAGED_APP := $(BUILD_ROOT)/$(APP_NAME)
PART_TAG := $(subst .,_,$(subst -,_,$(PART)))
PROJ_NAME := my_proj_dfx_$(PART_TAG)
DFX_BUILD_DIR := $(PROJECT_DIR)/build/vivado_dfx/$(PART_TAG)/$(PROJ_NAME)
FULL_MUL_BIT := $(DFX_BUILD_DIR)/$(PROJ_NAME).runs/impl_1/dut_64x64_axis_dfx_top.bit
FULL_XOR_BIT := $(DFX_BUILD_DIR)/$(PROJ_NAME).runs/impl_config_xor/dut_64x64_axis_dfx_top.bit
FULL_HWH := $(DFX_BUILD_DIR)/$(PROJ_NAME).gen/sources_1/bd/design_1/hw_handoff/design_1.hwh
PARTIAL_MUL_BIT := $(DFX_BUILD_DIR)/$(PROJ_NAME).runs/impl_1/u_rp_rp_mul_partial.bit
PARTIAL_XOR_BIT := $(DFX_BUILD_DIR)/$(PROJ_NAME).runs/impl_config_xor/u_rp_rp_xor_partial.bit
DELIVERABLES_ROOT := $(PROJECT_DIR)/deliverables/sw_pynq_dfx
DELIVERABLE_APP := $(DELIVERABLES_ROOT)/$(APP_NAME)
DELIVERABLE_FULL_MUL_BIT := $(DELIVERABLES_ROOT)/dfx_full_region_u_rp_rm_mul.bit
DELIVERABLE_FULL_MUL_HWH := $(DELIVERABLES_ROOT)/dfx_full_region_u_rp_rm_mul.hwh
DELIVERABLE_FULL_XOR_BIT := $(DELIVERABLES_ROOT)/dfx_full_region_u_rp_rm_xor.bit
DELIVERABLE_FULL_XOR_HWH := $(DELIVERABLES_ROOT)/dfx_full_region_u_rp_rm_xor.hwh
DELIVERABLE_PARTIAL_MUL_BIT := $(DELIVERABLES_ROOT)/dfx_partial_region_u_rp_rm_mul.bit
DELIVERABLE_PARTIAL_XOR_BIT := $(DELIVERABLES_ROOT)/dfx_partial_region_u_rp_rm_xor.bit

.PHONY: sw-pynq-dfx-check sw-pynq-dfx-build sw-pynq-dfx-deliver-check sw-pynq-dfx-deliver sw-pynq-dfx-clean

sw-pynq-dfx-check:
	@command -v "$(PYTHON)" >/dev/null 2>&1 || { echo "ERROR: Python interpreter not found: $(PYTHON)"; exit 1; }
	@test -f "$(APP_SRC)" || { echo "ERROR: App source not found: $(APP_SRC)"; exit 1; }
	@mkdir -p "$(BUILD_ROOT)"
	@echo "Python: $$(command -v "$(PYTHON)")"
	@echo "App source: $(APP_SRC)"
	@echo "Staged app: $(STAGED_APP)"

sw-pynq-dfx-build: sw-pynq-dfx-check
	"$(PYTHON)" -m py_compile "$(APP_SRC)"
	@rm -f "$(STAGED_APP)"
	install -m 755 "$(APP_SRC)" "$(STAGED_APP)"
	@echo "Staged DFX PYNQ app at $(STAGED_APP)"

sw-pynq-dfx-deliver-check:
	@test -f "$(STAGED_APP)" || { \
		echo "ERROR: Staged PYNQ app not found: $(STAGED_APP)"; \
		echo "Run 'make sw-pynq-dfx-build' first or use 'make sw-pynq-dfx-deliver' to stage and copy in one step."; \
		exit 1; \
	}
	@test -f "$(FULL_MUL_BIT)" || { \
		echo "ERROR: Default full DFX bitstream not found: $(FULL_MUL_BIT)"; \
		echo "Run 'make bitstream-xsa EXAMPLE_MAKE=dfx PART=$(PART)' first."; \
		exit 1; \
	}
	@test -f "$(FULL_XOR_BIT)" || { \
		echo "ERROR: Alternate full DFX bitstream not found: $(FULL_XOR_BIT)"; \
		echo "Run 'make bitstream-xsa EXAMPLE_MAKE=dfx PART=$(PART)' first."; \
		exit 1; \
	}
	@test -f "$(FULL_HWH)" || { \
		echo "ERROR: Full DFX HWH metadata not found: $(FULL_HWH)"; \
		echo "Run 'make bitstream-xsa EXAMPLE_MAKE=dfx PART=$(PART)' first."; \
		exit 1; \
	}
	@test -f "$(PARTIAL_MUL_BIT)" || { \
		echo "ERROR: Mul partial bitstream not found: $(PARTIAL_MUL_BIT)"; \
		echo "Run 'make bitstream-xsa EXAMPLE_MAKE=dfx PART=$(PART)' first."; \
		exit 1; \
	}
	@test -f "$(PARTIAL_XOR_BIT)" || { \
		echo "ERROR: XOR partial bitstream not found: $(PARTIAL_XOR_BIT)"; \
		echo "Run 'make bitstream-xsa EXAMPLE_MAKE=dfx PART=$(PART)' first."; \
		exit 1; \
	}
	@mkdir -p "$(DELIVERABLES_ROOT)"
	@echo "Deliverables root: $(DELIVERABLES_ROOT)"
	@echo "App source: $(STAGED_APP)"
	@echo "Full bitstream (mul): $(FULL_MUL_BIT)"
	@echo "Full bitstream (xor): $(FULL_XOR_BIT)"
	@echo "Full HWH: $(FULL_HWH)"
	@echo "Partial bitstream (mul): $(PARTIAL_MUL_BIT)"
	@echo "Partial bitstream (xor): $(PARTIAL_XOR_BIT)"

sw-pynq-dfx-deliver: sw-pynq-dfx-build sw-pynq-dfx-deliver-check
	install -m 755 "$(STAGED_APP)" "$(DELIVERABLE_APP)"
	install -m 644 "$(FULL_MUL_BIT)" "$(DELIVERABLE_FULL_MUL_BIT)"
	install -m 644 "$(FULL_HWH)" "$(DELIVERABLE_FULL_MUL_HWH)"
	install -m 644 "$(FULL_XOR_BIT)" "$(DELIVERABLE_FULL_XOR_BIT)"
	install -m 644 "$(FULL_HWH)" "$(DELIVERABLE_FULL_XOR_HWH)"
	install -m 644 "$(PARTIAL_MUL_BIT)" "$(DELIVERABLE_PARTIAL_MUL_BIT)"
	install -m 644 "$(PARTIAL_XOR_BIT)" "$(DELIVERABLE_PARTIAL_XOR_BIT)"
	@echo "Copied app to $(DELIVERABLE_APP)"
	@echo "Copied full mul overlay to $(DELIVERABLE_FULL_MUL_BIT)"
	@echo "Copied full xor overlay to $(DELIVERABLE_FULL_XOR_BIT)"
	@echo "Copied full overlay metadata to $(DELIVERABLE_FULL_MUL_HWH) and $(DELIVERABLE_FULL_XOR_HWH)"
	@echo "Copied partial mul overlay to $(DELIVERABLE_PARTIAL_MUL_BIT)"
	@echo "Copied partial xor overlay to $(DELIVERABLE_PARTIAL_XOR_BIT)"

sw-pynq-dfx-clean:
	rm -rf "$(BUILD_ROOT)"
	rm -rf "$(SW_DIR)/app/__pycache__"
