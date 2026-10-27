#!/usr/bin/env python3
"""Story shipped-nightly: the newest published cmux NEXT nightly, measured as people run it.

Every other lab story measures a `bench` build of a lab commit. This one measures the bytes people download: the
newest `nightly-next` DMG of the GitHub release (nightly.yml publishes it as `cmux-nightly-next-macos-arm64.dmg`).
Chrome's perf waterfall does the same with its reference build, the shipped binary measured beside the tip
(tools/perf/core/bot_platforms.py `run_reference_build`, telemetry `--browser=reference`), so a regression that only
the Release toolchain, signing or packaging makes still shows.

Steps, each refusing with exit 4 and one reason line before anything of the DMG runs:
1. download the DMG (or take `--dmg PATH`) into a scratch folder and hash it;
2. verify it as the publish job does: scripts/ci/verify-dmg-artifact.sh with channel `next` and the app's own ticket
   (stapler on the DMG and the app, Gatekeeper `spctl --type execute`, the cmux NEXT name, bundle id and icon, the
   bundled licenses); its digest receipt must name the downloaded bytes;
3. copy the app out of the read-only mount, check that the DMG still has the verified digest, then `codesign --verify
   --deep --strict` and `spctl --assess --type execute` on the copy, its bundle id, its CMUXCommit stamp and that it
   is a Release bundle (no bench-hooks marker, no debug dylib: bench_launch.build_config).

Then the legs, each from always-on signals only. The app gets no `debug.*` request: ``NightlyApp.rpc`` refuses one
before it reaches the socket. It speaks system.ping, features.list, action.run, snapshot.get and app.quit.
  launch    `--runs` pairs, interleaved: cold (every daemon of the bundle stopped, the cmux NEXT state moved aside,
            `sudo -n /usr/sbin/purge`) then warm (right after the cold run quit, its daemon still running, as
            bench-startup.py's warm mode). Each mark is the `launch.mark` signpost's own `ms=` (time since process
            start, CmuxNextSignposts LaunchSignposts.mark), streamed with `log stream --signpost`. A run whose stream
            lost messages, that did not start or that missed a mark counts in `missing_runs`. Without the purge right
            the cold runs do not run and the story exits 1 (decision D3, as launch-cold).
  session   one fresh launch with bench_idle.py's tabs-10 session (10 static `--engine` pages over 3 workspaces, the
            last one shown, hidden ones frozen), settled; then a `--idle` second window read only at its ends
            (proc_pid_rusage: interrupt wakeups/s and CPU of the app, the daemon and the engine's helpers, Chrome's
            GetIdleWakeupsPerSecond) and the footprint at its end; then `--rounds` of newTab, closeTab, splitRight,
            closeTab through action.run with the action signposts streamed (perf-signposts.py Recording): the
            action.perform and action.commit samples of every run. The pages must be real pages of the engine (each
            page reports its navigator.vendor and visibility to the bench's own page server).

Results: one cmux-perf-result/v1 file per metric in --out, config `release` (the bundle's own kind), sha the DMG's
CMUXCommit (never the lab's tip), the features the app reported in features.list; summary in
shipped-nightly-summary.json. Metric names start with `release.` (stories.d/shipped-nightly.json).

The story runner (run_story.py) appends --app, --tag and --out; the runner's app is a bench build of the lab commit,
which this story does not launch. The runner does not run `release` stories yet (stories.d `not_measurable`); run it
by hand on a lab host:
  python3 -I scripts/perf-lab/stories/shipped_nightly.py --out DIR [--dmg PATH | --dmg-url URL] [--runs 5]
      [--legs launch,session] [--engine chromium] [--idle 60] [--rounds 20] [--purge]
Exit: 0 every leg recorded; 1 a leg recorded nothing or only part; 2 usage; 4 refused before any launch.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
import pwd
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request
from typing import Callable, Dict, List, Optional, Sequence

HERE = os.path.dirname(os.path.abspath(__file__))
PERF_LAB = os.path.dirname(HERE)
ROOT = os.path.dirname(os.path.dirname(PERF_LAB))
CMUX_NEXT = os.path.join(ROOT, "scripts", "cmux-next")
if CMUX_NEXT not in sys.path:
    sys.path.insert(0, CMUX_NEXT)  # bench_launch, bench_idle and their siblings under `python3 -I`

STORY = "shipped-nightly"
CONFIG = "release"
PREFIX = "release."
# nightly.yml's `nightly-next` identity: release tag, DMG prefix (dmgPrefix) and arm64 only; the stable asset name
# is replaced by every publish, so it is always the newest.
DMG_URL = "https://github.com/manaflow-ai/cmux/releases/download/nightly-next/cmux-nightly-next-macos-arm64.dmg"
SIGN_CHANNEL = "next"  # verify-app-bundle-channel-metadata.sh's cmux NEXT row
NEXT_BUNDLE_ID = "com.cmuxterm.app.nightly.cmux-next"
NEXT_APP_DIR = "cmux NEXT.app"
VERIFY_DMG = os.path.join(ROOT, "scripts", "ci", "verify-dmg-artifact.sh")
# cmux NEXT's state under ~/Library/Application Support/cmux: its daemon's kept session tag `cmux-next`
# (BuildIdentity+AppNames.swift KeptNames, daemonStateDirectory) and its per-build roots (BuildIdentity.appSupport).
STATE_ROOTS = ("tags/cmux-next", f"builds/{NEXT_BUNDLE_ID}")
PREV_SUFFIX = ".shipped-nightly-prev"
SUBSYSTEM = "com.cmuxterm.app.next"
LAUNCH_PREDICATE = f'subsystem == "{SUBSYSTEM}" AND category == "launch"'
LAUNCH_MARKS = ("main_start", "did_finish_launching_end", "first_window_frame_committed")
FINAL_MARK = "first_window_frame_committed"
MODES = ("cold", "warm")
ACTIONS = ("newTab", "closeTab", "splitRight", "closeTab")  # bench-config-parity.py's net-zero round
ACTION_SERIES = ("action.perform", "action.commit")
ACTION_SPACING_S = 0.05  # between presses, as a person types (bench-config-parity.py)
LAUNCH_TIMEOUT_S = 120
QUIT_TIMEOUT_S = 30
ATTACH_TIMEOUT_S = 15
SUMMARY = "shipped-nightly-summary.json"
FORBIDDEN_PREFIX = "debug."

EXIT_OK, EXIT_FAILED, EXIT_USAGE, EXIT_REFUSED = 0, 1, 2, 4


class Refused(Exception):
    """The DMG cannot be measured: nothing of it was launched."""


class LegError(Exception):
    """A leg ran but has nothing it can record."""


def load_by_path(name: str, path: str):
    """The module at `path` as `name`, once per process (python3 -I puts no script folder on sys.path)."""
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module  # before exec: dataclasses resolve their module through sys.modules
    spec.loader.exec_module(module)
    return module


bench_launch = load_by_path("bench_launch", os.path.join(CMUX_NEXT, "bench_launch.py"))
bench_env = load_by_path("bench_env", os.path.join(PERF_LAB, "bench_env.py"))
perf_result = load_by_path("perf_result", os.path.join(PERF_LAB, "perf_result.py"))


def bench_idle():
    return load_by_path("bench_idle", os.path.join(CMUX_NEXT, "bench_idle.py"))


def signposts():
    return load_by_path("perf_signposts", os.path.join(CMUX_NEXT, "perf-signposts.py"))


# ---------------------------------------------------------------- the DMG: fetch, verify, install


def sha256_of(path: str) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def fetch(url: str, folder: str, opener: Callable = urllib.request.urlopen) -> str:
    """Downloads `url` into `folder`; returns the file. Raises Refused on any transport error."""
    path = os.path.join(folder, os.path.basename(url.split("?", 1)[0]) or "nightly.dmg")
    try:
        with opener(url, timeout=120) as reply, open(path, "wb") as f:
            shutil.copyfileobj(reply, f, 1 << 20)
    except OSError as error:  # urllib.error.URLError and HTTPError are OSErrors
        raise Refused(f"cannot download {url}: {error}") from None
    return path


def verify_dmg(dmg: str, digest: str, run: Callable = subprocess.run) -> str:
    """verify-dmg-artifact.sh on `dmg` (channel next, the app's own ticket required); returns its receipt line. Its
    receipt (`verified <sha256> <name>`, on stdout when fd 3 is closed) must name `digest`."""
    done = run(["/bin/bash", VERIFY_DMG, dmg, SIGN_CHANNEL, "--require-stapled-app"], capture_output=True, text=True,
               timeout=900)
    if done.returncode != 0:
        raise Refused(f"verify-dmg-artifact.sh refused {os.path.basename(dmg)} (exit {done.returncode}): "
                      f"{(done.stderr or '').strip()[-400:]}")
    receipt = next((line for line in (done.stdout or "").splitlines() if line.startswith("verified ")), "")
    words = receipt.split()
    if len(words) < 2 or words[1] != digest:
        raise Refused(f"verify-dmg-artifact.sh verified {words[1] if len(words) > 1 else 'nothing'}, "
                      f"but the downloaded DMG is {digest}")
    return receipt


def copy_app(dmg: str, dest: str, digest: str, run: Callable = subprocess.run) -> str:
    """Copies the DMG's app into `dest` from a read-only mount and checks that the DMG still has the verified
    `digest` afterwards (the bytes copied are the bytes verified). Returns the copy."""
    mount = tempfile.mkdtemp(prefix="shipped-nightly-mount-")
    app = os.path.join(dest, NEXT_APP_DIR)
    try:
        attach = run(["/usr/bin/hdiutil", "attach", dmg, "-nobrowse", "-readonly", "-mountpoint", mount],
                     capture_output=True, text=True, timeout=300)
        if attach.returncode != 0:
            raise Refused(f"hdiutil attach failed: {(attach.stderr or '').strip()[-300:]}")
        try:
            source = os.path.join(mount, NEXT_APP_DIR)
            if not os.path.isdir(source):
                raise Refused(f"the DMG has no {NEXT_APP_DIR}: {sorted(os.listdir(mount))[:8]}")
            copied = run(["/usr/bin/ditto", source, app], capture_output=True, text=True, timeout=600)
            if copied.returncode != 0:
                raise Refused(f"ditto failed: {(copied.stderr or '').strip()[-300:]}")
        finally:
            run(["/usr/bin/hdiutil", "detach", mount, "-force"], capture_output=True, text=True, timeout=120)
    finally:
        try:
            os.rmdir(mount)
        except OSError:
            pass  # still mounted after a failed detach: hdiutil owns it, never removed by hand
    if sha256_of(dmg) != digest:
        raise Refused(f"{os.path.basename(dmg)} changed while it was mounted")
    return app


def executable(app: str) -> str:
    """The bundle's main executable (Info.plist CFBundleExecutable): Contents/MacOS also holds helper tools."""
    name = bench_launch.info_plist(app).get("CFBundleExecutable")
    if not isinstance(name, str) or not name or "/" in name:
        raise Refused(f"{app} names no CFBundleExecutable")
    return os.path.join(os.path.realpath(app), "Contents", "MacOS", name)


def check_app(app: str, run: Callable = subprocess.run) -> Dict[str, str]:
    """The copy's own checks before its first launch: its code signature (every nested binary), Gatekeeper, its bundle
    id, that it is a Release bundle and the commit it names. Returns {bundle_id, sha, config}."""
    for argv in (["/usr/bin/codesign", "--verify", "--deep", "--strict", "--verbose=2", app],
                 ["/usr/sbin/spctl", "--assess", "-vv", "--type", "execute", app]):
        done = run(argv, capture_output=True, text=True, timeout=600)
        if done.returncode != 0:
            raise Refused(f"{os.path.basename(argv[0])} refused the installed copy: "
                          f"{((done.stderr or '') + (done.stdout or '')).strip()[-300:]}")
    bundle = bench_launch.info_plist(app).get("CFBundleIdentifier")
    if bundle != NEXT_BUNDLE_ID:
        raise Refused(f"the app is {bundle!r}, not cmux NEXT ({NEXT_BUNDLE_ID})")
    try:
        config = bench_launch.build_config(app, executable(app), CONFIG)
        sha = bench_launch.build_sha(app, environ={})  # the bundle's CMUXCommit only, never a fleet variable
    except (bench_launch.RecordError, OSError, SystemExit) as error:
        raise Refused(f"not a Release bundle with a commit stamp: {error}") from None
    return {"bundle_id": bundle, "sha": sha, "config": config}


# ---------------------------------------------------------------- the app, with no debug.* method


def fresh_state(app_support: str, roots: Sequence[str] = STATE_ROOTS) -> List[str]:
    """Moves cmux NEXT's state aside (one earlier copy kept at `<root>.shipped-nightly-prev`), so a launch starts
    from an empty saved session, as BenchApp.start_fresh does for a tag. Only while no process of it runs."""
    moved = []
    for relative in roots:
        root = os.path.join(app_support, relative)
        if not os.path.lexists(root):
            continue
        prev = root + PREV_SUFFIX
        if os.path.lexists(prev):
            shutil.rmtree(prev, ignore_errors=True)
        os.rename(root, prev)
        moved.append(root)
    return moved


def other_next_processes(app: str, table: Optional[str] = None) -> List[int]:
    """PIDs of every cmux NEXT process from another bundle path: they share this build's daemon session and state."""
    if table is None:
        table = subprocess.run(["/bin/ps", "-axo", "pid=,command="], capture_output=True, text=True).stdout
    own = os.path.realpath(app).rstrip("/") + "/"
    pids = []
    for line in table.splitlines():
        pid, _, command = line.strip().partition(" ")
        command = command.strip()
        if f"/{NEXT_APP_DIR}/Contents/" in command and not command.startswith(own) and pid.isdigit():
            pids.append(int(pid))
    return pids


class NightlyApp:
    """The installed cmux NEXT copy, launched with the lab's bench environment (bench_env.py: no activation, the
    updater off, a scratch cmux-next.json and Ghostty config, telemetry env unset) on a socket of its own
    (CMUX_NEXT_SOCKET_PATH, which every build honors: LaunchIdentity.socketOverrideKey). `rpc` refuses any debug.*
    method: a Release build has none, and this story measures what people run."""

    def __init__(self, app: str, out: str, config: Optional[dict] = None, teardown=None,
                 rpc_at: Callable = bench_launch.rpc_at, popen: Callable = subprocess.Popen):
        self.app = os.path.realpath(app).rstrip("/")
        self.out = out
        self.scratch = tempfile.mkdtemp(prefix="shipped-nightly-")
        self.socket = f"/tmp/cmux-shipped-nightly-{os.getpid()}.sock"
        self.config = config or {}
        self.process = None
        self.features = None
        self.launches = 0
        self._rpc_at, self._popen = rpc_at, popen
        if teardown is None:
            from tag_teardown import TagTeardown
            teardown = TagTeardown(self.app)
        self.teardown = teardown

    @property
    def binary(self) -> str:
        return executable(self.app)

    def environment(self) -> Dict[str, str]:
        config_path = os.path.join(self.scratch, "cmux-next.json")
        with open(config_path, "w") as f:
            json.dump(bench_env.with_config_defaults(dict(bench_launch.DEFAULT_CONFIG, **self.config)), f)
        ghostty = os.path.join(self.scratch, "ghostty")
        open(ghostty, "a").close()
        env = {"HOME": os.environ.get("HOME", bench_launch.account_home()), "USER": pwd.getpwuid(os.getuid()).pw_name,
               "TMPDIR": os.environ.get("TMPDIR", "/tmp"), **bench_launch.BASE_ENV,
               "CMUX_NEXT_CONFIG_FILE": config_path, "CMUX_NEXT_GHOSTTY_CONFIG": ghostty,
               "CMUX_NEXT_CHIEF_HOME": os.path.join(self.scratch, "chief"), "CMUX_NEXT_SOCKET_PATH": self.socket,
               "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1440,900", "CMUX_NEXT_TEST_WINDOW_SCREEN": "0"}
        for name in bench_launch.DROPPED_ENV + bench_env.unset_env():
            env.pop(name, None)
        return env

    def rpc(self, method: str, params: Optional[dict] = None, timeout: float = 60):
        if method.startswith(FORBIDDEN_PREFIX):
            raise ValueError(f"shipped-nightly sends no {FORBIDDEN_PREFIX}* request ({method})")
        return self._rpc_at(self.socket, method, params, timeout)

    def call(self, method: str, params: Optional[dict] = None, timeout: float = 60) -> dict:
        """`rpc` in the reply shape bench_idle's helpers read ({"result": ...} or {"error": ...})."""
        reply = self.rpc(method, params, timeout)
        if isinstance(reply, dict) and "error" in reply:
            return {"error": reply["error"]}
        return {"result": reply}

    def launch(self, timeout: float = LAUNCH_TIMEOUT_S) -> int:
        """Starts the app; returns its pid once system.ping answers, with its features.list snapshot read."""
        others = other_next_processes(self.app)
        if others:
            raise LegError(f"another cmux NEXT runs (pid {', '.join(map(str, others))}): it shares the daemon session")
        if os.path.lexists(self.socket):
            if bench_launch.socket_in_use(self.socket):
                raise LegError(f"{self.socket} is in use")
            os.unlink(self.socket)  # a socket an earlier run of this story left; nothing listens
        log = open(os.path.join(self.out, f"app-{self.launches}.log"), "a")
        self.launches += 1
        self.features = None
        self.process = self._popen([self.binary], env=self.environment(), stdout=log, stderr=log,
                                   stdin=subprocess.DEVNULL)
        log.close()  # the child holds its own descriptor
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline and self.process.poll() is None:  # bounded poll of the app it started
            reply = self.rpc("system.ping", timeout=min(10, max(0.1, deadline - time.monotonic())))
            if not (isinstance(reply, dict) and reply.get("error")):
                self.features = bench_launch.features_snapshot(self.rpc("features.list", timeout=10))
                self.teardown.remember()
                return self.process.pid
            time.sleep(0.25)  # the poll interval
        code = self.process.poll()
        self.quit()
        raise LegError(f"the app did not answer system.ping in {timeout:g} s" if code is None
                       else f"the app exited with {code} before it answered")

    def quit(self) -> None:
        """app.quit (the daemon keeps running: keep-on-quit), then TERM of its own pid if it did not exit."""
        if self.process is None:
            return
        if self.process.poll() is None:
            self.rpc("app.quit", {}, timeout=10)
            try:
                self.process.wait(QUIT_TIMEOUT_S)
            except subprocess.TimeoutExpired:
                self.process.terminate()  # its own pid, never a pattern
                try:
                    self.process.wait(10)
                except subprocess.TimeoutExpired:
                    self.process.kill()
                    self.process.wait()
        self.process = None

    def end(self) -> None:
        """The app quit and every process of the bundle ended (its daemons, hosts and holders; tag_teardown.py)."""
        self.quit()
        self.teardown.end()

    def close(self) -> None:
        self.end()
        shutil.rmtree(self.scratch, ignore_errors=True)


# ---------------------------------------------------------------- launch leg


def launch_event(line: str):
    """(pid, mark, ms) of a `launch.mark` signpost line (LaunchSignposts.mark: `<name> ms=<ms>`), "lost" for a loss
    event, else None."""
    if not line.startswith("{"):
        return None
    try:
        event = json.loads(line)
    except ValueError:
        return None
    if event.get("eventType") == "lossEvent":
        return "lost"
    if (event.get("eventType") != "signpostEvent" or event.get("subsystem") != SUBSYSTEM
            or event.get("signpostName") != "launch.mark"):
        return None
    words = (event.get("eventMessage") or "").split()
    fields = dict(word.split("=", 1) for word in words[1:] if "=" in word)
    try:
        return event.get("processID"), words[0], float(fields["ms"])
    except (IndexError, KeyError, ValueError):
        return None


class LaunchStream:
    """`log stream` of the launch signposts of every process, started before the spawn (the pid is not known yet)
    and drained on a reader thread (a full pipe would block `log stream` and logd would drop events)."""

    def __init__(self, popen: Callable = subprocess.Popen, attach_timeout: float = ATTACH_TIMEOUT_S):
        self.marks: Dict[int, Dict[str, float]] = {}
        self.lost = 0
        self._changed = threading.Condition()
        self._attached = threading.Event()
        self._log = popen(["/usr/bin/log", "stream", "--signpost", "--style", "ndjson", "--predicate", LAUNCH_PREDICATE],
                          stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, bufsize=1)
        self._reader = threading.Thread(target=self._drain, name="launch-stream-drain", daemon=True)
        self._reader.start()
        # The log tool prints its filter line once it is attached; a spawn before it loses the first marks.
        if not self._attached.wait(attach_timeout):
            raise LegError(f"log stream printed nothing in {attach_timeout:g} s")

    def _drain(self) -> None:
        for line in self._log.stdout:
            self._attached.set()
            event = launch_event(line.strip())
            if event is None:
                continue
            with self._changed:
                if event == "lost":
                    self.lost += 1
                else:
                    pid, mark, ms = event
                    self.marks.setdefault(pid, {}).setdefault(mark, ms)
                self._changed.notify_all()
        self._attached.set()

    def wait_mark(self, pid: int, mark: str, timeout: float) -> bool:
        with self._changed:
            return self._changed.wait_for(lambda: mark in self.marks.get(pid, {}), timeout)

    def stop(self) -> None:
        if self._log.poll() is None:
            self._log.send_signal(signal.SIGINT)  # our own log stream child: it flushes and exits
        try:
            self._log.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self._log.kill()
            self._log.wait()
        self._reader.join(timeout=10)


def purge(run: Callable = subprocess.run) -> Optional[str]:
    """Empties the file cache (`sudo -n /usr/sbin/purge`, decision D3); None, or why it could not."""
    done = run(["/usr/bin/sudo", "-n", "/usr/sbin/purge"], capture_output=True, text=True, timeout=300)
    return None if done.returncode == 0 else f"sudo -n purge: exit {done.returncode}: {(done.stderr or '').strip()[:200]}"


def launch_run(app: NightlyApp, mode: str, stream_factory: Callable = LaunchStream) -> dict:
    """One launch timed by its own launch marks; the app quits after its last mark (its daemon keeps running)."""
    run = {"mode": mode, "marks": {}, "lost": 0, "error": None}
    stream = stream_factory()
    try:
        pid = app.launch()
        run["pid"] = pid
        if not stream.wait_mark(pid, FINAL_MARK, LAUNCH_TIMEOUT_S):
            run["error"] = f"no {FINAL_MARK} mark in {LAUNCH_TIMEOUT_S} s"
        run["marks"] = dict(stream.marks.get(pid, {}))
    except LegError as error:
        run["error"] = str(error)
    finally:
        stream.stop()
        run["lost"] = stream.lost
        app.quit()
    return run


def launch_leg(app: NightlyApp, runs: int, do_purge: bool, app_support: str,
               purger: Callable = purge, stream_factory: Callable = LaunchStream) -> dict:
    """`runs` pairs of a cold and a warm launch. A cold launch needs the purge: without it no cold run runs."""
    out = {"runs": [], "problems": []}
    for _ in range(runs):
        app.end()  # a cold launch starts with no daemon of the bundle
        fresh_state(app_support)
        refusal = purger() if do_purge else "--purge not given: a launch with the file cache warm is not cold"
        if refusal:
            out["problems"].append(f"cold: {refusal}")
        else:
            out["runs"].append(launch_run(app, "cold", stream_factory))
        out["runs"].append(launch_run(app, "warm", stream_factory))
    app.end()
    return out


def launch_metrics(runs: Sequence[dict]) -> Dict[str, List[float]]:
    """{metric: samples}: each mark's ms per mode over the complete runs (no loss, no error, every mark), and each
    mode's `missing_runs` (the runs that are not complete)."""
    metrics: Dict[str, List[float]] = {}
    for mode in MODES:
        mine = [r for r in runs if r["mode"] == mode]
        if not mine:
            continue
        complete = [r for r in mine if not r["error"] and not r["lost"] and all(m in r["marks"] for m in LAUNCH_MARKS)]
        for mark in LAUNCH_MARKS:
            if complete:
                metrics[f"{PREFIX}launch.{mode}.{mark}"] = [r["marks"][mark] for r in complete]
        metrics[f"{PREFIX}launch.{mode}.missing_runs"] = [float(len(mine) - len(complete))]
    return metrics


# ---------------------------------------------------------------- session leg: idle, memory, actions


def page_problems(engine: str, kinds: Dict[int, str], pages, keys: Sequence[str]) -> List[str]:
    """Why the pages may not be real `engine` pages, from what the pages and the process table say (no debug.cef):
    a page that never loaded or names another engine's navigator.vendor, a shown page other than the last one, and
    for Chromium no renderer process."""
    idle = bench_idle()
    problems = [f"page {key} never loaded" for key in keys if key not in pages.loaded]
    wrong = [f"{key}={pages.vendors.get(key)!r}" for key in keys if pages.vendors.get(key) != idle.ENGINE_VENDORS[engine]]
    if wrong:
        problems.append(f"pages not drawn by {engine} (navigator.vendor): {', '.join(wrong)[:200]}")
    if engine == "chromium" and "cef-renderer" not in set(kinds.values()):
        problems.append("no Chromium renderer process")
    return problems + idle.shown_problems(pages.visibility, keys)


def idle_metrics(rows: Sequence[dict], end: Dict[int, object]) -> Dict[str, float]:
    """{metric: value} of a window's process rows (bench_idle.window_rows) and the footprints at its end. A judged
    kind with a partial row (it came or went in the window) has no value; helpers sum their complete rows."""
    idle = bench_idle()
    metrics: Dict[str, float] = {}

    def total(kind_matches, field, complete_only=False):
        picked = [r for r in rows if kind_matches(r["kind"])]
        if complete_only:
            picked = [r for r in picked if not r.get("partial")]
        if not picked or any(r.get("partial") for r in picked):
            return None
        return round(sum(r[field] for r in picked), 3)

    kinds = {"app": lambda k: k == "app", "daemon": lambda k: k == "daemon", "helper": idle.is_helper}
    for name, matches in kinds.items():
        for field, metric in (("wakeups_per_s", "wakeups_per_s"), ("cpu_percent", "cpu_percent")):
            value = total(matches, field, complete_only=name == "helper")
            if value is not None:
                metrics[f"{PREFIX}idle.tabs-10.{name}_{metric}"] = value
    by_pid = {r["pid"]: r["kind"] for r in rows}
    footprints = {pid: getattr(usage, "footprint", None) for pid, usage in end.items() if usage is not None}
    app = [size for pid, size in footprints.items() if by_pid.get(pid) == "app" and size]
    if app:
        metrics[f"{PREFIX}memory.tabs-10.app_footprint"] = float(sum(app))
    if footprints:
        metrics[f"{PREFIX}memory.tabs-10.total_footprint"] = float(sum(s for s in footprints.values() if s))
    return metrics


def idle_window(app: NightlyApp, pid: int, seconds: float, engine: str, pages, keys: Sequence[str]) -> dict:
    """One window read only at its ends: no socket request inside it."""
    idle = bench_idle()
    kinds = idle.tab_kinds(pid, app.app)
    start = {p: idle.procs.usage(p) for p in kinds}
    t0 = time.monotonic()
    time.sleep(seconds)  # the measurement window itself, not a wait for a condition
    end = {p: idle.procs.usage(p) for p in kinds}
    wall = time.monotonic() - t0
    for p, kind in idle.tab_kinds(pid, app.app).items():
        kinds.setdefault(p, kind)  # started inside the window: a partial row
    rows = idle.window_rows(kinds, start, end, wall)
    return {"wall_s": round(wall, 1), "processes": rows, "metrics": idle_metrics(rows, end),
            "problems": page_problems(engine, kinds, pages, keys), "notes": idle.helper_notes(rows)}


def action_rounds(app: NightlyApp, pid: int, rounds: int, recording_factory: Optional[Callable] = None) -> dict:
    """`rounds` of ACTIONS through action.run with the action signposts streamed; their perform and commit samples."""
    sp = signposts()
    recording = (recording_factory or sp.Recording)(pid, ["action"])
    errors = []
    try:
        for _ in range(rounds):
            for action in ACTIONS:
                reply = app.rpc("action.run", {"action": action})
                if isinstance(reply, dict) and reply.get("error"):
                    errors.append({"action": action, "error": reply["error"]})
                time.sleep(ACTION_SPACING_S)  # spacing between presses, not a wait for a condition
    finally:
        lines = recording.stop()
    parsed = sp.parse(lines, None)  # the header line carries the timebase
    series = sp.series(parsed["intervals"])
    return {"lost": parsed["lost"], "errors": errors[:20], "error_count": len(errors),
            "metrics": {f"{PREFIX}{name}": series[name] for name in ACTION_SERIES if series.get(name)}}


def session_leg(app: NightlyApp, engine: str, seconds: float, rounds: int, app_support: str, out_dir: str,
                pages_factory: Optional[Callable] = None) -> dict:
    """One fresh launch: the tabs-10 session, its idle window, then the action rounds."""
    idle = bench_idle()
    result = {"problems": []}
    pages = (pages_factory or idle.TabPages)()
    try:
        app.end()
        fresh_state(app_support)
        app.config = idle.tabs10_config(engine, {})
        pid = app.launch()
        result["pid"] = pid
        lab_check(app, pid, out_dir)
        skip = idle.build_tabs10(app, pages, engine)
        if skip:
            raise LegError(f"tabs-10 session: {skip}")
        time.sleep(idle.TABS10_SETTLE_MIN_S)  # past the hidden tabs' freeze (bench_idle.TABS10_FREEZE_S)
        keys = [key for _workspace, key in idle.tabs10_plan()]
        result["idle"] = idle_window(app, pid, seconds, engine, pages, keys)
        result["problems"] += result["idle"]["problems"]
        result["actions"] = action_rounds(app, pid, rounds)
        if result["actions"]["lost"]:
            result["problems"].append(f"actions: log stream lost messages {result['actions']['lost']} time(s)")
        if result["actions"]["error_count"]:
            result["problems"].append(f"actions: {result['actions']['error_count']} action.run error(s)")
    except LegError as error:
        result["problems"].append(str(error))
    finally:
        pages.close()
        app.end()
    return result


def lab_check(app: NightlyApp, pid: int, out_dir: str) -> None:
    """Under the lab runner (PERF_LAB_VDISPLAY_OUT), host_env's full validation of the launched app and its daemons,
    written where run_story.py looks for it (bench_launch.LAB_CHECK_PREFIX)."""
    vdisplay_out = os.environ.get(bench_launch.LAB_VDISPLAY_OUT)
    if not vdisplay_out:
        return
    pids = sorted({pid, *(p for p, _ in app.teardown.processes())})
    report = bench_launch.lab_host_check(vdisplay_out, pids)
    with open(os.path.join(out_dir, f"{bench_launch.LAB_CHECK_PREFIX}{pids[0]}.json"), "w") as f:
        json.dump(report, f, sort_keys=True)


# ---------------------------------------------------------------- results


class Recorder:
    """Writes result-v1 files for one installed nightly: its own commit and config, this host, one run."""

    def __init__(self, out: str, build, host_read: Callable, session: str):
        self.out, self.build, self.session = out, build, session
        self.host = perf_result.Host.from_dict(host_read())
        self.run = perf_result.Run.start()

    def record(self, metric: str, unit: str, samples: Sequence[float], engine: str, features) -> str:
        if features is None:
            raise LegError(f"{metric}: the app gave no features.list snapshot")
        named, features_hash, safe_mode = features
        result = perf_result.Result(
            story=STORY, metric=metric, unit=unit, better="lower", samples=list(samples), build=self.build,
            host=self.host, engine=engine, session=self.session, run=self.run,
            features={name: perf_result.Feature(**value) for name, value in named.items()},
            features_hash=features_hash, safe_mode=safe_mode)
        return str(perf_result.write_ndjson(self.out, [result], repo_root=ROOT))


def unit_of(metric: str) -> str:
    if metric.endswith("missing_runs"):
        return "count"
    if metric.endswith("wakeups_per_s"):
        return "per_s"
    if metric.endswith("cpu_percent"):
        return "percent"
    if metric.endswith("footprint"):
        return "bytes"
    return "ms"


def record_all(recorder: Recorder, metrics: Dict[str, Sequence[float]], engine: str, features) -> List[str]:
    """Writes each metric; returns the problems (a result that could not be written)."""
    problems = []
    for metric, samples in sorted(metrics.items()):
        try:
            recorder.record(metric, unit_of(metric), samples, engine, features)
        except (LegError, perf_result.ResultError, OSError) as error:
            problems.append(f"{metric}: not recorded: {error}")
    return problems


# ---------------------------------------------------------------- main


def parse_args(argv: Optional[Sequence[str]] = None):
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--app", help="the story runner's bench build: not what this story measures, never launched")
    p.add_argument("--tag", help="the story runner's tag of --app (unused)")
    p.add_argument("--out", required=True, help="result-v1 files and the summary")
    source = p.add_mutually_exclusive_group()
    source.add_argument("--dmg", help="a downloaded nightly-next DMG instead of the release's newest")
    source.add_argument("--dmg-url", default=DMG_URL)
    p.add_argument("--legs", default="launch,session")
    p.add_argument("--runs", type=int, default=5, help="cold and warm launch pairs")
    p.add_argument("--purge", action="store_true", help="sudo -n purge before each cold launch (decision D3)")
    p.add_argument("--engine", choices=("chromium", "webkit"), default="chromium")
    p.add_argument("--idle", type=float, default=60, help="seconds of the idle window")
    p.add_argument("--rounds", type=int, default=20, help="action rounds of newTab, closeTab, splitRight, closeTab")
    p.add_argument("--work", help="scratch folder for the DMG and the installed copy (default: a new temp folder)")
    opts = p.parse_args(argv)
    legs = [leg for leg in opts.legs.split(",") if leg]
    if not legs or any(leg not in ("launch", "session") for leg in legs):
        p.error(f"--legs={opts.legs!r}: launch, session or both")
    if opts.runs < 1 or opts.rounds < 1 or opts.idle <= 0:
        p.error("--runs and --rounds are >= 1 and --idle > 0")
    opts.legs = legs
    return opts


def prepare(opts, work: str, run: Callable = subprocess.run, opener: Callable = urllib.request.urlopen) -> dict:
    """The verified, installed nightly: {dmg, dmg_sha256, receipt, app, bundle_id, sha, config}. Raises Refused."""
    dmg = os.path.abspath(opts.dmg) if opts.dmg else fetch(opts.dmg_url, work, opener)
    if not os.path.isfile(dmg):
        raise Refused(f"no DMG at {dmg}")
    digest = sha256_of(dmg)
    receipt = verify_dmg(dmg, digest, run)
    app = copy_app(dmg, work, digest, run)
    return {"dmg": dmg, "dmg_sha256": digest, "receipt": receipt, "app": app, **check_app(app, run)}


def host_problem() -> None:
    """Refuses a host whose app would get no working GUI session, or whose numbers are not comparable."""
    if sys.platform != "darwin":
        raise Refused("not a Mac: the nightly runs on a lab Mac only")
    session = bench_launch.gui_session()
    if not session["ok"]:
        raise Refused(bench_launch.no_session_detail(session))
    if bench_launch.low_power_mode():
        raise Refused("this Mac is in Low Power Mode: its numbers are not comparable")


def main(argv: Optional[Sequence[str]] = None) -> int:
    opts = parse_args(argv)
    out = os.path.abspath(opts.out)
    os.makedirs(out, exist_ok=True)
    work = opts.work or tempfile.mkdtemp(prefix="shipped-nightly-work-")
    os.makedirs(work, exist_ok=True)
    summary: dict = {"story": STORY, "dmg_url": None if opts.dmg else opts.dmg_url, "runner_app": opts.app,
                     "legs": {}, "problems": []}
    code = EXIT_OK
    app = None
    try:
        try:
            host_problem()
            installed = prepare(opts, work)
        except Refused as error:
            summary["refused"] = str(error)
            print(f"shipped-nightly: refused: {error}", file=sys.stderr, flush=True)
            return EXIT_REFUSED
        summary["nightly"] = {k: v for k, v in installed.items() if k != "app"}
        build = perf_result.Build(sha=installed["sha"], config=installed["config"],
                                  measure_version=bench_launch.PERF_LAB_MEASURE_VERSION)
        host_file = os.environ.get(bench_launch.LAB_HOST_FILE)
        host_read = (load_by_path("perf_lab_host_env", os.path.join(PERF_LAB, "host_env.py")).host_reader(host_file)
                     if host_file else bench_launch.read_host)
        recorder = Recorder(out, build, host_read, os.environ.get(bench_launch.LAB_SESSION) or "light")
        app_support = os.path.join(bench_launch.account_home(), "Library", "Application Support", "cmux")
        app = NightlyApp(installed["app"], out)
        app.teardown.install()  # SIGTERM and SIGHUP raise SystemExit, so the finally below ends the bundle
        if "launch" in opts.legs:
            leg = launch_leg(app, opts.runs, opts.purge, app_support)
            leg["problems"] += record_all(recorder, launch_metrics(leg["runs"]), "none", app.features)
            if any(r["error"] or r["lost"] for r in leg["runs"]):
                leg["problems"].append("a launch run is incomplete (see runs)")
            summary["legs"]["launch"] = leg
        if "session" in opts.legs:
            leg = session_leg(app, opts.engine, opts.idle, opts.rounds, app_support, out)
            if not leg["problems"]:
                metrics = {name: [value] for name, value in leg["idle"]["metrics"].items()}
                metrics.update(leg["actions"]["metrics"])
                leg["problems"] += record_all(recorder, metrics, opts.engine, app.features)
            summary["legs"]["session"] = leg
        summary["problems"] = [f"{name}: {p}" for name, leg in summary["legs"].items() for p in leg["problems"]]
        code = EXIT_FAILED if summary["problems"] else EXIT_OK
    finally:
        if app is not None:
            app.close()
        if not opts.work:
            shutil.rmtree(work, ignore_errors=True)
        with open(os.path.join(out, SUMMARY), "w") as f:
            json.dump(summary, f, indent=1, default=str)
    for problem in summary["problems"]:
        print(f"shipped-nightly: {problem}", file=sys.stderr)
    return code


if __name__ == "__main__":
    sys.exit(main())
