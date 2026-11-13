#!/usr/bin/env python3
"""The migration proof of the registry rebuild at a retention floor, on a GENERATED registry
(scripts/measure/registry-migration-proof.sh builds the binaries and writes the registry).

Arms, each on its own APFS clone of the generated state, with real owner processes:
  control  each older owner binary on a clone of the state BEFORE the migration: what its
         saved roster and its History list hold there. The same binary's result on the migrated
         state is compared with it (an older build that shows less on BOTH is not a loss of the
         migration).
  main   start 1 (the owner folds, names the floor, builds the new registry beside the file;
         its memory, CPU time, the time of an identify request and the time of a
         rename-workspace request, which commits to the registry, are sampled), stop, start 2
         (the swap at open), stop, starts 3 and 4 (the replaced file gets its kept name and
         stays: the rule is 7 days AND 3 full starts), stop.
  second-swap  on a clone of the migrated state: this script removes the kept file (as the rule
         does later) and synth_registry --advance-checkpoints appends 200,000 records and moves
         the restore points to the head (what days of use do); then start (the owner builds
         again at the new floor), stop, start (the second swap), stop. Its counts are compared
         with the counts after the advance: the appended records are progress records, which
         change no agent and no session.
  kill-stage  kill -9 while start 1 stages; then start, wait for the build, stop, start, stop.
  kill-swap   kill -9 while start 2 runs the swap (the staging file changes); then start, stop.
  kill-renamed  kill -9 as soon as the backup file exists (after the rename, before the start
         is complete); then start, stop.
  space  a debug owner with a free-space margin no disk has: the rebuild is refused. With
         --space-dwell it runs on: the retention pass then deletes in place (a debug build's
         lock times).
  in-place  a RELEASE owner on a clone from before start 1 that starts no rebuild (this script
         puts an empty file with the kept name beside the registry): its retention passes
         delete sealed segments in place for --in-place-dwell seconds. The row: the registry
         lock by site (server-stats `locks`: acquisitions and hold times) and the times of an
         identify request each 0.5 s and a rename-workspace request each second.
  kill-hold  (not in the default list) kill -9 BETWEEN TWO HOLDS of the delete in place of
         one segment: as the in-place arm, and this script reads counts from the file each few
         milliseconds and kills the owner when the oldest sealed segment is at or below the
         floor with a part of its rows gone. The start after it must end that delete: the
         segment and each row at or below its end gone, the counts and the served answer equal.
  in-place-kept  the delete in place of each day: a RELEASE owner on a clone of the state
         AFTER the swap, with the kept file of that swap beside it (no rebuild for 7 days and 3
         starts), after synth_registry appended --kept-records sealed records. The row: the
         registry lock by site, each pass that deleted (seconds, segments), and the request
         times in two groups: while a pass deleted, and with no pass.
  in-place-kept-nowatch, in-place-kept-quiet  (not in the default list) the in-place-kept arm
         with NO read of the registry file by this script while the owner runs (nowatch), and
         with no request of the probe either (quiet: no rename, so the WAL bytes are those of
         the owner's own work). Both run for --kept-dwell seconds and give no pass rows. They
         say whether a large WAL comes from this script's reader or from the owner.
  in-place-stacks, in-place-kept-stacks  (not in the default list) the same two arms, each on
         its own clone, with the macOS stack sampler (/usr/bin/sample, each --stack-ms
         milliseconds) on the owner: of the samples inside the delete of one segment (the
         registry lock is held there), the share that waits for another writer of the file
         (SQLite's busy handler: the transaction has not taken its first write yet), that
         syncs, writes or reads the file, and that runs in the process. The sampler stops the
         owner for each sample, so the lock and request times of these two arms are NOT the
         times of the arms without it.
  first-fold  (not in the default list) how long the first fold of the agent History takes: a
         head owner on a clone from before start 1 (the saved fold is behind the head) is asked
         for history.entries.list (the agent kind, as the app's vault asks) from its ready on,
         again 1 s after each answer, until an answer names no pending kind. The row: the
         seconds from the first ask to the first complete answer, the count of answers that
         were not complete, the sessions of the first answer and of the complete one, and the
         slowest ask. The owner runs no longer than that, so it builds and deletes nothing.
  old    each older owner binary (--old-bin, a list) on its own clone of the migrated state:
         does it open it, what does it serve, what do the counts say after it stayed up
         --old-dwell seconds (a roster rebuild of another reducer version saves in that time),
         and after the new owner opened the state again (the return path: the roster and the
         History of the head build, and the two reducer base rows byte for byte).
  old-raised  each older owner binary on a clone of the migrated state whose stored
         schema_version is RAISED by hand (sqlite, by this script: no build writes it): does it
         refuse, with which lines and exit code, and is the folder byte for byte the same after
         it (a list of each file with its size and SHA-256, before and after).
After each arm: the counts of the registry (synth_registry --counts) against the counts before.
Equal = workspaces, tabs, terminals, roster agents, History sessions; the journal head never
goes back. The owner's answers over the socket (history.entries.list, agent.list) are compared
too: the count and a one-way mark (SHA-256, 16 hex digits) of the sorted ids. agent.list gives
the agent rows of terminals: on a state with no terminal each answer is 0 rows, and the verdict
then says that this comparison is void. Output: RMP
{json} per step and a Markdown table. The report holds counts, sizes, times, those marks and
the source file names of lock sites only: no paths and no row contents. A time from a loaded
host is not a perf number.
"""

import argparse
import hashlib
import importlib.util
import json
import os
import re
import shutil
import signal
import socket
import sqlite3
import subprocess
import sys
import threading
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location("drs", HERE / "daemon-registry-start.py")
drs = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(drs)

REGISTRY = drs.REGISTRY
STAGING = REGISTRY + ".output-cleanup"
# The file a swap replaced: under the first name until one full start, then the kept name.
PREVIOUS = REGISTRY + ".pre-output-cleanup"
KEPT = REGISTRY + ".kept-before-cleanup"
EQUAL_KEYS = ("workspaces", "tabs", "terminals", "roster_agents", "history_sessions",
              "roster_rested", "history_rested")
ROSTER_KEYS = ("roster_version", "roster_agents", "roster_rested", "roster_cursor",
               "history_sessions", "history_rested", "history_cursor")
BASE_KEYS = ("roster_base", "history_base")


def say(tag, value):
    print(f"{tag} {json.dumps(value)}", flush=True)


class Owner:
    """One owner process on a state dir."""

    def __init__(self, args, state, label, binary=None, env=None):
        self.args, self.state, self.label = args, str(state), label
        self.binary = binary or args.bin
        self.home = os.path.join(args.home, label)
        os.makedirs(self.home, exist_ok=True)
        self.socket = os.path.join(args.socket_dir, "mux.sock")
        self.env = drs.owner_env(
            self.home,
            CMUX_TUI_STATE_DIR=self.state,
            CMUX_TUI_CONFIG=os.path.join(self.home, "config.json"),
            CMUX_TUI_LOG_FILE=os.path.join(self.home, "client.log"),
            **(env or {}),
        )
        if os.path.exists(self.socket):
            os.unlink(self.socket)
        self.log_path = os.path.join(self.home, "owner.log")
        self.log = open(self.log_path, "ab")
        self.started = time.monotonic()
        self.child = subprocess.Popen(
            [self.binary, "--headless", "--session", args.session, "--socket", self.socket],
            env=self.env,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=self.log,
        )

    def elapsed(self):
        return time.monotonic() - self.started

    def log_text(self):
        try:
            return Path(self.log_path).read_text(errors="replace")
        except OSError:
            return ""

    def log_line(self, needle):
        for line in self.log_text().splitlines():
            if needle in line:
                return line
        return None

    def wait_ready(self, timeout=None):
        deadline = self.started + (timeout or self.args.ready_timeout)
        while time.monotonic() < deadline and self.child.poll() is None:
            if os.path.exists(self.socket):
                reply = drs.identify(self.socket, 2.0)
                if reply is not None and (reply.get("data") or {}).get("lifecycle_ready") is True:
                    return round(self.elapsed(), 3)
            time.sleep(0.01)
        return None

    def wait_log(self, needles, timeout, bad=()):
        """The first of `needles` in the log: (needle, seconds from spawn). None at the timeout,
        at an exit, or at a `bad` line (returned as the needle with seconds None)."""
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            text = self.log_text()
            for needle in needles:
                if needle in text:
                    return needle, round(self.elapsed(), 3)
            for needle in bad:
                if needle in text:
                    return needle, None
            if self.child.poll() is not None:
                return None
            time.sleep(0.05)
        return None

    def stop(self):
        subprocess.run(
            [self.binary, "server", "stop", "--session", self.args.session, "--end-terminals",
             "--socket", self.socket],
            env=self.env, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL, timeout=600, check=False,
        )
        try:
            self.child.wait(timeout=600)
        except subprocess.TimeoutExpired:
            self.child.kill()
            self.child.wait()
        self.log.close()
        return self.child.returncode

    def kill9(self):
        os.kill(self.child.pid, signal.SIGKILL)
        self.child.wait()
        self.log.close()


def request_line(owner, request, timeout=10.0):
    """One request line on the owner's socket: (reply or None, milliseconds or None)."""
    started = time.monotonic()
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
            conn.settimeout(timeout)
            conn.connect(owner.socket)
            conn.sendall(json.dumps(request).encode() + b"\n")
            data = b""
            while b"\n" not in data:
                chunk = conn.recv(1 << 20)
                if not chunk:
                    return None, None
                data += chunk
        reply = json.loads(data.split(b"\n", 1)[0])
    except (OSError, ValueError):
        return None, None
    return reply, round((time.monotonic() - started) * 1000, 2)


def cleanup_stats(owner):
    """The registry_cleanup section of server-stats: counts, sizes and one file NAME."""
    request = {"id": 2, "cmd": "server-stats", "include": ["registry_cleanup"]}
    reply, _ = request_line(owner, request, 60)
    section = ((reply or {}).get("data") or {}).get("registry_cleanup")
    if isinstance(section, dict) and "/" in str(section.get("error") or ""):
        section["error"] = "an error text with a path: not shown"
    return section


# The lock sites of the retention pass, the cleanup and the History fold (source file names).
LOCK_SITE_WORDS = ("journal_segment_retention", "journal_retention", "output_cleanup",
                   "journal_maintenance", "history_ops", "workspace_rename")


LOCK_SITE_LIST = 20  # diagnostics.rs DETAIL_SITES


def lock_sites(owner):
    """The registry lock of this owner since its start (server-stats `locks`): the hold
    histogram, and by site (a source file and line, no data) the acquisitions and the hold
    times in microseconds, for the sites of LOCK_SITE_WORDS and the 3 longest holds."""
    request = {"id": 3, "cmd": "server-stats", "include": ["locks"]}
    reply, _ = request_line(owner, request, 60)
    registry = (((reply or {}).get("data") or {}).get("locks") or {}).get("registry")
    if not isinstance(registry, dict):
        return None
    sites = {}
    for name, value in registry.items():
        if isinstance(value, list):
            for row in value:
                if isinstance(row, dict) and "site" in row:
                    # The source file under src/ and the line: no path of the build host.
                    row = {**row, "site": str(row["site"]).rsplit("/src/", 1)[-1]}
                    sites[row["site"]] = row
    longest = sorted(sites.values(), key=lambda row: -int(row.get("hold_max_us") or 0))[:3]
    ours = [row for row in sites.values()
            if any(word in str(row["site"]) for word in LOCK_SITE_WORDS)]
    ours.sort(key=lambda row: -int(row.get("hold_max_us") or 0))
    seen = registry.get("sites")
    # The daemon gives 2 lists of at most 20 sites each (by hold total, by hold p99): with more
    # sites seen, a site that is in neither list is ABSENT here, and that proves no "no hold".
    cut = isinstance(seen, int) and not isinstance(seen, bool) and seen > LOCK_SITE_LIST
    return {"hold_us": registry.get("hold_us"), "stalls": registry.get("stalls"),
            "sites_seen": seen, "site_lists_cut": cut, "longest_holds": longest,
            "retention_sites": ours}


