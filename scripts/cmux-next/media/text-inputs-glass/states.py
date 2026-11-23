"""Text inputs on Liquid Glass: capture states for every text field of the app (user 2026-11-21: "show me more, like how
text input will look with liquid glass"): the Chief composer, Home's sidebar search, the agent chat's composer and find
bar, the New Tab composer (web and native), the omnibar, the browser's and the terminal's find bars, the sidebar's
rename field and Settings' search field, each in light and dark over art and over a plain backdrop, at 2x, in four
states: idle and empty, focused and empty (placeholder and caret), typed (caret at the end) and a selection.

A tour holds at most 30 steps (tour.py), so this writes one state per input and backdrop into OUT:

    python3 scripts/cmux-next/media/text-inputs-glass/states.py OUT
    cmux-ci capture SHA --state OUT/chief-art.json --mac --display-scale 2 --whole-host   # then --job JOB for the rest

The app launches activated (the shot steps are CuaDriver shot objects) and debug.text_field key makes its window key, so carets, selections and focus rings draw as a person sees them:
a whole capture mini, never a shared one. Fields are driven by debug.text_field (native) and debug.page select / type /
blur (web).
"""
import json, re, sys
TEXT = "Liquid Glass inputs"
SEL = (7, 12)  # "Glass"
def rpc(method, params=None, **kw):
    return {"rpc": {"method": method, "params": params or {}}, **kw}
def cmux(*argv, **kw):
    return {"cmux": list(argv), **kw}
def step(title, body=None, wait=1.2, shot="", optional=None):
    s = {"title": title}
    if body: s.update(body)
    s["wait"] = wait
    # A shot object (a CuaDriver display shot of the window, back as shots/NAME.png) also makes pr-capture launch the
    # app activated, so the window is key and carets, selections and focus rings draw as a person sees them.
    if shot:
        s["shot"] = {"name": "-".join(re.findall(r"[a-z0-9]+", f"{title.split(']')[0]} {shot}".lower()))[:32], "with_popups": True, "dismiss": False}
    else:
        s["shot"] = False
    if optional: s["optional"] = optional
    return s

def native_states(label, focus, tag, opt=None):
    """idle (nothing focused), focused empty (placeholder + caret), typed (caret at end), selection."""
    return [
        step(f"{tag} {label}: idle, empty", rpc("debug.text_field", {"blur": True}), shot="idle", optional=opt),
        step(f"{label} focus", focus, shot=False, wait=0.8, optional=opt),
        step(f"{tag} {label}: focused, empty (placeholder, caret)", rpc("debug.text_field", {"text": ""}), shot="empty", optional=opt),
        step(f"{tag} {label}: typed text, caret at the end", rpc("debug.text_field", {"text": TEXT}), shot="typed", optional=opt),
        step(f"{tag} {label}: selection", rpc("debug.text_field", {"from": SEL[0], "to": SEL[1]}), shot="select", optional=opt),
        step(f"{label}: clear", rpc("debug.text_field", {"text": ""}), shot=False, wait=0.3, optional=opt),
        step(f"{label}: release the keyboard", rpc("debug.text_field", {"blur": True}), shot=False, wait=0.3, optional=opt),
    ]

def web_states(label, page, selector, tag, focus=None, opt=None, pick=None):
    p = lambda **kw: {"page": page, **({"selector": selector} if selector else {}), **(pick or {}), **kw}
    out = [step(f"{tag} {label}: idle, empty", rpc("debug.page", p(action="blur", clear=True)), shot="idle", optional=opt)]
    if focus: out.append(step(f"{label} focus", focus, shot=False, wait=0.8, optional=opt))
    out += [
        step(f"{tag} {label}: focused, empty (placeholder, caret)", rpc("debug.page", p(action="select", **{"from": 0, "to": 0})), shot="empty", optional=opt),
        step(f"{label}: type", rpc("debug.page", p(action="type", text=TEXT)), shot=False, wait=0.3, optional=opt),
        step(f"{tag} {label}: typed text, caret at the end", rpc("debug.page", p(action="select", **{"from": len(TEXT)})), shot="typed", optional=opt),
        step(f"{tag} {label}: selection", rpc("debug.page", p(action="select", **{"from": SEL[0], "to": SEL[1]})), shot="select", optional=opt),
        step(f"{label}: clear", rpc("debug.page", p(action="blur", clear=True)), shot=False, wait=0.3, optional=opt),
    ]
    return out

