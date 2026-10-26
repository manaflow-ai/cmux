"""The `--native-ui` suggestion rows of chromium-host-bench.py (p01-process-061): a page's autofill, password and
<datalist> suggestions, which the Chromium host sends as data (fork API 31's suggestion handler, p01-process-172) and
cmux draws in its own list under the field (ChromiumHostSuggestionList, feature `chromiumHostSuggestions`):

  autofill   a submitted form saves an autocomplete entry; typing its first letter in the field shows it in cmux's
             list beside the field, Down selects it there (Chromium's keys move cmux's highlight) and Return fills
             the field with it, after which the list is gone
  password   a click in a new-password field shows Chromium's password rows (the strong password offer) in cmux's
             list beside the field; Escape closes it
  datalist   (the native_ui row, with the feature on) the <input list> options come as cmux's list, not a page popup

Each reads `debug.cef` `host_suggestions` (null unless the host draws suggestions in cmux): the shown lists, each
with its row kinds and Chromium SuggestionTypes, its highlight, its screen frame and the field's.
"""
import time

# The probe's fields (chromium_host_native_ui.PAGE): a form whose submission saves an autocomplete entry, and a
# new-password field.
FIELDS = """<form id=af method=get style="position:fixed;top:220px;left:40px;margin:0">
<input id=name name=cmux_native_ui_name autocomplete=on style="position:static"></form>
<input id=newpw type=password autocomplete=new-password style="top:280px">
"""

ENTRY = "alpha"
# autofill::SuggestionType::kDatalistEntry (components/autofill/core/browser/suggestions/suggestion_type.h).
DATALIST_ENTRY = 20
SHOW_DEADLINE_S = 10.0
ROWS = ("autofill", "password")


def host_suggestions(rpc):
    """`debug.cef` `host_suggestions`: None unless the host draws suggestions in cmux, else the lists shown now."""
    return (rpc("debug.cef") or {}).get("host_suggestions")


def drawn(rpc):
    return host_suggestions(rpc) is not None


def shown(rpc, types=None):
    """The first list on screen with an entry row (of one of `types` when given), or None."""
    for listed in host_suggestions(rpc) or []:
        entries = [t for kind, t in zip(listed.get("kinds") or [], listed.get("types") or []) if kind == "entry"]
        if listed.get("frame") and entries and (types is None or any(t in types for t in entries)):
            return listed
    return None


def beside_field(listed):
    """The list sits under its field or over it (AppKit screen points, y up), never across it."""
    frame, field = listed.get("frame"), listed.get("field")
    if not frame or not field:
        return False
    below = frame[1] + frame[3] <= field[1] + 0.5
    above = frame[1] >= field[1] + field[3] - 0.5
    return below or above


def wait_list(rpc, wait, types=None):
    started = time.time()
    listed = wait(lambda: shown(rpc, types), SHOW_DEADLINE_S)
    return listed, (round((time.time() - started) * 1000, 1) if listed else None)


def key(rpc, name):
    rpc("debug.key", {"target": "page", "key": name})


def datalist(rpc, wait):
    """The datalist row with the feature on: its options in cmux's list."""
    listed, show_ms = wait_list(rpc, wait, (DATALIST_ENTRY,))
    return {"ok": bool(listed and beside_field(listed)), "list": listed, "show_ms": show_ms,
            "host_suggestions": None if listed else host_suggestions(rpc)}


def autofill(rpc, wait, page_eval, click):
    page_eval(f"(() => {{ document.getElementById('name').value = '{ENTRY}'; "
              "document.getElementById('af').requestSubmit(); return true; })()")
    if not wait(lambda: page_eval("location.search.includes('cmux_native_ui_name') && document.readyState === 'complete' "
                                  "&& !!document.getElementById('name')"), 30, 0.5):
        return {"ok": False, "error": "the form's submission never loaded"}
    click("name")
    key(rpc, ENTRY[0])
    listed, show_ms = wait_list(rpc, wait)
    if not listed:
        return {"ok": False, "error": "no suggestion list for the saved entry", "host_suggestions": host_suggestions(rpc)}
    placed = beside_field(listed)
    key(rpc, "down")
    selected = wait(lambda: (shown(rpc) or {}).get("highlighted") == 0, 5)
    key(rpc, "return")
    filled = wait(lambda: page_eval("document.getElementById('name').value") == ENTRY and shown(rpc) is None, 5)
    return {"ok": bool(placed and selected and filled), "list": listed, "show_ms": show_ms, "beside_field": placed,
            "key_selected": bool(selected), "accepted": bool(filled)}


def password(rpc, wait, click):
    click("newpw")
    listed, show_ms = wait_list(rpc, wait)
    if not listed:
        return {"ok": False, "error": "no suggestion list for the new-password field", "host_suggestions": host_suggestions(rpc)}
    placed = beside_field(listed)
    key(rpc, "escape")
    closed = wait(lambda: shown(rpc) is None, 5)
    return {"ok": bool(placed and closed), "list": listed, "show_ms": show_ms, "beside_field": placed, "closed": bool(closed)}


def run(rpc, wait, page_eval, click):
    """The autofill and password rows; the form's submission reloads the probe, so they run last."""
    if not drawn(rpc):
        reason = "no host suggestions: host mode is not live in this build or chromiumHostSuggestions is off"
        return {name: {"ok": False, "not_run": reason} for name in ROWS}
    return {"autofill": autofill(rpc, wait, page_eval, click), "password": password(rpc, wait, click)}
