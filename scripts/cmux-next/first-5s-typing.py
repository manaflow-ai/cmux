#!/usr/bin/env python3
"""Run-it-yourself bench: the first 5 s of typing into a new terminal, a new split and a new browser tab.

Lawrence (2026-10-27, v2.2.3): "typing into a new terminal is laggy at first but then no more lag after like 3
seconds", and the same for other first actions (new tabs). The first-keys check (new-terminal-first-keys.py) times only
the first key of each new terminal, so it cannot see a lag that lasts seconds. This bench types for the whole window.

Per app (several fleet builds in one step, so they share a host, a display and a shell): launch it with a real shell
config like Lawrence's (oh-my-zsh, the half-life theme, zsh-autosuggestions and a long history, its prompt in a git
repository: this checkout), open a base terminal, then per round:

  terminal  Cmd-T (a new terminal tab), then one key every --interval (50 ms) for --seconds (5 s), the first key
            --interval after the Cmd-T;
  split     Cmd-D (a new terminal split), the same keys;
  browser   Cmd-Shift-L (a new browser tab; its address bar has the keyboard), the same keys into the address bar.

Each key's latency is put against the time since the open key, in 500 ms buckets (p50 / p95 / max per bucket):

  probe     cmux-next builds: the typing probe (CMUX_NEXT_TYPING_PROBE) key-to-frame, `contents_ms` (the frame Ghostty
            hands to the layer after the echo's parse) or, for an AppKit text field, `commit_ms`; with its hops
            (dispatch, PTY write, echo received) so the app's share and the shell's share are apart.
  photon    every build, classic cmux too: the first frame of the app's window that changed after the key, read from
            ScreenCaptureKit in a process of its own (first5s-photon.swift, display time on the key's clock). Cursor
            blink is off, so a change after a key is the key's echo or other work the window shows.

Keys are the app's own synthetic key path (cmux-next `debug.key`, classic `simulate_shortcut`). The sender spins to each
key's planned time (never `time.sleep`: a fleet step's sleep woke up to ~150 ms late and sent 2-3 keys at once, a fake
50 ms staircase in every build) and stamps each key with the time it really left, as a keyboard stamps a person's key;
a key that then waits for a busy main thread counts that wait. `FIRST5S-SENDER` reports how late each key left; a run
whose max is over 1 ms is not valid (`sender_valid` false in the report). (Real HID input needs the Accessibility
grant, which the perf hosts do not hold.)

Over the same window it records what the main thread did:
  hangs     cmux-next: `debug.hangs` with the watchdog at --hang-ms (8 ms): each stall's start, length, CPU and
            stack, the scheduled task it caught, and the tasks over their budget, placed on the round's timeline.
  sample    one extra round per scenario under `/usr/bin/sample` (1 ms), the main thread's call tree (both families).

  first-5s-typing.py --app APP --out DIR [--json FILE] [--family next|classic] [--scenarios terminal,split,browser]
                     [--rounds 6] [--seconds 5] [--interval 0.05]
  first-5s-typing.py --apps-sha256 A,B,C --out DIR   (fleet builds, fetched by fleet-app-fetch.py)
  split-spring.sh --suite=first5s --apps-sha256=A,B,C --vdisplay=120   (on a perf-lead Mac through cmux-ci, exclusive)
  first-5s-typing.py --self-check [--json FILE]   the sender's own check, no app: a planned 1-key-per-50-ms sender
                     reports each key's real send time (exit 1 when it does not)

Never a CI job: run it yourself on the fleet, before and after a change.
"""
import argparse, base64, glob, json, os, pwd, re, shutil, signal, socket, statistics, subprocess, sys, threading, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import hid_input  # noqa: E402
import typing_report  # noqa: E402
from bench_launch import BenchApp, LaunchError, main_binary, shipping_env  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--app")
parser.add_argument("--apps-sha256", default="", help="comma list of fleet app artifacts (sha256), measured in turn")
parser.add_argument("--out", help="the report folder (required except with --self-check)")
parser.add_argument("--json")
parser.add_argument("--tag")
parser.add_argument("--features", default="",
                    help="one entry per app, separated by '/': the CMUX_ENABLE_FEATURES of that run (comma list, empty: defaults), "
                         "so one build runs twice, with its defaults and with switches on")
parser.add_argument("--families", default="", help="comma list, one per app: next (cmux-next) or classic (default next)")
parser.add_argument("--scenarios", default="terminal,split,newtab,browser")
parser.add_argument("--rounds", type=int, default=6, help="measured rounds per scenario")
parser.add_argument("--sample-rounds", type=int, default=1, help="extra rounds per scenario under /usr/bin/sample")
parser.add_argument("--seconds", type=float, default=5.0)
parser.add_argument("--interval", type=float, default=0.05)
parser.add_argument("--bucket-ms", type=float, default=500)
parser.add_argument("--settle", type=float, default=1.5)
parser.add_argument("--gap", type=float, default=3.0, help="seconds between rounds (the close settles)")
parser.add_argument("--hang-ms", type=int, default=8)
parser.add_argument("--no-photon", action="store_true")
parser.add_argument("--no-shell", action="store_true", help="the host's own shell config (no oh-my-zsh)")
parser.add_argument("--still", action="store_true", help="a JPEG of the window at the end of each round in the report")
parser.add_argument("--self-check", action="store_true",
                    help="only the sender's check (no app): each key carries the time it really left, not its plan")
opts, _unknown = parser.parse_known_args()
if not opts.out and not opts.self_check:
    parser.error("--out is required")

OUT = os.path.abspath(opts.out or ".")
if not opts.self_check:
    os.makedirs(OUT, exist_ok=True)
SCENARIOS = [s for s in opts.scenarios.split(",") if s]
# cmux-next: Ctrl-` is New Terminal Tab, Cmd-T the New Tab page, Cmd-D a split, Cmd-Shift-L a browser tab
# (DebugInstantCreateBench's keys). Classic: Cmd-T is a new terminal tab.
OPEN_KEYS = {"terminal": ("`", ["control"]), "newtab": ("t", ["command"]), "split": ("d", ["command"]),
             "browser": ("l", ["command", "shift"])}
CLASSIC_OPEN_KEYS = {"terminal": ("t", ["command"]), "split": ("d", ["command"]), "browser": ("l", ["command", "shift"])}
KEY_CODES = dict(hid_input.KEYCODES, **{"`": 50})
MODIFIER_CODES = {"command": 55, "shift": 56, "control": 59, "option": 58}
REPO = subprocess.run(["git", "-C", HERE, "rev-parse", "--show-toplevel"], capture_output=True, text=True).stdout.strip() or HERE
NOW_NS = lambda: time.clock_gettime_ns(getattr(time, "CLOCK_UPTIME_RAW", time.CLOCK_MONOTONIC))  # noqa: E731
SENDER_VALID_MS = 1.0  # a run whose sender left a key more than this late is not valid


