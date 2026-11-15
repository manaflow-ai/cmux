#!/usr/bin/env python3
"""Look first, then test: a change hot-applied onto a running copy of the app, shot and clicked, before any build.

    hot-verify.py plan --source SRC [--app APP | --base COMMIT] [--repo DIR] [--json]
    hot-verify.py look --source SRC [--app APP] [--side NAME] [--state FILE] [--out DIR] [--watch]
                       [--before-ref REF] [--themes LIGHT,DARK] [--no-video] [--kit DIR] [--host HOST]
    hot-verify.py fetch-nightly DIR      the newest NIGHTLY's app into DIR (its sha256-free length check,
                                         then codesign --verify); prints the app's path
    hot-verify.py stop --side NAME       quit the side instance and its dev server

Leo, 2026-11-15: "Just screenshot it, take a video, touch it, interact with it, click around with it, and then
push it through the various testing instead of the other way around." And: "maybe the code doesn't even need to
be compiled". This is that loop for an agent: the change goes onto a copy of an installed NIGHTLY (side-instance.sh:
its own bundle id, data, socket, daemon and web overlay, so nobody's app is touched), and the receipt holds what the
change looks like, light and dark, before and after, a short recording and a click-through, in minutes.

SRC is one of
  dir:PATH     a checkout's working tree as it is, edits and untracked files included (receipt source=worktree)
  pr:N         a pull request's head, fetched with git (refs/pull/N/head; source=pr)
  sha:SHA      a commit (a merged PR's merge commit; source=pr)
  profile:FILE a customize profile (cmux customize use FILE): settings, theme, views, extensions, applied as is

`plan` sorts the change against the app's commit (CMUXCommit; --base stands in when there is no app) with
live_apply.py's rules and hot-apply.py's Rust rules, and prints its layers and whether it needs a build:

  web        webviews/: served live into the copy (web-overlay.sh server --local --worktree TREE): Vite hot
             reload, so every later edit shows in the running copy within seconds, no bundle build
  rust       cmux-tui/ outside what the app links: `cargo build -p cmux-tui --bin cmux` in the tree (incremental
             when its target/ is warm), then hot-apply.py apply --binary (the daemon handed over, terminals kept)
  customize  a profile: `cmux customize use FILE` then `apply`, no build
  needs_build  Swift, resources, manifests, Rust the app links (FFI), a web ABI the app lacks: `look` stops
             there and prints the build command; nothing else here builds

`look` then runs, timing each phase (receipt.json `phases`, wall seconds):

  app        the side instance made from APP (default: the installed NIGHTLY) and launched; its control socket
  before     before/light.png and before/dark.png: the app as it is (or, with --before-ref REF, the web of REF,
             served the same way: a merged PR's parent against an app that already has it)
  apply      each layer above
  after      after/light.png, after/dark.png once the window changed (pixels, png_diff.py) or SETTLE_S passed;
             `edit_to_visible_s` is the time from the change landing on disk to the first changed frame
  steps      a click-through (default: from what changed, DEFAULT_STEPS; --state FILE takes a steps file in
             cmuxterm-hq build-fleet/pr_capture/nightly_steps.py's format), with a recording (video.mp4)

The pointer, keyboard, recording and window shots come from cmuxterm-hq's pr_capture kit (nightly_steps.py,
popup_shot.py: CuaDriver, under its own Screen Recording and Accessibility grants, which the capture minis have).
--kit DIR names the kit (default $CMUX_HQ_ROOT/build-fleet/pr_capture, else ~/Projects/cmuxterm-hq/...); without
it the shots fall back to `screencapture -l` and the steps are skipped, which the receipt says.

--host HOST runs the look on a fleet Mac: the tree's changed files (against the app's commit) are copied into a
checkout this script keeps there (~/hot-verify/cmux, fetched with git), the kit with them, the look runs there
(`reach HOST`), and the out folder comes back. An agent host with no GUI still gets the whole receipt.

--watch keeps the dev server and the copy running after the receipt, and shoots after/watch-N.png each time a file
under webviews/ changes, with its edit_to_visible_s appended to watch.jsonl; Ctrl-C ends it (`stop` cleans up).

The receipt's `marker` is the first line of the PR comment that says a change was looked at hot (cmuxterm-hq's
NOW metric counts it):

  <!-- cmux-hot-verify sha=<head 40> app=<CMUXCommit> layers=<web,rust,customize> source=<worktree|pr> -->

Exit 0: looked (or nothing in the app to look at). 2: usage. 3: needs a build (plan printed with the command).
1: a phase failed; the receipt says which.
"""
from __future__ import annotations

import argparse
import contextlib
import importlib.util
import json
import os
import plistlib
import re
import shlex
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
SIDE = HERE / "side-instance.sh"
OVERLAY = HERE / "web-overlay.sh"
HOT_APPLY = HERE / "hot-apply.py"
DEFAULT_APP = "/Applications/cmux NIGHTLY.app"
FEED = "https://files-next.cmux.com/nightly-next/appcast-arm64.xml"
SHA = re.compile(r"[0-9a-f]{40}")
# Two app themes for the light and dark shots (appearance.appTheme takes a theme name; both ship in every build).
DEFAULT_THEMES = ("Builtin Light", "Builtin Dark")
# After a change lands, how long the window may take to show it before the after shot is taken anyway.
SETTLE_S = 20.0
CHANGED_FRACTION = 0.0005  # of sampled pixels: a changed frame
SHOT_INTERVAL_S = 0.25
CUSTOMIZE_SUFFIX = ".json"
# Default click-through, by what changed: (path pattern, steps). The first match wins; every list ends with
# DEFAULT_TAIL. Each step is nightly_steps.py's format.
DEFAULT_STEPS = [
    (re.compile(r"webviews/src/(agent-pane|chat|transcript|composer)"),
     [{"action": "palette.newAgentChat", "name": "open-agent-chat"}, {"wait": 2.0}, {"shot": "agent-chat"}]),
    (re.compile(r"webviews/src/pages/settings|settings"),
     [{"action": "openSettings", "name": "open-settings"}, {"wait": 2.0}, {"shot": "settings"}]),
    (re.compile(r"webviews/src/pages/home|home"),
     [{"action": "newTab", "name": "new-tab"}, {"wait": 2.0}, {"shot": "new-tab"}]),
    (re.compile(r"."),
     [{"action": "newTab", "name": "new-tab"}, {"wait": 2.0}, {"shot": "new-tab"}]),
]
DEFAULT_TAIL = [{"key": "escape"}, {"wait": 0.5}, {"shot": "after-escape"}]


