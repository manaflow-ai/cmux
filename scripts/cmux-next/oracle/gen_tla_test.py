#!/usr/bin/env python3
"""Tests of gen_tla.py (p15-oracle-100). Stdlib unittest, run as a script, not in CI.

    python3 -I scripts/cmux-next/oracle/gen_tla_test.py

The TLC tests need java and the tla2tools jar that plans/cmux-next/formal/tlc.sh pins; they skip without java.
"""

from __future__ import annotations

import json
import shutil
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import case_checks  # noqa: E402
import gen_tla  # noqa: E402
from gen_tla import ModelValue, Rec  # noqa: E402

CORPUS = gen_tla.DEFAULT_OUT
SCHEMA = gen_tla.REPO / "schemas" / "oracle" / "case-v1.schema.json"


def config(name: str = "t", cfg: str = "x.cfg") -> gen_tla.Config:
    return gen_tla.Config(name, cfg, 10, 1, 10, 1, 1)


def trace(spec: str, states, constants=None) -> gen_tla.Trace:
    return gen_tla.Trace(spec, config(), 0, 0, constants or {}, states)


def label(name: str, **fields) -> Rec:
    return Rec(name=name, **fields)


class ValueParserTest(unittest.TestCase):
    def test_values_tlc_prints(self):
        value = gen_tla.parse_value('[a |-> <<1, -2>>, b |-> {"x", y}, c |-> (p1 :> <<>> @@ p2 :> TRUE), d |-> 1..3]')
        self.assertEqual(value["a"], (1, -2))
        self.assertEqual(value["b"], frozenset({"x", ModelValue("y")}))
        self.assertEqual(value["c"][ModelValue("p1")], ())
        self.assertIs(value["c"][ModelValue("p2")], True)
        self.assertEqual(value["d"], frozenset({1, 2, 3}))

    def test_model_value_is_not_a_string(self):
        self.assertNotEqual(ModelValue("none"), "none")
        self.assertNotEqual("none", ModelValue("none"))
        self.assertEqual(len({ModelValue("a"), "a"}), 2)

    def test_records_are_hashable_set_members(self):
        value = gen_tla.parse_value('{[op |-> 1, tab |-> 2], [op |-> 1, tab |-> 2], [op |-> 2, tab |-> 2]}')
        self.assertEqual(len(value), 2)

    def test_string_escapes_and_errors(self):
        self.assertEqual(gen_tla.parse_value(r'"a\"b"'), 'a"b')
        with self.assertRaises(gen_tla.GenError):
            gen_tla.parse_value("<<1, 2")
        with self.assertRaises(gen_tla.GenError):
            gen_tla.parse_value("1 2")

    def test_function_access(self):
        self.assertEqual(gen_tla.at((5, 6), 2), 6)
        self.assertEqual(gen_tla.at(Rec({ModelValue("c1"): 3}), ModelValue("c1")), 3)
        with self.assertRaises(gen_tla.GenError):
            gen_tla.at((5,), 2)

    def test_parse_trace_keeps_only_asked_variables(self):
        text = ("---- MODULE tr ----\nSTATE_1 == \n/\\ a = <<1,\n  2>>\n/\\ b = {}\n\n\nSTATE_2 == \n/\\ a = <<3>>\n"
                "/\\ b = {1}\n\n====\n")
        states = gen_tla.parse_trace(text, {"a"})
        self.assertEqual(states, [{"a": (1, 2)}, {"a": (3,)}])


