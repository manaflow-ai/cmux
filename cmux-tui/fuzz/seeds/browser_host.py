"""Seeds of the two browser host targets, whose input is a
`#[derive(Arbitrary)]` `Input` (fuzz_targets/browser_host_cdp_evaluate.rs and
browser_host_gate_fetch.rs). Each seed is an `Input` encoded with
arbitrary_bytes.py; the classes below follow the Rust types field for
field, so a change to a type there needs the same change here (a seed that
no longer decodes to what it says only makes a weaker start, never a false
finding).
"""

import json

from arbitrary_bytes import Arbitrary


def text(value):
    return json.dumps(value, separators=(",", ":"))


# browser_host_cdp_evaluate.rs

AGENT, PAGE, HOST = ("Agent",), ("Page",), ("Host",)
TAB, BROWSER = ("Tab",), ("Browser",)
WORLDS = ["Agent", "Page", "Host", "Other"]
SESSIONS = ["Tab", "Other", "Browser"]
CALLS = ["Evaluate", "FramesList", "Focused", "ContentFrame", "ContentFrames", "OwnerBox"]
EVENTS = ["ContextCreated", "ContextDestroyed", "ContextsCleared", "FrameNavigated",
          "FrameDetached", "AttachedFrame", "DetachedFromTarget", "Raw"]


def other(name):
    return ("Other", name)


def evaluate(world=AGENT, source="() => document.title", frame=None, handles=(), args=(),
             await_promise=None, closed_roots=False, raw=False, timeout_ms=63, unknown_tab=False):
    return ("Evaluate", dict(world=world, frame=frame, source=source, handles=list(handles),
                             args=list(args), await_promise=await_promise,
                             closed_roots=closed_roots, raw=raw), timeout_ms, unknown_tab)


def call(name, timeout_ms=63, unknown_tab=False, **fields):
    return (name, fields, timeout_ms, unknown_tab)


def step(result=None, error=None, events=(), session=TAB):
    """One fuzzed answer: `result` is a reply's result (a value, or JSON
    text when a str), `error` a (code, message)."""
    return (session, list(events), result, error)


def put_world(out, world):
    out.variant(WORLDS.index(world[0]), len(WORLDS))
    if world[0] == "Other":
        out.string(world[1])


def put_session(out, session):
    out.variant(SESSIONS.index(session[0]), len(SESSIONS))
    if session[0] == "Other":
        out.string(session[1])


def put_call(out, driver_call):
    name, fields, timeout_ms, unknown_tab = driver_call
    out.variant(CALLS.index(name), len(CALLS))
    if name == "Evaluate":
        out.option(fields["world"], lambda world: put_world(out, world))
        out.option(fields["frame"], out.string)
        out.string(fields["source"])
        out.vec(fields["handles"], out.string)
        out.vec(fields["args"], out.string)
        out.option(fields["await_promise"], out.bool)
        out.bool(fields["closed_roots"])
        out.bool(fields["raw"])
    elif name == "ContentFrame":
        out.string(fields["handle"])
        out.option(fields.get("frame"), out.string)
    elif name == "ContentFrames":
        out.vec(fields["handles"], out.string)
    elif name == "OwnerBox":
        out.string(fields["frame"])
    out.u8(timeout_ms)
    out.bool(unknown_tab)


def put_event(out, event):
    name, fields = event
    out.variant(EVENTS.index(name), len(EVENTS))
    if name == "ContextCreated":
        out.i64(fields["id"])
        out.option(fields.get("world"), lambda world: put_world(out, world))
        out.option(fields.get("frame"), out.string)
        out.bool(fields.get("default", False))
    elif name == "ContextDestroyed":
        out.i64(fields["id"])
    elif name == "FrameNavigated":
        out.option(fields.get("frame"), out.string)
        out.option(fields.get("parent"), out.string)
        out.string(fields["loader"])
        out.string(fields["url"])
    elif name == "FrameDetached":
        out.option(fields.get("frame"), out.string)
    elif name == "AttachedFrame":
        out.string(fields["session"])
        out.string(fields["frame"])
        out.bool(fields["waiting"])
    elif name == "DetachedFromTarget":
        put_session(out, fields["session"])
    elif name == "Raw":
        out.string(fields["method"])
        out.string(fields["params"])


