"""A workflow's jobs and what they hold, read the way GitHub reads them. Every guard that
derives a job list from a workflow (which jobs hold secrets, which run in a release
environment, which gate a merge) reads it through this one module.

Jobs come from a YAML loader, not from matching header lines: a header regex such as
`\\n  ([A-Za-z0-9_-]+):\\n` misses `  deploy-x: # note`, folds that job into the one before
it, and the job escapes the guard. The loader also refuses a repeated key, which PyYAML
would otherwise resolve by keeping the last job of that name.

Secrets are matched in every form GitHub accepts: `secrets.X`, `secrets['X']`,
`secrets["X"]`, any case, `toJSON(secrets)`, `secrets.*`, a computed index and `secrets: inherit`.
Each `${{ }}` is read by a tokenizer (expressions(), context_reads()), not a regex: a string
literal may hold `}}` (a format() writing JSON braces), and the reference may sit in any function,
index or operator (Codex review of #40784 at 96e5261c). Value resolution refuses unterminated
expressions; substitutions replace whole expression spans, never text inside a string literal.

PyYAML reads the `on:` key as the boolean True; a guard that needs the triggers reads
`document.get("on", document.get(True))`.
"""

from __future__ import annotations

import itertools
import json
import re
from collections.abc import Callable, Iterator, Mapping
from pathlib import Path
from typing import Any, NamedTuple

import yaml

ALL_SECRETS = "*"

# `secrets.NAME` in text outside `${{ }}`: an `if:` is an expression without the braces. Inside `${{ }}` every form
# is read by tokens (context_reads), never by a regex over the expression: in a run script `secrets[@]` is a shell
# array, and a name inside a string literal is text (review F1 on #41015: `'inputs.runner'` read as a self-reference
# and made a false loop).
# Context names and properties are case-insensitive in GitHub expressions.
_SECRET_DOT = re.compile(r"\bsecrets\s*\.\s*([A-Za-z_][A-Za-z0-9_-]*)", re.IGNORECASE)
_QUOTED = re.compile(r"^'((?:[^']|'')*)'$")
_IDENTIFIER = re.compile(r"[A-Za-z_][A-Za-z0-9_-]*")
# variable_reads(whole=True) only: a plain string a guard counts whole, its quotes text, not literals. `vars.NAME`
# (after dotted(), `vars['NAME']` too), and one whose name is not a literal, `vars[<expression>]` or the whole
# context (`toJSON(vars)`). Not `inputs.vars` or `x.vars`: a property of another.
_VAR_DOT = re.compile(r"(?<![\w.-])vars\s*\.\s*([A-Za-z_][A-Za-z0-9_]*)", re.IGNORECASE)
_VAR_OPEN = re.compile(r"(?<![\w.-])vars\s*(?=\[|\)|,)", re.IGNORECASE)


# The expression tokenizer, the same rule as the build-fleet repository's scripts/lib/actions_expr.py (Codex on
# hq#9175): an expression ends at the first `}}` outside every string literal, a literal is single-quoted with `''`
# for a quote (or double-quoted, read as cmux reads `vars["X"]`), and text inside a literal reads no context:
# `${{ 'vars.X' }}` is the text "vars.X". Numbers are Actions' literals: `-1`, `1.5`, `1e+2`, `1E-3`, `0x1F`.
_TOKEN = re.compile(r"\s*(?:(?P<string>'(?:[^']|'')*'|\"[^\"]*\")"
                    r"|(?P<number>-?(?:0[xX][0-9a-fA-F]+|0[oO][0-7]+|(?:[0-9]+\.?[0-9]*|\.[0-9]+)(?:[eE][+-]?[0-9]+)?))"
                    r"|(?P<name>[A-Za-z_][A-Za-z0-9_-]*)|(?P<op>&&|\|\||==|!=|<=|>=|[.\[\](),!<>*])|(?P<bad>\S))")


class Unreadable(ValueError):
    """An expression the tokenizer cannot read: an unterminated `${{` or string, or a character Actions rejects."""


def expression_spans(text: str, strict: bool = False) -> list[tuple[int, int]]:
    """(start, end) of each `${{ ... }}` in `text`, `}}` inside a string literal kept in its expression. One never
    closed raises Unreadable when `strict`; otherwise it and the text after it are no expression."""
    spans: list[tuple[int, int]] = []
    start = text.find("${{")
    while start != -1:
        index, quote = start + 3, ""
        while index < len(text):
            if quote and text[index] == quote:
                quote = ""  # `''` inside a literal closes and reopens it
            elif not quote and text[index] in "'\"":
                quote = text[index]
            elif not quote and text.startswith("}}", index):
                break
            index += 1
        if index >= len(text):
            if strict:
                raise Unreadable(f"unterminated expression: {text[start:]!r}")
            break
        spans.append((start, index + 2))
        start = text.find("${{", index + 2)
    return spans


def expressions(text: str, strict: bool = False) -> list[str]:
    """The bodies of the `${{ }}` expressions in `text` (expression_spans)."""
    return [text[start + 3:end - 2] for start, end in expression_spans(text, strict)]


class _Token(NamedTuple):
    kind: str
    text: str
    start: int
    end: int


def _token_spans(expression: str) -> list[_Token]:
    """Each token of one expression body with where it sits in it (tokens)."""
    out: list[_Token] = []
    position = 0
    while position < len(expression):
        match = _TOKEN.match(expression, position)
        if match is None:  # only trailing whitespace is left
            break
        kind = match.lastgroup
        if kind == "bad":
            raise Unreadable(f"unreadable character {match.group(kind)!r} in {expression!r}")
        out.append(_Token(kind, match.group(kind), match.start(kind), match.end(kind)))
        position = match.end()
    return out


def tokens(expression: str) -> list[tuple[str, str]]:
    """`(kind, text)` for each token of one expression body: string, number, name or op."""
    return [(token.kind, token.text) for token in _token_spans(expression)]


def _literal(token: tuple[str, ...]) -> str | None:
    kind, text = token[0], token[1]
    if kind != "string":
        return None
    return text[1:-1].replace("''", "'") if text[0] == "'" else text[1:-1]


def context_reads(expression: str, context: str) -> list[str | None]:
    """Each read of `context` (`inputs`, `vars`, `secrets`, `matrix`; any case) in one expression body, read by
    tokens: `ctx.NAME`, `ctx['NAME']` and `ctx["NAME"]` give NAME as written; a read whose name is not a literal
    (`ctx[<expression>]`, `toJSON(ctx)`) gives None. A name inside a string literal is text, not a read
    (`'inputs.runner'`, `format('inputs.x-{0}', ...)`), `github.event.inputs.x` is a property of another context,
    and `inputs.runner_count` is not `inputs.runner`. Raises Unreadable for an expression the tokenizer cannot read."""
    stream = _token_spans(expression)
    found: list[str | None] = []
    for index, token in enumerate(stream):
        if token.kind != "name" or token.text.lower() != context:
            continue
        if index and stream[index - 1][:2] == ("op", "."):
            continue
        after = stream[index + 1:index + 4]
        if len(after) >= 2 and after[0][:2] == ("op", ".") and after[1].kind == "name":
            found.append(after[1].text)
        elif len(after) >= 3 and after[0][:2] == ("op", "[") and after[2][:2] == ("op", "]"):
            found.append(_literal(after[1]))
        else:
            found.append(None)
    return found


