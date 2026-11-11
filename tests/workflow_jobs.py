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
from collections.abc import Callable, Iterator, Mapping
from pathlib import Path
from typing import Any, NamedTuple

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
# `ctx['name']` / `ctx["name"]` with a literal name: the same reference as `ctx.name` (matrix, inputs, vars, secrets,
# env, needs and the outputs of either).
_LITERAL_INDEX = re.compile(r"\b([A-Za-z_][A-Za-z0-9_-]*)\s*\[\s*(?:'([A-Za-z_][A-Za-z0-9_-]*)'|\"([A-Za-z_][A-Za-z0-9_-]*)\")\s*\]")
_INPUT_TERM = re.compile(r"\s*inputs\s*\.\s*([A-Za-z_][A-Za-z0-9_-]*)\s*", re.IGNORECASE)
_WHOLE_INPUT = re.compile(r"\$\{\{\s*inputs\s*\.\s*([A-Za-z_][A-Za-z0-9_-]*)\s*\}\}", re.IGNORECASE)
# A repository variable read: `vars.NAME` (after dotted(), `vars['NAME']` too), and one whose name is not a literal,
# `vars[<expression>]` or the whole context (`toJSON(vars)`). Not `inputs.vars` or `x.vars`: a property of another.
_VAR_DOT = re.compile(r"(?<![\w.-])vars\s*\.\s*([A-Za-z_][A-Za-z0-9_]*)", re.IGNORECASE)
_VAR_OPEN = re.compile(r"(?<![\w.-])vars\s*(?=\[|\)|,)", re.IGNORECASE)
_INPUT_READ = re.compile(r"(?<![\w.-])inputs\s*\.\s*([A-Za-z_][A-Za-z0-9_-]*)", re.IGNORECASE)


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
    """A job's own mapping, as written, plus the workflow-level `env:` it inherits (`inherited_env`). GitHub hands a
    workflow's env to every job, so a secret there is in every job's reach: secret_names() and holds_secret() read
    it with the job's own env, steps and `with:`/`secrets:`. The mapping itself stays the job's own keys, so a guard
    that compares or prints a job sees what the file says. copy.deepcopy keeps the inherited env."""

    def __init__(self, job: Mapping[str, Any], inherited_env: Any = None) -> None:
        super().__init__(job)
        self.inherited_env = inherited_env or {}


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
        out["jobs"] = {name: Job(job, env) if isinstance(job, dict) else job for name, job in found.items()}
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
    # A document loaded elsewhere (or a job a fixture added) still inherits the workflow env's secrets. Only then
    # is a job re-wrapped, so a guard that edits a job it got back edits the document's own job otherwise.
    env = loaded.get("env") or {}
    if not secret_names(env):
        return found
    return {name: job if isinstance(job, Job) else Job(job, env) for name, job in found.items()}


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
    secret: `secrets: inherit`, `toJSON(secrets)` or an index that is not a literal. For a Job this is its
    effective set: the workflow env it inherits, then its own env, steps, `with:` and `secrets:`."""
    names: set[str] = set()
    if isinstance(value, Job) and value.inherited_env:
        names |= secret_names(value.inherited_env)
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


def _matrix(job: Mapping[str, Any]) -> Any:
    return (job.get("strategy") or {}).get("matrix") if isinstance(job.get("strategy"), Mapping) else None


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
    when the matrix is an expression or the key is nowhere in it (the value is unknown)."""
    cells = _matrix_cells(job, key)
    return None if cells is None else [value for _, value in cells]


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


def expand_matrix(job: Mapping[str, Any], text: str, reads: "VarReads | None" = None) -> list[str] | None:
    """`text` with each `${{ matrix.KEY }}` replaced by every value the matrix gives it, or None
    when one of them cannot be resolved. `reads` records the variables each value it takes reads."""
    text = dotted(text)
    whole = re.compile(r"\$\{\{\s*matrix\s*\.\s*([A-Za-z_][A-Za-z0-9_-]*)\s*\}\}", re.IGNORECASE)
    keys = list(dict.fromkeys(whole.findall(text)))
    if not keys:
        return None if _MATRIX_REF.search(text) else [text]
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


