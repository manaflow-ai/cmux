#!/usr/bin/env python3
"""Seeded UI fuzzer and feature tour for cmux-next inside a macOS VM.

Runs on the VM host. Input goes through the VM's VNC server (rfb.py), so the
guest needs no Accessibility grant. App actions marked for the CLI run through
the guest's bundled `cmux` over SSH; GUI-only actions run by their shortcut or
by typing their title into the Cmd+Shift+P palette. Every step is logged to
steps.jsonl; `--replay steps.jsonl` repeats a run step for step.

After every step it pings the app (a hang is a ping over --hang-ms) and checks
for new crash reports. On a hang it samples the main thread; on a crash it
copies the .ips, takes a VNC screenshot and relaunches the app.

Example (vm.sh does this for you):
  fuzz.py --ssh admin@192.168.64.5 --vnc 127.0.0.1:5901:secret \
          --app "/Applications/cmux NIGHTLY.app" --seed 7 --steps 2000 --out out/15
"""

from __future__ import annotations

import argparse
import json
import os
import random
import shlex
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
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
              "terminate", "cloud", "firewall", "snapshot", "billing", "purchase", "subscribe")
TEXT = ["hello", "ls -la\n", "echo $((RANDOM))\n", "https://example.com\n", "# Title\n", "🙂 ünïcødé",
        "x" * 300, "\n\n", "printf '\\e[31mred\\n'\n", "yes | head -2000\n"]


class Guest:
    """The VM over one multiplexed SSH connection; the app's CLI runs in the guest."""

    def __init__(self, target: str, app: str, ssh_opts: list[str]):
        self.target, self.app = target, app
        self.cli = f"{app}/Contents/Resources/bin/cmux"
        self.binary = ""
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

    def ping_ms(self, timeout: float) -> int | None:
        """Main-thread round trip in ms, timed in the guest; None when nothing answers.

        A ping that runs past `timeout` returns the timeout (a hang), not None.
        """
        cmd = (f"/usr/bin/python3 -I -c 'import subprocess,shlex,sys,time\nt=time.time()\ntry:\n"
               f"  r=subprocess.run(shlex.split(sys.argv[1]),capture_output=True,timeout={timeout})\n"
               f"  print(int((time.time()-t)*1000) if r.returncode==0 else -1)\n"
               f"except subprocess.TimeoutExpired:\n  print({int(timeout * 1000)})' {shlex.quote(self._cli(['app', 'ping']))}")
        r = self.sh(cmd.replace("\\n", "\n"), timeout + 15)
        try:
            v = int(r.stdout.strip().splitlines()[-1])
            return None if v < 0 else v
        except (ValueError, IndexError):
            return None

    def pid(self) -> int | None:
        r = self.sh(f"pgrep -nf {shlex.quote(self.app + '/Contents/MacOS/')}")
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
        self.sh(f"open -a {shlex.quote(self.app)}")
        return True

    def install_helpers(self) -> None:
        src = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "winfo.js")).read()
        subprocess.run(self.base + ["cat > /tmp/fuzz-winfo.js"], input=src, text=True, capture_output=True, timeout=30)

    def launch(self, deadline: float = 180) -> bool:
        """Start the app with the automation socket open to SSH clients; wait for a ping."""
        plist = self.sh(f"/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' {shlex.quote(self.app + '/Contents/Info.plist')}")
        self.binary = f"{self.app}/Contents/MacOS/{plist.stdout.strip()}"
        before = time.time()
        self.sh(f"CMUX_NEXT_SOCKET_MODE=automation nohup {shlex.quote(self.binary)} "
                f">>/tmp/cmux-fuzz-app.log 2>&1 </dev/null & disown; true")
        while time.time() - before < deadline:
            r = self.sh("ls -t /tmp/cmux-*.sock 2>/dev/null | head -1")
            self.socket = r.stdout.strip()
            if self.socket and self.ping_ms(3) is not None:
                # Bring the window forward so VNC keys reach it.
                self.sh(f"open -a {shlex.quote(self.app)}")
                return True
            time.sleep(2)
        return False


def load_actions(g: Guest) -> list[dict]:
    r = g.cmux(["action", "list"], timeout=30)
    acts = json.loads(r.stdout)["actions"]
    keep = []
    for a in acts:
        ident = (a["id"] + " " + a.get("cli_name", "")).lower().replace(".", "")
        if a.get("debug_only") or a["surfaces"].get("mcp") == "endsApp":
            continue
        if a.get("category") in ("cloud", "remote") or any(w in ident for w in SKIP_WORDS):
            continue
        keep.append(a)
    return keep


