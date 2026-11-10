#!/usr/bin/env python3
"""Apply a merged feat-cmux-next commit's web and Rust parts to a running cmux NEXT app, no new build.

    hot-apply.py plan SHA [--app APP] [--repo DIR]
    hot-apply.py apply SHA [--app APP] [--repo DIR] [--parts web,rust] [--socket P] [--acpmux-home H]...
                       [--restart-acpmux]
    hot-apply.py rollback [--app APP] [--socket P]
    hot-apply.py status

Leo, 2026-11-06: "how much of this needs a nightly versus, like, us being able to do the hot swap
thing?" This puts the parts of a merged commit that need no app build into the app that runs now,
from what feat-cmux-next already published for that commit. Nothing builds here.

`plan` reads the app's commit (CMUXCommit in its Info.plist) and sorts `git diff APP_COMMIT SHA`
with live_apply.py's rules:

  web    webviews/ changed and SHA's web ABI (webviews/src/web-abi.json) equals the app's: the
         bundles published for SHA's source key (fetch-web-bundles.sh) go into the app's web
         overlay (web-overlay.sh install), and every open page reloads onto them
  rust   SHA's cmux-tui tree key differs from the app's and no Rust the app links (its FFI
         crates, scripts/ci/cmux_next_route.py) changed: the cmux binary published for SHA's tree
         key (files.cmux.com/cmux-tui/tree/KEY, sha256 from its completion.json) replaces the
         app's Contents/Resources/bin/cmux, with the companions bundled beside it (cmux-app-host,
         cmux-cloud, cmux-browser-host, cmux-tui-host, cmux-holder, the screen detector) from the
         same build, or removed where that build has none; then the app's daemon is handed to it the way the app
         hands off its own (rust-live.py's Swapper: same app pid, terminals kept). bin/cmux is
         also cmux-tui and acpmux (one multi-call binary), so `cmux link`, the CLI in the app's
         terminals and every acpmux daemon started after it run SHA's build. A running acpmux
         daemon keeps its build until it restarts: --acpmux-home H restarts the one of H, and
         --restart-acpmux restarts every acpmux daemon running from the app's bin folder (each
         `acpmux daemon run` or `cmux acp daemon run` there whose socket's `daemon status` names its
         pid), so the agent daemon swaps too: `daemon restart` keeps hosted sessions, which resume
         on the new build. Each restarts with its own launch environment, read from the process (its
         Chief home, Computer Use socket and policy stay). A daemon a restart would cost its chats
         (a memory store without agent hosts) or whose environment is unreadable is left, and the
         receipt lists every acpmux daemon left on the old build, with why.
  left   what needs a new app: Swift, resources and manifests, Rust the app links, a web ABI
         change, and the helpers the app bundles from cmux-tui crates (cmux-mobile-host; these
         keep the app's build while the daemon part still applies)

SHA must be at or after the app's commit on its history: the swapped parts carry every change
between the two, not only SHA's own. A SHA the app already contains is a no-op.

--branch takes a branch head instead (try-pr.sh passes a pull request's): one branched before the
app's commit is sorted from the fork, and its Rust part applies only when the app's cmux-tui tree
is the fork's, so the app has no Rust the branch lacks. Its web part is left to try-pr.sh, which
serves the branch's web with web-overlay.sh follow (a branch has no published bundles).

`plan` says whether CI published SHA's tree (`published`). `apply --binary PATH` swaps in PATH, a
cmux built for SHA some other way, instead of the published one.

`apply` applies the parts (`--parts` picks; default every part `plan` finds) and checks each:
the app's bin/cmux hashes to the published sha256, a new daemon owner answers from it, and the
overlay's manifest names SHA. A failed check puts back what was there before (exit 1). The last
line on stdout is the receipt, as JSON; it is also kept in the state folder (last.json and
history.jsonl), which `rollback` reads to put back the build and overlay that ran before the last
apply, checked the same way, and the acpmux daemons --acpmux-home restarted. A part that does not
go back stays in the receipt's `undo`, and `rollback` tries it again. `status` prints the last receipt.

The daemon is found from the app: the process running from APP's bin folder whose socket answers
`server status` with its own pid (--socket names it instead). For a side instance, run
`eval "$(scripts/cmux-next/side-instance.sh env NAME)"` first so the overlay is that copy's.

Replacing bin/cmux breaks the app bundle's seal until `rollback` puts the same bytes back or the
next update replaces the bundle. The running app is not affected; macOS checks the seal again only
when it assesses the app (a first launch from a quarantined download).

Exit 0: applied and checked (or nothing to apply). 1: a check failed (rolled back). 2: usage.
3: nothing here can apply SHA (an unpublished artifact, an unrelated commit, only `left` parts).
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import importlib.util
import json
import os
import platform
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(ROOT / "scripts/ci"))
import live_apply  # noqa: E402

TUI_BASE = os.environ.get("CMUX_HOT_APPLY_TUI_BASE") or "https://files.cmux.com/cmux-tui/tree"
# The commit-addressed builds a tree's source.json names, which publish its companions.
COMMIT_BASE = os.environ.get("CMUX_HOT_APPLY_COMMIT_BASE") or TUI_BASE.rsplit("/", 1)[0]
# The executables the app bundles beside bin/cmux from the same build (bundle-cmux-tui.sh
# place_companion): (the published artifact, the file in bin/). The daemon runs each sibling of
# its own executable, so they go in with bin/cmux, or go away when the build has none, as there.
COMPANIONS = (("app-host", "cmux-app-host"), ("cloud-server", "cmux-cloud"), ("browser-host", "cmux-browser-host"),
              ("host", "cmux-tui-host"), ("holder", "cmux-holder"),
              ("agent-screen-detection", "cmux-agent-screen-detection"))
WEB_BASE = os.environ.get("CMUX_WEB_BUNDLES_BASE") or "https://files.cmux.com/cmux-next-web"
DEFAULT_APP = "/Applications/cmux NIGHTLY.app"
BIN = "Contents/Resources/bin"
APP_ABI = "Contents/Resources/CmuxNext_CmuxNextPages.bundle/Contents/Resources/pages/web-abi.json"
SHA = re.compile(r"[0-9a-f]{40}")
# What a temporary checkout of SHA needs to compute its web source key (web-bundle-key.py reads
# the files): everything but the large folders no web bundle imports.
WEB_KEY_SPARSE = ["/*", "!/cmux-next-ios/", "!/web/", "!/cmux-tui/crates/", "!/ghostty/"]


def load(name: str, file: str):
    spec = importlib.util.spec_from_file_location(name, HERE / file)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module  # its dataclasses look their module up by name
    spec.loader.exec_module(module)
    return module


def log(message: str) -> None:
    print(f"hot-apply: {message}", file=sys.stderr, flush=True)


def state_dir() -> Path:
    if os.environ.get("CMUX_HOT_APPLY_STATE_DIR"):
        return Path(os.environ["CMUX_HOT_APPLY_STATE_DIR"])
    if sys.platform == "darwin":
        return Path.home() / "Library/Caches/cmux-next/hot-apply"
    return Path(os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache") / "cmux-next/hot-apply"


def git(repo: Path, *args: str, check: bool = True) -> str:
    done = subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True, errors="replace")
    if check and done.returncode != 0:
        raise RuntimeError(f"git {' '.join(args)}: {done.stderr.strip()[:300]}")
    return done.stdout.strip() if done.returncode == 0 else ""


def have_commit(repo: Path, sha: str) -> bool:
    """SHA is in REPO, fetched from origin when it is not yet."""
    def present() -> bool:
        return subprocess.run(["git", "-C", str(repo), "cat-file", "-e", f"{sha}^{{commit}}"],
                              capture_output=True).returncode == 0
    if present():
        return True
    subprocess.run(["git", "-C", str(repo), "fetch", "-q", "origin", sha], capture_output=True)
    return present()


def is_ancestor(repo: Path, older: str, newer: str) -> bool:
    return subprocess.run(["git", "-C", str(repo), "merge-base", "--is-ancestor", older, newer]).returncode == 0


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def fetch(url: str) -> bytes:
    # files.cmux.com answers Python's default user agent (Python-urllib/...) with 403.
    request = urllib.request.Request(url, headers={"User-Agent": "cmux-hot-apply/1"})
    with urllib.request.urlopen(request, timeout=300) as answer:
        return answer.read()


def app_commit(app: Path, repo: Path = ROOT) -> str:
    """The app's commit as a full sha. A nightly stamps CMUXCommit with the short one (nightly.yml)."""
    with open(app / "Contents/Info.plist", "rb") as handle:
        commit = str(plistlib.load(handle).get("CMUXCommit") or "")
    if not re.fullmatch(r"[0-9a-f]{7,40}", commit):
        raise RuntimeError(f"{app} has no CMUXCommit (a DEV build): nothing to compare SHA with")
    if not SHA.fullmatch(commit):
        def resolve() -> str:
            return git(repo, "rev-parse", "--verify", "--quiet", f"{commit}^{{commit}}", check=False)
        full = resolve()
        if not SHA.fullmatch(full):
            # A short sha cannot be fetched by itself: the branch the nightly was cut from can.
            shallow = git(repo, "rev-parse", "--is-shallow-repository", check=False) == "true"
            subprocess.run(["git", "-C", str(repo), "fetch", "-q", *(["--unshallow"] if shallow else []),
                            "origin", "feat-cmux-next"], capture_output=True)
            full = resolve()
        if not SHA.fullmatch(full):
            raise RuntimeError(f"{app}'s CMUXCommit {commit} is not one commit in {repo} (fetch feat-cmux-next)")
        commit = full
    return commit


