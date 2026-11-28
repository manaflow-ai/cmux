#!/usr/bin/env python3
"""The agent connection chaos suite (CONTRACT.md beside this file): a real built app, its real acpmux daemon and a
scripted agent (chaos_agent.py, no model call), one driver. Each case starts a counted reply in its own chat,
injects one fault mid-turn, sends a prompt while the link is down (or right after the relaunch), and judges:

  - the link recovers by itself within the case's bound (no click, no Retry);
  - the page never shows "The agent service stopped", "didn't answer in time", "not connected" or a Retry button;
  - the agent was given the stream prompt and the down-time prompt exactly once each;
  - the reply is whole after recovery: TAG-0 .. TAG-<COUNT-1>, each once, in order, on the page and in the store.

Cases (--cases, default all):
  update-midturn   Restart to Update mid-turn: the updater's relaunch hook, then Sparkle's swap of the bundle
                   (APFS clone + renamex_np RENAME_SWAP, bench_relaunch_reconnect.replace_bundle) with a new
                   version's bytes, then the relaunch.
  daemon-sigterm   SIGTERM the acpmux daemon mid-turn.
  daemon-sigkill   SIGKILL the acpmux daemon mid-turn.
  app-sigkill      SIGKILL the app mid-turn, then launch it again (same HOME, as a person reopening it).
  sleep-wake-sim   SIMULATION of sleep/wake: SIGSTOP the app and the daemon for --sleep seconds (default 35),
                   then SIGCONT. A real sleep also stops timers and the network and posts
                   NSWorkspace.didWakeNotification; this does not, and the agent pane has no wake hook to fake one.
  daemon-hung      SIGSTOP the daemon only, and leave it stopped: it holds its lock and socket and answers nothing (a
                   hung daemon). The app must replace it within the bound while it stays stopped; SIGCONT afterwards.
  socket-gone      The daemon's socket file moved away for 20 s, then put back (a removed or replaced socket).
  ws-port-block    The daemon's loopback WebSocket port blocked with pf for 20 s. Needs root (`sudo -n pfctl`);
                   without it the case is NOT RUN (reported so, never passed).

XFAIL below lists cases expected to fail until a named open PR lands. Such a case still runs, and its line names the
PR: a failure prints XFAIL (waits on cmux#N) and does not fail the suite; a pass prints XPASS and fails it, so the mark
comes off the day the fix lands. The judgment itself is never relaxed for a marked case. Exit status: 0 only when every
case passed or failed as marked; result JSON to --out.

Fleet Macs only (scripts/measure/agent-conn-chaos.sh): never cosmic-gray, air-blue, huge-blue or big-red.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
import bench_memory as bm  # noqa: E402  (launch, App, FakeChats, end_bundle, process_table, end_processes)
import bench_power as bp  # noqa: E402  (rpc, wipe_state)
import idle_cost_load as load  # noqa: E402  (new_session, open_workspace, read_chat)
import bench_relaunch_reconnect as rr  # noqa: E402  (quit_app, replace_bundle, daemon_pids)

AGENT = os.path.join(HERE, "chaos_agent.py")
CASES = ["update-midturn", "daemon-sigterm", "daemon-sigkill", "app-sigkill", "sleep-wake-sim", "daemon-hung", "socket-gone",
         "ws-port-block"]
# Seconds from the fault's end to a connected chat with its turn live or done (CONTRACT.md "Bounds").
BOUND = {"update-midturn": 60, "app-sigkill": 60, "daemon-sigterm": 30, "daemon-sigkill": 30,
         "sleep-wake-sim": 30, "daemon-hung": 45, "socket-gone": 30, "ws-port-block": 30}
# Expected failures until an open PR lands: case -> the PR. Each mark comes off when its PR merges (an XPASS fails).
XFAIL: dict[str, str] = {
    # The app does not start its own daemon again when a reconnect finds it gone.
    "daemon-sigterm": "cmux#60429 (lane/gui-agent-connection-dictator)",
    "daemon-sigkill": "cmux#60429 (lane/gui-agent-connection-dictator)",
    # An update's hand-off: the successor daemon takes the staged path's listener (acpmux daemon expect-relaunch).
    "update-midturn": "cmux#60430 (lane/agent-conn-update-handoff)",
    # A daemon that holds its lock but never answers is not replaced.
    "daemon-hung": "cmux#60685 (lane/agent-conn-hung-lock-holder)",
}
FORBIDDEN = [re.compile(p, re.I) for p in (r"agent service stopped", r"didn'?t answer in time", r"not connected",
                                           r"service stopped")]
RETRY = re.compile(r"^\s*Retry\b")  # a Retry control: an element whose own text starts with Retry
QUIET_S = 3.0  # CONTRACT.md: within this the page may show nothing at all; after it only the status dot
FAULT_AT_S = 8.0
COUNT, RATE = 240, 4.0  # a 60 s reply: every fault lands mid-turn and the turn outlives it


def log(msg: str):
    print(f"conn-chaos: {msg}", file=sys.stderr, flush=True)


class Run:
    def __init__(self, args):
        self.args = args
        self.bundle = args.app.rstrip("/")
        self.root = tempfile.mkdtemp(prefix="agent-conn-chaos-")
        self.agent_log = os.path.join(self.root, "agent.ndjson")
        self.acpmux_home = os.path.join(self.root, "acpmux")
        self.env = {"ACPMUX_HOME": self.acpmux_home}
        self.config = {}
        self.scratch = None
        self.generation = 0
        self.launch()

    def launch(self):
        self.pid, self.sock, self.scratch = bm.launch(self.bundle, self.config, self.env, scratch=self.scratch)
        self.app = bm.App(self.bundle, self.sock)
        args = shlex.quote(AGENT) + " " + shlex.quote(self.agent_log)
        for _ in range(5):
            added = self.app.run("agent.harness.add", id=bm.FAKE_AGENT_ID, name="Conn chaos", command=sys.executable,
                                 args=args, protocol="acp", replace="true")
            if "timeout" not in str(added.get("code") or added.get("error") or ""):
                break
            time.sleep(5)  # test script: the app is still starting (bench_memory.FakeChats)
        if added.get("error") or added.get("code"):
            raise SystemExit(f"conn-chaos: agent.harness.add: {added.get('message') or added.get('error')}")
        self.cli_env = dict(os.environ, ACPMUX_SOCKET=bm.FakeChats.acpmux_socket(self.bundle))

    def pane(self, action: str, timeout: float = 30, **params) -> dict:
        result = bp.rpc(self.sock, "debug.agent_pane", dict(params, action=action), timeout=timeout)
        return result if isinstance(result, dict) else {"error": repr(result)}

    def agent_entries(self) -> list[dict]:
        try:
            with open(self.agent_log) as handle:
                return [json.loads(line) for line in handle if line.strip()]
        except OSError:
            return []

    def close(self):
        bm.end_bundle(self.bundle)
        if self.scratch:
            shutil.rmtree(self.scratch, ignore_errors=True)
        shutil.rmtree(self.root, ignore_errors=True)


class Watch(threading.Thread):
    """Samples the shown chat every half second: its connection, and every element's text for a forbidden string."""

    def __init__(self, run: Run, session: str):
        super().__init__(daemon=True)
        self.run_, self.session, self.stop = run, session, threading.Event()
        self.samples: list[dict] = []
        self.seen: list[dict] = []
        self.paused = threading.Event()  # set while the app is stopped or gone: no sample then

    def run(self):
        while not self.stop.is_set():
            if not self.paused.is_set():
                self.sample()
            self.stop.wait(0.5)  # test script: the sampling pace

    def sample(self):
        at = time.monotonic()
        state = self.run_.pane("chat_state", timeout=5)
        if state.get("error"):
            self.samples.append({"at": at, "error": str(state["error"])[:200]})
            return
        self.samples.append({"at": at, "connection": state.get("connection"), "session": state.get("sessionId"),
                             "working": state.get("isWorking"), "unavailable": state.get("unavailable"),
                             "missing": state.get("missingSession")})
        found = self.run_.pane("query", timeout=5, selector="body *")
        texts = [str(row.get("text") or "") + " " + str(row.get("label") or "")
                 for row in (found.get("elements") or found.get("matches") or [])] if isinstance(found, dict) else []
        texts += [str(row) for row in state.get("transcript") or []]
        for text in texts:
            hit = next((p.pattern for p in FORBIDDEN if p.search(text)), None) or ("Retry" if RETRY.search(text) else None)
            if hit:
                self.seen.append({"at": at, "pattern": hit, "text": text[:160]})

    def connected_since(self, start: float) -> float | None:
        """The first moment at or after `start` the shown chat was this session's and connected."""
        for sample in self.samples:
            if sample["at"] >= start and sample.get("connection") == "connected" and sample.get("session") == self.session:
                return sample["at"]
        return None


