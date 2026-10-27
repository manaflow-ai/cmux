#!/usr/bin/env python3
"""The perf lab's story runner: measures one prebuilt bench app on one lab host.

scripts/measure/perf-lab.sh (the allowlisted fleet entry) runs this at the tip ref, so a bisect midpoint is measured
with today's harness, as Chrome's testers run the tip `tools/perf` against any builder's archive
(`docs/speed/perf_waterfall.md`, `tools/perf/core/bot_platforms.py`). It never builds: the app is the content-addressed
artifact that scripts/measure/perf-lab-build.sh published for (sha, config) (task 009), fetched by digest.

Steps, each refusing with its own exit code and one reason line (stderr and `summary.json`):
1. pick stories of the catalog (catalog.py, stories.d): `--stories a,b`, or `--shard K/N` (0-based K) of `--tier`
   (default T0) for `--config`. Only T0, T1 and T2 stories run on a lab Mac (a builder story builds, a linux story
   needs no Mac). A story with a catalog lint problem, or whose command does not take the runner's flags, is refused;
2. fetch the artifact by `--digest` from the controller store into `--work` (never the uploaded `--out`), check its
   sha256 and that the bundle is a `cmux DEV <tag>.app`, `--config` build whose own CMUXCommit is `--sha` (exit 4
   when it is missing or is another build; 5 when the store does not answer);
3. bring up the 120 Hz virtual display (scripts/ci/frame-pacing/vdisplay.m), held for the whole plan. A host that
   cannot is measured on its real display: the helper's `probe` line goes to host_env, which reports the Hz (60 is
   not a refusal). A run whose virtual display has ended is not run;
4. host_env.py `--pre-launch` (task 006) validates the host and writes its host block to `<out>/host.json`; an
   invalid host exits 3 (env-invalid) and stores nothing;
5. run the stories with interleaved repeats (round r runs every story that has more than r repeats, in id order, as
   Telemetry's `--pageset-repeat` interleaves pages), each in its own process group with the bench env
   (bench_env.py) and its own out folder `<out>/runs/<story>-<repeat>/`;
6. move each result-v1 file a run wrote (in any subfolder) to `<out>/results/`. A file that is not valid result-v1,
   names another build or story, or ran under a triggered safe mode, moves to `<out>/rejected/` so the ingest never
   stores it; so does every file of a run whose app had no ok full host validation after launch (BenchApp's
   `host-env-full-<pid>.json`: network-egress and the other checks, with the app's pids).

A story's `command` gets `--app APP --tag TAG --out RUN_DIR` appended (stories.d/README.md). The session, config, host
block path and vdisplay output come as the PERF_LAB_* variables BenchApp reads as its defaults (bench_launch LAB_*),
with the story, repeat, engine and Hz for the bench's own use. Exit codes: 0 every run wrote results, 1 a run
failed, 2 usage, 3 env-invalid, 4 no such artifact, 5 artifact store unreachable, 128+N stopped by signal N.

Stdlib only; loaded and run under `python3 -I`.
"""
from __future__ import annotations

import argparse
import ast
import glob
import hashlib
import importlib.util
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
from typing import Callable, Dict, List, Optional, Sequence, Tuple

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
HOST_ENV = os.path.join(HERE, "host_env.py")
CONFIGS = ("bench", "bench-checks")  # never debug, and release stories are not lab-Mac stories
MAC_TIERS = ("T0", "T1", "T2")
DIGEST = re.compile(r"^sha256:([0-9a-f]{64})$")
SHA = re.compile(r"^[0-9a-f]{40}$")
DEFAULT_CONTROLLER = "http://100.89.225.106:18765"
ARTIFACT_CACHE_KEEP = 6
TERM_GRACE_SECONDS = 10
HOST_ENV_TIMEOUT_SECONDS = 300
TEARDOWN_TIMEOUT_SECONDS = 300
RUNNER_FLAGS = ("--app", "--tag", "--out")
# Safe-mode states (result-v1 safe_mode) whose features are the ones the series measures: off, inactive (not
# triggered) and None (a build with no feature registry). last_known_good and no_remote run other features.
SAFE_MODES_MEASURED = ("off", "inactive", None)
STOP_SIGNALS = (signal.SIGTERM, signal.SIGINT, signal.SIGHUP)

EXIT_OK, EXIT_RUN_FAILED, EXIT_USAGE, EXIT_ENV_INVALID, EXIT_NO_ARTIFACT, EXIT_STORE_DOWN = 0, 1, 2, 3, 4, 5
ENV_INVALID_AFTER_LAUNCH = "env-invalid after launch"


