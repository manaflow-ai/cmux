#!/usr/bin/env python3
"""scripts/cmux-next/media/reel.py, run as the CLI: pull requests come from the notes once
each, clips are picked from the pr-media listing, a build joins title cards and clips into
one reel with a page listing every pull request, `--publish` uploads them to the build's
pr-media folder, and bad notes are refused."""

from __future__ import annotations

import base64
import html
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock
import importlib.util

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/cmux-next/media/reel.py"
# fc-match: drawtext needs fontconfig's default font, or the cards come out blank.
HAS_FFMPEG = bool(shutil.which("ffmpeg") and shutil.which("ffprobe") and shutil.which("fc-match"))
HAS_OPENSSL = bool(shutil.which("openssl"))
RELEASE_NOTES = ROOT / "scripts/cmux-next/release-notes.py"
RAW = "https://raw.githubusercontent.com/manaflow-ai/cmux/pr-media/"
ODD_TITLE = "it's 100%{pts} : a, b; [c] \\ d\nsecond line"
NOTES = {
    "version": 1, "build": "100", "items": [
        {"title": "Tabs keep their order", "author": "Ada", "pr": 11},
        {"title": "Unrelated commit", "author": "Bob"},
        {"title": "Tabs keep their order, part two", "author": "Ada", "pr": 11},
        {"title": "Sidebar: quieter", "author": "Cy", "pr": 22},
        {"title": "Cold start", "author": "Di", "pr": 44},
        {"title": "No media here", "author": "Ed", "pr": 33},
    ],
}
TREE = {"truncated": False, "tree": [{"path": p, "type": "blob"} for p in (
    # 11: two captures; the head fixture names the one that sorts first.
    "11/aaaaaaaa/next-core-after/tour.mp4",
    "11/bbbbbbbb/next-core-after/tour.mp4",
    "11/aaaaaaaa/next-core-before/tour.mp4",
    # 22: two captures and no head, so the pick is by name and says so.
    "22/cccccccc/next-core-after/tour.mp4",
    "22/dddddddd/next-new-tab-after/tour.mp4",
    # 44: only a before clip and a hand-posted clip.
    "44/eeeeeeee/next-core-before/tour.mp4",
    "44/44-cold-before-after.mp4",
    # 33 has nothing; 99 is not in the notes.
    "99/ffffffff/next-core-after/tour.mp4",
)]}


def reel(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run([sys.executable, str(SCRIPT), *args], capture_output=True, text=True, timeout=240)


def write(path: Path, data) -> Path:
    path.write_text(data if isinstance(data, str) else json.dumps(data), encoding="utf-8")
    return path


def duration(path: Path) -> float:
    return float(subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0",
                                 str(path)], capture_output=True, text=True, check=True).stdout)


