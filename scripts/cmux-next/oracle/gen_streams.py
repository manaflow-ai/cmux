#!/usr/bin/env python3
"""Generate the streams suite: one case per stream_open and connection_control operation of the catalog.

Spec: plans/cmux-next/chrome-parity/p15-oracle.md, section 3D (suite streams: 6 stream_open + 13
connection_control = 19) and task 204. Stdlib only, Python 3.9+, safe under `python3 -I`. `oracle.py gen --suite
streams` runs it with `--out <corpus>/streams`.

These operations act on the connection that sends them: a stream belongs to its connection, `request.cancel`
cancels only that connection's own requests, `client current` is the sender, and a viewer lease is the
attachment of one connection. So a case names its connections (`args.connection`, case-v1), and the steps of
one scenario run on one connection while the main connection makes the changes the stream must carry. Each case
is one scenario of its operation; the three the task names are `request.cancel` (cancel a terminal.wait in
flight), `client.detach` (detach the connection while its session.events stream is open) and
`terminal.viewer.resize` (resize during an attach).

Chrome reference (chromium/src): mojo/public/cpp/bindings/tests/ test each interface's connection lifecycle
(a pipe closed during a pending call, a reset while a response is in flight: connection_group_unittest.cc,
receiver_set_unittest.cc) as cases of their own, not as side effects of feature tests. Every call here is
checked against the daemon's own request check before it is written (gen_daemon_ops.CatalogCheck, the Python
port of catalog_validation.rs), as Mojo's generated validation data is checked by the bindings that read it.

The session event log of every stream case is the oracle's I8 input: event_log.py records `session.events`
through the Python SDK and invariants.py I8 folds it and compares the fold with the daemon facet at each
checkpoint's cursor. `session-events-ok` is the case whose stream I8 reads with a change on another connection.

coverage.json lists every operation with its class, case, scenario, connections and expected outcome; a catalog
operation of either class that has no case here is a generation error, so a new one gets its case first.

Usage:
  gen_streams.py --out DIR          write the cases and coverage.json into DIR
  gen_streams.py --out DIR --check  exit 1 when DIR differs from a fresh generation
  gen_streams.py --selftest         offline tests against the checked-in catalog
"""

from __future__ import annotations

import argparse
import copy
import json
import re
import sys
import tempfile
import unittest
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Dict, List, Mapping, Optional, Sequence, Tuple

HERE = Path(__file__).resolve().parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))
import gen_daemon_ops as ops  # noqa: E402
from gen_daemon_ops import Handle  # noqa: E402

REPO = HERE.parents[2]
DEFAULT_OUT = REPO / "tests" / "oracle" / "corpus" / "streams"
CASE_SCHEMA = ops.CASE_SCHEMA
SUITE = "streams"
GENERATOR = "scripts/cmux-next/oracle/gen_streams.py"
CLASSES = ("stream_open", "connection_control")
MAIN = "main"
SCOPE = ops.SCOPE
# A terminal.wait pattern no fixture terminal prints: the wait stays in flight until it is canceled.
NEVER_PRINTED = "oracle-pattern-never-printed"


class GenError(Exception):
    """The catalog and the case table disagree, or a call fails the daemon's request check."""


@dataclass(frozen=True)
class Ref:
    """A value from an earlier step of this case (`$step:<step>#<pointer>`); `sample` is a well-formed value of
    its type for the request check."""

    step: str
    pointer: str
    sample: Any


@dataclass(frozen=True)
class Call:
    """One resource.call step. `target` holds the selectors (Handle, Ref or a selector string), `params` the
    fields. Connection-scoped operations get `scope: connection` and no idempotency key; a mutation gets one."""

    id: str
    operation: str
    target: Mapping[str, Any] = field(default_factory=dict)
    params: Mapping[str, Any] = field(default_factory=dict)
    connection: str = MAIN
    error: Optional[str] = None
    result: Optional[Mapping[str, Any]] = None
    in_flight: bool = False
    note: Optional[str] = None


@dataclass(frozen=True)
class Case:
    operation: str
    scenario: str
    steps: Tuple[Call, ...]
    invariants: Tuple[str, ...] = ()
    untested: Tuple[str, ...] = ()
    # The sidebar plugin setup of the daemon-ops tuning runs first (a sidebar view needs a configured plugin).
    sidebar_plugin: bool = False


