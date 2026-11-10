"""A workflow's jobs and what they hold, read the way GitHub reads them. Every guard that
derives a job list from a workflow (which jobs hold secrets, which run in a release
environment, which gate a merge) reads it through this one module.

Jobs come from a YAML loader, not from matching header lines: a header regex such as
`\\n  ([A-Za-z0-9_-]+):\\n` misses `  deploy-x: # note`, folds that job into the one before
it, and the job escapes the guard. The loader also refuses a repeated key, which PyYAML
would otherwise resolve by keeping the last job of that name.

Secrets are matched in every form GitHub accepts: `secrets.X`, `secrets['X']`,
`secrets["X"]`, any case, `toJSON(secrets)` and `secrets: inherit`.

PyYAML reads the `on:` key as the boolean True; a guard that needs the triggers reads
`document.get("on", document.get(True))`.
"""

from __future__ import annotations

import itertools
import re
from collections.abc import Iterator, Mapping
from pathlib import Path
from typing import Any

import yaml

ALL_SECRETS = "*"

# `secrets.NAME`, `secrets['NAME']` / `secrets["NAME"]`, `secrets[<expression>]`, `toJSON(secrets)`.
# Context names and properties are case-insensitive in GitHub expressions.
_SECRET_DOT = re.compile(r"\bsecrets\s*\.\s*([A-Za-z_][A-Za-z0-9_-]*)", re.IGNORECASE)
_SECRET_INDEX = re.compile(r"\bsecrets\s*\[\s*(?:'([^']*)'|\"([^\"]*)\"|([^\]]*))\s*\]", re.IGNORECASE)
_SECRET_WHOLE = re.compile(r"\bsecrets\b(?!\s*[.\[])", re.IGNORECASE)
_EXPRESSION = re.compile(r"\$\{\{(.*?)\}\}", re.DOTALL)
_MATRIX_REF = re.compile(r"\bmatrix\s*\.\s*([A-Za-z_][A-Za-z0-9_-]*)", re.IGNORECASE)
_QUOTED = re.compile(r"^'((?:[^']|'')*)'$")


class _UniqueKeyLoader(yaml.SafeLoader):
    """SafeLoader that refuses a repeated mapping key."""


def _unique_mapping(loader: yaml.SafeLoader, node: yaml.MappingNode, deep: bool = False) -> dict:
    # Only the keys written in this mapping count: a `<<: *anchor` merge may supply a key the
    # mapping then overrides, which is how merges are meant to be used.
    seen = set()
    for key_node, _ in node.value:
        if key_node.tag == "tag:yaml.org,2002:merge":
            continue
        key = loader.construct_object(key_node, deep=deep)
        if key in seen:
            raise ValueError(f"line {key_node.start_mark.line + 1}: repeated key {key!r}")
        seen.add(key)
    loader.flatten_mapping(node)
    return loader.construct_mapping(node, deep=deep)


_UniqueKeyLoader.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, _unique_mapping)


def document(source: str | Path) -> dict[str, Any]:
    """The whole workflow, from a path or from its text."""
    text = source.read_text(encoding="utf-8") if isinstance(source, Path) else source
    loaded = yaml.load(text, Loader=_UniqueKeyLoader)
    if not isinstance(loaded, dict):
        raise ValueError(f"workflow is not a mapping: {type(loaded).__name__}")
    return loaded


def jobs(source: str | Path | Mapping[str, Any]) -> dict[str, dict[str, Any]]:
    """Each job's name and body, from a path, a workflow's text or a loaded document. Fails on a
    workflow without a jobs mapping or a job that is not a mapping, so a malformed file cannot
    come back as an empty, passing job set."""
    loaded = source if isinstance(source, Mapping) else document(source)
    found = loaded.get("jobs")
    if not isinstance(found, dict) or not found:
        raise ValueError("workflow has no jobs mapping")
    for name, job in found.items():
        if not isinstance(job, dict):
            raise ValueError(f"job {name!r} is not a mapping")
    return found


def strings(value: Any) -> Iterator[str]:
    """Every string in a loaded value, keys included."""
    if isinstance(value, str):
        yield value
    elif isinstance(value, Mapping):
        for key, item in value.items():
            yield from strings(key)
            yield from strings(item)
    elif isinstance(value, (list, tuple)):
        for item in value:
            yield from strings(item)


def secret_names(value: Any) -> set[str]:
    """The secrets a job (or any part of one) reads, upper-cased. ALL_SECRETS stands for every
    secret: `secrets: inherit`, `toJSON(secrets)` or an index that is not a literal."""
    names: set[str] = set()
    if isinstance(value, Mapping) and str(value.get("secrets", "")).strip().lower() == "inherit":
        names.add(ALL_SECRETS)
    for text in strings(value):
        names.update(match.upper() for match in _SECRET_DOT.findall(text))
        # The index and whole-context forms only inside `${{ }}`: in a run script `secrets[@]`
        # is a shell array.
        for expression in _EXPRESSION.findall(text):
            for single, double, _ in _SECRET_INDEX.findall(expression):
                names.add((single or double).upper() if (single or double) else ALL_SECRETS)
            if _SECRET_WHOLE.search(expression):
                names.add(ALL_SECRETS)
    return names


