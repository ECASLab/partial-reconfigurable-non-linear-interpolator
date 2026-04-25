/*
 * CYNQ host example for the final-project `individual` design.
 *
 * This software targets the current hardware shape:
 *   - AXI DMA control through AXI4-Lite
 *   - One AXI4-Stream DUT wrapper
 *   - No AXI4-Lite control registers on the DUT itself
 *
 * Because of that, this adapts the CYNQ flow to a DMA-only streaming design
 * instead of the MMIO-controlled `ad08` pattern.
 *
 * Typical use:
 *   ./individual_cynq
 *   ./individual_cynq --dut xor
 *   ./individual_cynq --bitstream /path/to/design_1_wrapper.bit
 *   ./individual_cynq --bitstream /path/to/design_1_wrapper.bit --xclbin /path/to/default.xclbin
 *   ./individual_cynq /path/to/design_1_wrapper.bit
 *   ./individual_cynq --no-program
 */

#include <cynq/datamover.hpp>
#include <cynq/enums.hpp>
#include <cynq/hardware.hpp>
#include <cynq/memory.hpp>
#include <cynq/status.hpp>

#include <algorithm>
#include <array>
#include <cstdint>
#include <cstdlib>
#include <filesystem>
#include <iomanip>
#include <iostream>
#include <memory>
#include <optional>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

constexpr uint64_t kDefaultDmaBase = 0x80000000ULL;
constexpr char kDefaultPartTag[] = "xck26_sfvc784_2LV_c";

enum class DutKind {
  Mul,
  Xor,
};

struct Options {
  DutKind dut = DutKind::Mul;
  uint64_t dma_base = kDefaultDmaBase;
  bool program_bitstream = true;
  std::string bitstream;
  std::string xclbin;
  std::filesystem::path executable_dir;
};

struct TestVector {
  uint64_t a;
  uint64_t b;
};

struct ExpectedResult {
  uint64_t lo;
  uint64_t hi;
};

struct alignas(16) AxiBeat128 {
  uint64_t lo;
  uint64_t hi;
};

static_assert(sizeof(AxiBeat128) == 16, "AXI beat must stay 128 bits wide");

constexpr std::array<TestVector, 4> kTests = {{
    {0x0000000000000007ULL, 0x0000000000000009ULL},
    {0x123456789abcdef0ULL, 0x0000000000000010ULL},
    {0xffffffffffffffffULL, 0x0000000000000002ULL},
    {0xfeedfacecafebeefULL, 0x0102030405060708ULL},
}};

std::string ToLower(std::string text) {
  std::transform(text.begin(), text.end(), text.begin(),
                 [](unsigned char ch) { return static_cast<char>(std::tolower(ch)); });
  return text;
}

std::string DutName(const DutKind dut) {
  return dut == DutKind::Mul ? "mul" : "xor";
}

std::string Hex64(const uint64_t value) {
  std::ostringstream os;
  os << "0x" << std::hex << std::setfill('0') << std::setw(16) << value;
  return os.str();
}

std::string Hex128(const uint64_t hi, const uint64_t lo) {
  std::ostringstream os;
  os << "0x" << std::hex << std::setfill('0') << std::setw(16) << hi
     << std::setw(16) << lo;
  return os.str();
}

void PrintUsage(const char* argv0) {
  std::cout
      << "Usage: " << argv0
      << " [--dut mul|xor] [--bitstream <path>|<path.bit>] [--xclbin <path>]"
         " [--dma-base <addr>]"
         " [--no-program]\n";
}

DutKind ParseDut(const std::string& text) {
  const std::string lowered = ToLower(text);
  if (lowered == "mul") {
    return DutKind::Mul;
  }
  if (lowered == "xor") {
    return DutKind::Xor;
  }
  throw std::runtime_error("Unsupported DUT '" + text + "'. Use 'mul' or 'xor'.");
}

uint64_t ParseAddress(const std::string& text) {
  size_t consumed = 0;
  const uint64_t value = std::stoull(text, &consumed, 0);
  if (consumed != text.size()) {
    throw std::runtime_error("Invalid numeric address '" + text + "'.");
  }
  return value;
}

std::filesystem::path GetExecutableDir(const char* argv0) {
  try {
    if (argv0 != nullptr && argv0[0] != '\0') {
      return std::filesystem::absolute(argv0).parent_path();
    }
  } catch (const std::exception&) {
  }
  return std::filesystem::current_path();
}

std::optional<std::filesystem::path> FindSingleBitfile(
    const std::filesystem::path& directory) {
  if (!std::filesystem::exists(directory) || !std::filesystem::is_directory(directory)) {
    return std::nullopt;
  }

  std::optional<std::filesystem::path> only_match;
  for (const auto& entry : std::filesystem::directory_iterator(directory)) {
    if (!entry.is_regular_file()) {
      continue;
    }
    if (entry.path().extension() != ".bit") {
      continue;
    }
    if (only_match.has_value()) {
      return std::nullopt;
    }
    only_match = entry.path();
  }
  return only_match;
}

