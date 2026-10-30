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
write_out = False
args = sys.argv[1:]
i = 0
while i < len(args):
    a = args[i]
    if a in ("-o", "--output"):
        out = args[i + 1]; i += 2; continue
    if a in ("-w", "--write-out"):
        write_out = True; i += 2; continue
    if a in ("--proto", "--connect-timeout", "--max-time", "--retry", "--retry-delay"):
        i += 2; continue
    if a.startswith("https://"):
        url = a
    i += 1
prefix = "https://files.cmux.com/"
if not url or not url.startswith(prefix):
    sys.exit(2)
path = os.path.join(os.environ["FAKE_R2"], url[len(prefix):].split("?", 1)[0])
if not os.path.isfile(path):
    if write_out:
        sys.stdout.write("404")
    sys.exit(22)
if write_out:
    sys.stdout.write("200")
if out:
    shutil.copyfile(path, out)
else:
    sys.stdout.buffer.write(open(path, "rb").read())
'''

# Write-once like scripts/ci/upload-r2-object.py: identical bytes pass, other
# bytes are an immutable conflict.
# The other run finishes its publication while this one waits: each sleep
# copies FAKE_RACE_DIR into the fake R2 (never over an existing object).
FAKE_SLEEP = r'''#!/usr/bin/env python3
import os, shutil, sys
with open(os.environ["FAKE_SLEEP_LOG"], "a") as log:
    log.write(" ".join(sys.argv[1:]) + "\n")
race = os.environ.get("FAKE_RACE_DIR")
if race and os.environ.get("FAKE_RACE_FINISHES") == "1":
    for root, _, files in os.walk(race):
        for name in files:
            src = os.path.join(root, name)
            dest = os.path.join(os.environ["FAKE_R2"], os.path.relpath(src, race))
            if not os.path.exists(dest):
                os.makedirs(os.path.dirname(dest), exist_ok=True)
                shutil.copyfile(src, dest)
'''

FAKE_UPLOADER = r'''#!/usr/bin/env python3
import argparse, os, shutil, sys
p = argparse.ArgumentParser()
p.add_argument("--write-once", action="store_true")
p.add_argument("--file"); p.add_argument("--endpoint-url"); p.add_argument("--bucket")
p.add_argument("--key"); p.add_argument("--cache-control")
p.add_argument("--conflict-exit-code", type=int)
p.add_argument("--download-to")
a = p.parse_args()
dest = os.path.join(os.environ["FAKE_R2"], a.key)
if os.environ.get("FAKE_UPLOAD_LOG") and not a.download_to:
    with open(os.environ["FAKE_UPLOAD_LOG"], "a") as log:
        log.write(a.key + "\n")
# A read (--download-to), as the real uploader's: exit 22 on a missing object.
# FAKE_DOWNLOAD_FAIL=<key>=<exit> fails that read as a transfer error would,
# after the real uploader's retries.
if a.download_to:
    if os.environ.get("FAKE_READ_LOG"):
        with open(os.environ["FAKE_READ_LOG"], "a") as log:
            log.write(a.key + "\n")
    failing, _, code = os.environ.get("FAKE_DOWNLOAD_FAIL", "").partition("=")
    if failing == a.key:
        print(f"R2 download of s3://{a.bucket}/{a.key} failed: Connection reset by peer", file=sys.stderr)
        sys.exit(int(code))
    if not os.path.isfile(dest):
        print(f"R2 download of s3://{a.bucket}/{a.key} failed: HTTP 404 Not Found", file=sys.stderr)
        sys.exit(22)
    shutil.copyfile(dest, a.download_to)
    sys.exit(0)
body = open(a.file, "rb").read()
# Another run is mid-publication: before this upload lands, it writes the
# objects named in FAKE_RACE (relative keys) from FAKE_OTHER_RUN.
race = os.environ.get("FAKE_RACE_DIR")
if race and os.path.exists(os.path.join(race, a.key)) and not os.path.exists(dest):
    for root, _, files in os.walk(race):
        for name in files:
            src = os.path.join(root, name)
            rel = os.path.relpath(src, race)
            if rel == a.key or rel in os.environ.get("FAKE_RACE_FIRST", "").split(","):
                os.makedirs(os.path.dirname(os.path.join(os.environ["FAKE_R2"], rel)), exist_ok=True)
                shutil.copyfile(src, os.path.join(os.environ["FAKE_R2"], rel))
