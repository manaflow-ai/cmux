"""Measure the visible coordinator's CEF process while twenty ACP children update at 1 Hz."""
import argparse
from collections import Counter, defaultdict
import json
from pathlib import Path
import platform
import plistlib
import re
import shutil
import subprocess
import time

import bench_memory as bm
from bench_acpmux_chat_memory import Rpc
from chat_renderer_crash import chat_pages, evaluate
from idle_cost_load import new_session, open_workspace


HISTORY_ROWS = 10_000
CHILDREN = 20
STATE = """(() => {
  const s = window.cmuxAcpmuxDebug?.chatState();
  return JSON.stringify({session: s?.sessionId, rows: s?.rows, older: s?.canLoadOlder,
    working: s?.isWorking, visible: !document.hidden,
    tray: document.querySelector('.acpmux-running-tray__head')?.textContent});
})()"""


def renderer(app, session):
    for page in chat_pages(app):
        if page["hidden"] or not page["renderer"]:
            continue
        value, error = evaluate(app, page["browser"], STATE)
        state = json.loads(value) if value and not error else {}
        if state.get("visible") and state.get("session") == session:
            return page, state
    raise RuntimeError(f"no visible CEF page for coordinator {session}")


def cpu_point(pid):
    began = time.monotonic()
    value = subprocess.check_output(["/bin/ps", "-p", str(pid), "-o", "time="], text=True).strip()
    wall = (began + time.monotonic()) / 2
    days, _, clock = value.rpartition("-")
    seconds = 0.
    for field in clock.split(":"):
        seconds = 60 * seconds + float(field)
    return {"wall": wall, "epoch": time.time(), "cpu": seconds + int(days or 0) * 86400}


def cpu_window(pid, intervals):
    samples = [cpu_point(pid)]
    for _ in range(intervals):
        time.sleep(5)
        samples.append(cpu_point(pid))
    first, last = samples[0], samples[-1]
    return {"samples": samples, "percent": 100 * (last["cpu"] - first["cpu"]) / (last["wall"] - first["wall"])}


def tail(rpc, sid, limit):
    return rpc.call("_acpmux/events", {"sessionId": sid, "beforeSeq": 2**63 - 1, "limit": limit})["events"]


def tick_receipt(rpc, sid, start, stop):
    ticks = defaultdict(list)
    for event in tail(rpc, sid, 2500):
        when = event["at"] / 1000
        if not start <= when <= stop or event["kind"] != "tool_call_update":
            continue
        params = event["msg"]["params"]
        child = params.get("_meta", {}).get("acpmux", {}).get("subagent")
        match = re.fullmatch(r"Checking part, tick (\d+)", params.get("update", {}).get("title", ""))
        if child and match:
            ticks[child].append((int(match[1]), when))
    if len(ticks) != CHILDREN:
        raise RuntimeError(f"daemon received ticks from {len(ticks)} children in the measured window")
    for child, values in ticks.items():
        values.sort()
        seq = [v[0] for v in values]
        if (len(seq) < stop - start - 2 or len(seq) > stop - start + 2
                or seq != list(range(seq[0], seq[-1] + 1))
                or any(b[1] - a[1] > 2 for a, b in zip(values, values[1:]))):
            raise RuntimeError(f"{child} missed the 1 Hz workload: {values}")
    return ticks


def js_profile(app, browser, out):
    def command(method):
        reply = app.call("debug.cef_page_devtools", {"browser": browser, "method": method, "params": {}}, timeout=45)
        if not reply or reply.get("error") or "result" not in reply:
            raise RuntimeError(f"{method}: {str(reply)[:240]}")
        return json.loads(reply["result"])

    command("Profiler.enable")
    try:
        command("Profiler.start")
        time.sleep(5)
        profile = command("Profiler.stop")["profile"]
    finally:
        command("Profiler.disable")
    (out / "coordinator.cpuprofile").write_text(json.dumps(profile))
    nodes = {n["id"]: n["callFrame"] for n in profile["nodes"]}
    weights = Counter()
    for key, duration in zip(profile["samples"], profile["timeDeltas"]):
        frame = nodes[key]
        weights[(frame["functionName"], frame["url"], frame["lineNumber"] + 1, frame["columnNumber"] + 1)] += duration
    return [{"function": key[0], "url": key[1], "line": key[2], "column": key[3], "self_us": us}
            for key, us in weights.most_common(20)]


