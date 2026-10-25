#!/usr/bin/env python3
"""expectations.py: expiry, issue links, the 7-day cap, `--check` and the scheduler's skip input.

  python3 -m unittest scripts/perf-lab/tests/test_expectations.py
"""
from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import sys
import tempfile
import unittest
from dataclasses import dataclass
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

EXPECTATIONS_PY = Path(__file__).resolve().parent.parent / "expectations.py"
_SPEC = importlib.util.spec_from_file_location("perf_lab_expectations", EXPECTATIONS_PY)
expectations = importlib.util.module_from_spec(_SPEC)
sys.modules[_SPEC.name] = expectations
_SPEC.loader.exec_module(expectations)

NOW = datetime(2026, 10, 25, 12, 0, tzinfo=timezone.utc)
M6 = "apple-m4-pro/24gb/120hz"
M6_60 = "apple-m4-pro/24gb/60hz"
ISSUE = "https://github.com/manaflow-ai/cmux/issues/25000"


def entry(**overrides) -> dict:
    base = dict(story="terminal.key-frame.light", host_class=M6, reason="flaky warm-up after macOS 26.1",
                issue=ISSUE, added="2026-10-23", expires="2026-10-30")
    base.update(overrides)
    return {key: value for key, value in base.items() if value is not None}


def document(*entries: dict) -> dict:
    return {"schema": expectations.SCHEMA, "entries": list(entries)}


def load(*entries: dict):
    return expectations.Expectations.from_document(document(*entries))


@dataclass(frozen=True)
class SchedulerHost:
    """The host shape plan() gets from the controller: a name, a role and a store host class."""
    name: str
    role: str
    host_class: str


class ExpiryTests(unittest.TestCase):
    def test_entry_in_force_from_added_until_the_expires_day(self):
        loaded = load(entry())
        self.assertFalse(loaded.skip("terminal.key-frame.light", M6, date(2026, 10, 22)))
        self.assertTrue(loaded.skip("terminal.key-frame.light", M6, date(2026, 10, 23)))
        self.assertTrue(loaded.skip("terminal.key-frame.light", M6, datetime(2026, 10, 29, 23, 59, tzinfo=timezone.utc)))
        self.assertFalse(loaded.skip("terminal.key-frame.light", M6, datetime(2026, 10, 30, 0, 0, tzinfo=timezone.utc)))

    def test_expired_entry_is_reported_and_no_longer_skips(self):
        loaded = load(entry(added="2026-10-15", expires="2026-10-20"))
        problems = loaded.problems(NOW)
        self.assertEqual(len(problems), 1)
        self.assertIn("expired on 2026-10-20", problems[0].message)
        self.assertIn(ISSUE, problems[0].message)
        self.assertEqual(loaded.entries[0].state(NOW.date()), "expired")
        self.assertFalse(loaded.skip("terminal.key-frame.light", M6, NOW))

    def test_day_boundary_is_utc(self):
        loaded = load(entry())
        tokyo = timezone(timedelta(hours=9))
        # 2026-10-30 08:00 in Tokyo is still 2026-10-29 in UTC.
        self.assertTrue(loaded.skip("terminal.key-frame.light", M6, datetime(2026, 10, 30, 8, 0, tzinfo=tokyo)))
        with self.assertRaises(ValueError):
            loaded.in_force(datetime(2026, 10, 25, 12, 0))

    def test_lifetime_over_seven_days_is_invalid_and_never_skips(self):
        loaded = load(entry(added="2026-10-23", expires="2026-10-31"))
        self.assertIn("more than 7 days", loaded.problems(NOW)[0].message)
        self.assertFalse(loaded.skip("terminal.key-frame.light", M6, NOW))
        self.assertEqual(load(entry(added="2026-10-23", expires="2026-10-30")).problems(NOW), [])

    def test_expires_not_after_added_is_invalid(self):
        loaded = load(entry(added="2026-10-25", expires="2026-10-25"))
        self.assertIn("must be after added", loaded.problems(NOW)[0].message)

    def test_added_in_the_future_is_reported(self):
        loaded = load(entry(added="2026-10-27", expires="2026-10-30"))
        self.assertEqual([p.message for p in loaded.problems(NOW)], ["added 2026-10-27 is in the future"])
        self.assertFalse(loaded.skip("terminal.key-frame.light", M6, NOW))


