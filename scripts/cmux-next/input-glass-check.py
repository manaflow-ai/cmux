#!/usr/bin/env python3
"""Key to glass: when a real key's glyph really showed on the display, against the presented time cmux estimated for
it (plans/cmux-next/chrome-parity/p04-input.md, task 071, done check DC3).

cmux has no presentation feedback for its Core Animation windows, so InputLatencyTracker closes each input slot at an
estimate (PresentationClock: the commit's vsync + one render-server frame + a per-OS PresentationOffset). Chrome ends
EventLatency at the display's presentation feedback (ui/gfx/presentation_feedback.h,
cc/metrics/event_latency_tracing_recorder.cc); this check is the ground truth the estimate is calibrated against,
read outside the app with ScreenCaptureKit, per macOS version.

For each surface it launches nothing new: one tagged app (BenchApp, frontmost, a cursor that does not blink) runs every
surface in turn. glass-capture.swift (compiled here, its own process) captures the caret region of the focused element
at the display's refresh rate and posts real keys at the HID event tap, alternating `x` and Delete (one glyph changes,
the caret stays). `log stream --signpost` records the app's `input.latency` slots (trace.py's reader). Each key is
paired with:

  glass      the displayTime of the first captured frame after the key whose changed pixels reach --min-pixels
  slot       the app's keyPress slot (entrypoint person) whose generated time (the NSEvent timestamp) is the key's
  presented  that slot's presented stage

and reported per surface and over all surfaces: glass (generated -> glass) p50/p95/p99/max, presented (generated ->
presented), glass - presented (signed) and |glass - presented|, for slots whose presented time is an estimate
(estimatedVsync, extrapolatedVsync, nominalRefresh; metalPresented and hostFeedback are real feedback and are only
reported). The suggested offset is the current PresentationOffset of this macOS (read from
Packages/macOS/CmuxNext/Sources/CmuxNextWakeups/PresentationOffset.swift, or --current-offset-ns) plus the median of
glass - presented; `residual` is |glass - presented - median|, what DC3 judges once that offset is set:
residual p95 <= one refresh and glass p99 <= 25 ms. The DC3 lines are information: exit 0 after a measurement.

A key is left out (and counted) when the region changed within --quiet-ms before it (`unsettled`: a blink or other
motion would be taken for its glyph), when no frame changed before the next key (`no_frame`) or when no slot matches
(`no_slot`).

Grants: the process that runs this needs Screen Recording (to capture) and Accessibility (to post keys). Without
either it refuses before the app launches, says which and exits 2.

  input-glass-check.py --app APP [--out DIR] [--surfaces terminal,home,omnibar] [--samples 200] [--interval-ms 120]
      [--min-pixels 6] [--quiet-ms 40] [--current-offset-ns N] [--json FILE]
  input-glass-check.py --self-test

Fleet (a capture mini with a lit or 120 Hz virtual display, macOS 26 and 27):
  nx-remote --needs gui --app-from-fleet cmux --tag p04-071 --ref SHA --timeout 3600 -- \\
    python3 scripts/cmux-next/input-glass-check.py --app "$NX_APP" \\
    --surfaces terminal,home,omnibar --samples 200
  (artifacts go to $NX_ARTIFACTS/glass; without --out or $NX_ARTIFACTS, to a new temporary directory it prints)
"""
import argparse, importlib.util, json, os, re, statistics, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import typing_report  # noqa: E402

REPO = os.path.dirname(os.path.dirname(HERE))
HELPER = os.path.join(HERE, "glass-capture.swift")
OFFSET_SWIFT = os.path.join(REPO, "Packages/macOS/CmuxNext/Sources/CmuxNextWakeups/PresentationOffset.swift")
WINDOW = (40, 40, 1400, 900)
ESTIMATE_SOURCES = ("estimatedVsync", "extrapolatedVsync", "nominalRefresh")
GLASS_P99_LIMIT_MS = 25.0
# A key's slot: generated (the NSEvent timestamp, set when the event was made, just before the post time is read, or
# later when the window server stamps it) from SLOT_BEFORE_NS before the post to SLOT_AFTER_NS after it.
SLOT_BEFORE_NS = 5_000_000
SLOT_AFTER_NS = 50_000_000
# A key whose glyph has not shown this long after it, or before the next key, has no frame.
FRAME_WINDOW_NS = 250_000_000
CALIBRATED = re.compile(r"static let calibrated: \[Int: Int64\] = \[([^\]]*)\]")