def variable_reads(text: str, whole: bool = False) -> list[str | None]:
    """Each repository variable `text` reads inside `${{ }}` (all of `text` when `whole`: an operand already taken
    out of one), upper-cased because GitHub matches variable names without case; None for a read whose name is
    not a literal (`vars[format(...)]`, `toJSON(vars)`), which no declaration can name."""
    found: list[str | None] = []
    for expression in [text] if whole else _EXPRESSION.findall(text):
        expression = dotted("${{" + expression + "}}")
        found += [name.upper() for name in _VAR_DOT.findall(expression)]
        found += [None] * len(_VAR_OPEN.findall(expression))
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
    """A trace the resolve step refused to finish: `inputs.<name>` of `workflow` loops back to itself (a default that
    names itself, two inputs whose defaults or callers name each other, a call cycle) or nests past
    MAX_TRACE_DEPTH. What it would read is unknown, so a guard treats it as a finding, never as "reads nothing"."""
    workflow: str
    name: str
    reason: str
    field: str


# How many reusable-workflow inputs one trace may pass through (callers' `with:` values and defaults alike).
MAX_TRACE_DEPTH = 32


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
    for path, text in _strings_at(_matrix(job), "strategy.matrix"):
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
    if tracer is not None:
        # Each input once per call: the reads pass below and the branches both trace it, and a trace that ran twice
        # per level grew as 2^depth along a chain of inputs.
        raw, done = tracer, {}

        def tracer(term: str) -> "tuple[set[str], set[str]] | None":
            match = _INPUT_TERM.fullmatch(term)
            key = match.group(1).lower() if match else term
            if key not in done:
                done[key] = raw(term)
            return done[key]
    expanded = expand_matrix(job, text, reads)
    if reads is not None:
        reads.note(path, text)
        if expanded is None:
            _note_unexpanded_matrix(job, reads)
        if tracer is not None:
            # An input read anywhere, a condition's included: its callers' values reach this field too.
            sources = expanded if expanded is not None else [text, *(s for _, s in _strings_at(_matrix(job), ""))]
            for name in dict.fromkeys(n.lower() for source in sources for e in _EXPRESSION.findall(source)
                                      for n in _INPUT_READ.findall(dotted("${{" + e + "}}"))):
                tracer(f"inputs.{name}")
    if expanded is None:
        return set(), {text}
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

    def input_values(self, workflow: str, name: str, _seen: frozenset = frozenset(),
                     reads: VarReads | None = None) -> tuple[set[str], set[str]]:
        """Every value `inputs.<name>` takes in `workflow`, and what nothing resolves (`inputs.<name>` itself when
        no workflow here calls it). `reads` records the variables each caller's value (or the declared default)
        reads, with the caller's file, job and `with.<name>` path.

        A caller that passes nothing gets the input's declared default, which is read in `workflow` itself: an
        `inputs.Y` in it is traced to this workflow's callers like any other (Codex on #40979: a default of
        `${{ inputs.fallback_runner }}` was scanned as text, so a caller's `fallback_runner: ${{ vars.X }}` was never
        read). A trace that comes back to an input it is already tracing, or passes MAX_TRACE_DEPTH inputs, stays
        unresolved and, with `reads`, is recorded as Unverifiable."""
        key = (workflow, name.lower())
        if key in _seen or len(_seen) >= MAX_TRACE_DEPTH:
            if reads is not None:
                reads.refuse(workflow, name, "a loop" if key in _seen else f"more than {MAX_TRACE_DEPTH} inputs")
            return set(), {f"inputs.{name}"}
        callers = list(self.callers(workflow))
        if not callers:
            return set(), {f"inputs.{name}"}
        values: set[str] = set()
        unresolved: set[str] = set()
        for caller, caller_job, job in callers:
            passed_key = next((k for k in (job.get("with") or {}) if str(k).lower() == name.lower()), None)
            if passed_key is None:
                default = self._declared_default(workflow, name)
                if not isinstance(default, str):
                    values.add("" if default is None else _scalar_text(default))
                    continue
                here = reads.at(workflow, "") if reads is not None else None
                found, open_terms = _resolve({}, default, self.tracer(workflow, _seen | {key}, here), here,
                                             f"on.workflow_call.inputs.{name}.default")
                values |= found
                unresolved |= open_terms
                continue
            passed = job["with"][passed_key]
            here = reads.at(caller, caller_job) if reads is not None else None
            found, open_terms = _resolve(job, _scalar_text(passed), self.tracer(caller, _seen | {key}, here),
                                         here, f"with.{passed_key}")
            values |= found
            unresolved |= open_terms
        return values, unresolved

    def tracer(self, workflow: str, _seen: frozenset = frozenset(), reads: VarReads | None = None) -> Tracer:
        """The tracer for jobs of `workflow`: an `inputs.X` term is input_values(workflow, X); others are None.
        With `reads`, it records the variables the callers' values read."""
        def trace(term: str) -> tuple[set[str], set[str]] | None:
            match = _INPUT_TERM.fullmatch(term)  # terms come from dotted text: inputs['x'] is inputs.x here
            return self.input_values(workflow, match.group(1), _seen, reads) if match else None
        return trace


