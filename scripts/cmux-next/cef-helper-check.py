#!/usr/bin/env python3
"""Chromium children of a tagged cmux-next app start from their own helper apps.

usage: cef-helper-check.py --app APP --tag TAG --json OUT.json [--out DIR] [--release-signing]

Launches APP (clean environment, no activation), opens a Chromium tab on a page
that runs JavaScript, and checks:

  * every `--type=renderer` child runs from "<app> Helper (Renderer).app" and
    every `--type=gpu-process` child from "<app> Helper (GPU).app" (the helpers
    that carry com.apple.security.cs.allow-jit), never from the plain helper;
  * the page's JavaScript ran (browser.page.eval answers);
  * no renderer died ("V8 process OOM ... CodeRange" in the CEF log).

--release-signing first signs the plain "<app> Helper.app" the way a release
does: hardened runtime and no allow-jit (ad hoc, plus disable-library-validation
so it still loads the ad hoc framework). Then a renderer that starts from the
plain helper cannot reserve V8's JIT code range and dies with SIGTRAP: the
"Aw, Snap! Error code: SIGTRAP" of the cef-156.0.15-cmux.43 NIGHTLY, also in a
Debug build. A window image goes to DIR/window.png when the host can capture.

Exit 0: all checks pass. Exit 1: a check failed (JSON names it).
"""
import argparse, base64, glob, json, os, plistlib, subprocess, sys, tempfile, time, urllib.parse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bench_cli_storm import Client  # noqa: E402

# openBrowser takes http(s) and file URLs, not data: URLs ("is not a URL cmux can open").
PAGE_HTML = ("<!doctype html><title>start</title><script>document.title='js-ran-'+(6*7)</script>"
             "<h1 style='font:48px sans-serif'>cmux helper check: JavaScript ran</h1>")
FRAME = (40, 40, 1200, 800)


def helpers(app):
    fw = os.path.join(app, "Contents", "Frameworks")
    plain = sorted(p for p in glob.glob(os.path.join(fw, "* Helper.app")))
    if not plain:
        raise SystemExit(f"no '* Helper.app' in {fw}")
    return fw, plain[0]


def release_sign(plain_helper, scratch):
    ent = os.path.join(scratch, "plain-helper.entitlements")
    with open(ent, "wb") as f:
        plistlib.dump({"com.apple.security.cs.disable-library-validation": True}, f)
    subprocess.run(["codesign", "--force", "--sign", "-", "--options", "runtime", "--entitlements", ent, plain_helper],
                   check=True, capture_output=True)
    info = subprocess.run(["codesign", "-dv", plain_helper], capture_output=True, text=True).stderr
    return "runtime" in info


def children(root_pid):
    rows = subprocess.run(["ps", "-axo", "pid=,ppid=,command="], capture_output=True, text=True).stdout.splitlines()
    procs = {}
    for row in rows:
        parts = row.strip().split(None, 2)
        if len(parts) == 3:
            procs[int(parts[0])] = (int(parts[1]), parts[2])
    out, todo = [], [root_pid]
    while todo:
        pid = todo.pop()
        for child, (ppid, cmd) in procs.items():
            if ppid == pid:
                out.append((child, cmd))
                todo.append(child)
    return out


def kind_of(cmd):
    for arg in cmd.split(" --")[1:]:
        if arg.startswith("type="):
            return arg.split("=", 1)[1].split()[0]
    return None