class ConfigTest(unittest.TestCase):
    CFG = ("\\* comment\nSPECIFICATION Spec\nCONSTANTS\n  NTabs = 4\n  Items = {\"a\", \"b\"}\n  InitLayout <- StripInit\n"
           "  None = none\nINVARIANTS\n  TypeOK\nCONSTRAINT InFlightBound\nCHECK_DEADLOCK FALSE\n")

    def test_constants(self):
        self.assertEqual(gen_tla.cfg_constants(self.CFG),
                         {"NTabs": 4, "Items": frozenset({"a", "b"}), "None": ModelValue("none")})

    def test_trace_cfg_keeps_constants_and_constraints_only(self):
        out = gen_tla.trace_cfg(self.CFG)
        self.assertIn("InitLayout <- StripInit", out)
        self.assertIn("CONSTRAINT\nInFlightBound", out)
        self.assertIn("INIT OracleInit", out)
        self.assertNotIn("TypeOK", out)
        self.assertNotIn("SPECIFICATION", out)

    def test_trace_module_labels_every_action_and_flags_the_rest(self):
        spec = gen_tla.load_actionmap()["TabLayout"]
        text = gen_tla.trace_module(spec)
        self.assertIn('\\E c \\in Clients : \\E s \\in inbox[c] : (Receive(c, s)) /\\ oracleAct\' = '
                      '[name |-> "Receive", c |-> c, s |-> s]', text)
        self.assertIn("OracleNext == Next /\\ (OracleLabeled \\/ (~OracleCovered", text)

    def test_actionmap_names_actions_of_the_specs(self):
        for spec in gen_tla.load_actionmap().values():
            source = (gen_tla.FORMAL / f"{spec.module}.tla").read_text(encoding="utf-8")
            for action in spec.actions:
                head = action.call.split("(")[0]
                self.assertRegex(source, rf"(?m)^{head}\b", f"{spec.name}: {head} is not defined in the spec")
            for cfg in spec.configs:
                self.assertTrue((gen_tla.FORMAL / cfg.cfg).is_file(), cfg.cfg)

    def test_override_constants_replaces_one_value(self):
        out = gen_tla.override_constants(self.CFG, (("NTabs", "5"),))
        self.assertEqual(gen_tla.cfg_constants(out)["NTabs"], 5)
        self.assertIn("InitLayout <- StripInit", out)
        with self.assertRaises(gen_tla.GenError):
            gen_tla.override_constants(self.CFG, (("MaxOps", "3"),))

    def test_excluded_specs_and_views_say_why(self):
        specs = gen_tla.load_actionmap()
        for name in ("FeedHandoff", "hovercard"):
            spec = specs[name]
            self.assertTrue(spec.excluded, name)
            self.assertFalse([a for a in spec.actions if a.map in ("owner", "restart")], name)
            self.assertFalse([c for c in spec.configs if c.cases], name)
            items = gen_tla.coverage_items(spec)
            self.assertTrue(items and all(items.values()), f"{name}: every item is excluded with a reason")
        closefocus = gen_tla.coverage_items(specs["closefocus"])
        self.assertIn("#26009", closefocus["closefocus:view"])
        self.assertIsNone(gen_tla.coverage_items(specs["TabLayout"])["TabLayout:restart-race"])
        self.assertNotIn("LayoutRows:restart-race", gen_tla.coverage_items(specs["LayoutRows"]))

    def test_tlc_pin_is_tlc_sh(self):
        version, digest = gen_tla.tlc_pin()
        self.assertEqual(version, "1.7.4")
        self.assertEqual(len(digest), 64)


class ProductDigestTest(unittest.TestCase):
    @staticmethod
    def case(prefix: str, note: str, index: int = 0, retry: bool = False):
        case = gen_tla.CaseBuilder(f"tablayout-{prefix}-0001")
        made = case.call(f"{prefix}-ws", "workspace.create", {}, {"initial_content": "terminal"})
        tab = gen_tla.value_ref(made, "tab_id")
        move = case.call(f"{prefix}-move", "tab.move", {"tab": tab}, {"index": index}, note=note)
        case.remember(1, move)
        if retry:
            case.replay(f"{prefix}-again", 1, note)
        else:
            case.call(f"{prefix}-again", "tab.move", {"tab": tab}, {"index": index}, note=note)
        case.state(move, {"workspaces": {"set": []}})
        return gen_tla.product_digest(case.steps, case.expected)

    def test_ids_notes_and_keys_do_not_make_a_case_distinct(self):
        self.assertEqual(self.case("m07", "TLA step 8"), self.case("m12", "TLA step 13"))

    def test_params_and_keyed_retries_do(self):
        self.assertNotEqual(self.case("m07", "x"), self.case("m07", "x", index=1))
        self.assertNotEqual(self.case("m07", "x"), self.case("m07", "x", retry=True))


