"""scripts/ci/cargo_test_verdict.py: a red pull request `cargo test` run passes only when each failing test is a
flake (it passed run again alone) or fails on the merge base too; a crash, a cut-short binary, a compile error or a
test the base passes is the change's own red."""
import importlib.util
import posixpath
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/cargo_test_verdict.py"
spec = importlib.util.spec_from_file_location("cargo_test_verdict", SCRIPT)
verdict = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verdict)

JOB = "acpmux tests"


def binary(*results, total=None):
    """One cargo test binary's output: `test NAME ... ok|FAILED` lines and its closing `test result:` line."""
    lines = [f"running {total if total is not None else len(results)} tests"]
    failed = [name for name, outcome in results if outcome == "FAILED"]
    lines += [f"test {name} ... {outcome}" for name, outcome in results]
    if failed:
        lines += ["", "failures:", ""] + [f"    {name}" for name in failed]
    state = "FAILED" if failed else "ok"
    lines.append(f"test result: {state}. {len(results) - len(failed)} passed; {len(failed)} failed; 0 ignored; "
                 "0 measured; 0 filtered out; finished in 1.00s")
    return "\n".join(lines)


def log(*binaries):
    return "\n\n".join(binaries) + "\n"


def starts_a_test(source):
    """Whether a plain `cargo test` starts a test of this Rust file: a `#[test]` or `#[tokio::test]` whose block of
    attributes holds no `#[ignore]`."""
    lines = [line.strip() for line in source.splitlines()]
    for n, line in enumerate(lines):
        if not re.match(r"#\[(?:tokio::)?test\b", line):
            continue
        first = last = n
        while first > 0 and lines[first - 1].startswith("#["):
            first -= 1
        while last + 1 < len(lines) and lines[last + 1].startswith("#["):
            last += 1
        if not any(attribute.startswith("#[ignore") for attribute in lines[first:last + 1]):
            return True
    return False


HEAD = log(
    binary(("hub::inbox_tests::keeps_order", "ok"), ("hub::turn_cap_tests::caps", "FAILED")),
    binary(("agent_inbox::delivers", "FAILED"), ("carried_turns::carries", "ok")),
)


