"""Tests for scripts/perf-lab/corpus/browse_heavy.py and perf-corpus/browse-heavy.json (task p12-perf-process-119).

Run: python3 -m unittest scripts/perf-lab/tests/test_corpus_browse_heavy.py
"""

import importlib.util
import json
import shutil
import sys
import tempfile
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


bh = load("corpus_browse_heavy_under_test", CORPUS / "browse_heavy.py")
cm = bh.manifest_module()
io_ = bh.session_io()
wpr = bh.wpr()


def committed():
    return json.loads((REPO_ROOT / bh.MANIFEST_PATH).read_text(encoding="utf-8"))


def tab_kind(snapshot, ref):
    workspace, pane, tab = (int(part[1:]) for part in ref[1:].split("."))
    return io_.leaves(snapshot["workspaces"][workspace]["tree"])[pane]["tabs"][tab]


class CommittedFiles(unittest.TestCase):
    def test_the_committed_files_are_what_the_script_makes(self):
        self.assertEqual(bh.stale(REPO_ROOT), [])
        self.assertEqual(bh.main(["--check"]), 0)

    def test_the_script_is_deterministic(self):
        self.assertEqual(bh.outputs(REPO_ROOT, committed()), bh.outputs(REPO_ROOT, committed()))

    def test_the_manifest_validates_and_fits_in_git(self):
        self.assertEqual(cm.validate_paths([REPO_ROOT / bh.MANIFEST_PATH], REPO_ROOT), [])
        for made in [*bh.outputs(REPO_ROOT, committed()), bh.PAGES_PATH]:
            self.assertLessEqual((REPO_ROOT / made).stat().st_size, cm.MAX_GIT_BYTES, made)

    def test_a_lab_recording_is_kept(self):
        digest = "cd" * 32
        current = {**committed(), "status": "recorded",
                   "web_archive": {"wprgo": {"sha256": "ef" * 32, "bytes": 9}, "spki": "B" * 43 + "="},
                   "checkpoints": [{"t_ms": 0, "name": "layout-imported", "focus": digest, "surfaces": digest}]}
        current.pop("planned")
        made = json.loads(bh.outputs(REPO_ROOT, current)[bh.MANIFEST_PATH])
        self.assertEqual(made["status"], "recorded")
        self.assertNotIn("planned", made)
        self.assertEqual(made["web_archive"], current["web_archive"])
        self.assertEqual((made["checkpoints"][0]["focus"], made["checkpoints"][0]["surfaces"]), (digest, digest))
        self.assertIsNone(made["checkpoints"][1]["focus"])

    def test_check_fails_on_a_changed_manifest(self):
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch)
            for path in [bh.MANIFEST_PATH, bh.LAYOUT_PATH, bh.PAGES_PATH]:
                (root / path).parent.mkdir(parents=True, exist_ok=True)
                shutil.copy(REPO_ROOT / path, root / path)
            manifest = root / bh.MANIFEST_PATH
            manifest.write_text(manifest.read_text(encoding="utf-8").replace('"T1"', '"T0"'), encoding="utf-8")
            self.assertEqual(bh.stale(root), [bh.MANIFEST_PATH])
            self.assertEqual(bh.write(root), [bh.MANIFEST_PATH])
            self.assertEqual(bh.stale(root), [])


class Layout(unittest.TestCase):
    def setUp(self):
        self.manifest = committed()
        self.snapshot = io_.check(json.loads((REPO_ROOT / bh.LAYOUT_PATH).read_text(encoding="utf-8")))

    def kinds(self):
        return [kind for workspace in self.snapshot["workspaces"] for leaf in io_.leaves(workspace["tree"])
                for kind in leaf["tabs"]]

    def test_30_chromium_tabs_over_6_workspaces_and_some_webkit(self):
        self.assertEqual(len(self.snapshot["workspaces"]), 6)
        self.assertEqual(self.manifest["layout"]["workspaces"], 6)
        self.assertEqual(self.kinds().count("chromium"), 30)
        self.assertEqual(self.kinds().count("webkit"), 4)
        for workspace in self.snapshot["workspaces"]:
            self.assertEqual(io_.leaves(workspace["tree"])[0]["tabs"].count("chromium"), bh.CHROMIUM_PER_WORKSPACE)

    def test_chromium_tabs_are_the_chromium_refs(self):
        refs = bh.chromium_tabs()
        self.assertEqual(len(refs), 30)
        self.assertEqual({tab_kind(self.snapshot, ref) for ref in refs}, {"chromium"})

    def test_the_layout_imports_through_actions(self):
        self.assertEqual(io_.importable(self.snapshot), [])

    def test_the_layout_digest_is_the_file(self):
        self.assertEqual(self.manifest["layout"]["snapshot"]["sha256"], io_.digest(self.snapshot))


