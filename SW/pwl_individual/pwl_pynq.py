#!/usr/bin/env python3
"""
PYNQ host example for the HLS PWL DUTs exported under final-project/SW/pynq.

Typical use:
  ./pwl_pynq.py --dut exp
  ./pwl_pynq.py --dut sigmoid
  ./pwl_pynq.py --dut exp --inputs=-8,-4,-1,0,1,4,8
  ./pwl_pynq.py --dut sigmoid --bitstream /path/to/design_1_wrapper.bit --hwh /path/to/design_1_wrapper.hwh
  ./pwl_pynq.py --dut exp --no-program
"""

from __future__ import annotations

import argparse
import math
import shutil
import struct
import sys
import tempfile
import time
from pathlib import Path
from typing import Iterable


DEFAULT_PART_TAG = "xck26_sfvc784_2LV_c"
DEFAULT_INPUTS = (-8.0, -4.0, -1.0, -0.25, 0.0, 0.25, 1.0, 4.0, 8.0)
CONTROL_TIMEOUT_SECONDS = 5.0

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

DUT_CONFIG = {
    "exp": {
        "display_name": "Nonuniform exponential",
        "ip_name": "pwl_exp_0",
        "type_fragment": "pwl_pwl_nonuniform_pwl_function_exponential_use_float32",
        "min_x": -8.0,
        "max_x": 8.0,
        "atol": 0.25,
        "rtol": 0.03,
    },
    "sigmoid": {
        "display_name": "Nonuniform sigmoid",
        "ip_name": "pwl_sigmoid_0",
        "type_fragment": "pwl_pwl_nonuniform_pwl_function_sigmoid_use_float32",
        "min_x": -8.0,
        "max_x": 8.0,
        "atol": 0.01,
        "rtol": 0.03,
    },
}


def get_executable_dir(argv0: str) -> Path:
    try:
        return Path(argv0).resolve().parent
    except OSError:
        return Path.cwd()


