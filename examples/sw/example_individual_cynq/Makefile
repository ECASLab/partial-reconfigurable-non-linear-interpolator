SHELL := /bin/bash

CXX ?= g++
PKG_CONFIG ?= pkg-config
XRT_ROOT ?= /opt/xilinx/xrt
CYNQ_PKG ?= cynq
CYNQ_PKGCONFIG_DIR ?= /usr/local/lib/x86_64-linux-gnu/pkgconfig
XRT_PKGCONFIG_DIR ?= $(XRT_ROOT)/lib/pkgconfig
PART ?= xck26-sfvc784-2LV-c
DUT ?= mul
SUPPORTED_DUTS := mul xor

PROJECT_DIR := ../..
SW_DIR := $(PROJECT_DIR)/sw/example_individual_cynq
APP_SRC := $(SW_DIR)/app/main.cpp
BUILD_ROOT := $(PROJECT_DIR)/build/sw_cynq
APP_NAME := individual_cynq
BIN_FILE := $(BUILD_ROOT)/$(APP_NAME)
PART_TAG := $(subst .,_,$(subst -,_,$(PART)))
DELIVERABLES_ROOT := $(PROJECT_DIR)/deliverables/sw_cynq
DELIVERABLE_SRC := $(DELIVERABLES_ROOT)/example_individual_cynq.cpp
DELIVERABLE_BIN := $(DELIVERABLES_ROOT)/$(APP_NAME)

PKG_CONFIG_PATH_EFFECTIVE := $(XRT_PKGCONFIG_DIR):$(CYNQ_PKGCONFIG_DIR):$(PKG_CONFIG_PATH)
PKG_CONFIG_ENV = PKG_CONFIG_PATH='$(PKG_CONFIG_PATH_EFFECTIVE)'

CYNQ_CFLAGS := $(shell $(PKG_CONFIG_ENV) $(PKG_CONFIG) --cflags $(CYNQ_PKG) 2>/dev/null)
CYNQ_LIBS := $(shell $(PKG_CONFIG_ENV) $(PKG_CONFIG) --libs $(CYNQ_PKG) 2>/dev/null)
CYNQ_INCLUDE_DIR := $(shell $(PKG_CONFIG_ENV) $(PKG_CONFIG) --variable=includedir $(CYNQ_PKG) 2>/dev/null)
CYNQ_LIB_DIR := $(shell $(PKG_CONFIG_ENV) $(PKG_CONFIG) --variable=libdir $(CYNQ_PKG) 2>/dev/null)

CPPFLAGS += $(CYNQ_CFLAGS)
CXXFLAGS += -std=c++17 -O2 -Wall -Wextra -Wpedantic
LDFLAGS += -Wl,-rpath,$(CYNQ_LIB_DIR) -Wl,-rpath,$(XRT_ROOT)/lib
LDLIBS += $(CYNQ_LIBS) -luuid -pthread

.PHONY: sw-cynq-check sw-cynq-build sw-cynq-deliver-check sw-cynq-deliver sw-cynq-clean

