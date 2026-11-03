"""chat-open-bench.py's summary of one case's opens, apart from the bench so a test can call it.

A case is complete only when every open has a first-content time, traced frames and a longest-empty
time. An incomplete case reports no first-content median at all (a slow open that timed out would
otherwise drop out and improve it), says how many of its opens were valid and why each other one was
not (``invalid_reason``), and fails the bench.

An open's trace says `timed_out` false whenever something ended its wait (the loading watchdog's
`pane_painted`/`loading_left` after the trace's frame cap, with no web paint), so `timed_out` alone
undercounts the opens that never showed content: #32448's step 3bbdee10 had 13 of 24 opens with no
first content and 7 timed out. The reason comes from what the open drew, not from that flag.
"""
import statistics


def _number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def invalid_reason(record):
    """Why an open is not a valid measurement, or None when it is: `error`, `timed_out`, `no_content`
    (no first-content frame, whatever ended the wait), `no_frames` (a trace that saw no frame at all)
    or `no_empty_time`. A trace that timed out or errored can still carry numbers (the time it waited,
    a first frame it saw before the wait gave up); they are not an open's times."""
    if record.get("error"):
        return "error"
    if record.get("timed_out"):
        return "timed_out"
    if not _number(record.get("first_content_ms")):
        return "no_content"
    if "frame_count" in record and not (_number(record.get("frame_count")) and record["frame_count"] > 0):
        return "no_frames"
    if not _number(record.get("longest_empty_ms")):
        return "no_empty_time"
    return None


def valid(record):
    return invalid_reason(record) is None


def summarize(records):
    good = [r for r in records if valid(r)]
    complete = bool(records) and len(good) == len(records)
    values = [r["first_content_ms"] for r in good] if complete else []
    empties = [r["longest_empty_ms"] for r in good] if complete else []
    images = [r["first_image_ms"] for r in good if _number(r.get("first_image_ms"))] if complete else []
    out = {"n": len(records), "ok": len(good), "complete": complete,
           "first_content_ms": {"median": round(statistics.median(values), 1) if values else None,
                                "min": min(values) if values else None, "max": max(values) if values else None},
           "first_image_ms": round(statistics.median(images), 1) if images else None,
           "longest_empty_ms": round(statistics.median(empties), 1) if empties else None,
           "flashes": sum(r.get("flashes") or 0 for r in records),
           "timed_out": sum(1 for r in records if r.get("timed_out"))}
    reasons = {}
    for record in records:
        reason = invalid_reason(record)
        if reason:
            reasons[reason] = reasons.get(reason, 0) + 1
    out["invalid"] = reasons
    out["no_first_content"] = sum(1 for r in records if not r.get("error") and not _number(r.get("first_content_ms")))
    # Each mark's median over the opens that ran it, complete case or not (an errored open has no
    # trace): an incomplete case still shows which marks ran and when (spare_adopted on 21 of 24
    # opens was hidden behind an empty {}); `marks_n` says over how many opens.
    marks = {}
    for record in records:
        if record.get("error"):
            continue
        for name, ms in (record.get("marks_ms") or {}).items():
            if _number(ms):
                marks.setdefault(name, []).append(ms)
    out["marks_median_ms"] = {name: round(statistics.median(v), 1) for name, v in marks.items()}
    out["marks_n"] = {name: len(v) for name, v in marks.items()}
    return out


def cell(summary, case):
    """One table cell: the medians, or FAILED with how many opens were valid."""
    if not summary.get("complete"):
        reasons = ", ".join(f"{name} {n}" for name, n in sorted((summary.get("invalid") or {}).items()))
        return f"FAILED ({summary.get('ok', 0)}/{summary.get('n', 0)} valid{'; ' + reasons if reasons else ''})"
    image = summary.get("first_image_ms")
    extra = f" (image {image})" if case == "restore" and image is not None else ""
    flashes = summary["flashes"]
    return (f"{summary['first_content_ms']['median']}{extra}, empty {summary['longest_empty_ms']}, "
            f"{flashes} flash{'es' if flashes != 1 else ''}")