def words_of(text: str, tag: str) -> list[int]:
    return [int(m) for m in re.findall(rf"\b{re.escape(tag)}-(\d+)\b", text or "")]


def whole(numbers: list[int], count: int) -> str | None:
    if numbers == list(range(count)):
        return None
    dup = sorted({n for n in numbers if numbers.count(n) > 1})
    missing = sorted(set(range(count)) - set(numbers))
    return f"{len(numbers)} words; missing {missing[:10]}{'...' if len(missing) > 10 else ''}; duplicated {dup[:10]}"


def store_text(run: Run, session: str) -> str:
    try:
        chat = load.read_chat(run.acpmux_home, session, wait=10)
    except RuntimeError as error:
        return f"(no store: {error})"
    return b"".join(chat["events"].values()).decode("utf-8", "replace")


def pf_block(port: int) -> tuple[bool, str]:
    rules = f"block drop quick on lo0 proto tcp from any to any port {port}\n"
    ok = subprocess.run(["sudo", "-n", "pfctl", "-a", "com.apple/agentconnchaos", "-f", "-"], input=rules, text=True,
                        capture_output=True)
    if ok.returncode != 0:
        return False, (ok.stderr or ok.stdout).strip()[:200]
    enabled = subprocess.run(["sudo", "-n", "pfctl", "-E"], capture_output=True, text=True)
    token = re.search(r"Token : (\d+)", enabled.stderr + enabled.stdout)
    return True, token.group(1) if token else ""