def random_args(rng: random.Random, a: dict) -> list[str] | None:
    out: list[str] = []
    for arg in a.get("arguments", []):
        kind, req = arg.get("kind"), arg.get("required")
        if kind == "enum" and arg.get("choices") and (req or rng.random() < 0.5):
            out += [f"--{arg['name']}", str(rng.choice(arg["choices"])["value"])]
        elif kind in ("string", "text") and (req or rng.random() < 0.3):
            out += [f"--{arg['name']}", rng.choice(["fuzz", "a", "Ω≈ç", "x" * 80])]
        elif kind in ("int", "integer", "number") and (req or rng.random() < 0.3):
            out += [f"--{arg['name']}", str(rng.choice([0, 1, 2, -1, 999]))]
        elif kind == "bool" and rng.random() < 0.3:
            out += [f"--{arg['name']}", rng.choice(["true", "false"])]
        elif req:
            return None
    return out


def plan_step(rng: random.Random, actions: list[dict]) -> dict:
    r = rng.random()
    if r < 0.30:
        a = rng.choice([x for x in actions if x.get("cli")] or actions)
        args = random_args(rng, a)
        if a.get("cli") and args is not None:
            step = {"kind": "action", "id": a["id"], "args": args}
            kinds = [t for t in a.get("targets", []) if t in TARGET_LISTS]
            if kinds and rng.random() < 0.8:
                # Resolved against the live list in UI order at run time (n modulo its length), so a replay
                # with the same seed and build picks the same object.
                step["target"] = {"kind": rng.choice(kinds), "n": rng.randrange(1 << 16)}
            return step
        return {"kind": "palette", "title": a["title"]}
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
}


def resolve_target(g: Guest, pick: dict) -> str | None:
    try:
        items = json.loads(g.cmux(TARGET_LISTS[pick["kind"]]).stdout)
    except (ValueError, TypeError, KeyError):
        return None
    ids = [x["id"] for x in items if isinstance(x, dict) and "id" in x] if isinstance(items, list) else []
    return ids[pick["n"] % len(ids)] if ids else None


def run_step(step: dict, g: Guest, vnc: RFB) -> str:
    k = step["kind"]
    if k == "action":
        target = resolve_target(g, step["target"]) if step.get("target") else None
        r = g.cmux(["action", "run", step["id"], *(["--target", target] if target else []), *step["args"]], timeout=20)
        return f"rc={r.returncode} {(r.stdout or r.stderr).strip()[:160]}"
    if k == "palette":
        vnc.chord("cmd+shift+p")
        time.sleep(0.3)
        vnc.type_text(step["title"][:40])
        time.sleep(0.3)
        vnc.chord("return")
        return "palette"
    if k == "key":
        vnc.chord(step["chord"])
    elif k == "type":
        vnc.type_text(step["text"])
    elif k in ("click", "drag", "scroll"):
        rect = g.window_rect_px(vnc)
        if rect is None:
            return "no window"
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
    return "ok"


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


