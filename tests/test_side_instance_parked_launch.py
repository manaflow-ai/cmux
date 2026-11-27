#!/usr/bin/env python3
"""side-instance.sh launch parks the copy by default: its windows go to a display no person looks at.

Leo, 2026-11-22: "when you guys are testing stuff on [a test Mac], if you're trying to capture or whatever, ideally you
guys are in some sort of background, maybe. every now and then i guess it's a little interesting for me to look at,
but usually it's too much of an eyesore to have so much stuff happening."

A parked launch starts the park display (park-display.m) and opens the copy with CMUX_NEXT_NO_ACTIVATE=1 and
CMUX_NEXT_TEST_WINDOW_SCREEN=<its screen>; --shown and --front open it as every launch did before; a park display
that cannot be made falls back to --shown and says so; stop ends the park display with the copy.
`open`, `ps`, `pgrep`, PlistBuddy, codesign, xattr and defaults are stand-ins (the app and the park display are
`sleep` processes this test starts and ends), so this runs anywhere with bash and python3.

Live check on a Mac with a screen (a laptop with a person logged in, 2026-11-22): `side-instance.sh make parktest --from NIGHTLY` then
`launch parktest` said "pid N (parked, on park display screen 1)"; the copy's window sat on the park display's frame,
the front app did not change, CuaDriver's window shot drew it, and `stop` took the display away.
"""

import json
import os
import shutil
import signal
import subprocess
import sys
import textwrap
import time
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import test_side_instance_remake_clears_old_identity as remake  # noqa: E402

SCRIPT = remake.SCRIPT

# open [-n] [-g] [--env K=V]... [--stderr FILE] APP [--args ...]: the park display (it has --ready-file) writes its
# ready line unless FAKE_PARK_FAIL is set; anything else is the copy. Each is a `sleep` whose pid goes to state.json.
OPEN = textwrap.dedent('''\
    #!/usr/bin/env python3
    import json, os, subprocess, sys
    state_path = os.environ["FAKE_STATE"]
    args = sys.argv[1:]
    with open(os.environ["FAKE_OPEN_LOG"], "a") as log:
        log.write(json.dumps(args) + "\\n")
    state = json.load(open(state_path)) if os.path.exists(state_path) else {}
    sleeper = lambda: subprocess.Popen(["sleep", "300"], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                       stderr=subprocess.DEVNULL, start_new_session=True).pid
    if "--ready-file" in args:
        if os.environ.get("FAKE_PARK_FAIL"):
            sys.exit(0)
        state["park_pid"] = sleeper()
        state["park_cmd"] = "/x/park-display.app/Contents/MacOS/park-display --pid-file " + args[args.index("--pid-file") + 1]
        open(args[args.index("--ready-file") + 1], "w").write("ready display=9 screen=2 frame=1702,1107,1440,900\\n")
    else:
        state["app_pid"] = sleeper()
    json.dump(state, open(state_path, "w"))
''')

# The subset of ps the script uses, answering for this test's sleeps only.
PS = textwrap.dedent('''\
    #!/usr/bin/env python3
    import json, os, sys
    state_path = os.environ["FAKE_STATE"]
    state = json.load(open(state_path)) if os.path.exists(state_path) else {}
    def alive(pid):
        if not pid: return False
        try: os.kill(pid, 0)
        except OSError: return False
        # a zombie of an ended sleep still answers kill -0
        try: return "Z" not in open(f"/proc/{pid}/stat").read().split()[2]
        except OSError: pass
        import subprocess
        out = subprocess.run(["/bin/ps", "-o", "stat=", "-p", str(pid)], capture_output=True, text=True).stdout
        return bool(out.strip()) and not out.strip().startswith("Z")
    args = sys.argv[1:]
    app, park, exe = state.get("app_pid"), state.get("park_pid"), os.environ["FAKE_EXE"]
    if args[:1] == ["-axo"]:
        if alive(app): print(f"  {app} {exe}")
    elif "-p" in args:
        pid = int(args[args.index("-p") + 1])
        if pid == app and alive(app): print(exe)
        elif pid == park and alive(park): print(state["park_cmd"] if "command=" in args else "park-display")
''')

