#!/usr/bin/env python3
"""Every CI job that can start an acpmux daemon gives it a home of the job's own.

On a mini the runner user's ~/.acpmux is the host's own acpmux daemon, which
launchd keeps running. On 2026-10-26 the `cmux-next swift test` job on cmux12s
ran tests that resolve the app's acpmux from the process environment; with no
ACPMUX_HOME they resolved ~/.acpmux, handed the host daemon (pid 11252) off at
22:49:08Z, and cycled short-lived daemons there until the run ended.

A job that runs cmux NEXT's Swift tests (the only Swift package that starts
acpmux: AcpmuxEnvironment), acpmux's or cmux-tui's daemon tests, or the acpmux
CLI against a daemon must therefore, before its first such step, export
ACPMUX_HOME=$RUNNER_TEMP/acpmux-home and an empty ACPMUX_SOCKET (a socket wins
over the home, and empty counts as unset), and after its last one, in an
always() step, end that home's daemon and agents with `env -u ACPMUX_SOCKET
acpmux daemon shutdown --end-agents` and delete the home, so a failed or
cancelled job cleans up too.
In the tests themselves, AcpmuxEnvironment refuses the account's ~/.acpmux in
a test process (AcpmuxEnvironment+TestGuard.swift).

Jobs that launch a built cmux NEXT app (benches, the crash gate, media tours)
are not in this rule: the app is a tagged DEV build, whose acpmux home is its
own build home (~/.acpmux/builds/<key>, BuildIdentity), never ~/.acpmux, and a
tour runs a base and a head app side by side that one shared job home would
make hand each other's daemon off.
"""

from __future__ import annotations

import re
import sys
import unittest
from pathlib import Path

import yaml

from shell_invocations import lex, may_run, must_run

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"
CMUX_NEXT_PACKAGE = "Packages/macOS/CmuxNext"

# What in a step's `run:` starts or reaches an acpmux daemon on the runner.
LAUNCHES = (
    # cmux NEXT's Swift tests, and the scripts that run them.
    re.compile(r"swift-test-with-hang-sampler\.sh"),
    re.compile(r"fast-tier\.py\b[^\n]*--kind swift"),
    re.compile(r"(?:check-action-surfaces|check-settings-exports|regenerate-[a-z-]+-exports|base-autofix-[a-z-]+-exports)\.sh"),
    re.compile(r"car_guards\.py\b[^\n]*--where mac"),
    re.compile(r"package-test-lane\.sh run"),
    # acpmux's and cmux-tui's daemon tests (cmux-tui-artifacts.yml "cargo test cmux_next_").
    re.compile(r"cmux-next-daemon-test-packages\.sh"),
    # The acpmux CLI against a daemon.
    re.compile(r"\bacpmux(?:\.exe)?\"?\s+(?:daemon\s+(?:run|start|restart)|new|ls|send|status|wait|attach)\b"),
)
SWIFT_TEST = re.compile(r"\bswift test\b")
# The job's home, as a step writes it (quotes removed).
HOME = re.compile(r"^\$(?:RUNNER_TEMP|\{RUNNER_TEMP\})/acpmux-home$")
HOME_EXPORT = "ACPMUX_HOME"
# ACPMUX_SOCKET wins over the home (acpmux config::socket_path): an inherited one is another
# home's daemon. Empty counts as unset everywhere (Swift, Rust).
SOCKET_CLEAR = "ACPMUX_SOCKET="
SHUTDOWN = "daemon shutdown --end-agents"
# The step's commands are read by tests/shell_invocations.py, never matched as text: a comment, an echo, a string
# or a heredoc body that names the export, the shutdown or the delete does none of them. Credit (the export, the
# delete) reads must_run(): only a command bash surely runs when the step succeeds; a delete behind `&&`, in an if
# branch or after an `exit 0` guard may be skipped. The shutdown is best effort (no acpmux binary, no daemon), so it
# needs only to be a command the step may run (may_run()), not text.
GITHUB_ENV = {"$GITHUB_ENV", "${GITHUB_ENV}"}
VARIABLE = re.compile(r"^\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?$")


def launches(step: dict) -> bool:
    run = str(step.get("run") or "")
    if any(pattern.search(run) for pattern in LAUNCHES):
        return True
    in_package = str(step.get("working-directory") or "").rstrip("/") == CMUX_NEXT_PACKAGE or CMUX_NEXT_PACKAGE in run
    return in_package and bool(SWIFT_TEST.search(run))


