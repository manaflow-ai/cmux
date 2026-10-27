"""Tests for scripts/perf-lab/run_story.py and scripts/measure/perf-lab.sh.

Run: python3 -m unittest scripts/perf-lab/tests/test_run_story.py
"""

import glob
import hashlib
import importlib.util
import io
import json
import os
import plistlib
import random
import re
import signal
import shutil
import subprocess
import sys
import tarfile
import tempfile
import textwrap
import time
import unittest
from unittest import mock
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

HOST = {"fingerprint": "ab" * 32, "class": "apple-m6/16gb/120hz", "chip": "Apple M6", "macos": "26.1",
        "macos_build": "25B78", "display_hz": 120}

# A bench that records one result-v1 file through the real BenchApp.record (bench_launch.py), with no session, config
# or host of its own: those must come from the runner's environment. It logs its argv, order and environment.
# FAKE_BENCH_SHA writes a result of another build through perf_result instead; FAKE_BENCH_SUBDIR records into a
# subfolder of --out; FAKE_LAB_REPORT is the full host check after "launch" (FAKE_BENCH_SKIP_LAB skips it).
FAKE_BENCH = textwrap.dedent('''
    import argparse, importlib.util, json, os, sys
    def load(name, path):
        spec = importlib.util.spec_from_file_location(name, path)
        module = importlib.util.module_from_spec(spec); sys.modules[name] = module; spec.loader.exec_module(module)
        return module
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--out", required=True)
    opts, rest = parser.parse_known_args()
    story, repeat = os.environ["PERF_LAB_STORY"], int(os.environ["PERF_LAB_REPEAT"])
    with open(os.environ["FAKE_BENCH_LOG"], "a") as f:
        f.write(json.dumps({"story": story, "repeat": repeat, "app": opts.app, "tag": opts.tag, "out": opts.out,
                            "rest": rest, "env": dict(os.environ)}) + "\\n")
    if os.environ.get("FAKE_BENCH_FAIL") == story:
        sys.exit(7)
    out = os.path.join(opts.out, os.environ.get("FAKE_BENCH_SUBDIR", ""))
    if os.environ.get("FAKE_BENCH_SHA"):
        pr = load("perf_result", os.environ["FAKE_PERF_RESULT"])
        host = pr.Host.from_dict(json.load(open(os.environ["PERF_LAB_HOST_FILE"])))
        build = pr.Build(sha=os.environ["FAKE_BENCH_SHA"], config=os.environ["PERF_LAB_CONFIG"], measure_version=1)
        os.makedirs(out, exist_ok=True)
        with open(os.path.join(out, "host-env-full-1.json"), "w") as f:
            f.write('{"ok": true, "reasons": []}')
        pr.write_ndjson(out, [pr.Result(story=story, metric="key_to_frame_ms", unit="ms", better="lower",
                                        samples=[8.0], build=build, host=host, engine="none", session="light",
                                        run=pr.Run.start(), safe_mode="off")])
        sys.exit(0)
    bl = load("bench_launch", os.environ["FAKE_BENCH_LAUNCH"])
    report = json.loads(os.environ.get("FAKE_LAB_REPORT", '{"ok": true, "reasons": []}'))
    app = bl.BenchApp(opts.app, out=out, teardown=False, lab_check=lambda pids: report)
    app.features = ({}, None, os.environ.get("FAKE_SAFE_MODE", "off"))  # what launch() reads from features.list
    if not os.environ.get("FAKE_BENCH_SKIP_LAB"):
        app.validate_lab_host([os.getpid()])  # what launch() does once the app answers
    app.record(story, "key_to_frame_ms", "ms", [8.0, 8.5], "lower", "none")
''')

# A story that ignores TERM (a bench slow to tear down) and logs its process group, for the runner's signal test.
SLOW_BENCH = textwrap.dedent('''
    import argparse, os, signal, time
    parser = argparse.ArgumentParser()
    parser.add_argument("--app")
    parser.add_argument("--tag")
    parser.add_argument("--out")
    parser.parse_known_args()
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    with open(os.environ["SLOW_BENCH_PGID"], "w") as f:
        f.write(str(os.getpgid(0)))
    time.sleep(120)
''')

# A bench that takes --app and --out but no --tag: the runner refuses its story before it fetches anything.
NO_TAG_BENCH = "import argparse\np = argparse.ArgumentParser()\np.add_argument('--app')\np.add_argument('--out')\n"

OWNERS_MD = "# owners\n\n| Area | Path | Owner |\n| --- | --- | --- |\n| Lab | scripts/perf-lab | PL-arch |\n"


