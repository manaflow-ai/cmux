#!/usr/bin/env python3
"""Edit to repaint: how long after a file is saved the cmux NEXT window shows the change.

Cases, each timed `--rounds` times on one app (a launched bench app, BenchApp, with its own cmux-next.json and
customize folder, never the account's; or, with `--attach-socket`, an app already running, such as a side
instance of an installed NIGHTLY: scripts/measure/ext-reload-nightly.sh):
- `theme`: cmux-next.json `appearance.themeFile` flips between two shipped theme files (phosphor, charcoal).
- `sidebar`: cmux-next.json `sidebar.density` flips between compact and expanded (four workspaces listed).
- `extension`: the customize folder's `main.js` (local/customize) is saved with a new headline in its
  `cmux.section/1` sidebar section; the daemon's watcher reloads it and the app redraws the section.
- `rows`: the same script saved with a new badge on every workspace row (`cmux.sidebar.rows/1`).
- `pane`: the same script saved with a new title in its `cmux.pane/1` pane, which is open in a tab.
- `glass`: the same script saved with the section's card on another level of the app's own glass
  (`.glass("popover")`, then `.glass("chip")`): the native glass a view draws changes with no rebuild.
- `command`: cmux-next.json `actions` gets a palette command whose title changes; the palette must list it.
- `shortcut`: keybindings.json (beside cmux-next.json) binds a command to a new key; that key must resolve to it.

The customize app (`extension`, `rows`, `pane`, `glass`) is one `cmux-app.json` and one `main.js` with all three
views, as a person's would be; each case changes only its own view's words.

How a pixel round is timed (`--mode pixels`, the default, which needs the bench build's `debug.window_snapshot`):
five window snapshots (`debug.window_snapshot`, the window server's composite of the main window, no page
images) taken 0.25 s apart before the write mark the parts of the window that change on their own (a blinking
cursor, a spinner); those 32 px blocks are left out. Then the file is written in place (open, write, close: an
editor's in-place save) and snapshots are taken back to back for `--window` seconds, each with the wall time
its request went out and its reply came back. A snapshot shows the change when at least `MIN_BLOCKS` other
blocks differ from the last baseline. The round's numbers:
- `upper_ms`: the reply of the first snapshot that shows the change, after the write ended. The repaint
  happened before this snapshot was taken, so this bounds it from above.
- `lower_ms`: the request of the last snapshot before it, which did not show the change: the repaint came
  after that capture began.
A capture holds the main actor for about 50 ms, so the back-to-back snapshots can push a repaint later by up
to one capture; `snap_ms` (each round's median capture time) says how much.

How a read-back round is timed (`--mode readback`, any build, and always for `command` and `shortcut`, which
change nothing on screen until the palette opens or the key is pressed): after the write the case's read-back
is asked every `POLL_S` until it shows the change; `upper_ms` is the reply of the first answer that shows it,
`lower_ms` the request of the last one that did not. The read-backs are control-socket reads every build
serves: `apps.views` (the words and glass levels of each open extension view, from the window's own mirror of its scene),
`palette.query` and `keybinding.resolve`.

Every customize round (`extension`, `rows`, `pane`, `glass`) also records what its view's mirror shows (`apps.views`)
and `cmux apps list` after the round, and keeps the round's last capture (pixel mode), so a miss says whether
the view never mounted, the save never reloaded, or the reload drew where the snapshots do not see.
Writes one `EDIT_REPAINT {json}` line per case and `--json` with every round.
"""
import argparse
import json
import os
import statistics
import struct
import subprocess
import sys
import time

