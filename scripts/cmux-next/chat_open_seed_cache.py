"""chat-open-bench.py's seed cache: the template chats a seeding daemon writes, kept on the worker.

A 10,000-turn chat takes the seeding daemon about 18 minutes to write (1,081.9 s on a Mac16,10),
and every arm of an A/B wrote the same one again. Each template is cached under a key that hashes
every input that shapes it: the template's own inputs (turns, subagents, bloat), the sources that
generate it (chat_open_agent.py, the fake agent it extends, idle_cost_load.py) and the acpmux store
and protocol sources that decide its on-disk shape. An arm's app build changes none of those, so the
arms of one A/B share the templates; a change to any of them is a new key.

Only the templates are cached. The bench still copies each one into a fresh store under fresh ids
for every open (copy_chat), so no open ever reads a chat an earlier open or run saw.

An entry is written to a temp folder and renamed into place, and read only when its manifest names
its key and every file's size and sha256 match. Entries unused for MAX_AGE_S are pruned, and past
MAX_ENTRIES or MAX_BYTES the least recently used go first. The cache deletes only folders under its
own root that it wrote: a key-named folder whose manifest names that key, or a stale .tmp- folder. A
cache folder that can't be read or written leaves the run uncached, never failed.
"""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import stat
import sys
import tempfile
import time

FORMAT = 1
MAX_AGE_S = 7 * 24 * 3600
MAX_ENTRIES = 16
MAX_BYTES = 16 << 30
TMP_PREFIX = ".tmp-"
TMP_STALE_S = 24 * 3600

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
ACPMUX = os.path.join(ROOT, "cmux-tui", "crates", "acpmux")


def default_root() -> str:
    """CMUX_BENCH_SEED_CACHE, else the fleet worker's step cache root (CMUX_CI_CACHE_DIR, set on
    every step and kept between steps, unlike a step's HOME), else the per-user cache folder."""
    if os.environ.get("CMUX_BENCH_SEED_CACHE"):
        return os.environ["CMUX_BENCH_SEED_CACHE"]
    if os.environ.get("CMUX_CI_CACHE_DIR"):
        return os.path.join(os.environ["CMUX_CI_CACHE_DIR"], "cmux-bench", "chat-open")
    library = os.path.expanduser("~/Library/Caches")
    base = library if sys.platform == "darwin" else os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache")
    return os.path.join(base, "cmux-bench", "chat-open")


def fake_agent_path() -> str:
    """The fake agent chat_open_agent.py loads, found the way it finds it."""
    path = os.environ.get("CHAT_OPEN_FAKE_AGENT") or os.path.join(ACPMUX, "tests", "fake_agent.py")
    return path if os.path.exists(path) else os.path.join(HERE, "fake_agent.py")


def source_files() -> list[str]:
    """The template generator's sources, then the acpmux store and protocol sources (the daemon's
    on-disk schema). Empty schema sources (a bench folder outside the repo) leave the caller to key
    on the acpmux binary instead."""
    files = [os.path.join(HERE, "chat_open_agent.py"), fake_agent_path(), os.path.join(HERE, "idle_cost_load.py"),
             os.path.join(HERE, "chat_open_seed_cache.py")]
    src = os.path.join(ACPMUX, "src")
    schema = [os.path.join(ACPMUX, "Cargo.toml"), os.path.join(src, "store.rs")]
    for folder in (os.path.join(src, "store"), os.path.join(src, "protocol")):
        for base, dirs, names in os.walk(folder):
            dirs.sort()
            schema += [os.path.join(base, n) for n in sorted(names) if n.endswith(".rs")]
    return files + [p for p in schema if os.path.isfile(p)]


