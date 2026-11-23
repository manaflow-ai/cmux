#!/usr/bin/env python3
"""cmux Mac Screen against macOS Screen Sharing on the same two Macs: the before/after numbers for
every screen-share change (design: the screen-share-under-100ms page, piece 0).

The one command, run from any machine that reaches both Macs with `reach NAME CMD` (or ssh):

  screen-share-vs.py run --host SHARED_MAC --viewer VIEWING_MAC --host-ip SHARED_MAC_LAN_IP \
      --tools ./tools --label after --cua-vnc PATH/cua-vnc \
      --vnc-user USER --vnc-password-file PATH_ON_VIEWING_MAC --out after.jsonl
  screen-share-vs.py compare before.jsonl after.jsonl

`--tools DIR` is a `tools/` folder built at your branch's head, with nothing compiled on the Macs:

  cmux-ci run --class exclusive --measurement --label measure \
      --script scripts/measure/screen-stream-eval.sh --ref "$(git rev-parse HEAD)" \
      --arg=tools-only=1 --artifact artifacts/screen-stream-eval/tools.tar.gz
  tar -xzf tools.tar.gz        # tools/cmux-rd, tools/cmux-rd-marker, tools/screen-eval-ocr, tools/rev

It installs tools/cmux-rd on both Macs (the host's `serve` and the viewer's `bench`),
tools/cmux-rd-marker on the shared Mac and tools/screen-eval-ocr on the viewing Mac. For the
before numbers run the same command with tools built at your branch's merge base and `--label
before`. `--bin FILE` (a macOS arm64 `cmux-rd` with the default features, e.g. from `cmux-ci
build`) and `--marker-src mac-marker/main.swift` (built with swiftc on the shared Mac) still work
in place of --tools; without screen-eval-ocr the text error is null. Use the shared Mac's LAN
address for --host-ip: the RFB leg needs port 5900, which a tailnet may block.

It prints the budget table, one row per stage, p50 / p95 in ms, cmux and Apple side by side,
then received Mbps and motion quality, and writes it as a {"budget": ...} JSON line to --out:

  row         from, to                                     cmux today (until the stage ledger)
  Input       viewer key down -> host inject               up + inject
  Screen      inject -> ScreenCaptureKit display time      draw
  Capture     display time -> encode start                 sck + gate
  Encode      encode start -> bitstream                    encode
  Send        bitstream -> last datagram on the wire       send
  Network     wire -> last shard received                  down (it also holds reassembly)
  Reassembly  last shard -> frame released                 null: the bench stamps a frame complete
                                                           and releases it in one step
  Decode      released -> decoded                          decode
  Present     decoded -> on screen                         null, or with --presented-* the
                                                           presented total minus the decoded total
  Total       viewer key down -> on screen                 to the decoded frame (sent -> decoded);
                                                           with --presented-* to the presented frame

Each stage's p50 and p95 are over per-sample sums (a sample counts only when every part is
known), so the stages do not add up to Total exactly. The mapping uses the host's
CMUX_RD_TIMING_LOG, whose `release_us` is the frame's t_capture_us under another name: it is
stamped at encode start, not at capture or release, so it is the encode start for gate and encode
and the key that joins a log frame to the bench's `capture_us`. When a sample carries the per-frame
stage ledger (schema cmux.rd-stage-ledger/1: host display_us, encode_start_us,
bitstream_ready_us, first/last_datagram_sent_us; viewer first/last_shard_us, released_us,
decoded_us, presented_us converted to the host clock; input_sent_us, inject_us), every row reads
the ledger instead and a missing field stays null, never zero.

Total ends at the presented frame only with a visible viewer pane on the viewing Mac (the Mac
Screen pane of cmux NEXT showing the shared Mac's marker): pass its --presented-pid,
--presented-window, --presented-origin, --presented-cell and --presented-at (capture pixels;
`screen-eval-marker-locate` finds them) and the viewer runs `cmux-rd observe` against it (src/mac/
observe.rs: CGEventPostToPid to the ScreenCaptureKit display timestamp of the frame whose marker
changed). The bench viewer has no window on macOS, so without them Total ends at decode.

`--app-viewer APP` finds that pane itself, with no pointer move and no Computer Use: on the
viewing Mac it launches the cmux NEXT app bundle APP (`open -n`, foreground unless
--app-viewer-background, its control socket in automation mode, --encode-profile written to a
CMUX_NEXT_CONFIG_FILE because remote.screenSharingProfile is user-only), and over that socket
(the `cmux` CLI's) opens a full-control Mac Screen pane to the host (`debug.device_hub connect`),
waits for its first frame (`debug.mac_screen state`: window_pid, window_id, transport), finds the
marker in it (`screencapture -D 1` + screen-eval-marker-locate from --tools), runs observe, reads
the app's own stage ledger from its log (`stage ledger:`), and ends the session and the app it
launched. The app's session goes through the hub to the host's sharing cmux NEXT app, not to the
bench's `cmux-rd serve`: --app-host-app APP (host) approves it and names the device, else pass
--app-host-device ID. The budget's `presented_source` says which pane Total ended at
(`app-viewer` or `presented-flags`), the Total cell's `via` the same, `app_ledger` the app's
stages, and `app_timings` the pane's own decode, glass and decode_present ms (`mac_screen.state`,
every build's read, the last 120 frames; decode_present is the viewer's Decode+Present, released
to on glass). The pane is driven through DEV-only methods, so --app-viewer needs a DEV build; a
Release app (NIGHTLY) fails at launch and says so. A NIGHTLY's own timings: `cmux app mac-screens`.

The Apple leg is a headless RFB client (the cua-vnc client, imported from --cua-vnc) on port 5900
asking only for the marker's strip. It never opens Screen Sharing.app or any window on either Mac.
The marker window is not key when the rig starts it, so before timing keys the leg clicks the
marker's gray pad once and waits for that click's update; `--apple-input click` times pad clicks
instead (they need no focus). It waits for each update in select() and reads a message only once
its first byte is in, so a timeout never leaves half a message in the stream; a message that
stops part way ends the trial (`stalled`) with what was measured so far.
Its Total is key press -> the framebuffer update showing the change (raw pixels, no decode, no
present); Apple exposes no stage times, so its other rows are null. Received Mbps and motion
quality are null for Apple too: raw RFB pixels are lossless and Apple's codec bytes reach only
Screen Sharing.app, which this harness does not open.

Motion: the fps trials run the marker with --tick --motion. cmux's received Mbps is the viewer's
video and FEC datagram bytes (average, peak second). Each trial's last decoded frame
(`bench --snapshot`) gets two quality numbers against the source, which the marker draws as a
function of its counter (read from the same frame): the frame score, the share of sampled pixels
in the moving bars that match what the source drew (1.0 = matches), and the text error, Vision OCR's
character error rate of the scrolling text panel against the lines the source drew (needs
screen-eval-ocr). Both are null when the shared Mac's marker predates `motion-geometry`.

The other tables stay as they were:

  first_frame_ms   connect start -> first decoded frame that shows the marker (p50/p95 of trials)
  key_to_frame_ms  key press sent on the viewer -> decoded frame showing its effect (p50/p95)
  fps              distinct marker values decoded per second while the marker counts every
                   display refresh over a full-screen animation (`--tick --motion`)
  rtt_ms           the link's UDP round trip (min/p50), from the clock probe

and, for cmux, where each key press's time went (host CMUX_RD_TIMING_LOG joined with the
bench's per-sample times; the two clocks are tied by an NTP-style UDP probe, min-RTT sample):

  up         viewer send -> host read the input datagram (network up + host read wait)
  inject     host read -> input injected (CGEvent)
  draw       injected -> the display showed the change (marker app + WindowServer + refresh)
  sck        display showed it -> ScreenCaptureKit handed the frame over
  gate       handed over -> encode started (`release_us`, see above)
  encode     encode
  send       encode end -> last datagram handed to the link
  down       last datagram sent -> frame complete on the viewer (network down + transfer)
  decode     frame complete -> decoded (VideoToolbox)

The cmux leg is the product's session path: `cmux-rd serve` (what `cmux rd serve` runs in
the app) and `cmux-rd bench --link 1` (the secure link, UDP direct), with the device hub's
signaling played by this script as screen-share-netem.py does.

Subcommands (each Mac gets this file and bin/ under ROOT, default ~/cmux-rd-test):
  run         the orchestrator
  compare     two result files (--out of two runs) side by side: before, after, the change
  rig         on the shared Mac, inside an app that holds Screen Recording and Accessibility
              (a terminal in cmux NEXT: `cmux workspace create -- /usr/bin/python3 ... rig`);
              serves ROOT/state/rig.sock (0700 dir) with a fixed command set
  rig-call    on the shared Mac, over SSH: one rig command, stdio bridged
  clock-serve / clock-probe   the UDP clock probe
  rfb-bench   on the viewing Mac: the macOS Screen Sharing leg
  frame-score on the viewing Mac: one decoded frame's quality against the source

`--source synthetic` needs no rig, marker app or grant, so any two Macs reached over ssh do:
the shared Mac runs `cmux-rd serve --source synthetic-still` (key trials: viewer input bumps
the generated marker) or `--source synthetic-tick` (fps trials: moving bars, the marker counts
every frame) straight from the orchestrator; only the cmux leg runs. It prints the budget table
too (marked synthetic, which `compare` shows): Apple is null with the reason, Present ends at
decode, and motion quality is null (the generated picture has no motion-geometry).

  screen-share-vs.py run --source synthetic --stacks cmux --via ssh --host A --viewer B \
      --host-ip 10.0.0.5 --bin target/release/cmux-rd --trials 5 --samples 30

The macOS Screen Sharing leg logs in with the shared Mac's account (security type 30): it reads
the user from VNC_USERNAME and the password from VNC_PASSWORD_FILE (a 0600 file on the viewing
Mac) and never from argv. Without them it is skipped and the table says so.
"""
import argparse
import contextlib
import ipaddress
import json
import os
import queue
import re
import select
import shlex
import signal
import socket
import statistics
import struct
import subprocess
import sys
import threading
import time

MONO = time.CLOCK_MONOTONIC  # the clock cmux-rd's now_ns() reads (clock.rs)
KEYSYM_A = 0x61
CELLS = 20
GUARD = (True, False, True, False)


def marker_click_at(line):
    """mac-marker's `marker-origin X,Y click-at X,Y` line -> [x, y] of its gray pad, where a click or
    scroll counts and touches no read cell (None: the line names none)."""
    words = line.split()
    if len(words) >= 4 and words[0] == "marker-origin" and words[2] == "click-at":
        x, y = words[3].split(",")
        return [int(x), int(y)]
    return None


def bench_input(kind, samples, at):
    """`cmux-rd bench`'s input flags. A click or scroll aims at AT (the marker's pad): the bench's
    own --at default, 960,600, misses the marker, which then counts nothing (every trial lost)."""
    flags = f"--input {kind} --samples {samples}"
    if kind in ("click", "scroll") and at:
        flags += f" --at {at[0]},{at[1]}"
    return flags


def motion_link(series):
    """Received Mbps for each second of a `--input none` run (video and FEC datagram bytes into
    the viewer) and the host's smoothed datagram loss (its `stats` control, computed from the
    viewer's feedback), one value a second."""
    mbps = [b["bytes"] * 8 / max(b.get("duration_ms") or 1000, 1) / 1e3 for b in series]
    loss = [(b.get("host_stats") or {}).get("loss_pct") for b in series]
    loss = [x for x in loss if x is not None]
    kbps = [(b.get("host_stats") or {}).get("kbps") for b in series]
    kbps = [x for x in kbps if x is not None]
    return {
        "mbit_per_s_peak": round(max(mbps), 2) if mbps else None,
        "mbit_per_s_series": [round(x, 2) for x in mbps],
        "loss_pct_mean": round(statistics.mean(loss), 3) if loss else None,
        "loss_pct_max": round(max(loss), 3) if loss else None,
        "target_kbps_last": kbps[-1] if kbps else None,
        "target_kbps_series": kbps,
    }


def host_frames(lines, cap_fps):
    """Where a tick run's frames went, from the host's CMUX_RD_TIMING_LOG frame lines (µs on
    the host clock): how many the host encoded a second against the cap, the gaps between
    them, how long each waited at the frame gate (damage to release) and in the encoder
    (release to encoded), and the encoder's output a second (encoded bytes, before packets and
    FEC), to set beside the controller's target (`target_kbps_series`)."""
    frames = sorted((x for x in lines if x.get("release_us") is not None),
                    key=lambda x: x["release_us"])
    if len(frames) < 2:
        return {"frames": len(frames)}
    t0 = frames[0]["release_us"]
    span_s = (frames[-1]["release_us"] - t0) / 1e6
    slot_ms = 1000.0 / max(cap_fps, 1)
    gaps = [(b["release_us"] - a["release_us"]) / 1e3 for a, b in zip(frames, frames[1:])]
    gate = [(x["release_us"] - x["damage_us"]) / 1e3 for x in frames if x.get("damage_us")]
    encode = [(x["encoded_us"] - x["release_us"]) / 1e3 for x in frames if x.get("encoded_us")]
    seconds = int(span_s) + 1
    kbps = [0.0] * seconds
    count = [0] * seconds
    for x in frames:
        s = min(int((x["release_us"] - t0) / 1e6), seconds - 1)
        kbps[s] += x.get("encoded_bytes", 0) * 8 / 1000
        count[s] += 1
    whole = int(span_s)  # the last bucket is a part second
    return {
        "frames": len(frames),
        "host_fps": round((len(frames) - 1) / max(span_s, 1e-6), 2),
        "cap_fps": cap_fps,
        "gap_ms": summary(gaps),
        "gaps_over_1_5_slots": sum(g > 1.5 * slot_ms for g in gaps),
        "missed_slots": sum(max(0, round(g / slot_ms) - 1) for g in gaps),
        "gate_wait_ms": summary(gate),
        "encode_ms": summary(encode),
        "idr": sum(bool(x.get("idr")) for x in frames),
        "encoded_kbps_series": [round(k) for k in kbps[:whole]],
        "frames_series": count[:whole],
    }


def mono_ns():
    return time.clock_gettime_ns(MONO)


def pct(xs, p):
    if not xs:
        return None
    s = sorted(xs)
    return s[min(len(s) - 1, int(round(p / 100.0 * (len(s) - 1))))]


def summary(xs):
    xs = [x for x in xs if x is not None]
    if not xs:
        return None
    return {"n": len(xs), "p50": round(pct(xs, 50), 2), "p95": round(pct(xs, 95), 2),
            "min": round(min(xs), 2), "max": round(max(xs), 2)}


# --- the budget table (design: screen-share-under-100ms, "Budget per stage") ---------------

BUDGET_SCHEMA = "cmux.screen-share-budget/1"
LEDGER_SCHEMA = "cmux.rd-stage-ledger/1"
# (row, budget p50 ms, from -> to, the breakdown keys summed for it today or None)
BUDGET_ROWS = (
    ("Input", 3, "viewer key down -> host inject", ("up", "inject")),
    ("Screen", 12, "inject -> ScreenCaptureKit display time", ("draw",)),
    ("Capture", 8, "display time -> encode start", ("sck", "gate")),
    ("Encode", 8, "encode start -> bitstream", ("encode",)),
    ("Send", 8, "bitstream -> last datagram on the wire", ("send",)),
    ("Network", 2, "wire -> last shard received", ("down",)),
    ("Reassembly", 1, "last shard -> frame released", None),
    ("Decode", 5, "released -> decoded", ("decode",)),
    ("Present", 10, "decoded -> on screen", None),
    ("Total", 57, "viewer key down -> on screen", ("total",)),
)
# Each row from the stage ledger: (end field, start field), all on the host clock in µs.
LEDGER_ROWS = {
    "Input": ("inject_us", "input_sent_us"),
    "Screen": ("display_us", "inject_us"),
    "Capture": ("encode_start_us", "display_us"),
    "Encode": ("bitstream_ready_us", "encode_start_us"),
    "Send": ("last_datagram_sent_us", "bitstream_ready_us"),
    "Network": ("last_shard_us", "last_datagram_sent_us"),
    "Reassembly": ("released_us", "last_shard_us"),
    "Decode": ("decoded_us", "released_us"),
    "Present": ("presented_us", "decoded_us"),
    "Total": ("presented_us", "input_sent_us"),
}
WHY_LEDGER = "needs the per-frame stage ledger (cmux.rd-stage-ledger/1), not in this build"
WHY_CMUX = {
    "Reassembly": "not split today: the bench stamps a frame complete and releases it in one step, "
                  "so Network holds it; " + WHY_LEDGER,
    "Present": "the bench viewer has no window on macOS (it ends at decode); pass --app-viewer (the "
               "cmux NEXT app's Mac Screen pane) or --presented-* for a visible viewer pane, or " + WHY_LEDGER,
}
WHY_SYNTHETIC_PRESENT = ("--source synthetic: the bench viewer has no window on macOS (it ends at "
                         "decode) and a viewer pane needs the marker app; " + WHY_LEDGER)