class Judge(unittest.TestCase):
    def judge(self, head, retry=None, base=None):
        return verdict.judge(head, retry, base, JOB)

    def test_failed_names_cover_every_binary(self):
        self.assertEqual(verdict.failed_names(HEAD), ["agent_inbox::delivers", "hub::turn_cap_tests::caps"])

    def test_a_test_the_base_passes_is_the_changes_own(self):
        base = log(binary(("hub::turn_cap_tests::caps", "FAILED")), binary(("agent_inbox::delivers", "ok")))
        own, notes = self.judge(HEAD, base=base)
        self.assertTrue(own)
        self.assertTrue(any(n.startswith("::error") and "agent_inbox::delivers" in n for n in notes), notes)

    def test_a_test_missing_on_the_base_is_the_changes_own(self):
        base = log(binary(("hub::turn_cap_tests::caps", "FAILED")), binary(total=0))
        own, _ = self.judge(HEAD, base=base)
        self.assertTrue(own)

    def test_every_test_failing_on_the_base_too_warns(self):
        base = log(binary(("hub::turn_cap_tests::caps", "FAILED")), binary(("agent_inbox::delivers", "FAILED")))
        own, notes = self.judge(HEAD, base=base)
        self.assertFalse(own)
        self.assertEqual(sum(n.startswith("::warning") and "(base red)" in n for n in notes), 2, notes)

    def test_no_base_log_excuses_nothing(self):
        own, _ = self.judge(HEAD)
        self.assertTrue(own)

    def test_a_test_that_passes_alone_is_a_flake(self):
        retry = log(binary(("hub::turn_cap_tests::caps", "ok")), binary(("agent_inbox::delivers", "ok")))
        own, notes = self.judge(HEAD, retry=retry)
        self.assertFalse(own)
        self.assertEqual(sum("(flaky)" in n for n in notes), 2, notes)

    def test_a_flake_and_a_base_red_together_pass(self):
        retry = log(binary(("hub::turn_cap_tests::caps", "FAILED")), binary(("agent_inbox::delivers", "ok")))
        base = log(binary(("hub::turn_cap_tests::caps", "FAILED")), binary(total=0))
        own, notes = self.judge(HEAD, retry=retry, base=base)
        self.assertFalse(own, notes)

    def test_a_flake_does_not_hide_a_new_red(self):
        retry = log(binary(("hub::turn_cap_tests::caps", "FAILED")), binary(("agent_inbox::delivers", "ok")))
        base = log(binary(("hub::turn_cap_tests::caps", "ok")), binary(total=0))
        own, notes = self.judge(HEAD, retry=retry, base=base)
        self.assertTrue(own)
        self.assertTrue(any(n.startswith("::error") and "hub::turn_cap_tests::caps" in n for n in notes), notes)

    def test_a_crashed_binary_is_the_changes_own_even_when_the_base_crashes(self):
        crashed = log(
            binary(("hub::turn_cap_tests::caps", "ok")),
            "running 2 tests\ntest agent_inbox::delivers ... ok\n"
            "error: test failed, to rerun pass `--test hub_integration`\n\n"
            "Caused by:\n  process didn't exit successfully: `target/debug/deps/hub_integration-abc` "
            "(signal: 6, SIGABRT: process abort signal)",
        )
        own, notes = self.judge(crashed, retry=crashed, base=crashed)
        self.assertTrue(own)
        self.assertTrue(any("crashed" in n for n in notes), notes)

    def test_a_binary_that_never_finished_is_the_changes_own(self):
        cut = log(binary(("hub::turn_cap_tests::caps", "FAILED")), "running 3 tests\ntest agent_inbox::delivers ... ok")
        base = log(binary(("hub::turn_cap_tests::caps", "FAILED")))
        own, notes = self.judge(cut, base=base)
        self.assertTrue(own)
        self.assertTrue(any("not whole" in n for n in notes), notes)

    def test_a_compile_error_is_the_changes_own(self):
        own, notes = self.judge("error[E0425]: cannot find value `x` in this scope\nerror: could not compile `acpmux`\n")
        self.assertTrue(own)
        self.assertTrue(any("named no failing test" in n for n in notes), notes)

    def test_a_missing_head_log_is_the_changes_own(self):
        self.assertTrue(self.judge(None)[0])
        self.assertTrue(self.judge("")[0])

    def test_timestamps_and_colours_are_read(self):
        stamped = "\n".join(f"2026-10-31T01:02:03.4567890Z \x1b[0m{line}" for line in HEAD.splitlines())
        base = log(binary(("hub::turn_cap_tests::caps", "FAILED")), binary(("agent_inbox::delivers", "FAILED")))
        self.assertEqual(verdict.failed_names(stamped), ["agent_inbox::delivers", "hub::turn_cap_tests::caps"])
        self.assertFalse(self.judge(stamped, base=base)[0])
        retry = log(binary(("hub::turn_cap_tests::caps", "ok")), binary(("agent_inbox::delivers", "ok")))
        self.assertFalse(self.judge(stamped, retry=retry)[0])


def coloured(text):
    """TEXT as cargo prints it to a colour terminal: each outcome and the summary's state in its own colour codes,
    each line stamped as the job log serves it."""
    for word, code in (("FAILED", 31), ("ok", 32)):
        text = re.sub(rf"(\.\.\. |test result: ){word}\b",
                      lambda m, word=word, code=code: f"{m.group(1)}\x1b[{code}m{word}\x1b[0m", text)
    return "\n".join(f"2026-10-31T01:02:03.4567890Z {line}" for line in text.splitlines())