def wal_stats(owner):
    """The registry WAL of this owner since its start (server-stats `write_path`): the commits,
    the bytes of the WAL frames that they appended, the size of the WAL file now and the
    largest size that the owner saw. None when the owner gives no such section."""
    request = {"id": 4, "cmd": "server-stats", "include": ["write_path"]}
    reply, _ = request_line(owner, request, 60)
    section = ((reply or {}).get("data") or {}).get("write_path")
    if not isinstance(section, dict):
        return None
    return {key: section.get(key) for key in (
        "wal_commits", "registry_wal_frame_bytes", "registry_wal_file_bytes",
        "registry_wal_file_high_water_bytes")}


def cpu_seconds(text):
    """ps cputime: M:SS.ss (macOS), HH:MM:SS or D-HH:MM:SS (Linux)."""
    days, _, rest = text.rpartition("-")
    total = 0.0
    for part in rest.split(":"):
        total = total * 60 + float(part)
    return total + (int(days) * 86400 if days else 0)


def first_workspace(owner):
    """The id of the first workspace in the owner's tree (None: the tree was not read)."""
    reply, _ = request_line(owner, {"id": 3, "cmd": "list-workspaces"}, 120)
    for workspace in ((reply or {}).get("data") or {}).get("workspaces") or []:
        if isinstance(workspace, dict) and "id" in workspace:
            return workspace["id"]
    return None


def spread(times):
    """p50, p95, p99 and max of a list of milliseconds."""
    times = sorted(times)

    def pick(share):
        return times[min(len(times) - 1, int(len(times) * share))] if times else None

    return {"n": len(times), "p50": pick(0.5), "p95": pick(0.95), "p99": pick(0.99),
            "max": times[-1] if times else None}


class Sampler(threading.Thread):
    """While an owner runs, each `period` seconds: its resident memory and CPU time (ps, the
    whole process) and the time of one identify request on its socket. Each `write_every`
    samples also one rename-workspace request: a request that commits to the registry (the
    name of the first workspace goes between two values; no count of the proof changes)."""

    def __init__(self, owner, period=0.5, write_every=10):
        super().__init__(daemon=True)
        self.owner, self.period, self.rows, self.done = owner, period, [], threading.Event()
        self.write_every = write_every
        self.workspace = first_workspace(owner) if write_every else None

    def run(self):
        pid = str(self.owner.child.pid)
        count = 0
        while not self.done.wait(self.period):
            at = self.owner.elapsed()
            try:
                out = subprocess.run(["ps", "-o", "rss=", "-o", "cputime=", "-p", pid],
                                     capture_output=True, text=True, timeout=10).stdout.split()
                row = {"at": at, "rss": int(out[0]), "cpu": cpu_seconds(out[1])}
            except (OSError, subprocess.SubprocessError, ValueError, IndexError):
                continue
            _, row["identify_ms"] = request_line(self.owner, {"id": 1, "cmd": "identify"}, 30)
            count += 1
            if self.workspace is not None and count % self.write_every == 0:
                request = {"id": 4, "cmd": "rename-workspace", "workspace": self.workspace,
                           "name": f"rmp-{count // self.write_every % 2}"}
                reply, ms = request_line(self.owner, request, 60)
                row["write"] = ms if reply is not None and reply.get("ok") is True else "refused"
                if reply is None:
                    row["write"] = "no answer"
            self.rows.append(row)

    def stop(self):
        self.done.set()
        self.join(timeout=90)

    def phase(self, start, end):
        """The samples from `start` to `end` (seconds from spawn; None: no such phase)."""
        if start is None or end is None:
            return None
        rows = [row for row in self.rows if start <= row["at"] < end]
        if len(rows) < 2:
            return {"samples": len(rows)}
        wall = rows[-1]["at"] - rows[0]["at"]
        cpu = rows[-1]["cpu"] - rows[0]["cpu"]
        writes = [row["write"] for row in rows if "write" in row]
        identify = spread([row["identify_ms"] for row in rows if row["identify_ms"] is not None])
        identify["no_answer"] = sum(1 for row in rows if row["identify_ms"] is None)
        rename = spread([value for value in writes if not isinstance(value, str)])
        rename["refused"] = writes.count("refused")
        rename["no_answer"] = writes.count("no answer")
        return {"samples": len(rows), "seconds": round(wall, 1),
                "peak_rss_mb": round(max(row["rss"] for row in rows) / 1024, 1),
                "cpu_s": round(cpu, 2),
                "cpu_share_of_one_core": round(cpu / wall, 3) if wall > 0 else None,
                "identify_ms": identify, "rename_workspace_ms": rename}


class SegmentWatch(threading.Thread):
    """Each `period` seconds: the count of sealed segments in the registry file and the end of
    the oldest one, by a read-only connection of this script (no request to the owner). An
    oldest end that moves is a delete in place."""

    def __init__(self, registry, period=0.1):
        super().__init__(daemon=True)
        self.registry, self.period, self.rows, self.done = registry, period, [], threading.Event()

    def run(self):
        try:
            connection = sqlite3.connect(Path(self.registry).as_uri() + "?mode=ro", uri=True,
                                         timeout=5, check_same_thread=False)
        except sqlite3.Error:
            return
        while not self.done.wait(self.period):
            try:
                count, oldest = connection.execute(
                    "SELECT COUNT(*), MIN(end_sequence) FROM journal_segments").fetchone()
            except sqlite3.Error:
                continue
            self.rows.append((time.monotonic(), count, oldest))
        connection.close()

    def stop(self):
        self.done.set()
        self.join(timeout=30)

    def last_delete(self):
        """The time of the last read that saw a delete (None: no delete so far)."""
        rows = list(self.rows)
        seen = [now[0] for before, now in zip(rows, rows[1:]) if now[2] != before[2]]
        return seen[-1] if seen else None

    def passes(self, gap=5.0):
        """Each retention pass that deleted: [start, end, segments]. A pass is a run of reads
        that saw a delete, with less than `gap` seconds between two of them; it starts at the
        read before the first one."""
        rows, found = list(self.rows), []
        for before, now in zip(rows, rows[1:]):
            if now[2] == before[2]:
                continue
            if found and before[0] - found[-1][1] < gap:
                found[-1][1], found[-1][3] = now[0], now[1]
            else:
                found.append([before[0], now[0], before[1], now[1]])
        return [[start, end, first - last] for start, end, first, last in found]


class PassProbe(threading.Thread):
    """While an owner runs, with `gap` seconds between two rounds: one identify request and
    one rename-workspace request (a request that commits to the registry), each with its
    start time. It is what a request of the person waits. Each rename adds a journal record
    (at most 5 each second: about one more sealed segment in 200 s)."""

    def __init__(self, owner, gap=0.2):
        super().__init__(daemon=True)
        self.owner, self.gap, self.rows, self.done = owner, gap, [], threading.Event()
        self.workspace = first_workspace(owner)

    def run(self):
        count = 0
        while not self.done.wait(self.gap):
            started = time.monotonic()
            _, ms = request_line(self.owner, {"id": 1, "cmd": "identify"}, 30)
            self.rows.append(("identify_ms", started, ms))
            if self.workspace is None:
                continue
            count += 1
            request = {"id": 4, "cmd": "rename-workspace", "workspace": self.workspace,
                       "name": f"rmp-{count % 2}"}
            started = time.monotonic()
            reply, ms = request_line(self.owner, request, 60)
            answered = reply is not None and reply.get("ok") is True
            self.rows.append(("rename_workspace_ms", started, ms if answered else None))

    def stop(self):
        self.done.set()
        self.join(timeout=90)

    def split(self, passes, margin):
        """The request times in two groups: a request that ran while a pass deleted (its time
        from start to answer meets a pass, each pass wider by `margin` seconds on both sides),
        and each other request. A request with no answer is counted, not timed."""
        groups = {"during_a_pass": {}, "with_no_pass": {}}
        for kind, started, ms in list(self.rows):
            ended = started + (ms or 0) / 1000
            met = any(started <= end + margin and ended >= start - margin
                      for start, end, _ in passes)
            group = groups["during_a_pass" if met else "with_no_pass"]
            times, missing = group.setdefault(kind, ([], [0]))
            if ms is None:
                missing[0] += 1
            else:
                times.append(ms)
        return {name: {kind: {**spread(times), "no_answer_or_refused": missing[0]}
                       for kind, (times, missing) in group.items()}
                for name, group in groups.items()}


# history_ops.rs MAX_LIST: the most rows one history.entries.list request returns.
HISTORY_LIST_LIMIT = 5000
# How many times `served` asks while the History fold is not at the head (3 s apart).
SERVED_TRIES = 200


SAMPLE_TOOL = "/usr/bin/sample"
STACK_CHUNK_SECONDS = 30
STACK_LINE = re.compile(r"^([ +!:|]*)(\d+) (.*)$")
# The holds of the delete of one segment (the registry lock is held from the first line of each
# to its commit): the base and the floor, the rows of at most 256 records, the segment row with
# its content. And the pass around them when the compiler put a hold inside the pass.
STACK_FRAMES = ("begin_journal_segment_prune", "delete_pruned_segment_rows",
                "finish_journal_segment_prune")
STACK_OUTER = "retain_journal"
# A release build puts the holds AND the pass into the maintenance loop: then the statements
# of the loop with no step of its own between (a step that is a function of its own has a
# cmux_tui frame there) are counted, and the wait for WAL room between two holds (no lock
# held) is named apart. The 3 holds are among those statements; other steps that the compiler
# put inside the loop are too, so the frame name in the result says which form was read.
STACK_LOOP = "run_journal_maintenance"
STACK_LOOP_NAME = re.compile(r"::run_journal_maintenance(::h[0-9a-f]{16})?$")
STACK_WAL_ROOM = ("wal_room_for_retention", "after_retention_hold")
# The pass's reads before a hold, on its own connection with no lock held
# (`RetentionReadAhead`, whose 3 reads are never inlined so that a sample names them): they
# are counted apart and are never a part of a hold.
STACK_READ_AHEAD = ("read_ahead::RetentionReadAhead",)
STACK_FOLD = ("fold_for_retention", "history_ops")
STACK_LOCK_WAIT = ("psynch_mutexwait", "pthread_mutex_lock", "pthread_mutex_firstfit")
# Where a sample is, by the names on its stack below the delete: the first group that matches.
STACK_GROUPS = (
    ("waits_for_another_writer", ("BusyCallback", "BusyHandler", "sqlite3OsSleep", "unixSleep",
                                  "usleep", "nanosleep", "__semwait_signal")),
    ("file_sync", ("unixSync", "full_fsync", "fsync")),
    ("file_lock_call", ("unixShmLock", "unixLock", "unixUnlock", "posixUnlock", "walLock",
                        "unixFileLock")),
    ("file_write", ("unixWrite", "seekAndWrite", "pwrite")),
    ("file_read", ("unixRead", "seekAndRead", "pread")),
    ("fcntl_sync_or_file_lock", ("fcntl",)),
)
# Parts of the delete by a name anywhere on the stack (a sample can be in several). A name that
# the compiler put inside another function is absent: 0 here proves nothing.
STACK_MARKS = {
    "save_reducer_bases": ("save_reducer_bases",),
    "json_of_the_states": ("jsonParse", "jsonExtract", "jsonValid", "json_valid", "json_extract"),
    "begin_write": ("sqlite3BtreeBeginTrans", "sqlite3PagerBegin",
                    "sqlite3WalBeginWriteTransaction"),
    "row_delete": ("sqlite3BtreeDelete",),
    "freed_or_overflow_pages": ("clearCell", "freePage"),
    "commit": ("sqlite3VdbeHalt", "sqlite3BtreeCommit", "sqlite3PagerCommitPhaseOne",
               "pagerWalFrames", "sqlite3WalFrames", "walFrames"),
    "checkpoint": ("sqlite3Checkpoint", "walCheckpoint", "sqlite3WalCheckpoint"),
    # A seek into an index b-tree for a row that a DELETE takes, and a page read under it:
    # the row holds of a large file are this (about 2.5 page reads for each subject row).
    "index_seek": ("sqlite3BtreeIndexMoveto",),
    "page_read_from_the_file": ("readDbPage",),
    "page_cache_spill_to_the_wal": ("pagerStress",),
    "schema_read": ("sqlite3InitOne", "sqlite3ReadSchema", "sqlite3InitCallback"),
    "trigger_drop_or_create": ("sqlite3DropTrigger", "sqlite3BeginTrigger",
                               "sqlite3FinishTrigger", "sqlite3NestedParse"),
}


