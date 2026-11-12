"""A workflow's jobs and what they hold, read the way GitHub reads them. Every guard that
derives a job list from a workflow (which jobs hold secrets, which run in a release
environment, which gate a merge) reads it through this one module.

Jobs come from a YAML loader, not from matching header lines: a header regex such as
`\\n  ([A-Za-z0-9_-]+):\\n` misses `  deploy-x: # note`, folds that job into the one before
it, and the job escapes the guard. The loader also refuses a repeated key, which PyYAML
would otherwise resolve by keeping the last job of that name.

Secrets are matched in every form GitHub accepts: `secrets.X`, `secrets['X']`,
`secrets["X"]`, any case, `toJSON(secrets)`, `secrets.*`, a computed index and `secrets: inherit`.
Each `${{ }}` is read by a tokenizer (expressions(), expression_tokens()), not a regex: a string
literal may hold `}}` (a format() writing JSON braces), and the reference may sit in any function,
index or operator (Codex review of #40784 at 96e5261c).

PyYAML reads the `on:` key as the boolean True; a guard that needs the triggers reads
`document.get("on", document.get(True))`.
"""

from __future__ import annotations

import itertools
import json
import re
from collections.abc import Callable, Iterator, Mapping
from pathlib import Path
from typing import Any

import yaml

ALL_SECRETS = "*"

# `secrets.NAME` anywhere in a value, inside `${{ }}` or not (a guard counts more, never less). Every other form
# is read inside `${{ }}` only, by expression_tokens(): in a run script `secrets[@]` is a shell array.
# Context names and properties are case-insensitive in GitHub expressions.
_SECRET_DOT = re.compile(r"\bsecrets\s*\.\s*([A-Za-z_][A-Za-z0-9_-]*)", re.IGNORECASE)
_TOKEN = re.compile(r"""\s*(?:(?P<string>'(?:[^']|'')*'?)|(?P<string2>"[^"]*"?)|(?P<number>-?\d[\w.+-]*)"""
                    r"""|(?P<name>[A-Za-z_][A-Za-z0-9_-]*)|(?P<op>==|!=|<=|>=|&&|\|\||[.\[\](),!<>*])|(?P<other>\S))""")
_EXPRESSION = re.compile(r"\$\{\{(.*?)\}\}", re.DOTALL)
_MATRIX_REF = re.compile(r"\bmatrix\s*\.\s*([A-Za-z_][A-Za-z0-9_-]*)", re.IGNORECASE)
_QUOTED = re.compile(r"^'((?:[^']|'')*)'$")
# `ctx['name']` / `ctx["name"]` with a literal name: the same reference as `ctx.name` (matrix, inputs, vars, secrets,
# env, needs and the outputs of either).
_LITERAL_INDEX = re.compile(r"\b([A-Za-z_][A-Za-z0-9_-]*)\s*\[\s*(?:'([A-Za-z_][A-Za-z0-9_-]*)'|\"([A-Za-z_][A-Za-z0-9_-]*)\")\s*\]")
_INPUT_TERM = re.compile(r"\s*inputs\s*\.\s*([A-Za-z_][A-Za-z0-9_-]*)\s*", re.IGNORECASE)
_WHOLE_INPUT = re.compile(r"\$\{\{\s*inputs\s*\.\s*([A-Za-z_][A-Za-z0-9_-]*)\s*\}\}", re.IGNORECASE)


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


def expressions(text: str) -> list[str]:
    """The contents of each `${{ }}` in TEXT, read as GitHub reads them: a `}}` inside a string literal
    (`'...'`, `''` an escaped quote) does not end the expression. One that never ends runs to the end of TEXT."""
    found = []
    start = text.find("${{")
    while start != -1:
        i, quoted = start + 3, False
        while i < len(text):
            if text[i] == "'":
                quoted = not quoted  # `''` inside a string toggles twice: still inside
            elif not quoted and text.startswith("}}", i):
                break
            i += 1
        found.append(text[start + 3:i])
        start = text.find("${{", i + 2)
    return found


def expression_tokens(expression: str) -> list[tuple[str, str]]:
    """(kind, text) for each token of one expression's contents: string, number, name, op or other."""
    tokens = []
    for match in _TOKEN.finditer(expression):
        kind = match.lastgroup
        if kind is None:
            continue
        tokens.append(("string" if kind == "string2" else kind, match.group(kind)))
    return tokens


def _string_value(token: str) -> str:
    body = token[1:-1] if len(token) >= 2 and token[-1] == token[0] else token[1:]
    return body.replace("''", "'") if token.startswith("'") else body


