/*
 * Copyright 2022-2024
 * Author: Luis G. Leon-Vega <luis.leon@ieee.org>
 * Modified: 03/2026 by Roger Morales <rj.m.m.2500@estudiantec.cr>
 */

#ifndef __CONFIG_H__
#define __CONFIG_H__

#include <stdint.h>
#include <ap_int.h> // HLS integer types
#include <ap_fixed.h> //HLS fixed-point types
#include <hls_stream.h> // HLS FIFO streaming intergaces

#if defined(USE_FLOAT16) || defined(USE_FLOAT8) || defined(USE_FLOAT4)
#include <hls_half.h> // HLS half-precision data types
#endif

#ifndef BUS
static constexpr int kBusWidth = 32;
#else
static constexpr int kBusWidth = BUS;
#endif

#ifndef MAX_INPUTS
#define MAX_INPUTS 512 // Max number of input elements in the stream
#endif

#ifdef USE_FLOAT32
static constexpr int kDataWidth = 32;
using DataT = float;
using AccT = float;
#elif defined(USE_FLOAT16)
static constexpr int kDataWidth = 16;
using DataT = half;
using AccT = half;
#elif defined(USE_FLOAT8)
static constexpr int kDataWidth = 8;
using DataT = half;
using AccT = half;
#elif defined(USE_FLOAT4)
static constexpr int kDataWidth = 4;
using DataT = half;
using AccT = half;
#elif defined(USE_FIXED16)
static constexpr int kFixedDataWidth = 16;
static constexpr int kFixedDataInt = 6;
static constexpr int kDataWidth = kFixedDataWidth;
using DataT = ap_fixed<kFixedDataWidth, kFixedDataInt>;
#elif defined(USE_FIXED8)
static constexpr int kFixedDataWidth = 8;
static constexpr int kFixedDataInt = 4;
static constexpr int kDataWidth = kFixedDataWidth;
using DataT = ap_fixed<kFixedDataWidth, kFixedDataInt>;
#else
static constexpr int kDataWidth = 32;
using DataT = float;
using AccT = DataT;
#endif

static constexpr int kPackets = kBusWidth / kDataWidth;
static_assert(kBusWidth % kDataWidth == 0, "kBusWidth must be multiple of kDataWidth"); // Ensure correctly configured packetization

using RawDataT = ap_uint<kBusWidth>;
using RawSingleDataT = ap_uint<kDataWidth>;
using StreamT = hls::stream<RawDataT>;
using StreamSingleT = hls::stream<RawSingleDataT>;

inline DataT raw_to_data(RawSingleDataT raw) {
#ifdef USE_FLOAT32
  union {
    uint32_t i;
    float f;
  } full_precision;
  full_precision.i = static_cast<uint32_t>(raw);
  return full_precision.f;
#elif defined(USE_FLOAT16) || defined(USE_FLOAT8) || defined(USE_FLOAT4)
#ifdef __SYNTHESIS__ // Use unions for synthesis
  union {
    ap_uint<16> u;
    DataT f;
  } reduced_precision;
  reduced_precision.u = static_cast<ap_uint<16> >(raw);
  return reduced_precision.f;
#else // For simulation use C++ set_bits/get_bits
  DataT value;
  value.set_bits(static_cast<half::uint16>(raw));
  return value;
#endif
#else
  DataT value;
  value.V = raw;
  return value;
#endif
}

inline RawSingleDataT data_to_raw(DataT value) {
#ifdef USE_FLOAT32
  union {
    uint32_t i;
    float f;
  } full_precision;
  full_precision.f = value;
  return static_cast<RawSingleDataT>(full_precision.i);
#elif defined(USE_FLOAT16) || defined(USE_FLOAT8) || defined(USE_FLOAT4)
#ifdef __SYNTHESIS__
  union {
    ap_uint<16> u;
    DataT f;
  } reduced_precision;
  reduced_precision.f = value;
  return static_cast<RawSingleDataT>(reduced_precision.u);
#else
  return static_cast<RawSingleDataT>(value.get_bits());
#endif
#else
  return static_cast<RawSingleDataT>(value.V);
#endif
}

#endif // __CONFIG_H__