#!/usr/bin/env python3
"""The in-tree pages verifier's live parts on one step's app (split-spring-terminal.py --suite=in-tree-verify).

Runs each part with the step's --app and --tag, in its own folder under --out, and writes --json:
{parts: {name: {cmd, exit, seconds, report}}, host, macos}. Always exits 0 (each part's exit is in the JSON).

  cef-intree      cef-layer-verify.py --mode intree --input cua (--cef-input debug for debug.mouse) (C3, C2 page_views, C17 select/context rows)
  cef-off         cef-layer-verify.py --mode off --input cua (C20: today's path with the switch off)
  overlay-on      overlay-live-check.py --in-tree on (C2, C10)
  overlay-off     overlay-live-check.py --in-tree off (C20)
  live-on         in-tree-live-checks.py --in-tree on (C2 census, C7 focus steal, C9 shortcuts, C16 prompts)
  live-off        in-tree-live-checks.py --in-tree off (C20)
  regressions     in-tree-live-checks.py --in-tree on --checks regressions: only the live rows of in-tree-regressions.md
                  (one per bug found in real use; not in the default parts, live-on already runs them)
  prompts         permission-prompts-live.py --engines chromium with CMUX_IN_TREE_PAGES=1 (C16)
  coverage-on     in-tree-coverage-checks.py --in-tree on: the in-tree-coverage.md rows the parts above do not check
  coverage-off    in-tree-coverage-checks.py --in-tree off (the same rows with the switch off, for parity)
                  (--coverage-checks passes its --checks; not in the default parts)

--parts picks a subset (comma-separated). --live-checks passes in-tree-live-checks.py its --checks (default: all);
--live-env K=V[,K=V] passes it --app-env for each (the app's environment).
"""
import json, os, platform, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
argv = sys.argv[1:]


def value(name, default=None):
    for i, a in enumerate(argv):
        if a == name and i + 1 < len(argv):
            return argv[i + 1]
        if a.startswith(name + "="):
            return a.split("=", 1)[1]
    return default


APP, TAG = value("--app"), value("--tag")
OUT = value("--out") or "/tmp/in-tree-verify"
REPORT = value("--json") or os.path.join(OUT, "report.json")
PARTS = (value("--parts") or "cef-intree,overlay-on,live-on,prompts,cef-off,overlay-off,live-off").split(",")
os.makedirs(OUT, exist_ok=True)

# cef-layer-verify's input: cua (the host's CuaDriver daemon posts real events and takes the screen images with its
# own Screen Recording grant). With `debug`, debug.mouse goes into the cmux window only (never a page window, so the
# OFF rows mean nothing) and screencapture writes no file without the step's own grant (step 9d6f7f59).
CEF_INPUT = value("--cef-input", "cua")


def part(name):
    folder = os.path.join(OUT, name)
    os.makedirs(folder, exist_ok=True)
    env = dict(os.environ)
    report = None
    if name in ("cef-intree", "cef-off"):
        cmd = ["cef-layer-verify.py", "--app", APP, "--tag", TAG, "--out", folder, "--input", CEF_INPUT,
               "--mode", "intree" if name == "cef-intree" else "off"]
    elif name in ("overlay-on", "overlay-off"):
        cmd = ["overlay-live-check.py", "--tag", TAG, "--app", APP, "--out", folder, "--in-tree", name.split("-")[1]]
    elif name == "regressions":
        report = os.path.join(folder, "in-tree-live.json")
        cmd = ["in-tree-live-checks.py", "--app", APP, "--tag", TAG, "--out", folder, "--json", report,
               "--in-tree", "on", "--checks", "regressions"]
    elif name in ("live-on", "live-off"):
        report = os.path.join(folder, "in-tree-live.json")
        cmd = ["in-tree-live-checks.py", "--app", APP, "--tag", TAG, "--out", folder, "--json", report,
               "--in-tree", name.split("-")[1]]
        if value("--live-checks"):
            cmd += ["--checks", value("--live-checks")]
        # --live-env K=V,K2=V2: the launched app's environment (in-tree-live-checks.py --app-env).
        for pair in filter(None, (value("--live-env") or "").split(",")):
            cmd += ["--app-env", pair]
    elif name in ("coverage-on", "coverage-off"):
        report = os.path.join(folder, "in-tree-coverage.json")
        cmd = ["in-tree-coverage-checks.py", "--app", APP, "--tag", TAG, "--out", folder, "--json", report,
               "--in-tree", name.split("-")[1]]
        if value("--coverage-checks"):
            cmd += ["--checks", value("--coverage-checks")]
    elif name == "prompts":
        env["CMUX_IN_TREE_PAGES"] = "1"
        cmd = ["permission-prompts-live.py", "--tag", TAG, "--app", APP, "--out", folder, "--engines", "chromium"]
    else:
        return {"error": f"unknown part {name}"}
    print(f"== in-tree-verify {name}: {' '.join(cmd)}", flush=True)
    started = time.time()
    with open(os.path.join(folder, "stdout.log"), "w") as log:
        proc = subprocess.Popen([sys.executable, os.path.join(HERE, cmd[0])] + cmd[1:], env=env,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        lines = []
        for line in proc.stdout:
            log.write(line)
            lines.append(line.rstrip("\n"))
            print(f"  [{name}] {line}", end="", flush=True)
        code = proc.wait()
    result = {"cmd": cmd, "exit": code, "seconds": round(time.time() - started, 1),
              "rows": [l for l in lines if l.split(" ", 1)[0] in ("PASS", "FAIL", "INFO", "SKIP")][-80:], "tail": lines[-40:]}
    for candidate in [report] + [os.path.join(folder, f) for f in ("report.json", "overlay-live.json", "cef-layer-verify.json")]:
        if candidate and os.path.exists(candidate):
            try:
                with open(candidate) as f:
                    result["report"] = json.load(f)
                break
            except ValueError:
                pass
    print(f"== in-tree-verify {name} exit {code}", flush=True)
    return result


results = {"parts": {}, "host": platform.node(), "macos": platform.mac_ver()[0], "app": APP, "tag": TAG}
try:
    for name in PARTS:
        results["parts"][name] = part(name)
        with open(REPORT, "w") as f:
            json.dump(results, f, indent=1, default=str)
finally:
    # Proof to bring home: every screenshot, and each window recording (debug.window_record) thinned to 30 frames a
    # second, in OUT/evidence.tar.gz (the step's --artifact when it asks for it). Frames become an mp4 at home.
    import tarfile
    with tarfile.open(os.path.join(OUT, "evidence.tar.gz"), "w:gz") as tar:
        for root, _, files in os.walk(OUT):
            frames = sorted(f for f in files if f.startswith("frame-") and f.endswith(".jpg"))
            step = 4 if len(frames) > 600 else 2 if len(frames) > 300 else 1
            keep = set(frames[::step])
            for f in files:
                if f.endswith((".png", ".mp4", ".mov", "frames.json", ".json", ".log")) or f in keep:
                    path = os.path.join(root, f)
                    if path.endswith("evidence.tar.gz") or os.path.getsize(path) > 40 << 20:
                        continue
                    tar.add(path, arcname=os.path.relpath(path, OUT))
print("IN-TREE-VERIFY " + json.dumps({k: v.get("exit") for k, v in results["parts"].items()}), flush=True)
sys.exit(0)
