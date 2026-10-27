#!/usr/bin/env python3
"""State-corruption chaos lane (p10-stability-174, stability lane `state-corruption`).

Every file a tagged DEV build persists is damaged in turn, and the build is relaunched on it. The build must start,
set the damaged file aside as `<name>.corrupt*`, count one fault in its error journal, and keep the rest of its state.
This is Chrome's contract for its own stores: a Preferences file that does not parse is moved aside and replaced
(components/prefs/json_pref_store.cc, HandleReadErrors), and a SQLite database that reports corruption is razed and
recreated (sql/database.cc, RazeAndPoison; sql/recovery.cc), never a crash at startup.

  state-corruption-e2e.py --app "cmux DEV <tag>.app" [--out DIR] [--mutations truncate,flip,zero-fill,zero-length]
      [--only GLOB,...] [--seed N] [--include-chromium] [--list]

Run:
  1. Baseline. A fresh launch of the tag (its state roots moved aside to `<root>.bench-prev`), a workspace named
     with a random marker that echoes the marker in its terminal, a quit that keeps the sessions, and the tag's
     daemons ended (TagTeardown). A copy of every state root is the baseline.
  2. Control. The baseline restored and relaunched with nothing damaged: everything must come back. Files the app
     itself removes on a clean relaunch are volatile and left out of the "other state kept" check. A failed control
     stops the run (exit 2): no row after it would mean anything.
  3. One row per (file, mutation). The baseline restored, one file damaged, the tag relaunched, then checked:
       app_started      the control socket answered with a window (BenchApp.launch)
       daemon_started   a cmux-tui daemon of the bundle runs and `cmux workspace list` answers
       set_aside        `<name>.corrupt*` or `<stem>.corrupt*` appeared next to the file
       faults           error journal entries (warning or worse) since the relaunch that name the file or `corrupt`
       other_missing    baseline files, other than this one and the volatile ones, that are gone
       workspace_kept   the marker workspace is listed (required unless the damaged file holds the marker)
     A row passes when the app and the daemon started, the app is still up, no crash report was written, the other
     state was kept, and, when the format rejects the damaged bytes (`format_accepts` false for JSON, plist and
     SQLite; Python's own parsers and `PRAGMA integrity_check` decide), the file was set aside and a fault counted.
  4. The baseline restored, the tag's daemons ended.

Mutations: `truncate` keeps the first half, `flip` XORs up to 16 random bytes (seeded per file and mutation),
`zero-fill` writes zeros over every byte, `zero-length` empties the file.

Safety: the app must be a `cmux DEV <tag>.app` with a DEV bundle id (build_names.names refuses any other build). The
script writes only inside the tag's own roots: `Application Support/cmux/tags/<tag>`, `.../cmux/builds/<key>`,
`~/.acpmux/builds/<key>` (BuildIdentity) and its own scratch root, which holds the settings file and Chief home the
launches use. A path whose real location is outside them is refused, and so is a socket whose name is not this
build's tagged socket (`cmux-debug-<tag>.sock` or `cmux-debug--<key hash>.sock`). The baseline is restored only
while no process of the tag runs.

Inputs: the files are found by walking the roots, not listed by name, so a new store is covered the day it ships.
state-roots-baseline.tsv names the resolvers of those roots and the source sites not yet moved onto them (`move`
rows); the run summary lists those sites as out of this lane's reach.

Rows: one JSON object per (file, mutation) line in `<out>/state-corruption.jsonl` (schema cmux-state-corruption/v1).
`<out>/state-corruption-run.json` holds the roots, every file found or skipped, the control row, the daemon's state
dir and the error journal's. Exit 0 when every row passed, 1 when a row failed, 2 when the run could not measure (a
refused root or socket, a failed baseline or control).

Test phase: bare metal on a lab mini against the final tip; `python3 -I
scripts/cmux-next/tests/test_state_corruption_e2e.py` for the pure parts and a fake app (any host).
"""
import argparse, fnmatch, hashlib, json, os, plistlib, random, re, secrets, shutil, sqlite3, stat, subprocess, sys
import tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)  # its siblings, also under `python3 -I`
import bench_launch  # noqa: E402
import build_names  # noqa: E402
import launch_journey_report as journey  # noqa: E402

