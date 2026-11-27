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
  5. cleanup uses machine IDs returned by this run’s vm:new commands.
Evidence: DIR/evidence.json, DIR/summary.md and each driver log. No token is written anywhere.
"""
from __future__ import annotations

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
evidence = {"tag": TAG, "prompt": PROMPT, "steps": [], "runs": [], "machines_killed": [], "machines_left": [],
            # Which secret the workflow's Claude preflight chose (a name, never a value).
            "claude_token_source": os.environ.get("HFR_CLAUDE_TOKEN_SOURCE")}


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


def run(words, *, cli=CLI, env=None, timeout=120, full_output=False) -> dict:
    started = time.monotonic()
    try:
        done = subprocess.run([cli, *words], env=env or ENV, capture_output=True, text=True, timeout=timeout)
        code, out, err = done.returncode, done.stdout, done.stderr
    except subprocess.TimeoutExpired as e:
        code, out, err = 124, (e.stdout or b"").decode() if isinstance(e.stdout, bytes) else (e.stdout or ""), \
            f"timed out after {timeout}s"
    out = redact(out)
    return {"words": words, "code": code, "ms": ms(started), "out": out if full_output else out[-6000:],
            "err": redact(err)[-4000:]}


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
    """Count transcript items. The CLI exposes tool IDs but omits command arguments."""
    got = run(["agents", "chat", "read", session, "--limit", "200", "--json"], timeout=60, full_output=True)
    text = got["out"]
    items = chat_items(text)
    prompts = [item for item in items if item.get("role") == "user"]
    tools = [item for item in items if item.get("role") == "tool"]
    assistant = agent_text(text)
    return {
        "code": got["code"], "items": len(items), "prompts": len(prompts),
        "continuations": len(re.findall(r"(?i)continu(?:e|ation)[^\"]{0,80}(?:move|machine|where you)", text)),
        "interrupted_markers": text.count("[Request interrupted"),
        "tool_calls": len(tools), "repeated_tool_calls": None,
        "done_1": assistant.count("done-1"),
        "finished": assistant.lower().count("finished"),
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


OK_WORD = re.compile(r"(?i)\bok\b")


def chat_items(text: str) -> list:
    value = parsed(text)
    payload = value.get("result", value) if isinstance(value, dict) else None
    items = payload.get("items") if isinstance(payload, dict) else None
    return [item for item in items if isinstance(item, dict)] if isinstance(items, list) else []


def agent_text(text: str) -> str:
    return "\n".join(item["text"] for item in chat_items(text)
                     if item.get("role") == "assistant" and isinstance(item.get("text"), str))


def reply_text(text: str) -> str:
    value = parsed(text)
    payload = value.get("result", value) if isinstance(value, dict) else None
    reply = payload.get("reply") if isinstance(payload, dict) else None
    return reply if isinstance(reply, str) else ""


def first_token(session: str, started: float, out: dict, stop: threading.Event) -> None:
    """The local chat's first agent text: polls `agents chat read` every 250 ms from the start's exit until the
    reply's "ok" is in it (ok_ms), noting when the transcript first grew past its first read (grew_ms)."""
    first = None
    while not stop.is_set() and "ok_ms" not in out:
        got = run(["agents", "chat", "read", session, "--limit", "50", "--json"], timeout=20, full_output=True)
        at = round((time.monotonic() - started) * 1000)
        text = got["out"] if got["code"] == 0 else ""
        if text and first is None:
            first = len(text)
        elif text and "grew_ms" not in out and len(text) > first:
            out["grew_ms"] = at
        if OK_WORD.search(agent_text(text)):
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
    r["machine_ready_ms"] = ready
    r["machine_ready_from"] = "ready line" if ready is not None else None
    r["machine_ready_s"] = round(r["machine_ready_ms"] / 1000, 2) if r["machine_ready_ms"] is not None else None
    r["move_ms"] = (live - moving) if live is not None and moving is not None else None
    r["live_ms"] = live
    # The turn's end, wherever the chat runs now.
    waited = run(["chat", "wait", r["session"], "--timeout", "300", "--json"], timeout=330)
    r["turn_wait"] = {k: waited[k] for k in ("code", "ms", "out", "err")}
    r["turn_end_ms"] = ms(started)
    r["reply"] = reply_text(waited["out"])
    r["transcript_end"] = transcript(r["session"])
    return r


KEYCHAIN_ITEMS: set = set()


def harness_names(config: Path) -> list | None:
    """The harness names in an acpmux config.json (names only), or None when there is none."""
    try:
        return sorted((json.loads(config.read_text()).get("harnesses") or {}).keys())
    except (OSError, ValueError, AttributeError):
        return None