def note(text):
    print(f"glass: {text}", flush=True)


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, file))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


# ---------------------------------------------------------------- the helper's file

def parse_capture(text):
    """glass-capture's FILE: {grant: {screen, accessibility} | None, ready: {...} | None, keys: [...], frames:
    [(ns, changed)], statuses: [(ns, name)], error: str | None, ended: bool}."""
    out = {"grant": None, "ready": None, "keys": [], "frames": [], "statuses": [], "error": None, "ended": False}
    for raw in text.splitlines():
        word, _, rest = raw.strip().partition(" ")
        parts = rest.split()
        try:
            if word == "grant":
                fields = dict(p.split("=", 1) for p in parts if "=" in p)
                out["grant"] = {"screen": fields.get("screen") == "yes",
                                "accessibility": fields.get("accessibility") == "yes"}
            elif word == "ready" and len(parts) >= 7:
                out["ready"] = {"display": int(parts[0]), "x": int(parts[1]), "y": int(parts[2]), "width": int(parts[3]),
                                "height": int(parts[4]), "hz": float(parts[5]), "source": parts[6]}
            elif word == "key" and len(parts) >= 4:
                out["keys"].append({"index": int(parts[0]), "post_ns": int(parts[1]), "keycode": int(parts[2]),
                                    "warmup": parts[3] == "1"})
            elif word == "frame" and len(parts) >= 2:
                out["frames"].append((int(parts[0]), int(parts[1])))
            elif word == "status" and len(parts) >= 2:
                out["statuses"].append((int(parts[0]), parts[1]))
            elif word == "error":
                out["error"] = rest
            elif word == "end":
                out["ended"] = True
        except ValueError:
            continue
    out["frames"].sort()
    out["keys"].sort(key=lambda k: k["post_ns"])
    return out


def refusal(grant, error=None):
    """Why the run cannot measure, from the helper's grant line and error; None when it may."""
    if error and error.startswith(("no-screen-recording-grant", "no-accessibility-grant")):
        return error
    if grant is None:
        return f"glass-capture reported no grant line{f' ({error})' if error else ''}"
    missing = [name for name, ok in (("Screen Recording (System Settings > Privacy & Security > Screen & System "
                                      "Audio Recording)", grant["screen"]),
                                     ("Accessibility (System Settings > Privacy & Security > Accessibility; it posts "
                                      "the keys)", grant["accessibility"])) if not ok]
    if missing:
        return ("this process has no " + " and no ".join(missing) + " grant, for the app that runs this script "
                "(Terminal, sshd or the fleet agent): no glass time can be read without it")
    return None


# ---------------------------------------------------------------- pairing

def pair(capture, slots, pid, min_pixels, quiet_ms):
    """One row per measured (non-warmup) key: {index, post_ns, keycode, status, glass_ns, generated_ns, presented_ns,
    source, target}. status: ok, unsettled, no_frame or no_slot (a key without a glass frame is no_frame first)."""
    frames = [(ns, changed) for ns, changed in capture["frames"] if changed >= min_pixels]
    keys = capture["keys"]
    quiet = int(quiet_ms * 1_000_000)
    candidates = sorted((s for s in slots if s.get("pid") == pid and s["kind"] == "keyPress"
                         and s["entrypoint"] == "person"), key=lambda s: s["generated_ns"])
    taken, rows = set(), []
    for position, key in enumerate(keys):
        post = key["post_ns"]
        end = post + FRAME_WINDOW_NS
        if position + 1 < len(keys):
            end = min(end, keys[position + 1]["post_ns"])
        if key["warmup"]:
            continue
        row = {"index": key["index"], "post_ns": post, "keycode": key["keycode"], "glass_ns": None,
               "generated_ns": None, "presented_ns": None, "source": None, "target": None}
        glass = next((ns for ns, _ in frames if post < ns < end), None)
        slot = min((s for s in candidates if id(s) not in taken and post - SLOT_BEFORE_NS <= s["generated_ns"]
                    <= post + SLOT_AFTER_NS and s["generated_ns"] < end),
                   key=lambda s: abs(s["generated_ns"] - post), default=None)
        if slot is not None:
            taken.add(id(slot))
            row.update(generated_ns=slot["generated_ns"], presented_ns=slot["stages"].get("presented"),
                       source=slot["source"], target=slot["target"])
        row["glass_ns"] = glass
        if any(post - quiet < ns <= post for ns, _ in frames):
            row["status"] = "unsettled"
        elif glass is None:
            row["status"] = "no_frame"
        elif slot is None:
            row["status"] = "no_slot"
        else:
            row["status"] = "ok"
        rows.append(row)
    return rows