def paced_send(start_ns, count, interval_ns, send, now=NOW_NS):
    """Sends keys 1..count at start_ns + k * interval_ns: spins to each key's time (a fleet step's `time.sleep` woke up
    to ~150 ms late, sending 2-3 keys at once) and calls send(k, at_ns) with the time the key really leaves, which the
    key carries as its stamp. Returns how late each key left its plan, in ms."""
    late = []
    for k in range(1, count + 1):
        when = start_ns + k * interval_ns
        while now() < when:
            pass
        at = now()
        send(k, at)
        late.append(round((at - when) / 1e6, 3))
    return late


RECEIVER = r'''
import json, socket, sys, time
now = lambda: time.clock_gettime_ns(getattr(time, "CLOCK_UPTIME_RAW", time.CLOCK_MONOTONIC))
conn = socket.socket(fileno=int(sys.argv[1]))
buf, out = b"", []
while True:
    chunk = conn.recv(65536)
    at = now()
    if not chunk:
        break
    buf += chunk
    while b"\n" in buf:
        line, buf = buf.split(b"\n", 1)
        out.append([json.loads(line)["params"]["timestamp"], at])
print(json.dumps(out))
'''


def self_check(seconds=5.0, interval=0.05):
    """The sender's own check (sequence-manager-DESIGN.md S0): a planned 1-key-per-50-ms sender reports each key's
    real send time. Part 1 (a clock that jumps 150 ms, as the late sleep did): every stamp is the time the key left,
    never its plan, and the lateness says so. Part 2 (the real clock, a receiver in its own process so this one's GIL
    does not delay it): every stamp is within 1 ms of the key's arrival and no key leaves more than 1 ms late."""
    result = {"seconds": seconds, "interval": interval}
    # Part 1, a unit check of paced_send at a fixed 50 ms plan whatever --interval is: a clock that loses 150 ms once,
    # before key 3 (the old sender stamped keys 3-5 with their plans).
    step = 50_000_000
    clock = {"t": 0, "jumped": False}

    def fake_now():
        clock["t"] += 1000  # 1 us per read: the spin advances
        if not clock["jumped"] and clock["t"] >= int(2.5 * step):
            clock["jumped"], clock["t"] = True, clock["t"] + 150_000_000
        return clock["t"]
    stamps = []
    late = paced_send(0, 6, step, lambda k, at: stamps.append((k, at, clock["t"])), now=fake_now)
    plan = [k * step for k in range(1, 7)]
    real = all(at == t for _k, at, t in stamps)
    # Keys 3-5 were due during the lost 150 ms: they leave at once, after it, each stamped then (late 125, 75 and
    # 25 ms), where the old sender stamped them 150, 200 and 250 ms (their plans) and reported nothing late.
    stamped_late = [k for (k, at, _t), p in zip(stamps, plan) if at - p >= 1_000_000]
    result["jump"] = {"late_ms": late, "stamps_are_send_times": real, "keys_stamped_after_plan": stamped_late}
    ok_jump = (real and stamped_late == [3, 4, 5] and late[2] >= 100 and late[3] >= 50 and late[4] >= 1
               and max(late[0], late[1], late[5]) < SENDER_VALID_MS)
    # Part 2: the real clock and a real socket.
    a, b = socket.socketpair()
    receiver = subprocess.Popen([sys.executable, "-I", "-c", RECEIVER, str(b.fileno())], pass_fds=(b.fileno(),),
                                stdout=subprocess.PIPE, text=True)
    b.close()
    count = int(round(seconds / interval))

    def send(k, at):
        a.sendall((json.dumps({"id": k, "method": "debug.key", "params": {"key": "a", "timestamp": at / 1e9}}) + "\n").encode())
    late, got = [], []
    try:
        time.sleep(0.2)  # the receiver is up
        late = paced_send(NOW_NS(), count, int(interval * 1e9), send)
        a.close()
        got = json.loads(receiver.communicate(timeout=30)[0] or "[]")
    except (OSError, ValueError, subprocess.TimeoutExpired) as error:
        result["error"] = repr(error)
    finally:
        a.close()
        if receiver.poll() is None:
            receiver.kill()
            receiver.wait()
    transit = [round((at - stamp * 1e9) / 1e6, 3) for stamp, at in got]
    result["real"] = {"keys": count, "received": len(got), "late_ms": typing_report.distribution(late, mean=False),
                      "stamp_to_arrival_ms": typing_report.distribution(transit, mean=False)}
    ok_real = (bool(got) and len(got) == count and max(late) <= SENDER_VALID_MS and min(transit) >= -0.001
               and max(transit) <= SENDER_VALID_MS)
    result["ok"] = ok_jump and ok_real
    note(f"FIRST5S-SELFCHECK {'pass' if result['ok'] else 'FAIL'}: jump {json.dumps(result['jump'])}; "
         f"real {json.dumps(result['real'])}")
    return result


def note(text):
    print(text, flush=True)


def account_home():
    return pwd.getpwuid(os.getuid()).pw_dir


# ---------------------------------------------------------------- the shell: oh-my-zsh + autosuggestions + git prompt
ZSHRC = r'''# first-5s-typing.py: a shell like Lawrence's (oh-my-zsh, half-life, zsh-autosuggestions, long history, git repo)
export ZSH="$ZDOTDIR/ohmyzsh"
ZSH_THEME="half-life"
DISABLE_AUTO_UPDATE=true
zstyle ':omz:update' mode disabled
ZSH_COMPDUMP="$ZDOTDIR/.zcompdump"
HISTFILE="$ZDOTDIR/.zsh_history"
HISTSIZE=50000
SAVEHIST=50000
plugins=(git zsh-autosuggestions)
source "$ZSH/oh-my-zsh.sh"
[[ -n "$FIRST5S_REPO" ]] && cd "$FIRST5S_REPO"
: > "$ZDOTDIR/loaded.$$"
'''


def clone(url, dest):
    cache_root = os.environ.get("CI_SHARED_CACHE_DIR")
    cached = os.path.join(cache_root, "first5s-shell", os.path.basename(dest)) if cache_root else None
    if cached and os.path.isdir(os.path.join(cached, ".git")):
        shutil.copytree(cached, dest, symlinks=True)
        return "cache"
    subprocess.run(["git", "clone", "--quiet", "--depth", "1", url, dest], check=True, timeout=300)
    if cached:
        try:
            shutil.rmtree(cached, ignore_errors=True)
            shutil.copytree(dest, cached, symlinks=True)
        except OSError:
            pass
    return "clone"