def _input_term(term: str) -> str | None:
    """The input a whole term reads, `inputs.X` or `inputs['X']` and nothing else, by tokens; else None."""
    try:
        stream = tokens(term)
    except Unreadable:
        return None
    if not stream or stream[0][0] != "name" or stream[0][1].lower() != "inputs":
        return None
    if len(stream) == 3 and stream[1] == ("op", ".") and stream[2][0] == "name":
        return stream[2][1]
    if len(stream) == 4 and stream[1] == ("op", "[") and stream[3] == ("op", "]"):
        return _literal(stream[2])
    return None


def _input_reads(text: str) -> list[str]:
    """Every input the `${{ }}` expressions in `text` read by a literal name, lower-cased, in order, once each. An
    expression the tokenizer cannot read gives none: variable_reads already records it as a read no declaration
    names, so the guard fails closed on it."""
    names: dict[str, None] = {}
    for body in expressions(text):
        try:
            names.update((name.lower(), None) for name in context_reads(body, "inputs") if name is not None)
        except Unreadable:
            continue
    return list(names)


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


class Job(dict):
    """A job's own mapping, as written, plus the workflow-level `env:` it inherits (`inherited_env`) and the workflow
    it sits in (`document`, for what a job reads from a sibling: `fromJSON(needs.x.outputs.y)`). GitHub hands a
    workflow's env to every job, so a secret there is in every job's reach: secret_names() and holds_secret() read
    it with the job's own env, steps and `with:`/`secrets:`. The mapping itself stays the job's own keys, so a guard
    that compares or prints a job sees what the file says. Copy a job with copy_job (or job.copy(), or
    copy.deepcopy): `{**job}` and `dict(job)` drop what it inherits, and the detector test refuses them."""

    def __init__(self, job: Mapping[str, Any], inherited_env: Any = None, document: Any = None) -> None:
        super().__init__(job)
        self.inherited_env = inherited_env or {}
        self.document = document

    def copy(self) -> Job:  # dict.copy() would return a plain dict
        return copy_job(self)


DROP = object()


def copy_job(job: Mapping[str, Any], changes: Mapping[str, Any] | None = None) -> Job:
    """A shallow copy of `job` with `changes` applied (a DROP value removes the key), keeping the workflow env and
    document it inherits. The one way a guard or fixture copies a job: `{**job}` and `dict(job)` drop them, so a
    workflow-env secret or a sibling's matrix output would fall out of the copy."""
    out = Job(job, getattr(job, "inherited_env", None), getattr(job, "document", None))
    for key, value in (changes or {}).items():
        if value is DROP:
            out.pop(key, None)
        else:
            out[key] = value
    return out


# A Job dumps as the mapping it is (yaml.safe_dump(job), as guards print or search a job).
yaml.SafeDumper.add_representer(Job, yaml.representer.SafeRepresenter.represent_dict)
yaml.Dumper.add_representer(Job, yaml.representer.SafeRepresenter.represent_dict)


def inheriting(document: Mapping[str, Any]) -> dict[str, Any]:
    """A copy of `document` whose every job is a Job inheriting the document's own `env:` (a fixture that adds a
    workflow env or a job to a loaded workflow rebinds them this way)."""
    out = dict(document)
    found = out.get("jobs")
    if isinstance(found, dict):
        env = out.get("env") or {}
        out["jobs"] = {name: Job(job, env, out) if isinstance(job, dict) else job for name, job in found.items()}
    return out


def document(source: str | Path) -> dict[str, Any]:
    """The whole workflow, from a path or from its text. Each job is a Job, carrying the workflow env it inherits."""
    text = source.read_text(encoding="utf-8") if isinstance(source, Path) else source
    loaded = yaml.load(text, Loader=_UniqueKeyLoader)
    if not isinstance(loaded, dict):
        raise ValueError(f"workflow is not a mapping: {type(loaded).__name__}")
    return inheriting(loaded)


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
    # A document loaded elsewhere (or a job a fixture added) still inherits the workflow env and sits in the
    # workflow: a plain job is wrapped in place, so a guard that edits a job it got back edits the document's job.
    env = loaded.get("env") or {}
    wrapped = {name: job if isinstance(job, Job) else Job(job, env, loaded) for name, job in found.items()}
    if all(wrapped[name] is job for name, job in found.items()):
        return found
    try:
        found.update(wrapped)
    except (AttributeError, TypeError):  # a read-only mapping: hand back the wrapped copy
        return wrapped
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


def _expression_parts(text: str) -> tuple[str, list[str]]:
    """`text` outside every `${{ }}`, and the body of each (expression_spans), one that never closes read to the end
    of `text` as a body: what a guard counts in it is counted, never dropped."""
    spans = expression_spans(text)
    outside, bodies, at = [], [], 0
    for start, end in spans:
        outside.append(text[at:start])
        bodies.append(text[start + 3:end - 2])
        at = end
    tail = text.find("${{", at)
    if tail != -1:
        outside.append(text[at:tail])
        bodies.append(text[tail + 3:])
    else:
        outside.append(text[at:])
    return " ".join(outside), bodies


def expression_secrets(expression: str) -> set[str]:
    """The secrets one expression's contents read, upper-cased: `secrets.X` and `secrets['X']` name X; the object
    filter `secrets.*`, a computed index and the whole context (`toJSON(secrets)`, `format('{0}', secrets)`, any
    other use) are ALL_SECRETS. `secrets` counts only as a context, never after a `.` (`needs.a.outputs.secrets`)
    or inside a string literal. An expression the tokenizer cannot read reads every secret."""
    try:
        found = context_reads(expression, "secrets")
    except Unreadable:  # what it reads is unknown: every secret
        return {ALL_SECRETS}
    return {ALL_SECRETS if name is None else name.upper() for name in found}


def secret_names(value: Any) -> set[str]:
    """The secrets a job (or any part of one) reads, upper-cased. ALL_SECRETS stands for every
    secret: `secrets: inherit`, `toJSON(secrets)`, `secrets.*` or an index that is not a literal. For a Job this is
    its effective set: the workflow env it inherits, then its own env, steps, `with:` and `secrets:`."""
    names: set[str] = set()
    if isinstance(value, Job) and value.inherited_env:
        names |= secret_names(value.inherited_env)
    if isinstance(value, Mapping) and str(value.get("secrets", "")).strip().lower() == "inherit":
        names.add(ALL_SECRETS)
    for text in strings(value):
        outside, bodies = _expression_parts(text)
        # Outside `${{ }}` only the dot form (an `if:`): in a run script `secrets[@]` is a shell array.
        names.update(match.upper() for match in _SECRET_DOT.findall(outside))
        for body in bodies:
            names |= expression_secrets(body)
    return names


def reads_secret(value: Any, *names: str) -> bool:
    """Whether a job reads any of these secrets (any case), or every secret at once."""
    found = secret_names(value)
    return ALL_SECRETS in found or bool(found & {name.upper() for name in names})


