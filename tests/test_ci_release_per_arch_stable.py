#!/usr/bin/env python3
"""Stable releases ship thin arm64 and x86_64 builds next to the universal one.

Pins the release.yml shape that keeps existing installs and download links safe:
- the universal cmux-macos.dmg is still built and published, so the website and
  Homebrew links that point at it keep working;
- both thin variants are cut from the stripped universal app before signing and
  are signed, smoke tested, notarized and stapled like nightly's;
- each DMG gets its own signed appcast, and the legacy appcast.xml is composed
  from all three (scripts/ci/compose_stable_appcast.py) so existing installs
  move onto their architecture in one update;
- the per-architecture feeds are published before the legacy feed, on GitHub
  and on R2, so the legacy feed never sends an install to a missing feed.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = (ROOT / ".github/workflows/release.yml").read_text(encoding="utf-8")
ARCHS = ("arm64", "x86_64")


def steps() -> dict[str, str]:
    parts = re.split(r"^      - name: ", WORKFLOW, flags=re.M)
    result = {}
    for part in parts[1:]:
        name, _, body = part.partition("\n")
        result[name.strip()] = body
    return result


def order(name: str) -> int:
    names = list(steps())
    if name not in names:
        raise AssertionError(f"release.yml has no step named {name!r}")
    return names.index(name)


class ReleasePerArchStableTest(unittest.TestCase):
    def test_thin_variants_are_cut_after_strip_and_before_signing(self):
        cut = steps().get("Cut thin stable variants", "")
        self.assertIn("for arch in arm64 x86_64", cut)
        self.assertIn('./scripts/thin-app-bundle.sh "variants/$arch/cmux.app" "$arch"', cut)
        self.assertIn("Mach-O universal", cut, "no fat Mach-O may survive thinning")
        self.assertLess(order("Strip release binaries"), order("Cut thin stable variants"))
        self.assertLess(order("Verify Cloud tunnel engine before signing"), order("Cut thin stable variants"))
        self.assertLess(order("Cut thin stable variants"), order("Start thin Computer Use helper notarizations"))
        self.assertLess(order("Start thin Computer Use helper notarizations"), order("Codesign app"))

    def test_every_variant_is_signed_and_verified_like_the_universal_app(self):
        all_steps = steps()
        for name in (
            "Codesign app",
            "Verify bundled Mach-O load commands",
            "Verify signed app SSH daemon contract",
            "Smoke launch signed app before notarization",
            "Smoke bundled CLI against the signed app",
            "Gate distribution with syspolicy_check",
        ):
            body = all_steps[name]
            self.assertIn("variants/arm64/cmux.app", body, name)
            self.assertIn("variants/x86_64/cmux.app", body, name)
        self.assertIn("all-except-computer-use", all_steps["Codesign app"])
        start = all_steps["Start thin Computer Use helper notarizations"]
        self.assertIn('cmux-computer-use-notarization-$arch.state', start)
        self.assertIn("--start", start)

    def test_thin_dmgs_are_notarized_and_stapled_with_stable_entitlements(self):
        body = steps().get("Notarize thin stable DMGs", "")
        self.assertIn("CMUX_CHANNEL: stable", body)
        self.assertIn("./scripts/ci/notarize-nightly-dmg.sh", body)
        self.assertIn('"variants/$arch/cmux.app"', body)
        self.assertIn('"cmux-macos-$arch.dmg"', body)
        self.assertIn('cmux-computer-use-notarization-$arch.state', body)
        self.assertLess(order("Notarize app"), order("Notarize thin stable DMGs"))
        self.assertLess(order("Notarize thin stable DMGs"), order("Generate Sparkle appcast"))

    def test_appcasts_are_generated_per_dmg_and_composed(self):
        body = steps()["Generate Sparkle appcast"]
        self.assertIn('sparkle_generate_appcast.sh cmux-macos.dmg "$GITHUB_REF_NAME" appcast-universal.xml', body)
        for arch in ARCHS:
            self.assertIn(
                f'sparkle_generate_appcast.sh cmux-macos-{arch}.dmg "$GITHUB_REF_NAME" appcast-{arch}.xml', body
            )
        self.assertIn(
            "compose_stable_appcast.py --universal appcast-universal.xml"
            " --arm64 appcast-arm64.xml --x86_64 appcast-x86_64.xml --out appcast.xml",
            body,
        )
        for feed in ("appcast.xml", "appcast-arm64.xml", "appcast-x86_64.xml"):
            self.assertIn(f"test -s {feed}", body)
            self.assertIn(f"grep -q 'sparkle:edSignature' {feed}", body)

    def test_universal_dmg_and_legacy_feed_url_stay_for_existing_links(self):
        self.assertIn('DMG_RELEASE="cmux-macos.dmg"', WORKFLOW)
        # Thin builds resolve their own feed at runtime from this legacy URL.
        self.assertIn(
            "SUFeedURL string https://github.com/manaflow-ai/cmux/releases/latest/download/appcast.xml", WORKFLOW
        )

    def test_dry_run_artifact_carries_every_dmg_and_feed(self):
        body = steps()["Upload build artifacts (dry-run)"]
        for name in (
            "cmux-macos.dmg",
            "cmux-macos-arm64.dmg",
            "cmux-macos-x86_64.dmg",
            "appcast.xml",
            "appcast-arm64.xml",
            "appcast-x86_64.xml",
        ):
            self.assertRegex(body, rf"(?m)^\s+{re.escape(name)}$")

    def test_github_publish_uploads_every_dmg_then_the_legacy_feed_last(self):
        body = steps()["Upload release asset"]
        for dmg in ("cmux-macos.dmg", "cmux-macos-arm64.dmg", "cmux-macos-x86_64.dmg"):
            self.assertIn(f"--immutable {dmg}", body)
        feeds = re.findall(r"--feed (\S+)", body)
        self.assertEqual(feeds, ["appcast-arm64.xml", "appcast-x86_64.xml", "appcast.xml"])

    def test_r2_publishes_per_arch_feeds_before_the_legacy_feed(self):
        body = steps()["Upload release appcast to R2"]
        keys = re.findall(r"--key (stable/\S+)", body)
        self.assertEqual(keys, ["stable/appcast-$arch.xml", "stable/appcast.xml"])
        self.assertIn("for arch in arm64 x86_64", body)

    def test_only_the_highest_release_becomes_latest(self):
        # Thin installs read releases/latest/download/appcast-<arch>.xml. A backport
        # published after a newer release must not become latest, or those installs
        # would read an older release (one from before thin builds has no such feed).
        decide = steps().get("Decide whether this release is latest", "")
        self.assertIn("--exclude-drafts --exclude-pre-releases", decide)
        self.assertIn("sort -V", decide)
        self.assertIn("make_latest=", decide)
        publish = steps()["Publish verified release"]
        self.assertIn("make_latest: ${{ steps.latest_release.outputs.make_latest }}", publish)
        self.assertLess(order("Decide whether this release is latest"), order("Publish verified release"))

    def test_local_release_publishes_per_arch_feeds(self):
        # scripts/build-sign-upload.sh builds only the universal DMG. It still has
        # to publish both per-arch feeds, holding the universal item, so a thin
        # install updates instead of finding no feed.
        script = (ROOT / "scripts/build-sign-upload.sh").read_text(encoding="utf-8")
        for arch in ARCHS:
            self.assertIn(f"cp appcast.xml appcast-{arch}.xml", script)
        self.assertRegex(script, r"gh release create .*appcast\.xml appcast-arm64\.xml appcast-x86_64\.xml")
        self.assertRegex(script, r"gh release upload \"\$TAG\" cmux-macos\.dmg appcast\.xml appcast-arm64\.xml appcast-x86_64\.xml")


if __name__ == "__main__":
    unittest.main()