class ValidationTests(unittest.TestCase):
    def test_issue_less_entry_is_reported_and_never_skips(self):
        for issue in (None, "", "  "):
            with self.subTest(issue=issue):
                loaded = load(entry(issue=issue))
                self.assertEqual([p.message for p in loaded.problems(NOW)], ["missing issue"])
                self.assertFalse(loaded.skip("terminal.key-frame.light", M6, NOW))

    def test_issue_must_be_a_manaflow_issue_link(self):
        for issue in ("#25000", "https://github.com/manaflow-ai/cmux/pull/25000",
                      "https://github.com/someone/cmux/issues/1", "crbug.com/123"):
            with self.subTest(issue=issue):
                self.assertIn("issue must be", load(entry(issue=issue)).problems(NOW)[0].message)
        hq = "https://github.com/manaflow-ai/cmuxterm-hq/issues/7"
        self.assertEqual(load(entry(issue=hq)).problems(NOW), [])

    def test_every_field_is_required_and_unknown_keys_are_refused(self):
        for key in expectations.ENTRY_KEYS:
            with self.subTest(key=key):
                messages = [p.message for p in load(entry(**{key: None})).problems(NOW)]
                self.assertIn(f"missing {key}", messages)
        typo = entry()
        typo["expiry"] = "2026-10-30"
        self.assertIn("unknown keys ['expiry']", load(typo).problems(NOW)[0].message)

    def test_bad_dates_and_host_classes(self):
        self.assertIn("YYYY-MM-DD", load(entry(expires="10/30/2026")).problems(NOW)[0].message)
        self.assertIn("not a calendar date", load(entry(expires="2026-02-30")).problems(NOW)[0].message)
        self.assertIn("host_class must look like", load(entry(host_class="cmux15")).problems(NOW)[0].message)
        self.assertIn("must be a string", load(entry(added=20261023)).problems(NOW)[0].message)

    def test_duplicate_pair_and_unknown_story(self):
        loaded = load(entry(), entry(reason="again"), entry(story="no.such.story"))
        messages = [str(p) for p in loaded.problems(NOW, known_stories={"terminal.key-frame.light"})]
        self.assertEqual(len(messages), 2)
        self.assertIn("entries[1] terminal.key-frame.light @ apple-m4-pro/24gb/120hz: duplicates entries[0]", messages)
        self.assertIn("entries[2] no.such.story @ apple-m4-pro/24gb/120hz: unknown story: no stories.d/no.such.story.json",
                      messages)
        self.assertEqual(load(entry(story="no.such.story")).problems(NOW, known_stories=None), [])

    def test_malformed_documents_raise_typed_errors(self):
        for bad in ([], {"entries": []}, {"schema": "v0", "entries": []}, {"schema": expectations.SCHEMA},
                    {"schema": expectations.SCHEMA, "entries": [], "extra": 1}):
            with self.subTest(bad=bad), self.assertRaises(expectations.ExpectationsError):
                expectations.Expectations.from_document(bad)
        self.assertEqual(load("not an object").problems(NOW)[0].message, "entry must be an object")

    def test_checked_in_file_passes(self):
        loaded = expectations.Expectations.load(expectations.DEFAULT_PATH)
        self.assertEqual(loaded.problems(datetime.now(timezone.utc),
                                         expectations.known_story_ids(expectations.DEFAULT_STORIES_DIR)), [])