class Refusal(Exception):
    """The run cannot measure; `code` is the exit code, `kind` the summary's refusal name."""
    code = EXIT_USAGE
    kind = "usage"


class EnvInvalid(Refusal):
    code, kind = EXIT_ENV_INVALID, "env-invalid"


class MissingArtifact(Refusal):
    code, kind = EXIT_NO_ARTIFACT, "missing-artifact"


class StoreUnreachable(Refusal):
    code, kind = EXIT_STORE_DOWN, "store-unreachable"


def load_by_path(name: str, path: str):
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module  # before exec: dataclasses resolve their module through sys.modules
    spec.loader.exec_module(module)
    return module


catalog = load_by_path("perf_lab_catalog", os.path.join(HERE, "catalog.py"))
perf_result = catalog.perf_result


def bench_launch():
    return load_by_path("bench_launch", os.path.join(ROOT, "scripts", "cmux-next", "bench_launch.py"))


def load_stories(root: str = ROOT) -> Tuple[Dict[str, object], Tuple[str, ...]]:
    """({id: catalog.Story}, the catalog's lint problems) of the stories.d under `root`."""
    try:
        loaded = catalog.load_catalog(root)
    except catalog.CatalogError as error:
        raise Refusal(f"the story catalog cannot be read: {error}") from None
    return {story.id: story for story in loaded.stories}, loaded.problems


def shard_assignment(stories: Sequence, count: int) -> Dict[str, int]:
    """{story id: shard} by longest-processing-time bin packing on story seconds, the packing Chrome's
    `generate_perf_sharding.py` does for its shard maps. Depends only on the ids and seconds, never on file order."""
    loads = [0.0] * count
    assignment = {}
    for story in sorted(stories, key=lambda s: (-s.seconds, s.id)):
        shard = min(range(count), key=lambda i: (loads[i], i))
        assignment[story.id] = shard
        loads[shard] += story.seconds
    return assignment


def parse_shard(text: str) -> Tuple[int, int]:
    match = re.fullmatch(r"(\d+)/(\d+)", text or "")
    if not match or not 0 <= int(match.group(1)) < int(match.group(2)):
        raise Refusal(f"--shard={text!r}: expected K/N with 0 <= K < N")
    return int(match.group(1)), int(match.group(2))


def select_stories(stories: Dict[str, object], config: str, names: Optional[str], shard: Optional[str], tier: str,
                   problems: Sequence[str] = ()) -> List:
    if bool(names) == bool(shard):
        raise Refusal("pass exactly one of --stories=a,b and --shard=K/N")
    if names:
        wanted = [n for n in names.split(",") if n]
        unknown = [n for n in wanted if n not in stories]
        if unknown:
            raise Refusal(f"unknown stories: {', '.join(unknown)}")
        blocked = [f"{n} ({stories[n].not_measurable})" for n in wanted if not stories[n].measurable()]
        if blocked:
            raise Refusal(f"stories {', '.join(blocked)} are not measurable yet")
        other = [n for n in wanted if stories[n].config != config]
        if other:
            raise Refusal(f"stories {', '.join(other)} measure another config than {config}")
        off_lab = [f"{n} ({stories[n].tier})" for n in wanted if stories[n].tier not in MAC_TIERS]
        if off_lab:
            raise Refusal(f"stories {', '.join(off_lab)} are not lab-Mac stories ({', '.join(MAC_TIERS)})")
        picked = sorted({stories[n].id: stories[n] for n in wanted}.values(), key=lambda s: s.id)
    else:
        if tier not in MAC_TIERS:
            raise Refusal(f"--tier={tier!r}: one of {', '.join(MAC_TIERS)}")
        index, count = parse_shard(shard)
        pool = [s for s in stories.values() if s.tier == tier and s.config == config and s.measurable()]
        assignment = shard_assignment(pool, count)
        picked = sorted((s for s in pool if assignment[s.id] == index), key=lambda s: s.id)
    linted = [p for s in picked for p in problems if p.startswith(s.path + ":")]
    if linted:
        raise Refusal("the catalog lint refuses the stories: " + "; ".join(linted)[:600])
    return picked


