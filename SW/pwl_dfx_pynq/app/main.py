#!/usr/bin/env python3
"""
PYNQ host example for the final-project PWL DFX design.

This application targets the `scripts` PWL DFX Vivado flow and exercises
the reconfigurable partition with two AXI-MM HLS kernels:
  - `exp`
  - `sigmoid`

The static shell exposes:
  - `axi_gpio_reset_0` at 0x8000_0000
  - `axi_gpio_shutdown_0` at 0x8001_0000, with channel 2 bit 0 = shutdown status
    and bits 31:1 = last partial-reconfiguration latency in PL clock cycles
  - `rp_s_axi_control` at 0x8002_0000

Typical use:
  ./pwl_dfx_pynq.py
  ./pwl_dfx_pynq.py --run sigmoid
  ./pwl_dfx_pynq.py --run both
  ./pwl_dfx_pynq.py --full-rm sigmoid --run both
  ./pwl_dfx_pynq.py --no-program --full-rm exp --run sigmoid
"""

from __future__ import annotations

import argparse
import math
import os
import shutil
import struct
import sys
import tempfile
import threading
import time
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable


DEFAULT_PART_TAG = "xck26_sfvc784_2LV_c"
DEFAULT_FULL_RM = "exp"

DEFAULT_RESET_GPIO_ADDR = 0x80000000
DEFAULT_SHUTDOWN_GPIO_ADDR = 0x80010000
DEFAULT_CONTROL_ADDR = 0x80020000
DEFAULT_MMIO_RANGE = 0x10000

GPIO_DATA_OFFSET = 0x0
GPIO_TRI_OFFSET = 0x4
GPIO2_DATA_OFFSET = 0x8
GPIO2_TRI_OFFSET = 0xC
SHUTDOWN_STATUS_MASK = 0x1
RECONFIG_LATENCY_SHIFT = 1
RECONFIG_LATENCY_MASK = 0x7FFFFFFF

RESET_ASSERT_LEVEL = 0
RESET_RELEASE_LEVEL = 1
SHUTDOWN_ASSERT_LEVEL = 1
SHUTDOWN_RELEASE_LEVEL = 0

HLS_AP_CTRL = 0x00
HLS_GIE = 0x04
HLS_IER = 0x08
HLS_ISR = 0x0C
HLS_IN_PTR_LO = 0x10
HLS_IN_PTR_HI = 0x14
HLS_OUT_PTR_LO = 0x1C
HLS_OUT_PTR_HI = 0x20
HLS_SIZE_LO = 0x28
HLS_SIZE_HI = 0x2C

AP_START = 1 << 0
AP_DONE = 1 << 1
AP_IDLE = 1 << 2
AP_CONTINUE = 1 << 4
AUTO_RESTART = 1 << 7

GPIO_TIMEOUT_SECONDS = 2.0
KERNEL_TIMEOUT_SECONDS = 5.0
DEFAULT_ITERATIONS = 1
DEFAULT_POWER_SAMPLE_INTERVAL_SECONDS = 0.02
DEFAULT_IDLE_POWER_SECONDS = 1.0
DEFAULT_POST_RECONFIG_STABILIZE_SECONDS = 0.1

PWL_MIN_X = -8.0
PWL_MAX_X = 8.0
DDR_HIGH_ADDR = 0x7FFFFFFF
FPGA_MANAGER_FLAGS = Path("/sys/class/fpga_manager/fpga0/flags")
FPGA_MANAGER_FIRMWARE = Path("/sys/class/fpga_manager/fpga0/firmware")
FPGA_MANAGER_FIRMWARE_DIR = Path("/lib/firmware")
HWMON_ROOT = Path("/sys/class/hwmon")
RAW_FULL_BIT_NAME = "pwl_dfx_top.bit"

DUT_CONFIG = {
    "exp": {
        "function": "exp",
        "display_name": "Nonuniform exponential Float32",
        "precision_bits": 32,
        "min_x": -8.0,
        "max_x": 8.0,
        "atol": 16.0,
        "rtol": 0.03,
    },
    "exp_f16": {
        "function": "exp",
        "display_name": "Nonuniform exponential Float16",
        "precision_bits": 16,
        "min_x": -8.0,
        "max_x": 8.0,
        "atol": 16.0,
        "rtol": 0.05,
    },
    "sigmoid": {
        "function": "sigmoid",
        "display_name": "Nonuniform sigmoid Float32",
        "precision_bits": 32,
        "min_x": -8.0,
        "max_x": 8.0,
        "atol": 0.02,
        "rtol": 0.02,
    },
    "sigmoid_f16": {
        "function": "sigmoid",
        "display_name": "Nonuniform sigmoid Float16",
        "precision_bits": 16,
        "min_x": -8.0,
        "max_x": 8.0,
        "atol": 0.03,
        "rtol": 0.05,
    },
}

AUTO_POWER_RAIL_HINTS = (
    "vccint",
    "vccintfpga",
    "vccintpl",
    "vccpint",
    "vccintlp",
)

AUTO_HWMON_HINTS = (
    "ina260",
    "ina238",
    "ina226",
)


@dataclass(frozen=True)
class PowerTarget:
    display_name: str
    reader: object
    source: str
    aliases: tuple[str, ...] = ()
    auto_priority: int = 100


@dataclass(frozen=True)
class RmTestMetrics:
    passed: bool
    mean_error: float
    max_error: float
    kernel_seconds: float
    validation_seconds: float


@dataclass(frozen=True)
class PackedIoPlan:
    input_words: list[int]
    logical_count: int
    padded_count: int
    word_count: int
    precision_bits: int


class FileBackedValue:
    def __init__(self, path: Path, scale: float):
        self.path = Path(path)
        self.scale = float(scale)

    @property
    def value(self) -> float:
        raw = self.path.read_text(encoding="utf-8").strip()
        return float(raw) / self.scale


class HwmonRail:
    def __init__(
        self,
        sensor_name: str,
        label: str,
        power_path: Path | None = None,
        voltage_path: Path | None = None,
        current_path: Path | None = None,
    ):
        self.sensor_name = sensor_name
        self.label = label
        self.power = FileBackedValue(power_path, 1_000_000.0) if power_path is not None else None
        self.voltage = FileBackedValue(voltage_path, 1_000.0) if voltage_path is not None else None
        self.current = FileBackedValue(current_path, 1_000.0) if current_path is not None else None


def debug_print(enabled: bool, message: str) -> None:
    if enabled:
        print(f"[DEBUG {time.strftime('%H:%M:%S')}] {message}", flush=True)


def normalize_name(name: str) -> str:
    return "".join(ch for ch in str(name).lower() if ch.isalnum())

def canonical_rm_id(rm: str) -> str:
    alias_map = {
        "exp": "exp",
        "exponential": "exp",
        "expf32": "exp",
        "expfloat32": "exp",
        "exp32": "exp",
        "expf16": "exp_f16",
        "expfloat16": "exp_f16",
        "exp16": "exp_f16",
        "sig": "sigmoid",
        "sigmoid": "sigmoid",
        "sigmoidf32": "sigmoid",
        "sigmoidfloat32": "sigmoid",
        "sig32": "sigmoid",
        "sigf32": "sigmoid",
        "sigmoidf16": "sigmoid_f16",
        "sigmoidfloat16": "sigmoid_f16",
        "sig16": "sigmoid_f16",
        "sigf16": "sigmoid_f16",
    }

    resolved = alias_map.get(normalize_name(rm))
    if resolved is None:
        supported = ", ".join(sorted(DUT_CONFIG))
        raise ValueError(f"Unsupported RM '{rm}'. Supported RMs: {supported}")
    return resolved


def clamp_input(rm: str, value: float) -> float:
    spec = DUT_CONFIG[rm]
    return min(max(value, spec["min_x"]), spec["max_x"])


def expected_value(rm: str, value: float) -> float:
    rm_id = canonical_rm_id(rm)
    x = clamp_input(rm_id, value)
    if DUT_CONFIG[rm_id]["function"] == "sigmoid":
        return 1.0 / (1.0 + math.exp(-x))
    return math.exp(x)


