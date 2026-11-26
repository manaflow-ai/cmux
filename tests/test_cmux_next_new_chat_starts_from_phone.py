#!/usr/bin/env python3
"""A new chat the Mac opened starts from the phone's first message, with no banner.

Leo, 2026-11-22, on the same banner: "figure out the fucking right behaviour we want, perfect it."
Leo, 2026-11-18, on an iPhone New chat that said "Agent hasn't started in this tab. Send the
first message from cmux on <Mac>; the chat continues here.": "you should be able to just start
the chat right there. Why is this dialogue showing?"

The phone's UnboundAgentSource now starts the chat on its first send (session/new, then the
tab's bind-conversation-tab-session, the Mac's own first-send path), and the Mac's phone policy
admits that bind for an unbound agent tab of this Mac. This test fails if the banner text comes
back on any surface, if the phone's unbound chat stops starting on send, or if the phone policy
drops the bind.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SURFACES = ["cmux-next-ios", "Packages", "webviews", "cmux-tui", "web"]
SUFFIXES = {".swift", ".rs", ".ts", ".tsx", ".json", ".strings", ".xcstrings"}
SKIP_PARTS = {"node_modules", "target", ".build", "build", "DerivedData"}
BANNERS = [
    re.compile(r"hasn'?t started in this tab", re.IGNORECASE),
    re.compile(r"Send the first message from cmux on", re.IGNORECASE),
]

LIVE = ROOT / "cmux-next-ios" / "CmuxMobileKit" / "Sources" / "CmuxMobileLive"
POLICY = ROOT / "cmux-next-ios" / "rust" / "crates" / "cmux-mobile-host" / "src" / "policy.rs"


def banner_hits() -> list[str]:
    hits = []
    for surface in SURFACES:
        base = ROOT / surface
        if not base.is_dir():
            continue
        for path in base.rglob("*"):
            if path.suffix not in SUFFIXES or SKIP_PARTS.intersection(path.parts) or not path.is_file():
                continue
            text = path.read_text(encoding="utf-8", errors="ignore")
            for pattern in BANNERS:
                for match in pattern.finditer(text):
                    line = text.count("\n", 0, match.start()) + 1
                    hits.append(f"{path.relative_to(ROOT)}:{line}: {match.group(0)}")
    return hits


def main() -> int:
    failures = []
    hits = banner_hits()
    if hits:
        failures.append("the not-started banner is back (a new chat starts from its first message instead):\n  "
                        + "\n  ".join(hits))

    coordinator = (LIVE / "LiveCoordinator.swift").read_text(encoding="utf-8")
    source = coordinator[coordinator.index("final class UnboundAgentSource"):]
    if "startTabChat" not in coordinator or "try await start()" not in source:
        failures.append("UnboundAgentSource no longer starts the chat on the phone's first send")

    creation = (LIVE / "LiveWorkspaceCreation.swift").read_text(encoding="utf-8")
    start = creation.find("func startTabChat")
    body = creation[start:creation.find("\n    }\n", start)] if start >= 0 else ""
    if '"bind-conversation-tab-session"' not in body or '"expected_session": NSNull()' not in body:
        failures.append("startTabChat no longer binds the session to the tab with expected_session null")

    policy = POLICY.read_text(encoding="utf-8")
    allowed = policy[policy.index("static ALLOWED_COMMANDS"):policy.index(".into_iter()")]
    if '"bind-conversation-tab-session"' not in allowed or "UnboundAgentTab" not in policy:
        failures.append("cmux-mobile-host no longer admits a phone's bind of an unbound agent tab")
    # The bind is checked against hostd's cached tree: without this capability the daemon lists
    # agent tabs as browser tabs and every bind is refused.
    cache = (POLICY.parent / "workspace_cache.rs").read_text(encoding="utf-8")
    # The hello names its capabilities from cmux_mobile_link::names (AGENT_SESSION_TABS is
    # "agent-session-tabs-v1").
    start = cache.find("fn cache_hello()")
    hello = cache[start:cache.find("\n}\n", start)] if start >= 0 else ""
    if "AGENT_SESSION_TABS" not in hello and "agent-session-tabs-v1" not in hello:
        failures.append("cmux-mobile-host's cache connection no longer declares agent-session-tabs-v1")

    for failure in failures:
        print(f"FAIL: {failure}", file=sys.stderr)
    if not failures:
        print("ok: a phone's new chat starts from its first message, and no not-started banner exists")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
