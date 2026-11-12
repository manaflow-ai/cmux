#!/usr/bin/env python3
"""Every step of a release workflow that publishes, attests, uploads release assets or signs with a release secret
runs only on the release ref, and a manual dispatch cannot reach it.

The release workflows (coderouter-release.yml, app-ffi-release.yml) also run on `workflow_dispatch`, which anyone
with write access can start from any ref. Nothing there may publish unless the run is on the release ref: a tag
`coderouter-v*` pushed (not dispatched: a dispatch can be started on a tag ref too) for coderouter, the branch
`feat-cmux-next` for the app FFI (which a dispatch from that branch may publish by design). This is a static
detector, so the gate is proven without running a release.

What counts as publishing is read from the step, not its name:
- `uses:` a release action (attest-build-provenance, a PyPI publish action, a GitHub release action,
  upload-release-asset, create-release);
- a command it may run, direct or wrapped (tests/shell_invocations.may_run_nested: a substitution, eval, `bash -c`,
  xargs, sudo, env ... all count): `gh release create|upload|edit|delete`, a write through `gh api .../releases`
  (the method as gh reads it, tests/shell_invocations.gh_api_request: a field flag or --input is a POST),
  `npm|pnpm|yarn|bun|cargo publish`, `twine upload` (each subcommand read by position with its tool's option grammar,
  so an option's value such as `--dir upload` or `-p publish` is no subcommand), `codesign` (other than a verify or
  display), `productsign`, `xcrun notarytool`; and executable content it cannot read (a heredoc into a shell, eval of
  a variable, a sourced file), which may publish. Every one of these checks writes first: a write marker (codesign's
  --sign, -s or --remove-signature, gh api's write method or --input, a write subcommand in its position after any
  options, or an option before it this does not know) wins, and an exemption (a verify or display, a GET, a read
  subcommand) applies only when no write marker is present;
- a step that reads a secret other than GITHUB_TOKEN (a signing certificate, an App key, a registry token), or a job
  that reads one in its own env/with/secrets, or a workflow-level env that does (it reaches every job).
A call to a local reusable workflow counts as publishing at the call when anything it reaches publishes, followed
through nested local `uses: ./.github/workflows/...` calls at any depth (a cycle is read once): a step that
publishes, or a `${{ secrets.* }}` read (signing material) in the called workflow's env, a job's env, `with:` or
`secrets:` (what it passes to the next reusable workflow), or a step.

A gate counts only if it REQUIRES the release ref. The condition is split at top-level `||` (every alternative must
require it) and `&&` (one conjunct is enough), so `tag-gate || github.event_name == 'workflow_dispatch'` is no gate.
For a policy with an event list (app-ffi-release.yml: push and workflow_dispatch) the gate must also carry an event
term, and an event term naming any other event (workflow_run, repository_dispatch, schedule) is refused too.
A step is gated by its own `if`, its job's `if`, or a job it `needs` that is gated, unless the job's `if` holds
always(), failure() or cancelled() (then it runs even when the gated job was skipped).

Run: python3 tests/test_ci_release_publish_tag_gate.py (a second, no build).
"""
from __future__ import annotations

import re
import sys
import unittest
from pathlib import Path
from typing import Any, Callable, Mapping, NamedTuple

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tests"))
import workflow_jobs  # noqa: E402
from shell_invocations import Options, first_operand, gh_api_request, may_run_nested  # noqa: E402

WORKFLOWS = ROOT / ".github/workflows"


class Policy(NamedTuple):
    ref: re.Pattern  # an atom that requires the release ref
    push_only: bool  # the gate must also exclude a dispatch (a tag ref can be dispatched)
    events: frozenset = frozenset()  # if set, the gate must also carry an event term naming only these events


POLICIES = {
    "coderouter-release.yml": Policy(re.compile(
        r"startsWith\(\s*github\.ref\s*,\s*'refs/tags/coderouter-v[^']*'\s*\)"
        r"|github\.ref\s*==\s*'refs/tags/coderouter-v[^']*'"), push_only=True),
    "app-ffi-release.yml": Policy(re.compile(r"github\.ref\s*==\s*'refs/heads/feat-cmux-next'"), push_only=False,
                                  events=frozenset({"push", "workflow_dispatch"})),
}
PUSH_ONLY_ATOM = re.compile(r"github\.event_name\s*==\s*'push'|github\.event_name\s*!=\s*'workflow_dispatch'")
STATUS_FUNCTION = re.compile(r"\b(always|failure|cancelled|success)\s*\(", re.IGNORECASE)
RELEASE_ACTION = re.compile(
    r"attest|gh-action-pypi-publish|action-gh-release|release-action|upload-release-asset|create-release|"
    r"npm-publish|cargo-publish", re.IGNORECASE)
# codesign's options (`codesign --help`). Short ones that take a value: in a cluster, the letters after one are its
# value. Those a verify or display may carry are the only ones that are not a write marker.
CODESIGN_VALUES = frozenset("aDiIoPrRs")
CODESIGN_READ_SHORT = frozenset("vdfRrah")
CODESIGN_READ_LONG = frozenset({"--verify", "--display", "--verbose", "--strict", "--no-strict", "--deep", "--force",
                                "--entitlements", "--requirements", "--xml", "--der", "--check-notarization",
                                "--test-requirement", "--architecture", "--arch", "--file-list", "--all-architectures",
                                "--extract-certificates", "--detached"})
GH_RELEASE_WRITES = frozenset({"create", "upload", "edit", "delete", "delete-asset"})


def _strip(expression: Any) -> str:
    text = str(expression).strip()
    if text.startswith("${{") and text.endswith("}}"):
        text = text[3:-2].strip()
    return text


def requires(expression: Any, atom: Callable[[str], bool]) -> bool:
    """Whether every way the condition can be true needs `atom`: all alternatives of `||`, any conjunct of `&&`."""
    text = _strip(expression)
    while workflow_jobs._wrapped(text):
        text = text[1:-1].strip()
    alternatives = workflow_jobs._split_top(text, "||")
    if len(alternatives) > 1:
        return all(requires(part, atom) for part in alternatives)
    conjuncts = workflow_jobs._split_top(text, "&&")
    if len(conjuncts) > 1:
        return any(requires(part, atom) for part in conjuncts)
    return atom(text)


def event_term(atom: str, allowed: frozenset) -> bool:
    match = re.fullmatch(r"github\.event_name\s*==\s*'([A-Za-z_]+)'", atom)
    return bool(match) and match.group(1) in allowed


def gated(expression: Any, policy: Policy) -> bool:
    if expression is None or not str(expression).strip():
        return False
    ref = requires(expression, lambda atom: bool(policy.ref.fullmatch(atom)))
    if not ref:
        return False
    if policy.push_only and not requires(expression, lambda atom: bool(PUSH_ONLY_ATOM.fullmatch(atom))):
        return False
    # A ref alone would let a trigger added later (workflow_run, repository_dispatch, schedule on that branch)
    # publish unnoticed, so the gate names the events that may, and every alternative of it names only those.
    return not policy.events or requires(expression, lambda atom: event_term(atom, policy.events))


RELEASE_PATH = re.compile(r"releases|/git/(tags|refs)|(^|/)tags(/|$)")


def _options(values: str = "", flags: str = "") -> Options:
    return Options(frozenset(values.split()), frozenset(flags.split()))