ROOT = os.path.realpath(os.path.join(os.path.dirname(__file__), "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "scripts", "cmux-next"))
import bench_launch  # noqa: E402
from bench_launch import BenchApp  # noqa: E402
import hashlib  # noqa: E402
from state_wait import wait_stable, wait_until  # noqa: E402

BLOCK = 32          # px of the snapshot per block side
STEP = 4            # sample every 4th pixel in each direction
MIN_BLOCKS = 2      # changed blocks (outside the baseline mask) that make a change
PIXEL_DELTA = 24    # summed |dr|+|dg|+|db| over which a sample counts as changed
MIN_SAMPLES = 3     # changed samples that make a block changed
POLL_S = 0.02       # read-back interval

APP_ID = "local/customize"
CUSTOMIZE_CASES = ("extension", "rows", "pane", "glass")
READBACK_CASES = ("command", "shortcut")  # nothing changes on screen for these until a person acts
INTERFACES = {"extension": "cmux.section/1", "rows": "cmux.sidebar.rows/1", "pane": "cmux.pane/1",
              "glass": "cmux.section/1"}
GLASS_CASES = ("glass",)  # read back from the view's glass levels (`apps.views` `glasses`), not its words
ALL_CASES = ("theme", "sidebar") + CUSTOMIZE_CASES + READBACK_CASES

MANIFEST = {
    "manifestVersion": 2, "id": APP_ID, "name": "Edit repaint", "version": "1.0.0",
    "description": "A section, row decorations and a pane whose words the bench rewrites.",
    "engines": {"cmux": "^2.0"}, "runtime": {"main": "main.js"},
    "implements": {
        "cmux.section/1": {"export": "renderSection", "title": "Edit repaint", "symbol": "bolt.horizontal",
                           "options": {"defaultRegion": "bottom"}},
        "cmux.sidebar.rows/1": {"export": "renderRows"},
        "cmux.pane/1": {"export": "renderPane", "title": "Edit repaint pane", "symbol": "bolt.horizontal"},
    },
    "scopes": {"workspace:read": "Decorate each workspace row."},
}
# Per case, the two words a round alternates between: wide and narrow glyphs, so the pixels differ.
WORDS = {
    "extension": ["WWWWWWWW 0000", "iiiiiiii 1111"],
    "rows": ["WW00", "ii11"],
    "pane": ["WWWWWWWW pane 0000", "iiiiiiii pane 1111"],
    "glass": ["popover", "chip"],  # glass levels: a different material and radius, so the pixels differ
    "command": ["Edit repaint command WWWW", "Edit repaint command iiii"],
    "shortcut": ["cmd+ctrl+opt+shift+8", "cmd+ctrl+opt+shift+9"],
}
SHORTCUT_COMMAND = "palette.open"


def main_js(words):
    """The customize script: the section's headline, the rows' badge, the pane's title and the glass level of
    the section's card (`words`). The rows view carries its badge as a Text too, so `apps.views` (which reads
    text, title and detail) can see it."""
    section, rows, pane, glass = (json.dumps(words[k]) for k in ("extension", "rows", "pane", "glass"))
    return ("// Written by scripts/cmux-next/edit-repaint.py.\n"
            "function renderSection() {\n"
            f"  return VStack({{ spacing: 2 }}, [Text({section}).font(\"headline\"),\n"
            f"    Row({{ title: {section} + \" row\", symbol: \"bolt.horizontal\" }}),\n"
            f"    HStack([Text(\"Glass card\"), Spacer()]).padding(8).cornerRadius(10).glass({glass})])\n"
            "}\n"
            "function renderRows() {\n"
            "  const workspaces = cmux.live(\"workspace.list\", {})\n"
            f"  return VStack([Text({rows}),\n"
            "    ForEach({ items: () => workspaces() ?? [], key: (w) => w.id }, (w) =>\n"
            f"      Group({{ row: () => w().id, badge: {rows}, icon: \"bolt.horizontal\", weight: \"bold\" }}, []))])\n"
            "}\n"
            "function renderPane() {\n"
            f"  return VStack({{ spacing: 8 }}, [Text({pane}).font(\"largeTitle\"), Text({pane} + \" detail\")])\n"
            "}\n"
            "globalThis.__cmuxAppExports = { renderSection, renderRows, renderPane }\n")


def bmp(png):
    """(width, height, rows) of a PNG through sips, rows as bytes top-down, 3 or 4 bytes a pixel."""
    out = png[:-4] + ".bmp"
    subprocess.run(["sips", "-s", "format", "bmp", png, "--out", out], capture_output=True, check=True)
    data = open(out, "rb").read()
    os.unlink(out)
    offset, = struct.unpack_from("<I", data, 10)
    width, height = struct.unpack_from("<ii", data, 18)
    bpp, = struct.unpack_from("<H", data, 28)
    step = bpp // 8
    row = (width * step + 3) & ~3
    rows = [data[offset + y * row: offset + y * row + width * step] for y in range(abs(height))]
    if height > 0:
        rows.reverse()  # a positive height is bottom-up
    return width, abs(height), step, rows


def blocks_changed(a, b):
    """The set of (bx, by) blocks where samples of image a and b differ."""
    width, height, step, rows_a = a
    _, _, _, rows_b = b
    if len(rows_a) != len(rows_b):
        return {"size"}
    counts = {}
    for y in range(0, height, STEP):
        ra, rb = rows_a[y], rows_b[y]
        if ra == rb:
            continue
        for x in range(0, width, STEP):
            i = x * step
            if abs(ra[i] - rb[i]) + abs(ra[i + 1] - rb[i + 1]) + abs(ra[i + 2] - rb[i + 2]) > PIXEL_DELTA:
                key = (x // BLOCK, y // BLOCK)
                counts[key] = counts.get(key, 0) + 1
    return {k for k, n in counts.items() if n >= MIN_SAMPLES}


class Attached:
    """An app that is already running (a NIGHTLY side instance): its control socket, its bundled CLI, its
    cmux-next.json and customize folder. Nothing is launched or stopped here."""

    def __init__(self, socket, cli, config, customize, cli_socket=None):
        self.socket, self.cli, self.customize = socket, cli, customize
        self.cli_socket = cli_socket
        self.launched_env = {"CMUX_NEXT_CONFIG_FILE": config}

    def rpc(self, method, params=None, timeout=60):
        return bench_launch.rpc_at(self.socket, method, params, timeout)

    def launch(self):
        reply = self.rpc("system.identify", timeout=10)
        if not isinstance(reply, dict) or "error" in reply:
            raise SystemExit(f"edit-repaint: the app at {self.socket} does not answer: {reply}")

    def stop(self):
        pass


class Round:
    def __init__(self, app, out, name, keep_last=False):
        self.app, self.out, self.name, self.keep_last = app, out, name, keep_last
        self.n = 0

    def snap(self):
        self.n += 1
        path = os.path.join(self.out, f"{self.name}-{self.n:04d}.png")
        sent = time.time()
        reply = self.app.rpc("debug.window_snapshot", {"kind": "main", "path": path, "webviews": False}, timeout=30)
        back = time.time()
        if not isinstance(reply, dict) or "path" not in reply:
            raise SystemExit(f"edit-repaint: snapshot failed: {reply}")
        return {"path": path, "sent": sent, "back": back}

    def run(self, write, window):
        base = []
        for _ in range(5):
            base.append(self.snap())
            time.sleep(0.25)
        images = [bmp(s["path"]) for s in base]
        mask = set()
        for image in images[:-1]:
            mask |= blocks_changed(image, images[-1])
        reference = images[-1]
        started = time.time()
        write()
        written = time.time()
        shots = []
        while time.time() - written < window:
            shots.append(self.snap())
        found, last_unchanged = None, None
        for shot in shots:
            changed = blocks_changed(reference, bmp(shot["path"])) - mask
            shot["blocks"] = len(changed)
            if len(changed) >= MIN_BLOCKS:
                found = shot
                break
            last_unchanged = shot
        final = len(blocks_changed(reference, bmp(shots[-1]["path"])) - mask) if shots else 0
        # A round with no change keeps its reference and its last snapshot, so a miss can be looked at; a
        # customize round keeps its last snapshot either way (what the window showed at the end of the round).
        last = shots[-1] if shots else None
        kept = [found, last_unchanged] if found else [base[-1], last]
        if self.keep_last:
            kept.append(last)
        for s in base + shots:
            if not any(s is k for k in kept):
                os.unlink(s["path"])
        snap_ms = statistics.median([(s["back"] - s["sent"]) * 1000 for s in shots]) if shots else None
        row = {"write_ms": round((written - started) * 1000, 1), "mask_blocks": len(mask), "snaps": len(shots),
               "snap_ms": round(snap_ms, 1) if snap_ms else None, "final_blocks": final}
        if self.keep_last and last:
            row["last_shot"] = os.path.basename(last["path"])
        if found:
            row["upper_ms"] = round((found["back"] - written) * 1000, 1)
            row["lower_ms"] = round(((last_unchanged["sent"] if last_unchanged else written) - written) * 1000, 1)
            row["blocks"] = found["blocks"]
            row["shot"] = os.path.basename(found["path"])
        return row


def readback_round(write, seen, window):
    """Writes, then asks `seen()` every POLL_S until it says the change shows, for up to `window` seconds."""
    started = time.time()
    write()
    written = time.time()
    row = {"write_ms": round((written - started) * 1000, 1), "method": "readback"}
    last_sent, polls = None, 0
    while time.time() - written < window:
        sent = time.time()
        shows = seen()
        back = time.time()
        polls += 1
        if shows:
            row["upper_ms"] = round((back - written) * 1000, 1)
            row["lower_ms"] = round(((last_sent if last_sent else written) - written) * 1000, 1)
            break
        last_sent = sent
        time.sleep(POLL_S)
    row["polls"] = polls
    return row


def views(app, interface):
    """The open views of the customize app for `interface` (`apps.views`), and the reply."""
    reply = app.rpc("apps.views", {"app": APP_ID}, timeout=10)
    found = [v for v in (reply.get("views") or []) if v.get("interface") == interface and not v.get("preview")] \
        if isinstance(reply, dict) else []
    return found, reply


def view_shows(app, interface, word, glass=False):
    """Whether an open view shows `word` among its words or, with `glass`, draws glass at level `word`."""
    found, _ = views(app, interface)
    if glass:
        return any(word in (v.get("glasses") or []) for v in found)
    return any(word in (v.get("texts") or []) or any(word in t for t in (v.get("texts") or [])) for v in found)


def view_readback(app, interface, word, glass=False):
    """The customize view as the window's mirror of its scene holds it (`apps.views`): whether a view is open,
    its status, revision, words and glass levels, and whether `word` is among them (among the glass levels,
    with `glass`)."""
    found, reply = views(app, interface)
    if not found:
        return {"open": False, "reply": reply}
    view = found[0]
    texts = view.get("texts") or []
    glasses = view.get("glasses") or []
    return {"open": True, "status": view.get("status"), "revision": view.get("revision"),
            "surface": view.get("surface"), "reason": view.get("reason"),
            "reload_failure": view.get("reload_failure"),
            "shows": word in glasses if glass else any(word in t for t in texts), "texts": texts[:20],
            "glasses": glasses[:20]}


def apps_list(app):
    """`cmux apps list --json` from the app's own CLI, so a run says whether the daemon has the customize app,
    installed and on, beside what the window shows."""
    env = dict(os.environ)
    socket = getattr(app, "cli_socket", None) or app.socket
    env["CMUX_SOCKET_PATH"] = socket
    try:
        run = subprocess.run([app.cli, "apps", "list", "--json"], capture_output=True, text=True, timeout=20, env=env)
    except (OSError, subprocess.TimeoutExpired) as error:
        return {"error": f"did not run: {error}"}
    try:
        listed = json.loads(run.stdout)
    except ValueError:
        return {"exit": run.returncode, "output": (run.stdout + run.stderr)[-1500:]}
    apps = listed.get("apps") if isinstance(listed, dict) else listed
    mine = [a for a in (apps or []) if isinstance(a, dict) and a.get("id") == APP_ID]
    return {"exit": run.returncode, "customize": mine[0] if mine else None,
            "count": len(apps) if isinstance(apps, list) else None}


COMMAND_ACTION = "edit-repaint"  # the command case's key in cmux-next.json `actions`


def place_section(app):
    """`cmux apps place APP_ID#cmux.section/1 --region bottom` from the app's own CLI. A section is placed
    once per sidebar (its id hashes the contribution): after a person, or an earlier run, removed it, a new
    install of the same app id draws no section until it is placed again, as the customize brief tells an
    agent to. True once the daemon took it (it answers "no such sidebar section" until the app is installed)."""
    env = dict(os.environ)
    env["CMUX_SOCKET_PATH"] = getattr(app, "cli_socket", None) or app.socket
    try:
        run = subprocess.run([app.cli, "apps", "place", f"{APP_ID}#cmux.section/1", "--region", "bottom"],
                             capture_output=True, text=True, timeout=20, env=env)
    except (OSError, subprocess.TimeoutExpired) as error:
        place_section.last = {"error": f"did not run: {error}"}
        return False
    place_section.last = {"exit": run.returncode, "output": (run.stdout + run.stderr)[-600:]}
    return run.returncode == 0


def palette_lists(app, title):
    """Whether `palette.query` returns a row that is the saved command: its title is `title` and its id or
    action names COMMAND_ACTION. Only `items` count: the reply echoes the query itself in `query`."""
    reply = app.rpc("palette.query", {"scope": "root", "query": title, "limit": 10}, timeout=10)
    items = reply.get("items") if isinstance(reply, dict) else None
    return any(isinstance(item, dict) and item.get("title") == title
               and any(COMMAND_ACTION in str(item.get(key) or "") for key in ("action", "id"))
               for item in items or [])


def key_resolves(app, keys, command):
    reply = app.rpc("keybinding.resolve", {"keys": keys}, timeout=10)
    return isinstance(reply, dict) and "error" not in reply and command in json.dumps(reply)


def settle(app, out, what, timeout=20):
    """Waits until the window reads the same four times in a row, 0.2 s apart: its surfaces (`debug.surfaces`, else
    `apps.views`) and,
    when the build serves it, its main-window snapshot. Best effort: a window still changing is logged."""
    probe = os.path.join(out, "settle-probe.png")

    def read():
        surfaces = app.rpc("debug.surfaces", timeout=10)
        if not isinstance(surfaces, dict) or surfaces.get("error") or not surfaces.get("windows"):
            surfaces = app.rpc("apps.views", {"app": APP_ID}, timeout=10)  # a build with no debug.surfaces
            if not isinstance(surfaces, dict) or surfaces.get("error"):
                raise RuntimeError(f"no surfaces: {surfaces}")
        shot = app.rpc("debug.window_snapshot", {"kind": "main", "path": probe, "webviews": False}, timeout=30)
        digest = None
        if isinstance(shot, dict) and "path" in shot and os.path.exists(probe):
            with open(probe, "rb") as f:
                digest = hashlib.sha256(f.read()).hexdigest()
            os.unlink(probe)
        return json.dumps(surfaces, sort_keys=True), digest

    if wait_stable(read, what, timeout=timeout, interval=0.2, reads=4, raise_on_timeout=False) is None:
        print(f"edit-repaint: {what}: the window gave no surfaces in {timeout} s", flush=True)


def summary(rows):
    upper = [r["upper_ms"] for r in rows if "upper_ms" in r]
    lower = [r["lower_ms"] for r in rows if "lower_ms" in r]
    if not upper:
        return {"n": 0, "missed": len(rows)}
    out = {"n": len(upper), "missed": len(rows) - len(upper),
           "upper_median_ms": round(statistics.median(upper), 1), "upper_max_ms": max(upper),
           "lower_median_ms": round(statistics.median(lower), 1), "lower_max_ms": max(lower)}
    snaps = [r["snap_ms"] for r in rows if r.get("snap_ms")]
    if snaps:
        out["snap_median_ms"] = round(statistics.median(snaps), 1)
    return out


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", help="the bench app to launch (a tagged build)")
    parser.add_argument("--attach-socket", help="the control socket of an app already running (with --cli, "
                        "--config, --customize); nothing is launched")
    parser.add_argument("--cli", help="with --attach-socket: the app's bundled cmux")
    parser.add_argument("--cli-socket", help="with --attach-socket: the daemon socket the CLI talks to")
    parser.add_argument("--config", help="with --attach-socket: the app's cmux-next.json")
    parser.add_argument("--customize", help="with --attach-socket: the customize folder the app's daemon reads")
    parser.add_argument("--out", required=True)
    parser.add_argument("--json", required=True)
    parser.add_argument("--rounds", type=int, default=10)
    parser.add_argument("--window", type=float, default=3.0, help="seconds of snapshots after each write")
    parser.add_argument("--mode", choices=("pixels", "readback"), default="pixels",
                        help="pixels: window snapshots (a bench build); readback: control-socket reads (any build)")
    parser.add_argument("--cases", help="comma-separated cases (default: every case the mode can read: all of "
                        "them for pixels; extension, rows, pane, command, shortcut for readback)")
    opts = parser.parse_args()
    readable = ALL_CASES if opts.mode == "pixels" else CUSTOMIZE_CASES + READBACK_CASES
    cases = opts.cases.split(",") if opts.cases else list(readable)
    for case in cases:
        if case not in ALL_CASES:
            raise SystemExit(f"edit-repaint: unknown case {case} (cases: {', '.join(ALL_CASES)})")
        if case not in readable:  # refused before anything is launched or written
            raise SystemExit(f"edit-repaint: {case} has no read-back; run it with --mode pixels")
    os.makedirs(opts.out, exist_ok=True)
    if opts.attach_socket:
        if not (opts.cli and opts.config and opts.customize):
            raise SystemExit("edit-repaint: --attach-socket needs --cli, --config and --customize")
        customize = opts.customize
        app = Attached(opts.attach_socket, opts.cli, opts.config, customize, opts.cli_socket)
    else:
        if not opts.app:
            raise SystemExit("edit-repaint: give --app, or --attach-socket")
        customize = os.path.join(opts.out, "customize")
        config = {"appearance": {"backgroundOpacity": 1}, "sidebar": {"density": "compact"}}
        app = BenchApp(opts.app, out=opts.out, config=config, env={"CMUX_CUSTOMIZE_DIR": customize})
    os.makedirs(customize, exist_ok=True)
    result = {"host": os.uname().nodename, "app": opts.app or opts.attach_socket, "rounds": opts.rounds,
              "window_s": opts.window, "mode": opts.mode, "customize": customize,
              "method": "see the module docstring", "cases": {}}
    words = {k: WORDS[k][1] for k in CUSTOMIZE_CASES}  # round 0 writes WORDS[k][0], a change from these

    def write_customize():
        with open(os.path.join(customize, "main.js"), "w") as f:
            f.write(main_js(words))

    try:
        app.launch()
        config_path = app.launched_env["CMUX_NEXT_CONFIG_FILE"]
        keybindings_path = os.path.join(os.path.dirname(config_path), "keybindings.json")
        if "shortcut" in cases and os.path.exists(keybindings_path):
            raise SystemExit(f"edit-repaint: {keybindings_path} exists; the shortcut case writes and removes it, "
                             "so it runs only beside a config folder of its own")
        if not opts.attach_socket:
            settle(app, opts.out, "the launched window")
        for _ in range(3):
            app.rpc("action.run", {"action": "workspace.newAtBottom", "focus": True})
            time.sleep(0.5)
        settle(app, opts.out, "the window with the new workspaces")

        def save_config(update):
            def write():
                try:
                    current = json.load(open(config_path))
                except (OSError, ValueError):
                    current = {}
                update(current)
                with open(config_path, "w") as f:
                    f.write(json.dumps(current, indent=2))
            return write

        if any(c in CUSTOMIZE_CASES for c in cases):
            # main.js first: the manifest appearing installs the app. Then the views draw once before the
            # first timed save, and the pane opens in a tab.
            write_customize()
            with open(os.path.join(customize, "cmux-app.json"), "w") as f:
                json.dump(MANIFEST, f, indent=2)
            if any(c in cases for c in ("extension", "glass")):
                # The section draws only once it is placed (see place_section): place it, as an agent would.
                placed = wait_until(lambda: place_section(app), "the customize section placed", timeout=60,
                                    interval=0.5, raise_on_timeout=False)
                result["section_place"] = dict(getattr(place_section, "last", {}), placed=bool(placed))
                if not placed:
                    print(f"edit-repaint: placing the customize section failed: {result['section_place']}",
                          flush=True)
            # Installed: each asked view other than the pane (it opens below) shows its words, then the window settles.
            shown = [c for c in ("extension", "rows") if c in cases]
            if not wait_until(lambda: all(view_shows(app, INTERFACES[c], words[c]) for c in shown),
                              "the customize views", timeout=60, interval=0.2, raise_on_timeout=False):
                print(f"edit-repaint: the customize views {shown} did not show their words in 60 s", flush=True)
            settle(app, opts.out, "the window with the customize app")
            if "pane" in cases:
                # focus: the pane's tab is selected, so pixel rounds snapshot the pane, not the tab before it.
                result["pane_open"] = app.rpc("action.run", {"action": "app.open", "args": {"app": APP_ID},
                                                             "focus": True}, timeout=30)
                # The pane's tab shows its words, then the window settles.
                if not wait_until(lambda: view_shows(app, INTERFACES["pane"], words["pane"]), "the customize pane",
                                  timeout=30, interval=0.2, raise_on_timeout=False):
                    print("edit-repaint: the customize pane did not show its words in 30 s", flush=True)
                settle(app, opts.out, "the window with the pane open")
            result["installed"] = {"apps_list": apps_list(app),
                                   "views": {c: view_readback(app, INTERFACES[c], words[c], glass=c in GLASS_CASES)
                                             for c in CUSTOMIZE_CASES if c in cases}}
            print(f"edit-repaint: installed: {json.dumps(result['installed'])[:3000]}", flush=True)

        for case in cases:
            rows = []
            result["cases"][case] = {"rounds": rows}  # finished rounds survive a later failure
            readback = opts.mode == "readback" or case in READBACK_CASES
            rnd = Round(app, opts.out, case, keep_last=case in CUSTOMIZE_CASES)
            for i in range(opts.rounds):
                word = WORDS.get(case, ["", ""])[i % 2]
                seen = None
                if case == "theme":
                    name = ["phosphor", "charcoal"][i % 2]
                    write = save_config(lambda c, n=name: c.setdefault("appearance", {}).__setitem__("themeFile", n))
                elif case == "sidebar":
                    density = ["expanded", "compact"][i % 2]
                    write = save_config(lambda c, d=density: c.setdefault("sidebar", {}).__setitem__("density", d))
                elif case in CUSTOMIZE_CASES:
                    def write(case=case, word=word):
                        words[case] = word
                        write_customize()
                    seen = lambda case=case, word=word: view_shows(app, INTERFACES[case], word,  # noqa: E731
                                                                   glass=case in GLASS_CASES)
                elif case == "command":
                    action = {"type": "command", "command": "true", "title": word, "target": "newTabInCurrentPane",
                              "palette": True}
                    write = save_config(lambda c, a=action: c.setdefault("actions", {}).__setitem__(COMMAND_ACTION, a))
                    seen = lambda word=word: palette_lists(app, word)  # noqa: E731
                elif case == "shortcut":
                    def write(word=word):
                        with open(keybindings_path, "w") as f:
                            json.dump([{"key": word, "command": SHORTCUT_COMMAND}], f, indent=2)
                    seen = lambda word=word: key_resolves(app, word, SHORTCUT_COMMAND)  # noqa: E731
                if readback:
                    if seen is None:
                        raise SystemExit(f"edit-repaint: {case} has no read-back; run it with --mode pixels")
                    row = readback_round(write, seen, opts.window)
                else:
                    row = rnd.run(write, opts.window)
                row["round"] = i
                if case in CUSTOMIZE_CASES:
                    # What the window's mirror of the view holds after the round (`apps.views`), and what the
                    # daemon lists: the new words there with no pixel change means the save reloaded but the
                    # change is not where the snapshots look; no view means it never mounted; no customize
                    # app in the list means the daemon never loaded the folder.
                    row["view"] = view_readback(app, INTERFACES[case], word, glass=case in GLASS_CASES)
                    row["apps_list"] = apps_list(app)
                rows.append(row)
                print(f"edit-repaint: {case} round {i}: {json.dumps(row)[:2000]}", flush=True)
                time.sleep(1.0)
            stats = summary(rows)
            stats["method"] = "readback" if readback else "pixels"
            if case in CUSTOMIZE_CASES:  # saves the view's mirror shows, beside the saves the pixels show
                stats["view_shown"] = sum(1 for r in rows if r.get("view", {}).get("shows"))
            result["cases"][case]["summary"] = stats
            print("EDIT_REPAINT " + json.dumps({"case": case, **stats}), flush=True)
            if case == "theme":  # the next cases run on the default look
                save_config(lambda c: c.get("appearance", {}).pop("themeFile", None))()
                time.sleep(2)
            if case == "command":
                save_config(lambda c: c.get("actions", {}).pop(COMMAND_ACTION, None))()
            if case == "shortcut" and os.path.exists(keybindings_path):
                os.unlink(keybindings_path)
    finally:
        with open(opts.json, "w") as f:
            json.dump(result, f, indent=2)
        app.stop()


if __name__ == "__main__":
    main()
