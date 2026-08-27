#!/usr/bin/env python3
"""Behavior checks for the no-socket `cmux config doctor` command."""

from __future__ import annotations

import glob
import json
import os
import subprocess
import tempfile
from pathlib import Path
from typing import Any


def resolve_cmux_cli() -> str:
    explicit = os.environ.get("CMUX_CLI_BIN") or os.environ.get("CMUX_CLI")
    if explicit and os.path.isfile(explicit) and os.access(explicit, os.X_OK):
        return explicit

    candidates = [
        path
        for path in glob.glob(os.path.expanduser("~/Library/Developer/Xcode/DerivedData/*/Build/Products/Debug/cmux"))
        if os.path.isfile(path) and os.access(path, os.X_OK)
    ]
    if candidates:
        candidates.sort(key=os.path.getmtime, reverse=True)
        return candidates[0]

    raise RuntimeError("Unable to find cmux CLI binary. Set CMUX_CLI_BIN.")


def run_cli(
    cli_path: str,
    args: list[str],
    home: Path,
    cwd: Path | None = None,
) -> subprocess.CompletedProcess[str]:
    env = dict(os.environ)
    env["HOME"] = str(home)
    env["CMUX_CLI_SENTRY_DISABLED"] = "1"
    env["CMUX_SOCKET_PATH"] = str(home / "missing.sock")
    env.pop("CMUX_SOCKET", None)
    env.pop("CMUX_SOCKET_PASSWORD", None)
    env.pop("CMUX_WORKSPACE_ID", None)
    env.pop("CMUX_SURFACE_ID", None)
    env.pop("CMUX_TAB_ID", None)
    return subprocess.run(
        [cli_path, *args],
        text=True,
        capture_output=True,
        cwd=str(cwd) if cwd is not None else None,
        env=env,
        timeout=5,
        check=False,
    )


def parse_json_output(raw: str, label: str, failures: list[str]) -> dict[str, Any] | None:
    try:
        payload = json.loads(raw)
    except json.JSONDecodeError as exc:
        failures.append(f"{label}: stdout is not valid JSON ({exc}): {raw!r}")
        return None
    if not isinstance(payload, dict):
        failures.append(f"{label}: stdout JSON is not an object: {raw!r}")
        return None
    return payload


def first_finding(
    payload: dict[str, Any],
    label: str,
    raw: str,
    failures: list[str],
) -> dict[str, Any] | None:
    findings = payload.get("findings")
    if not isinstance(findings, list) or not findings:
        failures.append(f"{label}: findings array is empty or missing: {raw}")
        return None
    finding = findings[0]
    if not isinstance(finding, dict):
        failures.append(f"{label}: first finding is not an object: {raw}")
        return None
    return finding


def main() -> int:
    cli_path = resolve_cmux_cli()
    failures: list[str] = []

    with tempfile.TemporaryDirectory(prefix="cmux-config-doctor-") as temp:
        home = Path(temp)
        workspace = home / "workspace" / "child"
        workspace.mkdir(parents=True)
        (home / "cmux.json").write_text('{"homeLevel": true,,}\n', encoding="utf-8")
        config_path = home / ".config" / "cmux" / "cmux.json"
        config_path.parent.mkdir(parents=True)
        config_path.write_text(
            """
            {
              // JSONC comments and trailing commas are valid in cmux.json.
              "schemaVersion": 1,
              "app": {
                "appearance": "system",
              },
            }
            """,
            encoding="utf-8",
        )

        ok_result = run_cli(cli_path, ["--json", "config", "doctor", "--path", str(config_path)], home)
        if ok_result.returncode != 0:
            failures.append(f"valid JSONC returned {ok_result.returncode}: {ok_result.stderr}")
        else:
            payload = parse_json_output(ok_result.stdout, "valid JSONC", failures)
            if payload is not None:
                finding = first_finding(payload, "valid JSONC", ok_result.stdout, failures)
                if finding is not None:
                    if payload.get("ok") is not True or finding.get("status") != "ok":
                        failures.append(f"valid JSONC was not ok: {ok_result.stdout}")
                    keys_raw = finding.get("keys", [])
                    keys = keys_raw if isinstance(keys_raw, list) else []
                    if "app" not in keys or "schemaVersion" not in keys:
                        failures.append(f"valid JSONC keys missing: {ok_result.stdout}")

        default_result = run_cli(cli_path, ["--json", "config", "doctor"], home, cwd=workspace)
        if default_result.returncode != 0:
            failures.append(f"default scan returned {default_result.returncode}: {default_result.stderr}")
        else:
            payload = parse_json_output(default_result.stdout, "default scan", failures)
            if payload is not None:
                findings = payload.get("findings", [])
                if not isinstance(findings, list):
                    failures.append(f"default scan findings were not a list: {default_result.stdout}")
                else:
                    primary = next(
                        (
                            finding
                            for finding in findings
                            if isinstance(finding, dict) and finding.get("label") == "primary"
                        ),
                        None,
                    )
                    if primary is None or primary.get("status") != "ok":
                        failures.append(f"default scan primary finding was not ok: {default_result.stdout}")
                    if any(
                        isinstance(finding, dict) and finding.get("path") == str(home / "cmux.json")
                        for finding in findings
                    ):
                        failures.append(f"default scan included home-level cmux.json: {default_result.stdout}")

        config_path.write_text('{"agent": true,,}\n', encoding="utf-8")
        bad_result = run_cli(cli_path, ["--json", "config", "doctor", "--path", str(config_path)], home)
        if bad_result.returncode == 0:
            failures.append("invalid JSON returned success")
        else:
            payload = parse_json_output(bad_result.stdout, "invalid JSON", failures)
            if payload is not None:
                finding = first_finding(payload, "invalid JSON", bad_result.stdout, failures)
                if finding is not None and (payload.get("ok") is not False or finding.get("status") != "error"):
                    failures.append(f"invalid JSON did not report an error: {bad_result.stdout}")
            if "cmux config doctor found 1 error(s)" not in bad_result.stderr:
                failures.append(f"invalid JSON stderr was unexpected: {bad_result.stderr}")

        directory_path = home / "config-directory"
        directory_path.mkdir()
        directory_result = run_cli(cli_path, ["--json", "config", "doctor", "--path", str(directory_path)], home)
        if directory_result.returncode == 0:
            failures.append("directory path returned success")
        else:
            payload = parse_json_output(directory_result.stdout, "directory path", failures)
            if payload is not None:
                finding = first_finding(payload, "directory path", directory_result.stdout, failures)
                if finding is not None:
                    if payload.get("ok") is not False or finding.get("status") != "error":
                        failures.append(f"directory path did not report an error: {directory_result.stdout}")
                    if finding.get("message") != "path is a directory, expected a file":
                        failures.append(f"directory path message was unexpected: {directory_result.stdout}")

        positional_result = run_cli(cli_path, ["config", "doctor", str(config_path)], home, cwd=workspace)
        if positional_result.returncode == 0:
            failures.append("positional config doctor path returned success")
        elif "Use --path <path>" not in positional_result.stderr:
            failures.append(f"positional path error was unexpected: {positional_result.stderr}")

    if failures:
        for failure in failures:
            print(f"FAIL: {failure}")
        return 1

    print("PASS: cmux config doctor validates JSONC and reports syntax errors")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
