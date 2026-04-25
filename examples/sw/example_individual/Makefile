SHELL := /bin/bash

XSCT ?= xsct
BOOTGEN ?= bootgen

PROJECT_DIR := ../..
SW_DIR := $(PROJECT_DIR)/sw/example_individual
BUILD_ROOT := $(PROJECT_DIR)/build/sw
APP_SRC := $(SW_DIR)/app/main.c
XSCT_BUILD_SCRIPT := $(SW_DIR)/scripts/build_baremetal_app.tcl
XSCT_RUN_SCRIPT := $(SW_DIR)/scripts/run_jtag.tcl
XSCT_SD_BOOT_SCRIPT := $(PROJECT_DIR)/sw/scripts/package_sd_boot.tcl

DUT ?= mul
PART_K26 := xck26-sfvc784-2LV-c
PART_U250 := xcu250-figd2104-2L-e
SUPPORTED_PARTS := $(PART_K26) $(PART_U250)
PART ?= $(PART_K26)

PART_TAG := $(subst .,_,$(subst -,_,$(PART)))
WORKSPACE := $(BUILD_ROOT)/$(DUT)/$(PART_TAG)/workspace
LOG_DIR := $(BUILD_ROOT)/$(DUT)/$(PART_TAG)/logs
PLATFORM_STAMP := $(BUILD_ROOT)/$(DUT)/$(PART_TAG)/.platform.stamp
APP_STAMP := $(BUILD_ROOT)/$(DUT)/$(PART_TAG)/.app.stamp
BUILD_STAMP := $(BUILD_ROOT)/$(DUT)/$(PART_TAG)/.build.stamp
SD_BOOT_STAMP := $(BUILD_ROOT)/$(DUT)/$(PART_TAG)/.sd_boot.stamp

PLATFORM_NAME := dut64_platform
APP_NAME := dut64_dma_smoke

XSA_FILE := $(PROJECT_DIR)/build/vivado/$(DUT)/$(PART_TAG)/export/my_proj_$(DUT)_$(PART_TAG).xsa
BIT_FILE := $(PROJECT_DIR)/build/vivado/$(DUT)/$(PART_TAG)/my_proj_$(DUT)_$(PART_TAG)/my_proj_$(DUT)_$(PART_TAG).runs/impl_1/design_1_wrapper.bit
PSU_INIT_TCL := $(WORKSPACE)/$(PLATFORM_NAME)/hw/psu_init.tcl
ELF_FILE := $(WORKSPACE)/$(APP_NAME)/Debug/$(APP_NAME).elf
SD_CARD_DIR := $(BUILD_ROOT)/$(DUT)/$(PART_TAG)/sd_card
BOOT_BIN_FILE := $(SD_CARD_DIR)/BOOT.BIN

ifneq ($(filter $(PART),$(SUPPORTED_PARTS)),$(PART))
$(error Unsupported PART '$(PART)'. Supported PARTs: $(SUPPORTED_PARTS))
endif

.PHONY: sw-check sw-platform sw-app sw-build sw-run-jtag sw-sd-boot sw-clean

sw-check:
	@command -v "$(XSCT)" >/dev/null 2>&1 || { echo "ERROR: xsct not found in PATH"; exit 1; }
	@test -f "$(XSCT_BUILD_SCRIPT)" || { echo "ERROR: XSCT script not found: $(XSCT_BUILD_SCRIPT)"; exit 1; }
	@test -f "$(XSCT_RUN_SCRIPT)" || { echo "ERROR: XSCT script not found: $(XSCT_RUN_SCRIPT)"; exit 1; }
	@test -f "$(XSCT_SD_BOOT_SCRIPT)" || { echo "ERROR: XSCT script not found: $(XSCT_SD_BOOT_SCRIPT)"; exit 1; }
	@test -f "$(APP_SRC)" || { echo "ERROR: App source not found: $(APP_SRC)"; exit 1; }
	@test -f "$(XSA_FILE)" || { echo "ERROR: XSA not found: $(XSA_FILE). Run 'make bitstream-xsa DUT=$(DUT) PART=$(PART)' first."; exit 1; }
	@mkdir -p "$(LOG_DIR)"
	@echo "XSCT: $$(command -v "$(XSCT)")"
	@echo "XSA: $(XSA_FILE)"
	@echo "Workspace: $(WORKSPACE)"

