#!/usr/bin/env python3
"""Apply a merged feat-cmux-next commit's web and Rust parts to a running cmux NEXT app, no new build.

    hot-apply.py plan SHA [--app APP] [--repo DIR]
    hot-apply.py apply SHA [--app APP] [--repo DIR] [--parts web,rust,ffi] [--socket P] [--acpmux-home H]...
                       [--restart-acpmux] [--restart-sessions] [--sign-identity ID | --reseal] [--dry-run]
                       [--base COMMIT]
    hot-apply.py prefetch SHA [--app APP | --base COMMIT] [--repo DIR]
    hot-apply.py rollback [--app APP] [--socket P]
    hot-apply.py status
    hot-apply.py live-from SHA [--repo DIR] [--max N]
    hot-apply.py drop-refused-overlay [--app APP]

Leo, 2026-11-06: "how much of this needs a nightly versus, like, us being able to do the hot swap
thing?" This puts the parts of a merged commit that need no app build into the app that runs now,
from what feat-cmux-next already published for that commit. Nothing builds here.

`plan` reads the app's commit (CMUXCommit in its Info.plist) and sorts `git diff APP_COMMIT SHA`
with live_apply.py's rules:

  web    webviews/ changed and SHA's web ABI (webviews/src/web-abi.json) equals the app's: the
         bundles published for SHA's source key (fetch-web-bundles.sh) go into the app's web
         overlay (web-overlay.sh install), and every open page reloads onto them
  rust   SHA's cmux-tui tree key differs from the app's and no Rust the app links (its FFI
         crates, scripts/ci/cmux_next_route.py) changed (the C, Objective-C and Zig sources inside
         cmux-tui count as its Rust: the tree build compiles them into bin/cmux or a companion): the cmux binary published for SHA's tree
         key (files.cmux.com/cmux-tui/tree/KEY, sha256 from its completion.json) replaces the
         app's Contents/Resources/bin/cmux, with the companions bundled beside it (cmux-app-host,
         cmux-cloud, cmux-browser-host, cmux-tui-host, cmux-holder, the screen detector) from the
         same build, or removed where that build has none; then the app's daemon is handed to it the way the app
         hands off its own (rust-live.py's Swapper: same app pid, terminals kept). Another
         session's daemon running from the same bin (a Chief's) keeps its build and is named in the
         receipt (`left_on_old_build`), unless --restart-sessions hands each one over too with
         `server restart` on its socket (terminals kept; its session, launch flags and environment
         carried; not from ssh on macOS), checked like the app's, and `rollback` hands them back. bin/cmux is
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
  ffi    Rust the app links (its FFI crates) changed, and the app carries that Rust as one library,
         Contents/Frameworks/libcmux_app_ffi.dylib: the library of SHA's published cmux-app-ffi
         release replaces it across `cmux app quit --keep-sessions` and a relaunch (a warm swap:
         the daemon and its terminals stay up), once the release is paired with the app (SHA's FFI
         only adds to the release the app's commit pins, and the library exports every symbol the
         app imports). An ad hoc app, or one whose signature disables library validation (a
         NIGHTLY), takes the ad hoc library as is; another Developer ID app loads only libraries of
         its team: --sign-identity signs with that team's identity, --reseal signs the app ad hoc
         too (hot_apply_ffi.py has the rules). The rust part rides with it; without it, both are left.
         A commit that only moves the pin (app-ffi-repin) takes this part too: the app links the
         release its commit pins, which lags its FFI sources, so SHA's pinned release replaces it.
  left   what needs a new app: Swift, resources and manifests, Rust the app links (statically), a web ABI
         change, and the helpers the app bundles from cmux-tui crates (cmux-mobile-host; these
         keep the app's build while the daemon part still applies), and a Rust build not signed as
         the app is: a Team-signed app (a NIGHTLY) holds no install key, so its daemon proves the app
         only by the same team's signature (prover A, cmux-link caller_macos.rs). CI's tree builds
         are ad-hoc signed, so in such an app no connection would be verified, the app would
         register no Cloud credential provider, and the Cloud machine list and every user-origin
         call would fail until rollback (2026-11-15). `plan` reads the published binary's
         signature with two range requests; `apply` checks the file it swaps in. --unsigned-daemon
         takes it anyway and says so. CI also signs each feat-cmux-next tree's darwin build with the
         NEXT nightly's identity (cmux-tui-team-signed.yml, at files.cmux.com/cmux-tui/tree/KEY/
         team-signed/, its completion.json naming the team and each file's sha256): an app signed
         by that team takes that set (plan's `build`, the receipt's steps.build), so the rust part
         reaches a NIGHTLY once it is published, a few minutes after the tree

SHA must be at or after the app's commit on its history: the swapped parts carry every change
between the two, not only SHA's own. A SHA the app already contains is a no-op.

Published keys first. CI publishes each feat-cmux-next commit's hot keys (`keys SHA`, written by
cmux-tui-artifacts.yml to files.cmux.com/cmux-next/hot-keys/SHA.json): its tree key, web source key
and web ABI, and one digest each over the paths and blobs of the files that need a new app (`shell`:
Swift, resources and manifests), the pinned FFI release plus Rust the Swift build reads (`ffi`), the bundled helpers' inputs
(`helpers`) and the web the app serves (`web`; the web key also covers web tests, so it only names
what to fetch), sorted by the same rules as the diff below. When both the app's commit and SHA have
them, `plan` compares the keys and nothing else (`via: published keys`): no fetch of SHA, no diff,
no tree or web key computed here, and no checkout needed past resolving a short CMUXCommit. Equal
`shell` and `ffi` digests mean the two commits differ only in what a hot apply swaps, in either
direction, so an older SHA with the app's shell takes too. The record names the rules that sorted it
(`rules`, live_apply.py's sha256): keys sorted by other rules do not compare, so that pair is diffed. Otherwise (a commit from before the
keys, a branch) `plan` diffs the two commits as it always has.

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

The web undo is what the app served, not the files as they were: when web-dev.json pointed at an
overlay the app refused (its manifest names another web ABI, so the app served its bundled pages),
`rollback` puts back no pointer, the bundled pages, and its receipt says so
(`dropped_refused_pointer`). `plan` names such a pointer in `notes`, and `drop-refused-overlay` drops
it from an install by itself (web-dev.json's server and gallery entries stay).

The daemon is found from the app: the process running from APP's bin folder whose socket answers
`server status` with its own pid (--socket names it instead). For a side instance, run
`eval "$(scripts/cmux-next/side-instance.sh env NAME)"` first so the overlay is that copy's.

Replacing bin/cmux breaks the app bundle's seal until `rollback` puts the same bytes back or the
next update replaces the bundle. The running app is not affected; macOS checks the seal again only
when it assesses the app (a first launch from a quarantined download).

Every receipt carries `phases`, the wall seconds of each phase of the run, and stderr prints them
(`hot-apply: apply 41.2 s: key 30.4, fetch 6.1, ...`). The phases are exclusive (one entered inside
another pauses it), so they add up to the run:

  plan      reading the app's commit and sorting the diff (live_apply.py)
  key       SHA's cmux-tui tree key and web source key (the web key checks SHA out sparsely)
  fetch     downloads from files.cmux.com (a build's files download at once, each hashed as it
            streams in; the web bundle's own sha256 check is inside it)
  verify    the sha256 checks of what was fetched and of what was put in place
  backup    the copies of what the app had, kept for `rollback`
  find      the daemons running from the app (ps, lsof, `server status`)
  swap      the files renamed into place; the web overlay installed
  reload    the daemon handoff until a new owner answers; the acpmux daemons restarted. The app's
            own reload of its pages (on the overlay's manifest.json) is not seen from here.
  quit      ffi: `cmux app quit --keep-sessions` until the app's pid is gone
  launch    ffi: `open APP` until a new pid answers on the app's control socket, then the stay-up check
  rollback  putting back what was there after a failed check

`apply --dry-run` plans, fetches and verifies every part and stops before `backup`: nothing in the
app changes, and the receipt (action `dry-run`) goes only to history.jsonl, never to last.json
(`rollback` never reads it). --base COMMIT stands in for the app's commit (its web ABI is read from
COMMIT's tree), so a host with no app can plan or dry-run.

`prefetch SHA` does what `apply` does up to the swap, and keeps it: SHA's keys, the published
metadata, the cmux build and its companions, and the web bundles, each under the state folder by
content (a key, a commit or a sha256), each checked when it is fetched. A later `apply SHA` then reads
them from there, checks each against the sha256 it was fetched with, and only swaps. Run it once CI
has published SHA (`glaeda-gh wait run` on the publish run, then `prefetch`); try-pr.sh and an agent
that merges can run it right away. A part the app already runs is skipped: a `bin/cmux` (and its
companions) that already hash to SHA's build, and an overlay whose commit has SHA's web key. The
receipt names it under `unchanged`. A build file the cache lacks but the app's bin/ already has (same
sha256) is copied from there, not downloaded. An apply that changed nothing leaves last.json, and so
`rollback`, to the apply before it. The web cache keeps the newest WEB_KEEP keys.

Exit 0: applied and checked (or nothing to apply). 1: a check failed (rolled back). 2: usage.
3: nothing here can apply SHA (an unpublished artifact, an unrelated commit, only `left` parts).
"""
from __future__ import annotations

import argparse
import base64
import concurrent.futures
import contextlib
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
import hot_apply_ffi as ffi_part  # noqa: E402

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
# Each feat-cmux-next commit's hot keys (`keys`), published write-once by cmux-next-hot-keys.yml.
HOT_KEYS_BASE = os.environ.get("CMUX_HOT_KEYS_BASE") or "https://files.cmux.com/cmux-next/hot-keys"
HOT_KEYS_SCHEMA = 2  # 2: `web` also digests the catalogs gen-strings.mjs reads, `shell` no longer does
# Beside each tree, its darwin build signed by the NEXT nightly's team (cmux-tui-team-signed.yml,
# scripts/ci/cmux_tui_team_sign.py): what a Team-signed app takes.
TEAM_SIGNED = "team-signed"
MISSING_KEYS_SECONDS = 3600
DEFAULT_APP = "/Applications/cmux NIGHTLY.app"
BIN = "Contents/Resources/bin"
APP_ABI = "Contents/Resources/CmuxNext_CmuxNextPages.bundle/Contents/Resources/pages/web-abi.json"
SHA = re.compile(r"[0-9a-f]{40}")
# What a temporary checkout of SHA needs to compute its web source key (web-bundle-key.py reads
# the files): everything but the large folders no web bundle imports.
WEB_KEY_SPARSE = ["/*", "!/cmux-next-ios/", "!/web/", "!/cmux-tui/crates/", "!/ghostty/"]


class Phases:
    """Wall seconds per phase of one run, exclusive: a phase entered inside another pauses the outer one,
    so the phases add up to the time they cover."""

    def __init__(self) -> None:
        self.seconds: dict[str, float] = {}
        self.stack: list[str] = []
        self.mark = time.monotonic()

    def _flush(self) -> None:
        now = time.monotonic()
        if self.stack:
            self.seconds[self.stack[-1]] = self.seconds.get(self.stack[-1], 0.0) + now - self.mark
        self.mark = now

    @contextlib.contextmanager
    def __call__(self, name: str):
        self._flush()
        self.stack.append(name)
        try:
            yield
        finally:
            self._flush()
            self.stack.pop()

    def rounded(self) -> dict[str, float]:
        return {name: round(secs, 3) for name, secs in self.seconds.items()}


PHASES = Phases()


WEB_KEEP = 8  # web bundle folders kept under state/web (about 30 MB each)
HEX = re.compile(r"[0-9a-f]{40}|[0-9a-f]{64}")


def write_atomic(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=path.parent, prefix=f".{path.name}.", delete=False) as part:
        part.write(data)
    os.replace(part.name, path)


def remembered(kind: str, sha: str, compute) -> str:
    """A key that is a function of commit SHA alone (its cmux-tui tree key, its web source key), kept
    under state/keys/KIND/SHA after the first time it is computed."""
    path = state_dir() / "keys" / kind / sha
    try:
        value = path.read_text().strip()
        if HEX.fullmatch(value):
            return value
    except OSError:
        pass
    value = compute()
    write_atomic(path, (value + "\n").encode())
    return value


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


