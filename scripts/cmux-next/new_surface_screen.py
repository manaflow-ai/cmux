"""cmd-n-paint-e2e.py --screen: Cmd-T and Cmd-N, one key at a time, as the screen showed it. A report, no judgement.

For each key (`--keys`) and each gap (`--gaps`, ms: 0 = one key with the app idle; N = a second key N ms after a
first one, both in one recording, the gap by the app's own timer), `--runs` recordings. Each one is the app's
`debug.new_tab frame_strip` with `above`: every frame that the window server composited for the display (with the
page's pixels) from before the key to `--duration-ms` after it, at `--scale` (1: a point is a pixel). The numbers
of a recording, and what they do not see: new_surface_frames.py.

The session: `--workspaces N` makes the session that many workspaces with the repository's one session maker
(scripts/perf-bench/session_real.py make, as scripts/measure/pane-motion-films.py does): each added workspace
has a terminal tab and a page tab, `--live-shells` of the terminals keep a shell and each other one is parked. No
chat is in that session: a session with chats is not measured by this tool. A launch by the driver (`--app`) starts
from an empty saved session for its tag (`fresh_session`), so the made session is this run's own.

Before each recording a spare New Tab page is ready (a row with none in 30 s is INVALID). A Cmd-T is pressed from
a terminal tab that Control-` opened, as the driver's own openings (the new page then changes the content area);
after the recording its new tabs close, then that terminal tab. A Cmd-N is pressed from the workspace that the
app shows; its new workspaces close after the recording. Each row says the count of tabs or workspaces before its
key.

The proof of the input, in each row: the app's own opening records, the count of tabs (Cmd-T) or workspaces
(Cmd-N) and the opening marks must each say one opening for each sent key; a row where one does not is INVALID. The
app keeps only its newest opening records, so the new ones are counted by the list's content, not by its length
(new_surface_frames.py `opened_since`), and the driver refuses a run of more than 60 openings before its launch (the
app's list has 64 places: `--runs` 10 with the default keys and gaps is 60). The key goes to the app's key path through `debug.key`'s sender, not
through the keyboard's driver: the path from the keyboard to the app is not in a number.

`--page-watch N`: the last N recordings of each case also ask the new page for its own layout watch (`debug.agent_pane
layout_watch`: the page's composer, its chips and its header, each frame of the page): the parts that moved after
the page's first frame, by name, from and to, in points. The ask goes on the app's socket while the frames are
recorded, and it is made again each 33 ms until a page answers: for one key from the recording's start, when no
page may be in the pane yet; for a second key from 30 ms after its due time. Those rows say `page_watch` and the
other rows have none; with the defaults (`--runs 3`, `--page-watch 3`) each row has it. A watch that a page
answered before the judged key says `before_the_key`. A move before the watch's first frame is in the screen's
frames only.

Kept pictures (`--screen-tgz FILE`, with the report): for the first `--keep-keys` recordings of each case and for
each recording with a change after the first content or an INVALID reason, the frame before the key, the named
frames and the first frame of each change, at the recorded scale. No picture of a later recording is kept after
160 kept pictures.

A recording whose reply is the control's `timeout` with `state: in_progress` (frame_strip's compare and its files
took longer than the call's limit; more frames or a larger `--scale` make it longer) is an INVALID row, and the
app's call goes on after the reply: it uses the processor and the app's one list of bench marks, so a key in that
time has numbers of 2 calls. The app has no call that says when frame_strip ended; its last act is the file
`strip.png` in the recording's folder. So the tool waits for that file (up to `CALL_END_PAUSES` pauses of 0.5 s)
before it removes the folder and sends a key, ends that case (`ended_early` in the case, `call_went_on` in the
row), and goes on with the next case. A call whose file did not come stops the run: no later recording, `stopped`
in the report and in the last printed line, and the driver's exit code is `STOPPED_EXIT`. A call that made no frame
writes no such file and reads as one that did not end. The row's folder is removed before each call, so a file of
an earlier run is not read as this call's.
"""
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import threading
import time

import bench_page_engine
import new_surface_frames as frames_of