def shell_setup():
    """ZDOTDIR with oh-my-zsh (half-life), zsh-autosuggestions and 20,000 history lines, warmed once (compinit)."""
    zdot = os.path.join(OUT, "zdotdir")
    if os.path.exists(os.path.join(zdot, ".zshrc")):
        return zdot, {}
    shutil.rmtree(zdot, ignore_errors=True)
    os.makedirs(zdot)
    info = {"ohmyzsh": clone("https://github.com/ohmyzsh/ohmyzsh.git", os.path.join(zdot, "ohmyzsh"))}
    info["autosuggestions"] = clone("https://github.com/zsh-users/zsh-autosuggestions.git",
                                    os.path.join(zdot, "ohmyzsh", "custom", "plugins", "zsh-autosuggestions"))
    for name in ("ohmyzsh", "ohmyzsh/custom/plugins/zsh-autosuggestions"):
        info[name + "_commit"] = subprocess.run(["git", "-C", os.path.join(zdot, name), "rev-parse", "HEAD"],
                                                capture_output=True, text=True).stdout.strip()
    with open(os.path.join(zdot, ".zshrc"), "w") as f:
        f.write(ZSHRC)
    words = ["git status", "git log --oneline -20", "cd ~/fun/cmux", "ls -la", "make", "cargo build", "rg TODO",
             "python3 scripts/cmux-next/bench.py", "gh pr view", "vim Package.swift", "bun run check", "ssh cmux-lawrence"]
    alphabet = hid_input.LETTERS * 8
    with open(os.path.join(zdot, ".zsh_history"), "w") as f:
        stamp = 1793000000
        for i in range(20000):
            f.write(f": {stamp + i}:0;{words[i % len(words)]} {i}\n")
        f.write(f": {stamp + 20001}:0;{alphabet[:200]}\n")  # the typed letters keep a suggestion on screen
    env = dict(os.environ, ZDOTDIR=zdot, FIRST5S_REPO=REPO)
    t0 = time.monotonic()
    warm = subprocess.run(["/bin/zsh", "-i", "-c", "exit"], env=env, capture_output=True, text=True, timeout=120)
    info["warm_zsh_s"] = round(time.monotonic() - t0, 3)
    info["warm_zsh_exit"] = warm.returncode
    t0 = time.monotonic()
    subprocess.run(["/bin/zsh", "-i", "-c", "exit"], env=env, capture_output=True, text=True, timeout=120)
    info["second_zsh_s"] = round(time.monotonic() - t0, 3)
    for path in glob.glob(os.path.join(zdot, "loaded.*")):
        os.remove(path)
    note(f"first5s: shell {json.dumps(info)}")
    return zdot, info


def shell_env(zdot):
    return {} if not zdot else {"ZDOTDIR": zdot, "FIRST5S_REPO": REPO, "SHELL": "/bin/zsh"}


def shells_loaded(zdot):
    return len(glob.glob(os.path.join(zdot, "loaded.*"))) if zdot else None


# ---------------------------------------------------------------- the photon recorder (ScreenCaptureKit)
def photon_binary():
    binary = os.path.join(OUT, "bin", "first5s-photon")
    if os.path.exists(binary):
        return binary, None
    os.makedirs(os.path.dirname(binary), exist_ok=True)
    try:
        build = subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-O", os.path.join(HERE, "first5s-photon.swift"),
                                "-o", binary], capture_output=True, text=True, timeout=600)
    except (OSError, subprocess.TimeoutExpired) as error:
        return None, f"first5s-photon did not compile: {error}"
    if build.returncode != 0:
        return None, f"first5s-photon did not compile: {build.stderr[-600:]}"
    return binary, None


class Photon:
    def __init__(self, pid, out):
        self.path, self.proc, self.error, self.ready = out, None, None, None
        if opts.no_photon:
            self.error = "off"
            return
        binary, self.error = photon_binary()
        if not binary:
            return
        self.proc = subprocess.Popen([binary, "--pid", str(pid), "--out", out, "--seconds", "3600"],
                                     stdout=subprocess.DEVNULL, stderr=open(out + ".err", "w"))
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            head = self._lines(2)
            if head and (head[0].startswith("ready") or head[0].startswith("error")):
                break
            if self.proc.poll() is not None:
                break
            time.sleep(0.2)
        head = self._lines(1)
        self.ready = head[0] if head else None
        if not self.ready or not self.ready.startswith("ready"):
            err = ""
            try:
                err = open(out + ".err").read()[-300:]
            except OSError:
                pass
            self.error = (self.ready or "no ready line") + " " + err
            self.stop()
        note(f"first5s: photon {self.ready or self.error}")

    def _lines(self, limit=None):
        try:
            with open(self.path) as f:
                lines = f.read().splitlines()
        except OSError:
            return []
        return lines[:limit] if limit else lines

    def frames(self, start_ns, end_ns):
        out = []
        for line in self._lines():
            parts = line.split()
            if len(parts) == 7 and parts[0] == "frame":
                ns = int(parts[1])
                if start_ns <= ns <= end_ns:
                    out.append([ns, int(parts[2]), int(parts[3]), int(parts[4]), int(parts[5]), int(parts[6])])
        return out

    def stop(self):
        if self.proc and self.proc.poll() is None:
            self.proc.terminate()  # the helper this bench started, by its PID
            try:
                self.proc.wait(10)
            except subprocess.TimeoutExpired:
                self.proc.kill()


def photon_ms(frames, key_ns, next_cap_ns, big_area):
    """The first changed frame after the key that is not a whole-window repaint (the echo), ms after the key."""
    for ns, changed, _x, _y, w, h in frames:
        if ns > key_ns and w * h < big_area:
            return round((ns - key_ns) / 1e6, 2)
        if ns > next_cap_ns:
            break
    return None


