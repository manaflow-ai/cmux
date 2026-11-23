#!/usr/bin/env python3
"""Look at a cmux NEXT change in a running app first, with no build; test it after.

    hot-verify.py plan --source dir:PATH|pr:N|sha:SHA [--repo CMUX_CLONE] [--app APP | --base COMMIT] [--json]
    hot-verify.py look --source dir:PATH|pr:N|sha:SHA --app APP --out DIR [--repo CMUX_CLONE] [--side NAME]
                       [--kit DIR] [--state STEPS.json] [--no-video] [--watch]
    hot-verify.py run --source dir:PATH|pr:N|sha:SHA --app APP --side NAME [--repo CMUX_CLONE] [--label TEXT]
    hot-verify.py extract --side NAME [--out FILE.patch]
    hot-verify.py stop --side NAME [--remove]

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
files.cmux.com/cmux-next-web/pr/N for a pr:N source or `look --pr N`, whose latest.json must name the head, else
the head's web source key) installed as the copy's web overlay, else
from the head's webviews served live by a dev server (web-overlay.sh server --local), so later edits of a
dir: source hot-reload. The rust layer is hot-apply.py apply --branch --parts rust on the copy: the cmux CI
published for the head's cmux-tui tree, else (a dir: source with cmux-tui and cargo here) a local cargo
build. When the head's daemon would differ from the app's Rust in commits that are not the change's (it branched
before the app's commit, or the app lags its fork with FFI changes between), the plan applies the change's own
commits onto the app's commit (git merge-tree, daemon_from) and the look swaps in that commit's daemon: its
published build, else --rust-binary; a change that does not apply cleanly still needs a build. Light and dark are the copy's own terminal theme (settings.set appearance.theme), never the Mac's
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

`run` is `cmux app try .`: the same plan and the same side copy, cloned from APP (the golden copy), with the
change's web and Rust put in and left running, and no screenshots, video or steps. A later run reuses the kept copy
when it came from the same APP and no layer of the last run would stay (reusable_copy); else it clones afresh. Its
last stdout line is JSON {side, from, copy, copy_reused, socket, pid, plan, applied, errors, edit_to_live_s,
phases}; exit 0 running, 1 failed (the copy stopped), 3 needs a build (no copy made). `extract --side NAME`
keeps the code a run swapped in: the branch cmux-try/NAME at the commit it ran and a patch of the change (JSON
{branch, patch, files, ...}).
`stop --remove` also deletes the copy.
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
from xml.etree import ElementTree

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
# The golden copy `run --pick` takes when the installed NIGHTLY needs a build for the tree: the NIGHTLY feed's builds,
# the tip feed's signed DEV builds of recent feat-cmux-next commits, and the nearest finished fleet app build.
NIGHTLY_FEED = (os.environ.get("CMUX_HOT_VERIFY_NIGHTLY_FEED")
                or "https://files-next.cmux.com/nightly-next/appcast-arm64.xml")
TIP_FEED = os.environ.get("CMUX_HOT_VERIFY_TIP_FEED") or "https://files.cmux.com/nightly-next/tip/appcast-arm64.xml"
SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
CMUX_XML = "https://cmux.com/xml-namespaces/cmux"
# Each kind's app identity, in the order a tie prefers them: a nightly first (its copy is a nightly).
IDENTITY = {"nightly": "nightly", "tip": "dev", "fleet": "dev"}
GOLDEN_FLEET_DEPTH = 8  # first-parent commits from the merge base asked for a fleet build
GOLDEN_KEEP = 3  # downloaded golden apps kept (250 MB to 1.1 GB each)
GOLDEN_SECONDS = 1800
GOLDEN_READY = "golden.json"
GOLDEN_FIELDS = ("kind", "commit", "label", "url", "job", "identity")
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


# A line where a tool says why it failed: cargo's and git's `error:`/`fatal:`, rustc's `error[E0425]:`, and a
# compiler's `path:line:col: error: ...` (Zig, Swift, clang).
ERROR_LINE = re.compile(r"(?:error(?:\[\w+\])?|fatal):\s|:\d+:\d+: error: ")


def why_failed(output: str, most: int = 300) -> str:
    """Why a tool failed, in at most MOST characters: its error lines, the last ones that fit, else the end of its
    output. A failed cargo build ends with the build script's panic and "waiting for other jobs to finish",
    so its last 300 characters hid the cause: `cmux app try .` on cmux17 (2026-11-19) said only "zig build of
    libghostty-vt failed with exit status: 2", while the line before said "Your Zig version v0.16.0 does not meet
    the required build version of v0.17.0"."""
    text = (output or "").strip()
    lines = [line.strip() for line in text.splitlines()]
    # A panic's message is the line after `thread 'main' panicked at FILE:LINE:COL:` (a build script's own why).
    said = [line for i, line in enumerate(lines)
            if ERROR_LINE.search(line) or (i and line and "panicked at" in lines[i - 1])]
    kept, size = [], 0
    for line in reversed(said):
        if line in kept:
            continue
        if kept and size + len(line) + 3 > most:
            break
        kept.append(line)
        size += len(line) + 3
    return " | ".join(reversed(kept))[:most] if kept else text[-most:]