def tolerances(rm: str) -> tuple[float, float]:
    spec = DUT_CONFIG[canonical_rm_id(rm)]
    return float(spec["atol"]), float(spec["rtol"])


def within_tolerance(expected: float, actual: float, atol: float, rtol: float) -> bool:
    return abs(actual - expected) <= (atol + (rtol * abs(expected)))


def parse_int_arg(value: str) -> int:
    return int(value, 0)


def companion_rm_id(rm: str) -> str:
    resolved = canonical_rm_id(rm)
    switch_map = {
        "exp": "sigmoid",
        "sigmoid": "exp",
        "exp_f16": "sigmoid_f16",
        "sigmoid_f16": "exp_f16",
    }
    return switch_map[resolved]


def get_executable_dir(argv0: str) -> Path:
    try:
        return Path(argv0).resolve().parent
    except OSError:
        return Path.cwd()


def default_summary_path(argv0: str, executable_dir: Path) -> Path:
    return executable_dir / f"{Path(argv0).stem}_summary.txt"


def save_summary_file(summary_path: Path, summary_lines: list[str]) -> Path:
    try:
        summary_path.parent.mkdir(parents=True, exist_ok=True)
        summary_path.write_text("\n".join(summary_lines) + "\n", encoding="utf-8")
    except OSError as exc:
        raise RuntimeError(f"Failed to write summary file '{summary_path}': {exc}") from exc
    return summary_path


def first_existing(paths: Iterable[Path]) -> Path | None:
    for path in paths:
        if path.exists():
            return path.resolve()
    return None


def dfx_impl_run_name(rm: str) -> str:
    rm_id = canonical_rm_id(rm)
    if rm_id == DEFAULT_FULL_RM:
        return "impl_1"
    return f"impl_config_{rm_id}"


def deliverable_full_bit_name(rm: str) -> str:
    return f"pwl_dfx_full_region_u_rp_rm_{canonical_rm_id(rm)}.bit"


def deliverable_partial_bit_name(rm: str) -> str:
    return f"pwl_dfx_partial_region_u_rp_rm_{canonical_rm_id(rm)}.bit"


def raw_partial_bit_name(rm: str) -> str:
    return f"u_rp_rm_{canonical_rm_id(rm)}_partial.bit"


def full_bitstream_candidates(full_rm: str, executable_dir: Path) -> list[Path]:
    rm_id = canonical_rm_id(full_rm)
    proj_name = f"my_proj_pwl_dfx_{DEFAULT_PART_TAG}"
    run_dir = dfx_impl_run_name(rm_id)
    repo_relative = (
        Path("build")
        / "vivado_pwl_dfx"
        / DEFAULT_PART_TAG
        / proj_name
        / f"{proj_name}.runs"
        / run_dir
        / RAW_FULL_BIT_NAME
    )

    deliverable_name = deliverable_full_bit_name(rm_id)
    return [
        executable_dir / deliverable_name,
        executable_dir / RAW_FULL_BIT_NAME,
        Path.cwd() / deliverable_name,
        Path.cwd() / RAW_FULL_BIT_NAME,
        repo_relative,
        Path("..") / repo_relative,
        Path("final-project") / repo_relative,
    ]


def partial_bitstream_candidates(rm: str, executable_dir: Path) -> list[Path]:
    rm_id = canonical_rm_id(rm)
    proj_name = f"my_proj_pwl_dfx_{DEFAULT_PART_TAG}"
    run_dir = dfx_impl_run_name(rm_id)
    repo_relative = (
        Path("build")
        / "vivado_pwl_dfx"
        / DEFAULT_PART_TAG
        / proj_name
        / f"{proj_name}.runs"
        / run_dir
        / raw_partial_bit_name(rm_id)
    )

    deliverable_name = deliverable_partial_bit_name(rm_id)
    return [
        executable_dir / deliverable_name,
        executable_dir / raw_partial_bit_name(rm_id),
        Path.cwd() / deliverable_name,
        Path.cwd() / raw_partial_bit_name(rm_id),
        repo_relative,
        Path("..") / repo_relative,
        Path("final-project") / repo_relative,
    ]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run the PWL DFX design through PYNQ.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument(
        "--full-rm",
        default=DEFAULT_FULL_RM,
        help="Full design configuration to load. Supported values include exp, sigmoid, exp_f16, sigmoid_f16.",
    )
    parser.add_argument(
        "--run",
        default="both",
        help="Which reconfigurable module tests to run. Use 'both', 'all', or a comma-separated RM list.",
    )
    parser.add_argument(
        "--num-samples",
        type=int,
        default=17,
        help="Number of logical samples to process per run",
    )
    parser.add_argument(
        "--iterations",
        type=int,
        default=DEFAULT_ITERATIONS,
        help="Number of repeated test iterations per requested RM. Each iteration always reconfigures the RM first.",
    )
    parser.add_argument("--full-bitstream", help="Path to the full .bit file")
    parser.add_argument(
        "--full-hwh",
        help="Path to the full .hwh metadata file used to load the full design through Overlay",
    )
    parser.add_argument("--exp-partial", help="Path to the exponential partial .bit file")
    parser.add_argument("--sigmoid-partial", help="Path to the sigmoid partial .bit file")
    parser.add_argument(
        "--partial-bit",
        action="append",
        default=[],
        metavar="RM=PATH",
        help="Optional override for any partial bitstream path, for example --partial-bit exp_f16=/path/to/file.bit",
    )
    parser.add_argument(
        "--reset-gpio-addr",
        type=parse_int_arg,
        default=DEFAULT_RESET_GPIO_ADDR,
        help="AXI GPIO base address for the RP reset signal",
    )
    parser.add_argument(
        "--shutdown-gpio-addr",
        type=parse_int_arg,
        default=DEFAULT_SHUTDOWN_GPIO_ADDR,
        help="AXI GPIO base address for the DFX shutdown request/status control",
    )
    parser.add_argument(
        "--control-addr",
        type=parse_int_arg,
        default=DEFAULT_CONTROL_ADDR,
        help="AXI-Lite base address for the active PWL kernel control interface",
    )
    parser.add_argument(
        "--mmio-range",
        type=parse_int_arg,
        default=DEFAULT_MMIO_RANGE,
        help="MMIO window size to map for GPIO and control interfaces",
    )
    parser.add_argument(
        "--gpio-timeout",
        type=float,
        default=GPIO_TIMEOUT_SECONDS,
        help="Timeout in seconds for shutdown handshake polling",
    )
    parser.add_argument(
        "--kernel-timeout",
        type=float,
        default=KERNEL_TIMEOUT_SECONDS,
        help="Timeout in seconds for kernel completion polling",
    )
    parser.add_argument(
        "--power-rail",
        help="Optional power source name to sample. Accepts either a PYNQ rail or a discovered hwmon source.",
    )
    parser.add_argument(
        "--power-sample-interval",
        type=float,
        default=DEFAULT_POWER_SAMPLE_INTERVAL_SECONDS,
        help="Seconds between power samples during reconfiguration and operation windows.",
    )
    parser.add_argument(
        "--idle-power-seconds",
        type=float,
        default=DEFAULT_IDLE_POWER_SECONDS,
        help="Seconds of idle sampling collected before reconfiguration and before operation.",
    )
    parser.add_argument(
        "--post-reconfig-stabilize-seconds",
        type=float,
        default=DEFAULT_POST_RECONFIG_STABILIZE_SECONDS,
        help="Seconds to wait after reconfiguration before collecting the operation idle-power baseline.",
    )
    parser.add_argument(
        "--list-rails",
        action="store_true",
        help="List the available PYNQ rails and hwmon power sources, then exit.",
    )
    parser.add_argument(
        "--summary-file",
        help="Optional path for the final summary text file. Defaults to a .txt file next to this app.",
    )
    parser.add_argument(
        "--no-program",
        action="store_true",
        help="Skip the full bitstream download and assume the matching static design is already loaded",
    )
    parser.add_argument(
        "--full-programmer",
        choices=("overlay", "fpga_manager"),
        default="overlay",
        help="How to load the full bitstream. 'overlay' uses the standard PYNQ/XRT path, "
        "'fpga_manager' bypasses XRT for the full load and is useful for isolating board-side hangs.",
    )
    parser.add_argument(
        "--debug",
        action="store_true",
        help="Enable step-by-step debug prints while programming and running the DFX design",
    )
    args = parser.parse_args()
    if args.iterations < 1:
        parser.error("--iterations must be >= 1")
    if args.power_sample_interval <= 0.0:
        parser.error("--power-sample-interval must be > 0")
    if args.idle_power_seconds <= 0.0:
        parser.error("--idle-power-seconds must be > 0")
    if args.post_reconfig_stabilize_seconds < 0.0:
        parser.error("--post-reconfig-stabilize-seconds must be >= 0")
    return args