# ---------------------------------------------------------------- the two app families
class NextApp:
    family = "next"
    enable_features = ""
    commit_probe = False
    page_target = False

    def __init__(self, app, zdot, out):
        self.app, self.out = app, out
        self.probe = os.path.join(out, "typing-probe.csv")
        env = {"CMUX_NEXT_TYPING_PROBE": self.probe, "CMUX_NEXT_HANG_THRESHOLD_MS": str(opts.hang_ms),
               **shipping_env(draw=False), **shell_env(zdot)}
        if self.enable_features:
            env["CMUX_ENABLE_FEATURES"] = self.enable_features
        self.bench = BenchApp(app, out=out, config={"browser": {"defaultEngine": "chromium"}}, window=(40, 40, 1400, 900),
                              log_name="app-first5s.log", env=env)
        with open(os.path.join(self.bench.scratch, "ghostty"), "w") as f:
            f.write("cursor-style-blink = false\n")
        self.control = hid_input.Control("", os.path.join(app, "Contents/Resources/bin/cmux"), None)

    def launch(self):
        self.bench.launch(timeout=180)
        self.control.socket_path = self.bench.socket
        self.control.config = os.path.join(self.bench.scratch, "cmux.json")
        time.sleep(6)
        note(f"first5s: activate {self.bench.activate()}")
        self.pid = self.bench.process.pid
        reply = self.control.action("newSurface", focus=True)  # the base terminal, from Home's dock
        note(f"first5s: base terminal {json.dumps(reply)[:160]}")
        time.sleep(4)

    def key(self, name, modifiers=(), stamp=None):
        params = {"key": name, "timestamp": stamp if stamp is not None else hid_input.uptime_raw()}
        if modifiers:
            params["modifiers"] = list(modifiers)
        return self.control.rpc("debug.key", params, timeout=20)

    def play(self, name, modifiers, typed):
        """The open shortcut, then a letter every --interval, all on ONE control connection: each `debug.key` line
        is written at its scheduled time and stamped with the time it really left (the client's CLOCK_UPTIME_RAW, the probe's clock),
        and a reader thread takes the replies, so no key waits for an earlier reply or a new connection. The
        server runs a connection's requests in order as input (MainActorWorkQueue.drainInput), so a key that waits
        for a busy main thread or a held key counts that wait, as a person's key queued in the window server does.
        (A connection per key measured the server's accept and connection setup: a 0-150 ms sawtooth on every key.
        `debug.key {sequence}` refuses on hosts whose CGEvent has no timestamp.)"""
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(60)
        conn.connect(self.control.socket_path)
        replies, buf = [], b""
        total = 1 + len(typed)

        def reader():
            nonlocal buf
            while len(replies) < total:
                try:
                    chunk = conn.recv(1 << 20)
                except OSError:
                    return
                if not chunk:
                    return
                buf += chunk
                while b"\n" in buf:
                    line, buf = buf.split(b"\n", 1)
                    try:
                        replies.append(json.loads(line))
                    except ValueError:
                        replies.append({"raw": line[:200].decode(errors="replace")})
        thread = threading.Thread(target=reader, daemon=True)
        thread.start()
        sent = [{} for _ in typed]

        def send(rid, key, mods, when):
            params = {"key": key, "timestamp": when / 1e9}
            if rid > 0 and self.commit_probe:  # a key into a text field or page: the probe row closes at its commit
                params["probe"] = "commit"
            if rid > 0 and self.page_target:
                # The New Tab page is a Chromium page window, the key window while its field has the keyboard: a
                # person's key goes there. Without `target: page` debug.key sends it to the shell window, which
                # neither the page nor the app's tracker sees (no row, no slot).
                params["target"] = "page"
            if mods:
                params["modifiers"] = list(mods)
            conn.sendall((json.dumps({"id": rid, "method": "debug.key", "params": params}) + "\n").encode())
        # Each key goes when its time comes and is stamped with the time it really left (paced_send).
        open_ns = NOW_NS()
        send(0, name, modifiers, open_ns)
        late = paced_send(open_ns, len(typed), int(opts.interval * 1e9), lambda k, at: send(k, typed[k - 1], (), at))
        for k, ms in enumerate(late):
            sent[k]["send_late_ms"] = ms
        thread.join(30)
        try:
            conn.close()
        except OSError:
            pass
        first = next((r for r in replies if r.get("id") == 0), {})
        reply = first.get("result") if first.get("ok") else first
        return sent, reply, open_ns

    def close(self, scenario):
        self.control.action("closeTab")

    def clear_line(self):
        self.key("u", ["control"])

    def hangs_clear(self):
        self.control.rpc("debug.hangs", {"clear": True}, timeout=20)
        self.control.rpc("debug.input", {"action": "reset"}, timeout=20)

    def tracker_slots(self):
        """The app's own key latency tracker: one row per closed key since the reset (kind, target, total_ms,
        stages_ms; dispatch_start is the event -> dispatch wait)."""
        reply = self.control.rpc("debug.input", {"action": "slots"}, timeout=30) or {}
        return reply.get("slots") if isinstance(reply, dict) else None

    def journal_mark(self, marker):
        self.control.rpc("debug.journal", {"marker": marker, "last": 1}, timeout=20)

    def journal_since(self, marker, limit=400):
        """The input journal after `marker` (ms from it): focus, responder, holds, content events."""
        out = []
        got = self.control.rpc("debug.journal", {"last": 4000}, timeout=30) or {}
        entries = got.get("entries") or [] if isinstance(got, dict) else []
        start = next((i for i, e in enumerate(entries) if marker in json.dumps(e.get("kind"))), None)
        if start is None:
            return [{"ms": None, "kind": f"marker not found in {len(entries)} entries"}]
        base_ns = entries[start].get("uptimeNanos") or 0
        for e in entries[start + 1:]:
            kind = json.dumps(e.get("kind"), separators=(",", ":"))
            if "debug.focus" in kind or '"resize:' in kind or "debug.journal" in kind:
                continue
            out.append({"ms": round(((e.get("uptimeNanos") or 0) - base_ns) / 1e6, 2), "kind": kind[:240]})
        return out[:limit]

    def hangs(self, start_ns, end_ns):
        reply = self.control.rpc("debug.hangs", {}, timeout=30) or {}
        if not isinstance(reply, dict) or reply.get("error"):
            return {"error": reply}
        out = {k: reply.get(k) for k in ("threshold_ms", "count", "max_ms", "total_ms", "long_frames", "frames_over_8_3ms",
                                         "max_gap_ms", "count100", "count250")}
        keep = []
        for kind in ("records", "over_budget", "task_hangs"):
            for r in reply.get(kind) or []:
                ns = r.get("start_uptime_ns") or 0
                if start_ns - 50e6 <= ns <= end_ns:
                    item = {"list": kind, "at_ms": round((ns - start_ns) / 1e6, 1), "ms": round(r.get("duration_ms") or 0, 1),
                            "cpu_ms": round(r.get("cpu_ms") or 0, 1),
                            "frames": [f for f in (r.get("frames") or []) if "cmux" in f or "Cmux" in f][:28] or (r.get("frames") or [])[:28]}
                    for k, v in r.items():
                        if k not in ("frames", "frame_details", "start_uptime_ns", "duration_ms", "cpu_ms", "sequence") and not isinstance(v, (list, dict)):
                            item[k] = v
                        elif k in ("task", "details", "owner") and isinstance(v, dict):
                            item[k] = v
                    keep.append(item)
        keep.sort(key=lambda h: h["at_ms"])
        out["window"] = keep
        return out

    def probe_rows(self):
        return hid_input.probe_rows(self.probe)

    def line(self):
        found = []

        def walk(node):
            if isinstance(node, dict):
                if node.get("focused") is True and isinstance(node.get("text"), str):
                    found.append(node["text"])
                for value in node.values():
                    walk(value)
            elif isinstance(node, list):
                for value in node:
                    walk(value)
        walk(self.control.rpc("debug.surfaces", {"text": True}, timeout=20))
        lines = [l for l in (found[-1] if found else "").splitlines() if l.strip()]
        return lines[-1] if lines else ""

    def stop(self):
        self.bench.stop()


