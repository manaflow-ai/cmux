#!/usr/bin/env python3
"""The oracle's app driver: a tagged cmux-next app, launched the bench way, driven over its control socket.

Spec: plans/cmux-next/chrome-parity/p15-oracle.md, sections 3A, 3B, 3D and task 047. Stdlib plus the sibling
oracle modules and scripts/cmux-next/bench_launch.py, Python 3.9+ (fleet minis run the system python3), safe
under `python3 -I`. It implements the driver protocol of oracle.py (`open_session`, `session.run_case`,
`session.close`); a session is one app launch that runs up to --batch-limit cases.

Launch. Through bench_launch's one launch path (`BenchApp`, whose `launch_app` wrapper gives no config file or
teardown): the bench environment (no activation, the automation socket, a mock agent pane, an isolated Chief,
no update check), a fixed window frame on the main display, a fresh saved session for the tag, and the tag's
daemons ended by TagTeardown when the session closes. The app's cmux-next.json is the bench config plus
`ui.animations.enabled: false` (section 3B: code works with no animation; the motion-on suite is a switch arm)
and `mcp.enabled: true` (the `mcp` steps), plus `browser.defaultEngine` when the case pins a browser engine or
the run is an engine arm (oracle.py --engine, the session's `engine`). HOME and CMUX_NEXT_ORACLE_ROOT come from
normalize.app_environment, so the app hashes path text with the prefixes normalize.py rewrites. The build is `--config bench` by default
(oracle.py DEFAULT_BUILD): a session refuses an app whose bundle is another config than the run's `--build`, and
any Release bundle (it has no `debug.oracle.*`). The driver never starts, quits or reads `/Applications/cmux.app`
or a `com.cmuxterm.app` bundle: bench_launch takes only `cmux DEV <tag>.app`, and the session checks again.

Steps: action.run (`action.run`), key (`debug.key`, one request per keystroke, through the app's real key
path, to the focused pane of the step's window, or with `target.overlay` to that open overlay panel, or with
`keyWindow` page to the focused pane's Chromium page window as the key window; Shift alone on a digit or symbol
types its shifted character, as on a US keyboard, so `shift+;` is `:`), cli (the bundle's own `cmux --app-socket`), mcp (`cmux mcp
serve --all-tools` over stdio), settle (`debug.oracle.settle`), snapshot. Any step may carry `waitFor`
(`debug.oracle.wait_for`, resolved from facet change signals; `changed` compares with the value read before the step). Checkpoints: `before`; `turn` for
action.run and key (the turn recorder armed for that step, `debug.oracle.recorder` and `debug.oracle.turns`);
`settled` after `debug.oracle.settle` (the action's reply sequence, else `sync`). No sleeps and no polls: every
wait is one of the app's own barriers, each bounded by the case's ms times the Slow multiplier. `kill` of
target.process daemon signals the tag's cmux-tui owner (its terminal hosts and holders keep running); `restart` of
target.process app is Quit and Keep Sessions, then the same bundle on the same saved session, daemon and config
file (bench_launch `quit_keep_sessions`, then a launch that keeps the state). Either step leaves the session dirty,
so the next case gets a fresh launch. resource.call, the other kill and restart targets, tui.key and advance_clock
belong to other drivers and fail the case as a Crash that names them. So do the conditions a launch cannot apply
yet: environment keys other than viewport and engine, fixture.agent none, fixture.clock virtual, a named fixture handle (no seeding reaches the app) and a key aimed at a pane, tab or page.

Web fixture. A case with `fixture.web` gets its own webfixture.py server (p15-oracle-222) on a loopback port the OS
picks: every `$WEB` of the case is that origin before the first step, the server stops with the case, and its
checkpoints are canonicalized with the origin as normalize.py's `--web`, so no snapshot holds the port.

Expect: `result` is the action's own value (action.run's `result` member, never the run's sequence or ids).
`errorDetails` is a subset of an action.run refusal's `error.data`; a cli, mcp or key reply has no details, so a
check on one is a Crash. An action.run step's `focus: true` is sent as the request's `focus` (the run may change
focus and selection, as a person's would).
`receipt` needs the ActionEffect kind, which no app reply carries yet: the driver checks that an action ran,
marks that step's checkpoints uncertain (never baselined) and says so in the result message.

Switch arms (task 049). The session's `switches` (registry name -> arm, from oracle.py `--switch NAME --arm A` or
`--arm launch-config`) become switches.arm_plan's launch values: CMUX_NEXT_SWITCHES (the env form of
`--cmux-switches=`, since bench_launch starts the app with no arguments) and CMUX_NEXT_TUI_SWITCHES, which
DaemonDiagnosticKnobs hands the app's daemon as CMUX_TUI_SWITCHES (the app's launch strip unsets a raw CMUX_TUI_*
variable). An unknown switch is a session error: nothing launches. Whenever the registry has switches, every launch
reads the app's arms back from the switches facet's `arms`, and every case, before its fixture and steps, reads the
tag daemon's `identify` and `oracle-state` when a daemon switch is registered; every registry switch must read back
its planned arm or its default. A mismatch (another arm, a default that leaked in, no reader in the build for a
requested switch) raises switches.ArmNotApplied out of run_case: oracle.py stops the run with one arm-not-applied
verdict, since every later case and every relaunch would run on the same arms. A run that requests an app switch
reads `debug.oracle.switch_hits` with reset once after each launch (the result's `launch_switch_hits`, so sites that
run only at startup count) and after each case (`switch_hits`: everything since the last read, the case's setup
settle included). The result carries `switch_readback` and both hit maps, which oracle.py writes into the receipt
and diff --switch (task 111) checks.

App pid: the app's pid at the case start must hold to the end (after a restart step, the relaunched app's): a
child crash the case allows never takes the app with it.

Facets: `debug.oracle.snapshot` gives the app's facets (a facet with no provider in the build comes back
not-comparable from the app); the `daemon` facet is read from the tag's own cmux-tui (the `--socket` of its
`--headless` process, found by TagTeardown's bundle-path match) through the Python SDK, with the snapshot
schema's capture rules. Every checkpoint of a case is canonicalized together by normalize.py. An engine arm
(the session's `engine`) canonicalizes without the tabs' engine (normalize.Context.drop ENGINE_DROP), so no pane
order or id label depends on it, and gives each checkpoint the engines its raw tabs showed (`engines`).

Trace (`run-case --trace DIR`, `trace` in the session context): each case result carries its invariants.py trace,
the raw checkpoints plus the side channels of invariants I11-I15 (p15-oracle-217). Per step: `debug.blocking`,
`debug.hangs` (`limit` 1) and `debug.action_budget` (`limit` 1) just before the step acts, the same three once it
settled (hangs `after` the newest record seen before; runs `limit` 64), and `debug.wakeups` at the settle and
again after the settled capture. A case with a turn checkpoint arms the turn recorder, whose reads cost each
action's turn its budget: it reads none of them and the trace says `recorderArmed`. The tag daemon's descriptors,
threads and children (resource_counts.py), with the liveObjects of its daemon facet, after the fixture setup and,
when the case passed, after its fixture teardown, for I15. A refused method is recorded as {"error": ...}: that
invariant is then not checked.

Chrome reference (chromium/src):
- ui/base/interaction/interactive_test.h, chrome/test/interaction/README.md (Kombucha): Action, WaitForState and
  Check verbs; a wait is a StateObserver on the producer's own signal, never a sleep.
- content/public/test/browser_test_utils.h WaitForLoadStop: the checkpoint barrier waits on the page's signal.
- net/test/embedded_test_server/embedded_test_server.h: each browser test starts its own loopback server.
- chrome/test/base/in_process_browser_test.cc: a fresh user-data dir per launch (here: the tag's saved session
  moved aside, a scratch config, a hermetic HOME).

Usage:
  driver_app.py run-case --app "PATH/cmux DEV <tag>.app" CASE.json [--build bench] [--repeat N] [--out DIR]
                         [--trace DIR]
                         [--switch NAME=ARM]...   (each result line carries its switch_readback and switch_hits)
      runs one case N times, each in a fresh launch and session root; prints each result's checkpoint
      hashes; exit 1 when they differ. --trace writes DIR/<attempt>.trace.json for `invariants.py check`
  driver_app.py --selftest       the offline tests (driver_app_test.py)
"""

from __future__ import annotations

import argparse
import importlib
import json
import os
import platform as platform_mod
import re
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass, field, replace
from pathlib import Path
from typing import Any, Callable, Dict, List, Mapping, Optional, Sequence, Tuple

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
SCRIPTS = HERE.parent
SDK = REPO / "cmux-tui" / "bindings" / "python"
FIXTURES = HERE / "action_fixtures"

for _path in (str(HERE), str(SCRIPTS)):
    if _path not in sys.path:
        sys.path.insert(0, _path)

import resource_counts  # noqa: E402 - sibling of this file, invariant I15's daemon reading
import switches  # noqa: E402 - sibling: the switch arms this launch applies and reads back
import webfixture  # noqa: E402 - the sibling loopback server, stdlib only
from invariants import SIDE_CHANNELS, TRACE_SCHEMA  # noqa: E402 - the trace invariants.py checks (I11-I15)

FACETS = ("topology", "daemon", "focus", "layout", "sidebar", "tabs", "overlays", "settings", "intents", "windows",
          "history", "notifications", "agents", "terminals", "webviews", "ax", "crashes", "liveObjects", "invariants",
          "switches")
DAEMON = "daemon"
# The app's control method names (CmuxNextControl OracleControl, OracleSettleControl, OracleRecorderControl).
SNAPSHOT, SETTLE, WAIT_FOR = "debug.oracle.snapshot", "debug.oracle.settle", "debug.oracle.wait_for"
RECORDER, TURNS = "debug.oracle.recorder", "debug.oracle.turns"
# I11-I13's readings per step (sideChannels): the newest hang record and action run before the step are the
# cursors of the after readings, which ask for at most these many of the newer ones (each hang record is
# symbolicated when read).
HANGS_AFTER_LIMIT, RUNS_AFTER_LIMIT = 32, 64
SWITCH_HITS = "debug.oracle.switch_hits"
# The app's reader of its frozen switch arms: the switches facet's `arms`.
APP_ARMS_READER = "snapshot.switches"
# OracleSettleControl.defaultSettleMilliseconds and maxSettleMilliseconds; OracleWaitCondition.maxMilliseconds.
DEFAULT_SETTLE_MS, MAX_SETTLE_MS, MAX_WAIT_MS = 5_000, 300_000, 30_000
REQUEST_S = 30.0
# The router answers a settle or wait 1 s after its bound (OracleSettleControl.replyMargin); this covers the socket.
REPLY_MARGIN_S = 5.0
CLI_S = 60.0
LAUNCH_S = 180.0
WINDOW_ORIGIN = (40, 40)
DEFAULT_VIEWPORT = (1440, 900)
# The cmux-next.json of every oracle launch (bench_env.with_config_defaults adds the bench keys under it).
ORACLE_CONFIG = {"appearance": {"backgroundOpacity": 1}, "ui": {"animations": {"enabled": False}},
                 "mcp": {"enabled": True}}
