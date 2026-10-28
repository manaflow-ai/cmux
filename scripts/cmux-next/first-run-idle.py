#!/usr/bin/env python3
"""SCRATCH MEASUREMENT (never lands): what Chromium does at idle on the first launch of a build, and on later ones.

The seqmgr idle benches saw the in-process CEF pump wake the main thread about 32 times/s, and the Chromium helpers
plus the daemon at about 7 % CPU, through the 60 s idle window of the first launch of a newly fetched bundle on a host,
against about 1.5/s and 0.2-0.3 % on later launches. This runs cef-idle-probe.py (Chromium's own trace: tasks per
second by posting location in every process, and the pump counters) in rounds that tell the causes apart:

  fresh    the bundle's Chromium root (<Application Support>/<bundle id>/Chromium) moved aside: Chromium's first run
           (profile creation, component and Safe Browsing downloads, caches made from nothing)
  warm     the root the fresh round made (a later launch)
  upgrade  that root with its `Last Version` set older, as after an app update that changes Chromium's version
  warm2    the root again

Around each round's idle window it reads the CPU time of every process of the bundle (the app, its Chromium helpers,
the daemon) and, after the window, samples the busiest helper for 5 s. The original root is put back at the end.

  first-run-idle.py --apps-sha256 HEX [--rounds fresh,warm,upgrade,warm2] [--settle 20] [--window 60]
"""
import argparse, glob, json, os, plistlib, re, shutil, subprocess, sys, threading, time

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(os.getcwd(), "artifacts", "split-spring")


def note(text):
    print(text, flush=True)


def bundle_id(app):
    with open(os.path.join(app, "Contents", "Info.plist"), "rb") as f:
        return plistlib.load(f).get("CFBundleIdentifier")


def processes(app):
    """{pid: (cpu seconds, command)} of every process whose executable is inside `app` or is the tag's daemon."""
    out = subprocess.run(["ps", "-axo", "pid=,time=,command="], capture_output=True, text=True).stdout
    found = {}
    for line in out.splitlines():
        m = re.match(r"\s*(\d+)\s+(\S+)\s+(.*)", line)
        command = m.group(3)
        if "python" in command.split(" ")[0] or "/usr/bin/sample" in command:
            continue
        if app not in command and "cmuxd" not in command and "cmux-tui" not in command:
            continue
        mm = re.match(r"(?:(\d+)-)?(?:(\d+):)?(\d+):(\d+(?:\.\d+)?)", m.group(2))
        if not mm:
            continue
        secs = int(mm.group(1) or 0) * 86400 + int(mm.group(2) or 0) * 3600 + int(mm.group(3)) * 60 + float(mm.group(4))
        found[int(m.group(1))] = (secs, m.group(3)[-200:])
    return found


def short(command):
    kind = re.search(r"--type=(\S+)", command)
    if kind:
        sub = re.search(r"--utility-sub-type=(\S+)", command)
        return kind.group(1) + (f":{sub.group(1).split('.')[-1]}" if sub else "")
    if re.search(r"/Contents/MacOS/[^/]+$", command.split(" --")[0]) and "Helper" not in command:
        return "app"
    if "cmuxd" in command or "cmux-tui" in command:
        return "daemon"
    return "other:" + os.path.basename(command.split(" --")[0])[:30]


def cpu_window(app, stop, result):
    """CPU seconds per process from the window's start to `stop` (the probe prints CEF-IDLE-PUMP at its end)."""
    start = processes(app)
    t0 = time.monotonic()
    stop.wait()
    end = processes(app)
    seconds = time.monotonic() - t0
    rows = []
    for pid, (cpu, command) in end.items():
        before = start.get(pid, (0.0, command))[0]
        rows.append({"pid": pid, "kind": short(command), "cpu_pct": round(100 * (cpu - before) / seconds, 2), "new": pid not in start})
    rows.sort(key=lambda r: -r["cpu_pct"])
    result.update({"seconds": round(seconds, 1), "processes": rows,
                   "helpers_daemon_pct": round(sum(r["cpu_pct"] for r in rows if r["kind"] != "app"), 2),
                   "app_pct": round(sum(r["cpu_pct"] for r in rows if r["kind"] == "app"), 2)})