def app_abi(app: Path) -> int | None:
    try:
        return json.loads((app / APP_ABI).read_text())["abi"]
    except (OSError, ValueError, KeyError):
        return None


def tree_key(repo: Path, sha: str) -> str:
    done = subprocess.run([sys.executable, str(ROOT / "scripts/ci/cmux_tui_tree_key.py"), "--version", "v2", sha],
                          cwd=repo, capture_output=True, text=True)
    key = done.stdout.strip()
    if done.returncode != 0 or not SHA.fullmatch(key):
        raise RuntimeError(f"no cmux-tui tree key for {sha}: {done.stderr.strip()[:300]}")
    return key


def linked_rust(repo: Path, paths: list[str]) -> list[str]:
    """The changed Rust paths the app links through FFI: those need a new app."""
    import cmux_next_route as route
    inputs = [p for p in route.SWIFT_JOB_INPUTS if p.startswith("cmux-tui/")] + list(route.app_ffi_inputs(repo))
    return [p for p in paths if any(p == i or p.startswith(i.rstrip("/") + "/") for i in inputs)]


def helper_rust(repo: Path, paths: list[str]) -> list[str]:
    """The changed Rust paths the app's other bundled helpers build from (the mobile host, the diff
    sidecar): those helpers keep the app's build."""
    import cmux_next_route as route
    inputs = [i for i in route.scheme_phase_rust_inputs(repo) if not i.endswith(("Cargo.lock", "Cargo.toml"))]
    return [p for p in paths if any(p == i or p.startswith(i.rstrip("/") + "/") for i in inputs)]


