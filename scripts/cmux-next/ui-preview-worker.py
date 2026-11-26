#!/usr/bin/env python3
"""The resident UI preview worker: one reserved display Mac that shoots the screens a cmux NEXT UI push touches,
before and after, and hands them to the agent that pushed, with no app build and no agent action.

    ui-preview-worker.py serve --state DIR [--bind ADDR] [--port 8765] [--public URL] [--send CMD]
                               [--publish-receipts CMD] [--no-warm]
    ui-preview-worker.py once --state DIR [REQUEST.json|-] [--send CMD] [--public URL]
    ui-preview-worker.py warm --state DIR
    ui-preview-worker.py submit --to http://HOST:PORT [REQUEST.json|-]

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
SESSION = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:/@-]{0,200}$")
BRANCH = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._/-]{0,250}$")
UI_PREFIXES = ("webviews/", "cmux-tui/frontends/web/", "Packages/macOS/CmuxNext/")
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
SWIFT_SPARSE = ("Packages/", "Prototypes/", "Resources/", "vendor/")
# The web tree: everything but the large folders no web file imports. A hand list of folders drifted: bun install's
# postinstall reads release-notes/ and schemas/, protocol:codegen the acpmux IR, gallery entries fixtures under
# Packages/ and cmux-tui/crates/, the model catalog under web/data/; each missing one failed every web look.
WEB_SPARSE = ("/*", "!/cmux-next-ios/", "!/ghostty/", "!/ghostty-next/")
GALLERY_PORT = 4217
KEEP_H = 36
# Bounds, seconds.
FETCH_SECONDS = 180
COLD_BUILD_SECONDS = 45 * 60
BUILD_SECONDS = 15 * 60
SHOOT_SECONDS = 180
INSTALL_SECONDS = 15 * 60
GALLERY_UP_SECONDS = 180
SEND_SECONDS = 60


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
        if path.startswith(("webviews/", "cmux-tui/frontends/web/")):
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

class Worker:
    def __init__(self, state: Path, public: str | None, send: str | None, publish: str | None,
                 host: str | None = None) -> None:
        self.state = state.resolve()
        self.state.mkdir(parents=True, exist_ok=True)
        self.clone = self.state / "cmux"
        self.swift_tree = self.state / "swift"
        self.web_tree = self.state / "web"
        self.public = (public or "").rstrip("/")
        self.send_template = send
        self.publish_template = publish
        self.host = host or socket.gethostname().split(".")[0]
        self.receipts_path = self.state / f"ui-preview-{self.host}.json"
        self.gallery: subprocess.Popen | None = None
        self.gallery_port = GALLERY_PORT
        self.web_lock_hash: str | None = None
        self.lock = threading.Lock()
        self.receipt_lock = threading.Lock()

    # The clone and its worktrees.
    def ensure_clone(self) -> None:
        if (self.clone / "HEAD").exists() or (self.clone / ".git").exists():
            return
        log(f"cloning {CMUX_URL} (blob-less) into {self.clone}")
        run(["git", "clone", "--filter=blob:none", "--no-checkout", "--single-branch", "--branch", BASE_BRANCH,
             CMUX_URL, str(self.clone)], timeout=1800, what="git clone")

    def fetch(self, *shas: str) -> None:
        missing = [s for s in shas if subprocess.run(["git", "-C", str(self.clone), "cat-file", "-e", f"{s}^{{commit}}"],
                                                       capture_output=True).returncode != 0]
        if missing:
            git(self.clone, "fetch", "-q", "--filter=blob:none", "--no-tags", "origin", *missing, timeout=FETCH_SECONDS)

    def ensure_tree(self, tree: Path, sparse: tuple[str, ...], sha: str) -> None:
        if not (tree / ".git").exists():
            git(self.clone, "worktree", "prune")
            git(self.clone, "worktree", "add", "--no-checkout", "--detach", str(tree), sha, timeout=300)
            git(tree, "sparse-checkout", "set", "--no-cone", *sparse)
        self.checkout(tree, sha)

    def checkout(self, tree: Path, sha: str) -> None:
        git(tree, "checkout", "-q", "--detach", "--force", sha, timeout=600)

    def on_branch_tip_or_landed(self, head: str, branch: str | None) -> bool:
        """The head is a manaflow-ai/cmux branch's tip, or landed on feat-cmux-next: never a fork's commit (the
        look builds and runs the head's code). One ls-remote."""
        refs = [f"refs/heads/{branch}"] if branch else []
        out = git(self.clone, "ls-remote", "origin", *refs, f"refs/heads/{BASE_BRANCH}", timeout=60)
        tips = dict(line.split("\t")[::-1] for line in out.splitlines() if "\t" in line)
        if branch and tips.get(f"refs/heads/{branch}") == head:
            return True
        tip = tips.get(f"refs/heads/{BASE_BRANCH}")
        if tip:
            self.fetch(tip)
            return subprocess.run(["git", "-C", str(self.clone), "merge-base", "--is-ancestor", head, tip],
                                  capture_output=True).returncode == 0
        return False

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
            fresh = cache.with_name(f".{sha}.{os.getpid()}")
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

    def web_install(self) -> bool:
        """bun install when the lockfile changed since the last install; True when it ran."""
        lock = self.web_tree / "bun.lock"
        digest = git(self.web_tree, "hash-object", str(lock)) if lock.exists() else "none"
        if digest == self.web_lock_hash and (self.web_tree / "webviews" / "node_modules").is_dir():
            return False
        run([self.bun(), "install", "--frozen-lockfile"], cwd=self.web_tree / "webviews", timeout=INSTALL_SECONDS,
            what="bun install")
        self.web_lock_hash = digest
        return True

    def gallery_up(self) -> bool:
        try:
            with urllib.request.urlopen(f"http://127.0.0.1:{self.gallery_port}/gallery/", timeout=3) as r:
                return r.status == 200
        except OSError:
            return False

    def start_gallery(self) -> None:
        if self.gallery is not None and self.gallery.poll() is None and self.gallery_up():
            return
        self.stop_gallery()
        logf = open(self.state / "gallery-dev.log", "ab")
        self.gallery = subprocess.Popen([self.bun(), "run", "gallery:dev"], cwd=self.web_tree / "webviews",
                                        stdout=logf, stderr=subprocess.STDOUT, start_new_session=True,
                                        env={**os.environ, "CMUX_GALLERY_DEV_PORT": str(self.gallery_port)})
        deadline = time.monotonic() + GALLERY_UP_SECONDS
        while time.monotonic() < deadline:
            if self.gallery.poll() is not None:
                raise LookError(f"gallery:dev exited {self.gallery.returncode} (see {self.state / 'gallery-dev.log'})")
            if self.gallery_up():
                return
            time.sleep(0.5)
        raise LookError(f"gallery:dev did not answer in {GALLERY_UP_SECONDS} s")

    def stop_gallery(self) -> None:
        if self.gallery is not None and self.gallery.poll() is None:
            with _suppress():
                os.killpg(self.gallery.pid, signal.SIGTERM)
            with _suppress():
                self.gallery.wait(10)
        self.gallery = None

    def web_scenes(self, files: list[str]) -> list[str]:
        """The gallery entries touched.ts ranks first for FILES, at the head (the web tree's checkout)."""
        changed = self.state / "changed.txt"
        changed.write_text("\n".join(files) + "\n")
        out = run([self.bun(), "scripts/gallery/touched.ts", "--changed", str(changed)], cwd=self.web_tree / "webviews",
                  timeout=120, what="touched.ts")
        touched = json.loads(out)
        ranked = [r.get("id") for r in touched.get("ranked") or [] if isinstance(r, dict)]
        return [i for i in ranked if isinstance(i, str) and re.match(r"^[A-Za-z0-9][A-Za-z0-9._-]*$", i)][:WEB_CAP]

    def shoot_gallery(self, entries: list[str], out: Path) -> dict:
        if out.exists():
            shutil.rmtree(out)
        out.mkdir(parents=True)
        spec = {"base": f"http://127.0.0.1:{self.gallery_port}/gallery/", "scheme": "dark",
                "shots": [{"name": e, "entry": e} for e in entries]}
        (out / "spec.json").write_text(json.dumps(spec))
        shooter = HERE / "ui-preview-shoot.mjs"
        try:
            done = subprocess.run([self.bun(), str(shooter), str(out / "spec.json"), str(out)],
                                  cwd=self.web_tree / "webviews", capture_output=True, text=True, timeout=SHOOT_SECONDS)
        except subprocess.TimeoutExpired:
            raise LookError(f"the gallery shoot ran past {SHOOT_SECONDS} s") from None
        shots = {}
        for line in done.stdout.splitlines():
            with _suppress():
                row = json.loads(line)
                if row.get("file") and (out / row["file"]).is_file():
                    shots[row["name"]] = row["file"]
        if not shots and done.returncode != 0:
            raise LookError(f"the gallery shoot exited {done.returncode}: {tail(done.stderr or done.stdout)}")
        return shots

    def web_side(self, sha: str, entries: list[str]) -> dict:
        cache = self.state / "shots" / "web" / sha
        have = {s: cache / f for s, f in self._cached(cache).items() if s in entries}
        want = [e for e in entries if e not in have]
        if want:
            self.ensure_tree(self.web_tree, WEB_SPARSE, sha)
            if self.web_install():
                self.stop_gallery()
            self.start_gallery()
            # vite's watcher sees the checkout; a page loaded after it settles takes the new modules.
            time.sleep(0.4)
            fresh = cache.with_name(f".{sha}.{os.getpid()}")
            shots = self.shoot_gallery(want, fresh)
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

    # Warm-up: the clone, both trees at the base tip, the shell's .build, node_modules and the gallery.
    def warm(self, web: bool = True, swift: bool = True) -> dict:
        stages = Stages()
        with stages("clone"):
            self.ensure_clone()
            git(self.clone, "fetch", "-q", "--filter=blob:none", "--no-tags", "origin", BASE_BRANCH,
                timeout=FETCH_SECONDS)
            tip = git(self.clone, "rev-parse", "FETCH_HEAD")
        errors = []
        if swift:
            try:
                with stages("swift"):
                    self.ensure_tree(self.swift_tree, SWIFT_SPARSE, tip)
                    self.build_shell(cold=True)
            except LookError as err:
                errors.append(f"swift: {err}")
        if web:
            try:
                with stages("web"):
                    self.ensure_tree(self.web_tree, WEB_SPARSE, tip)
                    self.web_install()
                    self.start_gallery()
            except LookError as err:
                errors.append(f"web: {err}")
        return {"tip": tip, "stages": stages.seconds, "errors": errors}

    # One look.
    def look(self, req: dict, received: float | None = None) -> dict:
        received = received if received is not None else time.monotonic()
        stages = Stages()
        stages.seconds["queue"] = round(time.monotonic() - received, 3)
        receipt = {k: req.get(k) for k in ("repo", "head_sha", "base_sha", "branch", "pushed_at", "ui_files",
                                           "recipient")}
        receipt.update(posted_at=None, scenes=[], worker=self.host, started_at=utc_now())
        if req.get("synthetic"):
            receipt["synthetic"] = True
        self.write_receipt(receipt)
        try:
            with self.lock:
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
        if planned["needs_build"]:
            raise LookError("needs an app build (Swift outside the UI shell's modules, or a manifest): "
                            + ", ".join(planned["needs_build"][:5]))
        if not planned["swift"] and not planned["web"]:
            raise LookError("no scene shows these files")
        with stages("fetch"):
            self.ensure_clone()
            self.fetch(head, base)
            if not self.on_branch_tip_or_landed(head, req.get("branch")):
                raise LookError(f"{head[:12]} is neither {req.get('branch')}'s tip on {CMUX_REPO} nor on "
                                f"{BASE_BRANCH}: no look at a commit that is not the repo's own")
        pairs: list[tuple[str, str, Path | None, Path | None]] = []  # (kind, scene, before, after)
        errors = []
        if planned["swift"]:
            try:
                with stages("swift_before"):
                    before = self.swift_side(base, planned["swift"])
                with stages("swift_after"):
                    after = self.swift_side(head, planned["swift"])
                pairs += [("swift", s, before.get(s), after.get(s)) for s in planned["swift"]]
            except LookError as err:
                errors.append(f"swift: {err}")
        if planned["web"]:
            try:
                with stages("web_plan"):
                    self.ensure_tree(self.web_tree, WEB_SPARSE, head)
                    if self.web_install():
                        self.stop_gallery()
                    web_files = [f for f in req["ui_files"] if f.startswith(("webviews/", "cmux-tui/frontends/web/"))]
                    entries = self.web_scenes(web_files)
                receipt["web_entries"] = entries
                if entries:
                    # Head first: its tree is checked out already; the base is often cached (the last push's head).
                    with stages("web_after"):
                        after = self.web_side(head, entries)
                    with stages("web_before"):
                        before = self.web_side(base, entries)
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
                if before is not None and after is not None and before.is_file() and after.is_file():
                    row["changed"] = before.read_bytes() != after.read_bytes()
                scenes.append(row)
        receipt["scenes"] = scenes
        receipt["look"] = token
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
            mark = "" if s.get("changed", True) else " (no visible change)"
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
            tmp = self.receipts_path.with_suffix(".tmp")
            tmp.write_text(json.dumps(doc, indent=1) + "\n")
            os.replace(tmp, self.receipts_path)
        if self.publish_template and receipt.get("stages") is not None:
            argv = [a.replace("{file}", str(self.receipts_path)).replace("{host}", self.host)
                    for a in shlex.split(self.publish_template)]
            with _suppress():
                subprocess.run(argv, capture_output=True, timeout=SEND_SECONDS)


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
                                        "gallery": worker.gallery_up()})
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
            jobs.put((req, time.monotonic()))
            return self.reply(202, {"queued": jobs.qsize(), "head_sha": req["head_sha"]})

    return Handler


