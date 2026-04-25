SHELL := /bin/bash

XVLOG ?= xvlog
XELAB ?= xelab

VERIF_DIR := .
VERIF_ROOT := $(abspath $(VERIF_DIR))
PROJECT_ROOT := $(abspath $(VERIF_DIR)/..)
SRC_DIR := $(PROJECT_ROOT)/srcs
BUILD_DIR := $(PROJECT_ROOT)/build
DUT ?= mul
ifeq ($(DUT),mul)
SIM_DEFINES := DUT_MODEL_MUL
else ifeq ($(DUT),xor)
SIM_DEFINES := DUT_MODEL_XOR
else
$(error Unsupported DUT '$(DUT)'. Supported DUTs: mul xor)
endif
XVLOG_DEFINE_FLAGS := $(foreach def,$(SIM_DEFINES),-d $(def))
FILELIST := $(VERIF_ROOT)/filelist_$(DUT).f
SIM_TOP := dut_64x64_axis_wrapper_tb
SIM_TESTCASE ?= smoke
SIM_TESTCASE_ID ?= 0
SIM_ROOT_DIR := $(BUILD_DIR)/sim/$(DUT)
SIM_WORK_DIR := $(SIM_ROOT_DIR)/work
SIM_LOG_DIR := $(SIM_ROOT_DIR)/logs
SIM_LIBS := xilinx_vip axi4stream_vip_v1_1_15
SIM_LIB_FLAGS := $(foreach lib,$(SIM_LIBS),-L $(lib))

.PHONY: help sim-check sim-prepare sim-compile sim-run sim sim-backpressure sim-clean sim-clean-all

help:
	@echo "Verification targets:"
	@echo "  make -C verif sim DUT=mul              - Compile and run the smoke test"
	@echo "  make -C verif sim DUT=xor              - Compile and run the smoke test"
	@echo "  make -C verif sim-backpressure DUT=mul - Compile and run the backpressure test"
	@echo "  make -C verif sim-backpressure DUT=xor - Compile and run the backpressure test"
	@echo "  make -C verif sim-clean DUT=mul        - Remove XSim outputs from $(BUILD_DIR)/sim/mul"
	@echo "  make -C verif sim-clean DUT=xor        - Remove XSim outputs from $(BUILD_DIR)/sim/xor"
	@echo "  make -C verif sim-clean-all            - Remove all XSim outputs from $(BUILD_DIR)/sim"

sim-check:
	@command -v "$(XVLOG)" >/dev/null 2>&1 || { echo "ERROR: xvlog not found in PATH"; exit 1; }
	@command -v "$(XELAB)" >/dev/null 2>&1 || { echo "ERROR: xelab not found in PATH"; exit 1; }
	@test -f "$(FILELIST)" || { echo "ERROR: File list not found: $(FILELIST)"; exit 1; }
	@mkdir -p "$(SIM_WORK_DIR)" "$(SIM_LOG_DIR)"
	@echo "xvlog: $$(command -v "$(XVLOG)")"
	@echo "xelab: $$(command -v "$(XELAB)")"
	@echo "DUT: $(DUT)"
	@echo "Sim work dir: $(SIM_WORK_DIR)"
	@echo "Filelist: $(FILELIST)"

sim-prepare: sim-check
	ln -sfn "$(SRC_DIR)" "$(SIM_WORK_DIR)/srcs"
	ln -sfn "$(VERIF_ROOT)" "$(SIM_WORK_DIR)/verif"

sim-compile: sim-prepare
	cd "$(SIM_WORK_DIR)" && \
	"$(XVLOG)" --sv $(SIM_LIB_FLAGS) $(XVLOG_DEFINE_FLAGS) -f "./verif/filelist_$(DUT).f" \
		-log "$(abspath $(SIM_LOG_DIR))/xvlog.log"

sim-run: sim-compile
	cd "$(SIM_WORK_DIR)" && \
	"$(XELAB)" $(SIM_LIB_FLAGS) work.$(SIM_TOP) \
		--generic_top "TESTCASE_ID=$(SIM_TESTCASE_ID)" \
		-s "$(SIM_TOP)_standalone_$(SIM_TESTCASE)" \
		-a \
		-log "$(abspath $(SIM_LOG_DIR))/xelab_$(SIM_TESTCASE).log"
	cd "$(SIM_WORK_DIR)" && \
	./axsim.sh | tee "$(abspath $(SIM_LOG_DIR))/axsim_$(SIM_TESTCASE).log"
	@grep -q "\[TB\] TESTCASE=$(SIM_TESTCASE) passed" "$(abspath $(SIM_LOG_DIR))/axsim_$(SIM_TESTCASE).log" || { \
		echo "ERROR: Simulation did not report a passing $(SIM_TESTCASE) test"; \
		exit 1; \
	}

sim: SIM_TESTCASE := smoke
sim: SIM_TESTCASE_ID := 0
sim: sim-run

sim-backpressure: SIM_TESTCASE := backpressure
sim-backpressure: SIM_TESTCASE_ID := 1
sim-backpressure: sim-run

sim-clean:
	rm -rf "$(SIM_ROOT_DIR)"

sim-clean-all:
	rm -rf "$(BUILD_DIR)/sim"