def stack_shares(texts):
    """The samples of `sample` call graphs that are inside the delete of one segment, by group.
    A sample is counted where its stack ends (a node's count less the counts of its callees).
    Symbol names only: no path, no address, no data."""
    groups, marks, tops, by_hold = {}, {}, {}, {}
    inside_total = lock_wait = wal_room_wait = read_ahead = 0
    read_ahead_groups = {}
    frames = set()
    # With a hold as a function of its own in one stack, only those stacks count; a stack of
    # the pass outside them is another lock hold (the floor read), the wait for the WAL
    # syncer's look (no lock held) or no hold.
    own_frame = any(frame in text for text in texts for frame in STACK_FRAMES)
    outer_frame = own_frame or any(STACK_OUTER in text for text in texts)
    for text in texts:
        graph = text.split("Call graph:", 1)[-1].split("Total number in stack", 1)[0]
        nodes, path = [], []
        for line in graph.splitlines():
            found = STACK_LINE.match(line)
            if not found:
                continue
            depth, count = len(found.group(1)), int(found.group(2))
            symbol = found.group(3).split("  (in ", 1)[0].strip()
            while path and nodes[path[-1]][0] >= depth:
                path.pop()
            if path:
                nodes[path[-1]][3] += count
            nodes.append([depth, count, symbol, 0, list(path)])
            path.append(len(nodes) - 1)
        for _, count, symbol, below, chain in nodes:
            own = count - below
            if own <= 0:
                continue
            names = [nodes[index][2] for index in chain] + [symbol]
            if any(word in name for name in names for word in STACK_READ_AHEAD):
                read_ahead += own
                group = next((key for key, words in STACK_GROUPS
                              if any(word in name for name in names for word in words)),
                             "runs_in_the_process")
                read_ahead_groups[group] = read_ahead_groups.get(group, 0) + own
                continue
            start = next((i for i, name in enumerate(names)
                          if any(frame in name for frame in STACK_FRAMES)), None)
            frame = None
            if start is not None:
                frame = next(frame for frame in STACK_FRAMES if frame in names[start])
                by_hold[frame] = by_hold.get(frame, 0) + own
            else:
                start = next((i for i, name in enumerate(names) if STACK_OUTER in name), None)
                frame = STACK_OUTER + " (the delete is inside it: the fold is left out)"
                if start is None and not outer_frame:
                    start = next((i for i in range(len(names) - 1, -1, -1)
                                  if STACK_LOOP_NAME.search(names[i])), None)
                    frame = STACK_LOOP + (" (the pass and the holds are inside it: its statements"
                                          " with no step of its own between)")
                    if start is not None:
                        below = names[start + 1:]
                        if any(word in name for name in below for word in STACK_WAL_ROOM):
                            wal_room_wait += own
                            continue
                        if not below or "cmux_tui" in below[0]:
                            continue
                if start is None:
                    continue
                inside = names[start + 1:]
                if any(word in name for name in inside for word in STACK_FOLD):
                    continue
                if any(word in name for name in inside for word in STACK_LOCK_WAIT):
                    lock_wait += own
                    continue
                if own_frame:
                    continue
            inside = names[start:]
            frames.add(frame)
            inside_total += own
            group = next((key for key, words in STACK_GROUPS
                          if any(word in name for name in inside for word in words)),
                         "runs_in_the_process")
            groups[group] = groups.get(group, 0) + own
            for key, words in STACK_MARKS.items():
                if any(word in name for name in inside for word in words):
                    marks[key] = marks.get(key, 0) + own
            top = re.sub(r"::h[0-9a-f]{16}$", "", symbol)[:90]
            tops[top] = tops.get(top, 0) + own
    share = {key: round(value / inside_total, 3) for key, value in groups.items()}
    return {"frame": sorted(frames), "samples_in_the_delete": inside_total,
            "samples_by_hold": by_hold,
            "by_group": groups, "share": share, "by_part_not_exclusive": marks,
            "pass_waits_for_a_lock_outside_the_delete": lock_wait,
            "pass_waits_for_wal_room_between_two_holds": wal_room_wait,
            "pass_reads_before_a_hold_with_no_lock": {"samples": read_ahead,
                                                      "by_group": read_ahead_groups},
            "top_of_stack_first_12": sorted(tops.items(), key=lambda row: -row[1])[:12]}


class StackSampler(threading.Thread):
    """/usr/bin/sample on the owner in chunks of 30 s, until stop(). The files of `sample` are
    read and removed: only the counts and the symbol names of stack_shares() are kept."""

    def __init__(self, owner, interval_ms):
        super().__init__(daemon=True)
        self.owner, self.interval_ms = owner, max(1, int(interval_ms))
        self.done = threading.Event()
        self.texts, self.errors = [], []
        self.sampled_s = 0.0

    def run(self):
        if not os.path.exists(SAMPLE_TOOL):
            self.errors.append("no " + SAMPLE_TOOL + " on this host")
            return
        index = 0
        while not self.done.is_set() and self.owner.child.poll() is None:
            path = Path(self.owner.home) / f"stacks-{index}.txt"
            began = time.monotonic()
            try:
                out = subprocess.run(
                    [SAMPLE_TOOL, str(self.owner.child.pid), str(STACK_CHUNK_SECONDS),
                     str(self.interval_ms), "-file", str(path)],
                    stdin=subprocess.DEVNULL, capture_output=True, text=True,
                    timeout=STACK_CHUNK_SECONDS + 600, check=False)
                note = (out.stderr or out.stdout or "").strip().splitlines()[-1:]
            except subprocess.TimeoutExpired:
                note = ["sample did not end"]
            if not path.exists():
                self.errors.append("no sample file: " + " ".join(note)[:200])
                return
            self.texts.append(path.read_text(errors="replace"))
            path.unlink()
            self.sampled_s += min(STACK_CHUNK_SECONDS, time.monotonic() - began)
            index += 1

    def stop(self):
        self.done.set()
        self.join()

    def result(self):
        value = stack_shares(self.texts)
        value.update(interval_ms=self.interval_ms, chunks=len(self.texts),
                     sampled_s=round(self.sampled_s, 1))
        if self.errors:
            value["errors"] = self.errors
        return value


def ask(owner, operation, params):
    """One request to the owner's socket: its reply. Raises OSError or ValueError."""
    request = {"protocol": "cmux.protocol/2", "type": "request", "id": "rmp-" + operation,
               "operation": operation, "params": params}
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
        conn.settimeout(120)
        conn.connect(owner.socket)
        conn.sendall(json.dumps(request).encode() + b"\n")
        data = b""
        while b"\n" not in data:
            chunk = conn.recv(1 << 20)
            if not chunk:
                break
            data += chunk
    return json.loads(data.split(b"\n", 1)[0])


def digest(names):
    """A one-way mark of a list of ids of GENERATED data: one row lost and one gained changes
    it while the count stays. It is no content."""
    return hashlib.sha256("\n".join(sorted(names)).encode()).hexdigest()[:16]


def refusal(reply):
    """The error of a reply: its code, and its text with each absolute path cut out (the data
    is generated; a path would name the host's folders)."""
    error = reply.get("error") or {}

    def cut(text):
        return re.sub(r"(?<![\w.])/[\w.\-]+(?:/[\w.\-]+)+", "<path>", text)

    value = {"error": str(error.get("code")), "message": cut(str(error.get("message") or ""))[:400]}
    details = error.get("details")
    # A refusal by the catalog names the contract and the violation (a catalog path such as
    # "history.entries.list.result" and field NAMES): which rule the answer broke.
    if isinstance(details, dict) and "contract" in details:
        kept = {key: details.get(key) for key in ("contract", "violation_code", "violation")}
        value["violation"] = cut(json.dumps(kept, sort_keys=True))[:400]
    return value


def served_roster(owner):
    """The agent roster the owner SERVES (agent.list): a count and a mark, or the error."""
    try:
        reply = ask(owner, "agent.list", {"machine": "current", "session": "current"})
    except (OSError, ValueError) as error:
        return {"error": type(error).__name__}
    if reply.get("ok") is not True:
        return refusal(reply)
    # The result is the array of AgentSnapshot (id, terminal_id, source_session, ...).
    agents = reply.get("result")
    if not isinstance(agents, list):
        return {"error": "the result is not a list"}
    rows = [agent for agent in agents if isinstance(agent, dict)]
    names = [f"{agent.get('id')}/{agent.get('terminal_id')}/{agent.get('source_session')}"
             for agent in rows]
    # A row with no `id` adds nothing to the mark: the mark is then weaker than it reads.
    return {"agents": len(agents), "ids_sha256": digest(names),
            "rows_with_no_id": sum(1 for agent in rows if not agent.get("id")) + len(agents)
            - len(rows)}


# The longest time `served` asks again after a refusal (3 s apart). The daemon refuses its own
# answer while the History fold is more than its 2 s budget behind the head (the answer then
# has a field that the catalog type does not name), so a large journal refuses for a time.
REFUSED_SECONDS = 300


def served(owner):
    """What the owner SERVES: the agent sessions of history.entries.list (the list of the app's
    History, vault and resume) and the agent roster of agent.list, asked over the socket.
    `pending` = the History fold was not at the head after the last try."""
    params = {"machine": "current", "session": "current", "kinds": ["agent"],
              "limit": HISTORY_LIST_LIMIT}
    # A refusal is asked again (3 s apart): "one time" and "each time" are not the same fault.
    refused, refused_at = [], None
    for attempt in range(SERVED_TRIES):
        try:
            reply = ask(owner, "history.entries.list", params)
        except (OSError, ValueError) as error:
            return {"error": type(error).__name__}
        if reply.get("ok") is not True:
            refused.append(refusal(reply))
            if refused_at is None:
                refused_at = time.monotonic()
            if time.monotonic() - refused_at >= REFUSED_SECONDS:
                return {**refused[0], "refused_times": len(refused),
                        "refused_s": round(time.monotonic() - refused_at, 1),
                        "last_message": refused[-1]["message"]}
            time.sleep(3)
            continue
        result = reply.get("result") or {}
        pending = bool(result.get("pending_kinds"))
        if not pending or attempt == SERVED_TRIES - 1:
            entries = [entry for entry in result.get("entries") or [] if isinstance(entry, dict)]
            listed = len(entries)
            # At the limit the list is one page: the count then proves only "at least".
            value = {"agent_sessions": listed, "pending": pending,
                     "one_page_only": listed >= HISTORY_LIST_LIMIT,
                     "ids_sha256": digest(str(entry.get("id")) for entry in entries),
                     "roster": served_roster(owner)}
            if refused:
                # `seconds`: from the first refusal to this answer.
                value["refused_first"] = {**refused[0], "times": len(refused),
                                          "seconds": round(time.monotonic() - refused_at, 1)}
            return value
        time.sleep(3)
    return {"error": "no answer"}


def served_mark(value):
    """What must be equal between two answers of history.entries.list."""
    return [value.get("agent_sessions"), value.get("ids_sha256")]


def served_lost(steps):
    """The starts of the main arm whose served agent sessions (the count and the mark of the
    ids) differ from start 1's. A control step before them is an older build's answer."""
    marks = [(step["arm"], served_mark(step.get("served") or {})) for step in steps
             if "served" in step and step["arm"].startswith("main-")]
    if not marks:
        return {}
    first = marks[0][1]
    return {arm: [first, mark] for arm, mark in marks[1:] if mark != first}


def head_served(steps):
    """Each answer of the HEAD build to `served`, by a name. In a step of an older build
    (`after_old`, or `untouched` in the raised arm) `served` and `served_after_dwell` are that
    build's answers: only the head build's start after it counts here."""
    found = {}
    for step in steps:
        arm = step["arm"]
        if "after_old" in step:
            if isinstance(step.get("new_after_old_served"), dict):
                found[arm + "-then-new"] = step["new_after_old_served"]
            if isinstance(step.get("new_after_old_served_2"), dict):
                found[arm + "-then-new-2"] = step["new_after_old_served_2"]
            continue
        if "untouched" in step:
            continue
        if isinstance(step.get("served"), dict):
            found[arm] = step["served"]
        for key, value in step.items():
            if isinstance(value, dict) and isinstance(value.get("served"), dict):
                found[f"{arm}.{key}"] = value["served"]
    return found