def git(repo: Path, *args: str, check: bool = True, env: dict | None = None, timeout: float = GIT_SECONDS) -> str:
    done = subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True, errors="replace",
                          env={**os.environ, "GIT_TERMINAL_PROMPT": "0", **(env or {})}, timeout=timeout)
    if check and done.returncode != 0:
        raise Usage(f"git {' '.join(args[:3])}: {why_failed(done.stderr, 300)}")
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
    an exported engine (no scripts/ci) or a clone with no working tree has neither. A sparse checkout with the Cargo
    manifests but no Xcode project counts as neither too: the bundled helpers' inputs come from the project's build
    phases, and without it every cmux-tui path reads as a helper's (cmux_next_route.py _scheme_phase_rust_inputs), so
    every daemon change planned as a build (2026-11-18: 28-36% of sampled PR heads, 2-5% with the project)."""
    return not ((ROOT / ROUTE).is_file() and (repo / "cmux-tui/Cargo.toml").is_file()
                and (repo / "cmux.xcodeproj/project.pbxproj").is_file())


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
        parent = git(repo, "rev-parse", "--verify", "-q", f"{head}^1", check=False) if base == head else ""
        if parent and on_first_parent_line(repo, head, parent):
            # A merged PR's commit, planned with no app (the workflow's merged half): its merge base is itself, so
            # head..head was empty and every landed PR planned as "nothing in the app changes" (cmux#44971's
            # Rust, 2026-11-17). Its change is its own first-parent diff.
            base = parent
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
        baseline = None
        skew: tuple[str, list[str]] | None = None
        if not behind and fork != base and h.tree_key(rules, fork) != h.tree_key(rules, base):
            skew = ("Rust the app has and the change lacks", [
                f"the app's commit {base[:12]} has cmux-tui changes the change (branched at {fork[:12]}) lacks: "
                "rebase it onto the app's commit, or build it"])
        elif behind and (pinned := lag_pins_daemon(h, repo, base, fork)) and not (
                not h.swift_read_rust(repo, [p for p in pinned if p != FFI_PIN_FILE])
                and (baseline := lag_ffi_baseline(h, rules, the_app, head, base, out))):
            # The head's daemon carries the lagging commits' FFI changes, which the app does not link. The fork's
            # release brings the library up; Rust the Swift build reads itself still needs a new app.
            skew = ("Rust the app links (FFI), in the commits the app lacks", pinned)
        elif not behind and pins_differ(h, repo, base, head) and not (
                baseline := lag_ffi_baseline(h, rules, the_app, head, base, out)):
            # A change branched before the app's commit on another app FFI release: hot-apply holds its daemon back
            # (cmux#44876's look, 2026-11-18: the NIGHTLY was a repin ahead, and that release does not go back).
            skew = ("Rust the app links (FFI): the app's release is not the change's", [FFI_PIN_FILE])
        onto, why = onto_app(repo, base, fork, head) if skew else (None, "")
        if onto:
            # cmuxterm-hq#13435: every one of a week's 132 needs-build looks was this skew, none the PR's own
            # paths. The daemon of the change's own commits on the app's commit has the app's Rust and FFI and
            # only the change's diff over them: what a person trying the PR on that nightly would run. It needs no
            # FFI release of its own: it links the one the app's commit pins.
            out["layers"].append("rust")
            out["daemon_from"] = onto
            out["tree_key"] = h.tree_key(rules, onto)
            out["notes"].append(f"the daemon is the change's own commits ({fork[:12]}..{head[:12]}) applied onto "
                                f"the app's commit {base[:12]} ({onto[:12]}), not the head's tree: {skew[0]}")
            if not h.published(out["tree_key"]):
                out["notes"].append("no CI build of that daemon is published: a look needs it built "
                                    "(look --rust-binary)")
        elif skew:
            out["build"][skew[0]] = skew[1]
            out["notes"].append(why)
        else:
            out["layers"].append("rust")
            out["tree_key"] = planned.get("tree_key")
            if baseline:
                out["ffi_baseline"] = baseline
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


def onto_app(repo: Path, base: str, fork: str, head: str) -> tuple[str | None, str]:
    """The change's own commits (FORK..HEAD) applied onto the app's commit BASE, as a commit of the merged tree
    whose parent is BASE, and an empty reason; or None and why not (a conflict, a git too old for merge-tree).
    The commit's names and dates are fixed and its date is HEAD's, so one change on one app is always the same
    commit (and tree key). It is written to REPO's objects and never to a ref."""
    try:
        done = subprocess.run(["git", "-C", str(repo), "merge-tree", "--write-tree", "--no-messages",
                               f"--merge-base={fork}", base, head], capture_output=True, text=True,
                              timeout=GIT_SECONDS)
    except subprocess.TimeoutExpired:
        return None, f"git merge-tree ran past {GIT_SECONDS}s applying the change onto the app's commit"
    tree = (done.stdout.split() or [""])[0]
    if done.returncode == 1:
        return None, (f"the change's own commits ({fork[:12]}..{head[:12]}) do not apply cleanly onto the app's "
                      f"commit {base[:12]}: no daemon of the change on the app's Rust")
    if done.returncode != 0 or not SHA.fullmatch(tree):
        return None, f"git merge-tree could not apply the change onto the app's commit: {done.stderr.strip()[-200:]}"
    stamp = git(repo, "show", "-s", "--format=%ct", head)
    who = {"GIT_AUTHOR_NAME": "hot-verify", "GIT_AUTHOR_EMAIL": "hot-verify@cmux.invalid",
           "GIT_COMMITTER_NAME": "hot-verify", "GIT_COMMITTER_EMAIL": "hot-verify@cmux.invalid",
           "GIT_AUTHOR_DATE": f"@{stamp} +0000", "GIT_COMMITTER_DATE": f"@{stamp} +0000"}
    message = f"hot-verify: {fork} .. {head} onto {base}"
    return git(repo, "commit-tree", "--no-gpg-sign", tree, "-p", base, "-m", message, env=who), ""


def lag_pins_daemon(h, repo: Path, base: str, fork: str) -> list[str]:
    """The Rust the app links through FFI that changed between the app's commit and the change's fork
    (hot-apply's pins_daemon over that range): a daemon built at the head speaks those changes and the app does
    not.

    None when both commits pin the same app FFI release (app-ffi-pin.json, the same blob): an app links the
    release its commit pins, not the FFI sources at its commit, so an app built at the fork would link the very
    library this app has, beside a daemon built from the fork's sources. A look then shows what a NIGHTLY at the
    fork plus the change would; 3 of the first 38 automatic looks (2026-11-16) were refused on FFI sources that
    the pin had not taken yet. With no pin file at either end, the sources decide, as before.

    Two different pins name the pin file too, as pins_daemon does: hot-apply holds the head's daemon back from an
    app on another release (#44525), so a look that planned it anyway ended `hot-apply.py apply --parts rust exited
    3` (7 of 8 failed Rust looks, 2026-11-17). lag_ffi_baseline then puts the fork's release into the copy."""
    pins = [pin_source(h, repo, c) for c in (base, fork)]
    if all(pins) and pins[0] == pins[1]:
        return []
    files = h.live_apply.classify_range(str(repo), base, fork)["files"]
    # As pins_daemon: since #43797 classify puts cmux-tui's own C, Objective-C and Zig in "daemon" too.
    moved = [FFI_PIN_FILE] if any(pins) and pins[0] != pins[1] else []
    return moved + h.linked_rust(repo, sorted(set(files.get("daemon", []))))


def pin_source(h, repo: Path, sha: str) -> str | None:
    """The source commit of the app FFI release SHA pins (hot-apply's pinned_ffi_source); None with no pin or an
    unreadable one. The release, not the file: a repin that only rewrites checksums names the same library."""
    try:
        return h.pinned_ffi_source(repo, sha)
    except (RuntimeError, ValueError, KeyError):
        return None


def pins_differ(h, repo: Path, base: str, head: str) -> bool:
    """The app's commit BASE and HEAD pin different app FFI releases (their source commits, as hot-apply reads)."""
    pins = [pin_source(h, repo, c) for c in (base, head)]
    return all(pins) and pins[0] != pins[1]


def lag_ffi_baseline(h, rules: Path, the_app: Path | None, head: str, base: str, out: dict) -> dict | None:
    """The app FFI release the copy takes before its first launch so the head's daemon fits it, when the app lags a
    repin on feat-cmux-next that the change forked after: hot-apply's ffi part (the release the head pins, which is
    feat-cmux-next's, published by app-ffi-release.yml), checked as hot-apply checks it (additive to the app's).
    None, with a note, when the app cannot take it: the change then needs a newer NIGHTLY or a build."""
    if not h.pin_on_base(rules, head):
        return None
    try:
        moved = h.ffi_part.pin_plan(rules, the_app, head, base)
    except (h.ffi_part.Left, RuntimeError) as why:
        out["notes"].append(f"ffi: the app cannot take the change's app FFI release: {why}")
        return None
    if moved:
        out["notes"].append(f"the app's FFI release ({moved['app_pin_source'][:12]}) is older than the one the "
                            f"change forked on ({moved['source'][:12]}): the copy takes that release before it opens")
    return moved


