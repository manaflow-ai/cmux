#!/usr/bin/env python3
"""The upgrades suite: state roots written by the last cmux-tui tags, opened by head, and head's roots refused by the previous tag.

Spec: plans/cmux-next/chrome-parity/p15-oracle.md, section 3D (suite upgrades, golden) and task 208. Stdlib plus the
cmux Python SDK's wire layer (cmux-tui/bindings/python, `cmux._protocol`), Python 3.9+, safe under `python3 -I`.
`oracle.py gen --suite upgrades` runs `--out <corpus>/upgrades`.

The daemon stores are the ones a rollback checks (cmux-tui-core store_schemas.rs `STORES`: workspace_registry and
conversation_store). Each holds `meta.schema_version`; a build refuses a store newer than its own SCHEMA_VERSION, and
the app refuses a rollback (CmuxNextUpdater RollbackDecision) when the kept build cannot say what it reads
(`predatesRollback`: its `cmux __store-schemas` fails, so StoreSchemaProbe.readable is nil), when a stored schema is
newer than the kept build reads (`storeTooNew`) or when the kept build does not know a stored store
(`unknownStore`). That refusal is the store_schemas error.

Fixtures (`--write-roots`, Linux VM): each of the last 5 cmux-tui tags merged into HEAD is built with linux_run.sh
(`--profile dev`, no features: a tag has no oracle profile), runs `POPULATE` on a fresh hermetic root through the
SDK, stops (`session.shutdown`), starts again on its own root and reads its facet (`session.snapshot`: what it
persisted, read back by itself), and stops. The state directory is packed into
tests/oracle/fixtures/state-roots/<tag>.tar.gz (sorted members, zero times and owners) next to <tag>.json: the tag's
sha, its readable schemas from its source (`readable`, which names the store files), what its own `__store-schemas`
prints (`storeSchemas`, the rollback check's input; null when the probe fails, as for every tag from before #18103),
the stored schemas, every file's sha256 and the facet.

Corpus (`--out DIR`, from the fixtures and head's source):
- `<tag>-<store>` per (tag, store the tag wrote): head starts on the tag's root (restart step `open`) and reads the
  facet (`read`). Every value the tag read from its own root equals head's value at the same pointer (head may add
  fields, never drop or change one), and after head stops `__store-schemas --stored` reports the store at head's
  schema (head migrated it).
- `rollback-<tag>-<store>` per store head reads, for the newest tag (the previous release): head runs POPULATE (and
  the store's own steps), reads its facet, then the `open` restart starts the previous tag on that root. The root
  holds exactly the registry and the case's store (`rollback_root_stores`; the runner fails a root with any other),
  and the `expect` is RollbackDecision's verdict over that whole root against the tag's `storeSchemas`:
  `store_schemas.predates_rollback`, `store_schemas.store_too_new` and `store_schemas.unknown_store` are refusals,
  ok means the rollback may run. On a refusal the runner still starts the tag, as a person would with the old app:
  store_too_new must stop it before it is ready, and on every refusal every file of the root is byte-identical after
  it (sha256) and none is gone; on ok the tag's facet equals head's the same way as an upgrade.

The cases need two builds on one root, which no product driver runs (they require `state_root`, which no product of
oracle.py has); `--run` is their runner. Terminals are left out: a packed root holds no live terminal host, and host
adoption across builds is the terminal-host protocol's (docs/cloud-guest-upgrades.md).

Chrome reference (chromium/src):
- components/history/core/browser/history_backend_db_unittest.cc: CreateDBVersion(N) loads a database that version N
  wrote (components/test/data/history/history.N.sql) and the current build must open and migrate it; each migration
  test then checks the rows survive. Here the old database comes from the tag's own binary.
- sql/meta_table.h (GetCompatibleVersionNumber) and components/history/core/browser/history_database.cc
  (sql::INIT_TOO_NEW): an older Chrome refuses a database whose compatible version is newer than its own and leaves
  it as it is; the rollback cases hold the previous tag to the same.

Usage:
  gen_upgrades.py --tags [--count 5]                         the tags the fixtures come from, oldest first
  gen_upgrades.py --write-roots [--count 5] [--tag-binary TAG=BIN]... [--isolation netns|auto|none]
                                                             build each tag (unless given), write its root and
                                                             manifest, then the corpus
  gen_upgrades.py --out DIR [--check]                        write the corpus (or exit 1 when DIR differs)
  gen_upgrades.py --run --binary HEAD [--previous-binary BIN] [--corpus DIR] [--case GLOB]... [--report FILE]
                  [--isolation netns|auto|none] [--keep]     run the suite; exit 0 when every case passes
  gen_upgrades.py --selftest                                 offline tests
"""

from __future__ import annotations

import argparse
import copy
import fnmatch
import gzip
import hashlib
import io
import json
import os
import re
import selectors
import shutil
import signal
import sqlite3
import subprocess
import sys
import tarfile
import tempfile
import time
import unittest
from dataclasses import dataclass, field, replace
from pathlib import Path
from typing import Any, Callable, Dict, Iterable, List, Mapping, Optional, Sequence, Tuple

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
SDK = REPO / "cmux-tui" / "bindings" / "python"
for _path in (str(HERE), str(SDK)):
    if _path not in sys.path:
        sys.path.insert(0, _path)

import hermetic_env  # noqa: E402 - sibling: the only place a case environment is built
from case_values import MISSING, resolve_pointer  # noqa: E402 - sibling: one JSON pointer implementation
from cmux._protocol import ProtocolConnection  # noqa: E402
import mock_chief  # noqa: E402 - sibling: the mock agent of a `fixture.agent: mock` case
from cmux.errors import CmuxError  # noqa: E402
from cmux.transport import JsonLineConnection  # noqa: E402 - the SDK's v1 command line (conversation-create)

TASK = "p15-oracle-208"
SUITE = "upgrades"
DEFAULT_OUT = REPO / "tests" / "oracle" / "corpus" / SUITE
FIXTURES = REPO / "tests" / "oracle" / "fixtures" / "state-roots"
CASE_SCHEMA = REPO / "schemas" / "oracle" / "case-v1.schema.json"
SCHEMA_REF = "../../../../schemas/oracle/case-v1.schema.json"
LINUX_RUN = HERE / "linux_run.sh"
STATE_ROOT_SCHEMA = "cmux-oracle-state-root-v1"
REPORT_SCHEMA = "cmux-oracle-upgrades-run-v1"
TAG_PATTERN = "cmux-tui-v*"
TAG_RE = re.compile(r"^cmux-tui-v(\d+)\.(\d+)\.(\d+)$")
HEAD = "head"
DEFAULT_COUNT = 5
# A tag has no oracle profile; dev keeps debug assertions, like the oracle profile.
TAG_PROFILE = "dev"
SESSION = "oracle-upgrade"
MARKER_ENV = "CMUX_ORACLE_CASE"
SELECTORS = {"machine": "current", "session": "current"}
STATE_BASE = Path("/tmp/o")
CORE_SRC = "cmux-tui/crates/cmux-tui-core/src"
STORE_SCHEMAS_RS = f"{CORE_SRC}/store_schemas.rs"
CLI_SRC = "cmux-tui/crates/cmux-tui/src"
OPERATIONS_SPEC = "cmux-tui/spec/resource-operations-v2.json"
# The daemon's readiness pipe (b3ce5640d94, 2026-09-30); a build from before it is awaited by connecting.
READY_FD_FLAG = "--owner-ready-fd"
READY_S = 60.0
REQUEST_S = 10.0
STOP_S = 60.0
LOG_TAIL_BYTES = 2048
SQLITE_SIDECARS = ("", "-wal", "-shm", "-journal")
# The SQLite open a build refuses a newer store with, by store (workspace_registry.rs
# UnsupportedWorkspaceRegistrySchema, conversation_store.rs initialize).
REFUSAL_TEXT = {
    "workspace_registry": "unsupported workspace registry schema",
    "conversation_store": "unsupported conversation store schema",
}
PREDATES_ROLLBACK = "store_schemas.predates_rollback"
STORE_TOO_NEW = "store_schemas.store_too_new"
UNKNOWN_STORE = "store_schemas.unknown_store"
# The store every root holds: POPULATE writes the registry.
REGISTRY = "workspace_registry"
STORE_SCHEMAS_FLAG = "__store-schemas"
# What one daemon start changes in the facet of an unchanged root; nothing else is left out.
VOLATILE: Dict[str, str] = {
    "/cursor": "the generation is new at every daemon start, and the revision counts the shutdown that ended the writer",
    "/session/generation": "new at every daemon start",
    "/session/revision": "counts every mutation, the writer's own shutdown and the opener's start included",
    "/clients": "the reading process's own connections, not stored state",
}

STEP_REF = re.compile(r"^\$step:([a-z0-9][a-z0-9-]{0,63})#((?:/(?:[^~/]|~[01])*)*)$")
TARGET = {"machine": "current", "session": "current"}


def _call(step_id: str, method: str, params: Mapping[str, Any], *, target: Optional[Mapping[str, str]] = None,
          note: str) -> Dict[str, Any]:
    return {
        "id": step_id, "op": "resource.call", "target": {**TARGET, **(target or {})},
        "args": {"method": method, "params": dict(params), "idempotencyKey": f"upgrades.{step_id}"},
        "expect": {"outcome": "ok", "receipt": "mutation_result"}, "note": note,
    }


def _read(step_id: str, method: str, *, note: str) -> Dict[str, Any]:
    return {"id": step_id, "op": "resource.call", "readOnly": True, "target": dict(TARGET),
            "args": {"method": method, "params": {}}, "expect": {"outcome": "ok"}, "note": note}