def fetch_remote(repo: Path) -> str:
    """origin, or the repo's URL for a checkout with none (a fleet ci-step checkout, as try-pr.sh)."""
    if git(repo, "remote", "get-url", "origin", check=False):
        return "origin"
    return os.environ.get("CMUX_TRY_PR_REMOTE", "https://github.com/manaflow-ai/cmux.git")


def have_commit(repo: Path, sha: str) -> bool:
    """SHA is in REPO, fetched from origin when it is not yet."""
    def present() -> bool:
        return subprocess.run(["git", "-C", str(repo), "cat-file", "-e", f"{sha}^{{commit}}"],
                              capture_output=True).returncode == 0
    if present():
        return True
    subprocess.run(["git", "-C", str(repo), "fetch", "-q", fetch_remote(repo), sha], capture_output=True)
    return present()


def is_ancestor(repo: Path, older: str, newer: str) -> bool:
    return subprocess.run(["git", "-C", str(repo), "merge-base", "--is-ancestor", older, newer]).returncode == 0


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def fetch_kept(url: str, complete=None) -> bytes:
    """fetch(), for a URL whose body never changes once published (a tree key's or a commit's files):
    kept under state/meta by the URL's sha256 after the first answer. A 404 is not kept, and neither
    is a body COMPLETE says lacks what this host needs (a completion.json without this host's binary):
    a kept one like that is fetched again."""
    path = state_dir() / "meta" / hashlib.sha256(url.encode()).hexdigest()
    try:
        body = path.read_bytes()
        if complete is None or complete(body):
            return body
    except OSError:
        pass
    body = fetch(url)
    if complete is None or complete(body):
        write_atomic(path, body)
    return body


def lists_binary(name: str):
    """A completion.json check for fetch_kept: it names NAME's sha256."""
    def check(body: bytes) -> bool:
        try:
            return bool(json.loads(body).get("binaries", {}).get(name))
        except (ValueError, AttributeError):
            return False
    return check


def fetch(url: str, timeout: float = 300) -> bytes:
    # files.cmux.com answers Python's default user agent (Python-urllib/...) with 403.
    request = urllib.request.Request(url, headers={"User-Agent": "cmux-hot-apply/1"})
    with PHASES("fetch"), urllib.request.urlopen(request, timeout=timeout) as answer:
        return answer.read()


# ---------------------------------------------------------------- code signatures

MACHO_LIMIT = 1 << 30  # a published binary is ~150 MB; a stream that runs past this is not one


def code_team(read_at) -> str | None:
    """The Team ID in a Mach-O's code signature (its CodeDirectory's teamID), None for an ad-hoc or
    unsigned one. READ_AT(offset, size) returns those bytes. A fat file is read by its first slice
    (every slice of one build carries the same signature identity). Unreadable means no team."""
    try:
        head = read_at(0, 8)
        base = 0
        if head[:4] in (b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca"):
            base = int.from_bytes(read_at(8 + 8, 4), "big")  # fat_arch[0].offset
            head = read_at(base, 8)
        if head[:4] != b"\xcf\xfa\xed\xfe":  # MH_MAGIC_64, little-endian
            return None
        header = read_at(base, 32)
        ncmds, sizeofcmds = int.from_bytes(header[16:20], "little"), int.from_bytes(header[20:24], "little")
        cmds = read_at(base + 32, min(sizeofcmds, 1 << 20))
        at = 0
        for _ in range(ncmds):
            cmd, size = int.from_bytes(cmds[at:at + 4], "little"), int.from_bytes(cmds[at + 4:at + 8], "little")
            if cmd == 0x1D:  # LC_CODE_SIGNATURE
                offset, length = int.from_bytes(cmds[at + 8:at + 12], "little"), int.from_bytes(cmds[at + 12:at + 16], "little")
                return superblob_team(read_at(base + offset, min(length, 1 << 22)))
            if size <= 0:
                return None
            at += size
    except (OSError, ValueError, IndexError):
        return None
    return None


def superblob_team(blob: bytes) -> str | None:
    count = int.from_bytes(blob[8:12], "big")
    for i in range(count):
        offset = int.from_bytes(blob[12 + 8 * i + 4:12 + 8 * i + 8], "big")
        if blob[offset:offset + 4] != b"\xfa\xde\x0c\x02":  # CSMAGIC_CODEDIRECTORY
            continue
        version = int.from_bytes(blob[offset + 8:offset + 12], "big")
        flags = int.from_bytes(blob[offset + 12:offset + 16], "big")
        team_at = int.from_bytes(blob[offset + 48:offset + 52], "big") if version >= 0x20200 else 0
        if flags & 0x2 or not team_at:  # CS_ADHOC, or no team
            return None
        return blob[offset + team_at:].split(b"\0", 1)[0].decode("ascii", "replace") or None
    return None


def file_team(path: Path) -> str | None:
    try:
        with open(path, "rb") as handle:
            def read_at(offset: int, size: int) -> bytes:
                handle.seek(offset)
                return handle.read(size)
            return code_team(read_at)
    except OSError:
        return None


def url_team(url: str) -> str | None:
    """code_team of a published binary, read with range requests (a few KB, not the binary)."""
    def read_at(offset: int, size: int) -> bytes:
        request = urllib.request.Request(url, headers={"User-Agent": "cmux-hot-apply/1",
                                                       "Range": f"bytes={offset}-{offset + size - 1}"})
        with PHASES("fetch"), urllib.request.urlopen(request, timeout=60) as answer:
            if getattr(answer, "status", 200) == 206:
                return answer.read(size)
            # No range support (file:// in tests): skip to OFFSET in the stream, bounded.
            if offset + size > MACHO_LIMIT:
                raise ValueError("past the size limit")
            skipped = 0
            while skipped < offset:
                chunk = answer.read(min(1 << 20, offset - skipped))
                if not chunk:
                    return b""
                skipped += len(chunk)
            return answer.read(size)
    return code_team(read_at)


def app_team(app: Path) -> str | None:
    """The Team ID that signs APP (its main executable): a Team-signed app holds no install key, so its
    daemon proves the app only by that team's signature (cmux-link caller_macos.rs, prover A)."""
    try:
        with open(app / "Contents/Info.plist", "rb") as handle:
            executable = plistlib.load(handle).get("CFBundleExecutable")
    except (OSError, ValueError):
        return None
    return file_team(app / "Contents/MacOS" / executable) if isinstance(executable, str) and executable else None


def unverifiable(team: str | None, have: str | None, what: str) -> str | None:
    """Why swapping in WHAT (signed by TEAM) leaves a Team-signed app (HAVE) unverified, else None."""
    if have is None or team == have:
        return None
    signed = f"signed by team {team}" if team else "ad-hoc signed (no Team ID)"
    return (f"{what} is {signed}; this app is signed by team {have}. A Team-signed app has no install key, so "
            "its daemon proves the app only by the same team's signature: on this build no app connection is "
            "verified, the app registers no Cloud credential provider, and the Cloud machine list, Cloud starts "
            "and every user-origin call fail (2026-11-15: \"Couldn't read your Cloud machines\" until rollback). "
            "--unsigned-daemon takes it anyway")


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
                            fetch_remote(repo), "+refs/heads/feat-cmux-next:" + BASE_REF], capture_output=True)
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
    # Keyed by the key script too: a new version of the script may compute another key for the same commit.
    script = sha256_file(ROOT / "scripts/ci/cmux_tui_tree_key.py")[:16]
    with PHASES("key"):
        return remembered(f"tree-v2-{script}", sha, lambda: _tree_key(repo, sha))


def _tree_key(repo: Path, sha: str) -> str:
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
    excluded = route.app_ffi_excluded(repo)  # the FFI crates' tests/, benches/, examples/: not linked
    return [p for p in paths if any(p == i or p.startswith(i.rstrip("/") + "/") for i in inputs)
            and not any(p.startswith(d + "/") for d in excluded)]


def ffi_input(repo: Path, path: str) -> bool:
    """PATH is a source of the app FFI library (cmux_next_route.app_ffi_inputs, less what Cargo never builds)."""
    inputs, excluded = ffi_part.ffi_paths(repo)
    return (any(path == i or path.startswith(i.rstrip("/") + "/") for i in inputs)
            and not any(path.startswith(d + "/") for d in excluded))


def swift_read_rust(repo: Path, paths: list[str]) -> list[str]:
    """The Rust inputs the Swift build reads directly, excluding sources in the pinned FFI library."""
    return [p for p in linked_rust(repo, paths) if not ffi_input(repo, p)]


def helper_rust(repo: Path, paths: list[str]) -> list[str]:
    """The changed Rust paths the app's other bundled helpers build from (the mobile host, the diff
    sidecar): those helpers keep the app's build."""
    import cmux_next_route as route
    # Manifests and lockfiles are helper inputs too.  A helper can keep an old binary when its
    # source is unchanged but its dependency graph moves, so every named Cargo input must floor
    # the signed app list just like the source directories do.
    inputs = route.scheme_phase_rust_inputs(repo)
    # The route helper intentionally narrows its Xcode scan to cmux-tui inputs for CI routing. The
    # app also builds the separately bundled diff sidecar from Native/DiffSidecar and cmux-git;
    # collect those explicit manifests here without treating the whole daemon tree as a helper.
    try:
        project = (repo / route.APP_PROJECT).read_text(encoding="utf-8")
    except OSError:
        project = ""
    inputs.extend(path for path in re.findall(r'"\$\(SRCROOT\)/([^"]+Cargo\.(?:toml|lock))"', project)
                  if path not in inputs)
    return [p for p in paths if any(p == i or p.startswith(i.rstrip("/") + "/") for i in inputs)]


# $(SRCROOT) inputs of the app's Xcode project that name a whole tree another layer carries: cmux-tui's daemon is the
# bin/ swap itself (its helper crates are helper_rust's), webviews/ is the web layer, and cmux-next-ios/ is the iPhone
# app, whose one Mac-bundled part, cmux-mobile-host, is read from its build script instead.
CARRIED_ROOTS = ("cmux-tui", "webviews", "cmux-next-ios")
MOBILE_HOST_BUILD = "scripts/cmux-next/build-mobile-host.sh"


def under(path: str, roots: list[str]) -> bool:
    return any(path == r or path.startswith(r + "/") for r in roots)


def bundled_inputs(repo: Path) -> list[str]:
    """The source paths the app bundle builds or copies that `cmux app try`'s bin swap does not replace: every
    $(SRCROOT) input of the app's Xcode project (scripts it copies, Native/DiffSidecar, resources) but the
    CARRIED_ROOTS, plus cmux-mobile-host's own build inputs (build-mobile-host.sh `inputs=(...)`). A change under
    one keeps an older app's copy, so it floors the signed live list like Swift does."""
    import cmux_next_route as route
    try:
        project = (repo / route.APP_PROJECT).read_text(encoding="utf-8")
    except OSError:
        project = ""
    refs = {p.strip("/") for p in re.findall(r'\$\(SRCROOT\)/([A-Za-z0-9_.@+/-]+)', project)}
    out = sorted(p for p in refs if p and p.split("/")[0] not in CARRIED_ROOTS)
    try:
        script = (repo / MOBILE_HOST_BUILD).read_text(encoding="utf-8")
    except OSError:
        script = ""
    if m := re.search(r"^inputs=\(([^)]*)\)", script, re.M):
        out.extend(p.strip("/") for p in m.group(1).split() if p.strip("/"))
    return out


BASE_REF = "refs/remotes/origin/feat-cmux-next"


def pin_on_base(repo: Path, sha: str) -> bool:
    """A branch head SHA pins the app FFI release feat-cmux-next pinned where SHA forked from it: the branch did
    not move the pin itself, so its release is one app-ffi-release.yml published for that merge (fetch_library
    still checks). False when REPO has no feat-cmux-next or the pin is the branch's own."""
    fork = git(repo, "merge-base", sha, BASE_REF, check=False)
    if not SHA.fullmatch(fork):
        return False
    have = git(repo, "rev-parse", "--verify", "--quiet", f"{sha}:{ffi_part.PIN_FILE}", check=False)
    return bool(have) and have == git(repo, "rev-parse", "--verify", "--quiet", f"{fork}:{ffi_part.PIN_FILE}",
                                      check=False)


