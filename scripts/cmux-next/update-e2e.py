#!/usr/bin/env python3
"""Real auto-update proof for cmux-next NIGHTLY (R114), socket-driven, no display.

Installs an older published nightly-next build into a scratch folder, starts
terminals, asks Sparkle to check (the palette action), waits until the update
is staged (downloaded and verified, delta when the feed has one), then:

  1. quit -> Sparkle installs on quit; the bundle becomes the newer build;
     relaunch -> same version as the feed's newest, the terminal still has
     its output and still answers (the daemon kept it across the update);
  2. (--click) a second older build, staged the same way, installs with the
     one-click action and Sparkle relaunches it by itself.

Rollback refusal is reported PENDING until `cmux update rollback` exists.

Host rules (coordinator 2026-10-04): an Aqua GUI session for this user, no
com.cmuxterm.app.nightly installed or running, no /tmp/cmux-nightly.sock.
Everything this run creates (scratch folder, Sparkle cache, defaults domain,
state dirs) is removed at the end; anything that existed before is kept.

  scripts/cmux-next/update-e2e.py [--feed URL] [--from BUILD] [--to BUILD] [--click] [--keep]
"""
import argparse, json, os, plistlib, re, shutil, socket, subprocess, sys, tempfile, time, urllib.request

BUNDLE_ID = "com.cmuxterm.app.nightly"
SOCKET = "/tmp/cmux-nightly.sock"
HOME = os.path.expanduser("~")

parser = argparse.ArgumentParser()
parser.add_argument("--feed", default="https://files-next.cmux.com/nightly-next/appcast-arm64.xml")
parser.add_argument("--from", dest="from_build", help="installed build (default: the feed's second item)")
parser.add_argument("--to", dest="to_build", help="expected build after the update (default: the feed's newest)")
parser.add_argument("--click", action="store_true", help="also prove the one-click install with an older build")
parser.add_argument("--keep", action="store_true", help="keep the scratch folder (debugging)")
opts = parser.parse_args()

results = []  # (check, PASS|FAIL|PENDING, detail)


def record(check, ok, detail=""):
    state = ok if isinstance(ok, str) else ("PASS" if ok else "FAIL")
    results.append((check, state, detail))
    print(f"[{state}] {check}" + (f": {detail}" if detail else ""), flush=True)


def run(*args, timeout=60, **kw):
    return subprocess.run(list(args), capture_output=True, text=True, timeout=timeout, **kw)


def wait(predicate, seconds, step=0.5):
    deadline = time.time() + seconds
    while time.time() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(step)
    return None


# ---- preflight -------------------------------------------------------------

def preflight():
    if run("launchctl", "print", f"gui/{os.getuid()}").returncode != 0:
        sys.exit("refused: no Aqua GUI session for this user (launchctl print gui/<uid> failed)")
    running = run("pgrep", "-fl", "cmux NIGHTLY.app/Contents/MacOS").stdout.strip()
    if running:
        sys.exit(f"refused: a cmux NIGHTLY runs here:\n{running}")
    installed = [p for p in run("mdfind", f"kMDItemCFBundleIdentifier == '{BUNDLE_ID}'").stdout.splitlines() if p.endswith(".app")]
    if installed:
        sys.exit("refused: an app with bundle id %s is installed: %s" % (BUNDLE_ID, ", ".join(installed)))
    if os.path.exists(SOCKET):
        sys.exit(f"refused: {SOCKET} exists (another nightly's socket)")


# What may be created: compared before/after; only new entries are removed.
STATE_ROOTS = [f"{HOME}/Library/Application Support", f"{HOME}/Library/Caches", f"{HOME}/Library/Preferences",
               f"{HOME}/Library/HTTPStorages", f"{HOME}/Library/Saved Application State", f"{HOME}/Library/WebKit",
               f"{HOME}/.cmuxterm", f"{HOME}/.local/state/cmux", f"{HOME}/.config/cmux", "/tmp"]