WHY_APPLE = {
    "stage": "Apple exposes no stage times; only its total is measured",
    "Present": "the Apple leg is a headless RFB client: no window is opened (never Screen Sharing.app)",
    "mbps": "the headless RFB client asks for raw pixels of the marker strip; Apple's codec bytes "
            "reach only Screen Sharing.app",
    "quality": "raw RFB pixels are lossless; Apple's codec quality shows only in Screen Sharing.app",
}


def stat(xs):
    """p50/p95/n over the known values, or None."""
    xs = [x for x in xs if x is not None]
    if not xs:
        return None
    return {"p50": round(pct(xs, 50), 2), "p95": round(pct(xs, 95), 2), "n": len(xs)}


def sample_sums(rows, keys):
    """Per sample, the sum of KEYS; a sample with any of them unknown is left out."""
    out = []
    for row in rows:
        vals = [row.get(k) for k in keys]
        if all(v is not None for v in vals):
            out.append(sum(vals))
    return out


def ledger_stages(ledger):
    """One frame's stage ledger as {row: ms}; a stage with a missing field is absent, not zero."""
    if not isinstance(ledger, dict) or ledger.get("schema") != LEDGER_SCHEMA:
        return {}
    out = {}
    for row, (end, start) in LEDGER_ROWS.items():
        if ledger.get(end) is not None and ledger.get(start) is not None:
            out[row] = (ledger[end] - ledger[start]) / 1000.0
    return out


def summary_stages(summary):
    """A bench's run stage ledger summary (`stage_ledger`, schema cmux.rd-stage-ledger/1) as
    {row: {"p50", "p95", "n"}} for the stages it measured; {} for anything else."""
    if not isinstance(summary, dict) or summary.get("schema") != LEDGER_SCHEMA:
        return {}
    out = {}
    for st in summary.get("stages") or []:
        if not isinstance(st, dict) or not isinstance(st.get("n"), int) or st["n"] <= 0:
            continue
        if st.get("p50_ms") is None or st.get("p95_ms") is None:
            continue
        out[st.get("stage")] = {"p50": round(st["p50_ms"], 2), "p95": round(st["p95_ms"], 2),
                                "n": st["n"]}
    return out


def from_summaries(row, summaries):
    """ROW from the trials' run summaries: the trial with the most frames for it (percentiles of
    separate trials do not pool), or None. Never Total: the summary's runs display time ->
    presented, not key press -> frame."""
    if row == "Total":
        return None
    cells = [s[row] for s in (summary_stages(x) for x in summaries or []) if row in s]
    if not cells:
        return None
    best = max(cells, key=lambda c: c["n"])
    return dict(best, source="ledger", of="run summary: the trial with the most frames",
                trials=len(cells))


def null(why):
    return {"null": why}


PRESENTED_KINDS = {
    "app-viewer": "the cmux NEXT app's Mac Screen pane (--app-viewer), opened through its control socket",
    "presented-flags": "a viewer pane named by --presented-pid/--presented-window",
}


# The Mac Screen pane's own frame timings (`mac_screen.state`, MacScreenStateControl), each
# {count, p50, p95, max} over its last APP_TIMING_WINDOW frames.
APP_TIMING_FIELDS = ("decode_ms", "glass_ms", "decode_present_ms", "present_ms", "frame_interval_ms")
APP_TIMING_WINDOW = 120
# The pane-timings read every build registers (Release too: `cmux app mac-screens`,
# MacScreenStateControl.releaseMethods); debug.mac_screen is DEV only.
APP_STATE_METHOD = "mac_screen.state"


def presented_source(kind, **fields):
    """Which pane the presented leg read (budget `presented_source`): KIND (PRESENTED_KINDS) and
    the pid, CGWindow id and marker coordinates it used."""
    if kind not in PRESENTED_KINDS:
        raise ValueError(f"unknown presented source {kind!r}")
    return {"kind": kind, "what": PRESENTED_KINDS[kind], **fields}


def cmux_cells(rows, ledgers, presented, synthetic=False, summaries=None, presented_via=None):
    """The cmux column: {row: cell}. ROWS are the key-to-frame breakdown rows, LEDGERS per-sample
    ledger stage dicts (ledger_stages), PRESENTED cmux-rd observe's latencies in ms or None,
    SUMMARIES the trials' run stage ledgers (the bench's `stage_ledger`), read for a row no
    per-sample ledger fills. PRESENTED_VIA (a presented_source kind) labels the Total it ends."""
    cells = {}
    decoded_total = stat(sample_sums(rows, ("total",)))
    pres = stat(presented or [])
    for row, _, _, keys in BUDGET_ROWS:
        from_ledger = stat([s.get(row) for s in ledgers])
        from_summary = None if from_ledger else from_summaries(row, summaries)
        if from_ledger:
            cells[row] = dict(from_ledger, source="ledger")
        elif from_summary:
            cells[row] = from_summary
        elif row == "Total" and pres:
            cells[row] = dict(pres, source="cmux-rd observe", to="presented",
                              **({"via": presented_via} if presented_via else {}))
        elif row == "Total" and decoded_total:
            cells[row] = dict(decoded_total, source="total", to="decoded")
        elif row == "Present" and pres and decoded_total:
            cells[row] = {"p50": round(pres["p50"] - decoded_total["p50"], 2),
                          "p95": round(pres["p95"] - decoded_total["p95"], 2),
                          "n": min(pres["n"], decoded_total["n"]),
                          "source": "presented total minus decoded total (separate samples)",
                          "derived": True}
        elif keys:
            s = stat(sample_sums(rows, keys))
            cells[row] = dict(s, source=" + ".join(keys)) if s else null(
                "no samples: the host timing log had no frame for any key press")
        else:
            why = (WHY_SYNTHETIC_PRESENT if synthetic and row == "Present"
                   else WHY_CMUX.get(row, WHY_LEDGER))
            cells[row] = null(why)
    return cells


def apple_cells(g2g, why_skipped=None):
    cells = {}
    for row, _, _, _ in BUDGET_ROWS:
        if why_skipped:
            cells[row] = null(why_skipped)
        elif row == "Total":
            s = stat(g2g or [])
            cells[row] = dict(s, source="RFB key -> update", to="RFB update") if s else null(
                "no key press reached a framebuffer update")
        else:
            cells[row] = null(WHY_APPLE.get(row, WHY_APPLE["stage"]))
    return cells


def motion_mbps(motion_rows):
    """Received Mbps under motion for cmux: run average and peak second, or None."""
    m = [r for r in motion_rows if r.get("mbit_per_s") is not None]
    if not m:
        return None
    peak = [r["mbit_per_s_peak"] for r in m if r.get("mbit_per_s_peak") is not None]
    return {"avg": round(statistics.mean(r["mbit_per_s"] for r in m), 2),
            "peak": round(max(peak), 2) if peak else None, "n": len(m)}


def quality_summary(scores, why_none):
    """The motion quality numbers from frame-score results, each null with a reason when absent."""
    frame = [s["frame_score"] for s in scores if s.get("frame_score") is not None]
    text = [s["text_cer"] for s in scores if s.get("text_cer") is not None]
    text_why = next((s.get("text_null") for s in scores if s.get("text_null")), None)
    frame_why = next((s.get("frame_null") for s in scores if s.get("frame_null")), None)
    return {
        "frame_score": ({"p50": round(pct(frame, 50), 4), "min": round(min(frame), 4), "n": len(frame)}
                        if frame else null(frame_why or why_none)),
        "text_cer": ({"p50": round(pct(text, 50), 4), "max": round(max(text), 4), "n": len(text)}
                     if text else null(text_why or frame_why or why_none)),
    }


def build_budget(cmux=None, apple=None, label=None, rev=None, link=None, rtt=None, source=None,
                 cmux_input="key", host=None, viewer=None, host_args=None, viewer_args=None,
                 encode_profile=None):
    """The budget record. CMUX: {"rows", "ledgers", "presented", "motion_rows", "scores",
    "quality_null"} or {"skipped": why}; APPLE: {"g2g"} or {"skipped": why}."""
    cmux = cmux or {"skipped": "not run (--stacks)"}
    p_source = cmux.get("presented_source")
    if cmux.get("skipped"):
        p_source = null(cmux["skipped"])
    elif not p_source:
        p_source = null("no --app-viewer or --presented-* flags")
    elif cmux.get("presented") is None and "null" not in p_source:
        p_source = dict(p_source, null=p_source.get("error") or "cmux-rd observe gave no complete run")
    app_ledger = cmux.get("app_ledger")
    if app_ledger and app_ledger.get("ledger"):
        app_ledger = {"stages": summary_stages(app_ledger["ledger"]), "lines": app_ledger.get("lines"),
                      "of": "the app viewer's own stage ledger (log `stage ledger:`), the session so far"}
    elif not app_ledger:
        app_ledger = null(cmux.get("skipped") or "no --app-viewer run")
    app_timings = cmux.get("app_timings")
    if not app_timings:
        app_timings = null(cmux.get("skipped") or "no --app-viewer run")
    elif "null" not in app_timings:
        app_timings = dict(app_timings, of="the app pane's own timings (mac_screen.state), last "
                           f"{APP_TIMING_WINDOW} frames: decode_present = released to on glass")
    apple = apple or {"skipped": "not run (--stacks)"}
    if cmux.get("skipped"):
        c_cells = {row: null(cmux["skipped"]) for row, _, _, _ in BUDGET_ROWS}
        c_mbps = null(cmux["skipped"])
        c_quality = {"frame_score": null(cmux["skipped"]), "text_cer": null(cmux["skipped"])}
    else:
        c_cells = cmux_cells(cmux.get("rows") or [], cmux.get("ledgers") or [], cmux.get("presented"),
                             synthetic=source == "synthetic", summaries=cmux.get("summaries"),
                             presented_via=p_source.get("kind") if "null" not in p_source else None)
        c_mbps = motion_mbps(cmux.get("motion_rows") or []) or null("no motion trial finished")
        c_quality = quality_summary(cmux.get("scores") or [],
                                    cmux.get("quality_null") or "no motion trial finished")
    why_apple = apple.get("skipped")
    rows = []
    for row, budget, span, _ in BUDGET_ROWS:
        rows.append({"row": row, "budget_ms": budget, "span": span, "cmux": c_cells[row],
                     "apple": apple_cells(apple.get("g2g"), why_apple)[row]})
    return {
        "schema": BUDGET_SCHEMA, "label": label, "rev": rev, "link": link, "rtt": rtt,
        "source": source or "screen", "rows": rows,
        # What the cmux leg timed (key, click or scroll) and on which two Macs: a pair of one
        # Mac's names is loopback, whatever the link label says.
        "input": cmux_input, "host": host, "viewer": viewer,
        # The profile the cmux leg asked for (--encode-profile; null: none sent, so the host ran standard).
        "encode_profile": encode_profile,
        "host_args": list(host_args or []), "viewer_args": list(viewer_args or []),
        "presented_source": p_source, "app_ledger": app_ledger, "app_timings": app_timings,
        "mbps": {"cmux": c_mbps, "apple": null(why_apple or WHY_APPLE["mbps"])},
        "quality": {"cmux": c_quality,
                    "apple": {"frame_score": null(why_apple or WHY_APPLE["quality"]),
                              "text_cer": null(why_apple or WHY_APPLE["quality"])}},
    }


def cell_text(cell, keys=("p50", "p95")):
    if not cell or "null" in cell:
        return "null"
    vals = []
    for k in keys:
        v = cell.get(k)
        vals.append("-" if v is None else f"{v:g}")
    text = " / ".join(vals)
    if cell.get("to") and cell["to"] != "presented":
        text += f" (to {cell['to']})"
    if cell.get("derived"):
        text += " (est)"
    return text


def args_text(b):
    """The run's extra cmux-rd flags (`run --host-arg`, `--viewer-arg`), for a table header."""
    return (f"host args: {' '.join(b.get('host_args') or []) or '(none)'}; "
            f"viewer args: {' '.join(b.get('viewer_args') or []) or '(none)'}")


def format_budget(b):
    """The table as text lines; every null cell is footnoted with its reason."""
    notes = {}

    def show(cell, keys=("p50", "p95")):
        text = cell_text(cell, keys)
        if text == "null":
            why = cell["null"] if cell else "no value"
            n = notes.setdefault(why, len(notes) + 1)
            text = f"null [{n}]"
        return text

    title = "budget table (ms, p50 / p95)"
    if b.get("label") or b.get("rev"):
        title += f": {b.get('label') or ''} {('@ ' + b['rev'][:12]) if b.get('rev') else ''}".rstrip()
    if b.get("source") == "synthetic":
        title += " (--source synthetic)"
    lines = [title]
    if b.get("host_args") or b.get("viewer_args"):
        lines.append("  " + args_text(b))
    lines.append(f"  {'row':<11} {'budget':>6}  {'cmux':<26} {'Apple Screen Sharing':<26} from, to")
    for r in b["rows"]:
        lines.append(f"  {r['row']:<11} {r['budget_ms']:>6}  {show(r['cmux']):<26} "
                     f"{show(r['apple']):<26} {r['span']}")
    lines.append(f"  {'Mbps':<11} {'':>6}  {show(b['mbps']['cmux'], ('avg', 'peak')):<26} "
                 f"{show(b['mbps']['apple'], ('avg', 'peak')):<26} received under motion, avg / peak 1 s")
    q = b["quality"]
    lines.append(f"  {'frame score':<11} {'':>6}  {show(q['cmux']['frame_score'], ('p50', 'min')):<26} "
                 f"{show(q['apple']['frame_score'], ('p50', 'min')):<26} "
                 "motion frame vs source, 1 = match, p50 / min")
    lines.append(f"  {'text error':<11} {'':>6}  {show(q['cmux']['text_cer'], ('p50', 'max')):<26} "
                 f"{show(q['apple']['text_cer'], ('p50', 'max')):<26} "
                 "OCR error of scrolling text, p50 / max")
    sources = [f"{r['row']}={r['cmux']['source']}" for r in b["rows"]
               if r["cmux"] and "null" not in r["cmux"] and r["cmux"].get("source")]
    if sources:
        lines.append("  cmux sources: " + ", ".join(sources))
    ps = b.get("presented_source") or {}
    if ps.get("kind"):
        where = ", ".join(f"{k} {ps[k]}" for k in ("pid", "window", "transport", "path") if ps.get(k))
        lines.append(f"  presented via {ps['kind']}: {ps['what']}" + (f" ({where})" if where else "")
                     + (f"; no Total from it: {ps['null']}" if ps.get("null") else ""))
    al = b.get("app_ledger") or {}
    if al.get("stages"):
        lines.append("  app viewer ledger: " + ", ".join(
            f"{row} {c['p50']:g}/{c['p95']:g} (n {c['n']})" for row, c in al["stages"].items()))
    at = b.get("app_timings") or {}
    if at.get("decode_present_ms"):
        lines.append("  app viewer timings p50/p95: " + ", ".join(
            f"{k[:-3]} {c.get('p50', 0):g}/{c.get('p95', 0):g} (n {c.get('count')})"
            for k, c in at.items() if k in APP_TIMING_FIELDS))
    for why, n in notes.items():
        lines.append(f"  [{n}] null: {why}")
    return lines


