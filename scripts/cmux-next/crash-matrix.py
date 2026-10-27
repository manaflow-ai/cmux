#!/usr/bin/env python3
"""crash-matrix.py: one crash report per process kind (plans/cmux-next/chrome-parity/p09-observability.md, done check 8,
task 087).

For each kind it launches the tagged bench app through bench_launch.BenchApp (a fresh saved session, Sentry on with
the recorder transport `CMUX_NEXT_SENTRY_RECORDER=<recorder>/<kind>` of task 086, hang reports on so the crash event
carries `blackbox.txt`), checks that a fresh terminal holder of this build runs, crashes one process, then relaunches
the app (app kinds: Sentry sends the cached crash at the next launch) or waits (the forwarders watch their logs), and
checks:

  - exactly 1 crash envelope arrived (an event of level fatal, or one with a `crash_source` tag);
  - its tags `process` and `crash_source`, and at least one `crash_key.<name>` tag (tasks 079, 097, 098);
  - the black box: app kinds need `blackbox.txt` with >= 256 events; any `blackbox.txt` has 0 key records
    (TraceBlackBoxUpload's rule: no `key.*`, no `pty` name part, no per-input event);
  - the top cmux frame's image UUID is a UUID of a dSYM of the build (`dwarfdump --uuid`), by the kind's rule below;
  - its stability counter (`metrics.snapshot`, task 109's `stability.*` enumerations) rose by exactly 1, for a kind
    that ends a process;
  - for every kind that is not an app kind, the app pid did not change.

The matrix is Chromium's own: crash each process type on purpose (chrome://crash, chrome://gpucrash and
chrome://inducebrowsercrashforrealz, content/browser/renderer_host/debug_urls.cc), then check one report and one
stability count per process type (components/metrics/stability_metrics_helper.cc).

Kinds (`--list`): app-signal, app-nsexception, daemon-panic, daemon-segv, holder-abort, terminal-host-panic,
terminal-host-segv, acpmux-panic, agent-host-panic, app-host-panic, browser-host-panic, renderer-crash, gpu-crash,
utility-kill, webkit-content-kill, mcp-serve-panic; plus chromium-host-abort with `--host` (the cefHelperHost flag is
off by default; the run turns it on for that kind only, through the Debug tunables file as child-crash-e2e.py does).

Injectors are task 101's only (DEBUG and bench builds; a field other than `kind` is refused):
  - the daemon: `{"cmd": "debug-panic", "kind": K}` on its socket;
  - acpmux: JSON-RPC `_acpmux/debug_panic {"kind": K}` on its socket.
A `panic` ends only the injector's thread (the panic log records it); `abort` and `segv` end the process. So the
daemon-panic and acpmux-panic kinds count no child exit. No task specifies a panic injector for the terminal host,
the agent host, the app host, the browser host or `cmux mcp serve`: their `*-panic` kinds send SIGABRT to a process
this run proved it owns, and the report names the missing injector. A build that lacks an injector, or a process that
does not run in the launch, makes the kind NOT-MEASURABLE.

The image UUID rule follows what the report can carry: a kind whose report has no stack by design (a Rust panic-log
event, a helper-exit event, a SIGKILL) reports that check SKIP with the reason; Chromium kinds accept the Chromium
framework and helper images; every other kind needs a crashing stack whose top cmux frame has a dSYM UUID.

Signals go only to processes this run started: a process of the tag (tag_teardown.TagTeardown's rules) whose start
is at or after this launch, or a pid child-crash-e2e's Ownership proves is the launched app's (its process tree, a
WebContent the app reports), or the `cmux mcp serve` this script started. Anything else is never signalled.

Exit 0 when every selected kind passes every check; 1 when one fails or is not measurable; 2 on bad arguments.

  crash-matrix.py --app "$NX_APP" [--recorder DIR] [--out DIR] [--only k1,k2] [--host] [--dsyms DIR ...]
                  [--uuids-from-binaries] [--timeout 90] [--settle 10]
  crash-matrix.py --self-test
  crash-matrix.py --list
"""
import argparse, ctypes, dataclasses, glob, hashlib, json, math, os, re, select, shutil, signal, socket, subprocess, sys
import tempfile, time, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

PASS, FAIL, NOT_MEASURABLE, SKIP = "PASS", "FAIL", "NOT-MEASURABLE", "SKIP"
RECORDER_ENV = "CMUX_NEXT_SENTRY_RECORDER"
MIN_APP_BLACKBOX_EVENTS = 256
# TraceBlackBoxUpload.perInputNames: one event per input, never uploaded.
PER_INPUT_NAMES = frozenset({"frame.present_estimate", "cef.host_input", "remote.input", "remote.present"})
# HistogramID+Dimensions.swift: UncleanExit and ChildExit values.
UNCLEAN_CRASH = 0
CHILD_SIGNAL, CHILD_PANIC = 1, 2
STABILITY_KINDS = frozenset({"app", "daemon", "host", "holder", "acpmux", "agent_host", "app_host", "browser_host",
                             "chromium_host", "renderer", "gpu", "utility", "webkit"})
NETWORK_SERVICE = "network.mojom.NetworkService"
HOLDER_BIN = "cmux-holder"
HEX64 = re.compile(r"^[0-9a-f]{64}$")
DWARFDUMP_UUID = re.compile(r"UUID:\s+([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12})"
                            r"\s+\(([^)]*)\)\s+(.+)$")


# ---------------------------------------------------------------- the kinds
@dataclasses.dataclass(frozen=True)
class Kind:
    """One process kind of done check 8. `trigger` names a Run method and `arg` its argument; `report` is
    "relaunch" (Sentry sends the crash at the app's next launch) or "live"; `counter` is the stability enumeration
    (histogram, value) the crash adds 1 to, or None with `counter_why`; `processes` are the accepted `process` tag
    values (empty: any non-empty value). `stand_in` names the injector no task specifies, when a signal takes its
    place. `no_stack` is the reason an event with no crashing stack is SKIP for the UUID check (empty: FAIL);
    `images` is the IMAGE_RULES key of the images the top frame may be in."""
    name: str
    trigger: str
    arg: object
    report: str
    counter: object
    processes: tuple = ()
    host_flag: bool = False
    counter_why: str = ""
    stand_in: str = ""
    no_stack: str = ""
    images: str = "cmux"

    @property
    def app_kind(self):
        return self.report == "relaunch"


def child(kind, value):
    return (f"stability.child_exit.{kind}", value)


def no_injector(process):
    return (f"SIGABRT stands in for a panic: no task specifies a panic injector for {process} "
            "(task 101 covers only the daemon and acpmux)")


THREAD_PANIC = ("a `panic` ends only the injector's thread (task 101); the process keeps running, so no child exit "
                "is counted")
PANIC_LOG = ("a Rust panic-log event has no stack or debug images (OwnerPanicForwarder.event puts the backtrace in "
             "`extra`); a UUID needs the forwarder to add debug_meta")
HELPER_EXIT = "a helper-exit event (task 083) has no stack; only a macOS crash report of the helper carries one"
KILLED = "SIGKILL ends the process with no crash handler, so no stack exists"

