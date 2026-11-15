# SPDX-License-Identifier: MIT
"""The claim mapping of truthmatrix.py, importable on its own (no guest paths)."""
import re

POLICY_RE = re.compile(r"(denied|not allowed|target_not_allowed|forbidden|refus|blocked|privacy|kept private)", re.I)

OUTCOMES = ("confirmed", "no_effect", "uncertain")  # cmux CU's verified result (cmux-cu-verified and later)


def top_fields(text):
    """The claim-bearing top-level fields of a JSON tool result: outcome, evidence, route, note. Read from the full
    text before the call record truncates it, so a long result (one carrying the window tree) keeps them."""
    import json
    try:
        d = json.loads(text)
    except (ValueError, TypeError):
        return {}
    if not isinstance(d, dict):
        return {}
    return {k: d[k] for k in ("outcome", "evidence", "route", "note") if isinstance(d.get(k), str)}


def claim_of(arm_id, rec):
    """The tool's own claim about one call.

    cmux: `outcome` (confirmed / no_effect / uncertain) when the engine sends it, else `evidence` (confirmed /
    delivered / no_visible_change). Tools without either (cua-driver, Aside) are read from their result text."""
    if rec is None:
        return None
    txt = rec.get("result") or ""
    if rec.get("is_error"):
        return "refused" if POLICY_RE.search(txt) else "error"
    fields = rec.get("claim_fields") or top_fields(txt)
    if fields.get("outcome") in OUTCOMES:
        return fields["outcome"]
    if fields.get("evidence"):
        return fields["evidence"]
    # a result too long to parse (truncated): only a top-level key can precede the nested "state"
    m = re.search(r'"outcome"\s*:\s*"(confirmed|no_effect|uncertain)"', txt.split('"state"', 1)[0])
    if m:
        return m.group(1)
    if arm_id.startswith("aside"):
        if re.match(r"^\s*(Uncaught\s+)?\w*Error\b", txt):
            return "error"
        if re.search(r"returns? without acting|did not act|was not performed", txt, re.I):
            return "no_visible_change"
        return "ok"
    m = re.search(r'"evidence"\s*:\s*"(\w+)"', txt.split('"state"', 1)[0])
    if m:
        return m.group(1)
    if arm_id.startswith("cua"):
        if re.search(r"\bunverified\b", txt, re.I):
            return "delivered"  # cua-driver's own "Sent (unverified)"
        if re.search(r"\bconfirmed\b", txt, re.I) and not re.search(r"\b(not|could not|couldn't|cannot) (be )?confirm", txt, re.I):
            return "confirmed"
    return "ok"


POSITIVE = {"confirmed", "delivered", "ok"}  # every other claim (no_effect, no_visible_change, error, refused) is negative
UNCERTAIN = {"uncertain"}  # neither: the tool said it does not know whether the action took effect


def confusion_cell(claim, truth, expect_none=False):
    """TP / FP / FN / TN / SIDE / UNC for one scored action.
    expect_none: the correct outcome is no effect (a disabled menu item); then 'none' is the right result
    and a positive claim about it is still a false claim (the tool said it did something)."""
    if claim is None:
        return "no_action"
    if truth is None:
        return "not_scored"  # the judge could not say what happened (a precondition was already met, no read)
    pos = claim in POSITIVE
    if truth == "extra":
        return "SIDE"  # an effect elsewhere, whatever the claim
    if claim in UNCERTAIN:
        return "UNC"
    if expect_none:
        if truth == "none":
            return "FP" if pos else "TN"
        return "FP" if pos else "FN"
    if truth == "correct":
        return "TP" if pos else "FN"
    if truth in ("none", "wrong"):
        return "FP" if pos else "TN"
    return "?"