class RestartRaceTest(unittest.TestCase):
    def test_a_fresh_move_after_a_restart_is_a_race_step(self):
        case = gen_tla.CaseBuilder("tablayout-t-0001", ("tab.move",))
        case.call("m01-move", "tab.move", {"tab": "x"}, {"index": 0})
        case.remember(1, "m01-move")
        case.restart("m02-restart", "restart")
        case.call("m03-close", "tab.close", {"tab": "x"})
        case.replay("m04-retry", 1, "retry")
        self.assertEqual(case.race_steps, [])
        case.call("m05-move", "tab.move", {"tab": "x"}, {"index": 1})
        self.assertEqual(case.race_steps, ["m05-move"])

    def test_expectations_block_keeps_other_lines(self):
        lines = ["#25999 [ daemon ] tla/tablayout-fixed-0001/m03-move [ Pass Failure ]"]
        fresh = gen_tla.render_expectations("", lines)
        self.assertTrue(fresh.startswith("# tla expectations"))
        self.assertIn(lines[0], fresh)
        kept = gen_tla.render_expectations("p15-oracle-100 tla/x [ Skip ]\n" + fresh, [])
        self.assertIn("p15-oracle-100 tla/x [ Skip ]", kept)
        self.assertNotIn(lines[0], kept)
        self.assertEqual(gen_tla.render_expectations(fresh, lines), fresh)


class DaemonMoveTest(unittest.TestCase):
    def test_own_pane_moves_name_one_more_to_the_right(self):
        # the daemon run of 2026-10-27: [T1,T2,T3], tab.move T1 index 2 gives [T2,T1,T3]
        self.assertEqual(gen_tla.move_index([1, 2, 3], [1, 2, 3], 1, 1, True), 2)
        self.assertEqual(gen_tla.daemon_move([1, 2, 3], [1, 2, 3], 1, 2, True)[1], [2, 1, 3])
        self.assertEqual(gen_tla.daemon_move([1, 2, 3], [1, 2, 3], 2, 1, True)[1], [1, 2, 3])
        self.assertEqual(gen_tla.daemon_move([1, 2, 3], [1, 2, 3], 3, 0, True)[1], [3, 1, 2])

    def test_other_pane_inserts_at_index(self):
        self.assertEqual(gen_tla.daemon_move([1, 2], [3], 1, 0, False), ([2], [1, 3]))
        self.assertEqual(gen_tla.daemon_move([1, 2], [3], 1, 9, False), ([2], [3, 1]))


def tablayout_state(layout, alive, ws, log=(), done=(), rejected=()):
    return {"layout": tuple(tuple(x) for x in layout), "alive": frozenset(alive), "wsOf": tuple(ws),
            "log": tuple(log), "doneOps": frozenset(done), "rejectedOps": frozenset(rejected)}