class NestedCargoSummary(unittest.TestCase):
    """#46751 job 137280817482: bwrap's captured child output closes before the parent binary."""

    def nested(self, parent_failed=2, child_failed=1):
        child = binary(("child", "FAILED")).replace("1 failed;", f"{child_failed} failed;")
        parent = binary(("outer", "FAILED"), ("flaky", "FAILED"))
        parent = parent.replace("2 failed;", f"{parent_failed} failed;")
        return parent.replace("\nfailures:\n", "\nfailures:\n\n---- outer stdout ----\n" + child + "\n", 1)

    def test_nested_summaries_keep_each_binarys_failures(self):
        head = self.nested()
        own, notes = verdict.judge(head, None, head, JOB)
        self.assertFalse(own, notes)

    def test_child_names_cannot_cover_an_unnamed_parent_failure(self):
        head = self.nested(parent_failed=3)
        self.assertTrue(verdict.judge(head, None, head, JOB)[0])

    def test_parent_names_cannot_cover_an_unnamed_child_failure(self):
        head = self.nested(child_failed=2)
        self.assertTrue(verdict.judge(head, None, head, JOB)[0])

    def test_parent_flakes_rewrite_only_the_parent_summary(self):
        head = self.nested()
        retry = binary(("flaky", "ok"))
        base = binary(("outer", "FAILED"), ("child", "FAILED"))
        own, notes = verdict.judge(head, retry, base, JOB)
        self.assertFalse(own, notes)
        rewritten = verdict.without_failures(head, {"flaky"})
        self.assertIn("test result: FAILED. 0 passed; 1 failed;", rewritten)
        self.assertIn("test result: FAILED. 1 passed; 1 failed;", rewritten)

    def test_child_summary_cannot_close_an_unfinished_parent(self):
        head = self.nested().rsplit("test result:", 1)[0]
        self.assertTrue(verdict.judge(head, None, self.nested(), JOB)[0])


class ColouredSummary(unittest.TestCase):
    """#41329's review F2: "scripts/ci/cargo_test_verdict.py:160: the summary rewrite searches the raw line, so ANSI
    codes around FAILED stop it matching. The flaky result drops out while its failure count stays, and judge() calls
    a passing retry an own red. Rewrite the normalized summary, and add a fixture with inline colour codes." And
    "strip ANSI once, at the log reader, so no parser sees raw colour"."""

    # One binary, a flake and a base red in it: taking the flake out leaves `1 failed`, its one named failure.
    HEAD = log(binary(("hub::turn_cap_tests::caps", "FAILED"), ("agent_inbox::delivers", "FAILED"),
                      ("carried_turns::carries", "ok")))
    RETRY = log(binary(("hub::turn_cap_tests::caps", "ok"), ("agent_inbox::delivers", "FAILED")))
    BASE = log(binary(("hub::turn_cap_tests::caps", "ok"), ("agent_inbox::delivers", "FAILED")))

    def test_a_flake_in_a_coloured_binary_leaves_its_count_matching_its_names(self):
        head = coloured(self.HEAD)
        self.assertIn("test result: \x1b[31mFAILED\x1b[0m. 1 passed; 2 failed;", head)
        out = verdict.without_failures(head, {"hub::turn_cap_tests::caps"})
        self.assertEqual([line for line in verdict.test_reds.lines_of(out) if line.startswith("test result: ")],
                         ["test result: FAILED. 2 passed; 1 failed; 0 ignored; 0 measured; 0 filtered out; "
                          "finished in 1.00s"])
        own, notes = verdict.judge(head, coloured(self.RETRY), coloured(self.BASE), JOB)
        self.assertFalse(own, notes)
        self.assertEqual(sum("(flaky)" in n for n in notes), 1, notes)
        self.assertEqual(sum("(base red)" in n for n in notes), 1, notes)

    def test_the_log_reader_strips_colour_once(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp, "head.log")
            path.write_text(coloured(self.HEAD) + "\n\x1b]8;;https://example.invalid\x07link\x1b]8;;\x07\n")
            text = verdict.read_text(path)
        self.assertNotIn("\x1b", text)
        self.assertIn("test result: FAILED. 1 passed; 2 failed;", text)