if a.write_once and os.path.exists(dest):
    if open(dest, "rb").read() == body:
        sys.exit(0)
    if a.conflict_exit_code is not None:
        print(f"another publisher wrote {a.key} first", file=sys.stderr)
        sys.exit(a.conflict_exit_code)
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
        self._exe(self.bin / "sleep", FAKE_SLEEP)
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
            "FAKE_SLEEP_LOG": str(self.root / "sleep.log"),
            # Each run is its own job, as on a runner: a fresh RUNNER_TEMP.
            "RUNNER_TEMP": tempfile.mkdtemp(prefix="runner-temp-", dir=self.root),
            **env,
        }
        return subprocess.run(["bash", "-e", "-c", script], cwd=self.repo, env=full, text=True, capture_output=True)

    def build(self, generation: str, *optional: str, real_checksums: bool = False) -> None:
        """This run's build outputs for the publish job, as the build job leaves them.

        With real_checksums the checksums files are sha256sum output, as
        "Build manifest and checksums" writes them (chatmux-relay has none)."""
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
            if not real_checksums:
                (d / f"{prefix}-checksums.txt").write_text(f"checksums {generation}\n")
            elif prefix != "chatmux-relay":
                (d / f"{prefix}-checksums.txt").write_text(
                    "".join(f"{sha256(d / n)}  {n}\n" for n in sorted(names)))
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

    def test_adopting_reads_each_object_once(self) -> None:
        """The legacy mux/ manifest lists its own checksums file too; the
        reads run side by side, so a second read of one name would race on
        the same local file."""
        self.box.build("1")
        self.assertEqual(self.box.run(self.upload).returncode, 0)
        manifest = json.loads((self.box.r2 / "mux" / self.box.sha / "manifest.json").read_text())
        self.assertIn("cmux-mux-checksums.txt", manifest["binaries"])
        self.box.build("2")
        log = Path(self.tmp.name) / "reads.log"
        result = self.box.run(self.upload, FAKE_READ_LOG=str(log))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        reads = log.read_text().splitlines()
        self.assertIn(f"mux/{self.box.sha}/cmux-mux-checksums.txt", reads)
        self.assertEqual(sorted(reads), sorted(set(reads)), "an object was read twice")

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

    def test_the_tree_verification_reads_every_binary_and_fails_on_any_bad_one(self) -> None:
        """The binaries are read side by side; every one is still checked."""
        self.box.build("1")
        self.assertEqual(self.box.run(self.upload).returncode, 0)
        names = subprocess.check_output(
            ["python3", str(ROOT / "scripts/ci/publish-cmux-tui-tree.py"), "--list-companions"], text=True
        ).split()
        commit = self.box.r2 / "cmux-tui" / self.box.sha
        tree = self.box.repo / "assets" / "tree"
        tree.mkdir(parents=True)
        for n in names:
            (commit / n).write_text(f"{n} build 1\n")
            (tree / n).write_text(f"{n} build 1\n")
        (commit / "manifest.json").write_text(json.dumps({
            "commit": self.box.sha,
            "attestationUrl": "https://github.com/manaflow-ai/cmux/actions/runs/2",
            "binaries": {n: sha256(commit / n) for n in names},
        }))
        key = "a" * 40
        publish = step_script("publish-tree", "Publish the complete tree with the trusted helper")
        self.assertEqual(self.box.run(publish, KEY_V2=key, LEGACY_KEY="").returncode, 0)
        verify = step_script("publish-tree", "Verify the tree publication")
        result = self.box.run(verify, KEY=key, LEGACY_KEY="", CMUX_TUI_PUBLISH_PASS="unix")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        checked = {"cmux-tui-aarch64-apple-darwin", "cmux-tui-x86_64-unknown-linux-musl",
                   "cmux-tui-aarch64-unknown-linux-musl"}
        for n in checked:
            self.assertIn(f"Verified: https://files.cmux.com/cmux-tui/tree/{key}/{n}\n", result.stdout)
        self.assertIn('"commit"', result.stdout, "source.json is printed")
        for n in sorted(checked):
            with self.subTest(corrupt=n):
                published = self.box.r2 / "cmux-tui" / "tree" / key / n
                good = published.read_bytes()
                published.write_bytes(good + b"tampered")
                bad = self.box.run(verify, KEY=key, LEGACY_KEY="", CMUX_TUI_PUBLISH_PASS="unix")
                published.write_bytes(good)
                self.assertNotEqual(bad.returncode, 0, bad.stdout + bad.stderr)
                self.assertNotIn(f"Verified: https://files.cmux.com/cmux-tui/tree/{key}/{n}\n", bad.stdout)

    def test_a_tree_read_that_fails_is_not_taken_for_an_absent_tree(self) -> None:
        """Run 40670486094: the edge reset a companion read (curl exit 92). The reads now go
        to R2; one that still fails after the downloader's retries fails the step, and a
        failed read of source.json never passes for a first publication."""
        names = subprocess.check_output(
            ["python3", str(ROOT / "scripts/ci/publish-cmux-tui-tree.py"), "--list-companions"], text=True
        ).split()
        commit = self.box.r2 / "cmux-tui" / self.box.sha
        commit.mkdir(parents=True)
        for n in names:
            (commit / n).write_text(f"{n} build 1\n")
        (commit / "manifest.json").write_text(json.dumps({
            "commit": self.box.sha,
            "attestationUrl": "https://github.com/manaflow-ai/cmux/actions/runs/1",
            "binaries": {n: sha256(commit / n) for n in names},
        }))
        tree = self.box.repo / "assets" / "tree"
        tree.mkdir(parents=True)
        for n in names:
            (tree / n).write_text(f"{n} build 2\n")
        script = step_script("publish-tree", "Publish the complete tree with the trusted helper")
        key = "a" * 40
        for failing in (f"cmux-tui/tree/{key}/source.json", f"cmux-tui/{self.box.sha}/{names[0]}"):
            with self.subTest(failing=failing):
                result = self.box.run(script, KEY_V2=key, LEGACY_KEY="", FAKE_DOWNLOAD_FAIL=f"{failing}=1")
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("Connection reset by peer", result.stderr)
                self.assertFalse((self.box.r2 / "cmux-tui" / "tree" / key).exists(),
                                 "nothing of the tree is written after a failed read")
        # The same reads, all answered: the tree publishes.
        result = self.box.run(script, KEY_V2=key, LEGACY_KEY="")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue((self.box.r2 / "cmux-tui" / "tree" / key / "completion.json").is_file())

    def test_this_runs_own_published_bytes_are_not_read_back(self) -> None:
        """The usual push: this run published the commit, so its downloaded
        build has the bytes the commit manifest names. Those companions are
        taken from the build (a read of them would fail here); a companion
        whose bytes differ is still read from R2."""
        names = subprocess.check_output(
            ["python3", str(ROOT / "scripts/ci/publish-cmux-tui-tree.py"), "--list-companions"], text=True
        ).split()
        commit = self.box.r2 / "cmux-tui" / self.box.sha
        commit.mkdir(parents=True)
        tree = self.box.repo / "assets" / "tree"
        tree.mkdir(parents=True)
        for n in names:
            (commit / n).write_text(f"{n} build 1\n")
            (tree / n).write_text(f"{n} build 1\n")
        # One companion of this run's build differs from the published one.
        differs = names[-1]
        (tree / differs).write_text(f"{differs} build 2\n")
        (commit / "manifest.json").write_text(json.dumps({
            "commit": self.box.sha,
            "attestationUrl": "https://github.com/manaflow-ai/cmux/actions/runs/2",
            "binaries": {n: sha256(commit / n) for n in names},
        }))
        script = step_script("publish-tree", "Publish the complete tree with the trusted helper")
        key = "a" * 40
        result = self.box.run(script, KEY_V2=key, LEGACY_KEY="",
                              FAKE_DOWNLOAD_FAIL=f"cmux-tui/{self.box.sha}/{names[0]}=1")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(f"Took cmux-tui/{self.box.sha}/{names[0]} from this run's build", result.stdout)
        self.assertNotIn(f"Took cmux-tui/{self.box.sha}/{differs} ", result.stdout)
        published = self.box.r2 / "cmux-tui" / "tree" / key
        for n in names:
            self.assertEqual((published / n).read_bytes(), (commit / n).read_bytes(), n)
        # The differing companion is read from R2: a failed read of it fails the step.
        shutil.rmtree(published)
        # The step leaves the published bytes in assets/tree; a new job starts
        # from its own download again.
        (tree / differs).write_text(f"{differs} build 2\n")
        failed = self.box.run(script, KEY_V2=key, LEGACY_KEY="",
                              FAKE_DOWNLOAD_FAIL=f"cmux-tui/{self.box.sha}/{differs}=1")
        self.assertNotEqual(failed.returncode, 0, failed.stdout + failed.stderr)
        self.assertFalse(published.exists())

    def publish_tree_with_acpmux(self) -> tuple[subprocess.CompletedProcess[str], Path, Path, list[str]]:
        """The commit's earlier publication attests acpmux for the four Unix targets."""
        self.box.build("1")
        self.assertEqual(self.box.run(self.upload).returncode, 0)
        list_names = lambda flag: subprocess.check_output(
            ["python3", str(ROOT / "scripts/ci/publish-cmux-tui-tree.py"), flag], text=True).split()
        names, acpmux = list_names("--list-companions"), list_names("--list-acpmux-companions")
        commit = self.box.r2 / "cmux-tui" / self.box.sha
        for n in names + acpmux:
            (commit / n).write_text(f"{n} build 1\n")
        (commit / "manifest.json").write_text(json.dumps({
            "commit": self.box.sha,
            "attestationUrl": "https://github.com/manaflow-ai/cmux/actions/runs/1",
            "binaries": {n: sha256(commit / n) for n in names + acpmux},
        }))
        tree = self.box.repo / "assets" / "tree"
        tree.mkdir(parents=True, exist_ok=True)
        for n in names:
            (tree / n).write_text(f"{n} build 2\n")
        script = step_script("publish-tree", "Publish the complete tree with the trusted helper")
        result = self.box.run(script, KEY_V2="a" * 40, LEGACY_KEY="")
        return result, commit, self.box.r2 / "cmux-tui" / "tree" / ("a" * 40), acpmux

    def test_a_new_tree_carries_the_commit_acpmux_in_completion_json(self) -> None:
        # hq-1f: acpmux for x86_64/aarch64 musl and aarch64/x86_64 darwin.
        result, commit, published, acpmux = self.publish_tree_with_acpmux()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(len(acpmux), 4)
        gate = json.loads((published / "completion.json").read_text())["binaries"]
        for n in acpmux:
            self.assertEqual((published / n).read_bytes(), (commit / n).read_bytes(), n)
            self.assertEqual(gate[n], sha256(commit / n), n)
            self.assertEqual((published / f"{n}.sha256").read_text(), f"{sha256(commit / n)}  {n}\n")

    def test_a_tree_published_before_acpmux_is_republished_without_a_conflict(self) -> None:
        # The tree's completion.json predates acpmux: it stays byte for byte.
        result, commit, published, acpmux = self.publish_tree_with_acpmux()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        first = (published / "completion.json").read_bytes()
        gate = json.loads(first)["binaries"]
        for n in acpmux:
            (published / n).unlink()
            (published / f"{n}.sha256").unlink()
            del gate[n]
        older = json.loads(first)
        older["binaries"] = gate
        (published / "completion.json").write_text(json.dumps(older, indent=2, sort_keys=True) + "\n")
        before = (published / "completion.json").read_bytes()
        script = step_script("publish-tree", "Publish the complete tree with the trusted helper")
        again = self.box.run(script, KEY_V2="a" * 40, LEGACY_KEY="", GITHUB_RUN_ID="3")
        self.assertEqual(again.returncode, 0, again.stdout + again.stderr)
        self.assertNotIn("immutable-r2-conflict", again.stdout + again.stderr)
        self.assertEqual((published / "completion.json").read_bytes(), before)
        for n in acpmux:
            self.assertFalse((published / n).exists(), n)