def repo_relative_overlay_paths(dut: str) -> tuple[Path, Path]:
    proj_name = f"my_proj_{dut}_{DEFAULT_PART_TAG}"
    bitstream = (
        Path("build")
        / "vivado"
        / dut
        / DEFAULT_PART_TAG
        / proj_name
        / f"{proj_name}.runs"
        / "impl_1"
        / "design_1_wrapper.bit"
    )
    hwh = (
        Path("build")
        / "vivado"
        / dut
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


def bitstream_candidates(dut: str, executable_dir: Path) -> list[Path]:
    repo_bitstream, _ = repo_relative_overlay_paths(dut)
    candidates = [
        executable_dir / dut / "design_1_wrapper.bit",
        executable_dir / "pynq" / dut / "design_1_wrapper.bit",
        Path.cwd() / dut / "design_1_wrapper.bit",
        Path.cwd() / "pynq" / dut / "design_1_wrapper.bit",
    ]

    for root in upward_search_roots(executable_dir):
        candidates.append(root / repo_bitstream)
        candidates.append(root / "final-project" / repo_bitstream)

    return unique_paths(candidates)


def hwh_candidates(dut: str, bitstream: Path, executable_dir: Path) -> list[Path]:
    _, repo_hwh = repo_relative_overlay_paths(dut)
    candidates = [
        bitstream.with_suffix(".hwh"),
        bitstream.with_name("design_1_wrapper.hwh"),
        bitstream.with_name("design_1.hwh"),
        executable_dir / dut / "design_1_wrapper.hwh",
        executable_dir / "pynq" / dut / "design_1_wrapper.hwh",
        Path.cwd() / dut / "design_1_wrapper.hwh",
        Path.cwd() / "pynq" / dut / "design_1_wrapper.hwh",
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

    temp_dir = tempfile.TemporaryDirectory(prefix="pwl_pynq_")
    staged_bit = Path(temp_dir.name) / bitstream.name
    staged_hwh = staged_bit.with_suffix(".hwh")
    shutil.copy2(bitstream, staged_bit)
    shutil.copy2(hwh, staged_hwh)
    return temp_dir, staged_bit


def resolve_overlay_files(
    dut: str,
    executable_dir: Path,
    bitstream_arg: str | None,
    hwh_arg: str | None,
) -> tuple[Path, Path]:
    bitstream = Path(bitstream_arg).expanduser() if bitstream_arg else first_existing(
        bitstream_candidates(dut, executable_dir)
    )
    if bitstream is None or not bitstream.exists():
        raise RuntimeError(
            "No bitstream path found. Pass --bitstream <path> or export the SW/pynq bundle first."
        )

    if hwh_arg:
        hwh = Path(hwh_arg).expanduser()
    else:
        hwh = first_existing(hwh_candidates(dut, bitstream, executable_dir))

    if hwh is None or not hwh.exists():
        raise RuntimeError(
            "No HWH metadata file found. Pass --hwh <path> or export the SW/pynq bundle "
            "so the bitstream and metadata are packaged together."
        )

    return bitstream.resolve(), hwh.resolve()


def parse_inputs(raw_inputs: str | None) -> list[float]:
    if raw_inputs is None:
        return list(DEFAULT_INPUTS)

    values: list[float] = []
    for token in raw_inputs.replace(",", " ").split():
        values.append(float(token))

    if not values:
        raise ValueError("At least one input value is required.")
    return values


def float_to_u32(value: float) -> int:
    return struct.unpack("<I", struct.pack("<f", float(value)))[0]


def u32_to_float(value: int) -> float:
    return struct.unpack("<f", struct.pack("<I", int(value) & 0xFFFFFFFF))[0]


def clamp(value: float, lower: float, upper: float) -> float:
    return max(lower, min(upper, value))


def reference_value(dut: str, x_value: float) -> float:
    if dut == "exp":
        return math.exp(x_value)
    return 1.0 / (1.0 + math.exp(-x_value))


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


def write_u64_register(mmio, lower_offset: int, upper_offset: int, value: int) -> None:
    mmio.write(lower_offset, value & 0xFFFFFFFF)
    mmio.write(upper_offset, (value >> 32) & 0xFFFFFFFF)


def wait_for_kernel(mmio) -> int:
    deadline = time.monotonic() + CONTROL_TIMEOUT_SECONDS
    last_status = 0

    while time.monotonic() < deadline:
        last_status = int(mmio.read(CTRL_OFFSET))
        if last_status & AP_DONE_MASK:
            return last_status
        time.sleep(0.001)

    raise RuntimeError(
        f"Timed out waiting for the accelerator to finish. Last CTRL value: 0x{last_status:08x}"
    )


def run_kernel(mmio, input_buffer, output_buffer, size: int) -> int:
    output_buffer[:] = 0
    sync_to_device(input_buffer)
    sync_to_device(output_buffer)

    write_u64_register(mmio, IN_R_1_OFFSET, IN_R_2_OFFSET, buffer_address(input_buffer))
    write_u64_register(mmio, OUT_R_1_OFFSET, OUT_R_2_OFFSET, buffer_address(output_buffer))
    write_u64_register(mmio, SIZE_1_OFFSET, SIZE_2_OFFSET, int(size))

    mmio.write(CTRL_OFFSET, 0)
    mmio.write(CTRL_OFFSET, AP_START_MASK)
    status = wait_for_kernel(mmio)
    sync_from_device(output_buffer)
    return status


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run the exported PWL accelerator through PYNQ.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument("bitstream_pos", nargs="?", help="Optional .bit path")
    parser.add_argument(
        "--dut",
        choices=tuple(DUT_CONFIG.keys()),
        default="exp",
        help="Select which PWL DUT to execute",
    )
    parser.add_argument("--bitstream", help="Path to the .bit file")
    parser.add_argument(
        "--hwh",
        help="Optional HWH metadata path. Useful when the HWH basename does not match the bitstream basename.",
    )
    parser.add_argument(
        "--ip-name",
        help="Optional overlay IP instance name override. By default the script uses the generated pwl_<dut>_0 name.",
    )
    parser.add_argument(
        "--inputs",
        help="Comma or space separated float32 inputs. Use the form --inputs=-8,-4,-1,0,1,4,8 for negative values.",
    )
    parser.add_argument(
        "--atol",
        type=float,
        help="Absolute tolerance used for the software-vs-hardware comparison",
    )
    parser.add_argument(
        "--rtol",
        type=float,
        help="Relative tolerance used for the software-vs-hardware comparison",
    )
    parser.add_argument(
        "--no-program",
        action="store_true",
        help="Skip PL programming and assume the matching overlay is already loaded",
    )

    args = parser.parse_args()
    if args.bitstream and args.bitstream_pos:
        parser.error("Provide the bitstream path either positionally or with --bitstream, not both.")
    return args


def main() -> int:
    args = parse_args()
    spec = DUT_CONFIG[args.dut]
    executable_dir = get_executable_dir(sys.argv[0])
    bitstream_arg = args.bitstream or args.bitstream_pos
    bitstream, hwh = resolve_overlay_files(args.dut, executable_dir, bitstream_arg, args.hwh)

    try:
        inputs = parse_inputs(args.inputs)
    except ValueError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1

    atol = spec["atol"] if args.atol is None else args.atol
    rtol = spec["rtol"] if args.rtol is None else args.rtol
    requested_ip_name = args.ip_name or spec["ip_name"]
    temp_overlay_dir = None

    print(f"DUT: {args.dut} ({spec['display_name']})")
    print(f"Requested IP: {requested_ip_name}")
    print(f"Bitstream: {bitstream}")
    print(f"HWH: {hwh}")
    print(f"Programming PL: {'no' if args.no_program else 'yes'}")
    print(f"Inputs: {', '.join(f'{value:.6f}' for value in inputs)}")
    print(f"Tolerances: atol={atol} rtol={rtol}")

    try:
        try:
            import numpy as np
            from pynq import Overlay, allocate
        except ImportError as exc:
            raise RuntimeError(
                "The pynq and numpy Python packages must be installed in this environment."
            ) from exc

        temp_overlay_dir, overlay_bit = stage_overlay_files(bitstream, hwh)
        overlay = Overlay(str(overlay_bit), download=not args.no_program)
        mmio, actual_ip_name = create_mmio(overlay, requested_ip_name, spec["type_fragment"])

        if actual_ip_name != requested_ip_name:
            print(f"Selected IP: auto-selected {actual_ip_name}")
        else:
            print(f"Selected IP: {actual_ip_name}")

        input_buffer = allocate(shape=(len(inputs),), dtype=np.uint32)
        output_buffer = allocate(shape=(len(inputs),), dtype=np.uint32)

        try:
            for index, value in enumerate(inputs):
                input_buffer[index] = float_to_u32(value)

            status = run_kernel(mmio, input_buffer, output_buffer, len(inputs))
            print(f"Kernel CTRL status: 0x{status:08x}")

            all_passed = True
            for index, original in enumerate(inputs):
                clamped = clamp(original, spec["min_x"], spec["max_x"])
                expected = reference_value(args.dut, clamped)
                actual = u32_to_float(int(output_buffer[index]))
                abs_err = abs(actual - expected)
                limit = atol + rtol * abs(expected)
                passed = abs_err <= limit
                all_passed &= passed

                print(
                    f"sample[{index}]"
                    f" x={original:.6f}"
                    f" clamped={clamped:.6f}"
                    f" expected={expected:.8f}"
                    f" actual={actual:.8f}"
                    f" abs_err={abs_err:.6e}"
                    f" limit={limit:.6e}"
                    f" {'PASS' if passed else 'FAIL'}"
                )

            if all_passed:
                print("All samples passed.")
                return 0

            print("One or more samples failed the tolerance check.", file=sys.stderr)
            return 1
        finally:
            close_buffer(input_buffer)
            close_buffer(output_buffer)
    except RuntimeError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    finally:
        if temp_overlay_dir is not None:
            temp_overlay_dir.cleanup()


if __name__ == "__main__":
    sys.exit(main())