def log(message: str) -> None:
    print(f"hot-verify: {message}", file=sys.stderr, flush=True)


def load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def git(repo: Path, *args: str, check: bool = True, env=None) -> str:
    done = subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True, errors="replace",
                          env={**os.environ, **(env or {})})
    if check and done.returncode != 0:
        raise RuntimeError(f"git {' '.join(args)}: {done.stderr.strip()[:300]}")
    return done.stdout.strip() if done.returncode == 0 else ""


class Phases:
    """Wall seconds per named phase, in order (the receipt's `phases`)."""

    def __init__(self, clock=time.monotonic):
        self.clock, self.seconds, self.started = clock, {}, clock()

    @contextlib.contextmanager
    def __call__(self, name: str):
        t0 = self.clock()
        try:
            yield
        finally:
            self.seconds[name] = round(self.seconds.get(name, 0.0) + self.clock() - t0, 3)

    def total(self) -> float:
        return round(self.clock() - self.started, 3)


# ---------------------------------------------------------------- sources


def parse_source(text: str) -> tuple[str, str]:
    kind, sep, value = text.partition(":")
    if not sep or kind not in ("dir", "pr", "sha", "profile") or not value:
        raise ValueError(f"--source takes dir:PATH, pr:N, sha:SHA or profile:FILE, not {text!r}")
    if kind == "pr" and not value.isdigit():
        raise ValueError(f"pr:N takes a number, not {value!r}")
    if kind == "sha" and not re.fullmatch(r"[0-9a-f]{7,40}", value):
        raise ValueError(f"sha:SHA takes a commit sha, not {value!r}")
    return kind, value


def snapshot_commit(repo: Path) -> str:
    """A commit object of REPO's working tree as it is (tracked edits and untracked, unignored files) on top of
    HEAD, made with a scratch index: the checkout, its index and its refs are untouched."""
    with tempfile.TemporaryDirectory(prefix="hot-verify-index.") as scratch:
        env = {"GIT_INDEX_FILE": str(Path(scratch) / "index")}
        git(repo, "read-tree", "HEAD", env=env)
        git(repo, "add", "-A", env=env)
        tree = git(repo, "write-tree", env=env)
    if tree == git(repo, "rev-parse", "HEAD^{tree}"):
        return git(repo, "rev-parse", "HEAD")
    return git(repo, "-c", "user.name=hot-verify", "-c", "user.email=hot-verify@localhost", "commit-tree", tree,
               "-p", "HEAD", "-m", "hot-verify: working tree")


def resolve_source(kind: str, value: str, repo: Path) -> dict:
    """{kind, repo, head (a commit the plan sorts), marker_sha (the 40-hex head the receipt names), receipt_source}."""
    if kind == "dir":
        tree = Path(value).expanduser().resolve()
        top = Path(git(tree, "rev-parse", "--show-toplevel"))
        head = snapshot_commit(top)
        base_head = git(top, "rev-parse", "HEAD")
        return {"kind": kind, "repo": top, "tree": top, "head": head, "marker_sha": base_head,
                "dirty": head != base_head, "receipt_source": "worktree"}
    if kind == "pr":
        git(repo, "fetch", "-q", "origin", f"refs/pull/{value}/head")
        head = git(repo, "rev-parse", "FETCH_HEAD")
        return {"kind": kind, "repo": repo, "tree": None, "head": head, "marker_sha": head, "pr": int(value),
                "dirty": False, "receipt_source": "pr"}
    if kind == "sha":
        if subprocess.run(["git", "-C", str(repo), "cat-file", "-e", f"{value}^{{commit}}"],
                          capture_output=True).returncode != 0:
            git(repo, "fetch", "-q", "origin", value)
        head = git(repo, "rev-parse", f"{value}^{{commit}}")
        return {"kind": kind, "repo": repo, "tree": None, "head": head, "marker_sha": head, "dirty": False,
                "receipt_source": "pr"}
    profile = Path(value).expanduser().resolve()
    if not profile.is_file() or profile.suffix != CUSTOMIZE_SUFFIX:
        raise ValueError(f"profile:FILE takes a customize profile .json, not {value}")
    return {"kind": kind, "repo": repo, "tree": None, "head": None, "marker_sha": None, "profile": str(profile),
            "dirty": False, "receipt_source": "worktree"}


# ---------------------------------------------------------------- plan


def app_info(app: Path) -> dict:
    try:
        with open(app / "Contents/Info.plist", "rb") as handle:
            info = plistlib.load(handle)
    except OSError:
        return {}
    return {"commit": str(info.get("CMUXCommit") or ""), "version": str(info.get("CFBundleVersion") or ""),
            "bundle": str(info.get("CFBundleIdentifier") or ""), "dirty": info.get("CMUXCommitDirty") is True}


