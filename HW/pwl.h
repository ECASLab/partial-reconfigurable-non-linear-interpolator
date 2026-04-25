/*
 * Copyright 2022-2024
 * Author: Luis G. Leon-Vega <luis.leon@ieee.org>
 */

#ifndef __PWL_H__
#define __PWL_H__

#include "common/config.h"

#ifndef PWL_TOP
#define PWL_TOP pwl
#endif

// defined
#if defined(PWL_UNIFORM) && defined(PWL_NONUNIFORM)
#error "Define either PWL_UNIFORM or PWL_NONUNIFORM"
#endif

// If none defined, use PWL UNIFORM
#if !defined(PWL_UNIFORM) && !defined(PWL_NONUNIFORM)
#define PWL_UNIFORM
#endif // !PWL_UNIFORM && !PWL_NONUNIFORM

// Only one must be defined
#if defined(PWL_FUNCTION_EXPONENTIAL) && defined(PWL_FUNCTION_SIGMOID)
#error "Define either PWL_FUNCTION_EXPONENTIAL or PWL_FUNCTION_SIGMOID"
#endif

// If none defined, use PWL Exponential
#if !defined(PWL_FUNCTION_EXPONENTIAL) && !defined(PWL_FUNCTION_SIGMOID)
#define PWL_FUNCTION_EXPONENTIAL
#endif // !PWL_FUNCTION_EXPONENTIAL && !PWL_FUNCTION_SIGMOID

#if defined(PWL_UNIFORM)
#if defined(PWL_FUNCTION_SIGMOID)
#if defined(USE_FLOAT16)
#include "coefficients/fp16/pwl_uniform_sigmoid_fp16_coefficients.hpp"
namespace pwl_coeff = sigmoid_fp16;
#else
#include "coefficients/fp32/pwl_uniform_sigmoid_fp32_coefficients.hpp"
namespace pwl_coeff = sigmoid_fp32;
#endif
#elif defined(PWL_FUNCTION_EXPONENTIAL)
#if defined(USE_FLOAT16)
#include "coefficients/fp16/pwl_uniform_exponential_fp16_coefficients.hpp"
namespace pwl_coeff = exponential_fp16;
#else
#include "coefficients/fp32/pwl_uniform_exponential_fp32_coefficients.hpp"
namespace pwl_coeff = exponential_fp32;
#endif
#else 
#if defined(USE_FLOAT16)
#include "coefficients/fp16/pwl_uniform_exponential_fp16_coefficients.hpp"
namespace pwl_coeff = exponential_fp16;
#else
#include "coefficients/fp32/pwl_uniform_exponential_fp32_coefficients.hpp"
namespace pwl_coeff = exponential_fp32;
#endif
#endif
#else // PWL_NONUNIFORM
#if defined(PWL_FUNCTION_SIGMOID)
#if defined(USE_FLOAT16)
#include "coefficients/fp16/pwl_nonuniform_sigmoid_fp16_coefficients.hpp"
namespace pwl_coeff = sigmoid_fp16;
#else
#include "coefficients/fp32/pwl_nonuniform_sigmoid_fp32_coefficients.hpp"
namespace pwl_coeff = sigmoid_fp32;
#endif
#elif defined(PWL_FUNCTION_EXPONENTIAL)
#if defined(USE_FLOAT16)
#include "coefficients/fp16/pwl_nonuniform_exponential_fp16_coefficients.hpp"
namespace pwl_coeff = exponential_fp16;
#else
#include "coefficients/fp32/pwl_nonuniform_exponential_fp32_coefficients.hpp"
namespace pwl_coeff = exponential_fp32;
#endif
#else // PWL_FUNCTION_EXPONENTIAL
#if defined(USE_FLOAT16)
#include "coefficients/fp16/pwl_nonuniform_exponential_fp16_coefficients.hpp"
namespace pwl_coeff = exponential_fp16;
#else
#include "coefficients/fp32/pwl_nonuniform_exponential_fp32_coefficients.hpp"
namespace pwl_coeff = exponential_fp32;
#endif
#endif 
#endif 

static constexpr uint64_t kMaxElements = MAX_INPUTS;
static constexpr uint64_t kTotalMaxSize = kMaxElements / kPackets;
static_assert((kMaxElements % kPackets) == 0,
              "kMaxElements must be multiple of kPackets");

extern "C" {
/**
 * Piecewise linear interpolation kernel
 * in:  input array of RawDataT (each word contains kPackets values)
 * out: output array of RawDataT
 * size: number of elements (must be multiple of kPackets)
 */
void PWL_TOP(RawDataT *in, RawDataT *out, uint64_t size);
}

#endif // __PWL_H__
