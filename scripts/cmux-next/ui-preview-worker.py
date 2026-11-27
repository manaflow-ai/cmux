#!/usr/bin/env python3
"""The resident UI preview worker: one reserved display Mac that shoots the screens a cmux NEXT UI push touches,
before and after, and hands them to the agent that pushed, with no app build and no agent action.

    ui-preview-worker.py serve --state DIR [--bind ADDR] [--port 8765] [--public URL] [--send CMD]
                               [--publish-receipts CMD] [--no-warm] [--no-swift] [--follow]
    ui-preview-worker.py once --state DIR [REQUEST.json|-] [--send CMD] [--public URL]
    ui-preview-worker.py warm --state DIR
    ui-preview-worker.py submit --to http://HOST:PORT [REQUEST.json|-]
    ui-preview-worker.py publish FILE HOST

--follow takes requests from the lane-gh broker's push trigger itself (`lane-gh call ui_preview_requests`, a 20 s
long-poll; cmuxterm-hq tools/lane-gh-broker/parts/49-calls-ui-preview.py), so a push needs no agent action and no
POST. The last seq taken is kept in DIR/follow-seq; a first start begins at the broker's newest, not its backlog.
--no-swift makes a web-only worker (a Linux host with no display or Xcode): it warms and shoots the web side only,
takes from the broker only requests with a web file, and names a request's Swift scenes as not shot here.
`publish FILE HOST` writes FILE (the receipts) as ui-preview/HOST.json on cmuxterm-hq's now-census through the
broker's state_put, which NOW's ui_preview.p95_push_to_post_s reads:
`--publish-receipts 'python3 ui-preview-worker.py publish {file} {host}'`.

Goal auto-ui-preview-under-60s (cmuxterm-hq goals/auto-ui-preview-under-60s.md), cuts 3, 4, 5 and 7: the look runs
on copies that stay warm between pushes instead of a NIGHTLY copied per look (hot-verify's fleet step: 154 s p50).
Leo, 2026-11-22: "we need to get more ambitious, especially given how we've made our stuff more efficient end to end
to end."

The request (ui-preview-request/v1; the trigger in the lane-gh broker sends it, see the record's `## Pipeline
contract`; until then `submit`, `once` or a POST to /request):

    {"schema": "ui-preview-request/v1", "repo": "manaflow-ai/cmux", "head_sha": "<40 hex>", "base_sha": "<40 hex>",
     "branch": "lane/x", "ui_files": ["webviews/src/...", "Packages/macOS/CmuxNext/Sources/CmuxNextTabs/..."],
     "recipient": "<acpmux session that pushed, HOST/NAME>", "recipient_host": "<host>",
     "pushed_at": "<ISO UTC>"}

What stays warm under --state:

  cmux/          a blob-less clone of manaflow-ai/cmux; each look fetches only its head and base
  swift/         a worktree of it holding Prototypes/UiLayerHost's `.build` (the UI shell, cmux-ui-layer): a changed
                 file in a shell module is an incremental `swift build` (5.8 s in the ui-shell ceiling run), never
                 the app
  web/           a worktree of it with webviews' node_modules and the live gallery (`bun run gallery:dev`, vite with
                 hot reload) running over it: a checkout of another commit is picked up by the dev server's watcher,
                 so a web look is a checkout plus a headless shot (ui-preview-shoot.mjs), no gallery build
  shots/KIND/SHA/  every shot set this worker took, by commit: the before of a push is the after of the push before
                 it (cut 7), so an agent's second push shoots one side
  looks/TOKEN/   what the agent is sent: before/SCENE.png and after/SCENE.png, served at --public/looks/TOKEN/ under a
                 128-bit random token on the worker's tailnet address only (private repo content never goes public)
  ui-preview-HOST.json  the ui-preview/v1 receipts (cmuxterm-hq tools/fleet-reconcilers/now_ui_preview.py), 36 h

Scenes come from the diff alone:
  - a Swift file under Packages/macOS/CmuxNext/Sources/<module>/ of a shell module: that module's playground windows
    (SWIFT_SCENES); the UI shell's own sources (Prototypes/UiLayerHost) shoot every scene
  - a web file: the gallery entries webviews/scripts/gallery/touched.ts ranks first (WEB_CAP of them), each its
    default variant in dark at the gallery's narrow width
  - a Swift file outside the shell's modules, or a package manifest: no look, the receipt says the change needs an
    app build (hot-verify.py's own rule: Swift needs a build), and nothing is built

Each receipt carries `stages` (seconds: queue, fetch, plan, swift_before, swift_after, web_before, web_after, publish,
send) and `push_to_post_s`. Exit 0 posted, 1 failed, 2 usage.
"""
from __future__ import annotations

import argparse
import datetime as dt
import fnmatch
import hashlib
import http.server
import json
import os
import queue
import re
import secrets
import shlex
import shutil
import signal
import socket
import subprocess
import sys
import threading
import time
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCHEMA_REQUEST = "ui-preview-request/v1"
SCHEMA_RECEIPT = "ui-preview/v1"
CMUX_REPO = "manaflow-ai/cmux"
CMUX_URL = f"https://github.com/{CMUX_REPO}.git"
BASE_BRANCH = "feat-cmux-next"
SHA = re.compile(r"^[0-9a-f]{40}$")
BRANCH_NAME = re.compile(r"^[A-Za-z0-9._][A-Za-z0-9._/-]*$")  # a plain branch name, as the brokered fetch takes it
SESSION = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:/@-]{0,200}$")
BRANCH = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._/-]{0,250}$")
# The web gallery also reads design/ (icons) and first-party-apps/<app>/preview: both are web looks.
WEB_PREFIXES = ("webviews/", "cmux-tui/frontends/web/", "design/", "first-party-apps/")
UI_PREFIXES = (*WEB_PREFIXES, "Packages/macOS/CmuxNext/")
SWIFT_ROOT = "Packages/macOS/CmuxNext/Sources/"
SHELL_PACKAGE = "Prototypes/UiLayerHost"
SHELL_PRODUCT = "cmux-ui-layer"
# The shell's scenes (UiShellShoot.swift scenes()) by the module whose views each draws. A module the scenes all
# lean on (the design system, its tokens and icons) shoots them all. Other modules the shell links (Settings, Compat,
# the preview leaf) draw in no scene: a change there has nothing to show here.
ALL_SWIFT_SCENES = ("tabs", "sidebar-states", "all-themes", "keycaps")
SWIFT_SCENES = {
    "CmuxNextTabs": ("tabs",),
    "CmuxNextSidebar": ("sidebar-states",),
    "CmuxNextDesign": ALL_SWIFT_SCENES,
    "CmuxNextDesignTokens": ALL_SWIFT_SCENES,
    "CmuxNextIcons": ALL_SWIFT_SCENES,
}
SHELL_LINKED = {"CmuxNextUiLayerPreview", "CmuxNextSettings", "CmuxNextCompat"}
WEB_CAP = 4
# The Swift tree is whole but for the iOS app (0.5 of the tree's 1.35 GB, read by no macOS build). An allow-list drifts
# out from under the builds: the shell's settings plugin came to run scripts/cmux-next/gen-settings-sources.py, and
# every look failed on a file not checked out.
SWIFT_SPARSE = ("/*", "!/cmux-next-ios/")
# The web tree: everything but the large folders no web file imports. A hand list of folders drifted: bun install's
# postinstall reads release-notes/ and schemas/, protocol:codegen the acpmux IR, gallery entries fixtures under
# Packages/ and cmux-tui/crates/, the model catalog under web/data/; each missing one failed every web look.
WEB_SPARSE = ("/*", "!/cmux-next-ios/", "!/ghostty/", "!/ghostty-next/")
GALLERY_PORT = 4217
# Warm galleries (web tree, vite, shooter) kept at once, each on one gallery config; ports GALLERY_PORT and up.
GALLERIES = 2
KEEP_H = 36
# The published census copy (ui-preview/HOST.json on now-census) goes through the broker's state_put, which refuses a
# file over STATE_MAX (1 MiB, cmuxterm-hq tools/lane-gh-broker/parts/46-calls-state.py). The local receipts file kept
# 36 h pretty-printed with stages, plans and entries and passed it on 2026-11-26 about 11:20Z (1.4 MB by 23:30Z):
# every publish after was refused, the refusal went nowhere, and NOW read 3 covered of 2203 pushes from a copy 12 h
# old. So the published doc carries only what NOW's ui_preview reads (cmuxterm-hq fleet-reconcilers/now_ui_preview.py),
# only the window it counts, compact, and under PUBLISH_MAX bytes, oldest receipts dropped first.
PUBLISH_WINDOW_H = 25
PUBLISH_MAX = 768 << 10
PUBLISH_FILES = 8  # NOW asks only whether any is a UI path; the count stays as ui_files_n
PUBLISH_FIELDS = ("repo", "head_sha", "branch", "pushed_at", "ui_files", "recipient", "posted_at", "error",
                  "synthetic")