def make_plan(source: dict, app: Path | None, base: str | None, hot=None, live=None) -> dict:
    """The layers SOURCE's change takes onto the app (or BASE), and what needs a build."""
    out = {"source": source["kind"], "head": source.get("head"), "marker_sha": source.get("marker_sha"),
           "layers": [], "needs_build": False, "build": {}, "notes": [], "files": {}}
    if source["kind"] == "profile":
        out["layers"] = ["customize"]
        out["app_commit"] = app_info(app).get("commit") if app else base
        return out
    hot = hot or load("hot_apply", HOT_APPLY)
    live = live or hot.live_apply
    repo, head = Path(source["repo"]), source["head"]
    if base:
        app_commit = git(repo, "rev-parse", f"{base}^{{commit}}")
    elif app is not None and (app / "Contents/Info.plist").is_file():
        if app_info(app).get("dirty"):
            out["notes"].append(f"{app} was built with local edits (CMUXCommitDirty): its code is not its commit's")
        app_commit = hot.app_commit(app, repo)
    else:
        app_commit = git(repo, "merge-base", head, "origin/feat-cmux-next")
        out["notes"].append(f"no app: sorted against the merge base with origin/feat-cmux-next ({app_commit[:12]})")
    out["app_commit"] = app_commit
    fork = app_commit if hot.is_ancestor(repo, app_commit, head) else git(repo, "merge-base", app_commit, head)
    out["since"] = fork
    if hot.is_ancestor(repo, head, app_commit):
        out["notes"].append("the app already contains this change (use --before-ref to see it against its parent)")
    result = live.classify_range(str(repo), fork, head)
    files = result["files"]
    native = [p for p in files.get("rebuild", []) if hot.NATIVE_IN_TUI.match(p)]
    if native:
        files["rebuild"] = [p for p in files["rebuild"] if p not in native]
        files["daemon"] = sorted(set(files.get("daemon", [])) | set(native))
    out["files"] = {k: v for k, v in files.items() if v}
    out["verdict"] = result["verdict"]
    for kind in ("swift-live", "rebuild"):
        if files.get(kind):
            out["build"][kind] = files[kind]
    if files.get("web-live"):
        want = web_abi(repo, head)
        have = hot.app_abi(app) if (app is not None and base is None) else web_abi(repo, app_commit)
        if want is not None and have is not None and want != have:
            out["build"]["web ABI"] = [f"the change's web needs ABI {want}, the app has {have}"]
        else:
            out["layers"].append("web")
    rust = files.get("daemon", [])
    if rust:
        linked = hot.linked_rust(repo, rust)
        if linked:
            out["build"]["Rust the app links (FFI)"] = linked
        elif fork != app_commit and hot.tree_key(repo, fork) != hot.tree_key(repo, app_commit):
            out["build"]["the app has Rust the change lacks"] = [
                f"rebase onto the app's commit {app_commit[:12]} (git rebase {app_commit[:12]}), or build"]
        else:
            out["layers"].append("rust")
            helpers = hot.helper_rust(repo, rust)
            if helpers:
                out["notes"].append("bundled helpers built from these files keep the app's build: "
                                    + ", ".join(helpers[:5]))
    if files.get("ios-only"):
        out["notes"].append("iOS files change: the Mac app does not")
    out["needs_build"] = bool(out["build"])
    if out["needs_build"]:
        out["build_command"] = build_command(source)
    elif not out["layers"]:
        out["notes"].append("nothing in the app changes (docs, CI, tests, scripts): nothing to look at")
    return out


def web_abi(repo: Path, commit: str) -> int | None:
    try:
        return json.loads(git(repo, "show", f"{commit}:webviews/src/web-abi.json"))["abi"]
    except (RuntimeError, ValueError, KeyError, TypeError):
        return None


def build_command(source: dict) -> str:
    if source.get("pr"):
        return f"scripts/cmux-next/try-pr.sh {source['pr']}   # the fleet dev build, opened in a side instance"
    return ("push the branch, open its PR, then scripts/cmux-next/try-pr.sh N (the fleet dev build); "
            f"or cmux-ci build cmux --ref {source.get('marker_sha') or 'SHA'}")


def marker(head: str | None, app_commit: str | None, layers: list, source: str) -> str:
    return (f"<!-- cmux-hot-verify sha={head or 'none'} app={app_commit or 'none'} "
            f"layers={','.join(layers) or 'none'} source={source} -->")


# ---------------------------------------------------------------- the copy


def side(*args: str, env=None, check: bool = True) -> str:
    done = subprocess.run([str(SIDE), *args], capture_output=True, text=True, env={**os.environ, **(env or {})})
    if check and done.returncode != 0:
        raise RuntimeError(f"side-instance.sh {' '.join(args)}: {(done.stderr or done.stdout).strip()[-400:]}")
    return done.stdout.strip()


def side_env(name: str) -> dict:
    """The exports `side-instance.sh env NAME` prints, as a dict."""
    out = {}
    for word in shlex.split(side("env", name).removeprefix("export ")):
        key, _, value = word.partition("=")
        out[key] = value
    return out


def side_root() -> Path:
    return Path(os.environ.get("CMUX_SIDE_ROOT") or Path.home() / "Library/Application Support/cmux-side")


def app_socket(pid: int, path: str, timeout: float = 90.0) -> str:
    """PATH (the socket side-instance.sh named in the copy's LSEnvironment), once it accepts a connection."""
    if not path:
        raise RuntimeError("the side instance names no socket (made before `side-instance.sh socket`): remake it")
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if connects(path):
            return path
        if subprocess.run(["kill", "-0", str(pid)], capture_output=True).returncode != 0:
            raise RuntimeError(f"the copy (pid {pid}) exited before its socket answered")
        time.sleep(0.5)  # the app's launch until its socket listens (bounded by TIMEOUT)
    raise RuntimeError(f"{path} did not answer in {timeout:g} s (pid {pid})")


def connects(path: str) -> bool:
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
            conn.settimeout(2)
            conn.connect(path)
        return True
    except OSError:
        return False


def rpc(path: str, method: str, params=None, timeout: float = 30.0) -> dict:
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
        conn.settimeout(timeout)
        conn.connect(path)
        conn.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = conn.recv(1 << 20)
            if not chunk:
                break
            buf += chunk
    answer = json.loads(buf or b"{}")
    return answer.get("result") if answer.get("ok") else {"error": answer.get("error")}


