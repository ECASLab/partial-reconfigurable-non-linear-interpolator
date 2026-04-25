#!/usr/bin/env python3
"""
PYNQ host example for the final-project DFX design.

This design has one static DMA path plus one reconfigurable region named `u_rp`.
The static overlay contains:
  - axi_dma_0
  - axi_gpio_decouple_0
  - axi_gpio_reset_0

The default full bitstream brings `mul` online. A second full bitstream brings
`xor` online. The RP can then be swapped with partial bitstreams.

Typical use:
  ./dfx_pynq.py
  ./dfx_pynq.py --run xor
  ./dfx_pynq.py --run both
  ./dfx_pynq.py --full-rm xor --run both
  ./dfx_pynq.py --no-program --full-rm mul --run xor
"""

from __future__ import annotations

import argparse
import shutil
import sys
import tempfile
import time
from pathlib import Path
from typing import Iterable


DEFAULT_PART_TAG = "xck26_sfvc784_2LV_c"
DEFAULT_DMA_NAME = "axi_dma_0"
DEFAULT_DECOUPLE_GPIO_NAME = "axi_gpio_decouple_0"
DEFAULT_RESET_GPIO_NAME = "axi_gpio_reset_0"

GPIO_DATA_OFFSET = 0x0
GPIO_TRI_OFFSET = 0x4
GPIO2_DATA_OFFSET = 0x8
GPIO2_TRI_OFFSET = 0xC

DECOUPLE_ASSERT_LEVEL = 1
DECOUPLE_RELEASE_LEVEL = 0
RESET_ASSERT_LEVEL = 0
RESET_RELEASE_LEVEL = 1
GPIO_TIMEOUT_SECONDS = 2.0

DELIVERABLE_FULL_BIT_NAMES = {
    "mul": "dfx_full_region_u_rp_rm_mul.bit",
    "xor": "dfx_full_region_u_rp_rm_xor.bit",
}
DELIVERABLE_PARTIAL_BIT_NAMES = {
    "mul": "dfx_partial_region_u_rp_rm_mul.bit",
    "xor": "dfx_partial_region_u_rp_rm_xor.bit",
}

