"""Chromium page zoom and DOM fullscreen checks for the browser-use live suite."""


def check_zoom(run, rpc, wait):
    def action(name):
        reply = rpc("action.run", {"action": name, "focus": True}) or {}
        run.check(reply.get("ran") is True, f"{name} runs on the selected tab")

    def geometry():
        return run.js("({dpr: devicePixelRatio, width: innerWidth})")

    action("browserZoomReset")
    base = wait(geometry, 5)
    run.check(bool(base and base["width"] > 0 and base["dpr"] > 0), f"initial viewport {base}")
    if not base or base["width"] <= 0 or base["dpr"] <= 0:
        return
    try:
        action("browserZoomIn")
        def zoomed_in():
            value = geometry()
            return value and value["dpr"] > base["dpr"] and value["width"] < base["width"]
        run.check(wait(zoomed_in, 5), "zoom in increases pixel ratio and narrows CSS viewport")
        run.shot("zoom-in")

        action("browserZoomOut")
        def restored():
            value = geometry()
            return (value and abs(value["dpr"] - base["dpr"]) < 0.001
                    and abs(value["width"] - base["width"]) <= 1)
        run.check(wait(restored, 5), "zoom out restores the original pixel ratio and viewport width")
        run.shot("zoom-out")
    finally:
        action("browserZoomReset")


def check_fullscreen(run, wait):
    try:
        for control, states in (("enter", [True]), ("exit", [True, False])):
            point = run.js(f"""(() => {{
                const button = document.getElementById('{control}');
                const rect = button.getBoundingClientRect();
                const x = rect.x + rect.width / 2, y = rect.y + rect.height / 2;
                return document.elementFromPoint(x, y) === button ? {{x, y}} : null;
            }})()""")
            run.check(bool(point), f"fullscreen {control} control is visible")
            if not point:
                return
            reply = run.page("mouse", kind="click", button="left", **point) or {}
            run.check(reply.get("native") is True, f"fullscreen {control} receives native mouse input")
            def transitioned():
                return (run.js("window.fullscreenTransitions") == states
                        and run.js("!!document.fullscreenElement") is states[-1])
            run.check(wait(transitioned, 5), f"fullscreen {control} changes the DOM and emits fullscreenchange")
            run.shot(f"fullscreen-{control}")
    finally:
        run.js("if (document.fullscreenElement) document.exitFullscreen()")
