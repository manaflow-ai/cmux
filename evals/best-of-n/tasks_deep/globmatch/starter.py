"""gitignore-style rules for the file tree, the quick-open index and the agent's file watcher.

Paths are relative to the root, "/"-separated, without a leading or trailing slash; callers say whether a path is
a directory. The rules follow gitignore(5): blank lines and `#` comments are skipped, `!` negates, a trailing `/`
matches directories only, a pattern with a `/` at its start or in its middle is relative to the root (otherwise
it matches a name at any depth), `*` `?` `[...]` never match `/`, a leading `**/` matches in all directories, a
trailing `/**` matches everything inside, `/**/` matches zero or more directories, and the last rule that matches
decides. A path inside an ignored directory is ignored, and no `!` rule can re-include it.
"""
import re
from dataclasses import dataclass


@dataclass(frozen=True)
class Rule:
    source: str
    regex: re.Pattern
    negated: bool
    dir_only: bool

    def matches(self, path: str, is_dir: bool) -> bool:
        if self.dir_only and not is_dir:
            return False
        return self.regex.fullmatch(path) is not None


def _segment_regex(seg: str) -> str:
    out = []
    i = 0
    while i < len(seg):
        c = seg[i]
        if c == "\\" and i + 1 < len(seg):
            out.append(re.escape(seg[i + 1]))
            i += 2
            continue
        if c == "*":
            out.append("[^/]*")
        elif c == "?":
            out.append("[^/]")
        elif c == "[":
            end = seg.find("]", i + 2)
            if end < 0:
                out.append(re.escape(c))
            else:
                body = seg[i + 1:end]
                if body.startswith("!"):
                    body = "^" + body[1:]
                out.append("[" + body.replace("\\", "\\\\") + "]")
                i = end + 1
                continue
        else:
            out.append(re.escape(c))
        i += 1
    return "".join(out)


def parse_rule(line: str) -> Rule | None:
    """One line of an ignore file as a Rule, or None for a blank line or a comment."""
    text = line.rstrip("\n")
    while text.endswith(" ") and not text.endswith("\\ "):
        text = text[:-1]
    if not text or text.startswith("#"):
        return None
    negated = text.startswith("!")
    if negated:
        text = text[1:]
    elif text.startswith("\\!") or text.startswith("\\#"):
        text = text[1:]
    anchored = "/" in text
    dir_only = text.endswith("/")
    body = text.rstrip("/")
    body = body.lstrip("/")
    if not body:
        return None
    parts = body.split("/")
    out = ""
    for i, seg in enumerate(parts):
        last = i == len(parts) - 1
        if seg == "**":
            out += ".*" if last else ".*/"
        else:
            out += _segment_regex(seg) + ("" if last else "/")
    prefix = "" if anchored else "(?:.*/)?"
    return Rule(line, re.compile(prefix + out, re.DOTALL), negated, dir_only)


class IgnoreRules:
    def __init__(self, lines=()):
        self.rules: list[Rule] = []
        self.extend(lines)

    @classmethod
    def from_text(cls, text: str) -> "IgnoreRules":
        return cls(text.splitlines())

    def extend(self, lines) -> None:
        for line in lines:
            rule = parse_rule(line)
            if rule is not None:
                self.rules.append(rule)

    def _decide(self, path: str, is_dir: bool) -> bool:
        ignored = False
        for rule in self.rules:
            if rule.matches(path, is_dir):
                ignored = not rule.negated
        return ignored

    def ignored(self, path: str, is_dir: bool = False) -> bool:
        """Whether `path` is ignored."""
        return self._decide(path, is_dir)

    def filter_paths(self, entries) -> list[str]:
        """The entries that are not ignored, in order. An entry ending in "/" is a directory."""
        kept = []
        for entry in entries:
            is_dir = entry.endswith("/")
            if not self.ignored(entry.rstrip("/"), is_dir):
                kept.append(entry)
        return kept