# Bounds, seconds.
FETCH_SECONDS = 180
COLD_BUILD_SECONDS = 45 * 60
BUILD_SECONDS = 15 * 60
SHOOT_SECONDS = 180
INSTALL_SECONDS = 15 * 60
GALLERY_UP_SECONDS = 180
# The gallery's ranker of touched entries; a tree without it (a branch off main) has no gallery to shoot.
GALLERY_RANKER = "webviews/scripts/gallery/touched.ts"
SEND_SECONDS = 60
PREFETCH_SECONDS = 300
# The VM's own mirror of manaflow-ai/cmux (repo-mirrors.timer, about every 15 min): the clone borrows its objects
# (objects/info/alternates), so a fetch from GitHub sends only what the mirror lacks and a checkout's blobs are local.
MIRROR = Path(os.environ.get("CMUX_UI_PREVIEW_MIRROR") or Path.home() / "Projects/.wt-mirrors/manaflow-ai/cmux.git")
# Looks run WEB_CAP at a time (fetch, verify, publish and send overlap; each gallery's web tree and the one shell tree
# are each one lock). A queued request is dropped for a newer push of its branch only once it waited this long.
LOOK_THREADS = WEB_CAP
SUPERSEDE_AGE_S = 45
# A gallery shot waits this long for the frame's ready mark, then reloads the page and waits again, within its bound
# (a page that loaded while vite restarted or re-optimized its deps never marks ready on its own).
SHOT_TRY_S = 20
SHOT_BOUND_S = 60
# Files whose change makes vite restart its server or re-optimize its deps: the worker restarts the gallery itself
# after a checkout that changes one, and waits for it to answer, instead of shooting pages into vite's own restart.
GALLERY_CONFIG = ("webviews/vite.config*.ts", "webviews/package.json", "webviews/dev-server/", "bun.lock",
                  "webviews/bun.lock")
# A gallery entry one side of the push does not have (the push adds it): that side's picture is a card that says so,
# not a 60 s wait for a frame that never marks ready (the frame settles the whole registry first, then fails).
ABSENT_PREFIX = "absent."
# Every gallery vite keeps its React Compiler (Babel) output on disk (webviews/reactCompiler.mjs
# CMUX_VITE_TRANSFORM_CACHE), one folder for all galleries: a vite restarted on a new config, or started on a spare
# tree, reads what any gallery already compiled instead of recompiling agent-pane (App.tsx alone ~33 s), which was
# the 41-63 s of a config push's cold side. Keyed by each module's exact code and the lockfile; pruned past
# TRANSFORM_CACHE_MB, oldest first, at warm.
TRANSFORM_CACHE_MB = 2048
PRESHOOT_FAMILIES = ("agent-pane.", "pages.")
# vite's optimized deps, one folder per gallery config in each tree (node_modules/.vite-<key>, CMUX_VITE_CACHE_DIR;
# inside webviews/, where the gallery's fs.allow lets vite serve it), the newest DEPS_KEYS kept: a gallery back on a
# config it served keeps its deps instead of a scan and bundle, and two galleries never share one folder.
DEPS_KEYS = 6
ENTRY_ID = re.compile(r'\bid:\s*"([a-z0-9][a-z0-9.-]*)"')
NO_LAZY = {**os.environ, "GIT_NO_LAZY_FETCH": "1"}


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")[:-4] + "Z"


def parse_ts(value) -> dt.datetime | None:
    try:
        t = dt.datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except (TypeError, ValueError):
        return None
    return t if t.tzinfo else t.replace(tzinfo=dt.timezone.utc)


def log(message: str) -> None:
    print(f"{utc_now()} ui-preview: {message}", file=sys.stderr, flush=True)


def tail(text, most: int = 400) -> str:
    if isinstance(text, bytes):
        text = text.decode("utf-8", "replace")
    return " ".join((text or "").split())[-most:]


class LookError(Exception):
    pass


def run(argv: list[str], cwd: Path | None = None, timeout: float = 120, env: dict | None = None,
        what: str | None = None) -> str:
    """Runs argv and returns its stdout; a failure or a timeout raises LookError naming WHAT and its last words."""
    what = what or argv[0]
    try:
        done = subprocess.run(argv, cwd=cwd, capture_output=True, text=True, timeout=timeout,
                              env={**os.environ, **(env or {})})
    except subprocess.TimeoutExpired as err:
        raise LookError(f"{what} ran past {int(timeout)} s: {tail(err.stderr or err.stdout)}") from None
    except OSError as err:
        raise LookError(f"{what} could not start: {err}") from None
    if done.returncode != 0:
        raise LookError(f"{what} exited {done.returncode}: {tail(done.stderr or done.stdout)}")
    return done.stdout


def git(repo: Path, *args: str, timeout: float = 120) -> str:
    return run(["git", "-C", str(repo), *args], timeout=timeout, what=f"git {args[0]}").strip()


class Stages:
    """Wall seconds per named stage, in order."""

    def __init__(self) -> None:
        self.seconds: dict[str, float] = {}

    def __call__(self, name: str):
        stages = self

        class _Timer:
            def __enter__(self):
                self.began = time.monotonic()

            def __exit__(self, *exc):
                stages.seconds[name] = round(stages.seconds.get(name, 0) + time.monotonic() - self.began, 3)
                return False

        return _Timer()


# ---- the request ---------------------------------------------------------------------------------------------

def check_request(req) -> dict:
    """The request, checked; raises LookError on anything this worker will not act on."""
    if not isinstance(req, dict) or req.get("schema") != SCHEMA_REQUEST:
        raise LookError(f"not a {SCHEMA_REQUEST} request")
    if req.get("repo") != CMUX_REPO:
        raise LookError(f"repo must be {CMUX_REPO}, not {req.get('repo')!r}")
    for key in ("head_sha", "base_sha"):
        if not SHA.match(str(req.get(key) or "")):
            raise LookError(f"{key} must be 40 hex")
    if req.get("branch") is not None and not BRANCH.match(str(req["branch"])):
        raise LookError("branch is not a plain branch name")
    if not SESSION.match(str(req.get("recipient") or "")):
        raise LookError("recipient must name a session")
    files = req.get("ui_files")
    if not isinstance(files, list) or not files or not all(isinstance(f, str) and f and ".." not in f
                                                          and not f.startswith("/") for f in files):
        raise LookError("ui_files must be a non-empty list of repo paths")
    if parse_ts(req.get("pushed_at")) is None:
        raise LookError("pushed_at must be an ISO time")
    return req


def plan(files: list[str]) -> dict:
    """Which kinds of look the changed FILES need and which scenes: {swift: [scenes], web: bool, needs_build:
    [paths], nothing: [paths]}. Pure: the diff alone."""
    swift: list[str] = []
    web = False
    needs_build: list[str] = []
    nothing: list[str] = []
    for path in files:
        if path.startswith(WEB_PREFIXES):
            web = True
        elif path.startswith(SHELL_PACKAGE + "/Sources/"):
            swift.extend(ALL_SWIFT_SCENES)
        elif path.startswith(SWIFT_ROOT):
            module = path[len(SWIFT_ROOT):].split("/", 1)[0]
            if module in SWIFT_SCENES:
                swift.extend(SWIFT_SCENES[module])
            elif module in SHELL_LINKED:
                nothing.append(path)
            elif path.endswith(".swift") or "/" in path[len(SWIFT_ROOT):]:
                needs_build.append(path)
        elif path.startswith("Packages/macOS/CmuxNext/"):
            # Package.swift, Tests, resources outside Sources: a manifest needs a build; tests show nothing.
            (needs_build if path.endswith("Package.swift") else nothing).append(path)
        else:
            nothing.append(path)
    return {"swift": [s for s in ALL_SWIFT_SCENES if s in swift], "web": web, "needs_build": needs_build,
            "nothing": nothing}


# ---- the warm trees --------------------------------------------------------------------------------------------

