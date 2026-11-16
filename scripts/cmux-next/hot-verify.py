#!/usr/bin/env python3
"""Look at a cmux NEXT change in a running app first, with no build; test it after.

    hot-verify.py plan --source dir:PATH|pr:N|sha:SHA [--repo CMUX_CLONE] [--app APP | --base COMMIT] [--json]
    hot-verify.py look --source dir:PATH|pr:N|sha:SHA --app APP --out DIR [--repo CMUX_CLONE] [--side NAME]
                       [--kit DIR] [--state STEPS.json] [--no-video] [--watch]
    hot-verify.py stop --side NAME

Leo, 2026-11-15: "Just screenshot it, take a video, touch it, interact with it, click around with it, and then
push it through the various testing instead of the other way around." And: "I mean, the point is sometimes like
maybe the code doesn't even need to be compiled, right?"

`plan` says whether a change needs an app build, and if not, which live layers carry it. The change is HEAD of
the source (a checkout's working tree, a pull request's head fetched with git, or a commit) against the app it
would go into: APP's CMUXCommit, else --base, else (no app, or --app /nonexistent/hot-verify-no-app) the
source's merge base with origin/feat-cmux-next. The paths are sorted by hot-apply.py's own rules
(hot-apply.py _plan, which reads live_apply.py) on the change's own commits, from where it forked off the
app's commit:

  web    webviews/ changed and the change's web ABI (webviews/src/web-abi.json) is the app's
  rust   the cmux-tui tree build changes and none of it is Rust the app links (its FFI crates). A change
         that forked before the app's commit needs the app's cmux-tui tree to be the fork's: else the app
         has Rust the change lacks, and it needs a rebase or a build

Swift, resources, manifests, the web ABI file, and Rust the app links need a build (`needs_build: true`, with
`build` naming why and which paths). Docs, CI, tests and scripts have no layer: `layers: none`, no build.
The text form prints `layers: web,rust|none`, `needs_build: true|false`, `build: WHY: paths` and `note:` lines;
--json prints {layers, needs_build, build, notes, head, base, fork, marker_sha, source}. Exit 0 on a plan, 2 on
a usage or git error. A plan never runs the change's own code: only these scripts and git.

`look` plans, then puts the change into a copy of APP running beside everything else (side-instance.sh NAME,
default hot-verify, under $CMUX_SIDE_ROOT), and writes into --out:

  before/light.png, before/dark.png   the copy's main window before the change
  after/light.png, after/dark.png     the same window with the change in
  steps/NAME.png                      the click-through after the change: --state (cmuxterm-hq
                                      build-fleet/pr_capture/nightly_steps.py's steps file), else a default
                                      walk (Home, a New Tab, Settings)
  video.mp4                           the copy's window from the change going in to the last step, unless
                                      --no-video: with --kit, CuaDriver's recording of the display (its
                                      Screen Recording grant) cut to the window (ffmpeg, else AVFoundation);
                                      else media/record-window.swift
  steps.json, receipt.json

The web layer comes from the bundles CI published for the head (a pull request's own layer,
files.cmux.com/cmux-next-web/pr/N, else the head's web source key) installed as the copy's web overlay, else
from the head's webviews served live by a dev server (web-overlay.sh server --local), so later edits of a
dir: source hot-reload. The rust layer is hot-apply.py apply --branch --parts rust on the copy: the cmux CI
published for the head's cmux-tui tree, else (a dir: source with cmux-tui and cargo here) a local cargo
build. Light and dark are the copy's own terminal theme (settings.set appearance.theme), never the Mac's
appearance. With --kit (cmuxterm-hq build-fleet/pr_capture) its window shot and its steps runner are used;
without it the engine shoots with screencapture and runs the steps a release socket serves (action, rpc,
cmux, wait, shot, waitFor), naming the others as needing the kit.

receipt.json: {schema 1, marker, plan, app {commit, version}, steps, errors, phases {name: seconds},
edit_to_visible_s (the change handed to the copy until its first after shot), push_to_first_shot_s (the head
commit's time until that shot)}. The marker is the line cmuxterm-hq's hot-verify comment and NOW metric read:

    <!-- cmux-hot-verify sha=<40-hex head> app=<CMUXCommit> layers=<web,rust> source=<worktree|pr> -->

Exit 0 looked (or nothing in the app changes), 1 the look failed, 2 usage, 3 the change needs a build (no look).
The copy is stopped at the end; --watch leaves it and its dev server running (edits to a dir: source then show
live) until `hot-verify.py stop --side NAME`, which stops the copy and everything the look started.
"""
from __future__ import annotations

import argparse
import contextlib
import fcntl
import hashlib
import importlib.util
import json
import os
import plistlib
import re
import shlex
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
BASE_BRANCH = "feat-cmux-next"
NO_APP = "/nonexistent/hot-verify-no-app"
SHA = re.compile(r"[0-9a-f]{40}")
SHORT_SHA = re.compile(r"[0-9a-f]{7,40}")
MARKER = re.compile(r"<!-- cmux-hot-verify sha=([0-9a-f]{40}) app=(\S+) layers=([a-z,]+) source=(worktree|pr) -->")
LAYERS = ("web", "rust", "customize")
WEB_ABI = "webviews/src/web-abi.json"
ROUTE = "scripts/ci/cmux_next_route.py"
WEB_BASE = os.environ.get("CMUX_WEB_BUNDLES_BASE") or "https://files.cmux.com/cmux-next-web"
EXIT_LOOKED, EXIT_FAILED, EXIT_USAGE, EXIT_NEEDS_BUILD = 0, 1, 2, 3
DEFAULT_SIDE = "hot-verify"
SIDE_LABEL = "cmux hot-verify"
STATE_FILE = "hot-verify.json"
# hot-apply.py _plan's `left` keys this engine reads, and the build reasons it names for the others.
LEFT_WEB = "web (not published for a branch)"
LEFT_HELPERS = "bundled helpers (cmux-mobile-host, ...)"
REASONS = {"swift-live": "Swift", "rebuild": "Swift, resources or manifests", "unrelated": "unrelated history"}
# The files the rules read from a checkout (cmux_next_route.py's FFI and scheme inputs, the tree key script),
# when this engine is an export of scripts/cmux-next or the clone has no working tree: a sparse worktree of
# the clone at origin/feat-cmux-next, the same commit the engine comes from.
RULES_SPARSE = ["/scripts/ci/", "/scripts/cmux-next/", "/cmux-tui/Cargo.toml", "/cmux-tui/**/Cargo.toml",
                "/cmux-tui/**/build.rs", "/cmux-tui/rust-toolchain.toml", "/cmux.xcodeproj/project.pbxproj"]
RULES_KEEP = 2
# A head's webviews checkout for a dev server: everything but the large folders no bundle imports (as
# hot-apply.py's web key), then the inputs web-bundle-key.py names outside them.
WEB_SPARSE = ["/*", "!/cmux-next-ios/", "!/web/", "!/cmux-tui/crates/", "!/ghostty/", "!/ghostty-next/"]
# Bounds, in seconds.
GIT_SECONDS = 600
LAUNCH_SECONDS = 120
WINDOW_SECONDS = 60
STEP_SECONDS = 45
APPLY_SECONDS = 900
# The app repainting after a theme change or an overlay reload: a capture's own bounded delay, never a wait on
# a condition (the release socket says nothing about paint).
SETTLE_LAUNCH = 4.0
SETTLE_THEME = 1.5
SETTLE_WEB = 5.0
SETTLE_DEV_SERVER = 10.0
MAX_STEPS = 60
ENGINES = ("webkit", "chromium")
DEFAULT_ENGINE = "webkit"
MAX_WAIT = 30.0
STEP_KINDS = ("action", "rpc", "cmux", "wait", "shot", "waitFor", "chat", "move", "hover", "type", "key",
              "recording")
SHOT_NAME = re.compile(r"[a-z0-9][a-z0-9-]{0,47}")
THEMES = {"light": "Apple System Colors Light", "dark": "Apple System Colors"}
DEFAULT_WALK = [
    {"action": "newTab.default", "name": "New Tab"},
    {"wait": 2},
    {"shot": "new-tab"},
    {"action": "openSettings", "name": "Settings"},
    {"wait": 2},
    {"shot": "settings"},
]


class Usage(Exception):
    """A source, app or argument this engine cannot take (exit 2)."""


class LookError(RuntimeError):
    """A look that could not go on: the message says why."""


def log(message: str) -> None:
    print(f"hot-verify: {message}", file=sys.stderr, flush=True)


def git(repo: Path, *args: str, check: bool = True, env: dict | None = None, timeout: float = GIT_SECONDS) -> str:
    done = subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True, errors="replace",
                          env={**os.environ, "GIT_TERMINAL_PROMPT": "0", **(env or {})}, timeout=timeout)
    if check and done.returncode != 0:
        raise Usage(f"git {' '.join(args[:3])}: {done.stderr.strip()[-300:]}")
    return done.stdout.strip() if done.returncode == 0 else ""


