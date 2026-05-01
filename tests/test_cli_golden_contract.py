#!/usr/bin/env python3
"""
Golden-master compatibility check for the cmux CLI.

This compares a baseline CLI binary against a candidate CLI binary. It is meant
to guard parser migrations: command inventory, help/error behavior, root option
handling, and selected socket payloads should stay identical unless a PR
intentionally updates the CLI contract.
"""

from __future__ import annotations

import dataclasses
import difflib
import json
import os
import re
import shlex
import socket
import subprocess
import tempfile
import threading
from pathlib import Path
from typing import Iterable


START_MARKER = "<!-- cli-contract-help-probes:start -->"
END_MARKER = "<!-- cli-contract-help-probes:end -->"
NEGATIVE_START_MARKER = "<!-- cli-contract-negative-help-probes:start -->"
NEGATIVE_END_MARKER = "<!-- cli-contract-negative-help-probes:end -->"
PROBE_RE = re.compile(r"^- `(?P<command>cmux(?: [^`]+)?)` -> `(?P<needle>[^`]+)`$")
NEGATIVE_PROBE_RE = re.compile(r"^- `(?P<command>cmux(?: [^`]+)?)` !> `(?P<needle>[^`]+)`$")


@dataclasses.dataclass(frozen=True)
class Probe:
    name: str
    command: str
    stdin: str = ""
    fake_socket: bool = False


@dataclasses.dataclass(frozen=True)
class Result:
    returncode: int
    stdout: str
    stderr: str
    socket_payloads: tuple[str, ...] = ()
    timeout: bool = False

    def comparable(self) -> str:
        payloads = "\n".join(self.socket_payloads)
        return (
            f"timeout={self.timeout}\n"
            f"returncode={self.returncode}\n"
            f"stdout:\n{self.stdout}\n"
            f"stderr:\n{self.stderr}\n"
            f"socket_payloads:\n{payloads}\n"
        )


EXPECTED_FAKE_SOCKET_RESULTS = {
    "cmux --socket {socket} ping": Result(0, "PONG\n", "", ("ping",)),
    "cmux --socket {socket} --json ping": Result(0, "PONG\n", "", ("ping",)),
}

INTENTIONAL_CANDIDATE_STDOUT_NORMALIZATIONS = {
    "cmux feed": (
        ("cmux feed clear [--yes|-y]", "cmux feed clear [--yes]"),
    ),
    "cmux feed help": (
        ("cmux feed clear [--yes|-y]", "cmux feed clear [--yes]"),
    ),
}


class CaptureSocketServer:
    def __init__(self, path: str):
        self.path = path
        self.ready = threading.Event()
        self.payloads: list[str] = []
        self.error: Exception | None = None
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._run, daemon=True)

    def start(self) -> None:
        self._thread.start()

    def wait_ready(self, timeout: float) -> bool:
        return self.ready.wait(timeout)

    def stop(self) -> None:
        self._stop.set()
        try:
            client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            client.settimeout(0.1)
            client.connect(self.path)
            client.close()
        except OSError:
            pass
        self._thread.join(timeout=1.0)
        try:
            os.remove(self.path)
        except OSError:
            pass

    def _run(self) -> None:
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            if os.path.exists(self.path):
                os.remove(self.path)
            server.bind(self.path)
            server.listen(16)
            server.settimeout(0.2)
            self.ready.set()

            while not self._stop.is_set():
                try:
                    conn, _ = server.accept()
                except socket.timeout:
                    continue
                with conn:
                    conn.settimeout(0.5)
                    data = b""
                    while b"\n" not in data:
                        try:
                            chunk = conn.recv(4096)
                        except socket.timeout:
                            break
                        if not chunk:
                            break
                        data += chunk
                    if not data:
                        continue

                    line = data.decode("utf-8", errors="replace").strip()
                    self.payloads.append(line)
                    if line == "ping":
                        conn.sendall(b"PONG\n")
                    elif line == "capabilities":
                        conn.sendall(b"{}\n")
                    else:
                        conn.sendall(b"OK\n")
        except Exception as exc:  # pragma: no cover - surfaced in comparison output
            self.error = exc
            self.ready.set()
        finally:
            server.close()


def repo_root() -> Path:
    return Path(__file__).resolve().parent.parent


