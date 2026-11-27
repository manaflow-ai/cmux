#!/usr/bin/env python3
"""The workspace that one `action.run` made, for the bench tools that make a workspace and then go to it
(chrome_parity.py, parity_appclock.py, session_real.py).

`action.run` answers with `created`, the public ids of what the run made. An app before 650fd32b59b9 sends
`create-workspace` and then `create-terminal`, and `created` is [ws_, tab_, term_]. From 650fd32b59b9 the app
sends one `create-terminal` that makes the workspace too, and `created` holds only the tab and the terminal:

    {'action': 'workspace.newAtBottom', 'args': {}, 'created': ['tab_17fc...', 'term_f67f...'], ...}

A tool that needs a ws_ id in `created` then runs no row on such an app. This helper reads both answers.
"""
from __future__ import annotations


def made_workspace(reply, topology):
    """The id of the workspace that the run of `reply` made; None when it made none.

    `reply` is the result of `action.run`. `topology` is a function with no argument that gives the `topology`
    object of `snapshot.get`; it is called one time, and only when `created` names no workspace.

    With no ws_ id in `created`, the workspace is the one that holds the tabs that the run made, and it counts
    only when it holds no other tab: a tab that the run put in a workspace that was there before is not a new
    workspace. The reply comes after the app showed each object of `created` in its snapshot, so this is one
    read with no wait. The id is the one that the snapshot prints; an action takes it as its `workspace`.
    """
    created = [str(item) for item in (reply or {}).get("created") or []]
    named = next((item for item in created if item.startswith("ws_")), None)
    if named:
        return named
    made_tabs = {item for item in created if item.startswith("tab_")}
    if not made_tabs:
        return None
    for workspace in (topology() or {}).get("workspaces") or []:
        tabs = {str(tab.get("id")) for screen in workspace.get("screens") or []
                for pane in screen.get("panes") or [] for tab in pane.get("tabs") or []}
        if made_tabs & tabs:
            return workspace.get("id") if tabs == made_tabs else None
    return None