class Gallery:
    """One web tree with its node_modules, its vite dev server (gallery:dev on its own port) and its resident shooter
    (one chromium). A worker keeps up to GALLERIES of them, each on one gallery config: a look whose sides differ in
    config shoots each side on a vite already on that config. Restarting one vite costs more than its start: the
    restart drops vite's module graph, and the next page recompiles it (40-60 s for agent-pane entries)."""

    def __init__(self, worker: "Worker", tree: Path, port: int, name: str) -> None:
        self.worker = worker
        self.tree = tree
        self.port = port
        self.name = name
        self.key: str | None = None  # the gallery config of the tree's checkout (Worker.gallery_key)
        self.used = 0.0
        self.lock = threading.Lock()  # the tree, its vite and its shooter: one side's checkout and shots at a time
        self.proc: subprocess.Popen | None = None
        self.lock_hash: str | None = None
        self.shooter: subprocess.Popen | None = None
        self.shooter_lines: "queue.Queue[str | None]" = queue.Queue()
        suffix = "" if name == "web" else f"-{name}"
        self.log_path = worker.state / f"gallery-dev{suffix}.log"
        self.shooter_log = worker.state / f"shooter{suffix}.log"

    def checkout(self, sha: str) -> None:
        """The tree at SHA. A checkout that changes the gallery's config, deps or dev server restarts the gallery here
        (start waits for it to answer): vite would restart or re-optimize on its own, and pages loaded meanwhile
        never marked ready (every base-side shot of a vite.config.ts push timed out at 60 s)."""
        old = None
        if (self.tree / ".git").exists():
            with _suppress():
                old = git(self.tree, "rev-parse", "HEAD").strip()
        self.worker.ensure_tree(self.tree, WEB_SPARSE, sha)
        if old and old != sha and self.worker.gallery_config_changed(old, sha):
            log(f"gallery {self.name}: config changed {old[:12]}..{sha[:12]}: restarting it")
            self.stop()
        self.key = self.worker.gallery_key(sha)

    def entry_ids(self) -> set[str]:
        """The gallery entry ids the tree's checkout holds, as the dev server's entry index reads them
        (webviews/dev-server/galleryHost.ts readEntryIndex: the first `id: "..."` after `export default` in each
        *.gallery.ts(x), else the file's first)."""
        ids = set()
        root = self.tree / "webviews" / "src"
        for dirpath, dirnames, filenames in os.walk(root):
            dirnames[:] = [d for d in dirnames if d != "node_modules"]
            for name in filenames:
                if not re.search(r"\.gallery\.tsx?$", name):
                    continue
                with _suppress():
                    text = (Path(dirpath) / name).read_text(errors="replace")
                    at = text.find("export default")
                    m = (ENTRY_ID.search(text[at:]) if at >= 0 else None) or ENTRY_ID.search(text)
                    if m:
                        ids.add(m.group(1))
        return ids

    def install(self) -> bool:
        """bun install when the lockfile changed since the last install; True when it ran."""
        lock = self.tree / "bun.lock"
        digest = git(self.tree, "hash-object", str(lock)) if lock.exists() else "none"
        if digest == self.lock_hash and (self.tree / "webviews" / "node_modules").is_dir():
            return False
        run([self.worker.bun(), "install", "--frozen-lockfile"], cwd=self.tree / "webviews", timeout=INSTALL_SECONDS,
            what="bun install")
        self.lock_hash = digest
        return True

    def deps_dir(self, key: str | None = None) -> Path:
        return self.tree / "webviews" / "node_modules" / f".vite-{key or self.key or 'none'}"

    def vite_env(self) -> dict:
        """The gallery vite's port, the React Compiler pass, the shared transform cache and this config's deps folder.
        oxc, not babel: four agent-pane entries on a cold vite took 64-70 s under babel (App.tsx alone ~33 s) and
        21 s under oxc, with byte-identical PNGs. The transform cache only applies under babel (reactCompiler.mjs
        returns before it for oxc); it stays set so CMUX_REACT_COMPILER=babel in the worker's env is still fast."""
        return {"CMUX_GALLERY_DEV_PORT": str(self.port),
                "CMUX_REACT_COMPILER": os.environ.get("CMUX_REACT_COMPILER") or "oxc",
                "CMUX_VITE_TRANSFORM_CACHE": str(self.worker.state / "vite-transforms"),
                "CMUX_VITE_CACHE_DIR": str(self.deps_dir())}

    def seed_deps(self) -> None:
        """This config's deps folder: kept when the tree served the config before; else a copy of a sibling's on the
        same config, else of this tree's newest. vite keeps a copy whose hash still matches (most config pushes leave
        the deps alone) instead of a 50 s scan and bundle. The newest DEPS_KEYS folders stay."""
        mine = self.deps_dir()
        modules = mine.parent
        if not modules.is_dir():
            return
        if not mine.exists():
            same = [g.deps_dir(self.key) for g in self.worker.galleries if g is not self]
            own = sorted(modules.glob(".vite-*"), key=lambda p: p.stat().st_mtime, reverse=True)
            source = next((d for d in [*same, *own] if d.is_dir() and (d / "deps").is_dir()), None)
            if source is not None:
                with _suppress():
                    shutil.copytree(source, mine, symlinks=True, ignore=shutil.ignore_patterns("deps_temp_*"))
        with _suppress():
            mine.mkdir(exist_ok=True)
            os.utime(mine)
        kept = sorted(modules.glob(".vite-*"), key=lambda p: p.stat().st_mtime, reverse=True)
        for old in kept[DEPS_KEYS:]:
            shutil.rmtree(old, ignore_errors=True)

    def up(self) -> bool:
        try:
            with urllib.request.urlopen(f"http://127.0.0.1:{self.port}/gallery/", timeout=3) as r:
                return r.status == 200
        except OSError:
            return False

    def start(self) -> None:
        if self.proc is not None and self.proc.poll() is None and self.up():
            return
        self.stop()
        self.seed_deps()
        logf = open(self.log_path, "ab")
        self.proc = subprocess.Popen([self.worker.bun(), "run", "gallery:dev"], cwd=self.tree / "webviews",
                                     stdout=logf, stderr=subprocess.STDOUT, start_new_session=True,
                                     env={**os.environ, **self.vite_env()})
        deadline = time.monotonic() + GALLERY_UP_SECONDS
        while time.monotonic() < deadline:
            if self.proc.poll() is not None:
                raise LookError(f"gallery:dev exited {self.proc.returncode} (see {self.log_path})")
            if self.up():
                return
            time.sleep(0.5)
        raise LookError(f"gallery:dev did not answer in {GALLERY_UP_SECONDS} s")

    def stop(self) -> None:
        if self.proc is not None and self.proc.poll() is None:
            with _suppress():
                os.killpg(self.proc.pid, signal.SIGTERM)
            with _suppress():
                self.proc.wait(10)
        self.proc = None

    def scenes(self, files: list[str]) -> list[str]:
        """The gallery entries touched.ts ranks first for FILES, at the tree's checkout."""
        changed = self.worker.state / f"changed-{threading.get_ident()}.txt"
        changed.write_text("\n".join(files) + "\n")
        try:
            out = run([self.worker.bun(), "scripts/gallery/touched.ts", "--changed", str(changed)],
                      cwd=self.tree / "webviews", timeout=120, what="touched.ts")
        finally:
            with _suppress():
                changed.unlink()
        touched = json.loads(out)
        ranked = [r.get("id") for r in touched.get("ranked") or [] if isinstance(r, dict)]
        return [i for i in ranked if isinstance(i, str) and re.match(r"^[A-Za-z0-9][A-Za-z0-9._-]*$", i)][:WEB_CAP]

    def shoot(self, entries: list[str], out: Path, absent: dict | None = None) -> dict:
        """ENTRIES shot into OUT by the resident shooter (one chromium kept open between looks); when it fails, one
        shooter run of its own (a cold chromium) before the look gives up. An entry in ABSENT ({entry: sha}) is
        not in this checkout: its picture is a card saying so (file ABSENT_PREFIX...). {entry: file}."""
        if out.exists():
            shutil.rmtree(out)
        out.mkdir(parents=True)
        absent = absent or {}
        spec = {"base": f"http://127.0.0.1:{self.port}/gallery/", "scheme": "dark", "out": str(out),
                "try_ms": SHOT_TRY_S * 1000, "bound_ms": SHOT_BOUND_S * 1000,
                "shots": [{"name": e, "entry": e, **({"absent": absent[e][:12]} if e in absent else {})}
                          for e in entries]}
        try:
            rows = self.shoot_resident(spec)
        except LookError as err:
            log(f"the resident shooter ({self.name}): {err}; one cold shoot")
            self.stop_shooter()
            rows = self.shoot_once(spec, out)
        shots = {}
        for row in rows:
            if isinstance(row, dict) and row.get("file") and (out / row["file"]).is_file():
                shots[row["name"]] = row["file"]
        if not shots and entries:
            errors = [str(r.get("error")) for r in rows if isinstance(r, dict) and r.get("error")]
            raise LookError(f"the gallery shoot took no shot: {tail('; '.join(errors)) or 'no answer'}")
        return shots

    def shoot_once(self, spec: dict, out: Path) -> list:
        (out / "spec.json").write_text(json.dumps(spec))
        try:
            done = subprocess.run([self.worker.bun(), str(HERE / "ui-preview-shoot.mjs"), str(out / "spec.json"),
                                   str(out)], cwd=self.tree / "webviews", capture_output=True, text=True,
                                  timeout=SHOOT_SECONDS)
        except subprocess.TimeoutExpired:
            raise LookError(f"the gallery shoot ran past {SHOOT_SECONDS} s") from None
        rows = []
        for line in done.stdout.splitlines():
            with _suppress():
                rows.append(json.loads(line))
        if not rows and done.returncode != 0:
            raise LookError(f"the gallery shoot exited {done.returncode}: {tail(done.stderr or done.stdout)}")
        return rows

    def shoot_resident(self, spec: dict) -> list:
        """One spec line to `ui-preview-shoot.mjs --serve` (started on first use, cwd the tree's webviews/), one
        answer line back: {"shots": [{name, file} | {name, error}]}."""
        if self.shooter is None or self.shooter.poll() is not None:
            self.shooter_lines = queue.Queue()
            with open(self.shooter_log, "ab") as logf:
                self.shooter = subprocess.Popen([self.worker.bun(), str(HERE / "ui-preview-shoot.mjs"), "--serve"],
                                                cwd=self.tree / "webviews", stdin=subprocess.PIPE,
                                                stdout=subprocess.PIPE, stderr=logf, text=True, start_new_session=True)
            lines, stdout = self.shooter_lines, self.shooter.stdout

            def pump() -> None:
                for line in stdout:
                    lines.put(line)
                lines.put(None)

            threading.Thread(target=pump, name=f"shooter-out-{self.name}", daemon=True).start()
        try:
            self.shooter.stdin.write(json.dumps(spec) + "\n")
            self.shooter.stdin.flush()
        except (OSError, ValueError) as err:
            raise LookError(f"could not hand it the spec: {err}") from None
        deadline = time.monotonic() + SHOOT_SECONDS
        while True:
            try:
                line = self.shooter_lines.get(timeout=max(0.1, deadline - time.monotonic()))
            except queue.Empty:
                raise LookError(f"no answer in {SHOOT_SECONDS} s") from None
            if line is None:
                raise LookError(f"it exited {self.shooter.wait()} (see {self.shooter_log})")
            with _suppress():
                answer = json.loads(line)
                if isinstance(answer, dict) and isinstance(answer.get("shots"), list):
                    return answer["shots"]

    def stop_shooter(self) -> None:
        if self.shooter is not None and self.shooter.poll() is None:
            with _suppress():
                self.shooter.stdin.close()
            with _suppress():
                self.shooter.wait(10)
            if self.shooter.poll() is None:
                with _suppress():
                    os.killpg(self.shooter.pid, signal.SIGTERM)
        if self.shooter is not None and self.shooter.stdout is not None:
            with _suppress():
                self.shooter.stdout.close()
        self.shooter = None