def plan_text(planned: dict) -> str:
    lines = [f"layers: {','.join(planned['layers']) or 'none'}",
             f"needs_build: {'true' if planned['needs_build'] else 'false'}"]
    for why, paths in planned["build"].items():
        lines.append(f"build: {why}: {', '.join(paths[:5])}{' ...' if len(paths) > 5 else ''}")
    lines += [f"note: {note}" for note in planned["notes"]]
    lines += [f"head: {planned['head']}", f"base: {planned['base']}"]
    if planned.get("daemon_from"):
        lines.append(f"daemon_from: {planned['daemon_from']}")
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
            raise LookError(f"side-instance.sh {args[0]} {self.name}: {why_failed(done.stderr or done.stdout, 300)}")
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
            raise LookError(f"screencapture -l{wid}: {why_failed(done.stderr or done.stdout, 200)}")
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
        return swift_tool(HERE / "media/record-window.swift", "-parse-as-library")

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
        return why_failed(err, 300)

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


def swift_tool(source: Path, *flags: str) -> Path:
    """SOURCE (a Swift file beside the engine) compiled once per source digest into the cache (a LookError when it
    does not compile). Callers name SOURCE as a literal join to HERE, quoted path and all: a fleet worker gets only the
    files the engine's text joins to its folder (cmuxterm-hq ci-client.py hot_verify_refs), and a path built from a
    name is not one (2026-11-16: crop-video.swift was left out, and the look's video stayed the whole display)."""
    name = source.stem
    digest = hashlib.sha256(source.read_bytes()).hexdigest()[:16]
    binary = cache_dir() / f"{name}-{digest}"
    if not binary.is_file():
        binary.parent.mkdir(parents=True, exist_ok=True)
        part = binary.with_name(f".{binary.name}.{os.getpid()}")
        done = subprocess.run(["xcrun", "swiftc", "-O", *flags, str(source), "-o", str(part)],
                              capture_output=True, text=True, timeout=300)
        if done.returncode != 0:
            part.unlink(missing_ok=True)
            raise LookError(f"{name} did not compile: {why_failed(done.stderr, 300)}")
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
        tool = swift_tool(HERE / "media/crop-video.swift")
        done = subprocess.run([str(tool), str(mp4), str(dest), *(f"{v:.6f}" for v in box), f"{scale:g}"],
                              capture_output=True, text=True, timeout=660)
    except LookError as error:
        return str(error)
    except (OSError, subprocess.SubprocessError) as error:
        return f"crop-video: {error}"
    if done.returncode == 0 and dest.is_file() and dest.stat().st_size > 0:
        return None
    dest.unlink(missing_ok=True)
    return why_failed(done.stderr or done.stdout, 300) or f"crop-video exited {done.returncode}"


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


def fetch_text(url: str) -> str | None:
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "cmux-hot-verify"}),
                                    timeout=30) as answer:
            return answer.read().decode("utf-8", "replace")
    except (urllib.error.URLError, OSError, ValueError):
        return None


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


def apply_web(repo: Path, planned: dict, src_tree: Path | None, side: Side, scratch: Path,
              settle: bool = True) -> dict:
    """The head's web into the copy: published bundles as its overlay, else a dev server of the head. web-overlay.sh
    server returns once the server answers the agent pane; SETTLE (a look, whose after shot follows) then also gives
    the copy's pages their bounded reload. A run takes no shot, so it waits for nothing more (cmux app try .: about
    10 of its 11.7-14.9 s edit_to_live were this wait, 2026-11-18)."""
    env = {**os.environ, **side.env()}
    head = planned["head"]
    key = None if src_tree is not None else published_web_key(repo, planned)
    if key:
        bundles = scratch / "web-bundles"
        done = subprocess.run([str(HERE / "fetch-web-bundles.sh"), "--key", key, "--out", str(bundles)],
                              capture_output=True, text=True, timeout=APPLY_SECONDS)
        if done.returncode != 0:
            raise LookError(f"fetch-web-bundles.sh --key {key[:12]}: {why_failed(done.stderr, 300)}")
        done = subprocess.run([str(HERE / "web-overlay.sh"), "install", str(bundles), "--commit", head], env=env,
                              capture_output=True, text=True, timeout=300)
        if done.returncode != 0:
            raise LookError(f"web-overlay.sh install: {why_failed(done.stderr, 300)}")
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
        raise LookError(f"web-overlay.sh server --local: {why_failed(done.stderr or done.stdout, 300)}")
    if settle:
        time.sleep(SETTLE_DEV_SERVER)
    return {"how": "dev server", "port": port}


def apply_ffi_baseline(rules: Path, planned: dict, side: Side) -> dict:
    """The app FFI release the change forked on, into the copy before it first opens (hot-apply.py apply --branch
    --parts ffi on a copy that is not running: the library is swapped and the copy is not opened). The before shots
    then show the app on that release, and the head's daemon fits it."""
    argv = [sys.executable, str(rules / "scripts/cmux-next/hot-apply.py"), "apply", planned["head"], "--branch",
            "--parts", "ffi", "--app", str(side.app()), "--repo", str(rules)]
    env = {**os.environ, "CMUX_HOT_APPLY_STATE_DIR": str(side.dir() / "hot-apply")}
    done = subprocess.run(argv, env=env, capture_output=True, text=True, timeout=APPLY_SECONDS)
    if done.returncode != 0:
        raise LookError(f"hot-apply.py apply --parts ffi exited {done.returncode}: "
                        f"{why_failed(done.stderr or done.stdout, 400)}")
    receipt = {}
    with contextlib.suppress(ValueError, IndexError):
        receipt = json.loads(done.stdout.strip().splitlines()[-1])
    return {"release": planned["ffi_baseline"].get("release"), "phases": receipt.get("phases"),
            "applied": receipt.get("applied")}


# A local `cargo build --release -p cmux-tui` on an M-series mini (2026-11-18): cold (no target/release) and warm.
CARGO_COLD_S, CARGO_WARM_S = 628, 261


def cargo_note(key: str | None, src_tree: Path) -> str:
    """What a run says before a local cargo build of the tree's daemon starts: that it builds, about how long, and
    the fleet route instead."""
    warm = (src_tree / "cmux-tui/target/release/cmux-tui").is_file()
    seconds = CARGO_WARM_S if warm else CARGO_COLD_S
    tree = f"cmux-tui tree {key[:12]}" if key else "the cmux-tui tree"
    return (f"no published build of {tree}: building the daemon here with cargo, about {round(seconds / 60)} min "
            f"({'warm' if warm else 'cold: no cmux-tui/target/release yet'}). Instead of waiting: commit and push, "
            "and CI publishes the tree's daemon for the next run to take; or build the app with it on the fleet, "
            "`cmux-ci build cmux --ref SHA`")


