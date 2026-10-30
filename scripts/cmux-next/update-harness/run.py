#!/usr/bin/env python3
"""Update harness: a real Sparkle update between two copies of a tagged DEV
build, on a GUI host (cmux-lawrence-2, `nx-remote --needs gui`), with the
timeline of the click and the relaunch.

    run.py --app "<path>/cmux DEV <tag>.app" --tag <tag> --out <dir> [--port N]

What it does (plans: .cmux-scratch/hq-ff/updates-plan.md, slice S0):
  1. Generates a throwaway EdDSA key in <out>/work/keys (keys.swift; deleted
     at the end). It is never a release or nightly key.
  2. Copies the app twice (v1, v2). Each copy gets SUPublicEDKey = the
     throwaway key, CMUXNextUpdateHarness = {feed, marks} and its own
     CFBundleVersion (v2 newer), and is signed again ad hoc. Only DEV
     builds read CMUXNextUpdateHarness (UpdateHarness.swift, #if DEBUG).
  3. Zips v2, signs the zip, writes a loopback appcast, serves it on
     127.0.0.1:<port>.
  4. Launches v1 (no activation, automation socket) and checks. Without the
     automatic-install opt-in (the default) the update-found step asks: the
     harness checks that nothing downloads, presses Update, waits for the
     update to stage (Sparkle downloads, verifies and extracts it), checks
     that nothing relaunches, then presses Restart to Update. Otherwise it
     runs the install action through the control socket.
  5. Waits for v1 to exit (kernel exit event) and for the relaunched app's
     launch marks, then writes <out>/timeline.json and prints the numbers.
  6. Stops what it started (exact pids), the server, and deletes the key.

Waits are kernel events on the marks file and the process (kqueue), each
with a deadline; nothing sleeps to synchronize.
"""
import argparse, json, os, plistlib, select, shutil, signal, socket, subprocess, sys, time
import re

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
from sessions import Agent, Owned, Terminal, bundle_commit, patch_build_stamp, wait_path  # noqa: E402
from tag_teardown import TagTeardown  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
INSTALL_ACTION = "palette.applyUpdateIfAvailable"
CHECK_ACTION = "palette.checkForUpdates"
ATTEMPT_ACTION = "palette.attemptUpdate"
# --scenario: the palette's Attempt Update (Cmd+Shift+P), run through action.run (the registry path
# the palette runs), and what the update UI shows (the card.* marks, updates.status).
SCENARIOS = ["attempt-up-to-date", "attempt-update", "attempt-staged", "attempt-feed-error", "attempt-download-error"]
RESTORED_MARKS = ["launch.first_window_frame_committed", "launch.launch_snapshot_shown",
                  "launch.daemon_connected", "launch.daemon_version_handoff", "launch.daemon_snapshot_loaded",
                  "launch.sidebar_rows_shown", "launch.first_terminal_content"]


def log(*parts):
    print(" ".join(str(p) for p in parts), flush=True)


def run(cmd, **kw):
    r = subprocess.run(cmd, capture_output=True, text=True, **kw)
    if r.returncode != 0:
        raise SystemExit(f"failed ({r.returncode}): {' '.join(cmd)}\n{r.stdout}{r.stderr}")
    return r.stdout.strip()


def plist_set(app, updates, harness):
    path = os.path.join(app, "Contents/Info.plist")
    with open(path, "rb") as f:
        info = plistlib.load(f)
    info.update(updates)
    info["CMUXNextUpdateHarness"] = harness
    with open(path, "wb") as f:
        plistlib.dump(info, f)
    run(["/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none",
         "--preserve-metadata=entitlements,requirements,flags,runtime", app])
    return info


class Marks:
    """The marks file, read as it grows (kqueue vnode events)."""

    def __init__(self, path):
        self.path = path
        open(path, "a").close()
        self.fd = os.open(path, os.O_RDONLY)
        self.kq = select.kqueue()
        self.kq.control([select.kevent(self.fd, select.KQ_FILTER_VNODE, select.KQ_EV_ADD | select.KQ_EV_CLEAR,
                                       select.KQ_NOTE_WRITE | select.KQ_NOTE_EXTEND)], 0)
        self.offset = 0
        self.rows = []

    def read(self):
        with open(self.path) as f:
            f.seek(self.offset)
            data = f.read()
        done = data.rfind("\n") + 1
        self.offset += len(data[:done].encode())
        for line in data[:done].splitlines():
            try:
                self.rows.append(json.loads(line))
            except ValueError:
                pass
        return self.rows

    def wait(self, predicate, timeout):
        """Returns the first row list for which predicate holds, or None at the deadline."""
        deadline = time.monotonic() + timeout
        while True:
            hit = predicate(self.read())
            if hit:
                return hit
            left = deadline - time.monotonic()
            if left <= 0:
                return None
            self.kq.control(None, 1, left)


def first(rows, name, pid=None, not_pid=None):
    """The first row named `name` (a trailing * matches a prefix)."""
    for r in rows:
        matches = r["name"].startswith(name[:-1]) if name.endswith("*") else r["name"] == name
        if matches and (pid is None or r["pid"] == pid) and (not_pid is None or r["pid"] != not_pid):
            return r
    return None


def wait_exit(pid, timeout):
    kq = select.kqueue()
    try:
        kq.control([select.kevent(pid, select.KQ_FILTER_PROC, select.KQ_EV_ADD, select.KQ_NOTE_EXIT)], 0)
    except OSError:
        return time.time()  # already gone
    events = kq.control(None, 1, timeout)
    return time.time() if events else None


def wait_socket(path, timeout):
    """True once `path` accepts a connection (kqueue on its directory; each
    directory change re-checks), False at the deadline."""
    directory = os.path.dirname(path)
    fd = os.open(directory, os.O_RDONLY)
    kq = select.kqueue()
    kq.control([select.kevent(fd, select.KQ_FILTER_VNODE, select.KQ_EV_ADD | select.KQ_EV_CLEAR, select.KQ_NOTE_WRITE)], 0)
    deadline = time.monotonic() + timeout
    try:
        while True:
            if os.path.exists(path):
                try:
                    c = socket.socket(socket.AF_UNIX)
                    c.settimeout(2)
                    c.connect(path)
                    c.close()
                    return True
                except OSError:
                    pass
            left = deadline - time.monotonic()
            if left <= 0:
                return False
            # A socket that exists but refuses has no directory event to wait for; re-check within 1 s.
            kq.control(None, 1, min(left, 1.0))
    finally:
        os.close(fd)


def rpc(sock, method, params=None, timeout=10):
    c = socket.socket(socket.AF_UNIX)
    c.settimeout(timeout)
    c.connect(sock)
    c.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
    buf = b""
    while not buf.endswith(b"\n"):
        chunk = c.recv(1 << 20)
        if not chunk:
            break
        buf += chunk
    c.close()
    return json.loads(buf) if buf else {}


