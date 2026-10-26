#!/usr/bin/env python3
"""The oracle's app driver, v0 facets: a tagged bench build of cmux driven through its control socket.

Spec: plans/cmux-next/chrome-parity/p15-oracle.md, task 006 (this v0 capture) and task 047 (the full driver with
`debug.oracle.*`, which replaces the v0 parts). Stdlib plus the cmux Python SDK of this checkout, safe under
`python3 -I`. It implements the driver protocol of oracle.py (`open_session`, `session.run_case`, `session.close`).
A fleet Mac with a GUI session only (bench_launch.py checks it); never the person's Mac, never
`/Applications/cmux.app`: the app is the tag's own `cmux DEV <tag>.app`.

v0 reads only methods that exist at the push base (facets_v0.py names each one), so the same driver captures the
push base and every later SHA with no source change:
- the app's control socket: `snapshot.get` (with `after: "sync"`, the read barrier that covers every daemon write),
  `debug.focus`, `debug.desync {check: true}`, `debug.tunables {action: list, changed: true}`, `debug.daemon` (the
  app daemon's pid);
- the app's daemon, through the SDK on the socket named by that daemon's own command line: `session.snapshot`,
  `settings.snapshot`.
Steps: action.run (`action.run`, `wait: true`, so the reply comes after the store applied the action's daemon
echoes), key (`debug.key`, one keystroke a turn), resource.call (on the app's daemon), settle (the read barrier
above), snapshot. cli, mcp, tui.key, kill, restart and advance_clock are Crash results here: drivers 048, 209,
234 and the app restart of task 047 own them.

Each case gets its own launch (`session_dirty`): the reset check between cases that would let a launch run a batch
is task 189. The launch is bench_launch.BenchApp (fresh state, the bench environment, animations off through the
app config), and its stop ends the tag's daemons (TagTeardown).

Usage (fleet Mac):
  facets_v0.py capture --product app --tag TAG --sha SHA --out DIR       the oracle run with v0 facets
"""

from __future__ import annotations

import json
import re
import sys
import time
from pathlib import Path
from typing import Any, Callable, Dict, List, Mapping, Optional, Sequence, Tuple

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
SCRIPTS = REPO / "scripts" / "cmux-next"
SDK = REPO / "cmux-tui" / "bindings" / "python"
for _path in (str(HERE), str(SCRIPTS), str(SDK)):
    if _path not in sys.path:
        sys.path.insert(0, _path)

import facets_v0  # noqa: E402 - sibling (p15-oracle-006)

FACETS = (
    "topology", "daemon", "focus", "layout", "sidebar", "tabs", "overlays", "settings", "intents", "windows",
    "history", "notifications", "agents", "terminals", "webviews", "ax", "crashes", "liveObjects",
    "invariants", "switches",
)
# The facets a step that is not a snapshot records: the app state the v0 methods give.
STEP_FACETS = ("topology", "daemon", "focus", "settings", "invariants", "switches")
SELECTORS = {"machine": "current", "session": "current"}
STEP_REF = re.compile(r"^\$step:([a-z0-9][a-z0-9-]{0,63})#((?:/(?:[^~/]|~[01])*)*)$")
MODIFIERS = {"cmd": "cmd", "shift": "shift", "opt": "option", "alt": "option", "ctrl": "control", "fn": "fn"}
OTHER_DRIVERS = {
    "cli": "driver_cli.py (p15-oracle-048)",
    "mcp": "driver_mcp.py (p15-oracle-209)",
    "tui.key": "driver_tui.py (p15-oracle-234)",
    "kill": "the app driver's restart and process steps (p15-oracle-047)",
    "restart": "the app driver's restart and process steps (p15-oracle-047)",
    "advance_clock": "the virtual clock (p15-oracle-185); v0 runs on the wall clock",
}
REQUEST_S = 30.0
# Animations off (CLAUDE.md: code works with no animation; spec 3B default run mode).
APP_CONFIG = {"appearance": {"backgroundOpacity": 1}, "ui": {"animations": {"enabled": False}}}


