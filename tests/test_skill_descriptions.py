#!/usr/bin/env python3
"""Keep every skill's frontmatter description free of angle brackets.

Anthropic's skill rules say a description cannot contain XML tags. A skill
validator loads the frontmatter as YAML and rejects any `<` or `>` in the
description, and uploading the skill to claude.ai fails the same way (#46729).
These checks load the frontmatter the same way; they need no build and no
running app.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parent.parent
SKILLS = sorted((ROOT / "skills").glob("*/SKILL.md"))
FRONTMATTER = re.compile(r"\A---\n(.*?)\n---\n", re.DOTALL)


def description(path: Path) -> object:
    """The `description` value of a SKILL.md frontmatter, as YAML decodes it."""
    frontmatter = FRONTMATTER.match(path.read_text(encoding="utf-8"))
    if frontmatter is None:
        return None
    fields = yaml.safe_load(frontmatter.group(1))
    return fields.get("description") if isinstance(fields, dict) else None


class SkillDescriptionTests(unittest.TestCase):
    def test_skills_are_found(self) -> None:
        self.assertIn(ROOT / "skills" / "cmux-settings" / "SKILL.md", SKILLS)

    def test_every_skill_has_a_description(self) -> None:
        for path in SKILLS:
            with self.subTest(skill=path.parent.name):
                value = description(path)
                self.assertIsInstance(value, str, "no description in the frontmatter")
                self.assertTrue(value.strip(), "empty description in the frontmatter")

    def test_no_description_contains_angle_brackets(self) -> None:
        for path in SKILLS:
            with self.subTest(skill=path.parent.name):
                value = description(path)
                self.assertNotRegex(
                    value if isinstance(value, str) else "",
                    r"\S*[<>]\S*",
                    f"{path.relative_to(ROOT)}: a skill description cannot contain < or >",
                )


if __name__ == "__main__":
    unittest.main()