class SchedulerInputTests(unittest.TestCase):
    """plan() gets `in_force(now)` and asks it, per waterfall host, which shard-map stories it may plan."""

    HOSTS = (
        SchedulerHost("cmux15", "waterfall", M6),
        SchedulerHost("cmux16", "waterfall", M6_60),
        SchedulerHost("cmux17", "pinpoint", M6),
    )
    SHARD_MAP = {
        "cmux15": ["terminal.key-frame.light", "sidebar.switch.light", "launch.cold"],
        "cmux16": ["terminal.key-frame.light", "tabs.reorder.light"],
    }

    def test_matching_pair_is_skipped_and_every_other_pair_is_planned(self):
        active = load(entry(), entry(story="launch.cold", host_class=M6_60)).in_force(NOW)
        planned = {host.name: active.runnable(self.SHARD_MAP[host.name], host)
                   for host in self.HOSTS if host.role == "waterfall"}
        self.assertEqual(planned, {
            "cmux15": ["sidebar.switch.light", "launch.cold"],
            "cmux16": ["terminal.key-frame.light", "tabs.reorder.light"],
        })
        # A bisect on a pinpoint host of the same class asks the same question.
        self.assertTrue(active.skip("terminal.key-frame.light", self.HOSTS[2]))
        self.assertFalse(active.skip("terminal.key-frame.light", {"name": "cmux16", "host_class": M6_60}))

    def test_expired_entry_puts_the_story_back_in_the_plan(self):
        active = load(entry(added="2026-10-15", expires="2026-10-20")).in_force(NOW)
        self.assertEqual(active.runnable(self.SHARD_MAP["cmux15"], self.HOSTS[0]), self.SHARD_MAP["cmux15"])

    def test_default_input_skips_nothing_and_hosts_need_a_class(self):
        self.assertFalse(expectations.ActiveExpectations().skip("launch.cold", M6))
        with self.assertRaises(TypeError):
            expectations.ActiveExpectations().skip("launch.cold", {"name": "cmux15"})


class CliTests(unittest.TestCase):
    def run_cli(self, entries: list, *args: str, stories: list[str] | None = None) -> tuple[int, str]:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "expectations.json"
            path.write_text(json.dumps(document(*entries)))
            stories_dir = Path(tmp) / "stories.d"
            if stories is not None:
                stories_dir.mkdir()
                for story in stories:
                    (stories_dir / f"{story}.json").write_text("{}")
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                code = expectations.main(["--file", str(path), "--stories-dir", str(stories_dir), *args], now=NOW)
            return code, out.getvalue()

    def test_check_passes_on_valid_entries(self):
        code, out = self.run_cli([entry()], "--check", stories=["terminal.key-frame.light"])
        self.assertEqual(code, 0)
        self.assertIn("1 entries, 0 problems", out)

    def test_check_fails_on_expired_and_issue_less_entries(self):
        code, out = self.run_cli([entry(added="2026-10-15", expires="2026-10-20"),
                                  entry(story="launch.cold", issue=None)], "--check")
        self.assertEqual(code, 1)
        self.assertIn("FAIL entries[0] terminal.key-frame.light @ apple-m4-pro/24gb/120hz: expired on 2026-10-20", out)
        self.assertIn("FAIL entries[1] launch.cold @ apple-m4-pro/24gb/120hz: missing issue", out)

    def test_check_fails_on_unknown_story_when_stories_dir_exists(self):
        code, out = self.run_cli([entry()], "--check", stories=["launch.cold"])
        self.assertEqual(code, 1)
        self.assertIn("unknown story", out)

    def test_list_without_check_exits_zero_and_json_reports_state(self):
        code, out = self.run_cli([entry(added="2026-10-15", expires="2026-10-20")])
        self.assertEqual(code, 0)
        self.assertIn("expired", out)
        code, out = self.run_cli([entry()], "--json", "--now", "2026-10-31T00:00:00+00:00")
        report = json.loads(out)
        self.assertEqual(report["entries"][0]["state"], "expired")
        self.assertEqual(report["problems"][0]["index"], 0)

    def test_unreadable_file_exits_two(self):
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            code = expectations.main(["--check", "--file", "/nonexistent/expectations.json"], now=NOW)
        self.assertEqual(code, 2)
        self.assertIn("cannot read", err.getvalue())


if __name__ == "__main__":
    unittest.main()
