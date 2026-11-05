#!/usr/bin/env python3
"""cmux live --chromium: save Chromium renderer or Blink C++, and open cmux pages
run that build seconds after it links, with the app, its windows and every
session kept.

  chromium-live.py start  --build-host H --src SRC [--out OUT] [--target T]
                          [--edits DIR] [--app APP] [--foreground]
  chromium-live.py swap   FRAMEWORK_BINARY [--app APP]
  chromium-live.py respawn [--app APP] [--gpu]
  chromium-live.py stop
  chromium-live.py status [--json] [--if-used]

The engine is one framework (Contents/Frameworks/Chromium Embedded
Framework.framework). The app's own process maps it at launch and keeps that
mapping; every renderer, GPU and utility helper maps it when it starts. So:

1. `start` watches --edits (default: the checkout's .cmux-dev/chromium/), where
   a file at chromium/src/<path> is kept as <edits>/<path>. On each save the
   changed files go to the build host's warm tree over rsync (the tree's own
   copies are kept the first time and `stop` puts them back), and the host
   runs an incremental `autoninja -C OUT TARGET` (default target `libcef`).
2. When the framework binary changed, it comes back into a new folder per
   build (rsync, compressed, against the previous build, so only the delta
   crosses), is signed the way scripts/cmux-next/sign-cef.sh signs a dev build
   (ad hoc), and is renamed over the framework binary inside the running app.
   The app keeps the inode it mapped; new helpers map the new file.
3. `respawn` ends the app's renderer processes (extension processes stay;
   --gpu also ends the GPU process, which Chromium restarts on its own) and
   reloads every Chromium page with `cmux browser <tab> reload`. A reload
   after a renderer end keeps the page's history (browser-isolation.md).

`swap` does steps 2 and 3 for a framework built anywhere, for example the
`CEF_PATH` dist of a `cmux-ci build cef` job.

Browser-process code (the parts that run in the app process) needs an app
restart; `cmux live` hands that to the live-mode build swap. Pages running in
WebKit are untouched. Every cycle goes to the state folder's last.json and
history.jsonl, which `status` (and `cmux live status`) prints.
"""

from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import signal
import subprocess
import sys
import time

FRAMEWORK_REL = Path("Contents/Frameworks/Chromium Embedded Framework.framework")
BINARY_NAME = "Chromium Embedded Framework"
# The framework binary as the build lays it out under the out dir (the link's own output is in obj/).
BUILT_BINARY_REL = f"{BINARY_NAME}.framework/Versions/A/{BINARY_NAME}"
STOP_WAIT_S = 900  # stop waits this long for a cycle in flight (a build) to finish
DEFAULT_TARGET = "libcef"
DEFAULT_OUT = "out/Release_GN_arm64"  # what the fleet CEF tree builds; the app links that build
SCAN_INTERVAL_S = 0.25


class LiveError(RuntimeError):
    pass


def log(message: str) -> None:
    print(f"chromium-live: {message}", file=sys.stderr, flush=True)


def state_dir() -> Path:
    if os.environ.get("CMUX_CHROMIUM_LIVE_STATE_DIR"):
        return Path(os.environ["CMUX_CHROMIUM_LIVE_STATE_DIR"])
    home = Path.home()
    if sys.platform == "darwin":
        return home / "Library/Caches/cmux-next/chromium-live"
    return Path(os.environ.get("XDG_CACHE_HOME") or home / ".cache") / "cmux-next/chromium-live"


def run(argv: list[str], *, input: bytes | None = None, check: bool = True,
        timeout: float | None = None) -> subprocess.CompletedProcess:
    proc = subprocess.run(argv, input=input, capture_output=True, timeout=timeout)
    if check and proc.returncode != 0:
        raise LiveError(f"{shlex.join(argv[:5])} ... exited {proc.returncode}: "
                        f"{proc.stderr.decode(errors='replace')[-1500:]}")
    return proc


# --- the app and its helpers ---------------------------------------------------------------------


