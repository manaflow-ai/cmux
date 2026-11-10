#!/usr/bin/env python3
"""Regression test: the main thread stays free while a person types in the LARGE session
(plans/cmux-next/main-thread-scheduling.md 1.5, step 0).

Registered with lane "manual" (tests/test-execution.d/cmux.toml): no CI lane runs it. Each step's author runs it on
the fleet before and after the step (the wrapper builds a bench app at the commit, then runs this test):

  cmux-ci run --class exclusive --measurement --label measure --key mts-<step> --ref SHA \\
    --script scripts/measure/main-thread-large-session.sh --artifact artifacts/main-thread/report.json \\
    --arg=--config=bench --arg=--mode=test

It runs scripts/cmux-next/sidebar-churn-typing.py --session large (60 workspaces x 6 tabs, the 5 title streams and 5
agent statuses a second in hidden workspaces, real HID keys into a `cat` terminal of the shown workspace) and FAILS
when, during the typed keys of a loaded phase:

  * any main-thread task is over 8 ms: an owner's longest task in debug.main_budget `owners` (every scheduled task's
    own time, the store drain `daemon.store.drain` too), or a debug.hangs stall record (the watchdog, threshold 8 ms:
    it also sees main-actor jobs that no scheduler owns, such as observation re-evaluations);
  * any refresh is missed while typing: a display frame interval over 1.5 refreshes that overlaps a key's window, from
    the key event to the frame that shows its echo (`missed_while_typing`). An app that does not report frame times
    (before step 0) is judged on every missed refresh of the phase instead, which can only count more;
  * fewer than 90 % of the keys reached a shown echo (the run measured nothing).

It prints the owner and the stack of each failure. Expected red on 9e0c2ce826c (the link-places loop of #40038:
84 % of the main thread in one owner); after #40038 (d1bf101b008) it names the next owner, or it is green.

  python3 tests/test_cmux_next_main_thread_large_session.py --app APP --tag TAG --out DIR [--input real] [--samples 120]
  python3 tests/test_cmux_next_main_thread_large_session.py --report DIR/large-report.json   # judge a report again
  python3 tests/test_cmux_next_main_thread_large_session.py --self-test                     # the judge, no app
"""
import argparse, json, os, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BENCH = os.path.join(ROOT, "scripts", "cmux-next", "sidebar-churn-typing.py")
TASK_LIMIT_MS = 8.0
MIN_KEY_SHARE = 0.9


def judge(report, samples=None):
    """The failures of a sidebar-churn-typing.py --session large report: a list of strings, empty when it passes."""
    failures = []
    if report.get("launch_failure"):
        return [f"the app did not launch: {report['launch_failure']}"]
    loaded = [p for p in report.get("phases") or [] if (p.get("churn_hz") or 0) > 0]
    if not loaded:
        return ["the report has no loaded phase (the run ended before typing under load)"]
    for phase in loaded:
        name = phase.get("phase")
        keys = samples or phase.get("keys") or 0
        complete = phase.get("complete") or 0
        if keys and complete < MIN_KEY_SHARE * keys:
            failures.append(f"{name}: only {complete} of {keys} keys showed an echo")
        for owner in phase.get("owners") or []:
            if (owner.get("max_ms") or 0) > TASK_LIMIT_MS:
                failures.append(f"{name}: owner {owner.get('owner')} task max {owner.get('max_ms'):.2f} ms > {TASK_LIMIT_MS:g} ms "
                                f"({owner.get('over_8ms')} of {owner.get('count')} tasks over 8 ms, p95 {owner.get('p95_ms'):.2f} ms)")
        if phase.get("owners") is None:
            # An app before the owner record: the longest task per budgeted class still names the class.
            classes = ((phase.get("main_budget") or {}).get("classes") or {}) if isinstance(phase.get("main_budget"), dict) else {}
            for cls, row in sorted(classes.items()):
                if (row.get("max_task_ms") or 0) > TASK_LIMIT_MS:
                    failures.append(f"{name}: class {cls} task max {row['max_task_ms']:.2f} ms > {TASK_LIMIT_MS:g} ms (no owner record)")
        for record in phase.get("hang_records") or []:
            if record.get("kind") not in (None, "stall"):
                continue
            ms = record.get("duration_ms") or 0
            if ms > TASK_LIMIT_MS:
                owner = record.get("task_owner") or "no scheduled owner (a plain main-actor job)"
                stack = "\n      ".join((record.get("frames") or [])[:24])
                failures.append(f"{name}: main-thread stall {ms:.1f} ms, owner {owner}\n      {stack}")
        hangs = phase.get("hangs") if isinstance(phase.get("hangs"), dict) else {}
        if (hangs.get("max_ms") or 0) > TASK_LIMIT_MS and not phase.get("hang_records"):
            failures.append(f"{name}: {hangs.get('count')} main-thread stalls, longest {hangs['max_ms']:.1f} ms (no records kept)")
        missed = phase.get("missed_while_typing")
        if missed is None:
            frames = phase.get("frames") if isinstance(phase.get("frames"), dict) else {}
            if frames.get("missed"):
                failures.append(f"{name}: {frames['missed']} missed refreshes in the phase (the app reports no frame times, so "
                                "every missed refresh counts)")
        elif missed.get("count"):
            failures.append(f"{name}: {missed['count']} missed refreshes while typing, over {missed.get('keys')} keys, the longest "
                            f"frame {missed.get('worst_ms')} ms (limit {missed.get('limit_ms')} ms)")
    return failures


