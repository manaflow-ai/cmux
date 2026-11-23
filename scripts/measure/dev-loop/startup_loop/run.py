#!/usr/bin/env python3
"""startup_loop's rounds, floors and json (goal dev-loop-ceiling). Started by ../startup_loop.sh; Python 3.9.

One round: a one-line edit of CmuxNextApp/AppDelegate.swift (a launch mark `app.dlc_edit_rK` in
applicationDidFinishLaunching), `scripts/reload.sh --tag dlc-startup --no-global-cli-links` (the tagged Debug
rebuild developers run; it quits the running tagged app before it replaces the bundle), then the relaunch through
launch-ready.swift `type` (startup-tti's harness: LaunchServices open, and the app types one key into its restored
terminal at its first frame and marks its echo). The round ends at `terminal_echo`.

Stages come from a process table sampled every 10 ms (libproc) while reload.sh runs: swift-frontend/swiftc/clang
compiles are compile, ld (and the clang driving it) link, codesign sign, and quit runs from reload's quit waiter
(the python3 child cmux_stop_app_instances forks right after its SIGTERM) to the old app's exit. Overlaps go to the
first of compile, link, sign, quit. launch = process start to the first on-screen window, ready = that window to
terminal_echo, both from launch-ready's LR-RUN. Everything else in the round is unattributed.

  run.py --out OUT --rounds N --repo REPO --edit PATH
  run.py --self-test     (the parsers and the sweep, on any OS)
"""
import argparse, ctypes, datetime, json, os, re, shlex, signal, socket, statistics, subprocess, sys, tempfile, threading, time

TAG = "dlc-startup"
STAGES = ["compile", "link", "sign", "quit", "launch", "ready"]
GRAPH = {"compile": [], "link": ["compile"], "sign": ["link"], "quit": [], "launch": ["sign", "quit"], "ready": ["launch"]}
ANCHOR = 'defer { DebugTimings.markLaunch("did_finish_launching_end") }'
IDLE_S = 15  # after a launch: time for the window, the typed key's echo and the app to go idle before the next step
EXEC_SETTLE_MS = 5000  # a new process's path can still change by exec this long after its start (Watcher.sweep)
LAUNCH_WAIT_S = 180  # LaunchServices' open to the app's process: a few s; 60 s once ran out (step a8b4d181c32ad2c06b3a0126)


def now_ms():
    return time.time() * 1000.0


def log(*parts):
    print("[startup_loop %s]" % datetime.datetime.utcnow().strftime("%H:%M:%S"), *parts, file=sys.stderr, flush=True)


# ---------------------------------------------------------------- process table (macOS libproc)

class Watcher(threading.Thread):
    """Every process seen while running: pid, ppid, executable, start and (approximate) end, ms since the epoch."""

    def __init__(self, interval=0.01):
        super().__init__(daemon=True)
        self.lib = ctypes.CDLL("/usr/lib/libproc.dylib")
        self.interval, self.procs, self.live, self.lock, self.stop_flag = interval, {}, {}, threading.Lock(), False
        self.buf = (ctypes.c_int * 16384)()

    def path(self, pid):
        buf = ctypes.create_string_buffer(4096)
        n = self.lib.proc_pidpath(pid, buf, 4096)
        return buf.value.decode(errors="replace") if n > 0 else ""

    def info(self, pid):
        raw = ctypes.create_string_buffer(136)
        if self.lib.proc_pidinfo(pid, 3, ctypes.c_uint64(0), raw, 136) != 136:  # PROC_PIDTBSDINFO
            return None
        import struct
        fields = struct.unpack("<12I16s32s6I2Q", raw.raw)
        name = fields[13].split(b"\0")[0].decode(errors="replace") or fields[12].split(b"\0")[0].decode(errors="replace")
        return {"pid": pid, "ppid": fields[4], "path": self.path(pid),
                "name": name, "start": fields[20] * 1000.0 + fields[21] / 1000.0, "end": None}

    def sweep(self):
        n = self.lib.proc_listallpids(self.buf, ctypes.sizeof(self.buf))
        t = now_ms()
        pids = set(p for p in self.buf[:max(n, 0)] if p > 0)
        with self.lock:
            for pid in pids:
                if pid not in self.live:
                    rec = self.info(pid)
                    if rec is None:
                        continue
                    key = (pid, rec["start"])
                    self.procs.setdefault(key, rec)
                    self.live[pid] = key
            for pid in list(self.live):
                if pid not in pids:
                    self.procs[self.live.pop(pid)]["end"] = t
                    continue
                # LaunchServices starts an app as xpcproxy, which then execs the app in the same pid: a sweep that saw
                # it first kept xpcproxy's path, so find() never matched the app. 2026-11-22 steps a8b4d181c32ad2c06b3a0126
                # and acf6e3bb243cda244406f29b: "no app process within 180 s" with the app (9278) running. A young
                # process's path is read again until it has been seen for EXEC_SETTLE_MS.
                rec = self.procs[self.live[pid]]
                if t - rec["start"] < EXEC_SETTLE_MS:
                    path = self.path(pid)
                    if path:
                        rec["path"] = path

    def run(self):
        while not self.stop_flag:
            try:
                self.sweep()
            except Exception as error:  # a sweep that fails is skipped, never the run
                log("watcher sweep failed:", error)
            time.sleep(self.interval)

    def between(self, t0, t1):
        with self.lock:
            return [dict(r) for r in self.procs.values() if r["start"] >= t0 - 50 and r["start"] <= t1]

    def find(self, path, since):
        with self.lock:
            hits = [r for r in self.procs.values() if r["path"] == path and r["start"] >= since - 1000]
        return max(hits, key=lambda r: r["start"]) if hits else None


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def wait_exit(pid, timeout_s):
    """Exit time (ms) of pid, sampled every 2 ms; None when it outlived timeout_s."""
    end = time.time() + timeout_s
    while time.time() < end:
        if not alive(pid):
            return now_ms()
        time.sleep(0.002)
    return None


