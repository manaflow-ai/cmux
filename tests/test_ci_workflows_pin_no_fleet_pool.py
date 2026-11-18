#!/usr/bin/env python3
"""No workflow submits a build-fleet job with `--pool`.

A pool is a reservation: an operator runs `cmux-ci reserve --pool NAME` for a while (often with --until)
and `cmux-ci unreserve` ends it. Once it ends, the controller refuses every `--pool NAME` job at submit
("controller HTTP 400: pool NAME reserves no worker now"). A person running a step by hand sees that at
once; a scheduled workflow fails every day with no one reading it. The nightly perf bench
(cmux-next-perf-bench.yml) did exactly that from 2026-11-07 to 2026-11-14: #37048 added
`--pool perf-lead` on 2026-11-06 while cmux20 was owner-only for that pool, and the perf-lead
reservation of cmux16-24 was lifted the same day (Leo: "16 to 24 are no longer under reserve").

So a workflow picks its worker by labels (`--label bench`) or `--target-worker`, which do not lapse.
A failure names the file, the line and the command.
"""
from __future__ import annotations

import re
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github/workflows"

# A build-fleet client call: the installed client by name, or the "$client" variable the gateway
# steps set to it (cmux-next-perf-bench.yml and the eval gateways).
FLEET_CALL = re.compile(r"""(?:\bcmux-ci\b|["']?\$\{?client\}?["']?)\s+(?:run|build|submit|test)\b""")
POOL_FLAG = re.compile(r"(?<![\w-])--pool(?:[\s=]|$)")


def logical_lines(text: str) -> list[tuple[int, str]]:
    """Shell commands with backslash continuations joined, each with its first line number."""
    out: list[tuple[int, str]] = []
    buf: list[str] = []
    start = 0
    for number, raw in enumerate(text.splitlines(), 1):
        line = raw.rstrip()
        if not buf:
            start = number
        if line.endswith("\\"):
            buf.append(line[:-1])
            continue
        buf.append(line)
        out.append((start, " ".join(part.strip() for part in buf)))
        buf = []
    if buf:
        out.append((start, " ".join(part.strip() for part in buf)))
    return out


def pinned_pools(path: Path, text: str) -> list[str]:
    rel = path.relative_to(ROOT) if path.is_relative_to(ROOT) else path
    findings = []
    for number, command in logical_lines(text):
        if command.lstrip().startswith("#"):
            continue
        if FLEET_CALL.search(command) and POOL_FLAG.search(command):
            findings.append(
                f"{rel}:{number}: a build-fleet job submitted with --pool: {command.strip()[:200]}\n"
                "  A pool is a reservation that lapses, and then the controller refuses the job at submit "
                "(\"pool NAME reserves no worker now\"). Pick the worker by --label or --target-worker.")
    return findings


class WorkflowsPinNoFleetPool(unittest.TestCase):
    def test_no_workflow_submits_with_a_pool(self) -> None:
        paths = sorted([*WORKFLOWS.glob("*.yml"), *WORKFLOWS.glob("*.yaml")])
        self.assertTrue(paths)
        findings = [f for p in paths for f in pinned_pools(p, p.read_text(encoding="utf-8"))]
        self.assertEqual(findings, [], "\n".join(findings))

    def test_detects_a_continued_client_call_with_a_pool(self) -> None:
        text = ('          "$client" run --class exclusive --measurement --pool perf-lead --label bench \\\n'
                '            --script scripts/measure/perf-bench.sh --ref "$sha"\n')
        self.assertEqual(len(pinned_pools(WORKFLOWS / "x.yml", text)), 1)
        text = "          cmux-ci build cmux --ref x \\\n            --pool=perf-lead\n"
        self.assertEqual(len(pinned_pools(WORKFLOWS / "x.yml", text)), 1)

    def test_ignores_comments_other_tools_and_pools_flags(self) -> None:
        text = ("          # cmux-ci run --pool perf-lead was refused once\n"
                '          python3 scripts/ci/cmux_tui_publisher_testing.py --run-id "$r" --pool "${DAEMON_POOL:-}"\n'
                '          cmux-ci run --class exclusive --measurement --label bench --script s.sh\n'
                '          python3 scripts/ci/seed.py --pools "$SEED_POOLS"\n')
        self.assertEqual(pinned_pools(WORKFLOWS / "x.yml", text), [])


if __name__ == "__main__":
    sys.exit(0 if unittest.main(exit=False, verbosity=1).result.wasSuccessful() else 1)
