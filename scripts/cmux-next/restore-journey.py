#!/usr/bin/env python3
"""Restore journey: quit cmux NEXT, reopen it, and check that everything came back.

The nightly consistency goal: after a quit (or an update relaunch) and a reopen, the windows,
workspaces, tabs, splits, browser pages, terminal scrollback and running programs, and agent
chats are all where they were. This script seeds that state in a running tagged build, takes a
canonical snapshot, quits through the app's own quit path, relaunches the same app with the
same environment, waits for restore to settle, snapshots again and prints a PASS/FAIL row per
item.

  scripts/cmux-next/restore-journey.py --socket /tmp/cmux-debug-<tag>-capslot<N>.sock \\
      [--variants quit,update] [--out DIR] [--fake-agent PATH] [--src STAGED_APP] [--update-to STAGED_APP_B]

Run it on the GUI host where the app already runs: a capture slot started by `capture-host
launch` (scripts/cmux-next/restore-journey-slot.sh does the whole slot run), or another tagged DEV
build with --allow-non-slot. It refuses an installed or untagged app.

Session continuity gate (Claude, Codex, agent chats and terminal agents come back live after a
quit, a crash, a daemon crash and a reboot):

  scripts/cmux-next/restore-journey-slot.sh JOB OUT -- --continuity It drives the app through
its control socket and the tag's daemon through the bundled `cmux` CLI.

Variants:
  quit    the Quit menu item / Cmd-Q path (`debug.quit {open: true}`; if the sheet asks, its
          default is pressed, as Return does, and the row records whether that keeps sessions);
  update  what Sparkle does before it relaunches into an update
          (`debug.updater {action: "relaunch"}`: the updater's relaunch hook, then terminate);
          with --update-to STAGED_APP_B the relaunch opens build B: once the app has ended, B is
          put at the installed copy's path with its identity (bundle id, tag, lease environment),
          as an update installs it (rj_update.py), so the state seeded on build A must come back
          on B (restore-journey-slot.sh JOB_A --update-to JOB_B OUT -- --variants update);
  crash   the app's exact pid is killed (SIGKILL), so none of its quit path runs;
  daemon  the app keeps running and its cmux-tui daemon is killed (SIGKILL) while an agent chat
          turn is in flight, as a daemon crash: the app must start a new one, reconnect and
          re-attach every view by itself, no input. Rows give the seconds from the kill to a new
          daemon, to the app connected to it and to restore settled; the UI, sampled every
          250 ms meanwhile, must show the designed recovery state (`debug.daemon`,
          `debug.surfaces`: each window its workspace or the connecting view, no blank pane, every
          shown terminal connected, restoring or reconnecting), and the turn must finish;
  daemon-stop  the daemon is frozen (SIGSTOP) instead, as a wedged owner: the app must notice
          (its heartbeat), offer Restart cmux-tui, and Restart (`debug.daemon {action: restart}`,
          the button's path after its confirm) must bring a new daemon and every view back. The
          stopped process is ended at the end if it is still there;
  reboot  the quit path, then every process the app's bundle started is killed with all its
          children (daemon, terminal hosts and their programs, acpmux, agent hosts), as a
          reboot or logout ends them. Running programs cannot come back (their rows are n/a);
          everything else must, and the agents part's sessions must be resumed and live;
  slow    the quit path, then a relaunch against a slow daemon (cx-wwtam; debug builds only):
          `CMUX_NEXT_DEBUG_SLOW_ATTACH=SLOW_ATTACH` makes every terminal attach wait, and the
          first ones of each terminal fail, as before a late daemon answers. With no input, every
          shown terminal must still attach (restore settles), and a terminal still attaching must
          say "Restoring…" (`debug.surfaces` link `restoring`).
  wedged  Quit and Keep Sessions over the socket (`action.run quitKeepSessions`) while the quit's
          engine stop blocks the main thread for good, as a wedged CefShutdown did (cx-ccjnn;
          `debug.quit {wedge_engine_stop: true}`, debug builds only): the app must still end within
          WEDGED_QUIT_BOUND seconds, by its quit deadline. If it never ends, its exact pid is
          killed so the restore rows still run.
Each relaunch reuses the app's own launch environment (read from the running process), so a
capture slot keeps its HOME, TMPDIR, socket and config file. It never runs `defaults delete`:
UserDefaults survive, as on a person's Mac. If the slot's app copy is gone after the quit,
`--src` re-clones it the way capture-host does (same bundle id, ad-hoc signed).

The seeded state, all named `rj-*` (earlier rj-* workspaces are closed first):
  window 1: rj-term (3000 numbered lines; a counter loop with a pid file in a right split; `top`
            in a nested down split; the counter's pane focused; selected at the end), rj-split (four terminals in nested
            right/down splits at uneven ratios, two tabs in one pane, the first selected, one tab renamed, one pinned), rj-web (two browser
            tabs from a local server: a page loaded from its address, then two link clicks
            (a -> b -> c), whose history length and Cmd-[ / Cmd-] walk are checked after
            seeding and after each reopen; and a tall page that scrolls itself the first
            time), rj-agent (an
            agent chat with the acpmux test agent: three turns and a draft); the window at a set
            frame;
  window 2: rj-w2 (a terminal with a marker line and a browser tab zoomed in three Cmd-+ steps
            from 100%), at another frame;
  window 3: rj-w3 (the new workspace Open Space in New Window opens on a new space rj-room-<run>,
            renamed, a terminal with a marker line), at a third frame;
  agents:   rj-chats (agent chats with the test agent as a Claude Code harness, a non-default
            model picked, and as a Codex harness: two turns and an unsent draft each) and
            rj-tagents (terminal tabs running `claude` and `codex` stand-ins,
            rj_fake_cli_agent.py, with launch flags and their account folder in
            CLAUDE_CONFIG_DIR / CODEX_HOME, one turn each), --agents-per-kind of each; every
            one must be back in its tab, with its transcript, model, draft and flags, signed in,
            and answer a new turn;
  cloud:    a Move to Cloud state of made-up machines `rj-<run>-*` (`debug.cloud.move_seed`,
            debug builds only; no Cloud account, machine or network): two moved chats, three move
            Retries, a Bring Back Local Retry, an "Always" folder grant and a dismissed launch offer.

Restore has settled when the topology is loaded with every rj-* tab back, the launch window has
handed over (`debug.windows`) and every shown terminal view is attached live (`debug.surfaces`).

Compared before vs after: windows (count, frames, workspaces in order, selection), each rj-*
workspace's panes, tabs (kind, order, selection), split tree with ratios (daemon `screen layout
export`), terminal ids, cwds and scrollback (rows, hash, the numbered lines), the view's text of
the scrollback terminal, the counter (same pid, alive, still counting in the daemon and in the
view), each page's own report of its path and scroll after the reload (no script reads a page),
the agent chat (tab bound to its session, the session's prompts, draft and what the chat
page shows), the Move to Cloud state (`debug.cloud.move_state`: each record's ids, kind and
digest, against what was seeded), the focused pane, `top` still drawing (daemon and view), and each terminal pane's
size and grid as the app lays it out (rj-split's ratios are uneven, so evened-out splits fail). Output: a table on stdout, `report.json`, raw dumps and window stills in --out.
Exit 0 only when every row passes.

Nothing outside the app's own tag state is changed: no settings.set (the shared config of a
capture mini); the acpmux config gets harness `fake` for the run and is put back; the local
web server, pid file and chat folder live in --out (the fake chats themselves stay in the
tag's acpmux home). The app is left running after the last
relaunch (the caller quits it and releases the slot).
"""
import argparse, atexit, glob, hashlib, http.server, json, os, plistlib, re, shlex, signal, socket, subprocess, sys, threading, time
from urllib.parse import parse_qs, urlparse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import build_names  # noqa: E402  (next to this script; restore-journey-slot.sh copies both)
import rj_rows  # noqa: E402  (next to this script, copied the same way)
import rj_update  # noqa: E402  (next to this script, copied the same way)

HERE = os.path.dirname(os.path.abspath(__file__))
parser = argparse.ArgumentParser()
parser.add_argument("--socket", required=True, help="the app's control socket")
parser.add_argument("--variants", default=None, help="comma list (default quit,update,crash)")
parser.add_argument("--continuity", action="store_true",
                    help="the session continuity gate: --variants quit,crash,daemon,daemon-stop,reboot (or the --variants "
                         "given) with only the agent parts "
                         "(--skip web,w2,cloud,split) and one session per kind, so it fits one capture-slot lease")
parser.add_argument("--out", default="/tmp/restore-journey")
parser.add_argument("--fake-agent", default=os.path.join(HERE, "../../cmux-tui/crates/acpmux/tests/fake_agent.py"))
parser.add_argument("--src", help="staged app to re-clone from when the slot's app copy is gone after a quit")
parser.add_argument("--update-to", metavar="STAGED_APP_B",
                    help="the update variant installs this build in place of the app's copy before it relaunches "
                         "(build A's state, restored by build B); needs --src (build A, staged)")
parser.add_argument("--settle", type=float, default=90, help="seconds restore may take to settle")
parser.add_argument("--skip", default="", help="comma list of seed parts to skip: term,split,web,agent,w2,w3,cloud,agents")
parser.add_argument("--agents-per-kind", type=int, default=2,
                    help="the agents part: chats per harness (Claude, Codex) and terminal agents per CLI (claude, codex)")
parser.add_argument("--break-cloud", choices=["moved_chat", "move_retry", "bring_back_retry", "grant", "dismissed"],
                    help="proof the cloud rows check something: after the first relaunch, forget one seeded record of this "
                         "kind (`debug.cloud.move_seed {drop}`), so its row must FAIL")
parser.add_argument("--max-seconds", type=int, default=0, help="stop (restoring what it changed) after this long; 0: no limit")
parser.add_argument("--activate", action="store_true",
                    help="relaunch as a person's launch does (activating, without CMUX_NEXT_NO_ACTIVATE), so window order and focus follow real key windows")
parser.add_argument("--hist-file", action="store_true",
                    help="serve the history pages as file:// pages (as a person opens a local .html), reporting to the local server")
parser.add_argument("--engine", choices=["webkit", "chromium"],
                    help="browser engine for the seeded pages: written to the capture slot's own settings file "
                         "(CMUX_NEXT_CONFIG_FILE under the slot, never a shared one) and put back at the end")
parser.add_argument("--allow-non-slot", action="store_true",
                    help="drive a tagged DEV build that is not in a capture slot (it closes rj-* workspaces, quits and relaunches it)")
opts = parser.parse_args()
if opts.continuity:
    opts.variants = opts.variants or "quit,crash,daemon,daemon-stop,reboot"
    opts.skip, opts.agents_per_kind = "web,w2,cloud,split", 1
opts.variants = opts.variants or "quit,update,crash"
if opts.update_to:
    if "update" not in [v.strip() for v in opts.variants.split(",")]:
        sys.exit("--update-to needs the update variant (--variants update)")
    if not os.path.isdir(opts.update_to) or not opts.src:
        sys.exit("--update-to needs a staged build B and --src, the staged build A the slot's copy was made from")
os.makedirs(opts.out, exist_ok=True)
SKIP = {s.strip() for s in opts.skip.split(",") if s.strip()}
AGENTS_N = max(1, opts.agents_per_kind)
LOG = open(os.path.join(opts.out, "journey.log"), "a")
RUN = os.urandom(3).hex()
SCROLLBACK_LINES = 3000
SCROLL = 1500
SIDEBAR_WIDTH = 312  # points: neither layout's default (208, 240), inside the 160...360 drag range
FONT_STEPS = 2  # Cmd-+ steps on the counter's terminal
PIDFILE = os.path.join(opts.out, f"counter-{RUN}.pid")



def say(*parts):
    line = " ".join(str(p) for p in parts)
    print(line, flush=True)
    LOG.write(time.strftime("%H:%M:%S ") + line + "\n")
    LOG.flush()


def wait(predicate, seconds, step=0.5):
    deadline = time.time() + seconds
    while time.time() < deadline:
        if os.getppid() == 1:  # the run that started this one is gone (ssh dropped): stop driving the app
            sys.exit("restore-journey: parent gone; stopping")
        value = predicate()
        if value:
            return value
        time.sleep(step)
    return None


def rpc(method, params=None, timeout=60):
    """One request on the app's control socket; the result, or {"error": ...}."""
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(timeout)
        conn.connect(opts.socket)
        conn.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = conn.recv(1 << 22)
            if not chunk:
                break
            buf += chunk
        conn.close()
        reply = json.loads(buf)
        return reply.get("result") if reply.get("ok") else {"error": reply.get("error")}
    except (OSError, ValueError) as error:
        return {"error": str(error)}


def action(name, **params):
    answer = rpc("action.run", {"action": name, **params}, timeout=90)
    say(f"  action {name} {json.dumps(params)[:120]} -> {json.dumps(answer)[:200]}")
    return answer


def dump(name, value):
    with open(os.path.join(opts.out, name), "w") as f:
        json.dump(value, f, indent=1, sort_keys=True, default=str)


# ---- the app process: identity, environment, quit, relaunch -----------------------------

# The slow variant's daemon: each terminal's first 3 attaches fail, every attach waits 1 s.
SLOW_ATTACH = "3:1000"
# The quit deadline (QuitDeadline.keepQuitLimit, 4 s after a keep quit is decided) plus
# margin for a loaded mini.
WEDGED_QUIT_BOUND = 10


