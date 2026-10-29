#!/usr/bin/env python3
"""Seeded UI fuzzer and feature tour for cmux-next inside a macOS VM.

Runs on the VM host. Input goes through the VM's VNC server (rfb.py), so the
guest needs no Accessibility grant. App actions marked for the CLI run through
the guest's bundled `cmux` over SSH; GUI-only actions run by their shortcut or
by typing their title into the Cmd+Shift+P palette. Every step is logged to
steps.jsonl; `--replay steps.jsonl` repeats a run step for step.

The plan comes from the build's own action schema (`cmux action list --json`), the way
ClusterFuzz's structure-aware fuzzers draw inputs from a grammar (Chromium
testing/libfuzzer/libprotobuf-mutator.md): every argument gets a value of its declared kind
(enum choices, ints at and inside their min/max, target-kind arguments resolved against the
live object lists at run time). The run has three parts: the feature tour, a coverage pass
that runs every eligible action once (seeded order, valid arguments), then the seeded random
walk. The same seed and the same build give the same steps. --minutes bounds the whole run;
--coverage-minutes bounds the tour and coverage pass inside it. summary.json reports each
action's runs and outcomes, `actions_eligible`, `actions_covered` (a run reached the handler:
not refused with a code in REFUSALS), `actions_refused` and why each other action was left
out. `--plan-only` writes the plan from a saved `action list --json` with no VM, to check a
plan offline.

After every step it pings the app (a hang is a ping over --hang-ms) and checks
for new crash reports. On a hang it samples the main thread; on a crash it
copies the .ips, takes a VNC screenshot and relaunches the app. On a build that
checks its invariants (a Debug or armed bench build: plans/cmux-next/invariants-DESIGN.md)
it also reads the app's invariant ledger after every step (scripts/journeys/invariants.py,
a full check): each new violation is an `invariant` finding, and the run exits 1. A build
that does not check (Release) is recorded as `invariants: not run`, never as clean.

With --diag NAME (diag.py: gmalloc, scribble, probguard, mtc, coop-strict, asan, tsan, ubsan) the
app runs under that check; summary.json's "diag" records the launch environment, the Chromium
state, the app's malloc zones and the reports the check wrote.

Example (vm.sh does this for you):
  fuzz.py --ssh admin@192.168.64.5 --vnc 127.0.0.1:5901:secret \
          --app "/Applications/cmux NIGHTLY.app" --seed 7 --steps 2000 --out out/15
"""

from __future__ import annotations

import argparse
import hashlib
import itertools
import json
import os
import random
import shlex
import subprocess
import sys
import time
from typing import Callable, Iterator

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
# The journeys' invariant cursor: the same contract as every journey step (scripts/journeys/invariants.py).
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "journeys"))
import diag  # noqa: E402
import invariants  # noqa: E402
from rfb import RFB  # noqa: E402

# Shortcuts the user named, sent as real keys whatever the action table says.
NAMED_KEYS = (
    [f"cmd+{i}" for i in range(1, 10)] + [f"ctrl+{i}" for i in range(1, 10)]
    + ["cmd+d", "cmd+shift+d", "cmd+w", "cmd+t", "cmd+n", "cmd+p", "cmd+shift+p",
       "cmd+,", "cmd+shift+[", "cmd+shift+]", "ctrl+cmd+[", "ctrl+cmd+]", "cmd+[", "cmd+]",
       "cmd+k", "cmd+f", "cmd+l", "cmd+shift+l", "cmd+r", "cmd+z", "cmd+shift+z",
       "cmd+=", "cmd+-", "cmd+0", "cmd+opt+left", "cmd+opt+right", "cmd+opt+up", "cmd+opt+down",
       "esc", "return", "tab", "shift+tab", "up", "down", "left", "right", "cmd+a", "cmd+c", "cmd+v"]
)
TOUR = [  # scripted feature tour run before the random walk (palette titles)
    "Settings…", "New Workspace", "Split Right", "Split Down", "New Browser Tab", "Home",
    "Toggle Sidebar", "New Tab", "Window Style", "Wallpaper", "Check for Updates", "What's New",
    "Extensions", "Markdown", "New Workspace Group", "Close Tab",
]
SKIP_WORDS = ("quit", "update", "uninstall", "restartsocket", "signout", "logout", "relaunch",
              "terminate", "cloud", "firewall", "snapshot", "billing", "purchase", "subscribe",
              # Opens the system's "change your default web browser" dialog, which no app input
              # answers; its handler then waits for ever (seen on macOS 15).
              "defaultbrowser")
TEXT = ["hello", "ls -la\n", "echo $((RANDOM))\n", "https://example.com\n", "# Title\n", "🙂 ünïcødé",
        "x" * 300, "\n\n", "printf '\\e[31mred\\n'\n", "yes | head -2000\n"]


