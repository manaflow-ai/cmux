"""The `--modes agentcdp` row of chromium-host-bench.py (p01-process-233): agent CDP straight from the browser host to
the Chromium Host, never through cmux's main thread (feature chromiumHostAgentRelay, which the bench turns on for this
mode). A Chromium tab of the app's backend in the Chromium Host (`debug.cef` backend `host`) is opened and then hidden
behind a terminal tab of the same pane, as an agent's background tab is; an agent session of the app's own browser host
(`cmux-browser-host eval --session ... --engine cef`, `tabs.use(<tab>)`) then sends RATE CDP messages a second (each
`page.evaluate` is a command and its reply, 2 messages) for SECONDS, while the bench types into the focused terminal.

  rate        messages the session got through, the seconds it took and its errors (pass: >= 90 % of RATE x SECONDS,
              no error)
  main_turns  `debug.main_budget` after a reset at the start of the burst: the main-thread tasks of each
              `browser-host.cdp*` owner (BrowserHostProvider's frame tasks). `browser-host.cdp` is one task per CDP
              frame the app relays itself; pass: 0 of it (the one prepare and the capture votes are not per message)
  key         terminal key-to-frame during the burst (the typing probe's `contents_ms`, CMUX_NEXT_TYPING_PROBE),
              p50/p95/p99/max; pass: p99 <= KEY_P99_MS (one 60 Hz frame)

The row says what the app's main-thread scheduler counted. For the full timeline (every thread, the app's main-thread
turns with their stacks), run the bench under trace.py's wrap mode, which records while it runs:
  python3 scripts/cmux-next/trace.py record --bundle APP --out DIR -- \\
    python3 scripts/cmux-next/chromium-host-bench.py --app APP --out DIR/bench --modes agentcdp

--kill-app adds `kill_app` (last: it SIGKILLs cmux): with the agent's tab open, cmux is killed with SIGKILL and launched
again. Pass when the Chromium Host outlived the kill, the relaunched cmux serves the same page (its
performance.timeOrigin is unchanged: no reload) and the agent session drives it again. The host outliving cmux is task
p01-process-150's `browserHost.survivesAppCrash`; a build without it ends the host with cmux, and the row says so and
fails.

Without the host backend the row says so and the mode fails: it could not run.
"""
import json
import os
import signal

RATE = 1000  # CDP messages a second (commands and replies)
SECONDS = 10.0
KEY_INTERVAL_S = 0.05
KEY_P99_MS = 16.7
MIN_SHARE = 0.9
SESSION = "chromium-host-agentcdp"
# The per-message owner: one main-thread task per `cdp` frame the app relays itself (BrowserHostProvider+Frames.swift).
PER_MESSAGE_OWNER = "browser-host.cdp"
HOST_SURVIVAL_S = 5.0

PAGE = """<!doctype html><meta charset=utf-8><title>agent cdp probe</title>
<style>html,body{margin:0;height:100%;background:#402060;color:#fff;font:16px system-ui}</style>
<p>agent cdp probe</p>"""


def agent_script(url, rate=RATE, seconds=SECONDS):
    """REPL code that claims the tab showing `url` for the session (the browser host's `cdp.prepare`) and prints one
    JSON line: the tab id and its performance.timeOrigin, and with `rate` messages a second for `seconds` (rate 0:
    none) the messages it got through, the errors and the seconds the burst took. Commands go in 100 ms slices of
    concurrent evaluates, so the rate does not depend on one round trip's latency."""
    per_slice = max(1, round(rate / 2 / 10)) if rate else 0
    slices = int(round(seconds * 10)) if rate else 0
    return "\n".join([
        "const all = await tabs.list({ all: true });",
        f"const hit = all.find((t) => t.url === {json.dumps(url)});",
        f"if (!hit) throw new Error('no tab shows ' + {json.dumps(url)});",
        "const page = await tabs.use(hit.id);",
        "const origin = await page.evaluate(() => performance.timeOrigin);",
        "let messages = 0, errors = 0;",
        "const t0 = Date.now();",
        f"for (let slice = 0; slice < {slices}; slice++) {{",
        "  const batch = [];",
        f"  for (let i = 0; i < {per_slice}; i++) batch.push(page.evaluate(() => 1).then(() => {{ messages += 2; }}, () => {{ errors++; }}));",
        "  await Promise.all(batch);",
        "  const rest = t0 + (slice + 1) * 100 - Date.now();",
        "  if (rest > 0) await new Promise((r) => setTimeout(r, rest));",
        "}",
        "console.log(JSON.stringify({ id: hit.id, origin, messages, errors, seconds: (Date.now() - t0) / 1000 }));",
    ])


def parse_agent(stdout):
    """The last JSON object line the agent script printed, or None."""
    for line in reversed((stdout or "").splitlines()):
        line = line.strip()
        if line.startswith("{"):
            try:
                value = json.loads(line)
            except ValueError:
                continue
            if isinstance(value, dict):
                return value
    return None