def tailnet_address() -> str | None:
    for tool in ("tailscale", "/Applications/Tailscale.app/Contents/MacOS/Tailscale"):
        with _suppress():
            out = subprocess.run([tool, "ip", "-4"], capture_output=True, text=True, timeout=10).stdout.split()
            if out:
                return out[0]
    return None


def command_serve(args) -> int:
    worker = Worker(Path(args.state), args.public, args.send, args.publish_receipts)
    bind = args.bind or tailnet_address() or "127.0.0.1"
    if not worker.public:
        worker.public = f"http://{bind}:{args.port}"
    if not args.no_warm:
        log(f"warming: {json.dumps(worker.warm())}")
    jobs: queue.Queue = queue.Queue()

    def drain() -> None:
        while True:
            req, received = jobs.get()
            receipt = worker.look(req, received)
            log(f"{req['head_sha'][:12]}: posted_at {receipt.get('posted_at')} push_to_post_s "
                f"{receipt.get('push_to_post_s')} stages {receipt.get('stages')} error {receipt.get('error')}")

    threading.Thread(target=drain, daemon=True).start()
    server = http.server.ThreadingHTTPServer((bind, args.port), make_handler(worker, jobs))
    log(f"serving on http://{bind}:{args.port} (state {worker.state})")
    try:
        server.serve_forever()
    finally:
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
        if not args.keep_gallery:
            worker.stop_gallery()
    print(json.dumps(receipt, indent=1))
    return 0 if receipt.get("posted_at") else 1


def command_warm(args) -> int:
    worker = Worker(Path(args.state), None, None, None)
    result = worker.warm(web=not args.no_web, swift=not args.no_swift)
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
    args = ap.parse_args(argv)
    return {"serve": command_serve, "once": command_once, "warm": command_warm, "submit": command_submit}[args.command](args)


if __name__ == "__main__":
    raise SystemExit(main())