class TitleSequencesKeepTheLinesBetweenThem(unittest.TestCase):
    """#41382's review F1 (test_reds.py:64): "The OSC pattern is greedy and runs to the last ESC \\ in the log, so
    plain() deletes every line between two title sequences. Reproduced through cargo_test_verdict.read_text: a head
    with one new and one existing failure loses the new one, and judge() excuses it."""

    TITLE = "\x1b]0;cargo test\x1b\\"

    def test_a_new_failure_between_two_titles_is_the_changes_own(self):
        head = log(binary(("hub::turn_cap_tests::caps", "FAILED")),
                   self.TITLE + binary(("agent_inbox::delivers", "FAILED")), self.TITLE + "done")
        base = log(binary(("hub::turn_cap_tests::caps", "FAILED")), binary(("agent_inbox::delivers", "ok")))
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp, "head.log")
            path.write_text(head)
            text = verdict.read_text(path)
        self.assertEqual(verdict.failed_names(text), ["agent_inbox::delivers", "hub::turn_cap_tests::caps"])
        own, notes = verdict.judge(text, None, base, JOB)
        self.assertTrue(own, notes)
        self.assertTrue(any(n.startswith("::error") and "agent_inbox::delivers" in n for n in notes), notes)


def workflow_paths(workflow: str) -> dict[str, list[str]]:
    """Each trigger's `paths:` globs in WORKFLOW, read without a YAML parser."""
    found, event, inside = {}, None, False
    for line in workflow.splitlines():
        if match := re.match(r"^  (push|pull_request):", line):
            event, inside = match.group(1), False
        elif re.match(r"^\S", line):
            event = None
        elif event and re.match(r"^    paths:", line):
            inside = True
            found[event] = []
        elif inside and (match := re.match(r'^      - "([^"]+)"', line)):
            found[event].append(match.group(1))
        elif inside and not re.match(r"^\s*(#.*)?$", line):
            inside = False
    return found


def glob_matches(glob: str, path: str) -> bool:
    pattern = "".join(".*" if part == "**" else "[^/]*" if part == "*" else re.escape(part)
                      for part in re.split(r"(\*\*|\*)", glob))
    return re.fullmatch(pattern, path) is not None


