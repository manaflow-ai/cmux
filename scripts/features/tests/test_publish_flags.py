#!/usr/bin/env python3
"""publish-flags.py with a fake fetch and a fake uploader: serial bump, refused names, the nightly's
assertion, the signature (against the destination key, the content-signing key the app and the daemon
trust, and the signed vector the Swift test checks), dry run and the write order.

  python3 -m unittest scripts/features/tests/test_publish_flags.py
"""
from __future__ import annotations

import base64
import datetime
import hashlib
import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "publish-flags.py"
REPO = SCRIPT.parent.parent.parent
NOW = datetime.datetime(2026, 10, 26, tzinfo=datetime.timezone.utc)
KINDS = {"perfLabKillProbe": "killSwitch", "cefTimerSlack": "perfPath", "energySaver": "labs"}
TEST_ENV = {"CMUX_PERF_LAB_FLAGS_BASE": "https://lab.example/perf-lab-test",
            "CMUX_PERF_LAB_R2_ENDPOINT": "https://r2.example", "CMUX_PERF_LAB_R2_BUCKET": "cmux-perf-lab"}
# The document FeatureRemoteTests.theCommittedTestKeySignsForTheBenchKey signs with the committed test seed,
# and its Ed25519 signature (deterministic, RFC 8032): Swift's CryptoKit, the daemon's ring and openssl
# all produce and accept exactly these bytes.
VECTOR_DOCUMENT = '{"version": 1, "default": {"Features": {"killThing": "off"}, "FeaturesSerial": 1}}'
VECTOR_SIGNATURE = "awi7tNpxH9yQKKOTIR0rnhqC9NTbcMynkyHu64U9D1th0EHUG131NFw6LDGVN7gA+hhBDgJJA3xWZUMOv5eDBw=="


