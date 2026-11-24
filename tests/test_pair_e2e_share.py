"""Pair-e2e must reject stale, unrelated, or GUI-assisted admission receipts."""
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts/ci"))
from cmux_next_pair_share_host import TaggedShareHost


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
