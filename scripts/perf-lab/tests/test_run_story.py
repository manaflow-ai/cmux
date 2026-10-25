"""Tests for scripts/perf-lab/run_story.py and scripts/measure/perf-lab.sh.

Run: python3 -m unittest scripts/perf-lab/tests/test_run_story.py
"""

import hashlib
import importlib.util
import io
import json
import os
import plistlib
import random
import signal
import shutil
import subprocess
import sys
import tempfile
import textwrap
import time
import unittest
import urllib.error
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
PERF_LAB = os.path.dirname(HERE)
ROOT = os.path.dirname(os.path.dirname(PERF_LAB))
ENTRY = os.path.join(ROOT, "scripts", "measure", "perf-lab.sh")
RUNNER = os.path.join(PERF_LAB, "run_story.py")


def load(name, path):
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


rs = load("run_story", RUNNER)

SHA = "0123456789abcdef0123456789abcdef01234567"
OTHER_SHA = "fedcba9876543210fedcba9876543210fedcba98"

# A bench that writes one result-v1 file through the real perf_result.py, and logs its order and environment.
FAKE_BENCH = textwrap.dedent('''
    import importlib.util, json, os, sys
    spec = importlib.util.spec_from_file_location("perf_result", sys.argv[1])
    pr = importlib.util.module_from_spec(spec); sys.modules["perf_result"] = pr; spec.loader.exec_module(pr)
    out, story, repeat, log = sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
    with open(log, "a") as f:
        f.write(json.dumps({"story": story, "repeat": int(repeat), "env": dict(os.environ)}) + "\\n")
    if os.environ.get("FAKE_BENCH_FAIL") == story:
        sys.exit(7)
    host = pr.Host(fingerprint="ab" * 32, host_class="m6-16gb-120hz", chip="Apple M6", macos="26.1",
                   macos_build="25B78", display_hz=120)
    sha = os.environ.get("FAKE_BENCH_SHA") or os.environ["PERF_LAB_SHA"]
    result = pr.Result(story=story, metric="key_to_frame_ms", unit="ms", better="lower", samples=[8.0, 8.5],
                       build=pr.Build(sha=sha, config=os.environ["PERF_LAB_CONFIG"], measure_version=1),
                       host=host, engine="none", session=os.environ["PERF_LAB_SESSION"],
                       run=pr.Run.start(run_id=f"{story}-{repeat}"), safe_mode="off")
    pr.write_ndjson(out, [result])
''')


class FakeStore:
    """The controller store seam: `blobs` maps hex digest -> bytes; `down` makes every request fail."""

    def __init__(self, blobs=None, down=False):
        self.blobs = blobs or {}
        self.down = down
        self.requests = []

    def urlopen(self, request, timeout):
        url = request.full_url
        self.requests.append(url)
        if self.down:
            raise urllib.error.URLError("connection refused")
        if url.endswith("/url"):
            hex_digest = url.rsplit("sha256:", 1)[1][:-len("/url")]
            if hex_digest not in self.blobs:
                raise urllib.error.HTTPError(url, 404, "not found", {}, None)
            return io.BytesIO(json.dumps({"url": f"https://blob.example/{hex_digest}"}).encode())
        return io.BytesIO(self.blobs[url.rsplit("/", 1)[1]])


class FakeDisplay:
    started = []

    def __init__(self, work):
        self.work = work
        self.stopped = False

    def start(self, hz, hold, size):
        FakeDisplay.started.append((hz, hold, size))
        return rs.VirtualDisplay.display(hz, "ready 7 8.33 main=7")

    pid = None

    def stop(self):
        self.stopped = True


def zip_extract(archive, dest):
    with zipfile.ZipFile(archive) as z:
        z.extractall(dest)


def app_zip(path, sha=SHA, config="bench", apps=1):
    """An artifact like perf-lab-build.sh's: one .app whose plist names the commit and whose binary is a bench build."""
    with zipfile.ZipFile(path, "w") as z:
        for index in range(apps):
            app = f"cmux DEV perf{index or ''}.app"
            z.writestr(f"{app}/Contents/Info.plist", plistlib.dumps({"CMUXCommit": sha}))
            binary = b"\0" + (b"CMUX_BENCH_HOOKS_BUILD" if config != "release" else b"") + b"\0"
            z.writestr(f"{app}/Contents/MacOS/cmux DEV", binary)
            if config == "debug":
                z.writestr(f"{app}/Contents/MacOS/cmux DEV.debug.dylib", b"\0")
    with open(path, "rb") as f:
        return "sha256:" + hashlib.sha256(f.read()).hexdigest()


