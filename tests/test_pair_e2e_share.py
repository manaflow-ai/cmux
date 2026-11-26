"""Pair-e2e must reject stale, unrelated, or GUI-assisted admission receipts."""
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts/ci"))
from cmux_next_pair_share_host import TaggedShareHost, share_log_line, share_without_asking_off
from cmux_next_pair_share_phone import (PairShareFailure, PairSharePhone, screen_sharing_page_state, viewer_log,
                                        viewer_state)
from cmux_next_screen_sharing_proof import positive_fps


class ShareAuditTests(unittest.TestCase):
    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.host = TaggedShareHost("/rig/Mac.app", {"ACPMUX_HOME": folder.name})
        self.host.target = {"deviceId": "rig-mac", "userId": "rig-owner"}
        self.host.audit.parent.mkdir()
        self.digest = hashlib.sha256(b"signed").hexdigest()
        self.decision = {"event": "remote_host.share_admitted", "device": "rig-mac", "via": "same-account",
                         "carrier": "device-hub", "nonce": "signed", "confirmed_by": "rig-owner",
                         "asker_name": "unique-sim", "asker": "phone-id", "confirmed_on": "phone-id"}

    def append(self, **changes):
        with self.host.audit.open("a") as f:
            f.write(json.dumps({**self.decision, **changes}) + "\n")

    def test_requires_a_new_decision_for_this_phone_target_and_owner(self):
        self.append()
        offset = self.host.audit.stat().st_size
        for key in ("device", "nonce", "confirmed_on", "confirmed_by", "via", "carrier"):
            self.append(**{key: "other"})
        self.append(nonce="")
        with patch.object(self.host, "_status", return_value={"appAttached": False}):
            with self.assertRaisesRegex(RuntimeError, "no fresh admission"):
                self.host.admission(offset, self.digest, timeout=0)
            self.append()
            self.assertEqual(self.host.admission(offset, self.digest, timeout=0), self.decision)

    def test_refuses_an_attached_mac_or_a_denied_approval(self):
        self.append()
        with patch.object(self.host, "_status", return_value={"appAttached": True}):
            with self.assertRaisesRegex(RuntimeError, "app was attached"):
                self.host.admission(0, self.digest, timeout=0)
        offset = self.host.audit.stat().st_size
        self.append(event="remote_host.share_refused", code="share.bad_signature")
        with self.assertRaisesRegex(RuntimeError, "share.bad_signature"):
            self.host.admission(offset, self.digest, timeout=0)


class FakeUI:
    def __init__(self, nodes):
        self.nodes = nodes

    def find(self, match):
        return [n for n in self.nodes if match(n)]

    def control(self, match, what):
        found = self.find(match)
        if not found:
            raise RuntimeError(what)
        return found[0]


class RdViewerTests(unittest.TestCase):
    """With the Mac app closed the phone views over rd/1, not WebRTC."""

    def phone(self, nodes):
        phone = PairSharePhone.__new__(PairSharePhone)
        phone.ui = FakeUI(nodes)
        return phone

    def test_reads_the_rd_meter_fps_and_taps_its_stream(self):
        stream = {"AXIdentifier": "browser.stream", "frame": {"x": 0, "y": 0, "width": 390, "height": 600}}
        phone = self.phone([stream, {"AXLabel": "phone 17:02:11.204"},
                            {"AXLabel": "30 fps · 812 kbps · 1280×800 · lan"}])
        self.assertTrue(positive_fps(phone.stats()))
        self.assertIs(phone.screen_view(), stream)

    def test_a_still_rd_meter_reads_no_frame(self):
        phone = self.phone([{"AXLabel": "0 fps · 0 kbps · 0×0 · lan"}])
        self.assertFalse(positive_fps(phone.stats()))

    def test_webrtc_stats_and_view_still_win(self):
        view = {"AXIdentifier": "screen.view", "frame": {"x": 0, "y": 0, "width": 1, "height": 1}}
        phone = self.phone([view, {"AXIdentifier": "screen.stats", "AXLabel": "LAN · 24 fps · 900 KB/s · 9 ms · h264"}])
        self.assertTrue(positive_fps(phone.stats()))
        self.assertIs(phone.screen_view(), view)


