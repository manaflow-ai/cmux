"""One Cmd-T or Cmd-N, read from the frames of the screen (cmd-n-paint-e2e.py --screen).

The rule that this reads for: the first frame after the key shows the new tab or workspace with the New Tab page's
content where it stays, and nothing of the window changes after that frame. The frames are frame_strip's rows of a
recording made with `above` (ScreenCaptureKit: each frame that the window server composited for the display, with
its display time, the page's pixels in it). Each row has, for the pane's content area and for the window outside
the pane's content area and tab strip, the share of pixels unlike the picture before the key and unlike the last
picture of the recording (a later build's rows may carry the same two numbers for the tab strip).

For one key (`one_key`), counted in frames of the display after the key (frame 1 = the first frame composited
after it) and in ms:

  tab            Cmd-N: the first frame where the window outside the pane is unlike before the key (the sidebar's
                 new row). Cmd-T: the same for the tab strip, when the rows carry the strip; else it is known only
                 when the strip changed in one step together with the content (`source` says which).
  content_first  the first frame where the content area is unlike before the key and not blank
  content_final  the first frame from which the content area equals the last picture for good
  final          the first frame from which each region equals the last picture for good: the end of the last change
  changes_after_content  the frames after `content_first` in which a region is not at the last picture, and
                 `after_content`: those frames as runs, each with the state of each region (`before`, `between`: equal
                 to neither picture, `final`)

A key that comes `gap_ms` after another key in the same recording is counted from the time at which that second
key was due (the first key's time plus the gap: a person's key waits in the queue while the app works, so the wait
counts). The picture before is then the one before the FIRST key, so `tab` is the frame at which the tab's region
reached the last picture (both new tabs or rows drawn), and `content_first` is 1 when the first key's page is on
the screen already.

What this does not see. A region's change is not a move: a fade, a late text and a caret change pixels too. A
caret is named and left out: `blink` is a region that flips between the last picture and one other picture, by a
small share of its pixels, at a steady period. A change below `tolerance` of a region's pixels is not seen. Which
part moved, and by how many points, comes from the kept pictures.

A row is INVALID (`invalid`: each reason) when its frames are not the screen's, when the app's own records do not
say that each sent key opened one tab or workspace, or when the recording ended less than `settle_ms` after
`content_first`: nobody could say that nothing changed in that time.

`content_first` is chat_open_frames.py's first content frame (a click on a chat's row), for a key.
"""

# The share of a region's pixels at or under which two pictures are the same one. 20 times finer than frame_strip's
# default: at full scale a part of the page that moves by one point changes less than 0.2 % of the content area.
TOLERANCE = 0.0001
CAPTURE = "screencapturekit"
REGIONS = ("content", "outside", "strip")
# A caret: at most this share of a region, each phase this long (ms).
BLINK_SHARE = 0.002
BLINK_PHASE_MS = (250, 900)
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
    """A caret in `region`: after its last change of more than BLINK_SHARE, the region flips between the last picture
    and another one, each phase BLINK_PHASE_MS long. Returns the fact (`period_ms`, `share`, `phases`) and the ms of
    the frames that show the other picture, or (None, set())."""
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
    if len(runs) < 3 or not any(run[0] for run in runs):
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
    picture from there on), `between_frames` (equal to neither), `blink`, and each row's state."""
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
    final = len(rows)
    while final > 0 and states[final - 1] == "final":
        final -= 1
    # The last frame is the last picture by its name: a region that changed less than SETTLED_MS before it still
    # changed when the recording ended, and has no final frame.
    settled = final < len(rows) and rows[-1]["ms"] - rows[final]["ms"] >= SETTLED_MS
    return {"changed": first is not None, "first": _at(numbered, first), "final": _at(numbered, final) if settled else None,
            "settled": settled, "between_frames": states.count("between"), "blink": blink, "states": states}


