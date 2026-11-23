#!/usr/bin/env python3
"""Update when idle, end to end: a staged update installs by itself only once nothing would be cut off and cmux has
been idle `updates.installWhenIdleMinutes`, and every agent host survives it.

Leo, 2026-11-19: "when it's idle, it's able to ... update automatically ... maybe even having it as an opt-in option
would be pretty interesting. Yeah, like update when idle".

    idle_e2e.py --app "<path>/cmux DEV <tag>.app" --tag <tag> --out <dir> [--expect install|none]

The app is a bench build (`reload.sh --config bench`: the NIGHTLY's Release optimization with the debug control
surface); its copies run the real Sparkle flow against a loopback appcast, as run.py's do (a release identity reads
no harness feed, and only the nightly key could sign one for it). Steps:
  1. v1 and v2 copies (v2 newer; with --handoff, the default, v2's daemons carry another build commit, so the update
     takes the daemon handoff a real nightly update takes), a throwaway EdDSA key, the signed appcast served on
     127.0.0.1. v1 gets its own cmux-next.json: updates.installWhenIdle on (--install-when-idle on, the opt-in; unset leaves
     the build's default), installWhenIdleMinutes N (1), a low
     idleInstallQuietSeconds, downloadAutomatically on, automatic checks off.
  2. Before the update stages: agent session A finishes a turn; agent session B starts a turn that waits on a FIFO
     (acpmux's fake agent, `gate:`); a new chat gets an unsent draft typed into its composer (`debug.key`, the path a
     key press takes). The acpmux agent host census is taken (the hosts records, their live pids, `acpmux ls --json`).
  3. Check for Updates; the update downloads and stages with no click.
  4. Phase turn+draft: the app must not install for longer than the idle time. Then B's gate opens and its turn ends
     (its final message must arrive). Phase draft: it must still not install. Then the draft is deleted (Delete
     keys in the composer).
  5. With --expect install: the install must start by itself (no install_clicked), no earlier than the idle time after
     the last input, and within a bound. The input clock is the harness's: `debug.updater {action: "input"}` marks a
     person's input now (DEBUG / CMUX_BENCH_HOOKS only), because a fleet Mac's window-server idle time is hours and
     cannot be reset from here. It is touched when the draft is cleared and once more --input-bump-after s later, so
     the run shows the idle clock restarting. A build without that method fails the run (exit 4), naming the hook.
     With --expect none (the base build, which has no installWhenIdle): nothing installs for the same windows.
  6. After the relaunch: the installed build is v2's, every agent host has the same host and harness pids (adopted by
     the new acpmux with --handoff), the census counts match, B's turn completed once with no cancel or stop.
Writes <out>/result.json (verdicts, counts, timestamps, version before and after) and <out>/marks.ndjson; ends what it
started by exact pid (TagTeardown, Owned), deletes the key.
"""
import argparse, glob, json, os, plistlib, shutil, signal, socket, subprocess, sys, threading, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, ".."))
from run import Marks, first, wait_exit, wait_socket, rpc, plist_set, run, log, end_tag, processes_under  # noqa: E402
from sessions import Agent, Owned, alive, bundle_commit, patch_build_stamp  # noqa: E402
from tag_teardown import TagTeardown  # noqa: E402
import re  # noqa: E402

CHECK_ACTION = "palette.checkForUpdates"
NEW_CHAT_ACTION = "palette.newAgentChat"
# The typed draft: ANSI virtual key codes for "idle draft".
DRAFT_TEXT = "idle draft"
KEY_CODES = {"i": 34, "d": 2, "l": 37, "e": 14, " ": 49, "r": 15, "a": 0, "f": 3, "t": 17}
DELETE_KEY = 51
INSTALL_MARKS = ("install_started", "install_handed_to_sparkle", "will_relaunch", "install_clicked")


