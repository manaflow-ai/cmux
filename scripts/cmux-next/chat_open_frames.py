"""chat-open-bench.py's click cases, read from pixels: a frame strip (`debug.new_tab frame_strip`, gesture
`mouse`) from a real mouse click on a chat's sidebar row until the pane stops changing.

Leo, 2026-11-03: clicking into a chat shows the final view on the first frame, never "text first and the real
view a second later"; a cold local chat reaches its final frame in under 300 ms. So each click is judged on
the frames the window server composited, not on the page's own first-content mark:

  first_content_ms  the first frame after the click whose content area differs from before the click and is
                    not blank (frame_strip's `blank`: flat and unlike both before and the final frame); a sparse
                    chat page is nearly one color too, so flatness alone does not tell a blank pane
  final_frame_ms    the first frame of the settled run: every frame from it to the end of the strip equals
                    the last one, and the run is at least `settle_frames` frames long (else the open never
                    settled inside the strip and has no final frame)
  first_is_final    the first content frame is the final frame and no frame was blank: nothing changed after
                    the chat first drew
  transcript_ms     when the page first drew transcript rows, from the page's own layout_watch started at the
                    click (its first paint when that had rows, else the first row that appeared after it): an
                    open counts only when this is inside the strip, so a strip that settled on the chat's chrome
                    before its transcript came is no pass
  between_frames    frames from first content to the final frame that equal neither (text first, then the view)
  blank_frames      frames the strip marked blank (the content area flat and unlike before and after)

Apart from the bench so a test can call it. Frames are frame_strip's rows: `ms` from the click, and the
content area's `content_vs_before`, `content_vs_final` and `flatness`.
"""
import statistics

# frame_strip's own default tolerance: a difference at or under it is the same picture.
TOLERANCE = 0.002


def _number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def final_frame(frames, settle_frames=10, tolerance=TOLERANCE):
    """The click's first-content and final-frame times from frame_strip `frames` (see the module doc)."""
    after = sorted((f for f in frames or [] if _number(f.get("ms")) and f["ms"] > 0), key=lambda f: f["ms"])
    out = {"frames_after_click": len(after), "first_content_ms": None, "final_frame_ms": None, "settled": False,
           "settled_frames": 0, "first_is_final": False, "between_frames": None,
           "blank_frames": sum(1 for f in after if f.get("blank"))}
    if not after or any(not _number(f.get("content_vs_final")) for f in after):
        out["error"] = "frame_strip rows carry no content_vs_final (a build before the click cases?)"
        return out
    first = next((i for i, f in enumerate(after) if (f.get("content_vs_before") or 0) > tolerance and not f.get("blank")), None)
    final = len(after)
    while final > 0 and after[final - 1]["content_vs_final"] <= tolerance:
        final -= 1
    out["settled_frames"] = len(after) - final
    out["settled"] = out["settled_frames"] >= max(1, settle_frames)
    if first is not None:
        out["first_content_ms"] = after[first]["ms"]
    if out["settled"]:
        out["final_frame_ms"] = after[final]["ms"]
    if first is not None and out["settled"]:
        out["first_is_final"] = first >= final and out["blank_frames"] == 0
        out["between_frames"] = sum(1 for f in after[first:final] if f["content_vs_final"] > tolerance)
    return out


def row_drift(watch):
    """The transcript's rows that moved after the page first drew them (layout_watch `shifts`), as the most
    pixels any row moved: an upper bound on the newest marker's drift (0 when no row moved), with the scroll
    jumps. None when the watch did not run."""
    if not isinstance(watch, dict) or watch.get("error") or not _number(watch.get("frames")):
        return None
    moved = []
    for shift in watch.get("shifts") or []:
        if not str(shift.get("element", "")).startswith("row#"):
            continue
        was, now = shift.get("from") or {}, shift.get("to") or {}
        moved.append(max(abs((now.get(k) or 0) - (was.get(k) or 0)) for k in ("x", "y", "w", "h")))
    late = sum(1 for item in watch.get("appeared") or [] if str(item.get("element", "")).startswith("row#"))
    return {"rows_moved": len(moved), "max_row_px": max(moved) if moved else 0, "rows_appeared_later": late,
            "scroll_jumps": len(watch.get("scroll_jumps") or []), "page_first_content_ms": watch.get("first_content_ms")}


def watch_started_ms(watch, asked, clicked, clicked_wall):
    """When the page's layout_watch began, in ms from the click: from the page's own `started_wall_ms` (the
    app and the bench share the Mac's clock) when it reports one, since the ask may reach the page well after
    it was sent (a Chromium page still starting waits in PageWebView.callPageScript); else from when the bench
    asked (`asked` and `clicked` monotonic s), an older page's only anchor. None without a watch."""
    if not isinstance(watch, dict) or not _number(asked):
        return None
    if _number(watch.get("started_wall_ms")) and _number(clicked_wall):
        return round(watch["started_wall_ms"] - clicked_wall * 1000)
    return round((asked - clicked) * 1000)


def transcript_ms(watch, watch_started_ms, strip_ms):
    """When the page first drew its transcript, in ms from the click (when the watch started plus its first paint
    when that had rows, else plus the first row that appeared later), or None when it drew none inside the strip.
    The click cases open chats with messages, so a first paint with no rows (`first_rows` 0: the empty chat, or a
    page still loading) is not the transcript, nor is a watch from a page that does not report its rows."""
    if not isinstance(watch, dict) or not _number(watch.get("first_content_ms")) or not _number(watch_started_ms):
        return None
    if not _number(watch.get("first_rows")):
        return None
    if watch["first_rows"] > 0:
        drawn = watch["first_content_ms"]
    else:
        drawn = min((item["at_ms"] for item in watch.get("appeared") or []
                     if str(item.get("element", "")).startswith("row#") and _number(item.get("at_ms"))), default=None)
        if drawn is None:
            return None
    at = round(max(0, watch_started_ms) + drawn, 1)
    return at if at <= strip_ms else None


def valid(record):
    return not record.get("error") and record.get("settled") and _number(record.get("first_content_ms")) \
        and _number(record.get("final_frame_ms")) and _number(record.get("transcript_ms"))


def summarize(records):
    """One click case's opens: medians only when every open settled with a first-content frame."""
    good = [r for r in records if valid(r)]
    complete = bool(records) and len(good) == len(records)

    def median(key):
        values = [r[key] for r in good] if complete else []
        return round(statistics.median(values), 1) if values else None

    drifts = [r["drift"]["max_row_px"] for r in good if isinstance(r.get("drift"), dict)]
    return {"n": len(records), "ok": len(good), "complete": complete,
            "first_content_ms": median("first_content_ms"), "final_frame_ms": median("final_frame_ms"),
            "max_final_frame_ms": max((r["final_frame_ms"] for r in good), default=None) if complete else None,
            "first_is_final": sum(1 for r in good if r.get("first_is_final")),
            "between_frames": sum(r.get("between_frames") or 0 for r in good),
            "blank_frames": sum(r.get("blank_frames") or 0 for r in records),
            "max_row_drift_px": max(drifts) if drifts else None}


def cell(summary):
    if not summary.get("complete"):
        return f"FAILED ({summary.get('ok', 0)}/{summary.get('n', 0)} settled)"
    drift = summary["max_row_drift_px"]
    return (f"content {summary['first_content_ms']}, final {summary['final_frame_ms']} (max {summary['max_final_frame_ms']}), "
            f"first=final {summary['first_is_final']}/{summary['n']}, between {summary['between_frames']}, "
            f"blank {summary['blank_frames']}, drift {'n/a' if drift is None else drift} px")