class TabLayoutProjectorTest(unittest.TestCase):
    def setUp(self):
        self.spec = gen_tla.load_actionmap()["TabLayout"]

    def build(self, states):
        case = gen_tla.CaseBuilder("tablayout-t-0001")
        gen_tla.TabLayoutProjector(self.spec).build(trace("TabLayout", states), case)
        return case

    def r(self, op, kind, tab, pane=0, idx=0):
        return Rec(op=op, client=1, kind=kind, tab=tab, pane=pane, idx=idx)

    def test_move_close_replay_and_restart(self):
        init = tablayout_state([[1, 2], [3], [], []], {1, 2}, [1, 1, 0, 0])
        init["oracleAct"] = label("Init")
        moved = tablayout_state([[2, 1], [3], [], []], {1, 2}, [1, 1, 0, 0], log=("b1",), done={1})
        moved["oracleAct"] = label("OwnerApply", r=self.r(1, "move", 1, 1, 2))
        replayed = dict(moved, oracleAct=label("OwnerApply", r=self.r(1, "move", 1, 1, 2)))
        closed = tablayout_state([[2, 1], [], [], []], {1}, [1, 0, 0, 0], log=("b1", "b2"), done={1, 2})
        closed["oracleAct"] = label("OwnerApply", r=self.r(2, "close", 3))
        again = tablayout_state([[2, 1], [], [], []], {1}, [1, 0, 0, 0], log=("b1", "b2"), done={1, 2, 3},
                                rejected={3})
        again["oracleAct"] = label("OwnerApply", r=self.r(3, "close", 3))
        restart = dict(again, oracleAct=label("OwnerRestart"))
        case = self.build([init, moved, replayed, closed, again, restart])
        steps = {s["id"]: s for s in case.steps}
        self.assertEqual(steps["m01-move"]["args"]["params"]["index"], 2)
        self.assertEqual(steps["m02-retry"]["args"], steps["m01-move"]["args"])
        self.assertEqual(steps["m04-close"]["expect"], {"outcome": "error", "error": "selector.not_found"})
        self.assertEqual(steps["m05-restart"]["op"], "restart")
        self.assertIn("restart", case.requires)
        self.assertEqual(case.expected[0]["state"],
                         {"workspaces": {"set": [{"set": [["t:1", "t:2"], ["t:3"]]}]}})
        self.assertEqual(case.expected[-1]["state"], {"workspaces": {"set": [{"set": [["t:2", "t:1"]]}]}})

    def test_split_is_unmapped(self):
        init = tablayout_state([[1, 2], [3], [], []], {1, 2}, [1, 1, 0, 0])
        init["oracleAct"] = label("Init")
        split = tablayout_state([[2], [3], [1], []], {1, 2, 3}, [1, 1, 1, 0], log=("b1",), done={1})
        split["oracleAct"] = label("OwnerApply", r=self.r(1, "split", 1, 1))
        with self.assertRaises(gen_tla.Unmapped) as raised:
            self.build([init, split])
        self.assertEqual(raised.exception.key, "TabLayout:op/split")

    def test_an_index_that_misses_the_model_is_a_generator_error(self):
        init = tablayout_state([[1, 2], [3], [], []], {1, 2}, [1, 1, 0, 0])
        init["oracleAct"] = label("Init")
        wrong = tablayout_state([[1, 2], [3], [], []], {1, 2}, [1, 1, 0, 0], log=("b1",), done={1})
        wrong["oracleAct"] = label("OwnerApply", r=self.r(1, "move", 1, 1, 2))
        with self.assertRaises(gen_tla.GenError):
            self.build([init, wrong])


def rows_own(cols, rows_of, panes_of, tabs_of, dock=None, used=None):
    n = 4
    rows_of = tuple(tuple(rows_of.get(c, ())) for c in range(1, n + 1))
    panes_of = tuple(tuple(panes_of.get(r, ())) for r in range(1, n + 1))
    tabs_of = tuple(tuple(tabs_of.get(p, ())) for p in range(1, n + 1))
    height = tuple(2 if any(r in x for x in rows_of) else 0 for r in range(1, n + 1))
    dock = tuple((dock or {}).get(c, "none") for c in range(1, n + 1))
    used = used or {}
    return Rec(cols=tuple(cols), rowsOf=rows_of, panesOf=panes_of, tabsOf=tabs_of, height=height, dock=dock,
               usedT=frozenset(used.get("T", {1, 2})), usedP=frozenset(used.get("P", {1, 2})),
               usedR=frozenset(used.get("R", {1})), usedC=frozenset(used.get("C", {1})), closed=frozenset(),
               orient="col")


def op(k, t=0, p=0, c=0, h=0, e="none"):
    return Rec(k=k, t=t, p=p, c=c, h=h, e=e, rs=False, b=False, rows=frozenset())