def plan(repo: Path, app: Path, sha: str, branch: bool = False) -> dict:
    base = app_commit(app, repo)
    for commit in (base, sha):
        if not have_commit(repo, commit):
            raise RuntimeError(f"{commit} is not in {repo} (fetch feat-cmux-next)")
    out = {"sha": sha, "base": base, "app": str(app), "parts": [], "left": {}, "notes": []}
    if is_ancestor(repo, sha, base):
        out["notes"].append("the app already contains SHA")
        return out
    since = base
    if not is_ancestor(repo, base, sha):
        fork = git(repo, "merge-base", base, sha, check=False)
        # --branch: SHA is a pull request's head, branched before the app's commit. Its daemon fits the
        # app when the app has no Rust the branch lacks: the app's cmux-tui tree is the one at the fork.
        # Only the Rust part is taken then; the app's newer Swift and web stay as they are.
        if not branch or not SHA.fullmatch(fork):
            out["left"]["unrelated"] = [f"{sha} is not after the app's commit {base}"]
            return out
        if tree_key(repo, fork) != tree_key(repo, base):
            out["left"]["unrelated"] = [f"the app's commit {base} has Rust that {sha} (branched at {fork}) lacks"]
            return out
        since = fork
        out["fork"] = fork
    result = live_apply.classify_range(str(repo), since, sha)
    files = result["files"]
    for kind in ("swift-live", "rebuild"):
        if files.get(kind):
            out["left"][kind] = files[kind]
    web = files.get("web-live", [])
    if web and branch:
        # A branch's web is not published: try-pr.sh serves it from the branch (web-overlay.sh follow).
        out["left"]["web (not published for a branch)"] = web
    elif web:
        want = json.loads(git(repo, "show", f"{sha}:webviews/src/web-abi.json"))["abi"]
        have = app_abi(app)
        if have == want:
            out["parts"].append("web")
        else:
            out["left"]["web ABI"] = [f"SHA's web needs ABI {want}, the app has {have}"]
    rust = files.get("daemon", [])
    if rust:
        linked = linked_rust(repo, rust)
        out["tree_key"], out["base_tree_key"] = tree_key(repo, sha), tree_key(repo, since)
        if linked:
            out["left"]["Rust the app links (FFI)"] = linked
        elif out["tree_key"] != out["base_tree_key"]:
            out["parts"].append("rust")
            out["published"] = published(out["tree_key"])
            helpers = helper_rust(repo, rust)
            if helpers:
                # The daemon part still applies; the helpers built from these files keep the app's build.
                out["left"]["bundled helpers (cmux-mobile-host, ...)"] = helpers
    return out


# ---------------------------------------------------------------- rust: the app's bin/cmux


def triple() -> str:
    arch = "aarch64" if platform.machine() in ("arm64", "aarch64") else "x86_64"
    return f"{arch}-apple-darwin" if sys.platform == "darwin" else f"{arch}-unknown-linux-musl"


def published(key: str) -> bool:
    """CI published the cmux binaries of tree KEY (its completion.json is there)."""
    try:
        return json.loads(fetch(f"{TUI_BASE}/{key}/completion.json")).get("key") == key
    except (OSError, ValueError):  # urllib's errors are OSErrors: a 404 is an unpublished tree
        return False


def fetch_cmux(key: str, state: Path) -> tuple[Path, str]:
    """SHA's cmux binary for this host, checked against the tree's completion.json and .sha256."""
    name = f"cmux-tui-{triple()}"
    completion = json.loads(fetch(f"{TUI_BASE}/{key}/completion.json"))
    if completion.get("key") != key:
        raise RuntimeError(f"{TUI_BASE}/{key}/completion.json names key {completion.get('key')}")
    want = completion.get("binaries", {}).get(name)
    published = fetch(f"{TUI_BASE}/{key}/{name}.sha256").decode().split()[0]
    if not want or want != published:
        raise RuntimeError(f"{name}: completion.json says {want}, {name}.sha256 says {published}")
    copy = state / "builds" / want / "cmux"
    if not copy.is_file() or sha256_file(copy) != want:
        body = fetch(f"{TUI_BASE}/{key}/{name}")
        if hashlib.sha256(body).hexdigest() != want:
            raise RuntimeError(f"{TUI_BASE}/{key}/{name} does not hash to {want}")
        copy.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile(dir=copy.parent, delete=False) as part:
            part.write(body)
        os.chmod(part.name, 0o755)
        os.replace(part.name, copy)
    return copy, want