std::vector<std::filesystem::path> BitstreamCandidates(
    const DutKind dut, const std::filesystem::path& executable_dir) {
  const std::string dut_name = DutName(dut);
  const std::string proj_name = "my_proj_" + dut_name + "_" + kDefaultPartTag;
  const std::string repo_relative =
      "build/vivado/" + dut_name + "/" + kDefaultPartTag + "/" + proj_name +
      "/" + proj_name + ".runs/impl_1/design_1_wrapper.bit";

  std::vector<std::filesystem::path> candidates = {
      executable_dir / "design_1_wrapper.bit",
      executable_dir / (dut_name + ".bit"),
      std::filesystem::current_path() / "design_1_wrapper.bit",
      std::filesystem::current_path() / (dut_name + ".bit"),
      repo_relative,
      std::filesystem::path("..") / repo_relative,
      std::filesystem::path("final-project") / repo_relative,
  };

  if (const auto single = FindSingleBitfile(executable_dir); single.has_value()) {
    candidates.push_back(*single);
  }
  if (const auto single = FindSingleBitfile(std::filesystem::current_path());
      single.has_value()) {
    candidates.push_back(*single);
  }

  return candidates;
}

std::vector<std::filesystem::path> XclbinCandidates(
    const std::filesystem::path& executable_dir) {
  return {
      executable_dir / "default.xclbin",
      executable_dir / "design_1_wrapper.xclbin",
      std::filesystem::current_path() / "default.xclbin",
      std::filesystem::current_path() / "design_1_wrapper.xclbin",
  };
}

std::string FindExistingBitstream(const DutKind dut,
                                  const std::filesystem::path& executable_dir) {
  for (const auto& candidate : BitstreamCandidates(dut, executable_dir)) {
    if (std::filesystem::exists(candidate)) {
      return candidate.string();
    }
  }
  return {};
}

std::string FindExistingXclbin(const std::filesystem::path& executable_dir) {
  for (const auto& candidate : XclbinCandidates(executable_dir)) {
    if (std::filesystem::exists(candidate)) {
      return candidate.string();
    }
  }
  return {};
}

Options ParseArgs(const int argc, char** argv) {
  Options options;
  bool bitstream_explicit = false;
  options.executable_dir = GetExecutableDir(argv[0]);
  options.bitstream = FindExistingBitstream(options.dut, options.executable_dir);
  options.xclbin = FindExistingXclbin(options.executable_dir);

  for (int i = 1; i < argc; ++i) {
    const std::string arg = argv[i];

    if (arg == "--help" || arg == "-h") {
      PrintUsage(argv[0]);
      std::exit(0);
    }

    if (arg == "--dut") {
      if (i + 1 >= argc) {
        throw std::runtime_error("Missing value after --dut.");
      }
      options.dut = ParseDut(argv[++i]);
      if (!bitstream_explicit) {
        options.bitstream = FindExistingBitstream(options.dut, options.executable_dir);
      }
      continue;
    }

    if (arg == "--bitstream") {
      if (i + 1 >= argc) {
        throw std::runtime_error("Missing value after --bitstream.");
      }
      options.bitstream = argv[++i];
      bitstream_explicit = true;
      continue;
    }

    if (arg == "--xclbin") {
      if (i + 1 >= argc) {
        throw std::runtime_error("Missing value after --xclbin.");
      }
      options.xclbin = argv[++i];
      continue;
    }

    if (arg == "--dma-base") {
      if (i + 1 >= argc) {
        throw std::runtime_error("Missing value after --dma-base.");
      }
      options.dma_base = ParseAddress(argv[++i]);
      continue;
    }

    if (arg == "--no-program") {
      options.program_bitstream = false;
      continue;
    }

    if (!arg.empty() && arg[0] != '-') {
      if (bitstream_explicit) {
        throw std::runtime_error("Bitstream path was already provided.");
      }
      options.bitstream = arg;
      bitstream_explicit = true;
      continue;
    }

    throw std::runtime_error("Unknown argument '" + arg + "'.");
  }

  if (options.program_bitstream) {
    if (options.bitstream.empty()) {
      throw std::runtime_error(
          "No bitstream path found. Pass --bitstream <path> or place a single "
          ".bit file next to the binary, or use --no-program if the overlay is "
          "already loaded.");
    }
    if (!std::filesystem::exists(options.bitstream)) {
      throw std::runtime_error("Bitstream not found: " + options.bitstream);
    }
  }

  if (options.xclbin.empty()) {
    throw std::runtime_error(
        "No xclbin path found. Pass --xclbin <path> or place default.xclbin "
        "next to the binary. Stock CYNQ requires an xclbin for XRT device "
        "setup and buffer allocation.");
  }
  if (!std::filesystem::exists(options.xclbin)) {
    throw std::runtime_error("XCLBIN not found: " + options.xclbin);
  }

  return options;
}