def write_catalog_root(root, stories):
    """A repository tree catalog.load_catalog reads (OWNERS.md, targets.json, the hot-path map), the fake bench, and
    `stories` ({id: field overrides}) in stories.d."""
    files = {"plans/cmux-next/OWNERS.md": OWNERS_MD,
             "scripts/perf-lab/targets.json": json.dumps({"schema": "cmux-perf-targets/v1", "targets": []}),
             "scripts/cmux-next/perf-hot-benches.json": json.dumps({"paths": {}}),
             "bench/fake_bench.py": FAKE_BENCH, "bench/slow_bench.py": SLOW_BENCH, "bench/no_tag.py": NO_TAG_BENCH}
    for path, text in files.items():
        os.makedirs(os.path.dirname(os.path.join(root, path)), exist_ok=True)
        with open(os.path.join(root, path), "w") as f:
            f.write(text)
    folder = os.path.join(root, "scripts/perf-lab/stories.d")
    os.makedirs(folder, exist_ok=True)
    for sid, overrides in stories.items():
        doc = {"id": sid, "tier": "T0", "description": f"the {sid} story", "command": ["bench/fake_bench.py"],
               "session": "light", "engine": "none", "config": "bench",
               "metrics": [{"name": "key_to_frame_ms", "unit": "ms", "better": "lower"}], "repeats": 2,
               "seconds": 10, "needs": [], "owner": "PL-arch", "component": "Lab>Test", **overrides}
        with open(os.path.join(folder, f"{sid}.json"), "w") as f:
            json.dump(doc, f)


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
    """The virtual display seam. `alive_runs` is how many alive() answers are True before the helper "ends"
    (None: it never ends)."""
    started = []
    alive_runs = None

    def __init__(self, work):
        self.work = work
        self.out_path = os.path.join(work, "vdisplay.out")
        self.stopped = False
        self.alive_answers = 0

    def start(self, hz, hold, size):
        FakeDisplay.started.append((hz, hold, size))
        os.makedirs(self.work, exist_ok=True)
        with open(self.out_path, "w") as f:
            f.write("ready 7 8.33 main=7 size=1920x1200 visible=1920x1175\n")
        return rs.VirtualDisplay.display(hz, "ready 7 8.33 main=7")

    pid = None

    def alive(self):
        self.alive_answers += 1
        return FakeDisplay.alive_runs is None or self.alive_answers <= FakeDisplay.alive_runs

    def stop(self):
        self.stopped = True


def fake_check_env(vdisplay_out, host_out, hz=120, calls=None):
    """host_env --pre-launch's stand-in: an ok report, and the host block at `host_out` that BenchApp records."""
    with open(vdisplay_out) as f:
        first = f.read().split()[0]
    if calls is not None:
        calls.append((first, host_out))
    with open(host_out, "w") as f:
        json.dump({**HOST, "display_hz": hz}, f)
    return {"ok": True, "reasons": [], "hz": hz, "fingerprint": HOST["fingerprint"], "class": HOST["class"]}


def zip_extract(archive, dest):
    with zipfile.ZipFile(archive) as z:
        z.extractall(dest)


def app_zip(path, sha=SHA, config="bench", apps=1, name="cmux DEV perf", binaries=None):
    """An artifact like perf-lab-build.sh's: one .app whose plist names the commit (sha=None: no CMUXCommit) and whose
    main executable is a bench build. `binaries` ({name: has the bench-hooks marker}) replaces the executables."""
    marker = b"CMUX_BENCH_HOOKS_BUILD"
    with zipfile.ZipFile(path, "w") as z:
        for index in range(apps):
            app = f"{name}{index or ''}.app"
            z.writestr(f"{app}/Contents/Info.plist", plistlib.dumps({"CMUXCommit": sha} if sha else {}))
            for binary, marked in (binaries or {"cmux DEV": config != "release"}).items():
                z.writestr(f"{app}/Contents/MacOS/{binary}", b"\0" + (marker if marked else b"") + b"\0")
            if config == "debug":
                z.writestr(f"{app}/Contents/MacOS/cmux DEV.debug.dylib", b"\0")
    with open(path, "rb") as f:
        return "sha256:" + hashlib.sha256(f.read()).hexdigest()