def sessions_alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def terminal_survived(r, handoff):
    """A terminal survival record (Terminal.check) passes: the same terminal and process counted through the swap. With
    a handoff, the terminal was found through a replacement cmux-tui daemon; without, the daemons stayed the same."""
    return bool(r["same_terminal_listed"] and r["pid_alive"] and r["pid_before"] == r["pid_after"]
                and r["last_sample_after_relaunch"] and r["samples_during_swap"] > 0
                and (r.get("replacement_daemon") if handoff else r["daemons_before"] == r["daemons_after"]))


def end_tag(teardowns, owned, acp_home, remove_home, log):
    """Ends the tag with the TagTeardowns kept for the whole run (they remembered every daemon and state root, old and
    relaunched, so they find hosts and holders whose daemon already exited), then each session process this run
    started that still runs, by its recorded pid. Deletes acp_home only when none of those is left. Returns the pids
    left."""
    for teardown in teardowns:
        if os.path.isdir(teardown.app):
            teardown.end()
    left = owned.end(log)
    if remove_home:
        if left:
            log("keeping", acp_home, "while session processes run:", left)
        else:
            shutil.rmtree(acp_home, ignore_errors=True)
    return left


def processes_under(root):
    out = subprocess.run(["ps", "-axo", "pid=,command="], capture_output=True, text=True).stdout
    found = []
    for line in out.splitlines():
        pid, _, command = line.strip().partition(" ")
        if root in command and "run.py" not in command:
            found.append((int(pid), command))
    return found


NOTES_ENTRIES = [
    ("new", {"en": "Restart to Update is instant", "ja": "すぐに再起動して更新"},
     {"en": "The click answers in one frame; terminals and agents keep running.", "ja": "クリックは1フレームで反応し、ターミナルとエージェントは動き続けます。"}),
    ("fixed", {"en": "Updates install when Sparkle staged them", "ja": "自動でダウンロードした更新もインストール"},
     {"en": "A silently downloaded update now installs on the first click.", "ja": "自動でダウンロードされた更新も最初のクリックでインストールされます。"}),
    ("improved", {"en": "What's New after every update", "ja": "毎回の更新後に新機能を表示"},
     {"en": "A card shows what changed, once, on every channel.", "ja": "変更点をすべてのチャンネルで一度だけ表示します。"}),
    ("new", {"en": "Highlights before you restart", "ja": "再起動前にハイライトを表示"},
     {"en": "The update card names the top changes.", "ja": "更新カードに主な変更点を表示します。"}),
]


def surface_shots(sock, out, phase, log, popover):
    """Light and dark captures of the main window, and with `popover` of the highlights popover
    (its own window, from debug.window_list). Returns what each capture wrote."""
    shots = {}
    for mode in ("light", "dark"):
        rpc(sock, "debug.appearance", {"mode": mode})
        if popover:
            shown = rpc(sock, "debug.update_surfaces", {"action": "show-popover"}).get("result", {})
            # Capture timing only: WebKit paints a page view moved into a new window on a later frame.
            time.sleep(1.0)
            windows = rpc(sock, "debug.window_list").get("result", {}).get("windows", [])
            pops = [w for w in windows if w.get("kind") == "popover" and w.get("visible")]
            shots[f"{phase}-{mode}-popover-shown"] = shown
            shots[f"{phase}-{mode}-log"] = [l for l in rpc(sock, "updates.status").get("result", {}).get("log", []) if "surface" in l]
            for index, window in enumerate(pops):
                path = os.path.join(out, f"{phase}-{mode}-popover-{index}.png")
                shots[path] = rpc(sock, "debug.window_snapshot", {"window": window["id"], "path": path}, timeout=30).get("result")
        time.sleep(0.5)  # capture timing only: the appearance change repaints the page views
        path = os.path.join(out, f"{phase}-{mode}-window.png")
        shots[path] = rpc(sock, "debug.window_snapshot", {"kind": "main", "path": path}, timeout=30).get("result")
    log(phase, "surface shots", json.dumps(shots)[:1500])
    return shots


def island_state(sock):
    """The active window's update pages (debug.update_surfaces state, cx-asynu)."""
    return rpc(sock, "debug.update_surfaces", {"action": "state"}).get("result", {})


def island_check(result, name, state, **expected):
    """Records `state` under `name` with each expected key's verdict; a miss marks the run failed."""
    misses = {k: (state.get(k), v) for k, v in expected.items() if state.get(k) != v}
    result.setdefault("island_lifecycle", {})[name] = {"state": state, "misses": misses}
    if misses:
        result.setdefault("island_failures", []).append(name)


def write_notes(feed, keys, info, log):
    """Signed release notes for `info`'s build, laid out like the real feed: notes/<build>.json + .sig
    and the index the changelog page lists (notes/index.json + .sig)."""
    build, short = info["CFBundleVersion"], info.get("CFBundleShortVersionString", "0")
    notes = {
        "version": 1, "build": build, "shortVersion": short, "date": time.strftime("%Y-%m-%d", time.gmtime()),
        "highlights": [], "changes": ["harness change"],
        "summary": [{"group": "new", "title": "Highlights before you restart"}],
        "whatsNew": {"schemaVersion": 1, "version": short, "channel": "nightly", "date": time.strftime("%Y-%m-%d", time.gmtime()),
                     "headline": {"en": "Faster updates", "ja": "より速い更新"},
                     "entries": [{"id": f"harness-{i}", "category": category, "title": title, "summary": summary,
                                  "platforms": ["macos"], "audience": "all"}
                                 for i, (category, title, summary) in enumerate(NOTES_ENTRIES)]},
    }
    folder = os.path.join(feed, "notes")
    os.makedirs(folder, exist_ok=True)
    path = os.path.join(folder, f"{build}.json")
    with open(path, "w") as f:
        json.dump(notes, f, ensure_ascii=False)
    with open(path + ".sig", "w") as f:
        f.write(run(["swift", os.path.join(HERE, "keys.swift"), "sign", keys, path]) + "\n")
    index = os.path.join(folder, "index.json")
    with open(index, "w") as f:
        json.dump({"builds": [{"build": build, "shortVersion": short, "date": notes["date"], "highlights": 0}]}, f)
    with open(index + ".sig", "w") as f:
        f.write(run(["swift", os.path.join(HERE, "keys.swift"), "sign", keys, index]) + "\n")
    log("notes", path, index)


# The narrow sidebar width for the --changelog-shots captures (the sidebar's minimum, Metrics.sidebarMinWidth).
NARROW_SIDEBAR = 160