def snapshot(depth=3):
    """Every path under the state roots, `depth` levels deep: the nightly's
    daemon writes inside shared folders (cmux-tui/sessions, cmux-next)."""
    found = set()
    for root in STATE_ROOTS:
        if not os.path.exists(root):
            continue
        found.add(root)
        base = root.rstrip("/").count("/")
        for current, dirs, files in os.walk(root):
            level = current.rstrip("/").count("/") - base
            if level >= depth or os.path.basename(current) == "cmux-cli-shims":
                dirs[:] = []
            for name in dirs + files:
                found.add(os.path.join(current, name))
    return found


SESSION_HINTS = [""]


def note_sessions(work):
    """Remembers the daemon session names of the app this run started."""
    SESSION_HINTS[0] += " " + run("pgrep", "-fl", work).stdout


def cleanup(before, work):
    # The app and its daemon end through the app's own quit (end everything),
    # then any process still running from the scratch folder is ended by PID.
    leftovers = [line.split(None, 1) for line in run("pgrep", "-fl", work).stdout.splitlines()]
    # The nightly's daemon session names (cmux-app-<hash>, terminal-hosts-<hash>).
    hashes = set(re.findall(r"(?:cmux-app|terminal-hosts)-([0-9a-f]{12,})", " ".join(c for _, c in leftovers) + SESSION_HINTS[0]))
    for pid, command in leftovers:
        print(f"ending leftover pid {pid}: {command[:120]}")
        try:
            os.kill(int(pid), 15)
        except OSError:
            pass
    run("defaults", "delete", BUNDLE_ID) if f"{HOME}/Library/Preferences/{BUNDLE_ID}.plist" not in before else None
    created = snapshot() - before
    # Only the topmost created path of each tree is removed.
    tops = [p for p in created if os.path.dirname(p) not in created]
    for path in sorted(tops, key=len, reverse=True):
        if not os.path.lexists(path):
            continue
        name = path.lower()
        if path.startswith(work) or "nightly" in name or any(h in name for h in hashes):
            print(f"removing created {path}")
            shutil.rmtree(path, ignore_errors=True) if os.path.isdir(path) and not os.path.islink(path) else os.unlink(path)
    for path in sorted(tops):
        if os.path.lexists(path) and re.search(r"(cmux-app|terminal-hosts)-[0-9a-f]+", path):
            print(f"NOT removed (unknown owner, check by hand): {path}")
    if not opts.keep:
        shutil.rmtree(work, ignore_errors=True)


# ---- feed and install -------------------------------------------------------

USER_AGENT = {"User-Agent": "cmux-update-e2e/1 (Sparkle-compatible test)"}


def fetch(url, timeout=600):
    return urllib.request.urlopen(urllib.request.Request(url, headers=USER_AGENT), timeout=timeout)


def feed_items():
    xml = fetch(opts.feed, timeout=30).read().decode()
    items = []
    for item in re.findall(r"<item>.*?</item>", xml, re.S):
        build = re.search(r"<sparkle:version>(.*?)<", item)
        build = build.group(1) if build else re.search(r'sparkle:version="([^"]+)"', item).group(1)
        url = re.search(r'<enclosure[^>]*url="([^"]+\.dmg)"', item).group(1)
        deltas = {m.group(2): int(m.group(1)) for m in re.finditer(
            r'<enclosure[^>]*length="(\d+)"[^>]*sparkle:deltaFrom="([^"]+)"', item)}
        deltas.update({m.group(1): int(m.group(2)) for m in re.finditer(
            r'<enclosure[^>]*sparkle:deltaFrom="([^"]+)"[^>]*length="(\d+)"', item)})
        items.append({"build": build, "url": url, "deltas": deltas})
    return items