# The chat page's web view takes the window's keyboard (Home's composer has it otherwise), as a click in the chat.
WEB_KEY = lambda: step("The chat page has the keyboard", rpc("debug.text_field", {"focus": "AgentPaneView"}), shot=False, wait=0.5)
KEY = lambda: step("Key window, app active (caret and focus rings draw)", rpc("debug.text_field", {"key": True}), shot=False, wait=0.6)

def g_chief(tag):
    return [step("Home", cmux("action", "run", "home.show"), wait=4, shot=False), KEY()] \
        + native_states("Chief composer (native)", rpc("debug.home.drive", {"action": "focus"}), tag)

def g_home_search(tag):
    # The Chief fills Home and the list (with its search field) is folded until Chats shows it; a
    # Home with the Chief alone folds it too. Three fixture chats and Chats on show the field.
    return [step("Home", cmux("action", "run", "home.show"), wait=4, shot=False),
            step("Three more chats", rpc("debug.home.sidebar_fixture", {"count": 3, "pinned": 0}), shot=False, wait=0.5),
            step("Chats shows the list", rpc("debug.home.sidebar_fixture", {"chatList": True}), shot=False, wait=1), KEY()] \
        + native_states("Home sidebar search (native)", rpc("debug.text_field", {"focus": "CmuxSidebarSearchField"}), tag)

def chat_setup(tag):
    return [step("A chat workspace", cmux("action", "run", "newTab", "--name", f"Chat {tag}", "--focus", "--cwd", "/tmp"), shot=False, wait=1.5),
            step("Open a chat", cmux("agent", "new-chat", "--cwd", "/tmp"), shot=False, wait=5), KEY(), WEB_KEY()]

def g_chat(tag):
    return chat_setup(tag) + web_states("Agent chat composer (web)", "cmux.agent", ".acpmux-composer .ProseMirror", tag)

def g_chat_find(tag):
    # Find works over a transcript: one prompt first (the showcase daemon answers it).
    send = [step("A prompt", rpc("debug.page", {"page": "cmux.agent", "action": "type", "selector": ".acpmux-composer .ProseMirror", "text": "Show me Liquid Glass inputs"}), shot=False, wait=0.5),
            step("Send it", rpc("debug.page", {"page": "cmux.agent", "action": "click", "selector": ".acpmux-composer .acpmux-send.acpmux-send-ready"}), shot=False, wait=5)]
    # A click in the transcript gives the chat page the window's keyboard (Home's composer has it), as a person's would.
    # The app's Find (Cmd-F) on the chat tab, as a person opens it: the page's command stream has no Find listener.
    # A trusted click in the transcript gives the chat pane the keyboard, so Find goes to it and not to the terminal beside it.
    return chat_setup(tag)[:-2] + send + [step("A click in the transcript", rpc("debug.page", {"page": "cmux.agent", "action": "press", "x": 240, "y": 160, "native": True}), shot=False, wait=0.6),
                                          KEY(), step("Chat find bar opens", cmux("action", "run", "find"), shot=False, wait=1)] \
        + web_states("Chat find bar (web)", "cmux.agent", ".acpmux-find__bar input", tag)

def g_newtab_web(tag):
    # The New Tab's field is .nt-field (.acpmux-newtab-field is the classic New Tab page's). The app's
    # first chat page draws it; the second is the next tab's warm spare, which also has a field and
    # which a probe picks while the window is not key. The dark pass keeps the same tab.
    first = {"instance": 1}
    opens = page_tab(tag) if "light" in tag else [KEY()]
    return opens + [step("The New Tab field draws", rpc("debug.page", {"page": "cmux.agent", "action": "wait", "selector": ".nt-field .ProseMirror", "timeout_ms": 10000, **first}), shot=False, wait=0.2)] \
        + web_states("New tab composer (web)", "cmux.agent", ".nt-field .ProseMirror", tag, pick=first)

def page_tab(tag):
    return [step("A new tab, as Cmd-T opens it", cmux("action", "run", "newTab.page", "--focus"), shot=False, wait=3), KEY()]

def web_tab(tag):
    name = "Web " + " ".join(re.findall(r"[a-z]+", tag))
    return name, [step("A browser tab", cmux("tab", "create", "browser", "--url", "https://example.com", "--name", name), shot=False, wait=4),
                  step("Select it", cmux("tab", name, "focus"), shot=False, wait=1.5), KEY()]

