"""Tests for scripts/perf-lab/corpus/dev_loop.py and perf-corpus/dev-loop.json (task p12-perf-process-118).

Run: python3 -m unittest scripts/perf-lab/tests/test_corpus_dev_loop.py
"""

import importlib.util
import json
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
CORPUS = HERE.parent / "corpus"
REPO_ROOT = HERE.parents[2]


def load(name, path):
    if name not in sys.modules:
        spec = importlib.util.spec_from_file_location(name, path)
        module = importlib.util.module_from_spec(spec)
        sys.modules[name] = module
        spec.loader.exec_module(module)
    return sys.modules[name]


dl = load("corpus_dev_loop_under_test", CORPUS / "dev_loop.py")
cm = dl.manifest_module()
io_ = dl.session_io()
pty = dl.pty_replay()
wpr = load("corpus_wpr_for_dev_loop", CORPUS / "wpr.py")


def committed():
    return json.loads((REPO_ROOT / dl.MANIFEST_PATH).read_text(encoding="utf-8"))


class CommittedFiles(unittest.TestCase):
    def test_the_committed_files_are_what_the_script_makes(self):
        self.assertEqual(dl.stale(REPO_ROOT), [])

    def test_the_script_is_deterministic(self):
        self.assertEqual(dl.outputs(REPO_ROOT, committed()), dl.outputs(REPO_ROOT, committed()))

    def test_the_manifest_validates_and_fits_in_git(self):
        path = REPO_ROOT / dl.MANIFEST_PATH
        self.assertEqual(cm.validate_paths([path], REPO_ROOT), [])
        for made in dl.outputs(REPO_ROOT, committed()):
            self.assertLessEqual((REPO_ROOT / made).stat().st_size, cm.MAX_GIT_BYTES, made)

    def test_a_lab_recording_is_kept(self):
        digest = "cd" * 32
        current = {**committed(), "status": "recorded",
                   "web_archive": {"wprgo": {"sha256": "ef" * 32, "bytes": 9}, "spki": "B" * 43 + "="},
                   "checkpoints": [{"t_ms": 0, "name": "layout-imported", "focus": digest, "surfaces": digest}]}
        current.pop("planned")
        made = json.loads(dl.outputs(REPO_ROOT, current)[dl.MANIFEST_PATH])
        self.assertEqual(made["status"], "recorded")
        self.assertNotIn("planned", made)
        self.assertEqual(made["web_archive"], current["web_archive"])
        self.assertEqual((made["checkpoints"][0]["focus"], made["checkpoints"][0]["surfaces"]), (digest, digest))
        self.assertIsNone(made["checkpoints"][1]["focus"])


