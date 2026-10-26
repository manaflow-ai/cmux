#!/usr/bin/env python3
"""MQ-input-turn-hops: the main-thread hops that run beside a person's input, as a queue of fix tasks
(plans/cmux-next/chrome-parity/p04-input.md, task 022).

Launches a DEBUG or bench build of cmux NEXT (scripts/cmux-next/bench_launch.py), types into a zsh terminal the
way typing-frame-bench.py's terminal surface does (idle, then with --busy printing terminals), reads
`debug.input` action `hops` since launch, symbolicates each Swift site (image + offset) to file:line with the
image's dSYM (atos), and writes one row per unique site:

  site, lane (swift | nonswift), count, kinds, origin, symbol, file, line, allowed

A Swift row is a main-actor job enqueued while input was pending or dispatching (the MainJobGate hook, task 021),
named by its first frame past the Swift runtime and libdispatch. A nonswift row is a kind of main run-loop
callout (timer, main queue or port, sources) timed during input turns. Each row is one task: remove the hop, or
justify it with `// input-hop-allow: <why>` on the site's line or the line above it (the row is then
`allowed`). typing-frame-bench.py quits its app when it ends, so this script launches its own.

  input-turn-hops.py --app APP --out DIR [--json artifacts/input-turn-hops.json] [--input real|debug]
      [--keys 200] [--busy 4] [--dsym PATH ...]
  input-turn-hops.py --from-reply REPLY.json --app APP [--json FILE]   (symbolicate a saved hops reply)
  input-turn-hops.py --self-test

Runs on a host with a GUI session (an owned mini with a console): --input real posts CGEvents, which needs the
Accessibility grant for the process that runs it.
"""
import argparse, glob, json, os, re, socket, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
SOURCES = os.path.join(REPO, "Packages/macOS/CmuxNext/Sources")
ALLOW = "input-hop-allow:"
ATOS_LINE = re.compile(r"^(?P<symbol>.*?) \(in (?P<image>[^)]+)\)(?: \((?P<file>[^():]+):(?P<line>\d+)\))?\s*$")
# ANSI virtual key codes (Carbon kVK_ANSI_*) of the typed keys (sidebar-churn-typing.py's table).
KEYCODES = {"a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
            "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45,
            "m": 46}
BUSY = "while :; do printf '%s busy line %s %s\\n' $RANDOM $RANDOM $RANDOM; done"


def note(text):
    print(text, flush=True)


# MARK: symbolication


def image_files(app, dsyms):
    """name -> candidate files to symbolicate an image of that name with: the given dSYMs, dSYMs next to the
    app, then the bundle's own binaries (a DEBUG build keeps its debug info in them)."""
    files = {}
    found = list(dsyms or [])
    if app:
        found += glob.glob(os.path.join(os.path.dirname(app), "*.dSYM"))
        found += glob.glob(os.path.join(app, "Contents", "**", "*.dSYM"), recursive=True)
    for dsym in found:
        for dwarf in glob.glob(os.path.join(dsym, "Contents/Resources/DWARF/*")):
            files.setdefault(os.path.basename(dwarf), []).append(dwarf)
    if app:
        for path in glob.glob(os.path.join(app, "Contents", "MacOS", "*")) + \
                glob.glob(os.path.join(app, "Contents", "Frameworks", "**", "*"), recursive=True):
            if os.path.isfile(path) and not os.path.islink(path):
                files.setdefault(os.path.basename(path), []).append(path)
    return files


def uuids(path):
    """The LC_UUIDs of `path` (dwarfdump --uuid), upper case."""
    try:
        out = subprocess.run(["dwarfdump", "--uuid", path], capture_output=True, text=True, timeout=60).stdout
    except (OSError, subprocess.TimeoutExpired):
        return set()
    return {m.upper() for m in re.findall(r"UUID: ([0-9A-Fa-f-]{36})", out)}


def pick_file(frame, files, uuid_cache):
    """The file whose UUID is the frame's image UUID (any candidate when the frame has none)."""
    candidates = files.get(frame.get("image") or "", [])
    want = (frame.get("image_uuid") or "").upper()
    for path in candidates:
        if not want:
            return path
        if path not in uuid_cache:
            uuid_cache[path] = uuids(path)
        if want in uuid_cache[path]:
            return path
    return None