class Guest:
    """The VM over one multiplexed SSH connection; the app's CLI runs in the guest."""

    def __init__(self, target: str, app: str, ssh_opts: list[str]):
        self.target, self.app = target, app
        self.cli = f"{app}/Contents/Resources/bin/cmux"
        self.binary = ""
        self.env = "CMUX_NEXT_SOCKET_MODE=automation"
        # A diag's factor on launch and ping deadlines (diag.Diag.slowdown).
        self.slowdown = 1
        self.launch_failure = ""
        self.socket = ""
        self.ctl = f"/tmp/fuzz-ssh-{os.getpid()}"
        self.base = ["ssh", "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
                     "-o", "LogLevel=ERROR", "-o", "ControlMaster=auto", "-o", f"ControlPath={self.ctl}",
                     "-o", "ControlPersist=600", "-o", "ConnectTimeout=8", "-o", "ServerAliveInterval=5",
                     "-o", "ServerAliveCountMax=3", *ssh_opts, target]

    def sh(self, cmd: str, timeout: float = 30) -> subprocess.CompletedProcess:
        try:
            return subprocess.run(self.base + [cmd], capture_output=True, text=True, timeout=timeout,
                                  stdin=subprocess.DEVNULL)
        except subprocess.TimeoutExpired as e:
            return subprocess.CompletedProcess(e.cmd, 124, "", "timeout")

    def _cli(self, args: list[str]) -> str:
        sock = ["--app-socket", self.socket] if self.socket else []
        return " ".join(shlex.quote(a) for a in [self.cli, *sock, "--json", *args])

    def cmux(self, args: list[str], timeout: float = 15) -> subprocess.CompletedProcess:
        return self.sh(self._cli(args), timeout)

    def ping_ms(self, timeout: float, sample_after_ms: int = 0, sample_file: str = "") -> int | None:
        """Main-thread round trip in ms, timed in the guest; None when nothing answers.

        A ping that runs past `timeout` returns the timeout (a hang), not None. With `sample_after_ms`,
        a ping still unanswered then starts `sample PID 5` of the app into `sample_file` in the guest
        while the hang lasts (sudo -n first: the hardened runtime refuses task_for_pid to a non-root
        sampler), so the sample shows the hang itself, over 5 s. The PID is looked up at that moment,
        and the file appears only complete (written to .tmp, then renamed).
        """
        # Perl, not python3: a macOS 26 guest without the Command Line Tools has only the
        # /usr/bin/python3 stub, which opens an install dialog and fails.
        ms = int(timeout * 1000)
        env = ""
        sampler = ""
        if sample_after_ms and sample_file:
            target = self.binary or self.app + "/Contents/MacOS/"
            pattern = "^" + "".join("\\" + c if c in ".[]()*+?{}|^$\\" else c for c in target)
            # Values reach the sampler through the environment, never spliced into code.
            env = f"FUZZ_SAMPLE_FILE={shlex.quote(sample_file)} FUZZ_APP_PATTERN={shlex.quote(pattern)} "
            sampler = (" if (!$done) { my $s = fork; if (defined $s && $s == 0) {"
                       " open STDIN, '<', '/dev/null'; open STDOUT, '>', '/dev/null'; open STDERR, '>', '/dev/null';"
                       " exec '/bin/sh', '-c', 'p=$(pgrep -nf \"$FUZZ_APP_PATTERN\") || exit 0; f=$FUZZ_SAMPLE_FILE;"
                       " { sudo -n /usr/bin/sample \"$p\" 5 -file \"$f.tmp\" || /usr/bin/sample \"$p\" 5 -file \"$f.tmp\"; }"
                       " && mv \"$f.tmp\" \"$f\"'; exit 127 } }")
        first = (sample_after_ms / 1000) if sampler else timeout
        perl = ("use Time::HiRes qw(time alarm); my $t = time; my $limit = " + str(timeout) + "; my $pid = fork;"
                " if (!$pid) { open STDOUT, '>', '/dev/null'; open STDERR, '>', '/dev/null'; exec @ARGV; exit 127 }"
                " my $wait = sub { my $s = shift; eval { local $SIG{ALRM} = sub { die \"t\\n\" }; alarm $s; waitpid($pid, 0); alarm 0; 1 } };"
                " my $done = $wait->(" + str(first) + ");"
                + sampler +
                # One deadline for the whole ping, counted from its start.
                " my $ok = $done || $wait->(($limit - (time - $t)) > 0.05 ? $limit - (time - $t) : 0.05);"
                " if (!$ok) { kill 9, $pid; print " + str(ms) + " } else { print $? ? -1 : int((time - $t) * 1000) }")
        r = self.sh(f"{env}/usr/bin/perl -e {shlex.quote(perl)} -- {self._cli(['app', 'ping'])}", timeout + 15)
        try:
            v = int(r.stdout.strip().splitlines()[-1])
            return None if v < 0 else v
        except (ValueError, IndexError):
            return None

    def rpc(self, method: str, params: dict) -> dict:
        """One debug control method over the guest's CLI (`cmux app call METHOD JSON`, Debug builds only: the CLI
        refuses any other bundle); raises on no answer."""
        r = self.cmux(["app", "call", method, json.dumps(params)], timeout=60)
        if r.returncode != 0:
            raise RuntimeError(f"{method}: exit {r.returncode}: {(r.stderr or r.stdout).strip()[-300:]}")
        return json.loads(r.stdout)

    def pid(self) -> int | None:
        # The app process itself (argv[0] is the binary), not a shell whose command line names it.
        target = self.binary or self.app + "/Contents/MacOS/"
        pattern = "^" + "".join("\\" + c if c in ".[]()*+?{}|^$\\" else c for c in target)
        r = self.sh(f"pgrep -nf {shlex.quote(pattern)}")
        return int(r.stdout.split()[0]) if r.returncode == 0 and r.stdout.strip() else None

    def winfo(self) -> dict | None:
        """Frontmost app and the app's on-screen windows (points), from CGWindowList in the guest."""
        pid = self.pid()
        if pid is None:
            return None
        r = self.sh(f"osascript -l JavaScript /tmp/fuzz-winfo.js {pid}", timeout=20)
        try:
            info = json.loads(r.stdout.strip().splitlines()[-1])
        except (ValueError, IndexError):
            return None
        info["pid"] = pid
        return info

    def window_rect_px(self, vnc: RFB) -> tuple[int, int, int, int] | None:
        info = self.winfo()
        if not info or not info.get("windows"):
            return None
        sx = vnc.width / info["screen"][0]
        sy = vnc.height / info["screen"][1]
        x, y, w, h = max(info["windows"], key=lambda r: r[2] * r[3])
        return int(x * sx), int(y * sy), int(w * sx), int(h * sy)

    def refocus(self) -> bool:
        """Bring the app back to the front when a step left it; True when it had to."""
        info = self.winfo()
        if info is None or info.get("front_pid") == info.get("pid"):
            return False
        # Other apps a stray key or click opened; the fuzz targets only cmux.
        self.sh("for a in Music Calendar 'System Settings' Photos Mail Maps Messages FaceTime Notes Reminders "
                "Freeform TV News 'App Store' Safari Contacts Preview TextEdit; do pkill -x \"$a\"; done; true")
        for _ in range(3):
            self.sh(f"open -a {shlex.quote(self.app)}")
            time.sleep(0.7)
            info = self.winfo()
            if info is None or info.get("front_pid") == info.get("pid"):
                break
        return True

    STATE_DIRS = ("~", "~/Library/Application Support", "~/Library/Caches", "~/Library/Preferences",
                  "~/Library/Saved Application State", "~/Library/HTTPStorages", "~/Library/WebKit", "/tmp",
                  "$(getconf DARWIN_USER_TEMP_DIR)")

    def _state_dirs(self) -> str:
        return " ".join('"$HOME' + d[1:] + '"' if d.startswith("~") else d if d.startswith("$(") else shlex.quote(d)
                        for d in self.STATE_DIRS)

    def snapshot_state(self) -> None:
        """Record what the state folders hold before the app's first launch (see ``reset``)."""
        dirs = self._state_dirs()
        self.sh(f"for d in {dirs}; do ls -A \"$d\" | sed \"s|^|$d/|\"; done > /tmp/fuzz-baseline.txt 2>/dev/null; true")

    def reset(self) -> None:
        """Quit the app and its helpers and delete every file the app created since ``snapshot_state``."""
        dirs = self._state_dirs()
        self.sh(f"pkill -9 -f {shlex.quote(self.app + '/Contents/')}; sleep 1; "
                f"for d in {dirs}; do ls -A \"$d\" | sed \"s|^|$d/|\"; done 2>/dev/null | grep -vxF -f /tmp/fuzz-baseline.txt "
                "| grep -v -E '/tmp/fuzz-|/tmp/cmux-fuzz-app.log' | while IFS= read -r p; do rm -rf \"$p\"; done; "
                "killall cfprefsd 2>/dev/null; true", timeout=60)

    def install_helpers(self) -> None:
        src = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "winfo.js")).read()
        subprocess.run(self.base + ["cat > /tmp/fuzz-winfo.js"], input=src, text=True, capture_output=True, timeout=30)

    def launch(self, deadline: float = 180, exit_file: str | None = None, until: float | None = None) -> bool:
        """Start the app with the automation socket open to SSH clients; wait for a ping.

        With `exit_file`, the guest shell waits for the app and writes its exit status there
        (128 + the signal for a signal death), so a caller can tell a clean quit from a crash, and
        the wait ends as soon as the app exits. The wait is `deadline` times the diag's slowdown,
        never past `until` (the run's end). On False, `launch_failure` says why.
        """
        plist = self.sh(f"/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' {shlex.quote(self.app + '/Contents/Info.plist')}")
        self.binary = f"{self.app}/Contents/MacOS/{plist.stdout.strip()}"
        before = time.time()
        end = before + deadline * self.slowdown
        if until is not None:
            end = min(end, until)
        self.launch_failure = ""
        # Not `nohup`: dyld strips DYLD_* variables from SIP-protected binaries and their
        # children, so the shell exports them and starts the app itself (ignoring SIGHUP).
        run = (f"{shlex.quote(self.binary)} >>/tmp/cmux-fuzz-app.log 2>&1 </dev/null; echo $? >{shlex.quote(exit_file)}"
               if exit_file else f"exec {shlex.quote(self.binary)} >>/tmp/cmux-fuzz-app.log 2>&1 </dev/null")
        if exit_file:
            self.sh(f"rm -f {shlex.quote(exit_file)}")
        self.sh(f"( trap '' HUP; export {self.env}; {run} ) & disown; true")
        # One round trip per poll: the exit status (once the app has exited), then the newest socket.
        probe = "ls -t /tmp/cmux-*.sock 2>/dev/null | head -1"
        if exit_file:
            probe = f"sed 's/^/exit=/' {shlex.quote(exit_file)} 2>/dev/null; {probe}"
        while time.time() < end:
            lines = self.sh(probe).stdout.splitlines()
            status = next((l[len("exit="):].strip() for l in lines if l.startswith("exit=")), None)
            if status is not None:
                self.launch_failure = f"the app exited during launch (status {status})"
                return False
            self.socket = next((l.strip() for l in lines if l.strip()), "")
            ms = self.ping_ms(3 * self.slowdown) if self.socket else None
            # A ping that ran into its timeout is a hung app, not a launched one.
            if ms is not None and ms < 3000 * self.slowdown:
                # Bring the window forward so VNC keys reach it.
                self.sh(f"open -a {shlex.quote(self.app)}")
                return True
            time.sleep(2)
        self.launch_failure = ("no ping before the run's end" if until is not None and end == until
                               else f"no ping within {deadline * self.slowdown:g} s")
        return False


