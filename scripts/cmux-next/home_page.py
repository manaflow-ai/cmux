"""Drive the React Home transcript (the `cmux.home-messages` page) for the live Home checks.

The native transcript and its `debug.home.drive` route are gone (#37777). The checks that typed into
Home, sent and read the transcript back now do it through `debug.page`, the generic verb every React
page answers, with the old action names and result shapes:

- `focus`: focuses the composer's field;
- `type` (`text`): inserts `text` in the field as typed input;
- `send`: clicks Send. An empty draft is refused (`{"ok": false, "refused": "empty"}`), never sent;
- `texts` (`limit`): the shown message texts, oldest first (each cut at 120 characters by the page query);
- `rows`: the shown message rows (`kind` text, `key`, `outgoing`, `text`);
- `geometry`: `ok` once the composer is drawn (the page has no native frames to report);
- `scroll` (`dy`): scrolls the oldest shown message into view for a negative `dy`, else the newest;
- `link` (`prefix`): clicks the first shown link whose href starts with `prefix`.

Any other action (the native view's pixel and layout probes) answers `{"ok": false, "error": ...}`.
`rpc(method, params)` is the caller's control-socket call and returns the result object.
"""
PAGE = "cmux.home-messages"
FIELD = ".mt-field-editor"


def page(rpc, action, **params):
    return rpc("debug.page", {"page": PAGE, "action": action, **params}) or {}


def elements(rpc, selector):
    return page(rpc, "query", selector=selector).get("elements") or []


def drive(rpc, params):
    """One old `debug.home.drive` call (`params["action"]`) on the React Home page."""
    action = params.get("action")
    if action == "focus":
        return {"ok": bool(page(rpc, "click", selector=FIELD).get("clicked"))}
    if action == "type":
        return {"ok": bool(page(rpc, "type", selector=FIELD, text=params.get("text", "")).get("inserted"))}
    if action == "send":
        button = elements(rpc, ".mt-send")
        if not button:
            return {"ok": False, "error": "no Home composer is shown"}
        if "ready" not in button[0].get("classes", []):
            return {"ok": False, "refused": "empty"}
        return {"ok": bool(page(rpc, "click", selector=".mt-send").get("clicked"))}
    if action == "texts":
        texts = [e.get("text", "") for e in elements(rpc, ".mt-bubble-row .mt-text")]
        return {"ok": True, "texts": texts[-int(params.get("limit", 50)):]}
    if action == "rows":
        rows = elements(rpc, ".mt-bubble-row")
        return {"ok": True, "rows": [{"kind": "text", "key": (r.get("data") or {}).get("message", ""), "outgoing": "out" in r.get("classes", []),
                                      "text": r.get("text", "")} for r in rows]}
    if action == "geometry":
        return {"ok": bool(elements(rpc, ".mt-compose")), "geometry": {}}
    if action == "scroll":
        older = float(params.get("dy", 1)) < 0
        selector = ".mt-bubble-row:first-of-type" if older else ".mt-bubble-row:last-of-type"
        return {"ok": "error" not in page(rpc, "scroll", selector=selector, block="start" if older else "end")}
    if action == "link":
        selector = f'.mt-transcript a[href^="{params.get("prefix", "https://")}"]'
        found = elements(rpc, selector)
        clicked = bool(found) and bool(page(rpc, "click", selector=selector).get("clicked"))
        return {"ok": clicked, "url": None}
    return {"ok": False, "error": f"debug.home.drive {action} was a native-transcript probe; the React Home has none"}
