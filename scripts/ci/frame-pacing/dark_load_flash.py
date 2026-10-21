"""A Chromium page never flashes white before it paints, in a dark theme.

Used by golden.py (`dark_load_flash`). Leo, 2026-10-20: opening a tab and navigating in a
dark theme flashed white. Chromium repaints the page area with the browser's background
color as soon as a document commits, long before its first contentful paint, and that color
was Chromium's white from a tab's first real page on (`CEFTab+LoadingBackground`).

The scenario puts the app in a dark theme (`settings.set appearance.theme`), reads that
theme's window background (`debug.themes`) and paints its two test pages in exactly that
color. A fixed build therefore shows one unchanging color across the whole gap: the page's
own paint and the base cmux stands in for it are the same. It opens a Chromium tab on the
first page, records the window at rest for its brightness baseline (`debug.window_record`
writes per-frame `luminance` and `peak` into `frames.json`), then records while the tab
navigates to the second page, whose head holds the parser busy for over a second: the
whole commit-to-paint gap is on camera. No frame may be brighter than the window at rest
by more than `TOLERANCE`, and the theme has to be dark for the check to mean anything.

Matching the pages to the theme is what makes the check read the right thing. Against
pages of some other dark color, a *correct* build still changes the page area's brightness
over the gap (from the page's color to the theme's), and the check would fail the build it
is meant to pass.
"""

from __future__ import annotations

import json
import time
from pathlib import Path

# Rec. 709 luminance (0...1) a frame may gain over the window at rest. The pages are the
# theme's own color, so a fixed build gains nothing at all over the gap and only the tab
# throbber and the address text move; a white page area fills over half the window, which
# raises the mean by about 0.45 and the peak to 1.
TOLERANCE = {"luminance": 0.04, "peak": 0.15}
# The check only means something below this: a light theme loads pages on a light color.
# Nord's window background sits near 0.20, well under a white page's 1.
DARK_THEME_LUMINANCE = 0.35
# A dark Ghostty theme every build ships.
THEME = "Nord"
# How long to wait for a recording's `frames.json` after its last frame, while the encoder
# queue drains.
WRITE_TIMEOUT = 20.0

PAGE = """<!doctype html><meta charset="utf-8"><title>%(title)s</title>
<style>html,body{margin:0;height:100%%;background:%(background)s;color:#8a8a99;font:600 16px -apple-system,sans-serif}
main{padding:24px}</style>
%(head)s
<main>%(title)s</main>
"""
# The theme background the pages fall back to when `debug.themes` gave no `#rrggbb`. The
# judge reports "not measured" in that case, so this only keeps the pages readable.
FALLBACK_BACKGROUND = "#1b1d23"
# A parser-blocking script in the head: the document commits, then nothing paints until it
# returns, so the page area shows whatever cmux put under it for well over a second.
STALL = """<script>
const end = Date.now() + 1400;
while (Date.now() < end) { /* hold the parser */ }
</script>"""

# A page with no background of its own, which paints at once and then keeps loading. This
# is the class the theme base can get wrong in the other direction: the base is the canvas
# under the document for as long as cmux holds it, not only until the first frame, so a
# build that waits for the *load* to end leaves the theme color under painted UA text
# (black on dark) and only turns white seconds later. A build that hands over at first
# contentful paint turns white right after the text appears.
#
# Reported, not judged: white here is correct (the page has no background of its own), so
# what matters is *when* the window brightens, and no run has measured that yet. The
# numbers go in the artifact until one has.
#
# The iframe is what separates the two moments: the main document's text paints as soon as
# it is parsed, but the main frame's load event waits for the subframe, which holds its own
# parser for over a second. First contentful paint and load end are therefore about 1.4 s
# apart, with the page's own content on screen for all of it.
UNSTYLED = """<!doctype html><meta charset="utf-8"><title>Unstyled page</title>
<p>Unstyled page, no background of its own.</p>
<iframe src="%(stall)s" width="80" height="40" style="border:0"></iframe>
"""


def luminance(hex_color: str) -> float:
    """Rec. 709 luminance (0...1) of `#rrggbb`; 1 for anything else (fails the dark check)."""
    text = hex_color.strip().lstrip("#")
    if len(text) != 6:
        return 1.0
    try:
        red, green, blue = (int(text[i:i + 2], 16) / 255 for i in (0, 2, 4))
    except ValueError:
        return 1.0
    return 0.2126 * red + 0.7152 * green + 0.0722 * blue