class ShareWithoutAskingOffTests(unittest.TestCase):
    def test_an_unset_key_reads_as_the_default_off(self):
        self.assertTrue(share_without_asking_off({"path": ["macScreen", "shareWithoutAsking"], "exists": False,
                                                  "value": None, "file": "/rig/cmux.json"}))

    def test_an_explicit_false_is_off(self):
        self.assertTrue(share_without_asking_off({"exists": True, "value": False}))

    def test_on_an_error_or_an_unknown_reply_is_not_off(self):
        for reply in ({"exists": True, "value": True}, {"error": "settings are not available"},
                      {"value": None}, {"exists": True, "value": None}, None):
            with self.subTest(reply=reply):
                self.assertFalse(share_without_asking_off(reply))


class MacRowTests(unittest.TestCase):
    """The phone's row for the rig Mac, whatever case the hub spells its id in."""

    def test_the_page_state_names_only_fixed_words_and_a_count(self):
        nodes = [{"AXIdentifier": "screenSharing.empty"}, {"AXIdentifier": "screenSharing.device.ABC", "AXLabel": "Mac"}]
        self.assertEqual(screen_sharing_page_state(nodes), "page state: empty; Mac rows: 1 [ba7816bf ?]")

    def test_each_row_says_its_digest_name_match_and_status(self):
        nodes = [{"AXIdentifier": "screenSharing.device.abc", "AXLabel": "rig, Not shared"},
                 {"AXIdentifier": "screenSharing.device.def", "AXLabel": "Old Mac, Offline"}]
        text = screen_sharing_page_state(nodes, "rig", "ABC")
        self.assertEqual(text, "page state: none; Mac rows: 2 [ba7816bf (rig name) Not shared; cb8379ac Offline]; "
                               "wanted ba7816bf")
        self.assertNotIn("Old Mac", text)
        self.assertEqual(screen_sharing_page_state([]), "page state: none; Mac rows: 0; no Screen Sharing page (0 nodes)")

    def test_a_missing_page_names_the_screen_it_is_on(self):
        nodes = [{"type": "Heading", "AXLabel": "Workspaces"},
                 {"AXIdentifier": "workspace.row.0123456789abcdef0123"},
                 {"AXIdentifier": "tab.settings"}]
        text = screen_sharing_page_state(nodes)
        self.assertIn("no Screen Sharing page (3 nodes; headings: Workspaces; ids: workspace.row.", text)
        self.assertNotIn("0123456789abcdef0123", text)
        self.assertTrue(text.endswith("tab.settings)"))

    def test_a_list_without_the_e2e_identifiers_says_so(self):
        nodes = [{"AXIdentifier": "screenSharing.page"}, {"AXIdentifier": "screenSharing.mac.0 e2e rig Mac", "AXLabel": "0 e2e rig Mac"}]
        text = screen_sharing_page_state(nodes, "0 e2e rig Mac", "abc")
        self.assertEqual(text, "page state: none; Mac rows: 0; rows keyed by name: 1; wanted ba7816bf")
        self.assertNotIn("rig Mac", text)

    def test_an_upper_case_row_id_matches_a_lower_case_device_id(self):
        row = {"AXIdentifier": "screenSharing.device.ABC-1", "AXLabel": "rig, Not shared"}
        alert = {"type": "StaticText", "AXLabel": "rig isn't sharing its screen"}
        button = {"type": "Button", "AXLabel": "Share rig"}
        phone = PairSharePhone.__new__(PairSharePhone)
        phone.ui = FakeUI([row, alert, button])
        taps = []
        phone.ui.tap = taps.append
        phone.request_share("rig", "abc-1")
        self.assertEqual(taps, [row, button])

    def test_launch_opens_screen_sharing_from_its_settings_row(self):
        row = {"AXIdentifier": "settings.screenSharing", "AXLabel": "Screen Sharing"}
        phone = PairSharePhone.__new__(PairSharePhone)
        phone.ui = FakeUI([row])
        launched, taps = [], []
        phone.ui.launch = launched.append
        phone.ui.tap = taps.append
        phone.launch()
        self.assertNotIn("-cmux-mobile-settings-page", launched[0])
        self.assertEqual(launched[0][launched[0].index("-cmux-mobile-tab") + 1], "settings")
        self.assertEqual(taps, [row])

    def test_launch_with_no_screen_sharing_row_says_the_service_never_came(self):
        phone = PairSharePhone.__new__(PairSharePhone)
        phone.ui = FakeUI([{"type": "Heading", "AXLabel": "Settings"}])
        phone.ui.launch = lambda args: None
        phone.screenshot = lambda name: None
        with patch("cmux_next_pair_share_phone.time.monotonic", side_effect=[0, 0, 300]), \
                patch("cmux_next_pair_share_phone.time.sleep"):
            with self.assertRaisesRegex(PairShareFailure, "no Screen Sharing row in 240 s.*headings: Settings"):
                phone.launch()

    def test_launch_taps_a_screen_sharing_row_its_label_repeats(self):
        phone = PairSharePhone.__new__(PairSharePhone)
        label = {"type": "StaticText", "AXUniqueId": "settings.screenSharing"}
        button = {"type": "Button", "AXUniqueId": "settings.screenSharing"}
        phone.ui = FakeUI([label, button])
        phone.ui.launch = lambda args: None
        tapped = []
        phone.ui.tap = tapped.append
        phone.launch()
        self.assertEqual(tapped, [button])

    def test_launch_with_no_row_lists_the_settings_rows_it_saw(self):
        phone = PairSharePhone.__new__(PairSharePhone)
        phone.ui = FakeUI([{"type": "Button", "AXUniqueId": "settings.devices"}])
        phone.ui.launch = lambda args: None
        phone.screenshot = lambda name: None
        with patch("cmux_next_pair_share_phone.time.monotonic", side_effect=[0, 0, 300]), \
                patch("cmux_next_pair_share_phone.time.sleep"):
            with self.assertRaisesRegex(PairShareFailure, "settings rows: settings.devices"):
                phone.launch()

    def test_a_missing_row_says_what_the_page_showed(self):
        phone = PairSharePhone.__new__(PairSharePhone)
        phone.ui = FakeUI([{"AXIdentifier": "screenSharing.failed"}])
        phone.ui.run = lambda *args, **kwargs: None
        phone.ui.udid = "sim"
        with patch("cmux_next_pair_share_phone.time.monotonic", side_effect=[0, 0, 300]), \
                patch("cmux_next_pair_share_phone.time.sleep"):
            with self.assertRaisesRegex(PairShareFailure, "page state: failed; Mac rows: 0; wanted "):
                phone.request_share("rig", "abc-1")

    def test_an_offline_row_is_not_tapped_and_the_failure_says_it_never_read_not_shared(self):
        phone = PairSharePhone.__new__(PairSharePhone)
        phone.ui = FakeUI([{"AXIdentifier": "screenSharing.device.abc-1", "AXLabel": "rig, Offline"}])
        phone.ui.run = lambda *args, **kwargs: None
        phone.ui.udid = "sim"
        taps = []
        phone.ui.tap = taps.append
        phone.screenshot = lambda name: None
        with patch("cmux_next_pair_share_phone.time.monotonic", side_effect=[0, 0, 300]), \
                patch("cmux_next_pair_share_phone.time.sleep"):
            with self.assertRaisesRegex(PairShareFailure, r"never read Not shared in 90 s .*\(rig name\) Offline"):
                phone.request_share("rig", "abc-1")
        self.assertEqual(taps, [])

    def test_a_row_that_comes_online_is_tapped_once_it_reads_not_shared(self):
        row = {"AXIdentifier": "screenSharing.device.abc-1", "AXLabel": "rig, Offline"}
        phone = PairSharePhone.__new__(PairSharePhone)
        phone.ui = FakeUI([row, {"type": "StaticText", "AXLabel": "rig isn't sharing its screen"},
                           {"type": "Button", "AXLabel": "Share rig"}])
        phone.ui.udid = "sim"
        phone.ui.run = lambda *args, **kwargs: row.update(AXLabel="rig, Not shared")
        taps = []
        phone.ui.tap = taps.append
        with patch("cmux_next_pair_share_phone.time.sleep"):
            phone.request_share("rig", "abc-1")
        self.assertEqual([t.get("AXLabel") for t in taps], ["rig, Not shared", "Share rig"])

    def test_no_share_alert_names_the_alert_that_came_instead(self):
        row = {"AXIdentifier": "screenSharing.device.abc-1", "AXLabel": "rig, Not shared"}
        phone = PairSharePhone.__new__(PairSharePhone)
        phone.ui = FakeUI([row, {"type": "StaticText", "AXLabel": "Couldn't share rig"}])
        phone.ui.tap = lambda node: None
        phone.screenshot = lambda name: None
        with self.assertRaisesRegex(PairShareFailure, "Share alert after tapping a Not shared row "
                                                      r"\(alert: couldn't share; page state: none; Mac rows: 1"):
            phone.request_share("rig", "abc-1")