class ClassicApp:
    """Classic cmux (Sources/, main): its DEV socket's simulate_shortcut keys (keyDown through NSApp.sendEvent)."""
    family = "classic"

    def __init__(self, app, zdot, out):
        self.app, self.out, self.zdot = app, out, zdot
        self.scratch = os.path.join(out, "classic-home")
        os.makedirs(os.path.join(self.scratch, "xdg", "ghostty"), exist_ok=True)
        with open(os.path.join(self.scratch, "xdg", "ghostty", "config"), "w") as f:
            f.write("cursor-style-blink = false\nwindow-width = 175\nwindow-height = 56\n")
        self.process, self.sock = None, None
        tag = os.path.basename(app).removesuffix(".app").removeprefix("cmux DEV").strip() or "classic"
        self.tag = tag

    def launch(self):
        env = {k: v for k, v in os.environ.items() if not k.startswith("CMUX")}
        self.log = os.path.join(self.out, "classic-debug.log")
        env.update({"CMUX_SOCKET_MODE": "allowAll", "CMUX_SOCKET_ENABLE": "1", "CMUX_KEY_LATENCY_PROBE": "1",
                    "CMUX_DEBUG_LOG": self.log, "CMUX_TAG": self.tag, "XDG_CONFIG_HOME": os.path.join(self.scratch, "xdg"),
                    **shell_env(self.zdot)})
        before = set(self._sockets())
        log = open(os.path.join(self.out, "app-classic.log"), "w")
        self.process = subprocess.Popen([main_binary(self.app)], env=env, stdout=log, stderr=log, stdin=subprocess.DEVNULL,
                                        start_new_session=True)
        self.pid = self.process.pid
        deadline = time.monotonic() + 120
        while time.monotonic() < deadline and not self.sock:
            for path in [p for p in self._sockets() if p not in before] + [p for p in self._sockets() if self.tag.replace("-", "") in p.replace("-", "")]:
                if self._send(path, "ping", timeout=2).startswith("PONG"):
                    self.sock = path
                    break
            time.sleep(0.5)
        if not self.sock:
            raise LaunchError("classic: no socket answered ping", {"sockets": self._sockets()})
        note(f"first5s: classic socket {self.sock}")
        time.sleep(6)
        if self.process.poll() is not None or not self._send(self.sock, "ping", timeout=3).startswith("PONG"):
            tail = ""
            try:
                text = open(os.path.join(self.out, "app-classic.log"), errors="replace").read()
                hits = [l for l in text.splitlines() if re.search(r"(?i)fatal|precondition|assert|terminat|exception|crash|trap|_exit|another instance", l)
                        and "Breadcrumb" not in l]
                tail = "\n".join(hits[-40:])
            except OSError:
                pass
            dbg = ""
            try:
                dbg = open(self.log).read()[-2000:]
            except OSError:
                pass
            crash = ""
            time.sleep(5)  # ReportCrash writes the report a few seconds after the exit
            reports = sorted(glob.glob(os.path.expanduser("~/Library/Logs/DiagnosticReports/*cmux*"))
                             + glob.glob(os.path.expanduser("~/Library/Logs/DiagnosticReports/*/*cmux*")), key=os.path.getmtime)
            if reports and time.time() - os.path.getmtime(reports[-1]) < 300:
                try:
                    text = open(reports[-1]).read()
                    crash = reports[-1] + "\n" + text[:6000]
                except OSError:
                    pass
            note(f"first5s: classic DIED after its socket answered: exit {self.process.poll()}\n--- app log tail\n{tail}\n--- debug log tail\n{dbg}\n--- crash report\n{crash}")
            raise LaunchError("classic: the app stopped answering 6 s after launch", {"exit": self.process.poll()})
        hid_input.bring_front(self.pid)
        note(f"first5s: classic activate {self._send(self.sock, 'activate_app')}")
        time.sleep(4)

    @staticmethod
    def _sockets():
        found = glob.glob("/tmp/cmux*.sock") + glob.glob(os.path.join(os.environ.get("TMPDIR", "/tmp"), "cmux*.sock"))
        found += glob.glob(os.path.expanduser("~/Library/Application Support/cmux/*.sock"))
        found += glob.glob(os.path.expanduser("~/.local/state/cmux/*.sock"))
        return sorted(set(found))

    @staticmethod
    def _send(path, line, timeout=20):
        try:
            conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            conn.settimeout(timeout)
            conn.connect(path)
            conn.sendall((line + "\n").encode())
            buf = b""
            while not buf.endswith(b"\n"):
                chunk = conn.recv(65536)
                if not chunk:
                    break
                buf += chunk
            conn.close()
            return buf.decode(errors="replace").strip()
        except OSError as error:
            return f"ERROR {error}"

    def key(self, name, modifiers=(), stamp=None):
        combo = "+".join([{"command": "cmd", "control": "ctrl", "option": "opt", "shift": "shift"}[m] for m in modifiers] + [name])
        return self._send(self.sock, f"simulate_shortcut {combo}")

    def play(self, name, modifiers, typed):
        """simulate_shortcut per key from this script on schedule; the app's key latency probe (CMUX_KEY_LATENCY_PROBE)
        logs each keyDown's delay from the request's arrival to its dispatch."""
        before = self._log_lines()
        open_ns = NOW_NS()
        reply = self.key(name, modifiers)
        late = paced_send(open_ns, len(typed), int(opts.interval * 1e9), lambda k, _at: self.key(typed[k - 1]))
        time.sleep(0.5)
        delays = []
        for line in self._log_lines()[len(before):]:
            m = re.search(r"typing\.delay probe=keyDown delayMs=([\d.]+)", line)
            if m:
                delays.append(float(m.group(1)))
        delays = delays[-len(typed):]
        sent = [{"delay_ms": None} for _ in range(len(typed) - len(delays))] + [{"delay_ms": d} for d in delays]
        for k, ms in enumerate(late):
            sent[k]["send_late_ms"] = ms
        return sent, reply, open_ns

    def _log_lines(self):
        try:
            with open(self.log) as f:
                return f.read().splitlines()
        except OSError:
            return []

    def close(self, scenario):
        self.key("w", ["command"])

    def clear_line(self):
        self.key("u", ["control"])

    def hangs_clear(self):
        pass

    def tracker_slots(self):
        return None

    def journal_mark(self, marker):
        pass

    def journal_since(self, marker, limit=400):
        return None

    def hangs(self, start_ns, end_ns):
        return None

    def probe_rows(self):
        return []

    def line(self):
        text = self._send(self.sock, "read_screen")
        lines = [l for l in text.splitlines() if l.strip()]
        return lines[-1] if lines else text[:120]

    def stop(self):
        if self.process and self.process.poll() is None:
            self._send(self.sock or "", "simulate_shortcut cmd+q", timeout=5)
            try:
                self.process.wait(15)
            except subprocess.TimeoutExpired:
                self.process.terminate()  # the PID this bench started
                try:
                    self.process.wait(10)
                except subprocess.TimeoutExpired:
                    self.process.kill()