def ms(ns):
    return ns / 1e6


def summarize(rows, hz, current_offset_ns):
    """The report of one surface's (or every surface's) rows."""
    counts = {}
    for row in rows:
        counts[row["status"]] = counts.get(row["status"], 0) + 1
    ok = [r for r in rows if r["status"] == "ok"]
    sources, targets = {}, {}
    for row in ok:
        sources[row["source"]] = sources.get(row["source"], 0) + 1
        targets[row["target"]] = targets.get(row["target"], 0) + 1
    presented = [r for r in ok if r["presented_ns"]]
    estimated = [r for r in presented if r["source"] in ESTIMATE_SOURCES]
    diffs = [r["glass_ns"] - r["presented_ns"] for r in estimated]
    report = {"keys": len(rows), "counts": counts, "sources": sources, "targets": targets,
              "glass_ms": typing_report.distribution([ms(r["glass_ns"] - r["generated_ns"]) for r in ok]),
              "presented_ms": typing_report.distribution([ms(r["presented_ns"] - r["generated_ns"]) for r in presented]),
              "glass_minus_presented_ms": typing_report.distribution([ms(d) for d in diffs]),
              "abs_glass_minus_presented_ms": typing_report.distribution([ms(abs(d)) for d in diffs]),
              "refresh_hz": hz, "estimated": len(estimated)}
    if diffs:
        median = int(statistics.median(diffs))
        residual = typing_report.distribution([ms(abs(d - median)) for d in diffs])
        report["residual_ms"] = residual
        report["suggested_offset_ns"] = current_offset_ns + median
        report["median_glass_minus_presented_ns"] = median
    report["dc3"] = dc3(report)
    return report


def dc3(report):
    """DC3's two lines on this report: the residual after the suggested offset within one refresh at p95, glass p99
    within 25 ms. Information only; None when a number is missing."""
    hz = report.get("refresh_hz") or 0
    refresh_ms = round(1000.0 / hz, 2) if hz > 0 else None
    residual = (report.get("residual_ms") or {}).get("p95")
    glass = (report.get("glass_ms") or {}).get("p99")
    return {"refresh_ms": refresh_ms, "residual_p95_ms": residual,
            "residual_within_refresh": None if residual is None or refresh_ms is None else residual <= refresh_ms,
            "glass_p99_ms": glass, "glass_p99_within_limit": None if glass is None else glass <= GLASS_P99_LIMIT_MS}


# ---------------------------------------------------------------- PresentationOffset

def offset_table(text):
    """PresentationOffset.calibrated as {macOS major: ns} from the Swift source."""
    match = CALIBRATED.search(text)
    table = {}
    if not match:
        return table
    for entry in match.group(1).split(","):
        major, _, nanos = entry.partition(":")
        try:
            table[int(major.strip())] = int(nanos.strip().replace("_", ""))
        except ValueError:
            continue
    return table


def current_offset(major, override=None, path=OFFSET_SWIFT):
    """(ns, where): the offset the app under test adds for macOS `major`."""
    if override is not None:
        return override, "--current-offset-ns"
    try:
        with open(path) as handle:
            return offset_table(handle.read()).get(major, 0), os.path.relpath(path, REPO)
    except OSError:
        return 0, "default (PresentationOffset.swift not found)"


def suggestion_line(major, nanos, table):
    """The PresentationOffset.calibrated literal with `major` set to `nanos`."""
    merged = dict(table)
    merged[major] = nanos
    body = ", ".join(f"{k}: {v:_}" for k, v in sorted(merged.items()))
    return f"private static let calibrated: [Int: Int64] = [{body}]"


# ---------------------------------------------------------------- the run

def compile_helper(out):
    binary = os.path.join(out, "bin", "glass-capture")
    os.makedirs(os.path.dirname(binary), exist_ok=True)
    try:
        build = subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-O", HELPER, "-o", binary],
                               capture_output=True, text=True, timeout=600)
    except (OSError, subprocess.TimeoutExpired) as error:
        return None, f"glass-capture did not compile: {error}"
    if build.returncode:
        return None, f"glass-capture did not compile: {build.stderr[-600:]}"
    return binary, None


