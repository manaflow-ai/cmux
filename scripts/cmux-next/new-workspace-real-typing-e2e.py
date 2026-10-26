#!/usr/bin/env python3
"""Real-key proof that no key typed right after an action that makes a New Tab page is lost
(cx-kql5h) on a running tagged cmux-next build: Cmd-N (New Workspace), Cmd-T from a terminal,
Cmd-D from a New Tab page (the new pane gets one) and New Tab Page from the command palette.

Lawrence's keys came 55-67 ms after Cmd-N at 25-30 keys/s and the New Tab field of the new
workspace lost the first 2-3 ("hello world 123" became "lo world 123"): nothing held them while
the daemon made the workspace and its page. Here a small compiled helper posts REAL key events at
the window server (CGEvent, HID tap), as a keyboard does: Cmd-N, then each character of the text
at --rate keys/s, the first one --delay-ms after Cmd-N. The field of the new workspace's New Tab
page must then hold the whole text (`debug.new_tab` `field`).

- cold: the app is relaunched before each Cmd-N run (its first Cmd-N).
- warm: Cmd-N, Cmd-T, split and palette runs back to back in the same app. A Cmd-T or palette run
  starts on a terminal tab (made through the socket, not measured), so a new page really opens.

Needs the logged-in GUI session and the right to post events (nx-remote --needs input). The
app launches (and relaunches, for each cold run) through bench_launch.BenchApp: the bench env, a scratch config, a
fresh saved session, an isolated launch that may activate (CMUX_NEXT_NO_ACTIVATE off, CMUX_NEXT_ISOLATED_LAUNCH on), and
the tag's teardown at the end. The helper brings the tagged app to the front itself. It never touches another app's
windows.

With --story (default none) every run's lost keys and each flow's failed runs are written as cmux-perf-result/v1
into --out (paint_typing_report.typing_series), failing runs included: the lost-key count is the measurement.

Usage: new-workspace-real-typing-e2e.py (--tag <tag> | --app BUNDLE) [--cold N] [--warm N] [--others N] [--rate 30]
       [--delay-ms 40] [--story new-workspace-typing]
Exit status 0 when every run kept every key.
"""
import argparse, json, os, re, subprocess, socket, sys, tempfile, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # the bench modules, also under `python3 -I`
import paint_typing_report as report  # noqa: E402
from bench_launch import ISOLATED_LAUNCH_KEY, BenchApp  # noqa: E402
from bench_story import story_problem  # noqa: E402

ENGINE = report.ENGINES[report.NEW_WORKSPACE_TYPING_STORY]
parser = argparse.ArgumentParser()
parser.add_argument("--tag", help="the tag of a DerivedData Debug app (with --app: the story runner passes it; the bundle carries the tag)")
parser.add_argument("--app", help="the app bundle (default: the DerivedData Debug app of --tag)")
parser.add_argument("--story", help="write the runs as cmux-perf-result/v1 under this story")
parser.add_argument("--session", choices=["light"], default="light", help="result-v1 session (the story runner's)")
parser.add_argument("--build-config", choices=["bench", "bench-checks"],
                    help="result-v1 build config of a bench-hooks bundle that does not stamp it")
parser.add_argument("--cold", type=int, default=10)
parser.add_argument("--warm", type=int, default=10)
parser.add_argument("--flow", choices=["workspace", "window"], default="workspace",
                    help="workspace: Cmd-N, Cmd-T, split and palette runs; window: Cmd-Shift-N (New Window) runs")
parser.add_argument("--others", type=int, default=10, help="warm runs of each other flow (Cmd-T, split, palette)")
parser.add_argument("--rate", type=float, default=30.0)
parser.add_argument("--delay-ms", type=int, default=40)
parser.add_argument("--text", default="hello world 123")
parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS", "/tmp"))
opts = parser.parse_args()
if not opts.app and not opts.tag:
    parser.error("name the app with --app, or the tag of a DerivedData Debug app with --tag")
if opts.story and story_problem(opts.story, ENGINE):
    parser.error(story_problem(opts.story, ENGINE))
if not opts.app:
    SLUG = re.sub(r"-+", "-", re.sub(r"[^a-z0-9]+", "-", opts.tag.lower())).strip("-")
    opts.app = os.path.expanduser(f"~/Library/Developer/Xcode/DerivedData/cmux-{SLUG}/Build/Products/Debug/cmux DEV {opts.tag}.app")
os.makedirs(opts.out, exist_ok=True)
BENCH = BenchApp(opts.app, out=opts.out, env={"CMUX_NEXT_NO_ACTIVATE": None, ISOLATED_LAUNCH_KEY: "1"},
                 perf_session=opts.session, build_config=opts.build_config)

