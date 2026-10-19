#!/usr/bin/env python3
"""scripts/ci/gallery_select.py picks the gallery states gallery-advisory.yml renders.

Fixtures are two pull requests: one that changes a shared stylesheet (every agent-pane entry is
touched; the old sample took the first 16 cases in file order, all of an unrelated entry) and one
that changes a single component. Nothing renders; the script only reads JSON.
"""
from pathlib import Path
import json
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/ci"))
import gallery_select  # noqa: E402

SHA = "a" * 40
BASE = "b" * 40


def cases(entry, variants, themes=("dark", "light")):
    return [
        {"id": f"{entry}--{v}--en--{t}--w420", "path_or_url": "frame.html",
         "params": {"entry": entry, "variant": v, "theme": t, "colorScheme": t}}
        for v in variants for t in themes
    ]


# The manifest lists entries in file order: composer-context (9 variants) before summary-card.
HEAD_ALL = (cases("agent-pane.composer-context", [f"v{i}" for i in range(9)])
            + cases("agent-pane.pr-dock", ["one", "two"])
            + cases("agent-pane.summary-card", ["open", "scrolled", "new-state"]))
BASE_ALL = (cases("agent-pane.composer-context", [f"v{i}" for i in range(9)])
            + cases("agent-pane.pr-dock", ["one", "two", "gone"])
            + cases("agent-pane.summary-card", ["open", "scrolled"]))


def ranked(*rows):
    return {"all": False, "entries": sorted(r[0] for r in rows),
            "ranked": [{"id": i, "tier": t, "why": w, "file": f, "distance": d} for i, t, w, f, d in rows]}


SHARED = ranked(
    ("agent-pane.summary-card", 0, "own", "webviews/src/summary/summary.css", 0),
    ("agent-pane.pr-dock", 3, "same-folder", "webviews/src/summary/summary.css", 0),
    ("agent-pane.composer-context", 4, "host-stylesheet", "webviews/src/summary/summary.css", 0),
)
SINGLE = ranked(("agent-pane.summary-card", 0, "own", "webviews/src/summary/SummaryCard.tsx", 0))


def state_ids(selection):
    return [s["state"] for s in selection["states"]]


class SelectTests(unittest.TestCase):
    def test_shared_file_pr_renders_the_owning_component_first(self):
        head, base, selection = gallery_select.select(SHARED, HEAD_ALL, BASE_ALL, body="", cap=4)
        self.assertEqual(state_ids(selection), [
            "agent-pane.summary-card/open", "agent-pane.summary-card/scrolled",
            "agent-pane.summary-card/new-state", "agent-pane.pr-dock/one"])
        # Both themes of each state, in that order.
        self.assertEqual([c["params"]["theme"] for c in head[:2]], ["dark", "light"])
        self.assertEqual(len(head), 8)
        # The base renders the sampled states it has (not the new one).
        self.assertEqual({c["params"]["variant"] for c in base}, {"open", "scrolled", "one"})
        self.assertEqual(selection["more"], 11)  # 15 states (3 + 3 + 9), 4 shown
        self.assertEqual(selection["states"][0]["selected_by"],
                         {"why": "own", "file": "webviews/src/summary/summary.css", "distance": 0})
        self.assertEqual(selection["states"][2]["status_hint"], "new")

    def test_single_component_pr_renders_only_that_component(self):
        head, base, selection = gallery_select.select(SINGLE, HEAD_ALL, BASE_ALL, body="", cap=16)
        self.assertEqual({s["entry"] for s in selection["states"]}, {"agent-pane.summary-card"})
        self.assertEqual(len(head), 6)
        self.assertEqual(len(base), 4)
        self.assertEqual(selection["more"], 0)

    def test_removed_state_is_rendered_from_the_base(self):
        rows = ranked(("agent-pane.pr-dock", 0, "own", "webviews/src/summary/PullRequestDock.tsx", 0))
        head, base, selection = gallery_select.select(rows, HEAD_ALL, BASE_ALL, body="", cap=16)
        self.assertIn("agent-pane.pr-dock/gone", state_ids(selection))
        self.assertNotIn("gone", {c["params"]["variant"] for c in head})
        self.assertIn("gone", {c["params"]["variant"] for c in base})

    def test_pr_body_override_always_wins(self):
        body = "Fades the card.\r\n\r\nGallery: agent-pane.composer-context/v3, agent-pane.pr-dock\r\n"
        head, _, selection = gallery_select.select(SHARED, HEAD_ALL, BASE_ALL, body=body, cap=16)
        self.assertEqual(state_ids(selection), [
            "agent-pane.composer-context/v3", "agent-pane.pr-dock/one", "agent-pane.pr-dock/two",
            "agent-pane.pr-dock/gone"])
        self.assertEqual(selection["states"][0]["selected_by"], {"why": "pr-body", "file": "", "distance": 0})
        self.assertEqual(selection["override"], ["agent-pane.composer-context/v3", "agent-pane.pr-dock"])

    def test_override_parsing(self):
        self.assertEqual(gallery_select.override_ids("gallery:  `a.b`,c.d/e  f.g\nGallery: h"), ["a.b", "c.d/e", "f.g"])
        self.assertEqual(gallery_select.override_ids("no line here\n  Gallery: x.y"), ["x.y"])
        self.assertEqual(gallery_select.override_ids("Gallery: ../../etc, ok.id"), ["ok.id"])
        self.assertEqual(gallery_select.override_ids(None), [])

    def test_manifest_entries_include_the_override(self):
        self.assertEqual(gallery_select.manifest_entries(SINGLE, "Gallery: agent-pane.pr-dock/one"),
                         ["agent-pane.pr-dock", "agent-pane.summary-card"])


