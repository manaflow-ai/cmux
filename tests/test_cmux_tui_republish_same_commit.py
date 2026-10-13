"""A second build of an already-published commit still publishes its tree.

Two cmux-tui-artifacts runs can build one commit at different times: a push
to a pull request branch, then a cmux-tui-pin-<sha> branch for the same
commit after the first run finished (the same-SHA owner election only sees
runs still in progress). The rebuild is not byte-identical, so its upload of
the write-once cmux-tui/<sha>/ objects used to stop with
immutable-r2-conflict, and the tree path was never published (op-next-launch,
da22005cd79a). These tests run the real publish and publish-tree steps
against a fake R2 to check the rebuild reuses the earlier publication.
"""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import stat
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "cmux-tui-artifacts.yml"

# Answers https://files.cmux.com/<key> from the fake R2 directory, as curl -f
# does: exit 22 when the object is missing.
FAKE_CURL = r'''#!/usr/bin/env python3
import os, shutil, sys
out = None
url = None
args = sys.argv[1:]
i = 0
while i < len(args):
    a = args[i]
    if a in ("-o", "--output"):
        out = args[i + 1]; i += 2; continue
    if a in ("--proto", "--connect-timeout", "--max-time", "--retry", "--retry-delay", "-w", "--write-out"):
        i += 2; continue
    if a.startswith("https://"):
        url = a
    i += 1
prefix = "https://files.cmux.com/"
if not url or not url.startswith(prefix):
    sys.exit(2)
path = os.path.join(os.environ["FAKE_R2"], url[len(prefix):].split("?", 1)[0])
if not os.path.isfile(path):
    sys.exit(22)
if out:
    shutil.copyfile(path, out)
else:
    sys.stdout.buffer.write(open(path, "rb").read())
'''

# Write-once like scripts/ci/upload-r2-object.py: identical bytes pass, other
# bytes are an immutable conflict.
FAKE_UPLOADER = r'''#!/usr/bin/env python3
import argparse, os, shutil, sys
p = argparse.ArgumentParser()
p.add_argument("--write-once", action="store_true")
p.add_argument("--file"); p.add_argument("--endpoint-url"); p.add_argument("--bucket")
p.add_argument("--key"); p.add_argument("--cache-control")
a = p.parse_args()
dest = os.path.join(os.environ["FAKE_R2"], a.key)
body = open(a.file, "rb").read()
if a.write_once and os.path.exists(dest):
    if open(dest, "rb").read() == body:
        sys.exit(0)
    print(f"::error title=immutable-r2-conflict::{a.key} already exists with other bytes")
    sys.exit(1)
os.makedirs(os.path.dirname(dest), exist_ok=True)
shutil.copyfile(a.file, dest)
'''


def step_script(job: str, name: str) -> str:
    doc = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
    for step in doc["jobs"][job]["steps"]:
        if step.get("name") == name:
            return step["run"]
    raise AssertionError(f"{job} has no step {name!r}")


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


class Sandbox:
    """A checkout of one commit, a fake R2 and the stubs the steps call."""

    def __init__(self, root: Path) -> None:
        self.root = root
        self.repo = root / "repo"
        self.r2 = root / "r2"
        self.bin = root / "bin"
        for d in (self.repo, self.r2, self.bin):
            d.mkdir()
        for d in ("cmux-tui", "ghostty", "ghostty-next"):
            (self.repo / d).mkdir()
            (self.repo / d / "README").write_text(d)
        git = ["git", "-C", str(self.repo), "-c", "user.name=t", "-c", "user.email=t@example.com"]
        subprocess.run(["git", "init", "-q", str(self.repo)], check=True)
        subprocess.run([*git, "add", "."], check=True)
        subprocess.run([*git, "commit", "-qm", "c"], check=True)
        self.sha = subprocess.check_output(["git", "-C", str(self.repo), "rev-parse", "HEAD"], text=True).strip()
        self._exe(self.bin / "curl", FAKE_CURL)
        self._exe(self.repo / "scripts/ci/upload-r2-object.py", FAKE_UPLOADER)
        shutil.copy(ROOT / "scripts/ci/publish-cmux-tui-tree.py", self.repo / "scripts/ci/publish-cmux-tui-tree.py")
        self._exe(self.repo / "scripts/cmux-next/pin-cmux-tui.sh", '#!/bin/sh\necho "$FAKE_TREE_KEY"\n')
        subprocess.run(["git", "-C", str(self.repo), "update-index", "--refresh"], capture_output=True)

    @staticmethod
    def _exe(path: Path, body: str) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(body)
        path.chmod(path.stat().st_mode | stat.S_IXUSR)

    def run(self, script: str, **env: str) -> subprocess.CompletedProcess[str]:
        full = {
            "PATH": f"{self.bin}:{os.environ['PATH']}",
            "HOME": str(self.root),
            "FAKE_R2": str(self.r2),
            "FAKE_TREE_KEY": "a" * 40,
            "GITHUB_SHA": self.sha,
            "GITHUB_REF": "refs/heads/cmux-tui-pin-" + self.sha[:12],
            "GITHUB_RUN_ID": "2",
            "GITHUB_SERVER_URL": "https://github.com",
            "GITHUB_REPOSITORY": "manaflow-ai/cmux",
            "R2_ENDPOINT": "https://r2.invalid",
            **env,
        }
        return subprocess.run(["bash", "-e", "-c", script], cwd=self.repo, env=full, text=True, capture_output=True)

    def build(self, generation: str, *optional: str) -> None:
        """This run's build outputs for the publish job, as the build job leaves them."""
        assets = self.repo / "assets"
        shutil.rmtree(assets, ignore_errors=True)
        for prefix, names in {
            "cmux-tui": ["cmux-tui-x86_64-unknown-linux-musl", "cmux-tui-aarch64-apple-darwin", *optional],
            "cmux-relay": ["cmux-relay-x86_64-unknown-linux-musl"],
            "chatmux-relay": ["chatmux-relay-x86_64-unknown-linux-musl"],
        }.items():
            d = assets / prefix
            d.mkdir(parents=True)
            for n in names:
                (d / n).write_text(f"{n} build {generation}\n")
            (d / f"{prefix}-checksums.txt").write_text(f"checksums {generation}\n")
            (d / "manifest.json").write_text(json.dumps({
                "commit": self.sha,
                "attestationUrl": f"https://github.com/manaflow-ai/cmux/actions/runs/{generation}",
                "binaries": {n: sha256(d / n) for n in names},
            }))