def contract_problems(story, root: str = ROOT) -> List[str]:
    """Why `story`'s command cannot take the flags the runner appends (`--app --tag --out`, stories.d/README.md).
    A Python bench is read with ast, never run (its add_argument names); any other script must name each flag."""
    script = story.command[0]
    try:
        with open(os.path.join(root, script), encoding="utf-8") as f:
            text = f.read()
    except OSError as error:
        return [f"{story.id}: {script} cannot be read ({error.strerror})"]
    if script.endswith(".py"):
        try:
            tree = ast.parse(text, script)
        except SyntaxError as error:
            return [f"{story.id}: {script} does not parse ({error.msg})"]
        named = {arg.value for node in ast.walk(tree)
                 if isinstance(node, ast.Call) and getattr(node.func, "attr", None) == "add_argument"
                 for arg in node.args if isinstance(arg, ast.Constant) and isinstance(arg.value, str)}
    else:
        named = set(re.findall(r"--[a-z][a-z0-9-]*", text))
    missing = [flag for flag in RUNNER_FLAGS if flag not in named]
    if missing:
        return [f"{story.id}: {script} takes no {', '.join(missing)} (the runner appends {' '.join(RUNNER_FLAGS)})"]
    return []


def interleaved(stories: Sequence, repeats: Optional[int]):
    """(story, repeat) in run order: every story's repeat r before any story's repeat r + 1."""
    counts = {s.id: repeats or s.repeats for s in stories}
    for r in range(max(counts.values(), default=0)):
        for story in stories:
            if r < counts[story.id]:
                yield story, r


def run_timeout(story) -> float:
    return 120 + 3 * story.seconds


def display_hold(runs: Sequence) -> int:
    """Seconds the virtual display holds itself: the host check, then every planned run at its worst case (its
    timeout, the group's TERM and KILL graces, a teardown), and a margin."""
    worst = sum(run_timeout(story) + 2 * TERM_GRACE_SECONDS + TEARDOWN_TIMEOUT_SECONDS for story, _ in runs)
    return int(HOST_ENV_TIMEOUT_SECONDS + worst + 300)


def sha256_file(path: str) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


class ArtifactStore:
    """The controller's content-addressed store (`GET /v1/artifacts/sha256:<hex>/url` gives a signed URL, as
    scripts/cmux-next/ensure-cef.sh reads it), with a per-host cache by digest. `urlopen` is the seam tests replace."""

    def __init__(self, controller: str, cache_dir: Optional[str], urlopen: Callable = urllib.request.urlopen):
        self.controller = controller.rstrip("/")
        self.cache_dir = cache_dir
        self.urlopen = urlopen

    def _get(self, url: str, timeout: float):
        request = urllib.request.Request(url, headers={"User-Agent": "cmux-perf-lab"})
        return self.urlopen(request, timeout=timeout)

    def fetch(self, digest: str, dest: str) -> str:
        match = DIGEST.match(digest or "")
        if not match:
            raise MissingArtifact(f"--digest={digest!r} is not sha256:<64 hex>; perf-lab-build.sh prints it")
        hex_digest = match.group(1)
        cached = os.path.join(self.cache_dir, f"{hex_digest}.zip") if self.cache_dir else None
        if cached and os.path.isfile(cached) and sha256_file(cached) == hex_digest:
            shutil.copyfile(cached, dest)
            os.utime(cached)
            return "cache"
        try:
            with self._get(f"{self.controller}/v1/artifacts/sha256:{hex_digest}/url", 30) as reply:
                url = json.load(reply).get("url", "")
            if not url.startswith(("https://", "http://")):
                raise MissingArtifact(f"the artifact store gave no URL for {digest}")
            with self._get(url, 1800) as reply, open(dest, "wb") as out:
                shutil.copyfileobj(reply, out, 1 << 20)
        except urllib.error.HTTPError as error:
            if error.code == 404:
                raise MissingArtifact(f"the artifact store has no {digest} (perf-lab-build.sh never published it)")
            raise StoreUnreachable(f"the artifact store answered {error.code} for {digest}") from None
        except (urllib.error.URLError, OSError, ValueError) as error:
            raise StoreUnreachable(f"could not fetch {digest} from {self.controller}: {error}") from None
        if sha256_file(dest) != hex_digest:
            raise MissingArtifact(f"the bytes fetched for {digest} hash to another digest")
        if cached:
            os.makedirs(self.cache_dir, exist_ok=True)
            shutil.copyfile(dest, cached + ".tmp")
            os.replace(cached + ".tmp", cached)
            zips = sorted((os.path.join(self.cache_dir, n) for n in os.listdir(self.cache_dir) if n.endswith(".zip")),
                          key=os.path.getmtime, reverse=True)
            for old in zips[ARTIFACT_CACHE_KEEP:]:
                os.remove(old)
        return "store"


def ditto_extract(archive: str, dest: str) -> None:
    """ditto keeps the bundle's symlinks, modes and signatures (zipfile does not)."""
    subprocess.run(["/usr/bin/ditto", "-x", "-k", archive, dest], check=True, capture_output=True, timeout=600)