def set_digest(blobs: dict[str, str], paths: list[str]) -> str:
    """One sha256 over PATHS and their blobs: equal for two commits exactly when none of them changed."""
    return hashlib.sha256("".join(f"{p}\0{blobs[p]}\n" for p in sorted(set(paths))).encode()).hexdigest()


def pinned_ffi_source(repo: Path, sha: str) -> str | None:
    """None only before the pin exists; an unreadable or malformed pin is not compatibility evidence."""
    if not git(repo, "ls-tree", "--name-only", sha, "--", ffi_part.PIN_FILE):
        return None
    return ffi_part.app_pin_source(repo, sha)


def ffi_digest(repo: Path, sha: str, blobs: dict[str, str], daemon: list[str]) -> str:
    """Digest what the app's linked FFI library and Swift build read at SHA.

    FFI sources are built into the separately pinned binary release, so a source edit does not change the
    library an app links until the pin moves. Rust inputs the Swift build reads directly still require an app.
    """
    pin_source = pinned_ffi_source(repo, sha)
    if pin_source is None:
        return set_digest(blobs, linked_rust(repo, daemon))
    entries = [(p, blobs[p]) for p in swift_read_rust(repo, daemon)]
    entries.append((ffi_part.PIN_FILE, pin_source))
    return hashlib.sha256("".join(f"{p}\0{blob}\n" for p, blob in sorted(set(entries))).encode()).hexdigest()


def web_catalogs(repo: Path, sha: str, strings: list[str]) -> tuple[list[str], list[str]]:
    """Split STRINGS (SHA's .xcstrings files) into the catalogs the web pages read and the rest. gen-strings.mjs
    builds every page's strings table from its catalogs at web-build time, and the web source key hashes them
    (web-bundle-key.py), so the bundle published for SHA carries those catalogs' words: they ride the web part.
    The rest (Swift-only catalogs) stay with the Swift build. gen-strings.mjs is read from SHA, not the working tree."""
    if not strings:
        return [], []
    try:
        named = load("web_bundle_key", "web-bundle-key.py").gen_strings_catalogs_in(
            git(repo, "show", f"{sha}:webviews/scripts/pages/gen-strings.mjs")) or []
    except (RuntimeError, OSError):
        named = []  # unreadable: every catalog stays with the Swift build, as before
    # A one-file-per-key table (`<Table>.xcstrings.d`, scripts/cmux-next/string_catalogs.py) is named as its directory.
    def read(p):
        return p in named or any(p.startswith(d.rstrip("/") + "/") for d in named if d.endswith(".xcstrings.d"))
    return [p for p in strings if read(p)], [p for p in strings if not read(p)]


def hot_keys(repo: Path, sha: str, web: str | None = None) -> dict:
    """SHA's hot keys: what `plan` compares instead of diffing two commits. Each key covers one bucket's files
    (live_apply.py's rules applied to every path of SHA's tree, as _plan applies them to a diff), so two commits
    whose `shell` and `ffi` keys are equal differ only in parts a hot apply swaps. The FFI and helper inputs are
    read from REPO's working tree (cmux_next_route.py), so CI runs this on SHA's own checkout."""
    listing = subprocess.run(["git", "-C", str(repo), "ls-tree", "-r", "-z", "--full-tree", sha],
                             capture_output=True, check=True).stdout.decode("utf-8", "replace")
    blobs = {}
    for entry in filter(None, listing.split("\0")):
        meta, path = entry.split("\t", 1)
        blobs[path] = meta.split()[2]
    files = live_apply.classify([("M", p) for p in blobs], {})["files"]
    # cmux-tui's own native sources (a shim, the Zig binding) are daemon in live_apply.py: the tree build compiles them.
    web_strings, swift_strings = web_catalogs(repo, sha, files.get("strings", []))
    shell = files.get("rebuild", []) + files.get("swift-live", []) + swift_strings
    daemon = files.get("daemon", [])
    abi = json.loads(git(repo, "show", f"{sha}:webviews/src/web-abi.json"))["abi"]
    return {"schema": HOT_KEYS_SCHEMA, "commit": sha, "tree_key": _tree_key(repo, sha),
            # `web` decides, `web_key` fetches: the source key also covers files no bundle ships (tests).
            "web": set_digest(blobs, files.get("web-live", []) + web_strings),
            "web_key": web or _web_key(repo, sha), "web_abi": abi, "shell": set_digest(blobs, shell),
            # The app links the FFI release named by its pin, not the current FFI sources. Keep source-only
            # FFI edits out of this key; a repin changes the pin source and therefore the linked library.
            "ffi": ffi_digest(repo, sha, blobs, daemon), "helpers": set_digest(blobs, helper_rust(repo, daemon)),
            "rules": rules_digest()}


def rules_digest() -> str:
    """live_apply.py's own sha256: the rules that sorted SHA's files into the digests above. Two commits' keys
    compare only under the same rules; a rule change (design/ became no-app) would otherwise differ every
    `shell` digest across it and leave a whole NIGHTLY's applies as "Swift, resources and manifests"."""
    return hashlib.sha256(Path(live_apply.__file__).read_bytes()).hexdigest()


def valid_keys(keys, sha: str) -> bool:
    """KEYS is a whole hot-keys record of SHA: every field `keys_plan` reads, well formed."""
    return (isinstance(keys, dict) and keys.get("schema") == HOT_KEYS_SCHEMA and keys.get("commit") == sha
            and type(keys.get("web_abi")) is int
            and all(HEX.fullmatch(str(keys.get(k))) for k in ("tree_key", "web", "web_key", "shell", "ffi", "helpers")))


def published_keys(sha: str) -> dict | None:
    """SHA's hot keys as CI published them (cmux-tui-artifacts.yml, mark-tree-commits), kept under
    state/keys/hot; None when CI has not (a commit before the step, a run that failed) or the record is not
    whole: `plan` then diffs the two commits."""
    path = state_dir() / "keys" / "hot" / f"{sha}.json"
    with contextlib.suppress(OSError, ValueError):
        kept = json.loads(path.read_text())
        if valid_keys(kept, sha):
            return kept
    # A miss is kept for an hour, so the apply after a prefetch (or a commit from before the keys) asks no
    # second time; CI may still publish a new commit's keys after that.
    missing = path.with_suffix(".missing")
    with contextlib.suppress(OSError):
        if time.time() - missing.stat().st_mtime < MISSING_KEYS_SECONDS:
            return None
    keys = None
    with PHASES("key"), contextlib.suppress(urllib.error.URLError, OSError, ValueError):
        keys = json.loads(fetch(f"{HOT_KEYS_BASE}/{sha}.json", timeout=10))  # the diff is the fallback: wait little
    if not valid_keys(keys, sha):
        write_atomic(missing, b"")
        return None
    write_atomic(path, json.dumps(keys).encode())
    return keys


def note_refused(out: dict, app: Path, given_base: bool) -> None:
    """Names a web-dev.json pointer at an overlay the app refuses (it serves its bundled pages instead)."""
    if not given_base and (refused := refused_pointer(app)):
        out["refused_overlay"] = refused
        out["notes"].append(f"web-dev.json points at {refused['overlay']}: {refused['why']}. "
                            "`hot-apply.py drop-refused-overlay` drops that pointer; an apply's web part replaces it")


def daemon_part(out: dict, app: Path, given_base: bool, unsigned: bool) -> None:
    """The Rust part, unless its published build is not signed as the app is: a Team-signed app's daemon
    proves a connection is the app only by that team's signature (prover A), so an ad-hoc daemon verifies
    none and Cloud (its credential provider) fails until rollback."""
    team = None if given_base else app_team(app)
    why = None
    if team and out.get("published"):
        if team_signed(out["tree_key"], team):
            out["build"] = f"team-signed ({team})"
        else:
            name = f"cmux-tui-{triple()}"
            why = unverifiable(url_team(f"{TUI_BASE}/{out['tree_key']}/{name}"), team, f"the published {name}")
    if why and not unsigned:
        out["left"]["Rust (the published build is not signed as this app is)"] = [why]
    else:
        out["parts"].append("rust")
        if why:
            out["notes"].append(f"--unsigned-daemon: {why}")
    out["app_team"] = team


def keys_plan(app: Path, sha: str, base: str, given_base: bool, unsigned: bool = False) -> dict | None:
    """The plan from both commits' published keys, with no checkout of either: None when one is missing."""
    have, want = published_keys(base), published_keys(sha)
    if not have or not want:
        return None
    if have.get("rules") != want.get("rules"):
        return None  # sorted by different live_apply.py rules: the digests do not compare, so the diff plans this pair
    out = {"sha": sha, "base": base, "app": str(app), "parts": [], "left": {}, "notes": [], "via": "published keys"}
    note_refused(out, app, given_base)
    if want["shell"] != have["shell"]:
        out["left"]["Swift, resources and manifests"] = [f"shell key {have['shell'][:12]} -> {want['shell'][:12]}"]
    if want["web"] != have["web"]:
        abi = have["web_abi"] if given_base else app_abi(app)
        if abi == want["web_abi"]:
            out["parts"].append("web")
            # Kept where web_unchanged() looks a commit's key up.
            out["web_key"] = remembered("web", sha, lambda: want["web_key"])
        else:
            out["left"]["web ABI"] = [f"SHA's web needs ABI {want['web_abi']}, the app has {abi}"]
    if want["tree_key"] != have["tree_key"]:
        out["tree_key"], out["base_tree_key"] = want["tree_key"], have["tree_key"]
        if want["ffi"] != have["ffi"]:
            # The app FFI may swap warm (cmux#43548): which files changed decides it (the Swift build's own Rust
            # inputs still need an app), and only the diff knows them, so the diff plans this pair.
            return None
        else:
            out["published"] = published(want["tree_key"])
            daemon_part(out, app, given_base, unsigned)
            if want["helpers"] != have["helpers"]:
                out["left"]["bundled helpers (cmux-mobile-host, ...)"] = [
                    f"helpers key {have['helpers'][:12]} -> {want['helpers'][:12]}"]
    if not out["parts"] and not out["left"]:
        out["notes"].append("the app already runs SHA's parts")
    return out


def plan(repo: Path, app: Path, sha: str, branch: bool = False, base: str | None = None, unsigned: bool = False) -> dict:
    with PHASES("plan"):
        if not branch:
            app_base = base or app_commit(app, repo)
            planned = keys_plan(app, sha, app_base, bool(base), unsigned)
            # The keys compare the pinned release, but a repin also changes package files that keys classify as
            # shell; the diff plan reads both pins to select the ffi part and remove only its packaging changes.
            if planned:
                # Published keys also work without a checkout. When both commits are here, a bad pin must
                # fail rather than masquerade as an unchanged release on that fast path.
                if not (have_commit(repo, app_base) and have_commit(repo, sha)):
                    return planned
                if pinned_ffi_source(repo, app_base) == pinned_ffi_source(repo, sha):
                    return planned
        return _plan(repo, app, sha, branch, base, unsigned)


LIVE_FROM_MAX = 400  # a NIGHTLY is at most a day of merges behind feat-cmux-next


