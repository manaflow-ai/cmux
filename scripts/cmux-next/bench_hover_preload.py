#!/usr/bin/env python3
"""Hover preload bench (plans/cmux-next/hover-preload-DESIGN.md, cmux-ad m34).

Uses only debug socket calls (`debug.pointer_hover {row}`, `debug.pointer_sweep`, `debug.frames`,
`debug.surfaces`), so the same run measures a build without hover preload (the base, with this harness
cherry-picked) and one with it, on one mini. The synthetic pointer aims at a row by its sidebar row id (the
store id in the row key; the bench names each workspace uniquely and maps its ws_ id by that title), read
in the app at the move (rows a reveal scroll moved are followed), and the sweep runs in the app, one move
per main-actor turn paced by the clock (not one socket round trip, a display frame, per move).

  (a) sweep   --workspaces sidebar rows, each with one hidden browser page, frozen or hibernated
              first. The synthetic pointer crosses --hz rows a second, down and up, until it crossed
              --crossings rows, then leaves the sidebar. Printed: wakes started (prewarmed_total and
              restores, must be 0), missed refreshes and main-thread busy ms per frame over the sweep
              (p50/p95/p99/max), each move's main-thread ms (event delivery and every handler it ran),
              and how many moves left their row hovered. Only rows the pointer really hovers are swept
              (each is checked once first); the sweep is reported invalid when the swept pages did not
              all freeze or hibernate first. --profile DIR records a Time Profiler trace over the sweep
              and prints the app's heaviest main-thread frames (PERF-HOVER-PROFILE). --stalls MS launches the
              app with its main-thread watchdog at MS (CMUX_NEXT_HANG_THRESHOLD_MS) and prints the stack sampled
              in each main-thread turn over MS during the sweep, the app's own frames named by atos
              (PERF-HOVER-STALL), and the frames most stalls share (PERF-HOVER-STALLS): no Instruments needed.
  (b) click   one workspace with --panes browser panes, hibernated by the timeout. --trials times
              each: "cold" (select it from another workspace, no hover) and "dwell" (the pointer
              rests --dwell-ms on its row, then select). Time to content: from the select until
              every shown page is live (not the hibernated stand-in) and answers
              document.readyState == "complete". First frame: the commit that carries the switch
              (debug.workspace_switch) shows every page live and loaded, not the stand-in or a
              page still loading (first_frame_content).
  (c) grace   after a dwell with no select: renderer footprint before the hover, after the wake, and
              after hoverGrace (30 s) plus --grace-slack-s; the woken pages must hibernate again.

Usage (a fleet mini, never a laptop; DEV or bench build):
  bench_hover_preload.py --app BUNDLE [--engine webkit|chromium] [--workspaces 40] [--crossings 200]
      [--hz 120] [--panes 2] [--trials 5] [--dwell-ms 150] [--out FILE.json] [--profile DIR] [--stalls MS]
Prints PERF-HOVER lines.
"""
from __future__ import annotations

import argparse
import http.server
import json
import os
import shutil
import collections
import signal
import struct
import subprocess
import sys
import tempfile
import threading
import time
import xml.etree.ElementTree as ET

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bench_memory as bm  # noqa: E402  (launch, App, sample, end_bundle, wait_gone)
import bench_power as bp  # noqa: E402  (rpc, wipe_state)

PAGE = (b"<!doctype html><title>hover bench</title><body style='font:16px sans-serif'>"
        + b"<h1>Hover preload bench</h1>" + b"<p>" + b"Lorem ipsum dolor sit amet. " * 400 + b"</p></body>")
GRACE_S = 30  # BrowserHibernation.hoverGrace


class Page(http.server.BaseHTTPRequestHandler):
    def do_GET(self):  # noqa: N802 (http.server API)
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(PAGE)))
        self.end_headers()
        self.wfile.write(PAGE)

    def log_message(self, *_):
        pass


def serve() -> int:
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Page)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server.server_address[1]


class Sites:
    """A site of its own per page, so a discard or a wake changes its own renderer (as
    bench_hibernation.page_url): Chromium tN.localhost on one port, WebKit a port each."""

    def __init__(self, engine: str):
        self.engine, self.ports, self.count = engine, [serve()], 0

    def next(self, label: str) -> str:
        index, self.count = self.count, self.count + 1
        if self.engine == "chromium":
            return f"http://t{index}.localhost:{self.ports[0]}/?n={label}"
        if index >= len(self.ports):
            self.ports.append(serve())
        return f"http://127.0.0.1:{self.ports[index]}/?n={label}"