def install(item, folder):
    dmg = os.path.join(folder, "build.dmg")
    print(f"downloading {item['url']}")
    with fetch(item["url"]) as response, open(dmg, "wb") as out:
        shutil.copyfileobj(response, out, 1 << 20)
    mount = os.path.join(folder, "mnt")
    os.makedirs(mount, exist_ok=True)
    attach = run("hdiutil", "attach", "-nobrowse", "-readonly", "-mountpoint", mount, dmg, timeout=300)
    if attach.returncode != 0:
        sys.exit(f"hdiutil attach failed: {attach.stderr}")
    try:
        app_name = next(n for n in os.listdir(mount) if n.endswith(".app"))
        app = os.path.join(folder, app_name)
        run("ditto", os.path.join(mount, app_name), app, timeout=300)
    finally:
        run("hdiutil", "detach", mount, timeout=120)
    os.unlink(dmg)
    return app


def bundle_build(app):
    with open(os.path.join(app, "Contents/Info.plist"), "rb") as f:
        return plistlib.load(f).get("CFBundleVersion")


# ---- app control -------------------------------------------------------------

class App:
    def __init__(self, path, config):
        self.path, self.config = path, config

    @property
    def cli_path(self):
        return os.path.join(self.path, "Contents/Resources/bin/cmux")

    def cli(self, *args, timeout=30):
        env = {"HOME": HOME, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_QUIET": "1"}
        return run(self.cli_path, "--app-socket", SOCKET, *args, timeout=timeout, env=env)

    def cli_json(self, *args):
        r = self.cli("--json", *args)
        try:
            return json.loads(r.stdout)
        except ValueError:
            return {"error": (r.stdout + r.stderr).strip()}

    def rpc(self, method, params=None, timeout=10):
        """One request line on the app control socket (`{"id","method","params"}`)."""
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
                sock.settimeout(timeout)
                sock.connect(SOCKET)
                sock.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
                data = b""
                while not data.endswith(b"\n"):
                    chunk = sock.recv(1 << 16)
                    if not chunk:
                        break
                    data += chunk
            reply = json.loads(data.decode() or "{}")
        except (OSError, ValueError) as error:
            return {"error": str(error)}
        if reply.get("ok") is False:
            return {"error": reply.get("error")}
        return reply.get("result", reply)

    def launch(self, log):
        # LaunchServices starts the app in the user's Aqua session even from
        # SSH; a plain child of an SSH shell has no window server.
        env = {"CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation", "CMUX_NEXT_CONFIG_FILE": self.config}
        args = ["open", "-n", "-g", "--stdout", log.name, "--stderr", log.name]
        for key, value in env.items():
            args += ["--env", f"{key}={value}"]
        opened = run(*args, self.path)
        if opened.returncode != 0:
            print(f"open failed: {opened.stderr}")
            return None
        return self.wait_ready()

    def pids(self):
        return [int(p) for p in run("pgrep", "-f", os.path.join(self.path, "Contents/MacOS/")).stdout.split()]

    def wait_ready(self):
        return wait(lambda: os.path.exists(SOCKET) and self.rpc("updates.status").get("build"), 90)

    def status(self):
        return self.rpc("updates.status")

    def quit(self):
        pids = self.pids()
        self.rpc("action.run", {"id": "quit"})
        if not wait(lambda: not any(run("kill", "-0", str(p)).returncode == 0 for p in pids), 90):
            print(f"quit did not end {pids}; SIGTERM (a normal quit)")
            for p in pids:
                run("kill", "-TERM", str(p))
            wait(lambda: not any(run("kill", "-0", str(p)).returncode == 0 for p in pids), 30)


def staged(app):
    s = app.status()
    return s if s.get("phase") == "installing" else None


def stage_update(app, label):
    app.rpc("action.run", {"id": "palette.checkForUpdates"})
    s = wait(lambda: staged(app), 900, 2)
    log = "\n".join(app.status().get("log", []))
    record(f"{label}: update downloaded, verified and staged", bool(s), f"detected {s.get('detected_version') if s else None}")
    return s, log


def main():
    preflight()
    before = snapshot()
    work = tempfile.mkdtemp(prefix="cmux-update-e2e-")
    config = os.path.join(work, "cmux.json")
    with open(config, "w") as f:
        json.dump({"app": {"quitBehavior": "keep"}, "updates": {"installOnQuit": True}}, f)
    log = open(os.path.join(work, "app.log"), "a")
    try:
        items = feed_items()
        by_build = {i["build"]: i for i in items}
        to_item = by_build[opts.to_build] if opts.to_build else items[0]
        from_item = by_build[opts.from_build] if opts.from_build else items[1]
        print(f"feed {opts.feed}: {len(items)} items; {from_item['build']} -> {to_item['build']}")
        apps = os.path.join(work, "apps")
        os.makedirs(apps)
        path = install(from_item, apps)
        record("installed the older build", bundle_build(path) == from_item["build"], bundle_build(path))

        app = App(path, config)
        record("older build launched, control socket answers", bool(app.launch(log)))
        note_sessions(work)
        app.cli("workspace", "create", "--name", "update-e2e")
        terminal = wait(lambda: next(iter(app.cli_json("terminal", "list") or []), None), 30)
        term = terminal.get("id") if isinstance(terminal, dict) else None
        token = f"before-update-{int(time.time())}"
        app.cli("terminal", term or "-", "write", "--text", f"echo {token}; echo $$ > {work}/shell.pid\n")
        screen = lambda: app.cli("terminal", term or "-", "screen", "read").stdout
        record("terminal ran before the update", bool(term and wait(lambda: token in screen(), 20)), f"terminal {term}")
        shell_pid = wait(lambda: open(f"{work}/shell.pid").read().strip() if os.path.exists(f"{work}/shell.pid") else None, 10)

        s, sparkle_log = stage_update(app, "quit path")
        if to_item["deltas"].get(from_item["build"]):
            # Sparkle keeps the download in its cache until it installs.
            cache = f"{HOME}/Library/Caches/{BUNDLE_ID}"
            files = [f for _, _, names in os.walk(cache) for f in names]
            deltas = [f for f in files if f.endswith(".delta")]
            record("delta update used", bool(deltas), ", ".join(deltas) or f"no .delta in the Sparkle cache ({len(files)} files)")
        app.quit()
        record("install on quit replaced the bundle", bool(wait(lambda: bundle_build(path) == to_item["build"], 300, 2)),
               f"bundle build {bundle_build(path)}")
        record("relaunched", bool(app.launch(log)))
        record("running the newest build", app.status().get("build") == to_item["build"], app.status().get("build"))
        record("terminal output kept across the update", bool(wait(lambda: token in screen(), 20)))
        alive = shell_pid and run("kill", "-0", shell_pid).returncode == 0
        record("terminal shell process survived (daemon kept it)", bool(alive), f"pid {shell_pid}")
        token2 = f"after-update-{int(time.time())}"
        app.cli("terminal", term or "-", "write", "--text", f"echo {token2}\n")
        record("terminal still answers after the update", bool(wait(lambda: token2 in screen(), 20)))

        if opts.click and len(items) > 2:
            app.quit()
            old = next(i for i in items if i["build"] not in (to_item["build"], from_item["build"]))
            shutil.rmtree(path)
            path = install(old, apps)
            app = App(path, config)
            record("click path: older build launched", bool(app.launch(log)))
            stage_update(app, "click path")
            app.rpc("action.run", {"id": "palette.applyUpdateIfAvailable"})
            # Sparkle relaunches the app by itself (no launch environment).
            relaunched = wait(lambda: bundle_build(path) == to_item["build"] and app.status().get("build") == to_item["build"], 300, 2)
            record("click path: one click installed and Sparkle relaunched", bool(relaunched), f"bundle {bundle_build(path)}")

        record("rollback refused when the store schema is newer", "PENDING", "cmux update rollback is not built yet")
    finally:
        try:
            with open(config, "w") as f:
                json.dump({"app": {"quitBehavior": "end-everything"}}, f)
            time.sleep(1)  # the app reloads cmux.json from its file watcher
            app.quit()
        except Exception as error:  # noqa: BLE001 - cleanup continues
            print(f"final quit: {error}")
        log.close()
        cleanup(before, work)
    failed = [r for r in results if r[1] == "FAIL"]
    print(json.dumps({"results": results, "ok": not failed}, indent=1))
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