class Scope(unittest.TestCase):
    CRATE = "cmux-tui/crates/acpmux"

    def test_the_crate_its_path_dependencies_and_their_includes_are_inputs(self):
        dirs, files = verdict.crate_inputs(ROOT, self.CRATE)
        self.assertIn(self.CRATE, dirs)
        self.assertIn("cmux-tui/crates/cmux-server", dirs)  # a direct path dependency
        self.assertIn("cmux-tui/crates/cmux-json", dirs)  # through `workspace = true`
        self.assertIn("skills/cmux-computer-use/SKILL.md", files)  # include_str! from outside the crates
        changed = ["cmux-tui/crates/cmux-json/src/lib.rs", "skills/cmux-computer-use/SKILL.md", "cmux-tui/Cargo.lock",
                   "README.md", "webviews/src/app.tsx", "cmux-tui/crates/ghostty-vt/src/lib.rs"]
        self.assertEqual(verdict.touches(ROOT, self.CRATE, changed), changed[:3])
        gates = ["scripts/cmux-next/run-v2-gates.sh", "scripts/cmux-next/tests/run-v2-gates.test.sh",
                 "scripts/cmux-next/v2-gates.d/pr03d.gates"]
        self.assertEqual(verdict.touches(ROOT, self.CRATE, gates), gates)  # read at test time
        self.assertEqual(verdict.touches(ROOT, "cmux-tui/crates/cmux-host", gates), [])

    def test_the_workflow_runs_for_every_included_file_outside_cmux_tui(self):
        _, files = verdict.crate_inputs(ROOT, self.CRATE)
        outside = [path for path in files if not path.startswith("cmux-tui/")]
        self.assertTrue(outside)
        paths = workflow_paths((ROOT / ".github/workflows/cmux-tui-spec.yml").read_text())
        # Pull requests carry no paths: feat-cmux-next requires the clippy job, so the workflow runs on every
        # one and its `changes` job routes them by these `push` paths (.github/scripts/cmux-tui-spec-changed.py).
        self.assertEqual(set(paths), {"push"})
        for event, globs in paths.items():
            for path in outside + [p.rstrip("/") + ("/x" if p.endswith("/") else "") for p in verdict.ALWAYS + verdict.READ_AT_TEST_TIME[self.CRATE]]:
                with self.subTest(event=event, path=path):
                    self.assertTrue(any(glob_matches(glob, path) for glob in globs),
                                    f"cmux-tui-spec.yml's {event} paths miss {path}, an input of acpmux's tests")

    def test_the_job_runs_the_tests_of_every_acpmux_crate_acpmux_is_built_from(self):
        # The job ran `-p acpmux` alone and no hosted job ran the other acpmux-* crates' tests: cmux#42834 changed
        # what acpmux-book answers and left acpmux-core's test of the old answer red on the base, and cmux#42906
        # left two more (repaired by cmux#42943). A new acpmux-* path dependency, direct or through another crate,
        # or a new tests/*.rs of one, joins the job's `suites`. acpmux's own tests/ are not asked for: most of them
        # run in other jobs.
        dirs, _ = verdict.crate_inputs(ROOT, self.CRATE)
        crates = [d for d in dirs if posixpath.basename(d).startswith("acpmux")]
        self.assertIn("cmux-tui/crates/acpmux-core", crates)
        workflow = (ROOT / ".github/workflows/cmux-tui-spec.yml").read_text()
        suites = re.search(r"^ +suites=\(([^)]*)\)$", workflow, re.M).group(1).split()
        named = {flag: {suites[n + 1] for n, word in enumerate(suites[:-1]) if word == flag}
                 for flag in ("-p", "--test")}
        self.assertIn("--lib", suites)
        with verdict.git_tree.GitTree(ROOT) as tree:
            for crate in crates:
                name = posixpath.basename(crate)
                with self.subTest(crate=name):
                    self.assertIn(name, named["-p"], f"cmux-tui-spec.yml's acpmux tests job runs no test of {name}: "
                                                     f"add `-p {name}` to its suites")
                    if crate == self.CRATE:
                        continue
                    targets = {posixpath.basename(path)[:-3] for path in tree.files(f"{crate}/tests", ".rs")
                               if posixpath.dirname(path) == f"{crate}/tests"}
                    self.assertEqual(targets - named["--test"], set(),
                                     f"cmux-tui-spec.yml's acpmux tests job misses {name}'s tests/ files: add "
                                     "`--test NAME` to its suites for each")
            # acpmux's own tests/v2_*.rs. tests/v2_gate_home.rs is the only test build of the v2 gate registry
            # (benches/v2/mod.rs) and no hosted job ran it: cmux#42725 made the report refuse a run that leaves a
            # measured row out, and two of the file's tests stayed red on the base. A v2_* file joins `suites`
            # unless every test in it is #[ignore]d (a release gate cmux-ci runs by name).
            found = []
            for path in tree.files(f"{self.CRATE}/tests", ".rs"):
                name = posixpath.basename(path)[:-3]
                if posixpath.dirname(path) != f"{self.CRATE}/tests" or not name.startswith("v2_"):
                    continue
                found.append(name)
                with self.subTest(target=name):
                    self.assertTrue(name in named["--test"] or not starts_a_test(tree.text(path)),
                                    f"cmux-tui-spec.yml's acpmux tests job misses acpmux's tests/{name}.rs, which "
                                    f"holds a test a plain run starts: add `--test {name}` to its suites")
            self.assertIn("v2_gate_home", found)

    def test_a_file_of_ignored_gates_starts_no_test(self):
        gate = '#[test]\n#[ignore = "release gate"]\nfn a() {}\n'
        self.assertFalse(starts_a_test(gate))
        self.assertFalse(starts_a_test('#[ignore]\n#[tokio::test(flavor = "multi_thread")]\nasync fn a() {}\n'))
        self.assertFalse(starts_a_test("fn helper() {}\n"))
        self.assertTrue(starts_a_test(gate + "\n#[test]\nfn b() {}\n"))
        self.assertTrue(starts_a_test("    #[tokio::test]\n    async fn c() {}\n"))

    def test_stop_budget_tests_run_once_alone_and_count_toward_the_verdict(self):
        stop = (ROOT / self.CRATE / "tests/hub_integration/stop.rs").read_text()
        budget = ["stop::" + name for name, body in
                  re.findall(r"#\[tokio::test\]\s+async fn (\w+)\(\) \{(.*?)\n\}", stop, re.S)
                  if "STOP_BUDGET" in body]
        self.assertEqual(len(budget), 2)
        workflow = (ROOT / ".github/workflows/cmux-tui-spec.yml").read_text()
        run_all = re.search(r"^          run_all\(\) \{.*?^          \}", workflow, re.M | re.S).group()
        # Record each real phase's arguments. A red in the isolated phase must still collect the
        # rest of the integration and library results before the verdict judge reads the head log.
        driver = '''
            RUNNER_TEMP=$1
            timing_status=$2
            shift 2
            skip=("$@")
            suites=(--lib --test hub_integration)
            pkgs=(-p acpmux)
            targets=(--test hub_integration)
            bounded() { echo "$*"; [[ " $* " != *" --test-threads=1 "* ]] || return "$timing_status"; }
        '''
        with tempfile.TemporaryDirectory() as temp:
            for skip in ([], ["--exact", "--skip", "a_deferred_test"]):
                for status in (0, 1):
                    with self.subTest(skip=skip, status=status):
                        result = subprocess.run(["bash", "-c", driver + run_all + "\nrun_all",
                                                 "bash", temp, str(status), *skip], capture_output=True, text=True)
                        self.assertEqual(result.returncode, status, result.stderr)
                        build, timing, integration, libraries = result.stdout.splitlines()
                        self.assertIn("--no-run", build)
                        self.assertCountEqual(timing.split(" -- ")[1].split(), ["--exact", "--test-threads=1", *budget])
                        self.assertIn("--test hub_integration --", timing)
                        omitted = integration.split(" -- ")[1].split()
                        self.assertEqual(omitted[0], "--exact")
                        self.assertEqual(omitted[1::2], ["--skip"] * len(omitted[2::2]))
                        self.assertCountEqual(omitted[2::2], skip[2:] + budget)
                        self.assertEqual(libraries.split(" --", 1)[1].split(), skip)