class ShareLogTests(unittest.TestCase):
    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.host = TaggedShareHost("/rig/Mac.app", {"ACPMUX_HOME": folder.name})

    def test_only_share_host_lines_after_the_cursor_with_urls_and_tokens_cut(self):
        self.host.log.write_text("share-host: before the baseline\n")
        self.host.log_cursor = self.host.log.stat().st_size
        with self.host.log.open("a") as log:
            log.write("other: unrelated\n")
            log.write("share-host: session s1: no helper: none at https://x.example/a?t=1\n")
            log.write("share-host: end not sent: " + "a" * 40 + "\n")
        self.assertEqual(self.host.share_log(),
                         "share-host log: share-host: session s1: no helper: none at <url> | "
                         "share-host: end not sent: <cut>")

    def test_the_daemons_stop_line_is_kept(self):
        with self.host.log.open("w") as log:
            log.write("INFO acpmux: stopping: its app quit (app pid 9)\n")
        self.assertEqual(self.host.share_log(), "share-host log: INFO acpmux: stopping: its app quit (app pid 9)")

    def test_a_missing_log_says_so(self):
        self.assertEqual(self.host.share_log(), "share-host log: FileNotFoundError")

    def test_a_long_line_is_cut(self):
        self.assertEqual(len(share_log_line("share-host: " + "word " * 100)), 240)