# Each tool's options before its subcommand (its --help): those that take a value, then those that take none. The
# subcommand is the first operand after them, so an option's value (`--dir upload`, `-p publish`) is never read as
# one, and an option this does not know before it leaves the subcommand unknown, which counts as publishing.
GH_ROOT = _options(flags="-h --help --version")
GH_RELEASE = _options("-R --repo", "-h --help")
PACKAGE_MANAGERS = {
    "npm": _options("-w --workspace --registry --prefix -C --userconfig --loglevel --tag --access --otp --cache",
                    "-ws --workspaces -g --global -s --silent -q --quiet -d -dd --verbose --dry-run --provenance "
                    "--ignore-scripts --include-workspace-root -y --yes --no-audit --no-fund -h --help"),
    "pnpm": _options("-C --dir -F --filter --registry --tag --access --otp --reporter --loglevel "
                     "--workspace-concurrency",
                     "-r --recursive -w --workspace-root -s --silent --dry-run --no-git-checks --frozen-lockfile "
                     "--provenance -h --help"),
    "yarn": _options("--cwd", "-s --silent --verbose -h --help"),
    "bun": _options("--cwd -c --config", "--silent -h --help"),
    "cargo": _options("--color --config -Z -C --explain",
                      "-v -vv --verbose -q --quiet --locked --offline --frozen -h --help -V --version --list"),
}
# Scripts that run another subcommand by name: `npm run publish` runs the package's publish script.
RUNS_SCRIPT = frozenset({"run", "run-script"})
TWINE = _options(flags="--no-color -h --help --version")
PYTHON = _options("-W -X", "-b -bb -B -d -E -h -i -I -O -OO -P -q -R -s -S -u -v -V -x")
XCRUN = _options("--sdk --toolchain", "-v --verbose -l --log -n --no-cache -r --run -k --kill-cache")


def subcommand(args: list[str], options: Options) -> tuple[str | None, list[str]]:
    """The subcommand of ARGS read by position with OPTIONS, and the words after it. None when its position cannot
    be read or the word is not readable (a caller counts that as publishing); "" when there is none."""
    index = first_operand(args, options)
    if index is None:
        return None, []
    if index >= len(args):
        return "", []
    word = args[index]
    return (None if "$" in word or "\x00" in word or "`" in word else word), args[index + 1:]


def _package_publishes(program: str, args: list[str]) -> bool:
    if program == "cargo" and args[:1] and args[0].startswith("+"):
        args = args[1:]  # `cargo +stable publish`: a toolchain before the subcommand
    command, rest = subcommand(args, PACKAGE_MANAGERS[program])
    if command is None or command == "publish":
        return True
    if command in RUNS_SCRIPT and program != "cargo":
        script, _ = subcommand(rest, Options())
        return script is None or script == "publish"
    if program == "yarn" and command == "workspace":
        return _package_publishes(program, rest[1:])  # `yarn workspace NAME COMMAND`
    if program == "yarn" and command == "npm":
        script, _ = subcommand(rest, Options())
        return script is None or script == "publish"
    if program == "yarn" and command == "workspaces":
        return "publish" in rest  # `yarn workspaces foreach ... npm publish`: its own grammar; any publish counts
    return False


def _python_module(args: list[str]) -> tuple[str | None, list[str]]:
    """The module `python ARGS` runs with -m (`-m twine`, `-mtwine`, `-Im twine`), and its arguments; "" for none,
    None when an option before it is unknown."""
    index = 0
    while index < len(args):
        word = args[index]
        if word in ("-m",):
            return (args[index + 1], args[index + 2:]) if index + 1 < len(args) else ("", [])
        if not word.startswith("-") or word in ("-", "--") or word.startswith("-c"):
            return "", []
        if word in PYTHON.flags:
            index += 1
            continue
        if word in PYTHON.values:
            index += 2
            continue
        letters = word[1:]
        if "m" in letters and all("-" + letter in PYTHON.flags for letter in letters[:letters.index("m")]):
            module = letters[letters.index("m") + 1:]
            if module:
                return module, args[index + 1:]
            return (args[index + 1], args[index + 2:]) if index + 1 < len(args) else ("", [])
        return None, []
    return "", []


def publishing_command(words: list[str]) -> bool:
    if not words:
        return False
    program, rest = Path(words[0]).name, words[1:]
    if program == "gh":
        command, rest = subcommand(rest, GH_ROOT)
        if command is None:
            return True
        if command == "release":
            action, _ = subcommand(rest, GH_RELEASE)
            return action is None or action in GH_RELEASE_WRITES
        if command != "api":
            return False
        request = gh_api_request(rest)
        # No endpoint it can read (xargs feeds it, a variable holds it): it may be a release path.
        return request.writes and (request.endpoint is None or bool(RELEASE_PATH.search(request.endpoint)))
    if program in PACKAGE_MANAGERS:
        return _package_publishes(program, rest)
    if program.startswith("python"):
        module, rest = _python_module(rest)
        if module is None:
            return "twine" in rest or any("twine" in word for word in words[1:])
        if module != "twine":
            return False
        program = "twine"
    if program == "twine":
        command, _ = subcommand(rest, TWINE)
        return command is None or command == "upload"
    if program == "codesign":
        return codesign_signs_or_writes(rest)
    if program == "productsign":
        return True
    if program == "xcrun":
        if any(word in ("-f", "--find") for word in rest):
            return False  # `xcrun --find TOOL` prints a path and runs nothing
        command, _ = subcommand(rest, XCRUN)
        return command == "notarytool" or (command is None and "notarytool" in rest)
    return False


def codesign_signs_or_writes(args: list[str]) -> bool:
    """codesign, writes first. A write marker anywhere makes it a write, whatever else is present: --sign or -s
    (`-s ID`, `-fs ID`, `--sign=ID`), --remove-signature, or any option a verify or display does not take (-o,
    -i, --timestamp, an option this does not know). Only then may an exemption apply: read-only needs a read action,
    --verify, --display, -d in a short cluster (`-dv` displays), or -v standing alone (`-v`, `-vv`). In a cluster
    with anything else -v is verbosity, so `-fv` is no verify."""
    reads = False
    for word in args:
        if word == "--":
            break
        if word.startswith("--"):
            name = word.split("=", 1)[0]
            if name not in CODESIGN_READ_LONG:
                return True  # --sign, --remove-signature, a signing option or one this does not know
            reads = reads or name in ("--verify", "--display")
            continue
        if word.startswith("-") and len(word) > 1:
            letters = word[1:]
            for letter in letters:
                if letter not in CODESIGN_READ_SHORT:
                    return True  # -s, a signing option (-o, -i ...) or one this does not know
                if letter in CODESIGN_VALUES:
                    break  # the rest of the word is this option's value
            reads = reads or set(letters) == {"v"} or "d" in letters.split("R")[0].split("r")[0].split("a")[0]
    return not reads


def publishes(step: Mapping[str, Any]) -> list[str]:
    """Why a step counts as publishing, as short reasons (empty: it does not)."""
    why = []
    uses = str(step.get("uses", ""))
    if uses and RELEASE_ACTION.search(uses.split("@", 1)[0]):
        why.append(f"uses {uses.split('@', 1)[0]}")
    run = str(step.get("run", ""))
    if run:
        for words in may_run_nested(run):
            reason = ("may run content it cannot read (a heredoc into a shell, eval of a variable, a sourced file)"
                      if not words else "runs " + " ".join(words[:3]) if publishing_command(words) else None)
            if reason and reason not in why:
                why.append(reason)
    secrets = workflow_jobs.secret_names(step) - {"GITHUB_TOKEN"}
    if secrets:
        why.append("reads secret " + ", ".join(sorted(secrets)))
    return why


def callee_publishes(job: Mapping[str, Any], documents: Mapping[str, Mapping[str, Any]],
                     seen: frozenset = frozenset()) -> bool:
    """Whether a call to a local reusable workflow reaches anything that publishes, at any depth: a step that
    publishes, or a secret other than GITHUB_TOKEN read in the called workflow's env, a job's env, `with:`,
    `secrets:` or a step (workflow_jobs.secret_names of a called Job covers each). A workflow already on the call
    path is not read again, so a cycle ends."""
    callee = workflow_jobs._local_callee(job.get("uses"))
    document = documents.get(callee or "")
    if document is None or callee in seen:
        return False
    seen = seen | {callee}
    for called in workflow_jobs.jobs(document).values():
        if workflow_jobs.secret_names(called) - {"GITHUB_TOKEN"}:
            return True
        if callee_publishes(called, documents, seen):
            return True
        if any(publishes(step) for step in called.get("steps") or [] if isinstance(step, Mapping)):
            return True
    return False


