#!/usr/bin/env python3
"""A job its name calls advisory ends in "(advisory)", so autoland and the verdict skip it.

next_autoland and cmuxterm-hq's now_pr_verdict.py drop a check only when a " / " part of its key ends "(advisory)".
chat-size-ladder.yml's job was "chat-size ladder (base vs head, advisory)": it said advisory but missed the suffix, so
on 2026-11-28 every acpmux head waited 46-62 min on it before landing and the verdict counted it (bound ratio 3.95).
"""
from __future__ import annotations

import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]


def advisory_names_without_suffix() -> list[str]:
    bad = []
    for path in sorted((ROOT / ".github/workflows").glob("*.y*ml")):
        workflow = yaml.safe_load(path.read_text()) or {}
        for key, job in (workflow.get("jobs") or {}).items():
            name = str((job or {}).get("name", key))
            if "advisory" in name.lower() and "(advisory)" not in name.lower():
                bad.append(f"{path.name}: {name}")
    return bad


class AdvisoryJobNames(unittest.TestCase):
    def test_every_job_named_advisory_carries_the_suffix(self) -> None:
        self.assertEqual(advisory_names_without_suffix(), [])


if __name__ == "__main__":
    unittest.main()