def exclusion_reason(a: dict) -> str | None:
    """Why the fuzz never runs `a` (None: it is eligible)."""
    if a.get("debug_only"):
        return "debug-only"
    if (a.get("surfaces") or {}).get("mcp") == "endsApp":
        return "ends-app"
    if a.get("bound") is False:
        return "not-bound"
    if a.get("unavailable_reason"):
        return "unavailable-in-build"  # bound as unavailable: every run answers `unavailable`
    if a.get("category") in ("cloud", "remote"):
        return f"category:{a['category']}"
    ident = (a["id"] + " " + a.get("cli_name", "")).lower().replace(".", "")
    word = next((w for w in SKIP_WORDS if w in ident), None)
    if word:
        return f"skip-word:{word}"
    for arg in a.get("arguments") or []:
        kind = arg.get("target_kind") or ""
        if arg.get("kind") == "target" and arg.get("required") and kind not in TARGET_LISTS and kind not in TARGET_FIXED:
            # No list command names such an object, so every run would be refused for the argument.
            return f"unresolvable-target:{kind}"
    return None


def classify_actions(listed: list[dict]) -> tuple[list[dict], dict[str, str]]:
    """The eligible actions sorted by id (the plan must not depend on the list's order) and
    the reason for each one left out."""
    eligible: list[dict] = []
    excluded: dict[str, str] = {}
    for a in sorted(listed, key=lambda x: x["id"]):
        reason = exclusion_reason(a)
        if reason:
            excluded[a["id"]] = reason
        else:
            eligible.append(a)
    return eligible, excluded


ACTION_LIST_KEYS = ("id", "title", "cli_name", "arguments", "targets", "requires", "bound", "debug_only",
                    "destructive", "waits_for_person")


def checked_action_list(doc: object) -> list[dict]:
    """The actions of a `cmux --json action list` reply (ControlActionInfo.json). Raises ValueError
    for any other document, such as plans/cmux-next/action-surfaces.json, which has no argument
    schema, so a plan made from it would test none of the argument generators."""
    actions = doc.get("actions") if isinstance(doc, dict) else None
    if not isinstance(actions, list) or not actions:
        raise ValueError("not a `cmux --json action list` reply: no `actions` list")
    for a in actions:
        missing = [k for k in ACTION_LIST_KEYS if not isinstance(a, dict) or k not in a]
        if missing:
            ident = a.get("id") if isinstance(a, dict) else a
            raise ValueError(f"not a `cmux --json action list` reply: action {ident!r} has no {', '.join(missing)}")
    return actions


def load_actions(g: Guest) -> tuple[list[dict], dict[str, str]]:
    r = g.cmux(["action", "list"], timeout=30)
    return classify_actions(checked_action_list(json.loads(r.stdout)))


STRING_VALUES = ("fuzz", "a", "", "Ω≈ç 🙂 ünïcødé", "x" * 300, "../../../etc/passwd", "\u202erlt", "%s%n{}$(true)")
# Under /tmp only: a destructive action runs confirmed, and must never take the guest home with it.
PATH_VALUES = ("/tmp/cmux-fuzz", "/tmp/cmux-fuzz/new.md", "/tmp/cmux fuzz/ünï.txt", "/tmp/cmux-fuzz/../cmux-fuzz-up", "/nonexistent/x")
URL_VALUES = ("https://example.com", "about:blank", "http://127.0.0.1:9/", "not a url", "file:///tmp/")
INT_VALUES = (0, 1, 2, -1, 999, 2**31 - 1, -(2**31))


def string_value(rng: random.Random, name: str) -> str:
    n = name.lower()
    if any(w in n for w in ("path", "file", "dir", "folder", "cwd", "out")):
        return rng.choice(PATH_VALUES)
    if any(w in n for w in ("url", "link", "href")):
        return rng.choice(URL_VALUES)
    return rng.choice(STRING_VALUES)