def pins_daemon(repo: Path, commit: str, *, whole_app: bool = False) -> list[str]:
    """The paths of COMMIT's own change that alter what the app links.

    The app links the release named by app-ffi-pin.json, so FFI source edits alone do not pin the daemon to
    a new app. A repin does, as does Rust the Swift build reads outside the FFI release. A root commit pins it.
    For app try's signed list, whole_app also includes every layer its bin-only update cannot carry.
    """
    parent = git(repo, "rev-parse", "--verify", "--quiet", f"{commit}^", check=False)
    if not SHA.fullmatch(parent or ""):
        return [f"{commit} has no parent here"]
    files = live_apply.classify_range(str(repo), parent, commit)["files"]
    daemon = sorted(set(files.get("daemon", [])))
    uncarried = []
    if whole_app:
        uncarried = [path for kind in ("swift-live", "rebuild", "web-live") for path in files.get(kind, [])]
        # Cargo.lock can classify as no-app even though a helper build consumes it. Include the
        # complete diff for matching explicit helper inputs, while leaving unrelated no-app files
        # out of the floor.
        uncarried.extend(helper_rust(repo, daemon + files.get("no-app", [])))
        # The separately bundled helpers share the workspace dependency graph.
        uncarried.extend(path for path in daemon if path in ("cmux-tui/Cargo.toml", "cmux-tui/Cargo.lock"))
        # What the bundle copies or builds beside bin/ (the code-mode runner and other bundled scripts, the diff
        # sidecar's sources, cmux-mobile-host and the crates it links) classifies as no-app, ios-only or daemon,
        # yet an older app keeps its own copy of it.
        bundled = bundled_inputs(repo)
        uncarried.extend(path for kind in ("no-app", "ios-only", "daemon") for path in files.get(kind, [])
                         if under(path, bundled))
    before, after = pinned_ffi_source(repo, parent), pinned_ffi_source(repo, commit)
    if before is None and after is None:
        return sorted(set(uncarried + linked_rust(repo, daemon)))
    paths = uncarried + swift_read_rust(repo, daemon)
    if before != after:
        paths.append(ffi_part.PIN_FILE)
    return sorted(set(paths))


def live_from(repo: Path, sha: str, limit: int = LIVE_FROM_MAX) -> dict:
    """Every app commit that app try can bring to SHA with only its published bin files, newest first.
    Stop at the newest commit changing a layer those files do not carry, or daemon ABI compatibility.
    Include that floor: an app built there already contains that change. Standalone hot-apply's daemon
    compatibility remains separate; it can apply parts and report the other layers as left.
    At most `limit` commits; `floor` is that commit, or None when the walk stopped at the limit. The
    signed Mac live update file names them (scripts/ci/cmux-machine-channel.py --purpose mac-live)."""
    out: dict = {"sha": sha, "live_from": [], "floor": None, "floor_paths": [],
                 "daemon_from": [], "daemon_floor": None, "daemon_floor_paths": []}
    # daemon_from: the wider list of app commits that can run SHA's bin files beside their own app (daemon ABI
    # only: the FFI pin and the Rust the Swift build reads). The nightly-live channel (`cmux app try channel`)
    # reads it: it swaps only the daemon part and never claims the app is at SHA, so Swift, resources and web
    # (which comes on its own channel) merged since the app's build wait for the next nightly. live_from stays
    # the whole-app list, so a CLI that reads only live_from claims nothing new.
    whole_app = True
    for commit in git(repo, "rev-list", "--first-parent", f"--max-count={limit}", sha).split():
        out["daemon_from"].append(commit)
        if whole_app:
            out["live_from"].append(commit)
            if paths := pins_daemon(repo, commit, whole_app=True):
                out["floor"], out["floor_paths"] = commit, paths[:20]
                whole_app = False
        if paths := pins_daemon(repo, commit):
            out["daemon_floor"], out["daemon_floor_paths"] = commit, paths[:20]
            break
    return out


def command_live_from(args) -> int:
    print(json.dumps(live_from(Path(args.repo), args.sha, args.max)))
    return 0


def abi_at(repo: Path, commit: str) -> int | None:
    """The web ABI of COMMIT's tree (--base: no app to read it from)."""
    try:
        return json.loads(git(repo, "show", f"{commit}:webviews/src/web-abi.json"))["abi"]
    except (RuntimeError, ValueError, KeyError):
        return None


def _plan(repo: Path, app: Path, sha: str, branch: bool, given_base: str | None, unsigned: bool = False) -> dict:
    base = given_base or app_commit(app, repo)
    for commit in (base, sha):
        if not have_commit(repo, commit):
            raise RuntimeError(f"{commit} is not in {repo} (fetch feat-cmux-next)")
    out = {"sha": sha, "base": base, "app": str(app), "parts": [], "left": {}, "notes": []}
    note_refused(out, app, bool(given_base))
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
    web_strings, swift_strings = web_catalogs(repo, sha, files.get("strings", []))
    for kind, paths in (("swift-live", files.get("swift-live")), ("rebuild", files.get("rebuild")), ("strings", swift_strings)):
        if paths:
            out["left"][kind] = paths
    if files.get("strings"):
        out["notes"].append("strings: " + ("the web pages' words ride the web part (gen-strings.mjs reads "
                                           + ", ".join(web_strings) + "); " if web_strings else "")
                            + "Swift's translations wait for the next build")
    web = files.get("web-live", []) + web_strings
    if web and branch:
        # A branch's web is not published: try-pr.sh serves it from the branch (web-overlay.sh follow).
        out["left"]["web (not published for a branch)"] = web
    elif web:
        want = json.loads(git(repo, "show", f"{sha}:webviews/src/web-abi.json"))["abi"]
        have = abi_at(repo, base) if given_base else app_abi(app)
        if have == want:
            out["parts"].append("web")
        else:
            out["left"]["web ABI"] = [f"SHA's web needs ABI {want}, the app has {have}"]
    rust = files.get("daemon", [])
    if rust:
        linked = linked_rust(repo, rust)
        out["tree_key"], out["base_tree_key"] = tree_key(repo, sha), tree_key(repo, since)
        if linked:
            # The app links the release its pin names, not the current FFI sources. A source-only FFI edit stays
            # in the daemon build; only a re-pin swaps the separately published library. Rust the Swift build
            # reads directly still needs an app.
            swift_read = swift_read_rust(repo, linked)
            try:
                if swift_read:
                    raise ffi_part.Left("the Swift build reads " + ", ".join(swift_read[:3]))
                if pinned_ffi_source(repo, base) is None or pinned_ffi_source(repo, sha) is None:
                    raise ffi_part.Left("no app FFI pin to establish the linked release: it needs a new app")
                if pinned_ffi_source(repo, base) != pinned_ffi_source(repo, sha):
                    if branch and not pin_on_base(repo, sha):
                        raise ffi_part.Left("a branch's app FFI is not published (app-ffi-release.yml publishes merges)")
                    moved = ffi_part.pin_plan(repo, None if given_base else app, sha, base)
                    if moved:
                        out["ffi"] = {**moved, "files": linked}
                        out["parts"].append("ffi")
                linked = []
            except ffi_part.Left as why:
                out["notes"].append(f"ffi: {why}")
        if linked:
            out["left"]["Rust the app links (FFI)"] = linked
        elif out["tree_key"] != out["base_tree_key"]:
            out["published"] = published(out["tree_key"])
            daemon_part(out, app, bool(given_base), unsigned)
            helpers = helper_rust(repo, rust)
            if helpers:
                # The daemon part still applies; the helpers built from these files keep the app's build.
                out["left"]["bundled helpers (cmux-mobile-host, ...)"] = helpers
    if ((not branch or pin_on_base(repo, sha)) and "ffi" not in out["parts"]
            and "Rust the app links (FFI)" not in out["left"]):
        # No FFI source changed after the app's commit, but SHA may pin a newer release than the app runs (the
        # pin lags the sources until app-ffi-repin lands): that release is what SHA's app would carry. A branch
        # takes it when the pin is feat-cmux-next's (a NIGHTLY older than the repin the branch forked after: 7 of
        # the 8 Rust looks that ended `exit 3` on 2026-11-17).
        try:
            moved = ffi_part.pin_plan(repo, None if given_base else app, sha, base)
            if moved:
                out["ffi"] = {**moved, "files": [ffi_part.PIN_FILE]}
                out["parts"].append("ffi")
        except ffi_part.Left as why:
            out["notes"].append(f"ffi: {why}")
    if pinned_ffi_source(repo, base) != pinned_ffi_source(repo, sha) and "ffi" not in out["parts"]:
        # A repin ties even an unrelated daemon edit to the new library. A refused library swap must
        # hold that daemon back, just as the signed live_from floor does.
        if "rust" in out["parts"]:
            out["parts"].remove("rust")
        if rust:
            out["left"].setdefault("Rust the app links (FFI)", [ffi_part.PIN_FILE])
    if "ffi" in out["parts"]:
        # Moving the pin is the ffi part's own change, not a Swift one.
        packaging = ffi_part.pin_packaging(repo, since, sha)
        for kind in ("swift-live", "rebuild"):
            if kind in out["left"]:
                rest = [p for p in out["left"][kind] if p not in packaging]
                if rest:
                    out["left"][kind] = rest
                else:
                    del out["left"][kind]
    return out


# ---------------------------------------------------------------- rust: the app's bin/cmux


def triple() -> str:
    """This host's build target; CMUX_HOT_APPLY_TRIPLE names another (a Linux measure fetching a Mac's build)."""
    if os.environ.get("CMUX_HOT_APPLY_TRIPLE"):
        return os.environ["CMUX_HOT_APPLY_TRIPLE"]
    arch = "aarch64" if platform.machine() in ("arm64", "aarch64") else "x86_64"
    return f"{arch}-apple-darwin" if sys.platform == "darwin" else f"{arch}-unknown-linux-musl"


def published(key: str) -> bool:
    """CI published the cmux binaries of tree KEY (its completion.json is there)."""
    try:
        return json.loads(fetch_kept(f"{TUI_BASE}/{key}/completion.json",
                                     lists_binary(f"cmux-tui-{triple()}"))).get("key") == key
    except (OSError, ValueError):  # urllib's errors are OSErrors: a 404 is an unpublished tree
        return False


def cached(copy: Path, want: str) -> bool:
    """A copy fetched before (state/builds/SHA256/) that still hashes to its name: no download."""
    with PHASES("verify"):
        return copy.is_file() and sha256_file(copy) == want


def cmux_job(key: str, state: Path) -> tuple[str, str, Path]:
    """SHA's cmux binary for this host as a build job (URL, its sha256, its copy under state/builds/),
    the sha256 checked between the tree's completion.json and .sha256."""
    name = f"cmux-tui-{triple()}"
    completion = json.loads(fetch_kept(f"{TUI_BASE}/{key}/completion.json", lists_binary(name)))
    if completion.get("key") != key:
        raise RuntimeError(f"{TUI_BASE}/{key}/completion.json names key {completion.get('key')}")
    want = completion.get("binaries", {}).get(name)
    published = fetch_kept(f"{TUI_BASE}/{key}/{name}.sha256").decode().split()[0]
    if not want or want != published:
        raise RuntimeError(f"{name}: completion.json says {want}, {name}.sha256 says {published}")
    return f"{TUI_BASE}/{key}/{name}", want, state / "builds" / want / "cmux"


FETCH_WORKERS = 4  # a build is the daemon and six companions (~160 MB); one connection each, this many at once


def fetch_build_files(jobs: list[tuple[str, str, Path]], seeds: Path | None = None) -> None:
    """Each (URL, WANT, COPY) into COPY (state/builds/SHA256/FILE), checked against WANT. A COPY that still
    hashes to WANT is kept; else a file of COPY's name in SEEDS (the app's bin/) that hashes to it is copied,
    not downloaded (an app that already runs that build); the rest download at once, each hashed as it streams
    to disk and kept only when it is WANT."""
    missing = [job for job in jobs if not cached(job[2], job[1]) and not seeded(job[1], job[2], seeds)]
    if not missing:
        return
    with PHASES("fetch"), concurrent.futures.ThreadPoolExecutor(min(FETCH_WORKERS, len(missing))) as pool:
        for done in [pool.submit(download_into, *job) for job in missing]:
            done.result()  # the first failure raises, after every download has ended


def seeded(want: str, copy: Path, seeds: Path | None) -> bool:
    """COPY made from SEEDS/COPY.name when that file hashes to WANT: no download."""
    seed = seeds / copy.name if seeds else None
    if seed is None or not seed.is_file():
        return False
    with PHASES("verify"):
        copy.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile(dir=copy.parent, delete=False) as part, open(seed, "rb") as source:
            digest = hashlib.sha256()
            while chunk := source.read(1 << 20):
                digest.update(chunk)
                part.write(chunk)
        if digest.hexdigest() != want:
            os.unlink(part.name)
            return False
        os.chmod(part.name, 0o755)
        os.replace(part.name, copy)
        return True