class BuildLog(unittest.TestCase):
    def setUp(self):
        self.data = (REPO_ROOT / dl.BUILD_LOG_PATH).read_bytes()
        self.recording = pty.decode_ttyrec(self.data)

    def bursts(self):
        """Runs of frames WRITE_MS apart."""
        runs = [[self.recording.frames[0]]]
        for frame in self.recording.frames[1:]:
            if frame.offset_ns - runs[-1][-1].offset_ns == dl.WRITE_MS * pty.NS_PER_MS:
                runs[-1].append(frame)
            else:
                runs.append([frame])
        return [run for run in runs if len(run) > 1]

    def test_bursts_run_at_2_mb_per_s(self):
        bursts = self.bursts()
        self.assertEqual([run[0].offset_ns // pty.NS_PER_MS for run in bursts], [start for start, _ in dl.BURSTS])
        for run, (_, size) in zip(bursts, dl.BURSTS):
            self.assertTrue(all(len(frame.data) == dl.WRITE_BYTES for frame in run[:-1]))
            self.assertLessEqual(len(run[-1].data), dl.WRITE_BYTES)
            self.assertGreaterEqual(sum(len(frame.data) for frame in run), size)
            self.assertEqual(dl.WRITE_BYTES * 1000 // dl.WRITE_MS, 2_000_000)
            self.assertTrue(run[-1].data.endswith(b"\r\n"), "a burst ends on a line, so the loop never splits one")

    def test_a_pass_is_pass_ms_of_ascii(self):
        self.assertEqual(self.recording.length_ns, dl.PASS_MS * pty.NS_PER_MS)
        self.recording.data.decode("ascii")
        self.assertTrue(self.recording.data.endswith(b"\r\n"))


class Layout(unittest.TestCase):
    def setUp(self):
        self.manifest = committed()
        self.snapshot = io_.check(json.loads((REPO_ROOT / dl.LAYOUT_PATH).read_text(encoding="utf-8")))

    def tab(self, ref):
        workspace, pane, tab = (int(part[1:]) for part in ref[1:].split("."))
        return io_.leaves(self.snapshot["workspaces"][workspace]["tree"])[pane]["tabs"][tab]

    def test_pty_tracks_play_into_terminals(self):
        self.assertEqual([self.tab(track["surface"]) for track in self.manifest["pty"]], ["terminal", "terminal"])
        self.assertEqual(self.manifest["layout"]["workspaces"], len(self.snapshot["workspaces"]))

    def test_the_docs_tab_is_chromium(self):
        self.assertEqual(self.tab(dl.DOCS + ".t0"), "chromium")

    def test_the_layout_digest_is_the_file(self):
        self.assertEqual(self.manifest["layout"]["snapshot"]["sha256"], io_.digest(self.snapshot))


class InputTrack(unittest.TestCase):
    def setUp(self):
        self.events = committed()["input"]["events"]

    def chords(self, key_code, modifiers):
        return [e for e in self.events if e["kind"] == "key" and e["payload"].get("key_code") == key_code
                and e["payload"]["modifiers"] == modifiers]

    def test_every_round_has_the_story(self):
        for key_code, modifiers in [(dl.KEY_T, ["cmd"]), (dl.KEY_N, ["cmd"]), (dl.KEY_W, ["cmd"]),
                                    (dl.KEY_D, ["cmd"]), (dl.KEY_P, ["cmd", "shift"])]:
            self.assertEqual(len(self.chords(key_code, modifiers)), dl.ROUNDS, key_code)
        actions = [e["payload"]["id"] for e in self.events if e["kind"] == "action"]
        self.assertEqual(actions.count("closePane"), dl.ROUNDS)
        self.assertEqual(actions.count("closeWorkspace"), dl.ROUNDS)
        scrolls = [e for e in self.events if e["kind"] == "mouse"]
        self.assertGreater(len(scrolls), 100 * dl.ROUNDS)
        self.assertTrue(all(e["payload"]["phase"] == "scroll" for e in scrolls))

    def test_typing_is_about_7_keys_per_second(self):
        typed = [e["t_ms"] for e in self.events if e["kind"] == "key" and "key_code" not in e["payload"]]
        gaps = sorted(b - a for a, b in zip(typed, typed[1:]) if b - a <= 200)
        self.assertTrue(110 <= gaps[len(gaps) // 2] <= 160, gaps[len(gaps) // 2])

    def test_return_goes_only_to_the_editor(self):
        """Typed synthetic text never runs: Return only while the editor (pty_replay drops its input) has focus."""
        focus, palette = None, False
        for event in self.events:
            payload = event["payload"]
            if event["kind"] == "action" and payload["id"] == "pane.focus":
                focus = payload["args"]["target"]
            elif event["kind"] == "key" and "cmd" in payload["modifiers"]:
                palette = payload.get("key_code") == dl.KEY_P
                focus = {dl.KEY_D: dl.SPLIT_PANE, dl.KEY_N: dl.NEW_WORKSPACE, dl.KEY_T: "new-tab"}.get(
                    payload.get("key_code"), focus)
            elif event["kind"] == "key" and payload.get("key_code") == dl.KEY_ESCAPE:
                palette = False
            elif event["kind"] == "key" and payload.get("key_code") == dl.KEY_RETURN:
                self.assertEqual((focus, palette), (dl.EDITOR, False), event)

    def test_events_are_in_the_window_and_ordered(self):
        times = [e["t_ms"] for e in self.events]
        self.assertEqual(times, sorted(times))
        self.assertLessEqual(times[-1], dl.DURATION_MS)


class DocsUrls(unittest.TestCase):
    def test_the_url_list_is_public_pages(self):
        urls = wpr.read_urls((REPO_ROOT / "perf-corpus" / "dev-loop" / "docs.urls").read_text(encoding="utf-8"))
        self.assertEqual(len(urls), 1)
        for url in urls:
            self.assertIsNone(wpr.public_url_problem(url, resolver=lambda host: ["151.101.2.137"]))


if __name__ == "__main__":
    unittest.main()
