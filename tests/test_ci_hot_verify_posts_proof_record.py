"""post the look posts the cmux/ui-proof record itself, so the gate passes with no hand-run `--record` look.

2026-11-27: cmux#61956's look had already run in this workflow, but cmux/ui-proof stayed pending until a lane built
and posted the record by hand (ui_proof_verdict.py record --post).
"""
import json, pathlib, struct, subprocess, sys, tempfile, unittest, zlib

import yaml

ROOT = pathlib.Path(__file__).resolve().parents[1]
WF = ROOT / ".github/workflows/cmux-next-hot-verify.yml"
sys.path.insert(0, str(ROOT / "scripts/ci"))
import proof_record  # noqa: E402


def png(path, rgb, w=4, h=4):
    raw = b"".join(b"\x00" + bytes(rgb) * w for _ in range(h))
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
                     + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


class PostsProofRecord(unittest.TestCase):
    def setUp(self):
        self.jobs = yaml.safe_load(WF.read_text())["jobs"]
        self.steps = {s.get("name"): s for s in self.jobs["publish"]["steps"]}

    def test_the_step_posts_as_a_trusted_app_and_reruns_the_gate(self):
        s = self.steps["Post the proof record"]
        self.assertIn("needs_build == 'false'", s["if"])
        self.assertIn("inputs.kind != 'merge'", s["if"])
        self.assertTrue(s["continue-on-error"])
        self.assertIn("CI_POOL_GH_TOKEN", s["env"]["POST_TOKEN"])
        self.assertIn("ui_proof_verdict.py record", s["run"])
        self.assertIn('GH_TOKEN="$POST_TOKEN" gh pr comment', s["run"])
        self.assertIn("rerun_gate", s["run"])
        names = list(self.steps)
        self.assertGreater(names.index("Post the proof record"), names.index("Check, upload and comment"))

    def test_every_publisher_checkout_carries_the_record_scripts(self):
        sparse = [s["with"]["sparse-checkout"] for s in self.jobs["publish"]["steps"]
                  if "sparse-checkout" in (s.get("with") or {})]
        self.assertGreaterEqual(len(sparse), 2)
        for text in sparse:
            self.assertIn("scripts/ci/ui_proof_verdict.py", text)
            self.assertIn("scripts/ci/proof_record.py", text)

    def test_the_command_the_step_runs_builds_a_record_the_gate_reads(self):
        head = "a" * 40
        with tempfile.TemporaryDirectory() as d:
            out = pathlib.Path(d)
            png(out / "before/light.png", (10, 10, 10))
            png(out / "after/light.png", (200, 10, 10))
            (out / "receipt.json").write_text(json.dumps({"plan": {"head": head, "layers": ["web"]}, "errors": [],
                                                          "app": {"commit": "b" * 40}}))
            done = subprocess.run([sys.executable, str(ROOT / "scripts/ci/ui_proof_verdict.py"), "record", "--out", d,
                                   "--pr", "1", "--repo", "manaflow-ai/cmux", "--head", head, "--pushed-at",
                                   "1795790000"], capture_output=True, text=True)
            self.assertEqual(done.returncode, 0, done.stderr)
            record = proof_record.parse((out / "proof-record.md").read_text())
            self.assertIsNotNone(record)
            self.assertEqual(record["verdict"], "pass")
            self.assertEqual(record["head_sha"], head)
            self.assertIn("push_to_proof_s", record["timing"])

    def test_a_failing_look_still_posts_its_record_under_bash_e(self):
        """cmux#55190, 2026-11-27: the look ran and failed (the fleet NIGHTLY's web ABI 7, the head's overlay 9), the
        record command exited 1, the step's `bash -e` ended it before the post, and cmux/ui-proof said "no look at
        this head" for 5 h. The step's own script runs here as Actions runs it, with gh stubbed."""
        head = "c" * 40
        with tempfile.TemporaryDirectory() as d:
            out, bin_ = pathlib.Path(d) / "out", pathlib.Path(d) / "bin"
            png(out / "before/light.png", (10, 10, 10))
            (out / "receipt.json").write_text(json.dumps({
                "plan": {"head": head, "layers": ["web"]}, "app": {"commit": "b" * 40},
                "errors": ["LookError: web-overlay.sh install: needs web ABI 9, the app has web ABI 7"]}))
            bin_.mkdir()
            calls = pathlib.Path(d) / "gh-calls"
            (bin_ / "gh").write_text(f'#!/bin/sh\necho "$@" >> {calls}\n')
            (bin_ / "gh").chmod(0o755)
            env = {"PATH": f"{bin_}:/usr/bin:/bin", "PR": "55190", "HEAD_SHA": head, "OUT": str(out),
                   "EVENT_AT": "1795806738", "GITHUB_REPOSITORY": "manaflow-ai/cmux", "POST_TOKEN": "x",
                   "GITHUB_STEP_SUMMARY": str(pathlib.Path(d) / "summary"), "PYTHONPATH": ""}
            done = subprocess.run(["bash", "-e", "-c", self.steps["Post the proof record"]["run"]], cwd=ROOT, env=env,
                                  capture_output=True, text=True)
            self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
            self.assertEqual(proof_record.parse((out / "proof-record.md").read_text())["verdict"], "fail")
            self.assertIn("pr comment 55190", calls.read_text())


if __name__ == "__main__":
    unittest.main()