SCHEMA = "cmux-state-corruption/v1"
MUTATIONS = ("truncate", "flip", "zero-fill", "zero-length")
FLIP_BYTES = 16
SQLITE_MAGIC = b"SQLite format 3\x00"
# Formats whose reader must reject damage it cannot parse: set aside and one fault are required for them. A log
# (jsonl) drops a torn or bad line instead, and an unknown format has no parser here to judge the bytes.
STRICT_KINDS = ("json", "plist", "sqlite")
# Never targets: live endpoints and locks, SQLite's side files (part of their database, damaged with it only through
# the main file), logs, temporaries and earlier set-asides.
SKIP_NAMES = ("*.sock", "*.lock", "*.pid", "*-wal", "*-shm", "*-journal", "*.log", "*.tmp", "*.corrupt*", ".DS_Store",
              "SingletonLock", "SingletonSocket", "SingletonCookie")
# Chromium's caches (rebuilt from nothing) and its user-data directory (marked by `Local State`): Chromium's own
# corruption handling, not cmux's, unless --include-chromium.
CACHE_DIRS = ("Cache", "Code Cache", "GPUCache", "DawnCache", "DawnGraphiteCache", "DawnWebGPUCache", "GrShaderCache",
              "GraphiteDawnCache", "ShaderCache", "Crashpad", "component_crx_cache", "Service Worker")
CHROMIUM_MARK = "Local State"
MAX_BYTES = 64 << 20
STATE_ROOTS_BASELINE = os.path.join(HERE, "state-roots-baseline.tsv")
UNTAGGED_SOCKETS = ("cmux.sock", "cmux-debug.sock", "cmux-debug-.sock")
TAG = re.compile(r"[a-z0-9]+(?:-[a-z0-9]+)*")
KEY = re.compile(r"[A-Za-z0-9_](?:[A-Za-z0-9._-]*[A-Za-z0-9_])?")


class Refused(SystemExit):
    """The run would leave the tag's own state or socket: exit 2 with the reason."""

    def __init__(self, reason):
        super().__init__(f"state-corruption: REFUSED: {reason}")
        self.code = 2


# ---------------------------------------------------------------- pure parts (tests feed them)

def mutate(data, mutation, rng):
    """(damaged bytes, detail) of `data` under `mutation`; `rng` is a random.Random for `flip`."""
    if mutation == "truncate":
        kept = len(data) // 2
        return data[:kept], {"kept": kept}
    if mutation == "flip":
        offsets = sorted(rng.sample(range(len(data)), min(FLIP_BYTES, len(data))))
        out = bytearray(data)
        for offset in offsets:
            out[offset] ^= rng.randrange(1, 256)  # never 0: every chosen byte changes
        return bytes(out), {"offsets": offsets}
    if mutation == "zero-fill":
        return bytes(len(data)), {}
    if mutation == "zero-length":
        return b"", {}
    raise ValueError(f"unknown mutation {mutation!r}")


def row_rng(seed, file_id, mutation):
    return random.Random(f"{seed}:{file_id}:{mutation}")


def kind_of(name, head):
    """The format of a file from its name and first bytes: sqlite, json, jsonl, plist or other."""
    if head.startswith(SQLITE_MAGIC):
        return "sqlite"
    if head.startswith(b"bplist00") or name.endswith(".plist"):
        return "plist"
    if name.endswith((".jsonl", ".ndjson")):
        return "jsonl"
    if name.endswith(".json"):
        return "json"
    return "other"


def format_accepts(kind, data):
    """Whether the format still reads `data` (True/False), or None when this script has no parser for it."""
    if kind == "json":
        try:
            json.loads(data.decode("utf-8"))
            return True
        except (UnicodeDecodeError, ValueError):
            return False
    if kind == "plist":
        try:
            plistlib.loads(data)
            return True
        except (plistlib.InvalidFileException, ValueError, OverflowError, KeyError, IndexError, TypeError):
            return False
    if kind == "sqlite":
        return sqlite_accepts(data)
    return None