# ---------------------------------------------------------------- stage attribution

def classify(procs):
    """(class, start, end) spans: compile, link and sign processes of a build."""
    by_pid = {}
    for r in procs:
        by_pid.setdefault(r["ppid"], []).append(r)
    spans = []
    for r in procs:
        base = os.path.basename(r["path"]) or r["name"]
        if r["end"] is None:
            continue
        if base in ("ld", "ld64", "ld-prime", "ld64.lld"):
            cls = "link"
        elif base in ("clang", "clang++"):
            cls = "link" if any(os.path.basename(c["path"]) in ("ld", "ld64", "ld-prime") for c in by_pid.get(r["pid"], [])) else "compile"
        elif base in ("swift-frontend", "swiftc", "swift-driver", "swift"):
            cls = "compile"
        elif base == "codesign":
            cls = "sign"
        else:
            continue
        spans.append((cls, r["start"], r["end"]))
    return spans


def sweep(spans, t0, t1, order=("compile", "link", "sign", "quit")):
    """ms per class inside [t0, t1]; a moment two classes share goes to the first in `order`."""
    points = sorted(set([t0, t1] + [min(max(t, t0), t1) for _, a, b in spans for t in (a, b)]))
    total = dict((c, 0.0) for c in order)
    for a, b in zip(points, points[1:]):
        mid = (a + b) / 2
        active = set(c for c, s, e in spans if s <= mid < e)
        for c in order:
            if c in active:
                total[c] += b - a
                break
    return total


def quit_span(procs, reload_pid, old_exit, not_before):
    """reload's quit: from the newest python3 descendant of reload alive when the old app exited, to that exit. Only
    one started after not_before (the end of the last sign): reload's re-exec lock is a python3 that lives throughout."""
    parents = dict((r["pid"], r["ppid"]) for r in procs)

    def under(pid):
        for _ in range(64):
            if pid == reload_pid:
                return True
            pid = parents.get(pid)
            if pid is None:
                return False
        return False
    waiters = [r for r in procs if "ython" in (os.path.basename(r["path"]) or r["name"]) and under(r["pid"])
               and not_before <= r["start"] <= old_exit and (r["end"] is None or r["end"] >= old_exit - 20)]
    if not waiters:
        return None
    return (max(w["start"] for w in waiters), old_exit)


# ---------------------------------------------------------------- floors from the build log

def frontend_command(text, suffix):
    """The swift-frontend command (argv, cwd) whose -primary-file ends with suffix, from an xcodebuild log."""
    cwd = None
    for line in text.splitlines():
        s = line.strip()
        if s.startswith("cd "):
            cwd = shlex.split(s)[1]
        if "-primary-file" not in s or "swift-frontend" not in s:
            continue
        # Xcode writes the command after "builtin-swiftTaskExecution -- " or as a bare line; either way argv[0] is the
        # swift-frontend binary.
        try:
            words = shlex.split(s.split(" -- ", 1)[1] if " -- " in s else s)
        except ValueError:
            continue
        at = next((i for i, w in enumerate(words) if os.path.basename(w) == "swift-frontend"), None)
        if at is None:
            continue
        argv = words[at:]
        prim = [argv[i + 1] for i, a in enumerate(argv[:-1]) if a == "-primary-file"]
        if any(p.endswith(suffix) for p in prim):
            return argv, cwd
    return None, None


