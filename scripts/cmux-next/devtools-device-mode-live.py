#!/usr/bin/env python3
"""Live check: DevTools device mode in a Chromium tab, side by side with Google Chrome; cmux device
emulation timing; Widevine status.

  nx-remote --needs gui --app-from-fleet cmux --tag <tag> --ref <sha> -- \
      'python3 -I scripts/cmux-next/devtools-device-mode-live.py [--widevine] [--no-chrome]'

Both browsers are driven the same way, through the real DevTools frontend: CDP to the
devtools:// frontend target runs the frontend's own models (DeviceModeModel, EmulatedDevicesList,
CPUThrottlingManager, MultitargetNetworkManager, the target's Emulation agent), so the page gets
exactly the calls the device toolbar makes, and CDP to the page reads what the page sees
(innerWidth/innerHeight, devicePixelRatio, screen, matchMedia pointer/hover/orientation/
prefers-*, touch, UA and UA client hints in JS and in request headers, geolocation, timing).
Chrome is the reference: a check passes when cmux gives Chrome's value. The cmux tab gets a
remote-debugging port through CMUX_NEXT_CEF_EXTRA_SWITCHES (debug dev bundles only).

Checks that fail for a known reason are in KNOWN_GAPS with their bead: they are reported, not
failed. A known gap that passes fails the run, so the fix removes it from the list in the same push.

  E1/E2  `tab emulate --device` and `tab emulate clear` reach the page within 2 s, and no
         "device emulation ... failed" line is logged (a synchronous DevTools answer was lost
         and every emulation change waited 5 s on Emulation.setEmitTouchEventsForMouse).
  D*     DevTools device mode: presets, rotate, responsive size, zoom, media features,
         geolocation, CPU and network throttling, the screenshot buttons, the toolbar.
  T*     agent clicks (browser host REPL, CDP Input) on a link and a button with device mode's iPhone
         preset on (it turns touch on; Chromium then never answers mouse input, cx-3ny35) and after it ends.
  F*     cmux's "Fit as 16:9" and DevTools device mode on the same tab.
  --widevine: EME for com.widevine.alpha, codec support, Shaka playback of two Widevine test
         streams (report only; --require-widevine makes them checks).

Writes results.json, window snapshots and the pages' screenshots to $NX_ARTIFACTS (or --out).
Ends with debug.quit and $NX_APP_STOP; quits the Chrome it started. Exits 1 when a check fails.
"""
import argparse, base64, hashlib, http.server, json, os, random, socket, struct, subprocess, sys, tempfile, threading, time, urllib.request

