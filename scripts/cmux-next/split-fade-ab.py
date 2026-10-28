#!/usr/bin/env python3
"""SCRATCH (never lands): the split fade A/B in ONE fleet step on one host (motion-first-principles.md, Part 1).

The step's own app (split-spring.sh, --config=bench: Release optimization with the debug control surface) is the head.
This script builds the base ref's app the same way in a worktree of its own, then runs pane-perf-terminal.py (the
`split` action: Cmd-D and its close) on base and head alternately, --rounds times each, with one recorded pass each,
and writes one report.json plus out.tgz (every run's report, the recordings) under --out.

    split-spring.sh --suite=split-fade-ab --config=bench --vdisplay=120 --base-ref=SHA [--ab-rounds=3] [pane-perf args]
"""
import json, os, re, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True, cwd=HERE).stdout.strip()


def flag(name, default=None):
    for arg in sys.argv[1:]:
        if arg.startswith(name + "="):
            return arg.split("=", 1)[1]
    return default


ours = ("--suite=", "--base-ref=", "--ab-rounds=", "--app=", "--out=", "--json=", "--tag=", "--config=")
args, skip = [], False
raw = sys.argv[1:]
named = {}
for i, arg in enumerate(raw):
    if skip:
        skip = False
        continue
    if arg in ("--app", "--out", "--json", "--tag") and i + 1 < len(raw):
        named[arg] = raw[i + 1]
        skip = True
        continue
    if arg.startswith(ours):
        continue
    args.append(arg)
head_app, out = named["--app"], named["--out"]
base_ref, rounds = flag("--base-ref"), int(flag("--ab-rounds", "3"))
config = flag("--config", "bench")
os.makedirs(out, exist_ok=True)
log = open(os.path.join(out, "ab.log"), "a")


def say(text):
    print(text, flush=True)
    log.write(text + "\n")
    log.flush()


def build_base():
    src = os.path.join(out, "base-src")
    if not os.path.isdir(src):
        if subprocess.run(["git", "cat-file", "-e", base_ref + "^{commit}"], cwd=ROOT).returncode:
            subprocess.run(["git", "fetch", "--no-tags", "origin", base_ref], cwd=ROOT, check=True)
        subprocess.run(["git", "worktree", "add", "--detach", src, base_ref], cwd=ROOT, check=True)
    for sub in ("ghostty", "ghostty-next"):
        if not os.path.exists(os.path.join(src, sub, ".git")):
            subprocess.run(["git", "submodule", "update", "--init", "--depth", "1", sub], cwd=src, check=True)
    kit = os.path.join(src, "GhosttyKit.xcframework")
    same = subprocess.run(["git", "rev-parse", "HEAD:ghostty"], capture_output=True, text=True, cwd=src).stdout == \
        subprocess.run(["git", "rev-parse", "HEAD:ghostty"], capture_output=True, text=True, cwd=ROOT).stdout
    if not os.path.exists(os.path.join(kit, "Info.plist")):
        if same and os.path.exists(os.path.join(ROOT, "GhosttyKit.xcframework", "Info.plist")):
            subprocess.run(["ditto", os.path.join(ROOT, "GhosttyKit.xcframework"), kit], check=True)
        else:
            subprocess.run(["./scripts/download-prebuilt-ghosttykit.sh"], cwd=src, check=True)
    env = dict(os.environ, CMUX_DEV_BACKEND_MODE="local")
    reload_log = os.path.join(out, "base-reload.log")
    # The measure step's log must grow (the controller stops a measurement silent for 45 min): a heartbeat each minute.
    import threading
    done = threading.Event()

    def beat():
        while not done.wait(60):
            size = os.path.getsize(reload_log) if os.path.exists(reload_log) else 0
            say(f"split-fade-ab: building the base app ({size} bytes of reload log)")
    threading.Thread(target=beat, daemon=True).start()
    with open(reload_log, "w") as handle:
        code = subprocess.run(["./scripts/reload.sh", "--tag", "splitbase", "--config", config], cwd=src, env=env,
                              stdout=handle, stderr=subprocess.STDOUT).returncode
    done.set()
    text = open(reload_log, errors="replace").read()
    match = re.findall(r"^App path:\s*\n\s*(.+)$", text, re.M)
    app = match[-1].strip() if match else ""
    if code or not app or not os.path.isdir(app):
        say("split-fade-ab: the base build failed:\n" + "\n".join(l for l in text.splitlines() if "error" in l)[-4000:])
        sys.exit(1)
    return app


say(f"split-fade-ab: base {base_ref}, head app {head_app}, {rounds} rounds, config {config}")
base_app = build_base()
say(f"split-fade-ab: base app {base_app}")
host = subprocess.run(["hostname"], capture_output=True, text=True).stdout.strip()
macos = subprocess.run(["sw_vers", "-productVersion"], capture_output=True, text=True).stdout.strip()
report = {"bench": "pane-perf-terminal.py split (split-fade-ab)", "host": host, "macos": macos, "config": config,
          "base_ref": base_ref, "runs": []}
status = 0
for r in range(rounds):
    for side, app, tag in (("base", base_app, "splitbase"), ("head", head_app, named.get("--tag", "split-spring"))):
        folder = os.path.join(out, f"{side}-r{r + 1}")
        os.makedirs(folder, exist_ok=True)
        extra = ["--record"] if r == 0 else []
        say(f"=== round {r + 1} {side}")
        code = subprocess.run([sys.executable, os.path.join(HERE, "pane-perf-terminal.py"), "--tag", tag, "--app", app,
                               "--out", folder, "--json", os.path.join(folder, "report.json"), "--rounds", "1"]
                              + extra + args).returncode
        status = status or code
        try:
            one = json.load(open(os.path.join(folder, "report.json")))
        except (OSError, ValueError) as error:
            one = {"error": repr(error)}
        report["runs"].append({"side": side, "round": r + 1, "exit": code, "summary": one.get("summary"),
                               "runs": one.get("runs"), "display": one.get("display")})
        json.dump(report, open(named.get("--json") or os.path.join(out, "report.json"), "w"), indent=1)
subprocess.run(["tar", "-czf", os.path.join(out, "out.tgz"), "-C", out, "--exclude", "base-src", "--exclude", "*.app",
                "--exclude", "out.tgz", "."], capture_output=True)
say("REPORT-JSON " + json.dumps([{"side": r["side"], "round": r["round"], "summary": r["summary"]} for r in report["runs"]]))
sys.exit(0)