def parse_atos(line):
    """(symbol, file, line) of one atos output line; file and line None without debug info."""
    match = ATOS_LINE.match(line.strip())
    if not match:
        return (line.strip() or None, None, None)
    number = match.group("line")
    return (match.group("symbol"), match.group("file"), int(number) if number else None)


def atos(path, offsets):
    """One atos line per image offset (each a return address: the call is the byte before it)."""
    load = 0x100000000
    addresses = [hex(load + max(0, offset - 1)) for offset in offsets]
    try:
        out = subprocess.run(["atos", "-o", path, "-l", hex(load), *addresses], capture_output=True, text=True,
                             timeout=120).stdout
    except (OSError, subprocess.TimeoutExpired):
        return [None] * len(offsets)
    lines = out.splitlines()
    return lines + [None] * (len(offsets) - len(lines))


def symbolicate(rows, files):
    """Adds symbol, file and line to each Swift row with a frame (one atos run per image)."""
    uuid_cache, by_file = {}, {}
    for row in rows:
        frame = row.get("frame")
        if row.get("lane") != "swift" or not frame:
            continue
        path = pick_file(frame, files, uuid_cache)
        if path:
            by_file.setdefault(path, []).append(row)
        else:
            row["symbol"] = frame.get("nearest_symbol")
    for path, group in by_file.items():
        for row, line in zip(group, atos(path, [r["frame"]["offset"] for r in group])):
            symbol, file, number = parse_atos(line) if line else (None, None, None)
            row["symbol"] = symbol or row["frame"].get("nearest_symbol")
            row["file"], row["line"] = file, number


# MARK: the queue


def source_index(root=SOURCES):
    """basename -> paths of the Swift sources under `root`."""
    index = {}
    for path in glob.glob(os.path.join(root, "**", "*.swift"), recursive=True):
        index.setdefault(os.path.basename(path), []).append(path)
    return index


def is_allowed(file, line, index, read=None):
    """Whether the site's line or the line above it says `// input-hop-allow:`; None when the file is not one
    unique source of the repo (a system frame, a name two packages share)."""
    paths = index.get(os.path.basename(file or ""), [])
    if not line or len(paths) != 1:
        return None
    try:
        lines = (read or (lambda p: open(p, encoding="utf-8", errors="replace").read()))(paths[0]).splitlines()
    except OSError:
        return None
    window = lines[max(0, line - 2):line]
    return any(ALLOW in text for text in window)


def queue(reply, index, read=None):
    """The MQ-input-turn-hops document from a symbolicated `debug.input hops` reply."""
    rows = []
    for row in reply.get("rows") or []:
        entry = {key: row.get(key) for key in ("site", "lane", "count", "kinds", "origin")}
        if row.get("lane") == "swift":
            entry.update(symbol=row.get("symbol"), file=row.get("file"), line=row.get("line"),
                         priorities=row.get("priorities") or [], frame=row.get("frame"))
            entry["allowed"] = is_allowed(row.get("file"), row.get("line"), index, read)
        else:
            entry.update(total_ms=row.get("total_ms"), max_ms=row.get("max_ms"), allowed=False)
        rows.append(entry)
    rows.sort(key=lambda r: (r.get("allowed") is True, -(r.get("count") or 0), r.get("site") or ""))
    return {"queue": "MQ-input-turn-hops", "since_launch": reply.get("since_launch"),
            "recorded": reply.get("recorded"), "dropped": reply.get("dropped"),
            "sites_overflow": reply.get("sites_overflow"), "rows": rows,
            "unallowed": sum(1 for r in rows if r.get("allowed") is not True)}


# MARK: the run


def rpc(path, method, params=None, timeout=30):
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(timeout)
        conn.connect(path)
        conn.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = conn.recv(1 << 22)
            if not chunk:
                break
            buf += chunk
        conn.close()
        reply = json.loads(buf)
    except (OSError, ValueError) as error:
        return {"error": str(error)}
    return reply.get("result") if reply.get("ok") else {"error": reply.get("error")}


def post_real_key(cg, key):
    """One real key press at the HID event tap (the window server queues it for the frontmost app)."""
    for down in (True, False):
        event = cg.CGEventCreateKeyboardEvent(None, KEYCODES[key], down)
        cg.CGEventPost(0, event)  # kCGHIDEventTap
        cg.CFRelease(event)


