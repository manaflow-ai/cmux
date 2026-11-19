#!/usr/bin/env python3
"""Keep every skill's frontmatter description free of angle brackets.

Anthropic's skill rules say a description cannot contain XML tags. A skill
validator reads any `<` or `>` in the description as a tag and rejects the
skill, and uploading it to claude.ai fails the same way (#46729). The checks
read the files only; they need no build and no running app.
"""

from __future__ import annotations

import re
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
SKILLS = sorted((ROOT / "skills").glob("*/SKILL.md"))
FRONTMATTER = re.compile(r"\A---\n(.*?)\n---\n", re.DOTALL)
# The top-level `description:` line and the indented or blank lines that continue it.
DESCRIPTION = re.compile(r"^description:(.*(?:\n(?:[ \t].*|[ \t]*$))*)", re.MULTILINE)
# A block scalar header such as `>-`, `|` or `>2 # note`; its text is on the lines below.
BLOCK_HEADER = re.compile(r"[>|][1-9+-]{0,2}(?:[ \t]+#.*)?")


def description(path: Path) -> str | None:
    """The `description:` value in a SKILL.md frontmatter on one line, without its quotes.

    A value continued on indented lines, plain, quoted or block scalar, is read in full.
    """
    frontmatter = FRONTMATTER.match(path.read_text(encoding="utf-8"))
    if frontmatter is None:
        return None
    match = DESCRIPTION.search(frontmatter.group(1))
    if match is None:
        return None
    lines = match.group(1).split("\n")
    if BLOCK_HEADER.fullmatch(lines[0].strip()):
        lines[0] = ""
    value = " ".join(" ".join(lines).split())
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
        value = value[1:-1]
    return value


class DescriptionParserTests(unittest.TestCase):
    def parse(self, frontmatter: str) -> str | None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "SKILL.md"
            path.write_text(f"---\n{frontmatter}\n---\nbody\n", encoding="utf-8")
            return description(path)

    def test_reads_plain_and_quoted_values(self) -> None:
        self.assertEqual(self.parse("name: x\ndescription: Use when a"), "Use when a")
        self.assertEqual(self.parse('description: "set <x> in cmux"'), "set <x> in cmux")
        self.assertEqual(self.parse("description: 'a b'"), "a b")

    def test_reads_the_lines_of_a_block_scalar(self) -> None:
        self.assertEqual(self.parse("description: >-\n  no brackets\n  here\nname: x"), "no brackets here")
        self.assertEqual(self.parse("description: |\n  set <x>\n\n  in cmux"), "set <x> in cmux")
        self.assertEqual(self.parse("description: >2 # note\n  no brackets"), "no brackets")

    def test_reads_a_value_continued_on_indented_lines(self) -> None:
        self.assertEqual(self.parse("description: Use when\n  set <x> in cmux\nname: x"), "Use when set <x> in cmux")
        self.assertEqual(self.parse('description: "Use when\n  set <x>"'), "Use when set <x>")

    def test_ignores_a_nested_description_key(self) -> None:
        self.assertIsNone(self.parse("metadata:\n  description: a"))


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