def load_budget(path):
    """The last budget record in a result file (a --out JSON lines file, or one JSON object)."""
    with open(path, encoding="utf8") as f:
        text = f.read()
    found = None
    try:
        whole = json.loads(text)
        if isinstance(whole, dict):
            found = whole.get("budget", whole if whole.get("schema") == BUDGET_SCHEMA else None)
    except ValueError:
        for line in text.splitlines():
            line = line.strip()
            if not line.startswith("{"):
                continue
            try:
                rec = json.loads(line)
            except ValueError:
                continue
            if isinstance(rec, dict) and isinstance(rec.get("budget"), dict):
                found = rec["budget"]
    if not found or found.get("schema") != BUDGET_SCHEMA:
        raise SystemExit(f"{path}: no {BUDGET_SCHEMA} record (a `run --out` file from this script)")
    return found


def delta(before, after, key):
    if not before or not after or "null" in before or "null" in after:
        return None
    if before.get(key) is None or after.get(key) is None:
        return None
    return round(after[key] - before[key], 2)


def format_compare(before, after):
    """cmux before and after side by side, with the p50 change; Apple from the after run."""
    def name(b, default):
        bits = [b.get("label") or default]
        if b.get("rev"):
            bits.append(b["rev"][:12])
        return " @ ".join(bits) + (" (synthetic)" if b.get("source") == "synthetic" else "")

    lines = [f"budget table, {name(before, 'before')} -> {name(after, 'after')} (ms, p50 / p95)",
             f"  {'row':<11} {'budget':>6}  {'cmux before':<22} {'cmux after':<22} {'p50 change':>10}  "
             f"{'Apple (after run)':<20}"]
    if any(x.get("host_args") or x.get("viewer_args") for x in (before, after)):
        lines[1:1] = [f"  before {args_text(before)}", f"  after  {args_text(after)}"]
    rows_before = {r["row"]: r for r in before["rows"]}
    for r in after["rows"]:
        b = rows_before.get(r["row"], {})
        d = delta(b.get("cmux"), r["cmux"], "p50")
        lines.append(f"  {r['row']:<11} {r['budget_ms']:>6}  {cell_text(b.get('cmux')):<22} "
                     f"{cell_text(r['cmux']):<22} {('-' if d is None else f'{d:+g}'):>10}  "
                     f"{cell_text(r['apple']):<20}")
    extra = (("Mbps", lambda x: x["mbps"]["cmux"], ("avg", "peak"), "avg"),
             ("frame score", lambda x: x["quality"]["cmux"]["frame_score"], ("p50", "min"), "p50"),
             ("text error", lambda x: x["quality"]["cmux"]["text_cer"], ("p50", "max"), "p50"))
    for label, get, keys, key in extra:
        cb, ca = get(before), get(after)
        d = delta(cb, ca, key)
        lines.append(f"  {label:<11} {'':>6}  {cell_text(cb, keys):<22} {cell_text(ca, keys):<22} "
                     f"{('-' if d is None else f'{d:+g}'):>10}")
    return lines


def cmd_compare(args):
    before, after = load_budget(args.before), load_budget(args.after)
    if args.json:
        print(json.dumps({"before": before, "after": after}))
        return
    print("\n".join(format_compare(before, after)))


# --- motion quality: one decoded frame against the source the marker drew -------------------


def motion_line(n):
    """Line N of the marker's scrolling panel (mac-marker/main.swift motionLine)."""
    return f"row {n % 100000:05d} the quick brown fox {(n * 7) % 1000:03d}"


def motion_truth(counter, lines):
    return "\n".join(motion_line(counter + i) for i in range(lines))


def read_ppm(path):
    """(width, height, rgb bytes) of a binary 8-bit PPM, as `bench --snapshot` writes it."""
    with open(path, "rb") as f:
        data = f.read()
    fields, i = [], 0
    while len(fields) < 4:
        while i < len(data) and data[i:i + 1].isspace():
            i += 1
        j = i
        while j < len(data) and not data[j:j + 1].isspace():
            j += 1
        if j == i:
            raise ValueError(f"{path}: not a PPM")
        fields.append(data[i:j].decode("ascii"))
        i = j
    if fields[0] != "P6" or fields[3] != "255":
        raise ValueError(f"{path}: not an 8-bit binary PPM")
    w, h = int(fields[1]), int(fields[2])
    rgb = data[i + 1:i + 1 + w * h * 3]
    if len(rgb) != w * h * 3:
        raise ValueError(f"{path}: short pixel data")
    return w, h, rgb


def write_ppm_crop(path, rgb, width, rect):
    x, y, w, h = rect
    out = bytearray(f"P6\n{w} {h}\n255\n".encode())
    for row in range(y, y + h):
        o = (row * width + x) * 3
        out += rgb[o:o + w * 3]
    with open(path, "wb") as f:
        f.write(out)


def bar_rows_pt(geo):
    """The y (points) of the rows the frame score samples: the middle of the bars above and below
    the text panel."""
    top = geo["bars_top_pt"]
    px, py, pw, ph = geo["panel_pt"]
    height = geo["display_pt"][1]
    return [top + (py - top) / 2, py + ph + (height - py - ph) / 2]


def frame_score(rgb, width, height, geo, counter, edge_pt=1.5, luma_cut=70):
    """Share of sampled pixels in the moving bars whose class (bar or background) matches what the
    source drew for COUNTER; pixels within EDGE_PT of a bar edge are skipped (scaling)."""
    scale = width / geo["display_pt"][0]
    bar, period = geo["bar_pt"], geo["bar_pt"] * 2
    start = -bar + (counter * geo["step_pt"]) % period
    px, py, pw, ph = geo["panel_pt"]
    match = total = 0
    for y_pt in bar_rows_pt(geo):
        y = int(y_pt * scale)
        if not 0 <= y < height:
            continue
        for x in range(width):
            x_pt = (x + 0.5) / scale
            if px <= x_pt < px + pw and py <= y_pt < py + ph:
                continue
            rel = (x_pt - start) % period
            if min(rel, abs(rel - bar), period - rel) < edge_pt:
                continue
            o = (y * width + x) * 3
            r, g, b = rgb[o], rgb[o + 1], rgb[o + 2]
            is_bar = (r * 299 + g * 587 + b * 114) // 1000 >= luma_cut
            match += is_bar == (rel < bar)
            total += 1
    return round(match / total, 4) if total else None


def panel_rect_px(geo, width, height):
    scale = width / geo["display_pt"][0]
    x, y, w, h = (int(round(v * scale)) for v in geo["panel_pt"])
    x, y = max(0, x), max(0, y)
    return x, y, min(w, width - x), min(h, height - y)


def score_frame(path, geo, origin, cell, ocr=None):
    """The frame-score result for one snapshot: counter, frame_score, text_cer (or *_null)."""
    width, height, rgb = read_ppm(path)
    counter = read_marker_rgb(rgb, width, origin, cell)
    out = {"frame": [width, height], "counter": counter}
    if counter is None:
        out["frame_null"] = "no readable marker in the decoded frame"
        return out
    if not geo.get("tick_driven"):
        out["frame_null"] = "the marker ran without --tick, so the scene is not tied to its counter"
        return out
    out["frame_score"] = frame_score(rgb, width, height, geo, counter)
    # A lagging scene shows here: the score against the frame before, for diagnosis.
    out["frame_score_prev"] = frame_score(rgb, width, height, geo, counter - 1)
    if not ocr:
        out["text_null"] = "no screen-eval-ocr on the viewing Mac (pass --tools)"
        return out
    crop = path + ".panel.ppm"
    truth = path + ".truth.txt"
    write_ppm_crop(crop, rgb, width, panel_rect_px(geo, width, height))
    try:
        for key, n in (("text_cer", counter), ("text_cer_prev", counter - 1)):
            with open(truth, "w", encoding="utf8") as f:
                f.write(motion_truth(n, geo["lines"]) + "\n")
            p = subprocess.run([ocr, crop, crop, truth], capture_output=True, text=True, timeout=60)
            if p.returncode != 0:
                out["text_null"] = f"screen-eval-ocr failed: {p.stderr.strip()[-200:]}"
                break
            try:
                out[key] = json.loads(p.stdout).get("viewer_cer_vs_truth")
            except ValueError:
                out["text_null"] = "screen-eval-ocr printed no JSON"
                break
    finally:
        for f in (crop, truth):
            if os.path.exists(f):
                os.unlink(f)
    return out


def cmd_frame_score(args):
    try:
        out = score_frame(args.ppm, json.loads(args.geometry), tuple(args.origin), args.cell,
                          args.ocr if args.ocr and os.path.exists(args.ocr) else None)
    except (OSError, ValueError) as e:
        out = {"frame_null": f"no decoded frame: {e}"}
    finally:
        if args.delete and os.path.exists(args.ppm):
            os.unlink(args.ppm)
    print(json.dumps(out))


def motion_geometry(marker_log):
    """The marker's `motion-geometry {JSON}` line, or None (a marker that predates it)."""
    for line in marker_log.splitlines():
        if line.startswith("motion-geometry "):
            try:
                return json.loads(line[len("motion-geometry "):])
            except ValueError:
                return None
    return None


# --- marker reading (RGB framebuffer) ---------------------------------------------------


def read_marker_rgb(rgb, width, origin, cell):
    """The marker counter from an RGB framebuffer (3 bytes a pixel), or None."""
    ox, oy = origin
    y = oy + cell // 2
    bits = []
    for i in range(CELLS):
        x = ox + i * cell + cell // 2
        o = (y * width + x) * 3
        if o + 2 >= len(rgb):
            return None
        r, g, b = rgb[o], rgb[o + 1], rgb[o + 2]
        luma = (r * 299 + g * 587 + b * 114) // 1000
        if 64 < luma < 192:
            return None  # mid-gray: not a marker cell
        bits.append(luma >= 128)
    if tuple(bits[16:]) != GUARD:
        return None
    return sum(1 << i for i, on in enumerate(bits[:16]) if on)


# --- the clock probe --------------------------------------------------------------------


def cmd_clock_serve(args):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.bind((args.bind, args.port))
    print(json.dumps({"listening": s.getsockname()[1]}), flush=True)
    end = time.time() + args.seconds
    while time.time() < end:
        r, _, _ = select.select([s, sys.stdin], [], [], 0.5)
        if sys.stdin in r and not os.read(sys.stdin.fileno(), 4096):
            return  # the orchestrator went away
        if s not in r:
            continue
        data, peer = s.recvfrom(64)
        s.sendto(data[:8] + struct.pack("!Q", mono_ns()), peer)


def cmd_clock_probe(args):
    host, port = args.addr.rsplit(":", 1)
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(0.5)
    best = None
    rtts = []
    misses = 0
    for i in range(args.count):
        t0 = mono_ns()
        s.sendto(struct.pack("!Q", i), (host, int(port)))
        try:
            data, _ = s.recvfrom(64)
        except socket.timeout:
            misses += 1
            if misses >= 10 and not rtts:
                break  # nothing is answering
            continue
        t1 = mono_ns()
        if struct.unpack("!Q", data[:8])[0] != i:
            continue
        th = struct.unpack("!Q", data[8:16])[0]
        rtt = t1 - t0
        rtts.append(rtt / 1e6)
        # host clock minus viewer clock, at the midpoint of the exchange
        offset = th - (t0 + rtt // 2)
        if best is None or rtt < best[0]:
            best = (rtt, offset)
        time.sleep(args.gap_ms / 1000.0)
    if best is None:
        print(json.dumps({"error": "no clock replies"}))
        sys.exit(2)
    print(json.dumps({"offset_ns": best[1], "rtt_min_ms": best[0] / 1e6,
                      "rtt_ms": summary(rtts), "replies": len(rtts)}))


# --- the rig: the shared Mac's side, inside an app with the grants ------------------------

SERVE_FLAGS = {"--profile": ("high", "baseline"), "--codec": ("videotoolbox", "openh264")}
MARKER_FLAGS = ("--motion", "--tick", "--verbose")
# `run --host-arg` / `--viewer-arg`: the only extra flags a run passes to `cmux-rd serve` and to
# `cmux-rd bench`, checked here and again by the rig (the rig command runs on a fleet Mac). Each
# maps to the pattern of its value, or None for a switch, which is sent as `--flag 1` (cmux-rd's
# options all take a value; `--flag=0` turns a switch off).
NUMBER = r"[0-9]{1,9}"
HOST_ARGS = {"--resolution-ladder": None, "--max-qp": NUMBER, "--max-kbps": NUMBER}
VIEWER_ARGS = {"--caps": r"[a-z0-9._-]+(,[a-z0-9._-]+)*"}


def checked_args(items, allowed, what):
    """The argv for ITEMS (`--flag`, `--flag=VALUE` or `--flag VALUE`), each flag in ALLOWED
    with a value matching its pattern; anything else raises ValueError naming WHAT."""
    argv, seen = [], set()
    for item in items or []:
        if not isinstance(item, str):
            raise ValueError(f"--{what}-arg {item!r}: not a string")
        flag, sep, value = item.strip().replace(" ", "=", 1).partition("=")
        if flag not in allowed:
            raise ValueError(f"--{what}-arg {item!r}: {flag} is not allowed "
                             f"(allowed: {', '.join(sorted(allowed))})")
        if flag in seen:
            raise ValueError(f"--{what}-arg {item!r}: {flag} given twice")
        seen.add(flag)
        pattern = allowed[flag]
        if pattern is None:
            if sep and value not in ("0", "1"):
                raise ValueError(f"--{what}-arg {item!r}: {flag} is a switch (no value, or =0/=1)")
            argv += [flag, value if sep else "1"]
        elif not sep or not re.fullmatch(pattern, value):
            raise ValueError(f"--{what}-arg {item!r}: {flag} needs a value matching {pattern}")
        else:
            argv += [flag, value]
    return argv


def rig_paths(root):
    root = os.path.expanduser(root)
    return root, os.path.join(root, "bin"), os.path.join(root, "state")


def cmd_rig(args):
    root, bindir, state = rig_paths(args.root)
    os.makedirs(state, exist_ok=True)
    os.chmod(root, 0o700)
    os.chmod(state, 0o700)
    path = os.path.join(state, "rig.sock")
    if os.path.exists(path):
        os.unlink(path)
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(path)
    os.chmod(path, 0o600)
    srv.listen(4)
    procs = {}
    timing = os.path.join(state, "timing.jsonl")

    def stop(name):
        p = procs.pop(name, None)
        if p and p.poll() is None:
            p.terminate()
            try:
                p.wait(timeout=3)
            except subprocess.TimeoutExpired:
                p.kill()
                p.wait()

    def quit_rig(*_):
        for name in list(procs):
            stop(name)
        try:
            os.unlink(path)
        except OSError:
            pass
        sys.exit(0)

    signal.signal(signal.SIGTERM, quit_rig)
    signal.signal(signal.SIGHUP, quit_rig)
    print("rig ready: " + path, flush=True)
    while True:
        conn, _ = srv.accept()
        f = conn.makefile("rwb", buffering=0)
        try:
            req = json.loads(f.readline() or b"{}")
        except ValueError:
            f.close()
            conn.close()
            continue
        cmd = req.get("cmd")
        reply = {"ok": True}
        try:
            if cmd == "ping":
                reply["pid"] = os.getpid()
            elif cmd == "marker":
                stop("marker")
                flags = [x for x in req.get("flags", []) if x in MARKER_FLAGS]
                log = os.path.join(state, "marker.log")
                out = open(log, "w")
                procs["marker"] = subprocess.Popen([os.path.join(bindir, "cmux-rd-marker"), *flags],
                                                   stdout=out, stderr=out)
                deadline = time.time() + 10
                while time.time() < deadline:
                    with open(log) as lf:
                        text = lf.read()
                    if "marker-origin" in text and "stream width" in text:
                        break
                    time.sleep(0.05)
                for line in text.splitlines():
                    if line.startswith("marker-origin "):
                        x, y = line.split()[1].split(",")
                        reply["origin"] = [int(x), int(y)]
                        at = marker_click_at(line)
                        if at:
                            reply["at"] = at
                    if "stream width" in line:
                        reply["geometry"] = line
                if "origin" not in reply:
                    reply = {"ok": False, "error": "marker printed no origin", "log": text[-400:]}
            elif cmd == "serve":
                stop("serve")
                argv = [os.path.join(bindir, "cmux-rd"), "serve"]
                for k, v in (req.get("flags") or {}).items():
                    if k in SERVE_FLAGS and v in SERVE_FLAGS[k]:
                        argv += [k, v]
                argv += checked_args(req.get("args"), HOST_ARGS, "host")  # refused, not dropped
                bind = req.get("link_bind")
                if bind:
                    socket.inet_aton(bind)  # an IPv4 literal, or this request fails
                    argv += ["--link-bind", f"{bind}:0"]
                env = dict(os.environ)
                if req.get("timing"):
                    open(timing, "w").close()
                    env["CMUX_RD_TIMING_LOG"] = timing
                err = open(os.path.join(state, "serve.err"), "w")
                p = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=err, env=env)
                procs["serve"] = p
                bridge(conn, p)
                stop("serve")
                f.close()
                conn.close()
                continue
            elif cmd == "timing":
                lines = []
                if os.path.exists(timing):
                    with open(timing) as tf:
                        lines = [json.loads(x) for x in tf if x.strip()]
                    open(timing, "w").close()
                reply["lines"] = lines
            elif cmd == "stop":
                for name in list(procs):
                    stop(name)
            elif cmd == "quit":
                f.write((json.dumps(reply) + "\n").encode())
                f.close()
                conn.close()
                quit_rig()
            else:
                reply = {"ok": False, "error": "unknown command"}
        except Exception as e:  # noqa: BLE001 - one bad request never ends the rig
            reply = {"ok": False, "error": repr(e)}
        try:
            f.write((json.dumps(reply) + "\n").encode())
        except OSError:
            pass
        f.close()
        conn.close()