def holds_secret(job: Mapping[str, Any]) -> bool:
    """A job holds secrets if it reads any secret in any form, passes them all on with
    `secrets: inherit`, or runs under a deployment environment, which carries its own secrets."""
    return bool(secret_names(job)) or environment_spec(job) is not None


def runs_on(job: Mapping[str, Any]) -> str:
    """The job's runs-on as written ("" when it has none, as a reusable-workflow call does)."""
    value = job.get("runs-on", "")
    return value if isinstance(value, str) else yaml.safe_dump(value, default_flow_style=True).strip()


def _raw_matrix(job: Mapping[str, Any]) -> Any:
    """The job's `strategy.matrix` as written (an expression stays a string)."""
    return (job.get("strategy") or {}).get("matrix") if isinstance(job.get("strategy"), Mapping) else None


_FROM_JSON = re.compile(r"fromJSON\s*\(\s*(.*?)\s*\)", re.IGNORECASE | re.DOTALL)
_NEEDS_OUTPUT = re.compile(r"needs\.([A-Za-z0-9_-]+)\.outputs\.([A-Za-z0-9_-]+)", re.IGNORECASE)
_STEP_OUTPUT = re.compile(r"\$\{\{\s*steps\.([A-Za-z0-9_-]+)\.outputs\.([A-Za-z0-9_-]+)\s*\}\}", re.IGNORECASE)


def _needs_output_literal(job: Mapping[str, Any], producer: str, key: str) -> str | None:
    """The literal text a sibling job's output holds, when it is one: the output written as a literal, or a step
    output its one `echo 'KEY=<literal>' >> "$GITHUB_OUTPUT"` line writes with nothing the shell expands. None
    for anything computed (a script, a variable), which leaves the matrix unresolved."""
    document = getattr(job, "document", None)
    producer_job = ((document or {}).get("jobs") or {}).get(producer) if isinstance(document, Mapping) else None
    outputs = producer_job.get("outputs") if isinstance(producer_job, Mapping) else None
    if not isinstance(outputs, Mapping):
        return None
    value = next((v for k, v in outputs.items() if str(k).lower() == key.lower()), None)
    if not isinstance(value, str):
        return None
    value = dotted(value).strip()
    if "${{" not in value:
        return value
    step_ref = _STEP_OUTPUT.fullmatch(value)
    if step_ref is None:
        return None
    step = next((s for s in producer_job.get("steps") or [] if isinstance(s, Mapping) and s.get("id") == step_ref.group(1)), None)
    run = step.get("run") if isinstance(step, Mapping) else None
    if not isinstance(run, str):
        return None
    name = re.escape(step_ref.group(2))
    writes = [line for line in run.splitlines() if re.search(rf"\b{name}=", line) or "GITHUB_OUTPUT" in line]
    write = re.compile(rf"""\s*echo\s+(?:'{name}=([^']*)'|"{name}=([^"$`\\]*)")\s*>>\s*(?:"\$GITHUB_OUTPUT"|\$GITHUB_OUTPUT|"\$\{{GITHUB_OUTPUT\}}")\s*""")
    if len(writes) != 1:
        return None
    found = write.fullmatch(writes[0])
    if found is None:
        return None
    literal = found.group(1) if found.group(1) is not None else found.group(2)
    return None if "${{" in literal else literal


def _matrix(job: Mapping[str, Any]) -> Mapping[str, Any] | None:
    """The job's matrix as a mapping: as written, or a `${{ fromJSON(...) }}` of a literal JSON object (in the
    expression, or a sibling's output that holds one). None for a matrix nothing here can read."""
    matrix = _raw_matrix(job)
    if isinstance(matrix, Mapping):
        return matrix
    if not isinstance(matrix, str):
        return None
    text = matrix.strip()
    try:
        spans = expression_spans(text, strict=True)
    except Unreadable:
        return None
    called = _FROM_JSON.fullmatch(text[3:-2].strip()) if spans == [(0, len(text))] else None
    if called is None:
        return None
    argument = dotted("${{ " + called.group(1) + " }}")[3:-2].strip()
    quoted = _QUOTED.match(argument)
    if quoted:
        payload = quoted.group(1).replace("''", "'")
    else:
        needs = _NEEDS_OUTPUT.fullmatch(argument)
        payload = _needs_output_literal(job, needs.group(1), needs.group(2)) if needs else None
    if payload is None:
        return None
    try:
        loaded = json.loads(payload)
    except ValueError:
        return None
    return loaded if isinstance(loaded, Mapping) else None


def _matrix_cells(job: Mapping[str, Any], key: str) -> list[tuple[str, Any]] | None:
    """matrix_values with the key path of each value (`strategy.matrix.runner[1]`, `strategy.matrix.include[0].runner`)."""
    matrix = _matrix(job)
    if not isinstance(matrix, Mapping):
        return None
    found: list[tuple[str, Any]] = []
    known = False
    axis_key = next((k for k in matrix if str(k).lower() == key.lower()), None)
    if axis_key is not None:
        axis = matrix[axis_key]
        if not isinstance(axis, list):
            return None
        found.extend((f"strategy.matrix.{axis_key}[{index}]", value) for index, value in enumerate(axis))
        known = True
    for index, entry in enumerate(matrix.get("include") or []):
        if not isinstance(entry, Mapping):
            return None
        for k, v in entry.items():
            if str(k).lower() == key.lower():
                found.append((f"strategy.matrix.include[{index}].{k}", v))
                known = True
    if isinstance(matrix.get("include"), str):
        return None
    return found if known else None


def matrix_values(job: Mapping[str, Any], key: str) -> list[Any] | None:
    """Every value `matrix.<key>` takes in a job, from the axis and its include entries, or None
    when the matrix is an expression nothing reads (_matrix) or the key is nowhere in it (the value is unknown)."""
    cells = _matrix_cells(job, key)
    return None if cells is None else [value for _, value in cells]


def _scalar_text(value: Any) -> str:
    return value if isinstance(value, str) else ("true" if value is True else "false" if value is False else str(value))


def _dotted_body(body: str) -> str:
    """One expression body with each literal index after a name in dot form, by tokens: a `['x']` inside a string
    literal is text and stays as written. One the tokenizer cannot read stays as written."""
    try:
        stream = _token_spans(body)
    except Unreadable:
        return body
    out, at, rewritten = [], 0, set()
    for index in range(1, len(stream) - 2):
        opener, literal, closer = stream[index:index + 3]
        name = _literal(literal)
        # After a name, or after an index just rewritten to one: `matrix['a']['b']` is `matrix.a.b`.
        if ((stream[index - 1].kind == "name" or index - 1 in rewritten) and opener[:2] == ("op", "[")
                and closer[:2] == ("op", "]") and name is not None and _IDENTIFIER.fullmatch(name)):
            out += [body[at:opener.start], ".", name]
            at = closer.end
            rewritten.add(index + 2)
    return "".join(out) + body[at:]


