#!/usr/bin/env python3
"""scripts/ios-live/ios-live keeps one owner name across separate shells.

Regression: with IOS_LIVE_OWNER unset and no session id the client named the owner after $PPID, which
is a new shell on every agent tool call, so the slot taken in one call was not yours in the next. Each
call here runs in its own bash (its own $PPID), with a fake `reach` that runs host.sh locally.
"""
from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CLIENT = ROOT / "scripts" / "ios-live" / "ios-live"
SESSION_VARS = ("IOS_LIVE_OWNER", "CLAUDE_CODE_SESSION_ID", "CLAUDE_SESSION_ID", "CODEX_THREAD_ID",
                "CODEX_SESSION_ID", "IOS_LIVE_HOST", "IOS_LIVE_AT")


class IosLiveLeaseOwner(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="ios-live-owner-"))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        bin_dir = self.tmp / "bin"
        bin_dir.mkdir()
        self.host_home = self.tmp / "host-home"
        self.host_home.mkdir()
        reach = bin_dir / "reach"
        # reach HOST CMD: run CMD here, as if on the host, with the host's own HOME.
        reach.write_text('#!/usr/bin/env bash\nshift\nHOME="$FAKE_HOST_HOME" exec bash -c "$*"\n')
        reach.chmod(0o755)
        self.env = {k: v for k, v in os.environ.items() if k not in SESSION_VARS}
        self.env.update(PATH=f"{bin_dir}{os.pathsep}{os.environ['PATH']}", FAKE_HOST_HOME=str(self.host_home),
                        XDG_CACHE_HOME=str(self.tmp / "cache"), IOS_LIVE_HOSTS="fakehost",
                        IOS_LIVE_SLOTS_PER_HOST="3")
        self.checkouts = {}
        for name in ("a", "b"):
            d = self.tmp / f"checkout-{name}"
            d.mkdir()
            subprocess.run(["git", "init", "-q", str(d)], check=True)
            self.checkouts[name] = d

    def call(self, checkout: str, *args: str, **extra: str) -> subprocess.CompletedProcess:
        # A fresh bash per call, so $PPID differs on every one, as in an agent's separate tool calls.
        env = dict(self.env, **extra)
        return subprocess.run(["bash", "-c", '"$0" "$@"', str(CLIENT), *args], cwd=self.checkouts[checkout],
                              env=env, capture_output=True, text=True, timeout=60)

    def ok(self, checkout: str, *args: str, **extra: str) -> str:
        r = self.call(checkout, *args, **extra)
        self.assertEqual(r.returncode, 0, f"ios-live {' '.join(args)}: {r.stdout}\n{r.stderr}")
        return r.stdout.strip()

    def test_lease_survives_separate_shells_without_owner(self) -> None:
        first = self.ok("a", "whoami")
        self.assertEqual(self.ok("a", "whoami"), first)
        self.assertEqual(self.ok("a", "lease", "take").splitlines()[-1], "fakehost/1")
        # A second shell renews the same slot rather than taking another, and beats it as its holder.
        self.assertEqual(self.ok("a", "lease", "take").splitlines()[-1], "fakehost/1")
        self.ok("a", "lease", "beat")
        # Another checkout is another owner: it gets the next slot and cannot beat the first.
        self.assertNotEqual(self.ok("b", "whoami"), first)
        self.assertEqual(self.ok("b", "lease", "take").splitlines()[-1], "fakehost/2")
        held = self.ok("a", "slots")
        self.assertIn(f"fakehost/1\tnot up\t{first} until", held)
        self.assertNotEqual(self.call("b", "lease", "beat", IOS_LIVE_AT="fakehost/1").returncode, 0)

    def test_session_id_and_override(self) -> None:
        a = self.ok("a", "whoami", CLAUDE_CODE_SESSION_ID="sess-1")
        self.assertTrue(a.endswith("/sess-1/checkout-a"), a)
        b = self.ok("b", "whoami", CLAUDE_CODE_SESSION_ID="sess-1")
        self.assertNotEqual(a, b)  # helpers of one session in two checkouts stay apart
        self.assertEqual(self.ok("a", "whoami", CODEX_THREAD_ID="t-9").split("/")[1], "t-9")
        self.assertEqual(self.ok("a", "whoami", IOS_LIVE_OWNER="me/x"), "me/x")


if __name__ == "__main__":
    sys.exit(unittest.main())