def expression_secrets(expression: str) -> set[str]:
    """The secrets one expression's contents read, upper-cased: `secrets.X` and `secrets['X']` name X; the object
    filter `secrets.*`, a computed index and the whole context (`toJSON(secrets)`, `format('{0}', secrets)`, any
    other use) are ALL_SECRETS. `secrets` counts only as a context, never after a `.` (`needs.a.outputs.secrets`)
    or inside a string literal."""
    tokens = expression_tokens(expression)
    names: set[str] = set()
    for i, (kind, text) in enumerate(tokens):
        if kind != "name" or text.lower() != "secrets" or (i and tokens[i - 1] == ("op", ".")):
            continue
        after = tokens[i + 1:i + 4]
        if after[:1] == [("op", ".")] and len(after) > 1 and after[1][0] == "name":
            names.add(after[1][1].upper())
        elif (after[:1] == [("op", "[")] and len(after) > 2 and after[1][0] == "string"
              and after[2] == ("op", "]")):
            names.add(_string_value(after[1][1]).upper())
        else:
            names.add(ALL_SECRETS)
    return names


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
        names.update(match.upper() for match in _SECRET_DOT.findall(text))
        for expression in expressions(text):
            names |= expression_secrets(expression)
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


_FROM_JSON = re.compile(r"^\$\{\{\s*fromJSON\s*\(\s*(.*?)\s*\)\s*\}\}$", re.IGNORECASE | re.DOTALL)
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
    strategy = job.get("strategy")
    matrix = strategy.get("matrix") if isinstance(strategy, Mapping) else None
    if isinstance(matrix, Mapping):
        return matrix
    if not isinstance(matrix, str):
        return None
    called = _FROM_JSON.match(matrix.strip())
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


def matrix_values(job: Mapping[str, Any], key: str) -> list[Any] | None:
    """Every value `matrix.<key>` takes in a job, from the axis and its include entries, or None
    when the matrix is an expression nothing reads (_matrix) or the key is nowhere in it (the value is unknown)."""
    matrix = _matrix(job)
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


def dotted(text: str) -> str:
    """`text` with every literal index inside `${{ }}` written in dot form: `matrix['runner']` is `matrix.runner`,
    `needs['a'].outputs['b']` is `needs.a.outputs.b`, `inputs["x"]` is `inputs.x`."""
    def one(expression: re.Match) -> str:
        inner = expression.group(0)
        previous = None
        while previous != inner:
            previous = inner
            inner = _LITERAL_INDEX.sub(lambda m: f"{m.group(1)}.{m.group(2) or m.group(3)}", inner)
        return inner
    return _EXPRESSION.sub(one, text)


def expand_matrix(job: Mapping[str, Any], text: str) -> list[str] | None:
    """`text` with each `${{ matrix.KEY }}` replaced by every value the matrix gives it, or None
    when one of them cannot be resolved."""
    text = dotted(text)
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
        expanded = dotted(expanded)  # a matrix value may itself index: ${{ vars['X'] }}
        if _MATRIX_REF.search(expanded):
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


def expression_values(expression: str) -> tuple[set[str], set[str]]:
    """The literal values a `${{ }}` expression can take, and the operands it can take a value
    from that are not literals. `c && 'a' || d && 'b' || 'e'` yields ({a, b, e}, set()); a value
    read from a context (`needs.x.outputs.y`) comes back in the second set, and the guard decides.
    `||` and `&&` split only outside quotes and parentheses, so `(a || b) && 'x' || 'y'` is {x, y}."""
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
        if quoted:
            values.add(quoted.group(1).replace("''", "'"))
        else:
            unresolved.add(term)
    return values, unresolved


Tracer = Callable[[str], "tuple[set[str], set[str]] | None"]


def _resolve(job: Mapping[str, Any], text: str, tracer: Tracer | None = None) -> tuple[set[str], set[str]]:
    """The literal values `text` (a value as written in the job) can take, literal indexes read in dot form,
    matrix cells expanded and an expression's literal branches read, and the parts nothing here resolves. A
    `tracer` (Workflows.tracer) resolves a branch that is a reusable workflow's `inputs.X` to its callers' values."""
    expanded = expand_matrix(job, text.strip())
    if expanded is None:
        return set(), {text.strip()}
    values: set[str] = set()
    unresolved: set[str] = set()
    for cell in expanded:
        expressions = _EXPRESSION.findall(cell)
        if not expressions:
            values.add(cell)
        elif len(expressions) == 1 and cell.startswith("${{") and cell.endswith("}}"):
            found, open_terms = expression_values(expressions[0])
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

    def input_values(self, workflow: str, name: str,
                     _seen: frozenset = frozenset()) -> tuple[set[str], set[str]]:
        """Every value `inputs.<name>` takes in `workflow`, and what nothing resolves (`inputs.<name>` itself when
        no workflow here calls it)."""
        key = (workflow, name.lower())
        callers = list(self.callers(workflow))
        if key in _seen or not callers:
            return set(), {f"inputs.{name}"}
        values: set[str] = set()
        unresolved: set[str] = set()
        for caller, _, job in callers:
            passed = next((v for k, v in (job.get("with") or {}).items() if str(k).lower() == name.lower()), None)
            if passed is None:
                default = self._declared_default(workflow, name)
                values.add("" if default is None else _scalar_text(default))
                continue
            found, open_terms = _resolve(job, _scalar_text(passed), self.tracer(caller, _seen | {key}))
            values |= found
            unresolved |= open_terms
        return values, unresolved

    def tracer(self, workflow: str, _seen: frozenset = frozenset()) -> Tracer:
        """The tracer for jobs of `workflow`: an `inputs.X` term is input_values(workflow, X); others are None."""
        def trace(term: str) -> tuple[set[str], set[str]] | None:
            match = _INPUT_TERM.fullmatch(term)  # terms come from dotted text: inputs['x'] is inputs.x here
            return self.input_values(workflow, match.group(1), _seen) if match else None
        return trace


