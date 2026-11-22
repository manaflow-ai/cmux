#!/usr/bin/env python3
"""The signed apt and yum archive (scripts/ci/linux-archive.py, cmuxterm-hq docs/design/linux-signed-packages.md
phase 4): the nfpm config holds exactly the binaries a verified release file names, at their sha256; the apt
repository's InRelease and Release.gpg verify with gpgv against the archive keyring alone (the signing subkey,
never the primary) and carry Valid-Until; Packages names each .deb's sha256. Needs openssl 3, gpg and gpgv,
and dpkg-deb; the rpm repository case also needs createrepo_c, and the nfpm case runs nfpm when $NFPM names it.
"""
import base64
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
ARCHIVE = os.path.join(ROOT, "scripts", "ci", "linux-archive.py")
POINTER = os.path.join(ROOT, "scripts", "cmux-next", "web-ota-pointer.py")
KEY_NEW = os.path.join(ROOT, "scripts", "ci", "linux-archive-key-new.sh")
TARGET = "x86_64-unknown-linux-musl"
COMMIT = "1" * 40
VERSION = "0.1.0+20261122120000.111111111111"


def run(argv, **kw):
    return subprocess.run(argv, capture_output=True, text=True, **kw)


def have(*tools):
    return all(shutil.which(t) for t in tools)


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="linux-archive-test-")
        self.addCleanup(shutil.rmtree, self.tmp, True)

    def path(self, *parts):
        return os.path.join(self.tmp, *parts)


@unittest.skipUnless(have("openssl"), "needs openssl 3")
class NfpmConfig(Base):
    def setUp(self):
        super().setUp()
        pem = self.path("ota.pem")
        run(["openssl", "genpkey", "-algorithm", "ed25519", "-out", pem], check=True)
        der = subprocess.run(["openssl", "pkey", "-in", pem, "-pubout", "-outform", "DER"], capture_output=True,
                             check=True).stdout
        raw = der[-32:]
        self.keys = self.path("keys.json")
        with open(self.keys, "w") as f:
            json.dump({"keys": [{"id": hashlib.sha256(raw).hexdigest()[:16],
                                 "ed25519": base64.b64encode(raw).decode()}]}, f)
        self.bin = self.path("bin")
        os.makedirs(self.bin)
        targets = {}
        # The verifier wants every Linux release target; the package reads one.
        for target, name in [(t, n) for t in ("x86_64-unknown-linux-gnu", "aarch64-unknown-linux-gnu", TARGET,
                                              "aarch64-unknown-linux-musl") for n in ("cmux-tui", "cmux-tui-hook")]:
            published = f"{name}-{target}"
            data = f"#!/bin/sh\necho {name} {target}\n".encode()
            with open(os.path.join(self.bin, published), "wb") as f:
                f.write(data)
            targets.setdefault(target, {})[name] = {
                "url": f"https://files.cmux.com/cmux-tui/{COMMIT}/{published}",
                "sha256": hashlib.sha256(data).hexdigest(), "size": len(data)}
        payload = {"schema": 1, "purpose": "cmux-linux-release", "channel": "feat-cmux-next", "version": VERSION,
                   "commit": COMMIT, "committed_at": 1795348800, "published_at": 1795348800,
                   "expires_at": 1795348900,
                   "targets": targets}
        with open(self.path("payload.json"), "w") as f:
            json.dump(payload, f)
        self.release = self.path("release.json")
        result = run([sys.executable, POINTER, "sign", "--payload", self.path("payload.json"), "--key", pem,
                      "--keys", self.keys, "--out", self.release])
        self.assertEqual(result.returncode, 0, result.stderr)

    def config(self, target=TARGET):
        out = self.path("nfpm.yaml")
        return run([sys.executable, ARCHIVE, "nfpm-config", "--release", self.release, "--keys", self.keys,
                    "--target", target, "--binaries-dir", self.bin, "--out", out]), out

    def test_config_installs_each_named_binary_and_a_disabled_unit(self):
        result, out = self.config()
        self.assertEqual(result.returncode, 0, result.stderr)
        config = json.load(open(out))
        self.assertEqual((config["name"], config["arch"], config["version"]), ("cmux", "amd64", VERSION))
        dst = {c["dst"]: c for c in config["contents"]}
        self.assertEqual(set(dst), {"/usr/bin/cmux", "/usr/bin/cmux-tui-hook",
                                    "/usr/lib/systemd/system/cmux-host.service"})
        unit = open(dst["/usr/lib/systemd/system/cmux-host.service"]["src"]).read()
        self.assertIn("ExecStart=/usr/bin/cmux host run", unit)
        # Installing starts nothing: no maintainer scripts enable the unit.
        self.assertNotIn("scripts", config)
        self.assertEqual(config["mtime"], "2026-11-22T12:00:00Z")  # reruns build the same bytes
        if os.environ.get("NFPM"):
            for packager in ("deb", "rpm"):
                built = run([os.environ["NFPM"], "package", "--config", out, "--packager", packager,
                             "--target", self.tmp])
                self.assertEqual(built.returncode, 0, built.stderr)
            deb = [n for n in os.listdir(self.tmp) if n.endswith(".deb")]
            self.assertEqual(len(deb), 1, os.listdir(self.tmp))
            if have("dpkg-deb"):
                listing = run(["dpkg-deb", "-c", self.path(deb[0])]).stdout
                self.assertIn("./usr/bin/cmux", listing)
                self.assertIn("./usr/lib/systemd/system/cmux-host.service", listing)

    def test_changed_binary_is_refused(self):
        with open(os.path.join(self.bin, f"cmux-tui-hook-{TARGET}"), "ab") as f:
            f.write(b"x")
        result, _ = self.config()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("sha256 differ", result.stderr)

    def test_missing_binary_is_refused(self):
        os.remove(os.path.join(self.bin, f"cmux-tui-hook-{TARGET}"))
        result, _ = self.config()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("is missing", result.stderr)

    def test_glibc_target_is_refused(self):
        result, _ = self.config("x86_64-unknown-linux-gnu")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no package for", result.stderr)

    def test_unsigned_release_is_refused(self):
        with open(self.release, "w") as f:
            json.dump({"schema": 1, "payload": base64.b64encode(b"{}").decode(), "signatures": []}, f)
        result, _ = self.config()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not a verified Linux release file", result.stderr)


