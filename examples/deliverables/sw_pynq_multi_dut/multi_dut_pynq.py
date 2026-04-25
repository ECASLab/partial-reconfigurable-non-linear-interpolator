#!/usr/bin/env python3
"""
PYNQ host example for the final-project `multi_dut` design.

This software targets the generated multi-accelerator overlay:
  - AXI DMA control through AXI4-Lite
  - One multiplier streaming path
  - One XOR streaming path
  - No AXI4-Lite control registers on the DUTs themselves

Typical use:
  ./multi_dut_pynq.py
  ./multi_dut_pynq.py --dut mul
  ./multi_dut_pynq.py --bitstream /path/to/design_1_wrapper.bit
  ./multi_dut_pynq.py --bitstream /path/to/design_1_wrapper.bit --hwh /path/to/design_1.hwh
  ./multi_dut_pynq.py /path/to/design_1_wrapper.bit
  ./multi_dut_pynq.py --no-program
"""

from __future__ import annotations

import argparse
import shutil
import sys
import tempfile
from pathlib import Path
from typing import Iterable


DEFAULT_PART_TAG = "xck26_sfvc784_2LV_c"
DEFAULT_DMA_NAMES = {
    "mul": "axi_dma_mul_0",
    "xor": "axi_dma_xor_0",
}
TESTS = (
    (0x0000000000000007, 0x0000000000000009),
    (0x123456789ABCDEF0, 0x0000000000000010),
    (0xFFFFFFFFFFFFFFFF, 0x0000000000000002),
    (0xFEEDFACECAFEBEEF, 0x0102030405060708),
)


def hex64(value: int) -> str:
    return f"0x{value & 0xFFFFFFFFFFFFFFFF:016x}"


def hex128(hi: int, lo: int) -> str:
    return f"0x{hi & 0xFFFFFFFFFFFFFFFF:016x}{lo & 0xFFFFFFFFFFFFFFFF:016x}"


def compute_expected(engine: str, a: int, b: int) -> tuple[int, int]:
    if engine == "xor":
        return (a ^ b) & 0xFFFFFFFFFFFFFFFF, 0

    product = (a * b) & ((1 << 128) - 1)
    return product & 0xFFFFFFFFFFFFFFFF, (product >> 64) & 0xFFFFFFFFFFFFFFFF


def get_executable_dir(argv0: str) -> Path:
    try:
        return Path(argv0).resolve().parent
    except OSError:
        return Path.cwd()


def bitstream_candidates(executable_dir: Path) -> list[Path]:
    proj_name = f"my_proj_multi_dut_{DEFAULT_PART_TAG}"
    repo_relative = (
        Path("build")
        / "vivado_multi_dut"
        / DEFAULT_PART_TAG
        / proj_name
        / f"{proj_name}.runs"
        / "impl_1"
        / "design_1_wrapper.bit"
    )

    return [
        executable_dir / "design_1_wrapper.bit",
        executable_dir / "multi_dut.bit",
        Path.cwd() / "design_1_wrapper.bit",
        Path.cwd() / "multi_dut.bit",
        repo_relative,
        Path("..") / repo_relative,
        Path("final-project") / repo_relative,
    ]