def load_script():
    spec = importlib.util.spec_from_file_location("cmux_publish_flags_for_test", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module  # dataclasses look the module up by name
    spec.loader.exec_module(module)
    return module


pf = load_script()


class FakeUploader:
    def __init__(self, refuse: set[str] = frozenset()):
        self.puts: list[dict] = []
        self.refuse = refuse

    def put(self, path, key, *, cache_control, write_once=False, replace_sha256=None):
        if key in self.refuse:
            raise pf.PublishError(f"{key} exists with other bytes")
        self.puts.append({"key": key, "data": Path(path).read_bytes(), "cache_control": cache_control,
                          "write_once": write_once, "replace_sha256": replace_sha256})

    def body(self, key):
        return next(put["data"] for put in self.puts if put["key"] == key)


def args(*argv):
    return pf.parse_args(list(argv))


def openssl_key_pair(folder: Path) -> tuple[Path, str]:
    """A fresh Ed25519 PEM key (the production key's stand-in) and its raw base64 public key."""
    pem = folder / "content-signing.pem"
    subprocess.run(["openssl", "genpkey", "-algorithm", "ed25519", "-out", str(pem)], check=True, capture_output=True)
    der = subprocess.run(["openssl", "pkey", "-in", str(pem), "-pubout", "-outform", "DER"],
                         check=True, capture_output=True).stdout
    return pem, base64.b64encode(der[-32:]).decode()


class PublishCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.folder = Path(self.tmp.name)
        self.checkout = self.folder / "flags.json"
        self.write_checkout({"version": 1, "default": {"FeaturesSerial": 1}, "cohorts": {}})
        self.published: dict[str, bytes] = {}
        self.output: list[str] = []

    def tearDown(self):
        self.tmp.cleanup()

    def write_checkout(self, document):
        self.checkout.write_text(json.dumps(document), encoding="utf-8")

    def fetch(self, url):
        return self.published.get(url)

    def publish_signed(self, document, base="https://lab.example/perf-lab-test"):
        """Serves `document` at the destination, signed with the perf lab's test key."""
        folder = Path(tempfile.mkdtemp(dir=self.folder))
        path = folder / "flags.json"
        path.write_bytes(pf.render(document))
        pf.sign([path], pf.write_test_key_pem(folder))
        self.published[f"{base}/notes/flags.json"] = path.read_bytes()
        self.published[f"{base}/notes/flags.json.sig"] = (folder / "flags.json.sig").read_bytes()

    def run_publish(self, *argv, env=None, uploader=None):
        uploader = uploader if uploader is not None else FakeUploader()
        code = pf.publish(args(*argv), env=env if env is not None else TEST_ENV, fetch=self.fetch,
                          uploader=uploader, out=self.output.append, now=NOW, checkout_path=self.checkout, kinds=KINDS)
        return code, uploader


class SerialAndContentTests(PublishCase):
    def test_serial_is_one_above_the_published_and_checkout_serials(self):
        self.write_checkout({"version": 1, "default": {"FeaturesSerial": 10}, "cohorts": {}})
        self.publish_signed({"version": 1, "default": {"FeaturesSerial": 9},
                             "cohorts": {"wave-1": {"FeaturesSerial": 11}}})
        code, uploader = self.run_publish("--cohort", "default", "--off", "perfLabKillProbe", "--reason", "crash spike",
                                          "--test-key")
        self.assertEqual(code, 0)
        document = json.loads(uploader.body("perf-lab-test/notes/flags.json"))
        self.assertEqual(document["default"]["FeaturesSerial"], 12)
        self.assertEqual(document["cohorts"]["wave-1"]["FeaturesSerial"], 12)
        self.assertEqual(document["default"]["Features"], {"perfLabKillProbe": "off"})
        self.assertTrue(pf.nightly_assertion(document))
        self.assertEqual(document["version"], 1)

    def test_with_nothing_published_it_starts_from_the_checkout(self):
        self.write_checkout({"version": 1, "default": {"FeaturesSerial": 4, "DisabledFeatures": ["cloud-vm"]},
                             "cohorts": {}})
        code, uploader = self.run_publish("--cohort", "default", "--off", "cefTimerSlack", "--on", "perfLabKillProbe",
                                          "--reason", "r", "--test-key")
        self.assertEqual(code, 0)
        document = json.loads(uploader.body("perf-lab-test/notes/flags.json"))
        self.assertEqual(document["default"], {"FeaturesSerial": 5, "DisabledFeatures": ["cloud-vm"],
                                               "Features": {"cefTimerSlack": "off", "perfLabKillProbe": "on"}})
        # Nothing to replace, so the first flags.json is written once.
        put = next(p for p in uploader.puts if p["key"] == "perf-lab-test/notes/flags.json")
        self.assertTrue(put["write_once"])

    def test_a_published_document_from_before_the_serial_gets_one(self):
        self.publish_signed({"version": 1, "default": {}, "cohorts": {}})
        code, uploader = self.run_publish("--cohort", "default", "--off", "perfLabKillProbe", "--reason", "r",
                                          "--test-key")
        self.assertEqual(code, 0)
        document = json.loads(uploader.body("perf-lab-test/notes/flags.json"))
        self.assertEqual(document["default"]["FeaturesSerial"], 2)
        self.assertTrue(pf.nightly_assertion(document))

    def test_a_published_document_of_another_version_is_refused(self):
        self.publish_signed({"version": 2, "default": {"FeaturesSerial": 2}, "cohorts": {}})
        with self.assertRaisesRegex(pf.PublishError, "not a version 1"):
            self.run_publish("--cohort", "default", "--off", "perfLabKillProbe", "--reason", "r", "--test-key")

    def test_a_cohort_starts_from_the_default_features_and_says_so(self):
        self.publish_signed({"version": 1, "default": {"FeaturesSerial": 2, "Features": {"cefTimerSlack": "off"}},
                             "cohorts": {}})
        code, uploader = self.run_publish("--cohort", "wave-1", "--off", "perfLabKillProbe", "--reason", "r",
                                          "--test-key")
        self.assertEqual(code, 0)
        document = json.loads(uploader.body("perf-lab-test/notes/flags.json"))
        self.assertEqual(document["cohorts"]["wave-1"]["Features"], {"cefTimerSlack": "off", "perfLabKillProbe": "off"})
        self.assertEqual(document["default"]["Features"], {"cefTimerSlack": "off"})
        self.assertTrue(any("now has its own Features" in line for line in self.output))

    def test_a_publish_that_changes_nothing_is_refused(self):
        self.publish_signed({"version": 1, "default": {"FeaturesSerial": 2, "Features": {"perfLabKillProbe": "off"}},
                             "cohorts": {}})
        with self.assertRaisesRegex(pf.PublishError, "already has these features"):
            self.run_publish("--cohort", "default", "--off", "perfLabKillProbe", "--reason", "r", "--test-key")

    def test_an_expired_document_is_refused(self):
        self.publish_signed({"version": 1, "default": {"FeaturesSerial": 2, "FeaturesExpiresAt": "2026-10-01T00:00:00Z"},
                             "cohorts": {}})
        with self.assertRaisesRegex(pf.PublishError, "has passed"):
            self.run_publish("--cohort", "default", "--off", "perfLabKillProbe", "--reason", "r", "--test-key")

    def test_the_history_record_reserves_the_serial_before_flags_json(self):
        self.publish_signed({"version": 1, "default": {"FeaturesSerial": 2}, "cohorts": {}})
        code, uploader = self.run_publish("--cohort", "default", "--off", "perfLabKillProbe", "--reason", "crash spike",
                                          "--test-key")
        self.assertEqual(code, 0)
        keys = [put["key"] for put in uploader.puts]
        self.assertEqual(keys, ["perf-lab-test/notes/history/3.json", "perf-lab-test/notes/history/3.json.sig",
                                "perf-lab-test/notes/flags.json", "perf-lab-test/notes/flags.json.sig"])
        self.assertTrue(uploader.puts[0]["write_once"])
        record = json.loads(uploader.body("perf-lab-test/notes/history/3.json"))
        self.assertEqual((record["serial"], record["reason"], record["off"]), (3, "crash spike", ["perfLabKillProbe"]))
        flags = uploader.puts[2]
        loaded = self.published["https://lab.example/perf-lab-test/notes/flags.json"]
        self.assertEqual(flags["replace_sha256"], hashlib.sha256(loaded).hexdigest())
        self.assertEqual(flags["cache_control"], pf.NO_CACHE)

    def test_a_taken_serial_stops_before_flags_json(self):
        self.publish_signed({"version": 1, "default": {"FeaturesSerial": 2}, "cohorts": {}})
        uploader = FakeUploader(refuse={"perf-lab-test/notes/history/3.json"})
        with self.assertRaises(pf.PublishError):
            self.run_publish("--cohort", "default", "--off", "perfLabKillProbe", "--reason", "r", "--test-key",
                             uploader=uploader)
        self.assertEqual(uploader.puts, [])

    def test_dry_run_prints_the_diff_and_uploads_nothing(self):
        self.publish_signed({"version": 1, "default": {"FeaturesSerial": 2}, "cohorts": {}})
        uploader = FakeUploader()
        code, _ = self.run_publish("--cohort", "default", "--off", "perfLabKillProbe", "--reason", "r", "--test-key",
                                   "--dry-run", uploader=uploader)
        self.assertEqual(code, 0)
        self.assertEqual(uploader.puts, [])
        text = "\n".join(self.output)
        self.assertIn('+    "FeaturesSerial": 3', text)
        self.assertIn('-    "FeaturesSerial": 2', text)
        self.assertIn('"perfLabKillProbe": "off"', text)
        self.assertIn("dry run", text)

    def test_a_test_key_publish_leaves_the_checkout_alone(self):
        before = self.checkout.read_bytes()
        self.run_publish("--cohort", "default", "--off", "perfLabKillProbe", "--reason", "r", "--test-key")
        self.assertEqual(self.checkout.read_bytes(), before)


class RefusedInputTests(PublishCase):
    def test_an_unknown_name_is_refused_before_any_fetch(self):
        self.fetch = lambda url: self.fail("fetched before the name check")
        with self.assertRaisesRegex(pf.PublishError, "not a registered feature"):
            self.run_publish("--cohort", "default", "--off", "noSuchFeature", "--reason", "r", "--test-key")

    def test_a_labs_feature_is_refused(self):
        with self.assertRaisesRegex(pf.PublishError, "labs feature"):
            self.run_publish("--cohort", "default", "--off", "energySaver", "--reason", "r", "--test-key")

    def test_on_and_off_together_and_no_names_are_refused(self):
        with self.assertRaisesRegex(pf.PublishError, "both --on and --off"):
            self.run_publish("--cohort", "default", "--off", "cefTimerSlack", "--on", "cefTimerSlack", "--reason", "r",
                             "--test-key")
        with self.assertRaisesRegex(pf.PublishError, "at least one"):
            self.run_publish("--cohort", "default", "--reason", "r", "--test-key")

    def test_a_blank_reason_and_a_bad_cohort_are_refused(self):
        with self.assertRaisesRegex(pf.PublishError, "--reason"):
            self.run_publish("--cohort", "default", "--off", "cefTimerSlack", "--reason", " ", "--test-key")
        with self.assertRaisesRegex(pf.PublishError, "not a name"):
            self.run_publish("--cohort", "../x", "--off", "cefTimerSlack", "--reason", "r", "--test-key")

    def test_a_published_document_that_does_not_verify_is_not_published_over(self):
        self.publish_signed({"version": 1, "default": {"FeaturesSerial": 2}, "cohorts": {}})
        url = "https://lab.example/perf-lab-test/notes/flags.json"
        self.published[url] = self.published[url].replace(b"2", b"3")
        with self.assertRaisesRegex(pf.PublishError, "does not verify"):
            self.run_publish("--cohort", "default", "--off", "perfLabKillProbe", "--reason", "r", "--test-key")

    def test_a_production_publish_needs_the_key_path(self):
        env = {"NIGHTLY_NEXT_R2_ENDPOINT": "https://r2.example"}
        published = {"version": 1, "default": {"FeaturesSerial": 2}, "cohorts": {}}
        self.publish_signed(published, base="https://files-next.cmux.com/nightly-next/next")
        # The served copy is signed with the test key, which production does not trust.
        with self.assertRaisesRegex(pf.PublishError, "does not verify"):
            self.run_publish("--cohort", "default", "--off", "perfLabKillProbe", "--reason", "r", env=env)
        self.published.clear()
        with self.assertRaisesRegex(pf.PublishError, pf.KEY_PATH_ENV):
            self.run_publish("--cohort", "default", "--off", "perfLabKillProbe", "--reason", "r", env=env)


class SignatureTests(PublishCase):
    def test_the_published_bytes_verify_with_the_bench_test_key(self):
        code, uploader = self.run_publish("--cohort", "default", "--off", "perfLabKillProbe", "--reason", "r",
                                          "--test-key")
        self.assertEqual(code, 0)
        data = uploader.body("perf-lab-test/notes/flags.json")
        signature = uploader.body("perf-lab-test/notes/flags.json.sig")
        public_key = json.loads((REPO / "schemas/features/bench-test-signing-key.json").read_text())["publicKey"]
        self.assertTrue(pf.bytes_verified(data, signature, public_key))
        self.assertFalse(pf.bytes_verified(data + b" ", signature, public_key))
        self.assertFalse(pf.bytes_verified(data, signature, pf.CONTENT_PUBLIC_KEY))

    def test_the_test_key_signs_the_shared_vector(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            path = folder / "vector.json"
            path.write_text(VECTOR_DOCUMENT, encoding="utf-8")
            pf.sign([path], pf.write_test_key_pem(folder))
            self.assertEqual((folder / "vector.json.sig").read_text().strip(), VECTOR_SIGNATURE)
        public_key, _ = pf.test_signing_key()
        self.assertTrue(pf.bytes_verified(VECTOR_DOCUMENT.encode(), VECTOR_SIGNATURE.encode(), public_key))
        swift_test = (REPO / "Packages/macOS/CmuxNext/Tests/CmuxNextFeaturesTests/FeatureRemoteTests.swift").read_text()
        self.assertIn(f'Data(#"{VECTOR_DOCUMENT}"#.utf8)', swift_test)

    def test_the_content_signing_key_is_the_one_the_app_daemon_and_nightly_trust(self):
        sources = {
            "Packages/macOS/CmuxNext/Sources/CmuxNextUpdater/ReleaseNotes/ReleaseNotes.swift":
                f'public static let publicKey = "{pf.CONTENT_PUBLIC_KEY}"',
            "cmux-tui/crates/cmux-tui/src/feature_flags.rs": f'const PUBLIC_KEY: &str = "{pf.CONTENT_PUBLIC_KEY}";',
            ".github/workflows/nightly.yml": f"CONTENT_PUBLIC_KEY: {pf.CONTENT_PUBLIC_KEY}",
        }
        for path, line in sources.items():
            self.assertIn(line, (REPO / path).read_text(encoding="utf-8"), path)

    def test_a_production_publish_signs_with_the_key_file_and_updates_the_checkout(self):
        pem, public_key = openssl_key_pair(self.folder)
        original = pf.CONTENT_PUBLIC_KEY
        pf.CONTENT_PUBLIC_KEY = public_key  # the stand-in key plays the content-signing key
        try:
            env = {"NIGHTLY_NEXT_R2_ENDPOINT": "https://r2.example", pf.KEY_PATH_ENV: str(pem)}
            code, uploader = self.run_publish("--cohort", "default", "--off", "perfLabKillProbe", "--reason", "r",
                                              env=env)
        finally:
            pf.CONTENT_PUBLIC_KEY = original
        self.assertEqual(code, 0)
        data = uploader.body("nightly-next/next/notes/flags.json")
        self.assertTrue(pf.bytes_verified(data, uploader.body("nightly-next/next/notes/flags.json.sig"), public_key))
        self.assertEqual(json.loads(self.checkout.read_text()), json.loads(data))
        self.assertFalse(any(str(pem) in line for line in self.output), "the key path is never printed")

    def test_a_wrong_production_key_uploads_nothing(self):
        pem, _ = openssl_key_pair(self.folder)
        env = {"NIGHTLY_NEXT_R2_ENDPOINT": "https://r2.example", pf.KEY_PATH_ENV: str(pem)}
        uploader = FakeUploader()
        with self.assertRaisesRegex(pf.PublishError, "does not verify") as raised:
            self.run_publish("--cohort", "default", "--off", "perfLabKillProbe", "--reason", "r", env=env,
                             uploader=uploader)
        self.assertNotIn(str(pem), str(raised.exception))
        self.assertEqual(uploader.puts, [])


class RegistryTests(unittest.TestCase):
    def test_the_real_registry_has_the_kill_probe(self):
        self.assertEqual(pf.registry()["perfLabKillProbe"], "killSwitch")

    def test_the_checkout_document_passes_the_nightly_assertion(self):
        self.assertTrue(pf.nightly_assertion(json.loads((REPO / "release-notes/next/flags.json").read_text())))

    def test_the_assertion_matches_nightly_yml(self):
        workflow = (REPO / ".github/workflows/nightly.yml").read_text(encoding="utf-8")
        self.assertIn('assert d.get("version")==1 and isinstance(d.get("default",{}),dict) and '
                      'isinstance(d.get("cohorts",{}),dict) and type(d["default"].get("FeaturesSerial")) is int',
                      workflow)


if __name__ == "__main__":
    sys.exit(unittest.main())