@unittest.skipUnless(have("gpg", "gpgv", "dpkg-deb", "bash"), "needs gpg, gpgv and dpkg-deb")
class AptRepo(Base):
    @classmethod
    def setUpClass(cls):
        # One throwaway archive key for the class, made by the same script the real key is made with:
        # the primary and its revocation stay in OFFLINE, CI gets the subkey alone.
        cls.keys_dir = tempfile.mkdtemp(prefix="linux-archive-key-")
        cls.offline = os.path.join(cls.keys_dir, "offline")
        result = run(["bash", KEY_NEW, "--out", cls.offline, "--uid", "cmux archive test <test@cmux.invalid>",
                      "--expire", "1y"])
        if result.returncode != 0:
            raise AssertionError(f"linux-archive-key-new.sh failed: {result.stdout}{result.stderr}")
        cls.subkey = open(os.path.join(cls.offline, "signing-subkey.fpr")).read().strip()
        cls.keyring = os.path.join(cls.offline, "cmux-archive-keyring.gpg")
        # CI's GNUPGHOME: the exported subkey only (secret primary stubbed out).
        cls.ci_home = os.path.join(cls.keys_dir, "ci")
        os.makedirs(cls.ci_home, mode=0o700)
        imported = run(["gpg", "--batch", "--homedir", cls.ci_home, "--import",
                        os.path.join(cls.offline, "ci-signing-subkey.asc")])
        if imported.returncode != 0:
            raise AssertionError(imported.stderr)

    @classmethod
    def tearDownClass(cls):
        run(["gpgconf", "--homedir", cls.ci_home, "--kill", "all"])
        run(["gpgconf", "--homedir", os.path.join(cls.offline, "gnupg"), "--kill", "all"])
        shutil.rmtree(cls.keys_dir, True)

    def deb(self, arch):
        root = self.path(f"pkg-{arch}")
        os.makedirs(os.path.join(root, "DEBIAN"))
        os.makedirs(os.path.join(root, "usr", "bin"))
        with open(os.path.join(root, "usr", "bin", "cmux"), "w") as f:
            f.write("#!/bin/sh\n")
        with open(os.path.join(root, "DEBIAN", "control"), "w") as f:
            f.write(f"Package: cmux\nVersion: {VERSION}\nArchitecture: {arch}\nMaintainer: t <t@cmux.invalid>\n"
                    "Description: test\n")
        os.makedirs(self.path("debs"), exist_ok=True)
        out = self.path("debs", f"cmux_{VERSION}_{arch}.deb")
        result = run(["dpkg-deb", "--root-owner-group", "--build", root, out])
        self.assertEqual(result.returncode, 0, result.stderr)
        return out

    def apt_repo(self, **env):
        return run([sys.executable, ARCHIVE, "apt-repo", "--debs", self.path("debs"), "--channel", "feat-cmux-next",
                    "--out", self.path("repo"), "--key-id", self.subkey, "--now", "1795000000"],
                   env={**os.environ, "GNUPGHOME": self.ci_home, **env})

    def test_signed_indexes_verify_against_the_keyring_alone(self):
        debs = [self.deb("amd64"), self.deb("arm64")]
        result = self.apt_repo()
        self.assertEqual(result.returncode, 0, result.stderr)
        dist = self.path("repo", "dists", "feat-cmux-next")
        release = open(os.path.join(dist, "Release")).read()
        self.assertIn("Valid-Until: Wed, 25 Nov 2026 11:06:40 UTC", release)  # --now 1795000000 plus 7 days
        self.assertRegex(release, r"(?m)^Architectures: amd64 arm64$")
        for name in ("InRelease", "Release.gpg"):
            argv = ["gpgv", "--keyring", self.keyring]
            argv += [os.path.join(dist, name)] if name == "InRelease" else [os.path.join(dist, name),
                                                                         os.path.join(dist, "Release")]
            verified = run(argv)
            self.assertEqual(verified.returncode, 0, f"{name}: {verified.stderr}")
            # Signed by the subkey, never the primary (which CI does not hold).
            self.assertIn(self.subkey[-16:].upper(), verified.stderr.replace(" ", "").upper())
        inrelease = open(os.path.join(dist, "InRelease")).read()
        self.assertIn("Valid-Until:", inrelease.split("-----BEGIN PGP SIGNATURE-----")[0])
        packages = open(os.path.join(dist, "main", "binary-amd64", "Packages")).read()
        self.assertIn(f"Filename: pool/feat-cmux-next/cmux_{VERSION}_amd64.deb", packages)
        self.assertIn(f"SHA256: {hashlib.sha256(open(debs[0], 'rb').read()).hexdigest()}", packages)
        for rel in ("main/binary-amd64/Packages", "main/binary-arm64/Packages.gz"):
            digest = hashlib.sha256(open(os.path.join(dist, rel), "rb").read()).hexdigest()
            self.assertRegex(release, rf"(?m)^ {digest} +\d+ {re.escape(rel)}$")

    def test_another_key_does_not_verify(self):
        self.deb("amd64")
        self.assertEqual(self.apt_repo().returncode, 0)
        other = tempfile.mkdtemp(prefix="linux-archive-other-")
        self.addCleanup(shutil.rmtree, other, True)
        made = run(["gpg", "--batch", "--homedir", other, "--passphrase", "", "--quick-gen-key",
                    "other <o@cmux.invalid>", "ed25519", "sign", "1d"])
        self.assertEqual(made.returncode, 0, made.stderr)
        ring = os.path.join(other, "ring.gpg")
        run(["gpg", "--batch", "--homedir", other, "--output", ring, "--export"], check=True)
        verified = run(["gpgv", "--keyring", ring, self.path("repo", "dists", "feat-cmux-next", "InRelease")])
        run(["gpgconf", "--homedir", other, "--kill", "all"])
        self.assertNotEqual(verified.returncode, 0)

    def test_ci_home_holds_no_primary_secret(self):
        listing = run(["gpg", "--batch", "--homedir", self.ci_home, "--list-secret-keys", "--with-colons"]).stdout
        sec = [line for line in listing.splitlines() if line.startswith("sec:")]
        self.assertTrue(sec, listing)
        # gpg marks a stubbed-out secret primary with `#` in field 15 (serial/stub).
        self.assertTrue(all(line.split(":")[14].startswith("#") for line in sec), listing)
        ssb = [line for line in listing.splitlines() if line.startswith("ssb:")]
        self.assertEqual(len(ssb), 1, listing)
        self.assertIn("s", ssb[0].split(":")[11])
        self.assertTrue(ssb[0].split(":")[6], "the signing subkey has an expiry")

    def test_no_debs_is_refused(self):
        os.makedirs(self.path("debs"))
        result = self.apt_repo()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no .deb", result.stderr)


