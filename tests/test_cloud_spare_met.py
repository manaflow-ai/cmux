#!/usr/bin/env python3
"""The met mode's own reading of a claim (scripts/cmux-next/cloud-spare-met.py): no app, no machine."""

import base64
import hashlib
import importlib.util
import json
from pathlib import Path
import sys
import unittest

sys.dont_write_bytecode = True  # a stale cached copy of the script must never stand in for it

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/cmux-next/cloud-spare-met.py"
spec = importlib.util.spec_from_file_location("cloud_spare_met", SCRIPT)
met = importlib.util.module_from_spec(spec)
spec.loader.exec_module(met)

STAGES = [{"step": "machine", "ms": 1200}, {"step": "connect", "ms": 800}, {"step": "login", "ms": 5},
          {"step": "approvals", "ms": 1}, {"step": "anchor", "ms": 2}, {"step": "tab", "ms": 40}, {"step": "start", "ms": 900}]
LOGIN = "sk-ant-oat01-journeystub-" + "ab" * 24
SHA = hashlib.sha256(LOGIN.encode()).hexdigest()


def row(**over):
    base = dict(index=0, spare="vm_aaaaaaaaaaaaaaaaaaaa", spare_ran=True, mark={"this_run": True, "own_login": True},
                answer={"machine_id": "vm_aaaaaaaaaaaaaaaaaaaa", "stages_ms": STAGES,
                        "stages_detail_ms": {"steps": [{"step": "login.receipt", "ms": 1}, {"step": "machine", "ms": 3}]}},
                exit_code=0, wall_s=4.5, reply="Stub reply n1.", nonce="n1", login_sha=SHA,
                turns=[{"method": "POST", "stream": True, "cred_sha256": SHA}])
    base.update(over)
    return met.claim_row(**base)


class CloudSpareMetTests(unittest.TestCase):
    def test_the_cached_login_is_named_and_wrapped_as_the_app_stores_it(self):
        # CloudCredentialLogin.name: CLAUDE_TRANSFER_ + the first 12 bytes of sha256("user:personal:"), hex.
        want = hashlib.sha256(b"user-1:personal:").digest()[:12].hex()
        self.assertEqual(met.transfer_name("user-1"), f"CLAUDE_TRANSFER_{want}")
        self.assertEqual(len(want), 24)
        wrapped = json.loads(met.envelope(LOGIN, 12.5))
        self.assertEqual(wrapped["created"], 12.5)
        self.assertEqual(base64.b64decode(wrapped["credential"]).decode(), LOGIN)

    def test_the_made_up_login_passes_the_apps_own_check(self):
        # CloudCredentialTransfer.validate: sk-ant-oat01-, 32+ characters, printable ASCII, no space.
        login = met.made_up_login()
        self.assertTrue(login.startswith("sk-ant-oat01-journeystub-"))
        self.assertGreaterEqual(len(login), 32)
        self.assertTrue(all(32 < ord(c) < 127 for c in login))
        self.assertNotEqual(login, met.made_up_login())

    def test_the_mark_reads_this_runs_login_only(self):
        self.assertEqual(met.read_mark("x\nMARK own=yes this_run=yes\n"), {"read": True, "own_login": True, "this_run": True})
        self.assertEqual(met.read_mark("MARK own=yes this_run=no"), {"read": True, "own_login": True, "this_run": False})
        self.assertEqual(met.read_mark("exec failed"), {"read": False, "own_login": None, "this_run": None})
        self.assertIn(SHA, met.mark_command(SHA))
        self.assertNotIn(LOGIN, met.mark_command(SHA))

    def test_create_and_bound_come_from_the_starts_own_stages(self):
        r = row()
        self.assertEqual((r["create_s"], r["bound_s"]), (1.2, 2.0))
        self.assertEqual(r["reply_s"], 4.5)
        self.assertEqual(r["reply_turn_s"], round(4.5 - 2.948, 3))
        self.assertEqual(r["bound_minus_create_s"], 0.8)
        self.assertEqual(r["reply_minus_bound_s"], 2.5)
        self.assertTrue(r["real_claim"] and r["login_on_spare_at_claim"] and r["replied"] and r["login_reached_model"])
        self.assertEqual(r["login_steps"], ["login.receipt"])

    def test_a_start_on_another_machine_or_a_spare_not_running_is_no_real_claim(self):
        self.assertFalse(row(answer={"machine_id": "vm_bbbbbbbbbbbbbbbbbbbb", "stages_ms": STAGES})["real_claim"])
        self.assertFalse(row(spare_ran=False)["real_claim"])
        self.assertFalse(row(spare=None)["real_claim"])

    def test_a_reply_without_the_stubs_nonce_or_another_login_does_not_count(self):
        self.assertFalse(row(reply="ok")["replied"])
        self.assertIsNone(row(reply="ok")["reply_s"])
        self.assertFalse(row(turns=[{"method": "POST", "stream": True, "cred_sha256": "0" * 64}])["login_reached_model"])
        self.assertFalse(row(turns=[])["login_reached_model"])
        refused = row(exit_code=1, answer={})
        self.assertFalse(refused["replied"])
        self.assertIsNone(refused["create_s"])

    def test_the_stub_log_keeps_real_turns_only(self):
        log = "\n".join(json.dumps(x) for x in (
            {"method": "GET", "path": "/__stub/info"}, {"method": "POST", "stream": True, "side": True},
            {"method": "POST", "stream": True, "cred_sha256": SHA})) + "\nnot json\n"
        self.assertEqual(met.stub_turns(log), [{"method": "POST", "stream": True, "cred_sha256": SHA}])

    def test_the_summary_passes_only_when_every_claim_did(self):
        good = [row(index=i, wall_s=3 + i) for i in range(10)]
        s = met.summarize(good)
        self.assertTrue(s["pass"])
        self.assertEqual((s["real_claims"], s["real_with_login"]), (10, 10))
        self.assertEqual(s["real"]["reply_s"]["p50"], 7)
        self.assertEqual(s["real"]["reply_s"]["p90"], 11)
        missing = good[:9] + [row(index=9, mark={"this_run": False, "own_login": False})]
        s = met.summarize(missing)
        self.assertFalse(s["pass"])
        self.assertEqual((s["real_claims"], s["real_with_login"]), (10, 9))
        self.assertEqual(s["real_with_login_stats"]["n"], 9)
        self.assertFalse(met.summarize([])["pass"])
        other_login = good[:9] + [row(index=9, turns=[{"method": "POST", "stream": True, "cred_sha256": "0" * 64}])]
        self.assertFalse(met.summarize(other_login)["pass"], "a reply on a login this run did not copy is no pass")
        md = met.markdown(missing, s, {"tag": "t"})
        self.assertIn("harness login attached in advance", md)
        self.assertIn("| real claims | 10 |", md)

    def test_nearest_rank_percentiles(self):
        self.assertIsNone(met.percentile([], 50))
        self.assertEqual(met.percentile([3.0], 90), 3.0)
        self.assertEqual(met.percentile([1, 2, 3, 4], 50), 2)
        self.assertEqual(met.percentile(list(range(1, 11)), 90), 9)


if __name__ == "__main__":
    unittest.main()
