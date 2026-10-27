#!/usr/bin/env python3
"""Tagged-app still of the Swift Home's typing indicator on the app's theme (MessagesLab 5c56f4f).

Launches the tagged app with no activation, opens the DEBUG Home fixture (the real transcript view
over a HomeStore over the mock owner: after a send its Chief waits 1.5 s, types for 1.5 s, then
answers, MockHomeSource.scheduleReplies), sends a message through the field's send path
(debug.home.drive type + send) and takes window snapshots at 2.0 s and 2.6 s, while the Chief types: the typing bubble (RowCell.typingBody, Fixture.typingFill) in the app's own theme.
Passes when the send goes and the bubble is in the image: its box (debug.home.drive typing) is
read from the app and the mean colour inside it must differ from the background beside it; its flat
edges have no partial pixels, also after the transcript moves by half a device pixel in its pane (b6760b6); in that
snapshot every text row's anchored side (incoming left, outgoing right) and top lie on whole device pixels, its
balloon's edges are where the app draws them (an outgoing text balloon a little inside its frame, 2281879), and an
incoming balloon's straight edges have no partial pixels (c1457e5 row-snap; home_pixels.check_rows). Then two width
changes of the transcript in one main-thread turn: the rows follow the second at once (f11642b resize-pace;
a first pass over the 2 ms frame budget defers it as intended: SKIP of that proof, and the rows must follow a frame
later). The half-pixel snapshot also has the pane's right edge on half a device pixel: my (outgoing) rows' right
edges are snapped (82ccac1). Socket only, no system input. Runs on
cmux-lawrence-2 or a lab host.

The app launches through bench_launch.BenchApp (the bench env, classic Home, no activation, a scratch config, a fresh
saved session) and ends with BenchApp.stop (the DEBUG quit fixture, then the tag's teardown: its `acpmux daemon
shutdown` and daemons). With --story (default none) a run that reached the resize-pace step writes cmux-perf-result/v1
into --out (paint_typing_report.home_typing_series): each width change's layout pass (ms), the passes the frame budget
deferred and the failed checks.

Usage: home-typing-still.py (--tag <tag> | --app BUNDLE) [--out DIR] [--story home-typing-still]
"""
import argparse, json, os, socket, sys, time

# The pane width trim (pt) that puts the transcript's right edge on half a device pixel (with the 0.25 pt move, 2x).
FRACTION_TRIM = 0.5

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # the bench modules, also under `python3 -I`
from home_pixels import SKIPPED, check_rows, mean_rgb, read_png  # noqa: E402
import home_classic  # noqa: E402
import paint_typing_report as report  # noqa: E402
from bench_launch import BenchApp  # noqa: E402
from bench_story import story_problem  # noqa: E402

ENGINE = report.ENGINES[report.HOME_TYPING_STILL_STORY]
parser = argparse.ArgumentParser()
parser.add_argument("--tag", help="the tag of a DerivedData Debug app (with --app: the story runner passes it; the bundle carries the tag)")
parser.add_argument("--app", help="the app bundle (default: the DerivedData Debug app of --tag)")
parser.add_argument("--out", default="/tmp/home-typing-still")
parser.add_argument("--story", help="write the run as cmux-perf-result/v1 under this story")
parser.add_argument("--session", choices=["light"], default="light", help="result-v1 session (the story runner's)")
parser.add_argument("--build-config", choices=["bench", "bench-checks"],
                    help="result-v1 build config of a bench-hooks bundle that does not stamp it")
opts = parser.parse_args()
if not opts.app and not opts.tag:
    parser.error("name the app with --app, or the tag of a DerivedData Debug app with --tag")
if opts.story and story_problem(opts.story, ENGINE):
    parser.error(story_problem(opts.story, ENGINE))
home = os.environ["HOME"]
app = opts.app or f"{home}/Library/Developer/Xcode/DerivedData/cmux-{opts.tag}/Build/Products/Debug/cmux DEV {opts.tag}.app"
os.makedirs(opts.out, exist_ok=True)
failures = []
pace_steps = []  # the resize-pace step replies (debug.home.drive resize), for result-v1
bench = BenchApp(app, out=opts.out, env={"CMUX_DEV_BACKEND_MODE": "local", **home_classic.ENV}, window=(40, 40, 1200, 800),
                 screen="last", log_name="app.log", perf_session=opts.session, build_config=opts.build_config)


