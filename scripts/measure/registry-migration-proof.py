#!/usr/bin/env python3
"""The migration proof of the registry rebuild at a retention floor, on a GENERATED registry
(scripts/measure/registry-migration-proof.sh builds the binaries and writes the registry).

Arms, each on its own APFS clone of the generated state, with real owner processes:
  main   start 1 (the owner folds, names the floor, builds the new registry beside the file),
         stop, start 2 (the swap at open), stop, start 3 (the backup goes), stop.
  kill-stage  kill -9 while start 1 stages; then start, wait for the build, stop, start, stop.
  kill-swap   kill -9 while start 2 runs the swap (the staging file changes); then start, stop.
  kill-renamed  kill -9 as soon as the backup file exists (after the rename, before the start
         is complete); then start, stop.
  space  a debug owner with a free-space margin no disk has: the rebuild is refused.
  old    each older owner binary (--old-bin, a list) on its own clone of the migrated state:
         does it open it, what does it serve, what do the counts say after it stayed up
         --old-dwell seconds (a roster rebuild of another reducer version saves in that time),
         and after the new owner opened the state again.
  old-raised  each older owner binary on a clone of the migrated state whose stored
         schema_version is RAISED by hand (sqlite, by this script: no build writes it): does it
         refuse, with which lines and exit code, and is the folder byte for byte the same after
         it (a list of each file with its size and SHA-256, before and after).
After each arm: the counts of the registry (synth_registry --counts) against the counts before.
Equal = workspaces, tabs, terminals, roster agents, History sessions; the journal head never
goes back. Output: RMP {json} per step and a Markdown table. The report holds counts, sizes and
times only: no paths and no row contents. A time from a loaded host is not a perf number.
"""

import argparse
import hashlib
import importlib.util
import json
import os
import shutil
import signal
import socket
import sqlite3
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location("drs", HERE / "daemon-registry-start.py")
drs = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(drs)

REGISTRY = drs.REGISTRY
STAGING = REGISTRY + ".output-cleanup"
PREVIOUS = REGISTRY + ".pre-output-cleanup"
EQUAL_KEYS = ("workspaces", "tabs", "terminals", "roster_agents", "history_sessions")


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


# history_ops.rs MAX_LIST: the most rows one history.entries.list request returns.
HISTORY_LIST_LIMIT = 5000


def served(owner):
    """What the owner SERVES: the agent sessions of history.entries.list (the list of the app's
    History, vault and resume), asked over the socket. `pending` = the fold was not at the head."""
    request = {"protocol": "cmux.protocol/2", "type": "request", "id": "rmp-history",
               "operation": "history.entries.list",
               "params": {"machine": "current", "session": "current", "kinds": ["agent"],
                          "limit": HISTORY_LIST_LIMIT}}
    for attempt in range(40):
        try:
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
            reply = json.loads(data.split(b"\n", 1)[0])
        except (OSError, ValueError) as error:
            return {"error": type(error).__name__}
        if reply.get("ok") is not True:
            return {"error": str((reply.get("error") or {}).get("code"))}
        result = reply.get("result") or {}
        pending = bool(result.get("pending_kinds"))
        if not pending or attempt == 39:
            listed = len(result.get("entries") or [])
            # At the limit the list is one page: the count then proves only "at least".
            return {"agent_sessions": listed, "pending": pending,
                    "one_page_only": listed >= HISTORY_LIST_LIMIT}
        time.sleep(3)
    return {"error": "no answer"}


def served_lost(steps):
    """The steps whose served agent session count differs from the first step's."""
    counts = [(step["arm"], (step.get("served") or {}).get("agent_sessions")) for step in steps
              if "served" in step]
    if not counts:
        return {}
    first = counts[0][1]
    return {arm: [first, count] for arm, count in counts[1:] if count != first}


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
    value["folder_bytes"] = sum(f.stat().st_size for f in sdir.iterdir() if f.is_file())
    return value


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