def sha256_file(path: str) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def source_digest(acpmux_binary: str | None = None) -> str:
    """One hash of every source that shapes a template. With no acpmux store sources beside this
    script, the daemon binary stands in for its schema."""
    files = source_files()
    digest = hashlib.sha256(f"format {FORMAT}\n".encode())
    for path in files:
        if os.path.exists(path):
            digest.update(f"{os.path.relpath(path, ROOT)} {sha256_file(path)}\n".encode())
    if not any(p.endswith("store.rs") for p in files) and acpmux_binary:
        digest.update(f"acpmux {sha256_file(acpmux_binary)}\n".encode())
    return digest.hexdigest()


def entry_key(name: str, inputs: dict, digest: str) -> str:
    """The cache key of template entry `name` made from `inputs` by sources hashing to `digest`."""
    blob = json.dumps({"format": FORMAT, "name": name, "inputs": inputs, "sources": digest}, sort_keys=True)
    return f"{name}-{hashlib.sha256(blob.encode()).hexdigest()[:KEY_HEX]}"


KEY_HEX = 32


def is_key(name: str) -> bool:
    """A folder name entry_key makes: <template name>-<32 hex digits>."""
    stem, _, tail = name.rpartition("-")
    return bool(stem) and _safe_name(stem) and len(tail) == KEY_HEX and all(c in "0123456789abcdef" for c in tail)


def owned(root: str, name: str) -> bool:
    """True for an entry this cache wrote: a key-shaped folder whose manifest names that key."""
    if not is_key(name):
        return False
    try:
        with open(os.path.join(root, name, "manifest.json")) as handle:
            manifest = json.load(handle)
    except (OSError, ValueError):
        return False
    return isinstance(manifest, dict) and manifest.get("format") == FORMAT and manifest.get("key") == name


def _digest_ok(want) -> bool:
    """A manifest's file record: {"bytes": int, "sha256": 64 hex digits}."""
    return isinstance(want, dict) and type(want.get("bytes")) is int and isinstance(want.get("sha256"), str) \
        and len(want["sha256"]) == 64 and all(c in "0123456789abcdef" for c in want["sha256"])


def _safe_name(name: str) -> bool:
    return bool(name) and "/" not in name and name not in (".", "..") and not name.startswith(".")


def get(root: str, key: str) -> dict | None:
    """The templates (name -> icl.read_chat dict) cached under `key`, or None. An entry that fails
    its manifest check is removed, and the caller seeds it again."""
    folder = os.path.join(root, key)
    manifest_path = os.path.join(folder, "manifest.json")
    if not os.path.isfile(manifest_path):
        return None
    try:
        with open(manifest_path) as handle:
            manifest = json.load(handle)
        if not isinstance(manifest, dict) or manifest.get("format") != FORMAT or manifest.get("key") != key:
            raise ValueError("manifest names another key")
        if not isinstance(manifest.get("templates"), dict) or not manifest["templates"]:
            raise ValueError("manifest lists no templates")
        templates = {}
        for name, entry in manifest["templates"].items():
            if not _safe_name(name) or not isinstance(entry, dict) or not isinstance(entry.get("id"), str) \
                    or not entry["id"] or not _digest_ok(entry.get("meta")) or not isinstance(entry.get("events"), dict) \
                    or not entry["events"] or not all(_safe_name(e) and _digest_ok(w) for e, w in entry["events"].items()):
                raise ValueError(f"manifest entry {name!r} is malformed")
            base = os.path.join(folder, name)

            def read(rel, want):
                with open(os.path.join(base, rel), "rb") as handle:
                    data = handle.read()
                if len(data) != want["bytes"] or hashlib.sha256(data).hexdigest() != want["sha256"]:
                    raise ValueError(f"{name}/{rel} does not match its manifest")
                return data

            templates[name] = {"id": entry["id"], "meta": read("session.json", entry["meta"]),
                               "events": {e: read(os.path.join("events", e), want) for e, want in entry["events"].items()}}
    except (OSError, ValueError, KeyError, TypeError, AttributeError) as error:
        print(f"chat-open: seed cache {key}: dropped ({error})", file=sys.stderr)
        shutil.rmtree(folder, ignore_errors=True)
        return None
    try:
        os.utime(manifest_path)  # last used, for pruning
    except OSError:
        pass
    return templates