def log_census(paths, suffix):
    """What the build logs held, for an error when no compile command matched: size, swift-frontend lines, lines naming
    the edited file, and the first of those."""
    parts = []
    for p in paths:
        if not os.path.exists(p):
            parts.append("%s: missing" % os.path.basename(p))
            continue
        lines = open(p, errors="replace").read().splitlines()
        named = [l.strip() for l in lines if os.path.basename(suffix) in l]
        parts.append("%s: %d lines, %d swift-frontend, %d -primary-file, %d naming %s%s" % (
            os.path.basename(p), len(lines), sum("swift-frontend" in l for l in lines),
            sum("-primary-file" in l for l in lines), len(named), os.path.basename(suffix),
            (", first: " + named[0][:240]) if named else ""))
    return "; ".join(parts) or "no round logs"


def remap_frontend(argv, suffix, tmp):
    """One primary (the file ending in suffix), every output in tmp."""
    prim = [argv[i + 1] for i, a in enumerate(argv[:-1]) if a == "-primary-file"]
    keep = [i for i, p in enumerate(prim) if p.endswith(suffix)][0]
    out, i, o_index = [], 0, 0
    while i < len(argv):
        a = argv[i]
        nxt = argv[i + 1] if i + 1 < len(argv) else None
        if a == "-primary-file":
            if nxt.endswith(suffix):
                out += [a, nxt]
            else:
                out.append(nxt)  # an input still, not compiled here
            i += 2
            continue
        if a == "-o":
            if o_index == keep:
                out += ["-o", os.path.join(tmp, "floor.o")]
            o_index += 1
            i += 2
            continue
        if a == "-supplementary-output-file-map":
            out += [a, remap_output_map(nxt, tmp)]
            i += 2
            continue
        if a == "-index-store-path" or (a.startswith("-emit-") and a.endswith("-path")) or a == "-serialize-diagnostics-path":
            out += [a, os.path.join(tmp, os.path.basename(nxt))]
            i += 2
            continue
        out.append(a)
        i += 1
    return out


def remap_output_map(path, tmp):
    text = open(path).read()
    text = re.sub(r'^(\s+[\w-]+:\s*)"([^"]*)"\s*$', lambda m: '%s"%s"' % (m.group(1), os.path.join(tmp, os.path.basename(m.group(2)))),
                  text, flags=re.M)
    dest = os.path.join(tmp, "output-file-map.yaml")
    open(dest, "w").write(text)
    return dest


def link_commands(text):
    """(argv, cwd) of every Ld task in an xcodebuild log."""
    found, block, cwd = [], False, None
    for line in text.splitlines():
        if line.startswith("Ld "):
            block, cwd = True, None
            continue
        if block:
            s = line.strip()
            if not line.startswith(" ") or not s:
                block = False
                continue
            if s.startswith("cd "):
                cwd = shlex.split(s)[1]
            elif not s.startswith("export ") and " -o " in s:
                found.append((shlex.split(s), cwd))
                block = False
    return found


def remap_link(argv, tmp, k):
    out = list(argv)
    for i, a in enumerate(out[:-1]):
        if a == "-o":
            out[i + 1] = os.path.join(tmp, "floor-link-%d" % k)
        if a == "-dependency_info" and i + 2 < len(out) and out[i + 1] == "-Xlinker":
            out[i + 2] = os.path.join(tmp, "dependency_info-%d.dat" % k)
    return out


WARM_BUILD_S = 4800  # the untimed warm build from a cold slot (see Loop.reload's warm call)


def timed(argv, cwd=None, timeout=600):
    t = time.monotonic()
    p = subprocess.run(argv, cwd=cwd, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=timeout)
    ms = (time.monotonic() - t) * 1000
    if p.returncode != 0:
        raise RuntimeError("%s exited %d: %s" % (os.path.basename(argv[0]), p.returncode, p.stderr.decode(errors="replace")[-600:]))
    return ms


# ---------------------------------------------------------------- the run

