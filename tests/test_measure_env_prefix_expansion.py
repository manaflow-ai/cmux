"""A ${x:+NAME=v} expansion in front of a command is never an env assignment:
bash runs NAME=v as the command (exit 127). In scripts/measure it must follow `env`."""
import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
EXPANSION = re.compile(r"\$\{[A-Za-z_][A-Za-z0-9_]*:\+[A-Z_][A-Z0-9_]*=")


def command_start(lines, i):
    while i > 0 and lines[i - 1].rstrip().endswith("\\"):
        i -= 1
    return lines[i]


class MeasureEnvPrefixExpansion(unittest.TestCase):
    def test_expanded_assignments_follow_env(self):
        bad = []
        for path in sorted((ROOT / "scripts/measure").glob("*.sh")):
            lines = path.read_text().splitlines()
            for i, line in enumerate(lines):
                if line.lstrip().startswith("#") or not EXPANSION.search(line):
                    continue
                start = command_start(lines, i)
                head = line if "env " in line.split("${")[0] else start
                if not re.search(r"(^|[\s(&;|])env\s", head):
                    bad.append(f"{path.relative_to(ROOT)}:{i + 1}")
        self.assertEqual(bad, [], "put `env` before the command: " + ", ".join(bad))


if __name__ == "__main__":
    unittest.main()
