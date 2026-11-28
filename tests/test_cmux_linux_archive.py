#!/usr/bin/env python3
"""The signed apt and yum archive (scripts/ci/linux-archive.py, cmuxterm-hq docs/design/linux-signed-packages.md
phase 4): the nfpm config holds exactly the binaries a verified release file names, at their sha256; the apt
repository's InRelease and Release.gpg verify with gpgv against the archive keyring alone (the signing subkey,
never the primary) and carry Valid-Until; Packages names each .deb's sha256. Needs openssl 3, gpg and gpgv,
and dpkg-deb; the rpm repository case also needs createrepo_c, and the nfpm case runs nfpm when $NFPM names it.
The AppImage cases (the same verified binaries, a reproducible image, its update information) need squashfs-tools.
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


@unittest.skipUnless(have("openssl"), "needs openssl 3")
class Packages(NfpmConfig):
    """`packages` builds the .deb and .rpm of the unsigned payload before it is signed and names them per
    target; the signed file verifies with them, and same-build ignores them (they carry the signing run's
    version). nfpm is a stub here unless $NFPM names the real one."""
    test_config_installs_each_named_binary_and_a_disabled_unit = None
    test_changed_binary_is_refused = None
    test_missing_binary_is_refused = None
    test_glibc_target_is_refused = None
    test_unsigned_release_is_refused = None

    def setUp(self):
        super().setUp()
        self.nfpm = os.environ.get("NFPM") or self.path("nfpm")
        if not os.environ.get("NFPM"):
            # nfpm package --config C --packager P --target DIR/: one file named as nfpm would.
            with open(self.nfpm, "w") as f:
                f.write("#!/bin/sh\nset -e\nwhile [ $# -gt 0 ]; do case $1 in --config) c=$2;; --packager) p=$2;; "
                        "--target) t=$2;; esac; shift; done\ncat \"$c\" >\"${t}cmux_built.$p\"\n")
            os.chmod(self.nfpm, 0o755)
        self.payload = self.path("payload.json")

    def packages(self):
        out = self.path("payload-packages.json")
        result = run([sys.executable, ARCHIVE, "packages", "--payload", self.payload, "--binaries-dir", self.bin,
                      "--nfpm", self.nfpm, "--work", self.path("work"), "--out", out])
        return result, out

    def sign(self, payload, out):
        result = run([sys.executable, POINTER, "sign", "--payload", payload, "--key", self.path("ota.pem"),
                      "--keys", self.keys, "--out", out])
        self.assertEqual(result.returncode, 0, result.stderr)
        return out

    def test_each_target_names_its_packages_under_the_commit(self):
        result, out = self.packages()
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.load(open(out))
        uploads = dict(line.split("\t")[::-1] for line in result.stdout.splitlines())
        prefix = f"https://files.cmux.com/cmux-tui/{COMMIT}/"
        for target, (deb, rpm) in {"x86_64-unknown-linux-gnu": ("amd64", "x86_64"), TARGET: ("amd64", "x86_64"),
                                   "aarch64-unknown-linux-gnu": ("arm64", "aarch64"),
                                   "aarch64-unknown-linux-musl": ("arm64", "aarch64")}.items():
            files = payload["targets"][target]
            self.assertEqual(files["deb"]["url"], f"{prefix}cmux-20261122120000-{deb}.deb")
            self.assertEqual(files["rpm"]["url"], f"{prefix}cmux-20261122120000-{rpm}.rpm")
            for packager in ("deb", "rpm"):
                local = uploads[files[packager]["url"][len("https://files.cmux.com/"):]]
                self.assertEqual(files[packager]["size"], os.path.getsize(local))
                self.assertEqual(files[packager]["sha256"], hashlib.sha256(open(local, "rb").read()).hexdigest())
        # The binaries are untouched, and the signed file verifies with its packages.
        before = json.load(open(self.payload))
        for target in before["targets"]:
            for name, entry in before["targets"][target].items():
                self.assertEqual(payload["targets"][target][name], entry)
        signed = self.sign(out, self.path("release-packages.json"))
        verified = run([sys.executable, POINTER, "verify", "--pointer", signed, "--keys", self.keys,
                        "--purpose", "cmux-linux-release", "--allow-expired"])
        self.assertEqual(verified.returncode, 0, verified.stderr)
        # A signed file that names packages builds the same nfpm config (packages are skipped).
        config = run([sys.executable, ARCHIVE, "nfpm-config", "--release", signed, "--keys", self.keys,
                      "--target", TARGET, "--binaries-dir", self.bin, "--out", self.path("again.json")])
        self.assertEqual(config.returncode, 0, config.stderr)

    def test_tree_payload_names_packages_under_the_tree(self):
        payload = json.load(open(self.payload))
        tree = "2" * 40
        payload["tree_key"] = tree
        for files in payload["targets"].values():
            for entry in files.values():
                entry["url"] = entry["url"].replace(f"/{COMMIT}/", f"/tree/{tree}/")
        with open(self.payload, "w") as f:
            json.dump(payload, f)
        result, out = self.packages()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"\tcmux-tui/tree/{tree}/cmux-20261122120000-amd64.deb", result.stdout)
        verified = run([sys.executable, POINTER, "verify", "--pointer", self.sign(out, self.path("t.json")),
                        "--keys", self.keys, "--purpose", "cmux-linux-release", "--allow-expired"])
        self.assertEqual(verified.returncode, 0, verified.stderr)

    def test_changed_binary_builds_nothing(self):
        with open(os.path.join(self.bin, f"cmux-tui-{TARGET}"), "ab") as f:
            f.write(b"x")
        result, out = self.packages()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(os.path.exists(out))

    def test_a_deb_url_that_is_not_a_deb_is_refused(self):
        result, out = self.packages()
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.load(open(out))
        payload["targets"][TARGET]["deb"]["url"] = f"https://files.cmux.com/cmux-tui/{COMMIT}/cmux-tui-{TARGET}"
        with open(out, "w") as f:
            json.dump(payload, f)
        verified = run([sys.executable, POINTER, "verify", "--pointer", self.sign(out, self.path("bad.json")),
                        "--keys", self.keys, "--purpose", "cmux-linux-release", "--allow-expired"])
        self.assertNotEqual(verified.returncode, 0)
        self.assertIn("is not a .deb", verified.stderr)

    def test_same_build_ignores_packages(self):
        # The file already written (with or without packages) is kept by a re-sign that built others.
        result, out = self.packages()
        self.assertEqual(result.returncode, 0, result.stderr)
        with_packages = self.sign(out, self.path("with.json"))
        payload = json.load(open(out))
        payload["targets"][TARGET]["deb"]["sha256"] = "f" * 64
        with open(self.path("other.json"), "w") as f:
            json.dump(payload, f)
        other = self.sign(self.path("other.json"), self.path("other-signed.json"))
        for new, current in ((with_packages, self.release), (self.release, with_packages), (other, with_packages)):
            same = run([sys.executable, POINTER, "same-build", "--pointer", new, "--current", current,
                        "--keys", self.keys])
            self.assertEqual(same.returncode, 0, same.stderr)
        # A changed binary is still another build.
        payload["targets"][TARGET]["cmux-tui"]["sha256"] = "e" * 64
        with open(self.path("bin.json"), "w") as f:
            json.dump(payload, f)
        changed = run([sys.executable, POINTER, "same-build", "--pointer", self.sign(self.path("bin.json"),
                       self.path("bin-signed.json")), "--current", with_packages, "--keys", self.keys])
        self.assertNotEqual(changed.returncode, 0)


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


UPDATE_INFO = "zsync|https://files.cmux.com/linux/appimage/feat-cmux-next/cmux-x86_64.AppImage.zsync"
PNG = b"\x89PNG\r\n\x1a\n" + b"\0" * 32


def fake_runtime():
    """An ELF64 little-endian file laid out like the type2 runtime: a 1024-byte .upd_info section, and the
    section header table last, so the squashfs starts right after it."""
    names = b"\0.shstrtab\0.upd_info\0"
    upd_at = 64
    names_at = upd_at + 1024
    shoff = names_at + len(names)
    header = bytearray(64)
    header[0:6] = b"\x7fELF\x02\x01"
    header[0x28:0x30] = shoff.to_bytes(8, "little")
    header[0x3A:0x3C] = (64).to_bytes(2, "little")
    header[0x3C:0x3E] = (3).to_bytes(2, "little")
    header[0x3E:0x40] = (1).to_bytes(2, "little")

    def section(name_at, offset, size):
        h = bytearray(64)
        h[0:4] = name_at.to_bytes(4, "little")
        h[24:32] = offset.to_bytes(8, "little")
        h[32:40] = size.to_bytes(8, "little")
        return bytes(h)
    return (bytes(header) + b"\0" * 1024 + names + bytes(64) + section(1, names_at, len(names))
            + section(11, upd_at, 1024))


@unittest.skipUnless(have("openssl", "mksquashfs", "unsquashfs"), "needs openssl 3 and squashfs-tools")
class AppImage(NfpmConfig):
    """The AppImage holds exactly the verified binaries under their installed names, builds to the same
    bytes twice, carries the update information in .upd_info, and appimage-verify refuses one whose binary
    is not the release file's."""

    def setUp(self):
        super().setUp()
        self.runtime = self.path("runtime")
        with open(self.runtime, "wb") as f:
            f.write(fake_runtime())
        self.runtime_sha = hashlib.sha256(fake_runtime()).hexdigest()
        self.icon = self.path("icon.png")
        with open(self.icon, "wb") as f:
            f.write(PNG)

    def appdir(self, out):
        return run([sys.executable, ARCHIVE, "appdir", "--release", self.release, "--keys", self.keys,
                    "--target", TARGET, "--binaries-dir", self.bin, "--icon", self.icon, "--out", out])

    def appimage(self, appdir, out, update_info=UPDATE_INFO, runtime_sha=None):
        return run([sys.executable, ARCHIVE, "appimage", "--appdir", appdir, "--runtime", self.runtime,
                    "--runtime-sha256", runtime_sha or self.runtime_sha, "--update-info", update_info,
                    "--out", out])

    def verify(self, image):
        return run([sys.executable, ARCHIVE, "appimage-verify", "--appimage", image, "--release", self.release,
                    "--keys", self.keys, "--target", TARGET])

    def build(self, name):
        appdir = self.path(f"{name}.AppDir")
        result = self.appdir(appdir)
        self.assertEqual(result.returncode, 0, result.stderr)
        out = self.path(f"{name}.AppImage")
        result = self.appimage(appdir, out)
        self.assertEqual(result.returncode, 0, result.stderr)
        return appdir, out

    def test_appdir_holds_the_installed_names_and_a_launcher(self):
        appdir, _ = self.build("a")
        self.assertEqual(sorted(os.listdir(os.path.join(appdir, "usr", "bin"))), ["cmux", "cmux-tui-hook"])
        self.assertTrue(os.access(os.path.join(appdir, "AppRun"), os.X_OK))
        self.assertEqual(open(os.path.join(appdir, "cmux-version")).read().strip(), VERSION)
        self.assertIn("Exec=cmux", open(os.path.join(appdir, "cmux.desktop")).read())
        self.assertEqual(os.readlink(os.path.join(appdir, ".DirIcon")), "cmux.png")
        self.assertEqual(int(os.stat(os.path.join(appdir, "usr", "bin", "cmux")).st_mtime), 1795348800)

    def test_build_is_reproducible_and_carries_the_update_information(self):
        _, first = self.build("a")
        _, second = self.build("b")
        data = open(first, "rb").read()
        self.assertEqual(data, open(second, "rb").read())
        self.assertTrue(os.access(first, os.X_OK))
        runtime = fake_runtime()
        self.assertEqual(data[64:64 + len(UPDATE_INFO)], UPDATE_INFO.encode())
        self.assertEqual(data[64 + len(UPDATE_INFO):64 + 1024], b"\0" * (1024 - len(UPDATE_INFO)))
        self.assertEqual(data[64 + 1024:len(runtime)], runtime[64 + 1024:])
        self.assertEqual(data[len(runtime):len(runtime) + 4], b"hsqs")
        result = self.verify(first)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("2 binaries match", result.stdout)

    def test_changed_binary_inside_is_refused(self):
        appdir = self.path("t.AppDir")
        self.assertEqual(self.appdir(appdir).returncode, 0)
        with open(os.path.join(appdir, "usr", "bin", "cmux-tui-hook"), "ab") as f:
            f.write(b"x")
        out = self.path("t.AppImage")
        self.assertEqual(self.appimage(appdir, out).returncode, 0)
        result = self.verify(out)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("is not the cmux-tui-hook the release file names", result.stderr)

    def test_extra_binary_inside_is_refused(self):
        appdir = self.path("x.AppDir")
        self.assertEqual(self.appdir(appdir).returncode, 0)
        with open(os.path.join(appdir, "usr", "bin", "extra"), "wb") as f:
            f.write(b"#!/bin/sh\n")
        out = self.path("x.AppImage")
        self.assertEqual(self.appimage(appdir, out).returncode, 0)
        result = self.verify(out)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not the binaries the release file names", result.stderr)

    def test_unpinned_runtime_and_foreign_update_url_are_refused(self):
        appdir = self.path("r.AppDir")
        self.assertEqual(self.appdir(appdir).returncode, 0)
        result = self.appimage(appdir, self.path("r.AppImage"), runtime_sha="0" * 64)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not the pinned runtime", result.stderr)
        result = self.appimage(appdir, self.path("r.AppImage"),
                               update_info="zsync|https://example.com/cmux-x86_64.AppImage.zsync")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("bad update information", result.stderr)

    def test_release_with_packages_builds_the_binaries_alone(self):
        # Since #57583 a release file names each musl target's .deb and .rpm beside its binaries; the
        # AppImage holds the binaries alone and appimage-verify reads the same set.
        payload = json.load(open(self.path("payload.json")))
        for packager in ("deb", "rpm"):
            payload["targets"][TARGET][packager] = {
                "url": f"https://files.cmux.com/cmux-tui/{COMMIT}/cmux-20261122120000-amd64.{packager}",
                "sha256": "0" * 64, "size": 1}
        with open(self.path("payload.json"), "w") as f:
            json.dump(payload, f)
        result = run([sys.executable, POINTER, "sign", "--payload", self.path("payload.json"),
                      "--key", self.path("ota.pem"), "--keys", self.keys, "--out", self.release])
        self.assertEqual(result.returncode, 0, result.stderr)
        appdir, image = self.build("p")
        self.assertEqual(sorted(os.listdir(os.path.join(appdir, "usr", "bin"))), ["cmux", "cmux-tui-hook"])
        result = self.verify(image)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("2 binaries match", result.stdout)

    def test_changed_binary_is_refused_before_the_appdir(self):
        with open(os.path.join(self.bin, f"cmux-tui-hook-{TARGET}"), "ab") as f:
            f.write(b"x")
        result = self.appdir(self.path("c.AppDir"))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("sha256 differ", result.stderr)


# AppImage inherits NfpmConfig's release fixture; its nfpm cases already ran once.
for _name in [n for n in vars(NfpmConfig) if n.startswith("test_")]:
    setattr(AppImage, _name, None)

# RpmRepo inherits AptRepo's key fixture; its apt cases already ran once.
for _name in [n for n in vars(AptRepo) if n.startswith("test_")]:
    setattr(RpmRepo, _name, None)


if __name__ == "__main__":
    unittest.main()