def unpack_app(archive: str, dest: str, sha: str, config: str, extract: Callable = ditto_extract) -> Tuple[str, str]:
    """(app, tag) of the one `cmux DEV <tag>.app` in the artifact, checked with bench_launch's own rules (its main
    executable, its config) to be a `config` build whose Info.plist CMUXCommit is `sha`. Only the bundle's own stamp
    counts: a digest of another commit's build must never be measured under `sha`."""
    try:
        extract(archive, dest)
    except (subprocess.SubprocessError, OSError, ValueError) as error:
        raise MissingArtifact(f"the artifact is not an app archive: {error}") from None
    apps = sorted(os.path.join(dest, n) for n in os.listdir(dest) if n.endswith(".app"))
    if len(apps) != 1:
        raise MissingArtifact(f"the artifact holds {len(apps)} .app bundles, not 1")
    app = apps[0]
    bl = bench_launch()
    if not re.fullmatch(r"cmux DEV .+\.app", os.path.basename(app)):
        raise MissingArtifact(f"{os.path.basename(app)} is not a `cmux DEV <tag>.app` bundle")
    tag = bl.tag_of(app)
    try:
        binary = bl.main_binary(app)
    except SystemExit:
        raise MissingArtifact(f"{os.path.basename(app)} has no executable") from None
    if not bl.info_plist(app).get("CMUXCommit"):
        raise MissingArtifact(f"{os.path.basename(app)} has no CMUXCommit in its Info.plist: the artifact does not "
                              f"say which commit it was built from (perf-lab-build.sh stamps it)")
    try:
        bl.build_config(app, binary, config)
        built = bl.build_sha(app, environ={})
    except bl.RecordError as error:
        raise MissingArtifact(f"the artifact is not a {config} build of {sha}: {error}") from None
    if built != sha:
        raise MissingArtifact(f"the artifact was built from {built}, not {sha}")
    return app, tag


class VirtualDisplay:
    """The private-CGVirtualDisplay helper split-spring.sh uses, as the main display at `hz`. Its own hold time ends
    it even when this process is killed with SIGKILL. Every line it prints goes to `out_path`, the file host_env.py
    reads (`--vdisplay-out`); when no virtual display holds the rate, the helper's `probe` line of the real main
    display follows, so host_env measures the display the stories really get."""

    READY = re.compile(r"ready (\d+) ([\d.]+) main=(\d+)")

    def __init__(self, work: str):
        self.work = work
        self.out_path = os.path.join(work, "vdisplay.out")
        self.helper = os.path.join(work, "VDisplay.app/Contents/MacOS/VDisplay")
        self.process: Optional[subprocess.Popen] = None
        self.drain: Optional[threading.Thread] = None
        self.holding = False  # start() reported the virtual display as the main display

    def start(self, hz: float, hold: int, size: str) -> dict:
        os.makedirs(os.path.dirname(self.helper), exist_ok=True)
        open(self.out_path, "w").close()
        error = self._build_helper()
        if error:
            self._note(f"error: {error}")
            return self.display(hz, f"error: {error}")
        display = self.display(hz, self._launch(hz, hold, size)) if hz else self.display(None, "real display")
        if not display["vdisplay"]:
            self.stop()
            display["probe"] = self._probe()
        self.holding = display["vdisplay"]
        return display

    def alive(self) -> bool:
        """Whether the stories still get the display start() reported: a virtual display needs its helper running."""
        return not self.holding or self.pid is not None

    def _build_helper(self) -> Optional[str]:
        compiled = subprocess.run(["xcrun", "clang", "-fobjc-arc", "-O2", "-Wno-deprecated-declarations", "-framework",
                                   "AppKit", "-framework", "CoreVideo",
                                   os.path.join(ROOT, "scripts/ci/frame-pacing/vdisplay.m"), "-o", self.helper],
                                  capture_output=True, text=True, timeout=300)
        if compiled.returncode != 0:
            return f"the virtual display helper did not compile: {compiled.stderr[-300:]}"
        shutil.copyfile(os.path.join(ROOT, "scripts/ci/frame-pacing/VDisplay-Info.plist"),
                        os.path.join(self.work, "VDisplay.app/Contents/Info.plist"))
        subprocess.run(["codesign", "-s", "-", "--force", os.path.join(self.work, "VDisplay.app")],
                       capture_output=True, timeout=60)
        return None

    def _note(self, line: str) -> None:
        with open(self.out_path, "a", encoding="utf-8") as f:
            f.write(line.rstrip("\n") + "\n")

    def _launch(self, hz: float, hold: int, size: str) -> str:
        self.process = subprocess.Popen([self.helper, str(hz), str(hold), "main", size], stdout=subprocess.PIPE,
                                        stderr=subprocess.DEVNULL, text=True)
        first: List[str] = []
        reported = threading.Event()
        self.drain = threading.Thread(target=self._drain, args=(self.process, first, reported), daemon=True)
        self.drain.start()
        reported.wait(20)  # set by the ready or error line, or by the helper's exit
        return first[0] if first else "error: the virtual display never reported"

    def _drain(self, process: subprocess.Popen, first: List[str], reported: threading.Event) -> None:
        with open(self.out_path, "a", encoding="utf-8") as out:
            for line in process.stdout:  # read to EOF, so the helper never blocks on a full pipe
                out.write(line)
                out.flush()
                if not first and line.startswith(("ready", "error")):
                    first.append(line.strip())
                    reported.set()
        reported.set()

    def _probe(self) -> str:
        try:
            done = subprocess.run([self.helper, "probe"], capture_output=True, text=True, timeout=30)
        except (OSError, subprocess.TimeoutExpired) as error:
            line = f"error: the display probe failed: {error}"
        else:
            line = next((l.strip() for l in done.stdout.splitlines() if l.startswith("main ")),
                        f"error: the display probe printed no main line (exit {done.returncode})")
        self._note(line)
        return line

    @classmethod
    def display(cls, hz: Optional[float], line: str) -> dict:
        """The result's display block: the helper is the main display, ticking within 15 % of the rate."""
        match = cls.READY.match(line)
        ok = bool(hz and match and match.group(1) == match.group(3)
                  and abs(float(match.group(2)) - 1000 / hz) <= 0.15 * 1000 / hz)
        return {"requested_hz": hz, "vdisplay": ok, "refresh_ms": float(match.group(2)) if ok else None,
                "line": line[:300]}

    @property
    def pid(self) -> Optional[int]:
        return self.process.pid if self.process and self.process.poll() is None else None

    def stop(self) -> None:
        if self.process and self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(TERM_GRACE_SECONDS)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
        if self.drain:
            self.drain.join(TERM_GRACE_SECONDS)  # its last lines are in out_path before a probe appends
        self.process, self.drain = None, None


