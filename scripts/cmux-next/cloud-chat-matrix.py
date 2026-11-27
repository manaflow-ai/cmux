#!/usr/bin/env python3
"""Cloud chats from every kind of workspace, each cell timed and its synced tree checked by hash.

Leo, 2026-11-10: "how well does it work though? Does it work across every expected possible
workspace? Especially on mine, just test it personally, on mine".

A cell is one Cloud chat started from one folder on this Mac with `cmux cloud start-chat --from-folder`
(the composer's copy, which New Cloud chat uses), with one agent. For each cell this records:

- create to reply: the start-chat's own time, from the call to the reply read back;
- sync: the folder copy's time when the answer says it, and the bytes and files it moved;
- the synced tree: a hash manifest of the copy, read on the machine with `cloud exec`, compared with the
  tree this Mac should have sent (what `link/sync_cli/skips.rs` leaves out is left out here too);
- secrets: canary values in `.env*`, key and credential files, which must be on neither the machine
  nor in the reply;
- the reply, which must carry a word only the folder's own file holds (so the agent read the copy).

Workspaces (WORKSPACES): an empty folder, a small repo, a big monorepo (a cmux clone), a repo whose
remote is private, submodules, Git LFS, a dirty tree, a big non-Git folder, a folder past the copy's
limits (`huge-plain`: a sparse 21 GiB file, no disk spent; `huge-repo`: one repository with one), a parent folder of repositories that is no
repository itself, under the limits (`parent-repos`, copied whole) and past them (`huge-parent-repos`,
~/Projects' shape). A folder past the limits is never refused: the chat starts in it at once from a first pass of
its files (link/sync_cli/size_cap.rs) and its reply must read the folder's word, within FIRST_PASS_REPLY_WITHIN_S;
its tree is not compared, the rest staying on the Mac (Leo, 2026-11-10: "then there's this limit", "did you guys
not test these"; 2026-11-15: "why are you guys still blocking on these?"). Every cell's start must carry the copy's
estimate, made before any machine (`estimate`: whole, first pass or seed); a first-pass cell's says first pass, and a
cell whose link made it a first pass by time is judged as one. The last cells: a folder of secrets, and odd names and symlinks. `--folder NAME=PATH` adds a person's own folder, read only: nothing is written
into it, so its cell has no word check. Agents (AGENTS) run on the small repo; the workspace cells use
the first agent.

The app is either launched here (`--app`, signed in from `--credentials-file`, the way
cloud-chat-proof.py does it, for CI) or already running and signed in (`--cli`, a person's own app).
At most `--parallel` machines (default 3) exist at once; each cell kills the machine it made, and the
run kills any machine still named after it at the end.

    python3 -I scripts/cmux-next/cloud-chat-matrix.py --cli "/Applications/cmux NIGHTLY.app/Contents/Resources/bin/cmux" \\
        --out /tmp/matrix --only small-repo,secrets
"""
from __future__ import annotations

import argparse
import base64
import concurrent.futures
import hashlib
import json
import os
import re
import secrets as random
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from safe_log import safe_print  # noqa: E402  (a line in a cleanup path never skips the kill)

sys.path.insert(0, str(Path(__file__).resolve().parent))
import claude_login_cache  # noqa: E402
from app_launch_env import launch_env  # noqa: E402

AGENTS = ("claude", "codex")
WORKSPACES = ("empty", "small-repo", "monorepo", "private-remote", "submodules", "lfs", "dirty",
              "big-plain", "huge-plain", "huge-repo", "parent-repos", "huge-parent-repos", "secrets", "odd-names",
              "public-remote", "heavy", "case-rename", "large-binaries", "media")
# RFD 0007's folder kinds (Leo, 2026-11-25: "how is projectionfs? for bare non-gited folders, ones with git, etc";
# "there's various other situations you guys need to be testing esp with projectionfs and intended read
# behaviour") and the cell that measures each: `--only kinds` runs just these.
KIND_CELLS = {
    "1 bare non-git folder": "big-plain", "2 git, public remote": "public-remote",
    "3 git, private remote": "private-remote", "4 local-only repo": "small-repo", "5 huge monorepo": "monorepo",
    "6 node_modules / build output": "heavy", "7 symlinks, case-only renames": "case-rename",
    "8 empty folder": "empty", "9 large binaries": "large-binaries", "10 media (MP4)": "media",
}
# The cells whose largest file the machine reads (first byte, then whole), timed, before the tree's hash
# reads everything: a projected folder's read is a lazy fault, so this is its intended read behaviour.
READ_PROBE_CELLS = ("big-plain", "public-remote", "private-remote", "small-repo", "monorepo", "heavy",
                    "case-rename", "empty", "large-binaries", "media")
# large-binaries: a few files past 100 MB (random, so no link compresses them away).
LARGE_BINARY_MB = (128, 160, 200)
# media: MP4-shaped files (an ftyp box, then random payload), 2-48 MB, as a phone's export folder holds.
MEDIA_MB = (2, 8, 24, 48)
# The production projection matrix is deliberately a small, stable set.  Keep this separate from the
# historical workspace list above so adding a fixture here never changes the nightly proof's coverage.
PROJECTION_KINDS = ("bare-folder", "public-remote", "private-remote", "local-only-repo", "huge-monorepo",
                    "build-output", "symlinks")
# The cells past the copy's limits: the chat starts from a first pass, never a refusal; no tree or git compare
# (a first pass sends no history), and the big file must stay on the Mac (left_on_mac >= 1).
FIRST_PASS_CELLS = ("huge-plain", "huge-repo", "huge-parent-repos")
# The file each first-pass cell leaves on the Mac.
FIRST_PASS_LEFT = "disk.img"
# The repositories inside parent-repos and huge-parent-repos.
PARENT_REPOS = ("api", "web", "work/tools")
WORD_FILE = "cmux-matrix-word.txt"
# huge-plain: past the copy's 20 GiB limit (link/sync_cli/size_cap.rs), sparse so it costs no disk.
HUGE_PLAIN_BYTES = 21 * 1024 ** 3
# How long a first-pass cell may take from the call to its reply.
FIRST_PASS_REPLY_WITHIN_S = 300

# What a copy leaves out (link/sync_cli/skips.rs): keep these in step with it.
CREDENTIAL_FOLDERS = (".ssh", ".aws", ".gnupg", ".config/gcloud", ".config/gh", ".kube", ".docker", ".secrets",
                      ".azure", ".cargo", ".gem", ".terraform.d", ".password-store", "library/keychains")
CREDENTIAL_NAMES = (".netrc", "_netrc", ".npmrc", ".pypirc", ".git-credentials", ".pgpass")
HEAVY_ALWAYS = ("node_modules", ".venv", "__pycache__", ".next", ".nuxt", "DerivedData", ".gradle", ".tox",
                ".mypy_cache", ".pytest_cache", ".cache", ".turbo", ".parcel-cache")
HEAVY_BESIDE = {"Pods": ("Podfile", "Podfile.lock"), "target": ("Cargo.toml", "pom.xml"),
                "build": ("package.json", "build.gradle", "build.gradle.kts", "settings.gradle",
                          "settings.gradle.kts", "setup.py", "pyproject.toml"),
                "dist": ("package.json", "setup.py", "pyproject.toml")}