def _commands_to_github_env(run: str) -> list[list[str]]:
    """The simple commands (words, quotes removed) whose output a `>` or `>>` sends to $GITHUB_ENV."""
    found: list[list[str]] = []
    words: list[str] = []
    to_env = False
    tokens = lex(run).tokens
    for index, token in enumerate(tokens):
        if token.kind == "word":
            words.append(token.text)
        elif token.kind == "op" and token.text in (">", ">>") and index + 1 < len(tokens):
            to_env = to_env or tokens[index + 1].text in GITHUB_ENV
            words.append(token.text)  # its target follows as a word; dropped below
        else:
            if to_env:
                found.append(words)
            words, to_env = [], False
    if to_env:
        found.append(words)
    return [[word for at, word in enumerate(command) if word not in (">", ">>")
             and not (at and command[at - 1] in (">", ">>"))] for command in found]


def _exports(run: str) -> set[str]:
    """The NAME=VALUE lines the step surely writes to $GITHUB_ENV: an echo or printf bash surely runs (must_run())
    whose output goes there."""
    sure = [words for words in must_run(run) if words and words[0] in ("echo", "printf")]
    lines = set()
    for words in _commands_to_github_env(run):
        if words in sure:
            lines.update(words[2:] if words[0] == "printf" else words[1:])
    return lines


def is_start(step: dict) -> bool:
    lines = _exports(str(step.get("run") or ""))
    return SOCKET_CLEAR in lines and any(
        line.startswith(f"{HOME_EXPORT}=") and HOME.match(line.split("=", 1)[1]) for line in lines)