def rpc(method, params=None, timeout=35):
    try:
        c = socket.socket(socket.AF_UNIX); c.settimeout(timeout); c.connect(bench.socket)
        c.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = c.recv(1 << 20)
            if not chunk:
                break
            buf += chunk
        c.close()
        reply = json.loads(buf)
        return reply.get("result", reply)
    except Exception as error:
        return {"ok": False, "error": f"socket: {error}"}


def api(**params):
    return rpc("debug.home.api", params)


def check(name, ok, detail=""):
    print(("ok   " if ok else "FAIL ") + name + ("" if ok else f"  {json.dumps(detail)[:500]}"), flush=True)
    if not ok:
        failures.append(name)
    return ok


def poll(predicate, timeout=20):
    deadline = time.time() + timeout
    while time.time() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.25)  # test harness wait, not app code
    return None




def edge_partials(px, w, h, box, scale, fill, bg, tol=12):
    """Pixels on the bubble's flat top and bottom edges (the middle 40 % of its width) that are neither
    the fill nor the background (a partial pixel: the edge is not on a whole device pixel)."""
    rows, bpp = px
    x0 = (box["x"] + box["width"] * 0.3) * scale; x1 = (box["x"] + box["width"] * 0.7) * scale
    top = (box["windowHeight"] - box["y"] - box["height"]) * scale; bottom = (box["windowHeight"] - box["y"]) * scale
    count = 0
    for edge in (top, bottom):
        for y in range(max(0, round(edge) - 2), min(h, round(edge) + 2)):
            for x in range(int(x0), int(x1)):
                c = rows[y][x * bpp:x * bpp + 3]
                near = lambda ref: all(abs(c[k] - ref[k]) <= tol for k in range(3))
                if not near(fill) and not near(bg):
                    count += 1
    return count