class Copy:
    """The side instance a look runs in: made from APP (again when APP changed), launched, its socket found."""

    def __init__(self, name: str, app: Path):
        self.name, self.app = name, app
        self.pid = None
        self.socket = None
        self.path = None

    def marker(self) -> dict:
        try:
            text = (side_root() / self.name / ".side-instance").read_text()
        except OSError:
            return {}
        return dict(line.split("=", 1) for line in text.splitlines() if "=" in line)

    def ensure(self) -> None:
        made = self.marker()
        version = app_info(self.app).get("version")
        if made.get("from") != str(self.app) or made.get("version") != version or not made.get("socket"):
            if made:
                side("stop", self.name, check=False)
            log(side("make", self.name, "--from", str(self.app), "--label", f"cmux {self.name}"))
        self.path = Path(side("path", self.name))
        # In front: the shots and the click-through are of this window (a capture mini's whole-host lease).
        said = side("launch", self.name, "--front")
        log(said)
        self.pid = int((side_root() / self.name / "pid").read_text().strip())
        self.socket = app_socket(self.pid, self.marker().get("socket", ""))

    def cli(self, *args: str, timeout: float = 60.0) -> subprocess.CompletedProcess:
        binary = self.path / "Contents/Resources/bin/cmux"
        return subprocess.run([str(binary), "--app-socket", self.socket, *args], capture_output=True, text=True,
                              timeout=timeout, env={**os.environ, "CMUX_NEXT_SOCKET_PATH": self.socket})

    def theme(self, name: str) -> dict:
        done = self.cli("settings", "set", "appearance.appTheme", name, "--yes")
        return {"theme": name, "ok": done.returncode == 0, **({} if done.returncode == 0 else
                                                                {"error": (done.stderr or done.stdout)[-300:]})}

    def alive(self) -> bool:
        return self.pid is not None and subprocess.run(["kill", "-0", str(self.pid)],
                                                       capture_output=True).returncode == 0


# ---------------------------------------------------------------- shots


class Shooter:
    """The copy's main window into a PNG: the pr_capture kit's window_shot (screencapture -l, else CuaDriver's
    capture under its own grant) when the kit is here, else screencapture -l of the app's frontmost window."""

    def __init__(self, kit: Path | None):
        self.kit, self.steps_module = kit, None
        if kit and (kit / "nightly_steps.py").is_file():
            sys.path.insert(0, str(kit))
            self.steps_module = load("pr_capture_nightly_steps", kit / "nightly_steps.py")

    def shoot(self, pid: int, path: Path) -> str:
        path.parent.mkdir(parents=True, exist_ok=True)
        if self.steps_module is not None:
            try:
                return self.steps_module.window_shot([pid], path)
            except RuntimeError as error:
                # The window alone failed (screencapture -l without this process's own Screen Recording grant,
                # CuaDriver's window capture empty): one capture of the display under CuaDriver's grant, cut to
                # the window (popup_shot.shoot, what capture-host shot takes).
                try:
                    self.steps_module.popup_shot.shoot(pid, path, with_popups=True)
                    return "cua-driver display cut"
                except (RuntimeError, OSError, ValueError, subprocess.SubprocessError) as second:
                    raise RuntimeError(f"{str(error)[:300]}; display cut: {str(second)[:300]}") from second
        window = frontmost_window(pid)
        done = subprocess.run(["screencapture", "-x", "-o", f"-l{window}", str(path)], capture_output=True,
                              timeout=30)
        if done.returncode != 0 or not path.is_file():
            raise RuntimeError(f"screencapture -l{window}: {done.stderr.decode(errors='replace')[-200:]}")
        return "screencapture"


def frontmost_window(pid: int) -> int:
    """The largest on-screen window of PID (Quartz, through the system python's objc bridge when present)."""
    code = ("import Quartz,sys,json\n"
            "ws=Quartz.CGWindowListCopyWindowInfo(Quartz.kCGWindowListOptionOnScreenOnly,Quartz.kCGNullWindowID)\n"
            f"m=[w for w in ws if w.get('kCGWindowOwnerPID')=={pid} and w.get('kCGWindowLayer')==0]\n"
            "m.sort(key=lambda w:-(w['kCGWindowBounds']['Width']*w['kCGWindowBounds']['Height']))\n"
            "print(m[0]['kCGWindowNumber'] if m else '')\n")
    done = subprocess.run(["/usr/bin/python3", "-c", code], capture_output=True, text=True, timeout=30)
    if not done.stdout.strip().isdigit():
        raise RuntimeError(f"no window of pid {pid} (install the pr_capture kit: --kit)")
    return int(done.stdout.strip())


def wait_changed(shooter: Shooter, pid: int, reference: Path, out: Path, since: float, settle: float = SETTLE_S,
                 diff=None) -> dict:
    """Shoot until the window differs from REFERENCE (or SETTLE seconds pass); the last frame goes to OUT.
    `seconds` counts from SINCE (time.monotonic of the change landing)."""
    diff = diff or load("png_diff", HERE / "png_diff.py").changed
    frame = out.with_suffix(".probe.png")
    while True:
        shooter.shoot(pid, frame)
        now = time.monotonic()
        try:
            fraction = diff(reference, frame)
        except ValueError:
            fraction = 1.0
        if fraction >= CHANGED_FRACTION or now - since >= settle:
            frame.replace(out)
            return {"changed": fraction >= CHANGED_FRACTION, "fraction": round(fraction, 5),
                    "seconds": round(now - since, 3)}
        time.sleep(SHOT_INTERVAL_S)


# ---------------------------------------------------------------- layers


def port_for(name: str) -> int:
    """A dev server port of the copy's own, kept across looks (side-instance root/NAME/port)."""
    saved = side_root() / name / "port"
    with contextlib.suppress(OSError, ValueError):
        return int(saved.read_text().strip())
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]
    saved.write_text(f"{port}\n")
    return port


