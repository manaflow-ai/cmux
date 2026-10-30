"""Extra collector pages for the real-extension checks."""

ADS = """<!doctype html><meta charset="utf-8"><title>cxt ads</title>
<body style="background:#fff">
<div class="adsbygoogle ad-banner" id="ad-slot" style="width:300px;height:250px;background:#eee">ad slot</div>
<script>window.cxtAds = {};</script>
<script src="https://pagead2.googlesyndication.com/pagead/js/adsbygoogle.js"
  onload="cxtAds.script='loaded'" onerror="cxtAds.script='blocked'"></script>
"""

LIGHT = """<!doctype html><meta charset="utf-8"><title>cxt light</title>
<body style="background:#fff;color:#000;font:16px -apple-system,sans-serif"><h1>Light page</h1><p>Plain text on white.</p>
"""

LINKS = """<!doctype html><meta charset="utf-8"><title>cxt links</title>
<body style="font:16px -apple-system,sans-serif"><p><a href="/home.html">one</a> <a href="/blank.html">two</a> <a href="/light.html">three</a></p>
"""

REACT = """<!doctype html><meta charset="utf-8"><title>cxt react</title><div id="root"></div>
<script src="https://unpkg.com/react@18/umd/react.development.js"></script>
<script src="https://unpkg.com/react-dom@18/umd/react-dom.development.js"></script>
<script>ReactDOM.createRoot(document.getElementById('root')).render(React.createElement('h1', null, 'React page'));</script>
"""

VUE = """<!doctype html><meta charset="utf-8"><title>cxt vue</title><div id="app">{{ message }}</div>
<script src="https://unpkg.com/vue@3/dist/vue.global.js"></script>
<script>Vue.createApp({data: () => ({message: 'Vue page'})}).mount('#app');</script>
"""

DATA = '{"name": "cmux", "values": [1, 2, 3], "nested": {"ok": true}}'


def _page(body, content_type="text/html"):
    return lambda query: (200, body, content_type)


ROUTES = {
    "/ads.html": _page(ADS),
    "/light.html": _page(LIGHT),
    "/links.html": _page(LINKS),
    "/react.html": _page(REACT),
    "/vue.html": _page(VUE),
    "/data.json": _page(DATA, "application/json"),
}
