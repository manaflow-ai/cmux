"""A dev build tag names one build space: every build entry point refuses a tag that is not its own slug.

A tag is the cloud build space `dev:<slug>` of its Mac and iPhone builds (X-Cmux-Build-Space) and the
`<tag>` of their app names. The slug lowercases and turns every run outside [a-z0-9] into one `-`, so
`foo_bar`, `foo.bar`, `Foo-Bar` and `foo--bar` all became `dev:foo-bar`: two tasks with "different" tags
shared one space, and each one's phone paired with the other's Mac (iPhone route audit, 2026-11-24, hole 4).
The shared validator (scripts/lib/mobile-attach.sh `cmux_attach_validate_dev_tag`) now accepts only the
canonical spelling, and refuses the tags that name an app of their own: `default` (the stable instance),
`dev` (cmux Dev, dev.cmux.mobile.dev, which try.sh's fallback for an older commit builds in dev:dev),
`demo` and `prod` (demo-build.sh's Demo and Production installs).

Also demo-build.sh (hole 2): a Demo build is in the default space on purpose (it shows the person's real
data and pairs with their NIGHTLY Mac), so `--tag X` must not name it like tag X's dev build
(`dev.cmux.mobile.X`, the Mac reads the bundle's suffix as the phone's tag). It is `dev.cmux.mobile.demo.X`.

Run: python3 tests/test_dev_tag_canonical.py
"""
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
ATTACH = ROOT / "scripts/lib/mobile-attach.sh"
RELOAD = ROOT / "scripts/reload.sh"
REVIEW = ROOT / "cmux-next-ios/scripts/review.sh"
TRY = ROOT / "cmux-next-ios/scripts/try.sh"
DEMO = ROOT / "cmux-next-ios/scripts/demo-build.sh"
SIM = ROOT / "scripts/ci/cmux-next-ios-sim.sh"
PHONE_PREFIX = "dev.cmux.mobile."
# The backends' pattern for a space's slug (cmux-next-ios/backend/src/index.ts, backend/apps/api/src/build-space.ts).
BACKEND_SLUG = re.compile(r"^[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?$")
BASH = "/bin/bash" if os.path.exists("/bin/bash") else "bash"


def run(args, env=None, timeout=60, cwd=ROOT):
    with tempfile.TemporaryDirectory() as home:
        return subprocess.run(args, capture_output=True, text=True, timeout=timeout, cwd=cwd,
                              env=dict(os.environ, HOME=home, **(env or {})))


def validate(tag):
    return run([BASH, "-c", 'source "$1"; cmux_attach_validate_dev_tag "$2"', "t", str(ATTACH), tag])


def slug(tag):
    return run([BASH, "-c", 'source "$1"; cmux_attach__slug_raw "$2"', "t", str(ATTACH), tag]).stdout


class ValidatorTests(unittest.TestCase):
    SPELLINGS = ["foo-bar", "foo_bar", "foo.bar", "Foo-Bar", "FOO_BAR", "foo--bar", "-foo-bar", "foo-bar-",
                 "foo bar", " foo-bar"]

    def test_only_the_canonical_spelling_of_a_space_passes(self):
        passed = [t for t in self.SPELLINGS if validate(t).returncode == 0]
        self.assertEqual(passed, ["foo-bar"])
        # They are all one space: that is what made them collide.
        self.assertEqual({slug(t) for t in self.SPELLINGS}, {"foo-bar"})

    def test_a_non_canonical_tag_is_refused_with_its_canonical_form(self):
        for tag, canonical in (("foo_bar", "foo-bar"), ("Foo-Bar", "foo-bar"), ("A..B__C", "a-b-c"),
                               ("de fault", "de-fault"), ("x--1", "x-1")):
            with self.subTest(tag=tag):
                r = validate(tag)
                self.assertNotEqual(r.returncode, 0)
                self.assertIn("is not a canonical tag", r.stderr)
                self.assertIn(f"--tag {canonical}", r.stderr)

    def test_canonical_tags_pass(self):
        for tag in ("a", "x-1", "cnx-test-v1", "default-2", "future-one", "dev-2", "demo-x", "prod1", "z" * 64):
            with self.subTest(tag=tag):
                r = validate(tag)
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertRegex(tag, BACKEND_SLUG)

    def test_too_long_and_letterless_tags_are_refused(self):
        self.assertIn("at most 64", validate("z" * 65).stderr)
        self.assertIn("no letters or digits", validate("---").stderr)

    def test_tags_that_name_another_app_are_reserved(self):
        for tag, why in (("default", "reserved for the stable app instance"), ("DEFAULT", "reserved for the stable app instance"),
                         ("dev", "cmux Dev"), ("Dev", "cmux Dev"), ("demo", "Demo"), ("prod", "Production")):
            with self.subTest(tag=tag):
                r = validate(tag)
                self.assertNotEqual(r.returncode, 0)
                self.assertIn(why, r.stderr)

    def test_reserved_list_is_what_try_sh_and_demo_build_sh_use(self):
        r = run([BASH, "-c", 'source "$1"; for t in default dev demo prod x; do cmux_attach_tag_reserved "$t" && echo "$t"; done; true',
                 "t", str(ATTACH)])
        self.assertEqual(r.stdout.split(), ["default", "dev", "demo", "prod"])