def put(root: str, key: str, inputs: dict, templates: dict, seed_s: float) -> bool:
    """Caches `templates` (name -> icl.read_chat dict) under `key`, atomically: written to a temp
    folder, then renamed. True when the entry is in place (this call's or a racing writer's)."""
    temp = None
    try:
        os.makedirs(root, exist_ok=True)
        temp = tempfile.mkdtemp(prefix=TMP_PREFIX, dir=root)
        manifest = {"format": FORMAT, "key": key, "inputs": inputs, "seed_s": round(seed_s, 1),
                    "created": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "templates": {}}
        for name, template in templates.items():
            if not _safe_name(name):
                raise ValueError(f"template name {name!r}")
            base = os.path.join(temp, name)
            os.makedirs(os.path.join(base, "events"))

            def write(rel, data):
                with open(os.path.join(base, rel), "wb") as handle:
                    handle.write(data)
                return {"bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}

            events = {}
            for event, data in template["events"].items():
                if not _safe_name(event):
                    raise ValueError(f"event file name {event!r}")
                events[event] = write(os.path.join("events", event), data)
            manifest["templates"][name] = {"id": template["id"], "meta": write("session.json", template["meta"]),
                                           "events": events}
        with open(os.path.join(temp, "manifest.json"), "w") as handle:
            json.dump(manifest, handle, indent=1)
        try:
            os.rename(temp, os.path.join(root, key))
        except OSError:
            if not os.path.isfile(os.path.join(root, key, "manifest.json")):
                raise
            shutil.rmtree(temp, ignore_errors=True)  # a racing writer put the same key first
        return True
    except (OSError, ValueError) as error:
        print(f"chat-open: seed cache {key}: not written ({error})", file=sys.stderr)
        if temp:
            shutil.rmtree(temp, ignore_errors=True)
        return False


def _size(folder: str) -> int:
    total = 0
    for base, _dirs, names in os.walk(folder):
        for name in names:
            try:
                total += os.lstat(os.path.join(base, name)).st_size
            except OSError:
                pass
    return total


def prune(root: str, now: float | None = None, max_age_s: float = MAX_AGE_S, max_entries: int = MAX_ENTRIES,
          max_bytes: int = MAX_BYTES, keep: tuple = ()) -> list[str]:
    """Removes entries unused for `max_age_s`, stale temp folders, then the least recently used
    past `max_entries` or `max_bytes` (never one named in `keep`). The removed names."""
    try:
        names = os.listdir(root)
    except OSError:
        return []
    now = time.time() if now is None else now
    removed, entries = [], []
    for name in names:
        path = os.path.join(root, name)
        try:
            info = os.lstat(path)
        except OSError:
            continue  # gone already (another run's prune) or unreadable
        if not stat.S_ISDIR(info.st_mode):
            continue
        if name.startswith(TMP_PREFIX):
            if now - info.st_mtime > TMP_STALE_S:
                shutil.rmtree(path, ignore_errors=True)
                removed.append(name)
            continue
        if not owned(root, name):
            continue  # not an entry this cache wrote
        try:
            used = os.lstat(os.path.join(path, "manifest.json")).st_mtime
        except OSError:
            continue
        if now - used > max_age_s and name not in keep:
            shutil.rmtree(path, ignore_errors=True)
            removed.append(name)
            continue
        entries.append((used, name, _size(path)))
    entries.sort(key=lambda e: (e[1] in keep, e[0]), reverse=True)  # this run's entries, then newest first
    total = 0
    for index, (_used, name, size) in enumerate(entries):
        total += size
        if name not in keep and (index >= max_entries or total > max_bytes):
            shutil.rmtree(os.path.join(root, name), ignore_errors=True)
            removed.append(name)
            total -= size
    return removed
