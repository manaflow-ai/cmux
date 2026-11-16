#!/usr/bin/env python3
"""bench_memory.owned counts the idle app's own processes once each, by kind (CMUX-571, goal ram-baseline).

The idle bench's Mac rows (scripts/bench/tests/fixtures/idle/perf-10x-idle.log) read `kind=tui-daemon n=4`
at 1, 10 and 50 workspaces: every bundle process of bin/cmux-tui or bin/cmux was a tui-daemon, so the
daemon's hidden-subcommand helpers summed into its 86 MB. And the PTY holder and the terminal hosts, which
the daemon starts with a bare argv[0] (`cmux-holder`, `cmux-tui __terminal-host`), were not counted at
all: their command line has no bundle path. The table below has that shape: the daemon, three helpers,
the chief's daemon, a holder and two hosts, a shell, and another install's host. Off macOS the libproc
and libSystem handles are stubs: the test mocks every call it reaches."""

from __future__ import annotations

import collections
import ctypes
import sys
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
if sys.platform == "darwin":
    import bench_memory as bm  # noqa: E402
else:
    with mock.patch.object(ctypes, "CDLL", mock.MagicMock()):
        import bench_memory as bm  # noqa: E402

BUNDLE = "/tmp/cmux DEV.app"
BIN = BUNDLE + "/Contents/Resources/bin"
APP, DAEMON, CHIEF, HOLDER, HOST1, HOST2, SHELL, STRANGER = 100, 110, 120, 130, 140, 141, 150, 160
OWNER = f"--owner com.cmuxterm.app.debug:-@{DAEMON}"
TABLE = [
    (APP, 1, BUNDLE + "/Contents/MacOS/cmux DEV"),
    (DAEMON, APP, BIN + "/cmux-tui --headless --session cmux-dev --socket /tmp/s.sock"),
    (111, DAEMON, BIN + "/cmux-tui __provider-authority --socket /tmp/p.sock"),
    (112, DAEMON, BIN + "/cmux __agent-browser-provider"),
    (113, DAEMON, BIN + "/cmux-tui __run --state /tmp/state"),
    (CHIEF, APP, BIN + "/cmux-tui --headless --session cmux-chief"),
    (HOLDER, 1, "cmux-holder " + OWNER),
    (HOST1, HOLDER, "cmux-tui __terminal-host --session cmux-dev " + OWNER),
    (HOST2, 1, "cmux-tui __terminal-host --session cmux-dev " + OWNER),
    (SHELL, HOST1, "-zsh"),
    (STRANGER, 1, "cmux-tui __terminal-host --session other --owner com.other:-@999"),
]
# proc_pidpath: the holder runs the bundle's standalone holder; the hosts' paths are unknown here (a
# process this user cannot read), so they count through their owner and parent alone.
EXE = {HOLDER: BIN + "/cmux-holder"}


def owned(exe=EXE):
    with mock.patch.object(bm, "process_table", return_value=TABLE), \
         mock.patch.object(bm, "_responsible", None), \
         mock.patch.object(bm, "exe_path", side_effect=lambda pid: exe.get(pid), create=True):
        return bm.owned(APP, BUNDLE)


def counts(found) -> dict[str, int]:
    return dict(collections.Counter(kind for kind, _cmd in found.values()))


class DaemonKinds(unittest.TestCase):
    def test_the_daemon_row_is_the_daemon_alone(self):
        found = owned()
        self.assertEqual(counts(found).get("tui-daemon"), 1)
        self.assertEqual(found[DAEMON][0], "tui-daemon")
        self.assertEqual(found[CHIEF][0], "tui-daemon-chief")

    def test_each_helper_has_a_kind_of_its_own(self):
        found = owned()
        self.assertEqual(found[111][0], "tui-provider-authority")
        self.assertEqual(found[112][0], "tui-agent-browser-provider")
        self.assertEqual(found[113][0], "tui-run")


class BareNamedProcesses(unittest.TestCase):
    def test_the_holder_and_the_hosts_are_counted(self):
        found = owned()
        self.assertEqual(found[HOLDER][0], "holder")
        self.assertEqual(found[HOST1][0], "terminal-host")
        self.assertEqual(found[HOST2][0], "terminal-host")
        self.assertEqual(counts(found).get("terminal-host"), 2)

    def test_the_holder_counts_by_its_owner_without_its_path(self):
        self.assertEqual(owned(exe={})[HOLDER][0], "holder")

    def test_shells_and_another_installs_host_stay_out(self):
        found = owned()
        self.assertNotIn(SHELL, found)
        self.assertNotIn(STRANGER, found)
        self.assertEqual(sorted(counts(found).values()), [1, 1, 1, 1, 1, 1, 1, 2])


if __name__ == "__main__":
    unittest.main()
