#!/usr/bin/env python3
"""The Linux appcast writer, scripts/ci/tip_appcast_linux.py, signs as Sparkle's
sign_update does."""

from __future__ import annotations

import base64
import importlib.util
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/tip_appcast_linux.py"

spec = importlib.util.spec_from_file_location("tip_appcast_linux", SCRIPT)
writer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(writer)
sys.path.insert(0, str(ROOT / "scripts/ci"))
import appcast_minimum_system_version as floor  # noqa: E402


# RFC 8032 section 7.1, test 1: the empty message.
RFC_SEED = bytes.fromhex("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60")
RFC_PUBLIC = bytes.fromhex("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a")
RFC_SIGNATURE = bytes.fromhex(
    "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b")


class Writer(unittest.TestCase):
    def test_rfc8032_vector(self) -> None:
        with tempfile.NamedTemporaryFile() as empty:
            self.assertEqual(writer.sign_file(RFC_SEED, empty.name), (RFC_SIGNATURE, RFC_PUBLIC))
            # The old 96-byte Sparkle key: the expanded key, then the public key.
            import hashlib
            h = bytearray(hashlib.sha512(RFC_SEED).digest())
            h[0] &= 248
            h[31] &= 63
            h[31] |= 64
            self.assertEqual(writer.sign_file(bytes(h) + RFC_PUBLIC, empty.name)[0], RFC_SIGNATURE)

    @unittest.skipUnless(shutil.which("openssl"), "no openssl")
    def test_openssl_verifies_a_file_signature(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "a.dmg")
            with open(path, "wb") as out:
                out.write(os.urandom(3 << 20))
            signature, public = writer.sign_file(RFC_SEED, path)
            self.assertTrue(writer.openssl_verify(public, signature, path))
            self.assertFalse(writer.openssl_verify(public, bytes(64), path))

    def test_the_item_matches_the_published_legacy_feed(self) -> None:
        # Build 4038033920301 of the old feed, as generate_appcast and
        # sparkle_generate_appcast.sh wrote it on a Mac (description and
        # pubDate aside).
        name = "cmux-nightly-next-macos-nightlyid-arm64-4038033920301.dmg"
        signature = "lnIDiywnOd1RqYIV0VyQDx9N+LJkKFONBAVUYRBgocElMo4guMBDuff+k05+5fVgjHhhIG65aUA8Qbmvk0vlDQ=="
        plist = {"CFBundleVersion": "4038033920301", "CFBundleShortVersionString": "1.0.0-nightly.4038033920301",
                 "LSMinimumSystemVersion": "14.0", "CFBundleName": "cmux NIGHTLY"}
        xml = writer.appcast("cmux NIGHTLY", plist, "https://github.com/manaflow-ai/cmux/releases/download/nightly-next/" + name,
                             237580114, signature, "https://github.com/manaflow-ai/cmux/releases/tag/nightly-next",
                             "Mon, 26 Oct 2026 19:38:02 +0000")
        xml = floor.enforce(xml, name, "14.0")
        xml = re.sub(r"<item>", "<item>\n            <sparkle:channel>cmux-next</sparkle:channel>", xml)
        published = """<?xml version="1.0" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
    <channel>
        <title>cmux NIGHTLY</title>
        <item>
            <sparkle:channel>cmux-next</sparkle:channel>
            <title>1.0.0-nightly.4038033920301</title>
            <pubDate>Mon, 26 Oct 2026 19:38:02 +0000</pubDate>
            <sparkle:fullReleaseNotesLink>https://github.com/manaflow-ai/cmux/releases/tag/nightly-next</sparkle:fullReleaseNotesLink>
            <sparkle:version>4038033920301</sparkle:version>
            <sparkle:shortVersionString>1.0.0-nightly.4038033920301</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
            <enclosure url="https://github.com/manaflow-ai/cmux/releases/download/nightly-next/cmux-nightly-next-macos-nightlyid-arm64-4038033920301.dmg" length="237580114" type="application/octet-stream" sparkle:edSignature="lnIDiywnOd1RqYIV0VyQDx9N+LJkKFONBAVUYRBgocElMo4guMBDuff+k05+5fVgjHhhIG65aUA8Qbmvk0vlDQ=="/>
        </item>
    </channel>
</rss>
"""
        self.assertEqual(xml, published)

    def test_refuses_an_app_that_trusts_another_key(self) -> None:
        import plistlib
        import zipfile
        with tempfile.TemporaryDirectory() as tmp:
            dmg = os.path.join(tmp, "x.dmg")
            Path(dmg).write_bytes(b"dmg")
            archive = os.path.join(tmp, "plist.zip")
            with zipfile.ZipFile(archive, "w") as zf:
                zf.writestr("cmux NIGHTLY.app/Contents/Info.plist", plistlib.dumps(
                    {"CFBundleVersion": "7", "SUPublicEDKey": base64.b64encode(bytes(32)).decode()}))
            env = dict(os.environ, KEY=base64.b64encode(RFC_SEED).decode())
            done = subprocess.run([sys.executable, "-I", str(SCRIPT), "KEY", dmg, archive, "cmux NIGHTLY", "u/", "n", "7",
                                   os.path.join(tmp, "out.xml")], env=env, capture_output=True, text=True)
            self.assertNotEqual(done.returncode, 0)
            self.assertIn("the app trusts", done.stderr)
            self.assertFalse(os.path.exists(os.path.join(tmp, "out.xml")))


if __name__ == "__main__":
    unittest.main()
