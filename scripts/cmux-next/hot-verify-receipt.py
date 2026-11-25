#!/usr/bin/env python3
"""Whether a cmux pull request already carries a hot-verify look receipt: `receipt=true|false`.

cmux-next-hot-verify.yml's `plan` job asks this when a PR merges: a merged PR with no receipt gets one look at its
merge commit. A receipt is a PR body line or a comment that starts with the marker, by anyone (the metric's own
reading, cmuxterm-hq `metric hot_verify_share`).

Each read is one `gh api` call and never waits or retries: the step runs with the workflow's token, and a step that
sleeps in a loop on it spends the budget every workflow shares (tests/test_ci_no_github_token_polling.py). A read that
fails exits 1, and the plan then looks anyway (an unknown answer is not a receipt).
"""

from __future__ import annotations

import argparse
import subprocess
import sys

# Must equal hot-verify-ci.py's MARKER_PREFIX (test_hot_verify_ci.py checks it).
MARKER_PREFIX = "<!-- cmux-hot-verify "
REPO = "manaflow-ai/cmux"
# scripts/ci/gh_pages.py's page size and cap.
PER_PAGE = 100
MAX_PAGES = 30


def read(*args: str) -> str:
    done = subprocess.run(["gh", "api", *args], capture_output=True, text=True, timeout=120)
    if done.returncode != 0:
        raise RuntimeError(f"gh api {args[0]}: {(done.stderr or '').strip()[:300]}")
    return done.stdout


def has_receipt(pr: int, repo: str = REPO) -> bool:
    body = read(f"repos/{repo}/pulls/{int(pr)}", "--jq", '.body // ""')
    if any(line.startswith(MARKER_PREFIX) for line in body.splitlines()):
        return True
    # One line per comment: whether its body starts with the marker. One bounded page per call, never gh's
    # paginate flag (the gh quota wrapper refuses it; scripts/ci/gh_pages.py): a page short of PER_PAGE is the last.
    for page in range(1, MAX_PAGES + 1):
        found = read(f"repos/{repo}/issues/{int(pr)}/comments?per_page={PER_PAGE}&page={page}", "--jq",
                     f'.[] | (.body // "") | startswith("{MARKER_PREFIX}")').splitlines()
        if any(line.strip() == "true" for line in found):
            return True
        if len(found) < PER_PAGE:
            return False
    raise RuntimeError(f"PR {pr} has more than {MAX_PAGES * PER_PAGE} comments; a list cut short is no answer")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--pr", type=int, required=True)
    parser.add_argument("--repo", default=REPO)
    a = parser.parse_args(argv)
    try:
        print(f"receipt={'true' if has_receipt(a.pr, a.repo) else 'false'}")
    except (RuntimeError, OSError, subprocess.TimeoutExpired) as error:
        print(f"hot-verify-receipt: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