def start_vdisplay(hz: float, scratch: str, hold_s: int = 3600) -> tuple[subprocess.Popen, str]:
    """`--vdisplay HZ`: a 1920x1200 virtual main display at `hz` (scripts/ci/frame-pacing/vdisplay.m, as
    palette-open-stages.py and split-spring.sh), made before the app launches, so a 60 Hz mini measures at 120 Hz.
    Returns the helper (it ends by itself after `hold_s`) and its ready line ("ready DISPLAY_ID p50_ms main=ID")."""
    repo = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
    folder = os.path.join(scratch, "VDisplay.app", "Contents")
    os.makedirs(os.path.join(folder, "MacOS"), exist_ok=True)
    binary = os.path.join(folder, "MacOS", "VDisplay")
    built = subprocess.run(["xcrun", "clang", "-fobjc-arc", "-O2", "-Wno-deprecated-declarations", "-framework", "AppKit",
                            "-framework", "CoreVideo", os.path.join(repo, "scripts/ci/frame-pacing/vdisplay.m"), "-o", binary],
                           capture_output=True, text=True)
    if built.returncode != 0:
        raise SystemExit(f"bench-hover-preload: the virtual display helper did not compile: {built.stderr[-600:]}")
    shutil.copyfile(os.path.join(repo, "scripts/ci/frame-pacing/VDisplay-Info.plist"), os.path.join(folder, "Info.plist"))
    subprocess.run(["codesign", "-s", "-", "--force", os.path.dirname(folder)], capture_output=True)
    out = open(os.path.join(scratch, "vdisplay.out"), "w+")
    helper = subprocess.Popen([binary, str(int(hz)), str(hold_s), "main", "1920x1200"], stdout=out, stderr=subprocess.DEVNULL)
    line = ""
    for _ in range(20):
        out.seek(0)
        line = next((l for l in out.read().splitlines() if l.startswith(("ready", "error"))), "")
        if line or helper.poll() is not None:
            break
        time.sleep(1)  # test script: a bounded wait for the helper's own ready line
    if not line.startswith("ready"):
        helper.kill()
        raise SystemExit(f"bench-hover-preload: no virtual display ({line or 'no line'})")
    time.sleep(2)  # test script: WindowServer settles the new main display before the app opens on it
    return helper, line


