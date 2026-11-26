"""One Cmd-T or Cmd-N, read from the frames of the screen (cmd-n-paint-e2e.py --screen).

The rule that this reads for: the first frame after the key shows the new tab or workspace with the New Tab page's
content where it stays, and nothing of the window changes after that frame. The frames are frame_strip's rows of a
recording made with `above` (ScreenCaptureKit: each frame that the window server composited for the display, with
its display time, the page's pixels in it). Each row has, for the pane's content area and for the window outside
the pane's content area and tab strip, the share of pixels unlike the picture before the key and unlike the last
picture of the recording (a later build's rows may carry the same two numbers for the tab strip).

The zero of a row. frame_strip takes its key time AFTER the send of the key returned (DebugFrameStrip.swift), and
that send runs the key's own main thread work. So the reply's times count from the END of that work, and its
opening marks start before its zero. `one_key` moves the zero back to the time at which the key went in, when the
reply says it (`before_send_ms`: how long before the reply's zero the key or gesture went in; the key's router is
then in the numbers). A reply with no such number (a build from before it) has the start of the first key's
earliest opening mark as its zero (`cmdN.start`; `newTab.take` or `newTab.open`), and the time of the key's router
before that mark is then in no number. `key_work_ms` is the distance from the row's zero to the reply's zero, added
to each row's time before a frame is numbered, and `zero` names which of the two zeros the row has: rows with
unlike zeros are not one table. A reply with neither has no known zero: the row is INVALID.

For one key (`one_key`), counted in frames of the display after the key (frame 1 = the first frame composited
after it) and in ms:

  tab            Cmd-N: the first frame where the window outside the pane is unlike before the key (the sidebar's
                 new row). Cmd-T: the same for the tab strip, when the rows carry the strip; else it is known only
                 when the strip changed in one step together with the content (`source` says which).
  content_first  the first frame where the content area is unlike before the key and not blank
                 (`content_first_vs_before`: the share of the content area that is unlike before in that frame)
  content_final  the first frame from which the content area equals the last picture for good
  final          the first frame from which each region equals the last picture for good: the end of the last change
  changes_after_content  the frames after `content_first` in which a region is not at the last picture, and
                 `after_content`: those frames as runs, each with the state of each region (`before`, `between`: equal
                 to neither picture, `final`)
  first_is_final True: each region is at the last picture IN the `content_first` frame
                 (`content_first_is_last_picture`) and in each row after it. False: one is not. None (not known):
                 each is, but a frame of the display from the one before `content_first` on has no row
                 (`frames_not_seen_from_content`), so a change can be in it, or the strip is not seen.
  whole_window   True: the regions that the row judges are the whole window. The rows carry the tab strip's
                 numbers, or the reply says that the strip changed in one step with the content (no frame with the
                 strip at neither picture, no row with the strip and the content apart). False: the strip did not,
                 and the rows do not carry it (a build from before the strip's numbers; `strip_not_seen`). Then the
                 row has no `final`, a row with the page new and the strip old is a changed frame with its number,
                 and the reply's count of strip frames at neither picture (`strip_intermediate`), less the rows up
                 to `content_first`, is the lowest count of changed frames after it: a run with no frame number.
                 With 2 keys the reply counts from the first key: its rows up to the second key's due time (the
                 strip then has the first key's tab: neither picture) are taken off that count too.
                 `first_is_final` is then False, or not known when that count is 0: never True.

The frame number of a row is its time over the display's frame time, counted up for the first row and by the rows'
steps after it. The rows start at the last frame before the reply's zero (frame_strip's `before` picture), so a
frame of the display inside the key's own work has no row; such a frame, and a frame that the recorder did not
deliver, is still counted (`frames_not_delivered`: the frames after the key with no row). The display's frame time
is the asked rate's (`asked_hz`) when the rows' steps agree with it within 15 %. Rows that come slower than that
are not the display's frames: the row is INVALID. With no asked rate the frame time is the rows' own median step,
and a recorder that delivers each second frame of the display then gives half of the true numbers with no sign.

A key that comes `gap_ms` after another key in the same recording is counted from the time at which that second
key was due (the first key's zero plus the gap: a person's key waits in the queue while the app works, so the wait
counts). In a build whose reply has `before_send_ms`, frame_strip's timer for the second key counts from the time
the first key went in, so the second key is late only when the first key's work is longer than the gap. In a build
from before it the timer starts when the first key's work ended, so the second key goes in `key_work_ms` after its
due time at the earliest. That wait is in the row's numbers in both (`second_key_late_ms`). The picture before is
then the one before the FIRST key, so `tab` is the frame at which the tab's region reached the last picture (both
new tabs or rows drawn), and `content_first` is 1 when the first key's page is on the screen already.

What this does not see. A region's change is not a move: a fade, a late text and a caret change pixels too. A
caret is named and left out: `blink` is a region that, after its last larger change, is at the last picture and off
it by turns, at least 4 phases, off by a small share of its pixels each time (the shares are compared, the pictures
are not), at a steady period. A change below `tolerance` of a region's pixels is not seen. A change from another
cause (a terminal's cursor, a late line of a shell, a hover) that stays is taken as the key's. A picture that
changes after the recording's end is not seen: a region is at its last picture when it held it for the last
100 ms of the recording. Which part moved, and by how many points, comes from the kept pictures.

A row is INVALID (`invalid`: each reason) when its frames are not the screen's or not the display's, when its zero
is not known, when the app's own records do not say that each sent key opened one tab or workspace, when a region
went back to the picture before the key after its first change (that change was not the key's), or when the
recording ended less than `settle_ms` after `content_first`: nobody could say that nothing changed in that time.

`content_first` is chat_open_frames.py's first content frame (a click on a chat's row), for a key.
"""
import math