class CaseError(Exception):
    """Ends the case with `status` (Failure, Crash or Timeout) at `step`."""

    def __init__(self, status: str, message: str, step: Optional[str] = None):
        super().__init__(message)
        self.status = status
        self.message = message
        self.step = step


# ---------------------------------------------------------------------------------------------------------
# Pure helpers (tested on Linux by driver_app_test.py)


def decode_pointer(pointer: str) -> List[str]:
    return [part.replace("~1", "/").replace("~0", "~") for part in pointer.split("/")[1:]] if pointer else []


def resolve_pointer(value: Any, pointer: str) -> Any:
    for part in decode_pointer(pointer):
        if isinstance(value, list) and part.isdigit() and int(part) < len(value):
            value = value[int(part)]
        elif isinstance(value, dict) and part in value:
            value = value[part]
        else:
            raise KeyError(pointer)
    return value


def resolve_refs(value: Any, replies: Mapping[str, Any]) -> Any:
    """`$step:<id>#<pointer>` strings become the value at that pointer of the earlier step's reply."""
    if isinstance(value, str):
        match = STEP_REF.match(value)
        if not match:
            return value
        step, pointer = match.groups()
        if step not in replies:
            raise CaseError("Failure", f"{value}: step {step} has no reply")
        try:
            return resolve_pointer(replies[step], pointer)
        except KeyError:
            raise CaseError("Failure", f"{value}: no value at {pointer} of step {step}") from None
    if isinstance(value, list):
        return [resolve_refs(item, replies) for item in value]
    if isinstance(value, dict):
        return {key: resolve_refs(item, replies) for key, item in value.items()}
    return value


def key_params(keystroke: str) -> Dict[str, Any]:
    """A case keystroke (`cmd+shift+d`) as `debug.key` params at the push base (DebugKey.keyPress)."""
    *mods, key = keystroke.split("+")
    names = {"plus": "+"}
    return {"key": names.get(key, key), "modifiers": [MODIFIERS[m] for m in mods]}


def action_params(step: Mapping[str, Any], replies: Mapping[str, Any]) -> Dict[str, Any]:
    """`action.run` params at the push base (ControlRouter+ActionRun.swift): action, target, args, wait."""
    args = resolve_refs(dict(step.get("args") or {}), replies)
    action = args.pop("action", None)
    if not isinstance(action, str):
        raise CaseError("Failure", "action.run needs args.action", step["id"])
    params: Dict[str, Any] = {"action": action, "wait": True}
    if step.get("target"):
        params["target"] = resolve_refs(dict(step["target"]), replies)
    if args.get("args") is not None:
        params["args"] = args.pop("args")
    if args.get("idempotencyKey"):
        params["idempotency_key"] = args.pop("idempotencyKey")
    if args:
        raise CaseError("Failure", f"action.run: unknown args {sorted(args)}", step["id"])
    return params


def resource_params(step: Mapping[str, Any], replies: Mapping[str, Any]) -> Tuple[str, Dict[str, Any], Optional[str]]:
    """(method, params with selectors, idempotency key) of a resource.call step on the app's daemon. The case's
    named fixture identities `local` and `fixture` are the app's own machine and session."""
    args = resolve_refs(dict(step.get("args") or {}), replies)
    params = dict(SELECTORS)
    for name, handle in resolve_refs(dict(step.get("target") or {}), replies).items():
        params[name] = "current" if (name, handle) in (("machine", "local"), ("session", "fixture")) else handle
    params.update(args.get("params") or {})
    return str(args.get("method")), params, args.get("idempotencyKey")


def check_expect(step: Mapping[str, Any], outcome: str, detail: Any) -> None:
    expect = step.get("expect")
    if not expect:
        return
    if expect.get("outcome") != outcome:
        raise CaseError("Failure", f"expected {expect.get('outcome')}, got {outcome}: {json.dumps(detail)[:300]}",
                        step["id"])
    if outcome == "error" and expect.get("error") and detail != expect["error"]:
        raise CaseError("Failure", f"expected error {expect['error']}, got {detail}", step["id"])


def daemon_endpoint(argv: Sequence[str]) -> Optional[str]:
    """The socket a daemon serves, from its own command line (`--socket PATH`)."""
    words = list(argv)
    return words[words.index("--socket") + 1] if "--socket" in words and words.index("--socket") + 1 < len(words) else None