RAW_FULL_BIT_NAME = "dut_64x64_axis_dfx_top.bit"
RAW_PARTIAL_BIT_NAMES = {
    "mul": "u_rp_rp_mul_partial.bit",
    "xor": "u_rp_rp_xor_partial.bit",
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


def compute_expected(rm: str, a: int, b: int) -> tuple[int, int]:
    if rm == "xor":
        return (a ^ b) & 0xFFFFFFFFFFFFFFFF, 0

    product = (a * b) & ((1 << 128) - 1)
    return product & 0xFFFFFFFFFFFFFFFF, (product >> 64) & 0xFFFFFFFFFFFFFFFF


def get_executable_dir(argv0: str) -> Path:
    try:
        return Path(argv0).resolve().parent
    except OSError:
        return Path.cwd()


def full_bitstream_candidates(full_rm: str, executable_dir: Path) -> list[Path]:
    proj_name = f"my_proj_dfx_{DEFAULT_PART_TAG}"
    run_dir = "impl_1" if full_rm == "mul" else "impl_config_xor"
    repo_relative = (
        Path("build")
        / "vivado_dfx"
        / DEFAULT_PART_TAG
        / proj_name
        / f"{proj_name}.runs"
        / run_dir
        / RAW_FULL_BIT_NAME
    )

    deliverable_name = DELIVERABLE_FULL_BIT_NAMES[full_rm]
    return [
        executable_dir / deliverable_name,
        executable_dir / RAW_FULL_BIT_NAME,
        Path.cwd() / deliverable_name,
        Path.cwd() / RAW_FULL_BIT_NAME,
        repo_relative,
        Path("..") / repo_relative,
        Path("final-project") / repo_relative,
    ]


def full_hwh_candidates(full_rm: str, bitstream: Path, executable_dir: Path) -> list[Path]:
    proj_name = f"my_proj_dfx_{DEFAULT_PART_TAG}"
    repo_relative = (
        Path("build")
        / "vivado_dfx"
        / DEFAULT_PART_TAG
        / proj_name
        / f"{proj_name}.gen"
        / "sources_1"
        / "bd"
        / "design_1"
        / "hw_handoff"
        / "design_1.hwh"
    )

    deliverable_name = DELIVERABLE_FULL_BIT_NAMES[full_rm].replace(".bit", ".hwh")
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


def partial_bitstream_candidates(rm: str, executable_dir: Path) -> list[Path]:
    proj_name = f"my_proj_dfx_{DEFAULT_PART_TAG}"
    run_dir = "impl_1" if rm == "mul" else "impl_config_xor"
    repo_relative = (
        Path("build")
        / "vivado_dfx"
        / DEFAULT_PART_TAG
        / proj_name
        / f"{proj_name}.runs"
        / run_dir
        / RAW_PARTIAL_BIT_NAMES[rm]
    )

    deliverable_name = DELIVERABLE_PARTIAL_BIT_NAMES[rm]
    return [
        executable_dir / deliverable_name,
        executable_dir / RAW_PARTIAL_BIT_NAMES[rm],
        Path.cwd() / deliverable_name,
        Path.cwd() / RAW_PARTIAL_BIT_NAMES[rm],
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
        description="Run the DFX AXI-stream design through PYNQ.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument(
        "--full-rm",
        choices=("mul", "xor"),
        default="mul",
        help="Full design configuration to load, or assume is already loaded when using --no-program",
    )
    parser.add_argument(
        "--run",
        choices=("mul", "xor", "both"),
        default="both",
        help="Which reconfigurable module tests to run",
    )
    parser.add_argument("--full-bitstream", help="Path to the full .bit file")
    parser.add_argument("--full-hwh", help="Path to the full .hwh metadata file")
    parser.add_argument("--mul-partial", help="Path to the mul partial .bit file")
    parser.add_argument("--xor-partial", help="Path to the xor partial .bit file")
    parser.add_argument(
        "--dma-name",
        default=DEFAULT_DMA_NAME,
        help="Overlay IP name for the AXI DMA instance",
    )
    parser.add_argument(
        "--decouple-gpio-name",
        default=DEFAULT_DECOUPLE_GPIO_NAME,
        help="Overlay IP name for the dual-channel decouple/status AXI GPIO",
    )
    parser.add_argument(
        "--reset-gpio-name",
        default=DEFAULT_RESET_GPIO_NAME,
        help="Overlay IP name for the RP reset AXI GPIO",
    )
    parser.add_argument(
        "--no-program",
        action="store_true",
        help="Skip the full bitstream download and assume the matching static design is already loaded",
    )
    return parser.parse_args()


def stage_overlay_files(bitstream: Path, hwh: Path) -> tuple[tempfile.TemporaryDirectory[str] | None, Path]:
    bitstream = bitstream.resolve()
    hwh = hwh.resolve()
    matching_hwh = bitstream.with_suffix(".hwh")
    if matching_hwh == hwh:
        return None, bitstream

    temp_dir = tempfile.TemporaryDirectory(prefix="dfx_pynq_full_")
    staged_bit = Path(temp_dir.name) / bitstream.name
    staged_hwh = staged_bit.with_suffix(".hwh")
    shutil.copy2(bitstream, staged_bit)
    shutil.copy2(hwh, staged_hwh)
    return temp_dir, staged_bit


def resolve_full_overlay_files(
    full_rm: str,
    executable_dir: Path,
    full_bitstream_arg: str | None,
    full_hwh_arg: str | None,
) -> tuple[Path, Path]:
    bitstream = Path(full_bitstream_arg).expanduser() if full_bitstream_arg else first_existing(
        full_bitstream_candidates(full_rm, executable_dir)
    )
    if bitstream is None or not bitstream.exists():
        raise RuntimeError(
            "No full DFX bitstream path found. Pass --full-bitstream <path> or use the deliverables target."
        )

    if full_hwh_arg:
        hwh = Path(full_hwh_arg).expanduser()
    else:
        hwh = first_existing(full_hwh_candidates(full_rm, bitstream, executable_dir))

    if hwh is None or not hwh.exists():
        raise RuntimeError(
            "No full DFX HWH metadata file found. Pass --full-hwh <path> or use the deliverables target "
            "so the full bitstream and HWH are packaged together."
        )

    return bitstream.resolve(), hwh.resolve()


def resolve_partial_bitstreams(
    executable_dir: Path,
    mul_partial_arg: str | None,
    xor_partial_arg: str | None,
) -> dict[str, Path]:
    partials = {
        "mul": Path(mul_partial_arg).expanduser() if mul_partial_arg else first_existing(
            partial_bitstream_candidates("mul", executable_dir)
        ),
        "xor": Path(xor_partial_arg).expanduser() if xor_partial_arg else first_existing(
            partial_bitstream_candidates("xor", executable_dir)
        ),
    }

    missing = [rm for rm, path in partials.items() if path is None or not path.exists()]
    if missing:
        raise RuntimeError(
            "Missing partial bitstream(s) for "
            f"{', '.join(missing)}. Pass --mul-partial/--xor-partial or use the deliverables target."
        )

    return {rm: path.resolve() for rm, path in partials.items()}


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
            f"IP '{ip_name}' was not found. Available {type_fragment} IPs: {', '.join(sorted(candidates))}."
        )

    raise RuntimeError(
        f"IP '{ip_name}' was not found and no '{type_fragment}' instances were discovered in the overlay."
    )