def sqlite_accepts(data):
    """SQLite's own verdict on a database file's bytes: `PRAGMA integrity_check` is `ok` (an empty file is an empty
    database). The bytes are read from a scratch copy with immutable=1, which reads the main file only."""
    with tempfile.TemporaryDirectory(prefix="state-corruption-sqlite-") as scratch:
        path = os.path.join(scratch, "db")
        with open(path, "wb") as f:
            f.write(data)
        try:
            connection = sqlite3.connect(f"file:{path}?immutable=1", uri=True)
            try:
                rows = connection.execute("PRAGMA integrity_check").fetchall()
            finally:
                connection.close()
        except sqlite3.DatabaseError:
            return False
        return rows == [("ok",)]


def skipped_name(name):
    return any(fnmatch.fnmatchcase(name, pattern) for pattern in SKIP_NAMES)


def discover(roots, include_chromium=False, max_bytes=MAX_BYTES):
    """(targets, skipped) under `roots` ({label: directory}): each target {"id": "<label>/<relative path>", "root",
    "path", "kind", "bytes", "sha256"}, each skip {"id", "why"}. Only regular files; symlinks are never followed."""
    targets, skipped = [], []
    for label, root in sorted(roots.items()):
        if not os.path.isdir(root):
            continue
        for directory, dirs, files in os.walk(root):
            relative_dir = os.path.relpath(directory, root)
            keep = []
            for name in sorted(dirs):
                file_id = f"{label}/{os.path.normpath(os.path.join(relative_dir, name))}"
                full = os.path.join(directory, name)
                if name in CACHE_DIRS:
                    skipped.append({"id": file_id + "/", "why": "cache"})
                elif not include_chromium and os.path.isfile(os.path.join(full, CHROMIUM_MARK)):
                    skipped.append({"id": file_id + "/", "why": "chromium user data"})
                elif not os.path.islink(full):
                    keep.append(name)
            dirs[:] = keep
            for name in sorted(files):
                full = os.path.join(directory, name)
                file_id = f"{label}/{os.path.normpath(os.path.join(relative_dir, name))}"
                info = os.lstat(full)
                why = ("not a regular file" if not stat.S_ISREG(info.st_mode) else
                       "skipped name" if skipped_name(name) else
                       "empty" if info.st_size == 0 else
                       f"over {max_bytes} bytes" if info.st_size > max_bytes else None)
                if why:
                    skipped.append({"id": file_id, "why": why})
                    continue
                with open(full, "rb") as f:
                    data = f.read()
                targets.append({"id": file_id, "root": label, "path": full, "kind": kind_of(name, data[:16]),
                                "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()})
    return targets, skipped


def select(targets, only):
    """The targets whose id matches one of the `only` globs (all when `only` is empty)."""
    return [t for t in targets if not only or any(fnmatch.fnmatchcase(t["id"], g) for g in only)]


def set_aside_names(name, before, after):
    """Entries new in a directory (`before`, `after`: names) that set `name` aside: `<name>.corrupt*` or
    `<stem>.corrupt*`."""
    stem = os.path.splitext(name)[0]
    prefixes = (f"{name}.corrupt", f"{stem}.corrupt")
    return sorted(entry for entry in set(after) - set(before) if entry.startswith(prefixes))


def fault_entries(reply, since_ms, name):
    """Error journal entries (errors.list) seen at or after `since_ms` that name the file (`name` or its stem) or say
    `corrupt`."""
    if not isinstance(reply, dict):
        return []
    stem = os.path.splitext(name)[0]
    needles = {name.lower(), stem.lower(), "corrupt"}
    found = []
    for entry in reply.get("entries") or []:
        if not isinstance(entry, dict) or (entry.get("last_ms") or 0) < since_ms:
            continue
        text = " ".join(str(v) for v in (entry.get("template"), entry.get("sample"),
                                         *((entry.get("context") or {}).values()))).lower()
        if any(needle in text for needle in needles):
            found.append(entry)
    return found


def problems_of(row):
    """Why a row failed (empty: it passed)."""
    out = []
    if not row["app_started"]:
        out.append(f"the app did not start ({row.get('launch_error') or 'no answer'})")
    else:
        if not row["daemon_started"]:
            out.append("no daemon answered")
        if not row["app_alive"]:
            out.append("the app ended after it started")
    if row["crash_reports"]:
        out.append(f"crash reports: {', '.join(os.path.basename(p) for p in row['crash_reports'])}")
    if row["other_missing"]:
        out.append(f"other state lost: {', '.join(row['other_missing'])}")
    if row["other_set_aside"]:
        out.append(f"other files set aside: {', '.join(row['other_set_aside'])}")
    if row["workspace_expected"] and row["app_started"] and not row["workspace_kept"]:
        out.append("the marker workspace was lost, and this file does not hold it")
    if row["expect_set_aside"]:
        if not row["set_aside"]:
            out.append("the damaged file was not set aside as *.corrupt")
        if not row["faults"]:
            out.append("no fault was counted")
    return out


def socket_allowed(path, tag, names):
    """Whether `path` names this build's tagged control socket: `cmux-debug-<tag>.sock` (BenchApp's
    socket_candidates) or the socket build_names gives the bundle (`cmux-debug-<kept tag>.sock` or
    `cmux-debug--<key hash>.sock`). The untagged sockets (`cmux.sock`, `cmux-debug.sock`) and a shipped build's tag
    are never this build's."""
    base = os.path.basename(path or "")
    own = {os.path.basename(names["socket"])}
    if tag and tag not in build_names.OWNED_TAGS:
        own.add(f"cmux-debug-{tag}.sock")
    return base in own and base not in UNTAGGED_SOCKETS


def inside(path, root):
    """Whether the real location of `path` is `root` or below it (symlinks resolved on both)."""
    real, base = os.path.realpath(path), os.path.realpath(root)
    return real == base or real.startswith(base.rstrip(os.sep) + os.sep)


def tag_roots(app_support, user_home, tag, names, scratch):
    """{label: directory} this run may write: the tag's state, the build's App Support and acpmux homes
    (BuildIdentity: `builds/<key>`), and the run's scratch root. Raises Refused for a tag or key that is not one
    path component of its own (BuildIdentity.tagSlug, component) or a tag a shipped build owns, and for a root that is
    a shared one."""
    key = os.path.basename(names["acpmux_home"])
    if not TAG.fullmatch(tag or "") or tag in build_names.OWNED_TAGS:
        raise Refused(f"tag {tag!r} is not a DEV build's own tag")
    if not KEY.fullmatch(key) or not key.startswith("com.cmuxterm.app."):
        raise Refused(f"build key {key!r} is not a DEV build's own key")
    roots = {"tag-state": os.path.join(app_support, "tags", tag),
             "build-support": os.path.join(app_support, "builds", key),
             "acpmux": names["acpmux_home"], "scratch": scratch}
    shared = {os.path.realpath(p) for p in (user_home, app_support, os.path.join(app_support, "tags"),
                                             os.path.join(app_support, "builds"), os.path.join(user_home, ".acpmux"),
                                             os.path.join(user_home, ".acpmux", "builds"))}
    for label, root in roots.items():
        if not os.path.isabs(root) or os.path.realpath(root) in shared:
            raise Refused(f"root {label} {root} is a shared state root")
    return roots


def state_sites(text):
    """The rows of state-roots-baseline.tsv: {"resolvers": [...], "unreviewed": [...]}, source files. A `keep` row
    whose reason starts with `resolver:` names a resolver of the roots this lane walks; a `move` row is a site that
    may write state outside them, which no row of this lane reaches (the run summary lists them)."""
    sites = {"resolvers": [], "unreviewed": []}
    for line in text.splitlines():
        parts = line.split("\t")
        if line.startswith("#") or len(parts) < 4:
            continue
        path, _, verdict, reason = parts[:4]
        if verdict == "keep" and reason.startswith("resolver:"):
            sites["resolvers"].append(path)
        elif verdict == "move":
            sites["unreviewed"].append(path)
    return sites


def guard(path, roots):
    """`path`, when it is inside one of `roots`; else Refused."""
    if not any(inside(path, root) for root in roots.values()):
        raise Refused(f"{path} is outside the tag's roots ({', '.join(sorted(roots.values()))})")
    return path


# ---------------------------------------------------------------- the tag's roots on disk

def copy_roots(roots, dest):
    """Copies each existing root into `dest/<label>` (symlinks as links; sockets and pipes left out)."""
    def ignore(directory, names):
        return [n for n in names if not (os.path.islink(os.path.join(directory, n)) or
                                         stat.S_ISREG(os.lstat(os.path.join(directory, n)).st_mode) or
                                         stat.S_ISDIR(os.lstat(os.path.join(directory, n)).st_mode))]
    os.makedirs(dest, exist_ok=True)
    for label, root in roots.items():
        if os.path.isdir(root):
            shutil.copytree(root, os.path.join(dest, label), symlinks=True, ignore=ignore)


def restore_roots(roots, pristine, idle):
    """Puts every root back to its copy in `pristine` (a root without a copy is removed). `idle()` must say no process
    of the tag runs: a daemon would write while the files change under it."""
    if not idle():
        raise Refused("processes of the tag still run; the baseline is restored only with the tag idle")
    for label, root in roots.items():
        guard(root, roots)
        if os.path.islink(root):
            raise Refused(f"root {label} {root} is a symlink")
        if os.path.isdir(root):
            shutil.rmtree(root)
        copy = os.path.join(pristine, label)
        if os.path.isdir(copy):
            shutil.copytree(copy, root, symlinks=True)


def move_aside(roots, labels):
    """BenchApp.start_fresh for the roots it does not own: each to `<root>.bench-prev` (one kept)."""
    for label in labels:
        root = guard(roots[label], roots)
        if not os.path.lexists(root):
            continue
        prev = root + ".bench-prev"
        if os.path.lexists(prev):
            shutil.rmtree(prev, ignore_errors=True)
        os.rename(root, prev)
        print(f"state-corruption: {label} moved aside to {prev}", flush=True)


def listing(directory):
    try:
        return os.listdir(directory)
    except OSError:
        return []


def holds(path, marker):
    with open(path, "rb") as f:
        return marker.encode() in f.read()


# ---------------------------------------------------------------- the run

class Run:
    def __init__(self, args, bench_app=bench_launch.BenchApp):
        self.args = args
        self.app = os.path.realpath(args.app).rstrip("/")
        self.tag = bench_launch.tag_of(self.app)
        bundle_id, shipped = build_names.bundled_tag(self.app)
        try:
            self.names = build_names.names(bundle_id or "", shipped, bench_launch.account_home())
        except ValueError as error:
            raise Refused(str(error)) from None
        self.out = os.path.abspath(args.out or tempfile.mkdtemp(prefix=f"state-corruption-{self.tag}-"))
        os.makedirs(self.out, exist_ok=True)
        scratch = os.path.join(self.out, "state")
        self.settings = os.path.join(scratch, "settings", "cmux-next.json")
        env = {"CMUX_NEXT_CONFIG_FILE": self.settings, "CMUX_NEXT_CHIEF_HOME": os.path.join(scratch, "chief")}
        self.bench = bench_app(self.app, out=self.out, env=env, log_name="app.log")
        app_support = os.path.dirname(os.path.dirname(self.bench.state_root()))
        self.roots = tag_roots(app_support, bench_launch.account_home(), self.tag, self.names, scratch)
        if any(inside(self.out, root) for label, root in self.roots.items() if label != "scratch"):
            raise Refused(f"--out {self.out} is inside a root this run replaces")
        self.pristine = os.path.join(self.out, "pristine")
        self.rows_path = os.path.join(self.out, "state-corruption.jsonl")
        self.summary_path = os.path.join(self.out, "state-corruption-run.json")
        self.marker = f"corrupt-e2e-{secrets.token_hex(4)}"
        self.volatile = set()
        self.journal_dir = None

    # The app's socket and CLI, only ever this build's.
    def socket(self):
        if not socket_allowed(self.bench.socket, self.tag, self.names):
            raise Refused(f"{self.bench.socket} is not the tagged socket of {self.app}")
        return self.bench.socket

    def rpc(self, method, params=None, timeout=20):
        return bench_launch.rpc_at(self.socket(), method, params, timeout)

    def cli(self, *argv, timeout=30):
        sock = self.socket()
        env = {**bench_launch.BASE_ENV, "HOME": bench_launch.account_home(), "CMUX_SOCKET_PATH": sock,
               "CMUX_QUIET": "1"}
        try:
            return subprocess.run([self.bench.cli, "--socket", sock, *argv], capture_output=True, text=True,
                                  timeout=timeout, env=env)
        except subprocess.TimeoutExpired as error:
            return subprocess.CompletedProcess(error.cmd, 124, "", f"timed out after {timeout} s")

    def journal(self, since_ms):
        """The error journal's entries (warning or worse) since `since_ms` (errors.list)."""
        return self.rpc("errors.list", {"since_ms": since_ms, "level": "warning", "limit": 1000})

    def idle(self):
        return not self.bench.tag_processes()

    def daemon_pids(self):
        prefix = os.path.join(self.app, "Contents/Resources/bin/cmux-tui") + " "
        return [pid for pid, command in self.bench.tag_processes() if command.startswith(prefix)]

    def wait(self, predicate, seconds, step=0.5):
        deadline = time.monotonic() + seconds
        while True:
            value = predicate()
            if value or time.monotonic() >= deadline:
                return value
            time.sleep(step)  # a bounded poll of the app this run launched

    def launch(self, fresh):
        """(started, error): one launch of the tag on the state on disk."""
        self.bench.fresh_state = fresh
        try:
            self.bench.launch(timeout=self.args.launch_timeout)
        except bench_launch.LaunchError as error:
            return False, error.reason
        finally:
            journey.remember(self.bench)
        self.socket()
        return True, None

    def end(self):
        """Quits the app keeping its sessions on disk, then ends the tag's daemons (their own shutdown first)."""
        if self.bench.process is not None and self.bench.process.poll() is None:
            if not self.bench.quit_keep_sessions()["quit"]:
                self.bench.process.kill()  # the PID this run started
                self.bench.process.wait()
        if self.bench.teardown:
            self.bench.teardown.end()

    def baseline(self):
        move_aside(self.roots, ("build-support", "acpmux"))
        os.makedirs(os.path.dirname(self.settings), exist_ok=True)
        with open(guard(self.settings, self.roots), "w") as f:
            json.dump(bench_launch.bench_env.with_config_defaults(self.bench.config), f)
        started, error = self.launch(fresh=True)
        if not started:
            raise Refused(f"the baseline launch failed: {error}")
        made = self.cli("workspace", "create", "--name", self.marker, "--shell", f"echo {self.marker}; exec cat")
        if made.returncode != 0 or not self.wait(lambda: self.marker in self.cli("workspace", "list").stdout, 20):
            raise Refused(f"the marker workspace was not made: {(made.stdout + made.stderr).strip()[:200]}")
        journal = self.rpc("errors.list", {"limit": 1, "harvest": False})
        self.journal_dir = journal.get("dir") if isinstance(journal, dict) else None
        time.sleep(self.args.persist_seconds)  # the daemon and the app write their state on their own schedule
        self.end()
        for root in sorted(self.bench.teardown.state_roots if self.bench.teardown else ()):
            if not any(inside(root, r) for r in self.roots.values()):
                raise Refused(f"the daemon kept state in {root}, outside the tag's roots")
        if not self.idle():
            raise Refused("processes of the tag still run after the baseline teardown")
        copy_roots(self.roots, self.pristine)
        return discover({label: os.path.join(self.pristine, label) for label in self.roots},
                        self.args.include_chromium)

    def live_path(self, target):
        return os.path.join(self.roots[target["root"]], target["id"].split("/", 1)[1])

    def case(self, target, mutation, targets):
        """One row: the baseline restored, `target` damaged by `mutation` (None: the control), a relaunch, checks."""
        began = time.monotonic()
        restore_roots(self.roots, self.pristine, self.idle)
        row = {"schema": SCHEMA, "tag": self.tag, "file": target["id"] if target else None,
               "mutation": mutation or "none", "kind": target["kind"] if target else None,
               "bytes_before": target["bytes"] if target else None, "seed": self.args.seed}
        name = directory = None
        before = []
        if target:
            path = guard(self.live_path(target), self.roots)
            name, directory = os.path.basename(path), os.path.dirname(path)
            with open(path, "rb") as f:
                data = f.read()
            damaged, detail = mutate(data, mutation, row_rng(self.args.seed, target["id"], mutation))
            with open(path, "wb") as f:
                f.write(damaged)
            accepts = format_accepts(target["kind"], damaged)
            before = listing(directory)
            row.update(bytes_after=len(damaged), detail=detail, damaged_sha256=hashlib.sha256(damaged).hexdigest(),
                       format_accepts=accepts, expect_set_aside=target["kind"] in STRICT_KINDS and accepts is False,
                       workspace_expected=not holds(os.path.join(self.pristine, target["id"]), self.marker))
        else:
            row.update(format_accepts=None, expect_set_aside=False, workspace_expected=True)
        since = time.time()
        since_ms = int(since * 1000)
        started, error = self.launch(fresh=False)
        row.update(app_started=started, launch_error=error, daemon_started=False, workspace_kept=False, set_aside=[],
                   set_aside_matches=None, faults=0, fault_samples=[], app_alive=False)
        if started:
            daemons = self.wait(self.daemon_pids, 15)
            row["daemon_started"] = bool(daemons) and self.cli("workspace", "list").returncode == 0
            # Wait only for what this row expects to come; what it does not expect is read once.
            listed = self.wait(lambda: self.marker in self.cli("workspace", "list").stdout,
                               self.args.settle if row["workspace_expected"] else 0)
            row["workspace_kept"] = bool(listed)
            if target:
                settle = self.args.settle if row["expect_set_aside"] else 0
                row["set_aside"] = self.wait(lambda: set_aside_names(name, before, listing(directory)), settle)
                faults = self.wait(lambda: fault_entries(self.journal(since_ms), since_ms, name), settle, 1.0)
                row["faults"] = sum(int(entry.get("count") or 1) for entry in faults)
                row["fault_samples"] = [str(e.get("sample") or e.get("template"))[:200] for e in faults[:3]]
                if row["set_aside"]:
                    with open(os.path.join(directory, row["set_aside"][0]), "rb") as f:
                        row["set_aside_matches"] = hashlib.sha256(f.read()).hexdigest() == row["damaged_sha256"]
            row["app_alive"] = self.bench.process.poll() is None
        daemon = os.path.join(self.app, "Contents/Resources/bin/cmux-tui")
        row["crash_reports"] = [*bench_launch.crash_reports(since, binary=self.bench.binary),
                                *bench_launch.crash_reports(since, name="cmux-tui", binary=daemon)]
        others = [t for t in targets if t is not target and t["id"] not in self.volatile]
        missing = sorted(t["id"] for t in others if not os.path.exists(self.live_path(t)))
        if target:
            row["other_missing"] = missing
        else:  # the control: what a clean relaunch removes by itself is volatile, not lost
            row["other_missing"], row["volatile"] = [], missing
        row["other_set_aside"] = sorted({
            entry for t in others
            for entry in set_aside_names(os.path.basename(t["id"]),
                                         listing(os.path.dirname(os.path.join(self.pristine, t["id"]))),
                                         listing(os.path.dirname(self.live_path(t))))} - set(row["set_aside"]))
        self.end()
        row["problems"] = problems_of(row)
        row["result"] = "fail" if row["problems"] else "pass"
        row["seconds"] = round(time.monotonic() - began, 1)
        print(f"{row['result'].upper():4} {row['file'] or '(control)'} {row['mutation']}"
              + (f": {'; '.join(row['problems'])}" if row["problems"] else ""), flush=True)
        return row

    def main(self):
        mutations = [m for m in self.args.mutations.split(",") if m]
        unknown = sorted(set(mutations) - set(MUTATIONS))
        if unknown:
            raise SystemExit(f"state-corruption: unknown mutation {', '.join(unknown)} "
                             f"(known: {', '.join(MUTATIONS)})")
        if self.bench.teardown:
            self.bench.teardown.install()
        baselined = False
        rows = []
        with open(STATE_ROOTS_BASELINE, encoding="utf-8") as f:
            sites = state_sites(f.read())
        summary = {"schema": SCHEMA + "-run", "tag": self.tag, "app": self.app, "roots": self.roots,
                   "seed": self.args.seed, "mutations": mutations, "state_sites": sites}
        try:
            targets, skipped = self.baseline()
            baselined = True
            chosen = select(targets, self.args.only)
            summary.update(targets=targets, chosen=[t["id"] for t in chosen], skipped=skipped,
                           daemon_state_roots=sorted(self.bench.teardown.state_roots if self.bench.teardown else ()),
                           error_journal={"dir": self.journal_dir, "inside_roots": bool(self.journal_dir) and any(
                               inside(self.journal_dir, root) for root in self.roots.values())})
            print(f"state-corruption: {len(targets)} files ({len(chosen)} chosen), {len(skipped)} skipped, "
                  f"{len(sites['unreviewed'])} unreviewed state sites (state-roots-baseline.tsv) out of reach; "
                  f"rows {self.rows_path}", flush=True)
            if self.args.list:
                for t in chosen:
                    print(f"  {t['id']} {t['kind']} {t['bytes']} B")
                for s in skipped:
                    print(f"  skip {s['id']}: {s['why']}")
                return 0
            control = summary["control"] = self.case(None, None, targets)
            self.volatile = set(control["volatile"])
            if control["problems"]:
                print(f"state-corruption: the control relaunch failed: {'; '.join(control['problems'])}")
                return 2
            if self.volatile:
                print(f"state-corruption: volatile (removed by a clean relaunch): {', '.join(sorted(self.volatile))}")
            open(self.rows_path, "w").close()
            for target in chosen:
                for mutation in mutations:
                    row = self.case(target, mutation, targets)
                    rows.append(row)
                    with open(self.rows_path, "a") as f:  # each row as it ends: a cut-off run keeps its rows
                        f.write(json.dumps(row, sort_keys=True) + "\n")
        finally:
            summary["rows"] = len(rows)
            summary["failed"] = sum(1 for r in rows if r["result"] == "fail")
            with open(self.summary_path, "w") as f:
                json.dump(summary, f, indent=1, sort_keys=True)
            if self.bench.process is not None and self.bench.process.poll() is None:
                self.end()
            if baselined and self.idle():
                restore_roots(self.roots, self.pristine, self.idle)
        failed = [r for r in rows if r["result"] == "fail"]
        print(f"state-corruption: {len(rows) - len(failed)}/{len(rows)} rows passed; rows {self.rows_path}")
        return 1 if failed else 0


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--app", required=True, help='the tagged build: "cmux DEV <tag>.app"')
    parser.add_argument("--out", help="the run's folder: rows, app log, baseline copy, scratch root")
    parser.add_argument("--mutations", default=",".join(MUTATIONS), help=f"comma list of {', '.join(MUTATIONS)}")
    parser.add_argument("--only", type=lambda v: [g for g in v.split(",") if g], default=[],
                        help="comma list of globs over file ids (`<root>/<relative path>`, e.g. 'tag-state/tui/*')")
    parser.add_argument("--seed", type=int, default=174, help="the flip offsets' seed")
    parser.add_argument("--include-chromium", action="store_true", help="also damage Chromium's user-data files")
    parser.add_argument("--launch-timeout", type=float, default=120.0)
    parser.add_argument("--settle", type=float, default=15.0,
                        help="seconds a relaunch may take to set aside and report")
    parser.add_argument("--persist-seconds", type=float, default=5.0, help="seconds the baseline waits for writes")
    parser.add_argument("--list", action="store_true", help="make the baseline, list the files, damage nothing")
    return parser.parse_args(argv)


def main(argv=None, bench_app=bench_launch.BenchApp):
    args = parse_args(argv)
    try:
        return Run(args, bench_app).main()
    except Refused as refused:
        print(refused, flush=True)
        return 2


if __name__ == "__main__":
    sys.exit(main())