def resolve_full_bitstream(
    full_rm: str,
    executable_dir: Path,
    full_bitstream_arg: str | None,
) -> Path:
    bitstream = Path(full_bitstream_arg).expanduser() if full_bitstream_arg else first_existing(
        full_bitstream_candidates(full_rm, executable_dir)
    )
    if bitstream is None or not bitstream.exists():
        raise RuntimeError(
            "No full PWL DFX bitstream path found. Pass --full-bitstream <path> or use the deliverables target."
        )

    return bitstream.resolve()


def full_hwh_candidates(full_rm: str, bitstream: Path, executable_dir: Path) -> list[Path]:
    proj_name = f"my_proj_pwl_dfx_{DEFAULT_PART_TAG}"
    repo_relative = (
        Path("build")
        / "vivado_pwl_dfx"
        / DEFAULT_PART_TAG
        / proj_name
        / f"{proj_name}.gen"
        / "sources_1"
        / "bd"
        / "design_1"
        / "hw_handoff"
        / "design_1.hwh"
    )

    deliverable_name = deliverable_full_bit_name(full_rm).replace(".bit", ".hwh")
    return [
        bitstream.with_suffix(".hwh"),
        executable_dir / deliverable_name,
        executable_dir / "design_1.hwh",
        Path.cwd() / deliverable_name,
        Path.cwd() / "design_1.hwh",
        repo_relative,
        Path("..") / repo_relative,
        Path("final-project") / repo_relative,
    ]


def resolve_full_hwh(
    full_rm: str,
    bitstream: Path,
    executable_dir: Path,
    full_hwh_arg: str | None,
) -> Path:
    hwh = Path(full_hwh_arg).expanduser() if full_hwh_arg else first_existing(
        full_hwh_candidates(full_rm, bitstream, executable_dir)
    )
    if hwh is None or not hwh.exists():
        raise RuntimeError(
            "No full PWL DFX HWH metadata file found. Pass --full-hwh <path> or use the deliverables target."
        )

    return hwh.resolve()


def parse_partial_overrides(
    inline_partial_args: list[str],
    exp_partial_arg: str | None,
    sigmoid_partial_arg: str | None,
) -> dict[str, Path]:
    overrides: dict[str, Path] = {}
    if exp_partial_arg:
        overrides["exp"] = Path(exp_partial_arg).expanduser()
    if sigmoid_partial_arg:
        overrides["sigmoid"] = Path(sigmoid_partial_arg).expanduser()

    for item in inline_partial_args:
        if "=" not in item:
            raise RuntimeError(
                f"Invalid --partial-bit value '{item}'. Use the form <rm>=<path>."
            )
        rm_name, path_text = item.split("=", 1)
        overrides[canonical_rm_id(rm_name)] = Path(path_text).expanduser()

    return overrides


def resolve_partial_bitstreams(
    executable_dir: Path,
    requested_rms: list[str],
    partial_overrides: dict[str, Path],
) -> dict[str, Path]:
    partials = {}
    for rm in requested_rms:
        override_path = partial_overrides.get(rm)
        partials[rm] = override_path if override_path is not None else first_existing(
            partial_bitstream_candidates(rm, executable_dir)
        )

    missing = [rm for rm, path in partials.items() if path is None or not path.exists()]
    if missing:
        raise RuntimeError(
            "Missing partial bitstream(s) for "
            f"{', '.join(missing)}. Pass --partial-bit <rm>=<path> or use the deliverables target."
        )

    return {rm: path.resolve() for rm, path in partials.items()}


def requested_sequence(full_rm: str, run: str) -> list[str]:
    full_rm_id = canonical_rm_id(full_rm)
    normalized = normalize_name(run)
    if normalized == "both":
        return [full_rm_id, companion_rm_id(full_rm_id)]
    if normalized == "all":
        return list(DUT_CONFIG)

    requested: list[str] = []
    for token in run.replace(",", " ").split():
        rm_id = canonical_rm_id(token)
        if rm_id not in requested:
            requested.append(rm_id)
    if not requested:
        raise RuntimeError("At least one RM must be selected with --run.")
    return requested


def build_input_samples(num_samples: int, np_module):
    if num_samples <= 0:
        raise RuntimeError("--num-samples must be greater than zero.")
    if num_samples == 1:
        return [0.0]
    return np_module.linspace(PWL_MIN_X, PWL_MAX_X, num=num_samples, dtype=np_module.float32).tolist()


def average(values: list[float]) -> float | None:
    if not values:
        return None
    return sum(values) / len(values)


def read_optional_text(path: Path) -> str | None:
    try:
        return path.read_text(encoding="utf-8").strip()
    except OSError:
        return None


def preferred_priority(normalized_name: str, hints: tuple[str, ...], default_priority: int) -> int:
    priority = default_priority
    for index, hint in enumerate(hints):
        if normalized_name == hint:
            return index
        if hint in normalized_name:
            priority = min(priority, 10 + index)
    return priority


def make_pynq_power_targets(rails: dict[str, object]) -> list[PowerTarget]:
    targets: list[PowerTarget] = []
    for name, rail in rails.items():
        normalized = normalize_name(name)
        targets.append(
            PowerTarget(
                display_name=f"pynq:{name}",
                reader=rail,
                source="pynq",
                aliases=(name,),
                auto_priority=preferred_priority(normalized, AUTO_POWER_RAIL_HINTS, 100),
            )
        )
    return targets


def extract_hwmon_index(filename: str, prefix: str) -> str | None:
    suffix = filename.removeprefix(prefix).removesuffix("_input")
    return suffix if suffix.isdigit() else None


def discover_hwmon_power_targets() -> list[PowerTarget]:
    if not HWMON_ROOT.exists():
        return []

    targets: list[PowerTarget] = []
    for hwmon_dir in sorted(HWMON_ROOT.glob("hwmon*")):
        real_dir = hwmon_dir.resolve()
        sensor_name = read_optional_text(real_dir / "name") or hwmon_dir.name
        normalized_sensor = normalize_name(sensor_name)
        auto_priority = preferred_priority(normalized_sensor, AUTO_HWMON_HINTS, 200)

        power_paths = sorted(real_dir.glob("power*_input"))
        for power_path in power_paths:
            label = power_path.name
            reader = HwmonRail(sensor_name=sensor_name, label=label, power_path=power_path)
            targets.append(
                PowerTarget(
                    display_name=f"hwmon:{sensor_name}:{label}",
                    reader=reader,
                    source="hwmon",
                    aliases=(
                        sensor_name,
                        hwmon_dir.name,
                        f"{sensor_name}/{label}",
                        f"{hwmon_dir.name}/{label}",
                        str(power_path),
                    ),
                    auto_priority=auto_priority,
                )
            )

        if power_paths:
            continue

        current_paths = sorted(real_dir.glob("curr*_input"))
        for current_path in current_paths:
            index = extract_hwmon_index(current_path.name, "curr")
            if index is None:
                continue
            voltage_path = real_dir / f"in{index}_input"
            if not voltage_path.exists():
                continue

            label = f"{current_path.name}+{voltage_path.name}"
            reader = HwmonRail(
                sensor_name=sensor_name,
                label=label,
                voltage_path=voltage_path,
                current_path=current_path,
            )
            targets.append(
                PowerTarget(
                    display_name=f"hwmon:{sensor_name}:{label}",
                    reader=reader,
                    source="hwmon",
                    aliases=(
                        sensor_name,
                        hwmon_dir.name,
                        f"{sensor_name}/{label}",
                        f"{hwmon_dir.name}/{label}",
                        str(current_path),
                        str(voltage_path),
                    ),
                    auto_priority=auto_priority + 20,
                )
            )

    return targets