def owner_table(report):
    """Per loaded phase, the owners by total time: count, p50 / p95 / max ms (the section 5 rows)."""
    lines = []
    for phase in report.get("phases") or []:
        owners = phase.get("owners") or []
        lines.append(f"{phase.get('phase')}: {len(owners)} owners")
        for owner in owners[:12]:
            lines.append(f"  {owner.get('owner')}: count {owner.get('count')}, p50 {owner.get('p50_ms'):.3f}, "
                         f"p95 {owner.get('p95_ms'):.3f}, max {owner.get('max_ms'):.3f} ms")
    return "\n".join(lines)


def self_test():
    """The judge on made-up reports: a clean run passes, each failure kind fails with its owner, an old app's report
    is judged on what it has."""
    def phase(**extra):
        base = {"phase": "churn-0", "churn_hz": 10, "keys": 120, "complete": 120, "hang_records": [], "hangs": {"max_ms": 0},
                "owners": [{"owner": "daemon.store.drain", "count": 900, "over_8ms": 0, "p50_ms": 0.2, "p95_ms": 0.6, "max_ms": 2.1}],
                "missed_while_typing": {"count": 0, "keys": 0, "worst_ms": 0, "limit_ms": 12.5}, "frames": {"missed": 3}}
        base.update(extra)
        return {"phases": [{"phase": "idle-0", "churn_hz": 0}, base]}

    assert judge(phase()) == [], judge(phase())
    slow = judge(phase(owners=[{"owner": "SidebarRows", "count": 10, "over_8ms": 1, "p50_ms": 1, "p95_ms": 9, "max_ms": 9.5}]))
    assert len(slow) == 1 and "SidebarRows" in slow[0], slow
    stall = judge(phase(hang_records=[{"kind": "stall", "duration_ms": 40, "frames": ["AgentPaneLinkPlaces.follow"]}],
                        hangs={"max_ms": 40}))
    assert len(stall) == 1 and "no scheduled owner" in stall[0] and "AgentPaneLinkPlaces" in stall[0], stall
    missed = judge(phase(missed_while_typing={"count": 2, "keys": 2, "worst_ms": 25, "limit_ms": 12.5}))
    assert len(missed) == 1 and "2 missed refreshes while typing" in missed[0], missed
    few = judge(phase(complete=50))
    assert len(few) == 1 and "50 of 120" in few[0], few
    old = judge(phase(owners=None, missed_while_typing=None, main_budget={"classes": {"visible": {"max_task_ms": 30}}}))
    assert len(old) == 2 and any("class visible" in f for f in old) and any("3 missed refreshes in the phase" in f for f in old), old
    assert judge({"phases": [{"phase": "idle-0", "churn_hz": 0}]}) != []
    print("self-test: ok")


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--app", help="a bench or Debug `cmux DEV <tag>.app` (not running)")
    mode.add_argument("--report", help="judge this sidebar-churn-typing.py --session large report")
    mode.add_argument("--self-test", action="store_true", help="check the judge on made-up reports (no app)")
    parser.add_argument("--tag", default="mts-large")
    parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS") or "artifacts/main-thread")
    parser.add_argument("--input", choices=["real", "debug"], default="real")
    parser.add_argument("--samples", type=int, default=120)
    parser.add_argument("--trace", action="store_true", help="a Time Profiler of the first phases (the bench's --trace)")
    opts = parser.parse_args()
    if opts.self_test:
        self_test()
        return 0
    if opts.app:
        os.makedirs(opts.out, exist_ok=True)
        path = os.path.join(opts.out, "large-report.json")
        command = [sys.executable, BENCH, "--app", opts.app, "--tag", opts.tag, "--out", opts.out, "--json", path,
                   "--session", "large", "--input", opts.input, "--samples", str(opts.samples)] + (["--trace"] if opts.trace else [])
        print("test: " + " ".join(command), flush=True)
        ran = subprocess.run(command)
        if not os.path.exists(path):
            print(f"FAIL: the bench wrote no report (exit {ran.returncode})")
            return 1
    else:
        path = opts.report
    with open(path) as handle:
        report = json.load(handle)
    print(owner_table(report))
    failures = judge(report, samples=None)
    if failures:
        print(f"FAIL: {len(failures)} failures")
        for failure in failures:
            print("  - " + failure)
        return 1
    print("PASS: no main-thread task over 8 ms and no missed refresh while typing")
    return 0


if __name__ == "__main__":
    sys.exit(main())
