#!/usr/bin/env python3
"""Post-publish deltas yield the signer Mac to the nightly-next build loop (scripts/ci/nightly_deltas_yield.py).

2026-11-14: run 43555705551's generate-nightly-deltas held cmux15-glaeda-1 04:33:31-04:43:25Z and
nightly-next-one of run 43557289118 (86dc299b) waited 6.6 min for the signer (queued 04:36:52, started 04:43:27).
Those deltas were never published: 86dc299b reached the feed first and republish dropped them as stale.
"""
from __future__ import annotations

import datetime as dt
import importlib.util
import os
from pathlib import Path
import sys
import tempfile
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/nightly_deltas_yield.py"
spec = importlib.util.spec_from_file_location("nightly_deltas_yield", SCRIPT)
yielder = importlib.util.module_from_spec(spec)
sys.modules["nightly_deltas_yield"] = yielder
spec.loader.exec_module(yielder)

JOBS = yaml.safe_load((ROOT / ".github/workflows/nightly.yml").read_text())["jobs"]
OURS, NEWER = 4355570555101, 4355728911801
NEXT, TIP = "8" * 40, "9" * 40
BUILT = "7" * 40  # the commit the feed's item for OURS names (cmux:sourceCommit)


def feed(build: int, commit: str = "") -> str:
    source = f'<cmux:sourceCommit xmlns:cmux="https://cmux.com/xml-namespaces/cmux">{commit}</cmux:sourceCommit>' if commit else ""
    return ('<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>'
            f'<title>t</title><sparkle:version>{build}</sparkle:version>{source}</item>'
            '<item><sparkle:version>1</sparkle:version></item></channel></rss>')


class Verdict(unittest.TestCase):
    def test_the_feed_s_newest_build_is_its_first_item(self):
        self.assertEqual(yielder.newest_build(feed(NEWER)), NEWER)
        self.assertIsNone(yielder.newest_build("not xml"))

    def test_a_newer_build_in_the_feed_skips_these_deltas(self):
        self.assertEqual(yielder.verdict(OURS, NEWER, NEXT, NEXT), "skip")

    def test_a_tip_past_nightly_next_keeps_the_signer_for_its_build(self):
        """04:31Z: feat-cmux-next had 86dc299b past nightly-next's bbf3c08c; its build took cmux15 at 04:43."""
        self.assertEqual(yielder.verdict(OURS, OURS, NEXT, TIP), "wait")

    def test_the_feed_s_newest_item_names_its_commit(self):
        self.assertEqual(yielder.newest_item(feed(OURS, BUILT)), (OURS, BUILT))
        self.assertEqual(yielder.newest_item(feed(OURS)), (OURS, ""))

    def test_a_promoted_build_still_on_its_way_to_the_signer_keeps_it(self):
        """04:34:04Z: 86dc299b's promotion moved nightly-next to the tip; its nightly-next-one asked for the signer
        at 04:36:52. nightly-next is no longer the commit the feed serves, so a build of it is in flight."""
        self.assertEqual(yielder.verdict(OURS, OURS, TIP, TIP, live_commit=BUILT), "wait")
        self.assertEqual(yielder.verdict(OURS, OURS, BUILT, BUILT, live_commit=BUILT), "quiet")

    def test_nightly_next_at_the_tip_is_quiet(self):
        self.assertEqual(yielder.verdict(OURS, OURS, TIP, TIP), "quiet")

    def test_unreadable_reads_never_skip(self):
        self.assertEqual(yielder.verdict(OURS, None, "", ""), "quiet")


