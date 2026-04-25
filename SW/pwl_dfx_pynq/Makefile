SHELL := /bin/bash

PYTHON ?= python3
PART ?= xck26-sfvc784-2LV-c
SUPPORTED_RMS := exp sigmoid exp_f16 sigmoid_f16
RMS ?= $(SUPPORTED_RMS)
comma := ,
RMS_LIST := $(strip $(subst $(comma), ,$(RMS)))
INVALID_RMS := $(filter-out $(SUPPORTED_RMS),$(RMS_LIST))

ifeq ($(strip $(RMS_LIST)),)
$(error RMS must include at least one RM from: $(SUPPORTED_RMS))
endif

ifneq ($(strip $(INVALID_RMS)),)
$(error Unsupported RM(s) in RMS: $(INVALID_RMS). Supported values: $(SUPPORTED_RMS))
endif

ROOT_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/../..)
APP_DIR := $(ROOT_DIR)/SW/pwl_dfx_pynq
APP_SRC := $(APP_DIR)/app/main.py
README_SRC := $(APP_DIR)/README.md
BUILD_ROOT := $(ROOT_DIR)/build/sw_pynq_pwl_dfx
APP_NAME := pwl_dfx_pynq.py
STAGED_APP := $(BUILD_ROOT)/$(APP_NAME)
PART_TAG := $(subst .,_,$(subst -,_,$(PART)))
PROJ_NAME := my_proj_pwl_dfx_$(PART_TAG)
DFX_BUILD_DIR := $(ROOT_DIR)/build/vivado_pwl_dfx/$(PART_TAG)/$(PROJ_NAME)
RUNS_DIR := $(DFX_BUILD_DIR)/$(PROJ_NAME).runs
FULL_HWH := $(DFX_BUILD_DIR)/$(PROJ_NAME).gen/sources_1/bd/design_1/hw_handoff/design_1.hwh
FULL_EXP_BIT := $(RUNS_DIR)/impl_1/pwl_dfx_top.bit
FULL_SIGMOID_BIT := $(RUNS_DIR)/impl_config_sigmoid/pwl_dfx_top.bit
FULL_EXP_F16_BIT := $(RUNS_DIR)/impl_config_exp_f16/pwl_dfx_top.bit
FULL_SIGMOID_F16_BIT := $(RUNS_DIR)/impl_config_sigmoid_f16/pwl_dfx_top.bit
PARTIAL_EXP_BIT := $(RUNS_DIR)/impl_1/u_rp_rm_exp_partial.bit
PARTIAL_SIGMOID_BIT := $(RUNS_DIR)/impl_config_sigmoid/u_rp_rm_sigmoid_partial.bit
PARTIAL_EXP_F16_BIT := $(RUNS_DIR)/impl_config_exp_f16/u_rp_rm_exp_f16_partial.bit
PARTIAL_SIGMOID_F16_BIT := $(RUNS_DIR)/impl_config_sigmoid_f16/u_rp_rm_sigmoid_f16_partial.bit
DELIVERABLES_ROOT := $(ROOT_DIR)/deliverables/sw_pynq_pwl_dfx
DELIVERABLE_APP := $(DELIVERABLES_ROOT)/$(APP_NAME)
DELIVERABLE_README := $(DELIVERABLES_ROOT)/README.md
DELIVERABLE_FULL_EXP_BIT := $(DELIVERABLES_ROOT)/pwl_dfx_full_region_u_rp_rm_exp.bit
DELIVERABLE_FULL_EXP_HWH := $(DELIVERABLES_ROOT)/pwl_dfx_full_region_u_rp_rm_exp.hwh
DELIVERABLE_FULL_SIGMOID_BIT := $(DELIVERABLES_ROOT)/pwl_dfx_full_region_u_rp_rm_sigmoid.bit
DELIVERABLE_FULL_SIGMOID_HWH := $(DELIVERABLES_ROOT)/pwl_dfx_full_region_u_rp_rm_sigmoid.hwh
DELIVERABLE_FULL_EXP_F16_BIT := $(DELIVERABLES_ROOT)/pwl_dfx_full_region_u_rp_rm_exp_f16.bit
DELIVERABLE_FULL_EXP_F16_HWH := $(DELIVERABLES_ROOT)/pwl_dfx_full_region_u_rp_rm_exp_f16.hwh
DELIVERABLE_FULL_SIGMOID_F16_BIT := $(DELIVERABLES_ROOT)/pwl_dfx_full_region_u_rp_rm_sigmoid_f16.bit
DELIVERABLE_FULL_SIGMOID_F16_HWH := $(DELIVERABLES_ROOT)/pwl_dfx_full_region_u_rp_rm_sigmoid_f16.hwh
DELIVERABLE_PARTIAL_EXP_BIT := $(DELIVERABLES_ROOT)/pwl_dfx_partial_region_u_rp_rm_exp.bit
DELIVERABLE_PARTIAL_SIGMOID_BIT := $(DELIVERABLES_ROOT)/pwl_dfx_partial_region_u_rp_rm_sigmoid.bit
DELIVERABLE_PARTIAL_EXP_F16_BIT := $(DELIVERABLES_ROOT)/pwl_dfx_partial_region_u_rp_rm_exp_f16.bit
DELIVERABLE_PARTIAL_SIGMOID_F16_BIT := $(DELIVERABLES_ROOT)/pwl_dfx_partial_region_u_rp_rm_sigmoid_f16.bit

