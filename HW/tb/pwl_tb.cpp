#include <cmath>
#include <cstdlib>
#include <iostream>
#include <limits>
#include <random>
#include <vector>

#include "pwl.h"

inline DataT reference_function(DataT x) {
  float xf = static_cast<float>(x);
#if defined(PWL_FUNCTION_SIGMOID)
  float yf = 1.0f / (1.0f + std::exp(-xf));
#else
  float yf = std::exp(xf);
#endif
  return static_cast<DataT>(yf);
}

int main(int argc, char **argv) {
  const float input_min = static_cast<float>(pwl_coeff::MIN_X);
  const float input_max = static_cast<float>(pwl_coeff::MAX_X);

  std::mt19937 rng(1234);
  std::uniform_real_distribution<float> dist(input_min, input_max);

  static constexpr uint64_t kDefaultValues = 512;
  uint64_t num_values = kDefaultValues;
  if (argc > 1) {
    num_values = std::strtoull(argv[1], nullptr, 10);
  }

  if (num_values == 0 || num_values > kMaxElements) {
    std::cerr << "Invalid number of values: " << num_values
              << ". Expected 1.." << kMaxElements << std::endl;
    return 1;
  }
  if ((num_values % kPackets) != 0) {
    std::cerr << "Number of values must be multiple of kPackets ("
              << kPackets << "): " << num_values << std::endl;
    return 1;
  }

  const uint64_t kWords = num_values / kPackets;
  const uint64_t size = num_values;

  RawDataT input_sequence[kTotalMaxSize] = {0};
  RawDataT output_sequence[kTotalMaxSize] = {0};

  std::vector<DataT> local_inputs(num_values);
  std::vector<DataT> local_outputs(num_values);

  for (uint64_t w = 0; w < kWords; ++w) {
    RawDataT raw_in = 0;
    for (int p = 0; p < kPackets; ++p) {
      const int offlow = p * kDataWidth;
      const int offhigh = offlow + kDataWidth - 1;
      const uint64_t idx = w * kPackets + p;

      float xf = dist(rng);
      DataT x = static_cast<DataT>(xf);
      raw_in(offhigh, offlow) = data_to_raw(x);

      local_inputs[idx] = x;
    }
    input_sequence[w] = raw_in;
  }

  PWL_TOP(input_sequence, output_sequence, size);

  for (uint64_t w = 0; w < kWords; ++w) {
    RawDataT raw_out = output_sequence[w];
    for (int p = 0; p < kPackets; ++p) {
      const int offlow = p * kDataWidth;
      const int offhigh = offlow + kDataWidth - 1;
      const uint64_t idx = w * kPackets + p;

      DataT y = raw_to_data(raw_out(offhigh, offlow));
      local_outputs[idx] = y;
    }
  }

  bool pass = true;
  double total_error = 0.0;
  double max_error = 0.0;
  double min_error = std::numeric_limits<double>::max();
  double total_sq_error = 0.0;

  for (uint64_t i = 0; i < num_values; ++i) {
    DataT x = local_inputs[i];
    DataT ref_out = reference_function(x);
    DataT dut_out = local_outputs[i];

    double abs_diff = std::fabs(static_cast<float>(dut_out) -
                                static_cast<float>(ref_out));
    total_error += abs_diff;
    total_sq_error += abs_diff * abs_diff;
    if (abs_diff > max_error) {
      max_error = abs_diff;
    }
    if (abs_diff < min_error) {
      min_error = abs_diff;
    }

    double tolerance = (kDataWidth == 32) ? 16.0 :
                       (kDataWidth == 16) ? 16.0 :
                       0.5;
    if (abs_diff > tolerance) {
      std::cerr << "Mismatch at sample " << i
                << ": x=" << static_cast<float>(x)
                << ", DUT=" << static_cast<float>(dut_out)
                << ", REF=" << static_cast<float>(ref_out)
                << ", |diff|=" << abs_diff << std::endl;
      pass = false;
    }
  }

  double mean_error = total_error / num_values;
  double rmse = std::sqrt(total_sq_error / num_values);

  if (!pass) {
    std::cerr << "FAILED. Mean=" << mean_error
              << ", Max=" << max_error
              << ", Min=" << min_error
              << ", RMSE=" << rmse << std::endl;
    return 1;
  }

  std::cout << "PASSED. Mean=" << mean_error
            << ", Max=" << max_error
            << ", Min=" << min_error
            << ", RMSE=" << rmse << std::endl;
  return 0;
}
