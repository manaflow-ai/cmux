#!/usr/bin/env python3
"""
Executable contract check for no-socket cmux CLI help behavior.

The command list lives in docs/cli-contract.md so the human migration spec and
CI check stay tied together. This test invokes the built CLI binary; it does not
inspect Swift source.
"""

from __future__ import annotations

import glob
import json
import os
import re
import shlex
import subprocess
import tempfile
import uuid
from dataclasses import dataclass
from pathlib import Path

from test_review_runner import check_review_runner_contract


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

    return run_cli_args(cli_path, tokens[1:])


GIT_LOCATION_ENV_KEYS = {
    "GIT_ALTERNATE_OBJECT_DIRECTORIES",
    "GIT_CEILING_DIRECTORIES",
    "GIT_COMMON_DIR",
    "GIT_DIR",
    "GIT_INDEX_FILE",
    "GIT_NAMESPACE",
    "GIT_OBJECT_DIRECTORY",
    "GIT_WORK_TREE",
    "GIT_REFERENCE_BACKEND",
    "GIT_CONFIG",
    "GIT_CONFIG_PARAMETERS",
    "GIT_CONFIG_COUNT",
}


def clean_git_env() -> dict[str, str]:
    env = {
        key: value
        for key, value in os.environ.items()
        if key not in GIT_LOCATION_ENV_KEYS
    }
    for key in list(env):
        if key.startswith(("GIT_CONFIG_KEY_", "GIT_CONFIG_VALUE_")):
            env.pop(key)
    return env