def pf_unblock(token: str):
    subprocess.run(["sudo", "-n", "pfctl", "-a", "com.apple/agentconnchaos", "-F", "all"], capture_output=True)
    if token:
        subprocess.run(["sudo", "-n", "pfctl", "-X", token], capture_output=True)


def ws_port(run: Run) -> int | None:
    for pid in rr.daemon_pids(run.bundle):
        out = subprocess.run(["lsof", "-nP", "-a", "-p", str(pid), "-iTCP", "-sTCP:LISTEN"], capture_output=True,
                             text=True).stdout
        found = re.search(r"127\.0\.0\.1:(\d+) \(LISTEN\)", out)
        if found:
            return int(found.group(1))
    return None


def signal_all(pids, sig):
    for pid in pids:
        try:
            os.kill(pid, sig)  # this run's own app and daemon only (pids of this run's bundle)
        except ProcessLookupError:
            pass


def inject(run: Run, case: str, watch: Watch, ping: str) -> dict:
    """The fault. Returns {fault_end (monotonic), ping_sent_via, ping_error?, not_run?, note?}."""
    info: dict = {}

    def ping_on_page():
        sent = run.pane("send_prompt", timeout=40, text=ping)
        info["ping_sent_via"] = "page composer, link down"
        if sent.get("error"):
            info["ping_error"] = str(sent["error"])[:300]

    if case in ("update-midturn", "app-sigkill"):
        watch.paused.set()
        if case == "update-midturn":
            rr.quit_app(run.sock, run.bundle, updater=True)
            run.generation += 1
            rr.replace_bundle(run.bundle, run.generation)
        else:
            signal_all([run.pid], signal.SIGKILL)
            bm.still_running({run.pid}, 10)
        relaunched = time.monotonic()
        run.launch()
        watch.paused.clear()
        info["fault_end"] = relaunched
        ping_on_page()
        return info
    if case in ("daemon-sigterm", "daemon-sigkill"):
        signal_all(rr.daemon_pids(run.bundle), signal.SIGTERM if case == "daemon-sigterm" else signal.SIGKILL)
        info["fault_end"] = time.monotonic()
        ping_on_page()
        return info
    if case == "sleep-wake-sim":
        pids = {run.pid} | rr.daemon_pids(run.bundle)
        watch.paused.set()
        signal_all(pids, signal.SIGSTOP)
        time.sleep(run.args.sleep)  # test script: the simulated sleep
        signal_all(pids, signal.SIGCONT)
        watch.paused.clear()
        info["fault_end"] = time.monotonic()
        info["note"] = f"SIGSTOP/SIGCONT {run.args.sleep:.0f} s simulation; no wake notification, no network drop"
        ping_on_page()
        return info
    if case == "daemon-hung":
        stopped = rr.daemon_pids(run.bundle)
        signal_all(stopped, signal.SIGSTOP)
        info["fault_end"] = time.monotonic()  # the daemon stays stopped: recovery is counted from the stop
        info["note"] = f"daemon {sorted(stopped)} SIGSTOPped for the whole case, SIGCONT at its end"
        info["cleanup"] = lambda: signal_all(stopped, signal.SIGCONT)
        ping_on_page()
        return info
    if case == "socket-gone":
        path = run.cli_env["ACPMUX_SOCKET"]
        away = path + ".chaos-away"
        os.rename(path, away)
        threading.Thread(target=ping_on_page, daemon=True).start()
        time.sleep(20)  # test script: the socket stays gone this long
        if os.path.exists(path):
            info["note"] = "the daemon made a new socket while the old one was away"
            os.remove(away)
        else:
            os.rename(away, path)
        info["fault_end"] = time.monotonic()
        return info
    if case == "ws-port-block":
        port = ws_port(run)
        if not port:
            return {"not_run": "no loopback WebSocket port found on the daemon"}
        ok, token = pf_block(port)
        if not ok:
            return {"not_run": f"needs root for pf (sudo -n pfctl: {token})"}
        try:
            threading.Thread(target=ping_on_page, daemon=True).start()
            time.sleep(20)  # test script: the port stays blocked this long
        finally:
            pf_unblock(token)
        info["fault_end"] = time.monotonic()
        info["note"] = f"pf block of 127.0.0.1:{port}"
        return info
    raise SystemExit(f"conn-chaos: unknown case {case}")


