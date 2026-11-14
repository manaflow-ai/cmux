# SPDX-License-Identifier: MIT
"""The claim mapping of truthmatrix.py, importable on its own (no guest paths)."""
import re

POLICY_RE = re.compile(r"(denied|not allowed|target_not_allowed|forbidden|refus|blocked|privacy|kept private)", re.I)

def claim_of(arm_id, rec):
    """The tool's own claim about one call."""
    if rec is None:
        return None
    txt = rec.get("result") or ""
    if rec.get("is_error"):
        return "refused" if POLICY_RE.search(txt) else "error"
    if arm_id.startswith("aside"):
        if re.match(r"^\s*(Uncaught\s+)?\w*Error\b", txt):
            return "error"
        if re.search(r"returns? without acting|did not act|was not performed", txt, re.I):
            return "no_visible_change"
        return "ok"
    m = re.search(r'"evidence"\s*:\s*"(\w+)"', txt)
    if m:
        return m.group(1)
    if arm_id.startswith("cua"):
        if re.search(r"\bunverified\b", txt, re.I):
            return "delivered"  # cua-driver's own "Sent (unverified)"
        if re.search(r"\bconfirmed\b", txt, re.I):
            return "confirmed"
    return "ok"


POSITIVE = {"confirmed", "delivered", "ok"}


def confusion_cell(claim, truth, expect_none=False):
    """TP / FP / FN / TN / SIDE for one scored action.
    expect_none: the correct outcome is no effect (a disabled menu item); then 'none' is the right result
    and a positive claim about it is still a false claim (the tool said it did something)."""
    if claim is None:
        return "no_action"
    pos = claim in POSITIVE
    if truth == "extra":
        return "SIDE"
    if expect_none:
        if truth == "none":
            return "FP" if pos else "TN"
        return "FP" if pos else "FN"
    if truth == "correct":
        return "TP" if pos else "FN"
    if truth in ("none", "wrong"):
        return "FP" if pos else "TN"
    return "?"


