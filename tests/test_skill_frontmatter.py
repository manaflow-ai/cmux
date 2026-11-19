#!/usr/bin/env python3
"""Keep every skill's frontmatter description free of angle brackets.

Anthropic's skill rules say a description cannot contain XML tags. A skill
validator reads any `<` or `>` in the description as a tag and rejects the
skill, and uploading it to claude.ai fails the same way (#46729). The checks
read the files only; they need no build and no running app.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
SKILLS = sorted((ROOT / "skills").glob("*/SKILL.md"))
FRONTMATTER = re.compile(r"\A---\n(.*?)\n---\n", re.DOTALL)
DESCRIPTION = re.compile(r"^description:[ \t]*(.*)$", re.MULTILINE)


def description(path: Path) -> str | None:
    """The `description:` value in a SKILL.md frontmatter, without its quotes."""
    frontmatter = FRONTMATTER.match(path.read_text(encoding="utf-8"))
    if frontmatter is None:
        return None
    line = DESCRIPTION.search(frontmatter.group(1))
    if line is None:
        return None
    value = line.group(1).strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
        value = value[1:-1]
    return value


class SkillDescriptionTests(unittest.TestCase):
    def test_skills_are_found(self) -> None:
        self.assertIn(ROOT / "skills" / "cmux-settings" / "SKILL.md", SKILLS)

    def test_every_skill_has_a_description(self) -> None:
        for path in SKILLS:
            with self.subTest(skill=path.parent.name):
                self.assertTrue(description(path), "no description in the frontmatter")

    def test_no_description_contains_angle_brackets(self) -> None:
        for path in SKILLS:
            with self.subTest(skill=path.parent.name):
                self.assertNotRegex(
                    description(path) or "",
                    r"\S*[<>]\S*",
                    f"{path.relative_to(ROOT)}: a skill description cannot contain < or >",
                )


if __name__ == "__main__":
    unittest.main()
