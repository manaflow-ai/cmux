#!/usr/bin/env python3
"""Record predicted-echo scenarios as GIFs against a tagged dev build.

Run on a Mac nobody is using (it fronts the app and records the screen), after
a tagged build (`./scripts/reload.sh --tag TAG`) and `setup-slow-remote.sh`:

    record.py --tag TAG --scenario burst-backspace-paste --out DIR [--link '{"one_way_ms":75}']
    record.py --list

The dogfood tour format cannot express this: it has no way to put a remote
behind a slow link, to open a `cmux ssh` workspace, to type with controlled
gaps between keys, or to capture video. This script does those four things:

- the link: `delay_proxy.py` as the ProxyCommand of `Host pe-slow`, configured
  through link.json, which it re-reads while connected;
- the workspace: the build's own CLI runs `cmux ssh pe-slow` (a known-remote
  surface), or `workspace.create` opens a local one;
- keys: `debug.shortcut.simulate` on the tag's debug socket, paced here
  (shifted characters go through cua-driver, since simulate sends them
  unshifted);
- video: cua-driver's `start_recording`, then ffmpeg crops the app window,
  drops to 12 fps and builds a palette GIF.

Needs cua-driver (~/.local/bin/cua-driver) with Screen Recording and
Accessibility, and ffmpeg.
"""
import argparse, json, os, shutil, socket, subprocess, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from cua import Cua  # noqa: E402

LINK = os.path.expanduser(os.environ.get(
    "PE_LINK_FILE", "~/.cmux-dogfood/predictive-echo/link.json"))

# Each step: ("type", text, gap_ms) | ("key", combo) | ("keys", combo, count, gap_ms)
# | ("paste", text) | ("wait", seconds) | ("link", {...}) | ("mark", label)
SCENARIOS = {
    "underlined-then-confirmed": dict(remote=True, link={"one_way_ms": 75, "jitter_ms": 0}, steps=[
        ("type", "echo predicted and then confirmed", 140), ("wait", 1.0), ("key", "return"), ("wait", 1.0),
    ]),
    "sudo-prompt": dict(remote=True, link={"one_way_ms": 75, "jitter_ms": 0}, steps=[
        ("type", "sudo -k; sudo -v", 90), ("key", "return"), ("wait", 1.5),
        ("type", "not-a-password", 140), ("wait", 1.0), ("key", "ctrl+c"), ("wait", 1.0),
        ("type", "echo back at the prompt", 120), ("wait", 1.0), ("key", "ctrl+u"), ("wait", 1.0),
    ]),
    "full-screen-apps": dict(remote=True, link={"one_way_ms": 75, "jitter_ms": 0}, steps=[
        ("type", "vim -u NONE -N /tmp/pe-vim.txt", 80), ("key", "return"), ("wait", 2.5),
        # vim with no vimrc waits `timeoutlen` (1 s) after Escape for a key code.
        ("type", "ityped inside vim", 140), ("key", "escape"), ("wait", 1.6),
        ("type", ":q!", 120), ("key", "return"), ("wait", 1.2),
        ("type", "less /etc/services", 80), ("key", "return"), ("wait", 1.2),
        ("type", "jjjj/http", 140), ("key", "return"), ("wait", 0.8), ("type", "q", 0), ("wait", 1.0),
    ]),
    "paste-then-type": dict(remote=True, link={"one_way_ms": 75, "jitter_ms": 0}, steps=[
        ("type", "echo ", 120), ("wait", 0.8), ("paste", "PASTED-TEXT "), ("type", "typed-right-after", 40),
        ("wait", 1.5), ("key", "ctrl+u"), ("wait", 1.0),
    ]),
    "local-tab": dict(remote=False, link=None, steps=[
        ("type", "echo a local tab never predicts", 120), ("wait", 1.0), ("key", "ctrl+u"), ("wait", 0.8),
    ]),
    "jitter-and-loss": dict(remote=True, link={"one_way_ms": 75, "jitter_ms": 40, "stall_probability": 0.15, "stall_ms": 250}, steps=[
        ("type", "echo typing through a lossy link with jitter", 90), ("wait", 1.5),
        ("keys", "backspace", 12, 40), ("wait", 1.5), ("key", "ctrl+u"), ("wait", 1.0),
    ]),
    "burst-backspace-paste": dict(remote=True, link={"one_way_ms": 75, "jitter_ms": 25}, steps=[
        ("type", "echo ", 120), ("wait", 1.0),
        ("mark", "burst"), ("type", "the quick brown fox jumps over", 35),
        ("mark", "held backspace"), ("keys", "backspace", 30, 33), ("wait", 1.5),
        ("mark", "burst, paste mid-burst"), ("type", "git commit", 35), ("paste", " -m pasted"), ("type", " more typing", 35),
        ("mark", "ctrl-u"), ("key", "ctrl+u"), ("wait", 1.5),
        ("mark", "burst then ctrl-w"), ("type", "abc defghij", 35), ("key", "ctrl+w"), ("wait", 1.5),
        ("key", "ctrl+u"), ("wait", 0.8),
    ]),
}