# The copy's acpmux daemons take the change too. bin/acpmux is the same file as bin/cmux, but a running daemon keeps
# the build it mapped until it restarts: without this, a look at an acpmux change showed the old daemon (the
# hot-swap end to end test, 2026-11-21). hot-apply restarts only a daemon whose chats resume and whose launch
# environment it can read, and names every other one in its receipt (acpmux_left_on_old_build).
RESTART_ACPMUX = ("--restart-acpmux",)


def apply_rust(rules: Path, planned: dict, src_tree: Path | None, side: Side, scratch: Path,
               given: Path | None = None) -> dict:
    """The change's daemon into the copy (hot-apply.py apply --branch --parts rust): the published build of the
    head's cmux-tui tree, else a local cargo build of a dir: source. A plan with daemon_from (the change applied
    onto the app's commit) takes that commit's published build, else GIVEN (look --rust-binary), never the
    head's: the head's daemon is the skew the plan stepped around."""
    onto = planned.get("daemon_from")
    if onto:
        argv = [sys.executable, str(rules / "scripts/cmux-next/hot-apply.py"), "apply", onto, "--branch",
                "--parts", "rust", "--app", str(side.app()), "--repo", str(rules), *RESTART_ACPMUX]
        if given is None and not hot().published(planned["tree_key"]):
            raise LookError(f"the daemon of the change applied onto the app's commit ({onto[:12]}) is not "
                            "published: build that commit's cmux-tui and pass it as --rust-binary")
        if given is not None:
            argv += ["--binary", str(given)]
        how = ("given binary of the change applied onto the app's commit" if given is not None
               else "published tree build of the change applied onto the app's commit")
        return run_hot_apply_rust(argv, side, how)
    argv = [sys.executable, str(rules / "scripts/cmux-next/hot-apply.py"), "apply", planned["head"], "--branch",
            "--parts", "rust", "--app", str(side.app()), "--repo", str(rules), *RESTART_ACPMUX]
    if given is not None:
        # The look's own plan has no daemon_from, so a binary built for one (the worker's plan) is not this change's
        # daemon: swapping it in would label another daemon as the head's.
        raise LookError("--rust-binary is the daemon of a plan's daemon_from, and this plan has none: its daemon "
                        "is the head's")
    if planned.get("ffi_baseline"):
        argv.append("--ffi-in")  # apply_ffi_baseline put the release in before the copy opened
    binary = None
    if src_tree is not None and (src_tree / "cmux-tui/Cargo.toml").is_file() and shutil.which("cargo"):
        published = hot().published(planned["tree_key"]) if planned.get("tree_key") else False
        if not published:
            log(cargo_note(planned.get("tree_key"), src_tree))
            done = subprocess.run(["cargo", "build", "--release", "-p", "cmux-tui", "--bin", "cmux-tui"],
                                  cwd=src_tree / "cmux-tui", capture_output=True, text=True, timeout=3600)
            if done.returncode != 0:
                raise LookError(f"cargo build cmux-tui: {why_failed(done.stderr, 300)}")
            binary = src_tree / "cmux-tui/target/release/cmux-tui"
    elif (src_tree is not None and not shutil.which("cargo") and planned.get("tree_key")
          and not hot().published(planned["tree_key"])):
        # No cargo here and nothing published for the tree: hot-apply would only say its fetch failed.
        raise LookError(f"no published build of cmux-tui tree {planned['tree_key'][:12]} and no cargo on this Mac to "
                        "build the daemon: commit and push (CI publishes the tree's daemon for the next run), or "
                        "build the app with it on the fleet, `cmux-ci build cmux --ref SHA`")
    if binary is not None:
        argv += ["--binary", str(binary)]
    how = "local cargo build" if binary is not None else "published tree build"
    return run_hot_apply_rust(argv, side, how)


def run_hot_apply_rust(argv: list[str], side: Side, how: str) -> dict:
    env = {**os.environ, "CMUX_HOT_APPLY_STATE_DIR": str(side.dir() / "hot-apply")}
    done = subprocess.run(argv, env=env, capture_output=True, text=True, timeout=APPLY_SECONDS)
    if done.returncode != 0:
        raise LookError(f"hot-apply.py apply --parts rust exited {done.returncode}: "
                        f"{why_failed(done.stderr or done.stdout, 400)}")
    receipt = {}
    with contextlib.suppress(ValueError, IndexError):
        receipt = json.loads(done.stdout.strip().splitlines()[-1])
    steps = receipt.get("steps") if isinstance(receipt.get("steps"), dict) else {}
    rust = steps.get("rust") if isinstance(steps.get("rust"), dict) else {}
    # What the look's receipt says about the copy's acpmux: each daemon restarted onto the change, and each left on
    # the build it had, with why (hot-apply's own receipt, which the look used to drop).
    return {"how": how, "phases": receipt.get("phases"), "acpmux": steps.get("acpmux"),
            "acpmux_left_on_old_build": rust.get("acpmux_left_on_old_build") or []}


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
        if getattr(args, "pr", None) and not planned.get("pr"):
            # A sha: source (the fleet step's) of pull request N: its web layer is the bundles CI published for it
            # (pr/N/latest.json, used only while it names this head), not a dev server (61 of 82 web looks
            # started one on 2026-11-17: the head's own source key is not the one the PR's layer publishes).
            planned["pr"] = args.pr
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
    except (RuntimeError, Usage, OSError, ValueError, subprocess.SubprocessError) as error:
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
            if planned.get("ffi_baseline"):
                receipt["ffi_baseline"] = apply_ffi_baseline(rules, planned, side)
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
                given = Path(args.rust_binary).resolve() if getattr(args, "rust_binary", None) else None
                applied["rust"] = apply_rust(rules, planned, src_tree, side, scratch, given)
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
    except (RuntimeError, OSError, ValueError, subprocess.SubprocessError) as error:
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
    side = Side(args.side)
    errors = side.stop()
    if getattr(args, "remove", False) and side.exists():
        try:
            side.run("remove", timeout=300)
        except (LookError, subprocess.SubprocessError) as error:
            errors.append(str(error))
    for error in errors:
        log(error)
    return EXIT_FAILED if errors else EXIT_LOOKED


# ---------------------------------------------------------------- the golden copy: the closest published build


def appcast_builds(text: str, kind: str) -> list[dict]:
    """A Sparkle feed's builds, newest first: {kind, commit, label, url}. The commit is the item's
    cmux:sourceCommit (the NIGHTLY feed), else the commit its release notes link names (the tip feed); an item
    with neither, or with no https enclosure, is not a candidate."""
    try:
        items = list(ElementTree.fromstring(text).iter("item"))
    except ElementTree.ParseError:
        return []
    builds = []
    for item in items:
        commit = (item.findtext(f"{{{CMUX_XML}}}sourceCommit") or "").strip()
        if not SHORT_SHA.fullmatch(commit):
            found = re.search(r"/commit/([0-9a-f]{40})", item.findtext(f"{SPARKLE}fullReleaseNotesLink") or "")
            commit = found.group(1) if found else ""
        enclosure = item.find("enclosure")
        url = enclosure.get("url", "") if enclosure is not None else ""
        if commit and url.startswith("https://"):
            builds.append({"kind": kind, "commit": commit, "url": url,
                           "label": item.findtext(f"{SPARKLE}shortVersionString") or item.findtext("title") or ""})
    return builds


