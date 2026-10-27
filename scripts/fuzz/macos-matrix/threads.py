#!/usr/bin/env python3
"""The threading checks of one cmux-next DEV build inside a macOS VM (chrome-parity p02-threads RUN-10, task 305).

vm.sh runs it per major (`--suite threads`; os-matrix.sh `--suite threads`) with the smoke's guest, VNC and app
arguments, and it reuses the smoke's plumbing (smoke.py: launch, calls through the guest's `cmux app call`,
screenshots, quit, crash and fault reports). The blocking detector finds the shared pool by libdispatch's queue
label (`com.apple.root.`), which is not API (risk 6 of plans/cmux-next/chrome-parity/p02-threads.md): these steps
check, on each macOS, that the labels still say what the detector reads.

Steps (each ok/FAIL in result.json; result.json's "labels" has each case's queue label, to compare majors):
  launch       the app starts and answers a ping
  window       a main window exists (debug.windows)
  pool_task    debug.pool_context: a seam call in a Task.detached is classified pool
  pool_global  a seam call in a DispatchQueue.global block is classified pool
  lane_files   a seam call in a BackgroundWork .files item is classified lane
  lane_cpu     a seam call in a .cpu item is classified cpu-lane
  recorded     debug.blocking lists the two pool calls' sites as pool and the .cpu one as cpu-lane, and not
               the .files one (a lane may block)
  raise        WorkHandle.raise of a running best-effort item lifts its thread's kernel priority
               (pth_curpri, overrides included) while its requested QoS stays utility
               (pthread_override_qos_class_start_np on this macOS)
  threads      debug.threads reads every thread: the main thread's requested QoS is user-interactive, some
               threads have a dispatch label (dispatch_queue_offsets), the task role is known
  alive        the app still answers a ping within 10 s
  quit         quitEndEverything ends the process with exit status 0
QoS mismatches and undeclared threads that debug.threads counts are findings (the RUN-3 audit's), not the verdict.

Needs a DEV build with debug.pool_context (perf/chrome-parity, task 305): an older build fails pool_task with
the router's unknown-method error.

Usage (vm.sh does this): threads.py --ssh admin@IP --vnc HOST:PORT:PW --app APP --out DIR
"""

from __future__ import annotations

import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import smoke  # noqa: E402

# The cases debug.pool_context runs, in its order, and the step each one is.
CASE_STEPS = {"task_detached": "pool_task", "global_queue": "pool_global", "lane_files": "lane_files",
              "lane_cpu": "lane_cpu"}
# The contexts in which the detector records a seam call (debug.blocking lists its site there).
RECORDED_CONTEXTS = ("pool", "cpu-lane")
RECORD_DEADLINE = 15  # s: the detector's drain publishes a new site on its own queue, after the call
POOL_CONTEXT_DEADLINE = 90  # s: a first launch in a VM can hold the best-effort fence this long
REQUIRED_STEPS = ("launch", "window", *CASE_STEPS.values(), "recorded", "raise", "threads", "alive", "quit")


def judge_cases(reply: dict) -> dict[str, tuple[bool, dict]]:
    """Each case's step: its context is the expected one. A reply without the cases fails every case step."""
    if "error" in reply or reply.get("refused") or reply.get("compiled_in") is not True:
        why = {"reply": reply, "detail": "no cases: needs a DEV build with the detector and debug.pool_context"}
        return {step: (False, why) for step in CASE_STEPS.values()}
    cases = {c.get("name"): c for c in reply.get("cases") or [] if isinstance(c, dict)}
    steps = {}
    for name, step in CASE_STEPS.items():
        case = cases.get(name)
        if case is None:
            steps[step] = (False, {"detail": f"debug.pool_context has no case {name}"})
            continue
        steps[step] = (case.get("context") == case.get("expected") and case.get("expected") is not None,
                       {k: case.get(k) for k in ("expected", "context", "label", "site")})
    return steps


def judge_recorded(reply: dict, blocking: dict) -> tuple[bool, dict]:
    """The recorded cases' sites are in debug.blocking with their context; a .files case's site is not."""
    contexts: dict[str, set[str]] = {}
    for site in blocking.get("sites") or []:
        contexts.setdefault(site.get("location"), set()).add(site.get("context"))
    want, wrong = {}, {}
    for case in reply.get("cases") or []:
        expected, site = case.get("expected"), case.get("site")
        seen = sorted(contexts.get(site, ()))
        want[case.get("name")] = {"site": site, "expected": expected if expected in RECORDED_CONTEXTS else None,
                                  "listed_as": seen}
        if (seen != [expected]) if expected in RECORDED_CONTEXTS else bool(seen):
            wrong[case.get("name")] = want[case.get("name")]
    ok = bool(want) and not wrong and blocking.get("compiled_in") is True
    return ok, {"cases": want, "wrong": sorted(wrong), "pool_mode": blocking.get("pool_mode")}


