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

# A bench that writes one result-v1 file through the real perf_result.py, and logs its argv, order and environment.
FAKE_BENCH = textwrap.dedent('''
    import argparse, importlib.util, json, os, sys
    spec = importlib.util.spec_from_file_location("perf_result", os.environ["FAKE_PERF_RESULT"])
    pr = importlib.util.module_from_spec(spec); sys.modules["perf_result"] = pr; spec.loader.exec_module(pr)
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
    host = pr.Host(fingerprint="ab" * 32, host_class="m6-16gb-120hz", chip="Apple M6", macos="26.1",
                   macos_build="25B78", display_hz=120)
    sha = os.environ.get("FAKE_BENCH_SHA") or os.environ["PERF_LAB_SHA"]
    result = pr.Result(story=story, metric="key_to_frame_ms", unit="ms", better="lower", samples=[8.0, 8.5],
                       build=pr.Build(sha=sha, config=os.environ["PERF_LAB_CONFIG"], measure_version=1),
                       host=host, engine="none", session=os.environ["PERF_LAB_SESSION"],
                       run=pr.Run.start(run_id=f"{story}-{repeat}"), safe_mode="off")
    pr.write_ndjson(opts.out, [result])
''')

OWNERS_MD = "# owners\n\n| Area | Path | Owner |\n| --- | --- | --- |\n| Lab | scripts/perf-lab | PL-arch |\n"


def write_catalog_root(root, stories):
    """A repository tree catalog.load_catalog reads (OWNERS.md, targets.json, the hot-path map), the fake bench, and
    `stories` ({id: field overrides}) in stories.d."""
    files = {"plans/cmux-next/OWNERS.md": OWNERS_MD,
             "scripts/perf-lab/targets.json": json.dumps({"schema": "cmux-perf-targets/v1", "targets": []}),
             "scripts/cmux-next/perf-hot-benches.json": json.dumps({"paths": {}}),
             "bench/fake_bench.py": FAKE_BENCH}
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
    started = []

    def __init__(self, work):
        self.work = work
        self.out_path = os.path.join(work, "vdisplay.out")
        self.stopped = False

    def start(self, hz, hold, size):
        FakeDisplay.started.append((hz, hold, size))
        os.makedirs(self.work, exist_ok=True)
        with open(self.out_path, "w") as f:
            f.write("ready 7 8.33 main=7 size=1920x1200 visible=1920x1175\n")
        return rs.VirtualDisplay.display(hz, "ready 7 8.33 main=7")

    pid = None

    def stop(self):
        self.stopped = True


def zip_extract(archive, dest):
    with zipfile.ZipFile(archive) as z:
        z.extractall(dest)


def app_zip(path, sha=SHA, config="bench", apps=1, name="cmux DEV perf"):
    """An artifact like perf-lab-build.sh's: one .app whose plist names the commit and whose binary is a bench build."""
    with zipfile.ZipFile(path, "w") as z:
        for index in range(apps):
            app = f"{name}{index or ''}.app"
            z.writestr(f"{app}/Contents/Info.plist", plistlib.dumps({"CMUXCommit": sha}))
            binary = b"\0" + (b"CMUX_BENCH_HOOKS_BUILD" if config != "release" else b"") + b"\0"
            z.writestr(f"{app}/Contents/MacOS/cmux DEV", binary)
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
        self.root = os.path.join(self.tmp, "repo")
        self.log = os.path.join(self.tmp, "bench.log")
        write_catalog_root(self.root, {"home-key": {"seconds": 20}, "term-key": {"seconds": 30},
                                       "idle": {"seconds": 60}, "build": {"tier": "builder"}})
        for name, value in (("FAKE_BENCH_LOG", self.log), ("FAKE_PERF_RESULT", os.path.join(PERF_LAB,
                                                                                            "perf_result.py"))):
            os.environ[name] = value
            self.addCleanup(os.environ.pop, name, None)
        self.digest = app_zip(os.path.join(self.tmp, "app.zip"))
        with open(os.path.join(self.tmp, "app.zip"), "rb") as f:
            self.store = FakeStore({self.digest.split(":")[1]: f.read()})
        self.teardowns = []
        self.env_calls = []

    def check_env(self, vdisplay_out, host_out):
        with open(vdisplay_out) as f:
            self.env_calls.append((f.read().split()[0], host_out))
        return {"ok": True, "reasons": [], "hz": 120, "fingerprint": "ab" * 32, "class": "m6-16gb-120hz"}

    def run_main(self, *args, store=None, check_env=None):
        argv = ["--out", self.out, "--state", os.path.join(self.out, "state.json"), "--measure-version", "1",
                "--sha", SHA, "--digest", self.digest, *args]
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
        self.assertEqual(self.run_main("--stories", "term-key,home-key"), 0)
        runs = self.bench_runs()
        self.assertEqual([(r["story"], r["repeat"]) for r in runs],
                         [("home-key", 0), ("term-key", 0), ("home-key", 1), ("term-key", 1)])
        self.assertEqual(runs[0]["tag"], "perf")
        self.assertTrue(runs[0]["app"].endswith("/cmux DEV perf.app"))
        self.assertEqual(runs[0]["out"], os.path.join(self.out, "results"))
        env = runs[0]["env"]
        self.assertEqual(env["CMUX_FEATURES_SAFE_MODE"], "off")
        self.assertEqual(env["CMUX_CI_SHA"], SHA)
        self.assertEqual(env["PERF_LAB_HOST_FILE"], os.path.join(self.out, "host.json"))
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
        results = rs.perf_result.read_dir(os.path.join(self.out, "results"))
        self.assertEqual({r.build.sha for r in results}, {SHA})
        self.assertEqual(self.teardowns, [])
        with open(os.path.join(self.out, "state.json")) as f:
            self.assertTrue(json.load(f)["app"].endswith(".app"))

    def test_bench_env_unset_switches_are_removed(self):
        bench_env = load("bench_env", os.path.join(PERF_LAB, "bench_env.py"))
        base = {name: "1" for name in bench_env.unset_env()}
        env = rs.story_env(base, story("a"), "/a.app", "/out", SHA, "bench", 0, 120, "/out/host.json")
        for name in bench_env.unset_env():
            self.assertNotIn(name, env)

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
                 "two-apps": {"apps": 2}, "not-a-dev-bundle": {"name": "cmux"}}
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
                self.assertEqual(self.run_main("--stories", "idle", store=store), 4)
                self.assertEqual(self.summary()["refusal"]["kind"], "missing-artifact")
                self.assertFalse(os.path.exists(self.log))

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
            self.assertEqual(json.load(f), ["--vdisplay-out", os.path.join(self.out, "vdisplay", "vdisplay.out"),
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
        argv = ["--out", self.out, "--measure-version", "1", "--env-only"]
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