class ParallelUploadsOfAClaimedPrefix(unittest.TestCase):
    """A prefix whose checksums file names every file in it is claimed by that
    file: it is written first and alone, the other files go up side by side,
    and manifest.json is still written last."""

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.box = Sandbox(Path(self.tmp.name))
        self.upload = step_script("publish", "Upload to R2")
        self.log = Path(self.tmp.name) / "uploads.log"
        self.other = Path(self.tmp.name) / "other-run"

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def published(self, root: Path | None = None) -> dict[str, bytes]:
        root = root or self.box.r2
        return {str(p.relative_to(root)): p.read_bytes() for p in root.rglob("*") if p.is_file()}

    def uploads(self, prefix: str) -> list[str]:
        start = f"{prefix}/{self.box.sha}/"
        return [k[len(start):] for k in self.log.read_text().splitlines() if k.startswith(start)]

    def test_the_checksums_go_first_and_the_manifest_last(self) -> None:
        self.box.build("1", real_checksums=True)
        result = self.box.run(self.upload, FAKE_UPLOAD_LOG=str(self.log))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        for prefix in ("cmux-tui", "cmux-relay", "mux"):
            with self.subTest(prefix=prefix):
                order = self.uploads(prefix)
                self.assertTrue(order[0].endswith("-checksums.txt"), order)
                self.assertEqual(order[-1], "manifest.json", order)
                local = self.box.repo / ("assets-legacy" if prefix == "mux" else f"assets/{prefix}")
                self.assertEqual(sorted(order), sorted(p.name for p in local.iterdir()))
        # chatmux-relay has no checksums file: it keeps the serial order.
        order = self.uploads("chatmux-relay")
        self.assertEqual(order, sorted(order[:-1]) + ["manifest.json"])

    def test_a_file_the_checksums_do_not_name_keeps_the_serial_order(self) -> None:
        self.box.build("1", real_checksums=True)
        (self.box.repo / "assets/cmux-relay/cmux-relay-extra").write_text("not in the checksums\n")
        result = self.box.run(self.upload, FAKE_UPLOAD_LOG=str(self.log))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        order = self.uploads("cmux-relay")
        self.assertEqual(order, sorted(order))

    def test_a_failed_upload_writes_no_manifest(self) -> None:
        self.box.build("1", real_checksums=True)
        failing = self.box.repo / "scripts/ci/upload-r2-object.py"
        body = failing.read_text()
        failing.write_text(body.replace(
            'body = open(a.file, "rb").read()',
            'body = open(a.file, "rb").read()\nif a.key.endswith("aarch64-apple-darwin") and a.key.startswith("cmux-tui/"):\n    sys.exit(1)',
            1))
        result = self.box.run(self.upload)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn(f"cmux-tui/{self.box.sha}/manifest.json", self.published())

    def test_the_loser_of_the_checksums_race_keeps_the_other_publication(self) -> None:
        self.box.build("1", real_checksums=True)
        self.assertEqual(self.box.run(self.upload).returncode, 0)
        shutil.move(str(self.box.r2), str(self.other))
        self.box.r2.mkdir()
        other = self.published(self.other)
        self.box.build("2", real_checksums=True)
        result = self.box.run(self.upload, FAKE_RACE_DIR=str(self.other), FAKE_RACE_FINISHES="1",
                              FAKE_UPLOAD_LOG=str(self.log))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("immutable-r2-conflict", result.stdout + result.stderr)
        self.assertEqual(self.published(), other)
        # The loser wrote nothing past the checksums file it lost.
        self.assertEqual(self.uploads("cmux-tui"), ["cmux-tui-checksums.txt"])
        for path in (self.box.repo / "assets").rglob("*"):
            if path.is_file():
                key = f"{path.parent.name}/{self.box.sha}/{path.name}"
                self.assertEqual(path.read_bytes(), other[key], key)

    def test_a_run_with_the_same_bytes_completes_an_unfinished_publication(self) -> None:
        self.box.build("1", real_checksums=True)
        self.assertEqual(self.box.run(self.upload).returncode, 0)
        first = self.published()
        # An attempt that stopped before its manifests: the same build again
        # (a re-run) writes identical bytes, which write-once accepts.
        for key in first:
            if key.endswith("/manifest.json"):
                (self.box.r2 / key).unlink()
        result = self.box.run(self.upload, FAKE_UPLOAD_LOG=str(self.log))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("immutable-r2-conflict", result.stdout + result.stderr)
        self.assertEqual(self.published(), first)
        self.assertGreater(len(self.uploads("cmux-tui")), 2)


