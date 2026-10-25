#!/usr/bin/env python3
"""The perf lab's story runner: measures one prebuilt bench app on one lab host.

scripts/measure/perf-lab.sh (the allowlisted fleet entry) runs this at the tip ref, so a bisect midpoint is measured
with today's harness, as Chrome's testers run the tip `tools/perf` against any builder's archive
(`docs/speed/perf_waterfall.md`, `tools/perf/core/bot_platforms.py`). It never builds: the app is the content-addressed
artifact that scripts/measure/perf-lab-build.sh published for (sha, config) (task 009), fetched by digest.

Steps, each refusing with its own exit code and one reason line (stderr and `summary.json`):
1. pick the stories: `--stories a,b`, or `--shard K/N` (0-based K) of `--tier` (default T0) for `--config`;
2. fetch the artifact by `--digest` from the controller store, check its sha256 and that the bundle is a `--config`
   build of `--sha` (exit 4 when it is missing or is another build; 5 when the store does not answer);
3. bring up the 120 Hz virtual display (scripts/ci/frame-pacing/vdisplay.m; a host that cannot is measured on its real
   display, and host_env reports the Hz);
4. host_env.py (task 006) validates the host; an invalid host exits 3 (env-invalid) and stores nothing;
5. runs the stories with interleaved repeats (round r runs every story that has more than r repeats, in id order, as
   Telemetry's `--pageset-repeat` interleaves pages), each in its own process group with the bench env
   (bench_env.py) and CMUX_FEATURES_SAFE_MODE=off;
6. keeps the result-v1 files each run wrote in `<out>/results/`; a file that is not valid result-v1, or names another
   build or story, moves to `<out>/rejected/` so the ingest never stores it.

A story's `command` (a string or an argv list from stories.d/<id>.json, task 007) may use {app}, {out}, {config},
{session}, {engine}, {story} and {repeat}; the run also gets them as PERF_LAB_* variables, and CMUX_CI_SHA (the
build sha BenchApp.record falls back to). Exit codes: 0 every run wrote results, 1 a run failed, 2 usage, 3
env-invalid, 4 no such artifact, 5 artifact store unreachable.

Stdlib only; loaded and run under `python3 -I`.
"""
from __future__ import annotations

import argparse
import dataclasses
import hashlib
import importlib.util
import json
import os
import re
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
from typing import Callable, Dict, List, Optional, Sequence

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
STORIES_DIR = os.path.join(HERE, "stories.d")
CONFIGS = ("bench", "bench-checks")  # never debug: a debug app's numbers are never compared with bench ones
DIGEST = re.compile(r"^sha256:([0-9a-f]{64})$")
SHA = re.compile(r"^[0-9a-f]{40}$")
STORY_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]*$")
PLACEHOLDERS = ("app", "out", "config", "session", "engine", "story", "repeat")
DEFAULT_CONTROLLER = "http://100.89.225.106:18765"
ARTIFACT_CACHE_KEEP = 6
TERM_GRACE_SECONDS = 10

EXIT_OK, EXIT_RUN_FAILED, EXIT_USAGE, EXIT_ENV_INVALID, EXIT_NO_ARTIFACT, EXIT_STORE_DOWN = 0, 1, 2, 3, 4, 5


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


@dataclasses.dataclass(frozen=True)
class Story:
    id: str
    tier: str
    command: tuple
    session: str
    engine: str
    config: str
    repeats: int
    seconds: float

    @classmethod
    def from_file(cls, path: str) -> "Story":
        try:
            with open(path, encoding="utf-8") as f:
                obj = json.load(f)
            command = obj["command"]
            command = tuple(shlex.split(command) if isinstance(command, str) else command)
            story = cls(id=obj["id"], tier=obj["tier"], command=command, session=obj.get("session", "light"),
                        engine=obj.get("engine", "none"), config=obj["config"], repeats=int(obj["repeats"]),
                        seconds=float(obj["seconds"]))
        except (OSError, ValueError, KeyError, TypeError) as error:
            raise Refusal(f"{path}: not a story ({type(error).__name__}: {error})") from None
        problems = [why for bad, why in (
            (not STORY_ID.match(str(story.id)), f"id {story.id!r}"),
            (not story.command or not all(isinstance(a, str) for a in story.command), "command"),
            (story.config not in CONFIGS, f"config {story.config!r} (one of {', '.join(CONFIGS)})"),
            (story.repeats < 1, "repeats < 1"), (story.seconds <= 0, "seconds <= 0")) if bad]
        if problems:
            raise Refusal(f"{path}: invalid {'; '.join(problems)}")
        return story


