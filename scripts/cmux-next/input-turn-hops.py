#!/usr/bin/env python3
"""MQ-input-turn-hops: the main-thread hops that run beside a person's input, as a queue of fix tasks
(plans/cmux-next/chrome-parity/p04-input.md, task 022).

Runs typing-frame-bench.py on its terminal surface (idle, then with --busy printing terminals) with --hops-out, so
the queue explains the same workload the typing bench measures; the bench reads `debug.input` action `hops` since
launch before its app quits. This script symbolicates each site (image + offset) to file:line with the image's dSYM
(atos) and writes one row per unique site:

  site, lane (swift | nonswift), count, kinds, origin, symbol, file, line, allowed

A Swift row is a main-actor job enqueued while input was pending or dispatching, named by its first frame past the
Swift runtime and libdispatch. Its producer was the MainJobGate hook, deleted in sequence-manager S6: the app's replies
have no Swift rows; the main-job census's input window (`debug.main_jobs.input`) names those jobs. A nonswift row is a main run-loop callout that ran
while input was pending, named by its own frame when it ran long enough to be sampled, else by its run-loop stretch
(`runloop.timer`, `runloop.main_queue_or_port`, `runloop.sources_or_polled_main_queue`); `includes_swift_jobs` marks
the time that also holds Swift jobs. Each row is one task: remove the hop, or justify it with
`// input-hop-allow: <why>` on the site's line or the line above it (the row is then `allowed`).

The typing bench types with `debug.key`, which the window server never sees as pending: its keys count only with
real HID keys (`--input real`, p04-input-070; pass it with --bench-arg).

  input-turn-hops.py --app APP --out DIR [--tag TAG] [--json artifacts/input-turn-hops.json] [--keys 200] [--busy 4]
      [--bench-arg=--stress ...] [--dsym PATH ...]
  input-turn-hops.py --from-reply REPLY.json --app APP [--json FILE]   (a saved hops reply, or a --hops-out file)
  input-turn-hops.py --self-test

Runs on a host with a GUI session (an owned mini with a console), as typing-frame-bench.py does.
"""
import argparse, glob, json, os, re, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
SOURCES = os.path.join(REPO, "Packages/macOS/CmuxNext/Sources")
ALLOW = "input-hop-allow:"
ATOS_LINE = re.compile(r"^(?P<symbol>.*?) \(in (?P<image>[^)]+)\)(?: \((?P<file>[^():]+):(?P<line>\d+)\))?\s*$")

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
    """Adds symbol, file and line to each row with a frame (one atos run per image)."""
    uuid_cache, by_file = {}, {}
    for row in rows:
        frame = row.get("frame")
        if not frame:
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


def merge_replies(replies):
    """One hops reply from several (the bench's sessions): rows of one site and lane add up."""
    merged, by_site = {"since_launch": True, "recorded": 0, "dropped": 0, "sites_overflow": 0, "rows": []}, {}
    for reply in replies:
        for key in ("recorded", "dropped", "sites_overflow"):
            merged[key] += reply.get(key) or 0
        for row in reply.get("rows") or []:
            known = by_site.get((row.get("site"), row.get("lane")))
            if known is None:
                by_site[(row.get("site"), row.get("lane"))] = known = dict(row, kinds=list(row.get("kinds") or []),
                                                                          origin=dict(row.get("origin") or {}))
                merged["rows"].append(known)
                continue
            known["count"] = (known.get("count") or 0) + (row.get("count") or 0)
            known["kinds"] += [k for k in row.get("kinds") or [] if k not in known["kinds"]]
            for name, count in (row.get("origin") or {}).items():
                known["origin"][name] = known["origin"].get(name, 0) + count
            for key in ("priorities", "callouts"):
                if row.get(key) is not None:
                    known[key] = sorted(set(known.get(key) or []) | set(row[key]))
            if row.get("includes_swift_jobs"):
                known["includes_swift_jobs"] = True
            if row.get("total_ms") is not None:
                known["total_ms"] = (known.get("total_ms") or 0) + row["total_ms"]
                known["max_ms"] = max(known.get("max_ms") or 0, row.get("max_ms") or 0)
    merged["rows"].sort(key=lambda r: (-(r.get("count") or 0), r.get("site") or ""))
    return merged