def registry_of(state):
    return drs.session_dir(str(state)) / REGISTRY


def counts(args, state):
    registry = registry_of(state)
    out = subprocess.run([args.synth, "--counts", str(registry)], stdin=subprocess.DEVNULL,
                         capture_output=True, text=True, timeout=3600, check=True).stdout
    value = json.loads(out.strip().splitlines()[-1])
    sdir = registry.parent
    value["staging_bytes"] = drs.file_size(sdir / STAGING)
    value["backup_bytes"] = drs.file_size(sdir / PREVIOUS)
    value["kept_bytes"] = drs.file_size(sdir / KEPT)
    value["folder_bytes"] = sum(f.stat().st_size for f in sdir.iterdir() if f.is_file())
    return value


def roster_of(value):
    return {key: value.get(key) for key in ROSTER_KEYS}


def bases_of(value):
    return {key: value.get(key) for key in BASE_KEYS}


def compare(before, after):
    """The keys that differ (empty: nothing lost)."""
    lost = {key: [before.get(key), after.get(key)] for key in EQUAL_KEYS
            if before.get(key) != after.get(key)}
    if int(after.get("journal_head", 0)) < int(before.get("journal_head", 0)):
        lost["journal_head"] = [before.get("journal_head"), after.get("journal_head")]
    return lost


def clone(source, target):
    """An APFS clone of a state dir (no extra disk until a file changes); a copy elsewhere."""
    flags = ["-cR"] if sys.platform == "darwin" else ["-R", "--reflink=auto"]
    subprocess.run(["cp", *flags, str(source), str(target)], check=True)
    return target


def swap_line(owner):
    line = owner.log_line("output cleanup: swapped the registry in")
    # Without the path at its end.
    return None if line is None else line.split("; previous file")[0].split("output cleanup: ")[1]


# A first pass, or a pass that goes on with the staging file of a killed owner.
STAGING_LINES = ["output cleanup: staging ", "output cleanup: resuming after sequence"]
BAD_BUILD = ("output cleanup: not enough free space", "output cleanup: staging failed")
SKIPPED = "output cleanup: skipped, the registry"
BUILT = "built the new registry in the background in"


def staging_passes(text):
    return sum(text.count(line) for line in STAGING_LINES)


def wait_built(owner, timeout):
    """The build line: ("built", seconds from spawn). A registry of the long-lived shape is
    first refused by the one-time pass without a floor (it would keep most of the journal:
    one "skipped" line); the owner then waits for the retention floor and stages again. A
    second "skipped" line ends the worker: (reason, None). None at the timeout or an exit."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        text = owner.log_text()
        if BUILT in text:
            return "built", round(owner.elapsed(), 3)
        for bad in BAD_BUILD:
            if bad in text:
                return bad, None
        if text.count(SKIPPED) >= 2:
            return "skipped two times", None
        if owner.child.poll() is not None:
            return None
        time.sleep(0.1)
    return None


def cleanup_lines(owner):
    """The cleanup's log lines of this owner, without the ones that hold a path."""
    return [line.split("output cleanup: ")[1][:200] for line in owner.log_text().splitlines()
            if "output cleanup: " in line and "/" not in line]


def build(args, state, label, timeout=None):
    """Start 1 on `state`: ready, then the new registry built beside the file. Stops the owner."""
    timeout = timeout or args.build_timeout
    owner = Owner(args, state, label)
    ready = owner.wait_ready()
    result = {"arm": label, "ready_s": ready, "load_1m": os.getloadavg()[0]}
    if ready is None:
        result["error"] = "not ready"
        owner.stop()
        return result
    sampler = Sampler(owner)
    sampler.start()
    staging = owner.wait_log(STAGING_LINES, timeout, BAD_BUILD)
    result["staging_started_s"] = None if staging is None else staging[1]
    built = None
    if staging is not None and staging[1] is not None:
        built = wait_built(owner, timeout)
    result["built_s"] = None if built is None else built[1]
    text = owner.log_text()
    result["skipped_passes"] = text.count(SKIPPED)
    result["cleanup_lines"] = cleanup_lines(owner)[-8:]
    if built is None or built[1] is None:
        result["error"] = "no build" if built is None else "no build: " + built[0]
    else:
        # A few seconds more: the samples after the build, on the same owner.
        time.sleep(args.after_built)
    sampler.stop()
    end = owner.elapsed()
    result["samples"] = {
        "ready_to_staging": sampler.phase(ready, result["staging_started_s"]),
        "while_it_builds": sampler.phase(result["staging_started_s"], result["built_s"]),
        "after_the_build": sampler.phase(result["built_s"], end),
    }
    result["cleanup_stats"] = cleanup_stats(owner)
    result["locks"] = lock_sites(owner)
    result["served"] = served(owner)
    result["exit"] = owner.stop()
    return result


# The longest time the first-fold arm asks for a complete list.
FIRST_FOLD_SECONDS = 1800


def first_fold_arm(args, state, report):
    """The first fold of the agent History on a clone from before start 1: the head owner is
    asked for the agent list from its ready on, until an answer names no pending kind. The
    first ask starts the daemon's feed thread, which folds to the head; each ask also folds
    for at most the daemon's own 2 s. Its counts are not compared: it is not a step of the
    migration (the owner stops before the cleanup worker starts, 60 s after a start, unless
    the fold is longer than that)."""
    owner = Owner(args, state, "first-fold")
    ready = owner.wait_ready()
    step = {"arm": "first-fold", "ready_s": ready, "load_1m": os.getloadavg()[0]}
    if ready is None:
        step["error"] = "not ready"
    else:
        params = {"machine": "current", "session": "current", "kinds": ["agent"],
                  "limit": HISTORY_LIST_LIMIT}
        began = time.monotonic()
        asks, not_complete, first, slowest = 0, 0, None, 0.0
        while True:
            asked = time.monotonic()
            try:
                reply = ask(owner, "history.entries.list", params)
            except (OSError, ValueError) as error:
                step["error"] = type(error).__name__
                break
            now = time.monotonic()
            asks += 1
            slowest = max(slowest, now - asked)
            if reply.get("ok") is not True:
                step["error"] = "refused"
                step["refusal"] = refusal(reply)
                break
            result = reply.get("result") or {}
            listed = len([entry for entry in result.get("entries") or []
                          if isinstance(entry, dict)])
            if first is None:
                first = listed
            if not result.get("pending_kinds"):
                step["complete_s"] = round(now - began, 1)
                step["agent_sessions"] = listed
                break
            not_complete += 1
            if now - began >= FIRST_FOLD_SECONDS:
                step["error"] = "the fold was not at the head"
                step["agent_sessions_at_the_end"] = listed
                break
            time.sleep(1)
        step.update(asks=asks, answers_not_complete=not_complete,
                    agent_sessions_first_answer=first, slowest_ask_s=round(slowest, 2),
                    owner_ran_s=round(owner.elapsed(), 1))
    step["exit"] = owner.stop()
    say("RMP", step)
    report["steps"].append(step)


def start_stop(args, state, label, binary=None, ask=True):
    owner = Owner(args, state, label, binary=binary)
    ready = owner.wait_ready()
    result = {"arm": label, "ready_s": ready, "swap": swap_line(owner),
              "load_1m": os.getloadavg()[0]}
    if ready is None:
        lines = owner.log_text().splitlines()
        result["error"] = "not ready"
        result["last_line"] = (lines[-1] if lines else "")[:200]
    elif ask:
        result["served"] = served(owner)
        result["cleanup_stats"] = cleanup_stats(owner)
    result["exit"] = owner.stop()
    return result


def main_arm(args, state, before, report):
    step = build(args, state, "main-start1")
    say("RMP", step)
    report["steps"].append(step)
    if "error" in step:
        return False
    staged = counts(args, state)
    say("RMP-COUNTS", {"at": "built", **staged})
    # The generated History fold is behind the head (as on his Mac). The first start folds to
    # the head before it deletes a record, so the count to keep is the one at the head, read
    # here: the registry still has every record and no pruned range. (The count of records
    # can be higher: each rename of the sampler adds journal records.)
    if (staged["records"] >= before["records"]
            and staged["pruned_ranges"] == before["pruned_ranges"]
            and staged["retention_floor"] == before["retention_floor"]
            and int(staged.get("history_cursor") or 0) > int(before.get("history_cursor") or 0)):
        say("RMP", {"arm": "history-base", "fold_behind_the_head": before["history_sessions"],
                    "fold_at_the_head_before_a_delete": staged["history_sessions"],
                    "cursor": [before.get("history_cursor"), staged.get("history_cursor")]})
        report["history_sessions_fold_behind_the_head"] = before["history_sessions"]
        before["history_sessions"] = staged["history_sessions"]
    for name in ("kill-swap", "kill-renamed"):
        if name in args.arms:
            clone(state, Path(args.scratch) / name)
    step = start_stop(args, state, "main-start2")
    after = counts(args, state)
    step.update(lost=compare(before, after), swapped=step["swap"] is not None)
    say("RMP", step)
    say("RMP-COUNTS", {"at": "swapped", **after})
    report["steps"].append(step)
    report["after_swap"] = after
    step = start_stop(args, state, "main-start3")
    final = counts(args, state)
    step.update(lost=compare(before, final), rollback_name_bytes=final["backup_bytes"],
                kept_name_bytes=final["kept_bytes"])
    say("RMP", step)
    report["steps"].append(step)
    step = start_stop(args, state, "main-start4")
    final = counts(args, state)
    step.update(lost=compare(before, final), rollback_name_bytes=final["backup_bytes"],
                kept_name_bytes=final["kept_bytes"])
    say("RMP", step)
    say("RMP-COUNTS", {"at": "final", **final})
    report["steps"].append(step)
    report["final"] = final
    report["served_lost"] = served_lost(report["steps"])
    say("RMP", {"arm": "main-served", "differs": report["served_lost"],
                "served": [[item["arm"], item.get("served")] for item in report["steps"]]})
    return True


def kill_stage_arm(args, state, before, report):
    """kill -9 in the pass that builds: the main arm says how many passes are skipped first."""
    skipped = next((step.get("skipped_passes", 0) for step in report["steps"]
                    if step["arm"] == "main-start1"), 0)
    owner = Owner(args, state, "kill-stage-a")
    owner.wait_ready()
    deadline = time.monotonic() + args.build_timeout
    seen = False
    while time.monotonic() < deadline and owner.child.poll() is None:
        text = owner.log_text()
        if staging_passes(text) > skipped or any(bad in text for bad in BAD_BUILD):
            seen = staging_passes(text) > skipped
            break
        time.sleep(0.02)
    staging = registry_of(state).parent / STAGING
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline and drs.file_size(staging) < 1 << 20:
        time.sleep(0.002)
    step = {"arm": "kill-stage", "point": "while the owner stages at the floor",
            "staging_seen": seen, "passes_skipped_before": skipped,
            "built_before_the_kill": BUILT in owner.log_text(),
            "staging_bytes_at_kill": drs.file_size(staging)}
    owner.kill9()
    step["after_kill"] = build(args, state, "kill-stage-b")
    step["swap_start"] = start_stop(args, state, "kill-stage-c")
    after = counts(args, state)
    step.update(lost=compare(before, after), swapped=step["swap_start"]["swap"] is not None)
    say("RMP", step)
    report["steps"].append(step)