def fetch_companions(key: str, state: Path) -> dict[str, tuple[Path, str] | None]:
    """The companions of tree KEY's build for this host, each checked against the sha256 of the
    commit-addressed manifest its source.json names; None for one that build published none of."""
    owner = json.loads(fetch(f"{TUI_BASE}/{key}/source.json")).get("commit") or ""
    if not SHA.fullmatch(owner):
        raise RuntimeError(f"{TUI_BASE}/{key}/source.json names no commit, so its companions are unknown")
    binaries = json.loads(fetch(f"{COMMIT_BASE}/{owner}/manifest.json")).get("binaries", {})
    out: dict[str, tuple[Path, str] | None] = {}
    for artifact, file in COMPANIONS:
        asset = f"cmux-tui-{artifact}-{triple()}"
        want = binaries.get(asset)
        if not want:
            out[file] = None
            continue
        copy = state / "builds" / want / file
        if not copy.is_file() or sha256_file(copy) != want:
            body = fetch(f"{COMMIT_BASE}/{owner}/{asset}")
            if hashlib.sha256(body).hexdigest() != want:
                raise RuntimeError(f"{COMMIT_BASE}/{owner}/{asset} does not hash to {want}")
            copy.parent.mkdir(parents=True, exist_ok=True)
            with tempfile.NamedTemporaryFile(dir=copy.parent, delete=False) as part:
                part.write(body)
            os.chmod(part.name, 0o755)
            os.replace(part.name, copy)
        out[file] = (copy, want)
    return out


def local_companions(binary: Path, state: Path) -> dict[str, tuple[Path, str] | None]:
    """The companions beside a cmux built elsewhere (--binary: a dev build's bin/)."""
    return {file: keep(state, binary.parent / file) if (binary.parent / file).is_file() else None
            for _, file in COMPANIONS}


def place_companions(app: Path, companions: dict[str, tuple[Path, str] | None], state: Path) -> dict:
    """Puts each companion beside bin/cmux, or removes the app's when the build has none; returns
    what was there before, by file (None: absent), for put_back."""
    prior: dict = {}
    for file, new in companions.items():
        target = app / BIN / file
        if target.is_symlink() or (not target.exists() and new is None):
            continue  # a link (cmux-tui, acpmux) follows bin/cmux; nothing to remove
        prior[file] = dict(zip(("copy", "sha256"), map(str, keep(state, target)))) if target.is_file() else None
        if new is None:
            target.unlink()
            continue
        # Renamed into place: a rewritten Mach-O keeps a stale code signature.
        staged = target.with_name(f".{file}.hot-apply")
        shutil.copy2(new[0], staged)
        staged.chmod(0o755)
        os.replace(staged, target)
        if sha256_file(target) != new[1]:
            raise RuntimeError(f"{target} does not hash to {new[1]}")
    return prior


def restore_companions(app: Path, prior: dict) -> None:
    for file, was in prior.items():
        target = app / BIN / file
        if was is None:
            target.unlink(missing_ok=True)
            continue
        staged = target.with_name(f".{file}.hot-apply")
        shutil.copy2(was["copy"], staged)
        staged.chmod(0o755)
        os.replace(staged, target)
        if sha256_file(target) != was["sha256"]:
            raise RuntimeError(f"{target} does not hash to {was['sha256']}")


def keep(state: Path, path: Path) -> tuple[Path, str]:
    """A copy of `path` by its sha256 under the state folder, so a rollback has its bytes."""
    digest = sha256_file(path)
    copy = state / "builds" / digest / "cmux"
    if not copy.is_file():
        copy.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, copy)
    return copy, digest


# The names bin/cmux runs as that serve `server status`. acpmux is the same file under another name
# (bin/acpmux links to it) and serves another protocol, which never answers `server status`.
DAEMON_NAMES = ("cmux", "cmux-tui")


def app_pids(app: Path, names: tuple[str, ...] | None = None) -> list[str]:
    """The processes running an executable from APP's bin folder: by the executable's path (`comm`,
    as side-instance.sh finds a copy's), or by argv[0] for a process whose comm is cut short. With
    NAMES, only those that run as one of them (the program name after the bin folder)."""
    prefixes = {str(app / BIN) + "/", str((app / BIN).resolve()) + "/"}
    bin_dir = os.path.realpath(app / BIN)
    found = []
    for field in ("comm", "command"):
        ps = subprocess.run(["ps", "-axww", "-o", f"pid=,{field}="], capture_output=True, text=True).stdout
        for line in ps.splitlines():
            pid, _, rest = line.strip().partition(" ")
            rest = rest.strip()
            # A process may name the folder through a link (macOS: the app daemon as /tmp/..., the copy
            # given as /private/tmp/...), so its bin folder is compared resolved.
            # Every place the segment appears is tried: a folder above the app may hold it too.
            marker, cut, starts = f"/{BIN}/", -1, []
            while (cut := rest.find(marker, cut + 1)) >= 0:
                starts.append(cut)
            cut = next((c for c in starts if os.path.realpath(rest[:c + len(BIN) + 1]) == bin_dir), -1)
            if pid in found or not rest.startswith("/") or cut < 0:
                continue
            # Program names have no spaces, so the name ends at the first one (the app path may have some).
            if names is None or rest[cut + len(BIN) + 2:].split(" ", 1)[0] in names:
                found.append(pid)
    # Linux: a daemon re-run through /proc/self/exe shows only its basename in comm and argv, but
    # /proc/PID/exe still names the file (" (deleted)" once a swap renamed a build over it).
    proc = Path("/proc")
    if proc.is_dir():
        for entry in proc.iterdir():
            if not entry.name.isdigit() or entry.name in found:
                continue
            try:
                exe = os.readlink(entry / "exe").removesuffix(" (deleted)")
            except OSError:
                continue
            if not any(exe.startswith(prefix) for prefix in prefixes):
                continue
            if names is not None:
                # exe resolves the acpmux link to cmux: the name it runs as is argv[0]'s.
                try:
                    argv0 = (entry / "cmdline").read_bytes().split(b"\0", 1)[0].decode(errors="replace")
                except OSError:
                    continue
                if os.path.basename(argv0) not in names:
                    continue
            found.append(entry.name)
    return found