class Worker:
    def __init__(self, state: Path, public: str | None, send: str | None, publish: str | None,
                 host: str | None = None) -> None:
        self.state = state.resolve()
        self.state.mkdir(parents=True, exist_ok=True)
        self.clone = self.state / "cmux"
        self.swift_tree = self.state / "swift"
        self.public = (public or "").rstrip("/")
        self.send_template = send
        self.publish_template = publish
        self.host = host or socket.gethostname().split(".")[0]
        self.receipts_path = self.state / f"ui-preview-{self.host}.json"
        self.swift_lock = threading.Lock()  # the shell's tree and .build
        self.fetch_lock = threading.Lock()  # the clone's fetches (a prefetch and a look's fetch of one head)
        self.receipt_lock = threading.Lock()
        self.swift_on = True  # serve --no-swift: a web-only worker
        self.mirror = MIRROR if (MIRROR / "objects").is_dir() else None
        self.publisher = Publisher(self)
        self.newest: dict[str, tuple[float, str]] = {}  # branch -> (received, head) of its newest queued request
        self.newest_lock = threading.Lock()
        self.galleries_lock = threading.Lock()
        self.gallery_keys: dict[str, str] = {}  # sha -> its gallery config's key
        self.web = Gallery(self, self.state / "web", GALLERY_PORT, "web")
        self.galleries = [self.web]

    # The clone and its worktrees.
    def ensure_clone(self) -> None:
        with self.fetch_lock:
            if not ((self.clone / "HEAD").exists() or (self.clone / ".git").exists()):
                log(f"cloning {CMUX_URL} (blob-less{', borrowing ' + str(self.mirror) if self.mirror else ''}) "
                    f"into {self.clone}")
                run(["git", "clone", "--filter=blob:none", "--no-checkout", "--single-branch", "--branch", BASE_BRANCH,
                     *(["--reference-if-able", str(self.mirror)] if self.mirror else []), CMUX_URL, str(self.clone)],
                    timeout=1800, what="git clone")
            self.borrow_mirror()

    def borrow_mirror(self) -> None:
        """The clone reads the VM mirror's objects (commits, trees and the blobs its checkouts hold) before asking
        GitHub: one alternates line, added once. No mirror: GitHub alone, as before."""
        if not self.mirror:
            return
        alternates = self.clone / "objects" / "info" / "alternates"
        line = str(self.mirror / "objects")
        with _suppress():
            have = alternates.read_text().split("\n") if alternates.exists() else []
            if line not in have:
                alternates.parent.mkdir(parents=True, exist_ok=True)
                alternates.write_text("".join(f"{h}\n" for h in have if h) + line + "\n")

    def has_commit(self, sha: str) -> bool:
        return subprocess.run(["git", "-C", str(self.clone), "cat-file", "-e", f"{sha}^{{commit}}"],
                              capture_output=True, env=NO_LAZY).returncode == 0

    def has_gallery(self, sha: str) -> bool:
        """SHA's tree holds the gallery's ranker (GALLERY_RANKER): a branch off main, which has none, has no web look
        to take (every one failed "Module not found scripts/gallery/touched.ts" and counted as a miss)."""
        return subprocess.run(["git", "-C", str(self.clone), "cat-file", "-e", f"{sha}:{GALLERY_RANKER}"],
                              capture_output=True, env=NO_LAZY).returncode == 0

    def is_ancestor(self, sha: str, tip: str) -> bool:
        return subprocess.run(["git", "-C", str(self.clone), "merge-base", "--is-ancestor", sha, tip],
                              capture_output=True, env=NO_LAZY).returncode == 0

    def local_base_tips(self) -> list[str]:
        """BASE_BRANCH's tips held here with no GitHub read: the clone's (warm-up's fetch) and the VM mirror's (a
        mirror of manaflow-ai/cmux, so a commit under its tip landed). The clone reads the mirror's objects."""
        tips = []
        for repo, ref in ((self.clone, f"refs/remotes/origin/{BASE_BRANCH}"), (self.mirror, f"refs/heads/{BASE_BRANCH}")):
            if repo is None:
                continue
            done = subprocess.run(["git", "-C", str(repo), "rev-parse", "-q", "--verify", f"{ref}^{{commit}}"],
                                  capture_output=True, text=True, env=NO_LAZY)
            if done.returncode == 0 and SHA.match(done.stdout.strip()):
                tips.append(done.stdout.strip())
        return list(dict.fromkeys(tips))

    def fetch(self, *shas: str, branches: tuple[str | None, ...] = ()) -> None:
        """SHAS into the clone: what the clone or the mirror holds already is not fetched; the rest by BRANCHES (and
        BASE_BRANCH) as origin/B, then by id only for what is still missing (one lock, so a prefetch and a look never
        fetch one head twice). By branch, never by --filter or a bare id: on a lane VM that publishes through the
        broker (host-gh) git fetch carries plain branch names and tracking refspecs only, and every warm-up died
        "git fetch --filter=blob:none: an option the brokered fetch does not carry" (lane-1/2, 2026-11-26). The
        blob-less clone's own config (remote.origin.partialclonefilter) keeps a plain git's fetch blob-less."""
        with self.fetch_lock:
            missing = [s for s in dict.fromkeys(shas) if not self.has_commit(s)]
            if missing:
                self.fetch_branches(*branches, BASE_BRANCH)
                missing = [s for s in missing if not self.has_commit(s)]
            if missing:
                git(self.clone, "fetch", "-q", "--no-tags", "--no-write-fetch-head", "origin", *missing,
                    timeout=FETCH_SECONDS)

    def fetch_branches(self, *branches: str | None) -> None:
        """BRANCHES' tips into the clone as refs/remotes/origin/B (the caller holds fetch_lock, or needs none)."""
        names = [b for b in dict.fromkeys(branches) if b and BRANCH_NAME.match(b)]
        if names:
            git(self.clone, "fetch", "-q", "--no-tags", "--no-write-fetch-head", "origin",
                *(f"+refs/heads/{b}:refs/remotes/origin/{b}" for b in names), timeout=FETCH_SECONDS)

    def remote_tip(self, branch: str) -> str | None:
        done = subprocess.run(["git", "-C", str(self.clone), "rev-parse", "-q", "--verify",
                               f"refs/remotes/origin/{branch}^{{commit}}"], capture_output=True, text=True, env=NO_LAZY)
        return done.stdout.strip() if done.returncode == 0 and SHA.match(done.stdout.strip()) else None

    def prefetch(self, req: dict) -> None:
        """While REQ waits in the queue: its head and base into the clone, and the blobs the diff between them reads
        (a partial clone fetches the missing ones in one batch), so the look's fetch and checkout find them here."""
        head, base = req["head_sha"], req["base_sha"]
        began = time.monotonic()
        try:
            self.ensure_clone()
            self.fetch(head, base, branches=(req.get("branch"),))
            git(self.clone, "diff", "--numstat", "--no-renames", base, head, "--", ".", ":!cmux-next-ios",
                ":!ghostty", ":!ghostty-next", timeout=PREFETCH_SECONDS)
            log(f"prefetch {head[:12]}: {time.monotonic() - began:.1f} s")
        except LookError as err:
            log(f"prefetch {head[:12]}: {err}")

    def start_prefetch(self, req: dict) -> threading.Thread:
        thread = threading.Thread(target=self.prefetch, args=(req,), name=f"prefetch-{req['head_sha'][:8]}",
                                  daemon=True)
        thread.start()
        return thread

    def ensure_tree(self, tree: Path, sparse: tuple[str, ...], sha: str) -> None:
        if not (tree / ".git").exists():
            git(self.clone, "worktree", "prune")
            git(self.clone, "worktree", "add", "--no-checkout", "--detach", str(tree), sha, timeout=300)
            git(tree, "sparse-checkout", "set", "--no-cone", *sparse)
        elif git(tree, "sparse-checkout", "list").split() != list(sparse):
            # A resident tree made under an older list: widen it in place, keeping its .build and node_modules.
            git(tree, "sparse-checkout", "set", "--no-cone", *sparse, timeout=600)
        self.checkout(tree, sha)

    def checkout(self, tree: Path, sha: str) -> None:
        git(tree, "checkout", "-q", "--detach", "--force", sha, timeout=600)

    def on_branch_tip_or_landed(self, head: str, branch: str | None) -> bool:
        """The head is a manaflow-ai/cmux branch's tip, or landed on feat-cmux-next: never a fork's commit (the
        look builds and runs the head's code). A head under a base tip held here asks GitHub nothing; else the
        branch tip the look's fetch wrote (origin/BRANCH: a tip the repo held, so the repo's own commit even if the
        branch moved since), and only when that is not the head one fetch of the branch and the base. No ls-remote: a lane VM's git has no GitHub credential, only the broker's fetch."""
        if any(self.is_ancestor(head, tip) for tip in self.local_base_tips()):
            return True
        if branch and self.remote_tip(branch) == head:
            return True
        with self.fetch_lock:
            self.fetch_branches(branch, BASE_BRANCH)
        if branch and self.remote_tip(branch) == head:
            return True
        tip = self.remote_tip(BASE_BRANCH)
        return bool(tip) and self.is_ancestor(head, tip)

    def gallery_config_changed(self, old: str, new: str) -> bool:
        out = git(self.clone, "diff", "--name-only", "--no-renames", old, new, "--",
                  *(f":(glob){p}**" if p.endswith("/") else f":(glob){p}" for p in GALLERY_CONFIG))
        return bool(out.strip())

    # The Swift shell.
    def shell_binary(self) -> Path:
        pkg = self.swift_tree / SHELL_PACKAGE
        out = run(["swift", "build", "--product", SHELL_PRODUCT, "--show-bin-path"], cwd=pkg, timeout=120,
                  what="swift build --show-bin-path")
        return Path(out.strip().splitlines()[-1]) / SHELL_PRODUCT

    def build_shell(self, cold: bool = False) -> None:
        pkg = self.swift_tree / SHELL_PACKAGE
        if not (pkg / "Package.swift").is_file():
            raise LookError(f"{SHELL_PACKAGE} is not at this commit")
        run(["swift", "build", "--product", SHELL_PRODUCT], cwd=pkg,
            timeout=COLD_BUILD_SECONDS if cold else BUILD_SECONDS, what="the shell's swift build")

    def shoot_shell(self, scenes: list[str], out: Path) -> dict:
        """The shell's --shoot of SCENES into OUT; {scene: file} for each scene that wrote a PNG."""
        if out.exists():
            shutil.rmtree(out)
        out.mkdir(parents=True)
        pkg = self.swift_tree / SHELL_PACKAGE
        binary = self.shell_binary()
        try:
            done = subprocess.run([str(binary), "--shoot", str(out), "--scene", ",".join(scenes)], cwd=pkg,
                                  capture_output=True, text=True, timeout=SHOOT_SECONDS)
        except subprocess.TimeoutExpired:
            raise LookError(f"the shell's shoot ran past {SHOOT_SECONDS} s") from None
        receipt_file = out / "receipt.json"
        if not receipt_file.is_file():
            raise LookError(f"the shell's shoot exited {done.returncode} with no receipt.json: "
                            f"{tail(done.stderr or done.stdout)}")
        shots = {}
        for shot in json.loads(receipt_file.read_text()).get("shots") or []:
            files = shot.get("files") or []
            if files and (out / files[0]).is_file():
                shots[shot["scene"]] = files[0]
        return shots

    def swift_side(self, sha: str, scenes: list[str]) -> dict:
        """SHA's shell shots of SCENES, from the shot cache when this worker already took them, else checkout,
        incremental build and shoot. {scene: path}."""
        cache = self.state / "shots" / "swift" / sha
        have = {s: cache / f for s, f in (self._cached(cache)).items() if s in scenes}
        want = [s for s in scenes if s not in have]
        if want:
            self.ensure_tree(self.swift_tree, SWIFT_SPARSE, sha)
            self.build_shell()
            fresh = cache.with_name(f".{sha}.{os.getpid()}.{threading.get_ident()}")
            shots = self.shoot_shell(want, fresh)
            merged = {**self._cached(cache), **shots}
            cache.mkdir(parents=True, exist_ok=True)
            for scene, name in shots.items():
                os.replace(fresh / name, cache / name)
            (cache / "index.json").write_text(json.dumps(merged))
            shutil.rmtree(fresh, ignore_errors=True)
            have.update({s: cache / shots[s] for s in want if s in shots})
        return have

    @staticmethod
    def _cached(cache: Path) -> dict:
        try:
            index = json.loads((cache / "index.json").read_text())
        except (OSError, ValueError):
            return {}
        return {s: f for s, f in index.items() if (cache / f).is_file()}

    # The web gallery.
    def bun(self) -> str:
        found = shutil.which("bun") or next((p for p in ("/Users/Shared/cmux-build-fleet/tools/bin/bun",
                                                         str(Path.home() / ".bun/bin/bun")) if Path(p).exists()), None)
        if not found:
            raise LookError("no bun on this worker")
        return found

    @property
    def web_tree(self) -> Path:
        return self.web.tree

    def gallery_key(self, sha: str) -> str | None:
        """SHA's gallery config (GALLERY_CONFIG's blob ids, read from the tree: no blob fetched), or None when the
        clone cannot read it. Two commits with one key run on one vite without a restart."""
        with self.galleries_lock:
            if sha in self.gallery_keys:
                return self.gallery_keys[sha]
        try:
            rows = git(self.clone, "ls-tree", "-r", sha, "--", "webviews/", "bun.lock").splitlines()
        except LookError:
            return None
        picked = []
        for row in rows:
            path = row.split("\t", 1)[-1]
            if any(path.startswith(p) if p.endswith("/") else fnmatch.fnmatchcase(path, p) for p in GALLERY_CONFIG):
                picked.append(row)
        key = hashlib.sha256("\n".join(sorted(picked)).encode()).hexdigest()[:16]
        with self.galleries_lock:
            self.gallery_keys[sha] = key
        return key

    def gallery_for(self, sha: str, avoid: tuple = ()) -> "Gallery":
        """The gallery to shoot SHA on: one already on SHA's config (its vite warm), else one not yet checked out,
        else a new one up to GALLERIES, else the least recently used (its checkout restarts it). Never one in AVOID
        while another is free: the look's other side holds it."""
        key = self.gallery_key(sha)
        with self.galleries_lock:
            free = [g for g in self.galleries if g not in avoid]
            pick = next((g for g in free if key is not None and g.key == key), None)
            pick = pick or next((g for g in free if g.key is None), None)
            if pick is None and len(self.galleries) < GALLERIES:
                n = len(self.galleries) + 1
                pick = Gallery(self, self.state / f"web-{n}", GALLERY_PORT + n - 1, f"web-{n}")
                self.galleries.append(pick)
            pick = pick or min(free or self.galleries, key=lambda g: g.used)
            pick.used = time.monotonic()
            return pick

    def stop_gallery(self) -> None:
        for g in list(self.galleries):
            g.stop()

    def stop_shooter(self) -> None:
        for g in list(self.galleries):
            g.stop_shooter()

    def web_side(self, sha: str, entries: list[str], gallery: "Gallery | None" = None) -> dict:
        cache = self.state / "shots" / "web" / sha
        have = {s: cache / f for s, f in self._cached(cache).items() if s in entries}
        want = [e for e in entries if e not in have]
        if want:
            g = gallery or self.gallery_for(sha)
            with g.lock:
                g.checkout(sha)
                if g.install():
                    g.stop()
                    g.stop_shooter()
                g.start()
                # vite's watcher sees the checkout; a page loaded after it settles takes the new modules.
                time.sleep(0.4)
                fresh = cache.with_name(f".{sha}.{os.getpid()}.{threading.get_ident()}")
                held = g.entry_ids()
                absent = {e: sha for e in want if e not in held}
                shots = g.shoot(want, fresh, absent)
            merged = {**self._cached(cache), **shots}
            cache.mkdir(parents=True, exist_ok=True)
            for name, rel in shots.items():
                dest = cache / Path(rel).name
                os.replace(fresh / rel, dest)
                merged[name] = dest.name
            (cache / "index.json").write_text(json.dumps(merged))
            shutil.rmtree(fresh, ignore_errors=True)
            have.update({s: cache / merged[s] for s in want if s in merged})
        return have

    def web_sides(self, head: str, base: str, entries: list[str], g_head: "Gallery", stages: Stages) -> tuple:
        """Both sides' shots. Sides on one gallery config shoot one after the other on one vite; sides on two configs
        shoot at once, each on its own warm vite (a vite.config.ts push restarted one vite twice: 105 s)."""
        g_base = g_head if self.gallery_key(base) in (None, g_head.key) else self.gallery_for(base, avoid=(g_head,))
        if g_base is g_head:
            with stages("web_after"):
                after = self.web_side(head, entries, g_head)
            with stages("web_before"):
                before = self.web_side(base, entries, g_base)
            return before, after
        got: dict = {}

        def side(name: str, sha: str, g: "Gallery") -> None:
            try:
                with stages(name):
                    got[name] = self.web_side(sha, entries, g)
            except LookError as err:
                got[name] = err

        other = threading.Thread(target=side, args=("web_before", base, g_base), name=f"before-{base[:8]}",
                                 daemon=True)
        other.start()
        side("web_after", head, g_head)
        other.join()
        for name in ("web_after", "web_before"):
            if isinstance(got.get(name), LookError):
                raise got[name]
        return got["web_before"], got["web_after"]

    # Warm-up: the clone, both trees at the base tip, the shell's .build, node_modules, the gallery and the shooter's
    # chromium, with one entry shot at the tip (vite has compiled the gallery; the shot is the next push's before).
    def warm(self, web: bool = True, swift: bool = True) -> dict:
        stages = Stages()
        with stages("clone"):
            self.ensure_clone()
            ref = f"refs/remotes/origin/{BASE_BRANCH}"
            with self.fetch_lock:
                self.fetch_branches(BASE_BRANCH)
            tip = git(self.clone, "rev-parse", ref)
        errors = []
        prune_transforms(self.state / "vite-transforms")
        if swift:
            try:
                with stages("swift"):
                    self.ensure_tree(self.swift_tree, SWIFT_SPARSE, tip)
                    self.build_shell(cold=True)
            except LookError as err:
                errors.append(f"swift: {err}")
        if web:
            try:
                g = self.web
                with stages("web"), g.lock:
                    g.checkout(tip)
                    g.install()
                    g.start()
                with stages("web_preshoot"):
                    # A change to the gallery itself touches every entry: the first one ranked is a real entry. Plus
                    # one entry of each big family (PRESHOOT_FAMILIES): vite and the transform cache hold its modules
                    # (agent-pane's App.tsx is ~33 s of React Compiler cold), so a push's first agent-pane look is warm.
                    entries = g.scenes(["webviews/src/gallery/warm"])[:1]
                    held = sorted(g.entry_ids())
                    for family in PRESHOOT_FAMILIES:
                        pick = next((e for e in held if e.startswith(family)), None)
                        if pick and not any(e.startswith(family) for e in entries):
                            entries.append(pick)
                    if entries:
                        self.web_side(tip, entries, g)
                with stages("web_spare"):
                    # The spare galleries' trees and node_modules at the tip: a push that changes the gallery config
                    # checks one out and starts its vite (deps cache seeded), with no worktree add or cold install.
                    while len(self.galleries) < GALLERIES:
                        spare = self.gallery_for(tip, avoid=tuple(self.galleries))
                        with spare.lock:
                            spare.checkout(tip)
                            spare.install()
                            spare.seed_deps()
            except LookError as err:
                errors.append(f"web: {err}")
        return {"tip": tip, "stages": stages.seconds, "errors": errors}

    # One look.
    def new_receipt(self, req: dict) -> dict:
        receipt = {k: req.get(k) for k in ("repo", "head_sha", "base_sha", "branch", "pushed_at", "ui_files",
                                           "recipient")}
        receipt.update(posted_at=None, scenes=[], worker=self.host, started_at=utc_now())
        if req.get("synthetic"):
            receipt["synthetic"] = True
        return receipt

    def refuse(self, req: dict, why: str, received: float | None = None) -> dict:
        """REQ's receipt with WHY and no look: nothing fetched, nothing shot."""
        receipt = self.new_receipt(req)
        receipt["error"] = why[:500]
        receipt["stages"] = {"queue": round(time.monotonic() - received, 3) if received is not None else 0.0}
        self.write_receipt(receipt)
        log(f"{req.get('head_sha', '')[:12]}: {receipt['error']}")
        return receipt

    def note_queued(self, req: dict, received: float) -> None:
        if req.get("branch"):
            with self.newest_lock:
                if received >= self.newest.get(req["branch"], (0.0, ""))[0]:
                    self.newest[req["branch"]] = (received, req["head_sha"])

    def superseded_by(self, req: dict, received: float, now: float | None = None) -> str | None:
        """The newer head of REQ's branch that replaces it, once REQ waited past SUPERSEDE_AGE_S; else None (a look
        that can start in time runs, even when its branch moved on)."""
        now = time.monotonic() if now is None else now
        if not req.get("branch") or now - received <= SUPERSEDE_AGE_S:
            return None
        with self.newest_lock:
            at, head = self.newest.get(req["branch"], (0.0, ""))
        return head if at > received and head != req["head_sha"] else None

    def look(self, req: dict, received: float | None = None) -> dict:
        received = received if received is not None else time.monotonic()
        stages = Stages()
        stages.seconds["queue"] = round(time.monotonic() - received, 3)
        receipt = self.new_receipt(req)
        self.write_receipt(receipt)
        try:
            self._look(req, receipt, stages)
        except LookError as err:
            receipt["error"] = str(err)[:500]
            log(f"{req.get('head_sha', '')[:12]}: {receipt['error']}")
        receipt["stages"] = stages.seconds
        pushed, posted = parse_ts(receipt.get("pushed_at")), parse_ts(receipt.get("posted_at"))
        if pushed and posted:
            receipt["push_to_post_s"] = round((posted - pushed).total_seconds(), 3)
        self.write_receipt(receipt)
        return receipt

    def _look(self, req: dict, receipt: dict, stages: Stages) -> None:
        head, base = req["head_sha"], req["base_sha"]
        with stages("plan"):
            planned = plan(req["ui_files"])
        receipt["plan"] = planned
        why = skip_reason(planned)
        if why:
            raise LookError(why)
        with stages("fetch"):
            self.ensure_clone()
            self.fetch(head, base, branches=(req.get("branch"),))
            if not self.on_branch_tip_or_landed(head, req.get("branch")):
                raise LookError(f"{head[:12]} is neither {req.get('branch')}'s tip on {CMUX_REPO} nor on "
                                f"{BASE_BRANCH}: no look at a commit that is not the repo's own")
            if planned["web"] and not self.has_gallery(head):
                planned = {**planned, "web": False, "no_gallery": True}
                receipt["plan"] = planned
                if not planned["swift"]:
                    raise LookError(f"no scene shows these files: {head[:12]} has no {GALLERY_RANKER} "
                                    f"(a branch off main, not {BASE_BRANCH})")
        pairs: list[tuple[str, str, Path | None, Path | None]] = []  # (kind, scene, before, after)
        errors = []
        if planned["needs_build"]:
            pass  # The web side still shows; the shell is not built over Swift it does not hold (said below).
        elif planned["swift"] and not self.swift_on:
            errors.append(f"swift: {', '.join(planned['swift'])} not shot: this worker ({self.host}) shoots web "
                          "scenes only")
        elif planned["swift"]:
            try:
                with self.swift_lock:
                    with stages("swift_before"):
                        before = self.swift_side(base, planned["swift"])
                    with stages("swift_after"):
                        after = self.swift_side(head, planned["swift"])
                pairs += [("swift", s, before.get(s), after.get(s)) for s in planned["swift"]]
            except LookError as err:
                errors.append(f"swift: {err}")
        if planned["web"]:
            try:
                began = time.monotonic()
                g = self.gallery_for(head)
                with stages("web_plan"):
                    with g.lock:  # the head's gallery: its checkout and touched.ts, then each side under its own lock
                        stages.seconds["web_wait"] = round(time.monotonic() - began, 3)
                        g.checkout(head)
                        if g.install():
                            g.stop()
                            g.stop_shooter()
                        web_files = [f for f in req["ui_files"] if f.startswith(WEB_PREFIXES)]
                        entries = g.scenes(web_files)
                receipt["web_entries"] = entries
                if entries:
                    # Head first: its tree is checked out already; the base is often cached (the last push's head).
                    before, after = self.web_sides(head, base, entries, g, stages)
                    pairs += [("web", e, before.get(e), after.get(e)) for e in entries]
                else:
                    errors.append("web: touched.ts names no gallery entry for these files")
            except LookError as err:
                errors.append(f"web: {err}")
        with stages("publish"):
            token = secrets.token_hex(16)
            look_dir = self.state / "looks" / token
            scenes = []
            for kind, scene, before, after in pairs:
                row = {"scene": scene, "kind": kind}
                for side, src in (("before", before), ("after", after)):
                    if src is not None and src.is_file():
                        dest = look_dir / side / f"{kind}-{scene}.png"
                        dest.parent.mkdir(parents=True, exist_ok=True)
                        shutil.copyfile(src, dest)
                        row[side] = self.url(token, side, dest.name)
                        row[f"{side}_path"] = str(dest)
                        if src.name.startswith(ABSENT_PREFIX):
                            row[f"{side}_absent"] = True  # the entry is not in this side's commit (a new entry)
                if before is not None and after is not None and before.is_file() and after.is_file():
                    row["changed"] = before.read_bytes() != after.read_bytes()
                scenes.append(row)
        receipt["scenes"] = scenes
        receipt["look"] = token
        if planned["needs_build"]:
            errors.append(needs_build_reason(planned))  # last: the 500-character error keeps the web side's why
        if errors:
            receipt["error"] = "; ".join(errors)[:500]
        if not any(s.get("before") and s.get("after") for s in scenes):
            raise LookError(receipt.get("error") or "no scene was shot")
        with stages("send"):
            self.send(req["recipient"], self.message(req, scenes, receipt))
        receipt["posted_at"] = utc_now()

    def url(self, token: str, side: str, name: str) -> str:
        rel = f"looks/{token}/{side}/{name}"
        return f"{self.public}/{rel}" if self.public else str(self.state / rel)

    def message(self, req: dict, scenes: list[dict], receipt: dict) -> str:
        head = req["head_sha"][:12]
        lines = [f"UI preview of your push {head} ({req.get('branch') or 'no branch'}), before {req['base_sha'][:12]} "
                 f"and after, from the resident preview worker on {self.host}:"]
        for s in scenes:
            mark = (" (new: not in the base)" if s.get("before_absent") else " (removed)" if s.get("after_absent")
                    else "" if s.get("changed", True) else " (no visible change)")
            lines.append(f"- {s['kind']} {s['scene']}{mark}: before {s.get('before') or 'none'}  after {s.get('after') or 'none'}")
        if receipt.get("error"):
            lines.append(f"Partly: {receipt['error']}")
        if self.public:
            lines.append(f"Read one: d=$(mktemp -d) && curl -s -o \"$d/ui-preview-{head}.png\" URL, then open it (tailnet only).")
        return "\n".join(lines) + "\n"

    def send(self, recipient: str, text: str) -> None:
        """Hands TEXT to RECIPIENT with --send's command ({recipient} filled in, the text on stdin); with no --send,
        writes it to outbox/ (a test)."""
        if not self.send_template:
            box = self.state / "outbox"
            box.mkdir(exist_ok=True)
            (box / f"{int(time.time() * 1000)}-{re.sub(r'[^A-Za-z0-9._-]', '_', recipient)}.txt").write_text(text)
            return
        argv = [a.replace("{recipient}", recipient) for a in shlex.split(self.send_template)]
        try:
            done = subprocess.run(argv, input=text, capture_output=True, text=True, timeout=SEND_SECONDS)
        except (subprocess.TimeoutExpired, OSError) as err:
            raise LookError(f"the send to {recipient} failed: {err}") from None
        if done.returncode != 0:
            raise LookError(f"the send to {recipient} exited {done.returncode}: {tail(done.stderr or done.stdout)}")

    # Receipts.
    def write_receipt(self, receipt: dict) -> None:
        with self.receipt_lock:
            try:
                doc = json.loads(self.receipts_path.read_text())
            except (OSError, ValueError):
                doc = {}
            rows = [r for r in doc.get("receipts") or [] if isinstance(r, dict)]
            cutoff = dt.datetime.now(dt.timezone.utc) - dt.timedelta(hours=KEEP_H)
            key = (receipt.get("repo"), receipt.get("head_sha"))
            rows = [r for r in rows if (r.get("repo"), r.get("head_sha")) != key
                    and (parse_ts(r.get("pushed_at")) or cutoff) >= cutoff]
            rows.append({k: v for k, v in receipt.items() if not k.endswith("_path")})
            for row in rows:
                for scene in row.get("scenes") or []:
                    scene.pop("before_path", None)
                    scene.pop("after_path", None)
            doc = {"schema": SCHEMA_RECEIPT, "host": self.host, "at": utc_now(), "receipts": rows}
            tmp = self.receipts_path.with_suffix(f".{threading.get_ident()}.tmp")
            tmp.write_text(json.dumps(doc, indent=1) + "\n")
            os.replace(tmp, self.receipts_path)
        if self.publish_template and receipt.get("stages") is not None:
            self.publisher.kick()

    def publish_now(self) -> None:
        """--publish-receipts once over the file as it is now (the publisher's thread; never a look's)."""
        argv = [a.replace("{file}", str(self.receipts_path)).replace("{host}", self.host)
                for a in shlex.split(self.publish_template or "")]
        if not argv:
            return
        try:
            done = subprocess.run(argv, capture_output=True, text=True, timeout=SEND_SECONDS)
        except (OSError, subprocess.SubprocessError) as err:
            log(f"publish: {err}")
            return
        if done.returncode != 0:  # a refused publish was silent for 12 h (PUBLISH_MAX): say it each time
            log(f"publish exited {done.returncode}: {tail(done.stderr or done.stdout)}")