def download_into(url: str, want: str, copy: Path, timeout: float = 300) -> None:
    """URL streamed into COPY, kept only when it hashes to WANT. Runs in a worker thread: no PHASES here."""
    copy.parent.mkdir(parents=True, exist_ok=True)
    request = urllib.request.Request(url, headers={"User-Agent": "cmux-hot-apply/1"})
    with tempfile.NamedTemporaryFile(dir=copy.parent, delete=False) as part:
        try:
            digest = hashlib.sha256()
            with urllib.request.urlopen(request, timeout=timeout) as answer:
                while chunk := answer.read(1 << 20):
                    digest.update(chunk)
                    part.write(chunk)
            if digest.hexdigest() != want:
                raise RuntimeError(f"{url} does not hash to {want}")
        except BaseException:
            part.close()
            os.unlink(part.name)
            raise
    os.chmod(part.name, 0o755)
    os.replace(part.name, copy)


def companion_jobs(key: str, state: Path) -> dict[str, tuple[str, str, Path] | None]:
    """The companions of tree KEY's build for this host as build jobs, each with the sha256 of the
    commit-addressed manifest its source.json names; None for one that build published none of."""
    owner = json.loads(fetch_kept(f"{TUI_BASE}/{key}/source.json")).get("commit") or ""
    if not SHA.fullmatch(owner):
        raise RuntimeError(f"{TUI_BASE}/{key}/source.json names no commit, so its companions are unknown")
    binaries = json.loads(fetch_kept(f"{COMMIT_BASE}/{owner}/manifest.json")).get("binaries", {})
    out: dict[str, tuple[str, str, Path] | None] = {}
    for artifact, file in COMPANIONS:
        asset = f"cmux-tui-{artifact}-{triple()}"
        want = binaries.get(asset)
        out[file] = (f"{COMMIT_BASE}/{owner}/{asset}", want, state / "builds" / want / file) if want else None
    return out


def team_signed(key: str, team: str | None) -> dict | None:
    """Tree KEY's Team-signed set (cmux-tui-team-signed.yml: the same build, signed by the identity the
    NEXT nightly signs with, at TUI_BASE/KEY/team-signed/) when TEAM signed it for this host, else None."""
    if not team:
        return None
    try:
        signed = json.loads(fetch_kept(f"{TUI_BASE}/{key}/{TEAM_SIGNED}/completion.json"))
    except (OSError, ValueError):  # a 404: not signed (yet)
        return None
    files = signed.get("files") if isinstance(signed, dict) else None
    if (not isinstance(files, dict) or signed.get("key") != key or signed.get("team") != team
            or signed.get("target") != triple() or set(files) != {"cmux", *(file for _, file in COMPANIONS)}):
        return None
    for entry in files.values():
        if entry is not None and not (isinstance(entry, dict) and re.fullmatch(r"[0-9a-f]{64}", str(entry.get("sha256")))):
            return None
    return signed if files["cmux"] else None


def fetch_build(key: str, state: Path, team: str | None,
                seeds: Path | None = None) -> tuple[Path, str, dict[str, tuple[Path, str] | None], str]:
    """Tree KEY's cmux and companions for this host: (cmux, its sha256, companions, which build). An app
    signed by TEAM takes the Team-signed set when there is one, else (and an ad-hoc app always) the tree.
    SEEDS (the app's bin/) gives the files it already has with the same sha256, so they are not downloaded."""
    signed = team_signed(key, team)
    if not signed:
        jobs = {"cmux": cmux_job(key, state), **companion_jobs(key, state)}
        build = "ad-hoc"
    else:
        jobs = {file: (f"{TUI_BASE}/{key}/{TEAM_SIGNED}/{entry['sha256']}/{file}", entry["sha256"],
                       state / "builds" / entry["sha256"] / file) if entry else None
                for file, entry in signed["files"].items()}
        build = f"team-signed ({team})"
    fetch_build_files([job for job in jobs.values() if job], seeds)
    out = {file: (job[2], job[1]) if job else None for file, job in jobs.items()}
    new, want = out.pop("cmux")
    return new, want, out, build


def local_companions(binary: Path, state: Path) -> dict[str, tuple[Path, str] | None]:
    """The companions beside a cmux built elsewhere (--binary: a dev build's bin/)."""
    return {file: keep(state, binary.parent / file) if (binary.parent / file).is_file() else None
            for _, file in COMPANIONS}


def rust_unchanged(app: Path, want: str, companions: dict[str, tuple[Path, str] | None]) -> bool:
    """The app's bin/cmux hashes to WANT and each companion is the build's (or absent where it has none)."""
    with PHASES("verify"):
        if sha256_file((app / BIN / "cmux").resolve()) != want:
            return False
        for file, new in companions.items():
            target = app / BIN / file
            if target.is_symlink():
                continue
            if (new is None) != (not target.is_file()) or (new and sha256_file(target) != new[1]):
                return False
        return True


def place_companions(app: Path, companions: dict[str, tuple[Path, str] | None], state: Path) -> dict:
    """Puts each companion beside bin/cmux, or removes the app's when the build has none; returns
    what was there before, by file (None: absent), for put_back."""
    with PHASES("swap"):
        return _place_companions(app, companions, state)


def _place_companions(app: Path, companions: dict[str, tuple[Path, str] | None], state: Path) -> dict:
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
        with PHASES("verify"):
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
    with PHASES("backup"):
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
    # One lsof for every process and every process's asks at once: a process at a time cost 0.03 s of lsof
    # each, and Leo's NIGHTLY runs 52 from its bin (find took 4.6 to 8.8 s there at cmux 3ca1a16e3).
    hung, found = [], []
    pids = app_pids(app, DAEMON_NAMES)
    by_pid: dict[str, set[str]] = {pid: set() for pid in pids}
    if pids:
        lsof = subprocess.run(["lsof", "-a", "-p", ",".join(pids), "-U", "-Fpn"], capture_output=True,
                              text=True).stdout
        current = None
        for entry in lsof.splitlines():
            if entry.startswith("p"):
                current = entry[1:]
            elif entry.startswith("n/") and current in by_pid:
                by_pid[current].add(entry[1:])
    import concurrent.futures
    asked = {pid: sorted(names) for pid, names in by_pid.items() if names}
    with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, min(16, len(asked)))) as pool:
        answers = {pid: pool.submit(first_status, cli, names, pid) for pid, names in asked.items()}
    for pid in pids:
        if pid not in answers:
            continue
        name, unanswered = answers[pid].result()
        if name:
            found.append(name)
        else:
            hung.extend(unanswered)
    # The app's own session must answer: a hung one is not passed over for another session's.
    if hung and (not found or any(Path(name).name.startswith("cmux-app") for name in hung)):
        raise RuntimeError(f"`server status` never answered on {', '.join(sorted(hung))}: the daemon running "
                           f"from {app} is not known; nothing changed (--socket names it)")
    return sorted(found, key=lambda name: not Path(name).name.startswith("cmux-app"))


def first_status(cli: Path, names: list[str], pid: str, timeout: float = 10) -> tuple[str | None, list[str]]:
    """The first of NAMES whose `server status` names PID, every name asked at once; and, when none does, the
    names that never answered in `timeout` seconds. A daemon holds unix sockets that are not its server too
    (a Chief's holds one that never answers): asked one at a time, each cost the full timeout before the
    daemon's own socket was reached (find took 10.4 s at cmux 7a6e6fb with a Chief running, 0.1 s without).
    Each ask is its own `subprocess.run` with the timeout, which ends its child; one still running when an
    answer wins is left to that timeout on its daemon thread."""
    import queue
    import threading
    answers: queue.Queue = queue.Queue()

    def ask(name: str) -> None:
        try:
            out = subprocess.run([str(cli), "--socket", name, "--json", "server", "status"], capture_output=True,
                                 text=True, timeout=timeout).stdout
            answers.put((name, bool(re.search(rf'"pid"\s*:\s*{pid}\b', out or ""))))
        except subprocess.TimeoutExpired:
            answers.put((name, None))
        except OSError:
            answers.put((name, False))

    for name in names:
        threading.Thread(target=ask, args=(name,), daemon=True).start()
    pending, hung, deadline = set(names), [], time.monotonic() + timeout + 1
    while pending:
        try:
            name, hit = answers.get(timeout=max(0.0, deadline - time.monotonic()))
        except queue.Empty:
            break
        pending.discard(name)
        if hit:
            return name, []
        if hit is None:
            hung.append(name)
    return None, sorted(hung + list(pending))


def find_socket(app: Path, cli: Path) -> str | None:
    """The socket of the app's own daemon running from APP's bin folder; None when none runs."""
    found = find_sockets(app, cli)
    return found[0] if found else None


def owner_state_dir(pid) -> str | None:
    """The CMUX_TUI_STATE_DIR daemon PID was started with (`ps eww`, this user's processes), or None."""
    try:
        out = subprocess.run(["ps", "eww", "-o", "command=", "-p", str(pid)], capture_output=True, text=True,
                             timeout=10).stdout
    except (subprocess.TimeoutExpired, OSError):
        return None
    # The environment follows the argv, space-separated: the value runs to the next ` KEY=`.
    found = re.search(r"(?:^|\s)CMUX_TUI_STATE_DIR=(.*?)(?=\s[A-Za-z_][A-Za-z0-9_]*=|$)", out.strip())
    return found.group(1) if found and found.group(1) else None


def restart_sessions(target: Path, sockets: list[str], state: Path) -> list[dict]:
    """Each other session's daemon running from the app's bin (a Chief's) restarted onto `target`, the build
    now in place: `server restart` by its socket stops the owner the way an update hands it off (its
    terminal hosts live on) and starts one from `target` with the stopped owner's session, launch flags and
    environment, which adopts them. Checked: a new owner answers on the socket, running `target`.

    A daemon that refuses the restart and still serves, the same owner answering as before, is left on the
    build it mapped, and its step names the refusal (`left`): it lost nothing, and the others still move.
    A Chief whose owner serves another state directory refuses this way (`server.different_state`, cmux
    bf0d3da on a fleet Mac). A daemon gone with no new owner, or a new owner on another file, raises, and
    the caller puts every part back."""
    swapper_cls = load("rust_live", "rust-live.py").Swapper
    done = []
    for name in sockets:
        swapper = swapper_cls(None, name, state=state / "handoff")
        t0 = time.monotonic()
        with PHASES("find"):
            before = swapper.owner(target, timeout=10)
        with PHASES("reload"):
            # The cmux-tui surface keeps `server` for the daemon's lifecycle in every build (the nightly's too, for
            # the rollback); on `cmux`, `server` is the machine server and refuses --socket (cmux 7a6e6fb, a Chief's).
            surface = target.with_name("cmux-tui") if target.with_name("cmux-tui").exists() else target
            # The restart's own ensure checks the owner against the CLI's state root; a Chief's daemon keeps
            # its session in its own (CMUX_TUI_STATE_DIR, which the restart does not carry), so without it
            # the check read the default root and refused (server.different_state, Leo's NIGHTLY 8568ebc).
            env = dict(os.environ)
            state_dir = owner_state_dir(before[0]) if before else None
            if state_dir:
                env["CMUX_TUI_STATE_DIR"] = state_dir
            ran = subprocess.run([str(surface), "--socket", name, "--json", "server", "restart"],
                                 capture_output=True, text=True, timeout=180, env=env)
            now = swapper.owner(target, timeout=30)
        step = {"socket": name, "old_pid": before[0] if before else None, "new_pid": now[0] if now else None,
                "seconds": round(time.monotonic() - t0, 3)}
        done.append(step)
        if ran.returncode != 0 and before and now and now[0] == before[0]:
            step["left"] = f"refused (exit {ran.returncode}), still served by its owner: " \
                           f"{(ran.stderr or ran.stdout).strip()[-300:]}"
            continue
        if ran.returncode != 0 or not now or (before and now[0] == before[0]):
            raise RuntimeError(f"`server restart` on {name} left no new owner (exit {ran.returncode}): "
                               f"{(ran.stderr or ran.stdout).strip()[-300:]}")
        if swapper.app_file(now[1]) != target:
            raise RuntimeError(f"the new owner on {name} runs {now[1]}, not {target}")
    return done