# `browser.defaultEngine` values (BrowserDefaultEngine), which are also the case-v1 environment.engine names; `none`
# (the case needs no engine) leaves the launch's engine as the run set it (oracle.py --engine) or the app default.
ENGINES = ("webkit", "chromium")
# The tab field an engine arm leaves out before canonicalization (spec 3F.4: the arms compare without it).
ENGINE_DROP = "/facets/tabs/panes/*/tabs/*/engine"
# The user's app (CLAUDE.md: never quit, kill, relaunch, replace or launch it).
USER_APP = "/Applications/cmux.app"
USER_BUNDLE_ID = "com.cmuxterm.app"
# bench_launch.bundle_kind -> the Expectations build modifier it runs as. Release has no debug.oracle.* methods.
BUILD_OF_KIND = {"debug": "debug", "bench-hooks": "bench"}
ACTION_RECEIPTS = ("action.done", "action.applied", "action.waiting")
# ActionEntrypoint values a socket caller may claim as its ControlOrigin (ControlOrigin.headless).
SOCKET_ORIGINS = ("cli", "mcp", "script", "remote")
# case-v1 keystroke modifiers -> debug.key modifiers (DebugKey.keyPress); fn has no debug.key flag.
MODIFIERS = {"cmd": "cmd", "ctrl": "control", "opt": "option", "alt": "option", "shift": "shift"}
# case-v1 key names -> debug.key names (DebugKey.named); function keys are not synthesized by debug.key.
KEY_NAMES = {"plus": "+", "backspace": "delete", "delete": "forwarddelete"}
# The US keyboard's shift layer (DebugKey.shiftedSymbols, inverted): Shift alone on a digit or symbol key types the
# shifted character, as a real keyboard does, so a case types `chrome://` as `shift+;` (case-v1 keystrokes have no
# `:`). debug.key sends the character with the base key's code and Shift.
SHIFTED = dict(zip("`1234567890-=[]\\;',./", "~!@#$%^&*()_+{}|:\"<>?"))
# case-v1 target.overlay -> the debug.key target of that panel (DebugKey.send: the palette's visible panel).
OVERLAY_KEY_TARGETS = {"palette": "palette"}
# case-v1 keyArgs.keyWindow -> debug.key `target` (DebugKey.send): the window made key for the keystrokes. Without
# one (or target.overlay), debug.key sends to the shell window, whose first responder (a terminal) never reaches a
# Chromium page such as the agent chat.
KEY_WINDOWS = {"page": "page"}
# Target kinds that route a step and name no object (never a fixture handle).
ROUTING_TARGETS = ("process", "overlay")
# The kill and restart steps this driver runs itself: op -> the target.process it takes.
APP_PROCESS_STEPS = {"kill": "daemon", "restart": "app"}
# case-v1 argsKill signals.
SIGNALS = {"KILL": signal.SIGKILL, "TERM": signal.SIGTERM, "ABRT": signal.SIGABRT, "SEGV": signal.SIGSEGV}
QUIT_S = 30.0
OTHER_DRIVERS = {
    "resource.call": "driver_daemon.py (p15-oracle-023)",
    "kill": "driver_daemon.py (p15-oracle-023); app child kills other than the daemon are p15-oracle-188",
    "restart": "driver_daemon.py (p15-oracle-023)",
    "advance_clock": "driver_daemon.py (p15-oracle-185)",
    "tui.key": "driver_tui.py (p15-oracle-234)",
}
STEP_REF = re.compile(r"^\$step:([a-z0-9][a-z0-9-]{0,63})#((?:/(?:[^~/]|~[01])*)*)$")
ERROR_CODE = re.compile(r"^[a-z][a-z_]*(\.[a-z][a-z_]*)+$")
SELECTORS = {"machine": "current", "session": "current"}
CURRENT = "current"
# The tasks that bring a case condition to the app launch.
SEED_TASK = "p15-oracle-180 (CMUX_NEXT_ORACLE_SEED) and p15-oracle-185 (seeded ids)"
AGENT_TASK = "p15-oracle-200 (hermetic per-case env)"
CLOCK_TASK = "p15-oracle-185 (virtual clock)"
ORACLE_STATE_KEYS = ("switches", "terminalAttach", "liveObjects", "panicLog")
MISSING = object()


class CaseError(Exception):
    """Ends a case with `status` (Failure, Crash or Timeout) at `step`."""

    def __init__(self, status: str, message: str, step: Optional[str] = None):
        super().__init__(message)
        self.status = status
        self.message = message
        self.step = step


class AppLaunchFailed(Exception):
    """bench_launch could not start the app; `reason` is its LaunchError reason."""

    def __init__(self, reason: str, detail: str):
        super().__init__(f"{reason}: {detail}")
        self.reason = reason


class AppGone(Exception):
    """The app's control socket stopped answering (the app exited or crashed)."""


@dataclass(frozen=True)
class LaunchSpec:
    """What one launch fixes for every case it runs: the window frame (x, y, width, height) and the browser engine
    new tabs and cmux pages use (an ENGINES value; None keeps the app's default)."""

    window: Tuple[int, int, int, int]
    engine: Optional[str] = None


def launch_config(spec: LaunchSpec) -> Dict[str, Any]:
    """The cmux-next.json of a launch: ORACLE_CONFIG, plus browser.defaultEngine when the launch sets one."""
    config = json.loads(json.dumps(ORACLE_CONFIG))
    if spec.engine is not None:
        config["browser"] = {"defaultEngine": spec.engine}
    return config


@dataclass(frozen=True)
class OraclePaths:
    """The session's hermetic prefixes: the root normalize.py rewrites to $ROOT (with its realpath alias) and
    the HOME it rewrites to $HOME; for a case with fixture.web, its loopback origin, rewritten to $WEB."""

    root: Path
    web: Tuple[str, ...] = ()

    @property
    def home(self) -> Path:
        return self.root / "h"

    @property
    def roots(self) -> Tuple[str, ...]:
        return tuple(dict.fromkeys([str(self.root), os.path.realpath(self.root)]))

    def control_paths(self) -> Dict[str, List[str]]:
        """The `paths` param of debug.oracle.snapshot, wait_for and an arming recorder. The web origin is not
        one: the app hashes no URL, and normalize.py rewrites the `url` fields after the capture."""
        return {"root": list(self.roots), "home": [str(self.home)]}


# ---------------------------------------------------------------------------------------------------------
# Pure helpers


def check_not_user_app(app: str, bundle_id: Optional[str]) -> None:
    """Refuses the user's running cmux: its bundle path, or any bundle that claims its id."""
    real = os.path.realpath(app).rstrip("/")
    if real == USER_APP or real.startswith(USER_APP + "/") or bundle_id == USER_BUNDLE_ID:
        raise ValueError(f"driver_app never launches the user's cmux ({real}, {bundle_id}); pass a tagged "
                         "`cmux DEV <tag>.app`")


def run_build(kind: str, requested: str) -> str:
    """The Expectations build modifier an app bundle of `kind` runs as; refuses a bundle the run did not ask for."""
    build = BUILD_OF_KIND.get(kind)
    if build is None:
        raise ValueError(f"the app is a {kind} bundle: it has no debug.oracle.* methods; build it with "
                         "`--config bench` (default) or `--config debug`")
    if build != requested:
        raise ValueError(f"the run asks for --build {requested}, but the app is a {build} build; build it with "
                         f"`--config {requested}` or pass --build {build}")
    return build


def launch_spec(case: Mapping[str, Any], engine: Optional[str] = None) -> LaunchSpec:
    """The launch a case needs; `engine` is the run's (oracle.py --engine), which a case's own engine overrides.
    The conditions a launch cannot apply yet fail the case, never pass it."""
    env = case.get("environment") or {}
    unsupported = sorted(k for k in env if k not in ("viewport", "engine"))
    if unsupported:
        raise CaseError("Crash", f"driver_app launches with no {', '.join(unsupported)} (environment); only "
                                 "viewport and engine are applied")
    check_conditions(case)
    width, height = DEFAULT_VIEWPORT
    if "viewport" in env:
        width, height = int(env["viewport"]["width"]), int(env["viewport"]["height"])
    pinned = env.get("engine")
    return LaunchSpec(window=(*WINDOW_ORIGIN, width, height), engine=pinned if pinned in ENGINES else engine)


def other_driver(op: str, process: Optional[str] = None) -> str:
    what = f"op {op} of target.process {process}" if op in APP_PROCESS_STEPS else f"op {op}"
    return f"{what} is not an app-driver step; it runs in {OTHER_DRIVERS.get(op, 'no driver')}"


def runs_here(step: Mapping[str, Any]) -> bool:
    """Whether this driver runs `step`: an op of its own, or a kill or restart of the process it owns."""
    op = step.get("op")
    if op in APP_PROCESS_STEPS:
        return (step.get("target") or {}).get("process") == APP_PROCESS_STEPS[op]
    return op not in OTHER_DRIVERS


def check_conditions(case: Mapping[str, Any]) -> None:
    """Refuses, before any launch, the steps of other drivers and the fixture conditions the bench launch does
    not apply: it always has the mock agent pane (bench_env CMUX_NEXT_AGENT_PANE_MOCK=1), the wall clock, and
    no seeded fixture identities."""
    fixture = case.get("fixture") or {}
    if fixture.get("agent", "mock") != "mock":
        raise CaseError("Crash", f"fixture.agent {fixture['agent']}: the bench launch always has the mock agent "
                                 f"pane; a launch without it is {AGENT_TASK}")
    if fixture.get("clock") == "virtual":
        raise CaseError("Crash", f"fixture.clock virtual: the app runs on the wall clock; the virtual clock is "
                                 f"{CLOCK_TASK}")
    for step in case.get("steps") or ():
        if not runs_here(step):
            raise CaseError("Crash", other_driver(step["op"], (step.get("target") or {}).get("process")),
                            step.get("id"))
        overlay = (step.get("target") or {}).get("overlay")
        if overlay is not None and (step.get("op") != "key" or overlay not in OVERLAY_KEY_TARGETS):
            raise CaseError("Crash", f"target.overlay {overlay!r} routes keys only: a key step to one of "
                                     f"{', '.join(sorted(OVERLAY_KEY_TARGETS))}", step.get("id"))
        for kind, value in (step.get("target") or {}).items():
            if kind not in ROUTING_TARGETS and isinstance(value, str) and value != CURRENT and not STEP_REF.match(value):
                raise CaseError("Crash", f"target.{kind} {value!r} is a named fixture identity, and no seeding "
                                         f"reaches the app yet ({SEED_TASK}); target `current` or a $step: value",
                                step.get("id"))