def dotted(text: str) -> str:
    """`text` with every literal index inside `${{ }}` written in dot form: `matrix['runner']` is `matrix.runner`,
    `needs['a'].outputs['b']` is `needs.a.outputs.b`, `inputs["x"]` is `inputs.x`. Read by tokens, so text inside a
    string literal is never rewritten. An unterminated expression leaves the text unchanged;
    value resolution then refuses it."""
    try:
        spans = expression_spans(text, strict=True)
    except Unreadable:
        return text
    out, at = [], 0
    for start, end in spans:
        out += [text[at:start], "${{", _dotted_body(text[start + 3:end - 2]), "}}"]
        at = end
    return "".join(out) + text[at:]


def _matrix_shape(text: str) -> tuple[list[tuple[int, int, str]], bool] | None:
    """Each `${{ matrix.KEY }}` in `text` that is a whole expression ((start, end, KEY)), and whether any other
    expression reads the matrix, by tokens (a `'matrix.x'` literal is no read); None when one cannot be read."""
    wholes: list[tuple[int, int, str]] = []
    other = False
    try:
        spans = expression_spans(text, strict=True)
    except Unreadable:
        return None
    for start, end in spans:
        body = text[start + 3:end - 2]
        try:
            stream = tokens(body)
            reads = context_reads(body, "matrix")
        except Unreadable:
            return None
        if (len(stream) == 3 and stream[0][0] == "name" and stream[0][1].lower() == "matrix"
                and stream[1] == ("op", ".") and stream[2][0] == "name"):
            wholes.append((start, end, stream[2][1]))
        elif reads:
            other = True
    return wholes, other


def expand_matrix(job: Mapping[str, Any], text: str, reads: "VarReads | None" = None) -> list[str] | None:
    """`text` with each `${{ matrix.KEY }}` replaced by every value the matrix gives it, or None
    when one of them cannot be resolved. `reads` records the variables each value it takes reads."""
    text = dotted(text)
    shape = _matrix_shape(text)
    if shape is None or shape[1]:
        return None
    wholes = shape[0]
    keys = list(dict.fromkeys(key for _, _, key in wholes))
    if not keys:
        return [text]
    choices = []
    for key in keys:
        cells = _matrix_cells(job, key)
        if cells is None or any(isinstance(v, (Mapping, list)) for _, v in cells):
            return None
        if reads is not None:
            for path, value in cells:
                reads.note(path, _scalar_text(value))
        choices.append([_scalar_text(v) for _, v in cells])
    out = []
    for combination in itertools.product(*choices):
        chosen = dict(zip(keys, combination))
        parts, at = [], 0
        for start, end, key in wholes:
            parts += [text[at:start], chosen[key]]
            at = end
        expanded = dotted("".join(parts) + text[at:])  # a matrix value may itself index: ${{ vars['X'] }}
        again = _matrix_shape(expanded)
        if again is None or again[0] or again[1]:
            return None
        out.append(expanded)
    return out


def _split_top(expression: str, operator: str) -> list[str]:
    """`expression` split at `operator` (`||` or `&&`) outside quotes and parentheses."""
    parts, depth, quoted, start, index = [], 0, False, 0, 0
    while index < len(expression):
        char = expression[index]
        if char == "'":
            quoted = not quoted  # '' inside a literal toggles twice
        elif not quoted and char in "([":
            depth += 1
        elif not quoted and char in ")]":
            depth -= 1
        elif not quoted and depth == 0 and expression.startswith(operator, index):
            parts.append(expression[start:index])
            start = index + len(operator)
            index = start
            continue
        index += 1
    parts.append(expression[start:])
    return parts


def _wrapped(term: str) -> bool:
    """`term` is one parenthesized group, `( ... )`, not `(a) || (b)`."""
    if not (term.startswith("(") and term.endswith(")")):
        return False
    depth, quoted = 0, False
    for index, char in enumerate(term):
        if char == "'":
            quoted = not quoted
        elif not quoted and char == "(":
            depth += 1
        elif not quoted and char == ")":
            depth -= 1
            if depth == 0 and index != len(term) - 1:
                return False
    return True


def _property_chain(stream: list[tuple[str, str]]) -> list[str | int] | None:
    """The keys of a property chain (`.a`, `['a']`, `[0]`) that is the whole of STREAM, or None."""
    keys: list[str | int] = []
    index = 0
    while index < len(stream):
        if stream[index] == ("op", ".") and index + 1 < len(stream) and stream[index + 1][0] == "name":
            keys.append(stream[index + 1][1])
            index += 2
        elif (stream[index] == ("op", "[") and index + 2 < len(stream) and stream[index + 2] == ("op", "]")
              and stream[index + 1][0] in ("string", "number")):
            key = stream[index + 1]
            if key[0] == "string":
                keys.append(_literal(key) or "")
            elif key[1].isdigit():
                keys.append(int(key[1]))
            else:
                return None
            index += 3
        else:
            return None
    return keys


def constant_from_json(term: str) -> list[str] | None:
    """The values a `fromJSON('<literal>')` term takes, with any property chain after it (`.mac`, `['mac']`,
    `[0]`): a string is itself, a number or boolean its text, an array of those each of its items (a runs-on
    array is its labels). None for anything else: not that shape, JSON that does not parse, a key it lacks
    (GitHub reads null), or a value that is an object or null. Object keys match without case, as GitHub's do."""
    try:
        stream = tokens(term)
    except Unreadable:
        return None
    if (len(stream) < 4 or stream[0][0] != "name" or stream[0][1].lower() != "fromjson" or stream[1] != ("op", "(")
            or stream[2][0] != "string" or stream[3] != ("op", ")")):
        return None
    keys = _property_chain(stream[4:])
    if keys is None:
        return None
    try:
        value = json.loads(_literal(stream[2]) or "")
    except ValueError:
        return None
    for key in keys:
        if isinstance(value, Mapping) and isinstance(key, str):
            value = next((v for k, v in value.items() if str(k).lower() == key.lower()), None)
        elif isinstance(value, list) and isinstance(key, int) and key < len(value):
            value = value[key]
        else:
            return None
    items = value if isinstance(value, list) else [value]
    if not items or any(item is None or isinstance(item, (Mapping, list)) for item in items):
        return None
    return [_scalar_text(item) for item in items]


def expression_values(expression: str) -> tuple[set[str], set[str]]:
    """The literal values a `${{ }}` expression can take, and the operands it can take a value
    from that are not literals. `c && 'a' || d && 'b' || 'e'` yields ({a, b, e}, set()); a value
    read from a context (`needs.x.outputs.y`) comes back in the second set, and the guard decides.
    `||` and `&&` split only outside quotes and parentheses, so `(a || b) && 'x' || 'y'` is {x, y}.
    A constant `fromJSON('<literal>')` is its values (constant_from_json): `fromJSON('["a"]')` is {a}."""
    values: set[str] = set()
    unresolved: set[str] = set()
    for alternative in _split_top(expression, "||"):
        term = _split_top(alternative, "&&")[-1].strip()
        if _wrapped(term):
            found, open_terms = expression_values(term[1:-1])
            values |= found
            unresolved |= open_terms
            continue
        quoted = _QUOTED.match(term)
        constant = None if quoted else constant_from_json(term)
        if quoted:
            values.add(quoted.group(1).replace("''", "'"))
        elif constant is not None:
            values.update(constant)
        else:
            unresolved.add(term)
    return values, unresolved