TERMINAL = {"terminal": Handle("terminal")}
BROWSER = {"browser": Handle("browser")}
SELF = {"client": "current"}
LEASE = "lease-sample"
STREAM = Ref("open", "/stream_id", ops.resource_id("stream"))
SIDEBAR_VIEW = Ref("ensure-view", "/value/id", ops.resource_id("sidebar_view"))
# A browser tab needs an engine: only a cmux-browser provider (or the app) gives one, as daemon-ops requires.
BROWSER_OPERATIONS = ("browser.", "tab.create_browser")


def sidebar_plugin_setup() -> List[Mapping[str, Any]]:
    """The steps that write and load a sidebar plugin config: the `before` of daemon-ops' sidebar_view.ensure
    success tuning, the one place that setup is written."""
    path = ops.DEFAULT_OUT / "sidebar" / ops.TUNING
    tuning = json.loads(path.read_text(encoding="utf-8"))["operations"]["sidebar_view.ensure"]["success"]
    return list(tuning["before"])


def attach(connection: str = "viewer", step: str = "attach") -> Call:
    return Call(step, "terminal.attach", TERMINAL, {"cols": 80, "rows": 24}, connection)


def browser_attach(connection: str = "viewer") -> Call:
    return Call("attach", "browser.attach", BROWSER, {"width_px": 800, "height_px": 600}, connection)


def events(connection: str = "watch", step: str = "open") -> Call:
    return Call(step, "session.events", connection=connection)


def rename(name: str) -> Call:
    """A mutation on the main connection: the change an open session.events stream must carry."""
    return Call("rename", "workspace.rename", {"workspace": Handle("workspace")}, {"name": name})