def core_graphics():
    import ctypes, ctypes.util
    cg = ctypes.cdll.LoadLibrary(ctypes.util.find_library("CoreGraphics"))
    cg.CGEventCreateKeyboardEvent.restype = ctypes.c_void_p
    cg.CGEventCreateKeyboardEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint16, ctypes.c_bool]
    cg.CGEventPost.argtypes = [ctypes.c_uint32, ctypes.c_void_p]
    cg.CFRelease.argtypes = [ctypes.c_void_p]
    return cg


def run_app(opts):
    """Launches the app, types --keys keys idle and --keys under load, returns the hops reply since launch."""
    sys.path.insert(0, HERE)
    from bench_launch import BenchApp, LaunchError
    app = os.path.realpath(opts.app.rstrip("/"))
    bench = BenchApp(app, out=opts.out, config={}, window=(40, 40, 1400, 900), log_name="app-input-turn-hops.log")
    try:
        try:
            bench.launch(timeout=180, settle=5.0)
        except LaunchError as error:
            raise SystemExit(f"input-turn-hops: the app did not come up: {error.reason}")
        sock, config = bench.socket, os.path.join(bench.scratch, "cmux.json")
        cli = os.path.join(app, "Contents/Resources/bin/cmux")
        env = {k: v for k, v in os.environ.items() if not k.startswith("CMUX_")}
        env["CMUX_NEXT_CONFIG_FILE"] = config

        def run_cli(*args):
            return subprocess.run([cli, "--app-socket", sock, *args], env=env, capture_output=True, text=True,
                                  timeout=60, stdin=subprocess.DEVNULL)

        run_cli("workspace", "create", "--name", "hops", "--focus", "--shell", "exec /bin/zsh -f")
        time.sleep(2)  # test harness: the prompt draws
        if rpc(sock, "debug.input", {"action": "hops"}).get("error"):
            raise SystemExit(f"input-turn-hops: debug.input hops is not in this build: "
                             f"{rpc(sock, 'debug.input', {'action': 'hops'})}")
        cg = core_graphics() if opts.input == "real" else None
        if cg:
            subprocess.run(["osascript", "-e", f'tell application "System Events" to set frontmost of (first process '
                            f'whose unix id is {bench.process.pid}) to true'], capture_output=True, timeout=30)

        def type_keys(count):
            keys = "asdfghjkl"
            for index in range(count):
                key = keys[index % len(keys)]
                if cg:
                    post_real_key(cg, key)
                else:
                    rpc(sock, "debug.key", {"key": key, "timestamp": time.clock_gettime(time.CLOCK_UPTIME_RAW)}, timeout=10)
                time.sleep(opts.interval)  # test harness: one key in flight at a time
            rpc(sock, "action.run", {"action": "terminal.sendText", "args": {"text": "\x15"}, "focus": True, "origin": "script"})

        type_keys(opts.keys)
        for index in range(opts.busy):
            run_cli("workspace", "create", "--name", f"busy-{index}", "--shell", BUSY)
        time.sleep(1)  # test harness: the busy terminals start printing
        type_keys(opts.keys)
        reply = rpc(sock, "debug.input", {"action": "hops", "since_launch": True}, timeout=60)
        if reply.get("error"):
            raise SystemExit(f"input-turn-hops: debug.input hops failed: {reply['error']}")
        with open(os.path.join(opts.out, "hops-reply.json"), "w") as handle:
            json.dump(reply, handle, indent=1)
        return reply, app
    finally:
        bench.stop()


# MARK: self-test


