#!/usr/bin/env python3
"""MQ-input-dirty-views: the views an input turn marks dirty outside the event's target, as a queue of fix tasks
(plans/cmux-next/chrome-parity/p04-input.md, task 093).

Runs input-latency-bench.py (real HID keys by default) on Home, the omnibar and the terminal, light and STRESS, with
`debug.input` action `dirty` in every measured phase: right after the bench's own `debug.input reset`, the phase asks
`dirty` once (the first request installs the recorder), the bench types, and the phase reads `dirty` again before the
next phase's reset removes the recorder. The recorder counts each `setNeedsDisplay`/`setNeedsLayout`/
`setNeedsUpdateConstraints` of a view or a layer from a key down, a click or a scroll to the commit pass after it, by
the receiver's class, its relation to the target (the key's first responder, the hit view) and its stack.

This script symbolicates each site's stack with the image's dSYM (atos, input-turn-hops.py's helpers), names the
site's caller (the first frame past the recorder) and the first frame of cmux's own code, and writes one row per
(session, surface, call, class, relation, site):

  session, surface, call, object_class, view_class, relation, off_target, count, kinds, caller, site, symbol, file, line

Rows with relation `outside`, `other_window` or `no_view` are off target and come first: each is one task (the view
should not change for input to another view, or should change in its own frame). `ancestor` rows are layout that
climbs from the target; `target` rows are the input's own work. Per surface and phase the document also has the
turns, the calls and the commit pass that ended each turn (`commit_pass_ms`: AppKit's display cycle and the Core Animation
commit), p50/p95/p99/max.

  input-dirty-views.py --app APP --out DIR [--json artifacts/input-dirty-views.json] [--surfaces home,omnibar,terminal]
      [--sessions light,stress] [--keys 200] [--input real|debug] [--dsym PATH ...] [--bench-arg=--storm=... ...]
  input-dirty-views.py --from-reply FILE [--app APP] [--json FILE]   (a saved document of this script's "replies")
  input-dirty-views.py --self-test

Runs on a host with a GUI session and the input grant (an owned mini with a console), as input-latency-bench.py does.
"""
import argparse, glob, importlib.util, json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
OFF_TARGET = ("outside", "other_window", "no_view")
# The recorder's own frames at the top of every stack: its Swift frames and the concurrency runtime's assumeIsolated.
RECORDER_SYMBOL = "InputDirty"
RUNTIME_IMAGE_PREFIX = "libswift"
QUEUE = "MQ-input-dirty-views"


def note(text):
    print(text, flush=True)


def load_script(name, file):
    """A sibling script as a module (its file name has dashes)."""
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, file))
    module = importlib.util.module_from_spec(spec)
    sys.path.insert(0, HERE)
    spec.loader.exec_module(module)
    return module


# MARK: the run


def dirty_bench(base, sink):
    """`base` (input-latency-bench's Bench) with `debug.input dirty` armed after each phase's reset and read at its
    end; each read goes to `sink` as {session, surface, reply}."""

    class DirtyBench(base):
        def phase_start(self, subject):
            recording = super().phase_start(subject)
            armed = self.control.rpc("debug.input", {"action": "dirty"}, timeout=30)
            if not isinstance(armed, dict) or armed.get("error"):
                self.note(f"{self.session} {subject}: debug.input dirty did not install: {armed}")
            return recording

        def phase_end(self, recording, threads):
            result = super().phase_end(recording, threads)
            reply = self.control.rpc("debug.input", {"action": "dirty"}, timeout=60)
            sink.append({"session": self.session, "surface": self.subject, "reply": reply})
            return result

    return DirtyBench


def bench_argv(opts):
    argv = ["--app", opts.app, "--out", opts.out, "--surfaces", opts.surfaces, "--sessions", opts.sessions,
            "--keys", str(opts.keys), "--input", opts.input]
    return argv + list(opts.bench_arg or [])