def wait_holds(wait: Mapping[str, Any], value: Any) -> bool:
    if "equals" in wait:
        return value == wait["equals"]
    predicate = wait.get("predicate")
    if predicate == "exists":
        return value is not None
    if predicate in ("absent", "empty"):
        return value in (None, [], {}, "")
    if predicate == "nonEmpty":
        return value not in (None, [], {}, "")
    if isinstance(predicate, dict):
        op, target = predicate["op"], predicate["value"]
        if op == "lengthEquals":
            return isinstance(value, (list, dict, str)) and len(value) == target
        if op == "contains":
            return isinstance(value, (list, str)) and target in value
        if isinstance(value, (int, float)) and not isinstance(value, bool):
            return {"gt": value > target, "gte": value >= target, "lt": value < target, "lte": value <= target}[op]
    return False


# ---------------------------------------------------------------------------------------------------------
# The app


class App:
    """One launch of the tag's app: its control socket and its daemon's resource connection."""

    def __init__(self, tag: str, out_dir: Path, launcher: Callable[..., Any]):
        self.bench = launcher(tag, out_dir)
        self.conn: Any = None

    def rpc(self, method: str, params: Optional[Mapping[str, Any]] = None, step: str = "") -> Any:
        reply = self.bench.rpc(method, dict(params or {}), timeout=REQUEST_S)
        # bench_launch.rpc_at answers the result, {"error": <ControlError object>} for a refusal, or
        # {"error": <text>, "unreachable": true}. A debug method's own {"error": <text>} value is a result.
        if isinstance(reply, dict) and reply.get("unreachable") is True:
            raise CaseError("Crash", f"{method}: the app's socket does not answer: {reply.get('error')}", step)
        if isinstance(reply, dict) and set(reply) == {"error"} and isinstance(reply["error"], dict):
            raise _ControlRefusal(reply["error"])
        return reply

    def daemon(self, step: str) -> Any:
        """The SDK connection to the app's own daemon (its pid from `debug.daemon`, its socket from its argv)."""
        if self.conn is not None and not self.conn.closed:
            return self.conn
        from cmux._protocol import ProtocolConnection  # the SDK of this checkout
        from tag_teardown import procargs

        pid = self.rpc("debug.daemon", {}, step).get("pid")
        found = procargs(int(pid)) if pid else None
        socket_path = daemon_endpoint(found[0]) if found else None
        if not socket_path:
            raise CaseError("Crash", f"the app's daemon (pid {pid}) names no --socket", step)
        self.conn = ProtocolConnection(socket_path, REQUEST_S)
        return self.conn

    def stop(self) -> None:
        if self.conn is not None:
            self.conn.close()
        self.bench.stop()


class _ControlRefusal(Exception):
    """A typed error reply of the control socket."""


def bench_launcher(tag: str, out_dir: Path) -> Any:
    """BenchApp of the tag's newest bench build (bench-startup's DerivedData lookup), launched."""
    import bench_launch

    startup = bench_launch.load_by_path("bench_startup", str(SCRIPTS / "bench-startup.py"))
    bench = bench_launch.BenchApp(startup.tagged_app(tag, optimized=True), out=str(out_dir), config=APP_CONFIG)
    bench.launch()
    return bench


