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
  old    an older owner binary on the migrated state: does it open it.
After each arm: the counts of the registry (synth_registry --counts) against the counts before.
Equal = workspaces, tabs, terminals, roster agents, History sessions; the journal head never
goes back. Output: RMP {json} per step and a Markdown table. The report holds counts, sizes and
times only: no paths and no row contents. A time from a loaded host is not a perf number.
"""

import argparse
import importlib.util
import json
import os
import shutil
import signal
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

    def wait_ready(self):
        deadline = self.started + self.args.ready_timeout
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


BAD_BUILD = ("output cleanup: not enough free space", "output cleanup: skipped, the registry",
             "output cleanup: staging failed")


def build(args, state, label):
    """Start 1 on `state`: ready, then the new registry built beside the file. Stops the owner."""
    owner = Owner(args, state, label)
    ready = owner.wait_ready()
    result = {"arm": label, "ready_s": ready, "load_1m": os.getloadavg()[0]}
    if ready is None:
        result["error"] = "not ready"
        owner.stop()
        return result
    staging = owner.wait_log(["output cleanup: staging "], args.build_timeout, BAD_BUILD)
    result["staging_started_s"] = None if staging is None else staging[1]
    built = None
    if staging is not None and staging[1] is not None:
        built = owner.wait_log(["built the new registry in the background in"],
                               args.build_timeout, BAD_BUILD)
    result["built_s"] = None if built is None else built[1]
    if built is None or built[1] is None:
        lines = [line.split("output cleanup: ")[1][:160] for line in owner.log_text().splitlines()
                 if "output cleanup: " in line and "/" not in line]
        result["error"] = "no build"
        result["cleanup_lines"] = lines[-6:]
    result["exit"] = owner.stop()
    return result


def start_stop(args, state, label, binary=None):
    owner = Owner(args, state, label, binary=binary)
    ready = owner.wait_ready()
    result = {"arm": label, "ready_s": ready, "swap": swap_line(owner),
              "load_1m": os.getloadavg()[0]}
    if ready is None:
        lines = owner.log_text().splitlines()
        result["error"] = "not ready"
        result["last_line"] = (lines[-1] if lines else "")[:200]
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
    return True


def kill_stage_arm(args, state, before, report):
    owner = Owner(args, state, "kill-stage-a")
    owner.wait_ready()
    seen = owner.wait_log(["output cleanup: staging "], args.build_timeout, BAD_BUILD)
    staging = registry_of(state).parent / STAGING
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline and drs.file_size(staging) < 1 << 20:
        time.sleep(0.002)
    step = {"arm": "kill-stage", "point": "while the owner stages", "staging_seen": seen is not None,
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
    while time.monotonic() < deadline and owner.child.poll() is None:
        if name == "kill-renamed":
            hit = previous.exists()
        else:
            hit = stamp() != first or previous.exists()
        if hit:
            break
        time.sleep(0.0005)
    at_kill = {"backup_exists": previous.exists(), "staging_exists": staging.exists(),
               "registry_is_the_old_file": (drs.file_size(registry), registry.stat().st_ino)
               == registry_before if registry.exists() else None,
               "registry_exists": registry.exists(), "ms_from_spawn": round(owner.elapsed() * 1000, 1)}
    owner.kill9()
    step = {"arm": name, "point_hit": hit, "at_kill": at_kill}
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
    step["lost"] = compare(before, counts(args, state))
    say("RMP", step)
    report["steps"].append(step)


def old_arm(args, state, before, report):
    step = start_stop(args, state, "old", binary=args.old_bin)
    step["opens"] = step["ready_s"] is not None
    after = counts(args, state)
    step["lost"] = compare(before, after)
    again = start_stop(args, state, "old-then-new")
    step["new_after_old_ready_s"] = again["ready_s"]
    step["lost_after_new"] = compare(before, counts(args, state))
    say("RMP", step)
    report["steps"].append(step)


def table(report):
    before, after, final = report["before"], report.get("after_swap"), report.get("final")
    steps = {step["arm"]: step for step in report["steps"]}
    gb = lambda value: "-" if value is None else f"{value / 1e9:.3f} GB"  # noqa: E731
    rows = [("registry before", gb(before["registry_bytes"]) + f", {before['records']} records, "
             f"{before['segments']} segments")]
    one = steps.get("main-start1", {})
    rows.append(("start 1: ready / staging starts / built", f"{one.get('ready_s')} s / "
                 f"{one.get('staging_started_s')} s / {one.get('built_s')} s "
                 f"(load {one.get('load_1m', 0):.1f}; {one.get('error', 'ok')})"))
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
    for name in ("kill-stage", "kill-swap", "kill-renamed", "space", "old"):
        step = steps.get(name)
        if step is not None:
            keep = {key: value for key, value in step.items()
                    if key in ("point", "point_hit", "at_kill", "lost", "lost_after_second",
                               "swapped", "refused", "staging_file", "opens", "lost_after_new")}
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
    parser.add_argument("--arms", default="main,kill-stage,kill-swap,kill-renamed,space,old")
    parser.add_argument("--ready-timeout", type=float, default=3600)
    parser.add_argument("--build-timeout", type=float, default=7200)
    args = parser.parse_args()
    args.arms = [arm for arm in args.arms.split(",") if arm]
    if not args.debug_bin and "space" in args.arms:
        args.arms.remove("space")
    if not args.old_bin and "old" in args.arms:
        args.arms.remove("old")
    scratch = Path(args.scratch)
    before = counts(args, args.state)
    say("RMP-COUNTS", {"at": "before", **before})
    report = {"before": before, "steps": [], "arms": args.arms, "host_load_1m": os.getloadavg()[0],
              "free_bytes": shutil.disk_usage(scratch).free}
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
    if "old" in args.arms and ok:
        old_arm(args, clone(args.state, scratch / "old"), before, report)
    Path(args.report).write_text(json.dumps(report, indent=1))
    table(report)
    lost = [step["arm"] for step in report["steps"]
            if step.get("lost") or step.get("lost_after_second") or step.get("lost_after_new")]
    failed = [step["arm"] for step in report["steps"] if "error" in step]
    say("RMP-VERDICT", {"lost_in": lost, "failed": failed})
    return 1 if lost or failed or not ok else 0


if __name__ == "__main__":
    sys.exit(main())