HELPER = r'''
import AppKit
import CoreGraphics
import Foundation

// args: pid planJSON. A plan is a list of steps: {"chord": [keyCode, "cmd,shift"]}, {"key": keyCode},
// {"wait_ms": n}, {"type": text, "rate": keysPerSecond, "measure": bool}.
let args = CommandLine.arguments
let pid = pid_t(args[1])!
let plan = try! JSONSerialization.jsonObject(with: Data(args[2].utf8)) as! [[String: Any]]
let keys: [Character: (UInt16, Bool)] = {
    var map: [Character: (UInt16, Bool)] = [:]
    let plain: [(Character, UInt16)] = [("a",0),("s",1),("d",2),("f",3),("h",4),("g",5),("z",6),("x",7),("c",8),("v",9),("b",11),
        ("q",12),("w",13),("e",14),("r",15),("y",16),("t",17),("1",18),("2",19),("3",20),("4",21),("6",22),("5",23),("9",25),
        ("7",26),("8",28),("0",29),("o",31),("u",32),("i",34),("p",35),("l",37),("j",38),("k",40),("n",45),("m",46),(" ",49),
        ("-",27),("=",24),(".",47),(",",43),("/",44)]
    for (c, k) in plain { map[c] = (k, false); if c.isLetter { map[Character(c.uppercased())] = (k, true) } }
    return map
}()
func post(_ code: UInt16, _ flags: CGEventFlags) {
    let source = CGEventSource(stateID: .hidSystemState)
    for down in [true, false] {
        let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)!
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }
}
func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e6 }
guard CGPreflightPostEventAccess() || CGRequestPostEventAccess() else {
    print("{\"error\":\"no post-event access\"}"); exit(3)
}
guard let app = NSRunningApplication(processIdentifier: pid) else { print("{\"error\":\"no app\"}"); exit(4) }
app.activate()
let until = now() + 5000
while NSWorkspace.shared.frontmostApplication?.processIdentifier != pid && now() < until {
    RunLoop.current.run(until: Date().addingTimeInterval(0.02))  // harness: wait for the front app
}
guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { print("{\"error\":\"app not frontmost\"}"); exit(5) }
usleep(300_000)  // harness: the activation settles before the first key
var lastChord = now()
var first = -1.0
var measuredStart = 0.0
var measuredCount = 0
var clock = now()
for step in plan {
    if let chord = step["chord"] as? [Any], let code = chord[0] as? Int {
        var flags: CGEventFlags = []
        for name in ((chord.count > 1 ? chord[1] as? String : nil) ?? "").split(separator: ",") {
            switch name { case "cmd": flags.insert(.maskCommand); case "shift": flags.insert(.maskShift)
            case "opt": flags.insert(.maskAlternate); case "ctrl": flags.insert(.maskControl); default: break }
        }
        post(UInt16(code), flags)
        lastChord = now(); clock = lastChord
    } else if let code = step["key"] as? Int {
        post(UInt16(code), []); clock = now()
    } else if let wait = step["wait_ms"] as? Double {
        clock += wait
        while now() < clock { usleep(300) }  // harness: step pacing
    } else if let text = step["type"] as? String {
        let gap = 1000.0 / ((step["rate"] as? Double) ?? 30)
        let measure = (step["measure"] as? Bool) ?? false
        let start = clock
        for (index, character) in text.enumerated() {
            let due = start + Double(index) * gap
            while now() < due { usleep(300) }  // harness: key pacing
            if measure && index == 0 { first = now() - lastChord; measuredStart = now() }
            guard let (code, shift) = keys[character] else { continue }
            post(code, shift ? .maskShift : [])
        }
        if measure { measuredCount = text.count }
        clock = now()
    }
}
let span = now() - measuredStart
print("{\"first_key_ms\":\(first),\"keys_ms\":\(span),\"rate\":\(span > 0 ? Double(max(measuredCount - 1, 0)) / (span / 1000.0) : 0)}")
'''


def rpc(method, params=None, timeout=20):
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(timeout)
        conn.connect(BENCH.socket)
        conn.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = conn.recv(1 << 20)
            if not chunk:
                break
            buf += chunk
        conn.close()
        reply = json.loads(buf)
        return reply.get("result") if reply.get("ok") else {"error": reply.get("error")}
    except (OSError, ValueError) as error:
        return {"error": str(error)}


def wait(check, seconds, step=0.1):
    deadline = time.time() + seconds
    while time.time() < deadline:
        value = check()
        if value:
            return value
        time.sleep(step)  # test harness polling a live app
    return None