def g_newtab_native(tag):
    return [step("Native new tab page on", cmux("settings", "set", "tabs.nativeNewTabPage", "true"), shot=False, wait=1)] + page_tab(tag) \
        + native_states("New tab composer (native)", rpc("debug.new_tab", {"action": "state"}), tag)

def g_omnibar(tag):
    name, setup = web_tab(tag)
    return setup + native_states("Omnibar (native)", rpc("debug.text_field", {"focus": "AddressField"}), tag) \
        + [step("Close the browser tab", cmux("tab", name, "close"), shot=False, wait=1)]

def g_browser_find(tag):
    # In a workspace of its own, shown and selected, so Find goes to the browser pane and not to the
    # Chief or the terminal beside it; Find needs the key window, which activation makes a beat later.
    name = "Web " + " ".join(re.findall(r"[a-z]+", tag))
    setup = [step("A browser workspace", cmux("workspace", "new", "--name", f"Find {tag}"), shot=False, wait=1.5),
             step("Show it", cmux("workspace", f"name:Find {tag}", "focus"), shot=False, wait=1.5),
             step("A browser tab", cmux("tab", "create", "browser", "--url", "https://example.com", "--name", name), shot=False, wait=4),
             step("Select it", cmux("tab", name, "focus"), shot=False, wait=1.5), KEY(),
             step("The window is key (activation lands a beat later)", rpc("debug.text_field", {"key": True}), shot=False, wait=2),
             step("Browser find bar opens", cmux("action", "run", "find"), shot=False, wait=1)]
    # The dark pass keeps the light pass's tab and its open bar (the appearance changes under it).
    if "dark" in tag: setup = [KEY()]
    return setup + native_states("Browser find bar (native)", rpc("debug.text_field", {"focus": "Find in page"}), tag)

def g_term_find(tag):
    return [step("A terminal workspace", cmux("workspace", "new", "--name", f"Term {tag}"), shot=False, wait=1.5),
            step("Show it", cmux("workspace", f"name:Term {tag}", "focus"), shot=False, wait=1.5), KEY()] \
        + [step("Terminal find bar opens", cmux("action", "run", "find"), shot=False, wait=1)] \
        + native_states("Terminal find bar (native)", rpc("debug.text_field", {"focus": "Find"}), tag)  # the bar's field, by its placeholder  # the bar's field (it opens without the keyboard)

def g_rename(tag):
    return [step("A workspace to rename", cmux("workspace", "new", "--name", f"Rename {tag}"), shot=False, wait=1.5),
            step("Show it", cmux("workspace", f"name:Rename {tag}", "focus"), shot=False, wait=1.5), KEY()] \
        + native_states("Sidebar rename field (native)", rpc("debug.sidebar_rename", {}), tag)[:-2] \
        + [step("Rename: escape", rpc("debug.key", {"key": "escape"}), shot=False, wait=0.5)]

def g_settings(tag):
    return [step("Settings", cmux("action", "run", "openSettings"), shot=False, wait=4), KEY()] \
        + web_states("Settings search field (web)", "cmux.settings", None, tag,
                     focus=rpc("debug.page", {"page": "cmux.settings", "action": "command", "command": "focusSearch"}))

GROUPS = {"chief": g_chief, "home-search": g_home_search, "chat": g_chat, "chat-find": g_chat_find,
          "newtab-web": g_newtab_web, "newtab-native": g_newtab_native, "omnibar": g_omnibar,
          "browser-find": g_browser_find, "terminal-find": g_term_find, "rename": g_rename, "settings": g_settings}

import os
out = sys.argv[1]
os.makedirs(out, exist_ok=True)
for name, group in GROUPS.items():
    for backdrop in ("art", "plain"):
        steps = [step("Launch", wait=4, shot=False)]
        for mode in ("light", "dark"):
            steps.append(step(mode, rpc("debug.text_field", {"appearance": mode}), shot=False, wait=2))
            steps += group(f"[{backdrop} {mode}]")
        state = {"title": f"Text inputs on Liquid Glass: {name}, {backdrop} backdrop, light and dark, 2x (idle, focused empty, typed, selection)",
                 "launch_args": ["--showcase"], "displayScale": 2, "wholeHost": True,
                 "settings": {"appearance": {"background": "hokusai-great-wave"}} if backdrop == "art" else {},
                 "steps": steps}
        json.dump(state, open(os.path.join(out, f"{name}-{backdrop}.json"), "w"), indent=1)
        print(name, backdrop, len(steps), sum(1 for s in steps if s.get("shot", True)))