MAKER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "perf-bench", "session_real.py")
LEAD_MS = 120  # frame_strip sends the key this long after its recording starts (later when the first frame is late)
MARK = "NEW-SURFACE-SCREEN"
OPENINGS_LIMIT = 60  # the app's list of opening records has 64 places (NewTabSparePool.maximumOpenings)
LAST_FILE = "strip.png"  # the last file that frame_strip writes into its folder (WindowFrame.writeAll), before its reply
CALL_END_PAUSES = 240  # of 0.5 s: how long the tool waits for a frame_strip call that went on after its `timeout` reply
STOPPED_EXIT = 3  # the driver's exit code for a run that stopped before its last case


def goes_on(reply):
    """True when the control says that the app's call of this reply still runs (`timeout` with `state: in_progress`)."""
    error = reply.get("error")
    data = error.get("data") if isinstance(error, dict) else None
    return isinstance(data, dict) and data.get("state") == "in_progress"


def openings(opts):
    """The openings that one run asks for: `--runs` for each key and gap, and two in a recording with a gap."""
    in_a_round = sum(2 if float(gap) else 1 for gap in opts.gaps.split(",") if gap)
    return opts.runs * len([key for key in opts.keys.split(",") if key]) * in_a_round


def add_arguments(parser):
    """The mode's own arguments; the driver has `--screen` itself and adds these only with it."""
    parser.add_argument("--gaps", default="0,100", help="--screen: ms between two keys of one recording, comma separated (0: one key)")
    parser.add_argument("--workspaces", type=int, default=0, help="--screen: make the session this many workspaces first (0: as launched)")
    parser.add_argument("--live-shells", type=int, default=8, help="--screen: terminals of the made session that keep a shell")
    parser.add_argument("--page-url", default="http://127.0.0.1:9/", help="--screen: the address of each page tab of the made session")
    parser.add_argument("--seed-deadline", type=float, default=1500.0, help="--screen: seconds for the session's maker")
    parser.add_argument("--scale", type=float, default=1.0, help="--screen: the scale of the recorded frames")
    parser.add_argument("--tolerance", type=float, default=frames_of.TOLERANCE, help="--screen: the share of a region's pixels under which two pictures are one")
    parser.add_argument("--page-watch", type=int, default=3, help="--screen: recordings of each case that also ask the page for its layout watch")
    parser.add_argument("--keep-keys", type=int, default=2, help="--screen: recordings of each case whose pictures are kept in any case")
    parser.add_argument("--screen-tgz", help="--screen: write the report and the kept pictures here")
    parser.add_argument("--display", default="", help="--screen: the display's own line, for the report (the entry's virtual display)")
    parser.add_argument("--display-hz", type=float, default=0, help="--screen: the display's refresh rate, when the entry made the display")
    parser.add_argument("--build", help="--screen: the build's form (scripts/measure/build-flags.py's file), for the report")
    parser.add_argument("--page-engine", default="cef", choices=bench_page_engine.WANTED,
                        help="--screen: the engine that the new page must run in for a row to be a number (any: each row only says it)")


def seed(socket_path, count, live, url, deadline, out):
    """`count` more workspaces by session_real.py `make` on the app's daemon (pane-motion-films.py's seed)."""
    command = [sys.executable, MAKER, "make", "--app-socket", socket_path, "--workspaces", str(count), "--terminals", str(count),
               "--agents", "0", "--no-agents", "--settle", "0", "--tabs", str(2 * count), "--panes", str(count),
               "--browser-tabs", str(count), "--browser-url", url, "--live-shells", str(live), "--out", os.path.join(out, "session.json")]
    began = time.monotonic()
    try:
        done = subprocess.run(command, check=False, timeout=deadline, capture_output=True, text=True)
        code, said = done.returncode, done.stdout + done.stderr
    except subprocess.TimeoutExpired as late:
        parts = [part.decode(errors="replace") if isinstance(part, bytes) else part or "" for part in (late.stdout, late.stderr)]
        code, said = f"not done in {deadline:.0f} s", "".join(parts)
    print(said[-3000:], flush=True)
    counted = re.findall(r"^made (\d+)/", said, re.M)
    return {"asked_more": count, "live_shells": live, "maker_exit": code, "maker_said_made": int(counted[-1]) if counted else 0,
            "seed_s": round(time.monotonic() - began, 1)}