def load_stories(directory: str = STORIES_DIR) -> Dict[str, Story]:
    stories: Dict[str, Story] = {}
    names = sorted(n for n in os.listdir(directory) if n.endswith(".json")) if os.path.isdir(directory) else []
    for name in names:
        story = Story.from_file(os.path.join(directory, name))
        if story.id in stories:
            raise Refusal(f"{directory}: story {story.id} is defined twice")
        stories[story.id] = story
    return stories


def shard_assignment(stories: Sequence[Story], count: int) -> Dict[str, int]:
    """{story id: shard} by longest-processing-time bin packing on story seconds, the packing Chrome's
    `generate_perf_sharding.py` does for its shard maps. Depends only on the ids and seconds, never on file order."""
    loads = [0.0] * count
    assignment = {}
    for story in sorted(stories, key=lambda s: (-s.seconds, s.id)):
        shard = min(range(count), key=lambda i: (loads[i], i))
        assignment[story.id] = shard
        loads[shard] += story.seconds
    return assignment


def parse_shard(text: str):
    match = re.fullmatch(r"(\d+)/(\d+)", text or "")
    if not match or not 0 <= int(match.group(1)) < int(match.group(2)):
        raise Refusal(f"--shard={text!r}: expected K/N with 0 <= K < N")
    return int(match.group(1)), int(match.group(2))


def select_stories(stories: Dict[str, Story], config: str, names: Optional[str], shard: Optional[str],
                   tier: str) -> List[Story]:
    if bool(names) == bool(shard):
        raise Refusal("pass exactly one of --stories=a,b and --shard=K/N")
    if names:
        wanted = [n for n in names.split(",") if n]
        unknown = [n for n in wanted if n not in stories]
        if unknown:
            raise Refusal(f"unknown stories: {', '.join(unknown)}")
        other = [n for n in wanted if stories[n].config != config]
        if other:
            raise Refusal(f"stories {', '.join(other)} measure another config than {config}")
        return sorted({stories[n] for n in wanted}, key=lambda s: s.id)
    index, count = parse_shard(shard)
    pool = [s for s in stories.values() if s.tier == tier and s.config == config]
    assignment = shard_assignment(pool, count)
    return sorted((s for s in pool if assignment[s.id] == index), key=lambda s: s.id)


def interleaved(stories: Sequence[Story], repeats: Optional[int]):
    """(story, repeat) in run order: every story's repeat r before any story's repeat r + 1."""
    counts = {s.id: repeats or s.repeats for s in stories}
    for r in range(max(counts.values(), default=0)):
        for story in stories:
            if r < counts[story.id]:
                yield story, r


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


def unpack_app(archive: str, dest: str, sha: str, config: str, extract: Callable = ditto_extract) -> str:
    """The one .app in the artifact, checked to be a `config` build of `sha` (bench_launch's own rules)."""
    try:
        extract(archive, dest)
    except (subprocess.SubprocessError, OSError, ValueError) as error:
        raise MissingArtifact(f"the artifact is not an app archive: {error}") from None
    apps = sorted(os.path.join(dest, n) for n in os.listdir(dest) if n.endswith(".app"))
    if len(apps) != 1:
        raise MissingArtifact(f"the artifact holds {len(apps)} .app bundles, not 1")
    app = apps[0]
    bench_launch = load_by_path("bench_launch", os.path.join(ROOT, "scripts", "cmux-next", "bench_launch.py"))
    macos = os.path.join(app, "Contents/MacOS")
    binaries = sorted(os.path.join(macos, n) for n in (os.listdir(macos) if os.path.isdir(macos) else [])
                      if not n.endswith(".dylib"))
    if not binaries:
        raise MissingArtifact(f"{os.path.basename(app)} has no executable")
    try:
        bench_launch.build_config(app, binaries[0], config)
        built = bench_launch.build_sha(app, environ={"CMUX_CI_SHA": sha})
    except bench_launch.RecordError as error:
        raise MissingArtifact(f"the artifact is not a {config} build of {sha}: {error}") from None
    if built != sha:
        raise MissingArtifact(f"the artifact was built from {built}, not {sha}")
    return app