Tracer = Callable[[str], "tuple[set[str], set[str]] | None"]


def variable_reads(text: str, whole: bool = False) -> list[str | None]:
    """Each repository variable `text` reads inside `${{ }}`, upper-cased because GitHub matches variable names
    without case; None for a read whose name is not a literal (`vars[format(...)]`, `toJSON(vars)`), which no
    declaration can name, and for an expression the tokenizer cannot read (one never closed, a character Actions
    rejects). Read by tokens: a name inside a string literal is no read (`${{ 'vars.X' }}` is text), a `}}` inside
    one does not end the expression, and `github.vars` is a property, not the context. With `whole`, `text` is a
    plain string (no `${{`) that a guard counts whole, read as it stands: its quotes are text, not literals."""
    if whole:
        expression = dotted("${{" + text + "}}")
        return ([name.upper() for name in _VAR_DOT.findall(expression)]
                + [None] * len(_VAR_OPEN.findall(expression)))
    found: list[str | None] = []
    try:
        for body in expressions(text, strict=True):
            found += [name.upper() if name is not None else None for name in context_reads(body, "vars")]
    except Unreadable:
        return [None]
    return found


class VarRead(NamedTuple):
    """One `vars` operand the resolve step consumed: the variable (upper-cased; None when its name is an
    expression), where it sits (the workflow file, the job id, the key path in that job: `runs-on`,
    `strategy.matrix.include[0].runner`, `with.runner`; job "" and `on.workflow_call...` or `env.X` for a
    workflow-level value), the text it sits in as written, and the field whose resolving consumed it (`runs-on`,
    `environment`, `name`, `env`)."""
    name: str | None
    file: str | None
    job: str
    path: str
    text: str
    field: str


class Unverifiable(NamedTuple):
    """A trace the resolve step refused to finish: `inputs.<name>` of `workflow` loops back to itself (for one
    caller, a default that names itself or two inputs whose defaults name each other; a call cycle) or nests past
    MAX_TRACE_DEPTH. What it would read is unknown, so a guard treats it as a finding, never as "reads nothing".
    Defaults are read per caller, so two callers whose chains are each finite never make a loop together."""
    workflow: str
    name: str
    reason: str
    field: str


# How many reusable-workflow inputs one trace may pass through (callers' `with:` values and defaults alike).
MAX_TRACE_DEPTH = 32


class _Trace:
    """One field's trace through Workflows: each input's values once per trace, memoised on (workflow, input) for
    the values every caller gives it and on (workflow, caller, caller job, input) for one caller's, so a chain of
    inputs costs O(callers x inputs), never 2^inputs. `open` holds what is being traced now: meeting one again is a
    loop. `depth` counts the inputs on the way down."""

    def __init__(self) -> None:
        self.done: dict[tuple, tuple[set[str], set[str]]] = {}
        self.open: set[tuple] = set()
        self.depth = 0


class VarReads:
    """What one field's resolve consumed: every `vars` operand of every text it read (the field as written, each
    matrix value it took, each caller's `with:` value and declared default an input it read came from, at any
    call depth, conditions included), each with where it sits. A matrix nothing could expand counts whole."""

    def __init__(self, field: str, file: str | None = None, job: str = "") -> None:
        self.field, self.file, self.job = field, file, job
        self.found: set[VarRead] = set()
        self.unverifiable: set[Unverifiable] = set()

    def at(self, file: str | None, job: str) -> "VarReads":
        """The same record, for texts in another job (a caller's)."""
        other = VarReads(self.field, file, job)
        other.found, other.unverifiable = self.found, self.unverifiable
        return other

    def refuse(self, workflow: str, name: str, reason: str) -> None:
        self.unverifiable.add(Unverifiable(workflow, name, reason, self.field))

    def note(self, path: str, text: str, whole: bool = False) -> None:
        for name in variable_reads(text, whole):
            self.found.add(VarRead(name, self.file, self.job, path, text, self.field))


def _strings_at(value: Any, path: str) -> Iterator[tuple[str, str]]:
    """Every string in a loaded value with its key path (keys at their mapping's path)."""
    if isinstance(value, str):
        yield path, value
    elif isinstance(value, Mapping):
        for key, item in value.items():
            if isinstance(key, str):
                yield path, key
            yield from _strings_at(item, f"{path}.{key}")
    elif isinstance(value, (list, tuple)):
        for index, item in enumerate(value):
            yield from _strings_at(item, f"{path}[{index}]")


def _note_unexpanded_matrix(job: Mapping[str, Any], reads: "VarReads") -> None:
    """A matrix nothing could expand (an expression such as fromJSON(vars.X), a key it lacks, a condition on a
    matrix value): the value may come from any part of it, so every variable anywhere in it counts (fail closed).
    A string with no `${{` counts as one operand, as the scan before the resolve step read it."""
    for path, text in _strings_at(_raw_matrix(job), "strategy.matrix"):
        reads.note(path, text, whole="${{" not in text)


def _resolve(job: Mapping[str, Any], text: str, tracer: Tracer | None = None, reads: VarReads | None = None,
             path: str = "") -> tuple[set[str], set[str]]:
    """The literal values `text` (a value as written in the job) can take, literal indexes read in dot form,
    matrix cells expanded and an expression's literal branches read, and the parts nothing here resolves. A
    `tracer` (Workflows.tracer) resolves a branch that is a reusable workflow's `inputs.X` to its callers' values.
    `reads` records every `vars` operand consumed on the way: in `text` (at `path`), conditions included, in each
    matrix value it took (the whole matrix when it could not expand one), and, through the tracer, in each caller's
    value of every input it reads, as a branch or in a condition."""
    text = text.strip()
    expanded = expand_matrix(job, text, reads)
    if reads is not None:
        reads.note(path, text)
        if expanded is None:
            _note_unexpanded_matrix(job, reads)
        if tracer is not None:
            # An input read anywhere, a condition's included: its callers' values reach this field too.
            sources = expanded if expanded is not None else [text, *(s for _, s in _strings_at(_raw_matrix(job), ""))]
            for name in dict.fromkeys(name for source in sources for name in _input_reads(source)):
                tracer(f"inputs.{name}")
    if expanded is None:
        return set(), {text}
    values: set[str] = set()
    unresolved: set[str] = set()
    for cell in expanded:
        # Keep the base tokenizer's strict unterminated-expression behavior while retaining
        # this branch's caller tracing for every unresolved term.
        try:
            bodies = expressions(cell, strict=True)
        except Unreadable:
            unresolved.add(cell)
            continue
        if not bodies:
            values.add(cell)
        elif len(bodies) == 1 and cell.startswith("${{") and cell.endswith("}}"):
            found, open_terms = expression_values(bodies[0])
            values |= found
            for term in open_terms:
                traced = tracer(term) if tracer else None
                if traced is None:
                    unresolved.add(term)
                else:
                    values |= traced[0]
                    unresolved |= traced[1]
        else:
            unresolved.add(cell)
    return values, unresolved