# The share of a region's pixels at or under which two pictures are the same one. 20 times finer than frame_strip's
# default: at full scale a part of the page that moves by one point changes less than 0.2 % of the content area.
TOLERANCE = 0.0001
CAPTURE = "screencapturekit"
REGIONS = ("content", "outside", "strip")
# The marks that open a key's own work, by key: the earliest of them is the row's zero.
OPENING_MARKS = {"n": ("cmdN.start",), "t": ("newTab.take", "newTab.open")}
ZERO = "the start of the first key's earliest opening mark"
ZERO_SENT = "the time at which the first key went in (the reply's before_send_ms)"
# A caret: at most this share of a region, each phase this long (ms), this many phases at least.
BLINK_SHARE = 0.002
BLINK_PHASE_MS = (250, 900)
BLINK_PHASES = 4
SETTLE_MS = 1000
# A region is at its last picture when it showed it for at least this long at the recording's end (ms).
SETTLED_MS = 100


def _number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def pair(row, region):
    """(share unlike before the key, share unlike the last picture) of `region` in one row, or None when the rows
    do not carry the region."""
    before, final = row.get(f"{region}_vs_before"), row.get(f"{region}_vs_final")
    return (before, final) if _number(before) and _number(final) else None


def key_work_of(key, spans):
    """ms from the start of the first key's earliest opening mark to the reply's zero (the reply takes its key time
    after the key's own work, so that mark starts before it), or None when the spans have no such mark."""
    starts = [span["ms"] for span in spans or [] if span.get("name") in OPENING_MARKS.get(key, ()) and _number(span.get("ms"))]
    return max(0.0, -min(starts)) if starts else None