def judge_raise(reply: dict) -> tuple[bool, dict]:
    """The raised item's priority rose and its requested QoS stayed utility (an override, not a QoS change)."""
    raised = reply.get("raise") or {}
    before, after = raised.get("before") or {}, raised.get("after") or {}
    pb, pa = before.get("priority"), after.get("priority")
    ok = (before.get("qos") == "utility" and after.get("qos") == "utility"
          and isinstance(pb, (int, float)) and isinstance(pa, (int, float)) and pa > pb)
    return ok, {"before": before, "after": after}


def judge_threads(reply: dict) -> tuple[bool, dict, dict]:
    """debug.threads reads the threads on this macOS; also the counts the QoS audit reads, as a finding."""
    rows = reply.get("threads") or []
    main = next((r for r in rows if r.get("main")), {})
    labeled = sum(1 for r in rows if r.get("label"))
    with_qos = sum(1 for r in rows if r.get("requested_qos"))
    detail = {"thread_count": reply.get("thread_count"), "main_requested_qos": main.get("requested_qos"),
              "labeled": labeled, "with_requested_qos": with_qos, "task_role": reply.get("task_role"),
              "error": reply.get("error")}
    ok = (bool(rows) and main.get("requested_qos") == "user-interactive" and labeled > 0
          and with_qos * 2 >= len(rows) and reply.get("task_role") not in (None, "unknown"))
    audit = {k: reply.get(k) for k in ("mismatched", "hidden_mismatched", "unknown_qos", "undeclared_cmux",
                                       "undeclared_library", "queue_problems")}
    return ok, detail, audit


class Threads(smoke.Smoke):
    suite = "threads"
    required = REQUIRED_STEPS

    def run(self) -> None:
        g = self.g
        self.result["os"] = g.sh("sw_vers -productVersion").stdout.strip()
        self.result["build"] = g.sh("sw_vers -buildVersion").stdout.strip()
        g.sh(": >/tmp/cmux-fuzz-app.log")
        started = time.time()
        if not self.step("launch", g.launch(smoke.LAUNCH_DEADLINE, exit_file=smoke.EXIT_FILE),
                         {"seconds_vm": round(time.time() - started, 1), "socket": g.socket}):
            return
        if "error" in self.call("system.identify"):
            self.step("debug_build", False, "the app refused `cmux app call`: the suite needs a DEV build")
            return
        windows = self.wait(self.windows, 30)
        if not self.step("window", bool(windows), {"windows": len(windows or [])}):
            return

        # The raise case is a best-effort item, which the launch's best-effort fence holds until launch settles: the
        # method then times out with no cases, and a later call runs them.
        replies: list[dict] = []

        def pool_context():
            replies.append(self.call("debug.pool_context", timeout=30))
            return None if "error" in replies[-1] else replies[-1]
        reply = self.wait(pool_context, POOL_CONTEXT_DEADLINE, every=2) or (replies[-1] if replies else {"error": "the app died"})
        self.result["pool_context_calls"] = len(replies)
        for step, (ok, detail) in judge_cases(reply).items():
            self.step(step, ok, detail)
        self.result["labels"] = {c.get("name"): c.get("label") for c in reply.get("cases") or []}

        def recorded():
            verdict = judge_recorded(reply, self.call("debug.blocking"))
            return verdict if verdict[0] else None
        verdict = self.wait(recorded, RECORD_DEADLINE) or judge_recorded(reply, self.call("debug.blocking"))
        self.step("recorded", *verdict)

        self.step("raise", *judge_raise(reply))

        ok, detail, audit = judge_threads(self.call("debug.threads"))
        self.step("threads", ok, detail)
        self.result["findings"].append({"kind": "qos-audit", **audit})

        ms = g.ping_ms(10)
        self.step("alive", ms is not None and ms < 10000, {"pid": g.pid(), "ping_answered": ms is not None and ms < 10000})


if __name__ == "__main__":
    sys.exit(smoke.main(Threads))