class Workflows:
    """Every workflow document by file name, for what crosses workflows: a reusable workflow's `inputs.X`
    (or `inputs['X']`) is every value its callers pass as `with: X:`, read in the caller job (its own matrix
    expanded per cell, `matrix['x']` too) and traced through the caller's own inputs at any call depth. An
    input with no caller, a call cycle, or a value nothing resolves stays unresolved, so a guard fails closed."""

    def __init__(self, documents: Mapping[str, Mapping[str, Any]]) -> None:
        self.documents = documents

    def callers(self, workflow: str) -> Iterator[tuple[str, str, Mapping[str, Any]]]:
        for caller, document in self.documents.items():
            for job_id, job in ((document or {}).get("jobs") or {}).items():
                uses = job.get("uses") if isinstance(job, Mapping) else None
                if (isinstance(uses, str) and uses.startswith("./.github/workflows/")
                        and uses.split("@", 1)[0].rsplit("/", 1)[-1] == workflow):
                    yield caller, job_id, job

    def _declared_default(self, workflow: str, name: str) -> Any:
        document = self.documents.get(workflow) or {}
        triggers = document.get("on", document.get(True)) or {}
        call = triggers.get("workflow_call") if isinstance(triggers, Mapping) else None
        declared = (call or {}).get("inputs") or {} if isinstance(call, Mapping) else {}
        spec = next((v for k, v in declared.items() if str(k).lower() == name.lower()), None)
        return spec.get("default") if isinstance(spec, Mapping) else None

    def input_values(self, workflow: str, name: str, reads: VarReads | None = None,
                     _trace: _Trace | None = None) -> tuple[set[str], set[str]]:
        """Every value `inputs.<name>` takes in `workflow`, and what nothing resolves (`inputs.<name>` itself when
        no workflow here calls it). `reads` records the variables each caller's value (or the declared default)
        reads, with the caller's file, job and `with.<name>` path. Each caller is read on its own (_call_value).

        A call cycle (an input whose callers' values come back to it through other workflows) stays unresolved and,
        with `reads`, is recorded as Unverifiable. Within one trace each input is read once (memoised), so a
        workflow called twice by each of a chain of workflows costs O(workflows), never 2^workflows."""
        trace = _trace or _Trace()
        key = (workflow, name.lower())
        if key in trace.done:
            return trace.done[key]
        if key in trace.open:
            if reads is not None:
                reads.refuse(workflow, name, "a loop")
            return set(), {f"inputs.{name}"}
        callers = list(self.callers(workflow))
        if not callers:
            return set(), {f"inputs.{name}"}
        values: set[str] = set()
        unresolved: set[str] = set()
        trace.open.add(key)
        try:
            for call in callers:
                found, open_terms = self._call_value(workflow, call, name, reads, trace)
                values |= found
                unresolved |= open_terms
        finally:
            trace.open.discard(key)
        trace.done[key] = (values, unresolved)
        return values, unresolved

    def _call_value(self, workflow: str, call: tuple[str, str, Mapping[str, Any]], name: str,
                    reads: VarReads | None, trace: _Trace) -> tuple[set[str], set[str]]:
        """The values `inputs.<name>` of `workflow` takes for one caller (`call`: its file, job id and job): its
        `with:` value, read in the caller job, or else the input's declared default, read in `workflow` with every
        `inputs.Y` in it this same caller's Y (Codex on #40979: a default of `${{ inputs.fallback_runner }}` was
        scanned as text, so a caller's `fallback_runner: ${{ vars.X }}` was never read; Codex on #41015: a default
        traced through every caller merged their scopes, so caller A's `fallback_runner` reached caller B's runner
        and two finite chains made a loop). A chain that comes back to an input of the same caller, or passes
        MAX_TRACE_DEPTH inputs, stays unresolved and, with `reads`, is recorded as Unverifiable."""
        caller, caller_job, job = call
        key = (workflow, caller, caller_job, name.lower())
        if key in trace.done:
            return trace.done[key]
        if key in trace.open or trace.depth >= MAX_TRACE_DEPTH:
            if reads is not None:
                reads.refuse(workflow, name, f"a loop for the call in {caller} job {caller_job}"
                             if key in trace.open else f"more than {MAX_TRACE_DEPTH} inputs")
            return set(), {f"inputs.{name}"}
        passed_key = next((k for k in (job.get("with") or {}) if str(k).lower() == name.lower()), None)
        trace.open.add(key)
        trace.depth += 1
        try:
            if passed_key is not None:
                here = reads.at(caller, caller_job) if reads is not None else None
                result = _resolve(job, _scalar_text(job["with"][passed_key]), self.tracer(caller, reads, trace),
                                  here, f"with.{passed_key}")
            else:
                default = self._declared_default(workflow, name)
                if not isinstance(default, str):
                    result = ({"" if default is None else _scalar_text(default)}, set())
                else:
                    def same_call(term: str) -> tuple[set[str], set[str]] | None:
                        name = _input_term(term)
                        return self._call_value(workflow, call, name, reads, trace) if name is not None else None
                    here = reads.at(workflow, "") if reads is not None else None
                    result = _resolve({}, default, same_call, here, f"on.workflow_call.inputs.{name}.default")
        finally:
            trace.open.discard(key)
            trace.depth -= 1
        trace.done[key] = result
        return result

    def tracer(self, workflow: str, reads: VarReads | None = None, _trace: _Trace | None = None) -> Tracer:
        """The tracer for jobs of `workflow`: an `inputs.X` term is input_values(workflow, X); others are None.
        With `reads`, it records the variables the callers' values read. One tracer is one trace: every input it
        reaches is read once."""
        trace = _trace or _Trace()

        def trace_term(term: str) -> tuple[set[str], set[str]] | None:
            name = _input_term(term)
            return self.input_values(workflow, name, reads, trace) if name is not None else None
        return trace_term


def runs_on_items(job: Mapping[str, Any]) -> list[Any]:
    return [item for _, item in _runs_on_paths(job)]


def runs_on_label_cells(job: Mapping[str, Any], workflow: str | None = None,
                        workflows: Workflows | None = None) -> list[tuple[str, ...]] | None:
    """runs_on_cells before it joins a cell's labels: each matrix cell's runs-on as the tuple of labels it asks
    for (one for a string runs-on), so a reader that tells one label from a list of them keeps the difference.
    None and [] as runs_on_cells."""
    cells: list[list[str]] = []
    for item in runs_on_items(job):
        if not isinstance(item, str):
            return None
        expanded = expand_matrix(job, item.strip())
        if expanded is None:
            return None
        if workflows is not None and workflow is not None:
            # A reusable workflow's `${{ inputs.X }}` is each value its callers pass; one nothing resolves stays an
            # expression of what it reads (`${{ vars.X }}`), never a label.
            traced = []
            for cell in expanded:
                cell_text = cell.strip()
                spans = expression_spans(cell_text)
                name = (_input_term(cell_text[3:-2]) if spans == [(0, len(cell_text))] else None)
                if name is None:
                    traced.append(cell)
                    continue
                values, open_terms = workflows.input_values(workflow, name)
                traced.extend([*sorted(values), *(f"${{{{ {term} }}}}" for term in sorted(open_terms))])
            expanded = traced
        cells.append(expanded)
    if not cells:
        return []
    return list(dict.fromkeys(itertools.product(*cells)))