class FinishedAgent(Agent):
    """A session whose one turn has ended before the update (no gate)."""

    def start(self, timeout=60):
        from sessions import wait_path
        if not wait_path(self.socket, lambda p: os.path.exists(p), timeout):
            raise SystemExit("the tag's acpmux did not start")
        conn = socket.socket(socket.AF_UNIX)
        conn.settimeout(60)
        conn.connect(self.socket)
        self.session = self.call(conn, "session/new", {"cwd": os.path.dirname(self.gate), "mcpServers": []})["sessionId"]
        self.call(conn, "session/prompt", {"sessionId": self.session, "prompt": [{"type": "text", "text": "finished turn"}]})
        conn.close()
        if not self.wait_event(lambda e: e.get("kind") == "turn_result", 30):
            raise SystemExit("the finished session's turn never ended")
        self.host_before = self.identity()
        self.events_before = self.events()
        self.harness_pid = self.host_before.get("harness_pid")
        with open(os.path.join(self.home, "daemon.pid")) as f:
            self.daemon_pid = int(f.read().strip())
        log("finished session", self.session, "harness pid", self.harness_pid)


def census(acp_home, acpmux_bin):
    """The tag's agent hosts: each hosts/<session>.json record with its pids and whether they run, and
    `acpmux ls --json` from the tag's own home. Never publishes the records' credentials."""
    hosts = []
    for path in sorted(glob.glob(os.path.join(acp_home, "hosts", "*.json"))):
        try:
            with open(path) as f:
                record = json.load(f)
        except (OSError, ValueError):
            continue
        host_pid, harness_pid = record.get("host_pid"), record.get("harness_pid")
        hosts.append({"session": record.get("session_id"), "host_pid": host_pid, "harness_pid": harness_pid,
                      "host_alive": bool(host_pid and alive(host_pid)), "harness_alive": bool(harness_pid and alive(harness_pid))})
    out = {"at": time.time(), "host_records": len(hosts),
           "live_hosts": sum(1 for h in hosts if h["host_alive"] and h["harness_alive"]), "hosts": hosts}
    env = dict(os.environ, ACPMUX_HOME=acp_home, ACPMUX_SOCKET=os.path.join(acp_home, "acpmux.sock"))
    try:
        done = subprocess.run([acpmux_bin, "ls", "--json"], env=env, capture_output=True, text=True, timeout=30)
        listed = json.loads(done.stdout) if done.returncode == 0 and done.stdout.strip() else None
        if isinstance(listed, dict):
            listed = next((v for k, v in listed.items() if isinstance(v, list)), [])
        out["ls_count"] = len(listed) if isinstance(listed, list) else None
        out["ls_sessions"] = sorted(str(r.get("id") or r.get("sessionId") or r.get("session_id") or r.get("name"))
                                    for r in listed or [] if isinstance(r, dict))
        if done.returncode != 0:
            out["ls_error"] = (done.stderr or done.stdout)[-600:]
    except (OSError, ValueError, subprocess.TimeoutExpired) as error:
        out["ls_count"], out["ls_error"] = None, str(error)
    return out


def type_keys(sock, codes, gap_ms=40):
    """Key presses into the focused pane's page (debug.key, the path a real key takes), one down and up per code."""
    steps = []
    for code in codes:
        steps += [{"key_code": code, "down": True, "after_ms": gap_ms}, {"key_code": code, "down": False, "after_ms": 15}]
    reply = rpc(sock, "debug.key", {"key_window": "page", "sequence": steps}, timeout=15)
    time.sleep(len(codes) * 0.06 + 0.5)  # the sequence plays after the reply; this is its length plus a margin
    return reply.get("result", reply)


def touch_input(sock, result, label):
    """`debug.updater {action: "input"}`: a person's input now, on the clock the idle install reads."""
    reply = rpc(sock, "debug.updater", {"action": "input"})
    stamp = time.time()
    if "error" in reply or reply.get("result") is None:
        result["input_override"] = {"supported": False, "reply": reply}
        return None
    result.setdefault("input_touches", []).append({"label": label, "at": stamp, "reply": reply.get("result")})
    log("input touched:", label)
    return stamp


def install_marks(marks, pid):
    rows = marks.read()
    return {name: (first(rows, name, pid=pid) or {}).get("unix_ms") for name in INSTALL_MARKS}


def status(sock):
    """The updater's status: phase, build, relaunch hold, idle-install fields when the build has them, recent log."""
    try:
        return rpc(sock, "updates.status").get("result") or {}
    except OSError as error:
        return {"socket_error": str(error)}


