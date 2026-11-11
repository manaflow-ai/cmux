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
- a command it may run (tests/shell_invocations.may_run, so a command in a substitution or behind eval counts):
  `gh release create|upload|edit|delete`, a write through `gh api .../releases`, `npm|pnpm|yarn|bun|cargo publish`,
  `twine upload`, `codesign` (other than verify and display), `productsign`, `xcrun notarytool`;
- a step that reads a secret other than GITHUB_TOKEN (a signing certificate, an App key, a registry token), or a job
  that reads one in its own env/with/secrets, or a workflow-level env that does (it reaches every job).
A call to a local reusable workflow whose steps publish counts as publishing at the call.

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
from shell_invocations import may_run  # noqa: E402

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
PUBLISH_TEXT = re.compile(
    r"\bgh\s+release\s+(create|upload|edit|delete)|\b(npm|pnpm|yarn|bun|cargo)\s+publish|\btwine\s+upload|"
    r"\bcodesign\b|\bproductsign\b|\bnotarytool\b")
CODESIGN_READ_ONLY = re.compile(r"-(v+|d+v*|dv+)|--verify|--display")


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
GH_API_VALUE_FLAGS = {"-X", "--method", "-f", "--raw-field", "-F", "--field", "-H", "--header", "--input", "-q",
                      "--jq", "-t", "--template", "--hostname", "--cache", "-p", "--preview"}
GH_API_FIELD_FLAGS = ("-f", "-F", "--field", "--raw-field", "--input")


def gh_api_writes_release(args: list[str]) -> bool:
    """`gh api` on a release, tag or asset path with a write method, read the way gh reads its flags: a field flag or
    --input makes it a POST unless -X/--method says otherwise; flags come spaced or attached (-XPOST, --method=POST)."""
    method, fields, paths, index = None, False, [], 0
    while index < len(args):
        word = args[index]
        index += 1
        name, attached = (word.split("=", 1) + [None])[:2] if word.startswith("--") else (word, None)
        if word.startswith("-X") and len(word) > 2:
            method = word[2:]
        elif name in ("-X", "--method"):
            method = attached if attached is not None else (args[index] if index < len(args) else "")
            index += 0 if attached is not None else 1
        elif name in GH_API_FIELD_FLAGS or (len(word) > 2 and word[:2] in ("-f", "-F") and not word.startswith("--")):
            fields = True
            index += 1 if (name in GH_API_VALUE_FLAGS and attached is None) else 0
        elif name in GH_API_VALUE_FLAGS:
            index += 1 if attached is None else 0
        elif not word.startswith("-"):
            paths.append(word)
    effective = (method or ("POST" if fields else "GET")).upper()
    return effective != "GET" and effective != "HEAD" and any(RELEASE_PATH.search(path) for path in paths)


def publishing_command(words: list[str]) -> bool:
    if not words:
        return False
    program, rest = Path(words[0]).name, words[1:]
    if program == "gh":
        if rest[:1] == ["release"] and rest[1:2] and rest[1] in {"create", "upload", "edit", "delete", "delete-asset"}:
            return True
        return rest[:1] == ["api"] and gh_api_writes_release(rest[1:])
    if program in {"npm", "pnpm", "yarn", "bun", "cargo"}:
        return "publish" in rest[:2]
    if program == "twine" or (program.startswith("python") and rest[:2] == ["-m", "twine"]):
        return "upload" in rest
    if program == "codesign":
        return not any(CODESIGN_READ_ONLY.fullmatch(word) for word in rest)
    if program == "productsign":
        return True
    return program == "xcrun" and "notarytool" in rest


def publishes(step: Mapping[str, Any]) -> list[str]:
    """Why a step counts as publishing, as short reasons (empty: it does not)."""
    why = []
    uses = str(step.get("uses", ""))
    if uses and RELEASE_ACTION.search(uses.split("@", 1)[0]):
        why.append(f"uses {uses.split('@', 1)[0]}")
    run = str(step.get("run", ""))
    if run:
        invocations = may_run(run)
        for invocation in invocations:
            if publishing_command(invocation.words):
                why.append("runs " + " ".join(invocation.words[:3]))
        if any(invocation.any_program for invocation in invocations) and PUBLISH_TEXT.search(run):
            why.append("may run a publish command through eval, bash -c or an unreadable construct")
    secrets = workflow_jobs.secret_names(step) - {"GITHUB_TOKEN"}
    if secrets:
        why.append("reads secret " + ", ".join(sorted(secrets)))
    return why


def callee_publishes(job: Mapping[str, Any], documents: Mapping[str, Mapping[str, Any]]) -> bool:
    callee = workflow_jobs._local_callee(job.get("uses"))
    document = documents.get(callee or "")
    if document is None:
        return False
    return any(publishes(step) for called in workflow_jobs.jobs(document).values()
               for step in called.get("steps") or [] if isinstance(step, Mapping))


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


if __name__ == "__main__":
    unittest.main()