@unittest.skipUnless(have("gpg", "gpgv", "createrepo_c", "bash"), "needs gpg, gpgv and createrepo_c")
class RpmRepo(AptRepo):
    def test_repomd_signature_verifies(self):
        os.makedirs(self.path("rpms"))
        # createrepo_c reads real rpm headers; a .rpm from nfpm is needed, so the case runs with $NFPM.
        if not os.environ.get("NFPM"):
            self.skipTest("needs $NFPM to build a .rpm")
        config = self.path("nfpm.json")
        payload = self.path("cmux")
        with open(payload, "w") as f:
            f.write("#!/bin/sh\n")
        with open(config, "w") as f:
            json.dump({"name": "cmux", "arch": "amd64", "platform": "linux", "version": VERSION,
                       "version_schema": "none", "maintainer": "t <t@cmux.invalid>", "description": "test",
                       "contents": [{"src": payload, "dst": "/usr/bin/cmux"}]}, f)
        built = run([os.environ["NFPM"], "package", "--config", config, "--packager", "rpm",
                     "--target", self.path("rpms")])
        self.assertEqual(built.returncode, 0, built.stderr)
        result = run([sys.executable, ARCHIVE, "rpm-repo", "--rpms", self.path("rpms"), "--channel",
                      "feat-cmux-next", "--out", self.path("repo"), "--key-id", self.subkey],
                     env={**os.environ, "GNUPGHOME": self.ci_home})
        self.assertEqual(result.returncode, 0, result.stderr)
        repodata = self.path("repo", "feat-cmux-next", "repodata")
        verified = run(["gpgv", "--keyring", self.keyring, os.path.join(repodata, "repomd.xml.asc"),
                        os.path.join(repodata, "repomd.xml")])
        self.assertEqual(verified.returncode, 0, verified.stderr)