def story(id, tier="T0", seconds=10.0, repeats=2, config="bench", command=("true",)):
    return rs.Story(id=id, tier=tier, command=tuple(command), session="light", engine="none", config=config,
                    repeats=repeats, seconds=seconds)


class ShardTests(unittest.TestCase):
    def setUp(self):
        rng = random.Random(25)
        self.stories = [story(f"s{i:02d}", seconds=rng.randint(5, 90)) for i in range(23)]

    def test_split_is_deterministic_and_independent_of_input_order(self):
        first = rs.shard_assignment(self.stories, 2)
        for seed in range(20):
            shuffled = list(self.stories)
            random.Random(seed).shuffle(shuffled)
            self.assertEqual(rs.shard_assignment(shuffled, 2), first)

    def test_shards_cover_every_story_once_and_balance_seconds(self):
        for count in (1, 2, 3):
            assignment = rs.shard_assignment(self.stories, count)
            self.assertEqual(set(assignment), {s.id for s in self.stories})
            loads = [sum(s.seconds for s in self.stories if assignment[s.id] == k) for k in range(count)]
            # LPT packing: no shard exceeds the lightest by more than the longest story.
            self.assertLessEqual(max(loads) - min(loads), max(s.seconds for s in self.stories))

    def test_select_shard_filters_tier_and_config(self):
        stories = {s.id: s for s in self.stories + [story("t1", tier="T1"), story("chk", config="bench-checks")]}
        picked = [s.id for k in range(2) for s in rs.select_stories(stories, "bench", None, f"{k}/2", "T0")]
        self.assertEqual(sorted(picked), sorted(s.id for s in self.stories))
        self.assertEqual([s.id for s in rs.select_stories(stories, "bench-checks", None, "0/1", "T0")], ["chk"])

    def test_bad_selection_is_refused(self):
        stories = {s.id: s for s in self.stories}
        for names, shard in ((None, None), ("s00", "0/2"), (None, "2/2"), (None, "x"), ("nope", None)):
            with self.assertRaises(rs.Refusal):
                rs.select_stories(stories, "bench", names, shard, "T0")
        with self.assertRaises(rs.Refusal):
            rs.select_stories({"c": story("c", config="bench-checks")}, "bench", "c", None, "T0")

    def test_repeats_interleave(self):
        order = [(s.id, r) for s, r in rs.interleaved([story("a", repeats=3), story("b", repeats=1)], None)]
        self.assertEqual(order, [("a", 0), ("b", 0), ("a", 1), ("a", 2)])
        order = [(s.id, r) for s, r in rs.interleaved([story("a"), story("b")], 2)]
        self.assertEqual(order, [("a", 0), ("b", 0), ("a", 1), ("b", 1)])

    def test_story_file_is_validated(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "x.json")
            with open(path, "w") as f:
                json.dump({"id": "x", "tier": "T0", "command": "a b", "config": "debug", "repeats": 1,
                           "seconds": 1}, f)
            with self.assertRaisesRegex(rs.Refusal, "config 'debug'"):
                rs.Story.from_file(path)


class MainTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="perf-lab-test-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.out = os.path.join(self.tmp, "out")
        self.stories = os.path.join(self.tmp, "stories.d")
        os.makedirs(self.stories)
        self.log = os.path.join(self.tmp, "bench.log")
        bench = os.path.join(self.tmp, "fake_bench.py")
        with open(bench, "w") as f:
            f.write(FAKE_BENCH)
        command = [sys.executable, "-I", bench, os.path.join(PERF_LAB, "perf_result.py"), "{out}", "{story}",
                   "{repeat}", self.log]
        for sid, seconds in (("home-key", 20), ("term-key", 30), ("idle", 60)):
            with open(os.path.join(self.stories, f"{sid}.json"), "w") as f:
                json.dump({"id": sid, "tier": "T0", "command": command, "session": "light", "engine": "none",
                           "config": "bench", "metrics": [], "repeats": 2, "seconds": seconds, "needs": [],
                           "owner": "PL-arch", "component": "x"}, f)
        self.digest = app_zip(os.path.join(self.tmp, "app.zip"))
        with open(os.path.join(self.tmp, "app.zip"), "rb") as f:
            self.store = FakeStore({self.digest.split(":")[1]: f.read()})
        self.teardowns = []
        self.env_lines = []

    def check_env(self, line):
        self.env_lines.append(line)
        return {"ok": True, "reasons": [], "hz": 120, "fingerprint": "ab" * 32, "class": "m6-16gb-120hz"}

    def run_main(self, *args, store=None, check_env=None):
        argv = ["--out", self.out, "--state", os.path.join(self.out, "state.json"), "--measure-version", "1",
                "--sha", SHA, "--digest", self.digest, *args]
        return rs.main(argv, store=rs.ArtifactStore("http://controller", None, (store or self.store).urlopen),
                       check_env=check_env or self.check_env, display_factory=FakeDisplay, extract=zip_extract,
                       teardown=self.teardowns.append, stories_dir=self.stories)

    def summary(self):
        with open(os.path.join(self.out, "summary.json")) as f:
            return json.load(f)

    def bench_runs(self):
        with open(self.log) as f:
            return [json.loads(line) for line in f]

    def test_runs_stories_interleaved_and_collects_result_files(self):
        self.assertEqual(self.run_main("--stories", "term-key,home-key"), 0)
        runs = self.bench_runs()
        self.assertEqual([(r["story"], r["repeat"]) for r in runs],
                         [("home-key", 0), ("term-key", 0), ("home-key", 1), ("term-key", 1)])
        env = runs[0]["env"]
        self.assertEqual(env["CMUX_FEATURES_SAFE_MODE"], "off")
        self.assertEqual(env["CMUX_CI_SHA"], SHA)
        bench_env = load("bench_env", os.path.join(PERF_LAB, "bench_env.py"))
        for name, value in bench_env.fixed_env().items():
            self.assertEqual(env[name], value)
        summary = self.summary()
        self.assertIsNone(summary["refusal"])
        self.assertEqual(summary["display"]["requested_hz"], 120.0)
        self.assertTrue(summary["display"]["vdisplay"])
        self.assertEqual(self.env_lines, ["ready 7 8.33 main=7"])
        files = sorted(os.listdir(os.path.join(self.out, "results")))
        self.assertEqual(len(files), 4)
        perf_result = load("perf_result", os.path.join(PERF_LAB, "perf_result.py"))
        results = perf_result.read_dir(os.path.join(self.out, "results"))
        self.assertEqual({r.build.sha for r in results}, {SHA})
        self.assertEqual(self.teardowns, [])
        with open(os.path.join(self.out, "state.json")) as f:
            self.assertTrue(json.load(f)["app"].endswith(".app"))

    def test_bench_env_unset_switches_are_removed(self):
        bench_env = load("bench_env", os.path.join(PERF_LAB, "bench_env.py"))
        base = {name: "1" for name in bench_env.unset_env()}
        env = rs.story_env(base, story("a"), "/a.app", "/out", SHA, "bench", 0, 120)
        for name in bench_env.unset_env():
            self.assertNotIn(name, env)

    def test_shard_runs_its_stories_only(self):
        self.assertEqual(self.run_main("--shard", "0/2", "--repeats", "1"), 0)
        first = {r["story"] for r in self.bench_runs()}
        os.remove(self.log)
        shutil.rmtree(self.out)
        self.assertEqual(self.run_main("--shard", "1/2", "--repeats", "1"), 0)
        second = {r["story"] for r in self.bench_runs()}
        self.assertEqual(first | second, {"home-key", "term-key", "idle"})
        self.assertFalse(first & second)
        self.assertEqual(first, {"idle"})  # 60 s alone balances 20 + 30 s

    def test_missing_artifact_exits_4_with_a_reason(self):
        self.digest = "sha256:" + "0" * 64
        self.assertEqual(self.run_main("--stories", "idle"), 4)
        refusal = self.summary()["refusal"]
        self.assertEqual(refusal["kind"], "missing-artifact")
        self.assertIn("has no sha256:" + "0" * 64, refusal["reason"])
        self.assertFalse(os.path.exists(self.log))

    def test_bad_digest_wrong_build_or_config_exits_4(self):
        cases = {"not-a-digest": None, "other-sha": OTHER_SHA, "debug": "debug", "two-apps": "two"}
        for name, variant in cases.items():
            with self.subTest(name):
                shutil.rmtree(self.out, ignore_errors=True)
                if variant is None:
                    self.digest = "sha256:xyz"
                    store = self.store
                else:
                    path = os.path.join(self.tmp, f"{name}.zip")
                    self.digest = app_zip(path, sha=variant if variant == OTHER_SHA else SHA,
                                          config="debug" if variant == "debug" else "bench",
                                          apps=2 if variant == "two" else 1)
                    with open(path, "rb") as f:
                        store = FakeStore({self.digest.split(":")[1]: f.read()})
                self.assertEqual(self.run_main("--stories", "idle", store=store), 4)
                self.assertEqual(self.summary()["refusal"]["kind"], "missing-artifact")

    def test_tampered_bytes_exit_4(self):
        hex_digest = self.digest.split(":")[1]
        self.assertEqual(self.run_main("--stories", "idle", store=FakeStore({hex_digest: b"other bytes"})), 4)
        self.assertIn("another digest", self.summary()["refusal"]["reason"])

    def test_store_down_exits_5(self):
        self.assertEqual(self.run_main("--stories", "idle", store=FakeStore(down=True)), 5)
        self.assertEqual(self.summary()["refusal"]["kind"], "store-unreachable")

    def test_env_invalid_exits_3_and_runs_nothing(self):
        host_env = os.path.join(self.tmp, "host_env.py")
        with open(host_env, "w") as f:
            f.write('import json\nprint(json.dumps({"ok": False, "reasons": ["no-gui-session", '
                    '"network-egress: cmux-tui 1.2.3.4:443"], "hz": 120}))\n')
        self.assertEqual(self.run_main("--stories", "idle",
                                       check_env=lambda line: rs.host_env_check(line, path=host_env)), 3)
        refusal = self.summary()["refusal"]
        self.assertEqual(refusal["kind"], "env-invalid")
        self.assertIn("no-gui-session", refusal["reason"])
        self.assertIn("network-egress", refusal["reason"])
        self.assertFalse(os.path.exists(self.log))
        self.assertFalse(os.path.exists(os.path.join(self.out, "results")))  # an invalid host stores nothing

    def test_missing_host_env_is_env_invalid(self):
        with self.assertRaises(rs.EnvInvalid):
            rs.host_env_check("ready", path=os.path.join(self.tmp, "absent.py"))

    def test_failed_story_tears_down_and_exits_1(self):
        os.environ["FAKE_BENCH_FAIL"] = "home-key"
        self.addCleanup(os.environ.pop, "FAKE_BENCH_FAIL", None)
        self.assertEqual(self.run_main("--stories", "home-key,idle", "--repeats", "1"), 1)
        runs = self.summary()["runs"]
        self.assertEqual([(r["story"], r["ok"]) for r in runs], [("home-key", False), ("idle", True)])
        self.assertEqual(runs[0]["reason"], "exit 7")
        self.assertEqual(len(self.teardowns), 1)

    def test_result_of_another_build_is_rejected(self):
        os.environ["FAKE_BENCH_SHA"] = OTHER_SHA
        self.addCleanup(os.environ.pop, "FAKE_BENCH_SHA", None)
        self.assertEqual(self.run_main("--stories", "idle", "--repeats", "1"), 1)
        run = self.summary()["runs"][0]
        self.assertEqual(run["reason"], "wrote no result-v1 file")
        self.assertEqual(len(run["rejected"]), 1)
        self.assertEqual(os.listdir(os.path.join(self.out, "results")), [])
        self.assertEqual(len(os.listdir(os.path.join(self.out, "rejected"))), 1)

    def test_env_only_validates_without_an_artifact(self):
        argv = ["--out", self.out, "--measure-version", "1", "--env-only"]
        code = rs.main(argv, store=rs.ArtifactStore("http://controller", None, FakeStore(down=True).urlopen),
                       check_env=self.check_env, display_factory=FakeDisplay, extract=zip_extract,
                       teardown=self.teardowns.append, stories_dir=self.stories)
        self.assertEqual(code, 0)
        with open(os.path.join(self.out, "env.json")) as f:
            self.assertTrue(json.load(f)["env"]["ok"])

    def test_artifact_cache_by_digest(self):
        cache = os.path.join(self.tmp, "cache")
        store = rs.ArtifactStore("http://controller", cache, self.store.urlopen)
        self.assertEqual(store.fetch(self.digest, os.path.join(self.tmp, "a.zip")), "store")
        self.assertEqual(store.fetch(self.digest, os.path.join(self.tmp, "b.zip")), "cache")
        self.assertEqual(len(self.store.requests), 2)  # the URL and the blob, once