def put_step(out, answer):
    session, events, result, error = answer
    put_session(out, session)
    out.vec(events, lambda event: put_event(out, event))
    if error is None:
        out.variant(0, 2)
        out.string(result if isinstance(result, str) else text(result))
    else:
        out.variant(1, 2)
        out.i32(error[0])
        out.string(error[1])


def cdp_input(calls, answers):
    out = Arbitrary()
    out.vec(calls, lambda driver_call: put_call(out, driver_call))
    out.vec(answers, lambda answer: put_step(out, answer))
    return out.finish()


def value(result):
    return {"result": result}


AGENT_CURRENT = step(value({"type": "boolean", "value": True}))
MAIN = {"id": "F-T1", "loaderId": "L0", "url": "https://a.test/", "securityOrigin": "https://a.test"}
CHILD = {"id": "F2", "parentId": "F-T1", "loaderId": "L1", "url": "https://b.test/",
         "securityOrigin": "https://b.test"}
TREE = step({"frameTree": {"frame": MAIN, "childFrames": [{"frame": CHILD}]}})
STALE = (-32000, "Cannot find context with specified id")


def browser_host_cdp_evaluate():
    return [
        # The agent world: the agent check, then the call; the value as JSON text.
        cdp_input([evaluate(raw=True)], [
            AGENT_CURRENT,
            step(value({"type": "object", "value": {"b": 1, "a": [2, 3.5, None]}})),
        ]),
        # The page world with a handle moved over from the agent world.
        cdp_input([evaluate(world=PAGE, source="(el, n) => el.tagName + n", handles=["h1"],
                            args=["1", "\"x\""], await_promise=False, raw=True)], [
            AGENT_CURRENT,
            step(value({"type": "object", "subtype": "node", "objectId": "o1"})),
            step({"node": {"nodeId": 0, "backendNodeId": 5, "nodeName": "DIV"}}),
            step({"object": {"type": "object", "subtype": "node", "objectId": "o2"}}),
            step(value({"type": "string", "value": "DIV1x"})),
        ]),
        # The host world is created, a script throws, then the context is reused.
        cdp_input([evaluate(world=HOST, source="() => { throw new Error('boom') }"),
                   evaluate(world=HOST, source="() => 1", closed_roots=True, raw=True)], [
            step({"executionContextId": 30}),
            step({"result": {"type": "object", "subtype": "error"},
                  "exceptionDetails": {"exceptionId": 1, "text": "Uncaught", "lineNumber": 0,
                                       "columnNumber": 7,
                                       "exception": {"type": "object", "description": "Error: boom"}}}),
            step(value({"type": "number", "value": 1})),
        ]),
        # A stale context: destroyed and replaced while the call runs.
        cdp_input([evaluate(), evaluate(world=other("utility")), evaluate(unknown_tab=True),
                   evaluate(world=None, frame="F-gone", timeout_ms=0)], [
            step(error=STALE, events=[
                ("ContextDestroyed", {"id": 20}),
                ("ContextCreated", {"id": 21, "world": AGENT}),
            ]),
            AGENT_CURRENT,
            step(value({"type": "undefined"})),
        ]),
        # An out-of-process frame attaches; its tree is grafted, then it goes.
        cdp_input([call("FramesList"), call("FramesList")], [
            step(events=[("AttachedFrame", {"session": "S2", "frame": "F2", "waiting": True})],
                 result={"frameTree": {"frame": MAIN, "childFrames": [{"frame": CHILD}]}}),
            step(session=other("S2"), result={"frameTree": {
                "frame": {"id": "F2", "loaderId": "L2", "url": "https://b.test/"},
                "childFrames": [{"frame": {"id": "F3", "parentId": "F2", "loaderId": "L3",
                                           "url": "https://c.test/"}}]}}),
            step(events=[("DetachedFromTarget", {"session": other("S2")}),
                         ("FrameDetached", {"frame": "F2"})],
                 result={"frameTree": {"frame": MAIN}}),
        ]),
        # Focus is in a child frame's document.
        cdp_input([call("Focused")], [
            step({"executionContextId": 31}),
            step(value({"type": "object", "subtype": "node", "objectId": "o5"})),
            step({"node": {"backendNodeId": 9, "frameId": "F2"}}),
            step({"executionContextId": 40}),
            step(value({"type": "string", "value": "https://b.test/"})),
        ]),
        # The frames an element and a list of elements show.
        cdp_input([call("ContentFrame", handle="h1"),
                   call("ContentFrames", handles=["h1", "h2"]),
                   call("ContentFrame", handle="h3", frame="F2")], [
            AGENT_CURRENT,
            step(value({"type": "object", "subtype": "node", "objectId": "o1"})),
            step({"node": {"backendNodeId": 5, "frameId": "F2"}}),
            step(value({"type": "object", "subtype": "node", "objectId": "o1"})),
            step({"node": {"backendNodeId": 5, "frameId": "F2"}}),
            step(value({"type": "object", "objectId": "o3"})),
            step({"node": {"backendNodeId": 6, "nodeName": "DIV"}}),
        ]),
        # The box of a frame's owner element.
        cdp_input([call("OwnerBox", frame="F2"), call("OwnerBox", frame="F-T1")], [
            TREE,
            step({"backendNodeId": 7}),
            step({"object": {"type": "object", "objectId": "o7"}}),
            step(value({"type": "object", "value": {"x": 1, "y": 2, "width": 300, "height": 150}})),
            TREE,
        ]),
        # A navigation clears the contexts; answers that are no object or no JSON.
        cdp_input([evaluate(world=PAGE, raw=True), evaluate(raw=True), call("FramesList")], [
            step(events=[
                ("FrameNavigated", {"loader": "L9", "url": "https://a.test/next"}),
                ("ContextsCleared", {}),
                ("ContextCreated", {"id": 50, "world": PAGE, "default": True}),
                ("ContextCreated", {"id": 51, "world": AGENT, "frame": "F-T1"}),
                ("Raw", {"method": "Page.lifecycleEvent",
                         "params": text({"frameId": "F-T1", "name": "load"})}),
                ("FrameNavigated", {"frame": "F4", "parent": "F-T1", "loader": "L4",
                                    "url": "about:blank"}),
                ("FrameDetached", {}),
                ("DetachedFromTarget", {"session": BROWSER}),
            ], result="[]"),
            step("not json"),
            step(error=(-32601, "'Page.getFrameTree' wasn't found")),
        ]),
    ]