def swap_cmux(app: Path, new: Path, want: str, socket: str | None, state: Path, sessions: bool = False) -> dict:
    """bin/cmux becomes `new` (sha256 `want`) and the app's daemon is handed to it; checked. With
    `sessions`, every other session's daemon from the same bin is restarted onto it too (restart_sessions);
    without, or from ssh on macOS, they keep the build they mapped and the receipt names them."""
    target = (app / BIN / "cmux").resolve()
    swapper_cls = load("rust_live", "rust-live.py").Swapper
    try:
        with PHASES("find"):
            running = find_sockets(app, target)
    except RuntimeError:
        if not socket:
            raise
        running = [socket]  # --socket names the daemon; the others are not known
    retired: list[dict] = []
    if not socket and running:
        # A daemon an earlier copy of the app started can outlive an update: its argv still names this
        # bin folder, but it runs the copy the updater moved aside (Leo's NIGHTLY, 2026-11-15: cmux-app.sock
        # ran .../nightly-update/backup/retired/cmux NIGHTLY.app.../bin/cmux and the apply refused). The
        # swap never reaches it, so it is left, named, and the app's own daemon is the first that runs TARGET.
        live = []
        for name in running:
            probe = swapper_cls(None, name)  # no state: a probe never reads or writes a hand-off marker
            with PHASES("find"):
                owner = probe.owner(target, timeout=10)
            if owner is not None and probe.app_file(owner[1]) != target:
                retired.append({"socket": name, "pid": owner[0], "runs": str(owner[1])})
            else:
                live.append(name)
        running = live
    socket = socket or (running[0] if running else None)
    step: dict = {"file": str(target), "to": want, "socket": socket}
    if retired:
        step["left_on_retired_copy"] = retired
    # The app's own daemon is handed off here. Another session's (the chief's) keeps the build it mapped
    # unless `sessions` restarts it below; the receipt names each one left, and why.
    others = [name for name in running if name != socket]
    ssh = outside_login_session()
    if others and (not sessions or ssh):
        step["left_on_old_build"] = others
        step["left_on_old_build_why"] = (
            "not asked (--restart-sessions)" if not sessions else
            "this run is an ssh session: the restarted daemon's new terminals would start outside the login "
            "session; run hot-apply in the Mac's own terminal")
    t0 = time.monotonic()
    if socket is None:
        # No daemon runs from this app: the file alone, which the app's next ensure runs.
        with PHASES("swap"):
            staged = target.with_name(f".{target.name}.hot-apply")
            shutil.copy2(new, staged)
            staged.chmod(0o755)
            os.replace(staged, target)
        step["daemon"] = "none running; the next start runs it"
    else:
        swapper = swapper_cls(None, socket, state=state / "handoff")
        with PHASES("find"):
            owner = swapper.owner(target)
        if owner is None:
            raise RuntimeError(f"no daemon answers on {socket}")
        if swapper.app_file(owner[1]) != target:
            raise RuntimeError(f"the daemon on {socket} runs {owner[1]}, not {target}: not this app's")
        with PHASES("reload"):  # the rename over target, SIGTERM, until the app's next owner answers
            swapper.app_handoff(new, owner[0], target)
            now = swapper.owner(target, timeout=10)
        step.update(old_pid=owner[0], new_pid=now[0] if now else None, daemon="app handoff")
        if not now or now[0] == owner[0]:
            raise RuntimeError(f"no new daemon owner answered on {socket} after the handoff")
    step["seconds"] = round(time.monotonic() - t0, 3)
    with PHASES("verify"):
        have = sha256_file(target)
    step["running_sha256"] = have
    if have != want:
        raise RuntimeError(f"{target} hashes to {have}, not {want}")
    if others and sessions and not ssh:
        step["sessions"] = restart_sessions(target, others, state)
        refused = [one["socket"] for one in step["sessions"] if "left" in one]
        if refused:
            step["left_on_old_build"] = refused
            step["left_on_old_build_why"] = "refused the restart and still served by its owner (each session's `left`)"
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
    # A process always starts with some environment (HOME, PATH): none read means it is hidden from us (another
    # user's process, or a kernel that withholds it), never that it had none (#40219 review P2).
    return env or None


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
                found.append({"pid": int(pid), "home": str(status["home"]), "socket": name,
                              "build": str(status.get("build", "")), "keeps_chats": keeps_its_chats(status),
                              "env_readable": process_env(int(pid)) is not None})
                break
        else:
            # Its `daemon status` timed out, was malformed or named another pid: it is still a daemon on the old
            # build, so the receipt names it rather than dropping it (#40219 Codex F2).
            found.append({"pid": int(pid), "home": None, "build": "", "keeps_chats": False, "env_readable": False,
                          "status_unreadable": True})
    return found


def outside_login_session() -> bool:
    """Whether this run is an ssh session on macOS. There `acpmux daemon restart` starts a daemon of the person's
    own home (under ~/.acpmux) as a launchd job in the login session, and launchd drops the environment the
    restart passes (#40219 Codex F1); any other home's daemon (a Chief's) starts in the ssh security session,
    where its agents cannot read the login keychain (acpmux daemon/login_session.rs, login_placement.rs). So no
    daemon found running is restarted from ssh; a home named by --acpmux-home still is, as before. The test is
    the ssh variables, not the security session acpmux asks: a shell that strips them is not caught."""
    return sys.platform == "darwin" and bool(os.environ.get("SSH_CONNECTION") or os.environ.get("SSH_TTY"))


def restart_acpmux(app: Path, homes: list[str], before: dict[str, int] | None = None,
                   sockets: dict[str, str] | None = None) -> list[dict]:
    with PHASES("reload"):
        return _restart_acpmux(app, homes, before, sockets)


def _restart_acpmux(app: Path, homes: list[str], before: dict[str, int] | None,
                    sockets: dict[str, str] | None) -> list[dict]:
    """`acpmux daemon restart` in each home; hosted sessions are kept and resume. The new daemon starts from
    the CLI that runs the restart, so the restart runs with the running daemon's own launch environment
    (its Chief home, Computer Use socket, agent launch policy: everything its owner started it with), read
    from the process, never written down. With BEFORE (home -> the pid that ran), each must answer again
    from another pid, else it raises; a home given by --acpmux-home whose daemon's environment cannot be
    read restarts with this process's, as before. SOCKETS (home -> the socket the daemon was found serving) finds
    a daemon started on a socket of its own, which answers there and not at its home's default."""
    done = []
    for home in homes:
        where = {"socket": sockets[home]} if sockets and sockets.get(home) else {"home": home}
        running = acpmux_status(app, **where)
        own = process_env(int(running["pid"])) if running.get("pid") else None
        if own is None and before and home in before:
            raise RuntimeError(f"cannot read the launch environment of the acpmux daemon in {home}: not restarted")
        env = dict(own if own is not None else os.environ)
        # ACPMUX_SOCKET wins over ACPMUX_HOME: one this process inherited, or one the daemon inherited but does not
        # serve, would restart another home's daemon. The daemon's own, when it answers there, is kept: the new
        # daemon must serve the socket its clients use (#40219 review P2).
        sock = env.get("ACPMUX_SOCKET")
        if own is None or not sock or acpmux_status(app, socket=sock).get("pid") != running.get("pid"):
            env.pop("ACPMUX_SOCKET", None)
        env["ACPMUX_HOME"] = home
        t0 = time.monotonic()
        result = subprocess.run([str(app / BIN / "acpmux"), "daemon", "restart"], capture_output=True, text=True,
                                env=env, timeout=60)
        if result.returncode != 0:
            raise RuntimeError(f"acpmux daemon restart ({home}): {(result.stderr or result.stdout).strip()[:300]}")
        step = {"home": home, "restarted": True, "own_environment": own is not None}
        if before and home in before:
            now = acpmux_status(app, **where)
            step.update(old_pid=before[home], new_pid=now.get("pid"), build=now.get("build"),
                        seconds=round(time.monotonic() - t0, 3))
            if not now.get("pid") or now.get("pid") == before[home]:
                raise RuntimeError(f"acpmux in {home} did not answer from a new daemon after its restart")
        done.append(step)
    return done


# ---------------------------------------------------------------- web: the app's overlay


def web_key(repo: Path, sha: str) -> str:
    """SHA's web source key, from a temporary sparse checkout of SHA (web-bundle-key.py reads files)."""
    with PHASES("key"):
        return remembered("web", sha, lambda: _web_key(repo, sha))


def _web_key(repo: Path, sha: str) -> str:
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


def overlay_pointer(web_dev: bytes | None) -> str | None:
    """The overlay folder web-dev.json points the app at, read as the app reads it (WebDevOverride.parse):
    None for no file, invalid JSON, `"enabled": false`, or no usable `overlay`."""
    try:
        data = json.loads(web_dev) if web_dev is not None else None
    except ValueError:
        return None
    if not isinstance(data, dict) or data.get("enabled", True) is False or not isinstance(data.get("overlay"), str):
        return None
    path = data["overlay"].strip()
    if path == "~" or path.startswith("~/"):
        return str(Path.home() / path[2:])
    return path if path.startswith("/") else None


def overlay_refusal(web_dev: bytes | None, manifest: str | None, have: int | None, folder: Path | None = None) -> dict | None:
    """Why the app refuses the overlay WEB_DEV points at, as WebDevOverride.abiRefusal does: its manifest
    (MANIFEST, the one in FOLDER, or the pointed folder's own when the pointer names another) names a web
    ABI that is not the app's (HAVE). None when the app serves it, or when it points at no overlay."""
    pointer = overlay_pointer(web_dev)
    if pointer is None or have is None:
        return None
    if folder is None or Path(pointer).resolve() != folder.resolve():
        try:
            manifest = (Path(pointer) / "manifest.json").read_text()
        except OSError:
            return None
    try:
        read = json.loads(manifest) if manifest is not None else {}
    except ValueError:
        return None
    abi = read.get("abi") if isinstance(read, dict) else None
    if not isinstance(abi, int) or isinstance(abi, bool) or abi == have:
        return None
    commit = read.get("commit") or "unknown commit"
    return {"overlay": pointer, "commit": commit, "abi": abi, "app_abi": have,
            "why": f"the overlay ({commit}) needs web ABI {abi}; this app has {have}, so it serves its bundled pages"}


def without_pointer(web_dev: bytes | None) -> bytes | None:
    """WEB_DEV with its `overlay` pointer dropped (the server and gallery entries stay); None, so the
    file goes, when nothing else is left in it."""
    data = json.loads(web_dev)
    data.pop("overlay", None)
    if not {k: v for k, v in data.items() if k != "enabled"}:
        return None
    return (json.dumps(data, indent=2) + "\n").encode()


def in_effect(saved: dict, have: int | None, folder: Path) -> dict:
    """SAVED (an overlay snapshot) as what the app served then, not as the files were: a pointer at an
    overlay the app refuses (HAVE, its web ABI) was the app's bundled pages, so it comes back as no
    pointer. The result names what it dropped under `refused`."""
    refused = overlay_refusal(base64.b64decode(saved["web_dev"]) if saved.get("web_dev") else None,
                              saved.get("manifest"), have, folder)
    if refused is None:
        return saved
    dropped = without_pointer(base64.b64decode(saved["web_dev"]))
    return {**saved, "web_dev": base64.b64encode(dropped).decode() if dropped is not None else None, "refused": refused}


def refused_pointer(app: Path) -> dict | None:
    """web-dev.json's overlay pointer when APP refuses that overlay and serves its bundled pages instead;
    None when it points at none or the app serves it."""
    _, web_dev = load("live_apply_loop", "live-apply.py").overlay_paths()
    try:
        data = web_dev.read_bytes()
    except OSError:
        return None
    return overlay_refusal(data, None, app_abi(app))