def host_env_check(vdisplay_out: str, host_out: str, path: str = HOST_ENV) -> dict:
    """host_env.py --pre-launch (task 006): its report {ok, reasons[], hz, fingerprint, class, host, ...}, with the
    host block written to `host_out`; raises EnvInvalid unless ok. The app is not running yet, so nettop is skipped
    (the report's checks_skipped says so)."""
    if not os.path.isfile(path):
        raise EnvInvalid("scripts/perf-lab/host_env.py is missing: the host cannot be validated")
    try:
        done = subprocess.run([sys.executable, "-I", path, "--vdisplay-out", vdisplay_out, "--pre-launch",
                               "--host-out", host_out], capture_output=True, text=True,
                              timeout=HOST_ENV_TIMEOUT_SECONDS)
    except subprocess.TimeoutExpired:
        raise EnvInvalid(f"host_env.py did not finish in {HOST_ENV_TIMEOUT_SECONDS} s") from None
    lines = [l[len("HOST-ENV "):] for l in done.stdout.splitlines() if l.startswith("HOST-ENV ")]
    try:
        report = json.loads(lines[-1]) if lines else None
    except ValueError:
        report = None
    if not isinstance(report, dict):
        raise EnvInvalid(f"host_env.py printed no HOST-ENV report (exit {done.returncode}): {done.stderr[-300:]}")
    if report.get("ok") is not True or done.returncode != 0:
        raise EnvInvalid("; ".join(report.get("reasons") or [f"host_env.py exited {done.returncode}"]))
    return report


def story_env(base: Dict[str, str], story, app: str, out: str, sha: str, config: str, repeat: int, hz,
              host_file: str, vdisplay_out: str) -> Dict[str, str]:
    """The bench's environment: the runner's without the bench env's unset switches and without CMUX_CI_SHA (the
    step's ref, not the measured build: the bundle's CMUXCommit names that), plus the bench env and PERF_LAB_*."""
    bench_env = load_by_path("bench_env", os.path.join(HERE, "bench_env.py"))
    bl = bench_launch()
    env = {k: v for k, v in base.items() if k not in bench_env.unset_env() and k != "CMUX_CI_SHA"}
    env.update(bench_env.fixed_env())
    env.update({"PERF_LAB_APP": app, "PERF_LAB_OUT": out, "PERF_LAB_SHA": sha, "PERF_LAB_STORY": story.id,
                "PERF_LAB_REPEAT": str(repeat), "PERF_LAB_ENGINE": story.engine,
                "PERF_LAB_HZ": "" if hz is None else str(hz), bl.LAB_SESSION: story.session, bl.LAB_CONFIG: config,
                bl.LAB_HOST_FILE: host_file, bl.LAB_VDISPLAY_OUT: vdisplay_out})
    return env