def hold(a, sock, marks, v1_pid, result, phase, seconds):
    """Nothing may install for `seconds`: v1 keeps running and writes no install mark."""
    started = time.time()
    exited = wait_exit(v1_pid, seconds)
    snap = status(sock) if exited is None else {}
    marked = {k: v for k, v in install_marks(marks, v1_pid).items() if v}
    row = {"from": started, "to": time.time(), "seconds": seconds, "v1_alive": exited is None, "install_marks": marked,
           "status": {k: snap.get(k) for k in ("phase", "badge", "relaunch_hold", "idle_install", "relaunch_blockers", "log")}}
    result["holds"][phase] = row
    log("hold", phase, json.dumps({k: row[k] for k in ("seconds", "v1_alive", "install_marks")}))
    if exited is not None or marked:
        raise SystemExit(f"installed during {phase}: v1 exited={exited is not None}, marks {marked}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--app", required=True)
    ap.add_argument("--tag", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--expect", choices=["install", "none"], default="install",
                    help="install: the build has Update When Idle (head); none: a control build without it (base)")
    ap.add_argument("--idle-minutes", type=int, default=1, help="updates.installWhenIdleMinutes (default 1)")
    ap.add_argument("--install-when-idle", choices=["on", "unset"], default="on",
                    help="updates.installWhenIdle in v1's config: on (the opt-in, default) or unset (the build's default)")
    ap.add_argument("--quiet-seconds", type=int, default=5, help="updates.idleInstallQuietSeconds (default 5)")
    ap.add_argument("--input-bump-after", type=float, default=20,
                    help="seconds after the draft is cleared to touch input once more (0: never); the install must wait "
                         "the idle time from this touch")
    ap.add_argument("--install-slack", type=float, default=120,
                    help="seconds past the earliest allowed moment within which the install must start")
    ap.add_argument("--no-handoff", dest="handoff", action="store_false",
                    help="v2 keeps v1's daemon build commit (no daemon handoff)")
    ap.add_argument("--stage-timeout", type=float, default=240)
    ap.add_argument("--relaunch-timeout", type=float, default=120)
    ap.add_argument("--port", type=int, default=0)
    ap.add_argument("--fake-agent", default=os.path.join(HERE, "../../../cmux-tui/crates/acpmux/tests/fake_agent.py"),
                    help="acpmux's test agent (a copied harness has no checkout beside it: the measure script passes it)")
    a = ap.parse_args()
    if a.idle_minutes < 1:
        ap.error("--idle-minutes is at least 1 (the setting's minimum)")
    idle_s = a.idle_minutes * 60
    hold_s = idle_s + a.quiet_seconds + 20  # longer than any idle wait the settings allow

    if a.port == 0:
        probe = socket.socket()
        probe.bind(("127.0.0.1", 0))
        a.port = probe.getsockname()[1]
        probe.close()
    out = os.path.abspath(a.out)
    work = os.path.join(out, "work")
    # A repeated run never erases another run's artifacts or state.
    if os.path.lexists(work):
        raise SystemExit(f"{work} exists: use a fresh output directory")
    keys, feed = os.path.join(work, "keys"), os.path.join(work, "feed")
    for d in (keys, feed, os.path.join(work, "v1"), os.path.join(work, "v2"), os.path.join(work, "cwd"), os.path.join(work, "draft")):
        os.makedirs(d)
    marks_path = os.path.join(out, "marks.ndjson")
    if os.path.lexists(marks_path):
        raise SystemExit(f"{marks_path} exists: use a fresh output directory")
    name = os.path.basename(a.app.rstrip("/"))
    v1, v2 = os.path.join(work, "v1", name), os.path.join(work, "v2", name)
    feed_url = f"http://127.0.0.1:{a.port}/appcast.xml"
    sock = f"/tmp/cmux-debug-{a.tag}.sock"
    slug = "-".join(filter(None, "".join(c if c.isalnum() else " " for c in a.tag.lower()).split()))
    acp_home = os.path.join(os.environ["HOME"], ".acpmux/builds",
                            "com.cmuxterm.app.debug." + re.sub(r"[^a-z0-9]+", ".", slug).strip("."))
    with open(os.path.join(a.app, "Contents/Info.plist"), "rb") as f:
        source_identity = plistlib.load(f).get("CFBundleIdentifier")
    if source_identity != os.path.basename(acp_home):
        raise SystemExit("the app must be the isolated DEV build for --tag")
    if os.path.lexists(sock):
        raise SystemExit(f"{sock} exists: use a fresh tag")
    os.makedirs(os.path.dirname(acp_home), exist_ok=True)
    # Exclusive creation proves that the final teardown owns this home.
    try:
        os.mkdir(acp_home)
    except FileExistsError:
        raise SystemExit(f"{acp_home} exists: use a fresh tag")
    result = {"tag": a.tag, "app": name, "expect": a.expect, "idle_minutes": a.idle_minutes, "quiet_seconds": a.quiet_seconds,
              "install_when_idle": a.install_when_idle,
              "handoff": a.handoff, "holds": {}, "passed": False}
    server = None
    owned_apps = {}
    owned = Owned(TagTeardown._table)
    teardowns = [TagTeardown(copy, acpmux_home=acp_home, acpmux_socket=os.path.join(acp_home, "acpmux.sock"), log=log)
                 for copy in (v1, v2)]

    def remember_app(pid):
        row = TagTeardown._table().get(pid)
        if row and any(t.in_bundle(row[2]) for t in teardowns):
            owned_apps[pid] = row[1:]

    def remember_tag():
        for t in teardowns:
            if os.path.isdir(t.app):
                t.remember()

    exit_code = 1
    try:
        teardowns[0].install()
        public_key = run(["swift", os.path.join(HERE, "keys.swift"), "generate", keys])
        run(["/usr/bin/ditto", a.app, v1])
        run(["/usr/bin/ditto", a.app, v2])
        if a.handoff:
            commit = bundle_commit(v2)
            bin2 = os.path.join(v2, "Contents/Resources/bin")
            result["handoff_patch"] = {n: patch_build_stamp(os.path.join(bin2, n), commit) for n in ("cmux-tui", "acpmux")}
        fake = os.path.abspath(a.fake_agent)
        if not os.path.isfile(fake):
            raise SystemExit(f"no fake agent at {fake}")
        dirs = {k: os.path.join(work, k) for k in ("agent-finished", "agent-running")}
        for d in dirs.values():
            os.makedirs(d)
        finished = FinishedAgent(acp_home, fake, dirs["agent-finished"], log, configure=True)
        running = Agent(acp_home, fake, dirs["agent-running"], log, configure=False)

        harness = {"feed": feed_url, "marks": marks_path}
        base = int(time.time())
        i1 = plist_set(v1, {"SUPublicEDKey": public_key, "CFBundleVersion": str(base)}, harness)
        i2 = plist_set(v2, {"SUPublicEDKey": public_key, "CFBundleVersion": str(base + 1)}, harness)
        result.update(bundle_id=i1.get("CFBundleIdentifier"),
                      version_before={"short": i1.get("CFBundleShortVersionString"), "build": i1["CFBundleVersion"]},
                      version_offered={"short": i2.get("CFBundleShortVersionString"), "build": i2["CFBundleVersion"]})
        archive = os.path.join(feed, "update.zip")
        run(["/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", v2, archive])
        signature = run(["swift", os.path.join(HERE, "keys.swift"), "sign", keys, archive])
        short = i2.get("CFBundleShortVersionString", "0")
        with open(os.path.join(feed, "appcast.xml"), "w") as f:
            f.write(f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>update when idle harness</title>
    <item>
      <title>{short} ({i2['CFBundleVersion']})</title>
      <pubDate>{time.strftime('%a, %d %b %Y %H:%M:%S +0000', time.gmtime())}</pubDate>
      <sparkle:version>{i2['CFBundleVersion']}</sparkle:version>
      <sparkle:shortVersionString>{short}</sparkle:shortVersionString>
      <description><![CDATA[New: update when idle]]></description>
      <enclosure url="http://127.0.0.1:{a.port}/update.zip" length="{os.path.getsize(archive)}" type="application/octet-stream" sparkle:edSignature="{signature}"/>
    </item>
  </channel>
</rss>
""")
        server = subprocess.Popen([sys.executable, "-m", "http.server", str(a.port), "--bind", "127.0.0.1", "--directory", feed],
                                  stdout=open(os.path.join(out, "server.log"), "w"), stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)
        # Its own config, never the Mac's shared ~/.config/cmux/cmux-next.json (cmux#45598).
        config = os.path.join(work, "cmux-next.json")
        with open(config, "w") as f:
            updates = {"installWhenIdleMinutes": a.idle_minutes, "idleInstallQuietSeconds": a.quiet_seconds,
                       "downloadAutomatically": True, "checkAutomatically": False}
            if a.install_when_idle == "on":
                updates["installWhenIdle"] = True
            json.dump({"updates": updates}, f)
        result["config"] = json.load(open(config))
        marks = Marks(marks_path)
        env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
               "SHELL": "/bin/zsh", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1",
               "CMUX_NEXT_SOCKET_MODE": "automation", "CMUX_DEV_BACKEND_MODE": "local", "CMUX_NEXT_CONFIG_FILE": config}
        binary = os.path.join(v1, "Contents/MacOS", i1["CFBundleExecutable"])
        app = subprocess.Popen([binary], env=env, cwd=os.path.join(work, "cwd"), stdin=subprocess.DEVNULL,
                               stdout=open(os.path.join(out, "v1.log"), "w"), stderr=subprocess.STDOUT, start_new_session=True)
        v1_pid = app.pid
        remember_app(v1_pid)
        remember_tag()
        result["v1_pid"] = v1_pid
        if not marks.wait(lambda rows: first(rows, "launch.first_window_frame_committed", pid=v1_pid), 120):
            raise SystemExit("v1 showed no window")
        if not wait_socket(sock, 60):
            raise SystemExit(f"v1's control socket {sock} did not open")
        if not first(marks.read(), "updater_created", pid=v1_pid):
            raise SystemExit("v1 did not start the harness updater (a bench or DEBUG build with the harness keys?)")

        # The input clock the idle install reads (DEBUG / CMUX_BENCH_HOOKS hook).
        touch_input(sock, result, "launch")
        if a.expect == "install" and result.get("input_override", {}).get("supported") is False:
            exit_code = 4
            raise SystemExit("this build has no debug.updater {action: \"input\"}: the idle wait cannot be proven on a "
                             "fleet Mac (its window-server idle time is hours). Add the hook (DebugUpdater.swift + "
                             "DaemonRelaunchBlockers.swift, DEBUG || CMUX_BENCH_HOOKS) and run again")

        # Sessions: one finished, one mid-turn, and a new chat with an unsent draft.
        finished.start()
        owned.add(finished.harness_pid)
        owned.add(finished.host_before.get("host_pid"))
        running.start()
        owned.add(running.harness_pid)
        owned.add(running.host_before.get("host_pid"))
        remember_tag()
        result["new_chat"] = rpc(sock, "action.run", {"id": NEW_CHAT_ACTION,
                                                      "arguments": {"harness": "fake", "cwd": os.path.join(work, "draft")}}, timeout=20)
        time.sleep(3.0)  # the chat page loads and its composer mounts; focus_composer below waits for the page itself
        result["draft_focus"] = rpc(sock, "debug.agent_pane", {"action": "focus_composer"}, timeout=60).get("result")
        result["draft_typed"] = type_keys(sock, [KEY_CODES[c] for c in DRAFT_TEXT])
        result["draft_readback"] = rpc(sock, "debug.agent_pane", {"action": "readiness"}, timeout=60).get("result")
        result["census_setup"] = census(acp_home, os.path.join(v1, "Contents/Resources/bin/acpmux"))
        log("census at setup", json.dumps({k: result["census_setup"][k] for k in ("host_records", "live_hosts", "ls_count")}))

        # The update stages with no click.
        result["check"] = rpc(sock, "action.run", {"id": CHECK_ACTION})
        ends = ("phase.ready", "phase.available")
        staged = marks.wait(lambda rows: next((first(rows, e, pid=v1_pid) for e in ends if first(rows, e, pid=v1_pid)), None),
                            a.stage_timeout)
        if staged and staged["name"] == "phase.available":
            result["found_step_pressed"] = rpc(sock, "debug.updater", {"action": "press", "button": "update"}).get("result")
            staged = marks.wait(lambda rows: first(rows, "phase.ready", pid=v1_pid), a.stage_timeout)
        if not staged or staged["name"] != "phase.ready":
            raise SystemExit(f"nothing staged: {json.dumps(status(sock))[:1500]}")
        result["staged_at"] = staged["unix_ms"] / 1000
        log("staged; holding", hold_s, "s with the turn running and the draft unsent")

        hold(a, sock, marks, v1_pid, result, "turn_and_draft", hold_s)

        # The turn ends: open its gate and wait for its final message.
        writer = threading.Thread(target=lambda: open(running.gate, "w").write("go"), daemon=True)
        writer.start()
        writer.join(30)
        ended = running.wait_event(lambda e: e.get("kind") == "turn_result", 60)
        result["turn_ended_at"] = time.time()
        if not ended:
            raise SystemExit("the running turn did not end after its gate opened")
        hold(a, sock, marks, v1_pid, result, "draft_only", hold_s)

        # The draft goes: Delete in the composer, as a person clears it; that is input too.
        result["draft_cleared_keys"] = type_keys(sock, [DELETE_KEY] * (len(DRAFT_TEXT) + 2))
        result["draft_cleared_at"] = time.time()
        result["draft_readback_cleared"] = rpc(sock, "debug.agent_pane", {"action": "readiness"}, timeout=60).get("result")
        last_input = touch_input(sock, result, "draft cleared") or result["draft_cleared_at"]
        result["census_before"] = census(acp_home, os.path.join(v1, "Contents/Resources/bin/acpmux"))
        log("census before", json.dumps({k: result["census_before"][k] for k in ("host_records", "live_hosts", "ls_count")}))

        if a.input_bump_after and result.get("input_touches"):
            # Within the idle time: an install now would ignore the restart of the idle clock.
            exited = wait_exit(v1_pid, a.input_bump_after)
            if exited is not None:
                raise SystemExit(f"installed {exited - last_input:.1f} s after input, before the {idle_s} s idle time")
            last_input = touch_input(sock, result, "bump") or last_input
        result["last_input_at"] = last_input
        earliest = last_input + idle_s

        if a.expect == "none":
            hold(a, sock, marks, v1_pid, result, "idle_control", idle_s + a.quiet_seconds + 30)
            result["passed"] = True
            exit_code = 0
            return

        deadline = earliest + a.quiet_seconds + a.install_slack - time.time()
        t_exit = wait_exit(v1_pid, max(1.0, deadline))
        if t_exit is None:
            result["status_no_install"] = status(sock)
            raise SystemExit(f"no install within {a.quiet_seconds + a.install_slack:.0f} s of the idle time")
        result["v1_exit_at"] = t_exit
        app.wait(10)
        rows = marks.read()
        result["install_marks"] = {k: (v / 1000 if v else None) for k, v in install_marks(marks, v1_pid).items()}
        start = result["install_marks"].get("install_started") or result["install_marks"].get("will_relaunch") or t_exit
        result["install_start_at"] = start
        result["install_after_last_input_s"] = round(start - last_input, 2)
        if result["install_marks"].get("install_clicked"):
            raise SystemExit("the install was clicked, not automatic")
        if start < earliest - 1.5:
            raise SystemExit(f"installed {start - last_input:.1f} s after the last input; the idle time is {idle_s} s")

        relaunched = marks.wait(lambda rs: first(rs, "launch.first_window_frame_committed", not_pid=v1_pid), a.relaunch_timeout)
        if not relaunched:
            raise SystemExit("the relaunched app showed no window")
        v2_pid = relaunched["pid"]
        remember_app(v2_pid)
        remember_tag()
        result.update(v2_pid=v2_pid, v2_first_frame_at=relaunched["unix_ms"] / 1000)
        with open(os.path.join(v1, "Contents/Info.plist"), "rb") as f:
            installed = plistlib.load(f)
        result["version_after"] = {"short": installed.get("CFBundleShortVersionString"), "build": installed["CFBundleVersion"]}
        if wait_socket(sock, 60):
            st = status(sock)
            result["v2_status"] = {k: st.get(k) for k in ("version", "build", "phase", "track", "bundle_id")}

        # Every agent host survived: adopted (with the handoff), same pids, the turn complete once, no cancel.
        agents = []
        for agent in (finished, running):
            adopted = agent.wait_event(lambda e: e.get("kind") == "host_adopted", 90) if a.handoff else None
            after = agent.identity()
            events = agent.events()
            agents.append({
                "session": agent.session, "host_before": agent.host_before, "host_after": after,
                "same_host": after == agent.host_before, "adopted": bool(adopted),
                "host_alive": bool(after.get("host_pid") and alive(after["host_pid"])),
                "harness_alive": bool(after.get("harness_pid") and alive(after["harness_pid"])),
                "transcript_prefix_preserved": events[:len(agent.events_before)] == agent.events_before,
                "turn_results": sum(e.get("kind") == "turn_result" for e in events),
                "turn_status": [((e.get("msg") or {}).get("status")) for e in events if e.get("kind") == "turn_result"],
                "after_gate_chunks": sum(1 for e in events if "after-gate" in json.dumps(e) and e.get("kind") != "prompt"),
                "cancel_events": [e.get("kind") for e in events if "cancel" in json.dumps(e).lower()],
                "outcome_unknown": any("outcome_unknown" in json.dumps(e) for e in events),
            })
        result["agents"] = agents
        result["census_after"] = census(acp_home, os.path.join(v1, "Contents/Resources/bin/acpmux"))
        before, after = result["census_before"], result["census_after"]
        pids = lambda c: sorted((h["session"], h["host_pid"], h["harness_pid"]) for h in c["hosts"])
        result["counts"] = {"host_records": [before["host_records"], after["host_records"]],
                            "live_hosts": [before["live_hosts"], after["live_hosts"]],
                            "acpmux_ls": [before.get("ls_count"), after.get("ls_count")],
                            "host_pids_unchanged": pids(before) == pids(after)}
        log("counts before/after", json.dumps(result["counts"]))
        verdicts = {
            "installed_v2": result["version_after"]["build"] == i2["CFBundleVersion"],
            "automatic": not result["install_marks"].get("install_clicked"),
            "waited_idle_time": start >= earliest - 1.5,
            "hosts_counts_equal": before["live_hosts"] == after["live_hosts"] == before["host_records"] == after["host_records"]
                                  and before.get("ls_count") == after.get("ls_count"),
            "host_pids_unchanged": result["counts"]["host_pids_unchanged"],
            "agents_survived": all(r["same_host"] and r["host_alive"] and r["harness_alive"] and r["transcript_prefix_preserved"]
                                   and (r["adopted"] or not a.handoff) for r in agents),
            "no_turn_cut": all(r["turn_results"] == 1 and r["turn_status"] == ["completed"] and not r["cancel_events"]
                               and not r["outcome_unknown"] for r in agents) and agents[1]["after_gate_chunks"] == 1,
        }
        result["verdicts"] = verdicts
        log("verdicts", json.dumps(verdicts))
        result["passed"] = all(verdicts.values())
        exit_code = 0 if result["passed"] else 1
    except SystemExit as error:
        result["failure"] = str(error)
        log("FAILED:", error)
    finally:
        result["marks"] = [r for r in Marks(marks_path).read()] if os.path.exists(marks_path) else []
        with open(os.path.join(out, "result.json"), "w") as f:
            json.dump(result, f, indent=1)
        for pid, identity in owned_apps.items():
            current = TagTeardown._table().get(pid)
            if current and current[1:] == identity:
                try:
                    os.kill(pid, signal.SIGTERM)  # an exact pid this run started
                    wait_exit(pid, 20)
                except ProcessLookupError:
                    pass
        result["session_processes_left"] = end_tag(teardowns, owned, acp_home, True, log)
        if server:
            server.terminate()
            server.wait(10)
        result["leftovers"] = [command[:200] for _, command in processes_under(work)]
        shutil.rmtree(keys, ignore_errors=True)
        if result.get("bundle_id"):
            record = os.path.join(os.environ["HOME"], "Library/Application Support/cmux-next", result["bundle_id"], "last-update.json")
            if os.path.exists(record):
                os.unlink(record)
        with open(os.path.join(out, "result.json"), "w") as f:
            json.dump(result, f, indent=1)
        log("RESULT", json.dumps({k: result.get(k) for k in ("expect", "passed", "failure", "counts", "version_before",
                                                          "version_after", "install_after_last_input_s")}))
    sys.exit(exit_code)


if __name__ == "__main__":
    main()
