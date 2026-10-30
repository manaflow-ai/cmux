#!/usr/bin/env python3
"""Control snapshot publish cost at scale for a tagged cmux-next build (cx-1ox9m).

The app publishes the control snapshot (`ControlSnapshotPublisher.publishNow`)
on the main thread after every settled change. On 2026-10-13 a DEV build hung
in that publish: it re-read every tab of every workspace on each publish, and
the debug watchdog stopped the app after 10 s.

The bench launches the tagged app itself (clean environment, no activation,
isolated Chief home), fills its daemon with --workspaces workspaces of --tabs
terminal tabs each through the daemon socket (`new-workspace`, `new-tab`),
then renames one workspace --renames times (`rename-workspace`, round robin)
and waits after each rename until `snapshot.get` shows the new name. Each
rename is one change to one workspace; each control request also publishes
after its frame, so most measured publishes change nothing (every workspace
comes from the cache), the case the 2026-10-13 hang paid O(tabs) for. It
reads, over the app's control socket:

  debug.timings control_publishes   main-actor time of each publish and its
                                    tab count (only publishes of the full
                                    tree; the app keeps the first 256)
  debug.hangs                       main-thread stalls over the watchdog
                                    threshold during the renames

Pass criteria: the app stays up, no stall reaches --max-stall-ms (default
2000, the watchdog's hang report), and the median publish is at most
--max-p50-ms (default 2.0).

Run it on the GUI host only (cmux-lawrence-2 through nx-remote with
--app-from-fleet), never on a laptop:

  nx-remote --needs gui --app-from-fleet cmux --tag TAG --ref SHA -- \\
    python3 scripts/cmux-next/bench-control-publish.py --tag TAG --app "$NX_APP"

macOS gives every terminal one PTY (kern.tty.ptmx_max is shared by the
host); the bench refuses a layout that would leave fewer than --pty-margin
free. It quits the app it launched (ending its sessions and agents) and ends the
daemon's terminals.
"""
from __future__ import annotations

import argparse
import glob
import json
import os
import signal
import statistics
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bench_cli_storm import Client  # noqa: E402
from bench_idle import wait_for_socket  # noqa: E402
from daemon_teardown import end_terminals  # noqa: E402


def daemon_socket(tag, limit_s=30):
    tmp = subprocess.run(["getconf", "DARWIN_USER_TEMP_DIR"], capture_output=True, text=True).stdout.strip()
    deadline = time.monotonic() + limit_s
    while time.monotonic() < deadline:
        found = glob.glob(os.path.join(tmp, "cmux-tui-*", f"cmux-app-{tag}.sock"))
        if found:
            return found[0]
        time.sleep(0.2)  # test script: waiting for the daemon socket to appear
    raise SystemExit(f"bench-control-publish: no daemon socket for {tag}")


def free_ptys():
    cap = int(subprocess.run(["sysctl", "-n", "kern.tty.ptmx_max"], capture_output=True, text=True).stdout.strip() or 511)
    return cap - len(glob.glob("/dev/ttys*"))


def tree(control):
    return ((control.call("snapshot.get", timeout=60).get("result") or {}).get("topology") or {})


def tab_count(topology):
    return sum(len(p.get("tabs", [])) for w in topology.get("workspaces", [])
               for s in w.get("screens", []) for p in s.get("panes", []))


def wait_until(condition, limit_s, what):
    deadline = time.monotonic() + limit_s
    while time.monotonic() < deadline:
        if condition():
            return
        time.sleep(0.05)  # test script: polls the app's published snapshot
    raise SystemExit(f"bench-control-publish: timed out waiting for {what}")


