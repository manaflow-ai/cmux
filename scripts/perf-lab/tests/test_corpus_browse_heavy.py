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
        for made in bh.outputs(REPO_ROOT, committed()):
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
        self.assertIsNone(made["web_archive"], "no player step loads archive pages into the tabs yet")
        self.assertEqual((made["checkpoints"][0]["focus"], made["checkpoints"][0]["surfaces"]), (digest, digest))
        self.assertIsNone(made["checkpoints"][1]["focus"])

    def test_check_fails_on_a_changed_manifest(self):
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch)
            for path in [bh.MANIFEST_PATH, bh.LAYOUT_PATH, cm.SETTINGS_PATH]:
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

    def digits(self):
        return [bh.DIGIT_KEYS.index(e["payload"]["key_code"]) + 1 for e in self.events
                if e["kind"] == "key" and e["payload"]["modifiers"] == ["cmd"] and e["payload"]["class"] == "digit"]

    def setting(self, key):
        """The value the replay launches with: the manifest's config (play.py sets it), else the app default."""
        return self.manifest.get("config", {}).get(key, cm.load_settings(REPO_ROOT)[key])

    def test_the_replay_config_is_the_scripts(self):
        self.assertEqual(self.manifest["config"], bh.CONFIG)

    def test_every_round_visits_every_workspace_with_cmd_digits(self):
        """Under the numbering the replay launches with, the Nth Cmd-digit of the track shows the Nth visit's
        workspace (SidebarNavigationSettings: allItems counts Home and the App Store first)."""
        numbering = self.setting("sidebar.numbering")
        self.assertEqual([bh.digit_workspace(digit, numbering) for digit in self.digits()],
                         [w for order in bh.VISIT_ORDER for w in order])
        for order in bh.VISIT_ORDER:
            self.assertEqual(sorted(order), list(range(6)))
            self.assertEqual(order[-1], 0, "each round ends on w0, the next round's start")

    def test_the_app_default_numbering_would_miss_workspaces(self):
        """Why the config sets numbering: under the default, Cmd-1 and Cmd-2 show Home and the App Store and no
        digit of the track reaches w4 or w5."""
        default = cm.load_settings(REPO_ROOT)["sidebar.numbering"]
        self.assertEqual(default, "allItems")
        self.assertEqual(bh.digit_workspace(1, default), None)
        self.assertEqual(bh.digit_workspace(3, default), 0)
        reached = {bh.digit_workspace(digit, default) for digit in self.digits()}
        self.assertNotIn(5, reached)
        self.assertEqual(self.setting("sidebar.numbering"), "workspacesOnly")

    def test_tab_switches_by_key_and_by_click(self):
        tabs = [e["payload"]["modifiers"] for e in self.events
                if e["kind"] == "key" and e["payload"].get("key_code") == bh.KEY_TAB]
        self.assertEqual(tabs.count(["ctrl"]), 6 * bh.ROUNDS)
        self.assertEqual(tabs.count(["ctrl", "shift"]), 6 * bh.ROUNDS)
        self.assertEqual(len(tabs), 2 * 6 * bh.ROUNDS)
        webkit = [e for e in self.actions("tab.focus") if tab_kind(self.snapshot, e["payload"]["args"]["target"]) == "webkit"]
        self.assertEqual(len(webkit), bh.ROUNDS)

    def test_every_hibernated_tab_sleeps_until_its_visit_wakes_it(self):
        """Replays the track's tab state under the replay's numbering and awake-neighbor radius: hibernateTab only
        hits a hidden Chromium tab, and until the round's tab.focus of that tab (the wake) no tab its pane shows is
        within the radius of it, so the neighbor policy never restores it first (BrowserHibernation, NeighborTabs:
        the neighbors wrap)."""
        numbering, radius = self.setting("sidebar.numbering"), self.setting(bh.NEIGHBOR_RADIUS_KEY)
        self.assertGreaterEqual(radius, 1, "the story checks the default neighbor policy, not a disabled one")
        selected, shown, hibernated, woken = [0] * 6, 0, {}, 0

        def asleep(workspace, when):
            if workspace in hibernated:
                count = len(bh.PANES[workspace][0])
                self.assertGreater(bh.ring_distance(hibernated[workspace], selected[workspace], count), radius,
                                   f"w{workspace} tab {hibernated[workspace]} is an awake neighbor at {when}")

        for event in self.events:
            payload = event["payload"]
            if event["kind"] == "key" and payload["class"] == "digit":
                shown = bh.digit_workspace(bh.DIGIT_KEYS.index(payload["key_code"]) + 1, numbering)
                self.assertIsNotNone(shown, f"Cmd-digit at {event['t_ms']} shows a top item")
            elif event["kind"] == "key" and payload.get("key_code") == bh.KEY_TAB:
                step = -1 if "shift" in payload["modifiers"] else 1
                selected[shown] = (selected[shown] + step) % len(bh.PANES[shown][0])
                asleep(shown, event["t_ms"])
            elif event["kind"] == "action" and payload["id"] in ("hibernateTab", "tab.focus"):
                workspace, pane, tab = (int(part[1:]) for part in payload["args"]["target"][1:].split("."))
                if payload["id"] == "hibernateTab":
                    self.assertNotEqual(workspace, shown)
                    self.assertEqual((pane, tab_kind(self.snapshot, payload["args"]["target"])), (0, "chromium"))
                    self.assertNotIn(workspace, hibernated)
                    hibernated[workspace] = tab
                    asleep(workspace, event["t_ms"])
                else:
                    self.assertEqual(workspace, shown)
                    if pane == 0:
                        if hibernated.get(workspace) == tab:
                            del hibernated[workspace]
                            woken += 1
                        selected[workspace] = tab
                        asleep(workspace, event["t_ms"])
        self.assertEqual(hibernated, {})
        self.assertEqual(woken, 5 * bh.ROUNDS)
        self.assertEqual(len(self.actions("hibernateTab")), 5 * bh.ROUNDS)

    def test_a_radius_with_no_sleeping_tab_is_refused(self):
        track = bh._Track(bh.random.Random(bh.SEED), neighbor_radius=2)
        with self.assertRaises(ValueError):
            track.hibernate(0, 0)

    def test_omnibar_typing_ends_with_escape_never_return(self):
        """No key could load a page or run text: no Return anywhere, and each Cmd-L query ends with ESCAPES presses
        of Escape before the next shortcut. No key arrows a row, and a Delete never empties the text, so the popup
        is open (its what-you-typed row) at the first Escape and the escapes take the same steps on every run."""
        self.assertFalse([e for e in self.events if e["kind"] == "key" and e["payload"].get("key_code") == bh.KEY_RETURN])
        self.assertEqual(bh.ESCAPES, 3)
        omnibar, sessions = False, 0
        for event in self.events:
            payload = event["payload"]
            if event["kind"] != "key":
                self.assertFalse(omnibar, f"an {event['kind']} event at {event['t_ms']} while the omnibar is open")
                continue
            if payload.get("key_code") == bh.KEY_L and payload["modifiers"] == ["cmd"]:
                omnibar, text, escapes, sessions = True, "", 0, sessions + 1
            elif payload.get("key_code") == bh.KEY_ESCAPE:
                self.assertTrue(omnibar)
                self.assertTrue(text.strip(), f"empty omnibar text at the Escape at {event['t_ms']}")
                escapes += 1
                omnibar = escapes < bh.ESCAPES
            elif payload.get("key_code") == bh.KEY_DELETE:
                self.assertTrue(omnibar)
                text = text[:-1]
                self.assertTrue(text.strip(), f"a Delete at {event['t_ms']} empties the omnibar")
            elif "key_code" not in payload:
                self.assertTrue(omnibar, f"typing at {event['t_ms']} outside the omnibar")
                text += " " if payload["class"] == "space" else "a"
            else:
                self.assertFalse(omnibar, f"key {payload['key_code']} at {event['t_ms']} while the omnibar is open")
        self.assertEqual(sessions, len(bh.OMNIBAR_WORKSPACES) * bh.ROUNDS)

    def test_the_omnibar_sends_no_suggest_request(self):
        """Remote suggestions are on by default (a URLSession fetch that Web Page Replay never sees); the replay
        turns them off, so the popup's rows come from local state only."""
        self.assertIs(cm.load_settings(REPO_ROOT)["browser.omnibar.remoteSuggestions"], True)
        self.assertIs(self.setting("browser.omnibar.remoteSuggestions"), False)

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


if __name__ == "__main__":
    unittest.main()
