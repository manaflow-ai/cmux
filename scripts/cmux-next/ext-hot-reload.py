#!/usr/bin/env python3
"""An installed extension, edited on disk, updates in the running app: the end-to-end read-back test.

Leo, 2026-11-14: "the sdk's stuff should all be hot reloadable from users' builds".

One launched app (BenchApp: its own config, state and customize folder, never the account's). The
extension is the person's customize folder (`CMUX_CUSTOMIZE_DIR`, app id `local/customize`), a
`cmux.section/1` sidebar section, written there as a person or an agent would: `main.js` first, then
`cmux-app.json`. Then each save pattern a real editor uses rewrites it with a new token:

- `in-place`: open, truncate, write, close (VS Code's default, `cat > f`, Python's `open(f, "w")`).
- `atomic-rename`: write a sibling temp file, then rename it over the file (`write-file-atomic`, Zed,
  JetBrains "safe write", `sed -i`, `git checkout`).
- `rename-away`: rename the file to `main.js~`, write a new `main.js`, delete the backup (Vim's
  `backupcopy=no`, Emacs' default backup).
- `manifest-title`: the manifest's section title, saved in place.
- `two-writes`: an editor that writes in two chunks with a pause between them (a slow disk, a large
  file): the second half must not be lost to the first half's reload.

After each save the test reads the section back from the running app's control socket (`apps.views`,
which `cmux app call apps.views` reads too: the words the window's mirror of the scene holds now) until
the new token shows, and records how long that took. A token that does not show within `--timeout`
seconds is a miss. Writes one `EXT_HOT_RELOAD {json}` line per pattern and `--json` with every round;
exits 1 on any miss. `--roots` runs the whole sequence once per place the customize folder is (one launch
each): under the step's TMPDIR, as edit-repaint.py had it, under /tmp, or under $HOME, and records the
volume each is on, so a file system whose saves the watch never hears shows up as that root's misses.

On a fleet Mac (builds the app, then runs this; the script launches an app, so it runs alone):
    cmux-ci run --class exclusive --label measure --script scripts/measure/ext-hot-reload.sh --ref <sha>
"""
import argparse
import json
import os
import statistics
import subprocess
import sys
import tempfile
import time