def story(id, tier="T0", seconds=10, repeats=2, config="bench", command=("bench/fake_bench.py",)):
    return rs.catalog.Story(id=id, path=f"scripts/perf-lab/stories.d/{id}.json", tier=tier, description=id,
                            command=tuple(command), session="light", engine="none", config=config, metrics=(),
                            repeats=repeats, seconds=seconds, needs=(), owner="PL-arch", component="Lab>Test")


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
        self.assertEqual([s.id for s in rs.select_stories(stories, "bench", None, "0/1", "T1")], ["t1"])

    def test_bad_selection_is_refused(self):
        stories = {s.id: s for s in self.stories}
        for names, shard in ((None, None), ("s00", "0/2"), (None, "2/2"), (None, "x"), ("nope", None)):
            with self.assertRaises(rs.Refusal):
                rs.select_stories(stories, "bench", names, shard, "T0")
        with self.assertRaises(rs.Refusal):
            rs.select_stories({"c": story("c", config="bench-checks")}, "bench", "c", None, "T0")

    def test_builder_and_linux_stories_never_run_here(self):
        stories = {"build": story("build", tier="builder"), "diff": story("diff", tier="linux")}
        for name in stories:
            with self.assertRaisesRegex(rs.Refusal, "not lab-Mac stories"):
                rs.select_stories(stories, "bench", name, None, "T0")
        for tier in ("builder", "linux"):
            with self.assertRaisesRegex(rs.Refusal, "--tier"):
                rs.select_stories(stories, "bench", None, "0/1", tier)

    def test_a_story_with_a_lint_problem_is_refused(self):
        stories = {"a": story("a"), "b": story("b")}
        problems = ("scripts/perf-lab/stories.d/b.json: owner 'x' is not an owner in plans/cmux-next/OWNERS.md",
                    "scripts/perf-lab/targets.json: 0 targets")
        self.assertEqual([s.id for s in rs.select_stories(stories, "bench", "a", None, "T0", problems)], ["a"])
        with self.assertRaisesRegex(rs.Refusal, "owner 'x'"):
            rs.select_stories(stories, "bench", None, "0/1", "T0", problems)

    def test_repeats_interleave(self):
        order = [(s.id, r) for s, r in rs.interleaved([story("a", repeats=3), story("b", repeats=1)], None)]
        self.assertEqual(order, [("a", 0), ("b", 0), ("a", 1), ("a", 2)])
        order = [(s.id, r) for s, r in rs.interleaved([story("a"), story("b")], 2)]
        self.assertEqual(order, [("a", 0), ("b", 0), ("a", 1), ("b", 1)])

    def test_repository_catalog_has_a_runnable_t0(self):
        stories, problems = rs.load_stories(ROOT)
        picked = rs.select_stories(stories, "bench", None, "0/1", "T0", problems)
        self.assertTrue(picked)
        self.assertTrue(all(s.tier == "T0" and s.config == "bench" for s in picked))
        # Each T0 command takes the runner's --app --tag --out (read from its argparse, not run).
        for s in picked:
            self.assertEqual(rs.contract_problems(s, ROOT), [], s.id)

    def test_contract_names_a_missing_runner_flag(self):
        root = tempfile.mkdtemp(prefix="perf-lab-contract-")
        self.addCleanup(shutil.rmtree, root, True)
        write_catalog_root(root, {})
        [problem] = rs.contract_problems(story("n", command=("bench/no_tag.py",)), root)
        self.assertIn("takes no --tag", problem)
        self.assertEqual(rs.contract_problems(story("f"), root), [])
        self.assertIn("cannot be read", rs.contract_problems(story("x", command=("bench/absent.py",)), root)[0])

    def test_display_hold_covers_the_whole_plan(self):
        stories, _ = rs.load_stories(ROOT)
        t1 = sorted((s for s in stories.values() if s.tier == "T1" and s.config == "bench"), key=lambda s: s.id)
        runs = list(rs.interleaved(t1, 1))
        self.assertGreater(sum(s.seconds for s, _ in runs), 3600)  # one hour would end mid-shard
        self.assertGreater(rs.display_hold(runs), sum(rs.run_timeout(s) for s, _ in runs))

    def test_story_argv_appends_app_tag_and_out(self):
        argv = rs.story_argv(story("a", command=("scripts/x.py", "--runs", "5")), "/a.app", "perf", "/out", "/repo")
        self.assertEqual(argv, [sys.executable, "/repo/scripts/x.py", "--runs", "5", "--app", "/a.app", "--tag",
                                "perf", "--out", "/out"])
        self.assertEqual(rs.story_argv(story("b", command=("scripts/y.sh",)), "/a.app", "t", "/o", "/r")[:2],
                         ["/bin/bash", "/r/scripts/y.sh"])


class MainTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="perf-lab-test-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.out = os.path.join(self.tmp, "out")
        self.work = os.path.join(self.tmp, "work")
        self.root = os.path.join(self.tmp, "repo")
        self.log = os.path.join(self.tmp, "bench.log")
        write_catalog_root(self.root, {"home-key": {"seconds": 20, "session": "stress"}, "term-key": {"seconds": 30},
                                       "idle": {"seconds": 60}, "build": {"tier": "builder"},
                                       "no-tag": {"command": ["bench/no_tag.py"], "tier": "T1"}})
        for name, value in (("FAKE_BENCH_LOG", self.log),
                            ("FAKE_PERF_RESULT", os.path.join(PERF_LAB, "perf_result.py")),
                            ("FAKE_BENCH_LAUNCH", os.path.join(ROOT, "scripts", "cmux-next", "bench_launch.py"))):
            self.set_env(name, value)
        self.digest = app_zip(os.path.join(self.tmp, "app.zip"))
        with open(os.path.join(self.tmp, "app.zip"), "rb") as f:
            self.store = FakeStore({self.digest.split(":")[1]: f.read()})
        self.teardowns = []
        self.env_calls = []
        self.hz = 120
        FakeDisplay.started, FakeDisplay.alive_runs = [], None
        self.addCleanup(setattr, FakeDisplay, "alive_runs", None)

    def set_env(self, name, value):
        os.environ[name] = value
        self.addCleanup(os.environ.pop, name, None)

    def check_env(self, vdisplay_out, host_out):
        return fake_check_env(vdisplay_out, host_out, self.hz, self.env_calls)

    def run_main(self, *args, store=None, check_env=None):
        argv = ["--out", self.out, "--work", self.work, "--state", os.path.join(self.work, "state.json"),
                "--measure-version", "1", "--sha", SHA, "--digest", self.digest, *args]
        return rs.main(argv, store=rs.ArtifactStore("http://controller", None, (store or self.store).urlopen),
                       check_env=check_env or self.check_env, display_factory=FakeDisplay, extract=zip_extract,
                       teardown=self.teardowns.append, root=self.root)

    def summary(self):
        with open(os.path.join(self.out, "summary.json")) as f:
            return json.load(f)

    def bench_runs(self):
        with open(self.log) as f:
            return [json.loads(line) for line in f]

    def test_runs_stories_interleaved_and_collects_result_files(self):
        self.set_env("CMUX_CI_SHA", OTHER_SHA)  # the step's ref: never the measured build's sha
        self.assertEqual(self.run_main("--stories", "term-key,home-key"), 0)
        runs = self.bench_runs()
        self.assertEqual([(r["story"], r["repeat"]) for r in runs],
                         [("home-key", 0), ("term-key", 0), ("home-key", 1), ("term-key", 1)])
        self.assertEqual(runs[0]["tag"], "perf")
        self.assertTrue(runs[0]["app"].endswith("/cmux DEV perf.app"))
        self.assertTrue(runs[0]["app"].startswith(self.work + os.sep), "the app is never in the uploaded folder")
        self.assertEqual(runs[0]["out"], os.path.join(self.out, "runs", "home-key-0"))
        env = runs[0]["env"]
        self.assertNotIn("CMUX_CI_SHA", env)
        self.assertNotIn("CMUX_FEATURES_SAFE_MODE", env)  # the app strips CMUX_* names: it would measure nothing
        self.assertEqual(env["PERF_LAB_HOST_FILE"], os.path.join(self.out, "host.json"))
        self.assertEqual(env["PERF_LAB_VDISPLAY_OUT"], os.path.join(self.work, "vdisplay", "vdisplay.out"))
        self.assertEqual(env["PERF_LAB_HZ"], "120")
        bench_env = load("bench_env", os.path.join(PERF_LAB, "bench_env.py"))
        for name, value in bench_env.fixed_env().items():
            self.assertEqual(env[name], value)
        summary = self.summary()
        self.assertIsNone(summary["refusal"])
        self.assertEqual(summary["display"]["requested_hz"], 120.0)
        self.assertTrue(summary["display"]["vdisplay"])
        self.assertEqual(self.env_calls, [("ready", os.path.join(self.out, "host.json"))])
        files = sorted(os.listdir(os.path.join(self.out, "results")))
        self.assertEqual(len(files), 4)
        self.assertTrue(all(name.endswith(".ndjson") for name in files), files)
        results = rs.perf_result.read_dir(os.path.join(self.out, "results"))
        self.assertEqual({r.build.sha for r in results}, {SHA})
        self.assertEqual(self.teardowns, [])
        with open(os.path.join(self.work, "state.json")) as f:
            self.assertTrue(json.load(f)["app"].endswith(".app"))
        self.assertFalse(os.path.exists(os.path.join(self.out, "artifact")))
        self.assertFalse(os.path.exists(os.path.join(self.out, "vdisplay")))

    def test_bench_app_record_takes_the_session_config_and_measured_host_from_the_runner(self):
        """A real BenchApp.record under the runner's environment: host.json's Hz, --config and the story's session."""
        self.hz = 60
        self.assertEqual(self.run_main("--stories", "home-key,idle", "--repeats", "1"), 0)
        by_story = {r.story: r for r in rs.perf_result.read_dir(os.path.join(self.out, "results"))}
        self.assertEqual(by_story["home-key"].host.display_hz, 60)
        self.assertEqual(by_story["home-key"].host.fingerprint, HOST["fingerprint"])
        self.assertEqual(by_story["home-key"].build.config, "bench")
        self.assertEqual(by_story["home-key"].session, "stress")
        self.assertEqual(by_story["idle"].session, "light")

    def test_bench_env_unset_switches_and_the_step_sha_are_removed(self):
        bench_env = load("bench_env", os.path.join(PERF_LAB, "bench_env.py"))
        base = {**{name: "1" for name in bench_env.unset_env()}, "CMUX_CI_SHA": OTHER_SHA}
        env = rs.story_env(base, story("a"), "/a.app", "/out", SHA, "bench", 0, 120, "/out/host.json", "/w/vd.out")
        for name in (*bench_env.unset_env(), "CMUX_CI_SHA"):
            self.assertNotIn(name, env)

    def test_results_in_subfolders_are_collected_and_each_run_has_its_own_folder(self):
        self.set_env("FAKE_BENCH_SUBDIR", "panes")
        self.assertEqual(self.run_main("--stories", "idle"), 0)
        files = sorted(os.listdir(os.path.join(self.out, "results")))
        self.assertEqual(len(files), 2)
        self.assertTrue(files[0].startswith("idle-0--panes--") and files[1].startswith("idle-1--panes--"), files)
        self.assertEqual(sorted(os.listdir(os.path.join(self.out, "runs"))), ["idle-0", "idle-1"])
        leftover = [p for p in glob.glob(os.path.join(self.out, "runs", "**", "*.ndjson"), recursive=True)]
        self.assertEqual(leftover, [], "every result-v1 file moves to results/ or rejected/")

    def test_egress_after_launch_rejects_the_runs_results(self):
        self.set_env("FAKE_LAB_REPORT", json.dumps({"ok": False, "reasons": ["network-egress"]}))
        self.assertEqual(self.run_main("--stories", "idle", "--repeats", "1"), 1)
        run = self.summary()["runs"][0]
        self.assertEqual(run["reason"], "env-invalid after launch: network-egress")
        self.assertIs(run["env_invalid"], True)  # the host failed it: no evidence about the story (harness_alerts)
        self.assertEqual(os.listdir(os.path.join(self.out, "results")), [])
        self.assertEqual(len(os.listdir(os.path.join(self.out, "rejected"))), 1)
        self.assertEqual(len(self.teardowns), 1)

    def test_a_run_with_no_full_host_check_stores_nothing(self):
        self.set_env("FAKE_BENCH_SKIP_LAB", "1")
        self.assertEqual(self.run_main("--stories", "idle", "--repeats", "1"), 1)
        self.assertIn("network-egress unchecked", self.summary()["runs"][0]["reason"])
        self.assertIs(self.summary()["runs"][0]["env_invalid"], False)  # the bench skipped its own check
        self.assertEqual(os.listdir(os.path.join(self.out, "results")), [])

    def test_a_result_measured_under_triggered_safe_mode_is_rejected(self):
        self.set_env("FAKE_SAFE_MODE", "last_known_good")
        self.assertEqual(self.run_main("--stories", "idle", "--repeats", "1"), 1)
        [rejected] = self.summary()["runs"][0]["rejected"]
        self.assertIn("safe mode last_known_good", rejected["reason"])

    def test_a_story_whose_command_does_not_take_the_runner_flags_is_refused_before_any_fetch(self):
        self.assertEqual(self.run_main("--stories", "no-tag"), 2)
        self.assertIn("takes no --tag", self.summary()["refusal"]["reason"])
        self.assertEqual(self.store.requests, [])

    def test_the_display_hold_is_the_plan_and_a_dead_display_stops_the_runs(self):
        self.assertEqual(self.run_main("--stories", "idle,home-key", "--repeats", "1"), 0)
        runs = list(rs.interleaved([story("home-key", seconds=20), story("idle", seconds=60)], 1))
        self.assertEqual(FakeDisplay.started[-1][1], rs.display_hold(runs))
        self.assertEqual(self.summary()["display"]["hold_seconds"], rs.display_hold(runs))
        self.assertEqual(self.run_main("--stories", "idle", "--repeats", "1", "--vdisplay-hold", "99"), 0)
        self.assertEqual(FakeDisplay.started[-1][1], 99)
        os.remove(self.log)
        FakeDisplay.alive_runs = 1
        self.assertEqual(self.run_main("--stories", "idle,home-key", "--repeats", "1"), 1)
        self.assertEqual([r["story"] for r in self.bench_runs()], ["home-key"])
        self.assertEqual([(r["story"], r["reason"], r["env_invalid"]) for r in self.summary()["runs"]],
                         [("home-key", None, False), ("idle", "the virtual display ended before this run", True)])

    def test_shard_runs_its_stories_only(self):
        self.assertEqual(self.run_main("--shard", "0/2", "--repeats", "1"), 0)
        first = {r["story"] for r in self.bench_runs()}
        os.remove(self.log)
        shutil.rmtree(self.out)
        self.assertEqual(self.run_main("--shard", "1/2", "--repeats", "1"), 0)
        second = {r["story"] for r in self.bench_runs()}
        self.assertEqual(first | second, {"home-key", "term-key", "idle"})  # never the builder story
        self.assertFalse(first & second)
        self.assertEqual(first, {"idle"})  # 60 s alone balances 20 + 30 s

    def test_missing_artifact_exits_4_with_a_reason(self):
        self.digest = "sha256:" + "0" * 64
        self.assertEqual(self.run_main("--stories", "idle"), 4)
        refusal = self.summary()["refusal"]
        self.assertEqual(refusal["kind"], "missing-artifact")
        self.assertIn("has no sha256:" + "0" * 64, refusal["reason"])
        self.assertFalse(os.path.exists(self.log))

    def test_bad_digest_wrong_build_config_or_name_exits_4(self):
        cases = {"not-a-digest": {}, "other-sha": {"sha": OTHER_SHA}, "debug": {"config": "debug"},
                 "two-apps": {"apps": 2}, "not-a-dev-bundle": {"name": "cmux"},
                 # No CMUXCommit: the bundle does not say what it is a build of (CMUX_CI_SHA never stands in).
                 "no-commit-stamp": {"sha": None},
                 # The main executable (`cmux DEV`, as BenchApp launches it) is not a bench build, even though an
                 # executable that sorts first is.
                 "main-not-bench": {"binaries": {"a-helper": True, "cmux DEV": False}}}
        for name, variant in cases.items():
            with self.subTest(name):
                shutil.rmtree(self.out, ignore_errors=True)
                if not variant:
                    self.digest = "sha256:xyz"
                    store = self.store
                else:
                    path = os.path.join(self.tmp, f"{name}.zip")
                    self.digest = app_zip(path, **variant)
                    with open(path, "rb") as f:
                        store = FakeStore({self.digest.split(":")[1]: f.read()})
                self.set_env("CMUX_CI_SHA", SHA)
                self.assertEqual(self.run_main("--stories", "idle", store=store), 4)
                self.assertEqual(self.summary()["refusal"]["kind"], "missing-artifact")
                self.assertFalse(os.path.exists(self.log))

    def test_the_main_executable_is_checked_not_the_first_in_sorted_order(self):
        path = os.path.join(self.tmp, "cli.zip")
        self.digest = app_zip(path, binaries={"cmux": False, "cmux DEV": True})  # `cmux` sorts before `cmux DEV`
        with open(path, "rb") as f:
            store = FakeStore({self.digest.split(":")[1]: f.read()})
        self.assertEqual(self.run_main("--stories", "idle", "--repeats", "1", store=store), 0)

    def test_tampered_bytes_exit_4(self):
        hex_digest = self.digest.split(":")[1]
        self.assertEqual(self.run_main("--stories", "idle", store=FakeStore({hex_digest: b"other bytes"})), 4)
        self.assertIn("another digest", self.summary()["refusal"]["reason"])

    def test_store_down_exits_5(self):
        self.assertEqual(self.run_main("--stories", "idle", store=FakeStore(down=True)), 5)
        self.assertEqual(self.summary()["refusal"]["kind"], "store-unreachable")

    def fake_host_env(self, report, code):
        """A host_env.py stand-in that logs its argv and prints `report` as its HOST-ENV line."""
        path = os.path.join(self.tmp, "host_env.py")
        with open(path, "w") as f:
            f.write(textwrap.dedent(f'''
                import json, sys
                open({os.path.join(self.tmp, "host_env.argv")!r}, "w").write(json.dumps(sys.argv[1:]))
                if {report!r}.get("ok"):
                    open(sys.argv[sys.argv.index("--host-out") + 1], "w").write(json.dumps({{**{HOST!r}, "display_hz": {report!r}["hz"]}}))
                print("checking")
                print("HOST-ENV " + json.dumps({report!r}))
                sys.exit({code})
            '''))
        return path

    def test_env_invalid_exits_3_and_runs_nothing(self):
        host_env = self.fake_host_env({"ok": False, "reasons": ["no-gui-session", "thermal-limit"], "hz": 120}, 3)
        self.assertEqual(self.run_main("--stories", "idle",
                                       check_env=lambda vd, host: rs.host_env_check(vd, host, path=host_env)), 3)
        refusal = self.summary()["refusal"]
        self.assertEqual(refusal["kind"], "env-invalid")
        self.assertEqual(refusal["reason"], "no-gui-session; thermal-limit")
        self.assertFalse(os.path.exists(self.log))
        self.assertFalse(os.path.exists(os.path.join(self.out, "results")))  # an invalid host stores nothing
        with open(os.path.join(self.tmp, "host_env.argv")) as f:
            self.assertEqual(json.load(f), ["--vdisplay-out", os.path.join(self.work, "vdisplay", "vdisplay.out"),
                                            "--pre-launch", "--host-out", os.path.join(self.out, "host.json")])

    def test_valid_host_env_report_is_the_summary_env(self):
        host_env = self.fake_host_env({"ok": True, "reasons": [], "hz": 60, "fingerprint": "cd" * 32,
                                       "class": "m6-16gb-60hz", "checks_skipped": ["network-egress"]}, 0)
        self.assertEqual(self.run_main("--stories", "idle", "--repeats", "1",
                                       check_env=lambda vd, host: rs.host_env_check(vd, host, path=host_env)), 0)
        self.assertEqual(self.summary()["env"]["hz"], 60)
        self.assertEqual(self.bench_runs()[0]["env"]["PERF_LAB_HZ"], "60")

    def test_host_env_without_a_report_or_file_is_env_invalid(self):
        with self.assertRaises(rs.EnvInvalid):
            rs.host_env_check("vd", "host", path=os.path.join(self.tmp, "absent.py"))
        silent = os.path.join(self.tmp, "silent.py")
        with open(silent, "w") as f:
            f.write("print('{\"ok\": true}')\n")  # JSON without the HOST-ENV prefix is no report
        with self.assertRaisesRegex(rs.EnvInvalid, "no HOST-ENV report"):
            rs.host_env_check("vd", "host", path=silent)

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

    def test_builder_story_is_refused_before_any_fetch(self):
        self.assertEqual(self.run_main("--stories", "build"), 2)
        self.assertIn("not lab-Mac stories", self.summary()["refusal"]["reason"])
        self.assertEqual(self.store.requests, [])

    def test_env_only_validates_without_an_artifact(self):
        argv = ["--out", self.out, "--work", self.work, "--measure-version", "1", "--env-only"]
        code = rs.main(argv, store=rs.ArtifactStore("http://controller", None, FakeStore(down=True).urlopen),
                       check_env=self.check_env, display_factory=FakeDisplay, extract=zip_extract,
                       teardown=self.teardowns.append, root=self.root)
        self.assertEqual(code, 0)
        with open(os.path.join(self.out, "env.json")) as f:
            self.assertTrue(json.load(f)["env"]["ok"])

    def test_artifact_cache_by_digest(self):
        cache = os.path.join(self.tmp, "cache")
        store = rs.ArtifactStore("http://controller", cache, self.store.urlopen)
        self.assertEqual(store.fetch(self.digest, os.path.join(self.tmp, "a.zip")), "store")
        self.assertEqual(store.fetch(self.digest, os.path.join(self.tmp, "b.zip")), "cache")
        self.assertEqual(len(self.store.requests), 2)  # the URL and the blob, once