def job_gates(jobs: Mapping[str, Mapping[str, Any]], policy: Policy) -> dict[str, bool]:
    """Which jobs only run on the release ref: their own `if`, or a gated job they need (and no status function)."""
    state = {name: gated(job.get("if"), policy) for name, job in jobs.items()}
    changed = True
    while changed:
        changed = False
        for name, job in jobs.items():
            if state[name]:
                continue
            needs = job.get("needs") or []
            needs = [needs] if isinstance(needs, str) else list(needs)
            condition = str(job.get("if", ""))
            # A status function in the job's `if` turns the implicit "every need succeeded" off: the job then runs
            # when the gated need was skipped. It stays covered only if the `if` itself requires that need's success.
            if any(state.get(need) and (not STATUS_FUNCTION.search(condition) or requires(
                    condition, lambda atom, need=need: bool(re.fullmatch(
                        rf"needs\.{re.escape(need)}\.result\s*==\s*'success'", atom)))) for need in needs):
                state[name], changed = True, True
    return state


def problems(name: str, document: Mapping[str, Any], policy: Policy,
             documents: Mapping[str, Mapping[str, Any]] | None = None) -> list[str]:
    documents = documents or {}
    found = []
    leaked = workflow_jobs.secret_names(document.get("env")) - {"GITHUB_TOKEN"}
    if leaked:
        found.append(f"{name}: workflow-level env reads {', '.join(sorted(leaked))}, which reaches every job")
    jobs = workflow_jobs.jobs(document)
    gates = job_gates(jobs, policy)
    for job_name, job in jobs.items():
        job_level = workflow_jobs.secret_names({key: job[key] for key in ("env", "with", "secrets") if key in job}) \
            - {"GITHUB_TOKEN"}
        if job_level and not gates[job_name]:
            found.append(f"{name} {job_name}: reads {', '.join(sorted(job_level))} in the job and has no release-ref gate")
        if workflow_jobs._local_callee(job.get("uses")) and callee_publishes(job, documents) and not gates[job_name]:
            found.append(f"{name} {job_name}: calls a reusable workflow that publishes and has no release-ref gate")
        for index, step in enumerate(job.get("steps") or []):
            if not isinstance(step, Mapping):
                continue
            why = publishes(step)
            if why and not gates[job_name] and not gated(step.get("if"), policy):
                label = step.get("name") or step.get("uses") or f"step {index}"
                found.append(f"{name} {job_name}: step {label!r} ({'; '.join(why)}) has no condition that requires "
                             "the release ref" + (" and the push event" if policy.push_only else "")
                             + (f" and an event term naming only {sorted(policy.events)}" if policy.events else ""))
    return found


def load_real() -> dict[str, dict]:
    return {path.name: workflow_jobs.document(path) for path in sorted(WORKFLOWS.glob("*.y*ml"))}


def check_real() -> list[str]:
    documents = load_real()
    return [why for name, policy in POLICIES.items() for why in problems(name, documents[name], policy, documents)]


POLICY = POLICIES["coderouter-release.yml"]
TAG = "startsWith(github.ref, 'refs/tags/coderouter-v')"
PUSH_TAG = f"github.event_name == 'push' && {TAG}"


def fixture(jobs: str, extra: str = "") -> dict:
    return workflow_jobs.document(f"on:\n  push:\n    tags: ['coderouter-v*']\n  workflow_dispatch:\n{extra}\njobs:\n{jobs}")


def job(name: str, steps: str, header: str = "") -> str:
    return f"  {name}:\n    runs-on: ubuntu-24.04\n{header}    steps:\n{steps}"


UPLOAD = "      - name: Upload\n{cond}        run: gh release upload \"$TAG\" dist/*\n"


def step(template: str, condition: str | None = None) -> str:
    return template.format(cond=f"        if: {condition}\n" if condition else "")


