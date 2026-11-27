"""Local test pages and the beacon server xbench.py measures paint, visibility and video with.

Every page is served from 127.0.0.1, so no row depends on the network. The
idle page follows Ardia's native-bench static page (60 boxes, 120 paragraphs,
a 1 s timer, paint and visibility marks) so rows compare with its published
numbers. Pages report to POST /b with `navigator.sendBeacon`:

  fcp      first-contentful-paint, as epoch ms (performance.timeOrigin + startTime)
  shown    visibilitychange to visible, then two requestAnimationFrame callbacks
  hidden   visibilitychange to hidden
  load     the load event
  playing  the video page's clip is playing (currentTime > 0)

`id` is the page's `?id=` query, so the harness knows which tab spoke.
"""
from __future__ import annotations

import http.server
import json
import threading
import time

BEACON_JS = """
<script>
const benchId = new URLSearchParams(location.search).get('id') || '';
function benchSend(ev, extra) {
  const body = Object.assign({id: benchId, ev, t: performance.timeOrigin + performance.now(),
                              vis: document.visibilityState}, extra || {});
  navigator.sendBeacon('/b', JSON.stringify(body));
}
try {
  new PerformanceObserver(list => {
    for (const e of list.getEntries())
      if (e.name === 'first-contentful-paint') benchSend('fcp', {t: performance.timeOrigin + e.startTime});
  }).observe({type: 'paint', buffered: true});
} catch (e) { benchSend('error', {message: String(e)}); }
document.addEventListener('visibilitychange', () => {
  if (document.visibilityState === 'visible')
    requestAnimationFrame(() => requestAnimationFrame(() => benchSend('shown')));
  else benchSend('hidden');
});
addEventListener('load', () => benchSend('load'));
</script>
"""

STYLE = ("<style>body{font:15px -apple-system,Helvetica,sans-serif;margin:24px;color:#222}"
         ".b{display:inline-block;width:96px;height:64px;margin:4px;border-radius:8px;"
         "background:linear-gradient(135deg,#4a90d9,#7b5ea7)}p{max-width:760px;line-height:1.5}</style>")
PARAGRAPH = ("cmux keeps idle work at zero: no timers, no polling, nothing drawn that did not change. "
             "This paragraph exists to give the renderer real text to lay out and paint. ")


def idle_page() -> str:
    boxes = "".join(f"<div class=b title='box {i}'></div>" for i in range(60))
    paragraphs = "".join(f"<p>{i}. {PARAGRAPH * 2}</p>" for i in range(120))
    return ("<!doctype html><meta charset=utf-8><title>xbench idle</title>" + STYLE + BEACON_JS +
            "<h1>xbench idle page <span id=clock></span></h1>" + boxes + paragraphs +
            "<script>setInterval(()=>{document.getElementById('clock').textContent=new Date().toLocaleTimeString()},1000)</script>")


def scroll_page() -> str:
    paragraphs = "".join(f"<p>{i}. {PARAGRAPH * 3}</p><div class=b></div>" for i in range(1500))
    # Scrolls itself 4 px per frame, bouncing at both ends: a reading-speed scroll at the display rate.
    return ("<!doctype html><meta charset=utf-8><title>xbench scroll</title>" + STYLE + BEACON_JS + paragraphs +
            "<script>let d=4;function s(){const e=document.scrollingElement;"
            "if(e.scrollTop+innerHeight>=e.scrollHeight-2)d=-4;else if(e.scrollTop<=0)d=4;"
            "e.scrollTop+=d;requestAnimationFrame(s)}addEventListener('load',()=>requestAnimationFrame(s))</script>")


def video_page() -> str:
    # The clip is made in the page (canvas -> MediaRecorder) so the row needs no
    # downloaded media and every engine decodes a codec it recorded itself.
    return ("<!doctype html><meta charset=utf-8><title>xbench video</title>" + BEACON_JS +
            "<body style='margin:0;background:#000'><video id=v muted loop playsinline style='width:100%'></video>"
            "<canvas id=c width=1280 height=720 hidden></canvas><script>"
            "const c=document.getElementById('c'),x=c.getContext('2d');"
            "const types=['video/webm;codecs=vp8','video/webm','video/mp4;codecs=avc1','video/mp4'];"
            "const type=types.find(t=>window.MediaRecorder&&MediaRecorder.isTypeSupported(t));"
            "if(!type){benchSend('error',{message:'no MediaRecorder type'})}else{"
            "const r=new MediaRecorder(c.captureStream(30),{mimeType:type,videoBitsPerSecond:4e6}),parts=[];let f=0;"
            "r.ondataavailable=e=>parts.push(e.data);"
            "r.onstop=()=>{const v=document.getElementById('v');v.src=URL.createObjectURL(new Blob(parts,{type}));"
            "v.play().then(()=>{const w=()=>v.currentTime>0?benchSend('playing',{type}):setTimeout(w,100);w()})"
            ".catch(e=>benchSend('error',{message:String(e)}))};"
            "function draw(){x.fillStyle=`hsl(${f*3%360},70%,40%)`;x.fillRect(0,0,1280,720);x.fillStyle='#fff';"
            "x.font='120px sans-serif';x.fillText('frame '+f,100,400);f++;if(f<300)requestAnimationFrame(draw);else r.stop()}"
            "r.start(250);draw()}</script>")


PAGES = {"/idle.html": idle_page, "/scroll.html": scroll_page, "/video.html": video_page}


class BeaconServer:
    """Serves PAGES and records every beacon with the time it arrived."""

    def __init__(self, port: int = 0):
        self.events: list[dict] = []
        self.cond = threading.Condition()
        bodies = {path: make().encode() for path, make in PAGES.items()}
        server = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):  # noqa: N802
                body = bodies.get(self.path.split("?", 1)[0])
                if body is None:
                    self.send_error(404)
                    return
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Cache-Control", "no-store")
                self.end_headers()
                self.wfile.write(body)

            def do_POST(self):  # noqa: N802
                data = self.rfile.read(int(self.headers.get("Content-Length") or 0))
                self.send_response(204)
                self.end_headers()
                try:
                    event = json.loads(data or b"{}")
                except ValueError:
                    return
                event["arrived"] = time.time() * 1000
                with server.cond:
                    server.events.append(event)
                    server.cond.notify_all()

            def log_message(self, *_args):
                pass

        self.httpd = http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler)
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()
        self.base = f"http://127.0.0.1:{self.httpd.server_address[1]}"

    def url(self, page: str, tab_id: str) -> str:
        return f"{self.base}/{page}.html?id={tab_id}"

    def wait(self, ev: str, tab_id: str | None = None, after: float = 0, timeout: float = 10) -> dict | None:
        """The first `ev` beacon (from `tab_id`, if given) arrived after epoch ms `after`, or None."""
        deadline = time.monotonic() + timeout
        with self.cond:
            while True:
                for event in self.events:
                    if event.get("ev") == ev and event["arrived"] >= after and (tab_id is None or event.get("id") == tab_id):
                        return event
                left = deadline - time.monotonic()
                if left <= 0:
                    return None
                self.cond.wait(left)