sw-platform: sw-check $(PLATFORM_STAMP)

$(PLATFORM_STAMP): $(XSCT_BUILD_SCRIPT) $(XSA_FILE)
	@mkdir -p "$(LOG_DIR)"
	"$(XSCT)" "$(XSCT_BUILD_SCRIPT)" platform "$(DUT)" "$(PART)" "$(XSA_FILE)" "$(WORKSPACE)" "$(APP_SRC)" \
		2>&1 | tee "$(LOG_DIR)/sw_platform.log"
	@touch "$@"

sw-app: sw-check $(APP_STAMP)

$(APP_STAMP): $(PLATFORM_STAMP) $(XSCT_BUILD_SCRIPT) $(APP_SRC)
	@mkdir -p "$(LOG_DIR)"
	"$(XSCT)" "$(XSCT_BUILD_SCRIPT)" app "$(DUT)" "$(PART)" "$(XSA_FILE)" "$(WORKSPACE)" "$(APP_SRC)" \
		2>&1 | tee "$(LOG_DIR)/sw_app.log"
	@touch "$@"

sw-build: sw-check $(BUILD_STAMP)

$(BUILD_STAMP): $(APP_STAMP) $(XSCT_BUILD_SCRIPT) $(APP_SRC)
	@mkdir -p "$(LOG_DIR)"
	"$(XSCT)" "$(XSCT_BUILD_SCRIPT)" build "$(DUT)" "$(PART)" "$(XSA_FILE)" "$(WORKSPACE)" "$(APP_SRC)" \
		2>&1 | tee "$(LOG_DIR)/sw_build.log"
	@test -f "$(ELF_FILE)" || { echo "ERROR: ELF not found after build: $(ELF_FILE)"; exit 1; }
	@touch "$@"

sw-run-jtag: sw-check $(BUILD_STAMP)
	@test -f "$(BIT_FILE)" || { echo "ERROR: Bitstream not found: $(BIT_FILE). Run 'make bitstream-xsa DUT=$(DUT) PART=$(PART)' first."; exit 1; }
	@test -f "$(PSU_INIT_TCL)" || { echo "ERROR: psu_init.tcl not found: $(PSU_INIT_TCL)"; exit 1; }
	@test -f "$(ELF_FILE)" || { echo "ERROR: ELF not found: $(ELF_FILE)"; exit 1; }
	@mkdir -p "$(LOG_DIR)"
	"$(XSCT)" "$(XSCT_RUN_SCRIPT)" "$(BIT_FILE)" "$(PSU_INIT_TCL)" "$(ELF_FILE)" \
		2>&1 | tee "$(LOG_DIR)/sw_run_jtag.log"

sw-sd-boot: sw-check $(SD_BOOT_STAMP)

$(SD_BOOT_STAMP): $(BUILD_STAMP) $(XSCT_SD_BOOT_SCRIPT) $(BIT_FILE)
	@command -v "$(BOOTGEN)" >/dev/null 2>&1 || { echo "ERROR: bootgen not found in PATH"; exit 1; }
	@mkdir -p "$(LOG_DIR)"
	"$(XSCT)" "$(XSCT_SD_BOOT_SCRIPT)" "$(DUT)" "$(PART)" "$(WORKSPACE)" "$(PLATFORM_NAME)" "$(APP_NAME)" "$(BIT_FILE)" "$(SD_CARD_DIR)" "$(BOOTGEN)" \
		2>&1 | tee "$(LOG_DIR)/sw_sd_boot.log"
	@test -f "$(BOOT_BIN_FILE)" || { echo "ERROR: BOOT.BIN not found after SD packaging: $(BOOT_BIN_FILE)"; exit 1; }
	@touch "$@"

sw-clean:
	rm -rf "$(BUILD_ROOT)/$(DUT)/$(PART_TAG)"