def kill_at_file_arm(args, state, before, report, name):
    """kill-swap: at the first change of the staging file in the start that swaps (the swap's
    transaction writes it). kill-renamed: when the backup file exists (after the rename)."""
    sdir = registry_of(state).parent
    staging, previous, registry = sdir / STAGING, sdir / PREVIOUS, sdir / REGISTRY
    watched = [staging, Path(str(staging) + "-wal"), Path(str(staging) + "-journal")]

    def stamp():
        marks = []
        for path in watched:
            try:
                stat = path.stat()
                marks.append((stat.st_size, stat.st_mtime_ns))
            except OSError:
                marks.append(None)
        return marks

    first = stamp()
    registry_before = (drs.file_size(registry), registry.stat().st_ino)
    owner = Owner(args, state, name + "-a")
    deadline = time.monotonic() + args.ready_timeout
    hit = False
    polls = 0
    ready_without_the_point = False
    while time.monotonic() < deadline and owner.child.poll() is None:
        if name == "kill-renamed":
            hit = previous.exists()
        else:
            hit = stamp() != first or previous.exists()
        if hit:
            break
        polls += 1
        # A start that is ready did not swap: the point does not come in this start.
        if polls % 1000 == 0 and os.path.exists(owner.socket):
            reply = drs.identify(owner.socket, 2.0)
            if reply is not None and (reply.get("data") or {}).get("lifecycle_ready") is True:
                ready_without_the_point = True
                break
        time.sleep(0.0005)
    at_kill = {"backup_exists": previous.exists(), "staging_exists": staging.exists(),
               "registry_is_the_old_file": (drs.file_size(registry), registry.stat().st_ino)
               == registry_before if registry.exists() else None,
               "registry_exists": registry.exists(), "ms_from_spawn": round(owner.elapsed() * 1000, 1)}
    owner.kill9()
    step = {"arm": name, "point_hit": hit, "at_kill": at_kill}
    if ready_without_the_point:
        step["error"] = "the start got ready with no swap: the kill was after it, not in the swap"
    step["restart"] = start_stop(args, state, name + "-b")
    after = counts(args, state)
    step.update(lost=compare(before, after), after_restart={
        "backup_bytes": after["backup_bytes"], "staging_bytes": after["staging_bytes"],
        "registry_bytes": after["registry_bytes"], "retention_floor": after["retention_floor"]})
    step["second_restart"] = start_stop(args, state, name + "-c")
    step["lost_after_second"] = compare(before, counts(args, state))
    say("RMP", step)
    report["steps"].append(step)


def space_arm(args, state, before, report):
    env = {"CMUX_TUI_TEST_OUTPUT_CLEANUP_DELAY_MS": "0",
           "CMUX_TUI_TEST_JOURNAL_MAINTENANCE_INTERVAL_MS": "500",
           "CMUX_TUI_TEST_OUTPUT_CLEANUP_MARGIN_BYTES": str(1 << 60)}
    owner = Owner(args, state, "space", binary=args.debug_bin, env=env)
    ready = owner.wait_ready()
    seen = owner.wait_log(["output cleanup: not enough free space"], args.build_timeout,
                          ("output cleanup: staging ",))
    staging = registry_of(state).parent / STAGING
    step = {"arm": "space", "ready_s": ready,
            "refused": seen is not None and seen[1] is not None,
            "staging_file": staging.exists()}
    if step["refused"] and args.space_dwell > 0:
        # After the refusal no rebuild can run: the retention pass deletes in place. A DEBUG
        # owner with a pass each 0.5 s: the lock times are a debug build's, not the product's.
        deadline = time.monotonic() + args.space_dwell
        while time.monotonic() < deadline and owner.child.poll() is None:
            time.sleep(1)
        step["dwell_s"] = args.space_dwell
        step["locks_debug_build"] = lock_sites(owner)
    step["exit"] = owner.stop()
    # This folder is a copy from before start 1. Its History fold is where the generator left
    # it, or at the head when this start folded: each of the two counts is "nothing lost".
    after = counts(args, state)
    lost = compare(before, after)
    if lost and not compare(report["before_start_1"], after):
        lost = {}
    step["lost"] = lost
    say("RMP", step)
    report["steps"].append(step)


IN_PLACE_KEYS = ("registry_bytes", "wal_bytes", "freelist_pages", "records", "segments",
                 "pruned_ranges", "retention_floor", "journal_head", "history_cursor",
                 "roster_cursor")
NO_REBUILD = "output cleanup: no rebuild in this start"
# The owner's line at ticks 1, 2, 4, 8, ... of a start that began no hold of the delete because
# the registry WAL had no room (journal_segment_retention.rs).
NO_WAL_ROOM = "journal retention: no hold in "


def no_wal_room_lines(owner):
    """Those lines of the owner, the last 4: each names a count, 2 sizes and no path."""
    return [line.strip()[:300] for line in owner.log_text().splitlines()
            if NO_WAL_ROOM in line][-4:]
# The in-place-kept arm ends when no read saw a delete for this long (a pass each 30 s).
KEPT_QUIET_SECONDS = 75
# A failure by TIME, not a loss: no retention pass deleted in the dwell (a slow fold, floor 0).
NO_DELETE_IN_DWELL = "no segment was deleted in place in the dwell"


def in_place_arm(args, state, before, report, name="in-place"):
    """The delete in place at this size, by a RELEASE owner that starts no rebuild. THIS SCRIPT
    writes an empty file with the kept name beside the registry of a clone from before start 1:
    the product then starts no cleanup worker (`backup_held`), and each retention pass (30 s
    apart) deletes 8 sealed segments in place, from the oldest: the packed sparse segments and
    the pruned ranges inside them. A person gets the same deletes when a rebuild is refused
    (no free space: only a debug owner has that seam, the space arm). The numbers: the registry
    lock by site, and the times of the sampler's requests (one rename-workspace each second:
    a request that commits to the registry) from ready to the end of the dwell."""
    sdir = registry_of(state).parent
    (sdir / KEPT).touch()
    start = counts(args, state)
    owner = Owner(args, state, name)
    ready = owner.wait_ready()
    step = {"arm": name, "ready_s": ready, "load_1m": os.getloadavg()[0],
            "dwell_s": args.in_place_dwell,
            "before": {key: start.get(key) for key in IN_PLACE_KEYS}}
    if ready is None:
        step["error"] = "not ready"
        step["exit"] = owner.stop()
        say("RMP", step)
        report["steps"].append(step)
        return
    stacks = StackSampler(owner, args.stack_ms) if name.endswith("-stacks") else None
    sampler = Sampler(owner, write_every=2)
    sampler.start()
    if stacks:
        stacks.start()
    deadline = time.monotonic() + args.in_place_dwell
    while time.monotonic() < deadline and owner.child.poll() is None:
        time.sleep(1)
    sampler.stop()
    step["samples"] = sampler.phase(ready, owner.elapsed())
    step["locks"] = lock_sites(owner)
    step["wal"] = wal_stats(owner)
    if stacks:
        stacks.stop()
        step["stacks"] = stacks.result()
    step["no_rebuild_line"] = NO_REBUILD in owner.log_text()
    step["no_wal_room_lines"] = no_wal_room_lines(owner)
    # In the verdict as each other answer of the head build: `served` waits for the History
    # fold at the head (the retention pass folds before it deletes).
    step["served"] = served(owner)
    step["exit"] = owner.stop()
    after = counts(args, state)
    step["after"] = {key: after.get(key) for key in IN_PLACE_KEYS}
    step["segments_deleted"] = int(start.get("segments") or 0) - int(after.get("segments") or 0)
    step["kept_name_bytes"] = after["kept_bytes"]
    # As in the space arm: this folder is a copy from before start 1.
    lost = compare(before, after)
    if lost and not compare(report["before_start_1"], after):
        lost = {}
    step["lost"] = lost
    if not step["no_rebuild_line"]:
        step["error"] = "the owner did not say that it starts no rebuild"
    elif step["segments_deleted"] <= 0:
        step["error"] = NO_DELETE_IN_DWELL
    say("RMP", step)
    report["steps"].append(step)


# The 4 tables with a row for each record of a sealed segment (journal_retention.rs
# PRUNED_ROW_TABLES), and the meta key of the sequence that retention deleted through.
PRUNED_ROW_TABLES = (("journal_segment_reducer_records", "sequence"),
                     ("journal_subject_index", "sequence"),
                     ("journal_event_index", "sequence"),
                     ("journal_ingress_receipts", "journal_sequence"))
PRUNED_THROUGH = "SELECT CAST(value AS INTEGER) FROM meta WHERE key = 'journal_retention_floor'"


class HoldWatch:
    """A read-only connection of this script to the registry file: counts only, each read its
    own short transaction (no request to the owner, no snapshot that stays)."""

    def __init__(self, registry):
        self.connection = sqlite3.connect(Path(registry).as_uri() + "?mode=ro", uri=True,
                                          timeout=5)

    def rows_through(self, end):
        """The rows of records at or below `end`, by table."""
        return {table: self.connection.execute(
            f"SELECT COUNT(*) FROM {table} WHERE {column} <= ?", (end,)).fetchone()[0]
                for table, column in PRUNED_ROW_TABLES}

    def read(self):
        """(deleted through, the end of the oldest sealed segment, the rows at or below that
        end by table). None when the file gave no answer (a schema change in progress)."""
        try:
            row = self.connection.execute(PRUNED_THROUGH).fetchone()
            through = int(row[0]) if row and row[0] is not None else 0
            end = self.connection.execute(
                "SELECT MIN(end_sequence) FROM journal_segments").fetchone()[0]
            return through, end, ({} if end is None else self.rows_through(end))
        except sqlite3.Error:
            return None

    def segments_through(self, end):
        """Sealed segments that end at or below `end` (None: no answer)."""
        try:
            return self.connection.execute(
                "SELECT COUNT(*) FROM journal_segments WHERE end_sequence <= ?",
                (end,)).fetchone()[0]
        except sqlite3.Error:
            return None

    def close(self):
        self.connection.close()


def kill_hold_arm(args, state, before, report):
    """kill -9 BETWEEN TWO HOLDS of the delete of one segment. The delete in place takes the
    registry lock one time for the base and the floor, one time for the rows of each 256
    records, and one time for the segment row with its content. Between two holds the segment
    is PART-DELETED: its row and content are there, the floor is at its end, a part of its
    rows is gone. As the in-place arm, a RELEASE owner on a clone from before start 1 with an
    empty file of the kept name (no rebuild in this start). This script reads counts from the
    file each few milliseconds and kills the owner when the oldest sealed segment is at or
    below the floor with fewer rows than it had and more than 0. Then a second start: the
    backfill of kept reducer rows runs before the pass and can write rows of that segment
    again; the pass takes the segment again and ends its delete. The proof: the segment and
    each row at or below its end are gone, and the counts and the served answer are equal."""
    name = "kill-hold"
    sdir = registry_of(state).parent
    (sdir / KEPT).touch()
    start = counts(args, state)
    owner = Owner(args, state, name + "-a")
    ready = owner.wait_ready()
    step = {"arm": name, "ready_s": ready, "load_1m": os.getloadavg()[0],
            "before": {key: start.get(key) for key in IN_PLACE_KEYS}}

    def end_with(error, running=None):
        step["error"] = error
        if running is not None:
            step["exit"] = running.stop()
        say("RMP", step)
        report["steps"].append(step)

    if ready is None:
        return end_with("not ready", owner)
    watch = HoldWatch(registry_of(state))
    most, hit, reads = {}, None, 0
    deadline = time.monotonic() + max(args.in_place_dwell, 120)
    while time.monotonic() < deadline and owner.child.poll() is None:
        seen = watch.read()
        reads += 1
        if seen is None or seen[1] is None:
            time.sleep(0.005)
            continue
        through, end, rows = seen
        total = sum(rows.values())
        most[end] = max(most.get(end, 0), total)
        if through >= end and 0 < total < most[end]:
            owner.kill9()
            owner.child.wait()
            hit = end
            break
        time.sleep(0.002)
    step["reads_before_the_kill"] = reads
    if hit is None:
        watch.close()
        return end_with("no part-deleted segment was seen in the dwell",
                        owner if owner.child.poll() is None else None)
    # The owner is dead: this read is the state that the next start finds.
    at_kill = watch.read()
    through, end, rows = at_kill if at_kill is not None else (None, None, {})
    left = sum(rows.values())
    step["at_kill"] = {"segment_end": hit, "deleted_through": through,
                       "the_segment_row_is_there": end == hit,
                       "rows_before_its_delete": most[hit], "rows_at_the_kill": rows,
                       "killed_at_s": round(owner.elapsed(), 1)}
    step["point_hit"] = bool(end == hit and through is not None and through >= hit
                             and 0 < left < most[hit])
    second = Owner(args, state, name + "-b")
    ready = second.wait_ready()
    step["after_restart"] = {"ready_s": ready}
    if ready is None:
        watch.close()
        return end_with("not ready after the kill", second)
    # Until the pass of this start ended the delete: the segment is gone with each row at or
    # below its end. The most rows seen on the way: more than at the kill = the backfill wrote
    # rows of the part-deleted segment again before the pass took it.
    most_after, gone_s, rows_left = left, None, None
    deadline = time.monotonic() + max(args.in_place_dwell, 120)
    while time.monotonic() < deadline and second.child.poll() is None:
        try:
            now = watch.rows_through(hit)
        except sqlite3.Error:
            time.sleep(0.01)
            continue
        most_after = max(most_after, sum(now.values()))
        if watch.segments_through(hit) == 0 and sum(now.values()) == 0:
            gone_s, rows_left = round(second.elapsed(), 1), now
            break
        rows_left = now
        time.sleep(0.01)
    watch.close()
    step["after_restart"].update(
        the_segment_was_gone_at_s=gone_s, rows_at_or_below_its_end=rows_left,
        most_rows_seen_after_the_start=most_after,
        rows_written_again_before_the_pass=most_after > left)
    step["locks"] = lock_sites(second)
    step["wal"] = wal_stats(second)
    step["no_rebuild_line"] = NO_REBUILD in second.log_text()
    step["no_wal_room_lines"] = no_wal_room_lines(second)
    step["served"] = served(second)
    step["exit"] = second.stop()
    after = counts(args, state)
    step["after"] = {key: after.get(key) for key in IN_PLACE_KEYS}
    # As in the space arm: this folder is a copy from before start 1.
    lost = compare(before, after)
    if lost and not compare(report["before_start_1"], after):
        lost = {}
    step["lost"] = lost
    if not step["point_hit"]:
        step["error"] = "the kill was not between two holds of one segment's delete"
    elif gone_s is None:
        step["error"] = "the start after the kill did not end the delete of the segment"
    say("RMP", step)
    report["steps"].append(step)