class WindowsPassKeepsTheFirstPassPrefixes(unittest.TestCase):
    """publish-windows runs the same Upload to R2 step after the first pass
    published every Unix prefix. It keeps them without reading them back
    (21 min of every publish-windows, run 40921878495) and writes only its
    own cmux-tui-windows/<sha>/."""

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.box = Sandbox(Path(self.tmp.name))
        self.upload = step_script("publish", "Upload to R2")

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def published(self) -> dict[str, bytes]:
        return {str(p.relative_to(self.box.r2)): p.read_bytes() for p in self.box.r2.rglob("*") if p.is_file()}

    def windows_build(self) -> Path:
        windows = self.box.repo / "assets" / "cmux-tui-windows"
        windows.mkdir(parents=True)
        exe = windows / "cmux-tui-x86_64-pc-windows-gnu.exe"
        exe.write_text("windows build\n")
        (windows / "cmux-tui-windows-checksums.txt").write_text(f"{sha256(exe)}  {exe.name}\n")
        (windows / "manifest.json").write_text(json.dumps({"commit": self.box.sha, "binaries": {exe.name: sha256(exe)}}))
        return windows

    def test_the_windows_pass_reads_none_of_the_unix_prefixes(self) -> None:
        self.box.build("1", real_checksums=True)
        self.assertEqual(self.box.run(self.upload, CMUX_TUI_PUBLISH_PASS="unix").returncode, 0)
        earlier = self.published()
        self.box.build("1", real_checksums=True)
        self.windows_build()
        # Any read from R2 fails: the Windows pass must not need one.
        result = self.box.run(self.upload, CMUX_TUI_PUBLISH_PASS="windows",
                              FAKE_DOWNLOAD_FAIL=f"cmux-tui/{self.box.sha}/manifest.json=1")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("the Windows pass does not read it back", result.stdout)
        now = self.published()
        self.assertEqual({k: v for k, v in now.items() if not k.startswith("cmux-tui-windows/")}, earlier)
        self.assertIn(f"cmux-tui-windows/{self.box.sha}/manifest.json", now)

    def test_a_missing_legacy_prefix_fails_the_windows_pass(self) -> None:
        self.box.build("1", real_checksums=True)
        self.assertEqual(self.box.run(self.upload, CMUX_TUI_PUBLISH_PASS="unix").returncode, 0)
        shutil.rmtree(self.box.r2 / "mux")
        self.box.build("2", real_checksums=True)
        self.windows_build()
        result = self.box.run(self.upload, CMUX_TUI_PUBLISH_PASS="windows")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("mux prefix missing", result.stdout + result.stderr)
        self.assertFalse((self.box.r2 / "mux").exists(), "this run's bytes are not published under mux/")