def decode_pointer(pointer: str) -> List[str]:
    if pointer == "":
        return []
    if not pointer.startswith("/"):
        raise ValueError(f"JSON pointer {pointer!r} does not start with /")
    return [part.replace("~1", "/").replace("~0", "~") for part in pointer[1:].split("/")]


def resolve_pointer(value: Any, pointer: str) -> Any:
    """The value at `pointer` (RFC 6901), or MISSING."""
    for part in decode_pointer(pointer):
        if isinstance(value, dict) and part in value:
            value = value[part]
        elif isinstance(value, list) and part.isdigit() and (part == "0" or not part.startswith("0")) \
                and int(part) < len(value):
            value = value[int(part)]
        else:
            return MISSING
    return value


def resolve_refs(value: Any, replies: Mapping[str, Any]) -> Any:
    """Substitutes `$step:<id>#<pointer>` strings with the value from that earlier step's reply."""
    if isinstance(value, str):
        match = STEP_REF.match(value)
        if not match:
            return value
        step, pointer = match.groups()
        if step not in replies:
            raise CaseError("Crash", f"{value}: step {step} has no reply")
        found = resolve_pointer(replies[step], pointer)
        if found is MISSING:
            raise CaseError("Failure", f"{value}: the reply of {step} has nothing at {pointer}")
        return found
    if isinstance(value, list):
        return [resolve_refs(item, replies) for item in value]
    if isinstance(value, dict):
        return {key: resolve_refs(item, replies) for key, item in value.items()}
    return value


def debug_key(stroke: str, step: str) -> Dict[str, Any]:
    """A case-v1 keystroke (`cmd+shift+d`) as debug.key params."""
    *mods, key = stroke.split("+")
    unknown = [m for m in mods if m not in MODIFIERS]
    if unknown:
        raise CaseError("Crash", f"debug.key has no {'+'.join(unknown)} modifier ({stroke})", step)
    if re.fullmatch(r"f[0-9]+", key):
        raise CaseError("Crash", f"debug.key does not synthesize function keys ({stroke})", step)
    modifiers = list(dict.fromkeys(MODIFIERS[m] for m in mods))
    if modifiers == ["shift"] and key in SHIFTED:
        return {"key": SHIFTED[key], "modifiers": []}
    return {"key": KEY_NAMES.get(key, key), "modifiers": modifiers}


def action_target(target: Mapping[str, Any], step: str) -> Optional[str]:
    """step.target as action.run's `kind:id`; `current` is the focused object (no target)."""
    named = {k: v for k, v in target.items() if k not in ROUTING_TARGETS}
    if not named:
        return None
    if len(named) > 1:
        raise CaseError("Crash", f"action.run takes one target, the step names {', '.join(sorted(named))}", step)
    (kind, value), = named.items()
    if not isinstance(value, str):
        raise CaseError("Crash", f"target.{kind} is {value!r}, not a string", step)
    return None if value == CURRENT else f"{kind}:{value}"


def typed_error(namespace: str, error: Any) -> str:
    """A reply's error as case-v1's typed code (`area.code`): a dotted code as is, a bare one under `namespace`
    (the app's `invalid_params` is `control.invalid_params`), anything else `<namespace>.failed`."""
    code = error.get("code") if isinstance(error, dict) else None
    if isinstance(code, str) and ERROR_CODE.match(code):
        return code
    if isinstance(code, str) and re.fullmatch(r"[a-z][a-z_]*", code):
        return f"{namespace}.{code}"
    return f"{namespace}.failed"


def arms_recorder(case: Mapping[str, Any]) -> bool:
    """Whether a step of the case asks for a turn checkpoint, which arms debug.oracle.recorder."""
    return any(isinstance(step, Mapping) and "turn" in (step.get("checkpoint") or ())
               for step in case.get("steps") or ())


def newest(reading: Any, member: str) -> int:
    """The highest `sequence` of a side-channel reading's `member` list (0: none, or a refused reading)."""
    rows = reading.get(member) if isinstance(reading, Mapping) else None
    return max((int(row["sequence"]) for row in rows or () if isinstance(row, Mapping)
                and isinstance(row.get("sequence"), int)), default=0)


def app_trace(case_id: str, steps: Sequence[Any], captures: Sequence["Capture"],
              side: Mapping[str, Mapping[str, Any]],
              resources: Tuple[Optional[Dict[str, Any]], Optional[Dict[str, Any]]],
              recorder_armed: bool) -> Optional[Dict[str, Any]]:
    """The case's `cmux.oracle.trace/v1` document (invariants.py): each reached step's raw checkpoints (the last
    turn of a step that ran several) and sideChannels, the tag daemon's counts after setup and at teardown, and
    whether the case armed the turn recorder. None when no step captured or read anything."""
    checkpoints: Dict[str, Dict[str, Any]] = {}
    for capture in captures:
        checkpoints.setdefault(capture.step, {})[capture.checkpoint] = capture.snapshot
    records = []
    for step in steps:
        step_id = step.get("id") if isinstance(step, Mapping) else None
        if step_id not in checkpoints and step_id not in side:
            continue
        record: Dict[str, Any] = {"id": step_id, "op": step["op"], "checkpoints": checkpoints.get(step_id, {})}
        if step_id in side:
            record["sideChannels"] = side[step_id]
        records.append(record)
    if not records:
        return None
    trace: Dict[str, Any] = {"schema": TRACE_SCHEMA, "case": case_id, "steps": records}
    if recorder_armed:
        trace["recorderArmed"] = True
    setup, teardown = resources
    if setup is not None:
        trace["setup"] = {"daemonResources": setup}
    if teardown is not None:
        trace["teardown"] = {"daemonResources": teardown}
    return trace


def not_comparable(reason: str, task: Optional[str] = None) -> Dict[str, str]:
    out = {"status": "not-comparable", "reason": reason}
    if task:
        out["task"] = task
    return out


def host_meta() -> Dict[str, str]:
    if sys.platform == "darwin":
        try:
            model = subprocess.run(["/usr/sbin/sysctl", "-n", "hw.model"], capture_output=True, text=True,
                                   timeout=10).stdout.strip()
        except (OSError, subprocess.TimeoutExpired):
            model = ""
        return {"os": f"macOS {platform_mod.mac_ver()[0]}", "arch": platform_mod.machine(), "model": model or "unknown"}
    return {"os": f"{platform_mod.system()} {platform_mod.release()}", "arch": platform_mod.machine(),
            "model": "unknown"}


def control_request(path: str, method: str, params: Mapping[str, Any], timeout: float) -> Dict[str, Any]:
    """One newline-JSON request on the app's control socket; the whole reply (`ok`, `result` or `error`).
    Raises AppGone when nothing answers, socket.timeout when the answer is late."""
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
            conn.settimeout(timeout)
            conn.connect(path)
            conn.sendall((json.dumps({"id": 1, "method": method, "params": dict(params)}) + "\n").encode())
            buf = b""
            while not buf.endswith(b"\n"):
                chunk = conn.recv(1 << 22)
                if not chunk:
                    break
                buf += chunk
    except socket.timeout:
        raise
    except OSError as error:
        raise AppGone(f"{method}: {error}") from None
    try:
        reply = json.loads(buf)
    except ValueError:
        raise AppGone(f"{method}: the app closed the connection without a reply") from None
    if not isinstance(reply, dict):
        raise AppGone(f"{method}: the reply is not an object")
    return reply


# ---------------------------------------------------------------------------------------------------------
# The app, behind one seam (tests pass a fake)


class BenchAppPort:
    """The app as the driver uses it, over bench_launch.BenchApp (the one launch path) and its TagTeardown."""

    def __init__(self, app: str, out: Path, env: Mapping[str, str]):
        from bench_launch import BenchApp  # noqa: E402 - scripts/cmux-next/bench_launch.py

        self._make = lambda spec: BenchApp(app, out=str(out), env=dict(env), config=launch_config(spec),
                                           window=spec.window, screen="0", log_name="app.log")
        self.bench = None

    def launch(self, spec: LaunchSpec) -> None:
        from bench_launch import LaunchError

        self.bench = self._make(spec)
        try:
            self.bench.launch(timeout=LAUNCH_S)
        except LaunchError as error:  # a SystemExit: never let it end oracle.py
            raise AppLaunchFailed(error.reason, str(error)[:600]) from None
        self.bench.teardown.remember()

    def request(self, method: str, params: Mapping[str, Any], timeout: float) -> Dict[str, Any]:
        return control_request(self.bench.socket, method, params, timeout)

    def alive(self) -> bool:
        return self.bench is not None and self.bench.process is not None and self.bench.process.poll() is None

    @property
    def pid(self) -> Optional[int]:
        return self.bench.process.pid if self.bench is not None and self.bench.process is not None else None

    @property
    def socket_path(self) -> str:
        return self.bench.socket

    @property
    def cli_path(self) -> str:
        return self.bench.cli

    def cli_env(self) -> Dict[str, str]:
        """The launch's environment for the bundle's CLI: its HOME and config file, and no other CMUX variable
        (a terminal's CMUX_SOCKET_PATH would send the CLI to another app)."""
        env = {k: v for k, v in (self.bench.launched_env or {}).items() if not k.startswith("CMUX")}
        env["CMUX_NEXT_CONFIG_FILE"] = self.bench.launched_env["CMUX_NEXT_CONFIG_FILE"]
        return env

    def daemon_owner_pid(self) -> Optional[int]:
        """The pid of the tag's cmux-tui owner (invariant I15 reads its counts)."""
        found = self.daemon_process()
        return int(found[0]) if found else None

    def daemon_process(self) -> Optional[Tuple[int, List[str]]]:
        """The pid and argv of the tag's cmux-tui owner, `cmux-tui --headless` (TagTeardown matches it by bundle
        path); its terminal hosts and holders are other processes."""
        tui = os.path.join(self.bench.teardown.bin, "cmux-tui")
        for pid, command in self.bench.teardown.processes():
            if command.startswith(tui + " --headless"):
                return pid, command.split()
        return None

    def daemon_socket(self) -> Optional[str]:
        """The `--socket` of the tag's cmux-tui owner."""
        found = self.daemon_process()
        if found is None or "--socket" not in found[1]:
            return None
        words = found[1]
        index = words.index("--socket")
        return words[index + 1] if index + 1 < len(words) else None

    def signal_daemon(self, signum: int) -> Optional[int]:
        """Sends `signum` to the tag's cmux-tui owner; its pid, or None when none runs."""
        found = self.daemon_process()
        if found is None:
            return None
        os.kill(found[0], signum)
        return found[0]

    def relaunch(self) -> None:
        """Quit and Keep Sessions, then the same bundle on the same saved session, daemon and config file. BenchApp
        writes its `config` at each launch, so the file the app wrote (a toggled setting) is read back first."""
        from bench_launch import LaunchError

        quit_reply = self.bench.quit_keep_sessions(timeout=QUIT_S)
        if not quit_reply["quit"]:
            raise AppLaunchFailed("quit-keep-sessions", quit_reply["error"][:600])
        config_file = self.bench.launched_env["CMUX_NEXT_CONFIG_FILE"]
        try:
            self.bench.config = json.loads(Path(config_file).read_text(encoding="utf-8"))
        except (OSError, ValueError) as error:
            raise AppLaunchFailed("config-unreadable", f"{config_file}: {error}") from None
        self.bench.fresh_state = False
        try:
            self.bench.launch(timeout=LAUNCH_S)
        except LaunchError as error:  # a SystemExit: never let it end oracle.py
            raise AppLaunchFailed(error.reason, str(error)[:600]) from None
        self.bench.teardown.remember()

    def stop(self) -> None:
        if self.bench is not None:
            self.bench.stop()
            self.bench = None


