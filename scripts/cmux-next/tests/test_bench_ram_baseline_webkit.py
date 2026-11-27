#!/usr/bin/env python3
"""bench_ram_baseline launches a peer app as its own child, so macOS holds the script's responsible
process responsible for the peer's WebKit processes, not the peer, and they are not its descendants
(launchd starts them). tree() counts a WebKit process started since the launch with the peer's
responsible process; one that ran before, or another app's, stays out (review of #38549, F2). Off
macOS the libproc and libSystem handles are stubs: the test mocks every call it reaches."""

from __future__ import annotations

import ctypes
import sys
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
if sys.platform == "darwin":
    import bench_ram_baseline as rb  # noqa: E402
else:
    with mock.patch.object(ctypes, "CDLL", mock.MagicMock()):
        import bench_ram_baseline as rb  # noqa: E402
bm = rb.bench_memory

PEER, HELPER, SCRIPT_OWNER, OTHER = 100, 101, 50, 70
WEBKIT = "/System/Library/Frameworks/WebKit.framework/XPCServices/com.apple.WebKit.WebContent.xpc/Contents/MacOS/com.apple.WebKit.WebContent"
TABLE = [
    (PEER, 1, "/Applications/Peer.app/Contents/MacOS/Peer"),
    (HELPER, PEER, "/Applications/Peer.app/Contents/Frameworks/Peer Helper"),
    (201, 1, WEBKIT),  # the peer's, started after the launch
    (202, 1, WEBKIT),  # the script owner's, running before the launch
    (203, 1, WEBKIT),  # another app's
]
RESPONSIBLE = {PEER: SCRIPT_OWNER, HELPER: SCRIPT_OWNER, 201: SCRIPT_OWNER, 202: SCRIPT_OWNER, 203: OTHER}


class PeerWebKit(unittest.TestCase):
    def pids(self, webkit_before):
        with mock.patch.object(bm, "process_table", return_value=TABLE), \
             mock.patch.object(bm, "_responsible", side_effect=lambda pid: RESPONSIBLE.get(pid, -1)), \
             mock.patch.object(bm, "usage", return_value=(bm.MB, bm.MB)):
            return {row["pid"] for row in rb.tree(PEER, webkit_before)}

    def test_a_launched_peer_counts_its_webkit_processes(self):
        self.assertEqual(self.pids({202}), {PEER, HELPER, 201})

    def test_an_attached_app_counts_only_what_it_is_responsible_for(self):
        self.assertEqual(self.pids(None), {PEER, HELPER})


if __name__ == "__main__":
    unittest.main()
