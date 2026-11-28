"""CMUX-865: never-selected tabs, with source-region frame evidence.

The visual workload is separate from the deterministic native test that exhausts
ContentPresentationScheduler's budget. CPU load does not prove that condition.
"""
from __future__ import annotations

import os
import time
import tab_switch_judge as judge
from state_wait import wait_until

SCENARIOS = ("tab-activate-cold", "tab-move-cold-source")


def border_regions(rect, thickness=2, inset=0):
    """Disjoint content-edge bands, optionally inset past the native focus ring."""
    x0, y0, x1, y1 = rect
    x0, y0, x1, y1 = x0 + inset, y0 + inset, x1 - inset, y1 - inset
    if x1 - x0 <= 2 * thickness or y1 - y0 <= 2 * thickness:
        raise ValueError("source pane is too small for border regions")
    return [(x0, y0, x1, y0 + thickness), (x0, y1 - thickness, x1, y1),
            (x0, y0 + thickness, x0 + thickness, y1 - thickness),
            (x1 - thickness, y0 + thickness, x1, y1 - thickness)]


def unchanged(frames, mark, width, regions, tolerance=0.01):
    """Count every transient changed frame, even if the final pixels match.

    Compare to the last pre-trigger frame, never the final frame. Rectangles
    are explicit in the receipt: this metric cannot claim unmeasured regions.
    """
    before = [frame for t, frame in frames if t <= mark]
    after = [(t, frame) for t, frame in frames if t > mark]
    if not before or not after or not regions:
        raise ValueError("unchanged-region measurement needs baseline, frames and regions")
    if width <= 0 or any(len(frame) % width for _, frame in frames):
        raise ValueError("malformed capture dimensions")
    for _, frame in frames:
        height = len(frame) // width
        if any(not (0 <= x0 < x1 <= width and 0 <= y0 < y1 <= height)
               for x0, y0, x1, y1 in regions):
            raise ValueError("unchanged region outside captured frame")
    baseline = [judge.crop(before[-1], width, rect) for rect in regions]
    changed = []
    maximum = 0.0
    per_region_max = [0.0] * len(regions)
    for t, frame in after:
        shares = [judge.diff_share(base, judge.crop(frame, width, rect))
                  for base, rect in zip(baseline, regions)]
        per_region_max = [max(old, share) for old, share in zip(per_region_max, shares)]
        # A large unchanged sidebar must not dilute a flash on a thin pane edge.
        share = max(shares)
        maximum = max(maximum, share)
        if share > tolerance:
            changed.append(round((t - mark) * 1000, 3))
    return {"regions": regions, "frames": len(after), "changed_frames": len(changed),
            "changed_ms": changed, "max_changed_share": maximum, "tolerance": tolerance,
            "per_region_max_changed_share": per_region_max,
            "count_unit": "captured samples", "comparison": "each region independently"}


def analyze(frames, mark, width, item, tolerance, reference=None):
    result = unchanged(frames, mark, width, item["unchanged_regions"], tolerance)
    rect = item["source_content"]
    # Validate source bounds too; malformed crops must not look like empty content.
    unchanged(frames, mark, width, [rect], tolerance)
    before = [judge.crop(g, width, rect) for t, g in frames if t <= mark][-1]
    after = [(t, judge.crop(g, width, rect)) for t, g in frames if t > mark]
    end = after[-1][1]
    if judge.flatness(before) >= judge.FLAT_SHARE:
        raise ValueError("source baseline is blank or fixture never loaded")
    if judge.flatness(end) >= judge.FLAT_SHARE:
        raise ValueError("source endpoint is blank or replacement never loaded")
    if judge.diff_share(before, end) <= tolerance:
        raise ValueError("source endpoint never changed to the replacement fixture")
    if reference is None:
        raise ValueError("independently recorded replacement reference required")
    expected = judge.crop(reference, width, rect)
    if judge.flatness(expected) >= judge.FLAT_SHARE or judge.diff_share(end, expected) > tolerance:
        raise ValueError("source endpoint does not match the independently verified replacement")
    result["source_blank_frames"] = sum(judge.is_blank(g, before, end, tolerance) for _, g in after)
    result["source_content"] = rect
    result["scope"] = "source content, static pane chrome and empty tab-strip space; intended tab changes and focus ring excluded"
    result["region_names"] = item.get("unchanged_region_names", [])
    result["window"] = item.get("recorded_window")
    result["unloaded_before"] = item.get("unloaded_before")
    result["reference"] = item.get("reference_receipt")
    return result