CASES: Tuple[Case, ...] = (
    # stream_open ----------------------------------------------------------------------------------------
    Case("session.events", "open the stream on one connection, change the session on another",
         (Call("call", "session.events", connection="watch"), rename("streamed")),
         ("I8: the watch connection's session.events log, folded, equals the daemon facet at every checkpoint "
          "after it opened, the rename included",)),
    Case("session.journal.subscribe", "read the journal from its beginning and complete",
         (Call("call", "session.journal.subscribe", params={"start": "beginning", "follow": False},
               connection="journal"),),
         ("follow false: the stream completes at the head captured when it opened",)),
    Case("terminal.attach", "attach a viewer to the fixture terminal",
         (Call("call", "terminal.attach", TERMINAL, {"cols": 80, "rows": 24}, "viewer"),),
         ("the viewer client lists the terminal in attached_terminal_ids",)),
    Case("browser.attach", "attach a viewer to the fixture browser",
         (Call("call", "browser.attach", BROWSER, {"width_px": 800, "height_px": 600}, "viewer"),)),
    Case("sidebar_view.attach", "attach to the sidebar view of a configured plugin",
         (Call("ensure-view", "sidebar_view.ensure", params={"cols": 80, "rows": 24}),
          Call("call", "sidebar_view.attach", {"sidebar_view": SIDEBAR_VIEW}, connection="viewer")),
         sidebar_plugin=True),
    Case("conversation.events", "open the stream of a conversation that does not exist",
         (Call("call", "conversation.events", params={"conversation": "conv_" + "0" * 26}, connection="watch",
               error="resource.not_found"),),
         untested=("a success case needs a conversation the user takes part in; the standard fixture has none "
                   "(p15-oracle-069 makes one for the chief family)",)),
    # connection_control ---------------------------------------------------------------------------------
    Case("stream.cancel", "cancel an open session.events stream on its own connection",
         (events(), Call("call", "stream.cancel", {"stream": STREAM}, connection="watch")),
         ("the watch log ends canceled; the stream is gone from the daemon's live subscriptions",)),
    Case("request.cancel", "cancel in flight: a terminal.wait that cannot match, canceled before it answers",
         (Call("wait", "terminal.wait", TERMINAL, {"pattern": NEVER_PRINTED}, "waiter", in_flight=True,
               note="never matches and has no timeout: only the cancel ends it"),
          Call("call", "request.cancel", params={"request_id": Ref("wait", "/request_id", "request-sample")},
               connection="waiter", result={"canceled": True},
               note="canceled true: the cancel wins against a wait that cannot complete")),
         ("the wait sends no response after the cancel's confirmation",)),
    Case("client.detach", "detach during stream: the connection detaches itself while its session.events is open",
         (events(), Call("call", "client.detach", SELF, connection="watch"), rename("after-detach")),
         ("the watch connection is gone from clients; its session.events log ends closed and carries no later "
          "change; I8 holds for it up to its end",)),
    Case("client.metadata.update", "the connection names itself",
         (Call("call", "client.metadata.update", SELF, {"name": "oracle-viewer"}, "viewer"),),
         ("the viewer client's name is oracle-viewer in the daemon facet",)),
    Case("client.sizing.set", "an attached viewer takes part in sizing the terminal",
         (attach(), Call("call", "client.sizing.set", {**TERMINAL, **SELF}, {"enabled": True}, "viewer"))),
    Case("client.sizing.release", "an attached viewer stops sizing the terminal",
         (attach(), Call("enable", "client.sizing.set", {**TERMINAL, **SELF}, {"enabled": True}, "viewer"),
          Call("call", "client.sizing.release", {**TERMINAL, **SELF}, connection="viewer"))),
    Case("client.cell_pixels.set", "the connection reports its cell size",
         (attach(), Call("call", "client.cell_pixels.set", SELF, {"width_px": 8, "height_px": 16}, "viewer"))),
    Case("terminal.viewer.resize", "resize during attach: the viewer resizes its own attachment",
         (attach(), Call("call", "terminal.viewer.resize", TERMINAL,
                         {"attachment_lease": Ref("attach", "/attachment_lease", LEASE), "cols": 100, "rows": 30},
                         "viewer")),
         ("the viewer's size of the terminal is 100x30 in the daemon facet's clients",)),
    Case("terminal.viewer.release", "the viewer releases its attachment",
         (attach(), Call("call", "terminal.viewer.release", TERMINAL,
                         {"attachment_lease": Ref("attach", "/attachment_lease", LEASE)}, "viewer"))),
    Case("browser.viewer.resize", "resize during attach: the browser viewer resizes its own attachment",
         (browser_attach(), Call("call", "browser.viewer.resize", BROWSER,
                                 {"attachment_lease": Ref("attach", "/attachment_lease", LEASE), "width_px": 1024,
                                  "height_px": 768}, "viewer"))),
    Case("browser.viewer.release", "the browser viewer releases its attachment",
         (browser_attach(), Call("call", "browser.viewer.release", BROWSER,
                                 {"attachment_lease": Ref("attach", "/attachment_lease", LEASE)}, "viewer"))),
    Case("terminal.renderer_grant.create", "the connection mints a short renderer grant for the fixture terminal",
         (Call("call", "terminal.renderer_grant.create", TERMINAL, {"ttl_ms": 1000}, "renderer",
               note="the token is sensitive: the case expects the receipt, never the token"),)),
    Case("origin.confirmation.issue", "an unverified connection asks for a confirmation token",
         (Call("call", "origin.confirmation.issue",
               params={"operation": "session.ping", "params_sha256": "0" * 64, "relay_connection_id": "1"},
               connection="relay", error="origin.forbidden",
               note="no connection is verified before peer verification ships (the catalog's constraint)"),),
         untested=("a success case needs a verified app connection and a live page relay connection",)),
)


# ---------------------------------------------------------------------------------------------- building


def snake(name: str) -> str:
    return re.sub(r"(?<!^)(?=[A-Z])", "_", name).lower()


def receipt_kind(catalog: ops.Catalog, operation: str) -> str:
    """The reply kind I1 expects: the catalog result type's name in snake case (mutation_result for a
    mutation, as gen_daemon_ops writes)."""
    result = catalog.operations[operation]["result"]
    if result.get("kind") == "apply" and result.get("name") == "MutationResult":
        return "mutation_result"
    if result.get("kind") != "ref":
        raise GenError(f"{operation}: its result is not a named type")
    return snake(result["name"])


def ref_text(value: Ref) -> str:
    return f"$step:{value.step}#{value.pointer}"