def cmux_ci() -> str | None:
    """The fleet client (`cmux-ci`), when this Mac has one: fleet Macs and the team's own do."""
    found = shutil.which("cmux-ci")
    if found:
        return found
    kept = Path.home() / ".local/bin/cmux-ci"
    return str(kept) if os.access(kept, os.X_OK) else None


def fleet_build(repo: Path, anchor: str, notes: list[str]) -> dict | None:
    """The nearest finished fleet app build (`cmux-ci build cmux`, which feat-cmux-next's own commits get as
    `ahead-*` builds) on ANCHOR or one of its first-parents, GOLDEN_FLEET_DEPTH at most; None without cmux-ci."""
    tool = cmux_ci()
    if tool is None:
        return None
    for commit in git(repo, "rev-list", "--first-parent", "-n", str(GOLDEN_FLEET_DEPTH), anchor).split():
        try:
            done = subprocess.run([tool, "status", "--ref", commit], capture_output=True, text=True, timeout=60)
        except (OSError, subprocess.SubprocessError) as error:
            notes.append(f"fleet builds: cmux-ci status did not answer ({error})")
            return None
        if done.returncode != 0:
            notes.append(f"fleet builds: cmux-ci status --ref exited {done.returncode} (no controller?)")
            return None
        try:
            jobs = json.loads(done.stdout or "[]")
        except ValueError:
            jobs = []
        finished = sorted((job for job in jobs if isinstance(job, dict) and job.get("kind") == "cmux"
                           and job.get("state") == "done" and job.get("artifact")),
                          key=lambda job: str(job.get("updated_at") or ""), reverse=True)
        if finished:
            job = finished[0]
            return {"kind": "fleet", "commit": commit, "job": str(job.get("id")),
                    "label": str(job.get("tag") or job.get("id"))}
    return None


def golden_candidates(repo: Path, anchor: str, installed: str | None, notes: list[str]) -> list[dict]:
    """The published app builds a tree at ANCHOR (its merge base with feat-cmux-next) could be swapped into, nearest
    to ANCHOR first, a nightly before a DEV build at the same distance: the NIGHTLY feed's builds, the tip feed's
    signed DEV builds, and the nearest finished fleet build. Only builds on ANCHOR or behind it: a newer one has
    commits the tree lacks. INSTALLED (the installed NIGHTLY's commit, already planned) is left out."""
    found = []
    for kind, feed in (("nightly", NIGHTLY_FEED), ("tip", TIP_FEED)):
        text = fetch_text(feed)
        if text is None:
            notes.append(f"{kind} feed: {feed} did not answer")
        found += appcast_builds(text or "", kind)
    if (fleet := fleet_build(repo, anchor, notes)) is not None:
        found.append(fleet)
    if any(not has_commit(repo, build["commit"]) for build in found):
        # A build of a commit this clone has not fetched yet: feat-cmux-next once, then whatever is still missing
        # is not a candidate.
        git(repo, "fetch", "-q", "--no-tags", "origin", f"+refs/heads/{BASE_BRANCH}:refs/remotes/origin/{BASE_BRANCH}",
            check=False)
    ranked, seen = [], {installed} if installed else set()
    for build in found:
        commit = git(repo, "rev-parse", "--verify", "-q", f"{build['commit']}^{{commit}}", check=False)
        if not SHA.fullmatch(commit) or commit in seen:
            continue
        seen.add(commit)
        if subprocess.run(["git", "-C", str(repo), "merge-base", "--is-ancestor", commit, anchor],
                          capture_output=True).returncode != 0:
            continue
        behind = int(git(repo, "rev-list", "--count", f"{commit}..{anchor}") or 0)
        ranked.append({**build, "commit": commit, "behind": behind, "identity": IDENTITY[build["kind"]]})
    ranked.sort(key=lambda build: (build["behind"], list(IDENTITY).index(build["kind"])))
    return ranked


def golden_anchor(repo: Path, head: str) -> str:
    """The commit a tree's golden copy should be built at: its merge base with feat-cmux-next (HEAD itself for a
    checkout of a feat-cmux-next commit)."""
    return git(repo, "merge-base", head, base_tip(repo))


def describe(build: dict) -> str:
    """One build, as `cmux app try .` names it."""
    where = {"installed": "the installed app", "nightly": "NIGHTLY", "tip": "tip DEV build",
             "fleet": "fleet build"}[build["kind"]]
    label = f" {build['label']}" if build.get("label") else ""
    return f"{where}{label} at {build['commit'][:12]}"


def pick_golden(repo: Path, source: str, installed: Path) -> dict:
    """The golden copy for SOURCE: INSTALLED when the change goes into it with no build, else the nearest published
    build it does go into (golden_candidates, each planned against its commit). Nothing is downloaded here:
    {kind, commit, label, identity, plan, why, tried, notes} and the build's url or fleet job; with no build that
    fits, INSTALLED's plan (needs_build) and what was tried."""
    planned = plan(repo, source, str(installed), None)
    mine = {"kind": "installed", "commit": planned["base"], "label": app_info(installed).get("version", ""),
            "identity": "nightly", "app": str(installed), "plan": planned, "tried": [], "notes": []}
    if not planned["needs_build"]:
        return {**mine, "why": f"{describe(mine)} takes this tree with no build"}
    reasons = "; ".join(planned["build"])
    anchor = golden_anchor(repo, planned["head"])
    notes: list[str] = []
    tried = [{"build": describe(mine), "build_reasons": list(planned["build"])}]
    for build in golden_candidates(repo, anchor, planned["base"], notes):
        theirs = plan(repo, source, None, build["commit"])
        if not theirs["needs_build"]:
            count = build["behind"]
            behind = ("at the tree's merge base" if count == 0 else
                      f"{count} commit{'s' if count != 1 else ''} behind the tree's merge base {anchor[:12]}")
            why = (f"{describe(build)} ({behind}) takes this tree with no build; {describe(mine)} needs one "
                   f"({reasons})")
            return {**build, "plan": theirs, "why": why, "tried": tried, "notes": notes}
        tried.append({"build": describe(build), "build_reasons": list(theirs["build"])})
    why = f"no published build takes this tree with no build: {describe(mine)} needs one ({reasons})"
    return {**mine, "why": why, "tried": tried, "notes": notes}


def golden_root() -> Path:
    return cache_dir() / "golden"


