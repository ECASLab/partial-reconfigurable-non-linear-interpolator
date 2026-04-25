#!/usr/bin/env python3
"""Extract DUT area utilization for the PWL multi-DUT and DFX flows."""

from __future__ import annotations

import argparse
import csv
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable

DUT_IDS = ("exp", "sigmoid", "exp_f16", "sigmoid_f16")
EXP_SLOT_IDS = ("exp", "exp_f16")
SIGMOID_SLOT_IDS = ("sigmoid", "sigmoid_f16")

METRIC_PATTERNS = {
    "lut": re.compile(r"^\|\s*CLB LUTs\*?\s*\|\s*([0-9,]+)\s*\|"),
    "ff": re.compile(r"^\|\s*CLB Registers\s*\|\s*([0-9,]+)\s*\|"),
    "bram_tile": re.compile(r"^\|\s*Block RAM Tile\s*\|\s*([0-9,]+)\s*\|"),
    "dsp": re.compile(r"^\|\s*DSPs\s*\|\s*([0-9,]+)\s*\|"),
}
DEVICE_PATTERN = re.compile(r"^\|\s*Device\s*:\s*(\S+)")
MULTI_SLOT_PATTERN = re.compile(r"^design_1_pwl_(exp|sigmoid)_0_0_synth_1$")
DFX_DUT_PATTERN = re.compile(r"^pwl_(.+)_xci_synth_1$")
RP_REPORT_SUFFIX = "_u_rp_utilization_hierarchical.rpt"


@dataclass
class AreaRow:
    flow: str
    part: str
    project: str
    dut_id: str
    context: str
    lut: int
    ff: int
    bram_tile: int
    dsp: int
    report_path: Path


def normalize_context_group(context: str) -> str:
    if context in {"exp_slot", "sigmoid_slot"}:
        return "slot"
    if context.startswith("rp_impl_"):
        return "rp_impl"
    return context


def build_worst_case_rows(rows: list[AreaRow]) -> list[AreaRow]:
    grouped: dict[tuple[str, str, str, str], list[AreaRow]] = {}
    for row in rows:
        # Avoid re-aggregating synthetic rows.
        if row.dut_id == "worst_of_duts" or row.context.endswith("_worst"):
            continue
        group_key = (row.flow, row.part, row.project, normalize_context_group(row.context))
        grouped.setdefault(group_key, []).append(row)

    worst_rows: list[AreaRow] = []
    for (flow, part, project, context_group), group_rows in grouped.items():
        dut_ids = {r.dut_id for r in group_rows if r.dut_id not in {"unknown_dut", "worst_of_duts"}}
        if len(dut_ids) < 2:
            continue

        worst_rows.append(
            AreaRow(
                flow=flow,
                part=part,
                project=project,
                dut_id="worst_of_duts",
                context=f"{context_group}_worst",
                lut=max(r.lut for r in group_rows),
                ff=max(r.ff for r in group_rows),
                bram_tile=max(r.bram_tile for r in group_rows),
                dsp=max(r.dsp for r in group_rows),
                report_path=Path("<computed>"),
            )
        )

    return worst_rows


def _parse_int(token: str) -> int:
    return int(token.replace(",", ""))


def parse_utilization_report(report_path: Path) -> tuple[str, dict[str, int]]:
    metrics: dict[str, int] = {}
    device = ""

    for line in report_path.read_text(encoding="utf-8", errors="replace").splitlines():
        if not device:
            device_match = DEVICE_PATTERN.match(line)
            if device_match:
                device = device_match.group(1)

        for key, pattern in METRIC_PATTERNS.items():
            if key in metrics:
                continue
            metric_match = pattern.match(line)
            if metric_match:
                metrics[key] = _parse_int(metric_match.group(1))

    missing = [k for k in METRIC_PATTERNS if k not in metrics]
    if missing:
        raise ValueError(
            f"Missing utilization metrics ({', '.join(missing)}) in report: {report_path}"
        )

    if not device:
        device = "unknown"

    return device, metrics