# browser_host_gate_fetch.rs

CREDENTIALS = ["Omit", "SameOrigin", "Include", "Other"]
REPLIES = ["Response", "Redirect", "Error", "Raw"]
PUBLIC_IP = [93, 184, 216, 34]


def fetch(url, method=None, headers=(), body_base64=None, credentials=None, origin=None,
          timeout_ms=None, target_id=None, cell=0):
    return dict(url=url, method=method, headers=list(headers), body_base64=body_base64,
                credentials=credentials, origin=origin, timeout_ms=timeout_ms,
                target_id=target_id, cell=cell)


def response(status=200, body=b"ok", leak_secret=False, remote_ip=PUBLIC_IP, cors_relaxed=(),
             headers=(("content-type", "text/plain"),)):
    return ("Response", dict(status=status, body=body, leak_secret=leak_secret,
                             remote_ip=remote_ip, cors_relaxed=list(cors_relaxed),
                             headers=list(headers)))


def redirect(location, status=302, remote_ip=PUBLIC_IP):
    return ("Redirect", dict(status=status, location=location, remote_ip=remote_ip))


def put_pairs(out, pairs):
    def pair(item):
        out.string(item[0])
        out.string(item[1])
    out.vec(pairs, pair)


def put_fetch(out, request):
    out.string(request["url"])
    out.option(request["method"], out.string)
    put_pairs(out, request["headers"])
    out.option(request["body_base64"], out.string)

    def credentials(value):
        out.variant(CREDENTIALS.index(value[0]), len(CREDENTIALS))
        if value[0] == "Other":
            out.string(value[1])
    out.option(request["credentials"], credentials)
    out.option(request["origin"], out.string)
    out.option(request["timeout_ms"], out.u16)
    out.option(request["target_id"], out.string)
    out.u64(request["cell"])