class RowsProjectorTest(unittest.TestCase):
    K = {"NTabs": 4, "NPanes": 4, "NRows": 3, "NCols": 2, "MaxH": 2, "FRAME": False}

    def setUp(self):
        self.spec = gen_tla.load_actionmap()["LayoutRows"]

    def state(self, own, req=(), done=(), commits=(0, 0, 0), name="Init"):
        return {"own": own, "req": frozenset(req), "done": frozenset(done), "commits": tuple(commits),
                "oracleAct": label(name)}

    def build(self, states):
        case = gen_tla.CaseBuilder("layoutrows-t-0001")
        gen_tla.RowsProjector(self.spec).build(trace("LayoutRows", states, self.K), case)
        return case

    def test_newcol_then_dock_reads_column_ids(self):
        one = rows_own([1], {1: [1]}, {1: [1, 2]}, {1: [1], 2: [2]})
        q1 = Rec(key=1, cl=1, op=op("newcol", p=2, h=2))
        two = rows_own([1, 2], {1: [1], 2: [2]}, {1: [1, 2], 2: [3]}, {1: [1], 2: [2], 3: [3]},
                       used={"T": {1, 2, 3}, "P": {1, 2, 3}, "R": {1, 2}, "C": {1, 2}})
        q2 = Rec(key=2, cl=1, op=op("dock", c=2, e="left"))
        docked = Rec(two, dock=("none", "left", "none", "none"))
        states = [self.state(one), self.state(one, req={q1}, name="Issue"),
                  self.state(two, done={q1}, commits=(1, 0, 0), name="Process"),
                  self.state(two, req={q2}, done={q1}, commits=(1, 0, 0), name="Issue"),
                  self.state(docked, done={q1, q2}, commits=(1, 1, 0), name="Process")]
        case = self.build(states)
        steps = {s["id"]: s for s in case.steps}
        self.assertEqual(steps["m02-newcol"]["args"]["params"], {"direction": "right", "viewport_width": 0.5})
        self.assertEqual(steps["m04-dock"]["args"]["params"]["column"], "$step:m04-columns#/layout/root/columns/1/column_id")
        self.assertTrue(steps["m04-columns"]["readOnly"])
        self.assertEqual(case.expected[-1]["state"]["cols"][1], {"dock": "left", "rows": [[["t:3"]]]})

    def test_pool_reject_and_rows_ops_are_dropped(self):
        one = rows_own([1], {1: [1]}, {1: [1, 2]}, {1: [1], 2: [2]})
        q = Rec(key=1, cl=1, op=op("newrow", p=1, h=2))
        with self.assertRaises(gen_tla.Unmapped) as raised:
            self.build([self.state(one), self.state(one, req={q}, name="Issue"),
                        self.state(one, done={q}, name="Process")])
        self.assertEqual(raised.exception.key, "LayoutRows:op/newrow")
        full = rows_own([1], {1: [1]}, {1: [1, 2]}, {1: [1], 2: [2]}, used={"T": {1, 2, 3, 4}, "P": {1, 2, 3, 4}})
        q = Rec(key=1, cl=1, op=op("split", p=1))
        with self.assertRaises(gen_tla.Unmapped) as raised:
            self.build([self.state(full), self.state(full, req={q}, name="Issue"),
                        self.state(full, done={q}, name="Process")])
        self.assertEqual(raised.exception.key, "LayoutRows:reject/id-pool")

    def test_guard_drift_is_a_generator_error(self):
        one = rows_own([1], {1: [1]}, {1: [1, 2]}, {1: [1], 2: [2]})
        q = Rec(key=1, cl=1, op=op("close", t=1))
        with self.assertRaises(gen_tla.GenError):  # the model committed nothing for a close our guards call done
            self.build([self.state(one), self.state(one, req={q}, name="Issue"),
                        self.state(one, done={q}, name="Process")])