def resolve_cli(env_name: str) -> str:
    value = os.environ.get(env_name)
    if not value:
        raise RuntimeError(f"{env_name} is required")
    if not os.path.exists(value) or not os.access(value, os.X_OK):
        raise RuntimeError(f"{env_name} is not executable: {value}")
    return value


def load_marked_commands(start_marker: str, end_marker: str, pattern: re.Pattern[str]) -> list[str]:
    lines = (repo_root() / "docs" / "cli-contract.md").read_text(encoding="utf-8").splitlines()
    in_block = False
    found_start = False
    commands: list[str] = []
    for line in lines:
        if line.strip() == start_marker:
            in_block = True
            found_start = True
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
            raise RuntimeError(f"Malformed CLI contract probe line: {line}")
        commands.append(match.group("command"))

    if in_block:
        raise RuntimeError(f"Missing end marker: {end_marker}")
    if not found_start:
        raise RuntimeError(f"Missing start marker: {start_marker}")
    return commands


def table_region() -> str:
    text = (repo_root() / "docs" / "cli-contract.md").read_text(encoding="utf-8")
    start = text.index("## Top-Level Commands")
    end = text.index("## No-Socket Help Probes")
    return text[start:end]


def documented_command_forms() -> list[str]:
    forms: set[str] = set()
    for line in table_region().splitlines():
        stripped = line.strip()
        if not stripped.startswith("|") or stripped.startswith("| ---"):
            continue
        cells = split_markdown_table_row(stripped)
        if not cells or cells[0] == "Command":
            continue
        for code in re.findall(r"`([^`]+)`", cells[0]):
            code = code.replace("\\|", "|")
            forms.update(expand_command_form(code))
    return sorted(forms)


def documented_top_level_commands(forms: Iterable[str]) -> set[str]:
    return {form.split()[0] for form in forms if form.split()}


def baseline_help_top_level_commands(cli_path: str) -> set[str]:
    with tempfile.TemporaryDirectory(prefix="cmux-cli-help-") as temp_root:
        env = isolated_env(temp_root)
        proc = subprocess.run(  # noqa: S603
            [cli_path, "--help"],
            text=True,
            capture_output=True,
            check=False,
            timeout=10.0,
            env=env,
        )
    if proc.returncode not in (0, 1):
        raise RuntimeError(f"Baseline help failed with exit {proc.returncode}: {proc.stderr}")
    return parse_help_top_level_commands(proc.stdout)


def candidate_inventory_top_level_commands(cli_path: str) -> set[str]:
    with tempfile.TemporaryDirectory(prefix="cmux-cli-inventory-") as temp_root:
        env = isolated_env(temp_root)
        proc = subprocess.run(  # noqa: S603
            [cli_path, "__argument-parser-inventory", "--verify", "--json"],
            text=True,
            capture_output=True,
            check=False,
            timeout=15.0,
            env=env,
        )
    if proc.returncode != 0:
        raise RuntimeError(f"Candidate inventory failed with exit {proc.returncode}: {proc.stderr}")
    payload = json.loads(proc.stdout)
    top_level = payload.get("top_level")
    if not isinstance(top_level, list):
        raise RuntimeError("Candidate inventory missing top_level list")
    return {str(command) for command in top_level}


def parse_help_top_level_commands(help_text: str) -> set[str]:
    commands: set[str] = set()
    in_commands = False
    for line in help_text.splitlines():
        stripped = line.strip()
        if stripped == "Commands:":
            in_commands = True
            continue
        if not in_commands:
            continue
        if not stripped:
            continue
        if not line.startswith("          "):
            break
        commands.update(extract_top_level_commands_from_help_line(stripped))
    return commands


def extract_top_level_commands_from_help_line(line: str) -> set[str]:
    commands: set[str] = set()
    command_part = re.split(r"\s{2,}", line, maxsplit=1)[0]
    for alternative in command_part.split(" | "):
        token = alternative.strip().split(maxsplit=1)[0] if alternative.strip() else ""
        if token:
            commands.add(token)

    alias_match = re.search(r"\(alias:\s*([^)]+)\)", line)
    if alias_match:
        for alias in re.split(r"[,|/]\s*", alias_match.group(1)):
            alias = alias.strip()
            if alias:
                commands.add(alias)
    return commands