class Publisher:
    """One background thread publishes the receipts file; a look only marks it stale and goes on. Writes coalesce:
    the file is rewritten whole, so the publish that runs next carries every receipt written before it began (the
    latest doc wins), and a burst of N writes during one slow publish costs one more publish, not N."""

    def __init__(self, worker: "Worker") -> None:
        self.worker = worker
        self.cv = threading.Condition()
        self.pending = False
        self.busy = False
        self.runs = 0
        self.thread: threading.Thread | None = None

    def kick(self) -> None:
        with self.cv:
            self.pending = True
            if self.thread is None or not self.thread.is_alive():
                self.thread = threading.Thread(target=self._loop, name="publish", daemon=True)
                self.thread.start()
            self.cv.notify_all()

    def _loop(self) -> None:
        while True:
            with self.cv:
                while not self.pending:
                    self.cv.wait()
                self.pending, self.busy = False, True
            try:
                self.worker.publish_now()
            finally:
                with self.cv:
                    self.busy = False
                    self.runs += 1
                    self.cv.notify_all()

    def flush(self, timeout: float = SEND_SECONDS * 2) -> bool:
        """Waits for the publishes asked for so far (a one-shot command before it exits); False past TIMEOUT."""
        deadline = time.monotonic() + timeout
        with self.cv:
            while self.pending or self.busy:
                left = deadline - time.monotonic()
                if left <= 0:
                    return False
                self.cv.wait(left)
        return True