class MatchTest(unittest.TestCase):
    def test_binding_is_kept_across_steps(self):
        want = {"workspaces": {"set": [{"set": [["t:1", "t:2"], ["t:3"]]}]}}
        got = {"workspaces": {"set": [{"set": [["tab#3"], ["tab#1", "tab#2"]]}]}}
        binding = gen_tla.match(want, got, {})
        self.assertEqual(binding, {"t:1": "tab#1", "t:2": "tab#2", "t:3": "tab#3"})
        swapped = {"workspaces": {"set": [{"set": [["tab#2", "tab#1"], ["tab#3"]]}]}}
        self.assertIsNone(gen_tla.match(want, swapped, binding))

    def test_kinds_do_not_mix_and_ids_are_one_to_one(self):
        self.assertIsNone(gen_tla.match(["t:1"], ["pane#1"], {}))
        self.assertIsNone(gen_tla.match(["t:1", "t:2"], ["tab#1", "tab#1"], {}))

    def test_projection_of_a_viewport(self):
        facets = {"daemon": {"session": {"screens": [{"workspace_id": "workspace#1", "layout": {"root": {
            "kind": "viewport", "columns": [
                {"root": {"kind": "split", "first": {"kind": "leaf", "pane_id": "pane#1", "tab_ids": ["tab#1"]},
                          "second": {"kind": "leaf", "pane_id": "pane#2", "tab_ids": ["tab#2"]}}},
                {"dock": {"edge": "left", "mode": "docked"},
                 "root": {"kind": "leaf", "pane_id": "pane#3", "tab_ids": ["tab#3"]}}]}}}]}}}
        self.assertEqual(gen_tla.project("rows", facets),
                         {"cols": [{"dock": "none", "rows": [[["tab#1"], ["tab#2"]]]},
                                   {"dock": "left", "rows": [[["tab#3"]]]}]})
        self.assertEqual(gen_tla.project("strip", facets), {"cols": [["pane#1", "pane#2"], ["pane#3"]]})
        self.assertEqual(gen_tla.project("tabs", facets),
                         {"workspaces": {"set": [{"set": [["tab#1"], ["tab#2"], ["tab#3"]]}]}})

    def test_check_result_reports_the_first_divergence(self):
        case = {"id": "c"}
        expected = [{"step": "a", "state": {"cols": [["p:a"]], "view": {"focus": "p:a"}}},
                    {"step": "b", "state": {"cols": [["p:a"], ["p:e"]], "view": {"focus": "p:e"}}}]

        def snap(cols):
            columns = [{"root": {"kind": "leaf", "pane_id": p, "tab_ids": []}} for [p] in cols]
            return {"facets": {"daemon": {"session": {"screens": [{"workspace_id": "w", "layout": {
                "root": {"kind": "viewport", "columns": columns}}}]}}}}

        good = {"status": "Pass", "checkpoints": [{"step": "a", "checkpoint": "settled", "snapshot": snap([["pane#1"]])},
                                                  {"step": "b", "checkpoint": "settled",
                                                   "snapshot": snap([["pane#1"], ["pane#2"]])}]}
        outcome = gen_tla.check_result(good, case, expected, "strip")
        self.assertEqual((outcome.status, outcome.unchecked), ("Pass", ["view"]))
        bad = json.loads(json.dumps(good))
        bad["checkpoints"][1]["snapshot"] = snap([["pane#2"], ["pane#1"]])
        outcome = gen_tla.check_result(bad, case, expected, "strip")
        self.assertEqual(outcome.status, "Failure")
        self.assertIn("b:", outcome.problems[0])