def capture_window(sock, path):
    """debug.window_snapshot of the main window (Debug builds; no Screen Recording needed), else screencapture."""
    try:
        Client(sock, timeout=60).call("debug.window_snapshot", {"kind": "main", "path": path})
        if os.path.exists(path) and os.path.getsize(path) > 0:
            return True
    except Exception:
        pass
    x, y, w, h = FRAME
    r = subprocess.run(["screencapture", "-x", "-R", f"{x},{y},{w},{h}", path], capture_output=True, text=True)
    return r.returncode == 0 and os.path.exists(path)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--app", required=True)
    ap.add_argument("--tag", required=True)
    ap.add_argument("--json", required=True)
    ap.add_argument("--out", default=tempfile.mkdtemp(prefix="cef-helper-check."))
    ap.add_argument("--release-signing", action="store_true")
    ap.add_argument("--settle", type=float, default=8.0)
    opts = ap.parse_args()
    app = os.path.realpath(opts.app)
    os.makedirs(opts.out, exist_ok=True)
    page_path = os.path.join(opts.out, "page.html")
    with open(page_path, "w") as f:
        f.write(PAGE_HTML)
    page = "file://" + urllib.parse.quote(page_path)
    fw, plain = helpers(app)
    res = {"app": app, "release_signing": opts.release_signing, "checks": {}}
    if opts.release_signing:
        res["plain_helper_hardened"] = release_sign(plain, opts.out)

    with open(os.path.join(app, "Contents", "Info.plist"), "rb") as f:
        exe = os.path.join(app, "Contents", "MacOS", plistlib.load(f)["CFBundleExecutable"])
    sock = f"/tmp/cmux-debug-{opts.tag}.sock"
    if os.path.exists(sock):
        os.unlink(sock)
    home = os.environ["HOME"]
    env = {"HOME": home, "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
           "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1",
           "CMUX_NEXT_SOCKET_MODE": "automation", "CMUX_NEXT_TEST_WINDOW_SCREEN": "last",
           "CMUX_NEXT_TEST_WINDOW_FRAME": ",".join(map(str, FRAME))}
    started = time.time()
    proc = subprocess.Popen([exe], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    res["pid"] = proc.pid
    try:
        t0 = time.monotonic()
        while not os.path.exists(sock):
            if time.monotonic() - t0 > 180 or proc.poll() is not None:
                raise SystemExit(f"no socket {sock} (exit {proc.poll()})")
            time.sleep(0.2)
        def call(method, params=None):
            try:
                return Client(sock).call(method, params or {})
            except (OSError, ValueError) as error:
                return {"ok": False, "error": str(error)}

        def rpc(method, params=None):
            reply = call(method, params)
            return (reply.get("result") or {}) if isinstance(reply, dict) and reply.get("ok") else {}

        def focused_pane():
            panes = [p for w in (rpc("debug.surfaces").get("windows") or []) for p in w.get("panes", [])]
            return next((p for p in panes if p.get("focused")), None)

        def wait_for(predicate, seconds):
            deadline = time.monotonic() + seconds
            while time.monotonic() < deadline:
                value = predicate()
                if value:
                    return value
                time.sleep(0.5)
            return None

        # A fresh profile opens on Home (first-run import or Chief's chat), where a browser cannot
        # open: a focused terminal tab gives the Chromium tab a pane, as cef-tab-bench.py does.
        wait_for(lambda: rpc("debug.windows").get("windows"), 60)
        res["new_tab_reply"] = call("action.run", {"action": "newTab", "args": {"name": "cef-helper-check"},
                                                   "focus": True, "origin": "script"})
        res["terminal_pane"] = bool(wait_for(lambda: (focused_pane() or {}).get("kind") == "terminal", 60))
        time.sleep(1)  # test harness: the shell prompt draws before the next tab opens
        res["open_reply"] = call("action.run", {"action": "openBrowser.chromium", "args": {"url": page},
                                                "focus": True, "origin": "script"})

        def title_ran():
            value = rpc("browser.page.eval", {"script": "document.title"}).get("value")
            return value if isinstance(value, str) and value.startswith("js-ran-") else None

        title = wait_for(title_ran, 30)
        if not title:
            # cef-tab-bench.py's path: the app's own new-browser command in the focused pane.
            res["bench_create_reply"] = call("debug.new_tab", {"action": "bench_create", "command": "new_browser",
                                                               "run": "openBrowser", "url": page})
            title = wait_for(title_ran, 45)
        res["focused_kind"] = (focused_pane() or {}).get("kind")
        res["title"] = title
        time.sleep(opts.settle)  # renderers that die do so ~0.6 s after launch; let any crash loop show
        rows = [(pid, kind_of(cmd), cmd) for pid, cmd in children(proc.pid)]
        renderer_suffix = " Helper (Renderer).app/Contents/MacOS/"
        # Chromium 156 (gpu_process_host.cc) starts the GPU process from the " (GPU)" helper only when SwiftShader
        # is allowed, and from the plain helper otherwise (the default). Both are right; the Renderer helper is not.
        gpu_helpers = (" Helper.app/Contents/MacOS/", " Helper (GPU).app/Contents/MacOS/")
        res["processes"] = [{"pid": p, "type": k, "exe": c.split(" --")[0]} for p, k, c in rows if k]
        renderers = [r for r in res["processes"] if r["type"] == "renderer"]
        gpus = [r for r in res["processes"] if r["type"] == "gpu-process"]
        c = res["checks"]
        c["renderer_running"] = bool(renderers)
        c["renderers_use_renderer_helper"] = bool(renderers) and all(renderer_suffix in r["exe"] for r in renderers)
        c["gpu_uses_plain_or_gpu_helper"] = all(any(h in r["exe"] for h in gpu_helpers) for r in gpus)
        c["javascript_ran"] = title == "js-ran-42"
        log_hits = 0
        for log in glob.glob(os.path.join(home, "Library/Application Support/*", "Chromium", "cef.log")):
            if os.path.getmtime(log) >= started:
                with open(log, errors="replace") as f:
                    log_hits += sum("Failed to reserve virtual memory for CodeRange" in line for line in f)
        res["coderange_oom_lines"] = log_hits
        c["no_v8_coderange_oom"] = log_hits == 0
        shot = os.path.join(opts.out, "window.png")
        if capture_window(sock, shot):
            res["window_png"] = shot
            with open(shot, "rb") as f:
                res["window_png_base64"] = base64.b64encode(f.read()).decode()
    finally:
        proc.terminate()
        try:
            proc.wait(20)
        except subprocess.TimeoutExpired:
            proc.kill()
    res["ok"] = all(res["checks"].values()) and bool(res["checks"])
    os.makedirs(os.path.dirname(os.path.abspath(opts.json)), exist_ok=True)
    with open(opts.json, "w") as f:
        json.dump(res, f, indent=1)
    print(json.dumps({k: v for k, v in res.items() if k not in ("processes", "window_png_base64")}, indent=1))
    for p in res.get("processes", []):
        print(f"  {p['pid']:>7} {p['type']:<12} {p['exe']}")
    return 0 if res["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
