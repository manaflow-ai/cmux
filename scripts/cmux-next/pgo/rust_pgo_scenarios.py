#!/usr/bin/env python3
"""The Rust PGO scenarios (plans/cmux-next/chrome-parity/p08-startup.md, section F, task 056).

  rust_pgo_scenarios.py ffi --lib LIB --repo REPO [--rounds N]
  rust_pgo_scenarios.py coverage --lib LIB --repo REPO --profdata PROFILE --tool LLVM_PROFDATA
  rust_pgo_scenarios.py daemon --binary CMUX_TUI [--rounds N] [--tabs N]
  rust_pgo_scenarios.py ab --base CMUX_TUI --pgo CMUX_TUI [--rounds N] [--tabs N] [--json PATH]

ffi     the app's calls into cmux-app-ffi, through the C ABI of the instrumented library (rust-pgo.sh generate
        links it whole into a shared library). Each round replays the palette ranker corpus recorded from the
        app (install a snapshot's entries once per version, then one rank per query), the focus rule corpus
        recorded from the Swift reducer (type-ahead queue and child-window key decisions) and what each
        animation frame asks of cmux-motion (every spring stepped at 120 Hz to rest, the tab strip tweens with a
        mid-flight retarget, easing samples, color mixes and the strip geometry), then rust_pgo_ffi.py: the
        sidebar document mirror, the window focus machine, the other reducer ops, the remote desktop core on
        loopback and the remote tab client. Every answer is checked, so a wrong shape fails instead of training
        the profile on the error path.
coverage  fails unless every C ABI that the app's Swift sources call and the library exports has counts in the
        merged FFI profile (rust-pgo.sh run checks it): LLVM compiles a function with no counts as cold code.
daemon  a headless daemon on a private socket and state directory, driven as the app drives it: identify and the
        reads the app makes at connect, then per tab new-tab (as the app does, with its own terminal_id), send,
        read-screen and the list and layout reads, then close-terminal; it ends through shutdown-daemon so the
        process exits through exit(3) and writes its profile (Chrome's generate_profile.py quits the browser
        the same way).
ab      the test phase: the same daemon scenario on two builds in alternation (ABBA order per round, a new
        daemon each time), then p50 and p95 per request class and over all requests, and the change. The task
        asks for -5 % at p50 and p95.

Percentiles are scripts/perf-lab/perf_stats.py pct (linear interpolation).
"""
import argparse
import ctypes
import importlib.util
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
sys.path.insert(0, HERE)
import rust_pgo_ffi  # noqa: E402

OK = 0
ERR_BUFFER = -3


