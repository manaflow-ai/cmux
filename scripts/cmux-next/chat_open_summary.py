"""chat-open-bench.py's summary of one case's opens, apart from the bench so a test can call it.

A case is complete only when every open has a first-content time and a longest-empty time. An
incomplete case reports no median at all (a slow open that timed out would otherwise drop out and
improve it), says how many of its opens were valid, and fails the bench.
"""
import statistics


def _number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def valid(record):
    # A trace that timed out or errored can still carry numbers (the time it waited, a first frame
    # it saw before the wait gave up); they are not an open's times.
    if record.get("timed_out") or record.get("error"):
        return False
    return _number(record.get("first_content_ms")) and _number(record.get("longest_empty_ms"))


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
    marks = {}
    for record in good if complete else []:
        for name, ms in (record.get("marks_ms") or {}).items():
            if _number(ms):
                marks.setdefault(name, []).append(ms)
    out["marks_median_ms"] = {name: round(statistics.median(v), 1) for name, v in marks.items()}
    return out


def cell(summary, case):
    """One table cell: the medians, or FAILED with how many opens were valid."""
    if not summary.get("complete"):
        return f"FAILED ({summary.get('ok', 0)}/{summary.get('n', 0)} valid)"
    image = summary.get("first_image_ms")
    extra = f" (image {image})" if case == "restore" and image is not None else ""
    flashes = summary["flashes"]
    return (f"{summary['first_content_ms']['median']}{extra}, empty {summary['longest_empty_ms']}, "
            f"{flashes} flash{'es' if flashes != 1 else ''}")