class TagGate(unittest.TestCase):
    def check(self, document: dict, documents: dict | None = None) -> list[str]:
        return problems("w.yml", document, POLICY, documents)

    def test_the_real_release_workflows_gate_every_publishing_step(self) -> None:
        found = check_real()
        self.assertEqual(found, [], "a release step can run off the release ref:\n  " + "\n  ".join(found))

    def test_a_publishing_step_with_no_gate_is_named(self) -> None:
        document = fixture(job("publish", step(UPLOAD)))
        self.assertEqual(len(self.check(document)), 1)

    def test_one_step_that_loses_its_gate_is_named(self) -> None:
        both = step(UPLOAD, PUSH_TAG) + step(UPLOAD.replace("Upload", "Upload two"))
        found = self.check(fixture(job("publish", both)))
        self.assertEqual(len(found), 1)
        self.assertIn("Upload two", found[0])
        self.assertEqual(self.check(fixture(job("publish", step(UPLOAD, PUSH_TAG) + step(UPLOAD, PUSH_TAG)))), [])

    def test_a_gate_that_a_dispatch_satisfies_is_no_gate(self) -> None:
        for condition in (f"{PUSH_TAG} || github.event_name == 'workflow_dispatch'",
                          f"({PUSH_TAG}) || github.event_name == 'workflow_dispatch'",
                          f"github.event_name == 'workflow_dispatch' || {PUSH_TAG}",
                          f"{TAG} || always()",
                          "github.event_name == 'push'"):
            with self.subTest(condition=condition):
                document = fixture(job("publish", step(UPLOAD, condition)))
                self.assertEqual(len(self.check(document)), 1)
                document = fixture(job("publish", step(UPLOAD), f"    if: {condition}\n"))
                self.assertEqual(len(self.check(document)), 1)

    def test_a_tag_ref_alone_is_not_enough_because_a_dispatch_can_run_on_a_tag(self) -> None:
        self.assertEqual(len(self.check(fixture(job("publish", step(UPLOAD, TAG))))), 1)
        self.assertEqual(self.check(fixture(job("publish", step(UPLOAD, f"github.event_name != 'workflow_dispatch' && {TAG}")))), [])

    def test_a_gate_that_really_requires_the_tag_passes(self) -> None:
        for condition in (PUSH_TAG, f"${{{{ {PUSH_TAG} }}}}", f"({PUSH_TAG}) && github.repository_owner == 'x'",
                          f"{TAG} && github.event_name == 'push' && runner.os == 'macOS'",
                          f"(github.event_name == 'push' && {TAG}) || (github.event_name == 'push' && {TAG})"):
            with self.subTest(condition=condition):
                self.assertEqual(self.check(fixture(job("publish", step(UPLOAD, condition)))), [])
                self.assertEqual(self.check(fixture(job("publish", step(UPLOAD), f"    if: {condition}\n"))), [])

    def test_a_gate_upstream_covers_a_job_that_needs_it_unless_a_status_function_runs_it_anyway(self) -> None:
        gate = job("gate", "      - run: echo ok\n", f"    if: {PUSH_TAG}\n")
        chained = fixture(gate + job("publish", step(UPLOAD), "    needs: gate\n"))
        self.assertEqual(self.check(chained), [])
        listed = fixture(gate + job("publish", step(UPLOAD), "    needs: [gate]\n"))
        self.assertEqual(self.check(listed), [])
        for status in ("always()", "${{ !cancelled() }}", "failure()"):
            with self.subTest(status=status):
                broken = fixture(gate + job("publish", step(UPLOAD), f"    needs: gate\n    if: {status}\n"))
                self.assertEqual(len(self.check(broken)), 1)
        ungated = fixture(job("gate", "      - run: echo ok\n") + job("publish", step(UPLOAD), "    needs: gate\n"))
        self.assertEqual(len(self.check(ungated)), 1)

    def test_what_publishes_is_read_from_the_step_not_its_name(self) -> None:
        cases = {
            "attest": "      - uses: actions/attest-build-provenance@v2\n        with:\n          subject-path: dist/x\n",
            "pypi action": "      - uses: pypa/gh-action-pypi-publish@release/v1\n",
            "release action": "      - uses: softprops/action-gh-release@v2\n",
            "cargo publish": "      - run: cargo publish --token x\n",
            "npm publish": "      - run: cd pkg && npm publish --provenance\n",
            "twine": "      - run: python3 -m twine upload dist/*\n",
            "gh release create": "      - run: gh release create v1 dist/*\n",
            "gh api write": "      - run: gh api -X POST repos/o/r/releases -f tag_name=v1\n",
            "codesign": "      - run: codesign --force --sign - dist/x\n",
            "notarytool": "      - run: xcrun notarytool submit x.zip\n",
            "secret": "      - run: ./sign.sh\n        env:\n          KEY: ${{ secrets.SIGNING_KEY }}\n",
            "secret by index": "      - run: ./sign.sh\n        env:\n          KEY: ${{ secrets['SIGNING_KEY'] }}\n",
            "inside a substitution": "      - run: url=$(gh release create v1 dist/*)\n",
            "behind eval": "      - run: eval \"gh release upload v1 dist/*\"\n",
            "behind bash -c": "      - run: bash -c 'gh release upload v1 dist/*'\n",
            "after an echo": "      - run: echo done; gh release upload v1 dist/*\n",
        }
        for label, steps in cases.items():
            with self.subTest(label):
                self.assertEqual(len(self.check(fixture(job("p", steps)))), 1, label)
                gated_job = fixture(job("p", steps, f"    if: {PUSH_TAG}\n"))
                self.assertEqual(self.check(gated_job), [], label)

    def test_text_that_only_names_a_publish_command_is_not_publishing(self) -> None:
        cases = ("      - run: echo gh release upload v1\n",
                 "      - run: |\n          # gh release upload v1 dist/*\n          true\n",
                 "      - run: |\n          cat <<'EOF'\n          gh release create v1\n          EOF\n",
                 "      - run: gh release view v1\n",
                 "      - run: gh api repos/o/r/releases/latest\n",
                 "      - run: codesign --verify --strict dist/x\n",
                 "      - run: codesign -dv dist/x\n",
                 "      - uses: actions/upload-artifact@v4\n        with:\n          path: dist\n",
                 "      - run: gh pr view\n        env:\n          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}\n")
        for steps in cases:
            with self.subTest(steps=steps):
                self.assertEqual(self.check(fixture(job("p", steps))), [], steps)

    def test_a_secret_in_a_job_or_the_workflow_env_needs_a_gate(self) -> None:
        in_job = fixture(job("p", "      - run: ./sign.sh\n", "    env:\n      KEY: ${{ secrets.SIGNING_KEY }}\n"))
        self.assertEqual(len(self.check(in_job)), 1)
        gated_job = fixture(job("p", "      - run: ./sign.sh\n", f"    if: {PUSH_TAG}\n    env:\n      KEY: ${{{{ secrets.SIGNING_KEY }}}}\n"))
        self.assertEqual(self.check(gated_job), [])
        workflow_env = fixture(job("p", "      - run: echo\n"), "env:\n  KEY: ${{ secrets.SIGNING_KEY }}")
        self.assertTrue(any("workflow-level env" in why for why in self.check(workflow_env)))

    def test_a_reusable_workflow_call_that_publishes_needs_a_gate(self) -> None:
        callee = workflow_jobs.document(
            "on: workflow_call\njobs:\n  p:\n    runs-on: ubuntu-24.04\n    steps:\n      - run: gh release upload v1 x\n")
        harmless = workflow_jobs.document(
            "on: workflow_call\njobs:\n  p:\n    runs-on: ubuntu-24.04\n    steps:\n      - run: echo hi\n")
        call = "  call:\n    uses: ./.github/workflows/callee.yml\n"
        self.assertEqual(len(self.check(fixture(call), {"callee.yml": callee})), 1)
        self.assertEqual(self.check(fixture(call + f"    if: {PUSH_TAG}\n"), {"callee.yml": callee}), [])
        self.assertEqual(self.check(fixture(call), {"callee.yml": harmless}), [])

    def test_the_branch_gated_workflow_allows_a_dispatch_from_its_branch_only(self) -> None:
        policy = POLICIES["app-ffi-release.yml"]
        branch = "github.ref == 'refs/heads/feat-cmux-next'"
        both = f"{branch} && (github.event_name == 'push' || github.event_name == 'workflow_dispatch')"
        self.assertEqual(problems("w.yml", fixture(job("p", step(UPLOAD), f"    if: {both}\n")), policy), [])
        self.assertEqual(len(problems("w.yml", fixture(job("p", step(UPLOAD), "    if: github.event_name == 'push'\n")), policy)), 1)
        self.assertEqual(len(problems("w.yml", fixture(job("p", step(UPLOAD), f"    if: {branch} || github.event_name == 'workflow_dispatch'\n")), policy)), 1)

    def test_the_branch_gated_workflow_needs_an_event_term_naming_only_push_and_dispatch(self) -> None:
        policy = POLICIES["app-ffi-release.yml"]
        branch = "github.ref == 'refs/heads/feat-cmux-next'"
        push, dispatch = "github.event_name == 'push'", "github.event_name == 'workflow_dispatch'"
        passes = (f"{branch} && ({push} || {dispatch})", f"{branch} && {push}", f"{branch} && {dispatch}",
                  f"${{{{ {branch} && ({push} || {dispatch}) }}}}", f"({push} || {dispatch}) && {branch}")
        refused = {
            "ref only": branch,
            "ref and an unrelated term": f"{branch} && github.repository_owner == 'manaflow-ai'",
            "workflow_run added": f"{branch} && ({push} || github.event_name == 'workflow_run')",
            "workflow_run alone": f"{branch} && github.event_name == 'workflow_run'",
            "repository_dispatch": f"{branch} && github.event_name == 'repository_dispatch'",
            "schedule": f"{branch} && github.event_name == 'schedule'",
            "an event alternative outside the branch": f"{branch} && {push} || {dispatch}",
            "negated event": f"{branch} && github.event_name != 'pull_request'",
        }
        for label, condition in [(c, c) for c in passes]:
            with self.subTest(passes=label):
                for header, text in ((f"    if: {condition}\n", ""), ("", condition)):
                    document = fixture(job("p", step(UPLOAD, text or None), header))
                    self.assertEqual(problems("w.yml", document, policy), [], condition)
        for label, condition in refused.items():
            with self.subTest(refused=label):
                self.assertEqual(len(problems("w.yml", fixture(job("p", step(UPLOAD), f"    if: {condition}\n")), policy)), 1)
                self.assertEqual(len(problems("w.yml", fixture(job("p", step(UPLOAD, condition))), policy)), 1)

    def test_every_gate_in_the_real_app_ffi_workflow_carries_an_event_term(self) -> None:
        document = load_real()["app-ffi-release.yml"]
        policy = POLICIES["app-ffi-release.yml"]
        for name, job in workflow_jobs.jobs(document).items():
            if job.get("if") and any(publishes(step) for step in job.get("steps") or []):
                with self.subTest(job=name):
                    self.assertTrue(gated(job["if"], policy), f"{name}: {job['if']}")
                    # Without its event term the same gate must be refused: it passes only through that term.
                    ref_only = re.sub(r"\s*&&\s*\([^()]*event_name[^()]*\)|\s*&&\s*github\.event_name\s*==\s*'\w+'", "",
                                      str(job["if"]))
                    self.assertFalse(gated(ref_only, policy), f"{name}: {ref_only}")

    def test_a_status_function_turns_the_needs_gate_off_unless_the_if_requires_that_need_succeeded(self) -> None:
        gate = job("gate", "      - run: echo ok\n", f"    if: {PUSH_TAG}\n")
        for condition in ("${{ !success() }}", "${{ failure() }}", "always()", "cancelled()",
                          "success() || always()", "needs.other.result == 'success' && always()",
                          "needs.gate.result == 'success' || always()"):
            with self.subTest(refused=condition):
                broken = fixture(gate + job("publish", step(UPLOAD), f"    needs: gate\n    if: {condition}\n"))
                self.assertEqual(len(self.check(broken)), 1)
        for condition in ("needs.gate.result == 'success'", "${{ always() && needs.gate.result == 'success' }}",
                          "${{ !cancelled() && needs.gate.result == 'success' }}"):
            with self.subTest(passes=condition):
                fine = fixture(gate + job("publish", step(UPLOAD), f"    needs: gate\n    if: {condition}\n"))
                self.assertEqual(self.check(fine), [])

    def test_gh_api_writes_to_release_paths_are_publishing_in_every_form_gh_reads(self) -> None:
        release = "repos/o/r/releases"
        writes = [
            f"gh api {release} -f tag_name=v1", f"gh api {release} -F draft=true", f"gh api {release} --field tag_name=v1",
            f"gh api {release} --raw-field tag_name=v1", f"gh api {release} --input body.json",
            f"gh api -f tag_name=v1 {release}", f"gh api {release} -ftag_name=v1", f"gh api {release} --field=tag_name=v1",
            f"gh api {release} --raw-field=tag_name=v1", f"gh api {release} --input=body.json",
            f"gh api {release} -X POST", f"gh api {release} -XPOST", f"gh api -X POST {release}",
            f"gh api {release} --method POST", f"gh api {release} --method=POST", f"gh api --method=post {release}",
            f"gh api {release}/1 -X PATCH", f"gh api {release}/1 -XPATCH", f"gh api {release}/1 --method=PATCH",
            f"gh api {release}/1 --method PUT", f"gh api {release}/1 -X DELETE", f"gh api {release}/1 --method=DELETE",
            "gh api repos/o/r/git/tags -f tag=v1", "gh api repos/o/r/git/refs -f ref=refs/tags/v1 -f sha=x",
            "gh api repos/o/r/releases/assets/9 -X DELETE", "gh api repos/o/r/releases/9/assets?name=a --input a.zip",
            f"gh api {release} -H 'Accept: x' -f tag_name=v1",
        ]
        reads = [f"gh api {release}", f"gh api {release}/latest", f"gh api {release} -X GET", f"gh api {release} --method=GET",
                 f"gh api {release} -XGET -f per_page=1", f"gh api {release} --method GET -F per_page=1",
                 f"gh api {release} -H 'Accept: x' -q .tag_name", "gh api repos/o/r/pulls -f title=x -X POST",
                 "gh api user -f x=1"]
        for command in writes:
            with self.subTest(write=command):
                steps = f"      - run: |\n          {command}\n"
                self.assertEqual(len(self.check(fixture(job("p", steps)))), 1, command)
                self.assertEqual(self.check(fixture(job("p", steps, f"    if: {PUSH_TAG}\n"))), [], command)
        for command in reads:
            with self.subTest(read=command):
                self.assertEqual(self.check(fixture(job("p", f"      - run: |\n          {command}\n"))), [], command)

    def test_a_wrapped_gh_api_release_write_is_classified_like_a_direct_one(self) -> None:
        write = "gh api repos/o/r/releases -X POST"
        field = "gh api repos/o/r/releases -f tag=v1"
        wrapped = [
            f'eval "{write}"', f"eval '{field}'", f"eval {write}", f"bash -c '{field}'", f'sh -c "{write}"',
            f"bash -lc '{write}'", f"echo repos/o/r/releases | xargs gh api -X POST", f"xargs -n1 {field}",
            f"echo x | xargs -I{{}} {field}", f"url=$({write})", f"url=`{field}`", f"echo $({field})",
            f"sudo {write}", f"env GH_TOKEN=x {field}", f"timeout 60 {write}", f"nice -n 5 {field}",
            f"sudo -E bash -c '{write}'", f"eval \"bash -c '{field}'\"", f"time {write}",
            "eval \"gh release upload v1 dist/x\"", "bash -c 'cargo publish'", "sh -c 'codesign --force -s - x'",
            "xargs codesign --force -s - < files", "bash -c 'unterminated",
        ]
        for command in wrapped:
            with self.subTest(command):
                steps = f"      - run: |\n          {command}\n"
                self.assertEqual(len(self.check(fixture(job("p", steps)))), 1, command)
                self.assertEqual(self.check(fixture(job("p", steps, f"    if: {PUSH_TAG}\n"))), [], command)
        harmless = ["eval \"echo hi\"", "bash -c 'echo gh api repos/o/r/releases -X POST'", "xargs rm -f < files",
                    "sudo apt-get install -y gh", "env FOO=1 true", "timeout 5 gh api repos/o/r/releases",
                    "bash -c 'gh api repos/o/r/releases -X GET'", "xargs -n1 echo"]
        for command in harmless:
            with self.subTest(harmless=command):
                self.assertEqual(self.check(fixture(job("p", f"      - run: |\n          {command}\n"))), [], command)

    def test_the_real_workflows_lose_a_gate_to_this_detector(self) -> None:
        # Mutate the real documents: remove the tag gate from one publishing job, then from one step.
        documents = load_real()
        document = documents["coderouter-release.yml"]
        names = ("prepare_release", "release")
        originals = {name: document["jobs"][name]["if"] for name in names}
        for name in names:
            self.addCleanup(document["jobs"][name].__setitem__, "if", originals[name])
        # `release` needs the gated `prepare_release`, so opening only `release` stays safe; opening both is not.
        loosen = lambda name: document["jobs"][name].__setitem__(
            "if", f"{originals[name]} || github.event_name == 'workflow_dispatch'")
        loosen("prepare_release")
        self.assertTrue(problems("coderouter-release.yml", document, POLICY, documents))
        loosen("release")
        self.assertTrue(problems("coderouter-release.yml", document, POLICY, documents))
        for name in names:
            document["jobs"][name]["if"] = originals[name]
        self.assertEqual(problems("coderouter-release.yml", document, POLICY, documents), [])
        build = document["jobs"]["build"]
        gated_steps = [item for item in build["steps"] if gated(item.get("if"), POLICY) and publishes(item)]
        self.assertTrue(gated_steps, "build has no gated publishing step to mutate")
        removed = gated_steps[0]["if"]
        self.addCleanup(gated_steps[0].__setitem__, "if", removed)
        del gated_steps[0]["if"]
        self.assertTrue(problems("coderouter-release.yml", document, POLICY, documents))