def app_pid():
    """The PID of the app BENCH started (the helper activates it and posts its keys while it is in front)."""
    return BENCH.process.pid


def relaunch():
    """A fresh app for the next runs: the running one quits first (BenchApp.stop), then BenchApp launches it again
    and returns once its socket answers with a window. TagTeardown.remember arms the teardown again for this launch
    (the last stop() ended the previous one's daemons)."""
    BENCH.stop()
    BENCH.launch(timeout=120)
    BENCH.teardown.remember()
    # The first window shows its first workspace before the first Cmd-N.
    wait(lambda: (rpc("debug.focus") or {}).get("windows"), 20)
    time.sleep(2)  # test harness: launch work settles (a cold run still has no spare page used yet)


def field_text():
    reply = rpc("debug.new_tab", {"action": "field"}) or {}
    return None if "error" in reply else reply.get("text")


CMD_N = [{"chord": [45, "cmd"]}]
CMD_SHIFT_N = [{"chord": [45, "cmd,shift"]}]
CMD_T = [{"chord": [17, "cmd"]}]
CMD_D = [{"chord": [2, "cmd"]}]
PALETTE = [{"chord": [35, "cmd,shift"]}, {"wait_ms": 400}, {"type": "new tab page", "rate": 30}, {"wait_ms": 250},
           {"key": 36}]


def plan(action):
    return action + [{"wait_ms": opts.delay_ms}, {"type": opts.text, "rate": opts.rate, "measure": True}]


def focus_terminal_tab():
    """A terminal tab in the focused pane, so the next New Tab really opens a page (not measured)."""
    print("  setup newSurface:", rpc("action.run", {"action": "newSurface", "args": {}, "focus": True}), flush=True)
    made = wait(lambda: field_text() is None, 5)
    time.sleep(1)  # test harness: the terminal takes the keyboard
    return made is not None


def focused_tab():
    windows = (rpc("debug.focus") or {}).get("windows") or []
    return ((windows[0].get("model") or {}).get("resolved_tab")) if windows else None


def fresh_page_workspace():
    """A new workspace on its New Tab page, so Cmd-D splits a page into a new pane (not measured)."""
    # A person's Cmd-N (the app's own key dispatch): a socket newTab would make a terminal workspace.
    before = focused_tab()
    print("  setup Cmd-N:", rpc("debug.key", {"key": "n", "modifiers": ["command"]}), flush=True)
    made = wait(lambda: focused_tab() not in (None, before) and field_text() == "", 8)
    time.sleep(1)  # test harness: the page settles
    return made is not None


def window_tabs():
    """Each window's focused tab, in window order (debug.focus and debug.new_tab share it)."""
    return [((w.get("model") or {}).get("resolved_tab")) for w in (rpc("debug.focus") or {}).get("windows") or []]


def new_window_field(before):
    """The field text of a window whose focused tab is new since `before`, or None."""
    for index, tab in enumerate(window_tabs()):
        if tab and tab not in before:
            reply = rpc("debug.new_tab", {"action": "field", "window": index}) or {}
            if "error" not in reply and reply.get("text") is not None:
                return reply.get("text")
    return None


def run_window(name, helper):
    """Cmd-Shift-N, then the text: it must land whole in the NEW window's New Tab field."""
    pid = app_pid()
    before = set(filter(None, window_tabs()))
    count = len(window_tabs())
    result = subprocess.run([helper, str(pid), json.dumps(plan(CMD_SHIFT_N))], capture_output=True, text=True, timeout=60)
    try:
        timing = json.loads(result.stdout.strip().splitlines()[-1])
    except (ValueError, IndexError):
        timing = {"error": (result.stdout + result.stderr)[-300:]}
    got = wait(lambda: (lambda t: t if t == opts.text else None)(new_window_field(before)), 8)
    text = got if got is not None else new_window_field(before)
    focus = rpc("debug.focus") or {}
    ok = got is not None and len(window_tabs()) > count and "error" not in timing and drained(focus)
    if not ok:
        print("  hold log:", json.dumps((focus.get("new_tab_key_log") or [])[-20:]), flush=True)
    row = {"run": name, "field": text, "pass": ok, "drained": drained(focus), "windows_before": count, "windows_after": len(window_tabs()),
           "holds_after": focus.get("new_tab_key_holds"), **timing}
    print(("PASS" if ok else "FAIL"), json.dumps(row), flush=True)
    return row


def panes():
    windows = (rpc("debug.focus") or {}).get("windows") or []
    return len(windows[0].get("topology") or []) if windows else 0