class BaseLogSave(unittest.TestCase):
    """The base's own test log, which every red pull request run reads first (a test red there is the base's), is
    saved by whichever event runs the job on feat-cmux-next. After #52321 that is only the post-merge batch (a
    workflow_call from a workflow_dispatch, `inputs.sha` the tested tip); the save steps still asked for `push`, so
    no log was saved, every red pull request retried and replayed the base's reds on a rebuilt merge parent (about
    15 of a red run's 33 min), and a base test flaky there read as the change's own red."""

    WORKFLOW = ROOT / ".github/workflows/cmux-tui-spec.yml"
    BATCH = ROOT / ".github/workflows/cmux-next-post-merge.yml"

    def steps(self, text, *names):
        found = {}
        for name in names:
            match = re.search(rf"^      - name: {re.escape(name)}\n((?:        .*\n|\s*\n)+)", text, re.M)
            self.assertIsNotNone(match, f"cmux-tui-spec.yml has no step {name!r}")
            found[name] = match.group(1)
        return found

    def test_the_batch_that_tests_feat_cmux_next_saves_the_base_log(self):
        text = self.WORKFLOW.read_text()
        push_branches = re.search(r"^  push:\n    branches:\n((?:      .*\n)+?)    paths:", text, re.M).group(1)
        batch = self.BATCH.read_text()
        batch_calls_with_sha = re.search(r"uses: \./\.github/workflows/cmux-tui-spec\.yml\n    with:\n      sha: ", batch)
        steps = self.steps(text, "Save this push's test log for pull requests", "Save the base's last test log")
        for name, body in steps.items():
            condition = re.search(r"^        if: \$\{\{(.*)\}\}$", body, re.M).group(1)
            with self.subTest(step=name):
                if "- feat-cmux-next" not in push_branches:
                    self.assertTrue(batch_calls_with_sha, "the post-merge batch no longer calls cmux-tui-spec.yml with "
                                                          "a sha: say which event tests feat-cmux-next, and save there")
                    self.assertIn("github.event_name == 'workflow_dispatch' && inputs.sha != ''", condition,
                                  f"{name!r} never runs on the post-merge batch, the only run of the job on "
                                  "feat-cmux-next: pull requests find no base log")
                # A bisect probe tests an old commit: its log, saved now, would read as the base's newest.
                self.assertIn("inputs.only == ''", condition)
                self.assertIn("github.ref == 'refs/heads/feat-cmux-next'", condition)
        # The tested commit names the log, so a pull request's exact merge-parent key finds the batch's run.
        self.assertIn("key: acpmux-tests-base-log-${{ inputs.sha || github.sha }}",
                      steps["Save the base's last test log"])
        self.assertIn('"${TESTED_SHA:-$GITHUB_SHA}" > "$dir/sha"', steps["Save this push's test log for pull requests"])
        self.assertIn("TESTED_SHA: ${{ inputs.sha }}", steps["Save this push's test log for pull requests"])