def runs_on_cells(job: Mapping[str, Any], workflow: str | None = None,
                  workflows: Workflows | None = None) -> list[str] | None:
    """The job's runs-on as each matrix cell would write it (`${{ matrix.runner }}` replaced by every value the
    matrix gives it; a list of labels joined by ", "), or None when a matrix value cannot be resolved (a
    fromJSON matrix, a key the matrix lacks): a guard counts such a job as unclassified, never as off its route.
    [] for a job with no runs-on (a reusable-workflow call)."""
    cells = runs_on_label_cells(job, workflow, workflows)
    if cells is None:
        return None
    return list(dict.fromkeys(", ".join(cell) for cell in cells))


class UnresolvedRunsOn(ValueError):
    """A job whose runs-on a guard reading one route cannot read as one."""


def single_runs_on(job: Mapping[str, Any], workflow: str | None = None,
                   workflows: Workflows | None = None) -> str:
    """The one runs-on a job runs on, as runs_on_cells writes it. Raises UnresolvedRunsOn when a matrix value
    cannot be resolved, the job has no runs-on, or its cells differ: a guard that checks one route text refuses a
    job it cannot read as one, instead of checking `${{ matrix.runner }}` and passing every cell."""
    cells = runs_on_cells(job, workflow, workflows)
    if cells is None:
        raise UnresolvedRunsOn(f"runs-on {runs_on(job)!r}: a matrix value cannot be resolved")
    if len(cells) != 1:
        raise UnresolvedRunsOn(f"runs-on {runs_on(job)!r}: {len(cells)} routes ({cells}), not one")
    return cells[0]


def _tracer(workflow: str | None, workflows: Workflows | None, reads: VarReads | None = None) -> Tracer | None:
    return workflows.tracer(workflow, reads=reads) if workflows is not None and workflow is not None else None


def _runs_on_paths(job: Mapping[str, Any]) -> list[tuple[str, Any]]:
    """runs_on_items with the key path of each."""
    raw = job.get("runs-on")
    if isinstance(raw, Mapping):
        labels = raw.get("labels")
        return [*(((f"runs-on.labels[{i}]", v) for i, v in enumerate(labels)) if isinstance(labels, list)
                  else [("runs-on.labels", labels)] if labels else []),
                *([("runs-on.group", raw["group"])] if raw.get("group") else [])]
    if isinstance(raw, list):
        return [(f"runs-on[{i}]", v) for i, v in enumerate(raw)]
    return [] if raw is None or raw == "" else [("runs-on", raw)]


def runs_on_values(job: Mapping[str, Any], workflow: str | None = None, workflows: Workflows | None = None,
                   reads: VarReads | None = None) -> tuple[set[str], set[str]]:
    """Every label a job's runs-on can resolve to (literal indexes read, matrix values expanded, literal branches
    of an expression read, and, given the job's `workflow` file name and every document as `workflows`, a reusable
    workflow's `inputs.X` traced to its callers' `with:` values at any depth), and every part it could not resolve
    (a context such as needs.x.outputs.y or vars.X, or a matrix value nothing gives). A guard counts a job with an
    unresolved part as unclassified, like environment_values. The single-host fallback test reads this."""
    values: set[str] = set()
    unresolved: set[str] = set()
    for path, item in _runs_on_paths(job):
        if not isinstance(item, str):
            unresolved.add(repr(item))
            if reads is not None:  # nothing resolves it, so every variable in it counts
                for at, text in _strings_at(item, path):
                    reads.note(at, text, whole="${{" not in text)
            continue
        found, open_terms = _resolve(job, item, _tracer(workflow, workflows, reads), reads, path)
        values |= found
        unresolved |= open_terms
    return values, unresolved


def environment_spec(job: Mapping[str, Any]) -> dict[str, Any] | None:
    """The job's `environment:` in one shape: None when it has none, else a mapping with `name` (as written; compare
    names through environment_values, which casefolds) and any `url` or `deployment` the file gives."""
    raw = job.get("environment")
    if raw is None or raw == "":
        return None
    return dict(raw) if isinstance(raw, Mapping) else {"name": raw}


def environment_values(job: Mapping[str, Any], workflow: str | None = None, workflows: Workflows | None = None,
                       reads: VarReads | None = None) -> tuple[set[str], set[str]]:
    """Every environment name a job's `environment:` can resolve to (matrix values expanded,
    literal branches of an expression read), casefolded because GitHub matches environment names
    without case (`Release` is `release`), and every part it could not resolve. A guard counts a
    job with an unresolved part as unclassified, never as outside the environment."""
    spec = environment_spec(job)
    env = spec.get("name") if spec is not None else None
    path = "environment.name" if isinstance(job.get("environment"), Mapping) else "environment"
    if env is None or env == "":
        return (set(), set()) if spec is None else (set(), {repr(spec)})
    if not isinstance(env, str):
        return set(), {repr(env)}
    values, unresolved = _resolve(job, env, _tracer(workflow, workflows, reads), reads, path)
    return {value.casefold() for value in values}, unresolved


def name_values(job: Mapping[str, Any], job_id: str, workflow: str | None = None,
                workflows: Workflows | None = None, reads: VarReads | None = None) -> tuple[set[str], set[str]]:
    """The check name a job reports: its `name:` (the job id when it has none) with matrix values
    expanded and literal expressions read (`${{ 'CLA policy guard' }}` is `CLA policy guard`), and
    every part nothing resolves. Check names keep their case. A guard that matches names counts a job
    with an unresolved part as a match (unclassified), never as a different check."""
    name = job.get("name", job_id)
    if not isinstance(name, str):
        return set(), {repr(name)}
    return _resolve(job, name, _tracer(workflow, workflows, reads), reads, "name")


def effective_env(document: Mapping[str, Any] | None, job: Mapping[str, Any],
                  step: Mapping[str, Any] | None = None) -> dict[str, Any]:
    """The env a step sees: the workflow's, then the job's, then the step's, the inner one winning a key, as
    GitHub merges them. Values stay as written; read a path value with repo_path."""
    env: dict[str, Any] = {}
    if document is None:  # a Job knows the workflow env it inherits
        document = {"env": getattr(job, "inherited_env", None) or {}}
    for scope in (document, job, step or {}):
        layer = scope.get("env") if isinstance(scope, Mapping) else None
        if isinstance(layer, Mapping):
            env.update({str(key): value for key, value in layer.items()})
    return env


_WORKSPACE = re.compile(r"^(?:\$\{\{\s*github\.workspace\s*\}\}|\$\{GITHUB_WORKSPACE\}|\$GITHUB_WORKSPACE\b)")


