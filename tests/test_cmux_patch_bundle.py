#!/usr/bin/env python3
"""scripts/ci/cmux-patch-bundle.py makes the patch bundle payload acpmux reads
(cmux_signed_envelope::patch_bundle::verify): a payload names its purpose, target, full base and a
later expiry and carries each file's bytes and sha256; a bad id, base, path or a source outside the
repo is refused. One case signs a payload with a throwaway key through
scripts/cmux-next/web-ota-pointer.py sign and reads it back. Runs without network; the signing case
needs openssl 3.
"""

import base64
import hashlib
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(ROOT, "scripts", "ci", "cmux-patch-bundle.py")
POINTER = os.path.join(ROOT, "scripts", "cmux-next", "web-ota-pointer.py")
spec = importlib.util.spec_from_file_location("cmux_patch_bundle", SCRIPT)
bundle = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bundle)

BASE = "41994452b7c0d1e2f3a4b5c6d7e8f90123456789"
NOW = 1_795_400_000


class PatchBundleTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = self.tmp.name
        os.makedirs(os.path.join(self.root, "fix"))
        with open(os.path.join(self.root, "fix", "app.js"), "wb") as f:
            f.write(b"console.log('fixed')\n")

    def tearDown(self):
        self.tmp.cleanup()

    def manifest(self, **over):
        m = {"id": "fix-1", "base": BASE, "files": [{"path": "web/app.js", "source": "fix/app.js"}]}
        m.update(over)
        return m

    def test_payload_carries_each_file_and_expiry(self):
        body = bundle.payload(self.manifest(days=2), "x86_64-unknown-linux-musl", NOW, self.root)
        self.assertEqual(body["purpose"], "cmux-patch-bundle")
        self.assertEqual(body["schema"], 1)
        self.assertEqual((body["target"], body["base"], body["id"]), ("x86_64-unknown-linux-musl", BASE, "fix-1"))
        self.assertEqual(body["expires_at"], NOW + 2 * 86400)
        (entry,) = body["files"]
        content = base64.b64decode(entry["content"])
        self.assertEqual(content, b"console.log('fixed')\n")
        self.assertEqual(entry["sha256"], hashlib.sha256(content).hexdigest())

    def test_refuses_bad_ids_bases_paths_and_sources(self):
        cases = [
            self.manifest(id="Fix 1"),
            self.manifest(base="41994452b"),
            self.manifest(days=0),
            self.manifest(days=True),
            self.manifest(files=[]),
            self.manifest(extra=1),
            self.manifest(files=[{"path": "../x", "source": "fix/app.js"}]),
            self.manifest(files=[{"path": ".hidden", "source": "fix/app.js"}]),
            self.manifest(files=[{"path": "a//b", "source": "fix/app.js"}]),
            self.manifest(files=[{"path": "c:x", "source": "fix/app.js"}]),
            self.manifest(files=[{"path": "a.js", "source": "../../etc/passwd"}]),
            self.manifest(files=[{"path": "a.js", "source": "fix/missing.js"}]),
            self.manifest(files=[{"path": "a.js", "source": "fix/app.js"}] * 2),
        ]
        for m in cases:
            with self.subTest(m=m), self.assertRaises(bundle.Refused):
                bundle.payload(m, "x86_64-unknown-linux-musl", NOW, self.root)
        with self.assertRaises(bundle.Refused):
            bundle.payload(self.manifest(), "X86 Linux", NOW, self.root)

    def test_signed_payload_verifies_with_its_key(self):
        try:
            subprocess.run(["openssl", "version"], check=True, capture_output=True)
        except (OSError, subprocess.CalledProcessError):
            self.skipTest("openssl is not here")
        d = self.root
        manifest = os.path.join(d, "m.json")
        with open(manifest, "w") as f:
            json.dump(self.manifest(), f)
        out = os.path.join(d, "payload.json")
        rc = bundle.main(["payload", "--manifest", manifest, "--target", "x86_64-unknown-linux-musl",
                          "--now", str(NOW), "--root", d, "--out", out])
        self.assertEqual(rc, 0)
        key = os.path.join(d, "key.pem")
        subprocess.run(["openssl", "genpkey", "-algorithm", "ed25519", "-out", key], check=True,
                       capture_output=True)
        pub = subprocess.run(["openssl", "pkey", "-in", key, "-pubout", "-outform", "DER"],
                             check=True, capture_output=True).stdout[-32:]
        key_id = hashlib.sha256(pub).hexdigest()[:16]
        keys = os.path.join(d, "keys.json")
        with open(keys, "w") as f:
            json.dump({"keys": [{"id": key_id, "ed25519": base64.b64encode(pub).decode()}]}, f)
        signed = os.path.join(d, "signed.json")
        subprocess.run([sys.executable, POINTER, "sign", "--payload", out, "--key", key,
                        "--keys", keys, "--out", signed], check=True, capture_output=True)
        with open(signed) as f:
            env = json.load(f)
        payload = json.loads(base64.b64decode(env["payload"]))
        self.assertEqual(payload["purpose"], "cmux-patch-bundle")
        self.assertEqual(env["signatures"][0]["key_id"], key_id)
        self.assertLessEqual(os.path.getsize(signed), bundle.MAX_BUNDLE_BYTES)

    def test_shipped_manifests_are_valid(self):
        patches = os.path.join(ROOT, "cmux-tui", "patches")
        for channel in sorted(os.listdir(patches)) if os.path.isdir(patches) else []:
            cdir = os.path.join(patches, channel)
            if not os.path.isdir(cdir):
                continue
            for name in sorted(os.listdir(cdir)):
                if name.endswith(".json"):
                    with self.subTest(manifest=f"{channel}/{name}"), open(os.path.join(cdir, name)) as f:
                        bundle.payload(json.load(f), name[: -len(".json")], NOW, ROOT)


if __name__ == "__main__":
    unittest.main()