def run_case(run: Run, case: str) -> dict:
    tag = re.sub(r"[^a-z]", "", case)[:10] + uuid.uuid4().hex[:4]
    nonce = uuid.uuid4().hex[:10]
    ping = f"chaos-ping: {nonce}"
    result: dict = {"case": case, "bound_s": BOUND[case], "failures": []}
    session = load.new_session(run.app.cli_path, run.cli_env, f"chaos {case}")
    if not session or not load.open_workspace(run.app, session):
        result["failures"].append("could not open a chat on the test agent")
        return result
    result["session"] = session
    sent = subprocess.run([run.app.cli_path, "acp", "send", "--no-wait", session, f"chaos-stream: {tag} {COUNT} {RATE}"],
                          capture_output=True, text=True, timeout=60, env=run.cli_env)
    if sent.returncode != 0:
        result["failures"].append(f"stream send: {(sent.stdout + sent.stderr).strip()[:300]}")
        return result
    watch = Watch(run, session)
    watch.start()
    time.sleep(FAULT_AT_S)  # test script: the turn streams before the fault
    fault_start = time.monotonic()
    try:
        info = inject(run, case, watch, ping)
    except Exception as error:  # a fault the harness could not inject is a harness failure, reported as one
        info = {"fault_end": time.monotonic(), "harness_error": repr(error)[:300]}
        result["failures"].append(f"harness: {error!r}"[:300])
    cleanup = info.pop("cleanup", None)
    result.update({k: v for k, v in info.items() if k != "fault_end"})
    if info.get("not_run"):
        watch.stop.set()
        result["status"] = "not-run"
        return result
    fault_end = info["fault_end"]
    result["fault_s"] = round(fault_end - fault_start, 1)
    # Wait for the turn to end on the agent's side, then for the page to show the ping's answer.
    deadline = fault_end + BOUND[case] + COUNT / RATE + 30
    while time.monotonic() < deadline:
        state = run.pane("chat_state", timeout=5)
        text = (state.get("lastAssistant") or {}).get("text") or ""
        if f"pong {nonce}" in text and not state.get("isWorking"):
            break
        time.sleep(1)  # test script: waiting for the turn and the ping to finish
    # The stream's reply, read while the ping (5 s on the agent) still holds it as the last reply: chat_state
    # keeps the whole last assistant row; the store holds every row.
    watch.stop.set()
    watch.join(5)
    if cleanup:
        cleanup()
    connected = watch.connected_since(fault_end)
    result["recovery_s"] = None if connected is None else round(connected - fault_end, 1)
    if connected is None or connected - fault_end > BOUND[case]:
        result["failures"].append(f"no recovery within {BOUND[case]} s (connected after {result['recovery_s']})")
    late = watch.seen  # CONTRACT.md: never, at any moment of the case
    if late:
        result["failures"].append(f"page showed {sorted({s['pattern'] for s in late})}: {late[0]['text']!r}")
    result["forbidden_seen"] = late[:5]
    entries = run.agent_entries()
    # By tag (one per case): the agent logs its own session id, not the chat's.
    streams = [e for e in entries if str(e.get("text", "")).startswith(f"chaos-stream: {tag} ")]
    pings = [e for e in entries if e.get("text") == ping]
    ends = [e for e in entries if e.get("tag") == tag and "end" in e]
    result["deliveries"] = {"stream": len(streams), "ping": len(pings)}
    if len(streams) != 1:
        result["failures"].append(f"stream prompt given to the agent {len(streams)} times (want 1)")
    if len(pings) != 1:
        result["failures"].append(f"down-time prompt given to the agent {len(pings)} times (want 1)"
                                  + (f"; page send: {info['ping_error']}" if info.get("ping_error") else ""))
    agent_sent = ends[-1]["sent"] if ends else None
    result["agent_words"] = agent_sent
    if not ends or ends[-1]["end"] != "end_turn" or agent_sent != COUNT:
        result["failures"].append(f"the agent's turn did not run to its end ({ends[-1] if ends else 'no end'})")
    store_gap = whole(words_of(store_text(run, session), tag), COUNT)
    if store_gap:
        result["failures"].append(f"store reply not whole: {store_gap}")
    state = run.pane("chat_state", timeout=10)
    rows = json.dumps(state.get("transcript") or [])
    page_numbers = words_of(rows, tag)
    if not page_numbers:
        result["failures"].append("the reply is not on the page after recovery")
    pongs = len(re.findall(rf"pong {nonce}", rows))
    if pongs != 1:
        result["failures"].append(f"the down-time prompt's answer shows {pongs} times on the page (want 1)")
    prompt_rows = [p for p in state.get("prompts") or [] if p.get("text") == ping]
    if len(prompt_rows) != 1 or prompt_rows[0].get("pending"):
        result["failures"].append(f"the down-time prompt's row on the page: {prompt_rows}")
    if state.get("missingSession") or state.get("unavailable"):
        result["failures"].append(f"chat unavailable: {state.get('missingSession') or state.get('unavailable')}")
    result["samples"] = len(watch.samples)
    return result