EVIDENCE_SCAN = re.compile(  # cloud-chat-proof.yml's evidence grep: nothing it matches may reach the evidence
    r"(?i)(cmvm|cmk|crt|crk|cmm|cmj)_[A-Za-z0-9_-]{8,}|sk-(ant-)?[A-Za-z0-9_-]{10,}"
    r"|eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}|bearer\s+[A-Za-z0-9._~+/=-]+"
    r"|(api[_-]?key|access[_-]?token|refresh[_-]?token|authorization|token|password|secret|credential)\s*[:=]"
)


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    where = parser.add_mutually_exclusive_group(required=True)
    where.add_argument("--app", help="an app bundle to launch here, signed in from --credentials-file (CI)")
    where.add_argument("--cli", help="the cmux CLI of an app already running and signed in")
    parser.add_argument("--tag", default=f"cwm-{random.token_hex(4)}", help="names the run's machines")
    parser.add_argument("--cloud-backend", choices=("staging", "prod"), help="with --app")
    parser.add_argument("--expected-api-origin", help="with --app")
    parser.add_argument("--credentials-file", help="with --app: a 0600 Stack credentials file the app reads")
    parser.add_argument("--grant-claude-login", action="store_true",
                        help="with --app: the launched app's own scratch cmux.json says yes to Use My Claude Login "
                             "on My Own Cloud Machines (a Release build's claude chat waits for that consent)")
    parser.add_argument("--login", choices=("", "none", "machine", "pass"), default="",
                        help="a Claude chat's `start-chat --login` (default: none given, so --grant-claude-login's consent "
                             "decides; `pass` copies the account's cached login, see --cache-claude-login; `none` "
                             "copies nothing, which leaves Claude signed out on a team the gateway does not serve)")
    parser.add_argument("--cache-claude-login", action="store_true",
                        help="with --app: store CLAUDE_CODE_OAUTH_TOKEN (environment only) as the signed-in account's "
                             "cached Claude login for this run (claude_login_cache.py); removed when the run ends")
    parser.add_argument("--agents", default="claude", help=f"comma list of {','.join(AGENTS)}")
    parser.add_argument("--only", default="", help="comma list of workspace cells (default: all)")
    parser.add_argument("--projection-kinds", action="store_true",
                        help="run the seven projected-folder fixtures used by RFD 0007")
    parser.add_argument("--folder", action="append", default=[], metavar="NAME=PATH",
                        help="a person's own folder as a cell, read only")
    parser.add_argument("--monorepo", default="https://github.com/manaflow-ai/cmux.git",
                        help="the big monorepo: a git URL cloned at depth 1, or a local checkout cloned from")
    parser.add_argument("--monorepo-ref", default="", help="the branch to clone (a mirror's HEAD may name none)")
    parser.add_argument("--submodule-url", default="https://github.com/octocat/Hello-World.git")
    parser.add_argument("--big-files", type=int, default=20000, help="files in the big non-Git folder")
    parser.add_argument("--projection-big-files", type=int, default=100000,
                        help="files in the huge-monorepo projection fixture")
    parser.add_argument("--projection-sparse-bytes", type=int, default=3 * 1024 ** 3,
                        help="logical bytes in the huge-monorepo sparse build output")
    parser.add_argument("--parallel", type=int, default=3, help="most machines at once")
    parser.add_argument("--timeout", type=int, default=900, help="seconds one start-chat may wait")
    parser.add_argument("--out", required=True, help="folder for matrix.json and matrix.md")
    parser.add_argument("--keep-fixtures", action="store_true")
    args = parser.parse_args(argv)
    if args.app and not (args.cloud_backend and args.expected_api_origin):
        parser.error("--app needs --cloud-backend and --expected-api-origin")
    if args.grant_claude_login and not args.app:
        # Never on --cli: that is a person's own app, and their consent is theirs to give.
        parser.error("--grant-claude-login works only with --app, the app this run launches")
    if args.cache_claude_login and not args.app:
        # Never on --cli: a person's own app keeps their own login.
        parser.error("--cache-claude-login works only with --app, the app this run launches")
    if args.cache_claude_login and not claude_login_cache.valid(claude_login_cache.token_from(os.environ)):
        parser.error(f"--cache-claude-login needs {claude_login_cache.TOKEN_ENV} set to a `claude setup-token` login")
    # The Cloud backend holds a script's creates and kills for approval, at most 5 pending per
    # install (approval-gate.ts MAX_PENDING_PER_IDENTITY): 2 cells at once leave room for their kills.
    args.parallel = max(1, min(args.parallel, 2))
    return args


def clean(text: str, limit: int = 600) -> str:
    text = (text or "").strip()
    return "[left out: secret-shaped]" if EVIDENCE_SCAN.search(text) else text[:limit]


def sh(*words: str, cwd=None, env=None, timeout=1800) -> str:
    done = subprocess.run(words, cwd=cwd, env=env, capture_output=True, text=True, timeout=timeout)
    if done.returncode != 0:
        raise RuntimeError(f"{' '.join(words[:3])}: exit {done.returncode}: {done.stderr.strip()[-400:]}")
    return done.stdout


GIT_ENV = {**os.environ, "GIT_AUTHOR_NAME": "cmux matrix", "GIT_AUTHOR_EMAIL": "matrix@cmux.invalid",
           "GIT_COMMITTER_NAME": "cmux matrix", "GIT_COMMITTER_EMAIL": "matrix@cmux.invalid",
           "GIT_CONFIG_NOSYSTEM": "1", "GIT_TERMINAL_PROMPT": "0"}


def git(path: Path, *words: str, timeout=1800) -> str:
    # No automatic maintenance: after a commit, git (2.47+) detaches a `maintenance run --auto` that can still be
    # rewriting a fixture's .git (packs, commit-graph) while its manifest is taken, so a fixture holding repositories
    # (parent-repos) hashed differently from one read to the next (base red in cmux-next checks).
    return sh("git", "-c", "init.defaultBranch=main", "-c", "protocol.file.allow=always",
              "-c", "maintenance.auto=false", "-c", "gc.auto=0", *words,
              cwd=path, env=GIT_ENV, timeout=timeout)