sw-cynq-check:
	@test -f "$(APP_SRC)" || { echo "ERROR: App source not found: $(APP_SRC)"; exit 1; }
	@$(PKG_CONFIG_ENV) $(PKG_CONFIG) --exists $(CYNQ_PKG) || { \
		echo "ERROR: pkg-config could not resolve $(CYNQ_PKG)."; \
		echo "Set PKG_CONFIG_PATH to include $(XRT_PKGCONFIG_DIR) and $(CYNQ_PKGCONFIG_DIR), or override those variables."; \
		exit 1; \
	}
	@test -n "$(CYNQ_INCLUDE_DIR)" || { echo "ERROR: Could not query $(CYNQ_PKG) include dir."; exit 1; }
	@test -n "$(CYNQ_LIB_DIR)" || { echo "ERROR: Could not query $(CYNQ_PKG) lib dir."; exit 1; }
	@test -f "$(CYNQ_INCLUDE_DIR)/cynq/datamover.hpp" || { echo "ERROR: Missing installed header: $(CYNQ_INCLUDE_DIR)/cynq/datamover.hpp"; exit 1; }
	@test -f "$(CYNQ_INCLUDE_DIR)/cynq/enums.hpp" || { echo "ERROR: Missing installed header: $(CYNQ_INCLUDE_DIR)/cynq/enums.hpp"; exit 1; }
	@test -f "$(CYNQ_INCLUDE_DIR)/cynq/hardware.hpp" || { echo "ERROR: Missing installed header: $(CYNQ_INCLUDE_DIR)/cynq/hardware.hpp"; exit 1; }
	@test -f "$(CYNQ_INCLUDE_DIR)/cynq/memory.hpp" || { echo "ERROR: Missing installed header: $(CYNQ_INCLUDE_DIR)/cynq/memory.hpp"; exit 1; }
	@test -f "$(CYNQ_INCLUDE_DIR)/cynq/status.hpp" || { echo "ERROR: Missing installed header: $(CYNQ_INCLUDE_DIR)/cynq/status.hpp"; exit 1; }
	@mkdir -p "$(BUILD_ROOT)"
	@echo "Compiler: $(CXX)"
	@echo "Binary: $(BIN_FILE)"
	@echo "PKG_CONFIG_PATH: $(PKG_CONFIG_PATH_EFFECTIVE)"
	@echo "CYNQ package: $(CYNQ_PKG)"
	@echo "CYNQ include dir: $(CYNQ_INCLUDE_DIR)"
	@echo "CYNQ lib dir: $(CYNQ_LIB_DIR)"

sw-cynq-build: sw-cynq-check
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) \
		$(APP_SRC) \
		-o "$(BIN_FILE)" \
		$(LDFLAGS) $(LDLIBS)

sw-cynq-deliver-check:
	@test -f "$(BIN_FILE)" || { \
		echo "ERROR: Compiled CYNQ app not found: $(BIN_FILE)"; \
		echo "Run 'make sw-cynq-build' first or use 'make sw-cynq-deliver' to build and copy in one step."; \
		exit 1; \
	}
	@mkdir -p "$(DELIVERABLES_ROOT)"
	@echo "Deliverables root: $(DELIVERABLES_ROOT)"
	@echo "Source to copy: $(APP_SRC)"
	@echo "Binary source: $(BIN_FILE)"
	@found=0; \
	for dut in $(SUPPORTED_DUTS); do \
		bit_file="$(PROJECT_DIR)/build/vivado/$$dut/$(PART_TAG)/my_proj_$${dut}_$(PART_TAG)/my_proj_$${dut}_$(PART_TAG).runs/impl_1/design_1_wrapper.bit"; \
		if [ -f "$$bit_file" ]; then \
			found=1; \
			echo "Bitstream source ($$dut): $$bit_file"; \
		else \
			echo "Bitstream source ($$dut): missing"; \
		fi; \
	done; \
	test "$$found" -eq 1 || { \
		echo "ERROR: No DUT bitstreams were found for $(SUPPORTED_DUTS)."; \
		exit 1; \
	}

sw-cynq-deliver: sw-cynq-build sw-cynq-deliver-check
	install -m 644 "$(APP_SRC)" "$(DELIVERABLE_SRC)"
	install -m 755 "$(BIN_FILE)" "$(DELIVERABLE_BIN)"
	@find "$(DELIVERABLES_ROOT)" -mindepth 2 -maxdepth 2 -type f -name "$(APP_NAME)" -delete
	@for dut in $(SUPPORTED_DUTS); do \
		dut_dir="$(DELIVERABLES_ROOT)/$$dut"; \
		bit_file="$(PROJECT_DIR)/build/vivado/$$dut/$(PART_TAG)/my_proj_$${dut}_$(PART_TAG)/my_proj_$${dut}_$(PART_TAG).runs/impl_1/design_1_wrapper.bit"; \
		mkdir -p "$$dut_dir"; \
		rm -f "$$dut_dir/design_1_wrapper.bit"; \
		if [ -f "$$bit_file" ]; then \
			install -m 644 "$$bit_file" "$$dut_dir/design_1_wrapper.bit"; \
			echo "Copied bitstream ($$dut) to $$dut_dir/design_1_wrapper.bit"; \
		else \
			echo "Skipped bitstream ($$dut): source not found"; \
		fi; \
	done
	@echo "Copied source to $(DELIVERABLE_SRC)"
	@echo "Copied binary to $(DELIVERABLE_BIN)"

sw-cynq-clean:
	rm -f "$(BIN_FILE)"