def in_place_kept_arm(args, state, before, report, name="in-place-kept"):
    """The delete in place as a person gets it each day: on the SMALL registry after the swap,
    with the kept file of the real swap beside it (the product then starts no rebuild for 7
    days and 3 full starts). synth_registry --advance-checkpoints appends --second-records
    records, moves the checkpoints to the head, seals every record and back-dates the segments
    (what days of use do); nothing else is of this script. A RELEASE owner then deletes 8
    sealed segments in each retention pass (30 s apart), until 75 s pass with no delete or
    --kept-dwell seconds are over. The numbers: the registry lock by site; how many passes
    deleted, with the seconds and the segments of each; and the times of identify and
    rename-workspace requests that a probe sends back to back, in two groups: a request that
    ran while a pass deleted, and each other request (the same owner, the same file). Its
    answer to `served` is in the verdict: the appended kind changes no agent and no session,
    and this is the arm that deletes in place on the migrated file."""
    start = counts(args, state)
    step = {"arm": name, "kept_name_bytes": start.get("kept_bytes"),
            "first_name_bytes": start.get("backup_bytes")}
    if not (start.get("kept_bytes") or start.get("backup_bytes")):
        step["error"] = "no file of the swap is held: this state is not the one after a swap"
        say("RMP", step)
        report["steps"].append(step)
        return
    records = args.kept_records or args.second_records
    dwell = args.kept_dwell or args.in_place_dwell
    step.update(dwell_s=dwell, appended_records=records)
    out = subprocess.run(
        [args.synth, "--advance-checkpoints", "16", "--append-records",
         str(records), "--out", str(state), "--session", args.session,
         "--seal-age-minutes", str(args.seal_age_minutes), "--quiet"],
        stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=3600, check=False)
    if out.returncode != 0:
        step["error"] = "synth_registry --advance-checkpoints failed: " + out.stderr[-300:]
        say("RMP", step)
        report["steps"].append(step)
        return
    step["advanced"] = json.loads(out.stdout.strip().splitlines()[-1])
    advanced = counts(args, state)
    step["lost_by_the_advance"] = compare(before, advanced)
    step["before"] = {key: advanced.get(key) for key in IN_PLACE_KEYS}
    owner = Owner(args, state, name)
    ready = owner.wait_ready()
    step.update(ready_s=ready, load_1m=os.getloadavg()[0])
    if ready is None:
        step["error"] = "not ready"
        step["exit"] = owner.stop()
        say("RMP", step)
        report["steps"].append(step)
        return
    # Memory and CPU by the sampler (it sends no rename here); the request times by the probe.
    # The nowatch and quiet arms: no read of the registry file by this script while the owner
    # runs (a reader of the file can hold the WAL at its size); quiet: no probe request either.
    watched = not name.endswith(("-nowatch", "-quiet"))
    sampler = Sampler(owner, write_every=0)
    probe = None if name.endswith("-quiet") else PassProbe(owner)
    watch = SegmentWatch(registry_of(state)) if watched else None
    stacks = StackSampler(owner, args.stack_ms) if name.endswith("-stacks") else None
    threads = [thread for thread in (watch, sampler, probe, stacks) if thread is not None]
    for thread in threads:
        thread.start()
    began = time.monotonic()
    deadline = began + dwell
    step["ended_by"] = "the dwell"
    step["reads_the_file_while_the_owner_runs"] = watched
    while time.monotonic() < deadline and owner.child.poll() is None:
        time.sleep(1)
        last = watch.last_delete() if watch else None
        # 2 passes with no delete (they are 30 s apart): no segment is left at the floor.
        if last is not None and time.monotonic() - last > KEPT_QUIET_SECONDS:
            step["ended_by"] = f"no delete for {KEPT_QUIET_SECONDS} s"
            break
    for thread in (probe, sampler, watch):
        if thread is not None:
            thread.stop()
    passes = watch.passes() if watch else []
    step["samples"] = sampler.phase(ready, owner.elapsed())
    step["ran_s"] = round(time.monotonic() - began, 1)
    if watch:
        step["passes"] = len(passes)
        step["pass_rows_first_40"] = [
            {"at_s": round(start - began, 1), "seconds": round(end - start, 2),
             "segments": segments}
            for start, end, segments in passes[:40]]
        step["watch_period_s"] = watch.period
    if probe:
        step["probe_requests"] = len(probe.rows)
        # With no watch no pass is known: each request is then in the group "with_no_pass".
        step["requests"] = probe.split(passes, watch.period if watch else 0.1)
    step["locks"] = lock_sites(owner)
    step["wal"] = wal_stats(owner)
    if stacks:
        stacks.stop()
        step["stacks"] = stacks.result()
    step["no_rebuild_line"] = NO_REBUILD in owner.log_text()
    step["no_wal_room_lines"] = no_wal_room_lines(owner)
    # The appended kind changes no agent and no session (synth_sparse.rs), so this answer must
    # equal start 1's: it is in the verdict as each other answer of the head build.
    step["served"] = served(owner)
    step["exit"] = owner.stop()
    after = counts(args, state)
    step["after"] = {key: after.get(key) for key in IN_PLACE_KEYS}
    step["segments_deleted"] = (int(advanced.get("segments") or 0)
                                - int(after.get("segments") or 0))
    step["lost"] = compare(before, after)
    if not step["no_rebuild_line"]:
        step["error"] = "the owner did not say that it starts no rebuild"
    elif step["segments_deleted"] <= 0:
        step["error"] = NO_DELETE_IN_DWELL
    say("RMP", step)
    report["steps"].append(step)


def base_sample_arm(args, state, report):
    """The control of the lock rows: a build with NONE of this change (--base-bin) as the owner
    of a clone from before start 1, with the same sampler as the in-place arm (one
    rename-workspace each second) for the same dwell. It deletes nothing and builds nothing,
    so its lock holds and request times are what the size of the file and the host cost
    alone. Its counts are not compared: it is not a step of the migration."""
    owner = Owner(args, state, "base-sample", binary=args.base_bin)
    ready = owner.wait_ready()
    step = {"arm": "base-sample", "ready_s": ready, "load_1m": os.getloadavg()[0],
            "dwell_s": args.in_place_dwell}
    if ready is None:
        step["base_error"] = "not ready"
    else:
        sampler = Sampler(owner, write_every=2)
        sampler.start()
        deadline = time.monotonic() + args.in_place_dwell
        while time.monotonic() < deadline and owner.child.poll() is None:
            time.sleep(1)
        sampler.stop()
        step["samples"] = sampler.phase(ready, owner.elapsed())
        step["locks"] = lock_sites(owner)
        step["wal"] = wal_stats(owner)
        # That build's own answer: not an answer of the head build, so no verdict rule reads it.
        step["base_served"] = served(owner)
    step["exit"] = owner.stop()
    say("RMP", step)
    report["steps"].append(step)


def base_kept_arm(args, state, report):
    """The control of the in-place-kept arms: a build with NONE of this change (--base-bin) as
    the owner of a clone of the SMALL registry after the swap, with the same appended records
    and the same probe (one identify and one rename-workspace back to back, PassProbe) for the
    same dwell. That build has no retention pass, so its WAL numbers and request times are what
    the probe's own requests cost on that file: the bytes of one rename, and how large the WAL
    file gets with no delete in place. Its counts are not compared (not a step of the
    migration), and no verdict rule reads its answer."""
    records = args.kept_records or args.second_records
    dwell = args.kept_dwell or args.in_place_dwell
    step = {"arm": "base-kept", "dwell_s": dwell, "appended_records": records}
    out = subprocess.run(
        [args.synth, "--advance-checkpoints", "16", "--append-records",
         str(records), "--out", str(state), "--session", args.session,
         "--seal-age-minutes", str(args.seal_age_minutes), "--quiet"],
        stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=3600, check=False)
    if out.returncode != 0:
        step["base_error"] = "synth_registry --advance-checkpoints failed: " + out.stderr[-300:]
        say("RMP", step)
        report["steps"].append(step)
        return
    advanced = counts(args, state)
    step["before"] = {key: advanced.get(key) for key in IN_PLACE_KEYS}
    owner = Owner(args, state, "base-kept", binary=args.base_bin)
    ready = owner.wait_ready()
    step.update(ready_s=ready, load_1m=os.getloadavg()[0])
    if ready is None:
        step["base_error"] = "not ready"
    else:
        sampler = Sampler(owner, write_every=0)
        probe = PassProbe(owner)
        for thread in (sampler, probe):
            thread.start()
        began = time.monotonic()
        deadline = began + dwell
        while time.monotonic() < deadline and owner.child.poll() is None:
            time.sleep(1)
        for thread in (probe, sampler):
            thread.stop()
        step["samples"] = sampler.phase(ready, owner.elapsed())
        step["ran_s"] = round(time.monotonic() - began, 1)
        step["probe_requests"] = len(probe.rows)
        step["requests"] = probe.split([], 0.1)
        step["locks"] = lock_sites(owner)
        step["wal"] = wal_stats(owner)
        step["base_served"] = served(owner)
    step["exit"] = owner.stop()
    after = counts(args, state)
    step["after"] = {key: after.get(key) for key in IN_PLACE_KEYS}
    say("RMP", step)
    report["steps"].append(step)


# Owner log lines that say what an older owner did with the state (no row contents).
OLD_LOG_WORDS = ("schema", "roster", "snapshot", "quarantin", "recover", "registry", "reducer")


def log_lines(owner, limit=12):
    lines = [line for line in owner.log_text().splitlines()
             if any(word in line.lower() for word in OLD_LOG_WORDS)]
    return [line[:300] for line in lines[:limit]]