class App:
    def __init__(self):
        self.refresh()
        info = self.info
        self.bundle = info.get("app_bundle_path")
        self.cli = info.get("app_cli_path") or os.path.join(self.bundle, "Contents/Resources/bin/cmux")
        self.tag = info.get("tag")
        self.bundle_id = info.get("bundle_id")
        self.env = self.environment(self.pid)
        say(f"app pid {self.pid} tag {self.tag} bundle {self.bundle} id {self.bundle_id}")
        self.check_target()

    def names(self):
        """The build's own names (build_names.py): socket, session, acpmux home; None if unknown."""
        try:
            return build_names.of_app(self.bundle) if self.bundle else None
        except ValueError:
            return None

    def sessions(self):
        """The app daemon's session: of the build key, or `cmux-app-<tag>` from before per-build isolation."""
        return [s for s in ((self.names() or {}).get("session"), f"cmux-app-{self.tag}") if s]

    def check_target(self):
        """Only a tagged DEV build, never a person's cmux: the journey closes rj-* workspaces,
        quits and relaunches the app and edits its tag's acpmux config."""
        bundle_id, bundle = self.bundle_id or "", self.bundle or ""
        problems = []
        if not self.tag:
            problems.append("the app has no tag")
        if ".debug" not in bundle_id:
            problems.append(f"bundle id {bundle_id!r} is not a DEV build's")
        if not bundle or bundle.startswith("/Applications/"):
            problems.append(f"bundle {bundle!r} is an installed app")
        if not opts.allow_non_slot and "capslot" not in bundle_id and not self.env.get("CMUX_CAPTURE_SLOT"):
            problems.append("not a capture slot's app (pass --allow-non-slot for another tagged DEV build)")
        if problems:
            sys.exit("restore-journey refuses this app: " + "; ".join(problems))

    def refresh(self):
        info = rpc("system.identify")
        if not isinstance(info, dict) or "error" in info or not info.get("pid"):
            sys.exit(f"no app answers on {opts.socket}: {info}")
        self.info, self.pid = info, int(info["pid"])

    @staticmethod
    def environment(pid):
        """The app's own launch variables (`ps eww`, same user): the CMUX_* ones plus HOME and
        TMPDIR, which is what a capture slot or a test launch sets."""
        out = subprocess.run(["ps", "eww", "-o", "command=", "-p", str(pid)], capture_output=True, text=True).stdout
        env = {}
        for word in out.split():
            key, sep, value = word.partition("=")
            if sep and (key.startswith("CMUX_") or key in ("HOME", "TMPDIR")):
                env[key] = value
        return env

    def alive(self):
        try:
            os.kill(self.pid, 0)
            return True
        except ProcessLookupError:
            return False
        except PermissionError:
            return True

    def quit(self, variant):
        """Ends the app (its own quit path, or a crash) and waits for the exact pid to exit."""
        if variant == "daemon":
            # The app keeps running; only its cmux-tui daemon process ends (SIGKILL), as a daemon
            # crash does. Its terminal hosts and acpmux live on.
            pids = self.daemon_pids()
            self.killed_daemons = set(pids)
            say(f"  daemon: SIGKILL {pids}")
            for pid in pids:
                try:
                    os.kill(pid, signal.SIGKILL)
                except OSError:
                    pass
            RESULTS.append(("daemon: the app's daemon is found and killed", bool(pids), f"pids {pids}", "app quit"))
            return bool(pids)
        if variant == "daemon-stop":
            # A wedged owner: the daemon stops answering but keeps its socket open (SIGSTOP).
            pids = self.daemon_pids()
            self.killed_daemons = set(pids)
            STOPPED.update(pids)
            say(f"  daemon-stop: SIGSTOP {pids}")
            for pid in pids:
                try:
                    os.kill(pid, signal.SIGSTOP)
                except OSError:
                    pass
            RESULTS.append(("daemon-stop: the app's daemon is found and stopped", bool(pids), f"pids {pids}", "app quit"))
            return bool(pids)
        if variant == "crash":
            # A crash: the app's exact pid ends at once (SIGKILL); nothing of the app's own quit runs.
            # Only the pid the slot's socket names right now, and only while it is alive.
            answer = rpc("system.identify", timeout=5)
            if not (isinstance(answer, dict) and int(answer.get("pid") or 0) == self.pid and self.alive()):
                say(f"  crash: the socket no longer names pid {self.pid}; not killing anything")
                return False
            say(f"  crash: SIGKILL pid {self.pid}")
            try:
                os.kill(self.pid, signal.SIGKILL)
            except OSError as error:
                say(f"  crash: kill failed: {error}")
                return False
        elif variant == "wedged":
            armed = rpc("debug.quit", {"wedge_engine_stop": True}, timeout=10)
            say(f"  debug.quit wedge_engine_stop -> {json.dumps(armed)[:200]}")
            if not (isinstance(armed, dict) and armed.get("wedges_engine_stop") is True):
                # A build without the seam (not a debug build) would quit normally and pass falsely.
                RESULTS.append((f"{variant}: the engine-stop wedge is armed", False, "debug.quit has no wedge_engine_stop (not a debug build?)", "harness"))
                return False
            started = time.time()
            say(f"  action.run quitKeepSessions -> {json.dumps(rpc('action.run', {'action': 'quitKeepSessions'}, timeout=30))[:200]}")
            ended = wait(lambda: not self.alive(), 60, 0.25)
            took = time.time() - started
            in_bound = bool(ended) and took <= WEDGED_QUIT_BOUND
            say(f"  app pid {self.pid} {f'exited {took:.1f} s after its quit' if ended else 'is STILL RUNNING after 60 s'}")
            RESULTS.append((f"{variant}: app ends within {WEDGED_QUIT_BOUND} s with its engine stop wedged", in_bound,
                            f"exited after {took:.1f} s" if ended else "still running after 60 s", "app quit"))
            if ended:
                return True
            # The red case: action.run is wedged too (the main thread never runs it).
            answer = rpc("action.run", {"action": "equalizeSplits"}, timeout=10)
            RESULTS.append((f"{variant}: action.run still runs while the quit hangs", isinstance(answer, dict) and "error" not in answer,
                            json.dumps(answer)[:160], "app quit"))
            identity = rpc("system.identify", timeout=5)
            if isinstance(identity, dict) and int(identity.get("pid") or 0) == self.pid and self.alive():
                say(f"  wedged: SIGKILL pid {self.pid} so the restore rows still run")
                os.kill(self.pid, signal.SIGKILL)
            return bool(wait(lambda: not self.alive(), 20, 0.25))
        elif variant == "update":
            say(f"  debug.updater relaunch -> {json.dumps(rpc('debug.updater', {'action': 'relaunch'}, timeout=30))[:200]}")
        else:
            say(f"  debug.quit open -> {json.dumps(rpc('debug.quit', {'open': True}, timeout=30))[:200]}")
            # Cmd-Q may ask about the local terminals: answer with the sheet's default, as a
            # person pressing Return does, and record what it was.
            def asking():
                if not self.alive():
                    return "gone"
                report = rpc("debug.quit", timeout=5)
                return report if isinstance(report, dict) and report.get("asking") else None
            sheet = wait(asking, 8, 0.3)
            if isinstance(sheet, dict):
                dump(f"quit-sheet-{variant}.json", sheet)
                default = str((sheet.get("prompt") or {}).get("default"))
                say(f"  quit sheet asks (default {default}, buttons {[b.get('id') for b in sheet.get('buttons') or []]}); pressing the default")
                RESULTS.append((f"{variant}: quit sheet default keeps sessions", "keep" in default, f"default {default}", "app quit"))
                rpc("debug.quit", {"press": "keep" if "keep" in default else default}, timeout=10)
        ended = wait(lambda: not self.alive(), 60, 0.25)
        say(f"  app pid {self.pid} {'exited' if ended else 'is STILL RUNNING after 60 s'}")
        self.rebooted = False
        if ended and variant == "reboot":
            self.rebooted = True
            return self.power_off()
        return bool(ended)

    def daemon_pids(self):
        """The pids of this app's own cmux-tui daemon (its session, run from its bundle)."""
        out = subprocess.run(["ps", "axo", "pid=,args="], capture_output=True, text=True).stdout
        return [int(line.split(None, 1)[0]) for line in out.splitlines()
                if len(line.split(None, 1)) == 2 and line.split(None, 1)[1].startswith(self.bundle + "/")
                and "--headless" in line and any(f"--session {s} " in line + " " for s in self.sessions())]

    def power_off(self):
        """The rest of a reboot, after the app's own quit: every process the app's bundle started
        ends at once (SIGKILL), with all of their children: the daemon, its terminal hosts and the
        shells and programs in them, acpmux and its agent hosts and agents. Only processes run from
        this app's own bundle (a capture slot's clone) and their descendants."""
        table = subprocess.run(["ps", "axo", "pid=,ppid=,args="], capture_output=True, text=True).stdout
        procs = []
        for line in table.splitlines():
            parts = line.split(None, 2)
            if len(parts) == 3 and parts[0].isdigit() and parts[1].isdigit():
                procs.append((int(parts[0]), int(parts[1]), parts[2]))
        roots = {pid for pid, _, args in procs if args.startswith(self.bundle + "/") and pid != os.getpid()}
        # Terminal hosts run from a copy of the daemon's executable (host_exe.rs) with launchd as
        # their parent and a bare `cmux-tui` argv[0]; each names its owner, this app's bundle id.
        try:
            with open(os.path.join(self.bundle, "Contents", "Info.plist"), "rb") as f:
                bundle_id = plistlib.load(f).get("CFBundleIdentifier") or ""
        except (OSError, plistlib.InvalidFileException):
            bundle_id = ""
        if bundle_id:
            owner = f"--owner {bundle_id}:"
            roots |= {pid for pid, _, args in procs if "--bootstrap-stdio" in args and owner in args}
        doomed, grew = set(roots), True
        while grew:
            more = {pid for pid, ppid, _ in procs if ppid in doomed and pid not in doomed and pid != os.getpid()}
            doomed |= more
            grew = bool(more)
        say(f"  reboot: SIGKILL {len(doomed)} processes ({len(roots)} run from the bundle)")
        dump("reboot-killed.json", sorted([pid, args[:200]] for pid, _, args in procs if pid in doomed))
        for pid in doomed:
            try:
                os.kill(pid, signal.SIGKILL)
            except OSError:
                pass
        def gone():
            for pid in doomed:
                try:
                    os.kill(pid, 0)
                    return False
                except ProcessLookupError:
                    continue
                except PermissionError:
                    return False
            return True
        ok = wait(gone, 20, 0.25)
        RESULTS.append(("reboot: every process of the app's bundle ends", bool(roots) and bool(ok),
                        f"{len(doomed)} killed, {len(roots)} from the bundle", "app quit"))
        # acpmux went with it: the run's connection is dead; the next use reconnects.
        ACPMUX.pop("client", None)
        return bool(ok)

    def ensure_bundle(self):
        if os.path.isdir(self.bundle):
            return True
        if UPDATED.get("identity"):
            # After the update the copy is build B with the copy's identity (tag, lease environment), not a bare clone.
            say(f"  re-installing {opts.update_to} -> {self.bundle} (the updated copy's identity)")
            rj_update.reinstall(self.bundle, opts.update_to, opts.src, UPDATED["identity"])
            return True
        if not opts.src:
            say(f"  the app copy {self.bundle} is gone and no --src was given")
            return False
        say(f"  re-cloning {opts.src} -> {self.bundle} (bundle id {self.bundle_id})")
        if subprocess.run(["cp", "-cR", opts.src, self.bundle]).returncode != 0:
            subprocess.run(["cp", "-R", opts.src, self.bundle], check=True)
        plist = os.path.join(self.bundle, "Contents/Info.plist")
        subprocess.run(["/usr/libexec/PlistBuddy", "-c", f"Set :CFBundleIdentifier {self.bundle_id}", plist], check=True)
        subprocess.run(["/usr/bin/codesign", "--force", "--deep", "--sign", "-", self.bundle], capture_output=True)
        return True

    def relaunch(self, extra_env=None):
        if not self.ensure_bundle():
            return False
        # The updater's hook may relaunch the app itself: never start a second copy beside it.
        answer = rpc("system.identify", timeout=5)
        if isinstance(answer, dict) and answer.get("pid") and int(answer["pid"]) != self.pid:
            self.refresh()
            say(f"  the app relaunched itself: pid {self.pid}")
            return True
        if os.path.exists(opts.socket):
            os.unlink(opts.socket)
        args = ["/usr/bin/open", "-n", "-a", self.bundle] if opts.activate else ["/usr/bin/open", "-g", "-n", "-a", self.bundle]
        for key, value in self.env.items():
            if opts.activate and key == "CMUX_NEXT_NO_ACTIVATE":
                continue
            args += ["--env", f"{key}={value}"]
        for key, value in (extra_env or {}).items():
            args += ["--env", f"{key}={value}"]
        subprocess.run(args, check=True)
        up = wait(lambda: os.path.exists(opts.socket) and (lambda r: isinstance(r, dict) and r.get("pid"))(rpc("system.identify", timeout=5)), 60, 0.5)
        if not up:
            say("  the relaunched app never answered on its socket")
            return False
        self.refresh()
        say(f"  relaunched: pid {self.pid}")
        return True


UPDATED = {}  # --update-to: what rj_update.install reported, once build B is in place


def update_build():
    """--update-to: build B in place of the ended app's copy, as an update installs it (rj_update.py).
    Rows: B is installed with the copy's identity (same names, so A's saved state is B's), and it is
    another build than A. False stops the journey (the copy is left as it was)."""
    answer = rpc("system.identify", timeout=5)
    if APP.alive() or (isinstance(answer, dict) and answer.get("pid")):
        RESULTS.append(("update: build B is installed in place", False, f"an app still runs (pid {APP.pid}, socket {answer})", "update"))
        return False
    UPDATED["from_version"] = [APP.info.get("version"), APP.info.get("build")]
    try:
        report = rj_update.install(APP.bundle, opts.update_to, opts.src)
    except (OSError, RuntimeError, ValueError, subprocess.CalledProcessError) as error:
        RESULTS.append(("update: build B is installed in place", False, str(error)[:300], "update"))
        return False
    UPDATED.update(report)
    dump("update-install.json", {k: v for k, v in UPDATED.items() if k != "identity"})
    say(f"  update: {report['from_commit']} -> {report['to_commit']} at {APP.bundle}; {'; '.join(report['notes']) or 'same identity'}")
    RESULTS.append(("update: build B is installed in place with the copy's names", report["names_before"] == report["names_after"],
                    f"{report['names_after']['session']}; {'; '.join(report['notes']) or 'same identity'}", "update"))
    RESULTS.append(("update: build B is another build than A", rj_update.different_builds(report["from_commit"], report["to_commit"]),
                    f"{report['from_commit']} -> {report['to_commit']}", "update"))
    return True


def updated_rows():
    """After the relaunch into B: the running app is a new process of B's version, at the same path."""
    want = UPDATED.get("to_version") or [None, None]
    got = [APP.info.get("version"), APP.info.get("build")]
    same_place = APP.info.get("app_bundle_path") == APP.bundle and APP.info.get("bundle_id") == APP.bundle_id
    RESULTS.append(("update: the relaunched app runs build B", same_place and got == want,
                    f"version {UPDATED.get('from_version')} -> {got} (B ships {want}), pid {APP.pid}, {APP.info.get('app_bundle_path')}",
                    "update"))


# ---- the tag's daemon (bundled CLI) and acpmux ----------------------------------------------

def daemon_socket():
    """The headless daemon this app started (`cmux-tui --headless --session cmux-app-<tag>
    --socket <path>`, run from the app bundle): its socket, from its own arguments."""
    out = subprocess.run(["ps", "axo", "args="], capture_output=True, text=True).stdout
    for line in out.splitlines():
        if line.startswith(APP.bundle + "/") and "--headless" in line and any(f"--session {s} " in line + " " for s in APP.sessions()):
            m = re.search(r"--socket (\S+)", line)
            if m:
                return m.group(1)
    return None