def cleanup_created_machines() -> None:
    # Both the hybrid and control commands request vm:new. Account-wide listings
    # can also contain machines that another journey started while ours ran.
    created = {row["machine"] for row in evidence["runs"] if row.get("machine")}
    if evidence.get("control_machine"):
        created.add(evidence["control_machine"])
    for machine in sorted(created):
        got = run(["cloud", "kill-machine", "--target", f"machine:{machine}", "--confirm", "--json"],
                  cli=APP_CLI, timeout=120)
        evidence["machines_killed"].append({"machine": machine, "code": got["code"], "err": got["err"][-500:]})
        if got["code"]:
            FAILED.append(f"cleanup failed for {machine} (exit {got['code']})")
        print(f"kill {machine}: exit {got['code']}", flush=True)
    if created:
        evidence["machines_left"] = sorted(created.intersection(machines()))
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
APP_PATH = str(Path(args.app).resolve())


def sh(cmd: list, timeout: int = 60) -> str:
    try:
        done = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return redact((done.stdout + done.stderr)[-20000:])
    except (OSError, subprocess.TimeoutExpired) as error:
        return f"{cmd[0]}: {error}"


def matching_pids() -> set[int]:
    executable = re.escape(APP_PATH + "/Contents/MacOS/")
    return {int(pid) for pid in sh(["/usr/bin/pgrep", "-f", "^" + executable]).split() if pid.isdigit()}


existing_pids = matching_pids()


def app_pids() -> list[int]:
    return sorted(matching_pids() - existing_pids)


def identified_pid(result: dict):
    value = parsed(result.get("out", ""))
    value = value.get("result", value) if isinstance(value, dict) else None
    return value.get("pid") if result.get("code") == 0 and isinstance(value, dict) else None


app_identified = False
app = subprocess.Popen(launch, env=ENV, stdout=launch_log.open("w"), stderr=subprocess.STDOUT)
evidence["launch"] = {"argv": [a if "=" not in a or not a.startswith("CLAUDE") else "CLAUDE_CODE_OAUTH_TOKEN=[redacted]"
                               for a in launch], "socket": SOCKET}
FAILED: list = []


def diagnose(why: str) -> None:
    """Keep the launched app's output and socket diagnostics."""
    pids = app_pids()
    output = launch_log.read_text(errors="replace")[-4000:] if launch_log.exists() else ""
    (OUT / "launch-diagnostics.txt").write_text(redact("\n".join([
        f"why: {why}", f"open exit: {app.poll()}", f"open output: {output}",
        f"app pids: {pids}", *[sh(["/usr/sbin/lsof", "-a", "-p", str(pid), "-U"]) for pid in pids],
    ])))


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
            if identified_pid({"code": probe.returncode, "out": probe.stdout}) in app_pids():
                return path
    return None


try:
    deadline = time.monotonic() + 240
    switched = False
    while time.monotonic() < deadline:
        got = run(["app", "identify", "--json"], cli=APP_CLI, timeout=30)
        if identified_pid(got) in app_pids():
            app_identified = True
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
    IDENT = parsed(got["out"]) if got["code"] == 0 else {}
    IDENT = (IDENT.get("result") or IDENT) if isinstance(IDENT, dict) else {}
    if not app_identified:
        diagnose("could not identify the app launched by this run")
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
    # Blocker (1), run 45268577702: the PR CLI sits outside any app bundle, and with only CMUX_SOCKET_PATH it
    # resolved NIGHTLY's ~/.acpmux, a daemon with no harnesses ("no harnesses configured"), while the app's own
    # acpmux lives in ~/.acpmux/builds/<bundle id>. Give both CLIs the identity an app terminal exports.
    bundle = IDENT.get("bundle_id") or "com.cmuxterm.app.debug.next"
    tag = IDENT.get("tag") or "next"
    acp_home = Path.home() / ".acpmux" / "builds" / bundle
    evidence["acpmux"] = {"app_home": str(acp_home), "app_home_exists": acp_home.is_dir(),
                          "harnesses_app_home": harness_names(acp_home / "config.json"),
                          "harnesses_default_home": harness_names(Path.home() / ".acpmux" / "config.json")}
    ENV.update({"CMUX_BUNDLE_ID": bundle, "CMUX_TAG": tag})
    if acp_home.is_dir():
        ENV["ACPMUX_HOME"] = str(acp_home)
    print(f"acpmux: {json.dumps(evidence['acpmux'])}", flush=True)
    # Blocker (2): the app's Set up Cloud gate (CloudSetup.refusal) reads the app acpmux's model connections; a
    # cached login is not one. Add the agent test account's setup-token as a Claude connection the way
    # `cmux cloud connect claude` does for a person, with CMUX_CLAUDE_BIN printing the token in place of
    # `claude setup-token` (a 0600 file, removed at once; the token never reaches argv or the log).
    conns = step("cloud connections (before)", run(["cloud", "connections", "--json"], cli=APP_CLI))
    if TOKEN and claude_login_cache.valid(TOKEN) and "claude-token" not in conns["out"]:
        holder = Path(tempfile.mkdtemp(prefix="hfr-claude-bin-"))
        secret_file, fake = holder / "token", holder / "claude"
        secret_file.touch(mode=0o600)
        secret_file.write_text(TOKEN + "\n")
        fake.write_text(f"#!/bin/sh\n/bin/cat '{secret_file}'\n")
        fake.chmod(0o700)
        try:
            connect = run(["cloud", "connect", "claude", "--label", "hybrid first run", "--json"], cli=APP_CLI,
                          env={**ENV, "CMUX_CLAUDE_BIN": str(fake)}, timeout=120)
        finally:
            secret_file.unlink(missing_ok=True)
            fake.unlink(missing_ok=True)
            holder.rmdir()
        KEYCHAIN_ITEMS.update(re.findall(r"claude-token-[0-9a-f]{8}", connect["out"] + connect["err"]))
        step("cloud connect claude (agent test account's setup-token)", {**connect, "out": redact(connect["out"])[-800:],
                                                                        "err": redact(connect["err"])[-800:]})
        conns = step("cloud connections (after)", run(["cloud", "connections", "--json"], cli=APP_CLI))
    evidence["claude_connection"] = "claude-token" in conns["out"]
    step("cli version (PR build)", run(["--version"]))
    hs = step("hybrid-status", run(["cloud", "hybrid-status", "--json"]))
    hv = parsed(hs["out"])
    hv = (hv.get("result") or hv) if isinstance(hv, dict) else {}
    evidence["plan"] = hv.get("plan")
    evidence["hybrid_status"] = hv
    # The app's own plan read (billing.status), beside the CLI's cloud.plan.get: a null plan names which read is empty.
    bs = step("billing.status (the app's plan read)", run(["app", "call", "billing.status", "--json"], cli=APP_CLI, timeout=60))
    bv = parsed(bs["out"])
    evidence["billing_status"] = (bv.get("result") or bv) if isinstance(bv, dict) else bs["err"][-600:]
    for i in range(1, args.runs + 1):
        r = hybrid_run(i)
        evidence["runs"].append(r)
        local_reply = (r.get("first_token") or {}).get("ok_ms")
        ready = r.get("machine_ready_ms")
        if local_reply is None or ready is None or local_reply >= ready:
            FAILED.append(f"run {i}: no local model reply observed before machine readiness")
        if (r.get("live_ms") is None or (r.get("turn_wait") or {}).get("code") != 0
                or not re.search(r"\bfinished\b", r.get("reply", ""), re.I)):
            FAILED.append(f"run {i}: no completed turn observed after handoff")
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
        if follow["code"] != 0 or "done-1" not in reply_text(follow["out"]):
            FAILED.append("follow-up failed on the destination")
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
    if control["code"] != 0 or not re.search(r"\bfinished\b", reply_text(control["out"]), re.I):
        FAILED.append("control did not complete the prompted turn")
