# SPDX-License-Identifier: MIT
"""Web page fixtures for macOS, where Tk windows answer no accessibility and
take no background input: the same windows as fixture_app.py, as pages in the
OS browser (a real Cocoa app with a full accessibility tree).

  python3 web_app.py --mode form --port 8765 --state /tmp/form.json [--title T] [--code 1234]

Every change on the page is posted to /state and merged into --state (JSON,
atomically), with the same keys fixture_app.py writes, so the same checks read
it. The state file appears only once the page has loaded (the ready signal).

Modes:
  form      "CU Eval Form": name, subscribe, Increment + "Count: N", answer, Save,
            a 100-row list (scrolls), a 0-100 slider, a verification code.
  catalog   "CU Eval Catalog": an Answer box and Check button at the top, then a
            long table of items; one row is --item with price --price.
  prefs     "CU Eval Preferences": General and Advanced tabs; Advanced shows the
            Device ID (--code); General has "Pairing code" and Apply.
"""

from __future__ import annotations

import argparse
import html
import json
import os
import random
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

STYLE = """body{font:15px -apple-system,system-ui;margin:16px;max-width:30rem}
label{display:block;margin:.4rem 0}input[type=text]{font:inherit;padding:.2rem;width:16rem}
button{font:inherit;padding:.2rem .8rem}select{font:inherit;width:12rem}"""

POST = """<script>
var _seq=0;
function post(patch){_seq+=1;patch._seq=_seq;fetch('/state',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(patch)});}
</script>"""

FORM = """<!doctype html><html><head><meta charset="utf-8"><title>{title}</title><style>{style}</style>{post}</head>
<body>
<label>Name <input type="text" id="name" aria-label="Name" autocomplete="off" oninput="post({{name:this.value}})"
  onkeydown="if(event.key==='Enter'){{save()}}"></label>
<label><input type="checkbox" id="subscribe" onchange="post({{subscribe:this.checked}})"> Subscribe to updates</label>
<p><button id="inc" onclick="inc()">Increment</button> <span id="count">Count: 0</span></p>
<label>Answer <input type="text" id="answer" aria-label="Answer" autocomplete="off" oninput="post({{answer:this.value}})"></label>
<p><button id="save" onclick="save()">Save</button></p>
<label>Items <select id="list" size="6" aria-label="Items" onchange="post({{selected:this.selectedIndex+1}})">{options}</select></label>
<label>Level <input type="range" id="slider" aria-label="Level" min="0" max="100" value="0"
  oninput="post({{slider:parseInt(this.value)}});document.getElementById('lv').textContent=this.value"> <span id="lv">0</span></label>
<p id="code">Verification code: {code}</p>
<script>
var n=0;
function inc(){{n+=1;document.getElementById('count').textContent='Count: '+n;post({{counter:n}});}}
function save(){{post({{saved:true,saved_name:document.getElementById('name').value}});}}
document.getElementById('list').addEventListener('scroll',function(){{post({{first_visible:Math.floor(this.scrollTop/18)+1}})}});
post({{loaded:true}});
</script></body></html>"""

CATALOG = """<!doctype html><html><head><meta charset="utf-8"><title>{title}</title><style>{style}
td{{padding:2px 10px;border-bottom:1px solid #ddd}}</style>{post}</head>
<body>
<label>Answer <input type="text" id="answer" aria-label="Answer" autocomplete="off" oninput="post({{answer:this.value}})"></label>
<p><button onclick="post({{checked:true,checked_answer:document.getElementById('answer').value}})">Check</button></p>
<table><tr><th>Item</th><th>Price</th></tr>{rows}</table>
<script>post({{loaded:true}});</script></body></html>"""

PREFS = """<!doctype html><html><head><meta charset="utf-8"><title>{title}</title><style>{style}
[role=tab][aria-selected=true]{{font-weight:bold}}</style>{post}</head>
<body>
<div role="tablist"><button role="tab" id="t1" aria-selected="true" onclick="show(1)">General</button>
<button role="tab" id="t2" aria-selected="false" onclick="show(2)">Advanced</button></div>
<div role="tabpanel" id="p1"><label>Pairing code <input type="text" id="pair" aria-label="Pairing code" autocomplete="off"
  oninput="post({{pairing:this.value}})"></label>
<p><button onclick="post({{applied:true,applied_code:document.getElementById('pair').value}})">Apply</button></p></div>
<div role="tabpanel" id="p2" hidden><p>Device ID: {code}</p><p>Channel: stable</p></div>
<script>
function show(i){{document.getElementById('p1').hidden=i!==1;document.getElementById('p2').hidden=i!==2;
document.getElementById('t1').setAttribute('aria-selected',i===1);document.getElementById('t2').setAttribute('aria-selected',i===2);
post({{tab:i===1?'general':'advanced'}});}}
post({{loaded:true}});
</script></body></html>"""