def run_cli_args(cli_path: str, args: list[str], *, cwd: str | None = None) -> ProbeResult:
    env = clean_git_env()
    for key in [
        "CMUX_SOCKET_PASSWORD",
        "CMUX_SOCKET",
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

        proc = subprocess.run(  # noqa: S603
            [cli_path, *args],
            text=True,
            capture_output=True,
            check=False,
            timeout=5.0,
            env=env,
            cwd=cwd,
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
    failures.extend(check_guide_contract(cli_path))
    failures.extend(check_task_help_contract(cli_path))
    failures.extend(check_review_ledger_contract(cli_path))
    failures.extend(check_review_runner_contract(cli_path))
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

    try:
        result = run_cli_args(cli_path, [])
    except subprocess.TimeoutExpired:
        failures.append("cmux: timed out")
    except (RuntimeError, OSError, ValueError) as exc:
        failures.append(f"cmux: {exc}")
    else:
        if result.returncode != 2:
            failures.append(
                f"cmux: expected missing-command exit 2, got {result.returncode}\n"
                f"stdout={result.stdout!r}\nstderr={result.stderr!r}"
            )
        if result.stdout:
            failures.append(
                f"cmux: missing-command usage should not write stdout\n"
                f"stdout={result.stdout!r}\nstderr={result.stderr!r}"
            )
        if "Missing command" not in result.stderr or "cmux --help" not in result.stderr:
            failures.append(
                f"cmux: missing-command error should point to cmux --help\n"
                f"stdout={result.stdout!r}\nstderr={result.stderr!r}"
            )
        if "browser find" in result.stderr or "cmux - control cmux via Unix socket" in result.stderr:
            failures.append(
                f"cmux: missing-command error should not dump full help\n"
                f"stdout={result.stdout!r}\nstderr={result.stderr!r}"
            )

    try:
        result = run_cli_args(cli_path, ["settings", "--help"])
    except subprocess.TimeoutExpired:
        failures.append("cmux settings --help stale-target check: timed out")
    except (RuntimeError, OSError, ValueError) as exc:
        failures.append(f"cmux settings --help stale-target check: {exc}")
    else:
        stale_usage = "Usage: cmux settings [open|path|docs|target]"
        target_usage = "Usage: cmux settings [open [target]|path|docs|<target>]"
        if stale_usage in result.stdout:
            failures.append(
                f"cmux settings --help: stale literal target usage still present\n"
                f"stdout={result.stdout!r}\nstderr={result.stderr!r}"
            )
        if target_usage not in result.stdout:
            failures.append(
                f"cmux settings --help: expected target-placeholder usage {target_usage!r}\n"
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



def check_review_ledger_contract(cli_path: str) -> list[str]:
    failures: list[str] = []
    with tempfile.TemporaryDirectory(prefix="cmux-review-ledger-") as tmpdir:
        repository = Path(tmpdir) / "repo"
        init = subprocess.run(
            ["git", "init", "-q", str(repository)],
            text=True,
            capture_output=True,
            check=False,
            timeout=5.0,
            env=clean_git_env(),
        )
        if init.returncode != 0:
            return [f"cmux review fixture: git init failed: {init.stderr!r}"]
        canonical_repository = str(repository.resolve())

        review_id = "aaaaaaaa-bbbbbbbb-" + ("c" * 64)
        receipt_dir = repository / ".git" / "cmux" / "reviews"
        receipt_dir.mkdir(parents=True)
        receipt = {
            "schema_version": 1,
            "policy_version": "cmux-review/v1",
            "repository_root": str(repository),
            "ruleset_sha256": None,
            "source": {
                "repository_id": "github:manaflow-ai/cmux",
                "base_sha": "1" * 40,
                "head_sha": "2" * 40,
                "tree_sha": "3" * 40,
                "working_tree_dirty": True,
                "patch_sha256": None,
            },
            "brief": {
                "intent": "Preserve the review ledger",
                "requirements": [
                    {
                        "requirement": "Read receipts without a running app",
                        "status": "satisfied",
                        "evidence": ["cmux review is routed before socket connection"],
                    }
                ],
                "out_of_scope_changes": [],
                "behavior_changed": ["Local review receipts are readable from the CLI"],
                "risk_areas": [],
                "file_groups": [],
                "reading_order": [],
                "safeguards": [],
                "coverage_gaps": [],
            },
            "summary": {
                "hypotheses_investigated": 2,
                "suppressed": 1,
                "refuted": 0,
                "verified": 1,
                "human_judgment": 0,
            },
            "findings": [
                {
                    "id": "LEDGER-01",
                    "title": "Verified finding",
                    "severity": "P1",
                    "claims": [
                        {
                            "kind": "inferred",
                            "message": "A real issue exists",
                            "evidence": [],
                        },
                        {
                            "kind": "proven",
                            "message": "The example failure reproduced",
                            "evidence": [],
                        },
                    ],
                    "failure_mode": "Example failure",
                    "paths": ["Sources/App.swift"],
                    "discovery_sources": ["correctness"],
                    "challenge": {"disposition": "survives_challenge", "evidence": []},
                    "verification": {"result": "reproduced", "evidence": []},
                    "repair": {
                        "attempted": True,
                        "result": "fixed",
                        "after_source": {
                            "repository_id": "github:manaflow-ai/cmux",
                            "base_sha": "1" * 40,
                            "head_sha": "4" * 40,
                            "tree_sha": "5" * 40,
                            "working_tree_dirty": True,
                            "patch_sha256": None,
                        },
                        "verification": {
                            "result": "passed",
                            "evidence": [
                                {
                                    "kind": "test",
                                    "summary": "original discriminator passes after repair",
                                }
                            ],
                        },
                    },
                    "disposition": "repaired",
                },
                {
                    "id": "LEDGER-02",
                    "title": "Suppressed nit",
                    "severity": "P3",
                    "claims": [
                        {
                            "kind": "inferred",
                            "message": "Low-value issue",
                            "evidence": [],
                        }
                    ],
                    "failure_mode": "No meaningful failure",
                    "paths": ["Sources/App.swift"],
                    "discovery_sources": ["rules"],
                    "challenge": {"disposition": "refuted", "evidence": []},
                    "verification": {"result": "not_reproduced", "evidence": []},
                    "repair": None,
                    "disposition": "suppressed",
                },
            ],
            "created_at": "2026-09-22T00:00:00Z",
        }
        (receipt_dir / f"{review_id}.json").write_text(
            json.dumps(receipt),
            encoding="utf-8",
        )

        # This instant is newer than 2026-09-22T00:00:00Z even though its
        # original ISO-8601 string sorts lexically before it.
        offset_review_id = "offset-newer-" + ("e" * 64)
        offset_receipt = dict(receipt)
        offset_receipt["created_at"] = "2026-09-21T23:30:00-01:00"
        (receipt_dir / f"{offset_review_id}.json").write_text(
            json.dumps(offset_receipt),
            encoding="utf-8",
        )

        cases = [
            (
                "list",
                ["review", "list", "--repo", str(repository), "--json"],
                lambda payload: (
                    payload["repo_root"] == canonical_repository
                    and payload["reviews"][0]["id"] == offset_review_id
                    and payload["reviews"][0]["verified"] == 1
                ),
            ),
            (
                "show",
                ["review", "show", "latest", "--json"],
                lambda payload: (
                    payload["policy_version"] == "cmux-review/v1"
                    and payload["brief"]["requirements"][0]["status"] == "satisfied"
                ),
            ),
            (
                "findings",
                ["review", "findings", "latest", "--json"],
                lambda payload: (
                    [finding["id"] for finding in payload["findings"]] == ["LEDGER-01"]
                ),
            ),
            (
                "findings --all",
                ["review", "findings", "latest", "--all", "--json"],
                lambda payload: (
                    [finding["id"] for finding in payload["findings"]]
                    == ["LEDGER-01", "LEDGER-02"]
                ),
            ),
        ]

        for label, args, validate in cases:
            try:
                result = run_cli_args(cli_path, args, cwd=str(repository))
            except (subprocess.TimeoutExpired, OSError, ValueError) as exc:
                failures.append(f"cmux review {label}: {exc}")
                continue
            if result.returncode != 0 or result.stderr:
                failures.append(
                    f"cmux review {label}: expected clean exit\n"
                    f"stdout={result.stdout!r}\nstderr={result.stderr!r}"
                )
                continue
            if result.socket_path in result.stdout:
                failures.append(
                    f"cmux review {label}: unexpectedly attempted socket access "
                    f"{result.socket_path!r}"
                )
                continue
            try:
                payload = json.loads(result.stdout)
            except json.JSONDecodeError as exc:
                failures.append(f"cmux review {label}: invalid JSON: {exc}")
                continue
            if not validate(payload):
                failures.append(
                    f"cmux review {label}: unexpected payload {payload!r}"
                )

        try:
            text_result = run_cli_args(cli_path, ["review", "show"], cwd=str(repository))
        except (subprocess.TimeoutExpired, OSError, ValueError) as exc:
            failures.append(f"cmux review show: {exc}")
        else:
            if (
                text_result.returncode != 0
                or "Requirements: 1 satisfied · 0 missing · 0 uncertain" not in text_result.stdout
                or "Findings: 1 verified · 0 human · 0 refuted · 1 suppressed" not in text_result.stdout
            ):
                failures.append(
                    "cmux review show: human output lost review summary\n"
                    f"stdout={text_result.stdout!r}\nstderr={text_result.stderr!r}"
                )

        future_receipt = dict(receipt)
        future_receipt["schema_version"] = 2
        (receipt_dir / ("future-" + ("d" * 64) + ".json")).write_text(
            json.dumps(future_receipt),
            encoding="utf-8",
        )
        try:
            future_result = run_cli_args(
                cli_path,
                ["review", "list", "--repo", str(repository), "--json"],
                cwd=str(repository),
            )
        except (subprocess.TimeoutExpired, OSError, ValueError) as exc:
            failures.append(f"cmux review list future receipt: {exc}")
        else:
            if (
                future_result.returncode == 0
                or "schema_version must be 1" not in future_result.stderr
            ):
                failures.append(
                    "cmux review list: future receipt schema should fail closed\n"
                    f"stdout={future_result.stdout!r}\nstderr={future_result.stderr!r}"
                )

    return failures

def check_task_help_contract(cli_path: str) -> list[str]:
    failures: list[str] = []
    topics = {
        "start": ("Start & Resume:", "open <path-or-url>..."),
        "agents": ("Agents:", "claude-teams [claude-args...]"),
        "navigate": ("Navigate & Arrange:", "new-split <left|right|up|down>"),
        "inspect": ("Inspect:", "tree [--all]"),
        "customize": ("Customize:", "settings [open [target]|path|docs|<target>]"),
        "automation": ("Automation:", "automation <list|show|test|enable|disable|logs|reload> [args]"),
        "browser": ("Browser:", "browser snapshot [--interactive|-i]"),
        "remote": ("Remote:", "remotes <list|add|remove>"),
        "diagnostics": ("Diagnostics / Advanced:", "ping"),
    }
    headings = {heading for heading, _ in topics.values()}

    for topic, (heading, needle) in topics.items():
        label = f"cmux help {topic}"
        try:
            result = run_cli_args(cli_path, ["help", topic])
        except subprocess.TimeoutExpired:
            failures.append(f"{label}: timed out")
            continue
        except (RuntimeError, OSError, ValueError) as exc:
            failures.append(f"{label}: {exc}")
            continue

        merged = f"{result.stdout}\n{result.stderr}".strip()
        if result.returncode != 0:
            failures.append(
                f"{label}: expected exit 0, got {result.returncode}\n"
                f"stdout={result.stdout!r}\nstderr={result.stderr!r}"
            )
            continue
        if result.stderr:
            failures.append(
                f"{label}: task help should write only stdout\n"
                f"stdout={result.stdout!r}\nstderr={result.stderr!r}"
            )
        if result.socket_path in merged:
            failures.append(
                f"{label}: unexpected socket usage with forced socket {result.socket_path!r}\n"
                f"stdout={result.stdout!r}\nstderr={result.stderr!r}"
            )
        if heading not in result.stdout or needle not in result.stdout:
            failures.append(
                f"{label}: missing task help content {heading!r} / {needle!r}\n"
                f"stdout={result.stdout!r}"
            )
        leaked = sorted(other for other in headings if other != heading and other in result.stdout)
        if leaked:
            failures.append(
                f"{label}: included unrelated task headings {leaked!r}\n"
                f"stdout={result.stdout!r}"
            )

    try:
        fallback = run_cli_args(cli_path, ["help", "unknown-task-topic"])
    except subprocess.TimeoutExpired:
        failures.append("cmux help unknown-task-topic: timed out")
    except (RuntimeError, OSError, ValueError) as exc:
        failures.append(f"cmux help unknown-task-topic: {exc}")
    else:
        if (
            fallback.returncode != 0
            or fallback.stderr
            or "cmux - control cmux via Unix socket" not in fallback.stdout
            or "Start & Resume:" not in fallback.stdout
        ):
            failures.append(
                "cmux help unknown-task-topic: expected legacy top-level help fallback\n"
                f"stdout={fallback.stdout!r}\nstderr={fallback.stderr!r}"
            )

    return failures


def check_guide_contract(cli_path: str) -> list[str]:
    failures: list[str] = []
    # An explicit missing socket and invalid window prove that guides do not
    # connect, authenticate, or focus a window, even with ambient cmux context.
    prefix = ["--socket", f"/tmp/cmux-guide-{uuid.uuid4().hex}.sock", "--window", "window:999999"]
    topics = {
        "cmux": [["guide"], ["--skill"]],
        "cloud": [["cloud", "guide"], ["cloud", "--skill"], ["vm", "guide"], ["vm", "--skill"]],
    }
    for topic, aliases in topics.items():
        expected_content = None
        for invocation in aliases:
            label = "cmux " + " ".join(invocation)
            try:
                plain = run_cli_args(cli_path, prefix + invocation)
                if plain.returncode != 0 or plain.stderr or not plain.stdout.startswith("# cmux"):
                    raise ValueError(f"guide failed: {plain}")
                if expected_content is None:
                    expected_content = plain.stdout
                if plain.stdout != expected_content:
                    raise ValueError("alias output differs from the canonical guide")
                for arguments in (["--json", *invocation], [*invocation, "--json"]):
                    result = run_cli_args(cli_path, prefix + arguments)
                    payload = json.loads(result.stdout)
                    if result.returncode != 0 or result.stderr or payload != {
                        "topic": topic, "format": "markdown", "content": expected_content,
                    }:
                        raise ValueError(f"JSON guide differs from plain output: {result}")
                if topic == "cmux":
                    for needle in ("cmux cloud", "Chrome", "cua-driver"):
                        if needle not in plain.stdout:
                            raise ValueError(f"local guide must include the Cloud detail: {needle}")
                expected = ["agent-browser.dev", "agent-browser --auto-connect", "agent-browser --cdp"]
                if topic == "cmux":
                    expected.append("agent-browser --headed")
                if topic == "cloud":
                    expected += ["cua-driver --version", "cua-driver doctor", "cua-driver mcp", "DISPLAY=:1", "cmux cloud route --json", "would_provision", "route --provision", "terminal wait", "terminal read", "google-chrome-stable", "--remote-debugging-port=9222", "cmux cloud dev <machine> --no-open"]
                missing = [needle for needle in expected if needle not in plain.stdout]
                if missing:
                    raise ValueError(f"guide is missing method details: {missing}")
                for suffix in (["unexpected"], ["--", "--help"]):
                    result = run_cli_args(cli_path, prefix + invocation + suffix)
                    if result.returncode != 2 or result.stdout or "Usage:" not in result.stderr:
                        raise ValueError(f"invalid arguments must fail before socket access: {result}")
            except (subprocess.TimeoutExpired, OSError, ValueError) as exc:
                failures.append(f"{label}: {exc}")
    return failures


if __name__ == "__main__":
    raise SystemExit(main())