KINDS = (
    Kind("app-signal", "app_rpc", ("debug.crash.app", {"signal": "segv"}), "relaunch", ("stability.unclean_exit", UNCLEAN_CRASH)),
    Kind("app-nsexception", "app_rpc", ("debug.crash.exception", {}), "relaunch", ("stability.unclean_exit", UNCLEAN_CRASH)),
    Kind("daemon-panic", "daemon_inject", "panic", "live", None, ("cmux-tui",), counter_why=THREAD_PANIC,
         no_stack=PANIC_LOG),
    Kind("daemon-segv", "daemon_inject", "segv", "live", child("daemon", CHILD_SIGNAL), ("cmux-tui",)),
    Kind("holder-abort", "signal_holder", signal.SIGABRT, "live", child("holder", CHILD_SIGNAL), ("cmux-holder",)),
    Kind("terminal-host-panic", "signal_host", signal.SIGABRT, "live", child("host", CHILD_SIGNAL),
         ("cmux-tui-host", "cmux-tui"), stand_in=no_injector("the terminal host")),
    Kind("terminal-host-segv", "signal_host", signal.SIGSEGV, "live", child("host", CHILD_SIGNAL),
         ("cmux-tui-host", "cmux-tui")),
    Kind("acpmux-panic", "acpmux_inject", "panic", "live", None, ("acpmux",), counter_why=THREAD_PANIC,
         no_stack=PANIC_LOG),
    Kind("agent-host-panic", "signal_agent_host", signal.SIGABRT, "live", child("agent_host", CHILD_SIGNAL),
         stand_in=no_injector("the agent host")),
    Kind("app-host-panic", "signal_bundle_binary", ("cmux-app-host", signal.SIGABRT), "live",
         child("app_host", CHILD_SIGNAL), stand_in=no_injector("cmux-app-host")),
    Kind("browser-host-panic", "signal_bundle_binary", ("cmux-browser-host", signal.SIGABRT), "live",
         child("browser_host", CHILD_SIGNAL), stand_in=no_injector("cmux-browser-host")),
    Kind("renderer-crash", "omnibar", "chrome://crash", "live", child("renderer", CHILD_SIGNAL),
         no_stack=HELPER_EXIT, images="chromium"),
    Kind("gpu-crash", "omnibar", "chrome://gpucrash", "live", child("gpu", CHILD_SIGNAL),
         no_stack=HELPER_EXIT, images="chromium"),
    Kind("utility-kill", "kill_utility", signal.SIGKILL, "live", child("utility", CHILD_SIGNAL), no_stack=KILLED),
    Kind("webkit-content-kill", "kill_webcontent", signal.SIGKILL, "live", child("webkit", CHILD_SIGNAL),
         no_stack=KILLED),
    Kind("mcp-serve-panic", "mcp_signal", signal.SIGABRT, "live", None,
         counter_why="`cmux mcp serve` is not a child of the app: task 109 names no counter for it",
         stand_in=no_injector("`cmux mcp serve`")),
    Kind("chromium-host-abort", "host_check", "chrome://inducebrowsercrashforrealz", "live",
         child("chromium_host", CHILD_SIGNAL), host_flag=True, no_stack=HELPER_EXIT, images="chromium"),
)
KINDS_BY_NAME = {kind.name: kind for kind in KINDS}


def selected_kinds(only, host):
    """The kinds to run, in table order: `only` (comma-separated names) or every kind; chromium-host-abort only with
    `host`. SystemExit(2) naming the kinds for an unknown name."""
    names = [n for n in (only or "").split(",") if n]
    unknown = [n for n in names if n not in KINDS_BY_NAME]
    if unknown:
        print(f"crash-matrix: unknown kind {', '.join(unknown)}; kinds: {', '.join(KINDS_BY_NAME)}", file=sys.stderr)
        raise SystemExit(2)
    chosen = [k for k in KINDS if (not names or k.name in names)]
    return [k for k in chosen if host or not k.host_flag]


# ---------------------------------------------------------------- Sentry envelopes (pure)
@dataclasses.dataclass
class Item:
    headers: dict
    payload: bytes


@dataclasses.dataclass
class Envelope:
    path: str
    headers: dict
    items: list

    def event(self):
        """The envelope's event payload as a dict, or None."""
        for item in self.items:
            if item.headers.get("type") == "event":
                try:
                    value = json.loads(item.payload)
                except ValueError:
                    return None
                return value if isinstance(value, dict) else None
        return None

    def attachments(self):
        """{filename: bytes} of the attachment items."""
        return {item.headers.get("filename") or "": item.payload
                for item in self.items if item.headers.get("type") == "attachment"}


class EnvelopeError(ValueError):
    pass


def parse_envelope(data, path=""):
    """A Sentry envelope (develop.sentry.dev/sdk/envelopes): a header line, then items of a header line and a payload
    of `length` bytes, or up to the next newline without one. EnvelopeError for anything else (a file still being
    written)."""
    def line_at(offset):
        end = data.find(b"\n", offset)
        return (data[offset:], len(data)) if end < 0 else (data[offset:end], end + 1)

    head, offset = line_at(0)
    try:
        headers = json.loads(head or b"{}")
    except ValueError as error:
        raise EnvelopeError(f"{path}: bad envelope header: {error}") from None
    if not isinstance(headers, dict):
        raise EnvelopeError(f"{path}: the envelope header is not an object")
    items = []
    while offset < len(data):
        line, offset = line_at(offset)
        if not line.strip():
            continue
        try:
            item_headers = json.loads(line)
        except ValueError as error:
            raise EnvelopeError(f"{path}: bad item header: {error}") from None
        if not isinstance(item_headers, dict):
            raise EnvelopeError(f"{path}: an item header is not an object")
        length = item_headers.get("length")
        if isinstance(length, int):
            if offset + length > len(data):
                raise EnvelopeError(f"{path}: an item is cut short ({len(data) - offset} of {length} bytes)")
            payload, offset = data[offset:offset + length], offset + length
            if data[offset:offset + 1] == b"\n":
                offset += 1
        else:
            payload, offset = line_at(offset)
        items.append(Item(item_headers, payload))
    return Envelope(path, headers, items)


def tags_of(event):
    """An event's tags as a dict (Sentry sends an object or a list of [key, value] pairs)."""
    tags = (event or {}).get("tags") or {}
    if isinstance(tags, list):
        return {str(p[0]): str(p[1]) for p in tags if isinstance(p, (list, tuple)) and len(p) == 2}
    return {str(k): str(v) for k, v in tags.items()} if isinstance(tags, dict) else {}


def is_crash_envelope(envelope):
    """A crash report: an event of level fatal, or one with a `crash_source` tag (sessions, transactions, lag
    spikes and hangs are not)."""
    event = envelope.event()
    return bool(event) and (event.get("level") == "fatal" or "crash_source" in tags_of(event))


# ---------------------------------------------------------------- black box (pure)
def is_key_record(name):
    """TraceBlackBoxUpload.keeps' per-key names: `key.*`, a `pty` name part, or a per-input event."""
    return name.startswith("key.") or name in PER_INPUT_NAMES or "pty" in re.split(r"[._]", name)


def blackbox_summary(text):
    """{events, key_records, malformed} of a `blackbox.txt` (`<t_ns> <process> <name> <phase> <arg0> <arg1>` lines)."""
    events = keys = malformed = 0
    for line in text.splitlines():
        if not line.strip():
            continue
        parts = line.split(" ")
        if len(parts) != 6 or not parts[0].isdigit() or not parts[4].isdigit() or not parts[5].isdigit():
            malformed += 1
            continue
        events += 1
        if is_key_record(parts[2]):
            keys += 1
    return {"events": events, "key_records": keys, "malformed": malformed}


# ---------------------------------------------------------------- frames and debug images (pure)
def parse_address(value):
    if isinstance(value, int):
        return value
    if isinstance(value, str):
        try:
            return int(value, 16) if value.lower().startswith("0x") else int(value)
        except ValueError:
            return None
    return None


def normalize_uuid(value):
    """32 lowercase hex digits of a UUID or a Sentry debug_id (a Breakpad age suffix dropped), or None."""
    digits = re.sub(r"[^0-9a-fA-F]", "", str(value or ""))
    return digits[:32].lower() if len(digits) >= 32 else None


def crash_frames(event):
    """The crashing stack, innermost frame first: the last exception's stacktrace, else the crashed thread's
    (Sentry lists frames outermost first)."""
    exceptions = (event or {}).get("exception") or {}
    values = exceptions.get("values") if isinstance(exceptions, dict) else exceptions
    for exception in reversed(values or []):
        frames = ((exception or {}).get("stacktrace") or {}).get("frames") or []
        if frames:
            return list(reversed(frames))
    threads = (event or {}).get("threads") or {}
    for thread in (threads.get("values") if isinstance(threads, dict) else threads) or []:
        if (thread or {}).get("crashed"):
            return list(reversed(((thread.get("stacktrace") or {}).get("frames")) or []))
    return []


def is_cmux_image(path):
    """A binary cmux builds: inside a cmux app bundle, a host-exe copy, or a cmux/acpmux executable; never the
    Chromium framework or a system library."""
    if not path or "Chromium Embedded Framework" in path:
        return False
    base = os.path.basename(path)
    return ("/host-exe/" in path or base.startswith(("cmux", "acpmux")) or "cmux DEV" in path
            or "/cmux.app/" in path or "/cmux NIGHTLY.app/" in path)


def is_build_image(path):
    """A binary of the build a Chromium crash may stop in: a cmux image (its helper apps included) or the Chromium
    Embedded Framework it ships."""
    return bool(path) and (is_cmux_image(path) or "Chromium Embedded Framework" in path)


IMAGE_RULES = {"cmux": is_cmux_image, "chromium": is_build_image}


def frame_image(frame, images):
    """The debug image a frame's address falls in, else the one with its package path."""
    base = parse_address(frame.get("image_addr"))
    address = parse_address(frame.get("instruction_addr"))
    for image in images:
        start = parse_address(image.get("image_addr"))
        if start is None:
            continue
        if base is not None and base == start:
            return image
        size = parse_address(image.get("image_size")) or 0
        if address is not None and start <= address < start + size:
            return image
    package = frame.get("package")
    return next((i for i in images if package and i.get("code_file") == package), None)


