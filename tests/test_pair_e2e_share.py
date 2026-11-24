"""Pair-e2e must reject stale, unrelated, or GUI-assisted admission receipts."""
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts/ci"))
from cmux_next_pair_share_host import TaggedShareHost, share_without_asking_off
from cmux_next_pair_share_phone import PairShareFailure, PairSharePhone, screen_sharing_page_state
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
        self.assertEqual(screen_sharing_page_state(nodes), "page state: empty; Mac rows: 1")
        self.assertEqual(screen_sharing_page_state([]), "page state: none; Mac rows: 0")

    def test_an_upper_case_row_id_matches_a_lower_case_device_id(self):
        row = {"AXIdentifier": "screenSharing.device.ABC-1", "AXLabel": "rig"}
        alert = {"type": "StaticText", "AXLabel": "rig isn't sharing its screen"}
        button = {"type": "Button", "AXLabel": "Share rig"}
        phone = PairSharePhone.__new__(PairSharePhone)
        phone.ui = FakeUI([row, alert, button])
        taps = []
        phone.ui.tap = taps.append
        phone.request_share("rig", "abc-1")
        self.assertEqual(taps, [row, button])

    def test_a_missing_row_says_what_the_page_showed(self):
        phone = PairSharePhone.__new__(PairSharePhone)
        phone.ui = FakeUI([{"AXIdentifier": "screenSharing.failed"}])
        phone.ui.run = lambda *args, **kwargs: None
        phone.ui.udid = "sim"
        with patch("cmux_next_pair_share_phone.time.monotonic", side_effect=[0, 0, 100]), \
                patch("cmux_next_pair_share_phone.time.sleep"):
            with self.assertRaisesRegex(PairShareFailure, "page state: failed; Mac rows: 0"):
                phone.request_share("rig", "abc-1")