RELEASES = "repos/o/r/releases"
# cmux#41121 F1: every gh api write form gh reads, direct and wrapped. Implicit POST is any field flag or --input
# without an explicit GET.
GH_API_WRITE_ESCAPES = {
    "implicit POST -f": f"gh api {RELEASES} -f tag_name=v1",
    "implicit POST -F": f"gh api {RELEASES} -F draft=true",
    "implicit POST --field": f"gh api {RELEASES} --field tag_name=v1",
    "implicit POST --raw-field": f"gh api {RELEASES} --raw-field tag_name=v1",
    "implicit POST --input": f"gh api {RELEASES} --input body.json",
    "implicit POST -ftag_name=v1": f"gh api {RELEASES} -ftag_name=v1",
    "implicit POST --field=": f"gh api {RELEASES} --field=tag_name=v1",
    "implicit POST --input=": f"gh api {RELEASES} --input=body.json",
    "implicit POST, field first": f"gh api -f tag_name=v1 {RELEASES}",
    "implicit POST after -H": f"gh api {RELEASES} -H 'Accept: x' -f tag_name=v1",
    "-XPOST": f"gh api {RELEASES} -XPOST",
    "-X POST": f"gh api {RELEASES} -X POST",
    "--method POST": f"gh api {RELEASES} --method POST",
    "--method=POST": f"gh api {RELEASES} --method=POST",
    "--method=post": f"gh api --method=post {RELEASES}",
    "-iXPOST": f"gh api -iXPOST {RELEASES}",
    "-X $METHOD": f"gh api -X \"$METHOD\" {RELEASES}",
    "bash -c implicit POST": f"bash -c 'gh api {RELEASES} -f tag_name=v1'",
    "bash -c -XPOST": f"bash -c 'gh api {RELEASES} -XPOST'",
    "bash -lc --method=POST": f"bash -lc 'gh api {RELEASES} --method=POST'",
    "sh -c --method POST": f"sh -c \"gh api {RELEASES} --method POST\"",
    "eval implicit POST": f"eval \"gh api {RELEASES} --input body.json\"",
    "eval unquoted -X POST": f"eval gh api {RELEASES} -X POST",
    "eval of bash -c": f"eval \"bash -c 'gh api {RELEASES} -XPOST'\"",
    "xargs implicit POST": f"xargs -n1 gh api {RELEASES} -f tag_name=v1 < tags",
    "xargs -I --input": f"ls *.json | xargs -I{{}} gh api {RELEASES} --input {{}}",
    "xargs sh -c": f"xargs -I{{}} sh -c 'gh api {RELEASES} -XPOST' < tags",
    "sudo -XPOST": f"sudo gh api {RELEASES} -XPOST",
    "sudo -E bash -c": f"sudo -E bash -c 'gh api {RELEASES} -f tag_name=v1'",
    "env --method=POST": f"env GH_TOKEN=x gh api {RELEASES} --method=POST",
    "env -S text": f"env -S 'gh api {RELEASES} -f tag_name=v1'",
    "timeout implicit POST": f"timeout 60 gh api {RELEASES} -F draft=true",
    "nice -X POST": f"nice -n 5 gh api {RELEASES} -X POST",
    "nohup implicit POST": f"nohup gh api {RELEASES} -f tag_name=v1",
    "command --input": f"command gh api {RELEASES} --input body.json",
    "exec -XPOST": f"exec gh api {RELEASES} -XPOST",
    "time --method=POST": f"time gh api {RELEASES} --method=POST",
    "find -exec --input": f"find dist -name '*.json' -exec gh api {RELEASES} --input {{}} \\;",
    "flock implicit POST": f"flock /tmp/l gh api {RELEASES} -f tag_name=v1",
    "su -c -XPOST": f"su runner -c 'gh api {RELEASES} -XPOST'",
    "substitution implicit POST": f"id=$(gh api {RELEASES} -f tag_name=v1 --jq .id)",
}
# #41133 F2: executable content the detector cannot read may publish, so it needs the gate.
UNRESOLVED_ESCAPES = {
    "a heredoc into bash": "bash <<'EOF'\ngh release create v1 dist/x\nEOF",
    "a heredoc into sh -s": "sh -s <<EOF\ngh release create v1 dist/x\nEOF",
    "eval of a variable": "cmd=\"gh release create v1 dist/x\"\neval \"$cmd\"",
    "bash -c of a variable": "cmd=\"gh release create v1 dist/x\"\nbash -c \"$cmd\"",
    "source of a generated file": "printf 'gh release create v1 dist/x\\n' > publish.sh\nsource ./publish.sh",
    "dot of a generated file": "printf 'gh release create v1 dist/x\\n' > publish.sh\n. ./publish.sh",
}
STILL_READS = {
    "-X GET with a field": f"gh api {RELEASES} -X GET -f per_page=1",
    "--method=GET with a field": f"gh api {RELEASES} --method=GET -F per_page=1",
    "-XGET with a field": f"gh api {RELEASES} -XGET -f per_page=1",
    "bash -c read": f"bash -c 'gh api {RELEASES}/latest'",
    "sudo read": f"sudo gh api {RELEASES}",
    "xargs read": f"xargs -n1 gh api {RELEASES}/tags < tags",
    "a write elsewhere": "gh api repos/o/r/pulls -f title=x",
    "a function call": "f() { echo hi; }\nf",
    "a variable program": "\"$wheel_python\" -m wheel unpack \"$wheel\" --dest out",
    "xargs with a variable argument": "xargs rm -f \"$scratch\" < files",
}


