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


def analyze(frames, mark, width, item, tolerance):
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
    result["source_blank_frames"] = sum(judge.is_blank(g, before, end, tolerance) for _, g in after)
    result["source_content"] = rect
    result["scope"] = "source content edge bands inset past native focus ring, plus sidebar; source content checked for blank frames"
    return result


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
            def shown_ready():
                answer = h.c.call("browser.page.eval", {"tab": shown, "script": "document.readyState"}, timeout=5)
                return isinstance(answer, dict) and not answer.get("error") and answer.get("value") == "complete"

            wait_until(shown_ready, "shown fixture loaded before cold creation", timeout=15)
            time.sleep(h.args.settle)  # sleep-ok: pre-trigger visual baseline, after fixture readiness
            _checked(h.c.action("openBrowser.chromium", target=f"tab:{shown}", focus=False,
                                url="file://" + page + "?cold"), "create background tab")
            tabs = h.wait_tabs(2)
            cold = next(t["id"] for t in tabs if t["id"] != shown)
            if h.selected_tab() != shown:
                raise RuntimeError("background creation selected the cold tab; cannot measure cold activation")
            rect = h.chrome_rect()
            if rect is None:
                raise RuntimeError("debug.pane_chrome source bounds required")
            # Content-edge bands avoid a native focus-ring change when the move focuses its destination.
            regions = border_regions(rect, inset=max(4, round(4 * h.rec.scale)))
            if h.sidebar:
                regions.append(h.sidebar)
            trigger = (lambda: h.c.action("tab.focus", target=f"tab:{cold}")) if name == "tab-activate-cold" else (
                lambda: h.c.action("moveSurfaceToPaneRight", target=f"tab:{shown}"))
            result = step(h, name, load, round_number, trigger)
            if h.selected_tab() != cold:
                result[1]["error"] = "the source did not select its cold replacement by capture end"
            result[1].update(cold_evidence=True, source_content=rect, unchanged_regions=regions,
                             cold_tab=cold, source_tab=shown, source_pane=h.pane_id,
                             cold_setup="created without focus after calibration; never selected/evaluated")
            out.append(result)
        finally:
            h.workspace_id, h.pane_id = saved
            if workspace is not None and workspace not in old_workspaces:
                h.c.action("closeWorkspace", target=f"workspace:{workspace}", confirm=True)
            h.c.action("goToWorkspace", workspace=saved[0])
            h.wait_workspace(saved[0], "return from CMUX-865 scratch workspace")
    return out
