"""The style guards level (CMUX_NEXT_STYLE_GUARDS): `fail` only on main and release tags, `warn` on every other base.

#54185: the expression keyed on `base_ref == 'feat-cmux-next'`, so a stacked pull request (base: another lane
branch) got `fail` and went red on findings feat-cmux-next already had and its parent only warned about. This
evaluates the one expression each workflow carries against the events it runs on.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = {
    ".github/workflows/ci-web.yml": "CMUX_NEXT_STYLE_GUARDS_LEVEL",
    ".github/workflows/release-rails.yml": "CMUX_NEXT_STYLE_GUARDS_LEVEL",
    ".github/workflows/cmux-vm-clients.yml": "CMUX_NEXT_STYLE_GUARDS_LEVEL",
    ".github/workflows/cmux-tui-spec.yml": "CMUX_NEXT_STYLE_GUARDS_LEVEL",
    ".github/workflows/test-ios.yml": "CMUX_NEXT_STYLE_GUARDS",
}


def workflow_expression(path: str, key: str) -> str:
    text = (ROOT / path).read_text(encoding="utf-8")
    match = re.search(rf"^  {key}: \$\{{\{{ (.+) \}}\}}$", text, re.M)
    if match is None:
        raise AssertionError(f"{path}: no workflow-level {key} expression")
    return match.group(1)


def evaluate(expression: str, github: dict) -> object:
    """Evaluate the GitHub Actions expression subset this uses: `||`, `&&`, `!`, `==`, startsWith, contexts."""

    def lookup(dotted: str) -> object:
        value: object = {"github": github}
        for part in dotted.split("."):
            value = value.get(part) if isinstance(value, dict) else None
        return value

    def starts_with(value: object, prefix: str) -> bool:
        return isinstance(value, str) and value.lower().startswith(prefix.lower())

    python = expression.replace("||", " or ").replace("&&", " and ")
    python = re.sub(r"!(?!=)", " not ", python)
    python = python.replace("startsWith(", "starts_with(")
    python = re.sub(r"\bgithub(?:\.\w+)+", lambda m: f"lookup({m.group(0)!r})", python)
    return eval(python, {"__builtins__": {}}, {"lookup": lookup, "starts_with": starts_with})  # noqa: S307


def pull_request(base: str) -> dict:
    return {"event_name": "pull_request", "base_ref": base, "ref": "refs/pull/1/merge", "event": {}}


def push(ref: str) -> dict:
    return {"event_name": "push", "base_ref": "", "ref": ref, "event": {}}


def merge_group(base: str) -> dict:
    return {"event_name": "merge_group", "base_ref": "", "ref": f"refs/heads/gh-readonly-queue/{base}/pr-1-abc",
            "event": {"merge_group": {"base_ref": f"refs/heads/{base}"}}}


CASES = [
    ("pull request onto feat-cmux-next", pull_request("feat-cmux-next"), "warn"),
    ("stacked pull request onto a lane branch (#54185)", pull_request("lane/design-tokens"), "warn"),
    ("pull request onto main", pull_request("main"), "fail"),
    ("push to feat-cmux-next", push("refs/heads/feat-cmux-next"), "warn"),
    ("push to main", push("refs/heads/main"), "fail"),
    ("release tag", push("refs/tags/v1.2.3"), "fail"),
    ("merge group onto feat-cmux-next", merge_group("feat-cmux-next"), "warn"),
    ("merge group onto main", merge_group("main"), "fail"),
]


class StyleGuardsLevelTests(unittest.TestCase):
    def test_every_workflow_carries_the_same_expression(self):
        expressions = {path: workflow_expression(path, key) for path, key in WORKFLOWS.items()}
        self.assertEqual(len(set(expressions.values())), 1, expressions)

    def test_only_main_and_release_tags_fail(self):
        for path, key in WORKFLOWS.items():
            expression = workflow_expression(path, key)
            for name, github, expected in CASES:
                with self.subTest(workflow=path, case=name):
                    self.assertEqual(evaluate(expression, github), expected)

    def test_steps_read_the_shared_level(self):
        for path, key in WORKFLOWS.items():
            if key == "CMUX_NEXT_STYLE_GUARDS":
                continue
            text = (ROOT / path).read_text(encoding="utf-8")
            with self.subTest(workflow=path):
                self.assertIn("CMUX_NEXT_STYLE_GUARDS: ${{ env.CMUX_NEXT_STYLE_GUARDS_LEVEL }}", text)
                self.assertNotIn("== 'feat-cmux-next' && 'warn' || 'fail'", text)
                self.assertNotIn("== 'refs/heads/feat-cmux-next') && 'warn' || 'fail'", text)


if __name__ == "__main__":
    unittest.main()