# #41133 review F1 and F2: absolute shell and wrapper paths, an unknown absolute program given -c, and a substitution
# inside a parameter expansion.
SHELL_FORM_ESCAPES = {
    "/bin/bash -c": f"/bin/bash -c 'gh api {RELEASES} -f tag_name=v1'",
    "/usr/bin/env bash -c": f"/usr/bin/env bash -c 'gh api {RELEASES} -f tag_name=v1'",
    "/usr/bin/env /bin/sh -c": f"/usr/bin/env /bin/sh -c 'gh api {RELEASES} -XPOST'",
    "/usr/bin/sudo gh api": f"/usr/bin/sudo gh api {RELEASES} -XPOST",
    "/usr/bin/xargs gh release upload": "/usr/bin/xargs gh release upload v1 < files",
    "an unknown absolute program with -c": f"/opt/tools/bin/fish -c 'gh api {RELEASES} -f tag_name=v1'",
    "$( ) in ${x:-}": f'echo "${{x:-$(gh api {RELEASES} -f tag_name=v1)}}"',
    "backticks in ${x:+}": "echo ${x:+`gh release create v1 dist/x`}",
    "$( ) in a nested ${ }": f'echo "${{x:-${{y:-$(gh api {RELEASES} -XPOST)}}}}"',
    # #41398 review F1: a substitution inside arithmetic, inside a parameter expansion or an array subscript, runs.
    "$( ) in $(( )) in ${x:-}": 'echo "${x:-$(( $(gh release create v1 dist/x) + 1 ))}"',
    "$( ) in $(( ))": "echo $(( $(gh release create v1 dist/x) + 1 ))",
    "$( ) in an array subscript": 'echo "${arr[$(gh release create v1 dist/x)]}"',
    "$( ) in $(( )) in a heredoc body": "cat <<EOF\n$(( $(gh release create v1 dist/x) + 1 ))\nEOF",
    "an escaped $( ) in backticks": "echo `echo \\$(gh release create v1 dist/x)`",
}
# #41398 (folded in from the review of #41376, F1): the subcommand is read by position, with each tool's option
# grammar, never anywhere in the line: an option's value is no subcommand.
SUBCOMMAND_ESCAPES = {
    "gh release -R before upload": "gh release -R o/r upload v1 dist/x",
    "gh release --repo= before create": "gh release --repo=o/r create v1 dist/x",
    "gh release -Ro/r before delete": "gh release -Ro/r delete v1",
    "npm -w before publish": "npm -w pkg publish",
    "npm --workspace= before publish": "npm --workspace=pkg publish --provenance",
    "pnpm --filter before publish": "pnpm --filter pkg publish",
    "cargo --locked before publish": "cargo --locked publish",
    "cargo +toolchain before publish": "cargo +stable publish",
    "cargo -Z value before publish": "cargo -Z unstable-options publish",
    "yarn workspace NAME npm publish": "yarn workspace pkg npm publish",
    "python -I -m twine upload": "python3 -I -m twine upload dist/*",
    "twine --no-color upload": "twine --no-color upload dist/*",
    "xcrun --sdk before notarytool": "xcrun --sdk macosx notarytool submit x.zip",
}
SUBCOMMAND_READS = {
    "gh release download --dir upload": "gh release download v1 --dir upload",
    "gh release download -D upload": "gh release download v1 -D upload",
    "gh release view -R o/r create": "gh release view -R o/r create",
    "cargo test -p publish": "cargo test -p publish",
    "cargo build --package publish": "cargo build --package publish",
    "npm test publish": "npm test publish",
    "npm view pkg publish": "npm view pkg publish",
    "twine check upload/x.whl": "twine check upload/x.whl",
    "twine check upload": "twine check upload",
    "xcrun --find notarytool": "xcrun --find notarytool",
}