class DebugSocket:
    def __init__(self, path):
        self.path = path
        self.connect()

    def connect(self):
        s = socket.socket(socket.AF_UNIX)
        s.connect(self.path)
        self.f = s.makefile("rwb")

    def call(self, method, params):
        self.f.write((json.dumps({"id": 1, "method": method, "params": params}) + "\n").encode())
        self.f.flush()
        return json.loads(self.f.readline() or b"null")

    def key(self, combo):
        if combo.startswith("shift+") and self.shifted:
            # simulate sends the unshifted character with a Shift flag, which
            # the terminal encodes as the unshifted character; a real key
            # event through cua-driver carries the shifted text.
            return self.shifted(combo.split("+"))
        return self.call("debug.shortcut.simulate", {"combo": combo})

    shifted = None


SHIFTED = dict(zip('~!@#$%^&*()_+{}|:"<>?', "`1234567890-=[]\\;',./"))


def key_for(ch):
    """The `debug.shortcut.simulate` combo that types `ch` on a US layout."""
    if ch in (" ", "\n"):
        return {" ": "space", "\n": "return"}[ch]
    if ch.isupper():
        return "shift+" + ch.lower()
    if ch in SHIFTED:
        return "shift+" + SHIFTED[ch]
    return ch


def paced(sock, combos, gap_ms):
    for combo in combos:
        start = time.monotonic()
        sock.key(combo)
        rest = gap_ms / 1000 - (time.monotonic() - start)
        if rest > 0:
            time.sleep(rest)


def app_window(c, tag):
    windows = json.loads(json.dumps(c.call("list_windows", {"on_screen_only": True}).get("structuredContent", {})))
    for w in windows.get("windows", []):
        if w.get("app_name", "").endswith(tag) and w.get("bounds", {}).get("height", 0) > 200:
            return w
    raise SystemExit(f"no on-screen window for tag {tag}")


