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
is the asked rate's (`asked_hz`), also when the rows come slower than it (`refresh_of`). With no asked rate the
frame time is the rows' own median step: a recorder that delivers each second frame of the display then gives
half of the true numbers, and a frame with no row is not seen. `one_key` alone gives no sign of it, so the mode
(new_surface_screen.py) makes each row of a run with no asked rate INVALID (`NO_RATE`, the reason `display`), and
the row's line and the case's line then say `not known` for the frames with no row. `rows_ms` is each row's time
after the judged key.

An asked rate that is lower than the display's has the same fault: the frame numbers are too small and a frame
with no row is not seen. The rows can prove that an asked rate is too LOW, and `rate_fault` does (the reason
`display`): the smallest time of `RATE_STEPS` steps one after the other in the whole recording (`rate_share`: that
time over as many asked frame times; a row with a frame after the key whose recording has 9 rows or more has it,
valid or not) is below `RATE_SHARE`. One
step alone is no proof: a row's time has a jitter of some ms, and a recording at the right rate has single steps
of half a frame time, each next to a long one. A rule that cannot judge does not pass: a recording with too few
rows for that sum is INVALID too, and so is one with no `RATE_STEPS` steps one after the other whose rows come at
the asked rate (`rate_on_grid`; the reason says `not judged`): rows that come slower than the asked rate, or at
steps that are not even, prove no rate. So the check needs 9 rows in 9 frames of the display one after the other;
with one frame with no row in them it judges only rows with nearly no jitter. The check has a limit, and the head
of a report with an asked rate says it (`rate_limit_sentence`): an asked rate that is wrong by about
`1 - RATE_SHARE` or less passes, a rate that is too low is found only when enough rows come one after the other at
the display's own rate, and the rows cannot prove that an asked rate is
RIGHT: a 120 Hz display whose pictures come each second frame gives the rows of a 60 Hz display. The true rate is
the display's own, which the entry makes.

A frame with no row. The recorder gives a row for each picture that the window server made and for each time
that it says that nothing changed, and it does not give one for each frame of the display: in the still part of a
recording its rows come at its own pace. So the rows' step over the whole recording says nothing about the part
that moves, and a rule is needed for that part alone:

  first_frame_span  the frames from the key to `content_first`: how many, how many with no row and which, the
                 longest step between two rows, and `early_ms_at_most` (`span_of`). A frame with no row is
                 directly before the first content row when no row of the old picture is between them (a blank
                 row is not the old picture). The page can have come in one of those, so the row is then
                 INVALID (`no-row`), and `early_ms_at_most` and the reason say how early the page can have been:
                 the time from the FIRST of those frames to the first content row (a count of frame times, not
                 the count of the frames with no row: a blank row between them counts too). A frame with no row
                 that is before a row of the old picture (a frame inside the key's own work is one) cannot be the
                 page's first frame: the row stays valid for its TIME.
  partial_state_not_seen  the frames from the key to `content_first` with no row, each of them. What such a
                 frame showed is not known: a page that came and went again in it is not seen. A row that is
                 valid for its time with a count above 0 here does not prove that no frame had a partial state.
  refresh_moving_ms  the step of the rows from the key to `content_final`, when there are 4 of them at least. A
                 step of more than 1.15 frame times there is INVALID (`refresh`). The still part is not judged.

A key that comes `gap_ms` after another key in the same recording is counted from the time at which that second
key was due (the first key's zero plus the gap: a person's key waits in the queue while the app works, so the wait
counts). In a build whose reply has `before_send_ms`, frame_strip's timer for the second key counts from the time
the first key went in, so the second key is late only when the first key's work is longer than the gap. In a build
from before it the timer starts when the first key's work ended, so the second key goes in `key_work_ms` after its
due time at the earliest. That wait is in the row's numbers in both (`second_key_late_ms`). The picture before is
then the one before the FIRST key, so `tab` is the frame at which the tab's region reached the last picture (both
new tabs or rows drawn), and `content_first` is 1 when the first key's page is on the screen already. The second
key's OWN first frame is `second_first` (`second_first_of`): the first row after the start of that key's own
opening mark in which the tab's region is unlike the row before it, with its frames with no row as for
`content_first` (INVALID with one that is not before a row in which the region did not move). The rows carry only each region's shares unlike two pictures, so a change
that keeps both shares is not seen, and a change of the first key's that still runs at the mark is taken as the
second key's (`moving_at_the_mark` says that it ran).