class Loop:
    def __init__(self, args):
        self.args, self.repo, self.out = args, args.repo, args.out
        self.edit_path = os.path.join(self.repo, args.edit)
        self.original = open(self.edit_path).read()
        if ANCHOR not in self.original:
            raise RuntimeError("edit anchor not found in %s: %s" % (args.edit, ANCHOR))
        self.notes, self.rounds, self.floors = [], [], dict((s, []) for s in STAGES)
        self.started = now_ms()
        self.watch = Watcher()
        self.launches = []  # Popen of every launch-ready this run started
        self.sock_dir = tempfile.mkdtemp(prefix="dlc.", dir="/tmp")
        self.home = os.path.join(self.out, "home")
        os.makedirs(os.path.join(self.out, "logs"), exist_ok=True)
        self.app = None

    # -- edit
    def set_edit(self, nonce):
        indent = re.search(r"^([ \t]*)" + re.escape(ANCHOR), self.original, re.M).group(1)
        line = '%sDebugTimings.markLaunch("app.dlc_edit_%s")\n' % (indent, nonce)
        text = self.original if nonce is None else self.original.replace(ANCHOR + "\n", ANCHOR + "\n" + line, 1)
        with open(self.edit_path, "w") as f:
            f.write(text)

    def restore(self):
        with open(self.edit_path, "w") as f:
            f.write(self.original)

    # -- reload.sh
    def reload(self, label, timeout_s=1800):
        logpath = os.path.join(self.out, "logs", "reload-%s.out" % label)
        t0 = now_ms()
        with open(logpath, "w") as f:
            p = subprocess.Popen(["scripts/reload.sh", "--tag", TAG, "--no-global-cli-links"], cwd=self.repo, stdout=f,
                                 stderr=subprocess.STDOUT)
            try:
                rc = p.wait(timeout=timeout_s)
            except subprocess.TimeoutExpired:
                p.terminate()
                p.wait(60)
                tail = open(logpath, errors="replace").read()[-800:].strip()
                raise RuntimeError("reload.sh %s ran over %d s: %s" % (label, timeout_s, tail))
        t1 = now_ms()
        text = open(logpath, errors="replace").read()
        if rc != 0:
            raise RuntimeError("reload.sh %s exited %d: %s" % (label, rc, text[-1500:]))
        m = re.findall(r"^App path:[ \t]*\n[ \t]*(\S.*\.app)[ \t]*$", text, re.M)  # reload.sh: the path on the next line
        if not m:
            raise RuntimeError("reload.sh %s printed no App path" % label)
        self.app = m[-1].strip()
        logs = re.findall(r"^==> log: (\S.*?)\s*$", text, re.M)
        build_log = open(logs[-1], errors="replace").read() if logs and os.path.exists(logs[-1]) else ""
        with open(os.path.join(self.out, "logs", "build-%s.log" % label), "w") as f:
            f.write(build_log)
        return p.pid, t0, t1, build_log

    def executable(self):
        plist = os.path.join(self.app, "Contents", "Info.plist")
        name = subprocess.run(["/usr/libexec/PlistBuddy", "-c", "Print :CFBundleExecutable", plist], capture_output=True,
                              text=True).stdout.strip()
        return os.path.join(self.app, "Contents", "MacOS", name)

    # -- launch-ready.swift
    def launch(self, label, settle):
        """Starts launch-ready on the tagged app; returns (Popen, stdout path, request time, app pid)."""
        outp = os.path.join(self.out, "logs", "lr-%s.out" % label)
        env = dict(os.environ, GITHUB_WORKSPACE=self.repo)
        t = now_ms()
        p = subprocess.Popen(["scripts/ci/frame-pacing/console-session.sh", self.lr_bin, self.app, self.home, label,
                              str(settle), os.path.join(self.sock_dir, "app.sock"), "type"], cwd=self.repo,
                             stdout=open(outp, "w"), stderr=open(outp + ".err", "w"), env=env)
        self.launches.append(p)
        exe, pid, end = self.executable(), None, time.time() + LAUNCH_WAIT_S
        while time.time() < end and pid is None:
            rec = self.watch.find(exe, t)
            pid = rec["pid"] if rec else None
            if p.poll() is not None:
                break
            time.sleep(0.05)
        if pid is None:
            # 2026-11-22 step a8b4d181c32ad2c06b3a0126: "launch floor3: no app process within 60 s ()": launch-ready's
            # stderr was empty, and its own failure ("open: ...") goes to stdout. Say both, and what of the app ran.
            with self.watch.lock:
                live = sorted("%d %s" % (r["pid"], os.path.basename(r["path"])) for r in self.watch.procs.values()
                              if r["end"] is None and r["path"].startswith(self.app + "/"))
            tails = " | ".join("%s: %s" % (os.path.basename(f), open(f, errors="replace").read()[-600:].strip())
                               for f in (outp, outp + ".err") if os.path.exists(f))
            raise RuntimeError("launch %s: no app process within %d s (launch-ready %s; %s; app processes live: %s)"
                               % (label, LAUNCH_WAIT_S, "running" if p.poll() is None else "exited %s" % p.returncode,
                                  tails or "no output", ", ".join(live) or "none"))
        return p, outp, t, pid

    def finish_launch(self, label, p, outp):
        try:
            p.wait(timeout=90)
        except subprocess.TimeoutExpired:
            p.terminate()
            try:
                p.wait(10)
            except subprocess.TimeoutExpired:
                p.kill()
            # Its own words, since the step returns only report.json: what it saw before it stopped.
            tails = " | ".join("%s: %s" % (os.path.basename(f), open(f, errors="replace").read()[-600:].strip())
                               for f in (outp, outp + ".err") if os.path.exists(f))
            raise RuntimeError("launch-ready %s did not end 90 s after its app quit (%s)" % (label, tails or "no output"))
        lines = [l for l in open(outp).read().splitlines() if l.startswith("LR-RUN ")]
        if not lines:
            raise RuntimeError("launch-ready %s printed no LR-RUN (%s)" % (label, open(outp + ".err").read()[-800:]))
        row = json.loads(lines[-1][len("LR-RUN "):])
        if row.get("error"):
            raise RuntimeError("launch-ready %s: %s" % (label, row["error"]))
        return row

    @staticmethod
    def launch_ready(row, label):
        marks = row.get("marks") or {}
        window = row.get("window_on_screen")
        echo = marks.get("terminal_echo")
        if window is None:
            raise RuntimeError("launch %s: no window_on_screen" % label)
        if echo is None:
            raise RuntimeError("launch %s: no terminal_echo mark (no restored terminal took the typed key; marks %s)"
                               % (label, sorted(marks)))
        return window, echo - window

    # -- phases
    def prepare(self):
        self.watch.start()
        self.lr_bin = os.path.join(self.out, "launch-ready")
        p = subprocess.run(["xcrun", "swiftc", "-O", "-o", self.lr_bin, "scripts/measure/launch-ready.swift"], cwd=self.repo,
                           capture_output=True, text=True, timeout=600)
        if p.returncode != 0:
            raise RuntimeError("launch-ready.swift did not build: " + p.stderr[-1500:])
        log("warm build (untimed)")
        self.restore()
        # The untimed warm build starts from whatever .build the fleet slot kept, often none: a cold Xcode build of the
        # app ran past 1800 s on 2026-11-21 step 0d5f8be711282a5a8062d811 ("reload.sh warm ran over 1800 s"). Timed
        # rounds keep 1800 s; this one only fills the caches they measure from.
        self.reload("warm", timeout_s=WARM_BUILD_S)
        log("app", self.app)
        # The priming launch: one workspace with its terminal left in front, so every later launch restores a
        # terminal and the `type` probe's key has a PTY to reach (launch-ready.sh front=tab).
        sock = os.path.join(self.sock_dir, "app.sock")
        if os.path.exists(sock):
            os.unlink(sock)
        p, outp, _, pid = self.launch("prime", 40)
        seed = subprocess.run(["/usr/bin/python3", "-I", "scripts/measure/launch-ready-seed.py", sock, "--windows", "1",
                               "--workspaces", "1", "--front", "tab", "--stay"], cwd=self.repo, capture_output=True,
                              text=True, timeout=180)
        with open(os.path.join(self.out, "logs", "seed.out"), "w") as f:
            f.write(seed.stdout + seed.stderr)
        self.finish_launch("prime", p, outp)
        if seed.returncode != 0:
            raise RuntimeError("seed of a terminal front failed: " + (seed.stdout + seed.stderr)[-800:])

    def idle_instance(self, label):
        p, outp, t, pid = self.launch(label, 3600)
        # sleep-ok: the floor measures quitting an idle app; launch-ready reports its window and echo only at exit,
        # so this fixed idle window is the condition itself, not a wait on one.
        time.sleep(IDLE_S)
        if not alive(pid):
            raise RuntimeError("launch %s: app %d ended by itself" % (label, pid))
        return p, outp, pid

    def run_floors_launch(self, n):
        """quit, launch and ready floors: n no-change launches; each is quit idle with one SIGTERM, as reload's quit."""
        for k in range(n):
            label = "floor%d" % (k + 1)
            p, outp, pid = self.idle_instance(label)
            sent = now_ms()
            os.kill(pid, signal.SIGTERM)
            gone = wait_exit(pid, 60)
            if gone is None:
                raise RuntimeError("floor %s: app %d did not quit in 60 s" % (label, pid))
            row = self.finish_launch(label, p, outp)
            launch, ready = self.launch_ready(row, label)
            self.floors["quit"].append(round(gone - sent, 1))
            self.floors["launch"].append(round(launch, 1))
            self.floors["ready"].append(round(ready, 1))
            log(label, "quit", round(gone - sent), "launch", round(launch), "ready", round(ready))

    def run_rounds(self, n):
        old_p, old_out, old_pid = self.idle_instance("old")
        pending = None
        for k in range(1, n + 1):
            label = "r%d" % k
            exit_box = {}
            waiter = threading.Thread(target=lambda: exit_box.update(t=wait_exit(old_pid, 2400)), daemon=True)
            waiter.start()
            t0 = now_ms()
            self.set_edit(label)
            reload_pid, r0, r1, build_log = self.reload(label)
            waiter.join(5)
            old_exit = exit_box.get("t")
            if old_exit is None:
                raise RuntimeError("round %s: the old app %d was still running after reload.sh" % (label, old_pid))
            if pending is None:
                self.finish_launch("old", old_p, old_out)  # the instance round 1 quits: its own launch is not a round
            else:
                self.close_round(pending, self.finish_launch(pending["label"], old_p, old_out))
            procs = self.watch.between(r0, r1)
            signs = [e for c, _, e in classify(procs) if c == "sign" and e <= old_exit]
            span = quit_span(procs, reload_pid, old_exit, max(signs) if signs else r0 + 2000)
            if span is None:
                raise RuntimeError("round %s: no quit waiter under reload.sh at the old app's exit" % label)
            spans = classify(procs) + [("quit", span[0], span[1])]
            build = sweep(spans, t0, r1)
            p, outp, request, pid = self.launch(label, 3600)
            pending = {"label": label, "t0": t0, "reload": [r0, r1], "build": build, "request": request,
                       "build_log": build_log, "procs": len(procs)}
            time.sleep(IDLE_S)
            if not alive(pid):
                raise RuntimeError("round %s: relaunched app %d ended by itself" % (label, pid))
            old_p, old_out, old_pid = p, outp, pid
            log(label, "reload", round(r1 - r0), dict((c, round(v)) for c, v in build.items()))
        os.kill(old_pid, signal.SIGTERM)
        if wait_exit(old_pid, 60) is None:
            raise RuntimeError("last relaunched app %d did not quit in 60 s" % old_pid)
        self.close_round(pending, self.finish_launch(pending["label"], old_p, old_out))

    def close_round(self, pending, row):
        label = pending["label"]
        if ("app.dlc_edit_%s" % label) not in (row.get("marks") or {}):
            raise RuntimeError("round %s: the relaunched app has no app.dlc_edit_%s mark, so it is not the new binary"
                               % (label, label))
        window, ready = self.launch_ready(row, label)
        start = row["start_epoch_ms"]
        echo_at = start + window + ready
        e2e = echo_at - pending["t0"]
        stages = dict((c, round(v, 1)) for c, v in pending["build"].items())
        stages["launch"] = round(window, 1)
        stages["ready"] = round(ready, 1)
        stages["unattributed"] = round(e2e - sum(stages[s] for s in STAGES), 1)
        self.rounds.append({"end_to_end_ms": round(e2e, 1), "stages_ms": stages, "detail": {
            "reload_sh_ms": round(pending["reload"][1] - pending["reload"][0], 1),
            "edit_to_reload_ms": round(pending["reload"][0] - pending["t0"], 1),
            "reload_end_to_open_request_ms": round(pending["request"] - pending["reload"][1], 1),
            "open_request_to_process_start_ms": round(start - pending["request"], 1),
            "finished_launching_ms": row.get("finished_launching"), "first_window_frame_committed_ms":
                (row.get("marks") or {}).get("first_window_frame_committed"),
            "terminal_input_accepted_ms": (row.get("marks") or {}).get("terminal_input_accepted"),
            "processes_sampled": pending["procs"]}})
        log(label, "end_to_end", round(e2e), stages)

    def run_floors_build(self, n):
        tmp = tempfile.mkdtemp(prefix="dlc-floor.", dir=os.environ.get("TMPDIR") or None)
        suffix = "/CmuxNextApp/AppDelegate.swift"
        logs = [os.path.join(self.out, "logs", "build-r%d.log" % k) for k in range(1, len(self.rounds) + 1)]
        text = next((open(p, errors="replace").read() for p in logs if os.path.exists(p)
                     and frontend_command(open(p, errors="replace").read(), suffix)[0]), "")
        argv, cwd = frontend_command(text, suffix)
        if not argv:
            raise RuntimeError("compile floor: no swift-frontend command for AppDelegate.swift in the round build logs (%s)"
                               % log_census(logs, suffix))
        cmd = remap_frontend(argv, suffix, tmp)
        for _ in range(n):
            self.floors["compile"].append(round(timed(cmd, cwd), 1))
        links = link_commands(text)
        if not links:
            raise RuntimeError("link floor: no Ld command in the round build log")
        for _ in range(n):
            self.floors["link"].append(round(sum(timed(remap_link(a, tmp, k), c) for k, (a, c) in enumerate(links)), 1))
        self.notes.append("link floor: %d Ld command(s) from round 1's build log rerun unchanged, outputs in a temp dir: %s"
                          % (len(links), "; ".join(os.path.basename(a[a.index("-o") + 1]) for a, _ in links)))
        clone = os.path.join(tmp, "sign.app")
        subprocess.run(["cp", "-cR", self.app, clone], check=True)
        ident = os.environ.get("CMUX_DEV_SIGN_IDENTITY") or "-"
        for _ in range(n):
            self.floors["sign"].append(round(timed(["/usr/bin/codesign", "--force", "--sign", ident, "--timestamp=none",
                                                    "--generate-entitlement-der", clone]), 1))
        log("build floors", dict((s, self.floors[s]) for s in ("compile", "link", "sign")))

    def cleanup(self):
        """Ends what this run started: launch-ready probes, then the tagged app's own processes (its daemons a
        Keep Sessions quit leaves), by pid: only processes running from this run's app bundle, started after this
        run began."""
        for p in self.launches:
            if p.poll() is None:
                p.terminate()
                try:
                    p.wait(10)
                except subprocess.TimeoutExpired:
                    p.kill()
        if self.app and self.watch.is_alive():
            self.watch.sweep()
            with self.watch.lock:
                mine = [r for r in self.watch.procs.values() if r["end"] is None and r["start"] >= self.started
                        and r["path"].startswith(self.app + "/")]
            for r in mine:
                log("ending pid", r["pid"], r["path"])
                try:
                    os.kill(r["pid"], signal.SIGTERM)
                except (ProcessLookupError, PermissionError):
                    pass
        self.watch.stop_flag = True