class StartupBenchRecordTests(unittest.TestCase):
    """The T0 launch-warm bench (bench-startup.py --out) writes result-v1 through BenchApp.record, with metrics its
    catalog entry declares."""

    def test_bench_startup_records_the_launch_warm_metrics(self):
        tmp = tempfile.mkdtemp(prefix="perf-lab-startup-")
        self.addCleanup(shutil.rmtree, tmp, True)
        digest_zip = os.path.join(tmp, "app.zip")
        app_zip(digest_zip)
        zip_extract(digest_zip, tmp)
        startup = load("perf_lab_bench_startup", os.path.join(ROOT, "scripts", "cmux-next", "bench-startup.py"))
        startup.APPS["perf"] = os.path.join(tmp, "cmux DEV perf.app")

        def bench_app(app, **kwargs):
            return startup.BenchApp(app, host=lambda: dict(HOST), **kwargs)
        with mock.patch.dict(os.environ, {"PERF_LAB_STORY": "launch-warm"}):
            recorder = startup.Recorder(os.path.join(tmp, "out"), "empty", build_config="bench", bench_app=bench_app)
        recorder.app("perf").features = ({}, None, "off")
        runs = [{"first_window_frame_committed": 140.0, "did_finish_launching_end": 90.0},
                {"first_window_frame_committed": 150.0, "did_finish_launching_end": 95.0, "sidebar_rows_shown": 160.0}]
        written = recorder.record("perf", "warm", runs)
        self.assertFalse([m for m, outcome in written.items() if outcome.startswith("not recorded")], written)
        results = rs.perf_result.read_dir(os.path.join(tmp, "out"))
        metrics = {r.metric: r.samples for r in results}
        self.assertEqual(metrics["launch.warm.first_window_frame_committed"], [140.0, 150.0])
        self.assertEqual(metrics["launch.warm.sidebar_rows_shown.missing_runs"], [1])
        self.assertEqual({(r.story, r.build.sha, r.build.config) for r in results}, {("launch-warm", SHA, "bench")})
        stories, _ = rs.load_stories(ROOT)
        patterns = [m.name for m in stories["launch-warm"].metrics]
        for metric in metrics:
            self.assertTrue(any(re.fullmatch(p, metric) for p in patterns), metric)