def _frames(folder: Path) -> dict:
    """`frames.json` of a recording, or an error."""
    try:
        data = json.loads((folder / "frames.json").read_text())
    except (OSError, ValueError) as error:
        return {"error": f"no frames.json in {folder.name}: {error}"}
    return data if isinstance(data, dict) else {"error": f"{folder.name}/frames.json is not an object"}


def _record(driver, folder: Path, seconds: float, act=None) -> dict:
    """Records the window for `seconds`, running `act()` a moment in; returns its frames."""
    folder.mkdir(parents=True, exist_ok=True)
    # A leftover file from an earlier run in the same `out` would be read as
    # this run's frames the moment the poll below starts.
    (folder / "frames.json").unlink(missing_ok=True)
    started = driver.call("debug.window_record", {"dir": str(folder), "seconds": seconds})
    if "error" in started:
        return {"error": f"window_record: {started['error']}"}
    time.sleep(0.2)
    acted = act() if act else None
    time.sleep(seconds)
    # Poll rather than sleep a fixed margin: `finish()` queues the JSON write behind every
    # frame's encode, and a 2.6 s pass at 120 Hz leaves a few hundred of those in the
    # queue. A margin that ran out would read no `frames.json`, which reports "not
    # measured" and silently turns the check off.
    deadline = time.monotonic() + WRITE_TIMEOUT
    while time.monotonic() < deadline:
        frames = _frames(folder)
        if "error" not in frames:
            break
        time.sleep(0.25)
    else:
        frames = _frames(folder)
    if acted is not None:
        frames["acted"] = acted
    return frames


def drive(driver, out: Path) -> None:
    """Dark theme, a Chromium tab on a dark page, then a navigation that stalls before paint."""
    theme = driver.call("settings.set", {"path": "appearance.theme", "value": THEME})
    time.sleep(1.0)
    themes = driver.call("debug.themes", {})
    window = (themes.get("windows") or [{}])[0]
    content = str(window.get("window_background") or "")
    theme_luminance = luminance(content)

    # The pages are the theme's own color, so a page that paints and the base that stands
    # in for it look the same and only a flash changes the window's brightness.
    background = content if theme_luminance < 1.0 else FALLBACK_BACKGROUND
    pages = out / "dark-load-flash"
    pages.mkdir(parents=True, exist_ok=True)
    first = pages / "first.html"
    first.write_text(PAGE % {"title": "First page", "head": "", "background": background})
    slow = pages / "slow.html"
    slow.write_text(PAGE % {"title": "Slow page", "head": STALL, "background": background})
    unstyled = pages / "unstyled.html"
    unstyled.write_text(UNSTYLED % {"stall": slow.name})

    opened = driver.call("action.run", {"action": "openBrowser.chromium", "args": {"url": first.as_uri()}, "focus": True},
                         timeout=90)

    def evaluate(script: str):
        result = driver.call("browser.page.eval", {"script": script}, timeout=20)
        return result.get("value") if "error" not in result else None

    deadline = time.monotonic() + 60
    ready = False
    while time.monotonic() < deadline:
        if evaluate("document.readyState === 'complete' && document.title === 'First page'") is True:
            ready = True
            break
        time.sleep(0.5)
    if not ready:
        state = driver.call("browser.page.state", {}, timeout=20)
        driver.save("dark_load_flash", {"error": "the first page never loaded in a Chromium tab",
                                        "opened": opened, "state": state, "theme": theme})
        return
    time.sleep(1.0)

    rest = _record(driver, pages / "rest", 0.6)
    navigate = _record(driver, pages / "navigate", 2.6,
                       lambda: evaluate(f"location.href = {json.dumps(slow.as_uri())}, true"))
    # Reported only (`UNSTYLED`): how long the theme color stays under a page that has
    # already painted its own content.
    unstyled_frames = _record(driver, pages / "unstyled", 2.6,
                              lambda: evaluate(f"location.href = {json.dumps(unstyled.as_uri())}, true"))
    driver.save("dark_load_flash", {
        "theme": theme, "theme_background": content, "theme_luminance": round(theme_luminance, 4),
        "theme_is_dark": window.get("is_dark"), "page_background": background,
        "opened": opened, "rest": rest, "navigate": navigate, "unstyled": unstyled_frames,
    })