class CaseRun:
    def __init__(self, app: App, case: Mapping[str, Any], ctx: Mapping[str, Any], session_ctx: Mapping[str, Any]):
        self.app = app
        self.case = case
        self.case_id = ctx.get("case_id") or f"{case.get('suite')}/{case.get('id')}"
        self.sha = facets_v0.resolve_sha(str(session_ctx.get("ref") or "HEAD"))
        self.scale = float(ctx.get("timeout_multiplier") or 1)
        self.v1 = facets_v0.load_v1()
        self.host = facets_v0.host_record()
        self.replies: Dict[str, Any] = {}
        self.captures: List[Tuple[str, str, Dict[str, Any]]] = []

    def run(self) -> Dict[str, Any]:
        status, message, at = "Pass", "", None
        try:
            for index, step in enumerate(self.case.get("steps") or ()):
                self.run_step(index, step)
        except CaseError as error:
            status, message, at = error.status, error.message, error.step
        result: Dict[str, Any] = {"status": status, "message": message, "checkpoints": [], "session_dirty": True}
        if at:
            result["step"] = at
        try:
            values = facets_v0.canonicalize([c[2] for c in self.captures], labels=[f"{c[0]}/{c[1]}" for c in self.captures])
        except Exception as error:  # noqa: BLE001 - normalize refuses the snapshot: the case cannot compare
            result.update(status="Crash", message="; ".join(filter(None, [message, f"snapshot refused: {error}"])))
            return result
        result["checkpoints"] = [{"step": s, "checkpoint": c, "snapshot": v} for (s, c, _), v in zip(self.captures, values)]
        return result

    def run_step(self, index: int, step: Mapping[str, Any]) -> None:
        step_id, op = step["id"], step["op"]
        if op in OTHER_DRIVERS:
            raise CaseError("Crash", f"{op} steps belong to {OTHER_DRIVERS[op]}", step_id)
        facets = tuple((step.get("args") or {}).get("facets") or FACETS) if op == "snapshot" else STEP_FACETS
        checkpoints = step.get("checkpoint") or ["settled"]
        if "turn" in checkpoints:
            raise CaseError("Crash", "a turn checkpoint needs debug.oracle.turns (p15-oracle-030); v0 has none", step_id)
        if "before" in checkpoints:
            self.capture(index, step_id, "before", facets)
        outcome, detail = getattr(self, "op_" + op.replace(".", "_"))(step)
        check_expect(step, outcome, detail)
        if step.get("waitFor"):
            self.wait_for(step)
        if "settled" in checkpoints:
            self.capture(index, step_id, "settled", facets)

    # -- steps

    def op_action_run(self, step: Mapping[str, Any]) -> Tuple[str, Any]:
        try:
            reply = self.app.rpc("action.run", action_params(step, self.replies), step["id"])
        except _ControlRefusal as refusal:
            return "error", _error_code(refusal.args[0])
        self.replies[step["id"]] = reply
        return "ok", reply

    def op_key(self, step: Mapping[str, Any]) -> Tuple[str, Any]:
        target = dict(step.get("target") or {})
        for keystroke in (step.get("args") or {}).get("keys") or ():
            params = key_params(keystroke)
            if target.get("window"):
                params["window"] = resolve_refs(target["window"], self.replies)
            reply = self.app.rpc("debug.key", params, step["id"])
            if isinstance(reply, dict) and reply.get("error"):
                raise CaseError("Failure", f"debug.key {keystroke}: {reply['error']}", step["id"])
        return "ok", {}

    def op_resource_call(self, step: Mapping[str, Any]) -> Tuple[str, Any]:
        from cmux.errors import ResourceError

        method, params, key = resource_params(step, self.replies)
        try:
            reply = self.app.daemon(step["id"]).request(method, params, idempotency_key=key, timeout=REQUEST_S * self.scale)
        except ResourceError as error:
            return "error", error.code
        self.replies[step["id"]] = reply
        return "ok", reply

    def op_settle(self, step: Mapping[str, Any]) -> Tuple[str, Any]:
        self.barrier(step["id"])
        return "ok", {}

    def op_snapshot(self, step: Mapping[str, Any]) -> Tuple[str, Any]:
        return "ok", {}

    # -- snapshots

    def barrier(self, step: str) -> Dict[str, Any]:
        """`snapshot.get` after `sync`: the app answers from the first snapshot that reflects every write the
        daemon committed so far (ControlRouter+Barrier.swift), the push base's settle point."""
        try:
            return self.app.rpc("snapshot.get", {"after": "sync"}, step)
        except _ControlRefusal as refusal:
            raise CaseError("Timeout", f"snapshot.get after sync: {refusal.args[0]}", step) from None

    def replies_for(self, facets: Sequence[str], step: str) -> Dict[str, Any]:
        out: Dict[str, Any] = {}
        for name in facets_v0.methods_for(facets, "app"):
            method = facets_v0.METHODS[name]
            if name == "snapshot.get":
                out[name] = self.barrier(step)
            elif method.product == "app":
                try:
                    out[name] = self.app.rpc(name, method.params, step)
                except _ControlRefusal as refusal:
                    raise CaseError("Crash", f"{name}: {refusal.args[0]}", step) from None
            else:
                out[name] = self.app.daemon(step).request(name, dict(method.params), timeout=REQUEST_S * self.scale)
        return out

    def facets(self, names: Sequence[str], step: str) -> Dict[str, Any]:
        try:
            return facets_v0.build_facets(names, "app", self.replies_for(names, step), self.v1)
        except facets_v0.V0Error as error:
            raise CaseError("Crash", f"v0 facets: {error}", step) from None

    def capture(self, index: int, step: str, checkpoint: str, names: Sequence[str]) -> None:
        snapshot = facets_v0.snapshot(case=self.case_id, step=index, checkpoint=checkpoint, product="app",
                                      sha=self.sha, facets=self.facets(names, step), host=self.host)
        self.captures.append((step, checkpoint, snapshot))

    def wait_for(self, step: Mapping[str, Any]) -> None:
        """waitFor at v0: re-read the facet after each published snapshot (the `after` barrier of the next
        sequence), until the value holds or maxMs passes. No sleeps: each read blocks in the app until a newer
        snapshot is published."""
        wait = step["waitFor"]
        facet = decode_pointer(wait["pointer"])[0]
        deadline = time.monotonic() + wait["maxMs"] / 1000 * self.scale
        sequence = 0
        while True:
            value = self.facets([facet], step["id"])
            try:
                current = resolve_pointer(value, wait["pointer"])
            except KeyError:
                current = None
            if wait_holds(wait, current):
                return
            if time.monotonic() >= deadline:
                raise CaseError("Timeout", f"waitFor {wait['pointer']} did not hold in {wait['maxMs']} ms "
                                           f"(last {json.dumps(current)[:200]})", step["id"])
            sequence = max(sequence, int(self.barrier(step["id"]).get("sequence") or 0)) + 1
            try:
                self.app.rpc("snapshot.get", {"after": sequence}, step["id"])
            except _ControlRefusal:
                continue  # the barrier's own deadline passed with no newer snapshot: read again