class DisplayTests(unittest.TestCase):
    def test_ready_line(self):
        self.assertTrue(rs.VirtualDisplay.display(120, "ready 5 8.40 main=5")["vdisplay"])
        self.assertFalse(rs.VirtualDisplay.display(120, "ready 5 16.6 main=5")["vdisplay"])
        self.assertFalse(rs.VirtualDisplay.display(120, "ready 5 8.33 main=1")["vdisplay"])
        self.assertIsNone(rs.VirtualDisplay.display(120, "error: no display")["refresh_ms"])


class EntryTests(unittest.TestCase):
    def test_never_builds(self):
        for path in (ENTRY, RUNNER):
            with open(path) as f:
                text = f.read()
            for word in ("reload.sh", "xcodebuild", "swift build"):
                self.assertNotIn(word, text, f"{path} names {word}")

    def test_measure_version(self):
        with open(ENTRY) as f:
            self.assertRegex(f.read(), r"(?m)^PERF_LAB_MEASURE_VERSION=1$")

    def fake_checkout(self, runner_body):
        """A git checkout holding perf-lab.sh, a stub runner and a stub tag_teardown.py that logs its argument."""
        root = tempfile.mkdtemp(prefix="perf-lab-entry-")
        self.addCleanup(shutil.rmtree, root, True)
        for folder in ("scripts/measure", "scripts/perf-lab", "scripts/cmux-next"):
            os.makedirs(os.path.join(root, folder))
        shutil.copy(ENTRY, os.path.join(root, "scripts/measure/perf-lab.sh"))
        with open(os.path.join(root, "scripts/perf-lab/run_story.py"), "w") as f:
            f.write(textwrap.dedent('''
                import json, os, sys, time
                state = sys.argv[sys.argv.index("--state") + 1]
                with open(state, "w") as f:
                    json.dump({"app": "/lab/cmux DEV perf.app", "vdisplay_pid": None}, f)
            ''') + textwrap.dedent(runner_body))
        with open(os.path.join(root, "scripts/cmux-next/tag_teardown.py"), "w") as f:
            f.write("import os, sys\nopen(os.environ['TEARDOWN_LOG'], 'a').write(sys.argv[1] + '\\n')\n")
        subprocess.run(["git", "init", "-q", root], check=True)
        return root

    def run_entry(self, root, wait_for=None, sig=None):
        log = os.path.join(root, "teardown.log")
        env = {**os.environ, "TEARDOWN_LOG": log, "MARKER": os.path.join(root, "marker")}
        process = subprocess.Popen(["bash", os.path.join(root, "scripts/measure/perf-lab.sh"), "--sha=x"], cwd=root,
                                   env=env)
        if sig:
            deadline = time.monotonic() + 30
            while not os.path.exists(env["MARKER"]) and time.monotonic() < deadline:
                time.sleep(0.05)  # test-side wait for the stub runner to start
            process.send_signal(sig)
        code = process.wait(60)
        with open(log) as f:
            return code, f.read().splitlines()

    def test_exit_trap_tears_down_after_a_refusal(self):
        root = self.fake_checkout("sys.exit(4)\n")
        code, calls = self.run_entry(root)
        self.assertEqual(code, 4)
        self.assertEqual(calls, ["/lab/cmux DEV perf.app"])

    def test_term_stops_the_runner_and_tears_down(self):
        root = self.fake_checkout('''
            open(os.environ["MARKER"], "w").close()
            time.sleep(60)
            open(os.environ["MARKER"] + ".survived", "w").close()
        ''')
        started = time.monotonic()
        code, calls = self.run_entry(root, sig=signal.SIGTERM)
        self.assertEqual(code, 128 + signal.SIGTERM)
        self.assertLess(time.monotonic() - started, 30)
        self.assertEqual(calls, ["/lab/cmux DEV perf.app"])
        time.sleep(0.2)
        self.assertFalse(os.path.exists(os.path.join(root, "marker.survived")))


if __name__ == "__main__":
    unittest.main()
