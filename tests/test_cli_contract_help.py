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
import shutil
import subprocess
from dataclasses import dataclass
from pathlib import Path


START_MARKER = "<!-- cli-contract-help-probes:start -->"
END_MARKER = "<!-- cli-contract-help-probes:end -->"
PROBE_RE = re.compile(r"^- `(?P<command>cmux(?: [^`]+)?)` -> `(?P<needle>[^`]+)`$")


@dataclass(frozen=True)
class HelpProbe:
    command: str
    needle: str


def repo_root() -> Path:
    return Path(__file__).resolve().parent.parent


def resolve_cmux_cli() -> str:
    explicit = os.environ.get("CMUX_CLI_BIN") or os.environ.get("CMUX_CLI")
    if explicit and os.path.exists(explicit) and os.access(explicit, os.X_OK):
        return explicit

    candidates: list[str] = []
    candidates.extend(glob.glob(os.path.expanduser("~/Library/Developer/Xcode/DerivedData/*/Build/Products/Debug/cmux")))
    candidates.extend(glob.glob("/tmp/cmux-*/Build/Products/Debug/cmux"))
    candidates = [path for path in candidates if os.path.exists(path) and os.access(path, os.X_OK)]
    if candidates:
        candidates.sort(key=os.path.getmtime, reverse=True)
        return candidates[0]

    in_path = shutil.which("cmux")
    if in_path:
        return in_path

    raise RuntimeError("Unable to find cmux CLI binary. Set CMUX_CLI_BIN.")


def load_help_probes() -> list[HelpProbe]:
    contract_path = repo_root() / "docs" / "cli-contract.md"
    lines = contract_path.read_text(encoding="utf-8").splitlines()

    in_block = False
    probes: list[HelpProbe] = []
    for line in lines:
        if line.strip() == START_MARKER:
            in_block = True
            continue
        if line.strip() == END_MARKER:
            in_block = False
            break
        if not in_block:
            continue

        stripped = line.strip()
        if not stripped:
            continue
        match = PROBE_RE.match(stripped)
        if match is None:
            raise RuntimeError(f"Malformed help probe line: {line}")
        probes.append(HelpProbe(command=match.group("command"), needle=match.group("needle")))

    if in_block:
        raise RuntimeError(f"Missing end marker: {END_MARKER}")
    if not probes:
        raise RuntimeError("No CLI help probes found in docs/cli-contract.md")
    return probes


def run_probe(cli_path: str, probe: HelpProbe) -> tuple[int, str, str]:
    tokens = shlex.split(probe.command)
    if not tokens or tokens[0] != "cmux":
        raise RuntimeError(f"Probe must start with cmux: {probe.command}")

    env = dict(os.environ)
    for key in [
        "CMUX_SOCKET_PATH",
        "CMUX_SOCKET",
        "CMUX_WORKSPACE_ID",
        "CMUX_SURFACE_ID",
        "CMUX_TAB_ID",
    ]:
        env.pop(key, None)
    env["CMUX_CLI_SENTRY_DISABLED"] = "1"
    env["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"

    proc = subprocess.run(
        [cli_path, *tokens[1:]],
        text=True,
        capture_output=True,
        check=False,
        timeout=5.0,
        env=env,
    )
    return proc.returncode, proc.stdout.strip(), proc.stderr.strip()


def main() -> int:
    try:
        cli_path = resolve_cmux_cli()
        probes = load_help_probes()
    except Exception as exc:
        print(f"FAIL: {exc}")
        return 1

    failures: list[str] = []
    for probe in probes:
        try:
            code, stdout, stderr = run_probe(cli_path, probe)
        except subprocess.TimeoutExpired:
            failures.append(f"{probe.command}: timed out")
            continue
        except Exception as exc:
            failures.append(f"{probe.command}: {exc}")
            continue

        merged = f"{stdout}\n{stderr}".strip()
        if code != 0:
            failures.append(
                f"{probe.command}: expected exit 0, got {code}\nstdout={stdout!r}\nstderr={stderr!r}"
            )
            continue
        if probe.needle not in merged:
            failures.append(
                f"{probe.command}: missing expected text {probe.needle!r}\nstdout={stdout!r}\nstderr={stderr!r}"
            )

    if failures:
        print("FAIL: CLI help contract probes failed")
        for failure in failures:
            print("")
            print(failure)
        return 1

    print(f"PASS: {len(probes)} CLI help contract probes passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