def top_frame_uuid(event, accept=is_cmux_image):
    """(uuid, code_file, "") of the innermost crashing frame in an image `accept` takes, or (None, None, why)."""
    images = ((event or {}).get("debug_meta") or {}).get("images") or []
    frames = crash_frames(event)
    if not frames:
        return None, None, "the event has no crashing stack"
    for frame in frames:
        image = frame_image(frame, images)
        path = (image or {}).get("code_file") or frame.get("package")
        if not accept(path):
            continue
        uuid = normalize_uuid((image or {}).get("debug_id") or (image or {}).get("uuid"))
        if uuid is None:
            return None, path, f"the top build frame ({os.path.basename(path)}) has no debug image with a UUID"
        return uuid, path, ""
    return None, None, f"no frame of {len(frames)} is in a build image"


def parse_dwarfdump_uuids(text):
    """{uuid: [(arch, path)]} from `dwarfdump --uuid` output."""
    found = {}
    for line in text.splitlines():
        match = DWARFDUMP_UUID.search(line.strip())
        if match:
            found.setdefault(normalize_uuid(match.group(1)), []).append((match.group(2), match.group(3)))
    return found


# ---------------------------------------------------------------- stability counters (pure)
def stability_counters(reply):
    """{(histogram, value): count} of the `stability.*` enumerations in a metrics.snapshot reply (the bucket's `low`
    is the enumeration value); None for a reply with no histograms."""
    histograms = (reply or {}).get("histograms") if isinstance(reply, dict) else None
    if not isinstance(histograms, list):
        return None
    counts = {}
    for histogram in histograms:
        name = (histogram or {}).get("name") or ""
        if not name.startswith("stability.") or name in ("stability.launch", "stability.active_seconds"):
            continue
        for bucket in histogram.get("buckets") or []:
            value = bucket.get("low") if bucket.get("low") is not None else bucket.get("index")
            if isinstance(value, (int, float)) and isinstance(bucket.get("count"), (int, float)):
                counts[(name, int(value))] = int(bucket["count"])
    return counts


def counter_delta(before, after):
    """{(histogram, value): after - before} of every counter that changed."""
    keys = set(before) | set(after)
    return {k: after.get(k, 0) - before.get(k, 0) for k in sorted(keys) if after.get(k, 0) != before.get(k, 0)}


# ---------------------------------------------------------------- processes (pure)
def lstart_epoch(text):
    """Epoch seconds of a `ps -o lstart` value (`Tue Oct 27 10:00:00 2026`, local time), or None."""
    try:
        return time.mktime(time.strptime(" ".join(text.split()), "%a %b %d %H:%M:%S %Y"))
    except (ValueError, OverflowError):
        return None


def started_by_run(pid, rows, tag_pids, launched_at, exclude):
    """(True, how) when `pid` is a process of the tag that started at or after `launched_at` (epoch seconds; `ps`
    gives whole seconds); else (False, why). `rows` is {pid: (ppid, lstart, command)}; `exclude` never qualifies
    (this script, its ancestors, the app)."""
    if pid in exclude:
        return False, f"pid {pid} is this script, an ancestor or the app"
    if pid not in rows:
        return False, f"pid {pid} does not run"
    if pid not in tag_pids:
        return False, f"pid {pid} is not a process of the tag"
    started = lstart_epoch(rows[pid][1])
    if started is None:
        return False, f"pid {pid}: its start time cannot be read ({rows[pid][1]!r})"
    if started < math.floor(launched_at):
        return False, f"pid {pid} started before this launch"
    return True, "a process of the tag started by this launch"


def executable_path(pid):
    """The file `pid` runs (proc_pidpath, libproc.h), or None. Not the `ps` command: the daemon starts holders and
    hosts with a bare argv0 (`cmux-holder`, service.rs; `cmux-tui`, host_exe.rs)."""
    try:
        libc = ctypes.CDLL(None, use_errno=True)
        buffer = ctypes.create_string_buffer(4096)  # PROC_PIDPATHINFO_MAXSIZE
        length = libc.proc_pidpath(int(pid), buffer, ctypes.sizeof(buffer))
    except (OSError, AttributeError):
        return None
    return os.fsdecode(buffer.raw[:length]) if length > 0 else None


def holder_build_check(exe, bundle_bin, digest=None):
    """(ok, detail): the running holder's executable `exe` (executable_path) is this build's: it has the SHA-256 of
    the bundle binary it was copied from (a host-exe copy keeps its source's name: `cmux-holder`, or the host binary
    for the built-in `__holder`), and a host-exe copy's folder is named by that hash (host_exe.rs)."""
    if not exe:
        return False, "the holder's executable path cannot be read"
    digest = digest or file_sha256
    source = os.path.join(bundle_bin, os.path.basename(exe))
    try:
        want, have = digest(source), digest(exe)
    except OSError as error:
        return False, f"cannot hash {error.filename}: {error.strerror}"
    if have != want:
        return False, f"{exe} has sha256 {have[:12]}, the bundle's {os.path.basename(source)} {want[:12]}"
    folder = os.path.basename(os.path.dirname(exe))
    if HEX64.match(folder) and folder != want:
        return False, f"the host-exe folder {folder[:12]} does not name the binary's hash {want[:12]}"
    return True, f"{os.path.basename(exe)} sha256 {want[:12]} matches the bundle"


def file_sha256(path):
    sha = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            sha.update(block)
    return sha.hexdigest()


def is_holder(command):
    """A terminal holder (tag_teardown.TagTeardown._is_holder): argv0 `cmux-holder` or the built-in `__holder`."""
    words = command.split()
    return bool(words) and (os.path.basename(words[0]) == HOLDER_BIN or " __holder " in f" {command} ")


def is_terminal_host(command):
    return " __terminal-host " in f" {command} "


def is_agent_host(command):
    return " __agent-host " in f" {command} "


def runs_bundle_binary(command, app, name, args=""):
    """True when the `ps` command runs `<app>/Contents/Resources/bin/<name>` (then `args`, when given): matched by the
    whole path, since a tagged bundle path has spaces (`cmux DEV <tag>.app`). A /var or /tmp spelling matches its
    /private realpath (tag_teardown.TagTeardown._relative)."""
    resolved = "/private" + command if command.startswith(("/var/", "/tmp/")) else command
    start = os.path.join(app.rstrip("/"), "Contents/Resources/bin", name) + (f" {args}" if args else "")
    return resolved == start or resolved.startswith(start + " ")


# ---------------------------------------------------------------- injectors (pure)
ACPMUX_DEBUG_PANIC = "_acpmux/debug_panic"


def daemon_debug_panic(kind):
    """Task 101's daemon line: `debug-panic` takes `kind` and no other field."""
    return {"id": 1, "cmd": "debug-panic", "kind": kind}


def acpmux_debug_panic(kind):
    """Task 101's acpmux requests: `initialize`, then `_acpmux/debug_panic` with `kind` and no other field."""
    return [{"jsonrpc": "2.0", "id": 1, "method": "initialize",
             "params": {"protocolVersion": 1, "clientInfo": {"name": "crash-matrix"}}},
            {"jsonrpc": "2.0", "id": 2, "method": ACPMUX_DEBUG_PANIC, "params": {"kind": kind}}]


def injector_refusal(reply):
    """None when the injector took the request (an ok reply, or the connection ended because the process died);
    else the refusal text (the build lacks it, a remote client, a field other than `kind`)."""
    if reply is None or reply.get("closed"):
        return None
    if reply.get("ok") is True or ("result" in reply and "error" not in reply):
        return None
    error = reply.get("error")
    if isinstance(error, dict):
        error = error.get("message") or json.dumps(error)
    return str(error or reply)[:300]


# ---------------------------------------------------------------- the checks of one kind
@dataclasses.dataclass
class Check:
    name: str
    status: str
    detail: str = ""


class KindReport:
    def __init__(self, kind):
        self.kind, self.checks = kind, []

    def add(self, name, status, detail=""):
        self.checks.append(Check(name, status, str(detail)[:500]))
        print(f"{status} {self.kind.name}: {name}{': ' + str(detail)[:400] if detail else ''}", flush=True)

    def check(self, name, ok, detail=""):
        self.add(name, PASS if ok else FAIL, detail)
        return ok

    @property
    def status(self):
        statuses = {c.status for c in self.checks}
        for status in (FAIL, NOT_MEASURABLE):
            if status in statuses:
                return status
        return PASS if PASS in statuses else NOT_MEASURABLE

    def json(self):
        return {"kind": self.kind.name, "status": self.status, "checks": [dataclasses.asdict(c) for c in self.checks]}