def check_grant(binary):
    try:
        run = subprocess.run([binary, "--check-grant"], capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.TimeoutExpired) as error:
        return f"glass-capture --check-grant failed: {error}"
    return refusal(parse_capture(run.stdout)["grant"], run.stderr.strip() or None)


def capture_keys(binary, out, surface, pid, opts):
    """Runs glass-capture for one surface; returns its parsed file."""
    path = os.path.join(out, f"capture-{surface}.txt")
    warmup = 6
    command = [binary, "--out", path, "--pid", str(pid), "--keys", str(opts.samples), "--warmup", str(warmup),
               "--interval-ms", str(opts.interval_ms), "--quiet-ms", str(opts.quiet_ms), "--region",
               ",".join(str(v) for v in WINDOW)]
    bound = 60 + (opts.samples + warmup) * opts.interval_ms * 11 / 1000.0  # a key waits up to ten intervals
    try:
        subprocess.run(command, capture_output=True, text=True, timeout=bound)
    except subprocess.TimeoutExpired:
        note(f"{surface}: glass-capture passed its {bound:.0f} s bound")
    try:
        with open(path) as handle:
            return parse_capture(handle.read())
    except OSError as error:
        return {**parse_capture(""), "error": f"no capture file: {error}"}


class Surfaces:
    """Puts the keyboard focus on each surface (the paths typing-frame-bench.py takes)."""

    def __init__(self, bench):
        self.bench, self.made = bench, {}

    def rpc(self, method, params=None, timeout=60):
        return self.bench.rpc(method, params, timeout)

    def action(self, name, args=None, settle=0.0, timeout=60):
        reply = self.rpc("action.run", {"action": name, "args": args or {}, "focus": True, "origin": "script"}, timeout)
        if settle:
            time.sleep(settle)  # test harness: the layout settles before the keys
        return reply

    def workspace(self, name):
        """(id, first pane id) of the workspace named `name`, waiting for it up to 20 s."""
        end = time.monotonic() + 20
        while time.monotonic() < end:  # bounded wait for the live app
            snap = self.rpc("snapshot.get") or {}
            for w in (snap.get("topology") or snap).get("workspaces") or []:
                if (w.get("name") or w.get("title")) == name:
                    panes = [p for sc in w.get("screens") or [] for p in sc.get("panes") or [] if not p.get("dock")]
                    return w.get("id"), (panes[0].get("id") if panes else None)
            time.sleep(0.25)
        return None, None

    def cli(self, *args):
        env = {k: v for k, v in os.environ.items() if not k.startswith("CMUX_")}
        env["CMUX_NEXT_CONFIG_FILE"] = os.path.join(self.bench.scratch, "cmux.json")
        return subprocess.run([self.bench.cli, "--app-socket", self.bench.socket, *args], env=env, capture_output=True,
                              text=True, timeout=60, stdin=subprocess.DEVNULL)

    def terminal(self):
        if "terminal" not in self.made:
            self.cli("workspace", "create", "--name", "glass", "--focus", "--shell", "exec /bin/zsh -f")
            self.made["terminal"] = self.workspace("glass")
            time.sleep(2)  # the prompt draws
        ws, pane = self.made["terminal"]
        self.action("goToWorkspace", {"workspace": ws})
        if pane:
            self.rpc("action.run", {"action": "pane.focus", "target": f"pane:{pane}", "focus": True, "origin": "script"})
        time.sleep(0.5)  # focus settles
        return bool(ws)

    def home(self):
        if "home" not in self.made:
            self.cli("workspace", "create", "--name", "glass home", "--focus")
            self.made["home"] = self.workspace("glass home")
            self.action("goToWorkspace", {"workspace": self.made["home"][0]}, settle=1.0)
            self.rpc("debug.home_native_fixture.open", {"new": True})
            time.sleep(2)  # the transcript lays out
        self.action("goToWorkspace", {"workspace": self.made["home"][0]}, settle=0.5)
        focused = self.rpc("debug.home.drive", {"action": "focus"})
        return isinstance(focused, dict) and bool(focused.get("ok"))

    def omnibar(self):
        if "omnibar" not in self.made:
            self.action("openBrowser.chromium", {"url": "about:blank"}, settle=4.0, timeout=120)
            self.made["omnibar"] = True
        self.action("focusBrowserAddressBar", settle=0.5)
        return bool((self.rpc("debug.omnibar") or {}).get("field_editor_active"))

    def after(self, surface):
        """Leaves the surface as it was: the typed line cleared, the address bar closed."""
        if surface == "terminal":
            self.action("terminal.sendText", {"text": "\x15"})
        elif surface == "omnibar":
            self.rpc("debug.key", {"key": "escape"})