class ViewerStateTests(unittest.TestCase):
    def test_a_session_over_card_names_that_no_known_reason_came(self):
        nodes = [{"AXIdentifier": "screenSharing.page"}, {"AXLabel": "Sharing ended"},
                 {"AXLabel": "The session with Rig Mac is over."}]
        self.assertEqual(viewer_state(nodes, "Rig Mac"),
                         "viewer: ended (session over, reason not one the phone names); views: screenSharing.page; "
                         "meter: none")

    def test_a_share_problem_alert_names_its_fixed_reason(self):
        nodes = [{"AXIdentifier": "screenSharing.page"},
                 {"AXLabel": "Couldn't share Rig Mac"},
                 {"AXLabel": "Rig Mac didn't turn on sharing. Check that cmux is open on it and signed in to your account."}]
        self.assertEqual(viewer_state(nodes, "Rig Mac"),
                         "viewer: share problem (no sharing before the deadline); views: screenSharing.page; meter: none")

    def test_an_rd_viewer_reports_its_views_and_meter_without_free_text(self):
        nodes = [{"AXIdentifier": "browser.stream"}, {"AXIdentifier": "macScreen.status", "AXLabel": "secret words"},
                 {"AXLabel": "0 fps · 0 kbps · 0×0 · lan"}]
        self.assertEqual(viewer_state(nodes, "Rig Mac"),
                         "viewer: no card; views: browser.stream, macScreen.status; meter: 0 fps · 0 kbps")


