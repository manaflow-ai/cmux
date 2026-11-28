#!/usr/bin/env python3
"""bench_memory.acpmux_cli_env: the bundled acpmux CLI gets the app daemon's ACPMUX_SOCKET together with the
ACPMUX_HOME that daemon runs in (its own environment), never the socket alone, which acpmux refuses beside HOME's own
home (cmux19 step 1e1bb17a129d, 2026-11-28; tab_switch_frames got the same pairing in #64426).
Run: python3 -I scripts/cmux-next/tests/test_bench_memory_acpmux_home.py"""
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import bench_memory as bm  # noqa: E402

HOME = "/Users/cmux/Library/Application Support/cmux-build-worker/work/steps/1e1bb17a/h/.acpmux/builds/com.x"
SOCK = "/tmp/acpmux-501/97fbc03cbe6d9760.sock"
DAEMON = ("/tmp/A.app/Contents/Resources/bin/acpmux daemon run --x HOME=/Users/cmux/h "
          f"ACPMUX_HOME={HOME} ACPMUX_SOCKET={SOCK} PATH=/usr/bin:/bin")


class EnvWords(unittest.TestCase):
    def test_reads_a_home_with_a_space(self):
        self.assertEqual(bm.acpmux_env_words(DAEMON), {"ACPMUX_HOME": HOME, "ACPMUX_SOCKET": SOCK})

    def test_last_value_is_the_environment_one(self):
        out = "x --note ACPMUX_HOME=/argv HOME=/h ACPMUX_HOME=/env"
        self.assertEqual(bm.acpmux_env_words(out), {"ACPMUX_HOME": "/env"})

    def test_absent(self):
        self.assertEqual(bm.acpmux_env_words("/bin/zsh HOME=/h"), {})


class DaemonHome(unittest.TestCase):
    ROWS = [(10, 1, "/bin/zsh"), (11, 1, "/tmp/Other.app/Contents/Resources/bin/acpmux daemon run"),
            (12, 1, "/tmp/A.app/Contents/Resources/bin/acpmux daemon run")]
    ENVS = {11: "acpmux daemon run HOME=/o ACPMUX_HOME=/o/.acpmux ACPMUX_SOCKET=/o/.acpmux/acpmux.sock",
            12: DAEMON}

    def home(self, socket_path):
        return bm.acpmux_daemon_home(socket_path, rows=self.ROWS, read_env=self.ENVS.get)

    def test_the_daemon_serving_the_socket(self):
        self.assertEqual(self.home(SOCK), HOME)
        self.assertEqual(self.home("/o/.acpmux/acpmux.sock"), "/o/.acpmux")

    def test_none_when_no_daemon_serves_it(self):
        self.assertIsNone(self.home("/tmp/acpmux-501/0000000000000000.sock"))
        self.assertIsNone(self.home(None))

    def test_cli_env_pairs_socket_and_home(self):
        env = bm.acpmux_cli_env(SOCK, {"HOME": "/step/home"}, home=HOME)
        self.assertEqual(env, {"HOME": "/step/home", "ACPMUX_SOCKET": SOCK, "ACPMUX_HOME": HOME})


if __name__ == "__main__":
    unittest.main()