class DryRunTests(unittest.TestCase):
    def test_plan_from_notes_and_listing(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            done = reel("--build", "100", "--notes", str(write(tmp / "notes.json", NOTES)),
                        "--tree", str(write(tmp / "tree.json", TREE)),
                        "--heads", str(write(tmp / "heads.json", {"11": "aaaaaaaa" + "0" * 32})),
                        "--out", str(tmp / "out"), "--dry-run", "--allow-unsigned")
            self.assertEqual(done.returncode, 0, done.stderr)
            self.assertEqual(sorted(p.name for p in (tmp / "out").iterdir()), ["reel.json"])
            report = json.loads((tmp / "out/reel.json").read_text())
        prs = {p["pr"]: p for p in report["prs"]}
        self.assertEqual([p["pr"] for p in report["prs"]], [11, 22, 44, 33])
        self.assertEqual(prs[11]["title"], "Tabs keep their order")
        self.assertEqual(prs[11]["clip"], RAW + "11/aaaaaaaa/next-core-after/tour.mp4")
        self.assertNotIn("note", prs[11])
        self.assertEqual(prs[22]["clip"], RAW + "22/dddddddd/next-new-tab-after/tour.mp4")
        self.assertIn("head unknown", prs[22]["note"])
        self.assertEqual((prs[44]["source"], prs[44]["clip"]), ("manual", RAW + "44/44-cold-before-after.mp4"))
        self.assertEqual(prs[33]["clip"], "no clip")
        self.assertIsNone(report["reel"])

    def test_notes_without_items_use_the_pr_suffix_of_each_change(self):
        notes = {"build": "100", "changes": ["fix: a (#5)", "chore: b", "fix: c again (#5)", "feat: d (#6)"]}
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            done = reel("--build", "100", "--notes", str(write(tmp / "notes.json", notes)),
                        "--tree", str(write(tmp / "tree.json", {"tree": []})), "--out", str(tmp / "out"), "--dry-run",
                        "--allow-unsigned")
            self.assertEqual(done.returncode, 0, done.stderr)
            report = json.loads((tmp / "out/reel.json").read_text())
        self.assertEqual([(p["pr"], p["title"], p["clip"]) for p in report["prs"]],
                         [(5, "fix: a", "no clip"), (6, "feat: d", "no clip")])


class FfmpegEnvTests(unittest.TestCase):
    def test_ffmpeg_runs_without_the_publish_steps_secrets(self):
        spec = importlib.util.spec_from_file_location("media_reel", SCRIPT)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        seen = {}

        def run(argv, **kwargs):
            seen.update(kwargs["env"])
            return subprocess.CompletedProcess(argv, 0, "", "")

        secrets = {"PR_MEDIA_PRIVATE_TERMS": "secret-host", "GH_TOKEN": "t", "PATH": "/usr/bin"}
        with mock.patch.dict(os.environ, secrets), mock.patch.object(module.subprocess, "run", side_effect=run):
            module.ffmpeg(["-version"], Path("."))
        self.assertEqual(seen.get("PATH"), "/usr/bin")
        self.assertFalse({"PR_MEDIA_PRIVATE_TERMS", "GH_TOKEN"} & set(seen))


@unittest.skipUnless(HAS_FFMPEG, "needs ffmpeg")
class BuildTests(unittest.TestCase):
    def test_two_clips_an_odd_title_and_a_pr_without_a_clip(self):
        notes = {"build": "100", "items": [{"title": ODD_TITLE, "author": "Ada", "pr": 11},
                                           {"title": "Sidebar <b>quieter</b>", "author": "Cy", "pr": 22},
                                           {"title": "No media here", "author": "Ed", "pr": 33},
                                           {"title": "Off-branch clip", "author": "Fa", "pr": 44},
                                           {"title": "Local URL clip", "author": "Gi", "pr": 55}]}
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            for name in ("a", "b"):
                subprocess.run(["ffmpeg", "-nostdin", "-loglevel", "error", "-y", "-f", "lavfi", "-i",
                                "testsrc=size=320x200:rate=10:duration=1", "-pix_fmt", "yuv420p",
                                str(tmp / f"{name}.mp4")], check=True)
            clips = write(tmp / "clips.json", {"11": str(tmp / "a.mp4"), "22": str(tmp / "b.mp4"),
                                                  "44": "https://example.com/x.mp4",
                                                  "55": f"file://{tmp / 'a.mp4'}"})
            out = tmp / "out"
            done = reel("--build", "100", "--notes", str(write(tmp / "notes.json", notes)),
                        "--clips", str(clips), "--out", str(out), "--allow-unsigned")
            self.assertEqual(done.returncode, 0, done.stderr)
            self.assertNotIn("blank card", done.stderr)
            # Two 1.5 s cards and two 1 s clips.
            self.assertAlmostEqual(duration(out / "reel.mp4"), 5.0, delta=0.5)
            page = (out / "index.html").read_text()
            report = json.loads((out / "reel.json").read_text())
        for title in (ODD_TITLE, "Sidebar <b>quieter</b>", "No media here"):
            self.assertIn(html.escape(title), page)
        self.assertNotIn("<b>quieter", page)
        self.assertIn(">#33</a></td><td>No media here</td><td>Ed</td><td>no clip</td>", page)
        self.assertEqual(report["reel"], "reel.mp4")
        self.assertEqual([(p["pr"], p["clip"] == "no clip") for p in report["prs"]],
                         [(11, False), (22, False), (33, True), (44, False), (55, False)])
        # Clips are fetched only from the pr-media branch; a non-https clip is never a link.
        refused = {p["pr"]: p.get("error", "") for p in report["prs"]}
        self.assertIn("refused URL", refused[44])
        self.assertIn("refused URL", refused[55])
        self.assertNotIn('href="file:', page)


# gh: every read is a 404 (nothing published yet); every contents PUT is logged
# with its body and succeeds. Nothing reaches GitHub.
FAKE_GH = r'''#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
if "PUT" in args:
    with open(os.environ["FAKE_GH_LOG"], "a") as log:
        log.write(json.dumps({"route": args[-3], "body": json.loads(sys.stdin.read())}) + "\n")
    print("{}")
else:
    sys.stderr.write("gh: Not Found (HTTP 404)\n")
    sys.exit(1)
'''


class PublishTests(unittest.TestCase):
    @unittest.skipUnless(HAS_FFMPEG, "needs ffmpeg, ffprobe and fontconfig")
    def test_publish_uploads_the_reel_page_and_report_to_the_build_folder(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            subprocess.run(["ffmpeg", "-nostdin", "-loglevel", "error", "-y", "-f", "lavfi", "-i",
                            "testsrc=size=320x200:rate=10:duration=1", "-pix_fmt", "yuv420p",
                            str(tmp / "a.mp4")], check=True)
            gh = tmp / "bin/gh"
            gh.parent.mkdir()
            gh.write_text(FAKE_GH, encoding="utf-8")
            gh.chmod(0o755)
            log = tmp / "gh.jsonl"
            notes = {"build": "100", "items": [{"title": "Tabs keep their order", "author": "Ada", "pr": 11}]}
            out = tmp / "out"
            # As inside .github/actions/pr-media-publish: a made-up terms list instead
            # of this machine's names, and an OCR tool that reads every frame as clean.
            ocr = tmp / "bin/ocr"
            ocr.write_text("#!/bin/sh\necho ok\n", encoding="utf-8")
            ocr.chmod(0o755)
            env = dict(os.environ, PATH=f"{gh.parent}{os.pathsep}{os.environ.get('PATH', '')}", FAKE_GH_LOG=str(log),
                       GITHUB_ACTIONS="true", PR_MEDIA_PUBLISH_GATE="1", PR_MEDIA_PRIVACY_OCR=str(ocr),
                       PR_MEDIA_PRIVATE_TERMS='["glow-box"]')
            done = subprocess.run([sys.executable, str(SCRIPT), "--build", "100",
                                   "--notes", str(write(tmp / "notes.json", notes)), "--allow-unsigned",
                                   "--clips", str(write(tmp / "clips.json", {"11": str(tmp / "a.mp4")})),
                                   "--out", str(out), "--publish"],
                                  capture_output=True, text=True, timeout=240, env=env)
            self.assertEqual(done.returncode, 0, done.stderr)
            puts = [json.loads(line) for line in log.read_text(encoding="utf-8").splitlines()]
            uploaded = {put["route"]: put["body"] for put in puts}
            for name in ("index.html", "reel.json", "reel.mp4"):
                body = uploaded[f"repos/manaflow-ai/cmux/contents/nightly-next/100/{name}"]
                self.assertEqual(body["branch"], "pr-media")
                self.assertEqual(base64.b64decode(body["content"]), (out / name).read_bytes())
                self.assertIn(f"{RAW}nightly-next/100/{name}", done.stdout)
            # The page goes up last, so it never links a reel that failed to upload.
            self.assertEqual([put["route"].rsplit("/", 1)[1] for put in puts], ["reel.mp4", "reel.json", "index.html"])

    def test_publish_is_refused_with_a_dry_run(self):
        done = reel("--build", "100", "--out", "/nonexistent", "--dry-run", "--publish")
        self.assertNotEqual(done.returncode, 0)
        self.assertIn("--publish", done.stderr)


def keypair(directory: Path) -> tuple[Path, str]:
    """A throwaway Ed25519 key: the PEM file and the raw public key in base64."""
    key = directory / "key.pem"
    subprocess.run(["openssl", "genpkey", "-algorithm", "ed25519", "-out", str(key)], check=True, capture_output=True)
    der = subprocess.run(["openssl", "pkey", "-in", str(key), "-pubout", "-outform", "DER"],
                         check=True, capture_output=True).stdout
    return key, base64.b64encode(der[-32:]).decode()


class SignatureTests(unittest.TestCase):
    @unittest.skipUnless(HAS_OPENSSL, "needs openssl")
    def test_notes_signed_with_the_given_key_are_accepted(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            key, public = keypair(tmp)
            notes = write(tmp / "100.json", NOTES)
            subprocess.run([sys.executable, str(RELEASE_NOTES), "sign", "--key", str(key), str(notes)],
                           check=True, capture_output=True)
            done = reel("--build", "100", "--notes", str(notes), "--public-key", public,
                        "--tree", str(write(tmp / "t.json", TREE)), "--out", str(tmp / "out"), "--dry-run")
            self.assertEqual(done.returncode, 0, done.stderr)
            self.assertNotIn("unverified", done.stderr)
            self.assertEqual(len(json.loads((tmp / "out/reel.json").read_text())["prs"]), 4)

    @unittest.skipUnless(HAS_OPENSSL, "needs openssl")
    def test_notes_signed_with_another_key_are_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            key, _ = keypair(tmp)
            notes = write(tmp / "100.json", NOTES)
            subprocess.run([sys.executable, str(RELEASE_NOTES), "sign", "--key", str(key), str(notes)],
                           check=True, capture_output=True)
            done = reel("--build", "100", "--notes", str(notes), "--tree", str(write(tmp / "t.json", TREE)),
                        "--out", str(tmp / "out"), "--dry-run")
            self.assertEqual(done.returncode, 1)
            self.assertIn("bad signature", done.stderr)

    def test_unsigned_notes_are_refused_without_the_flag(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            done = reel("--build", "100", "--notes", str(write(tmp / "100.json", NOTES)),
                        "--tree", str(write(tmp / "t.json", TREE)), "--out", str(tmp / "out"), "--dry-run")
            self.assertEqual(done.returncode, 1)
            self.assertIn("--allow-unsigned", done.stderr)
            self.assertFalse((tmp / "out/reel.json").exists())


class RefusalTests(unittest.TestCase):
    def test_a_bad_signature_is_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            notes = write(tmp / "100.json", NOTES)
            write(tmp / "100.json.sig", "AAAA\n")
            done = reel("--build", "100", "--notes", str(notes), "--tree", str(write(tmp / "t.json", TREE)),
                        "--out", str(tmp / "out"), "--dry-run")
            self.assertEqual(done.returncode, 1)
            self.assertIn("bad signature", done.stderr)
            self.assertFalse((tmp / "out/reel.json").exists())

    def test_notes_for_another_build_are_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            done = reel("--build", "101", "--notes", str(write(tmp / "n.json", NOTES)), "--allow-unsigned",
                        "--tree", str(write(tmp / "t.json", TREE)), "--out", str(tmp / "out"), "--dry-run")
            self.assertEqual(done.returncode, 1)
            self.assertIn("is build 100, not 101", done.stderr)

    def test_notes_without_a_build_are_refused(self):
        notes = {k: v for k, v in NOTES.items() if k != "build"}
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            done = reel("--build", "100", "--notes", str(write(tmp / "n.json", notes)), "--allow-unsigned",
                        "--tree", str(write(tmp / "t.json", TREE)), "--out", str(tmp / "out"), "--dry-run")
            self.assertEqual(done.returncode, 1)
            self.assertIn("is build None, not 100", done.stderr)

    def test_a_build_that_is_not_digits_is_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            done = reel("--build", "../100", "--out", str(Path(tmp) / "out"), "--dry-run")
            self.assertEqual(done.returncode, 1)
            self.assertIn("--build must be digits", done.stderr)

    def test_a_truncated_listing_stops_the_build_unless_allowed(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            args = ["--build", "100", "--notes", str(write(tmp / "n.json", NOTES)), "--allow-unsigned",
                    "--tree", str(write(tmp / "t.json", {**TREE, "truncated": True})),
                    "--out", str(tmp / "out"), "--dry-run"]
            done = reel(*args)
            self.assertEqual(done.returncode, 1)
            self.assertIn("--allow-truncated", done.stderr)
            done = reel(*args, "--allow-truncated")
            self.assertEqual(done.returncode, 0, done.stderr)
            self.assertTrue(json.loads((tmp / "out/reel.json").read_text())["treeTruncated"])


if __name__ == "__main__":
    unittest.main()