WORDS = ["amber", "birch", "cedar", "delta", "ember", "fjord", "garnet", "harbor", "indigo", "juniper", "kelp",
         "lumen", "maple", "nectar", "onyx", "pepper", "quartz", "raven", "saffron", "tundra", "umber", "violet",
         "willow", "yarrow", "zephyr", "basalt", "cobalt", "dune", "flint", "glacier"]


def page(a: argparse.Namespace) -> str:
    if a.mode == "form":
        opts = "".join(f"<option>Item {i}</option>" for i in range(1, 101))
        return FORM.format(title=html.escape(a.title or "CU Eval Form"), style=STYLE, post=POST, options=opts,
                           code=html.escape(a.code))
    if a.mode == "catalog":
        rng = random.Random(a.seed)
        names = [f"{w}-{rng.randrange(100, 999)}" for w in WORDS for _ in range(5)]
        names = [n for n in names if n != a.item]
        rng.shuffle(names)
        rows = [(n, f"{rng.randrange(1, 99)}.{rng.randrange(100):02d}") for n in names[:150]]
        rows.insert(a.position, (a.item, a.price))
        body = "".join(f"<tr><td>{html.escape(n)}</td><td>{html.escape(p)}</td></tr>" for n, p in rows)
        return CATALOG.format(title=html.escape(a.title or "CU Eval Catalog"), style=STYLE, post=POST, rows=body)
    return PREFS.format(title=html.escape(a.title or "CU Eval Preferences"), style=STYLE, post=POST,
                        code=html.escape(a.code))


def base_state(a: argparse.Namespace) -> dict:
    if a.mode == "form":
        return {"mode": "form", "title": a.title or "CU Eval Form", "name": "", "subscribe": False, "counter": 0,
                "answer": "", "saved": False, "saved_name": None, "selected": None, "first_visible": 0,
                "slider": 0, "code": a.code}
    if a.mode == "catalog":
        return {"mode": "catalog", "answer": "", "checked": False, "checked_answer": None}
    return {"mode": "prefs", "pairing": "", "applied": False, "applied_code": None, "tab": "general"}


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--mode", choices=["form", "catalog", "prefs"], required=True)
    p.add_argument("--port", type=int, required=True)
    p.add_argument("--state", required=True)
    p.add_argument("--title", default="")
    p.add_argument("--code", default="0000")
    p.add_argument("--item", default="")
    p.add_argument("--price", default="")
    p.add_argument("--position", type=int, default=120)
    p.add_argument("--seed", type=int, default=0)
    a = p.parse_args()
    body = page(a).encode()
    state = base_state(a)
    lock = threading.Lock()
    seqs: dict[str, int] = {}

    def write():
        tmp = a.state + ".tmp"
        with open(tmp, "w") as f:
            json.dump(state, f, indent=1, sort_keys=True)
        os.replace(tmp, a.state)

    class H(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_GET(self):
            code, data = (200, body) if self.path in ("/", "/index.html") else (404, b"not found")
            self.send_response(code)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(data)

        def do_POST(self):
            n = int(self.headers.get("Content-Length") or 0)
            try:
                patch = json.loads(self.rfile.read(n) or b"{}")
            except ValueError:
                patch = {}
            with lock:  # posts can arrive out of order: a key keeps the value of its latest post
                if isinstance(patch, dict):
                    seq = patch.pop("_seq", 0)
                    for k, v in patch.items():
                        if seq >= seqs.get(k, -1):
                            state[k] = v
                            seqs[k] = seq
                write()
            self.send_response(204)
            self.end_headers()

    ThreadingHTTPServer(("127.0.0.1", a.port), H).serve_forever()


if __name__ == "__main__":
    main()
