"""cmux-next checks generated files on one package build: one `swift build --build-tests` producer.

swift-test, daemon-test and generated-files each ran their own `swift build --build-tests` of
Packages/macOS/CmuxNext on a separate Mac (HQ#4724; 265-579 s of Mac time each, plus each job's
setup). Path routing now names one job that checks the generated files (path_route's
generated_host): daemon-test on a push it runs on, swift-test where it runs and builds, daemon-test
on a pull request it runs on, and only otherwise the generated-files job's own build. The folded
verdict is its own check (generated-verdict), never the host's result."""

from __future__ import annotations

import itertools
import math
import re
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/cmux-next.yml"
FOLD = "env.CMUX_NEXT_FOLD_GENERATED == 'true'"
STALE = "::error::Generated cmux-next files are stale. Regenerate them as the step summary says."


class Expr:
    """A small evaluator of the GitHub Actions expressions these job conditions use:
    literals, property paths (with `.*.`), !, ==, !=, &&, || (operand-valued),
    parentheses, cancelled() and contains(). Loose equality as GitHub does it:
    values of different types compare as numbers (null and '' are 0)."""

    TOKEN = re.compile(r"\s*(?:(\d+)|'((?:[^']|'')*)'|(&&|\|\||==|!=|!|\(|\)|,)|([A-Za-z_][A-Za-z0-9_.*-]*))")

    def __init__(self, text, ctx):
        text = text.strip()
        if text.startswith("${{") and text.endswith("}}"):
            text = text[3:-2]
        self.toks, pos = [], 0
        text = text.strip()
        while pos < len(text):
            m = self.TOKEN.match(text, pos)
            if not m or m.end() == pos:
                raise ValueError(f"cannot parse at {text[pos:pos + 30]!r}")
            num, string, op, name = m.groups()
            self.toks.append(("num", int(num)) if num else ("str", string.replace("''", "'")) if string is not None
                             else ("op", op) if op else ("name", name))
            pos = m.end()
            while pos < len(text) and text[pos].isspace():
                pos += 1
        self.i, self.ctx = 0, ctx

    def value(self):
        v = self.or_()
        assert self.i == len(self.toks), self.toks[self.i:]
        return v

    def peek(self, op):
        return self.i < len(self.toks) and self.toks[self.i] == ("op", op)

    def or_(self):
        v = self.and_()
        while self.peek("||"):
            self.i += 1
            r = self.and_()
            v = v if truthy(v) else r
        return v

    def and_(self):
        v = self.cmp()
        while self.peek("&&"):
            self.i += 1
            r = self.cmp()
            v = r if truthy(v) else v
        return v

    def cmp(self):
        v = self.unary()
        while self.peek("==") or self.peek("!="):
            op = self.toks[self.i][1]
            self.i += 1
            r = self.unary()
            v = loose_eq(v, r) if op == "==" else not loose_eq(v, r)
        return v

    def unary(self):
        if self.peek("!"):
            self.i += 1
            return not truthy(self.unary())
        if self.peek("("):
            self.i += 1
            v = self.or_()
            assert self.peek(")")
            self.i += 1
            return v
        kind, tok = self.toks[self.i]
        self.i += 1
        if kind in ("num", "str"):
            return tok
        if self.peek("("):
            self.i += 1
            args = []
            while not self.peek(")"):
                args.append(self.or_())
                if self.peek(","):
                    self.i += 1
            self.i += 1
            if tok == "cancelled":
                return bool(self.ctx.get("cancelled"))
            if tok == "contains":
                hay, needle = args
                return needle in hay if isinstance(hay, (list, str)) else False
            raise ValueError(tok)
        if tok in ("true", "false", "null"):
            return {"true": True, "false": False, "null": None}[tok]
        return lookup(self.ctx, tok)


def lookup(ctx, path):
    cur = ctx
    parts = path.split(".")
    for n, part in enumerate(parts):
        if part == "*":
            rest = ".".join(parts[n + 1:])
            return [lookup(x, rest) for x in (cur or [])]
        cur = cur.get(part) if isinstance(cur, dict) else None
    return cur


def number(v):
    if v is None:
        return 0.0
    if isinstance(v, bool):
        return float(v)
    if isinstance(v, (int, float)):
        return float(v)
    try:
        return float(v) if v.strip() else 0.0
    except ValueError:
        return math.nan


