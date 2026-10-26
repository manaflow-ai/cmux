#!/usr/bin/env python3
"""expectations.py: entry rules, expiry, `lab.py expectations --check` and the skip hook inside scheduler.plan().

  python3 -m unittest scripts/perf-lab/tests/test_expectations.py
"""
from __future__ import annotations

import importlib.util
import io
import json
import subprocess
import sys
import tempfile
import unittest
from argparse import Namespace
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

LAB = Path(__file__).resolve().parent.parent
REPO_ROOT = LAB.parents[1]


def _load(name: str):
    module_name = f"perf_lab_{name}"
    if module_name in sys.modules:
        return sys.modules[module_name]
    spec = importlib.util.spec_from_file_location(module_name, LAB / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    spec.loader.exec_module(module)
    return module


expectations = _load("expectations")
scheduler = _load("scheduler")
gen = _load("gen_shard_map")

TODAY = date(2026, 10, 26)
NOW = datetime(2026, 10, 26, 12, 0, tzinfo=timezone.utc)
M6 = "apple-m6/24gb/120hz"
M6_32 = "apple-m6/32gb/120hz"
ISSUE = "https://github.com/manaflow-ai/cmux/issues/25000"


def entry(**changes):
    item = {"story": "t0-key", "host_class": M6, "reason": "key story crashes on the M6 driver",
            "issue": ISSUE, "added": "2026-10-24", "expires": "2026-10-31"}
    item.update(changes)
    return item


def document(*items):
    return {"schema": expectations.SCHEMA, "expectations": list(items)}


def parsed(*items):
    return expectations.from_document(document(*items))


class EntryRuleTests(unittest.TestCase):
    def test_valid_entry_has_no_problems_and_skips_its_pair_only(self):
        loaded = parsed(entry())
        self.assertEqual(loaded.check(TODAY), [])
        active = loaded.active(TODAY)
        self.assertTrue(active.skip("t0-key", scheduler.Host("a", "pinpoint", "m6", M6)))
        self.assertFalse(active.skip("t0-key", scheduler.Host("b", "pinpoint", "m6", M6_32)))
        self.assertFalse(active.skip("t0-switch", scheduler.Host("a", "pinpoint", "m6", M6)))

    def test_expired_entry_is_reported_and_skips_nothing(self):
        loaded = parsed(entry(added="2026-10-18", expires="2026-10-25"))
        problems = loaded.check(TODAY)
        self.assertEqual(len(problems), 1)
        self.assertIn("expired on 2026-10-25", problems[0])
        self.assertIn(ISSUE, problems[0])
        self.assertEqual(loaded.active(TODAY).pairs, frozenset())

    def test_entry_skips_through_its_expires_day(self):
        loaded = parsed(entry(added="2026-10-19", expires="2026-10-26"))
        self.assertEqual(loaded.check(TODAY), [])
        self.assertEqual(loaded.active(TODAY).pairs, {("t0-key", M6)})
        self.assertEqual(loaded.active(TODAY + timedelta(days=1)).pairs, frozenset())

    def test_issue_less_entry_is_reported_and_skips_nothing(self):
        for issue in ("", "TODO", "#25000", "http://example.com/1"):
            with self.subTest(issue=issue):
                loaded = parsed(entry(issue=issue))
                self.assertTrue(any("not an https issue link" in p for p in loaded.check(TODAY)))
                self.assertEqual(loaded.active(TODAY).pairs, frozenset())

    def test_missing_issue_field_is_reported(self):
        item = entry()
        del item["issue"]
        loaded = parsed(item)
        self.assertEqual(loaded.entries, ())
        self.assertEqual(loaded.check(TODAY), ["expectations.json entry 0: missing issue"])

    def test_expiry_more_than_seven_days_after_added_is_reported(self):
        loaded = parsed(entry(added="2026-10-24", expires="2026-11-01"))
        self.assertTrue(any("more than 7 days" in p for p in loaded.check(TODAY)))
        self.assertEqual(loaded.active(TODAY).pairs, frozenset())
        self.assertEqual(parsed(entry(added="2026-10-24", expires="2026-10-31")).check(TODAY), [])

    def test_added_in_the_future_cannot_stretch_the_window(self):
        loaded = parsed(entry(added="2026-11-20", expires="2026-11-27"))
        self.assertTrue(any("is after 2026-10-26" in p for p in loaded.check(TODAY)))
        self.assertEqual(loaded.active(TODAY).pairs, frozenset())

    def test_expires_before_added_is_reported(self):
        self.assertTrue(any("before added" in p for p in parsed(entry(expires="2026-10-23")).check(TODAY)))

    def test_bad_dates_unknown_fields_and_host_classes_are_reported(self):
        problems = parsed(entry(added="next week"), entry(owner="me"), entry(host_class="m6"),
                          entry(reason=" ")).check(TODAY)
        self.assertIn("expectations.json entry 0: added 'next week' is not a YYYY-MM-DD date", problems)
        self.assertIn("expectations.json entry 1: unknown owner", problems)
        self.assertTrue(any("entry 2: host_class 'm6'" in p for p in problems))
        self.assertIn("expectations.json entry 3: reason is empty", problems)

    def test_duplicate_pair_is_reported_and_skips_nothing(self):
        loaded = parsed(entry(), entry(reason="again"))
        self.assertIn(f"expectations.json: t0-key on {M6} is listed more than once", loaded.check(TODAY))
        self.assertEqual(loaded.active(TODAY).pairs, frozenset())

    def test_unknown_story_is_reported_against_the_catalog(self):
        problems = parsed(entry(story="gone")).check(TODAY, stories=["t0-key"])
        self.assertEqual(problems, ["expectations.json entry 0: story 'gone' is not in stories.d/"])

    def test_malformed_document_raises(self):
        for bad in ({}, {"schema": expectations.SCHEMA}, {"schema": "other", "expectations": []}, []):
            with self.subTest(bad=bad), self.assertRaises(expectations.ExpectationsError):
                expectations.from_document(bad)


class SchedulerInputTests(unittest.TestCase):
    """The skip hook inside plan(): a matching story x host-class pair is skipped, every other pair runs."""

    STORIES = (
        scheduler.StorySpec("t0-key", "T0", 150, "bench"),
        scheduler.StorySpec("t0-switch", "T0", 120, "bench"),
    )
    SHARD_MAP = scheduler.ShardMap.from_document(gen.generate(STORIES))
    # two m6 shards on hosts of different host classes, so an entry names one of them
    HOSTS = (scheduler.Host("wf-a", "waterfall", "m6", M6, shard=0),
             scheduler.Host("wf-b", "waterfall", "m6", M6_32, shard=1))

    def _owner(self, story):
        return self.HOSTS[self.SHARD_MAP.owner("m6", "T0", story)]

    def _t0_plan(self, skip):
        tip = f"{1:040x}"
        cut = scheduler.plan(scheduler.State(), NOW, self.HOSTS, scheduler.Builds(), (tip,), stories=self.STORIES,
                             shard_map=self.SHARD_MAP, skip=skip)
        self.assertEqual([(b.sha, b.config) for b in cut.builds], [(tip, "bench")])
        built = scheduler.Builds(ready=frozenset({(tip, "bench")}))
        return scheduler.plan(cut.state, NOW + timedelta(minutes=6), self.HOSTS, built, (tip,),
                              stories=self.STORIES, shard_map=self.SHARD_MAP, skip=skip)

    @staticmethod
    def _planned(result):
        return {(j.host, s) for j in result.jobs if j.tier == "T0" for s in j.stories}

    def test_matching_pair_is_skipped_by_plan(self):
        owner = self._owner("t0-key")
        self.assertNotEqual(owner, self._owner("t0-switch"))
        result = self._t0_plan(parsed(entry(host_class=owner.host_class)).active(TODAY).skip)
        planned = self._planned(result)
        self.assertNotIn(owner.name, {host for host, _ in planned})  # its only story was skipped: no job
        self.assertIn((self._owner("t0-switch").name, "t0-switch"), planned)
        self.assertEqual([(s.story, s.host) for s in result.skipped], [("t0-key", owner.name)])

    def test_entry_for_another_host_class_does_not_skip(self):
        other = self._owner("t0-switch")
        result = self._t0_plan(parsed(entry(host_class=other.host_class)).active(TODAY).skip)
        self.assertEqual(result.skipped, ())
        self.assertIn((self._owner("t0-key").name, "t0-key"), self._planned(result))

    def test_expired_entry_lets_plan_run_the_story(self):
        owner = self._owner("t0-key")
        loaded = parsed(entry(host_class=owner.host_class, added="2026-10-18", expires="2026-10-25"))
        result = self._t0_plan(loaded.active(TODAY).skip)
        self.assertEqual(result.skipped, ())
        self.assertIn((owner.name, "t0-key"), self._planned(result))


class CommandTests(unittest.TestCase):
    def _run(self, items, *, check=True, today=TODAY):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "expectations.json"
            path.write_text(json.dumps(document(*items)))
            out, err = io.StringIO(), io.StringIO()
            code = expectations.run("expectations", Namespace(root=REPO_ROOT, file=path, check=check, today=today),
                                    out, err)
        return code, out.getvalue(), err.getvalue()

    def test_check_fails_on_an_expired_entry(self):
        code, out, err = self._run([entry(story="switch", added="2026-10-18", expires="2026-10-25")])
        self.assertEqual(code, 1)
        self.assertIn("expired on 2026-10-25", err)
        self.assertIn("switch\tapple-m6/24gb/120hz\texpired", out)

    def test_check_fails_on_an_issue_less_entry(self):
        code, _, err = self._run([entry(story="switch", issue="")])
        self.assertEqual(code, 1)
        self.assertIn("not an https issue link", err)

    def test_check_passes_on_a_valid_entry_and_lists_it(self):
        code, out, err = self._run([entry(story="switch")])
        self.assertEqual((code, err), (0, ""))
        self.assertIn("switch\tapple-m6/24gb/120hz\tskips through 2026-10-31", out)

    def test_without_check_problems_are_printed_but_do_not_fail(self):
        code, _, err = self._run([entry(story="switch", issue="")], check=False)
        self.assertEqual(code, 0)
        self.assertIn("not an https issue link", err)

    def test_checked_in_file_passes_through_lab_py(self):
        done = subprocess.run([sys.executable, "-I", str(LAB / "lab.py"), "expectations", "--check"],
                              capture_output=True, text=True)
        self.assertEqual(done.returncode, 0, done.stderr)


if __name__ == "__main__":
    unittest.main()
