"""Parity rig driver (feat-cnx-ios-parity): the iOS app in ONE headless simulator on
this laptop, the real tagged cmux-next Mac app on a cmux Mac mini (rmac.py there).
Every flow goes phone app -> real link -> cnx-hostd -> the Mac's daemon and acpmux.
The Mac side is read only to check what the phone did (its bundled CLI over ssh).

    python3 -c 'import pq; pq.setup()'          # simulator, install, sign in, pick the rig Mac
    python3 -c 'import pq; pq.run("browser")'   # one creation flow, recorded

State: ~/cnx-ios-e2e/parity-state.json. Videos: ~/cnx-ios-e2e/parity-raw/<flow>.mp4.
"""
import json
import os
import shlex
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "../e2e"))
os.environ.setdefault("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")
from sim import Sim  # noqa: E402
import journey as journey_mod  # noqa: E402
from journey import Journey, Fail, check  # noqa: E402

STATE = os.path.expanduser("~/cnx-ios-e2e/parity-state.json")
RAW = os.path.expanduser("~/cnx-ios-e2e/parity-raw")
ART = os.path.join(HERE, "artifacts")
HOST = os.environ.get("PQ_HOST", "mini-cmux11s-mac-mini")
RBASE = "~/cnx-ios-e2e/parity"
BUNDLE = journey_mod.BUNDLE
SIM_NAME = "cnx-parity-1"
DEVICE = "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"
RUNTIME = "com.apple.CoreSimulator.SimRuntime.iOS-26-5"


def load():
    return json.load(open(STATE)) if os.path.exists(STATE) else {}


def save(st):
    os.makedirs(os.path.dirname(STATE), exist_ok=True)
    json.dump(st, open(STATE, "w"), indent=2)


def log(msg):
    print(f"{time.strftime('%H:%M:%S')} {msg}", flush=True)


def rsh(cmd, timeout=180):
    return subprocess.run(["ssh", "-o", "ConnectTimeout=10", "-o", "BatchMode=yes", HOST, cmd],
                          capture_output=True, text=True, timeout=timeout)


class RemoteMac:
    """The Mac half on HOST, with the surface Journey uses."""

    def __init__(self):
        self.pid = None
        self._name = None

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
                return [json.loads(line) for line in out.splitlines() if line.strip()]
        return r

    def computer_name(self):
        if not self._name:
            self._name = self._rmac("name").stdout.strip()
        return self._name

    def device_id(self):
        return self._rmac("device-id").stdout.strip() or None

    def link_events(self, since):
        return []


def ctx():
    st = load()
    sim = Sim(st["udid"], os.path.join(ART, "shots"))
    mac = RemoteMac()
    j = Journey(sim, mac, ART, st.get("app_path"), log)
    j.device_id = st.get("device_id")
    j.ws_name = st.get("ws_name", j.ws_name)
    return sim, mac, j


def setup(app_path=os.path.expanduser("~/cnx-ios-e2e/parity/CnxApp.app")):
    """One simulator (named in the rig Mac's pairing seed), the app, sign-in, the rig Mac."""
    st = load()
    lst = json.loads(subprocess.run(["xcrun", "simctl", "list", "devices", "-j"], capture_output=True, text=True).stdout)
    udid = next((d["udid"] for devs in lst["devices"].values() for d in devs if d["name"] == SIM_NAME), None)
    if not udid:
        udid = subprocess.run(["xcrun", "simctl", "create", SIM_NAME, DEVICE, RUNTIME], capture_output=True, text=True).stdout.strip()
    subprocess.run(["xcrun", "simctl", "boot", udid], capture_output=True)
    subprocess.run(["xcrun", "simctl", "bootstatus", udid, "-b"], capture_output=True, timeout=600)
    mac = RemoteMac()
    st.update(udid=udid, app_path=app_path, device_id=mac.device_id(), mac_name=mac.computer_name(),
              ws_name=f"parity-{time.strftime('%H%M%S')}")
    save(st)
    sim, mac, j = ctx()
    # A workspace in a project folder, so the phone has a folder to start agent chats in.
    proj = "~/cnx-ios-e2e/parity/proj"
    rsh(f"mkdir -p {proj} && printf '# parity\\n' > {proj}/README.md")
    created = mac.cmux("workspace", "create", "--name", st["ws_name"], "--cwd",
                       rsh(f"cd {proj} && pwd").stdout.strip(), json_out=True)
    log(f"seed workspace: {created}")
    for sid, fn in (("fresh_install", j.s_fresh_install), ("sign_in", j.s_sign_in), ("choose_space", j.s_choose_space)):
        j.step(sid, sid, "parity", fn)
    j.step("pick_mac", "the rig Mac", "parity", lambda: pick_mac(j))
    return j.results