def has_commit(repo: Path, sha: str) -> bool:
    return subprocess.run(["git", "-C", str(repo), "cat-file", "-e", f"{sha}^{{commit}}"], capture_output=True,
                          env={**os.environ, "GIT_NO_LAZY_FETCH": "1"}).returncode == 0


def cache_dir() -> Path:
    if os.environ.get("CMUX_HOT_VERIFY_CACHE"):
        return Path(os.environ["CMUX_HOT_VERIFY_CACHE"])
    if sys.platform == "darwin":
        return Path.home() / "Library/Caches/cmux-next/hot-verify"
    return Path(os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache") / "cmux-next/hot-verify"


_HOT = None


def hot():
    """hot-apply.py beside this file, loaded once: its plan rules, phases, app readers and keys."""
    global _HOT
    if _HOT is None:
        spec = importlib.util.spec_from_file_location("hot_apply", HERE / "hot-apply.py")
        module = importlib.util.module_from_spec(spec)
        sys.modules["hot_apply"] = module
        spec.loader.exec_module(module)
        _HOT = module
    return _HOT


# ---------------------------------------------------------------- the source


def base_tip(repo: Path) -> str:
    """origin/feat-cmux-next in REPO, fetched when the clone has none."""
    ref = f"refs/remotes/origin/{BASE_BRANCH}"
    tip = git(repo, "rev-parse", "--verify", "-q", f"{ref}^{{commit}}", check=False)
    if not SHA.fullmatch(tip):
        git(repo, "fetch", "-q", "--no-tags", "origin", f"+refs/heads/{BASE_BRANCH}:{ref}")
        tip = git(repo, "rev-parse", "--verify", f"{ref}^{{commit}}")
    return tip


def snapshot(top: Path) -> str:
    """A commit of TOP's working tree (tracked changes and new files, not ignored ones) on its HEAD, through a
    copy of its index, so a sparse checkout's absent files stay as they are. Nothing in TOP changes."""
    head = git(top, "rev-parse", "HEAD")
    index = Path(git(top, "rev-parse", "--path-format=absolute", "--git-path", "index"))
    with tempfile.TemporaryDirectory(prefix="hot-verify-index-") as scratch:
        copy = Path(scratch) / "index"
        if index.is_file():
            shutil.copyfile(index, copy)
        env = {"GIT_INDEX_FILE": str(copy)}
        if not index.is_file():
            git(top, "read-tree", "HEAD", env=env)
        git(top, "add", "-A", env=env)
        tree = git(top, "write-tree", env=env)
    if tree == git(top, "rev-parse", "HEAD^{tree}"):
        return head
    who = {"GIT_AUTHOR_NAME": "hot-verify", "GIT_AUTHOR_EMAIL": "hot-verify@localhost",
           "GIT_COMMITTER_NAME": "hot-verify", "GIT_COMMITTER_EMAIL": "hot-verify@localhost"}
    return git(top, "commit-tree", tree, "-p", head, "-m", "hot-verify: the working tree", env=who)


def same_store(a: Path, b: Path) -> bool:
    common = [Path(git(p, "rev-parse", "--path-format=absolute", "--git-common-dir")).resolve() for p in (a, b)]
    return common[0] == common[1]


def resolve_source(repo: Path, spec: str) -> dict:
    """SPEC's head commit in REPO: {kind, head, marker_source, tree (a dir: source's checkout), notes}."""
    kind, _, value = spec.partition(":")
    notes: list[str] = []
    if kind == "pr":
        if not value.isdigit() or int(value) <= 0:
            raise Usage(f"--source pr:N takes a pull request number, not {value!r}")
        ref = f"refs/hot-verify/pr-{int(value)}"
        git(repo, "fetch", "-q", "--no-tags", "origin", f"+refs/pull/{int(value)}/head:{ref}")
        return {"kind": "pr", "pr": int(value), "head": git(repo, "rev-parse", f"{ref}^{{commit}}"),
                "marker_source": "pr", "tree": None, "notes": notes}
    if kind == "sha":
        if not SHORT_SHA.fullmatch(value):
            raise Usage(f"--source sha:SHA takes a commit id, not {value!r}")
        if not has_commit(repo, value):
            if not SHA.fullmatch(value):
                raise Usage(f"{value} is not in {repo}: give the full 40-hex commit so it can be fetched")
            git(repo, "fetch", "-q", "--no-tags", "origin", value)
        return {"kind": "sha", "head": git(repo, "rev-parse", f"{value}^{{commit}}"), "marker_source": "pr",
                "tree": None, "notes": notes}
    if kind == "dir":
        top = Path(git(Path(value or "."), "rev-parse", "--show-toplevel"))
        head = snapshot(top)
        if head != git(top, "rev-parse", "HEAD"):
            notes.append(f"the working tree has changes: looked at as commit {head[:12]} on HEAD")
        if not same_store(top, repo):
            ref = "refs/hot-verify/worktree"
            git(top, "update-ref", ref, head)
            git(repo, "fetch", "-q", "--no-tags", str(top), f"+{ref}:{ref}")
        return {"kind": "dir", "head": head, "marker_source": "worktree", "tree": top, "notes": notes}
    raise Usage(f"--source takes dir:PATH, pr:N or sha:SHA, not {spec!r}")


# ---------------------------------------------------------------- the rules root


def needs_rules_root(repo: Path) -> bool:
    """The rules read scripts/ci from this engine's checkout and Cargo manifests from the clone's working tree:
    an exported engine (no scripts/ci) or a clone with no working tree has neither."""
    return not ((ROOT / ROUTE).is_file() and (repo / "cmux-tui/Cargo.toml").is_file())


def rules_root(repo: Path) -> Path:
    """A sparse worktree of REPO at origin/feat-cmux-next with RULES_SPARSE, made once per tip under the cache
    (the newest RULES_KEEP kept). It shares REPO's objects and refs, so git answers there as in REPO."""
    tip = base_tip(repo)
    cache = cache_dir() / "rules"
    cache.mkdir(parents=True, exist_ok=True)
    dest = cache / tip
    with open(cache / ".lock", "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if not (dest / ROUTE).is_file():
            git(repo, "worktree", "remove", "--force", str(dest), check=False)
            shutil.rmtree(dest, ignore_errors=True)
            git(repo, "worktree", "add", "-q", "--detach", "--no-checkout", str(dest), tip)
            git(dest, "sparse-checkout", "set", "--no-cone", *RULES_SPARSE)
            git(dest, "checkout", "-q", tip)
        os.utime(dest)
        kept = sorted((p for p in cache.iterdir() if SHA.fullmatch(p.name)), key=lambda p: p.stat().st_mtime,
                      reverse=True)
        for old in kept[RULES_KEEP:]:
            if old != dest:
                git(repo, "worktree", "remove", "--force", str(old), check=False)
                shutil.rmtree(old, ignore_errors=True)
    return dest


def rules_for(repo: Path) -> Path:
    """The checkout the rules read (REPO itself, or rules_root), with hot-apply.py pointed at its scripts."""
    h = hot()
    if not needs_rules_root(repo):
        return repo
    root = rules_root(repo)
    h.ROOT = root
    ci = str(root / "scripts/ci")
    if ci not in sys.path:
        sys.path.insert(0, ci)
    return root


# ---------------------------------------------------------------- plan


def app_info(app: Path | None) -> dict:
    """APP's Info.plist: {commit (CMUXCommit as stamped), version}; {} for no app."""
    if app is None:
        return {}
    try:
        with open(app / "Contents/Info.plist", "rb") as handle:
            info = plistlib.load(handle)
    except (OSError, ValueError, plistlib.InvalidFileException):
        return {}
    version = " ".join(str(info.get(k) or "") for k in ("CFBundleShortVersionString", "CFBundleVersion")).strip()
    return {"commit": str(info.get("CMUXCommit") or ""), "version": version}


def real_app(app: str | None) -> Path | None:
    if not app or app == NO_APP:
        return None
    path = Path(app)
    if not (path / "Contents/Info.plist").is_file():
        raise Usage(f"no app at {app} (--app {NO_APP} plans against the merge base)")
    return path


def plan(repo: Path, source: str, app: str | None = None, base: str | None = None) -> dict:
    """The plan of SOURCE against APP's commit, BASE, or the merge base with origin/feat-cmux-next."""
    h = hot()
    src = resolve_source(repo, source)
    head = src["head"]
    rules = rules_for(repo)
    the_app = real_app(app)
    if base:
        base = git(repo, "rev-parse", "--verify", f"{base}^{{commit}}")
    elif the_app is not None:
        base = h.app_commit(the_app, repo)
    else:
        base = git(repo, "merge-base", head, base_tip(repo))
    fork = git(repo, "merge-base", base, head, check=False)
    if not SHA.fullmatch(fork):
        raise Usage(f"{head[:12]} shares no history with {base[:12]}")
    # An app older than the change's own fork (a nightly lags feat-cmux-next): fork..head would count everything
    # merged since the nightly as the change, so a 4-file Rust PR "needed a build" for 33 Swift files that were
    # not its own. The change is what it adds to feat-cmux-next (own fork..head); the commits between the app and
    # that fork are noted, and the web ABI check still compares the head with the app.
    own = git(repo, "merge-base", head, base_tip(repo), check=False)
    if own == head and head != base and on_first_parent_line(repo, head, base):
        # HEAD is itself on feat-cmux-next (a PR's merge commit, looked at after it landed): its change is its own
        # first-parent diff, and everything between the app and that parent is lag, as for a PR branched later.
        # Without this, own == head made `behind` false and every commit merged since the nightly counted as the
        # change. A root commit keeps own == head.
        own = git(repo, "rev-parse", "--verify", "-q", f"{head}^1", check=False) or head
    # fork == base: the app's commit is an ancestor of the head; own != base: the change forked later.
    behind = (fork == base and SHA.fullmatch(own or "") is not None and own not in (base, head)
              and subprocess.run(["git", "-C", str(repo), "merge-base", "--is-ancestor", base, own],
                                 capture_output=True).returncode == 0)
    if behind:
        lag = git(repo, "rev-list", "--count", f"{base}..{own}", check=False) or "?"
        fork = own
    # hot-apply's own rules over the change's own commits (fork..head), as a branch: its web is not published
    # per merge, so it comes back under LEFT_WEB, and its FFI is never swapped.
    planned = h._plan(rules, Path(NO_APP), head, True, fork)
    out = {"source": src["marker_source"], "head": head, "marker_sha": head, "base": base, "fork": fork,
           "layers": [], "needs_build": False, "build": {}, "notes": src["notes"] + list(planned.get("notes") or [])}
    if src.get("pr"):
        out["pr"] = src["pr"]
    if behind:
        out["notes"].append(f"the app's commit {base[:12]} is {lag} commits behind the change's fork {fork[:12]} "
                            "on feat-cmux-next: those commits are not the change, and a look does not show them")
    left = dict(planned.get("left") or {})
    web = left.pop(LEFT_WEB, [])
    helpers = left.pop(LEFT_HELPERS, [])
    for kind, paths in left.items():
        out["build"][REASONS.get(kind, kind)] = list(paths)
    if web:
        want, have = h.abi_at(repo, head), (h.app_abi(the_app) if the_app is not None else h.abi_at(repo, base))
        if WEB_ABI in web:
            out["build"]["web ABI"] = [WEB_ABI]
        elif want != have:
            out["build"]["web ABI"] = [f"the change's web needs ABI {want}, the app has {have}"]
        else:
            out["layers"].append("web")
    if "rust" in planned.get("parts", []):
        if not behind and fork != base and h.tree_key(rules, fork) != h.tree_key(rules, base):
            out["build"]["Rust the app has and the change lacks"] = [
                f"the app's commit {base[:12]} has cmux-tui changes the change (branched at {fork[:12]}) lacks: "
                "rebase it onto the app's commit, or build it"]
        elif behind and (pinned := lag_pins_daemon(h, repo, base, fork)):
            # The head's daemon carries the lagging commits' FFI changes, which the app does not link.
            out["build"]["Rust the app links (FFI), in the commits the app lacks"] = pinned
        else:
            out["layers"].append("rust")
            out["tree_key"] = planned.get("tree_key")
            if not planned.get("published"):
                out["notes"].append("the head's cmux-tui tree is not published yet (CI publishes it after the "
                                    "push); a look waits for it or builds it locally")
    elif planned.get("tree_key") and planned.get("tree_key") == planned.get("base_tree_key"):
        out["notes"].append("Rust changed outside the cmux-tui tree build's inputs: no daemon to swap")
    if helpers:
        # hot-apply leaves these for a new app (`left`): the bundled helpers (the diff sidecar, transport, ...) keep
        # the app's build, so a look that swaps only the daemon would show the change without them.
        out["build"]["Rust only bundled helpers use"] = list(helpers)
    out["needs_build"] = bool(out["build"])
    return out


FFI_PIN_FILE = "Packages/macOS/CmuxNext/app-ffi-pin.json"


def on_first_parent_line(repo: Path, head: str, base: str) -> bool:
    """HEAD is one of feat-cmux-next's own first-parent commits after BASE (a landed PR's merge commit), not a commit
    of a branch a merge brought in as its second parent: for that one head^1..head is only its last commit, and the
    branch's earlier commits (its Swift too) would pass as lag."""
    line = git(repo, "rev-list", "--first-parent", f"^{base}", base_tip(repo), check=False)
    return head in line.split()


def lag_pins_daemon(h, repo: Path, base: str, fork: str) -> list[str]:
    """The Rust the app links through FFI that changed between the app's commit and the change's fork
    (hot-apply's pins_daemon over that range): a daemon built at the head speaks those changes and the app does
    not.

    None when both commits pin the same app FFI release (app-ffi-pin.json, the same blob): an app links the
    release its commit pins, not the FFI sources at its commit, so an app built at the fork would link the very
    library this app has, beside a daemon built from the fork's sources. A look then shows what a NIGHTLY at the
    fork plus the change would; 3 of the first 38 automatic looks (2026-11-16) were refused on FFI sources that
    the pin had not taken yet. With no pin file at either end, the sources decide, as before."""
    pins = [git(repo, "rev-parse", "--verify", "--quiet", f"{c}:{FFI_PIN_FILE}", check=False) for c in (base, fork)]
    if all(SHA.fullmatch(p or "") for p in pins) and pins[0] == pins[1]:
        return []
    files = h.live_apply.classify_range(str(repo), base, fork)["files"]
    # As pins_daemon: since #43797 classify puts cmux-tui's own C, Objective-C and Zig in "daemon" too.
    return h.linked_rust(repo, sorted(set(files.get("daemon", []))))


def plan_text(planned: dict) -> str:
    lines = [f"layers: {','.join(planned['layers']) or 'none'}",
             f"needs_build: {'true' if planned['needs_build'] else 'false'}"]
    for why, paths in planned["build"].items():
        lines.append(f"build: {why}: {', '.join(paths[:5])}{' ...' if len(paths) > 5 else ''}")
    lines += [f"note: {note}" for note in planned["notes"]]
    lines += [f"head: {planned['head']}", f"base: {planned['base']}"]
    return "\n".join(lines) + "\n"


def marker(head: str, app: str, layers: list[str], source: str) -> str:
    """The look's marker line (cmuxterm-hq build-fleet/hot-verify MARKER): checked before it is written."""
    app = re.sub(r"\s+", "-", app.strip()) or "unknown"
    line = f"<!-- cmux-hot-verify sha={head} app={app} layers={','.join(layers)} source={source} -->"
    if not MARKER.fullmatch(line):
        raise ValueError(f"not a hot-verify marker: {line}")
    return line


def command_plan(args) -> int:
    planned = plan(Path(args.repo), args.source, args.app, args.base)
    print(json.dumps(planned, indent=2) if args.json else plan_text(planned), end="\n" if args.json else "")
    return EXIT_LOOKED


# ---------------------------------------------------------------- the side instance


class Side:
    """side-instance.sh NAME: a copy of an app beside everything else, and what the look started for it."""

    def __init__(self, name: str):
        if not re.fullmatch(r"[a-z0-9][a-z0-9-]{0,39}", name):
            raise Usage("--side takes lower case letters, digits and dashes")
        self.name = name
        self.script = HERE / "side-instance.sh"

    def run(self, *args: str, timeout: float = 300) -> str:
        done = subprocess.run([str(self.script), args[0], self.name, *args[1:]], capture_output=True, text=True,
                              errors="replace", timeout=timeout)
        if done.returncode != 0:
            raise LookError(f"side-instance.sh {args[0]} {self.name}: {(done.stderr or done.stdout).strip()[-300:]}")
        return done.stdout.strip()

    def exists(self) -> bool:
        return subprocess.run([str(self.script), "path", self.name], capture_output=True).returncode == 0

    def app(self) -> Path:
        return Path(self.run("path"))

    def socket(self) -> str | None:
        """The control socket side-instance.sh named for the copy (CMUX_NEXT_SOCKET_PATH), or None for a copy
        made before it named one."""
        try:
            return self.run("socket", timeout=30) or None
        except LookError:
            return None

    def dir(self) -> Path:
        return self.app().parent

    def env(self) -> dict:
        """The copy's web overlay environment (side-instance.sh env)."""
        found = {}
        for word in shlex.split(self.run("env")):
            key, eq, value = word.partition("=")
            if eq and re.fullmatch(r"[A-Z_]+", key):
                found[key] = value
        return found

    def state(self) -> dict:
        try:
            data = json.loads((self.dir() / STATE_FILE).read_text())
        except (OSError, ValueError, LookError):
            return {}
        return data if isinstance(data, dict) else {}

    def remember(self, **fields) -> None:
        data = {**self.state(), **fields}
        (self.dir() / STATE_FILE).write_text(json.dumps(data, indent=2) + "\n")

    def stop(self) -> list[str]:
        """Stops the copy and what the look started for it (its dev server, the head's checkout, the recorder);
        the errors, if any."""
        errors = []
        if not self.exists():
            return errors
        state = self.state()
        if state.get("dev_server"):
            with contextlib.suppress(LookError, OSError, subprocess.SubprocessError):
                env = {**os.environ, **self.env()}
                subprocess.run([str(HERE / "web-overlay.sh"), "server", "off"], env=env, capture_output=True,
                               timeout=60)
        recorder = state.get("recorder_pid")
        # Only the recorder this look started, by its pid and name: record-window, or the kit's own
        # `cua-driver mcp` session (never CuaDriver's daemon, whose pid is never recorded).
        if isinstance(recorder, int) and process_runs(recorder, state.get("recorder_name") or "record-window"):
            with contextlib.suppress(OSError):
                os.kill(recorder, 15)
        try:
            self.run("stop", timeout=120)
        except (LookError, subprocess.SubprocessError) as error:
            errors.append(str(error))
        tree, repo = state.get("worktree"), state.get("repo")
        if tree and repo:
            git(Path(repo), "worktree", "remove", "--force", tree, check=False)
        with contextlib.suppress(LookError):
            self.remember(dev_server=False, recorder_pid=None, recorder_name=None, worktree=None)
        return errors


def process_runs(pid: int, name: str) -> bool:
    """PID is still a process whose command is NAME (a recorded pid never names another program)."""
    done = subprocess.run(["ps", "-o", "comm=", "-p", str(pid)], capture_output=True, text=True)
    return Path(done.stdout.strip()).name == name


def control_socket(pid: int, named: str | None = None) -> str | None:
    """The copy's control socket: the one side-instance.sh named (NAMED) when it answers system.identify with
    PID; else, for a copy made before it named one, each cmux socket is asked and the one that answers with PID
    is it (scripts/measure/hot-apply-nightly.py)."""
    if named and os.path.exists(named):
        return named if rpc(named, "system.identify", timeout=5).get("pid") == pid else None
    # No socket at the named path: an app older than CMUX_NEXT_SOCKET_PATH puts it by its key hash, so scan.
    import glob
    import pwd
    homes = dict.fromkeys([os.path.expanduser("~"), pwd.getpwuid(os.getuid()).pw_dir])
    found = set(glob.glob("/tmp/cmux-*.sock"))
    for home in homes:
        found.update(glob.glob(os.path.join(home, ".local/state/cmux/*.sock")))
    for path in sorted(found):
        reply = rpc(path, "system.identify", timeout=5)
        if reply.get("pid") == pid:
            return path
    return None


def rpc(path: str, method: str, params: dict | None = None, timeout: float = STEP_SECONDS) -> dict:
    """One request on the app's control socket (newline-delimited JSON); {"error": ...} when it fails."""
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
            conn.settimeout(timeout)
            conn.connect(path)
            conn.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
            buf = b""
            while b"\n" not in buf:
                chunk = conn.recv(1 << 20)
                if not chunk:
                    break
                buf += chunk
        reply = json.loads(buf.split(b"\n", 1)[0])
    except (OSError, ValueError) as error:
        return {"error": str(error)}
    if not isinstance(reply, dict):
        return {"error": "not a JSON object"}
    if reply.get("ok") is False or reply.get("error"):
        return {"error": reply.get("error")}
    result = reply.get("result")
    return result if isinstance(result, dict) else {"value": result}


def until(what: str, seconds: float, probe):
    """PROBE's first truthy answer within SECONDS (a bounded wait on a local process, every 0.25 s)."""
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        found = probe()
        if found:
            return found
        time.sleep(0.25)
    raise LookError(f"{what}: nothing within {seconds:g} s")


# ---------------------------------------------------------------- shots and video


def window_id(pid: int) -> int | None:
    """PID's largest on-screen layer-0 window, from the window list (ids and bounds need no grant)."""
    script = ('ObjC.import("CoreGraphics");'
              'var list = ObjC.deepUnwrap(ObjC.castRefToObject($.CGWindowListCopyWindowInfo('
              '$.kCGWindowListOptionOnScreenOnly | $.kCGWindowListExcludeDesktopElements, 0))) || [];'
              f'var mine = list.filter(function (w) {{ return w.kCGWindowOwnerPID === {int(pid)}'
              ' && w.kCGWindowLayer === 0 && w.kCGWindowBounds.Width >= 100 && w.kCGWindowBounds.Height >= 60'
              ' && Math.abs(w.kCGWindowBounds.X) < 20000 && Math.abs(w.kCGWindowBounds.Y) < 20000; });'
              'mine.sort(function (a, b) { return b.kCGWindowBounds.Width * b.kCGWindowBounds.Height'
              ' - a.kCGWindowBounds.Width * a.kCGWindowBounds.Height; });'
              'mine.length ? String(mine[0].kCGWindowNumber) : ""')
    try:
        done = subprocess.run(["osascript", "-l", "JavaScript", "-e", script], capture_output=True, text=True,
                              timeout=15)
    except (OSError, subprocess.SubprocessError):
        return None
    text = done.stdout.strip()
    return int(text) if text.isdigit() else None


class Shooter:
    """The copy's main window into a PNG: the kit's window shot (screencapture, else CuaDriver) when there is a
    kit, else screencapture of the window by its id. Never the display."""

    def __init__(self, kit_steps=None):
        self.kit_steps = kit_steps

    def __call__(self, pid: int, path: Path) -> str:
        path.parent.mkdir(parents=True, exist_ok=True)
        if self.kit_steps is not None:
            return self.kit_steps.window_shot([pid], path)
        wid = window_id(pid)
        if wid is None:
            raise LookError("the copy has no on-screen window")
        done = subprocess.run(["screencapture", "-x", "-o", f"-l{wid}", str(path)], capture_output=True, text=True,
                              timeout=30)
        if done.returncode != 0 or not path.is_file() or path.stat().st_size == 0:
            raise LookError(f"screencapture -l{wid}: {(done.stderr or done.stdout).strip()[-200:]}")
        return "screencapture"


# The clip name the look's own recording takes in the kit's Recorder: an underscore, which a steps file's clip name
# (SHOT_NAME) never has, so it never meets a clip the steps record.
LOOK_CLIP = "hot_verify_look"
# The most a look's video.mp4 may be: a fleet look's out.tar keeps a file of at most 32 MiB (cmuxterm-hq pr-capture
# RESULT_MAX_BYTES), so a bigger video is shrunk (fit_video) rather than dropped on the way back.
LOOK_VIDEO_MAX_BYTES = 30 << 20
# The most the kit's Recorder may hand over before the cut and the fit: the display for a look's whole length.
RAW_VIDEO_MAX_BYTES = 2 << 30


class Video:
    """The copy on video from the change going in to the last step, as video.mp4.

    With the kit (a fleet display worker) CuaDriver records it: the kit's Recorder (nightly_steps.Recorder, one
    `cua-driver mcp` session's start_recording) records the main display under CuaDriver's own Screen Recording
    grant, cut to the copy's window (ffmpeg, else media/crop-video.swift). media/record-window.swift cannot record
    there: it is a new ad-hoc binary per source digest, started under the root worker daemon (launchctl asuser), and TCC
    asks for the grant of a process that has none and cannot be given one (a PPPC payload never allows
    ScreenCapture). Every look on a fleet worker on 2026-11-15/16 said "no Screen Recording grant" while CuaDriver
    held the grant on the same minis. Without a kit (a person's Mac, whose terminal holds the grant),
    media/record-window.swift records the window alone (ScreenCaptureKit), remuxed to video.mp4."""

    def __init__(self, out: Path, kit=None):
        self.out = out
        self.mov = out / ".video.mov"
        self.process = None
        self.kit = kit if kit is not None and hasattr(kit, "Recorder") else None
        self.recorder = self.kit.Recorder() if self.kit is not None else None
        self.pid = None
        self.facts = {"by": "cua-driver" if self.recorder is not None else "record-window"}

    @property
    def name(self) -> str:
        """The recorder's process name (side state's recorder_name: a stop kills that pid only by this name)."""
        return self.facts["by"]

    def binary(self) -> Path:
        return swift_tool("record-window", "-parse-as-library")

    def start(self, pid: int) -> int:
        self.pid = pid
        if self.recorder is not None:
            try:
                self.recorder.start(self.out, LOOK_CLIP)
            except (OSError, ValueError, RuntimeError) as error:
                raise LookError(f"CuaDriver's recording did not start: {str(error)[:300]}") from error
            return self.recorder.process.pid
        self.mov.unlink(missing_ok=True)
        self.process = subprocess.Popen([str(self.binary()), str(pid), str(self.mov)], stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        import selectors
        with selectors.DefaultSelector() as ready:
            ready.register(self.process.stdout, selectors.EVENT_READ)
            if ready.select(timeout=30) and self.process.stdout.readline().strip() == "READY":
                return self.process.pid
        said = self.stop_process()
        raise LookError(f"the window recording did not start: {said}")

    @property
    def running(self) -> bool:
        return self.process is not None or (self.recorder is not None and self.recorder.running)

    def abandon(self) -> None:
        """End a recording a failed look left running, keeping nothing."""
        if self.recorder is not None and self.recorder.running:
            self.recorder.close()
        self.stop_process()

    def stop_process(self) -> str:
        process, self.process = self.process, None
        if process is None:
            return ""
        try:
            _, err = process.communicate(input="\n", timeout=30)
        except (OSError, subprocess.TimeoutExpired):
            process.kill()
            _, err = process.communicate()
        return (err or "").strip()[-300:]

    def stop(self) -> Path:
        if self.recorder is not None:
            return self.stop_cua()
        said = self.stop_process()
        if not self.mov.is_file() or self.mov.stat().st_size == 0:
            raise LookError(f"the window recording wrote nothing: {said}")
        mp4 = self.out / "video.mp4"
        ffmpeg = shutil.which("ffmpeg")
        tries = []
        if ffmpeg:
            tries.append([ffmpeg, "-y", "-v", "error", "-i", str(self.mov), "-c", "copy", "-movflags", "+faststart",
                          str(mp4)])
        if shutil.which("avconvert"):
            tries.append(["avconvert", "--source", str(self.mov), "--output", str(mp4), "--preset",
                          "PresetPassthrough", "--replace"])
        for argv in tries:
            done = subprocess.run(argv, capture_output=True, text=True, timeout=300)
            if done.returncode == 0 and mp4.is_file() and mp4.stat().st_size > 0:
                self.mov.unlink(missing_ok=True)
                self.facts["window"] = True
                return mp4
        raise LookError("no ffmpeg or avconvert here turned the recording into video.mp4")

    def stop_cua(self) -> Path:
        frame = window_frame(self.pid) if self.pid is not None else None
        # The kit's clip cap (MAX_CLIP_BYTES) is sized for a steps clip, and its stop deletes a clip over it. A look
        # records the whole display from the change going in, often for minutes: its cap is lifted for this stop,
        # and the window cut, then LOOK_VIDEO_MAX_BYTES, bound what comes back.
        kit = self.kit
        capped = getattr(kit, "MAX_CLIP_BYTES", None)
        try:
            if capped is not None:
                kit.MAX_CLIP_BYTES = RAW_VIDEO_MAX_BYTES
            made = self.recorder.stop(self.out)
        except (OSError, RuntimeError) as error:
            raise LookError(f"CuaDriver's recording: {str(error)[:300]}") from error
        finally:
            if capped is not None:
                kit.MAX_CLIP_BYTES = capped
        clip = self.out / made["clip"]
        mp4 = self.out / "video.mp4"
        try:
            os.replace(clip, mp4)
            with contextlib.suppress(OSError):
                clip.parent.rmdir()  # clips/ only when the steps recorded none of their own
            why = cut_to_window(mp4, frame, main_display_points())
            self.facts["window"] = why is None
            if why is not None:
                self.facts["display"] = why
            fit_video(mp4)
        except OSError as error:
            raise LookError(f"the recording did not become video.mp4: {error}") from error
        return mp4


def window_frame(pid: int) -> dict | None:
    """PID's largest on-screen layer-0 window's bounds in points ({X, Y, Width, Height}), or None."""
    script = ('ObjC.import("CoreGraphics");'
              'var list = ObjC.deepUnwrap(ObjC.castRefToObject($.CGWindowListCopyWindowInfo('
              '$.kCGWindowListOptionOnScreenOnly | $.kCGWindowListExcludeDesktopElements, 0))) || [];'
              f'var mine = list.filter(function (w) {{ return w.kCGWindowOwnerPID === {int(pid)}'
              ' && w.kCGWindowLayer === 0 && w.kCGWindowBounds.Width >= 100 && w.kCGWindowBounds.Height >= 60; });'
              'mine.sort(function (a, b) { return b.kCGWindowBounds.Width * b.kCGWindowBounds.Height'
              ' - a.kCGWindowBounds.Width * a.kCGWindowBounds.Height; });'
              'mine.length ? JSON.stringify(mine[0].kCGWindowBounds) : ""')
    try:
        done = subprocess.run(["osascript", "-l", "JavaScript", "-e", script], capture_output=True, text=True,
                              timeout=15)
        frame = json.loads(done.stdout.strip() or "null")
    except (OSError, subprocess.SubprocessError, ValueError):
        return None
    keys = ("X", "Y", "Width", "Height")
    if not isinstance(frame, dict) or not all(isinstance(frame.get(k), (int, float)) for k in keys):
        return None
    return {k: float(frame[k]) for k in keys}


def main_display_points() -> tuple[float, float] | None:
    """The main display's size in points (CGDisplayBounds, no grant), or None off macOS."""
    import ctypes
    import ctypes.util

    class Rect(ctypes.Structure):
        _fields_ = [("x", ctypes.c_double), ("y", ctypes.c_double), ("w", ctypes.c_double), ("h", ctypes.c_double)]

    found = ctypes.util.find_library("CoreGraphics")
    if not found:
        return None
    try:
        cg = ctypes.CDLL(found)
        cg.CGMainDisplayID.restype = ctypes.c_uint32
        cg.CGDisplayBounds.argtypes = [ctypes.c_uint32]
        cg.CGDisplayBounds.restype = Rect
        rect = cg.CGDisplayBounds(cg.CGMainDisplayID())
    except (OSError, AttributeError):
        return None
    return (rect.w, rect.h) if rect.w > 0 and rect.h > 0 else None


def swift_tool(name: str, *flags: str) -> Path:
    """media/NAME.swift compiled once per source digest into the cache (a LookError when it does not compile)."""
    source = HERE / f"media/{name}.swift"
    digest = hashlib.sha256(source.read_bytes()).hexdigest()[:16]
    binary = cache_dir() / f"{name}-{digest}"
    if not binary.is_file():
        binary.parent.mkdir(parents=True, exist_ok=True)
        part = binary.with_name(f".{binary.name}.{os.getpid()}")
        done = subprocess.run(["xcrun", "swiftc", "-O", *flags, str(source), "-o", str(part)],
                              capture_output=True, text=True, timeout=300)
        if done.returncode != 0:
            part.unlink(missing_ok=True)
            raise LookError(f"{name} did not compile: {done.stderr.strip()[-300:]}")
        os.replace(part, binary)
    return binary


def window_box(frame: dict | None, display: tuple[float, float] | None) -> tuple[float, float, float, float] | None:
    """FRAME (points) on a main-display video of DISPLAY points as fractions of the video (x, y, width, height from
    the top left), so no probe of its pixels is needed; None when the window is not wholly on the main display."""
    if frame is None or display is None:
        return None
    dw, dh = display
    x, y, w, h = frame["X"], frame["Y"], frame["Width"], frame["Height"]
    if x < 0 or y < 0 or w <= 0 or h <= 0 or x + w > dw + 0.5 or y + h > dh + 0.5:
        return None
    fx, fy = round(x / dw, 6), round(y / dh, 6)
    # A window flush with the right or bottom edge stays inside the video after rounding.
    return fx, fy, round(min(w / dw, 1.0 - fx), 6), round(min(h / dh, 1.0 - fy), 6)


def window_crop(frame: dict | None, display: tuple[float, float] | None) -> str | None:
    """ffmpeg's crop filter for window_box, in the video's own pixels (iw, ih), even sizes for H.264."""
    box = window_box(frame, display)
    if box is None:
        return None
    fx, fy, fw, fh = box
    return (f"crop=trunc(iw*{fw}/2)*2:trunc(ih*{fh}/2)*2:trunc(iw*{fx}/2)*2:trunc(ih*{fy}/2)*2")


def crop_video(mp4: Path, box: tuple[float, float, float, float], scale: float, dest: Path) -> str | None:
    """MP4's BOX (window_box's fractions) at SCALE into DEST through media/crop-video.swift (AVFoundation, on every
    Mac: no display worker has ffmpeg). None when DEST was written; else why not."""
    try:
        tool = swift_tool("crop-video")
        done = subprocess.run([str(tool), str(mp4), str(dest), *(f"{v:.6f}" for v in box), f"{scale:g}"],
                              capture_output=True, text=True, timeout=660)
    except LookError as error:
        return str(error)
    except (OSError, subprocess.SubprocessError) as error:
        return f"crop-video: {error}"
    if done.returncode == 0 and dest.is_file() and dest.stat().st_size > 0:
        return None
    dest.unlink(missing_ok=True)
    return (done.stderr or done.stdout).strip()[-300:] or f"crop-video exited {done.returncode}"


def cut_to_window(mp4: Path, frame: dict | None, display: tuple[float, float] | None) -> str | None:
    """MP4 (the main display) cut to the copy's window in place: ffmpeg when it is here, else AVFoundation
    (crop_video). The rest of the display shows what else runs there (another step's system dialogs), which the
    privacy check withholds the video for. None when cut; else why it stays the display."""
    box = window_box(frame, display)
    if box is None:
        return "the copy's window was not wholly on the main display"
    cut = mp4.with_name(".video-window.mp4")
    ffmpeg = shutil.which("ffmpeg")
    for codec in (["-c:v", "libx264", "-preset", "veryfast", "-crf", "23"], ["-c:v", "h264_videotoolbox", "-b:v", "6M"]) \
            if ffmpeg else ():
        try:
            done = subprocess.run([ffmpeg, "-y", "-v", "error", "-i", str(mp4), "-vf", window_crop(frame, display),
                                   *codec, "-an", "-movflags", "+faststart", str(cut)], capture_output=True, text=True,
                                  timeout=300)
        except (OSError, subprocess.SubprocessError):
            continue
        if done.returncode == 0 and cut.is_file() and cut.stat().st_size > 0:
            os.replace(cut, mp4)
            return None
    why = crop_video(mp4, box, 1.0, cut)
    if why is None:
        os.replace(cut, mp4)
        return None
    cut.unlink(missing_ok=True)
    return f"{'ffmpeg and ' if ffmpeg else ''}AVFoundation could not cut the window out: {why}"


def fit_video(mp4: Path, most: int = LOOK_VIDEO_MAX_BYTES) -> None:
    """MP4 shrunk in place until it is at most MOST bytes (half the size, then a quarter, each at a lower quality);
    a video that still does not fit (ffmpeg, else media/crop-video.swift) is removed with a LookError naming its
    size."""
    size = mp4.stat().st_size
    if size <= most:
        return
    ffmpeg = shutil.which("ffmpeg")
    small = mp4.with_name(".video-small.mp4")
    for scale, crf in ((2, 28), (4, 32)):
        if ffmpeg:
            try:
                done = subprocess.run([ffmpeg, "-y", "-v", "error", "-i", str(mp4), "-vf",
                                       f"scale=trunc(iw/{scale * 2})*2:trunc(ih/{scale * 2})*2", "-c:v", "libx264",
                                       "-preset", "veryfast", "-crf", str(crf), "-an", "-movflags", "+faststart",
                                       str(small)], capture_output=True, text=True, timeout=600)
                made = done.returncode == 0
            except (OSError, subprocess.SubprocessError):
                made = False
        else:
            why = crop_video(mp4, (0.0, 0.0, 1.0, 1.0), 1 / scale, small)
            if why is not None and "did not compile" in why:
                break  # the next pass would only wait on the same compile again
            made = why is None
        if made and small.is_file() and 0 < small.stat().st_size <= most:
            os.replace(small, mp4)
            return
    small.unlink(missing_ok=True)
    mp4.unlink(missing_ok=True)
    raise LookError(f"the video was {size >> 20} MiB, over the {most >> 20} MiB a look brings back, and did not "
                    f"shrink to fit ({'ffmpeg' if ffmpeg else 'AVFoundation'})")


# ---------------------------------------------------------------- the steps


def load_steps(path: str | None, kit) -> list:
    """The click-through: --state's steps (checked by the kit's validator when there is a kit), else the walk."""
    if not path:
        return [dict(step) for step in DEFAULT_WALK]
    data = json.loads(Path(path).read_text())
    if kit is not None:
        return kit.validate(data)
    steps = data.get("steps") if isinstance(data, dict) else None
    if not isinstance(steps, list) or not 0 < len(steps) <= MAX_STEPS:
        raise Usage(f"--state {path}: a steps file is {{\"steps\": [...]}} with 1 to {MAX_STEPS} steps")
    for index, step in enumerate(steps):
        kinds = [k for k in STEP_KINDS if isinstance(step, dict) and k in step]
        if len(kinds) != 1:
            raise Usage(f"--state {path}: step {index} needs exactly one of {', '.join(STEP_KINDS)}")
        if kinds[0] == "shot" and not SHOT_NAME.fullmatch(str(step["shot"])):
            raise Usage(f"--state {path}: step {index}'s shot name must match {SHOT_NAME.pattern}")
    return steps


def steps_engine(path: str | None) -> str:
    """The copy's browser.defaultEngine: the steps file's "engine", else webkit. The pr_capture kit's stopgap
    (nightly_steps.py CHROMIUM_UNCAPTURABLE): since cmux#34904 a Chromium-default NEXT nightly turns uncapturable
    10-25 s after launch (`screencapture -l`: "could not create image from window"), so every shot fails."""
    if not path:
        return DEFAULT_ENGINE
    data = json.loads(Path(path).read_text())
    engine = data.get("engine", DEFAULT_ENGINE) if isinstance(data, dict) else DEFAULT_ENGINE
    if engine not in ENGINES:
        raise Usage(f"--state {path}: a steps file's engine is one of {', '.join(ENGINES)}")
    return engine


def set_browser_engine(config: Path, engine: str) -> None:
    """Set browser.defaultEngine in the copy's own settings file (CMUX_NEXT_CONFIG_FILE), keeping the rest. A file
    this cannot read as JSON is left alone and the look stops: overwriting it would drop the copy's settings."""
    data = {}
    if config.exists():
        try:
            data = json.loads(config.read_text())
        except ValueError as error:
            raise LookError(f"the copy's settings file {config} is not plain JSON ({error}); "
                            "not overwriting it to set browser.defaultEngine") from error
        if not isinstance(data, dict):
            raise LookError(f"the copy's settings file {config} is not a JSON object")
    browser = data.get("browser") if isinstance(data.get("browser"), dict) else {}
    data["browser"] = {**browser, "defaultEngine": engine}
    config.parent.mkdir(parents=True, exist_ok=True)
    config.write_text(json.dumps(data, indent=2) + "\n")


def selected_kinds(sock: str) -> list[str]:
    """The kind of each pane's selected tab in the workspaces a visible window shows (snapshot.get)."""
    topology = rpc(sock, "snapshot.get", timeout=10).get("topology") or {}
    shown = {w.get("workspace") for w in topology.get("windows") or [] if isinstance(w, dict) and w.get("visible")}
    kinds = []
    for workspace in topology.get("workspaces") or []:
        if not isinstance(workspace, dict) or workspace.get("id") not in shown:
            continue
        for screen in workspace.get("screens") or []:
            for pane in (screen or {}).get("panes") or []:
                for tab in (pane or {}).get("tabs") or []:
                    if isinstance(tab, dict) and tab.get("id") == (pane or {}).get("selected_tab"):
                        kinds.append(str(tab.get("kind")))
    return kinds


def run_steps(steps: list, pid: int, sock: str, app: Path, out: Path, shoot: Shooter) -> list[dict]:
    """STEPS on the copy, each recorded ({index, kind, name, ok, ms, shot?, answer?}); a failing step is
    recorded and the next one runs (later shots still show what is there)."""
    results = []
    cli = app / "Contents/Resources/bin/cmux"
    for index, step in enumerate(steps):
        kind = next(k for k in STEP_KINDS if k in step)
        entry = {"index": index, "kind": kind, "name": step.get("name") or str(step[kind])[:80]}
        started = time.monotonic()
        answer, ok = None, True
        try:
            if kind == "action":
                params = {"action": step["action"], "focus": True, **({"args": step["args"]} if step.get("args") else {})}
                answer = rpc(sock, "action.run", params)
                ok = "error" not in answer
            elif kind == "rpc":
                answer = rpc(sock, step["rpc"], step.get("params") or {})
                ok = "error" not in answer
            elif kind == "cmux":
                done = subprocess.run([str(cli), "--socket", sock, *map(str, step["cmux"])], capture_output=True,
                                      text=True, timeout=STEP_SECONDS)
                ok, answer = done.returncode == 0, (done.stdout or done.stderr)[-2000:]
            elif kind == "wait":
                time.sleep(min(float(step["wait"]), MAX_WAIT))
            elif kind == "shot":
                path = out / "steps" / f"{step['shot']}.png"
                entry["how"] = shoot(pid, path)
                entry["shot"] = f"steps/{path.name}"
            elif kind == "waitFor":
                want = step["waitFor"]
                limit = min(float(want.get("timeout", 20)), MAX_WAIT)
                until(f"a selected {want.get('selectedTabKind')} tab", limit,
                      lambda: want.get("selectedTabKind") in selected_kinds(sock))
            else:
                ok, answer = False, {"error": f"a {kind} step needs the capture kit (--kit)"}
        except (OSError, ValueError, KeyError, LookError, subprocess.SubprocessError) as error:
            ok, answer = False, {"error": str(error)[:500]}
        entry["ok"] = ok
        entry["ms"] = round((time.monotonic() - started) * 1000)
        if answer is not None and (step.get("record") or not ok):
            entry["answer"] = json.dumps(answer, default=str)[:4000]
        results.append(entry)
    return results


def run_kit_steps(kit, steps: list, pid: int, sock: str, app: Path, out: Path) -> list[dict]:
    """STEPS through the kit's runner (nightly_steps.Steps: pointer, keyboard, chat and recording steps too);
    its shots/ become steps/."""

    class Process:
        def __init__(self, pid: int):
            self.pid = pid

        def poll(self):
            return None if process_runs_any(self.pid) else 0

    runner = kit.Steps(steps, out, "/nonexistent/ocr", str(Path(kit.__file__).with_name("private-terms.json")))
    runner(Process(pid), sock, dict(os.environ), app, out, {"rendered_at": 0})
    results = json.loads((out / kit.RESULT).read_text()).get("steps") or []
    shots = out / "shots"
    if shots.is_dir():
        (out / "steps").mkdir(exist_ok=True)
        for png in shots.glob("*.png"):
            os.replace(png, out / "steps" / png.name)
        shutil.rmtree(shots, ignore_errors=True)
    for entry in results:
        if str(entry.get("shot", "")).startswith("shots/"):
            entry["shot"] = "steps/" + entry["shot"][len("shots/"):]
    return results


def process_runs_any(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def load_kit(kit: str | None):
    if not kit:
        return None
    path = Path(kit) / "nightly_steps.py"
    if not path.is_file():
        raise Usage(f"--kit {kit} has no nightly_steps.py (cmuxterm-hq build-fleet/pr_capture)")
    spec = importlib.util.spec_from_file_location("pr_capture_nightly_steps", path)
    module = importlib.util.module_from_spec(spec)
    sys.modules["pr_capture_nightly_steps"] = module
    spec.loader.exec_module(module)
    return module


# ---------------------------------------------------------------- the layers


def free_port() -> int:
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def fetch_json(url: str) -> dict | None:
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "cmux-hot-verify"}),
                                    timeout=60) as answer:
            data = json.loads(answer.read())
    except (urllib.error.URLError, OSError, ValueError):
        return None
    return data if isinstance(data, dict) else None


def published_web_key(repo: Path, planned: dict) -> str | None:
    """The web bundles CI published for exactly the head: a pull request's own layer (its pointer names this
    head), else the head's web source key when that key is published. None when neither is."""
    head = planned["head"]
    if planned.get("pr"):
        pointer = fetch_json(f"{WEB_BASE}/pr/{planned['pr']}/latest.json")
        if pointer and pointer.get("head") == head and re.fullmatch(r"[0-9a-f]{64}", str(pointer.get("key"))):
            return pointer["key"]
    try:
        key = hot().web_key(repo, head)
    except (RuntimeError, OSError, subprocess.SubprocessError) as error:
        log(f"no web source key for {head[:12]}: {error}")
        return None
    return key if fetch_json(f"{WEB_BASE}/{key}/manifest.json") else None


def web_checkout(repo: Path, head: str, scratch: Path) -> Path:
    """A sparse checkout of HEAD with its webviews and every input its bundles import."""
    tree = scratch / "web-tree"
    git(repo, "worktree", "add", "-q", "--detach", "--no-checkout", str(tree), head)
    git(tree, "sparse-checkout", "set", "--no-cone", *WEB_SPARSE)
    git(tree, "checkout", "-q", head)
    named = subprocess.run([sys.executable, str(tree / "scripts/cmux-next/web-bundle-key.py"), str(tree), "--inputs"],
                           capture_output=True, text=True, timeout=120).stdout.split()
    extra = [f"/{p.rstrip('/')}" for p in named if not p.startswith(":")]
    if extra:
        git(tree, "sparse-checkout", "set", "--no-cone", *WEB_SPARSE, *extra)
    return tree


def apply_web(repo: Path, planned: dict, src_tree: Path | None, side: Side, scratch: Path) -> dict:
    """The head's web into the copy: published bundles as its overlay, else a dev server of the head."""
    env = {**os.environ, **side.env()}
    head = planned["head"]
    key = None if src_tree is not None else published_web_key(repo, planned)
    if key:
        bundles = scratch / "web-bundles"
        done = subprocess.run([str(HERE / "fetch-web-bundles.sh"), "--key", key, "--out", str(bundles)],
                              capture_output=True, text=True, timeout=APPLY_SECONDS)
        if done.returncode != 0:
            raise LookError(f"fetch-web-bundles.sh --key {key[:12]}: {done.stderr.strip()[-300:]}")
        done = subprocess.run([str(HERE / "web-overlay.sh"), "install", str(bundles), "--commit", head], env=env,
                              capture_output=True, text=True, timeout=300)
        if done.returncode != 0:
            raise LookError(f"web-overlay.sh install: {done.stderr.strip()[-300:]}")
        time.sleep(SETTLE_WEB)
        return {"how": "published bundles", "key": key}
    if not shutil.which("bun"):
        raise LookError("no web bundles are published for the head and no bun here serves its webviews")
    tree = src_tree
    if tree is None:
        # A dev server runs the head's own code here: only a head on a branch of origin or already merged.
        tips = git(repo, "ls-remote", "--heads", "origin", check=False).split()
        merged = subprocess.run(["git", "-C", str(repo), "merge-base", "--is-ancestor", head, base_tip(repo)],
                                capture_output=True).returncode == 0
        if head not in tips and not merged:
            raise LookError(f"{head[:12]} is on no branch of origin (a fork?): its dev server would run its code here")
        tree = web_checkout(repo, head, scratch)
        side.remember(worktree=str(tree), repo=str(repo))
    port = free_port()
    side.remember(dev_server=True)
    done = subprocess.run([str(HERE / "web-overlay.sh"), "server", "--local", "--worktree", str(tree), "--port",
                           str(port)], env=env, capture_output=True, text=True, timeout=APPLY_SECONDS)
    if done.returncode != 0:
        raise LookError(f"web-overlay.sh server --local: {(done.stderr or done.stdout).strip()[-300:]}")
    time.sleep(SETTLE_DEV_SERVER)
    return {"how": "dev server", "port": port}


def apply_rust(rules: Path, planned: dict, src_tree: Path | None, side: Side, scratch: Path) -> dict:
    """The head's daemon into the copy (hot-apply.py apply --branch --parts rust): the published build of its
    cmux-tui tree, else a local cargo build of a dir: source."""
    argv = [sys.executable, str(rules / "scripts/cmux-next/hot-apply.py"), "apply", planned["head"], "--branch",
            "--parts", "rust", "--app", str(side.app()), "--repo", str(rules)]
    binary = None
    if src_tree is not None and (src_tree / "cmux-tui/Cargo.toml").is_file() and shutil.which("cargo"):
        published = hot().published(planned["tree_key"]) if planned.get("tree_key") else False
        if not published:
            done = subprocess.run(["cargo", "build", "--release", "-p", "cmux-tui", "--bin", "cmux-tui"],
                                  cwd=src_tree / "cmux-tui", capture_output=True, text=True, timeout=3600)
            if done.returncode != 0:
                raise LookError(f"cargo build cmux-tui: {done.stderr.strip()[-300:]}")
            binary = src_tree / "cmux-tui/target/release/cmux-tui"
    if binary is not None:
        argv += ["--binary", str(binary)]
    env = {**os.environ, "CMUX_HOT_APPLY_STATE_DIR": str(side.dir() / "hot-apply")}
    done = subprocess.run(argv, env=env, capture_output=True, text=True, timeout=APPLY_SECONDS)
    if done.returncode != 0:
        raise LookError(f"hot-apply.py apply --parts rust exited {done.returncode}: "
                        f"{(done.stderr or done.stdout).strip()[-400:]}")
    receipt = {}
    with contextlib.suppress(ValueError, IndexError):
        receipt = json.loads(done.stdout.strip().splitlines()[-1])
    return {"how": "local cargo build" if binary else "published tree build", "phases": receipt.get("phases")}


# ---------------------------------------------------------------- look


def set_theme(sock: str, mode: str) -> None:
    """The copy in light or dark: its own appearance where the build serves debug.appearance, and its terminal
    theme (cmux's chrome follows it while App Theme is Match Terminal Theme). Never the Mac's appearance."""
    rpc(sock, "debug.appearance", {"mode": mode}, timeout=10)
    answer = rpc(sock, "settings.set", {"path": "appearance.theme", "value": THEMES[mode]}, timeout=30)
    if "error" in answer:
        raise LookError(f"settings.set appearance.theme: {answer['error']}")
    time.sleep(SETTLE_THEME)


def commit_time(repo: Path, sha: str) -> float | None:
    stamp = git(repo, "show", "-s", "--format=%ct", sha, check=False)
    return float(stamp) if stamp.isdigit() else None


def write_receipt(out: Path, receipt: dict) -> None:
    out.mkdir(parents=True, exist_ok=True)
    (out / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    (out / "steps.json").write_text(json.dumps({"steps": receipt.get("steps") or []}, indent=2) + "\n")


def command_look(args) -> int:
    began = time.monotonic()
    h = hot()
    phases = h.Phases()
    out = Path(args.out).resolve()
    out.mkdir(parents=True, exist_ok=True)
    repo = Path(args.repo).resolve()
    receipt = {"schema": 1, "marker": None, "plan": None, "app": {}, "steps": [], "errors": [], "phases": {},
               "edit_to_visible_s": None, "push_to_first_shot_s": None}
    side = Side(args.side)
    the_app = real_app(args.app)
    if the_app is None:
        raise Usage("look needs --app APP: the app the change goes into")
    receipt["app"] = app_info(the_app)
    try:
        with phases("plan"):
            planned = plan(repo, args.source, str(the_app), None)
        receipt["plan"] = planned
        if planned["needs_build"]:
            receipt["errors"].append("the change needs a build: " + "; ".join(planned["build"]))
            return finish(out, receipt, phases, began, EXIT_NEEDS_BUILD)
        if not planned["layers"]:
            receipt["plan"]["notes"].append("nothing in the app changes: nothing to look at")
            return finish(out, receipt, phases, began, EXIT_LOOKED)
        unsupported = [layer for layer in planned["layers"] if layer not in ("web", "rust")]
        if unsupported:
            raise LookError(f"this engine applies no {', '.join(unsupported)} layer yet")
        if sys.platform != "darwin":
            raise LookError("a look runs the app: it needs macOS with a display")
        receipt["marker"] = marker(planned["head"], receipt["app"].get("commit") or receipt["app"].get("version")
                                   or "unknown", planned["layers"], planned["source"])
        return look(args, repo, planned, side, the_app, out, receipt, phases, began)
    except (LookError, Usage, OSError, ValueError, subprocess.SubprocessError) as error:
        receipt["errors"].append(f"{type(error).__name__}: {str(error)[:500]}")
        if not args.watch:
            with phases("stop"):
                receipt["errors"] += side.stop()
        return finish(out, receipt, phases, began, EXIT_FAILED)


def finish(out: Path, receipt: dict, phases, began: float, code: int) -> int:
    receipt["phases"] = {**phases.rounded(), "total": round(time.monotonic() - began, 3)}
    write_receipt(out, receipt)
    log("look " + ", ".join(f"{k} {v:.1f}" for k, v in receipt["phases"].items()) + f" (exit {code})")
    return code


def side_make_args(the_app: Path) -> list[str]:
    """side-instance.sh make's arguments for the look's copy. --neutral-shell: its terminals show `$ `, never the
    worker's `cmux@cmux23 ~ %`, which the privacy check withheld every new-tab shot and video for (2026-11-16)."""
    return ["make", "--from", str(the_app), "--label", SIDE_LABEL, "--neutral-shell"]


def stop_video(video: Video, receipt: dict, side, phases) -> None:
    """VIDEO ended into video.mp4 (its errors in the receipt's), and the receipt's video facts: which recorder, and
    whether it is the copy's window alone or the whole display (and why)."""
    with phases("video"):
        try:
            video.stop()
        except LookError as error:
            receipt["errors"].append(f"video: {error}")
        receipt["video"] = video.facts
        side.remember(recorder_pid=None, recorder_name=None)
    return None


def look(args, repo, planned, side, the_app, out, receipt, phases, began) -> int:
    kit = load_kit(args.kit)
    steps = load_steps(args.state, kit)
    engine = steps_engine(args.state)
    receipt["app"]["engine"] = engine
    shoot = Shooter(kit)
    rules = rules_for(repo)
    src_tree = resolve_tree(planned, args.source)
    scratch = Path(tempfile.mkdtemp(prefix="hot-verify-look-"))
    video = None
    try:
        with phases("side"):
            if side.exists():
                side.stop()
                side.run("remove", timeout=300)
            side.run(*side_make_args(the_app), timeout=600)
            set_browser_engine(Path(side.env()["CMUX_NEXT_CONFIG_FILE"]), engine)
            launched = side.run("launch", timeout=LAUNCH_SECONDS)
            found = re.search(r"pid (\d+)", launched)
            if not found:
                raise LookError(f"side-instance.sh launch said no pid: {launched[-200:]}")
            pid = int(found.group(1))
            named = side.socket()
            sock = until("the copy's control socket", LAUNCH_SECONDS, lambda: control_socket(pid, named))
            until("the copy's window", WINDOW_SECONDS, lambda: window_id(pid) if kit is None else True)
            time.sleep(SETTLE_LAUNCH)
        with phases("before"):
            for mode in ("light", "dark"):
                set_theme(sock, mode)
                shoot(pid, out / "before" / f"{mode}.png")
        if not args.no_video:
            with phases("video"):
                video = Video(out, kit)
                try:
                    side.remember(recorder_pid=video.start(pid), recorder_name=video.name)
                except LookError as error:
                    receipt["errors"].append(f"video: {error}")
                    video = None
        handed = time.monotonic()
        applied = {}
        with phases("apply"):
            if "rust" in planned["layers"]:
                applied["rust"] = apply_rust(rules, planned, src_tree, side, scratch)
            if "web" in planned["layers"]:
                applied["web"] = apply_web(rules, planned, src_tree, side, scratch)
        receipt["applied"] = applied
        with phases("after"):
            for index, mode in enumerate(("light", "dark")):
                set_theme(sock, mode)
                shoot(pid, out / "after" / f"{mode}.png")
                if index == 0:
                    receipt["edit_to_visible_s"] = round(time.monotonic() - handed, 3)
                    pushed = commit_time(repo, planned["head"])
                    if pushed is not None:
                        receipt["push_to_first_shot_s"] = round(time.time() - pushed, 3)
        if video is not None and video.recorder is not None and any("recording" in s for s in steps):
            # The steps record clips of their own through CuaDriver, which runs one recording at a time: the look's
            # video ends here, with the change in and the after shots, and the clips show the steps.
            video = stop_video(video, receipt, side, phases)
        with phases("steps"):
            receipt["steps"] = (run_kit_steps(kit, steps, pid, sock, side.app(), out) if kit is not None
                                else run_steps(steps, pid, sock, side.app(), out, shoot))
        if video is not None:
            video = stop_video(video, receipt, side, phases)
    except (LookError, OSError, ValueError, subprocess.SubprocessError) as error:
        receipt["errors"].append(f"{type(error).__name__}: {str(error)[:500]}")
    finally:
        if video is not None and video.running:
            video.abandon()
        if not args.watch:
            with phases("stop"):
                receipt["errors"] += side.stop()
            shutil.rmtree(scratch, ignore_errors=True)
        else:
            log(f"watching: {side.name} keeps running; hot-verify.py stop --side {side.name} ends it")
    looked = all((out / "after" / f"{mode}.png").is_file() for mode in ("light", "dark")) and "applied" in receipt
    return finish(out, receipt, phases, began, EXIT_LOOKED if looked else EXIT_FAILED)


def resolve_tree(planned: dict, source: str) -> Path | None:
    kind, _, value = source.partition(":")
    if kind != "dir":
        return None
    return Path(git(Path(value or "."), "rev-parse", "--show-toplevel"))


def command_stop(args) -> int:
    errors = Side(args.side).stop()
    for error in errors:
        log(error)
    return EXIT_FAILED if errors else EXIT_LOOKED


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[1].strip())
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("plan")
    p.add_argument("--source", required=True)
    p.add_argument("--repo", default=str(ROOT))
    where = p.add_mutually_exclusive_group()
    where.add_argument("--app")
    where.add_argument("--base")
    p.add_argument("--json", action="store_true")
    p.set_defaults(func=command_plan)
    p = sub.add_parser("look")
    p.add_argument("--source", required=True)
    p.add_argument("--app", required=True)
    p.add_argument("--repo", default=str(ROOT))
    p.add_argument("--out", required=True)
    p.add_argument("--side", default=DEFAULT_SIDE)
    p.add_argument("--kit")
    p.add_argument("--state")
    p.add_argument("--no-video", action="store_true")
    p.add_argument("--watch", action="store_true")
    p.set_defaults(func=command_look)
    p = sub.add_parser("stop")
    p.add_argument("--side", default=DEFAULT_SIDE)
    p.set_defaults(func=command_stop)
    args = parser.parse_args(argv)
    try:
        return args.func(args)
    except Usage as error:
        log(str(error))
        return EXIT_USAGE
    except (RuntimeError, OSError, subprocess.SubprocessError) as error:
        log(f"{type(error).__name__}: {error}")
        return EXIT_USAGE


if __name__ == "__main__":
    sys.exit(main())