def seed(daemon, workspaces, tabs):
    def listed():
        return {w["id"]: w for w in daemon.call("list-workspaces", cmd_key="cmd")["data"]["workspaces"]}

    created = []
    for index in range(workspaces):
        before = listed()
        reply = daemon.call("new-workspace", {"name": f"publish-{index:03d}"}, cmd_key="cmd")
        if not reply.get("ok"):
            raise SystemExit(f"bench-control-publish: new-workspace failed: {reply.get('error')}")
        workspace = next(w for key, w in listed().items() if key not in before)
        pane = workspace["screens"][0]["panes"][0]
        for _ in range(tabs - 1):
            reply = daemon.call("new-tab", {"pane": pane["id"]}, cmd_key="cmd")
            if not reply.get("ok"):
                raise SystemExit(f"bench-control-publish: new-tab failed: {reply.get('error')}")
        created.append(workspace["id"])
    return created


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--app")
    parser.add_argument("--workspaces", type=int, default=50)
    parser.add_argument("--tabs", type=int, default=10, help="terminal tabs per workspace")
    parser.add_argument("--renames", type=int, default=120)
    parser.add_argument("--settle", type=float, default=5)
    parser.add_argument("--pty-margin", type=int, default=100)
    parser.add_argument("--max-p50-ms", type=float, default=2.0)
    parser.add_argument("--max-stall-ms", type=float, default=2000)
    parser.add_argument("--label", default="run")
    parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS") or "artifacts/cmux-next-bench")
    parser.add_argument("--no-fail", action="store_true")
    args = parser.parse_args()

    tag = args.tag
    bundle = args.app or os.path.expanduser(f"~/Library/Developer/Xcode/DerivedData/cmux-{tag}/Build/Products/Debug/cmux DEV {tag}.app")
    binary = os.path.join(bundle, "Contents/MacOS/cmux DEV")
    if not os.path.exists(binary):
        raise SystemExit(f"bench-control-publish: no app at {bundle}")
    needed = args.workspaces * args.tabs + 1
    if free_ptys() - needed < args.pty_margin:
        raise SystemExit(f"bench-control-publish: {needed} terminals would leave fewer than {args.pty_margin} "
                         f"free PTYs ({free_ptys()} free); lower --workspaces or --tabs")
    scratch = tempfile.mkdtemp(prefix=f"bench-publish-{tag}-")
    env = {
        "HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_CHIEF_ISOLATED": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
        "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_CONFIG_FILE": os.path.join(scratch, "cmux.json"),
    }
    app = subprocess.Popen([binary], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    report = {"tag": tag, "label": args.label, "workspaces": args.workspaces, "tabs_per_workspace": args.tabs}
    failures = []
    control = None
    try:
        control = wait_for_socket(f"/tmp/cmux-debug-{tag}.sock")
        daemon = Client(daemon_socket(tag), timeout=30)
        started = time.monotonic()
        ids = seed(daemon, args.workspaces, args.tabs)
        wait_until(lambda: tab_count(tree(control)) >= args.workspaces * args.tabs, 300, "the app to list every tab")
        report["seed_s"] = round(time.monotonic() - started, 1)
        total = tab_count(tree(control))
        report["tabs"] = total
        time.sleep(args.settle)  # test script: let the seeded tree settle before the measured window
        control.call("debug.timings", {"clear": True})
        control.call("debug.hangs", {"clear": True})
        rename_ms = []
        for index in range(args.renames):
            workspace = ids[index % len(ids)]
            name = f"publish-r{index:04d}"
            sent = time.monotonic()
            reply = daemon.call("rename-workspace", {"workspace": workspace, "name": name}, cmd_key="cmd")
            if not reply.get("ok"):
                raise SystemExit(f"bench-control-publish: rename-workspace failed: {reply.get('error')}")
            wait_until(lambda: any(w.get("name") == name for w in tree(control).get("workspaces", [])), 30,
                       f"rename {index} in the snapshot")
            rename_ms.append((time.monotonic() - sent) * 1000)
        timings = control.call("debug.timings").get("result") or {}
        hangs = control.call("debug.hangs", {"limit": 3}).get("result") or {}
        publishes = [p["ms"] for p in timings.get("control_publishes", []) if p.get("tabs", 0) >= total]
        if not publishes:
            failures.append("debug.timings has no control_publishes (build without cx-1ox9m instrumentation?)")
        else:
            ordered = sorted(publishes)
            report["publish_ms"] = {
                "count": len(publishes),
                "p50": round(statistics.median(publishes), 3),
                "p90": round(ordered[int(0.9 * (len(ordered) - 1))], 3),
                "max": round(ordered[-1], 3),
                "mean": round(statistics.fmean(publishes), 3),
            }
            if report["publish_ms"]["p50"] > args.max_p50_ms:
                failures.append(f"median publish {report['publish_ms']['p50']} ms over {args.max_p50_ms} ms at {total} tabs")
        report["rename_to_snapshot_ms"] = {"p50": round(statistics.median(rename_ms), 2), "max": round(max(rename_ms), 2)}
        report["hangs"] = {k: hangs.get(k) for k in ("count", "max_ms", "total_ms", "max_gap_ms", "long_frames")}
        if (hangs.get("max_ms") or 0) >= args.max_stall_ms:
            failures.append(f"main-thread stall {hangs.get('max_ms')} ms reached {args.max_stall_ms} ms")
        if app.poll() is not None:
            failures.append(f"the app exited ({app.returncode})")
    finally:
        try:
            if control is not None and app.poll() is None:
                control.call("debug.quit", {"fixture_quit": "end-everything"}, timeout=30)
            app.wait(timeout=30)
        except Exception:  # noqa: BLE001 - quit is best effort; stop the launched app below
            if app.poll() is None:
                app.send_signal(signal.SIGTERM)
                try:
                    app.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    app.kill()
        try:
            report["teardown"] = end_terminals(os.path.join(bundle, "Contents/Resources/bin/cmux-tui"), tag)
        except Exception as error:  # noqa: BLE001 - teardown is best effort; report it
            print(f"bench-control-publish: daemon teardown: {error}", file=sys.stderr)
    report["failures"] = failures
    os.makedirs(args.out, exist_ok=True)
    out = os.path.join(args.out, f"control-publish-{tag}-{args.label}.json")
    with open(out, "w") as handle:
        json.dump(report, handle, indent=2)
    print(json.dumps({k: report.get(k) for k in ("tabs", "seed_s", "publish_ms", "rename_to_snapshot_ms", "hangs")}, indent=2))
    print(f"bench-control-publish: wrote {out}")
    for failure in failures:
        print(f"FAIL {failure}")
    if failures and not args.no_fail:
        sys.exit(1)


if __name__ == "__main__":
    main()
