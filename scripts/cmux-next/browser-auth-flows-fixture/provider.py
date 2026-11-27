#!/usr/bin/env python3
"""Fixture OAuth provider + relying party for browser auth-flow checks. Usage: server.py PORT
Hosts: localhost (RP, app), 127.0.0.1 (IdP). No real credentials."""
import http.server, sys, json, urllib.parse, html
PORT=int(sys.argv[1]) if len(sys.argv)>1 else 8765
P={}  # what pages and requests observed, read back at /reports
def oc(js):  # a script as a double-quoted HTML attribute (a json.dumps'd string's quotes would end it early)
    return '"'+html.escape(js,quote=True)+'"'
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
            self.send("<title>ifr</title><script>document.cookie='tp=1; SameSite=None';localStorage.setItem('k','v');parent.postMessage({cookie:document.cookie,ls:localStorage.getItem('k'),saa:typeof document.requestStorageAccess},'*')</script>",
                      headers=[("Set-Cookie","fr=1; Path=/; SameSite=None")])
        elif u.path=="/report":  # a page tells what it saw: /report?k=NAME&opener=true...
            k=q.pop("k",["?"])[0]; P[k]={a:b[0] for a,b in q.items()}; self.send("ok")
        elif u.path=="/reports": self.send(json.dumps(P),ct="application/json")
        elif u.path=="/reset": P.clear(); self.send("ok")
        elif u.path=="/probe":  # a link target: reports opener, name and the Referer the server got
            k=q.get("k",["probe"])[0]; P.setdefault("ref",{})[k]=self.headers.get("Referer","(none)")
            hdr=[("Cross-Origin-Opener-Policy",q["coop"][0])] if "coop" in q else []
            self.send(f"<title>probe</title><script>fetch('/report?k={k}&opener='+(!!window.opener)+'&name='+encodeURIComponent(window.name)+'&ref='+encodeURIComponent(document.referrer))</script>probe {k}",headers=hdr)
        elif u.path=="/links":  # target=_blank link variants, on the RP host
            t=f"http://127.0.0.1:{PORT}/probe"
            self.send(f"<title>links</title><a id=l_blank target=_blank href='{t}?k=blank'>x</a><a id=l_noopener target=_blank rel=noopener href='{t}?k=noopener'>x</a>"
                      f"<a id=l_noreferrer target=_blank rel=noreferrer href='{t}?k=noreferrer'>x</a><a id=l_opener target=_blank rel=opener href='{t}?k=relopener'>x</a>"
                      f"<a id=l_named target=named_win href='{t}?k=named'>x</a>")
        elif u.path=="/coopopener":  # opener page with its own COOP; popup is cross-origin and has its own
            hdr=[("Cross-Origin-Opener-Policy",q["coop"][0])] if "coop" in q else []
            to=f"http://127.0.0.1:{PORT}/probe?"+urllib.parse.urlencode([("k",q.get("k",["coop"])[0])]+([("coop",q["popupcoop"][0])] if "popupcoop" in q else []))
            js="window.__w=window.open(%s,'coopwin','popup,width=400,height=400');window.__opened=String(!!__w)"%json.dumps(to)
            self.send("<title>coop</title><button id=go onclick=%s>go</button>"%oc(js),headers=hdr)
        elif u.path=="/cb":  # an OAuth popup ending: custom scheme by script, or by 302
            to=q.get("to",["vscode://auth?code=1"])[0]
            if q.get("via",["js"])[0]=="302": self.send("",code=302,headers=[("Location",to)])
            else: self.send(f"<title>cb</title>finishing<script>setTimeout(()=>{{location.href={json.dumps(to)}}},300)</script>")
        elif u.path=="/schemeopen":  # RP: opens the /cb popup (gesture), or the main tab goes there
            to=q.get("to",["vscode://auth?code=1"])[0]; via=q.get("via",["js"])[0]
            js="window.__w=window.open(%s+encodeURIComponent(%s),'schemewin','popup,width=400,height=400')"%(json.dumps(f"http://127.0.0.1:{PORT}/cb?via={via}&to="),json.dumps(to))
            self.send("<title>schemeopen</title><button id=go onclick=%s>go</button>"%oc(js))
        elif u.path=="/iframeopen":  # a same-origin iframe whose script opens the IdP popup and gets the code back
            self.send(f"<title>iframeopen</title><iframe id=fr src='/iframeopen_inner'></iframe><script>window.__m=[];addEventListener('message',e=>__m.push(e.data))</script>")
        elif u.path=="/iframeopen_inner":
            self.send(f"<button id=go onclick=\"w=window.open('http://127.0.0.1:{PORT}/idp/authorize?mode=popup','ifrwin','popup,width=400,height=400');window.__w=String(!!w)\">go</button><script>window.__m=[];addEventListener('message',e=>{{__m.push(e.data);parent.__m.push(e.data)}})</script>")
        elif u.path=="/openerback":  # popup (IdP host) sets opener.location, the redirect-back flow, then closes
            self.send(f"<title>back</title><script>setTimeout(()=>{{opener.location='http://localhost:{PORT}/done?code=9';setTimeout(()=>close(),300)}},300)</script>")
        elif u.path=="/openerrp":
            self.send(f"<title>openerrp</title><button id=go onclick=\"window.__w=window.open('http://127.0.0.1:{PORT}/openerback','backwin','popup,width=400,height=400')\">go</button>")
        elif u.path=="/done": self.send("<title>done</title>done "+q.get("code",[""])[0])
        elif u.path=="/dl":  # a file as the login's next step
            self.send("downloaded-during-login",ct="application/octet-stream",headers=[("Content-Disposition","attachment; filename=login.bin")])
        elif u.path=="/dlflow":  # RP page: popup is sent to a download, then reports back
            self.send(f"<title>dlflow</title><button id=go onclick=\"window.__w=window.open('http://127.0.0.1:{PORT}/dl','dlwin','popup,width=400,height=400')\">go</button><a id=dl href='/dl'>dl</a>")
        elif u.path=="/basic":  # an HTTP 401 Basic challenge; user:pw is the only answer
            import base64
            if self.headers.get("Authorization")=="Basic "+base64.b64encode(b"user:pw").decode(): self.send("<title>basic ok</title>auth ok")
            else: self.send("<title>basic 401</title>need auth",code=401,headers=[("WWW-Authenticate",'Basic realm="fixture"')])
        elif u.path=="/cookies": self.send(self.headers.get("Cookie","(none)"),ct="text/plain")
        else: self.send("hi")
if __name__=="__main__": http.server.ThreadingHTTPServer(("127.0.0.1",PORT),H).serve_forever()
