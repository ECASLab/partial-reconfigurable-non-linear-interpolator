/*
 * Copyright 2022-2024
 * Author: Luis G. Leon-Vega <luis.leon@ieee.org>
 */

#include "pwl.h"

#if defined(PWL_NONUNIFORM)
// Recursive template for compile-time binary search on breakpoints.
template<int Low, int High>
struct BinarySearch {
  template<typename T>
  static int find(T x, const T xs[]) {
    constexpr int Mid = (Low + High) / 2;
    if (x < xs[Mid + 1]) {
      return BinarySearch<Low, Mid>::find(x, xs);
    }
    return BinarySearch<Mid + 1, High>::find(x, xs);
  }
};

// Base case specialization.
template<int Low>
struct BinarySearch<Low, Low> {
  template<typename T>
  static int find(T, const T[]) {
    return Low;
  }
};
#endif

static int search_index(DataT x) {
#pragma HLS INLINE off
  // Keep this function standalone to isolate search latency in synthesis.

#if defined(PWL_UNIFORM)
  const DataT dx = (pwl_coeff::MAX_X - pwl_coeff::MIN_X) / (DataT)pwl_coeff::NUM_SEGMENTS;
  int index = (int)((x - pwl_coeff::MIN_X) / dx);
#else
#pragma HLS bind_storage variable=pwl_coeff::breakpoints type=ROM_1P impl=LUTRAM
  // Store breakpoints in LUTRAM for predictable read latency.
  int index = BinarySearch<0, pwl_coeff::NUM_SEGMENTS - 1>::find(x, pwl_coeff::breakpoints);
#endif

  if (index < 0) {
    index = 0;
  }
  if (index >= pwl_coeff::NUM_SEGMENTS) {
    index = pwl_coeff::NUM_SEGMENTS - 1;
  }
  return index;
}

static DataT interpolate(DataT x, int index) {
#pragma HLS INLINE off
  // Keep this function standalone to isolate interpolation latency in synthesis.

#pragma HLS bind_storage variable=pwl_coeff::slopes type=ROM_1P impl=LUTRAM
#pragma HLS bind_storage variable=pwl_coeff::intercepts type=ROM_1P impl=LUTRAM
  // Store coefficients in LUTRAM for predictable read latency.

  DataT slope = pwl_coeff::slopes[index];
  DataT intercept = pwl_coeff::intercepts[index];
  return slope * (x + intercept);
}

static DataT compute_pwl(DataT x) {
#pragma HLS INLINE off
  // Keep this function standalone to isolate PWL compute latency in synthesis.

  if (x < pwl_coeff::MIN_X) {
    x = pwl_coeff::MIN_X;
  }
  if (x > pwl_coeff::MAX_X) {
    x = pwl_coeff::MAX_X;
  }

  const int index = search_index(x);
  return interpolate(x, index);
}

static void compute(StreamT &in_stream,
                    StreamT &out_stream,
                    uint64_t size) {
#pragma HLS INLINE off

iterate_elements:
  for (uint64_t elem = 0; elem < size; elem += kPackets) {
// Pipeline one packed word per cycle for throughput.
#pragma HLS PIPELINE
// Tripcount helps Vitis estimate latency/area when size is runtime.
#pragma HLS LOOP_TRIPCOUNT min = kTotalMaxSize max = kTotalMaxSize avg = kTotalMaxSize
    RawDataT raw_out = 0;
    RawDataT raw_in = in_stream.read();

  compute_words:
    for (int p = 0; p < kPackets; ++p) {
      const int offlow = p * kDataWidth;
      const int offhigh = offlow + kDataWidth - 1;

      DataT number = raw_to_data(raw_in(offhigh, offlow));
      DataT result = compute_pwl(number);
      raw_out(offhigh, offlow) = data_to_raw(result);
    }
    out_stream << raw_out;
  }
}

static void load_input(RawDataT *in, StreamT &inStream, uint64_t size) {
  const uint64_t size_raw = size / kPackets;
mem_rd:
  for (uint64_t i = 0; i < size_raw; ++i) {
// Pipeline reads from memory into the stream.
#pragma HLS PIPELINE
// Tripcount helps Vitis estimate latency/area when size is runtime.
#pragma HLS LOOP_TRIPCOUNT min = kTotalMaxSize max = kTotalMaxSize avg = kTotalMaxSize
    inStream << in[i];
  }
}

static void store_result(RawDataT *out, StreamT &out_stream, uint64_t size) {
  const uint64_t size_raw = size / kPackets;
mem_wr:
  for (uint64_t i = 0; i < size_raw; ++i) {
// Pipeline writes from stream to memory.
#pragma HLS PIPELINE
// Tripcount helps Vitis estimate latency/area when size is runtime.
#pragma HLS LOOP_TRIPCOUNT min = kTotalMaxSize max = kTotalMaxSize avg = kTotalMaxSize
    out[i] = out_stream.read();
  }
}

extern "C" {
void PWL_TOP(RawDataT *in, RawDataT *out, uint64_t size) {
// AXI4 master ports for bulk data movement and AXI4-Lite for control.
#pragma HLS INTERFACE m_axi port=in offset=slave bundle=gmem0 depth=kTotalMaxSize
#pragma HLS INTERFACE m_axi port=out offset=slave bundle=gmem1 depth=kTotalMaxSize
#pragma HLS INTERFACE s_axilite register port = size
#pragma HLS INTERFACE s_axilite register port = return

  StreamT stream_in;
  StreamT stream_out;
#pragma HLS stream variable = stream_in depth = 32
#pragma HLS stream variable = stream_out depth = 32
// Use per-invocation streams so repeated kernel launches start from empty FIFOs.

// Enable task-level pipelining across load/compute/store.
#pragma HLS dataflow
  load_input(in, stream_in, size);
  compute(stream_in, stream_out, size);
  store_result(out, stream_out, size);
}
}