def parse_multi_dut_project_selection(project_name: str, part_tag: str) -> tuple[str, str]:
    prefix = "my_proj_multi_dut_"
    suffix = f"_{part_tag}"

    if not project_name.startswith(prefix) or not project_name.endswith(suffix):
        return "exp", "sigmoid"

    variant_fragment = project_name[len(prefix) : len(project_name) - len(suffix)]
    if variant_fragment == "":
        return "exp", "sigmoid"

    for exp_id in EXP_SLOT_IDS:
        for sigmoid_id in SIGMOID_SLOT_IDS:
            if variant_fragment == f"{exp_id}_{sigmoid_id}":
                return exp_id, sigmoid_id

    raise ValueError(
        "Unable to map multi-DUT project variant fragment "
        f"'{variant_fragment}' from project '{project_name}'."
    )


def discover_multi_dut_rows(build_dir: Path) -> list[AreaRow]:
    pattern = (
        "vivado_multi_dut/*/*/*.runs/"
        "design_1_pwl_*_0_0_synth_1/design_1_pwl_*_0_0_utilization_synth.rpt"
    )
    rows: list[AreaRow] = []

    for report_path in sorted(build_dir.glob(pattern)):
        parts = report_path.parts
        try:
            flow_idx = parts.index("vivado_multi_dut")
            part_tag = parts[flow_idx + 1]
            project_name = parts[flow_idx + 2]
            run_name = parts[flow_idx + 4]
        except (ValueError, IndexError) as exc:
            raise ValueError(f"Unexpected multi-DUT report path format: {report_path}") from exc

        slot_match = MULTI_SLOT_PATTERN.match(run_name)
        if not slot_match:
            continue

        exp_dut_id, sigmoid_dut_id = parse_multi_dut_project_selection(project_name, part_tag)
        slot_name = slot_match.group(1)
        dut_id = exp_dut_id if slot_name == "exp" else sigmoid_dut_id

        device, metrics = parse_utilization_report(report_path)
        rows.append(
            AreaRow(
                flow="multi_dut",
                part=device,
                project=project_name,
                dut_id=dut_id,
                context=f"{slot_name}_slot",
                lut=metrics["lut"],
                ff=metrics["ff"],
                bram_tile=metrics["bram_tile"],
                dsp=metrics["dsp"],
                report_path=report_path,
            )
        )

    return rows


def discover_dfx_rows(build_dir: Path) -> list[AreaRow]:
    pattern = "vivado_pwl_dfx/*/*/*.runs/pwl_*_xci_synth_1/pwl_*_xci_utilization_synth.rpt"
    rows: list[AreaRow] = []

    for report_path in sorted(build_dir.glob(pattern)):
        parts = report_path.parts
        try:
            flow_idx = parts.index("vivado_pwl_dfx")
            project_name = parts[flow_idx + 2]
            run_name = parts[flow_idx + 4]
        except (ValueError, IndexError) as exc:
            raise ValueError(f"Unexpected DFX report path format: {report_path}") from exc

        dut_match = DFX_DUT_PATTERN.match(run_name)
        if not dut_match:
            continue

        dut_id = dut_match.group(1)
        if dut_id not in DUT_IDS:
            continue

        device, metrics = parse_utilization_report(report_path)
        rows.append(
            AreaRow(
                flow="pwl_dfx",
                part=device,
                project=project_name,
                dut_id=dut_id,
                context="rm",
                lut=metrics["lut"],
                ff=metrics["ff"],
                bram_tile=metrics["bram_tile"],
                dsp=metrics["dsp"],
                report_path=report_path,
            )
        )

    return rows


def _parse_hierarchical_row_int(token: str) -> int:
    token = token.strip()
    if token in {"", "-"}:
        return 0
    return _parse_int(token)


def _resolve_dfx_project_for_run(build_dir: Path, run_name: str) -> str:
    run_matches = sorted(build_dir.glob(f"vivado_pwl_dfx/*/*/*.runs/{run_name}"))
    if len(run_matches) == 0:
        return "unknown_project"

    parts = run_matches[0].parts
    try:
        flow_idx = parts.index("vivado_pwl_dfx")
        return parts[flow_idx + 2]
    except (ValueError, IndexError):
        return "unknown_project"


