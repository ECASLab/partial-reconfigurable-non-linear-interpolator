SHELL := /bin/bash

CXX ?= g++
PKG_CONFIG ?= pkg-config
RUNNER ?= sudo -E

APP_SRC ?= $(CURDIR)/example_individual_cynq.cpp
APP_NAME ?= individual_cynq
BIN_FILE ?= $(CURDIR)/$(APP_NAME)

DUT ?= mul
DMA_BASE ?= 0x80000000
BIT_FILE ?= $(CURDIR)/$(DUT)/design_1_wrapper.bit
XCLBIN_FILE ?= /usr/local/share/pynq-venv/lib/python3.10/site-packages/pynq/pl_server/default.xclbin
RUN_ARGS ?=

PKG_CONFIG_PATH_EFFECTIVE ?= /usr/lib/pkgconfig:/usr/local/lib/pkgconfig:/usr/lib/aarch64-linux-gnu/pkgconfig:/usr/local/lib/aarch64-linux-gnu/pkgconfig:/usr/lib/x86_64-linux-gnu/pkgconfig:/usr/local/lib/x86_64-linux-gnu/pkgconfig:/opt/xilinx/xrt/lib/pkgconfig:$(PKG_CONFIG_PATH)
PKG_CONFIG_ENV = PKG_CONFIG_PATH='$(PKG_CONFIG_PATH_EFFECTIVE)'

CYNQ_CFLAGS := $(shell $(PKG_CONFIG_ENV) $(PKG_CONFIG) --cflags cynq 2>/dev/null)
CYNQ_LIBS := $(shell $(PKG_CONFIG_ENV) $(PKG_CONFIG) --libs cynq 2>/dev/null)

CPPFLAGS += $(CYNQ_CFLAGS)
CXXFLAGS += -std=c++17 -O2 -Wall -Wextra -Wpedantic
LDLIBS += $(CYNQ_LIBS) -luuid -pthread

.PHONY: help check build run run-no-program test test-no-program clean

help:
	@echo "Standalone CYNQ target Makefile"
	@echo "Expected layout:"
	@echo "  ./Makefile"
	@echo "  ./example_individual_cynq.cpp"
	@echo "  ./mul/design_1_wrapper.bit"
	@echo "  ./xor/design_1_wrapper.bit"
	@echo "  make build"
	@echo "  make run"
	@echo "  make run-no-program"
	@echo "Variables you can override:"
	@echo "  APP_SRC=$(APP_SRC)"
	@echo "  APP_NAME=$(APP_NAME)"
	@echo "  BIN_FILE=$(BIN_FILE)"
	@echo "  DUT=$(DUT)"
	@echo "  DMA_BASE=$(DMA_BASE)"
	@echo "  BIT_FILE=$(BIT_FILE)"
	@echo "  XCLBIN_FILE=$(XCLBIN_FILE)"
	@echo "  RUNNER=$(RUNNER)"
	@echo "  RUN_ARGS=$(RUN_ARGS)"

check:
	@command -v "$(CXX)" >/dev/null 2>&1 || { echo "ERROR: C++ compiler not found: $(CXX)"; exit 1; }
	@test -f "$(APP_SRC)" || { echo "ERROR: App source not found: $(APP_SRC)"; exit 1; }
	@$(PKG_CONFIG_ENV) $(PKG_CONFIG) --exists cynq || { \
		echo "ERROR: pkg-config could not resolve cynq."; \
		echo "Current PKG_CONFIG_PATH: $(PKG_CONFIG_PATH_EFFECTIVE)"; \
		exit 1; \
	}
	@test -n "$(CYNQ_CFLAGS)" || { echo "ERROR: Could not query cynq compiler flags."; exit 1; }
	@test -n "$(CYNQ_LIBS)" || { echo "ERROR: Could not query cynq linker flags."; exit 1; }
	@echo "Compiler: $$(command -v "$(CXX)")"
	@echo "Source: $(APP_SRC)"
	@echo "Binary: $(BIN_FILE)"
	@echo "DUT: $(DUT)"
	@echo "DMA base: $(DMA_BASE)"
	@echo "Default xclbin: $(XCLBIN_FILE)"

build: check
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) \
		"$(APP_SRC)" \
		-o "$(BIN_FILE)" \
		$(LDLIBS)
	@echo "Built $(BIN_FILE)"

run: build
	@test -f "$(BIT_FILE)" || { echo "ERROR: Bitstream not found: $(BIT_FILE)"; exit 1; }
	@test -f "$(XCLBIN_FILE)" || { echo "ERROR: XCLBIN not found: $(XCLBIN_FILE)"; exit 1; }
	$(RUNNER) "$(BIN_FILE)" \
		--dut "$(DUT)" \
		--dma-base "$(DMA_BASE)" \
		--bitstream "$(BIT_FILE)" \
		--xclbin "$(XCLBIN_FILE)" \
		$(RUN_ARGS)

run-no-program: build
	@test -f "$(XCLBIN_FILE)" || { echo "ERROR: XCLBIN not found: $(XCLBIN_FILE)"; exit 1; }
	$(RUNNER) "$(BIN_FILE)" \
		--dut "$(DUT)" \
		--dma-base "$(DMA_BASE)" \
		--no-program \
		--xclbin "$(XCLBIN_FILE)" \
		$(RUN_ARGS)

test: run

test-no-program: run-no-program

clean:
	rm -f "$(BIN_FILE)"