def golden_use_lock(root: Path, name: str):
    """The in-use lock of cached golden app NAME (root/.NAME.use, beside the app so removing the app keeps it): a try
    holds it shared until its clone is made; the cache's cleanup removes an app only when it can take it exclusive."""
    return open(root / f".{name}.use", "a")


def fetch_golden(build: dict, hold: contextlib.ExitStack | None = None) -> Path:
    """BUILD's app, downloaded and checked once into the cache (golden/<kind>-<commit>/), the newest GOLDEN_KEEP
    kept; each try then clones it (side-instance.sh make: an APFS clone). With HOLD, the app's in-use lock is taken
    shared before the cache lock is let go and stays held until HOLD closes, so another try's cleanup never removes
    the app while this try clones it."""
    if build["kind"] == "installed":
        return Path(build["app"])
    root = golden_root()
    root.mkdir(parents=True, exist_ok=True)
    dest = root / f"{build['kind']}-{build['commit'][:12]}"
    with open(root / ".lock", "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if not (dest / GOLDEN_READY).is_file():
            shutil.rmtree(dest, ignore_errors=True)
            part = Path(tempfile.mkdtemp(prefix=".part-", dir=root))
            try:
                log(f"golden copy: downloading {describe(build)} once (later tries clone it)")
                download_golden(build, part)
                app = golden_app(part)
                check_golden(app, build)
                stamp_commit(app, build["commit"])
                (part / GOLDEN_READY).write_text(json.dumps({k: build.get(k) for k in GOLDEN_FIELDS}) + "\n")
                os.replace(part, dest)
            finally:
                shutil.rmtree(part, ignore_errors=True)
        os.utime(dest)
        if hold is not None:
            mine = hold.enter_context(golden_use_lock(root, dest.name))
            fcntl.flock(mine, fcntl.LOCK_SH)
        kept = sorted((p for p in root.iterdir() if p.is_dir() and (p / GOLDEN_READY).is_file()),
                      key=lambda p: p.stat().st_mtime, reverse=True)
        for old in kept[GOLDEN_KEEP:]:
            if old == dest:
                continue
            with golden_use_lock(root, old.name) as used:
                try:
                    fcntl.flock(used, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    continue  # a try is cloning it now: the next fetch removes it
                shutil.rmtree(old, ignore_errors=True)
    return golden_app(dest)


def download_golden(build: dict, part: Path) -> None:
    """BUILD's app into PART: a feed's DMG (curl, mounted read-only, the app copied out), or a fleet job's app
    (cmux-ci artifact: its per-file bundle when the store has one and zstd is here, else its zip)."""
    if build["kind"] == "fleet":
        tool = cmux_ci()
        if tool is None:
            raise LookError("a fleet build needs cmux-ci")
        bundle = part / "bundle"
        done = subprocess.run([tool, "artifact", build["job"], str(bundle), "--bundle"], capture_output=True,
                              text=True, timeout=GOLDEN_SECONDS)
        if done.returncode == 0:
            return
        shutil.rmtree(bundle, ignore_errors=True)
        archive = part / "app.zip"
        done = subprocess.run([tool, "artifact", build["job"], str(archive)], capture_output=True, text=True,
                              timeout=GOLDEN_SECONDS)
        if done.returncode != 0:
            raise LookError(f"cmux-ci artifact {build['job']}: {(done.stderr or done.stdout).strip()[-300:]}")
        unzip = subprocess.run(["ditto", "-x", "-k", str(archive), str(part / "app")], capture_output=True, text=True,
                               timeout=GOLDEN_SECONDS)
        archive.unlink(missing_ok=True)
        if unzip.returncode != 0:
            raise LookError(f"ditto -x {archive.name}: {unzip.stderr.strip()[-300:]}")
        return
    image = part / "app.dmg"
    done = subprocess.run(["curl", "-fsSL", "--proto", "=https", "-o", str(image), build["url"]], capture_output=True,
                          text=True, timeout=GOLDEN_SECONDS)
    if done.returncode != 0:
        raise LookError(f"curl {build['url']}: {done.stderr.strip()[-300:]}")
    mount = part / "mnt"
    mount.mkdir()
    done = subprocess.run(["hdiutil", "attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", str(mount),
                           str(image)], capture_output=True, text=True, timeout=600)
    if done.returncode != 0:
        raise LookError(f"hdiutil attach {image.name}: {done.stderr.strip()[-300:]}")
    try:
        app = golden_app(mount)
        done = subprocess.run(["ditto", str(app), str(part / "app" / app.name)], capture_output=True, text=True,
                              timeout=GOLDEN_SECONDS)
        if done.returncode != 0:
            raise LookError(f"ditto {app.name}: {done.stderr.strip()[-300:]}")
    finally:
        subprocess.run(["hdiutil", "detach", str(mount)], capture_output=True, timeout=120)
    image.unlink(missing_ok=True)


def golden_app(root: Path) -> Path:
    apps = sorted(root.glob("*.app")) or sorted(root.glob("*/*.app")) or sorted(root.glob("*/*/*.app"))
    if not apps:
        raise LookError(f"{root} holds no .app")
    return apps[0]


def check_golden(app: Path, build: dict) -> None:
    """The downloaded app is BUILD's: its CMUXCommit (when it has one: a fleet DEV build has none, and cmux-ci
    checked its artifact's sha256) is the build's commit, and a feed's signed app verifies."""
    commit = app_info(app).get("commit") or ""
    if commit and not build["commit"].startswith(commit) and not commit.startswith(build["commit"]):
        raise LookError(f"{describe(build)}'s app says CMUXCommit {commit[:12]}")
    if build["kind"] != "fleet":
        done = subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], capture_output=True, text=True,
                              timeout=600)
        if done.returncode != 0:
            raise LookError(f"{app.name} does not verify: {done.stderr.strip()[-300:]}")


def stamp_commit(app: Path, commit: str) -> None:
    """A fleet DEV build names no CMUXCommit, and hot-apply refuses to put a daemon into an app it cannot place
    ("has no CMUXCommit (a DEV build)", the first fleet golden copy's Rust apply on a fleet Mac, 2026-11-19): the
    cached app is stamped with the commit its job built, which `--from` that app then plans against too. Its seal
    breaks, as every copy's does; side-instance.sh make re-seals the copy."""
    path = app / "Contents/Info.plist"
    with open(path, "rb") as handle:
        info = plistlib.load(handle)
    if info.get("CMUXCommit"):
        return
    info["CMUXCommit"] = commit
    with open(path, "wb") as handle:
        plistlib.dump(info, handle, fmt=plistlib.FMT_XML)


def command_golden(args) -> int:
    """The golden copy `run --pick` would take for SOURCE, planned only: nothing is downloaded."""
    chosen = pick_golden(Path(args.repo).resolve(), args.source, real_app(args.app) or Path(NO_APP))
    if args.json:
        print(json.dumps(chosen, indent=2))
    else:
        print(f"golden: {describe(chosen)}\nwhy: {chosen['why']}")
        for tried in chosen["tried"]:
            print(f"tried: {tried['build']}: needs a build ({'; '.join(tried['build_reasons'])})")
        for note in chosen["notes"]:
            print(f"note: {note}")
        print(plan_text(chosen["plan"]), end="")
    return EXIT_NEEDS_BUILD if chosen["plan"]["needs_build"] else EXIT_LOOKED


