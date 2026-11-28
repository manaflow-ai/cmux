#!/usr/bin/env python3
"""nightly-next-one builds the nearest deltas with no key beside the bundle's checks, and signs them after.

appcast-with-nearest-deltas.sh `prebuild` (one-job.sh deltas-start, in the background) fetches the bases and runs
BinaryDelta with no Sparkle key; the keyed run after the stray check takes those bases and deltas when the
prebuild's `done` names this build and DMG, and fetches and builds as before otherwise. Run 44893172356 spent
269 s in the keyed step, on the critical path to the feed (2026-11-21). The tools are stubs that log their calls.
"""
from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/nightly-steps/appcast-with-nearest-deltas.sh"

FETCH = """#!/usr/bin/env python3
import os, sys
if "--save" in sys.argv:
    open(os.environ["LOG"], "a").write("save\\n")
    sys.exit(0)
out = sys.argv[sys.argv.index("--out") + 1]
open(os.environ["LOG"], "a").write("fetch\\n")
open(os.environ["LOG"] + ".args", "a").write(" ".join(sys.argv[1:]) + "\\n")
for build in ("300", "200"):
    open(os.path.join(out, f"cmux-nightly-next-macos-arm64-{build}.dmg"), "w").write(build)
"""
SPARKLE = """#!/usr/bin/env bash
set -euo pipefail
echo "sparkle prebuild_only=${SPARKLE_PREBUILD_ONLY_DIR:-} key=${SPARKLE_PRIVATE_KEY:+yes} prebuilt=${SPARKLE_PREBUILT_DELTAS_DIR:-} previous=${SPARKLE_PREVIOUS_ARCHIVES_DIR:-}" >> "$LOG"
if [ -n "${SPARKLE_PREBUILD_ONLY_DIR:-}" ]; then
  for base in "$SPARKLE_PREVIOUS_ARCHIVES_DIR"/*.dmg; do b="${base##*-}"; echo delta > "$SPARKLE_PREBUILD_ONLY_DIR/x-${b%.dmg}.delta"; done
  exit 0
fi
[ -n "${SPARKLE_PRIVATE_KEY:-}" ]
echo '<rss><item>sparkle:deltas</item></rss>' > "$3"
for base in "${SPARKLE_PREVIOUS_ARCHIVES_DIR:-/nonexistent}"/*.dmg; do
  [ -f "$base" ] || continue
  b="${base##*-}"; echo delta > "${SPARKLE_DELTA_NAME_PREFIX}${NIGHTLY_BUILD}-${b%.dmg}.delta"
done
"""


class DeltasBesideChecksTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp())
        ci = self.tmp / "scripts/ci"
        (ci / "nightly-steps").mkdir(parents=True)
        shutil.copy(SCRIPT, ci / "nightly-steps" / SCRIPT.name)
        files = {
            ci / "nightly_next_previous_dmgs.py": FETCH,
            ci / "drop-previous-nightlies-with-other-sparkle-key.sh": "#!/usr/bin/env bash\necho drop >> \"$LOG\"\n",
            # `check` (does the live item list a delta?) answers CHECK_EXIT, no by default; the rest succeed.
            ci / "nightly_next_delta_check.py": "#!/usr/bin/env python3\nimport os, sys\n"
            "sys.exit(int(os.environ.get('CHECK_EXIT', '1')) if sys.argv[1] == 'check' else 0)\n",
            ci / "nightly-sparkle-key.sh": "#!/usr/bin/env bash\necho THE-KEY\n",
            self.tmp / "scripts/sparkle_generate_appcast.sh": SPARKLE,
        }
        for path, text in files.items():
            path.write_text(text)
            path.chmod(0o755)
        (self.tmp / "cmux-nightly-next-macos-arm64-400.dmg").write_text("the new build")
        self.log = self.tmp / "log"
        self.env = {
            "PATH": os.environ["PATH"], "HOME": str(self.tmp), "LOG": str(self.log), "RUNNER_TEMP": str(self.tmp / "temp"),
            "NIGHTLY_DMG_IMMUTABLE": "cmux-nightly-next-macos-arm64-400.dmg", "NIGHTLY_DMG_RELEASE": "cmux-nightly-next-macos-arm64-400.dmg",
            "NIGHTLY_APPCAST": "appcast-arm64.xml", "CHANNEL_RELEASE_TAG": "nightly-next", "CHANNEL_DMG_PREFIX": "cmux-nightly-next-macos",
            "NIGHTLY_VARIANT": "arm64", "NIGHTLY_BUILD": "400", "NIGHTLY_NEXT_FEED_BASE": "https://example.invalid/nightly-next",
            "NIGHTLY_NEXT_SPARKLE_PUBLIC_KEY": "pub", "GITHUB_STEP_SUMMARY": str(self.tmp / "summary"),
        }
        (self.tmp / "temp").mkdir()

    def tearDown(self) -> None:
        shutil.rmtree(self.tmp, ignore_errors=True)

    def run_script(self, *args: str, **extra: str) -> subprocess.CompletedProcess:
        return subprocess.run(["bash", "scripts/ci/nightly-steps/appcast-with-nearest-deltas.sh", *args], cwd=self.tmp,
                              env={**self.env, **extra}, capture_output=True, text=True, timeout=60)

    def calls(self) -> list[str]:
        return self.log.read_text().splitlines() if self.log.exists() else []

    def test_the_keyed_run_signs_what_the_keyless_prebuild_built(self) -> None:
        pre = self.run_script("prebuild")
        self.assertEqual(pre.returncode, 0, pre.stderr)
        self.assertEqual(self.calls()[:2], ["fetch", "drop"])
        self.assertIn("key= ", self.calls()[2], "the prebuild runs BinaryDelta with no key")
        prebuilt = self.tmp / "temp/nightly-next-prebuilt"
        self.assertEqual(sorted(p.name for p in (prebuilt / "deltas").iterdir()), ["x-200.delta", "x-300.delta"])
        self.assertTrue((prebuilt / "done").read_text().startswith("400 "))
        self.log.unlink()
        keyed = self.run_script()
        self.assertEqual(keyed.returncode, 0, keyed.stderr)
        calls = self.calls()
        self.assertNotIn("fetch", calls, "the keyed run fetches no base again")
        self.assertEqual(len(calls), 1, calls)
        self.assertIn("key=yes", calls[0])
        self.assertIn(f"prebuilt={prebuilt}/deltas", calls[0])
        self.assertIn(f"previous={prebuilt}/bases", calls[0])
        self.assertIn("Taking the bases and deltas the keyless prebuild made for 400", keyed.stdout)

    def test_the_prebuild_and_the_keyed_fetch_use_the_kept_dmgs(self) -> None:
        self.assertEqual(self.run_script("prebuild").returncode, 0)
        cache = f"--cache-dir {self.tmp}/.cmux-nightly-next-dmg-cache "
        self.assertIn(cache, Path(str(self.log) + ".args").read_text())

    def test_the_deltas_after_the_feed_sign_what_the_prebuild_built(self) -> None:
        self.assertEqual(self.run_script("prebuild").returncode, 0)
        self.log.unlink()
        after = self.run_script("after-feed")
        self.assertEqual(after.returncode, 0, after.stderr)
        calls = self.calls()
        self.assertEqual(calls[0], "save", "the final DMG is kept for the next build first")
        self.assertNotIn("fetch", calls, "the post-feed run fetches no base the prebuild has")
        prebuilt = self.tmp / "temp/nightly-next-prebuilt"
        self.assertIn(f"prebuilt={prebuilt}/deltas", calls[1])
        self.assertIn("key=yes", calls[1])

    def test_the_deltas_after_the_feed_build_what_a_stopped_prebuild_left(self) -> None:
        after = self.run_script("after-feed")
        self.assertEqual(after.returncode, 0, after.stderr)
        calls = self.calls()
        self.assertEqual(calls[:3], ["save", "fetch", "drop"])
        self.assertIn("prebuilt= ", calls[3])

    def test_the_feed_waits_for_the_notes_only_when_the_deltas_follow_it(self) -> None:
        tooling = self.tmp / "tooling/ci"
        tooling.mkdir(parents=True)
        (tooling / "background_build.py").write_text(
            "#!/usr/bin/env python3\nimport os, sys\n"
            "open(os.environ['LOG'], 'a').write(sys.argv[1] + ' ' + sys.argv[-1] + '\\n')\n"
            "sys.exit(1 if sys.argv[1] == 'join' and os.environ.get('JOIN_FAILS') == sys.argv[-3] else 0)\n")
        state = self.tmp / "temp/nightly-helper-builds"
        state.mkdir(parents=True)
        for name in ("nearest-deltas", "notes-span"):
            (state / f"{name}.pid").write_text("1")
        script = ROOT / "scripts/ci/nightly-steps/one-job.sh"

        def join(**extra: str) -> list[str]:
            self.log.unlink(missing_ok=True)
            done = subprocess.run(["bash", str(script), "deltas-join"], cwd=self.tmp, capture_output=True, text=True,
                                  env={**self.env, "PUBLISH_TOOLING": str(self.tmp / "tooling"), **extra}, timeout=60)
            self.assertEqual(done.returncode, 0, done.stderr)
            return self.calls()

        self.assertEqual(join(), ["join 900", "join 900"], "the split path waits for both")
        # stop's last argument is the name; join's is the timeout, and the notes are the second name.
        # An unfinished prebuild gets a bounded grace (ask-1f1e9b8ec5), so the feed's first item carries its deltas.
        self.assertEqual(join(NIGHTLY_NEXT_DELTAS_AFTER_FEED="true"), ["join 150", "join 900"])
        self.assertEqual(join(NIGHTLY_NEXT_DELTAS_AFTER_FEED="true", NIGHTLY_NEXT_PREBUILD_GRACE_SECONDS="60"),
                         ["join 60", "join 900"])
        # Past the grace it is stopped and the deltas follow the feed.
        self.assertEqual(join(NIGHTLY_NEXT_DELTAS_AFTER_FEED="true", JOIN_FAILS="nearest-deltas"),
                         ["join 150", "stop nearest-deltas", "join 900"])
        (state / "nearest-deltas.status").write_text("0")
        self.assertEqual(join(NIGHTLY_NEXT_DELTAS_AFTER_FEED="true"), ["join 900", "join 900"],
                         "a prebuild that finished in time is joined, and its work signed before the feed")

    def test_the_feed_item_carries_a_finished_prebuilds_deltas(self) -> None:
        # The release push fires on the feed's first write, so a pushed Mac gets a delta only when that item has one.
        self.assertEqual(self.run_script("prebuild").returncode, 0)
        self.log.unlink()
        keyed = self.run_script(NIGHTLY_NEXT_DELTAS_AFTER_FEED="true")
        self.assertEqual(keyed.returncode, 0, keyed.stderr)
        self.assertNotIn("full-only", keyed.stdout)
        self.assertIn("Taking the bases and deltas the keyless prebuild made for 400", keyed.stdout)
        self.assertIn("sparkle:deltas", (self.tmp / "appcast-arm64.xml").read_text())
        self.assertEqual(sorted(p.name for p in self.tmp.glob("*-400-*.delta")),
                         ["cmux-nightly-next-macos-arm64-400-200.delta", "cmux-nightly-next-macos-arm64-400-300.delta"])

    def test_the_feed_item_is_full_only_without_a_finished_prebuild(self) -> None:
        keyed = self.run_script(NIGHTLY_NEXT_DELTAS_AFTER_FEED="true")
        # (The stub appcast writer always writes sparkle:deltas, which full_only then refuses: its exit is not read.)
        self.assertIn("full-only; its deltas follow the feed", keyed.stdout)
        self.assertNotIn("fetch", self.calls(), "no base is fetched before the feed")

    def test_the_deltas_after_the_feed_add_nothing_to_an_item_that_has_them(self) -> None:
        self.assertEqual(self.run_script("prebuild").returncode, 0)
        self.log.unlink()
        after = self.run_script("after-feed", CHECK_EXIT="0")
        self.assertEqual(after.returncode, 0, after.stderr)
        self.assertIn("went out with its deltas", after.stdout)
        self.assertEqual(self.calls(), ["save"])
        self.assertFalse((self.tmp / "nightly-deltas").exists())

    def test_the_prebuild_refuses_a_key(self) -> None:
        pre = self.run_script("prebuild", SPARKLE_PRIVATE_KEY="leaked")
        self.assertNotEqual(pre.returncode, 0)
        self.assertEqual(self.calls(), [])

    def test_a_prebuild_of_another_build_or_dmg_is_not_taken(self) -> None:
        self.assertEqual(self.run_script("prebuild").returncode, 0)
        (self.tmp / "cmux-nightly-next-macos-arm64-400.dmg").write_text("a different DMG")
        self.log.unlink()
        keyed = self.run_script()
        self.assertEqual(keyed.returncode, 0, keyed.stderr)
        calls = self.calls()
        self.assertEqual(calls[:2], ["fetch", "drop"], "a DMG the prebuild did not diff is fetched and built as before")
        self.assertIn("prebuilt= ", calls[2])

    def test_a_failed_prebuild_leaves_the_keyed_run_as_before(self) -> None:
        fetch = self.tmp / "scripts/ci/nightly_next_previous_dmgs.py"
        fetch.write_text("#!/usr/bin/env python3\nimport sys; sys.exit(3)\n")
        self.assertNotEqual(self.run_script("prebuild").returncode, 0)
        self.assertFalse((self.tmp / "temp/nightly-next-prebuilt/done").exists())
        fetch.write_text(FETCH)
        keyed = self.run_script()
        self.assertEqual(keyed.returncode, 0, keyed.stderr)
        self.assertEqual(self.calls()[:2], ["fetch", "drop"])


if __name__ == "__main__":
    unittest.main()
