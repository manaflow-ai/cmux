#!/usr/bin/env python3
"""
Executable contract check for no-socket cmux CLI help behavior.

The command list lives in docs/cli-contract.md so the human migration spec and
CI check stay tied together. This test invokes the built CLI binary; it does not
inspect Swift source.
"""

from __future__ import annotations

import glob
import os
import re
import shlex
import subprocess
import tempfile
import uuid
from dataclasses import dataclass
from pathlib import Path


START_MARKER = "<!-- cli-contract-help-probes:start -->"
END_MARKER = "<!-- cli-contract-help-probes:end -->"
NEGATIVE_START_MARKER = "<!-- cli-contract-negative-help-probes:start -->"
NEGATIVE_END_MARKER = "<!-- cli-contract-negative-help-probes:end -->"
PROBE_RE = re.compile(r"^- `(?P<command>cmux(?: [^`]+)?)` -> `(?P<needle>[^`]+)`$")
NEGATIVE_PROBE_RE = re.compile(r"^- `(?P<command>cmux(?: [^`]+)?)` !> `(?P<needle>[^`]+)`$")


@dataclass(frozen=True)
class HelpProbe:
    command: str
    needle: str


@dataclass(frozen=True)
class ProbeResult:
    returncode: int
    stdout: str
    stderr: str
    socket_path: str


def repo_root() -> Path:
    return Path(__file__).resolve().parent.parent


def resolve_cmux_cli() -> str:
    explicit = os.environ.get("CMUX_CLI_BIN") or os.environ.get("CMUX_CLI")
    if explicit and os.path.exists(explicit) and os.access(explicit, os.X_OK):
        return explicit

    candidates: list[str] = []
    candidates.extend(glob.glob(os.path.expanduser("~/Library/Developer/Xcode/DerivedData/*/Build/Products/Debug/cmux")))
    candidates = [path for path in candidates if os.path.exists(path) and os.access(path, os.X_OK)]
    if candidates:
        candidates.sort(key=os.path.getmtime, reverse=True)
        return candidates[0]

    raise RuntimeError("Unable to find cmux CLI binary. Set CMUX_CLI_BIN.")


def load_help_probes() -> list[HelpProbe]:
    probes = load_probes(START_MARKER, END_MARKER, PROBE_RE)
    if not probes:
        raise RuntimeError("No CLI help probes found in docs/cli-contract.md")
    return probes


def load_negative_help_probes() -> list[HelpProbe]:
    probes = load_probes(NEGATIVE_START_MARKER, NEGATIVE_END_MARKER, NEGATIVE_PROBE_RE)
    if not probes:
        raise RuntimeError("No negative CLI help probes found in docs/cli-contract.md")
    return probes


def load_probes(start_marker: str, end_marker: str, pattern: re.Pattern[str]) -> list[HelpProbe]:
    contract_path = repo_root() / "docs" / "cli-contract.md"
    lines = contract_path.read_text(encoding="utf-8").splitlines()

    in_block = False
    probes: list[HelpProbe] = []
    for line in lines:
        if line.strip() == start_marker:
            in_block = True
            continue
        if line.strip() == end_marker:
            in_block = False
            break
        if not in_block:
            continue

        stripped = line.strip()
        if not stripped:
            continue
        match = pattern.match(stripped)
        if match is None:
            raise RuntimeError(f"Malformed probe line: {line}")
        probes.append(HelpProbe(command=match.group("command"), needle=match.group("needle")))

    if in_block:
        raise RuntimeError(f"Missing end marker: {end_marker}")
    return probes


def run_probe(cli_path: str, probe: HelpProbe) -> ProbeResult:
    tokens = shlex.split(probe.command)
    if not tokens or tokens[0] != "cmux":
        raise RuntimeError(f"Probe must start with cmux: {probe.command}")

    env = dict(os.environ)
    for key in [
        "CMUX_SOCKET_PASSWORD",
        "CMUX_WORKSPACE_ID",
        "CMUX_SURFACE_ID",
        "CMUX_TAB_ID",
    ]:
        env.pop(key, None)
    env["CMUX_CLI_SENTRY_DISABLED"] = "1"
    env["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"

    with tempfile.TemporaryDirectory(prefix="cmux-no-socket-") as tmpdir:
        no_socket = os.path.join(tmpdir, f"socket-{uuid.uuid4().hex}.sock")
        env["CMUX_SOCKET_PATH"] = no_socket
        env["CMUX_SOCKET"] = no_socket

        proc = subprocess.run(  # noqa: S603
            [cli_path, *tokens[1:]],
            text=True,
            capture_output=True,
            check=False,
            timeout=5.0,
            env=env,
        )

    return ProbeResult(
        returncode=proc.returncode,
        stdout=proc.stdout.strip(),
        stderr=proc.stderr.strip(),
        socket_path=no_socket,
    )


def main() -> int:
    try:
        cli_path = resolve_cmux_cli()
        probes = load_help_probes()
        negative_probes = load_negative_help_probes()
    except (RuntimeError, OSError, ValueError) as exc:
        print(f"FAIL: {exc}")
        return 1

    failures: list[str] = []
    for probe in probes:
        try:
            result = run_probe(cli_path, probe)
        except subprocess.TimeoutExpired:
            failures.append(f"{probe.command}: timed out")
            continue
        except (RuntimeError, OSError, ValueError) as exc:
            failures.append(f"{probe.command}: {exc}")
            continue

        merged = f"{result.stdout}\n{result.stderr}".strip()
        if result.returncode != 0:
            failures.append(
                f"{probe.command}: expected exit 0, got {result.returncode}\n"
                f"stdout={result.stdout!r}\nstderr={result.stderr!r}"
            )
            continue
        if result.socket_path in merged:
            failures.append(
                f"{probe.command}: unexpected socket usage with forced socket {result.socket_path!r}\n"
                f"stdout={result.stdout!r}\nstderr={result.stderr!r}"
            )
            continue
        if probe.needle not in merged:
            failures.append(
                f"{probe.command}: missing expected text {probe.needle!r}\n"
                f"stdout={result.stdout!r}\nstderr={result.stderr!r}"
            )

    for probe in negative_probes:
        try:
            result = run_probe(cli_path, probe)
        except subprocess.TimeoutExpired:
            failures.append(f"{probe.command}: timed out")
            continue
        except (RuntimeError, OSError, ValueError) as exc:
            failures.append(f"{probe.command}: {exc}")
            continue

        merged = f"{result.stdout}\n{result.stderr}".strip()
        if probe.needle in merged:
            failures.append(
                f"{probe.command}: unexpected help text {probe.needle!r}\n"
                f"stdout={result.stdout!r}\nstderr={result.stderr!r}"
            )
        if result.returncode == 0:
            failures.append(
                f"{probe.command}: expected nonzero exit after forwarding --help, got 0\n"
                f"stdout={result.stdout!r}\nstderr={result.stderr!r}"
            )
        if result.socket_path not in merged:
            failures.append(
                f"{probe.command}: expected forwarded command to reach forced socket {result.socket_path!r}\n"
                f"stdout={result.stdout!r}\nstderr={result.stderr!r}"
            )

    if failures:
        print("FAIL: CLI help contract probes failed")
        for failure in failures:
            print("")
            print(failure)
        return 1

    print(f"PASS: {len(probes)} CLI help contract probes and {len(negative_probes)} negative probes passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