def run_bench(opts):
    """Runs input-latency-bench.py's phases with the dirty recorder armed; returns the dirty replies."""
    bench = load_script("input_latency_bench", "input-latency-bench.py")
    parser = bench.build_parser()
    bench_opts = parser.parse_args(bench_argv(opts))
    bench.validate(bench_opts, parser)
    replies = []
    bench.Bench = dirty_bench(bench.Bench, replies)
    document = bench.run_launched(bench_opts)
    bench.write(os.path.join(opts.out, "input-latency-report.json"), document)
    return replies


# MARK: symbolication


def app_images(app):
    """The image names of the app bundle: cmux's own code."""
    if not app:
        return set()
    paths = glob.glob(os.path.join(app, "Contents", "MacOS", "*")) + \
        glob.glob(os.path.join(app, "Contents", "Frameworks", "**", "*"), recursive=True)
    return {os.path.basename(p) for p in paths if os.path.isfile(p) and not os.path.islink(p)}


def symbolicate(rows, files, hops):
    """Adds symbol, file and line to every stack frame (one atos run per image file)."""
    uuid_cache, by_file = {}, {}
    for row in rows:
        for frame in row.get("stack") or []:
            path = hops.pick_file(frame, files, uuid_cache)
            if path:
                by_file.setdefault(path, []).append(frame)
            else:
                frame["symbol"] = frame.get("nearest_symbol")
    for path, frames in by_file.items():
        for frame, line in zip(frames, hops.atos(path, [f["offset"] for f in frames])):
            symbol, file, number = hops.parse_atos(line) if line else (None, None, None)
            frame["symbol"] = symbol or frame.get("nearest_symbol")
            frame["file"], frame["line"] = file, number


def is_recorder(frame):
    symbol = frame.get("symbol") or frame.get("nearest_symbol") or ""
    return RECORDER_SYMBOL in symbol or (frame.get("image") or "").startswith(RUNTIME_IMAGE_PREFIX)


def name(frame):
    if not frame:
        return None
    return f"{frame.get('image')}+0x{int(frame.get('offset') or 0):x}"


def sites(stack, own):
    """(caller, site) of a stack: the first frame past the recorder's, and the first frame of cmux's own images
    from there (the caller when none is cmux's)."""
    index = 0
    while index < len(stack) and is_recorder(stack[index]):
        index += 1
    rest = stack[index:]
    caller = rest[0] if rest else None
    site = next((f for f in rest if f.get("image") in own), caller)
    return caller, site


# MARK: the queue


def queue(replies, own):
    """The MQ-input-dirty-views document from symbolicated dirty replies ({session, surface, reply})."""
    rows, by_key, surfaces, failed = [], {}, {}, []
    for entry in replies:
        reply, label = entry.get("reply"), f"{entry.get('session')}/{entry.get('surface')}"
        if not isinstance(reply, dict) or reply.get("error"):
            failed.append({"surface": label, "error": reply.get("error") if isinstance(reply, dict) else "no reply"})
            continue
        # One entry per phase: a surface measured under several conditions has one per condition.
        surfaces.setdefault(label, []).append({key: reply.get(key) for key in (
            "turns", "calls", "off_target_calls", "sites_overflow", "commit_pass_ms", "calls_per_turn")})
        for row in reply.get("rows") or []:
            caller, site = sites(row.get("stack") or [], own)
            key = (entry.get("session"), entry.get("surface"), row.get("call"), row.get("object_class"),
                   row.get("view_class"), row.get("relation"), name(site))
            known = by_key.get(key)
            if known is None:
                known = by_key[key] = {
                    "session": entry.get("session"), "surface": entry.get("surface"), "call": row.get("call"),
                    "object_class": row.get("object_class"), "view_class": row.get("view_class"),
                    "relation": row.get("relation"), "off_target": row.get("relation") in OFF_TARGET, "count": 0,
                    "kinds": [], "caller": name(caller), "caller_symbol": (caller or {}).get("symbol"),
                    "site": name(site), "symbol": (site or {}).get("symbol"), "file": (site or {}).get("file"),
                    "line": (site or {}).get("line")}
                rows.append(known)
            known["count"] += row.get("count") or 0
            known["kinds"] += [k for k in row.get("kinds") or [] if k not in known["kinds"]]
    rows.sort(key=lambda r: (not r["off_target"], -r["count"], r["surface"] or "", r["call"] or "", r["object_class"] or ""))
    return {"queue": QUEUE, "surfaces": surfaces, "failed": failed, "rows": rows,
            "off_target": sum(1 for r in rows if r["off_target"])}