parser = argparse.ArgumentParser()
parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS") or tempfile.mkdtemp(prefix="devtools-device-mode-"))
parser.add_argument("--app", default=os.environ.get("NX_APP"))
parser.add_argument("--chrome", default="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
parser.add_argument("--no-chrome", action="store_true", help="cmux only; the D* checks are skipped")
parser.add_argument("--widevine", action="store_true")
parser.add_argument("--require-widevine", action="store_true")
opts = parser.parse_args()
os.makedirs(opts.out, exist_ok=True)
SOCKET = os.environ.get("NX_APP_SOCKET")
if not opts.app or not SOCKET:
    sys.exit("run inside nx-remote --app-from-fleet (NX_APP, NX_APP_SOCKET)")
RUN = "dm%05d" % random.randint(0, 99999)
LOG = open(os.path.join(opts.out, "transcript.jsonl"), "w")
RESULTS = {"run": RUN, "checks": []}

# Known gaps: check id -> bead. Remove a line in the same push as its fix.
KNOWN_GAPS = {
    # None. cx-fhcve (device-mode toolbar, responsive, zoom, fit scale, the fit and DevTools
    # device mode on one tab) was fixed by fork API 24 (cef-154.0.28-cmux.28).
    # The page is 1-2 CSS px shorter than Chrome's in rotate, responsive and zoom (frame exact).
    "D_rotate_page": "cx-22w3i",
    "D_responsive_page": "cx-22w3i",
    "D_zoom_page": "cx-22w3i",
}


def log(**entry):
    LOG.write(json.dumps(entry, default=str)[:60000] + "\n"); LOG.flush()


def check(cid, ok, **detail):
    gap = KNOWN_GAPS.get(cid)
    status = "pass" if ok else ("known-gap" if gap else "fail")
    if ok and gap:
        status = "fail"; detail["note"] = "passes now: remove %s (%s) from KNOWN_GAPS" % (cid, gap)
    RESULTS["checks"].append(dict(id=cid, status=status, bead=gap, **detail))
    print("%-10s %s %s" % (status, cid, json.dumps(detail, default=str)[:400]), flush=True)


def wait_for(fn, seconds, step=0.25):
    end = time.time() + seconds; value = fn()
    while not value and time.time() < end:
        time.sleep(step)  # test harness: bounded poll of another process
        value = fn()
    return value


# ------------------------------------------------------------------ websocket + CDP (stdlib only)
class CDP:
    def __init__(self, url, name):
        host, _, rest = url[len("ws://"):].partition("/"); h, _, p = host.partition(":")
        self.s = socket.create_connection((h, int(p)), timeout=30); self.name = name
        key = base64.b64encode(os.urandom(16)).decode()
        self.s.sendall(("GET /%s HTTP/1.1\r\nHost: %s\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                        "Sec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n\r\n" % (rest, host, key)).encode())
        buf = b""
        while b"\r\n\r\n" not in buf:
            buf += self.s.recv(4096)
        head, _, self.rest = buf.partition(b"\r\n\r\n")
        if b" 101 " not in head.split(b"\r\n")[0]:
            raise RuntimeError("websocket handshake failed: %r" % head[:120])
        self.s.settimeout(None); self.lock = threading.Lock(); self.cv = threading.Condition(); self.n = 0; self.replies = {}
        threading.Thread(target=self._loop, daemon=True).start()

    def _read(self, n):
        while len(self.rest) < n:
            chunk = self.s.recv(1 << 20)
            if not chunk:
                raise EOFError
            self.rest += chunk
        out, self.rest = self.rest[:n], self.rest[n:]
        return out

    def _loop(self):
        try:
            msg = b""
            while True:
                b0, b1 = self._read(2); n = b1 & 0x7F
                n = struct.unpack(">H", self._read(2))[0] if n == 126 else struct.unpack(">Q", self._read(8))[0] if n == 127 else n
                data = self._read(n); op = b0 & 0x0F
                if op == 8:
                    return
                if op in (0, 1):
                    msg += data
                    if b0 & 0x80:
                        m = json.loads(msg.decode("utf-8", "replace")); msg = b""
                        if "id" in m:
                            with self.cv:
                                self.replies[m["id"]] = m; self.cv.notify_all()
        except (OSError, EOFError, ValueError) as error:
            log(cdp_closed=self.name, error=str(error))

    def call(self, method, params=None, session=None, timeout=30):
        with self.cv:
            self.n += 1; i = self.n
        msg = {"id": i, "method": method, "params": params or {}}
        if session:
            msg["sessionId"] = session
        data = json.dumps(msg).encode(); mask = os.urandom(4); n = len(data)
        head = bytes([0x81]) + (bytes([0x80 | n]) if n < 126 else bytes([0x80 | 126]) + struct.pack(">H", n) if n < 65536 else bytes([0x80 | 127]) + struct.pack(">Q", n))
        with self.lock:
            self.s.sendall(head + mask + bytes(b ^ mask[k % 4] for k, b in enumerate(data)))
        with self.cv:
            if not self.cv.wait_for(lambda: i in self.replies, timeout):
                log(cdp=self.name, method=method, timeout=timeout); return {"error": {"message": "timeout"}}
            return self.replies.pop(i)

    def eval(self, expr, session, timeout=30):
        r = self.call("Runtime.evaluate", {"expression": expr, "awaitPromise": True, "returnByValue": True, "userGesture": True}, session, timeout)
        res = r.get("result", {})
        if "exceptionDetails" in res or "error" in r:
            log(cdp=self.name, eval_error=res.get("exceptionDetails") or r.get("error"), expr=expr[:200]); return None
        return res.get("result", {}).get("value")


class Browser:
    def __init__(self, name, port):
        with urllib.request.urlopen("http://127.0.0.1:%d/json/version" % port, timeout=5) as r:
            v = json.loads(r.read())
        self.name, self.version, self.cdp = name, v.get("Browser"), CDP(v["webSocketDebuggerUrl"], name)

    def attach(self, pred, seconds=30):
        def find():
            return next((t for t in self.cdp.call("Target.getTargets").get("result", {}).get("targetInfos", []) if pred(t)), None)
        target = wait_for(find, seconds, 0.5)
        if not target:
            return None
        return self.cdp.call("Target.attachToTarget", {"targetId": target["targetId"], "flatten": True}).get("result", {}).get("sessionId")


def port_up(port):
    try:
        with urllib.request.urlopen("http://127.0.0.1:%d/json/version" % port, timeout=2):
            return True
    except OSError:
        return False


# ------------------------------------------------------------------ pages
PROBE = """<!doctype html><html><head><meta charset=utf-8><meta name=viewport content="width=device-width, initial-scale=1">
<title>device mode probe</title><style>body{margin:0;font:16px -apple-system,Helvetica;background:#fff;color:#111}
#hdr{height:56px;background:#1b6ef3;color:#fff;display:flex;align-items:center;padding:0 16px;font-weight:600}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(160px,1fr));gap:12px;padding:12px}
.card{height:120px;border-radius:10px;background:linear-gradient(135deg,#ffd166,#ef476f)}
@media (max-width:600px){.card{background:linear-gradient(135deg,#06d6a0,#118ab2)}}
@media (prefers-color-scheme:dark){body{background:#111;color:#eee}}</style></head>
<body><div id=hdr>cmux device mode probe</div><div class=grid>""" + "<div class=card></div>" * 12 + """</div><script>
async function probe(){const mm=q=>matchMedia(q).matches;let he=null,hdr=null;
 try{he=navigator.userAgentData?await navigator.userAgentData.getHighEntropyValues(['model','platform']):null}catch(e){}
 try{hdr=await (await fetch('/headers?'+Math.random())).json()}catch(e){}
 return {w:innerWidth,h:innerHeight,dpr:devicePixelRatio,sw:screen.width,sh:screen.height,orient:screen.orientation&&screen.orientation.type,
  ua:navigator.userAgent,mobile:navigator.userAgentData?navigator.userAgentData.mobile:null,model:he&&he.model,platform:he&&he.platform,
  hdrPlatform:hdr&&hdr['sec-ch-ua-platform'],hdrMobile:hdr&&hdr['sec-ch-ua-mobile'],hdrModel:hdr&&hdr['sec-ch-ua-model'],
  touch:navigator.maxTouchPoints,coarse:mm('(pointer:coarse)'),hoverNone:mm('(hover:none)'),dark:mm('(prefers-color-scheme:dark)'),
  reducedMotion:mm('(prefers-reduced-motion:reduce)'),portrait:mm('(orientation:portrait)'),narrow:mm('(max-width:600px)')}}
</script></body></html>"""
SHAKA = """<!doctype html><meta charset=utf-8><title>widevine status</title>
<script src="https://cdn.jsdelivr.net/npm/shaka-player@4.11.7/dist/shaka-player.compiled.js"></script>
<video id=v muted autoplay playsinline width=640 height=360 style="background:#000"></video><pre id=o></pre><script>
window.__s={state:'init',errors:[]};
(async()=>{const v=document.getElementById('v');shaka.polyfill.installAll();if(!shaka.Player.isBrowserSupported()){__s.state='unsupported';return}
 const p=new shaka.Player();await p.attach(v);p.configure({drm:{servers:{'com.widevine.alpha':'https://cwip-shaka-proxy.appspot.com/no_auth'}},preferredVideoCodecs:(new URLSearchParams(location.search).get('codec')||'').split(',').filter(Boolean)});
 p.addEventListener('error',e=>__s.errors.push(e.detail.code));
 try{await p.load(new URLSearchParams(location.search).get('mpd'));__s.state='loaded';const t=p.getVariantTracks().find(t=>t.active);
  __s.variant=t&&{v:t.videoCodec,a:t.audioCodec,h:t.height};__s.keySystem=p.keySystem();await v.play().catch(e=>__s.errors.push(String(e)))}
 catch(e){__s.state='load-failed';__s.errors.push(e.code)}})();
function status(){const v=document.getElementById('v');const q=v.getVideoPlaybackQuality();return Object.assign({},__s,{t:v.currentTime,frames:q.totalVideoFrames})}
setInterval(()=>{document.getElementById('o').textContent=JSON.stringify(status(),null,1)},500);</script>"""
MP4 = """<!doctype html><meta charset=utf-8><title>h264 aac</title>
<video id=v autoplay muted playsinline width=640 src="https://download.samplelib.com/mp4/sample-5s.mp4"></video><script>
let err=null;document.getElementById('v').addEventListener('error',e=>{const m=e.target.error;err=m?m.code+' '+m.message:'error'});
function mp4(){const v=document.getElementById('v');return {t:v.currentTime,vw:v.videoWidth,frames:v.getVideoPlaybackQuality().totalVideoFrames,
 audioBytes:v.webkitAudioDecodedByteCount,canPlay:v.canPlayType('video/mp4; codecs="avc1.42E01E, mp4a.40.2"'),error:err}}</script>"""
WV_JS = r"""(async()=>{const out={};const cfgs={
 'mp4-avc1-aac':[{initDataTypes:['cenc'],videoCapabilities:[{contentType:'video/mp4; codecs="avc1.42E01E"',robustness:'SW_SECURE_CRYPTO'}],audioCapabilities:[{contentType:'audio/mp4; codecs="mp4a.40.2"',robustness:'SW_SECURE_CRYPTO'}]}],
 'webm-vp9-opus':[{initDataTypes:['webm','cenc'],videoCapabilities:[{contentType:'video/webm; codecs="vp9"',robustness:'SW_SECURE_CRYPTO'}],audioCapabilities:[{contentType:'audio/webm; codecs="opus"',robustness:'SW_SECURE_CRYPTO'}]}]};
for(const [k,c] of Object.entries(cfgs)){try{const a=await navigator.requestMediaKeySystemAccess('com.widevine.alpha',c);await a.createMediaKeys();out[k]=true}catch(e){out[k]=String(e)}}
const T=t=>MediaSource.isTypeSupported(t);out.codecs={avc1:T('video/mp4; codecs="avc1.42E01E"'),aac:T('audio/mp4; codecs="mp4a.40.2"'),vp9:T('video/webm; codecs="vp9"'),opus:T('audio/webm; codecs="opus"'),av1:T('video/mp4; codecs="av01.0.05M.08"')};
return out})()"""


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith("/headers"):
            body, ctype = json.dumps({k.lower(): v for k, v in self.headers.items() if k.lower().startswith("sec-ch") or k.lower() == "user-agent"}).encode(), "application/json"
        elif self.path.startswith("/slow"):
            body, ctype = b"x" * 200_000, "application/octet-stream"
        elif self.path.startswith("/mp4"):
            body, ctype = MP4.encode(), "text/html; charset=utf-8"
        elif self.path.startswith("/widevine"):
            body, ctype = SHAKA.encode(), "text/html; charset=utf-8"
        else:
            body, ctype = PROBE.encode(), "text/html; charset=utf-8"
        self.send_response(200); self.send_header("Content-Type", ctype); self.send_header("Content-Length", str(len(body)))
        self.send_header("Accept-CH", "Sec-CH-UA-Model, Sec-CH-UA-Platform, Sec-CH-UA-Mobile"); self.send_header("Cache-Control", "no-store")
        self.end_headers(); self.wfile.write(body)

    def log_message(self, *args):
        pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
ORIGIN = "http://127.0.0.1:%d" % server.server_address[1]
URL = ORIGIN + "/probe-%s.html" % RUN

# The device toolbar's own code paths, run in the DevTools frontend (same code in both browsers).
FE = r"""(async(op,arg)=>{const B='devtools://devtools/bundled/';
const E=await import(B+'models/emulation/emulation.js');const UI=await import(B+'ui/legacy/legacy.js');const SDK=await import(B+'core/sdk/sdk.js');
const m=E.DeviceModeModel.DeviceModeModel.instance();const L=E.EmulatedDevices.EmulatedDevicesList.instance();
const tgt=SDK.TargetManager.TargetManager.instance().primaryPageTarget();const settle=()=>new Promise(r=>setTimeout(r,800));
const st=()=>({type:m.type(),device:m.device()&&m.device().title,scale:m.scale(),w:m.appliedDeviceSize().width,h:m.appliedDeviceSize().height,
  toolbar:(()=>{const seen=[];const walk=r=>{for(const e of r.querySelectorAll('*')){if(e.classList&&e.classList.contains('device-mode-toolbar')&&e.offsetWidth>0)seen.push(e);if(e.shadowRoot)walk(e.shadowRoot)}};walk(document);return seen.length>0})()});
const dev=t=>L.standard().find(d=>d.title===t);
switch(op){
 case 'devices':return L.standard().map(d=>d.title);
 case 'state':return st();
 case 'toggle':await UI.ActionRegistry.ActionRegistry.instance().getAction('emulation.toggle-device-mode').execute();await settle();return st();
 case 'device':{const d=dev(arg.title);m.emulate(E.DeviceModeModel.Type.Device,d,d.modesForOrientation(arg.orientation||'vertical')[0]);await settle();return st()}
 case 'responsive':m.emulate(E.DeviceModeModel.Type.Responsive,null,null);m.setWidth(arg.w);m.setHeight(arg.h);await settle();return st();
 case 'scale':m.scaleSetting().set(arg.scale);await settle();return st();
 case 'media':await tgt.emulationAgent().invoke_setEmulatedMedia({media:'',features:arg.features});return true;
 case 'geo':await tgt.emulationAgent().invoke_setGeolocationOverride(arg);return true;
 case 'net':SDK.NetworkManager.MultitargetNetworkManager.instance().setNetworkConditions(arg.on?SDK.NetworkManager.Slow3GConditions:SDK.NetworkManager.NoThrottlingConditions);return true;
 case 'cpu':SDK.CPUThrottlingManager.CPUThrottlingManager.instance().setCPUThrottlingRate(arg.rate);return true;
 case 'shot':await (arg.full?m.captureFullSizeScreenshot():m.captureScreenshot());return true;
}})"""
TIMING = """(async()=>{const t0=performance.now();let x=0;for(let i=0;i<3e7;i++)x+=i%7;const cpu=performance.now()-t0;
const t1=performance.now();await (await fetch('/slow?'+Math.random())).arrayBuffer();return {cpu:cpu,net:performance.now()-t1}})()"""
GEO = """new Promise(r=>navigator.geolocation.getCurrentPosition(p=>r([p.coords.latitude,p.coords.longitude]),e=>r(String(e.code)),{timeout:4000}))"""
KEYS = ("w", "h", "dpr", "sw", "sh", "orient", "mobile", "model", "platform", "hdrPlatform", "hdrMobile", "hdrModel",
        "touch", "coarse", "hoverNone", "dark", "reducedMotion", "portrait", "narrow")


def project(p):
    return {k: (p or {}).get(k) for k in KEYS} if isinstance(p, dict) else p


def suite(br, page, front):
    """The device toolbar steps; returns {step: (frontend state, page probe)}."""
    out = {}
    fe = lambda op, arg=None: br.cdp.eval("%s(%s,%s)" % (FE, json.dumps(op), json.dumps(arg or {})), front, 40)
    probe = lambda: br.cdp.eval("probe()", page, 20)
    wait_for(lambda: isinstance(fe("state"), dict), 30, 1)
    out["devices"] = fe("devices")
    # DevTools may still move to its remembered dock side: read the base once the page size holds.
    seen = []
    def steady():
        seen.append(probe())
        return len(seen) >= 2 and seen[-1] and seen[-2] and (seen[-1]["w"], seen[-1]["h"]) == (seen[-2]["w"], seen[-2]["h"]) and seen[-1]
    out["base"] = (None, wait_for(steady, 12, 1) or seen[-1])
    out["toggle"] = (fe("toggle"), probe())
    out["iphone"] = (fe("device", {"title": "iPhone 14 Pro Max"}), None)
    br.cdp.call("Page.reload", {}, page); wait_for(lambda: br.cdp.eval("typeof probe", page, 5) == "function", 20)
    out["iphone"] = (out["iphone"][0], probe())
    shot = br.cdp.call("Page.captureScreenshot", {"format": "png"}, page).get("result", {}).get("data")
    if shot:
        open(os.path.join(opts.out, "%s-page-iphone.png" % br.name), "wb").write(base64.b64decode(shot))
    out["rotate"] = (fe("device", {"title": "iPhone 14 Pro Max", "orientation": "horizontal"}), probe())
    if br.name == "cmux":
        out["rotate_frames"] = [{k: d.get(k) for k in ("page_frame", "devtools_frame")} for d in (rpc("debug.cef") or {}).get("devtools", []) if d.get("open")]
    out["pixel7"] = (fe("device", {"title": "Pixel 7"}), None)
    br.cdp.call("Page.reload", {}, page); wait_for(lambda: br.cdp.eval("typeof probe", page, 5) == "function", 20)
    out["pixel7"] = (out["pixel7"][0], probe())
    fe("media", {"features": [{"name": "prefers-color-scheme", "value": "dark"}, {"name": "prefers-reduced-motion", "value": "reduce"}]})
    out["media"] = (None, probe()); fe("media", {"features": []})
    out["responsive"] = (fe("responsive", {"w": 500, "h": 700}), probe())
    if br.name == "cmux":
        out["responsive_frames"] = [{k: d.get(k) for k in ("page_frame", "devtools_frame")} for d in (rpc("debug.cef") or {}).get("devtools", []) if d.get("open")]
    out["zoom"] = (fe("scale", {"scale": 0.5}), probe()); fe("scale", {"scale": 1})
    fe("geo", {"latitude": 37.7749, "longitude": -122.4194, "accuracy": 10})
    br.cdp.call("Browser.grantPermissions", {"origin": ORIGIN, "permissions": ["geolocation"]})
    out["geo"] = br.cdp.eval(GEO, page, 10)
    base = br.cdp.eval(TIMING, page, 30); fe("net", {"on": True}); fe("cpu", {"rate": 6})
    slow = br.cdp.eval(TIMING, page, 90); fe("net", {"on": False}); fe("cpu", {"rate": 1})
    out["throttle"] = {"base": base, "slow": slow}
    downloads = os.path.expanduser("~/Downloads"); before = set(os.listdir(downloads))
    fe("device", {"title": "iPhone 14 Pro Max"}); fe("shot", {"full": False})
    files = wait_for(lambda: [f for f in set(os.listdir(downloads)) - before if RUN in f and f.endswith(".png")], 15) or []
    out["screenshot"] = []
    for f in files:
        data = open(os.path.join(downloads, f), "rb").read()
        out["screenshot"].append(list(struct.unpack(">II", data[16:24])))
        os.replace(os.path.join(downloads, f), os.path.join(opts.out, "%s-devtools-screenshot.png" % br.name))
    out["off"] = (fe("toggle"), probe())
    return out


def rpc(method, params=None, timeout=30):
    try:
        c = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); c.settimeout(timeout); c.connect(SOCKET)
        c.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode()); buf = b""
        while not buf.endswith(b"\n"):
            chunk = c.recv(1 << 20)
            if not chunk:
                break
            buf += chunk
        c.close(); r = json.loads(buf); out = r.get("result") if r.get("ok") else {"error": r.get("error")}
    except (OSError, ValueError) as error:
        out = {"error": str(error)}
    log(rpc=method, params=params, reply=out)
    return out


def find(value, key):
    if isinstance(value, dict):
        if key in value:
            return value[key]
        value = list(value.values())
    for child in value if isinstance(value, list) else []:
        hit = find(child, key)
        if hit is not None:
            return hit
    return None


HOST = {}


def host_socket():
    """The browser host of the tagged app's own daemon: bh-<sha256(daemon socket)[:12]>/browser-host.sock
    beside that socket (another app's host on this Mac does not know the tab)."""
    if HOST.get("sock") and os.path.exists(HOST["sock"]):
        return HOST["sock"]
    p = subprocess.run([HOST["cli"], "--json", "daemon", "status"], capture_output=True, text=True, timeout=60)
    try:
        status = json.loads(p.stdout)
    except ValueError:
        status = {}
    for daemon in [v for v in (find(status, k) for k in ("socket", "socket_path", "path")) if isinstance(v, str)]:
        leaf = "bh-" + hashlib.sha256(daemon.encode()).hexdigest()[:12]
        for candidate in (os.path.join(os.path.dirname(daemon), leaf, "browser-host.sock"),
                          os.path.join("/tmp/cmux-tui-%d" % os.getuid(), leaf, "browser-host.sock")):
            if os.path.exists(candidate):
                HOST["sock"] = candidate
                log(daemon_socket=daemon, host_socket=candidate)
                return candidate
    log(host_socket=None, daemon_status=status)
    return None


def host(method, params, timeout=90):
    sock = host_socket()
    try:
        c = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); c.settimeout(timeout); c.connect(sock)
        c.sendall((json.dumps({"id": 1, "method": method, "params": params, "origin": "mcp"}) + "\n").encode()); buf = b""
        while not buf.endswith(b"\n"):
            chunk = c.recv(1 << 20)
            if not chunk:
                break
            buf += chunk
        c.close(); out = json.loads(buf)
    except (OSError, TypeError, ValueError) as e:
        out = {"error": str(e)}
    log(host=method, params=params, reply=out)
    return out