def find_sockets(app: Path, cli: Path) -> list[str]:
    """The sockets of the daemons running from APP's bin folder: processes there whose unix socket
    answers `server status` with that process's pid, the app's own session (`cmux-app...`) first;
    the app also runs other sessions' daemons from the same file (its chief's). A socket that never
    answered means a daemon may run there, and raises rather than pass for none."""
    hung, found = [], []
    for pid in app_pids(app, DAEMON_NAMES):
        lsof = subprocess.run(["lsof", "-a", "-p", pid, "-U", "-Fn"], capture_output=True, text=True).stdout
        for name in sorted({entry[1:] for entry in lsof.splitlines() if entry.startswith("n/")}):
            try:
                status = subprocess.run([str(cli), "--socket", name, "--json", "server", "status"],
                                        capture_output=True, text=True, timeout=10)
            except subprocess.TimeoutExpired:
                hung.append(name)
                continue
            if re.search(rf'"pid"\s*:\s*{pid}\b', status.stdout):
                found.append(name)
                break
    # The app's own session must answer: a hung one is not passed over for another session's.
    if hung and (not found or any(Path(name).name.startswith("cmux-app") for name in hung)):
        raise RuntimeError(f"`server status` never answered on {', '.join(sorted(hung))}: the daemon running "
                           f"from {app} is not known; nothing changed (--socket names it)")
    return sorted(found, key=lambda name: not Path(name).name.startswith("cmux-app"))


def find_socket(app: Path, cli: Path) -> str | None:
    """The socket of the app's own daemon running from APP's bin folder; None when none runs."""
    found = find_sockets(app, cli)
    return found[0] if found else None


def swap_cmux(app: Path, new: Path, want: str, socket: str | None, state: Path) -> dict:
    """bin/cmux becomes `new` (sha256 `want`) and the app's daemon is handed to it; checked."""
    target = (app / BIN / "cmux").resolve()
    swapper_cls = load("rust_live", "rust-live.py").Swapper
    try:
        running = find_sockets(app, target)
    except RuntimeError:
        if not socket:
            raise
        running = [socket]  # --socket names the daemon; the others are not known
    socket = socket or (running[0] if running else None)
    step: dict = {"file": str(target), "to": want, "socket": socket}
    # Only the app's own daemon is handed off. Another session's (the chief's) keeps the build it
    # mapped until its owner restarts; the receipt names it.
    if others := [name for name in running if name != socket]:
        step["left_on_old_build"] = others
    t0 = time.monotonic()
    if socket is None:
        # No daemon runs from this app: the file alone, which the app's next ensure runs.
        staged = target.with_name(f".{target.name}.hot-apply")
        shutil.copy2(new, staged)
        staged.chmod(0o755)
        os.replace(staged, target)
        step["daemon"] = "none running; the next start runs it"
    else:
        swapper = swapper_cls(None, socket, state=state / "handoff")
        owner = swapper.owner(target)
        if owner is None:
            raise RuntimeError(f"no daemon answers on {socket}")
        if swapper.app_file(owner[1]) != target:
            raise RuntimeError(f"the daemon on {socket} runs {owner[1]}, not {target}: not this app's")
        swapper.app_handoff(new, owner[0], target)
        now = swapper.owner(target, timeout=10)
        step.update(old_pid=owner[0], new_pid=now[0] if now else None, daemon="app handoff")
        if not now or now[0] == owner[0]:
            raise RuntimeError(f"no new daemon owner answered on {socket} after the handoff")
    step["seconds"] = round(time.monotonic() - t0, 3)
    have = sha256_file(target)
    step["running_sha256"] = have
    if have != want:
        raise RuntimeError(f"{target} hashes to {have}, not {want}")
    return step


def acpmux_status(app: Path, **where: str) -> dict:
    """`acpmux daemon status` of one daemon, by ACPMUX_SOCKET or ACPMUX_HOME; {} when none answers."""
    env = {k: v for k, v in os.environ.items() if k not in ("ACPMUX_SOCKET", "ACPMUX_HOME")}
    env.update({f"ACPMUX_{k.upper()}": v for k, v in where.items()})
    try:
        out = subprocess.run([str(app / BIN / "acpmux"), "--json", "daemon", "status"], capture_output=True,
                             text=True, env=env, timeout=10).stdout
        status = json.loads(out or "{}")
    except (subprocess.TimeoutExpired, ValueError, OSError):
        return {}
    return status if isinstance(status, dict) else {}


def process_env(pid: int) -> dict[str, str] | None:
    """The environment process PID started with (its own user's process only), or None when unreadable:
    /proc/PID/environ on Linux, KERN_PROCARGS2 on macOS (exec path, argv, then the environment)."""
    environ = Path(f"/proc/{pid}/environ")
    if environ.parent.is_dir():
        try:
            raw = environ.read_bytes().split(b"\0")
        except OSError:
            return None
    elif sys.platform == "darwin":
        import ctypes
        libc = ctypes.CDLL(None, use_errno=True)
        mib = (ctypes.c_int * 3)(1, 49, pid)  # CTL_KERN, KERN_PROCARGS2
        size = ctypes.c_size_t(0)
        if libc.sysctl(mib, 3, None, ctypes.byref(size), None, 0) != 0 or not size.value:
            return None
        buf = ctypes.create_string_buffer(size.value)
        if libc.sysctl(mib, 3, buf, ctypes.byref(size), None, 0) != 0:
            return None
        data = buf.raw[:size.value]
        argc = int.from_bytes(data[:4], sys.byteorder)
        rest = data[4:]
        rest = rest[rest.index(b"\0"):].lstrip(b"\0")  # past the exec path and its padding
        raw = rest.split(b"\0")[argc:]
    else:
        return None
    env: dict[str, str] = {}
    for entry in raw:
        if not entry:
            break  # the environment ends at the first empty string
        key, sep, value = entry.decode(errors="replace").partition("=")
        if sep:
            env[key] = value
    return env


