#!/usr/bin/env python3
"""The first real run of the hybrid chat start (cmux#52145) against staging Cloud, on a macOS runner.

    hybrid-start-first-run.py --app APP --cli CLI --credentials-file F --out DIR [--runs 3]

APP is the published, signed NEXT DEV app (launched as cloud-chat-proof.py launches it: its own socket, its own
cmux.json with the Claude login consent, the staging agent account from F, `--cloud-backend staging`). CLI is the
cmux-tui built from this pull request; every hybrid command runs through it against APP's socket.

Runs, each timed with a monotonic clock here (the driver's log carries no times, so its lines are stamped as this
script reads them):
  1. `cmux cloud hybrid-status --json`
  2. RUNS x `CMUX_HYBRID_START=1 cmux chat --on vm:new --prompt PROMPT`: first output, command exit, each driver
     log line (gate, show booting/ready/moving/live/failed, done), the turn's end, the transcript before the move
     and after (prompts, continuation prompts, interruption markers, repeated tool calls).
  3. one follow-up `cmux chat send SESSION TEXT --wait` into the first moved chat.
  4. one `CMUX_HYBRID_START=0` control start with the same prompt (`--wait`, today's Cloud start).
  5. every machine this run made is killed (the list before vs after, and every id a log names).
Evidence: DIR/evidence.json, DIR/summary.md and each driver log. No token is written anywhere.
"""
import argparse, json, os, re, subprocess, sys, tempfile, threading, time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import claude_login_cache  # noqa: E402

PROMPT = "Reply with the word ok, then run: sleep 20; echo done-1; then say finished"
FOLLOW_UP = "What did the sleep command print? Answer in one line."
API_ORIGIN = "https://cloud-api-staging.cmux.dev"

p = argparse.ArgumentParser()
p.add_argument("--app", required=True)
p.add_argument("--cli", required=True)
p.add_argument("--credentials-file", required=True)
p.add_argument("--out", required=True)
p.add_argument("--runs", type=int, default=3)
p.add_argument("--run-deadline", type=int, default=1500, help="seconds one hybrid run may take, driver included")
args = p.parse_args()
OUT = Path(args.out)
OUT.mkdir(parents=True, exist_ok=True)
TAG = f"hfr-{os.environ.get('GITHUB_RUN_ID', str(int(time.time())))}"
SOCKET = f"/tmp/cmux-debug-{TAG}.sock"
TOKEN = claude_login_cache.token_from(os.environ)
ENV = {**os.environ, "CMUX_SOCKET_PATH": SOCKET, "CMUX_NEXT_SOCKET_PATH": SOCKET}
ENV.pop(claude_login_cache.TOKEN_ENV, None)
APP_CLI = str(Path(args.app) / "Contents/Resources/bin/cmux")
CLI = str(Path(args.cli).resolve())
SECRETS = [re.compile(r"(?i)\b(?:cmvm|cmk|crt|crk|cmm|cmj)_[A-Za-z0-9_-]{8,}"),
           re.compile(r"(?i)\bsk-(?:ant-)?[A-Za-z0-9_-]{10,}"),
           re.compile(r"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}"),
           re.compile(r"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]+")]
T0 = time.monotonic()
evidence = {"tag": TAG, "prompt": PROMPT, "steps": [], "runs": [], "machines_killed": [], "machines_left": []}


def redact(text: str) -> str:
    for pattern in SECRETS:
        text = pattern.sub("[redacted]", text)
    if TOKEN:
        text = text.replace(TOKEN, "[redacted]")
    return text


def ms(since: float) -> int:
    return round((time.monotonic() - since) * 1000)


def save() -> None:
    (OUT / "evidence.json").write_text(redact(json.dumps(evidence, indent=2, default=str)))


def run(words, *, cli=CLI, env=None, timeout=120) -> dict:
    started = time.monotonic()
    try:
        done = subprocess.run([cli, *words], env=env or ENV, capture_output=True, text=True, timeout=timeout)
        code, out, err = done.returncode, done.stdout, done.stderr
    except subprocess.TimeoutExpired as e:
        code, out, err = 124, (e.stdout or b"").decode() if isinstance(e.stdout, bytes) else (e.stdout or ""), \
            f"timed out after {timeout}s"
    return {"words": words, "code": code, "ms": ms(started), "out": redact(out)[-6000:], "err": redact(err)[-4000:]}


