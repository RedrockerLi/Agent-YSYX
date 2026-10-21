#!/usr/bin/env python3
"""Summarize ECC post-synthesis STA reports for the fast iteration flow.

This script is intentionally tolerant of report-schema differences: if a field
cannot be parsed it records null and prints the raw report head, rather than
failing the whole run.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable

FLOAT_RE = re.compile(r"[-+]?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?")

SLACK_KEYS = {
    "slack",
    "slack_ns",
    "worst_slack",
    "setup_slack",
    "slack_value",
    "timing_slack",
}
START_KEYS = {
    "start",
    "start_point",
    "startpoint",
    "from",
    "from_pin",
    "launch",
    "launch_pin",
    "source",
}
END_KEYS = {
    "end",
    "end_point",
    "endpoint",
    "to",
    "to_pin",
    "capture",
    "capture_pin",
    "sink",
}
DELAY_KEYS = {
    "delay",
    "path_delay",
    "arrival",
    "arrival_time",
    "data_arrival",
    "delay_ns",
    "arrival_ns",
}
LEVEL_KEYS = {
    "logic_levels",
    "levels",
    "logic_depth",
    "depth",
    "level",
}


def numbers(text: str) -> list[float]:
    return [float(x) for x in FLOAT_RE.findall(text)]


def first_after_key(line: str, key: str) -> float | None:
    match = re.search(rf"{key}[^0-9+\-]*([-+]?\d+(?:\.\d+)?)", line, re.I)
    return float(match.group(1)) if match else None


def parse_summary(text: str) -> dict[str, float | int | None]:
    """Parse ECC's qor_summary.rpt table.

    The report format is:
        Path Group   WNS  TNS  NVP  FREQ  WNS(H)  TNS(H)  NVP(H)
        ...
        Summary      ...
    """
    lines = text.splitlines()
    result: dict[str, float | int | None] = {
        "wns_ns": None,
        "tns_ns": None,
        "hold_wns_ns": None,
        "hold_tns_ns": None,
        "nvp": None,
        "estimated_fmax_mhz": None,
    }

    for idx, line in enumerate(lines):
        low = line.lower()
        if "path group" not in low or "wns" not in low or "tns" not in low:
            continue
        rows = [row for row in lines[idx + 1 :] if row.strip()]
        summary_row = next((row for row in rows if row.strip().startswith("Summary")), None)
        data_row = summary_row
        if data_row is None:
            data_row = next(
                (row for row in rows if row.strip().startswith(("clock", "Summary"))),
                None,
            )
        if data_row is None:
            data_row = next((row for row in rows if len(numbers(row)) >= 2), None)
        if data_row is not None:
            nums = numbers(data_row)
            if len(nums) >= 2:
                result["wns_ns"] = nums[0]
                result["tns_ns"] = nums[1]
            if len(nums) >= 3:
                result["nvp"] = int(nums[2])
            if len(nums) >= 4:
                result["estimated_fmax_mhz"] = nums[3]
            if len(nums) >= 6:
                result["hold_wns_ns"] = nums[4]
                result["hold_tns_ns"] = nums[5]
            return result

    # Fallback for reports that expose key/value lines instead of a table.
    for line in lines:
        low = line.lower()
        if result["wns_ns"] is None and re.search(r"\bwns\b", low):
            result["wns_ns"] = first_after_key(line, "wns")
        if result["tns_ns"] is None and re.search(r"\btns\b", low):
            result["tns_ns"] = first_after_key(line, "tns")

    if result["wns_ns"] is None:
        slack_values: list[float] = []
        for line in lines:
            if "slack" in line.lower():
                slack_values.extend(numbers(line))
        if slack_values:
            result["wns_ns"] = min(slack_values)
    return result


def get_ci(mapping: dict[str, Any], names: set[str]) -> Any:
    for key, value in mapping.items():
        normalized = str(key).lower().replace("-", "_")
        if normalized in names:
            return value
    return None


def to_float(value: Any) -> float | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, str):
        match = FLOAT_RE.search(value)
        return float(match.group(0)) if match else None
    return None


def to_text(value: Any) -> str | None:
    if value is None:
        return None
    if isinstance(value, dict):
        for key in ("name", "pin", "instance", "cell", "port", "endpoint", "startpoint"):
            if key in value and value[key] is not None:
                return str(value[key])
        return json.dumps(value, ensure_ascii=False, sort_keys=True)
    if isinstance(value, list):
        return ", ".join(filter(None, (to_text(item) for item in value)))
    return str(value)


def collect_paths(obj: Any, out: list[dict[str, Any]]) -> None:
    if isinstance(obj, dict):
        slack = to_float(get_ci(obj, SLACK_KEYS))
        if slack is not None:
            start = to_text(get_ci(obj, START_KEYS))
            end = to_text(get_ci(obj, END_KEYS))
            delay = to_float(get_ci(obj, DELAY_KEYS))
            levels_raw = get_ci(obj, LEVEL_KEYS)
            levels = int(to_float(levels_raw)) if to_float(levels_raw) is not None else None
            stages = obj.get("stages")
            if levels is None and isinstance(stages, list):
                levels = sum(
                    1
                    for stage in stages
                    if isinstance(stage, dict) and stage.get("kind") == "cell_arc"
                )
            out.append(
                {
                    "start": start,
                    "end": end,
                    "slack_ns": slack,
                    "delay_ns": delay,
                    "logic_levels": levels,
                    "analysis_type": to_text(get_ci(obj, {"analysis_type"})),
                }
            )
        for value in obj.values():
            collect_paths(value, out)
    elif isinstance(obj, list):
        for value in obj:
            collect_paths(value, out)


def top_paths_from_json(path: Path | None) -> list[dict[str, Any]]:
    if path is None or not path.is_file():
        return []
    try:
        data = json.loads(path.read_text(encoding="utf-8", errors="ignore"))
    except Exception as exc:  # noqa: BLE001 - report schema is external
        print(f"[sta-fast] WARNING: cannot parse {path}: {exc}", file=sys.stderr)
        return []

    raw_paths: list[dict[str, Any]] = []
    collect_paths(data, raw_paths)

    # De-duplicate by start/end/slack, then keep the worst (most negative) paths.
    unique: dict[tuple[str, str, float], dict[str, Any]] = {}
    for item in raw_paths:
        key = (
            item.get("start") or "",
            item.get("end") or "",
            round(float(item["slack_ns"]), 6),
        )
        unique.setdefault(key, item)

    paths = sorted(unique.values(), key=lambda item: item["slack_ns"])
    if not paths:
        if isinstance(data, dict):
            keys = ", ".join(map(str, data.keys()))
            print(
                "[sta-fast] WARNING: no slack entries found in timing_paths.json; "
                f"top-level keys: {keys}",
                file=sys.stderr,
            )
        else:
            print(
                "[sta-fast] WARNING: no slack entries found in timing_paths.json",
                file=sys.stderr,
            )
    return paths[:10]


def sha256_files(files: Iterable[Path]) -> str | None:
    file_list = list(files)
    if not file_list:
        return None
    digest = hashlib.sha256()
    for path in file_list:
        digest.update(path.name.encode("utf-8", errors="ignore"))
        digest.update(b"\0")
        digest.update(path.read_bytes())
        digest.update(b"\0")
    return digest.hexdigest()


def rtl_and_origin_hashes(
    vsrc_dir: Path, workspace_path: Path
) -> tuple[str | None, str | None, bool | None]:
    rtl_files = sorted(
        path for path in vsrc_dir.glob("*.v") if path.name != "sim_top.v"
    )
    rtl_hash = sha256_files(rtl_files)

    origin_dir = workspace_path / "origin"
    if not origin_dir.is_dir():
        print(
            f"[sta-fast] WARNING: origin directory not found: {origin_dir}",
            file=sys.stderr,
        )
        return rtl_hash, None, None

    origin_files: list[Path] = []
    for rtl_file in rtl_files:
        matches = sorted(origin_dir.rglob(rtl_file.name))
        if not matches:
            print(
                f"[sta-fast] WARNING: origin copy not found for {rtl_file.name}",
                file=sys.stderr,
            )
            return rtl_hash, None, None
        origin_files.append(matches[0])

    origin_hash = sha256_files(origin_files)
    return rtl_hash, origin_hash, origin_hash != rtl_hash


def sdc_hash(workspace_path: Path) -> str | None:
    origin_dir = workspace_path / "origin"
    candidates = sorted(origin_dir.glob("*.sdc"))
    return sha256_files(candidates[:1]) if candidates else None


def git_value(repo_dir: Path, *args: str) -> str | None:
    try:
        result = subprocess.run(
            ["git", "-C", str(repo_dir), *args],
            capture_output=True,
            text=True,
            check=False,
        )
    except OSError:
        return None
    return result.stdout.strip() if result.returncode == 0 else None


def parse_time_file(path: Path | None) -> tuple[int | None, int | None]:
    elapsed: int | None = None
    maxrss: int | None = None
    if path is None or not path.is_file():
        return elapsed, maxrss
    for line in path.read_text(encoding="utf-8", errors="ignore").splitlines():
        if line.startswith("elapsed_s="):
            try:
                elapsed = int(float(line.split("=", 1)[1]))
            except ValueError:
                pass
        elif line.startswith("maxrss_kb="):
            try:
                maxrss = int(float(line.split("=", 1)[1]))
            except ValueError:
                pass
    return elapsed, maxrss


def fmt(value: float | None) -> str:
    return "n/a" if value is None else f"{value:+.3f}"


def display_path(path: Path, repo_dir: Path) -> str:
    """Prefer a repo-relative path so manifests are readable on the host."""
    try:
        return str(path.resolve().relative_to(repo_dir.resolve()))
    except ValueError:
        return str(path.resolve())


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", required=True)
    parser.add_argument("--json", default="")
    parser.add_argument("--out", required=True)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--freq", required=True)
    parser.add_argument("--workspace", required=True)
    parser.add_argument("--workspace-path", required=True)
    parser.add_argument("--vsrc-dir", required=True)
    parser.add_argument("--repo-dir", required=True)
    parser.add_argument("--time-file", default="")
    args = parser.parse_args()

    report_path = Path(args.report)
    feature_path = Path(args.json) if args.json else None
    workspace_path = Path(args.workspace_path)
    out_path = Path(args.out)
    time_path = Path(args.time_file) if args.time_file else None
    repo_dir = Path(args.repo_dir)

    report_text = report_path.read_text(encoding="utf-8", errors="ignore")
    summary = parse_summary(report_text)
    wns = summary["wns_ns"]
    tns = summary["tns_ns"]
    paths = top_paths_from_json(feature_path)
    rtl_hash, origin_hash, origin_mismatch = rtl_and_origin_hashes(
        Path(args.vsrc_dir), workspace_path
    )
    elapsed_s, maxrss_kb = parse_time_file(time_path)
    git_rev = git_value(repo_dir, "rev-parse", "--short", "HEAD")
    git_dirty = bool(git_value(repo_dir, "status", "--porcelain"))

    manifest = {
        "run_id": args.run_id,
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "git_rev": git_rev,
        "git_dirty": git_dirty,
        "frequency_mhz": float(args.freq),
        "workspace": args.workspace,
        "report": display_path(report_path, repo_dir),
        "feature": display_path(feature_path, repo_dir)
        if feature_path and feature_path.is_file()
        else None,
        "wns_ns": wns,
        "tns_ns": tns,
        "hold_wns_ns": summary["hold_wns_ns"],
        "hold_tns_ns": summary["hold_tns_ns"],
        "nvp": summary["nvp"],
        "estimated_fmax_mhz": summary["estimated_fmax_mhz"],
        "top_paths": paths,
        "rtl_sha256": rtl_hash,
        "origin_rtl_sha256": origin_hash,
        "origin_mismatch": origin_mismatch,
        "sdc_sha256": sdc_hash(workspace_path),
        "elapsed_s": elapsed_s,
        "maxrss_kb": maxrss_kb,
    }

    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(manifest, indent=2, ensure_ascii=False), encoding="utf-8")

    fmax = summary["estimated_fmax_mhz"]
    fmax_text = f" Fmax~{fmax:g}MHz" if fmax is not None else ""
    print(
        f"[sta-fast] run={args.run_id} freq={float(args.freq):g}MHz "
        f"WNS={fmt(wns)}ns TNS={fmt(tns)}ns{fmax_text}"
    )
    if paths:
        worst = next(
            (path for path in paths if path.get("analysis_type") == "setup"),
            paths[0],
        )
        print(
            f"[sta-fast] worst: {worst.get('start')} -> {worst.get('end')} "
            f"slack={fmt(worst.get('slack_ns'))}ns"
        )
    else:
        print("[sta-fast] no parsed timing paths (see warnings above)")
    print(f"[sta-fast] manifest: {out_path}")

    if origin_mismatch:
        print(
            "[sta-fast] WARNING: origin RTL hash differs from npc/vsrc; "
            "the STA may have used stale RTL.",
            file=sys.stderr,
        )

    if wns is None:
        print(
            "[sta-fast] WARNING: WNS/TNS not parsed; report head follows:",
            file=sys.stderr,
        )
        for line in report_text.splitlines()[:40]:
            print("  " + line, file=sys.stderr)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