def keeps_its_chats(status: dict) -> bool:
    """As the app's AcpmuxVersionHandoff.keepsItsChats: a daemon keeps its chats across a restart when its
    agents run under agent hosts or its chats are on disk (`store.mode` local); a memory store without agent
    hosts would lose them."""
    store = status.get("store") if isinstance(status.get("store"), dict) else {}
    return bool(status.get("agentHosts")) or store.get("mode") == "local"


def running_acpmux(app: Path) -> list[dict]:
    """The acpmux daemons running from APP's bin folder: each `acpmux daemon run` (or the multi-call
    `cmux acp daemon run`) there, with the home its socket's `daemon status` names when that status names
    the same pid, whether a restart keeps its chats, and whether its launch environment is readable."""
    found = []
    for pid in app_pids(app, ("acpmux", "cmux")):
        command = subprocess.run(["ps", "-ww", "-o", "command=", "-p", pid], capture_output=True, text=True).stdout
        # The program and its arguments after the bin folder (the app path may hold spaces, a program name none).
        program, _, rest = command.rpartition(f"/{BIN}/")[2].strip().partition(" ")
        words = rest.split()
        if not ((program == "acpmux" and words[:2] == ["daemon", "run"])
                or (program == "cmux" and words[:3] == ["acp", "daemon", "run"])):
            continue  # the CLI, an agent host, a terminal daemon or an MCP server: not an acpmux daemon
        lsof = subprocess.run(["lsof", "-a", "-p", pid, "-U", "-Fn"], capture_output=True, text=True).stdout
        for name in sorted({entry[1:] for entry in lsof.splitlines() if entry.startswith("n/")}):
            status = acpmux_status(app, socket=name)
            if str(status.get("pid")) == pid and status.get("home"):
                found.append({"pid": int(pid), "home": str(status["home"]), "build": str(status.get("build", "")),
                              "keeps_chats": keeps_its_chats(status),
                              "env_readable": process_env(int(pid)) is not None})
                break
    return found


def restart_acpmux(app: Path, homes: list[str], before: dict[str, int] | None = None) -> list[dict]:
    """`acpmux daemon restart` in each home; hosted sessions are kept and resume. The new daemon starts from
    the CLI that runs the restart, so the restart runs with the running daemon's own launch environment
    (its Chief home, Computer Use socket, agent launch policy: everything its owner started it with), read
    from the process, never written down. With BEFORE (home -> the pid that ran), each must answer again
    from another pid, else it raises; a home given by --acpmux-home whose daemon's environment cannot be
    read restarts with this process's, as before."""
    done = []
    for home in homes:
        running = acpmux_status(app, home=home)
        own = process_env(int(running["pid"])) if running.get("pid") else None
        if own is None and before and home in before:
            raise RuntimeError(f"cannot read the launch environment of the acpmux daemon in {home}: not restarted")
        env = dict(own if own is not None else os.environ)
        # ACPMUX_SOCKET wins over ACPMUX_HOME: an inherited one would restart another home's daemon.
        env.pop("ACPMUX_SOCKET", None)
        env["ACPMUX_HOME"] = home
        t0 = time.monotonic()
        result = subprocess.run([str(app / BIN / "acpmux"), "daemon", "restart"], capture_output=True, text=True,
                                env=env, timeout=60)
        if result.returncode != 0:
            raise RuntimeError(f"acpmux daemon restart ({home}): {(result.stderr or result.stdout).strip()[:300]}")
        step = {"home": home, "restarted": True, "own_environment": own is not None}
        if before and home in before:
            now = acpmux_status(app, home=home)
            step.update(old_pid=before[home], new_pid=now.get("pid"), build=now.get("build"),
                        seconds=round(time.monotonic() - t0, 3))
            if not now.get("pid") or now.get("pid") == before[home]:
                raise RuntimeError(f"acpmux in {home} did not answer from a new daemon after its restart")
        done.append(step)
    return done


# ---------------------------------------------------------------- web: the app's overlay


def web_key(repo: Path, sha: str) -> str:
    """SHA's web source key, from a temporary sparse checkout of SHA (web-bundle-key.py reads files)."""
    scratch = Path(tempfile.mkdtemp(prefix="hot-apply-web-"))
    tree = scratch / "tree"
    try:
        git(repo, "worktree", "add", "-q", "--detach", "--no-checkout", str(tree), sha)
        git(tree, "sparse-checkout", "set", "--no-cone", *WEB_KEY_SPARSE)
        git(tree, "checkout", "-q", sha)
        # The inputs the key names outside those folders (web/data, a cmux-tui binding) come back.
        named = subprocess.run([sys.executable, str(tree / "scripts/cmux-next/web-bundle-key.py"), str(tree), "--inputs"],
                               capture_output=True, text=True, check=True).stdout.split()
        git(tree, "sparse-checkout", "set", "--no-cone", *WEB_KEY_SPARSE,
            *[f"/{p.rstrip('/')}" for p in named if not p.startswith(":")])
        done = subprocess.run([sys.executable, str(tree / "scripts/cmux-next/web-bundle-key.py"), str(tree), "--source"],
                              capture_output=True, text=True)
        key = done.stdout.strip()
        if done.returncode != 0 or not re.fullmatch(r"[0-9a-f]{64}", key):
            raise RuntimeError(f"no web source key for {sha}: {done.stderr.strip()[:300]}")
        return key
    finally:
        git(repo, "worktree", "remove", "--force", str(tree), check=False)
        shutil.rmtree(scratch, ignore_errors=True)


