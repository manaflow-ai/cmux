"""Terminal QA driver (feat-cnx-ios-termqa): the iOS app in a headless simulator on
this laptop, the real tagged cmux-next Mac app on ANOTHER machine (a cmux Mac mini).
Every scenario goes phone app -> real link (WebRTC / WireGuard, direct or relay) ->
cnx-hostd -> daemon. The Mac side is driven only to start programs and to read its
screen for comparison (its bundled CLI over ssh on the mini, never from the phone).

    python3 -c 'from tq import *; ...'

State: ~/cnx-ios-e2e/termqa-state.json (udid, remote host, app path).
"""
import json
import os
import shlex
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "../e2e"))
from sim import Sim  # noqa: E402
from journey import Journey  # noqa: E402

STATE = os.path.expanduser("~/cnx-ios-e2e/termqa-state.json")
ART = os.path.join(HERE, "artifacts")
RAW = os.path.expanduser("~/cnx-ios-e2e/termqa-raw")
HOST = os.environ.get("TQ_HOST", "mini-cmuxs-mac-mini-2")
RBASE = "~/cnx-ios-e2e/termqa"
BUNDLE = "dev.cmux.cnx.cnx"


def load():
    return json.load(open(STATE)) if os.path.exists(STATE) else {}


def save(st):
    os.makedirs(os.path.dirname(STATE), exist_ok=True)
    json.dump(st, open(STATE, "w"), indent=2)


def log(msg):
    print(f"{time.strftime('%H:%M:%S')} {msg}", flush=True)


def rsh(cmd, timeout=180, check=False):
    r = subprocess.run(["ssh", "-o", "ConnectTimeout=10", HOST, cmd], capture_output=True, text=True, timeout=timeout)
    if check and r.returncode:
        raise RuntimeError(f"{HOST}: {cmd[:120]}: {(r.stderr or r.stdout)[-400:]}")
    return r


class RemoteMac:
    """The Mac half, on HOST. Same surface the rig's Journey uses."""

    def __init__(self):
        self.pid = None
        self._name = None
        self.tag = "cnx-e2e-604fc689"

    def _rmac(self, *args, timeout=180):
        return rsh(f"cd {RBASE} && python3 rmac.py " + " ".join(shlex.quote(a) for a in args), timeout=timeout)

    def cmux(self, *args, check=True, timeout=60, json_out=False):
        a = (["--json"] if json_out else []) + list(args)
        r = self._rmac("cli", *a, timeout=timeout + 20)
        if check and r.returncode != 0:
            raise RuntimeError(f"cmux {' '.join(args)}: {(r.stderr or r.stdout).strip()[:400]}")
        if json_out and r.returncode == 0:
            out = r.stdout.strip()
            try:
                return json.loads(out) if out else None
            except ValueError:
                return [json.loads(l) for l in out.splitlines() if l.strip()]
        return r

    def launch(self):
        d = json.loads(self._rmac("launch", timeout=300).stdout)
        self.pid = d["pid"]
        return time.time()

    def wait_hostd(self, timeout=120):
        return bool(json.loads(self._rmac("hostd").stdout)["hostd"])

    def quit(self):
        return json.loads(self._rmac("quit").stdout)["quit"]

    def computer_name(self):
        if not self._name:
            self._name = self._rmac("name").stdout.strip()
        return self._name

    def device_id(self):
        return self._rmac("device-id").stdout.strip() or None

    def link_events(self, since):
        # The mini's clock is NTP-synced like this one; good to ~0.1 s.
        return [tuple(x) for x in json.loads(self._rmac("link-events", str(since)).stdout or "[]")]


def ctx():
    st = load()
    sim = Sim(st["udid"], os.path.join(ART, "shots"))
    mac = RemoteMac()
    j = Journey(sim, mac, ART, st.get("app_path"), log)
    j.seed = st.get("seed", {})
    j.ws_name = st.get("ws_name", j.ws_name)
    return sim, mac, j


def shot(name):
    s = Sim(load()["udid"])
    os.makedirs(os.path.join(ART, "shots"), exist_ok=True)
    raw = f"/tmp/termqa-{name}.png"
    subprocess.run(["xcrun", "simctl", "io", s.udid, "screenshot", raw], capture_output=True)
    out = os.path.join(ART, "shots", f"{name}.jpg")
    subprocess.run(["sips", "-Z", "874", "-s", "format", "jpeg", "-s", "formatOptions", "70", raw, "--out", out],
                   capture_output=True)
    return out


def ocr_dump(min_y=0, max_y=900):
    s = Sim(load()["udid"])
    for x, y, w, h, t in s.ocr():
        if min_y <= y <= max_y:
            print(f"{x:5.0f} {y:5.0f} {w:4.0f} {h:3.0f}  {t}")


def ax(contains=None, ident=None, label=None):
    s = Sim(load()["udid"])
    for e in s.find(contains=contains, ident=ident, label=label):
        print(repr(e))


def term():
    return load()["term"]


def mac_screen(t=None):
    return RemoteMac().cmux("terminal", t or term(), "screen", "read", json_out=True).get("text", "")


def mac_write(text, t=None):
    RemoteMac().cmux("terminal", t or term(), "write", "--text", text)


def rec_start(name):
    st = load()
    os.makedirs(RAW, exist_ok=True)
    path = os.path.join(RAW, f"{name}.mp4")
    p = subprocess.Popen(["xcrun", "simctl", "io", st["udid"], "recordVideo", "--codec", "h264", "--force", path],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    st["rec"] = {"pid": p.pid, "path": path, "t0": time.time()}
    save(st)
    time.sleep(1.0)
    return path


def rec_stop():
    import signal
    st = load()
    r = st.pop("rec", None)
    save(st)
    if not r:
        return None
    try:
        os.kill(r["pid"], signal.SIGINT)
    except ProcessLookupError:
        return r["path"]
    for _ in range(60):
        try:
            os.kill(r["pid"], 0)
            time.sleep(0.25)
        except ProcessLookupError:
            break
    return r["path"]


def sheet(name, fps=4, cols=8, start=None, dur=None, width=200, crop=None):
    """Contact sheet of a recording (verify-ui-video style) into artifacts/sheets."""
    src = os.path.join(RAW, f"{name}.mp4")
    os.makedirs(os.path.join(ART, "sheets"), exist_ok=True)
    out = os.path.join(ART, "sheets", f"{name}-%02d.jpg")
    vf = (f"crop={crop}," if crop else "") + f"fps={fps},scale={width}:-1,tile={cols}x4"
    cmd = ["ffmpeg", "-v", "error", "-y"] + (["-ss", str(start)] if start is not None else []) + \
          (["-t", str(dur)] if dur else []) + ["-i", src, "-vf", vf, out]
    subprocess.run(cmd, check=True)
    return sorted(p for p in os.listdir(os.path.join(ART, "sheets")) if p.startswith(name))


def frames(name, fps=10, start=None, dur=None, width=402):
    src = os.path.join(RAW, f"{name}.mp4")
    d = os.path.join(RAW, "frames", name)
    os.makedirs(d, exist_ok=True)
    cmd = ["ffmpeg", "-v", "error", "-y"] + (["-ss", str(start)] if start is not None else []) + \
          (["-t", str(dur)] if dur else []) + ["-i", src, "-vf", f"fps={fps},scale={width}:-1", os.path.join(d, "f%04d.png")]
    subprocess.run(cmd, check=True)
    return d


def load_avg():
    return float(subprocess.run(["sysctl", "-n", "vm.loadavg"], capture_output=True, text=True).stdout.split()[1])
