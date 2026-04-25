#!/usr/bin/env python3
"""
PYNQ host application for the final-project PWL multi-DUT design.

This software targets the generated multi-DUT overlay:
  - AXI4-Lite control for `pwl_exp_0`
  - AXI4-Lite control for `pwl_sigmoid_0`
  - Shared PS-attached DDR through the HLS AXI master ports

Typical use:
  ./pwl_multi_dut_pynq.py
  ./pwl_multi_dut_pynq.py --dut exp
  ./pwl_multi_dut_pynq.py --dut sigmoid
  ./pwl_multi_dut_pynq.py --inputs=-8,-4,-1,0,1,4,8
  ./pwl_multi_dut_pynq.py --bitstream /path/to/design_1_wrapper.bit --hwh /path/to/design_1.hwh
  ./pwl_multi_dut_pynq.py --no-program
"""

from __future__ import annotations

import argparse
import math
import random
import shutil
import struct
import sys
import tempfile
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable


DEFAULT_PART_TAG = "xck26_sfvc784_2LV_c"
DEFAULT_INPUTS = (-8.0, -4.0, -1.0, -0.25, 0.0, 0.25, 1.0, 4.0, 8.0)
CONTROL_TIMEOUT_SECONDS = 5.0
DDR_HIGH_ADDR = 0x7FFFFFFF
DEFAULT_ITERATIONS = 1
DEFAULT_POWER_SAMPLE_INTERVAL_SECONDS = 0.02
DEFAULT_IDLE_POWER_SECONDS = 1.0
HWMON_ROOT = Path("/sys/class/hwmon")
MAX_PRINTED_INPUTS = 12
MAX_PRINTED_SAMPLE_LINES = 16
DEFAULT_EXP_DUT_ID = "exp"
DEFAULT_SIGMOID_DUT_ID = "sigmoid"

CTRL_OFFSET = 0x00
IN_R_1_OFFSET = 0x10
IN_R_2_OFFSET = 0x14
OUT_R_1_OFFSET = 0x1C
OUT_R_2_OFFSET = 0x20
SIZE_1_OFFSET = 0x28
SIZE_2_OFFSET = 0x2C

AP_START_MASK = 1 << 0
AP_DONE_MASK = 1 << 1
AP_IDLE_MASK = 1 << 2
AP_CONTINUE_MASK = 1 << 4
AUTO_RESTART_MASK = 1 << 7

