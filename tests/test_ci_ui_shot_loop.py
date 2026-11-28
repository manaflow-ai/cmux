"""scripts/ci/ui_shot_loop.py: pairing renders, the gate, the comment."""

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "scripts" / "ci" / "ui_shot_loop.py"
PNG = bytes.fromhex("89504e470d0a1a0a")


def run(*args):
    return subprocess.run([sys.executable, "-I", str(SCRIPT), *args], capture_output=True, text=True, check=True).stdout


def render(root: Path, names):
    root.mkdir(parents=True)
    rows = []
    for n in names:
        (root / f"{n}.png").write_bytes(PNG)
        rows.append({"id": n, "screenshot": f"{n}.png", "ready": True, "params": {"colorScheme": "dark"}})
    (root / "results.json").write_text(json.dumps(rows))


class UiShotLoopTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())

    def stage(self, base, head):
        render(self.tmp / "b", base)
        render(self.tmp / "h", head)
        run("stage", "--base", str(self.tmp / "b"), "--head", str(self.tmp / "h"), "--out", str(self.tmp / "s"))
        return json.loads((self.tmp / "s" / "states.json").read_text())

    def test_stage_marks_new_and_removed(self):
        states = {s["name"]: s["state"] for s in self.stage(["a", "gone"], ["a", "fresh"])}
        self.assertEqual(states, {"web/a": "changed", "web/gone": "removed", "web/fresh": "new"})
        self.assertTrue((self.tmp / "s/base/web/a.png").is_file())
        self.assertFalse((self.tmp / "s/heads/web/gone.png").exists())

    def gate(self, status, **kw):
        self.stage(["a"], ["a"])
        report = self.tmp / "r.json"
        report.write_text(json.dumps({"entries": [{"name": "web/a", "status": status}]}))
        args = ["gate", "--report", str(report), "--states", str(self.tmp / "s/states.json")]
        if "labels" in kw:
            args += ["--labels", kw["labels"]]
        if "body" in kw:
            (self.tmp / "body").write_text(kw["body"])
            args += ["--body", str(self.tmp / "body")]
        return run(*args).split("\t")[0]

    def test_gate(self):
        self.assertEqual(self.gate("pass"), "success")
        self.assertEqual(self.gate("fail"), "failure")
        self.assertEqual(self.gate("fail", labels="x,ui-shot-intended"), "success")
        self.assertEqual(self.gate("fail", body="Visual-change: web/a: wanted"), "success")
        self.assertEqual(self.gate("fail", body="no line"), "failure")

    def test_comment_embeds_pr_media_images(self):
        self.stage(["a"], ["a"])
        report = self.tmp / "r.json"
        report.write_text(json.dumps({"entries": [{"name": "web/a", "status": "fail",
                                                   "verdict": {"changed_ratio": 0.02, "ssim": 0.9}}]}))
        media = self.tmp / "m"
        media.mkdir()
        (media / "ui-shot-web_a-base.png").write_bytes(PNG)
        out = run("comment", "--report", str(report), "--states", str(self.tmp / "s/states.json"),
                  "--media-dir", str(media), "--pr", "7", "--sha", "a" * 40, "--repo", "o/r")
        self.assertTrue(out.startswith("<!-- cmux-ui-shot-loop -->"))
        self.assertIn("raw.githubusercontent.com/o/r/pr-media/7%2Fui-shot-web_a-base.png", out)
        self.assertIn("2.00% px", out)


if __name__ == "__main__":
    unittest.main()