def bridge(conn, p):
    """Socket <-> process stdio until either side ends."""
    out = p.stdout.fileno()
    sock = conn.fileno()
    while p.poll() is None:
        r, _, _ = select.select([sock, out], [], [], 0.5)
        if sock in r:
            data = os.read(sock, 65536)
            if not data:
                try:
                    p.stdin.write(b'{"stop":true}\n')
                    p.stdin.flush()
                except OSError:
                    pass
                break
            p.stdin.write(data)
            p.stdin.flush()
        if out in r:
            data = os.read(out, 65536)
            if not data:
                break
            conn.sendall(data)


def cmd_rig_call(args):
    _, _, state = rig_paths(args.root)
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(os.path.join(state, "rig.sock"))
    s.sendall((args.request + "\n").encode())
    if json.loads(args.request).get("cmd") != "serve":
        data = b""
        while not data.endswith(b"\n"):
            chunk = s.recv(1 << 20)
            if not chunk:
                break
            data += chunk
        sys.stdout.write(data.decode())
        return
    inp = sys.stdin.fileno()
    while True:
        r, _, _ = select.select([inp, s], [], [])
        if inp in r:
            data = os.read(inp, 65536)
            if not data:
                s.shutdown(socket.SHUT_WR)
                inp = -1
            else:
                s.sendall(data)
        if s in r:
            data = s.recv(65536)
            if not data:
                return
            os.write(1, data)
        if inp == -1:
            # stdin closed: drain the rest of the host's output, then end
            while True:
                data = s.recv(65536)
                if not data:
                    return
                os.write(1, data)


# --- the cmux NEXT app as the viewer (viewing Mac; `run --app-viewer`) ---------------------

APP_CHANNELS = (("com.cmuxterm.app.nightly", "nightly"), ("com.cmuxterm.app.rc", "rc"),
                ("com.cmuxterm.app.staging", "staging"))
APP_DEBUG_BUNDLE = "com.cmuxterm.app.debug"
APP_ENV = re.compile(r"CMUX_[A-Z0-9_]+=[^\n]*")
LEDGER_LINE = "stage ledger: "
APP_PROFILE = {"standard": "balanced", "ultra": "ultra"}  # --encode-profile -> the app's setting
APP_LOG_SUBSYSTEM = "com.cmuxterm.app.next"  # RemoteRdStreamTransport's Logger
APP_LOG_CATEGORY = "remote-view-rd"


def app_slug(raw):
    """ControlSocketPath.sanitize: lowercase, [^a-z0-9]+ -> '-', trimmed; None when empty."""
    slug = re.sub(r"[^a-z0-9]+", "-", raw.lower()).strip("-")
    return slug or None


def app_socket_paths(bundle_id, home):
    """The control socket of the app with BUNDLE_ID (ControlSocketPath.swift), most likely first:
    the state-folder path and its /tmp name (the app keeps a symlink there). Release: one path."""
    bundle = (bundle_id or "").strip()
    old = None
    for channel_id, channel in APP_CHANNELS:
        if bundle == channel_id:
            old = f"/tmp/cmux-{channel}.sock"
        elif bundle.startswith(channel_id + ".") and app_slug(bundle[len(channel_id) + 1:]):
            old = f"/tmp/cmux-{channel}-{app_slug(bundle[len(channel_id) + 1:])}.sock"
    if old is None and bundle.startswith(APP_DEBUG_BUNDLE + ".") and app_slug(bundle[len(APP_DEBUG_BUNDLE) + 1:]):
        old = f"/tmp/cmux-debug-{app_slug(bundle[len(APP_DEBUG_BUNDLE) + 1:])}.sock"
    if old is None and bundle == APP_DEBUG_BUNDLE:
        old = "/tmp/cmux-debug.sock"
    if old is None:
        return [os.path.join(home, ".local/state/cmux/cmux.sock")]
    moved = os.path.join(home, ".local/state/cmux", old[len("/tmp/"):])
    return [moved, old] if len(moved.encode()) <= 103 else [old]


def app_bundle_id(app):
    import plistlib
    with open(os.path.join(app, "Contents", "Info.plist"), "rb") as f:
        return plistlib.load(f).get("CFBundleIdentifier")


def app_call(paths, method, params=None, timeout=60):
    """One request on the app's control socket (the socket the `cmux` CLI uses): its result, or
    {"error"}. Needs an automation-mode socket (CMUX_NEXT_SOCKET_MODE=automation)."""
    last = "no socket"
    for path in paths:
        if not os.path.exists(path):
            continue
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
            return reply.get("result") if reply.get("ok") else {"error": reply.get("error")}
        except (OSError, ValueError) as e:
            last = f"{path}: {e}"
    return {"error": last}


def parse_locate(text):
    """screen-eval-marker-locate's `origin X,Y cell C at X,Y` as (origin, cell, at), or None."""
    m = re.search(r"origin (\d+,\d+) cell (\d+) at (\d+,\d+)", text or "")
    return (m.group(1), int(m.group(2)), m.group(3)) if m else None


def app_ledger_from_log(ndjson):
    """The newest `stage ledger:` line (RemoteRdStreamTransport, every 5 s: the session so far)
    in `log show --style ndjson` output, as the ledger dict, and how many there were."""
    found, last = 0, None
    for line in (ndjson or "").splitlines():
        try:
            msg = json.loads(line).get("eventMessage") or ""
        except (ValueError, AttributeError):
            continue
        if not msg.startswith(LEDGER_LINE):
            continue
        try:
            ledger = json.loads(msg[len(LEDGER_LINE):])
        except ValueError:
            continue
        found += 1
        last = ledger
    return last, found


def cmd_app(args):
    """On the viewing Mac: launch the app (`open -n`), call its control socket, locate the marker
    on the main display, or read its stage ledger log. Prints one JSON line."""
    app = os.path.expanduser(args.app)
    paths = app_socket_paths(app_bundle_id(app), os.path.expanduser("~"))
    out = {}
    if args.action == "rpc":
        out = app_call(paths, args.method, json.loads(args.params or "{}"))
    elif args.action == "launch":
        alive = "error" not in app_call(paths, "system.ping", timeout=10)
        out = {"socket": paths[0], "reused": alive}
        if alive:
            # An app that already runs keeps its own settings: the profile is whatever it has.
            out["encode_profile_applied"] = False
        else:
            state = os.path.expanduser(args.state)
            os.makedirs(state, mode=0o700, exist_ok=True)
            env = dict(e.split("=", 1) for e in args.env or [])
            env.setdefault("CMUX_NEXT_SOCKET_MODE", "automation")
            if args.frame:
                env.setdefault("CMUX_NEXT_TEST_WINDOW_FRAME", args.frame)
            if args.background:
                env.setdefault("CMUX_NEXT_NO_ACTIVATE", "1")
            if args.encode_profile and "CMUX_NEXT_CONFIG_FILE" not in env:
                # remote.screenSharingProfile is a user-only setting: no agent `settings.set`
                # reaches it, a config file does.
                config = os.path.join(state, "app-viewer-cmux.json")
                with open(config, "w") as f:
                    json.dump({"remote": {"screenSharingProfile": args.encode_profile}}, f)
                env["CMUX_NEXT_CONFIG_FILE"] = config
            out["encode_profile_applied"] = bool(args.encode_profile) and \
                env.get("CMUX_NEXT_CONFIG_FILE") == os.path.join(state, "app-viewer-cmux.json")
            log = os.path.join(state, "app-viewer.log")
            argv = ["open", "-n"] + (["-g"] if args.background else []) + ["--stdout", log, "--stderr", log]
            for k, v in sorted(env.items()):
                argv += ["--env", f"{k}={v}"]
            subprocess.run(argv + [app], check=True, timeout=60)
            deadline = time.time() + args.wait
            while time.time() < deadline:
                if "error" not in app_call(paths, "system.ping", timeout=10):
                    break
                time.sleep(0.5)  # bounded wait (--wait) for the launched app's socket
            else:
                out["error"] = f"the app's socket did not answer in {args.wait:g} s ({paths[0]})"
            out["env"] = sorted(env)
        if not out.get("error"):
            # --app-viewer drives the pane through debug.device_hub and debug.mac_screen, which
            # only DEV builds register: a Release app (NIGHTLY) answers method_not_found.
            probe = app_call(paths, "debug.mac_screen", {"action": "state"}, timeout=10)
            if "method_not_found" in str(probe.get("error") or ""):
                out["error"] = (f"{app} is a Release build: debug.mac_screen and debug.device_hub, which "
                                "--app-viewer drives, exist only in DEV builds. Pass a DEV build at or after "
                                "cmux#47235; a Release app's own pane timings are `cmux app mac-screens` "
                                f"({APP_STATE_METHOD})")
    elif args.action == "locate":
        png = os.path.join(os.path.expanduser(args.state), "app-viewer-locate.png")
        why = "no capture"
        deadline = time.time() + args.wait
        while True:
            cap = subprocess.run(["screencapture", "-x", "-D", "1", png], capture_output=True, text=True)
            if cap.returncode == 0:
                loc = subprocess.run([args.locate, png], capture_output=True, text=True)
                found = parse_locate(loc.stdout)
                if found:
                    out = {"origin": found[0], "cell": found[1], "at": found[2]}
                    break
                why = (loc.stderr or loc.stdout).strip()[-300:]
            else:
                why = f"screencapture: {cap.stderr.strip()[-300:]}"
            if time.time() >= deadline:
                out = {"error": f"no marker visible through the app's pane ({why})"}
                break
            time.sleep(0.5)  # bounded wait (--wait) for the marker to show in the pane
        with contextlib.suppress(OSError):
            os.unlink(png)
    elif args.action == "ledger":
        start = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(args.since))
        pred = (f'subsystem == "{APP_LOG_SUBSYSTEM}" AND category == "{APP_LOG_CATEGORY}" '
                f'AND processIdentifier == {int(args.pid)}')
        p = subprocess.run(["log", "show", "--style", "ndjson", "--info", "--start", start,
                            "--predicate", pred], capture_output=True, text=True, timeout=120)
        ledger, n = app_ledger_from_log(p.stdout)
        out = {"ledger": ledger, "lines": n}
        if p.returncode != 0:
            out["error"] = f"log show: exit {p.returncode}: {p.stderr.strip()[-300:]}"
    print(json.dumps(out))


# --- the macOS Screen Sharing leg (viewing Mac) ------------------------------------------


def load_cua_vnc(path):
    import importlib.machinery
    import importlib.util
    loader = importlib.machinery.SourceFileLoader("cua_vnc", path)
    spec = importlib.util.spec_from_loader("cua_vnc", loader)
    mod = importlib.util.module_from_spec(spec)
    sys.modules["cua_vnc"] = mod  # dataclasses look the module up by name
    loader.exec_module(mod)
    return mod


RFB_WAIT_S = 1.0  # no update this long after an input: the input is lost
RFB_MESSAGE_S = 10.0  # one message, once its first byte is here


class RfbStalled(Exception):
    """A message stopped arriving part way: the stream is no longer in step, so the trial ends."""


def rfb_next(client, wait_s):
    """The next server message's type, or None when none starts within WAIT_S. Waiting happens
    in select() before the first byte, never inside a read: a socket timeout in the middle of a
    message would leave the rest of it in the stream and every later read out of step."""
    sock = client.t.sock
    r, _, _ = select.select([sock], [], [], max(wait_s, 0))
    if not r:
        return None
    client.t.set_timeout(RFB_MESSAGE_S)
    try:
        return client.read_message()
    except (socket.timeout, TimeoutError, OSError, EOFError) as e:
        raise RfbStalled(repr(e)) from e


def rfb_click(client, x, y):
    client.pointer(x, y, 1)
    client.pointer(x, y, 0)