def verdict(result: dict) -> str:
    if result.get("status") == "not-run":
        return "not-run"
    failed = bool(result["failures"])
    # A suite that could not drive the case judged nothing: that is a failure even under a mark.
    if any(f.startswith(("harness:", "could not open", "stream send:")) for f in result["failures"]):
        return "fail"
    if result["case"] in XFAIL:
        return "xfail" if failed else "xpass"
    return "fail" if failed else "pass"


def refuse_leo_machines():
    names = set()
    for argv in (["scutil", "--get", "ComputerName"], ["scutil", "--get", "LocalHostName"], ["hostname", "-s"]):
        try:
            names.add(subprocess.run(argv, capture_output=True, text=True, timeout=5).stdout.strip().lower())
        except (OSError, subprocess.SubprocessError):
            pass
    bad = {n for n in names for leo in ("cosmic-gray", "air-blue", "huge-blue", "big-red") if leo in n.replace(" ", "-")}
    if bad and not os.environ.get("AGENT_CONN_CHAOS_ANY_HOST"):
        raise SystemExit(f"conn-chaos: refusing to run on {sorted(bad)}: Leo's machines and big-red are off limits "
                         "(fleet Macs through cmux-ci only)")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--app", required=True, help="a built DEV bundle (its bundle id must contain .debug.)")
    parser.add_argument("--cases", default=",".join(CASES))
    parser.add_argument("--sleep", type=float, default=35)
    parser.add_argument("--out")
    args = parser.parse_args(argv)
    refuse_leo_machines()
    cases = [c for c in args.cases.split(",") if c]
    for case in cases:
        if case not in CASES:
            raise SystemExit(f"conn-chaos: unknown case {case} (known: {', '.join(CASES)})")
    signal.signal(signal.SIGTERM, bm.interrupted)
    bp.wipe_state(args.app)
    run = Run(args)
    results = []
    try:
        for case in cases:
            log(f"case {case}")
            try:
                result = run_case(run, case)
            except Exception as error:
                result = {"case": case, "failures": [f"harness: {error!r}"[:400]]}
            result["verdict"] = verdict(result)
            if result["case"] in XFAIL:
                result["xfail_until"] = XFAIL[result["case"]]
            results.append(result)
            waits = f" waits_on={XFAIL[case]}" if case in XFAIL else ""
            print(f"AGENT-CONN-CHAOS case={case} verdict={result['verdict'].upper()}{waits} recovery_s={result.get('recovery_s')} "
                  f"bound_s={result.get('bound_s')} failures={json.dumps(result['failures'])}", flush=True)
    finally:
        run.close()
    print("AGENT-CONN-CHAOS-TABLE-BEGIN")
    print("| case | verdict | recovery s | bound s | failures |\n|---|---|---|---|---|")
    for r in results:
        print(f"| {r['case']} | {r['verdict']} | {r.get('recovery_s')} | {r.get('bound_s')} | "
              f"{'; '.join(r['failures']) or r.get('not_run') or ''} |")
    print("AGENT-CONN-CHAOS-TABLE-END", flush=True)
    if args.out:
        with open(args.out, "w") as handle:
            json.dump({"app": args.app, "results": results}, handle, indent=1)
    bad = [r for r in results if r["verdict"] in ("fail", "xpass")]
    return 1 if bad or not results else 0


if __name__ == "__main__":
    sys.exit(main())