def agent_clicks(page, cmux, tab, label):
    """An agent clicks a link and a button through the browser host's REPL (CDP Input), as an MCP agent does."""
    cmux.cdp.eval("""(()=>{for(const id of ['TL','TB'])document.getElementById(id)?.remove();window.__agentClicks=[];
      const a=document.createElement('a');a.id='TL';a.href='#tl';a.textContent='agent link';
      const b=document.createElement('button');b.id='TB';b.textContent='agent button';
      for(const [e,t] of [[a,40],[b,120]]){Object.assign(e.style,{position:'fixed',left:'20px',top:t+'px',width:'160px',height:'48px',zIndex:2147483647});document.body.appendChild(e)}
      document.addEventListener('click',e=>{const t=e.target.closest('#TL,#TB');if(t){e.preventDefault();window.__agentClicks.push(t.id)}},true);return 1})()""", page, 10)
    session = "touch-%s-%d" % (label, os.getpid())
    opened = wait_for(lambda: (lambda o: o if "result" in o else None)(host("browser.repl.open", {"session": session, "engine": "cef"})), 30) or {}
    for target in ("TL", "TB"):
        t0 = time.time()
        code = 'const p = await tabs.use("%s"); await p.locator("#%s").click({timeout: 20000}); "clicked"' % (tab, target)
        reply = host("browser.repl.eval", {"session": session, "code": code, "timeoutMs": 40000}, 60)
        got = wait_for(lambda: (lambda v: v if v and target in v else None)(cmux.cdp.eval("window.__agentClicks", page, 10)), 5) or []
        check("T_%s_%s" % (label, "link" if target == "TL" else "button"), target in got, seconds=round(time.time() - t0, 2),
              clicks=got, reply=json.dumps(reply)[:300], opened=bool(opened))
    host("browser.repl.close", {"session": session})