def add_hits(total: Optional[Mapping[str, Mapping[str, int]]],
             more: Mapping[str, Mapping[str, int]]) -> Dict[str, Dict[str, int]]:
    """Two hit maps (registry name -> {arm: N}) summed."""
    out = {name: dict(arms) for name, arms in (total or {}).items()}
    for name, arms in more.items():
        for arm, count in arms.items():
            out.setdefault(name, {})[arm] = out.get(name, {}).get(arm, 0) + count
    return out


def read_daemon_arm_sources(socket_path: str, timeout: float = REQUEST_S) -> Dict[str, Any]:
    """The switch readers of the app's daemon (`identify`, `oracle-state`), read the way driver_daemon.py reads them."""
    import driver_daemon

    with driver_daemon.SdkReads(socket_path, timeout) as reads:
        return driver_daemon.daemon_arm_sources(reads)


def read_daemon_facet(socket_path: str, schema_doc: Mapping[str, Any], timeout: float = REQUEST_S) -> Dict[str, Any]:
    """The app daemon's `daemon` facet: session.snapshot + settings.snapshot (+ the oracle-state extras of a debug
    or `--features oracle` daemon) through the Python SDK, with the schema's capture rules."""
    if str(SDK) not in sys.path:
        sys.path.insert(0, str(SDK))
    import check_snapshot_schema
    from cmux._protocol import ProtocolConnection
    from cmux.raw import CmuxClient

    node = schema_doc["properties"]["facets"]["properties"]["daemon"]["oneOf"][0]["properties"]
    raw = CmuxClient(socket_path, timeout=timeout)
    resource = ProtocolConnection(socket_path, timeout)
    try:
        extras = raw.request("oracle-state")
        unknown = "unknown variant `oracle-state`" in str(extras.get("error") or "")
        if extras.get("ok") is not True and not unknown:
            raise RuntimeError(f"oracle-state refused: {extras.get('error')!r}")
        if extras.get("ok") is True and isinstance(extras.get("data"), dict):
            data = extras["data"]
            session = data["session"]
            facet: Dict[str, Any] = {"journalHead": data["journal_head"],
                                     "oracle": {key: data[key] for key in ORACLE_STATE_KEYS if key in data}}
        else:
            session = resource.request("session.snapshot", SELECTORS)
            facet = {}
        facet["session"] = check_snapshot_schema.capture(schema_doc, node["session"], session)
        facet["settings"] = check_snapshot_schema.capture(schema_doc, node["settings"],
                                                          resource.request("settings.snapshot", SELECTORS))
        return facet
    finally:
        raw.close()
        resource.close()


# ---------------------------------------------------------------------------------------------------------
# One case


@dataclass
class Capture:
    index: int
    step: str
    checkpoint: str
    snapshot: Dict[str, Any]


@dataclass
class CaseState:
    replies: Dict[str, Any] = field(default_factory=dict)
    captures: List[Capture] = field(default_factory=list)