# MARK: self-test


def self_test():
    failures = []

    def check(label, condition):
        if not condition:
            failures.append(label)

    recorder = {"image": "cmux DEV", "offset": 16, "symbol": "InputDirtyLedger.note(_:_:target:kind:)"}
    runtime = {"image": "libswift_Concurrency.dylib", "offset": 32, "symbol": "MainActor.assumeIsolated"}
    appkit = {"image": "AppKit", "offset": 48, "symbol": "-[NSView setFrameSize:]"}
    own = {"image": "cmux DEV", "offset": 64, "symbol": "SidebarRow.update()", "file": "SidebarRow.swift", "line": 12}
    caller, site = sites([recorder, runtime, appkit, own], {"cmux DEV"})
    check("the caller is the first frame past the recorder", caller is appkit)
    check("the site is the first frame of cmux's code", site is own)
    check("no cmux frame: the site is the caller", sites([recorder, appkit], {"cmux DEV"}) == (appkit, appkit))
    check("an empty stack has no site", sites([], set()) == (None, None))

    reply = {"installed": True, "turns": {"key": 3}, "calls": 9, "off_target_calls": 4, "sites_overflow": 0,
             "commit_pass_ms": {"key": {"n": 3, "p50": 1.0, "p95": 2.0, "p99": 2.0, "max": 2.0}}, "rows": [
                 {"call": "view.needs_display", "object_class": "TextView", "view_class": "TextView", "relation": "target",
                  "count": 5, "kinds": ["key"], "stack": [recorder, appkit]},
                 {"call": "view.needs_layout", "object_class": "SidebarRow", "view_class": "SidebarRow",
                  "relation": "outside", "count": 3, "kinds": ["key"], "stack": [recorder, runtime, appkit, own]},
                 {"call": "layer.needs_display", "object_class": "CALayer", "view_class": None, "relation": "no_view",
                  "count": 1, "kinds": ["key"], "stack": [recorder, own]}]}
    stress = {"rows": [{"call": "view.needs_layout", "object_class": "SidebarRow", "view_class": "SidebarRow",
                        "relation": "outside", "count": 4, "kinds": ["click"], "stack": [recorder, appkit, own]}]}
    document = queue([{"session": "light", "surface": "home", "reply": reply},
                      {"session": "light", "surface": "home", "reply": stress},
                      {"session": "stress", "surface": "terminal", "reply": {"error": "unavailable"}}], {"cmux DEV"})
    rows = document["rows"]
    check("off-target rows first", [r["off_target"] for r in rows] == [True, True, False])
    check("one site's rows of a surface add up", rows[0]["object_class"] == "SidebarRow" and rows[0]["count"] == 7
          and rows[0]["kinds"] == ["key", "click"])
    check("a row names its site and caller", rows[0]["site"] == "cmux DEV+0x40" and rows[0]["file"] == "SidebarRow.swift"
          and rows[0]["caller"] == "AppKit+0x30")
    check("no_view is off target", rows[1]["relation"] == "no_view" and rows[1]["off_target"])
    check("off-target count", document["off_target"] == 2)
    check("per-phase numbers", len(document["surfaces"]["light/home"]) == 2 and document["surfaces"]["light/home"][0]["commit_pass_ms"]["key"]["p99"] == 2.0)
    check("a failed read is listed", document["failed"] == [{"surface": "stress/terminal", "error": "unavailable"}])

    class Control:
        def __init__(self):
            self.calls = []

        def rpc(self, method, params=None, timeout=30):
            self.calls.append((method, dict(params or {})))
            return {"installed": True, "rows": []}

    class Base:
        def __init__(self):
            self.control, self.session, self.subject, self.notes = Control(), "light", None, []

        def note(self, text):
            self.notes.append(text)

        def phase_start(self, subject):
            self.subject = subject
            self.control.rpc("debug.input", {"action": "reset"})
            return "recording"

        def phase_end(self, recording, threads):
            return ("events", recording)

    sink = []
    bench = dirty_bench(Base, sink)()
    check("the phase still records", bench.phase_start("home") == "recording")
    check("dirty is armed after the reset", bench.control.calls == [("debug.input", {"action": "reset"}),
                                                                   ("debug.input", {"action": "dirty"})])
    check("the phase still ends", bench.phase_end("recording", []) == ("events", "recording"))
    check("the end reads dirty", bench.control.calls[-1] == ("debug.input", {"action": "dirty"}) and
          sink == [{"session": "light", "surface": "home", "reply": {"installed": True, "rows": []}}])
    opts = argparse.Namespace(app="/A.app", out="/o", surfaces="home", sessions="light", keys=5, input="real",
                              bench_arg=["--storm=cli=10hz"])
    argv = bench_argv(opts)
    check("bench argv", argv[argv.index("--surfaces") + 1] == "home" and argv[-1] == "--storm=cli=10hz"
          and argv[argv.index("--input") + 1] == "real")
    for label in failures:
        print(f"FAIL {label}")
    print("self-test:", "FAIL" if failures else "PASS")
    return 1 if failures else 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--app")
    parser.add_argument("--out")
    parser.add_argument("--json", help="the queue document (default artifacts/input-dirty-views.json in the repo)")
    parser.add_argument("--surfaces", default="home,omnibar,terminal")
    parser.add_argument("--sessions", default="light,stress")
    parser.add_argument("--keys", type=int, default=200)
    parser.add_argument("--input", choices=("real", "debug"), default="real")
    parser.add_argument("--bench-arg", action="append", help="one more input-latency-bench.py argument (repeatable)")
    parser.add_argument("--dsym", action="append", help="a dSYM bundle to symbolicate with (repeatable)")
    parser.add_argument("--from-reply", help="a saved document with this script's `replies` instead of a run")
    parser.add_argument("--self-test", action="store_true")
    opts = parser.parse_args(argv)
    if opts.self_test:
        return self_test()
    app = os.path.realpath(opts.app.rstrip("/")) if opts.app else None
    if opts.from_reply:
        with open(opts.from_reply) as handle:
            replies = json.load(handle).get("replies") or []
    else:
        if not app or not opts.out:
            parser.error("--app and --out are required for a run")
        opts.app, opts.out = app, os.path.abspath(opts.out)
        os.makedirs(opts.out, exist_ok=True)
        replies = run_bench(opts)
    hops = load_script("input_turn_hops", "input-turn-hops.py")
    rows = [row for entry in replies if isinstance(entry.get("reply"), dict) for row in entry["reply"].get("rows") or []]
    symbolicate(rows, hops.image_files(app, opts.dsym), hops)
    document = queue(replies, app_images(app))
    document.update(app=app, input=opts.input, replies=replies)
    path = opts.json or os.path.join(REPO, "artifacts", "input-dirty-views.json")
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    with open(path, "w") as handle:
        json.dump(document, handle, indent=1)
    note(f"input-dirty-views: {len(document['rows'])} rows, {document['off_target']} off target, "
         f"{len(document['failed'])} failed reads -> {path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
