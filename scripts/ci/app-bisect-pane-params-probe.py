#!/usr/bin/env python3
"""A probe for app_build_bisect.py that needs no Mac: does the agent page at COMMIT send a param the app relay's
params rule refuses?

    app-bisect-pane-params-probe.py COMMIT [METHOD ...]     (only these methods; default every known_params one)

The class it checks: the page (webviews/src/agent-session/acpmux/direct.ts) adds a key to a request the app relays,
and the relay's rule (cmux-tui/crates/cmux-agent-pane-policy/policy.json `known_params`, mirrored by Swift's
AcpmuxPaneMethods+Params.swift) does not know it, so the app refuses every such request as transport.intent_invalid
("agent pane params rule refused method=..."). On 2026-11-21 that refused every chat's initialize: the chat said
"Something went wrong" and the model picker read only "Model". It reads the tree at COMMIT with git, so it runs
anywhere with the history; a GUI probe (app-bisect-probe.sh) checks the running app instead.

For each method in known_params, the top-level keys of each object literal the page sends with
`request("METHOD", { ... })` are compared with the rule's `params`, and `_meta.acpmux`'s keys with its `acpmux`.
A call that passes a helper's result (`request("initialize", initializeParams())`) is read from that helper's
returned literal.

Exit 0: every key is known (good). 1: a key the rule refuses (bad; printed). 125: COMMIT has no policy file or page.
"""
from __future__ import annotations

import json
import re
import subprocess
import sys

POLICY = "cmux-tui/crates/cmux-agent-pane-policy/policy.json"
PAGE = "webviews/src/agent-session/acpmux/direct.ts"


def show(commit: str, path: str) -> str | None:
    done = subprocess.run(["git", "show", f"{commit}:{path}"], capture_output=True, text=True)
    return done.stdout if done.returncode == 0 else None


def literal(text: str, start: int) -> str | None:
    """The balanced `{...}` starting at text[start]."""
    if start >= len(text) or text[start] != "{":
        return None
    depth, i, quote = 0, start, None
    while i < len(text):
        ch = text[i]
        if quote:
            if ch == "\\":
                i += 1
            elif ch == quote:
                quote = None
        elif ch in "\"'`":
            quote = ch
        elif text.startswith("//", i):
            i = text.find("\n", i)
            if i < 0:
                return None
            continue
        elif ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return text[start:i + 1]
        i += 1
    return None


def top_keys(obj: str) -> dict[str, str]:
    """Top-level keys of an object literal, each with its value text (a `...spread` is skipped)."""
    keys: dict[str, str] = {}
    body, depth, i, quote, key_start = obj[1:-1], 0, 0, None, 0
    parts, cur = [], []
    while i < len(body):
        ch = body[i]
        if quote:
            cur.append(ch)
            if ch == "\\" and i + 1 < len(body):
                cur.append(body[i + 1])
                i += 1
            elif ch == quote:
                quote = None
        elif body.startswith("//", i):
            j = body.find("\n", i)
            i = len(body) if j < 0 else j
            continue
        elif ch in "\"'`":
            quote = ch
            cur.append(ch)
        elif ch in "{[(":
            depth += 1
            cur.append(ch)
        elif ch in "}])":
            depth -= 1
            cur.append(ch)
        elif ch == "," and depth == 0:
            parts.append("".join(cur))
            cur = []
        else:
            cur.append(ch)
        i += 1
    parts.append("".join(cur))
    del key_start
    for part in parts:
        part = part.strip()
        if not part or part.startswith("..."):
            continue
        m = re.match(r"""^["']?([A-Za-z_$][\w$]*)["']?\s*(?::\s*(.*))?$""", part, re.S)
        if m:
            keys[m.group(1)] = (m.group(2) or m.group(1)).strip()
    return keys


def sent(page: str, method: str) -> list[dict[str, str]]:
    out = []
    for m in re.finditer(r"""request\(\s*["']""" + re.escape(method) + r"""["']\s*,\s*""", page):
        at = m.end()
        if page[at] == "{":
            obj = literal(page, at)
        else:
            helper = re.match(r"([A-Za-z_$][\w$]*)\(\s*\)", page[at:])
            obj = None
            if helper:
                fn = re.search(r"function\s+" + re.escape(helper.group(1)) + r"\s*\([^)]*\)[^{]*\{\s*return\s*",
                               page)
                obj = literal(page, fn.end()) if fn else None
        if obj:
            out.append(top_keys(obj))
    return out


def main(argv: list[str]) -> int:
    if not argv:
        print(__doc__, file=sys.stderr)
        return 3
    commit, only = argv[0], set(argv[1:])
    policy_text, page = show(commit, POLICY), show(commit, PAGE)
    if policy_text is None or page is None:
        print(f"{commit[:12]}: no {POLICY if policy_text is None else PAGE}")
        return 125
    known = (json.loads(policy_text).get("known_params") or {})
    refused = []
    for method, rule in sorted(known.items()):
        if only and method not in only:
            continue
        allowed, acpmux = set(rule.get("params") or []), set(rule.get("acpmux") or [])
        for keys in sent(page, method):
            for key in keys:
                if key not in allowed:
                    refused.append(f"{method}: page sends `{key}`, the rule knows {sorted(allowed)}")
            meta = keys.get("_meta", "")
            inner = re.search(r"acpmux\s*:\s*\{", meta)
            if "_meta" in allowed and inner:
                for key in top_keys(literal(meta, inner.end() - 1) or "{}"):
                    if key not in acpmux:
                        refused.append(f"{method}: page sends `_meta.acpmux.{key}`, the rule knows {sorted(acpmux)}")
    if refused:
        print(f"{commit[:12]}: bad: " + "; ".join(refused))
        return 1
    print(f"{commit[:12]}: good: every key the page sends is in the relay's params rule")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