def fresh_session(tag, app=None):
    """An empty saved session for the tag's next launch, as each BenchApp launch has (bench_launch.start_fresh_state:
    a tag's earlier state moves aside). The mode's session of many workspaces is under the entry's one fixed tag, and
    bench_launch.py says that a launch restores its tag's saved session. The state moves only while no process of
    the tag runs: with `app` (its bundle), the tag's daemons that an earlier run left end first (tag_teardown.py),
    because such a daemon keeps its session.

    The teardown ends each process that runs from below the path `app`, and their direct children (the shells of the
    tag's terminals). So this refuses, and ends nothing, when the path is not a `cmux DEV <tag>.app` bundle
    (bench_launch.tag_of: a shipped bundle, a folder that is no bundle), when the bundle's tag is not `tag`, and
    when an app of the bundle runs now (`tag-in-use`, as a BenchApp launch refuses): that app is a person's, or
    another run's, and not this run's to end. A process lists the path that it was started by, so the app is
    searched by the bundle's real path, by the path as given (a link to the bundle) and by the real path with no
    `/private` before it (a Mac's `/tmp` and `/var`). The state that moves is the bundle's tag's (`--tag My-Tag` is
    the tag `my-tag`)."""
    import bench_launch  # only this mode's launch and the entry's cleanup need it
    if app:
        from tag_teardown import TagTeardown
        given, app = os.path.abspath(app).rstrip("/"), os.path.realpath(app).rstrip("/")
        of_bundle = bench_launch.tag_of(app)  # stops here when the path is not a tagged DEV bundle
        if of_bundle != re.sub(r"[^a-z0-9]+", "-", tag.lower()).strip("-"):
            sys.exit(f"{MARK}: --tag {tag} is not the tag of {os.path.basename(app)} ({of_bundle}): nothing ended, no session moved")
        paths = {app, given, app[len("/private"):] if app.startswith("/private/") else app}
        running = sorted({pid for path in paths for pid in bench_launch.bundle_pids(path, "Contents/MacOS/")})
        if running:
            sys.exit(f"{MARK}: tag-in-use: an app of {app} runs now (pid {', '.join(map(str, running))}): it is not this "
                     "run's to end. Quit it, then run again. Nothing ended, no session moved")
        TagTeardown(app).end()
        tag = of_bundle
    bench_launch.start_fresh_state(tag)