OUTCOMES = [
    {"key": "agent-pane.summary-card--open--en--dark--w420-chromium.png", "id": "agent-pane.summary-card--open--en--dark--w420",
     "entry": "agent-pane.summary-card", "variant": "open", "theme": "dark", "engine": "chromium", "status": "changed",
     "base": "base/agent-pane.summary-card--open--en--dark--w420-chromium.png",
     "head": "head/agent-pane.summary-card--open--en--dark--w420-chromium.png",
     "thumb": "thumbs/agent-pane.summary-card--open--en--dark--w420-chromium.png", "ratio": 0.01234},
    {"key": "agent-pane.summary-card--new-state--en--light--w420-chromium.png", "id": "agent-pane.summary-card--new-state--en--light--w420",
     "entry": "agent-pane.summary-card", "variant": "new-state", "theme": "light", "engine": "chromium", "status": "new",
     "head": "head/agent-pane.summary-card--new-state--en--light--w420-chromium.png", "ratio": 1},
    {"key": "x\"><img src=y>.png", "id": "bad", "entry": "bad<script>", "variant": "v", "theme": "t",
     "engine": "chromium", "status": "changed", "ratio": 0.5},
]


class ReviewTests(unittest.TestCase):
    def review(self):
        _, _, selection = gallery_select.select(SHARED, HEAD_ALL, BASE_ALL, body="", cap=4)
        return gallery_select.review(selection, OUTCOMES, pr=21672, head_sha=SHA, base_sha=BASE,
                                     repo="manaflow-ai/cmux", run_id=123)

    def test_review_manifest_names_images_diff_and_cause(self):
        doc = self.review()
        self.assertEqual(doc["schema"], "cmux.gallery-review.v1")
        self.assertEqual(doc["artifact"], f"gallery-advisory-21672-{SHA}")
        self.assertEqual(doc["head_sha"], SHA)
        self.assertIn(f"name=gallery-advisory-21672-{SHA}", doc["artifact_api"])
        first = doc["images"][0]
        self.assertEqual(first["state"], "agent-pane.summary-card/open")
        self.assertEqual(first["status"], "changed")
        self.assertEqual(first["diff_percent"], 1.234)
        self.assertEqual(first["base_image"], "base/agent-pane.summary-card--open--en--dark--w420-chromium.png")
        self.assertEqual(first["head_image"], "head/agent-pane.summary-card--open--en--dark--w420-chromium.png")
        self.assertEqual(first["before_after"], "diff/thumbs/agent-pane.summary-card--open--en--dark--w420-chromium.png")
        self.assertEqual(first["selected_by"]["file"], "webviews/src/summary/summary.css")
        new = doc["images"][1]
        self.assertIsNone(new["base_image"])
        # An outcome the PR's code could have forged never reaches the manifest.
        self.assertEqual([i["entry"] for i in doc["images"]], ["agent-pane.summary-card"] * 2)

    def test_visual_manifest_matches_the_feed_shape(self):
        doc = gallery_select.visual_manifest(self.review(), generated_at="2026-10-19T22:00:00Z")
        self.assertEqual(doc["schema"], "cmux.visual-manifest.v1")
        self.assertEqual((doc["producer"], doc["head"], doc["base"], doc["pr"]), ("gallery-advisory", SHA, BASE, 21672))
        self.assertEqual(doc["run_url"], "https://github.com/manaflow-ai/cmux/actions/runs/123")
        first, new = doc["states"]
        self.assertEqual(first["id"], "agent-pane.summary-card/open")
        self.assertEqual((first["theme"], first["source"], first["changed"], first["rank_reason"]),
                         ("dark", "webview-gallery", True, "own-source"))
        # Gallery images stay in the run's artifact (#21400): no hosted URL, the path inside it instead.
        self.assertEqual(first["before"], {"url": None, "sha": BASE,
                                           "artifact_path": "base/agent-pane.summary-card--open--en--dark--w420-chromium.png"})
        self.assertEqual(first["after"]["sha"], SHA)
        self.assertIsNone(new["before"])
        self.assertEqual(new["theme"], "light")

    def test_status_section_lists_states_and_the_download_command(self):
        text = gallery_select.section(self.review())
        self.assertIn(SHA[:7], text)
        self.assertIn(f"gh run download 123 -R manaflow-ai/cmux -n gallery-advisory-21672-{SHA}", text)
        self.assertIn("agent-pane.summary-card/open", text)
        self.assertIn("1.23%", text)
        self.assertIn("summary.css", text)
        self.assertIn("11 more", text)
        self.assertNotIn("<img", text)  # images stay in the artifact, not on the public PR (#21400)

    def test_stale_marks_an_older_head(self):
        text = gallery_select.section(self.review())
        stale = gallery_select.stale(text, "c" * 40)
        self.assertTrue(stale.startswith("**Stale**"))
        self.assertIn("ccccccc", stale)
        self.assertIsNone(gallery_select.stale(text, SHA))
        self.assertIsNone(gallery_select.stale(None, SHA))
        self.assertEqual(gallery_select.stale(stale, "d" * 40).count("**Stale**"), 1)

    def test_cli_select_writes_the_three_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            t = Path(tmp)
            (t / "touched.json").write_text(json.dumps(SHARED))
            (t / "head-all.json").write_text(json.dumps(HEAD_ALL))
            (t / "base-all.json").write_text(json.dumps(BASE_ALL))
            subprocess.run([sys.executable, str(ROOT / "scripts/ci/gallery_select.py"), "select",
                            "--touched", str(t / "touched.json"), "--head-all", str(t / "head-all.json"),
                            "--base-all", str(t / "base-all.json"), "--cap", "2", "--out-dir", str(t)],
                           check=True, env={"PR_BODY": ""})
            self.assertEqual(len(json.loads((t / "head.json").read_text())), 4)
            self.assertEqual(json.loads((t / "selection.json").read_text())["more"], 13)