# ---------------------------------------------------------------- run and extract: `cmux app try .`


def emit(result: dict, phases, began: float, code: int) -> int:
    """RESULT as the last stdout line (`cmux app try` reads it), and the exit code."""
    result["phases"] = {**phases.rounded(), "total": round(time.monotonic() - began, 3)}
    print(json.dumps(result), flush=True)
    return code


def can_build_swift_app(planned: dict) -> bool:
    """Whether a complete fleet app can cover every build-required layer in the plan.

    A fleet artifact is the exact head's complete app, so it also carries web or Rust layers
    that are live-swappable when they accompany a Swift change. Other build reasons (FFI,
    manifests, bundled helpers) remain an explicit build-required result.
    """
    build = planned.get("build")
    return bool(planned.get("needs_build") and isinstance(build, dict) and build
                and set(build) <= {"Swift", "Swift, resources or manifests"}
                and all(paths and all(path.endswith(".swift") and not path.endswith("Package.swift")
                                      for path in paths) for paths in build.values()))


def _ci_client() -> str:
    ci = os.environ.get("CMUX_CI") or str(Path.home() / ".local/bin/cmux-ci")
    if not os.access(ci, os.X_OK):
        raise LookError(f"no cmux-ci client at {ci} (CMUX_CI names another)")
    return ci


def _ci_run(argv: list[str], cwd: Path | None = None, timeout: int = APPLY_SECONDS) -> subprocess.CompletedProcess:
    done = subprocess.run(argv, cwd=cwd, capture_output=True, text=True, errors="replace", timeout=timeout)
    if done.returncode != 0:
        detail = why_failed(done.stderr or done.stdout, 500) or "no output"
        raise LookError(f"{' '.join(argv[1:])}: {detail}")
    return done


def _artifact_app(bundle: Path) -> Path:
    apps = sorted(p for pattern in ("*.app", "*/*.app") for p in bundle.glob(pattern)
                  if p.is_dir() and (p / "Contents/Info.plist").is_file())
    if len(apps) != 1:
        raise LookError(f"fleet build returned {len(apps)} top-level app artifacts; expected one")
    return apps[0]


def build_swift_app(repo: Path, planned: dict, source: str, out: Path) -> Path:
    """Build the exact source tree on the fleet and return its complete app artifact."""
    ci = _ci_client()
    kind = source.partition(":")[0]
    tree = resolve_tree(planned, source) if kind == "dir" else repo
    if tree is None:
        raise LookError("working-tree source has no checkout")
    tag = f"app-try-{planned['head'][:12]}"
    build = [ci, "build", "cmux", "--builder", "linux", "--backend-mode", "local", "--tag", tag]
    if kind == "dir":
        build.append("--working-tree")
    else:
        build += ["--ref", planned["head"], "--workspace", f"app-try:{planned['head']}"]
    submitted = _ci_run(build, cwd=tree)
    try:
        job = str(json.loads(submitted.stdout)["id"])
    except (json.JSONDecodeError, KeyError, TypeError, ValueError) as error:
        raise LookError(f"cmux-ci build returned no job id: {why_failed(submitted.stdout, 300) or 'no output'}") from error
    log(f"fleet app build {job} for {planned['head'][:12]}")
    _ci_run([ci, "wait", "--timeout", str(APPLY_SECONDS), job], cwd=tree, timeout=APPLY_SECONDS + 30)
    bundle = out / "fleet-bundle"
    bundle.mkdir(parents=True, exist_ok=True)
    artifact = subprocess.run([ci, "artifact", job, str(bundle), "--bundle"], cwd=tree,
                              capture_output=True, text=True, errors="replace", timeout=APPLY_SECONDS)
    if artifact.returncode == 3:
        archive = out / "fleet-app.zip"
        _ci_run([ci, "artifact", job, str(archive)], cwd=tree)
        shutil.rmtree(bundle, ignore_errors=True)
        bundle.mkdir(parents=True, exist_ok=True)
        # ditto preserves the executable modes and framework symlinks in macOS app archives.
        _ci_run(["ditto", "-x", "-k", str(archive), str(bundle)], cwd=tree)
    elif artifact.returncode != 0:
        raise LookError(f"cmux-ci artifact {job}: {why_failed(artifact.stderr or artifact.stdout, 500) or 'no output'}")
    return _artifact_app(bundle)


def reusable_copy(state: dict, the_app: Path, label: str, layers: list[str]) -> str | None:
    """Why the kept copy must be made again for this try, or None when it can be reused as it is: stopped, the
    layers put in, relaunched. A remake (APFS clone, ad hoc re-seal, lsregister) costs about 5 s, and a new
    bundle's first launch pays about 1.7 s of policy check (goal team-dev-build-is-swap's Ceiling: a re-try's
    side phase read 8.6 s). So a copy is reused when it was cloned from the same golden app at the same version,
    under the same label, and this try's layers overwrite every layer the last try put in, so none of the last
    branch's code stays behind."""
    if state.get("try_from") != str(the_app):
        return "another golden app"
    if not state.get("try_app") or state.get("try_app") != app_info(the_app):
        return "the golden app changed"
    if state.get("try_label") != label:
        return "another label"
    left = sorted(set(state.get("try_layers") or []) - set(layers))
    if left:
        return f"the last try's {', '.join(left)} would stay"
    return None