def serve_web(tree: Path, name: str, env: dict) -> dict:
    """The copy's web from TREE's webviews/ through its Vite dev server (hot reload)."""
    port = port_for(name)
    done = subprocess.run([str(OVERLAY), "server", "--local", "--worktree", str(tree), "--port", str(port)],
                          capture_output=True, text=True, env={**os.environ, **env}, timeout=600)
    if done.returncode != 0:
        raise RuntimeError(f"web-overlay.sh server --local: {(done.stderr or done.stdout).strip()[-500:]}")
    return {"server": f"http://127.0.0.1:{port}/", "tree": str(tree)}


def look_tree(repo: Path, name: str) -> Path:
    """One checkout this script keeps per copy for pr: and sha: sources (and --before-ref): a later look moves
    it, so its node_modules and Vite cache stay warm."""
    tree = side_root() / name / "tree"
    if not (tree / ".git").exists():
        git(repo, "worktree", "prune", "--expire", "now")
        git(repo, "worktree", "add", "-q", "--detach", str(tree), "HEAD")
    return tree


def move_tree(tree: Path, commit: str) -> float:
    """TREE checked out at COMMIT (its files land on disk: the "edit"); returns time.monotonic when it did."""
    git(tree, "checkout", "-q", "--force", "--detach", commit)
    landed = time.monotonic()
    if (tree / "ghostty-next/build.zig").exists():  # follow a ghostty-next pin bump (no-op when it did not move)
        subprocess.run(["git", "-C", str(tree), "submodule", "update", "--depth", "1", "ghostty-next"],
                       capture_output=True, text=True)
    return landed


def zig_env(tree: Path) -> dict:
    """CMUX_ZIG for the Zig ghostty-next asks for (its build.zig.zon minimum_zig_version) when the zig on PATH is
    another minor: a host keeps several (Homebrew's zig@X.Y), and libghostty-vt refuses any but its own."""
    zon = tree / "ghostty-next/build.zig.zon"
    found = re.search(r'\.minimum_zig_version\s*=\s*"(\d+\.\d+)', zon.read_text()) if zon.exists() else None
    if not found:
        return {}
    want = found.group(1)
    if os.environ.get("CMUX_ZIG") or os.environ.get("ZIG"):
        return {}
    on_path = shutil.which("zig")
    have = subprocess.run([on_path, "version"], capture_output=True, text=True).stdout if on_path else ""
    if have.startswith(want + "."):
        return {}
    for prefix in ("/opt/homebrew/opt", "/usr/local/opt"):
        zig = Path(prefix) / f"zig@{want}/bin/zig"
        if zig.exists():
            return {"CMUX_ZIG": str(zig)}
    return {}


def build_rust(tree: Path) -> tuple[Path, float]:
    """`cargo build -p cmux-tui --bin cmux-tui` (the app ships it as bin/cmux) in TREE's cmux-tui workspace: incremental when target/ is warm."""
    t0 = time.monotonic()
    # cmux-tui links libghostty-vt, built from the ghostty-next submodule at the tree's own pin.
    if not (tree / "ghostty-next/build.zig").exists():
        sub = subprocess.run(["git", "-C", str(tree), "submodule", "update", "--init", "--depth", "1", "ghostty-next"],
                             capture_output=True, text=True)
        if sub.returncode != 0:
            subprocess.run(["git", "-C", str(tree), "submodule", "update", "--init", "ghostty-next"], check=True)
    done = subprocess.run(["cargo", "build", "-p", "cmux-tui", "--bin", "cmux-tui"], cwd=tree / "cmux-tui",
                          capture_output=True, text=True, env={**os.environ, **zig_env(tree)})
    if done.returncode != 0:
        raise RuntimeError(f"cargo build -p cmux-tui: {done.stderr.strip()[-800:]}")
    return tree / "cmux-tui/target/debug/cmux-tui", round(time.monotonic() - t0, 3)


def swap_rust(copy: Copy, repo: Path, head: str, binary: Path, env: dict) -> dict:
    state = side_root() / copy.name / "hot-apply"
    done = subprocess.run([sys.executable, str(HOT_APPLY), "apply", head, "--branch", "--parts", "rust", "--app",
                           str(copy.path), "--repo", str(repo), "--binary", str(binary)], capture_output=True,
                          text=True, env={**os.environ, **env, "CMUX_HOT_APPLY_STATE_DIR": str(state)})
    lines = [line for line in done.stdout.splitlines() if line.startswith("{")]
    receipt = json.loads(lines[-1]) if lines else {}
    if done.returncode != 0:
        raise RuntimeError(f"hot-apply.py apply --binary: exit {done.returncode}: {done.stderr.strip()[-500:]}")
    return {"phases": receipt.get("phases"), "applied": receipt.get("applied"), "seconds": receipt.get("seconds")}


def apply_profile(copy: Copy, profile: str) -> dict:
    used = copy.cli("customize", "use", profile, "--json")
    if used.returncode != 0:
        raise RuntimeError(f"cmux customize use: {(used.stderr or used.stdout)[-400:]}")
    applied = copy.cli("customize", "apply", "hot-verify", "--json")
    if applied.returncode != 0:
        raise RuntimeError(f"cmux customize apply: {(applied.stderr or applied.stdout)[-400:]}")
    return {"profile": os.path.basename(profile)}


# ---------------------------------------------------------------- steps


def default_steps(files: dict) -> list:
    changed = [p for paths in files.values() for p in paths]
    for pattern, steps in DEFAULT_STEPS:
        if any(pattern.search(p) for p in changed) or pattern.pattern == ".":
            return [{"recording": "start", "clip": "look"}, *steps, *DEFAULT_TAIL, {"recording": "stop"}]
    return []


