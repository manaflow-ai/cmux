WORKING = [(0x2801, 0x28FF), (0x25D0, 0x25D3), (0x25F4, 0x25F7), (0x2596, 0x259F)]
IDLE = {0x2733, 0x2736, 0x273B, 0x273D, 0x2722, 0x00B7, 0x25CF, 0x25CB, 0x25C9, 0x23FA}
DONE = {0x2713, 0x2714, 0x2705}
FAILED = {0x2717, 0x2718, 0x274C}
SELECTORS = [(0x180B, 0x180D), (0x180F, 0x180F), (0xFE00, 0xFE0F), (0xE0100, 0xE01EF)]
ACTIVITIES = ("working", "idle", "done", "failed")


def _activity(ch):
    c = ord(ch)
    if any(a <= c <= b for a, b in WORKING):
        return "working"
    if c in IDLE:
        return "idle"
    if c in DONE:
        return "done"
    if c in FAILED:
        return "failed"
    return None


def split_title(raw):
    i, n, activity = 0, len(raw), None
    while i < n and raw[i].isspace():
        i += 1
    while i < n and _activity(raw[i]):
        activity = _activity(raw[i])
        i += 1
        while i < n and any(a <= ord(raw[i]) <= b for a, b in SELECTORS):
            i += 1
        while i < n and raw[i].isspace():
            i += 1
    text = raw[i:].strip()
    return (text or raw.strip()), activity


def store(stored, title):
    if title == stored:
        return stored, None
    new = split_title(title)
    old = split_title(stored) if stored is not None else ("", None)
    return title, (new if new != old else None)


def shown_title(tab):
    text = tab.get("title_text")
    if isinstance(text, str):
        act = tab.get("title_activity")
        return text, (act if act in ACTIVITIES else None)
    title = tab.get("title", "")
    if tab.get("kind") in ("pty", "remote-pty"):
        return split_title(title)
    return title, None
