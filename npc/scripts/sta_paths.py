#!/usr/bin/env python3
"""Summarize setup timing paths from the fast post-synthesis STA flow.

The JSON feature file only keeps a small number of paths, so this script also
accepts the detailed reg-to-reg report.  It groups violating paths by the
module that owns the start/end flop, which is the useful view when iterating
on a frequency target.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from collections import defaultdict
from pathlib import Path
from typing import Any

NUMBER_RE = re.compile(r"[-+]?\d+(?:\.\d+)?")
START_RE = re.compile(r"^\s*Startpoint:\s*(\S+)", re.I)
END_RE = re.compile(r"^\s*Endpoint:\s*(\S+)", re.I)
SLACK_RE = re.compile(r"^\s*slack\b[^0-9+\-]*([-+]?\d+(?:\.\d+)?)", re.I)

MODULE_PREFIXES = (
    "u_mul_unit",
    "u_div_unit",
    "u_dcache",
    "u_icache",
    "u_bpu",
    "u_alu",
    "u_axi_master",
    "u_regfile",
    "u_csr",
    "u_arbiter",
)


def normalize_pin(name: str) -> str:
    """Strip the :Q/:D pin suffix so JSON and report paths de-duplicate."""
    return re.sub(r":[QD]$", "", name.strip())


def module_of(name: str) -> str:
    for prefix in MODULE_PREFIXES:
        if prefix in name:
            return prefix[2:]
    return "cpu_top"


def parse_json(path: Path) -> list[dict[str, Any]]:
    data = json.loads(path.read_text(encoding="utf-8", errors="ignore"))
    paths = data.get("paths", []) if isinstance(data, dict) else []
    result: list[dict[str, Any]] = []
    for item in paths:
        if str(item.get("analysis_type", "")).lower() != "setup":
            continue
        levels = item.get("logic_levels")
        stages = item.get("stages")
        if levels is None and isinstance(stages, list):
            levels = sum(1 for s in stages if s.get("kind") == "cell_arc")
        result.append(
            {
                "start": item.get("start_point", ""),
                "end": item.get("end_point", ""),
                "slack_ns": item.get("slack_ns"),
                "arrival_ns": item.get("arrival_ns"),
                "levels": levels,
            }
        )
    return result


def parse_report(path: Path) -> list[dict[str, Any]]:
    """Best-effort parser for iSTA detailed path reports."""
    text = path.read_text(encoding="utf-8", errors="ignore")
    result: list[dict[str, Any]] = []
    start = end = None
    for line in text.splitlines():
        m = START_RE.match(line)
        if m:
            start = m.group(1)
            continue
        m = END_RE.match(line)
        if m:
            end = m.group(1)
            continue
        m = SLACK_RE.search(line)
        if m and start and end:
            try:
                slack = float(m.group(1))
            except ValueError:
                continue
            if slack < 0:
                result.append(
                    {
                        "start": start,
                        "end": end,
                        "slack_ns": slack,
                        "arrival_ns": None,
                        "levels": None,
                    }
                )
            start = end = None
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json", default="")
    parser.add_argument("--report", default="")
    parser.add_argument("--top", type=int, default=20)
    parser.add_argument("--max-slack", type=float, default=0.0,
                        help="Only show paths with slack < this value (default 0).")
    args = parser.parse_args()

    paths: list[dict[str, Any]] = []
    if args.json and Path(args.json).is_file():
        paths.extend(parse_json(Path(args.json)))
    if args.report and Path(args.report).is_file():
        paths.extend(parse_report(Path(args.report)))
    if not paths:
        print("[sta-paths] no setup paths parsed; check --json/--report", file=sys.stderr)
        return 1

    # De-duplicate on (start, end, slack).
    unique: dict[tuple[str, str, float], dict[str, Any]] = {}
    for item in paths:
        slack = item.get("slack_ns")
        if slack is None:
            continue
        if float(slack) >= args.max_slack:
            continue
        key = (
            normalize_pin(item.get("start", "")),
            normalize_pin(item.get("end", "")),
            round(float(slack), 6),
        )
        unique.setdefault(key, item)

    paths = sorted(unique.values(), key=lambda item: float(item["slack_ns"]))
    if not paths:
        print(f"[sta-paths] no paths with slack < {args.max_slack:g} ns")
        return 0

    def owner(item: dict[str, Any]) -> str:
        end_module = module_of(item.get("end", ""))
        start_module = module_of(item.get("start", ""))
        return end_module if end_module != "cpu_top" else start_module

    by_module: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for item in paths:
        by_module[owner(item)].append(item)

    print(f"{'module':12s} {'count':>5s} {'worst_ns':>9s}  worst start -> end")
    print("-" * 110)
    for module, items in sorted(
        by_module.items(), key=lambda kv: float(kv[1][0]["slack_ns"])
    ):
        worst = items[0]
        print(
            f"{module:12s} {len(items):5d} {float(worst['slack_ns']):+9.3f}  "
            f"{worst.get('start')} -> {worst.get('end')}"
        )

    print()
    print(f"Top {min(args.top, len(paths))} setup paths:")
    for index, item in enumerate(paths[: args.top], 1):
        levels = item.get("levels")
        level_text = f" levels={levels}" if levels is not None else ""
        arrival = item.get("arrival_ns")
        arrival_text = f" arrival={float(arrival):.3f}ns" if arrival is not None else ""
        print(
            f"{index:3d}. {float(item['slack_ns']):+8.3f}ns{arrival_text}{level_text}  "
            f"{owner(item)}: {item.get('start')} -> {item.get('end')}"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