def queue(reply, index, read=None):
    """The MQ-input-turn-hops document from a symbolicated `debug.input hops` reply."""
    rows = []
    for row in reply.get("rows") or []:
        entry = {key: row.get(key) for key in ("site", "lane", "count", "kinds", "origin")}
        entry.update(symbol=row.get("symbol"), file=row.get("file"), line=row.get("line"), frame=row.get("frame"))
        if row.get("lane") == "swift":
            entry["priorities"] = row.get("priorities") or []
        else:
            entry.update(callouts=row.get("callouts"), includes_swift_jobs=row.get("includes_swift_jobs"),
                         total_ms=row.get("total_ms"), max_ms=row.get("max_ms"))
        # A stretch with no site of its own is a task until it is sampled; a site is judged by its source line.
        entry["allowed"] = is_allowed(row.get("file"), row.get("line"), index, read) if row.get("frame") else False
        rows.append(entry)
    rows.sort(key=lambda r: (r.get("allowed") is True, -(r.get("count") or 0), r.get("site") or ""))
    return {"queue": "MQ-input-turn-hops", "since_launch": reply.get("since_launch"),
            "recorded": reply.get("recorded"), "dropped": reply.get("dropped"),
            "sites_overflow": reply.get("sites_overflow"), "rows": rows,
            "unallowed": sum(1 for r in rows if r.get("allowed") is not True)}


# MARK: the run


def bench_command(opts, app, hops_out):
    """typing-frame-bench.py on its terminal surface, idle then under --busy printing terminals, one round."""
    return [sys.executable, os.path.join(HERE, "typing-frame-bench.py"), "--app", app, "--tag", opts.tag,
            "--out", opts.out, "--surfaces", "terminal", "--phases", "idle,load", "--rounds", "1",
            "--samples", str(opts.keys), "--busy", str(opts.busy), "--chats", "0", "--hops-out", hops_out,
            *(opts.bench_arg or [])]


def replies_of(document):
    """The hops replies of a --hops-out file ({"sessions": {...}}) or of one saved reply."""
    if isinstance(document, dict) and isinstance(document.get("sessions"), dict):
        return list(document["sessions"].values())
    return [document]


def run_bench(opts):
    """Runs the typing bench with --hops-out and returns its sessions' hops replies, merged, and the app."""
    app = os.path.realpath(opts.app.rstrip("/"))
    hops_out = os.path.join(opts.out, "hops-reply.json")
    if os.path.exists(hops_out):
        os.remove(hops_out)
    subprocess.run(bench_command(opts, app, hops_out), check=False)
    try:
        with open(hops_out) as handle:
            replies = replies_of(json.load(handle))
    except (OSError, ValueError):
        raise SystemExit(f"input-turn-hops: typing-frame-bench.py wrote no hops reply ({hops_out})")
    failed = [r.get("error") for r in replies if not isinstance(r, dict) or r.get("error")]
    if failed:
        raise SystemExit(f"input-turn-hops: debug.input hops failed: {failed}")
    return merge_replies(replies), app


# MARK: self-test