class VirtualDisplay:
    """The private-CGVirtualDisplay helper split-spring.sh uses, as the main display at `hz`. Its own hold time ends
    it even when this process is killed with SIGKILL."""

    READY = re.compile(r"ready (\d+) ([\d.]+) main=(\d+)")

    def __init__(self, work: str):
        self.work = work
        self.process: Optional[subprocess.Popen] = None

    def start(self, hz: float, hold: int, size: str) -> dict:
        helper = os.path.join(self.work, "VDisplay.app/Contents/MacOS/VDisplay")
        os.makedirs(os.path.dirname(helper), exist_ok=True)
        compiled = subprocess.run(["xcrun", "clang", "-fobjc-arc", "-O2", "-Wno-deprecated-declarations", "-framework",
                                   "AppKit", "-framework", "CoreVideo",
                                   os.path.join(ROOT, "scripts/ci/frame-pacing/vdisplay.m"), "-o", helper],
                                  capture_output=True, text=True, timeout=300)
        if compiled.returncode != 0:
            return self.display(hz, f"error: the virtual display helper did not compile: {compiled.stderr[-300:]}")
        shutil.copyfile(os.path.join(ROOT, "scripts/ci/frame-pacing/VDisplay-Info.plist"),
                        os.path.join(self.work, "VDisplay.app/Contents/Info.plist"))
        subprocess.run(["codesign", "-s", "-", "--force", os.path.join(self.work, "VDisplay.app")],
                       capture_output=True, timeout=60)
        self.process = subprocess.Popen([helper, str(hz), str(hold), "main", size], stdout=subprocess.PIPE,
                                        stderr=subprocess.DEVNULL, text=True)
        first: List[str] = []
        reported = threading.Event()
        threading.Thread(target=self._drain, args=(first, reported), daemon=True).start()
        reported.wait(20)  # set by the ready or error line, or by the helper's exit
        line = first[0] if first else "error: the virtual display never reported"
        display = self.display(hz, line)
        if not display["vdisplay"]:
            self.stop()
        return display

    def _drain(self, first: List[str], reported: threading.Event) -> None:
        for line in self.process.stdout:  # read to EOF, so the helper never blocks on a full pipe
            if not first and line.startswith(("ready", "error")):
                first.append(line.strip())
                reported.set()
        reported.set()

    @classmethod
    def display(cls, hz: float, line: str) -> dict:
        """The result's display block: the helper is the main display, ticking within 15 % of the rate."""
        match = cls.READY.match(line)
        period = 1000 / hz
        ok = bool(match and match.group(1) == match.group(3) and abs(float(match.group(2)) - period) <= 0.15 * period)
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
        self.process = None


def host_env_check(display_line: str, path: str = os.path.join(HERE, "host_env.py")) -> dict:
    """host_env.py (task 006): {ok, reasons[], hz, fingerprint, class}; raises EnvInvalid unless ok."""
    if not os.path.isfile(path):
        raise EnvInvalid("scripts/perf-lab/host_env.py is missing: the host cannot be validated")
    try:
        done = subprocess.run([sys.executable, "-I", path, "--json", f"--vdisplay-line={display_line}"],
                              capture_output=True, text=True, timeout=300)
    except subprocess.TimeoutExpired:
        raise EnvInvalid("host_env.py did not finish in 300 s") from None
    try:
        report = json.loads(done.stdout)
    except ValueError:
        raise EnvInvalid(f"host_env.py printed no report (exit {done.returncode}): {done.stderr[-300:]}") from None
    if not isinstance(report, dict) or report.get("ok") is not True:
        reasons = report.get("reasons") if isinstance(report, dict) else None
        raise EnvInvalid("; ".join(reasons or ["host_env.py did not say ok"]))
    return report


def story_env(base: Dict[str, str], story: Story, app: str, out: str, sha: str, config: str, repeat: int,
              hz) -> Dict[str, str]:
    bench_env = load_by_path("bench_env", os.path.join(HERE, "bench_env.py"))
    env = {k: v for k, v in base.items() if k not in bench_env.unset_env()}
    env.update(bench_env.fixed_env())
    env.update({"CMUX_FEATURES_SAFE_MODE": "off", "CMUX_CI_SHA": sha, "PERF_LAB_APP": app, "PERF_LAB_OUT": out,
                "PERF_LAB_SHA": sha, "PERF_LAB_CONFIG": config, "PERF_LAB_STORY": story.id,
                "PERF_LAB_REPEAT": str(repeat), "PERF_LAB_SESSION": story.session, "PERF_LAB_ENGINE": story.engine,
                "PERF_LAB_HZ": "" if hz is None else str(hz)})
    return env


