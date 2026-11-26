"""Apply unified-diff hunks to a file's lines, tolerating drift.

The agent tooling uses this to apply model-written patches to files that may
have changed since the model read them, so a hunk is searched for near where its
header says it goes rather than required to sit exactly there.

Lines are handled without their line endings: `apply(lines, diff)` takes and
returns a list of strings.
"""

import re

_HEADER = re.compile(r"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@")


class PatchError(ValueError):
    """The diff text is malformed."""


class HunkFailed(Exception):
    """Hunk number `index` (0-based) matched nowhere within the search window."""

    def __init__(self, index):
        super().__init__("hunk #%d failed to apply" % (index + 1))
        self.index = index


class Hunk:
    def __init__(self, old_start, old_len, new_start, new_len, body):
        self.old_start = old_start
        self.old_len = old_len
        self.new_start = new_start
        self.new_len = new_len
        self.body = body  # list of (op, text), op in " ", "-", "+"

    def old_lines(self):
        return [t for op, t in self.body if op != "+"]

    def new_lines(self):
        return [t for op, t in self.body if op != "-"]

    def __repr__(self):
        return "Hunk(-%d,%d +%d,%d)" % (self.old_start, self.old_len, self.new_start, self.new_len)


def parse(diff):
    """The hunks of a unified diff, in order. File headers (---, +++) are skipped."""
    hunks = []
    current = None
    for line in diff.splitlines():
        if line.startswith("@@"):
            m = _HEADER.match(line)
            if not m:
                raise PatchError("bad hunk header: %r" % line)
            old_start, old_len, new_start, new_len = (
                int(m.group(1)), int(m.group(2) or 0), int(m.group(3)), int(m.group(4) or 0))
            current = Hunk(old_start, old_len, new_start, new_len, [])
            hunks.append(current)
        elif line.startswith(("---", "+++", "diff ", "index ")) and (current is None or _complete(current)):
            current = None
        elif current is None:
            continue
        elif line.startswith("\\"):
            continue  # "\ No newline at end of file"
        elif line == "":
            current.body.append((" ", ""))
        elif line[0] in " -+":
            current.body.append((line[0], line[1:]))
        else:
            raise PatchError("bad hunk line: %r" % line)
    for h in hunks:
        if len(h.old_lines()) != h.old_len or len(h.new_lines()) != h.new_len:
            raise PatchError("hunk %r does not match its header" % (h,))
    return hunks


def _complete(h):
    return len(h.old_lines()) >= h.old_len and len(h.new_lines()) >= h.new_len


def _matches(lines, pos, want):
    if pos < 0 or pos + len(want) > len(lines):
        return False
    return lines[pos:pos + len(want)] == want


def _find(lines, want, expected, max_offset):
    for off in range(0, max_offset + 1):
        if _matches(lines, expected + off, want):
            return expected + off
    return None


def apply(lines, diff, max_offset=20):
    """Return `lines` with every hunk of `diff` applied, or raise HunkFailed."""
    out = list(lines)
    delta = 0
    for i, h in enumerate(parse(diff)):
        old, new = h.old_lines(), h.new_lines()
        expected = h.old_start - 1 + delta
        pos = _find(out, old, expected, max_offset)
        if pos is None:
            raise HunkFailed(i)
        out[pos:pos + len(old)] = new
        delta += len(new) - len(old)
    return out


def apply_text(text, diff, max_offset=20):
    """apply() for a whole file's text; keeps a trailing newline if the text had one."""
    trailing = text.endswith("\n")
    lines = text.split("\n")
    if trailing:
        lines.pop()
    out = apply(lines, diff, max_offset)
    return "\n".join(out) + ("\n" if trailing and out else "")