def check_envelopes(report, kind, envelopes, uuids, uuid_source):
    """The envelope checks of one kind over the envelopes that arrived after its crash."""
    crashes = [e for e in envelopes if is_crash_envelope(e)]
    others = len(envelopes) - len(crashes)
    if not report.check("exactly 1 crash envelope", len(crashes) == 1,
                        f"{len(crashes)} crash envelopes ({', '.join(os.path.basename(e.path) for e in crashes) or 'none'}), "
                        f"{others} other"):
        if not crashes:
            return
    event = crashes[0].event()
    tags = tags_of(event)
    process, source = tags.get("process"), tags.get("crash_source")
    allowed = kind.processes
    report.check("tags process and crash_source", bool(process) and bool(source)
                 and (not allowed or process in allowed),
                 f"process={process} crash_source={source}" + (f" (want process in {', '.join(allowed)})" if allowed else ""))
    keys = sorted(k for k in tags if k.startswith("crash_key."))
    report.check("crash keys as tags", bool(keys), ", ".join(keys) or "no crash_key.* tag")
    text = crashes[0].attachments().get("blackbox.txt")
    if text is None:
        if kind.app_kind:
            report.check("blackbox.txt attached", False, "no blackbox.txt attachment")
        else:
            report.add("blackbox.txt", SKIP, "no attachment (required for app kinds only)")
    else:
        box = blackbox_summary(text.decode("utf-8", "replace"))
        if kind.app_kind:
            report.check(f"blackbox.txt has >= {MIN_APP_BLACKBOX_EVENTS} events", box["events"] >= MIN_APP_BLACKBOX_EVENTS, box)
        report.check("blackbox.txt has 0 key records", box["key_records"] == 0 and box["malformed"] == 0, box)
    name = f"top {kind.images} frame UUID matches a dSYM"
    if not crash_frames(event) and kind.no_stack:
        report.add(name, SKIP, kind.no_stack)
        return
    uuid, path, why = top_frame_uuid(event, IMAGE_RULES[kind.images])
    if uuid is None:
        report.check(name, False, why)
    elif not uuids:
        report.add(name, NOT_MEASURABLE,
                   "no dSYM of the build found: pass --dsyms DIR (or --uuids-from-binaries for a DEV build)")
    else:
        report.check(name, uuid in uuids, f"{os.path.basename(path)} {uuid} ({uuid_source}: {len(uuids)} UUIDs)")


def check_counter(report, kind, before, after):
    """Its stability counter rose by exactly 1; the other changes are printed."""
    if kind.counter is None:
        report.add("stability counter", SKIP, kind.counter_why)
        return
    if before is None or after is None:
        report.add("stability counter", NOT_MEASURABLE, "metrics.snapshot gave no histograms (metricsView off?)")
        return
    delta = counter_delta(before, after)
    others = {f"{name}[{value}]": change for (name, value), change in delta.items() if (name, value) != kind.counter}
    name, value = kind.counter
    report.check(f"{name}[{value}] +1", delta.get(kind.counter, 0) == 1,
                 f"+{delta.get(kind.counter, 0)}" + (f"; other changes {others}" if others else ""))


# ---------------------------------------------------------------- the live run
class Recorder:
    """The recorder transport's folder of one kind: every regular file is one envelope."""

    def __init__(self, folder):
        self.folder = folder
        os.makedirs(folder, exist_ok=True)

    def files(self):
        found = []
        for root, _, names in os.walk(self.folder):
            found.extend(os.path.join(root, n) for n in names if not n.startswith("."))
        return set(found)

    def wait(self, seen, timeout, settle):
        """The envelopes written after `seen`: polls until a crash envelope arrives (then `settle` seconds more, so a
        second one is counted) or `timeout` passes. A file that does not parse yet is read again; one that never
        parses is returned as unparsable."""
        deadline = time.monotonic() + timeout
        parsed, broken, first = {}, {}, None
        while True:
            for path in sorted(self.files() - seen - set(parsed)):
                try:
                    with open(path, "rb") as handle:
                        parsed[path] = parse_envelope(handle.read(), path)
                    broken.pop(path, None)
                except (OSError, EnvelopeError) as error:
                    broken[path] = str(error)
            if first is None and any(is_crash_envelope(e) for e in parsed.values()):
                first = time.monotonic()
            now = time.monotonic()
            if (first is not None and now - first >= settle) or now >= deadline:
                return list(parsed.values()), broken
            time.sleep(0.5)  # test harness: the recorder writes files from the app's own threads


def line_request(path, body, timeout=10):
    """One JSON line on a daemon-style socket; the reply with the request's id, {"closed": True} when the peer ended
    before replying (the process died), or {"error": ...} when it could not connect."""
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(timeout)
        conn.connect(path)
    except OSError as error:
        return {"error": f"connect {path}: {error}", "unreachable": True}
    try:
        buffer = b""
        for line in body if isinstance(body, list) else [body]:
            conn.sendall((json.dumps(line) + "\n").encode())
        want = (body[-1] if isinstance(body, list) else body).get("id")
        while True:
            while b"\n" not in buffer:
                chunk = conn.recv(1 << 20)
                if not chunk:
                    return {"closed": True}
                buffer += chunk
            raw, buffer = buffer.split(b"\n", 1)
            try:
                message = json.loads(raw)
            except ValueError:
                continue
            if isinstance(message, dict) and message.get("id") == want:
                return message
    except socket.timeout:
        return {"closed": True, "timeout": True}
    except OSError:
        return {"closed": True}
    finally:
        conn.close()