def cli(path, *args):
    p = subprocess.run([path, "--json", *args], capture_output=True, text=True, timeout=60)
    log(cli=args, rc=p.returncode, out=p.stdout[-3000:], err=p.stderr[-1000:])
    return p.returncode


def main():
    chrome_proc = chrome = None; failed = True
    try:
        reference = None
        if not opts.no_chrome and not os.path.exists(opts.chrome):
            check("D_chrome_reference", False, why="no Google Chrome at %s (pass --no-chrome to skip the D checks)" % opts.chrome)
        if not opts.no_chrome and os.path.exists(opts.chrome):
            data_dir = os.path.join(tempfile.gettempdir(), "chrome-" + RUN)
            chrome_proc = subprocess.Popen([opts.chrome, "--user-data-dir=" + data_dir, "--remote-debugging-port=0", "--no-first-run",
                                            "--no-default-browser-check", "--auto-open-devtools-for-tabs", "--window-size=1400,1000", URL],
                                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            port_file = os.path.join(data_dir, "DevToolsActivePort")
            port = wait_for(lambda: os.path.exists(port_file) and open(port_file).read().split()[:1], 30)
            chrome = Browser("chrome", int(port[0]))
            page = chrome.attach(lambda t: t["type"] == "page" and t["url"].startswith(URL))
            front = chrome.attach(lambda t: t["url"].startswith("devtools://devtools/bundled/devtools_app"))
            chrome.cdp.call("Runtime.enable", {}, page)
            reference = suite(chrome, page, front)
            RESULTS["chrome"] = {"version": chrome.version, "suite": reference}
        port = 9300 + random.randint(0, 600)
        subprocess.run(["open", "-n", "--env", "CMUX_NEXT_CEF_EXTRA_SWITCHES=remote-debugging-port=%d%s" % (port, (":component-updater=fast-update" if opts.widevine else "") + (":" + os.environ["CMUX_LIVE_EXTRA_SWITCHES"] if os.environ.get("CMUX_LIVE_EXTRA_SWITCHES") else "")), opts.app], check=True)
        wait_for(lambda: "error" not in (rpc("system.ping") or {"error": 1}), 120, 1)
        ident = rpc("system.identify") or {}; app_cli = ident.get("app_cli_path"); pid = ident.get("pid"); started = time.time()
        rpc("debug.window_frame", {"frame": [40, 60, 1400, 1000]}); rpc("debug.focus")
        def open_tab():
            reply = rpc("action.run", {"action": "openBrowser.chromium", "args": {"url": URL}, "focus": True}, 60)
            if isinstance(reply, dict) and reply.get("created"):
                return reply["created"][0]
            # A fresh launch can have no focused pane yet: focus the window, make a tab, try again.
            rpc("debug.window.focus", {}); rpc("action.run", {"action": "newTab", "origin": "script", "focus": True}, 30)
            return None
        tab = wait_for(open_tab, 60, 1)
        if not tab:
            raise RuntimeError("openBrowser.chromium never opened a tab")
        wait_for(lambda: (rpc("browser.page.eval", {"script": "document.title", "tab": tab}) or {}).get("value"), 60, 1)
        if not wait_for(lambda: port_up(port), 60, 1):
            check("cmux_remote_debugging", False, why="no DevTools port %d (a Release build ignores CMUX_NEXT_CEF_EXTRA_SWITCHES)" % port)
            raise RuntimeError("no cmux DevTools port")
        cmux = Browser("cmux", port)
        page = cmux.attach(lambda t: t["type"] == "page" and t["url"].startswith(URL))
        cmux.cdp.call("Runtime.enable", {}, page)
        size = lambda: cmux.cdp.eval("({w:innerWidth,dpr:devicePixelRatio,ua:navigator.userAgent.includes('iPhone')})", page, 10)

        # E: cmux's own emulation reaches the page at once, both ways.
        native = size()
        t0 = time.time(); cli(app_cli, "tab", tab, "emulate", "--device", "iPhone 15")
        on = wait_for(lambda: (lambda s: s if s and s["w"] == 393 and s["dpr"] == 3 and s["ua"] else None)(size()), 8)
        check("E1_emulate_device_fast", bool(on) and time.time() - t0 < 2.0, seconds=round(time.time() - t0, 2), page=on)
        t0 = time.time(); cli(app_cli, "tab", tab, "emulate", "clear")
        off = wait_for(lambda: (lambda s: s if s and s["w"] == native["w"] and not s["ua"] else None)(size()), 12)
        check("E2_emulate_clear_fast", bool(off) and time.time() - t0 < 2.0, seconds=round(time.time() - t0, 2), page=off, native=native)

        # D: DevTools device mode, compared with Chrome.
        rpc("action.run", {"action": "toggleBrowserDeveloperTools", "origin": "script"}, 30)
        front = cmux.attach(lambda t: t["url"].startswith("devtools://devtools/bundled/devtools_app"), 30)
        check("D_devtools_frontend", bool(front))
        if front and reference:
            mine = suite(cmux, page, front); RESULTS["cmux"] = {"version": cmux.version, "suite": mine}
            check("D_presets_same", mine["devices"] == reference["devices"], cmux=mine["devices"], chrome=reference["devices"])
            check("D_toolbar_visible", bool((mine["toggle"][0] or {}).get("toolbar")), cmux=mine["toggle"][0], chrome=reference["toggle"][0])
            for step in ("iphone", "rotate", "pixel7", "media"):
                check("D_%s_page" % step, project(mine[step][1]) == project(reference[step][1]), cmux=project(mine[step][1]), chrome=project(reference[step][1]))
            # Device mode off: each browser's page is back to its own size before device mode.
            # Chrome's own base is read while its auto-opened DevTools may still take its width: compare it without w/h.
            loose = lambda p: {k: v for k, v in (project(p) or {}).items() if k not in ("w", "h")}
            check("D_off_restores_page", project(mine["off"][1]) == project(mine["base"][1]) and loose(reference["off"][1]) == loose(reference["base"][1]),
                  cmux=[project(mine["base"][1]), project(mine["off"][1])], chrome=[project(reference["base"][1]), project(reference["off"][1])])
            # The fit scale depends on the area beside the panels, which differs between the two
            # windows: a 932 px tall device scales down to fit in both, and toolbar and size agree.
            mi, ri = mine["iphone"][0] or {}, reference["iphone"][0] or {}
            check("D_iphone_fit_scale", 0.2 < (mi.get("scale") or 0) < 1 and 0.2 < (ri.get("scale") or 0) < 1
                  and (mi.get("w"), mi.get("h"), mi.get("toolbar")) == (ri.get("w"), ri.get("h"), ri.get("toolbar")), cmux=mi, chrome=ri)
            for step in ("responsive", "zoom"):
                check("D_%s_page" % step, project(mine[step][1]) == project(reference[step][1]), cmux=[mine[step][0], project(mine[step][1])],
                      chrome=[reference[step][0], project(reference[step][1])])
            check("D_geolocation", mine["geo"] == reference["geo"] == [37.7749, -122.4194], cmux=mine["geo"], chrome=reference["geo"])
            t = mine["throttle"]
            check("D_throttling", bool(t["base"] and t["slow"]) and t["slow"]["cpu"] > 2 * t["base"]["cpu"] and t["slow"]["net"] > 1000, cmux=t, chrome=reference["throttle"])
            check("D_screenshot", bool(mine["screenshot"]) and mine["screenshot"][0][0] == (reference["screenshot"] or [[0]])[0][0],
                  cmux=mine["screenshot"], chrome=reference["screenshot"])
            fe = lambda op, arg=None: cmux.cdp.eval("%s(%s,%s)" % (FE, json.dumps(op), json.dumps(arg or {})), front, 40)
            # The page window sits in the device's screen area, over DevTools (debug.cef page_frame).
            fe("toggle"); fe("device", {"title": "iPhone 14 Pro Max"})
            state0 = fe("state") or {}
            def placed():
                for d in (rpc("debug.cef") or {}).get("devtools", []):
                    f = d.get("page_frame")
                    if d.get("open") and d.get("tab") == tab and f and abs(f[2] - state0.get("w", 0) * state0.get("scale", 0)) <= 2:
                        return [d]
                return None
            report = wait_for(placed, 10) or [d for d in (rpc("debug.cef") or {}).get("devtools", []) if d.get("tab") == tab] or [{}]
            rpc("debug.window_snapshot", {"path": os.path.join(opts.out, "cmux-devtools-iphone.png")})
            frame, devtools_frame = report[0].get("page_frame"), report[0].get("devtools_frame")
            state = fe("state") or {}
            check("D_page_in_device_area", bool(frame and devtools_frame) and abs(frame[2] - state.get("w", 0) * state.get("scale", 0)) <= 2
                  and frame[2] < devtools_frame[2], page_frame=frame, devtools_frame=devtools_frame, frontend=state)
            # T (cx-3ny35): device mode turned touch on (the frontend's call, not cmux's): an agent's click
            # through the browser host (CDP Input) lands on a link and a button; before, it timed out at 30 s.
            HOST["cli"] = app_cli
            agent_clicks(page, cmux, tab, "devtools_iphone")
            fe("toggle")
            agent_clicks(page, cmux, tab, "after_device_mode")

            # F: the 16:9 fit and DevTools device mode on one tab.
            rpc("debug.window_frame", {"frame": [40, 60, 900, 1000]}); wait_for(lambda: (size() or {}).get("w", 9999) < 600, 10)
            cli(app_cli, "tab", tab, "emulate", "--fit", "16:9"); fit = wait_for(lambda: (lambda s: s if s and s["w"] > 1000 else None)(size()), 8)
            fe("toggle"); fe("device", {"title": "iPhone 14 Pro Max"})
            before = wait_for(lambda: (lambda s: s if s and s["w"] == 430 else None)(size()), 6)
            rpc("debug.window_frame", {"frame": [40, 60, 960, 1000]})
            samples = []
            wait_for(lambda: samples.append(size()) and False, 4)
            check("F_resize_keeps_devtools_device", bool(before) and len(samples) >= 4 and all(s and s["w"] == 430 for s in samples),
                  fit=fit, before=before, after_resize=samples[-3:])
            fe("toggle"); back = wait_for(lambda: (lambda s: s if s and s["w"] > 1000 else None)(size()), 6)
            check("F_devtools_off_restores_fit", bool(back), after=back or size())
            cli(app_cli, "tab", tab, "emulate", "clear")

        if opts.widevine:
            give = max(0, 90 - (time.time() - started))
            wait_for(lambda: False, give, 5)  # the component updater's download window
            status = {"eme": cmux.cdp.eval(WV_JS, page, 30), "playback": {}}
            for name, mpd in (("angel-one", "https://storage.googleapis.com/shaka-demo-assets/angel-one-widevine/dash.mpd&codec=avc1"),
                              ("sintel-vp9", "https://storage.googleapis.com/shaka-demo-assets/sintel-widevine/dash.mpd")):
                target = cmux.cdp.call("Target.createTarget", {"url": "%s/widevine-%s?mpd=%s" % (ORIGIN, RUN, mpd)}).get("result", {}).get("targetId")
                session = cmux.cdp.call("Target.attachToTarget", {"targetId": target, "flatten": True}).get("result", {}).get("sessionId")
                status["playback"][name] = wait_for(lambda: (lambda s: s if isinstance(s, dict) and (s.get("errors") or (s.get("t") or 0) > 3) else None)(
                    cmux.cdp.eval("typeof status==='function'?status():null", session, 10)), 30, 1) or cmux.cdp.eval("status()", session, 10)
                cmux.cdp.call("Target.closeTarget", {"targetId": target})
            root = os.path.expanduser("~/Library/Application Support/%s/Chromium" % ident.get("bundle_id"))
            def fresh(sub, name):
                """Version folders under <root>/<sub> that hold `name`."""
                base = os.path.join(root, sub); hits = []
                for dirpath, _, files in os.walk(base) if os.path.isdir(base) else []:
                    if name in files:  # an installed version folder, not an empty or partial one
                        hits.append(os.path.relpath(dirpath, base))
                return sorted(hits) or None
            status["cdm_dir"] = fresh("WidevineCdm", "libwidevinecdm.dylib")
            # CRLSet comes in a later update round than Widevine (seen at 90-150 s with fast-update).
            status["crlset_dir"] = wait_for(lambda: fresh("CertificateRevocation", "crl-set"), max(0, 240 - (time.time() - started)), 5)
            # H.264/AAC (proprietary_codecs, cmux.28): a plain MP4 plays with picture and sound.
            target = cmux.cdp.call("Target.createTarget", {"url": "%s/mp4-%s" % (ORIGIN, RUN)}).get("result", {}).get("targetId")
            session = cmux.cdp.call("Target.attachToTarget", {"targetId": target, "flatten": True}).get("result", {}).get("sessionId")
            status["mp4"] = wait_for(lambda: (lambda s: s if isinstance(s, dict) and (s.get("error") or (s.get("t") or 0) > 3) else None)(
                cmux.cdp.eval("typeof mp4==='function'?mp4():null", session, 10)), 40, 1) or cmux.cdp.eval("mp4()", session, 10)
            cmux.cdp.call("Target.closeTarget", {"targetId": target})
            status["sig_files"] = subprocess.run(["find", opts.app, "-name", "*.sig"], capture_output=True, text=True).stdout.split("\n")[:-1]
            RESULTS["widevine"] = status
            print("widevine:", json.dumps(status, default=str)[:1500], flush=True)
            if opts.require_widevine:
                check("W_eme_vp9", status["eme"] and status["eme"].get("webm-vp9-opus") is True, eme=status["eme"])
                check("W_cdm_installed", bool(status["cdm_dir"]), cdm_dir=status["cdm_dir"])
                check("W_crlset_installed", bool(status["crlset_dir"]), crlset_dir=status["crlset_dir"])
                check("W_mp4_h264_aac", ((status["mp4"] or {}).get("t") or 0) > 3 and (status["mp4"] or {}).get("frames", 0) > 0
                      and (status["mp4"] or {}).get("audioBytes", 0) > 0, mp4=status["mp4"])
                check("W_eme_h264_aac", status["eme"] and status["eme"].get("mp4-avc1-aac") is True, eme=status["eme"])
                angel = status["playback"].get("angel-one") or {}
                check("W_playback_h264_sd", (angel.get("t") or 0) > 3 and str((angel.get("variant") or {}).get("v", "")).startswith("avc1"), playback=angel)
                check("W_playback_vp9", ((status["playback"].get("sintel-vp9") or {}).get("t") or 0) > 3, playback=status["playback"].get("sintel-vp9"))

        if not pid:
            raise RuntimeError("system.identify gave no pid")
        shown = subprocess.run(["log", "show", "--last", "%ds" % int(time.time() - started + 30), "--style", "compact", "--predicate",
                                'processID == %d AND eventMessage CONTAINS "device emulation"' % pid], capture_output=True, text=True, timeout=120)
        bad = [l for l in shown.stdout.splitlines() if "failed" in l]
        check("E3_no_emulation_errors", shown.returncode == 0 and not bad, errors=bad[-6:], rc=shown.returncode)
        failed = any(c["status"] == "fail" for c in RESULTS["checks"])
    except Exception as error:  # noqa: BLE001 - any harness error is a failed run
        check("harness", False, error=repr(error)); failed = True
    finally:
        json.dump(RESULTS, open(os.path.join(opts.out, "results.json"), "w"), indent=1, default=str)
        if chrome:
            chrome.cdp.call("Browser.close", {}, timeout=5)
        if chrome_proc:
            chrome_proc.wait(timeout=30)
        rpc("debug.quit", {"fixture_quit": "end-sessions"}, 10)
        if os.environ.get("NX_APP_STOP"):
            subprocess.run([os.environ["NX_APP_STOP"]], timeout=120)
    gaps = [c["id"] for c in RESULTS["checks"] if c["status"] == "known-gap"]
    print("RESULT %s (%d checks, known gaps: %s)" % ("FAIL" if failed else "PASS", len(RESULTS["checks"]), ", ".join(gaps) or "none"), flush=True)
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