class CaseRun:
    """One case on a launched app: fixture setup, the steps, and the case's fixture teardown."""

    def __init__(self, session: "AppSession", case: Mapping[str, Any], ctx: Mapping[str, Any]):
        self.session = session
        self.app = session.app
        self.case = case
        self.case_id = ctx.get("case_id") or f"{case.get('suite')}/{case.get('id')}"
        self.scale = float(ctx.get("timeout_multiplier") or 1)
        self.state = CaseState()
        self.switch_readback: Dict[str, str] = {}
        # Switch hits read before an app restart step (op_restart), added to the case's teardown read.
        self.restart_hits: Optional[Dict[str, Dict[str, int]]] = None
        # The step running now (a Crash from an unexpected error names it), the steps whose expected receipt
        # kind the app could not report, and whether the app was left in a state the next case must not inherit.
        self.at: Optional[str] = None
        self.unchecked_receipts: Dict[str, str] = {}
        self.dirty = False
        # A traced run (`trace` in the session context, `run-case --trace`) writes the case's invariants.py trace:
        # each step's sideChannels (I11-I14; none for a case that arms the turn recorder, whose turn reads cost
        # each action's turn its budget) and the tag daemon's counts after setup and at teardown (I15).
        self.trace = session.trace
        self.recorder_armed = arms_recorder(case)
        self.perf = self.trace and not self.recorder_armed
        self.side: Dict[str, Dict[str, Dict[str, Any]]] = {}
        self.resources: List[Optional[Dict[str, Any]]] = [None, None]
        # The app's process at the case start: a child crash (allow_crashes) must leave it running (CrashTab's
        # contract, content/public/test/browser_test_utils.h), so a new pid fails the case like an exit does.
        self.pid: Optional[int] = None
        self.ops: Dict[str, Callable[[int, Mapping[str, Any]], Tuple[Tuple[str, Any], Any]]] = {
            "action.run": self.op_action_run,
            "key": self.op_key,
            "cli": self.op_cli,
            "mcp": self.op_mcp,
            "settle": self.op_settle,
            "snapshot": self.op_snapshot,
            "kill": self.op_kill,
            "restart": self.op_restart,
        }

    # -- control calls

    def call(self, method: str, params: Mapping[str, Any], step: str, timeout: Optional[float] = None) -> Dict[str, Any]:
        """One control request; `timeout` (s) is a barrier's own bound, else REQUEST_S times the Slow multiplier."""
        timeout = REQUEST_S * self.scale if timeout is None else timeout
        try:
            return self.app.request(method, params, timeout)
        except socket.timeout:
            raise CaseError("Timeout", f"{method} gave no answer in {timeout:.0f} s", step) from None
        except AppGone as error:
            raise CaseError("Crash", f"the app stopped answering: {error}", step) from None

    def result(self, method: str, params: Mapping[str, Any], step: str, timeout: Optional[float] = None) -> Any:
        """A method that must succeed: its result, else a Crash naming the control error."""
        reply = self.call(method, params, step, timeout)
        if reply.get("ok") is not True:
            raise CaseError("Crash", f"{method} refused: {json.dumps(reply.get('error'))[:400]}", step)
        return reply.get("result")

    # -- the run

    def run(self) -> Dict[str, Any]:
        status, message, at = "Pass", "", None
        teardown = None
        web = None
        origins: Tuple[str, ...] = ()
        try:
            fixture = self.case.get("fixture") or {}
            self.at = "setup"
            if fixture.get("web"):
                web = self.session.web_fixture()
                origins = (self.start_web(web),)
                self.case = web.expand(self.case)
            self.pid = self.app.pid
            self.settle("sync", DEFAULT_SETTLE_MS, "setup")
            # Raises switches.ArmNotApplied, which ends the run (oracle.py), not just this case.
            self.switch_readback = self.session.verify_arms()
            teardown = self.setup_fixture(fixture.get("setup"))
            if self.trace:
                self.resources[0] = self.session.daemon_resources()
            for index, step in enumerate(self.case.get("steps") or ()):
                self.at = step.get("id") if isinstance(step, Mapping) else None
                self.run_step(index, step)
        except CaseError as error:
            status, message, at = error.status, error.message, error.step
        except switches.ArmNotApplied:
            raise
        except Exception as error:  # noqa: BLE001 - a malformed step or a driver bug is this case's Crash
            status, message, at = "Crash", f"driver: {error!r}", self.at
        finally:
            if teardown is not None:
                try:
                    teardown(self.rpc)
                except Exception as error:  # noqa: BLE001 - a fixture teardown failure fails the case
                    status = "Crash"
                    message = "; ".join(filter(None, [message, f"fixture teardown: {error!r}"]))
            if self.trace and status == "Pass":
                self.resources[1] = self.session.daemon_resources()
            if web is not None:
                web.stop()
        hits = None
        if self.session.counts_hits and self.app.alive():
            try:
                hits = self.switch_hits("teardown")
            except CaseError as error:
                status, message = "Crash", "; ".join(filter(None, [message, error.message]))
        if self.restart_hits is not None:
            hits = add_hits(self.restart_hits, hits or {})
        result: Dict[str, Any] = {"status": status, "message": message, "checkpoints": []}
        if at:
            result["step"] = at
        if self.switch_readback:
            result["switch_readback"] = dict(self.switch_readback)
        if hits is not None:
            result["switch_hits"] = hits
        if status in ("Crash", "Timeout") or self.dirty or not self.app.alive():
            # A crash or a stuck barrier leaves state the next case must not inherit (task 189 adds the reset check).
            result["session_dirty"] = True
        if self.unchecked_receipts:
            notes = ", ".join(f"{step} {kind}" for step, kind in self.unchecked_receipts.items())
            result["message"] = "; ".join(filter(None, [message, f"receipt kind not compared (the app reply has no "
                                                                 f"ActionEffect kind): {notes}"]))
        try:
            result["checkpoints"] = self.session.canonical(self.case_id, self.state.captures, web=origins)
        except Exception as error:  # noqa: BLE001 - a snapshot normalize refuses is this case's Crash
            result.update(status="Crash", message="; ".join(filter(None, [message, f"snapshot refused: {error}"])))
        for checkpoint in result["checkpoints"]:
            if checkpoint["step"] in self.unchecked_receipts:
                checkpoint["uncertain"] = True
        if self.trace:
            result["trace"] = app_trace(self.case_id, self.case.get("steps") or (), self.state.captures, self.side,
                                        (self.resources[0], self.resources[1]), self.recorder_armed)
        return result

    def switch_hits(self, step: str) -> Optional[Dict[str, Dict[str, int]]]:
        try:
            return self.session.hit_counts(step)
        except socket.timeout:
            raise CaseError("Timeout", f"{SWITCH_HITS} gave no answer in {REQUEST_S:.0f} s", step) from None
        except AppGone as error:
            raise CaseError("Crash", f"the app stopped answering: {error}", step) from None

    @staticmethod
    def start_web(web: Any) -> str:
        """Starts the case's web fixture; its origin."""
        try:
            return web.start()
        except webfixture.FixtureError as error:
            raise CaseError("Crash", f"web fixture: {error}", "setup") from None

    def rpc(self, method: str, params: Optional[Mapping[str, Any]] = None) -> Any:
        """The fixtures' control call: the result, or the error object as {"error": ...}."""
        reply = self.call(method, params or {}, "fixture")
        return reply.get("result") if reply.get("ok") is True else {"error": reply.get("error")}

    def setup_fixture(self, family: Optional[str]) -> Optional[Callable[[Callable[..., Any]], Any]]:
        """Runs oracle/action_fixtures/<family>.py's `setup(rpc)` (p15-oracle-046's per-family fixtures) and
        returns its `teardown(rpc)`, if any."""
        if not family:
            return None
        if not (FIXTURES / f"{family}.py").is_file():
            raise CaseError("Crash", f"fixture.setup {family}: no oracle/action_fixtures/{family}.py (p15-oracle-046)")
        try:
            module = importlib.import_module(f"action_fixtures.{family}")
            module.setup(self.rpc)
        except CaseError:
            raise
        except Exception as error:  # noqa: BLE001 - a fixture failure is this case's Crash
            raise CaseError("Crash", f"fixture {family} setup: {error!r}", "setup") from None
        return getattr(module, "teardown", None)

    def run_step(self, index: int, step: Mapping[str, Any]) -> None:
        step_id = step["id"]
        op = step["op"]
        handler = self.ops.get(op)
        if handler is None:
            raise CaseError("Crash", other_driver(op), step_id)
        self.check_alive(step_id)
        checkpoints = step.get("checkpoint") or ["settled"]
        facets = tuple((step.get("args") or {}).get("facets") or FACETS) if op == "snapshot" else FACETS
        if "before" in checkpoints:
            self.capture(index, step_id, "before", facets)
        wait = step.get("waitFor")
        since = self.wait_baseline(wait, step_id) if wait else None
        if self.perf:
            self.read_side_channels(step_id, "before")
        armed = self.arm(facets, step_id) if "turn" in checkpoints else None
        try:
            outcome, sequence = handler(index, step)
            self.check_expect(step, outcome)
            if armed is not None:
                self.record_turns(index, step_id, facets, armed)
        except Exception as error:
            if armed is not None:
                self.disarm_after(error, step_id)
            raise
        if armed is not None:
            self.result(RECORDER, {"arm": False, "clear": True}, step_id)
        if wait:
            self.wait_for(wait, since, step_id)
        if "settled" in checkpoints:
            if op != "settle":
                self.settle(sequence, step.get("settleMaxMs") or DEFAULT_SETTLE_MS, step_id)
            if self.perf:
                self.read_side_channels(step_id, "after")
                self.read_side(step_id, "wakeups", "settled", {})
            self.capture(index, step_id, "settled", facets)
            if self.perf:
                self.read_side(step_id, "wakeups", "idle", {})
        elif self.perf:
            self.read_side_channels(step_id, "after")

    def disarm_after(self, error: Exception, step: str) -> None:
        """Disarms the recorder after a step failed, keeping that failure as the case's result. After a Crash,
        Timeout or driver error the session is relaunched anyway, so a hung app gets no second wait."""
        if not (isinstance(error, CaseError) and error.status == "Failure") or not self.app.alive():
            self.dirty = True
            return
        try:
            self.result(RECORDER, {"arm": False, "clear": True}, step)
        except CaseError:
            self.dirty = True

    def check_alive(self, step: str) -> None:
        if not self.app.alive():
            raise CaseError("Crash", "the app exited during the case", step)
        if self.pid is not None and self.app.pid != self.pid:
            raise CaseError("Crash", f"the app process changed during the case (pid {self.pid}, now {self.app.pid})",
                            step)

    # -- side channels (I11-I14)

    def read_side(self, step: str, key: str, name: str, params: Mapping[str, Any]) -> Dict[str, Any]:
        """One reading of `key`'s debug method into the step's sideChannels: its result, or {"error": ...} when
        the build refuses it (invariants.py then does not check that invariant)."""
        reply = self.call(SIDE_CHANNELS[key], params, step)
        value = reply.get("result") if reply.get("ok") is True else {"error": reply.get("error")}
        reading = value if isinstance(value, dict) else {"error": {"code": "not_an_object", "value": value}}
        self.side.setdefault(step, {}).setdefault(key, {})[name] = reading
        return reading

    def read_side_channels(self, step: str, name: str) -> None:
        """debug.blocking, debug.hangs and debug.action_budget `before` the step acts or `after` it (once it
        settled). The after readings of hangs and runs start from the newest the before reading named."""
        earlier = self.side.get(step, {})
        self.read_side(step, "blocking", name, {})
        if name == "before":
            self.read_side(step, "hangs", name, {"limit": 1})
            self.read_side(step, "actionBudget", name, {"limit": 1})
            return
        self.read_side(step, "hangs", name, {"after": newest(earlier.get("hangs", {}).get("before"), "records"),
                                             "limit": HANGS_AFTER_LIMIT})
        self.read_side(step, "actionBudget", name, {"limit": RUNS_AFTER_LIMIT})

    # -- barriers

    def settle(self, sequence: Any, max_ms: int, step: str) -> Dict[str, Any]:
        bound = min(int(max_ms * self.scale), MAX_SETTLE_MS)
        reply = self.result(SETTLE, {"sequence": sequence, "settleMaxMs": max(bound, 1)}, step,
                            bound / 1000 + REPLY_MARGIN_S)
        if not isinstance(reply, dict) or reply.get("settled") is not True:
            pending = (reply or {}).get("pending") if isinstance(reply, dict) else None
            raise CaseError("Timeout", f"settle through {sequence} missed {bound} ms; pending {pending}", step)
        return reply

    def wait_baseline(self, wait: Mapping[str, Any], step: str) -> Any:
        """The value at the waitFor pointer before the step (null: absent), the `since` of a `changed` wait."""
        if wait.get("predicate") != "changed":
            return None
        facet = decode_pointer(wait["pointer"])[0]
        self.check_waitable(facet, step)
        values = self.app_facets((facet,), step)
        found = resolve_pointer(values, wait["pointer"])
        return None if found is MISSING else found

    def check_waitable(self, facet: str, step: str) -> None:
        if facet == DAEMON:
            raise CaseError("Crash", "waitFor on /daemon: the app's wait_for has no daemon facet; wait on an app "
                                     "facet or use driver_daemon.py", step)

    def wait_for(self, wait: Mapping[str, Any], since: Any, step: str) -> None:
        facet = decode_pointer(wait["pointer"])[0]
        self.check_waitable(facet, step)
        bound = min(int(wait["maxMs"] * self.scale), MAX_WAIT_MS)
        params: Dict[str, Any] = {"pointer": wait["pointer"], "maxMs": bound,
                                  "paths": self.session.paths.control_paths()}
        if "equals" in wait:
            params["equals"] = resolve_refs(wait["equals"], self.state.replies)
        else:
            params["predicate"] = resolve_refs(wait["predicate"], self.state.replies)
            if wait["predicate"] == "changed":
                params["since"] = since
        reply = self.result(WAIT_FOR, params, step, bound / 1000 + REPLY_MARGIN_S)
        if not isinstance(reply, dict) or reply.get("satisfied") is not True:
            value = reply.get("value") if isinstance(reply, dict) else None
            raise CaseError("Timeout", f"waitFor {wait['pointer']} not met in {bound} ms (last value "
                                       f"{json.dumps(value)[:200]})", step)

    # -- turn checkpoints

    def arm(self, facets: Sequence[str], step: str) -> Tuple[int, int]:
        """Arms the turn recorder with the requested facets it can read in a turn; the armed mark's sequence and
        the recorder's dropped count then (it counts since launch)."""
        armable = [f for f in facets if f in self.session.armable]
        if not armable:
            raise CaseError("Crash", "a turn checkpoint needs a main-actor facet; this build arms none of "
                                     f"{', '.join(facets)}", step)
        reply = self.result(RECORDER, {"clear": True, "arm": True, "facets": armable,
                                       "paths": self.session.paths.control_paths()}, step)
        return int(reply["checkpoint"]["sequence"]), int(reply.get("dropped") or 0)

    def record_turns(self, index: int, step: str, facets: Sequence[str], armed: Tuple[int, int]) -> None:
        after, dropped = armed
        reply = self.result(TURNS, {"after": after}, step)
        lost = int(reply.get("dropped") or 0) - dropped
        if lost:
            raise CaseError("Crash", f"the turn recorder overwrote {lost} checkpoints of this step", step)
        turns = [c for c in reply.get("checkpoints") or () if c.get("kind") == "turn"]
        if not turns:
            raise CaseError("Failure", "the step asked for a turn checkpoint, but no perform turn ran", step)
        for turn in turns:
            if turn.get("failure"):
                raise CaseError("Crash", f"turn {turn.get('label')}: {turn['failure']}", step)
            recorded = turn.get("facets") or {}
            values = {}
            for name in facets:
                if name in recorded:
                    values[name] = recorded[name]
                else:
                    values[name] = not_comparable(f"{name} is not read inside a perform turn in this build")
            self.state.captures.append(Capture(index, step, "turn", self.snapshot(index, "turn", values)))

    # -- steps

    def op_action_run(self, index: int, step: Mapping[str, Any]) -> Tuple[Tuple[str, Any], Any]:
        step_id = step["id"]
        args = resolve_refs(step["args"], self.state.replies)
        params: Dict[str, Any] = {"action": args["action"], "args": args.get("params") or {}}
        target = action_target(resolve_refs(step.get("target") or {}, self.state.replies), step_id)
        if target:
            params["target"] = target
        entry = args.get("entrypoint")
        if entry in SOCKET_ORIGINS:
            params["origin"] = entry
        elif entry not in (None, "unattributed"):
            raise CaseError("Crash", f"a socket caller cannot be the {entry} entrypoint; use a key step", step_id)
        if args.get("focus") is True:
            # ControlActionRequest.focus: the run may change focus and selection (ActionInvocation.allowsViewChange).
            params["focus"] = True
        reply = self.call("action.run", params, step_id)
        if reply.get("ok") is not True:
            error = reply.get("error")
            self.state.replies[step_id] = {"error": error}
            return ("error", typed_error("control", error)), "sync"
        value = reply.get("result") or {}
        self.state.replies[step_id] = value
        return ("ok", value), value.get("sequence", "sync")

    def op_key(self, index: int, step: Mapping[str, Any]) -> Tuple[Tuple[str, Any], Any]:
        step_id = step["id"]
        target = resolve_refs(step.get("target") or {}, self.state.replies)
        # debug.key sends to the focused pane of a window (DebugKey.send reads `pane` only for a page or DevTools
        # window), or to an open overlay's panel: a key aimed at another object would land on whatever has focus.
        aimed = sorted(k for k, v in target.items() if k not in ("window", "overlay") and v != CURRENT)
        if aimed:
            raise CaseError("Crash", f"a key goes to the focused pane of its window; debug.key cannot aim at target."
                                     f"{', target.'.join(aimed)} (focus it in an earlier action.run step)", step_id)
        window = target.get("window", CURRENT)
        if not isinstance(window, str):
            raise CaseError("Crash", f"target.window is {window!r}, not a string", step_id)
        where: Dict[str, Any] = {} if window == CURRENT else {"window": window}
        if "overlay" in target:
            if target["overlay"] not in OVERLAY_KEY_TARGETS:
                raise CaseError("Crash", f"debug.key has no overlay {target['overlay']!r}", step_id)
            where["target"] = OVERLAY_KEY_TARGETS[target["overlay"]]
        key_window = step["args"].get("keyWindow")
        if key_window is not None:
            if "overlay" in target:
                raise CaseError("Crash", "a key step takes target.overlay or keyWindow, not both", step_id)
            if key_window not in KEY_WINDOWS:
                raise CaseError("Crash", f"keyWindow {key_window!r}: debug.key has no such window "
                                         f"({', '.join(sorted(KEY_WINDOWS))})", step_id)
            where["target"] = KEY_WINDOWS[key_window]
        replies = []
        for stroke in step["args"]["keys"]:
            reply = self.call("debug.key", {**debug_key(stroke, step_id), **where}, step_id)
            if reply.get("ok") is not True:
                raise CaseError("Crash", f"debug.key refused: {json.dumps(reply.get('error'))[:300]}", step_id)
            value = reply.get("result") or {}
            replies.append(value)
            if isinstance(value, dict) and value.get("error"):
                self.state.replies[step_id] = replies
                return ("error", "key.refused"), "sync"
        self.state.replies[step_id] = replies
        return ("ok", replies), "sync"

    def op_cli(self, index: int, step: Mapping[str, Any]) -> Tuple[Tuple[str, Any], Any]:
        step_id = step["id"]
        args = resolve_refs(step["args"], self.state.replies)
        done = self.run_cli(list(args["argv"]), args.get("stdin"), step_id)
        stdout = done.stdout
        try:
            parsed: Any = json.loads(stdout) if stdout.strip() else None
        except ValueError:
            parsed = stdout
        reply = {"exit": done.returncode, "stdout": parsed}
        self.state.replies[step_id] = reply
        if done.returncode != 0:
            return ("error", typed_error("cli", parsed.get("error") if isinstance(parsed, dict) else None)), "sync"
        return ("ok", reply), "sync"

    def run_cli(self, argv: List[str], stdin: Optional[str], step: str) -> subprocess.CompletedProcess:
        """The bundle's own cmux on the app's socket: its text output captured, `stdin` as its input (else no
        input at all, never the runner's), bounded by CLI_S times the Slow multiplier."""
        bound = CLI_S * self.scale
        feed: Dict[str, Any] = {"input": stdin} if stdin is not None else {"stdin": subprocess.DEVNULL}
        try:
            return self.session.run([self.app.cli_path, "--app-socket", self.app.socket_path, *argv],
                                    env=self.app.cli_env(), capture_output=True, text=True, timeout=bound, **feed)
        except subprocess.TimeoutExpired:
            raise CaseError("Timeout", f"cmux {' '.join(argv)[:200]} gave no answer in {bound:.0f} s", step) from None
        except OSError as error:
            raise CaseError("Crash", f"cmux {' '.join(argv)[:200]} did not start: {error}", step) from None

    def op_mcp(self, index: int, step: Mapping[str, Any]) -> Tuple[Tuple[str, Any], Any]:
        step_id = step["id"]
        args = resolve_refs(step["args"], self.state.replies)
        requests = [
            {"jsonrpc": "2.0", "id": 1, "method": "initialize",
             "params": {"protocolVersion": "2025-06-18", "capabilities": {},
                        "clientInfo": {"name": "cmux-oracle", "version": "1"}}},
            {"jsonrpc": "2.0", "method": "notifications/initialized"},
            {"jsonrpc": "2.0", "id": 2, "method": "tools/call",
             "params": {"name": args["tool"], "arguments": args.get("arguments") or {}}},
        ]
        done = self.run_cli(["mcp", "serve", "--all-tools"], "".join(json.dumps(r) + "\n" for r in requests), step_id)
        answer = None
        for line in done.stdout.splitlines():
            try:
                message = json.loads(line)
            except ValueError:
                continue
            if isinstance(message, dict) and message.get("id") == 2:
                answer = message
        if answer is None:
            raise CaseError("Crash", f"mcp serve gave no tools/call answer (exit {done.returncode}): "
                                     f"{done.stderr.strip()[-300:]}", step_id)
        if "error" in answer:
            self.state.replies[step_id] = {"error": answer["error"]}
            return ("error", "mcp.rpc_error"), "sync"
        result = answer.get("result") or {}
        value = result.get("structuredContent", result.get("content"))
        self.state.replies[step_id] = value
        if result.get("isError"):
            return ("error", "mcp.tool_error"), "sync"
        return ("ok", value), "sync"

    def op_settle(self, index: int, step: Mapping[str, Any]) -> Tuple[Tuple[str, Any], Any]:
        reply = self.settle("sync", step.get("settleMaxMs") or DEFAULT_SETTLE_MS, step["id"])
        self.state.replies[step["id"]] = reply
        return ("ok", reply), reply.get("sequence", "sync")

    def op_snapshot(self, index: int, step: Mapping[str, Any]) -> Tuple[Tuple[str, Any], Any]:
        return ("ok", {}), "sync"

    def op_kill(self, index: int, step: Mapping[str, Any]) -> Tuple[Tuple[str, Any], Any]:
        """Signals the tag's cmux-tui owner. The app's view of the loss is the step's waitFor."""
        step_id = step["id"]
        if not runs_here(step):
            raise CaseError("Crash", other_driver("kill", (step.get("target") or {}).get("process")), step_id)
        name = (step.get("args") or {}).get("signal", "KILL")
        if name not in SIGNALS:
            raise CaseError("Crash", f"kill signal {name}: the app driver sends {', '.join(SIGNALS)}", step_id)
        if self.app.signal_daemon(SIGNALS[name]) is None:
            raise CaseError("Crash", "kill target.process daemon: no cmux-tui of this tag is running", step_id)
        # A later case must not inherit the owner that replaced this one.
        self.dirty = True
        reply = {"process": "daemon", "signal": name}
        self.state.replies[step_id] = reply
        return ("ok", reply), "sync"

    def op_restart(self, index: int, step: Mapping[str, Any]) -> Tuple[Tuple[str, Any], Any]:
        """Quits the app keeping its sessions and launches it again on the same state."""
        step_id = step["id"]
        if not runs_here(step):
            raise CaseError("Crash", other_driver("restart", (step.get("target") or {}).get("process")), step_id)
        if self.session.counts_hits:
            # The new process counts from zero: keep the hits of the one that quits.
            self.restart_hits = add_hits(self.restart_hits, self.switch_hits(step_id) or {})
        try:
            self.app.relaunch()
        except (AppLaunchFailed, AppGone, socket.timeout) as error:
            raise CaseError("Crash", f"restart target.process app: {error}", step_id) from None
        # The relaunched app is the one the rest of the case must keep.
        self.pid = self.app.pid
        # A later case must not inherit the restored session.
        self.dirty = True
        reply = {"process": "app"}
        self.state.replies[step_id] = reply
        return ("ok", reply), "sync"

    def check_expect(self, step: Mapping[str, Any], outcome: Tuple[str, Any]) -> None:
        expect = step.get("expect")
        if not expect:
            return
        step_id = step["id"]
        kind, detail = outcome
        if expect["outcome"] != kind:
            got = f"error {detail}" if kind == "error" else "ok"
            raise CaseError("Failure", f"expected {expect['outcome']}"
                                       f"{' ' + expect['error'] if 'error' in expect else ''}, got {got}", step_id)
        if kind == "error":
            if detail != expect["error"]:
                raise CaseError("Failure", f"expected error {expect['error']}, got {detail}", step_id)
            if "errorDetails" in expect:
                self.check_error_details(step, expect["errorDetails"])
            return
        receipt = expect.get("receipt")
        if receipt is not None:
            if receipt not in ACTION_RECEIPTS or step["op"] not in ("action.run", "key"):
                raise CaseError("Crash", f"receipt kind {receipt} has no {step['op']} reply in the app", step_id)
            ran = detail.get("ran") is True if step["op"] == "action.run" else any(
                isinstance(r, dict) and r.get("action") for r in detail)
            if not ran:
                raise CaseError("Failure", f"expected an {receipt} receipt, but no action ran", step_id)
            # The reply names that a handler ran, not its ActionEffect kind: the kind itself is not compared.
            self.unchecked_receipts[step_id] = receipt
        if "result" in expect:
            # action.run's own reply also holds the run's daemon sequence, idempotency key and created ids.
            value = detail.get("result", MISSING) if step["op"] == "action.run" else detail
            if value is MISSING:
                raise CaseError("Failure", "expected a result, but the action returned none", step_id)
            if value != expect["result"]:
                raise CaseError("Failure", f"result differs: {json.dumps(value, sort_keys=True)[:300]}", step_id)

    def check_error_details(self, step: Mapping[str, Any], expected: Any) -> None:
        """expect.errorDetails against an action.run refusal's `error.data` (ControlError's details, for example
        {"action": id, "reason": text}), compared as case_checks.error_details_mismatch says. The cli, mcp and key
        replies reach this driver as a typed code only: a check on them is a Crash, never a silent pass."""
        step_id = step["id"]
        if step["op"] != "action.run":
            raise CaseError("Crash", f"errorDetails: the {step['op']} reply gives this driver no error details",
                            step_id)
        import case_checks
        error = (self.state.replies.get(step_id) or {}).get("error")
        actual = error.get("data") if isinstance(error, dict) else None
        problem = case_checks.error_details_mismatch(resolve_refs(expected, self.state.replies), actual)
        if problem:
            raise CaseError("Failure", f"errorDetails {problem}", step_id)

    # -- snapshots

    def app_facets(self, names: Sequence[str], step: str) -> Dict[str, Any]:
        """The app's facets of `names` (debug.oracle.snapshot), the daemon facet from the tag's daemon."""
        out: Dict[str, Any] = {}
        app_names = [n for n in names if n != DAEMON]
        if app_names:
            values = self.result(SNAPSHOT, {"facets": app_names, "paths": self.session.paths.control_paths()}, step)
            for name in app_names:
                if not isinstance(values, dict) or name not in values:
                    raise CaseError("Crash", f"{SNAPSHOT} left out the requested facet {name}", step)
                out[name] = values[name]
        if DAEMON in names:
            out[DAEMON] = self.session.daemon_facet(step)
        return out

    def snapshot(self, index: int, checkpoint: str, facets: Dict[str, Any]) -> Dict[str, Any]:
        return {
            "schema": "cmux.oracle.snapshot/v1",
            "meta": {"case": self.case_id, "step": index, "checkpoint": checkpoint, "product": "app",
                     "sha": self.session.sha, "host": self.session.host, "clock": "wall",
                     "capturedAtMs": int(time.time() * 1000), "facets": list(facets)},
            "facets": facets,
        }

    def capture(self, index: int, step: str, checkpoint: str, names: Sequence[str]) -> None:
        self.check_alive(step)
        values = self.app_facets(names, step)
        self.state.captures.append(Capture(index, step, checkpoint, self.snapshot(index, checkpoint, values)))