def build(args, state, label):
    """Start 1 on `state`: ready, then the new registry built beside the file. Stops the owner."""
    owner = Owner(args, state, label)
    ready = owner.wait_ready()
    result = {"arm": label, "ready_s": ready, "load_1m": os.getloadavg()[0]}
    if ready is None:
        result["error"] = "not ready"
        owner.stop()
        return result
    staging = owner.wait_log(STAGING_LINES, args.build_timeout, BAD_BUILD)
    result["staging_started_s"] = None if staging is None else staging[1]
    built = None
    if staging is not None and staging[1] is not None:
        built = wait_built(owner, args.build_timeout)
    result["built_s"] = None if built is None else built[1]
    text = owner.log_text()
    result["skipped_passes"] = text.count(SKIPPED)
    result["cleanup_lines"] = cleanup_lines(owner)[-8:]
    if built is None or built[1] is None:
        result["error"] = "no build" if built is None else "no build: " + built[0]
    result["served"] = served(owner)
    result["exit"] = owner.stop()
    return result


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
    # here: the registry still has every record and no pruned range.
    if (staged["records"] == before["records"]
            and staged["pruned_ranges"] == before["pruned_ranges"]
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
    step.update(lost=compare(before, final), backup_left=final["backup_bytes"] > 0)
    say("RMP", step)
    report["steps"].append(step)
    step = start_stop(args, state, "main-start4")
    final = counts(args, state)
    step.update(lost=compare(before, final), backup_left=final["backup_bytes"] > 0)
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


# Owner log lines that say what an older owner did with the state (no row contents).
OLD_LOG_WORDS = ("schema", "roster", "snapshot", "quarantin", "recover", "registry", "reducer")


def log_lines(owner, limit=12):
    lines = [line for line in owner.log_text().splitlines()
             if any(word in line.lower() for word in OLD_LOG_WORDS)]
    return [line[:300] for line in lines[:limit]]


def old_arm(args, state, before, report, label, binary):
    owner = Owner(args, state, label, binary=binary)
    ready = owner.wait_ready()
    step = {"arm": label, "ready_s": ready, "opens": ready is not None,
            "load_1m": os.getloadavg()[0]}
    if ready is None:
        lines = owner.log_text().splitlines()
        step["last_line"] = (lines[-1] if lines else "")[:200]
    else:
        step["served"] = served(owner)
        # A reducer of another version rebuilds and saves after the owner is ready.
        time.sleep(args.old_dwell)
        step["served_after_dwell"] = served(owner)
    step["exit"] = owner.stop()
    step["log_lines"] = log_lines(owner)
    after = counts(args, state)
    step["lost"] = compare(before, after)
    again = start_stop(args, state, label + "-then-new")
    step["new_after_old_ready_s"] = again["ready_s"]
    step["new_after_old_served"] = again.get("served")
    step["lost_after_new"] = compare(before, counts(args, state))
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
    two = steps.get("main-start2", {})
    rows.append(("start 2: ready, the swap", f"{two.get('ready_s')} s; {two.get('swap')}"))
    if after:
        rows.append(("registry after the swap", gb(after["registry_bytes"]) + f", {after['records']} "
                     f"records, {after['segments']} segments, floor {after['retention_floor']}, "
                     f"backup {gb(after['backup_bytes'])}"))
    if final:
        rows.append(("folder after 2 more starts", gb(final["folder_bytes"]) + f", backup "
                     f"{gb(final['backup_bytes'])}"))
    for key in EQUAL_KEYS:
        rows.append((f"{key} before / after the swap / final",
                     f"{before.get(key)} / {(after or {}).get(key)} / {(final or {}).get(key)}"))
    rows.append(("agent sessions the owner serves (history.entries.list): start 1 / 2 / 3 / 4",
                 " / ".join(str((steps.get(f"main-start{n}", {}).get("served") or {})
                                .get("agent_sessions")) for n in (1, 2, 3, 4))
                 + f"; differs: {json.dumps(report.get('served_lost', {}))}"))
    names = ["kill-stage", "kill-swap", "kill-renamed", "space"]
    names += [name for name in steps if name.startswith("old") and not name.endswith("-new")]
    for name in names:
        step = steps.get(name)
        if step is not None:
            keep = {key: value for key, value in step.items()
                    if key in ("point", "point_hit", "at_kill", "lost", "lost_after_second",
                               "swapped", "refused", "staging_file", "opens", "lost_after_new",
                               "served", "ready_s", "last_line", "staging_seen",
                               "built_before_the_kill", "staging_bytes_at_kill",
                               "after_restart", "new_after_old_ready_s",
                               "served_after_dwell", "new_after_old_served", "log_lines",
                               "schema_version", "exit", "changed", "removed", "added",
                               "untouched", "still_running_at_s", "files_before")}
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
    parser.add_argument("--old-bin", default="")
    parser.add_argument("--arms",
                        default="main,kill-stage,kill-swap,kill-renamed,space,old,old-raised")
    parser.add_argument("--old-dwell", type=float, default=45)
    parser.add_argument("--refusal-timeout", type=float, default=90)
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
    for name in ("old", "old-raised"):
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
    if before["backup_bytes"] or plain["ready_s"] is None:
        plain["error"] = "the plain start swapped or did not get ready"
    for name in ("kill-stage", "space"):
        if name in args.arms:
            clone(args.state, scratch / name)
    ok = main_arm(args, args.state, before, report)
    if "kill-stage" in args.arms:
        kill_stage_arm(args, scratch / "kill-stage", before, report)
    for name in ("kill-swap", "kill-renamed"):
        if name in args.arms and (scratch / name).is_dir():
            kill_at_file_arm(args, scratch / name, before, report, name)
    if "space" in args.arms:
        space_arm(args, scratch / "space", before, report)
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
    lost = [step["arm"] for step in report["steps"]
            if step.get("lost") or step.get("lost_after_second") or step.get("lost_after_new")]
    failed = [step["arm"] for step in report["steps"] if "error" in step]
    # A raised schema_version that an older owner opens, or a folder it changed: not a count,
    # so it is named apart and does not change the exit code.
    not_clean = [step["arm"] for step in report["steps"]
                 if "untouched" in step and (step["opens"] or not step["untouched"])]
    if report.get("served_lost"):
        lost.append("served")
    unread = [step["arm"] for step in report["steps"] if "error" in (step.get("served") or {})]
    say("RMP-VERDICT", {"lost_in": lost, "failed": failed, "served_not_read_in": unread,
                        "raised_not_clean_in": not_clean})
    return 1 if lost or failed or not ok else 0


if __name__ == "__main__":
    sys.exit(main())
