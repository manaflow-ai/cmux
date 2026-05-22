#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path
from typing import Any


LABELS = ("mac", "iphone", "ipad")


def load_json(path: Path) -> dict[str, Any]:
    try:
        return json.loads(path.read_text())
    except Exception as exc:
        return {"status": "invalid", "error": str(exc)}


def ps_commands_for_pids(pids: list[int]) -> dict[int, str]:
    if not pids:
        return {}
    try:
        result = subprocess.run(
            ["ps", "-p", ",".join(str(pid) for pid in pids), "-o", "pid=,command="],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=10,
            check=False,
        )
    except subprocess.TimeoutExpired:
        return {}
    commands: dict[int, str] = {}
    for line in result.stdout.splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        pid_text, _, command = stripped.partition(" ")
        try:
            commands[int(pid_text)] = command
        except ValueError:
            continue
    return commands


def post_startup_resource_anomalies(path: Path) -> list[dict[str, Any]]:
    anomalies: list[dict[str, Any]] = []
    if not path.exists():
        return [{"status": "missing_resource_log", "path": str(path)}]
    for line_number, line in enumerate(path.read_text().splitlines(), start=1):
        if not line.strip():
            continue
        try:
            item = json.loads(line)
        except json.JSONDecodeError as exc:
            anomalies.append({"line": line_number, "status": "invalid_json", "error": str(exc)})
            continue
        status = item.get("status")
        if status in {"missing", "sample_failed", "pid_changed"}:
            if item.get("startup_grace") is True:
                continue
            if status in {"pid_changed"} and item.get("status") == "pid_changed_startup_grace":
                continue
            anomalies.append({"line": line_number, **item})
        if int(item.get("failures", 0) or 0) > 0:
            anomalies.append({"line": line_number, **item})
    return anomalies


def diagnostic_files(root: Path) -> list[str]:
    diagnostics = root / "diagnostics"
    if not diagnostics.exists():
        return []
    return sorted(str(path) for path in diagnostics.rglob("*") if path.is_file())


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("root", type=Path)
    parser.add_argument("--required-seconds", type=float, default=43200)
    args = parser.parse_args()

    root = args.root
    audit = load_json(root / "audit.json")
    checks = audit.get("checks", {}) if isinstance(audit.get("checks"), dict) else {}

    failures: list[str] = []

    if audit.get("achieved") is not True:
        failures.append("audit.achieved is not true")
    if audit.get("status") != "passed":
        failures.append(f"audit.status is {audit.get('status')!r}, expected 'passed'")

    for name in (*LABELS, "resources"):
        check = checks.get(name, {})
        if check.get("status") != "passed":
            failures.append(f"{name}.status is {check.get('status')!r}, expected 'passed'")
        if int(check.get("failures", 1) or 0) != 0:
            failures.append(f"{name}.failures is {check.get('failures')!r}, expected 0")
        elapsed = float(check.get("elapsed_seconds", 0) or 0)
        if elapsed < args.required_seconds:
            failures.append(f"{name}.elapsed_seconds is {elapsed}, expected >= {args.required_seconds}")

    diagnostics = diagnostic_files(root)
    if diagnostics:
        failures.append(f"diagnostics contains {len(diagnostics)} files")

    anomalies = post_startup_resource_anomalies(root / "resources.jsonl")
    if anomalies:
        failures.append(f"resource anomaly query returned {len(anomalies)} records")

    resource_processes = (
        checks.get("resources", {}).get("processes", {})
        if isinstance(checks.get("resources", {}).get("processes", {}), dict)
        else {}
    )
    pids = [
        int(resource_processes.get(label, {}).get("pid", 0) or 0)
        for label in LABELS
    ]
    commands = ps_commands_for_pids([pid for pid in pids if pid > 0])
    for label in LABELS:
        pid = int(resource_processes.get(label, {}).get("pid", 0) or 0)
        command = commands.get(pid)
        if not pid or command is None:
            failures.append(f"{label}.pid {pid} is not live")
            continue
        if label == "mac" and "cmux DEV swmob.app/Contents/MacOS/cmux DEV" not in command:
            failures.append(f"{label}.pid {pid} does not look like tagged macOS cmux")
        if label in {"iphone", "ipad"} and "cmux.app/cmux" not in command:
            failures.append(f"{label}.pid {pid} does not look like cmux")

    payload = {
        "achieved": not failures,
        "root": str(root),
        "failures": failures,
        "audit": audit,
        "diagnostics": diagnostics[:20],
        "resource_anomalies": anomalies[:20],
    }
    print(json.dumps(payload, indent=2))
    return 0 if not failures else 1


if __name__ == "__main__":
    raise SystemExit(main())