def parse_ps(text: str) -> list[tuple[int, int, str]]:
    procs = []
    for line in text.splitlines():
        bits = line.strip().split(None, 2)
        if len(bits) == 3 and bits[0].isdigit() and bits[1].isdigit():
            procs.append((int(bits[0]), int(bits[1]), bits[2]))
    return procs


def app_process(app: Path, procs: list[tuple[int, int, str]]) -> int:
    exe_dir = str(app / "Contents/MacOS") + "/"
    hits = [pid for pid, _, args in procs if args.startswith(exe_dir) and "--type=" not in args]
    if len(hits) != 1:
        raise LiveError(f"expected one running {app.name} from {app}, found {len(hits)}")
    return hits[0]


def helpers_to_end(procs: list[tuple[int, int, str]], app_pid: int, gpu: bool) -> list[int]:
    picked = []
    for pid, ppid, args in procs:
        if ppid != app_pid:
            continue
        if "--type=renderer" in args and "--extension-process" not in args:
            picked.append(pid)
        elif gpu and "--type=gpu-process" in args:
            picked.append(pid)
    return picked


def running_app() -> Path:
    """The running cmux app bundle that embeds Chromium (one, else --app is needed)."""
    procs = parse_ps(run(["ps", "-axww", "-o", "pid=,ppid=,args="]).stdout.decode(errors="replace"))
    apps = set()
    for _, _, args in procs:
        if "--type=" in args or ".app/Contents/MacOS/" not in args:
            continue
        bundle = Path(args.split(".app/Contents/MacOS/", 1)[0] + ".app")
        if (bundle / FRAMEWORK_REL).is_dir() and "Helper" not in bundle.name:
            apps.add(bundle)
    if len(apps) != 1:
        raise LiveError(f"found {len(apps)} running cmux apps with Chromium; pass --app")
    return apps.pop()


def framework_binary(app: Path) -> Path:
    path = (app / FRAMEWORK_REL / BINARY_NAME).resolve()
    if not path.is_file():
        raise LiveError(f"{app} embeds no Chromium framework binary")
    return path


def swap_in(new_file: Path, dest: Path) -> None:
    """Sign a copy of new_file next to dest and rename it over dest."""
    tmp = dest.with_name(f".{dest.name}.live-{os.getpid()}")
    tmp.unlink(missing_ok=True)
    if run(["cp", "-c", str(new_file), str(tmp)], check=False).returncode != 0:
        shutil.copy2(new_file, tmp)
    os.chmod(tmp, 0o755)
    if sys.platform == "darwin":
        run(["codesign", "--force", "--sign", "-", str(tmp)])
    os.replace(tmp, dest)


def cmux_cli() -> str:
    return os.environ.get("CMUX_CLI") or shutil.which("cmux") or "cmux"


def browser_tabs() -> list[str]:
    out = run([cmux_cli(), "browser", "page", "tabs", "--all", "--json"], timeout=15).stdout
    data = json.loads(out or b"{}")
    tabs = data.get("tabs") if isinstance(data, dict) else data
    return [str(tab["id"]) for tab in tabs or [] if tab.get("id")]


def runs_on_chromium(tab: str) -> bool:
    """A tab's engine, asked of its page: CEF's user agent says Chrome/, WebKit's does not.

    The tab list carries no engine, so this asks each page while its renderer still runs. A tab
    that does not answer (never loaded, or its renderer already gone) counts as not Chromium: it is
    left alone, and a CEF one shows its own Reload button.
    """
    try:
        proc = run([cmux_cli(), "browser", tab, "eval", "navigator.userAgent"], check=False,
                   timeout=5)
    except subprocess.TimeoutExpired:
        return False
    return proc.returncode == 0 and b"Chrome/" in proc.stdout


def chromium_tabs() -> list[str]:
    tabs = browser_tabs()
    with ThreadPoolExecutor(max_workers=8) as pool:
        engines = list(pool.map(runs_on_chromium, tabs))
    return [tab for tab, chromium in zip(tabs, engines) if chromium]