class TwoRunsOfOneCommitAtOnce(unittest.TestCase):
    """cx-a1q4d: a lane commit's side-branch run and its fast-forwarded
    feat-cmux-next run build the same commit and publish it at the same time.
    The run that loses a write-once race waits for the other run's
    publication and keeps it: it never fails and never overwrites."""

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.box = Sandbox(Path(self.tmp.name))
        self.upload = step_script("publish", "Upload to R2")
        self.other = Path(self.tmp.name) / "other-run"

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def published(self) -> dict[str, bytes]:
        return {str(p.relative_to(self.box.r2)): p.read_bytes() for p in self.box.r2.rglob("*") if p.is_file()}

    def other_run_publication(self) -> dict[str, bytes]:
        """The other run's complete publication of the commit, moved aside."""
        self.box.build("1")
        self.assertEqual(self.box.run(self.upload).returncode, 0)
        shutil.move(str(self.box.r2), str(self.other))
        self.box.r2.mkdir()
        return {str(p.relative_to(self.other)): p.read_bytes() for p in self.other.rglob("*") if p.is_file()}

    def test_the_loser_of_a_commit_prefix_race_keeps_the_other_publication(self) -> None:
        other = self.other_run_publication()
        self.box.build("2")
        first = sorted(k for k in other if k.startswith(f"cmux-tui/{self.box.sha}/"))[0]
        result = self.box.run(self.upload, FAKE_RACE_DIR=str(self.other), FAKE_RACE_FINISHES="1",
                              FAKE_RACE_FIRST=first)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("immutable-r2-conflict", result.stdout + result.stderr)
        self.assertEqual(self.published(), other)
        for path in (self.box.repo / "assets").rglob("*"):
            if path.is_file():
                key = f"{path.parent.name}/{self.box.sha}/{path.name}"
                self.assertEqual(path.read_bytes(), other[key], key)

    def test_an_other_publication_that_never_completes_fails_after_a_bounded_wait(self) -> None:
        other = self.other_run_publication()
        self.box.build("2")
        first = sorted(k for k in other if k.startswith(f"cmux-tui/{self.box.sha}/"))[0]
        result = self.box.run(self.upload, FAKE_RACE_DIR=str(self.other), FAKE_RACE_FIRST=first,
                              CMUX_R2_ADOPT_WAIT_SECONDS="30")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("immutable-r2-conflict", result.stdout + result.stderr)
        # Nothing of this run's build replaced the other run's object.
        self.assertEqual(self.published()[first], other[first])
        self.assertEqual(len((self.box.root / "sleep.log").read_text().splitlines()), 2)

    def test_the_loser_of_a_tree_race_keeps_the_other_tree(self) -> None:
        names = subprocess.check_output(
            ["python3", str(ROOT / "scripts/ci/publish-cmux-tui-tree.py"), "--list-companions"], text=True
        ).split()
        commit = self.box.r2 / "cmux-tui" / self.box.sha
        commit.mkdir(parents=True)
        for n in names:
            (commit / n).write_text(f"{n} build 1\n")
        (commit / "manifest.json").write_text(json.dumps({
            "commit": self.box.sha,
            "attestationUrl": "https://github.com/manaflow-ai/cmux/actions/runs/1",
            "binaries": {n: sha256(commit / n) for n in names},
        }))
        tree = self.box.repo / "assets" / "tree"
        tree.mkdir(parents=True)
        for n in names:
            (tree / n).write_text(f"{n} build 2\n")
        script = step_script("publish-tree", "Publish the complete tree with the trusted helper")
        key = "a" * 40
        # The other run (the side branch's) publishes the tree first.
        self.assertEqual(self.box.run(script, KEY_V2=key, LEGACY_KEY="",
                                      GITHUB_REF="refs/heads/lane-branch").returncode, 0)
        prefix = f"cmux-tui/tree/{key}"
        other = {k: v for k, v in self.published().items() if k.startswith(prefix + "/")}
        shutil.rmtree(self.box.r2 / prefix)
        (self.other / prefix).parent.mkdir(parents=True)
        for rel, body in other.items():
            dest = self.other / rel
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_bytes(body)
        # This feat-cmux-next run read no source.json, then the other run
        # wrote its own just before this run's write.
        result = self.box.run(script, KEY_V2=key, LEGACY_KEY="", GITHUB_REF="refs/heads/feat-cmux-next",
                              FAKE_RACE_DIR=str(self.other), FAKE_RACE_FINISHES="1",
                              FAKE_RACE_FIRST=f"{prefix}/source.json")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("immutable-r2-conflict", result.stdout + result.stderr)
        mine = {k: v for k, v in self.published().items() if k.startswith(prefix + "/")}
        self.assertEqual(mine, other)
        self.assertEqual(json.loads(mine[f"{prefix}/source.json"])["ref"], "refs/heads/lane-branch")

    def test_a_conflict_after_source_json_stays_a_hard_failure(self) -> None:
        # Only source.json is a race between two publishers; another object of
        # the tree with other bytes is damage, and waiting would hide it.
        names = subprocess.check_output(
            ["python3", str(ROOT / "scripts/ci/publish-cmux-tui-tree.py"), "--list-companions"], text=True
        ).split()
        commit = self.box.r2 / "cmux-tui" / self.box.sha
        commit.mkdir(parents=True)
        for n in names:
            (commit / n).write_text(f"{n} build 1\n")
        (commit / "manifest.json").write_text(json.dumps({
            "commit": self.box.sha,
            "attestationUrl": "https://github.com/manaflow-ai/cmux/actions/runs/1",
            "binaries": {n: sha256(commit / n) for n in names},
        }))
        tree = self.box.repo / "assets" / "tree"
        tree.mkdir(parents=True)
        key = "a" * 40
        damaged = self.box.r2 / "cmux-tui" / "tree" / key / names[0]
        damaged.parent.mkdir(parents=True)
        damaged.write_text("other bytes\n")
        script = step_script("publish-tree", "Publish the complete tree with the trusted helper")
        result = self.box.run(script, KEY_V2=key, LEGACY_KEY="")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("immutable-r2-conflict", result.stdout + result.stderr)
        self.assertFalse((self.box.root / "sleep.log").exists())
        self.assertEqual(damaged.read_text(), "other bytes\n")


if __name__ == "__main__":
    unittest.main()