class WorkflowTests(unittest.TestCase):
    """gallery-advisory.yml wires the selection, the receipt and the trusted comment job."""

    @classmethod
    def setUpClass(cls):
        import yaml  # PyYAML ships on the hosted runners
        cls.text = (ROOT / ".github/workflows/gallery-advisory.yml").read_text()
        cls.jobs = yaml.safe_load(cls.text)["jobs"]

    def run_text(self, job):
        return "\n".join(step.get("run", "") for step in self.jobs[job]["steps"])

    def test_capture_uses_the_ranked_selection(self):
        capture = self.run_text("capture")
        self.assertIn("gallery_select.py\" select", capture.replace('"$select"', 'gallery_select.py"'))
        self.assertIn("--visual-out", capture)
        self.assertNotIn(".[0:16]", capture)  # the old file-order sample
        self.assertNotIn("pull-requests", str(self.jobs["capture"].get("permissions", {})))

    def test_comment_job_runs_base_code_with_a_write_token(self):
        job = self.jobs["comment"]
        self.assertEqual(job["permissions"]["pull-requests"], "write")
        checkout = job["steps"][0]
        self.assertEqual(checkout["with"]["ref"], "${{ github.event.pull_request.base.ref }}")
        self.assertIn("scripts/ci/gallery_select.py", checkout["with"]["sparse-checkout"])
        download = job["steps"][1]
        self.assertEqual(download["with"]["name"],
                         "gallery-advisory-${{ github.event.pull_request.number }}-${{ github.event.pull_request.head.sha }}")
        self.assertIn("--section gallery", self.run_text("comment"))
        self.assertIn("gallery", pr_status_sections())

    def test_artifact_name_is_pr_and_exact_head(self):
        upload = [s for s in self.jobs["capture"]["steps"] if "upload-artifact" in s.get("uses", "")][0]
        self.assertEqual(upload["with"]["name"],
                         "gallery-advisory-${{ github.event.pull_request.number }}-${{ github.event.pull_request.head.sha }}")


def pr_status_sections():
    import pr_status
    return pr_status.SECTIONS


if __name__ == "__main__":
    unittest.main()