ExpectedResult ComputeExpected(const DutKind dut, const TestVector& test) {
  if (dut == DutKind::Xor) {
    return ExpectedResult{test.a ^ test.b, 0ULL};
  }

  const __uint128_t product =
      static_cast<__uint128_t>(test.a) * static_cast<__uint128_t>(test.b);
  return ExpectedResult{
      static_cast<uint64_t>(product),
      static_cast<uint64_t>(product >> 64),
  };
}

void CheckStatus(const cynq::Status& status, const std::string& action) {
  if (status.code != cynq::Status::OK) {
    std::ostringstream os;
    os << action << " failed";
    if (!status.msg.empty()) {
      os << ": " << status.msg;
    } else {
      os << " with status code " << status.code;
    }
    throw std::runtime_error(os.str());
  }
}

void FillInputBuffer(AxiBeat128* input_beats) {
  for (size_t i = 0; i < kTests.size(); ++i) {
    // The RTL wrapper expects:
    //   tdata[127:64] = a
    //   tdata[63:0]   = b
    input_beats[i].lo = kTests[i].b;
    input_beats[i].hi = kTests[i].a;
  }
}

}  // namespace

int main(int argc, char** argv) {
  try {
    const Options options = ParseArgs(argc, argv);

    std::cout << "DUT: " << DutName(options.dut) << '\n';
    std::cout << "DMA base: " << Hex64(options.dma_base) << '\n';
    if (options.program_bitstream) {
      std::cout << "Bitstream: " << options.bitstream << '\n';
    } else {
      std::cout << "Bitstream: already configured hardware (--no-program)\n";
    }
    std::cout << "XCLBIN: " << options.xclbin << '\n';

    std::shared_ptr<cynq::IHardware> platform;
    if (options.program_bitstream) {
      platform = cynq::IHardware::Create(cynq::HardwareArchitecture::UltraScale,
                                         options.bitstream, options.xclbin);
    } else {
      platform = cynq::IHardware::Create(cynq::HardwareArchitecture::UltraScale,
                                         "", options.xclbin);
    }

    if (!platform) {
      throw std::runtime_error("Failed to create the CYNQ platform object.");
    }

    std::shared_ptr<cynq::IDataMover> mover =
        platform->GetDataMover(options.dma_base);
    if (!mover) {
      throw std::runtime_error("Failed to create the CYNQ DMA data mover.");
    }

    const size_t payload_bytes = kTests.size() * sizeof(AxiBeat128);
    std::shared_ptr<cynq::IMemory> in_mem = mover->GetBuffer(payload_bytes);
    std::shared_ptr<cynq::IMemory> out_mem = mover->GetBuffer(payload_bytes);
    if (!in_mem || !out_mem) {
      throw std::runtime_error("Failed to allocate CYNQ buffers.");
    }

    auto* input_beats = in_mem->HostAddress<AxiBeat128>().get();
    auto* output_beats = out_mem->HostAddress<AxiBeat128>().get();
    if (!input_beats || !output_beats) {
      throw std::runtime_error("Failed to map host-visible CYNQ buffers.");
    }

    FillInputBuffer(input_beats);
    for (size_t i = 0; i < kTests.size(); ++i) {
      output_beats[i] = AxiBeat128{0ULL, 0ULL};
    }

    // For a streaming accelerator without start/stop registers, arm the
    // receive path first so the DUT never has to wait for the output DMA.
    CheckStatus(
        mover->Download(out_mem, payload_bytes, 0, cynq::ExecutionType::Async),
        "queue DMA S2MM transfer");
    CheckStatus(
        mover->Upload(in_mem, payload_bytes, 0, cynq::ExecutionType::Async),
        "queue DMA MM2S transfer");
    CheckStatus(mover->Sync(cynq::SyncType::HostToDevice),
                "wait for DMA MM2S completion");
    CheckStatus(mover->Sync(cynq::SyncType::DeviceToHost),
                "wait for DMA S2MM completion");
    CheckStatus(out_mem->Sync(cynq::SyncType::DeviceToHost),
                "synchronise output buffer to host");

    bool all_passed = true;
    for (size_t i = 0; i < kTests.size(); ++i) {
      const ExpectedResult expected = ComputeExpected(options.dut, kTests[i]);
      const uint64_t actual_lo = output_beats[i].lo;
      const uint64_t actual_hi = output_beats[i].hi;
      const bool passed =
          (expected.lo == actual_lo) && (expected.hi == actual_hi);

      all_passed &= passed;

      std::cout << "test[" << i << "]"
                << " a=" << Hex64(kTests[i].a)
                << " b=" << Hex64(kTests[i].b)
                << " expected=" << Hex128(expected.hi, expected.lo)
                << " actual=" << Hex128(actual_hi, actual_lo)
                << " " << (passed ? "PASS" : "FAIL") << '\n';
    }

    if (!all_passed) {
      std::cerr << "One or more DUT checks failed.\n";
      return 1;
    }

    std::cout << "All DUT checks passed.\n";
    return 0;
  } catch (const std::exception& ex) {
    std::cerr << "ERROR: " << ex.what() << '\n';
    return 1;
  }
}
