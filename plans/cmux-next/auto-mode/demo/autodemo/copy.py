"""The copy: a chat's folder and the agent's session file as content-addressed blobs.

A manifest names every file by the sha256 of its bytes, so a second copy uploads only what
changed and an import downloads only what differs. The session file is cut at its last whole
line: the agent may be in the middle of writing one.
"""

import hashlib
import os
import re
import shutil
import socket
import subprocess
import time

SKIP_DIRS = {"node_modules", "target", ".venv", "venv", "__pycache__", ".next", "dist", "build"}
FILE_MAX = 64 * 1024 * 1024
TOTAL_MAX = 512 * 1024 * 1024


class TooLarge(Exception):
    pass


def slug(path):
    """The agent's folder name for a project path."""
    return re.sub(r"[^a-zA-Z0-9]", "-", os.path.realpath(path))


def config_dir():
    return (os.environ.get("AUTO_CLAUDE_CONFIG_DIR") or os.environ.get("CLAUDE_CONFIG_DIR")
            or os.path.join(os.path.expanduser("~"), ".claude"))


def session_path(cwd, sid):
    return os.path.join(config_dir(), "projects", slug(cwd), sid + ".jsonl")


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def _git_files(folder):
    """The folder's files as git sees them (tracked, and untracked but not ignored), or None."""
    if not os.path.isdir(os.path.join(folder, ".git")):
        return None
    try:
        out = subprocess.run(["git", "-C", folder, "ls-files", "-co", "--exclude-standard", "-z"],
                             capture_output=True, timeout=60)
    except (OSError, subprocess.SubprocessError):
        return None
    if out.returncode != 0:
        return None
    return [p for p in out.stdout.decode("utf-8", "surrogateescape").split("\0") if p]


def _walk(folder, sub=""):
    out = []
    for base, dirs, files in os.walk(os.path.join(folder, sub) if sub else folder):
        if not sub:
            dirs[:] = [d for d in dirs if d not in SKIP_DIRS and d != ".git"]
        for name in files:
            out.append(os.path.relpath(os.path.join(base, name), folder))
        for name in list(dirs):
            if os.path.islink(os.path.join(base, name)):
                out.append(os.path.relpath(os.path.join(base, name), folder))
    return out


def files_of(folder):
    """Every path the copy carries: the working files, and the repository itself."""
    paths = _git_files(folder)
    if paths is None:
        paths = _walk(folder)
    else:
        paths += _walk(folder, ".git")
    return sorted(set(p for p in paths if not p.endswith(".lock")))


class Copier:
    """Exports and imports one chat's folder. Remembers hashes by (mtime, size)."""

    def __init__(self, client, folder):
        self.client = client
        self.folder = folder
        self.cache = {}

    def _entry(self, rel):
        path = os.path.join(self.folder, rel)
        try:
            st = os.lstat(path)
        except OSError:
            return None
        if os.path.islink(path):
            data = os.readlink(path).encode()
            return [sha256(data), "l", len(data)], data
        if not os.path.isfile(path) or st.st_size > FILE_MAX:
            return None
        key = (st.st_mtime_ns, st.st_size)
        hit = self.cache.get(rel)
        if hit and hit[0] == key:
            return [hit[1], st.st_mode & 0o777, st.st_size], None
        try:
            with open(path, "rb") as f:
                data = f.read()
        except OSError:
            return None
        digest = sha256(data)
        self.cache[rel] = (key, digest)
        return [digest, st.st_mode & 0o777, len(data)], data

    def scan(self):
        """The folder as a files map {path: [sha, mode, size]}."""
        files, total = {}, 0
        for rel in files_of(self.folder):
            got = self._entry(rel)
            if got is None:
                continue
            files[rel] = got[0]
            total += got[0][2]
        if total > TOTAL_MAX:
            raise TooLarge("the folder is %d MB; the demo copies up to %d MB"
                           % (total >> 20, TOTAL_MAX >> 20))
        return files

    def _read(self, rel):
        path = os.path.join(self.folder, rel)
        if os.path.islink(path):
            return os.readlink(path).encode()
        with open(path, "rb") as f:
            return f.read()

    def export(self, sid, seq, extra=None):
        """Uploads what the store lacks and returns the manifest to post."""
        files = self.scan()
        session = None
        spath = session_path(self.folder, sid)
        if os.path.exists(spath):
            with open(spath, "rb") as f:
                data = f.read()
            data = data[: data.rfind(b"\n") + 1]
            session = {"id": sid, "sha": sha256(data), "bytes": len(data)}
            session_data = data
        by_sha = {}
        for rel, entry in files.items():
            by_sha.setdefault(entry[0], rel)
        shas = list(by_sha)
        if session:
            shas.append(session["sha"])
        uploaded = 0
        for sha in self.client.missing_blobs(shas):
            if session and sha == session["sha"]:
                data = session_data
            else:
                rel = by_sha[sha]
                try:
                    data = self._read(rel)
                except OSError:
                    data = None
                if data is None or sha256(data) != sha:
                    # It changed while we looked: this copy goes without it, the next has it.
                    self.cache.pop(rel, None)
                    for other in [p for p, e in files.items() if e[0] == sha]:
                        del files[other]
                    continue
            self.client.put_blob(sha, data)
            uploaded += len(data)
        manifest = {"v": 1, "at": int(time.time() * 1000), "seq": seq, "cwd": self.folder,
                    "host": socket.gethostname(), "files": files, "session": session}
        manifest.update(extra or {})
        return manifest, uploaded

    def bring(self, manifest, previous_files=None):
        """Makes the folder and the session file what the manifest says. Files this side had
        from the last copy and the manifest no longer names are removed."""
        os.makedirs(self.folder, exist_ok=True)
        files = manifest.get("files") or {}
        fetched = 0
        for rel, (sha, mode, _size) in files.items():
            path = os.path.join(self.folder, rel)
            have = self._entry(rel)
            if have is not None and have[0][0] == sha and have[0][1] == mode:
                continue
            data = self.client.blob(sha)
            fetched += len(data)
            os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
            if os.path.islink(path) or (os.path.exists(path) and mode == "l"):
                os.remove(path)
            if mode == "l":
                os.symlink(data.decode(), path)
                continue
            tmp = path + ".auto-tmp"
            with open(tmp, "wb") as f:
                f.write(data)
            os.chmod(tmp, mode)
            os.replace(tmp, path)
            self.cache.pop(rel, None)
        removed = 0
        for rel in (previous_files or {}):
            if rel not in files:
                try:
                    os.remove(os.path.join(self.folder, rel))
                    removed += 1
                except OSError:
                    pass
        session = manifest.get("session")
        if session:
            spath = session_path(self.folder, session["id"])
            os.makedirs(os.path.dirname(spath), exist_ok=True)
            data = self.client.blob(session["sha"])
            tmp = spath + ".auto-tmp"
            with open(tmp, "wb") as f:
                f.write(data)
            os.replace(tmp, spath)
        return fetched, removed

    def leftover(self, stored_files, dest):
        """What this folder has that the last stored copy does not: changed and new working
        files are copied to `dest`. Returns their paths."""
        kept = []
        try:
            now = self.scan()
        except TooLarge:
            return kept
        for rel, entry in now.items():
            if rel.startswith(".git/"):
                continue
            old = (stored_files or {}).get(rel)
            if old is None or old[0] != entry[0]:
                target = os.path.join(dest, rel)
                os.makedirs(os.path.dirname(target), exist_ok=True)
                try:
                    shutil.copy2(os.path.join(self.folder, rel), target, follow_symlinks=False)
                    kept.append(rel)
                except OSError:
                    pass
        return kept