class Cli(unittest.TestCase):
    def run_cli(self, *args):
        return subprocess.run([sys.executable, str(SCRIPT), *args], capture_output=True, text=True, check=False,
                              stdin=subprocess.DEVNULL)

    def test_failed_and_judge(self):
        with tempfile.TemporaryDirectory() as tmp:
            head, base = Path(tmp, "head.log"), Path(tmp, "base.log")
            head.write_text(HEAD)
            base.write_text(log(binary(("hub::turn_cap_tests::caps", "FAILED")), binary(("agent_inbox::delivers", "ok"))))
            out = self.run_cli("failed", str(head))
            self.assertEqual(out.stdout.split(), ["agent_inbox::delivers", "hub::turn_cap_tests::caps"])
            out = self.run_cli("judge", "--head", str(head), "--base", str(base), "--retry", str(Path(tmp, "none")),
                               "--job", JOB)
            self.assertEqual(out.returncode, 1, out.stdout + out.stderr)
            self.assertIn("::error title=acpmux tests::", out.stdout)
            base.write_text(log(binary(("hub::turn_cap_tests::caps", "FAILED")),
                                binary(("agent_inbox::delivers", "FAILED"))))
            out = self.run_cli("judge", "--head", str(head), "--base", str(base), "--job", JOB)
            self.assertEqual(out.returncode, 0, out.stdout + out.stderr)

    def test_touches(self):
        run = lambda changed: subprocess.run(  # noqa: E731
            [sys.executable, str(SCRIPT), "touches", "cmux-tui/crates/acpmux", "--repo", str(ROOT)],
            input=changed, capture_output=True, text=True, check=False)
        out = run("README.md\ncmux-tui/crates/cmux-server/src/lib.rs\n")
        self.assertEqual((out.returncode, out.stdout), (0, "cmux-tui/crates/cmux-server/src/lib.rs\n"), out.stderr)
        out = run("README.md\n")
        self.assertEqual((out.returncode, out.stdout), (1, ""), out.stderr)


if __name__ == "__main__":
    unittest.main()