define resolve_partial_bit
$(or $(wildcard $(RUNS_DIR)/impl_config_$(1)/u_rp_rm_$(1)_partial.bit),$(wildcard $(RUNS_DIR)/impl_1/u_rp_rm_$(1)_partial.bit))
endef

define resolve_full_bit
$(or $(wildcard $(RUNS_DIR)/impl_config_$(1)/pwl_dfx_top.bit),$(if $(call resolve_partial_bit,$(1)),$(wildcard $(RUNS_DIR)/impl_1/pwl_dfx_top.bit)))
endef

FULL_BIT_exp := $(call resolve_full_bit,exp)
FULL_BIT_sigmoid := $(call resolve_full_bit,sigmoid)
FULL_BIT_exp_f16 := $(call resolve_full_bit,exp_f16)
FULL_BIT_sigmoid_f16 := $(call resolve_full_bit,sigmoid_f16)
PARTIAL_BIT_exp := $(call resolve_partial_bit,exp)
PARTIAL_BIT_sigmoid := $(call resolve_partial_bit,sigmoid)
PARTIAL_BIT_exp_f16 := $(call resolve_partial_bit,exp_f16)
PARTIAL_BIT_sigmoid_f16 := $(call resolve_partial_bit,sigmoid_f16)
DELIVERABLE_FULL_BIT_exp := $(DELIVERABLE_FULL_EXP_BIT)
DELIVERABLE_FULL_BIT_sigmoid := $(DELIVERABLE_FULL_SIGMOID_BIT)
DELIVERABLE_FULL_BIT_exp_f16 := $(DELIVERABLE_FULL_EXP_F16_BIT)
DELIVERABLE_FULL_BIT_sigmoid_f16 := $(DELIVERABLE_FULL_SIGMOID_F16_BIT)
DELIVERABLE_FULL_HWH_exp := $(DELIVERABLE_FULL_EXP_HWH)
DELIVERABLE_FULL_HWH_sigmoid := $(DELIVERABLE_FULL_SIGMOID_HWH)
DELIVERABLE_FULL_HWH_exp_f16 := $(DELIVERABLE_FULL_EXP_F16_HWH)
DELIVERABLE_FULL_HWH_sigmoid_f16 := $(DELIVERABLE_FULL_SIGMOID_F16_HWH)
DELIVERABLE_PARTIAL_BIT_exp := $(DELIVERABLE_PARTIAL_EXP_BIT)
DELIVERABLE_PARTIAL_BIT_sigmoid := $(DELIVERABLE_PARTIAL_SIGMOID_BIT)
DELIVERABLE_PARTIAL_BIT_exp_f16 := $(DELIVERABLE_PARTIAL_EXP_F16_BIT)
DELIVERABLE_PARTIAL_BIT_sigmoid_f16 := $(DELIVERABLE_PARTIAL_SIGMOID_F16_BIT)

.PHONY: help check build deliver-check deliver clean \
	sw-pynq-pwl-dfx-check sw-pynq-pwl-dfx-build sw-pynq-pwl-dfx-deliver-check \
	sw-pynq-pwl-dfx-deliver sw-pynq-pwl-dfx-clean

help:
	@echo "PWL DFX PYNQ software targets:"
	@echo "  make -C SW/pwl_dfx_pynq build PART=$(PART)"
	@echo "  make -C SW/pwl_dfx_pynq deliver PART=$(PART) RMS=$(RMS)"
	@echo "  make -C SW/pwl_dfx_pynq clean"
	@echo "Supported RMs: $(SUPPORTED_RMS)"
	@echo "Example subset: make -C SW/pwl_dfx_pynq deliver PART=$(PART) RMS=exp_f16,sigmoid_f16"

