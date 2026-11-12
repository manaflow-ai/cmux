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
    """The id of the workspace that the run of `reply` made; None when `created` names none.

    `reply` is the result of `action.run`. `topology` is a function with no argument that gives the `topology`
    object of `snapshot.get`; it is not read yet.
    """
    created = [str(item) for item in (reply or {}).get("created") or []]
    return next((item for item in created if item.startswith("ws_")), None)