class Run:
    """One kind on one launch of the app."""

    def __init__(self, opts, kind, report, modules):
        self.opts, self.kind, self.report = opts, kind, report
        self.launch, self.tagged, self.teardown_mod, self.e2e = modules
        self.app = None
        self.driver = None
        self.launched_at = None
        self.mcp = None
        self.app_pid = None
        self.holder = None
        self.server = None

    # -- setup
    def environment(self, tunables):
        env = {**self.launch.shipping_env(), RECORDER_ENV: os.path.join(self.opts.recorder, self.kind.name),
               self.e2e.TUNABLES_FILE: tunables}
        with open(tunables, "w") as handle:
            json.dump({"version": 1, "values": {self.e2e.HOST_TOGGLE: self.kind.host_flag}}, handle)
        return env

    def start(self, out):
        tunables = os.path.join(out, "tunables.json")
        config = {**self.launch.DEFAULT_CONFIG, "diagnostics": {"hangReports": True}, "mcp": {"enabled": True}}
        self.app = self.launch.BenchApp(self.opts.app, out=out, env=self.environment(tunables), config=config,
                                        local_features={"metricsView": True})
        consent = self.launch.seed_hang_report_consent(self.app.app)
        if consent:
            self.report.add("hang report consent", NOT_MEASURABLE, consent)
        self.launched_at = time.time()
        self.app.launch()
        self.app_pid = self.app.process.pid
        self.app.teardown.remember()
        if self.kind.host_flag:
            state = self.e2e.settle_host_state(self.app, "on")
            self.report.check(f"{self.e2e.HOST_FEATURE} is on", state == "on", f"state {state}")

    def tag_table(self):
        """({pid: (ppid, lstart, command)}, {pid: command} of the tag's processes)."""
        rows = self.teardown_mod.TagTeardown._table()
        return rows, dict(self.app.teardown.processes())

    def exclude(self, rows):
        return self.teardown_mod.TagTeardown._lineage(rows, os.getpid()) | {self.app_pid}

    def find(self, match, seconds=30):
        """The newest process of the tag started by this launch whose command `match`es, or None."""
        def newest():
            rows, tag = self.tag_table()
            found = [pid for pid, command in tag.items() if match(command)
                     and started_by_run(pid, rows, tag, self.launched_at, self.exclude(rows))[0]]
            return max(found, key=lambda pid: lstart_epoch(rows[pid][1]) or 0) if found else None
        return self.e2e.wait(newest, seconds, 0.5)

    def bundle(self):
        return os.path.realpath(self.app.app).rstrip("/")

    def fresh_holder(self):
        """A holder of this build started by this launch (done check 8's first step)."""
        pid = self.find(is_holder)
        if not self.report.check("a fresh holder runs", bool(pid), f"pid {pid}" if pid else "no holder started within 30 s"):
            return None
        ok, detail = holder_build_check(executable_path(pid), os.path.join(self.bundle(), "Contents/Resources/bin"))
        self.report.check("the holder's build id is this build's", ok, detail)
        return pid

    def signal(self, pid, sig, reported_by_app=False):
        """Sends `sig` to `pid` once it is proved this run's; True when sent."""
        if self.mcp is not None and self.mcp.pid == pid and self.mcp.poll() is None:
            owned, why = True, "the `cmux mcp serve` this script started"
        else:
            rows, tag = self.tag_table()
            owned, why = started_by_run(pid, rows, tag, self.launched_at, self.exclude(rows))
            if not owned:
                owned, why = self.e2e.Ownership(self.app_pid).proof(pid, reported_by_app)
        if not owned:
            self.report.add("trigger", NOT_MEASURABLE, f"refused to signal {pid}: {why}")
            return False
        os.kill(int(pid), sig)  # a pid proved to be this run's
        self.report.add("trigger", PASS, f"signal {signal.Signals(sig).name} to {pid} ({why})")
        return True

    def chromium_tab(self, engine):
        server, url = self.e2e.serve()
        self.server = server
        self.driver = self.e2e.Driver(self.app.rpc, self.app_pid, url, host_on=self.kind.host_flag)
        table = self.driver.ownership.read_table()
        self.driver.baseline_renderers = set(self.e2e.chromium_children(table, self.app_pid, "renderer"))
        return self.driver.open_layout(engine)

    # -- triggers: each returns True when the crash was sent
    def app_rpc(self, arg):
        method, params = arg
        self.plant_key_records()
        self.app.rpc(method, params, timeout=5)  # the reply may be lost: the app ends
        try:
            self.app.process.wait(60)
        except subprocess.TimeoutExpired:
            return self.report.check("trigger", False, f"{method} did not end the app in 60 s")
        return self.report.check("trigger", True, f"{method}: the app ended ({self.app.process.returncode})")

    def plant_key_records(self):
        """Keys into the focused terminal, so the ring holds key records the black box must leave out."""
        for index in range(32):
            self.app.rpc("debug.key", {"key": "abcdefghijklmnopqrstuvwxyz"[index % 26], "timestamp": self.e2e.uptime()},
                         timeout=10)

    def daemon_inject(self, kind):
        try:
            path = self.tagged.daemon_socket(self.app.tag)
        except SystemExit as error:  # bench_tagged.daemon_socket ends a bench this way; here it ends one kind
            self.report.add("trigger", NOT_MEASURABLE, f"no daemon socket: {error}")
            return False
        return self.injected(f"daemon debug-panic {kind}", line_request(path, daemon_debug_panic(kind)))

    def acpmux_inject(self, kind):
        pid = self.find(lambda c: runs_bundle_binary(c, self.bundle(), "acpmux", "daemon run"))
        found = self.teardown_mod.procargs(pid) if pid else None
        env = found[1] if found else {}
        path = env.get("ACPMUX_SOCKET") or (os.path.join(env["ACPMUX_HOME"], "acpmux.sock") if env.get("ACPMUX_HOME") else None)
        if not path:
            self.report.add("trigger", NOT_MEASURABLE, "no acpmux daemon of this launch (or its socket cannot be read)")
            return False
        return self.injected(f"acpmux {ACPMUX_DEBUG_PANIC} {kind}", line_request(path, acpmux_debug_panic(kind)))

    def injected(self, what, reply):
        refused = injector_refusal(reply)
        if refused:
            self.report.add("trigger", NOT_MEASURABLE, f"{what} refused (task 101's injector): {refused}")
            return False
        self.report.add("trigger", PASS, what)
        return True

    def signal_found(self, what, match, sig):
        pid = self.find(match)
        if not pid:
            self.report.add("trigger", NOT_MEASURABLE, f"no {what} of this launch runs")
            return False
        return self.signal(pid, sig)

    def signal_holder(self, sig):
        return bool(self.holder) and self.signal(self.holder, sig)

    def signal_host(self, sig):
        return self.signal_found("terminal host", is_terminal_host, sig)

    def signal_agent_host(self, sig):
        self.app.rpc("action.run", {"action": "palette.newAgentChat", "args": {}, "focus": True, "origin": "script"})
        return self.signal_found("agent host", is_agent_host, sig)

    def signal_bundle_binary(self, arg):
        name, sig = arg
        return self.signal_found(name, lambda c: runs_bundle_binary(c, self.bundle(), name), sig)

    def mcp_signal(self, sig):
        """Starts `cmux mcp serve`, waits for its `initialize` reply (it serves), then signals it."""
        self.mcp = subprocess.Popen([self.app.cli, "--app-socket", self.app.socket, "mcp", "serve"],
                                    env=dict(self.app.launched_env or {}), stdin=subprocess.PIPE,
                                    stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        initialize = {"jsonrpc": "2.0", "id": 1, "method": "initialize",
                      "params": {"protocolVersion": "2025-06-18", "capabilities": {},
                                 "clientInfo": {"name": "crash-matrix", "version": "1"}}}
        try:
            self.mcp.stdin.write((json.dumps(initialize) + "\n").encode())
            self.mcp.stdin.flush()
        except OSError as error:
            self.report.add("trigger", NOT_MEASURABLE, f"cmux mcp serve: {error}")
            return False
        reply, buffer, deadline = None, b"", time.monotonic() + 15
        while reply is None and time.monotonic() < deadline:
            ready, _, _ = select.select([self.mcp.stdout], [], [], 0.5)
            if not ready:
                continue
            chunk = os.read(self.mcp.stdout.fileno(), 1 << 16)
            if not chunk:
                break
            buffer += chunk
            for raw in buffer.split(b"\n")[:-1]:
                try:
                    message = json.loads(raw)
                except ValueError:
                    continue
                if isinstance(message, dict) and message.get("id") == 1 and "result" in message:
                    reply = message
            buffer = buffer.rsplit(b"\n", 1)[-1]
        if reply is None:
            self.report.add("trigger", NOT_MEASURABLE, "cmux mcp serve gave no initialize reply in 15 s")
            return False
        return self.signal(self.mcp.pid, sig)

    def omnibar(self, url):
        if not self.chromium_tab("chromium"):
            self.report.add("trigger", NOT_MEASURABLE, "the Chromium tab did not open")
            return False
        return self.omnibar_typed(url)

    def kill_utility(self, sig):
        if not self.chromium_tab("chromium"):
            self.report.add("trigger", NOT_MEASURABLE, "the Chromium tab did not open")
            return False
        table = self.driver.ownership.read_table()
        nets = self.e2e.chromium_children(table, self.app_pid, "utility", NETWORK_SERVICE)
        if not nets:
            self.report.add("trigger", NOT_MEASURABLE, "no out-of-process network service")
            return False
        return self.signal(nets[0], sig)

    def kill_webcontent(self, sig):
        tab = self.chromium_tab("webkit")
        page = tab and self.e2e.wait(lambda: self.driver.status(tab).get("page_pid"), 20)
        if not page:
            self.report.add("trigger", NOT_MEASURABLE, "the WebKit tab reports no WebContent process")
            return False
        return self.signal(int(page), sig, reported_by_app=True)

    def host_check(self, url):
        tab = self.chromium_tab("chromium")
        if not tab:
            self.report.add("trigger", NOT_MEASURABLE, "the Chromium tab did not open")
            return False
        table = self.driver.ownership.read_table()
        renderers = set(self.e2e.chromium_children(table, self.app_pid, "renderer")) - self.driver.baseline_renderers
        host = self.e2e.serving_host(table, self.app_pid, renderers)
        if host is None:
            # Without proof that Chromium's browser process is not the app, a browser CHECK would end cmux.
            self.report.add("trigger", NOT_MEASURABLE, "no Chromium host runs the tab's renderers; the URL is not typed")
            return False
        return self.omnibar_typed(url)

    def omnibar_typed(self, url):
        at, why = self.driver.omnibar(self.kind.name, url)
        if at is None:
            self.report.add("trigger", NOT_MEASURABLE, why)
            return False
        self.report.add("trigger", PASS, f"{url} typed into the omnibar")
        return True

    # -- the kind
    def counters(self):
        return stability_counters(self.app.rpc("metrics.snapshot", {"names": ["stability."]}, timeout=20))

    def wait_counter(self, before):
        """The counters once the kind's counter moved, or after 20 s."""
        if self.kind.counter is None or before is None:
            return self.counters()
        last = {"value": None}

        def moved():
            last["value"] = self.counters()
            return last["value"] is not None and last["value"].get(self.kind.counter, 0) > before.get(self.kind.counter, 0)
        self.e2e.wait(moved, 20, 0.5)
        return last["value"]

    def run(self, uuids, uuid_source):
        out = os.path.join(self.opts.out, self.kind.name)
        os.makedirs(out, exist_ok=True)
        recorder = Recorder(os.path.join(self.opts.recorder, self.kind.name))
        self.server = None
        try:
            self.start(out)
            self.holder = self.fresh_holder()
            before = None if self.kind.app_kind else self.counters()
            seen = recorder.files()
            if self.kind.stand_in:
                self.report.add("injector", SKIP, self.kind.stand_in)
            sent = getattr(self, self.kind.trigger)(self.kind.arg)
            if not sent:
                return
            if self.kind.app_kind:
                self.app.fresh_state = False  # the relaunch reads the crashed run's state
                self.launched_at = time.time()
                self.app.launch()
                self.app_pid = self.app.process.pid
                self.app.teardown.remember()
                before = {}  # a new process: its counters start at 0, and the launch records the unclean exit
            envelopes, broken = recorder.wait(seen, self.opts.timeout, self.opts.settle)
            for path, why in sorted(broken.items()):
                self.report.add("recorder file parses", FAIL, f"{os.path.basename(path)}: {why}")
            check_envelopes(self.report, self.kind, envelopes, uuids, uuid_source)
            check_counter(self.report, self.kind, before, self.wait_counter(before))
            if not self.kind.app_kind:
                running = self.app.process.poll() is None
                self.report.check("the app pid survives", running and self.app.process.pid == self.app_pid,
                                  f"pid {self.app_pid} {'runs' if running else 'ended'}")
        except self.launch.LaunchError as error:
            self.report.add("launch", NOT_MEASURABLE, str(error))
        finally:
            if self.mcp and self.mcp.poll() is None:
                self.mcp.kill()  # the `cmux mcp serve` this run started
            if self.server:
                self.server.shutdown()
            if self.driver:
                for failure in self.driver.failures:
                    self.report.add(failure, FAIL, "child-crash-e2e driver step")
            if self.app:
                self.app.stop()


# ---------------------------------------------------------------- dSYM UUIDs
def dwarfdump():
    found = shutil.which("dwarfdump")
    return [found] if found else (["xcrun", "dwarfdump"] if shutil.which("xcrun") else None)


def is_macho(path):
    try:
        with open(path, "rb") as handle:
            magic = handle.read(4)
    except OSError:
        return False
    return magic in (b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca")


def collect_uuids(app, dsym_dirs, from_binaries):
    """({uuid}, source): the UUIDs of the build's dSYMs (in `dsym_dirs`, default the folder of the app), plus, with
    `from_binaries`, of every Mach-O in the bundle."""
    tool = dwarfdump()
    if tool is None:
        return set(), "no dwarfdump"
    targets = []
    for folder in dsym_dirs or [os.path.dirname(os.path.realpath(app))]:
        targets += sorted(glob.glob(os.path.join(folder, "*.dSYM")) + glob.glob(os.path.join(folder, "*", "*.dSYM")))
    source = f"{len(targets)} dSYMs"
    if from_binaries:
        binaries = [os.path.join(root, n) for root, _, names in os.walk(app) for n in names
                    if not os.path.islink(os.path.join(root, n)) and is_macho(os.path.join(root, n))]
        targets += binaries
        source += f" + {len(binaries)} bundle binaries"
    uuids = set()
    for start in range(0, len(targets), 64):
        done = subprocess.run(tool + ["--uuid", *targets[start:start + 64]], capture_output=True, text=True)
        uuids.update(parse_dwarfdump_uuids(done.stdout))
    return uuids, source


# ---------------------------------------------------------------- self-test
def envelope_bytes(event, attachments=(), lengths=True):
    lines = [json.dumps({"event_id": "0" * 32}).encode()]
    payload = json.dumps(event).encode()
    lines.append(json.dumps({"type": "event", **({"length": len(payload)} if lengths else {})}).encode())
    lines.append(payload)
    for name, data in attachments:
        lines.append(json.dumps({"type": "attachment", "length": len(data), "filename": name}).encode())
        lines.append(data)
    return b"\n".join(lines) + b"\n"


UUID = "1A2B3C4D-5E6F-7081-92A3-B4C5D6E7F809"


class SelfTest(unittest.TestCase):
    def crash_event(self, **tags):
        return {"level": "fatal", "tags": {"process": "cmux-holder", "crash_source": "macos_crash_report",
                                           "crash_key.daemon_epoch": "3", **tags},
                "exception": {"values": [{"stacktrace": {"frames": [
                    {"instruction_addr": "0x1000", "image_addr": "0x1000", "package": "/usr/lib/dyld"},
                    {"instruction_addr": "0x200010", "image_addr": "0x200000",
                     "package": "/Users/x/Library/Application Support/cmux-tui/host-exe/ab/cmux-holder"},
                    {"instruction_addr": "0x300004", "image_addr": "0x300000", "package": "/usr/lib/system/libsystem_c.dylib"},
                ]}}]},
                "debug_meta": {"images": [
                    {"image_addr": "0x200000", "image_size": 4096, "debug_id": UUID.lower(),
                     "code_file": "/Users/x/Library/Application Support/cmux-tui/host-exe/ab/cmux-holder"},
                    {"image_addr": "0x300000", "image_size": 4096, "debug_id": "ffffffff-0000-0000-0000-000000000000",
                     "code_file": "/usr/lib/system/libsystem_c.dylib"}]}}

    def test_envelope_with_lengths_and_attachment(self):
        box = b"1 app frame.commit B 0 0\n2 app key.frame E 7 0\n"
        envelope = parse_envelope(envelope_bytes(self.crash_event(), [("blackbox.txt", box)]), "a.envelope")
        self.assertEqual(envelope.event()["level"], "fatal")
        self.assertEqual(envelope.attachments()["blackbox.txt"], box)
        self.assertTrue(is_crash_envelope(envelope))

    def test_envelope_without_lengths(self):
        envelope = parse_envelope(envelope_bytes({"tags": [["crash_source", "owner_panic_log"]]}, lengths=False))
        self.assertEqual(tags_of(envelope.event()), {"crash_source": "owner_panic_log"})
        self.assertTrue(is_crash_envelope(envelope))

    def test_cut_envelope_is_an_error(self):
        data = envelope_bytes(self.crash_event())
        with self.assertRaises(EnvelopeError):
            parse_envelope(data[:-20])

    def test_session_is_not_a_crash(self):
        data = b'{}\n{"type":"session","length":2}\n{}\n'
        self.assertFalse(is_crash_envelope(parse_envelope(data)))
        self.assertFalse(is_crash_envelope(parse_envelope(envelope_bytes({"level": "error", "tags": {"a": "b"}}))))

    def test_blackbox_counts_key_records(self):
        text = ("1 app frame.commit B 0 0\n2 daemon key.echo_frame i 1 0\n3 holder holder.pty.read i 0 0\n"
                "4 app frame.present_estimate i 9 0\n5 app cef.pump E 0 0\nbroken line\n")
        self.assertEqual(blackbox_summary(text), {"events": 5, "key_records": 3, "malformed": 1})
        self.assertFalse(is_key_record("daemon.request"))
        self.assertFalse(is_key_record("empty.state"))  # "pty" only as a whole name part

    def test_top_frame_uuid(self):
        uuid, path, why = top_frame_uuid(self.crash_event())
        self.assertEqual((uuid, why), (normalize_uuid(UUID), ""))
        self.assertTrue(path.endswith("cmux-holder"))

    def test_top_cmux_frame_from_crashed_thread(self):
        event = {"threads": {"values": [{"crashed": False, "stacktrace": {"frames": [{"package": "/a/cmux DEV x.app/Contents/MacOS/cmux DEV x"}]}},
                                        {"crashed": True, "stacktrace": {"frames": [
                                            {"instruction_addr": "0x5008", "package": "/x/cmux DEV t.app/Contents/MacOS/cmux DEV t.debug.dylib"},
                                            {"instruction_addr": "0x9000", "package": "/System/Library/Frameworks/AppKit"}]}}]},
                 "debug_meta": {"images": [{"image_addr": "0x5000", "image_size": "0x100", "uuid": UUID,
                                            "code_file": "/x/cmux DEV t.app/Contents/MacOS/cmux DEV t.debug.dylib"}]}}
        self.assertEqual(top_frame_uuid(event)[0], normalize_uuid(UUID))

    def test_no_cmux_frame(self):
        event = {"exception": {"values": [{"stacktrace": {"frames": [{"package": "/usr/lib/dyld"}]}}]}}
        self.assertIsNone(top_frame_uuid(event)[0])
        self.assertFalse(is_cmux_image("/x/Chromium Embedded Framework.framework/Chromium Embedded Framework"))

    def test_dwarfdump_parse(self):
        text = (f"UUID: {UUID} (arm64) /b/cmux DEV t.app.dSYM/Contents/Resources/DWARF/cmux DEV t\n"
                "UUID: 00000000-1111-2222-3333-444444444444 (x86_64) /b/x.dSYM/Contents/Resources/DWARF/x\nnoise\n")
        found = parse_dwarfdump_uuids(text)
        self.assertEqual(set(found), {normalize_uuid(UUID), "00000000111122223333444444444444"})
        self.assertEqual(normalize_uuid(UUID.lower() + "-0"), normalize_uuid(UUID))

    def test_stability_counters_and_delta(self):
        reply = {"histograms": [
            {"name": "stability.child_exit.holder", "buckets": [{"index": 1, "low": 1, "high": 2, "count": 1}]},
            {"name": "stability.launch", "buckets": [{"index": 1, "low": 1, "count": 1}]},
            {"name": "key.frame", "buckets": [{"index": 3, "low": 4, "count": 9}]}]}
        after = stability_counters(reply)
        self.assertEqual(after, {("stability.child_exit.holder", 1): 1})
        self.assertIsNone(stability_counters({"error": "unavailable"}))
        self.assertEqual(counter_delta({}, after), {("stability.child_exit.holder", 1): 1})
        report = KindReport(KINDS_BY_NAME["holder-abort"])
        check_counter(report, report.kind, {}, after)
        self.assertEqual(report.status, PASS)
        report = KindReport(KINDS_BY_NAME["holder-abort"])
        check_counter(report, report.kind, after, after)
        self.assertEqual(report.status, FAIL)

    def test_envelope_checks(self):
        box = "".join(f"{i} app frame.commit B 0 0\n" for i in range(300)).encode()
        envelope = parse_envelope(envelope_bytes(self.crash_event(), [("blackbox.txt", box)]), "e")
        report = KindReport(KINDS_BY_NAME["holder-abort"])
        check_envelopes(report, report.kind, [envelope], {normalize_uuid(UUID)}, "test")
        self.assertEqual(report.status, PASS, [dataclasses.asdict(c) for c in report.checks])
        twice = KindReport(KINDS_BY_NAME["holder-abort"])
        check_envelopes(twice, twice.kind, [envelope, envelope], {normalize_uuid(UUID)}, "test")
        self.assertEqual(twice.status, FAIL)
        app = KindReport(KINDS_BY_NAME["app-signal"])
        keyed = box + b"301 app key.frame E 1 0\n"
        event = self.crash_event(process="cmux DEV t", crash_source="sentry")
        check_envelopes(app, app.kind, [parse_envelope(envelope_bytes(event, [("blackbox.txt", keyed)]))],
                        {normalize_uuid(UUID)}, "test")
        self.assertEqual([c.name for c in app.checks if c.status == FAIL], ["blackbox.txt has 0 key records"])
        wrong = KindReport(KINDS_BY_NAME["holder-abort"])
        check_envelopes(wrong, wrong.kind, [parse_envelope(envelope_bytes(self.crash_event(process="acpmux")))],
                        {normalize_uuid(UUID)}, "test")
        self.assertEqual(wrong.status, FAIL)

    def test_lstart_and_started_by_run(self):
        epoch = lstart_epoch("Tue Oct 27 10:00:05 2026")
        self.assertIsNotNone(epoch)
        rows = {10: (1, "Tue Oct 27 10:00:05 2026", "cmux-holder --socket s"),
                11: (1, "Tue Oct 27 09:00:00 2026", "cmux-holder --socket s"),
                12: (1, "Tue Oct 27 10:00:09 2026", "/bin/zsh")}
        tag = {10: rows[10][2], 11: rows[11][2]}
        self.assertTrue(started_by_run(10, rows, tag, epoch + 0.4, set())[0])
        self.assertFalse(started_by_run(11, rows, tag, epoch, set())[0])  # an older holder: never signalled
        self.assertFalse(started_by_run(12, rows, tag, epoch, set())[0])  # not the tag's
        self.assertFalse(started_by_run(10, rows, tag, epoch, {10})[0])   # the script or the app
        self.assertFalse(started_by_run(99, rows, tag, epoch, set())[0])
        self.assertIsNone(lstart_epoch("yesterday"))

    def test_holder_build_check(self):
        bundle = "/b/cmux DEV t.app/Contents/Resources/bin"
        sha = "a" * 64
        # What `ps` shows: the daemon sets argv0 to the bare name (service.rs); the file comes from proc_pidpath.
        command = "cmux-holder --socket /tmp/cmux-hd-501/1.sock --owner b:t@4"
        exe = f"/Users/x/Library/Application Support/cmux-tui/host-exe/{sha}/cmux-holder"
        hashed = []
        digest = lambda path: hashed.append(path) or sha  # noqa: E731
        self.assertTrue(holder_build_check(exe, bundle, digest=digest)[0])
        self.assertEqual(hashed, [f"{bundle}/cmux-holder", exe])
        other = lambda path: sha if path.startswith(bundle) else "b" * 64  # noqa: E731
        self.assertFalse(holder_build_check(exe, bundle, digest=other)[0])
        self.assertFalse(holder_build_check(exe.replace(sha, "c" * 64), bundle, digest=lambda path: sha)[0])
        self.assertEqual(holder_build_check(None, bundle, digest=digest),
                         (False, "the holder's executable path cannot be read"))
        builtin = f"/Users/x/Library/Application Support/cmux-tui/host-exe/{sha}/cmux-tui-host"
        hashed.clear()
        self.assertTrue(holder_build_check(builtin, bundle, digest=digest)[0])
        self.assertEqual(hashed[0], f"{bundle}/cmux-tui-host")
        self.assertTrue(is_holder(command))
        self.assertTrue(is_holder("cmux-tui __holder --socket s"))
        self.assertFalse(is_holder("/bin/zsh -f"))
        self.assertIsNone(executable_path(2 ** 22 + 7))  # no such pid (and no proc_pidpath off macOS)

    def test_runs_bundle_binary(self):
        app = "/Users/x/cmux DEV t.app"
        bin_dir = f"{app}/Contents/Resources/bin"
        self.assertTrue(runs_bundle_binary(f"{bin_dir}/acpmux daemon run", app, "acpmux", "daemon run"))
        self.assertTrue(runs_bundle_binary(f"{bin_dir}/acpmux daemon run --foreground", app, "acpmux", "daemon run"))
        self.assertFalse(runs_bundle_binary(f"{bin_dir}/acpmux __agent-host x", app, "acpmux", "daemon run"))
        self.assertTrue(runs_bundle_binary(f"{bin_dir}/cmux-app-host serve --socket s", app, "cmux-app-host"))
        self.assertTrue(runs_bundle_binary(f"{bin_dir}/cmux-browser-host", app, "cmux-browser-host"))
        self.assertFalse(runs_bundle_binary(f"{bin_dir}/cmux-browser-host-x serve", app, "cmux-browser-host"))
        self.assertFalse(runs_bundle_binary("/Users/x/cmux DEV u.app/Contents/Resources/bin/cmux-app-host serve",
                                            app, "cmux-app-host"))
        self.assertTrue(runs_bundle_binary("/var/f/cmux DEV t.app/Contents/Resources/bin/cmux-app-host serve",
                                           "/private/var/f/cmux DEV t.app", "cmux-app-host"))

    def test_uuid_rule_per_kind(self):
        panic = {"level": "error", "tags": {"process": "cmux-tui", "crash_source": "owner_panic_log",
                                            "crash_key.daemon_epoch": "1"},
                 "exception": {"values": [{"type": "RustPanic", "value": "injected"}]},
                 "threads": {"values": [{"crashed": False, "stacktrace": {"frames": [{"package": "/x/cmux DEV t"}]}}]},
                 "extra": {"backtrace": "0: main"}}
        envelope = parse_envelope(envelope_bytes(panic))
        for name in ("daemon-panic", "acpmux-panic", "utility-kill", "webkit-content-kill", "renderer-crash"):
            report = KindReport(KINDS_BY_NAME[name])
            event = dict(panic, tags={**panic["tags"], "process": "acpmux" if name == "acpmux-panic" else "cmux-tui"})
            check_envelopes(report, report.kind, [parse_envelope(envelope_bytes(event))], {normalize_uuid(UUID)}, "t")
            uuid = [c for c in report.checks if "UUID" in c.name]
            self.assertEqual([c.status for c in uuid], [SKIP], (name, [dataclasses.asdict(c) for c in report.checks]))
            self.assertEqual(uuid[0].detail, report.kind.no_stack[:500])
        stack = KindReport(KINDS_BY_NAME["daemon-segv"])
        check_envelopes(stack, stack.kind, [envelope], {normalize_uuid(UUID)}, "t")
        self.assertEqual([c.status for c in stack.checks if "UUID" in c.name], [FAIL])
        cef = "/b/cmux DEV t.app/Contents/Frameworks/Chromium Embedded Framework.framework/Chromium Embedded Framework"
        renderer = {"level": "fatal", "tags": {"process": "cmux DEV t Helper (Renderer)", "crash_source": "macos_crash_report",
                                               "crash_key.url_chunk": "1"},
                    "exception": {"values": [{"stacktrace": {"frames": [
                        {"instruction_addr": "0x7008", "package": cef}, {"instruction_addr": "0x9000", "package": "/usr/lib/dyld"}]}}]},
                    "debug_meta": {"images": [{"image_addr": "0x7000", "image_size": 4096, "debug_id": UUID, "code_file": cef}]}}
        report = KindReport(KINDS_BY_NAME["renderer-crash"])
        check_envelopes(report, report.kind, [parse_envelope(envelope_bytes(renderer))], {normalize_uuid(UUID)}, "t")
        self.assertEqual([c.status for c in report.checks if "UUID" in c.name], [PASS])
        self.assertIsNone(top_frame_uuid(renderer)[0])  # the cmux rule never accepts the Chromium framework

    def test_daemon_inject_without_socket_reports_the_kind(self):
        class Tagged:
            @staticmethod
            def daemon_socket(tag):
                raise SystemExit(f"bench: no daemon socket for tag {tag} after 30 s")
        report = KindReport(KINDS_BY_NAME["daemon-segv"])
        run = Run(None, report.kind, report, (None, Tagged, None, None))
        run.app = type("App", (), {"tag": "t"})()
        self.assertFalse(run.daemon_inject("segv"))
        self.assertEqual(report.status, NOT_MEASURABLE)
        self.assertIn("no daemon socket", report.checks[0].detail)

    def test_injector_requests_carry_only_kind(self):
        self.assertEqual(daemon_debug_panic("segv"), {"id": 1, "cmd": "debug-panic", "kind": "segv"})
        requests = acpmux_debug_panic("panic")
        self.assertEqual(requests[-1]["method"], "_acpmux/debug_panic")
        self.assertEqual(requests[-1]["params"], {"kind": "panic"})

    def test_injector_refusal(self):
        self.assertIsNone(injector_refusal({"id": 1, "ok": True}))
        self.assertIsNone(injector_refusal({"closed": True}))
        self.assertIsNone(injector_refusal({"jsonrpc": "2.0", "id": 2, "result": {}}))
        self.assertIn("unknown", injector_refusal({"id": 1, "ok": False, "error": "unknown cmd debug-panic"}))
        self.assertIn("not found", injector_refusal({"id": 2, "error": {"code": -32601, "message": "method not found"}}))

    def test_kind_table(self):
        names = [k.name for k in KINDS]
        self.assertEqual(len(names), 17)
        self.assertEqual(len(set(names)), 17)
        self.assertEqual(len(selected_kinds("", host=False)), 16)
        self.assertEqual(len(selected_kinds("", host=True)), 17)
        self.assertEqual([k.name for k in selected_kinds("chromium-host-abort", host=False)], [])
        for kind in KINDS:
            self.assertIn(kind.report, ("relaunch", "live"))
            self.assertTrue(hasattr(Run, kind.trigger), kind.trigger)
            self.assertIn(kind.images, IMAGE_RULES)
            # Task 101's injectors take only a kind name; no injector takes a target.
            if kind.trigger in ("daemon_inject", "acpmux_inject"):
                self.assertIn(kind.arg, ("panic", "abort", "segv"), kind.name)
            if kind.trigger in ("daemon_inject", "acpmux_inject") and kind.arg == "panic":
                self.assertIsNone(kind.counter, f"{kind.name}: a thread panic ends no process")
            if kind.counter is None:
                self.assertTrue(kind.counter_why, kind.name)
            if kind.stand_in:
                self.assertTrue(kind.name.endswith("-panic") and kind.trigger not in ("daemon_inject", "acpmux_inject"))
            if kind.counter:
                name, value = kind.counter
                self.assertTrue(name == "stability.unclean_exit"
                                or name.removeprefix("stability.child_exit.") in STABILITY_KINDS, name)
                self.assertIn(value, (UNCLEAN_CRASH, CHILD_SIGNAL, CHILD_PANIC))
        with self.assertRaises(SystemExit):
            selected_kinds("bogus", host=False)

    def test_recorder_reads_new_files_only(self):
        folder = tempfile.mkdtemp(prefix="crash-matrix-test-")
        recorder = Recorder(folder)
        with open(os.path.join(folder, "old.envelope"), "wb") as handle:
            handle.write(envelope_bytes(self.crash_event()))
        seen = recorder.files()
        with open(os.path.join(folder, "new.envelope"), "wb") as handle:
            handle.write(envelope_bytes(self.crash_event()))
        with open(os.path.join(folder, "half.envelope"), "wb") as handle:
            handle.write(envelope_bytes(self.crash_event())[:-30])
        envelopes, broken = recorder.wait(seen, timeout=1, settle=0)
        self.assertEqual([os.path.basename(e.path) for e in envelopes], ["new.envelope"])
        self.assertEqual(list(map(os.path.basename, broken)), ["half.envelope"])
        shutil.rmtree(folder)


# ---------------------------------------------------------------- main
def parse(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--app", help="the tagged bench or DEV app (default $NX_APP)")
    parser.add_argument("--recorder", help="the recorder folder (one subfolder per kind; default <out>/recorder)")
    parser.add_argument("--out", help="the report folder (default a new temporary folder)")
    parser.add_argument("--only", default="", help="comma-separated kinds")
    parser.add_argument("--host", action="store_true", help="also run chromium-host-abort with cefHelperHost on")
    parser.add_argument("--dsyms", action="append", default=[], help="a folder with the build's dSYMs (repeatable)")
    parser.add_argument("--uuids-from-binaries", action="store_true",
                        help="also accept the UUIDs of the bundle's own Mach-O files (a DEV build without dSYMs)")
    parser.add_argument("--timeout", type=float, default=90, help="seconds to wait for a crash envelope")
    parser.add_argument("--settle", type=float, default=10, help="seconds to wait for a second envelope")
    parser.add_argument("--self-test", action="store_true", help="test the parsers and the ownership rule")
    parser.add_argument("--list", action="store_true", help="print the kinds")
    return parser.parse_args(argv)


def main(argv=None):
    opts = parse(argv)
    if opts.self_test:
        result = unittest.TextTestRunner(verbosity=1).run(unittest.defaultTestLoader.loadTestsFromTestCase(SelfTest))
        return 0 if result.wasSuccessful() else 1
    if opts.list:
        for kind in KINDS:
            counter = f"{kind.counter[0]}[{kind.counter[1]}]" if kind.counter else "-"
            print(f"{kind.name:<22} {kind.trigger:<20} {kind.report:<9} {counter}{'  (--host)' if kind.host_flag else ''}"
              f"{'  (SIGABRT stands in for a panic)' if kind.stand_in else ''}")
        return 0
    opts.app = opts.app or os.environ.get("NX_APP")
    if not opts.app:
        print("crash-matrix: pass --app APP or set $NX_APP", file=sys.stderr)
        return 2
    kinds = selected_kinds(opts.only, opts.host)
    opts.out = os.path.abspath(opts.out or tempfile.mkdtemp(prefix="crash-matrix-"))
    opts.recorder = os.path.abspath(opts.recorder or os.path.join(opts.out, "recorder"))
    import bench_launch, bench_tagged, tag_teardown  # noqa: E401 (macOS run only; the self-test needs none)
    e2e = bench_launch.load_by_path("child_crash_e2e", os.path.join(HERE, "child-crash-e2e.py"))
    bench_launch.require_gui_session("crash-matrix")
    uuids, uuid_source = collect_uuids(os.path.realpath(opts.app), opts.dsyms, opts.uuids_from_binaries)
    print(f"crash-matrix: {len(kinds)} kinds, {len(uuids)} debug UUIDs ({uuid_source}), recorder {opts.recorder}", flush=True)
    if not opts.host:
        print("SKIP chromium-host-abort: runs only with --host (cefHelperHost on)", flush=True)
    reports = []
    for kind in kinds:
        report = KindReport(kind)
        Run(opts, kind, report, (bench_launch, bench_tagged, tag_teardown, e2e)).run(uuids, uuid_source)
        reports.append(report)
    summary = {"app": opts.app, "recorder": opts.recorder, "uuid_source": uuid_source, "host": opts.host,
               "kinds": [r.json() for r in reports]}
    with open(os.path.join(opts.out, "crash-matrix.json"), "w") as handle:
        json.dump(summary, handle, indent=2)
    print("\ncrash-matrix:")
    for report in reports:
        failed = [c.name for c in report.checks if c.status in (FAIL, NOT_MEASURABLE)]
        print(f"  {report.kind.name:<22} {report.status:<15} {', '.join(failed)}")
    print(f"report: {os.path.join(opts.out, 'crash-matrix.json')}")
    return 0 if all(r.status == PASS for r in reports) else 1


if __name__ == "__main__":
    sys.exit(main())