def self_test():
    fixture = {"since_launch": True, "recorded": 9, "dropped": 1, "sites_overflow": 0, "pending": 0, "rows": [
        {"site": "cmux DEV+0x10", "lane": "swift", "count": 5, "kinds": ["key"], "origin": {"main": 5},
         "priorities": [25], "frame": {"image": "cmux DEV", "image_uuid": "U", "offset": 16}},
        {"site": "cmux DEV+0x20", "lane": "swift", "count": 2, "kinds": ["key", "dispatching"],
         "origin": {"off_main": 2}, "priorities": [21], "frame": {"image": "cmux DEV", "image_uuid": "U", "offset": 32}},
        {"site": "runloop.timer", "lane": "nonswift", "count": 2, "kinds": ["key"], "origin": {"default": 2},
         "priorities": [], "callouts": ["timer"], "includes_swift_jobs": False, "total_ms": 3.5, "max_ms": 2.0,
         "stack": []},
        {"site": "cmux DEV+0x30", "lane": "nonswift", "count": 1, "kinds": ["key"], "origin": {"default": 1},
         "priorities": [], "callouts": ["main_queue_or_port"], "includes_swift_jobs": True, "total_ms": 4.0,
         "max_ms": 4.0, "frame": {"image": "cmux DEV", "image_uuid": "U", "offset": 48}},
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
    fixture["rows"][3].update(file="Foo.swift", line=3)
    sources = {"/s/Foo.swift": "a\n// input-hop-allow: the menu needs this order\nTask { @MainActor in }\n",
               "/s/Bar.swift": "a\nTask { @MainActor in }\n"}
    index = {"Foo.swift": ["/s/Foo.swift"], "Bar.swift": ["/s/Bar.swift"], "Twice.swift": ["/a/Twice.swift", "/b/Twice.swift"]}
    document = queue(fixture, index, read=lambda path: sources[path])
    rows = {r["site"]: r for r in document["rows"]}
    check("allow comment on the line above", rows["cmux DEV+0x10"]["allowed"] is True)
    check("no allow comment", rows["cmux DEV+0x20"]["allowed"] is False)
    check("a stretch with no site is a task", rows["runloop.timer"]["allowed"] is False and rows["runloop.timer"]["total_ms"] == 3.5)
    check("a sampled callout is judged by its line", rows["cmux DEV+0x30"]["allowed"] is True)
    check("a sampled callout keeps its fields", rows["cmux DEV+0x30"]["includes_swift_jobs"] is True
          and rows["cmux DEV+0x30"]["callouts"] == ["main_queue_or_port"])
    check("unallowed count", document["unallowed"] == 2)
    check("allowed rows sort last", {r["site"] for r in document["rows"][-2:]} == {"cmux DEV+0x10", "cmux DEV+0x30"})
    light = {"recorded": 3, "dropped": 0, "sites_overflow": 0, "rows": [
        {"site": "s", "lane": "nonswift", "count": 2, "kinds": ["key"], "origin": {"default": 2}, "callouts": ["timer"],
         "total_ms": 3.0, "max_ms": 2.0}]}
    stress = {"recorded": 2, "dropped": 1, "sites_overflow": 0, "rows": [
        {"site": "s", "lane": "nonswift", "count": 1, "kinds": ["click"], "origin": {"event_tracking": 1},
         "callouts": ["sources_or_polled_main_queue"], "includes_swift_jobs": True, "total_ms": 5.0, "max_ms": 5.0},
        {"site": "s", "lane": "swift", "count": 1, "kinds": ["key"], "origin": {"main": 1}, "priorities": [25]}]}
    merged = merge_replies(replies_of({"sessions": {"light": light, "stress": stress}}))
    first = merged["rows"][0]
    check("merge adds a site's sessions", (merged["recorded"], merged["dropped"], len(merged["rows"])) == (5, 1, 2))
    check("merge adds counts and times", (first["count"], first["total_ms"], first["max_ms"]) == (3, 8.0, 5.0))
    check("merge unions kinds and origins", first["kinds"] == ["key", "click"]
          and first["origin"] == {"default": 2, "event_tracking": 1})
    check("merge keeps the swift-jobs mark", first["includes_swift_jobs"] is True
          and first["callouts"] == ["sources_or_polled_main_queue", "timer"])
    check("merge leaves its inputs", light["rows"][0]["count"] == 2 and light["rows"][0]["kinds"] == ["key"])
    check("one saved reply is one reply", replies_of(light) == [light])
    opts = argparse.Namespace(tag="hops", out="/o", keys=50, busy=2, bench_arg=["--stress"])
    command = bench_command(opts, "/A.app", "/o/h.json")
    check("the bench runs its terminal surface with --hops-out", command[1].endswith("typing-frame-bench.py")
          and command[command.index("--surfaces") + 1] == "terminal" and command[command.index("--hops-out") + 1] == "/o/h.json"
          and command[command.index("--samples") + 1] == "50" and command[-1] == "--stress")
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
    parser.add_argument("--tag", default="hops", help="the typing bench's tag")
    parser.add_argument("--json", help="the queue document (default artifacts/input-turn-hops.json in the repo)")
    parser.add_argument("--keys", type=int, default=200, help="keys per phase (idle, then load)")
    parser.add_argument("--busy", type=int, default=4, help="printing terminals in the load phase")
    parser.add_argument("--bench-arg", action="append", help="one more typing-frame-bench.py argument (repeatable)")
    parser.add_argument("--dsym", action="append", help="a dSYM bundle to symbolicate with (repeatable)")
    parser.add_argument("--from-reply", help="a saved `debug.input hops` reply or --hops-out file instead of a run")
    parser.add_argument("--self-test", action="store_true")
    opts = parser.parse_args(argv)
    if opts.self_test:
        return self_test()
    if opts.from_reply:
        with open(opts.from_reply) as handle:
            reply = merge_replies(replies_of(json.load(handle)))
        app = os.path.realpath(opts.app.rstrip("/")) if opts.app else None
    else:
        if not opts.app or not opts.out:
            parser.error("--app and --out are required for a run")
        opts.out = os.path.abspath(opts.out)
        os.makedirs(opts.out, exist_ok=True)
        reply, app = run_bench(opts)
    rows = reply.get("rows") or []
    symbolicate(rows, image_files(app, opts.dsym))
    document = queue(reply, source_index())
    document["app"] = app
    document["bench_args"] = None if opts.from_reply else opts.bench_arg or []
    path = opts.json or os.path.join(REPO, "artifacts", "input-turn-hops.json")
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    with open(path, "w") as handle:
        json.dump(document, handle, indent=1)
    note(f"input-turn-hops: {len(document['rows'])} sites, {document['unallowed']} unallowed, "
         f"{document.get('dropped')} dropped -> {path}")
    return 0

if __name__ == "__main__":
    sys.exit(main())