def parse_rp_impl_utilization_report(report_path: Path) -> tuple[str, str, dict[str, int]]:
    device = "unknown"
    module_name = ""
    metrics: dict[str, int] = {}

    for line in report_path.read_text(encoding="utf-8", errors="replace").splitlines():
        if device == "unknown":
            device_match = DEVICE_PATTERN.match(line)
            if device_match:
                device = device_match.group(1)

        # Hierarchical utilization rows use pipe-delimited columns.
        if not line.startswith("|"):
            continue
        cells = [cell.strip() for cell in line.split("|")[1:-1]]
        if len(cells) < 13:
            continue
        if cells[0] != "u_rp":
            continue

        module_name = cells[1]
        try:
            total_luts = _parse_hierarchical_row_int(cells[4])
            total_ffs = _parse_hierarchical_row_int(cells[8])
            ramb36 = _parse_hierarchical_row_int(cells[9])
            ramb18 = _parse_hierarchical_row_int(cells[10])
            dsps = _parse_hierarchical_row_int(cells[12])
        except ValueError as exc:
            raise ValueError(
                f"Could not parse RP hierarchical metrics in report: {report_path}"
            ) from exc

        # One RAMB36 equals one tile. Two RAMB18s can share one tile.
        bram_tiles = ramb36 + ((ramb18 + 1) // 2)
        metrics = {
            "lut": total_luts,
            "ff": total_ffs,
            "bram_tile": bram_tiles,
            "dsp": dsps,
        }
        break

    if not module_name or not metrics:
        raise ValueError(
            "Could not find top-level 'u_rp' utilization row in report: "
            f"{report_path}"
        )

    dut_id = ""
    if module_name.startswith("pwl_rp_"):
        dut_id = module_name[len("pwl_rp_") :]
    if dut_id not in DUT_IDS:
        dut_id = "unknown_dut"

    return device, dut_id, metrics


def discover_dfx_rp_impl_rows(build_dir: Path) -> list[AreaRow]:
    pattern = f"reports/area/rp_partition/*{RP_REPORT_SUFFIX}"
    rows: list[AreaRow] = []

    for report_path in sorted(build_dir.glob(pattern)):
        report_name = report_path.name
        run_name = report_name[: -len(RP_REPORT_SUFFIX)]
        if run_name == "":
            continue

        device, dut_id, metrics = parse_rp_impl_utilization_report(report_path)
        project_name = _resolve_dfx_project_for_run(build_dir, run_name)
        rows.append(
            AreaRow(
                flow="pwl_dfx",
                part=device,
                project=project_name,
                dut_id=dut_id,
                context=f"rp_impl_{run_name}",
                lut=metrics["lut"],
                ff=metrics["ff"],
                bram_tile=metrics["bram_tile"],
                dsp=metrics["dsp"],
                report_path=report_path,
            )
        )

    return rows


def render_table(rows: Iterable[AreaRow], repo_root: Path) -> str:
    headers = [
        "Flow",
        "Part",
        "Project",
        "DUT",
        "Context",
        "LUT",
        "FF",
        "BRAM_TILE",
        "DSP",
        "Report",
    ]

    table_rows: list[list[str]] = []
    for row in rows:
        try:
            report_text = str(row.report_path.relative_to(repo_root))
        except ValueError:
            report_text = str(row.report_path)

        table_rows.append(
            [
                row.flow,
                row.part,
                row.project,
                row.dut_id,
                row.context,
                str(row.lut),
                str(row.ff),
                str(row.bram_tile),
                str(row.dsp),
                report_text,
            ]
        )

    col_widths = [len(h) for h in headers]
    for cells in table_rows:
        for i, cell in enumerate(cells):
            col_widths[i] = max(col_widths[i], len(cell))

    def _format_row(cells: list[str]) -> str:
        return " | ".join(cell.ljust(col_widths[i]) for i, cell in enumerate(cells))

    lines = [_format_row(headers), "-+-".join("-" * w for w in col_widths)]
    lines.extend(_format_row(cells) for cells in table_rows)
    return "\n".join(lines)


def write_csv(rows: Iterable[AreaRow], csv_path: Path) -> None:
    csv_path.parent.mkdir(parents=True, exist_ok=True)
    with csv_path.open("w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f)
        writer.writerow(
            [
                "flow",
                "part",
                "project",
                "dut",
                "context",
                "lut",
                "ff",
                "bram_tile",
                "dsp",
                "report_path",
            ]
        )
        for row in rows:
            writer.writerow(
                [
                    row.flow,
                    row.part,
                    row.project,
                    row.dut_id,
                    row.context,
                    row.lut,
                    row.ff,
                    row.bram_tile,
                    row.dsp,
                    str(row.report_path),
                ]
            )


def write_text_report(table_text: str, txt_path: Path) -> None:
    txt_path.parent.mkdir(parents=True, exist_ok=True)
    txt_path.write_text(f"{table_text}\n", encoding="utf-8")


def sanitize_token(value: str) -> str:
    token = re.sub(r"[^A-Za-z0-9_.-]+", "_", value.strip())
    token = re.sub(r"_+", "_", token)
    token = token.strip("_")
    return token or "all"


def parse_args() -> argparse.Namespace:
    default_repo_root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(
        description=(
            "Extract DUT area utilization from Vivado synthesis reports "
            "for the multi-DUT and DFX PWL flows."
        )
    )
    parser.add_argument(
        "--repo-root",
        type=Path,
        default=default_repo_root,
        help="Path to final-project directory (default: script parent).",
    )
    parser.add_argument(
        "--flow",
        choices=["all", "multi_dut", "dfx", "pwl_dfx"],
        default="all",
        help="Flow to report (default: all).",
    )
    parser.add_argument(
        "--part",
        default="",
        help="Optional part filter (for example: xck26-sfvc784-2LV-c).",
    )
    parser.add_argument(
        "--csv",
        type=Path,
        default=None,
        help="Optional CSV output path (default: auto-generated in build/reports/area).",
    )
    parser.add_argument(
        "--txt",
        type=Path,
        default=None,
        help="Optional text summary output path (default: auto-generated in build/reports/area).",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    repo_root = args.repo_root.resolve()
    build_dir = repo_root / "build"

    rows: list[AreaRow] = []
    if args.flow in {"all", "multi_dut"}:
        rows.extend(discover_multi_dut_rows(build_dir))
    if args.flow in {"all", "dfx", "pwl_dfx"}:
        rows.extend(discover_dfx_rows(build_dir))
        rows.extend(discover_dfx_rp_impl_rows(build_dir))

    rows.extend(build_worst_case_rows(rows))

    part_filter = args.part.strip()
    if part_filter:
        rows = [row for row in rows if row.part == part_filter]

    rows = sorted(rows, key=lambda r: (r.flow, r.part, r.project, r.dut_id, r.context))

    if not rows:
        print(
            "No matching utilization reports were found under "
            f"{build_dir}. Run the Vivado flow first.",
            file=sys.stderr,
        )
        return 1

    table_text = render_table(rows, repo_root)
    print(table_text)

    flow_token = "all" if args.flow == "all" else ("pwl_dfx" if args.flow in {"dfx", "pwl_dfx"} else "multi_dut")
    part_token = sanitize_token(part_filter if part_filter else "all")
    default_report_dir = repo_root / "build" / "reports" / "area"
    default_base_name = f"pwl_area_{flow_token}_{part_token}"

    if args.csv is None:
        csv_path = default_report_dir / f"{default_base_name}.csv"
    else:
        csv_path = args.csv if args.csv.is_absolute() else (Path.cwd() / args.csv)
    csv_path = csv_path.resolve()
    write_csv(rows, csv_path)

    if args.txt is None:
        txt_path = default_report_dir / f"{default_base_name}.txt"
    else:
        txt_path = args.txt if args.txt.is_absolute() else (Path.cwd() / args.txt)
    txt_path = txt_path.resolve()
    write_text_report(table_text, txt_path)

    print(f"\nWrote CSV: {csv_path}")
    print(f"Wrote text report: {txt_path}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