def render(command: Sequence[str], values: Dict[str, str]) -> List[str]:
    argv = []
    for arg in command:
        for key in PLACEHOLDERS:
            arg = arg.replace("{" + key + "}", values[key])
        argv.append(arg)
    return argv


class Runner:
    """Runs (story, repeat) pairs one at a time; `current` is the running process group, for the signal path."""

    def __init__(self, out: str, app: str, sha: str, config: str, hz, teardown: Callable[[str], None],
                 base_env: Optional[Dict[str, str]] = None):
        self.out, self.app, self.sha, self.config, self.hz = out, app, sha, config, hz
        self.results = os.path.join(out, "results")
        self.rejected = os.path.join(out, "rejected")
        self.logs = os.path.join(out, "logs")
        for folder in (self.results, self.rejected, self.logs):
            os.makedirs(folder, exist_ok=True)
        self.teardown = teardown
        self.base_env = dict(os.environ if base_env is None else base_env)
        self.current: Optional[subprocess.Popen] = None
        self.perf_result = load_by_path("perf_result", os.path.join(HERE, "perf_result.py"))

    def run(self, story: Story, repeat: int) -> dict:
        values = {"app": self.app, "out": self.results, "config": self.config, "session": story.session,
                  "engine": story.engine, "story": story.id, "repeat": str(repeat)}
        before = set(os.listdir(self.results))
        log_path = os.path.join(self.logs, f"{story.id}-{repeat}.log")
        started = time.monotonic()
        timeout = 120 + 3 * story.seconds
        with open(log_path, "wb") as log:
            self.current = subprocess.Popen(
                render(story.command, values), cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, start_new_session=True,
                env=story_env(self.base_env, story, self.app, self.results, self.sha, self.config, repeat, self.hz))
            try:
                code = self.current.wait(timeout)
                reason = None if code == 0 else f"exit {code}"
            except subprocess.TimeoutExpired:
                reason = f"timed out after {timeout:.0f} s"
            finally:
                self.stop_current()
        written, rejected = self.collect(story, sorted(set(os.listdir(self.results)) - before))
        if reason is None and not written:
            reason = "wrote no result-v1 file"
        if reason:
            self.teardown(self.app)  # a failed bench may leave its app and daemons to the next story
        return {"story": story.id, "repeat": repeat, "ok": reason is None, "reason": reason,
                "seconds": round(time.monotonic() - started, 3), "results": written, "rejected": rejected,
                "log": os.path.relpath(log_path, self.out)}

    def collect(self, story: Story, names: Sequence[str]):
        written, rejected = [], []
        for name in names:
            if name.startswith(".") or not name.endswith(".ndjson"):
                continue
            path = os.path.join(self.results, name)
            try:
                wrong = [f"{r.story}/{r.metric}: build {r.build.sha} {r.build.config}"
                         for r in self.perf_result.read_file(path)
                         if r.story != story.id or r.build.sha != self.sha or r.build.config != self.config]
                why = f"names another story or build ({'; '.join(wrong)[:300]})" if wrong else None
            except self.perf_result.ResultError as error:
                why = str(error)[:300]
            if why:
                os.replace(path, os.path.join(self.rejected, name))
                rejected.append({"file": name, "reason": why})
            else:
                written.append(name)
        return written, rejected

    def stop_current(self) -> None:
        """TERM, then KILL, the running story's whole process group."""
        process, self.current = self.current, None
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


def tag_teardown(app: str) -> None:
    subprocess.run([sys.executable, "-I", os.path.join(ROOT, "scripts/cmux-next/tag_teardown.py"), app],
                   timeout=300, check=False)


def write_json(path: str, obj) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".tmp-")
    with os.fdopen(fd, "w") as f:
        json.dump(obj, f, indent=1)
    os.replace(tmp, path)