def wire(value: Any) -> Any:
    """The case value: fixture handles and step references as `$step:` strings."""
    if isinstance(value, Ref):
        return ref_text(value)
    if isinstance(value, Handle):
        return ops.refs(value)
    if isinstance(value, Mapping):
        return {key: wire(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [wire(item) for item in value]
    return value


def sample(synth: ops.Synth, value: Any) -> Any:
    """The value with every handle and reference replaced by a well-formed value of its type."""
    if isinstance(value, Ref):
        return value.sample
    if isinstance(value, Handle):
        return synth.concrete(value)
    if isinstance(value, Mapping):
        return {key: sample(synth, item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [sample(synth, item) for item in value]
    return value


def handles(value: Any) -> List[str]:
    if isinstance(value, Handle):
        return [value.name]
    if isinstance(value, Mapping):
        return [h for item in value.values() for h in handles(item)]
    if isinstance(value, (list, tuple)):
        return [h for item in value for h in handles(item)]
    return []


def selectors_of(catalog: ops.Catalog, operation: str) -> Mapping[str, str]:
    return catalog.operations[operation]["params"]["selectors"]


def call_step(catalog: ops.Catalog, synth: ops.Synth, case_id: str, call: Call, checkpoint: Optional[List[str]]
              ) -> Dict[str, Any]:
    spec = catalog.operations.get(call.operation)
    if spec is None:
        raise GenError(f"{case_id}/{call.id}: {call.operation} is not in the catalog")
    selectors = selectors_of(catalog, call.operation)
    target = {**{k: v for k, v in SCOPE.items() if k in selectors}, **call.target}
    unknown = sorted(set(target) - set(selectors))
    if unknown:
        raise GenError(f"{case_id}/{call.id}: {call.operation} has no selector {', '.join(unknown)}")
    request = {**sample(synth, target), **sample(synth, call.params)}
    if spec["class"] == "stream_open":
        request["stream_id"] = ops.resource_id("stream")  # the SDK's open_stream adds it
    problem = ops.CatalogCheck(catalog).params(call.operation, request)
    if problem is not None:
        raise GenError(f"{case_id}/{call.id}: {call.operation} fails the daemon's request check: {problem}")
    cls = spec["class"]
    args: Dict[str, Any] = {"method": call.operation}
    if call.params:
        args["params"] = wire(call.params)
    step: Dict[str, Any] = {"id": call.id, "op": "resource.call"}
    if target:
        step["target"] = wire(target)
    if cls == "mutation":
        args["idempotencyKey"] = f"{case_id}.{call.id}"
    elif cls in CLASSES:
        args["scope"] = "connection"
    elif cls == "read":
        step["readOnly"] = True
    else:
        raise GenError(f"{case_id}/{call.id}: {call.operation} has class {cls}")
    if call.connection != MAIN:
        args["connection"] = call.connection
    if call.in_flight:
        if call.operation not in ("terminal.wait", "terminal.wait_exit"):
            raise GenError(f"{case_id}/{call.id}: only terminal.wait and terminal.wait_exit can be canceled in flight")
        args["inFlight"] = True
    step["args"] = args
    if call.error is not None:
        if call.error not in spec.get("errors", []):
            raise GenError(f"{case_id}/{call.id}: {call.operation} does not list error {call.error}")
        step["expect"] = {"outcome": "error", "error": call.error}
    elif cls == "read":
        step["expect"] = {"outcome": "ok"}
    else:
        step["expect"] = {"outcome": "ok", "receipt": receipt_kind(catalog, call.operation)}
    if call.result is not None:
        step["expect"]["result"] = dict(call.result)
    if checkpoint:
        step["checkpoint"] = checkpoint
    if call.note:
        step["note"] = call.note
    return step


def case_id_of(case: Case) -> str:
    """`<operation slug>-ok` or `-error` by the outcome of the case's one `call` step, as daemon-ops names cases."""
    calls = [call for call in case.steps if call.id == "call"]
    if len(calls) != 1 or calls[0].operation != case.operation:
        raise GenError(f"{case.operation}: want exactly one step `call` of the operation")
    return f"{ops.slug(case.operation)}-{'error' if calls[0].error else 'ok'}"


def case_doc(catalog: ops.Catalog, synth: ops.Synth, case: Case) -> Dict[str, Any]:
    case_id = case_id_of(case)
    steps = [ops.call_step(case_id, fx.id, fx.operation, {s: Handle(h) for s, h in fx.target}, fx.params, ops.OK)
             for fx in (ops.FIXTURE_BY_ID[i] for i in ops.fixture_closure(
                 [h for call in case.steps for h in handles(call.target) + handles(call.params)]))]
    connections = sorted({call.connection for call in case.steps} - {MAIN})
    if case.sidebar_plugin:
        # The `before` of sidebar_view.ensure's success tuning: tuned_step reads its request only for a replay.
        owner = ops.Request("sidebar_view.ensure")
        steps.extend(ops.tuned_step(case_id, spec, catalog, owner) for spec in sidebar_plugin_setup())
    for call in case.steps:
        steps.append(call_step(catalog, synth, case_id, call, ["before", "settled"] if call.id == "call" else None))
    steps.append({"id": "settle", "op": "settle", "note": "the last cut: I8 folds every open log up to it"})
    ids = [step["id"] for step in steps]
    if len(ids) != len(set(ids)):
        raise GenError(f"{case_id}: duplicate step ids {ids}")
    browser = any(step.get("args", {}).get("method", "").startswith(BROWSER_OPERATIONS) for step in steps)
    preconditions = ["hermetic state root", "no other cmux-tui on the state root",
                     f"one SDK connection per case connection: main, {', '.join(connections)}"]
    if browser:
        preconditions.append(ops.ENGINE_PRECONDITION)
    doc: Dict[str, Any] = {
        "$schema": ops.SCHEMA_REF,
        "corpusVersion": 1,
        "id": case_id,
        "suite": SUITE,
        "title": f"{case.operation}: {case.scenario}",
        "surface": "cmux-next-daemon",
        "source": {"repo": "manaflow-ai/cmux", "ref": "$RUN", "artifact": "$RUN"},
        "environment": {},
        "fixture": {"seed": f"{SUITE}.{ops.slug(case.operation)}", "network": "offline", "clock": "virtual"},
        "preconditions": preconditions,
        "requires": ["resource_api", *(["chromium"] if browser else [])],
        "platforms": ["linux", "mac"],
        "steps": steps,
        "invariants": [f"generated by {GENERATOR} from the catalog entry of {case.operation} "
                       f"({catalog.operations[case.operation]['class']})", *case.invariants],
        "teardown": ["close every case connection", "stop the case daemon",
                     "verify the socket and state root are gone"],
    }
    if case.untested:
        doc["untested"] = list(case.untested)
    return doc


def generate(catalog: ops.Catalog) -> Dict[str, Any]:
    """{file name: JSON value} for the whole suite, coverage.json included."""
    wanted = {name: spec["class"] for name, spec in catalog.operations.items() if spec.get("class") in CLASSES}
    listed = [case.operation for case in CASES]
    if len(listed) != len(set(listed)):
        raise GenError("CASES lists an operation twice")
    missing, extra = sorted(set(wanted) - set(listed)), sorted(set(listed) - set(wanted))
    if missing:
        raise GenError(f"no case for {', '.join(missing)}: add each to CASES")
    if extra:
        raise GenError(f"{', '.join(extra)}: not a {' or '.join(CLASSES)} operation of the catalog")
    synth = ops.Synth(catalog)
    files: Dict[str, Any] = {}
    operations: Dict[str, Any] = {}
    for case in sorted(CASES, key=lambda c: c.operation):
        doc = case_doc(catalog, synth, case)
        files[f"{doc['id']}.json"] = doc
        call = next(step for step in doc["steps"] if step["id"] == "call")
        operations[case.operation] = {
            "class": wanted[case.operation],
            "cases": {"case": f"{SUITE}/{doc['id']}"},
            "scenario": case.scenario,
            "connections": sorted({step["args"].get("connection", MAIN) for step in doc["steps"]
                                   if step["op"] == "resource.call"}),
            "expect": call["expect"],
        }
    counts = {cls: sum(1 for c in wanted.values() if c == cls) for cls in CLASSES}
    files[ops.COVERAGE] = {
        "generator": GENERATOR,
        "catalog": "cmux-tui/spec/resource-operations-v2.json",
        "catalog_sha256": catalog.sha256,
        "suite": SUITE,
        "total": len(wanted),
        "listed": len(operations),
        "classes": counts,
        "verdicts": "not run",
        "operations": operations,
    }
    return files


# --------------------------------------------------------------------------------------------- self test


class GenStreamsSelfTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.catalog = ops.Catalog.load()
        cls.files = generate(cls.catalog)
        cls.cases = {name: doc for name, doc in cls.files.items() if name != ops.COVERAGE}

    def test_every_stream_open_and_connection_control_operation_is_listed(self) -> None:
        coverage = self.files[ops.COVERAGE]
        self.assertEqual((coverage["total"], coverage["listed"]), (19, 19))
        self.assertEqual(coverage["classes"], {"stream_open": 6, "connection_control": 13})
        self.assertEqual(len(self.cases), 19)

    def test_a_new_operation_of_either_class_needs_a_case(self) -> None:
        data = copy.deepcopy(self.catalog.data)
        data["operations"]["stream.pause"] = {**data["operations"]["stream.cancel"]}
        with self.assertRaisesRegex(GenError, "no case for stream.pause"):
            generate(ops.Catalog(data, json.dumps(data)))
        del data["operations"]["stream.pause"]
        data["operations"]["stream.cancel"] = {**data["operations"]["stream.cancel"], "class": "mutation"}
        with self.assertRaisesRegex(GenError, "stream.cancel: not a"):
            generate(ops.Catalog(data, json.dumps(data)))

    def test_the_named_connection_scenarios(self) -> None:
        def steps(name: str) -> List[Dict[str, Any]]:
            return [s for s in self.cases[name]["steps"] if s["op"] == "resource.call"]

        wait, cancel = steps("request-cancel-ok.json")[-2:]
        self.assertEqual((wait["args"]["method"], wait["args"]["inFlight"], wait["readOnly"]), ("terminal.wait", True, True))
        self.assertEqual(cancel["args"]["params"]["request_id"], "$step:wait#/request_id")
        self.assertEqual(wait["args"]["connection"], cancel["args"]["connection"], "cancel is connection-local")
        self.assertEqual(cancel["expect"]["result"], {"canceled": True})
        opened, detach, after = steps("client-detach-ok.json")[-3:]
        self.assertEqual((opened["args"]["method"], detach["args"]["method"]), ("session.events", "client.detach"))
        self.assertEqual(detach["target"]["client"], "current")
        self.assertEqual(opened["args"]["connection"], detach["args"]["connection"])
        self.assertNotIn("connection", after["args"], "the change after the detach comes from main")
        attach_step, resize = steps("terminal-viewer-resize-ok.json")[-2:]
        self.assertEqual(attach_step["args"]["method"], "terminal.attach")
        self.assertEqual(resize["args"]["params"]["attachment_lease"], "$step:attach#/attachment_lease")
        self.assertEqual(attach_step["args"]["connection"], resize["args"]["connection"])

    def test_fixtures_the_daemon_cannot_supply_are_set_up_or_required(self) -> None:
        browser = sorted(name for name, case in self.cases.items() if "chromium" in case["requires"])
        self.assertEqual(browser, ["browser-attach-ok.json", "browser-viewer-release-ok.json",
                                   "browser-viewer-resize-ok.json"], "a browser tab needs an engine")
        sidebar = self.cases["sidebar-view-attach-ok.json"]["steps"]
        self.assertEqual([s["id"] for s in sidebar],
                         ["write-config", "config-written", "reload-config", "ensure-view", "call", "settle"],
                         "the plugin is configured before the view starts")
        self.assertEqual(sidebar[4]["target"]["sidebar_view"], "$step:ensure-view#/value/id")

    def test_session_events_carries_a_change_from_another_connection(self) -> None:
        calls = [s for s in self.cases["session-events-ok.json"]["steps"] if s["op"] == "resource.call"]
        stream = next(s for s in calls if s["id"] == "call")
        change = next(s for s in calls if s["id"] == "rename")
        self.assertEqual(stream["args"]["connection"], "watch")
        self.assertNotIn("connection", change["args"])
        self.assertLess(calls.index(stream), calls.index(change))

    def test_connection_scoped_calls_have_no_idempotency_key_and_a_typed_outcome(self) -> None:
        for name, case in self.cases.items():
            for step in case["steps"]:
                if step["op"] != "resource.call":
                    continue
                cls = self.catalog.operations[step["args"]["method"]]["class"]
                self.assertEqual("idempotencyKey" in step["args"], cls == "mutation", f"{name} {step['id']}")
                self.assertEqual(step["args"].get("scope") == "connection", cls in CLASSES, f"{name} {step['id']}")
                expect = step["expect"]
                if expect["outcome"] == "ok" and cls != "read":
                    self.assertEqual(expect["receipt"], receipt_kind(self.catalog, step["args"]["method"]))
        self.assertEqual(receipt_kind(self.catalog, "terminal.attach"), "view_attachment_stream_opened")
        self.assertEqual(receipt_kind(self.catalog, "stream.cancel"), "empty_result")

    def test_error_cases_name_an_error_the_catalog_lists(self) -> None:
        errors = {name: s["expect"]["error"] for name, c in self.cases.items() for s in c["steps"]
                  if s["id"] == "call" and s["expect"]["outcome"] == "error"}
        self.assertEqual(errors, {"conversation-events-error.json": "resource.not_found",
                                  "origin-confirmation-issue-error.json": "origin.forbidden"})
        bad = Case("stream.cancel", "x", (events(), Call("call", "stream.cancel", {"stream": STREAM}, connection="watch",
                                                         error="cursor.gap")))
        with self.assertRaisesRegex(GenError, "does not list error cursor.gap"):
            case_doc(self.catalog, ops.Synth(self.catalog), bad)

    def test_every_call_passes_the_daemon_request_check(self) -> None:
        bad = Case("terminal.viewer.resize", "x", (attach(), Call("call", "terminal.viewer.resize", TERMINAL,
                                                                  {"attachment_lease": LEASE, "cols": 0, "rows": 30},
                                                                  "viewer")))
        with self.assertRaisesRegex(GenError, "request check"):
            case_doc(self.catalog, ops.Synth(self.catalog), bad)
        no_selector = Case("request.cancel", "x", (Call("call", "request.cancel", TERMINAL, {"request_id": "r"}),))
        with self.assertRaisesRegex(GenError, "has no selector terminal"):
            case_doc(self.catalog, ops.Synth(self.catalog), no_selector)

    def test_cases_pass_the_case_schema_and_its_checks(self) -> None:
        normalize = __import__("normalize")
        checks = __import__("case_checks")
        schema = json.loads(CASE_SCHEMA.read_text(encoding="utf-8"))
        rules = checks.Rules(schema)
        for name, case in sorted(self.cases.items()):
            self.assertEqual(normalize.validate(case, schema), [], name)
            self.assertEqual(checks.check_case(case, rules), [], name)

    def test_regeneration_is_byte_stable_and_check_finds_drift(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp)
            self.assertEqual(ops.write(out, generate(self.catalog))[0], 20)
            self.assertEqual(ops.write(out, generate(self.catalog)), (0, 0))
            self.assertEqual(ops.drift(out, generate(self.catalog)), [])
            (out / "stream-cancel-ok.json").write_text("{}\n", encoding="utf-8")
            self.assertEqual(ops.drift(out, generate(self.catalog)),
                             ["stream-cancel-ok.json: differs from a fresh generation"])


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT, help="the suite directory (default: the corpus)")
    parser.add_argument("--catalog", type=Path, default=ops.CATALOG)
    parser.add_argument("--check", action="store_true", help="exit 1 when --out differs from a fresh generation")
    parser.add_argument("--selftest", action="store_true", help="run the offline self tests")
    args = parser.parse_args(argv)
    if args.selftest:
        suite = unittest.defaultTestLoader.loadTestsFromTestCase(GenStreamsSelfTest)
        return 0 if unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful() else 1
    try:
        files = generate(ops.Catalog.load(args.catalog))
        coverage = files[ops.COVERAGE]
        if args.check:
            problems = ops.drift(args.out, files)
            for problem in problems:
                print(f"gen_streams: {problem}", file=sys.stderr)
            print(f"gen_streams: {coverage['listed']}/{coverage['total']} operations, "
                  f"{'stale' if problems else 'up to date'}")
            return 1 if problems else 0
        written, removed = ops.write(args.out, files)
    except (GenError, ops.GenError) as error:
        print(f"gen_streams: {error}", file=sys.stderr)
        return 2
    print(f"gen_streams: {coverage['listed']}/{coverage['total']} operations, {len(files) - 1} cases, "
          f"{written} files written, {removed} removed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