def p50(values):
    return round(statistics.median(values), 1) if values else None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out")
    ap.add_argument("--rounds", type=int, default=5)
    ap.add_argument("--repo", default=os.getcwd())
    ap.add_argument("--edit")
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args()
    if args.self_test:
        return self_test()
    commit = subprocess.run(["git", "rev-parse", "HEAD"], cwd=args.repo, capture_output=True, text=True).stdout.strip()
    doc = {"schema": "dev-loop-ceiling/loop/v1", "loop": "startup_loop", "commit": commit or None,
           "host": socket.gethostname().split(".")[0],
           "measured_at": datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
           "target": "cmux NEXT tagged Debug app: scripts/reload.sh --tag %s --no-global-cli-links, one-line edit of %s, "
                     "relaunch through scripts/measure/launch-ready.swift type" % (TAG, args.edit),
           "error": None, "rounds": [], "floors_ms": {}, "graph": GRAPH, "notes": []}
    loop = None
    try:
        loop = Loop(args)
        loop.prepare()
        loop.run_floors_launch(args.rounds)
        loop.run_rounds(args.rounds)
        loop.restore()
        loop.run_floors_build(args.rounds)
    except Exception as error:
        doc["error"] = "%s: %s" % (type(error).__name__, error)
        log("error:", doc["error"])
    finally:
        if loop is not None:
            loop.restore()
            loop.cleanup()
    if loop is not None:
        doc["rounds"], doc["floors_ms"] = loop.rounds, dict((s, v) for s, v in loop.floors.items())
        doc["notes"] = loop.notes
    doc["notes"] += notes(args.rounds)
    if doc["error"] is None:
        short = [s for s in STAGES if len(doc["floors_ms"].get(s, [])) < args.rounds]
        if len(doc["rounds"]) < args.rounds or short:
            doc["error"] = "incomplete: %d rounds, floors short for %s" % (len(doc["rounds"]), short)
    if doc["rounds"]:
        doc["summary_p50_ms"] = {"end_to_end": p50([r["end_to_end_ms"] for r in doc["rounds"]]),
                                 "stages": dict((s, p50([r["stages_ms"][s] for r in doc["rounds"]])) for s in STAGES + ["unattributed"]),
                                 "floors": dict((s, p50(v)) for s, v in doc["floors_ms"].items())}
    with open(os.path.join(args.out, "startup_loop.json"), "w") as f:
        json.dump(doc, f, indent=1)
    print(json.dumps(doc.get("summary_p50_ms", {})))
    return 0 if doc["error"] is None else 1