def parse_args(argv):
    p = argparse.ArgumentParser(description="Measure a prebuilt bench app on this lab host.")
    p.add_argument("--out", required=True)
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
    p.add_argument("--vdisplay-hold", type=int, default=3600)
    p.add_argument("--vdisplay-size", default="1920x1200")
    return p.parse_args(argv)


def measure(opts, summary: dict, state: dict, store: ArtifactStore, check_env: Callable[[str], dict],
            display_factory: Callable[[str], VirtualDisplay], extract: Callable, teardown: Callable[[str], None],
            stories_dir: str = STORIES_DIR) -> int:
    def save_state():
        if opts.state:
            write_json(opts.state, state)

    stories: List[Story] = []
    if not opts.env_only:
        if not SHA.match(opts.sha):
            raise Refusal(f"--sha={opts.sha!r} is not a full commit")
        if opts.config not in CONFIGS:
            raise Refusal(f"--config={opts.config!r}: one of {', '.join(CONFIGS)}")
        if opts.repeats is not None and opts.repeats < 1:
            raise Refusal("--repeats must be >= 1")
        stories = select_stories(load_stories(stories_dir), opts.config, opts.stories, opts.shard, opts.tier)
        if not stories:
            raise Refusal("no story to run")
        summary["stories"] = [s.id for s in stories]
        work = os.path.join(opts.out, "artifact")
        shutil.rmtree(work, ignore_errors=True)
        os.makedirs(os.path.join(work, "app"))
        summary["artifact"] = {"digest": opts.digest,
                               "from": store.fetch(opts.digest, os.path.join(work, "app.zip"))}
        state["app"] = unpack_app(os.path.join(work, "app.zip"), os.path.join(work, "app"), opts.sha, opts.config,
                                  extract)
        save_state()
    display = display_factory(os.path.join(opts.out, "vdisplay"))
    try:
        summary["display"] = (display.start(opts.vdisplay, opts.vdisplay_hold, opts.vdisplay_size) if opts.vdisplay
                              else VirtualDisplay.display(60.0, "real display"))
        state["vdisplay_pid"] = display.pid
        save_state()
        summary["env"] = check_env(summary["display"]["line"])
        if opts.env_only:
            return EXIT_OK
        runner = Runner(opts.out, state["app"], opts.sha, opts.config, summary["env"].get("hz"), teardown)
        summary["runs"] = []
        try:
            for story, repeat in interleaved(stories, opts.repeats):
                summary["runs"].append(runner.run(story, repeat))
        finally:
            runner.stop_current()
        return EXIT_OK if all(run["ok"] for run in summary["runs"]) else EXIT_RUN_FAILED
    finally:
        display.stop()


def main(argv=None, store=None, check_env=host_env_check, display_factory=VirtualDisplay, extract=ditto_extract,
         teardown=tag_teardown, stories_dir=STORIES_DIR) -> int:
    opts = parse_args(argv)
    os.makedirs(opts.out, exist_ok=True)
    store = store or ArtifactStore(os.environ.get("CMUX_CI_CONTROLLER") or DEFAULT_CONTROLLER,
                                   os.path.join(os.environ["CI_SHARED_CACHE_DIR"], "perf-lab-artifacts")
                                   if os.environ.get("CI_SHARED_CACHE_DIR") else None)
    summary = {"measure_version": opts.measure_version, "sha": opts.sha, "config": opts.config, "refusal": None}
    state = {"app": None, "vdisplay_pid": None}
    code = EXIT_OK
    try:
        code = measure(opts, summary, state, store, check_env, display_factory, extract, teardown, stories_dir)
    except Refusal as refusal:
        code = refusal.code
        summary["refusal"] = {"kind": refusal.kind, "reason": str(refusal)}
        print(f"perf-lab: {refusal.kind}: {refusal}", file=sys.stderr)
    finally:
        write_json(os.path.join(opts.out, "env.json" if opts.env_only else "summary.json"), summary)
    for run in summary.get("runs", []):
        print(f"perf-lab: {run['story']}#{run['repeat']} {'ok' if run['ok'] else 'FAILED: ' + run['reason']} "
              f"({len(run['results'])} result files, {run['seconds']} s)")
    return code


def stop_on_signal(signum, _frame):
    raise SystemExit(128 + signum)  # unwinds main's finally blocks: the story's process group, the display, summary


if __name__ == "__main__":
    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(sig, stop_on_signal)
    sys.exit(main())