def files_written(roots, since):
    """Files under the Chromium roots written since `since`, by top-level folder: what Chromium made in the window."""
    out = {}
    for root in roots:
        for dirpath, _dirs, files in os.walk(root):
            for f in files:
                path = os.path.join(dirpath, f)
                try:
                    st = os.stat(path)
                except OSError:
                    continue
                if st.st_mtime >= since:
                    top = os.path.relpath(path, root).split(os.sep)
                    key = "/".join(top[:2]) if top[0] in ("Default",) or top[0].startswith("Profile-") else top[0]
                    row = out.setdefault(key, [0, 0])
                    row[0] += 1
                    row[1] += st.st_size
    return dict(sorted(out.items(), key=lambda kv: -kv[1][1])[:40])


UBO_ID = "cjpalhdlnbpafiamejdnhcphjbkeiagm"
UBO_STATE = r"""(async () => {
  const ub = self.µBlock;
  const local = await chrome.storage.local.get(null);
  const sizes = {};
  for (const [k, v] of Object.entries(local)) { let n = 0; try { n = JSON.stringify(v).length; } catch (e) {} sizes[k] = n; }
  const reg = local.assetCacheRegistry || {};
  const registry = {};
  for (const [k, v] of Object.entries(reg)) { registry[k] = { writeTime: v && v.writeTime, readTime: v && v.readTime }; }
  let idb = null;
  try { idb = (await indexedDB.databases()).map(d => d.name + ':' + d.version); } catch (e) { idb = String(e); }
  const hs = (ub && ub.hiddenSettings) || {};
  return { now: Date.now(), t0: self.vAPI && vAPI.T0, allReadyAfter: ub && ub.supportStats && ub.supportStats.allReadyAfter,
           supportStats: ub && ub.supportStats, selfieIsInvalid: ub && ub.selfieIsInvalid,
           version: local.version, compiledMagic: local.compiledMagic, selfieMagic: local.selfieMagic,
           storageKeys: sizes, registry, idb,
           hidden: { autoUpdateDelayAfterLaunch: hs.autoUpdateDelayAfterLaunch, selfieDelayInSeconds: hs.selfieDelayInSeconds,
                     cacheStorageAPI: hs.cacheStorageAPI, autoUpdatePeriod: hs.autoUpdatePeriod },
           autoUpdate: ub && ub.userSettings && ub.userSettings.autoUpdate,
           lists: ub && Object.entries(ub.availableFilterLists || {}).filter(([k, v]) => v.off !== true && v.content === 'filters').map(([k]) => k) };
})()"""


def ubo_state(port):
    """uBlock Origin's own state in every profile's background page: whether it loaded from its selfie, its cache's
    registry write times, its storage keys and sizes."""
    sys.path.insert(0, HERE)
    from ext_e2e import cdp
    out = []
    try:
        targets = cdp.targets(port)
    except Exception as error:  # noqa: BLE001
        return [{"error": f"targets: {error}"[:200]}]
    for t in targets:
        if not (t.get("url") or "").startswith(f"chrome-extension://{UBO_ID}/") or t.get("type") != "background_page":
            continue
        try:
            session = cdp.page_session(port, t["id"])
            try:
                out.append({"target": t["id"], "state": session.evaluate(UBO_STATE, timeout=20)})
            finally:
                session.close()
        except Exception as error:  # noqa: BLE001
            out.append({"target": t.get("id"), "error": f"{type(error).__name__}: {error}"[:200]})
    return out


def network_callers(path):
    """The main thread's call paths through Chromium's network and update code in a `sample` report: for each line
    naming SimpleURLLoader, update_client, component_updater, safe_browsing or a URL loader, the line and its eight
    callers (the indented lines above it), deduplicated."""
    try:
        lines = open(path).read().splitlines()
    except OSError:
        return []
    start = next((i for i, l in enumerate(lines) if "com.apple.main-thread" in l), None)
    if start is None:
        return []
    end = next((i for i in range(start + 1, len(lines)) if re.match(r"\s+\d+ Thread_", lines[i]) or not lines[i].strip()), len(lines))
    tree = lines[start:end]
    hits, seen = [], set()
    pattern = re.compile(r"SimpleURLLoader|update_client|component_updater|safe_browsing|URLLoader|NetworkFetcher|Downloader|extensions::|leveldb", re.I)
    def depth(l):
        return len(l) - len(l.lstrip(" +!:|"))
    for i, l in enumerate(tree):
        if not pattern.search(l):
            continue
        chain, d = [l.strip()[:200]], depth(l)
        for j in range(i - 1, 0, -1):
            if depth(tree[j]) < d:
                chain.append(tree[j].strip()[:200])
                d = depth(tree[j])
                if len(chain) >= 9:
                    break
        key = tuple(re.sub(r"^\d+ ", "", c) for c in chain)
        if key in seen:
            continue
        seen.add(key)
        hits.append(chain)
        if len(hits) >= 40:
            break
    return hits