def parsed(text: str):
    try:
        return json.loads(text)
    except (ValueError, TypeError):
        for line in reversed((text or "").splitlines()):
            try:
                return json.loads(line)
            except ValueError:
                continue
    return {}


def step(name: str, result: dict) -> dict:
    result["name"] = name
    evidence["steps"].append(result)
    print(f"[{ms(T0):>8} ms] {name}: exit {result['code']} in {result['ms']} ms", flush=True)
    if result["code"] != 0:
        print(f"    stderr: {result['err'][-1500:]}\n    stdout: {result['out'][-1500:]}", flush=True)
    save()
    return result


def machines() -> dict:
    listed = parsed(run(["cloud", "list-machines", "--json"])["out"])
    rows = (listed.get("result") or listed).get("machines") if isinstance(listed, dict) else None
    return {r["machine_id"]: r for r in rows or [] if isinstance(r, dict) and r.get("machine_id")}


def transcript(session: str) -> dict:
    """Counts from `agents chat read`: the person's prompts, continuation prompts, interruption markers, tool calls
    (and repeats of the same command)."""
    got = run(["agents", "chat", "read", session, "--limit", "200", "--json"], timeout=60)
    text = got["out"]
    value = parsed(text)
    items = (value.get("result") or value).get("items") if isinstance(value, dict) else None
    items = items if isinstance(items, list) else []
    prompts = [i for i in items if isinstance(i, dict) and i.get("role") in ("user", "person", "prompt")
               or (isinstance(i, dict) and i.get("kind") in ("prompt", "user_message"))]
    tools = [json.dumps(i.get("input") or i.get("title") or i.get("command") or "")
             for i in items if isinstance(i, dict) and (i.get("kind") in ("tool_call", "tool") or i.get("toolCallId"))]
    return {
        "code": got["code"], "items": len(items), "prompts": len(prompts),
        "continuations": len(re.findall(r"(?i)continu(?:e|ation)[^\"]{0,80}(?:move|machine|where you)", text)),
        "interrupted_markers": text.count("[Request interrupted"),
        "tool_calls": len(tools), "repeated_tool_calls": len(tools) - len(set(tools)),
        "sleep_calls": text.count("sleep 20"), "done_1": text.count("done-1"), "finished": text.lower().count("finished"),
        "raw_tail": text[-3000:] if got["code"] == 0 else got["err"][-1500:],
    }


def follow_log(path: Path, lines: list, stop: threading.Event) -> None:
    """Stamps each driver log line as it appears (ms since the run's command started is added by the caller)."""
    seen = 0
    while not stop.is_set():
        try:
            body = path.read_text()
        except OSError:
            body = ""
        new = body[seen:]
        if "\n" in new:
            complete, _, _ = new.rpartition("\n")
            for line in complete.split("\n"):
                lines.append((time.monotonic(), redact(line)))
            seen += len(complete) + 1
        stop.wait(0.2)


OK_WORD = re.compile(r'(?i)"(?:text|content|delta|message|value)"\s*:\s*"[^"]{0,200}\bok\b')


def first_token(session: str, started: float, out: dict, stop: threading.Event) -> None:
    """The local chat's first agent text: polls `agents chat read` every 250 ms from the start's exit until the
    reply's "ok" is in it (ok_ms), noting when the transcript first grew past its first read (grew_ms)."""
    first = None
    while not stop.is_set() and "ok_ms" not in out:
        got = run(["agents", "chat", "read", session, "--limit", "50", "--json"], timeout=20)
        at = round((time.monotonic() - started) * 1000)
        text = got["out"] if got["code"] == 0 else ""
        if text and first is None:
            first = len(text)
        elif text and "grew_ms" not in out and len(text) > first:
            out["grew_ms"] = at
        if OK_WORD.search(text):
            out["ok_ms"] = at
            out["at_ok"] = text[-1500:]
        stop.wait(0.25)