def run_steps(shooter: Shooter, copy: Copy, steps: list, out: Path, video: bool) -> dict:
    """STEPS through the kit's nightly_steps.Steps against the copy; the clip becomes OUT/video.mp4."""
    module = shooter.steps_module
    if module is None:
        return {"skipped": "no pr_capture kit (--kit): steps and the recording need CuaDriver"}
    if not video:
        steps = [s for s in steps if "recording" not in s]
    steps = module.validate({"steps": steps})
    runner = module.Steps(steps, out, ocr=str(shooter.kit / "ocr"), terms_file=str(shooter.kit / "private-terms.json"))

    class Process:
        pid = copy.pid

        @staticmethod
        def poll():
            return None if copy.alive() else 1

    env = {**os.environ, "HOME": str(Path.home())}
    runner(Process, copy.socket, env, copy.path, out, {"rendered_at": True})
    result = json.loads((out / module.RESULT).read_text()) if (out / module.RESULT).is_file() else {}
    clips = sorted((out / "clips").glob("*.mp4")) if (out / "clips").is_dir() else []
    if clips:
        clips[0].replace(out / "video.mp4")
    return {"steps": result.get("steps", []), "video": (out / "video.mp4").is_file()}


# ---------------------------------------------------------------- look


def look(args) -> int:
    phases = Phases()
    out = Path(args.out or tempfile.mkdtemp(prefix="hot-verify-")).resolve()
    out.mkdir(parents=True, exist_ok=True)
    kind, value = parse_source(args.source)
    repo = Path(args.repo).resolve()
    app = Path(args.app)
    receipt = {"schema": 1, "at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "source": args.source,
               "app": {"path": str(app), **app_info(app)}, "phases": phases.seconds, "files": {}, "errors": []}

    def finish(code: int) -> int:
        receipt["seconds"] = phases.total()
        receipt["files"] = sorted(str(p.relative_to(out)) for p in out.rglob("*")
                                  if p.is_file() and p.name != "receipt.json" and ".probe." not in p.name)
        (out / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
        print(json.dumps({"receipt": str(out / "receipt.json"), "marker": receipt.get("marker"),
                          "seconds": receipt["seconds"], "errors": receipt["errors"]}))
        return code

    with phases("plan"):
        source = resolve_source(kind, value, repo)
        planned = make_plan(source, app, None)
    receipt["plan"] = planned
    receipt["marker"] = marker(source.get("marker_sha"), planned.get("app_commit"), planned["layers"],
                               source["receipt_source"])
    if planned["needs_build"]:
        log(f"needs a build: {', '.join(planned['build'])}; {planned['build_command']}")
        return finish(3)
    if not planned["layers"]:
        log("nothing in the app changes: nothing to look at")
        return finish(0)
    name = args.side or f"hv-{(source.get('pr') or (source.get('marker_sha') or 'profile')[:8])}"
    copy = Copy(name, app)
    shooter = Shooter(Path(args.kit) if args.kit else default_kit())
    receipt["side"] = name
    receipt["shots_by"] = "pr_capture kit" if shooter.steps_module else "screencapture"
    themes = args.themes.split(",") if args.themes else list(DEFAULT_THEMES)
    try:
        with phases("app"):
            copy.ensure()
            env = side_env(name)
        tree = source.get("tree")
        before_ref = args.before_ref
        if "web" in planned["layers"] and (before_ref or not tree):
            tree = look_tree(Path(source["repo"]), name)
        with phases("before"):
            if before_ref:
                move_tree(tree, git(Path(source["repo"]), "rev-parse", f"{before_ref}^{{commit}}"))
                receipt["before_web"] = serve_web(tree, name, env)
                time.sleep(2.0)  # the copy reloads its pages onto the server (bounded settle, a capture's delay)
            receipt["themes"] = {}
            for label, theme in zip(("light", "dark"), themes):
                receipt["themes"][label] = copy.theme(theme)
                time.sleep(1.0)  # the theme repaints (a capture's bounded delay)
                receipt.setdefault("shots", {})[f"before/{label}"] = shooter.shoot(copy.pid, out / f"before/{label}.png")
        landed = None
        with phases("apply"):
            if "web" in planned["layers"]:
                if source.get("tree") and not before_ref:
                    landed = time.monotonic()
                    receipt["web"] = serve_web(source["tree"], name, env)
                else:
                    if not before_ref:
                        move_tree(tree, source["head"])
                        receipt["web"] = serve_web(tree, name, env)
                        landed = time.monotonic()
                    else:
                        landed = move_tree(tree, source["head"])  # Vite sees the files change: hot reload
                        receipt["web"] = receipt["before_web"]
            if "rust" in planned["layers"]:
                build_tree = source.get("tree") or tree or look_tree(Path(source["repo"]), name)
                if not source.get("tree"):
                    move_tree(build_tree, source["head"])
                binary, built = build_rust(Path(build_tree))
                phases.seconds["rust_build"] = built
                t0 = time.monotonic()
                receipt["rust"] = swap_rust(copy, Path(source["repo"]), source["head"], binary, env)
                phases.seconds["rust_swap"] = round(time.monotonic() - t0, 3)
                landed = landed or time.monotonic()
            if "customize" in planned["layers"]:
                landed = time.monotonic()
                receipt["customize"] = apply_profile(copy, source["profile"])
        with phases("after"):
            dark = out / "before/dark.png"
            seen = wait_changed(shooter, copy.pid, dark, out / "after/dark.png", landed or time.monotonic())
            receipt["edit_to_visible_s"] = seen["seconds"] if seen["changed"] else None
            receipt["after_change"] = seen
            receipt["shots"]["after/dark"] = "changed" if seen["changed"] else "settled"
            receipt["themes"]["light-after"] = copy.theme(themes[0])
            time.sleep(1.0)  # the theme repaints
            receipt["shots"]["after/light"] = shooter.shoot(copy.pid, out / "after/light.png")
            if args.started is not None:
                receipt["push_to_first_shot_s"] = round(time.time() - args.started, 3)
        with phases("steps"):
            steps = json.loads(Path(args.state).read_text())["steps"] if args.state else default_steps(planned["files"])
            receipt["steps"] = run_steps(shooter, copy, steps, out, not args.no_video)
        if args.watch:
            watch(shooter, copy, Path(source.get("tree") or tree), out, receipt)
        return finish(0)
    except (OSError, RuntimeError, ValueError, subprocess.SubprocessError) as error:
        receipt["errors"].append(str(error)[:1000])
        log(str(error)[:1000])
        return finish(1)


def watch(shooter: Shooter, copy: Copy, tree: Path, out: Path, receipt: dict) -> None:
    """Shoot after each change under TREE/webviews/src until Ctrl-C (mtime scan: no watcher dependency)."""
    root = tree / "webviews/src"

    def newest() -> float:
        return max((p.stat().st_mtime for p in root.rglob("*") if p.is_file()), default=0.0)

    seen, count = newest(), 0
    log(f"watching {root}: each save is shot into {out}/after/watch-N.png (Ctrl-C ends)")
    with contextlib.suppress(KeyboardInterrupt):
        while copy.alive():
            mtime = newest()
            if mtime > seen:
                landed = time.monotonic() - max(0.0, time.time() - mtime)
                count += 1
                reference = out / ("after/dark.png" if count == 1 else f"after/watch-{count - 1}.png")
                result = wait_changed(shooter, copy.pid, reference, out / f"after/watch-{count}.png", landed)
                with open(out / "watch.jsonl", "a") as handle:
                    handle.write(json.dumps({"n": count, "edit_to_visible_s": result["seconds"],
                                             "changed": result["changed"]}) + "\n")
                log(f"save {count}: {'visible' if result['changed'] else 'no change'} in {result['seconds']} s")
                seen = mtime
            time.sleep(0.25)


def default_kit() -> Path | None:
    for candidate in (os.environ.get("CMUX_HQ_ROOT"), Path.home() / "Projects/cmuxterm-hq",
                      Path.home() / "hot-verify/cmuxterm-hq"):
        if candidate and (Path(candidate) / "build-fleet/pr_capture/nightly_steps.py").is_file():
            return Path(candidate) / "build-fleet/pr_capture"
    return None


# ---------------------------------------------------------------- remote


def changed_files(repo: Path, base: str) -> list[str]:
    """The files that differ from BASE in REPO's working tree (tracked edits, deletions, untracked)."""
    tracked = git(repo, "diff", "--name-only", "--no-renames", base).splitlines()
    untracked = git(repo, "ls-files", "--others", "--exclude-standard").splitlines()
    return sorted(set(tracked) | set(untracked))


def remote(args) -> int:
    """The look on HOST: its checkout at the app's commit (or the source's base), this tree's changed files on
    top, the kit beside it; the out folder back here."""
    host = args.host
    kind, value = parse_source(args.source)
    remote_root = "hot-verify"
    out = Path(args.out or tempfile.mkdtemp(prefix="hot-verify-")).resolve()
    out.mkdir(parents=True, exist_ok=True)
    t0 = time.time()
    rest = [a for a in remote_args(args)]
    if kind == "dir":
        tree = Path(git(Path(value).expanduser(), "rev-parse", "--show-toplevel"))
        base = git(tree, "merge-base", "HEAD", "origin/feat-cmux-next")
        files = changed_files(tree, base)
        log(f"{len(files)} changed file(s) against {base[:12]} go to {host}")
        reach(host, f"set -e; mkdir -p ~/{remote_root}; cd ~/{remote_root}; "
                    f"[ -d cmux/.git ] || git clone -q --filter=blob:none https://github.com/manaflow-ai/cmux.git cmux; "
                    f"cd cmux; git fetch -q origin {base} feat-cmux-next; git checkout -q --force --detach {base}; "
                    f"git clean -fdq -e node_modules -e target")
        present = [f for f in files if (tree / f).exists()]
        gone = [f for f in files if not (tree / f).exists()]
        if present:
            tar = subprocess.Popen(["tar", "-C", str(tree), "-cf", "-", *present], stdout=subprocess.PIPE)
            subprocess.run(["reach", host, f"tar -C ~/{remote_root}/cmux -xf -"], stdin=tar.stdout, check=True)
            tar.wait()
        if gone:
            reach(host, f"cd ~/{remote_root}/cmux && rm -f -- {' '.join(shlex.quote(f) for f in gone)}")
        rest += ["--source", f"dir:~/{remote_root}/cmux"]
    else:
        reach(host, f"set -e; mkdir -p ~/{remote_root}; cd ~/{remote_root}; "
                    f"[ -d cmux/.git ] || git clone -q --filter=blob:none https://github.com/manaflow-ai/cmux.git cmux; "
                    f"git -C cmux fetch -q origin feat-cmux-next")
        rest += ["--source", args.source]
    kit = Path(args.kit) if args.kit else default_kit()
    if kit:
        tar = subprocess.Popen(["tar", "-C", str(kit), "-cf", "-", "."], stdout=subprocess.PIPE)
        subprocess.run(["reach", host, f"mkdir -p ~/{remote_root}/kit && tar -C ~/{remote_root}/kit -xf -"],
                       stdin=tar.stdout, check=True)
        tar.wait()
        rest += ["--kit", f"~/{remote_root}/kit"]
    remote_out = f"~/{remote_root}/out/{out.name}"
    command = (f"cd ~/{remote_root}/cmux && python3 scripts/cmux-next/hot-verify.py look --out {remote_out} "
               f"--started {t0} " + " ".join(shlex.quote(a) if not a.startswith("~/") else a for a in rest))
    code = subprocess.run(["reach", host, command]).returncode
    pull = subprocess.Popen(["reach", host, f"tar -C {remote_out} -cf - ."], stdout=subprocess.PIPE)
    subprocess.run(["tar", "-C", str(out), "-xf", "-"], stdin=pull.stdout)
    pull.wait()
    log(f"receipt: {out}/receipt.json")
    return code


def remote_args(args) -> list[str]:
    out = []
    for flag, value in (("--app", args.app if args.app != DEFAULT_APP else None), ("--side", args.side),
                        ("--before-ref", args.before_ref), ("--themes", args.themes)):
        if value:
            out += [flag, value]
    if args.state:
        out += ["--state", args.state]  # a path on HOST
    if args.no_video:
        out.append("--no-video")
    return out


def reach(host: str, command: str) -> str:
    done = subprocess.run(["reach", host, command], capture_output=True, text=True)
    if done.returncode != 0:
        raise RuntimeError(f"reach {host}: {(done.stderr or done.stdout).strip()[-400:]}")
    return done.stdout


# ---------------------------------------------------------------- fetch-nightly, stop


def fetch_nightly(out: Path) -> Path:
    import urllib.request
    import xml.etree.ElementTree as ET
    request = urllib.request.Request(FEED, headers={"User-Agent": "cmux-hot-verify/1"})
    with urllib.request.urlopen(request, timeout=60) as answer:
        feed = ET.fromstring(answer.read())
    enclosure = feed.find("./channel/item/enclosure")
    url, length = enclosure.get("url"), int(enclosure.get("length"))
    version = url.rsplit("-", 1)[-1].removesuffix(".dmg")
    target = out / version
    found = sorted(target.glob("*.app")) if target.is_dir() else []
    if found:
        return found[0]
    target.mkdir(parents=True, exist_ok=True)
    dmg = target / "nightly.dmg"
    with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "cmux-hot-verify/1"}),
                                timeout=600) as answer, open(dmg, "wb") as handle:
        shutil.copyfileobj(answer, handle)
    if dmg.stat().st_size != length:
        raise RuntimeError(f"{url}: {dmg.stat().st_size} bytes, the appcast says {length}")
    mount = Path(tempfile.mkdtemp(prefix="hot-verify-dmg."))
    subprocess.run(["hdiutil", "attach", "-nobrowse", "-readonly", "-mountpoint", str(mount), str(dmg)],
                   check=True, capture_output=True)
    try:
        for app in mount.glob("*.app"):
            subprocess.run(["ditto", str(app), str(target / app.name)], check=True)
    finally:
        subprocess.run(["hdiutil", "detach", str(mount)], capture_output=True)
        dmg.unlink()
    app = sorted(target.glob("*.app"))[0]
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    return app


