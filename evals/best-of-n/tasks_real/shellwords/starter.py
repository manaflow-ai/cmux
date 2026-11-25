import re
import shlex

_ASSIGNMENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*(\[[^\]]+\])?\+?=")


def split_command(line: str) -> tuple:
    """(assignments, argv) of one simple shell command, as bash reads it."""
    words = shlex.split(line, posix=True)
    k = 0
    while k < len(words) and _ASSIGNMENT.match(words[k]):
        k += 1
    return words[:k], words[k:]