def put_reply(out, reply):
    name, fields = reply
    out.variant(REPLIES.index(name), len(REPLIES))
    if name == "Response":
        out.u16(fields["status"])
        out.byte_vec(fields["body"])
        out.bool(fields["leak_secret"])
        out.option(fields["remote_ip"], out.ipv4)
        put_pairs(out, fields["cors_relaxed"])
        put_pairs(out, fields["headers"])
    elif name == "Redirect":
        out.u64(fields["status"])
        out.option(fields["location"], out.string)
        out.option(fields["remote_ip"], out.ipv4)
    elif name == "Error":
        out.u8(fields["code"])
        out.string(fields["message"])
    else:
        out.string(fields)


def gate_input(fetches, replies, remote=False, signed_in_profile=False, prohibit=False,
               allowed=None, block_ips=False, resolved=(PUBLIC_IP,)):
    out = Arbitrary()
    out.bool(remote)
    out.bool(signed_in_profile)
    out.bool(prohibit)
    out.option(allowed, lambda domains: out.vec(domains, out.string))
    out.bool(block_ips)
    out.vec(resolved, out.ipv4)
    out.vec(fetches, lambda request: put_fetch(out, request))
    out.vec(replies, lambda reply: put_reply(out, reply))
    return out.finish()


def browser_host_gate_fetch():
    auth = [("Authorization", "Bearer t"), ("accept", "*/*")]
    return [
        # One hop.
        gate_input([fetch("https://a.test/")], [response()]),
        # A redirect chain, same origin then cross origin with Authorization.
        gate_input([fetch("https://a.test/start", headers=auth, credentials=("Include",))], [
            redirect("https://a.test/next", status=301),
            redirect("/relative", status=307),
            redirect("https://b.test/final", status=308),
            response(body=b"final"),
        ]),
        # Answers that are no object, no JSON, an error, a redirect with no location.
        gate_input([fetch("https://a.test/raw"), fetch("https://a.test/text"),
                    fetch("https://a.test/garbage"), fetch("https://a.test/error")], [
            ("Raw", "[1,2]"), ("Raw", text("text")), ("Raw", "{not json"),
            ("Error", dict(code=1, message="the engine timed out")),
        ]),
        gate_input([fetch("https://a.test/x"), fetch("https://a.test/y")], [
            redirect(None, status=303), ("Raw", "null"), ("Raw", text({"status": "200"})),
        ]),
        # The policy: a prohibited domain, a redirect into it, an allowlist.
        gate_input([fetch("https://blocked.test/"), fetch("https://a.test/hop"),
                    fetch("https://c.test/")], [
            redirect("https://www.blocked.test/x"),
            response(),
        ], prohibit=True, allowed=["a.test", "*.blocked.test", "["]),
        # IP blocking: a private address, a loopback answer.
        gate_input([fetch("http://intranet.test/"), fetch("http://127.0.0.1:8080/"),
                    fetch("https://a.test/")], [
            response(remote_ip=[127, 0, 0, 1]),
            redirect("http://10.0.0.1/", remote_ip=[10, 0, 0, 1]),
        ], block_ips=True, resolved=([10, 0, 0, 5], PUBLIC_IP)),
        # The secret in a body; relaxed CORS; a signed-in remote session.
        gate_input([fetch("https://a.test/me", credentials=("SameOrigin",), origin="https://a.test",
                          target_id="T1", cell=7)], [
            response(leak_secret=True, cors_relaxed=[("https://a.test/me", "credentials")],
                     headers=[("set-cookie", "s=1"), ("access-control-allow-origin", "*")]),
        ], remote=True, signed_in_profile=True),
        # Forbidden headers, a body, a bad credentials mode, a timeout.
        gate_input([fetch("https://a.test/post", method="POST", body_base64="aGVsbG8=",
                          headers=[("Host", "evil.test"), ("Cookie2", "x"), ("Sec-Fetch-Mode", "cors"),
                                   ("Proxy-Authorization", "x"), ("Content-Length", "9")],
                          credentials=("Other", "bogus"), timeout_ms=100),
                    fetch("not a url", method="GET\r\n", body_base64="%%%",
                          credentials=("Omit",), timeout_ms=0)], [
            response(status=201),
        ]),
        # More redirects than MAX_REDIRECTS.
        gate_input([fetch("https://a.test/0")],
                   [redirect(f"https://a.test/{n}") for n in range(1, 8)]),
    ]