def measure(app, bundle, out):
    chats = bm.FakeChats(app, bundle, str(Path(__file__).with_name("chat_open_agent.py")))
    session = new_session(app.cli_path, chats.env, "Ready")
    if not session:
        raise RuntimeError("failed to start coordinator")
    cli = [app.cli_path, "acp", "send"]
    subprocess.run(cli + [session, f"rows: {HISTORY_ROWS}"], env=chats.env, check=True,
                   stdout=subprocess.DEVNULL, timeout=300)
    rpc = Rpc(chats.env["ACPMUX_SOCKET"])
    try:
        seed = tail(rpc, session, 30)
        marker = f"Row {HISTORY_ROWS // 2 - 1}:"
        if not any(marker in str(e["msg"]) for e in seed):
            raise RuntimeError("last seeded history row missing from the coordinator log")
        if not open_workspace(app, session):
            raise RuntimeError("failed to open coordinator")
        page, state = renderer(app, session)
        pid = page["renderer"]
        time.sleep(5)
        idle = cpu_window(pid, 1)
        subprocess.run(cli + ["--no-wait", session, "coordinator ticks"], env=chats.env,
                       check=True, stdout=subprocess.DEVNULL, timeout=30)
        time.sleep(5)
        live_page, live_state = renderer(app, session)
        if live_page != page or not live_state.get("working") or not live_state.get("tray"):
            raise RuntimeError(f"coordinator is not showing running children: {live_page}, {live_state}")
        live = cpu_window(pid, 3)
        start, stop = (live["samples"][index]["epoch"] for index in (0, -1))
        ticks = tick_receipt(rpc, session, start, stop)
        print(f"Coordinator renderer {pid}: {live['percent']:.2f}% CPU, {len(ticks)} ticking children", flush=True)
        profile_start = time.time()
        frames = js_profile(app, page["browser"], out)
        subprocess.run(["/usr/bin/sample", str(pid), "5", "-file", str(out / "renderer.sample.txt")],
                       check=True, timeout=30)
        profile_ticks = tick_receipt(rpc, session, profile_start, time.time())
        final_page, final_state = renderer(app, session)
        if final_page != page:
            raise RuntimeError(f"renderer changed during measurement: {page} -> {final_page}")
        return {"session": session, "history_rows": HISTORY_ROWS, "seed_last_seq": max(e["seq"] for e in seed),
                "page": page, "seed_state": state, "live_state": live_state, "final_state": final_state,
                "long_chat_idle": idle, "coordinator_live": live, "ticks": ticks, "js_top_self": frames,
                "profile_ticks": profile_ticks}
    finally:
        rpc.sock.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True)
    parser.add_argument("--sha", required=True)
    parser.add_argument("--out", required=True, type=Path)
    args = parser.parse_args()
    with open(Path(args.app) / "Contents/Info.plist", "rb") as file:
        info = plistlib.load(file)
    if info.get("CMUXCommit") != args.sha or info.get("CMUXCommitDirty"):
        raise SystemExit(f"expected clean {args.sha}, got {info.get('CMUXCommit')}, dirty={info.get('CMUXCommitDirty')}")
    args.out.mkdir(parents=True, exist_ok=True)
    _, sock, scratch = bm.launch(args.app, {}, direct=True)
    try:
        app = bm.App(args.app, sock)
        deadline = time.monotonic() + 60
        while not app.ping():
            if time.monotonic() >= deadline:
                raise RuntimeError("cmux app socket did not answer")
            time.sleep(0.5)
        report = measure(app, args.app, args.out)
        report.update({"app_sha": args.sha, "harness_sha": subprocess.check_output(["git", "rev-parse", "HEAD"],
                       text=True).strip(), "machine": platform.node(), "macos": platform.mac_ver()[0]})
        (args.out / "report.json").write_text(json.dumps(report, indent=2) + "\n")
        print("COORDINATOR-CPU " + json.dumps({k: report[k] for k in
              ("app_sha", "harness_sha", "machine", "history_rows", "coordinator_live", "js_top_self")}), flush=True)
    finally:
        bm.end_bundle(args.app)
        shutil.rmtree(scratch)


if __name__ == "__main__":
    main()
