# Directories
PY_DIR      := ../Coeff_Gen
HLS_DIR     := .
TB_DIR      := ./tb
BUILD_DIR   := ./build
BUILD_CPP   := $(BUILD_DIR)/cpp
BUILD_VITIS := $(BUILD_DIR)/vitis_hls
VITIS_HLS_INCLUDE ?= $(firstword $(wildcard /tools/Xilinx/Vitis_HLS/*/include))

# Configuration
PWL_MODE ?= uniform
PWL_FUNCTION ?= exponential
PWL_PRECISION ?= float32

ifeq ($(PWL_MODE),uniform)
  PWL_MODE_DEF := -DPWL_UNIFORM
  PWL_MODE_ENV := PWL_UNIFORM
else ifeq ($(PWL_MODE),nonuniform)
  PWL_MODE_DEF := -DPWL_NONUNIFORM
  PWL_MODE_ENV := PWL_NONUNIFORM
else
  $(error PWL_MODE must be uniform or nonuniform)
endif

ifeq ($(PWL_FUNCTION),exponential)
  PWL_FUNC_DEF := -DPWL_FUNCTION_EXPONENTIAL
  PWL_FUNC_ENV := PWL_FUNCTION_EXPONENTIAL
else ifeq ($(PWL_FUNCTION),sigmoid)
  PWL_FUNC_DEF := -DPWL_FUNCTION_SIGMOID
  PWL_FUNC_ENV := PWL_FUNCTION_SIGMOID
else
  $(error PWL_FUNCTION must be exponential or sigmoid)
endif

PWL_DEFS := $(PWL_MODE_DEF) $(PWL_FUNC_DEF)

ifeq ($(PWL_PRECISION),float32)
  PWL_PREC_DEF := -DUSE_FLOAT32
  PWL_PREC_ENV := USE_FLOAT32
else ifeq ($(PWL_PRECISION),float16)
  PWL_PREC_DEF := -DUSE_FLOAT16 -DHLS_NO_XIL_FPO_LIB -DBUS=16
  PWL_PREC_ENV := USE_FLOAT16
  PWL_BUS_ENV := 16
else ifeq ($(PWL_PRECISION),float8)
  PWL_PREC_DEF := -DUSE_FLOAT8 -DHLS_NO_XIL_FPO_LIB
  PWL_PREC_ENV := USE_FLOAT8
else
  $(error PWL_PRECISION must be float32, float16, or float8)
endif

PWL_DEFS += $(PWL_PREC_DEF)
PWL_BUS_ENV ?=

ifeq ($(PWL_MODE),uniform)
  ifeq ($(PWL_FUNCTION),sigmoid)
    PY_SCRIPT := $(PY_DIR)/uniform/pwl_uniform_sigmoid.py
  else
    PY_SCRIPT := $(PY_DIR)/uniform/pwl_uniform_exp.py
  endif
else
  ifeq ($(PWL_FUNCTION),sigmoid)
    PY_SCRIPT := $(PY_DIR)/nonuniform/pwl_nonuniform_sigmoid.py
  else
    PY_SCRIPT := $(PY_DIR)/nonuniform/pwl_nonuniform_exp.py
  endif
endif

# Compiler
CXX := g++
CXXFLAGS := -std=c++14 -Wall \
            -I$(VITIS_HLS_INCLUDE) \
            -I$(HLS_DIR) \
            -I$(HLS_DIR)/common \
            -I$(HLS_DIR)/coefficients \
            -I$(TB_DIR) \
            $(PWL_DEFS)

# Build directories
$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

$(BUILD_CPP): $(BUILD_DIR)
	mkdir -p $(BUILD_CPP)

$(BUILD_VITIS): $(BUILD_DIR)
	mkdir -p $(BUILD_VITIS)

# Aggregate targets
.PHONY: all clean run gen_coeffs build_sim vitis
all: gen_coeffs build_sim vitis

gen_coeffs:
	@echo ">>> Generating coefficients for $(PWL_MODE) / $(PWL_FUNCTION)"
	python3 $(PY_SCRIPT)

build_sim: $(BUILD_CPP)
	@echo ">>> Building C++ simulation for pwl"
	$(CXX) $(CXXFLAGS) \
		$(HLS_DIR)/pwl.cpp \
		$(TB_DIR)/pwl_tb.cpp \
		-o $(BUILD_CPP)/pwl_sim

vitis: $(BUILD_VITIS)
	@echo ">>> Running Vitis HLS for pwl"
	@mkdir -p $(BUILD_VITIS)/pwl
	PWL_MODE=$(PWL_MODE_ENV) PWL_FUNCTION=$(PWL_FUNC_ENV) PWL_PRECISION=$(PWL_PREC_ENV) PWL_BUS=$(PWL_BUS_ENV) \
		vitis_hls -l $(BUILD_VITIS)/pwl/vitis_hls.log -f $(HLS_DIR)/pwl.tcl

run: build_sim
	@echo ">>> Running simulation for pwl"
	$(BUILD_CPP)/pwl_sim

clean:
	rm -rf $(BUILD_DIR)