ALPHA = "$step:create-alpha#/value/workspace_id"
GAMMA = "$step:create-gamma#/value/workspace_id"
# Registry content with no process behind it (an empty workspace has no terminal), so a packed root is complete.
POPULATE: Tuple[Dict[str, Any], ...] = (
    _call("create-alpha", "workspace.create", {"name": "alpha", "initial_content": "empty"},
          note="an empty workspace: no terminal host, so the packed root holds all of it"),
    _call("create-beta", "workspace.create", {"name": "béta ✓ ", "initial_content": "empty"},
          note="exact name bytes: non-ASCII and a trailing space"),
    _call("create-gamma", "workspace.create", {"name": "gamma", "initial_content": "empty"}, note="a third workspace"),
    _call("move-gamma", "workspace.move", {"index": 0}, target={"workspace": GAMMA}, note="the stored order"),
    _call("rename-alpha", "workspace.rename", {"name": "alpha renamed"}, target={"workspace": ALPHA},
          note="a renamed workspace"),
    _call("notify", "notification.create", {"title": "build done", "body": "all green"}, note="a stored notification"),
    _call("focus-alpha", "workspace.focus", {}, target={"workspace": ALPHA}, note="the stored focus"),
)
# Steps that write one store beyond the registry, run only where the build offers every method. A conversation
# exists only once an agent made one: such a store's case runs with the mock agent (STORE_AGENT).
STORE_STEPS: Dict[str, Tuple[Dict[str, Any], ...]] = {
    "conversation_store": (
        _read("conversations", "conversation.list", note="the session's conversations"),
        _call("send", "conversation.send", {"conversation": "$step:conversations#/0/id", "text": "oracle upgrade"},
              note="one message in the conversation store"),
    ),
}


STORE_AGENT = {"conversation_store": "mock"}


class UpgradeError(Exception):
    """A bad argument, a missing tool or an input that does not parse: exit 2."""


class CaseFailure(Exception):
    """Ends a case with `status` (Failure, Crash, Timeout) and its reason."""

    def __init__(self, status: str, message: str, step: Optional[str] = None):
        super().__init__(message)
        self.status = status
        self.message = message
        self.step = step


class NotReady(Exception):
    """The daemon exited before it was ready: its exit and log tail."""

    def __init__(self, exit_text: str, log: str):
        super().__init__(f"{exit_text}: {log}")
        self.exit_text = exit_text
        self.log = log


# ------------------------------------------------------------------------------------------------ sources


@dataclass(frozen=True)
class Store:
    name: str
    module: str
    file_const: str
    version_const: str

    @property
    def path(self) -> str:
        return f"{CORE_SRC}/{self.module}.rs"


STORE_DECL = re.compile(
    r'\(\s*"([a-z_]+)"\s*,\s*crate::([a-z_]+)::([A-Z_]+)\s*,\s*crate::([a-z_]+)::([A-Z_]+)\s*,?\s*\)')