# ---------------------------------------------------------------------------------------------------------
# The session


# (snapshots, paths, labels, drop): drop is normalize.Context.drop, the pointers the session leaves out.
Canonicalize = Callable[[Sequence[Dict[str, Any]], Any, Sequence[str], Sequence[str]], List[Any]]
AppFactory = Callable[[str, Path, Mapping[str, str]], Any]


def normalize_canonicalizer(schema_path: Optional[str] = None) -> Tuple[Canonicalize, Dict[str, Any]]:
    """normalize.py's case canonicalization over the snapshot schema, and the schema document (the daemon
    facet's capture rules). Raises ValueError when normalize.py refuses the schema: no snapshot could be canonical."""
    import normalize

    path = Path(schema_path) if schema_path else normalize.DEFAULT_SCHEMA
    try:
        schema = normalize.Schema.load(path)
    except normalize.OracleError as error:
        raise ValueError(f"normalize.py refuses the snapshot schema, so no snapshot can be canonical: {error}") from None

    def canonicalize(snapshots: Sequence[Dict[str, Any]], paths: OraclePaths, labels: Sequence[str],
                     drop: Sequence[str]) -> List[Any]:
        ctx = normalize.Context(root=paths.roots, home=(str(paths.home),), web=paths.web, drop=tuple(drop))
        return [r.value for r in normalize.canonicalize_case(list(snapshots), schema, ctx, list(labels))]

    return canonicalize, schema.doc