class RealStepMutation:
    """Strip the release gate from a real signing step of coderouter-release.yml and give it an escape form: the
    detector must name it, and the same step with its real gate restored must pass."""

    STEP = "Sign and verify macOS CodeRouter binary"

    def mutate(self, run: str, keep_gate: bool) -> list[str]:
        documents = load_real()
        document = documents["coderouter-release.yml"]
        steps = document["jobs"]["build"]["steps"]
        index = next(i for i, item in enumerate(steps) if isinstance(item, Mapping) and item.get("name") == self.STEP)
        real = steps[index]
        self.assertTrue(gated(real.get("if"), POLICY), "the real step lost its gate")
        mutant = {key: value for key, value in real.items() if key not in ("env", "run", "if")}
        mutant["if"] = real["if"] if keep_gate else "runner.os == 'macOS'"
        mutant["run"] = run + "\n"
        steps[index] = mutant
        return problems("coderouter-release.yml", document, POLICY, documents)

    def assert_escape_caught(self, cases: Mapping[str, str]) -> None:
        for label, run in cases.items():
            with self.subTest(label):
                found = self.mutate(run, keep_gate=False)
                self.assertEqual(len(found), 1, f"{label}: {run!r} escaped the detector: {found}")
                self.assertIn(self.STEP, found[0])
                self.assertEqual(self.mutate(run, keep_gate=True), [], label)



class RealGateMutations(RealStepMutation, unittest.TestCase):
    def test_absolute_paths_and_parameter_substitutions_without_the_real_gate_are_named(self) -> None:
        self.assert_escape_caught(SHELL_FORM_ESCAPES)

    def test_every_gh_api_write_form_without_the_real_gate_is_named(self) -> None:
        self.assert_escape_caught(GH_API_WRITE_ESCAPES)

    def test_a_subcommand_after_options_without_the_real_gate_is_named(self) -> None:
        self.assert_escape_caught(SUBCOMMAND_ESCAPES)

    def test_an_option_value_that_names_a_subcommand_stays_unnamed_without_the_gate(self) -> None:
        for label, run in SUBCOMMAND_READS.items():
            with self.subTest(label):
                self.assertEqual(self.mutate(run, keep_gate=False), [], f"{label}: {run!r}")

    def test_unresolved_executable_content_without_the_real_gate_is_named(self) -> None:
        self.assert_escape_caught(UNRESOLVED_ESCAPES)

    def test_reads_and_harmless_wrappers_stay_unnamed_without_the_gate(self) -> None:
        for label, run in STILL_READS.items():
            with self.subTest(label):
                self.assertEqual(self.mutate(run, keep_gate=False), [], f"{label}: {run!r}")

# cmux#41121 F2: with --sign or -s, codesign signs and -v only means verbose.
CODESIGN_SIGNING_ESCAPES = {
    "-v before --sign": "codesign -v --force --sign \"$IDENTITY\" bin",
    "--verify with --sign": "codesign --verify --sign - bin",
    "-s then -v": "codesign -s \"$IDENTITY\" -v bin",
    "-d with --sign=": "codesign -d --force --sign=\"$IDENTITY\" bin",
    "-dv with -s": "codesign -dv -s \"$IDENTITY\" bin",
    "--display with -fs": "codesign --display -fs \"$IDENTITY\" bin",
    "-vv with a keychain": "codesign -vv --keychain \"$KEYCHAIN\" --options runtime --sign \"$IDENTITY\" bin",
}
CODESIGN_READS = {
    "-v": "codesign -v bin", "--verify --strict --deep": "codesign --verify --strict --deep bin",
    "-dvvv": "codesign -dvvv bin", "-vvv --deep": "codesign -vvv --deep --strict bin",
    "-dv --verbose=4": "codesign -dv --verbose=4 bin", "-d --entitlements": "codesign -d --entitlements :- bin",
}


def workflow(jobs: str, env: str = "") -> dict:
    return workflow_jobs.document(f"on: workflow_call\n{env}jobs:\n{jobs}")


PUBLISH_JOB = "  p:\n    runs-on: ubuntu-24.04\n    steps:\n      - run: gh release upload v1 x\n"
HARMLESS_JOB = "  h:\n    runs-on: ubuntu-24.04\n    steps:\n      - run: echo hi\n"
SIGN_JOB = "  s:\n    runs-on: ubuntu-24.04\n    steps:\n      - run: ./sign.sh\n"


def call(callee: str, extra: str = "", name: str = "c") -> str:
    return f"  {name}:\n    uses: ./.github/workflows/{callee}\n{extra}"


SECRET = "${{ secrets.SIGNING_KEY }}"
# cmux#41121 F3: a reusable workflow call reaches signing material or a publish below its first level.
NESTED_CALL_ESCAPES = {
    "a publish two levels down": {"outer.yml": workflow(call("inner.yml")), "inner.yml": workflow(PUBLISH_JOB)},
    "a publish three levels down": {"outer.yml": workflow(call("middle.yml")), "middle.yml": workflow(call("inner.yml")),
                                    "inner.yml": workflow(PUBLISH_JOB)},
    "a callee job-level env secret": {"outer.yml": workflow(SIGN_JOB.replace("    steps:", f"    env:\n      KEY: {SECRET}\n    steps:"))},
    "a callee workflow-level env secret": {"outer.yml": workflow(SIGN_JOB, f"env:\n  KEY: {SECRET}\n")},
    "a nested callee job-level env secret": {
        "outer.yml": workflow(call("inner.yml")),
        "inner.yml": workflow(SIGN_JOB.replace("    steps:", f"    env:\n      KEY: {SECRET}\n    steps:"))},
    "a nested callee step-level env secret": {
        "outer.yml": workflow(call("inner.yml")),
        "inner.yml": workflow(SIGN_JOB + f"        env:\n          KEY: {SECRET}\n")},
    "a nested callee workflow-level env secret": {"outer.yml": workflow(call("inner.yml")),
                                                  "inner.yml": workflow(SIGN_JOB, f"env:\n  KEY: {SECRET}\n")},
    "a callee passing a secret in with:": {"outer.yml": workflow(call("inner.yml", f"    with:\n      key: {SECRET}\n")),
                                           "inner.yml": workflow(HARMLESS_JOB)},
    "a callee passing a secret in secrets:": {
        "outer.yml": workflow(call("inner.yml", f"    secrets:\n      KEY: {SECRET}\n")), "inner.yml": workflow(HARMLESS_JOB)},
    "a callee passing secrets: inherit": {"outer.yml": workflow(call("inner.yml", "    secrets: inherit\n")),
                                          "inner.yml": workflow(HARMLESS_JOB)},
    "a publish behind a call cycle": {"outer.yml": workflow(call("inner.yml")),
                                      "inner.yml": workflow(call("outer.yml") + PUBLISH_JOB)},
}
NESTED_CALL_HARMLESS = {
    "a harmless chain": {"outer.yml": workflow(call("inner.yml")), "inner.yml": workflow(call("leaf.yml")),
                         "leaf.yml": workflow(HARMLESS_JOB)},
    "a harmless cycle": {"outer.yml": workflow(call("inner.yml")), "inner.yml": workflow(call("outer.yml") + HARMLESS_JOB)},
    "a callee passing GITHUB_TOKEN": {
        "outer.yml": workflow(call("inner.yml", "    secrets:\n      token: ${{ secrets.GITHUB_TOKEN }}\n")),
        "inner.yml": workflow(HARMLESS_JOB)},
}