except SystemExit:
    pass
finally:
    cleanup_created_machines()
    for item in sorted(KEYCHAIN_ITEMS):  # the Claude connection's Keychain item this run added
        sh(["/usr/bin/security", "delete-generic-password", "-s", "cmux-model-key", "-a", item])
    if FAILED:
        diagnose("; ".join(FAILED)) if not (OUT / "launch-diagnostics.txt").exists() else None
    if app_identified and identified_pid(run(["app", "identify", "--json"], cli=APP_CLI)) in app_pids():
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
def message(result: dict | None) -> str | None:
    """The CLI's error message for a failed command, else None."""
    if not result or result.get("code") in (0, None):
        return None
    value = parsed(result.get("err") or "") or parsed(result.get("out") or "")
    said = value.get("message") if isinstance(value, dict) else None
    return (said or (result.get("err") or "")[-300:]).strip()[:400]


def seconds(value) -> str:
    return "none" if value is None else f"{value / 1000:.1f} s"


first = next((r for r in evidence["runs"] if r.get("machine")), None) or (evidence["runs"] or [{}])[0]
follow = evidence.get("follow_up") or {}
control = evidence.get("control") or {}
result_line = (
    f"result: machine started {'yes' if first.get('machine') else 'no'}"
    f" (ready {seconds(first.get('machine_ready_ms'))}); first reply here {seconds((first.get('first_token') or {}).get('ok_ms'))};"
    f" on the machine at {seconds(first.get('live_ms'))}; move {first.get('move_ms')} ms;"
    f" turn {'answered' if 'finished' in (first.get('reply') or '').lower() else 'failed'};"
    f" follow-up {'skipped: ' + follow['skipped'] if follow.get('skipped') else ('answered' if follow.get('code') == 0 and 'done-1' in reply_text(follow.get('out', '')) else 'failed')};"
    f" control {'answered' if control.get('code') == 0 and 'finished' in reply_text(control.get('out', '')).lower() else 'failed'}")
summary = "\n".join(["## Hybrid start first run", "", result_line, "",
                     f"plan: {evidence.get('plan')} (hybrid-status {json.dumps({k: (evidence.get('hybrid_status') or {}).get(k) for k in ('plan', 'off', 'flag')})});"
                     f" billing.status plan: {json.dumps((evidence.get('billing_status') or {}).get('plan') if isinstance(evidence.get('billing_status'), dict) else evidence.get('billing_status'))}",
                     f"Claude login: {evidence.get('claude_token_source')}", "", *rows, "",
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