check: sw-pynq-pwl-dfx-check

build: sw-pynq-pwl-dfx-build

deliver-check: sw-pynq-pwl-dfx-deliver-check

deliver: sw-pynq-pwl-dfx-deliver

clean: sw-pynq-pwl-dfx-clean

sw-pynq-pwl-dfx-check:
	@command -v "$(PYTHON)" >/dev/null 2>&1 || { echo "ERROR: Python interpreter not found: $(PYTHON)"; exit 1; }
	@test -f "$(APP_SRC)" || { echo "ERROR: App source not found: $(APP_SRC)"; exit 1; }
	@test -f "$(README_SRC)" || { echo "ERROR: README source not found: $(README_SRC)"; exit 1; }
	@mkdir -p "$(BUILD_ROOT)"
	@echo "Python: $$(command -v "$(PYTHON)")"
	@echo "App source: $(APP_SRC)"
	@echo "Staged app: $(STAGED_APP)"

sw-pynq-pwl-dfx-build: sw-pynq-pwl-dfx-check
	"$(PYTHON)" -m py_compile "$(APP_SRC)"
	@rm -f "$(STAGED_APP)"
	install -m 755 "$(APP_SRC)" "$(STAGED_APP)"
	@echo "Staged PWL DFX PYNQ app at $(STAGED_APP)"

sw-pynq-pwl-dfx-deliver-check:
	@test -f "$(STAGED_APP)" || { \
		echo "ERROR: Staged PYNQ app not found: $(STAGED_APP)"; \
		echo "Run 'make -C SW/pwl_dfx_pynq build' first or use 'make -C SW/pwl_dfx_pynq deliver'."; \
		exit 1; \
	}
	@test -f "$(FULL_HWH)" || { \
		echo "ERROR: Full DFX HWH metadata not found: $(FULL_HWH)"; \
		echo "Run 'make -C scripts/pwl_dfx bitstream-xsa PART=$(PART)' first."; \
		exit 1; \
	}
	@for rm in $(RMS_LIST); do \
		case "$$rm" in \
			exp) full_bit="$(FULL_BIT_exp)"; partial_bit="$(PARTIAL_BIT_exp)" ;; \
			sigmoid) full_bit="$(FULL_BIT_sigmoid)"; partial_bit="$(PARTIAL_BIT_sigmoid)" ;; \
			exp_f16) full_bit="$(FULL_BIT_exp_f16)"; partial_bit="$(PARTIAL_BIT_exp_f16)" ;; \
			sigmoid_f16) full_bit="$(FULL_BIT_sigmoid_f16)"; partial_bit="$(PARTIAL_BIT_sigmoid_f16)" ;; \
		esac; \
		test -f "$$full_bit" || { \
			echo "ERROR: Full DFX bitstream not found for RM '$$rm': $$full_bit"; \
			echo "Run 'make -C scripts/pwl_dfx bitstream-xsa PART=$(PART)' first."; \
			exit 1; \
		}; \
		test -f "$$partial_bit" || { \
			echo "ERROR: Partial DFX bitstream not found for RM '$$rm': $$partial_bit"; \
			echo "Run 'make -C scripts/pwl_dfx bitstream-xsa PART=$(PART)' first."; \
			exit 1; \
		}; \
	done
	@mkdir -p "$(DELIVERABLES_ROOT)"
	@echo "Deliverables root: $(DELIVERABLES_ROOT)"
	@echo "Selected RMs: $(RMS_LIST)"
	@echo "Full HWH: $(FULL_HWH)"
	@for rm in $(RMS_LIST); do \
		case "$$rm" in \
			exp) full_bit="$(FULL_BIT_exp)"; partial_bit="$(PARTIAL_BIT_exp)" ;; \
			sigmoid) full_bit="$(FULL_BIT_sigmoid)"; partial_bit="$(PARTIAL_BIT_sigmoid)" ;; \
			exp_f16) full_bit="$(FULL_BIT_exp_f16)"; partial_bit="$(PARTIAL_BIT_exp_f16)" ;; \
			sigmoid_f16) full_bit="$(FULL_BIT_sigmoid_f16)"; partial_bit="$(PARTIAL_BIT_sigmoid_f16)" ;; \
		esac; \
		echo "Selected RM ($$rm) full bitstream: $$full_bit"; \
		echo "Selected RM ($$rm) partial bitstream: $$partial_bit"; \
	done