def _unstyled_handover(rest: dict, unstyled: dict) -> dict:
    """When the window brightened on the unstyled page, as a share of the recording.

    Reported, never judged. The page has no background of its own, so a correct build does
    turn the page area white -- the question is whether it does so when the page *paints*
    or only when its load *ends*, and those are about 1.4 s apart here. A small share means
    the hand-over followed the paint; a share near 1 means the theme color stayed under
    text that was already on screen.
    """
    if "error" in unstyled:
        return {"note": f"not measured: {unstyled['error']}"}
    at_rest = [float(value) for value in rest.get("luminance") or []]
    during = [float(value) for value in unstyled.get("luminance") or []]
    if len(at_rest) < 10 or len(during) < 60:
        return {"note": f"not measured: {len(at_rest)} frames at rest, {len(during)} on the unstyled page"}
    threshold = max(at_rest) + TOLERANCE["luminance"]
    risen = next((index for index, value in enumerate(during) if value > threshold), None)
    if risen is None:
        return {"frames": len(during), "note": "the page area never brightened"}
    return {"frames": len(during), "rise_frame": risen, "rise_share": round(risen / len(during), 3),
            "threshold": round(threshold, 4)}


def judge(data: dict, refresh: float) -> dict:
    """Fails when a frame of the navigation was brighter than the window at rest.

    A run that could not measure the scenario says so and never fails the judge: this
    one needs an owned Mac in a dark theme, so most runs have no result for it, and a
    missing measurement is not a flash. Only a run that did measure can fail.
    """
    del refresh  # brightness, not pacing
    if "error" in data:
        return {"ok": True, "measured": False, "problems": [],
                "note": f"not measured: {data['error']}"}
    unmeasured: list[str] = []
    theme_luminance = float(data.get("theme_luminance", 1))
    if theme_luminance > DARK_THEME_LUMINANCE or data.get("theme_is_dark") is not True:
        unmeasured.append(f"the theme is not dark (background {data.get('theme_background')}, "
                          f"luminance {theme_luminance:.3f}, is_dark {data.get('theme_is_dark')})")
    verdict: dict = {"theme_luminance": round(theme_luminance, 4)}
    rest, navigate = data.get("rest") or {}, data.get("navigate") or {}
    for name, frames in (("rest", rest), ("navigate", navigate)):
        if "error" in frames:
            unmeasured.append(f"{name}: {frames['error']}")
    problems: list[str] = []
    if not unmeasured:
        for key, tolerance in TOLERANCE.items():
            at_rest = [float(value) for value in rest.get(key) or []]
            during = [float(value) for value in navigate.get(key) or []]
            if len(at_rest) < 10 or len(during) < 60:
                unmeasured.append(f"{len(at_rest)} frames at rest, {len(during)} during the navigation")
                break
            base, worst = max(at_rest), max(during)
            verdict[key] = {"rest": round(base, 4), "worst": round(worst, 4),
                            "gain": round(worst - base, 4), "tolerance": tolerance}
            if worst - base > tolerance:
                problems.append(f"the page flashed: {key} rose from {base:.3f} at rest to {worst:.3f} "
                                f"(over {tolerance:.2f}) while the page loaded")
    if unmeasured:
        # A run that reports itself unmeasured never also fails. The loop above
        # can record a `luminance` problem and only then find `peak` too short,
        # which today cannot happen (the recorder appends to both arrays for
        # the same frames) but must not become a FAIL on a half-measured run.
        problems = []
    verdict["frames"] = {"rest": len(rest.get("peak") or []), "navigate": len(navigate.get("peak") or [])}
    verdict["unstyled"] = _unstyled_handover(rest, data.get("unstyled") or {})
    verdict["problems"] = problems
    verdict["measured"] = not unmeasured
    verdict["ok"] = not problems
    if unmeasured:
        verdict["note"] = "not measured: " + "; ".join(unmeasured)
    return verdict


def markdown_row(verdict: dict) -> str:
    """The scenario's row of golden.py's table."""
    if not verdict.get("measured"):
        return f"| dark_load_flash | report |  |  |  | {verdict.get('note', 'not measured')} (reported only) |"
    problems = verdict.get("problems") or []
    peak, mean = verdict.get("peak") or {}, verdict.get("luminance") or {}
    notes = list(problems) or [f"no frame brighter than the window at rest (theme luminance "
                               f"{verdict.get('theme_luminance', 0):.3f})"]
    brightness = ""
    if peak and mean:
        brightness = (f"peak {peak['rest']:.3f} → {peak['worst']:.3f}, "
                      f"mean {mean['rest']:.3f} → {mean['worst']:.3f}")
    return f"| dark_load_flash | {'ok' if verdict.get('ok') else 'FAIL'} | {brightness} |  |  | {'; '.join(notes)} |"
