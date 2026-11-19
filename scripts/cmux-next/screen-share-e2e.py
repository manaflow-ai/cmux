#!/usr/bin/env python3
"""Screen Sharing end to end: open every device the way a person does, and pass only on a real picture.

For each device `cmux device list` offers to view through the device hub, this opens it with
`cmux tab new-mac-screen --device NAME --scope view` (the same `macScreen.open` the chevron, the
palette and the Screen Sharing page run, connecting at once to view one of your own devices) in the
cmux app this CLI talks to, then reads `cmux app mac-screens` until the tab shows a frame or the
time runs out. A device passes only when its tab has a frame (`has_frame`) within `--timeout`
seconds and that frame's luma variance (`luma_variance`) is above `--variance-floor`, so a black or
flat grey picture fails too. It never reads a window screenshot: the picture lives in a child
window, so a screenshot paints the pane grey even while it draws.

Each device prints one line with the furthest stage it reached:

  open refused   the app refused the open (its message follows)
  no tab         no Screen Sharing tab appeared for it
  connect card   the tab waits at Connect: this app build does not take --scope view
  no answer      the request went to the hub and the host never answered
  waiting for Allow / declined / refused / revoked / ended   the host side said so
  no link        the session was approved but the stream never connected
  no frame       the stream connected but no frame showed
  flat frame     a frame showed but it is flat (black, grey, one colour)
  ok             a frame with a real picture

Devices that are offline, have no desktop or are phones are listed as skipped and do not fail the
run (`--require-online` makes an offline one fail). Exit 0 when every opened device is ok, 1 when
one is not, 2 when the check could not run (no cmux, no device list).

Run it on a Mac signed in to cmux, against the app the `cmux` on PATH talks to:

  python3 scripts/cmux-next/screen-share-e2e.py                 # every device
  python3 scripts/cmux-next/screen-share-e2e.py --device cosmic-gray --timeout 30
  python3 scripts/cmux-next/screen-share-e2e.py --json > result.json

It opens one tab per device and closes it afterwards (`--keep-tabs` leaves them open). It sends no
input to any device and only views.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import time
from dataclasses import asdict, dataclass, field
from typing import Any, Callable

DEFAULT_TIMEOUT_S = 20.0
DEFAULT_VARIANCE_FLOOR = 25.0
POLL_S = 0.5

OK = "ok"
HUB_STAGES = {
    "idle": "connect card",
    "requesting": "no answer",
    "waiting_for_approval": "waiting for Allow",
    "declined": "declined",
    "refused": "refused",
    "revoked": "revoked",
    "ended": "ended",
}


@dataclass
class Result:
    device: str
    stage: str
    ok: bool
    detail: str = ""
    seconds: float | None = None
    tab: str | None = None
    row: dict[str, Any] = field(default_factory=dict)


Runner = Callable[[list[str]], "subprocess.CompletedProcess[str]"]


def run_cli(cmux: str, timeout: float = 30.0) -> Runner:
    def run(args: list[str]) -> subprocess.CompletedProcess[str]:
        return subprocess.run([cmux, *args], capture_output=True, text=True, timeout=timeout, check=False)

    return run


def parse_json(text: str) -> Any:
    text = text.strip()
    if not text:
        return None
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        # The last JSON line wins (a CLI may print a note first).
        for line in reversed(text.splitlines()):
            try:
                return json.loads(line)
            except json.JSONDecodeError:
                continue
    return None


def screen_rows(run: Runner) -> list[dict[str, Any]]:
    proc = run(["app", "mac-screens"])
    value = parse_json(proc.stdout)
    if isinstance(value, dict) and "result" in value and isinstance(value["result"], dict):
        value = value["result"]
    tabs = value.get("tabs") if isinstance(value, dict) else None
    return [row for row in tabs or [] if isinstance(row, dict)]


def viewable_devices(listing: Any) -> tuple[list[str], list[Result]]:
    """The device names to open, and a skipped result for each device that offers no hub screen."""
    devices = listing.get("devices", []) if isinstance(listing, dict) else []
    names: list[str] = []
    skipped: list[Result] = []
    for device in devices:
        if not isinstance(device, dict) or device.get("kind") != "computer":
            continue
        name = str(device.get("name") or device.get("id") or "?")
        screen = device.get("screen")
        if not isinstance(screen, dict):
            continue
        if screen.get("action") == "view" and screen.get("route") == "hub":
            if name not in names:
                names.append(name)
        elif screen.get("action") == "view":
            skipped.append(Result(name, f"skipped ({screen.get('route')} desktop)", True))
        else:
            skipped.append(Result(name, f"skipped ({screen.get('reason', 'no screen')})", True))
    return names, skipped


def stage_of(row: dict[str, Any] | None, floor: float) -> tuple[str, str]:
    """The furthest stage `row` (a `cmux app mac-screens` tab) shows, and a detail."""
    if row is None:
        return "no tab", ""
    hub = row.get("hub_phase")
    phase = row.get("phase")
    if row.get("has_frame"):
        if "luma_variance" not in row:
            return "flat frame", "this app build reports no luma_variance; update it"
        variance = row.get("luma_variance")
        if variance is None:
            return "no frame", "a frame showed but none was measured yet"
        if float(variance) <= floor:
            return "flat frame", f"luma variance {variance} <= {floor}"
        return OK, f"luma variance {variance}, first frame {row.get('first_frame_ms')} ms, {row.get('path') or ''}".strip(", ")
    if phase == "connected":
        return "no frame", f"connected, frames_decoded {row.get('frames_decoded')}"
    if hub in HUB_STAGES:
        reason = row.get("hub_reason") or ""
        return HUB_STAGES[hub], reason
    if hub in ("approved", "streaming", "stream_failed") or phase in ("connecting", "failed"):
        return "no link", f"hub {hub}, stream {phase}"
    if hub is None and phase is None:
        return "no answer", "no session yet"
    return "no link", f"hub {hub}, stream {phase}"


def check_device(run: Runner, name: str, timeout: float, floor: float, keep: bool,
                 clock: Callable[[], float] = time.monotonic, sleep: Callable[[float], None] = time.sleep) -> Result:
    before = {row.get("tab") for row in screen_rows(run)}
    started = clock()
    proc = run(["tab", "new-mac-screen", "--device", name, "--scope", "view"])
    if proc.returncode != 0:
        message = (proc.stderr or proc.stdout).strip().splitlines()
        return Result(name, "open refused", False, message[-1] if message else f"exit {proc.returncode}")
    row: dict[str, Any] | None = None
    tab: str | None = None
    stage, detail = "no tab", ""
    while True:
        rows = [r for r in screen_rows(run) if r.get("tab") not in before]
        if tab is None and rows:
            tab = rows[-1].get("tab")
        row = next((r for r in rows if r.get("tab") == tab), None)
        stage, detail = stage_of(row, floor)
        elapsed = clock() - started
        if stage == OK or stage in ("declined", "refused", "revoked") or elapsed >= timeout:
            break
        sleep(POLL_S)
    result = Result(name, stage, stage == OK, detail, round(clock() - started, 1), tab, row or {})
    if tab and not keep:
        closed = run(["tab", "close", str(tab)])
        if closed.returncode != 0:
            result.detail += f" (tab {tab} left open: {(closed.stderr or closed.stdout).strip()[:120]})"
    return result


def main(argv: list[str] | None = None, run: Runner | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--cmux", default="cmux", help="the cmux CLI (default: cmux on PATH)")
    parser.add_argument("--device", action="append", help="only this device name (repeatable)")
    parser.add_argument("--timeout", type=float, default=DEFAULT_TIMEOUT_S, help="seconds per device to a frame")
    parser.add_argument("--variance-floor", type=float, default=DEFAULT_VARIANCE_FLOOR,
                        help="luma variance a frame must exceed (0-16256; a flat frame is near 0)")
    parser.add_argument("--require-online", action="store_true", help="an offline device fails the run")
    parser.add_argument("--keep-tabs", action="store_true", help="leave each device's tab open")
    parser.add_argument("--json", action="store_true", help="print one JSON document")
    args = parser.parse_args(argv)
    run = run or run_cli(args.cmux)

    try:
        listing_proc = run(["device", "list", "--json"])
    except (OSError, subprocess.TimeoutExpired) as error:
        print(f"screen-share-e2e: cannot run {args.cmux}: {error}", file=sys.stderr)
        return 2
    listing = parse_json(listing_proc.stdout)
    if listing_proc.returncode != 0 or not isinstance(listing, dict):
        print(f"screen-share-e2e: `cmux device list --json` failed: {(listing_proc.stderr or listing_proc.stdout).strip()}", file=sys.stderr)
        return 2
    names, skipped = viewable_devices(listing)
    if args.device:
        wanted = {d.lower() for d in args.device}
        names = [n for n in names if n.lower() in wanted]
        skipped = [s for s in skipped if s.device.lower() in wanted]
        missing = wanted - {n.lower() for n in names} - {s.device.lower() for s in skipped}
        skipped += [Result(m, "not listed", False, "not in `cmux device list`") for m in sorted(missing)]
    if args.require_online:
        for item in skipped:
            if "offline" in item.stage:
                item.ok = False

    results = [check_device(run, name, args.timeout, args.variance_floor, args.keep_tabs) for name in names]
    results += skipped
    passed = all(r.ok for r in results) and bool(names)

    if args.json:
        print(json.dumps({"ok": passed, "devices": [asdict(r) for r in results]}, indent=2))
    else:
        width = max([len(r.device) for r in results] + [6])
        for r in results:
            mark = "PASS" if r.ok else "FAIL"
            took = f" {r.seconds}s" if r.seconds is not None else ""
            print(f"{mark}  {r.device:<{width}}  {r.stage}{took}{'  ' + r.detail if r.detail else ''}")
        if not names:
            print("no device offers a screen to view: sign in to cmux on another Mac or Linux desktop")
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
