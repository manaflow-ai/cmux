"""Every actions/checkout of a branch by name gives the full ref (refs/heads/NAME).

actions/checkout turns a bare branch name into the wildcard refspec `+refs/heads/NAME*` (and
`+refs/tags/NAME*`). For feat-cmux-next that fetched every feat-cmux-next-* branch, about 1,750 of
them, at depth 1 with their trees: risk-tier.yml's checkout of five files took 68 s median of an
~88 s `risk evidence` job, which ran ~700 times an hour on 2026-11-25. A full ref fetches the one
branch, and checks it out the same way (branch NAME tracking origin/NAME).
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"

USES_CHECKOUT = re.compile(r"^\s*-?\s*uses:\s*actions/checkout@")
REF_LINE = re.compile(r"^(\s*)ref:\s*(.+?)\s*(#.*)?$")
# A branch name with no refs/ prefix: feat-cmux-next, main, or a branch-name expression such as
# github.event.pull_request.base.ref / head.ref, github.base_ref, github.head_ref, github.ref_name.
BRANCH_EXPR = re.compile(
    r"^\$\{\{\s*github\.(event\.pull_request\.(base|head)\.ref|base_ref|head_ref|ref_name)\s*\}\}$")
BARE_NAME = re.compile(r"^['\"]?(feat-cmux-next|main)['\"]?$")


def checkout_refs(text: str) -> list[tuple[int, str]]:
    """(line number, ref value) for each `ref:` under an actions/checkout `with:`."""
    lines = text.splitlines()
    found = []
    for i, line in enumerate(lines):
        if not USES_CHECKOUT.match(line):
            continue
        indent = len(line) - len(line.lstrip(" -"))
        for j in range(i + 1, min(i + 30, len(lines))):
            nxt = lines[j]
            if nxt.strip() and (len(nxt) - len(nxt.lstrip(" -"))) < indent:
                break
            if nxt.lstrip().startswith("- ") and (len(nxt) - len(nxt.lstrip(" "))) <= indent:
                break
            match = REF_LINE.match(nxt)
            if match:
                found.append((j + 1, match.group(2)))
                break
    return found


def unqualified(ref: str) -> bool:
    return bool(BARE_NAME.match(ref) or BRANCH_EXPR.match(ref))


class CheckoutBranchRefExact(unittest.TestCase):
    def test_no_checkout_fetches_a_branch_by_bare_name(self) -> None:
        bad = []
        for path in sorted(WORKFLOWS.glob("*.y*ml")):
            for number, ref in checkout_refs(path.read_text(encoding="utf-8")):
                if unqualified(ref):
                    bad.append(f"{path.name}:{number}: ref: {ref}")
        self.assertEqual(bad, [], "use ref: refs/heads/<branch>; a bare name fetches <branch>* (every "
                                  "feat-cmux-next-* branch)")

    def test_risk_evidence_checks_out_the_base_branch_by_full_ref(self) -> None:
        text = (WORKFLOWS / "risk-tier.yml").read_text(encoding="utf-8")
        self.assertIn("ref: refs/heads/${{ github.event.pull_request.base.ref }}", text)

    def test_the_detector_sees_the_bare_forms(self) -> None:
        sample = (
            "      - uses: actions/checkout@abc # v6\n"
            "        with:\n"
            "          ref: ${{ github.event.pull_request.base.ref }}\n"
            "      - name: x\n"
            "        uses: actions/checkout@abc\n"
            "        with:\n"
            "          persist-credentials: false\n"
            "          ref: feat-cmux-next\n"
            "      - uses: actions/checkout@abc\n"
            "        with:\n"
            "          ref: refs/heads/feat-cmux-next\n"
            "      - uses: actions/checkout@abc\n"
            "        with:\n"
            "          ref: ${{ github.event.pull_request.base.sha }}\n"
        )
        refs = [ref for _, ref in checkout_refs(sample)]
        self.assertEqual(refs, ["${{ github.event.pull_request.base.ref }}", "feat-cmux-next",
                                "refs/heads/feat-cmux-next", "${{ github.event.pull_request.base.sha }}"])
        self.assertEqual([unqualified(r) for r in refs], [True, True, False, False])


if __name__ == "__main__":
    unittest.main()