def repo_path(value: str) -> str | None:
    """`value` as a path from the repo root: `${{ github.workspace }}`, `${GITHUB_WORKSPACE}` and
    `$GITHUB_WORKSPACE` are the root (`.`), a relative path is itself; None for anything else (another
    expression or variable, an absolute path), which a guard counts as unresolved."""
    text = value.strip()
    anchored = _WORKSPACE.match(text)
    if anchored:
        text = text[anchored.end():].lstrip("/")
    elif text.startswith("/") or "$" in text:
        return None
    if "$" in text:
        return None
    text = text.rstrip("/")
    return text or "."


def _local_callee(uses: Any) -> str | None:
    if isinstance(uses, str) and uses.startswith("./.github/workflows/"):
        return uses.split("@", 1)[0].rsplit("/", 1)[-1]
    return None


def effective_secrets(job: Mapping[str, Any], workflows: Workflows | None = None,
                      _seen: frozenset = frozenset()) -> tuple[set[str], set[str]]:
    """The secrets a job reads (secret_names), and for a call with `secrets: inherit` also every secret the called
    workflow reads, followed through its own inherited calls at any depth. ALL_SECRETS stays in for the inherit
    itself. The second set names each call nothing here can follow (another repository's workflow, a file the
    documents lack, no Workflows given, a cycle): a guard fails on it."""
    names = secret_names(job)
    unresolved: set[str] = set()
    if str(job.get("secrets", "")).strip().lower() != "inherit":
        return names, unresolved
    callee = _local_callee(job.get("uses"))
    document = workflows.documents.get(callee) if workflows is not None and callee else None
    if not isinstance(document, Mapping) or callee in _seen:
        unresolved.add(str(job.get("uses") or "secrets: inherit"))
        return names, unresolved
    names |= secret_names(document.get("env") or {})
    for called_job in (document.get("jobs") or {}).values():
        if isinstance(called_job, Mapping):
            found, open_calls = effective_secrets(called_job, workflows, _seen | {callee})
            names |= found
            unresolved |= open_calls
    return names, unresolved


# Jobs whose matrix nothing here can read, each with why and what checks it instead. A guard that meets one of
# these skips it by name (audited_matrix); any other unresolved matrix fails. The detector test fails an entry
# whose job is gone or now resolves.
UNRESOLVED_MATRICES: dict[tuple[str, str], str] = {
    ("cmux-tui-build-package.yml", "build"):
        "plan-build's python step computes the target list from runner env at run time; "
        "tests/test_ci_linux_compile_runners.py checks the targets it writes",
    ("cmux-tui-build-package.yml", "verify-linux-packages"):
        "plan-build's python step computes linux_package_matrix at run time; "
        "tests/test_ci_linux_compile_runners.py checks the packages it writes",
    ("cmux-next-fast-tier-seed.yml", "seed"):
        "due's step runs scripts/cmux-next/fast-tier-seed-due.py, which keeps the pools of the job env's literal "
        "SEED_POOLS list whose seed is old; tests/test_cmux_next_checks_workflow.py (SEED_DUE_SCRIPT) checks it",
    ("seed-derived-data.yml", "seed"):
        "decide's shell step computes the pool and root lanes from repository variables at run time; "
        "tests/test_seed_derived_data.py runs that step and checks every lane it writes",
}


def audited_matrix(workflow: str, job_id: str) -> str | None:
    """Why `job_id` in `workflow` (a file name) may have a matrix nothing resolves, or None when it may not."""
    return UNRESOLVED_MATRICES.get((Path(workflow).name, job_id))


class Resolved:
    """Every field a guard compares, read once and normalized: runs-on per matrix cell
    (runs_on_cells, runs_on_values), environment names casefolded (environment_values) and the
    environment in one shape (environment_spec), the check name with literal expressions read
    (name_values), the env the job's steps start from (the workflow's, then the job's: env), and the
    job's effective secrets (the workflow env it inherits, then its env, steps, `with:` and `secrets:`,
    and what a `secrets: inherit` call's workflow reads: effective_secrets). Each `*_unresolved` set,
    and `runs_on_cells is None`, is what nothing here could read: a guard fails closed on it, unless
    `matrix_audit` names why that job's matrix is read elsewhere (UNRESOLVED_MATRICES).

    `vars_read` is every repository variable those fields consumed (VarRead: the variable, the file, job and key
    path it sits at, and the field), wherever it sat: the field as written, a matrix value it took (a matrix
    nothing could expand counts whole), a caller's `with:` value or an input's default at any call depth, inside a
    condition or a fromJSON, in dot or bracket form. A guard about the variables a field reads reads them here,
    never the field's text. `unverifiable` is every trace those fields refused to finish (Unverifiable: a loop or
    a nesting past MAX_TRACE_DEPTH); a guard counts each as a finding. Field `env` holds the variables the job's
    env layers read (the workflow's, then the job's): runs-on, environment and name cannot read the env context, so
    no other field consumes them."""

    def __init__(self, job: Mapping[str, Any], job_id: str = "", workflow: str | None = None,
                 workflows: Workflows | None = None) -> None:
        self.job = job
        self.runs_on_cells = runs_on_cells(job, workflow, workflows)
        reads = {field: VarReads(field, workflow, job_id) for field in ("runs-on", "environment", "name", "env")}
        self.runs_on, self.runs_on_unresolved = runs_on_values(job, workflow, workflows, reads["runs-on"])
        self.environments, self.environments_unresolved = environment_values(job, workflow, workflows,
                                                                             reads["environment"])
        self.names, self.names_unresolved = name_values(job, job_id, workflow, workflows, reads["name"])
        inherited = job.inherited_env if isinstance(job, Job) else {}
        for scope, layer in (("", inherited), (job_id, job.get("env"))):
            for path, text in _strings_at(layer or {}, "env"):
                reads["env"].at(workflow, scope).note(path, text)
        self.vars_read: frozenset[VarRead] = frozenset().union(*(r.found for r in reads.values()))
        self.unverifiable: frozenset[Unverifiable] = frozenset().union(*(r.unverifiable for r in reads.values()))
        self.environment = environment_spec(job)
        self.env = effective_env(None, job)
        self.secrets, self.secrets_unresolved = effective_secrets(job, workflows)
        self.inherits_secrets = str(job.get("secrets", "")).strip().lower() == "inherit"
        passed = job.get("secrets")
        self.passed_secrets = dict(passed) if isinstance(passed, Mapping) else {}
        self.matrix_audit = audited_matrix(workflow, job_id) if workflow and job_id else None

    @property
    def unresolved(self) -> bool:
        """Whether any field is one nothing here could read (a guard counts the job as unclassified)."""
        return (self.runs_on_cells is None or bool(self.runs_on_unresolved or self.environments_unresolved
                                                   or self.names_unresolved or self.secrets_unresolved))


def resolve(job: Mapping[str, Any], job_id: str = "", workflow: str | None = None,
            workflows: Workflows | None = None) -> Resolved:
    """The one resolve step (Resolved). A guard reads a job's runs-on, environment, name and secrets here, never
    the raw field. Given the job's workflow file name and every document (Workflows), a reusable workflow's
    inputs resolve through its callers."""
    return Resolved(job, job_id, workflow, workflows)