def changelog_shots(sock, out, phase, log, action, popover):
    """cx-7rone: the sidebar's update card at the narrow width (light and dark), then, at the width
    before, the What's New page its button opens (`action`: open-changes or open-whats-new), light
    and dark. The ready phase leaves that page's tab open in the session the relaunch restores."""
    shots = {"width": rpc(sock, "debug.update_surfaces", {"action": "sidebar-width", "width": NARROW_SIDEBAR}).get("result")}
    time.sleep(1.0)  # capture timing only: the card's page re-measures at the new width
    shots.update(surface_shots(sock, out, f"{phase}-narrow", log, popover=popover))
    # Back to the width before, so later captures (and the relaunched session) keep it.
    previous = (shots["width"] or {}).get("previous")
    if previous:
        rpc(sock, "debug.update_surfaces", {"action": "sidebar-width", "width": previous})
    shots["open"] = rpc(sock, "debug.update_surfaces", {"action": action}).get("result")
    time.sleep(3.0)  # capture timing only: the page loads the notes list and the newest notes
    shots["windows"] = rpc(sock, "debug.window_list").get("result", {}).get("windows", [])
    shots.update(surface_shots(sock, out, f"{phase}-changelog", log, popover=False))
    return shots


def second_hop(a, work, feed, keys, name, public_key, harness, base, marks, sock, installed_path, old_pids, click_after_keep):
    """The relaunched build updates again: v3 on the feed, a check, the staged click, the next relaunch."""
    v2_pid = old_pids[-1]
    v3 = os.path.join(work, "v3", name)
    os.makedirs(os.path.dirname(v3))
    run(["/usr/bin/ditto", a.app, v3])
    i3 = plist_set(v3, {"SUPublicEDKey": public_key, "CFBundleVersion": str(base + 2)}, harness)
    archive = os.path.join(feed, "update3.zip")
    run(["/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", v3, archive])
    signature = run(["swift", os.path.join(HERE, "keys.swift"), "sign", keys, archive])
    short = i3.get("CFBundleShortVersionString", "0")
    with open(os.path.join(feed, "appcast.xml"), "w") as f:
        f.write(f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>update harness</title>
    <item>
      <title>{short} ({i3['CFBundleVersion']})</title>
      <pubDate>{time.strftime('%a, %d %b %Y %H:%M:%S +0000', time.gmtime())}</pubDate>
      <sparkle:version>{i3['CFBundleVersion']}</sparkle:version>
      <sparkle:shortVersionString>{short}</sparkle:shortVersionString>
      <description><![CDATA[New: the second update]]></description>
      <enclosure url="http://127.0.0.1:{a.port}/update3.zip" length="{os.path.getsize(archive)}" type="application/octet-stream" sparkle:edSignature="{signature}"/>
    </item>
  </channel>
</rss>
""")
    if not wait_socket(sock, 60):
        return {"result": "the relaunched app's socket did not open"}
    rpc(sock, "action.run", {"id": CHECK_ACTION})
    staged = marks.wait(lambda rows: next((first(rows, end, pid=v2_pid) for end in ("phase.ready", "phase.note", "phase.available")
                                           if first(rows, end, pid=v2_pid)), None), a.stage_timeout)
    if staged and staged["name"] == "phase.available":
        # The found step asks (no automatic-install opt-in): Update, then the ready step.
        staged = answer_found_step(a, sock, marks, v2_pid)["staged"]
    if not staged or staged["name"] != "phase.ready":
        return {"result": "v2 staged nothing", "status": rpc(sock, "updates.status")}
    if click_after_keep:
        marks.wait(lambda rows: first(rows, "keep_previous_end", pid=v2_pid), 120)
    rpc(sock, "action.run", {"id": INSTALL_ACTION})
    if wait_exit(v2_pid, 60) is None:
        return {"result": "v2's install click did nothing", "status": rpc(sock, "updates.status")}
    opened = marks.wait(lambda rows: next((r for r in rows if r["name"] == "launch.first_window_frame_committed"
                                           and r["pid"] not in old_pids), None), a.relaunch_timeout)
    with open(os.path.join(installed_path, "Contents/Info.plist"), "rb") as f:
        installed = plistlib.load(f)["CFBundleVersion"]
    return {"result": "updated" if opened and installed == i3["CFBundleVersion"] else "failed",
            "v3_pid": opened and opened["pid"], "installed_build": installed, "v3_build": i3["CFBundleVersion"]}


def card_marks(rows, pid):
    """The update card kinds v1 showed, in order (card.* marks)."""
    return [r["name"] for r in rows if r["pid"] == pid and r["name"].startswith("card.")]


def answer_found_step(a, sock, marks, pid):
    """Without the automatic-install opt-in (the default on every channel): the check stops on the
    update-found step and nothing downloads until its Update; the staged update then waits on the
    Update Ready card and nothing relaunches until Restart to Update. Returns the steps seen; exits
    non-zero when either step did not ask."""
    status = rpc(sock, "updates.status").get("result") or {}
    steps = {"found": {k: status.get(k) for k in ("phase", "card", "badge", "detected_version", "automatic_downloads")}}
    # The found step asks: nothing downloads by itself while it waits (a bounded negative wait).
    downloaded = marks.wait(lambda rows: first(rows, "phase.downloading", pid=pid), 3)
    steps["downloaded_without_answer"] = bool(downloaded)
    if downloaded:
        raise SystemExit("the found update downloaded before its Update was pressed")
    steps["update_reply"] = rpc(sock, "debug.updater", {"action": "press", "button": "update"}).get("result")
    log("found step answered: Update", json.dumps(steps)[:600])
    staged = marks.wait(lambda rows: first(rows, "phase.ready", pid=pid), a.stage_timeout)
    if not staged:
        raise SystemExit(f"Update on the found step staged nothing: {json.dumps(rpc(sock, 'updates.status'))[:1500]}")
    steps["staged"] = staged
    # The ready step asks: the app keeps running and installs nothing until Restart to Update.
    # --click-at-stage clicks at once instead (the staging work's timing), so it only reads.
    steps["relaunched_without_answer"] = wait_exit(pid, 0 if a.click_at_stage else 5) is not None
    steps["install_started_without_answer"] = bool(first(marks.read(), "install_started", pid=pid))
    if steps["relaunched_without_answer"] or steps["install_started_without_answer"]:
        raise SystemExit("the staged update installed or relaunched before Restart to Update")
    status = rpc(sock, "updates.status").get("result") or {}
    steps["ready"] = {k: status.get(k) for k in ("phase", "card", "badge", "detected_version", "automatic_downloads")}
    steps["phases"] = [r["name"] for r in marks.read() if r["pid"] == pid and r["name"].startswith(("phase.", "card.", "download_clicked"))]
    log("ready step asks", json.dumps(steps["ready"]))
    return steps


def run_attempt_scenario(a, sock, marks, pid, result):
    """Runs Attempt Update once and checks what the update UI shows (the card.* marks, then
    updates.status). Exits non-zero when the expected result never shows."""
    before = len(card_marks(marks.read(), pid))
    reply = rpc(sock, "action.run", {"id": ATTEMPT_ACTION})
    log("attempt", json.dumps(reply)[:300])
    expected = {"attempt-up-to-date": ["card.up_to_date"], "attempt-update": ["card.ready"],
                "attempt-feed-error": ["card.check_failed"], "attempt-download-error": ["card.check_failed"]}[a.scenario]
    hit = marks.wait(lambda rows: any(m in card_marks(rows, pid)[before:] for m in expected), a.stage_timeout)
    rows = marks.read()
    status = rpc(sock, "updates.status").get("result") or {}
    shown = card_marks(rows, pid)[before:]
    failure = first(rows, "failure_content.*", pid=pid)
    result["scenario"] = {"name": a.scenario, "reply": reply, "card_marks": shown,
                          "phases": [r["name"] for r in rows if r["pid"] == pid and r["name"].startswith("phase.")],
                          "failure_content": failure and failure["name"],
                          "status": {k: status.get(k) for k in ("phase", "card", "badge", "detected_version", "log")}}
    log("scenario", json.dumps(result["scenario"])[:3000])
    if not hit:
        raise SystemExit(f"{a.scenario}: the update UI never showed {expected}; it showed {shown}")
    # The result must come from this click's check: a progress card first, then the result.
    progress = [i for i, m in enumerate(shown) if m in ("card.checking", "card.downloading")]
    result_at = min(i for i, m in enumerate(shown) if m in expected)
    if not progress or progress[0] > result_at:
        raise SystemExit(f"{a.scenario}: no checking or downloading card before {expected}: {shown}")
    if a.scenario == "attempt-update" and not status.get("badge"):
        raise SystemExit("attempt-update: the staged update has no Restart to Update pill")
    if a.scenario == "attempt-download-error" and not (failure and "downloadManually" in failure["name"]):
        raise SystemExit(f"attempt-download-error: the failure offers no Download Manually: {failure}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--app", required=True)
    ap.add_argument("--tag", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--port", type=int, default=0, help="loopback port for the appcast (default: a free one)")
    ap.add_argument("--stage-timeout", type=float, default=240)
    ap.add_argument("--relaunch-timeout", type=float, default=120)
    ap.add_argument("--handoff", action="store_true",
                    help="give v2's cmux-tui and acpmux another build commit, so the update takes the daemon handoff")
    ap.add_argument("--sessions", action="store_true",
                    help="run a terminal counter and an agent turn across the update and check they survive")
    ap.add_argument("--agent-count", type=int, default=1, help="active FIFO-gated turns with --sessions (default: 1)")
    ap.add_argument("--terminal-count", type=int, default=1, help="running counters with --sessions (default: 1)")
    ap.add_argument("--required-update", action="store_true",
                    help="turn automatic downloads off (cmux.json) and require v2 (managed MinimumVersion): "
                         "the update must still download and stage with no click")
    ap.add_argument("--sparkle-auto", action="store_true",
                    help="v1 runs with SUAutomaticallyUpdate on and starts with Sparkle's scheduled background "
                         "check (Sparkle's own silent driver stages the update, as on a Mac whose nightly "
                         "preferences have automatic updates on)")
    ap.add_argument("--readonly-install", action="store_true",
                    help="make the app's folder read-only after the update stages: the click must not quit; "
                         "the failure sheet with Download Manually shows (the install preflight)")
    ap.add_argument("--break-staged", action="store_true",
                    help="delete Sparkle's staged installation after the update stages: the install must fail "
                         "visibly while the app runs (the failure sheet with Download Manually), never as a dead click")
    ap.add_argument("--notes", action="store_true",
                    help="publish signed release notes for v2 (a localized What's New document) next to the feed, "
                         "signed with the throwaway key, and read the staged highlights (updates.highlights)")
    ap.add_argument("--language", help="v1's AppleLanguages, for example ja")
    ap.add_argument("--surface-shots", action="store_true",
                    help="capture the React update surfaces: the staged card's highlights popover before the "
                         "restart and the Updated card after it, light and dark (debug.window_snapshot)")
    ap.add_argument("--island-lifecycle", action="store_true",
                    help="with --surface-shots and --notes: check that each update page exists only while its card "
                         "shows (debug.update_surfaces state): the Updated card's page at launch and none after its x, "
                         "no highlights page before staging, the highlights page drawn (the popover opens only with "
                         "a measured page) and 3 staged items (the updater's data) once staged, the Updated card's "
                         "page drawn after the restart")
    ap.add_argument("--changelog-shots", action="store_true",
                    help="with --surface-shots and --notes: after each surface capture, capture the card at the "
                         "narrow sidebar width and the What's New page its button opens, light and dark (cx-7rone)")
    ap.add_argument("--second-hop", action="store_true",
                    help="after the relaunch, publish a v3 and update the relaunched build again")
    ap.add_argument("--click-at-stage", action="store_true",
                    help="click the moment the update stages, not after the staging work (the rollback keep) ends")
    ap.add_argument("--scenario", choices=SCENARIOS,
                    help="the palette's Attempt Update: up-to-date (the feed offers v1 itself) -> the up to date card; "
                         "update -> checking or downloading, then the staged update card (Restart to Update); "
                         "staged (a check stages first) -> Check for Updates keeps the staged card, then Attempt "
                         "Update installs and relaunches; feed-error (no appcast) -> the check failed card; "
                         "download-error (the archive is missing) -> the check failed card and the failure sheet "
                         "content with Download Manually")
    a = ap.parse_args()
    if not 1 <= a.agent_count <= 32 or not 1 <= a.terminal_count <= 32:
        ap.error("session counts must be between 1 and 32")
    if not a.sessions and (a.agent_count != 1 or a.terminal_count != 1):
        ap.error("session counts need --sessions")
    if a.island_lifecycle and not (a.surface_shots and a.notes):
        ap.error("--island-lifecycle needs --surface-shots and --notes")
    if a.changelog_shots and not (a.surface_shots and a.notes):
        ap.error("--changelog-shots needs --surface-shots and --notes")

    if a.port == 0:
        probe = socket.socket()
        probe.bind(("127.0.0.1", 0))
        a.port = probe.getsockname()[1]
        probe.close()
    out = os.path.abspath(a.out)
    work = os.path.join(out, "work")
    if os.path.exists(work):
        shutil.rmtree(work)
    keys, feed = os.path.join(work, "keys"), os.path.join(work, "feed")
    for d in (keys, feed, os.path.join(work, "v1"), os.path.join(work, "v2"), os.path.join(work, "cwd")):
        os.makedirs(d)
    marks_path = os.path.join(work, "marks.ndjson")
    name = os.path.basename(a.app.rstrip("/"))
    v1, v2 = os.path.join(work, "v1", name), os.path.join(work, "v2", name)
    feed_url = f"http://127.0.0.1:{a.port}/appcast.xml"
    sock = f"/tmp/cmux-debug-{a.tag}.sock"
    server = app = None
    owned_apps = {}
    owned = Owned(TagTeardown._table)
    def remember_app(pid):
        row = TagTeardown._table().get(pid)
        if row and any(teardown.in_bundle(row[2]) for teardown in teardowns):
            owned_apps[pid] = row[1:]  # start time and command; the Sparkle parent may exit
    def remember_tag():
        # One TagTeardown per copy for the whole run: each remember() records the daemons and state roots that run
        # now, so a cancellation after the old daemons exited still finds their hosts and holders.
        for teardown in teardowns:
            if os.path.isdir(teardown.app):
                teardown.remember()
    result = {"tag": a.tag, "app": name}
    slug = "-".join(filter(None, "".join(c if c.isalnum() else " " for c in a.tag.lower()).split()))
    acp_home = os.path.join(os.environ["HOME"], ".acpmux/builds", "com.cmuxterm.app.debug." + re.sub(r"[^a-z0-9]+", ".", slug.lower()).strip("."))
    terminals, agents = [], []
    teardowns = [TagTeardown(copy, acpmux_home=acp_home, acpmux_socket=os.path.join(acp_home, "acpmux.sock"), log=log)
                 for copy in (v1, v2)]
    try:
        # A CI timeout or cancellation must enter the same ownership-scoped teardown (the finally below, with these
        # same instances).
        teardowns[0].install()
        public_key = run(["swift", os.path.join(HERE, "keys.swift"), "generate", keys])
        run(["/usr/bin/ditto", a.app, v1])
        run(["/usr/bin/ditto", a.app, v2])
        if a.handoff:
            commit = bundle_commit(v2)
            bin2 = os.path.join(v2, "Contents/Resources/bin")
            result["handoff_patch"] = {name: patch_build_stamp(os.path.join(bin2, name), commit) for name in ("cmux-tui", "acpmux")}
            log("v2 daemons stamped", json.dumps(result["handoff_patch"]))
        if a.sessions:
            fake = os.path.abspath(os.path.join(HERE, "../../../cmux-tui/crates/acpmux/tests/fake_agent.py"))
            for i in range(a.agent_count):
                directory = os.path.join(work, f"agent-{i + 1}")
                os.makedirs(directory)
                agents.append(Agent(acp_home, fake, directory, log, configure=i == 0))
            for i in range(a.terminal_count):
                directory = os.path.join(work, f"terminal-{i + 1}")
                os.makedirs(directory)
                terminals.append(Terminal(v1, directory, log, f"cmux-app-{slug}"))
        harness = {"feed": feed_url, "marks": marks_path}
        base = int(time.time())
        v1_harness = dict(harness)
        if a.sparkle_auto:
            v1_harness["background"] = True
        if a.notes:
            v1_harness["contentKey"] = public_key
        i1 = plist_set(v1, {"SUPublicEDKey": public_key, "CFBundleVersion": str(base)}, v1_harness)
        v2_extra = {}
        if a.required_update:
            # v2 is a newer version, which v1's organization requires.
            with open(os.path.join(v2, "Contents/Info.plist"), "rb") as f:
                short = plistlib.load(f).get("CFBundleShortVersionString", "0.0.0")
            parts = (short.split("-")[0].split(".") + ["0", "0"])[:3]
            v2_extra["CFBundleShortVersionString"] = ".".join(parts[:2] + [str(int(parts[2]) + 1)])
        i2 = plist_set(v2, {"SUPublicEDKey": public_key, "CFBundleVersion": str(base + 1), **v2_extra}, harness)
        result.update(v1_build=i1["CFBundleVersion"], v2_build=i2["CFBundleVersion"], bundle_id=i1.get("CFBundleIdentifier"))
        archive = os.path.join(feed, "update.zip")
        run(["/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", v2, archive])
        signature = run(["swift", os.path.join(HERE, "keys.swift"), "sign", keys, archive])
        length = os.path.getsize(archive)
        short = i2.get("CFBundleShortVersionString", "0")
        appcast = f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>update harness</title>
    <item>
      <title>{short} ({i2['CFBundleVersion']})</title>
      <pubDate>{time.strftime('%a, %d %b %Y %H:%M:%S +0000', time.gmtime())}</pubDate>
      <sparkle:version>{i2['CFBundleVersion']}</sparkle:version>
      <sparkle:shortVersionString>{short}</sparkle:shortVersionString>
      <description><![CDATA[New: the update harness relaunch]]></description>
      <enclosure url="http://127.0.0.1:{a.port}/{'missing.zip' if a.scenario == 'attempt-download-error' else 'update.zip'}" length="{length}" type="application/octet-stream" sparkle:edSignature="{signature}"/>
    </item>
  </channel>
</rss>
"""
        if a.scenario == "attempt-up-to-date":
            # The feed's newest item is the running build: nothing to update to.
            appcast = appcast.replace(f"<sparkle:version>{i2['CFBundleVersion']}</sparkle:version>",
                                      f"<sparkle:version>{i1['CFBundleVersion']}</sparkle:version>")
        if a.scenario != "attempt-feed-error":
            with open(os.path.join(feed, "appcast.xml"), "w") as f:
                f.write(appcast)
        if a.notes:
            write_notes(feed, keys, i2, log)
        server = subprocess.Popen([sys.executable, "-m", "http.server", str(a.port), "--bind", "127.0.0.1", "--directory", feed],
                                  stdout=open(os.path.join(out, "server.log"), "w"), stderr=subprocess.STDOUT,
                                  stdin=subprocess.DEVNULL)
        marks = Marks(marks_path)
        if os.path.exists(sock):
            os.unlink(sock)
        home = os.environ["HOME"]
        env = {"HOME": home, "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
               "SHELL": "/bin/zsh", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1",
               "CMUX_NEXT_SOCKET_MODE": "automation", "CMUX_DEV_BACKEND_MODE": "local"}
        if a.surface_shots:
            # v1 opens as if it had just updated from an older build: its "cmux Updated!" card shows
            # at launch, so both appearances are captured with this config (the relaunched app
            # starts without the harness environment).
            record_dir = os.path.join(os.environ["HOME"], "Library/Application Support/cmux-next", i1["CFBundleIdentifier"])
            os.makedirs(record_dir, exist_ok=True)
            with open(os.path.join(record_dir, "last-update.json"), "w") as f:
                json.dump({"fromVersion": "0.64.0", "fromBuild": str(base - 1), "toVersion": i1.get("CFBundleShortVersionString", "0"),
                           "toBuild": i1["CFBundleVersion"], "stagedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                           "changelog": {"version": i1.get("CFBundleShortVersionString", "0"), "lines": ["New: Highlights before you restart"]},
                           "highlights": {"version": i1.get("CFBundleShortVersionString", "0"), "build": i1["CFBundleVersion"],
                                          "fromVersion": "0.64.0", "fromBuild": str(base - 1), "source": "whatsNew", "language": "en",
                                          "date": time.strftime("%Y-%m-%d", time.gmtime()), "moreCount": 2,
                                          "changelog": {"from": "0.64.0", "to": i1.get("CFBundleShortVersionString", "0")},
                                          "items": [{"id": "a", "title": "Restart to Update is instant", "category": "new",
                                                     "summary": "The click answers in one frame."},
                                                    {"id": "b", "title": "Highlights before you restart", "category": "new"}]}}, f)
            # Light and dark captures follow debug.appearance only with a theme for each.
            config = os.path.join(work, "cmux.json")
            with open(config, "w") as f:
                json.dump({"appearance": {"theme": "light:Builtin Light,dark:Builtin Dark"}}, f)
            env["CMUX_NEXT_CONFIG_FILE"] = config
        if a.required_update:
            config = os.path.join(work, "cmux.json")
            with open(config, "w") as f:
                json.dump({"updates": {"downloadAutomatically": False}}, f)
            managed = os.path.join(work, "managed.plist")
            with open(managed, "wb") as f:
                plistlib.dump({"MinimumVersion": i2["CFBundleShortVersionString"]}, f)
            env.update(CMUX_NEXT_CONFIG_FILE=config, CMUX_NEXT_MANAGED_PREFS_FILE=managed)
            result["required"] = {"from": i1.get("CFBundleShortVersionString"), "minimum": i2["CFBundleShortVersionString"]}
        binary = os.path.join(v1, "Contents/MacOS", i1["CFBundleExecutable"])
        arguments = ["-SUAutomaticallyUpdate", "YES"] if a.sparkle_auto else []
        if a.language:
            arguments += ["-AppleLanguages", f"({a.language})"]
        app = subprocess.Popen([binary, *arguments], env=env, cwd=os.path.join(work, "cwd"), stdin=subprocess.DEVNULL,
                               stdout=open(os.path.join(out, "v1.log"), "w"), stderr=subprocess.STDOUT, start_new_session=True)
        v1_pid = app.pid
        remember_app(v1_pid)
        remember_tag()
        result["v1_pid"] = v1_pid
        log("v1 pid", v1_pid, "build", i1["CFBundleVersion"])
        if not marks.wait(lambda rows: first(rows, "launch.first_window_frame_committed", pid=v1_pid), 120):
            raise SystemExit("v1 showed no window")
        if not wait_socket(sock, 60):
            raise SystemExit(f"v1's control socket {sock} did not open")
        if a.surface_shots:
            result["v1_last_highlights"] = rpc(sock, "updates.highlights", {"last": True}).get("result")
            time.sleep(2.0)  # capture timing only: the card's page loads and reports its height
            result["v1_updated_shots"] = surface_shots(sock, out, "v1-updated", log, popover=False)
        if a.island_lifecycle:
            # Launch: the Updated card's page only. A launch check may stage the update already, so
            # the highlights page must follow the card, not be absent.
            state = island_state(sock)
            island_check(result, "v1-launch", state, updatedCard="true", updatedPage="true", highlights=state.get("card"))
            rpc(sock, "debug.update_surfaces", {"action": "dismiss-updated"})
            deadline = time.monotonic() + 5
            while island_state(sock).get("updatedCard") == "true" and time.monotonic() < deadline:
                time.sleep(0.2)  # the sidebar applies the dismissal on its next model pass
            state = island_state(sock)
            idle = state.get("card") == "false"
            island_check(result, "v1-after-dismiss", state, updatedCard="false", updatedPage="false",
                         highlights=state.get("card"), **({"sidebarWebViews": 0} if idle else {}))
            result["island_lifecycle"]["v1-after-dismiss"]["idle"] = idle
            log("island lifecycle", json.dumps(result["island_lifecycle"]))
        if not first(marks.read(), "updater_created", pid=v1_pid):
            raise SystemExit("v1 did not start the harness updater (is it a DEBUG build with the harness keys?)")
        if a.scenario and a.scenario != "attempt-staged":
            run_attempt_scenario(a, sock, marks, v1_pid, result)
            return
        # Sparkle's launch check may already run; an explicit check makes the run deterministic.
        if not a.sparkle_auto:
            log("check", json.dumps(rpc(sock, "action.run", {"id": CHECK_ACTION}))[:200])
        # Without the automatic-install opt-in (the default) the check stops on the update-found step.
        ends = ["phase.ready", "phase.note", "phase.available"]
        staged = marks.wait(lambda rows: next((first(rows, end, pid=v1_pid) for end in ends if first(rows, end, pid=v1_pid)), None),
                            a.stage_timeout)
        if a.required_update:
            # Staged with automatic downloads off: only the requirement could download it.
            result["required"]["staged_without_click"] = bool(staged and staged["name"] == "phase.ready")
            result["required"]["phases"] = [r["name"] for r in marks.read() if r["pid"] == v1_pid and r["name"].startswith("phase.")]
            log("required update", json.dumps(result["required"]))
        if not a.required_update and not a.sparkle_auto:
            # No automatic-download opt-in here (the default): the check must stop on the
            # update-found step. Anything else (straight to staged) skipped the first ask.
            if not staged or staged["name"] != "phase.available":
                raise SystemExit(f"the check did not stop on the update-found step: {staged and staged['name']}")
            result["asked"] = answer_found_step(a, sock, marks, v1_pid)
            staged = result["asked"]["staged"]
        if not staged or staged["name"] != "phase.ready":
            status = rpc(sock, "updates.status")
            raise SystemExit(f"no staged update: {json.dumps(status)[:1500]}")
        log("staged")
        if not a.click_at_stage:
            # A person clicks seconds or hours after the card appears; the staging work is done by then.
            kept = marks.wait(lambda rows: first(rows, "keep_previous_end", pid=v1_pid), 120)
            log("staging work done" if kept else "staging work still running after 120 s; clicking anyway")
        if a.notes:
            # The notes load after staging (one fetch, verified); read until they count, 10 s at most.
            deadline = time.monotonic() + 10
            while True:
                highlights = rpc(sock, "updates.highlights").get("result")
                if (highlights or {}).get("source") == "whatsNew" or time.monotonic() > deadline:
                    break
                time.sleep(0.5)
            result["highlights"] = highlights
            log("highlights", json.dumps(highlights, ensure_ascii=False)[:2000])
        if a.surface_shots:
            result["ready_shots"] = surface_shots(sock, out, "ready", log, popover=True)
        if a.island_lifecycle:
            items = len((result.get("highlights") or {}).get("items") or [])
            shown = result["ready_shots"].get("ready-light-popover-shown", {})
            island_check(result, "v1-staged", dict(island_state(sock), items=items, popoverShown=shown.get("shown")),
                         card="true", highlights="true", items=3, popoverShown="true")
        if a.changelog_shots:
            result["ready_changelog_shots"] = changelog_shots(sock, out, "ready", log, "open-changes", popover=True)
        if terminals:
            for terminal in terminals:
                terminal.start(v1)
                owned.add(terminal.pid)
            remember_tag()  # the tag's cmux-tui daemon runs the counters' terminals
            for agent in agents:
                agent.start()
                owned.add(agent.harness_pid)
                owned.add(agent.host_before.get("host_pid"))
            remember_tag()
            result["busy_before_install"] = {
                "agents": [{"session": agent.session, "host": agent.identity(), "daemon": agent.daemon_pid,
                            "turn_results": sum(e.get("kind") == "turn_result" for e in agent.events())}
                           for agent in agents],
                "commands": [{"terminal": terminal.term, "pid": terminal.pid} for terminal in terminals],
            }
            if any(row["turn_results"] or not row["host"]["harness_pid"]
                   or not sessions_alive(row["host"]["harness_pid"])
                   for row in result["busy_before_install"]["agents"]):
                raise SystemExit("an agent turn is not running before the install")
            if any(not terminal.pid or not sessions_alive(terminal.pid) for terminal in terminals):
                raise SystemExit("a terminal counter is not running before the install")
            result["busy_snapshot"] = rpc(sock, "debug.window_snapshot", {"path": os.path.join(out, "busy-before-install.png")})
            log("busy before install", json.dumps(result["busy_before_install"]))
        if a.readonly_install:
            os.chmod(os.path.dirname(v1), 0o555)
        if a.break_staged:
            staged_dir = os.path.join(os.environ["HOME"], "Library/Caches", i1["CFBundleIdentifier"],
                                      "org.sparkle-project.Sparkle/Installation")
            result["broken_staged"] = os.listdir(staged_dir) if os.path.isdir(staged_dir) else []
            shutil.rmtree(staged_dir, ignore_errors=True)
        if a.scenario == "attempt-staged":
            # Check for Updates while the update waits: the staged card stays (Sparkle skips the check).
            log("check while staged", json.dumps(rpc(sock, "action.run", {"id": CHECK_ACTION}))[:200])
            status = rpc(sock, "updates.status").get("result") or {}
            answered = any("check while an update waits" in line for line in status.get("log") or [])
            result["staged_check"] = {"badge": status.get("badge"), "card": status.get("card"), "answered_by_staged": answered,
                                      "card_marks": card_marks(marks.read(), v1_pid)}
            log("staged check", json.dumps(result["staged_check"]))
            if not status.get("badge") or not answered:
                raise SystemExit("a check while the update waits did not keep the staged update card")
        install_action = ATTEMPT_ACTION if a.scenario == "attempt-staged" else INSTALL_ACTION
        if "asked" in result and a.scenario is None:
            # The answer to the ready step: the Update Ready card's Restart to Update.
            install_action = "debug.updater press restart"
        result["install_action"] = install_action
        t_send = time.time()
        if install_action == "debug.updater press restart":
            reply = rpc(sock, "debug.updater", {"action": "press", "button": "restart"})
        else:
            reply = rpc(sock, "action.run", {"id": install_action})
        t_reply = time.time()
        log("install", json.dumps(reply)[:200])
        if a.break_staged or a.readonly_install:
            sheet = marks.wait(lambda rows: first(rows, "failure_content.*", pid=v1_pid), 60)
            # A moment for the sheet to open after the failure state (it opens in the same turn).
            presented = marks.wait(lambda rows: first(rows, "failure_sheet_presented", pid=v1_pid), 5)
            result["break_staged"] = {"failure_content": sheet and sheet["name"], "sheet_presented": bool(presented),
                                          "seconds_after_click": sheet and round(sheet["unix_ms"] / 1000 - t_send, 1),
                                          "app_still_running": sessions_alive(v1_pid),
                                       "status": rpc(sock, "updates.status") if sessions_alive(v1_pid) else None}
            log("break staged", json.dumps(result["break_staged"])[:2000])
            if not (sheet and presented and "downloadManually" in sheet["name"]):
                raise SystemExit("the failed install did not open a failure sheet with Download Manually")
            return
        t_exit = wait_exit(v1_pid, 60)
        if t_exit is None:
            # The click did nothing visible to the process: record what the updater says, then try
            # the way out a person has (Quit; Sparkle installs a staged update when the app quits).
            result["click"] = "no exit within 60 s"
            result["status_after_click"] = rpc(sock, "updates.status")
            log("CLICK DID NOTHING", json.dumps(result["status_after_click"])[:3000])
            log("quit", json.dumps(rpc(sock, "action.run", {"id": "quitKeepSessions"}))[:200])
            result["quit_exit"] = wait_exit(v1_pid, 60) is not None
            def installed(_):
                try:
                    with open(os.path.join(v1, "Contents/Info.plist"), "rb") as f:
                        build = plistlib.load(f)["CFBundleVersion"]
                except (OSError, ValueError, KeyError):
                    return None
                return build if build == i2["CFBundleVersion"] else None
            # The installer swaps the bundle after the app exits.
            result["installed_build_after_quit"] = wait_path(os.path.dirname(v1), installed, 60) or "unchanged"
            log("after quit", result["quit_exit"], result["installed_build_after_quit"])
            raise SystemExit("the install click did nothing")
        result["click"] = "exited"
        app.wait(5)
        restored = marks.wait(lambda rows: all(first(rows, m, not_pid=v1_pid) for m in RESTORED_MARKS[:2]) and rows,
                              a.relaunch_timeout)
        if not restored:
            raise SystemExit("the relaunched app showed no window")
        # The later launch marks arrive within a few seconds; read what came.
        marks.wait(lambda rows: all(first(rows, m, not_pid=v1_pid) for m in RESTORED_MARKS), 20)
        rows = marks.read()
        v2_pid = next(r["pid"] for r in rows if r["pid"] != v1_pid)
        remember_app(v2_pid)
        remember_tag()
        result["v2_pid"] = v2_pid
        with open(os.path.join(v1, "Contents/Info.plist"), "rb") as f:
            result["installed_build"] = plistlib.load(f)["CFBundleVersion"]
        click = first(rows, "install_clicked", pid=v1_pid)["unix_ms"]
        if a.handoff:
            handed = marks.wait(lambda rows: first(rows, "launch.daemon_version_handoff", not_pid=v1_pid), 60)
            result["daemon_handoff_mark"] = bool(handed)
        if terminals:
            relaunched = first(rows, "launch.first_window_frame_committed", not_pid=v1_pid)["unix_ms"] / 1000
            # Capture the relaunched app while every agent is still blocked on its FIFO.
            wait_socket(sock, 30)
            result["busy_relaunched_snapshot"] = rpc(sock, "debug.window_snapshot",
                {"path": os.path.join(out, "busy-after-relaunch.png")})
            result["terminal_survivals"] = [terminal.check(v1, click / 1000, relaunched, handoff=a.handoff)
                                            for terminal in terminals]
            remember_tag()  # the relaunched daemons run now
            result["agent_survivals"] = [agent.check(handoff=a.handoff) for agent in agents]
            # Keep the original single-session keys for existing receipt consumers.
            result["terminal_survival"] = result["terminal_survivals"][0]
            result["agent_survival"] = result["agent_survivals"][0]
            terminal_ok = all(terminal_survived(r, a.handoff) for r in result["terminal_survivals"])
            agent_ok = all(r["harness_alive_after_swap"] and r["same_host"] and r["transcript_prefix_preserved"]
                           and r["gate_released"] and r["turn_results"] == 1 and r["turn_status"] == "completed"
                           and not r["outcome_unknown"]
                           and r["before_gate_chunks"] == 1 and r["after_gate_chunks"] == 1
                           and (r["host_adopted"] if a.handoff else r["daemon_before"] == r["daemon_after"])
                           for r in result["agent_survivals"])
            result["session_survival_passed"] = terminal_ok and agent_ok
            log("session survival", json.dumps({k: result[k] for k in
                ("terminal_survivals", "agent_survivals", "session_survival_passed")}))
            if not result["session_survival_passed"]:
                raise SystemExit("sessions did not survive the update; inspect timeline.json")

        def at(name, pid):
            r = first(rows, name, pid=pid)
            return None if r is None else r["unix_ms"] - click

        timeline = {
            "socket_send_to_click_ms": click - t_send * 1000,
            "socket_reply_ms": (t_reply - t_send) * 1000,
            "click_to": {n: at(n, v1_pid) for n in ["install_started", "install_handed_to_sparkle", "phase.installing",
                                                     "feedback_state", "feedback_frame", "feedback_frame.stalled",
                                                     "feedback_frame_2", "feedback_frame_2.stalled",
                                                     "windows_*", "keep_previous_start", "keep_previous_end", "will_relaunch",
                                                     "main_window_closed.*", "main_window_closed.remaining_0", "will_terminate"]},
            "click_to_v1_exit_ms": t_exit * 1000 - click,
            "click_to_v2": {n: at(n, v2_pid) for n in ["process_start", "updater_created"] + RESTORED_MARKS},
        }
        result["timeline"] = timeline
        result["rows"] = rows
        result["v2_marks"] = sorted({r["name"] for r in rows if r["pid"] == v2_pid and not r["name"].startswith("launch.")})
        log(json.dumps(timeline, indent=1))
        # The relaunched app as the user sees it, and what its updater says.
        try:
            wait_socket(sock, 30)
            shot = os.path.join(out, "v2-window.png")
            result["v2_snapshot"] = rpc(sock, "debug.window_snapshot", {"path": shot}, timeout=30)
            result["v2_status"] = rpc(sock, "updates.status")
            if a.surface_shots:
                result["v2_last_highlights"] = rpc(sock, "updates.highlights", {"last": True}).get("result")
                result["updated_shots"] = surface_shots(sock, out, "updated", log, popover=False)
            if a.island_lifecycle:
                state = island_state(sock)
                island_check(result, "v2-updated", dict(state, drawn=float(state.get("updatedHeight", "0")) > 0),
                             updatedCard="true", updatedPage="true", drawn=True)
            # After the lifecycle check: "See What's New" marks the update seen, so the card goes.
            if a.changelog_shots:
                result["updated_changelog_shots"] = changelog_shots(sock, out, "updated", log, "open-whats-new", popover=False)
        except OSError as error:
            result["v2_socket_error"] = str(error)
        if a.second_hop:
            result["second_hop"] = second_hop(a, work, feed, keys, name, public_key, harness, base, marks, sock, v1,
                                              (v1_pid, v2_pid), click_after_keep=not a.click_at_stage)
            remember_tag()
            log("second hop", json.dumps(result["second_hop"]))
    finally:
        if a.readonly_install and os.path.isdir(os.path.dirname(v1)):
            os.chmod(os.path.dirname(v1), 0o755)
        with open(os.path.join(out, "timeline.json"), "w") as f:
            json.dump(result, f, indent=1)
        for pid, identity in owned_apps.items():
            current = TagTeardown._table().get(pid)
            if current and current[1:] == identity:
                try:
                    os.kill(pid, signal.SIGTERM)
                    wait_exit(pid, 20)
                except ProcessLookupError:
                    pass
        # End the tag's sessions: acpmux (its agents with it), the cmux-tui session (its terminals
        # with it), then any process left inside the bundle copies, by exact pid.
        result["session_processes_left"] = end_tag(teardowns, owned, acp_home, a.sessions, log)
        if server:
            server.terminate()
            server.wait(10)
            server = None
        result["leftovers"] = [command[:200] for _, command in processes_under(work)]
        log("LEFTOVERS", result["leftovers"])
        with open(os.path.join(out, "timeline.json"), "w") as f:
            json.dump(result, f, indent=1)
        if server:
            server.terminate()
            server.wait(10)
        shutil.rmtree(keys, ignore_errors=True)
        # What's New's record for this tag (the old app writes it when the update stages).
        if result.get("bundle_id"):
            record = os.path.join(os.environ["HOME"], "Library/Application Support/cmux-next", result["bundle_id"], "last-update.json")
            if os.path.exists(record):
                with open(record) as f:
                    result["last_update_record_left"] = f.read()
                os.unlink(record)
            with open(os.path.join(out, "timeline.json"), "w") as f:
                json.dump(result, f, indent=1)
    if a.island_lifecycle:
        log("island lifecycle", json.dumps(result.get("island_lifecycle")))
        if result.get("island_failures") or len(result.get("island_lifecycle", {})) != 4:
            raise SystemExit(f"island lifecycle failed: {result.get('island_failures')}, "
                             f"phases {sorted(result.get('island_lifecycle', {}))} of 4")


if __name__ == "__main__":
    main()