def respawn(app: Path, gpu: bool = False) -> dict:
    procs = parse_ps(run(["ps", "-axww", "-o", "pid=,ppid=,args="]).stdout.decode(errors="replace"))
    app_pid = app_process(app, procs)
    tabs = chromium_tabs()  # before the renderers end, while every page can still answer
    ended = helpers_to_end(procs, app_pid, gpu)
    for pid in ended:
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    reloaded, failed = 0, []
    for tab in tabs:
        if run([cmux_cli(), "browser", tab, "reload"], check=False, timeout=15).returncode == 0:
            reloaded += 1
        else:
            failed.append(tab)
    return {"app_pid": app_pid, "ended": ended, "reloaded": reloaded, "reload_failed": failed}


def swap(app: Path, built: Path, gpu: bool = False) -> dict:
    t0 = time.monotonic()
    swap_in(built, framework_binary(app))
    t1 = time.monotonic()
    result = respawn(app, gpu)
    t2 = time.monotonic()
    result["seconds"] = {"swap": round(t1 - t0, 3), "respawn": round(t2 - t1, 3)}
    return result


# --- the build host -------------------------------------------------------------------------------

BUILD_SCRIPT = r"""
set -euo pipefail
src="$1"; out="$2"; target="$3"; keep="$4"
mkdir -p "$keep/orig"
cd "$src"
case "$out" in out/*) ;; *) echo "out dir must be out/<name>" >&2; exit 64;; esac
bin="$out/$BINARY"
before=$(stat -f '%m %z %i' "$bin" 2>/dev/null || stat -c '%Y %s %i' "$bin" 2>/dev/null || echo none)
t0=$(date +%s)
set +e
autoninja -C "$out" "$target" < /dev/null > "$keep/build.log" 2>&1
rc=$?
set -e
t1=$(date +%s)
after=$(stat -f '%m %z %i' "$bin" 2>/dev/null || stat -c '%Y %s %i' "$bin" 2>/dev/null || echo none)
sha=""
if [ "$rc" = 0 ] && [ "$before" != "$after" ]; then
  sha=$(shasum -a 256 "$bin" 2>/dev/null | cut -c1-64 || sha256sum "$bin" | cut -c1-64)
fi
printf '{"rc": %d, "build_seconds": %d, "binary": "%s", "sha256": "%s"}\n' "$rc" $((t1 - t0)) "$bin" "$sha"
"""

KEEP_SCRIPT = r"""
set -euo pipefail
src="$1"; keep="$2"; shift 2
mkdir -p "$keep/orig"
cd "$src"
# The tree's own copy of each path, kept once and before the edit lands, so stop can put it back.
for rel in "$@"; do
  case "$rel" in /*|*..*) echo "refusing $rel" >&2; exit 64;; esac
  if [ ! -e "$keep/orig/$rel" ] && [ ! -e "$keep/orig/$rel.absent" ]; then
    mkdir -p "$(dirname "$keep/orig/$rel")"
    if [ -e "$rel" ]; then cp -p "$rel" "$keep/orig/$rel"; else : > "$keep/orig/$rel.absent"; fi
  fi
done
"""

RESTORE_SCRIPT = r"""
set -euo pipefail
src="$1"; keep="$2"
[ -d "$keep/orig" ] || { echo 0; exit 0; }
cd "$src"
n=0
while IFS= read -r -d '' f; do
  rel="${f#$keep/orig/}"
  case "$rel" in
    *.absent) rm -f "${rel%.absent}" ;;
    *) mkdir -p "$(dirname "$rel")"; cp "$f" "$rel" ;;
  esac
  n=$((n + 1))
done < <(find "$keep/orig" -type f -print0)
rm -rf "$keep"
echo "$n"
"""