class Screen:
    """One run of the mode on a running app. `rpc(method, params, timeout)` is the driver's; `tools` are its own
    steps (`spare_ready`, `terminal_tab`, `close_new`), and `sleep` its pause."""

    def __init__(self, opts, rpc, tools, sleep=time.sleep, make_session=seed):
        self.opts, self.rpc, self.tools, self.sleep, self.make_session = opts, rpc, tools, sleep, make_session
        self.keep = os.path.join(opts.out, "screen-keep")
        self.rows, self.kept = [], 0

    def workspaces(self):
        snap = self.rpc("snapshot.get", None, 180) or {}
        topology = (snap.get("topology") or snap) if isinstance(snap, dict) else {}
        return len([w for w in topology.get("workspaces") or [] if isinstance(w, dict)])

    def count(self, key):
        """What one more opening adds one to: the focused pane's tabs (Cmd-T), the workspaces (Cmd-N)."""
        if key == "n":
            return self.workspaces()
        return len((self.rpc("debug.new_tab", {"action": "switch_and_type"}, 30) or {}).get("tabs") or [])

    def opened(self):
        return (self.rpc("debug.new_tab", {"action": "state"}, 30) or {}).get("openings") or []

    def session(self):
        opts, have = self.opts, self.workspaces()
        fact = {"asked": opts.workspaces, "at_launch": have, "chats": 0}
        if opts.workspaces > have:
            fact.update(self.make_session(opts.socket, opts.workspaces - have, opts.live_shells, opts.page_url, opts.seed_deadline, opts.out))
        fact["listed_by_the_app"] = self.workspaces()
        fact["as_asked"] = not opts.workspaces or fact["listed_by_the_app"] == opts.workspaces
        print(f"{MARK}-SESSION {json.dumps(fact)}", flush=True)
        return fact

    def watch(self, out, start_at, stop_at):
        """Asks the shown page for its layout watch from `start_at` until one answers (before the key the pane shows
        a terminal, so the ask fails at once and is asked again), as chat-open-bench.py's click cases do."""
        while time.monotonic() < start_at:
            self.sleep(0.005)  # tool pacing: the second key of a gap recording is not sent yet
        while time.monotonic() < stop_at:
            asked = time.monotonic()
            reply = self.rpc("debug.agent_pane", {"action": "layout_watch", "ms": max(100, self.opts.duration_ms - 200)},
                             self.opts.duration_ms / 1000 + 8)
            if isinstance(reply, dict) and not reply.get("error") and "frames" in reply:
                out["watch"], out["asked"] = reply, asked
                return
            out["error"] = json.dumps(reply, default=str)[:300]
            self.sleep(0.033)  # tool pacing: no page is in the pane yet

    def one(self, key, gap, run, session_fault):
        opts, label = self.opts, f"cmd-{key}-{'idle' if not gap else f'gap{gap:g}'}-{run}"
        keys_sent = 2 if gap else 1
        row = {"label": label, "key": key, "gap_ms": gap, "run": run, "invalid": []}
        # Cmd-T from a terminal tab (Control-`), as the driver's openings: the new page then changes the content area.
        own_tabs = self.count("t") if key == "t" else None
        if key == "t":
            self.tools["terminal_tab"]()
        deadline = time.monotonic() + 30
        while not self.tools["spare_ready"]():
            if time.monotonic() > deadline:
                row["invalid"].append("spare: no ready spare page in 30 s before the key")
                self.close(0, own_tabs)
                return row
            self.sleep(0.2)  # tool pacing, as the driver's own wait for a ready spare
        before_count, before_opened = self.count(key), self.opened()
        row["tabs_before" if key == "t" else "workspaces_before"] = before_count
        self.sleep(0.5)  # the window settles (caret, hover) before the recording, as the driver's warm openings
        folder = os.path.join(opts.out, label)
        # `capture`: the screen's frames also where the app has the Screen Recording grant (frame_strip then takes
        # the window list by itself, and the page is not in those frames).
        params = {"action": "frame_strip", "key": key, "dir": folder, "above": True, "capture": frames_of.CAPTURE,
                  "scale": opts.scale, "tolerance": opts.tolerance, "duration_ms": opts.duration_ms + gap}
        if gap:
            params.update({"repeat": 2, "repeat_interval_ms": gap})
        # No file of an earlier run in the row's folder (`--out` has a fixed default): an old last file is no call's end.
        shutil.rmtree(folder, ignore_errors=True)
        watched, watcher = {}, None
        asked = time.monotonic()
        if run >= opts.runs - opts.page_watch:
            watcher = threading.Thread(target=self.watch, daemon=True,
                                       args=(watched, asked + (LEAD_MS + gap + 30) / 1000 if gap else asked, asked + opts.duration_ms / 1000 + 6))
            watcher.start()
        reply = self.rpc("debug.new_tab", params, (opts.duration_ms + gap) / 1000 + 180) or {}
        if watcher:
            watcher.join(timeout=max(0.0, asked + opts.duration_ms / 1000 + 6 - time.monotonic()) + 20)
        if "error" in reply:
            row["invalid"].append(f"frame_strip: {json.dumps(reply.get('error'), default=str)[:300]}")
            if goes_on(reply):
                row["call_went_on"] = self.call_end(folder)
            shutil.rmtree(folder, ignore_errors=True)
            # Cmd-W only for what the keys opened: a call that the app refused sent no key, and a thing that another
            # actor opened in the wait is not the tool's (never more Cmd-W than keys).
            self.close(min(keys_sent, max(0, self.count(key) - before_count)), own_tabs)
            return row
        records = self.opened()
        row.update(frames_of.one_key(reply, key, gap, opts.tolerance, opts.display_hz or None))
        row["label"] = label
        opened = frames_of.opened_since(before_opened, records)
        faults, starts = frames_of.input_proof(key, keys_sent, opened, self.count(key) - before_count, reply.get("spans"))
        row["invalid"] += faults + ([session_fault] if session_fault else [])
        # The marks' times from the row's zero (the reply's own zero is `key_work_ms` after it).
        starts = [round(start + (row.get("key_work_ms") or 0), 1) for start in starts]
        row.update({"keys_sent": keys_sent, "opening_marks_ms": starts, "lead_ms": reply.get("lead_ms"),
                    "second_key_late_ms": round(starts[1] - gap, 1) if gap and len(starts) > 1 else None,
                    "spare": [bool(record.get("spare")) for record in records[len(records) - opened:]],
                    "frame_count": reply.get("frame_count"), "mean_interval_ms": reply.get("mean_interval_ms")})
        # Each measure says its engine: the new page's, read after the recording. A page in another engine is no number.
        row["page_engine"] = bench_page_engine.page_engine(self.rpc("debug.agent_pane", {"action": "engine"}, 20))
        if opts.page_engine != "any" and bench_page_engine.family(row["page_engine"]) != opts.page_engine:
            row["invalid"].append(f"engine: the page ran in {row['page_engine']}, {opts.page_engine} was asked")
        if watcher:
            judged = asked + ((reply.get("lead_ms") if isinstance(reply.get("lead_ms"), (int, float)) else LEAD_MS) + gap) / 1000
            watch = watched.get("watch")
            row["page_watch"] = {"error": watched.get("error") or "no answer"} if not watch else {
                "asked_ms": round((watched["asked"] - judged) * 1000), "frames": watch.get("frames"),
                "first_content_ms": watch.get("first_content_ms"), "elements": watch.get("elements"),
                "shifts": watch.get("shifts"), "appeared": watch.get("appeared"), "scroll_jumps": watch.get("scroll_jumps"),
                # A watch that was asked before the judged key reads the page of the key before it.
                "before_the_key": watched["asked"] < judged}
        self.pictures(row, folder, run)
        shutil.rmtree(folder, ignore_errors=True)
        self.close(keys_sent, own_tabs)
        return row

    def call_end(self, folder):
        """Waits until the app's frame_strip call that went on after its reply wrote its last file into `folder`:
        whether it came, and after how many pauses."""
        for pauses in range(CALL_END_PAUSES):
            if os.path.exists(os.path.join(folder, LAST_FILE)):
                self.sleep(0.5)  # tool pacing: the call makes its reply after its last file
                return {"ended": True, "pauses": pauses}
            self.sleep(0.5)  # tool pacing: the app still compares and writes its frames
        return {"ended": os.path.exists(os.path.join(folder, LAST_FILE)), "pauses": CALL_END_PAUSES}

    def close(self, opened, own_tabs):
        """Closes the recording's new tabs or workspaces, then Control-`'s terminal tab when the pane still has one
        more tab than before it: each recording of a case starts from the same tabs."""
        if opened:
            self.tools["close_new"](opened)
        if own_tabs is not None and self.count("t") > own_tabs:
            self.tools["close_new"](1)

    def pictures(self, row, folder, run):
        # A row that is not first-is-final by its first content frame alone has no later changed frame: keep it too.
        wanted = (run < self.opts.keep_keys or row.get("changes_after_content") or row.get("invalid")
                  or row.get("content_first_is_last_picture") is False)
        if not wanted or self.kept >= 160:
            return
        os.makedirs(self.keep, exist_ok=True)
        kept = {}
        for name, file in (row.get("pictures") or {}).items():
            source = os.path.join(folder, file) if file else None
            if source and os.path.exists(source):
                kept[name] = f"{row['label']}-{name}-{file}"
                shutil.copyfile(source, os.path.join(self.keep, kept[name]))
        self.kept += len(kept)
        row["kept_pictures"] = kept

    def run(self):
        opts = self.opts
        report = {"mode": "screen", "keys": opts.keys.split(","), "gaps_ms": [float(g) for g in opts.gaps.split(",") if g],
                  "runs": opts.runs, "duration_ms": opts.duration_ms, "scale": opts.scale, "tolerance": opts.tolerance,
                  "display": opts.display or "as the host has it", "display_hz_asked": opts.display_hz or None, "build": None,
                  "key_path": "debug.key's sender: the app's own key path, not the keyboard's driver",
                  "numbers": "new_surface_frames.py", "rows": self.rows, "cases": {}}
        if opts.build and os.path.exists(opts.build):
            with open(opts.build, encoding="utf-8") as handle:
                report["build"] = json.load(handle)
        report["split"], report["chromium"] = opts.split, bench_page_engine.chromium_word(self.rpc("debug.cef", None, 10))
        print(bench_page_engine.chromium_line("new-surface-screen", report["chromium"]), flush=True)
        report["session"] = self.session()
        session_fault = None if report["session"]["as_asked"] else (
            f"session: {opts.workspaces} workspaces asked, the app lists {report['session']['listed_by_the_app']}")
        for key in report["keys"]:
            for gap in report["gaps_ms"]:
                case = f"cmd-{key}/{'idle' if not gap else f'{gap:g} ms after a key'}"
                rows = []
                for run in range(opts.runs):
                    row = self.one(key, gap, run, session_fault)
                    rows.append(row)
                    self.rows.append(row)
                    said = {name: row.get(name) and [row[name]["frame"], row[name]["ms"]] for name in ("tab", "content_first", "content_final", "final")}
                    print(f"{MARK}-ROW {row['label']}: {'INVALID ' + '; '.join(row['invalid']) if row['invalid'] else 'valid'} "
                          f"{json.dumps(said)} first_is_final={row.get('first_is_final')} whole_window={row.get('whole_window')} "
                          f"changes_after_content={row.get('changes_after_content')} "
                          f"refresh_ms={row.get('refresh_ms')} capture={row.get('capture')}", flush=True)
                    if row.get("call_went_on"):
                        break
                report["cases"][case] = frames_of.summarize(rows)
                went_on = rows[-1].get("call_went_on") if rows else None
                if went_on:
                    report["cases"][case]["ended_early"] = f"after {len(rows)} of {opts.runs} rows: frame_strip answered `timeout` and the app's call went on"
                    if not went_on["ended"]:
                        report["stopped"] = (f"after {rows[-1]['label']}: the app's frame_strip call did not end in "
                                             f"{went_on['pauses']} pauses of 0.5 s: no later recording")
                early = report["cases"][case].get("ended_early")
                print(f"{MARK} {case}: {frames_of.cell(report['cases'][case])}{' (THE CASE ENDED EARLY ' + early + ')' if early else ''}", flush=True)
                if report.get("stopped"):
                    break
            if report.get("stopped"):
                print(f"{MARK} STOPPED {report['stopped']}", flush=True)
                break
        # A stopped run is not a whole run: the driver ends with this code (0: each case ran).
        report["exit_code"] = STOPPED_EXIT if report.get("stopped") else 0
        if opts.json:
            with open(opts.json, "w", encoding="utf-8") as handle:
                json.dump(report, handle, indent=1)
        if opts.screen_tgz:
            os.makedirs(self.keep, exist_ok=True)
            with open(os.path.join(self.keep, "report.json"), "w", encoding="utf-8") as handle:
                json.dump(report, handle, indent=1)
            with tarfile.open(opts.screen_tgz, "w:gz") as archive:
                archive.add(self.keep, arcname="new-surface-screen")
        print(f"{MARK} report only: {len(self.rows)} rows, {sum(1 for row in self.rows if row['invalid'])} INVALID, "
              f"{self.kept} pictures kept" + (f"; STOPPED {report['stopped']}" if report.get("stopped") else ""), flush=True)
        return report


if __name__ == "__main__":
    # The entry's cleanup, after it ended the tag's processes: `new_surface_screen.py --fresh-session TAG`.
    if len(sys.argv) != 3 or sys.argv[1] != "--fresh-session":
        sys.exit("use: new_surface_screen.py --fresh-session TAG (the mode itself: cmd-n-paint-e2e.py --screen)")
    fresh_session(sys.argv[2])