def story_argv(story, app: str, tag: str, out: str, root: str = ROOT) -> List[str]:
    """The story's command with the runner's `--app --tag --out`; its first item is a repository path (catalog lint),
    run with python3 or bash by its suffix, since not every bench script is executable."""
    program = os.path.join(root, story.command[0])
    launcher = [sys.executable] if program.endswith(".py") else ["/bin/bash"] if program.endswith(".sh") else []
    return [*launcher, program, *story.command[1:], "--app", app, "--tag", tag, "--out", out]


def host_check_reason(run_dir: str) -> Optional[str]:
    """Why the run's results cannot be stored for its host, from every BenchApp's full validation after launch
    (bench_launch.validate_lab_host) under `run_dir`; None when there is one at least and every one is ok."""
    prefix = bench_launch().LAB_CHECK_PREFIX
    reasons, count = [], 0
    for path in sorted(glob.glob(os.path.join(run_dir, "**", f"{prefix}*.json"), recursive=True)):
        count += 1
        try:
            with open(path, encoding="utf-8") as f:
                report = json.load(f)
        except (OSError, ValueError):
            report = {"reasons": [f"{os.path.relpath(path, run_dir)} unreadable"]}
        if not isinstance(report, dict) or report.get("ok") is not True:
            reasons += (report.get("reasons") if isinstance(report, dict) else None) or ["not ok"]
    if not count:
        return "no full host validation after the app launched (network-egress unchecked)"
    return f"{ENV_INVALID_AFTER_LAUNCH}: {', '.join(sorted(set(reasons)))}" if reasons else None


class Runner:
    """Runs (story, repeat) pairs one at a time; `current` is the running process group, for the signal path."""

    def __init__(self, out: str, app: str, tag: str, sha: str, config: str, hz, teardown: Callable[[str], None],
                 vdisplay_out: str, root: str = ROOT, base_env: Optional[Dict[str, str]] = None):
        self.out, self.app, self.tag, self.sha, self.config, self.hz, self.root = out, app, tag, sha, config, hz, root
        self.vdisplay_out = vdisplay_out
        self.host_file = os.path.join(out, "host.json")
        self.results = os.path.join(out, "results")
        self.rejected = os.path.join(out, "rejected")
        self.logs = os.path.join(out, "logs")
        self.runs = os.path.join(out, "runs")
        for folder in (self.results, self.rejected, self.logs, self.runs):
            os.makedirs(folder, exist_ok=True)
        self.teardown = teardown
        self.base_env = dict(os.environ if base_env is None else base_env)
        self.current: Optional[subprocess.Popen] = None

    def run(self, story, repeat: int) -> dict:
        name = f"{story.id}-{repeat}"
        run_dir = os.path.join(self.runs, name)
        shutil.rmtree(run_dir, ignore_errors=True)
        os.makedirs(run_dir)
        log_path = os.path.join(self.logs, f"{name}.log")
        started = time.monotonic()
        timeout = run_timeout(story)
        with open(log_path, "wb") as log:
            self.current = subprocess.Popen(
                story_argv(story, self.app, self.tag, run_dir, self.root), cwd=self.root, stdout=log,
                stderr=subprocess.STDOUT, start_new_session=True,
                env=story_env(self.base_env, story, self.app, run_dir, self.sha, self.config, repeat, self.hz,
                              self.host_file, self.vdisplay_out))
            try:
                code = self.current.wait(timeout)
                reason = None if code == 0 else f"exit {code}"
            except subprocess.TimeoutExpired:
                reason = f"timed out after {timeout:.0f} s"
            finally:
                self.stop_current()
        host_reason = host_check_reason(run_dir)
        written, rejected = self.collect(story, run_dir, name, host_reason)
        env_invalid = False  # the host, not the story, failed the run (harness_alerts.py counts it as no evidence)
        if reason is None and rejected and host_reason:
            reason = host_reason
            env_invalid = host_reason.startswith(ENV_INVALID_AFTER_LAUNCH)
        if reason is None and not written:
            reason = "wrote no result-v1 file"
        if reason:
            self.teardown(self.app)  # a failed bench may leave its app and daemons to the next story
        return {"story": story.id, "repeat": repeat, "ok": reason is None, "reason": reason, "env_invalid": env_invalid,
                "seconds": round(time.monotonic() - started, 3), "results": written, "rejected": rejected,
                "log": os.path.relpath(log_path, self.out)}

    def collect(self, story, run_dir: str, name: str, host_reason: Optional[str]):
        """Moves every result-v1 file under `run_dir` (subfolders too) to results/ or, with its reason, rejected/."""
        written, rejected = [], []
        for path in sorted(glob.glob(os.path.join(run_dir, "**", "*.ndjson"), recursive=True)):
            relative = os.path.relpath(path, run_dir)
            if os.path.basename(path).startswith("."):
                continue
            why = host_reason
            if why is None:
                try:
                    results = perf_result.read_file(path)
                    wrong = [f"{r.story}/{r.metric}: build {r.build.sha} {r.build.config}" for r in results
                             if r.story != story.id or r.build.sha != self.sha or r.build.config != self.config]
                    unsafe = sorted({str(r.safe_mode) for r in results if r.safe_mode not in SAFE_MODES_MEASURED})
                    why = (f"names another story or build ({'; '.join(wrong)[:300]})" if wrong else
                           f"ran under safe mode {', '.join(unsafe)}" if unsafe else None)
                except perf_result.ResultError as error:
                    why = str(error)[:300]
            stored = f"{name}--{relative.replace(os.sep, '--')}"
            os.replace(path, os.path.join(self.rejected if why else self.results, stored))
            if why:
                rejected.append({"file": stored, "reason": why})
            else:
                written.append(stored)
        return written, rejected

    def stop_current(self) -> None:
        """TERM, then KILL, the running story's whole process group. `current` is cleared only when the stop has
        finished, so a stop that is cut short is done again by the next call."""
        process = self.current
        if process is None:
            return
        for sig in (signal.SIGTERM, signal.SIGKILL):
            try:
                os.killpg(process.pid, sig)
            except (ProcessLookupError, PermissionError):
                break
            try:
                process.wait(TERM_GRACE_SECONDS)
                break
            except subprocess.TimeoutExpired:
                continue
        self.current = None