def command_run(args) -> int:
    """`cmux app try .`: a clone of APP (the golden copy; by default the installed NIGHTLY) beside everything
    else, the source's web and Rust swapped in, left running. The kept copy of the last try is reused when it was
    cloned from the same APP and nothing of the last try would stay (reusable_copy); else it is cloned fresh.
    No screenshots, video or steps: the copy and its dev server keep running (saves under webviews/ show live)
    until `stop --side NAME`. Swift-only app changes use a complete per-commit fleet app before launch; other
    build-required changes exit 3 with their plan and make no copy."""
    began = time.monotonic()
    phases = hot().Phases()
    repo = Path(args.repo).resolve()
    side = Side(args.side)
    the_app = real_app(args.app)
    if the_app is None:
        raise Usage("run needs --app APP: the app the copy is cloned from")
    result = {"schema": 1, "side": side.name, "from": str(the_app), "app": app_info(the_app), "plan": None,
              "copy": None, "socket": None, "pid": None, "applied": {}, "errors": [], "edit_to_live_s": None}
    scratch = None
    golden_held = contextlib.ExitStack()  # the cached golden app's in-use lock, until the copy is made
    try:
        with phases("plan"):
            if args.pick:
                golden = pick_golden(repo, args.source, the_app)
                result["golden"] = {k: golden.get(k) for k in (*GOLDEN_FIELDS, "why", "tried", "notes")}
                log(f"golden copy: {golden['why']}")
                planned = golden["plan"]
            else:
                golden, planned = None, plan(repo, args.source, str(the_app), None)
        result["plan"] = planned
        built_app = None
        if planned["needs_build"] and not can_build_swift_app(planned):
            return emit(result, phases, began, EXIT_NEEDS_BUILD)
        if golden is not None and golden["kind"] != "installed":
            with phases("golden"):
                the_app = fetch_golden(golden, golden_held)
            result.update({"from": str(the_app), "app": app_info(the_app)})
        unsupported = [layer for layer in planned["layers"] if layer not in ("web", "rust")]
        if unsupported:
            raise LookError(f"this engine applies no {', '.join(unsupported)} layer yet")
        if sys.platform != "darwin":
            raise LookError("a run launches the app: it needs macOS")
        rules = rules_for(repo)
        src_tree = resolve_tree(planned, args.source)
        scratch = Path(tempfile.mkdtemp(prefix="hot-verify-run-"))
        if can_build_swift_app(planned):
            try:
                with phases("app-build"):
                    built_app = build_swift_app(repo, planned, args.source, scratch)
                result["applied"]["app"] = {
                    "how": "fleet app build (re-sealed side instance)",
                    "commit": planned["head"],
                }
            except (LookError, OSError, ValueError, subprocess.SubprocessError):
                shutil.rmtree(scratch, ignore_errors=True)
                scratch = None
                raise
        label = args.label or f"cmux {side.name}"
        layers = sorted(planned["layers"])
        with phases("side"):
            # The kept copy, when nothing it holds differs from what this try puts in (reusable_copy): stopped,
            # not made again, so its relaunch is a warm one. Else a fresh clone: the last one, its dev server too,
            # goes first. Its own Cloud session stays either way (side-instance.sh remove --keep-sign-in): a person
            # signs a copy in once, not every try. A built app is new each time, so it always makes a fresh clone.
            remake = "no copy yet"
            if side.exists():
                remake = "an app was built" if built_app is not None else \
                    reusable_copy(side.state(), the_app, label, layers)
                side.stop()
            if remake is None:
                golden_held.close()
                result["copy_reused"] = True
            else:
                result["copy_reused"] = False
                result["remade_because"] = remake
                if side.exists():
                    side.run("remove", "--keep-sign-in", timeout=300)
                make = ["make", "--from", str(built_app or the_app), "--label", label]
                try:
                    side.run(*make, timeout=600)
                finally:
                    golden_held.close()
            side.remember(try_source=args.source, try_repo=str(repo), try_head=planned["head"],
                          try_fork=planned["fork"], try_from=str(the_app),
                          # A copy of a built app never passes for a clone of the golden one (reusable_copy).
                          try_app=app_info(the_app) if built_app is None else {"built": planned["head"]},
                          try_label=label, try_layers=layers)
            launched = side.run("launch", timeout=LAUNCH_SECONDS)
            found = re.search(r"pid (\d+)", launched)
            if not found:
                raise LookError(f"side-instance.sh launch said no pid: {launched[-200:]}")
            pid = int(found.group(1))
            named = side.socket()
            sock = until("the copy's control socket", LAUNCH_SECONDS, lambda: control_socket(pid, named))
        result.update(copy=str(side.app()), socket=sock, pid=pid)
        try:
            handed = time.monotonic()
            with phases("apply"):
                if built_app is None and "rust" in planned["layers"]:
                    result["applied"]["rust"] = apply_rust(rules, planned, src_tree, side, scratch)
                if built_app is None and "web" in planned["layers"]:
                    result["applied"]["web"] = apply_web(rules, planned, src_tree, side, scratch, settle=False)
            result["edit_to_live_s"] = round(time.monotonic() - handed, 3)
        finally:
            shutil.rmtree(scratch, ignore_errors=True)
        return emit(result, phases, began, EXIT_LOOKED)
    except (LookError, OSError, ValueError, subprocess.SubprocessError) as error:
        result["errors"].append(f"{type(error).__name__}: {str(error)[:500]}")
        with phases("stop"):
            result["errors"] += side.stop()
        if scratch is not None:
            shutil.rmtree(scratch, ignore_errors=True)
        return emit(result, phases, began, EXIT_FAILED)
    finally:
        golden_held.close()


def command_extract(args) -> int:
    """The code a run swapped in, kept: the branch cmux-try/NAME at the commit it ran (the working tree as it was
    then) and a patch of the change (from its fork with the app's commit to that commit) under the cache, so both
    outlive the copy. The checkout's working tree is not touched."""
    began = time.monotonic()
    phases = hot().Phases()
    side = Side(args.side)
    if not side.exists():
        raise Usage(f"no copy {side.name}: nothing was swapped in to extract")
    state = side.state()
    head, fork, repo = state.get("try_head"), state.get("try_fork"), state.get("try_repo")
    if not (SHA.fullmatch(str(head)) and SHA.fullmatch(str(fork)) and repo):
        raise Usage(f"copy {side.name} has no run recorded (hot-verify.py run records one)")
    repo = Path(repo)
    branch = f"cmux-try/{side.name}"
    git(repo, "update-ref", f"refs/heads/{branch}", head)
    out = Path(args.out) if args.out else cache_dir() / "extract" / f"{side.name}-{head[:12]}.patch"
    out.parent.mkdir(parents=True, exist_ok=True)
    diff = git(repo, "diff", "--binary", fork, head)
    out.write_text(diff + ("\n" if diff else ""))
    files = [line for line in git(repo, "diff", "--name-only", fork, head).splitlines() if line]
    result = {"schema": 1, "side": side.name, "branch": branch, "head": head, "fork": fork, "patch": str(out),
              "files": files, "repo": str(repo)}
    return emit(result, phases, began, EXIT_LOOKED)


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
    p.add_argument("--rust-binary", help="the cmux-tui built from the plan's daemon_from (the change applied onto "
                   "the app's commit), when no CI build of it is published")
    p.add_argument("--watch", action="store_true")
    p.add_argument("--pr", type=int, help="the pull request a sha: source is the head of: its published web layer")
    p.set_defaults(func=command_look)
    p = sub.add_parser("run")
    p.add_argument("--source", required=True)
    p.add_argument("--app", required=True)
    p.add_argument("--repo", default=str(ROOT))
    p.add_argument("--side", required=True)
    p.add_argument("--label")
    p.add_argument("--pick", action="store_true",
                   help="when APP needs a build for the source, copy the nearest published build that does not")
    p.set_defaults(func=command_run)
    p = sub.add_parser("golden")
    p.add_argument("--source", required=True)
    p.add_argument("--app", required=True)
    p.add_argument("--repo", default=str(ROOT))
    p.add_argument("--json", action="store_true")
    p.set_defaults(func=command_golden)
    p = sub.add_parser("extract")
    p.add_argument("--side", required=True)
    p.add_argument("--out")
    p.set_defaults(func=command_extract)
    p = sub.add_parser("stop")
    p.add_argument("--side", default=DEFAULT_SIDE)
    p.add_argument("--remove", action="store_true")
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