def tab_engines(snapshot: Any) -> Dict[str, int]:
    """How many tabs of the snapshot's tabs facet show each engine (BrowserEngineKind); page tabs show none."""
    facets = snapshot.get("facets") if isinstance(snapshot, dict) else None
    tabs = facets.get("tabs") if isinstance(facets, dict) else None
    panes = tabs.get("panes") if isinstance(tabs, dict) else None
    counts: Dict[str, int] = {}
    for pane in panes if isinstance(panes, list) else ():
        for tab in (pane.get("tabs") if isinstance(pane, dict) else None) or ():
            kind = tab.get("engine") if isinstance(tab, dict) else None
            if isinstance(kind, str):
                counts[kind] = counts.get(kind, 0) + 1
    return dict(sorted(counts.items()))


def app_identity(app: str) -> Tuple[str, Optional[str], str, str]:
    """(tag, bundle id, bundle kind, build sha or "") of a tagged app, by bench_launch's readers."""
    import bench_launch

    try:
        tag = bench_launch.tag_of(app)
        kind = bench_launch.bundle_kind(app, bench_launch.main_binary(app))
    except SystemExit as error:  # bench_launch refuses a bundle that is not `cmux DEV <tag>.app` with an executable
        raise ValueError(str(error)) from None
    try:
        sha = bench_launch.build_sha(app)
    except bench_launch.RecordError:
        sha = ""
    return tag, bench_launch.bundle_id(app), kind, sha


class AppSession:
    """One app launch for up to --batch-limit cases (oracle.py's session). Launched at the first case, again when
    a case needs another launch (its viewport), and quit with its tag's daemons at close."""

    # The case a launch runs; driver_mcp.py's fleet session runs one that keeps the mcp and cli receipts.
    case_class: Callable[["AppSession", Mapping[str, Any], Mapping[str, Any]], CaseRun] = CaseRun

    def __init__(self, session_ctx: Mapping[str, Any], *, make_app: Optional[AppFactory] = None,
                 identity: Callable[[str], Tuple[str, Optional[str], str, str]] = app_identity,
                 canonicalizer: Optional[Tuple[Canonicalize, Dict[str, Any]]] = None,
                 run: Callable[..., subprocess.CompletedProcess] = subprocess.run,
                 read_daemon: Callable[[str, Mapping[str, Any]], Dict[str, Any]] = read_daemon_facet,
                 read_daemon_arms: Callable[[str], Mapping[str, Any]] = read_daemon_arm_sources,
                 host: Callable[[], Dict[str, str]] = host_meta, root_base: Path = Path("/tmp/o"),
                 switch_roots: Optional[switches.Roots] = None,
                 web_fixture: Callable[[], Any] = webfixture.WebFixture,

                 read_resources: Callable[[Optional[int]], Optional[Dict[str, Any]]] = resource_counts.read):
        app = session_ctx.get("binary")
        if not app:
            raise ValueError("the app driver needs --binary \"PATH/cmux DEV <tag>.app\" (a --config bench build)")
        registry = session_ctx.get("switch_registry")
        roots = switch_roots or (switches.Roots(registry=Path(registry).resolve()) if registry else switches.Roots())
        try:
            self.arms = switches.arm_plan(dict(session_ctx.get("switches") or {}), roots)
        except switches.UnknownSwitch as error:  # nothing launches on a switch the run cannot apply
            raise ValueError(str(error)) from None
        self.read_daemon_arms = read_daemon_arms
        self.app_arms = switches.Readback(arms={}, sources={}, problems=())
        # Whether this build counts switch hits for the run (read once per launch), and the hits of the last
        # launch that no case result has carried yet.
        self.counts_hits = False
        self.launch_hits: Optional[Dict[str, Dict[str, int]]] = None
        self.engine = session_ctx.get("engine")
        if self.engine is not None and self.engine not in ENGINES:
            raise ValueError(f"engine {self.engine!r}: one of {', '.join(ENGINES)} (browser.defaultEngine)")
        app = os.path.realpath(str(app)).rstrip("/")
        check_not_user_app(app, None)
        tag, bundle, kind, sha = identity(app)
        check_not_user_app(app, bundle)
        if session_ctx.get("tag") and session_ctx["tag"] != tag:
            raise ValueError(f"--tag {session_ctx['tag']} but {app} is the app of tag {tag}")
        self.build = run_build(kind, str(session_ctx.get("build") or "bench"))
        ref = session_ctx.get("ref")
        self.sha = ref if isinstance(ref, str) and re.fullmatch(r"[0-9a-f]{40}", ref) else sha
        if not re.fullmatch(r"[0-9a-f]{40}", self.sha or ""):
            raise ValueError(f"no build sha for {app}: it has no CMUXCommit, CMUX_CI_SHA is unset and --ref is not "
                             "a full SHA")
        self.canonicalize, self.schema_doc = canonicalizer or normalize_canonicalizer(session_ctx.get("snapshot_schema"))
        self.app_path = app
        self.tag = tag
        self.run = run
        self.read_daemon = read_daemon
        # A case with fixture.web gets one of these: its own loopback server (start, expand, stop).
        self.web_fixture = web_fixture
        self.host = host()
        root_base.mkdir(parents=True, exist_ok=True)
        self.paths = OraclePaths(Path(tempfile.mkdtemp(prefix="a", dir=str(root_base))))
        self.paths.home.mkdir()
        # The app log stays after close (the session root goes): a failed launch's report names it.
        out = Path(session_ctx.get("out_dir") or root_base / "logs") / "app" / self.paths.root.name
        out.mkdir(parents=True, exist_ok=True)
        self.out = out
        self.app = (make_app or BenchAppPort)(app, out, self.environment())
        self.launched: Optional[LaunchSpec] = None
        self.armable: Tuple[str, ...] = ()
        # `run-case --trace`: each case result carries its invariants.py trace (I11-I15).
        self.trace = bool(session_ctx.get("trace"))
        self.read_resources = read_resources

    def environment(self) -> Dict[str, str]:
        """The launch's own variables over bench_launch's: normalize.app_environment of the session's prefixes and
        the run's switch arms (CMUX_NEXT_SWITCHES, CMUX_NEXT_TUI_SWITCHES for the app's daemon).
        Task p15-oracle-200 moves the hermetic environment into hermetic_env.py."""
        import normalize

        prefixes = normalize.app_environment(normalize.Context(root=self.paths.roots, home=(str(self.paths.home),)))
        return {**prefixes, **self.arms.app_environment()}

    def ensure_launched(self, spec: LaunchSpec) -> None:
        """Launches the app for `spec` unless it runs already. Raises switches.ArmNotApplied when the arms the app
        froze at launch are not the plan's: every case of this launch, and every relaunch, would run on them."""
        if self.launched == spec and self.app.alive():
            return
        if self.launched is not None:
            self.app.stop()
            self.launched = None
        self.app.launch(spec)
        self.launched = spec
        self.armable = self.probe_armable()
        self.app_arms = self.read_app_arms()
        self.app_arms.check()
        try:
            launch = self.hit_counts("launch")
        except CaseError as error:
            raise AppLaunchFailed("bad-switch-hits", error.message) from None
        self.counts_hits = launch is not None
        if launch is not None:
            self.launch_hits = add_hits(self.launch_hits, launch)

    def read_app_arms(self) -> Any:
        """The arms the app froze at launch, from the switches facet's `arms` (p15-oracle-180), against the plan:
        each requested switch its arm, every other registry switch its default. A build with no switches provider
        reads back nothing, so a requested app switch is arm-not-applied; with an empty registry nothing is read."""
        if not self.arms.switches:
            return switches.Readback(arms={}, sources={}, problems=())
        values = self.request(SNAPSHOT, {"facets": ["switches"], "paths": self.paths.control_paths()})
        facet = values.get("switches") if isinstance(values, dict) else None
        arms = facet.get("arms") if isinstance(facet, dict) and facet.get("status") != "not-comparable" else None
        try:
            return switches.read_back(self.arms, switches.APP, {APP_ARMS_READER: arms})
        except switches.UsageError as error:
            raise AppLaunchFailed("bad-switch-readback", str(error)) from None

    def daemon_arms(self) -> Any:
        """The tag daemon's arms against the plan. No daemon of the tag running reads back nothing, which only a
        requested daemon switch needs; a read that fails proves no arm, so it is a mismatch."""
        socket_path = self.app.daemon_socket()
        if socket_path is None:
            missing = tuple(f"{s.name}: no cmux-tui of this tag is running to read back"
                            for s in self.arms.requested(switches.DAEMON))
            return switches.Readback(arms={}, sources={}, problems=missing)
        try:
            return switches.read_back(self.arms, switches.DAEMON, self.read_daemon_arms(socket_path))
        except Exception as error:  # noqa: BLE001 - an SDK or reply failure is a readback that failed
            return switches.Readback(arms={}, sources={}, problems=(
                f"daemon switch readback from {socket_path}: {error!r}",))

    def verify_arms(self) -> Dict[str, str]:
        """The arms both processes read back now (registry name -> arm). The app's are read once per launch (a
        frozen value); the daemon's at each case whenever the registry has a daemon switch, since the app may start
        a new daemon. Raises switches.ArmNotApplied, with the readback, on any mismatch with the plan."""
        readbacks = [self.app_arms]
        if any(s.product == switches.DAEMON for s in self.arms.switches):
            readbacks.append(self.daemon_arms())
        seen: Dict[str, set] = {}
        for readback in readbacks:
            for name, arm in readback.arms.items():
                seen.setdefault(name, set()).update(arm.split("|"))
        arms = {name: "|".join(sorted(values)) for name, values in sorted(seen.items())}
        problems = tuple(problem for readback in readbacks for problem in readback.problems)
        if problems:
            raise switches.ArmNotApplied(problems, arms)
        return arms

    def hit_counts(self, step: str) -> Optional[Dict[str, Dict[str, int]]]:
        """The switch hits since the last call, by registry name (`debug.oracle.switch_hits` reads and zeroes them),
        or None when this run requests no app switch or the build has no hit counters (p15-oracle-027)."""
        if not self.arms.requested(switches.APP):
            return None
        reply = self.app.request(SWITCH_HITS, {"reset": True}, REQUEST_S)
        if reply.get("ok") is not True or reply.get("result") is None:
            return None
        try:
            return switches.hits_by_name(self.arms, reply["result"])
        except switches.UsageError as error:
            raise CaseError("Crash", f"{SWITCH_HITS}: {error}", step) from None

    def take_launch_hits(self) -> Optional[Dict[str, Dict[str, int]]]:
        """The hits of the launch since its first read (startup, the first window), once: the next result carries
        them as `launch_switch_hits` and oracle.py adds them to the run's hits."""
        hits, self.launch_hits = self.launch_hits, None
        return hits

    def probe_armable(self) -> Tuple[str, ...]:
        """The facets this build reads inside a perform turn: the recorder refuses to arm one read off the main
        actor, so each provided facet is tried once per launch and the recorder left disarmed and empty."""
        catalog = self.request(SNAPSHOT, {"list": True})
        provided = [e["facet"] for e in catalog if isinstance(e, dict) and e.get("provided")]
        armable = []
        for name in provided:
            reply = self.app.request(RECORDER, {"arm": True, "facets": [name]}, REQUEST_S)
            if reply.get("ok") is True:
                armable.append(name)
        self.request(RECORDER, {"arm": False, "clear": True})
        return tuple(armable)

    def request(self, method: str, params: Mapping[str, Any]) -> Any:
        reply = self.app.request(method, params, REQUEST_S)
        if reply.get("ok") is not True:
            raise AppLaunchFailed("no-oracle-methods", f"{method}: {json.dumps(reply.get('error'))[:300]}")
        return reply.get("result")

    def run_case(self, case: Dict[str, Any], case_ctx: Dict[str, Any]) -> Dict[str, Any]:
        """One case's result. switches.ArmNotApplied (from the launch or the case's readback) is raised, not
        returned: it is the run's verdict, not this case's."""
        result = self.run_launched(case, case_ctx)
        launch = self.take_launch_hits()
        if launch is not None:
            result["launch_switch_hits"] = launch
        return result

    def run_launched(self, case: Dict[str, Any], case_ctx: Dict[str, Any]) -> Dict[str, Any]:
        try:
            spec = launch_spec(case, self.engine)
            self.ensure_launched(spec)
        except CaseError as error:
            refused = {"status": error.status, "message": error.message, "checkpoints": []}
            if error.step:
                refused["step"] = error.step
            return refused
        except (AppLaunchFailed, AppGone, socket.timeout) as error:
            return {"status": "Crash", "message": f"app launch: {error}", "checkpoints": [], "session_dirty": True}
        return self.case_class(self, case, case_ctx).run()

    def daemon_facet(self, step: str) -> Any:
        socket_path = self.app.daemon_socket()
        if socket_path is None:
            return not_comparable("no cmux-tui of this tag is running")
        try:
            return self.read_daemon(socket_path, self.schema_doc)
        except Exception as error:  # noqa: BLE001 - an SDK or reply failure is this case's Crash
            raise CaseError("Crash", f"daemon facet from {socket_path}: {error!r}", step) from None

    def daemon_resources(self) -> Optional[Dict[str, Any]]:
        """The tag daemon's descriptors, threads and children now (I15), with the liveObjects of its daemon facet
        (a debug or oracle daemon); None when no daemon of the tag runs or its counts cannot be read."""
        try:
            pid, socket_path = self.app.daemon_owner_pid(), self.app.daemon_socket()
        except (OSError, subprocess.SubprocessError, ValueError):
            return None  # the process table could not be read: I15 is then not checked
        reading = self.read_resources(pid) if pid is not None else None
        if reading is not None and socket_path is not None:
            try:
                facet = self.read_daemon(socket_path, self.schema_doc)
            except Exception:  # noqa: BLE001 - no live objects: I15 says it cannot tell, the case goes on
                return reading
            live = (facet.get("oracle") or {}).get("liveObjects")
            if isinstance(live, dict):
                reading["liveObjects"] = live
        return reading

    def canonical(self, case_id: str, captures: Sequence[Capture], web: Sequence[str] = ()) -> List[Dict[str, Any]]:
        """The case's checkpoints canonicalized together; `web` holds the origin of its web fixture, if any."""
        if not captures:
            return []
        paths = replace(self.paths, web=tuple(web)) if web else self.paths
        drop = (ENGINE_DROP,) if self.engine is not None else ()
        values = self.canonicalize([c.snapshot for c in captures], paths,
                                   [f"{c.step}/{c.checkpoint}" for c in captures], drop)
        rows = [{"step": c.step, "checkpoint": c.checkpoint, "snapshot": v} for c, v in zip(captures, values)]
        if self.engine is not None:
            for row, capture in zip(rows, captures):
                row["engines"] = tab_engines(capture.snapshot)
        return rows

    def close(self) -> None:
        try:
            self.app.stop()
        finally:
            self.launched = None
            shutil.rmtree(self.paths.root, ignore_errors=True)