def self_test():
    fixture = {"since_launch": True, "recorded": 9, "dropped": 1, "sites_overflow": 0, "pending": 0, "rows": [
        {"site": "cmux DEV+0x10", "lane": "swift", "count": 5, "kinds": ["key"], "origin": {"main": 5},
         "priorities": [25], "frame": {"image": "cmux DEV", "image_uuid": "U", "offset": 16}},
        {"site": "cmux DEV+0x20", "lane": "swift", "count": 2, "kinds": ["key", "dispatching"],
         "origin": {"off_main": 2}, "priorities": [21], "frame": {"image": "cmux DEV", "image_uuid": "U", "offset": 32}},
        {"site": "runloop.timer", "lane": "nonswift", "count": 2, "kinds": ["key"], "origin": {"default": 2},
         "priorities": [], "total_ms": 3.5, "max_ms": 2.0, "stack": []},
    ]}
    failures = []

    def check(name, condition):
        if not condition:
            failures.append(name)

    symbol, file, line = parse_atos("closure #1 in Foo.bar() (in cmux DEV) (Foo.swift:42)")
    check("atos with a line", (symbol, file, line) == ("closure #1 in Foo.bar()", "Foo.swift", 42))
    check("atos without debug info", parse_atos("Foo.bar() (in cmux DEV) + 12")[1:] == (None, None))
    fixture["rows"][0].update(file="Foo.swift", line=3)
    fixture["rows"][1].update(file="Bar.swift", line=2)
    sources = {"/s/Foo.swift": "a\n// input-hop-allow: the menu needs this order\nTask { @MainActor in }\n",
               "/s/Bar.swift": "a\nTask { @MainActor in }\n"}
    index = {"Foo.swift": ["/s/Foo.swift"], "Bar.swift": ["/s/Bar.swift"], "Twice.swift": ["/a/Twice.swift", "/b/Twice.swift"]}
    document = queue(fixture, index, read=lambda path: sources[path])
    rows = {r["site"]: r for r in document["rows"]}
    check("allow comment on the line above", rows["cmux DEV+0x10"]["allowed"] is True)
    check("no allow comment", rows["cmux DEV+0x20"]["allowed"] is False)
    check("nonswift rows are tasks", rows["runloop.timer"]["allowed"] is False and rows["runloop.timer"]["total_ms"] == 3.5)
    check("unallowed count", document["unallowed"] == 2)
    check("allowed rows sort last", document["rows"][-1]["site"] == "cmux DEV+0x10")
    check("row keys", all({"site", "lane", "count", "kinds", "origin", "allowed"} <= set(r) for r in document["rows"]))
    check("two files of one name are not judged", is_allowed("Twice.swift", 1, index, read=lambda p: ALLOW) is None)
    check("no line is not judged", is_allowed("Foo.swift", None, index, read=lambda path: sources[path]) is None)
    check("pick by uuid", pick_file({"image": "x", "image_uuid": "ab"}, {"x": ["/p1", "/p2"]},
                                    {"/p1": {"CD"}, "/p2": {"AB"}}) == "/p2")
    check("no uuid takes the first", pick_file({"image": "x"}, {"x": ["/p1"]}, {}) == "/p1")
    with tempfile.TemporaryDirectory() as root:
        os.makedirs(os.path.join(root, "A"))
        open(os.path.join(root, "A", "One.swift"), "w").close()
        check("source index", source_index(root) == {"One.swift": [os.path.join(root, "A", "One.swift")]})
    for name in failures:
        print(f"FAIL {name}")
    print("self-test:", "FAIL" if failures else "PASS")
    return 1 if failures else 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--app")
    parser.add_argument("--out")
    parser.add_argument("--json", help="the queue document (default artifacts/input-turn-hops.json in the repo)")
    parser.add_argument("--input", choices=("real", "debug"), default="real",
                        help="real: CGEvent key presses through the window server (input is pending until dispatch); "
                             "debug: debug.key (only the dispatching turns count)")
    parser.add_argument("--keys", type=int, default=200, help="keys per phase (idle, then load)")
    parser.add_argument("--interval", type=float, default=0.05, help="seconds between keys")
    parser.add_argument("--busy", type=int, default=4, help="printing terminals in the load phase")
    parser.add_argument("--dsym", action="append", help="a dSYM bundle to symbolicate with (repeatable)")
    parser.add_argument("--from-reply", help="a saved `debug.input hops` reply instead of a run")
    parser.add_argument("--self-test", action="store_true")
    opts = parser.parse_args(argv)
    if opts.self_test:
        return self_test()
    if opts.from_reply:
        with open(opts.from_reply) as handle:
            reply, app = json.load(handle), os.path.realpath(opts.app.rstrip("/")) if opts.app else None
    else:
        if not opts.app or not opts.out:
            parser.error("--app and --out are required for a run")
        os.makedirs(opts.out, exist_ok=True)
        reply, app = run_app(opts)
    rows = reply.get("rows") or []
    symbolicate(rows, image_files(app, opts.dsym))
    document = queue(reply, source_index())
    document["app"] = app
    document["input"] = None if opts.from_reply else opts.input
    path = opts.json or os.path.join(REPO, "artifacts", "input-turn-hops.json")
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    with open(path, "w") as handle:
        json.dump(document, handle, indent=1)
    note(f"input-turn-hops: {len(document['rows'])} sites, {document['unallowed']} unallowed, "
         f"{document.get('dropped')} dropped -> {path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