class RebuildOfAPublishedCommit(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.box = Sandbox(Path(self.tmp.name))
        self.upload = step_script("publish", "Upload to R2")

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def published(self) -> dict[str, bytes]:
        return {str(p.relative_to(self.box.r2)): p.read_bytes() for p in self.box.r2.rglob("*") if p.is_file()}

    def test_a_first_publication_uploads_every_prefix(self) -> None:
        self.box.build("1")
        result = self.box.run(self.upload)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        for prefix in ("cmux-tui", "cmux-relay", "chatmux-relay", "mux"):
            self.assertIn(f"{prefix}/{self.box.sha}/manifest.json", self.published())

    def test_a_byte_different_rebuild_reuses_the_earlier_publication(self) -> None:
        self.box.build("1")
        self.assertEqual(self.box.run(self.upload).returncode, 0)
        earlier = self.published()
        self.box.build("2")
        result = self.box.run(self.upload)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("immutable-r2-conflict", result.stdout + result.stderr)
        self.assertEqual(self.published(), earlier)
        # The rolling latest publish and the verify steps read the local
        # copy, so it must be the bytes the commit prefix serves.
        for path in (self.box.repo / "assets").rglob("*"):
            if path.is_file():
                key = f"{path.parent.name}/{self.box.sha}/{path.name}"
                self.assertEqual(path.read_bytes(), earlier[key], key)
        for path in (self.box.repo / "assets-legacy").iterdir():
            self.assertEqual(path.read_bytes(), earlier[f"mux/{self.box.sha}/{path.name}"], path.name)

    def test_a_rebuild_with_other_optional_binaries_keeps_the_published_set(self) -> None:
        # The agent screen detector is optional: either build may lack it.
        detector = "cmux-tui-agent-screen-detection-aarch64-apple-darwin"
        for earlier_has, rebuild_has in ((True, False), (False, True)):
            with self.subTest(earlier_has=earlier_has):
                shutil.rmtree(self.box.r2)
                self.box.r2.mkdir()
                self.box.build("1", *([detector] if earlier_has else []))
                self.assertEqual(self.box.run(self.upload).returncode, 0)
                earlier = self.published()
                self.box.build("2", *([detector] if rebuild_has else []))
                result = self.box.run(self.upload)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                local = self.box.repo / "assets" / "cmux-tui"
                served = {k.rsplit("/", 1)[1] for k in earlier if k.startswith(f"cmux-tui/{self.box.sha}/")}
                self.assertEqual({p.name for p in local.iterdir()}, served)

    def test_the_tree_is_published_from_the_earlier_publication(self) -> None:
        self.box.build("1")
        self.assertEqual(self.box.run(self.upload).returncode, 0)
        names = subprocess.check_output(
            ["python3", str(ROOT / "scripts/ci/publish-cmux-tui-tree.py"), "--list-companions"], text=True
        ).split()
        commit = self.box.r2 / "cmux-tui" / self.box.sha
        # The earlier run's companions; its manifest names their digests.
        for n in names:
            (commit / n).write_text(f"{n} build 1\n")
        (commit / "manifest.json").write_text(json.dumps({
            "commit": self.box.sha,
            "attestationUrl": "https://github.com/manaflow-ai/cmux/actions/runs/1",
            "binaries": {n: sha256(commit / n) for n in names},
        }))
        # This run's build (the tree job's downloaded artifacts) differs.
        tree = self.box.repo / "assets" / "tree"
        tree.mkdir(parents=True)
        for n in names:
            (tree / n).write_text(f"{n} build 2\n")
        script = step_script("publish-tree", "Publish the complete tree with the trusted helper")
        result = self.box.run(script, KEY_V2="a" * 40, LEGACY_KEY="")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        published = self.box.r2 / "cmux-tui" / "tree" / ("a" * 40)
        self.assertTrue((published / "completion.json").is_file())
        for n in names:
            self.assertEqual((published / n).read_bytes(), (commit / n).read_bytes(), n)
        # Provenance names the run that built them (bundle-cmux-tui.sh stamps it).
        self.assertEqual(json.loads((published / "source.json").read_text())["run"], "1")


if __name__ == "__main__":
    unittest.main()