def loose_eq(a, b):
    if type(a) is type(b):
        return a.lower() == b.lower() if isinstance(a, str) else a == b
    return number(a) == number(b)


def truthy(v):
    return not (v is None or v is False or v == "" or (isinstance(v, (int, float)) and (v == 0 or math.isnan(v))))


BUILD = "swift build --build-tests"
HOSTS = ("swift-test", "daemon-test")
CHECKS = ("Check generated action catalog, surfaces and inventory", "Check the settings exports")
TAIL = ("Regenerate stale files", "Upload the regenerated files", "Give the generated files verdict")
REPO = "manaflow-ai/cmux"
NEXT = "refs/heads/feat-cmux-next"


def route_ctx(event, ref, generated, swift, targets, daemon, tree, marker):
    """path_route's own expression context: its route step, the tree probes and the marker upload."""
    return {"github": {"event_name": event, "ref": ref},
            "steps": {"route": {"outputs": {"generated": generated, "swift": swift, "swift_targets": targets,
                                            "daemon": daemon}},
                      "tree": {"outputs": {"tree_state": tree}}, "tree-final": {"outputs": {}},
                      "marker-upload": {"outcome": marker}}}


class GeneratedFoldTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.jobs = yaml.safe_load(WORKFLOW.read_text())["jobs"]
        cls.daemon = cls.jobs["daemon-test"]
        cls.swift = cls.jobs["swift-test"]
        cls.generated = cls.jobs["generated-files"]
        cls.verdict = cls.jobs["generated-verdict"]
        cls.route = cls.jobs["path_route"]

    def steps(self, job):
        return [s.get("name", "") for s in job["steps"]]

    def step(self, job, name):
        return next(s for s in job["steps"] if s.get("name") == name)

    def builders(self, job):
        return [s for s in job.get("steps", []) if BUILD in s.get("run", "")]

    def host(self, *args):
        return Expr(self.route["outputs"]["generated_host"], route_ctx(*args)).value()

    def test_only_the_three_package_jobs_run_the_test_build(self):
        producers = sorted(job_id for job_id, job in self.jobs.items() if self.builders(job))
        self.assertEqual(producers, ["daemon-test", "generated-files", "swift-test"])
        for job_id in producers:
            self.assertEqual(len(self.builders(self.jobs[job_id])), 1, job_id)

    def test_each_host_folds_exactly_where_path_routing_picks_it(self):
        for job_id in HOSTS:
            self.assertEqual(self.jobs[job_id]["env"]["CMUX_NEXT_FOLD_GENERATED"],
                             "${{ needs.path_route.outputs.generated_host == '%s' }}" % job_id)
            self.assertIn("steps.generated-files-verdict.outputs.verdict", self.jobs[job_id]["outputs"]["generated_files"])
        self.assertIn("needs.path_route.outputs.generated_host == 'generated-files'", self.generated["if"])
        self.assertEqual(self.daemon["needs"], self.generated["needs"])
        self.assertEqual(self.swift["needs"], self.generated["needs"])

    def test_every_routed_run_builds_once_for_its_generated_files(self):
        """Evaluates path_route's generated_host and the four jobs' conditions over events, routes,
        tree states, web bundles, a superseded head and the fork clause. Where the generated files are
        routed they are checked exactly once, by the job path routing named; generated-files builds
        only when neither swift-test nor daemon-test builds; and on a pull request with daemon or swift
        inputs (HQ#4724) the generated files add no build producer: one producer for swift or daemon
        with generated, two only for swift and daemon both (their suites run in parallel)."""
        host_expr = self.route["outputs"]["generated_host"]
        tree_expr = self.route["outputs"]["tree_state"]
        swift_build_if = self.builders(self.swift)[0]["if"]
        events = [("push", NEXT), ("push", "refs/heads/main"),
                  ("pull_request", "refs/pull/1/merge"), ("workflow_dispatch", NEXT)]
        cases = pr_single = 0
        for (event, ref), generated, swift, targets, daemon, tree, marker, web, current, fork in itertools.product(
                events, ("true", "false"), ("true", "false"), ("all", ""), ("true", "false"),
                ("ready", "deferred", "failed", ""), ("", "failure"), ("success", "failure"), ("true", "false"),
                (False, True)):
            rctx = route_ctx(event, ref, generated, swift, targets, daemon, tree, marker)
            host = Expr(host_expr, rctx).value()
            tree_state = Expr(tree_expr, rctx).value()
            outputs = {"generated": generated, "swift": swift, "swift_targets": targets, "daemon": daemon,
                       "tree_state": tree_state, "generated_host": host}
            head = "someone/fork" if fork else REPO
            ctx = {"github": {"event_name": event, "ref": ref, "repository": REPO,
                              "event": {"pull_request": {"head": {"repo": {"full_name": head}}, "labels": []}}},
                   "inputs": {}, "cancelled": False,
                   "needs": {"path_route": {"outputs": outputs}, "web-bundles": {"result": web},
                             "push-head-preflight": {"outputs": {"current": current}}}}
            runs = {job_id: truthy(Expr(self.jobs[job_id]["if"], ctx).value())
                    for job_id in ("swift-test", "daemon-test", "generated-files")}
            builds = {
                "swift-test": runs["swift-test"] and truthy(
                    Expr(swift_build_if, dict(ctx, env={"SWIFT_TARGETS": targets}, steps={})).value()),
                "daemon-test": runs["daemon-test"],
                "generated-files": runs["generated-files"],
            }
            folds = {job_id: runs[job_id]
                     and Expr(self.jobs[job_id]["env"]["CMUX_NEXT_FOLD_GENERATED"], ctx).value() is True
                     for job_id in HOSTS}
            ctx["needs"]["swift-test"] = {"result": "success" if runs["swift-test"] else "skipped"}
            ctx["needs"]["daemon-test"] = {"result": "success" if runs["daemon-test"] else "skipped"}
            verdict = truthy(Expr(self.verdict["if"], ctx).value())
            # The generated-files job's condition before generated_host: its shared prerequisites.
            gen_routed = (generated == "true" and web == "success" and current == "true"
                          and not (event == "pull_request" and fork))
            with self.subTest(event=event, ref=ref, generated=generated, swift=swift, targets=targets, daemon=daemon,
                              tree=tree, marker=marker, web=web, current=current, fork=fork, host=host):
                checked_by = [job_id for job_id in HOSTS if folds[job_id]] + (
                    ["generated-files"] if runs["generated-files"] else [])
                self.assertEqual(len(checked_by), 1 if gen_routed else 0, checked_by)
                if gen_routed:
                    self.assertEqual(checked_by, [host])
                for job_id in HOSTS:
                    if folds[job_id]:
                        self.assertTrue(builds[job_id], f"{job_id} folds but does not build")
                self.assertEqual(verdict, folds["swift-test"] or folds["daemon-test"])
                if runs["generated-files"]:
                    self.assertFalse(builds["swift-test"] or builds["daemon-test"],
                                     "generated-files builds beside another package build")
                producers = sum(builds.values())
                if gen_routed:
                    self.assertEqual(producers, max(1, builds["swift-test"] + builds["daemon-test"]))
                if event == "pull_request" and gen_routed and builds["swift-test"] + builds["daemon-test"] == 1:
                    self.assertEqual(producers, 1)
                    pr_single += 1
            cases += 1
        self.assertEqual(cases, 4 * 2 * 2 * 2 * 2 * 4 * 2 * 2 * 2 * 2)
        self.assertGreater(pr_single, 0)

    def test_a_pull_request_with_daemon_or_swift_and_generated_inputs_has_one_build_producer(self):
        """HQ#4724's case, spelled out: before, swift-test (or daemon-test) and generated-files both built."""
        pr = ("pull_request", "refs/pull/1/merge")
        self.assertEqual(self.host(*pr, "true", "true", "all", "false", "", ""), "swift-test")
        self.assertEqual(self.host(*pr, "true", "false", "", "true", "ready", ""), "daemon-test")
        self.assertEqual(self.host(*pr, "true", "true", "all", "true", "ready", ""), "swift-test")
        # No targets: swift-test does not build, so the daemon tests or the job's own build check them.
        self.assertEqual(self.host(*pr, "true", "true", "", "true", "ready", ""), "daemon-test")
        self.assertEqual(self.host(*pr, "true", "true", "", "false", "", ""), "generated-files")
        self.assertEqual(self.host(*pr, "true", "false", "", "true", "deferred", ""), "generated-files")
        self.assertEqual(self.host(*pr, "false", "true", "all", "true", "ready", ""), "none")
        # A push keeps daemon-test as its host (swift-test skips a feat-cmux-next push).
        self.assertEqual(self.host("push", NEXT, "true", "true", "all", "true", "ready", ""), "daemon-test")
        self.assertEqual(self.host("push", NEXT, "true", "true", "all", "true", "ready", "failure"), "generated-files")
        self.assertEqual(self.host("push", NEXT, "true", "true", "all", "true", "deferred", ""), "generated-files")
        # A dispatch builds in swift-test, else in daemon-test.
        self.assertEqual(self.host("workflow_dispatch", NEXT, "true", "true", "all", "true", "ready", ""), "swift-test")
        self.assertEqual(self.host("workflow_dispatch", NEXT, "true", "false", "", "true", "ready", ""), "daemon-test")

    def test_the_evaluator_follows_github_semantics(self):
        ctx = {"inputs": {}, "a": {"b": [{"n": "x"}, {"n": "y"}]}}
        self.assertTrue(Expr("inputs.same_tree_sha == ''", ctx).value())
        self.assertTrue(Expr("inputs.same_tree_origin != 'push'", ctx).value())
        self.assertTrue(Expr("contains(a.b.*.n, 'y')", ctx).value())
        self.assertEqual(Expr("'' || 'z'", ctx).value(), "z")
        self.assertEqual(Expr("'q' && 'z'", ctx).value(), "z")
        self.assertFalse(truthy(Expr("!('a' == 'A')", ctx).value()))
        self.assertEqual(Expr("('' || 'ready') == 'ready' && 'x'", ctx).value(), "x")

    def test_the_checks_run_on_the_build_before_the_catalogs_compile(self):
        for host in (self.daemon, self.swift):
            names = self.steps(host)
            build = names.index("Build package and tests")
            catalogs = names.index("Compile string catalogs into the resource bundles")
            for name in CHECKS:
                self.assertLess(build, names.index(name))
                self.assertLess(names.index(name), catalogs)
                ours, theirs = self.step(host, name), self.step(self.generated, name)
                self.assertTrue(ours["if"].startswith("${{ " + FOLD), ours["if"])
                self.assertTrue(ours["continue-on-error"])
                self.assertEqual(ours["run"], theirs["run"])
                self.assertEqual(ours.get("id"), theirs.get("id"))
            self.assertEqual(self.step(host, CHECKS[0])["env"], {"CMUX_ACTION_SURFACES_SKIP_BUILD": "1"})

    def test_the_hosts_give_a_verdict_after_their_suites_and_never_fail_on_it(self):
        for host, suites in ((self.daemon, "Run the live-daemon suites"),
                             (self.swift, "Run package tests (changed suites first, then selected targets)")):
            names = self.steps(host)
            for name in TAIL:
                self.assertGreater(names.index(name), names.index(suites))
                self.assertIn("!cancelled()", self.step(host, name)["if"])
            for name in TAIL[:2]:
                ours, theirs = self.step(host, name), self.step(self.generated, name)
                for key in ("run", "with", "id"):
                    self.assertEqual(ours.get(key), theirs.get(key), f"{name}: {key}")
            give = self.step(host, "Give the generated files verdict")
            self.assertEqual(give["id"], "generated-files-verdict")
            self.assertIn(FOLD, give["if"])
            self.assertNotIn("exit 1", give["run"])
            self.assertNotIn("Fail on stale generated files", names)
        self.assertIn(STALE, self.step(self.generated, "Fail on stale generated files")["run"])

    def test_the_verdict_job_fails_a_stale_file_or_a_missing_verdict(self):
        self.assertEqual(self.verdict["needs"], ["path_route", "swift-test", "daemon-test"])
        self.assertTrue(self.verdict["name"].startswith("cmux-next generated files"))
        self.assertNotIn("macos", self.verdict["runs-on"])
        run = self.verdict["steps"][0]["run"]
        self.assertIn("fresh)", run)
        self.assertEqual(run.count("exit 1"), 3)
        env = self.verdict["steps"][0]["env"]
        for host in HOSTS:
            self.assertIn(f"needs.{host}.outputs.generated_files", env["VERDICT"])

    def run_script(self, script, **env):
        import os, subprocess, tempfile
        with tempfile.TemporaryDirectory() as temp:
            summary, output = Path(temp) / "summary", Path(temp) / "output"
            summary.write_text(""); output.write_text("")
            result = subprocess.run(["bash", "-e", "-c", script], capture_output=True, text=True,
                                    env={**os.environ, "GITHUB_STEP_SUMMARY": str(summary), "GITHUB_OUTPUT": str(output),
                                         **env})
            return result, summary.read_text(), output.read_text()

    def test_a_catalog_failure_is_never_labelled_stale(self):
        # 2026-10-29: the action checks failed with fresh exports too (judge-action-exports.sh said "a catalog failure,
        # not a stale file"), but every summary said "Generated cmux-next files are stale" and pointed at the
        # regenerator, which changes nothing there (#27632, the base red of #27245).
        for host in (self.swift, self.daemon):
            give = self.step(host, "Give the generated files verdict")
            self.assertEqual(give["env"]["CATALOG"], "${{ steps.actions.outputs.catalog }}")
            run = give["run"]
            result, summary, output = self.run_script(run, ACTIONS="failure", CATALOG="failure", SETTINGS="success")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("verdict=catalog", output)
            self.assertIn("a catalog failure, not stale files", summary)
            self.assertNotIn("are stale", summary)
            result, summary, output = self.run_script(run, ACTIONS="failure", CATALOG="", SETTINGS="success")
            self.assertIn("verdict=stale", output)
            self.assertIn("Generated cmux-next files are stale", summary)
            result, summary, output = self.run_script(run, ACTIONS="success", CATALOG="", SETTINGS="success")
            self.assertIn("verdict=fresh", output)
        verdict = self.verdict["steps"][0]["run"]
        result, _, _ = self.run_script(verdict, VERDICT="catalog", HOST="swift-test", HOST_RESULT="failure")
        self.assertEqual(result.returncode, 1)
        self.assertIn("a catalog failure, not stale files", result.stdout)
        self.assertNotIn("are stale", result.stdout)
        fail = self.step(self.generated, "Fail on stale generated files")
        result, summary, _ = self.run_script(fail["run"], ACTIONS="failure", CATALOG="failure", SETTINGS="success")
        self.assertEqual(result.returncode, 1)
        self.assertIn("a catalog failure, not stale files", result.stdout + summary)
        self.assertNotIn(STALE, result.stdout)
        result, summary, _ = self.run_script(fail["run"], ACTIONS="failure", CATALOG="", SETTINGS="success")
        self.assertIn(STALE, result.stdout)

    def test_a_folded_swift_test_pass_records_only_with_fresh_generated_files(self):
        """A folded run keys the base the generated files are compared with and records a pass only
        when they are fresh, so a reused pass stands for the generated files too."""
        key = self.step(self.swift, "Fingerprint this job's inputs")["run"]
        self.assertIn('--extra "generated_base=$([[ "$CMUX_NEXT_FOLD_GENERATED" != true ]] || git rev-parse HEAD^1)"', key)
        for name in ("Record this pass for the same inputs", "Save the pass"):
            self.assertIn("(env.CMUX_NEXT_FOLD_GENERATED != 'true' || steps.generated-files-verdict.outputs.verdict == 'fresh')",
                          self.step(self.swift, name)["if"])
        self.assertEqual(self.swift["outputs"]["generated_files"],
                         "${{ steps.reuse.outputs.hit == 'true' && 'fresh' || steps.generated-files-verdict.outputs.verdict }}")
        self.assertEqual(self.daemon["outputs"]["generated_files"], "${{ steps.generated-files-verdict.outputs.verdict }}")

    def test_the_exports_cache_accepts_a_folded_push(self):
        cache = self.jobs["swift-exports-cache"]
        self.assertIn("generated-verdict", cache["needs"])
        self.assertIn("(needs.generated-files.result == 'success' || needs.generated-files.result == 'skipped' "
                      "&& needs.generated-verdict.result == 'success')", cache["if"])
        self.assertIn("needs.daemon-test.result == 'success'", cache["if"])

    def test_the_check_script_skips_the_build_only_when_asked(self):
        script = (ROOT / "scripts/cmux-next/check-action-surfaces.sh").read_text()
        self.assertRegex(script, re.escape('[[ "${CMUX_ACTION_SURFACES_SKIP_BUILD:-}" != 1 ]] || skip_build=(--skip-build)'))
        # bash 3.2 (macOS /bin/bash) treats an empty "${a[@]}" as unbound under set -u.
        self.assertIn('${skip_build[@]+"${skip_build[@]}"}', script)


if __name__ == "__main__":
    unittest.main()