class DfxControl:
    def __init__(self, decouple_mmio, reset_mmio):
        self._decouple = decouple_mmio
        self._reset = reset_mmio
        self._configure_directions()

    def _configure_directions(self) -> None:
        self._decouple.write(GPIO_TRI_OFFSET, 0x0)
        self._decouple.write(GPIO2_TRI_OFFSET, 0x1)
        self._reset.write(GPIO_TRI_OFFSET, 0x0)

    def read_decouple_request(self) -> int:
        return self._decouple.read(GPIO_DATA_OFFSET) & 0x1

    def read_decouple_status(self) -> int:
        return self._decouple.read(GPIO2_DATA_OFFSET) & 0x1

    def read_resetn(self) -> int:
        return self._reset.read(GPIO_DATA_OFFSET) & 0x1

    def write_decouple_request(self, level: int) -> None:
        self._decouple.write(GPIO_DATA_OFFSET, level & 0x1)

    def write_resetn(self, level: int) -> None:
        self._reset.write(GPIO_DATA_OFFSET, level & 0x1)

    def wait_for_decouple_status(self, expected_level: int) -> None:
        deadline = time.monotonic() + GPIO_TIMEOUT_SECONDS
        while time.monotonic() < deadline:
            if self.read_decouple_status() == (expected_level & 0x1):
                return
            time.sleep(0.001)
        raise RuntimeError(
            f"Timed out waiting for decouple status to reach {expected_level & 0x1}."
        )

    def bring_region_online(self) -> None:
        self.write_resetn(RESET_RELEASE_LEVEL)
        self.write_decouple_request(DECOUPLE_RELEASE_LEVEL)
        self.wait_for_decouple_status(DECOUPLE_RELEASE_LEVEL)

    def prepare_for_reconfiguration(self) -> None:
        self.write_decouple_request(DECOUPLE_ASSERT_LEVEL)
        self.wait_for_decouple_status(DECOUPLE_ASSERT_LEVEL)
        self.write_resetn(RESET_ASSERT_LEVEL)

    def resume_after_reconfiguration(self) -> None:
        self.write_resetn(RESET_RELEASE_LEVEL)
        self.write_decouple_request(DECOUPLE_RELEASE_LEVEL)
        self.wait_for_decouple_status(DECOUPLE_RELEASE_LEVEL)

    def ensure_region_ready(self) -> None:
        if self.read_resetn() != RESET_RELEASE_LEVEL:
            raise RuntimeError("RP reset is still asserted; the reconfigurable region is not ready for DMA traffic.")
        if self.read_decouple_request() != DECOUPLE_RELEASE_LEVEL:
            raise RuntimeError("Decouple request is still asserted; the reconfigurable region is isolated.")
        if self.read_decouple_status() != DECOUPLE_RELEASE_LEVEL:
            raise RuntimeError("Decouple status is still asserted; the reconfigurable region is isolated.")


def close_buffer(buffer) -> None:
    for method_name in ("close", "freebuffer"):
        method = getattr(buffer, method_name, None)
        if callable(method):
            method()
            return


def run_one_transfer(dma, input_buf, output_buf, a: int, b: int) -> tuple[int, int]:
    input_buf[0] = b
    input_buf[1] = a
    output_buf[:] = 0

    dma.recvchannel.transfer(output_buf)
    dma.sendchannel.transfer(input_buf)
    dma.sendchannel.wait()
    dma.recvchannel.wait()

    return int(output_buf[0]), int(output_buf[1])