class CodesignAndNestedCallMutations(RealStepMutation, unittest.TestCase):
    def test_codesign_that_signs_is_named_whatever_verify_or_display_flag_it_also_has(self) -> None:
        self.assert_escape_caught(CODESIGN_SIGNING_ESCAPES)

    def test_codesign_that_only_verifies_or_displays_stays_unnamed(self) -> None:
        for label, run in CODESIGN_READS.items():
            with self.subTest(label):
                self.assertEqual(self.mutate(run, keep_gate=False), [], f"{label}: {run!r}")

    def call_mutation(self, callees: Mapping[str, dict], keep_gate: bool) -> list[str]:
        """Add a call to outer.yml to the real coderouter-release.yml, with the real `release` job's gate or without
        it."""
        documents = {**load_real(), **callees}
        document = documents["coderouter-release.yml"]
        gate = document["jobs"]["release"]["if"]
        self.assertTrue(gated(gate, POLICY), "the real release job lost its gate")
        caller = {"uses": "./.github/workflows/outer.yml", "if": gate if keep_gate else "github.repository_owner == 'manaflow-ai'"}
        document["jobs"]["escape"] = caller
        return problems("coderouter-release.yml", document, POLICY, documents)

    def test_a_reusable_workflow_call_is_followed_to_every_depth_and_reads_of_signing_material(self) -> None:
        for label, callees in NESTED_CALL_ESCAPES.items():
            with self.subTest(label):
                found = self.call_mutation(callees, keep_gate=False)
                self.assertEqual(len(found), 1, f"{label} escaped the detector: {found}")
                self.assertIn("escape", found[0])
                self.assertEqual(self.call_mutation(callees, keep_gate=True), [], label)

    def test_a_harmless_reusable_workflow_chain_or_cycle_needs_no_gate(self) -> None:
        for label, callees in NESTED_CALL_HARMLESS.items():
            with self.subTest(label):
                self.assertEqual(self.call_mutation(callees, keep_gate=False), [], label)


# Write first (cmux#41343 review F1): every classifier here looks for write markers first, and an exemption (a verify
# or display, a GET, a read subcommand) applies only when none is present.
WRITE_FIRST_ESCAPES = {
    "codesign --remove-signature -fv": "codesign --remove-signature -fv bin",
    "codesign -fv --remove-signature": "codesign -fv --remove-signature bin",
    "codesign --remove-signature --verify": "codesign --remove-signature --verify bin",
    "codesign -d with a signing option": "codesign -d -o runtime bin",
    "gh api -X POST then -X GET": f"gh api {RELEASES} -X POST -X GET",
    "gh api --method=DELETE then --method=GET": f"gh api {RELEASES}/1 --method=DELETE --method=GET",
    "gh api -XPATCH then -XGET": f"gh api -XPATCH {RELEASES}/1 -XGET",
    "gh api -X GET with --input": f"gh api {RELEASES} -X GET --input body.json",
    "gh release -R before upload": "gh release -R o/r upload v1 dist/x",
    "gh release --repo= before create": "gh release --repo=o/r create v1 dist/x",
    "npm -w before publish": "npm -w pkg publish",
    "python -I -m twine upload": "python3 -I -m twine upload dist/*",
}

CODESIGN_WRITES = [
    ["--sign", "ID", "bin"], ["-s", "ID", "bin"], ["-fs", "ID", "bin"], ["--sign=ID", "bin"],
    ["--force", "--options", "runtime", "--sign", "ID", "bin"], ["--remove-signature", "bin"],
    ["--remove-signature", "-f", "bin"],
]
CODESIGN_READ_MARKERS = [["-v"], ["-vv"], ["-d"], ["-dv"], ["-dvvv"], ["-fv"], ["--verify"], ["--display"],
                         ["--verbose=4"], ["--strict"], ["--deep"]]
GH_API_WRITES = [[RELEASES, "-X", "POST"], [RELEASES, "-XPOST"], [RELEASES + "/1", "--method=PATCH"],
                 [RELEASES + "/1", "--method", "DELETE"], [RELEASES, "--input", "b.json"], [RELEASES, "-f", "tag=v1", "-XPOST"]]
GH_API_READ_MARKERS = [["-X", "GET"], ["-XGET"], ["--method=GET"], ["--method", "GET"], ["-X", "HEAD"]]


def placements(write: list[str], marker: list[str]) -> list[list[str]]:
    """`marker` before every word of `write` and after the last, so an exemption meets each write marker on both
    sides."""
    return [write[:at] + marker + write[at:] for at in range(len(write) + 1)]


class WriteFirst(unittest.TestCase):
    def test_a_read_marker_added_anywhere_to_a_codesign_write_leaves_it_a_write(self) -> None:
        for write in CODESIGN_WRITES:
            for marker in CODESIGN_READ_MARKERS:
                for args in placements(write, marker):
                    with self.subTest(args=args):
                        self.assertTrue(publishing_command(["codesign", *args]), f"codesign {' '.join(args)} read as read-only")

    def test_a_read_method_added_anywhere_to_a_gh_api_release_write_leaves_it_a_write(self) -> None:
        for write in GH_API_WRITES:
            for marker in GH_API_READ_MARKERS:
                for args in placements(write, marker):
                    with self.subTest(args=args):
                        self.assertTrue(publishing_command(["gh", "api", *args]), f"gh api {' '.join(args)} read as a read")

    def test_reads_with_no_write_marker_stay_reads(self) -> None:
        for run in CODESIGN_READS.values():
            with self.subTest(run):
                self.assertFalse(publishing_command(run.split()), run)
        for marker in GH_API_READ_MARKERS:
            with self.subTest(marker=marker):
                self.assertFalse(publishing_command(["gh", "api", RELEASES, *marker, "-f", "per_page=1"]))
        for words in (["gh", "release", "view", "v1"], ["gh", "release", "-R", "o/r", "download", "v1"],
                      ["npm", "-w", "pkg", "run", "build"], ["python3", "-I", "-m", "twine", "check", "dist/x"]):
            with self.subTest(words=words):
                self.assertFalse(publishing_command(words), words)


class WriteFirstRealMutations(RealStepMutation, unittest.TestCase):
    def test_a_write_marker_wins_over_an_exemption_on_the_real_step_without_its_gate(self) -> None:
        self.assert_escape_caught(WRITE_FIRST_ESCAPES)


# #41398 review (reviewer's rows): the subcommand is the first operand after the tool's options, and -m counts only
# before python's script operand. Each read has a near-miss counterpart that does publish.
REVIEWER_SUBCOMMAND_ROWS = {
    "gh release view create": ("gh release view create", False),
    "gh release download upload": ("gh release download upload", False),
    "npm view publish": ("npm view publish", False),
    "python3 build.py -m twine upload": ("python3 build.py -m twine upload", False),
    "gh release create v1": ("gh release create v1", True),
    "npm publish": ("npm publish", True),
    "npm exec publish": ("npm exec -- npm publish", True),
    "python3 -m twine upload dist/*": ("python3 -m twine upload dist/*", True),
    "python3 -m unreadable upload": ('python3 -m "$MODULE" upload', True),
}


class ReviewerSubcommandRows(RealStepMutation, unittest.TestCase):
    def test_each_row_has_the_verdict_by_position(self) -> None:
        for label, (run, publishes_) in REVIEWER_SUBCOMMAND_ROWS.items():
            with self.subTest(label):
                self.assertEqual(publishing_command(run.split()), publishes_, run)
                self.assertEqual(len(self.mutate(run, keep_gate=False)), 1 if publishes_ else 0, run)

if __name__ == "__main__":
    unittest.main()