def tag_teardown(app: str) -> None:
    subprocess.run([sys.executable, "-I", os.path.join(ROOT, "scripts/cmux-next/tag_teardown.py"), app],
                   timeout=TEARDOWN_TIMEOUT_SECONDS, check=False)

def write_json(path: str, obj) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".tmp-")
    with os.fdopen(fd, "w") as f:
        json.dump(obj, f, indent=1)
    os.replace(tmp, path)


def parse_args(argv):
    p = argparse.ArgumentParser(description="Measure a prebuilt bench app on this lab host.")
    p.add_argument("--out", required=True, help="the results folder perf-lab.sh packs and uploads")
    p.add_argument("--work", required=True,
                   help="scratch outside --out: the artifact, the app, the virtual display helper (never uploaded)")
    p.add_argument("--state", help="file perf-lab.sh's exit trap reads: the app and the virtual display's pid")
    p.add_argument("--measure-version", type=int, required=True)
    p.add_argument("--sha", default="")
    p.add_argument("--config", default="bench")
    p.add_argument("--digest", default="")
    p.add_argument("--stories")
    p.add_argument("--shard")
    p.add_argument("--tier", default="T0")
    p.add_argument("--repeats", type=int)
    p.add_argument("--env-only", action="store_true")
    p.add_argument("--vdisplay", type=float, default=120.0, help="Hz; 0 measures on the real display")
    p.add_argument("--vdisplay-hold", type=int, help="seconds the virtual display holds (default: the plan's worst case)")
    p.add_argument("--vdisplay-size", default="1920x1200")
    return p.parse_args(argv)


def not_run(story, repeat: int, reason: str) -> dict:
    """A run the host could not give its story (its virtual display ended): env-invalid, not the story's error."""
    return {"story": story.id, "repeat": repeat, "ok": False, "reason": reason, "env_invalid": True, "seconds": 0,
            "results": [], "rejected": [], "log": None}