def git(*args: str, check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(["git", "-C", str(REPO), *args], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          text=True, check=check, env=dict(os.environ, GIT_OPTIONAL_LOCKS="0"))


class Source:
    """Files of one build: head's working tree, or a tag through git."""

    def __init__(self, ref: Optional[str] = None, read: Optional[Callable[[str], Optional[str]]] = None):
        self.ref = ref
        self._read = read

    def read(self, path: str) -> Optional[str]:
        if self._read is not None:
            return self._read(path)
        if self.ref is None:
            file = REPO / path
            return file.read_text(encoding="utf-8") if file.is_file() else None
        shown = git("show", f"{self.ref}:{path}", check=False)
        return shown.stdout if shown.returncode == 0 else None

    def mentions(self, folder: str, needle: str) -> bool:
        if self._read is not None:
            return needle in (self._read(folder) or "")
        found = git("grep", "-q", "-F", "-e", needle, *([self.ref] if self.ref else []), "--", folder, check=False)
        return found.returncode == 0


def store_decls(source: Source) -> List[Store]:
    """The stores a rollback checks, from store_schemas.rs (head's list: a tag predates the file)."""
    text = source.read(STORE_SCHEMAS_RS)
    if text is None:
        raise UpgradeError(f"{STORE_SCHEMAS_RS} is missing: the store list comes from head's source")
    stores = []
    for name, file_mod, file_const, version_mod, version_const in STORE_DECL.findall(text):
        if file_mod != version_mod:
            raise UpgradeError(f"{STORE_SCHEMAS_RS}: store {name} names two modules ({file_mod}, {version_mod})")
        stores.append(Store(name, file_mod, file_const, version_const))
    if not stores:
        raise UpgradeError(f"{STORE_SCHEMAS_RS}: no STORES entries")
    return stores


def rust_const(text: str, name: str, kind: str) -> Optional[str]:
    pattern = r'"([^"]+)"' if kind == "&str" else r"(-?\d+)"
    found = re.search(rf"(?m)^\s*(?:pub(?:\([a-z]+\))?\s+)?const\s+{name}\s*:\s*{re.escape(kind)}\s*=\s*{pattern}\s*;",
                      text)
    return found.group(1) if found else None


def store_layout(source: Source, stores: Sequence[Store]) -> Tuple[Dict[str, int], Dict[str, str]]:
    """(readable schema, file name) of each store the build has; a store whose module it lacks is unknown to it."""
    readable: Dict[str, int] = {}
    files: Dict[str, str] = {}
    for store in stores:
        text = source.read(store.path)
        if text is None:
            continue
        version = rust_const(text, store.version_const, "i64")
        file = rust_const(text, store.file_const, "&str")
        if version is None or file is None:
            raise UpgradeError(f"{source.ref or HEAD}:{store.path} has the module but not {store.version_const} and "
                               f"{store.file_const}")
        readable[store.name] = int(version)
        files[store.name] = file
    return readable, files


def operations(source: Source) -> frozenset:
    text = source.read(OPERATIONS_SPEC)
    if text is None:
        raise UpgradeError(f"{source.ref or HEAD}: no {OPERATIONS_SPEC}")
    return frozenset(json.loads(text).get("operations", {}))


def tag_version(tag: str) -> Tuple[int, int, int]:
    found = TAG_RE.match(tag)
    if not found:
        raise UpgradeError(f"{tag} is not a cmux-tui release tag")
    return int(found.group(1)), int(found.group(2)), int(found.group(3))


def last_tags(count: int) -> List[str]:
    """The newest `count` cmux-tui release tags merged into HEAD, oldest first."""
    listed = git("tag", "--list", TAG_PATTERN, "--merged", "HEAD").stdout.split()
    tags = sorted((tag for tag in listed if TAG_RE.match(tag)), key=tag_version)
    if len(tags) < count:
        raise UpgradeError(f"only {len(tags)} cmux-tui tags are merged into HEAD; fetch the tags")
    return tags[-count:]


def slug(text: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")


def tag_slug(tag: str) -> str:
    return slug(tag[len("cmux-tui-"):])


# --------------------------------------------------------------------------------------- the store_schemas verdict


def rollback_verdict(stored: Mapping[str, int], readable: Optional[Mapping[str, int]],
                     kept: str) -> Optional[Dict[str, Any]]:
    """RollbackDecision.decide after its signature check (CmuxNextUpdater/RollbackDecision.swift), over every store
    the root holds: predates_rollback when the kept build cannot say what it reads (`readable` None: its
    `__store-schemas` failed), else the first store, in name order, the kept build does not know or holds newer than
    it reads; None when it reads every stored store."""
    if readable is None:
        return {"error": PREDATES_ROLLBACK, "errorDetails": {"kept": kept}}
    for store in sorted(stored):
        if store not in readable:
            return {"error": UNKNOWN_STORE, "errorDetails": {"store": store}}
        if stored[store] > readable[store]:
            return {"error": STORE_TOO_NEW,
                    "errorDetails": {"store": store, "stored": stored[store], "readable": readable[store]}}
    return None


def rollback_root_stores(store: str) -> List[str]:
    """The stores a rollback case's root holds: the registry POPULATE writes and the case's own store."""
    return sorted({REGISTRY, store})


def root_verdict(stored: Mapping[str, int], store: str, readable: Optional[Mapping[str, int]],
                 kept: str) -> Optional[Dict[str, Any]]:
    """The verdict over a rollback case's whole root. A root that holds other stores than the case's fails the
    case: its expectation was made for `rollback_root_stores(store)`."""
    if sorted(stored) != rollback_root_stores(store):
        raise CaseFailure("Failure", f"the root holds {', '.join(sorted(stored)) or 'no store'}; the case is made for "
                                     f"{', '.join(rollback_root_stores(store))}", "written")
    return rollback_verdict(stored, readable, kept)


def parse_store_schemas(text: str) -> Optional[Dict[str, int]]:
    """StoreSchemaProbe.parse: one JSON object of store name to integer schema, else None."""
    try:
        value = json.loads(text)
    except ValueError:
        return None
    if not isinstance(value, dict) or not all(type(item) is int for item in value.values()):
        return None
    return dict(value)


def probe_readable(binary: str, env: "hermetic_env.CaseEnv") -> Optional[Dict[str, int]]:
    """StoreSchemaProbe.readable: what `binary __store-schemas` prints, run in the case environment; None when it
    cannot start, exits non-zero, times out or prints anything but the object (a build from before the probe)."""
    try:
        done = env.run([binary, STORE_SCHEMAS_FLAG], timeout=REQUEST_S, stdin=subprocess.DEVNULL)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return parse_store_schemas(done.stdout) if done.returncode == 0 else None


def refusal_changes(before: Mapping[str, str], after: Mapping[str, str]) -> List[str]:
    """Every file of the root (path to sha256) that the refused build changed or removed. There is no exception:
    the lock files are empty and taken with flock, so they keep their bytes too. A file the build added is not a
    change to head's data and is reported apart."""
    return sorted(path for path, digest in before.items() if after.get(path) != digest)


# ------------------------------------------------------------------------------------------------- facets


def project(facet: Any) -> Any:
    """The facet without what one daemon start changes (VOLATILE)."""
    out = copy.deepcopy(facet)
    for pointer in VOLATILE:
        parts = pointer[1:].split("/")
        node = out
        for part in parts[:-1]:
            node = node.get(part) if isinstance(node, dict) else None
        if isinstance(node, dict):
            node.pop(parts[-1], None)
    return out


def subset_differences(old: Any, new: Any, pointer: str = "", limit: int = 20) -> List[Dict[str, Any]]:
    """Where `new` does not hold `old`: every member of an old object is in the new one with an equal value, arrays
    have the same length and items, scalars are equal with their JSON type. New members are allowed (a newer build
    reports more), a missing or changed one is a difference."""
    out: List[Dict[str, Any]] = []

    def walk(a: Any, b: Any, at: str) -> None:
        if len(out) >= limit:
            return
        if isinstance(a, dict):
            if not isinstance(b, dict):
                out.append({"pointer": at or "/", "old": a, "new": b})
                return
            for key in sorted(a):
                child = f"{at}/{key.replace('~', '~0').replace('/', '~1')}"
                if key not in b:
                    out.append({"pointer": child, "old": a[key], "new": None, "missing": True})
                else:
                    walk(a[key], b[key], child)
        elif isinstance(a, list):
            if not isinstance(b, list) or len(a) != len(b):
                out.append({"pointer": at or "/", "old": a, "new": b})
                return
            for index, (x, y) in enumerate(zip(a, b)):
                walk(x, y, f"{at}/{index}")
        elif type(a) is not type(b) or a != b:
            out.append({"pointer": at or "/", "old": a, "new": b})

    walk(old, new, pointer)
    return out


# ---------------------------------------------------------------------------------------------- state roots


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def file_hashes(folder: Path) -> Dict[str, str]:
    """sha256 of every regular file under `folder`, by path relative to it."""
    return {path.relative_to(folder).as_posix(): sha256_file(path)
            for path in sorted(folder.rglob("*")) if path.is_file() and not path.is_symlink()}


def pack(folder: Path, prefix: str) -> bytes:
    """`folder` as a gzip tar under `prefix`: sorted members, regular files and directories only, zero times,
    owners and names, so the bytes depend only on the content and the modes."""
    raw = io.BytesIO()
    with tarfile.open(fileobj=raw, mode="w", format=tarfile.PAX_FORMAT) as tar:
        for path in [folder, *sorted(folder.rglob("*"))]:
            if path.is_symlink() or not (path.is_dir() or path.is_file()):
                continue
            rel = path.relative_to(folder).as_posix()
            info = tarfile.TarInfo(prefix if rel == "." else f"{prefix}/{rel}")
            info.mode = path.stat().st_mode & 0o777
            info.mtime = 0
            info.uid = info.gid = 0
            info.uname = info.gname = ""
            if path.is_dir():
                info.type = tarfile.DIRTYPE
                tar.addfile(info)
            else:
                data = path.read_bytes()
                info.size = len(data)
                tar.addfile(info, io.BytesIO(data))
    out = io.BytesIO()
    with gzip.GzipFile(fileobj=out, mode="wb", mtime=0, filename="") as handle:
        handle.write(raw.getvalue())
    return out.getvalue()


def unpack(data: bytes, prefix: str, folder: Path) -> None:
    """The inverse of pack into `folder`; refuses any member outside `prefix`, a link or a special file."""
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as tar:
        for member in tar.getmembers():
            name = member.name
            parts = Path(name).parts
            if not parts or parts[0] != prefix or Path(name).is_absolute() or ".." in parts:
                raise UpgradeError(f"state root member {name!r} is outside {prefix}/")
            if not (member.isdir() or member.isfile()):
                raise UpgradeError(f"state root member {name!r} is not a file or directory")
            target = folder.joinpath(*parts[1:])
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
                os.chmod(target, member.mode & 0o777)
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            source = tar.extractfile(member)
            assert source is not None
            target.write_bytes(source.read())
            os.chmod(target, member.mode & 0o777)


def stored_schemas(state: Path, files: Mapping[str, str]) -> Dict[str, int]:
    """store_schemas::stored for a build without `__store-schemas`: the newest `meta.schema_version` of each store
    in any session directory, read from a copy so the root stays as the build left it."""
    found: Dict[str, int] = {}
    for session in sorted(p for p in state.iterdir() if p.is_dir()):
        for store, name in files.items():
            if not (session / name).is_file():
                continue
            with tempfile.TemporaryDirectory(prefix="upgrades-store-") as tmp:
                for suffix in SQLITE_SIDECARS:
                    if (session / f"{name}{suffix}").is_file():
                        shutil.copyfile(session / f"{name}{suffix}", Path(tmp) / f"{name}{suffix}")
                connection = sqlite3.connect(str(Path(tmp) / name))
                try:
                    has_meta = connection.execute(
                        "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'meta')").fetchone()[0]
                    row = connection.execute("SELECT value FROM meta WHERE key = 'schema_version'").fetchone() \
                        if has_meta else None
                finally:
                    connection.close()
            if row is not None:
                found[store] = max(found.get(store, int(row[0])), int(row[0]))
    return found


# ----------------------------------------------------------------------------------------------- the daemon


@dataclass
class Build:
    """One cmux-tui build: head or a tag, with what the runner needs to know about it. `readable` comes from the
    source and names the store files; `probed` is what the build's own `__store-schemas` prints (probe_readable),
    the input of the rollback check, None when the build cannot say."""

    name: str
    binary: str
    ready_fd: bool
    readable: Dict[str, int]
    files: Dict[str, str]
    operations: frozenset = field(default_factory=frozenset)
    probed: Optional[Dict[str, int]] = None


def short_token(text: str) -> str:
    """Six base-36 characters of sha256(text) (driver_daemon.py's state root tokens)."""
    value = int.from_bytes(hashlib.sha256(text.encode("utf-8")).digest()[:5], "big")
    digits = "0123456789abcdefghijklmnopqrstuvwxyz"
    out = ""
    for _ in range(6):
        value, rest = divmod(value, 36)
        out = digits[rest] + out
    return out


class CaseRoot:
    """A fresh hermetic state root `/tmp/o/<run6>/<case6>` and its environment; removed on exit unless kept."""

    def __init__(self, run_id: str, key: str, isolation: hermetic_env.Isolation, keep: bool = False,
                 agent: Optional[str] = None):
        self.root = STATE_BASE / short_token(run_id) / short_token(key)
        self.isolation = isolation
        self.keep = keep
        self.env: Optional[hermetic_env.CaseEnv] = None
        self.agent: Optional[mock_chief.MockAgent] = None
        if agent == "mock":
            self.agent = mock_chief.MockAgent(self.root / hermetic_env.RUN_DIR)

    def __enter__(self) -> "CaseRoot":
        if self.root.exists():
            shutil.rmtree(self.root)
        extra = {MARKER_ENV: str(self.root)}
        if self.agent is not None:
            extra.update(self.agent.brain.environment())
        self.env = hermetic_env.daemon_case(self.root, self.isolation, platform="linux", extra=extra).prepare()
        if self.agent is not None:
            self.agent.start()
        return self

    def __exit__(self, *_: object) -> None:
        if self.agent is not None:
            self.agent.close()
        left = self.processes()
        for pid in left:
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        if not self.keep:
            shutil.rmtree(self.root, ignore_errors=True)

    @property
    def case_env(self) -> hermetic_env.CaseEnv:
        assert self.env is not None
        return self.env

    @property
    def state(self) -> Path:
        return self.case_env.state_dir

    def processes(self) -> List[int]:
        """Processes that carry this root's marker (Linux /proc): a case process outlived its daemon (I6)."""
        needle = f"{MARKER_ENV}={self.root}\0".encode()
        found = []
        for entry in Path("/proc").iterdir() if Path("/proc").is_dir() else ():
            if not entry.name.isdigit() or int(entry.name) == os.getpid():
                continue
            try:
                if needle in (entry / "environ").read_bytes():
                    found.append(int(entry.name))
            except OSError:
                continue
        return found


class Daemon:
    """One build's `cmux-tui --headless` on a case root, spoken to only through the SDK's wire layer."""

    def __init__(self, build: Build, root: CaseRoot):
        self.build = build
        self.root = root
        self.proc: Optional[subprocess.Popen] = None
        self.conn: Optional[ProtocolConnection] = None
        self.stops = 0

    @property
    def log(self) -> Path:
        return self.root.root / f"daemon-{slug(self.build.name)}.log"

    def log_tail(self) -> str:
        try:
            return self.log.read_bytes()[-LOG_TAIL_BYTES:].decode("utf-8", "replace")
        except OSError:
            return ""

    def exit_text(self) -> str:
        code = self.proc.returncode if self.proc is not None else None
        if code is None:
            return "running"
        return f"signal {signal.Signals(-code).name}" if code < 0 else f"exit {code}"

    def start(self) -> None:
        env = self.root.case_env
        argv = [self.build.binary, "--headless", "--session", SESSION, "--socket", str(env.socket),
                "--state", str(env.state_dir)]
        read_fd = write_fd = -1
        if self.build.ready_fd:
            read_fd, write_fd = os.pipe()
            argv += [READY_FD_FLAG, str(write_fd)]
        try:
            with open(self.log, "ab") as log:
                self.proc = subprocess.Popen(env.command(argv), env=dict(env.env), cwd=str(env.cwd),
                                             pass_fds=(write_fd,) if write_fd >= 0 else (),
                                             stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=log,
                                             start_new_session=True)
        except OSError as error:
            raise CaseFailure("Crash", f"cannot start {self.build.name}: {error}") from None
        finally:
            if write_fd >= 0:
                os.close(write_fd)
        if self.build.ready_fd:
            self._await_pipe(read_fd)
        else:
            self._await_listener()

    def _await_pipe(self, read_fd: int) -> None:
        """The daemon's own startup protocol: one byte when it serves, EOF when it exits first."""
        try:
            with selectors.DefaultSelector() as selector:
                selector.register(read_fd, selectors.EVENT_READ)
                byte = os.read(read_fd, 1) if selector.select(READY_S) else None
        finally:
            os.close(read_fd)
        if byte is None:
            raise CaseFailure("Timeout", f"{self.build.name} did not report ready in {READY_S:.0f} s")
        if not byte:
            assert self.proc is not None
            self.proc.wait()
            raise NotReady(self.exit_text(), self.log_tail())
        try:
            self.conn = self._connect()
        except CmuxError as error:
            raise CaseFailure("Crash", f"{self.build.name} reported ready but does not answer a ping: {error}: "
                                       f"{self.log_tail()}") from None

    def _await_listener(self) -> None:
        """A build from before the readiness pipe: its socket answers a ping once it serves, or it exits first."""
        assert self.proc is not None
        deadline = time.monotonic() + READY_S
        delay = 0.01
        while True:
            if self.proc.poll() is not None:
                raise NotReady(self.exit_text(), self.log_tail())
            try:
                self.conn = self._connect()
                return
            except (CmuxError, OSError):
                if time.monotonic() > deadline:
                    raise CaseFailure("Timeout", f"{self.build.name} did not serve in {READY_S:.0f} s") from None
                time.sleep(delay)
                delay = min(delay * 2, 0.2)

    def _connect(self) -> ProtocolConnection:
        conn = ProtocolConnection(str(self.root.case_env.socket), REQUEST_S)
        try:
            conn.request("session.ping", SELECTORS, timeout=REQUEST_S)
        except CmuxError:
            conn.close()
            raise
        return conn

    def command(self, cmd: str, params: Mapping[str, Any]) -> Any:
        """A v1 daemon command (the mock agent's conversation-create); a refusal fails the case."""
        with JsonLineConnection(str(self.root.case_env.socket), REQUEST_S) as line:
            line.send({"id": 1, "cmd": cmd, **params})
            reply = line.recv()
        if reply.get("ok") is not True:
            raise CaseFailure("Failure", f"{cmd} on {self.build.name}: {str(reply.get('error'))[:300]}")
        return reply.get("data")

    def request(self, method: str, params: Mapping[str, Any], key: Optional[str] = None) -> Any:
        if self.conn is None:
            raise CaseFailure("Crash", f"{self.build.name} is not running")
        return self.conn.request(method, {**SELECTORS, **params}, idempotency_key=key, timeout=REQUEST_S)

    def facet(self) -> Any:
        try:
            return self.request("session.snapshot", {})
        except CmuxError as error:
            raise CaseFailure("Failure", f"session.snapshot on {self.build.name}: {error}") from None

    def stop(self) -> None:
        """`session.shutdown` (force: no other owner may hold it open), then the exit."""
        assert self.proc is not None
        self.stops += 1
        try:
            self.request("session.shutdown", {"force": True}, key=f"upgrades.stop-{self.stops}")
        except CmuxError as error:
            self.kill()
            raise CaseFailure("Crash", f"session.shutdown on {self.build.name}: {error}: {self.log_tail()}") from None
        finally:
            self.close()
        try:
            code = self.proc.wait(STOP_S)
        except subprocess.TimeoutExpired:
            self.kill()
            raise CaseFailure("Timeout", f"{self.build.name} did not exit {STOP_S:.0f} s after session.shutdown") \
                from None
        if code != 0:
            raise CaseFailure("Crash", f"{self.build.name} ended with {self.exit_text()}: {self.log_tail()}")

    def close(self) -> None:
        if self.conn is not None:
            try:
                self.conn.close()
            except CmuxError:
                pass
            self.conn = None

    def kill(self) -> None:
        self.close()
        if self.proc is not None and self.proc.poll() is None:
            self.proc.kill()
            self.proc.wait()


def resolve_refs(value: Any, replies: Mapping[str, Any]) -> Any:
    if isinstance(value, str):
        found = STEP_REF.match(value)
        if not found:
            return value
        if found.group(1) not in replies:
            raise CaseFailure("Crash", f"{value} names a step that has not run")
        resolved = resolve_pointer(replies[found.group(1)], found.group(2))
        if resolved is MISSING:
            raise CaseFailure("Failure", f"{value} names nothing in the step's reply")
        return resolved
    if isinstance(value, list):
        return [resolve_refs(item, replies) for item in value]
    if isinstance(value, dict):
        return {key: resolve_refs(item, replies) for key, item in value.items()}
    return value


def run_resource_steps(daemon: Daemon, steps: Sequence[Mapping[str, Any]]) -> Dict[str, Any]:
    """Each resource.call step: selectors from its target, its params and key; an error reply fails the case."""
    replies: Dict[str, Any] = {}
    for step in steps:
        target = {key: value for key, value in resolve_refs(step.get("target", {}), replies).items()
                  if key not in SELECTORS}
        params = resolve_refs(step["args"].get("params", {}), replies)
        try:
            replies[step["id"]] = daemon.request(step["args"]["method"], {**target, **params},
                                                 key=step["args"].get("idempotencyKey"))
        except CmuxError as error:
            raise CaseFailure("Failure", f"{step['args']['method']} on {daemon.build.name}: {error}",
                              step["id"]) from None
    return replies


def populate_steps(build_operations: frozenset, stores: Iterable[str]) -> List[Dict[str, Any]]:
    """POPULATE plus each named store's own steps, all of whose methods the build offers."""
    steps = [copy.deepcopy(step) for step in POPULATE]
    for store in stores:
        extra = STORE_STEPS.get(store, ())
        if extra and all(step["args"]["method"] in build_operations for step in extra):
            steps.extend(copy.deepcopy(step) for step in extra)
    missing = sorted({step["args"]["method"] for step in steps} - set(build_operations))
    if missing:
        raise UpgradeError(f"the build offers no {', '.join(missing)}")
    return steps


# ------------------------------------------------------------------------------------------------ fixtures


def build_tag(tag: str) -> str:
    """linux_run.sh build of the tag (the runnerd queue; a finished build is reused); the binary's path."""
    if not sys.platform.startswith("linux"):
        raise UpgradeError("tags are built on the Linux VM (linux_run.sh); pass --binary TAG=PATH elsewhere")
    result = subprocess.run(["bash", str(LINUX_RUN), "build", tag, "--profile", TAG_PROFILE, "--features", ""],
                            stdout=subprocess.PIPE, text=True, check=False, env=dict(os.environ))
    lines = result.stdout.strip().splitlines()
    if result.returncode != 0 or not lines or not Path(lines[-1]).is_file():
        raise UpgradeError(f"linux_run.sh build {tag} failed (exit {result.returncode})")
    return lines[-1]


def tag_build(tag: str, binary: str, stores: Sequence[Store]) -> Build:
    source = Source(tag)
    readable, files = store_layout(source, stores)
    return Build(tag, binary, source.mentions(CLI_SRC, READY_FD_FLAG), readable, files, operations(source))


def head_build(binary: str, stores: Sequence[Store]) -> Build:
    source = Source()
    readable, files = store_layout(source, stores)
    return Build(HEAD, binary, source.mentions(CLI_SRC, READY_FD_FLAG), readable, files, operations(source))


def probed_build(build: Build, isolation: hermetic_env.Isolation, run_id: str) -> Build:
    """`build` with `probed`: its `__store-schemas`, run on a fresh case root of its own, as the app's
    StoreSchemaProbe runs the kept bundle's CLI."""
    with CaseRoot(run_id, f"probe-{build.name}", isolation) as root:
        return replace(build, probed=probe_readable(build.binary, root.case_env))


def write_root(build: Build, isolation: hermetic_env.Isolation, run_id: str) -> Tuple[Dict[str, Any], bytes]:
    """The tag writes POPULATE on a fresh root, reads it back after its own restart, and stops: (manifest, tarball)."""
    with CaseRoot(run_id, build.name, isolation) as root:
        daemon = Daemon(build, root)
        try:
            daemon.start()
            steps = populate_steps(build.operations, build.readable)
            run_resource_steps(daemon, steps)
            daemon.stop()
            daemon.start()
            facet = daemon.facet()
            daemon.stop()
        except NotReady as error:
            raise UpgradeError(f"{build.name} did not start: {error}") from None
        except CaseFailure as error:
            raise UpgradeError(f"{build.name}: {error.message}") from None
        finally:
            daemon.kill()
        left = root.processes()
        if left:
            raise UpgradeError(f"{build.name} left processes {left} after its shutdown")
        stored = stored_schemas(root.state, build.files)
        tarball = pack(root.state, "state")
        files = {f"state/{path}": digest for path, digest in file_hashes(root.state).items()}
    sha = git("rev-parse", f"{build.name}^{{commit}}").stdout.strip()
    manifest = {
        "schema": STATE_ROOT_SCHEMA,
        "task": TASK,
        "tag": build.name,
        "sha": sha,
        "generatedBy": "scripts/cmux-next/oracle/gen_upgrades.py --write-roots",
        "build": {"profile": TAG_PROFILE, "features": [], "binarySha256": sha256_file(Path(build.binary)),
                  "readyFd": build.ready_fd},
        "session": SESSION,
        "readable": build.readable,
        "storeSchemas": build.probed,
        "storeFiles": build.files,
        "stored": stored,
        "steps": [step["id"] for step in steps],
        "tarball": f"{build.name}.tar.gz",
        "tarballSha256": sha256_bytes(tarball),
        "files": files,
        "facet": facet,
    }
    return manifest, tarball


def load_manifests(folder: Path = FIXTURES) -> List[Dict[str, Any]]:
    manifests = []
    for path in sorted(folder.glob("cmux-tui-v*.json")):
        manifest = json.loads(path.read_text(encoding="utf-8"))
        if manifest.get("schema") != STATE_ROOT_SCHEMA or manifest.get("tag") != path.stem:
            raise UpgradeError(f"{path}: not a {STATE_ROOT_SCHEMA} manifest of {path.stem}")
        if "storeSchemas" not in manifest:
            raise UpgradeError(f"{path}: no storeSchemas (the tag's own __store-schemas): gen_upgrades.py "
                               "--write-roots")
        manifests.append(manifest)
    return sorted(manifests, key=lambda m: tag_version(m["tag"]))


def check_fixture(manifest: Mapping[str, Any], folder: Path = FIXTURES) -> bytes:
    """The tarball's bytes after checking them, and every packed file, against the manifest."""
    data = (folder / manifest["tarball"]).read_bytes()
    if sha256_bytes(data) != manifest["tarballSha256"]:
        raise UpgradeError(f"{manifest['tarball']}: sha256 differs from its manifest")
    with tempfile.TemporaryDirectory(prefix="upgrades-fixture-") as tmp:
        unpack(data, "state", Path(tmp))
        found = {f"state/{path}": digest for path, digest in file_hashes(Path(tmp)).items()}
    if found != manifest["files"]:
        raise UpgradeError(f"{manifest['tarball']}: its files differ from the manifest's")
    return data


# --------------------------------------------------------------------------------------------------- corpus


def base_case(case_id: str, title: str, state_root: Mapping[str, str], steps: List[Dict[str, Any]],
              preconditions: List[str], invariants: List[str]) -> Dict[str, Any]:
    return {
        "$schema": SCHEMA_REF,
        "corpusVersion": 1,
        "id": case_id,
        "suite": SUITE,
        "title": title,
        "surface": "cmux-next-daemon",
        "source": {"repo": "manaflow-ai/cmux", "ref": "$RUN", "artifact": "$RUN"},
        "environment": {},
        "fixture": {"seed": f"{SUITE}.{case_id}", "network": "offline", "clock": "fixed",
                    "stateRoot": dict(state_root)},
        "preconditions": preconditions,
        "requires": ["resource_api", "restart", "state_root"],
        "platforms": ["linux"],
        "steps": steps,
        "invariants": invariants,
        "teardown": ["stop the case daemon", "verify no case process is left", "remove the state root"],
        "untested": [
            "terminals: a packed root holds no live terminal host; host adoption across builds belongs to the "
            "terminal-host protocol (docs/cloud-guest-upgrades.md)",
        ],
    }


def open_step(expect: Mapping[str, Any], note: str) -> Dict[str, Any]:
    return {"id": "open", "op": "restart", "target": {"process": "daemon"}, "expect": dict(expect),
            "checkpoint": ["settled"], "note": note}


def read_step(note: str) -> Dict[str, Any]:
    return {"id": "read", "op": "snapshot", "args": {"facets": ["daemon"]}, "checkpoint": ["settled"], "note": note}


START_REASON = "a daemon start answers no request, so it has no receipt; it is ready or it exits"


def upgrade_case(manifest: Mapping[str, Any], store: str, head_readable: Mapping[str, int]) -> Dict[str, Any]:
    tag = manifest["tag"]
    stored = manifest["stored"][store]
    return base_case(
        f"{tag_slug(tag)}-{slug(store)}",
        f"head opens the {store} (schema {stored}) that {tag} wrote",
        {"writtenBy": tag, "openedBy": HEAD},
        [
            open_step({"outcome": "ok", "noReceiptReason": START_REASON},
                      f"head starts on the root {tag} wrote (tests/oracle/fixtures/state-roots/{tag}.tar.gz)"),
            read_step(f"head's facet; every value {tag} read back from its own root is here unchanged"),
        ],
        [f"state root unpacked from tests/oracle/fixtures/state-roots/{tag}.tar.gz, every file at its manifest's "
         "sha256", "no daemon before the first step"],
        [f"read: every value of the facet {tag} read from its root (the manifest's facet, without "
         f"{', '.join(sorted(VOLATILE))}) is at the same pointer in head's, equal; head may add members",
         f"after head stops, its __store-schemas --stored reports {store} at {head_readable.get(store, '?')}, the "
         "schema head reads: head migrated the store and kept it"],
    )


def rollback_case(previous: Mapping[str, Any], store: str, head_readable: Mapping[str, int]) -> Dict[str, Any]:
    tag = previous["tag"]
    kept_reads = previous["storeSchemas"]
    root_stores = rollback_root_stores(store)
    stored = {name: head_readable[name] for name in root_stores}
    verdict = rollback_verdict(stored, kept_reads, tag)
    steps = populate_steps(frozenset(step["args"]["method"] for step in (*POPULATE, *STORE_STEPS.get(store, ()))),
                           [store])
    steps.append(read_step("head's facet of the root it wrote, before the rollback"))
    steps[-1]["id"] = "written"
    reads = "nothing: its __store-schemas fails" if kept_reads is None else json.dumps(kept_reads, sort_keys=True)
    invariants = [f"head's __store-schemas --stored over the root is {json.dumps(stored, sort_keys=True)}: the case's "
                  "store and the registry, no other",
                  f"the store_schemas verdict of the whole root against what {tag} reads ({reads}), as "
                  "RollbackDecision.decide gives it"]
    allow: List[Dict[str, Any]] = []
    if verdict is None:
        steps.append(open_step({"outcome": "ok", "noReceiptReason": START_REASON},
                               f"the rollback may run: {tag} starts on head's root"))
        steps.append(read_step(f"{tag}'s facet of head's root"))
        invariants.append(f"read: every value {tag} reads is in head's written facet at the same pointer, equal")
        title = f"{tag} opens the {store} head wrote (the rollback may run)"
    else:
        steps.append(open_step({"outcome": "error", **verdict},
                               f"the rollback is refused; {tag} is then started anyway, as the old app would be"))
        if verdict["error"] == STORE_TOO_NEW:
            allow.append({"kind": "daemon", "steps": ["open"],
                          "reason": f"{tag} refuses the newer {verdict['errorDetails']['store']} and exits before "
                                    "it is ready"})
            invariants.append(f"{tag} exits before it is ready, its log naming the "
                              f"{verdict['errorDetails']['store']} schema")
        else:
            allow.append({"kind": "daemon", "steps": ["open"],
                          "reason": f"a refused rollback: {tag} may exit before it is ready on head's root"})
        invariants.append(f"every file of the root (each store's database and SQLite sidecars, the locks, machine-id "
                          f"and the pepper) is byte-identical (sha256) after {tag} ran, and none is gone")
        title = f"{tag} refuses head's root with the {store} ({verdict['error']})"
    case = base_case(f"rollback-{tag_slug(tag)}-{slug(store)}", title, {"writtenBy": HEAD, "openedBy": tag}, steps,
                     ["a fresh state root", "head's daemon runs the steps before the first restart"], invariants)
    if store in STORE_AGENT:
        case["fixture"]["agent"] = STORE_AGENT[store]
        case["preconditions"].append("the mock agent (mock_chief.py MockAgent) made its Chief conversation, the "
                                     "only one conversation.list gives")
    if allow:
        case["allow_crashes"] = allow
    return case


def corpus(manifests: Sequence[Mapping[str, Any]], head_readable: Mapping[str, int]) -> Dict[str, Dict[str, Any]]:
    """Every case of the suite by file name: one per (tag, store the tag wrote) and one per store head reads
    against the newest tag."""
    cases: Dict[str, Dict[str, Any]] = {}
    for manifest in manifests:
        for store in sorted(manifest["stored"]):
            case = upgrade_case(manifest, store, head_readable)
            cases[f"{case['id']}.json"] = case
    if manifests:
        for store in sorted(head_readable):
            case = rollback_case(manifests[-1], store, head_readable)
            cases[f"{case['id']}.json"] = case
    return cases


def render(case: Mapping[str, Any]) -> str:
    return json.dumps(case, indent=2, ensure_ascii=False) + "\n"


def write_corpus(out: Path, check: bool) -> int:
    head_readable, _ = store_layout(Source(), store_decls(Source()))
    cases = corpus(load_manifests(), head_readable)
    existing = {path.name: path.read_text(encoding="utf-8") for path in out.glob("*.json")} if out.is_dir() else {}
    wanted = {name: render(case) for name, case in cases.items()}
    if check:
        stale = sorted(set(existing) ^ set(wanted) | {n for n in wanted if existing.get(n) not in (None, wanted[n])})
        for name in stale:
            print(f"gen_upgrades: {out / name} differs from a fresh generation", file=sys.stderr)
        return 1 if stale else 0
    out.mkdir(parents=True, exist_ok=True)
    for name in set(existing) - set(wanted):
        (out / name).unlink()
    for name, text in wanted.items():
        (out / name).write_text(text, encoding="utf-8")
    print(f"gen_upgrades: {len(wanted)} cases in {out}")
    return 0


# ------------------------------------------------------------------------------------------------- the runner


@dataclass
class Runner:
    head: Build
    previous: Optional[Build]
    isolation: hermetic_env.Isolation
    run_id: str
    keep: bool = False

    def run_case(self, case: Mapping[str, Any]) -> Dict[str, Any]:
        result: Dict[str, Any] = {"case": f"{SUITE}/{case['id']}", "result": "Pass", "checks": []}
        try:
            with CaseRoot(self.run_id, case["id"], self.isolation, self.keep, case["fixture"].get("agent")) as root:
                try:
                    if case["fixture"]["stateRoot"]["writtenBy"] == HEAD:
                        self.rollback(case, root, result)
                    else:
                        self.upgrade(case, root, result)
                finally:
                    left = root.processes()
                if left:
                    raise CaseFailure("Failure", f"processes {left} outlived the case's daemons (I6)")
        except CaseFailure as error:
            result.update(result=error.status, message=error.message)
            if error.step:
                result["step"] = error.step
        except NotReady as error:
            result.update(result="Crash", message=f"a daemon exited before it was ready: {error}")
        except CmuxError as error:
            result.update(result="Crash", message=f"the daemon connection failed: {error}")
        return result

    def store_of(self, case: Mapping[str, Any]) -> str:
        for store in sorted(self.head.readable, key=len, reverse=True):
            if case["id"].endswith(f"-{slug(store)}"):
                return store
        raise CaseFailure("Crash", f"{case['id']} names no store head reads")

    def head_stored(self, root: CaseRoot) -> Dict[str, int]:
        """head's own `__store-schemas --stored` over the case root (the probe the rollback check runs)."""
        done = root.case_env.run([self.head.binary, "__store-schemas", "--stored"], timeout=REQUEST_S * 3)
        if done.returncode != 0:
            raise CaseFailure("Failure", f"__store-schemas --stored exited {done.returncode}: {done.stderr[-500:]}")
        try:
            return {key: int(value) for key, value in json.loads(done.stdout).items()}
        except (ValueError, AttributeError):
            raise CaseFailure("Failure", f"__store-schemas --stored printed {done.stdout[:200]!r}") from None

    def upgrade(self, case: Mapping[str, Any], root: CaseRoot, result: Dict[str, Any]) -> None:
        tag = case["fixture"]["stateRoot"]["writtenBy"]
        store = self.store_of(case)
        manifests = {m["tag"]: m for m in load_manifests()}
        if tag not in manifests:
            raise CaseFailure("Crash", f"no fixture for {tag} in {FIXTURES}")
        manifest = manifests[tag]
        try:
            unpack(check_fixture(manifest), "state", root.state)
        except UpgradeError as error:
            raise CaseFailure("Crash", str(error)) from None
        result["checks"].append(f"unpacked {manifest['tarball']} ({len(manifest['files'])} files at their sha256)")
        daemon = Daemon(self.head, root)
        try:
            daemon.start()
            facet = daemon.facet()
            daemon.stop()
        finally:
            daemon.kill()
        differences = subset_differences(project(manifest["facet"]), project(facet))
        if differences:
            result["differences"] = differences
            raise CaseFailure("Failure", f"head's facet does not hold what {tag} read from its root at "
                                         f"{differences[0]['pointer']}", "read")
        result["checks"].append(f"head's facet holds every value {tag} read")
        stored = self.head_stored(root)
        if stored.get(store) != self.head.readable[store]:
            raise CaseFailure("Failure", f"after head ran, {store} is stored at {stored.get(store)}, not head's "
                                         f"{self.head.readable[store]}", "open")
        result["checks"].append(f"{store} stored at head's schema {stored[store]}")

    def rollback(self, case: Mapping[str, Any], root: CaseRoot, result: Dict[str, Any]) -> None:
        previous = self.previous
        opener = case["fixture"]["stateRoot"]["openedBy"]
        if previous is None or previous.name != opener:
            raise CaseFailure("Crash", f"the case opens with {opener}; pass its binary as --previous-binary")
        store = self.store_of(case)
        steps = case["steps"]
        index = next(i for i, step in enumerate(steps) if step["op"] == "restart")
        writes = [step for step in steps[:index] if step["op"] == "resource.call"]
        head = Daemon(self.head, root)
        try:
            head.start()
            if root.agent is not None:
                root.agent.ready(head.command)
            run_resource_steps(head, writes)
            written = head.facet()
            head.stop()
        finally:
            head.kill()
        stored = self.head_stored(root)
        result["stored"] = stored
        result["keptReads"] = previous.probed
        if stored.get(store) != self.head.readable[store]:
            raise CaseFailure("Failure", f"head stored {store} at {stored.get(store)}, not at its readable "
                                         f"{self.head.readable[store]}", "written")
        verdict = root_verdict(stored, store, previous.probed, previous.name)
        expect = steps[index]["expect"]
        expected = None if expect["outcome"] == "ok" else {"error": expect["error"],
                                                           "errorDetails": expect.get("errorDetails", {})}
        if verdict != expected:
            raise CaseFailure("Failure", f"the store_schemas verdict is {verdict}, the case expects {expected}; "
                                         "regenerate the corpus (gen_upgrades.py --out)", "open")
        result["checks"].append(f"store_schemas verdict over {', '.join(sorted(stored))}: "
                                f"{verdict['error'] if verdict else 'ok'}")
        before = file_hashes(root.state)
        old = Daemon(previous, root)
        facet = None
        try:
            try:
                old.start()
            except NotReady as error:
                if verdict is None:
                    raise CaseFailure("Failure", f"the store_schemas verdict lets the rollback run, but "
                                                 f"{previous.name} exited before it was ready: {error}", "open") \
                        from None
                too_new = verdict["errorDetails"]["store"] if verdict["error"] == STORE_TOO_NEW else None
                if too_new is None:
                    # A refused rollback: the old build may run or stop, as long as it leaves the root alone.
                    result["checks"].append(f"{previous.name} exited before it was ready ({error.exit_text}): "
                                            f"{error.log.strip()[-200:]}")
                elif REFUSAL_TEXT[too_new] not in error.log:
                    raise CaseFailure("Failure", f"{previous.name} exited ({error.exit_text}) without naming the "
                                                 f"{too_new} schema: {error.log[-300:]}", "open") from None
                else:
                    result["checks"].append(f"{previous.name} refused to start: {REFUSAL_TEXT[too_new]}")
            else:
                if verdict is not None and verdict["error"] == STORE_TOO_NEW:
                    raise CaseFailure("Failure", f"{previous.name} served a {verdict['errorDetails']['store']} "
                                                 "newer than it reads", "open")
                facet = old.facet()
                old.stop()
        finally:
            old.kill()
        if verdict is None:
            differences = subset_differences(project(facet), project(written))
            if differences:
                result["differences"] = differences
                raise CaseFailure("Failure", f"{previous.name}'s facet differs from head's at "
                                             f"{differences[0]['pointer']}", "read")
            result["checks"].append(f"{previous.name}'s facet holds only head's values")
            return
        after = file_hashes(root.state)
        added = sorted(set(after) - set(before))
        if added:
            result["added"] = added
        changed = refusal_changes(before, after)
        if changed:
            result["changed"] = changed
            raise CaseFailure("Failure", f"{previous.name} changed or removed {', '.join(changed)}", "open")
        result["checks"].append(f"all {len(before)} files of the root unchanged by sha256"
                                + (f" ({len(added)} added)" if added else ""))


def select(cases: Mapping[str, Mapping[str, Any]], globs: Sequence[str]) -> List[Mapping[str, Any]]:
    return [case for name, case in sorted(cases.items())
            if not globs or any(fnmatch.fnmatchcase(case["id"], pattern) for pattern in globs)]


def run_suite(args: argparse.Namespace) -> int:
    if not sys.platform.startswith("linux"):
        raise UpgradeError("--run runs on the Linux VM")
    stores = store_decls(Source())
    head = head_build(args.binary, stores)
    probe = subprocess.run([args.binary, "__store-schemas"], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           text=True, check=False, env={"PATH": hermetic_env.TOOL_PATH})
    if probe.returncode != 0 or json.loads(probe.stdout or "null") != head.readable:
        raise UpgradeError(f"{args.binary} reads {probe.stdout.strip() or probe.stderr.strip()}, the source "
                           f"{json.dumps(head.readable, sort_keys=True)}: build this checkout")
    cases = {path.name: json.loads(path.read_text(encoding="utf-8")) for path in sorted(args.corpus.glob("*.json"))}
    chosen = select(cases, args.case)
    openers = {case["fixture"]["stateRoot"]["openedBy"] for case in chosen} - {HEAD}
    previous = None
    if len(openers) > 1:
        raise UpgradeError(f"cases open with several tags: {sorted(openers)}")
    isolation = hermetic_env.isolation_for(args.isolation, "linux")
    run_id = f"upgrades-{os.getpid()}-{time.time_ns()}"
    if openers:
        tag = openers.pop()
        previous = probed_build(tag_build(tag, args.previous_binary or build_tag(tag), stores), isolation, run_id)
        recorded = {m["tag"]: m for m in load_manifests()}.get(tag, {}).get("storeSchemas", MISSING)
        if recorded != previous.probed:
            raise UpgradeError(f"{tag}'s __store-schemas gives {json.dumps(previous.probed)}, its manifest "
                               f"{json.dumps(None if recorded is MISSING else recorded)}: gen_upgrades.py "
                               "--write-roots")
    runner = Runner(head, previous, isolation, run_id, args.keep)
    results = []
    for case in chosen:
        outcome = runner.run_case(case)
        results.append(outcome)
        print(f"{outcome['result']:8} {outcome['case']}" + (f": {outcome['message']}" if "message" in outcome else ""),
              flush=True)
    report = {"schema": REPORT_SCHEMA, "task": TASK, "head": {"binary": args.binary, "readable": head.readable},
              "previous": previous and {"tag": previous.name, "binary": previous.binary,
                                        "readable": previous.readable, "storeSchemas": previous.probed},
              "isolation": isolation.describe(), "results": results}
    if args.report:
        args.report.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    failed = [r for r in results if r["result"] != "Pass"]
    print(f"gen_upgrades: {len(results) - len(failed)}/{len(results)} cases pass")
    return 1 if failed or not results else 0


def write_roots(args: argparse.Namespace) -> int:
    given = dict(item.split("=", 1) for item in args.binary_map or ())
    tags = last_tags(args.count)
    stores = store_decls(Source())
    isolation = hermetic_env.isolation_for(args.isolation, "linux")
    FIXTURES.mkdir(parents=True, exist_ok=True)
    for old in FIXTURES.glob("cmux-tui-v*"):
        if old.name.split(".tar.gz")[0].removesuffix(".json") not in tags:
            old.unlink()
    run_id = f"upgrades-roots-{os.getpid()}-{time.time_ns()}"
    for tag in tags:
        build = probed_build(tag_build(tag, given.get(tag) or build_tag(tag), stores), isolation, run_id)
        manifest, tarball = write_root(build, isolation, run_id)
        (FIXTURES / manifest["tarball"]).write_bytes(tarball)
        (FIXTURES / f"{tag}.json").write_text(json.dumps(manifest, indent=2, ensure_ascii=False, sort_keys=True) + "\n",
                                              encoding="utf-8")
        print(f"gen_upgrades: {tag}: stored {json.dumps(manifest['stored'], sort_keys=True)}, "
              f"{len(manifest['files'])} files", flush=True)
    return write_corpus(DEFAULT_OUT, check=False)


# -------------------------------------------------------------------------------------------------- selftest


def _fake_source(files: Mapping[str, str]) -> Source:
    return Source("fake", read=lambda path: files.get(path))


STORE_SCHEMAS_FIXTURE = """
const STORES: &[(&str, &str, i64)] = &[
    (
        "workspace_registry",
        crate::workspace_registry::WORKSPACE_REGISTRY_FILE,
        crate::workspace_registry::SCHEMA_VERSION,
    ),
    ("conversation_store", crate::conversation_store::CONVERSATIONS_FILE, crate::conversation_store::SCHEMA_VERSION),
];
"""


class SelfTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="gen-upgrades-test-"))

    def tearDown(self) -> None:
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_store_list_and_layout_come_from_the_source(self) -> None:
        stores = store_decls(_fake_source({STORE_SCHEMAS_RS: STORE_SCHEMAS_FIXTURE}))
        self.assertEqual([s.name for s in stores], ["workspace_registry", "conversation_store"])
        tag = _fake_source({
            f"{CORE_SRC}/workspace_registry.rs": 'const SCHEMA_VERSION: i64 = 14;\n'
                                                 'const WORKSPACE_REGISTRY_FILE: &str = "workspace-registry.sqlite3";\n',
        })
        self.assertEqual(store_layout(tag, stores), ({"workspace_registry": 14},
                                                     {"workspace_registry": "workspace-registry.sqlite3"}))
        head = _fake_source({
            f"{CORE_SRC}/workspace_registry.rs": 'pub(crate) const SCHEMA_VERSION: i64 = 15;\n'
                                                 'pub(crate) const WORKSPACE_REGISTRY_FILE: &str = "w.sqlite3";\n',
            f"{CORE_SRC}/conversation_store.rs": 'pub(crate) const SCHEMA_VERSION: i64 = 2;\n'
                                                 'pub(crate) const CONVERSATIONS_FILE: &str = "c.sqlite3";\n',
        })
        self.assertEqual(store_layout(head, stores)[0], {"workspace_registry": 15, "conversation_store": 2})
        broken = _fake_source({f"{CORE_SRC}/workspace_registry.rs": "const OTHER: i64 = 1;\n"})
        with self.assertRaises(UpgradeError):
            store_layout(broken, stores)

    def test_head_source_lists_both_stores(self) -> None:
        readable, files = store_layout(Source(), store_decls(Source()))
        self.assertEqual(set(readable), {"workspace_registry", "conversation_store"})
        self.assertEqual(files["workspace_registry"], "workspace-registry.sqlite3")

    def test_verdict_mirrors_rollback_decision(self) -> None:
        kept = "cmux-tui-v9.9.9"
        self.assertIsNone(rollback_verdict({"workspace_registry": 15}, {"workspace_registry": 15}, kept))
        self.assertIsNone(rollback_verdict({"workspace_registry": 14}, {"workspace_registry": 15}, kept))
        self.assertEqual(rollback_verdict({"workspace_registry": 16}, {"workspace_registry": 15}, kept),
                         {"error": STORE_TOO_NEW,
                          "errorDetails": {"store": "workspace_registry", "stored": 16, "readable": 15}})
        self.assertEqual(rollback_verdict({"conversation_store": 2}, {"workspace_registry": 15}, kept),
                         {"error": UNKNOWN_STORE, "errorDetails": {"store": "conversation_store"}})
        # Name order, like the Swift decision: the conversation store comes first.
        self.assertEqual(rollback_verdict({"workspace_registry": 16, "conversation_store": 2},
                                          {"workspace_registry": 15}, kept)["error"], UNKNOWN_STORE)
        # A kept build that cannot say what it reads is refused before any store is looked at, an empty root too.
        for stored in ({"workspace_registry": 15}, {}):
            self.assertEqual(rollback_verdict(stored, None, kept),
                             {"error": PREDATES_ROLLBACK, "errorDetails": {"kept": kept}})

    def test_verdict_covers_every_store_on_the_root(self) -> None:
        kept = "cmux-tui-v9.9.9"
        both = {"workspace_registry": 15, "conversation_store": 2}
        # The registry case's root also holding a conversation store: the whole root is refused, so the case's
        # per-store expectation ("ok" for the registry) does not apply and the case fails instead of passing.
        with self.assertRaises(CaseFailure) as raised:
            root_verdict(both, "workspace_registry", {"workspace_registry": 15}, kept)
        self.assertEqual(raised.exception.step, "written")
        self.assertIsNone(root_verdict({"workspace_registry": 15}, "workspace_registry", {"workspace_registry": 15},
                                       kept))
        # The conversation case's root holds both stores; the verdict is the whole root's.
        self.assertEqual(root_verdict(both, "conversation_store", {"workspace_registry": 15}, kept)["error"],
                         UNKNOWN_STORE)
        self.assertEqual(root_verdict(both, "conversation_store", {"workspace_registry": 14, "conversation_store": 2},
                                      kept)["errorDetails"], {"store": "workspace_registry", "stored": 15,
                                                              "readable": 14})
        self.assertIsNone(root_verdict(both, "conversation_store", both, kept))
        with self.assertRaises(CaseFailure):
            root_verdict({"workspace_registry": 15}, "conversation_store", both, kept)

    def test_probe_reads_like_store_schema_probe(self) -> None:
        class Env:
            def __init__(self, code: int, out: str = "", error: Optional[BaseException] = None):
                self.code, self.out, self.error = code, out, error

            def run(self, argv: Sequence[str], **_: Any) -> subprocess.CompletedProcess:
                if self.error is not None:
                    raise self.error
                assert list(argv) == ["bin", STORE_SCHEMAS_FLAG]
                return subprocess.CompletedProcess(argv, self.code, self.out, "")

        self.assertEqual(probe_readable("bin", Env(0, '{"conversation_store":2,"workspace_registry":15}\n')),
                         {"conversation_store": 2, "workspace_registry": 15})
        # A build from before the probe: `cmux: unknown resource scope "__store-schemas".`, exit 2.
        self.assertIsNone(probe_readable("bin", Env(2)))
        self.assertIsNone(probe_readable("bin", Env(0, "[]")))
        self.assertIsNone(probe_readable("bin", Env(0, '{"workspace_registry": true}')))
        self.assertIsNone(probe_readable("bin", Env(0, '{"workspace_registry": "15"}')))
        self.assertIsNone(probe_readable("bin", Env(0, error=subprocess.TimeoutExpired("bin", 1))))
        self.assertIsNone(probe_readable("bin", Env(0, error=OSError("no such file"))))

    def test_refusal_compares_every_file_of_the_root(self) -> None:
        before = {"machine-id": "a", "s/workspace-registry.sqlite3": "b", "s/workspace-registry.sqlite3-wal": "c",
                  "s/conversations.sqlite3": "d", "s/writer.lock": "e"}
        self.assertEqual(refusal_changes(before, dict(before, **{"s/new.log": "f"})), [])
        self.assertEqual(refusal_changes(before, dict(before, **{"s/workspace-registry.sqlite3-wal": "x"})),
                         ["s/workspace-registry.sqlite3-wal"])
        gone = {k: v for k, v in before.items() if k != "s/workspace-registry.sqlite3"}
        self.assertEqual(refusal_changes(before, gone), ["s/workspace-registry.sqlite3"])
        self.assertEqual(refusal_changes(before, dict(before, **{"machine-id": "x"})), ["machine-id"])

    def test_subset_allows_new_members_only(self) -> None:
        old = {"workspaces": [{"id": "ws_1", "name": "a"}], "n": 1}
        self.assertEqual(subset_differences(old, {"workspaces": [{"id": "ws_1", "name": "a", "color": None}],
                                                  "n": 1, "extra": []}), [])
        self.assertEqual(subset_differences(old, {"workspaces": [{"id": "ws_1"}], "n": 1})[0]["pointer"],
                         "/workspaces/0/name")
        self.assertEqual(subset_differences(old, {"workspaces": [], "n": 1})[0]["pointer"], "/workspaces")
        self.assertEqual(subset_differences(old, {"workspaces": [{"id": "ws_1", "name": "a"}], "n": True})[0]
                         ["pointer"], "/n")
        self.assertEqual(subset_differences({"a/b": 1}, {"a/b": 2})[0]["pointer"], "/a~1b")

    def test_projection_drops_only_the_volatile_pointers(self) -> None:
        facet = {"cursor": {"generation": "g", "revision": "3"}, "clients": [{"id": "c"}],
                 "session": {"id": "s", "generation": "g", "revision": "3", "name": "oracle-upgrade"},
                 "workspaces": [{"id": "w"}]}
        self.assertEqual(project(facet), {"session": {"id": "s", "name": "oracle-upgrade"}, "workspaces": [{"id": "w"}]})
        self.assertIn("cursor", facet)

    def test_pack_is_deterministic_and_round_trips(self) -> None:
        state = self.tmp / "state"
        (state / "s").mkdir(parents=True)
        (state / "s" / "db.sqlite3").write_bytes(b"\x00data")
        (state / "machine-id").write_text("m\n")
        os.chmod(state / "s" / "db.sqlite3", 0o600)
        first = pack(state, "state")
        os.utime(state / "machine-id", (1, 1))
        self.assertEqual(pack(state, "state"), first)
        out = self.tmp / "out"
        out.mkdir()
        unpack(first, "state", out)
        self.assertEqual(file_hashes(out), file_hashes(state))
        self.assertEqual((out / "s" / "db.sqlite3").stat().st_mode & 0o777, 0o600)

    def test_unpack_refuses_members_outside_the_root(self) -> None:
        raw = io.BytesIO()
        with tarfile.open(fileobj=raw, mode="w") as tar:
            info = tarfile.TarInfo("state/../escape")
            info.size = 1
            tar.addfile(info, io.BytesIO(b"x"))
        data = gzip.compress(raw.getvalue())
        with self.assertRaises(UpgradeError):
            unpack(data, "state", self.tmp)
        self.assertFalse((self.tmp.parent / "escape").exists())

    def test_stored_schemas_reads_a_copy_with_its_wal(self) -> None:
        session = self.tmp / "state" / "oracle-upgrade-0"
        session.mkdir(parents=True)
        db = session / "w.sqlite3"
        writer = sqlite3.connect(str(db))
        writer.execute("PRAGMA journal_mode=WAL")
        writer.execute("CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT)")
        writer.execute("INSERT INTO meta VALUES ('schema_version', '15')")
        writer.commit()
        before = file_hashes(self.tmp / "state")
        self.assertEqual(stored_schemas(self.tmp / "state", {"workspace_registry": "w.sqlite3",
                                                             "conversation_store": "c.sqlite3"}),
                         {"workspace_registry": 15})
        self.assertEqual(file_hashes(self.tmp / "state"), before)
        writer.close()

    def test_corpus_cases_are_valid_and_named_per_tag_and_store(self) -> None:
        import case_checks
        import normalize
        schema = json.loads(CASE_SCHEMA.read_text(encoding="utf-8"))
        rules = case_checks.Rules(schema)
        manifests = [
            {"tag": "cmux-tui-v0.13.3", "stored": {"workspace_registry": 15}, "readable": {"workspace_registry": 15},
             "storeSchemas": {"workspace_registry": 15}},
            {"tag": "cmux-tui-v0.13.4", "stored": {"workspace_registry": 15}, "readable": {"workspace_registry": 15},
             "storeSchemas": {"workspace_registry": 15}},
        ]
        cases = corpus(manifests, {"workspace_registry": 16, "conversation_store": 2})
        self.assertEqual(sorted(cases), [
            "rollback-v0-13-4-conversation-store.json", "rollback-v0-13-4-workspace-registry.json",
            "v0-13-3-workspace-registry.json", "v0-13-4-workspace-registry.json"])
        for name, case in cases.items():
            self.assertEqual(normalize.validate(case, schema), [], name)
            self.assertEqual([f.message for f in case_checks.check_case(case, rules)], [], name)
            self.assertEqual(f"{case['id']}.json", name)
        too_new = cases["rollback-v0-13-4-workspace-registry.json"]
        opened = next(step for step in too_new["steps"] if step["op"] == "restart")
        self.assertEqual(opened["expect"]["error"], STORE_TOO_NEW)
        self.assertEqual(too_new["allow_crashes"][0]["steps"], ["open"])
        unknown = cases["rollback-v0-13-4-conversation-store.json"]
        self.assertIn("send", [step["id"] for step in unknown["steps"]])
        self.assertEqual(next(s for s in unknown["steps"] if s["op"] == "restart")["expect"]["error"], UNKNOWN_STORE)
        self.assertEqual(unknown["allow_crashes"][0]["steps"], ["open"])
        same = corpus(manifests, {"workspace_registry": 15})["rollback-v0-13-4-workspace-registry.json"]
        self.assertEqual([s["id"] for s in same["steps"]][-2:], ["open", "read"])
        # A previous tag without the probe (every tag before #18103): RollbackDecision refuses it outright.
        predates = [*manifests[:1], dict(manifests[1], storeSchemas=None)]
        refused = corpus(predates, {"workspace_registry": 15, "conversation_store": 2})
        for name in ("rollback-v0-13-4-workspace-registry.json", "rollback-v0-13-4-conversation-store.json"):
            opened = next(step for step in refused[name]["steps"] if step["op"] == "restart")
            self.assertEqual((opened["expect"]["error"], opened["expect"]["errorDetails"]),
                             (PREDATES_ROLLBACK, {"kept": "cmux-tui-v0.13.4"}), name)
            self.assertEqual([f.message for f in case_checks.check_case(refused[name], rules)], [], name)

    def test_populate_needs_every_method(self) -> None:
        methods = frozenset(step["args"]["method"] for step in POPULATE)
        self.assertEqual([s["id"] for s in populate_steps(methods, ["conversation_store"])],
                         [s["id"] for s in POPULATE])
        with self.assertRaises(UpgradeError):
            populate_steps(methods - {"workspace.move"}, [])

    def test_committed_fixtures_match_their_manifests_and_the_corpus(self) -> None:
        manifests = load_manifests()
        if not manifests:
            self.skipTest("no fixtures yet: gen_upgrades.py --write-roots")
        for manifest in manifests:
            check_fixture(manifest)
            self.assertIn("workspace_registry", manifest["stored"])
        self.assertEqual(write_corpus(DEFAULT_OUT, check=True), 0)


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--tags", action="store_true", help="print the tags the fixtures come from")
    mode.add_argument("--write-roots", action="store_true", help="write the state-root fixtures, then the corpus")
    mode.add_argument("--out", type=Path, help="write the corpus into DIR")
    mode.add_argument("--run", action="store_true", help="run the suite")
    mode.add_argument("--selftest", action="store_true", help="offline tests")
    parser.add_argument("--check", action="store_true", help="with --out: exit 1 when DIR differs")
    parser.add_argument("--count", type=int, default=DEFAULT_COUNT)
    parser.add_argument("--binary", help="--run: head's cmux-tui")
    parser.add_argument("--tag-binary", dest="binary_map", action="append", metavar="TAG=PATH",
                        help="--write-roots: a tag's built binary instead of linux_run.sh build")
    parser.add_argument("--previous-binary", help="--run: the previous tag's cmux-tui (default: linux_run.sh build)")
    parser.add_argument("--corpus", type=Path, default=DEFAULT_OUT)
    parser.add_argument("--case", action="append", default=[], help="--run: case id glob")
    parser.add_argument("--report", type=Path)
    parser.add_argument("--isolation", choices=hermetic_env.ISOLATION_MODES, default="netns")
    parser.add_argument("--keep", action="store_true", help="--run: keep each case's state root")
    args = parser.parse_args(argv)
    try:
        if args.selftest:
            suite = unittest.defaultTestLoader.loadTestsFromTestCase(SelfTest)
            return 0 if unittest.TextTestRunner(verbosity=1).run(suite).wasSuccessful() else 1
        if args.tags:
            print("\n".join(last_tags(args.count)))
            return 0
        if args.write_roots:
            return write_roots(args)
        if args.out is not None:
            return write_corpus(args.out, args.check)
        if not args.binary:
            parser.error("--run needs --binary")
        return run_suite(args)
    except (UpgradeError, hermetic_env.HermeticError) as error:
        print(f"gen_upgrades: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