def refresh_of(rows, asked_hz=None):
    """The display's frame time in ms. The rows' own steps (their times are whole ms, so the mean of the steps near
    the median one); the asked rate when the steps agree with it within 15 %."""
    steps = [b["ms"] - a["ms"] for a, b in zip(rows, rows[1:]) if b["ms"] > a["ms"]]
    measured = None
    if steps:
        middle = sorted(steps)[len(steps) // 2]
        near = [s for s in steps if 0.5 * middle <= s <= 1.5 * middle]
        measured = sum(near) / len(near)
    asked = 1000.0 / asked_hz if _number(asked_hz) and asked_hz > 0 else None
    if asked and (measured is None or abs(measured - asked) <= 0.15 * asked):
        return asked, measured
    return measured, measured


def blink_of(rows, region, tolerance):
    """A caret in `region`: after its last change of more than BLINK_SHARE, the region is at the last picture and off
    it by turns, BLINK_PHASES phases at least, each inner phase BLINK_PHASE_MS long (the first phase at most 2 times
    that and the last at most that, with no low limit: the last larger change and the recording's end cut them), the
    largest share off it at most 1.5 times the smallest. Returns the fact (`period_ms`, `share`, `phases`) and the ms
    of the frames that are off the last picture, or (None, set())."""
    series = [(row["ms"], pair(row, region)[1]) for row in rows if pair(row, region)]
    last_big = max((i for i, (_, v) in enumerate(series) if v > BLINK_SHARE), default=-1)
    tail = series[last_big + 1:]
    runs = []  # [off the last picture?, first ms, last ms, shares]
    for ms, value in tail:
        off = value > tolerance
        if runs and runs[-1][0] == off:
            runs[-1][2] = ms
            runs[-1][3].append(value)
        else:
            runs.append([off, ms, ms, [value]])
    inner = runs[1:-1]
    # 3 phases are also one change that goes away again: that is a change, not a caret.
    if len(runs) < BLINK_PHASES:
        return None, set()
    # A phase's length: from its first frame to the next phase's first frame.
    lengths = [runs[i + 2][1] - runs[i + 1][1] for i in range(len(inner))]
    low, high = BLINK_PHASE_MS
    edge_ok = (runs[0][2] - runs[0][1]) <= 2 * high and (runs[-1][2] - runs[-1][1]) <= high
    shares = [value for run in runs if run[0] for value in run[3]]
    if not edge_ok or any(not low <= length <= high for length in lengths) or max(shares) > 1.5 * min(shares):
        return None, set()
    fact = {"region": region, "period_ms": round(2 * sum(lengths) / len(lengths)), "share": round(max(shares), 6),
            "phases": len(runs)}
    return fact, {ms for ms, value in tail if value > tolerance}


def _at(numbered, index):
    return None if index is None else {"frame": numbered[index][0], "ms": numbered[index][1]["ms"], "file": numbered[index][1].get("file")}


def region_of(numbered, region, tolerance):
    """One region over the numbered rows after the key: `first` (unlike before the key), `final` (equal to the last
    picture from there on), `back` (the first row after `first` that equals the picture before the key again),
    `between_frames` (equal to neither), `blink`, and each row's state."""
    rows = [row for _, row in numbered]
    if not rows or any(pair(row, region) is None for row in rows):
        return None
    blink, blinking = blink_of(rows, region, tolerance)
    states = []
    for row in rows:
        before, final = pair(row, region)
        if final <= tolerance or row["ms"] in blinking:
            states.append("final")
        else:
            states.append("before" if before <= tolerance else "between")
    first = next((i for i, row in enumerate(rows) if pair(row, region)[0] > tolerance), None)
    back = None if first is None else next((i for i in range(first + 1, len(rows)) if states[i] == "before"), None)
    final = len(rows)
    while final > 0 and states[final - 1] == "final":
        final -= 1
    # The last frame is the last picture by its name: a region that changed less than SETTLED_MS before it still
    # changed when the recording ended, and has no final frame.
    settled = final < len(rows) and rows[-1]["ms"] - rows[final]["ms"] >= SETTLED_MS
    return {"changed": first is not None, "first": _at(numbered, first), "final": _at(numbered, final) if settled else None,
            "back": _at(numbered, back), "settled": settled, "between_frames": states.count("between"), "blink": blink,
            "states": states}


def opened_since(before, after):
    """How many opening records `after` has that `before` had not. The app keeps only its newest records
    (NewTabSparePool.maximumOpenings), so a full list keeps its length and loses its oldest ones: the count is the
    smallest one for which the rest of `after` is the end of `before`."""
    for new in range(len(after) + 1):
        kept = len(after) - new
        if kept <= len(before) and after[:kept] == before[len(before) - kept:]:
            return new
    return len(after)


def input_proof(key, keys_sent, opened, counted, spans):
    """The proof that the app took each sent key, in order, as one opening: its own opening records (`opened` more
    than before the recording), the count of tabs (Cmd-T) or workspaces (Cmd-N) (`counted` more), and its opening
    marks. Returns (faults, the time of each opening's first mark in ms after the reply's zero)."""
    mark = "cmdN.start" if key == "n" else "newTab.open"
    starts = sorted(span["ms"] for span in spans or [] if span.get("name") == mark and _number(span.get("ms")))
    faults = []
    if opened != keys_sent:
        faults.append(f"input: {keys_sent} keys sent, the app recorded {opened} openings")
    if counted != keys_sent:
        faults.append(f"input: {keys_sent} keys sent, {counted} more {'workspaces' if key == 'n' else 'tabs'} after them")
    if len(starts) != keys_sent:
        faults.append(f"input: {keys_sent} keys sent, {len(starts)} `{mark}` marks")
    return faults, starts


def one_key(reply, key, gap_ms=0, tolerance=TOLERANCE, asked_hz=None, settle_ms=SETTLE_MS):
    """One recording's numbers (the module doc). `reply` is frame_strip's; `gap_ms` > 0: two keys that far apart,
    counted from the second one's due time."""
    sent = reply.get("before_send_ms")
    said = _number(sent) and sent >= 0
    work = sent if said else key_work_of(key, reply.get("spans"))
    out = {"key": key, "gap_ms": gap_ms, "invalid": [], "capture": reply.get("capture"),
           "capture_error": reply.get("capture_error"), "spans": reply.get("spans") or [],
           "key_work_ms": work, "zero": ZERO_SENT if said else None if work is None else ZERO}
    if reply.get("capture") != CAPTURE:
        out["invalid"].append(f"capture: the frames are not the screen's ({reply.get('capture')!r}): the page is not in them")
    if work is None:
        out["invalid"].append("zero: the reply does not say when the key went in and the spans have no opening mark of the "
                              "first key: the time of the key's own work is not known")
    # The rows after the judged key, their ms from it: the reply's zero is the end of the first key's own work, and
    # the judged key is the first one, or the second one at its due time in a gap recording.
    shift = (work or 0) - gap_ms
    after = sorted(({**f, "ms": f["ms"] + shift} for f in reply.get("frames") or [] if _number(f.get("ms")) and f["ms"] + shift > 0),
                   key=lambda f: f["ms"])
    if not after or pair(after[0], "content") is None:
        out["invalid"].append("frames: no frame after the key with the content area's numbers")
        return out
    refresh, measured = refresh_of(after, asked_hz)
    refresh = refresh or 1000.0 / 60
    asked = 1000.0 / asked_hz if _number(asked_hz) and asked_hz > 0 else None
    if asked and measured and measured > 1.15 * asked:
        out["invalid"].append(f"refresh: the rows come each {measured:.2f} ms and the display's frame time is {asked:.2f} ms: "
                              "the rows are not each frame of the display")
    # The first row's own frame of the display (a frame before it with no row counts), then the rows' steps.
    lost = max(0, math.ceil((after[0]["ms"] - 0.5) / refresh) - 1)
    numbered = [(1 + lost + round((row["ms"] - after[0]["ms"]) / refresh), row) for row in after]
    out.update({"frames_after_key": len(after), "refresh_ms": round(refresh, 3),
                "refresh_measured_ms": None if measured is None else round(measured, 3),
                "frames_not_delivered": numbered[-1][0] - len(numbered), "take_ms": after[-1]["ms"],
                "blank_frames": sum(1 for row in after if row.get("blank"))})
    regions = {name: region_of(numbered, name, tolerance) for name in REGIONS}
    known = {name: region for name, region in regions.items() if region}
    content = regions["content"]
    first = next((i for i, (_, row) in enumerate(numbered)
                  if pair(row, "content")[0] > tolerance and not row.get("blank")), None)
    out["content_first"], out["content_final"] = _at(numbered, first), content["final"]
    out["content_first_vs_before"] = None if first is None else pair(numbered[first][1], "content")[0]
    for name, region in known.items():
        if region["back"]:
            out["invalid"].append(f"back: {name} went back to the picture before the key at frame {region['back']['frame']}, "
                                  f"after its first change at frame {region['first']['frame']}: that change was not the key's")
    # The tab or the workspace's row: an idle key's first frame unlike before; a second key's frame at the last picture.
    which = "outside" if key == "n" else "strip"
    tab, source = None, f"the rows' {which} numbers"
    if regions[which]:
        tab = regions[which]["final" if gap_ms else "first"]
    elif not reply.get("strip_intermediate") and not any(row.get("desync") for row in after) and not content["between_frames"]:
        tab, source = (content["final"] if gap_ms else content["first"]), "derived: the strip changed in one step with the content"
    else:
        source = (f"not known: the rows carry no strip numbers; {reply.get('strip_intermediate') or 0:.0f} frames of the "
                  f"strip equal neither picture, {sum(1 for row in after if row.get('desync'))} frames show the strip and the content apart")
    out["tab"], out["tab_source"] = tab, source
    # The strip in a build whose rows do not carry it: the reply still counts the frames with the strip at neither
    # picture and marks the rows with the strip and the content apart. A strip with neither changed in one step with
    # the content and is seen with it. One with either is not seen: the judged regions are then not the whole window.
    hidden = regions["strip"] is None
    slid = reply.get("strip_intermediate") if hidden and _number(reply.get("strip_intermediate")) else 0
    apart = {index for index, (_, row) in enumerate(numbered) if row.get("desync")} if hidden else set()
    whole = bool(regions["outside"]) and not (slid or apart)
    out["whole_window"] = whole
    out["strip_not_seen"] = None if whole or not hidden else {"frames_at_neither_picture": slid, "rows_apart": len(apart)}
    unsettled = sorted(name for name, region in known.items() if not region["settled"])
    finals = [region["final"] for region in known.values() if region["changed"] and region["final"]]
    # No `final` when the strip is not seen: the end of the last change is not in the rows.
    out["final"] = None if unsettled or not whole else max(finals, key=lambda at: at["frame"], default=_at(numbered, 0))
    if unsettled:
        out["invalid"].append(f"frames: {', '.join(unsettled)} still changed at the recording's last frame")
    runs, unseen = [], None
    if first is not None:
        for index in range(first + 1, len(numbered)):
            state = {name: region["states"][index] for name, region in known.items()}
            if index in apart:
                state["strip"] = "before"  # the page is new in this row (it is after content_first), so the strip is the old one
            if all(value == "final" for value in state.values()):
                continue
            frame, row = numbered[index]
            if runs and runs[-1]["state"] == state and runs[-1]["frames"][1] == numbered[index - 1][0]:
                runs[-1]["frames"][1], runs[-1]["ms"][1] = frame, row["ms"]
                runs[-1]["count"] += 1
            else:
                runs.append({"frames": [frame, frame], "ms": [row["ms"], row["ms"]], "count": 1, "state": state, "file": row.get("file")})
        # The strip's frames at neither picture: the rows up to content_first can be `first + 1` of them at most, and
        # each row from the reply's zero to the judged key (a gap recording: the first key's tab is in the strip) can be one.
        skipped = sum(1 for f in reply.get("frames") or [] if _number(f.get("ms")) and f["ms"] >= 0 and f["ms"] + shift <= 0)
        later = max(0, int(slid) - skipped - first - 1)
        if later:
            runs.append({"frames": None, "ms": None, "count": later, "state": {"strip": "between"}, "file": None,
                         "source": "the reply's strip_intermediate, less the rows up to content_first: the rows carry no "
                                   "strip numbers, so the frames are not known and the count is the lowest one"})
        quiet = after[-1]["ms"] - numbered[first][1]["ms"]
        if quiet < settle_ms:
            out["invalid"].append(f"frames: the take ended before {settle_ms / 1000:g} s after content_first ({quiet:.0f} ms after it)")
        # The frames of the display with no row, from the row before content_first (or from the key) to the end.
        unseen = numbered[-1][0] - (numbered[first - 1][0] if first else 0) - (len(numbered) - first)
    else:
        out["invalid"].append("content: no frame of the take shows the content area unlike before the key and not blank")
    out["after_content"] = runs
    out["changes_after_content"] = sum(run["count"] for run in runs) if first is not None else None
    out["frames_not_seen_from_content"] = unseen
    # The content_first frame itself: each region that the rows carry is at its last picture in it. A page that is
    # half drawn in that frame, or a sidebar row that comes one frame later, is a change after the first content.
    at_first = first is not None and first not in apart and all(region["states"][first] == "final" for region in known.values())
    # None: no content, or each judged region is at its last picture in that frame and the strip is not seen.
    out["content_first_is_last_picture"] = None if first is None or (at_first and not whole) else at_first
    # None: not known. No row shows a change, but a frame with no row can hold one, or the strip is not seen.
    out["first_is_final"] = False if first is None or runs or not at_first else (None if unseen or not whole else True)
    out["regions"] = {name: ({k: v for k, v in region.items() if k != "states"} if region else None) for name, region in regions.items()}
    out["blinks"] = [region["blink"] for region in known.values() if region["blink"]]
    # The pictures that say what each number means: the picture that the app compares with (its last frame before the
    # reply's zero), the named frames, the last one.
    before = max((f for f in reply.get("frames") or [] if _number(f.get("ms")) and f["ms"] <= 0), key=lambda f: f["ms"], default={})
    out["pictures"] = {"before": before.get("file"), "last": after[-1].get("file"),
                       **{name: out[name]["file"] for name in ("tab", "content_first", "content_final", "final") if out[name]},
                       **{f"changed_{index}": run["file"] for index, run in enumerate(runs[:6]) if run["file"]}}
    return out


def _spread(values):
    values = sorted(v for v in values if _number(v))
    if not values:
        return None
    middle = len(values) // 2
    median = values[middle] if len(values) % 2 else (values[middle - 1] + values[middle]) / 2
    return {"p50": median, "max": values[-1]}


def summarize(rows):
    """One case's keys (one key and one gap): counts, and p50 and max over the VALID rows of each frame number."""
    good = [row for row in rows if not row.get("invalid")]
    out = {"n": len(rows), "valid": len(good), "invalid": sorted({reason.split(":")[0] for row in rows for reason in row.get("invalid") or []}),
           "first_is_final": sum(1 for row in good if row.get("first_is_final") is True),
           "first_is_final_not_known": sum(1 for row in good if row.get("first_is_final") is None),
           "whole_window": sum(1 for row in good if row.get("whole_window") is True),
           "changes_after_content": _spread([row.get("changes_after_content") for row in good]),
           "tab_known": sum(1 for row in good if row.get("tab")), "blinks": sum(1 for row in good if row.get("blinks")),
           "blank_frames": sum(row.get("blank_frames") or 0 for row in good),
           "refresh_ms": _spread([row.get("refresh_ms") for row in good]),
           "key_work_ms": _spread([row.get("key_work_ms") for row in good]),
           "zero": sorted({row["zero"] for row in good if row.get("zero")})}
    for name in ("tab", "content_first", "content_final", "final"):
        out[name] = {unit: _spread([(row.get(name) or {}).get(unit) for row in good]) for unit in ("frame", "ms")}
    return out


def cell(summary):
    def said(name):
        frames, ms = summary[name]["frame"], summary[name]["ms"]
        return "none" if not frames else f"frame {frames['p50']:g} (max {frames['max']:g}), {ms['p50']:g} ms (max {ms['max']:g})"
    changes, work, zeros = summary["changes_after_content"], summary["key_work_ms"], summary.get("zero") or []
    return (f"valid {summary['valid']}/{summary['n']}" + (f" (INVALID: {', '.join(summary['invalid'])})" if summary["invalid"] else "")
            + f"; tab {said('tab')} [known {summary['tab_known']}/{summary['valid']}]; content_first {said('content_first')}; "
            f"content_final {said('content_final')}; final {said('final')}; first=final {summary['first_is_final']}/{summary['valid']} "
            f"(not known {summary['first_is_final_not_known']}); whole window seen {summary['whole_window']}/{summary['valid']}"
            + ("" if summary["whole_window"] == summary["valid"] else " (THE STRIP IS NOT SEEN in the others: their changed frames are a lowest count)")
            + "; "
            f"frames changed after content p50 {changes['p50'] if changes else 'n/a'} max {changes['max'] if changes else 'n/a'}; "
            f"the key's own work p50 {work['p50'] if work else 'n/a'} ms max {work['max'] if work else 'n/a'}; "
            f"blank {summary['blank_frames']}; caret rows {summary['blinks']}"
            + ("" if not zeros else f"; zero: {zeros[0]}" if len(zeros) == 1 else f"; ROWS OF {len(zeros)} ZEROS (their times are not one table): {' / '.join(zeros)}"))