def read_sensor_value(sensor) -> float | None:
    if sensor is None:
        return None

    value = getattr(sensor, "value", sensor)
    if callable(value):
        value = value()
    if value is None:
        return None
    return float(value)


def read_rail_power_watts(rail) -> float:
    power_value = read_sensor_value(getattr(rail, "power", None))
    if power_value is not None:
        return power_value

    voltage_value = read_sensor_value(getattr(rail, "voltage", None))
    current_value = read_sensor_value(getattr(rail, "current", None))
    if voltage_value is not None and current_value is not None:
        return voltage_value * current_value

    raise RuntimeError("Selected rail does not expose readable power or voltage/current sensors.")


def get_rails_dict(get_rails_fn) -> dict[str, object]:
    rails = get_rails_fn()
    if hasattr(rails, "items"):
        return dict(rails.items())
    return dict(rails)


def resolve_power_target(power_targets: list[PowerTarget], requested_name: str | None) -> PowerTarget | None:
    if not power_targets:
        if requested_name:
            raise RuntimeError(
                f"Requested power source '{requested_name}' was not found because no power sources are available."
            )
        return None

    if requested_name:
        requested_token = normalize_name(requested_name)
        matches = []
        for target in power_targets:
            candidates = (target.display_name,) + target.aliases
            if any(normalize_name(candidate) == requested_token for candidate in candidates):
                matches.append(target)

        if len(matches) == 1:
            return matches[0]
        if len(matches) > 1:
            raise RuntimeError(
                f"Requested power source '{requested_name}' is ambiguous. "
                f"Use one of: {', '.join(sorted(target.display_name for target in matches))}"
            )

        available = ", ".join(sorted(target.display_name for target in power_targets))
        raise RuntimeError(
            f"Requested power source '{requested_name}' was not found. Available sources: {available}"
        )

    return min(power_targets, key=lambda target: (target.auto_priority, target.display_name))


class RailSampler(threading.Thread):
    def __init__(self, rail, interval_seconds: float):
        super().__init__(daemon=True)
        self.rail = rail
        self.interval_seconds = interval_seconds
        self.samples: list[float] = []
        self.error: Exception | None = None
        self._stop_event = threading.Event()

    def run(self) -> None:
        while not self._stop_event.is_set():
            try:
                self.samples.append(read_rail_power_watts(self.rail))
            except Exception as exc:  # pragma: no cover - hardware-specific runtime path
                self.error = exc
                self._stop_event.set()
                break
            self._stop_event.wait(self.interval_seconds)

    def stop(self) -> None:
        self._stop_event.set()


def collect_power_samples(rail, duration_seconds: float, interval_seconds: float) -> list[float]:
    deadline = time.monotonic() + duration_seconds
    samples: list[float] = []

    while True:
        samples.append(read_rail_power_watts(rail))
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            break
        time.sleep(min(interval_seconds, remaining))

    return samples