def recorded_reference(frames, flips, item, width, tolerance):
    """Use a separately loaded fixture, recorded before the tested tab exists."""
    start, end = (flips.get(item.get(key)) for key in ("reference_start", "reference_end"))
    if start is None or end is None or end - start < .2:
        raise ValueError("replacement reference interval missing or too short")
    samples = [(t, g) for t, g in frames if start < t <= end]
    if len(samples) < 2 or samples[-1][0] - samples[0][0] < .15:
        raise ValueError("replacement reference has insufficient recorded frames")
    expected = samples[-1][1]
    rect = item["source_content"]
    target = judge.crop(expected, width, rect)
    if any(judge.diff_share(judge.crop(g, width, rect), target) > tolerance for _, g in samples):
        raise ValueError("independent replacement reference did not settle")
    # DOM readiness alone cannot prove paint. A patch inside the fixture's
    # central tan rectangle must have its expected captured luma (146), with
    # slack for video compression/color conversion. This excludes a settled
    # partial blank from becoming even the independent reference.
    x0, y0, x1, y1 = rect
    patch = (x0 + (x1-x0)*45//100, y0 + (y1-y0)*55//100,
             x0 + (x1-x0)*55//100, y0 + (y1-y0)*65//100)
    pixels = b"".join(expected[y*width+patch[0]:y*width+patch[2]] for y in range(patch[1], patch[3]))
    if not pixels or sum(abs(p-146) <= 12 for p in pixels) / len(pixels) < .95:
        raise ValueError("independent reference fixture color was not painted")
    return expected


def pixel_rect(value, scale):
    if isinstance(value, (list, tuple)) and len(value) == 4:
        x, y, w, h = value  # debug.pane_chrome's wire format
    elif isinstance(value, dict) and all(k in value for k in ("x", "y", "width", "height")):
        x, y, w, h = (value[k] for k in ("x", "y", "width", "height"))
    else:
        raise ValueError("missing pane geometry")
    if w <= 0 or h <= 0:
        raise ValueError("empty pane geometry")
    return tuple(round(v * scale) for v in (x, y, x + w, y + h))


def geometry(window_list, surfaces, chrome, pane_id, window_bounds, display, scale):
    """Join the recorder's global crop to a native window and its exact pane.

    debug.window_list uses AppKit's bottom-left screen points; the recorder
    uses the primary display's top-left points. Ambiguous matches are errors.
    """
    matches = []
    for window in window_list.get("windows", []):
        f = window.get("frame") or {}
        if not window.get("visible") or window.get("kind") != "main" or not all(k in f for k in ("x", "y", "width", "height")):
            continue
        bounds = [f["x"], display[3] - f["y"] - f["height"], f["width"], f["height"]]
        if all(abs(a - b) <= .5 for a, b in zip(bounds, window_bounds)):
            matches.append(window)
    if len(matches) != 1:
        raise ValueError("recorded window has no unique native-window match")
    number = str(matches[0]["id"])
    native = [w for w in surfaces.get("windows", []) if str(w.get("window")) == number]
    if len(native) != 1 or not any(p.get("pane") == pane_id for p in native[0].get("panes", [])):
        raise ValueError("source pane is not in the recorded native window")
    panes = [(w, p) for w in chrome.get("windows", []) for p in w.get("panes", []) if p.get("pane") == pane_id]
    if len(panes) != 1:
        raise ValueError("source pane chrome is missing or ambiguous across windows")
    window, pane = panes[0]
    if pane.get("vertical_tabs") or pane.get("strip_hidden"):
        raise ValueError("cold fixture requires a visible horizontal tab strip")
    return {"native_window": number, "window": window.get("id"), "pane": pane_id,
            "bounds": list(window_bounds), "content": pixel_rect(pane.get("border"), scale),
            "cell": pixel_rect(pane.get("cell"), scale), "strip": pixel_rect(pane.get("strip"), scale),
            "empty_strip": pixel_rect(pane.get("strip_empty"), scale),
            "sidebar": pixel_rect(window.get("sidebar"), scale)}


def intersect(a, b):
    r = (max(a[0], b[0]), max(a[1], b[1]), min(a[2], b[2]), min(a[3], b[3]))
    return r if r[2] > r[0] and r[3] > r[1] else None


def stable_regions(before, after, scale):
    """Only exclude intentional tab changes and the native focus outline."""
    for key in ("native_window", "window", "pane", "bounds", "content", "cell", "strip", "sidebar"):
        if before[key] != after[key]:
            raise ValueError(f"source geometry changed during action: {key}")
    empty = intersect(before["empty_strip"], after["empty_strip"])
    if empty is None or empty[2] - empty[0] < 8:
        raise ValueError("no measurable static tab-strip space")
    regions = border_regions(before["content"], inset=max(4, round(4 * scale)))
    names = ["content-top", "content-bottom", "content-left", "content-right"]
    # Empty space lies beyond the tabs and + controls in BOTH layouts, so
    # selecting or removing a tab cannot exempt a strip-wide blank frame.
    regions.extend([empty, before["sidebar"]])
    names.extend(["static-tab-strip", "sidebar"])
    x0, y0, x1, y1 = before["cell"]
    cx0, cy0, cx1, cy1 = before["content"]
    sx0, sy0, sx1, sy1 = before["strip"]
    pad = max(2, round(2 * scale))
    # Cell space outside the changing strip/content (excluding focus ring).
    for name, r in (("chrome-left", (x0, sy1, cx0-pad, y1)),
                    ("chrome-right", (cx1+pad, sy1, x1, y1)),
                    ("chrome-bottom", (x0, cy1+pad, x1, y1)),
                    ("chrome-top", (x0, y0, x1, sy0))):
        if r[2] > r[0] and r[3] > r[1]:
            regions.append(r)
            names.append(name)
    return regions, names


def unloaded(surfaces, shown, cold):
    phases = (surfaces.get("hibernation") or {}).get("page_phases")
    if not isinstance(phases, dict) or shown not in phases:
        raise ValueError("live browser-cache diagnostic unavailable for shown fixture")
    if cold in phases:
        raise ValueError("replacement already has a native browser page before activation")
    return {"diagnostic": "debug.surfaces.hibernation.page_phases", "shown": shown,
            "shown_phase": phases[shown], "cold": cold, "cold_cached": False}


def measured_geometry(h):
    return geometry(_checked(h.c.call("debug.window_list"), "native windows"),
                    _checked(h.c.call("debug.surfaces"), "surface diagnostics"),
                    _checked(h.c.call("debug.pane_chrome"), "pane chrome"),
                    h.pane_id, h.rec.window, h.rec.display, h.rec.scale)


def fixture_ready(h, tab, expected):
    script = ('JSON.stringify({ready:document.readyState,text:document.getElementById("state")?.textContent,'
              'color:getComputedStyle(document.getElementById("state")).backgroundColor})')
    answer = h.c.call("browser.page.eval", {"tab": tab, "script": script}, timeout=5)
    import json
    try:
        value = json.loads(answer.get("value", ""))
    except (AttributeError, TypeError, ValueError):
        return False
    return value == {"ready": "complete", "text": expected,
                     "color": "rgb(179, 143, 83)" if expected == "Cold replacement" else "rgb(89, 119, 145)"}


def _checked(reply, what):
    if not isinstance(reply, dict) or reply.get("error"):
        raise RuntimeError(f"{what}: {reply}")
    return reply


def run(h, load, round_number, scenarios, step):
    """Each scenario owns a scratch workspace: two source tabs, one never selected.

    Cold tabs are created after calibration, without focus permission. No eval,
    calibration or screenshot call selects them before the measured trigger.
    """
    out = []
    saved = h.workspace_id, h.pane_id
    for name in SCENARIOS:
        if name not in scenarios:
            continue
        workspace = None
        try:
            old_workspaces = set(h.workspace_ids())
            _checked(h.c.action("workspace new"), "create scratch workspace")
            workspace = wait_until(
                lambda: (lambda current: current if current not in old_workspaces else None)(h.focused_workspace()),
                "new scratch workspace focused", timeout=15)
            _, pane = h.c.focused_tabs()
            if not pane or not pane.get("id"):
                raise RuntimeError("scratch pane unavailable")
            h.workspace_id, h.pane_id = workspace, pane["id"]
            tabs = h.wait_tabs(1)
            terminal = tabs[0]["id"]
            page = os.path.join(h.root, f"cold-{name}-{round_number}.html")
            with open(page, "w") as handle:
                handle.write('<html><body style="margin:0;background:#273544;color:#eee">'
                             '<div style="height:45vh;background:#597791">CMUX-865 frame fixture</div>'
                             '<div id=state style="position:absolute;inset:25%;background:#597791">Shown page</div><script>if(location.search){document.getElementById("state").textContent="Cold replacement";document.getElementById("state").style.background="#b38f53"}</script></body></html>')
            _checked(h.c.action("openBrowser.chromium", target=f"tab:{terminal}",
                                url="file://" + page), "create shown page")
            tabs = h.wait_tabs(2)
            shown = next(t["id"] for t in tabs if t["id"] != terminal)
            _checked(h.c.action("closeTab", target=f"tab:{terminal}"), "remove scratch terminal")
            h.wait_tabs_gone([terminal], "scratch terminal closed")
            if name == "tab-move-cold-source":
                _checked(h.c.action("splitRight", target=f"pane:{h.pane_id}"), "create destination")
                _checked(h.c.action("tab.focus", target=f"tab:{shown}"), "select source")
            wait_until(lambda: fixture_ready(h, shown, "Shown page"), "shown fixture loaded", timeout=15)
            # A disposable, separately loaded tab supplies the reference. The
            # actual cold tab does not exist until this interval is recorded.
            _checked(h.c.action("openBrowser.chromium", target=f"tab:{shown}",
                                url="file://" + page + "?cold"), "create reference fixture")
            reference_tab = next(t["id"] for t in h.wait_tabs(2) if t["id"] != shown)
            wait_until(lambda: fixture_ready(h, reference_tab, "Cold replacement"), "reference fixture loaded", timeout=15)
            reference_geometry = measured_geometry(h)
            time.sleep(max(.3, h.args.settle))  # sleep-ok: reference paint settles before its independent recording
            ref_start, ref_end = (f"{name}/{load}/{round_number}:reference-{part}" for part in ("start", "end"))
            h.rec.flip(ref_start)
            time.sleep(.4)  # sleep-ok: independent settled reference interval in the same retained recording
            h.rec.flip(ref_end)
            _checked(h.c.action("closeTab", target=f"tab:{reference_tab}"), "close disposable reference")
            h.wait_tabs_gone([reference_tab], "reference removed")
            _checked(h.c.action("tab.focus", target=f"tab:{shown}"), "restore source baseline")
            wait_until(lambda: fixture_ready(h, shown, "Shown page"), "source restored", timeout=15)
            time.sleep(h.args.settle)  # sleep-ok: pre-trigger visual baseline, after fixture readiness
            _checked(h.c.action("openBrowser.chromium", target=f"tab:{shown}", focus=False,
                                url="file://" + page + "?cold"), "create background tab")
            tabs = h.wait_tabs(2)
            cold = next(t["id"] for t in tabs if t["id"] != shown)
            if h.selected_tab() != shown:
                raise RuntimeError("background creation selected the cold tab; cannot measure cold activation")
            time.sleep(max(.3, h.args.settle))  # sleep-ok: finish background tab-strip insertion before trigger
            before_geometry = measured_geometry(h)
            if reference_geometry["content"] != before_geometry["content"]:
                raise ValueError("reference and source content bounds differ")
            cold_receipt = unloaded(_checked(h.c.call("debug.surfaces"), "cold cache diagnostic"), shown, cold)
            rect = before_geometry["content"]
            trigger = (lambda: h.c.action("tab.focus", target=f"tab:{cold}")) if name == "tab-activate-cold" else (
                lambda: h.c.action("moveSurfaceToPaneRight", target=f"tab:{shown}"))
            result = step(h, name, load, round_number, trigger)
            if h.selected_tab() != cold:
                result[1]["error"] = "the source did not select its cold replacement by capture end"
            # Capture end precedes all postcondition evaluation: it cannot
            # warm the tested tab or turn its recorded endpoint into an oracle.
            after_geometry = measured_geometry(h)
            regions, region_names = stable_regions(before_geometry, after_geometry, h.rec.scale)
            if not fixture_ready(h, cold, "Cold replacement"):
                result[1]["error"] = "replacement endpoint DOM does not match fixture"
            if name == "tab-move-cold-source":
                owners = [p.get("id") for w in h.c.topology().get("workspaces", []) for s in w.get("screens", [])
                          for p in s.get("panes", []) if any(t.get("id") == shown for t in p.get("tabs", []))]
                if len(owners) != 1 or owners[0] == h.pane_id:
                    result[1]["error"] = "moved tab did not acquire a distinct destination pane"
            result[1].update(cold_evidence=True, source_content=rect, unchanged_regions=regions,
                             cold_tab=cold, source_tab=shown, source_pane=h.pane_id,
                             cold_setup="native cache absent before trigger; never selected/evaluated",
                             unloaded_before=cold_receipt, unchanged_region_names=region_names,
                             recorded_window=before_geometry, reference_start=ref_start, reference_end=ref_end,
                             reference_receipt={"tab": reference_tab, "dom": "Cold replacement", "closed_before_cold_creation": True})
            out.append(result)
        finally:
            h.workspace_id, h.pane_id = saved
            if workspace is not None and workspace not in old_workspaces:
                h.c.action("closeWorkspace", target=f"workspace:{workspace}", confirm=True)
            h.c.action("goToWorkspace", workspace=saved[0])
            h.wait_workspace(saved[0], "return from CMUX-865 scratch workspace")
    return out