def open_session(session_ctx: Dict[str, Any]) -> Any:
    if session_ctx.get("facets") == "v0":
        # facets_v0.py capture: the push base has no debug.oracle.* methods, so v0 reads its own.
        import driver_app_v0

        return driver_app_v0.open_session(session_ctx)
    return AppSession(session_ctx)


# ---------------------------------------------------------------------------------------------------------
# CLI


def run_repeats(ctx: Mapping[str, Any], case: Dict[str, Any], repeat: int,
                open_session: Callable[[Dict[str, Any]], AppSession] = AppSession,
                emit: Callable[[str], None] = print, trace_dir: Optional[Path] = None) -> int:
    """Runs `case` `repeat` times, each in its own session (a fresh launch, saved session and root), as
    oracle.py --repeat does: a run never starts from the state an earlier one left. 0 when every run passes
    with equal checkpoint hashes. With `trace_dir`, each run's invariants.py trace is written there as
    `<attempt>.trace.json` (`invariants.py check` reads it)."""
    import oracle

    case_id = f"{case.get('suite')}/{case.get('id')}"
    hashes = []
    for attempt in range(repeat):
        session = open_session({**ctx, "trace": trace_dir is not None})
        try:
            result = session.run_case(case, {"case_id": case_id, "attempt": attempt})
        finally:
            session.close()
        trace = result.pop("trace", None)
        if trace_dir is not None and trace is not None:
            trace_dir.mkdir(parents=True, exist_ok=True)
            path = trace_dir / f"{attempt}.trace.json"
            path.write_text(json.dumps(trace, indent=1, sort_keys=True) + "\n", encoding="utf-8")
            emit(f"driver_app: trace {path}")
        row = [oracle.snapshot_sha256(cp["snapshot"]) for cp in result["checkpoints"]]
        hashes.append((result["status"], row))
        emit(json.dumps({"attempt": attempt, "status": result["status"], "message": result["message"],
                         "checkpoints": [f"{cp['step']}/{cp['checkpoint']} {h[:12]}"
                                         for cp, h in zip(result["checkpoints"], row)],
                         **{k: result[k] for k in ("switch_readback", "switch_hits", "launch_switch_hits")
                            if k in result}}))
    same = all(h == hashes[0] for h in hashes)
    emit(f"driver_app: {len(hashes)} runs, {'equal' if same else 'DIFFERENT'} checkpoint hashes")
    return 0 if same and hashes and hashes[0][0] == "Pass" else 1


def cmd_run_case(args: argparse.Namespace) -> int:
    case = json.loads(Path(args.case).read_text(encoding="utf-8"))
    ctx = {"run_id": "run-case", "product": "app", "build": args.build, "binary": args.app, "ref": args.ref,
           "out_dir": args.out, "switches": switches.parse_requests(args.switch),
           "switch_registry": args.switch_registry}
    return run_repeats(ctx, case, args.repeat, emit=lambda line: print(line, flush=True),
                       trace_dir=Path(args.trace) if args.trace else None)


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--selftest", action="store_true", help="run the offline tests (driver_app_test.py)")
    sub = parser.add_subparsers(dest="command")
    one = sub.add_parser("run-case", help="one case --repeat times, each in a fresh launch")
    one.add_argument("case")
    one.add_argument("--app", required=True, help='the tagged "cmux DEV <tag>.app"')
    one.add_argument("--build", default="bench", choices=("bench", "debug"))
    one.add_argument("--ref", help="the full SHA the app was built from (default: its CMUXCommit or CMUX_CI_SHA)")
    one.add_argument("--repeat", type=int, default=2)
    one.add_argument("--out", help="log folder (default: /tmp/o/logs, kept after the run)")
    one.add_argument("--trace", help="write each run's invariants.py trace (raw checkpoints, the I11-I14 side "
                                     "channels, I15's daemon counts) to DIR/<attempt>.trace.json")
    one.add_argument("--switch", action="append", default=[], metavar="NAME=ARM",
                     help="run on this refactor switch arm (plans/cmux-next/refactor-switches/NAME.json); repeatable")
    one.add_argument("--switch-registry", help="refactor switch registry (default plans/cmux-next/refactor-switches)")
    args = parser.parse_args(argv)
    if args.selftest:
        import unittest

        import driver_app_test

        suite = unittest.defaultTestLoader.loadTestsFromModule(driver_app_test)
        return 0 if unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful() else 1
    if args.command == "run-case":
        try:
            return cmd_run_case(args)
        except (switches.UsageError, ValueError) as error:  # a bad --switch or an unknown switch: nothing launched
            print(f"driver_app: {error}", file=sys.stderr)
            return 2
        except switches.ArmNotApplied as error:  # the build runs other arms than the run applied
            print(f"driver_app: {error}; read back {json.dumps(error.readback, sort_keys=True)}", file=sys.stderr)
            return 1
    parser.print_usage(sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