ROOT = os.path.realpath(os.path.join(os.path.dirname(__file__), "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "scripts", "cmux-next"))
from bench_launch import BenchApp  # noqa: E402

APP = "local/customize"
SECTION = "cmux.section/1"
PATTERNS = ["in-place", "atomic-rename", "rename-away", "manifest-title", "two-writes"]


def manifest(title):
    return {
        "manifestVersion": 2, "id": APP, "name": "Hot reload probe", "version": "1.0.0",
        "description": "A sidebar section the hot reload test rewrites.", "engines": {"cmux": "^2.0"},
        "runtime": {"main": "main.js"},
        "implements": {SECTION: {"export": "renderSection", "title": title, "symbol": "bolt.horizontal",
                                 "options": {"defaultRegion": "top"}}},
    }


def main_js(token):
    return ("// Written by scripts/cmux-next/ext-hot-reload.py.\n"
            "function renderSection() {\n"
            f"  return VStack({{ spacing: 2 }}, [Text({json.dumps(token)}),\n"
            f"    Row({{ title: {json.dumps(token + ' row')}, symbol: \"bolt.horizontal\" }})])\n"
            "}\n"
            "globalThis.__cmuxAppExports = { renderSection }\n")


def write_in_place(path, text):
    with open(path, "w") as f:
        f.write(text)


def write_atomic(path, text):
    temp = f"{path}.tmp-{os.getpid()}-{time.monotonic_ns()}"
    with open(temp, "w") as f:
        f.write(text)
        f.flush()
        os.fsync(f.fileno())
    os.replace(temp, path)


def write_rename_away(path, text):
    backup = path + "~"
    os.replace(path, backup)
    with open(path, "w") as f:
        f.write(text)
    os.unlink(backup)


def write_two_chunks(path, text):
    half = len(text) // 2
    with open(path, "w") as f:
        f.write(text[:half])
        f.flush()
        time.sleep(0.4)
        f.write(text[half:])


def section_views(app):
    reply = app.rpc("apps.views", {"app": APP}, timeout=10)
    if not isinstance(reply, dict) or "views" not in reply:
        return None, reply
    return [v for v in reply["views"] if v.get("interface") == SECTION and not v.get("preview")], reply


def wait_for(app, want, timeout, field="texts"):
    """Polls `apps.views` until a section view shows `want`; (ms from the call, last reply)."""
    started = time.monotonic()
    last = None
    while time.monotonic() - started < timeout:
        views, last = section_views(app)
        for view in views or []:
            shown = view.get(field)
            if (want in shown) if isinstance(shown, list) else shown == want:
                return round((time.monotonic() - started) * 1000, 1), last
        time.sleep(0.025)
    return None, last


def diagnostics(app, customize):
    out = {"files": sorted(os.listdir(customize))}
    env = dict(os.environ, CMUX_SOCKET_PATH=app.socket)
    for args in (["apps", "info", APP], ["apps", "list"]):
        try:
            run = subprocess.run([app.cli, *args], capture_output=True, text=True, timeout=20, env=env)
            out[" ".join(args)] = (run.stdout + run.stderr)[-3000:]
        except (OSError, subprocess.TimeoutExpired) as error:
            out[" ".join(args)] = f"did not run: {error}"
    return out


def volume(path):
    """The mount a folder is on (`df`), so a run says which file system its saves were made on."""
    try:
        run = subprocess.run(["df", "-P", path], capture_output=True, text=True, timeout=10)
        last = run.stdout.strip().splitlines()[-1].split()
        return {"device": last[0], "mount": last[-1]}
    except (OSError, IndexError, subprocess.TimeoutExpired) as error:
        return {"error": str(error)}


def run_root(opts, label, customize):
    """One launched app whose customize folder is `customize`: install, then every pattern's rounds."""
    os.makedirs(customize, exist_ok=True)
    out = os.path.join(opts.out, f"app-{label}")
    app = BenchApp(opts.app, out=out, env={"CMUX_CUSTOMIZE_DIR": customize})
    result = {"customize": customize, "volume": volume(customize), "patterns": {}}
    misses = 0
    main_path = os.path.join(customize, "main.js")
    manifest_path = os.path.join(customize, "cmux-app.json")
    try:
        app.launch()
        time.sleep(3)
        # Install: the script first, then the manifest (its appearing installs the app).
        write_in_place(main_path, main_js("token-install"))
        write_in_place(manifest_path, json.dumps(manifest("Probe title 0"), indent=2))
        ms, last = wait_for(app, "token-install", 30)
        result["install"] = {"ms": ms}
        print(f"ext-hot-reload: {label}: install: {json.dumps(result['install'])}", flush=True)
        if ms is None:
            result["install"]["last_reply"] = last
            result["install"]["diagnostics"] = diagnostics(app, customize)
            print("EXT_HOT_RELOAD " + json.dumps({"root": label, "pattern": "install", "shown": False,
                                                  "last_reply": last}), flush=True)
            return result, 1
        n = 0
        for pattern in opts.patterns.split(","):
            rows = []
            result["patterns"][pattern] = {"rounds": rows}
            for i in range(opts.rounds):
                n += 1
                token = f"token-{pattern}-{n}"
                if pattern == "manifest-title":
                    write_in_place(manifest_path, json.dumps(manifest(f"Probe title {n}"), indent=2))
                    ms, last = wait_for(app, f"Probe title {n}", opts.timeout, field="title")
                else:
                    writer = {"in-place": write_in_place, "atomic-rename": write_atomic,
                              "rename-away": write_rename_away, "two-writes": write_two_chunks}[pattern]
                    writer(main_path, main_js(token))
                    ms, last = wait_for(app, token, opts.timeout)
                row = {"round": i, "shown": ms is not None, "ms": ms}
                if ms is None:
                    misses += 1
                    row["last_reply"] = last
                rows.append(row)
                print(f"ext-hot-reload: {label}: {pattern} round {i}: {json.dumps(row)}", flush=True)
                time.sleep(0.5)
            shown = [r["ms"] for r in rows if r["shown"]]
            summary = {"root": label, "pattern": pattern, "n": len(rows), "missed": len(rows) - len(shown)}
            if shown:
                summary.update(median_ms=round(statistics.median(shown), 1), max_ms=max(shown))
            result["patterns"][pattern]["summary"] = summary
            print("EXT_HOT_RELOAD " + json.dumps(summary), flush=True)
        if misses:
            result["diagnostics"] = diagnostics(app, customize)
        return result, misses
    finally:
        app.stop()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--json", required=True)
    parser.add_argument("--rounds", type=int, default=3, help="saves per pattern")
    parser.add_argument("--timeout", type=float, default=10.0, help="seconds a save may take to show")
    parser.add_argument("--patterns", default=",".join(PATTERNS))
    parser.add_argument("--roots", default="out,tmp",
                        help="where the customize folder is, one launch each: `out` under --out (the step's "
                             "TMPDIR, as edit-repaint.py had it), `tmp` under /tmp, `home` under $HOME")
    opts = parser.parse_args()
    os.makedirs(opts.out, exist_ok=True)
    result = {"host": os.uname().nodename, "app": opts.app, "timeout_s": opts.timeout, "roots": {}}
    misses = 0
    try:
        for label in opts.roots.split(","):
            base = {"out": opts.out, "tmp": "/tmp", "home": os.path.expanduser("~")}[label]
            customize = tempfile.mkdtemp(prefix="cmux-ext-hot-reload.", dir=base)
            try:
                result["roots"][label], missed = run_root(opts, label, os.path.join(customize, "customize"))
            except SystemExit as error:  # a launch that failed (LaunchError) is this root's miss
                result["roots"][label], missed = {"customize": customize, "launch_error": str(error)}, 1
            misses += missed
    finally:
        result["misses"] = misses
        with open(opts.json, "w") as f:
            json.dump(result, f, indent=2)
        print("EXT_HOT_RELOAD_RESULT " + json.dumps({"misses": misses}), flush=True)
    return misses


if __name__ == "__main__":
    sys.exit(1 if main() else 0)
