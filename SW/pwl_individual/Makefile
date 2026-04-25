SHELL := /bin/bash

PYTHON ?= python3
PART ?= xck26-sfvc784-2LV-c
ROOT_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/../../..)
APP_DIR := $(ROOT_DIR)/SW/pwl_individual
APP_SRC := $(APP_DIR)/pwl_pynq.py
APP_NAME := pwl_pynq.py
BUILD_ROOT := $(ROOT_DIR)/build/sw_pynq_pwl_individual
STAGED_APP := $(BUILD_ROOT)/$(APP_NAME)
DELIVERABLES_ROOT := $(ROOT_DIR)/deliverables/sw_pynq_pwl_individual
SUPPORTED_DUTS := exp sigmoid
PART_TAG := $(subst .,_,$(subst -,_,$(PART)))

.PHONY: help check build deliver-check deliver clean

help:
	@echo "PWL individual PYNQ software targets:"
	@echo "  make -C SW/pwl_individual check PART=$(PART)"
	@echo "  make -C SW/pwl_individual build PART=$(PART)"
	@echo "  make -C SW/pwl_individual deliver PART=$(PART)"
	@echo "  make -C SW/pwl_individual clean"

check:
	@command -v "$(PYTHON)" >/dev/null 2>&1 || { echo "ERROR: Python interpreter not found: $(PYTHON)"; exit 1; }
	@test -f "$(APP_SRC)" || { echo "ERROR: App source not found: $(APP_SRC)"; exit 1; }
	@mkdir -p "$(BUILD_ROOT)"
	@echo "Python: $$(command -v "$(PYTHON)")"
	@echo "App source: $(APP_SRC)"
	@echo "Staged app: $(STAGED_APP)"
	@echo "Part: $(PART)"
	@for dut in $(SUPPORTED_DUTS); do \
		proj_name="my_proj_$${dut}_$(PART_TAG)"; \
		bit_file="$(ROOT_DIR)/build/vivado/$$dut/$(PART_TAG)/$$proj_name/$${proj_name}.runs/impl_1/design_1_wrapper.bit"; \
		hwh_file="$(ROOT_DIR)/build/vivado/$$dut/$(PART_TAG)/$$proj_name/$${proj_name}.gen/sources_1/bd/design_1/hw_handoff/design_1.hwh"; \
		test -f "$$bit_file" || { echo "ERROR: Bitstream not found for $$dut: $$bit_file"; exit 1; }; \
		test -f "$$hwh_file" || { echo "ERROR: HWH metadata not found for $$dut: $$hwh_file"; exit 1; }; \
		echo "Bitstream ($$dut): $$bit_file"; \
		echo "HWH metadata ($$dut): $$hwh_file"; \
	done

build: check
	"$(PYTHON)" -m py_compile "$(APP_SRC)"
	@rm -f "$(STAGED_APP)"
	install -m 755 "$(APP_SRC)" "$(STAGED_APP)"
	@echo "Staged PYNQ app at $(STAGED_APP)"

deliver-check: check
	@test -f "$(STAGED_APP)" || { \
		echo "ERROR: Staged PYNQ app not found: $(STAGED_APP)"; \
		echo "Run 'make -C SW/pwl_individual build' first or use 'make -C SW/pwl_individual deliver'."; \
		exit 1; \
	}
	@mkdir -p "$(DELIVERABLES_ROOT)"
	@echo "Deliverables root: $(DELIVERABLES_ROOT)"
	@echo "Staged app: $(STAGED_APP)"
	@for dut in $(SUPPORTED_DUTS); do \
		proj_name="my_proj_$${dut}_$(PART_TAG)"; \
		bit_file="$(ROOT_DIR)/build/vivado/$$dut/$(PART_TAG)/$$proj_name/$${proj_name}.runs/impl_1/design_1_wrapper.bit"; \
		hwh_file="$(ROOT_DIR)/build/vivado/$$dut/$(PART_TAG)/$$proj_name/$${proj_name}.gen/sources_1/bd/design_1/hw_handoff/design_1.hwh"; \
		echo "Source bitstream ($$dut): $$bit_file"; \
		echo "Source HWH ($$dut): $$hwh_file"; \
		echo "Deliverable bitstream ($$dut): $(DELIVERABLES_ROOT)/$$dut/design_1_wrapper.bit"; \
		echo "Deliverable HWH ($$dut): $(DELIVERABLES_ROOT)/$$dut/design_1_wrapper.hwh"; \
	done

deliver: build deliver-check
	@rm -f "$(DELIVERABLES_ROOT)/$(APP_NAME)"
	install -m 755 "$(STAGED_APP)" "$(DELIVERABLES_ROOT)/$(APP_NAME)"
	@for dut in $(SUPPORTED_DUTS); do \
		proj_name="my_proj_$${dut}_$(PART_TAG)"; \
		bit_file="$(ROOT_DIR)/build/vivado/$$dut/$(PART_TAG)/$$proj_name/$${proj_name}.runs/impl_1/design_1_wrapper.bit"; \
		hwh_file="$(ROOT_DIR)/build/vivado/$$dut/$(PART_TAG)/$$proj_name/$${proj_name}.gen/sources_1/bd/design_1/hw_handoff/design_1.hwh"; \
		dst_dir="$(DELIVERABLES_ROOT)/$$dut"; \
		mkdir -p "$$dst_dir"; \
		rm -f "$$dst_dir/design_1_wrapper.bit" "$$dst_dir/design_1_wrapper.hwh"; \
		install -m 644 "$$bit_file" "$$dst_dir/design_1_wrapper.bit"; \
		install -m 644 "$$hwh_file" "$$dst_dir/design_1_wrapper.hwh"; \
		echo "Copied bitstream ($$dut) to $$dst_dir/design_1_wrapper.bit"; \
		echo "Copied HWH metadata ($$dut) to $$dst_dir/design_1_wrapper.hwh"; \
	done
	@echo "Copied app to $(DELIVERABLES_ROOT)/$(APP_NAME)"

clean:
	rm -rf "$(BUILD_ROOT)"
	rm -rf "$(APP_DIR)/__pycache__"