def split_markdown_table_row(row: str) -> list[str]:
    cells: list[str] = []
    current: list[str] = []
    in_code = False
    escaped = False
    for char in row.strip():
        if escaped:
            current.append(char)
            escaped = False
            continue
        if char == "\\":
            current.append(char)
            escaped = True
            continue
        if char == "`":
            in_code = not in_code
            current.append(char)
            continue
        if char == "|" and not in_code:
            cells.append("".join(current).strip())
            current = []
            continue
        current.append(char)
    cells.append("".join(current).strip())
    if cells and cells[0] == "":
        cells = cells[1:]
    if cells and cells[-1] == "":
        cells = cells[:-1]
    return cells


def expand_command_form(raw: str) -> list[str]:
    if "<agent>" in raw or raw.startswith("--") or raw.startswith("CMUX_"):
        return []
    raw = raw.removeprefix("cmux ").strip()
    if not raw or raw.startswith("<"):
        return []

    tokens = raw.split()
    literal_tokens: list[list[str]] = []
    for token in tokens:
        if token.startswith("<") or token.startswith("["):
            inner = token.strip("<>[]")
            previous = literal_tokens[-1][0] if literal_tokens else ""
            if "|" in inner and not previous.startswith("--"):
                literal_tokens.append([part for part in inner.split("|") if part])
                continue
            break
        if token.startswith("("):
            break
        if token == "...":
            break
        alternatives = [part for part in token.split("|") if part]
        literal_tokens.append(alternatives)

    if not literal_tokens:
        return []

    forms = [""]
    for alternatives in literal_tokens:
        forms = [
            f"{prefix} {alternative}".strip()
            for prefix in forms
            for alternative in alternatives
        ]
    return forms


def build_probes() -> list[Probe]:
    probes: list[Probe] = [
        Probe("top-level help", "cmux --help"),
        Probe("top-level short help", "cmux -h"),
        Probe("top-level version", "cmux --version"),
        Probe("top-level short version", "cmux -v"),
        Probe("missing command", "cmux"),
        Probe("legacy help command", "cmux help"),
        Probe("legacy help command help", "cmux help --help"),
        Probe("version command", "cmux version"),
        Probe("version command help", "cmux version --help"),
        Probe("root help before version preserves input order", "cmux --help --version"),
        Probe("root version before help preserves input order", "cmux --version --help"),
        Probe("root short version before dangling socket", "cmux -v --socket"),
        Probe("feed default help", "cmux feed"),
        Probe("feed help subcommand", "cmux feed help"),
        Probe("feed tui help", "cmux feed tui --help"),
        Probe("feed tui conflicting implementation flags", "cmux feed tui --opentui --legacy"),
        Probe("feed tui unknown flag", "cmux feed tui --unknown"),
        Probe("feed clear no history", "cmux feed clear --yes"),
        Probe("feed clear passthrough yes no history", "cmux feed clear -- --yes"),
        Probe("feed clear ignores extra args", "cmux feed clear ignored --yes"),
        Probe("feed option before subcommand stays invalid", "cmux feed --yes clear"),
        Probe("themes set multi-token", "cmux themes set Compat Theme"),
        Probe("themes shorthand multi-token", "cmux themes Compat Theme"),
        Probe("themes set split light dark", "cmux themes set --light Light Compat --dark Dark Compat"),
        Probe("themes json set split light dark", "cmux --json themes set --light Light Compat --dark Dark Compat"),
        Probe("themes repeated option last wins", "cmux themes set --light First Compat --light Second Compat"),
        Probe("themes list extra invalid", "cmux themes list extra"),
        Probe("themes clear extra invalid", "cmux themes clear extra"),
        Probe("themes unknown flag invalid", "cmux themes --bogus"),
        Probe("themes set unknown flag invalid", "cmux themes set --bogus"),
        Probe("root json before help", "cmux --json ping --help"),
        Probe("root id format before help", "cmux --id-format both list-windows --help"),
        Probe("root window before help", "cmux --window window:1 list-workspaces --help"),
        Probe("root password before help", "cmux --password test-password ping --help"),
        Probe("root socket before help", "cmux --socket /tmp/cmux-golden-missing.sock ping --help"),
        Probe("root socket dash value", "cmux --socket --json ping --help"),
        Probe("root socket missing value", "cmux --socket"),
        Probe("root id format missing value", "cmux --id-format"),
        Probe("root window missing value", "cmux --window"),
        Probe("root password missing value", "cmux --password"),
        Probe("double dash forwarding", "cmux vm exec demo -- --help"),
        Probe("fake socket ping", "cmux --socket {socket} ping", fake_socket=True),
        Probe("fake socket json ping", "cmux --socket {socket} --json ping", fake_socket=True),
    ]

    for command in load_marked_commands(START_MARKER, END_MARKER, PROBE_RE):
        probes.append(Probe(f"marked help: {command}", command))
    for command in load_marked_commands(NEGATIVE_START_MARKER, NEGATIVE_END_MARKER, NEGATIVE_PROBE_RE):
        probes.append(Probe(f"marked negative: {command}", command))
    for form in documented_command_forms():
        probes.append(Probe(f"documented command help: {form}", f"cmux {form} --help"))

    return dedupe_probes(probes)


