#!/usr/bin/env python3
"""Scale fixture gate: the sidebar and workspace switching at a power user's scale, failing on a main-thread block.

Leo, 2026-11-27 (ask-5ad71ec59c): "Scale fixtures. Seed one profile with about 1,000 workspaces, several Chiefs and a
big cmux.json, run the sidebar and switch flows, and fail if the main thread is blocked for more than ~250 ms. This is
the test that would have caught Lawrence's beach ball."

One tagged bench app (bench_launch.py), seeded as docs/rfd 0186's scale table has it:
  - a ~160 KB cmux.json (the settings file the 2026-11-26 beach ball re-encoded per row, cmux#59531),
  - --workspaces (default 1,100) workspaces, each opened on one agent chat with the app's own
    `agent.openSessionWorkspace`,
  - --chiefs (default 5) Chiefs on this Mac owning those chats (`debug.scale_fixture`), so every row asks for its
    Chief's avatar on every sidebar flush, as Lawrence's rows did.
Then three flows, each timed by the app's own main-thread watchdog (`debug.hangs`, cleared before each):
  flush   agent steps: --ticks rounds that flip --tick-lanes chats between working and idle (row flushes),
  scroll  the sidebar scrolled down and back with the wheel (`debug.sidebar_wheel`),
  switch  --switches workspace switches (`goToWorkspace`) across the list.
A flow fails when the main thread went longer than --budget-ms (default 250) without returning to its run loop
(`max_gap_ms`, every gap whatever the watchdog's threshold; the watchdog's records name the stalls' stacks).
Before the flows a 400 ms `debug.stall` proves the watchdog sees a block (`probe`): a blind gate fails, never passes.

Fail open (exit 0, `verdict: "skipped"`, a `warning`): no GUI session on this Mac, the app does not launch, or the
fixture could not be seeded because the host refused it (no acpmux host id). A seeded fixture whose rows do not ask
for a Chief's avatar (`owned` below half the workspaces) fails: the gate would be blind (exit 2).
Exit 1: a flow blocked the main thread past the budget. The JSON report (--json) has every number.

Run on a fleet GUI Mac (it builds the app at the ref; never on a person's Mac):
  cmux-ci run --class exclusive --measurement --label measure --script scripts/measure/split-spring.sh \\
    --ref SHA --artifact artifacts/split-spring/report.json --arg=--suite=scale-fixture
"""

from __future__ import annotations

import argparse, json, os, socket, sys, threading, time, uuid

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

BUDGET_MS = 250.0
PROBE_MS = 400
# Valid ids of schemas/settings/source/home.json's Chief characters.
MASCOTS = ("fox", "machine", "moon", "mochi", "captain")


