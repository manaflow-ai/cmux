#!/usr/bin/env python3
"""scripts/ci/cmux-config-ring.py makes the config ring payload acpmux reads
(cmux_signed_envelope::config_ring::verify): the shipped ring sources are valid, a payload names
its purpose, ring, seq and a later expiry, a bad flag name or value is refused, and `newer` never
moves a published file back to an older seq. One case signs a payload with a throwaway key through
scripts/cmux-next/web-ota-pointer.py sign and reads it back as the reader would.
Runs without network; the signing case needs openssl 3.
"""

import base64
import contextlib
import glob
import hashlib
import importlib.util
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(ROOT, "scripts", "ci", "cmux-config-ring.py")
POINTER = os.path.join(ROOT, "scripts", "cmux-next", "web-ota-pointer.py")
spec = importlib.util.spec_from_file_location("cmux_config_ring", SCRIPT)
ring = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ring)


def run(*argv):
    out = io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
        code = ring.main(list(argv))
    return code, out.getvalue()


class ConfigRing(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = self.tmp.name

    def tearDown(self):
        self.tmp.cleanup()

    def path(self, name):
        return os.path.join(self.dir, name)

    def source(self, flags):
        path = self.path("source.json")
        with open(path, "w") as f:
            json.dump({"flags": flags}, f)
        return path

    def payload(self, flags, seq=100, ring_name="feat-cmux-next"):
        out = self.path(f"payload-{seq}.json")
        code, _ = run("payload", "--source", self.source(flags), "--ring", ring_name, "--seq", str(seq),
                      "--now", "1000", "--days", "30", "--out", out)
        return code, out

    def published(self, seq, purpose=ring.PURPOSE):
        path = self.path("published.json")
        body = json.dumps({"purpose": purpose, "seq": seq}).encode()
        with open(path, "w") as f:
            json.dump({"schema": 1, "payload": base64.b64encode(body).decode(), "signatures": []}, f)
        return path

    def test_shipped_sources_are_valid(self):
        sources = glob.glob(os.path.join(ROOT, "cmux-tui", "rings", "*.json"))
        self.assertIn(os.path.join(ROOT, "cmux-tui", "rings", "feat-cmux-next.json"), sources)
        for source in sources:
            name = os.path.basename(source)[: -len(".json")]
            self.assertTrue(ring.valid_name(name), name)
            with open(source) as f:
                ring.checked_flags(json.load(f))

    def test_payload_shape(self):
        code, out = self.payload({"chat.fast-send": True, "retry.max": 3, "theme": "dim"})
        self.assertEqual(code, 0)
        body = json.load(open(out))
        self.assertEqual(body, {"schema": 1, "purpose": "cmux-config-ring", "ring": "feat-cmux-next",
                                "seq": 100, "issued_at": 1000, "expires_at": 1000 + 30 * 86400,
                                "flags": {"chat.fast-send": True, "retry.max": 3, "theme": "dim"}})

    def test_refuses_bad_flags_and_ring(self):
        for flags in ({"Upper": True}, {"x" * 65: True}, {"list": [1]}, {"obj": {}}, {"nul": None},
                      {"long": "x" * 1025}):
            code, _ = self.payload(flags)
            self.assertEqual(code, 1, flags)
        code, _ = self.payload({}, ring_name="Bad Ring")
        self.assertEqual(code, 1)
        path = self.path("extra.json")
        with open(path, "w") as f:
            json.dump({"flags": {}, "other": 1}, f)
        code, _ = run("payload", "--source", path, "--ring", "r", "--seq", "1", "--now", "1", "--out", self.path("o"))
        self.assertEqual(code, 1)

    def test_newer_is_forward_only(self):
        _, out = self.payload({}, seq=100)
        self.assertEqual(run("newer", "--published", self.path("none.json"), "--payload", out)[0], 0)
        self.assertEqual(run("newer", "--published", self.published(99), "--payload", out)[0], 0)
        # The same seq is a re-sign with a later expiry.
        self.assertEqual(run("newer", "--published", self.published(100), "--payload", out)[0], 0)
        self.assertEqual(run("newer", "--published", self.published(101), "--payload", out)[0], 3)
        # Another kind of file at the key never holds a ring back.
        self.assertEqual(run("newer", "--published", self.published(500, "other"), "--payload", out)[0], 0)
        self.assertEqual(run("seq", "--published", self.published(42))[1].strip(), "42")

    def test_signed_round_trip(self):
        pem = self.path("key.pem")
        if subprocess.run(["openssl", "genpkey", "-algorithm", "ed25519", "-out", pem],
                          capture_output=True).returncode != 0:
            self.skipTest("openssl cannot make an ed25519 key")
        der = subprocess.run(["openssl", "pkey", "-in", pem, "-pubout", "-outform", "DER"],
                             capture_output=True, check=True).stdout
        raw = der[-32:]
        key_id = hashlib.sha256(raw).hexdigest()[:16]
        keys = self.path("keys.json")
        with open(keys, "w") as f:
            json.dump({"keys": [{"id": key_id, "ed25519": base64.b64encode(raw).decode()}]}, f)
        _, out = self.payload({"chat.fast-send": False}, seq=7)
        signed = self.path("signed.json")
        subprocess.run([sys.executable, POINTER, "sign", "--payload", out, "--key", pem, "--keys", keys,
                        "--out", signed], check=True, capture_output=True)
        envelope = json.load(open(signed))
        self.assertEqual(envelope["signatures"][0]["key_id"], key_id)
        self.assertEqual(base64.b64decode(envelope["payload"]), open(out, "rb").read())
        self.assertLessEqual(os.path.getsize(signed), ring.MAX_RING_BYTES)
        self.assertEqual(run("seq", "--published", signed)[1].strip(), "7")


if __name__ == "__main__":
    unittest.main()
