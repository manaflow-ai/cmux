#!/usr/bin/env python3
"""No runs-on reaches Blacksmith 32 vCPU without a measured reason in .github/runners.json `linux_sizes`.

Leo, 2026-11-01, on 1,531 jobs queued on blacksmith-32vcpu-ubuntu-2404: "ok. we clearly are not able to use
them. so we should have resized a long-ass time ago." and "(im pretty sure blacksmith trimmed us off a bit just
cuz we were allegedly costing like $10k a day) so we need to figure out solulus". Blacksmith caps concurrency in
vCPUs: one 32 vCPU job holds the room of eight 4 vCPU jobs, and on 2026-10-31 the 32 vCPU size billed about
193,000 minutes ($12.4k at $0.064 a minute).

`linux_sizes.jobs` maps `<workflow>#<job>` to the Blacksmith size the job's measurement picked. This test fails:

- a job whose runner text (runs-on, a matrix runner, an env or `with` value it hands on) names
  blacksmith-32vcpu-ubuntu-2404, or reads the capability map's `linux_32`, with no entry, or with an entry
  that neither says `why_32` nor is `pending` on a named open pull request;
- an entry whose `size` or `failover` the job's runner text does not name (the table and the workflow drift);
- an entry for a job that no longer exists;
- a `pending` list longer or shorter than PENDING: it only shrinks, so a moved job cannot come back.

Only literal labels are seen here. `vars.LINUX_RUNNER` and `fromJSON(vars.RUNNER_POOLS).linux` take the Linux
pool's live member, which main's .github/runners.json `pools.linux` declares (scripts/ci/runner_pools.py).
"""

from __future__ import annotations

import json
import re
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"
RUNNERS = ROOT / ".github" / "runners.json"
BIG = "blacksmith-32vcpu-ubuntu-2404"
LABEL = re.compile(r"blacksmith-(\d+)vcpu-ubuntu-2404(?![-\w])")
CAPABILITY_32 = re.compile(r"outputs\.map\)\.linux_32\b")
# Jobs still on 32 vCPU while an open pull request changes the same runs-on. Lower it as they move; never raise it.
PENDING = 51


def table() -> dict:
    return json.loads(RUNNERS.read_text(encoding="utf-8"))["linux_sizes"]


def jobs() -> dict[str, str]:
    """`<workflow>#<job>` -> the job's whole definition as text, for every workflow job."""
    found = {}
    for path in sorted(WORKFLOWS.glob("*.y*ml")):
        document = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
        for name, job in (document.get("jobs") or {}).items():
            found[f"{path.name}#{name}"] = json.dumps(job)
    return found


def sizes(text: str) -> set[int]:
    return {int(size) for size in LABEL.findall(text)}


def reaches_32(text: str) -> bool:
    return 32 in sizes(text) or CAPABILITY_32.search(text) is not None


def problems(entries: dict, found: dict[str, str]) -> list[str]:
    out = []
    for key, text in sorted(found.items()):
        if not reaches_32(text):
            continue
        entry = entries.get(key)
        if entry is None:
            out.append(f"{key} can run on {BIG} and has no .github/runners.json linux_sizes entry")
        elif not entry.get("pending") and not entry.get("why_32"):
            out.append(f"{key} can run on {BIG} but its entry has neither why_32 nor pending")
    for key, entry in sorted(entries.items()):
        if key not in found:
            out.append(f"{key}: linux_sizes names a job that does not exist")
            continue
        if not isinstance(entry.get("measured"), dict):
            out.append(f"{key}: entry has no measured map")
        if entry.get("pending"):
            continue
        named = sizes(found[key])
        for field in ("size", "failover"):
            if field in entry and entry[field] not in named:
                out.append(f"{key}: linux_sizes {field} {entry[field]} is not a label its runner text names {sorted(named)}")
        if "size" not in entry:
            out.append(f"{key}: entry has no size")
    return out


class BlacksmithLinuxSizesTest(unittest.TestCase):
    def test_every_32_vcpu_route_is_measured(self) -> None:
        self.assertEqual(problems(table()["jobs"], jobs()), [])

    def test_the_pending_list_only_shrinks(self) -> None:
        pending = sorted(key for key, entry in table()["jobs"].items() if entry.get("pending"))
        self.assertEqual(len(pending), PENDING,
                         f"{len(pending)} jobs are pending (allowed {PENDING}); lower PENDING when one moves: {pending}")

    def test_every_size_has_a_price(self) -> None:
        declared = table()
        prices = {int(size) for size in declared["prices_usd_per_minute"]}
        used = {entry[field] for entry in declared["jobs"].values() for field in ("size", "failover", "target")
                if field in entry}
        self.assertLessEqual(used, prices)

    def test_the_checker(self) -> None:
        fake = {"a.yml#small": "'blacksmith-4vcpu-ubuntu-2404'", "a.yml#big": f"'{BIG}'",
                "a.yml#map": "fromJSON(needs.runners.outputs.map).linux_32"}
        self.assertEqual(len(problems({}, fake)), 2)
        self.assertEqual(problems({"a.yml#big": {"size": 32, "measured": {}, "why_32": "x"},
                                   "a.yml#map": {"measured": {}, "pending": "#1"}}, fake), [])
        self.assertTrue(problems({"a.yml#small": {"size": 8, "measured": {}}}, fake))
        self.assertTrue(problems({"a.yml#gone": {"size": 4, "measured": {}}}, fake))


if __name__ == "__main__":
    unittest.main()
