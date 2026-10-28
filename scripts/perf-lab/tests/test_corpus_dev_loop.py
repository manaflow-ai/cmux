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
                   "checkpoints": [{"t_ms": 0, "name": "layout-imported", "focus": digest, "surfaces": digest}]}
        current.pop("planned")
        made = json.loads(dl.outputs(REPO_ROOT, current)[dl.MANIFEST_PATH])
        self.assertEqual(made["status"], "recorded")
        self.assertNotIn("planned", made)
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

    def test_no_web_archive_is_claimed(self):
        """No player step loads an archived URL into a layout tab, so the story claims no archive: the docs tab
        scrolls the page the layout import gives it."""
        self.assertIsNone(self.manifest["web_archive"])
        self.assertNotIn("Web Page Replay", self.manifest["description"])
        self.assertFalse((REPO_ROOT / "perf-corpus" / "dev-loop" / "docs.urls").exists())

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
                                    (dl.KEY_W, ["cmd", "shift"]), (dl.KEY_D, ["cmd"]), (dl.KEY_P, ["cmd", "shift"])]:
            self.assertEqual(len(self.chords(key_code, modifiers)), dl.ROUNDS, key_code)
        actions = [e["payload"]["id"] for e in self.events if e["kind"] == "action"]
        self.assertEqual(actions.count("closePane"), dl.ROUNDS)
        scrolls = [e for e in self.events if e["kind"] == "mouse"]
        self.assertGreater(len(scrolls), 100 * dl.ROUNDS)
        self.assertTrue(all(e["payload"]["phase"] == "scroll" for e in scrolls))

    def test_typing_is_about_7_keys_per_second(self):
        typed = [e["t_ms"] for e in self.events if e["kind"] == "key" and "key_code" not in e["payload"]]
        gaps = sorted(b - a for a, b in zip(typed, typed[1:]) if b - a <= 200)
        self.assertTrue(110 <= gaps[len(gaps) // 2] <= 160, gaps[len(gaps) // 2])

    def walk(self):
        """(event, focus, palette open) before each event and (checkpoint, focus, palette open) at each checkpoint.
        The palette follows PaletteNavReducer.escape: Escape with a query clears it, Escape with an empty query
        closes the palette. Cmd-N focuses the workspace it makes and Cmd-Shift-W closes the shown workspace, so
        after it the focus is not known until the next pane.focus."""
        focus, palette, query = None, False, 0
        checkpoints = iter(committed()["checkpoints"])
        checkpoint = next(checkpoints, None)
        for event in self.events:
            while checkpoint is not None and checkpoint["t_ms"] <= event["t_ms"]:
                yield checkpoint, focus, palette
                checkpoint = next(checkpoints, None)
            yield event, focus, palette
            payload = event["payload"]
            if event["kind"] == "action" and payload["id"] == "pane.focus":
                focus = payload["args"]["target"]
            elif event["kind"] == "action" and payload["id"] in ("closePane", "closeWorkspace"):
                focus = None
            elif event["kind"] != "key":
                continue
            elif "cmd" in payload["modifiers"]:
                chord = (payload.get("key_code"), tuple(payload["modifiers"]))
                palette, query = chord == (dl.KEY_P, ("cmd", "shift")), 0
                focus = {(dl.KEY_D, ("cmd",)): dl.SPLIT_PANE, (dl.KEY_N, ("cmd",)): "new-workspace",
                         (dl.KEY_T, ("cmd",)): "new-tab", (dl.KEY_W, ("cmd", "shift")): None}.get(chord, focus)
            elif palette and payload.get("key_code") == dl.KEY_ESCAPE:
                palette, query = query > 0, 0
            elif palette and payload.get("key_code") == dl.KEY_DELETE:
                query = max(query - 1, 0)
            elif palette and "key_code" not in payload:
                query += 1
        for checkpoint in [checkpoint, *checkpoints] if checkpoint is not None else []:
            yield checkpoint, focus, palette

    def test_return_goes_only_to_the_editor(self):
        """Typed synthetic text never runs: Return only while the editor (pty_replay drops its input) has focus."""
        for item, focus, palette in self.walk():
            if item.get("kind") == "key" and item["payload"].get("key_code") == dl.KEY_RETURN:
                self.assertEqual((focus, palette), (dl.EDITOR, False), item)

    def test_the_palette_is_closed_at_every_checkpoint(self):
        seen = [item["name"] for item, _, palette in self.walk() if "name" in item and not palette]
        self.assertEqual(seen, [c["name"] for c in committed()["checkpoints"]])

    def test_the_palette_model_needs_two_escapes_after_a_query(self):
        """The model above, checked on a track whose one Escape follows a typed query: the palette stays open."""
        events = [{"t_ms": 0, "kind": "key", "payload": {"phase": "down", "class": "letter", "key_code": dl.KEY_P,
                                                          "modifiers": ["cmd", "shift"]}},
                  {"t_ms": 10, "kind": "key", "payload": {"phase": "down", "class": "letter", "modifiers": []}},
                  {"t_ms": 20, "kind": "key", "payload": {"phase": "down", "class": "named",
                                                           "key_code": dl.KEY_ESCAPE, "modifiers": []}},
                  {"t_ms": 30, "kind": "key", "payload": {"phase": "down", "class": "named",
                                                           "key_code": dl.KEY_RETURN, "modifiers": []}}]
        self.events = events
        last = [palette for item, _, palette in self.walk() if item is events[-1]]
        self.assertEqual(last, [True])

    def test_refs_name_only_layout_workspaces(self):
        """A ref to a workspace the story makes would depend on workspaces.newPlacement (top by default): every
        ref names a workspace of the layout, and the story closes what it makes through focus."""
        layout = len(json.loads((REPO_ROOT / dl.LAYOUT_PATH).read_text(encoding="utf-8"))["workspaces"])
        refs = [e["payload"]["args"]["target"] for e in self.events if e["kind"] == "action"]
        self.assertTrue(refs)
        for ref in refs:
            self.assertLess(int(ref[2:].split(".")[0]), layout, ref)
        self.assertNotIn("closeWorkspace", [e["payload"]["id"] for e in self.events if e["kind"] == "action"])

    def test_events_are_in_the_window_and_ordered(self):
        times = [e["t_ms"] for e in self.events]
        self.assertEqual(times, sorted(times))
        self.assertLessEqual(times[-1], dl.DURATION_MS)


if __name__ == "__main__":
    unittest.main()