What this does not see. A region's change is not a move: a fade, a late text and a caret change pixels too. A
caret is named and left out: `blink` is a region that, after its last larger change, is at the last picture and off
it by turns, at least 4 phases, off by a small share of its pixels each time (the shares are compared, the pictures
are not), at a steady period. A change below `tolerance` of a region's pixels is not seen. A change from another
cause (a terminal's cursor, a late line of a shell, a hover) that stays is taken as the key's. A picture that
changes after the recording's end is not seen: a region is at its last picture when it held it for the last
100 ms of the recording. Which part moved, and by how many points, comes from the kept pictures.

A row is INVALID (`invalid`: each reason) when its frames are not the screen's or not the display's, when a frame
from the key to its first frame has no row, when its zero is not known, when the app's count of tabs or workspaces
and its opening marks do not say that each sent key opened one tab or workspace (`input_proof`), when a region
went back to the picture before the key after its first change (that change was not the key's), or when the
recording ended less than `settle_ms` after `content_first`: nobody could say that nothing changed in that time.

`content_first` is chat_open_frames.py's first content frame (a click on a chat's row), for a key.

A Close Tab key (`w`; `close_of`, with the pane's tabs before and after the keys). The same frames, read for a
close: the picture before is the one at the Close Tab key, the content region's first change is the frame in which
the closed tab's content is gone (`content_gone`: a blank frame counts), `content_final` is the frame from which
the content of the tab that shows stays (`content_shown`), and the strip's first change is `strip_first`; `order`
says which of the two changed first, in frames. A first change with frames with no row directly before it is the
LATEST frame of that change, not a proved one (`strip_first_can_be_frames_earlier`,
`content_gone_can_be_frames_earlier`: the count of those frames): `order` then gives the range of frames, says
`not proved` when the range does not say which one was first, and the row's line and the case's line say so. A
row is not INVALID for it: Rule 1 is for `content_first`. Which tab closed and which tab shows come from the app's list of
the pane's tabs, by the tabs' ids and places, not from the pictures. The key has no opening mark, so its zero is
only the reply's `before_send_ms`. What a close's row does not see: two tabs with one picture (a New Tab page
after a New Tab page) leave the content region with no change, and the row then says so and has no
`content_gone` (the reader's `content:` reason for an opening is then no fault: `not_a_fault_for_a_close`); with
New Tab keys before the Close Tab key in the same recording, a change of a New Tab key that still runs at the
Close Tab key is taken as the Close Tab key's (`new_tab_change_can_be_in_the_frames`), and the app's marks give
the true time between the keys only for the New Tab keys that went in after the recording's start
(`new_tab_marks_before_ms`: each `newTab.open` mark's start before the Close Tab key went in).
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
# The INVALID reason of each row of a run with no asked display rate (the mode adds it; the module doc).
NO_RATE = ("display: no asked display rate (`--display-hz`; the entry gives it with `--vdisplay=HZ`): the frame time is the "
           "rows' own median step, so a frame with no row is not seen and a frame's number can be too small")


# The asked rate against the rows: the steps one after the other whose time is judged, the share of as many asked
# frame times under which the display runs faster than the asked rate, and the share under which a take's head
# says that the margin is small. `RATE_SHARE` is the one limit: of the INVALID decision, of the frame time that
# `refresh_of` takes, and of the rows that `rate_on_grid` takes as rows at the asked rate. So an asked rate that
# is wrong by about 15 % or less passes (the rows' times are whole ms, which moves the limit by about 1 %: with a
# 120 Hz display 102 asked is INVALID and 139 asked passes); what the check does not find is in `rate_limit_sentence`.
RATE_STEPS, RATE_SHARE, RATE_MARGIN = 8, 0.85, 0.88
# Why the counts of frames with no row are not known, for a row or a case with a `display` reason.
NO_RATE_SAID, RATE_NOT_PROVED_SAID = "no asked display rate", "the asked display rate is not proved"


def _number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def asked_rate(value):
    """The asked display rate in Hz, or None when `value` is no rate: only a finite number above 0 is one (`inf` is none:
    its frame time is 0; so is a whole number that is too large for a float)."""
    try:
        return value if _number(value) and math.isfinite(value) and value > 0 else None
    except OverflowError:
        return None


def rate_share(timed, asked):
    """The smallest time of RATE_STEPS steps one after the other in the rows `timed` (each row of the recording, in
    the order of their times), over as many frame times `asked` (ms). None: no asked rate, or too few rows."""
    times = [row["ms"] for row in timed]
    if not asked or len(times) <= RATE_STEPS:
        return None
    return round(min(b - a for a, b in zip(times, times[RATE_STEPS:])) / (RATE_STEPS * asked), 3)


def rate_on_grid(timed, asked):
    """True when RATE_STEPS steps one after the other of the rows `timed` come at the asked rate: each of those rows
    has an error against a row for each frame time `asked` (ms) from the first of them, and the largest error less
    the smallest one is `1 - RATE_SHARE` of the steps' asked time together or less (1.2 frame times: the room that
    the sum's limit gives). So one row 0.7 late and one row 0.7 early are not at the rate. Only such rows say
    something of the rate: a sum of long and short steps can pass the limit at each rate. The rows are 9 rows in 9
    frames of the display: one frame with no row in them takes 1.0 of the room, so only rows with nearly no jitter
    pass with it."""
    times = [row["ms"] for row in timed]
    room = (1 - RATE_SHARE) * RATE_STEPS * asked
    for start in range(len(times) - RATE_STEPS):
        off = [times[start + step] - times[start] - step * asked for step in range(RATE_STEPS + 1)]
        if max(off) - min(off) <= room:
            return True
    return False


def rate_fault(timed, asked, refresh):
    """The INVALID reason `display` of a recording whose rows do not agree with the asked frame time `asked` (ms),
    or None (also with no asked rate: the mode gives that reason). `refresh`: the frame time that `refresh_of` took."""
    if not asked:
        return None
    share, low = rate_share(timed, asked), f"{round((1 - RATE_SHARE) * 100):g} %"
    if share is None:
        return (f"display: the recording has {len(timed)} rows, fewer than the {RATE_STEPS + 1} that the check of the asked "
                f"display rate needs ({RATE_STEPS} steps one after the other): the rate is not proved")
    if share < RATE_SHARE:
        return (f"display: {RATE_STEPS} steps one after the other of the rows took {share:g} of {RATE_STEPS} asked frame times "
                f"({asked:.2f} ms each; under {RATE_SHARE:g}): the display runs faster than the asked rate, so a frame with "
                f"no row is not seen and a frame's number can be too small")
    if refresh != asked:
        return (f"display: the rows come faster than the asked rate by more than {low}, so the frame time is the rows' own "
                f"median step ({refresh:.2f} ms; asked {asked:.2f} ms): a frame with no row is not seen")
    if not rate_on_grid(timed, asked):
        return (f"display: the asked rate is not judged: no {RATE_STEPS} steps one after the other of the recording's "
                f"{len(timed)} rows come at the asked rate ({asked:.2f} ms each; the sum of {RATE_STEPS} steps is {share:g} of "
                f"{RATE_STEPS} asked frame times at the least: the rows come slower than the asked rate, or their steps are not even)")
    return None


def rate_not_known(reasons):
    """Why the counts of frames with no row are not known for a row with the INVALID `reasons`, or None when they
    are known: a row with a `display` reason has a frame time that does not see such a frame."""
    if NO_RATE in (reasons or []):
        return NO_RATE_SAID
    return RATE_NOT_PROVED_SAID if any(reason.split(":")[0] == "display" for reason in reasons or []) else None


def rate_margin_sentence(rows):
    """One sentence for a report's head when a VALID row of `rows` has a `rate_share` under RATE_MARGIN, or None."""
    valid = [row for row in rows if not row.get("invalid")]
    small = [row for row in valid if _number(row.get("rate_share")) and row["rate_share"] < RATE_MARGIN]
    if not small:
        return None
    least = min(small, key=lambda row: row["rate_share"])
    return (f"THE ASKED DISPLAY RATE HAS A SMALL MARGIN: in {len(small)} of the {len(valid)} valid rows the smallest time of "
            f"{RATE_STEPS} steps one after the other is below {RATE_MARGIN:g} of {RATE_STEPS} asked frame times (the smallest: "
            f"{least['rate_share']:g} in {least.get('label')}; below {RATE_SHARE:g} a row is INVALID by `display`)")


def rate_limit_sentence(asked_hz):
    """One sentence for the head of a report with an asked display rate (None with none): what the check of the
    asked rate against the rows finds, and what it does not find."""
    if not asked_rate(asked_hz):
        return None
    low, rows = f"{round((1 - RATE_SHARE) * 100):g} %", RATE_STEPS + 1
    return (f"the asked display rate ({asked_hz:g} Hz) against the rows: a row is INVALID by `display` when {RATE_STEPS} steps one "
            f"after the other of its rows took less than {RATE_SHARE:g} of {RATE_STEPS} asked frame times, and when no {rows} rows one "
            f"after the other come at the asked rate (not judged; {rows} rows in {rows} frames of the display are what the check "
            f"needs: with one frame with no row in them it judges only rows with nearly no jitter); an asked rate that is too low "
            f"is found only when enough rows come one after the other at the display's own rate ({rows} are enough for an error "
            f"above about {low}): rows that come each 2nd or 3rd frame of a faster display pass, and rows with steps of 1 and 2 "
            f"frames by turns can pass; an error of about {low} or less is not found (rows of a 132 Hz display with 120 asked "
            f"pass with no word)")


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
    """(the display's frame time, the rows' own step), in ms. The rows' own step: their times are whole ms, so the
    mean of the steps near the median one. The frame time is the asked rate's when one is given: rows that come
    slower than it are frames with no row, and a frame's number stays the display's. Only rows that come FASTER
    than the asked rate by more than 15 % (a step under `RATE_SHARE` of the asked frame time) say that the display
    does not run at it: the frame time is then the rows' own step, as with no asked rate."""
    steps = [b["ms"] - a["ms"] for a, b in zip(rows, rows[1:]) if b["ms"] > a["ms"]]
    measured = None
    if steps:
        middle = sorted(steps)[len(steps) // 2]
        near = [s for s in steps if 0.5 * middle <= s <= 1.5 * middle]
        measured = sum(near) / len(near)
    asked = 1000.0 / asked_hz if asked_rate(asked_hz) else None
    if asked and (measured is None or measured >= RATE_SHARE * asked):
        return asked, measured
    return measured, measured


def span_of(inside, refresh, start_frame=0, start_ms=0.0, old=None):
    """The frames of the display after `start_frame` (0: the key) up to the last of the numbered rows `inside`:
    how many there are (`frames`), how many have a row (`rows`), how many have none (`no_row`, and which:
    `no_row_frames`, the first 32), the longest time between two rows one after the other, the span's start as the
    first time (`longest_gap_ms`), and `early_ms_at_most`: the time from the FIRST frame with no row after the last
    row that still shows the old state (`old`: the frames of those rows; None: each row before the last one) to the
    last row, in ms (0 with no such frame). What the last row is the first to show can have been on the screen that
    much earlier and no more: that row of the old state does not show it, and a frame with no row before it cannot
    be the first one. It is not the count of those frames: a row between them that is not of the old state (a blank
    row) does not prove that the frame before it did not show it."""
    have = {frame for frame, _ in inside}
    last = inside[-1][0]
    missing = [frame for frame in range(start_frame + 1, last + 1) if frame not in have]
    times = [start_ms] + [row["ms"] for _, row in inside]
    floor = max([frame for frame, _ in inside[:-1] if old is None or frame in old] + [start_frame])
    return {"frames": last - start_frame, "rows": len(have), "no_row": len(missing), "no_row_frames": missing[:32],
            "longest_gap_ms": round(max(b - a for a, b in zip(times, times[1:])), 1),
            "early_ms_at_most": round(max([last - frame for frame in missing if frame > floor] + [0]) * refresh, 1)}


def no_row_fault(span, start, name):
    """The INVALID reason of a span in which what its last row is the first to show can have come in a frame with
    no row (`early_ms_at_most` above 0), or None. A span whose frames with no row are each before a row of the old
    state has none: its time is proved."""
    if not span or not span["early_ms_at_most"]:
        return None
    return (f"no-row: {span['no_row']} of the {span['frames']} frames from {start} to {name} have no row (frames "
            f"{', '.join(map(str, span['no_row_frames']))}; the longest step between rows {span['longest_gap_ms']:g} ms): "
            f"{name} can be at most {span['early_ms_at_most']:g} ms early")


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


def records_range(key, keys_sent):
    """The fewest and the most opening records that `keys_sent` keys can make (NewTabSparePool's list). The pool
    records a page that it gives with a refill at once, and not a page that it gives as idle work. A Cmd-T: one
    record for each key, and one more for each new tab whose page was not the spare (the cold page's own view asks
    the pool again). A Cmd-N: none for a key that took the workspace that the app reserved at idle (that page left
    the pool as idle work), else one, and one more at most from the page's own view."""
    return (keys_sent if key == "t" else 0), 2 * keys_sent


def records_fact(key, keys_sent, spare):
    """The app's opening records of one recording (`spare`: each new record's flag, in order) as a fact by kind.
    It is no proof of the input: `input_proof` takes only a count outside `records_range` as a fault."""
    low, high = records_range(key, keys_sent)
    fact = {"count": len(spare), "spare": list(spare), "possible": [low, high]}
    if key == "t":
        fact["more_than_the_keys"] = len(spare) - keys_sent  # the new tabs that also asked the pool from their own view
    else:
        fact["keys_with_no_record"] = max(0, keys_sent - len(spare))  # at least: the keys that took a reserved workspace
    return fact


def input_proof(key, keys_sent, opened, counted, spans):
    """The proof that the app took each sent key, in order, as one opening: the count of tabs (Cmd-T) or workspaces
    (Cmd-N) (`counted` more than before the recording) and its opening marks, one of each for each key. The app's
    own opening records (`opened` more) are a fact by kind (`records_fact`), and a fault only when their count is
    one that the keys cannot make (`records_range`). Returns (faults, the time of each opening's first mark in ms
    after the reply's zero)."""
    mark = "cmdN.start" if key == "n" else "newTab.open"
    starts = sorted(span["ms"] for span in spans or [] if span.get("name") == mark and _number(span.get("ms")))
    faults = []
    low, high = records_range(key, keys_sent)
    if not low <= opened <= high:
        faults.append(f"input: {keys_sent} keys sent, the app recorded {opened} openings ({low} to {high} are possible for Cmd-{key.upper()})")
    if counted != keys_sent:
        faults.append(f"input: {keys_sent} keys sent, {counted} more {'workspaces' if key == 'n' else 'tabs'} after them")
    if len(starts) != keys_sent:
        faults.append(f"input: {keys_sent} keys sent, {len(starts)} `{mark}` marks")
    return faults, starts


def second_first_of(key, gap_ms, every, offset, spans, shift, refresh, tolerance, regions):
    """The second key's own first frame, in a recording of two keys: the first row after the start of that key's
    own opening mark in which the tab's region (the tab strip for Cmd-T, the window outside the pane for Cmd-N) is
    unlike the row before it. `every`: each row with its frame number, the rows after the judged key from `offset`
    on. Returns (the fact or None, why there is none). The fact: `mark_ms` (the mark's start after the key's due
    time), the row (`frame`, `ms`, `file`), `after_mark_ms`, the content area's state in that row, `span` (the
    frames from the last row at or before the mark to that row: `span_of`), and `moving_at_the_mark`: the region
    also changed in the last row at or before the mark. The first key's change then still ran, and the row is only
    the earliest one in which the second key's change can be."""
    if not gap_ms:
        return None, "one key"
    which, mark = ("outside", "cmdN.start") if key == "n" else ("strip", "newTab.open")
    starts = sorted(span["ms"] for span in spans or [] if span.get("name") == mark and _number(span.get("ms")))
    if len(starts) < 2:
        return None, f"not known: the spans have no second `{mark}` mark"
    if regions[which] is None:
        return None, f"not known: the rows carry no {which} numbers"
    at = starts[1] + shift

    def moved(index):
        """The region in the row `index` is unlike the row before it (None: one of the two rows does not carry it)."""
        here, there = pair(every[index][1], which), pair(every[index - 1][1], which) if index > 0 else None
        return None if here is None or there is None else any(abs(a - b) > tolerance for a, b in zip(there, here))

    start = max((index for index, (_, row) in enumerate(every) if row["ms"] <= at), default=None)
    found = next((index for index in range(max(offset, 0 if start is None else start + 1), len(every)) if moved(index)), None)
    if found is None:
        return None, f"not known: no row after the second key's `{mark}` mark has the {which} region unlike the row before it"
    frame, row = every[found]
    low = 0 if start is None else start + 1
    inside = every[low:found + 1]
    # A row in which the region did not move still shows the state before the second key's change.
    old = {every[index][0] for index in range(low, found) if moved(index) is False}
    span = span_of(inside, refresh, *((every[start][0], every[start][1]["ms"]) if start is not None else (inside[0][0] - 1, at)), old=old)
    return {"region": which, "mark_ms": round(at, 1), "frame": frame, "ms": row["ms"], "file": row.get("file"),
            "after_mark_ms": round(row["ms"] - at, 1), "content": regions["content"]["states"][found - offset],
            "moving_at_the_mark": None if start is None else moved(start), "span": span}, f"the rows' {which} numbers and the second `{mark}` mark"


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
    timed = sorted(({**f, "ms": f["ms"] + shift} for f in reply.get("frames") or [] if _number(f.get("ms"))), key=lambda f: f["ms"])
    after = [f for f in timed if f["ms"] > 0]
    if not after or pair(after[0], "content") is None:
        out["invalid"].append("frames: no frame after the key with the content area's numbers")
        return out
    refresh, measured = refresh_of(after, asked_hz)
    refresh = refresh or 1000.0 / 60
    asked = 1000.0 / asked_hz if asked_rate(asked_hz) else None
    # The first row's own frame of the display (a frame before it with no row counts), then the rows' steps. The
    # rows before the judged key have their numbers too (0 and less): a span can start at one of them.
    lost = max(0, math.ceil((after[0]["ms"] - 0.5) / refresh) - 1)
    every = [(1 + lost + round((row["ms"] - after[0]["ms"]) / refresh), row) for row in timed]
    numbered = every[len(timed) - len(after):]
    out.update({"frames_after_key": len(after), "refresh_ms": round(refresh, 3),
                "refresh_measured_ms": None if measured is None else round(measured, 3),
                "frames_not_delivered": numbered[-1][0] - len(numbered), "take_ms": after[-1]["ms"],
                "blank_frames": sum(1 for row in after if row.get("blank")),
                "rows_ms": [round(row["ms"], 1) for row in after]})
    regions = {name: region_of(numbered, name, tolerance) for name in REGIONS}
    known = {name: region for name, region in regions.items() if region}
    for region in known.values():
        # The frames of the display with no row directly before the region's first change (from the key, for the
        # first row after it): the change can have come in one of them, so `first` is the latest frame of it.
        at = next((i for i, (frame, _) in enumerate(numbered) if region["first"] and frame == region["first"]["frame"]), None)
        region["first_can_be_frames_earlier"] = None if at is None else numbered[at][0] - (numbered[at - 1][0] if at else 0) - 1
    content = regions["content"]
    first = next((i for i, (_, row) in enumerate(numbered)
                  if pair(row, "content")[0] > tolerance and not row.get("blank")), None)
    out["content_first"], out["content_final"] = _at(numbered, first), content["final"]
    out["content_first_vs_before"] = None if first is None else pair(numbered[first][1], "content")[0]
    # The first frame's time is proved only when no frame with no row is between the last row of the old picture
    # and it: the page can have come in such a frame. The row still says how many frames from the key to it have
    # no row (in those a partial state is not seen) and how early the first frame can be.
    still_old = {frame for frame, row in numbered[:first or 0] if pair(row, "content")[0] <= tolerance}
    out["first_frame_span"] = None if first is None else span_of(numbered[:first + 1], refresh, old=still_old)
    out["partial_state_not_seen"] = None if first is None else out["first_frame_span"]["no_row"]
    out["invalid"] += [fault for fault in [no_row_fault(out["first_frame_span"], "the key", "content_first")] if fault]
    # The rows of the part that moves, from the key to `content_final` (to the end when the content has none): 4 of
    # them at least, and their own step. Rows that come slower than the display there are not each frame of it. The
    # still part after it is not judged: its frames with no row are a count (`frames_not_delivered`).
    moving = after if not content["final"] else [row for row in after if row["ms"] <= content["final"]["ms"]]
    moving_step = refresh_of(moving)[1] if len(moving) >= 4 else None
    out["refresh_moving_ms"] = None if moving_step is None else round(moving_step, 3)
    if asked and moving_step and moving_step > 1.15 * asked:
        out["invalid"].append(f"refresh: the {len(moving)} rows from the key to content_final come each {moving_step:.2f} ms and "
                              f"the display's frame time is {asked:.2f} ms: the rows are not each frame of the display")
    # The asked rate against the rows of the whole recording (the module doc). Each row has the judged number.
    out["rate_share"] = rate_share(timed, asked)
    out["invalid"] += [fault for fault in [rate_fault(timed, asked, refresh)] if fault]
    out["second_first"], out["second_first_source"] = second_first_of(key, gap_ms, every, len(timed) - len(after), reply.get("spans"),
                                                                      shift, refresh, tolerance, regions)
    if out["second_first"]:
        out["invalid"] += [fault for fault in [no_row_fault(out["second_first"]["span"], "the second key's mark", "second_first")] if fault]
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
                       **{name: out[name]["file"] for name in ("tab", "content_first", "content_final", "final", "second_first") if out[name]},
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
    for name in ("tab", "content_first", "content_final", "final", "second_first"):
        out[name] = {unit: _spread([(row.get(name) or {}).get(unit) for row in good]) for unit in ("frame", "ms")}
    # A row with a `display` reason: its frame time does not see a frame with no row, so its counts are not known
    # (`rate_not_known`). `no_row_not_known`: why, for a case with such a row (None: each row's counts are known);
    # `no_row_not_known_rows`: how many of the case's rows.
    whys = [rate_not_known(row.get("invalid")) for row in rows]
    out["no_row_not_known"] = next((why for why in (NO_RATE_SAID, RATE_NOT_PROVED_SAID) if why in whys), None)
    out["no_row_not_known_rows"] = sum(1 for why in whys if why)
    # Over EACH row with a first content frame whose counts are known, also an INVALID one: how wrong its first
    # frame can be. None when the counts of each row of the case are not known: a 0 there would read as `none`.
    spans = [row["first_frame_span"] for row, why in zip(rows, whys) if not why and row.get("first_frame_span")]
    out["first_frame_no_row"] = None if rows and all(whys) else {
        "rows": len(spans), "with_a_frame_with_no_row": sum(1 for span in spans if span["no_row"]),
        # The 2 kinds apart: the page can have come in a frame with no row (INVALID for the time), or each such
        # frame is before a row of the old picture (the time is proved).
        "time_not_proved": sum(1 for span in spans if span["early_ms_at_most"]),
        "time_proved_partial_state_not_seen": sum(1 for span in spans if span["no_row"] and not span["early_ms_at_most"]),
        "no_row": _spread([span["no_row"] for span in spans]),
        "longest_gap_ms": _spread([span["longest_gap_ms"] for span in spans]),
        "early_ms_at_most": _spread([span["early_ms_at_most"] for span in spans])}
    return out


def recorder_lost(rows):
    """One case's rows that the recorder lost: the rows with an INVALID reason `no-row` (a frame with no row where
    the page can have come) or `refresh` (rows slower than the display's frames). Both are faults of the tool's
    yield, not of the app. A row with a `display` reason is not counted: its frame time does not see a frame with
    no row (`rate_not_known`). `rows`: the rows with one of the 2 reasons, `of` the rows that are counted,
    `not_known` the rows that are not. None when no row of the case is counted: a 0 would read as `none lost`."""
    seen = [row for row in rows if not rate_not_known(row.get("invalid"))]
    if rows and not seen:
        return None
    kinds = [{reason.split(":")[0] for reason in row.get("invalid") or []} & {"no-row", "refresh"} for row in seen]
    return {"rows": sum(1 for kind in kinds if kind), "of": len(seen), "not_known": len(rows) - len(seen),
            "no_row": sum(1 for kind in kinds if "no-row" in kind), "refresh": sum(1 for kind in kinds if "refresh" in kind)}


def recorder_sentence(cases):
    """The report's head sentence from each case's `recorder_lost`, in the cases' order. A case with a `display`
    row has no count for that row: its frame time does not see a frame with no row, so `0 of N` would read as
    `none lost`. A case with rows of both kinds says how many rows are not known, and counts the others."""
    said = []
    for name, case in cases.items():
        lost = case.get("recorder_lost") or {}
        kinds = f" (no-row {lost['no_row']}, refresh {lost['refresh']})" if lost.get("rows") else ""
        blind, some = case.get("no_row_not_known"), lost.get("not_known")
        said.append(f"{name} {lost.get('rows')} of {lost.get('of')}{kinds}" if not blind else
                    f"{name} not known for {some} of {some + lost['of']} rows ({blind}), {lost['rows']} of the {lost['of']} others{kinds}"
                    if some and lost.get("of") else f"{name} not known ({blind})")
    if not said:
        return "rows lost to the recorder: no case recorded"
    return "rows lost to the recorder (INVALID by `no-row` or `refresh`, a fault of the tool's yield): " + "; ".join(said)


def cell(summary):
    def said(name):
        frames, ms = summary[name]["frame"], summary[name]["ms"]
        return "none" if not frames else f"frame {frames['p50']:g} (max {frames['max']:g}), {ms['p50']:g} ms (max {ms['max']:g})"
    changes, work, zeros = summary["changes_after_content"], summary["key_work_ms"], summary.get("zero") or []
    holes, blind, some = summary["first_frame_no_row"], summary.get("no_row_not_known"), summary.get("no_row_not_known_rows")
    # Each row of the case is not known (also a summary of an older tool, which has no count of such rows).
    whole = blind and (holes is None or not some or some >= summary["n"])
    partly = "" if whole or not blind else f": not known for {some} of {summary['n']} rows ({blind})"
    return (f"valid {summary['valid']}/{summary['n']}" + (f" (INVALID: {', '.join(summary['invalid'])})" if summary["invalid"] else "")
            + (f"; frames with no row from the key to content_first: not known ({blind})" if whole else
               f"; frames with no row from the key to content_first{partly}" if not holes["rows"] and partly else
               "" if not holes["rows"] else
               f"; frames with no row from the key to content_first{partly}{';' if partly else ','} over EACH of "
               f"{holes['rows']} {'other ' if partly else ''}rows (also the INVALID ones): in "
               f"{holes['with_a_frame_with_no_row']} rows ({holes['time_not_proved']} with one directly before content_first: the time is "
               f"not proved; {holes['time_proved_partial_state_not_seen']} with each before a row of the old picture: the time is proved, "
               f"a partial state is not seen), p50 {holes['no_row']['p50']:g} max {holes['no_row']['max']:g}, the longest step "
               f"between rows max {holes['longest_gap_ms']['max']:g} ms, content_first at most {holes['early_ms_at_most']['max']:g} ms early")
            + ("" if not summary["second_first"]["frame"] else f"; second_first {said('second_first')}")
            + f"; tab {said('tab')} [known {summary['tab_known']}/{summary['valid']}]; content_first {said('content_first')}; "
            f"content_final {said('content_final')}; final {said('final')}; first=final {summary['first_is_final']}/{summary['valid']} "
            f"(not known {summary['first_is_final_not_known']}); whole window seen {summary['whole_window']}/{summary['valid']}"
            + ("" if summary["whole_window"] == summary["valid"] else " (THE STRIP IS NOT SEEN in the others: their changed frames are a lowest count)")
            + "; "
            f"frames changed after content p50 {changes['p50'] if changes else 'n/a'} max {changes['max'] if changes else 'n/a'}; "
            f"the key's own work p50 {work['p50'] if work else 'n/a'} ms max {work['max'] if work else 'n/a'}; "
            f"blank {summary['blank_frames']}; caret rows {summary['blinks']}"
            + ("" if not zeros else f"; zero: {zeros[0]}" if len(zeros) == 1 else f"; ROWS OF {len(zeros)} ZEROS (their times are not one table): {' / '.join(zeros)}"))


NEW_TAB_MARK, CLOSE_MARK = "newTab.open", "closeLocalTab"  # one for each opening of a New Tab key; one for each closed local tab


def _shows(before, after, closed, left, new_tab_keys):
    """The tab that shows after a Close Tab key, by its place: from the closed tab for a key alone, and against
    the New Tab keys of the recording when there are some. `left`: the tabs of `after` that `before` had not."""
    shown, old = after.get("selected"), [tab["id"] for tab in before["tabs"]]
    if shown is None:
        return "not known: the app names no shown tab"
    if new_tab_keys:
        if shown in left:
            return f"a new tab of the recording (place {left.index(shown) + 1} of the {len(left)} that are left, from the left)"
        return "the tab that was shown before the New Tab keys" if shown == before.get("selected") else "another tab that was there before the New Tab keys"
    if not closed:
        return "no tab closed"
    if not closed[0]["was_shown"]:
        return ("the tab that was shown before the key (the closed tab was not the shown one)" if shown == before.get("selected")
                else "another tab than the one shown before the key (the closed tab was not the shown one)")
    if shown not in old:
        return "a tab that was not there before the key"
    places = old.index(shown) - closed[0]["index"]
    side = "left" if places < 0 else "right"
    return f"the tab to the {side} of the closed tab" if abs(places) == 1 else f"another tab ({abs(places)} places to the {side} of the closed tab)"


def close_of(row, spans, before, after, new_tab_keys=0):
    """One Close Tab key's facts (the module doc), from `row` (`one_key` of its recording), the recording's marks
    and the pane's tabs before the keys and after them (`{"tabs": [{"id", "kind"}], "selected": id}`, or None when
    the app did not list them). `new_tab_keys`: the New Tab key-downs that the tool sent before the Close Tab key.
    Returns (the fact, the INVALID reasons). A close of a tab that nobody expected, and a tab that shows that
    nobody expected, are facts and no fault: the proof of the input is the count of tabs and the marks."""
    regions = row.get("regions") or {}
    content, strip, work = regions.get("content") or {}, regions.get("strip"), row.get("key_work_ms") or 0.0
    gone, moved = content.get("first"), (strip or {}).get("first")
    early_strip, early_content = (strip or {}).get("first_can_be_frames_earlier") or 0, content.get("first_can_be_frames_earlier") or 0
    # Each `newTab.open` mark's start, in ms before the time at which the Close Tab key went in (below 0: after it).
    marks = sorted((round(-(span["ms"] + work), 1) for span in spans or [] if span.get("name") == NEW_TAB_MARK and _number(span.get("ms"))), reverse=True)
    earlier = [mark for mark in marks if mark >= 0]
    if strip is None:
        order = "not known: the rows carry no strip numbers"
    elif not gone:
        order = "the strip changed and the content area did not (one picture before and after the key)" if moved else "neither the strip nor the content area changed"
    elif not moved:
        order = "the content area changed and the strip did not"
    elif not early_strip and not early_content and moved["frame"] == gone["frame"]:
        order = "the strip and the content area changed in the same frame"
    elif not early_strip and not early_content:
        order = f"the strip changed {abs(moved['frame'] - gone['frame'])} frames {'before' if moved['frame'] < gone['frame'] else 'after'} the content area"
    else:
        # A first change with frames with no row directly before it is the LATEST frame of that change: the strip's
        # frame less the content's is then a range, and which one was first is proved only when the range has one sign.
        low, high = moved["frame"] - early_strip - gone["frame"], moved["frame"] - gone["frame"] + early_content
        order = (f"the strip changed {low} to {high} frames after the content area" if low > 0 else
                 f"the strip changed {-high} to {-low} frames before the content area" if high < 0 else
                 f"not proved: the strip changed from {-low} frames before to {high} frames after the content area")
        order += f" (frames with no row directly before the first change: the strip's {early_strip}, the content area's {early_content})"
    fact = {"new_tab_keys": new_tab_keys, "strip_first_can_be_frames_earlier": early_strip if moved else None,
            "content_gone_can_be_frames_earlier": early_content if gone else None, "new_tab_marks_before_ms": earlier, "last_new_tab_key_before_ms": min(earlier, default=None),
            "close_marks_ms": [round(span["ms"] + work, 1) for span in spans or [] if span.get("name") == CLOSE_MARK and _number(span.get("ms"))],
            "content_gone": gone, "content_shown": row.get("content_final") if gone else None, "strip_first": moved,
            "content_between_frames": content.get("between_frames"), "blank_frames": row.get("blank_frames"), "order": order,
            "new_tab_change_can_be_in_the_frames": new_tab_keys > 0,
            # The reader's reason for an OPENING with no new content: a close between two tabs of one picture has none.
            "not_a_fault_for_a_close": [reason for reason in row.get("invalid") or [] if reason.startswith("content: ")]}
    faults = []
    if new_tab_keys and not earlier:
        faults.append("input: no `newTab.open` mark in the recording before the Close Tab key went in: the last New Tab key did not open "
                      "a tab in the recording, or it went in before the recording's start")
    if marks and marks[-1] < 0:
        faults.append(f"input: a `newTab.open` mark starts {-marks[-1]:g} ms after the Close Tab key went in: a New Tab key was not before it")
    if not before or not after:
        which = "before and after" if not before and not after else "before" if not before else "after"
        return fact, [f"tabs: the app did not list the pane's tabs {which} the keys (`debug.focus`): which tab closed and which tab shows is not known"] + faults
    old, now = [tab["id"] for tab in before["tabs"]], [tab["id"] for tab in after["tabs"]]
    closed = [{"id": tab["id"], "kind": tab.get("kind"), "index": index, "was_shown": tab["id"] == before.get("selected")}
              for index, tab in enumerate(before["tabs"]) if tab["id"] not in now]
    left = [name for name in now if name not in old]
    closed_new = max(0, new_tab_keys - len(left))
    if new_tab_keys:
        closed_is = (f"a tab that was there before the New Tab keys ({closed[0]['kind']})" if closed
                     else "a new tab of the recording" if closed_new else "no tab")
    else:
        closed_is = "no tab" if not closed else f"{'the shown tab' if closed[0]['was_shown'] else 'a tab that was not the shown one'} ({closed[0]['kind']})"
    if len(closed) > 1:
        closed_is = f"{len(closed)} tabs that were there before the key"
    shown = next(({"id": tab["id"], "kind": tab.get("kind"), "index": index} for index, tab in enumerate(after["tabs"])
                  if tab["id"] == after.get("selected")), {"id": after.get("selected"), "kind": None, "index": None})
    fact.update({"tabs_before": len(old), "tabs_after": len(now), "closed": closed, "closed_is": closed_is, "new_tabs_left": len(left),
                 "closed_new_tabs": closed_new, "shown_before": before.get("selected"),
                 "shown_after": {**shown, "of": len(now), "is": _shows(before, after, closed, left, new_tab_keys)}})
    expected = len(old) + new_tab_keys - 1
    if len(now) != expected:
        faults.insert(0, f"input: {new_tab_keys} New Tab key-downs and 1 Close Tab key sent: the pane had {len(old)} tabs before them and has "
                         f"{len(now)} after them ({expected} is the count for one tab opened by each key-down and one tab closed)")
    return fact, faults


def close_summary(rows):
    """One Close Tab case: over its VALID rows, how many times each tab showed and each kind of tab closed, and
    p50 and max of the close's frames."""
    facts = [row["close_tab"] for row in rows if not row.get("invalid") and row.get("close_tab")]

    def counted(values):
        out = {}
        for value in values:
            out[value] = out.get(value, 0) + 1
        return out

    out = {"n": len(rows), "valid": len(facts), "shows": counted((fact.get("shown_after") or {}).get("is") or "not known" for fact in facts),
           "closed": counted(fact.get("closed_is") or "not known" for fact in facts), "order": counted(fact["order"] for fact in facts),
           "content_did_not_change": sum(1 for fact in facts if not fact["content_gone"]),
           # The rows whose `strip_first` is the latest frame of the strip's change: a frame with no row is before it.
           "strip_first_not_proved": sum(1 for fact in facts if fact.get("strip_first_can_be_frames_earlier")),
           "blank_frames": _spread([fact.get("blank_frames") for fact in facts]),
           "content_between_frames": _spread([fact.get("content_between_frames") for fact in facts]),
           "last_new_tab_key_before_ms": _spread([fact.get("last_new_tab_key_before_ms") for fact in facts])}
    for name in ("content_gone", "content_shown", "strip_first"):
        out[name] = {unit: _spread([(fact.get(name) or {}).get(unit) for fact in facts]) for unit in ("frame", "ms")}
    return out


def close_cell(summary):
    def said(name):
        frames, ms = summary[name]["frame"], summary[name]["ms"]
        return "none" if not frames else f"frame {frames['p50']:g} (max {frames['max']:g}), {ms['p50']:g} ms (max {ms['max']:g})"

    def each(name):
        return ", ".join(f"{what} {count}/{summary['valid']}" for what, count in summary[name].items()) or "no valid row"
    blank, between, gap = summary["blank_frames"], summary["content_between_frames"], summary["last_new_tab_key_before_ms"]
    latest = summary.get("strip_first_not_proved")
    return (f"; CLOSE TAB, over the {summary['valid']} valid rows: closed: {each('closed')}; shows after the close: {each('shows')}; "
            f"closed tab's content gone {said('content_gone')}; content of the tab that shows final {said('content_shown')}; "
            f"strip's first change {said('strip_first')}"
            + ("" if not latest else f" [in {latest} of the {summary['valid']} rows a frame with no row is directly before it: there it "
                                     f"is the latest frame]")
            + f"; order: {each('order')}; the content area did not change in "
            f"{summary['content_did_not_change']} rows; blank frames p50 {blank['p50'] if blank else 'n/a'} max {blank['max'] if blank else 'n/a'}; "
            f"content frames at neither picture p50 {between['p50'] if between else 'n/a'} max {between['max'] if between else 'n/a'}"
            + ("" if not gap else f"; the last New Tab key's mark before the Close Tab key p50 {gap['p50']:g} ms max {gap['max']:g}"))
