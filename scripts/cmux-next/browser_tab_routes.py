"""Chromium link routing checks for the browser-use tabs scenario."""

import json


def check_tab_routes(run, base, rpc, wait):
    def tabs():
        return {row["id"]: row.get("url") for row in rpc("browser.page.tabs", {"all": True})["tabs"]}

    for element in ("newtab", "noopener", "window-open", "cmd-click", "middle-click"):
        rpc("browser.page.select_tab", {"tab": run.tab})
        visible = wait(lambda: run.js("document.visibilityState") == "visible", 5)
        run.check(visible, f"{element}: the source tab is visible")
        if not visible:
            return

        # Use native CEF input. Calling element.click() would skip command modifiers
        # and give window.open a different user activation path.
        point = run.js("""(() => {
            const el = document.getElementById(%s);
            el.scrollIntoView({block: 'center'});
            const r = el.getBoundingClientRect(), x = r.x + r.width / 2, y = r.y + r.height / 2;
            return el.contains(document.elementFromPoint(x, y)) ? {x, y} : null;
        })()""" % json.dumps(element))
        run.check(point, f"{element}: the control is visible and unobstructed")
        if not point:
            continue

        expected = base + "/search.html" + ("" if element == "newtab" else "?route=" + element)
        before = tabs()
        modifiers = ["meta"] if element == "cmd-click" else []
        button = "middle" if element == "middle-click" else "left"
        clicked = run.page("mouse", kind="click", button=button, modifiers=modifiers, **point)
        run.check(clicked.get("native") is True, f"{element}: Chromium receives native input")

        def destination():
            current = tabs()
            added = current.keys() - before.keys()
            if len(added) == 1:
                tab = next(iter(added))
                if current[tab] == expected:
                    return tab

        tab = wait(destination, 10)
        run.check(tab, f"{element}: exactly one new cmux tab opens {expected}")
        if tab:
            try:
                script = "location.href === %s && window.opener === null" % json.dumps(expected)
                loaded = wait(lambda: rpc("browser.page.eval", {"tab": tab, "script": script}).get("value") is True, 8)
                run.check(loaded, f"{element}: the destination loads without an opener")
                run.shot(element + "-destination")
            finally:
                rpc("action.run", {"action": "closeTab", "target": "tab:" + tab, "wait": True})
                run.check(wait(lambda: tab not in tabs(), 5), f"{element}: the test destination closes")
                rpc("browser.page.select_tab", {"tab": run.tab})
        run.check(run.js("location.href") == base + "/tabs.html", f"{element}: the source URL stays put")