def input_proof(key, keys_sent, opened, counted, spans):
    """The proof that the app took each sent key, in order, as one opening: its own opening records (`opened` more
    than before the recording), the count of tabs (Cmd-T) or workspaces (Cmd-N) (`counted` more), and its opening
    marks. Returns (faults, the time of each opening's first mark in ms after the first key)."""
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
    out = {"key": key, "gap_ms": gap_ms, "invalid": [], "capture": reply.get("capture"),
           "capture_error": reply.get("capture_error"), "spans": reply.get("spans") or []}
    if reply.get("capture") != CAPTURE:
        out["invalid"].append(f"capture: the frames are not the screen's ({reply.get('capture')!r}): the page is not in them")
    # The rows after the judged key, their ms from it (the second key's due time in a gap recording).
    after = sorted(({**f, "ms": f["ms"] - gap_ms} for f in reply.get("frames") or [] if _number(f.get("ms")) and f["ms"] > gap_ms),
                   key=lambda f: f["ms"])
    if not after or pair(after[0], "content") is None:
        out["invalid"].append("frames: no frame after the key with the content area's numbers")
        return out
    refresh, measured = refresh_of(after, asked_hz)
    refresh = refresh or 1000.0 / 60
    numbered = [(1 + round((row["ms"] - after[0]["ms"]) / refresh), row) for row in after]
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
    unsettled = sorted(name for name, region in known.items() if not region["settled"])
    finals = [region["final"] for region in known.values() if region["changed"] and region["final"]]
    out["final"] = None if unsettled else max(finals, key=lambda at: at["frame"], default=_at(numbered, 0))
    if unsettled:
        out["invalid"].append(f"frames: {', '.join(unsettled)} still changed at the recording's last frame")
    runs = []
    if first is not None:
        for index in range(first + 1, len(numbered)):
            state = {name: region["states"][index] for name, region in known.items()}
            if all(value == "final" for value in state.values()):
                continue
            frame, row = numbered[index]
            if runs and runs[-1]["state"] == state and runs[-1]["frames"][1] == numbered[index - 1][0]:
                runs[-1]["frames"][1], runs[-1]["ms"][1] = frame, row["ms"]
                runs[-1]["count"] += 1
            else:
                runs.append({"frames": [frame, frame], "ms": [row["ms"], row["ms"]], "count": 1, "state": state, "file": row.get("file")})
        quiet = after[-1]["ms"] - numbered[first][1]["ms"]
        if quiet < settle_ms:
            out["invalid"].append(f"frames: the take ended before {settle_ms / 1000:g} s after content_first ({quiet:.0f} ms after it)")
    else:
        out["invalid"].append("content: no frame of the take shows the content area unlike before the key and not blank")
    out["after_content"] = runs
    out["changes_after_content"] = sum(run["count"] for run in runs) if first is not None else None
    out["first_is_final"] = first is not None and not runs
    out["regions"] = {name: ({k: v for k, v in region.items() if k != "states"} if region else None) for name, region in regions.items()}
    out["blinks"] = [region["blink"] for region in known.values() if region["blink"]]
    # The pictures that say what each number means: the frame before the first key, the named frames, the last one.
    before = max((f for f in reply.get("frames") or [] if _number(f.get("ms")) and f["ms"] <= 0), key=lambda f: f["ms"], default={})
    out["pictures"] = {"before": before.get("file"), "last": after[-1].get("file"),
                       **{name: out[name]["file"] for name in ("tab", "content_first", "content_final", "final") if out[name]},
                       **{f"changed_{index}": run["file"] for index, run in enumerate(runs[:6])}}
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
           "first_is_final": sum(1 for row in good if row.get("first_is_final")),
           "changes_after_content": _spread([row.get("changes_after_content") for row in good]),
           "tab_known": sum(1 for row in good if row.get("tab")), "blinks": sum(1 for row in good if row.get("blinks")),
           "blank_frames": sum(row.get("blank_frames") or 0 for row in good),
           "refresh_ms": _spread([row.get("refresh_ms") for row in good])}
    for name in ("tab", "content_first", "content_final", "final"):
        out[name] = {unit: _spread([(row.get(name) or {}).get(unit) for row in good]) for unit in ("frame", "ms")}
    return out


def cell(summary):
    def said(name):
        frames, ms = summary[name]["frame"], summary[name]["ms"]
        return "none" if not frames else f"frame {frames['p50']:g} (max {frames['max']:g}), {ms['p50']:g} ms (max {ms['max']:g})"
    changes = summary["changes_after_content"]
    return (f"valid {summary['valid']}/{summary['n']}" + (f" (INVALID: {', '.join(summary['invalid'])})" if summary["invalid"] else "")
            + f"; tab {said('tab')} [known {summary['tab_known']}/{summary['valid']}]; content_first {said('content_first')}; "
            f"content_final {said('content_final')}; final {said('final')}; first=final {summary['first_is_final']}/{summary['valid']}; "
            f"frames changed after content p50 {changes['p50'] if changes else 'n/a'} max {changes['max'] if changes else 'n/a'}; "
            f"blank {summary['blank_frames']}; caret rows {summary['blinks']}")