def should_print_iteration(iteration_index: int, total_iterations: int) -> bool:
    if total_iterations <= 10:
        return True
    if iteration_index == 0 or iteration_index == total_iterations - 1:
        return True

    step = max(1, total_iterations // 10)
    return (iteration_index + 1) % step == 0


def print_stage_power_summary(
    rm: str,
    stage_name: str,
    source_name: str,
    idle_power_avgs: list[float],
    active_power_avgs: list[float],
    delta_power_avgs: list[float],
    idle_sample_counts: list[int],
    active_sample_counts: list[int],
    duration_seconds: list[float],
    duration_field_name: str = "avg_active_window_ms",
    extra_fields: dict[str, float] | None = None,
) -> str:
    idle_avg = average(idle_power_avgs)
    active_avg = average(active_power_avgs)
    delta_avg = average(delta_power_avgs)
    avg_idle_samples = average([float(count) for count in idle_sample_counts])
    avg_active_samples = average([float(count) for count in active_sample_counts])
    avg_duration = average(duration_seconds)

    if idle_avg is None or active_avg is None or delta_avg is None or avg_duration is None:
        summary = f"{rm} {stage_name} power summary: insufficient samples on source {source_name}"
        print(summary, flush=True)
        return summary

    summary = (
        f"{rm} {stage_name} power summary"
        f" source={source_name}"
        f" iterations={len(duration_seconds)}"
        f" avg_idle_w={idle_avg:.6f}"
        f" avg_active_w={active_avg:.6f}"
        f" avg_delta_w={delta_avg:.6f}"
        f" avg_idle_samples={avg_idle_samples:.2f}"
        f" avg_active_samples={avg_active_samples:.2f}"
        f" {duration_field_name}={avg_duration * 1e3:.3f}"
    )
    if extra_fields:
        for key, value in extra_fields.items():
            if key.endswith("_cycles"):
                summary += f" {key}={value:.2f}"
            elif key.endswith("_ms"):
                summary += f" {key}={value:.3f}"
            else:
                summary += f" {key}={value:.6f}"
    print(summary, flush=True)
    return summary


def float_to_u32(value: float) -> int:
    return struct.unpack("<I", struct.pack("<f", float(value)))[0]


def u32_to_float(value: int) -> float:
    return struct.unpack("<f", struct.pack("<I", int(value) & 0xFFFFFFFF))[0]


def float_to_u16(value: float) -> int:
    return struct.unpack("<H", struct.pack("<e", float(value)))[0]


def u16_to_float(value: int) -> float:
    return struct.unpack("<e", struct.pack("<H", int(value) & 0xFFFF))[0]


def scalar_to_raw(value: float, precision_bits: int) -> int:
    if precision_bits == 32:
        return float_to_u32(value)
    if precision_bits == 16:
        return float_to_u16(value)
    raise RuntimeError(f"Unsupported precision {precision_bits} bits.")


def raw_to_scalar(value: int, precision_bits: int) -> float:
    if precision_bits == 32:
        return u32_to_float(value)
    if precision_bits == 16:
        return u16_to_float(value)
    raise RuntimeError(f"Unsupported precision {precision_bits} bits.")


def prepare_packed_io(samples: list[float], rm: str) -> PackedIoPlan:
    rm_id = canonical_rm_id(rm)
    precision_bits = int(DUT_CONFIG[rm_id]["precision_bits"])
    packets_per_word = 32 // precision_bits
    logical_count = len(samples)
    padded_count = ((logical_count + packets_per_word - 1) // packets_per_word) * packets_per_word
    padded_samples = list(samples)
    if padded_count > logical_count:
        padded_samples.extend([0.0] * (padded_count - logical_count))

    mask = (1 << precision_bits) - 1
    input_words: list[int] = []
    for base in range(0, padded_count, packets_per_word):
        word = 0
        for packet_index in range(packets_per_word):
            raw_value = scalar_to_raw(padded_samples[base + packet_index], precision_bits)
            word |= (raw_value & mask) << (packet_index * precision_bits)
        input_words.append(word)

    return PackedIoPlan(
        input_words=input_words,
        logical_count=logical_count,
        padded_count=padded_count,
        word_count=len(input_words),
        precision_bits=precision_bits,
    )


def unpack_output_words(output_buffer, logical_count: int, precision_bits: int) -> list[float]:
    packets_per_word = 32 // precision_bits
    mask = (1 << precision_bits) - 1
    values: list[float] = []
    for raw_word in output_buffer:
        word = int(raw_word)
        for packet_index in range(packets_per_word):
            if len(values) >= logical_count:
                return values
            raw_value = (word >> (packet_index * precision_bits)) & mask
            values.append(raw_to_scalar(raw_value, precision_bits))
    return values


def buffer_address(buffer) -> int:
    for attr_name in ("physical_address", "device_address"):
        value = getattr(buffer, attr_name, None)
        if value is not None:
            return int(value)
    raise RuntimeError("Allocated PYNQ buffer does not expose a physical/device address.")


def sync_buffer_to_device(buffer) -> None:
    for method_name in ("sync_to_device", "flush"):
        method = getattr(buffer, method_name, None)
        if callable(method):
            method()
            return


def sync_buffer_from_device(buffer) -> None:
    for method_name in ("sync_from_device", "invalidate"):
        method = getattr(buffer, method_name, None)
        if callable(method):
            method()
            return


def close_buffer(buffer) -> None:
    for method_name in ("close", "freebuffer"):
        method = getattr(buffer, method_name, None)
        if callable(method):
            method()
            return


def warn_if_address_outside_ddr(name: str, address: int) -> None:
    if address > DDR_HIGH_ADDR:
        print(
            f"WARNING: {name} buffer address 0x{address:016x} is outside the current RP DDR aperture "
            f"(0x00000000..0x{DDR_HIGH_ADDR:08x}).",
            file=sys.stderr,
        )


class DfxControl:
    def __init__(self, shutdown_mmio, reset_mmio, gpio_timeout: float, debug: bool = False):
        self._shutdown = shutdown_mmio
        self._reset = reset_mmio
        self._timeout = gpio_timeout
        self._debug = debug
        self._configure_directions()

    def _configure_directions(self) -> None:
        debug_print(self._debug, "Configuring GPIO directions for shutdown/reset control.")
        self._shutdown.write(GPIO_TRI_OFFSET, 0x0)
        self._shutdown.write(GPIO2_TRI_OFFSET, 0xFFFFFFFF)
        self._reset.write(GPIO_TRI_OFFSET, 0x0)

    def read_shutdown_request(self) -> int:
        return self._shutdown.read(GPIO_DATA_OFFSET) & 0x1

    def read_shutdown_channel2(self) -> int:
        return self._shutdown.read(GPIO2_DATA_OFFSET) & 0xFFFFFFFF

    def read_shutdown_status(self) -> int:
        return self.read_shutdown_channel2() & SHUTDOWN_STATUS_MASK

    def read_last_reconfiguration_cycles(self) -> int:
        return (self.read_shutdown_channel2() >> RECONFIG_LATENCY_SHIFT) & RECONFIG_LATENCY_MASK

    def read_resetn(self) -> int:
        return self._reset.read(GPIO_DATA_OFFSET) & 0x1

    def write_shutdown_request(self, level: int) -> None:
        self._shutdown.write(GPIO_DATA_OFFSET, level & 0x1)

    def write_resetn(self, level: int) -> None:
        self._reset.write(GPIO_DATA_OFFSET, level & 0x1)

    def wait_for_shutdown_status(self, expected_level: int) -> None:
        debug_print(self._debug, f"Waiting for shutdown status to reach {expected_level & 0x1}.")
        deadline = time.monotonic() + self._timeout
        last_report = 0.0
        while time.monotonic() < deadline:
            status = self.read_shutdown_status()
            if status == (expected_level & 0x1):
                debug_print(self._debug, f"Shutdown status reached {status}.")
                return
            now = time.monotonic()
            if self._debug and (now - last_report) >= 0.25:
                debug_print(
                    True,
                    "Shutdown wait in progress: "
                    f"request={self.read_shutdown_request()} status={status} resetn={self.read_resetn()}",
                )
                last_report = now
            time.sleep(0.001)
        raise RuntimeError(
            f"Timed out waiting for shutdown status to reach {expected_level & 0x1}."
        )

    def bring_region_online(self) -> None:
        debug_print(self._debug, "Bringing reconfigurable region online.")
        self.write_resetn(RESET_RELEASE_LEVEL)
        self.write_shutdown_request(SHUTDOWN_RELEASE_LEVEL)
        self.wait_for_shutdown_status(SHUTDOWN_RELEASE_LEVEL)

    def prepare_for_reconfiguration(self) -> None:
        debug_print(self._debug, "Preparing reconfigurable region for partial reconfiguration.")
        self.write_shutdown_request(SHUTDOWN_ASSERT_LEVEL)
        self.wait_for_shutdown_status(SHUTDOWN_ASSERT_LEVEL)
        self.write_resetn(RESET_ASSERT_LEVEL)

    def resume_after_reconfiguration(self) -> None:
        debug_print(self._debug, "Resuming reconfigurable region after partial reconfiguration.")
        self.write_resetn(RESET_RELEASE_LEVEL)
        self.write_shutdown_request(SHUTDOWN_RELEASE_LEVEL)
        self.wait_for_shutdown_status(SHUTDOWN_RELEASE_LEVEL)

    def ensure_region_ready(self) -> None:
        if self.read_resetn() != RESET_RELEASE_LEVEL:
            raise RuntimeError("RP reset is still asserted; the reconfigurable region is not ready.")
        if self.read_shutdown_request() != SHUTDOWN_RELEASE_LEVEL:
            raise RuntimeError("Shutdown request is still asserted; the reconfigurable region is isolated.")
        if self.read_shutdown_status() != SHUTDOWN_RELEASE_LEVEL:
            raise RuntimeError("Shutdown status is still asserted; the reconfigurable region is isolated.")


class HlsKernelControl:
    def __init__(self, mmio, timeout_seconds: float, debug: bool = False):
        self._mmio = mmio
        self._timeout_seconds = timeout_seconds
        self._debug = debug

    def _write_u64(self, low_offset: int, high_offset: int, value: int) -> None:
        self._mmio.write(low_offset, value & 0xFFFFFFFF)
        self._mmio.write(high_offset, (value >> 32) & 0xFFFFFFFF)

    def _continue(self) -> None:
        ctrl = self._mmio.read(HLS_AP_CTRL)
        self._mmio.write(HLS_AP_CTRL, (ctrl & AUTO_RESTART) | AP_CONTINUE)

    def _wait_for_mask(self, required_mask: int, description: str) -> int:
        deadline = time.monotonic() + self._timeout_seconds
        last_ctrl = 0
        last_report = 0.0
        while time.monotonic() < deadline:
            last_ctrl = self._mmio.read(HLS_AP_CTRL)
            if last_ctrl & required_mask:
                return last_ctrl
            now = time.monotonic()
            if self._debug and (now - last_report) >= 0.25:
                debug_print(True, f"Kernel waiting for {description}, control register = 0x{last_ctrl:08x}")
                last_report = now
            time.sleep(0.001)
        raise RuntimeError(
            f"Timed out waiting for kernel {description}. Last control register value: 0x{last_ctrl:08x}"
        )

    def start(self, input_addr: int, output_addr: int, size: int) -> None:
        debug_print(
            self._debug,
            "Starting kernel: "
            f"in=0x{input_addr:016x} out=0x{output_addr:016x} size={size}",
        )
        self._wait_for_mask(AP_IDLE, "idle before launch")
        self._write_u64(HLS_IN_PTR_LO, HLS_IN_PTR_HI, input_addr)
        self._write_u64(HLS_OUT_PTR_LO, HLS_OUT_PTR_HI, output_addr)
        self._write_u64(HLS_SIZE_LO, HLS_SIZE_HI, size)
        self._mmio.write(HLS_GIE, 0)
        self._mmio.write(HLS_IER, 0)
        self._mmio.write(HLS_ISR, 0)
        self._mmio.read(HLS_AP_CTRL)
        self._mmio.write(HLS_AP_CTRL, AP_START)

    def wait_done(self) -> int:
        debug_print(self._debug, "Polling kernel control register for completion.")
        last_ctrl = self._wait_for_mask(AP_DONE, "completion")
        self._continue()
        self._wait_for_mask(AP_IDLE, "idle after completion")
        debug_print(self._debug, f"Kernel completed with control register 0x{last_ctrl:08x}.")
        return last_ctrl


def sanitize_full_hwh(original_hwh: Path, sanitized_hwh: Path) -> None:
    tree = ET.parse(original_hwh)
    root = tree.getroot()
    removed_memranges = 0
    removed_busifs = 0

    for memory_map in root.iter("MEMORYMAP"):
        for memrange in list(memory_map.findall("MEMRANGE")):
            if (
                memrange.get("INSTANCE") == "rp_s_axi_control"
                or memrange.get("SLAVEBUSINTERFACE") == "rp_s_axi_control"
            ):
                memory_map.remove(memrange)
                removed_memranges += 1

    for businterfaces in root.iter("BUSINTERFACES"):
        for busif in list(businterfaces.findall("BUSINTERFACE")):
            if busif.get("NAME") == "rp_s_axi_control":
                businterfaces.remove(busif)
                removed_busifs += 1

    if removed_memranges == 0 and removed_busifs == 0:
        raise RuntimeError(
            "Expected to sanitize rp_s_axi_control from the full HWH, but no matching "
            "BUSINTERFACE or MEMORYMAP entry was found."
        )

    tree.write(sanitized_hwh, encoding="utf-8", xml_declaration=True)


def stage_overlay_files(bitstream: Path, hwh: Path, debug: bool = False) -> tuple[tempfile.TemporaryDirectory[str], Path]:
    temp_dir = tempfile.TemporaryDirectory(prefix="pwl_dfx_full_")
    staged_bit = Path(temp_dir.name) / bitstream.name
    staged_hwh = staged_bit.with_suffix(".hwh")

    debug_print(debug, f"Staging full bitstream into temporary overlay directory {temp_dir.name}")
    shutil.copy2(bitstream, staged_bit)
    sanitize_full_hwh(hwh, staged_hwh)
    debug_print(debug, f"Sanitized HWH staged at {staged_hwh}")
    return temp_dir, staged_bit


def bitstream_payload_to_bin(bit_path: Path) -> bytes:
    contents = bit_path.read_bytes()
    offset = 0

    if len(contents) < 4:
        raise RuntimeError(f"Bitstream header is too short: {bit_path}")

    length = struct.unpack(">h", contents[offset : offset + 2])[0]
    offset += 2 + length
    offset += 2

    while offset < len(contents):
        desc = contents[offset]
        offset += 1

        if desc == 0x65:
            payload_length = struct.unpack(">i", contents[offset : offset + 4])[0]
            offset += 4
            payload = contents[offset : offset + payload_length]
            if len(payload) != payload_length:
                raise RuntimeError(f"Bitstream payload is truncated: {bit_path}")
            if payload_length % 4 != 0:
                raise RuntimeError(
                    f"Bitstream payload length is not word-aligned ({payload_length} bytes): {bit_path}"
                )

            swapped = bytearray(payload_length)
            for index in range(0, payload_length, 4):
                swapped[index : index + 4] = payload[index : index + 4][::-1]
            return bytes(swapped)

        field_length = struct.unpack(">h", contents[offset : offset + 2])[0]
        offset += 2 + field_length

    raise RuntimeError(f"Failed to find the bitstream payload marker in {bit_path}")


def stage_fpga_manager_firmware(bitstream: Path, debug: bool = False) -> Path:
    if not FPGA_MANAGER_FIRMWARE_DIR.exists():
        raise RuntimeError(
            f"fpga_manager firmware directory is not available: {FPGA_MANAGER_FIRMWARE_DIR}"
        )

    firmware_name = f"pwl_dfx_full_{os.getpid()}_{int(time.time() * 1000)}.bin"
    firmware_path = FPGA_MANAGER_FIRMWARE_DIR / firmware_name
    debug_print(debug, f"Converting {bitstream} into {firmware_path} for fpga_manager.")
    firmware_path.write_bytes(bitstream_payload_to_bin(bitstream))
    return firmware_path


def program_full_via_fpga_manager(bitstream: Path, debug: bool = False) -> Path:
    if not FPGA_MANAGER_FLAGS.exists() or not FPGA_MANAGER_FIRMWARE.exists():
        raise RuntimeError("fpga_manager sysfs controls are not available on this platform.")

    firmware_path = stage_fpga_manager_firmware(bitstream, debug=debug)
    debug_print(debug, f"Programming full bitstream through fpga_manager using {firmware_path.name}")
    FPGA_MANAGER_FLAGS.write_text("0", encoding="ascii")
    FPGA_MANAGER_FIRMWARE.write_text(firmware_path.name, encoding="ascii")
    debug_print(debug, "fpga_manager full bitstream programming request completed.")
    return firmware_path


def create_overlay_metadata(overlay_bit: Path, program: bool, debug: bool = False):
    from pynq import Overlay

    if program:
        debug_print(debug, f"Creating Overlay from {overlay_bit}")
        return Overlay(str(overlay_bit), download=True)

    debug_print(debug, f"Parsing Overlay metadata from {overlay_bit} without programming the PL")
    overlay = Overlay(str(overlay_bit), download=False)
    overlay_device = getattr(overlay, "device", None)
    overlay_parser = getattr(overlay, "parser", None)
    overlay_bit_name = getattr(overlay, "bitfile_name", str(overlay_bit))
    if overlay_device is not None and overlay_parser is not None and hasattr(overlay_device, "reset"):
        debug_print(debug, "Refreshing PYNQ device metadata without a full Overlay download.")
        overlay_device.reset(parser=overlay_parser, bitfile_name=overlay_bit_name)
    return overlay


def load_partial_bitstream(partial_bit: Path, debug: bool = False) -> None:
    from pynq.bitstream import Bitstream

    debug_print(debug, f"Downloading partial bitstream: {partial_bit}")
    Bitstream(str(partial_bit), partial=True).download()
    debug_print(debug, "Partial bitstream download finished.")


def run_rm_test(
    rm: str,
    kernel: HlsKernelControl,
    input_buf,
    output_buf,
    samples: list[float],
    packed_plan: PackedIoPlan,
    dfx_control: DfxControl,
    print_samples: bool = True,
    debug: bool = False,
) -> RmTestMetrics:
    rm_id = canonical_rm_id(rm)
    spec = DUT_CONFIG[rm_id]
    print(
        f"Running smoke test for rm={rm_id} ({spec['display_name']}) "
        f"with {len(samples)} logical samples",
        flush=True,
    )
    dfx_control.ensure_region_ready()

    debug_print(debug, "Writing input samples into the PYNQ buffer.")
    for index, word in enumerate(packed_plan.input_words):
        input_buf[index] = word
    output_buf[:] = 0

    debug_print(debug, "Synchronizing input/output buffers to the device.")
    sync_buffer_to_device(input_buf)
    sync_buffer_to_device(output_buf)

    input_addr = buffer_address(input_buf)
    output_addr = buffer_address(output_buf)
    warn_if_address_outside_ddr("input", input_addr)
    warn_if_address_outside_ddr("output", output_addr)

    kernel_start = time.monotonic()
    kernel.start(input_addr, output_addr, packed_plan.padded_count)
    kernel.wait_done()
    kernel_seconds = time.monotonic() - kernel_start
    debug_print(debug, "Kernel reported done, invalidating output buffer.")
    sync_buffer_from_device(output_buf)

    output_values = unpack_output_words(output_buf, packed_plan.logical_count, packed_plan.precision_bits)
    atol, rtol = tolerances(rm_id)
    all_passed = True
    total_error = 0.0
    max_error = 0.0
    sample_lines: list[str] = []
    validation_start = time.monotonic()

    for index, raw_x in enumerate(samples):
        x = float(raw_x)
        expected = expected_value(rm_id, x)
        actual = float(output_values[index])
        error = abs(actual - expected)
        passed = within_tolerance(expected, actual, atol, rtol)
        all_passed &= passed
        total_error += error
        max_error = max(max_error, error)

        sample_lines.append(
            f"{rm} sample[{index:02d}]"
            f" x={x: .6f}"
            f" expected={expected: .6f}"
            f" actual={actual: .6f}"
            f" abs_err={error: .6f}"
            f" {'PASS' if passed else 'FAIL'}"
        )

    if print_samples or not all_passed:
        for line in sample_lines:
            print(line, flush=True)

    mean_error = total_error / len(samples)
    print(
        f"{rm} summary: mean_abs_error={mean_error:.6f} "
        f"max_abs_error={max_error:.6f} atol={atol:.6f} rtol={rtol:.6f}",
        flush=True,
    )
    validation_seconds = time.monotonic() - validation_start
    return RmTestMetrics(
        passed=all_passed,
        mean_error=mean_error,
        max_error=max_error,
        kernel_seconds=kernel_seconds,
        validation_seconds=validation_seconds,
    )


def main() -> int:
    args = parse_args()
    executable_dir = get_executable_dir(sys.argv[0])
    summary_path = (
        Path(args.summary_file).expanduser()
        if args.summary_file
        else default_summary_path(sys.argv[0], executable_dir)
    )
    try:
        full_rm_id = canonical_rm_id(args.full_rm)
        sequence = requested_sequence(full_rm_id, args.run)
        partial_overrides = parse_partial_overrides(
            args.partial_bit,
            args.exp_partial,
            args.sigmoid_partial,
        )
    except (ValueError, RuntimeError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1

    temp_overlay_dir = None
    staged_firmware_path = None
    summary_lines = [
        f"Summary generated: {time.strftime('%Y-%m-%d %H:%M:%S')}",
        f"Application: {Path(sys.argv[0]).name}",
        f"Summary file: {summary_path}",
        f"Full RM: {full_rm_id}",
        f"Run sequence: {', '.join(sequence)}",
    ]

    try:
        try:
            import numpy as np
            from pynq import MMIO, Overlay, allocate
            try:
                from pynq import get_rails
            except ImportError:
                get_rails = None
        except ImportError as exc:
            raise RuntimeError(
                "This application requires both numpy and the pynq Python package."
            ) from exc

        power_targets: list[PowerTarget] = []
        if get_rails is not None:
            power_targets.extend(make_pynq_power_targets(get_rails_dict(get_rails)))
        power_targets.extend(discover_hwmon_power_targets())

        if args.list_rails:
            if power_targets:
                print("Available power sources:")
                for target in sorted(power_targets, key=lambda item: item.display_name):
                    print(f"  {target.display_name}")
            else:
                print("No PYNQ rails or hwmon power sources were reported by this environment.")
            return 0

        selected_power_target = resolve_power_target(power_targets, args.power_rail)
        power_source_name = selected_power_target.display_name if selected_power_target is not None else None
        rail = selected_power_target.reader if selected_power_target is not None else None

        full_bitstream = resolve_full_bitstream(full_rm_id, executable_dir, args.full_bitstream)
        full_hwh = resolve_full_hwh(full_rm_id, full_bitstream, executable_dir, args.full_hwh)
        partials = resolve_partial_bitstreams(executable_dir, sequence, partial_overrides)

        print(f"Full RM: {full_rm_id}")
        print(f"Run sequence: {', '.join(sequence)}")
        print(f"Iterations per RM: {args.iterations}")
        print(f"Full bitstream: {full_bitstream}")
        print(f"Full HWH: {full_hwh}")
        for rm_name in sequence:
            print(f"{rm_name} partial: {partials[rm_name]}")
        print(f"Reset GPIO addr: 0x{args.reset_gpio_addr:08x}")
        print(f"Shutdown GPIO addr: 0x{args.shutdown_gpio_addr:08x}")
        print(f"Kernel control addr: 0x{args.control_addr:08x}")
        print(f"Full programmer: {args.full_programmer}")
        print(f"Programming full design: {'no' if args.no_program else 'yes'}")
        summary_lines.extend(
            [
                f"Iterations per RM: {args.iterations}",
                f"Full bitstream: {full_bitstream}",
                f"Full HWH: {full_hwh}",
                f"Full programmer: {args.full_programmer}",
                f"Programming full design: {'no' if args.no_program else 'yes'}",
            ]
        )
        for rm_name in sequence:
            summary_lines.append(f"{rm_name} partial: {partials[rm_name]}")
        if power_source_name is not None:
            print(f"Power source: {power_source_name} ({selected_power_target.source})")
            print(
                f"Power windows: idle_s={args.idle_power_seconds:.3f} "
                f"reconfig_sample_interval_s={args.power_sample_interval:.3f} "
                f"post_reconfig_stabilize_s={args.post_reconfig_stabilize_seconds:.3f}",
                flush=True,
            )
            summary_lines.append(f"Power source: {power_source_name} ({selected_power_target.source})")
        else:
            print(
                "Power source: unavailable "
                "(no matching PYNQ rail or hwmon sensor was found; use --list-rails to inspect)",
                flush=True,
            )
            summary_lines.append("Power source: unavailable")

        debug_print(args.debug, "Building software input samples.")
        samples = build_input_samples(args.num_samples, np)
        summary_lines.append(f"Input count: {len(samples)}")
        temp_overlay_dir, overlay_bit = stage_overlay_files(full_bitstream, full_hwh, debug=args.debug)
        if args.no_program:
            debug_print(
                args.debug,
                "Skipping full overlay metadata parsing because --no-program uses direct MMIO/Bitstream control.",
            )
        elif args.full_programmer == "fpga_manager":
            staged_firmware_path = program_full_via_fpga_manager(full_bitstream, debug=args.debug)
            debug_print(
                args.debug,
                "Skipping Overlay metadata parsing after fpga_manager programming because the app uses direct MMIO/Bitstream control.",
            )
        else:
            create_overlay_metadata(overlay_bit, program=True, debug=args.debug)

        debug_print(args.debug, "Creating MMIO mappings.")
        shutdown_mmio = MMIO(args.shutdown_gpio_addr, args.mmio_range)
        reset_mmio = MMIO(args.reset_gpio_addr, args.mmio_range)
        kernel_mmio = MMIO(args.control_addr, args.mmio_range)

        dfx_control = DfxControl(shutdown_mmio, reset_mmio, args.gpio_timeout, debug=args.debug)
        kernel = HlsKernelControl(kernel_mmio, args.kernel_timeout, debug=args.debug)
        dfx_control.bring_region_online()

        all_passed = True

        for target_rm in sequence:
            spec = DUT_CONFIG[target_rm]
            packed_plan = prepare_packed_io(samples, target_rm)
            debug_print(
                args.debug,
                f"Allocating {packed_plan.word_count} packed words for rm={target_rm} "
                f"({packed_plan.logical_count} logical samples, padded_count={packed_plan.padded_count}).",
            )
            print(
                f"Testing RM {target_rm} ({spec['display_name']}) for {args.iterations} iteration(s).",
                flush=True,
            )
            if packed_plan.padded_count != packed_plan.logical_count:
                print(
                    f"{target_rm} packs {packed_plan.logical_count} logical samples into "
                    f"{packed_plan.word_count} words using padded_count={packed_plan.padded_count}",
                    flush=True,
                )

            input_buf = allocate(shape=(packed_plan.word_count,), dtype=np.uint32)
            output_buf = allocate(shape=(packed_plan.word_count,), dtype=np.uint32)

            try:
                warn_if_address_outside_ddr("input", buffer_address(input_buf))
                warn_if_address_outside_ddr("output", buffer_address(output_buf))

                reconfig_idle_power_avgs: list[float] = []
                reconfig_active_power_avgs: list[float] = []
                reconfig_delta_power_avgs: list[float] = []
                reconfig_idle_sample_counts: list[int] = []
                reconfig_active_sample_counts: list[int] = []
                reconfig_duration_seconds: list[float] = []
                reconfig_latency_cycles: list[float] = []

                operation_idle_power_avgs: list[float] = []
                operation_active_power_avgs: list[float] = []
                operation_delta_power_avgs: list[float] = []
                operation_idle_sample_counts: list[int] = []
                operation_active_sample_counts: list[int] = []
                operation_active_window_seconds: list[float] = []
                operation_kernel_seconds: list[float] = []
                operation_validation_seconds: list[float] = []
                operation_host_overhead_seconds: list[float] = []
                operation_mean_errors: list[float] = []
                operation_max_errors: list[float] = []

                for iteration_index in range(args.iterations):
                    reconfig_idle_samples: list[float] = []
                    if rail is not None:
                        reconfig_idle_samples = collect_power_samples(
                            rail,
                            args.idle_power_seconds,
                            args.power_sample_interval,
                        )

                    reconfig_active_samples: list[float] = []
                    reconfig_sampler = RailSampler(rail, args.power_sample_interval) if rail is not None else None
                    reconfig_start = time.monotonic()
                    try:
                        if reconfig_sampler is not None:
                            reconfig_sampler.start()
                        dfx_control.prepare_for_reconfiguration()
                        load_partial_bitstream(partials[target_rm], debug=args.debug)
                        dfx_control.resume_after_reconfiguration()
                    finally:
                        if reconfig_sampler is not None:
                            reconfig_sampler.stop()
                            reconfig_sampler.join()
                            if reconfig_sampler.error is not None:
                                raise RuntimeError(
                                    f"Failed to sample reconfiguration power on '{power_source_name}': {reconfig_sampler.error}"
                                ) from reconfig_sampler.error
                            reconfig_active_samples = reconfig_sampler.samples

                    reconfig_elapsed = time.monotonic() - reconfig_start
                    reconfiguration_cycles = dfx_control.read_last_reconfiguration_cycles()
                    reconfig_duration_seconds.append(reconfig_elapsed)
                    reconfig_latency_cycles.append(float(reconfiguration_cycles))

                    reconfig_idle_avg = average(reconfig_idle_samples)
                    reconfig_active_avg = average(reconfig_active_samples)
                    reconfig_delta_avg = None
                    if reconfig_idle_avg is not None and reconfig_active_avg is not None:
                        reconfig_delta_avg = reconfig_active_avg - reconfig_idle_avg
                        reconfig_idle_power_avgs.append(reconfig_idle_avg)
                        reconfig_active_power_avgs.append(reconfig_active_avg)
                        reconfig_delta_power_avgs.append(reconfig_delta_avg)
                        reconfig_idle_sample_counts.append(len(reconfig_idle_samples))
                        reconfig_active_sample_counts.append(len(reconfig_active_samples))

                    print(
                        f"Partial reconfiguration iteration {iteration_index + 1}/{args.iterations}: "
                        f"active rm={target_rm} latency_cycles={reconfiguration_cycles}",
                        flush=True,
                    )

                    if args.post_reconfig_stabilize_seconds > 0.0:
                        time.sleep(args.post_reconfig_stabilize_seconds)

                    operation_idle_samples: list[float] = []
                    if rail is not None:
                        operation_idle_samples = collect_power_samples(
                            rail,
                            args.idle_power_seconds,
                            args.power_sample_interval,
                        )

                    operation_active_samples: list[float] = []
                    operation_sampler = RailSampler(rail, args.power_sample_interval) if rail is not None else None
                    operation_active_window = 0.0
                    try:
                        operation_start = time.monotonic()
                        if operation_sampler is not None:
                            operation_sampler.start()
                        test_metrics = run_rm_test(
                            target_rm,
                            kernel,
                            input_buf,
                            output_buf,
                            samples,
                            packed_plan,
                            dfx_control,
                            print_samples=(args.iterations == 1),
                            debug=args.debug,
                        )
                        operation_active_window = time.monotonic() - operation_start
                    finally:
                        if operation_sampler is not None:
                            operation_sampler.stop()
                            operation_sampler.join()
                            if operation_sampler.error is not None:
                                raise RuntimeError(
                                    f"Failed to sample operation power on '{power_source_name}': {operation_sampler.error}"
                                ) from operation_sampler.error
                            operation_active_samples = operation_sampler.samples

                    operation_host_overhead = max(
                        0.0,
                        operation_active_window - test_metrics.kernel_seconds - test_metrics.validation_seconds,
                    )
                    all_passed &= test_metrics.passed
                    operation_active_window_seconds.append(operation_active_window)
                    operation_kernel_seconds.append(test_metrics.kernel_seconds)
                    operation_validation_seconds.append(test_metrics.validation_seconds)
                    operation_host_overhead_seconds.append(operation_host_overhead)
                    operation_mean_errors.append(test_metrics.mean_error)
                    operation_max_errors.append(test_metrics.max_error)

                    operation_idle_avg = average(operation_idle_samples)
                    operation_active_avg = average(operation_active_samples)
                    operation_delta_avg = None
                    if operation_idle_avg is not None and operation_active_avg is not None:
                        operation_delta_avg = operation_active_avg - operation_idle_avg
                        operation_idle_power_avgs.append(operation_idle_avg)
                        operation_active_power_avgs.append(operation_active_avg)
                        operation_delta_power_avgs.append(operation_delta_avg)
                        operation_idle_sample_counts.append(len(operation_idle_samples))
                        operation_active_sample_counts.append(len(operation_active_samples))

                    if should_print_iteration(iteration_index, args.iterations) or not test_metrics.passed:
                        line = (
                            f"{target_rm} iteration {iteration_index + 1}/{args.iterations}"
                            f" latency_cycles={reconfiguration_cycles}"
                            f" reconfig_ms={reconfig_elapsed * 1e3:.3f}"
                            f" active_window_ms={operation_active_window * 1e3:.3f}"
                            f" kernel_ms={test_metrics.kernel_seconds * 1e3:.3f}"
                            f" validation_ms={test_metrics.validation_seconds * 1e3:.3f}"
                            f" host_overhead_ms={operation_host_overhead * 1e3:.3f}"
                            f" mean_abs_error={test_metrics.mean_error:.6f}"
                            f" max_abs_error={test_metrics.max_error:.6f}"
                        )
                        if reconfig_delta_avg is not None:
                            line += (
                                f" reconfig_idle_w={reconfig_idle_avg:.6f}"
                                f" reconfig_active_w={reconfig_active_avg:.6f}"
                                f" reconfig_delta_w={reconfig_delta_avg:.6f}"
                                f" reconfig_idle_samples={len(reconfig_idle_samples)}"
                                f" reconfig_active_samples={len(reconfig_active_samples)}"
                            )
                        if operation_delta_avg is not None:
                            line += (
                                f" op_idle_w={operation_idle_avg:.6f}"
                                f" op_active_w={operation_active_avg:.6f}"
                                f" op_delta_w={operation_delta_avg:.6f}"
                                f" op_idle_samples={len(operation_idle_samples)}"
                                f" op_active_samples={len(operation_active_samples)}"
                            )
                        line += f" {'PASS' if test_metrics.passed else 'FAIL'}"
                        print(line, flush=True)

                if power_source_name is not None:
                    reconfig_summary = print_stage_power_summary(
                        target_rm,
                        "reconfiguration",
                        power_source_name,
                        reconfig_idle_power_avgs,
                        reconfig_active_power_avgs,
                        reconfig_delta_power_avgs,
                        reconfig_idle_sample_counts,
                        reconfig_active_sample_counts,
                        reconfig_duration_seconds,
                        duration_field_name="avg_active_window_ms",
                        extra_fields={
                            "avg_latency_cycles": average(reconfig_latency_cycles) or 0.0,
                        },
                    )
                    operation_summary = print_stage_power_summary(
                        target_rm,
                        "operation",
                        power_source_name,
                        operation_idle_power_avgs,
                        operation_active_power_avgs,
                        operation_delta_power_avgs,
                        operation_idle_sample_counts,
                        operation_active_sample_counts,
                        operation_active_window_seconds,
                        duration_field_name="avg_active_window_ms",
                        extra_fields={
                            "avg_kernel_ms": (average(operation_kernel_seconds) or 0.0) * 1e3,
                            "avg_validation_ms": (average(operation_validation_seconds) or 0.0) * 1e3,
                            "avg_host_overhead_ms": (average(operation_host_overhead_seconds) or 0.0) * 1e3,
                            "avg_mean_abs_error": average(operation_mean_errors) or 0.0,
                            "avg_max_abs_error": average(operation_max_errors) or 0.0,
                        },
                    )
                    summary_lines.extend([reconfig_summary, operation_summary])
            finally:
                debug_print(args.debug, f"Releasing PYNQ buffers for rm={target_rm}.")
                close_buffer(output_buf)
                close_buffer(input_buf)

        if not all_passed:
            summary_lines.append("One or more PWL DFX checks failed.")
            saved_summary_path = save_summary_file(summary_path, summary_lines)
            print(f"Saved summary to {saved_summary_path}", flush=True)
            print("One or more PWL DFX checks failed.", file=sys.stderr)
            return 1

        summary_lines.append("All requested PWL DFX checks passed.")
        saved_summary_path = save_summary_file(summary_path, summary_lines)
        print(f"Saved summary to {saved_summary_path}", flush=True)
        print("All requested PWL DFX checks passed.", flush=True)
        return 0
    except Exception as exc:  # pylint: disable=broad-except
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    finally:
        if temp_overlay_dir is not None:
            temp_overlay_dir.cleanup()
        if staged_firmware_path is not None:
            try:
                staged_firmware_path.unlink()
            except OSError:
                pass


if __name__ == "__main__":
    raise SystemExit(main())
