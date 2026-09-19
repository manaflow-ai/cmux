#!/usr/bin/env python3
"""Behavior checks for the no-socket `cmux config doctor` command."""

from __future__ import annotations

import glob
import json
import os
import subprocess
import sys
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


def semantic_issues(payload: dict[str, Any]) -> list[dict[str, Any]]:
    issues: list[dict[str, Any]] = []
    findings = payload.get("findings")
    if not isinstance(findings, list):
        return issues
    for finding in findings:
        if not isinstance(finding, dict):
            continue
        raw_issues = finding.get("issues")
        if isinstance(raw_issues, list):
            issues.extend(issue for issue in raw_issues if isinstance(issue, dict))
    return issues


def main() -> int:
    cli_path = resolve_cmux_cli()
    failures: list[str] = []
    repo_root = Path(__file__).resolve().parents[1]

    generator_result = subprocess.run(
        [sys.executable, str(repo_root / "scripts" / "generate-cmux-config-schema.py"), "--check"],
        text=True,
        capture_output=True,
        check=False,
    )
    if generator_result.returncode != 0:
        failures.append(
            "embedded schema is stale: "
            + (generator_result.stdout.strip() or generator_result.stderr.strip())
        )

    with tempfile.TemporaryDirectory(prefix="cmux-config-doctor-") as temp:
        home = Path(temp)
        workspace = home / "workspace" / "child"
        workspace.mkdir(parents=True)
        (home / "cmux.json").write_text('{"homeLevel": true,,}\n', encoding="utf-8")
        config_path = home / ".config" / "cmux" / "cmux.json"
        config_path.parent.mkdir(parents=True)
        custom_global_path = home / "custom-global" / "cmux.json"
        custom_global_path.parent.mkdir()
        custom_global_path.write_text(
            json.dumps({"app": {"appearance": "dark"}}) + "\n",
            encoding="utf-8",
        )
        custom_global_validate = subprocess.run(
            [
                sys.executable,
                str(helper),
                "--file",
                str(custom_global_path),
                "validate",
            ],
            text=True,
            capture_output=True,
            cwd=workspace,
            env=helper_env,
            timeout=5,
            check=False,
        )
        if custom_global_validate.returncode != 0:
            failures.append(
                "custom global cmux.json was misclassified as project-local: "
                + custom_global_validate.stderr
            )

        explicit_project_validate = subprocess.run(
            [
                sys.executable,
                str(helper),
                "--file",
                str(custom_global_path),
                "--scope",
                "project",
                "validate",
            ],
            text=True,
            capture_output=True,
            cwd=workspace,
            env=helper_env,
            timeout=5,
            check=False,
        )
        if explicit_project_validate.returncode == 0:
            failures.append("cmux-settings --scope project did not reject global-only app settings")
        if "$.app" not in explicit_project_validate.stderr:
            failures.append(
                "cmux-settings --scope project did not report the rejected app path: "
                + explicit_project_validate.stderr
            )

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

        semantic_cases = [
            (
                "unknown setting",
                {"app": {"madeUpSetting": True}},
                "$.app.madeUpSetting",
                "unknown configuration key",
            ),
            (
                "wrong value type",
                {"notifications": {"dockBadge": "yes"}},
                "$.notifications.dockBadge",
                "expected boolean",
            ),
            (
                "enum violation",
                {"app": {"appearance": "neon"}},
                "$.app.appearance",
                "must be one of",
            ),
            (
                "numeric bounds",
                {"fileEditor": {"tabWidth": 0}},
                "$.fileEditor.tabWidth",
                "must be >= 1",
            ),
            (
                "malformed nested value",
                {"agentChat": {"fonts": {"baseSize": 0}}},
                "$.agentChat.fonts.baseSize",
                "must be > 0",
            ),
            (
                "structural config section",
                {"commands": "echo hello"},
                "$.commands",
                "expected array",
            ),
        ]
        for label, document, expected_path, expected_message in semantic_cases:
            config_path.write_text(json.dumps(document) + "\n", encoding="utf-8")
            result = run_cli(
                cli_path,
                [
                    "--json",
                    "config",
                    "validate",
                    "--path",
                    str(config_path),
                    "--scope",
                    "global",
                ],
                home,
            )
            if result.returncode == 0:
                failures.append(f"{label}: semantic validation unexpectedly passed")
                continue
            payload = parse_json_output(result.stdout, label, failures)
            if payload is None:
                continue
            issues = semantic_issues(payload)
            if not any(
                issue.get("path") == expected_path
                and expected_message in str(issue.get("message", ""))
                for issue in issues
            ):
                failures.append(
                    f"{label}: expected {expected_path!r} / {expected_message!r}: {result.stdout}"
                )

        config_path.write_text(
            json.dumps({"app": {"appearance": "system"}}) + "\n",
            encoding="utf-8",
        )
        project_global_result = run_cli(
            cli_path,
            [
                "--json",
                "config",
                "validate",
                "--path",
                str(config_path),
                "--scope",
                "project",
            ],
            home,
        )
        if project_global_result.returncode == 0:
            failures.append("project scope accepted global-only app settings")
        else:
            payload = parse_json_output(
                project_global_result.stdout,
                "project/global difference",
                failures,
            )
            if payload is not None:
                issues = semantic_issues(payload)
                if not any(
                    issue.get("path") == "$.app"
                    and "global cmux.json" in str(issue.get("message", ""))
                    for issue in issues
                ):
                    failures.append(
                        "project/global difference did not identify $.app: "
                        + project_global_result.stdout
                    )

        config_path.write_text(
            json.dumps({"notifications": {"hooksMode": "replace", "hooks": []}}) + "\n",
            encoding="utf-8",
        )
        project_hooks_result = run_cli(
            cli_path,
            [
                "--json",
                "config",
                "validate",
                "--path",
                str(config_path),
                "--scope",
                "project",
            ],
            home,
        )
        if project_hooks_result.returncode != 0:
            failures.append(
                "project notification hooks should be valid: "
                + project_hooks_result.stdout
                + project_hooks_result.stderr
            )

        original_bytes = b"""{
  // Preserve this exact source when the proposed edit is invalid.
  "app": {
    "appearance": "dark",
  },
}
"""
        config_path.write_bytes(original_bytes)
        helper = repo_root / "skills" / "cmux-settings" / "scripts" / "cmux-settings"
        helper_env = dict(os.environ)
        helper_env["HOME"] = str(home)
        helper_env["CMUX_CLI_BIN"] = cli_path
        helper_env["CMUX_CLI_SENTRY_DISABLED"] = "1"
        helper_result = subprocess.run(
            [
                sys.executable,
                str(helper),
                "--file",
                str(config_path),
                "set",
                "app.appearance",
                "neon",
            ],
            text=True,
            capture_output=True,
            env=helper_env,
            timeout=5,
            check=False,
        )
        if helper_result.returncode == 0:
            failures.append("cmux-settings set accepted an invalid enum value")
        if config_path.read_bytes() != original_bytes:
            failures.append("rejected cmux-settings set changed the source bytes")
        if "$.app.appearance" not in helper_result.stderr:
            failures.append(
                "rejected cmux-settings set did not report the config path: "
                + helper_result.stderr
            )

        config_path.write_text(
            json.dumps({"app": {"appearance": "neon"}}) + "\n",
            encoding="utf-8",
        )
        helper_validate_result = subprocess.run(
            [sys.executable, str(helper), "--file", str(config_path), "validate"],
            text=True,
            capture_output=True,
            env=helper_env,
            timeout=5,
            check=False,
        )
        if helper_validate_result.returncode == 0:
            failures.append("cmux-settings validate accepted an invalid enum value")
        if "$.app.appearance" not in helper_validate_result.stderr:
            failures.append(
                "cmux-settings validate did not report the config path: "
                + helper_validate_result.stderr
            )

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