def cdp_owner_tasks(budget):
    """{owner: tasks} of the `browser-host.cdp*` owners in a `debug.main_budget` report."""
    owners = (budget or {}).get("owners") if isinstance(budget, dict) else None
    out = {}
    for row in owners or []:
        owner = row.get("owner") if isinstance(row, dict) else None
        if isinstance(owner, str) and owner.startswith(PER_MESSAGE_OWNER):
            out[owner] = out.get(owner, 0) + int(row.get("tasks") or 0)
    return out


def percentiles(values):
    """n/p50/p95/p99/max of `values` (linear interpolation, as perf_stats.py), or None for none."""
    values = sorted(float(v) for v in values if v is not None)
    if not values:
        return None

    def at(q):
        position = (len(values) - 1) * q
        low = int(position)
        high = min(low + 1, len(values) - 1)
        return round(values[low] + (values[high] - values[low]) * (position - low), 3)

    return {"n": len(values), "p50": at(0.5), "p95": at(0.95), "p99": at(0.99), "max": round(values[-1], 3)}


def judge(rate, agent, cdp_tasks, key, rate_s=SECONDS):
    """The row's pass from its parts (the module docs)."""
    expected = rate * rate_s
    got = (agent or {}).get("messages") or 0
    checks = {
        "rate": bool(agent) and not agent.get("errors") and got >= MIN_SHARE * expected,
        "main_turns": cdp_tasks.get(PER_MESSAGE_OWNER, 0) == 0,
        "key": bool(key) and key["p99"] <= KEY_P99_MS,
    }
    return checks, all(checks.values())


def run(rpc, wait, page_eval, url, agent, type_keys, typed_ms, rate=RATE, seconds=SECONDS):
    """The row; returns (row, ok). `agent(script, timeout)` starts the agent session's eval and returns a handle
    whose `.result()` is (exit code, stdout, stderr) once it ends; `type_keys(seconds)` types into the focused
    terminal for that long; `typed_ms()` is the typing probe's key-to-frame values so far."""
    backend = (rpc("debug.cef") or {}).get("backend")
    if backend != "host":
        return {"not_run": f"the Chromium backend is {backend!r}, not the Chromium Host (a Release build, or "
                           "browserHost.helper off)", "pass": False}, False
    opened = rpc("action.run", {"action": "openBrowser.chromium", "args": {"url": url}, "focus": True,
                                "origin": "script"}, timeout=120)
    if not wait(lambda: page_eval("document.title === 'agent cdp probe' && document.readyState === 'complete'"), 60, 0.5):
        return {"error": f"the probe never loaded: {str(opened)[:200]}", "pass": False}, False
    # The agent's tab goes to the background: a terminal tab in front of it takes the keys.
    rpc("action.run", {"action": "newTab", "focus": True, "origin": "script"}, timeout=60)
    # The first claim prepares the page (rebuilt for the agent, then named to the browser host): not in the burst.
    warm = agent(agent_script(url, rate=0), 120).result()
    if warm[0] != 0 or not parse_agent(warm[1]):
        return {"error": f"the agent session did not drive the tab: {(warm[2] or warm[1]).strip()[:400]}",
                "pass": False}, False
    before = len(typed_ms())
    rpc("debug.main_budget", {"reset": True}, timeout=20)
    burst = agent(agent_script(url, rate, seconds), seconds + 120)
    type_keys(seconds)
    code, out, err = burst.result()
    budget = rpc("debug.main_budget", timeout=20)
    report = parse_agent(out)
    tasks = cdp_owner_tasks(budget)
    key = percentiles(typed_ms()[before:])
    checks, ok = judge(rate, report, tasks, key, seconds)
    row = {"rate_per_s": rate, "seconds": seconds, "agent": report or {"exit": code, "stderr": (err or "")[:400]},
           "main_turns": tasks, "key_to_frame_ms": key, "checks": checks, "pass": ok}
    return row, True


def kill_app(app_pid, host_pid, relaunch, agent, url, alive, sleep):
    """The --kill-app row (module docs); returns (row, ok). `app_pid` and `host_pid` are cmux's and the Chromium Host's
    pids before the kill; `relaunch()` launches cmux again; `alive(pid)` is whether a pid still runs; `sleep` the
    harness wait."""
    if not app_pid or not host_pid:
        return {"error": "no cmux process or no Chromium Host runs", "pass": False}, False
    before = agent(agent_script(url, rate=0), 120).result()
    origin = (parse_agent(before[1]) or {}).get("origin")
    if origin is None:
        return {"error": f"the agent session did not drive the tab: {(before[2] or before[1]).strip()[:400]}",
                "pass": False}, False
    os.kill(app_pid, signal.SIGKILL)
    sleep(HOST_SURVIVAL_S)  # test harness: the host's crash survival decides within its first seconds
    survived = alive(host_pid)
    row = {"host_survived": survived, "origin_before": origin}
    if not survived:
        row.update({"not_measurable": "the Chromium Host ended with cmux: browserHost.survivesAppCrash "
                                      "(task p01-process-150) is not in this build", "pass": False})
        return row, True
    relaunch()
    after = agent(agent_script(url, rate=0), 180).result()
    report = parse_agent(after[1]) or {}
    row.update({"origin_after": report.get("origin"), "agent_after": report or {"stderr": (after[2] or "")[:400]}})
    row["pass"] = report.get("origin") == origin
    return row, True