class EntryPointTests(unittest.TestCase):
    """The Mac build (reload.sh, which the fleet's cmux-ci build runs), the hand-off and the simulator step refuse first."""

    def test_reload_sh_refuses_a_non_canonical_tag_before_doing_work(self):
        r = run([BASH, str(RELOAD), "--tag", "Foo_Bar"], timeout=120)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("is not a canonical tag", r.stderr)
        self.assertNotRegex(r.stdout + r.stderr, re.compile(r"xcodebuild|launching|building", re.I))

    def test_review_sh_refuses_a_non_canonical_or_reserved_tag(self):
        for tag, why in (("Foo_Bar", "is not a canonical tag"), ("foo.bar", "is not a canonical tag"), ("dev", "cmux Dev")):
            with self.subTest(tag=tag):
                r = run([BASH, str(REVIEW), "--tag", tag])
                self.assertEqual(r.returncode, 2, r.stderr)
                self.assertIn(why, r.stderr)

    def test_simulator_handoff_refuses_a_tag_whose_space_is_another_spelling(self):
        for tag, why in (("foo--bar", "is not a canonical tag"), ("demo", "Demo"), ("prod", "Production"), ("dev", "cmux Dev")):
            with self.subTest(tag=tag):
                r = run([BASH, str(SIM), "handoff", f"tag={tag}"], env={"CMUX_CI_STEP_KEY": "test"}, timeout=30)
                self.assertEqual(r.returncode, 2, r.stderr)
                self.assertIn(why, r.stderr)

    def test_simulator_handoff_uses_the_shared_validator(self):
        text = SIM.read_text()
        block = text[text.index('if [[ "$mode" == handoff ]]; then\n  [[ $# -eq 2'):]
        block = block[:block.index("\nfi\n")]
        self.assertIn('cmux_attach_validate_dev_tag "$handoff_tag"', block)


class TryFallbackTests(unittest.TestCase):
    """try.sh builds an older commit through its handoff mode with tag dev: no real tagged build may share dev:dev."""

    def fleet(self, extra=""):
        with tempfile.TemporaryDirectory() as temp:
            ci = Path(temp) / "cmux-ci"
            ci.write_text('#!/bin/sh\n[ "$1" = run ] && echo "$@" > "%s/args"\nexit 0\n' % temp)
            ci.chmod(0o755)
            r = run([BASH, "-c", f'source "{TRY}"; {extra} SHA={"a" * 40} STATE="{temp}" TRY_LABEL=x CMUX_CI="{ci}"; '
                     'try_fleet handoff; echo rc=$?'], env={"CMUX_CI": str(ci)})
            return r, (Path(temp) / "args").exists()

    def test_the_fallback_runs_while_dev_is_reserved(self):
        r, sent = self.fleet()
        self.assertIn("rc=0", r.stdout, r.stderr)
        self.assertTrue(sent)

    def test_the_fallback_refuses_if_dev_were_a_usable_tag(self):
        r, sent = self.fleet("cmux_attach_tag_reserved() { return 1; };")
        self.assertNotIn("rc=0", r.stdout)
        self.assertIn("dev:dev", r.stderr)
        self.assertFalse(sent)


class DemoBuildNamingTests(unittest.TestCase):
    def identity(self, *args):
        r = run([BASH, str(DEMO), *args, "--print-identity"])
        self.assertEqual(r.returncode, 0, r.stderr)
        return dict(line.split("=", 1) for line in r.stdout.splitlines() if "=" in line)

    def test_default_and_production_installs_keep_their_names(self):
        self.assertEqual(self.identity(), {"bundle_id": "dev.cmux.mobile.demo", "display_name": "cmux mobile",
                                           "build_space": "none"})
        self.assertEqual(self.identity("--config", "Production")["bundle_id"], "dev.cmux.mobile.prod")

    def test_a_tagged_demo_build_is_never_named_like_that_tags_dev_build(self):
        for tag in ("r1a2b3c4d", "cnx-test-v1", "x"):
            with self.subTest(tag=tag):
                got = self.identity("--tag", tag)
                self.assertEqual(got["bundle_id"], f"dev.cmux.mobile.demo.{tag}")
                self.assertEqual(got["display_name"], f"demo {tag}")
                self.assertEqual(got["build_space"], "none")
                # The Mac reads the bundle's suffix as the phone's tag (IPhoneDevAutoApprove.phoneTag): a Demo
                # build's suffix has a dot, which no tag has, so no tagged Mac takes it for its own phone.
                suffix = got["bundle_id"][len(PHONE_PREFIX):]
                self.assertNotEqual(validate(suffix).returncode, 0)
                self.assertNotEqual(got["display_name"], f"cmux {tag}")

    def test_a_demo_tag_is_canonical(self):
        for tag in ("Foo_Bar", "foo.bar", "foo--bar"):
            with self.subTest(tag=tag):
                r = run([BASH, str(DEMO), "--tag", tag, "--print-identity"])
                self.assertEqual(r.returncode, 2)
                self.assertIn("lowercase letters, digits", r.stderr)

    def test_demo_builds_send_no_build_space(self):
        text = DEMO.read_text()
        self.assertNotIn("CMUX_MOBILE_DEV_TAG", text.split("--- iOS builds ---", 1)[1])


if __name__ == "__main__":
    unittest.main()