def int_value(rng: random.Random, arg: dict, valid_only: bool) -> int:
    lo, hi = arg.get("min"), arg.get("max")
    if lo is None or hi is None:
        return rng.choice(INT_VALUES)
    if not valid_only and rng.random() < 0.1:
        return rng.choice([lo - 1, hi + 1])  # the app's range check
    return rng.choice([lo, hi, (lo + hi) // 2, min(lo + 1, hi), max(hi - 1, lo), rng.randint(lo, hi)])


def arg_value(rng: random.Random, a: dict, arg: dict, valid_only: bool) -> str | dict:
    """A value of the argument's declared kind; a target-kind argument gets a placeholder that
    `resolve_target` turns into a live object at run time."""
    kind, name = arg.get("kind"), arg["name"]
    if name == "confirm" and a.get("destructive"):
        return "true"
    if kind == "enum" and arg.get("choices"):
        if not valid_only and rng.random() < 0.05:
            return "fuzz-no-such-choice"
        return str(rng.choice(arg["choices"])["value"])
    if kind == "int":
        return str(int_value(rng, arg, valid_only))
    if kind == "bool":
        return rng.choice(["true", "false"])
    if kind == "target":
        return {"kind": arg.get("target_kind") or "", "n": rng.randrange(1 << 16)}
    return string_value(rng, name)


def plan_args(rng: random.Random, a: dict, valid_only: bool) -> list[list]:
    """[name, value] pairs: every required argument, the confirmation of a destructive action,
    and a seeded choice of the optional ones."""
    out: list[list] = []
    for arg in a.get("arguments") or []:
        if not arg.get("name"):
            continue
        needed = arg.get("required") or (arg["name"] == "confirm" and a.get("destructive"))
        if needed or rng.random() < (0.5 if valid_only else 0.35):
            out.append([arg["name"], arg_value(rng, a, arg, valid_only)])
    return out


def plan_action(rng: random.Random, a: dict, valid_only: bool) -> dict:
    step = {"kind": "action", "id": a["id"], "args": plan_args(rng, a, valid_only)}
    kinds = [t for t in a.get("targets") or [] if t in TARGET_LISTS or t in TARGET_FIXED]
    # In the coverage pass an action that needs context always names its object: a target stands
    # in for the focused window's context (`available_with_target`), which the pass does not set up.
    if kinds and ((valid_only and a.get("requires")) or rng.random() < 0.7):
        # Resolved against the live list in UI order at run time (n modulo its length), so a replay
        # with the same seed and build picks the same object.
        step["target"] = {"kind": rng.choice(kinds), "n": rng.randrange(1 << 16)}
    if a.get("waits_for_person"):
        step["wait"] = False  # nobody answers its dialog; the step dismisses it instead
    return step


def plan_coverage(rng: random.Random, actions: list[dict]) -> list[dict]:
    """Every eligible action once, in a seeded order, with valid arguments."""
    order = list(actions)
    rng.shuffle(order)
    return [plan_action(rng, a, valid_only=True) for a in order]


def plan_run(seed: int, actions: list[dict], tour: bool, coverage: bool,
             count: int | None) -> tuple[int, Iterator[dict]]:
    """The planned steps (the tour, the coverage pass, then the walk) and how many come before
    the walk.

    The walk is drawn lazily from the same seeded generator after the coverage pass, so the
    same seed and build give the same sequence however long the run is; `count` None walks
    until the caller stops.
    """
    rng = random.Random(seed)
    prefix = [{"kind": "palette", "title": t} for t in TOUR] if tour else []
    if coverage:
        prefix += plan_coverage(rng, actions)
    walk = (plan_step(rng, actions) for _ in (itertools.count() if count is None else range(count)))
    return len(prefix), itertools.chain(prefix, walk)


def plan_step(rng: random.Random, actions: list[dict]) -> dict:
    r = rng.random()
    if r < 0.30:
        return plan_action(rng, rng.choice(actions), valid_only=False)
    if r < 0.40:
        a = rng.choice(actions)
        return {"kind": "palette", "title": a["title"]}
    if r < 0.58:
        bound = [x["shortcut"] for x in actions if x.get("shortcut") and "…" not in x["shortcut"]]
        return {"kind": "key", "chord": rng.choice(NAMED_KEYS + bound)}
    if r < 0.66:
        return {"kind": "type", "text": rng.choice(TEXT)}
    def f(lo: float = 0.0, hi: float = 1.0) -> float:
        return round(rng.uniform(lo, hi), 4)
    # Pointer steps use fractions of the app's largest window, resolved at run time, so they
    # stay in the app; drags reach 5% past the edges to hit window and split resize handles.
    if r < 0.82:
        return {"kind": "click", "fx": f(), "fy": f(), "right": rng.random() < 0.2,
                "count": rng.choice([1, 1, 1, 2])}
    if r < 0.92:
        return {"kind": "drag", "fx0": f(-0.05, 1.05), "fy0": f(-0.05, 1.05), "fx1": f(-0.05, 1.05), "fy1": f(-0.05, 1.05)}
    if r < 0.96:
        return {"kind": "scroll", "fx": f(), "fy": f(), "down": rng.random() < 0.5}
    return {"kind": "esc"}


TARGET_LISTS = {  # action target kind -> CLI list command
    "workspace": ["workspace", "list"], "tab": ["tab", "list"], "pane": ["pane", "list"],
    "screen": ["screen", "list"], "workspace-group": ["workspace", "group", "list"],
    "window": ["window", "list"], "tab-group": ["tab", "group", "list"],
    "screen-group": ["screen", "group", "list"], "bookmark": ["bookmark", "list"],
}
TARGET_FIXED = {  # target kinds that always have these objects (ActionTargetKind)
    "machine": ["machine:local"], "room": ["room:default"], "browser-profile": ["browser-profile:default"],
    "sidebar-item": ["sidebar-item:home"],
}


def list_ids(items: object) -> list[str]:
    """Object ids of a `<noun> list --json` reply: a list, or an object holding one."""
    if isinstance(items, dict):
        items = next((v for v in items.values() if isinstance(v, list)), [])
    if not isinstance(items, list):
        return []
    return [str(x["id"]) for x in items if isinstance(x, dict) and "id" in x]


def resolve_target(g: Guest, pick: dict) -> str | None:
    """`kind:id` of the pick's object, n modulo the live list in UI order; None when none exists."""
    kind = pick.get("kind", "")
    if kind in TARGET_FIXED:
        ids = TARGET_FIXED[kind]
    elif kind in TARGET_LISTS:
        try:
            ids = list_ids(json.loads(g.cmux(TARGET_LISTS[kind]).stdout))
        except (ValueError, TypeError):
            return None
    else:
        return None
    if not ids:
        return None
    ident = ids[pick["n"] % len(ids)]
    return ident if ":" in ident else f"{kind}:{ident}"


def action_cli_args(step: dict, resolve: Callable[[dict], str | None]) -> list[str]:
    """`cmux action run ID` arguments for an action step, its target placeholders resolved.

    Arguments go as `--arg name=value`: the schema's exact name, never mistaken for one of the
    CLI's own flags (`--target`, `--wait`, `--focus`).
    """
    raw = step.get("args") or []
    if all(isinstance(x, str) for x in raw):
        tokens = list(raw)  # steps.jsonl written before schema-driven arguments
    else:
        tokens = []
        for name, value in raw:
            if isinstance(value, dict):
                value = resolve(value)
                if value is None:
                    continue
            tokens += ["--arg", f"{name}={value}"]
    target = resolve(step["target"]) if step.get("target") else None
    if target:
        tokens = ["--target", target, *tokens]
    if step.get("wait") is False:
        tokens.append("--no-wait")
    return tokens


# Error codes with which the app or the CLI refuses a run before its handler acts (ControlError+ActionRun,
# ControlRouter+Validation, PublicIDTargetResolver, the CLI's usage errors); `transport`: the step broke off.
REFUSALS = frozenset(("invalid_params", "invalid_request", "usage.invalid", "parse_error", "method_not_found",
                      "unavailable", "not_bound", "disabled", "feature.disabled", "confirmation_required",
                      "not_found", "ambiguous", "transport"))


def reached_handler(outcome: str) -> bool:
    """Whether an action step's outcome shows its handler ran: `ok`, a `timeout`, or an error code
    that is not a refusal. `rc:<n>` (the CLI failed with no error code) does not."""
    if outcome in ("ok", "timeout"):
        return True
    return outcome.startswith("error:") and outcome[len("error:"):] not in REFUSALS


def action_outcome(r: subprocess.CompletedProcess) -> str:
    """`ok`, `timeout`, `error:<code>` from the CLI's JSON error on stderr, or `rc:<exit status>`."""
    if r.returncode == 0:
        return "ok"
    if r.returncode == 124 and r.stderr == "timeout":
        return "timeout"
    for line in reversed((r.stderr or "").strip().splitlines()):
        try:
            code = json.loads(line).get("code")
        except (ValueError, AttributeError):
            continue
        if code:
            return f"error:{code}"
    return f"rc:{r.returncode}"


def run_step(step: dict, g: Guest, vnc: RFB) -> tuple[str, str | None]:
    """Runs one step; the note for the log and, for an action step, its outcome."""
    k = step["kind"]
    if k == "action":
        cache: dict[str, str | None] = {}

        def resolve(pick: dict) -> str | None:
            key = json.dumps(pick, sort_keys=True)
            if key not in cache:
                cache[key] = resolve_target(g, pick)
            return cache[key]

        r = g.cmux(["action", "run", step["id"], *action_cli_args(step, resolve)], timeout=20)
        if step.get("wait") is False:
            time.sleep(0.5)
            vnc.chord("esc")  # the dialog the action opened waits for a person
        return f"rc={r.returncode} {(r.stdout or r.stderr).strip()[:160]}", action_outcome(r)
    if k == "palette":
        vnc.chord("cmd+shift+p")
        time.sleep(0.3)
        vnc.type_text(step["title"][:40])
        time.sleep(0.3)
        vnc.chord("return")
        return "palette", None
    if k == "key":
        vnc.chord(step["chord"])
    elif k == "type":
        vnc.type_text(step["text"])
    elif k in ("click", "drag", "scroll"):
        rect = g.window_rect_px(vnc)
        if rect is None:
            return "no window", None
        x, y, w, h = rect
        px = lambda fx: int(x + fx * w)  # noqa: E731
        py = lambda fy: int(y + fy * h)  # noqa: E731
        if k == "click":
            vnc.click(px(step["fx"]), py(step["fy"]), step["right"], step["count"])
            if step["right"]:
                time.sleep(0.3)
                vnc.chord("esc")  # a context menu would swallow the next steps
        elif k == "drag":
            vnc.drag(px(step["fx0"]), py(step["fy0"]), px(step["fx1"]), py(step["fy1"]))
        else:
            vnc.scroll(px(step["fx"]), py(step["fy"]), step["down"])
    elif k == "esc":
        vnc.chord("esc")
    return "ok", None


class InvariantBroken(Exception):
    """A step after which the app's invariant ledger had a new violation (invariants.assert_clean)."""


def invariant_cursor(g: Guest) -> tuple[invariants.Cursor | None, str | None]:
    """The app's invariant cursor from its launch, or None and why the run is not checked (a Release build)."""
    try:
        return invariants.Cursor(g.rpc, g.pid, from_start=True), None
    except invariants.NotArmed as e:
        return None, str(e)


def workspace_count(g: Guest) -> int:
    try:
        return len(json.loads(g.cmux(["workspace", "list"]).stdout))
    except (ValueError, TypeError):
        return -1


CMD_CANDIDATES = (("Alt_R", 0xFFEA), ("Super_L", 0xFFEB), ("Super_R", 0xFFEC), ("Hyper_L", 0xFFED))


def check_input(g: Guest, vnc: RFB) -> dict:
    """Find the keysym the VNC server maps to Command: the one whose Cmd+N adds a workspace."""
    import rfb
    tried = {}
    for name, sym in CMD_CANDIDATES:
        rfb.KEYSYM["cmd"] = sym
        g.refocus()
        vnc.chord("esc")
        time.sleep(0.3)
        before = workspace_count(g)
        vnc.chord("cmd+n")
        time.sleep(2)
        after = workspace_count(g)
        tried[name] = [before, after]
        if after > before >= 0:
            return {"ok": True, "cmd_keysym": name, "tried": tried}
    rfb.KEYSYM["cmd"] = 0xFFEA
    return {"ok": False, "tried": tried}


def report_kind(name: str) -> str:
    """A DiagnosticReports file's finding kind: .ips files of the app are crashes; .diag files are
    resource reports (disk writes, CPU, wakeups), .hang files hang reports and JetsamEvent files
    the system's memory kills."""
    if name.endswith(".hang"):
        return "hang-report"
    if name.endswith(".diag"):
        return "resource-report"
    if name.startswith("JetsamEvent"):
        return "jetsam"  # the system ended processes for memory: not a crash of the app's code
    return "crash"


def new_reports(g: Guest, since: float, seen: set[str]) -> list[str]:
    """Crash (.ips), hang and Jetsam (memory kill) reports written since `since` (epoch s)."""
    perl = ("for my $d (glob('~/Library/Logs/DiagnosticReports'), '/Library/Logs/DiagnosticReports') {"
            " for my $p (glob(\"$d/*\")) { my ($n) = $p =~ m{([^/]+)$};"
            " next unless $n =~ /cmux|acpmux|optchat/ || $n =~ /\\.hang$/ || $n =~ /^JetsamEvent/;"
            " print \"$p\\n\" if (stat $p)[9] > $ARGV[0] } }")
    r = g.sh(f"/usr/bin/perl -e {shlex.quote(perl)} {since}")
    return [p for p in r.stdout.splitlines() if p and p not in seen]


def minimize(steps: list[dict], g: Guest, vnc: RFB, out: str) -> list[dict]:
    """Delta-debug (ddmin) the steps before the last one down to a minimal list that still kills the app.

    Every trial resets the app's state in the same VM, launches it, runs the candidate steps and checks
    the app is still alive 5 s after the last one. Writes each trial and the result to `out`.
    """
    last = steps[-1]
    trials = open(os.path.join(out, "minimize.jsonl"), "a")

    def dies(prefix: list[dict]) -> bool:
        g.reset()
        if not g.launch():
            return False
        g.refocus()
        for st in prefix + [last]:
            g.refocus()
            try:
                run_step(st, g, vnc)
            except (ConnectionError, OSError):
                pass
            time.sleep(0.15)
        time.sleep(5)
        dead = g.pid() is None
        trials.write(json.dumps({"n": len(prefix), "dies": dead}) + "\n")
        trials.flush()
        print(f"trial {len(prefix)} steps: {'DIES' if dead else 'lives'}", flush=True)
        return dead

    cur = steps[:-1]
    if not dies(cur):
        print("the full list does not kill the app in a fresh state; nothing to minimize", flush=True)
        return steps
    n = 2
    while len(cur) >= 2:
        chunk = max(1, len(cur) // n)
        parts = [cur[i:i + chunk] for i in range(0, len(cur), chunk)]
        reduced = False
        for i in range(len(parts)):
            complement = [x for j, p in enumerate(parts) if j != i for x in p]
            if dies(complement):
                cur, n, reduced = complement, max(n - 1, 2), True
                break
        if not reduced:
            if n >= len(cur):
                break
            n = min(len(cur), n * 2)
    if not cur and not dies([]):
        pass
    result = cur + [last]
    with open(os.path.join(out, "minimal.jsonl"), "w") as f:
        for st in result:
            f.write(json.dumps({"step": st}) + "\n")
    print(f"minimal: {len(result)} steps", flush=True)
    return result


class Coverage:
    """Per-action runs and outcomes for summary.json. An action counts as covered only when one of
    its runs reached the handler (``reached_handler``); an action that was only refused stays in
    `actions_uncovered` and is listed in `actions_refused` with its outcomes."""

    def __init__(self, eligible: list[dict], excluded: dict[str, str]):
        self.eligible = [a["id"] for a in eligible]
        self.excluded = excluded
        self.runs: dict[str, dict[str, int]] = {}

    def record(self, action: str, outcome: str) -> None:
        tally = self.runs.setdefault(action, {})
        tally[outcome] = tally.get(outcome, 0) + 1

    def summary(self) -> dict:
        covered = {a for a in self.eligible if any(reached_handler(o) for o in self.runs.get(a, {}))}
        return {
            "actions_known": len(self.eligible) + len(self.excluded),
            "actions_eligible": len(self.eligible),
            "actions_covered": len(covered),
            "actions_ok": sum(1 for a in covered if self.runs[a].get("ok")),
            "actions_uncovered": [a for a in self.eligible if a not in covered],
            "actions_refused": {a: sorted(self.runs[a]) for a in self.eligible if a in self.runs and a not in covered},
            "actions_excluded": self.excluded,
            "action_outcomes": {a: {"runs": sum(t.values()), "outcomes": dict(sorted(t.items()))}
                                for a, t in sorted(self.runs.items())},
        }


def run_deadlines(start: float, minutes: float, coverage_minutes: float) -> tuple[float | None, float]:
    """(run_end, prefix_end). --minutes bounds the whole run, tour and coverage pass included, as
    vm.sh and os-matrix.sh expect; the coverage pass ends at --coverage-minutes or at the run's
    end, whichever comes first."""
    run_end = start + minutes * 60 if minutes > 0 else None
    prefix_end = start + coverage_minutes * 60
    return run_end, prefix_end if run_end is None else min(prefix_end, run_end)


def step_gate(i: int, prefix_len: int, now: float, run_end: float | None, prefix_end: float) -> str:
    """`run` step i, `skip` it (a coverage-pass step past the pass's bound), or `stop` the run."""
    if run_end is not None and now >= run_end:
        return "stop"
    if i < prefix_len and now >= prefix_end:
        return "skip"
    return "run"


def plan_digest(steps: list[dict]) -> str:
    return hashlib.sha256("\n".join(json.dumps(s, sort_keys=True) for s in steps).encode()).hexdigest()


def write_plan(actions_json: str, seed: int, tour: bool, walk: int, out: str) -> dict:
    """--plan-only: the plan for a saved `cmux --json action list`, no VM. Writes plan.jsonl
    and returns its digest and coverage."""
    with open(actions_json) as f:
        eligible, excluded = classify_actions(checked_action_list(json.load(f)))
    prefix_len, steps = plan_run(seed, eligible, tour=tour, coverage=True, count=walk)
    planned = list(steps)
    with open(os.path.join(out, "plan.jsonl"), "w") as f:
        for st in planned:
            f.write(json.dumps({"step": st}) + "\n")
    covered = {st["id"] for st in planned[:prefix_len] if st["kind"] == "action"}
    return {"seed": seed, "steps": len(planned), "prefix_steps": prefix_len,
            "plan_sha256": plan_digest(planned[:prefix_len]), "actions_eligible": len(eligible),
            "actions_planned_in_coverage": len(covered), "actions_excluded": len(excluded)}


def apply_diag(g: Guest, d: diag.Diag | None, dylibs: list[str], hang_ms: int) -> tuple[dict[str, str], int]:
    """The app's launch environment (the diag's, or the inserted dylibs alone), exported through
    `g.env`, and --hang-ms scaled by the diag's slowdown."""
    env = diag.launch_env(d, dylibs) if d else ({"DYLD_INSERT_LIBRARIES": ":".join(dylibs)} if dylibs else {})
    g.env += "".join(f" {k}={shlex.quote(v)}" for k, v in env.items())
    if d:
        g.slowdown = d.slowdown
        hang_ms *= d.slowdown
    return env, hang_ms


def diag_summary(g: Guest, d: diag.Diag, env: dict[str, str], runtime_left: list[str], snapshots: list[dict],
                 reports: diag.Reports, zones_tool: str, launched: bool = True) -> dict:
    """summary.json's diag keys at the end of the run: a last snapshot of a live app, the check's
    reports, the record, and `invalid` when the record says the run proves nothing."""
    if g.pid() is not None:
        snapshots.append({"at": "end", **diag.snapshot(g, zones_tool)})
    reports.harvest_stderr(g, "end")
    reports.collect_files(g)
    rec = diag.record(d, env, runtime_left, snapshots, reports, launched=launched)
    keys = {"diag": rec, "diag_reports": rec["reports"]["count"]}
    if rec["invalid"]:
        keys["invalid"] = rec["invalid"]
    return keys


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--ssh", help="guest user@ip (required unless --plan-only)")
    ap.add_argument("--vnc", help="host:port[:password] (required unless --plan-only)")
    ap.add_argument("--app", default="/Applications/cmux NIGHTLY.app")
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--steps", type=int, default=None,
                    help="random steps after the tour (default 1000; with --minutes: as many as the time allows)")
    ap.add_argument("--minutes", type=float, default=0,
                    help="stop the run after this many minutes (0: run every step); the run's time bound, "
                         "tour and coverage pass included")
    ap.add_argument("--no-coverage", action="store_true", help="skip the pass that runs every eligible action once")
    ap.add_argument("--coverage-minutes", type=float, default=60,
                    help="time bound on the tour and coverage pass (default 60), inside --minutes; "
                         "summary.json lists what it left")
    ap.add_argument("--plan-only", metavar="ACTIONS_JSON",
                    help="write plan.jsonl for a saved `cmux --json action list` and exit (no VM)")
    ap.add_argument("--hang-ms", type=int, default=1000)
    ap.add_argument("--out", required=True)
    ap.add_argument("--replay", help="steps.jsonl from an earlier run")
    ap.add_argument("--no-tour", action="store_true")
    ap.add_argument("--probe-keys", action="store_true", help="only find the Command keysym, then exit")
    ap.add_argument("--minimize", action="store_true", help="with --replay: delta-debug the steps to a minimal crash")
    ap.add_argument("--shot-every", type=int, default=50, help="VNC screenshot every N steps (0: never)")
    ap.add_argument("--ssh-opt", action="append", default=[], help="extra ssh option (repeatable)")
    ap.add_argument("--insert-dylib", action="append", default=[],
                    help="guest path of a diagnostic dylib to load (DYLD_INSERT_LIBRARIES; repeatable); "
                    "the app must be signed without the hardened runtime")
    ap.add_argument("--diag", choices=sorted(diag.DIAGS), help="run the app under this check (diag.py)")
    ap.add_argument("--zones-tool", default="", help="guest path of malloc-zones (vm.sh --diag puts it there)")
    o = ap.parse_args()
    d = diag.DIAGS.get(o.diag) if o.diag else None

    os.makedirs(o.out, exist_ok=True)
    if o.plan_only:
        walk = o.steps if o.steps is not None else 1000
        try:
            print(json.dumps(write_plan(o.plan_only, o.seed, not o.no_tour, walk, o.out)))
        except ValueError as e:
            ap.error(f"--plan-only {o.plan_only}: {e}")
        return 0
    if not o.ssh or not o.vnc:
        ap.error("--ssh and --vnc are required")
    host, port, *pw = o.vnc.split(":")
    vnc = RFB(host, int(port), pw[0] if pw else None)
    g = Guest(o.ssh, o.app, o.ssh_opt)
    env, o.hang_ms = apply_diag(g, d, o.insert_dylib, o.hang_ms)
    osver = g.sh("sw_vers -productVersion").stdout.strip()
    if g.sh(f"test -d {shlex.quote(o.app)}").returncode != 0:
        sys.exit(f"no app at {o.app!r} in the guest")
    g.install_helpers()
    if o.minimize:
        g.snapshot_state()
    runtime_left: list[str] = []
    diag_reports = diag.Reports(d, o.out) if d else None
    snapshots: list[dict] = []
    if d:
        diag.prepare_guest(g, d)
        runtime_left = diag.runtime_in_bundle(g, o.app) if d.chromium_off else []
    exit_file = f"/tmp/cmux-fuzz-exit-{os.getpid()}"
    # From before the launch: --minutes bounds the whole run, a slow diag launch included.
    run_end, prefix_end = run_deadlines(time.time(), o.minutes, o.coverage_minutes)
    if not g.launch(exit_file=exit_file, until=run_end):
        if d and diag_reports:
            # The check may have stopped the app at launch: its reports and the record are the finding.
            summary = {"os": osver, "seed": o.seed, "steps": 0, "crashes": 0, "hangs": 0, "relaunches": 0,
                       "launch_failed": g.launch_failure,
                       **diag_summary(g, d, env, runtime_left, snapshots, diag_reports, o.zones_tool, launched=False)}
            json.dump(summary, open(os.path.join(o.out, "summary.json"), "w"), indent=2)
            print(json.dumps(summary))
        sys.exit(f"the app did not launch: {g.launch_failure}")
    if d:
        snapshots.append({"at": "launch", **diag.snapshot_after_launch(g, o.zones_tool)})
        print("diag launch:", json.dumps(snapshots[-1]), flush=True)
    actions, excluded = load_actions(g)
    coverage = Coverage(actions, excluded)
    steps: Iterator[dict]
    if o.replay:
        with open(o.replay) as f:
            replayed = [json.loads(l)["step"] for l in f if l.strip()]
        # No coverage prefix: a replay repeats every step, bounded only by --minutes.
        prefix_len, steps, plan_sha = 0, iter(replayed), plan_digest(replayed)
    else:
        # --minutes without --steps walks until the time is up.
        count = o.steps if o.steps is not None else (None if o.minutes > 0 else 1000)
        prefix_len, planned = plan_run(o.seed, actions, tour=not o.no_tour, coverage=not o.no_coverage, count=count)
        prefix = list(itertools.islice(planned, prefix_len))
        plan_sha = plan_digest(prefix)
        steps = itertools.chain(prefix, planned)

    summary_input = check_input(g, vnc)
    print("input check:", json.dumps(summary_input), flush=True)
    if o.probe_keys or not summary_input["ok"]:
        try:
            open(os.path.join(o.out, "input-check.png"), "wb").write(vnc.screenshot_png())
        except Exception:
            pass
    if o.probe_keys:
        return 0 if summary_input["ok"] else 1
    if o.minimize:
        if not o.replay:
            sys.exit("--minimize needs --replay")
        minimize(replayed, g, vnc, o.out)
        return 0
    log = open(os.path.join(o.out, "steps.jsonl"), "w")
    findings = open(os.path.join(o.out, "findings.jsonl"), "a")
    seen: set[str] = set()
    t0 = time.time() - 5
    summary = {"os": osver, "seed": o.seed, "steps": 0, "crashes": 0, "hangs": 0, "relaunches": 0,
               "plan_sha256": plan_sha, "prefix_steps": prefix_len, "input": summary_input}

    def finding(kind: str, i: int, step: dict, extra: dict) -> None:
        rec = {"kind": kind, "os": osver, "seed": o.seed, "index": i, "step": step, "t": time.time(), **extra}
        findings.write(json.dumps(rec) + "\n")
        findings.flush()
        try:
            open(os.path.join(o.out, f"{kind}-{i}.png"), "wb").write(vnc.screenshot_png())
        except Exception as e:  # screenshot is best effort
            rec["screenshot_error"] = str(e)

    executed = 0
    # Prefix steps (tour and coverage pass) not run, and the wall time of the coverage-pass action
    # steps that ran, ping and report checks included: the data behind the --coverage-minutes default.
    coverage_skipped = coverage_steps = 0
    coverage_seconds = 0.0
    coverage_started: float | None = None
    run_id = os.getpid()  # in live-sample names: a reused guest never matches an older file
    last_pid = g.pid()
    cursor, unchecked = invariant_cursor(g)
    summary["invariants"] = "checked" if cursor else f"not run: {unchecked}"
    summary["invariant_violations"] = 0
    for i, step in enumerate(steps):
        now = time.time()
        if coverage_started is not None:
            coverage_seconds += now - coverage_started
            coverage_started = None
        gate = step_gate(i, prefix_len, now, run_end, prefix_end)
        if gate == "stop":
            if i < prefix_len:
                summary.setdefault("coverage_stopped", f"--minutes {o.minutes:g} reached at step {i}")
                coverage_skipped += prefix_len - i
            summary["stopped"] = f"--minutes {o.minutes:g} reached after {executed} steps"
            break
        if gate == "skip":
            # The rest of the pass is skipped, not run late: actions_uncovered lists it.
            summary.setdefault("coverage_stopped", f"--coverage-minutes {o.coverage_minutes:g} reached at step {i}")
            coverage_skipped += 1
            continue
        started = now
        if i < prefix_len and step["kind"] == "action":
            coverage_started = started
            coverage_steps += 1
        # Before action steps too: an action's availability follows the focused window's context,
        # and the Esc that dismisses a waiting action's dialog goes to the frontmost app.
        if g.refocus():
            summary["refocus"] = summary.get("refocus", 0) + 1
        try:
            note, outcome = run_step(step, g, vnc)
        except (ConnectionError, OSError) as e:
            note, outcome = f"vnc error {e}", None
            vnc = RFB(host, int(port), pw[0] if pw else None)
        if step["kind"] == "action":
            coverage.record(step["id"], outcome or "error:transport")
        live_sample = f"/tmp/fuzz-live-sample-{run_id}-{i}.txt"
        ms = g.ping_ms(timeout=max(5, o.hang_ms / 1000 * 5), sample_after_ms=o.hang_ms, sample_file=live_sample)
        log.write(json.dumps({"i": i, "step": step, "note": note, "outcome": outcome, "ping_ms": ms,
                              "dt": round(time.time() - started, 3)}) + "\n")
        log.flush()
        executed += 1
        summary["steps"] = executed
        if o.shot_every and i % o.shot_every == 0:
            try:
                open(os.path.join(o.out, f"step-{i:05d}.png"), "wb").write(vnc.screenshot_png())
            except Exception as e:  # best effort
                print("screenshot failed:", e, flush=True)
        pid = g.pid()
        dead_pid = last_pid if pid is None else None
        last_pid = pid if pid is not None else last_pid
        if cursor and pid is not None and ms is not None and ms <= o.hang_ms:
            # Every rule on every subject after the step; a relaunched app's new ledger starts at 0 (Cursor.new).
            try:
                invariants.assert_clean(cursor, f"step {i} ({step.get('kind')} {step.get('id', '')})".strip(), InvariantBroken,
                                        check=True)
            except InvariantBroken as e:
                summary["invariant_violations"] += 1
                finding("invariant", i, step, {"invariants": str(e)[-4000:]})
        if ms is not None and ms > o.hang_ms and pid:
            summary["hangs"] += 1
            # The live sample appears only complete (renamed after 5 s and symbolication): wait for it, bounded.
            text = g.sh(f"for n in $(seq 1 20); do [ -e {live_sample} ] && break; sleep 1; done; "
                        f"cat {live_sample} 2>/dev/null", timeout=40).stdout
            if text.strip():
                open(os.path.join(o.out, f"hang-{i}.live-sample.txt"), "w").write(text)
            sample = os.path.join("/tmp", f"fuzz-sample-{i}.txt")
            g.sh(f"sudo -n /usr/bin/sample {pid} 2 -file {sample} >/dev/null 2>&1 || /usr/bin/sample {pid} 2 -file {sample} >/dev/null 2>&1", timeout=20)
            text = g.sh(f"cat {sample}").stdout
            open(os.path.join(o.out, f"hang-{i}.sample.txt"), "w").write(text)
            finding("hang", i, step, {"ping_ms": ms})
        reports = new_reports(g, t0, seen)
        for path in reports:
            seen.add(path)
            body = g.sh(f"cat {shlex.quote(path)}", timeout=30).stdout
            name = os.path.basename(path)
            open(os.path.join(o.out, name), "w").write(body)
            kind = report_kind(name)
            if kind == "crash":
                summary["crashes"] += 1
            elif kind == "resource-report":
                summary["resource_reports"] = summary.get("resource_reports", 0) + 1
            finding(kind, i, step, {"report": name})
        if pid is None or ms is None:
            if g.sh("true", timeout=20).returncode != 0:
                summary["guest_lost_at"] = i
                finding("guest-lost", i, step, {})
                break
            if pid is not None:
                # Alive but not answering: record where the main thread is; never start a second copy.
                summary["unresponsive"] = summary.get("unresponsive", 0) + 1
                g.sh(f"sudo -n /usr/bin/sample {pid} 2 -file /tmp/fuzz-unresp-{i}.txt >/dev/null 2>&1 || "
                     f"/usr/bin/sample {pid} 2 -file /tmp/fuzz-unresp-{i}.txt >/dev/null 2>&1", timeout=20)
                open(os.path.join(o.out, f"unresponsive-{i}.sample.txt"), "w").write(g.sh(f"cat /tmp/fuzz-unresp-{i}.txt").stdout)
                finding("unresponsive", i, step, {})
                continue
            summary["relaunches"] += 1
            found: list[str] = []
            for _ in range(10):  # ReportCrash writes the .ips up to ~20 s after the exit
                time.sleep(3)
                found = new_reports(g, t0, seen)
                if found:
                    break
            for path in found:
                seen.add(path)
                name = os.path.basename(path)
                open(os.path.join(o.out, name), "w").write(g.sh(f"cat {shlex.quote(path)}", timeout=30).stdout)
                if report_kind(name) == "crash":
                    summary["crashes"] += 1
                finding(report_kind(name), i, step, {"report": name})
            # The runtime's fatal-error text (e.g. "freed pointer was not the last allocation")
            # goes to stderr only, never into the .ips.
            open(os.path.join(o.out, f"dead-{i}.stderr.txt"), "w").write(
                g.sh("tail -c 8000 /tmp/cmux-fuzz-app.log", timeout=20).stdout)
            if o.insert_dylib:
                open(os.path.join(o.out, f"dead-{i}.dylib.txt"), "w").write(
                    g.sh("cat /tmp/taskalloc-*.log 2>/dev/null", timeout=30).stdout)
            # Why the process ended: its exit status (the guest shell that started it records it; 128+N
            # is signal N: 137 a SIGKILL, e.g. from the system) and the system's log of the last minutes
            # about it (memory kills, a quit request, its own quit lines).
            status = g.sh(f"cat {shlex.quote(exit_file)} 2>/dev/null", timeout=20).stdout.strip()
            died = {"ping_ms": ms, "exit_status": int(status) if status.lstrip("-").isdigit() else None}
            if dead_pid:
                open(os.path.join(o.out, f"dead-{i}.system-log.txt"), "w").write(g.sh(
                    "log show --last 5m --style compact --predicate "
                    + shlex.quote(f'(eventMessage CONTAINS "{dead_pid}") OR (process == "kernel" AND eventMessage CONTAINS[c] "memorystatus")'
                                  ' OR (subsystem == "com.cmuxterm.app.next" AND category == "app.quit")')
                    + " 2>/dev/null | tail -400", timeout=120).stdout)
            finding("dead", i, step, died)
            if diag_reports:
                diag_reports.harvest_stderr(g, f"dead-{i}")
            g.sh(": >/tmp/cmux-fuzz-app.log", timeout=20)
            if not g.launch(exit_file=exit_file, until=run_end):
                # Each further step would relaunch again, a whole deadline each: the walk ends here.
                summary["relaunch_failed"] = {"index": i, "why": g.launch_failure}
                finding("relaunch-failed", i, step, {"why": g.launch_failure})
                break
            if d:
                snapshots.append({"at": f"relaunch-{i}", **diag.snapshot_after_launch(g, o.zones_tool)})

    if coverage_started is not None:
        coverage_seconds += time.time() - coverage_started
    if coverage_skipped:
        summary["coverage_skipped"] = coverage_skipped
    if coverage_steps:
        summary["coverage_steps_run"] = coverage_steps
        summary["coverage_seconds"] = round(coverage_seconds, 1)
        summary["coverage_s_per_step"] = round(coverage_seconds / coverage_steps, 2)

    faults = g.sh(f"log show --style ndjson --start '@{int(t0)}' --predicate "
                  "'(process CONTAINS \"cmux\") AND (messageType == fault)' 2>/dev/null | tail -500", timeout=120)
    open(os.path.join(o.out, "faults.ndjson"), "w").write(faults.stdout)
    summary["faults"] = sum(1 for l in faults.stdout.splitlines() if l.startswith("{"))
    summary.update(coverage.summary())
    if d and diag_reports:
        summary.update(diag_summary(g, d, env, runtime_left, snapshots, diag_reports, o.zones_tool))
    json.dump(summary, open(os.path.join(o.out, "summary.json"), "w"), indent=2)
    print(json.dumps(summary))
    # The fuzz fails on any invariant violation (plans/cmux-next/invariants-DESIGN.md section 5.3).
    return 1 if summary["invariant_violations"] else 0


if __name__ == "__main__":
    sys.exit(main())