def hwh_candidates(bitstream: Path, executable_dir: Path) -> list[Path]:
    proj_name = f"my_proj_multi_dut_{DEFAULT_PART_TAG}"
    repo_relative = (
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

    return [
        bitstream.with_suffix(".hwh"),
        bitstream.with_name("design_1.hwh"),
        executable_dir / "design_1_wrapper.hwh",
        executable_dir / "design_1.hwh",
        Path.cwd() / "design_1_wrapper.hwh",
        Path.cwd() / "design_1.hwh",
        repo_relative,
        Path("..") / repo_relative,
        Path("final-project") / repo_relative,
    ]


def first_existing(paths: Iterable[Path]) -> Path | None:
    for path in paths:
        if path.exists():
            return path.resolve()
    return None


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run the multi-DUT AXI-stream design through PYNQ.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument("bitstream_pos", nargs="?", help="Optional .bit path")
    parser.add_argument(
        "--dut",
        choices=("mul", "xor", "both"),
        default="both",
        help="Select which engine(s) to exercise",
    )
    parser.add_argument("--bitstream", help="Path to the .bit file")
    parser.add_argument(
        "--hwh",
        help="Optional HWH metadata file. Useful when the .hwh basename does not match the .bit basename.",
    )
    parser.add_argument(
        "--mul-dma-name",
        default=DEFAULT_DMA_NAMES["mul"],
        help="Overlay IP name for the multiplier AXI DMA instance",
    )
    parser.add_argument(
        "--xor-dma-name",
        default=DEFAULT_DMA_NAMES["xor"],
        help="Overlay IP name for the XOR AXI DMA instance",
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


def stage_overlay_files(bitstream: Path, hwh: Path) -> tuple[tempfile.TemporaryDirectory[str] | None, Path]:
    bitstream = bitstream.resolve()
    hwh = hwh.resolve()
    matching_hwh = bitstream.with_suffix(".hwh")
    if matching_hwh == hwh:
        return None, bitstream

    temp_dir = tempfile.TemporaryDirectory(prefix="multi_dut_pynq_")
    staged_bit = Path(temp_dir.name) / bitstream.name
    staged_hwh = staged_bit.with_suffix(".hwh")
    shutil.copy2(bitstream, staged_bit)
    shutil.copy2(hwh, staged_hwh)
    return temp_dir, staged_bit


def resolve_overlay_files(
    executable_dir: Path,
    bitstream_arg: str | None,
    hwh_arg: str | None,
) -> tuple[Path, Path]:
    bitstream = Path(bitstream_arg).expanduser() if bitstream_arg else first_existing(
        bitstream_candidates(executable_dir)
    )
    if bitstream is None or not bitstream.exists():
        raise RuntimeError(
            "No bitstream path found. Pass --bitstream <path> or place a .bit file next "
            "to the script."
        )

    if hwh_arg:
        hwh = Path(hwh_arg).expanduser()
    else:
        hwh = first_existing(hwh_candidates(bitstream, executable_dir))

    if hwh is None or not hwh.exists():
        raise RuntimeError(
            "No HWH metadata file found. PYNQ Overlay requires a .hwh file alongside "
            "the bitstream metadata. Pass --hwh <path> or use the deliverables target "
            "so the .bit and .hwh are packaged together."
        )

    return bitstream.resolve(), hwh.resolve()


def create_dma(overlay, dma_name: str):
    from pynq.lib.dma import DMA

    if dma_name in overlay.ip_dict:
        return DMA(overlay.ip_dict[dma_name]), dma_name

    dma_candidates = [
        name
        for name, desc in overlay.ip_dict.items()
        if "axi_dma" in str(desc.get("type", ""))
    ]

    if len(dma_candidates) == 1:
        chosen_name = dma_candidates[0]
        return DMA(overlay.ip_dict[chosen_name]), chosen_name

    if dma_candidates:
        raise RuntimeError(
            f"DMA IP '{dma_name}' was not found. Available DMA IPs: {', '.join(sorted(dma_candidates))}."
        )

    raise RuntimeError(
        f"DMA IP '{dma_name}' was not found and no AXI DMA instances were discovered in the overlay."
    )


def close_buffer(buffer) -> None:
    for method_name in ("close", "freebuffer"):
        method = getattr(buffer, method_name, None)
        if callable(method):
            method()
            return


def run_one_transfer(dma, input_buf, output_buf, a: int, b: int) -> tuple[int, int]:
    # The RTL wrappers expect:
    #   tdata[127:64] = a
    #   tdata[63:0]   = b
    input_buf[0] = b
    input_buf[1] = a
    output_buf[:] = 0

    dma.recvchannel.transfer(output_buf)
    dma.sendchannel.transfer(input_buf)
    dma.sendchannel.wait()
    dma.recvchannel.wait()

    return int(output_buf[0]), int(output_buf[1])


def run_engine_tests(engine: str, dma, input_buf, output_buf) -> bool:
    print(f"Running smoke test for engine={engine}")
    all_passed = True

    for index, (a, b) in enumerate(TESTS):
        expected_lo, expected_hi = compute_expected(engine, a, b)
        actual_lo, actual_hi = run_one_transfer(dma, input_buf, output_buf, a, b)
        passed = expected_lo == actual_lo and expected_hi == actual_hi
        all_passed &= passed

        print(
            f"{engine} test[{index}]"
            f" a={hex64(a)}"
            f" b={hex64(b)}"
            f" expected={hex128(expected_hi, expected_lo)}"
            f" actual={hex128(actual_hi, actual_lo)}"
            f" {'PASS' if passed else 'FAIL'}"
        )

    return all_passed


def selected_engines(dut: str) -> list[str]:
    if dut == "both":
        return ["mul", "xor"]
    return [dut]


def main() -> int:
    args = parse_args()
    executable_dir = get_executable_dir(sys.argv[0])
    bitstream_arg = args.bitstream or args.bitstream_pos
    bitstream, hwh = resolve_overlay_files(executable_dir, bitstream_arg, args.hwh)
    temp_overlay_dir = None
    dma_names = {
        "mul": args.mul_dma_name,
        "xor": args.xor_dma_name,
    }
    engines = selected_engines(args.dut)

    print(f"Engines: {', '.join(engines)}")
    print(f"Bitstream: {bitstream}")
    print(f"HWH: {hwh}")
    print(f"Programming PL: {'no' if args.no_program else 'yes'}")

    try:
        try:
            from pynq import Overlay, allocate
        except ImportError as exc:
            raise RuntimeError(
                "The pynq Python package is not installed in this environment."
            ) from exc

        temp_overlay_dir, overlay_bit = stage_overlay_files(bitstream, hwh)
        overlay = Overlay(str(overlay_bit), download=not args.no_program)

        dmas = {}
        for engine in engines:
            dma, actual_dma_name = create_dma(overlay, dma_names[engine])
            dmas[engine] = dma
            if actual_dma_name != dma_names[engine]:
                print(f"{engine} DMA IP: auto-selected {actual_dma_name}")
            else:
                print(f"{engine} DMA IP: {actual_dma_name}")

        input_buf = allocate(shape=(2,), dtype="u8")
        output_buf = allocate(shape=(2,), dtype="u8")

        try:
            all_passed = True
            for engine in engines:
                all_passed &= run_engine_tests(engine, dmas[engine], input_buf, output_buf)

            if not all_passed:
                print("One or more DUT checks failed.", file=sys.stderr)
                return 1

            print("All requested DUT checks passed.")
            return 0
        finally:
            close_buffer(output_buf)
            close_buffer(input_buf)
    except Exception as exc:  # pylint: disable=broad-except
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    finally:
        if temp_overlay_dir is not None:
            temp_overlay_dir.cleanup()


if __name__ == "__main__":
    raise SystemExit(main())