DUT_CONFIG = {
    "exp": {
        "function": "exp",
        "display_name": "Nonuniform exponential Float32",
        "ip_name": "pwl_exp_0",
        "type_fragment": "pwl_pwl_nonuniform_pwl_function_exponential_use_float32",
        "precision_bits": 32,
        "min_x": -8.0,
        "max_x": 8.0,
        "atol": 0.25,
        "rtol": 0.03,
    },
    "exp_f16": {
        "function": "exp",
        "display_name": "Nonuniform exponential Float16",
        "ip_name": "pwl_exp_0",
        "type_fragment": "pwl_pwl_nonuniform_pwl_function_exponential_use_float16",
        "precision_bits": 16,
        "min_x": -8.0,
        "max_x": 8.0,
        "atol": 1.0,
        "rtol": 0.05,
    },
    "sigmoid": {
        "function": "sigmoid",
        "display_name": "Nonuniform sigmoid Float32",
        "ip_name": "pwl_sigmoid_0",
        "type_fragment": "pwl_pwl_nonuniform_pwl_function_sigmoid_use_float32",
        "precision_bits": 32,
        "min_x": -8.0,
        "max_x": 8.0,
        "atol": 0.01,
        "rtol": 0.03,
    },
    "sigmoid_f16": {
        "function": "sigmoid",
        "display_name": "Nonuniform sigmoid Float16",
        "ip_name": "pwl_sigmoid_0",
        "type_fragment": "pwl_pwl_nonuniform_pwl_function_sigmoid_use_float16",
        "precision_bits": 16,
        "min_x": -8.0,
        "max_x": 8.0,
        "atol": 0.02,
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


def canonical_dut_id(dut_id: str, function_name: str | None = None) -> str:
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

    normalized = normalize_name(dut_id)
    resolved = alias_map.get(normalized)
    if resolved is None:
        supported = ", ".join(sorted(DUT_CONFIG))
        raise ValueError(f"Unsupported DUT id '{dut_id}'. Supported DUT ids: {supported}")

    if function_name is not None and DUT_CONFIG[resolved]["function"] != function_name:
        supported = ", ".join(
            dut_name for dut_name, spec in DUT_CONFIG.items() if spec["function"] == function_name
        )
        raise ValueError(
            f"Unsupported DUT id '{dut_id}' for slot '{function_name}'. Supported DUT ids: {supported}"
        )

    return resolved


def multi_dut_project_name(part_tag: str, exp_dut_id: str, sigmoid_dut_id: str) -> str:
    if exp_dut_id == DEFAULT_EXP_DUT_ID and sigmoid_dut_id == DEFAULT_SIGMOID_DUT_ID:
        suffix = ""
    else:
        suffix = f"_{exp_dut_id}_{sigmoid_dut_id}"
    return f"my_proj_multi_dut{suffix}_{part_tag}"


def repo_relative_overlay_paths(exp_dut_id: str, sigmoid_dut_id: str) -> tuple[Path, Path]:
    proj_name = multi_dut_project_name(DEFAULT_PART_TAG, exp_dut_id, sigmoid_dut_id)
    bitstream = (
        Path("build")
        / "vivado_multi_dut"
        / DEFAULT_PART_TAG
        / proj_name
        / f"{proj_name}.runs"
        / "impl_1"
        / "design_1_wrapper.bit"
    )
    hwh = (
        Path("build")
        / "vivado_multi_dut"
        / DEFAULT_PART_TAG
        / proj_name
        / f"{proj_name}.gen"
        / "sources_1"
        / "bd"
        / "design_1"
        / "hw_handoff"
        / "design_1.hwh"
    )
    return bitstream, hwh


def unique_paths(paths: Iterable[Path]) -> list[Path]:
    deduped: list[Path] = []
    seen: set[str] = set()
    for path in paths:
        key = str(path)
        if key in seen:
            continue
        seen.add(key)
        deduped.append(path)
    return deduped


def upward_search_roots(start: Path) -> list[Path]:
    candidates = [start, Path.cwd()]
    roots: list[Path] = []
    for candidate in candidates:
        try:
            resolved = candidate.resolve()
        except OSError:
            resolved = candidate
        roots.append(resolved)
        roots.extend(resolved.parents)
    return unique_paths(roots)


def bitstream_candidates(executable_dir: Path, exp_dut_id: str, sigmoid_dut_id: str) -> list[Path]:
    repo_bitstream, _ = repo_relative_overlay_paths(exp_dut_id, sigmoid_dut_id)
    candidates = [
        executable_dir / "design_1_wrapper.bit",
        executable_dir / "pwl_multi_dut.bit",
        Path.cwd() / "design_1_wrapper.bit",
        Path.cwd() / "pwl_multi_dut.bit",
    ]

    for root in upward_search_roots(executable_dir):
        candidates.append(root / repo_bitstream)
        candidates.append(root / "final-project" / repo_bitstream)

    return unique_paths(candidates)


def hwh_candidates(
    bitstream: Path,
    executable_dir: Path,
    exp_dut_id: str,
    sigmoid_dut_id: str,
) -> list[Path]:
    _, repo_hwh = repo_relative_overlay_paths(exp_dut_id, sigmoid_dut_id)
    candidates = [
        bitstream.with_suffix(".hwh"),
        bitstream.with_name("design_1_wrapper.hwh"),
        bitstream.with_name("design_1.hwh"),
        executable_dir / "design_1_wrapper.hwh",
        executable_dir / "design_1.hwh",
        Path.cwd() / "design_1_wrapper.hwh",
        Path.cwd() / "design_1.hwh",
    ]

    for root in upward_search_roots(executable_dir):
        candidates.append(root / repo_hwh)
        candidates.append(root / "final-project" / repo_hwh)

    return unique_paths(candidates)


def first_existing(paths: Iterable[Path]) -> Path | None:
    for path in paths:
        if path.exists():
            return path.resolve()
    return None


def stage_overlay_files(bitstream: Path, hwh: Path) -> tuple[tempfile.TemporaryDirectory[str] | None, Path]:
    bitstream = bitstream.resolve()
    hwh = hwh.resolve()
    matching_hwh = bitstream.with_suffix(".hwh")
    if matching_hwh == hwh:
        return None, bitstream

    temp_dir = tempfile.TemporaryDirectory(prefix="pwl_multi_dut_pynq_")
    staged_bit = Path(temp_dir.name) / bitstream.name
    staged_hwh = staged_bit.with_suffix(".hwh")
    shutil.copy2(bitstream, staged_bit)
    shutil.copy2(hwh, staged_hwh)
    return temp_dir, staged_bit


def resolve_overlay_files(
    executable_dir: Path,
    bitstream_arg: str | None,
    hwh_arg: str | None,
    exp_dut_id: str,
    sigmoid_dut_id: str,
) -> tuple[Path, Path]:
    bitstream = Path(bitstream_arg).expanduser() if bitstream_arg else first_existing(
        bitstream_candidates(executable_dir, exp_dut_id, sigmoid_dut_id)
    )
    if bitstream is None or not bitstream.exists():
        raise RuntimeError(
            "No bitstream path found. Pass --bitstream <path> or export the SW/pynq bundle first."
        )

    if hwh_arg:
        hwh = Path(hwh_arg).expanduser()
    else:
        hwh = first_existing(hwh_candidates(bitstream, executable_dir, exp_dut_id, sigmoid_dut_id))

    if hwh is None or not hwh.exists():
        raise RuntimeError(
            "No HWH metadata file found. Pass --hwh <path> or export the SW/pynq bundle "
            "so the bitstream and metadata are packaged together."
        )

    return bitstream.resolve(), hwh.resolve()


def input_bounds_for_duts(requested_dut_ids: list[str]) -> tuple[float, float]:
    lower = min(DUT_CONFIG[dut_id]["min_x"] for dut_id in requested_dut_ids)
    upper = max(DUT_CONFIG[dut_id]["max_x"] for dut_id in requested_dut_ids)
    return float(lower), float(upper)


def generate_random_inputs(
    count: int,
    requested_dut_ids: list[str],
    random_seed: int | None,
) -> list[float]:
    lower, upper = input_bounds_for_duts(requested_dut_ids)
    rng = random.Random(random_seed)
    return [rng.uniform(lower, upper) for _ in range(count)]


def parse_inputs(
    raw_inputs: str | None,
    random_input_count: int | None,
    requested_dut_ids: list[str],
    random_seed: int | None,
) -> list[float]:
    if random_input_count is not None:
        return generate_random_inputs(random_input_count, requested_dut_ids, random_seed)

    if raw_inputs is None:
        return list(DEFAULT_INPUTS)

    values: list[float] = []
    for token in raw_inputs.replace(",", " ").split():
        values.append(float(token))

    if not values:
        raise ValueError("At least one input value is required.")
    return values


def format_input_summary(values: list[float], limit: int = MAX_PRINTED_INPUTS) -> str:
    if len(values) <= limit:
        return ", ".join(f"{value:.6f}" for value in values)

    head_count = limit // 2
    tail_count = limit - head_count
    preview = [f"{value:.6f}" for value in values[:head_count]]
    preview.append("...")
    preview.extend(f"{value:.6f}" for value in values[-tail_count:])
    return ", ".join(preview)


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


def prepare_packed_io(samples: list[float], dut_id: str) -> PackedIoPlan:
    precision_bits = int(DUT_CONFIG[dut_id]["precision_bits"])
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


def clamp(value: float, lower: float, upper: float) -> float:
    return max(lower, min(upper, value))


def reference_value(dut: str, x_value: float) -> float:
    if dut == "exp":
        return math.exp(x_value)
    return 1.0 / (1.0 + math.exp(-x_value))


def selected_duts(dut: str) -> list[str]:
    if dut == "both":
        return ["exp", "sigmoid"]
    return [dut]


def normalize_name(name: str) -> str:
    return "".join(ch for ch in str(name).lower() if ch.isalnum())


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


def create_mmio(overlay, ip_name: str, type_fragment: str):
    from pynq import MMIO

    if ip_name in overlay.ip_dict:
        desc = overlay.ip_dict[ip_name]
        return MMIO(desc["phys_addr"], desc["addr_range"]), ip_name

    candidates = [
        name
        for name, desc in overlay.ip_dict.items()
        if type_fragment in str(desc.get("type", ""))
    ]
    if len(candidates) == 1:
        chosen_name = candidates[0]
        desc = overlay.ip_dict[chosen_name]
        return MMIO(desc["phys_addr"], desc["addr_range"]), chosen_name

    if candidates:
        raise RuntimeError(
            f"IP '{ip_name}' was not found. Available matching IPs: {', '.join(sorted(candidates))}."
        )

    raise RuntimeError(
        f"IP '{ip_name}' was not found and no '{type_fragment}' instances were discovered in the overlay."
    )


def buffer_address(buffer) -> int:
    for attr_name in ("device_address", "physical_address"):
        value = getattr(buffer, attr_name, None)
        if value is not None:
            return int(value)
    raise RuntimeError("Unable to resolve a device-visible address for the PYNQ buffer.")


def sync_to_device(buffer) -> None:
    for method_name in ("sync_to_device", "flush"):
        method = getattr(buffer, method_name, None)
        if callable(method):
            method()
            return


def sync_from_device(buffer) -> None:
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
            f"WARNING: {name} buffer address 0x{address:016x} is outside the current DDR aperture "
            f"(0x00000000..0x{DDR_HIGH_ADDR:08x}).",
            file=sys.stderr,
        )


def write_u64_register(mmio, lower_offset: int, upper_offset: int, value: int) -> None:
    mmio.write(lower_offset, value & 0xFFFFFFFF)
    mmio.write(upper_offset, (value >> 32) & 0xFFFFFFFF)


def continue_kernel(mmio) -> None:
    ctrl = int(mmio.read(CTRL_OFFSET))
    mmio.write(CTRL_OFFSET, (ctrl & AUTO_RESTART_MASK) | AP_CONTINUE_MASK)


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


def resolve_power_target(
    power_targets: list[PowerTarget],
    requested_name: str | None,
) -> PowerTarget | None:
    if not power_targets:
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


def wait_for_kernel_state(mmio, required_mask: int, description: str) -> int:
    deadline = time.monotonic() + CONTROL_TIMEOUT_SECONDS
    last_status = 0

    while time.monotonic() < deadline:
        last_status = int(mmio.read(CTRL_OFFSET))
        if last_status & required_mask:
            return last_status
        time.sleep(0.001)

    raise RuntimeError(
        f"Timed out waiting for the accelerator to reach {description}. "
        f"Last CTRL value: 0x{last_status:08x}"
    )


def run_kernel(mmio, input_buffer, output_buffer, size: int) -> tuple[int, float]:
    output_buffer[:] = 0
    sync_to_device(input_buffer)
    sync_to_device(output_buffer)

    kernel_start = time.monotonic()
    wait_for_kernel_state(mmio, AP_IDLE_MASK, "idle before launch")

    write_u64_register(mmio, IN_R_1_OFFSET, IN_R_2_OFFSET, buffer_address(input_buffer))
    write_u64_register(mmio, OUT_R_1_OFFSET, OUT_R_2_OFFSET, buffer_address(output_buffer))
    write_u64_register(mmio, SIZE_1_OFFSET, SIZE_2_OFFSET, int(size))

    mmio.write(CTRL_OFFSET, 0)
    mmio.read(CTRL_OFFSET)
    mmio.write(CTRL_OFFSET, AP_START_MASK)
    status = wait_for_kernel_state(mmio, AP_DONE_MASK, "completion")
    continue_kernel(mmio)
    wait_for_kernel_state(mmio, AP_IDLE_MASK, "idle after completion")
    kernel_seconds = time.monotonic() - kernel_start
    sync_from_device(output_buffer)
    return status, kernel_seconds


def validate_outputs(dut: str, dut_id: str, inputs: list[float], output_values: list[float]) -> tuple[bool, list[str]]:
    spec = DUT_CONFIG[dut_id]
    passed = True
    lines: list[str] = []

    for index, original in enumerate(inputs):
        clamped = clamp(original, spec["min_x"], spec["max_x"])
        expected = reference_value(spec["function"], clamped)
        actual = float(output_values[index])
        abs_err = abs(actual - expected)
        limit = spec["atol"] + spec["rtol"] * abs(expected)
        sample_passed = abs_err <= limit
        passed &= sample_passed

        lines.append(
            f"{dut} sample[{index}]"
            f" x={original:.6f}"
            f" clamped={clamped:.6f}"
            f" expected={expected:.8f}"
            f" actual={actual:.8f}"
            f" abs_err={abs_err:.6e}"
            f" limit={limit:.6e}"
            f" {'PASS' if sample_passed else 'FAIL'}"
        )

    return passed, lines


def print_sample_lines(sample_lines: list[str], limit: int = MAX_PRINTED_SAMPLE_LINES) -> None:
    if len(sample_lines) <= limit:
        for line in sample_lines:
            print(line)
        return

    head_count = limit // 2
    tail_count = limit - head_count
    for line in sample_lines[:head_count]:
        print(line)
    omitted = len(sample_lines) - limit
    print(f"... omitted {omitted} sample lines ...")
    for line in sample_lines[-tail_count:]:
        print(line)


def should_print_iteration(iteration_index: int, total_iterations: int) -> bool:
    if total_iterations <= 10:
        return True
    if iteration_index == 0 or iteration_index == total_iterations - 1:
        return True

    step = max(1, total_iterations // 10)
    return (iteration_index + 1) % step == 0


def print_power_summary(
    dut: str,
    dut_id: str,
    rail_name: str,
    idle_power_avgs: list[float],
    active_power_avgs: list[float],
    delta_power_avgs: list[float],
    idle_sample_counts: list[int],
    active_sample_counts: list[int],
    active_window_seconds: list[float],
    kernel_seconds: list[float],
    validation_seconds: list[float],
    host_overhead_seconds: list[float],
) -> str:
    idle_avg = average(idle_power_avgs)
    active_avg = average(active_power_avgs)
    delta_avg = average(delta_power_avgs)
    avg_idle_samples = average([float(count) for count in idle_sample_counts])
    avg_active_samples = average([float(count) for count in active_sample_counts])
    active_window_avg = average(active_window_seconds)
    kernel_avg = average(kernel_seconds)
    validation_avg = average(validation_seconds)
    host_overhead_avg = average(host_overhead_seconds)

    if (
        idle_avg is None
        or active_avg is None
        or delta_avg is None
        or active_window_avg is None
        or kernel_avg is None
        or validation_avg is None
        or host_overhead_avg is None
    ):
        summary = f"{dut} power summary: insufficient per-iteration samples on rail {rail_name}"
        print(summary)
        return summary

    summary = (
        f"{dut} power summary"
        f" impl={dut_id}"
        f" rail={rail_name}"
        f" iterations={len(active_window_seconds)}"
        f" avg_idle_w={idle_avg:.6f}"
        f" avg_active_w={active_avg:.6f}"
        f" avg_delta_w={delta_avg:.6f}"
        f" avg_idle_samples={avg_idle_samples:.2f}"
        f" avg_active_samples={avg_active_samples:.2f}"
        f" avg_active_window_ms={active_window_avg * 1e3:.3f}"
        f" avg_kernel_ms={kernel_avg * 1e3:.3f}"
        f" avg_validation_ms={validation_avg * 1e3:.3f}"
        f" avg_host_overhead_ms={host_overhead_avg * 1e3:.3f}"
    )
    print(summary)
    return summary


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run the exported PWL multi-DUT accelerator through PYNQ.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument("bitstream_pos", nargs="?", help="Optional .bit path")
    parser.add_argument(
        "--dut",
        choices=("exp", "sigmoid", "both"),
        default="both",
        help="Select which DUT(s) to execute",
    )
    parser.add_argument("--bitstream", help="Path to the .bit file")
    parser.add_argument(
        "--hwh",
        help="Optional HWH metadata path. Useful when the HWH basename does not match the bitstream basename.",
    )
    parser.add_argument(
        "--exp-ip-name",
        default=DUT_CONFIG[DEFAULT_EXP_DUT_ID]["ip_name"],
        help="Overlay IP instance name for the exponential DUT",
    )
    parser.add_argument(
        "--sigmoid-ip-name",
        default=DUT_CONFIG[DEFAULT_SIGMOID_DUT_ID]["ip_name"],
        help="Overlay IP instance name for the sigmoid DUT",
    )
    parser.add_argument(
        "--exp-dut-id",
        default=DEFAULT_EXP_DUT_ID,
        help="Implementation to load into the exponential slot. Supported values: exp, exp_f16.",
    )
    parser.add_argument(
        "--sigmoid-dut-id",
        default=DEFAULT_SIGMOID_DUT_ID,
        help="Implementation to load into the sigmoid slot. Supported values: sigmoid, sigmoid_f16.",
    )
    parser.add_argument(
        "--inputs",
        help="Comma or space separated input samples. Use the form --inputs=-8,-4,-1,0,1,4,8 for negative values.",
    )
    parser.add_argument(
        "--random-input-count",
        type=int,
        help="Generate this many random inputs across the selected DUT domain instead of using --inputs.",
    )
    parser.add_argument(
        "--random-seed",
        type=int,
        help="Optional seed for randomized input generation.",
    )
    parser.add_argument(
        "--iterations",
        type=int,
        default=DEFAULT_ITERATIONS,
        help="Number of repeated executions per requested DUT. Used to widen the power measurement window.",
    )
    parser.add_argument(
        "--power-rail",
        help="Optional power source name to sample. Accepts either a PYNQ rail or a discovered hwmon source.",
    )
    parser.add_argument(
        "--power-sample-interval",
        type=float,
        default=DEFAULT_POWER_SAMPLE_INTERVAL_SECONDS,
        help="Seconds between rail power samples during idle and active windows.",
    )
    parser.add_argument(
        "--idle-power-seconds",
        type=float,
        default=DEFAULT_IDLE_POWER_SECONDS,
        help="Seconds of idle rail sampling collected before each DUT run.",
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
        help="Skip PL programming and assume the matching overlay is already loaded",
    )

    args = parser.parse_args()
    if args.bitstream and args.bitstream_pos:
        parser.error("Provide the bitstream path either positionally or with --bitstream, not both.")
    if args.inputs and args.random_input_count is not None:
        parser.error("Use either --inputs or --random-input-count, not both.")
    if args.iterations < 1:
        parser.error("--iterations must be >= 1")
    if args.random_input_count is not None and args.random_input_count < 1:
        parser.error("--random-input-count must be >= 1")
    if args.power_sample_interval <= 0.0:
        parser.error("--power-sample-interval must be > 0")
    if args.idle_power_seconds <= 0.0:
        parser.error("--idle-power-seconds must be > 0")
    return args


def main() -> int:
    args = parse_args()
    executable_dir = get_executable_dir(sys.argv[0])
    summary_path = (
        Path(args.summary_file).expanduser()
        if args.summary_file
        else default_summary_path(sys.argv[0], executable_dir)
    )
    try:
        exp_dut_id = canonical_dut_id(args.exp_dut_id, "exp")
        sigmoid_dut_id = canonical_dut_id(args.sigmoid_dut_id, "sigmoid")
    except ValueError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1

    requested_duts = selected_duts(args.dut)
    selected_impls = {
        "exp": exp_dut_id,
        "sigmoid": sigmoid_dut_id,
    }
    requested_dut_ids = [selected_impls[dut] for dut in requested_duts]
    ip_names = {
        "exp": args.exp_ip_name,
        "sigmoid": args.sigmoid_ip_name,
    }
    temp_overlay_dir = None
    summary_lines = [
        f"Summary generated: {time.strftime('%Y-%m-%d %H:%M:%S')}",
        f"Application: {Path(sys.argv[0]).name}",
        f"Summary file: {summary_path}",
        f"Requested DUTs: {', '.join(requested_duts)}",
        f"Exp slot implementation: {exp_dut_id}",
        f"Sigmoid slot implementation: {sigmoid_dut_id}",
        f"Iterations per DUT: {args.iterations}",
    ]

    try:
        inputs = parse_inputs(
            args.inputs,
            args.random_input_count,
            requested_dut_ids,
            args.random_seed,
        )
    except ValueError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1

    try:
        try:
            import numpy as np
            from pynq import Overlay, allocate
            try:
                from pynq import get_rails
            except ImportError:
                get_rails = None
        except ImportError as exc:
            raise RuntimeError(
                "The pynq and numpy Python packages must be installed in this environment."
            ) from exc

        power_targets: list[PowerTarget] = []
        if get_rails is not None:
            rails = get_rails_dict(get_rails)
            power_targets.extend(make_pynq_power_targets(rails))
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
        rail_name = selected_power_target.display_name if selected_power_target is not None else None
        rail = selected_power_target.reader if selected_power_target is not None else None
        if selected_power_target is not None:
            print(f"Power source: {rail_name} ({selected_power_target.source})")
            print(
                f"Power sampling: idle_window_s={args.idle_power_seconds:.3f} "
                f"sample_interval_s={args.power_sample_interval:.3f}"
            )
            summary_lines.append(f"Power source: {rail_name} ({selected_power_target.source})")
        elif args.power_rail:
            raise RuntimeError(f"Unable to resolve requested power source '{args.power_rail}'.")
        else:
            print(
                "Power source: unavailable "
                "(no matching PYNQ rail or hwmon sensor was found; use --list-rails to inspect)"
            )
            summary_lines.append("Power source: unavailable")

        bitstream_arg = args.bitstream or args.bitstream_pos
        bitstream, hwh = resolve_overlay_files(
            executable_dir,
            bitstream_arg,
            args.hwh,
            exp_dut_id,
            sigmoid_dut_id,
        )
        print(f"DUTs: {', '.join(requested_duts)}")
        print(f"Exp slot implementation: {exp_dut_id}")
        print(f"Sigmoid slot implementation: {sigmoid_dut_id}")
        print(f"Bitstream: {bitstream}")
        print(f"HWH: {hwh}")
        print(f"Programming PL: {'no' if args.no_program else 'yes'}")
        print(f"Input count: {len(inputs)}")
        print(f"Inputs: {format_input_summary(inputs)}")
        summary_lines.extend(
            [
                f"Bitstream: {bitstream}",
                f"HWH: {hwh}",
                f"Programming PL: {'no' if args.no_program else 'yes'}",
                f"Input count: {len(inputs)}",
                f"Inputs: {format_input_summary(inputs)}",
            ]
        )
        if args.random_input_count is not None:
            seed_text = str(args.random_seed) if args.random_seed is not None else "system-default"
            print(f"Random inputs: enabled count={args.random_input_count} seed={seed_text}")
            summary_lines.append(
                f"Random inputs: enabled count={args.random_input_count} seed={seed_text}"
            )
        print(f"Iterations per DUT: {args.iterations}")

        temp_overlay_dir, overlay_bit = stage_overlay_files(bitstream, hwh)
        overlay = Overlay(str(overlay_bit), download=not args.no_program)

        mmios = {}
        for dut in requested_duts:
            dut_id = selected_impls[dut]
            spec = DUT_CONFIG[dut_id]
            mmio, actual_name = create_mmio(overlay, ip_names[dut], spec["type_fragment"])
            mmios[dut] = mmio
            if actual_name != ip_names[dut]:
                print(f"{dut} IP: auto-selected {actual_name} for impl={dut_id}")
            else:
                print(f"{dut} IP: {actual_name} (impl={dut_id})")

        all_passed = True
        for dut in requested_duts:
            dut_id = selected_impls[dut]
            spec = DUT_CONFIG[dut_id]
            packed_plan = prepare_packed_io(inputs, dut_id)
            print(f"Running test for dut={dut} impl={dut_id} ({spec['display_name']})")
            if packed_plan.padded_count != packed_plan.logical_count:
                print(
                    f"{dut} impl={dut_id} packs {packed_plan.logical_count} logical samples "
                    f"into {packed_plan.word_count} words using padded_count={packed_plan.padded_count}"
                )
            input_buffer = allocate(shape=(packed_plan.word_count,), dtype=np.uint32)
            output_buffer = allocate(shape=(packed_plan.word_count,), dtype=np.uint32)

            try:
                for index, word in enumerate(packed_plan.input_words):
                    input_buffer[index] = word

                warn_if_address_outside_ddr("input", buffer_address(input_buffer))
                warn_if_address_outside_ddr("output", buffer_address(output_buffer))

                idle_power_avgs: list[float] = []
                active_power_avgs: list[float] = []
                delta_power_avgs: list[float] = []
                idle_sample_counts: list[int] = []
                active_sample_counts: list[int] = []
                active_window_seconds: list[float] = []
                kernel_runtime_seconds: list[float] = []
                validation_runtime_seconds: list[float] = []
                host_overhead_seconds: list[float] = []
                if rail is not None:
                    print(
                        f"{dut} impl={dut_id} per-iteration power sampling:"
                        f" idle_window_s={args.idle_power_seconds:.3f}"
                        f" sample_interval_s={args.power_sample_interval:.3f}"
                    )

                for iteration_index in range(args.iterations):
                    idle_samples: list[float] = []
                    if rail is not None:
                        idle_samples = collect_power_samples(
                            rail,
                            args.idle_power_seconds,
                            args.power_sample_interval,
                        )

                    active_samples: list[float] = []
                    sampler = RailSampler(rail, args.power_sample_interval) if rail is not None else None
                    active_window = 0.0

                    try:
                        active_start = time.monotonic()
                        if sampler is not None:
                            sampler.start()

                        status, kernel_seconds = run_kernel(
                            mmios[dut],
                            input_buffer,
                            output_buffer,
                            packed_plan.padded_count,
                        )
                        validation_start = time.monotonic()
                        output_values = unpack_output_words(
                            output_buffer,
                            packed_plan.logical_count,
                            packed_plan.precision_bits,
                        )
                        passed, sample_lines = validate_outputs(dut, dut_id, inputs, output_values)
                        validation_seconds = time.monotonic() - validation_start
                        active_window = time.monotonic() - active_start
                        all_passed &= passed
                    finally:
                        if sampler is not None:
                            sampler.stop()
                            sampler.join()
                            if sampler.error is not None:
                                raise RuntimeError(
                                    f"Failed to sample power rail '{rail_name}': {sampler.error}"
                                ) from sampler.error
                            active_samples = sampler.samples

                    host_overhead = max(0.0, active_window - kernel_seconds - validation_seconds)
                    active_window_seconds.append(active_window)
                    kernel_runtime_seconds.append(kernel_seconds)
                    validation_runtime_seconds.append(validation_seconds)
                    host_overhead_seconds.append(host_overhead)

                    idle_avg = average(idle_samples)
                    active_avg = average(active_samples)
                    delta_avg = None
                    if idle_avg is not None and active_avg is not None:
                        delta_avg = active_avg - idle_avg
                        idle_power_avgs.append(idle_avg)
                        active_power_avgs.append(active_avg)
                        delta_power_avgs.append(delta_avg)
                        idle_sample_counts.append(len(idle_samples))
                        active_sample_counts.append(len(active_samples))

                    if should_print_iteration(iteration_index, args.iterations) or not passed:
                        line = (
                            f"{dut} iteration {iteration_index + 1}/{args.iterations}"
                            f" impl={dut_id}"
                            f" CTRL=0x{status:08x}"
                            f" active_window_ms={active_window * 1e3:.3f}"
                            f" kernel_ms={kernel_seconds * 1e3:.3f}"
                            f" validation_ms={validation_seconds * 1e3:.3f}"
                            f" host_overhead_ms={host_overhead * 1e3:.3f}"
                        )
                        if delta_avg is not None:
                            line += (
                                f" idle_avg_w={idle_avg:.6f}"
                                f" active_avg_w={active_avg:.6f}"
                                f" delta_w={delta_avg:.6f}"
                                f" idle_samples={len(idle_samples)}"
                                f" active_samples={len(active_samples)}"
                            )
                        line += f" {'PASS' if passed else 'FAIL'}"
                        print(line)

                    if args.iterations == 1 or not passed:
                        print_sample_lines(sample_lines)

                if rail_name is not None:
                    power_summary = print_power_summary(
                        dut,
                        dut_id,
                        rail_name,
                        idle_power_avgs,
                        active_power_avgs,
                        delta_power_avgs,
                        idle_sample_counts,
                        active_sample_counts,
                        active_window_seconds,
                        kernel_runtime_seconds,
                        validation_runtime_seconds,
                        host_overhead_seconds,
                    )
                    summary_lines.append(power_summary)
            finally:
                close_buffer(output_buffer)
                close_buffer(input_buffer)

        if all_passed:
            summary_lines.append("All requested PWL multi-DUT checks passed.")
            saved_summary_path = save_summary_file(summary_path, summary_lines)
            print(f"Saved summary to {saved_summary_path}")
            print("All requested PWL multi-DUT checks passed.")
            return 0

        summary_lines.append("One or more PWL multi-DUT checks failed.")
        saved_summary_path = save_summary_file(summary_path, summary_lines)
        print(f"Saved summary to {saved_summary_path}")
        print("One or more PWL multi-DUT checks failed.", file=sys.stderr)
        return 1
    except RuntimeError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    finally:
        if temp_overlay_dir is not None:
            temp_overlay_dir.cleanup()


if __name__ == "__main__":
    sys.exit(main())
