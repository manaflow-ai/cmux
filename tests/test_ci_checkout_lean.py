#!/usr/bin/env python3
"""Full-tree blob:none checkouts leave out the media the job never reads (.github/checkout-lean.json).

A full-tree `filter: blob:none` checkout downloads every blob at the tip: about 570 MiB in cmux, about
470 MiB of it media and QA evidence under cmux-next-ios/verify/. Behind a slow git cache that took a
checkout from about 50 s to 3-5 min (2026-11-03). .github/checkout-lean.json is the one declared table:
its `sparse_checkout` patterns, the jobs proven not to read those paths (`lean`) and the jobs that keep
the full tree with their reason (`full`). actions/checkout runs before any repository file exists, so a
composite action cannot hold the patterns; this test keeps every listed step equal to the table instead.
It fails when

  (a) a `lean` job's blob:none checkout does not use exactly the table's patterns in non-cone mode;
  (b) a full-tree blob:none checkout (no sparse-checkout) is in neither list;
  (c) an entry names a workflow or job that no longer has such a checkout, or has no reason.

`python3 tests/test_ci_checkout_lean.py --write` adds the table's patterns to every `lean` step that lacks them.
"""

from __future__ import annotations

import json
import re
import sys
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"
TABLE = ROOT / ".github" / "checkout-lean.json"
SCHEMA = "checkout-lean/v1"


def table() -> dict:
    data = json.loads(TABLE.read_text(encoding="utf-8"))
    assert data.get("schema") == SCHEMA, f"{TABLE.name}: schema is not {SCHEMA}"
    return data


def blob_none_checkouts():
    """(workflow, job, step index, with) for every actions/checkout step with filter blob:none."""
    for path in sorted(WORKFLOWS.glob("*.y*ml")):
        doc = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
        for job_id, job in (doc.get("jobs") or {}).items():
            for i, step in enumerate((job or {}).get("steps") or []):
                uses = str((step or {}).get("uses") or "")
                options = (step or {}).get("with") or {}
                if uses.startswith("actions/checkout@") and str(options.get("filter", "")) == "blob:none":
                    yield path.name, str(job_id), i, options


def patterns(options: dict) -> list[str] | None:
    raw = options.get("sparse-checkout")
    return None if raw is None else [line.strip() for line in str(raw).splitlines() if line.strip()]


def is_lean(options: dict, want: list[str]) -> bool:
    return patterns(options) == want and options.get("sparse-checkout-cone-mode") is False


class CheckoutLeanTest(unittest.TestCase):
    def setUp(self):
        self.table = table()
        self.want = self.table["sparse_checkout"]
        self.steps = list(blob_none_checkouts())

    def test_lean_jobs_use_the_declared_patterns(self):
        bad = []
        for wf, job, i, options in self.steps:
            if job in self.table["lean"].get(wf, {}) and not is_lean(options, self.want):
                bad.append(f"{wf} :: {job} step {i}: sparse-checkout {patterns(options)!r}, "
                           f"cone mode {options.get('sparse-checkout-cone-mode')!r}")
        self.assertEqual(bad, [], f"run `python3 tests/test_ci_checkout_lean.py --write`, or move the job to "
                                  f"`full` in {TABLE.name} with its reason:\n" + "\n".join(bad))

    def test_every_full_tree_blob_none_checkout_is_declared(self):
        undeclared = sorted({f"{wf} :: {job}" for wf, job, _, options in self.steps
                             if patterns(options) is None and job not in self.table["lean"].get(wf, {})
                             and job not in self.table["full"].get(wf, {})})
        self.assertEqual(undeclared, [], f"a full-tree blob:none checkout downloads every blob, "
                                         f"{self.want[1:]} included: prove the job reads none of them and add it to "
                                         f"`lean` in {TABLE.name}, or add it to `full` with the reason it needs them:\n"
                                         + "\n".join(undeclared))

    def test_entries_are_live_and_reasoned(self):
        live = {(wf, job) for wf, job, _, options in self.steps
                if patterns(options) is None or is_lean(options, self.want)}
        stale, unreasoned = [], []
        for kind in ("lean", "full"):
            for wf, jobs in self.table[kind].items():
                for job, reason in jobs.items():
                    if (wf, job) not in live:
                        stale.append(f"{kind}: {wf} :: {job}")
                    if len(str(reason).strip()) < 20:
                        unreasoned.append(f"{kind}: {wf} :: {job}")
        self.assertEqual(stale, [], "no full-tree or lean blob:none checkout there any more: drop the entry")
        self.assertEqual(unreasoned, [], "each entry says what the job reads, or why it needs the full tree")

    def test_patterns_keep_the_tree_and_drop_only_named_paths(self):
        self.assertEqual(self.want[0], "/*")
        self.assertTrue(all(p.startswith("!/") and p.endswith("/") for p in self.want[1:]), self.want)


def write() -> int:
    """Insert the table's patterns after `filter: blob:none` in each lean step that lacks them."""
    data = table()
    want = data["sparse_checkout"]
    todo = {}
    for wf, job, i, options in blob_none_checkouts():
        if job in data["lean"].get(wf, {}) and patterns(options) is None:
            todo.setdefault(wf, set()).add(job)
    for wf, jobs in todo.items():
        path = WORKFLOWS / wf
        lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
        out, job = [], None
        for line in lines:
            m = re.match(r"^  ([A-Za-z0-9_-]+):\s*$", line)
            if m:
                job = m.group(1)
            out.append(line)
            f = re.match(r"^(\s+)filter: blob:none\b", line)
            if f and job in jobs:
                pad = f.group(1)
                out.append(f"{pad}sparse-checkout-cone-mode: false # patterns: .github/checkout-lean.json\n")
                out.append(f"{pad}sparse-checkout: |\n")
                out.extend(f"{pad}  {p}\n" for p in want)
        path.write_text("".join(out), encoding="utf-8")
        print(f"{wf}: {', '.join(sorted(jobs))}")
    return 0


if __name__ == "__main__":
    if sys.argv[1:] == ["--write"]:
        sys.exit(write())
    unittest.main()