# ---------------------------------------------------------------- one round
def sample_main_thread(pid, seconds, path):
    try:
        return subprocess.Popen(["/usr/bin/sample", str(pid), str(int(seconds) + 1), "1", "-mayDie", "-file", path],
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except OSError:
        return None


def main_thread_tree(path, min_share=0.02, limit=260):
    """The main thread's call tree of a `sample` report, the lines with at least `min_share` of its samples."""
    try:
        text = open(path).read()
    except OSError:
        return None
    lines = text.splitlines()
    start = next((i for i, l in enumerate(lines) if "com.apple.main-thread" in l or re.match(r"\s+\d+ Thread_\d+\s+DispatchQueue_1", l)), None)
    if start is None:
        return {"error": "no main thread in the sample", "head": lines[:20]}
    total = int(re.match(r"\s*(\d+)", lines[start]).group(1))
    indent = len(lines[start]) - len(lines[start].lstrip())
    out = [lines[start].strip()]
    for line in lines[start + 1:]:
        stripped = line.lstrip(" +!:|")
        if re.match(r"\s{%d}\d+ Thread_" % indent, line) or not line.strip():
            break
        m = re.match(r"(\d+) ", stripped)
        if m and int(m.group(1)) >= total * min_share:
            out.append(line.rstrip()[:240])
        if len(out) >= limit:
            break
    return {"samples": total, "tree": out}


def run_round(app, scenario, index, sampled):
    name, modifiers = (CLASSIC_OPEN_KEYS if app.family == "classic" else OPEN_KEYS)[scenario]
    app.commit_probe = scenario in ("newtab", "browser")
    app.page_target = scenario == "newtab"
    nkeys = int(round(opts.seconds / opts.interval))
    rows_before = app.probe_rows()
    base = max([int(r["index"]) for r in rows_before if (r.get("index") or "").isdigit()], default=-1)
    app.hangs_clear()
    marker = f"first5s-{scenario}-{index}-{time.time_ns()}"
    try:
        app.journal_mark(marker)
    except Exception:  # an app without the journal: the round still runs
        pass
    sampler = sample_main_thread(app.pid, opts.seconds + 0.5, os.path.join(app.out, f"sample-{scenario}-{index}.txt")) if sampled else None
    if sampler:
        time.sleep(0.6)  # sample attaches before the open key
    typed = "".join(hid_input.LETTERS[i % 26] for i in range(nkeys))
    sent, open_reply, open_ns = app.play(name, modifiers, typed)
    open_reply_ms = round((NOW_NS() - open_ns) / 1e6, 1)
    schedule = [open_ns + int((k + 1) * opts.interval * 1e9) for k in range(nkeys)]
    rest = (schedule[-1] - NOW_NS()) / 1e9
    if rest > 0:
        time.sleep(rest)
    time.sleep(opts.settle)
    end_ns = NOW_NS()
    line = app.line()
    hangs = app.hangs(open_ns, end_ns)
    try:
        slots = app.tracker_slots()
    except Exception as error:
        slots = {"error": repr(error)}
    try:
        journal = app.journal_since(marker)
    except Exception as error:
        journal = [{"ms": None, "kind": repr(error)}]
    if sampler:
        try:
            sampler.wait(15)
        except subprocess.TimeoutExpired:
            sampler.kill()
    rows = [r for r in app.probe_rows() if (r.get("index") or "").isdigit() and int(r["index"]) > base]
    by_index = {int(r["index"]): r for r in rows}
    indices = sorted(by_index)
    letter_indices = indices[-nkeys:] if len(indices) >= nkeys else indices
    offset = nkeys - len(letter_indices)
    keys = []
    for k in range(nkeys):
        row = by_index.get(letter_indices[k - offset]) if k >= offset else None
        def col(c, row=row):
            v = (row or {}).get(c)
            try:
                return round(float(v), 2) if v not in (None, "") else None
            except ValueError:
                return None
        latency = col("contents_ms") if col("contents_ms") is not None else col("commit_ms")
        keys.append({"k": k, "t_ms": round((schedule[k] - open_ns) / 1e6, 1), "probe_ms": latency,
                     "complete": (row or {}).get("complete"), "dispatch_end_ms": col("dispatch_end_ms"), "io_write_ms": col("io_write_ms"),
                     "output_received_ms": col("output_received_ms"), "contents_ms": col("contents_ms"), "commit_ms": col("commit_ms"),
                     "dispatch_start_ms": col("dispatch_start_ms"),
                     "delay_ms": sent[k].get("delay_ms") if k < len(sent) else None,
                     "send_late_ms": sent[k].get("send_late_ms") if k < len(sent) else None})
    frames = app.photon.frames(open_ns - int(0.2e9), end_ns) if app.photon and not app.photon.error else []
    big = (app.photon_area or 10 ** 12) * 0.25
    for k, key in enumerate(keys):
        cap = schedule[k] + int(2e9)
        key["photon_ms"] = photon_ms(frames, schedule[k], cap, big) if frames else None
    first_big = next(((ns - open_ns) / 1e6 for ns, _c, _x, _y, w, h in frames if ns > open_ns and w * h >= big), None)
    first_any = next(((ns - open_ns) / 1e6 for ns, *_ in frames if ns > open_ns), None)
    ok = line.rstrip().endswith(typed[-12:])
    rec = {"scenario": scenario, "round": index, "sampled": sampled, "open_reply_ms": open_reply_ms, "open_ns": open_ns,
           "open_reply": json.dumps(open_reply)[:200], "line": line[-140:], "all_keys_on_screen": ok,
           "shells_loaded": shells_loaded(app.zdot), "probe_rows": len(rows), "keys": keys, "hangs": hangs,
           "first_frame_ms": round(first_any, 1) if first_any is not None else None,
           "first_big_frame_ms": round(first_big, 1) if first_big is not None else None,
           "frames": frames, "journal": journal, "tracker_slots": slots}
    if sampled:
        rec["sample"] = main_thread_tree(os.path.join(app.out, f"sample-{scenario}-{index}.txt"), min_share=0.01, limit=400)
        tree = (rec["sample"] or {}).get("tree") or []
        note(f"      SAMPLE {scenario}: {(rec['sample'] or {}).get('samples')} main-thread samples; {len(tree)} lines over 1%")
        for line in tree[:120]:
            note(f"      S {line}")
    probe = [k["probe_ms"] for k in keys if k["probe_ms"] is not None]
    photon = [k["photon_ms"] for k in keys if k["photon_ms"] is not None]
    note(f"  {scenario} {index}{' (sampled)' if sampled else ''}: open reply {open_reply_ms} ms, probe rows {len(rows)}, "
         f"{'ok' if ok else 'LINE ' + repr(line[-50:])}; probe max {max(probe) if probe else None} photon max "
         f"{max(photon) if photon else None}; first frame {rec['first_frame_ms']} big {rec['first_big_frame_ms']}; "
         f"hangs {len((hangs or {}).get('window') or []) if isinstance(hangs, dict) else None}")
    if index == 0 and journal:
        for item in journal[:70]:
            note(f"      J {item['ms']} {item['kind'][:200]}")
    for h in ((hangs or {}).get("window") or [])[:12] if isinstance(hangs, dict) else []:
        note(f"      hang +{h['at_ms']} ms {h['ms']} ms cpu {h['cpu_ms']} [{h['list']}] {h.get('task') or h.get('name') or ''} "
             f"{' < '.join(f[:150] for f in h['frames'][:5])}")
    # Back to the base terminal.
    if scenario == "browser":
        app.key("escape")
    else:
        app.clear_line()
    time.sleep(0.3)
    app.close(scenario)
    time.sleep(opts.gap)
    return rec


def buckets(rounds, field):
    width = opts.bucket_ms
    edges = int(opts.seconds * 1000 // width) + 1
    out = []
    for b in range(edges):
        vals = [k[field] for r in rounds if not r["sampled"] for k in r["keys"]
                if k.get(field) is not None and b * width <= k["t_ms"] < (b + 1) * width]
        d = typing_report.distribution(vals, mean=False)
        out.append({"from_ms": int(b * width), "to_ms": int((b + 1) * width), **(d or {"n": 0})})
    return out


def held(rounds, limit_ms=100):
    """Per bucket: keys whose dispatch started more than `limit_ms` after the key (the tracker's dispatchStart: the
    typing probe's dispatch_start_ms, classic's typing.delay), and keys measured."""
    width = opts.bucket_ms
    edges = int(opts.seconds * 1000 // width) + 1
    out = []
    for b in range(edges):
        vals = [k.get("dispatch_start_ms") if k.get("dispatch_start_ms") is not None else k.get("delay_ms")
                for r in rounds if not r["sampled"] for k in r["keys"] if b * width <= k["t_ms"] < (b + 1) * width]
        vals = [v for v in vals if v is not None]
        out.append({"from_ms": int(b * width), "keys": len(vals), "over_100ms": sum(v > limit_ms for v in vals),
                    "over_16_7ms": sum(v > 16.7 for v in vals)})
    return out


def hops(rounds):
    width = opts.bucket_ms
    edges = int(opts.seconds * 1000 // width) + 1
    out = []
    for b in range(edges):
        row = {"from_ms": int(b * width)}
        for h in ("delay_ms", "dispatch_end_ms", "io_write_ms", "output_received_ms", "contents_ms"):
            vals = [k[h] for r in rounds if not r["sampled"] for k in r["keys"] if k.get(h) is not None and b * width <= k["t_ms"] < (b + 1) * width]
            row[h] = round(statistics.median(vals), 2) if vals else None
        out.append(row)
    return out


def measure(app_path, zdot, result, family, features=""):
    out = os.path.join(OUT, os.path.basename(app_path).replace(" ", "_").removesuffix(".app") + (f"-on{len(result['apps'])}" if features else ""))
    os.makedirs(out, exist_ok=True)
    NextApp.enable_features = features
    app = (NextApp if family == "next" else ClassicApp)(app_path, zdot, out)
    app.zdot = zdot
    label = os.path.basename(app_path) + (" +felt" if features else "")
    entry = {"app": label, "family": family, "enable_features": features, "scenarios": {}}
    result["apps"].append(entry)
    note(f"=== {entry['app']} ({family})")
    try:
        try:
            app.launch()
        except LaunchError as error:
            entry["launch_failure"] = str(getattr(error, "reason", None) or error)
            note(f"first5s: launch failed {entry['launch_failure']}")
            return
        app.photon = Photon(app.pid, os.path.join(out, "photon.txt"))
        app.photon_area = None
        if not app.photon.error and app.photon.ready:
            m = re.search(r"(\d+)x(\d+)", app.photon.ready)
            app.photon_area = int(m.group(1)) * int(m.group(2)) if m else None
        entry["photon"] = app.photon.ready or app.photon.error
        entry["shells_loaded_at_start"] = shells_loaded(zdot)
        for scenario in SCENARIOS:
            if family == "classic" and scenario not in CLASSIC_OPEN_KEYS:
                continue
            rounds = []
            for index in range(opts.rounds + opts.sample_rounds):
                rounds.append(run_round(app, scenario, index, sampled=index >= opts.rounds))
                save(result)
            entry["scenarios"][scenario] = {"rounds": rounds, "probe_buckets": buckets(rounds, "probe_ms"),
                                            "delay_buckets": buckets(rounds, "delay_ms"),
                                            "held": held(rounds),
                                            "dispatch_buckets": buckets(rounds, "dispatch_end_ms"),
                                            "photon_buckets": buckets(rounds, "photon_ms"), "hops": hops(rounds)}
            print_table(entry["app"], scenario, entry["scenarios"][scenario])
            print_dispatch(entry["app"], scenario, entry["scenarios"][scenario])
            entry["scenarios"][scenario]["sender"] = print_send_late(entry["app"], scenario, rounds)
            tb, targets = tracker_buckets(rounds)
            entry["scenarios"][scenario]["tracker_buckets"] = tb
            note(f"FIRST5S-TRACKER {entry['app']} {scenario}: the app's key tracker, targets {targets}; per bucket total and dispatch_start n/p50/p95/max")
            for row in tb:
                tt, ds = row["total"], row["dispatch_start"]
                note(f"   {row['from_ms']:5d}  total {tt.get('n', 0):3d} {tt.get('p50', '-')} {tt.get('p95', '-')} {tt.get('max', '-')}"
                     f"   dispatch_start {ds.get('n', 0):3d} {ds.get('p50', '-')} {ds.get('p95', '-')} {ds.get('max', '-')}")
            save(result)
    finally:
        if getattr(app, "photon", None):
            app.photon.stop()
        app.stop()
        save(result)


def print_table(name, scenario, data):
    note(f"FIRST5S {name} {scenario}: per {int(opts.bucket_ms)} ms after the open key, key-to-frame ms")
    note("   bucket      probe n/p50/p95/max            photon n/p50/p95/max          hops (median): classic-delay dispatch write echo frame")
    for p, f, h in zip(data["probe_buckets"], data["photon_buckets"], data["hops"]):
        def cell(d):
            return f"{d.get('n', 0):3d} {d.get('p50', '-'):>7} {d.get('p95', '-'):>7} {d.get('max', '-'):>7}" if d.get("n") else "  0       -       -       -"
        note(f"   {p['from_ms']:5d}-{p['to_ms']:<5d} {cell(p)}    {cell(f)}    {h['delay_ms']} {h['dispatch_end_ms']} {h['io_write_ms']} "
             f"{h['output_received_ms']} {h['contents_ms']}")


def tracker_buckets(rounds):
    """The tracker's key slots per 500 ms after the open (its generated_ns against the open key's): total_ms and
    dispatch_start, p50/p95/max, and the target the tracker named."""
    width = opts.bucket_ms
    edges = int(opts.seconds * 1000 // width) + 1
    rows = [[] for _ in range(edges)]
    targets = {}
    for r in rounds:
        if r["sampled"] or not isinstance(r.get("tracker_slots"), list):
            continue
        open_ns = r.get("open_ns")
        for slot in r["tracker_slots"]:
            if slot.get("kind") != "keyPress" or open_ns is None:
                continue
            t = (int(slot.get("generated_ns") or 0) - open_ns) / 1e6
            b = int(t // width)
            if 0 <= b < edges and t >= 1:
                rows[b].append(slot)
                targets[slot.get("target")] = targets.get(slot.get("target"), 0) + 1
    out = []
    for b, slots in enumerate(rows):
        total = typing_report.distribution([s.get("total_ms") for s in slots], mean=False) or {"n": 0}
        start = typing_report.distribution([(s.get("stages_ms") or {}).get("dispatchStart") for s in slots], mean=False) or {"n": 0}
        out.append({"from_ms": int(b * width), "total": total, "dispatch_start": start})
    return out, targets


def print_send_late(name, scenario, rounds):
    """How late the keys left their plan; the scenario's numbers are valid only when no key left over 1 ms late."""
    vals = [k["send_late_ms"] for r in rounds for k in r["keys"] if k.get("send_late_ms") is not None]
    late = typing_report.distribution(vals, mean=False)
    valid = bool(vals) and max(vals) <= SENDER_VALID_MS
    # Classic keys wait for each reply (simulate_shortcut), so there lateness includes the app's reply time.
    note(f"FIRST5S-SENDER {name} {scenario}: key sent after its planned time, ms {late}"
         f"{'' if valid else f' NOT VALID (a key left over {SENDER_VALID_MS} ms late)'}")
    return {"late_ms": late, "sender_valid": valid}


def print_dispatch(name, scenario, data):
    note(f"FIRST5S-DISPATCH {name} {scenario}: key press to its dispatch in the app (main-thread wait), per bucket n/p50/p95/max")
    for d, c, h in zip(data["dispatch_buckets"], data["delay_buckets"], data["held"]):
        def cell(x):
            return f"{x.get('n', 0):3d} {x.get('p50', '-'):>7} {x.get('p95', '-'):>7} {x.get('max', '-'):>7}" if x.get("n") else "  0       -       -       -"
        note(f"   {d['from_ms']:5d}-{d['to_ms']:<5d} next {cell(d)}    classic {cell(c)}    dispatchStart>100ms {h['over_100ms']}/{h['keys']}")


def save(result):
    if opts.json:
        with open(opts.json, "w") as f:
            json.dump(result, f, indent=1)


def main():
    if opts.self_check:
        check = self_check(interval=opts.interval)
        if opts.json:
            with open(opts.json, "w") as f:
                json.dump({"bench": "first-5s-typing", "self_check": check}, f, indent=1)
        return 0 if check["ok"] else 1
    result = {"bench": "first-5s-typing", "host": os.uname().nodename, "opts": vars(opts), "apps": [],
              "home_is_account_home": os.path.realpath(os.environ.get("HOME", "")) == os.path.realpath(account_home())}
    # The sender's check on this host first (2 s): a host whose spin cannot keep 1 ms gives no valid run.
    result["sender_self_check"] = self_check(seconds=2.0, interval=opts.interval)
    if not result["sender_self_check"]["ok"]:
        note("first5s: NOT VALID: the sender's self-check failed on this host (FIRST5S-SELFCHECK above)")
    result["valid"] = result["sender_self_check"]["ok"]
    zdot = None
    if not opts.no_shell:
        try:
            zdot, result["shell"] = shell_setup()
        except (OSError, subprocess.SubprocessError) as error:
            result["shell"] = {"error": repr(error)}
            note(f"first5s: shell setup failed ({error!r}); the host's shell config")
    apps = []
    if opts.app and not opts.apps_sha256:
        apps.append(os.path.abspath(opts.app.rstrip("/")))
    for sha in [s for s in opts.apps_sha256.split(",") if s]:
        got = subprocess.run([sys.executable, os.path.join(HERE, "fleet-app-fetch.py"), "--sha256", sha, "--dest",
                              os.path.join(OUT, "apps", sha[:12])], capture_output=True, text=True)
        if got.returncode != 0:
            result["apps"].append({"sha256": sha, "fetch_error": got.stderr[-400:]})
            continue
        apps.append(got.stdout.strip().splitlines()[-1])
    families = [f for f in opts.families.split(",") if f]
    features = opts.features.split("/") if opts.features else []
    for i, app in enumerate(apps):
        measure(app, zdot, result, families[i] if i < len(families) else "next", features[i] if i < len(features) else "")
    save(result)
    return 0


if __name__ == "__main__":
    sys.exit(main())
