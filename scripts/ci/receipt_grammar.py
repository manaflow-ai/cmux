#!/usr/bin/env python3
"""The review receipt grammar, and when a receipt counts. One copy: risk_tier.py and defaults_guard.py import it.

A receipt is an independent review's verdict on the exact head, on one line:

    Review (<reviewer>): SHIP at <full head sha>        (or BLOCK, FIX, NOT SHIP, HOLD)

Every agent posts on GitHub as the same account as the pull request's author, so the account does not show who
reviewed. A pull request an agent made says its author agent in the description, on one line:

    Author-agent: <agent id>

and a receipt from the pull request author's own account must name the reviewer agent and who started it:

    Review (<reviewer agent id>, started by <agent id>): SHIP at <full head sha>

Such a SHIP counts only when both ids are there, the description names its Author-agent, and neither id is an
Author-agent (cmux-ad m25 item 7; on #36311 the author agent's own subagent posted
`Review (claude-review-subagent): SHIP at ...` from the author's account and the guard read it as independent).
A receipt from another account keeps the older rule. A label with "self" in it never counts. A BLOCK always counts:
an unverified receipt can make a guard red, never green.
"""

from __future__ import annotations

import re
from dataclasses import dataclass

# The verdict on a comment's or review's first line, or on a line of the description.
RECEIPT = re.compile(r"^\W*(?:independent\s+)?review\s*\(([^)\n]*)\)\s*:\W*(ship|block|fix|not ship|hold)(?![\w-])",
                     re.I)
# "<reviewer agent id>, started by <agent id>": the last comma-separated part of the label names the starter.
STARTED_BY = re.compile(r"^(?P<reviewer>.*\S)\s*,\s*started\s+by\s+(?P<starter>\S.*?)\s*$", re.I)
# "Author-agent: <agent id>" on a line of its own, optionally as a list item, quote or bold label.
AUTHOR_AGENT = re.compile(r"^[\s>*_`-]*author-agent[*_`]*\s*:[\s*_`]*(?P<id>[^\s*`]+)", re.I | re.M)
HTML_COMMENT = re.compile(r"<!--.*?-->", re.S)


@dataclass(frozen=True)
class Receipt:
    verdict: str  # "ship" or "block" (BLOCK, FIX, NOT SHIP and HOLD all hold the head)
    label: str  # the text inside the parentheses
    reviewer: str | None  # the reviewer agent id, when the label says who started it
    starter: str | None  # the agent that started the reviewer

    @property
    def who(self) -> str:
        return f"review ({self.label})"


def parse(line: str, head: str) -> Receipt | None:
    """The receipt on `line` when it names the full `head` sha and its label does not say self, else None."""
    match = RECEIPT.match(line or "")
    if not head or not match or head not in line or "self" in match.group(1).lower():
        return None
    label = match.group(1).strip()
    started = STARTED_BY.match(label)
    return Receipt("ship" if match.group(2).lower() == "ship" else "block", label,
                   started.group("reviewer").strip() if started else None,
                   started.group("starter").strip() if started else None)


def norm(agent: str | None) -> str:
    return (agent or "").strip().strip("`*_").strip().lower()


def author_agents(body: str | None) -> set[str]:
    """Every `Author-agent: <id>` the description names outside <!-- comments -->, normalized."""
    return {norm(m.group("id")) for m in AUTHOR_AGENT.finditer(HTML_COMMENT.sub("", body or ""))} - {""}


def same_account(login: str | None, author: str | None) -> bool:
    """Whether the receipt's account is the pull request author's. An unknown author or login is treated as
    the same account: the stricter rule applies when nobody can tell."""
    return not author or not login or login.strip().lower() == author.strip().lower()


def refusal(receipt: Receipt, same: bool, agents: set[str]) -> str | None:
    """Why `receipt` does not count, or None when it does. Only a SHIP from the author's own account is refused."""
    if receipt.verdict != "ship" or not same:
        return None
    if not agents:
        return "a SHIP from the author's account, and the description has no `Author-agent: <agent id>` line"
    if not receipt.reviewer or not receipt.starter:
        return "a SHIP from the author's account must say `Review (<reviewer agent id>, started by <agent id>)`"
    if norm(receipt.reviewer) in agents:
        return f"the reviewer {receipt.reviewer} is the pull request's author agent"
    if norm(receipt.starter) in agents:
        return f"the reviewer was started by {receipt.starter}, the pull request's author agent"
    return None


def counted(line: str, head: str, *, login: str | None, author: str | None, body: str | None) -> Receipt | None:
    """The receipt on `line` if it counts for `head`: parse(), then refusal() for the author's own account.
    `login` posted it, `author` opened the pull request and `body` is its description."""
    receipt = parse(line, head)
    if receipt is None or refusal(receipt, same_account(login, author), author_agents(body)):
        return None
    return receipt