def notes(n):
    return [
        "Round: T0 just before the one-line edit (a DebugTimings.markLaunch(\"app.dlc_edit_rK\") line after the "
        "did_finish_launching_end defer in CmuxNextApp/AppDelegate.swift); scripts/reload.sh --tag %s --no-global-cli-links "
        "(no --launch: it builds, signs, quits the running tagged app and swaps the bundle); then launch-ready.swift "
        "(startup-tti's harness, mode type, CMUX_NEXT_LAUNCH_TYPE_PROBE=1) opens the new bundle through LaunchServices. "
        "The round ends at the app's terminal_echo mark (the typed key's echo from the restored terminal). The "
        "relaunched app must carry the round's app.dlc_edit_rK mark, or the round fails." % TAG,
        "Before the rounds: one untimed warm reload.sh build, and a priming launch where launch-ready-seed.py leaves "
        "one workspace's terminal in front (launch-ready.sh front=tab), so every launch restores a terminal.",
        "Stages compile/link/sign/quit: a libproc process table sampled every 10 ms while reload.sh runs. compile: "
        "swift-frontend/swiftc/swift-driver and clang without an ld child; link: ld and its clang driver; sign: every "
        "codesign (Xcode's CodeSign tasks and reload.sh's own re-sign of the tagged bundle); quit: from reload's quit "
        "waiter (the python3 child cmux_stop_app_instances forks right after its SIGTERM) to the old app's exit "
        "(kill(pid,0) every 2 ms). Overlaps count once, for the first of compile, link, sign, quit. Processes under "
        "10 ms can be missed; their time is unattributed.",
        "launch: process start (sysctl p_starttime) to the first on-screen window (CGWindowList), ready: that window to "
        "terminal_echo, both from launch-ready's LR-RUN. LaunchServices' open request to process start, xcodebuild's "
        "own planning, reload.sh's script work (bundle clone, plist, xattr, bundle checks, mv) are unattributed; each "
        "round's detail keeps reload_sh_ms, reload_end_to_open_request_ms and open_request_to_process_start_ms.",
        "Floors: compile = round 1's swift-frontend command for AppDelegate.swift from the xcodebuild log, its one "
        "primary file kept, outputs in a temp dir, rerun %d times against the built module; link = the round's Ld "
        "command(s) rerun with no change, outputs in a temp dir; sign = codesign of an APFS clone of the unchanged "
        "tagged bundle with reload.sh's flags; quit = SIGTERM to an idle instance (%d s after launch) to its exit; "
        "launch and ready = the same no-change launches of the built app (launch-ready type), %d each." % (n, IDLE_S, n),
        "graph: quit depends on nothing (the old instance could quit while the build runs; reload.sh runs it after "
        "the sign), launch on sign and quit, ready on launch.",
        "GUI: the step needs a console session (launch-ready opens the app through LaunchServices and reads "
        "CGWindowList); it runs with cmux-ci run --display, and launch-ready through scripts/ci/frame-pacing/console-session.sh.",
        "Path: the brief names scripts/measure/dev-loop/startup_loop.sh for every dev-loop-ceiling loop; "
        "scripts/measure/README.md's registered-bench rule is not followed for that reason.",
    ]