def write(path: Path, text: str | bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(text if isinstance(text, bytes) else text.encode())


def small_repo(path: Path) -> None:
    path.mkdir(parents=True)
    git(path, "init", "-q")
    write(path / "README.md", "# small\n")
    write(path / "src/main.py", "print('hello')\n")
    write(path / "src/util.py", "def add(a, b):\n    return a + b\n")
    write(path / ".gitignore", "*.log\n")
    git(path, "add", "-A")
    git(path, "commit", "-qm", "first")


def projection_repo(path: Path, remote: str | None = None) -> None:
    """The tiny repository used by the projection kinds, with explicit round-trip targets."""
    small_repo(path)
    write(path / "projection-edit.txt", "before\n")
    write(path / "projection-delete.txt", "remove me\n")
    write(path / "projection-rename-old.txt", "rename me\n")
    git(path, "add", "-A")
    git(path, "commit", "-qm", "projection actions")
    if remote:
        git(path, "remote", "add", "origin", remote)


def build_fixture(kind: str, root: Path, args, canary: str) -> tuple[Path | None, str]:
    """The cell's folder, made under ROOT, and a note (a skip reason when it cannot be made here)."""
    path = root / kind
    if kind == "bare-folder":
        path.mkdir(parents=True)
        write(path / "projection-edit.txt", "before\n")
        write(path / "projection-delete.txt", "remove me\n")
        write(path / "projection-rename-old.txt", "rename me\n")
    elif kind == "public-remote":
        projection_repo(path, "https://github.com/manaflow-ai/cmux.git")
    elif kind == "local-only-repo":
        projection_repo(path)
    elif kind == "huge-monorepo":
        # The sparse image gives the fixture multi-GB logical size without consuming the runner disk.
        projection_repo(path, "https://github.com/manaflow-ai/cmux.git")
        for index in range(max(1, args.projection_big_files)):
            write(path / "tree" / f"d{index % 1000:04d}" / f"f{index:06d}.txt", f"{index}\n")
        with open(path / "build-image.bin", "wb") as sparse:
            sparse.truncate(max(1, args.projection_sparse_bytes))
    elif kind == "build-output":
        path.mkdir(parents=True)
        write(path / "package.json", '{"name":"projection-fixture"}\n')
        write(path / "src/index.js", "export default 1;\n")
        for index in range(100):
            write(path / "node_modules/pkg" / f"module-{index:03d}.js", "module.exports = 1;\n")
        write(path / "Cargo.toml", "[package]\nname = \"projection-fixture\"\nversion = \"0.0.0\"\n")
        write(path / "target/debug/app", "debug\n")
        write(path / "dist/bundle.js", "bundle\n")
        write(path / "projection-edit.txt", "before\n")
        write(path / "projection-delete.txt", "remove me\n")
        write(path / "projection-rename-old.txt", "rename me\n")
    elif kind == "symlinks":
        path.mkdir(parents=True)
        write(path / "projection-edit.txt", "before\n")
        write(path / "projection-delete.txt", "remove me\n")
        write(path / "projection-rename-old.txt", "rename me\n")
        write(path / "inside/target.txt", "inside\n")
        outside = root / "projection-outside.txt"
        write(outside, "outside\n")
        os.symlink("inside/target.txt", path / "relative-link")
        os.symlink(str(outside), path / "absolute-link")
        os.symlink("../../projection-outside.txt", path / "escaping-link")
        os.symlink("missing-target", path / "dangling-link")
        write(path / "CaseOnly.txt", "case\n")
        write(path / "case-only-source.txt", "case rename\n")
    elif kind == "empty":
        path.mkdir(parents=True)
    elif kind == "small-repo":
        small_repo(path)
    elif kind == "monorepo":
        source = args.monorepo
        if Path(source).is_dir():
            source = Path(source).resolve().as_uri()
        branch = ("--branch", args.monorepo_ref) if args.monorepo_ref else ()
        git(root, "clone", "-q", "--depth", "1", "--no-recurse-submodules", *branch, source, str(path), timeout=1800)
        if not any(entry.name != ".git" for entry in path.iterdir()):
            raise RuntimeError(f"the clone of {args.monorepo} checked out nothing (give --monorepo-ref)")
    elif kind == "private-remote":
        if args.projection_kinds:
            projection_repo(path, "https://github.com/manaflow-ai/cmuxterm-hq.git")
        else:
            small_repo(path)
            git(path, "remote", "add", "origin", "https://github.com/manaflow-ai/cmuxterm-hq.git")
    elif kind == "submodules":
        # A public GitHub submodule, as a real project has: the machine fetches it itself (a file://
        # submodule only this Mac can reach is not a workspace anyone moves to Cloud).
        path.mkdir(parents=True)
        git(path, "init", "-q")
        write(path / "top.txt", "top\n")
        git(path, "submodule", "add", "-q", "--depth", "1", args.submodule_url, "vendor/child")
        git(path, "add", "-A")
        git(path, "commit", "-qm", "with a submodule")
    elif kind == "lfs":
        try:
            sh("git", "lfs", "version")
        except (OSError, RuntimeError):
            return None, "skipped: no git-lfs on this host"
        small_repo(path)
        git(path, "lfs", "install", "--local")
        git(path, "lfs", "track", "*.bin")
        write(path / "assets/blob.bin", os.urandom(8 * 1024 * 1024))
        git(path, "add", "-A")
        git(path, "commit", "-qm", "an LFS file")
    elif kind == "dirty":
        small_repo(path)
        write(path / "src/main.py", "print('changed, not staged')\n")
        write(path / "src/util.py", "def add(a, b):\n    return b + a  # staged\n")
        git(path, "add", "src/util.py")
        (path / "README.md").unlink()
        write(path / "notes/untracked.md", "untracked\n")
        write(path / "debug.log", "ignored by .gitignore\n")
    elif kind == "big-plain":
        path.mkdir(parents=True)
        for index in range(args.big_files):
            write(path / f"d{index % 200:03d}" / f"f{index:05d}.txt", f"{index}\n" * (1 + index % 512))
        for index in range(4):
            write(path / "large" / f"blob{index}.bin", os.urandom(32 * 1024 * 1024))
    elif kind == "huge-plain":
        path.mkdir(parents=True)
        write(path / "src/app.py", "print('hi')\n")
        with open(path / "disk.img", "wb") as sparse:
            sparse.truncate(HUGE_PLAIN_BYTES)
    elif kind == "huge-repo":
        # One repository past the limits, its own folder for the chat (cmuxterm-hq#11697): a sparse 21 GiB
        # untracked build product beside its sources.
        small_repo(path)
        with open(path / "disk.img", "wb") as sparse:
            sparse.truncate(HUGE_PLAIN_BYTES)
    elif kind in ("parent-repos", "huge-parent-repos"):
        # ~/Projects' shape: no repository itself, repositories right inside it and one level down.
        path.mkdir(parents=True)
        for name in PARENT_REPOS:
            small_repo(path / name)
        write(path / "notes.md", "a parent of repositories\n")
        if kind == "huge-parent-repos":
            with open(path / "disk.img", "wb") as sparse:
                sparse.truncate(HUGE_PLAIN_BYTES)
    elif kind == "public-remote":
        small_repo(path)
        git(path, "remote", "add", "origin", "https://github.com/octocat/Hello-World.git")
    elif kind == "heavy":
        # A JS project as it sits after `npm install` and a build: node_modules and build/ stay on the Mac.
        small_repo(path)
        write(path / "package.json", '{"name": "heavy", "scripts": {"build": "true"}}\n')
        for index in range(3000):
            write(path / "node_modules" / f"pkg{index % 300:03d}" / f"f{index:04d}.js", "module.exports = 1;\n" * 40)
        for index in range(200):
            write(path / "build" / f"chunk{index:03d}.js", "x" * 20000)
        write(path / "dist/bundle.js", os.urandom(4 * 1024 * 1024))
        write(path / ".gitignore", "*.log\nnode_modules/\nbuild/\ndist/\n")
        git(path, "add", "-A")
        git(path, "commit", "-qm", "ignore the build")
    elif kind == "case-rename":
        # Symlinks, and a file renamed by case only (a case-insensitive Mac keeps one name; Linux sees the new one).
        small_repo(path)
        write(path / "Docs/Readme.md", "case\n")
        git(path, "add", "-A")
        git(path, "commit", "-qm", "Readme")
        git(path, "mv", "Docs/Readme.md", "Docs/tmp.md")
        git(path, "mv", "Docs/tmp.md", "Docs/README.md")
        git(path, "commit", "-qm", "rename by case only")
        os.symlink("src/main.py", path / "link-inside")
        os.symlink("/etc/hosts", path / "link-outside")
        os.symlink("nowhere", path / "link-broken")
        os.symlink("Docs", path / "docs-link")
    elif kind == "large-binaries":
        path.mkdir(parents=True)
        write(path / "README.txt", "model weights\n")
        for index, size in enumerate(LARGE_BINARY_MB):
            with open(path / f"weights{index}.bin", "wb") as out:
                for _ in range(size):
                    out.write(os.urandom(1024 * 1024))
    elif kind == "media":
        path.mkdir(parents=True)
        for index, size in enumerate(MEDIA_MB):
            with open(path / f"clip{index}.mp4", "wb") as out:
                out.write(b"\x00\x00\x00\x20ftypisom\x00\x00\x02\x00isomiso2avc1mp41")
                for _ in range(size):
                    out.write(os.urandom(1024 * 1024))
    elif kind == "secrets":
        path.mkdir(parents=True)
        write(path / "app.py", "print('uses env')\n")
        line = f"CMUX_MATRIX_CANARY={canary}\n"
        for name in (".env", ".env.local", ".env.production", "config/.env.test", "id_rsa", "deploy/server.key",
                     "certs/client.pem", ".aws/credentials", ".ssh/config", ".netrc", "web/.npmrc",
                     ".config/gh/hosts.yml", ".docker/config.json", ".git-credentials"):
            write(path / name, line)
    elif kind == "odd-names":
        path.mkdir(parents=True)
        write(path / "with space/file name.txt", "space\n")
        write(path / "ünïcödé/日本語.txt", "unicode\n")
        write(path / "deep" / ("/".join(f"l{i}" for i in range(30))) / "bottom.txt", "deep\n")
        write(path / "empty.txt", b"")
        write(path / "exec.sh", "#!/bin/sh\necho hi\n")
        os.chmod(path / "exec.sh", 0o755)
        write(path / "node_modules/pkg/index.js", "module.exports = 1\n")
        write(path / "package.json", "{}\n")
        write(path / "build/out.js", "built\n")
        os.symlink("exec.sh", path / "link-inside")
        os.symlink("/etc/hosts", path / "link-outside")
        os.symlink("nowhere", path / "link-broken")
    else:
        raise ValueError(kind)
    return path, ""


def skipped(relative: str, is_dir: bool, parent: Path, name: str) -> str:
    """Why a copy leaves RELATIVE out (skips.rs), or ''."""
    lower = relative.lower()
    parts = lower.split("/")
    folders = parts if is_dir else parts[:-1]
    for end in range(1, len(folders) + 1):
        for credential in CREDENTIAL_FOLDERS:
            want = credential.split("/")
            if end >= len(want) and folders[end - len(want):end] == want:
                return "secret"
    if is_dir:
        if name in HEAVY_ALWAYS or (name == "venv" and (parent / "venv/pyvenv.cfg").is_file()):
            return "heavy"
        if name in HEAVY_BESIDE and any((parent / beside).is_file() for beside in HEAVY_BESIDE[name]):
            return "heavy"
        return ""
    if name.startswith(".env") or parts[-1] in CREDENTIAL_NAMES or lower.endswith(".config/hub"):
        return "secret"
    if parts[-1].startswith(("id_rsa", "id_ed25519", "id_ecdsa", "id_dsa")) or parts[-1].endswith(
            (".pem", ".p12", ".pfx", ".key")):
        return "secret"
    return ""


# The manifest, the same code here and on the machine: one line per file, `sha256 mode-x relative`,
# a symlink as `L target relative`; `.git` is left to the git check. The machine runs this with python3.
MANIFEST_PY = r'''
import hashlib, json, os, sys
root = sys.argv[1]
lines, size, links = [], 0, []
for top, dirs, files in os.walk(root):
    rel_top = os.path.relpath(top, root)
    dirs[:] = sorted(d for d in dirs if not (rel_top == "." and d == ".git"))
    if rel_top == ".":
        files = [f for f in files if f != ".cmux-sync.json"]  # the copy's own record (skips.rs Reserved)
    for name in files + [d for d in dirs if os.path.islink(os.path.join(top, d))]:
        full = os.path.join(top, name)
        rel = os.path.normpath(os.path.join(rel_top, name))
        if os.path.islink(full):
            links.append(rel); continue
        if not os.path.isfile(full):
            continue
        digest = hashlib.sha256()
        with open(full, "rb") as handle:
            for chunk in iter(lambda: handle.read(1 << 20), b""):
                digest.update(chunk)
        size += os.path.getsize(full)
        lines.append("%s %s %s" % (digest.hexdigest(), "x" if os.access(full, os.X_OK) else "-", rel))
lines.sort(key=lambda line: line.split(" ", 2)[2])
canary = sys.argv[2] if len(sys.argv) > 2 else ""
hits = []
if canary:
    for line in lines:
        rel = line.split(" ", 2)[2]
        full = os.path.join(root, rel)
        try:
            if not os.path.islink(full) and canary.encode() in open(full, "rb").read():
                hits.append(rel)
        except OSError:
            pass
by_top = {}
for line in lines:
    top = line.split(" ", 2)[2].split("/", 1)[0]
    by_top.setdefault(top, []).append(line)
print(json.dumps({"files": len(lines), "bytes": size,
                  "sha256": hashlib.sha256("\n".join(lines).encode()).hexdigest(),
                  "tops": {top: hashlib.sha256("\n".join(v).encode()).hexdigest() for top, v in by_top.items()},
                  "lines": lines if len(lines) <= int(sys.argv[3] if len(sys.argv) > 3 else 400) else None,
                  "canary_hits": hits, "symlinks": sorted(links)[:50]}))
'''


def git_ignored(folder: Path) -> set[str]:
    """The untracked files a Git folder's .gitignore keeps out: a copy of a Git folder sends
    `git ls-files --cached --others --exclude-standard` (sync_cli/local.rs), never these."""
    if not (folder / ".git").exists():
        return set()
    try:
        out = git(folder, "ls-files", "-z", "--others", "--ignored", "--exclude-standard", timeout=600)
    except RuntimeError:
        return set()
    return {path for path in out.split("\0") if path}


def local_manifest(folder: Path, canary: str) -> dict:
    """The manifest of what this Mac should send: MANIFEST_PY's form, over the files a copy keeps."""
    lines, size, left_out = [], 0, {}
    ignored = git_ignored(folder)
    for top, dirs, files in os.walk(folder):
        top_path = Path(top)
        rel_top = os.path.relpath(top, folder)
        keep = []
        for name in sorted(dirs):
            rel = os.path.normpath(os.path.join(rel_top, name))
            if rel_top == "." and name == ".git":
                continue
            why = "symlink" if (top_path / name).is_symlink() else skipped(rel, True, top_path, name)
            if why:
                left_out[why] = left_out.get(why, 0) + 1
            else:
                keep.append(name)
        dirs[:] = keep
        for name in files:
            full = top_path / name
            rel = os.path.normpath(os.path.join(rel_top, name))
            if full.is_symlink():
                left_out["symlink"] = left_out.get("symlink", 0) + 1
                continue
            why = "gitignored" if rel in ignored else skipped(rel, False, top_path, name)
            if why:
                left_out[why] = left_out.get(why, 0) + 1
                continue
            if not full.is_file():
                continue
            digest = hashlib.sha256()
            with open(full, "rb") as handle:
                for chunk in iter(lambda: handle.read(1 << 20), b""):
                    digest.update(chunk)
            size += full.stat().st_size
            lines.append(f"{digest.hexdigest()} {'x' if os.access(full, os.X_OK) else '-'} {rel}")
    lines.sort(key=lambda line: line.split(" ", 2)[2])
    by_top: dict[str, list[str]] = {}
    for line in lines:
        by_top.setdefault(line.split(" ", 2)[2].split("/", 1)[0], []).append(line)
    return {"files": len(lines), "bytes": size, "sha256": hashlib.sha256("\n".join(lines).encode()).hexdigest(),
            "tops": {top: hashlib.sha256("\n".join(v).encode()).hexdigest() for top, v in by_top.items()},
            "lines": lines, "left_out": left_out}


def git_state(folder: Path) -> dict | None:
    if not (folder / ".git").exists():
        return None
    try:
        head = git(folder, "rev-parse", "HEAD", timeout=60).strip()
    except RuntimeError:
        head = ""
    try:
        status = git(folder, "status", "--porcelain=v1", "--untracked-files=no", timeout=300)
    except RuntimeError:
        status = ""
    return {"head": head, "status_sha256": hashlib.sha256(status.encode()).hexdigest(),
            "changed": len(status.splitlines())}


def launch_argv(app: str, socket: str, credentials_file: str | None, backend: str, config: str) -> list[str]:
    """The `open` command that starts --app on its own socket and its own cmux.json, as cloud-chat-proof.py
    does. The socket goes only as CMUX_NEXT_SOCKET_PATH: CMUX_SOCKET_PATH marks another cmux, and the app
    then strips the CMUX_NEXT_* knobs, this socket included, so it never answered on it (CI run 42833136507).
    CMUX_NEXT_CONFIG_FILE keeps every setting the run reads or writes out of the shared
    ~/.config/cmux/cmux-next.json that the person's other apps read."""
    argv = ["/usr/bin/open", "-W", "-g", "-n", "--env", f"CMUX_NEXT_SOCKET_PATH={socket}",
            "--env", f"CMUX_NEXT_CONFIG_FILE={config}"]
    if credentials_file:
        argv += ["--env", f"CMUX_AUTH_CREDENTIALS_FILE={Path(credentials_file).resolve()}",
                 "--env", "CMUX_DEV_AUTH_PROFILE=agent", "--env", "CMUX_DEV_AUTH_REPLACE_SESSION=1"]
    return argv + [str(Path(app).resolve()), "--args", "--cloud-backend", backend]


CLAUDE_LOGIN_SETTING = ("cloud", "useMyClaudeLoginOnMyCloudMachines")


def start_login(agent: str, login: str) -> list[str]:
    """A Claude cell's start-chat `--login` words: none unless `--login` names one. `none` copies nothing, so Claude runs
    on the machine's team mode (the SR2/CodeRouter gateway) and needs no consent. Codex never takes it: `none` would
    leave it signed out (its login is the Mac's broker)."""
    # `cmux cloud start-chat` has no --login any more (a machine's agents reach models through the Cloud model route;
    # run 45643863592 died on `unexpected argument "--login"`), so no value is passed on.
    return []


def list_unread(message: str) -> bool:
    """The app's refusal when its machine list was not fresh enough to check the name (CloudStartSessionStrings
    listUnread); the message itself says to run the same command again."""
    return "Couldn't read your Cloud machines" in (message or "")


def scratch_config(folder: Path, grant_claude_login: bool) -> Path:
    """The launched app's own cmux.json (0600), deleted with the run's temporary folder. With
    --grant-claude-login it holds the one-time consent a Release build's claude chat on the account's own
    machine waits for (CloudLoginCopyConsentSetting: only the file can say yes). Run 42864046223 failed
    all 20 cells on it. A file, not `settings set`: that write asks a person on screen, which CI has not."""
    config: dict = {}
    if grant_claude_login:
        config = {CLAUDE_LOGIN_SETTING[0]: {CLAUDE_LOGIN_SETTING[1]: True}}
    path = folder / "cmux-next.json"
    path.touch(mode=0o600)
    path.write_text(json.dumps(config, indent=2) + "\n")
    return path


class Matrix:
    def __init__(self, args):
        self.args = args
        self.cli = args.cli or str(Path(args.app) / "Contents/Resources/bin/cmux")
        self.env = dict(os.environ)
        # The token goes to `cloud secret set` on stdin only; no CLI call inherits it.
        self.claude_token = claude_login_cache.token_from(self.env) if args.cache_claude_login else ""
        self.env.pop(claude_login_cache.TOKEN_ENV, None)
        self.cached_logins: list[str] = []
        # The Claude connections this run added (claude_login_cache.connect), removed with the logins.
        self.added_connections: list[dict] = []
        self.config_dir = None
        if args.app:
            socket = f"/tmp/cmux-debug-{args.tag}.sock"
            self.config_dir = Path(tempfile.mkdtemp(prefix="cmux-matrix-config-"))
            self.config = scratch_config(self.config_dir, args.grant_claude_login)
            self.env.update(CMUX_SOCKET_PATH=socket, CMUX_NEXT_SOCKET_PATH=socket,
                            CMUX_NEXT_CONFIG_FILE=str(self.config))
        self.launcher = None
        self.lock = threading.Lock()
        self.machines: set[str] = set()
        self.stopping = threading.Event()
        # The run's live CLI children, under their own lock: stop() runs in the SIGTERM handler, which can
        # interrupt the main thread inside `self.lock` (launch, sweep, kill), and a Lock is not reentrant.
        # Nothing holds children_lock across a call that can be interrupted by a signal handler that then
        # needs it: the handler only reads a snapshot (`list()` is atomic under the GIL) and never waits.
        self.children_lock = threading.Lock()
        # (folder, the level it held before): the trust decisions this run wrote, put back at teardown.
        self.trusted: list[tuple[str, str]] = []
        self.children: set[subprocess.Popen] = set()

    def cmux(self, *words: str, timeout: int = 120) -> tuple[int, str, str]:
        # Once stop() ran, a cell's thread starts nothing more; the main thread's cleanup still runs.
        cell_thread = threading.current_thread() is not threading.main_thread()
        if self.stopping.is_set() and cell_thread:
            return 130, "", "stopped: the run was cancelled"
        child = subprocess.Popen([self.cli, *words], env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                 text=True)
        with self.children_lock:
            self.children.add(child)
        # A stop() between the check above and this registration took a snapshot without this child: look
        # again now that it is registered, so it is ended either by stop() or here, never neither.
        if self.stopping.is_set() and cell_thread:
            child.terminate()
        try:
            out, err = child.communicate(timeout=timeout)
            return child.returncode, out, err
        except subprocess.TimeoutExpired:
            child.kill()
            child.communicate()
            return 124, "", f"timed out after {timeout}s"
        finally:
            with self.children_lock:
                self.children.discard(child)

    def stop(self) -> None:
        """A cancelled run (SIGTERM): no cell starts another step, and the CLI calls cells are waiting on
        (this run's own children) end now, so cleanup runs at once rather than after 900 s starts. Safe in a
        signal handler: it takes no lock (the interrupted frame may hold one) and only reads a snapshot."""
        self.stopping.set()
        for child in list(self.children):
            try:
                child.terminate()
            except OSError:
                pass

    @staticmethod
    def parsed(text: str) -> dict:
        for candidate in [text, *reversed((text or "").splitlines())]:
            try:
                value = json.loads(candidate)
            except (json.JSONDecodeError, TypeError):
                continue
            if isinstance(value, dict):
                inner = value.get("result", value)
                return inner if isinstance(inner, dict) else {}
        return {}

    def error(self, out: str, err: str) -> dict:
        for text in (err, out):
            value = self.parsed(text)
            if isinstance(value.get("code"), str) or isinstance(value.get("message"), str):
                return value
        return {}

    def launch(self) -> str:
        """Launch --app signed in (as cloud-chat-proof.py), or check --cli's app is signed in."""
        args = self.args
        if args.app:
            launch = launch_argv(args.app, self.env["CMUX_NEXT_SOCKET_PATH"], args.credentials_file,
                                 args.cloud_backend, str(self.config))
            self.launcher = subprocess.Popen(launch, env=launch_env(self.env), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        # As cloud-chat-proof.py waits: the launched app answers `app identify`, then `auth.status` says it
        # is signed in on the selected backend (the first CI run read `cloud list-machines` too early and
        # gave up at 300 s, run 42808502162). Then the machine list loads.
        steps = []
        if args.app:
            app_path = str(Path(args.app).resolve())
            steps.append(("app identify", ("app", "identify", "--json"), 240,
                          lambda v: bool(v.get("pid")) and v.get("app_bundle_path") == app_path))
            origin = (args.expected_api_origin or "").rstrip("/")
            steps.append(("auth.status", ("app", "call", "auth.status", "--json"), 300,
                          lambda v: v.get("signed_in") is True and v.get("cloud_environment") == args.cloud_backend
                          and str(v.get("backend", "")).rstrip("/") == origin))
        steps.append(("cloud list-machines", ("cloud", "list-machines", "--json"), 300,
                      lambda v: bool((v.get("account") or {}).get("signed_in")) and v.get("loaded") is not False))
        status = {}
        for name, words, limit, ready in steps:
            deadline, last = time.monotonic() + limit, ""
            while True:
                code, out, err = self.cmux(*words, timeout=30)
                value = self.parsed(out) if code == 0 else {}
                if code == 0 and ready(value):
                    status = value if name == "auth.status" else status
                    break
                last = clean(self.error(out, err).get("message") or err or json.dumps(
                    {k: value.get(k) for k in ("signed_in", "backend", "cloud_environment", "loaded") if k in value}), 300)
                if time.monotonic() >= deadline:
                    return f"the app is not ready: {name} after {limit} s ({last})"
                time.sleep(3)
        if args.cache_claude_login:
            # The entries a start reads for this account (CloudCredentialLogin.loadAny): its team's, then its personal one.
            entries = claude_login_cache.names(status)
            if not entries:
                return "the app is not ready: auth.status names no user to cache a Claude login for"
            for entry in entries:
                self.cached_logins.append(entry)
                code, err = claude_login_cache.store(self.cli, self.env, entry, self.claude_token)
                if code != 0:
                    return f"cache claude login: exit {code} ({clean(err, 300)})"
            # A cached login is not a connection: the start gate runs a Claude chat only when one serves Cloud
            # (or the team's gateway does). Add it as this account's Claude connection, as Set up Claude does.
            code, err, added = claude_login_cache.connect(self.cli, self.env, self.claude_token,
                                                          f"matrix {self.args.tag}")
            if added:
                self.added_connections.append(added)
            elif code != 0:
                return f"add claude connection: exit {code} ({clean(err, 300)})"
            else:
                return "add claude connection: the answer named no connection"
        return ""

    def remove_logins(self) -> list[str]:
        """Removes every cached Claude login from the Keychain; answers the ones that could not be removed."""
        left = []
        while self.cached_logins:
            entry = self.cached_logins.pop()
            code, err = claude_login_cache.remove(self.cli, self.env, entry)
            if code != 0:
                left.append(f"{entry}: exit {code} ({clean(err, 200)})")
        while self.added_connections:
            added = self.added_connections.pop()
            code, err = claude_login_cache.disconnect(self.cli, self.env, added)
            if code != 0:
                left.append(f"connection {added['id']}: exit {code} ({clean(err, 200)})")
        return left

    def quit(self) -> None:
        for problem in self.remove_logins():  # the backstop of a cancelled or crashed run: never silent
            print(f"cached claude login NOT removed: {problem}", file=sys.stderr, flush=True)
        if self.launcher is not None:
            self.cmux("app", "quit", "--json", timeout=30)
            try:
                self.launcher.wait(timeout=60)
            except subprocess.TimeoutExpired:
                pass
            self.launcher = None
        if self.config_dir is not None:
            shutil.rmtree(self.config_dir, ignore_errors=True)
            self.config_dir = None

    def trust(self, folder: Path) -> str:
        """Trusts a fixture this run made, as a person does on this Mac before a Cloud start: a start from a folder
        this Mac doesn't trust is refused before any machine (#41079), which left every cell red at 0.0 s. Never
        called on a --folder (a person's own folder): its refusal is the finding. Answers "" or the cell's failure.

        The decision lands in this Mac's real trust record (acpmux's trust.json, which the app's start check reads),
        so each one written is kept with the level it replaced and put back by ``forget_trust`` at teardown: a run
        leaves no trusted temp path behind for a later folder at that path to inherit."""
        code, out, err = self.cmux("--json", "setup", "trust", str(folder))
        if code != 0:
            return f"fail: trust: {clean(self.error(out, err).get('message') or err or out, 300)}"
        report = self.parsed(out)
        if report.get("written"):
            with self.children_lock:
                self.trusted.append((str(report["written"]), str(report.get("recorded") or "unknown")))
        return ""

    def forget_trust(self) -> list[str]:
        """Puts back every trust decision ``trust`` wrote, newest first (`unknown` forgets it). Runs before the
        fixtures are deleted, while their paths still resolve. Answers the folders it could not put back."""
        left = []
        with self.children_lock:
            trusted, self.trusted = self.trusted, []
        for folder, level in reversed(trusted):
            code, _, _ = self.cmux("--json", "setup", "trust", folder, "--level", level)
            if code != 0:
                left.append(folder)
        return left

    def kill(self, machine: str) -> bool:
        for _ in range(2):
            code, _, _ = self.cmux("cloud", "kill-machine", "--target", f"machine:{machine}", "--confirm", "--json",
                                   timeout=120)
            if code == 0:
                with self.lock:
                    self.machines.discard(machine)
                return True
        return False

    def machine_titled(self, title: str) -> str | None:
        code, out, _ = self.cmux("cloud", "list-machines", "--json", timeout=60)
        rows = (self.parsed(out).get("machines") or []) if code == 0 else []
        return next((row.get("machine_id") for row in rows
                     if isinstance(row, dict) and row.get("title") == title and row.get("machine_id")), None)

    def sweep(self) -> list[str]:
        """Kill every machine still named after this run; answer the ones that would not go."""
        code, out, _ = self.cmux("cloud", "list-machines", "--json", timeout=60)
        rows = (self.parsed(out).get("machines") or []) if code == 0 else []
        left = []
        for row in rows:
            if isinstance(row, dict) and str(row.get("title", "")).startswith(self.args.tag):
                if not self.kill(row.get("machine_id", "")):
                    left.append(row.get("machine_id", ""))
        return left + sorted(self.machines)

    def find_copy(self, machine: str, folder: Path, word: str) -> str:
        """The copy of FOLDER on the machine: the folder holding the word's file, else the newest folder
        named after it (CloudMoveFolder: the local name plus a short hash) under the work roots."""
        roots = "/home/cmux/work /root/work /home/cmux/chats /root/chats"
        if word:
            command = (f"for f in $(find {roots} -maxdepth 4 -name {WORD_FILE} 2>/dev/null); do "
                       f"grep -qx {shlex_quote(word)} \"$f\" && dirname \"$f\"; done | head -1")
        else:
            command = (f"ls -dt $(find {roots} -maxdepth 2 -type d -name {shlex_quote(folder.name + '*')} 2>/dev/null) "
                       "2>/dev/null | head -1")
        code, out, _ = self.cmux("cloud", "exec", "--target", f"machine:{machine}", "--command", command, "--json",
                                 timeout=120)
        stdout = self.parsed(out).get("stdout") if code == 0 else ""
        return (stdout or "").strip().splitlines()[0] if (stdout or "").strip() else ""

    def exec_json(self, machine: str, command: str, timeout: int = 600) -> tuple[dict, str]:
        code, out, err = self.cmux("cloud", "exec", "--target", f"machine:{machine}", "--command", command,
                                   "--json", timeout=timeout + 30)
        if code != 0:
            return {}, clean(self.error(out, err).get("message") or err or f"exit {code}")
        answer = self.parsed(out)
        stdout = answer.get("stdout") if isinstance(answer.get("stdout"), str) else ""
        for line in reversed(stdout.splitlines()):
            try:
                return json.loads(line), ""
            except json.JSONDecodeError:
                continue
        return {}, clean(answer.get("stderr") or "no JSON from the machine")

    def run_cell(self, name: str, agent: str, folder: Path | None, note: str, *, word: str, canary: str,
                 read_only: bool) -> dict:
        cell = {"workspace": name, "agent": agent, "result": "", "notes": []}
        if self.stopping.is_set():
            cell["result"] = "skipped: the run was cancelled"
            return cell
        if folder is None:
            cell["result"] = note or "skipped"
            return cell
        started = time.monotonic()
        # A first-pass cell's tree is not compared (the rest stays on the Mac), and hashing its 21 GiB
        # sparse file would read 21 GiB of zeros.
        projection = bool(self.args.projection_kinds)
        cell["projection"] = projection
        expected = {"files": None, "bytes": None, "left_out": {}, "sha256": None, "tops": {}, "lines": []} \
            if name in FIRST_PASS_CELLS else local_manifest(folder, canary)
        cell["local"] = {key: expected[key] for key in ("files", "bytes", "left_out")}
        cell["local"]["manifest_s"] = round(time.monotonic() - started, 1)
        cell["local_git"] = git_state(folder)
        title = re.sub(r"[^A-Za-z0-9-]", "-", f"{self.args.tag}-{name}-{agent}")[:60]
        # File reads only: a shell command makes the agent ask permission first, and a headless --wait
        # then ends at chat.permission_waiting (the first live run, 2026-11-10). The copy's folder on
        # the machine is found with `cloud exec`, not from the reply.
        ask_word = "" if read_only or name == "empty" else (
            f" Read the file {WORD_FILE} in your working folder with your file-reading tool; it holds one word.")
        if projection and not read_only:
            prompt = ("This is an automated projected-folder check. Use only your file tools, never a shell command. "
                      "Read cmux-matrix-word.txt, edit projection-edit.txt to exactly 'after\\n', delete "
                      "projection-delete.txt, rename projection-rename-old.txt to projection-rename-new.txt, "
                      "and create projection-created.txt containing exactly 'created\\n'. "
                      "Also rename CaseOnly.txt to caseonly.txt without changing its contents. "
                      "Reply on one line in exactly this form and nothing else: PROJECTION_OK word=<the word>")
            form = "PROJECTION_OK"
        else:
            form = "MATRIX_OK" + ("" if not ask_word else " word=<the word>")
            prompt = (f"This is an automated check of the folder this chat started in. Do not run any shell command."
                      f"{ask_word} Reply on one line in exactly this form and nothing else: {form}")
        chat_started = time.monotonic()
        deadline = chat_started + self.args.timeout
        while True:
            code, out, err = self.cmux("cloud", "start-chat", "--from-folder", str(folder), "--prompt", prompt,
                                       "--agent", agent, *start_login(agent, self.args.login), "--name", title,
                                       "--wait", "--timeout", str(self.args.timeout), "--json",
                                       timeout=self.args.timeout + 60)
            if time.monotonic() > deadline:
                break
            if code == 75:
                time.sleep(5)
                continue
            if code != 0 and list_unread(self.error(out, err).get("message") or err):
                # The app refuses a start while its machine list is stale (CloudStartSession listFresh): two
                # prod cells failed in 0.4 s and 2.1 s that way (run 42864046223). Read the list, then ask again.
                self.cmux("cloud", "list-machines", "--json", timeout=60)
                time.sleep(5)
                continue
            break
        cell["create_to_reply_s"] = round(time.monotonic() - chat_started, 1)
        answer = self.parsed(out) if code == 0 else {}
        failure = self.error(out, err)
        details = failure.get("details") or {}
        machine = (answer.get("machine_id") or details.get("machine_id")
                   or (details.get("answer") or {}).get("machine_id"))
        if not machine:
            # Some refusals name the machine they made only in their text ("--target vm:vm_…"): a cell
            # that misses it would leave the machine running.
            named = re.search(r"\b(vm_[0-9a-f]{8,64})\b", f"{failure.get('message', '')} {err} {out}")
            machine = named.group(1) if named else None
        if not machine and code != 0:
            machine = self.machine_titled(title)
        if machine:
            with self.lock:
                self.machines.add(machine)
        cell["start_exit"] = code
        if code != 0:
            cell["start_error"] = clean(f"{failure.get('code', '')}: {failure.get('message', '')}".strip(": ")
                                        or err or out, 800)
        reply = answer.get("reply") if isinstance(answer.get("reply"), str) else ""
        # The start's own stage times (CloudStartSession: stages_ms, stages_detail_ms) and the copy's counts.
        # The copy's estimate, made before any machine (link/sync_cli/estimate.rs): the verdict checks it.
        if isinstance(answer.get("estimate"), dict):
            cell["estimate"] = {key: answer["estimate"].get(key) for key in
                                ("mode", "copy_mode", "files", "bytes", "seconds", "left_bytes", "why", "complete")}
        first_ms = first_text_ms(answer.get("stages_ms"))
        if first_ms is None:
            first_ms = first_text_ms(answer.get("stages_detail_ms"))
        if first_ms is None:
            first_ms = first_text_ms(answer)
        if first_ms is not None:
            cell["first_text_ms"] = first_ms
            cell["first_text_s"] = round(first_ms / 1000, 3)
        moved, moved_source = copy_bytes(answer)
        if moved is not None:
            cell["bytes_moved"] = moved
            cell["bytes_moved_source"] = moved_source
        for key in ("stages_ms", "stages_detail_ms", "ready_ms", "copy", "seed", "mode", "skipped_counts", "projected"):
            if isinstance(answer.get(key), (dict, list, int, str)):
                cell.setdefault("answer_timing", {})[key] = json.loads(clean(json.dumps(answer[key]), 4000)) \
                    if not EVIDENCE_SCAN.search(json.dumps(answer[key])) else "[left out]"
        match = re.search(r"MATRIX_OK", reply)
        remote = ""
        for key in ("folder", "cwd", "remote_folder", "path"):
            if isinstance(answer.get(key), str) and answer[key].startswith("/"):
                remote = answer[key]
                break
        if machine and not remote and code == 0:
            remote = self.find_copy(machine, folder, word if ask_word else "")
        cell["reply"] = {
            "observed": bool(reply),
            "form_ok": bool(re.search(r"PROJECTION_OK" if projection else r"MATRIX_OK", reply)),
            "word_ok": (not ask_word) or (f"word={word}" in reply),
            "canary_in_reply": bool(canary) and canary in reply,
            "text": clean(reply.replace(canary, "[canary]") if canary else reply, 300),
        }
        cell["remote_folder"] = clean(remote, 300)
        # What the start moved before anything read the tree, then the intended read on the machine.
        cell["projection_log"] = projection_log(folder)
        if machine and remote and name in READ_PROBE_CELLS:
            probe = base64.b64encode(READ_PROBE_PY.encode()).decode()
            got, problem = self.exec_json(machine, f"echo {probe} | base64 -d > /tmp/cwm-read.py && "
                                                   f"python3 /tmp/cwm-read.py {shlex_quote(remote)}", timeout=900)
            cell["read_probe"] = got or {"error": problem}
            after = projection_log(folder)
            if isinstance(after.get("sent"), dict):
                cell["projection_log"]["sent_after_read"] = after["sent"]
        if projection and remote and machine and not read_only:
            # The agent actions are checked on the machine before cleanup.  Bring Back's full
            # three-way correctness is covered by the companion Rust matrix, which runs the same
            # projection-v1 daemon and is recorded beside this production row.
            action_probe = (
                "import json,os; r=%(r)s; "
                "read=lambda p: open(os.path.join(r,p), encoding='utf-8').read() if os.path.isfile(os.path.join(r,p)) else None; "
                "print(json.dumps({'edit':read('projection-edit.txt')=='after\\n',"
                "'created':read('projection-created.txt')=='created\\n',"
                "'deleted':not os.path.lexists(os.path.join(r,'projection-delete.txt')),"
                "'renamed':read('projection-rename-new.txt')=='rename me\\n' and not os.path.lexists(os.path.join(r,'projection-rename-old.txt')),"
                "'case_only_renamed':read('caseonly.txt')=='case\\n' and not os.path.lexists(os.path.join(r,'CaseOnly.txt'))}))" %
                {"r": json.dumps(remote)})
            actions, problem = self.exec_json(machine, f"python3 -c {shlex_quote(action_probe)}", timeout=120)
            cell["agent_actions"] = actions or {"error": problem}
            cell["agent_actions_ok"] = all(actions.get(key) is True for key in
                                            ("edit", "created", "deleted", "renamed", "case_only_renamed"))
        if machine and remote:
            script = base64.b64encode(MANIFEST_PY.encode()).decode()
            started = time.monotonic()
            got, problem = self.exec_json(machine, f"echo {script} | base64 -d > /tmp/cwm-manifest.py && "
                                                   f"python3 /tmp/cwm-manifest.py {shlex_quote(remote)} "
                                                   f"{shlex_quote(canary)} 400")
            cell["remote_manifest_s"] = round(time.monotonic() - started, 1)
            if problem:
                cell["notes"].append(f"manifest: {problem}")
            else:
                cell["remote"] = {key: got.get(key) for key in ("files", "bytes", "symlinks")}
                cell["hash_match"] = got.get("sha256") == expected["sha256"]
                cell["canary_on_machine"] = got.get("canary_hits") or []
                if not cell["hash_match"]:
                    cell["diff_tops"] = sorted(
                        top for top in set(expected["tops"]) | set(got.get("tops") or {})
                        if expected["tops"].get(top) != (got.get("tops") or {}).get(top))[:40]
                    if isinstance(got.get("lines"), list):
                        mine, theirs = set(expected["lines"]), set(got["lines"])
                        cell["only_here"] = sorted(line.split(" ", 2)[2] for line in mine - theirs)[:40]
                        cell["only_there"] = sorted(line.split(" ", 2)[2] for line in theirs - mine)[:40]
            if name in FIRST_PASS_CELLS:
                cell["left_on_mac"] = self.left_on_mac(answer, machine, remote)
            if cell["local_git"] and name not in FIRST_PASS_CELLS:
                git_probe = (f"cd {shlex_quote(remote)} && python3 -c \"import json,subprocess,hashlib;"
                             "r=lambda *a: subprocess.run(['git',*a],capture_output=True,text=True).stdout;"
                             "s=r('status','--porcelain=v1','--untracked-files=no');"
                             "print(json.dumps({'head':r('rev-parse','HEAD').strip(),"
                             "'status_sha256':hashlib.sha256(s.encode()).hexdigest(),'changed':len(s.splitlines())}))\"")
                got_git, problem = self.exec_json(machine, git_probe, timeout=300)
                cell["remote_git"] = got_git or {"error": problem}
                cell["git_match"] = bool(got_git) and got_git.get("head") == cell["local_git"]["head"] and \
                    got_git.get("status_sha256") == cell["local_git"]["status_sha256"]
        cell["machine_killed"] = self.kill(machine) if machine else None
        cell["result"] = verdict(cell, canary)
        return cell


def _left_on_mac(self, answer: dict, machine: str, remote: str) -> int:
    """How many files a first-pass cell left on the Mac: the copy's `left_on_mac` count when the answer carries it,
    else 1 when the cell's big file is not on the machine (0 when it is)."""
    counts = answer.get("skipped_counts") if isinstance(answer.get("skipped_counts"), dict) else {}
    if isinstance(counts.get("left_on_mac"), int):
        return counts["left_on_mac"]
    path = shlex_quote(f"{remote}/{FIRST_PASS_LEFT}")
    got, _ = self.exec_json(machine, f"if [ -e {path} ]; then echo '{{\"there\":true}}'; "
                                     f"else echo '{{\"there\":false}}'; fi", timeout=120)
    return 0 if got.get("there") is not False else 1


Matrix.left_on_mac = _left_on_mac


# Run on the machine: time a listing of the folder, then the first byte and the whole of its largest file.
READ_PROBE_PY = r"""
import json, os, sys, time
root = sys.argv[1]
t = time.monotonic(); entries = 0; largest = (0, "")
for top, dirs, files in os.walk(root):
    dirs[:] = [d for d in dirs if d != ".git"]
    for name in files:
        entries += 1
        p = os.path.join(top, name)
        try:
            st = os.lstat(p)
        except OSError:
            continue
        if not os.path.islink(p) and st.st_size > largest[0]:
            largest = (st.st_size, p)
out = {"entries": entries, "list_ms": round((time.monotonic() - t) * 1000)}
if largest[1]:
    out["largest_bytes"] = largest[0]
    out["largest"] = os.path.relpath(largest[1], root)
    t = time.monotonic()
    with open(largest[1], "rb") as f:
        f.read(1)
        out["first_byte_ms"] = round((time.monotonic() - t) * 1000)
        while f.read(1 << 20):
            pass
    out["whole_ms"] = round((time.monotonic() - t) * 1000)
out["mounted"] = any(line.split()[1] == root or root.startswith(line.split()[1] + "/")
                     for line in open("/proc/mounts") if "fuse" in line.split()[2])
print(json.dumps(out))
"""


def projection_log(folder: Path) -> dict:
    """The Mac-side projection server's own record of FOLDER's start (link/sync_cli/project.rs): its `ready`
    timing (entries, listed_ms, manifest_bytes, ready_ms, mount_ms) and its last `sent` line (file reads and bytes
    answered). {} when no server serves the folder: the start was a copy or seed, not a projection."""
    roots = [Path(os.environ[key]) for key in ("CMUX_TUI_STATE_DIR",) if os.environ.get(key)]
    roots.append(Path.home() / "Library/Application Support/cmux-tui/sessions")
    roots.append(Path.home() / ".local/state/cmux-tui/sessions")
    want = str(folder.resolve())
    for root in roots:
        for served in (root / "link-sync" / "projections").glob("*.served"):
            try:
                local = served.read_bytes().split(b"\0", 2)[-1].decode()
                if local != want:
                    continue
                found: dict = {"server": served.stem}
                for line in served.with_suffix(".log").read_text(errors="replace").splitlines():
                    for key in ("ready", "sent"):
                        prefix = f"cmux link project: {key} "
                        if line.startswith(prefix):
                            try:
                                found[key] = json.loads(line[len(prefix):])
                            except json.JSONDecodeError:
                                pass
                return found
            except OSError:
                continue
    return {}


def shlex_quote(text: str) -> str:
    return "'" + text.replace("'", "'\"'\"'") + "'"


def first_text_ms(value) -> float | None:
    """Return the start trace's create-to-first-text mark, wherever the CLI nested it."""
    if isinstance(value, dict):
        for key in ("create_to_first_text_ms", "first_text_ms"):
            number = value.get(key)
            if isinstance(number, (int, float)):
                return number
        if value.get("step") == "first_text" and isinstance(value.get("ms"), (int, float)):
            return value["ms"]
        for child in value.values():
            found = first_text_ms(child)
            if found is not None:
                return found
    elif isinstance(value, list):
        for child in value:
            found = first_text_ms(child)
            if found is not None:
                return found
    return None


def copy_bytes(answer: dict) -> tuple[int | None, str | None]:
    """Find bytes actually sent by the copy/seed response, with an explicit source label."""
    for key in ("copy_bytes", "bundle_bytes"):
        value = answer.get(key)
        if isinstance(value, int):
            return value, key
    for section_name in ("copy", "seed"):
        section = answer.get(section_name)
        if not isinstance(section, dict):
            continue
        for key in ("copy_bytes", "bundle_bytes", "bytes"):
            value = section.get(key)
            if isinstance(value, int):
                return value, f"{section_name}.{key}"
    estimate = answer.get("estimate")
    if isinstance(estimate, dict) and isinstance(estimate.get("bytes"), int):
        return estimate["bytes"], "estimate.bytes"
    return None, None


def verdict(cell: dict, canary: str) -> str:
    if cell.get("start_exit") != 0:
        return "fail: start-chat"
    problems = []
    reply = cell.get("reply") or {}
    if not reply.get("form_ok"):
        problems.append("reply form")
    if not reply.get("word_ok"):
        problems.append("word not read")
    if reply.get("canary_in_reply") or cell.get("canary_on_machine"):
        problems.append("SECRET LEAKED")
    # Every start says what its copy sends before any machine is made (Leo, 2026-11-10: a 20 GB copy began after a
    # machine was leased). A first-pass cell's must say first pass; any cell on a slow link may too, and is then
    # judged as one (its tree is partial by design).
    estimate = cell.get("estimate")
    copy_mode = None
    if not isinstance(estimate, dict):
        problems.append("no copy estimate before the lease")
    else:
        copy_mode = estimate.get("copy_mode") if estimate.get("mode") == "seed" else estimate.get("mode")
        if cell.get("workspace") in FIRST_PASS_CELLS and copy_mode != "first_pass":
            problems.append(f"estimate said {copy_mode}")
    first_pass = cell.get("workspace") in FIRST_PASS_CELLS or copy_mode == "first_pass"
    projection = bool(cell.get("projection"))
    if cell.get("hash_match") is False and not first_pass and not projection:
        problems.append("tree differs")
    if first_pass and (cell.get("create_to_reply_s") or 0) > FIRST_PASS_REPLY_WITHIN_S:
        problems.append(f"first reply after {cell.get('create_to_reply_s')} s")
    if first_pass and (cell.get("left_on_mac") or 0) < 1:
        problems.append("nothing left on the Mac")
    if cell.get("hash_match") is None and not projection:
        problems.append("tree not checked")
    if cell.get("git_match") is False and not projection:
        problems.append("git state differs")
    if projection and cell.get("agent_actions_ok") is not True:
        problems.append("projection actions")
    if cell.get("machine_killed") is False:
        problems.append("machine not killed")
    return "pass" if not problems else "fail: " + ", ".join(problems)


def grid(cells: list[dict]) -> str:
    rows = ["| Workspace | Agent | Result | First token | Bytes moved | Round trip | Create to reply | Mode | Ready ms | Manifest B | Sent at start | List ms | "
            "Largest: first byte / whole ms | Sent after read | Files (here / there) | Hash | Git | Secrets | Reply |",
            "|---|---|---|---:|---:|---|---:|---|---|---|---|---|---|---|---|---|---|---|---|"]
    for cell in cells:
        local, remote = cell.get("local") or {}, cell.get("remote") or {}
        hash_text = {True: "match", False: "differs", None: "-"}[cell.get("hash_match")]
        git_text = {True: "match", False: "differs", None: "-"}[cell.get("git_match")]
        leak = "LEAK" if (cell.get("canary_on_machine") or (cell.get("reply") or {}).get("canary_in_reply")) else (
            "none leaked" if cell["workspace"] == "secrets" else "-")
        projection = cell.get("projection_log") or {}
        ready = projection.get("ready") or {}
        probe = cell.get("read_probe") or {}
        mode = (cell.get("answer_timing") or {}).get("mode") or ("projected" if ready else "-")
        sent = (projection.get("sent") or {}).get("bytes", "-")
        sent_after = (projection.get("sent_after_read") or {}).get("bytes", "-")
        largest = (f"{probe.get('largest_bytes', '-')} B: {probe.get('first_byte_ms', '-')} / {probe.get('whole_ms', '-')}"
                   if probe.get("largest_bytes") else "-")
        first = cell.get("first_text_s")
        first_text = f"{first:.3f} s" if isinstance(first, (int, float)) else "-"
        moved = cell.get("bytes_moved")
        moved_text = str(moved) if isinstance(moved, int) else "-"
        actions = cell.get("agent_actions") or {}
        round_trip = "pass" if cell.get("agent_actions_ok") else ("-" if not cell.get("projection") else "fail")
        if cell.get("projection"):
            round_trip += "; conflict/no-loss: Rust"
        rows.append(f"| {cell['workspace']} | {cell['agent']} | {cell['result']} | {first_text} | {moved_text} | {round_trip} | "
                    f"{cell.get('create_to_reply_s', '-')} s | {mode} | {ready.get('ready_ms', '-')} | "
                    f"{ready.get('manifest_bytes', '-')} | {sent} | {probe.get('list_ms', '-')} | {largest} | {sent_after} | {local.get('files', '-')} / {remote.get('files', '-')} | "
                    f"{hash_text} | {git_text} | {leak} | {(cell.get('reply') or {}).get('text', '-')[:80]} |")
    return "\n".join(rows) + "\n"


def main(argv=None) -> int:
    args = parse_args(argv)
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    agents = [agent for agent in args.agents.split(",") if agent]
    only = {name for name in args.only.split(",") if name}
    if "kinds" in only:  # RFD 0007's folder kinds
        only = (only - {"kinds"}) | set(KIND_CELLS.values())
    selected = PROJECTION_KINDS if args.projection_kinds else WORKSPACES
    kinds = [kind for kind in selected if not only or kind in only]
    root = Path(tempfile.mkdtemp(prefix="cmux-matrix-"))
    canary = f"cmxcanary{random.token_hex(10)}"
    matrix = Matrix(args)
    # A cancelled CI job sends SIGTERM, which skips `finally`: stop the cells' work, then SystemExit, so
    # `finally` sweeps the machines, quits the app and deletes its scratch cmux.json.
    def cancelled(signum, frame):
        matrix.stop()
        sys.exit(128 + signum)
    signal.signal(signal.SIGTERM, cancelled)
    swept = False
    report = {"tag": args.tag, "agents": agents, "cells": [], "started": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
    try:
        problem = matrix.launch()
        if problem:
            report["result"] = f"fail: {problem}"
            return finish(report, out, 1)
        jobs = []
        for kind in kinds:
            started = time.monotonic()
            try:
                folder, note = build_fixture(kind, root, args, canary)
            except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
                folder, note = None, f"skipped: fixture: {clean(str(error), 300)}"
            word = f"w{random.token_hex(5)}"
            if folder is not None and kind != "empty":
                write(folder / WORD_FILE, word + "\n")
            if folder is not None:
                note = matrix.trust(folder) or note
                folder = None if note else folder
            jobs.append((kind, agents[0], folder, note, word, canary if kind == "secrets" else "", False,
                         round(time.monotonic() - started, 1)))
        for agent in agents[1:]:
            folder = root / f"small-repo-{agent}"
            small_repo(folder)
            word = f"w{random.token_hex(5)}"
            write(folder / WORD_FILE, word + "\n")
            note = matrix.trust(folder)
            jobs.append(("small-repo", agent, None if note else folder, note, word, "", False, 0.0))
        for spec in args.folder:
            name, _, path = spec.partition("=")
            folder = Path(path).expanduser()
            jobs.append((f"own:{name}", agents[0], folder if folder.is_dir() else None,
                         "" if folder.is_dir() else "skipped: not a folder", "", "", True, 0.0))
        pool = concurrent.futures.ThreadPoolExecutor(max_workers=args.parallel)
        try:
            futures = [pool.submit(matrix.run_cell, kind, agent, folder, note, word=word, canary=canary_value,
                                   read_only=read_only) for kind, agent, folder, note, word, canary_value, read_only, _
                       in jobs]
            for job, future in zip(jobs, futures):
                try:
                    cell = future.result()
                except Exception as error:  # one cell's crash is its own row, never the run's end
                    cell = {"workspace": job[0], "agent": job[1], "result": f"fail: {clean(repr(error), 300)}"}
                cell["fixture_s"] = job[7]
                report["cells"].append(cell)
                safe_print(f"[{cell['result']}] {cell['workspace']} ({cell['agent']})", flush=True)
        finally:
            # A `with` would wait for every queued cell: on SystemExit, drop the ones not yet started.
            pool.shutdown(wait=True, cancel_futures=True)
        left = matrix.sweep()
        swept = True
        report["machines_left"] = left
        logins_left = matrix.remove_logins()
        report["claude_logins_left"] = logins_left
        failed = [cell for cell in report["cells"] if not cell["result"].startswith(("pass", "skipped"))]
        report["result"] = "pass" if not failed and not left and not logins_left else f"fail: {len(failed)} cells" + (
            f", {len(left)} machines left" if left else "") + (
            f", {len(logins_left)} cached claude logins not removed" if logins_left else "")
        return finish(report, out, 0 if report["result"] == "pass" else 1)
    finally:
        if not swept:
            matrix.sweep()  # a cancelled or crashed run still deletes the machines it made
        untrusted = matrix.forget_trust()  # before the fixtures go, while their paths still resolve
        if untrusted:
            print(f"warning: trust left on {len(untrusted)} fixture folder(s): {', '.join(untrusted)}", file=sys.stderr)
        matrix.quit()
        if not args.keep_fixtures:
            shutil.rmtree(root, ignore_errors=True)


def finish(report: dict, out: Path, code: int) -> int:
    text = json.dumps(report, indent=2)
    if EVIDENCE_SCAN.search(text):
        text = json.dumps({"tag": report.get("tag"), "result": report.get("result"),
                           "note": "the full report held a secret-shaped value and was not written"})
    (out / "matrix.json").write_text(text + "\n")
    (out / "matrix.md").write_text(f"## Cloud workspace matrix ({report.get('tag')})\n\n{report.get('result', '')}\n\n"
                                   + grid(report.get("cells") or []))
    print((out / "matrix.md").read_text())
    return code


if __name__ == "__main__":
    sys.exit(main())