def _error_code(error: Any) -> str:
    return str(error.get("code")) if isinstance(error, dict) else str(error)


# ---------------------------------------------------------------------------------------------------------
# The driver protocol


class AppSession:
    """The app product's session: a launch per case (no reset check before task 189)."""

    def __init__(self, session_ctx: Mapping[str, Any], launcher: Callable[..., Any] = bench_launcher):
        if session_ctx.get("facets") != "v0":
            raise ValueError("driver_app.py captures v0 facets only (facets_v0.py capture); v1 facets come from "
                             "debug.oracle.snapshot (p15-oracle-030, p15-oracle-047)")
        if not session_ctx.get("tag"):
            raise ValueError("the app driver needs --tag (the tagged bench build of the run's SHA)")
        if session_ctx.get("switches"):
            raise ValueError("switch arms reach the app in p15-oracle-049; this driver runs the default arms")
        self.session_ctx = dict(session_ctx)
        self.launcher = launcher

    def run_case(self, case: Dict[str, Any], case_ctx: Dict[str, Any]) -> Dict[str, Any]:
        out_dir = Path(str(self.session_ctx.get("out_dir") or "/tmp/oracle")) / "app" / str(case_ctx.get("key") or "case")
        out_dir.mkdir(parents=True, exist_ok=True)
        try:
            app = App(str(self.session_ctx["tag"]), out_dir, self.launcher)
        except SystemExit as error:  # bench_launch.LaunchError: no GUI session, tag in use, no socket
            return {"status": "Crash", "message": f"launch: {error}", "checkpoints": [], "session_dirty": True}
        try:
            return CaseRun(app, case, case_ctx, self.session_ctx).run()
        finally:
            app.stop()

    def close(self) -> None:
        """Nothing outlives a case: each run_case stops its launch and the tag's daemons."""


def open_session(session_ctx: Dict[str, Any]) -> AppSession:
    return AppSession(session_ctx)


if __name__ == "__main__":
    print(__doc__)