def pct(values: list[float], p: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    return round(ordered[min(len(ordered) - 1, int(round(p * (len(ordered) - 1))))], 3)


def dist(values: list[float]) -> dict:
    return {"n": len(values), "p50": pct(values, 0.5), "p95": pct(values, 0.95), "p99": pct(values, 0.99),
            "max": round(max(values), 3) if values else None}


def wait_for(predicate, seconds: float, step: float = 0.25):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(step)  # test script: polls the app's state
    return predicate()


class Bench:
    def __init__(self, sock: str, app: bm.App, pid: int = 0):
        self.sock, self.app, self.pid = sock, app, pid
        self.titles: dict[str, str] = {}  # daemon workspace id -> the unique title the bench gave it
        self.mapped_by = "none"  # how row_keys mapped them: by "title", or by "order" when a rename was refused

    def rpc(self, method: str, params: dict | None = None, timeout: float = 30):
        return bp.rpc(self.sock, method, params, timeout=timeout) or {}

    def hibernation(self) -> dict:
        return self.rpc("debug.surfaces").get("hibernation") or {}

    def rows(self) -> list[dict]:
        windows = self.rpc("debug.sidebar_rows").get("windows") or []
        rows = (windows[0] if windows else {}).get("rows") or []
        rows = [r for r in rows if str(r.get("key", "")).startswith("workspace(") and r.get("in_list") and r.get("window_frame")]
        return sorted(rows, key=lambda r: float(r["window_frame"]["y"]))

    def hover(self, point: list[float] | None) -> float:
        started = time.perf_counter()
        self.rpc("debug.pointer_hover", {"point": point} if point else {})
        return (time.perf_counter() - started) * 1000

    def hover_row(self, workspace: str) -> dict:
        """The pointer to the middle of `workspace`'s sidebar row as the app draws it now (`workspace` is the row's
        store id, `row_key`); the reply says which workspace's row shows hovered after the move (`row_hovered`)."""
        return self.rpc("debug.pointer_hover", {"row": workspace})

    def row_keys(self, titles: dict[str, str]) -> dict[str, str]:
        """Each daemon workspace id (ws_..., what actions take) -> its sidebar row's store id (the UUID in the row
        key `workspace(<id>)`, what `debug.pointer_hover {row}` and `debug.pointer_sweep` take), by the unique
        title the bench gave each workspace. Waits until every title shows in the sidebar's rows."""
        def listed() -> list[tuple[str, str]]:
            windows = self.rpc("debug.sidebar_rows").get("windows") or []
            return [(key[len("workspace("):-1], str(row.get("title") or "")) for row in (windows[0] if windows else {}).get("rows") or []
                    for key in [str(row.get("key", ""))] if key.startswith("workspace(") and key.endswith(")")]

        def read():
            by_title = {title: key for key, title in listed()}
            found = {ws: by_title[title] for ws, title in titles.items() if title in by_title}
            return found if len(found) == len(titles) else None
        found = wait_for(read, 15, 0.25)
        if found:
            self.mapped_by = "title"
            return found
        # A rename the app refused: the bench's workspaces are the last rows, in the order newAtBottom made them.
        rows = listed()
        if len(rows) < len(titles):
            return {}
        self.mapped_by = "order"
        return {ws: key for ws, (key, _) in zip(titles, rows[-len(titles):])}

    def still(self) -> bool:
        """The sidebar's rows hold still (no reveal scroll or row motion in flight): two reads 0.3 s apart agree."""
        def frames():
            return [(r.get("key"), r["window_frame"].get("y")) for r in self.rows()]
        first = frames()
        time.sleep(0.3)  # test script: two reads apart
        return bool(first) and first == frames()

    def hoverable(self, workspaces: list[str]) -> tuple[list[str], list[dict]]:
        """The workspaces whose row the synthetic pointer really hovers (not under the footer, not scrolled off),
        and each refusal with what the app answered."""
        wait_for(self.still, 10, 0.2)
        kept, refused = [], []
        for workspace in workspaces:
            reply = self.hover_row(workspace)
            if str(reply.get("row_hovered") or "").endswith(workspace):
                kept.append(workspace)
            else:
                refused.append({"workspace": workspace, "reply": reply})
        self.hover(None)
        return kept, refused

    def open_workspace(self, engine: str, urls: list[str]) -> tuple[str | None, list[str]]:
        made = self.app.run("workspace.newAtBottom")
        created = [c for c in made.get("created", []) if str(c).startswith("ws_")]
        if not created:
            print(f"   workspace.newAtBottom: {made.get('error') or made}", file=sys.stderr)
            return None, []
        self.app.run("workspace.selectLast")
        # A unique title, so the bench finds this workspace's sidebar row (rows are keyed by store id, not ws_).
        self.titles[created[0]] = f"hover-bench-{len(self.titles)}"
        named = self.app.action("renameWorkspace", workspace=created[0], name=self.titles[created[0]])
        if named.get("error"):  # then through the CLI's --target
            named = self.app.run("renameWorkspace", target=created[0], name=self.titles[created[0]])
        if named.get("error"):
            print(f"   renameWorkspace {created[0]}: {named['error']}", file=sys.stderr)
        tabs = []
        for index, url in enumerate(urls):
            if index:
                self.app.run("splitRight")
            reply = self.app.run(f"openBrowser.{engine}", url=url)
            made_tabs = [t for t in reply.get("created", []) if str(t).startswith("tab_")]
            for tab in made_tabs:
                # A fresh profile starts on Home: a tab the daemon made has no page until it shows (as
                # bench_hibernation.open_tab). Show it, then wait until its page loaded.
                self.app.run("tab.focus", target=tab)
                if not wait_for(lambda t=tab: self.live(t, set()), 30, 0.1):
                    print(f"   {tab}: page did not load", file=sys.stderr)
            tabs += made_tabs
        return created[0], tabs

    def live(self, tab: str, hibernated: set[str]) -> bool:
        # Never asks a hibernated page (a script call would wake it); a live page answers once it loaded.
        if tab in hibernated:
            return False
        answer = self.rpc("browser.page.eval", {"tab": tab, "script": "document.readyState"}, timeout=5)
        return not answer.get("error") and answer.get("value") == "complete"

    def asleep(self, tabs: list[str]) -> bool:
        return set(tabs) <= set(self.hibernation().get("hibernated") or [])

    def diagnose(self, label: str, tabs: list[str]) -> dict:
        """Why `tabs` are not asleep: each one's lifecycle phase and exemption, counted, plus the setting the
        app reports. Printed as one PERF-HOVER-DIAG line and kept in the report."""
        h = self.hibernation()
        hibernated, frozen = set(h.get("hibernated") or []), set(h.get("frozen") or [])
        phases, exemptions = h.get("page_phases") or {}, h.get("exemptions") or {}
        counts: dict[str, int] = {}
        for tab in tabs:
            state = "hibernated" if tab in hibernated else phases.get(tab, "no_page")
            if tab in frozen:
                state += "+frozen"
            key = f"{state}/{exemptions.get(tab, '-')}"
            counts[key] = counts.get(key, 0) + 1
        result = {"label": label, "tabs": len(tabs), "states": counts, "mode": h.get("mode"),
                  "pressure": h.get("pressure"), "hibernated_total": h.get("hibernated_total"),
                  "sample_ids": {"bench": tabs[:2], "app": sorted(phases)[:2]}}
        print(f"PERF-HOVER-DIAG {json.dumps(result)}", flush=True)
        return result


class Profile:
    """`--profile`: an Instruments Time Profiler recording over the sweep only, then the heaviest
    main-thread frames (self and inclusive ms) as PERF-HOVER-PROFILE lines. What the hover path runs on main per
    crossing, by name (as scripts/measure/pane-main-profile.sh reads its trace)."""

    def __init__(self, pid: int, directory: str, label: str):
        os.makedirs(directory, exist_ok=True)
        self.pid, self.trace = pid, os.path.join(directory, f"sweep-{label}-{pid}.trace")
        # Every process, as pane-main-profile.sh records (an attach needs a grant a fleet step may lack); rows are
        # kept for this app's main thread only.
        self.proc = subprocess.Popen(["xcrun", "xctrace", "record", "--template", "Time Profiler", "--all-processes",
                                      "--time-limit", "300s", "--output", self.trace, "--no-prompt"],
                                     stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        self.started = threading.Event()
        self.lines: list[str] = []
        threading.Thread(target=self.read, daemon=True).start()
        if not self.started.wait(120):
            print(f"PERF-HOVER-PROFILE error=not_started output={json.dumps(self.lines[-5:])}", flush=True)

    def read(self):
        for line in self.proc.stdout or []:
            self.lines.append(line.strip())
            if "Starting recording" in line or "Ctrl-C to stop" in line:
                self.started.set()

    def stop(self) -> dict:
        self.proc.send_signal(signal.SIGINT)
        try:
            self.proc.wait(180)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            return {"error": "xctrace did not stop"}
        table = self.trace + ".xml"
        with open(table, "w") as handle:
            subprocess.run(["xcrun", "xctrace", "export", "--input", self.trace, "--xpath",
                            '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]'], stdout=handle, check=False,
                           timeout=300)
        return main_thread_frames(table, self.pid)


def main_thread_frames(table: str, pid: int, top: int = 30) -> dict:
    """Self and inclusive main-thread ms per frame name in an exported time-profile table: the main thread
    of `pid`, else (a launcher pid, not the app's) the one main thread of a process named cmux."""
    byid: dict[str, ET.Element] = {}
    per: dict[str, list] = {}  # main thread name -> [own, inclusive, total ns]

    def resolve(element):
        ref = element.get("ref")
        return byid.get(ref, element) if ref else element
    for _, element in ET.iterparse(table, events=("end",)):
        if element.get("id"):
            byid[element.get("id")] = element
        if element.tag != "row":
            continue
        thread = element.find("thread")
        thread_name = resolve(thread).get("fmt", "") if thread is not None else ""
        if "Main Thread" not in thread_name:
            continue
        weight = element.find("weight")
        weight = resolve(weight) if weight is not None else None
        ns = int(weight.text) if weight is not None and weight.text and weight.text.isdigit() else 1_000_000
        backtrace = element.find("backtrace")
        backtrace = resolve(backtrace) if backtrace is not None else None
        names = [resolve(frame).get("name", "?") for frame in backtrace.findall("frame")] if backtrace is not None else []
        if not names:
            continue
        own, inclusive, _ = per.setdefault(thread_name, [collections.Counter(), collections.Counter(), 0])
        per[thread_name][2] += ns
        own[names[0]] += ns
        for name in set(names):
            inclusive[name] += ns
    chosen = [name for name in per if f"pid: {pid}" in name] or [name for name in per if "(cmux" in name]
    if len(chosen) != 1:
        return {"main_ms": 0.0, "threads": sorted(per, key=lambda name: -per[name][2])[:3], "self": [], "inclusive": []}
    own, inclusive, total = per[chosen[0]]
    return {"main_ms": round(total / 1e6, 1), "thread": chosen[0],
            "self": [[round(ns / 1e6, 1), name[:160]] for name, ns in own.most_common(top)],
            "inclusive": [[round(ns / 1e6, 1), name[:160]] for name, ns in inclusive.most_common(top * 2)]}


CPU_ARCH = {(0x0100000C, 0): "arm64", (0x0100000C, 1): "arm64", (0x0100000C, 2): "arm64e", (0x01000007, 3): "x86_64"}


def macho_slices(path: str) -> list[tuple[str, str | None]]:
    """(LC_UUID uppercase with dashes, atos arch name or None) of each 64-bit slice of a Mach-O file; [] for any other
    file. Reads only the headers, so a whole bundle's same-named files are cheap to tell apart."""
    try:
        with open(path, "rb") as handle:
            head = handle.read(8)
            if len(head) < 8:
                return []
            magic = struct.unpack(">I", head[:4])[0]
            if magic in (0xCAFEBABE, 0xCAFEBABF):  # universal: big-endian table of slices
                count, wide = struct.unpack(">I", head[4:])[0], magic == 0xCAFEBABF
                entry = ">iiQQII" if wide else ">iiIII"
                table = handle.read(struct.calcsize(entry) * min(count, 64))
                out = []
                for index in range(len(table) // struct.calcsize(entry)):
                    cputype, subtype, offset = struct.unpack_from(entry, table, index * struct.calcsize(entry))[:3]
                    out += [(uuid, CPU_ARCH.get((cputype & 0xFFFFFFFF, subtype & 0xFF)))
                            for uuid, _ in _thin_slice(handle, offset)]
                return out
            return _thin_slice(handle, 0)
    except OSError:
        return []


def _thin_slice(handle, offset: int) -> list[tuple[str, str | None]]:
    handle.seek(offset)
    header = handle.read(32)
    if len(header) < 32 or struct.unpack("<I", header[:4])[0] != 0xFEEDFACF:  # MH_MAGIC_64, little-endian
        return []
    cputype, subtype, _, ncmds, sizeofcmds = struct.unpack("<iiIII", header[4:24])
    commands = handle.read(min(sizeofcmds, 1 << 20))
    at = 0
    for _ in range(ncmds):
        if at + 8 > len(commands):
            break
        cmd, size = struct.unpack_from("<II", commands, at)
        if cmd == 0x1B and size >= 24 and at + 24 <= len(commands):  # LC_UUID
            raw = commands[at + 8:at + 24].hex().upper()
            uuid = f"{raw[:8]}-{raw[8:12]}-{raw[12:16]}-{raw[16:20]}-{raw[20:]}"
            return [(uuid, CPU_ARCH.get((cputype & 0xFFFFFFFF, subtype & 0xFF)))]
        if size < 8:
            break
        at += size
    return []


class Atos:
    """Names a stall frame the app could not (`symbol` null: a stripped or local function) from its image in the
    bundle and its offset from the image header, with atos: one call per image per stall set. The image is the bundle
    file whose LC_UUID is the frame's `image_uuid`: a bundle holds more than one file of one name (the app's cmux in
    Contents/MacOS, the CLI's in Contents/Resources/bin), so a name alone could pick the wrong binary."""

    LOAD = 0x100000000  # any load address: atos takes the slide from it

    def __init__(self, bundle: str):
        self.files: dict[str, list[str]] = collections.defaultdict(list)
        for root, _, files in os.walk(os.path.join(bundle, "Contents")):
            for name in files:
                self.files[name].append(os.path.join(root, name))

    def binary(self, image: str, uuid: str | None) -> tuple[str, str | None] | None:
        """(path, arch) of the bundle file of `image` whose slice has `uuid`; None when no file has it (a system
        image, or a frame with no UUID: never a guess)."""
        if not uuid:
            return None
        wanted = uuid.upper()
        for path in self.files.get(image, []):
            for found, arch in macho_slices(path):
                if found == wanted:
                    return path, arch
        return None

    def names(self, wanted: dict[tuple[str, str | None], set[int]]) -> dict[tuple[str, str | None, int], str]:
        found = {}
        for (image, uuid), offsets in wanted.items():
            located, ordered = self.binary(image, uuid), sorted(offsets)
            if not located or not ordered:
                continue
            path, arch = located
            try:
                out = subprocess.run(["xcrun", "atos", "-o", path] + (["-arch", arch] if arch else [])
                                     + ["-l", hex(self.LOAD)] + [hex(self.LOAD + o) for o in ordered],
                                     capture_output=True, text=True, timeout=120).stdout.splitlines()
            except (OSError, subprocess.SubprocessError):
                continue
            for offset, line in zip(ordered, out):
                if line and not line.startswith("0x"):
                    found[(image, uuid, offset)] = line.strip()
        return found


def _lookup(detail: dict, index: int) -> tuple[str, str | None, int] | None:
    """The (image, uuid, offset) atos names for an unnamed frame: the call for a return address (index > 0)."""
    if detail.get("symbol") is not None or not detail.get("image") or detail.get("image_offset") is None:
        return None
    return detail["image"], detail.get("image_uuid"), int(detail["image_offset"]) - (1 if index else 0)


def stall_frames(bench: Bench, bundle: str, report: dict, top: int = 40):
    """The main-thread turns over --stalls ms during the sweep (debug.hangs): each one's duration, CPU and stack
    (sampled mid-turn), app frames named by atos, then each frame name with the number of stalls it is in. A record
    that does not parse is skipped and listed (`skipped`), never the end of the report."""
    hangs = bench.rpc("debug.hangs", {"limit": 128}, timeout=60)
    records, skipped = [], []
    for record in [r for r in hangs.get("records") or [] if isinstance(r, dict) and r.get("kind") == "stall"]:
        try:
            details = record.get("frame_details") or []
            keys = [_lookup(detail, index) for index, detail in enumerate(details)]
            records.append((record, float(record["duration_ms"]), float(record.get("cpu_ms") or 0),
                            list(zip(record.get("frames") or [], keys))))
        except (KeyError, TypeError, ValueError, AttributeError) as error:
            skipped.append({"sequence": record.get("sequence"), "error": repr(error)})
    wanted: dict[tuple[str, str | None], set[int]] = collections.defaultdict(set)
    for _, _, _, frames in records:
        for _, key in frames:
            if key:
                wanted[key[:2]].add(key[2])
    named = Atos(bundle).names(wanted)
    shared: collections.Counter = collections.Counter()
    stalls = []
    for _, ms, cpu_ms, frames in records:
        names = [named.get(key, text) if key else text for text, key in frames]
        stalls.append({"ms": ms, "cpu_ms": cpu_ms, "frames": names})
        shared.update(set(names))
        print(f"PERF-HOVER-STALL ms={ms:.1f} cpu_ms={cpu_ms:.1f} frames={len(names)}", flush=True)
        for name in names[:48]:
            print(f"PERF-HOVER-STALL   {name[:200]}", flush=True)
    report["sweep_stalls"] = {"threshold_ms": hangs.get("threshold_ms"), "count": len(stalls), "stalls": stalls,
                              "shared": shared.most_common(top), "skipped": skipped}
    print(f"PERF-HOVER-STALLS threshold_ms={hangs.get('threshold_ms')} count={len(stalls)} skipped={len(skipped)} "
          f"installed={hangs.get('installed')}", flush=True)
    for name, count in shared.most_common(top):
        print(f"PERF-HOVER-STALLS {count:3d}/{len(stalls)}  {name[:200]}", flush=True)


def sweep(bench: Bench, args, report: dict, rows: list[str]):
    if len(rows) < 2:
        report["sweep"] = {"error": f"rows={len(rows)}"}
        print(f"PERF-HOVER-SWEEP error rows={len(rows)}", flush=True)
        return
    before = bench.hibernation()
    path, index, step = [], 0, 1
    while len(path) < args.crossings:
        path.append(rows[index])
        if not 0 <= index + step < len(rows):
            step = -step
        index += step
    profile = None
    if args.profile:
        try:
            profile = Profile(bench.pid, args.profile, args.label)
        except Exception as error:  # a profile that cannot start never costs the arm its sweep
            report["sweep_profile"] = {"error": repr(error)}
    if args.stalls:
        bench.rpc("debug.hangs", {"clear": True, "limit": 0})
    bench.rpc("debug.frames", {"action": "start"})
    moved = bench.rpc("debug.pointer_sweep", {"path": path, "hz": args.hz}, timeout=90)
    time.sleep(0.5)  # test script: past the dwell, so a pending intent would have fired
    frames = bench.rpc("debug.frames", {"action": "stop", "raw": True})
    if profile:
        try:
            frames_of_profile = profile.stop()
        except Exception as error:  # an export that fails or does not parse keeps the sweep's numbers
            profile.proc.kill()
            frames_of_profile = {"error": repr(error)}
        report["sweep_profile"] = frames_of_profile
        print(f"PERF-HOVER-PROFILE main_ms={frames_of_profile.get('main_ms')} error={frames_of_profile.get('error')} "
              f"unmatched_threads={json.dumps(frames_of_profile.get('threads'))}", flush=True)
        for kind in ("self", "inclusive"):
            for ms, name in frames_of_profile.get(kind) or []:
                print(f"PERF-HOVER-PROFILE {kind} {ms:8.1f} ms  {name}", flush=True)
    if args.stalls:
        try:
            stall_frames(bench, args.app, report)
        except Exception as error:  # a stall read that fails keeps the sweep's numbers, as a failed profile does
            report["sweep_stalls"] = {"error": repr(error)}
            print(f"PERF-HOVER-STALLS error={error!r}", flush=True)
    main_ms = [float(v) for v in frames.get("main_ms") or []]
    move_ms = [float(v) for v in moved.get("move_ms") or []]
    after = bench.hibernation()
    woke = (after.get("prewarmed_total") or 0) - (before.get("prewarmed_total") or 0)
    restores = (after.get("restored_total") or 0) - (before.get("restored_total") or 0)
    seconds = float(moved.get("seconds") or 0)
    result = {"rows_on_screen": len(rows), "crossings": len(path), "hz": args.hz, "duration_s": seconds,
              "rows_per_s": round(len(path) / seconds, 1) if seconds else None, "late_moves": moved.get("late"),
              "missing_rows": moved.get("missing"), "landed": moved.get("landed"), "hover_areas": moved.get("areas"),
              "error": moved.get("error"), "wakes": woke, "restores": restores,
              "move_ms": dist(move_ms), "main_busy_ms_per_frame": dist(main_ms),
              "frames": {k: frames.get(k) for k in (
                  "frames", "refresh_ms", "missed", "p50_ms", "p99_ms", "max_ms", "main_over_8_3_ms")}}
    report["sweep"] = result
    print(f"PERF-HOVER-SWEEP crossings={len(path)} rows_per_s={result['rows_per_s']} late_moves={result['late_moves']} "
          f"landed={result['landed']} missing={result['missing_rows']} wakes={woke} restores={restores} "
          f"refresh_ms={frames.get('refresh_ms')} missed={frames.get('missed')} "
          f"main={json.dumps(result['main_busy_ms_per_frame'])} move_ms={json.dumps(result['move_ms'])}"
          + (f" error={moved.get('error')}" if moved.get("error") else ""), flush=True)


def click_trials(bench: Bench, args, report: dict, target: str, row: str, tabs: list[str], away: str, hoverable: bool):
    """`target` is the workspace's daemon id (for actions), `row` its sidebar row id (for the pointer)."""
    trials = []
    for trial in range(args.trials):
        if report.get("click_stopped"):
            break
        for mode in ("cold", "dwell"):
            bench.hover(None)  # first: the reveal scroll must not move rows under a resting pointer
            bench.app.action("goToWorkspace", workspace=away)
            if not wait_for(lambda: bench.asleep(tabs), args.sleep_wait_s, 1):
                trials.append({"trial": trial, "mode": mode, "error": "pages did not hibernate",
                               "diag": bench.diagnose(f"click-{trial}-{mode}", tabs)})
                print(f"PERF-HOVER-CLICK trial={trial} mode={mode} error=not_hibernated", flush=True)
                # Every later trial would wait the same timeout for the same reason: the arm stops here.
                report["click_stopped"] = f"trial {trial} {mode}: pages did not hibernate"
                break
            if mode == "dwell":
                landed = str(bench.hover_row(row).get("row_hovered") or "").endswith(row) if hoverable else False
                if not landed:
                    trials.append({"trial": trial, "mode": mode, "error": "row not hoverable"})
                    print(f"PERF-HOVER-CLICK trial={trial} mode={mode} error=row_not_hoverable", flush=True)
                    continue
                time.sleep(args.dwell_ms / 1000)  # test script: the pointer rests on the row
            # The first frame: what the commit carrying the switch shows of each page (debug.workspace_switch).
            bench.rpc("debug.workspace_switch", {"action": "start"})
            started = time.perf_counter()
            bench.app.action("goToWorkspace", workspace=target)
            shown_at = (time.perf_counter() - started) * 1000
            def content():
                hibernated = set(bench.hibernation().get("hibernated") or [])
                return all(bench.live(t, hibernated) for t in tabs)
            done = wait_for(content, 20, 0.03)
            content_ms = (time.perf_counter() - started) * 1000 if done else None
            switches = bench.rpc("debug.workspace_switch", {"action": "stop"}).get("switches") or []
            first = switches[-1] if switches else {}
            entry = {"trial": trial, "mode": mode, "select_rtt_ms": round(shown_at, 2),
                     "content_ms": round(content_ms, 1) if content_ms else None,
                     "first_frame": {k: first.get(k) for k in ("pages", "pages_placeholder", "pages_loading", "commit_ms",
                                                               "late_vsyncs", "refresh_ms")},
                     # Every shown page shows its loaded content in the switch's first frame (None: no switch read).
                     "first_frame_content": (first.get("pages", 0) > 0 and not first.get("pages_placeholder")
                                             and not first.get("pages_loading")) if "pages" in first else None}
            if not done:
                # Why no content: each page's phase and what it answers now.
                entry["diag"] = bench.diagnose(f"click-{trial}-{mode}-no-content", tabs)
                entry["answers"] = {t: bench.rpc("browser.page.eval", {"tab": t, "script": "document.readyState"}, timeout=5)
                                    for t in tabs}
                print(f"PERF-HOVER-CLICK-NOCONTENT {json.dumps(entry['answers'])}", flush=True)
            trials.append(entry)
            print(f"PERF-HOVER-CLICK trial={trial} mode={mode} content_ms={entry['content_ms']} "
                  f"select_rtt_ms={entry['select_rtt_ms']} first_frame_content={entry['first_frame_content']} "
                  f"first_frame={json.dumps(entry['first_frame'])}", flush=True)
    summary, first_frames = {}, {}
    for mode in ("cold", "dwell"):
        values = [t["content_ms"] for t in trials if t.get("mode") == mode and t.get("content_ms") is not None]
        summary[mode] = dist(values)
        read = [t["first_frame_content"] for t in trials if t.get("mode") == mode and t.get("first_frame_content") is not None]
        first_frames[mode] = {"n": len(read), "content": sum(read)}
    report["click"] = {"trials": trials, "summary": summary, "first_frame_content": first_frames}
    print(f"PERF-HOVER-CLICK-SUMMARY cold={json.dumps(summary['cold'])} dwell={json.dumps(summary['dwell'])} "
          f"first_frame_content={json.dumps(first_frames)}", flush=True)


def grace(bench: Bench, args, report: dict, pid: int, bundle: str, tabs: list[str], away: str, row: str,
          hoverable: bool):
    bench.hover(None)
    bench.app.action("goToWorkspace", workspace=away)
    if not wait_for(lambda: bench.asleep(tabs), args.sleep_wait_s, 1):
        report["grace"] = {"error": "pages did not hibernate", "diag": bench.diagnose("grace", tabs)}
        print("PERF-HOVER-GRACE error=not_hibernated", flush=True)
        return
    time.sleep(5)  # test script: renderers of the discarded pages exit
    asleep = bm.sample(pid, bundle, "asleep", 1)
    if not hoverable or not str(bench.hover_row(row).get("row_hovered") or "").endswith(row):
        report["grace"] = {"error": "row not hoverable"}
        print("PERF-HOVER-GRACE error=row_not_hoverable", flush=True)
        return
    time.sleep(args.dwell_ms / 1000)  # test script: the pointer rests on the row
    bench.hover(None)
    woke = wait_for(lambda: not bench.asleep(tabs), 20, 0.1)
    time.sleep(3)  # test script: the woken pages load
    awake = bm.sample(pid, bundle, "woken", 1)
    back = wait_for(lambda: bench.asleep(tabs), GRACE_S + args.grace_slack_s, 1)
    time.sleep(5)  # test script: renderers of the discarded pages exit
    again = bm.sample(pid, bundle, "after_grace", 1)
    result = {"woke": bool(woke), "hibernated_again": bool(back),
              "footprint_mb": {"asleep": asleep["total_footprint_mb"], "woken": awake["total_footprint_mb"],
                               "after_grace": again["total_footprint_mb"]}}
    report["grace"] = result
    print(f"PERF-HOVER-GRACE woke={result['woke']} hibernated_again={result['hibernated_again']} "
          f"footprint_mb={json.dumps(result['footprint_mb'])}", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--app", required=True)
    parser.add_argument("--engine", default="webkit", choices=["webkit", "chromium"])
    parser.add_argument("--workspaces", type=int, default=40)
    parser.add_argument("--crossings", type=int, default=200)
    parser.add_argument("--hz", type=float, default=120)
    parser.add_argument("--panes", type=int, default=2)
    parser.add_argument("--trials", type=int, default=5)
    parser.add_argument("--dwell-ms", type=float, default=150)
    parser.add_argument("--sleep-wait-s", type=float, default=150)
    parser.add_argument("--grace-slack-s", type=float, default=30)
    parser.add_argument("--phases", default="sweep,click,grace")
    # The arm's name in the report (the fleet entry runs the base build as "off" and the head as "on").
    parser.add_argument("--label", default="on")
    parser.add_argument("--out")
    # A directory: record a Time Profiler trace of the app over the sweep and print its heaviest main-thread frames.
    parser.add_argument("--profile")
    # Refresh rate of a virtual main display made before the launch (a 60 Hz mini measures at 120 Hz); 0: the host's own.
    parser.add_argument("--vdisplay", type=float, default=0)
    # Milliseconds (4 or more): sample the main thread's stack in every turn over this during the sweep (debug.hangs).
    parser.add_argument("--stalls", type=float, default=0)
    # browser.wakeTabsOnHover (hover preload, off by default in the app): 1 turns it on for this launch, 0 leaves it off.
    parser.add_argument("--wake-on-hover", type=int, default=1, choices=[0, 1])
    args = parser.parse_args()
    phases = set(args.phases.split(","))
    # Hidden pages discard after 0.5 min (a timeout written, so the hover may restore them) and freeze after 5 s.
    config = {"browser": {"hibernation": 0.5, "freezeHiddenTabs": 5, "wakeTabsOnHover": bool(args.wake_on_hover)}}
    bundle = os.path.realpath(args.app)
    signal.signal(signal.SIGTERM, bm.interrupted)
    bp.wipe_state(bundle)
    vdisplay, ready = None, None
    if args.vdisplay:
        vdisplay, ready = start_vdisplay(args.vdisplay, tempfile.mkdtemp(prefix="hover-vdisplay-"))
        print(f"PERF-HOVER-VDISPLAY hz={args.vdisplay} {ready}", flush=True)
    pid, sock, scratch = bm.launch(bundle, config, {"CMUX_NEXT_HANG_THRESHOLD_MS": str(int(args.stalls))} if args.stalls else None)
    app = bm.App(bundle, sock)
    bench = Bench(sock, app, pid)
    sites = Sites(args.engine)
    report = {"app": bundle, "engine": args.engine, "label": args.label, "config": config, "vdisplay": ready}
    print(f"PERF-HOVER-ARM label={args.label}", flush=True)
    try:
        # The workspace the bench shows while the others are hidden, then the target right after it, so the
        # target's row is near the top of the sidebar (a select of the first scrolls to the top).
        home, _ = bench.open_workspace(args.engine, [sites.next("home")])
        target, target_tabs = bench.open_workspace(args.engine, [sites.next(f"t{i}") for i in range(args.panes)])
        sweep_tabs, sweep_workspaces = [], []
        if "sweep" in phases:
            for index in range(args.workspaces):
                workspace, tabs = bench.open_workspace(args.engine, [sites.next(f"s{index}")])
                sweep_tabs += tabs
                sweep_workspaces += [workspace] if workspace else []
        bench.hover(None)
        bench.app.action("goToWorkspace", workspace=home)
        report["target"] = {"workspace": target, "tabs": target_tabs}
        # Every bench page must exist in the app before anything is timed: a page that never mounted cannot sleep.
        setup = bench.diagnose("setup", target_tabs + sweep_tabs)
        report["setup"] = setup
        if any(state.startswith("no_page") for state in setup["states"]):
            print("PERF-HOVER-SETUP invalid=pages_not_mounted", flush=True)
            raise SystemExit(3)
        # Which rows the pointer really hovers, found once now, while every page is still live: a probe step that
        # rests past the dwell then wakes nothing, and any hover grace it starts (30 s) ends long before the settle
        # wait below. The pointer aims at each row as drawn when it moves, so a later scroll does not matter.
        keys = bench.row_keys(bench.titles)
        report["row_keys"] = {"mapped": len(keys), "workspaces": len(bench.titles), "by": bench.mapped_by}
        print(f"PERF-HOVER-ROWKEYS mapped={len(keys)}/{len(bench.titles)} by={bench.mapped_by} sample={json.dumps(dict(list(keys.items())[:2]))}",
              flush=True)
        if len(keys) < len(bench.titles):
            print("PERF-HOVER-SETUP invalid=rows_not_mapped", flush=True)
            raise SystemExit(3)
        # The pointer names rows by their sidebar row id; actions keep the daemon id (target, home).
        target_row = keys.get(target) if target else None
        sweep_rows = [keys[w] for w in sweep_workspaces]
        kept, refused = bench.hoverable(([target_row] if target_row else []) + sweep_rows)
        why = (refused[0]["reply"].get("why") if refused else None) or {}
        if not kept and isinstance(why, dict) and (why.get("presentation") != "shown" or why.get("list_hidden")):
            # The window opened with its sidebar hidden (a narrow fleet display): show it, then look again.
            print(f"PERF-HOVER-ROWS sidebar_hidden why={json.dumps(why)}", flush=True)
            report["sidebar_shown_by_bench"] = bench.app.action("toggleSidebar")
            kept, refused = bench.hoverable(([target_row] if target_row else []) + sweep_rows)
        target_hoverable = bool(target_row) and target_row in kept
        report["rows_hoverable"] = len(kept)
        report["target_row_hoverable"] = target_hoverable
        report["rows_refused"] = refused[:5]
        print(f"PERF-HOVER-ROWS hoverable={len(kept)} refused={len(refused)} target={target_hoverable} "
              f"first_refused={json.dumps(refused[:2])}", flush=True)
        if "sweep" in phases:
            # Every swept page frozen or hibernated first, so a wake would count. The planner discards a few
            # pages per pass after the 30 s timeout: wait in proportion to the page count.
            def settled():
                h = bench.hibernation()
                return set(sweep_tabs) <= set(h.get("hibernated") or []) | set(h.get("frozen") or [])
            wait_s = 30 + 2.5 * (len(sweep_tabs) + len(target_tabs)) + 30
            report["sweep_pages_settled"] = bool(wait_for(settled, wait_s, 1))
            if report["sweep_pages_settled"]:
                sweep(bench, args, report, [w for w in kept if w != target_row])
            else:
                report["sweep"] = {"error": "invalid: the swept pages did not all freeze or hibernate first",
                                   "diag": bench.diagnose("sweep", sweep_tabs)}
                print("PERF-HOVER-SWEEP invalid=not_settled", flush=True)
        if "click" in phases and target:
            click_trials(bench, args, report, target, target_row, target_tabs, home, target_hoverable)
        if "grace" in phases and target:
            grace(bench, args, report, pid, bundle, target_tabs, home, target_row, target_hoverable)
    finally:
        app.run("quit")
        bm.wait_gone(pid, 20)
        bm.end_bundle(bundle)
        shutil.rmtree(scratch, ignore_errors=True)
        if vdisplay:
            vdisplay.terminate()
        if args.out:
            with open(args.out, "w") as handle:
                json.dump(report, handle, indent=1)
            print(f"bench-hover-preload: wrote {args.out}")


if __name__ == "__main__":
    main()
