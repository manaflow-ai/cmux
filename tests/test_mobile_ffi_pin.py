#!/usr/bin/env python3
"""The cmux-mobile-ffi publish-and-pin pipeline (RFD 0213 slice 1).

cmux-mobile-ffi.yml publishes each feat-cmux-next build of the iOS Rust core as
the release cmux-mobile-ffi-<sha> and its repin job pins it in
Packages/Shared/CmuxMobileFFI (mobile-ffi-pin.json and the uniffi bindings, one
commit), the package ios/CmuxiOS links. This test holds:

- the pin file's one format (scripts/cmux-next/mobile_ffi_pin.py), and the
  committed pin parses;
- the additive judgment that lets a re-pin skip the pull request;
- the workflow's push paths cover every input check-mobile-ffi-pin.sh lists, or a
  change to one would never be published;
- publish-mobile-ffi-repin.sh against a local remote and release: the first pin
  goes to the mobile-ffi-repin branch, an additive one lands on the base, a
  narrowing one goes to the branch, and an older release never pins backwards.
"""
from __future__ import annotations

import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
PIN_TOOL = ROOT / "scripts/cmux-next/mobile_ffi_pin.py"
CHECK = ROOT / "scripts/cmux-next/check-mobile-ffi-pin.sh"
WORKFLOW = ROOT / ".github/workflows/cmux-mobile-ffi.yml"
RELEASE_WORKFLOW = ROOT / ".github/workflows/cmux-mobile-ffi-release.yml"
PIN = ROOT / "Packages/Shared/CmuxMobileFFI/mobile-ffi-pin.json"
SCRIPTS = [
    "scripts/cmux-next/mobile_ffi_pin.py",
    "scripts/cmux-next/check-mobile-ffi-pin.sh",
    "scripts/cmux-next/repin-mobile-ffi.sh",
    "scripts/cmux-next/publish-mobile-ffi-repin.sh",
    "scripts/ci/app_ffi_pin.py",
]
CLEAN_ENV = {k: v for k, v in os.environ.items() if not k.startswith(("GIT_", "GITHUB_"))}
# The system git, never a wrapper on PATH (a lane VM's git routes pushes through its broker).
_GIT = shutil.which("git", path="/usr/local/bin:/usr/bin:/bin") or "git"
_BIN = tempfile.mkdtemp(prefix="mobile-ffi-pin-bin-")
os.symlink(_GIT, os.path.join(_BIN, "git"))
CLEAN_ENV.update(GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1")
CLEAN_ENV["PATH"] = _BIN + os.pathsep + CLEAN_ENV.get("PATH", "")


def run(args, cwd=None, env=None, check=True):
    result = subprocess.run(args, cwd=cwd, env=env or CLEAN_ENV, capture_output=True, text=True)
    if check and result.returncode != 0:
        raise AssertionError(f"{args} exited {result.returncode}\n{result.stdout}\n{result.stderr}")
    return result


class PinFormat(unittest.TestCase):
    def tool(self, *args):
        return run([sys.executable, "-I", str(PIN_TOOL), *args], check=False)

    def test_committed_pin_reads(self):
        result = self.tool("read", str(PIN))
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_round_trip_and_refusals(self):
        with tempfile.TemporaryDirectory() as tmp:
            pin = Path(tmp, "pin.json")
            sha, checksum = "a" * 40, "b" * 64
            self.assertEqual(self.tool("write", sha, checksum, str(pin)).returncode, 0)
            self.assertEqual(self.tool("read", str(pin)).stdout.strip(), f"{sha} {checksum}")
            for text in (
                '{"url": "", "checksum": ""}',  # no trailing newline: not the one format
                '{"checksum": "", "url": ""}\n',
                json.dumps({"url": "https://example.com/x.zip", "checksum": checksum}) + "\n",
                json.dumps({"url": "", "checksum": "", "extra": 1}) + "\n",
            ):
                pin.write_text(text)
                self.assertNotEqual(self.tool("read", str(pin)).returncode, 0, text)
            self.assertNotEqual(self.tool("write", "abc", checksum, str(pin)).returncode, 0)

    def test_additive(self):
        with tempfile.TemporaryDirectory() as tmp:
            old, new, narrow = Path(tmp, "old"), Path(tmp, "new"), Path(tmp, "narrow")
            old.write_text("public func feedPushJson(op: String, request: String) -> String {\n  x\n}\n")
            new.write_text(old.read_text() + "public func screenJson(request: String) -> String {\n}\n")
            narrow.write_text("public func screenJson(request: String) -> String {\n}\n")
            self.assertEqual(self.tool("additive", str(old), str(new)).returncode, 0)
            self.assertNotEqual(self.tool("additive", str(old), str(narrow)).returncode, 0)


class Workflow(unittest.TestCase):
    def test_push_paths_cover_inputs(self):
        workflow = yaml.safe_load(WORKFLOW.read_text())
        on = workflow.get("on", workflow.get(True))
        paths = on["push"]["paths"]
        inputs = run(["bash", str(CHECK), "--list-inputs"]).stdout.split()
        self.assertIn("cmux-tui/crates/cmux-mobile-ffi", inputs)
        for item in inputs:
            self.assertTrue(
                any(p == item or (p.endswith("/**") and item.startswith(p[:-3])) for p in paths),
                f"{item} is an input of the published library but not in cmux-mobile-ffi.yml's push paths",
            )

    def test_publish_and_repin_jobs(self):
        build = yaml.safe_load(WORKFLOW.read_text())["jobs"]
        self.assertIn("check-mobile-ffi-pin.sh", json.dumps(build["rust"]["steps"]))
        self.assertIn("refs/heads/feat-cmux-next", build["release"]["if"])
        self.assertIn("cmux-mobile-ffi-release.yml", json.dumps(build["release"]["steps"]))
        self.assertNotIn("secrets.", WORKFLOW.read_text(), "the wildcard-push build workflow reads no secrets")
        release = yaml.safe_load(RELEASE_WORKFLOW.read_text())
        on = release.get("on", release.get(True))
        self.assertEqual(list(on), ["workflow_dispatch"])
        self.assertEqual(sorted(on["workflow_dispatch"]["inputs"]), ["checksum", "run_id", "source"])
        jobs = release["jobs"]
        for name in ("publish", "repin"):
            self.assertEqual(jobs[name].get("environment"), "ffi-release", name)
            self.assertIn("github.ref == 'refs/heads/feat-cmux-next'", jobs[name]["if"], name)
        self.assertIn("publish-mobile-ffi-repin.sh", json.dumps(jobs["repin"]["steps"]))

    def test_ios_package_reads_the_pin(self):
        manifest = (ROOT / "ios/CmuxiOS/Package.swift").read_text()
        self.assertIn("Packages/Shared/CmuxMobileFFI/mobile-ffi-pin.json", manifest)
        self.assertIn('.product(name: "CmuxMobileFFI", package: "CmuxMobileFFI")', manifest)


class Repin(unittest.TestCase):
    """publish-mobile-ffi-repin.sh against a bare remote and a file:// release."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        self.remote = self.tmp / "remote.git"
        self.work = self.tmp / "work"
        self.releases = self.tmp / "releases"
        run(["git", "init", "--quiet", "--bare", "-b", "feat-cmux-next", str(self.remote)])
        run(["git", "init", "--quiet", "-b", "feat-cmux-next", str(self.work)])
        for rel in SCRIPTS:
            dest = self.work / rel
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / rel, dest)
        crate = self.work / "cmux-tui/crates/cmux-mobile-ffi"
        (crate / "src").mkdir(parents=True)
        (crate / "Cargo.toml").write_text('[package]\nname = "cmux-mobile-ffi"\n')
        (crate / "src/lib.rs").write_text("// 1\n")
        (self.work / "cmux-tui/rust-toolchain.toml").write_text("[toolchain]\n")
        pkg = self.work / "Packages/Shared/CmuxMobileFFI"
        pkg.mkdir(parents=True)
        (pkg / "mobile-ffi-pin.json").write_text('{"url": "", "checksum": ""}\n')
        self.git("config", "user.name", "t")
        self.git("config", "user.email", "t@example.com")
        self.git("config", f"url.{self.remote}.insteadOf", "https://github.com/manaflow-ai/cmux.git")
        self.commit("base")
        self.git("push", "--quiet", "https://github.com/manaflow-ai/cmux.git", "HEAD:refs/heads/feat-cmux-next")

    def git(self, *args):
        return run(["git", *args], cwd=self.work).stdout.strip()

    def commit(self, message):
        self.git("add", "-A")
        self.git("commit", "--quiet", "--allow-empty", "-m", message)
        return self.git("rev-parse", "HEAD")

    def advance(self, text):
        """A new FFI source commit on the remote base; returns its sha."""
        self.git("fetch", "--quiet", "https://github.com/manaflow-ai/cmux.git", "feat-cmux-next")
        self.git("checkout", "--quiet", "--force", "--detach", "FETCH_HEAD")
        (self.work / "cmux-tui/crates/cmux-mobile-ffi/src/lib.rs").write_text(text)
        sha = self.commit(f"ffi {text.strip()}")
        self.git("push", "--quiet", "https://github.com/manaflow-ai/cmux.git", "HEAD:refs/heads/feat-cmux-next")
        return sha

    def release(self, sha, bindings):
        directory = self.releases / f"cmux-mobile-ffi-{sha}"
        directory.mkdir(parents=True)
        checksum = hashlib.sha256(sha.encode()).hexdigest()
        (directory / "CmuxMobileFFI.swift").write_text(bindings)
        digest = hashlib.sha256(bindings.encode()).hexdigest()
        (directory / "SHA256SUMS").write_text(
            f"{checksum}  CmuxMobileFFIFFI.xcframework.zip\n{digest}  CmuxMobileFFI.swift\n")
        (directory / "SOURCE_SHA").write_text(sha + "\n")
        return checksum

    def repin(self, sha, checksum, base_pin=True):
        env = dict(CLEAN_ENV, SOURCE=sha, CHECKSUM=checksum, APP_TOKEN="app", GH_TOKEN="",
                   BASE_TOKEN="base", BASE_PIN_ENABLED="true" if base_pin else "false",
                   GITHUB_REPOSITORY="manaflow-ai/cmux",
                   CMUX_MOBILE_FFI_RELEASE_BASE=f"file://{self.releases}")
        return run(["bash", "scripts/cmux-next/publish-mobile-ffi-repin.sh"], cwd=self.work, env=env)

    def remote_pin(self, branch):
        return run(["git", "--git-dir", str(self.remote), "show",
                    f"{branch}:Packages/Shared/CmuxMobileFFI/mobile-ffi-pin.json"], check=False).stdout

    def test_pipeline(self):
        api = "public func feedPushJson(op: String, request: String) -> String {\n}\n"
        first = self.advance("// 2\n")
        out = self.repin(first, self.release(first, api)).stdout
        self.assertIn("first pin", out)
        self.assertIn(first, self.remote_pin("mobile-ffi-repin"))
        self.assertNotIn(first, self.remote_pin("feat-cmux-next"), "the first pin goes through the pull request")

        # Merge that pull request (fast-forward), then an additive release lands on the base.
        tip = run(["git", "--git-dir", str(self.remote), "rev-parse", "mobile-ffi-repin"]).stdout.strip()
        run(["git", "--git-dir", str(self.remote), "update-ref", "refs/heads/feat-cmux-next", tip])
        second = self.advance("// 3\n")
        self.repin(second, self.release(second, api + "public func screenJson(request: String) -> String {\n}\n"))
        self.assertIn(second, self.remote_pin("feat-cmux-next"))

        # An older release finishing late pins nothing.
        out = self.repin(first, hashlib.sha256(first.encode()).hexdigest()).stdout
        self.assertIn("already newer", out)
        self.assertIn(second, self.remote_pin("feat-cmux-next"))

        # A release that drops a public declaration goes through the pull request.
        third = self.advance("// 4\n")
        out = self.repin(third, self.release(third, "public func screenJson(request: String) -> String {\n}\n")).stdout
        self.assertIn("drop or change a public declaration", out)
        self.assertIn(second, self.remote_pin("feat-cmux-next"))
        self.assertIn(third, self.remote_pin("mobile-ffi-repin"))

        # The pinned base passes the check against the release.
        self.git("fetch", "--quiet", "https://github.com/manaflow-ai/cmux.git", "feat-cmux-next")
        self.git("checkout", "--quiet", "--force", "--detach", "FETCH_HEAD")
        self.git("reset", "--quiet", "--hard", "HEAD~1")  # back to the pinned tip, before // 4
        env = dict(CLEAN_ENV, CMUX_MOBILE_FFI_RELEASE_BASE=f"file://{self.releases}")
        out = run(["bash", "scripts/cmux-next/check-mobile-ffi-pin.sh", "--verify-release"], cwd=self.work, env=env).stdout
        self.assertIn("committed bindings", out)


if __name__ == "__main__":
    try:
        unittest.main()
    finally:
        shutil.rmtree(_BIN, ignore_errors=True)