class Builder:
    def __init__(self, cfg: dict, state: Path):
        self.host = cfg["build_host"]
        self.out = cfg["out"]
        self.target = cfg["target"]
        self.binary_rel = cfg.get("binary_rel", BUILT_BINARY_REL)
        self._src = cfg["src"]
        self._keep = f"~/.cmux-chromium-live/{cfg['session']}"
        self._home: str | None = None
        self.state = state

    def absolute(self, path: str) -> str:
        """A build-host path with a leading ~ made absolute, so nothing is expanded by a shell."""
        if path != "~" and not path.startswith("~/"):
            return path
        if self._home is None:
            self._home = run(self.ssh() + ['printf %s "$HOME"']).stdout.decode().strip()
            if not self._home.startswith("/"):
                raise LiveError(f"{self.host}: could not read its home folder")
        return self._home + path[1:]

    @property
    def src(self) -> str:
        return self.absolute(self._src)

    @property
    def keep(self) -> str:
        return self.absolute(self._keep)

    def ssh(self) -> list[str]:
        control = self.state / "ssh-%C"
        return ["ssh", "-o", "BatchMode=yes", "-o", "ControlMaster=auto",
                "-o", f"ControlPath={control}", "-o", "ControlPersist=900", self.host]

    def remote(self, script: str, *args: str) -> str:
        """Run script on the build host; every argument reaches it as one quoted word."""
        cmd = "bash -s -- " + " ".join(shlex.quote(a) for a in args)
        return run(self.ssh() + [cmd], input=script.encode()).stdout.decode(errors="replace")

    def sync(self, edits: Path, rels: list[str]) -> None:
        listing = "\n".join(rels) + "\n"
        self.remote(KEEP_SCRIPT, self.src, self.keep, *rels)
        files_from = self.state / "sync.list"
        files_from.write_text(listing)
        rsh = shlex.join(self.ssh()[:-1])
        run(["rsync", "-a", "-z", "--files-from", str(files_from), "-e", rsh,
             str(edits) + "/", f"{self.host}:{shlex.quote(self.src + '/')}"])

    def build(self) -> dict:
        script = f"BINARY={shlex.quote(self.binary_rel)}\n" + BUILD_SCRIPT
        text = self.remote(script, self.src, self.out, self.target, self.keep)
        line = [l for l in text.splitlines() if l.startswith("{")][-1]
        return json.loads(line)

    def fetch(self, report: dict, generation: Path) -> Path:
        generation.mkdir(parents=True, exist_ok=True)
        dest = generation / BINARY_NAME
        previous = sorted(p for p in generation.parent.iterdir() if p != generation and
                          (p / BINARY_NAME).is_file())
        if previous:
            shutil.copy2(previous[-1] / BINARY_NAME, dest)  # rsync sends only the delta
        rsh = shlex.join(self.ssh()[:-1])
        run(["rsync", "-a", "-z", "--inplace", "-e", rsh,
             f"{self.host}:{shlex.quote(self.src + '/' + report['binary'])}", str(dest)])
        if sha256(dest) != report["sha256"]:
            raise LiveError("the fetched framework does not match the build host's sha256")
        return dest

    def restore(self) -> int:
        return int(self.remote(RESTORE_SCRIPT, self.src, self.keep).strip() or 0)


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for block in iter(lambda: fh.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def scan(root: Path) -> dict[str, int]:
    seen = {}
    if root.is_dir():
        for p in root.rglob("*"):
            if p.is_file() and not p.name.startswith("."):
                seen[p.relative_to(root).as_posix()] = p.stat().st_mtime_ns
    return seen


def record(state: Path, entry: dict) -> None:
    state.mkdir(parents=True, exist_ok=True)
    (state / "last.json").write_text(json.dumps(entry, indent=2) + "\n")
    with (state / "history.jsonl").open("a") as fh:
        fh.write(json.dumps(entry) + "\n")


def cycle(cfg: dict, state: Path, builder: Builder, rels: list[str], saved_at: float) -> dict:
    edits, app = Path(cfg["edits"]), Path(cfg["app"])
    t = {}
    t0 = time.monotonic()
    builder.sync(edits, rels)
    t["sync"] = time.monotonic() - t0
    t1 = time.monotonic()
    report = builder.build()
    t["build"] = time.monotonic() - t1
    entry = {"at": time.time(), "files": rels, "build": report}
    if report["rc"] != 0:
        entry["error"] = "build failed (see the build host's build.log)"
    elif not report["sha256"]:
        entry["note"] = "the framework did not change (nothing to swap)"
    else:
        t2 = time.monotonic()
        built = builder.fetch(report, state / "builds" / time.strftime("%Y%m%dT%H%M%S"))
        t["fetch"] = time.monotonic() - t2
        result = swap(app, built, cfg.get("gpu", False))
        t.update(result.pop("seconds"))
        entry["respawn"] = result
    t["save_to_reloaded"] = time.time() - saved_at
    entry["seconds"] = {k: round(v, 3) for k, v in t.items()}
    record(state, entry)
    return entry


def pid_file(state: Path) -> Path:
    return state / "watch.pid"


def running_pid(state: Path) -> int | None:
    try:
        pid = int(pid_file(state).read_text().split()[0])
        os.kill(pid, 0)
        return pid
    except (OSError, ValueError, IndexError):
        return None


def watch(cfg: dict, state: Path) -> int:
    builder = Builder(cfg, state)
    edits = Path(cfg["edits"])
    stop = state / "stop"
    stop.unlink(missing_ok=True)
    last = scan(edits)
    log(f"watching {edits} (builds {cfg['target']} on {cfg['build_host']})")
    while not stop.exists():  # stop condition: `chromium-live.py stop`
        time.sleep(SCAN_INTERVAL_S)
        cur = scan(edits)
        rels = sorted(r for r, m in cur.items() if last.get(r) != m)
        last = cur
        if rels:
            saved_at = max(cur[r] for r in rels) / 1e9
            try:
                entry = cycle(cfg, state, builder, rels, saved_at)
                log(summary(entry))
            except (LiveError, subprocess.SubprocessError, OSError) as err:
                record(state, {"at": time.time(), "files": rels, "error": str(err)})
                log(str(err))
    stop.unlink(missing_ok=True)
    return 0


def summary(entry: dict) -> str:
    if entry.get("error"):
        return f"{', '.join(entry.get('files', []))}: {entry['error']}"
    s = entry.get("seconds", {})
    if entry.get("note"):
        return f"{entry['note']} (build {s.get('build', 0):.1f} s)"
    r = entry.get("respawn", {})
    return (f"swapped; {len(r.get('ended', []))} renderers ended, {r.get('reloaded', 0)} pages "
            f"reloaded; save to reloaded {s.get('save_to_reloaded', 0):.1f} s "
            f"(build {s.get('build', 0):.1f}, fetch {s.get('fetch', 0):.1f}, "
            f"swap {s.get('swap', 0):.2f}, respawn {s.get('respawn', 0):.2f})")


def checkout(worktree: str | None) -> Path:
    if worktree:
        return Path(worktree).resolve()
    out = run(["git", "rev-parse", "--show-toplevel"], check=False)
    if out.returncode != 0:
        raise LiveError("not in a cmux checkout; pass --worktree")
    return Path(out.stdout.decode().strip())


def command_start(args) -> int:
    state = state_dir()
    state.mkdir(parents=True, exist_ok=True)
    if running_pid(state):
        raise LiveError("already watching; `chromium-live.py stop` first")
    tree = checkout(args.worktree)
    app = Path(args.app).resolve() if args.app else running_app()
    framework_binary(app)
    edits = Path(args.edits).resolve() if args.edits else tree / ".cmux-dev/chromium"
    edits.mkdir(parents=True, exist_ok=True)
    cfg = {"build_host": args.build_host, "src": args.src, "out": args.out, "target": args.target,
           "binary_rel": args.binary_rel, "edits": str(edits), "app": str(app), "gpu": args.gpu,
           "session": hashlib.sha256(f"{tree}:{time.time()}".encode()).hexdigest()[:12]}
    (state / "config.json").write_text(json.dumps(cfg, indent=2) + "\n")
    if args.foreground:
        pid_file(state).write_text(f"{os.getpid()} {tree}\n")
        try:
            return watch(cfg, state)
        finally:
            pid_file(state).unlink(missing_ok=True)
    logf = (state / "watch.log").open("a")
    proc = subprocess.Popen([sys.executable, __file__, "_watch"], stdout=logf, stderr=logf,
                            stdin=subprocess.DEVNULL, start_new_session=True)
    pid_file(state).write_text(f"{proc.pid} {tree}\n")
    print(f"Watching {edits}: a saved file under it lands at chromium/src/<same path> on "
          f"{args.build_host} and builds {args.target}; open Chromium pages reload on the build. "
          f"`cmux live status` shows the last swap.")
    return 0


def command_stop(_args) -> int:
    state = state_dir()
    pid = running_pid(state)
    if pid:
        (state / "stop").write_text("stop\n")
        # Restore only once the watcher is gone, so a cycle in flight cannot send its edit after.
        deadline = time.monotonic() + STOP_WAIT_S
        while running_pid(state) == pid and time.monotonic() < deadline:
            time.sleep(0.2)
        if running_pid(state) == pid:
            os.kill(pid, signal.SIGTERM)  # our own watcher, started by `start`
            time.sleep(0.5)
    cfg_path = state / "config.json"
    if cfg_path.is_file():
        cfg = json.loads(cfg_path.read_text())
        n = Builder(cfg, state).restore()
        print(f"Stopped. Put back {n} file(s) in the build host's tree; the app keeps the last build "
              "until it restarts.")
        cfg_path.unlink()
    else:
        print("Not watching.")
    return 0


def command_status(args) -> int:
    state = state_dir()
    last = state / "last.json"
    if args.if_used and not last.is_file():
        return 0
    entry = json.loads(last.read_text()) if last.is_file() else None
    watching = running_pid(state) is not None
    if args.json:
        print(json.dumps({"watching": watching, "last": entry}))
        return 0
    print(f"Chromium live: {'watching' if watching else 'not watching'}")
    if entry:
        when = time.strftime("%H:%M:%SZ", time.gmtime(entry["at"]))
        print(f"  last {when}: {summary(entry)}")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="cmd", required=True)
    st = sub.add_parser("start")
    st.add_argument("--build-host", required=True, help="ssh target holding a warm engine tree")
    st.add_argument("--src", required=True, help="chromium/src on the build host")
    st.add_argument("--out", default=DEFAULT_OUT)
    st.add_argument("--target", default=DEFAULT_TARGET)
    st.add_argument("--binary-rel", default=BUILT_BINARY_REL,
                    help="the framework binary below OUT that the target links")
    st.add_argument("--edits")
    st.add_argument("--app")
    st.add_argument("--worktree")
    st.add_argument("--gpu", action="store_true")
    st.add_argument("--foreground", action="store_true")
    sw = sub.add_parser("swap")
    sw.add_argument("binary", type=Path)
    sw.add_argument("--app")
    sw.add_argument("--gpu", action="store_true")
    rs = sub.add_parser("respawn")
    rs.add_argument("--app")
    rs.add_argument("--gpu", action="store_true")
    sub.add_parser("stop")
    stt = sub.add_parser("status")
    stt.add_argument("--json", action="store_true")
    stt.add_argument("--if-used", action="store_true")
    sub.add_parser("_watch")
    args = parser.parse_args(argv)
    try:
        if args.cmd == "start":
            return command_start(args)
        if args.cmd == "stop":
            return command_stop(args)
        if args.cmd == "status":
            return command_status(args)
        if args.cmd == "_watch":
            state = state_dir()
            return watch(json.loads((state / "config.json").read_text()), state)
        app = Path(args.app).resolve() if args.app else running_app()
        if args.cmd == "swap":
            result = swap(app, args.binary.resolve(), args.gpu)
        else:
            result = respawn(app, args.gpu)
        record(state_dir(), {"at": time.time(), "files": [], "respawn": result,
                             "seconds": result.get("seconds", {})})
        print(json.dumps(result))
        return 0
    except LiveError as err:
        log(str(err))
        return 1


if __name__ == "__main__":
    sys.exit(main())