class PublishWithoutTheKey(Base):
    """The workflow step publishes nothing, with a warning and success, until the key exists."""
    PUBLISH = os.path.join(ROOT, "scripts", "ci", "linux-archive-publish.sh")

    def publish(self, **env):
        clean = {k: v for k, v in os.environ.items() if k != "ARCHIVE_SIGNING_KEY"}
        return run(["bash", self.PUBLISH, self.path("built"), self.path("work")], env={**clean, **env})

    def test_no_secret_skips_with_a_warning(self):
        result = self.publish()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("::warning::CMUX_LINUX_ARCHIVE_SIGNING_KEY is not set", result.stdout)
        self.assertFalse(os.path.exists(self.path("work")))

    def test_no_committed_keyring_skips_with_a_warning(self):
        if os.path.exists(os.path.join(ROOT, "scripts", "ci", "cmux-archive-keyring.asc")):
            self.skipTest("the keyring is committed")
        result = self.publish(ARCHIVE_SIGNING_KEY="not read before the keyring check")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("::warning::scripts/ci/cmux-archive-keyring.asc is not committed", result.stdout)


# RpmRepo inherits AptRepo's key fixture; its apt cases already ran once.
for _name in [n for n in vars(AptRepo) if n.startswith("test_")]:
    setattr(RpmRepo, _name, None)


if __name__ == "__main__":
    unittest.main()