def reads_secret(value: Any, *names: str) -> bool:
    """Whether a job reads any of these secrets (any case), or every secret at once."""
    found = secret_names(value)
    return ALL_SECRETS in found or bool(found & {name.upper() for name in names})


def holds_secret(job: Mapping[str, Any]) -> bool:
    """A job holds secrets if it reads any secret in any form, passes them all on with
    `secrets: inherit`, or runs under a deployment environment, which carries its own secrets."""
    return bool(secret_names(job)) or bool(job.get("environment"))


def runs_on(job: Mapping[str, Any]) -> str:
    """The job's runs-on as written ("" when it has none, as a reusable-workflow call does)."""
    value = job.get("runs-on", "")
    return value if isinstance(value, str) else yaml.safe_dump(value, default_flow_style=True).strip()


def matrix_values(job: Mapping[str, Any], key: str) -> list[Any] | None:
    """Every value `matrix.<key>` takes in a job, from the axis and its include entries, or None
    when the matrix is an expression or the key is nowhere in it (the value is unknown)."""
    matrix = (job.get("strategy") or {}).get("matrix") if isinstance(job.get("strategy"), Mapping) else None
    if not isinstance(matrix, Mapping):
        return None
    found: list[Any] = []
    known = False
    axis = next((v for k, v in matrix.items() if str(k).lower() == key.lower()), None)
    if axis is not None:
        if not isinstance(axis, list):
            return None
        found.extend(axis)
        known = True
    for entry in matrix.get("include") or []:
        if not isinstance(entry, Mapping):
            return None
        for k, v in entry.items():
            if str(k).lower() == key.lower():
                found.append(v)
                known = True
    if isinstance(matrix.get("include"), str):
        return None
    return found if known else None


def _scalar_text(value: Any) -> str:
    return value if isinstance(value, str) else ("true" if value is True else "false" if value is False else str(value))


def expand_matrix(job: Mapping[str, Any], text: str) -> list[str] | None:
    """`text` with each `${{ matrix.KEY }}` replaced by every value the matrix gives it, or None
    when one of them cannot be resolved."""
    whole = re.compile(r"\$\{\{\s*matrix\s*\.\s*([A-Za-z_][A-Za-z0-9_-]*)\s*\}\}", re.IGNORECASE)
    keys = list(dict.fromkeys(whole.findall(text)))
    if not keys:
        return None if _MATRIX_REF.search(text) else [text]
    choices = []
    for key in keys:
        values = matrix_values(job, key)
        if values is None or any(isinstance(v, (Mapping, list)) for v in values):
            return None
        choices.append([_scalar_text(v) for v in values])
    out = []
    for combination in itertools.product(*choices):
        expanded = text
        for key, value in zip(keys, combination):
            expanded = re.sub(r"\$\{\{\s*matrix\s*\.\s*" + re.escape(key) + r"\s*\}\}", value, expanded, flags=re.IGNORECASE)
        if _MATRIX_REF.search(expanded):
            return None
        out.append(expanded)
    return out


def expression_values(expression: str) -> tuple[set[str], set[str]]:
    """The literal values a `${{ }}` expression can take, and the operands it can take a value
    from that are not literals. `c && 'a' || d && 'b' || 'e'` yields ({a, b, e}, set()); a value
    read from a context (`needs.x.outputs.y`) comes back in the second set, and the guard decides."""
    values: set[str] = set()
    unresolved: set[str] = set()
    for alternative in re.split(r"\|\|", expression):
        term = re.split(r"&&", alternative)[-1].strip()
        while term.startswith("(") and term.endswith(")"):
            term = term[1:-1].strip()
        quoted = _QUOTED.match(term)
        if quoted:
            values.add(quoted.group(1).replace("''", "'"))
        else:
            unresolved.add(term)
    return values, unresolved


def environment_values(job: Mapping[str, Any]) -> tuple[set[str], set[str]]:
    """Every environment name a job's `environment:` can resolve to (matrix values expanded,
    literal branches of an expression read), and every part it could not resolve. A guard counts
    a job with an unresolved part as unclassified, never as outside the environment."""
    env = job.get("environment")
    if isinstance(env, Mapping):
        env = env.get("name")
    if env is None or env == "":
        return set(), set()
    if not isinstance(env, str):
        return set(), {repr(env)}
    expanded = expand_matrix(job, env.strip())
    if expanded is None:
        return set(), {env.strip()}
    values: set[str] = set()
    unresolved: set[str] = set()
    for text in expanded:
        expressions = _EXPRESSION.findall(text)
        if not expressions:
            values.add(text)
        elif len(expressions) == 1 and text.startswith("${{") and text.endswith("}}"):
            found, open_terms = expression_values(expressions[0])
            values |= found
            unresolved |= open_terms
        else:
            unresolved.add(text)
    return values, unresolved