@unittest.skipUnless(CORPUS.is_dir(), "no tests/oracle/corpus/tla")
class CorpusTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        gen_tla.corpus_store.ensure(CORPUS.parent, [gen_tla.SUITE])  # the suite is a pinned artifact, not in git

    def test_every_case_passes_the_case_checks_and_has_expected_states(self):
        rules = case_checks.Rules(json.loads(SCHEMA.read_text(encoding="utf-8")))
        specs = gen_tla.load_actionmap()
        coverage = json.loads((CORPUS / gen_tla.COVERAGE).read_text(encoding="utf-8"))
        self.assertFalse(coverage["missing"], coverage["missing"])
        for spec in specs.values():
            if spec.excluded:
                self.assertEqual(coverage["specs"][spec.name]["excluded"], spec.excluded)
                self.assertFalse(list(CORPUS.glob(f"{spec.slug}-*.json")), spec.name)
                continue
            expected = json.loads((CORPUS / gen_tla.expected_name(spec.slug)).read_text(encoding="utf-8"))["cases"]
            cases = sorted(CORPUS.glob(f"{spec.slug}-*.json"))
            self.assertGreaterEqual(len(cases), 200, spec.name)
            self.assertEqual(set(expected), {p.stem for p in cases})
            digests = set()
            for path in cases:
                case = json.loads(path.read_text(encoding="utf-8"))
                findings = [f.message for f in case_checks.check_case(case, rules)]
                self.assertFalse(findings, f"{path.name}: {findings}")
                self.assertEqual((case["id"], case["suite"]), (path.stem, gen_tla.SUITE))
                ids = {s["id"] for s in case["steps"]}
                for entry in expected[path.stem]:
                    self.assertIn(entry["step"], ids)
                digests.add(gen_tla.product_digest(case["steps"], expected[path.stem]))
            self.assertEqual(len(digests), len(cases), f"{spec.name}: every case is a distinct product run")
        self.assertEqual(sorted(p.name for p in CORPUS.iterdir() if p.is_dir()), [], "the suite is flat")

    def test_restart_race_cases_have_their_expectations_lines(self):
        import expectations  # noqa: E402

        coverage = json.loads((CORPUS / gen_tla.COVERAGE).read_text(encoding="utf-8"))
        path = gen_tla.expectations_path(CORPUS)
        text = path.read_text(encoding="utf-8")
        self.assertEqual(gen_tla.render_expectations(text, coverage["expectations"]), text)
        race = gen_tla.load_actionmap()["TabLayout"].race
        self.assertEqual(len(coverage["expectations"]), 2 * race.keep)
        for line in coverage["expectations"]:
            self.assertTrue(line.startswith(f"{race.issue} [ daemon ] tla/"), line)
            target = line.split()[4]
            _, case_id, step = target.split("/")
            case = json.loads((CORPUS / f"{case_id}.json").read_text(encoding="utf-8"))
            moves = [s["id"] for s in case["steps"] if (s.get("args") or {}).get("method") == "tab.move"]
            self.assertIn(step, moves)
        diags = expectations.lint(expectations.Expectations.load([path.parent], []), CORPUS.parent)
        self.assertFalse([d for d in diags if d.file.endswith("tla.txt") or d.code == "golden-budget"], diags)

    def test_oracle_check_accepts_the_suite(self):
        import oracle  # noqa: E402

        cases, errors = oracle.load_corpus(CORPUS.parent)
        self.assertFalse([e for e in errors if e.startswith(f"{gen_tla.SUITE}/")])
        self.assertGreaterEqual(sum(1 for c in cases if c.suite == gen_tla.SUITE), 800)

    def test_owns_files_by_slug(self):
        self.assertTrue(gen_tla.owns("tablayout-fixed-0001.json", ["tablayout"]))
        self.assertTrue(gen_tla.owns("_expected-tablayout.json", ["tablayout"]))
        self.assertFalse(gen_tla.owns("closefocus-strip-0001.json", ["tablayout"]))
        self.assertFalse(gen_tla.owns("coverage.json", ["tablayout"]))
        self.assertTrue(gen_tla.owns("coverage.json", []))


@unittest.skipUnless(shutil.which("java"), "no java")
class SimulateTest(unittest.TestCase):
    def test_closefocus_batch_is_labeled_and_stable(self):
        spec = gen_tla.load_actionmap()["closefocus"]
        small = gen_tla.Config("strip", "closefocus-strip.cfg", 12, 77, 20, 1, 1)
        jar = gen_tla.tlc_jar()
        first = [t.states for t in gen_tla.simulate(spec, small, 0, jar, {"cols", "focus"})]
        second = [t.states for t in gen_tla.simulate(spec, small, 0, jar, {"cols", "focus"})]
        self.assertEqual(len(first), 20)
        self.assertEqual(first, second)
        labels = {s["oracleAct"]["name"] for states in first for s in states}
        self.assertTrue(labels <= {"Init", "Close", "Focus", "Create", "Animate", "Resync"}, labels)

    def test_excluded_specs_label_every_next_step(self):
        specs = gen_tla.load_actionmap()
        jar = gen_tla.tlc_jar()
        for name in ("FeedHandoff", "hovercard"):
            spec = specs[name]
            small = gen_tla.Config("t", spec.configs[0].cfg, 12, 91, 30, 1, 0)
            labels = {s["oracleAct"]["name"] for t in gen_tla.simulate(spec, small, 0, jar, set()) for s in t.states}
            self.assertTrue(labels - {"Init"} <= {a.label for a in spec.actions}, f"{name}: {labels}")
            self.assertGreater(len(labels), 2, name)


if __name__ == "__main__":
    unittest.main(verbosity=2)