def macos():
    try:
        version = subprocess.run(["sw_vers", "-productVersion"], capture_output=True, text=True, timeout=30).stdout.strip()
    except (OSError, subprocess.TimeoutExpired):
        version = ""
    try:
        return version, int(version.split(".")[0])
    except ValueError:
        return version, 0


def launch_env(isolated_key):
    """BenchApp's `env`: frontmost (real keys go to the frontmost app) and still an isolated launch, so the test window
    frame applies and the app claims no hot keys, shim, login item or import offer (bench_launch.SHIPPING_ENV)."""
    return {"CMUX_NEXT_NO_ACTIVATE": None, isolated_key: "1"}


def out_dir(out, environ):
    """--out, else $NX_ARTIFACTS/glass, else a new temporary directory."""
    if out:
        return os.path.abspath(out)
    if environ.get("NX_ARTIFACTS"):
        return os.path.join(os.path.abspath(environ["NX_ARTIFACTS"]), "glass")
    return tempfile.mkdtemp(prefix="glass-")


def run(opts):
    out = out_dir(opts.out, os.environ)
    note(f"artifacts in {out}")
    os.makedirs(out, exist_ok=True)
    binary, error = compile_helper(out)
    if error:
        note(error)
        return 2
    refused = check_grant(binary)
    if refused:
        print(f"glass: refused: {refused}", flush=True)
        return 2
    from bench_launch import ISOLATED_LAUNCH_KEY, BenchApp, LaunchError
    trace_tool = load("trace_tool", "trace.py")
    version, major = macos()
    offset_ns, offset_from = current_offset(major, opts.current_offset_ns)
    report = {"host": os.uname().nodename, "macos": version, "macos_major": major, "current_offset_ns": offset_ns,
              "current_offset_from": offset_from, "opts": vars(opts), "surfaces": {}, "log": []}
    bench = BenchApp(os.path.abspath(opts.app.rstrip("/")), out=out, window=WINDOW, log_name="app.log",
                     env=launch_env(ISOLATED_LAUNCH_KEY))
    with open(os.path.join(bench.scratch, "ghostty"), "w") as handle:
        handle.write("cursor-style-blink = false\n")  # a blink would be taken for a glyph
    stream = trace_tool.SignpostStream(os.path.join(out, "signposts.ndjson"))
    captures = {}
    try:
        try:
            bench.launch(timeout=180)
        except LaunchError as failure:
            note(f"the app did not come up: {failure.reason}")
            report["launch_failure"] = failure.reason
            return 2
        stream.start()
        surfaces = Surfaces(bench)
        for surface in opts.surfaces.split(","):
            if not getattr(surfaces, surface)():
                note(f"{surface}: the surface did not take the keyboard focus; measuring anyway")
            activated = bench.activate()
            if not activated.get("activated"):
                note(f"{surface}: not frontmost ({activated.get('error')}); real keys may go elsewhere")
            captures[surface] = capture_keys(binary, out, surface, bench.process.pid, opts)
            surfaces.after(surface)
            if captures[surface]["error"]:
                note(f"{surface}: glass-capture: {captures[surface]['error']}")
    finally:
        stream.stop()
        pid = bench.process.pid if bench.process else None
        bench.stop()
    slots, unplaced = trace_tool.input_latency_slots(trace_tool.read_signposts(os.path.join(out, "signposts.ndjson")))
    report["slots"] = {"read": len(slots), "unplaced": unplaced}
    every = []
    for surface, capture in captures.items():
        hz = (capture["ready"] or {}).get("hz")
        rows = pair(capture, slots, pid, opts.min_pixels, opts.quiet_ms)
        every += rows
        report["surfaces"][surface] = {"ready": capture["ready"], "error": capture["error"],
                                       **summarize(rows, hz, offset_ns), "rows": rows}
    hz = next((c["ready"]["hz"] for c in captures.values() if c["ready"]), None)
    report["all"] = summarize(every, hz, offset_ns)
    if "suggested_offset_ns" in report["all"]:
        table = offset_table(open(OFFSET_SWIFT).read()) if os.path.exists(OFFSET_SWIFT) else {}
        report["suggestion"] = suggestion_line(major, report["all"]["suggested_offset_ns"], table)
    path = opts.json or os.path.join(out, "glass.json")
    with open(path, "w") as handle:
        json.dump(report, handle, indent=1)
    print_report(report)
    return 0


