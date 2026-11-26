# Status glyphs agent CLIs put in front of a terminal title, by code point.
WORKING = [(0x2801, 0x28FF), (0x25D0, 0x25D3), (0x25F4, 0x25F7), (0x2596, 0x259F)]  # spinners (not blank U+2800)
IDLE = {0x2733, 0x2736, 0x273B, 0x273D, 0x2722, 0x00B7, 0x25CF, 0x25CB, 0x25C9, 0x23FA}
DONE = {0x2713, 0x2714, 0x2705}
FAILED = {0x2717, 0x2718, 0x274C}
# Variation selectors that may follow a glyph (U+FE0F makes it an emoji, and so on).
SELECTORS = [(0x180B, 0x180D), (0x180F, 0x180F), (0xFE00, 0xFE0F), (0xE0100, 0xE01EF)]
ACTIVITIES = ("working", "idle", "done", "failed")


def split_title(raw: str) -> tuple:
    """(text, activity) of a terminal title."""
    return raw, None


def store(stored, title: str) -> tuple:
    """(raw title to store, what to announce or None) for a title the terminal just set."""
    if title == stored:
        return stored, None
    return title, (title, None)


def shown_title(tab: dict) -> tuple:
    """(text, activity) the sidebar shows for a tab."""
    return tab.get("title", ""), None