def cli(*args, timeout=60, quiet=False):
    """The bundled `cmux` on the tag's daemon, `--json`; the parsed answer, or {"error": ...}."""
    sock = daemon_socket()
    if not sock:
        return {"error": "no daemon socket"}
    env = {"HOME": APP.env.get("HOME", os.environ["HOME"]), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_QUIET": "1"}
    r = subprocess.run([APP.cli, "--socket", sock, "--json", *args], capture_output=True, text=True, timeout=timeout, env=env)
    try:
        answer = json.loads(r.stdout)
    except ValueError:
        answer = {"error": (r.stdout + r.stderr).strip()[:400]}
    if not quiet:
        say(f"  cli {' '.join(args)[:120]} -> {json.dumps(answer)[:200]}")
    return answer


def value(answer):
    return answer.get("value", {}) if isinstance(answer, dict) else {}


def acpmux_socket_of(home):
    """acpmux `config::socket_path()`: `<home>/acpmux.sock`, or `/tmp/acpmux-<uid>/<fnv1a64>.sock`
    when that is too long for sun_path."""
    preferred = os.path.join(home, "acpmux.sock")
    if len(preferred.encode()) < 96:
        return preferred
    h = 0xcbf29ce484222325
    for byte in home.encode():
        h = ((h ^ byte) * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF
    return f"/tmp/acpmux-{os.getuid()}/{h:016x}.sock"


def acpmux_home():
    """The app's acpmux home: <the app's HOME>/.acpmux/builds/<build key> (a slot's home on a capture
    slot), else <account home>/.acpmux/builds/<build key> (build_names.py has the app's rule), or, for a build from before per-build
    isolation, builds/com.cmuxterm.app.debug.<tag slug>. Never /tmp/acpmux-<uid> as such: other
    apps' daemons live there."""
    slug = re.sub(r"[^a-z0-9]+", "-", (APP.tag or "").lower()).strip("-")
    homes = []
    # A capture slot launches the app with the slot's home as HOME (capture-host since hq#4961): its
    # acpmux home is under that home, by the same build key.
    if APP.bundle and APP.env.get("HOME"):
        try:
            homes.append(build_names.of_app(APP.bundle, APP.env["HOME"])["acpmux_home"])
        except ValueError:
            pass
    homes += [APP.names()["acpmux_home"]] if APP.names() else []
    for base in {os.path.expanduser("~"), APP.env.get("HOME", "")}:
        if base:
            homes.append(os.path.join(base, ".acpmux", "builds", "com.cmuxterm.app.debug." + re.sub(r"[^a-z0-9]+", ".", slug).strip(".")))
    return next((home for home in homes if os.path.exists(acpmux_socket_of(home))), None)


class Acpmux:
    """One request/answer connection to acpmux (JSON-RPC lines); notifications are dropped."""

    def __init__(self, path):
        self.path, self.reconnects = path, 0
        self.connect()

    def connect(self):
        if getattr(self, "conn", None):
            self.conn.close()
        self.conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.conn.settimeout(60)
        self.conn.connect(self.path)
        self.next, self.buf = 0, b""
        self.send("initialize", {"protocolVersion": 1, "clientInfo": {"name": "restore-journey"}})

    def request(self, method, params, timeout=60):
        """One request; when acpmux restarted under the connection (an app quit or reboot can end
        it), connect again once and resend."""
        try:
            answer = self.send(method, params, timeout)
        except socket.timeout:
            # A slow answer is not a closed connection: never send it again.
            return {"error": {"message": f"no answer to {method} within {timeout} s"}}
        except OSError:
            answer = {"error": {"message": "closed"}}
        if answer.get("error", {}).get("message") != "closed":
            return answer
        self.reconnects += 1
        say(f"  acpmux connection closed; reconnecting ({self.reconnects})")

        def connected():
            # A killed acpmux leaves its socket file: retry the connect itself until one answers.
            try:
                self.connect()
                return True
            except OSError:
                return False
        if not wait(connected, 60, 0.5):
            return {"error": {"message": "reconnect failed: acpmux did not answer within 60 s"}}
        try:
            return self.send(method, params, timeout)
        except OSError as error:
            return {"error": {"message": f"after reconnecting: {error}"}}

    def send(self, method, params, timeout=60):
        self.next += 1
        rid = self.next
        self.conn.settimeout(timeout)
        self.conn.sendall((json.dumps({"jsonrpc": "2.0", "id": rid, "method": method, "params": params}) + "\n").encode())
        while True:
            while b"\n" in self.buf:
                line, self.buf = self.buf.split(b"\n", 1)
                try:
                    message = json.loads(line)
                except ValueError:
                    continue
                if message.get("id") == rid and ("result" in message or "error" in message):
                    return message
            chunk = self.conn.recv(1 << 20)
            if not chunk:
                return {"error": {"message": "closed"}}
            self.buf += chunk


ACPMUX_RESTORE = []
atexit.register(lambda: restore_acpmux_config())
for _sig in (signal.SIGTERM, signal.SIGHUP, signal.SIGALRM):
    signal.signal(_sig, lambda *_: sys.exit(1))  # runs finally blocks and atexit
if opts.max_seconds:
    signal.alarm(opts.max_seconds)


def configure_fake(home):
    path = os.path.join(home, "config.json")
    try:
        with open(path) as f:
            original = f.read()
    except FileNotFoundError:
        original = None
    config = json.loads(original) if original else {}
    harnesses = config.setdefault("harnesses", {})
    harnesses["fake"] = {"argv": ["python3", os.path.abspath(opts.fake_agent)]}
    # The chats of the agents part: the test agent as a Claude Code and a Codex harness (their
    # family, so the app treats them as Claude and Codex chats: picker, chips, resume path).
    for name, profile in CHAT_PROFILES.items():
        harnesses[name] = {"argv": ["python3", os.path.abspath(opts.fake_agent)], **profile}
    ACPMUX_RESTORE.append((path, original))  # first, so an exit at any point after puts it back
    with open(path + ".rj", "w") as f:
        f.write(json.dumps(config, indent=2))
    os.replace(path + ".rj", path)
    client = Acpmux(acpmux_socket_of(home))
    say(f"  acpmux reload_config -> {json.dumps(client.request('_acpmux/reload_config', {}))[:160]}")
    return client


def restore_acpmux_config():
    for path, original in ACPMUX_RESTORE:
        try:
            if original is None:
                os.remove(path)
            else:
                with open(path + ".rj", "w") as f:
                    f.write(original)
                os.replace(path + ".rj", path)
        except OSError as error:
            print("could not restore", path, error, file=sys.stderr)
            continue
        try:
            Acpmux(acpmux_socket_of(os.path.dirname(path))).request("_acpmux/reload_config", {}, timeout=10)
        except Exception as error:  # restored on disk; acpmux reads it at its next start
            print("could not reload acpmux config", path, error, file=sys.stderr)
    ACPMUX_RESTORE.clear()


# ---- the local web server: pages that report their own path and scroll ---------------------

REPORTS = {}  # page name -> latest {path, scrollY, at}
LIVE_READ = {}  # the seeded history page's outside-folder read probe, before the first quit
SINCE = 0.0  # when the last quit ended: reports older than this are stale
CHAT_CONNECT_BOUND = 10  # seconds a shown chat page may take to connect after a relaunch
SERVED = set()
REPORT_LOG = []  # (page name, time) of every report: when each page first reported after a relaunch
PAGE_LOADS = []  # (page name, time) of every page the server sent: a reopened page loads once
LOCK = threading.Lock()


def outside_image():
    """A 1x1 PNG next to the local history pages' folder, not in it."""
    path = os.path.join(opts.out, "outside", "dot.png")
    if not os.path.exists(path):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as f:
            f.write(bytes.fromhex("89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c489"
                                  "0000000d49444154789c63f8cfc0f01f00050001ff89993d1d0000000049454e44ae426082"))
    return path


def outside_text():
    """A text file beside `outside_image`, outside the local history pages' folder."""
    path = os.path.join(os.path.dirname(outside_image()), "secret.txt")
    if not os.path.exists(path):
        with open(path, "w") as f:
            f.write("rj-secret")
    return path


def page_html(name, base=""):
    body = "".join(f"<p style='height:40px;margin:0'>rj {name} row {i}</p>" for i in range(400)) if name == "tall" else ""
    act = ""
    if name == "tall":
        # The server, not the HTML, says whether to scroll: only the first load asks and gets a
        # yes. A copy of the page from a cache runs this same script and asks again (no).
        act = ("try{var q=new XMLHttpRequest();q.open('GET','" + base + "/act?page=tall&t='+Date.now(),false);q.send();"
               f"if(q.responseText==='1'){{setTimeout(function(){{acted=1;window.scrollTo(0,{SCROLL});}},300);}}}}catch(e){{}}")
    # The history pages link on (a -> b -> c), for link-click navigation as a person's.
    nxt = {"hist-a": "hist-b", "hist-b": "hist-c"}.get(name)
    href = f"{nxt}.html" if opts.hist_file else f"/{nxt}"
    # The link covers the page, so a click at the pane's center lands on it.
    link = f"<a id='next' href='{href}' style='position:fixed;inset:0;display:block'>next</a>" if nxt else ""
    # A local history page also tries to show an image from outside its folder: a page loaded
    # with access to its own folder cannot (`ext` 0), after a reopen too.
    if opts.hist_file and name.startswith("hist"):
        link += f"<img id='probe' src='file://{outside_image()}' style='width:1px;height:1px'>"
        # And to read a file outside its folder (`rd`): a fresh load cannot (fetch from a file page),
        # so a restore that read it would have widened the page's file access.
        read = (f"try{{var x=new XMLHttpRequest();x.open('GET','file://{outside_text()}',false);x.send();"
                "rd=x.responseText.indexOf('rj-secret')>=0?1:0;}catch(e){rd=0;}")
    else:
        read = ""
    # Both history pages report as one tab ("hist").
    tab = "hist" if name.startswith("hist") else name
    return f"""<!doctype html><html><head><title>rj {name}</title></head><body>
<h1>rj {name}</h1>{link}{body}
<script>
var acted=0;
function report(){{var p=location.pathname.replace(/^.*\\//,'/').replace(/\\.html$/,'');
var probe=document.getElementById('probe'),ext=probe?(probe.complete&&probe.naturalWidth>0?1:0):-1,rd=-1;{read}
new Image().src='{base}/report?page={tab}&path='+encodeURIComponent(p)+'&y='+Math.round(window.scrollY)+'&h='+history.length+'&ext='+ext+'&rd='+rd+'&s='+acted+'&w='+window.innerWidth+'&t='+Date.now();}}
{act}
setInterval(report,1000); window.addEventListener('scroll',report); window.addEventListener('pageshow',report); report();
</script></body></html>"""


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        url = urlparse(self.path)
        if url.path == "/act":
            page = parse_qs(url.query).get("page", [""])[0]
            with LOCK:
                first = page not in SERVED
                SERVED.add(page)
            data = b"1" if first else b"0"
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        if url.path == "/report":
            q = parse_qs(url.query)
            with LOCK:
                REPORT_LOG.append((q.get("page", [""])[0], time.time()))
                REPORTS[q.get("page", [""])[0]] = {"path": q.get("path", [""])[0], "scrollY": int(q.get("y", ["0"])[0]),
                                                   "history": int(q.get("h", ["0"])[0]), "ext": int(q.get("ext", ["-1"])[0]),
                                                   "read": int(q.get("rd", ["-1"])[0]),
                                                   "self_scrolled": int(q.get("s", ["0"])[0]),
                                                   "width": int(q.get("w", ["0"])[0]),
                                                   "at": time.time()}
            self.send_response(204)
            self.end_headers()
            return
        with LOCK:
            PAGE_LOADS.append((url.path.strip("/") or "index", time.time()))
        data = page_html(url.path.strip("/") or "index").encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


def start_server():
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, f"http://127.0.0.1:{server.server_address[1]}"


# ---- seeding ---------------------------------------------------------------------------------

def topology():
    snap = rpc("snapshot.get")
    return (snap or {}).get("topology") if isinstance(snap, dict) else None


def rj_workspaces(topo):
    return [w for w in (topo or {}).get("workspaces", []) if (w.get("name") or "").startswith("rj-")]


def workspace_named(name, topo=None):
    return next((w for w in (topo or topology() or {}).get("workspaces", []) if w.get("name") == name), None)


def tabs_of(ws):
    return [tab for screen in (ws or {}).get("screens", []) for pane in screen.get("panes", []) for tab in pane.get("tabs", [])]


def write(term, text):
    return cli("terminal", term, "write", "--text", text)


def split(pane, direction, ratio=None):
    return value(cli("pane", pane, "split", f"--{direction}", *(["--ratio", str(ratio)] if ratio else [])))


def new_workspace(name):
    created = value(cli("workspace", "create", "--name", name))
    if not created.get("workspace_id"):
        say(f"  workspace {name} was not created")
    return created


def seed_term():
    if os.path.exists(PIDFILE):
        os.remove(PIDFILE)
    ws = new_workspace("rj-term")
    if not ws.get("terminal_id"):
        return
    write(ws["terminal_id"], f"cd {shlex.quote(opts.out)}; for i in $(seq 1 {SCROLLBACK_LINES}); do echo rj-line-$i-{RUN}; done; echo rj-scrollback-done\n")
    right = split(ws["pane_id"], "right")
    if right.get("terminal_id"):
        write(right["terminal_id"], f"sh -c 'echo $$ > {shlex.quote(PIDFILE)}; i=0; while :; do i=$((i+1)); echo rj-tick-$i; sleep 1; done'\n")
        down = split(right["pane_id"], "down")
        if down.get("terminal_id"):
            write(down["terminal_id"], "top -s 1\n")
            TOP["terminal"] = down["terminal_id"]
    # The pane a person left focused: the counter's, neither the first pane nor the split made
    # last (a restore that falls back to either must fail focus.pane).
    if right.get("pane_id"):
        cli("pane", right["pane_id"], "focus")
        # The counter's terminal zoomed in, as a person's Cmd-+ (two steps): its tab record keeps
        # the font scale, and the reopened view must draw at it (`debug.surfaces` font_scale).
        for _ in range(FONT_STEPS * bool(right.get("tab_id"))):
            # The font size actions take the terminal's tab, not its pane.
            action("terminal.increaseFontSize", target=f"tab:{right['tab_id']}")


def seed_split():
    ws = new_workspace("rj-split")
    if not ws.get("terminal_id"):
        return
    write(ws["terminal_id"], "echo rj-split-a\n")
    # Uneven ratios (a restore that evens splits out must fail the layout and geometry rows),
    # each one inside what the 1100-point window can draw (a pane is at least ~200 points wide).
    b = split(ws["pane_id"], "right", 0.55)
    c = b.get("pane_id") and split(b["pane_id"], "down", 0.7)
    d = c and c.get("pane_id") and split(c["pane_id"], "right", 0.45)
    for made, label in ((b, "b"), (c, "c"), (d, "d")):
        if made and made.get("terminal_id"):
            write(made["terminal_id"], f"echo rj-split-{label}\n")
    # A second tab in pane A, then A's first tab selected again.
    e = value(cli("tab", "create", "terminal", "--workspace", ws["workspace_id"], "--pane", ws["pane_id"]))
    if e.get("terminal_id"):
        write(e["terminal_id"], "echo rj-split-e\n")
    # A tab a person renamed, and one they pinned.
    if e.get("tab_id"):
        cli("tab", e["tab_id"], "rename", "--name", "rj-renamed")
    if b and b.get("tab_id"):
        cli("tab", b["tab_id"], "pin")
    cli("tab", ws["tab_id"], "focus")


def seed_web(base):
    ws = new_workspace("rj-web")
    if not ws.get("workspace_id"):
        return
    cli("workspace", ws["workspace_id"], "focus")
    # Each page in its own pane and selected there, so both load now and after the relaunch.
    first = f"{base}/hist-a"
    if opts.hist_file:
        folder = os.path.join(opts.out, "pages")
        os.makedirs(folder, exist_ok=True)
        for name in ("hist-a", "hist-b", "hist-c"):
            with open(os.path.join(folder, f"{name}.html"), "w") as f:
                f.write(page_html(name, base))
        first = "file://" + os.path.join(folder, "hist-a.html")
    hist = value(cli("tab", "create", "browser", "--url", first, "--workspace", ws["workspace_id"], "--pane", ws["pane_id"]))
    if hist.get("tab_id"):
        cli("tab", hist["tab_id"], "focus")
        HIST["tab"] = hist["tab_id"]
    # A person's history: the first page loaded from the address, then two link clicks (a -> b -> c).
    for here, there in (("/hist-a", "/hist-b"), ("/hist-b", "/hist-c")):
        if not wait(lambda: (REPORTS.get("hist") or {}).get("path") == here, 40):
            say(f"  the history page never reported from {here}")
            break
        clicked = person_click(ws, here, there)
        say(f"  click the link on {here} -> {clicked}")
    if not wait(lambda: (REPORTS.get("hist") or {}).get("path") == "/hist-c", 40):
        say("  the history page never reported from /hist-c")
    right = split(ws["pane_id"], "right")
    tall = value(cli("tab", "create", "browser", "--url", f"{base}/tall", "--workspace", ws["workspace_id"], "--pane", right.get("pane_id") or ws["pane_id"]))
    if tall.get("tab_id"):
        cli("tab", tall["tab_id"], "focus")
    if not wait(lambda: (REPORTS.get("tall") or {}).get("scrollY", 0) >= SCROLL - 5, 40):
        say("  the tall page never reported its scroll")


def person_click(ws, here, there):
    """Clicks the history page's link with a posted mouse click (a person's click: the entry it
    adds has user activation, which Chromium's Back needs, as it skips entries a page added
    without one). Window-level first, then Chromium's page view; a script click only if neither
    navigates. Returns how it clicked."""
    wait(lambda: (lambda r: isinstance(r, dict) and r.get("value") is True)(
        rpc("browser.page.eval", {"tab": HIST.get("tab"), "script": "document.readyState === 'complete'"})), 20, 0.5)
    topo = topology() or {}
    pane = next((p.get("id") for s_ in (workspace_named("rj-web", topo) or {}).get("screens", []) for p in s_.get("panes", [])
                 if any(t.get("id") == HIST.get("tab") for t in p.get("tabs", []))), None)
    # debug.mouse names a window by its controller id: the window's `key` in the topology.
    window = next((w.get("key") for w in topo.get("windows", []) if ws["workspace_id"] in w.get("workspaces", [])), None)
    reached = lambda: (REPORTS.get("hist") or {}).get("path") == there
    for how, params in (("mouse", {"pane": pane}), ("mouse on the page view", {"pane": pane, "target": "page"})):
        answer = rpc("debug.mouse", {**params, **({"window": window} if window else {})})
        say(f"  debug.mouse {how} -> {json.dumps(answer)[:200]}")
        if wait(reached, 5, 0.25):
            HIST.setdefault("clicks", []).append(how)
            return f"{how}: {json.dumps(answer)[:100]}"
    answer = wait(lambda: (lambda r: r if isinstance(r, dict) and r.get("value") is True else None)(
        rpc("browser.page.eval", {"tab": HIST.get("tab"), "script": CLICK_NEXT})), 20, 0.5)
    HIST.setdefault("clicks", []).append("script")
    return f"script: {json.dumps(answer)[:100]}"


AGENT = None
TOP = {}  # the terminal running `top`: {"terminal": its id}
W2 = {}  # the w2 page's zoom seed: {"steps": Cmd-+ steps that zoomed it in, from 100%}
HIST = {}  # the history tab: {"tab": its id}
SEEDED = {}  # values from the first before-snapshot that later variants must keep
# Clicks the page's link once it has loaded (a click before load can replace the entry instead of adding one).
CLICK_NEXT = "document.readyState === 'complete' ? (document.getElementById('next').click(), true) : false"


def seed_agent():
    global AGENT
    ws = new_workspace("rj-agent")
    if not ws.get("workspace_id"):
        return
    cli("workspace", ws["workspace_id"], "focus")
    action("palette.newAgentChat", focus=True)
    client = acpmux_client()
    if not client:
        say("  no acpmux home for this tag; the agent chat is not seeded")
        return
    home = ACPMUX["home"]
    created = client.request("session/new", {"cwd": opts.out, "mcpServers": [], "_meta": {"acpmux": {"harness": "fake"}}})
    sid = (created.get("result") or {}).get("sessionId")
    say(f"  fake chat {sid}: {json.dumps(created)[:160]}")
    if not sid:
        return
    for i, text in enumerate(["rj hello one", "rj hello two", "rj hello three"]):
        client.request("session/prompt", {"sessionId": sid, "prompt": [{"type": "text", "text": f"{text} {RUN}"}],
                                          "_meta": {"acpmux": {"promptId": f"rj-{RUN}-{i}"}}}, timeout=60)
    client.request("_acpmux/draft_set", {"sessionId": sid, "text": f"rj unsent draft {RUN}"})
    pane = next((p.get("id") for s_ in (workspace_named("rj-agent") or {}).get("screens", []) for p in s_.get("panes", [])
                 if any(t.get("kind") == "conversation" for t in p.get("tabs", []))), None)
    for attempt in range(4):
        # The pane, then the focused agent pane (the new chat tab may not be the shown one yet).
        target = pane if attempt % 2 == 0 else None
        params = {"action": "select_session", "session": sid, **({"pane": target} if target else {})}
        say(f"  select_session -> {json.dumps(rpc('debug.agent_pane', params, timeout=60))[:160]}")
        if wait(lambda: any(t.get("agent_session") == sid for t in tabs_of(workspace_named("rj-agent"))), 30, 1):
            break
    else:
        say("  the chat tab's record never named the session (the page has it selected)")
        # Evidence for the gap: the app's own log about the bind and the page's session report.
        log = subprocess.run(["log", "show", "--last", "4m", "--style", "compact", "--predicate",
                              f"processID == {APP.pid} AND (eventMessage CONTAINS[c] 'conversation-tab' "
                              "OR eventMessage CONTAINS[c] 'session' OR eventMessage CONTAINS[c] 'bind' "
                              "OR eventMessage CONTAINS[c] 'refused' OR eventMessage CONTAINS[c] 'agent pane')"],
                             capture_output=True, text=True, timeout=120).stdout
        with open(os.path.join(opts.out, "agent-bind-log.txt"), "w") as f:
            f.write(log)
        state = rpc("debug.agent_pane", {"action": "chat_state", **({"pane": pane} if pane else {})}, timeout=30)
        dump("agent-bind-chat-state.json", state)
        say(f"  bind log: {len(log.splitlines())} lines in agent-bind-log.txt")
    AGENT = {"session": sid, "home": home, "pane": pane}


# ---- the agents part: several Claude and Codex sessions of each kind --------------------------
#
# Leo's continuity bar (classic cmux's): after a quit, crash or reboot every agent session is back
# in its workspace and tab, with its transcript, harness, model and draft, and is live (it
# answers a new turn; it is not "Not logged in"). Two kinds, AGENTS_N of each per harness:
#   rj-chats    agent chats (acpmux), as a Claude Code harness (`rj-claude`: Claude's model
#               picker; a non-default model is picked) and a Codex harness (`rj-codex`; a
#               non-default effort is picked), two turns and an unsent draft each;
#   rj-tagents  terminal tabs running the `claude` and `codex` CLIs (rj_fake_cli_agent.py: its
#               account is CLAUDE_CONFIG_DIR / CODEX_HOME, given inline on its command line as
#               a person's alias does, with launch flags; it reports SessionStart through the
#               terminal's hook helper as the real hooks do), one turn each.

CHAT_PROFILES = {
    "rj-claude": {"family": "claude", "env": {"FAKE_PICKER": "1", "FAKE_PICKER_MODES": "claude"}},
    "rj-codex": {"family": "codex", "env": {"FAKE_PICKER": "1"}},
}
CHAT_PICKS = {"rj-claude": {"model": "claude-sonnet-5-5"}, "rj-codex": {}}  # the test agent keeps picks only as Claude
CLI_AGENTS = {
    # After a reboot a respawned terminal resumes its agent with its flags and account ("Resume
    # Agents After Restart" is on by default). Claude's runs with its approvals off, so its resume
    # is typed on the new prompt without Return (#22292: a respawn never starts an agent with its
    # approvals off by itself); the journey checks it waits there, then presses Return as a
    # person does. Codex's resume runs by itself.
    "claude": {"account": "CLAUDE_CONFIG_DIR", "flags": "--dangerously-skip-permissions --model claude-sonnet-5-5",
               "resume_waits": True},
    "codex": {"account": "CODEX_HOME", "flags": "-m gpt-5.5 --search"},
}
CHATS = []  # {"label", "harness", "session", "tab"}
TAGENTS = []  # {"label", "provider", "terminal", "tab", "session", "flags", "account"}
ACPMUX = {}  # {"home", "client"}: the tag's acpmux, configured once for the run


def acpmux_client():
    """The tag's acpmux with the run's harnesses configured (once per run); None when it has none."""
    if not ACPMUX:
        home = wait(acpmux_home, 60)
        if not home:
            return None
        ACPMUX.update(home=home, client=configure_fake(home))
    elif "client" not in ACPMUX:
        # After a reboot: the relaunched app starts acpmux again with the run's config still in
        # place. Its old socket file may still be there: retry the connect itself.
        def connect():
            try:
                return Acpmux(acpmux_socket_of(ACPMUX["home"]))
            except OSError:
                return None
        client = wait(connect, 60, 0.5)
        if not client:
            say("  acpmux did not answer within 60 s after the reboot")
            return None
        ACPMUX["client"] = client
    return ACPMUX["client"]


def page(pane, act, **params):
    return rpc("debug.agent_pane", {"action": act, **({"pane": pane} if pane else {}), **params}, timeout=60)


def place_of(tab_id, topo=None):
    """`ws[name].s0.paneP.tabT` of a tab, or None."""
    for ws in rj_workspaces(topo or topology()):
        for s_index, screen in enumerate(ws.get("screens", [])):
            for p_index, pane in enumerate(screen.get("panes", [])):
                for t_index, tab in enumerate(pane.get("tabs", [])):
                    if tab.get("id") == tab_id:
                        return f"ws[{ws.get('name')}].s{s_index}.pane{p_index}.tab{t_index}", pane.get("id")
    return None, None


def seed_chats():
    ws = new_workspace("rj-chats")
    if not ws.get("workspace_id"):
        return
    cli("workspace", ws["workspace_id"], "focus")
    client = acpmux_client()
    if not client:
        say("  no acpmux home for this tag; the chats are not seeded")
        return
    for harness in CHAT_PROFILES:
        for i in range(AGENTS_N):
            label = f"{harness}-{i}"
            known = {t.get("id") for t in tabs_of(workspace_named("rj-chats"))}
            action("palette.newAgentChat", focus=True)
            fresh = wait(lambda: next((t for t in tabs_of(workspace_named("rj-chats"))
                                       if t.get("kind") == "conversation" and t.get("id") not in known), None), 30, 0.5)
            if not fresh:
                say(f"  {label}: no new chat tab")
                continue
            created = client.request("session/new", {"cwd": opts.out, "mcpServers": [], "_meta": {"acpmux": {"harness": harness}}})
            sid = (created.get("result") or {}).get("sessionId")
            if not sid:
                say(f"  {label}: session/new -> {json.dumps(created)[:200]}")
                continue
            _, pane = place_of(fresh["id"])
            # The page learns of a new acpmux session a moment after it is made: select it until the
            # tab's record names it.
            for attempt in range(4):
                # The new tab may not be the pane's shown tab yet; then the focused agent pane.
                target = pane if attempt % 2 == 0 else None
                say(f"  {label}: select_session -> {json.dumps(page(target, 'select_session', session=sid))[:160]}")
                if wait(lambda: any(t.get("agent_session") == sid for t in tabs_of(workspace_named("rj-chats"))), 15, 1):
                    break
            else:
                say(f"  {label}: the tab never recorded session {sid}")
            pick = CHAT_PICKS[harness]
            if pick:
                # The pick a person makes in the composer's menus; through acpmux when the page refuses.
                for target in (pane, None):
                    picked = page(target, "set_model", **pick)
                    say(f"  {label}: set_model {pick} -> {json.dumps(picked)[:200]}")
                    if isinstance(picked, dict) and "error" not in picked:
                        break
                if not isinstance(picked, dict) or "error" in picked:
                    if pick.get("model"):
                        client.request("session/set_model", {"sessionId": sid, "modelId": pick["model"]})
                    if pick.get("effort"):
                        client.request("session/set_config_option", {"sessionId": sid, "configId": "effort", "value": pick["effort"]})
            for turn in range(2):
                client.request("session/prompt", {"sessionId": sid, "prompt": [{"type": "text", "text": f"rj chat turn {turn} {label} {RUN}"}],
                                                  "_meta": {"acpmux": {"promptId": f"rj-{RUN}-{label}-{turn}"}}}, timeout=60)
            client.request("_acpmux/draft_set", {"sessionId": sid, "text": f"rj draft {label} {RUN}"})
            CHATS.append({"label": label, "harness": harness, "session": sid, "tab": fresh["id"]})


def screen_text(term):
    """The terminal's scrollback and screen as one string with the line breaks taken out."""
    rows = history(term) or []
    screen = cli("terminal", term, "screen", "read", quiet=True)
    return ("".join(rows) + (screen.get("text", "") if isinstance(screen, dict) else "")).replace("\n", "")


def agent_events(session=None):
    """The terminal agents' own log (rj_fake_cli_agent.py, RJ_AGENT_LOG): every start and answer."""
    events = []
    try:
        with open(os.path.join(opts.out, "rj-agents.jsonl")) as f:
            for line in f:
                try:
                    events.append(json.loads(line))
                except ValueError:
                    continue  # a line an agent is still writing
    except OSError:
        return []
    return [e for e in events if session is None or e.get("session") == session]


def daemon_binary():
    """The app's cmux-tui (its daemon's executable), for the agents' hook fallback."""
    out = subprocess.run(["ps", "axo", "args="], capture_output=True, text=True).stdout
    for line in out.splitlines():
        if line.startswith(APP.bundle + "/") and "--headless" in line:
            return line.split(" --", 1)[0]
    return None


def seed_tagents():
    ws = new_workspace("rj-tagents")
    if not ws.get("terminal_id"):
        return
    here = os.path.dirname(os.path.abspath(__file__))
    bindir = os.path.join(opts.out, "rj-bin")
    os.makedirs(bindir, exist_ok=True)
    tui = daemon_binary() or ""
    for provider in CLI_AGENTS:
        # On PATH as `claude` / `codex`. The wrapper names the log and the app's cmux-tui itself, so
        # a resume run by the app after a reboot (with no variables of ours) still reports.
        exe = os.path.join(bindir, provider)
        with open(exe, "w") as f:
            f.write("#!/bin/sh\n"
                    f"export RJ_AGENT_LOG={shlex.quote(os.path.join(opts.out, 'rj-agents.jsonl'))} RJ_CMUX_TUI={shlex.quote(tui)}\n"
                    f"exec python3 {shlex.quote(os.path.join(here, 'rj_fake_cli_agent.py'))} {provider} \"$@\"\n")
        os.chmod(exe, 0o755)
    # The CLIs on PATH as a person's shell profile puts them, so a new shell (after a reboot) finds
    # them too. Only a capture slot's own HOME (its lease folder, removed at release).
    home = APP.env.get("HOME", "")
    if "/cmux-capture/slots/" in home:
        # .zshrc: interactive shells only (a terminal's), not the app's own login-shell probes.
        with open(os.path.join(home, ".zshrc"), "a") as f:
            f.write(f"\nexport PATH={shlex.quote(bindir)}:$PATH  # restore-journey\n")
    else:
        say("  not a capture slot HOME: a new shell will not find the test CLIs (reboot rows will fail)")
    first = True
    for provider, spec in CLI_AGENTS.items():
        account = os.path.join(opts.out, f"rj-account-{provider}")
        os.makedirs(account, exist_ok=True)
        open(os.path.join(account, "rj-login"), "w").close()
        for i in range(AGENTS_N):
            label = f"{provider}-{i}"
            if first:
                made, first = ws, False
            else:
                made = value(cli("tab", "create", "terminal", "--workspace", ws["workspace_id"], "--pane", ws["pane_id"]))
            term = made.get("terminal_id")
            if not term:
                say(f"  {label}: no terminal")
                continue
            known = {e.get("pid") for e in agent_events()}
            write(term, f"export PATH={shlex.quote(bindir)}:$PATH; cd {shlex.quote(opts.out)}; "
                        f"{spec['account']}={shlex.quote(account)} {provider} {spec['flags']}\n")
            start = wait(lambda: next((e for e in agent_events() if e.get("event") == "start" and e.get("pid") not in known
                                       and e.get("provider") == provider), None), 20, 0.5)
            if not start:
                say(f"  {label}: the agent never started: {screen_text(term)[-300:]!r}")
                continue
            say(f"  {label}: started {json.dumps(start)[:240]}")
            write(term, f"rj tturn {label} {RUN}\n")
            wait(lambda: any(e.get("event") == "answer" and e.get("text") == f"rj tturn {label} {RUN}" for e in agent_events(start["session"])), 15, 0.5)
            TAGENTS.append({"label": label, "provider": provider, "terminal": term, "tab": made.get("tab_id"),
                            "session": start["session"], "flags": start.get("flags"), "hook": start.get("hook"), "pid": start.get("pid")})
    if ws.get("tab_id"):
        cli("tab", ws["tab_id"], "focus")


def chat_items(label, items, raw):
    """Rows for each seeded chat: where its tab is, what its acpmux record keeps, what its page
    shows, and a new turn it answers (live)."""
    topo = topology()
    client = acpmux_client()
    with visiting("rj-chats"):
        for chat in CHATS:
            c = f"chat[{chat['label']}]"
            tab = next((t for ws in rj_workspaces(topo) for t in tabs_of(ws) if t.get("agent_session") == chat["session"]), None)
            items[f"{c}.place"], pane = place_of(tab.get("id"), topo) if tab else (None, None)
            if client:
                events = ((client.request("_acpmux/events", {"sessionId": chat["session"], "afterSeq": 0, "limit": 5000}).get("result") or {}).get("events")) or []
                items[f"{c}.prompts"] = [e.get("msg", {}).get("text") for e in events if e.get("kind") == "user_message"
                                         and "rj chat turn" in str(e.get("msg", {}).get("text"))]
                items[f"{c}.draft"] = (client.request("_acpmux/draft_get", {"sessionId": chat["session"]}).get("result") or {}).get("draft")
            if not tab:
                continue
            cli("tab", tab["id"], "focus", quiet=True)
            state = wait(lambda: (lambda r: r if isinstance(r, dict) and "error" not in r and r.get("connection") != "connecting"
                                  and r.get("sessionId") == chat["session"] else None)(page(pane, "chat_state")), 45, 1) or page(pane, "chat_state")
            raw[f"{c}.chat_state"] = state
            if not isinstance(state, dict) or "error" in state:
                items[f"{c}.page"] = f"chat_state: {json.dumps(state)[:120]}"
                continue
            items[f"{c}.page.session"] = state.get("sessionId")
            items[f"{c}.page.harness"] = state.get("harness")
            items[f"{c}.page.missing_session"] = state.get("missingSession")
            chips = state.get("composer") or {}
            # The composer's chips as drawn show the model and effort picked.
            # (The model chip may draw only its icon, so the model is read from the page's own state.)
            pick = CHAT_PICKS.get(chat["harness"], {})
            shown = page(pane, "models")
            current = shown.get("current") if isinstance(shown, dict) else None
            ok = not pick.get("model") or current == pick["model"]
            items[f"{c}.page.picked"] = True if ok else f"chips {json.dumps(chips)[:100]}, model {current!r}; picked {json.dumps(pick)}"
            items[f"{c}.page.transcript"] = [r.get("text") for r in state.get("transcript") or [] if "rj chat turn" in str(r.get("text"))
                                              or str(r.get("text")).startswith("echo: rj chat turn")]
            # Live: a new turn is answered by the agent and shows on the page. Sent through acpmux, so
            # the composer's draft stays as seeded.
            text = f"rj live {chat['label']} {label} {RUN}"
            if client:
                client.request("session/prompt", {"sessionId": chat["session"], "prompt": [{"type": "text", "text": text}],
                                                  "_meta": {"acpmux": {"promptId": f"rj-{RUN}-{chat['label']}-{label}"}}}, timeout=60)
            answered = wait(lambda: (lambda r: isinstance(r, dict) and (r.get("lastAssistant") or {}).get("text") == f"echo: {text}"
                                     and not (r.get("lastAssistant") or {}).get("streaming"))(page(pane, "chat_state")), 30, 1)
            items[f"{c}.live"] = bool(answered) or f"no answer: {json.dumps((page(pane, 'chat_state') or {}).get('lastAssistant'))[:120]}"


def tagent_items(label, items, raw):
    """Rows for each seeded terminal agent: its tab's place, the agent process that runs its
    session now (its last start: same session, signed in, same flags), its transcript, and a new
    line it answers (live)."""
    topo = topology()
    for agent in TAGENTS:
        a = f"tagent[{agent['label']}]"
        items[f"{a}.place"] = place_of(agent["tab"], topo)[0]
        # A terminal brought back after its host died (reboot) may take a few seconds to resume.
        def current():
            starts = [e for e in agent_events(agent["session"]) if e.get("event") == "start"]
            return starts[-1] if starts and _pid_alive(starts[-1].get("pid")) else None
        if getattr(APP, "rebooted", False) and CLI_AGENTS[agent["provider"]].get("resume_waits"):
            # Its resume is typed on the new prompt and does not run by itself: the command with
            # its session on screen, no agent started for it. Then Return, as a person presses it.
            typed = wait(lambda: f"--resume {agent['session']}" in screen_text(agent["terminal"])[-600:], 30, 1)
            ran = current()
            ran = ran if ran and ran.get("pid") != agent.get("pid") else None
            items[f"{a}.resume_waits"] = (bool(typed) and not ran) or \
                (f"started by itself: {ran}" if ran else f"no resume typed; screen ends {screen_text(agent['terminal'])[-200:]!r}")
            if typed and not ran:
                write(agent["terminal"], "\r")
        start = wait(current, 60, 1)
        raw[f"{a}.start"] = start
        raw[f"{a}.text"] = screen_text(agent["terminal"])[-4000:]
        items[f"{a}.running"] = bool(start) or f"no live agent; screen ends {raw[f'{a}.text'][-200:]!r}"
        if start and getattr(APP, "rebooted", False):
            # After a reboot the agent that runs is a new one, resumed into its session (the
            # respawned terminal ran the resume command), not one that outlived the reboot.
            items[f"{a}.running"] = (start.get("resumed") is True and start.get("pid") != agent.get("pid")) \
                or f"the running agent was not resumed after the reboot: {start}"
        items[f"{a}.flags"] = start.get("flags") if start else None
        items[f"{a}.signed_in"] = bool(start) and start.get("signed_in") is True and not start.get("missing")
        # The seeded turn on screen (spaces out: a wrapped line loses the one at its break).
        items[f"{a}.transcript"] = f"echo: rj tturn {agent['label']} {RUN}".replace(" ", "") in raw[f"{a}.text"].replace(" ", "")
        ping = f"rj ping {agent['label']} {label} {RUN}"
        write(agent["terminal"], ping + "\n")
        items[f"{a}.live"] = bool(wait(lambda: any(e.get("event") == "answer" and e.get("text") == ping
                                                   for e in agent_events(agent["session"])), 20, 0.5)) \
            or f"no answer; screen ends {screen_text(agent['terminal'])[-200:]!r}"


def _pid_alive(pid):
    try:
        os.kill(int(pid), 0)
        return True
    except (TypeError, ValueError, ProcessLookupError):
        return False
    except PermissionError:
        return True


def seed_w2(base):
    ws = new_workspace("rj-w2")
    if not ws.get("workspace_id"):
        return
    write(ws["terminal_id"], f"echo rj-w2-marker-{RUN}\n")
    page = value(cli("tab", "create", "browser", "--url", f"{base}/w2page", "--workspace", ws["workspace_id"], "--pane", ws["pane_id"]))
    # The page zoomed in, as a person's Cmd-+ (`browserZoomIn`, three steps), while it is shown
    # in the key window (the action needs the key window's focused pane to show a page).
    if page.get("tab_id"):
        cli("workspace", ws["workspace_id"], "focus")
        cli("tab", page["tab_id"], "focus")
        if wait(lambda: (REPORTS.get("w2page") or {}).get("width"), 30):
            zoom = lambda perform: say(f"  {perform} -> {json.dumps(rpc('debug.toast', {'perform': perform, 'target_kind': 'pane', 'target_id': page.get('pane_id')}))[:120]}")
            # The level is per host and kept on disk (SiteZoomLevels), so an earlier run on this
            # slot leaves it zoomed, up to the 500% cap where Cmd-+ does nothing: reset it first.
            width = REPORTS["w2page"]["width"]
            zoom("browserZoomReset")
            wait(lambda: (REPORTS.get("w2page") or {}).get("width", 0) > width, 5)
            W2["steps"] = 0
            for _ in range(3):
                width = REPORTS["w2page"]["width"]
                zoom("browserZoomIn")
                if wait(lambda: 0 < (REPORTS.get("w2page") or {}).get("width", 0) < width, 10):
                    W2["steps"] += 1
    action("moveWorkspaceToNewWindow", target=f"workspace:{ws['workspace_id']}")
    window = wait(lambda: next((w for w in (topology() or {}).get("windows", []) if w.get("workspace") == ws["workspace_id"]), None), 20)
    if window:
        rpc("debug.window_frame", {"window": window.get("key"), "frame": FRAMES[1]})


def seed_w3():
    """A third window on its own space, as a person makes one: a new space, then Open Space in New
    Window, which opens a window on the space with a new workspace there (rj-w3). (Its sidebar stays:
    `toggleSidebar` acts on the key window, and a no-activate slot has none; MultiWindowRestoreTests
    covers a hidden sidebar.)"""
    answer = cli("room", "create", "--name", f"rj-room-{RUN}")
    room = answer.get("value", answer) if isinstance(answer, dict) else {}
    room_id = room.get("id") or room.get("room_id") or (room.get("room") or {}).get("id")
    if not room_id:
        say(f"  w3: no room: {json.dumps(answer)[:160]}")
        return
    # The app learns of the room through the daemon's personal-changed event: wait for the action to accept it.
    wait(lambda: not (action("space.openInNewWindow", args={"space": room_id}) or {}).get("error"), 15, 1)
    def space_window():
        report = rpc("debug.windows")
        for entry in (report or {}).get("windows", []) if isinstance(report, dict) else []:
            if entry.get("profile") == room_id and entry.get("open") is not False:
                return entry
        return None
    entry = wait(space_window, 20)
    topo = topology() or {}
    window = entry and next((w for w in topo.get("windows", []) if w.get("key") == entry.get("id") and w.get("workspace")), None)
    if not window:
        say(f"  w3: no window on the space: {json.dumps(rpc('debug.windows'))[:300]}")
        return
    ws_id = window["workspace"]
    cli("workspace", ws_id, "rename", "rj-w3")
    workspace = next((w for w in topo.get("workspaces", []) if w.get("id") == ws_id), {})
    term = next((t.get("terminal") for s_ in workspace.get("screens", []) for p in s_.get("panes", []) for t in p.get("tabs", [])
                 if t.get("kind") == "terminal" and t.get("terminal")), None)
    if term:
        write(term, f"echo rj-w3-marker-{RUN}\n")
    rpc("debug.window_frame", {"window": window.get("key"), "frame": FRAMES[2]})
    say(f"  w3: window {window.get('key')} workspace {ws_id} terminal {term}")


# Window frames (AppKit points, bottom-left origin), inside a 1080p screen's visible frame (above
# the Dock), so a restore that keeps a window on screen has no reason to move them.
FRAMES = [[80, 220, 1100, 700], [260, 280, 820, 560], [520, 120, 760, 520]]


def seed_cloud():
    """Move to Cloud's kept state, recorded through the app's own stores (`debug.cloud.move_seed`)."""
    answer = rpc("debug.cloud.move_seed", {"run": RUN})
    say(f"  cloud seed -> {json.dumps(answer)[:200]}")
    if not isinstance(answer, dict) or "error" in answer:
        raise RuntimeError(f"debug.cloud.move_seed: {answer}")


def cloud_items():
    """The seeded Move to Cloud records as the app reads them now: ids, kinds and digests."""
    state = rpc("debug.cloud.move_state")
    if not isinstance(state, dict) or "error" in state:
        return {"cloud.state": state}
    mine = lambda value: str(value or "").startswith(f"rj-{RUN}-")
    return {
        "cloud.moved_chats": [c for c in state.get("moved_chats", []) if mine(c.get("machine_id"))],
        "cloud.move_retries": [r for r in state.get("move_retries", []) if mine(r.get("tab"))],
        "cloud.bring_back_retries": [r for r in state.get("bring_back_retries", []) if mine(r.get("tab"))],
        # Grants are named by their folder's digest only; a slot starts with none of its own.
        "cloud.grants": state.get("grants", []),
        "cloud.dismissed": [d for d in state.get("dismissed", []) if mine(d.get("tab"))],
    }


def cleanup_earlier():
    """Closes rj-* workspaces an earlier run left (slot state persists per tag), ending their terminals."""
    for ws in rj_workspaces(topology()):
        cli("workspace", ws["id"], "close")
    wait(lambda: not rj_workspaces(topology()), 20)
    rooms = cli("room", "list", quiet=True)
    for room in (rooms.get("value", rooms) if isinstance(rooms, dict) else rooms) or []:
        if isinstance(room, dict) and str(room.get("name", "")).startswith("rj-room-"):
            cli("room", room.get("id"), "delete")


def seed(base):
    say("seeding")
    cleanup_earlier()
    for part, run in (("term", seed_term), ("split", seed_split), ("web", lambda: seed_web(base)),
                      ("agent", seed_agent), ("w2", lambda: seed_w2(base)), ("w3", seed_w3), ("cloud", seed_cloud),
                      ("agents", seed_chats), ("agents", seed_tagents)):
        if part not in SKIP:
            try:
                run()
            except Exception as error:  # one part failing still leaves the others to check
                say(f"  seed {part} failed: {error!r}")
    term = workspace_named("rj-term")
    first = term and next((w for w in (topology() or {}).get("windows", []) if term["id"] in w.get("workspaces", [])), None)
    if term:
        cli("workspace", term["id"], "focus")
    if first:
        rpc("debug.window_frame", {"window": first.get("key"), "frame": FRAMES[0]})
        # The window a person used last: key and first in the app's window recency.
        say(f"  window.focus -> {json.dumps(rpc('debug.window.focus', {'window': first.get('key')}))[:160]}")
        # Its sidebar dragged to a width neither default uses (the active window's).
        say(f"  sidebar width -> {json.dumps(rpc('debug.update_surfaces', {'action': 'sidebar-width', 'width': SIDEBAR_WIDTH}))[:160]}")
    # The scrollback writer is done and the counter has ticked a few times.
    wait(lambda: "rj-scrollback-done" in json.dumps(rpc("debug.surfaces", {"text": True})), 40, 1)
    if "term" not in SKIP:
        wait(lambda: view_tick() >= 3, 20, 0.5)


# ---- the canonical snapshot ------------------------------------------------------------------

def sha(text):
    return hashlib.sha256(text.encode()).hexdigest()[:16]


def history(term):
    """Every scrollback row of `term` (oldest first), paged back from the newest."""
    rows, before = [], None
    for _ in range(100):
        args = ["terminal", term, "history", "read", "--limit", "1000"] + (["--before", str(before)] if before is not None else [])
        page = cli(*args, quiet=True)
        if not isinstance(page, dict) or "rows" not in page:
            return None
        chunk = ["".join(run.get("text", "") for run in row.get("runs", [])).rstrip() for row in page["rows"]]
        rows = chunk + rows
        start = int(page.get("start") or 0)
        if not chunk or start <= 0:
            break
        before = start
    return rows


HISTORY_BY_SHA = {}  # history_sha -> the rows it hashes, for the history_sha row's compare


def terminal_items(term):
    rows = history(term)
    screen = cli("terminal", term, "screen", "read", quiet=True)
    text = "\n".join(rows or []) + "\n" + (screen.get("text", "") if isinstance(screen, dict) else "")
    numbered = [int(n) for n in re.findall(rf"rj-line-(\d+)-{RUN}", text)]
    HISTORY_BY_SHA[sha("\n".join(rows or []))] = rows or []
    return {"history_rows": len(rows) if rows is not None else None, "history_sha": sha("\n".join(rows or [])),
            "numbered_lines": len(set(numbered)), "numbered_max": max(numbered) if numbered else 0,
            "ticks": [int(t) for t in re.findall(r"rj-tick-(\d+)", text)]}


def pane_active_tab(pane_id):
    """The tab pane `pane_id` shows, from its screen's layout export (`active_tab_id` of its leaf), or None."""
    topo = topology() or {}
    screen = next((s_.get("id") for ws in rj_workspaces(topo) for s_ in ws.get("screens", [])
                   if any(p.get("id") == pane_id for p in s_.get("panes", []))), None)
    if not screen:
        return None
    exported = cli("screen", screen, "layout", "export", quiet=True)
    found = []
    def walk(node):
        if isinstance(node, dict):
            if node.get("pane_id") == pane_id and node.get("active_tab_id"):
                found.append(node["active_tab_id"])
            for item in node.values():
                walk(item)
        elif isinstance(node, list):
            for item in node:
                walk(item)
    walk(exported.get("value", exported) if isinstance(exported, dict) else exported)
    return found[0] if found else None


def layout_shape(screen_id, pane_index):
    """The screen's split tree from the daemon, with pane ids replaced by their index and ratios rounded."""
    exported = cli("screen", screen_id, "layout", "export", quiet=True)
    tree = exported.get("value", exported) if isinstance(exported, dict) else exported

    def walk(node):
        if isinstance(node, dict):
            out = {}
            for key, item in node.items():
                if key in ("id", "pane_id", "pane", "split_id") and isinstance(item, str) and item in pane_index:
                    out[key] = f"pane#{pane_index[item]}"
                elif key in ("id", "split_id", "tab_id", "terminal_id", "browser_id", "revision", "generation") and isinstance(item, str):
                    continue
                elif isinstance(item, float):
                    out[key] = round(item, 2)
                else:
                    out[key] = walk(item)
            return out
        if isinstance(node, list):
            return [walk(item) for item in node]
        return node

    return walk(tree)


def view_tick():
    """The counter's newest tick that a terminal view shows (0 when none)."""
    _, views = view_panes()
    ticks = [int(t) for t in re.findall(r"rj-tick-(\d+)", "\n".join(v.get("text") or "" for v in views.values()))]
    return max(ticks) if ticks else 0


def view_panes():
    report = rpc("debug.surfaces", {"text": True}, timeout=60)
    panes = {}
    for window in report.get("windows", []) if isinstance(report, dict) else []:
        for pane in window.get("panes", []):
            panes[pane.get("pane")] = pane
    return report, panes


PAGE_WORKSPACE = {"hist": "rj-web", "tall": "rj-web", "w2page": "rj-w2"}


class visiting:
    """Shows workspace `name` for a read, then the workspace that was focused before again (so
    the focus rows and the next variant see what the person left)."""

    def __init__(self, name):
        self.name, self.back, self.prior = name, None, None

    def __enter__(self):
        topo = topology() or {}
        self.back = (topo.get("focus") or {}).get("workspace")
        target = workspace_named(self.name, topo) if self.name else None
        if target and target.get("id") != self.back:
            # The workspace the visited window showed, when that is not the focused window: put
            # back too, or the snapshot leaves that window on another workspace than it recorded.
            window = next((w for w in topo.get("windows", []) if target["id"] in w.get("workspaces", [])), None)
            shown = window and window.get("workspace")
            self.prior = shown if shown not in (None, target["id"], self.back) else None
            cli("workspace", target["id"], "focus", quiet=True)
        else:
            self.back = None
        return self

    def __exit__(self, *_):
        if self.prior:
            cli("workspace", self.prior, "focus", quiet=True)
        if self.back:
            cli("workspace", self.back, "focus", quiet=True)
            wait(lambda: ((topology() or {}).get("focus") or {}).get("workspace") == self.back, 10, 0.3)


grid_fits_view = rj_rows.grid_fits_view


def snapshot(label):
    """Raw dumps plus the canonical items: {item: value}."""
    say(f"snapshot {label}")
    topo = topology() or {}
    surfaces, views = view_panes()
    raw = {"topology": topo, "debug.windows": rpc("debug.windows"), "debug.screens": rpc("debug.screens"),
           "debug.surfaces": surfaces, "reports": dict(REPORTS), "debug.timings": rpc("debug.timings")}
    with LOCK:
        raw["page_loads"] = list(PAGE_LOADS)
    items = {}
    ws_by_id = {w.get("id"): w for w in topo.get("workspaces", [])}
    rj = lambda name: (name or "").startswith("rj-")
    # Windows that hold rj-* workspaces, in topology order.
    rj_windows = [w for w in topo.get("windows", []) if any(rj(ws_by_id.get(i, {}).get("name")) for i in w.get("workspaces", []))]
    items["windows.count"] = len(rj_windows)
    # A window is named by its rj-* workspaces (window ids are compared separately).
    names = {w.get("key"): "+".join(sorted(n for n in (ws_by_id.get(i, {}).get("name") for i in w.get("workspaces", [])) if rj(n)))
             for w in rj_windows}
    recency = (raw["debug.windows"] or {}).get("recency") if isinstance(raw["debug.windows"], dict) else None
    items["windows.recency"] = [names[key] for key in recency or [] if key in names]
    # What each window's record saves, as the window shows it (debug.windows, keyed by window id).
    app_windows = {w.get("id"): w for w in ((raw["debug.windows"] or {}).get("windows") or [])} if isinstance(raw["debug.windows"], dict) else {}
    displays = (raw["debug.windows"] or {}).get("displays") if isinstance(raw["debug.windows"], dict) else None
    for index, window in enumerate(rj_windows):
        p = f"window[{names[window.get('key')]}]"
        items[f"{p}.id"] = window.get("id")
        items[f"{p}.workspaces"] = [n for n in (ws_by_id.get(i, {}).get("name") for i in window.get("workspaces", [])) if rj(n)]
        items[f"{p}.selected_workspace"] = ws_by_id.get(window.get("workspace"), {}).get("name")
        # With no `frame`, debug.window_frame sets the window's own frame again and returns it.
        framed = rpc("debug.window_frame", {"window": window.get("key")})
        items[f"{p}.frame"] = framed.get("frame") if isinstance(framed, dict) else None
        shown = app_windows.get(window.get("key")) or {}
        items[f"{p}.full_screen"] = shown.get("full_screen")
        items[f"{p}.sidebar_width"] = shown.get("sidebar_width")
        items[f"{p}.sidebar_hidden"] = shown.get("sidebar_hidden")
        items[f"{p}.space"] = shown.get("profile")
        # Which display a window comes back on means something only with two to pick from; a
        # capture slot has one 1080p display, so there the row reads n/a.
        if isinstance(displays, int) and displays >= 2:
            items[f"{p}.display"] = shown.get("display")
        raw[f"{p}.snapshot"] = rpc("debug.window_snapshot", {"window": window.get("key"), "path": os.path.join(opts.out, f"{label}-window{index}.png")}, timeout=60)
    if not isinstance(displays, int):
        RESULTS.append((f"{label}: debug.windows reports a displays count", False, f"displays is {displays!r}", "windows"))
    elif displays < 2:
        RESULTS.append((f"{label}: window[*].display", NA, f"n/a: {displays} display(s), the row needs two", "windows"))
    focus = topo.get("focus", {})
    items["focus.workspace"] = ws_by_id.get(focus.get("workspace"), {}).get("name")
    items["focus.window"] = next((names.get(w.get("key")) for w in rj_windows if w.get("id") == focus.get("window")), focus.get("window"))
    # The most recent window is the focused one (cx-ppw2w): a window opened
    # behind, never key, must not lead the recency the next launch restores.
    front = items["windows.recency"][0] if items["windows.recency"] else None
    RESULTS.append((f"{label}: windows.recency front is focus.window", front == items["focus.window"],
                    f"recency front {json.dumps(front)}, focus {json.dumps(items['focus.window'])}", "windows"))
    terms = {}
    pane_names = {}  # pane id -> its row prefix
    pane_ids = {}  # workspace name -> [(row prefix, pane id)]
    for ws in topo.get("workspaces", []):
        name = ws.get("name")
        if not rj(name):
            continue
        p = f"ws[{name}]"
        items[f"{p}.title"] = ws.get("title")
        items[f"{p}.screens"] = len(ws.get("screens", []))
        for s_index, screen in enumerate(ws.get("screens", [])):
            panes = screen.get("panes", [])
            pane_index = {pane.get("id"): i for i, pane in enumerate(panes)}
            items[f"{p}.s{s_index}.layout"] = layout_shape(screen.get("id"), pane_index)
            items[f"{p}.s{s_index}.zoomed"] = screen.get("zoomed_pane")
            for p_index, pane in enumerate(panes):
                pp = f"{p}.s{s_index}.pane{p_index}"
                pane_names[pane.get("id")] = pp
                pane_ids.setdefault(name, []).append((pp, pane.get("id")))
                tabs = pane.get("tabs", [])
                items[f"{pp}.tabs"] = [t.get("kind") for t in tabs]  # titles load late; URLs are their own rows
                items[f"{pp}.selected_tab"] = next((i for i, t in enumerate(tabs) if t.get("id") == pane.get("selected_tab")), None)
                for t_index, tab in enumerate(tabs):
                    tp = f"{pp}.tab{t_index}"
                    kind = tab.get("kind")
                    items[f"{tp}.id"] = tab.get("id")
                    items[f"{tp}.name"] = tab.get("name")
                    items[f"{tp}.pinned"] = tab.get("pinned")
                    if kind == "terminal":
                        items[f"{tp}.terminal"] = tab.get("terminal")
                        items[f"{tp}.cwd"] = tab.get("cwd")
                        items[f"{tp}.dead"] = tab.get("dead")
                        terms[tp] = tab.get("terminal")
                    elif kind == "browser":
                        items[f"{tp}.url"] = tab.get("url")
                    elif kind == "conversation":
                        items[f"{tp}.agent_session"] = tab.get("agent_session")
                    if kind == "terminal" and tab.get("id") == pane.get("selected_tab") and pane.get("id") in views:
                        view = views[pane.get("id")]
                        items[f"{tp}.view.attach"] = view.get("attach")
                        items[f"{tp}.view.font_scale"] = view.get("font_scale")
    # The focused pane, by its place (rj-term's counter pane, focused by the seed).
    focused_pane = focus.get("pane") or focus.get("pane_id")
    items["focus.pane"] = pane_names.get(focused_pane, f"not an rj pane: {focused_pane}" if focused_pane else None)
    raw["focus"] = focus
    # Terminals: scrollback, the numbered lines, the counter.
    pid = None
    if os.path.exists(PIDFILE):
        pid = int(open(PIDFILE).read().strip() or 0)
    for tp, term in terms.items():
        info = terminal_items(term)
        raw[f"terminal {tp}"] = info
        raw[f"terminal {tp} rows"] = HISTORY_BY_SHA.get(info["history_sha"])
        if info["numbered_lines"]:
            items[f"{tp}.scrollback.numbered_lines"] = info["numbered_lines"]
            items[f"{tp}.scrollback.numbered_max"] = info["numbered_max"]
            items[f"{tp}.scrollback.history_rows"] = info["history_rows"]
            items[f"{tp}.scrollback.history_sha"] = info["history_sha"]
        if info["ticks"]:
            items["counter.tick_in_daemon"] = max(info["ticks"])
    if pid:
        try:
            os.kill(pid, 0)
            alive = True
        except OSError:
            alive = False
        items["counter.pid"] = pid
        items["counter.alive"] = alive
    view_text = "\n".join(v.get("text") or "" for v in views.values())
    ticks = [int(t) for t in re.findall(r"rj-tick-(\d+)", view_text)]
    items["counter.tick_in_view"] = max(ticks) if ticks else None
    items["view.scrollback_tail"] = [line.strip() for line in view_text.splitlines() if f"rj-line-" in line][-3:]
    # Browser pages: what each page reports about itself.
    # Only reports sent since the last quit count: an older one says nothing about the reopened page.
    # A page in a workspace nobody shows loads when it is shown, as for a person: visit it.
    stale = lambda: [p for p in REPORTS if REPORTS[p].get("at", 0) <= SINCE]
    for page in stale():
        with visiting(PAGE_WORKSPACE.get(page)):
            wait(lambda: page not in stale(), 30, 0.5)
            if page == "tall":  # its scroll comes back after it loads
                wait(lambda: REPORTS["tall"].get("scrollY", 0) >= SCROLL - 40, 8, 0.5)
    if "tall" in REPORTS and REPORTS["tall"].get("at", 0) > SINCE:
        wait(lambda: REPORTS["tall"].get("scrollY", 0) >= SCROLL - 40, 8, 0.5)
    fresh = {page: r for page, r in REPORTS.items() if r.get("at", 0) > SINCE}
    for page in ("hist", "tall", "w2page"):
        if page in fresh:
            items[f"page[{page}].path"] = fresh[page]["path"]
    if "w2page" in fresh:
        # The page's zoom: its pane's width in points over its CSS viewport width.
        w2_pane = next((p_.get("id") for ws in rj_workspaces(topo) if ws.get("name") == "rj-w2" for s_ in ws.get("screens", [])
                        for p_ in s_.get("panes", []) if any(t.get("kind") == "browser" for t in p_.get("tabs", []))), None)
        try:
            points = int(str((views.get(w2_pane) or {}).get("content_size")).split("x")[0])
            items["page[w2page].zoom"] = round(points / fresh["w2page"]["width"], 2) if fresh["w2page"].get("width") else None
        except ValueError:
            items["page[w2page].zoom"] = None
    if "hist" in fresh:
        # WebKit's own back list, as the page sees it (a person's link clicks: 3 entries).
        items["page[hist].history_length"] = fresh["hist"].get("history")
    if "tall" in fresh:
        items["page[tall].scrollY"] = fresh["tall"]["scrollY"]
        # Whether this page itself ran the seed's scroll (1 only on the seeded load): a reopened
        # page that ran it again (a cached copy of the seeded page) proves nothing about restore.
        items["page[tall].self_scrolled"] = fresh["tall"].get("self_scrolled")
    # The agent chat: its acpmux record, its tab, and what its page shows.
    if AGENT:
        sid = AGENT["session"]
        try:
            client = Acpmux(acpmux_socket_of(AGENT["home"]))
            page = client.request("_acpmux/events", {"sessionId": sid, "afterSeq": 0, "limit": 5000})
            events = ((page.get("result") or {}).get("events")) or []
            items["agent.prompts"] = [e.get("msg", {}).get("text") for e in events if e.get("kind") == "user_message"]
            items["agent.draft"] = (client.request("_acpmux/draft_get", {"sessionId": sid}).get("result") or {}).get("draft")
            items["agent.status"] = (client.request("_acpmux/info", {"sessionId": sid}).get("result") or {}).get("status")
        except OSError as error:
            items["agent.acpmux"] = f"unreachable: {error}"
        items["agent.tabs_bound"] = sum(1 for ws in rj_workspaces(topo) for t in tabs_of(ws) if t.get("agent_session") == sid)
        pane = next((p.get("id") for ws in rj_workspaces(topo) for s_ in ws.get("screens", []) for p in s_.get("panes", [])
                     if any(t.get("agent_session") == sid or t.get("kind") == "conversation" for t in p.get("tabs", []))), AGENT.get("pane"))
        # The chat's page shows only while its workspace is shown: visit it.
        with visiting("rj-agent"):
            # A page still connecting to acpmux has no session yet: wait for it to connect.
            # Each ask is short (5 s): one call that hangs must not count as the page's connect time.
            shown_at, asks = time.time(), []
            def connected():
                answer = rpc("debug.agent_pane", {"action": "chat_state", **({"pane": pane} if pane else {})}, timeout=5)
                asks.append([round(time.time() - shown_at, 1), (answer.get("error") or answer.get("connection")) if isinstance(answer, dict) else str(answer)])
                return answer if isinstance(answer, dict) and "error" not in answer and answer.get("connection") != "connecting" else None
            state = wait(connected, 90, 0.25)
            connect_seconds = round(time.time() - shown_at, 1)
            state = state or rpc("debug.agent_pane", {"action": "chat_state", **({"pane": pane} if pane else {})}, timeout=10)
        raw["agent_pane.chat_state"] = state
        raw["agent_pane.connect_seconds"] = connect_seconds
        raw["agent_pane.connect_asks"] = asks[-40:]
        say(f"  chat page {state.get('connection') if isinstance(state, dict) else state} {raw['agent_pane.connect_seconds']} s after it was shown")
        if label.endswith("-after"):
            # A person who opens the chat after a relaunch waits this long for it (before: 61 s, one
            # 60 s debug call that hung, not the page).
            RESULTS.append((f"{label[:-len('-after')]}: the chat page connects within {CHAT_CONNECT_BOUND} s after it is shown",
                            isinstance(state, dict) and "error" not in state and state.get("connection") not in (None, "connecting", "disconnected")
                            and connect_seconds <= CHAT_CONNECT_BOUND,
                            f"{state.get('connection') if isinstance(state, dict) else state} after {connect_seconds} s; asks {json.dumps(asks[:6])[:200]}",
                            "agent chat"))
        if isinstance(state, dict) and "error" not in state:
            items["agent.page.session"] = state.get("sessionId")
            items["agent.page.last_assistant"] = state.get("lastAssistant")
            items["agent.page.missing_session"] = state.get("missingSession")
        else:
            items["agent.page"] = f"chat_state: {json.dumps(state)[:120]}"
    # `top` (a full-screen program) keeps running and drawing: its screen changes in the daemon
    # and the view shows it.
    if TOP.get("terminal"):
        first = cli("terminal", TOP["terminal"], "screen", "read", quiet=True)
        time.sleep(2.5)
        second = cli("terminal", TOP["terminal"], "screen", "read", quiet=True)
        texts = [x.get("text", "") if isinstance(x, dict) else "" for x in (first, second)]
        items["top.running"] = all("Load Avg" in t for t in texts) and texts[0] != texts[1]
        top_pane = next((pid_ for ws in rj_workspaces(topo) for s_ in ws.get("screens", []) for pid_ in
                         [p_.get("id") for p_ in s_.get("panes", []) if any(t.get("terminal") == TOP["terminal"] for t in p_.get("tabs", []))]), None)
        with visiting("rj-term"):
            items["top.in_view"] = bool(wait(lambda: "Load Avg" in (view_panes()[1].get(top_pane) or {}).get("text", ""), 15, 0.5))
    # What the app draws: each terminal pane's size and grid in the window (the daemon's ratios
    # survive an app quit by themselves; this is the app laying them out again).
    for name in ("rj-term", "rj-split"):
        if not pane_ids.get(name):
            continue
        with visiting(name):
            # A workspace shown again claims the grids its views fit a few frames later (the resize
            # settle, then the daemon's echo): a window that got shorter while it was hidden leaves
            # the old grids for about 50 ms. Read once every terminal renders what its view fits
            # (`fit_grid`; a build without it: the same grids on two reads in a row).
            last = {}

            def drawn():
                report, now = view_panes()
                last["report"] = report
                shown = [now.get(pid_) for _, pid_ in pane_ids[name]]
                ok = all(v and v.get("presence") == "visible" and v.get("attach") == "live" and v.get("surface", {}).get("grid") for v in shown)
                if not ok:
                    return None
                surfaces = [v["surface"] for v in shown]
                grids = [s["grid"] for s in surfaces]
                if all("fit_grid" in s for s in surfaces):
                    settled = all(s["fit_grid"] in (None, s["grid"]) for s in surfaces)
                else:
                    settled = last.get("grids") == grids
                last["grids"] = grids
                return now if settled else None
            now = wait(drawn, 20, 0.5)
            report = last.get("report")
            if not now:
                # Not settled: read once more, waiting out a report the app does not answer (a
                # loaded host), so the rows name what the app drew, not a failed read.
                report, now = wait(lambda: (lambda r: r if rj_rows.report_error(r[0]) is None else None)(view_panes()), 60, 2) \
                    or view_panes()
            raw[f"debug.surfaces.{name}"] = report
            for pp, pid_ in pane_ids[name]:
                v = now.get(pid_) or {}
                items[f"{pp}.view.size"] = v.get("content_size")
                items[f"{pp}.view.grid"] = (v.get("surface") or {}).get("grid")
                RESULTS.append(grid_fits_view(label, pp, v, report))
    if "cloud" not in SKIP:
        items.update(cloud_items())
    if "agents" not in SKIP:
        # Evidence only (the rows are each chat's own: bound, answering): acpmux's processes.
        out = subprocess.run(["ps", "axo", "pid=,args="], capture_output=True, text=True).stdout
        raw["acpmux.processes"] = sorted(int(line.split(None, 1)[0]) for line in out.splitlines()
                                             if len(line.split(None, 1)) == 2 and line.split(None, 1)[1].startswith(APP.bundle + "/")
                                             and "acpmux" in line)
        chat_items(label, items, raw)
        tagent_items(label, items, raw)
    dump(f"{label}-raw.json", raw)
    dump(f"{label}-items.json", items)
    return items


# ---- settle and compare ----------------------------------------------------------------------

def settled(expected_tabs):
    """Restore has settled when the topology is loaded with every rj-* tab back, the launch
    window has handed over (`debug.windows`: no launch_window, no window awaiting content,
    consistent), and every shown terminal view is attached live (`debug.surfaces`)."""
    topo = topology()
    if not topo or not topo.get("loaded"):
        return False
    if sum(len(tabs_of(w)) for w in rj_workspaces(topo)) < expected_tabs:
        return False
    windows = rpc("debug.windows")
    if not isinstance(windows, dict) or windows.get("launch_window") or windows.get("consistent") is False:
        return False
    if any(w.get("awaiting_content") for w in windows.get("windows", [])):
        return False
    _, views = view_panes()
    shown = [v for v in views.values() if v.get("kind") == "terminal" and v.get("presence") == "visible"]
    return bool(shown) and all(v.get("attach") == "live" for v in shown)


RESULTS = []  # (item, ok, detail, area); ok NA: the row does not apply on this host
NA = "n/a"


def area_of(item):
    if item.startswith(("window", "focus")):
        return "windows"
    if item.startswith("tagent["):
        return "terminal agent"
    if item.startswith(("agent", "chat[", "acpmux.")) or ".agent_session" in item:
        return "agent chat"
    if item.startswith(("counter", "view.", "top.")) or any(k in item for k in (".scrollback", ".terminal", ".dead", ".cwd", ".view.attach")):
        return "terminal"
    if item.startswith("page[") or ".url" in item:
        return "browser"
    if item.startswith("cloud."):
        return "cloud move"
    return "layout"


def broken(v, item=""):
    """A probe that answered nothing usable: missing, empty, or an error."""
    if v in (None, "<missing>", [], {}):
        return True
    if item == "agent.tabs_bound":
        return v == 0
    if isinstance(v, str):
        return v.startswith(("chat_state:", "unreachable"))
    return isinstance(v, dict) and ("error" in v or "code" in v and "message" in v)


def must_have(item):
    """Rows whose value is always present on a working app; for these, equal emptiness is a FAIL."""
    return (item.endswith((".frame", ".layout", ".view.attach", ".selected_workspace", ".id", ".url", ".tabs",
                           ".full_screen", ".sidebar_width", ".sidebar_hidden", ".display", ".view.font_scale"))
            or item.endswith(".agent_session")
            or item.endswith((".view.size", ".view.grid"))
            or item in ("windows.recency", "focus.window", "focus.workspace", "focus.pane", "agent.page", "agent.acpmux", "agent.prompts",
                        "agent.page.session", "agent.tabs_bound")
            or item.startswith(("page[", "cloud."))
            or (item.startswith(("chat[", "tagent[")) and not item.endswith(".missing_session")))


def uneven(items, one, other):
    """Two panes' drawn widths differ by more than 10 points."""
    try:
        widths = [int(str(items.get(f"{p}.view.size")).split("x")[0]) for p in (one, other)]
    except ValueError:
        return False
    return abs(widths[0] - widths[1]) > 10


def seeded(before):
    """FAIL rows for seed parts the before-snapshot does not show, so a seed that failed cannot
    leave an empty comparison that passes."""
    def has(cond):
        return any(cond(k, v) for k, v in before.items())
    checks = {
        "term": [("3000 numbered lines", has(lambda k, v: k.endswith(".scrollback.numbered_lines") and v == SCROLLBACK_LINES)),
                 ("counter running", before.get("counter.alive") is True and isinstance(before.get("counter.tick_in_daemon"), int)),
                 ("top drawing", before.get("top.running") is True and before.get("top.in_view") is True),
                 ("the counter's pane focused", before.get("focus.pane") == "ws[rj-term].s0.pane1"),
                 (f"the counter's terminal zoomed in by {FONT_STEPS} Cmd-+ steps",
                  (before.get("ws[rj-term].s0.pane1.tab0.view.font_scale") or 0) > 1.05),
                 (f"the first window's sidebar at {SIDEBAR_WIDTH} points",
                  has(lambda k, v: k.endswith(".sidebar_width") and isinstance(v, (int, float)) and abs(v - SIDEBAR_WIDTH) <= 1))],
        "web": [("history page at /hist-c after two link clicks", before.get("page[hist].path") == "/hist-c"),
                # Chromium's Back needs it. A capture slot's window is never key, so a posted
                # window-level click does not reach a WebKit page there; WebKit's Back keeps
                # script-added entries, so its seed falls back to the script click.
                *([("both link clicks were posted mouse clicks", len(HIST.get("clicks", [])) == 2 and "script" not in HIST["clicks"])]
                  if engine() == "chromium" else []),
                ("history page has three entries", before.get("page[hist].history_length") == 3),
                ("tall page scrolled", (before.get("page[tall].scrollY") or 0) >= SCROLL - 5)],
        "agent": [("three turns", len(before.get("agent.prompts") or []) == 3),
                  ("chat tab bound to the session", (before.get("agent.tabs_bound") or 0) >= 1
                   and bool(AGENT) and before.get("agent.page.session") == AGENT["session"])],
        "agents": [*[(f"chat {c['label']} bound, picked and answering", before.get(f"chat[{c['label']}].page.session") == c["session"]
                       and before.get(f"chat[{c['label']}].live") is True and len(before.get(f"chat[{c['label']}].prompts") or []) == 2)
                      for c in CHATS],
                   *[(f"terminal agent {t['label']} reports to its hook and answers", t["hook"] == "yes"
                      and before.get(f"tagent[{t['label']}].live") is True and before.get(f"tagent[{t['label']}].signed_in") is True)
                     for t in TAGENTS],
                   (f"{AGENTS_N} chats per harness", len(CHATS) == AGENTS_N * len(CHAT_PROFILES)),
                   (f"{AGENTS_N} terminal agents per CLI", len(TAGENTS) == AGENTS_N * len(CLI_AGENTS))],
        "w2": [("second window", before.get("windows.count") == (2 if "w3" in SKIP else 3)), ("w2 page", before.get("page[w2page].path") == "/w2page"),
               ("w2 page zoomed in by three Cmd-+ steps from 100%", W2.get("steps") == 3 and (before.get("page[w2page].zoom") or 0) > 1.15)],
        "w3": [("third window, on its own space", before.get("window[rj-w3].space") not in (None, "default")),
               ("third window shows rj-w3", before.get("window[rj-w3].selected_workspace") == "rj-w3")],
        "cloud": [("two moved chats", len(before.get("cloud.moved_chats") or []) == 2),
                  ("three move Retries (move, show, update)",
                   sorted(r.get("kind") for r in before.get("cloud.move_retries") or []) == ["move", "show", "update"]),
                  ("a Bring Back Local Retry (ask first)", [r.get("kind") for r in before.get("cloud.bring_back_retries") or []] == ["ask_first"]),
                  ("an Always folder grant", any(g.get("scope") == "account_team_origin_folder" for g in before.get("cloud.grants") or [])),
                  ("a dismissed offer matching its Retry", [d.get("matches_retry") for d in before.get("cloud.dismissed") or []] == [True])],
        "split": [("rj-split workspace", has(lambda k, v: k.startswith("ws[rj-split]."))),
                  # The name and pin rows compare equal emptiness as a pass: they need the seed to show.
                  ("a tab renamed rj-renamed", has(lambda k, v: k.startswith("ws[rj-split].") and k.endswith(".name") and v == "rj-renamed")),
                  ("a pinned tab", has(lambda k, v: k.startswith("ws[rj-split].") and k.endswith(".pinned") and v is True)),
                  # The geometry rows only mean something if the app draws the uneven splits.
                  ("rj-split drawn uneven", uneven(before, "ws[rj-split].s0.pane0", "ws[rj-split].s0.pane2")
                   and uneven(before, "ws[rj-split].s0.pane2", "ws[rj-split].s0.pane3"))],
    }
    for part, rows in checks.items():
        if part in SKIP:
            continue
        for what, ok in rows:
            RESULTS.append((f"seed {part}: {what}", bool(ok), "seeded" if ok else "missing before the quit", "seed"))


def compare(variant, before, after):
    for item in sorted(set(before) | set(after)):
        b, a = before.get(item, "<missing>"), after.get(item, "<missing>")
        if variant == "reboot" and (item.startswith(("counter.", "top.")) or item == "agent.status"):
            # A reboot ends every process: running programs and their screens cannot come back.
            RESULTS.append((f"{variant}: {item}", NA, "n/a: a reboot ends every running program", area_of(item)))
            continue
        if item == "agent.status" and {b, a} <= {"ready", "idle"}:
            # acpmux hibernates a chat whose agent sat idle 2 min (`idle`: no agent process, the next
            # prompt resumes it): the same live session as `ready`, not a lost one.
            RESULTS.append((f"{variant}: {item}", True, f"{json.dumps(b)} -> {json.dumps(a)} (idle: hibernated, resumes on the next prompt)", area_of(item)))
            continue
        if item.startswith("tagent[") and item.endswith(".resume_waits"):
            # Only after a reboot: nothing to compare with before it.
            RESULTS.append((f"{variant}: {item}", a is True, json.dumps(a)[:200], area_of(item)))
            continue
        if item.startswith(("chat[", "tagent[")) and item.endswith((".live", ".signed_in", ".running", ".page.picked")) or item.startswith("tagent[") and item.endswith(".transcript"):
            ok = a is True and b is True
            detail = f"{json.dumps(b)[:100]} -> {json.dumps(a)[:100]}"
        elif item.startswith("counter.tick_in_"):
            ok = isinstance(a, int) and isinstance(b, int) and a > b
            detail = f"{b} -> {a} (must keep counting)"
        elif item.endswith(".frame") and isinstance(a, list) and isinstance(b, list) and len(a) == len(b):
            ok = all(abs(float(x) - float(y)) <= 2 for x, y in zip(a, b))
            detail = f"{b} -> {a}"
        elif item == "page[tall].scrollY" and isinstance(a, int):
            # Against what was seeded, not the last reopen: a lost scroll must not pass the next variant.
            ok = abs(a - SCROLL) <= 40
            detail = f"{b} -> {a} (seeded {SCROLL})"
        elif item.endswith((".view.size", ".view.grid")) and isinstance(a, str) and isinstance(b, str) and "x" in a and "x" in b:
            # The same window frame lays the same splits out again: within 2 points, 1 cell.
            slack = 1 if item.endswith(".grid") else 2
            try:
                ok = all(abs(int(x) - int(y)) <= slack for x, y in zip(a.split("x"), b.split("x")))
            except ValueError:
                ok = False
            detail = f"{b} -> {a}"
        elif item in ("top.running", "top.in_view"):
            ok = a is True and b is True
            detail = f"{b} -> {a}"
        elif item == "page[w2page].zoom" and isinstance(a, (int, float)) and isinstance(b, (int, float)):
            # Against what was seeded, not the last reopen: a lost zoom must not pass the next variant.
            seeded_zoom = SEEDED.get(item, b)
            ok = abs(a - seeded_zoom) <= 0.03
            detail = f"{b} -> {a} (seeded {seeded_zoom})"
        elif item.endswith((".sidebar_width", ".view.font_scale")) and isinstance(a, (int, float)):
            # Against what was seeded, not the last reopen: a lost width or zoom must not pass the next variant.
            seeded_value = SEEDED.get(item, b)
            slack = 1 if item.endswith(".sidebar_width") else 0.01
            ok = isinstance(seeded_value, (int, float)) and abs(a - seeded_value) <= slack
            detail = f"{b} -> {a} (seeded {seeded_value})"
        elif item == "page[tall].self_scrolled":
            # Only the seeded load scrolls itself; every reopened one must get its scroll from restore.
            ok = a == 0
            detail = f"{b} -> {a} (the reopened page must not run the seed's own scroll)"
        elif item == "page[hist].history_length":
            seeded_length = SEEDED.get(item, 3)
            ok = a == seeded_length
            detail = f"{b} -> {a} (seeded {seeded_length}: the address load and two link clicks)"
        elif item.startswith("cloud."):
            # Against what was seeded, not the last reopen: a record lost once must not pass the next variant.
            seeded_value = SEEDED.get(item, b)
            ok = a == seeded_value
            detail = (f"{len(a)} records, as seeded" if ok and isinstance(a, list)
                      else f"seeded {json.dumps(seeded_value)[:160]} -> {json.dumps(a)[:160]}")
        elif item.endswith(".scrollback.history_sha") and a in HISTORY_BY_SHA and b in HISTORY_BY_SHA:
            # Every row exactly as before, in order; rows only after them (a respawned shell's
            # marker line and prompt push the old screen's top rows into the history). Soft
            # wraps must survive the replay too: a line wrapped at an older width re-flows at
            # the new one, so the same text with other row breaks fails ("re-wrapped").
            rows_b, rows_a = HISTORY_BY_SHA[b], HISTORY_BY_SHA[a]
            ok = bool(rows_b) and rows_a[:len(rows_b)] == rows_b
            if a == b:
                detail = json.dumps(a)
            elif ok:
                detail = (f"{json.dumps(b)} -> {json.dumps(a)}: rows kept, {len(rows_a) - len(rows_b)} rows"
                          f" after them {json.dumps(rows_a[len(rows_b):])[:80]}")
            else:
                row = next((i for i, (x, y) in enumerate(zip(rows_b, rows_a)) if x != y), min(len(rows_b), len(rows_a)))
                text_b, text_a = "".join(rows_b), "".join(rows_a)
                rewrapped = bool(rows_b) and text_a.startswith(text_b)
                detail = (f"{json.dumps(b)} -> {json.dumps(a)}: row {row} "
                          f"{json.dumps(rows_b[row] if row < len(rows_b) else None)[:50]} -> "
                          f"{json.dumps(rows_a[row] if row < len(rows_a) else None)[:50]}"
                          + (f" (re-wrapped: same text, {sum(1 for x, y in zip(rows_b, rows_a) if x != y)}"
                             " rows with other breaks)" if rewrapped else " (the text changed)"))
        elif item.endswith(".scrollback.history_rows") and isinstance(a, int) and isinstance(b, int):
            # A view re-attaching may add a prompt line, never drop rows (see history_sha).
            ok = a >= b
            detail = f"{b} -> {a}"
        else:
            ok = a == b
            detail = json.dumps(a)[:100] if ok else f"{json.dumps(b)[:100]} -> {json.dumps(a)[:100]}"
        if ok and must_have(item) and (broken(a, item) or broken(b, item)):
            ok, detail = False, f"no value: {json.dumps(b)[:80]} -> {json.dumps(a)[:80]}"
        RESULTS.append((f"{variant}: {item}", ok, detail, area_of(item)))


def back_walk(label):
    """A person's Back and Forward (Cmd-[ / Cmd-], `browserBack` / `browserForward`) on the
    history tab: c -> b -> a -> b -> c. Each step must bring a report sent after that step, from
    the page it should reach. Run once after seeding (label `seed`: a failure there is the live
    Back bug, not restore) and after each reopen. Puts the page back on c if a step fails, so the
    next variant starts where the seed did."""
    if "web" in SKIP or not HIST.get("tab"):
        return
    hist = lambda: REPORTS.get("hist") or {}
    def reached(path, since):
        return hist().get("path") == path and hist().get("at", 0) > since
    pane = next((p.get("id") for ws in rj_workspaces(topology()) for s_ in ws.get("screens", []) for p in s_.get("panes", [])
                 if any(t.get("id") == HIST["tab"] for t in p.get("tabs", []))), None)
    with visiting("rj-web"):
        focused = rpc("action.run", {"action": "tab.focus", "target": f"tab:{HIST['tab']}", "focus": True})
        start = time.time()
        if not wait(lambda: reached("/hist-c", SINCE), 20, 0.5):
            RESULTS.append((f"{label}: the history tab shows /hist-c before Back", False,
                            f"at {hist().get('path')}; focus {json.dumps(focused)[:80]}", "browser"))
            return
        target = {"target_kind": "pane", "target_id": pane} if pane else {}
        steps = [("browserBack", "/hist-b"), ("browserBack", "/hist-a"), ("browserForward", "/hist-b"), ("browserForward", "/hist-c")]
        for action_id, path in steps:
            step = time.time()
            reply = rpc("debug.toast", {"perform": action_id, **target})
            ok = bool(wait(lambda: reached(path, step), 15, 0.3))
            detail = f"performed {reply.get('performed') if isinstance(reply, dict) else reply}; at {hist().get('path')}"
            if not ok:
                status = rpc("debug.browser.page_status", {"tab": HIST["tab"]})
                status = status if isinstance(status, dict) else {}
                detail += f"; history_start {status.get('history_start')!r} ({time.time() - start:.1f} s after the focus), can_go_back {status.get('can_go_back')!r}"
            RESULTS.append((f"{label}: {action_id} reaches {path}", ok, detail, "browser"))
            if not ok:
                break
        if hist().get("path") != "/hist-c":
            for _ in range(2):  # back to c: Forward first (keeps the list), the address last
                step = time.time()
                rpc("debug.toast", {"perform": "browserForward", **target})
                if wait(lambda: reached("/hist-c", step), 5, 0.3):
                    break
            else:
                rpc("browser.page.eval", {"tab": HIST["tab"], "script": f"location.href = '{'hist-c.html' if opts.hist_file else '/hist-c'}'; true"})
                wait(lambda: hist().get("path") == "/hist-c" and hist().get("at", 0) > start, 10, 0.3)
                RESULTS.append((f"{label}: page put back on /hist-c by its address", False,
                                "Forward could not return; the next variant's history length counts from here", "browser"))


def load_rows(variant, launched):
    """How long each page took to report after the relaunch (restore time per tab, compared
    before and after a change), and that the reopened history page loaded once."""
    if "web" in SKIP:  # no page was seeded: nothing reports, nothing reopens
        return
    with LOCK:
        first = {}
        for page, at in REPORT_LOG:
            if at > launched and page not in first:
                first[page] = at - launched
        hist_loads = sum(1 for page, at in PAGE_LOADS if page == "hist-c" and at > launched)
    timings = ", ".join(f"{page} {first[page]:.2f} s" for page in sorted(first))
    say(f"  pages reported after the relaunch: {timings or 'none'}")
    RESULTS.append((f"{variant}: pages report after the relaunch", bool(first), timings or "no page reported", "browser"))
    if not opts.hist_file:
        # WebKit's own restore may show the page from its cache (0 requests): still one load.
        # A restored Chromium page in a workspace nobody shows loads when it is shown, after this row.
        RESULTS.append((f"{variant}: page[hist] loads once after the reopen", hist_loads <= 1,
                        f"the server sent /hist-c {hist_loads} times" + ("" if "hist" in first else " (not shown yet)"), "browser"))
    def page_status():
        status = rpc("debug.browser.page_status", {"tab": HIST.get("tab")}) if HIST.get("tab") else {}
        return status if isinstance(status, dict) else {}
    status = page_status()
    if HIST.get("tab") and status.get("error") == "no browser tab":
        # A tab in a workspace not shown yet has no page until it is shown.
        with visiting("rj-web"):
            wait(lambda: page_status().get("history_start") not in (None, "", "engine-waiting-file"), 15, 0.3)
            status = page_status()
    RESULTS.append((f"{variant}: page[hist] reopens through the engine's own history", status.get("history_start") == "engine",
                    f"history_start {status.get('history_start')!r}, engine_state_saved {status.get('engine_state_saved')!r}, "
                    f"can_go_back {status.get('can_go_back')!r}" + ("" if "history_start" in status else f"; {json.dumps(status)[:160]}"), "browser"))
    if opts.hist_file:
        # Only a report the reopened page sent counts (a pre-quit one would pass falsely).
        fresh = REPORTS.get("hist") if (REPORTS.get("hist") or {}).get("at", 0) > launched else {}
        # A file page sees its own folder only, on both engines (Chromium: CEFShim
        # local_file_scope.h, cx-ary1f), fresh or reopened.
        ext = fresh.get("ext")
        RESULTS.append((f"{variant}: page[hist] shows nothing outside its folder",
                        ext == 0,
                        f"probe {ext} after the reopen, {LIVE_READ.get('hist_ext')} on the page loaded fresh (1 shown, 0 refused, -1 no probe)", "browser"))
        # Reading a file outside the page's folder stays refused on both engines, fresh or reopened.
        read = fresh.get("read")
        RESULTS.append((f"{variant}: page[hist] reads nothing outside its folder",
                        read == 0,
                        f"read {read} after the reopen, {LIVE_READ.get('hist')} on the page loaded fresh (1 read, 0 refused, -1 no probe)", "browser"))


# ---- the daemon variants: a killed or stopped cmux-tui under a running app -----------------

DAEMON_VARIANTS = ("daemon", "daemon-stop")
STOPPED = set()  # daemon pids daemon-stop froze; ended at exit if still there


def end_stopped_daemons():
    """A frozen daemon that Restart did not end: let it run, then end it (SIGKILL). Only a pid that
    is still one of the app's daemons: a pid the system reused for something else is left alone."""
    try:
        current = set(APP.daemon_pids()) if APP else set()
    except Exception:
        current = set()
    for pid in sorted(STOPPED & current):
        try:
            os.kill(pid, signal.SIGCONT)
            os.kill(pid, signal.SIGKILL)
            say(f"  ended the stopped daemon {pid}")
        except OSError:
            pass
    STOPPED.clear()


atexit.register(end_stopped_daemons)


def daemon_state(timeout=3):
    """`debug.daemon`: the app's daemon connection and recovery; None when it does not answer."""
    answer = rpc("debug.daemon", timeout=timeout)
    return answer if isinstance(answer, dict) and "error" not in answer else None


def reconnected(old):
    """The app is connected to a daemon that is not one of `old`; its pid, or None."""
    state = daemon_state() or {}
    pid = state.get("pid")
    return int(pid) if state.get("connection") == "connected" and pid and int(pid) not in old else None


def daemon_recovery(variant, started, sampler, turn):
    """After the kill or stop: the seconds to a new daemon and to the app connected to it; for
    daemon-stop, the seconds until the app offers Restart, then Restart through `debug.daemon`."""
    old = set(APP.killed_daemons)
    if variant == "daemon-stop":
        offered = wait(lambda: ((daemon_state() or {}).get("recovery") or {}).get("offers_restart") is True, 150, 0.25)
        at = time.time() - started
        RESULTS.append((f"{variant}: the app offers Restart cmux-tui", bool(offered),
                        f"{at:.1f} s after the stop" if offered else f"not within {at:.0f} s: {json.dumps(daemon_state())[:300]}",
                        "app quit"))
        pressed = rpc("debug.daemon", {"action": "restart"}, timeout=10)
        say(f"  daemon-stop: Restart -> {json.dumps(pressed)[:200]}")
        restarted_at = time.time()
    fresh = wait(lambda: [p for p in APP.daemon_pids() if p not in old], 90, 0.25)
    new_at = time.time() - started
    RESULTS.append((f"{variant}: a new daemon starts", bool(fresh),
                    f"{new_at:.1f} s after the {'stop' if variant == 'daemon-stop' else 'kill'}, pids {fresh}" if fresh
                    else f"none within {new_at:.0f} s", "app quit"))
    pid = wait(lambda: reconnected(old), 90, 0.25)
    at = time.time() - started
    detail = f"{at:.1f} s after the {'stop' if variant == 'daemon-stop' else 'kill'}, daemon {pid}"
    if variant == "daemon-stop":
        detail += f", {time.time() - restarted_at:.1f} s after Restart"
    RESULTS.append((f"{variant}: the app reconnects to the new daemon", bool(pid),
                    detail if pid else f"not within {at:.0f} s: {json.dumps(daemon_state())[:300]}", "app quit"))
    if variant == "daemon-stop":
        alive = [p for p in old if _pid_alive(p)]
        RESULTS.append((f"{variant}: Restart ends the stopped daemon", not alive,
                        f"still there: {alive}" if alive else "gone", "app quit"))
        end_stopped_daemons()


class RecoverySampler:
    """What the app shows while its daemon is gone, every 250 ms (`debug.daemon`, `debug.surfaces`).
    The designed recovery state: each window shows its workspace or the connecting view
    (DaemonConnectingView), no pane is blank, and every shown terminal is connected, restoring, or
    disconnected and reconnecting. A terminal disconnected for good (no reconnect) for over a
    second, a window with nothing, or one blank pane is not. Both calls must keep answering after
    the kill: a stretch of over GAP seconds without an answer from either is a violation too (a
    hung app shows nothing designed)."""

    CALL_TIMEOUT = 1.0
    GAP = 1.0

    def __init__(self):
        self.samples, self.stop, self.thread, self.killed = [], threading.Event(), None, None

    def start(self, started):
        self.started = started

        def run():
            while not self.stop.is_set():
                at = time.time() - self.started
                self.samples.append((at, daemon_state(self.CALL_TIMEOUT), rpc("debug.surfaces", timeout=self.CALL_TIMEOUT)))
                self.stop.wait(0.25)
        self.thread = threading.Thread(target=run, daemon=True)
        self.thread.start()

    def halt(self):
        """Stops sampling; a sample in flight ends within both calls' timeouts."""
        self.stop.set()
        if self.thread:
            self.thread.join(2 * self.CALL_TIMEOUT + 2)
        return list(self.samples)

    @staticmethod
    def surfaces_answered(surfaces):
        return isinstance(surfaces, dict) and "error" not in surfaces

    def gaps(self, samples, end):
        """(largest gap between samples, per call the largest stretch after the kill without an answer)."""
        ats = [at for at, _, _ in samples]
        between = max((b - a for a, b in zip(ats, ats[1:])), default=end)
        killed = self.killed if self.killed is not None else 0.0
        silent = {}
        for name, answered in (("debug.daemon", lambda st, su: bool(st)), ("debug.surfaces", lambda st, su: self.surfaces_answered(su))):
            last, worst = killed, 0.0
            for at, state, surfaces in samples:
                if at < killed:
                    continue
                if answered(state, surfaces):
                    worst, last = max(worst, at - last), at
            silent[name] = max(worst, end - last)
        return between, silent

    @staticmethod
    def problems(state, surfaces):
        """(hard problems, terminals disconnected for good) of one sample."""
        hard, dead = [], []
        for window in (state or {}).get("windows") or []:
            if window.get("shows") not in ("content", "connecting"):
                hard.append(f"window {window.get('id')} shows {window.get('shows')}")
        if isinstance(surfaces, dict) and "error" not in surfaces:
            if surfaces.get("blank_panes"):
                hard.append(f"{surfaces.get('blank_panes')} blank pane(s)")
            for window in surfaces.get("windows") or []:
                for pane in window.get("panes") or []:
                    if pane.get("kind") != "terminal" or pane.get("presence") != "visible":
                        continue
                    link = str(pane.get("link"))
                    if link in ("connected", "restoring") or (link.startswith("disconnected:") and link.endswith(":reconnecting")):
                        continue
                    dead.append(f"pane {pane.get('pane')} {link}")
        return hard, dead

    def finish(self, variant):
        samples = self.halt()
        end = time.time() - self.started
        seen, violations, dead_since = {}, [], None
        for at, state, surfaces in samples:
            hard, dead = self.problems(state, surfaces)
            violations += [f"{at:.2f} s: {h}" for h in hard]
            if dead:
                dead_since = at if dead_since is None else dead_since
                if at - dead_since > 1.0:
                    violations.append(f"{at:.2f} s: {', '.join(dead)} since {dead_since:.2f} s")
            else:
                dead_since = None
            shows = ",".join(sorted({w.get("shows", "?") for w in (state or {}).get("windows") or []})) or "no answer"
            links = set()
            for window in (surfaces or {}).get("windows") or [] if isinstance(surfaces, dict) else []:
                links |= {str(p.get("link")).split(":")[0] for p in window.get("panes") or []
                          if p.get("kind") == "terminal" and p.get("presence") == "visible"}
            key = f"{(state or {}).get('connection', 'no answer')}/{shows}/{'+'.join(sorted(links)) or '-'}"
            seen[key] = seen.get(key, 0) + 1
        dump(f"{variant}-recovery-samples.json", [{"at": round(at, 2), "daemon": state, "blank_panes": (surfaces or {}).get("blank_panes")
                                                     if isinstance(surfaces, dict) else None} for at, state, surfaces in samples])
        killed = self.killed if self.killed is not None else 0.0
        answered = sum(1 for at, state, _ in samples if state and at >= killed)
        surfaced = sum(1 for at, _, surfaces in samples if self.surfaces_answered(surfaces) and at >= killed)
        between, silent = self.gaps(samples, end)
        for name, worst in silent.items():
            if worst > self.GAP:
                violations.append(f"{name} did not answer for {worst:.2f} s")
        ok = answered > 0 and surfaced > 0 and not violations
        detail = (f"{len(samples)} samples (after the kill: debug.daemon answered {answered}, debug.surfaces {surfaced}); "
                  f"largest gap between samples {between:.2f} s, without an answer "
                  f"{', '.join(f'{n} {w:.2f} s' for n, w in silent.items())}; states {json.dumps(seen)[:400]}"
                  + (f"; NOT designed: {'; '.join(violations[:5])}" if violations else ""))
        RESULTS.append((f"{variant}: the UI shows the designed recovery state meanwhile (no blank pane)", ok, detail, "layout"))


def start_turn_in_flight(variant):
    """An agent chat turn in flight at the kill: the first seeded chat's `gate:` turn (the test
    agent streams before-gate, then waits on a FIFO the journey writes after the reconnect)."""
    client = acpmux_client() if CHATS else None
    if not client:
        RESULTS.append((f"{variant}: an agent chat turn is in flight at the {'stop' if variant == 'daemon-stop' else 'kill'}",
                        False, "no seeded agent chat or acpmux client to start one", "agents"))
        return None
    chat = CHATS[0]
    fifo = os.path.join(opts.out, f"rj-gate-{variant}-{RUN}")
    try:
        os.mkfifo(fifo)
    except FileExistsError:
        pass
    box = {}

    def run():
        try:
            box["answer"] = Acpmux(acpmux_socket_of(ACPMUX["home"])).request(
                "session/prompt", {"sessionId": chat["session"], "prompt": [{"type": "text", "text": f"gate: {fifo}"}],
                                   "_meta": {"acpmux": {"promptId": f"rj-{RUN}-gate-{variant}"}}}, timeout=400)
        except Exception as error:
            box["answer"] = {"error": {"message": str(error)}}
    thread = threading.Thread(target=run, daemon=True)
    thread.start()

    def streaming():
        events = ((client.request("_acpmux/events", {"sessionId": chat["session"], "afterSeq": 0, "limit": 5000}).get("result") or {})
                  .get("events")) or []
        return any("before-gate" in json.dumps(event) for event in events[-50:])
    began = wait(streaming, 20, 0.25)
    RESULTS.append((f"{variant}: an agent chat turn is in flight at the {'stop' if variant == 'daemon-stop' else 'kill'}",
                    bool(began), "streamed before-gate, waiting on its gate" if began else "the turn never started", "agents"))
    return {"chat": chat, "fifo": fifo, "thread": thread, "box": box}


def finish_turn_in_flight(variant, turn):
    """Opens the turn's gate; it must end (end_turn) and its answer show on the chat's page."""
    try:
        fd = os.open(turn["fifo"], os.O_WRONLY | os.O_NONBLOCK)
        os.write(fd, b"go")
        os.close(fd)
    except OSError as error:
        say(f"  the gate turn is not waiting: {error}")
    turn["thread"].join(60)
    answer = turn["box"].get("answer") or {}
    stop = (answer.get("result") or {}).get("stopReason")
    topo = topology()
    tab = next((t for ws in rj_workspaces(topo) for t in tabs_of(ws) if t.get("agent_session") == turn["chat"]["session"]), None)
    shown = None
    if tab:
        with visiting("rj-chats"):
            pane = place_of(tab.get("id"), topo)[1]
            # Its pane holds another chat too: show this chat's tab, and read only its own page.
            # The tab the pane showed comes back after, so the layout rows see the seeded state.
            shown_tab = pane_active_tab(pane)
            cli("tab", tab["id"], "focus", quiet=True)
            def own_page_shows():
                state = page(pane, "chat_state") or {}
                return state.get("sessionId") == turn["chat"]["session"] and "after-gate" in str((state.get("lastAssistant") or {}).get("text"))
            shown = wait(own_page_shows, 20, 0.5)
            if shown_tab and shown_tab != tab["id"]:
                cli("tab", shown_tab, "focus", quiet=True)
    RESULTS.append((f"{variant}: the turn in flight finishes and its page shows it", stop == "end_turn" and bool(shown),
                    f"stopReason {stop}, page {'shows' if shown else 'does not show'} after-gate"
                    + (f"; {json.dumps(answer)[:200]}" if stop != "end_turn" else ""), "agents"))
    try:
        os.remove(turn["fifo"])
    except OSError:
        pass


def journey(base):
    global SINCE
    seed(base)
    back_walk("seed")  # before any reopen: tells the live Back bug apart from a restore loss
    for n, variant in enumerate(v.strip() for v in opts.variants.split(",") if v.strip()):
        before = snapshot(f"{variant}-before")
        if n == 0:
            seeded(before)
            SEEDED.update({k: v for k, v in before.items() if k in ("page[hist].history_length", "page[w2page].zoom")
                           or k.startswith("cloud.") or k.endswith((".sidebar_width", ".view.font_scale"))})
        if variant == "crash":
            # A crash comes after the last change has been saved (the browser history and record
            # writers debounce 500 ms); the rows check what was saved, not what was still in flight.
            time.sleep(2)
        expected = sum(len(tabs_of(w)) for w in rj_workspaces(topology()))
        if opts.hist_file and "hist" in REPORTS and "hist" not in LIVE_READ:
            # The seeded page, loaded fresh by link clicks: what a fresh load may read.
            LIVE_READ["hist"] = REPORTS["hist"].get("read")
            LIVE_READ["hist_ext"] = REPORTS["hist"].get("ext")
            RESULTS.append(("seed web: the file page loaded fresh reads nothing outside its folder", LIVE_READ["hist"] == 0,
                            f"read {LIVE_READ['hist']} (1 read, 0 refused, -1 no probe)", "seed"))
            RESULTS.append(("seed web: the file page loaded fresh shows nothing outside its folder", LIVE_READ["hist_ext"] == 0,
                            f"probe {LIVE_READ['hist_ext']} (1 shown, 0 refused, -1 no probe)", "seed"))
        turn = start_turn_in_flight(variant) if variant in DAEMON_VARIANTS else None
        sampler = RecoverySampler() if variant in DAEMON_VARIANTS else None
        started = SINCE = time.time()
        if sampler:
            sampler.start(started)
        if not APP.quit(variant):
            RESULTS.append((f"{variant}: app ends ({'killed' if variant == 'crash' else 'its quit path'})", False, "still running", "app quit"))
            if sampler:
                sampler.halt()
            if turn:
                try:
                    os.remove(turn["fifo"])
                except OSError:
                    pass
            return
        if sampler:
            sampler.killed = time.time() - started
        # Reports count from here: the old app's pages keep reporting until its process ends, and
        # one of those would pass for a reopened page that has not reported yet (cx-p1xs5).
        if variant == "update" and opts.update_to and not UPDATED and not update_build():
            return
        launched = SINCE = time.time()
        if variant in DAEMON_VARIANTS:
            # No relaunch: the running app must bring a new daemon and every view back.
            daemon_recovery(variant, started, sampler, turn)
        elif not APP.relaunch({"CMUX_NEXT_DEBUG_SLOW_ATTACH": SLOW_ATTACH} if variant == "slow" else None):
            RESULTS.append((f"{variant}: app relaunches", False, "no socket", "app quit"))
            return
        if variant == "update" and UPDATED and "relaunched" not in UPDATED:
            UPDATED["relaunched"] = True
            updated_rows()
        if variant == "slow":
            # No input from here on: the terminals must come back by themselves.
            links = set()
            def restoring_seen():
                report = rpc("debug.surfaces", timeout=10)
                for window in report.get("windows", []) if isinstance(report, dict) else []:
                    for pane in window.get("panes", []):
                        if pane.get("kind") == "terminal" and pane.get("presence") == "visible":
                            links.add(str(pane.get("link")))
                return "restoring" in links
            seen = wait(restoring_seen, 15, 0.25)
            RESULTS.append((f"{variant}: a terminal still attaching says Restoring…", bool(seen),
                            f"links seen: {sorted(links)}", "terminal"))
        ok = wait(lambda: settled(expected), opts.settle, 1)
        took = time.time() - started
        say(f"  restore {'settled' if ok else 'did NOT settle'} {took:.1f} s after the quit")
        RESULTS.append((f"{variant}: restore settles", bool(ok), f"{took:.1f} s after the quit", "layout"))
        if sampler:
            sampler.finish(variant)
        if turn:
            finish_turn_in_flight(variant, turn)
        # The counter's next tick, in the view (it must keep counting after the reopen).
        if isinstance(before.get("counter.tick_in_view"), int):
            wait(lambda: view_tick() > before["counter.tick_in_view"], 10, 0.5)
        if opts.break_cloud and n == 0:
            say(f"  --break-cloud: forgetting one {opts.break_cloud} -> {json.dumps(rpc('debug.cloud.move_seed', {'drop': opts.break_cloud}))}")
        compare(variant, before, snapshot(f"{variant}-after"))
        load_rows(variant, launched)
        back_walk(f"{variant} after the reopen")


def engine():
    """The app's browser engine for new pages (`webkit` or `chromium`)."""
    return (rpc("settings.get", {"path": "browser.defaultEngine"}) or {}).get("value")


ENGINE_CONFIG = {}  # the slot settings file --engine changed: {"path", "text"} to put back


def use_engine(engine):
    """Points browser.defaultEngine at `engine` in the slot's own settings file and waits for the
    app to read it. Only a capture slot's file (its launch sets CMUX_NEXT_CONFIG_FILE and
    CMUX_CAPTURE_SLOT): a mini's shared settings are never written."""
    path = APP.env.get("CMUX_NEXT_CONFIG_FILE")
    if not path or not APP.env.get("CMUX_CAPTURE_SLOT"):
        sys.exit("--engine needs a capture slot's own settings file (CMUX_NEXT_CONFIG_FILE and CMUX_CAPTURE_SLOT)")
    text = open(path).read() if os.path.exists(path) else None
    ENGINE_CONFIG.update(path=path, text=text)
    config = json.loads(text) if text and text.strip() else {}
    config.setdefault("browser", {})["defaultEngine"] = engine
    with open(path, "w") as f:
        json.dump(config, f, indent=2)
    read = lambda: (rpc("settings.get", {"path": "browser.defaultEngine"}) or {}).get("value") == engine
    if not wait(read, 20, 0.5):
        sys.exit(f"the app never read browser.defaultEngine {engine} from {path}")
    say(f"  browser.defaultEngine {engine} in {path}")


def restore_engine_config():
    path = ENGINE_CONFIG.pop("path", None)
    if not path:
        return
    text = ENGINE_CONFIG.pop("text", None)
    if text is None:
        os.unlink(path)
    else:
        with open(path, "w") as f:
            f.write(text)


atexit.register(restore_engine_config)


def main():
    global APP
    APP = App()
    if opts.engine:
        use_engine(opts.engine)
    server, base = start_server()
    say(f"local pages at {base}; daemon {daemon_socket()}")
    try:
        journey(base)
    except SystemExit as stop:  # --max-seconds, a signal, or the parent gone: keep the rows so far
        RESULTS.append(("journey finished", False, f"stopped early: {stop.code}", "harness"))
    finally:
        restore_acpmux_config()
        restore_engine_config()
        server.shutdown()
    width = max((len(r[0]) for r in RESULTS), default=10)
    print("\n" + "-" * (width + 40))
    for item, ok, detail, area in RESULTS:
        print(f"{'N/A ' if ok is NA else 'PASS' if ok else 'FAIL'}  {item:<{width}}  [{area}] {detail}")
    # A row with ok NA does not apply on this host (one display): neither passed nor failed.
    counted = [r for r in RESULTS if r[1] is not NA]
    failed = [r for r in counted if not r[1]]
    print(f"RESULT {'PASS' if not failed else 'FAIL'}: {len(counted) - len(failed)}/{len(counted)} rows pass"
          f"{f', {len(RESULTS) - len(counted)} n/a' if len(counted) < len(RESULTS) else ''}; out {opts.out}")
    dump("report.json", [{"item": r[0], "ok": r[1], "detail": r[2], "area": r[3]} for r in RESULTS])
    sys.exit(1 if failed else 0)


APP = None
if __name__ == "__main__":
    main()