def runs_on_items(job: Mapping[str, Any]) -> list[Any]:
    """The job's runs-on as the list of items it asks for, as written: a string is one item, a list its items, a
    `group`/`labels` mapping its labels then its group; [] when it has none. For a reader of the written text (an
    exact-match check, a pattern scan) that keeps lists as lists; a reader of labels reads runs_on_label_cells,
    runs_on_cells or runs_on_values, which expand the matrix."""
    raw = job.get("runs-on")
    if raw is None or raw == "":
        return []
    if isinstance(raw, Mapping):
        labels = raw.get("labels")
        return [*(labels if isinstance(labels, list) else [labels] if labels else []),
                *([raw["group"]] if raw.get("group") else [])]
    return raw if isinstance(raw, list) else [raw]


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
                whole = _WHOLE_INPUT.fullmatch(cell.strip())
                if whole is None:
                    traced.append(cell)
                    continue
                values, open_terms = workflows.input_values(workflow, whole.group(1))
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


def _tracer(workflow: str | None, workflows: Workflows | None) -> Tracer | None:
    return workflows.tracer(workflow) if workflows is not None and workflow is not None else None


def runs_on_values(job: Mapping[str, Any], workflow: str | None = None,
                   workflows: Workflows | None = None) -> tuple[set[str], set[str]]:
    """Every label a job's runs-on can resolve to (literal indexes read, matrix values expanded, literal branches
    of an expression read, and, given the job's `workflow` file name and every document as `workflows`, a reusable
    workflow's `inputs.X` traced to its callers' `with:` values at any depth), and every part it could not resolve
    (a context such as needs.x.outputs.y or vars.X, or a matrix value nothing gives). A guard counts a job with an
    unresolved part as unclassified, like environment_values. The single-host fallback test reads this."""
    values: set[str] = set()
    unresolved: set[str] = set()
    for item in runs_on_items(job):
        if not isinstance(item, str):
            unresolved.add(repr(item))
            continue
        found, open_terms = _resolve(job, item, _tracer(workflow, workflows))
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


def environment_values(job: Mapping[str, Any], workflow: str | None = None,
                       workflows: Workflows | None = None) -> tuple[set[str], set[str]]:
    """Every environment name a job's `environment:` can resolve to (matrix values expanded,
    literal branches of an expression read), casefolded because GitHub matches environment names
    without case (`Release` is `release`), and every part it could not resolve. A guard counts a
    job with an unresolved part as unclassified, never as outside the environment."""
    spec = environment_spec(job)
    env = spec.get("name") if spec is not None else None
    if env is None or env == "":
        return (set(), set()) if spec is None else (set(), {repr(spec)})
    if not isinstance(env, str):
        return set(), {repr(env)}
    values, unresolved = _resolve(job, env, _tracer(workflow, workflows))
    return {value.casefold() for value in values}, unresolved


def name_values(job: Mapping[str, Any], job_id: str, workflow: str | None = None,
                workflows: Workflows | None = None) -> tuple[set[str], set[str]]:
    """The check name a job reports: its `name:` (the job id when it has none) with matrix values
    expanded and literal expressions read (`${{ 'CLA policy guard' }}` is `CLA policy guard`), and
    every part nothing resolves. Check names keep their case. A guard that matches names counts a job
    with an unresolved part as a match (unclassified), never as a different check."""
    name = job.get("name", job_id)
    if not isinstance(name, str):
        return set(), {repr(name)}
    return _resolve(job, name, _tracer(workflow, workflows))


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
    `matrix_audit` names why that job's matrix is read elsewhere (UNRESOLVED_MATRICES)."""

    def __init__(self, job: Mapping[str, Any], job_id: str = "", workflow: str | None = None,
                 workflows: Workflows | None = None) -> None:
        self.job = job
        self.runs_on_cells = runs_on_cells(job, workflow, workflows)
        self.runs_on, self.runs_on_unresolved = runs_on_values(job, workflow, workflows)
        self.environments, self.environments_unresolved = environment_values(job, workflow, workflows)
        self.names, self.names_unresolved = name_values(job, job_id, workflow, workflows)
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