sw-pynq-pwl-dfx-deliver: sw-pynq-pwl-dfx-build sw-pynq-pwl-dfx-deliver-check
	install -m 755 "$(STAGED_APP)" "$(DELIVERABLE_APP)"
	install -m 644 "$(README_SRC)" "$(DELIVERABLE_README)"
	@for rm in $(RMS_LIST); do \
		case "$$rm" in \
			exp) \
				full_bit="$(FULL_BIT_exp)"; \
				deliver_full_bit="$(DELIVERABLE_FULL_BIT_exp)"; \
				deliver_full_hwh="$(DELIVERABLE_FULL_HWH_exp)"; \
				partial_bit="$(PARTIAL_BIT_exp)"; \
				deliver_partial_bit="$(DELIVERABLE_PARTIAL_BIT_exp)" ;; \
			sigmoid) \
				full_bit="$(FULL_BIT_sigmoid)"; \
				deliver_full_bit="$(DELIVERABLE_FULL_BIT_sigmoid)"; \
				deliver_full_hwh="$(DELIVERABLE_FULL_HWH_sigmoid)"; \
				partial_bit="$(PARTIAL_BIT_sigmoid)"; \
				deliver_partial_bit="$(DELIVERABLE_PARTIAL_BIT_sigmoid)" ;; \
			exp_f16) \
				full_bit="$(FULL_BIT_exp_f16)"; \
				deliver_full_bit="$(DELIVERABLE_FULL_BIT_exp_f16)"; \
				deliver_full_hwh="$(DELIVERABLE_FULL_HWH_exp_f16)"; \
				partial_bit="$(PARTIAL_BIT_exp_f16)"; \
				deliver_partial_bit="$(DELIVERABLE_PARTIAL_BIT_exp_f16)" ;; \
			sigmoid_f16) \
				full_bit="$(FULL_BIT_sigmoid_f16)"; \
				deliver_full_bit="$(DELIVERABLE_FULL_BIT_sigmoid_f16)"; \
				deliver_full_hwh="$(DELIVERABLE_FULL_HWH_sigmoid_f16)"; \
				partial_bit="$(PARTIAL_BIT_sigmoid_f16)"; \
				deliver_partial_bit="$(DELIVERABLE_PARTIAL_BIT_sigmoid_f16)" ;; \
		esac; \
		install -m 644 "$$full_bit" "$$deliver_full_bit"; \
		install -m 644 "$(FULL_HWH)" "$$deliver_full_hwh"; \
		install -m 644 "$$partial_bit" "$$deliver_partial_bit"; \
	done
	@echo "Copied app to $(DELIVERABLE_APP)"
	@echo "Copied README to $(DELIVERABLE_README)"
	@for rm in $(RMS_LIST); do \
		case "$$rm" in \
			exp) \
				deliver_full_bit="$(DELIVERABLE_FULL_BIT_exp)"; \
				deliver_full_hwh="$(DELIVERABLE_FULL_HWH_exp)"; \
				deliver_partial_bit="$(DELIVERABLE_PARTIAL_BIT_exp)" ;; \
			sigmoid) \
				deliver_full_bit="$(DELIVERABLE_FULL_BIT_sigmoid)"; \
				deliver_full_hwh="$(DELIVERABLE_FULL_HWH_sigmoid)"; \
				deliver_partial_bit="$(DELIVERABLE_PARTIAL_BIT_sigmoid)" ;; \
			exp_f16) \
				deliver_full_bit="$(DELIVERABLE_FULL_BIT_exp_f16)"; \
				deliver_full_hwh="$(DELIVERABLE_FULL_HWH_exp_f16)"; \
				deliver_partial_bit="$(DELIVERABLE_PARTIAL_BIT_exp_f16)" ;; \
			sigmoid_f16) \
				deliver_full_bit="$(DELIVERABLE_FULL_BIT_sigmoid_f16)"; \
				deliver_full_hwh="$(DELIVERABLE_FULL_HWH_sigmoid_f16)"; \
				deliver_partial_bit="$(DELIVERABLE_PARTIAL_BIT_sigmoid_f16)" ;; \
		esac; \
		echo "Copied full $$rm overlay to $$deliver_full_bit"; \
		echo "Copied full $$rm metadata to $$deliver_full_hwh"; \
		echo "Copied partial $$rm overlay to $$deliver_partial_bit"; \
	done

sw-pynq-pwl-dfx-clean:
	rm -rf "$(BUILD_ROOT)"
	rm -rf "$(APP_DIR)/app/__pycache__"