def measure(opts, summary: dict, state: dict, store: ArtifactStore, check_env: Callable[[str, str], dict],
            display_factory: Callable[[str], VirtualDisplay], extract: Callable, teardown: Callable[[str], None],
            root: str = ROOT) -> int:
    def save_state():
        if opts.state:
            write_json(opts.state, state)

    runs: List = []
    tag = ""
    if not opts.env_only:
        if not SHA.match(opts.sha):
            raise Refusal(f"--sha={opts.sha!r} is not a full commit")
        if opts.config not in CONFIGS:
            raise Refusal(f"--config={opts.config!r}: one of {', '.join(CONFIGS)}")
        if opts.repeats is not None and opts.repeats < 1:
            raise Refusal("--repeats must be >= 1")
        catalog_stories, problems = load_stories(root)
        stories = select_stories(catalog_stories, opts.config, opts.stories, opts.shard, opts.tier, problems)
        if not stories:
            raise Refusal("no story to run")
        unrunnable = [p for story in stories for p in contract_problems(story, root)]
        if unrunnable:
            raise Refusal("stories whose command cannot take the runner's flags: " + "; ".join(unrunnable)[:600])
        summary["stories"] = [s.id for s in stories]
        runs = list(interleaved(stories, opts.repeats))
        artifact = os.path.join(opts.work, "artifact")
        shutil.rmtree(artifact, ignore_errors=True)
        os.makedirs(os.path.join(artifact, "app"))
        summary["artifact"] = {"digest": opts.digest,
                               "from": store.fetch(opts.digest, os.path.join(artifact, "app.zip"))}
        state["app"], tag = unpack_app(os.path.join(artifact, "app.zip"), os.path.join(artifact, "app"), opts.sha,
                                       opts.config, extract)
        save_state()
    display = display_factory(os.path.join(opts.work, "vdisplay"))
    hold = opts.vdisplay_hold or display_hold(runs)
    try:
        summary["display"] = {**display.start(opts.vdisplay, hold, opts.vdisplay_size), "hold_seconds": hold}
        state["vdisplay_pid"] = display.pid
        save_state()
        summary["env"] = check_env(display.out_path, os.path.join(opts.out, "host.json"))
        if opts.env_only:
            return EXIT_OK
        runner = Runner(opts.out, state["app"], tag, opts.sha, opts.config, summary["env"].get("hz"), teardown,
                        display.out_path, root)
        summary["runs"] = []
        try:
            for index, (story, repeat) in enumerate(runs):
                if not display.alive():
                    summary["runs"] += [not_run(s, r, "the virtual display ended before this run")
                                        for s, r in runs[index:]]
                    break
                summary["runs"].append(runner.run(story, repeat))
        finally:
            runner.stop_current()
        return EXIT_OK if all(run["ok"] for run in summary["runs"]) else EXIT_RUN_FAILED
    finally:
        display.stop()
        if os.path.isfile(display.out_path):
            shutil.copyfile(display.out_path, os.path.join(opts.out, "vdisplay.out"))


def main(argv=None, store=None, check_env=host_env_check, display_factory=VirtualDisplay, extract=ditto_extract,
         teardown=tag_teardown, root=ROOT) -> int:
    opts = parse_args(argv)
    os.makedirs(opts.out, exist_ok=True)
    os.makedirs(opts.work, exist_ok=True)
    store = store or ArtifactStore(os.environ.get("CMUX_CI_CONTROLLER") or DEFAULT_CONTROLLER,
                                   os.path.join(os.environ["CI_SHARED_CACHE_DIR"], "perf-lab-artifacts")
                                   if os.environ.get("CI_SHARED_CACHE_DIR") else None)
    summary = {"measure_version": opts.measure_version, "sha": opts.sha, "config": opts.config, "refusal": None}
    state = {"app": None, "vdisplay_pid": None}
    code = EXIT_OK
    try:
        code = measure(opts, summary, state, store, check_env, display_factory, extract, teardown, root)
    except Refusal as refusal:
        code = refusal.code
        summary["refusal"] = {"kind": refusal.kind, "reason": str(refusal)}
        print(f"perf-lab: {refusal.kind}: {refusal}", file=sys.stderr)
    except SystemExit as stop:
        summary["refusal"] = {"kind": "signal", "reason": f"stopped (exit {stop.code}) during the runs"}
        raise
    finally:
        write_json(os.path.join(opts.out, "env.json" if opts.env_only else "summary.json"), summary)
    for run in summary.get("runs", []):
        print(f"perf-lab: {run['story']}#{run['repeat']} {'ok' if run['ok'] else 'FAILED: ' + run['reason']} "
              f"({len(run['results'])} result files, {run['seconds']} s)")
    return code


def stop_on_signal(signum, _frame):
    """Unwinds main's finally blocks once (the story's process group, the display, the summary): later signals are
    ignored, so a second TERM never cuts that cleanup short."""
    for sig in STOP_SIGNALS:
        signal.signal(sig, signal.SIG_IGN)
    raise SystemExit(128 + signum)


def install_signal_handlers() -> None:
    for sig in STOP_SIGNALS:
        signal.signal(sig, stop_on_signal)


if __name__ == "__main__":
    install_signal_handlers()
    sys.exit(main())