# pgrep answers with the park display's pid while it runs, and fails (as pgrep does) when none does.
PGREP = textwrap.dedent('''\
    #!/usr/bin/env python3
    import json, os, sys
    path = os.environ["FAKE_STATE"]
    pid = (json.load(open(path)) if os.path.exists(path) else {}).get("park_pid")
    try:
        os.kill(pid, 0) if pid else sys.exit(1)
    except OSError:
        sys.exit(1)
    print(pid)
''')


class SideInstanceParkedLaunchTests(unittest.TestCase):
    app = remake.SideInstanceRemakeTests.app

    def setUp(self):
        remake.SideInstanceRemakeTests.setUp(self)
        bin_dir = self.tmp / "bin"
        for tool, body in {"open": OPEN, "ps": PS, "pgrep": PGREP}.items():
            (bin_dir / tool).write_text(body)
            (bin_dir / tool).chmod(0o755)
        park = self.tmp / "park-display.app"
        (park / "Contents/MacOS").mkdir(parents=True)
        self.state = self.tmp / "state.json"
        self.open_log = self.tmp / "open.log"
        self.env.update({"FAKE_STATE": str(self.state), "FAKE_OPEN_LOG": str(self.open_log),
                         "SIDE_INSTANCE_PARK_APP": str(park), "SIDE_INSTANCE_BOOT_ID": "boot-1"})
        self.env.pop("CMUX_SIDE_PARK_RETRY", None)
        self.env.pop("CMUX_SIDE_PLACEMENT", None)
        self.addCleanup(self.end_sleepers)
        subprocess.run(["bash", str(SCRIPT), "make", "probe", "--from",
                        str(self.app("nightly", "com.cmuxterm.app.nightly", "cmux-next"))],
                       env=self.env, check=True, capture_output=True, text=True)
        marker = self.tmp / "side/probe/.side-instance"
        copy = dict(line.split("=", 1) for line in marker.read_text().splitlines())["app"]
        self.env["FAKE_EXE"] = f"{copy}/Contents/MacOS/cmux"

    def end_sleepers(self):
        """Ends the sleeps this test started that the script under test did not."""
        if not self.state.exists():
            return
        for key in ("app_pid", "park_pid"):
            pid = json.loads(self.state.read_text()).get(key)
            if pid:
                try:
                    os.kill(pid, signal.SIGTERM)
                except OSError:
                    pass

    def side(self, *args: str, **env: str) -> subprocess.CompletedProcess:
        return subprocess.run(["bash", str(SCRIPT), *args], env={**self.env, **env}, capture_output=True, text=True,
                              timeout=120)

    def opens(self) -> list[list[str]]:
        return [json.loads(line) for line in self.open_log.read_text().splitlines()]

    def copy_open(self) -> list[str]:
        return [args for args in self.opens() if "--ready-file" not in args][-1]

    def gone(self, pid: int) -> bool:
        for _ in range(50):
            out = subprocess.run(["/bin/ps", "-o", "stat=", "-p", str(pid)], capture_output=True, text=True).stdout
            if not out.strip() or out.strip().startswith("Z"):
                return True
            subprocess.run(["sleep", "0.1"])
        return False

    def test_launch_parks_the_copy_by_default(self):
        result = self.side("launch", "probe")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("(parked, on park display screen 2)", result.stdout)
        park = [args for args in self.opens() if "--ready-file" in args]
        self.assertEqual(len(park), 1)
        self.assertIn("-g", park[0])
        self.assertEqual(park[0][park[0].index("--pid-file") + 1], str((self.tmp / "side/probe/pid").resolve()))
        copy = self.copy_open()
        self.assertIn("-g", copy)
        self.assertIn("CMUX_NEXT_NO_ACTIVATE=1", copy)
        self.assertIn("CMUX_NEXT_TEST_WINDOW_SCREEN=2", copy)
        for env_value in ("CMUX_NEXT_NO_ACTIVATE=1", "CMUX_NEXT_TEST_WINDOW_SCREEN=2"):
            self.assertEqual(copy[copy.index(env_value) - 1], "--env")

    def test_shown_and_front_open_as_before(self):
        for flag, expected in (("--shown", ["-n", "-g"]), ("--front", ["-n"])):
            with self.subTest(flag=flag):
                self.open_log.unlink(missing_ok=True)
                result = self.side("launch", "probe", flag)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.opens(), [expected + [self.env["FAKE_EXE"].rsplit("/Contents/", 1)[0]]])
                self.assertEqual(self.side("stop", "probe").returncode, 0)

    def test_placement_env_sets_the_default_and_a_flag_wins(self):
        result = self.side("launch", "probe", CMUX_SIDE_PLACEMENT="shown")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("CMUX_NEXT_NO_ACTIVATE=1", self.copy_open())
        self.side("stop", "probe")
        result = self.side("launch", "probe", "--parked", CMUX_SIDE_PLACEMENT="shown")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("CMUX_NEXT_NO_ACTIVATE=1", self.copy_open())
        self.assertNotEqual(self.side("launch", "probe", CMUX_SIDE_PLACEMENT="sideways").returncode, 0)

    def test_no_park_display_falls_back_to_shown_and_says_so(self):
        result = self.side("launch", "probe", FAKE_PARK_FAIL="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("(shown)", result.stdout)
        self.assertIn("no park display", result.stderr)
        self.assertEqual(self.copy_open()[:2], ["-n", "-g"])
        self.assertNotIn("--env", self.copy_open())

    def park_opens(self) -> int:
        return sum("--ready-file" in args for args in self.opens()) if self.open_log.exists() else 0

    def test_a_park_display_that_exits_ends_the_wait_and_is_not_tried_again_this_boot(self):
        # A headless CI Mac (2026-11-26): AppKit never listed the virtual display, park-display.m gave up
        # after 10 s, and every launch still waited 15 s: a `cmux app try` side phase went from 8 s to 25.9 s.
        started = time.monotonic()
        result = self.side("launch", "probe", FAKE_PARK_FAIL="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertLess(time.monotonic() - started, 8, "the wait outlived the park display")
        self.assertIn("exited without a screen", result.stderr)
        self.assertEqual(self.park_opens(), 1)
        self.side("stop", "probe")

        started = time.monotonic()
        result = self.side("launch", "probe", FAKE_PARK_FAIL="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertLess(time.monotonic() - started, 4)
        self.assertIn("failed on this Mac since it started", result.stderr)
        self.assertIn("(shown)", result.stdout)
        self.assertEqual(self.park_opens(), 1, "the park display was tried again in the same boot")
        self.side("stop", "probe")

        for env in ({"CMUX_SIDE_PARK_RETRY": "1"}, {"SIDE_INSTANCE_BOOT_ID": "boot-2"}):
            with self.subTest(env=env):
                before = self.park_opens()
                self.assertEqual(self.side("launch", "probe", FAKE_PARK_FAIL="1", **env).returncode, 0)
                self.assertEqual(self.park_opens(), before + 1)
                self.side("stop", "probe")

    def test_a_park_display_that_works_again_clears_the_failure(self):
        self.assertEqual(self.side("launch", "probe", FAKE_PARK_FAIL="1").returncode, 0)
        self.side("stop", "probe")
        result = self.side("launch", "probe", CMUX_SIDE_PARK_RETRY="1")
        self.assertIn("(parked, on park display screen 2)", result.stdout)
        self.side("stop", "probe")
        result = self.side("launch", "probe")
        self.assertIn("(parked, on park display screen 2)", result.stdout, result.stderr)

    def test_stop_ends_the_park_display_with_the_copy(self):
        self.assertEqual(self.side("launch", "probe").returncode, 0)
        state = json.loads(self.state.read_text())
        result = self.side("stop", "probe")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.gone(state["app_pid"]))
        self.assertTrue(self.gone(state["park_pid"]))
        self.assertFalse((self.tmp / "side/probe/park.pid").exists())

    def test_stop_leaves_a_pid_that_is_no_longer_a_park_display(self):
        self.assertEqual(self.side("launch", "probe").returncode, 0)
        state = json.loads(self.state.read_text())
        state["park_cmd"] = "/usr/bin/something-else"
        self.state.write_text(json.dumps(state))
        self.assertEqual(self.side("stop", "probe").returncode, 0)
        self.assertFalse(self.gone(state["park_pid"]))


if __name__ == "__main__":
    unittest.main()
