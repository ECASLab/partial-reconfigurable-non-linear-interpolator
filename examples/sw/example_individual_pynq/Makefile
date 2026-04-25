SHELL := /bin/bash

PYTHON ?= python3
PART ?= xck26-sfvc784-2LV-c
DUT ?= mul
SUPPORTED_DUTS := mul xor

PROJECT_DIR := ../..
SW_DIR := $(PROJECT_DIR)/sw/example_individual_pynq
APP_SRC := $(SW_DIR)/app/main.py
BUILD_ROOT := $(PROJECT_DIR)/build/sw_pynq
APP_NAME := individual_pynq.py
STAGED_APP := $(BUILD_ROOT)/$(APP_NAME)
PART_TAG := $(subst .,_,$(subst -,_,$(PART)))
DELIVERABLES_ROOT := $(PROJECT_DIR)/deliverables/sw_pynq
DELIVERABLES_MUL_DIR := $(DELIVERABLES_ROOT)/mul
DELIVERABLES_XOR_DIR := $(DELIVERABLES_ROOT)/xor
DELIVERABLE_APP := $(DELIVERABLES_ROOT)/$(APP_NAME)

.PHONY: sw-pynq-check sw-pynq-build sw-pynq-deliver-check sw-pynq-deliver sw-pynq-clean

sw-pynq-check:
	@command -v "$(PYTHON)" >/dev/null 2>&1 || { echo "ERROR: Python interpreter not found: $(PYTHON)"; exit 1; }
	@test -f "$(APP_SRC)" || { echo "ERROR: App source not found: $(APP_SRC)"; exit 1; }
	@mkdir -p "$(BUILD_ROOT)"
	@echo "Python: $$(command -v "$(PYTHON)")"
	@echo "App source: $(APP_SRC)"
	@echo "Staged app: $(STAGED_APP)"

sw-pynq-build: sw-pynq-check
	"$(PYTHON)" -m py_compile "$(APP_SRC)"
	install -m 755 "$(APP_SRC)" "$(STAGED_APP)"
	@echo "Staged PYNQ app at $(STAGED_APP)"

sw-pynq-deliver-check:
	@test -f "$(STAGED_APP)" || { \
		echo "ERROR: Staged PYNQ app not found: $(STAGED_APP)"; \
		echo "Run 'make sw-pynq-build' first or use 'make sw-pynq-deliver' to stage and copy in one step."; \
		exit 1; \
	}
	@mkdir -p "$(DELIVERABLES_ROOT)" "$(DELIVERABLES_MUL_DIR)" "$(DELIVERABLES_XOR_DIR)"
	@echo "Deliverables root: $(DELIVERABLES_ROOT)"
	@echo "App source: $(STAGED_APP)"
	@found=0; \
	for dut in $(SUPPORTED_DUTS); do \
		bit_file="$(PROJECT_DIR)/build/vivado/$$dut/$(PART_TAG)/my_proj_$${dut}_$(PART_TAG)/my_proj_$${dut}_$(PART_TAG).runs/impl_1/design_1_wrapper.bit"; \
		hwh_file="$(PROJECT_DIR)/build/vivado/$$dut/$(PART_TAG)/my_proj_$${dut}_$(PART_TAG)/my_proj_$${dut}_$(PART_TAG).gen/sources_1/bd/design_1/hw_handoff/design_1.hwh"; \
		if [ -f "$$bit_file" ] || [ -f "$$hwh_file" ]; then \
			found=1; \
		fi; \
		if [ -f "$$bit_file" ]; then \
			echo "Bitstream source ($$dut): $$bit_file"; \
		else \
			echo "Bitstream source ($$dut): missing"; \
		fi; \
		if [ -f "$$hwh_file" ]; then \
			echo "HWH source ($$dut): $$hwh_file"; \
		else \
			echo "HWH source ($$dut): missing"; \
		fi; \
	done; \
	test "$$found" -eq 1 || { \
		echo "ERROR: No DUT bitstream or HWH files were found for $(SUPPORTED_DUTS)."; \
		exit 1; \
	}

sw-pynq-deliver: sw-pynq-build sw-pynq-deliver-check
	@find "$(DELIVERABLES_ROOT)" -mindepth 2 -maxdepth 2 -type f -name "$(APP_NAME)" -delete
	install -m 755 "$(STAGED_APP)" "$(DELIVERABLE_APP)"
	@for dut in $(SUPPORTED_DUTS); do \
		dut_dir="$(DELIVERABLES_ROOT)/$$dut"; \
		bit_file="$(PROJECT_DIR)/build/vivado/$$dut/$(PART_TAG)/my_proj_$${dut}_$(PART_TAG)/my_proj_$${dut}_$(PART_TAG).runs/impl_1/design_1_wrapper.bit"; \
		hwh_file="$(PROJECT_DIR)/build/vivado/$$dut/$(PART_TAG)/my_proj_$${dut}_$(PART_TAG)/my_proj_$${dut}_$(PART_TAG).gen/sources_1/bd/design_1/hw_handoff/design_1.hwh"; \
		mkdir -p "$$dut_dir"; \
		rm -f "$$dut_dir/design_1_wrapper.bit" "$$dut_dir/design_1_wrapper.hwh"; \
		if [ -f "$$bit_file" ]; then \
			install -m 644 "$$bit_file" "$$dut_dir/design_1_wrapper.bit"; \
			echo "Copied bitstream ($$dut) to $$dut_dir/design_1_wrapper.bit"; \
		else \
			echo "Skipped bitstream ($$dut): source not found"; \
		fi; \
		if [ -f "$$hwh_file" ]; then \
			install -m 644 "$$hwh_file" "$$dut_dir/design_1_wrapper.hwh"; \
			echo "Copied HWH metadata ($$dut) to $$dut_dir/design_1_wrapper.hwh"; \
		else \
			echo "Skipped HWH metadata ($$dut): source not found"; \
		fi; \
	done
	@echo "Copied app to $(DELIVERABLE_APP)"

sw-pynq-clean:
	rm -rf "$(BUILD_ROOT)"
	rm -rf "$(SW_DIR)/app/__pycache__"