def print_report(report):
    for name, entry in list(report["surfaces"].items()) + [("all", report["all"])]:
        glass, diff, residual = entry.get("glass_ms") or {}, entry.get("abs_glass_minus_presented_ms") or {}, \
            entry.get("residual_ms") or {}
        note(f"{name}: keys {entry['keys']} {entry['counts']}; glass p50 {glass.get('p50')} p95 {glass.get('p95')} p99 "
             f"{glass.get('p99')} ms; |glass - presented| p95 {diff.get('p95')} ms; residual p95 {residual.get('p95')} ms; "
             f"sources {entry['sources']}; DC3 {entry['dc3']}")
    if report.get("suggestion"):
        note(f"macOS {report['macos']}: suggested PresentationOffset {report['all']['suggested_offset_ns']} ns "
             f"(now {report['current_offset_ns']} ns from {report['current_offset_from']}):")
        note(f"  {report['suggestion']}")
    else:
        note("no estimated presented time paired with a glass frame: no offset to suggest")


# ---------------------------------------------------------------- self-test

def self_test():
    """Canned helper files and canned input.latency signposts through the parser, the pairing, the report, the
    refusal and the offset table; and the protocol words against the Swift helper."""
    failures = []

    def check(name, condition):
        print(f"{'ok  ' if condition else 'FAIL'} {name}", flush=True)
        if not condition:
            failures.append(name)

    fixtures = load("trace_fixtures", "trace_fixtures.py")
    trace_tool = load("trace_tool", "trace.py")
    ms_ = 1_000_000
    pid = 42
    base = 9_000 * ms_
    # Keys 120 ms apart; the first is warmup. Frames: key 1's glyph at +14 ms (a 2-pixel flicker at +5 ms is under
    # --min-pixels); key 2's glyph at +22 ms; a blink 10 ms before key 3 (unsettled); key 4 changes nothing; key 5's
    # glyph at +12 ms but no slot; key 6's glyph at +16 ms with a metalPresented slot (reported, not in the offset).
    keys = [base + i * 120 * ms_ for i in range(7)]
    capture_text = "\n".join([
        "grant screen=yes accessibility=yes",
        "ready 1 40 40 160 30 120.0 caret",
        f"key 0 {keys[0]} 7 1", f"frame {keys[0] + 15 * ms_} 40",
        f"key 1 {keys[1]} 51 0", f"frame {keys[1] + 5 * ms_} 2", f"frame {keys[1] + 14 * ms_} 38",
        f"key 2 {keys[2]} 7 0", f"frame {keys[2] + 22 * ms_} 41",
        f"frame {keys[3] - 10 * ms_} 60", f"key 3 {keys[3]} 51 0", f"frame {keys[3] + 13 * ms_} 37",
        f"key 4 {keys[4]} 7 0",
        f"key 5 {keys[5]} 51 0", f"frame {keys[5] + 12 * ms_} 35",
        f"key 6 {keys[6]} 7 0", f"frame {keys[6] + 16 * ms_} 39", f"status {keys[6] + 30 * ms_} stopped",
        "end", "garbage line", "frame notanumber 3"])
    capture = parse_capture(capture_text)
    check("parse: grant, ready, keys, frames, statuses, end",
          capture["grant"] == {"screen": True, "accessibility": True} and capture["ready"]["hz"] == 120.0
          and capture["ready"]["source"] == "caret" and len(capture["keys"]) == 7 and len(capture["frames"]) == 8
          and capture["statuses"] == [(keys[6] + 30 * ms_, "stopped")] and capture["ended"])

    # Slots: the generated time is the event's (a few us before the post); presented estimates 10 ms, 18 ms, 11 ms.
    slot_specs = [(0, 1, 9_000, 0), (1, 1, 10_000, 0), (2, 1, 18_000, 5), (3, 1, 11_000, 0), (4, 1, 9_000, 0),
                  (6, 1, 15_500, 1)]
    slots_in = []
    for key_index, entry, presented_us, source in slot_specs:
        slots_in.append({"kind": 0, "target": 1, "entry": 0 if entry else 1, "source": source, "frame": 1,
                         "gen_ns": keys[key_index] - 3_000, "arrived_us": 300, "dispatch_end_us": 900,
                         "commit_us": 2_000, "presented_us": presented_us})
    slots_in.append({"kind": 0, "target": 1, "entry": 1, "source": 0, "frame": 1, "gen_ns": keys[5] + 1_000,
                     "presented_us": 8_000})  # automation: not key 5's
    slots_in.append({"kind": 3, "target": 1, "entry": 0, "source": 0, "frame": 1, "gen_ns": keys[5] + 2_000,
                     "presented_us": 8_000})  # a click: not key 5's
    lines = ["#timebase 1/1", "#continuous-minus-uptime-us 0"]
    for index, slot in enumerate(slots_in):
        lines.append(json.dumps({"eventType": "signpostEvent", "subsystem": trace_tool.SUBSYSTEM, "category": "input",
                                 "signpostName": "input.latency", "signpostID": 100 + index, "signpostType": "event",
                                 "processID": pid, "threadID": 259, "machTimestamp": slot["gen_ns"] + 30 * ms_,
                                 "eventMessage": fixtures.input_latency_message(slot)}))
    with tempfile.TemporaryDirectory() as scratch:
        path = os.path.join(scratch, "signposts.ndjson")
        with open(path, "w") as handle:
            handle.write("\n".join(lines) + "\n")
        slots, unplaced = trace_tool.input_latency_slots(trace_tool.read_signposts(path))
    check("signposts: every slot read through trace.py", len(slots) == len(slots_in) and unplaced == 0)
    rows = pair(capture, slots, pid, min_pixels=6, quiet_ms=40)
    status = {r["index"]: r["status"] for r in rows}
    check("pair: warmup left out, each key's status",
          status == {1: "ok", 2: "ok", 3: "unsettled", 4: "no_frame", 5: "no_slot", 6: "ok"})
    by = {r["index"]: r for r in rows}
    check("pair: glass is the first frame over --min-pixels", by[1]["glass_ns"] == keys[1] + 14 * ms_)
    check("pair: a key's window ends at the next key", by[4]["glass_ns"] is None)
    check("pair: the slot is the key's (generated a few us before the post)",
          by[1]["generated_ns"] == keys[1] - 3_000 and by[1]["presented_ns"] == keys[1] - 3_000 + 10 * ms_)
    check("pair: an automation slot or a click is no key's", by[5]["generated_ns"] is None)
    check("pair: another process's slots are no key's",
          all(r["status"] != "ok" for r in pair(capture, slots, pid + 1, 6, 40)))

    report = summarize(rows, 120.0, current_offset_ns=1_000_000)
    # Estimated rows: key 1 glass 14.003 - presented 10 = +4 ms; key 2 22.003 - 18 = +4 ms. Key 6 is metalPresented.
    check("report: counts and sources", report["counts"] == {"ok": 3, "unsettled": 1, "no_frame": 1, "no_slot": 1}
          and report["sources"] == {"estimatedVsync": 1, "nominalRefresh": 1, "metalPresented": 1}
          and report["estimated"] == 2)
    check("report: glass from the generated time", report["glass_ms"]["max"] == 22.0 and report["glass_ms"]["n"] == 3)
    check("report: glass - presented over estimated slots only",
          report["glass_minus_presented_ms"]["n"] == 2 and report["glass_minus_presented_ms"]["p50"] == 4.0)
    check("report: suggested offset = current + median", report["suggested_offset_ns"] == 1_000_000 + 4_003_000)
    check("report: DC3 lines", report["dc3"]["refresh_ms"] == 8.33 and report["dc3"]["residual_within_refresh"] is True
          and report["dc3"]["glass_p99_within_limit"] is True)
    empty = summarize([], None, 0)
    check("report: nothing measured suggests nothing", "suggested_offset_ns" not in empty
          and empty["dc3"]["residual_within_refresh"] is None)

    check("refuse: no Screen Recording grant names it",
          "Screen Recording" in (refusal({"screen": False, "accessibility": True}) or ""))
    check("refuse: no Accessibility grant names it",
          "Accessibility" in (refusal({"screen": True, "accessibility": False}) or ""))
    check("refuse: the helper's own error line", refusal(parse_capture(
        "grant screen=no accessibility=yes\nerror no-screen-recording-grant: this process may not capture")["grant"],
        "no-screen-recording-grant: x") == "no-screen-recording-grant: x")
    check("refuse: both grants measure", refusal({"screen": True, "accessibility": True}) is None)

    class StubBench:
        scratch, socket = tempfile.gettempdir(), "/nonexistent.sock"

        @property
        def cli(self):  # BenchApp.cli is a property that returns a str
            return "/bin/echo"

    echoed = Surfaces(StubBench()).cli("workspace", "create")
    check("surfaces: the CLI path is BenchApp.cli (a str property)",
          echoed.returncode == 0 and echoed.stdout.split() == ["--app-socket", "/nonexistent.sock", "workspace", "create"])
    import bench_launch
    env = launch_env(bench_launch.ISOLATED_LAUNCH_KEY)
    check("launch: frontmost and isolated (the test window frame applies)",
          env == {"CMUX_NEXT_NO_ACTIVATE": None, "CMUX_NEXT_ISOLATED_LAUNCH": "1"})
    check("out: --out wins", out_dir("rel", {"NX_ARTIFACTS": "/a"}) == os.path.abspath("rel"))
    check("out: $NX_ARTIFACTS/glass without --out", out_dir(None, {"NX_ARTIFACTS": "/a"}) == "/a/glass")
    made = out_dir(None, {})
    check("out: a new temporary directory otherwise", os.path.isdir(made) and os.path.basename(made).startswith("glass-"))
    os.rmdir(made)

    sample = "    private static let calibrated: [Int: Int64] = [26: 1_200_000, 27: -300_000]\n"
    check("offset table: parsed", offset_table(sample) == {26: 1_200_000, 27: -300_000})
    check("offset table: empty literal", offset_table("static let calibrated: [Int: Int64] = [:]") == {})
    check("offset: override wins", current_offset(26, 5, path="/nonexistent") == (5, "--current-offset-ns"))
    check("offset: suggestion literal",
          suggestion_line(26, 2_500_000, {27: -300_000}) == "private static let calibrated: [Int: Int64] = "
          "[26: 2_500_000, 27: -300_000]")
    if os.path.exists(OFFSET_SWIFT):
        with open(OFFSET_SWIFT) as handle:
            check("offset table: the real PresentationOffset.swift has the literal", CALIBRATED.search(handle.read()))
    with open(HELPER) as handle:
        swift = handle.read()
    check("protocol: the helper writes every line this parser reads",
          all(word in swift for word in ('"grant screen=', '"ready \\(', '"key \\(', '"frame \\(', '"status \\(',
                                         '"end"', '"error ', "no-screen-recording-grant", "no-accessibility-grant")))
    print(f"{'PASS' if not failures else 'FAIL'}: {len(failures)} failing", flush=True)
    return 1 if failures else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--app")
    parser.add_argument("--out", help="artifacts (default: $NX_ARTIFACTS/glass, else a new temporary directory)")
    parser.add_argument("--json")
    parser.add_argument("--surfaces", default="terminal,home,omnibar")
    parser.add_argument("--samples", type=int, default=200, help="measured keys per surface (after 6 warmup keys)")
    parser.add_argument("--interval-ms", type=int, default=120, help="between keys; under the caret's blink period")
    parser.add_argument("--min-pixels", type=int, default=6, help="changed pixels that make a frame a glyph's")
    parser.add_argument("--quiet-ms", type=int, default=40, help="no change this long before a key, or it is unsettled")
    parser.add_argument("--current-offset-ns", type=int, help="the app's PresentationOffset now (default: the source)")
    opts = parser.parse_args()
    if opts.self_test:
        sys.exit(self_test())
    if not opts.app:
        parser.error("--app is required (or --self-test)")
    unknown = [s for s in opts.surfaces.split(",") if s not in ("terminal", "home", "omnibar")]
    if unknown:
        parser.error(f"unknown surfaces {unknown}: terminal, home, omnibar")
    sys.exit(run(opts))


if __name__ == "__main__":
    main()