def pick_mac(j):
    j.tab("Workspaces")
    if j.sim.wait(ident="workspaces.filter", timeout=8):
        j.choose_mac()
    t = time.time()
    while time.time() - t < 45:
        if j.sim.find(prefix=load()["ws_name"], kind="Button"):
            return f"rig Mac rows in {time.time() - t:.1f} s"
        time.sleep(0.5)
    raise Fail("the rig Mac's seed workspace never listed")


# ---------------------------------------------------------------- recording

def rec_start(name):
    st = load()
    os.makedirs(RAW, exist_ok=True)
    path = os.path.join(RAW, f"{name}.mp4")
    subprocess.run(["pkill", "-INT", "-f", f"io {st['udid']} recordVideo"], capture_output=True)
    p = subprocess.Popen(["xcrun", "simctl", "io", st["udid"], "recordVideo", "--codec", "h264", "--force", path],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    st["rec"] = {"pid": p.pid, "path": path}
    save(st)
    time.sleep(1.5)
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


# ---------------------------------------------------------------- flows

def open_workspace(j):
    j.back_to_list()
    row = j.sim.wait(prefix=load()["ws_name"], kind="Button", timeout=30)
    check(row, "seed workspace not on the phone")
    j.sim.tap_el(row)
    time.sleep(2.5)


def open_grid(j):
    """The tab grid (Safari's tab button: the bottom-right toolbar control)."""
    for ident in ("tabs.toolbar.tabs", "tabsKit.tabs"):
        e = j.sim.find(ident=ident)
        if e:
            j.sim.tap_el(e[0]); time.sleep(1.2)
            return
    e = [x for x in j.sim.find(kind="Button") if (x.label or "") in ("Tabs", "Show Tabs", "Tab Overview")]
    check(e, "no tab grid button")
    j.sim.tap_el(e[0]); time.sleep(1.2)


def new_tab(j, title):
    """Grid (+) then the menu row titled `title`."""
    open_grid(j)
    plus = [x for x in j.sim.find(kind="Button") if (x.label or "") in ("New Tab", "Add", "New tab")] or \
        j.sim.find(ident="tabsKit.newTab")
    check(plus, "no (+) in the grid")
    j.sim.tap_el(plus[0]); time.sleep(1.0)
    item = j.sim.wait(label=title, timeout=6)
    check(item, f"no {title!r} in the new-tab menu; menu: {[x.label for x in j.sim.find(kind='Button')][:12]}")
    return j.sim.tap_el(item)


def mac_tabs():
    """Every tab on the rig Mac (the CLI's `tab list`)."""
    out = RemoteMac().cmux("tab", "list", json_out=True)
    return out if isinstance(out, list) else (out or {}).get("tabs", out)


def shot(name):
    """A small JPEG of the simulator screen (for reading)."""
    st = load()
    os.makedirs(os.path.join(ART, "shots"), exist_ok=True)
    raw = f"/tmp/parity-{name}.png"
    subprocess.run(["xcrun", "simctl", "io", st["udid"], "screenshot", raw], capture_output=True)
    out = os.path.join(ART, "shots", f"{name}.jpg")
    subprocess.run(["sips", "-Z", "874", "-s", "format", "jpeg", "-s", "formatOptions", "70", raw, "--out", out],
                   capture_output=True)
    return out


def ax(contains=None, ident=None, label=None, kind=None):
    s, _, _ = ctx()
    for e in s.find(contains=contains, ident=ident, label=label, kind=kind):
        print(repr(e))
