"""CLOSE MOTION steps (task close-motion, Lawrence cmux-ad m48 2026-11-06: one close decision per case: tab, last tab of a
pane, last tab of a workspace). The cases are video-cases/gen_close.py. Local kit only (never pushed).

driver.py loads this file (load_extensions) on the mini, under /usr/bin/python3 (3.9, standard library only).

Steps (`do`):
  cm_close_tab {pane, which: first|selected|last}   closeTab of that tab of the named pane through the control socket
                                                     (action.run with a tab target: the CLI/socket entry point)
  cm_pin       {pane}                                palette.toggleTabPin on the named pane's selected tab
  cm_browser   {pane, engine: cef|webkit, bg}        openBrowser (engine) in the named pane: a new browser tab, shown;
                                                     waits until the pane shows a non-terminal tab
  cm_topo      {as}                                  the window's workspaces, the shown one, and per pane its tab count
                                                     (snapshot.get), kept in the recording's notes under AS
  cm_close_others {}                                 closeWorkspace (confirm) for every workspace but the shown one
"""
import json
import time

D = None
W = None  # ext_window: named panes
P = None  # ext_pixel: topology helpers, page url
V = None  # ext_video: the recording's notes


def install(driver):
    global D, W, P, V
    D = driver
    import ext_pixel
    import ext_video
    import ext_window
    W, P, V = ext_window, ext_pixel, ext_video


def _tabs(j, name):
    rec = W.named(j, name)
    pane = P._topology_pane(j, rec["pane"])
    return rec, pane, P._real_tabs(pane)


def step_cm_close_tab(j, step):
    rec, pane, tabs = _tabs(j, step["pane"])
    if not tabs:
        raise D.StepError(f"cm_close_tab {step['pane']}: no tab listed")
    which = step.get("which", "first")
    if which == "selected":
        tab = pane.get("selected_tab")
    elif which == "last":
        tab = tabs[-1]["id"]
    else:
        tab = tabs[0]["id"]
    if step.get("mark"):
        j.marks[step["mark"]] = D.now()
    sent = D.now()
    reply = j.app.rpc("action.run", {"action": "closeTab", "target": f"tab:{tab}"})
    returned = D.now()
    rec_v = getattr(j, "video", None)
    if rec_v is not None:
        rec_v["hid"].append({"kind": "socket", "path": "action.run closeTab", "args": {"tab": tab, "which": which},
                             "t_sent": round(sent, 6), "t_returned": round(returned, 6),
                             "host_offset_s": round(V._host_offset_s(), 6)})
    return {"tab": tab, "which": which, "selected": pane.get("selected_tab"), "tabs": [t["id"] for t in tabs], "reply": reply}


def step_cm_pin(j, step):
    rec, pane, tabs = _tabs(j, step["pane"])
    tab = pane.get("selected_tab")
    reply = j.app.rpc("action.run", {"action": "palette.toggleTabPin", "target": f"tab:{tab}"})
    time.sleep(0.5)
    _, pane, tabs = _tabs(j, step["pane"])
    row = next((t for t in tabs if t["id"] == tab), {})
    return {"tab": tab, "reply": reply, "tab_after": row}


def step_cm_browser(j, step):
    rec = W.named(j, step["pane"])
    focus = j.app.cmux("pane", rec["pane"], "focus")
    time.sleep(0.3)
    url = P.page_url(step.get("bg", "#00FF00"), step["pane"])
    engine = step.get("engine", "cef")
    opened = j.app.rpc("action.run", {"action": "openBrowser", "args": {"url": url, "engine": engine}, "focus": True})
    end = D.now() + float(step.get("timeout", 30))
    row = {}
    while D.now() < end:
        row = P._surface_row(j, rec["pane"]) or {}
        if row.get("selected_tab") and row.get("kind") != "terminal":
            time.sleep(float(step.get("settle", 2.0)))
            return {"pane": rec["pane"], "engine": engine, "opened": opened, "focus": focus, "kind": row.get("kind"),
                    "url": row.get("url")}
        time.sleep(0.2)  # orchestration poll of the app's own report
    raise D.StepError(f"cm_browser {step['pane']}: no browser tab shown within the timeout (pane {json.dumps(row)[:300]}; "
                      f"openBrowser {json.dumps(opened)[:200]})")


def topo(j):
    snap = j.app.rpc("snapshot.get") or {}
    topology = snap.get("topology") or {}
    out = {"workspaces": [], "windows": []}
    for w in topology.get("windows") or []:
        if isinstance(w, dict):
            out["windows"].append({k: w.get(k) for k in ("id", "workspace", "selected_workspace") if k in w})
    for ws in topology.get("workspaces") or []:
        panes = []
        for screen in ws.get("screens") or []:
            for pane in screen.get("panes") or []:
                if isinstance(pane, dict):
                    panes.append({"pane": pane.get("id"), "tabs": len(P._real_tabs(pane)), "selected_tab": pane.get("selected_tab")})
        out["workspaces"].append({"id": ws.get("id"), "title": ws.get("title") or ws.get("name"), "panes": panes})
    return out


def step_cm_topo(j, step):
    t = topo(j)
    rec = getattr(j, "video", None)
    if rec is not None:
        rec["notes"][step["as"]] = {"t": D.now(), "topology": t}
    return {"workspaces": len(t["workspaces"]), "windows": t["windows"],
            "panes": [[p["tabs"] for p in w["panes"]] for w in t["workspaces"]][-6:]}


def step_cm_close_others(j, step):
    t = topo(j)
    shown = {w.get("workspace") or w.get("selected_workspace") for w in t["windows"]}
    closed = []
    for ws in t["workspaces"]:
        if ws["id"] in shown or not ws["id"]:
            continue
        try:
            j.app.rpc("action.run", {"action": "closeWorkspace", "target": f"workspace:{ws['id']}", "args": {"confirm": True}})
            closed.append(ws["id"])
        except D.StepError as error:
            closed.append({"id": ws["id"], "error": str(error)[:160]})
        time.sleep(0.3)
    time.sleep(1.0)
    return {"shown": sorted(x for x in shown if x), "closed": closed, "left": len(topo(j)["workspaces"])}


STEPS = {"cm_close_tab": step_cm_close_tab, "cm_pin": step_cm_pin, "cm_browser": step_cm_browser, "cm_topo": step_cm_topo,
         "cm_close_others": step_cm_close_others}
CONDITIONS = {}


if __name__ == "__main__":
    print(json.dumps(sorted(STEPS)))