def new_reports(g: Guest, since: float, seen: set[str]) -> list[str]:
    r = g.sh("find ~/Library/Logs/DiagnosticReports /Library/Logs/DiagnosticReports -maxdepth 1 "
             f"-newermt @{int(since)} \\( -name '*cmux*' -o -name '*acpmux*' -o -name '*.hang' \\) 2>/dev/null")
    return [p for p in r.stdout.split() if p and p not in seen]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--ssh", required=True, help="guest user@ip")
    ap.add_argument("--vnc", required=True, help="host:port[:password]")
    ap.add_argument("--app", default="/Applications/cmux NIGHTLY.app")
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--steps", type=int, default=1000)
    ap.add_argument("--hang-ms", type=int, default=1000)
    ap.add_argument("--out", required=True)
    ap.add_argument("--replay", help="steps.jsonl from an earlier run")
    ap.add_argument("--no-tour", action="store_true")
    ap.add_argument("--probe-keys", action="store_true", help="only find the Command keysym, then exit")
    ap.add_argument("--shot-every", type=int, default=50, help="VNC screenshot every N steps (0: never)")
    ap.add_argument("--ssh-opt", action="append", default=[], help="extra ssh option (repeatable)")
    o = ap.parse_args()

    os.makedirs(o.out, exist_ok=True)
    host, port, *pw = o.vnc.split(":")
    vnc = RFB(host, int(port), pw[0] if pw else None)
    g = Guest(o.ssh, o.app, o.ssh_opt)
    osver = g.sh("sw_vers -productVersion").stdout.strip()
    if g.sh(f"test -d {shlex.quote(o.app)}").returncode != 0:
        sys.exit(f"no app at {o.app!r} in the guest")
    g.install_helpers()
    if not g.launch():
        sys.exit("the app did not answer a ping within the launch deadline")
    actions = load_actions(g)
    rng = random.Random(o.seed)
    if o.replay:
        steps = [json.loads(l)["step"] for l in open(o.replay) if l.strip()]
    else:
        tour = [] if o.no_tour else [{"kind": "palette", "title": t} for t in TOUR]
        steps = tour + [plan_step(rng, actions) for _ in range(o.steps)]

    summary_input = check_input(g, vnc)
    print("input check:", json.dumps(summary_input), flush=True)
    if o.probe_keys or not summary_input["ok"]:
        try:
            open(os.path.join(o.out, "input-check.png"), "wb").write(vnc.screenshot_png())
        except Exception:
            pass
    if o.probe_keys:
        return 0 if summary_input["ok"] else 1
    log = open(os.path.join(o.out, "steps.jsonl"), "w")
    findings = open(os.path.join(o.out, "findings.jsonl"), "a")
    seen: set[str] = set()
    t0 = time.time() - 5
    summary = {"os": osver, "seed": o.seed, "steps": 0, "crashes": 0, "hangs": 0, "relaunches": 0,
               "actions_known": len(actions), "input": summary_input}

    def finding(kind: str, i: int, step: dict, extra: dict) -> None:
        rec = {"kind": kind, "os": osver, "seed": o.seed, "index": i, "step": step, "t": time.time(), **extra}
        findings.write(json.dumps(rec) + "\n")
        findings.flush()
        try:
            open(os.path.join(o.out, f"{kind}-{i}.png"), "wb").write(vnc.screenshot_png())
        except Exception as e:  # screenshot is best effort
            rec["screenshot_error"] = str(e)

    for i, step in enumerate(steps):
        started = time.time()
        if g.refocus():
            summary["refocus"] = summary.get("refocus", 0) + 1
        try:
            note = run_step(step, g, vnc)
        except (ConnectionError, OSError) as e:
            note = f"vnc error {e}"
            vnc = RFB(host, int(port), pw[0] if pw else None)
        ms = g.ping_ms(timeout=max(5, o.hang_ms / 1000 * 5))
        log.write(json.dumps({"i": i, "step": step, "note": note, "ping_ms": ms,
                              "dt": round(time.time() - started, 3)}) + "\n")
        log.flush()
        summary["steps"] = i + 1
        if o.shot_every and i % o.shot_every == 0:
            try:
                open(os.path.join(o.out, f"step-{i:05d}.png"), "wb").write(vnc.screenshot_png())
            except Exception as e:  # best effort
                print("screenshot failed:", e, flush=True)
        pid = g.pid()
        if ms is not None and ms > o.hang_ms and pid:
            summary["hangs"] += 1
            sample = os.path.join("/tmp", f"fuzz-sample-{i}.txt")
            g.sh(f"sample {pid} 2 -file {sample} >/dev/null 2>&1", timeout=20)
            text = g.sh(f"cat {sample}").stdout
            open(os.path.join(o.out, f"hang-{i}.sample.txt"), "w").write(text)
            finding("hang", i, step, {"ping_ms": ms})
        reports = new_reports(g, t0, seen)
        for path in reports:
            seen.add(path)
            body = g.sh(f"cat {shlex.quote(path)}", timeout=30).stdout
            name = os.path.basename(path)
            open(os.path.join(o.out, name), "w").write(body)
            kind = "hang-report" if name.endswith(".hang") else "crash"
            if kind == "crash":
                summary["crashes"] += 1
            finding(kind, i, step, {"report": name})
        if pid is None or ms is None:
            if g.sh("true", timeout=20).returncode != 0:
                summary["guest_lost_at"] = i
                finding("guest-lost", i, step, {})
                break
            summary["relaunches"] += 1
            finding("dead", i, step, {"ping_ms": ms})
            g.launch()

    faults = g.sh(f"log show --style ndjson --start '@{int(t0)}' --predicate "
                  "'(process CONTAINS \"cmux\") AND (messageType == fault)' 2>/dev/null | tail -500", timeout=120)
    open(os.path.join(o.out, "faults.ndjson"), "w").write(faults.stdout)
    summary["faults"] = sum(1 for l in faults.stdout.splitlines() if l.startswith("{"))
    json.dump(summary, open(os.path.join(o.out, "summary.json"), "w"), indent=2)
    print(json.dumps(summary))
    return 0


if __name__ == "__main__":
    sys.exit(main())