def old_arm(args, state, before, report, label, binary, migrated=True):
    """An older owner on `state`, until it saved its own roster (or --old-dwell seconds), then
    the head build again. `migrated` False: the control, on the state before the migration."""
    start = counts(args, state)
    owner = Owner(args, state, label, binary=binary)
    ready = owner.wait_ready()
    step = {"arm": label, "ready_s": ready, "opens": ready is not None,
            "load_1m": os.getloadavg()[0], "at_start": roster_of(start)}
    if ready is None:
        lines = owner.log_text().splitlines()
        step["last_line"] = (lines[-1] if lines else "")[:200]
    else:
        step["served"] = served(owner)
        # A reducer of another version rebuilds and saves after the owner is ready: the saved
        # roster then has that build's version.
        deadline = time.monotonic() + args.old_dwell
        step["saved_its_roster_s"] = None
        while time.monotonic() < deadline and owner.child.poll() is None:
            try:
                now = roster_of(counts(args, state))
            except (subprocess.SubprocessError, ValueError, IndexError):
                # The owner writes: one read that fails is read again.
                time.sleep(2)
                continue
            if now["roster_version"] != start.get("roster_version"):
                step["saved_its_roster_s"] = round(owner.elapsed(), 1)
                time.sleep(min(10, args.old_dwell))
                break
            time.sleep(min(5, args.old_dwell))
        step["served_after_dwell"] = served(owner)
    step["exit"] = owner.stop()
    step["log_lines"] = log_lines(owner)
    after = counts(args, state)
    step["after_old"] = roster_of(after)
    step["lost"] = compare(before, after)
    if migrated:
        # Older builds keep the key: the two base rows are the bytes the swap wrote.
        step["bases_after_old"] = bases_of(after)
        step["bases_equal_after_old"] = bases_of(after) == bases_of(report["after_swap"])
    again = start_stop(args, state, label + "-then-new")
    final = counts(args, state)
    step["new_after_old_ready_s"] = again["ready_s"]
    step["new_after_old_served"] = again.get("served")
    step["after_new"] = roster_of(final)
    step["lost_after_new"] = compare(before, final)
    # A second start of the head build: does it answer as the first one did?
    second = start_stop(args, state, label + "-then-new-2")
    step["new_after_old_served_2"] = second.get("served")
    if migrated:
        step["bases_equal_after_new"] = bases_of(final) == bases_of(report["after_swap"])
        control = next((item for item in report["steps"]
                        if item["arm"] == label.replace("old-", "control-", 1)), None)
        if control is not None:
            keys = ("roster_agents", "roster_rested")
            step["roster_of_the_old_build"] = {
                "before_the_migration": {key: control["after_old"].get(key) for key in keys},
                "after_the_migration": {key: step["after_old"].get(key) for key in keys},
                "served_before": (control.get("served_after_dwell") or {}).get("agent_sessions"),
                "served_after": (step.get("served_after_dwell") or {}).get("agent_sessions"),
            }
            step["same_as_control"] = all(
                control["after_old"].get(key) == step["after_old"].get(key) for key in keys)
    say("RMP", step)
    report["steps"].append(step)


def second_swap_arm(args, state, before, report):
    """A second rebuild and swap of the migrated registry. The owner rebuilds again only when no
    file of the last swap is held and 100,000 records are at or below a new floor. THIS SCRIPT
    removes the kept file (the product does it after 7 days and 3 full starts), and
    synth_registry --advance-checkpoints appends --second-records terminal.progress records,
    writes new checkpoints at the head by owners, seals every record and back-dates the segments
    (what days of use do). The rest is the product."""
    sdir = registry_of(state).parent
    removed = {}
    for name in (PREVIOUS, KEPT):
        for suffix in ("", "-wal", "-shm"):
            path = sdir / (name + suffix)
            if path.is_file():
                removed[name + suffix] = path.stat().st_size
                path.unlink()
    start = counts(args, state)
    out = subprocess.run(
        [args.synth, "--advance-checkpoints", "16", "--append-records",
         str(args.second_records), "--out", str(state), "--session", args.session,
         "--seal-age-minutes", str(args.seal_age_minutes), "--quiet"],
        stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=3600, check=False)
    step = {"arm": "second-swap", "removed_by_this_script": removed,
            "before": {key: start.get(key) for key in
                       ("registry_bytes", "records", "segments", "retention_floor",
                        "journal_head", "checkpoints")}}
    if out.returncode != 0:
        step["error"] = "synth_registry --advance-checkpoints failed: " + out.stderr[-300:]
        say("RMP", step)
        report["steps"].append(step)
        return
    step["advanced"] = json.loads(out.stdout.strip().splitlines()[-1])
    step["lost_by_the_advance"] = compare(before, counts(args, state))
    step["build"] = build(args, state, "second-swap-a", timeout=args.second_build_timeout)
    step["swap_start"] = start_stop(args, state, "second-swap-b")
    after = counts(args, state)
    step["after"] = {key: after.get(key) for key in
                     ("registry_bytes", "records", "segments", "retention_floor",
                      "journal_head", "checkpoints", "backup_bytes", "kept_bytes")}
    step.update(lost=compare(before, after), swapped=step["swap_start"]["swap"] is not None,
                bases_after=bases_of(after))
    if "error" in step["build"]:
        step["error"] = "no second build: " + step["build"]["error"]
    elif not step["swapped"]:
        step["error"] = "the second start did not swap"
    step["third_start"] = start_stop(args, state, "second-swap-c")
    step["lost_after_third"] = compare(before, counts(args, state))
    say("RMP", step)
    report["steps"].append(step)


def manifest(state):
    """Each file under the state dir: [bytes, SHA-256]. Names are relative: no host path."""
    files = {}
    root = Path(state)
    for path in sorted(root.rglob("*")):
        if path.is_file() and not path.is_symlink():
            digest = hashlib.sha256()
            with open(path, "rb") as handle:
                for block in iter(lambda: handle.read(1 << 22), b""):
                    digest.update(block)
            files[str(path.relative_to(root))] = [path.stat().st_size, digest.hexdigest()]
        elif not path.is_dir():
            files[str(path.relative_to(root))] = ["not a regular file", ""]
    return files


def raised_arm(args, state, report, label, binary):
    """An older owner on a state whose schema_version this script raised by one."""
    registry = registry_of(state)
    connection = sqlite3.connect(str(registry))
    try:
        stored = int(connection.execute(
            "SELECT value FROM meta WHERE key = 'schema_version'").fetchone()[0])
        connection.execute("UPDATE meta SET value = ? WHERE key = 'schema_version'",
                           (str(stored + 1),))
        connection.commit()
    finally:
        connection.close()
    before = manifest(state)
    owner = Owner(args, state, label, binary=binary)
    ready = owner.wait_ready(timeout=args.refusal_timeout)
    step = {"arm": label, "schema_version": [stored, stored + 1], "ready_s": ready,
            "opens": ready is not None, "files_before": len(before)}
    if ready is not None:
        step["served"] = served(owner)
        step["exit"] = owner.stop()
    else:
        try:
            step["exit"] = owner.child.wait(timeout=args.refusal_timeout)
            owner.log.close()
        except subprocess.TimeoutExpired:
            step["still_running_at_s"] = round(owner.elapsed(), 1)
            owner.kill9()
            step["exit"] = "killed by this script"
    step["log_lines"] = [line[:400] for line in owner.log_text().splitlines()[:14]]
    after = manifest(state)
    step["changed"] = {name: [before[name], after[name]] for name in before
                       if name in after and before[name] != after[name]}
    step["removed"] = [name for name in before if name not in after]
    step["added"] = {name: after[name] for name in after if name not in before}
    step["untouched"] = not (step["changed"] or step["removed"] or step["added"])
    say("RMP", step)
    report["steps"].append(step)


def table(report):
    before, after, final = report["before"], report.get("after_swap"), report.get("final")
    steps = {step["arm"]: step for step in report["steps"]}
    gb = lambda value: "-" if value is None else f"{value / 1e9:.3f} GB"  # noqa: E731
    rows = [("registry before", gb(before["registry_bytes"]) + f", {before['records']} records, "
             f"{before['segments']} segments, {before['workspaces']} workspaces"),
            ("a plain start changed", json.dumps(steps.get("plain-start", {})
                                                 .get("changed_by_a_plain_start")))]
    one = steps.get("main-start1", {})
    rows.append(("start 1: ready / first staging starts / built", f"{one.get('ready_s')} s / "
                 f"{one.get('staging_started_s')} s / {one.get('built_s')} s "
                 f"(load {one.get('load_1m', 0):.1f}; {one.get('error', 'ok')}; passes skipped "
                 f"first: {one.get('skipped_passes')})"))
    rows.append(("start 1: the cleanup's lines", json.dumps(one.get("cleanup_lines"))))
    rows.append(("start 1: the owner process (memory, CPU, identify request)",
                 json.dumps(one.get("samples"))))
    rows.append(("start 1: server-stats registry_cleanup", json.dumps(one.get("cleanup_stats"))))
    two = steps.get("main-start2", {})
    rows.append(("start 2: ready, the swap", f"{two.get('ready_s')} s; {two.get('swap')}"))
    if after:
        rows.append(("registry after the swap", gb(after["registry_bytes"]) + f", {after['records']} "
                     f"records, {after['segments']} segments, floor {after['retention_floor']}, "
                     f"backup {gb(after['backup_bytes'])}"))
        rows.append(("the two base rows after the swap", json.dumps(bases_of(after))))
        rows.append(("start 2: server-stats registry_cleanup",
                     json.dumps(two.get("cleanup_stats"))))
    if final:
        rows.append(("folder after 2 more starts", gb(final["folder_bytes"]) + ", the replaced "
                     f"file under its first name {gb(final['backup_bytes'])}, under its kept "
                     f"name {gb(final['kept_bytes'])}"))
        rows.append(("start 4: server-stats registry_cleanup",
                     json.dumps(steps.get("main-start4", {}).get("cleanup_stats"))))
    for key in EQUAL_KEYS:
        rows.append((f"{key} before / after the swap / final",
                     f"{before.get(key)} / {(after or {}).get(key)} / {(final or {}).get(key)}"))
    rows.append(("start 1: the registry lock by site while it waits and builds",
                 json.dumps(steps.get("main-start1", {}).get("locks"))))
    rows.append(("agent sessions the owner serves (history.entries.list): start 1 / 2 / 3 / 4",
                 " / ".join(str((steps.get(f"main-start{n}", {}).get("served") or {})
                                .get("agent_sessions")) for n in (1, 2, 3, 4))
                 + f"; differs: {json.dumps(report.get('served_lost', {}))}"))
    names = ["kill-stage", "kill-swap", "kill-renamed", "space", "in-place", "in-place-stacks",
             "kill-hold", "in-place-kept", "in-place-kept-stacks", "in-place-kept-nowatch",
             "in-place-kept-quiet", "base-sample", "base-kept", "second-swap"]
    names += [name for name in steps if name.startswith(("old", "control"))
              and not name.endswith("-new")]
    for name in names:
        step = steps.get(name)
        if step is not None:
            keep = {key: value for key, value in step.items()
                    if key in ("point", "point_hit", "at_kill", "lost", "lost_after_second",
                               "swapped", "refused", "staging_file", "opens", "lost_after_new",
                               "served", "ready_s", "last_line", "staging_seen",
                               "built_before_the_kill", "staging_bytes_at_kill",
                               "after_restart", "new_after_old_ready_s",
                               "served_after_dwell", "new_after_old_served",
                               "new_after_old_served_2", "log_lines",
                               "schema_version", "exit", "changed", "removed", "added",
                               "untouched", "still_running_at_s", "files_before",
                               "at_start", "after_old", "after_new", "saved_its_roster_s",
                               "bases_after_old", "bases_equal_after_old",
                               "bases_equal_after_new", "roster_of_the_old_build",
                               "same_as_control", "removed_by_this_script", "before", "after",
                               "advanced", "lost_by_the_advance", "lost_after_third",
                               "bases_after", "error", "dwell_s", "locks", "samples",
                               "locks_debug_build", "no_rebuild_line", "segments_deleted",
                               "kept_name_bytes", "base_served", "base_error",
                               "first_name_bytes", "load_1m",
                               "appended_records", "ended_by", "ran_s", "passes",
                               "pass_rows_first_40", "watch_period_s", "probe_requests",
                               "requests", "stacks", "wal",
                               "reads_the_file_while_the_owner_runs",
                               "no_wal_room_lines", "reads_before_the_kill")}
            if name == "second-swap":
                keep["build"] = {key: step.get("build", {}).get(key) for key in
                                 ("ready_s", "staging_started_s", "built_s", "cleanup_lines",
                                  "samples")}
                keep["swap"] = step.get("swap_start", {}).get("swap")
            rows.append((name, json.dumps(keep)))
    print("RMP-TABLE | item | result |")
    print("RMP-TABLE | --- | --- |")
    for item, result in rows:
        print(f"RMP-TABLE | {item} | {result} |")