def cmd_rfb_bench(args):
    vnc = load_cua_vnc(os.path.expanduser(args.cua_vnc))
    user = os.environ.get("VNC_USERNAME")
    pw_file = os.environ.get("VNC_PASSWORD_FILE")
    if not user or not pw_file:
        print(json.dumps({"error": "no credentials: set VNC_USERNAME and VNC_PASSWORD_FILE"}))
        sys.exit(3)
    with open(os.path.expanduser(pw_file), encoding="utf8") as f:
        password = f.read().rstrip("\r\n")
    ox, oy = args.origin
    cell = args.cell
    strip = (ox, oy, cell * CELLS, cell)
    # The marker's gray pad (mac-marker's click-at): clicks there count and never touch a read cell.
    pad = (ox + cell * (CELLS + 2), oy + cell // 2)
    t_start = mono_ns()
    client = vnc.RfbClient(vnc.TcpTransport(args.host, args.port, 10.0), password, user,
                           "apple", ["raw"])
    password = None
    client.connect()
    t_auth = mono_ns()
    client.t.set_timeout(10.0)

    def request(incremental):
        client.send(struct.pack("!BBHHHH", 3, 1 if incremental else 0, *strip))

    def value():
        d = client.desktop
        return read_marker_rgb(d.rgb, d.width, (ox, oy), cell)

    def send_input(kind):
        if kind == "click":
            rfb_click(client, *pad)
        else:
            client.key(KEYSYM_A, True)
            client.key(KEYSYM_A, False)

    def await_change(before, wait_s):
        """The next marker value other than BEFORE, or None when no update brings one in WAIT_S."""
        deadline = mono_ns() + wait_s * 1e9
        while True:
            msg = rfb_next(client, (deadline - mono_ns()) / 1e9)
            if msg is None:
                return None
            if msg == 0:
                v = value()
                request(True)
                if v is not None and v != before:
                    return v

    report = {"stack": "apple", "input": args.input if args.mode == "key" else None}
    g2g, lost = [], 0
    try:
        request(False)
        marker = None
        while marker is None:
            msg = rfb_next(client, 30 - (mono_ns() - t_start) / 1e9)
            if msg is None:
                print(json.dumps({"error": "no marker within 30 s"}))
                sys.exit(2)
            if msg == 0:
                marker = value()
                request(marker is not None)
        report.update({"first_frame_ms": (mono_ns() - t_start) / 1e6,
                       "auth_ms": (t_auth - t_start) / 1e6, "security_type": client.security_type,
                       "screen": [client.desktop.width, client.desktop.height]})
        if args.mode == "key":
            if args.input == "key":
                # The marker window is not key after the rig starts it, so RFB keys would go to
                # another window: one click on its pad makes it key. Time keys only after that
                # click's update arrives.
                rfb_click(client, *pad)
                v = await_change(marker, 3.0)
                if v is None:
                    report.update({"error": "the focus click on the marker's pad did not show",
                                   "key_to_frame_ms": [], "lost": args.samples})
                    print(json.dumps(report))
                    return
                marker = v
                report["focus_click"] = True
            for _ in range(args.samples):
                expected = (marker + 1) & 0xFFFF
                t0 = mono_ns()
                send_input(args.input)
                v = await_change(marker, RFB_WAIT_S)
                if v is None:
                    lost += 1
                else:
                    t1 = mono_ns()
                    marker = v
                    if v == expected:
                        g2g.append((t1 - t0) / 1e6)
                    else:
                        lost += 1  # the counter moved by something else: not this input's frame
                time.sleep(0.04 + (os.urandom(1)[0] / 255.0) * 0.12)
            report.update({"key_to_frame_ms": g2g, "lost": lost})
        else:
            changes, t_begin = 0, mono_ns()
            end = t_begin + args.duration_s * 1e9
            while mono_ns() < end:
                msg = rfb_next(client, min(RFB_WAIT_S, (end - mono_ns()) / 1e9))
                if msg is None:
                    request(True)
                    continue
                if msg == 0:
                    v = value()
                    request(True)
                    if v is not None and v != marker:
                        changes += 1
                        marker = v
            secs = (mono_ns() - t_begin) / 1e9
            report.update({"marker_changes": changes, "marker_fps": changes / secs, "seconds": secs})
    except RfbStalled as e:
        # The stream is out of step: keep what was measured, read nothing more.
        report["stalled"] = str(e)[-200:]
        if args.mode == "key":
            report.update({"key_to_frame_ms": g2g, "lost": lost + 1})
    client.close()
    print(json.dumps(report))


# --- the orchestrator ---------------------------------------------------------------------


class Remote:
    def __init__(self, name, via):
        self.name, self.via = name, via

    def argv(self, cmd):
        if self.via == "ssh":
            return ["ssh", "-o", "BatchMode=yes", self.name, cmd]
        if self.via == "local":
            # The orchestrator runs on the Mac itself: a lane VM's reach relay carries no stdin,
            # and the session's signaling goes over the host's and viewer's stdin.
            return ["/bin/bash", "-c", cmd]
        return ["reach", self.name, cmd]

    def run(self, cmd, timeout=120, stdin=None):
        p = subprocess.run(self.argv(cmd), input=stdin, capture_output=True, text=True,
                           timeout=timeout)
        if p.returncode != 0:
            raise RuntimeError(f"{self.name}: {cmd[:80]}: exit {p.returncode}: {p.stderr.strip()[-400:]}")
        return p.stdout

    def popen(self, cmd):
        p = subprocess.Popen(self.argv(cmd), stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE, text=True, bufsize=1)
        # A reader thread owns stdout. select() on a buffered pipe misses lines that one
        # read already pulled into the buffer (a signaling line then never gets relayed).
        p.lines = queue.Queue()

        def pump():
            for line in p.stdout:
                p.lines.put(line)
            p.lines.put(None)

        threading.Thread(target=pump, daemon=True).start()
        return p

    def put(self, local, remote_path, mode="0755"):
        with open(local, "rb") as f:
            data = f.read()
        p = subprocess.run(self.argv(f"mkdir -p {shlex.quote(os.path.dirname(remote_path))} && "
                                     f"cat > {shlex.quote(remote_path)}.tmp && chmod {mode} "
                                     f"{shlex.quote(remote_path)}.tmp && mv {shlex.quote(remote_path)}.tmp "
                                     f"{shlex.quote(remote_path)}"),
                           input=data, capture_output=True, timeout=300)
        if p.returncode != 0:
            raise RuntimeError(f"{self.name}: put {remote_path}: {p.stderr.decode()[-300:]}")


# The remote half of SpoolRemote.popen: runs CMD in its own process group with stdin fed from
# DIR/in as it grows (until DIR/in.closed), stdout and stderr to DIR/out and DIR/err, and its exit
# status to DIR/rc. DIR/kill ends the group.
SPOOL_RUNNER = r'''
import os, signal, subprocess, sys, time
d, cmd = sys.argv[1], sys.argv[2]
out, err = open(d + "/out", "wb"), open(d + "/err", "wb")
p = subprocess.Popen(cmd, shell=True, stdin=subprocess.PIPE, stdout=out, stderr=err,
                     start_new_session=True)
open(d + "/pid", "w").write(str(p.pid))
f, fed = open(d + "/in", "rb"), True
while p.poll() is None:
    if os.path.exists(d + "/kill"):
        os.killpg(p.pid, signal.SIGTERM)
        try:
            p.wait(3)
        except subprocess.TimeoutExpired:
            os.killpg(p.pid, signal.SIGKILL)
        break
    chunk = f.read()
    if chunk and fed:
        try:
            p.stdin.write(chunk)
            p.stdin.flush()
        except BrokenPipeError:
            fed = False
    elif fed and os.path.exists(d + "/in.closed"):
        if not f.read():
            p.stdin.close()
            fed = False
    time.sleep(0.02)
open(d + "/rc.tmp", "w").write(str(p.wait()))
os.rename(d + "/rc.tmp", d + "/rc")
'''


class SpoolRemote(Remote):
    """A Remote for `reach` routes with no stdin (a lane VM's broker relay): a file's bytes
    travel as base64 in the command, and a long-running process reads its stdin from a file on
    the Mac that each write appends to, while a thread here polls its stdout file. Only the
    control lines pay the relay's round trip (about 3 s); every timed sample runs on the Macs."""

    CHUNK = 15_000  # the broker relay takes commands of at most 16384 bytes

    def __init__(self, name):
        super().__init__(name, "reach")
        self.runner = None
        self.lock = threading.Lock()

    def argv(self, cmd):
        return ["reach", "--timeout", "480", self.name, cmd]

    def run(self, cmd, timeout=120, stdin=None):
        if stdin is not None:
            raise RuntimeError("spool: run with stdin is not supported")
        # The relay itself fails now and then (its lease read times out, the call is dropped):
        # retried, since the command never ran ("nothing was run") or is idempotent here.
        for attempt in range(4):
            try:
                return super().run(cmd, timeout=timeout)
            except (RuntimeError, subprocess.TimeoutExpired) as e:
                transient = isinstance(e, subprocess.TimeoutExpired) or "nothing was run" in str(e)
                if not transient or attempt == 3:
                    raise
                time.sleep(2 * (attempt + 1))

    def put(self, local, remote_path, mode="0755"):
        import base64
        import gzip
        with open(local, "rb") as f:
            data = base64.b64encode(gzip.compress(f.read())).decode()
        tmp = shlex.quote(remote_path + ".b64")
        self.run(f"mkdir -p {shlex.quote(os.path.dirname(remote_path))} && : > {tmp}")
        for i in range(0, len(data), self.CHUNK):
            self.run(f"printf %s {data[i:i + self.CHUNK]} >> {tmp}", timeout=300)
        q = shlex.quote(remote_path)
        self.run(f"base64 -d < {tmp} | gunzip > {q}.tmp && rm {tmp} && chmod {mode} {q}.tmp "
                 f"&& mv {q}.tmp {q}", timeout=300)

    def popen(self, cmd):
        with self.lock:
            if not self.runner:
                path = f"/tmp/ssvs-spool-{os.getpid()}-runner.py"
                import tempfile
                with tempfile.NamedTemporaryFile("w", suffix=".py", delete=False) as f:
                    f.write(SPOOL_RUNNER)
                try:
                    self.put(f.name, path, "0644")
                finally:
                    os.unlink(f.name)
                self.runner = path
        d = f"/tmp/ssvs-spool-{os.urandom(6).hex()}"
        # A new session: the relay ends the command's whole process group when the call returns.
        start = ("import subprocess, sys; subprocess.Popen(['/usr/bin/python3'] + sys.argv[1:], "
                 "start_new_session=True, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, "
                 "stderr=subprocess.DEVNULL)")
        self.run(f"mkdir -m 700 {d} && : > {d}/in && /usr/bin/python3 -c {shlex.quote(start)} "
                 f"{self.runner} {d} {shlex.quote(cmd)}")
        return SpoolProc(self, d)


class SpoolProc:
    """The Popen-like handle SpoolRemote.popen returns: .lines, .stdin, .stderr, poll, wait,
    terminate, kill."""

    lag_s = 30  # readline's extra wait: a stdout poll is one relay round trip (about 3 s, more under load)

    def __init__(self, remote, d):
        self.remote, self.d = remote, d
        self.lines = queue.Queue()
        self.returncode = None
        self.done = threading.Event()
        self.stdin = self._Stdin(self)
        self.stderr = self._Stderr(self)
        threading.Thread(target=self._pump, daemon=True).start()

    class _Stdin:
        def __init__(self, proc):
            self.proc, self.buf = proc, ""

        def write(self, s):
            self.buf += s.decode() if isinstance(s, bytes) else s

        def flush(self):
            import base64
            if not self.buf:
                return
            data, self.buf = base64.b64encode(self.buf.encode()).decode(), ""
            self.proc.remote.run(f"printf %s {data} | base64 -d >> {self.proc.d}/in")

        def close(self):
            self.flush()
            self.proc.remote.run(f": > {self.proc.d}/in.closed")

    class _Stderr:
        def __init__(self, proc):
            self.proc = proc

        def read(self):
            try:
                return self.proc.remote.run(f"cat {self.proc.d}/err")
            except Exception as e:  # noqa: BLE001
                return repr(e)

    def _pump(self):
        off, part = 0, b""
        mark = "@@SPOOL-RC "
        while True:
            try:
                out = self.remote.run(f"tail -c +{off + 1} {self.d}/out 2>/dev/null; "
                                      f"printf '\\n{mark}%s' \"$(cat {self.d}/rc 2>/dev/null)\"")
            except Exception:  # noqa: BLE001 - a lost poll is retried
                time.sleep(1)
                continue
            body, _, rc = out.rpartition("\n" + mark)
            chunk = body.encode()
            off += len(chunk)
            part += chunk
            *whole, part = part.split(b"\n")
            for line in whole:
                self.lines.put(line.decode(errors="replace") + "\n")
            if rc.strip():
                if part:
                    self.lines.put(part.decode(errors="replace"))
                self.returncode = int(rc.strip())
                self.lines.put(None)
                self.done.set()
                return
            time.sleep(0.3)

    def poll(self):
        return self.returncode

    def wait(self, timeout=None):
        if not self.done.wait(timeout):
            raise subprocess.TimeoutExpired(self.d, timeout)
        return self.returncode

    def terminate(self):
        try:
            self.remote.run(f": > {self.d}/kill")
        except Exception:  # noqa: BLE001
            pass

    kill = terminate


TAILNET_UDP = ("UDP over the tailnet got no answer between the wired fleet pair (2026-11-19, cmux20 to cmux17: "
               "\"no clock replies\" while ping answered); pass the shared Mac's LAN address as --host-ip.")


def tailnet(addr):
    """Whether ADDR is a tailnet (CGNAT 100.64.0.0/10) address."""
    try:
        return ipaddress.ip_address(addr) in ipaddress.ip_network("100.64.0.0/10")
    except ValueError:
        return False


def readline(proc, deadline):
    """The next stdout line of a Remote.popen process, or None at EOF or the deadline. A spool
    process's lines arrive by polling through the relay, so its deadline gets the relay's lag."""
    left = deadline - time.time() + getattr(proc, "lag_s", 0)
    if left <= 0:
        return None
    try:
        return proc.lines.get(timeout=left)
    except queue.Empty:
        return None


class Orchestrator:
    def __init__(self, args):
        self.a = args
        self.ff_rows = []
        self.motion_rows = []  # cmux fps trials: received Mbps and loss under motion
        make = (lambda name: SpoolRemote(name)) if args.via == "spool" else (lambda name: Remote(name, args.via))
        self.host = make(args.host)
        self.viewer = make(args.viewer)
        self.root = args.root
        self.py = args.python
        self.me = f"{self.root}/screen-share-vs.py"
        self.out = open(args.out, "a") if args.out else None
        self.synthetic = args.source == "synthetic"
        self.scores = []  # frame-score results of the motion trials' last decoded frames
        self.ledgers = []  # per-sample stage ledger rows (ledger_stages), when the build has them
        self.summaries = []  # each counted trial's run stage ledger (the bench's stage_ledger)
        self.presented = None  # cmux-rd observe's latencies (ms) through a visible viewer pane
        self.presented_source = None  # where that pane came from (presented_source())
        self.app_ledger = None  # the app viewer's own stage ledger (--app-viewer), or {"null"}
        self.app_timings = None  # the pane's own frame timings (mac_screen.state), or {"null"}
        self.geometry = None  # the marker's motion-geometry, read from the shared Mac
        self.quality_null = None
        self.apple_g2g = None
        self.apple_skipped = None
        self.marker_bin = self.ocr_bin = self.locate_bin = None
        self.rev = getattr(args, "rev", None)
        # Extra `cmux-rd serve` / `cmux-rd bench` flags (HOST_ARGS, VIEWER_ARGS), as given.
        self.host_args = list(getattr(args, "host_arg", None) or [])
        self.viewer_args = list(getattr(args, "viewer_arg", None) or [])
        try:
            self.host_argv = checked_args(self.host_args, HOST_ARGS, "host")
            self.viewer_argv = checked_args(self.viewer_args, VIEWER_ARGS, "viewer")
        except ValueError as e:
            raise SystemExit(str(e))
        if getattr(args, "tools", None):
            tools = os.path.expanduser(args.tools)
            if not os.path.isdir(tools):
                raise SystemExit(f"--tools {tools}: not a folder (unpack tools.tar.gz first)")
            if not args.bin:
                args.bin = os.path.join(tools, "cmux-rd")
            if not args.marker_src and os.path.exists(os.path.join(tools, "cmux-rd-marker")):
                self.marker_bin = os.path.join(tools, "cmux-rd-marker")
            if os.path.exists(os.path.join(tools, "screen-eval-ocr")):
                self.ocr_bin = os.path.join(tools, "screen-eval-ocr")
            if os.path.exists(os.path.join(tools, "screen-eval-marker-locate")):
                self.locate_bin = os.path.join(tools, "screen-eval-marker-locate")
        if getattr(args, "app_viewer", None):
            if not self.locate_bin:
                raise SystemExit("--app-viewer needs screen-eval-marker-locate (pass --tools with "
                                 "the unpacked tools.tar.gz) to find the marker in the app's pane")
            if args.presented_pid or args.presented_window:
                raise SystemExit("--app-viewer finds the pane itself: drop --presented-pid/--presented-window")
            if not self.rev and os.path.exists(os.path.join(tools, "rev")):
                with open(os.path.join(tools, "rev")) as f:
                    self.rev = f.read().strip() or None

    def log(self, rec):
        line = json.dumps({**rec, "host_args": self.host_args, "viewer_args": self.viewer_args})
        print(line, flush=True)
        if self.out:
            self.out.write(line + "\n")
            self.out.flush()

    def rig(self, request, timeout=30):
        out = self.host.run(f"{self.py} {self.me} rig-call --root {self.root} "
                            f"{shlex.quote(json.dumps(request))}", timeout=timeout)
        reply = json.loads(out.strip().splitlines()[-1])
        if not reply.get("ok"):
            raise RuntimeError(f"rig {request.get('cmd')}: {reply}")
        return reply

    def setup(self):
        if not self.root.startswith("/"):
            homes = {r.run('printf %s "$HOME"').strip() for r in (self.host, self.viewer)}
            if len(homes) != 1:
                raise SystemExit(f"the two Macs have different homes {homes}: pass an absolute --root")
            self.root = f"{homes.pop()}/{self.root}"
            self.me = f"{self.root}/screen-share-vs.py"
        here = os.path.abspath(__file__)
        for r in (self.host, self.viewer):
            r.put(here, self.me)
        if self.a.bin:
            self.viewer.put(self.a.bin, f"{self.root}/bin/cmux-rd")
        if self.a.bin or self.a.host_bin:
            self.host.put(self.a.host_bin or self.a.bin, f"{self.root}/bin/cmux-rd")
        if self.a.marker_src:
            self.host.put(self.a.marker_src, f"{self.root}/bin/marker-main.swift", "0644")
            self.host.run(f"cd {self.root}/bin && swiftc -O -o cmux-rd-marker marker-main.swift",
                          timeout=600)
        elif self.marker_bin:
            self.host.put(self.marker_bin, f"{self.root}/bin/cmux-rd-marker")
        if self.ocr_bin:
            self.viewer.put(self.ocr_bin, f"{self.root}/bin/screen-eval-ocr")
        if self.locate_bin and getattr(self.a, "app_viewer", None):
            self.viewer.put(self.locate_bin, f"{self.root}/bin/screen-eval-marker-locate")
        if self.a.cua_vnc:
            self.viewer.put(self.a.cua_vnc, f"{self.root}/bin/cua-vnc")
        self.viewer.run(f"mkdir -p {shlex.quote(self.root)}/state && chmod 700 {shlex.quote(self.root)}/state")
        if self.synthetic:
            # No rig and no marker app: `cmux-rd serve --source synthetic-*` needs no grant.
            state = shlex.quote(f"{self.root}/state")
            self.host.run(f"mkdir -p {state} && chmod 700 {shlex.quote(self.root)} {state}")
            return
        try:
            self.rig({"cmd": "ping"})
        except Exception:
            if not self.a.rig_launch:
                raise SystemExit(
                    "the rig is not running on the shared Mac; start it inside an app that holds "
                    "Screen Recording and Accessibility, or pass --rig-launch cmux-next")
            app_cli = "/Applications/cmux NEXT.app/Contents/Resources/bin/cmux"
            self.host.run(f"{shlex.quote(app_cli)} workspace create --name rd-share-rig -- "
                          f"/usr/bin/python3 {self.me} rig --root {self.root}")
            for _ in range(50):
                try:
                    self.rig({"cmd": "ping"})
                    break
                except Exception:
                    time.sleep(0.2)
            else:
                raise SystemExit("the rig did not start in cmux NEXT")

    CLOCK_TRIES = 3

    def clock(self):
        """The clock probe, tried up to CLOCK_TRIES times. Its control path (a reach call to each Mac)
        can stall for tens of seconds when the fanout is busy, while the pair link itself is fine; one
        slow start or timed-out probe ended a whole run before any trial."""
        errors = []
        for _ in range(self.CLOCK_TRIES):
            try:
                return self.clock_once()
            except Exception as e:  # a slow start, a timed-out probe, no replies
                errors.append(f"{type(e).__name__}: {e}")
                print(f"clock probe try {len(errors)} of {self.CLOCK_TRIES} failed: {errors[-1]}", file=sys.stderr, flush=True)
        raise RuntimeError(f"clock probe failed {len(errors)} times: " + " | ".join(errors))

    def clock_once(self):
        # Port 0: a clock server still draining from the last probe never collides.
        srv = self.host.popen(f"{self.py} {self.me} clock-serve --bind {self.a.host_ip} "
                              f"--port 0 --seconds 180")
        line = readline(srv, time.time() + 45)
        try:
            port = json.loads(line or "{}").get("listening")
            if not port:
                raise RuntimeError(f"clock-serve on {self.a.host} did not start: {line!r}")
            try:
                out = self.viewer.run(f"{self.py} {self.me} clock-probe --addr {self.a.host_ip}:{port} "
                                      f"--count {self.a.clock_count}", timeout=120)
            except RuntimeError as e:
                if tailnet(self.a.host_ip):
                    raise RuntimeError(f"{e}\n{TAILNET_UDP}") from None
                raise
        finally:
            srv.terminate()
        return json.loads(out.strip().splitlines()[-1])

    # cmux ------------------------------------------------------------------------------

    def cmux_attempt(self, origin, mode, snapshot=None):
        rec = {"stack": "cmux", "mode": mode, "ok": False}
        session = "vs-" + os.urandom(8).hex()
        bench = (f"{self.root}/bin/cmux-rd bench --link 1 --marker-origin {origin[0]},{origin[1]} ")
        if mode == "key":
            bench += bench_input(getattr(self.a, "cmux_input", "key"), self.a.samples,
                                 getattr(self, "marker_at", None))
        else:
            bench += f"--input none --duration-s {self.a.fps_seconds}"
            if getattr(self.a, "marker_log", False):
                bench += " --marker-log 1"
            if snapshot:
                bench += f" --snapshot {snapshot}"
        if self.viewer_argv:
            bench += " " + " ".join(shlex.quote(a) for a in self.viewer_argv)
        viewer = self.viewer.popen(bench)
        host = None
        try:
            line = readline(viewer, time.time() + 20)
            viewer_key = json.loads(line)["key"]
            if self.synthetic:
                host = self.host.popen(self.synthetic_serve(mode))
            else:
                host = self.host.popen(f"{self.py} {self.me} rig-call --root {self.root} "
                                       + shlex.quote(json.dumps({"cmd": "serve", "timing": mode == "key",
                                                                 "flags": {"--profile": "high"},
                                                                 "args": self.host_args,
                                                                 "link_bind": self.a.link_bind})))
            setup = {"session": session, "peer_key": viewer_key, "scope": "control", "stun": [],
                     "display": "main", "max_fps": self.a.max_fps,
                     "viewer": {"user": "viewer", "install": "screen-share-vs"}}
            if self.a.encode_profile:
                setup["encode_profile"] = self.a.encode_profile
            host.stdin.write(json.dumps(setup) + "\n")
            host.stdin.flush()
            host_key, cands = None, []
            dl = time.time() + 20
            while True:
                line = readline(host, min(dl, time.time() + 0.3) if host_key and cands else dl)
                if not line:
                    break
                msg = json.loads(line)
                if "key" in msg:
                    host_key = msg["key"]
                elif "candidate" in msg:
                    cands.append(msg["candidate"])
                elif msg.get("candidates_done"):
                    break
            rec["host_candidates"] = cands
            cands = [c for c in cands if self.a.host_ip in c] or cands
            t0 = time.time()
            viewer.stdin.write(json.dumps({"session": session, "peer_key": host_key, "stun": [],
                                           "candidates": cands}) + "\n")
            viewer.stdin.flush()
            streams = {"host": host, "viewer": viewer}
            deadline = t0 + self.a.timeout
            while streams and time.time() < deadline and "report" not in rec:
                for who, p in list(streams.items()):
                    try:
                        line = p.lines.get(timeout=0.01)
                    except queue.Empty:
                        continue
                    if line is None:
                        del streams[who]
                        continue
                    try:
                        msg = json.loads(line)
                    except ValueError:
                        continue
                    if who == "viewer" and "candidate" in msg:
                        host.stdin.write(json.dumps(msg) + "\n")
                        host.stdin.flush()
                    elif who == "host" and msg.get("connected"):
                        rec["connect_ms"] = round((time.time() - t0) * 1000, 1)
                    elif who == "host" and "path" in msg:
                        rec.setdefault("paths", []).append(msg["path"])
                    elif who == "viewer" and ("g2g_ms" in msg or "marker_fps" in msg):
                        rec["report"] = msg
            rep = rec.pop("report", None)
            if rep:
                rec["ok"] = True
                if isinstance(rep.get("stage_ledger"), dict):
                    rec["stage_ledger"] = rep["stage_ledger"]
                rec["first_frame_ms"] = rep.get("first_frame_ms")
                if mode == "key":
                    rec["g2g_ms"] = rep.get("g2g_ms")
                    rec["lost"] = rep.get("lost")
                    rec["sample_times"] = rep.get("sample_times")
                    rec["first_frame_times"] = rep.get("first_frame_times")
                    rec["frames_per_s"] = rep.get("frames_per_s")
                else:
                    rec["marker_fps"] = rep.get("marker_fps")
                    rec["fps"] = rep.get("fps")
                    rec["mbit_per_s"] = rep.get("bytes", 0) * 8 / max(rep.get("seconds", 1), 1e-3) / 1e6
                    rec.update(motion_link(rep.get("series") or []))
                    if rep.get("marker_log") is not None:
                        rec["marker_log"] = rep["marker_log"]
                        # Each second's end (viewer wall ms) and the host's newest stats then.
                        rec["series_stats"] = [[b.get("unix_ms"), (b.get("host_stats") or {}).get("kbps")]
                                               for b in rep.get("series") or []]
            else:
                rec["error"] = (viewer.stderr.read() if viewer.poll() is not None else "timeout")[-400:]
        except Exception as e:  # noqa: BLE001 - a broken attempt is a failed attempt
            rec["error"] = repr(e)
        finally:
            for p in (viewer, host):
                if p and p.poll() is None:
                    try:
                        p.stdin.write(json.dumps({"stop": True}) + "\n")
                        p.stdin.flush()
                        p.stdin.close()
                    except Exception:  # noqa: BLE001
                        pass
            for p in (viewer, host):
                if p:
                    try:
                        p.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        p.kill()
                        p.wait()
        return rec

    def first_frame_breakdown(self, rec, timing, offset_ns):
        """connect -> first decoded frame, split with the host's log (ms, viewer clock)."""
        t = rec.get("first_frame_times")
        opened = next((x for x in timing if "open_us" in x), None)
        f = next((x for x in timing if t and x.get("capture_us", x.get("release_us")) == t.get("capture_us")), None)
        if not (t and opened and f):
            return None
        off_us = offset_ns / 1000.0
        start = t["start_ns"] / 1000.0
        arrived = f.get("arrived_us")

        def ms(us):
            return None if us is None else round(us / 1000.0, 3)

        return {
            # the viewer has the answer -> the host opens the session (handshake, hello, start)
            "signal": ms(opened["open_us"] - off_us - start),
            # capture stream and encoder start
            "capture_start": ms(opened["desktop_ready_us"] - opened["open_us"]),
            # the capture's first frame arrives
            "first_capture": ms(arrived - opened["desktop_ready_us"]) if arrived else None,
            "gate": ms(f.get("encode_start_us", f["release_us"]) - arrived) if arrived else None,
            "encode": ms(f["encoded_us"] - f.get("encode_start_us", f["release_us"])),
            "send": ms(f["sent_us"] - f["encoded_us"]),
            "down": ms(t["complete_ns"] / 1000.0 - (f["sent_us"] - off_us)),
            "decode": ms((t["decoded_ns"] - t["complete_ns"]) / 1000.0),
            "total": ms((t["decoded_ns"] - t["start_ns"]) / 1000.0),
            "bytes": f.get("encoded_bytes"),
            "idr": f.get("idr"),
        }

    def breakdown(self, rec, timing, offset_ns):
        """Per key press: where the time went, on the viewer's clock (ms)."""
        frames = {}
        injects = []
        for line in timing:
            if "inject_us" in line:
                injects.append(line)
            elif "release_us" in line:
                frames[line.get("capture_us", line["release_us"])] = line
        injects.sort(key=lambda x: x["inject_us"])
        rows = []
        off_us = offset_ns / 1000.0

        def v(host_us):  # a host time (µs) on the viewer's clock
            return host_us - off_us

        def ms(us):
            return None if us is None else round(us / 1000.0, 3)

        for s in rec.get("sample_times") or []:
            f = frames.get(s["capture_us"])
            sent = s["sent_ns"] / 1000.0
            # The first injection the host read after this press was sent (1 ms of slack for
            # the clock estimate).
            inj = next((i for i in injects if i.get("recv_us") and v(i["recv_us"]) >= sent - 1000), None)
            if not f or not inj:
                continue
            shown, arrived = f.get("shown_us"), f.get("arrived_us")
            rows.append({
                "up": ms(v(inj["recv_us"]) - sent),
                "inject": ms(inj["inject_us"] - inj["recv_us"]),
                "draw": ms(shown - inj["inject_us"]) if shown else None,
                "sck": ms(arrived - shown) if shown and arrived else None,
                "gate": ms(f.get("encode_start_us", f["release_us"]) - arrived) if arrived else None,
                "encode": ms(f["encoded_us"] - f.get("encode_start_us", f["release_us"])),
                "send": ms(f["sent_us"] - f["encoded_us"]),
                "first_packet": ms(s["first_rx_ns"] / 1000.0 - v(f["sent_us"])),
                "down": ms(s["complete_ns"] / 1000.0 - v(f["sent_us"])),
                "decode": ms((s["decoded_ns"] - s["complete_ns"]) / 1000.0),
                "total": ms((s["decoded_ns"] - s["sent_ns"]) / 1000.0),
                "bytes": f.get("encoded_bytes"),
            })
        return rows

    # --source synthetic: the host streams a generated picture (`cmux-rd serve --source
    # synthetic-still|synthetic-tick`), its marker at 0,0, and viewer input bumps the marker.
    # No rig, marker app or grant: any two Macs over ssh.

    def synthetic_timing_path(self):
        return shlex.quote(f"{self.root}/state/timing.jsonl")

    def synthetic_serve(self, mode):
        """The host command of one synthetic attempt: key trials show a still picture whose
        marker counts key presses (the marker app alone); fps trials move the bars and count
        every frame (the marker app's `--tick --motion`)."""
        source = "synthetic-still" if mode == "key" else "synthetic-tick"
        argv = [f"{self.root}/bin/cmux-rd", "serve", "--profile", "high", "--source", source]
        if self.a.synthetic_size:
            argv += ["--synthetic-size", self.a.synthetic_size]
        if getattr(self.a, "synthetic_scene", None):
            argv += ["--synthetic-scene", self.a.synthetic_scene]
        if self.a.link_bind:
            ipaddress.IPv4Address(self.a.link_bind)  # an IPv4 literal, or this attempt fails
            argv += ["--link-bind", f"{self.a.link_bind}:0"]
        argv += self.host_argv
        # Both modes log timing: key trials for the breakdown, fps trials for `host_frames`.
        timing = self.synthetic_timing_path()
        env = f": > {timing} && CMUX_RD_TIMING_LOG={timing} "
        err = shlex.quote(f"{self.root}/state/serve.err")
        return env + " ".join(shlex.quote(a) for a in argv) + f" 2> {err}"

    def marker(self, flags):
        """The marker's origin for the next attempt: the marker app's (the rig), or 0,0."""
        if self.synthetic:
            return [0, 0]
        reply = self.rig({"cmd": "marker", "flags": flags})
        origin = reply["origin"]
        # click and scroll must land on the marker or it never counts them (the bench's own --at
        # default, 960,600, misses it): the marker's click-at, else its pad from the origin.
        self.marker_at = reply.get("at") or [origin[0] + 32 * (CELLS + 2), origin[1] + 16]
        time.sleep(0.5)
        return origin

    def host_timing(self):
        """The host's CMUX_RD_TIMING_LOG lines of the last attempt (then cleared)."""
        if not self.synthetic:
            return self.rig({"cmd": "timing"}, timeout=60).get("lines", [])
        timing = self.synthetic_timing_path()
        out = self.host.run(f"cat {timing} 2>/dev/null; : > {timing}", timeout=60)
        return [json.loads(x) for x in out.splitlines() if x.strip()]

    def run_cmux(self, clock):
        firsts, g2g, fps, rows = [], [], [], []
        # The first session after the rig starts can miss every key (the marker window is
        # not key yet), so warm-up attempts are logged but not counted.
        for n in range(1 - self.a.warmup, self.a.trials + 1):
            origin = self.marker([])
            rec = self.cmux_attempt(origin, "key")
            timing = self.host_timing()
            if n < 1:
                rec.pop("sample_times", None)
                self.log(dict(rec, warmup=True))
                continue
            rec["trial"] = n
            if rec["ok"]:
                firsts.append(rec["first_frame_ms"])
                g2g += [(s["decoded_ns"] - s["sent_ns"]) / 1e6 for s in rec.get("sample_times") or []]
                # A build with the stage ledger hands one per sample; every row then reads it.
                self.ledgers += [ledger_stages(s["ledger"]) for s in rec.get("sample_times") or []
                                 if s.get("ledger")]
                if rec.get("stage_ledger"):
                    self.summaries.append(rec["stage_ledger"])
                rec["breakdown"] = self.breakdown(rec, timing, clock["offset_ns"])
                rows += rec["breakdown"]
                ff = self.first_frame_breakdown(rec, timing, clock["offset_ns"])
                if ff:
                    rec["first_frame_breakdown"] = ff
                    self.ff_rows.append(ff)
            rec.pop("sample_times", None)
            self.log(rec)
        for n in range(1, self.a.fps_trials + 1):
            origin = self.marker(["--tick", "--motion"])
            geo = self.motion_geometry()
            snap = f"{self.root}/state/motion-{n}.ppm" if geo else None
            rec = self.cmux_attempt(origin, "fps", snap)
            rec["trial"] = n
            if self.synthetic:
                lines = self.host_timing()
                rec["host_frames"] = host_frames(lines, self.a.max_fps)
                if getattr(self.a, "marker_log", False):
                    # Frame k of the log carries marker k (tick mode), for stall analysis.
                    rec["host_frame_times"] = [[x["release_us"], x.get("sent_us")]
                                               for x in lines if x.get("release_us") is not None]
            if rec["ok"]:
                fps.append(rec["marker_fps"])
                # Motion trials release every frame, so their ledger holds the most frames.
                if rec.get("stage_ledger"):
                    self.summaries.append(rec["stage_ledger"])
                self.motion_rows.append(rec)
                if geo:
                    rec["quality"] = self.frame_score(snap, geo, origin)
                    self.scores.append(rec["quality"])
            self.log(rec)
        if not self.synthetic:
            self.rig({"cmd": "stop"})
        return firsts, g2g, fps, rows

    def motion_geometry(self):
        """The marker's motion layout from its log on the shared Mac, or None (and why)."""
        if self.synthetic:
            # No marker app: the generated picture has no motion-geometry to score against.
            self.quality_null = ("--source synthetic: the generated picture has no "
                                 "motion-geometry to score against")
            return None
        try:
            geo = motion_geometry(self.host.run(f"cat {self.root}/state/marker.log", timeout=30))
        except Exception as e:  # noqa: BLE001 - quality is null, the run goes on
            self.quality_null = f"could not read the marker's log: {repr(e)[-200:]}"
            return None
        if not geo:
            self.quality_null = ("the marker on the shared Mac predates motion-geometry "
                                 "(pass --tools or --marker-src from this tree)")
        return geo

    def frame_score(self, snap, geo, origin):
        cmd = (f"{self.py} {self.me} frame-score --ppm {snap} --delete --origin {origin[0]} "
               f"{origin[1]} --cell 32 --ocr {self.root}/bin/screen-eval-ocr "
               f"--geometry {shlex.quote(json.dumps(geo))}")
        try:
            return json.loads(self.viewer.run(cmd, timeout=120).strip().splitlines()[-1])
        except Exception as e:  # noqa: BLE001
            return {"frame_null": f"frame-score failed: {repr(e)[-200:]}"}

    def app(self, remote, app, action, *extra, timeout=None):
        """`screen-share-vs.py app ACTION` on REMOTE for the app bundle APP: its JSON reply."""
        # The rpc positionals (method, params) come before --app: argparse takes no optional
        # positional after an option.
        cmd = (f"{self.py} {self.me} app {action} "
               + "".join(shlex.quote(str(x)) + " " for x in extra) + f"--app {shlex.quote(app)}")
        return json.loads(remote.run(cmd, timeout=timeout or self.a.timeout).strip().splitlines()[-1])

    def app_rpc(self, remote, app, method, params, timeout=None):
        return self.app(remote, app, "rpc", method, json.dumps(params), timeout=timeout)

    def until(self, seconds, fn, step=1.0):
        """FN's first truthy value within SECONDS (a bounded poll of another Mac's socket)."""
        deadline = time.time() + seconds
        while True:
            value = fn()
            if value or time.time() >= deadline:
                return value
            time.sleep(step)  # bounded by SECONDS

    def host_device(self):
        """The hub device id of the shared Mac: --app-host-device, the host app's own id
        (--app-host-app), or the viewer's online shared device named like the host Mac."""
        a = self.a
        if a.app_host_device:
            return a.app_host_device, "--app-host-device"
        if a.app_host_app:
            st = self.app_rpc(self.host, a.app_host_app, "debug.device_hub", {"action": "state"})
            if st.get("this_device"):
                return st["this_device"], "--app-host-app this_device"
            raise RuntimeError(f"the host app has no hub device id: {st}")
        name = self.host.run("scutil --get ComputerName").strip()
        st = self.app_rpc(self.viewer, a.app_viewer, "debug.device_hub", {"action": "state"})
        hits = [d for d in st.get("devices") or []
                if d.get("name") == name and d.get("online") and d.get("shared") and not d.get("this")]
        if len(hits) != 1:
            raise RuntimeError(f"no single online shared hub device named {name!r} "
                               f"(pass --app-host-device): {st.get('devices')}")
        return hits[0]["id"], f"hub device named {name!r}"

    def open_app_pane(self, rec):
        """Launch the app viewer, open a full-control Mac Screen pane to the host through the
        app's control socket (debug.device_hub connect), and wait for its first frame. Fills
        REC; returns the pane's state row (window_pid, window_id, transport, ...)."""
        a = self.a
        env = []
        for e in a.app_viewer_env or []:
            env += ["--env", e]
        launch = self.app(self.viewer, a.app_viewer, "launch", "--state", f"{self.root}/state",
                          "--frame", a.app_viewer_frame, "--wait", "120",
                          *(["--encode-profile", APP_PROFILE[a.encode_profile]] if a.encode_profile else []),
                          *(["--background"] if a.app_viewer_background else []), *env,
                          timeout=a.timeout + 180)
        rec["launch"] = launch
        if launch.get("error"):
            raise RuntimeError(launch["error"])
        self.app_launched = not launch.get("reused")
        hub = self.until(120, lambda: (lambda st: st if st.get("signed_in") else None)(
            self.app_rpc(self.viewer, a.app_viewer, "debug.device_hub", {"action": "state"})), 2)
        if not hub:
            raise RuntimeError("the app viewer is not signed in to the hub "
                               "(pass --app-viewer-env CMUX_AUTH_CREDENTIALS_FILE=...)")
        device, rec["host_device_via"] = self.host_device()
        rec["host_device"] = device

        def tabs():
            st = self.app_rpc(self.viewer, a.app_viewer, "debug.mac_screen", {"action": "state"})
            return {t["tab"] for t in st.get("tabs") or []}

        before = tabs()
        # One connect: it opens a Mac Screen tab even when it answers "no pane", so a retry
        # would open a second tab that replaces the first session. The new tab is followed.
        rec["connect"] = self.app_rpc(self.viewer, a.app_viewer, "debug.device_hub",
                                      {"action": "connect", "device": device, "scope": "full"})
        new = self.until(15, lambda: tabs() - before) or set()
        if len(new) != 1:
            raise RuntimeError(f"connect opened {len(new)} Mac Screen tabs: {rec['connect']}")
        tab = next(iter(new))

        def ready():
            if a.app_host_app:
                st = self.app_rpc(self.host, a.app_host_app, "debug.device_hub", {"action": "state"})
                for req in st.get("pending_requests") or []:
                    self.app_rpc(self.host, a.app_host_app, "debug.device_hub",
                                 {"action": "decide", "session": req["id"], "choice": "always_full"})
            rows = self.app_rpc(self.viewer, a.app_viewer, "debug.mac_screen",
                                {"action": "state", "tab": tab}).get("tabs") or [{}]
            row = rows[0]
            ok = row.get("phase") == "connected" and row.get("has_frame") and row.get("window_id")
            return row if ok else None

        row = self.until(a.timeout, ready, 2)
        if not row:
            raise RuntimeError("the app's Mac Screen pane showed no frame of the host in "
                               f"{a.timeout:g} s (approve it on the host, or pass --app-host-app)")
        if row.get("session_scope") != "full":
            raise RuntimeError(f"the pane's session is {row.get('session_scope')!r}, not full control")
        if row.get("window_on_primary_display") is False:
            raise RuntimeError("the app's window is not on the main display (marker-locate reads -D 1)")
        rec["tab"] = tab
        return row

    def read_app_timings(self, tab):
        """The pane's own frame timings from `mac_screen.state` (every build; APP_TIMING_FIELDS, each a
        {count, p50, p95, max} of the last frames): decode, glass (decoded to on glass, the
        drawable's presentedHandler) and decode_present (released to on glass). Waits up to 30 s
        for a full window of APP_TIMING_WINDOW frames; a short window is kept and says so."""
        a = self.a
        last = {}

        def full():
            rows = self.app_rpc(self.viewer, a.app_viewer, APP_STATE_METHOD,
                                {"tab": tab}).get("tabs") or [{}]
            last.update(rows[0])
            dp = rows[0].get("decode_present_ms") or {}
            return rows[0] if (dp.get("count") or 0) >= APP_TIMING_WINDOW else None

        self.until(30, full, 1)
        timings = {k: last[k] for k in APP_TIMING_FIELDS if isinstance(last.get(k), dict)}
        if not timings.get("decode_present_ms"):
            return {"null": "the pane reported no decode_present_ms (an app before cmux#47235?)"}
        n = timings["decode_present_ms"].get("count") or 0
        if n < APP_TIMING_WINDOW:
            timings["short_window"] = n
        return timings

    def close_app_pane(self, rec):
        a = self.a
        row = rec.get("pane") or {}
        try:
            if row.get("hub_session"):
                rec["end"] = self.app_rpc(self.viewer, a.app_viewer, "debug.device_hub",
                                          {"action": "end", "session": row["hub_session"]})
            if getattr(self, "app_launched", False):
                # Only the app this run launched; a reused one keeps running.
                rec["quit"] = self.app_rpc(self.viewer, a.app_viewer, "action.run",
                                           {"id": "quitEndSessions"}, timeout=60)
        except Exception as e:  # noqa: BLE001
            rec["close_error"] = repr(e)[-300:]

    def run_presented(self):
        """Key press to the presented frame through a visible viewer pane on the viewing Mac
        (cmux-rd observe): the pane --presented-* name, or the cmux NEXT app's own Mac Screen
        pane that --app-viewer opens. The latencies in ms, or None."""
        a = self.a
        app_mode = bool(getattr(a, "app_viewer", None))
        if not app_mode and not (a.presented_pid and a.presented_window and a.presented_origin
                                 and a.presented_at):
            self.presented_source = {"null": "no --app-viewer or --presented-* flags"}
            return None
        if self.synthetic:
            # The pane would show the real display's marker app, which a synthetic run has not.
            self.presented_source = {"null": "--source synthetic runs no marker app"}
            self.log({"skipped": "presented", "why": "--source synthetic runs no marker app"})
            return None
        rec = {"stack": "cmux", "mode": "presented"}
        started = time.time()
        try:
            # A rig or app error costs this leg only, never the tables after it.
            if app_mode:
                rec["source"] = "app-viewer"
                row = rec["pane"] = self.open_app_pane(rec)
            self.rig({"cmd": "marker", "flags": []})
            time.sleep(0.5)
            if app_mode:
                loc = self.app(self.viewer, a.app_viewer, "locate", "--state", f"{self.root}/state",
                               "--locate", f"{self.root}/bin/screen-eval-marker-locate", "--wait", "10")
                if loc.get("error"):
                    raise RuntimeError(loc["error"])
                pid, window = row["window_pid"], row["window_id"]
                origin, cell, at = loc["origin"], loc["cell"], loc["at"]
            else:
                pid, window = a.presented_pid, a.presented_window
                origin, cell, at = a.presented_origin, a.presented_cell, a.presented_at
            self.presented_source = presented_source(
                "app-viewer" if app_mode else "presented-flags", pid=pid, window=window,
                origin=origin, cell=cell, at=at, input=a.presented_input,
                **({"app": a.app_viewer, "tab": rec.get("tab"), "host_device": rec.get("host_device"),
                    "transport": row.get("transport"), "path": row.get("path"),
                    "encode_profile": a.encode_profile,
                    "encode_profile_applied": (rec.get("launch") or {}).get("encode_profile_applied")}
                   if app_mode else {}))
            rec["presented_source"] = self.presented_source
            cmd = (f"{self.root}/bin/cmux-rd observe --pid {int(pid)} "
                   f"--window {int(window)} --input {a.presented_input} --samples {int(a.samples)} "
                   f"--cell-size {int(cell)} "
                   f"--marker-origin {shlex.quote(origin)} --at {shlex.quote(at)}")
            rec["observe"] = cmd
            rep = json.loads(self.viewer.run(cmd, timeout=self.a.timeout).strip().splitlines()[-1])
            rec["ok"] = rep.get("complete") is True
            rec["presented_ms"] = [x / 1000.0 for x in rep.get("samples_us") or []]
            rec.update({k: rep.get(k) for k in ("p50_ms", "p95_ms", "n", "method", "error")
                        if rep.get(k) is not None})
            if app_mode:
                self.app_timings = self.read_app_timings(rec.get("tab"))
                rec["app_timings"] = self.app_timings
                # The app's own stage ledger for this session (logged every 5 s, cumulative).
                time.sleep(5.5)
                led = self.app(self.viewer, a.app_viewer, "ledger", "--pid", int(pid),
                               "--since", f"{started:.0f}")
                self.app_ledger = ({"ledger": led["ledger"], "lines": led.get("lines")}
                                   if led.get("ledger") else
                                   {"null": led.get("error") or "the app logged no stage ledger"})
                rec["app_ledger_lines"] = led.get("lines")
        except Exception as e:  # noqa: BLE001
            rec.update({"ok": False, "error": repr(e)[-400:]})
            if self.presented_source is None:
                self.presented_source = {"null": f"{rec.get('source', 'presented-flags')}: {repr(e)[-200:]}"}
        finally:
            try:
                self.rig({"cmd": "stop"})  # the marker this leg started
            except Exception as e:  # noqa: BLE001
                rec["stop_error"] = repr(e)[-200:]
            if app_mode:
                self.close_app_pane(rec)
        self.log(rec)
        if not rec.get("ok") and self.presented_source and "null" not in self.presented_source:
            self.presented_source = {**self.presented_source, "error": rec.get("error") or "observe incomplete"}
        return rec["presented_ms"] if rec.get("ok") else None

    # macOS Screen Sharing -----------------------------------------------------------------

    def run_apple(self):
        if not (self.a.vnc_user and self.a.vnc_password_file):
            self.apple_skipped = "skipped: no --vnc-user / --vnc-password-file given"
            return None
        firsts, g2g, fps = [], [], []
        env = (f"VNC_USERNAME={shlex.quote(self.a.vnc_user)} "
               f"VNC_PASSWORD_FILE={shlex.quote(self.a.vnc_password_file)} ")
        for mode, trials, flags in (("key", self.a.trials, []),
                                    ("fps", self.a.fps_trials, ["--tick", "--motion"])):
            for n in range(1 - (self.a.warmup if mode == "key" else 0), trials + 1):
                origin = self.rig({"cmd": "marker", "flags": flags})["origin"]
                time.sleep(0.5)
                cmd = (env + f"{self.py} {self.me} rfb-bench --host {self.a.host_ip} "
                       f"--cua-vnc {self.root}/bin/cua-vnc --origin {origin[0]} {origin[1]} "
                       f"--cell 32 --mode {mode} --input {self.a.apple_input} --samples {self.a.samples} "
                       f"--duration-s {self.a.fps_seconds}")
                rec = {"stack": "apple", "mode": mode, "trial": n}
                try:
                    rep = json.loads(self.viewer.run(cmd, timeout=self.a.timeout).strip().splitlines()[-1])
                    rec.update(rep)
                    rec["ok"] = "error" not in rep
                except Exception as e:  # noqa: BLE001
                    rec.update({"ok": False, "error": repr(e)[-400:]})
                if n < 1:
                    rec["warmup"] = True
                self.log(rec)
                if n < 1:
                    time.sleep(2)
                    continue
                if rec["ok"]:
                    firsts.append(rec["first_frame_ms"])
                    if mode == "key":
                        g2g += rec["key_to_frame_ms"]
                    else:
                        fps.append(rec["marker_fps"])
                # Screen Sharing keeps a closed session's state for a moment.
                time.sleep(2)
        self.rig({"cmd": "stop"})
        self.apple_g2g = g2g
        return firsts, g2g, fps

    def main(self):
        if tailnet(self.a.host_ip):
            print(f"warning: --host-ip {self.a.host_ip} is a tailnet address. {TAILNET_UDP}",
                  file=sys.stderr, flush=True)
        self.setup()
        clock0 = self.clock()
        self.log({"clock": clock0, "host": self.a.host, "viewer": self.a.viewer,
                  "host_ip": self.a.host_ip, "link": self.a.link})
        results = {}
        stacks = self.a.stacks.split(",")
        rows = []
        if "cmux" in stacks:
            f, g, fps, rows = self.run_cmux(clock0)
            results["cmux Mac Screen" + (" (synthetic)" if self.synthetic else "")] = (f, g, fps)
            self.presented = self.run_presented()
        if "apple" in stacks and self.synthetic:
            # Screen Sharing shows the real display; the synthetic picture is cmux's alone.
            self.apple_skipped = "--source synthetic streams no display (cmux leg only)"
            self.log({"skipped": "apple", "why": "--source synthetic streams no display"})
        elif "apple" in stacks:
            r = self.run_apple()
            results["macOS Screen Sharing"] = r
        try:
            clock1 = self.clock()
            self.log({"clock_end": clock1,
                      "drift_ms": (clock1["offset_ns"] - clock0["offset_ns"]) / 1e6})
        except Exception as e:  # noqa: BLE001 - the drift check never costs the table
            self.log({"clock_end_error": repr(e)[-400:]})
        self.table(results, clock0, rows)
        self.budget(stacks, rows, clock0)

    def budget(self, stacks, rows, clock):
        """The design's budget table, printed and written as one {"budget"} line."""
        cmux = apple = None
        if "cmux" in stacks:
            cmux = {"rows": rows, "ledgers": self.ledgers, "summaries": self.summaries,
                    "presented": self.presented, "presented_source": self.presented_source,
                    "app_ledger": self.app_ledger, "app_timings": self.app_timings,
                    "motion_rows": self.motion_rows, "scores": self.scores,
                    "quality_null": self.quality_null}
        if "apple" in stacks:
            apple = {"skipped": self.apple_skipped} if self.apple_skipped else {"g2g": self.apple_g2g}
        b = build_budget(cmux, apple, label=self.a.label, rev=self.rev, link=self.a.link,
                         rtt=clock.get("rtt_min_ms"), source=self.a.source,
                         cmux_input=getattr(self.a, "cmux_input", "key"), host=self.a.host,
                         viewer=self.a.viewer, host_args=self.host_args,
                         viewer_args=self.viewer_args,
                         encode_profile=getattr(self.a, "encode_profile", None))
        print()
        print("\n".join(format_budget(b)))
        self.log({"budget": b})

    def table(self, results, clock, rows):
        rtt = clock.get("rtt_ms") or {}
        print()
        print(f"link {self.a.link} {self.a.host} -> {self.a.viewer} ({self.a.host_ip}): "
              f"udp rtt min {clock['rtt_min_ms']:.2f} ms, p50 {rtt.get('p50')} ms, p95 {rtt.get('p95')} ms")
        if self.host_args or self.viewer_args:
            print(args_text({"host_args": self.host_args, "viewer_args": self.viewer_args}))
        print(f"{'stack':<22} {'first_frame_ms p50/p95':>24} {'key_to_frame_ms p50/p95':>25} "
              f"{'fps (motion) p50':>17} {'n':>10}")
        summ = {}
        for name, r in results.items():
            if r is None:
                print(f"{name:<22} {'skipped: no VNC_USERNAME / VNC_PASSWORD_FILE given':>60}")
                continue
            f, g, fps = r
            sf, sg, sp = summary(f), summary(g), summary(fps)
            summ[name] = {"first_frame_ms": sf, "key_to_frame_ms": sg, "fps": sp}
            fmt = lambda s: f"{s['p50']:.1f} / {s['p95']:.1f}" if s else "-"  # noqa: E731
            print(f"{name:<22} {fmt(sf):>24} {fmt(sg):>25} {(sp['p50'] if sp else '-'):>17} "
                  f"{len(f)}tr/{len(g)}k")
        if self.motion_rows:
            m = self.motion_rows
            peak = [r["mbit_per_s_peak"] for r in m if r.get("mbit_per_s_peak") is not None]
            loss = [r["loss_pct_mean"] for r in m if r.get("loss_pct_mean") is not None]
            loss_max = [r["loss_pct_max"] for r in m if r.get("loss_pct_max") is not None]
            link = {"mbit_per_s_avg": round(statistics.mean(r["mbit_per_s"] for r in m), 2),
                    "mbit_per_s_peak": round(max(peak), 2) if peak else None,
                    "loss_pct_mean": round(statistics.mean(loss), 3) if loss else None,
                    "loss_pct_max": round(max(loss_max), 3) if loss_max else None}
            summ["cmux_motion_link"] = link
            print()
            print(f"cmux under motion ({len(m)} x {self.a.fps_seconds} s): received "
                  f"{link['mbit_per_s_avg']} Mbps avg, {link['mbit_per_s_peak']} Mbps peak (1 s); "
                  f"host loss {link['loss_pct_mean']} % mean, {link['loss_pct_max']} % max")

        def stage_table(title, rows, keys):
            print()
            print(title)
            stages = {}
            for k in keys:
                xs = [row[k] for row in rows if row.get(k) is not None]
                if xs:
                    stages[k] = {"p50": round(pct(xs, 50), 2), "p95": round(pct(xs, 95), 2),
                                 "mean": round(statistics.mean(xs), 2)}
                    print(f"  {k:<13} {stages[k]['p50']:>8} {stages[k]['p95']:>8} {stages[k]['mean']:>8}")
            return stages

        if rows:
            summ["cmux_breakdown"] = stage_table(
                "cmux key-to-frame breakdown (ms, viewer clock; p50 / p95 / mean over samples)", rows,
                ["up", "inject", "draw", "sck", "gate", "encode", "send", "first_packet", "down",
                 "decode", "total"])
        if self.ff_rows:
            summ["cmux_first_frame_breakdown"] = stage_table(
                "cmux first-frame breakdown (ms, viewer clock; p50 / p95 / mean over trials)",
                self.ff_rows, ["signal", "capture_start", "first_capture", "gate", "encode", "send",
                               "down", "decode", "total"])
        self.log({"summary": summ, "link": self.a.link, "rtt": clock})


def cmd_run(args):
    Orchestrator(args).main()


def app_env(text):
    """--app-viewer-env KEY=VALUE: only the app's own CMUX_* variables."""
    if not APP_ENV.fullmatch(text):
        raise argparse.ArgumentTypeError(f"{text!r}: want CMUX_NAME=value")
    return text


def build_parser():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run")
    r.add_argument("--host", required=True, help="the shared Mac (reach/ssh name)")
    r.add_argument("--viewer", required=True, help="the viewing Mac (reach/ssh name)")
    r.add_argument("--host-ip", required=True, help="the shared Mac's address on the measured link")
    r.add_argument("--link", default="wired", help="a label for the table")
    r.add_argument("--link-bind", help="bind the shared Mac's link socket to this address (its "
                   "Wi-Fi address when Ethernet shares the subnet), so both directions use it")
    r.add_argument("--via", choices=["reach", "ssh", "spool", "local"], default="reach",
                   help="spool: reach with no stdin (a lane VM's broker relay; SpoolRemote); "
                   "local: both Macs are this one (run the orchestrator on the shared Mac)")
    r.add_argument("--root", default="cmux-rd-test", help="relative to the remote home")
    r.add_argument("--python", default="/usr/bin/python3")
    r.add_argument("--bin", help="local cmux-rd (macOS arm64, features bench,link) to install")
    r.add_argument("--host-bin", help="install this on the shared Mac instead of --bin (for example a "
                   "script that execs a shipped app's `cmux rd`, so its serve is what is measured)")
    r.add_argument("--marker-src", help="local mac-marker/main.swift to build on the shared Mac")
    r.add_argument("--cua-vnc", help="local cua-vnc/bin/cua-vnc to install on the viewing Mac")
    r.add_argument("--rig-launch", choices=["cmux-next"], help="start the rig in cmux NEXT")
    r.add_argument("--stacks", default="cmux,apple")
    r.add_argument("--source", choices=["screen", "synthetic"], default="screen",
                   help="synthetic: the host streams a generated picture with the marker "
                   "(`cmux-rd serve --source synthetic-*`), input bumps the marker; no rig, "
                   "marker app or Screen Recording/Accessibility grant (cmux leg only)")
    r.add_argument("--synthetic-size", help="WxH of the synthetic picture (default 1920x1080)")
    r.add_argument("--marker-log", action="store_true",
                   help="fps trials keep every decoded marker change and, with --source synthetic, "
                   "the host's frame times (frame-by-frame recovery after a stall)")
    r.add_argument("--synthetic-scene", choices=["bars", "text", "noise", "churn"],
                   help="what the synthetic picture shows under the marker (default bars; text "
                   "and noise translate; churn is new content every frame)")
    r.add_argument("--host-arg", action="append", metavar="ARG",
                   help="an extra `cmux-rd serve` flag, repeatable, in the = form since it starts "
                        "with - (--host-arg=--resolution-ladder --host-arg=--max-qp=40); only "
                        + ", ".join(sorted(HOST_ARGS)) + " (a switch is sent as `--flag 1`)")
    r.add_argument("--viewer-arg", action="append", metavar="ARG",
                   help="an extra `cmux-rd bench` flag for the viewer, repeatable, in the = form "
                        "(--viewer-arg=--caps=video.scaled); only " + ", ".join(sorted(VIEWER_ARGS)))
    r.add_argument("--trials", type=int, default=10)
    r.add_argument("--warmup", type=int, default=1, help="uncounted key attempts first")
    r.add_argument("--fps-trials", type=int, default=3)
    r.add_argument("--samples", type=int, default=30)
    r.add_argument("--fps-seconds", type=int, default=10)
    r.add_argument("--max-fps", type=int, default=60)
    r.add_argument("--encode-profile", choices=("standard", "ultra"),
                   help="the cmux stack's profile, asked in the setup line as the app's viewer "
                        "asks it (default: none sent, so the host runs standard)")
    r.add_argument("--clock-count", type=int, default=200)
    r.add_argument("--timeout", type=float, default=120)
    r.add_argument("--vnc-user", default=os.environ.get("VNC_USERNAME"))
    r.add_argument("--vnc-password-file", help="path on the viewing Mac (0600)")
    r.add_argument("--out", help="JSON lines file; its last line is the budget table (`compare`)")
    r.add_argument("--label", help="before|after (or any name): written into the budget record")
    r.add_argument("--rev", help="the commit the tools were built at (default: --tools DIR/rev)")
    r.add_argument("--tools", help="an unpacked tools/ folder from screen-stream-eval.sh "
                   "tools-only=1: cmux-rd, cmux-rd-marker, screen-eval-ocr")
    r.add_argument("--apple-input", choices=["key", "click"], default="key",
                   help="the Apple leg's timed input (key: after one focus click on the pad)")
    r.add_argument("--cmux-input", choices=["key", "click", "scroll"], default="key",
                   help="the cmux leg's timed input: each kind goes through the host's injector and "
                   "bumps the marker (keyDown, mouseDown, scrollWheel)")
    r.add_argument("--presented-pid", type=int, help="a visible viewer pane's process on the "
                   "viewing Mac: Total then ends at the presented frame (cmux-rd observe)")
    r.add_argument("--presented-window", type=int, help="that pane's CGWindow id")
    r.add_argument("--presented-origin", help="X,Y: the marker in the viewing Mac's capture pixels")
    r.add_argument("--presented-cell", type=int, default=32, help="the marker cell in those pixels")
    r.add_argument("--presented-at", help="X,Y: the marker's gray pad in those pixels")
    r.add_argument("--presented-input", choices=("key", "click"), default="key",
                   help="the presented leg's timed input, posted to the pane's process (no pointer move)")
    r.add_argument("--app-viewer", metavar="APP", help="a cmux NEXT app bundle on the viewing Mac (DEV "
                   "or channel build): launch it (`open -n`), open its Mac Screen pane to the host "
                   "through its control socket, and end Total at the frame it presents")
    r.add_argument("--app-viewer-env", action="append", type=app_env, metavar="CMUX_KEY=VALUE",
                   help="extra launch environment for --app-viewer (repeatable), e.g. "
                   "CMUX_AUTH_CREDENTIALS_FILE=... to sign it in")
    r.add_argument("--app-viewer-frame", default="0,0,1500,950",
                   help="X,Y,W,H of the app's window (CMUX_NEXT_TEST_WINDOW_FRAME)")
    r.add_argument("--app-viewer-background", action="store_true",
                   help="launch it with `open -g` and CMUX_NEXT_NO_ACTIVATE=1 (its window then "
                   "opens behind others, and observe refuses an obscured pane)")
    r.add_argument("--app-host-device", help="the host's hub device id (default: --app-host-app's, "
                   "else the viewer's online shared device named like the host Mac)")
    r.add_argument("--app-host-app", metavar="APP", help="the sharing cmux NEXT app on the host: "
                   "its device id, and it approves the viewer's request (always full)")
    r.set_defaults(fn=cmd_run)
    ap_ = sub.add_parser("app", help="on the viewing Mac: drive a cmux NEXT app (--app-viewer)")
    ap_.add_argument("action", choices=("rpc", "launch", "locate", "ledger"))
    ap_.add_argument("method", nargs="?", help="rpc: the control socket method")
    ap_.add_argument("params", nargs="?", help="rpc: its params as JSON")
    ap_.add_argument("--app", required=True, help="the app bundle")
    ap_.add_argument("--state", default="~/.cache/cmux-rd-vs/state", help="launch/locate: scratch folder")
    ap_.add_argument("--env", action="append", type=app_env, help="launch: CMUX_KEY=VALUE")
    ap_.add_argument("--frame", help="launch: CMUX_NEXT_TEST_WINDOW_FRAME")
    ap_.add_argument("--background", action="store_true", help="launch: open -g, CMUX_NEXT_NO_ACTIVATE=1")
    ap_.add_argument("--encode-profile", choices=("balanced", "ultra"),
                     help="launch: remote.screenSharingProfile, through a CMUX_NEXT_CONFIG_FILE")
    ap_.add_argument("--wait", type=float, default=120, help="launch/locate: seconds")
    ap_.add_argument("--locate", help="locate: the screen-eval-marker-locate binary")
    ap_.add_argument("--pid", type=int, help="ledger: the app's process")
    ap_.add_argument("--since", type=float, help="ledger: epoch seconds")
    ap_.set_defaults(fn=cmd_app)
    m = sub.add_parser("compare", help="two result files side by side")
    m.add_argument("before")
    m.add_argument("after")
    m.add_argument("--json", action="store_true")
    m.set_defaults(fn=cmd_compare)
    fs = sub.add_parser("frame-score")
    fs.add_argument("--ppm", required=True)
    fs.add_argument("--geometry", required=True, help="the marker's motion-geometry JSON")
    fs.add_argument("--origin", type=int, nargs=2, required=True)
    fs.add_argument("--cell", type=int, default=32)
    fs.add_argument("--ocr", help="screen-eval-ocr; without it the text error is null")
    fs.add_argument("--delete", action="store_true", help="remove the PPM when done")
    fs.set_defaults(fn=cmd_frame_score)
    g = sub.add_parser("rig")
    g.add_argument("--root", default="~/cmux-rd-test")
    g.set_defaults(fn=cmd_rig)
    c = sub.add_parser("rig-call")
    c.add_argument("--root", default="~/cmux-rd-test")
    c.add_argument("request")
    c.set_defaults(fn=cmd_rig_call)
    s = sub.add_parser("clock-serve")
    s.add_argument("--bind", default="0.0.0.0")
    s.add_argument("--port", type=int, default=47123)
    s.add_argument("--seconds", type=float, default=30)
    s.set_defaults(fn=cmd_clock_serve)
    p = sub.add_parser("clock-probe")
    p.add_argument("--addr", required=True)
    p.add_argument("--count", type=int, default=200)
    p.add_argument("--gap-ms", type=float, default=5)
    p.set_defaults(fn=cmd_clock_probe)
    b = sub.add_parser("rfb-bench")
    b.add_argument("--host", required=True)
    b.add_argument("--port", type=int, default=5900)
    b.add_argument("--cua-vnc", required=True)
    b.add_argument("--origin", type=int, nargs=2, required=True)
    b.add_argument("--cell", type=int, default=32)
    b.add_argument("--mode", choices=["key", "fps"], default="key")
    b.add_argument("--input", choices=["key", "click"], default="key",
                   help="key mode's input: a key after one focus click, or a click on the pad")
    b.add_argument("--samples", type=int, default=30)
    b.add_argument("--duration-s", type=float, default=10)
    b.set_defaults(fn=cmd_rfb_bench)
    return ap


def main():
    args = build_parser().parse_args()
    args.fn(args)


if __name__ == "__main__":
    main()