def run_round(name, app, opts, roots):
    """One launch: settle, then an idle window with the pump counters (debug.cef), every process's CPU, the files
    Chromium wrote, a sample of the busiest helper and, on a Debug build, Chromium's own trace (posting locations)."""
    sys.path.insert(0, HERE)
    from bench_launch import BenchApp
    out = os.path.join(OUT, name)
    os.makedirs(out, exist_ok=True)
    env = {}
    port = None
    if opts.trace:
        import socket
        sock = socket.socket()
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
        sock.close()
        env["CMUX_NEXT_CEF_EXTRA_SWITCHES"] = f"remote-debugging-port={port}:remote-allow-origins=*"
    if opts.extra_switch:
        env["CMUX_NEXT_CEF_EXTRA_SWITCHES"] = ":".join(filter(None, [env.get("CMUX_NEXT_CEF_EXTRA_SWITCHES"), opts.extra_switch]))
        report_extra = opts.extra_switch
    else:
        report_extra = None
    bench = BenchApp(app, out=out, env=env)
    report = {"round": name, "extra_switch": report_extra}
    try:
        state = os.path.join(os.path.expanduser("~"), "Library/Application Support/cmux/tags", bench.tag, "tui")
        shutil.rmtree(state, ignore_errors=True)
        t_launch = time.time()
        bench.launch()
        report["launch_s"] = round(time.time() - t_launch, 1)
        # The launch's own first minutes: the pump per 10 s from the launch on, then the window.
        series = []
        last = bench.rpc("debug.cef", timeout=10)
        report["cef_state"] = {k: last.get(k) for k in ("state", "spare_window", "pages_spare_window", "backend", "likely", "trigger")}
        t0 = time.monotonic()
        while time.monotonic() - t0 < opts.settle:
            time.sleep(10)
            cur = bench.rpc("debug.cef", timeout=10)
            a, b = (last.get("pump") or {}), (cur.get("pump") or {})
            series.append({"t_s": round(time.time() - t_launch), **{k: round((b.get(k, 0) - a.get(k, 0)) / 10, 2)
                           for k in b if isinstance(b.get(k), (int, float)) and b.get(k) != a.get(k)}})
            last = cur
        report["settle_series"] = series
        if port:
            report["ubo_after_settle"] = ubo_state(port)
        note(f"FIRSTRUN {name}: settle pump per s every 10 s: {json.dumps(series)[:600]}")
        tracer = None
        if port:
            import importlib.util
            spec = importlib.util.spec_from_file_location("cmux_trace", os.path.join(HERE, "trace.py"))
            trace = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(trace)
            try:
                tracer = trace.ChromiumTracer(port, out)
                tracer.start()
            except Exception as error:  # noqa: BLE001
                report["trace_error"] = str(error)[:300]
                tracer = None
        stopped, cpu = threading.Event(), {}
        # The app's main thread during the window's first 20 s (the component updater starts 60 s after Chromium):
        # what the pump's passes run.
        main_sample = os.path.join(out, "sample-app.txt")
        sampler = subprocess.Popen(["/usr/bin/sample", str(bench.process.pid), "20", "1", "-mayDie", "-file", main_sample],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        watcher = threading.Thread(target=cpu_window, args=(app, stopped, cpu), daemon=True)
        since = time.time()
        before = bench.rpc("debug.cef", timeout=10).get("pump") or {}
        watcher.start()
        w0 = time.monotonic()
        time.sleep(opts.window)
        after = bench.rpc("debug.cef", timeout=10).get("pump") or {}
        seconds = time.monotonic() - w0
        stopped.set()
        watcher.join(timeout=30)
        report["pump_per_s"] = {k: round((after.get(k, 0) - before.get(k, 0)) / seconds, 2)
                                for k in after if isinstance(after.get(k), (int, float))}
        report["pump_after"] = after
        report["cpu"] = cpu
        report["files_written"] = files_written(roots, since)
        if port:
            report["ubo_after_window"] = ubo_state(port)
            for when in ("ubo_after_settle", "ubo_after_window"):
                for entry in report.get(when) or []:
                    st = entry.get("state") or {}
                    now = st.get("now") or 0
                    fresh = {k: round((now - (v.get("writeTime") or 0)) / 1000) for k, v in (st.get("registry") or {}).items()
                             if v.get("writeTime") and now - v["writeTime"] < 600000}
                    note(f"FIRSTRUN {name}: UBO {when} {entry.get('target', '')[:8]} allReadyAfter={st.get('allReadyAfter')!r} "
                         f"selfieIsInvalid={st.get('selfieIsInvalid')} version={st.get('version')} magic={st.get('compiledMagic')}/{st.get('selfieMagic')} "
                         f"autoUpdate={st.get('autoUpdate')} hidden={st.get('hidden')} idb={st.get('idb')} err={entry.get('error')}")
                    note(f"FIRSTRUN {name}: UBO {when} registry entries written in the last 10 min (age s): {json.dumps(fresh)[:900]}")
                    big = sorted((st.get("storageKeys") or {}).items(), key=lambda kv: -kv[1])[:15]
                    note(f"FIRSTRUN {name}: UBO {when} storage.local biggest keys: {json.dumps(big)[:700]}")
        if tracer:
            tracer.stop()
            try:
                import importlib.util
                spec = importlib.util.spec_from_file_location("cef_idle_probe", os.path.join(HERE, "cef-idle-probe.py"))
                cip = importlib.util.module_from_spec(spec)
                spec.loader.exec_module(cip)
                summary = cip.chromium_summary(os.path.join(out, "chromium-trace.json"), seconds)
                counts = summary.pop("task_counts")
                report["tasks"] = summary.get("tasks", [])[:40]
                rows = sorted(((k, v) for k, v in counts.items()), key=lambda kv: -kv[1])[:40]
                report["posted"] = [{"key": list(k) if isinstance(k, tuple) else k, "per_s": round(v / seconds, 2)} for k, v in rows]
            except Exception as error:  # noqa: BLE001
                report["trace_summary_error"] = f"{type(error).__name__}: {error}"[:300]
        busiest = next((r for r in cpu.get("processes", []) if r["kind"] != "app"), None)
        if busiest and busiest["cpu_pct"] > 0.5:
            path = os.path.join(out, f"sample-{busiest['kind'].replace(':', '_')}.txt")
            subprocess.run(["/usr/bin/sample", str(busiest["pid"]), "5", "1", "-mayDie", "-file", path],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            report["sample_of"] = busiest
            try:
                text = open(path).read().splitlines()
                report["sample_head"] = [l for l in text if re.match(r"\s*[+!:| ]*\d+ ", l)][:120]
            except OSError:
                pass
        sampler.wait(timeout=60)
        report["app_main_hits"] = network_callers(main_sample)
    except BaseException as error:  # noqa: BLE001
        report["error"] = f"{type(error).__name__}: {error}"[:500]
        note(f"FIRSTRUN {name}: ERROR {report['error']}")
    finally:
        try:
            bench.stop()
        except Exception:  # noqa: BLE001
            pass
    cpu = report.get("cpu") or {}
    note(f"FIRSTRUN {name}: pump per s {json.dumps(report.get('pump_per_s'))[:500]}")
    note(f"FIRSTRUN {name}: CPU app {cpu.get('app_pct')} %, helpers+daemon {cpu.get('helpers_daemon_pct')} % over {cpu.get('seconds')} s; "
         + ", ".join(f"{r['kind']} {r['cpu_pct']}" for r in cpu.get("processes", [])[:10]))
    note(f"FIRSTRUN {name}: files written in the window (count, bytes): {json.dumps(report.get('files_written'))[:700]}")
    for row in (report.get("posted") or [])[:25]:
        note(f"   [{name}] POSTED {json.dumps(row)[:300]}")
    if report.get("sample_of"):
        note(f"   [{name}] SAMPLE of {report['sample_of']}")
        for l in (report.get("sample_head") or [])[:70]:
            note(f"   [{name}] S {l[:220]}")
    for chain in (report.get("app_main_hits") or [])[:25]:
        note(f"   [{name}] MAIN " + " <- ".join(chain[:6]))
    return report


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", help="the fetched app (split-spring.sh passes it); else --apps-sha256 is fetched")
    parser.add_argument("--apps-sha256")
    parser.add_argument("--rounds", default="warm,newcopy,fresh,warm2",
                        help="warm: the root as it is; newcopy: a new copy of the bundle at a new path (an update's new"
                             " binary, same root); fresh: no Chromium root; warm2: again")
    parser.add_argument("--trace", action="store_true", help="Chromium's own trace over CDP (Debug builds only)")
    parser.add_argument("--extra-switch", default="", help="a Chromium switch for every round (Debug builds: CMUX_NEXT_CEF_EXTRA_SWITCHES)")
    parser.add_argument("--settle", type=float, default=20)
    parser.add_argument("--window", type=float, default=60)
    opts, _ = parser.parse_known_args()
    os.makedirs(OUT, exist_ok=True)
    if opts.app and not opts.apps_sha256:
        app, fetched = os.path.abspath(opts.app), "split-spring.sh (see its reload stub line: worker cache or download)"
    else:
        sha = opts.apps_sha256.split(",")[0]
        got = subprocess.run([sys.executable, os.path.join(HERE, "fleet-app-fetch.py"), "--sha256", sha,
                              "--dest", os.path.join(OUT, "apps", sha[:12])], capture_output=True, text=True)
        note(got.stderr.strip()[-400:])
        if got.returncode != 0:
            sys.exit(f"first-run-idle: fetch failed: {got.stderr[-400:]}")
        app, fetched = got.stdout.strip().splitlines()[-1], got.stderr.strip()[-300:]
    ident = bundle_id(app)
    import pwd
    # The app reads Application Support from the account's home (Foundation), or from $HOME: a step's HOME is a
    # scratch folder, so both candidates are moved aside and the report says which one the app filled.
    homes = []
    for home in (pwd.getpwuid(os.getuid()).pw_dir, os.path.expanduser("~")):
        if home not in homes:
            homes.append(home)
    roots = [os.path.join(h, "Library", "Application Support", ident, "Chromium") for h in homes]
    result = {"bench": "first-run-idle", "host": os.uname().nodename, "app": app, "bundle_id": ident, "roots": roots,
              "roots_existed": [os.path.isdir(r) for r in roots], "fetch": fetched, "rounds": {}}
    note(f"FIRSTRUN app {app} bundle {ident} roots {roots} existed {result['roots_existed']}")
    saved = []
    try:
        for root in roots:
            if os.path.isdir(root):
                shutil.rmtree(root + ".first-run-idle-saved", ignore_errors=True)
                os.rename(root, root + ".first-run-idle-saved")
                saved.append(root)
        current = app
        for index, name in enumerate(opts.rounds.split(",")):
            if name == "fresh":
                for root in roots:
                    shutil.rmtree(root, ignore_errors=True)
            if name == "newcopy":
                copy_dir = os.path.join(OUT, f"copy-{index}")
                os.makedirs(copy_dir, exist_ok=True)
                current = os.path.join(copy_dir, os.path.basename(app))
                subprocess.run(["ditto", app, current], check=True)
                note(f"FIRSTRUN newcopy: {current}")
            result["rounds"][name] = run_round(name, current, opts, roots)
            result["rounds"][name]["roots_used"] = [r for r in roots if os.path.isdir(r)]
            result["rounds"][name]["root_entries"] = {r: sorted(os.listdir(r))[:60] for r in roots if os.path.isdir(r)}
            note(f"FIRSTRUN {name}: Chromium root in use {result['rounds'][name]['roots_used']}")
            with open(os.path.join(OUT, "report.json"), "w") as f:
                json.dump(result, f, indent=1)
    finally:
        for root in saved:
            shutil.rmtree(root, ignore_errors=True)
            os.rename(root + ".first-run-idle-saved", root)
        with open(os.path.join(OUT, "report.json"), "w") as f:
            json.dump(result, f, indent=1)


if __name__ == "__main__":
    main()