def overlay_snapshot(live) -> dict:
    """live-apply.py's overlay state, made JSON so a later `rollback` can restore it."""
    snap = live.overlay_state()
    return {"links": snap["links"], "kept": {gen: str(path) for gen, path in snap["kept"].items()},
            "manifest": snap["manifest"],
            "web_dev": base64.b64encode(snap["web_dev"]).decode() if snap["web_dev"] is not None else None}


def overlay_restore(live, saved: dict) -> None:
    live.restore({"links": saved["links"], "kept": {gen: Path(path) for gen, path in saved["kept"].items()},
                  "manifest": saved["manifest"],
                  "web_dev": base64.b64decode(saved["web_dev"]) if saved["web_dev"] is not None else None})


def overlay_commit(live) -> str | None:
    overlay, _ = live.overlay_paths()
    try:
        return json.loads((overlay / "manifest.json").read_text()).get("commit")
    except (OSError, ValueError):
        return None


def apply_web(repo: Path, sha: str, live) -> dict:
    key = web_key(repo, sha)
    out = Path(tempfile.mkdtemp(prefix="hot-apply-bundles-"))
    try:
        fetched = subprocess.run([str(ROOT / "scripts/cmux-next/fetch-web-bundles.sh"), "--key", key, "--out", str(out / "b")],
                                 stdout=subprocess.PIPE, stderr=sys.stderr, text=True)
        if fetched.returncode != 0:
            raise RuntimeError(f"web bundles for key {key} not fetched (exit {fetched.returncode}; 3 is unpublished)")
        installed = subprocess.run([str(ROOT / "scripts/cmux-next/web-overlay.sh"), "install", str(out / "b"), "--commit", sha],
                                   stdout=sys.stderr, stderr=sys.stderr)
        if installed.returncode != 0:
            raise RuntimeError(f"web-overlay.sh install exited {installed.returncode}")
    finally:
        shutil.rmtree(out, ignore_errors=True)
    if overlay_commit(live) != sha:
        raise RuntimeError(f"the overlay's manifest names {overlay_commit(live)}, not {sha}")
    return {"key": key, "commit": sha, "generation": live.generation()}


# ---------------------------------------------------------------- commands


def record(state: Path, receipt: dict) -> None:
    state.mkdir(parents=True, exist_ok=True)
    line = json.dumps(receipt)
    (state / "last.json").write_text(line + "\n")
    with open(state / "history.jsonl", "a") as handle:
        handle.write(line + "\n")
    print(line)


def command_plan(args) -> int:
    out = plan(Path(args.repo), Path(args.app), args.sha, args.branch)
    print(json.dumps(out, indent=2))
    return 0 if out["parts"] or not out["left"] else 3


