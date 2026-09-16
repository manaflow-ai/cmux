#!/usr/bin/env python3
"""Static and black-box parity checks for the native Rust cmux CLI.

The Swift CLI is intentionally still used as the source of the compatibility
inventory while the migration is in flight.  This script does two things:

* extracts the top-level labels from the real Swift dispatcher and reports any
  label that is not mentioned by a Rust command module; and
* probes a built Rust executable using commands that must never open a socket.

The source check is useful before a build exists.  The black-box checks accept
the release executable with ``--binary`` (or ``CMUX_RUST_CLI_BIN``), so CI and
the remote Mac build can use the exact artifact that will be bundled.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Iterable


ROOT = Path(__file__).resolve().parents[1]
SWIFT_DISPATCHER = ROOT / "CLI" / "cmux.swift"
RUST_COMMAND_DIR = ROOT / "Native" / "CmuxCLI" / "src" / "commands"
COMMAND_MANIFEST = ROOT / "Native" / "CmuxCLI" / "commands.json"

# Commands handled before Swift's socket switch. They are part of the public
# invocation contract and must remain native Rust commands too. Keep this list
# deliberately short: the dispatcher labels below remain the source of truth
# for socket-backed commands.
NO_SOCKET_COMMANDS = {
    "welcome",
    "guide",
    "docs",
    "settings",
    "config",
    "shortcuts",
    "disable-browser",
    "enable-browser",
    "browser-status",
    "restore-session",
    "feedback",
    "themes",
    "feed",
    "events",
    "open",
    "diff",
    "automation",
    "sessions",
    "auth",
    "coderouter",
    "cr",
    "--skill",
    "--help",
    "-h",
    "--version",
    "-v",
    "help",
    "version",
}


def _quoted_labels(text: str) -> set[str]:
    """Return string labels from a Swift ``case`` line."""

    return set(re.findall(r'"([A-Za-z0-9_+.-]+)"', text))


def swift_dispatch_labels(path: Path = SWIFT_DISPATCHER) -> set[str]:
    """Extract top-level ``switch command`` labels from ``CLI/cmux.swift``.

    The dispatcher cases use eight spaces of indentation. Nested switches use
    at least twelve, making indentation a safer boundary than trying to parse
    Swift interpolation and closure braces with a regular expression.
    """

    lines = path.read_text(encoding="utf-8").splitlines()
    switch_line = next(
        i for i, line in enumerate(lines) if line.strip() == "switch command {"
    )
    labels: set[str] = set()
    pending: list[str] = []
    for line in lines[switch_line + 1 :]:
        if "throw unknownCommandError(command)" in line:
            break
        match = re.match(r"^        case\s+(.*)", line)
        if match:
            pending = [match.group(1)]
        elif pending:
            pending.append(line.strip())
        if pending and ":" in pending[-1]:
            labels.update(_quoted_labels(" ".join(pending).split(":", 1)[0]))
            pending = []
    return labels


def swift_early_commands(path: Path = SWIFT_DISPATCHER) -> set[str]:
    source = path.read_text(encoding="utf-8")
    start = source.index("func run() async throws {")
    end = source.index("switch command {", start)
    return set(re.findall(r'\bcommand\s*==\s*"([^"\\]+)"', source[start:end]))


def rust_module_labels(directory: Path = RUST_COMMAND_DIR) -> dict[str, set[str]]:
    """Collect command-looking literals from each Rust command module.

    Command modules intentionally keep their public labels next to ``run``.
    Collecting all quoted labels gives a conservative inventory while allowing
    aliases and compact one-line match arms. The parity report only uses this
    as evidence that a module claims a label; runtime tests validate behavior.
    """

    result: dict[str, set[str]] = {}
    for source in sorted(directory.glob("*.rs")):
        if source.name == "mod.rs":
            continue
        text = source.read_text(encoding="utf-8")
        result[source.stem] = _quoted_labels(text)
    result["core"] = _quoted_labels((directory.parent / "lib.rs").read_text(encoding="utf-8"))
    return result


def command_owners(labels: Iterable[str], modules: dict[str, set[str]]) -> dict[str, list[str]]:
    owners: dict[str, list[str]] = {}
    for label in sorted(set(labels)):
        owners[label] = sorted(name for name, claimed in modules.items() if label in claimed)
    return owners


def source_report() -> dict[str, object]:
    swift = swift_dispatch_labels()
    early = swift_early_commands() | NO_SOCKET_COMMANDS
    required = swift | early
    modules = rust_module_labels()
    owners = command_owners(required, modules)
    manifest = None
    manifest_error = None
    if COMMAND_MANIFEST.exists():
        try:
            manifest = json.loads(COMMAND_MANIFEST.read_text(encoding="utf-8"))
            listed = {item["label"] for item in manifest.get("commands", [])}
            if listed != set(swift):
                manifest_error = (
                    f"commands.json labels differ from Swift dispatcher "
                    f"(missing={sorted(set(swift) - listed)}, extra={sorted(listed - set(swift))})"
                )
        except (OSError, json.JSONDecodeError, KeyError, TypeError) as exc:
            manifest_error = f"invalid commands.json: {exc}"

    required_rust = set(early)
    if isinstance(manifest, dict):
        for item in manifest.get("commands", []):
            if item.get("migration") in {"implemented", "delegated"}:
                required_rust.add(item.get("label"))
    else:
        required_rust = required
    missing = sorted(command for command in required_rust if not owners.get(command))
    fallback = sorted(
        item.get("label")
        for item in (manifest or {}).get("commands", [])
        if item.get("migration") == "fallback"
    ) if isinstance(manifest, dict) else []
    return {
        "swift_dispatch_labels": sorted(swift),
        "swift_early_commands": sorted(early),
        "required_labels": sorted(required),
        "rust_modules": {name: sorted(labels) for name, labels in modules.items()},
        "owners": owners,
        "missing": missing,
        "manifest_error": manifest_error,
        "manifest_fallback": fallback,
    }


def _clean_environment() -> dict[str, str]:
    env = os.environ.copy()
    for key in (
        "CMUX_SOCKET_PATH",
        "CMUX_SOCKET",
        "CMUX_SOCKET_PASSWORD",
        "CMUX_WORKSPACE_ID",
        "CMUX_SURFACE_ID",
        "CMUX_TAB_ID",
        "CMUX_PANEL_ID",
        "CMUXD_SOCKET",
    ):
        env.pop(key, None)
    return env


def run_cli(binary: Path, args: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [str(binary), *args],
        cwd=ROOT,
        env=_clean_environment(),
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        timeout=10,
        check=False,
    )


def _assert_no_socket(result: subprocess.CompletedProcess[str], args: list[str]) -> None:
    if result.returncode != 0:
        raise AssertionError(
            f"{' '.join(args)} unexpectedly failed ({result.returncode})\n"
            f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}"
        )
    combined = f"{result.stdout}\n{result.stderr}".lower()
    if "socket" in combined and ("connect" in combined or "unavailable" in combined):
        raise AssertionError(f"{' '.join(args)} attempted socket access:\n{combined}")


def black_box_report(binary: Path) -> dict[str, object]:
    if not binary.is_file() or not os.access(binary, os.X_OK):
        raise FileNotFoundError(f"Rust CLI executable is not executable: {binary}")

    checks: list[dict[str, object]] = []
    for args in (["--help"], ["-h"], ["help"], ["--socket", "/definitely-missing.sock", "help"]):
        result = run_cli(binary, list(args))
        _assert_no_socket(result, list(args))
        if "usage" not in result.stdout.lower():
            raise AssertionError(f"{' '.join(args)} did not print usage:\n{result.stdout}")
        checks.append({"args": list(args), "exit": result.returncode})

    versions: list[str] = []
    for args in (["--version"], ["-v"], ["version"]):
        result = run_cli(binary, list(args))
        _assert_no_socket(result, list(args))
        value = result.stdout.strip()
        if not value:
            raise AssertionError(f"{' '.join(args)} printed an empty version")
        versions.append(value)
        checks.append({"args": list(args), "exit": result.returncode})
    if len(set(versions)) != 1:
        raise AssertionError(f"version aliases disagree: {versions!r}")

    # Capabilities is intentionally a local discovery command. It must be
    # usable by an agent before a cmux app is running.
    result = run_cli(binary, ["capabilities", "--local"])
    _assert_no_socket(result, ["capabilities", "--local"])
    try:
        capabilities = json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        raise AssertionError(f"capabilities did not return JSON:\n{result.stdout}") from exc
    if not isinstance(capabilities, dict):
        raise AssertionError("capabilities response must be a JSON object")
    if not any(key in capabilities for key in ("commands", "capabilities", "data")):
        raise AssertionError("capabilities response has no command catalog")
    checks.append({"args": ["capabilities", "--local"], "exit": result.returncode})

    for args in (
        ["--json", "help"],
        ["--output", "json", "help"],
        ["--non-interactive", "help"],
        ["--dry-run", "help"],
        ["--explain", "help"],
        ["--id-format", "both", "help"],
    ):
        result = run_cli(binary, list(args))
        _assert_no_socket(result, list(args))
        checks.append({"args": list(args), "exit": result.returncode})
    return {"checks": checks, "version": versions[0], "capabilities_keys": sorted(capabilities)}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, help="built Rust cmux executable")
    parser.add_argument("--source-only", action="store_true", help="skip executable probes")
    parser.add_argument("--allow-missing", action="store_true", help="report missing owners without failing")
    parser.add_argument("--json", action="store_true", help="emit one machine-readable report")
    options = parser.parse_args(argv)

    report: dict[str, object] = {"source": source_report()}
    missing = report["source"]["missing"]  # type: ignore[index]
    manifest_error = report["source"].get("manifest_error")  # type: ignore[union-attr]
    fallback = report["source"].get("manifest_fallback", [])  # type: ignore[union-attr]
    if (missing or manifest_error or fallback) and not options.allow_missing:
        if options.json:
            print(json.dumps(report, indent=2, sort_keys=True))
        else:
            if manifest_error:
                print(f"Rust CLI parity: {manifest_error}", file=sys.stderr)
            if missing:
                print("Rust CLI parity: missing owners for: " + ", ".join(missing), file=sys.stderr)
            if fallback:
                print("Rust CLI parity: Swift fallback remains for: " + ", ".join(fallback), file=sys.stderr)
        return 1

    if not options.source_only:
        binary = options.binary or (
            Path(os.environ["CMUX_RUST_CLI_BIN"])
            if os.environ.get("CMUX_RUST_CLI_BIN")
            else ROOT / "Native" / "CmuxCLI" / "target" / "release" / "cmux"
        )
        try:
            report["black_box"] = black_box_report(binary)
        except (AssertionError, FileNotFoundError, subprocess.SubprocessError) as exc:
            if options.json:
                report["black_box_error"] = str(exc)
            else:
                print(f"Rust CLI black-box parity failed: {exc}", file=sys.stderr)
            return 1

    if options.json:
        print(json.dumps(report, indent=2, sort_keys=True))
    else:
        source = report["source"]
        print(f"Swift dispatcher labels: {len(source['swift_dispatch_labels'])}")
        print(f"Rust modules: {len(source['rust_modules'])}")
        print(f"Missing owners: {len(source['missing'])}")
        print(f"Swift fallbacks: {len(source['manifest_fallback'])}")
        if report.get("black_box"):
            print(f"No-socket probes: {len(report['black_box']['checks'])}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