def big_config(target_bytes: int = 160_000) -> dict:
    """A cmux.json of about `target_bytes` (the RFD's 160 KB; the sibling unit bench's filler, ChiefFaceFlushBench):
    a Chief character setting and a block of `bench` entries, as a long-lived config of actions and commands is."""
    filler, i = {}, 0
    config = {"appearance": {"backgroundOpacity": 1}, "home": {"chiefPetMascot": "fox"}, "bench": filler}
    entry = lambda n: {"command": "echo " + "x" * 48, "title": f"bench {n}"}
    # Fill to just under the target with the measured size of one entry, then top up one at a time.
    per = len(json.dumps({"key0": entry(0)})) + 1
    while len(json.dumps(config)) < target_bytes:
        for _ in range(max(1, (target_bytes - len(json.dumps(config))) // per)):
            filler[f"key{i}"] = entry(i)
            i += 1
    return config


def verdict(report: dict, budget_ms: float = BUDGET_MS) -> tuple[str, int, list[str]]:
    """(verdict, exit code, reasons) of a run's report: `skipped` (0) when it measured nothing for a reason outside
    the change (no GUI session, no launch, a refused seed); `blind` (2) when the watchdog missed the probe stall or
    the rows did not ask for avatars; `fail` (1) when a flow's longest main-thread gap passed `budget_ms`; else
    `pass` (0)."""
    if report.get("skipped"):
        return "skipped", 0, [report["skipped"]]
    reasons = []
    probe = report.get("probe") or {}
    if probe.get("seen_ms", 0) < PROBE_MS * 0.75:
        reasons.append(f"watchdog missed the {PROBE_MS} ms probe stall (saw {probe.get('seen_ms', 0):.0f} ms)")
    fixture = report.get("fixture") or {}
    wanted = report.get("workspaces_wanted", 0)
    if fixture.get("owned", 0) < wanted / 2:
        reasons.append(f"only {fixture.get('owned', 0)} of {wanted} workspaces ask for a Chief avatar")
    if reasons:
        return "blind", 2, reasons
    for name, flow in (report.get("flows") or {}).items():
        worst = max(flow.get("max_gap_ms", 0), flow.get("max_ms", 0))
        if worst > budget_ms:
            reasons.append(f"{name}: main thread blocked {worst:.0f} ms > {budget_ms:.0f} ms")
    return ("fail", 1, reasons) if reasons else ("pass", 0, [])


class App:
    """The bench app's control socket (newline JSON, as stress-bench.py)."""

    def __init__(self, path: str):
        self.path = path

    def call(self, method: str, params: dict | None = None, timeout: float = 120) -> dict:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as stream:
            stream.settimeout(timeout)
            stream.connect(self.path)
            stream.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
            reply = b""
            while not reply.endswith(b"\n"):
                chunk = stream.recv(1 << 20)
                if not chunk:
                    break
                reply += chunk
        message = json.loads(reply or b"{}")
        if message.get("error"):
            return {"error": message["error"]}
        return message.get("result") if isinstance(message.get("result"), dict) else {"result": message.get("result")}

    def action(self, action: str, focus: bool = False, **args) -> dict:
        params = {"action": action, "args": args, "wait": True, "origin": "script",
                  "idempotency_key": f"mutation_{uuid.uuid4().hex}"}
        if focus:
            params["focus"] = True
        return self.call("action.run", params)


def hangs(app: App, clear: bool = False) -> dict:
    reply = app.call("debug.hangs", {"clear": clear, "limit": 5}, timeout=30)
    keep = ("installed", "threshold_ms", "count", "max_ms", "max_gap_ms", "long_frames", "long_frame_max_ms")
    out = {key: reply.get(key) for key in keep}
    # The stalls' own reports (duration, the task or stack the sample caught), for the PR's evidence.
    out["records"] = [{k: r.get(k) for k in ("duration_ms", "task", "verdict", "frames", "symbols") if k in r}
                      for r in (reply.get("records") or [])][-3:]
    return out


def flow(app: App, name: str, body) -> dict:
    hangs(app, clear=True)
    time.sleep(0.3)  # the clear's own turn ends
    hangs(app, clear=True)
    started = time.monotonic()
    detail = body() or {}
    time.sleep(1.0)  # flushes the flow started run before the read
    measured = hangs(app)
    measured["seconds"] = round(time.monotonic() - started, 2)
    measured.update(detail)
    worst = max(measured.get("max_gap_ms") or 0, measured.get("max_ms") or 0)
    print(f"scale-fixture: {name}: max main-thread gap {worst:.0f} ms ({measured.get('count')} stalls) in "
          f"{measured['seconds']} s", flush=True)
    return measured


def open_workspaces(app: App, sessions: list[str], deadline: float, threads: int = 4) -> tuple[list[str], list[str]]:
    """Opens one workspace per session (`agent.openSessionWorkspace`), `threads` at a time; the created
    workspace refs and the first refusals."""
    created, errors, lock, it = [], [], threading.Lock(), iter(enumerate(sessions))

    def worker():
        while time.monotonic() < deadline:
            with lock:
                item = next(it, None)
            if item is None:
                return
            index, session = item
            reply = app.action("agent.openSessionWorkspace", session=session, name=f"scale {index:04d}")
            refs = [str(r) for r in (reply.get("created") or []) if str(r).startswith("ws_")]
            with lock:
                if refs:
                    created.append(refs[0])
                elif len(errors) < 5:
                    errors.append(str(reply.get("error") or reply)[:300])

    pool = [threading.Thread(target=worker, daemon=True) for _ in range(threads)]
    for thread in pool:
        thread.start()
    for thread in pool:
        thread.join()
    return created, errors


def run(opts) -> dict:
    from bench_launch import BenchApp, LaunchError, gui_session

    report: dict = {"budget_ms": opts.budget_ms, "workspaces_wanted": opts.workspaces, "chiefs": opts.chiefs}
    session = gui_session()
    if not session.get("ok"):
        report["skipped"] = f"no GUI session on this Mac ({session.get('reason') or session})"
        return report
    config = big_config(opts.config_bytes)
    report["config_bytes"] = len(json.dumps(config))
    # The watchdog records every stall from 100 ms with its stack; the gate reads `max_gap_ms`, every gap.
    bench = BenchApp(opts.app, out=opts.out, config=config, log_name="app-scale-fixture.log",
                     env={"CMUX_NEXT_HANG_THRESHOLD_MS": "100"})
    try:
        bench.launch(timeout=180)
    except LaunchError as error:
        report["skipped"] = f"app did not launch: {error.reason}"
        return report
    try:
        app = App(bench.socket)
        report["watchdog"] = hangs(app, clear=True)
        app.call("debug.stall", {"ms": PROBE_MS}, timeout=30)
        time.sleep(0.5)
        seen = hangs(app)
        report["probe"] = {"stall_ms": PROBE_MS, "seen_ms": max(seen.get("max_gap_ms") or 0, seen.get("max_ms") or 0)}

        sessions = [str(uuid.uuid4()) for _ in range(opts.workspaces)]
        # The lanes first: the rows read their Chief as they are mapped.
        report["fixture_lanes"] = app.call("debug.scale_fixture", {"chiefs": opts.chiefs, "sessions": sessions})
        if "error" in report["fixture_lanes"]:
            report["skipped"] = f"debug.scale_fixture refused: {report['fixture_lanes']['error']}"
            return report
        started = time.monotonic()
        created, errors = open_workspaces(app, sessions, started + opts.seed_timeout)
        report["seed"] = {"created": len(created), "seconds": round(time.monotonic() - started, 1), "errors": errors}
        print(f"scale-fixture: opened {len(created)} of {opts.workspaces} workspaces in {report['seed']['seconds']} s",
              flush=True)
        if not created:
            report["skipped"] = f"no workspace opened: {errors[:1]}"
            return report
        # Again after the opens, should a lane watch page have replaced the store meanwhile.
        report["fixture"] = app.call("debug.scale_fixture", {"chiefs": opts.chiefs, "sessions": sessions})
        # Each Chief wears its own character (ChiefMascotPicks), as a person who picked them does: the avatar path
        # of the beach ball. The Home fixture names them; no Home page only leaves the default Chief's character.
        chiefs = [{"id": f"agent_scale{i:02d}", "name": f"Scale Chief {i}", "mascot": MASCOTS[i % len(MASCOTS)]}
                  for i in range(min(20, max(1, opts.chiefs)))]
        try:
            report["chief_mascots"] = app.call("debug.home.sidebar_fixture", {"count": 0, "chiefs": chiefs})
        except Exception as exc:  # noqa: BLE001 - the avatars still ask for the default Chief's character
            report["chief_mascots"] = {"error": str(exc)}
        print(f"scale-fixture: fixture {report['fixture']}", flush=True)
        time.sleep(3)  # the seed's own flushes settle before the first flow

        flows = report["flows"] = {}

        def flush():
            for _ in range(opts.ticks):
                app.call("debug.scale_fixture", {"tick": opts.tick_lanes})
                time.sleep(0.25)
            return {"ticks": opts.ticks, "lanes_per_tick": opts.tick_lanes}

        def scroll():
            for dy in (-40, 40):
                for _ in range(opts.scroll_steps):
                    app.call("debug.sidebar_wheel", {"x": 120, "y": 400, "dy": dy, "count": 3})
                    time.sleep(0.05)
            return {"wheel_events": opts.scroll_steps * 6}

        def switch():
            step = max(1, len(created) // max(1, opts.switches))
            targets = created[::step][:opts.switches]
            accepted = 0
            for ref in targets:
                reply = app.action("goToWorkspace", focus=True, workspace=ref)
                accepted += "error" not in reply
                time.sleep(0.2)
            return {"switches": len(targets), "accepted": accepted}

        flows["flush"] = flow(app, "flush", flush)
        flows["scroll"] = flow(app, "scroll", scroll)
        flows["switch"] = flow(app, "switch", switch)
        report["fixture_after"] = app.call("debug.scale_fixture", {"tick": 0})
        return report
    finally:
        bench.stop()


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--app", required=True)
    ap.add_argument("--tag")
    ap.add_argument("--out", required=True)
    ap.add_argument("--json", required=True)
    ap.add_argument("--workspaces", type=int, default=1100)
    ap.add_argument("--chiefs", type=int, default=5)
    ap.add_argument("--config-bytes", type=int, default=160_000)
    ap.add_argument("--budget-ms", type=float, default=BUDGET_MS)
    ap.add_argument("--seed-timeout", type=float, default=900)
    ap.add_argument("--ticks", type=int, default=20)
    ap.add_argument("--tick-lanes", type=int, default=50)
    ap.add_argument("--scroll-steps", type=int, default=30)
    ap.add_argument("--switches", type=int, default=30)
    opts, _ = ap.parse_known_args(argv)
    os.makedirs(opts.out, exist_ok=True)
    report = run(opts)
    name, code, reasons = verdict(report, opts.budget_ms)
    report["verdict"], report["reasons"] = name, reasons
    if name == "skipped":
        report["warning"] = f"scale-fixture measured nothing (fail open): {reasons[0]}"
    with open(opts.json, "w") as f:
        json.dump(report, f, indent=1)
    print(f"scale-fixture: {name.upper()}" + (": " + "; ".join(reasons) if reasons else ""), flush=True)
    print("SCALE-FIXTURE " + json.dumps({k: report.get(k) for k in ("verdict", "reasons", "probe", "seed", "fixture")}),
          flush=True)
    return code


if __name__ == "__main__":
    sys.exit(main())