def main():
    parser = argparse.ArgumentParser()
    for name in ("bin", "synth", "state", "home", "session", "socket-dir", "scratch", "report"):
        parser.add_argument("--" + name, required=True)
    parser.add_argument("--debug-bin", default="")
    # A cmux-tui with none of this change: the base-sample arm (left out without it).
    parser.add_argument("--base-bin", default="")
    parser.add_argument("--old-bin", default="")
    parser.add_argument("--arms",
                        default="control,main,kill-stage,kill-swap,kill-renamed,space,in-place,"
                                "in-place-kept,second-swap,old,old-raised")
    # The longest wait for an older owner to save its own roster.
    parser.add_argument("--old-dwell", type=float, default=45)
    parser.add_argument("--after-built", type=float, default=10)
    parser.add_argument("--second-build-timeout", type=float, default=1800)
    parser.add_argument("--second-records", type=int, default=200000)
    parser.add_argument("--seal-age-minutes", type=int, default=120)
    parser.add_argument("--refusal-timeout", type=float, default=90)
    # Seconds the space arm's debug owner runs on after the refusal (0: it stops at once).
    parser.add_argument("--space-dwell", type=float, default=0)
    # Seconds the in-place arm's owner runs after it is ready (a retention pass each 30 s).
    parser.add_argument("--in-place-dwell", type=float, default=150)
    # The in-place-kept arm: its longest run in seconds and the records the generator appends
    # first (0: --in-place-dwell and --second-records).
    parser.add_argument("--kept-dwell", type=float, default=0)
    parser.add_argument("--kept-records", type=int, default=0)
    # The in-place-stacks and in-place-kept-stacks arms: milliseconds between two stack samples.
    parser.add_argument("--stack-ms", type=int, default=10)
    parser.add_argument("--ready-timeout", type=float, default=3600)
    parser.add_argument("--build-timeout", type=float, default=7200)
    args = parser.parse_args()
    args.arms = [arm for arm in args.arms.split(",") if arm]
    if not args.debug_bin and "space" in args.arms:
        args.arms.remove("space")
    # --old-bin: "label=/abs/path,label=/abs/path" (a path alone gets the label oldN).
    olds = []
    for index, item in enumerate(part for part in args.old_bin.split(",") if part):
        label, _, path = item.rpartition("=")
        olds.append((label or f"old{index + 1}", path))
    for name in ("control", "old", "old-raised"):
        if not olds and name in args.arms:
            args.arms.remove(name)
    scratch = Path(args.scratch)
    generated = counts(args, args.state)
    say("RMP-COUNTS", {"at": "generated", **generated})
    # One plain start and stop first: what a start alone changes in a generated registry (its
    # agents are not real terminals) is not a result of the migration, so the counts "before"
    # are read after it. It stops when it is ready (the cleanup worker waits 60 s after a start),
    # and it does not ask for the History list (that waits for the fold).
    plain = start_stop(args, args.state, "plain-start", ask=False)
    before = counts(args, args.state)
    plain["changed_by_a_plain_start"] = compare(generated, before)
    say("RMP", plain)
    say("RMP-COUNTS", {"at": "before", **before})
    report = {"generated": generated, "before": before, "before_start_1": dict(before),
              "steps": [plain], "arms": args.arms,
              "host_load_1m": os.getloadavg()[0], "free_bytes": shutil.disk_usage(scratch).free}
    if before["backup_bytes"] or before["kept_bytes"] or plain["ready_s"] is None:
        plain["error"] = "the plain start swapped or did not get ready"
    # The control: each older build on the state as it is before the migration.
    for label, binary in olds:
        if "control" in args.arms:
            name = f"control-{label}"
            old_arm(args, clone(args.state, scratch / name), before, report, name, binary,
                    migrated=False)
            shutil.rmtree(scratch / name)
    if args.base_bin:
        args.arms.append("base-sample")
    for name in ("kill-stage", "space", "in-place", "in-place-stacks", "kill-hold",
                 "base-sample", "first-fold"):
        if name in args.arms:
            clone(args.state, scratch / name)
    if "main" not in args.arms:
        # The control arms only: the head build after an older build on a folder with no
        # migration. With bin= of a build that has none of this change, the run says what
        # that build does alone.
        Path(args.report).write_text(json.dumps(report, indent=1))
        answers = head_served(report["steps"])
        refused = {arm: value for arm, value in answers.items()
                   if "error" in value or "refused_first" in value}
        say("RMP-VERDICT", {"control_only": True,
                            "proves": "no migration: no start of this run swapped or deleted",
                            "head_served": answers,
                            "head_served_refused_in": refused})
        return 1 if refused else 0
    ok = main_arm(args, args.state, before, report)
    if "kill-stage" in args.arms:
        kill_stage_arm(args, scratch / "kill-stage", before, report)
    for name in ("kill-swap", "kill-renamed"):
        if name in args.arms and (scratch / name).is_dir():
            kill_at_file_arm(args, scratch / name, before, report, name)
    if "space" in args.arms:
        space_arm(args, scratch / "space", before, report)
    for name in ("in-place", "in-place-stacks"):
        if name in args.arms:
            in_place_arm(args, scratch / name, before, report, name)
            shutil.rmtree(scratch / name)
    if "kill-hold" in args.arms:
        kill_hold_arm(args, scratch / "kill-hold", before, report)
        shutil.rmtree(scratch / "kill-hold")
    if "base-sample" in args.arms:
        base_sample_arm(args, scratch / "base-sample", report)
        shutil.rmtree(scratch / "base-sample")
    if "first-fold" in args.arms:
        first_fold_arm(args, scratch / "first-fold", report)
        shutil.rmtree(scratch / "first-fold")
    for name in ("in-place-kept", "in-place-kept-stacks", "in-place-kept-nowatch",
                 "in-place-kept-quiet"):
        if name in args.arms and ok:
            in_place_kept_arm(args, clone(args.state, scratch / name), before, report, name)
            shutil.rmtree(scratch / name)
    if "base-kept" in args.arms and ok and args.base_bin:
        base_kept_arm(args, clone(args.state, scratch / "base-kept"), report)
        shutil.rmtree(scratch / "base-kept")
    if "second-swap" in args.arms and ok:
        second_swap_arm(args, clone(args.state, scratch / "second-swap"), before, report)
        shutil.rmtree(scratch / "second-swap")
    for label, binary in olds:
        if "old" in args.arms and ok:
            name = f"old-{label}"
            old_arm(args, clone(args.state, scratch / name), before, report, name, binary)
            shutil.rmtree(scratch / name)
        if "old-raised" in args.arms and ok:
            name = f"old-raised-{label}"
            raised_arm(args, clone(args.state, scratch / name), report, name, binary)
            shutil.rmtree(scratch / name)
    Path(args.report).write_text(json.dumps(report, indent=1))
    table(report)
    # A control step is the older build on the state BEFORE the migration: what differs
    # there is not a loss of the migration, so it is named apart.
    # An older build as the last writer saves ITS roster (a build before 2026-11-09 reads
    # no record below the floor): that is named apart too. The count that must hold is the
    # one after the head build opened the state again.
    def older(step):
        return "after_old" in step

    lost = [step["arm"] for step in report["steps"] if not step["arm"].startswith("control-")
            and ((step.get("lost") and not older(step)) or step.get("lost_after_second")
                 or step.get("lost_after_new") or step.get("lost_after_third"))]
    shows_less = {step["arm"]: step["lost"] for step in report["steps"]
                  if older(step) and step.get("lost") and not step["arm"].startswith("control-")}
    control = {step["arm"]: {"after_old": step.get("lost"), "after_new": step.get("lost_after_new")}
               for step in report["steps"] if step["arm"].startswith("control-")}
    bases_changed = [step["arm"] for step in report["steps"]
                     if step.get("bases_equal_after_old") is False]
    not_as_control = [step["arm"] for step in report["steps"]
                      if step.get("same_as_control") is False]
    failed = [step["arm"] for step in report["steps"] if "error" in step]
    # A raised schema_version that an older owner opens, or a folder it changed: not a count,
    # so it is named apart and does not change the exit code.
    not_clean = [step["arm"] for step in report["steps"]
                 if "untouched" in step and (step["opens"] or not step["untouched"])]
    if report.get("served_lost"):
        lost.append("served")
    unread = [step["arm"] for step in report["steps"] if "error" in (step.get("served") or {})]
    # The answers of the head build over the socket, in every arm. One that was not read, or
    # that was read while the History fold was not at the head, proves nothing: it fails the
    # run. One that differs from start 1 of the main arm is a loss, but for the control arms
    # (the state before the migration), which are named apart. The records that the generator
    # appends (second-swap, in-place-kept) change no agent and no session: those answers must
    # be equal too. A full page (5,000 rows) proves only "at least": it is named.
    answers = head_served(report["steps"])
    head_unread = sorted(arm for arm, value in answers.items() if "error" in value)
    head_pending = sorted(arm for arm, value in answers.items() if value.get("pending"))
    one_page = sorted(arm for arm, value in answers.items() if value.get("one_page_only"))
    first = answers.get("main-start1") or {}
    differs = {}
    if first and "error" not in first:
        differs = {arm: [served_mark(first), served_mark(value)]
                   for arm, value in answers.items()
                   if "error" not in value and not value.get("pending")
                   and served_mark(value) != served_mark(first)}
    apart = {arm: pair for arm, pair in differs.items()
             if arm.startswith("control-")}
    served_differs = {arm: pair for arm, pair in differs.items() if arm not in apart}
    rosters = {arm: value.get("roster") for arm, value in answers.items() if "roster" in value}
    # The served agent roster (agent.list), by count and mark, against start 1 of the main arm.
    def roster_mark(value):
        roster = (value or {}).get("roster") or {}
        return None if "error" in roster or "agents" not in roster else [
            roster["agents"], roster.get("ids_sha256")]

    roster_unread = sorted(arm for arm, value in answers.items()
                           if "error" not in value and roster_mark(value) is None)
    roster_differs, roster_apart = {}, {}
    if roster_mark(first) is not None:
        for arm, value in answers.items():
            mark = roster_mark(value)
            if mark is not None and mark != roster_mark(first):
                (roster_apart if arm.startswith("control-")
                 else roster_differs)[arm] = [roster_mark(first), mark]
    roster_void = bool(answers) and all(
        (roster_mark(value) or [1])[0] == 0 for value in answers.values())
    # Failures by time, not by a loss: the History fold was not at the head after the last try
    # (SERVED_TRIES, 3 s apart), or no retention pass deleted in the dwell of the in-place arm.
    by_time = sorted(set(head_pending) | {step["arm"] for step in report["steps"]
                                          if step.get("error") == NO_DELETE_IN_DWELL})
    say("RMP-VERDICT", {"lost_in": lost, "failed": failed, "served_not_read_in": unread,
                        "head_served_not_read_in": head_unread,
                        "head_served_with_the_fold_not_at_the_head_in": head_pending,
                        "head_served_differs_from_start_1_in": served_differs,
                        "head_served_differs_named_apart": apart,
                        "head_served_one_page_only_in": one_page,
                        "head_served_refused_before_it_answered_in": {
                            arm: value["refused_first"] for arm, value in answers.items()
                            if "refused_first" in value},
                        "head_served_roster": rosters,
                        "head_served_roster_not_read_in": roster_unread,
                        "head_served_roster_differs_from_start_1_in": roster_differs,
                        "head_served_roster_differs_named_apart": roster_apart,
                        # agent.list gives the agent rows of TERMINALS: a generated state has
                        # no terminal, so each answer is 0 rows and equal answers prove nothing.
                        "head_served_roster_void_0_rows_in_each_answer": roster_void,
                        "failed_by_time_not_by_a_loss_in": by_time,
                        "raised_not_clean_in": not_clean, "control": control,
                        "an_older_build_as_the_last_writer_shows_less": shows_less,
                        "bases_changed_by_an_older_build_in": bases_changed,
                        "older_build_not_as_its_control_in": not_as_control})
    # A full page proves only "at least": the run fails (this tool reads one page).
    bad = (lost or failed or bases_changed or head_unread or head_pending or served_differs
           or one_page or roster_unread or roster_differs)
    return 1 if bad or not ok else 0

if __name__ == "__main__":
    sys.exit(main())