def _load_stats():
    path = os.path.join(REPO, "scripts", "perf-lab", "perf_stats.py")
    spec = importlib.util.spec_from_file_location("perf_lab_perf_stats", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


pct = _load_stats().pct


ScenarioError = rust_pgo_ffi.ScenarioError


# ---------- cmux-app-ffi ----------


class Spring(ctypes.Structure):
    _fields_ = [("response", ctypes.c_double), ("damping_fraction", ctypes.c_double)]


class SpringState(ctypes.Structure):
    _fields_ = [("value", ctypes.c_double), ("velocity", ctypes.c_double), ("target", ctypes.c_double)]


class Policy(ctypes.Structure):
    _fields_ = [
        ("speed", ctypes.c_uint8),
        ("reduce_motion", ctypes.c_bool),
        ("bounce", ctypes.c_uint8),
        ("pane_animations", ctypes.c_bool),
        ("new_tab", ctypes.c_bool),
        ("new_workspace", ctypes.c_bool),
    ]


class Tween(ctypes.Structure):
    _fields_ = [("duration", ctypes.c_double), ("curve", ctypes.c_uint8)]


class TweenState(ctypes.Structure):
    _fields_ = [
        ("value", ctypes.c_double),
        ("from_", ctypes.c_double),
        ("target", ctypes.c_double),
        ("elapsed", ctypes.c_double),
        ("duration", ctypes.c_double),
    ]


class StripGeometry(ctypes.Structure):
    _fields_ = [(name, ctypes.c_double) for name in (
        "max_width", "open_start_width", "close_end_width", "min_active_width", "min_inactive_width",
        "pinned_width", "reorder_threshold", "closing_mode_below_pad", "closing_mode_trailing_pad",
        "closing_mode_exit_delay",
    )]


SPRING_TOKENS = 13  # cmux_motion_ffi.h: 0 move ... 12 tabOpen
TWEEN_TOKENS = 3  # 0 tabOpen, 1 tabClose, 2 tabMove
CURVES = 4  # 0 easeOutQuad, 1 easeOut, 2 easeInOut, 3 linear


def bind(lib):
    """Declares the C signatures the scenarios call (the headers under cmux-tui/crates)."""
    u8p = ctypes.POINTER(ctypes.c_uint8)
    double4 = ctypes.POINTER(ctypes.c_double)
    sigs = {
        "cmux_palette_ranker_new": (ctypes.c_void_p, []),
        "cmux_palette_ranker_free": (None, [ctypes.c_void_p]),
        "cmux_palette_ranker_install": (ctypes.c_int32, [ctypes.c_void_p, ctypes.c_int64, ctypes.c_char_p, ctypes.c_size_t]),
        "cmux_palette_ranker_rank": (ctypes.c_int32, [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_size_t,
                                                      ctypes.POINTER(u8p), ctypes.POINTER(ctypes.c_size_t)]),
        "cmux_layout_reducer_json": (ctypes.c_int32, [ctypes.c_char_p, ctypes.c_size_t, ctypes.c_char_p,
                                                      ctypes.c_void_p, ctypes.c_size_t, ctypes.POINTER(ctypes.c_size_t)]),
        "cmux_motion_spring_base": (ctypes.c_bool, [ctypes.c_uint8, ctypes.POINTER(Spring)]),
        "cmux_motion_spring_is_structural": (ctypes.c_bool, [ctypes.c_uint8]),
        "cmux_motion_resolve": (Spring, [Spring, ctypes.c_bool, Policy]),
        "cmux_motion_step": (ctypes.c_bool, [ctypes.POINTER(SpringState), ctypes.c_double, Spring, ctypes.c_double]),
        "cmux_motion_animates": (ctypes.c_bool, [ctypes.c_uint8, Policy]),
        "cmux_motion_fade_seconds": (ctypes.c_double, [ctypes.c_uint8, Policy]),
        "cmux_motion_tween_base": (ctypes.c_bool, [ctypes.c_uint8, ctypes.POINTER(Tween)]),
        "cmux_motion_tween_seconds": (ctypes.c_double, [ctypes.c_uint8, Policy]),
        "cmux_motion_tween_retarget": (ctypes.c_bool, [ctypes.POINTER(TweenState), ctypes.c_double, ctypes.c_double]),
        "cmux_motion_tween_step": (ctypes.c_bool, [ctypes.POINTER(TweenState), ctypes.c_double, ctypes.c_uint8]),
        "cmux_motion_ease": (ctypes.c_double, [ctypes.c_uint8, ctypes.c_double]),
        "cmux_motion_cubic_bezier": (ctypes.c_double, [ctypes.c_double] * 5),
        "cmux_motion_spring_progress_monotone": (ctypes.c_double, [Spring, ctypes.c_double]),
        "cmux_motion_spring_arrival": (ctypes.c_double, [Spring]),
        "cmux_motion_mix_rgba": (ctypes.c_bool, [double4, double4, ctypes.c_double, ctypes.c_uint8, double4]),
        "cmux_motion_tab_strip_geometry": (ctypes.c_bool, [ctypes.c_uint8, ctypes.POINTER(StripGeometry)]),
    }
    for name, (restype, argtypes) in sigs.items():
        fn = getattr(lib, name)
        fn.restype = restype
        fn.argtypes = argtypes
    return lib


def encode(value):
    return json.dumps(value, separators=(",", ":"), ensure_ascii=False).encode()


def load_json(path):
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def palette(lib, corpus):
    handle = lib.cmux_palette_ranker_new()
    if not handle:
        raise ScenarioError("cmux_palette_ranker_new returned null")
    calls = 0
    try:
        installed = None
        for case in corpus["cases"]:
            entry_set = corpus["sets"][case["set"]]
            version = entry_set["version"]
            if not case.get("inline") and installed != version:
                entries = encode(entry_set["entries"])
                code = lib.cmux_palette_ranker_install(handle, version, entries, len(entries))
                if code != OK:
                    raise ScenarioError(f"palette install {version}: code {code}")
                installed = version
            request = encode(case["request"])
            response = ctypes.POINTER(ctypes.c_uint8)()
            length = ctypes.c_size_t(0)
            code = lib.cmux_palette_ranker_rank(handle, request, len(request), ctypes.byref(response), ctypes.byref(length))
            if code != OK:
                raise ScenarioError(f"palette {case.get('name', '?')}: code {code}")
            json.loads(ctypes.string_at(response, length.value))
            calls += 1
    finally:
        lib.cmux_palette_ranker_free(handle)
    return calls


def reducer_json(lib, operation, request):
    body = encode(request)
    capacity = 4096
    while True:
        output = ctypes.create_string_buffer(capacity)
        length = ctypes.c_size_t(0)
        code = lib.cmux_layout_reducer_json(body, len(body), operation, output, capacity, ctypes.byref(length))
        if code == ERR_BUFFER and length.value > capacity:
            capacity = length.value
            continue
        if code != OK:
            raise ScenarioError(f"{operation.decode()}: code {code} for {body[:200]!r}")
        return json.loads(output.raw[:length.value])


def focus(lib, corpus):
    calls = 0
    for case in corpus["childWindow"]:
        answer = reducer_json(lib, b"focus_child_window_key", {"facts": case["facts"]})
        if answer.get("shouldReclaim") != case["shouldReclaim"]:
            raise ScenarioError(f"focus_child_window_key answered {answer} for {case['facts']}")
        calls += 1
    for sequence in corpus["typeAhead"]:
        queue = {"text": ""}
        for entry in sequence["ops"]:
            op = entry["op"]
            if "drop" in op:
                queue = {"text": ""}
                continue
            queue = reducer_json(lib, b"focus_type_ahead", {"queue": queue, "op": op})["queue"]
            calls += 1
    return calls


def motion(lib):
    calls = 0
    policy = Policy(speed=1, reduce_motion=False, bounce=0, pane_animations=True, new_tab=True, new_workspace=False)
    frame = 1.0 / 120.0
    for token in range(SPRING_TOKENS):
        base = Spring()
        if not lib.cmux_motion_spring_base(token, ctypes.byref(base)):
            raise ScenarioError(f"cmux_motion_spring_base({token}) refused")
        spring = lib.cmux_motion_resolve(base, lib.cmux_motion_spring_is_structural(token), policy)
        for start, target in ((0.0, 1.0), (1.0, 0.0), (0.0, 240.0)):
            state = SpringState(value=start, velocity=0.0, target=target)
            for _ in range(5 * 120):
                calls += 1
                if not lib.cmux_motion_step(ctypes.byref(state), frame, spring, 0.001):
                    break
            else:
                raise ScenarioError(f"spring {token} did not settle in 5 s")
        lib.cmux_motion_spring_arrival(spring)
        for step in range(61):
            lib.cmux_motion_spring_progress_monotone(spring, step / 60.0)
        calls += 62
    for kind in range(3):
        lib.cmux_motion_animates(kind, policy)
    for fade in range(8):
        lib.cmux_motion_fade_seconds(fade, policy)
    for token in range(TWEEN_TOKENS):
        tween = Tween()
        if not lib.cmux_motion_tween_base(token, ctypes.byref(tween)):
            raise ScenarioError(f"cmux_motion_tween_base({token}) refused")
        seconds = lib.cmux_motion_tween_seconds(token, policy)
        for curve in range(CURVES):
            state = TweenState(value=0.0, from_=0.0, target=0.0, elapsed=0.0, duration=0.0)
            lib.cmux_motion_tween_retarget(ctypes.byref(state), 200.0, seconds)
            for index in range(240):
                if index == 6:
                    # A tab closes mid-open: the target moves, as in the strip.
                    lib.cmux_motion_tween_retarget(ctypes.byref(state), 120.0, seconds)
                calls += 1
                if not lib.cmux_motion_tween_step(ctypes.byref(state), frame, curve):
                    break
    for curve in range(CURVES):
        for step in range(101):
            lib.cmux_motion_ease(curve, step / 100.0)
            lib.cmux_motion_cubic_bezier(0.2, 0.0, 0.0, 1.0, step / 100.0)
            calls += 2
    rgba = ctypes.c_double * 4
    out = rgba()
    for space in range(2):
        for step in range(61):
            if not lib.cmux_motion_mix_rgba(rgba(0.1, 0.2, 0.3, 1.0), rgba(0.9, 0.8, 0.2, 0.5), step / 60.0, space, out):
                raise ScenarioError("cmux_motion_mix_rgba refused")
            calls += 1
    geometry = StripGeometry()
    for density in range(2):
        if not lib.cmux_motion_tab_strip_geometry(density, ctypes.byref(geometry)):
            raise ScenarioError(f"cmux_motion_tab_strip_geometry({density}) refused")
    return calls


def run_ffi(args):
    crates = os.path.join(args.repo, "cmux-tui", "crates")
    palette_corpus = load_json(os.path.join(crates, "cmux-palette-ranker", "tests", "corpus", "palette-corpus.json"))
    focus_corpus = load_json(os.path.join(crates, "cmux-layout-reducer-ffi", "tests", "focus", "corpus.json"))
    lib = rust_pgo_ffi.bind(bind(ctypes.CDLL(os.path.abspath(args.lib))))
    corpora = rust_pgo_ffi.corpora(args.repo)
    totals = {"palette": 0, "focus": 0, "motion": 0}
    for _ in range(args.rounds):
        totals["palette"] += palette(lib, palette_corpus)
        totals["focus"] += focus(lib, focus_corpus)
        totals["motion"] += motion(lib)
        for name, count in rust_pgo_ffi.run_round(lib, corpora).items():
            totals[name] = totals.get(name, 0) + count
    print("ffi: " + ", ".join(f"{name} {count} calls" for name, count in totals.items()))
    # The profile is written by the instrumented library's exit handler when this process exits.
    return 0


def run_coverage(args):
    lib = ctypes.CDLL(os.path.abspath(args.lib))
    checked = rust_pgo_ffi.coverage(lib, args.repo, args.tool, args.profdata)
    print(f"ffi coverage: each of the {checked} C ABIs the app calls has counts")
    return 0


# ---------- cmux-tui daemon ----------


class Daemon:
    """A headless cmux-tui daemon on a private socket and state directory."""

    def __init__(self, binary, start_timeout=20.0):
        self.dir = tempfile.mkdtemp(prefix="cmux-rust-pgo-")
        self.socket = os.path.join(self.dir, "s.sock")
        self.log = open(os.path.join(self.dir, "err.log"), "w")
        self.next_id = 0
        env = dict(os.environ)
        env["SHELL"] = "/bin/sh"
        started = time.perf_counter()
        self.process = subprocess.Popen(
            [binary, "--headless", "--session", "rust-pgo", "--socket", self.socket, "--state", os.path.join(self.dir, "state")],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=self.log, env=env)
        deadline = started + start_timeout
        while True:
            if self.process.poll() is not None:
                raise ScenarioError(f"the daemon exited with {self.process.returncode} before it served: {self.tail()}")
            try:
                self.request("ping")
                break
            except OSError:
                if time.perf_counter() > deadline:
                    raise ScenarioError(f"the daemon did not serve its socket in {start_timeout} s: {self.tail()}")
                time.sleep(0.02)  # bench: the daemon binds its socket
        self.start_ms = (time.perf_counter() - started) * 1000

    def tail(self):
        self.log.flush()
        with open(os.path.join(self.dir, "err.log"), encoding="utf-8", errors="replace") as handle:
            return handle.read()[-2000:]

    def request(self, cmd, **params):
        """One request on a fresh connection, as the CLI sends it. Returns (reply, milliseconds)."""
        self.next_id += 1
        body = dict(params, id=self.next_id, cmd=cmd)
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
            sock.settimeout(30)
            started = time.perf_counter()
            sock.connect(self.socket)
            sock.sendall((json.dumps(body) + "\n").encode())
            buffer = b""
            while True:
                while b"\n" not in buffer:
                    chunk = sock.recv(1 << 20)
                    if not chunk:
                        raise ConnectionError(f"{cmd}: the socket closed before the reply")
                    buffer += chunk
                line, buffer = buffer.split(b"\n", 1)
                reply = json.loads(line)
                if reply.get("id") == body["id"]:
                    return reply, (time.perf_counter() - started) * 1000

    def stop(self):
        """shutdown-daemon with end_terminals: the daemon exits through exit(3) and writes its profile."""
        try:
            identity, _ = self.request("identify")
            data = identity.get("data") or {}
            reply, _ = self.request("shutdown-daemon", pid=data.get("pid"), generation=data.get("generation"), end_terminals=True)
            if not reply.get("ok"):
                raise ScenarioError(f"shutdown-daemon failed: {reply.get('error')}")
            self.process.wait(30)
        finally:
            if self.process.poll() is None:
                self.process.kill()
                self.process.wait()
            self.log.close()
            shutil.rmtree(self.dir, ignore_errors=True)
        if self.process.returncode != 0:
            raise ScenarioError(f"the daemon exited with {self.process.returncode} after shutdown-daemon")


# The reads the app makes when it connects, and after each change (the classes of command_names.rs).
CONNECT_READS = ("identify", "list-workspaces", "list-terminals", "list-clients", "ids")
CHANGE_READS = ("list-workspaces", "list-terminals", "ids", "export-layout")


def checked(daemon, samples, cmd, kind, **params):
    reply, ms = daemon.request(cmd, **params)
    if not reply.get("ok"):
        raise ScenarioError(f"{cmd} failed: {reply.get('error')}")
    samples.setdefault(kind, []).append(ms)
    samples.setdefault(cmd, []).append(ms)
    return reply.get("data") or {}


def surface_of(data):
    for key in ("surface", "surface_id"):
        if isinstance(data.get(key), int):
            return data[key]
    raise ScenarioError(f"new-tab named no surface: {sorted(data)}")


def daemon_round(binary, tabs):
    """One daemon life: start, the app's requests, shutdown. Returns {request or class: [ms]} and the start."""
    samples = {}
    daemon = Daemon(binary)
    try:
        for cmd in CONNECT_READS:
            checked(daemon, samples, cmd, "query")
        terminals = []
        for index in range(tabs):
            terminal_id = uuid.uuid4().hex
            data = checked(daemon, samples, "new-tab", "create", terminal_id=terminal_id, env={"SHELL": "/bin/sh"})
            surface = surface_of(data)
            terminals.append(terminal_id)
            checked(daemon, samples, "send", "terminal_io", surface=surface, text=f"echo rust-pgo {index}\n")
            checked(daemon, samples, "read-screen", "terminal_io", surface=surface)
            for cmd in CHANGE_READS:
                checked(daemon, samples, cmd, "query")
        for terminal_id in terminals:
            checked(daemon, samples, "close-terminal", "topology", terminal_id=terminal_id)
            checked(daemon, samples, "list-terminals", "query")
    except BaseException:
        try:
            daemon.stop()
        except ScenarioError:
            pass  # the first failure is the one to report
        raise
    daemon.stop()
    return samples, daemon.start_ms


def run_daemon(args):
    count = 0
    for _ in range(args.rounds):
        samples, _ = daemon_round(args.binary, args.tabs)
        count += sum(len(values) for key, values in samples.items() if key in CLASSES)
    print(f"daemon: {args.rounds} daemon lives, {count} requests")
    return 0


CLASSES = ("query", "create", "terminal_io", "topology")


def change(base, pgo):
    return None if not base or pgo is None else (pgo - base) / base * 100


def summarize(results):
    """{key: {base: {p50, p95}, pgo: {...}, change_p50, change_p95}} over each class, all requests and start."""
    out = {}
    for key in ("all",) + CLASSES + ("start",):
        row = {}
        for name in ("base", "pgo"):
            values = results[name].get(key, [])
            row[name] = {"n": len(values), "p50": pct(values, 0.5), "p95": pct(values, 0.95)}
        row["change_p50"] = change(row["base"]["p50"], row["pgo"]["p50"])
        row["change_p95"] = change(row["base"]["p95"], row["pgo"]["p95"])
        out[key] = row
    return out


def run_ab(args):
    builds = {"base": args.base, "pgo": args.pgo}
    results = {"base": {}, "pgo": {}}
    for round_index in range(args.rounds):
        order = ("base", "pgo", "pgo", "base") if round_index % 2 == 0 else ("pgo", "base", "base", "pgo")
        for name in order:
            samples, start_ms = daemon_round(builds[name], args.tabs)
            merged = results[name]
            merged.setdefault("start", []).append(start_ms)
            for key in CLASSES:
                merged.setdefault(key, []).extend(samples.get(key, []))
                merged.setdefault("all", []).extend(samples.get(key, []))
    table = summarize(results)
    fmt = lambda v: "-" if v is None else f"{v:.3f}"  # noqa: E731
    pct_fmt = lambda v: "-" if v is None else f"{v:+.1f}%"  # noqa: E731
    print(f"{'request (ms)':14s} {'n':>6s} {'base p50':>9s} {'pgo p50':>9s} {'change':>8s} {'base p95':>9s} {'pgo p95':>9s} {'change':>8s}")
    for key, row in table.items():
        print(f"{key:14s} {row['pgo']['n']:6d} {fmt(row['base']['p50']):>9s} {fmt(row['pgo']['p50']):>9s} "
              f"{pct_fmt(row['change_p50']):>8s} {fmt(row['base']['p95']):>9s} {fmt(row['pgo']['p95']):>9s} "
              f"{pct_fmt(row['change_p95']):>8s}")
    target = table["all"]
    met = all(v is not None and v <= -5 for v in (target["change_p50"], target["change_p95"]))
    print(f"target (all requests, p50 and p95 at most -5 %): {'met' if met else 'not met'}")
    if args.json:
        with open(args.json, "w", encoding="utf-8") as handle:
            json.dump({"base": args.base, "pgo": args.pgo, "rounds": args.rounds, "tabs": args.tabs,
                       "summary": table, "target_met": met}, handle, indent=2)
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="scenario", required=True)
    ffi = sub.add_parser("ffi", help="cmux-app-ffi through its C ABI")
    ffi.add_argument("--lib", required=True, help="the instrumented libcmux_app_ffi shared library")
    ffi.add_argument("--repo", default=REPO, help="the cmux checkout holding the corpora")
    ffi.add_argument("--rounds", type=int, default=20)
    cover = sub.add_parser("coverage", help="every app C ABI has counts in the FFI profile")
    cover.add_argument("--lib", required=True, help="the instrumented libcmux_app_ffi shared library")
    cover.add_argument("--repo", default=REPO, help="the cmux checkout whose Swift sources name the calls")
    cover.add_argument("--profdata", required=True, help="the merged cmux-app-ffi profile")
    cover.add_argument("--tool", required=True, help="llvm-profdata of the pinned rustc")
    daemon = sub.add_parser("daemon", help="a headless cmux-tui daemon")
    daemon.add_argument("--binary", required=True)
    daemon.add_argument("--rounds", type=int, default=20)
    daemon.add_argument("--tabs", type=int, default=8)
    ab = sub.add_parser("ab", help="the daemon scenario on two builds")
    ab.add_argument("--base", required=True)
    ab.add_argument("--pgo", required=True)
    ab.add_argument("--rounds", type=int, default=15)
    ab.add_argument("--tabs", type=int, default=8)
    ab.add_argument("--json", help="write the summary here")
    args = parser.parse_args(argv)
    if getattr(args, "rounds", 1) < 1 or getattr(args, "tabs", 1) < 1:
        parser.error("--rounds and --tabs take a positive number")
    try:
        return {"ffi": run_ffi, "coverage": run_coverage, "daemon": run_daemon, "ab": run_ab}[args.scenario](args)
    except ScenarioError as error:
        print(f"rust_pgo_scenarios: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