class ViewerLogTests(unittest.TestCase):
    def test_the_phone_says_why_its_session_ended(self):
        lines = [
            "2026-11-26 00:01:02.000 I cmux[1:2] [dev.cmux.mobile:screen-sharing] host serves cmux.rd/1: reattaching for it\n",
            "2026-11-26 00:01:02.100 I cmux[1:2] [dev.cmux.mobile:links] live data on\n",
            "2026-11-26 00:01:04.000 I cmux[1:2] [dev.cmux.mobile:screen-sharing] rd closed: ended \n",
            "2026-11-26 00:01:04.001 I cmux[1:2] [dev.cmux.mobile:screen-sharing] viewer ended: ended\n",
        ]
        self.assertEqual(viewer_log(lines),
                         "host serves cmux.rd/1: reattaching for it | rd closed: ended | viewer ended: ended")

    def test_no_lines_says_so(self):
        self.assertEqual(viewer_log(["live data on\n"]), "no viewer session lines")


class LaunchLiveStateTests(unittest.TestCase):
    """The share launch's failure says whether the phone reached live data after that launch."""

    @staticmethod
    def log(rows):
        import threading
        import cmux_next_pair_e2e
        log = type("Log", (), {"wait_at": cmux_next_pair_e2e.Stream.wait_at})()
        log.times, log.lines, log.cond = [t for t, _ in rows], [l for _, l in rows], threading.Condition()
        return cmux_next_pair_e2e.launch_live_state, log

    def test_names_when_each_line_came(self):
        state, log = self.log([(5, "Stack project p (development)"), (12, "live data on api.example")])
        self.assertEqual(state(log, 2), "phone since launch: auth config after 3 s, live data after 10 s")

    def test_live_data_from_an_earlier_launch_does_not_count(self):
        state, log = self.log([(1, "live data on api.example"), (5, "Stack project p")])
        self.assertEqual(state(log, 2), "phone since launch: auth config after 3 s, live data not logged")


class BuildSpaceForTagTests(unittest.TestCase):
    """The rig's daemon gets the tag's build space, so its share host registers beside the phone."""

    def test_the_rig_tag_is_its_own_space(self):
        import cmux_next_pair_e2e
        self.assertEqual(cmux_next_pair_e2e.build_space_for_tag("iospair-8f03f7e6-4242"), "dev:iospair-8f03f7e6-4242")

    def test_a_tag_that_is_not_a_slug_is_left_to_the_app(self):
        import cmux_next_pair_e2e
        for tag in ("", None, "Upper", "-edge", "a_b", "x" * 65):
            self.assertIsNone(cmux_next_pair_e2e.build_space_for_tag(tag), tag)


class ShareLaunchKeepsHelpersTests(unittest.TestCase):
    """The Mac launch the share leg quits keeps its helpers: a tagged DEV build's `__dev-reaper`
    otherwise SIGTERMs acpmux and its share host as the app exits (run 45886008693), which a shipped
    app never does, so the phone read the Mac Offline."""

    def test_the_share_launch_keeps_helpers(self):
        source = (Path(__file__).resolve().parents[1] / "scripts/ci/cmux_next_pair_e2e.py").read_text()
        self.assertIn('share_launch = dict(env, CMUX_DEV_KEEP_HELPERS="1")', source)
        self.assertIn('if discovery else share_launch)', source)
        # The identity restart is the launch the share leg quits when discovery runs (run 45901838391).
        self.assertIn('discovery_restart(app, exe, share_launch,', source)
        self.assertIn('start_mac(env, "-pair")', source)
