"""gitignore-style rules for the file tree, the quick-open index and the agent's file watcher.

Paths are relative to the root, "/"-separated, without a leading or trailing slash; callers say whether a path is
a directory. The rules follow gitignore(5): blank lines and `#` comments are skipped, `!` negates, a trailing `/`
matches directories only, a pattern with a `/` at its start or in its middle is relative to the root (otherwise
it matches a name at any depth), `*` `?` `[...]` never match `/`, a leading `**/` matches in all directories, a
trailing `/**` matches everything inside, `/**/` matches zero or more directories, and the last rule that matches
decides. A path inside an ignored directory is ignored, and no `!` rule can re-include it. Matching is
case-sensitive; `**` that is not a whole segment acts like `*`; `*` matches a leading dot.
"""
import re
from dataclasses import dataclass


_STAR = ("*",)
_ONE = ("?",)


@dataclass(frozen=True)
class Rule:
    source: str
    parts: tuple
    negated: bool
    dir_only: bool

    def matches(self, path: str, is_dir: bool) -> bool:
        if self.dir_only and not is_dir:
            return False
        return _match_parts(self.parts, path.split("/"))


def _tokens(seg: str):
    out = []
    i = 0
    while i < len(seg):
        c = seg[i]
        if c == "\\" and i + 1 < len(seg):
            out.append(("=", seg[i + 1]))
            i += 2
            continue
        if c == "*":
            if not out or out[-1] is not _STAR:
                out.append(_STAR)
        elif c == "?":
            out.append(_ONE)
        elif c == "[":
            end = seg.find("]", i + 2)
            if end < 0:
                out.append(("=", c))
            else:
                body = seg[i + 1:end]
                if body.startswith("!"):
                    body = "^" + body[1:]
                out.append(("[", re.compile("[" + body.replace("\\", "\\\\") + "]", re.DOTALL)))
                i = end + 1
                continue
        else:
            out.append(("=", c))
        i += 1
    return tuple(out)


def _one(tok, ch):
    if tok is _ONE:
        return True
    if tok[0] == "=":
        return tok[1] == ch
    return tok[1].fullmatch(ch) is not None


def _match_segment(toks, s):
    """Wildcard match with one remembered star: O(len(toks) * len(s)), no exponential backtracking."""
    p = i = 0
    star = -1
    mark = 0
    n = len(toks)
    while i < len(s):
        if p < n and toks[p] is _STAR:
            star, mark = p, i
            p += 1
        elif p < n and _one(toks[p], s[i]):
            p += 1
            i += 1
        elif star >= 0:
            mark += 1
            p, i = star + 1, mark
        else:
            return False
    while p < n and toks[p] is _STAR:
        p += 1
    return p == n


def _match_parts(parts, segs):
    """parts: "**" or token tuples. A "**" before the end matches zero or more segments; the last one matches
    one or more."""
    n = len(parts)

    def close(states):
        todo = list(states)
        while todo:
            q = todo.pop()
            if q < n - 1 and parts[q] == "**" and q + 1 not in states:
                states.add(q + 1)
                todo.append(q + 1)
        return states

    states = close({0})
    for seg in segs:
        nxt = set()
        for q in states:
            if q >= n:
                continue
            if parts[q] == "**":
                nxt.add(q)
                if q == n - 1:
                    nxt.add(n)
            elif _match_segment(parts[q], seg):
                nxt.add(q + 1)
        if not nxt:
            return False
        states = close(nxt)
    return n in states


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
    dir_only = text.endswith("/")
    body = text.rstrip("/")
    anchored = "/" in body
    body = body.lstrip("/")
    if not body:
        return None
    parts = tuple("**" if seg == "**" else _tokens(seg) for seg in body.split("/"))
    if not anchored:
        parts = ("**",) + parts
    return Rule(line, parts, negated, dir_only)


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
        parts = path.split("/")
        for k in range(1, len(parts)):
            if self._decide("/".join(parts[:k]), True):
                return True
        return self._decide(path, is_dir)

    def filter_paths(self, entries) -> list[str]:
        """The entries that are not ignored, in order. An entry ending in "/" is a directory."""
        kept = []
        for entry in entries:
            is_dir = entry.endswith("/")
            if not self.ignored(entry.rstrip("/"), is_dir):
                kept.append(entry)
        return kept