def _runs_on_items(job: Mapping[str, Any]) -> list[Any]:
    return [item for _, item in _runs_on_paths(job)]


def runs_on_cells(job: Mapping[str, Any], workflow: str | None = None,
                  workflows: Workflows | None = None) -> list[str] | None:
    """The job's runs-on as each matrix cell would write it (`${{ matrix.runner }}` replaced by every value the
    matrix gives it; a list of labels joined by ", "), or None when a matrix value cannot be resolved (a
    fromJSON matrix, a key the matrix lacks): a guard counts such a job as unclassified, never as off its route.
    [] for a job with no runs-on (a reusable-workflow call)."""
    cells: list[list[str]] = []
    for item in _runs_on_items(job):
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
    return list(dict.fromkeys(", ".join(combination) for combination in itertools.product(*cells)))


def _tracer(workflow: str | None, workflows: Workflows | None, reads: VarReads | None = None) -> Tracer | None:
    return workflows.tracer(workflow, reads=reads) if workflows is not None and workflow is not None else None


def _runs_on_paths(job: Mapping[str, Any]) -> list[tuple[str, Any]]:
    """_runs_on_items with the key path of each."""
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


def environment_values(job: Mapping[str, Any], workflow: str | None = None, workflows: Workflows | None = None,
                       reads: VarReads | None = None) -> tuple[set[str], set[str]]:
    """Every environment name a job's `environment:` can resolve to (matrix values expanded,
    literal branches of an expression read), casefolded because GitHub matches environment names
    without case (`Release` is `release`), and every part it could not resolve. A guard counts a
    job with an unresolved part as unclassified, never as outside the environment."""
    env = job.get("environment")
    path = "environment"
    if isinstance(env, Mapping):
        env, path = env.get("name"), "environment.name"
    if env is None or env == "":
        return set(), set()
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


def effective_env(document: Mapping[str, Any], job: Mapping[str, Any],
                  step: Mapping[str, Any] | None = None) -> dict[str, Any]:
    """The env a step sees: the workflow's, then the job's, then the step's, the inner one winning a key, as
    GitHub merges them. Values stay as written; read a path value with repo_path."""
    env: dict[str, Any] = {}
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


class Resolved:
    """Every field a guard compares, read once and normalized: runs-on per matrix cell
    (runs_on_cells, runs_on_values), environment names casefolded (environment_values), the check
    name with literal expressions read (name_values), and the job's effective secrets (the workflow
    env it inherits, then its env, steps, `with:` and `secrets:`; secret_names). Each `*_unresolved`
    set, and `runs_on_cells is None`, is what nothing here could read: a guard fails closed on it.

    `vars_read` is every repository variable those fields consumed (VarRead: the variable, the file, job and key
    path it sits at, and the field), wherever it sat: the field as written, a matrix value it took (a matrix
    nothing could expand counts whole), a caller's `with:` value or an input's default at any call depth, inside a
    condition or a fromJSON, in dot or bracket form. A guard about the variables a field reads reads them here,
    never the field's text. `unverifiable` is every trace those fields refused to finish (Unverifiable: a loop or
    a nesting past MAX_TRACE_DEPTH); a guard counts each as a finding. Field `env` holds the variables the job's env layers read (the workflow's, then the
    job's): runs-on, environment and name cannot read the env context, so no other field consumes them."""

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
        self.secrets = secret_names(job)


def resolve(job: Mapping[str, Any], job_id: str = "", workflow: str | None = None,
            workflows: Workflows | None = None) -> Resolved:
    """The one resolve step (Resolved). A guard reads a job's runs-on, environment, name and secrets here, never
    the raw field. Given the job's workflow file name and every document (Workflows), a reusable workflow's
    inputs resolve through its callers."""
    return Resolved(job, job_id, workflow, workflows)