class Main(unittest.TestCase):
    def run_main(self, feeds, refs, max_minutes="40"):
        clock = {"now": dt.datetime(2026, 11, 14, 4, 31, tzinfo=dt.timezone.utc)}
        feeds, refs = iter(feeds), iter(refs)

        def sleep(seconds):
            clock["now"] += dt.timedelta(seconds=seconds)

        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "out"
            os.environ["GITHUB_OUTPUT"] = str(out)
            try:
                yielder.main(["--repo", "o/r", "--build", str(OURS), "--feed", "https://f/appcast-arm64.xml",
                              "--max-minutes", max_minutes],
                             feed=lambda url: next(feeds), ref=lambda repo, branch: next(refs),
                             clock=lambda: clock["now"], sleep=sleep)
            finally:
                os.environ.pop("GITHUB_OUTPUT", None)
            return out.read_text().strip(), (clock["now"] - dt.datetime(2026, 11, 14, 4, 31, tzinfo=dt.timezone.utc))

    def test_it_waits_for_the_next_build_and_skips_once_it_publishes(self):
        answer, waited = self.run_main([feed(OURS), feed(OURS), feed(NEWER)], [NEXT, TIP, NEXT, TIP, TIP, TIP])
        self.assertEqual(answer, "skip=true")
        self.assertEqual(waited, dt.timedelta(seconds=60))

    def test_it_waits_out_a_promoted_build_and_skips_once_it_publishes(self):
        answer, waited = self.run_main([feed(OURS, BUILT)] * 8 + [feed(NEWER, TIP)], [TIP] * 40)
        self.assertEqual(answer, "skip=true")
        self.assertEqual(waited, dt.timedelta(minutes=4))

    def test_a_quiet_loop_signs_after_two_minutes(self):
        answer, waited = self.run_main([feed(OURS)] * 10, [TIP] * 20)
        self.assertEqual(answer, "skip=false")
        self.assertEqual(waited, dt.timedelta(minutes=2))

    def test_the_wait_is_bounded(self):
        answer, waited = self.run_main([feed(OURS)] * 200, [NEXT, TIP] * 200, max_minutes="5")
        self.assertEqual(answer, "skip=false")
        self.assertEqual(waited, dt.timedelta(minutes=5))

    def test_unreadable_reads_sign_as_before(self):
        def boom(*args):
            raise OSError("down")
        with tempfile.TemporaryDirectory() as tmp:
            os.environ["GITHUB_OUTPUT"] = str(Path(tmp) / "out")
            try:
                now = dt.datetime(2026, 11, 14, tzinfo=dt.timezone.utc)
                clock = [now]
                yielder.main(["--repo", "o/r", "--build", str(OURS), "--feed", "u"], feed=boom, ref=boom,
                             clock=lambda: clock[0], sleep=lambda s: clock.__setitem__(0, clock[0] + dt.timedelta(seconds=s)))
                self.assertEqual((Path(tmp) / "out").read_text().strip(), "skip=false")
            finally:
                os.environ.pop("GITHUB_OUTPUT", None)


class Wiring(unittest.TestCase):
    def test_the_deltas_wait_before_asking_for_the_signer_and_skip_when_superseded(self):
        steps = JOBS["build-nightly-deltas"]["steps"]
        wait = [step for step in steps if "nightly_deltas_yield.py" in str(step.get("run", ""))]
        self.assertEqual(len(wait), 1, "build-nightly-deltas (nightly-only minis) waits for the build loop")
        self.assertTrue(wait[0].get("continue-on-error"), "the wait never fails the deltas")
        self.assertIn("nightly-next", str(wait[0].get("if", "")), "only the nightly-next track yields")
        self.assertNotIn("GH_TOKEN", str(wait[0].get("env", {})), "the wait spends no API budget")
        self.assertIn("skip", str(JOBS["build-nightly-deltas"].get("outputs", {})))
        self.assertIn("needs.build-nightly-deltas.outputs.skip != 'true'", str(JOBS["generate-nightly-deltas"]["if"]))
        self.assertIn("needs.generate-nightly-deltas.result != 'skipped'", str(JOBS["republish-nightly-deltas"]["if"]))


if __name__ == "__main__":
    unittest.main()