def prune_transforms(folder: Path, cap_mb: int = TRANSFORM_CACHE_MB) -> int:
    """The shared transform cache under CAP_MB: the oldest entries go first, down to three quarters of it (each push
    adds the modules it changed). The number removed."""
    if not folder.is_dir():
        return 0
    rows = []
    for dirpath, _, filenames in os.walk(folder):
        for name in filenames:
            with _suppress():
                st = (Path(dirpath) / name).stat()
                rows.append((st.st_mtime, st.st_size, Path(dirpath) / name))
    total = sum(r[1] for r in rows)
    if total <= cap_mb << 20:
        return 0
    removed = 0
    for _, size, path in sorted(rows):
        if total <= (cap_mb << 20) * 3 // 4:
            break
        with _suppress():
            path.unlink()
            total -= size
            removed += 1
    return removed


def needs_build_reason(planned: dict) -> str:
    files = planned["needs_build"]
    more = f" and {len(files) - 3} more" if len(files) > 3 else ""
    return f"needs an app build (Swift outside the UI shell's modules, or a manifest): {', '.join(files[:3])}{more}"


def skip_reason(planned: dict) -> str | None:
    """Why a plan gets no look at all (said in the receipt at once, nothing fetched): every file needs an app build or
    shows in no scene. A needs_build file beside a web file still gets the web look."""
    if planned["web"]:
        return None
    if planned["needs_build"]:
        return needs_build_reason(planned)
    if not planned["swift"]:
        return "no scene shows these files"
    return None


