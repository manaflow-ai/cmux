"""cmux-next pushes check generated files in daemon-test, on its package build.

Both jobs ran the same `swift build --build-tests` of Packages/macOS/CmuxNext on
a push (265-579 s of Mac time each). On a push that daemon-test runs on,
generated-files is skipped and daemon-test runs its checks and its verdict.
Pull requests keep the generated-files job."""

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


class GeneratedFoldTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.jobs = yaml.safe_load(WORKFLOW.read_text())["jobs"]
        cls.daemon = cls.jobs["daemon-test"]
        cls.generated = cls.jobs["generated-files"]

    def steps(self, job):
        return [s.get("name", "") for s in job["steps"]]

    def step(self, job, name):
        return next(s for s in job["steps"] if s.get("name") == name)

    def test_daemon_test_folds_only_a_routed_push(self):
        self.assertEqual(
            self.daemon["env"]["CMUX_NEXT_FOLD_GENERATED"],
            "${{ github.event_name == 'push' && inputs.same_tree_sha == '' && needs.path_route.outputs.generated == 'true' }}")

    def test_generated_files_skips_exactly_the_pushes_daemon_test_runs_on(self):
        gen_if = self.generated["if"]
        clause = ("!(github.event_name == 'push' && inputs.same_tree_origin != 'push' && inputs.same_tree_sha == '' "
                  "&& needs.path_route.outputs.daemon == 'true' && needs.path_route.outputs.tree_state == 'ready')")
        self.assertIn(clause, gen_if)
        # daemon-test's push condition: the folded clause plus what generated-files' own if already requires.
        daemon_if = self.daemon["if"]
        for part in ("inputs.same_tree_origin != 'push'", "!cancelled()",
                     "(needs.web-bundles.result == 'success' || needs.web-bundles.result == 'skipped')",
                     "inputs.same_tree_sha == '' && needs.path_route.outputs.daemon == 'true' && "
                     "needs.push-head-preflight.outputs.current == 'true' && needs.path_route.outputs.tree_state == 'ready'"):
            self.assertIn(part, daemon_if)
        for part in ("!cancelled()", "(needs.web-bundles.result == 'success' || needs.web-bundles.result == 'skipped')",
                     "needs.path_route.outputs.generated == 'true'", "needs.push-head-preflight.outputs.current == 'true'"):
            self.assertIn(part, gen_if)
        self.assertEqual(self.daemon["needs"], self.generated["needs"])

    def test_every_routed_event_is_checked_by_one_job_or_skipped_by_both_on_purpose(self):
        """Evaluates both conditions over pushes (inputs unset), same-tree dispatches, ready, deferred
        and failed trees, web bundles, a superseded head and the generated route: generated-files runs
        as before except where daemon-test runs and folds, and a fold never happens without the run."""
        skip = (" && !(github.event_name == 'push' && inputs.same_tree_origin != 'push' && inputs.same_tree_sha == '' "
                "&& needs.path_route.outputs.daemon == 'true' && needs.path_route.outputs.tree_state == 'ready') }}")
        old_gen_if = self.generated["if"].replace(skip, " }}")
        self.assertNotEqual(old_gen_if, self.generated["if"])
        fold_env = self.daemon["env"]["CMUX_NEXT_FOLD_GENERATED"]
        events = [("push", {}), ("pull_request", {}),
                  ("workflow_dispatch", {"same_tree_sha": "a" * 40, "same_tree_origin": "push", "same_tree_state": "ready",
                                         "same_tree_tiers": "daemon scheme"}),
                  ("workflow_dispatch", {"same_tree_sha": "a" * 40, "same_tree_origin": "dispatch", "same_tree_state": "ready",
                                         "same_tree_tiers": "daemon"}),
                  ("workflow_dispatch", {})]
        cases = 0
        for (event, inputs), daemon, tree, web, current, generated, cancelled in itertools.product(
                events, ("true", "false"), ("ready", "deferred", "failed"), ("success", "skipped", "failure"),
                ("true", "false"), ("true", "false"), (False, True)):
            ctx = {"github": {"event_name": event, "repository": "manaflow-ai/cmux",
                              "event": {"pull_request": {"head": {"repo": {"full_name": "manaflow-ai/cmux"}}, "labels": []}}},
                   "inputs": inputs, "cancelled": cancelled,
                   "needs": {"path_route": {"outputs": {"daemon": daemon, "generated": generated, "tree_state": tree}},
                             "web-bundles": {"result": web}, "push-head-preflight": {"outputs": {"current": current}}}}
            gen_before = truthy(Expr(old_gen_if, ctx).value())
            gen_now = truthy(Expr(self.generated["if"], ctx).value())
            daemon_runs = truthy(Expr(self.daemon["if"], ctx).value())
            folds = daemon_runs and Expr(fold_env, ctx).value() is True
            with self.subTest(event=event, inputs=inputs, daemon=daemon, tree=tree, web=web, current=current,
                              generated=generated, cancelled=cancelled):
                self.assertEqual(gen_now, gen_before and not folds)
                self.assertFalse(gen_before and not gen_now and not folds, "generated files skipped and checked by nobody")
                if folds:
                    self.assertEqual(event, "push")
                if event != "push":
                    self.assertEqual(gen_now, gen_before)
            cases += 1
        self.assertEqual(cases, 720)
        # The fold happens on a ready push and on nothing else.
        ready_push = {"github": {"event_name": "push"}, "inputs": {}, "cancelled": False,
                      "needs": {"path_route": {"outputs": {"daemon": "true", "generated": "true", "tree_state": "ready"}},
                                "web-bundles": {"result": "success"}, "push-head-preflight": {"outputs": {"current": "true"}}}}
        self.assertFalse(truthy(Expr(self.generated["if"], ready_push).value()))
        self.assertTrue(truthy(Expr(self.daemon["if"], ready_push).value()))
        ready_push["needs"]["path_route"]["outputs"]["tree_state"] = "deferred"
        self.assertTrue(truthy(Expr(self.generated["if"], ready_push).value()))

    def test_the_evaluator_follows_github_semantics(self):
        ctx = {"inputs": {}, "a": {"b": [{"n": "x"}, {"n": "y"}]}}
        self.assertTrue(Expr("inputs.same_tree_sha == ''", ctx).value())
        self.assertTrue(Expr("inputs.same_tree_origin != 'push'", ctx).value())
        self.assertTrue(Expr("contains(a.b.*.n, 'y')", ctx).value())
        self.assertEqual(Expr("'' || 'z'", ctx).value(), "z")
        self.assertEqual(Expr("'q' && 'z'", ctx).value(), "z")
        self.assertFalse(truthy(Expr("!('a' == 'A')", ctx).value()))

    def test_the_checks_run_on_the_build_before_the_catalogs_compile(self):
        names = self.steps(self.daemon)
        build = names.index("Build package and tests")
        catalogs = names.index("Compile string catalogs into the resource bundles")
        actions = names.index("Check generated action catalog, surfaces and inventory")
        settings = names.index("Check the settings exports")
        self.assertLess(build, actions)
        self.assertLess(settings, catalogs)
        for name in ("Check generated action catalog, surfaces and inventory", "Check the settings exports"):
            ours, theirs = self.step(self.daemon, name), self.step(self.generated, name)
            self.assertEqual(ours["if"], "${{ " + FOLD + " }}")
            self.assertTrue(ours["continue-on-error"])
            self.assertEqual(ours["run"], theirs["run"])
            self.assertEqual(ours.get("id"), theirs.get("id"))
        self.assertEqual(self.step(self.daemon, "Check generated action catalog, surfaces and inventory")["env"],
                         {"CMUX_ACTION_SURFACES_SKIP_BUILD": "1"})

    def test_the_verdict_is_the_generated_files_verdict_after_the_daemon_suites(self):
        names = self.steps(self.daemon)
        suites = names.index("Run the live-daemon suites")
        for name in ("Regenerate stale files", "Upload the regenerated files", "Fail on stale generated files"):
            self.assertGreater(names.index(name), suites)
            ours, theirs = self.step(self.daemon, name), self.step(self.generated, name)
            self.assertIn("!cancelled()", ours["if"])
            for key in ("run", "with", "id"):
                self.assertEqual(ours.get(key), theirs.get(key), f"{name}: {key}")
        self.assertIn(STALE, self.step(self.daemon, "Fail on stale generated files")["run"])

    def test_the_exports_cache_accepts_a_folded_push(self):
        cache = self.jobs["swift-exports-cache"]
        self.assertIn("path_route", cache["needs"])
        self.assertIn("(needs.generated-files.result == 'success' || needs.generated-files.result == 'skipped' "
                      "&& needs.path_route.outputs.generated == 'true')", cache["if"])
        self.assertIn("needs.daemon-test.result == 'success'", cache["if"])

    def test_the_check_script_skips_the_build_only_when_asked(self):
        script = (ROOT / "scripts/cmux-next/check-action-surfaces.sh").read_text()
        self.assertRegex(script, re.escape('[[ "${CMUX_ACTION_SURFACES_SKIP_BUILD:-}" != 1 ]] || skip_build=(--skip-build)'))
        # bash 3.2 (macOS /bin/bash) treats an empty "${a[@]}" as unbound under set -u.
        self.assertIn('${skip_build[@]+"${skip_build[@]}"}', script)


if __name__ == "__main__":
    unittest.main()
