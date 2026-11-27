"""Variable expansion for cmux workspace configs: `env`, `cwd` and `command` fields, and `.env` files.

Supported forms:
    $NAME  ${NAME}        the value of NAME ("" when unset, unless strict)
    ${NAME:-word}         word when NAME is unset or empty, else NAME's value
    ${NAME-word}          word when NAME is unset, else NAME's value (even "")
    \\$                    a literal "$"; a "$" not followed by a name or "{" is literal too
NAME is a letter or underscore followed by letters, digits and underscores. `word` is expanded itself, so defaults
can nest: ${EDITOR:-${VISUAL:-vi}}.
"""
import re

_NAME = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")


class UnsetVariable(KeyError):
    """A strict expansion referenced a variable that is not set."""

    def __init__(self, name: str):
        super().__init__(name)
        self.name = name


def _lookup(name: str, env, strict: bool) -> str:
    if name in env:
        return env[name]
    if strict:
        raise UnsetVariable(name)
    return ""


def _braced_end(text: str, start: int) -> int:
    """Index of the "}" closing the "${" whose body starts at `start` (nested ${...} skipped)."""
    depth = 1
    i = start
    while i < len(text):
        if text[i] == "\\":
            i += 2
            continue
        if text.startswith("${", i):
            depth += 1
            i += 2
            continue
        if text[i] == "}":
            depth -= 1
            if depth == 0:
                return i
        i += 1
    raise ValueError(f"unterminated ${{ in {text!r}")


def expand(text: str, env, strict: bool = False) -> str:
    """`text` with every variable reference replaced from `env` (a mapping). With `strict`, a reference to an
    unset variable raises UnsetVariable instead of expanding to ""."""
    out = []
    i = 0
    while i < len(text):
        c = text[i]
        if c == "\\" and text.startswith("$", i + 1):
            out.append("$")
            i += 2
            continue
        if c != "$":
            out.append(c)
            i += 1
            continue
        if text.startswith("{", i + 1):
            end = _braced_end(text, i + 2)
            body = text[i + 2:end]
            m = _NAME.match(body)
            if not m:
                raise ValueError(f"bad substitution: ${{{body}}}")
            name, rest = m.group(0), body[m.end():]
            if rest == "":
                out.append(_lookup(name, env, strict))
            elif rest.startswith(":-"):
                default = expand(rest[2:], env)
                out.append(env.get(name) or default)
            elif rest.startswith("-"):
                default = expand(rest[1:], env)
                out.append(env[name] if name in env else default)
            else:
                raise ValueError(f"bad substitution: ${{{body}}}")
            i = end + 1
            continue
        m = _NAME.match(text, i + 1)
        if not m:
            out.append("$")
            i += 1
            continue
        out.append(_lookup(m.group(0), env, strict))
        i = m.end()
    return "".join(out)


def expand_all(items, env, strict: bool = False) -> list[str]:
    """Each string of `items` expanded."""
    return [expand(item, env, strict) for item in items]


def expand_env(assignments: dict, base, strict: bool = False) -> dict:
    """A workspace's `env` block: each value expanded in order against `base` plus the entries before it, so
    `{"A": "x", "B": "$A/y"}` gives B "x/y". Returns only the block's own entries."""
    scope = dict(base)
    out = {}
    for key, raw in assignments.items():
        value = expand(raw, scope, strict)
        scope[key] = value
        out[key] = value
    return out


def parse_dotenv(source: str, base, strict: bool = False) -> dict:
    """A `.env` file: `KEY=value` lines (an optional `export ` prefix), blank lines and `#` comments skipped.
    A value in single quotes is taken literally; one in double quotes or bare is expanded like `expand_env`."""
    assignments = {}
    literal = set()
    for raw in source.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[len("export "):].lstrip()
        key, sep, value = line.partition("=")
        key = key.strip()
        if not sep or not _NAME.fullmatch(key):
            raise ValueError(f"bad .env line: {raw!r}")
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] == "'":
            assignments[key] = value[1:-1]
            literal.add(key)
            continue
        if len(value) >= 2 and value[0] == value[-1] == '"':
            value = value[1:-1]
        assignments[key] = value
        literal.discard(key)
    scope = dict(base)
    out = {}
    for key, value in assignments.items():
        out[key] = value if key in literal else expand(value, scope)
        scope[key] = out[key]
    return out


def resolve_workspace(config: dict, base, strict: bool = False) -> dict:
    """`env`, `cwd` and `command` of a workspace config, expanded: `env` first, then the rest against it."""
    env = dict(base)
    env.update(expand_env(config.get("env", {}), base, strict))
    return {
        "env": {k: env[k] for k in config.get("env", {})},
        "cwd": expand(config.get("cwd", "."), env),
        "command": expand_all(config.get("command", []), env, strict),
    }