def stop(name: str) -> int:
    with contextlib.suppress(RuntimeError):
        env = side_env(name)
        subprocess.run([str(OVERLAY), "server", "off"], env={**os.environ, **env}, capture_output=True)
    print(side("stop", name, check=False))
    return 0


# ---------------------------------------------------------------- main


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("plan")
    p.add_argument("--source", required=True)
    p.add_argument("--app", default=DEFAULT_APP)
    p.add_argument("--base", help="stand in for the app's commit (no app needed)")
    p.add_argument("--repo", default=str(ROOT))
    p.add_argument("--json", action="store_true")
    p = sub.add_parser("look")
    p.add_argument("--source", required=True)
    p.add_argument("--app", default=DEFAULT_APP)
    p.add_argument("--repo", default=str(ROOT))
    p.add_argument("--side")
    p.add_argument("--state", help="a nightly_steps.py steps file for the click-through")
    p.add_argument("--out")
    p.add_argument("--watch", action="store_true")
    p.add_argument("--before-ref", help="before shots with the web of REF (a merged PR's parent)")
    p.add_argument("--themes", help=f"LIGHT,DARK app themes (default {','.join(DEFAULT_THEMES)})")
    p.add_argument("--no-video", action="store_true")
    p.add_argument("--kit", help="cmuxterm-hq build-fleet/pr_capture (CuaDriver shots, steps, recording)")
    p.add_argument("--host", help="run the look on this fleet Mac (reach HOST); the out folder comes back")
    p.add_argument("--started", type=float, help="epoch seconds the source was pushed or made ready")
    p = sub.add_parser("fetch-nightly")
    p.add_argument("dir")
    p = sub.add_parser("stop")
    p.add_argument("--side", required=True)
    args = parser.parse_args(argv)
    try:
        if args.command == "plan":
            kind, value = parse_source(args.source)
            source = resolve_source(kind, value, Path(args.repo).resolve())
            app = Path(args.app) if not args.base else None
            planned = make_plan(source, app, args.base)
            planned["marker"] = marker(source.get("marker_sha"), planned.get("app_commit"), planned["layers"],
                                       source["receipt_source"])
            if args.json:
                print(json.dumps(planned, indent=2))
            else:
                print(f"layers: {','.join(planned['layers']) or 'none'}")
                print(f"needs_build: {'true' if planned['needs_build'] else 'false'}")
                for why, paths in planned["build"].items():
                    print(f"  {why}: {', '.join(paths[:5])}{' ...' if len(paths) > 5 else ''}")
                if planned.get("build_command"):
                    print(f"build: {planned['build_command']}")
                for note in planned["notes"]:
                    print(f"note: {note}")
            return 0
        if args.command == "look":
            if args.host:
                return remote(args)
            return look(args)
        if args.command == "fetch-nightly":
            print(fetch_nightly(Path(args.dir).expanduser().resolve()))
            return 0
        if args.command == "stop":
            return stop(args.side)
    except ValueError as error:
        print(f"hot-verify: {error}", file=sys.stderr)
        return 2
    except RuntimeError as error:
        print(f"hot-verify: {error}", file=sys.stderr)
        return 1
    return 2


if __name__ == "__main__":
    signal.signal(signal.SIGPIPE, signal.SIG_DFL)
    sys.exit(main())