def to_gif(video, gif, window, scale, fps=12, width=960):
    b = window["bounds"]
    crop = f"crop={int(b['width'] * scale)}:{int(b['height'] * scale)}:{int(b['x'] * scale)}:{int(b['y'] * scale)}"
    graph = f"{crop},fps={fps},scale={width}:-1:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4"
    ffmpeg = os.environ.get("FFMPEG") or shutil.which("ffmpeg") or os.path.expanduser("~/.local/bin/ffmpeg")
    subprocess.run([ffmpeg, "-loglevel", "error", "-y", "-i", video, "-filter_complex", graph, gif], check=True)
    return os.path.getsize(gif)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tag")
    ap.add_argument("--scenario")
    ap.add_argument("--out", default=os.path.expanduser("~/.cmux-dogfood/predictive-echo/out"))
    ap.add_argument("--link", help="JSON overriding the scenario's link settings")
    ap.add_argument("--repo", default=os.path.abspath(os.path.join(os.path.dirname(__file__), "../../..")),
                    help="cmux checkout whose scripts/cmux-debug-cli.sh drives the tag")
    ap.add_argument("--derived-data", help="the --derived-data the tag was built with, if not the default")
    ap.add_argument("--list", action="store_true")
    args = ap.parse_args()
    if args.list or not (args.tag and args.scenario):
        print("\n".join(SCENARIOS))
        return
    scenario = SCENARIOS[args.scenario]
    link = {**(scenario["link"] or {}), **json.loads(args.link or "{}")}
    if scenario["remote"]:
        with open(LINK, "w") as f:
            json.dump(link, f)

    sock_path = f"/tmp/cmux-debug-{args.tag}.sock"
    sock = DebugSocket(sock_path)
    run_dir = os.path.join(args.out, f"{args.scenario}-{args.tag}")
    os.makedirs(run_dir, exist_ok=True)
    marks = []
    with Cua() as c:
        if scenario["remote"]:
            cli = os.path.join(args.repo, "scripts/cmux-debug-cli.sh")
            subprocess.run([cli, "ssh", "pe-slow"], check=True, env={**os.environ, "CMUX_TAG": args.tag, **({"CMUX_DERIVED_DATA": args.derived_data} if args.derived_data else {})})
            time.sleep(8)  # connect, bootstrap, reach the prompt
        else:
            sock.call("workspace.create", {"title": "Local", "focus": True})
            time.sleep(2)
        # Simulated keys only reach the terminal once the window is key and the
        # surface has focus: front the app and click inside the terminal.
        window = app_window(c, args.tag)
        sock.shifted = lambda keys: c.call("hotkey", {"pid": window["pid"], "window_id": window["window_id"], "keys": keys, "delivery_mode": "foreground"})
        c.call("bring_to_front", {"pid": window["pid"], "window_id": window["window_id"]})
        b = window["bounds"]
        c.call("click", {"pid": window["pid"], "window_id": window["window_id"],
                         "x": b["width"] * 0.6, "y": b["height"] * 0.5})
        time.sleep(0.5)
        sock.connect()
        # A fresh `cmux ssh` workspace can show its first prompt blank; Ctrl-L
        # has the shell redraw it at the top.
        sock.key("ctrl+l")
        time.sleep(1.0)
        # Two echoed keys arm the prediction run; clear them before recording.
        paced(sock, [key_for(ch) for ch in "echo warm"], 150)
        sock.key("ctrl+u")
        time.sleep(1.5)
        scale = c.call("get_screen_size", {}).get("structuredContent", {}).get("scale_factor", 1) or 1
        c.call("start_recording", {"output_dir": run_dir, "record_video": True})
        t0 = time.monotonic()
        time.sleep(0.8)
        for step in scenario["steps"]:
            op = step[0]
            if op == "type":
                paced(sock, [key_for(ch) for ch in step[1]], step[2])
            elif op == "key":
                sock.key(step[1])
            elif op == "keys":
                paced(sock, [step[1]] * step[2], step[3])
            elif op == "paste":
                subprocess.run(["pbcopy"], input=step[1].encode(), check=True)
                sock.key("cmd+v")
            elif op == "wait":
                time.sleep(step[1])
            elif op == "link":
                with open(LINK, "w") as f:
                    json.dump(step[1], f)
            elif op == "mark":
                marks.append((round(time.monotonic() - t0, 3), step[1]))
        time.sleep(1.0)
        c.call("stop_recording", {})
    with open(os.path.join(run_dir, "marks.json"), "w") as f:
        json.dump({"link": link, "marks": marks}, f)
    gif = os.path.join(args.out, f"{args.scenario}-{args.tag}.gif")
    size = to_gif(os.path.join(run_dir, "recording.mp4"), gif, window, scale)
    print(f"{gif} {size / 1e6:.1f} MB")


if __name__ == "__main__":
    main()