class DisplayTests(unittest.TestCase):
    def test_ready_line(self):
        self.assertTrue(rs.VirtualDisplay.display(120, "ready 5 8.40 main=5")["vdisplay"])
        self.assertFalse(rs.VirtualDisplay.display(120, "ready 5 16.6 main=5")["vdisplay"])
        self.assertFalse(rs.VirtualDisplay.display(120, "ready 5 8.33 main=1")["vdisplay"])
        self.assertIsNone(rs.VirtualDisplay.display(120, "error: no display")["refresh_ms"])
        self.assertFalse(rs.VirtualDisplay.display(None, "real display")["vdisplay"])

    def test_host_env_reads_the_line_the_display_writes(self):
        host_env = load("perf_lab_host_env", os.path.join(PERF_LAB, "host_env.py"))
        # A failed 120 Hz display is followed by the probe line of the real display: host_env reads the last one.
        text = "ready 5 16.70 main=1 size=1920x1200 visible=1920x1175\nmain 1 16.67\n"
        self.assertEqual(host_env.parse_vdisplay(text), 16.67)


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
        """A git checkout holding perf-lab.sh, a stub runner and a stub tag_teardown.py that logs its argument. The
        stub writes a result into --out and a stand-in app into --work before its body runs."""
        root = tempfile.mkdtemp(prefix="perf-lab-entry-")
        self.addCleanup(shutil.rmtree, root, True)
        for folder in ("scripts/measure", "scripts/perf-lab", "scripts/cmux-next"):
            os.makedirs(os.path.join(root, folder))
        shutil.copy(ENTRY, os.path.join(root, "scripts/measure/perf-lab.sh"))
        with open(os.path.join(root, "scripts/perf-lab/run_story.py"), "w") as f:
            f.write(textwrap.dedent('''
                import json, os, sys, time
                arg = lambda name: sys.argv[sys.argv.index(name) + 1]
                with open(arg("--state"), "w") as f:
                    json.dump({"app": "/lab/cmux DEV perf.app", "vdisplay_pid": None}, f)
                os.makedirs(os.path.join(arg("--out"), "results"))
                open(os.path.join(arg("--out"), "results", "r.ndjson"), "w").write("{}\\n")
                open(os.path.join(arg("--work"), "app.zip"), "w").write("the app")
            ''') + textwrap.dedent(runner_body))
        with open(os.path.join(root, "scripts/cmux-next/tag_teardown.py"), "w") as f:
            f.write("import os, sys\nopen(os.environ['TEARDOWN_LOG'], 'a').write(sys.argv[1] + '\\n')\n")
        subprocess.run(["git", "init", "-q", root], check=True)
        return root

    def run_entry(self, root, sig=None):
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

    def assert_packed(self, root):
        """The upload is one file with the results, never the app; the work folder is gone."""
        with tarfile.open(os.path.join(root, "artifacts", "perf-lab.tgz")) as tar:
            names = {os.path.normpath(n) for n in tar.getnames()}
        self.assertIn("results/r.ndjson", names)
        self.assertFalse([n for n in names if "app.zip" in n], names)
        self.assertFalse(os.path.exists(os.path.join(root, "artifacts", "perf-lab-work")))

    def test_exit_trap_tears_down_after_a_refusal(self):
        root = self.fake_checkout("sys.exit(4)\n")
        code, calls = self.run_entry(root)
        self.assertEqual(code, 4)
        self.assertEqual(calls, ["/lab/cmux DEV perf.app"])
        self.assert_packed(root)

    def test_each_stop_signal_stops_the_runner_and_tears_down(self):
        for sig in rs.STOP_SIGNALS:
            with self.subTest(signal.Signals(sig).name):
                root = self.fake_checkout('''
                    open(os.environ["MARKER"], "w").close()
                    time.sleep(60)
                    open(os.environ["MARKER"] + ".survived", "w").close()
                ''')
                started = time.monotonic()
                code, calls = self.run_entry(root, sig=sig)
                self.assertEqual(code, 128 + sig)
                self.assertLess(time.monotonic() - started, 30)
                self.assertEqual(calls, ["/lab/cmux DEV perf.app"])
                time.sleep(0.2)
                self.assertFalse(os.path.exists(os.path.join(root, "marker.survived")))
                self.assert_packed(root)