def self_test():
    spans = [("compile", 0, 100), ("link", 90, 150), ("sign", 140, 160), ("quit", 170, 200)]
    got = sweep(spans, 0, 210)
    assert got == {"compile": 100, "link": 50, "sign": 10, "quit": 30}, got
    log_text = "\n".join([
        "SwiftCompile normal arm64 /r/Sources/CmuxNextApp/AppDelegate.swift (in target 'CmuxNextApp')",
        "    cd /r/Packages",
        "    builtin-swiftTaskExecution -- /X/swift-frontend -frontend -c /r/A.swift /r/Sources/CmuxNextApp/AppDelegate.swift "
        "-primary-file /r/A.swift -primary-file /r/Sources/CmuxNextApp/AppDelegate.swift -o /d/A.o -o /d/AppDelegate.o "
        "-index-store-path /d/Index -module-name CmuxNextApp",
        "",
        "Ld /d/cmux\\ DEV.app/Contents/MacOS/cmux\\ DEV normal (in target 'cmux')",
        "    cd /r",
        "    /X/clang -Xlinker -dependency_info -Xlinker /d/dep.dat -o /d/cmux\\ DEV.app/Contents/MacOS/cmux\\ DEV /d/a.o",
        "",
    ])
    argv, cwd = frontend_command(log_text, "/CmuxNextApp/AppDelegate.swift")
    assert cwd == "/r/Packages" and argv[0] == "/X/swift-frontend", (argv, cwd)
    bare = log_text.replace("builtin-swiftTaskExecution -- ", "")
    assert frontend_command(bare, "/CmuxNextApp/AppDelegate.swift") == (argv, cwd), "a bare swift-frontend line"
    assert frontend_command(log_text, "/CmuxNextApp/Other.swift") == (None, None)
    cmd = remap_frontend(argv, "/CmuxNextApp/AppDelegate.swift", "/t")
    assert cmd.count("-primary-file") == 1 and cmd[cmd.index("-o") + 1] == "/t/floor.o" and cmd.count("-o") == 1, cmd
    assert cmd[cmd.index("-index-store-path") + 1] == "/t/Index", cmd
    links = link_commands(log_text)
    assert len(links) == 1 and links[0][1] == "/r", links
    l = remap_link(links[0][0], "/t", 0)
    assert l[l.index("-o") + 1] == "/t/floor-link-0" and "/t/dependency_info-0.dat" in l, l
    procs = [{"pid": 10, "ppid": 1, "path": "/bin/bash", "name": "bash", "start": 0, "end": None},
             {"pid": 11, "ppid": 10, "path": "/usr/bin/python3", "name": "python3", "start": 5, "end": 30},
             {"pid": 12, "ppid": 10, "path": "/usr/bin/python3", "name": "python3", "start": 50, "end": 80},
             {"pid": 13, "ppid": 10, "path": "/usr/bin/codesign", "name": "codesign", "start": 31, "end": 45}]
    assert quit_span(procs, 10, 78, 45) == (50, 78)
    assert quit_span(procs, 10, 78, 60) is None
    assert classify(procs) == [("sign", 31, 45)]
    app_out = "==> reload succeeded in 9s\n\nApp path:\n  /d/Build/Products/Debug/cmux DEV dlc-startup.app\n"
    assert re.findall(r"^App path:[ \t]*\n[ \t]*(\S.*\.app)[ \t]*$", app_out, re.M) == ["/d/Build/Products/Debug/cmux DEV dlc-startup.app"]
    print("self-test ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