class InputTrack(unittest.TestCase):
    def setUp(self):
        self.manifest = committed()
        self.events = self.manifest["input"]["events"]
        self.snapshot = io_.check(json.loads((REPO_ROOT / bh.LAYOUT_PATH).read_text(encoding="utf-8")))

    def actions(self, action):
        return [e for e in self.events if e["kind"] == "action" and e["payload"]["id"] == action]

    def test_every_round_visits_every_workspace_with_cmd_digits(self):
        digits = [e["payload"]["key_code"] for e in self.events
                  if e["kind"] == "key" and e["payload"]["modifiers"] == ["cmd"] and e["payload"]["class"] == "digit"]
        self.assertEqual(digits, [bh.DIGIT_KEYS[w] for order in bh.VISIT_ORDER for w in order])
        for order in bh.VISIT_ORDER:
            self.assertEqual(sorted(order), list(range(6)))
            self.assertEqual(order[-1], 0, "each round ends on w0, the next round's start")

    def test_tab_switches_by_key_and_by_click(self):
        ctrl_tabs = [e for e in self.events if e["kind"] == "key" and e["payload"].get("key_code") == bh.KEY_TAB
                     and e["payload"]["modifiers"] == ["ctrl"]]
        self.assertEqual(len(ctrl_tabs), 2 * 6 * bh.ROUNDS)
        webkit = [e for e in self.actions("tab.focus") if tab_kind(self.snapshot, e["payload"]["args"]["target"]) == "webkit"]
        self.assertEqual(len(webkit), bh.ROUNDS)

    def test_every_hibernated_tab_is_a_hidden_chromium_tab_woken_by_its_visit(self):
        """Replays the track's tab state: hibernateTab only hits a Chromium tab that is not selected and not shown,
        and the round's tab.focus of that tab (the wake) comes before any Ctrl-Tab could reach it."""
        selected, shown, hibernated, woken = [0] * 6, 0, {}, 0
        for event in self.events:
            payload = event["payload"]
            if event["kind"] == "key" and payload["class"] == "digit":
                shown = bh.DIGIT_KEYS.index(payload["key_code"])
            elif event["kind"] == "key" and payload.get("key_code") == bh.KEY_TAB:
                selected[shown] = (selected[shown] + 1) % len(bh.PANES[shown][0])
                self.assertNotIn(selected[shown], [t for w, t in hibernated.items() if w == shown],
                                 f"Ctrl-Tab woke a hibernated tab at {event['t_ms']}")
            elif event["kind"] == "action" and payload["id"] in ("hibernateTab", "tab.focus"):
                workspace, pane, tab = (int(part[1:]) for part in payload["args"]["target"][1:].split("."))
                if payload["id"] == "hibernateTab":
                    self.assertNotEqual(workspace, shown)
                    self.assertEqual((pane, tab_kind(self.snapshot, payload["args"]["target"])), (0, "chromium"))
                    self.assertNotEqual(tab, selected[workspace])
                    self.assertNotIn(workspace, hibernated)
                    hibernated[workspace] = tab
                else:
                    self.assertEqual(workspace, shown)
                    if pane == 0:
                        if hibernated.get(workspace) == tab:
                            del hibernated[workspace]
                            woken += 1
                        selected[workspace] = tab
        self.assertEqual(hibernated, {})
        self.assertEqual(woken, 5 * bh.ROUNDS)
        self.assertEqual(len(self.actions("hibernateTab")), 5 * bh.ROUNDS)

    def test_omnibar_typing_ends_with_escape_never_return(self):
        """No key could navigate outside the archive or run text: no Return anywhere, and each Cmd-L query ends
        with ESCAPES presses of Escape before the next shortcut."""
        self.assertFalse([e for e in self.events if e["kind"] == "key" and e["payload"].get("key_code") == bh.KEY_RETURN])
        omnibar, typed, sessions = False, 0, 0
        for event in self.events:
            payload = event["payload"]
            if event["kind"] != "key":
                self.assertFalse(omnibar, f"an {event['kind']} event at {event['t_ms']} while the omnibar is open")
                continue
            if payload.get("key_code") == bh.KEY_L and payload["modifiers"] == ["cmd"]:
                omnibar, typed, escapes, sessions = True, 0, 0, sessions + 1
            elif payload.get("key_code") == bh.KEY_ESCAPE:
                self.assertTrue(omnibar)
                escapes += 1
                omnibar = escapes < bh.ESCAPES
            elif "key_code" not in payload:
                self.assertTrue(omnibar, f"typing at {event['t_ms']} outside the omnibar")
                typed += 1
            elif payload["modifiers"]:
                self.assertFalse(omnibar, f"a shortcut at {event['t_ms']} while the omnibar is open")
        self.assertEqual(sessions, len(bh.OMNIBAR_WORKSPACES) * bh.ROUNDS)

    def test_typing_is_about_7_keys_per_second(self):
        typed = [e["t_ms"] for e in self.events if e["kind"] == "key" and "key_code" not in e["payload"]]
        gaps = sorted(b - a for a, b in zip(typed, typed[1:]) if b - a <= 200)
        self.assertTrue(110 <= gaps[len(gaps) // 2] <= 160, gaps[len(gaps) // 2])

    def test_scrolls_are_inside_pane_p0(self):
        scrolls = [e for e in self.events if e["kind"] == "mouse"]
        self.assertTrue(scrolls)
        self.assertEqual({(e["payload"]["phase"], e["payload"]["x"], e["payload"]["y"]) for e in scrolls},
                         {("scroll", *bh.PAGE_POINT)})
        self.assertLess(bh.PAGE_POINT[0], bh.WINDOW[0] / 2, "left of the split of w0 and w3")

    def test_events_and_checkpoints_are_in_the_window_and_ordered(self):
        times = [e["t_ms"] for e in self.events]
        self.assertEqual(times, sorted(times))
        self.assertLessEqual(times[-1], bh.DURATION_MS)
        checkpoints = self.manifest["checkpoints"]
        self.assertEqual([c["t_ms"] for c in checkpoints], sorted(c["t_ms"] for c in checkpoints))
        self.assertEqual(len(checkpoints), 2 + bh.ROUNDS * 7)
        for number in range(bh.ROUNDS):
            start = [c["t_ms"] for c in checkpoints if c["name"] == f"round-{number}-hibernated"][0]
            self.assertGreaterEqual(start, number * bh.ROUND_MS)
            last = [c["t_ms"] for c in checkpoints if c["name"] == f"round-{number}-w0"][0]
            self.assertLess(last, (number + 1) * bh.ROUND_MS)

    def test_metrics_are_the_story_series(self):
        names = [m["name"] for m in self.manifest["metrics"]]
        self.assertIn(r"corpus\.browse_heavy\.wake_to_frame", names)
        self.assertIn(r"corpus\.browse_heavy\.tab_switch_to_frame", names)
        self.assertIn(r"corpus\.browse_heavy\.omnibar_key_to_frame", names)


class Pages(unittest.TestCase):
    def test_one_public_page_per_chromium_tab(self):
        self.assertEqual(bh.pages_problems(REPO_ROOT), [])
        urls = wpr.read_urls((REPO_ROOT / bh.PAGES_PATH).read_text(encoding="utf-8"))
        self.assertEqual(len(urls), len(bh.chromium_tabs()))

    def test_a_short_or_private_list_is_refused(self):
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch)
            (root / bh.PAGES_PATH).parent.mkdir(parents=True)
            (root / bh.PAGES_PATH).write_text("https://example.org/\nhttp://wiki.local/\n", encoding="utf-8")
            problems = bh.pages_problems(root)
            self.assertTrue(any("2 pages for 30 Chromium tabs" in p for p in problems), problems)
            self.assertTrue(any("wiki.local" in p for p in problems), problems)
            (root / bh.PAGES_PATH).write_text("https://example.org/\nhttps://example.org/\n", encoding="utf-8")
            self.assertTrue(any("more than once" in p for p in bh.pages_problems(root)))


if __name__ == "__main__":
    unittest.main()