def hybrid_run(index: int) -> dict:
    env = {**ENV, "CMUX_HYBRID_START": "1"}
    started = time.monotonic()
    proc = subprocess.Popen([CLI, "chat", "--on", "vm:new", "--prompt", PROMPT], env=env,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    stream: list = []

    def pump(pipe, name):
        for line in pipe:
            stream.append((time.monotonic(), name, redact(line.rstrip("\n"))))
    threads = [threading.Thread(target=pump, args=(proc.stdout, "out"), daemon=True),
               threading.Thread(target=pump, args=(proc.stderr, "err"), daemon=True)]
    for t in threads:
        t.start()
    try:
        code = proc.wait(timeout=300)
    except subprocess.TimeoutExpired:
        proc.kill()
        code = 124
    for t in threads:
        t.join(5)
    exited = ms(started)
    r = {"index": index, "command_exit": code, "command_ms": exited,
         "first_output_ms": round((stream[0][0] - started) * 1000) if stream else None,
         "output": [(round((t - started) * 1000), n, l) for t, n, l in stream]}
    text = "\n".join(l for _, _, l in stream)
    log = re.search(r"\(log: ([^)]+)\)", text)
    session = re.search(r"\b([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\b", text)
    started_json = parsed(text)
    if isinstance(started_json, dict):
        sid = (started_json.get("result") or started_json).get("session_id") or (started_json.get("result") or started_json).get("id")
        if isinstance(sid, str):
            r["session"] = sid
    if session and "session" not in r:
        r["session"] = session.group(1)
    r["log_path"] = log.group(1) if log else None
    if r["log_path"] and "session" not in r:
        r["session"] = Path(r["log_path"]).stem
    print(f"[run {index}] exit {code} first output {r['first_output_ms']} ms, command {exited} ms, "
          f"session {r.get('session')}, log {r['log_path']}", flush=True)
    if not r["log_path"] or not r.get("session"):
        r["failure"] = "the start named no driver log or session (hybrid start did not take this start)"
        return r
    lines: list = []
    stop = threading.Event()
    follower = threading.Thread(target=follow_log, args=(Path(r["log_path"]), lines, stop), daemon=True)
    follower.start()
    token: dict = {}
    watcher = threading.Thread(target=first_token, args=(r["session"], started, token, stop), daemon=True)
    watcher.start()
    r["transcript_start"] = transcript(r["session"])
    deadline = started + args.run_deadline
    while time.monotonic() < deadline and not any('"done"' in l for _, l in lines):
        time.sleep(0.5)
    stop.set()
    follower.join(2)
    watcher.join(5)
    r["first_token"] = token
    r["first_token_s"] = round(token["ok_ms"] / 1000, 2) if token.get("ok_ms") is not None else None
    r["driver_log"] = [(round((t - started) * 1000), l) for t, l in lines]
    r["driver_done"] = any('"done"' in l for _, l in lines)
    for t, l in lines:
        value = parsed(l)
        show = value.get("show") if isinstance(value, dict) else None
        if isinstance(show, dict):
            r.setdefault("show_ms", {}).setdefault(str(show.get("cloud")), round((t - started) * 1000))
            if show.get("machine"):
                r["machine"] = show["machine"]
            if show.get("reason"):
                r.setdefault("reasons", []).append(show["reason"])
        if "gate" in l and " ms" in l:
            r["gate_line"] = l
    shows = r.get("show_ms", {})
    moving = next((shows[k] for k in shows if "mov" in k.lower()), None)
    live = next((shows[k] for k in shows if "live" in k.lower()), None)
    ready = next((shows[k] for k in shows if "ready" in k.lower()), None)
    r["machine_ready_ms"] = ready if ready is not None else moving
    r["machine_ready_from"] = "ready line" if ready is not None else ("move start (no ready line)" if moving is not None else None)
    r["machine_ready_s"] = round(r["machine_ready_ms"] / 1000, 2) if r["machine_ready_ms"] is not None else None
    r["move_ms"] = (live - moving) if live is not None and moving is not None else None
    r["live_ms"] = live
    # The turn's end, wherever the chat runs now.
    waited = run(["chat", "wait", r["session"], "--timeout", "300", "--json"], timeout=330)
    r["turn_wait"] = {k: waited[k] for k in ("code", "ms", "out", "err")}
    r["turn_end_ms"] = ms(started)
    reply = parsed(waited["out"])
    reply = (reply.get("result") or reply).get("reply") if isinstance(reply, dict) else None
    r["reply"] = reply
    r["agents_ls"] = next((row for row in (parsed(run(["agent", "ls", "--json"])["out"]) or {}).get("result", {}).get("sessions", [])
                          if isinstance(row, dict) and r["session"] in json.dumps(row)), None) \
        if isinstance(parsed(run(["agent", "ls", "--json"])["out"]), dict) else None
    r["agent_ls_raw"] = run(["agent", "ls", "--json"])["out"][-4000:]
    r["transcript_end"] = transcript(r["session"])
    return r


def kill_all(before: set) -> None:
    named = {r.get("machine") for r in evidence["runs"] if r.get("machine")} | {evidence.get("control_machine")}
    after = machines()
    mine = (set(after) - before) | {m for m in named if m}
    for machine in sorted(mine):
        got = run(["cloud", "kill-machine", "--target", f"machine:{machine}", "--confirm", "--json"], cli=APP_CLI, timeout=120)
        evidence["machines_killed"].append({"machine": machine, "code": got["code"], "err": got["err"][-500:]})
        print(f"kill {machine}: exit {got['code']}", flush=True)
    left = set(machines()) - before
    evidence["machines_left"] = sorted(left)
    save()


# 1. The app, as cloud-chat-proof.py launches it.
config_dir = Path(tempfile.mkdtemp(prefix="hfr-config-"))
config = config_dir / "cmux-next.json"
config.touch(mode=0o600)
config.write_text(json.dumps({"cloud": {"useMyClaudeLoginOnMyCloudMachines": True}}) + "\n")
ENV["CMUX_NEXT_CONFIG_FILE"] = str(config)
creds = str(Path(args.credentials_file).resolve())
launch = ["/usr/bin/open", "-W", "-g", "-n", "--env", f"CMUX_NEXT_SOCKET_PATH={SOCKET}",
          "--env", f"CMUX_NEXT_CONFIG_FILE={config}", "--env", f"CMUX_AUTH_CREDENTIALS_FILE={creds}",
          "--env", "CMUX_DEV_AUTH_PROFILE=agent", "--env", "CMUX_DEV_AUTH_REPLACE_SESSION=1"]
if TOKEN:
    # The local chat's Claude (the app's acpmux starts it) signs in with the agent test account's setup-token.
    launch += ["--env", f"{claude_login_cache.TOKEN_ENV}={TOKEN}"]
launch += [str(Path(args.app).resolve()), "--args", "--cloud-backend", "staging"]
launch_log = OUT / "open.log"
launched_at = time.strftime("%Y-%m-%d %H:%M:%S")
app = subprocess.Popen(launch, env=ENV, stdout=launch_log.open("w"), stderr=subprocess.STDOUT)
APP_PATH = str(Path(args.app).resolve())
evidence["launch"] = {"argv": [a if "=" not in a or not a.startswith("CLAUDE") else "CLAUDE_CODE_OAUTH_TOKEN=[redacted]"
                               for a in launch], "socket": SOCKET}
FAILED: list = []


def sh(cmd: list, timeout: int = 60) -> str:
    try:
        done = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return redact((done.stdout + done.stderr)[-20000:])
    except (OSError, subprocess.TimeoutExpired) as error:
        return f"{cmd[0]}: {error}"


def app_pids() -> list:
    return [int(x) for x in sh(["/usr/bin/pgrep", "-f", APP_PATH + "/Contents/MacOS/"]).split() if x.isdigit()]


def diagnose(why: str) -> None:
    """What the launch left behind, so a failure names its cause: open's exit, the app's processes, the sockets
    they hold, /tmp's cmux sockets and the app's unified log since the launch."""
    pids = app_pids()
    (OUT / "launch-diagnostics.txt").write_text("\n".join([
        f"why: {why}", f"open exit: {app.poll()}", f"open output: {launch_log.read_text()[-4000:] if launch_log.exists() else ''}",
        f"app pids: {pids}", "ps:", sh(["/bin/ps", "-axo", "pid,ppid,etime,command"]),
        "app sockets:", *[sh(["/usr/sbin/lsof", "-a", "-p", str(pid), "-U"]) for pid in pids],
        "tmp sockets:", sh(["/bin/ls", "-la", "/tmp/"]),
        "state sockets:", sh(["/bin/ls", "-la", str(Path.home() / ".local/state/cmux") + "/"]),
        "unified log:", sh(["/usr/bin/log", "show", "--style", "compact", "--info", "--start", launched_at,
                             "--predicate", 'process CONTAINS[c] "cmux" OR subsystem CONTAINS[c] "cmux"'], timeout=120),
    ]))
    for crash in sorted(Path.home().glob("Library/Logs/DiagnosticReports/*cmux*"))[-3:]:
        (OUT / f"crash-{crash.name}").write_text(crash.read_text(errors="replace")[-40000:])


def find_socket() -> str | None:
    """The socket the launched app listens on when it is not the one asked for. The app binds in a
    private `.cmuxsock.XXXXXX/s` beside its real path and renames it, so lsof names the staging
    dir's parent; the published app ignores CMUX_NEXT_SOCKET_PATH and binds its build default
    (`~/.local/state/cmux/cmux-debug-<tag>.sock`). Probe every socket in those directories."""
    dirs = {Path.home() / ".local/state/cmux", Path("/tmp")}
    for pid in app_pids():
        for path in re.findall(r"(/\S+)", sh(["/usr/sbin/lsof", "-a", "-p", str(pid), "-U"])):
            if path.endswith(".sock"):
                dirs.add(Path(path).parent)
            elif "/.cmuxsock." in path:
                dirs.add(Path(path.split("/.cmuxsock.")[0]))
    for folder in sorted(dirs):
        for path in sorted(str(p) for p in folder.glob("cmux*.sock")):
            probe = subprocess.run([APP_CLI, "app", "identify", "--json"], env={**ENV, "CMUX_SOCKET_PATH": path,
                                   "CMUX_NEXT_SOCKET_PATH": path}, capture_output=True, text=True, timeout=30)
            if probe.returncode == 0 and parsed(probe.stdout).get("pid") in app_pids():
                return path
    return None


before: set = set()
try:
    deadline = time.monotonic() + 240
    switched = False
    while time.monotonic() < deadline:
        got = run(["app", "identify", "--json"], cli=APP_CLI, timeout=30)
        if got["code"] == 0 and parsed(got["out"]).get("pid"):
            break
        if not switched and time.monotonic() > deadline - 220:
            other = find_socket()
            if other:
                switched = True
                evidence["socket_used"] = other
                print(f"the app is not on {SOCKET}; it answers on {other}: using that", flush=True)
                ENV["CMUX_SOCKET_PATH"] = ENV["CMUX_NEXT_SOCKET_PATH"] = other
                continue
        if app.poll() is not None and not app_pids():
            break
        time.sleep(1)
    step("app identify", got)
    if got["code"] != 0:
        diagnose("app identify never answered")
        FAILED.append("app identify: " + (got["err"] or got["out"])[-300:])
        raise SystemExit(1)
    deadline = time.monotonic() + 300
    while time.monotonic() < deadline:
        got = run(["app", "call", "auth.status", "--json"], cli=APP_CLI, timeout=30)
        status = parsed(got["out"]) if got["code"] == 0 else {}
        if status.get("signed_in") is True and str(status.get("backend", "")).rstrip("/") == API_ORIGIN:
            break
        time.sleep(3)
    step("auth.status (staging, signed in)", {**got, "out": json.dumps({k: status.get(k) for k in ("signed_in", "backend", "cloud_environment")})})
    if not (status.get("signed_in") is True and str(status.get("backend", "")).rstrip("/") == API_ORIGIN):
        diagnose("auth.status is not signed in to staging")
        FAILED.append(f"auth.status: {json.dumps({k: status.get(k) for k in ('signed_in', 'backend', 'cloud_environment')})}")
        raise SystemExit(1)
    if TOKEN and claude_login_cache.valid(TOKEN):
        for entry in claude_login_cache.names(status):
            code, err = claude_login_cache.store(APP_CLI, ENV, entry, TOKEN)
            step("cache claude login", {"words": ["cloud", "secret", "set", "<entry>"], "code": code, "ms": 0, "out": "", "err": redact(err)})
    step("cli version (PR build)", run(["--version"]))
    hs = step("hybrid-status", run(["cloud", "hybrid-status", "--json"]))
    hv = parsed(hs["out"])
    hv = (hv.get("result") or hv) if isinstance(hv, dict) else {}
    evidence["plan"] = hv.get("plan")
    evidence["hybrid_status"] = hv
    before = set(machines())
    evidence["machines_before"] = sorted(before)
    for i in range(1, args.runs + 1):
        r = hybrid_run(i)
        evidence["runs"].append(r)
        save()
    if not any(r.get("log_path") for r in evidence["runs"]):
        FAILED.append("no run took the hybrid path: " + json.dumps(evidence["runs"][0].get("output") if evidence["runs"] else None)[-500:])
    moved = next((r for r in evidence["runs"] if r.get("live_ms") is not None and r.get("session")), None)
    if moved:
        before_follow = transcript(moved["session"])
        follow = run(["chat", "send", moved["session"], FOLLOW_UP, "--wait", "--timeout", "300", "--json"], timeout=330)
        evidence["follow_up"] = {"run": moved["index"], "session": moved["session"], **follow,
                                 "transcript_before": before_follow, "transcript_after": transcript(moved["session"])}
        step("follow-up on the machine", follow)
    else:
        evidence["follow_up"] = {"skipped": "no run moved to its machine"}
    control_env = {**ENV, "CMUX_HYBRID_START": "0"}
    started = time.monotonic()
    control = run(["chat", "--on", "vm:new", "--prompt", PROMPT, "--wait", "--timeout", "900", "--json"],
                  env=control_env, timeout=960)
    control["total_ms"] = ms(started)
    value = parsed(control["out"])
    value = value.get("result") or value if isinstance(value, dict) else {}
    evidence["control_machine"] = value.get("machine_id") if isinstance(value, dict) else None
    evidence["control"] = control
    step("control start (CMUX_HYBRID_START=0)", control)
except SystemExit:
    pass
finally:
    kill_all(before)
    if FAILED:
        diagnose("; ".join(FAILED)) if not (OUT / "launch-diagnostics.txt").exists() else None
    run(["app", "quit"], cli=APP_CLI, timeout=30)
    try:
        app.wait(timeout=30)
    except subprocess.TimeoutExpired:
        app.terminate()

rows = ["| run | first output ms | command ms | first token s (local) | machine ready s | ready from | move ms | on machine | turn end ms | prompts before/after | interrupted | repeated tools | done-1 | finished |",
        "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|"]
for r in evidence["runs"]:
    a, b = r.get("transcript_start") or {}, r.get("transcript_end") or {}
    rows.append(f"| {r['index']} | {r.get('first_output_ms')} | {r.get('command_ms')} | {r.get('first_token_s')} | "
                f"{r.get('machine_ready_s')} | {r.get('machine_ready_from')} | "
                f"{r.get('move_ms')} | {'yes' if r.get('live_ms') is not None else 'no'} | {r.get('turn_end_ms')} | "
                f"{a.get('prompts')}/{b.get('prompts')} | {b.get('interrupted_markers')} | {b.get('repeated_tool_calls')} | "
                f"{b.get('done_1')} | {b.get('finished')} |")
summary = "\n".join(["## Hybrid start first run", "", f"plan: {evidence.get('plan')}", "", *rows, "",
                     *(f"FAILED: {f}" for f in FAILED),
                     f"control (HYBRID=0): exit {evidence.get('control', {}).get('code')} in {evidence.get('control', {}).get('total_ms')} ms",
                     f"follow-up: {json.dumps({k: evidence.get('follow_up', {}).get(k) for k in ('code', 'ms', 'skipped')})}",
                     f"killed: {json.dumps(evidence['machines_killed'])}", f"left: {evidence['machines_left']}"])
(OUT / "summary.md").write_text(redact(summary) + "\n")
print(summary)
for r in evidence["runs"]:
    print(f"\n--- run {r['index']} driver log ---")
    for t, l in r.get("driver_log") or []:
        print(f"{t:>8} ms  {l}")
save()
evidence["failed"] = FAILED
save()
sys.exit(1 if FAILED else 0)