class _suppress:
    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return exc[0] is not None and issubclass(exc[0], Exception)


# ---- the daemon ----------------------------------------------------------------------------------------------

def make_handler(worker: Worker, jobs: "queue.Queue"):
    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, fmt, *args):
            pass

        def reply(self, code: int, body, kind: str = "application/json") -> None:
            data = body if isinstance(body, bytes) else (json.dumps(body) + "\n").encode()
            self.send_response(code)
            self.send_header("Content-Type", kind)
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            path = self.path.split("?", 1)[0]
            if path == "/health":
                return self.reply(200, {"ok": True, "host": worker.host, "queued": jobs.qsize(),
                                        "gallery": worker.web.up()})
            if path == "/receipts":
                try:
                    return self.reply(200, worker.receipts_path.read_bytes())
                except OSError:
                    return self.reply(200, {"schema": SCHEMA_RECEIPT, "host": worker.host, "receipts": []})
            found = re.match(r"^/looks/([0-9a-f]{32})/(before|after)/([A-Za-z0-9._-]+\.png)$", path)
            if found:
                file = worker.state / "looks" / found[1] / found[2] / found[3]
                if file.is_file():
                    return self.reply(200, file.read_bytes(), "image/png")
            return self.reply(404, {"error": "not found"})

        def do_POST(self):
            if self.path != "/request":
                return self.reply(404, {"error": "not found"})
            try:
                size = int(self.headers.get("Content-Length") or 0)
                req = check_request(json.loads(self.rfile.read(min(size, 1 << 20))))
            except (ValueError, LookError) as err:
                return self.reply(400, {"error": str(err)})
            enqueue(worker, jobs, req)
            return self.reply(202, {"queued": jobs.qsize(), "head_sha": req["head_sha"]})

    return Handler


def tailnet_address() -> str | None:
    for tool in ("tailscale", "/Applications/Tailscale.app/Contents/MacOS/Tailscale"):
        with _suppress():
            out = subprocess.run([tool, "ip", "-4"], capture_output=True, text=True, timeout=10).stdout.split()
            if out:
                return out[0]
    return None


FOLLOW_WAIT_S = 20  # the broker's long-poll bound (UI_PREVIEW_WAIT_MAX_S)
FOLLOW_RETRY_S = 10  # after a failed call


def lane_gh_call(tool: str, args: dict, timeout: float, repo: str | None = None) -> dict:
    """One `lane-gh call TOOL [REPO] JSON` through the broker: the answer's data (status 200), or LookError."""
    try:
        done = subprocess.run(["lane-gh", "call", tool, *([repo] if repo else []), json.dumps(args)],
                              capture_output=True, text=True, timeout=timeout)
    except (subprocess.TimeoutExpired, OSError) as err:
        raise LookError(f"lane-gh call {tool}: {err}") from None
    if done.returncode != 0:
        raise LookError(f"lane-gh call {tool} exited {done.returncode}: {tail(done.stderr or done.stdout)}")
    try:
        answer = json.loads(done.stdout)
    except ValueError:
        raise LookError(f"lane-gh call {tool}: not JSON: {tail(done.stdout)}") from None
    if not isinstance(answer, dict) or answer.get("status") != 200:
        raise LookError(f"lane-gh call {tool}: not answered 200: {tail(json.dumps(answer))}")
    data = answer.get("data")
    return data if isinstance(data, dict) else {}


def enqueue(worker: "Worker", jobs: "queue.Queue", req: dict) -> threading.Thread | None:
    """REQ into the jobs queue, or its receipt at once when no look would show it (no fetch). A queued request's
    head and base are fetched while it waits (the prefetch thread returned)."""
    received = time.monotonic()
    why = skip_reason(plan(req["ui_files"]))
    if why:
        worker.refuse(req, why, received)
        return None
    worker.note_queued(req, received)
    jobs.put((req, received))
    return worker.start_prefetch(req)


def drain(worker: "Worker", jobs: "queue.Queue", once: bool = False) -> None:
    """One of the LOOK_THREADS look threads: takes the next request; one that waited past SUPERSEDE_AGE_S while its
    branch was pushed again gets a superseded receipt instead of a look."""
    while True:
        req, received = jobs.get()
        try:
            newer = worker.superseded_by(req, received)
            if newer:
                receipt = worker.refuse(req, f"superseded by {newer[:12]} after {SUPERSEDE_AGE_S} s queued", received)
            else:
                receipt = worker.look(req, received)
            log(f"{req['head_sha'][:12]}: posted_at {receipt.get('posted_at')} push_to_post_s "
                f"{receipt.get('push_to_post_s')} stages {receipt.get('stages')} error {receipt.get('error')}")
        except Exception as err:  # a look thread outlives one bad look
            log(f"{req.get('head_sha', '')[:12]}: look thread: {err!r}")
        finally:
            jobs.task_done()
        if once:
            return