# Runs the real run_story.main with its signal handlers, the test seams of this module and a short TERM grace.
SIGNAL_DRIVER = textwrap.dedent('''
    import importlib.util, json, sys
    spec = importlib.util.spec_from_file_location("perf_lab_test_run_story", sys.argv[1])
    t = importlib.util.module_from_spec(spec); sys.modules[spec.name] = t; spec.loader.exec_module(t)
    rs = t.rs
    rs.TERM_GRACE_SECONDS = 2
    zip_path, root, argv = sys.argv[2], sys.argv[3], sys.argv[4:]
    blob = open(zip_path, "rb").read()
    store = t.FakeStore({t.hashlib.sha256(blob).hexdigest(): blob})
    rs.install_signal_handlers()
    sys.exit(rs.main(argv, store=rs.ArtifactStore("http://controller", None, store.urlopen),
                     check_env=t.fake_check_env, display_factory=t.FakeDisplay, extract=t.zip_extract,
                     teardown=lambda app: None, root=root))
''')


class RunnerSignalTests(unittest.TestCase):
    def test_a_second_term_never_cuts_the_story_group_teardown_short(self):
        tmp = tempfile.mkdtemp(prefix="perf-lab-signal-")
        self.addCleanup(shutil.rmtree, tmp, True)
        root, out = os.path.join(tmp, "repo"), os.path.join(tmp, "out")
        write_catalog_root(root, {"slow": {"command": ["bench/slow_bench.py"], "repeats": 1}})
        digest = app_zip(os.path.join(tmp, "app.zip"))
        driver = os.path.join(tmp, "driver.py")
        with open(driver, "w") as f:
            f.write(SIGNAL_DRIVER)
        pgid_file = os.path.join(tmp, "pgid")
        process = subprocess.Popen(
            [sys.executable, driver, os.path.abspath(__file__), os.path.join(tmp, "app.zip"), root, "--out", out,
             "--work", os.path.join(tmp, "work"), "--measure-version", "1", "--sha", SHA, "--digest", digest,
             "--stories", "slow"], env={**os.environ, "SLOW_BENCH_PGID": pgid_file})
        deadline = time.monotonic() + 30
        while not os.path.exists(pgid_file) and time.monotonic() < deadline:
            time.sleep(0.05)  # test-side wait for the story to start
        time.sleep(0.2)
        with open(pgid_file) as f:
            pgid = int(f.read())
        process.send_signal(signal.SIGTERM)
        time.sleep(0.5)  # inside the story group's TERM grace (the story ignores TERM)
        process.send_signal(signal.SIGTERM)  # a second TERM, as the worker and perf-lab.sh both send one
        self.assertEqual(process.wait(30), 128 + signal.SIGTERM)
        with self.assertRaises(ProcessLookupError):
            os.killpg(pgid, 0)  # the runner KILLed the whole group after the grace
        with open(os.path.join(out, "summary.json")) as f:
            self.assertEqual(json.load(f)["refusal"]["kind"], "signal")


if __name__ == "__main__":
    unittest.main()
