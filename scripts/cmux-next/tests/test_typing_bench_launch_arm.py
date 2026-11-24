#!/usr/bin/env python3
"""typing-frame-bench.py's launch-time A/B plumbing, with no app and no Mac.

A launch-time `--ab` key (LAUNCH_TIME_TUNABLES) is read once at startup, so each arm gets its own launch with the
value written into the build's own `debug-tunables.json`. Three ways that went wrong, each a review finding on
cmux#48152:

* the override file was addressed by `--tag`, which only labels the report: a `--tag` that did not match the bundle
  wrote the file one build reads and launched another, and both arms then measured the build's default;
* the end of the arms wrote `null` for the key instead of removing it, and a stored null reads as a value that is
  set, so the key stayed overridden for whatever ran next;
* `reset_arm` sent a live `debug.tunables set` for a launch-time key, recording a reset that cannot happen in a
  process that already parsed its command line;
* the switch proof was read per row, putting a 20 s-timeout `debug.cef` RPC between a surface's setup and its keys.

Run: python3 -I scripts/cmux-next/tests/test_typing_bench_launch_arm.py"""
import importlib.util, os, sys, tempfile, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, ".."))
BENCH = os.path.join(ROOT, "typing-frame-bench.py")
LAUNCH_KEY = "browserPage.noFrameRateLimit"


def load_bench(bundle_tag="bench-fake", reported_tag="bench-fake", ab=None):
    """typing-frame-bench.py imported with its options parsed, pointed at a scratch state base and a fake bundle.

    `bundle_tag` names the `cmux DEV <tag>.app` the bench was given; `reported_tag` is `--tag`, which labels the
    report. The module parses argv at import, so each case gets its own module object."""
    scratch = tempfile.mkdtemp()
    app = os.path.join(scratch, f"cmux DEV {bundle_tag}.app")
    os.makedirs(app)
    argv, env = sys.argv, os.environ.get("BENCH_LAUNCH_STATE_BASE")
    os.environ["BENCH_LAUNCH_STATE_BASE"] = os.path.join(scratch, "state")
    sys.argv = ["typing-frame-bench.py", "--app", app, "--tag", reported_tag, "--out", scratch]
    if ab:
        sys.argv += ["--ab", ab]
    sys.path.insert(0, ROOT)
    try:
        spec = importlib.util.spec_from_file_location(f"tfb_{bundle_tag}_{ab}", BENCH)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
    finally:
        sys.argv = argv
        sys.path.remove(ROOT)
        if env is None:
            os.environ.pop("BENCH_LAUNCH_STATE_BASE", None)
        else:
            os.environ["BENCH_LAUNCH_STATE_BASE"] = env
    return module


class LaunchTunableFile(unittest.TestCase):
    def test_the_path_comes_off_the_bundle_not_the_report_tag(self):
        bench = load_bench(bundle_tag="real-bundle", reported_tag="a-label-nobody-built")
        path = bench.launch_tunables_path()
        self.assertIn(os.path.join("tags", "real-bundle"), path)
        self.assertNotIn("a-label-nobody-built", path)

    def test_a_value_is_written_and_read_back(self):
        bench = load_bench()
        path = bench.write_launch_tunable(LAUNCH_KEY, True)
        self.assertEqual(bench.json.load(open(path))["values"][LAUNCH_KEY], True)

    def test_none_removes_the_key_instead_of_storing_null(self):
        bench = load_bench()
        bench.write_launch_tunable(LAUNCH_KEY, False)
        path = bench.write_launch_tunable(LAUNCH_KEY, None)
        values = bench.json.load(open(path))["values"]
        self.assertNotIn(LAUNCH_KEY, values, "a stored null reads as a value that is set")

    def test_other_keys_in_the_file_survive(self):
        bench = load_bench()
        path = bench.write_launch_tunable("someone.else", 3)
        bench.write_launch_tunable(LAUNCH_KEY, True)
        bench.write_launch_tunable(LAUNCH_KEY, None)
        self.assertEqual(bench.json.load(open(path))["values"], {"someone.else": 3})


class ResetArm(unittest.TestCase):
    def rpc_calls(self, bench):
        calls = []
        bench.rpc = lambda method, params=None, timeout=60: calls.append((method, params)) or {}
        return calls

    def test_a_launch_time_key_is_not_reset_live(self):
        bench = load_bench(ab=LAUNCH_KEY)
        calls = self.rpc_calls(bench)
        bench.reset_arm()
        self.assertEqual(calls, [], "this process already parsed its command line")

    def test_a_live_key_is_reset(self):
        bench = load_bench(ab="browserPage.drawKeysAtOnce")
        calls = self.rpc_calls(bench)
        bench.reset_arm()
        self.assertEqual(calls, [("debug.tunables",
                                  {"action": "set", "key": "browserPage.drawKeysAtOnce", "value": None})])

    def test_without_ab_nothing_is_sent(self):
        bench = load_bench()
        calls = self.rpc_calls(bench)
        bench.reset_arm()
        self.assertEqual(calls, [])


class LaunchSwitchProof(unittest.TestCase):
    def test_one_read_per_launch_is_shared_by_every_row(self):
        bench = load_bench(ab=LAUNCH_KEY)
        reads = []
        bench.rpc = lambda method, params=None, timeout=60: (
            reads.append(method) or {"launch_switches": ["disable-frame-rate-limit", "disable-gpu-vsync"]})
        bench.LAUNCH_ARM = True
        first = bench.launch_switch_once()
        again = bench.launch_switch_once()
        self.assertEqual(reads, ["debug.cef"], "the row read debug.cef again inside one launch")
        self.assertEqual(first, again)
        self.assertIs(first[0], True)

    def test_the_off_arm_wants_no_switches(self):
        bench = load_bench(ab=LAUNCH_KEY)
        bench.rpc = lambda method, params=None, timeout=60: {"launch_switches": ["disable-gpu-vsync"]}
        bench.LAUNCH_ARM = False
        ok, detail = bench.launch_switch_once()
        self.assertIs(ok, False, "the off arm launched with a switch of the on arm")
        self.assertEqual(detail["launched_with"], ["disable-gpu-vsync"])

    def test_a_live_key_has_no_switch_proof(self):
        bench = load_bench(ab="browserPage.drawKeysAtOnce")
        bench.rpc = lambda method, params=None, timeout=60: self.fail("a live key must not read debug.cef")
        self.assertEqual(bench.launch_switch_once(), (None, None))

    def test_a_new_launch_reads_again(self):
        """`run_session` clears the cache, so the next launch's rows do not carry the last launch's switches."""
        source = open(BENCH).read()
        self.assertIn("global app, SESSION, SOCKET, CONFIG, LAUNCH_SWITCH", source)
        self.assertIn("LAUNCH_SWITCH = None  # one switch proof per launch", source)


if __name__ == "__main__":
    unittest.main()