def _home_words(run: str) -> set[str]:
    """How the step names the job home: its path, and each variable a NAME=VALUE word sets to it."""
    names = {token.text.split("=", 1)[0] for token in lex(run).tokens
             if token.kind == "word" and "=" in token.text and HOME.match(token.text.split("=", 1)[1])
             and re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", token.text.split("=", 1)[0])}
    return names


def _is_home(word: str, names: set[str]) -> bool:
    variable = VARIABLE.match(word)
    return bool(HOME.match(word) or (variable and variable.group(1) in names))


def _program(word: str) -> str:
    return word.rsplit("/", 1)[-1]


def _deletes_home(words: list[str], names: set[str]) -> bool:
    if not words or _program(words[0]) != "rm":
        return False
    options = "".join(word[1:] for word in words[1:] if word.startswith("-") and not word.startswith("--"))
    return ("r" in options.lower() and "f" in options and any(_is_home(word, names) for word in words[1:]))


def _shuts_down(words: list[str]) -> bool:
    """`env -u ACPMUX_SOCKET [NAME=VALUE ...] ACPMUX [...] daemon shutdown --end-agents`, the acpmux binary named
    by its path or a variable."""
    if not words or _program(words[0]) != "env":
        return False
    rest, unset = words[1:], False
    while rest and (rest[0].startswith("-") or "=" in rest[0]):
        if rest[0] in ("-u", "--unset") and len(rest) > 1:
            unset = unset or rest[1] == "ACPMUX_SOCKET"
            rest = rest[2:]
            continue
        unset = unset or rest[0] in ("-uACPMUX_SOCKET", "--unset=ACPMUX_SOCKET")
        rest = rest[1:]
    return (unset and bool(rest) and (_program(rest[0]) in ("acpmux", "acpmux.exe") or bool(VARIABLE.match(rest[0])))
            and " ".join(rest[1:]) == SHUTDOWN)


def is_stop(step: dict) -> bool:
    if "always()" not in str(step.get("if") or "").replace(" ", ""):
        return False
    run = str(step.get("run") or "")
    names = _home_words(run)
    return (any(_deletes_home(words, names) for words in must_run(run))
            and any(_shuts_down(invocation.words) for invocation in may_run(run)))


def condition(step: dict) -> str:
    return re.sub(r"\s+", "", str(step.get("if") or "")).removeprefix("${{").removesuffix("}}")


def runs_before_every_launch(start: dict, launching: list[dict]) -> bool:
    """An unconditional start, or one whose condition every launching step also requires (the
    daemon-test job's `steps.current.outputs.stale != 'true'`: a superseded run launches nothing)."""
    gate = condition(start)
    return not gate or all(gate in condition(step) for step in launching)


def job_failures(where: str, job: dict) -> list[str]:
    steps = [step for step in job.get("steps") or [] if isinstance(step, dict)]
    launching = [index for index, step in enumerate(steps) if launches(step)]
    if not launching:
        return []
    first, last = launching[0], launching[-1]
    named = steps[first].get("name") or f"step {first + 1}"
    failures = []
    starts = [index for index, step in enumerate(steps) if is_start(step)]
    if not any(index < first and runs_before_every_launch(steps[index], [steps[i] for i in launching])
               for index in starts):
        failures.append(f"{where}: '{named}' can start acpmux, but no step before it that runs whenever they do "
                        "exports ACPMUX_HOME=$RUNNER_TEMP/acpmux-home and an empty ACPMUX_SOCKET to $GITHUB_ENV")
    if not any(index > last and is_stop(step) for index, step in enumerate(steps)):
        failures.append(f"{where}: no always() step after its last acpmux step runs `env -u ACPMUX_SOCKET "
                        f"acpmux {SHUTDOWN}` for $RUNNER_TEMP/acpmux-home and deletes it")
    return failures


def workflow_jobs():
    for path in sorted(WORKFLOWS.glob("*.y*ml")):
        document = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
        for name, job in (document.get("jobs") or {}).items():
            if isinstance(job, dict):
                yield f"{path.name}:{name}", job


def failures() -> list[str]:
    found = []
    for where, job in workflow_jobs():
        found += job_failures(where, job)
    return found


START = {"name": "Give this job its own acpmux home",
         "run": 'home="$RUNNER_TEMP/acpmux-home"\nrm -rf "$home" && mkdir -m 700 "$home"\n'
                'echo "ACPMUX_HOME=$RUNNER_TEMP/acpmux-home" >> "$GITHUB_ENV"\necho "ACPMUX_SOCKET=" >> "$GITHUB_ENV"\n'}
STOP = {"name": "Stop this job's acpmux daemons and remove its home", "if": "${{ always() }}",
        "run": 'home="$RUNNER_TEMP/acpmux-home"\n'
               'env -u ACPMUX_SOCKET ACPMUX_HOME="$home" acpmux daemon shutdown --end-agents || true\nrm -rf "$home"\n'}
TEST = {"name": "Run package tests", "working-directory": CMUX_NEXT_PACKAGE,
        "run": "../../../scripts/cmux-next/swift-test-with-hang-sampler.sh --skip-build"}


class AcpmuxJobHomeTests(unittest.TestCase):
    def test_every_job_that_can_start_acpmux_has_its_own_home(self) -> None:
        self.assertEqual(failures(), [])

    def test_the_rule_reaches_the_swift_test_job(self) -> None:
        jobs = {where for where, job in workflow_jobs() if any(launches(step) for step in job.get("steps") or [])}
        for required in ("cmux-next.yml:swift-test", "cmux-next.yml:daemon-test",
                         "cmux-tui-artifacts.yml:cmux-next-daemon-tests"):
            self.assertIn(required, jobs)

    def test_a_job_without_its_own_home_fails(self) -> None:
        self.assertEqual(len(job_failures("w:j", {"steps": [TEST]})), 2)
        self.assertEqual(len(job_failures("w:j", {"steps": [TEST, STOP]})), 1)
        self.assertEqual(len(job_failures("w:j", {"steps": [START, TEST]})), 1)
        # Too late, or skipped by a condition.
        self.assertEqual(len(job_failures("w:j", {"steps": [TEST, START, STOP]})), 1)
        self.assertEqual(len(job_failures("w:j", {"steps": [dict(START, **{"if": "x"}), TEST, STOP]})), 1)
        gated = dict(TEST, **{"if": "steps.current.outputs.stale != 'true'"})
        self.assertEqual(len(job_failures("w:j", {"steps": [dict(START, **{"if": "x"}), gated, STOP]})), 1)
        # A stop that does not run after a failure or a cancel.
        self.assertEqual(len(job_failures("w:j", {"steps": [START, TEST, {**STOP, "if": "success()"}]})), 1)
        # An inherited ACPMUX_SOCKET left in place: the job's steps, or its shutdown, reach that daemon.
        keeps_socket = dict(START, run=START["run"].replace('echo "ACPMUX_SOCKET=" >> "$GITHUB_ENV"\n', ""))
        self.assertEqual(len(job_failures("w:j", {"steps": [keeps_socket, TEST, STOP]})), 1)
        stops_by_socket = dict(STOP, run=STOP["run"].replace("env -u ACPMUX_SOCKET ", ""))
        self.assertEqual(len(job_failures("w:j", {"steps": [START, TEST, stops_by_socket]})), 1)

    def test_a_job_with_its_own_home_passes(self) -> None:
        self.assertEqual(job_failures("w:j", {"steps": [START, TEST, STOP]}), [])
        swift_test = {"run": "swift test --package-path Packages/macOS/CmuxNext --filter X"}
        self.assertEqual(job_failures("w:j", {"steps": [START, swift_test, STOP]}), [])
        # A start gated like every launching step: a run that skips them needs no home.
        stale = "steps.current.outputs.stale != 'true'"
        self.assertEqual(job_failures("w:j", {"steps": [dict(START, **{"if": stale}), dict(TEST, **{"if": stale}),
                                                        dict(STOP, **{"if": f"${{{{ always() && {stale} }}}}"})]}), [])

    def test_text_that_only_names_the_export_shutdown_or_delete_is_not_credited(self) -> None:
        # Sweep of cmux#40784 F1: is_start and is_stop matched substrings, so a comment, an echo, a heredoc body or
        # a skipped command that named the export, the shutdown or the delete counted as one. Each form is named.
        home = 'home="$RUNNER_TEMP/acpmux-home"\n'
        shutdown = 'env -u ACPMUX_SOCKET ACPMUX_HOME="$home" acpmux daemon shutdown --end-agents || true\n'
        stops = {
            "shutdown in a comment": home + f"# {shutdown}" + 'rm -rf "$home"\n',
            "shutdown echoed": home + f"echo '{shutdown.strip()}'\n" + 'rm -rf "$home"\n',
            "shutdown in a heredoc body": home + f"cat <<'EOF' >/dev/null\n{shutdown}EOF\n" + 'rm -rf "$home"\n',
            "delete echoed": home + shutdown + 'echo rm -rf "$home"\n',
            "delete in a comment": home + shutdown + '# rm -rf "$home"\n',
            "delete right of &&": home + shutdown + 'false && rm -rf "$home"\n',
            "delete in an if branch": home + shutdown + 'if [[ -n "${KEEP:-}" ]]; then rm -rf "$home"; fi\n',
            "delete after an exit 0 guard": home + '[[ -d "$home" ]] || exit 0\n' + shutdown + 'rm -rf "$home"\n',
            "another directory deleted": home + shutdown + 'rm -rf "$RUNNER_TEMP/other"  # acpmux-home\n',
        }
        for form, run in stops.items():
            with self.subTest(form):
                self.assertEqual(len(job_failures("w:j", {"steps": [START, TEST, dict(STOP, run=run)]})), 1)
        export = 'echo "ACPMUX_HOME=$RUNNER_TEMP/acpmux-home" >> "$GITHUB_ENV"\n'
        clear = 'echo "ACPMUX_SOCKET=" >> "$GITHUB_ENV"\n'
        starts = {
            "export in a comment": f"# {export}" + clear,
            "export in a heredoc body": f"cat <<'EOF' >/dev/null\n{export}EOF\n" + clear,
            "export to stdout": 'echo "ACPMUX_HOME=$RUNNER_TEMP/acpmux-home"  # >> "$GITHUB_ENV"\n' + clear,
            "export right of &&": "false && " + export + clear,
            "socket clear in an if branch": export + f"if false; then {clear.strip()}; fi\n",
        }
        for form, run in starts.items():
            with self.subTest(form):
                self.assertEqual(len(job_failures("w:j", {"steps": [dict(START, run=run), TEST, STOP]})), 1)

    def test_the_workflows_stop_shape_is_credited(self) -> None:
        # The stop every workflow uses: the shutdown only where the home and an acpmux binary exist, the delete on
        # every path.
        run = ('home="$RUNNER_TEMP/acpmux-home"\nif [[ -d "$home" ]]; then\n'
               '  acpmux="$(command -v acpmux || true)"\n'
               '  [[ -z "$acpmux" ]] || env -u ACPMUX_SOCKET ACPMUX_HOME="$home" "$acpmux" daemon shutdown --end-agents'
               ' || true\nfi\nrm -rf "$home"\n')
        self.assertEqual(job_failures("w:j", {"steps": [START, TEST, dict(STOP, run=run)]}), [])
        self.assertTrue(is_stop(dict(STOP, run=run.replace('rm -rf "$home"', 'rm -rf "${RUNNER_TEMP}/acpmux-home"'))))
        self.assertTrue(is_start({"run": "printf '%s\\n' \"ACPMUX_HOME=$RUNNER_TEMP/acpmux-home\" >> \"$GITHUB_ENV\"\n"
                                         "echo ACPMUX_SOCKET= >>$GITHUB_ENV\n"}))

    def test_certainty_the_redirect_and_the_binding_belong_to_one_command(self) -> None:
        # dep-fleet-6 F1 (:109): the export matched by its words, so `false && echo .. >> $GITHUB_ENV` borrowed the
        # certainty of an identical echo to stdout. Certainty and the redirect are read off the same command.
        export = 'echo "ACPMUX_HOME=$RUNNER_TEMP/acpmux-home"'
        clear = 'echo "ACPMUX_SOCKET=" >> "$GITHUB_ENV"\n'
        self.assertFalse(is_start({"run": f'{export}\nfalse && {export} >> "$GITHUB_ENV"\n{clear}'}))
        self.assertFalse(is_start({"run": f'{export} 2>> "$GITHUB_ENV"\n{clear}'}))
        self.assertTrue(is_start({"run": f'{export} >> "$GITHUB_ENV"\n{clear}'}))
        # dep-fleet-6 F2 (:122): `echo "home=.."` read as a binding, so `rm -rf "$home"` counted while home pointed
        # elsewhere. Only a binding bash surely makes, and nothing else writes, names the home.
        shutdown = 'env -u ACPMUX_SOCKET ACPMUX_HOME="$home" acpmux daemon shutdown --end-agents || true\n'
        bound = 'home="$RUNNER_TEMP/acpmux-home"\n'
        for form, run in (
                ("an echo, not a binding", 'home=/tmp/elsewhere\necho "home=$RUNNER_TEMP/acpmux-home"\n'),
                ("an echo alone", 'echo "home=$RUNNER_TEMP/acpmux-home"\n'),
                ("bound, then rebound", bound + "home=/tmp/elsewhere\n"),
                ("bound right of &&", 'false && home="$RUNNER_TEMP/acpmux-home"\n'),
                ("bound in a subshell", '( home="$RUNNER_TEMP/acpmux-home" )\n'),
                ("bound, then read", bound + "read -r home < /dev/null\n"),
                ("bound for one command only", 'home="$RUNNER_TEMP/acpmux-home" true\n')):
            with self.subTest(form):
                self.assertFalse(is_stop(dict(STOP, run=run + shutdown + 'rm -rf "$home"\n')))
        self.assertTrue(is_stop(dict(STOP, run=bound + shutdown + 'rm -rf "$home"\n')))
        # dep-fleet-6 F3 (:147): reading through `env` dropped its -u, so a plain valid stop was refused.
        for shutdown in ("env -u ACPMUX_SOCKET acpmux daemon shutdown --end-agents\n",
                         "env --unset=ACPMUX_SOCKET /usr/local/bin/acpmux daemon shutdown --end-agents\n",
                         "timeout 30 env -u ACPMUX_SOCKET acpmux daemon shutdown --end-agents || true\n"):
            with self.subTest(shutdown):
                self.assertTrue(is_stop(dict(STOP, run=bound + shutdown + 'rm -rf "$home"\n')))
        self.assertFalse(is_stop(dict(STOP, run=bound + "env acpmux daemon shutdown --end-agents\n" + 'rm -rf "$home"\n')))

    def test_the_fleet_package_lane_gives_its_tests_a_home_of_their_own(self) -> None:
        # A fleet step (`cmux-ci run --script scripts/ci/package-test-lane.sh`) runs on a mini
        # outside this job, so the lane itself makes a home when it was given none.
        lane = (ROOT / "scripts" / "ci" / "package-test-lane.sh").read_text(encoding="utf-8")
        setup = lane[lane.index("end_own_acpmux_home() {"):lane.rindex('case "$phase" in')]
        self.assertIn("  suite|packages|run)\n    if [ -z \"${ACPMUX_HOME:-}\" ]; then", setup)
        self.assertIn('export ACPMUX_HOME="$own_acpmux_home" ACPMUX_SOCKET=', setup)
        self.assertIn("trap 'status=$?; end_own_acpmux_home; exit \"$status\"' EXIT", setup)
        self.assertIn(f'env -u ACPMUX_SOCKET ACPMUX_HOME="$own_acpmux_home" "$acpmux" {SHUTDOWN}', setup)
        self.assertIn('rm -rf "$own_acpmux_home"', setup)

    def test_other_swift_packages_are_not_acpmux(self) -> None:
        self.assertFalse(launches({"run": "swift test --package-path Packages/Shared/CmuxVNC"}))
        self.assertTrue(launches({"run": "swift test --skip-build", "working-directory": CMUX_NEXT_PACKAGE}))
        self.assertTrue(launches({"run": "acpmux daemon run --ready-fd 3"}))
        self.assertFalse(launches({"run": "acpmux --version"}))


if __name__ == "__main__":
    unittest.main(argv=sys.argv[:1] + sys.argv[1:], verbosity=2)