def command_apply(args) -> int:
    repo, app, state = Path(args.repo), Path(args.app), state_dir()
    t0 = time.monotonic()
    planned = plan(repo, app, args.sha, args.branch)
    parts = [p for p in planned["parts"] if p in args.parts.split(",")]
    receipt = {"action": "apply", **planned, "applied": [], "rolled_back": False, "steps": {},
               "at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
    if not parts:
        receipt["seconds"] = round(time.monotonic() - t0, 3)
        record(state, receipt)
        return 0 if not planned["left"] else 3
    live = load("live_apply_loop", "live-apply.py")
    target = (app / BIN / "cmux").resolve()
    undo: dict = {}
    try:
        if "rust" in parts:
            # --binary: a cmux binary built for SHA elsewhere (try-pr.sh: the PR's fleet dev build).
            if args.binary:
                new, want = keep(state, Path(args.binary))
                companions = local_companions(Path(args.binary), state)
            else:
                new, want = fetch_cmux(planned["tree_key"], state)
                companions = fetch_companions(planned["tree_key"], state)
            prior, prior_sha = keep(state, target)
            undo["rust"] = {"copy": str(prior), "sha256": prior_sha, "companions": {}}
            # Before the handoff, so the new daemon starts the companions of its own build.
            undo["rust"]["companions"] = place_companions(app, companions, state)
            receipt["steps"]["companions"] = {f: (c[1] if c else None) for f, c in companions.items()}
            receipt["steps"]["rust"] = swap_cmux(app, new, want, args.socket, state)
            receipt["steps"]["rust"]["from"] = prior_sha
            receipt["applied"].append("rust")
            daemons = running_acpmux(app) if args.restart_acpmux or not args.acpmux_home else []
            # A daemon whose chats a restart would lose (a memory store without agent hosts), or whose launch
            # environment cannot be read, keeps its build: the receipt names it and why.
            safe = [d for d in daemons if d["keeps_chats"] and d["env_readable"]] if args.restart_acpmux else []
            left = [dict(d, why="not asked (--restart-acpmux)" if not args.restart_acpmux else
                         "its chats would be lost: a memory store without agent hosts" if not d["keeps_chats"] else
                         "its launch environment is unreadable") for d in daemons if d not in safe]
            homes = list(dict.fromkeys(args.acpmux_home + [d["home"] for d in safe]))
            if homes:
                undo["rust"]["acpmux_homes"] = homes
                receipt["steps"]["acpmux"] = restart_acpmux(app, homes, {d["home"]: d["pid"] for d in safe})
            if left:  # they keep the build they mapped
                receipt["steps"]["rust"]["acpmux_left_on_old_build"] = left
        if "web" in parts:
            undo["web"] = overlay_snapshot(live)
            receipt["steps"]["web"] = apply_web(repo, args.sha, live)
            receipt["applied"].append("web")
    except Exception as error:  # noqa: BLE001 - any failed step puts back what ran before
        receipt["error"] = str(error)
        receipt["rolled_back"] = True
        receipt["rollback"] = put_back(app, undo, args.socket, state, live)
        # A part that did not go back stays in `undo`, so `rollback` can try it again.
        receipt["undo"] = {part: undo[part] for part, step in receipt["rollback"].items() if not step.get("ok")}
        receipt["seconds"] = round(time.monotonic() - t0, 3)
        record(state, receipt)
        return 1
    receipt["undo"] = undo
    receipt["seconds"] = round(time.monotonic() - t0, 3)
    record(state, receipt)
    return 0


def put_back(app: Path, undo: dict, socket: str | None, state: Path, live) -> dict:
    """Restores each part in `undo` and checks it; returns what happened to each."""
    out: dict = {}
    if "web" in undo:
        try:
            overlay_restore(live, undo["web"])
            out["web"] = {"ok": True, "commit": overlay_commit(live)}
        except Exception as error:  # noqa: BLE001
            out["web"] = {"ok": False, "error": str(error)}
    if "rust" in undo:
        target = (app / BIN / "cmux").resolve()
        try:
            restore_companions(app, undo["rust"].get("companions") or {})
            if sha256_file(target) == undo["rust"]["sha256"]:
                out["rust"] = {"ok": True, "running_sha256": undo["rust"]["sha256"], "daemon": "unchanged"}
            else:
                out["rust"] = {"ok": True, **swap_cmux(app, Path(undo["rust"]["copy"]), undo["rust"]["sha256"], socket, state)}
            # The acpmux daemons the apply restarted run the applied build: restart them on the prior one.
            if undo["rust"].get("acpmux_homes"):
                out["rust"]["acpmux"] = restart_acpmux(app, undo["rust"]["acpmux_homes"])
        except Exception as error:  # noqa: BLE001
            out["rust"] = {"ok": False, "error": str(error)}
    return out


def command_rollback(args) -> int:
    state = state_dir()
    try:
        last = json.loads((state / "last.json").read_text())
    except (OSError, ValueError):
        print("hot-apply: nothing applied here", file=sys.stderr)
        return 3
    if last.get("action") == "rollback" and not last.get("ok") and last.get("undo"):
        last = {**last, "sha": last["of"]}  # a rollback that did not finish: try its parts again
    elif last.get("action") != "apply" or not last.get("undo"):
        print("hot-apply: the last apply left nothing to put back", file=sys.stderr)
        return 3
    app = Path(args.app or last["app"])
    t0 = time.monotonic()
    done = put_back(app, last["undo"], args.socket, state, load("live_apply_loop", "live-apply.py"))
    receipt = {"action": "rollback", "of": last["sha"], "app": str(app), "steps": done,
               "undo": {part: last["undo"][part] for part, step in done.items() if not step.get("ok")},
               "ok": all(step.get("ok") for step in done.values()), "seconds": round(time.monotonic() - t0, 3),
               "at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
    record(state, receipt)
    return 0 if receipt["ok"] else 1


def command_status(_args) -> int:
    try:
        print((state_dir() / "last.json").read_text().strip())
    except OSError:
        print("hot-apply: nothing applied here")
    return 0


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)
    for name in ("plan", "apply"):
        p = sub.add_parser(name)
        p.add_argument("sha")
        p.add_argument("--app", default=DEFAULT_APP)
        p.add_argument("--repo", default=str(ROOT))
        p.add_argument("--branch", action="store_true",
                       help="SHA is a branch head (a pull request) that may predate the app's commit")
        if name == "apply":
            p.add_argument("--parts", default="web,rust")
            p.add_argument("--binary", help="the cmux binary to swap in, instead of the one published for SHA")
            p.add_argument("--socket")
            p.add_argument("--acpmux-home", action="append", default=[])
            p.add_argument("--restart-acpmux", action="store_true",
                           help="also restart every acpmux daemon running from the app's bin folder (sessions resume)")
    p = sub.add_parser("rollback")
    p.add_argument("--app")
    p.add_argument("--socket")
    sub.add_parser("status")
    args = parser.parse_args(argv)
    if getattr(args, "sha", None) is not None:
        args.sha = git(Path(args.repo), "rev-parse", "--verify", f"{args.sha}^{{commit}}", check=False) or args.sha
        if not SHA.fullmatch(args.sha):
            print(f"hot-apply: {args.sha!r} is not a commit here", file=sys.stderr)
            return 2
    try:
        return {"plan": command_plan, "apply": command_apply, "rollback": command_rollback,
                "status": command_status}[args.command](args)
    except RuntimeError as error:
        print(f"hot-apply: {error}", file=sys.stderr)
        return 3


if __name__ == "__main__":
    sys.exit(main())