def command_drop_refused_overlay(args) -> int:
    """Drops web-dev.json's pointer at an overlay the app refuses (an older install's, a rollback's from
    before rollback checked): the app already serves its bundled pages, and now the file says so too.
    The server and gallery entries stay. A pointer the app serves is left alone."""
    import fcntl
    app, state = Path(args.app), state_dir()
    _, web_dev = load("live_apply_loop", "live-apply.py").overlay_paths()
    receipt = {"action": "drop-refused-overlay", "app": str(app), "web_dev": str(web_dev), "dropped": None,
               "at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
    if web_dev.parent.is_dir():
        with open(web_dev.parent / ".web-dev.lock", "a") as lock:  # web-overlay.sh's lock
            fcntl.flock(lock, fcntl.LOCK_EX)
            try:
                data = web_dev.read_bytes()
            except OSError:
                data = None
            refused = overlay_refusal(data, None, app_abi(app))
            if refused:
                kept = without_pointer(data)
                if kept is None:
                    web_dev.unlink()
                else:
                    write_atomic(web_dev, kept)
                receipt["dropped"] = refused
                receipt["web_dev_now"] = "removed" if kept is None else "kept without its overlay pointer"
    receipt["note"] = (f"dropped the pointer at {receipt['dropped']['overlay']}: {receipt['dropped']['why']}"
                       if receipt["dropped"] else "web-dev.json points at no overlay this app refuses: nothing to drop")
    log(receipt["note"])
    record(state, receipt, last=False)  # `rollback` still puts back the last apply
    return 0


def overlay_commit(live) -> str | None:
    overlay, _ = live.overlay_paths()
    try:
        return json.loads((overlay / "manifest.json").read_text()).get("commit")
    except (OSError, ValueError):
        return None


def fetch_web(key: str, out: Path) -> None:
    """The bundles published for web source KEY, unpacked into OUT and checked against their manifest."""
    with PHASES("fetch"):  # fetch-web-bundles.sh checks the archive's sha256 itself
        fetched = subprocess.run([str(ROOT / "scripts/cmux-next/fetch-web-bundles.sh"), "--key", key, "--out", str(out)],
                                 stdout=subprocess.PIPE, stderr=sys.stderr, text=True)
    if fetched.returncode != 0:
        raise RuntimeError(f"web bundles for key {key} not fetched (exit {fetched.returncode}; 3 is unpublished)")


DIGEST = ".hot-apply-digest"


def tree_digest(root: Path) -> str:
    """sha256 over every file under ROOT (its path and its sha256), but the digest file itself."""
    digest = hashlib.sha256()
    for path in sorted(p for p in root.rglob("*") if p.is_file() and p.name != DIGEST):
        digest.update(f"{path.relative_to(root)}\0{sha256_file(path)}\n".encode())
    return digest.hexdigest()


def web_bundles(key: str, state: Path) -> Path:
    """The bundles published for web source KEY, under state/web/KEY: fetched and checked once (the
    archive against its manifest's sha256), then checked on each use against the digest of the files
    as they were unpacked. A folder that no longer matches is fetched again."""
    root = state / "web" / key
    with PHASES("verify"):
        try:
            if (root / DIGEST).read_text().strip() == tree_digest(root):
                os.utime(root)  # the newest used is the last pruned
                return root
        except OSError:
            pass
    shutil.rmtree(root, ignore_errors=True)
    stage = Path(tempfile.mkdtemp(prefix=f".{key[:12]}.", dir=ensure_dir(state / "web")))
    try:
        fetch_web(key, stage / "b")
        with PHASES("verify"):
            (stage / "b" / DIGEST).write_text(tree_digest(stage / "b") + "\n")
        os.replace(stage / "b", root)
    finally:
        shutil.rmtree(stage, ignore_errors=True)
    prune_web(state)
    return root


def ensure_dir(path: Path) -> Path:
    path.mkdir(parents=True, exist_ok=True)
    return path


def prune_web(state: Path, keep: int = WEB_KEEP) -> None:
    """Only the newest KEEP web bundle folders stay: the cache stays bounded however many commits go by."""
    folders = sorted((p for p in (state / "web").iterdir() if p.is_dir() and HEX.fullmatch(p.name)),
                     key=lambda p: p.stat().st_mtime, reverse=True)
    for old in folders[keep:]:
        shutil.rmtree(old, ignore_errors=True)


def web_unchanged(live, key: str) -> bool:
    """The overlay already holds KEY's bundles: its manifest names a commit whose web key is KEY (as
    remembered here; a commit whose key was never computed here is not taken for one)."""
    commit = overlay_commit(live)
    if not commit or not SHA.fullmatch(commit):
        return False
    try:
        return (state_dir() / "keys" / "web" / commit).read_text().strip() == key
    except OSError:
        return False


def apply_web(key: str, sha: str, live) -> dict:
    bundles = web_bundles(key, state_dir())
    with PHASES("swap"):
        installed = subprocess.run([str(ROOT / "scripts/cmux-next/web-overlay.sh"), "install", str(bundles),
                                    "--commit", sha], stdout=sys.stderr, stderr=sys.stderr)
    if installed.returncode != 0:
        raise RuntimeError(f"web-overlay.sh install exited {installed.returncode}")
    with PHASES("verify"):
        if overlay_commit(live) != sha:
            raise RuntimeError(f"the overlay's manifest names {overlay_commit(live)}, not {sha}")
    return {"key": key, "commit": sha, "generation": live.generation()}


# ---------------------------------------------------------------- commands


def record(state: Path, receipt: dict, last: bool = True) -> None:
    """Writes the receipt, with the run's phases, to history.jsonl (and last.json unless LAST is false, as for a
    dry run), prints it as the last line on stdout and the phases on stderr."""
    receipt["phases"] = PHASES.rounded()
    state.mkdir(parents=True, exist_ok=True)
    line = json.dumps(receipt)
    if last:
        (state / "last.json").write_text(line + "\n")
    with open(state / "history.jsonl", "a") as handle:
        handle.write(line + "\n")
    log(timings(receipt))
    print(line)


def timings(receipt: dict) -> str:
    """One line: the run's seconds, then each phase's, largest first."""
    phases = sorted(receipt.get("phases", {}).items(), key=lambda kv: -kv[1])
    return f"{receipt.get('action', '?')} {receipt.get('seconds', 0):.1f} s: " + (
        ", ".join(f"{name} {secs:.1f}" for name, secs in phases) or "no phases")


def command_plan(args) -> int:
    out = plan(Path(args.repo), Path(args.app), args.sha, args.branch, args.base, args.unsigned_daemon)
    print(json.dumps(out, indent=2))
    return 0 if out["parts"] or not out["left"] else 3


def command_apply(args) -> int:
    repo, app, state = Path(args.repo), Path(args.app), state_dir()
    if args.base and not args.dry_run:
        print("hot-apply: --base stands in for an app only in plan and apply --dry-run", file=sys.stderr)
        return 2
    t0 = time.monotonic()
    planned = plan(repo, app, args.sha, args.branch, args.base, args.unsigned_daemon)
    parts = [p for p in planned["parts"] if p in args.parts.split(",")]
    receipt = {"action": args.command if args.dry_run and args.command == "prefetch" else
               "dry-run" if args.dry_run else "apply", **planned, "applied": [], "rolled_back": False,
               "steps": {}, "at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
    if ("rust" in parts and "ffi" in planned["parts"] and "ffi" not in parts and not args.ffi_in
            and planned["ffi"]["source"] != planned["ffi"]["app_pin_source"]):
        # The daemon rides with the app FFI release the plan puts in (#44525): --parts rust alone would pair it with
        # the app's old library. hot-verify's look puts the release in first and says so with --ffi-in.
        planned["left"] = {**planned["left"], "Rust the app links (FFI)": [
            f"the daemon needs the app FFI release {planned['ffi']['release']} in first: apply --parts ffi too"]}
        receipt["left"] = planned["left"]
        parts = [p for p in parts if p != "rust"]
    if not parts:
        receipt["seconds"] = round(time.monotonic() - t0, 3)
        record(state, receipt, last=False)  # nothing changed: `rollback` still puts back the last apply
        return 0 if not planned["left"] else 3
    if args.dry_run:
        return dry_run(repo, args, planned, parts, receipt, state, t0)
    live = load("live_apply_loop", "live-apply.py")
    target = (app / BIN / "cmux").resolve()
    undo: dict = {}
    receipt["unchanged"] = []
    ffi_how = ffi_new = ffi_checksum = None
    if "ffi" in parts and planned["ffi"]["source"] != planned["ffi"]["app_pin_source"]:
        # Before any part changes: the daemon part rides with the library, so one the app cannot take keeps both.
        try:
            ffi_how = ffi_part.how_to_sign(app, args.sign_identity, args.reseal)
            ffi_new, ffi_checksum = ffi_part.fetch_library(planned["ffi"]["source"], state, fetch, fetch_kept)
            with PHASES("verify"):
                missing = sorted(ffi_part.imports(app) - ffi_part.exports(ffi_new))
            if missing:
                raise ffi_part.Left(f"the library lacks {len(missing)} symbol(s) the app imports: "
                                    + ", ".join(missing[:5]))
        except ffi_part.Left as why:
            ffi_new = None
            receipt["left"]["ffi"] = [str(why)]
            receipt["left"]["Rust the app links (FFI)"] = planned["ffi"]["files"]
            parts = [p for p in parts if p not in ("ffi", "rust")]
            if not parts:
                receipt["seconds"] = round(time.monotonic() - t0, 3)
                record(state, receipt, last=False)
                return 3
    try:
        if "rust" in parts:
            # --binary: a cmux binary built for SHA elsewhere (try-pr.sh: the PR's fleet dev build).
            if args.binary:
                new, want = keep(state, Path(args.binary))
                companions = local_companions(Path(args.binary), state)
            else:
                new, want, companions, build = fetch_build(planned["tree_key"], state, app_team(app), app / BIN)
                receipt["steps"]["build"] = build
            # The file itself, whatever plan read: a --binary, or a build plan could not read.
            why = unverifiable(file_team(new), app_team(app), "SHA's cmux" if not args.binary else args.binary)
            if why and not args.unsigned_daemon:
                raise RuntimeError(why)
            if why:
                receipt["steps"]["unsigned_daemon"] = why
            if not (args.restart_acpmux or args.acpmux_home or args.restart_sessions) and rust_unchanged(app, want, companions):
                # A hot apply of SHA (or a later commit with the same build) already put it in: nothing to hand off.
                receipt["unchanged"].append("rust")
                receipt["steps"]["rust"] = {"to": want, "unchanged": True}
                parts = [p for p in parts if p != "rust"]
        if "rust" in parts:
            prior, prior_sha = keep(state, target)
            undo["rust"] = {"copy": str(prior), "sha256": prior_sha, "companions": {}}
            # Before the handoff, so the new daemon starts the companions of its own build.
            undo["rust"]["companions"] = place_companions(app, companions, state)
            receipt["steps"]["companions"] = {f: (c[1] if c else None) for f, c in companions.items()}
            # Before the swap: a session restart that fails part way is put back by the rollback.
            undo["rust"]["sessions"] = bool(args.restart_sessions)
            receipt["steps"]["rust"] = swap_cmux(app, new, want, args.socket, state, args.restart_sessions)
            receipt["steps"]["rust"]["from"] = prior_sha
            receipt["applied"].append("rust")
            daemons = running_acpmux(app) if args.restart_acpmux or not args.acpmux_home else []
            # A daemon whose chats a restart would lose (a memory store without agent hosts), or whose launch
            # environment cannot be read, keeps its build: the receipt names it and why.
            ssh = outside_login_session()
            safe = ([d for d in daemons if d["keeps_chats"] and d["env_readable"]]
                    if args.restart_acpmux and not ssh else [])
            left = [dict(d, why="not asked (--restart-acpmux)" if not args.restart_acpmux else
                         "its daemon status did not answer" if d.get("status_unreadable") else
                         "this run is an ssh session: the restarted daemon would lose its launch environment or the "
                         "login keychain; run hot-apply in the Mac's own terminal" if ssh else
                         "its chats would be lost: a memory store without agent hosts" if not d["keeps_chats"] else
                         "its launch environment is unreadable") for d in daemons if d not in safe]
            homes = list(dict.fromkeys(args.acpmux_home + [d["home"] for d in safe]))
            if homes:
                undo["rust"]["acpmux_homes"] = homes
                undo["rust"]["acpmux_own_env"] = [d["home"] for d in safe]
                undo["rust"]["acpmux_sockets"] = {d["home"]: d["socket"] for d in safe}
                receipt["steps"]["acpmux"] = restart_acpmux(app, homes, {d["home"]: d["pid"] for d in safe},
                                                            undo["rust"]["acpmux_sockets"])
            if left:  # they keep the build they mapped
                receipt["steps"]["rust"]["acpmux_left_on_old_build"] = left
        if "web" in parts:
            key = planned.get("web_key") or web_key(repo, args.sha)
            if web_unchanged(live, key):
                receipt["unchanged"].append("web")
                receipt["steps"]["web"] = {"key": key, "commit": overlay_commit(live), "unchanged": True}
            else:
                # What the app served before, not the files as they were: a pointer at an overlay the app
                # refuses was its bundled pages, so that is what `rollback` puts back.
                undo["web"] = in_effect(overlay_snapshot(live), app_abi(app), live.overlay_paths()[0])
                receipt["steps"]["web"] = apply_web(key, args.sha, live)
                if undo["web"].get("refused"):
                    receipt["steps"]["web"]["replaced_refused_overlay"] = undo["web"]["refused"]
                receipt["applied"].append("web")
        if "ffi" in parts:
            # Last: the app quits (sessions kept) and opens again on the new library, and its pages with it.
            source = planned["ffi"]["source"]
            if ffi_new is None:  # the app was built with SHA's FFI sources
                receipt["unchanged"].append("ffi")
                receipt["steps"]["ffi"] = {"source": source, "unchanged": True}
            else:
                try:
                    step, undo["ffi"] = ffi_part.swap(app, ffi_new, state, ffi_how, args.sign_identity, PHASES)
                except Exception as error:
                    if getattr(error, "undo", None):
                        undo["ffi"] = error.undo  # quit and swapped: put the old library back
                    raise
                receipt["steps"]["ffi"] = {"source": source, "release": planned["ffi"]["release"],
                                           "archive_sha256": ffi_checksum, **step}
                receipt["applied"].append("ffi")
    except Exception as error:  # noqa: BLE001 - any failed step puts back what ran before
        receipt["error"] = str(error)
        receipt["rolled_back"] = True
        with PHASES("rollback"):
            receipt["rollback"] = put_back(app, undo, args.socket, state, live)
        # A part that did not go back stays in `undo`, so `rollback` can try it again.
        receipt["undo"] = {part: undo[part] for part, step in receipt["rollback"].items() if not step.get("ok")}
        receipt["seconds"] = round(time.monotonic() - t0, 3)
        record(state, receipt)
        return 1
    receipt["undo"] = undo
    receipt["seconds"] = round(time.monotonic() - t0, 3)
    record(state, receipt, last=bool(receipt["applied"]))  # an apply that changed nothing keeps the last one
    return 0


def dry_run(repo: Path, args, planned: dict, parts: list[str], receipt: dict, state: Path, t0: float) -> int:
    """What `apply` would fetch and verify, fetched and verified; nothing in the app changes."""
    app = Path(args.app)
    try:
        if "rust" in parts and not args.binary:
            new, want, companions, build = fetch_build(planned["tree_key"], state, planned.get("app_team"),
                                                       None if args.base else app / BIN)
            receipt["steps"]["rust"] = {"to": want, "copy": str(new), "build": build}
            receipt["steps"]["companions"] = {f: (c[1] if c else None) for f, c in companions.items()}
        if "web" in parts:
            key = planned.get("web_key") or web_key(repo, args.sha)
            receipt["steps"]["web"] = {"key": key, "commit": args.sha, "bundles": str(web_bundles(key, state))}
        if "ffi" in parts and planned["ffi"]["source"] != planned["ffi"]["app_pin_source"]:
            try:
                new, checksum = ffi_part.fetch_library(planned["ffi"]["source"], state, fetch, fetch_kept)
                receipt["steps"]["ffi"] = {"source": planned["ffi"]["source"], "archive_sha256": checksum,
                                           "copy": str(new)}
                if not args.base:  # an app to pair with: its imports, and how it would be signed
                    missing = sorted(ffi_part.imports(app) - ffi_part.exports(new))
                    receipt["steps"]["ffi"]["missing_symbols"] = missing
                    receipt["steps"]["ffi"]["signed"] = ffi_part.how_to_sign(app, args.sign_identity, args.reseal)
            except ffi_part.Left as why:
                receipt["left"]["ffi"] = [str(why)]
    except Exception as error:  # noqa: BLE001 - the receipt says what failed; nothing to put back
        receipt["error"] = str(error)
        receipt["seconds"] = round(time.monotonic() - t0, 3)
        record(state, receipt, last=False)
        return 1
    receipt["seconds"] = round(time.monotonic() - t0, 3)
    record(state, receipt, last=False)
    return 0


def put_back(app: Path, undo: dict, socket: str | None, state: Path, live) -> dict:
    """Restores each part in `undo` and checks it; returns what happened to each."""
    out: dict = {}
    if "ffi" in undo:  # first: the app quits and opens again on the library it had
        try:
            out["ffi"] = ffi_part.put_back(app, undo["ffi"])
        except Exception as error:  # noqa: BLE001
            out["ffi"] = {"ok": False, "error": str(error)}
    if "web" in undo:
        try:
            # An undo written before apply checked this (or an app updated since) is checked here too.
            saved = in_effect(undo["web"], app_abi(app), live.overlay_paths()[0])
            overlay_restore(live, saved)
            if saved.get("refused"):
                out["web"] = {"ok": True, "commit": None, "in_effect": "the app's bundled pages",
                              "dropped_refused_pointer": saved["refused"]}
            else:
                pointer = overlay_pointer(base64.b64decode(saved["web_dev"]) if saved.get("web_dev") else None)
                out["web"] = {"ok": True, "commit": overlay_commit(live) if pointer else None,
                              "in_effect": f"the overlay at {pointer}" if pointer else "the app's bundled pages"}
        except Exception as error:  # noqa: BLE001
            out["web"] = {"ok": False, "error": str(error)}
    if "rust" in undo:
        target = (app / BIN / "cmux").resolve()
        try:
            restore_companions(app, undo["rust"].get("companions") or {})
            if sha256_file(target) == undo["rust"]["sha256"]:
                out["rust"] = {"ok": True, "running_sha256": undo["rust"]["sha256"], "daemon": "unchanged"}
            else:
                out["rust"] = {"ok": True, **swap_cmux(app, Path(undo["rust"]["copy"]), undo["rust"]["sha256"], socket, state,
                                                     bool(undo["rust"].get("sessions")))}
            # The acpmux daemons the apply restarted run the applied build: restart them on the prior one.
            if undo["rust"].get("acpmux_homes"):
                # The ones restarted with their own environment go back with it, or not at all (#40219 review P2).
                # One that no longer answers is skipped with a note, so the cmux swap-back still counts.
                own = set(undo["rust"].get("acpmux_own_env") or [])
                sockets = undo["rust"].get("acpmux_sockets") or {}
                where = {h: ({"socket": sockets[h]} if sockets.get(h) else {"home": h}) for h in own}
                before = {h: int(acpmux_status(app, **where[h]).get("pid") or 0) for h in own}
                gone = [h for h in own if not before[h]]
                homes = [h for h in undo["rust"]["acpmux_homes"] if h not in gone]
                out["rust"]["acpmux"] = restart_acpmux(app, homes, {h: p for h, p in before.items() if p} or None,
                                                       sockets)
                if gone:
                    out["rust"]["acpmux_not_answering"] = gone
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
    with PHASES("rollback"):
        done = put_back(app, last["undo"], args.socket, state, load("live_apply_loop", "live-apply.py"))
    receipt = {"action": "rollback", "of": last["sha"], "app": str(app), "steps": done,
               "undo": {part: last["undo"][part] for part, step in done.items() if not step.get("ok")},
               "ok": all(step.get("ok") for step in done.values()), "seconds": round(time.monotonic() - t0, 3),
               "at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
    record(state, receipt)
    return 0 if receipt["ok"] else 1


def command_prefetch(args) -> int:
    """`apply --dry-run` under its own name: fetch and check what SHA's apply needs, and keep it."""
    args.dry_run, args.parts, args.binary, args.ffi_in = True, "web,rust,ffi", None, False
    args.sign_identity, args.reseal = None, False
    args.socket, args.acpmux_home, args.restart_acpmux, args.restart_sessions = None, [], False, False
    return command_apply(args)


def command_keys(args) -> int:
    print(json.dumps(hot_keys(Path(args.repo), args.sha, args.web_key), indent=1, sort_keys=True))
    return 0


def command_status(_args) -> int:
    try:
        print((state_dir() / "last.json").read_text().strip())
    except OSError:
        print("hot-apply: nothing applied here")
    return 0


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)
    for name in ("plan", "apply", "prefetch"):
        p = sub.add_parser(name)
        p.add_argument("sha")
        p.add_argument("--app", default=DEFAULT_APP)
        p.add_argument("--repo", default=str(ROOT))
        p.add_argument("--branch", action="store_true",
                       help="SHA is a branch head (a pull request) that may predate the app's commit")
        p.add_argument("--base", help="stand in for the app's commit (plan, apply --dry-run): no app needed")
        p.add_argument("--unsigned-daemon", action="store_true",
                       help="take a Rust build not signed as the app is (a Team-signed app then verifies no "
                            "connection: Cloud and user-origin calls fail until rollback)")
        if name == "apply":
            p.add_argument("--parts", default="web,rust,ffi")
            p.add_argument("--sign-identity",
                           help="ffi: sign the app FFI library with this keychain identity (a Developer ID app's team)")
            p.add_argument("--reseal", action="store_true",
                           help="ffi: a Developer ID app takes an ad hoc library by being signed ad hoc too "
                                "(it starts signed out of its Keychain items; rollback puts the signature back)")
            p.add_argument("--binary", help="the cmux binary to swap in, instead of the one published for SHA")
            p.add_argument("--ffi-in", action="store_true",
                           help="the app FFI release the plan names is already in the app (an earlier --parts ffi): "
                                "--parts rust alone may then put the daemon in")
            p.add_argument("--socket")
            p.add_argument("--acpmux-home", action="append", default=[])
            p.add_argument("--restart-acpmux", action="store_true",
                           help="also restart every acpmux daemon running from the app's bin folder (sessions resume)")
            p.add_argument("--restart-sessions", action="store_true",
                           help="also hand every other session's terminal daemon from the app's bin (a Chief's) "
                                "to the new build with `server restart` (terminals kept)")
            p.add_argument("--dry-run", action="store_true",
                           help="plan, fetch and verify every part; change nothing in the app (receipt: history.jsonl)")
    p = sub.add_parser("keys")
    p.add_argument("sha")
    p.add_argument("--repo", default=str(ROOT))
    p.add_argument("--web-key", help="SHA's web source key, when the caller has it (else computed here)")
    p = sub.add_parser("live-from", help="the app commits that can take SHA's daemon build live (JSON)")
    p.add_argument("sha")
    p.add_argument("--repo", default=str(ROOT))
    p.add_argument("--max", type=int, default=LIVE_FROM_MAX)
    p = sub.add_parser("rollback")
    p.add_argument("--app")
    p.add_argument("--socket")
    sub.add_parser("status")
    p = sub.add_parser("drop-refused-overlay",
                       help="drop web-dev.json's pointer at an overlay the app refuses (it serves its bundled pages)")
    p.add_argument("--app", default=DEFAULT_APP)
    args = parser.parse_args(argv)
    if getattr(args, "sha", None) is not None:
        args.sha = git(Path(args.repo), "rev-parse", "--verify", f"{args.sha}^{{commit}}", check=False) or args.sha
        if not SHA.fullmatch(args.sha):
            print(f"hot-apply: {args.sha!r} is not a commit here", file=sys.stderr)
            return 2
    try:
        return {"plan": command_plan, "apply": command_apply, "prefetch": command_prefetch, "keys": command_keys,
                "rollback": command_rollback, "status": command_status, "live-from": command_live_from,
                "drop-refused-overlay": command_drop_refused_overlay}[args.command](args)
    except RuntimeError as error:
        print(f"hot-apply: {error}", file=sys.stderr)
        return 3


if __name__ == "__main__":
    sys.exit(main())