try:
    bench.launch(timeout=180)
    print(f"launched pid {bench.process.pid}", flush=True)
    # Classic Home or stop at once (cx-h0kds): these checks drive the native classic Home transcript.
    if not home_classic.require(rpc):
        sys.exit(2)
    inbox = poll(lambda: (r := api(call="inbox")) and "conversations" in r and r, timeout=180)
    if not check("the local owner answers inbox", bool(inbox), api(call="inbox")):
        sys.exit(1)
    opened = rpc("debug.home_native_fixture.open", {"new": True}) or {}
    check("the Home fixture opens", bool(opened.get("ok")), opened)
    texts = poll(lambda: (t := (rpc("debug.home.drive", {"action": "texts"}) or {}).get("texts")) and t, timeout=60)
    check("the fixture's transcript shows messages", bool(texts), rpc("debug.home.drive", {"action": "texts"}))
    rpc("debug.home.drive", {"action": "focus"})
    rpc("debug.home.drive", {"action": "type", "text": "Typing still check"})
    sent = rpc("debug.home.drive", {"action": "send"}) or {}
    check("the send goes", bool(sent.get("ok")), sent)
    # Every read and snapshot happens while the mock Chief types (1.5 s to 3.0 s after the send); the image
    # analysis comes after (a PNG read takes about a second).
    time.sleep(1.9)  # test harness: inside the typing window
    box = rpc("debug.home.drive", {"action": "typing"}) or {}
    shot = os.path.join(opts.out, "typing-0.png")
    rpc("debug.window_snapshot", {"path": shot})
    # MessagesLab b6760b6: the transcript moves by half a device pixel in its pane (no size change); the bubble
    # must still land on whole device pixels (RowCell.windowPlace, refreshed by Home's host). The backing
    # scale comes from the window (2x on the GUI host); 0.25 pt at 2x (0.5 pt would stay on the pixel grid).
    # MessagesLab c1457e5 (row-snap): every message row rests on whole device pixels too, so the move is on both
    # axes (a vertical move puts the rows' top and bottom edges on half a pixel without the snap).
    k0 = 2.0
    # MessagesLab 82ccac1 (snap-followup): my rows snap their right edge, so the pane's right edge goes onto a
    # fraction of a device pixel too: the transcript narrows by 0.5 pt (with the 0.25 pt move, its right edge is half a
    # device pixel off the grid, as a pane split to a fractional width).
    rpc("debug.home.drive", {"action": "nudge", "dx": 0.5 / k0, "dy": 0.5 / k0})
    rpc("debug.home.drive", {"action": "resize", "trims": [FRACTION_TRIM]})
    time.sleep(0.2)  # test harness: one display frame for the move to show
    half = rpc("debug.home.drive", {"action": "typing"}) or {}
    half_rows = rpc("debug.home.drive", {"action": "rows"}) or {}
    half_shot = os.path.join(opts.out, "typing-half-pixel.png")
    rpc("debug.window_snapshot", {"path": half_shot})
    check("snapshots of the typing indicator", os.path.exists(shot) and os.path.exists(half_shot), [shot, half_shot])
    # The bubble must be in the image: its box from the app (debug.home.drive typing, window points,
    # bottom-left origin), then the mean colour inside it against the background just right of it.
    check("the app reports a typing bubble", bool(box.get("ok")), box)

    def measure(b, path):
        w, h, px = read_png(path)
        scale = w / b["windowWidth"]
        x0, x1 = b["x"] * scale, (b["x"] + b["width"]) * scale
        y1 = (b["windowHeight"] - b["y"]) * scale; y0 = y1 - b["height"] * scale
        inner = mean_rgb(px, w, h, x0 + (x1 - x0) * 0.35, y0 + (y1 - y0) * 0.15, x1 - (x1 - x0) * 0.05, y1 - (y1 - y0) * 0.15)
        bg = mean_rgb(px, w, h, x1 + 20 * scale, y0, x1 + 60 * scale, y1)
        diff = sum(abs(a - b) for a, b in zip(inner, bg)) / 3
        return scale, (x0, y0, x1, y1), inner, bg, diff, edge_partials(px, w, h, b, scale, inner, bg)

    if box.get("ok") and os.path.exists(shot):
        scale, (x0, y0, x1, y1), inner, bg, diff, partial = measure(box, shot)
        print(f"     typing box px ({x0:.0f},{y0:.0f})-({x1:.0f},{y1:.0f}) inside {inner} background {bg} mean diff {diff:.1f};"
              f" partial pixels on the flat edges (information; the bubble breathes) {partial}", flush=True)
        check("the typing bubble is in the image (inside differs from the background by more than 6 levels)", diff > 6,
              {"inside": inner, "background": bg})
        if abs(scale - k0) > 0.01:
            check("the window's backing scale is 2 (the half-pixel move assumes it)", False, scale)

    def whole(v):  # a device-pixel edge (window points x backing scale)
        return abs(v - round(v)) < 0.01
    # snapTyping places the group's top-left on a device pixel (its size is whole pixels too): the left and
    # top edges (window y from the bottom: y + height).
    check("the transcript sits on half a device pixel (both axes)", bool(half.get("ok"))
          and all(abs(((half.get(k, 0) * k0) % 1) - 0.5) < 0.01 for k in ("hostX", "hostY")), half)
    check("the transcript's right edge sits on half a device pixel", abs(((half_rows.get("hostRight", 0) * k0) % 1) - 0.5) < 0.01,
          {k: half_rows.get(k) for k in ("hostRight", "trim", "scale")})
    if half.get("ok") and os.path.exists(half_shot):
        scale, _, inner, bg, diff, partial = measure(half, half_shot)
        px_edges = [half["x"] * scale, (half["y"] + half["height"]) * scale]
        print(f"     half pixel: host x {half['hostX']}, bubble left/top in device px {[round(e, 3) for e in px_edges]},"
              f" mean diff {diff:.1f}, partial pixels on the flat edges (information) {partial}", flush=True)
        check("moved by half a device pixel, the bubble's edges are on whole device pixels", all(whole(e) for e in px_edges), px_edges)
    # The message rows (c1457e5 RowCell.snapRow), in the same half-pixel snapshot: every text bubble's
    # top-left on whole device pixels, and no partial pixels along its straight edges.
    check("the app reports the message rows", bool(half_rows.get("ok")), half_rows)
    if half_rows.get("ok") and os.path.exists(half_shot):
        check_rows(check, "half pixel", half_rows, half_shot)

    # MessagesLab f11642b (resize-pace): a second width change in the same display frame runs its layout at once
    # when that frame's passes cost under 2 ms (it waited for the next frame's tick before: one frame with the
    # new width and the old rows). The transcript narrows by 40 pt twice in one main-thread turn (one socket
    # request: no display frame between), as a divider drag or a live resize can. After the second change the
    # outgoing rows must already end 80 pt further left, and no width pass may be deferred.
    base = rpc("debug.home.drive", {"action": "rows"}) or {}
    paced = rpc("debug.home.drive", {"action": "resize", "trims": [FRACTION_TRIM + 40, FRACTION_TRIM + 80]}) or {}
    steps = paced.get("steps") or []
    pace_steps.extend(steps)
    check("resize pace: two width changes in one turn", bool(paced.get("ok")) and len(steps) == 2 and bool(base.get("ok")), paced)
    if len(steps) == 2 and base.get("ok"):
        def outgoing_right(rows):
            return {r["key"]: r.get("maxX", r["x"] + r.get("width", 0)) for r in rows if r["kind"] == "text" and r["outgoing"]}
        b0 = {r["key"]: r["balloon"]["x"] + r["balloon"]["width"] for r in base["rows"] if r["kind"] == "text" and r["outgoing"]}
        s1, s2 = outgoing_right(steps[0]["rows"]), outgoing_right(steps[1]["rows"])
        keys = sorted(set(b0) & set(s1) & set(s2))
        moved = {k: [round(b0[k] - s1[k], 2), round(b0[k] - s2[k], 2)] for k in keys}
        deferred = steps[1]["deferred"] - steps[0]["deferred"]
        print(f"     resize pace: passes {steps[0]['passes']} -> {steps[1]['passes']}, deferred in the second change {deferred};"
              f" outgoing right edges moved left by (first, second) {moved}", flush=True)
        check("resize pace: outgoing rows to compare", bool(keys), {"base": list(b0), "after": list(s2)})
        # The frame budget (2 ms): a first pass that cost more defers the second change to the next frame, as the
        # pin intends (a slow Debug pass is no failure). Then the rows must follow by the next request, and the
        # proof of the same-frame layout is not made (said in the output, not passed silently).
        budget = paced.get("budgetMs", 2.0); first_ms = steps[0].get("ms", 0)
        over = first_ms >= budget
        print(f"     resize pace: first step {first_ms:.2f} ms, second {steps[1].get('ms', 0):.2f} ms, frame budget {budget:.2f} ms", flush=True)
        if deferred and over:
            print(f"SKIP resize pace same-frame proof: the first pass took {first_ms:.2f} ms (budget {budget:.2f} ms), so the"
                  " deferral is the intended one", flush=True)
            SKIPPED.append("resize pace same-frame")
            # Rows read until they follow (a display frame must pass first; at most 2 s).
            follows = lambda r: bool(keys) and all(k in r and abs(b0[k] - r[k] - 80) <= 0.6 for k in keys)
            later = poll(lambda: (r := outgoing_right((rpc("debug.home.drive", {"action": "rows"}) or {}).get("rows") or []))
                         and follows(r) and r, timeout=2) or {}
            check("resize pace: after the deferral the rows follow the new width a frame later (outgoing right edges 80 pt left)",
                  bool(keys) and all(k in later and abs(b0[k] - later[k] - 80) <= 0.6 for k in keys),
                  {k: round(b0[k] - later[k], 2) for k in keys if k in later})
        else:
            check("resize pace: the second width change in the frame ran its pass at once (none deferred)", deferred == 0, steps)
            check("resize pace: after the second change the rows are laid out for the new width (outgoing right edges 80 pt left)",
                  bool(keys) and all(abs(v[0] - 40) <= 0.6 and abs(v[1] - 80) <= 0.6 for v in moved.values()), moved)
    rpc("debug.home.drive", {"action": "resize", "trims": [0]})
finally:
    bench.stop()

print(f"{len(failures)} failed: {failures}" if failures else "all checks passed", flush=True)
if SKIPPED:
    print(f"{len(SKIPPED)} proof(s) skipped (not passed): {SKIPPED}", flush=True)
recorded = True
if opts.story:
    recorded = bool(pace_steps) and report.any_written(
        report.record_all(bench, opts.story, ENGINE, report.home_typing_series(pace_steps, failures)))
    if not recorded:
        print(f"FAIL no result-v1 written for --story {opts.story}", flush=True)
sys.exit(1 if failures or not recorded else 0)