def dedupe_probes(probes: Iterable[Probe]) -> list[Probe]:
    seen: set[tuple[str, str, bool]] = set()
    result: list[Probe] = []
    for probe in probes:
        key = (probe.command, probe.stdin, probe.fake_socket)
        if key in seen:
            continue
        seen.add(key)
        result.append(probe)
    return result


def isolated_env(temp_root: str) -> dict[str, str]:
    env = os.environ.copy()
    for key in [
        "CMUX_SOCKET_PASSWORD",
        "CMUX_WORKSPACE_ID",
        "CMUX_SURFACE_ID",
        "CMUX_TAB_ID",
        "CMUX_COMMIT",
    ]:
        env.pop(key, None)
    env["CMUX_CLI_SENTRY_DISABLED"] = "1"
    env["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"
    env["NO_COLOR"] = "1"

    home = os.path.join(temp_root, "home")
    os.makedirs(home, exist_ok=True)
    env["HOME"] = home
    env["CFFIXED_USER_HOME"] = home

    missing_socket = os.path.join(temp_root, "missing.sock")
    env["CMUX_SOCKET_PATH"] = missing_socket
    env["CMUX_SOCKET"] = missing_socket
    return env


def run_probe(cli_path: str, probe: Probe, temp_root: str) -> Result:
    env = isolated_env(temp_root)

    command = probe.command
    server: CaptureSocketServer | None = None
    if probe.fake_socket:
        socket_path = os.path.join(temp_root, "capture.sock")
        server = CaptureSocketServer(socket_path)
        server.start()
        if not server.wait_ready(2.0):
            return Result(1, "", "capture socket server did not become ready")
        command = command.replace("{socket}", socket_path)
        env.pop("CMUX_SOCKET_PATH", None)
        env.pop("CMUX_SOCKET", None)

    tokens = shlex.split(command)
    if not tokens or tokens[0] != "cmux":
        raise RuntimeError(f"Probe command must start with cmux: {command}")

    try:
        proc = subprocess.run(  # noqa: S603
            [cli_path, *tokens[1:]],
            input=probe.stdin,
            text=True,
            capture_output=True,
            check=False,
            timeout=6.0,
            env=env,
        )
        payloads = tuple(server.payloads if server is not None else [])
        if server is not None and server.error is not None:
            return Result(
                proc.returncode,
                normalize(proc.stdout, temp_root, cli_path),
                normalize(proc.stderr, temp_root, cli_path),
                payloads + (f"SERVER_ERROR: {server.error}",),
            )
        return Result(
            proc.returncode,
            normalize(proc.stdout, temp_root, cli_path),
            normalize(proc.stderr, temp_root, cli_path),
            payloads,
        )
    except subprocess.TimeoutExpired as exc:
        stdout = normalize(exc.stdout or "", temp_root, cli_path)
        stderr = normalize(exc.stderr or "", temp_root, cli_path)
        payloads = tuple(server.payloads if server is not None else [])
        return Result(124, stdout, stderr, payloads, timeout=True)
    finally:
        if server is not None:
            server.stop()


def normalize(value: str | bytes, temp_root: str, cli_path: str) -> str:
    if isinstance(value, bytes):
        value = value.decode("utf-8", errors="replace")
    replacements = [
        (temp_root, "<TMP>"),
        (os.path.realpath(temp_root), "<TMP>"),
        (cli_path, "<CLI>"),
        (os.path.realpath(cli_path), "<CLI>"),
        ("/private/tmp", "/tmp"),
    ]
    normalized = value.replace("\r\n", "\n")
    for old, new in sorted(replacements, key=lambda item: len(item[0]), reverse=True):
        normalized = normalized.replace(old, new)
    normalized = normalize_build_metadata(normalized)
    return normalized


def normalize_build_metadata(value: str) -> str:
    normalized = re.sub(
        r"^cmux (?:version unknown|(?:\d+\.\d+\.\d+|dev|unknown)(?: \([^)]+\))?(?: \[[^\]]+\])?)$",
        "cmux <VERSION>",
        value,
        flags=re.MULTILINE,
    )
    normalized = re.sub(
        r"^app version: .*$",
        "app version: <VERSION>",
        normalized,
        flags=re.MULTILINE,
    )
    normalized = re.sub(r"^build: .*\n?", "", normalized, flags=re.MULTILINE)
    normalized = re.sub(r"^commit: .*\n?", "", normalized, flags=re.MULTILINE)
    normalized = re.sub(
        r"/remote-daemons/[^/\n]+/",
        "/remote-daemons/<VERSION>/",
        normalized,
    )
    return normalized


def compare_probe(baseline_cli: str, candidate_cli: str, probe: Probe) -> str | None:
    with tempfile.TemporaryDirectory(prefix="cmux-cli-golden-") as temp_root:
        baseline = run_probe(baseline_cli, probe, os.path.join(temp_root, "baseline"))
        candidate = run_probe(candidate_cli, probe, os.path.join(temp_root, "candidate"))

    expected = EXPECTED_FAKE_SOCKET_RESULTS.get(probe.command) if probe.fake_socket else None
    if expected is not None:
        if candidate == expected:
            return None
        diff = "\n".join(
            difflib.unified_diff(
                expected.comparable().splitlines(),
                candidate.comparable().splitlines(),
                fromfile="expected",
                tofile="candidate",
                lineterm="",
            )
        )
        return f"{probe.name}\ncommand: {probe.command}\n{diff}"

    if baseline == candidate:
        return None

    normalized_candidate = normalize_intentional_candidate_delta(probe, candidate)
    if baseline == normalized_candidate:
        return None

    diff = "\n".join(
        difflib.unified_diff(
            baseline.comparable().splitlines(),
            candidate.comparable().splitlines(),
            fromfile="baseline",
            tofile="candidate",
            lineterm="",
        )
    )
    return f"{probe.name}\ncommand: {probe.command}\n{diff}"


def normalize_intentional_candidate_delta(probe: Probe, result: Result) -> Result:
    replacements = INTENTIONAL_CANDIDATE_STDOUT_NORMALIZATIONS.get(probe.command)
    if replacements is None:
        return result

    stdout = result.stdout
    for candidate_text, baseline_text in replacements:
        stdout = stdout.replace(candidate_text, baseline_text)
    return dataclasses.replace(result, stdout=stdout)


def compare_baseline_top_level_commands(
    baseline_cli: str,
    candidate_cli: str,
    documented_forms: Iterable[str],
) -> list[str]:
    baseline_top_level = baseline_help_top_level_commands(baseline_cli)
    candidate_top_level = candidate_inventory_top_level_commands(candidate_cli)
    documented_top_level = documented_top_level_commands(documented_forms)

    failures: list[str] = []
    missing_from_candidate = sorted(baseline_top_level - candidate_top_level)
    if missing_from_candidate:
        failures.append(
            "baseline top-level commands missing from candidate inventory: "
            + ", ".join(missing_from_candidate)
        )

    missing_from_docs = sorted(baseline_top_level - documented_top_level)
    if missing_from_docs:
        failures.append(
            "baseline top-level commands missing from docs contract: "
            + ", ".join(missing_from_docs)
        )
    return failures


def main() -> int:
    try:
        baseline_cli = resolve_cli("CMUX_BASELINE_CLI")
        candidate_cli = resolve_cli("CMUX_CANDIDATE_CLI")
        documented_forms = documented_command_forms()
        probes = build_probes()
    except (RuntimeError, OSError, ValueError) as exc:
        print(f"FAIL: {exc}")
        return 1

    failures = compare_baseline_top_level_commands(baseline_cli, candidate_cli, documented_forms)
    for probe in probes:
        failure = compare_probe(baseline_cli, candidate_cli, probe)
        if failure is not None:
            failures.append(failure)

    if failures:
        print("FAIL: CLI golden contract changed")
        print(f"probes={len(probes)} failures={len(failures)}")
        for failure in failures:
            print("")
            print(failure)
        return 1

    print(f"PASS: CLI golden contract matched baseline for {len(probes)} probes")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
