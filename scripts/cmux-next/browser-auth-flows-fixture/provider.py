#!/usr/bin/env python3
"""Fixture OAuth provider + relying party for browser auth-flow checks. Usage: server.py PORT
Hosts: localhost (RP, app), 127.0.0.1 (IdP). No real credentials."""
import http.server, sys, json, urllib.parse
PORT=int(sys.argv[1]) if len(sys.argv)>1 else 8765
P={}
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self,*a): pass
    def send(self,body,ct="text/html",code=200,headers=()):
        b=body.encode(); self.send_response(code); self.send_header("Content-Type",ct)
        for k,v in headers: self.send_header(k,v)
        self.send_header("Content-Length",str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        u=urllib.parse.urlparse(self.path); q=urllib.parse.parse_qs(u.query); h=self.headers.get("Host","")
        if u.path=="/rp":  # relying party: button opens popup with opener
            self.send(f"""<title>rp</title><button id=gesture onclick="w=window.open('http://127.0.0.1:{PORT}/idp/authorize?mode=popup','idp','width=500,height=600');window.__w=!!w">sign in popup</button>
<button id=g1 onclick="w1=window.open('http://127.0.0.1:{PORT}/idp/authorize?mode=popup','p1');window.__w1=String(!!w1)">nofeat</button>
<button id=g2 onclick="try{{w2=window.open('http://127.0.0.1:{PORT}/idp/authorize?mode=popup','p2','popup,width=500,height=600');window.__w2=String(!!w2)}}catch(e){{window.__w2='err '+e}}">feat</button>
<a id=blank target=_blank href="http://127.0.0.1:{PORT}/idp/plain">blank</a>
<script>window.__msgs=[];addEventListener('message',e=>{{window.__msgs.push([e.origin,e.data])}});
window.scripted=()=>{{var w=window.open('http://127.0.0.1:{PORT}/idp/plain','x');return !!w}};</script>""")
        elif u.path=="/auto":
            self.send(f"<title>auto</title><script>setTimeout(()=>{{window.__auto=window.open('http://127.0.0.1:{PORT}/idp/plain','auto');window.__autoResult=String(!!window.__auto)}},500)</script>")
        elif u.path=="/idp/authorize":
            self.send("<title>idp</title><form id=f><input id=user type=text><input id=pw type=password><button>go</button></form><script>setTimeout(()=>{opener.postMessage({code:'abc',origin:location.origin},'*');if(location.search.includes('close'))window.close()},300)</script>",
                      headers=[("Set-Cookie","idp=1; Path=/")])
        elif u.path=="/idp/plain": self.send("<title>plain</title>opener="+"<script>document.write(String(!!window.opener))</script>")
        elif u.path=="/redir": self.send("",code=302,headers=[("Location",q["to"][0])])
        elif u.path=="/setcookie":  # cookie on this host with attrs
            self.send("ok",headers=[("Set-Cookie","a=1; Path=/; SameSite=None; Secure"),("Set-Cookie","l=1; Path=/; SameSite=Lax"),("Set-Cookie","n=1; Path=/; SameSite=None"),("Set-Cookie","p=persist; Path=/; Max-Age=86400")])
        elif u.path=="/embed":  # SSO iframe: top on this host, iframe on other host
            other=q.get("other",[f"http://127.0.0.1:{PORT}"])[0]
            self.send(f"<title>embed</title><script>window.__m=[];addEventListener('message',e=>__m.push(e.data))</script><iframe id=fr src='{other}/iframe'></iframe>")
        elif u.path=="/iframe":
            self.send("<title>ifr</title><script>document.cookie='tp=1; SameSite=None';localStorage.setItem('k','v');parent.postMessage({cookie:document.cookie,ls:localStorage.getItem('k')},'*')</script>",
                      headers=[("Set-Cookie","fr=1; Path=/; SameSite=None")])
        elif u.path=="/cookies": self.send(self.headers.get("Cookie","(none)"),ct="text/plain")
        else: self.send("hi")
http.server.ThreadingHTTPServer(("127.0.0.1",PORT),H).serve_forever()