def run_rm_tests(rm: str, dma, input_buf, output_buf, dfx_control: DfxControl) -> bool:
    print(f"Running smoke test for rm={rm}")
    dfx_control.ensure_region_ready()
    all_passed = True

    for index, (a, b) in enumerate(TESTS):
        expected_lo, expected_hi = compute_expected(rm, a, b)
        actual_lo, actual_hi = run_one_transfer(dma, input_buf, output_buf, a, b)
        passed = expected_lo == actual_lo and expected_hi == actual_hi
        all_passed &= passed

        print(
            f"{rm} test[{index}]"
            f" a={hex64(a)}"
            f" b={hex64(b)}"
            f" expected={hex128(expected_hi, expected_lo)}"
            f" actual={hex128(actual_hi, actual_lo)}"
            f" {'PASS' if passed else 'FAIL'}"
        )

    return all_passed


def requested_sequence(full_rm: str, run: str) -> list[str]:
    if run == "both":
        other = "xor" if full_rm == "mul" else "mul"
        return [full_rm, other]
    return [run]


def load_partial_bitstream(partial_bit: Path) -> None:
    from pynq.bitstream import Bitstream

    Bitstream(str(partial_bit), partial=True).download()


def main() -> int:
    args = parse_args()
    executable_dir = get_executable_dir(sys.argv[0])
    full_bitstream, full_hwh = resolve_full_overlay_files(
        args.full_rm, executable_dir, args.full_bitstream, args.full_hwh
    )
    partials = resolve_partial_bitstreams(executable_dir, args.mul_partial, args.xor_partial)
    temp_overlay_dir = None
    sequence = requested_sequence(args.full_rm, args.run)

    print(f"Full RM: {args.full_rm}")
    print(f"Run sequence: {', '.join(sequence)}")
    print(f"Full bitstream: {full_bitstream}")
    print(f"Full HWH: {full_hwh}")
    print(f"Mul partial: {partials['mul']}")
    print(f"XOR partial: {partials['xor']}")
    print(f"Programming full design: {'no' if args.no_program else 'yes'}")

    try:
        try:
            from pynq import Overlay, allocate
        except ImportError as exc:
            raise RuntimeError(
                "The pynq Python package is not installed in this environment."
            ) from exc

        temp_overlay_dir, overlay_bit = stage_overlay_files(full_bitstream, full_hwh)
        overlay = Overlay(str(overlay_bit), download=not args.no_program)

        dma, actual_dma_name = create_dma(overlay, args.dma_name)
        if actual_dma_name != args.dma_name:
            print(f"DMA IP: auto-selected {actual_dma_name}")
        else:
            print(f"DMA IP: {actual_dma_name}")

        decouple_mmio, actual_decouple_name = create_mmio(overlay, args.decouple_gpio_name, "axi_gpio")
        reset_mmio, actual_reset_name = create_mmio(overlay, args.reset_gpio_name, "axi_gpio")
        if actual_decouple_name != args.decouple_gpio_name:
            print(f"Decouple GPIO IP: auto-selected {actual_decouple_name}")
        else:
            print(f"Decouple GPIO IP: {actual_decouple_name}")
        if actual_reset_name != args.reset_gpio_name:
            print(f"Reset GPIO IP: auto-selected {actual_reset_name}")
        else:
            print(f"Reset GPIO IP: {actual_reset_name}")

        dfx_control = DfxControl(decouple_mmio, reset_mmio)
        dfx_control.bring_region_online()

        input_buf = allocate(shape=(2,), dtype="u8")
        output_buf = allocate(shape=(2,), dtype="u8")

        try:
            all_passed = True
            current_rm = args.full_rm

            for target_rm in sequence:
                if target_rm != current_rm:
                    print(f"Preparing RP for partial load of {target_rm}.")
                    dfx_control.prepare_for_reconfiguration()
                    load_partial_bitstream(partials[target_rm])
                    dfx_control.resume_after_reconfiguration()
                    current_rm = target_rm
                    print(f"Partial reconfiguration complete: active rm={current_rm}")

                all_passed &= run_rm_tests(target_rm, dma, input_buf, output_buf, dfx_control)

            if not all_passed:
                print("One or more DFX checks failed.", file=sys.stderr)
                return 1

            print("All requested DFX checks passed.")
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
