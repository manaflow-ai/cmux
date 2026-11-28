#!/usr/bin/env python3
"""Nightly jobs check the build ref out from this run's pack, not from github.com (scripts/ci/nightly-source.sh).

Leo: "are nightlies not publishin? where the priority?" and "can you help us on the nightlies :o". Run
46101546346 fetched the build ref from github.com in prepare (after the fleet shim's 90 s mirror wait),
in signing and in the signed-nightly verify. resolve-nightly-cmux-tui-client now packs the build
commit once; every job that checks the build ref out unpacks it first and runs actions/checkout only
when that failed. This test holds

  (a) pack then unpack gives a sparse, shallow checkout of the commit with no network, into an empty
      workspace and into a reused one that already holds the history (which stays unshallow);
  (b) a bad pack fails without leaving a sparse setting for the fallback checkout;
  (c) every nightly.yml actions/checkout of the build ref without submodules sits right after the
      unpack step and is skipped when it succeeded, and resolve uploads the pack under the name the
      jobs download. The recursive-submodule checkouts (the app builds) still fetch through the shim.
"""
from __future__ import annotations

import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/nightly-source.sh"
WORKFLOW = ROOT / ".github/workflows/nightly.yml"
BUILD_SHA = "needs.resolve-nightly-cmux-tui-client.outputs.build_sha"


def git(cwd: Path, *args: str) -> str:
    return subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True, text=True).stdout.strip()


class PackUnpack(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp())
        src = self.tmp / "src"
        src.mkdir()
        git(src, "init", "-q")
        for rel, body in {"README": "1", "cmux-next-ios/verify/big.png": "media",
                          "cmux-next-ios/app/a.swift": "app", "a/b/sp ace.txt": "x"}.items():
            (src / rel).parent.mkdir(parents=True, exist_ok=True)
            (src / rel).write_text(body)
        git(src, "add", "-A")
        git(src, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "one")
        (src / "README").write_text("2")
        git(src, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qam", "two")
        self.src, self.sha = src, git(src, "rev-parse", "HEAD")

    def run_script(self, *args: str, workspace: Path, out: Path | None = None) -> subprocess.CompletedProcess:
        env = {**os.environ, "GITHUB_WORKSPACE": str(workspace), "GIT_NO_LAZY_FETCH": "1",
               "GITHUB_SERVER_URL": "https://example.invalid", "GITHUB_REPOSITORY": "o/r"}
        env.pop("GITHUB_OUTPUT", None)
        if out:
            env["GITHUB_OUTPUT"] = str(out)
        return subprocess.run(["bash", *args], env=env, capture_output=True, text=True)

    def pack(self, name: str) -> Path:
        out = self.tmp / name
        done = self.run_script(str(SCRIPT), "pack", self.sha, str(out), workspace=self.src)
        self.assertEqual(done.returncode, 0, done.stderr)
        return out

    def files(self, ws: Path) -> set[str]:
        return {str(p.relative_to(ws)) for p in ws.rglob("*") if p.is_file() and ".git" not in p.parts}

    def test_unpack_into_an_empty_workspace(self) -> None:
        pack, ws, out = self.pack("p1"), self.tmp / "ws", self.tmp / "out"
        done = self.run_script(str(pack / "unpack.sh"), "unpack", self.sha, str(pack), workspace=ws, out=out)
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn("github.com git fetches this job: 0", done.stdout)
        self.assertEqual(out.read_text().strip(), "ok=true")
        self.assertEqual(git(ws, "rev-parse", "HEAD"), self.sha)
        self.assertEqual(self.files(ws), {"README", "cmux-next-ios/app/a.swift", "a/b/sp ace.txt"})
        self.assertEqual((ws / ".git/shallow").read_text().split(), [self.sha])
        self.assertEqual(git(ws, "status", "--porcelain"), "")
        self.assertFalse(pack.exists(), "the unpacked pack is removed")

    def test_unpack_into_a_reused_workspace_keeps_its_history(self) -> None:
        pack, ws = self.pack("p2"), self.tmp / "ws2"
        subprocess.run(["git", "clone", "-q", str(self.src), str(ws)], check=True)
        (ws / "left-over").write_text("x")
        done = self.run_script(str(pack / "unpack.sh"), "unpack", self.sha, str(pack), workspace=ws)
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertFalse((ws / ".git/shallow").exists())
        self.assertNotIn("left-over", self.files(ws))
        self.assertEqual(git(ws, "remote", "get-url", "origin"), "https://example.invalid/o/r")

    def test_a_bad_pack_fails_and_leaves_no_sparse_setting(self) -> None:
        pack, ws, out = self.pack("p3"), self.tmp / "ws3", self.tmp / "out3"
        (pack / "source.pack").write_bytes(b"not a pack")
        done = self.run_script(str(pack / "unpack.sh"), "unpack", self.sha, str(pack), workspace=ws, out=out)
        self.assertNotEqual(done.returncode, 0)
        self.assertFalse(out.exists() and "ok=true" in out.read_text())
        self.assertEqual(subprocess.run(["git", "config", "core.sparseCheckout"], cwd=ws).returncode, 1)


class Wiring(unittest.TestCase):
    def test_every_build_ref_checkout_follows_the_unpack(self) -> None:
        jobs = yaml.safe_load(WORKFLOW.read_text())["jobs"]
        consumers = 0
        for job_id, job in jobs.items():
            steps = job.get("steps") or []
            for i, step in enumerate(steps):
                uses = str(step.get("uses") or "")
                ref = str((step.get("with") or {}).get("ref") or "")
                if not (uses.startswith("actions/checkout@") and BUILD_SHA in ref):
                    continue
                if str((step.get("with") or {}).get("submodules")) == "recursive":
                    continue  # the app builds also need every submodule; the fleet shim serves those
                consumers += 1
                with self.subTest(job=job_id):
                    self.assertEqual(steps[i - 1].get("id"), "nightly-source")
                    self.assertEqual(steps[i - 2].get("id"), "nightly-source-get")
                    self.assertIn("steps.nightly-source.outputs.ok != 'true'", str(step.get("if")))
        self.assertGreaterEqual(consumers, 9)
        resolve = jobs["resolve-nightly-cmux-tui-client"]["steps"]
        upload = next(s for s in resolve if s.get("name") == "Upload the build source")
        self.assertEqual(upload["with"]["name"], "nightly-source-${{ steps.build.outputs.build_sha }}")
        download = next(s for s in jobs["verify-signed-nightly"]["steps"] if s.get("id") == "nightly-source-get")
        self.assertEqual(download["with"]["name"], f"nightly-source-${{{{ {BUILD_SHA} }}}}")


if __name__ == "__main__":
    unittest.main(verbosity=1)