def follow_once(worker: "Worker", jobs: "queue.Queue", after: int | None, call=lane_gh_call) -> int:
    """One long-poll of the broker's push trigger: queues each request this worker takes and returns the seq to ask
    after next. AFTER None (a first start): the broker's newest, taking nothing (no backlog)."""
    answer = call("ui_preview_requests", {"after": after or 0, "wait": 0 if after is None else FOLLOW_WAIT_S},
                  FOLLOW_WAIT_S + 60)
    newest = answer.get("seq") if isinstance(answer.get("seq"), int) else 0
    if after is None:
        return newest
    for raw in answer.get("requests") or []:
        seq = raw.get("seq") if isinstance(raw, dict) else None
        if isinstance(seq, int):
            after = max(after, seq)
        try:
            req = check_request(raw)
        except LookError as err:
            log(f"follow: request {seq} not taken: {err}")
            continue
        planned = plan(req["ui_files"])
        if not worker.swift_on and not planned["web"] and not skip_reason(planned):
            continue  # Swift scenes only: the display Mac's
        if enqueue(worker, jobs, req):
            log(f"follow: request {seq} {req['head_sha'][:12]} ({req.get('branch')}) queued for {req['recipient']}")
    if answer.get("reset"):
        return newest  # the broker's queue restarted below our seq
    return after


def follow(worker: "Worker", jobs: "queue.Queue", call=lane_gh_call) -> None:
    seq_file = worker.state / "follow-seq"
    try:
        after: int | None = int(seq_file.read_text().strip())
    except (OSError, ValueError):
        after = None
    while True:
        try:
            nxt = follow_once(worker, jobs, after, call)
        except LookError as err:
            log(f"follow: {err}; again in {FOLLOW_RETRY_S} s")
            time.sleep(FOLLOW_RETRY_S)
            continue
        if nxt != after:
            after = nxt
            with _suppress():
                seq_file.write_text(f"{after}\n")


def command_serve(args) -> int:
    worker = Worker(Path(args.state), args.public, args.send, args.publish_receipts)
    worker.swift_on = not args.no_swift
    bind = args.bind or tailnet_address() or "127.0.0.1"
    if not worker.public:
        worker.public = f"http://{bind}:{args.port}"
    if not args.no_warm:
        log(f"warming: {json.dumps(worker.warm(swift=worker.swift_on))}")
    jobs: queue.Queue = queue.Queue()
    if args.follow:
        threading.Thread(target=follow, args=(worker, jobs), name="follow", daemon=True).start()

    for n in range(LOOK_THREADS):
        threading.Thread(target=drain, args=(worker, jobs), name=f"look-{n}", daemon=True).start()
    server = http.server.ThreadingHTTPServer((bind, args.port), make_handler(worker, jobs))
    log(f"serving on http://{bind}:{args.port} (state {worker.state})")
    try:
        server.serve_forever()
    finally:
        worker.stop_shooter()
        worker.stop_gallery()
    return 0


def read_request(source: str) -> dict:
    text = sys.stdin.read() if source == "-" else Path(source).read_text()
    return check_request(json.loads(text))


def command_once(args) -> int:
    worker = Worker(Path(args.state), args.public, args.send, args.publish_receipts)
    try:
        req = read_request(args.request)
    except (OSError, ValueError, LookError) as err:
        print(f"ui-preview-worker: {err}", file=sys.stderr)
        return 2
    try:
        receipt = worker.look(req)
    finally:
        worker.stop_shooter()
        if not args.keep_gallery:
            worker.stop_gallery()
        worker.publisher.flush()
    print(json.dumps(receipt, indent=1))
    return 0 if receipt.get("posted_at") else 1


def command_warm(args) -> int:
    worker = Worker(Path(args.state), None, None, None)
    result = worker.warm(web=not args.no_web, swift=not args.no_swift)
    worker.stop_shooter()
    worker.stop_gallery()
    print(json.dumps(result, indent=1))
    return 0 if not result["errors"] else 1


def command_submit(args) -> int:
    try:
        req = read_request(args.request)
    except (OSError, ValueError, LookError) as err:
        print(f"ui-preview-worker: {err}", file=sys.stderr)
        return 2
    data = json.dumps(req).encode()
    request = urllib.request.Request(args.to.rstrip("/") + "/request", data=data,
                                     headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=30) as r:
        print(r.read().decode().strip())
    return 0


def publish_doc(doc: dict, now: dt.datetime | None = None, limit: int = PUBLISH_MAX) -> str:
    """DOC (the local receipts file) as the census copy: the receipts pushed in the last PUBLISH_WINDOW_H hours, each
    with PUBLISH_FIELDS (at most PUBLISH_FILES ui_files) and its scenes' before and after (relative to the row's
    look_base, when every shot shares one), compact, newest kept and oldest dropped until it is at most
    LIMIT bytes. Raises ValueError for a doc that is not ui-preview/v1."""
    if not isinstance(doc, dict) or doc.get("schema") != SCHEMA_RECEIPT or not isinstance(doc.get("receipts"), list):
        raise ValueError("the receipts file is not a ui-preview/v1 document")
    cutoff = (now or dt.datetime.now(dt.timezone.utc)) - dt.timedelta(hours=PUBLISH_WINDOW_H)
    rows = []
    for r in doc["receipts"]:
        pushed = parse_ts(r.get("pushed_at")) if isinstance(r, dict) else None
        if pushed is None or pushed < cutoff:
            continue
        row = {k: r[k] for k in PUBLISH_FIELDS if r.get(k) is not None}
        if isinstance(row.get("error"), str):
            row["error"] = row["error"][:200]
        files = row.get("ui_files")
        if isinstance(files, list) and len(files) > PUBLISH_FILES:  # a whole-tree push named 17 KB of paths
            row["ui_files"], row["ui_files_n"] = files[:PUBLISH_FILES], len(files)
        scenes = [{k: s[k] for k in ("scene", "kind", "before", "after") if s.get(k)}
                  for s in r.get("scenes") or [] if isinstance(s, dict)]
        # Every shot's URL is the worker's http://HOST:PORT/looks/LOOK/ and a short tail: the base once, as look_base.
        bases = {m[1] for s in scenes for k in ("before", "after")
                 if isinstance(s.get(k), str) and (m := re.match(r"^(.*/looks/[0-9a-f]{32}/)(.+)$", s[k]))}
        if len(bases) == 1:
            row["look_base"] = base = bases.pop()
            for s in scenes:
                for k in ("before", "after"):
                    if isinstance(s.get(k), str) and s[k].startswith(base):
                        s[k] = s[k][len(base):]
        if scenes:
            row["scenes"] = scenes
        rows.append((pushed, row))
    rows.sort(key=lambda pr: pr[0])
    kept = [row for _, row in rows]
    head = {"schema": SCHEMA_RECEIPT, "host": doc.get("host"), "at": doc.get("at") or utc_now()}

    def encode(receipts: list) -> str:
        return json.dumps({**head, "receipts": receipts}, separators=(",", ":")) + "\n"

    text = encode(kept)
    while len(text.encode()) > limit and kept:
        over = len(text.encode()) - limit
        drop = max(1, over * len(kept) // max(1, len(text.encode())))
        kept = kept[drop:]
        text = encode(kept)
    return text


def command_publish(args) -> int:
    """FILE as ui-preview/HOST.json on cmuxterm-hq's reconciler-state/now-census (the broker's state_put)."""
    try:
        text = publish_doc(json.loads(Path(args.file).read_text()))
        lane_gh_call("state_put", {"name": "now-census", "files": {f"ui-preview/{args.host}.json": text}},
                     SEND_SECONDS, repo="manaflow-ai/cmuxterm-hq")
    except (OSError, ValueError, LookError) as err:
        print(f"ui-preview-worker: publish: {err}", file=sys.stderr)
        return 1
    return 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = ap.add_subparsers(dest="command", required=True)
    for name in ("serve", "once"):
        p = sub.add_parser(name)
        p.add_argument("--state", required=True)
        p.add_argument("--public", help="the URL the looks are served at (serve: http://<tailnet ip>:PORT)")
        p.add_argument("--send", help="the command that hands the message to the recipient, {recipient} filled in, "
                                      "text on stdin (e.g. 'lane-gh send {recipient} -'); none: outbox/")
        p.add_argument("--publish-receipts", help="a command run after each receipt write, {file} and {host} "
                                                  "filled in")
        if name == "serve":
            p.add_argument("--bind")
            p.add_argument("--port", type=int, default=8765)
            p.add_argument("--no-warm", action="store_true")
            p.add_argument("--no-swift", action="store_true", help="a web-only worker (no display, no Xcode)")
            p.add_argument("--follow", action="store_true",
                           help="take requests from the lane-gh broker's push trigger (ui_preview_requests)")
        else:
            p.add_argument("request", nargs="?", default="-")
            p.add_argument("--keep-gallery", action="store_true")
    p = sub.add_parser("warm")
    p.add_argument("--state", required=True)
    p.add_argument("--no-web", action="store_true")
    p.add_argument("--no-swift", action="store_true")
    p = sub.add_parser("submit")
    p.add_argument("--to", required=True)
    p.add_argument("request", nargs="?", default="-")
    p = sub.add_parser("publish")
    p.add_argument("file")
    p.add_argument("host")
    args = ap.parse_args(argv)
    return {"serve": command_serve, "once": command_once, "warm": command_warm, "submit": command_submit,
            "publish": command_publish}[args.command](args)


if __name__ == "__main__":
    raise SystemExit(main())