def drained(focus):
    """The run's hold ended by the field's readiness (not the limit or a fallback release)."""
    ends = [e for e in focus.get("new_tab_key_log") or [] if e.startswith("drained") or e.startswith("release:")]
    return bool(ends) and ends[-1].startswith("drained")


def run(name, helper, steps, setup=None, new_pane=False):
    if setup and not setup():
        row = {"run": name, "pass": False, "error": "setup failed"}
        print("FAIL", json.dumps(row), flush=True)
        return row
    pid = app_pid()
    panes_before = panes()
    # The field read after must be a NEW page's: the tab focused before (maybe the last run's page,
    # holding the same text) does not count.
    before = focused_tab()
    result = subprocess.run([helper, str(pid), json.dumps(plan(steps))], capture_output=True, text=True, timeout=60)
    timing = {}
    try:
        timing = json.loads(result.stdout.strip().splitlines()[-1])
    except (ValueError, IndexError):
        timing = {"error": (result.stdout + result.stderr)[-300:]}
    got = wait(lambda: (lambda t: t if t == opts.text and focused_tab() not in (None, before) else None)(field_text()), 6)
    after = focused_tab()
    # No new focused tab: the keys reached no new page, whatever the old page's field holds.
    text = got if got is not None else (field_text() if after not in (None, before) else None)
    focus = rpc("debug.focus") or {}
    holds = focus.get("new_tab_key_holds")
    ok = got is not None and "error" not in timing and drained(focus) and (not new_pane or panes() == panes_before + 1)
    if not ok:
        print("  hold log:", json.dumps((focus.get("new_tab_key_log") or [])[-20:]), flush=True)
    row = {"run": name, "field": text, "pass": ok, "tab_before": before, "tab_after": after, "drained": drained(focus),
           "new_pane": new_pane, "panes": [panes_before, panes()], "holds_after": holds, **timing}
    print(("PASS" if ok else "FAIL"), json.dumps(row), flush=True)
    return row


def measure(helper):
    """Every run of the flows asked for; returns their rows."""
    rows = []
    if opts.flow == "window":
        for index in range(opts.cold):
            relaunch()
            rows.append(run_window(f"cold-newwin-{index + 1}", helper))
        if opts.warm and not opts.cold:
            relaunch()
        for index in range(opts.warm):
            time.sleep(1)  # test harness: the previous window settles
            rows.append(run_window(f"warm-newwin-{index + 1}", helper))
    for index in range(opts.cold if opts.flow == "workspace" else 0):
        relaunch()
        rows.append(run(f"cold-cmdn-{index + 1}", helper, CMD_N))
    if opts.flow == "workspace" and (opts.warm or opts.others):
        if not opts.cold:
            relaunch()
        for index in range(opts.warm):
            time.sleep(1)  # test harness: the previous workspace settles
            rows.append(run(f"warm-cmdn-{index + 1}", helper, CMD_N))
        for index in range(opts.others):
            rows.append(run(f"warm-cmdt-{index + 1}", helper, CMD_T, setup=focus_terminal_tab))
            # Cmd-D on a fresh New Tab page: the new pane opens its own New Tab page.
            rows.append(run(f"warm-split-{index + 1}", helper, CMD_D, setup=fresh_page_workspace, new_pane=True))
            rows.append(run(f"warm-palette-{index + 1}", helper, PALETTE, setup=focus_terminal_tab))
    return rows


def main():
    helper_dir = tempfile.mkdtemp(prefix="realkeys-")
    source, helper = os.path.join(helper_dir, "keys.swift"), os.path.join(helper_dir, "keys")
    with open(source, "w") as handle:
        handle.write(HELPER)
    subprocess.run(["xcrun", "swiftc", "-O", source, "-o", helper], check=True)
    try:
        rows = measure(helper)
    finally:
        BENCH.stop()
    with open(os.path.join(opts.out, "new-workspace-real-typing.json"), "w") as handle:
        json.dump(rows, handle, indent=1)
    passed = sum(1 for row in rows if row["pass"])
    recorded = True
    if opts.story and rows:
        recorded = report.any_written(report.record_all(BENCH, opts.story, ENGINE, report.typing_series(rows, opts.text)))
        if not recorded:
            print(f"FAIL no result-v1 written for --story {opts.story}", flush=True)
    print(f"\nRESULT {'PASS' if rows and passed == len(rows) else 'FAIL'} ({passed}/{len(rows)})")
    sys.exit(0 if rows and passed == len(rows) and recorded else 1)


if __name__ == "__main__":
    main()
