#!/usr/bin/env python3
"""Generate the tours suite: one golden case per cmux-next media tour, with every timed wait made a typed wait.

Spec: plans/cmux-next/chrome-parity/p15-oracle.md, sections 3B (settle and waits), 3D (suite tours, golden, 23 media
tours) and task 091. Stdlib plus scripts/cmux-next/media/tour.py (its `load_tour` is the one tour reader), Python
3.9+, safe under `python3 -I`. `oracle.py gen --suite tours` runs it with `--out <corpus>/tours`.

Chrome reference (chromium/src): chrome/test/interaction/README.md and ui/base/interaction/interactive_test.h
(Kombucha) turn a scripted UI walk into Action, WaitForState and Check verbs, where a wait is a StateObserver on
the producer's own signal and never a timer; content/public/test/browser_test_utils.h WaitForLoadStop is the
page barrier. A tour (scripts/cmux-next/media/tours/<name>.json) is such a walk written for pictures: each step
runs one command, then sleeps `wait` seconds before its screenshot. Here each step becomes a case-v1 step whose
settled snapshot stands in for the screenshot, and the sleep becomes the step's waitFor or the settle barrier.

Step mapping (tour step -> case step):

  the first step (`Launch`)  snapshot (shot) or settle; tour `settings` become cli `settings set` setup steps
                             before it, since case-v1 has no launch config
  wait only                  snapshot (shot) or settle
  cmux ARGV                  cli ARGV on the app's socket (driver_app.py op_cli); a `daemon` verb reaches the tag's
                             daemon through the bundle's own cmux (cli/wire/socket.rs: the bundled cmux names its
                             app's session), so it needs no --session
  rpc {method, params}       cli `app call METHOD JSON` (cli/app/call.rs), the tour's own spelling for a method with
                             no verb (update-card.json)
  wait SECONDS               waitFor on the value the command changes (WAITS, below), else the settle barrier
                             alone; a wait of WIDE_WAIT_S or more widens the bounds to WIDE_MS
  optional REASON            the settle barrier alone (the tour says the step may not do its work, so no value is
                             sure to change) and a note with the reason
  shot, display, windows     dropped: every step records its settled snapshot, and pictures are tour.py's job

The waits a command gets, each the value it is sure to change (`changed` compares with the value read before the
step, driver_app.py wait_baseline):

  workspace new, split, close pane, pin       /topology/topology/workspaces
  new terminal tab, new page, close others    /topology/tab_count
  next tab                                    /topology/topology/focus/tab
  terminal write                              /terminals/list (the last 24 lines hash)
  sidebar toggle, palette toggle              /sidebar/hidden, /overlays/palette/open
  settings set or unset                       /settings/effectiveSha256, only when the step changes the document
                                              (the generator tracks it from the tour's settings and steps)
  a new browser tab                           /tabs/panes/0/tabs/0/loadState equals finished (the tour's first
                                              browser or page tab: the facet lists only panes with one)
  a hover on a new rail mark                  /overlays/hoverCard/target

Rewrites (REWRITES, TEXT_REWRITES, URL_REWRITES, DROPPED): a remote URL becomes a page of the loopback web fixture
($WEB, fixture.web); text a terminal runs never sleeps (a shell `sleep` that holds a state becomes `cat >/dev/null`,
and core's timed agent run waits on a line from `head -n 1` that a later step writes); host-dependent output
(uname, /System/Applications) becomes fixed text; a step that needs a method only a DEBUG build registers
(DEBUG_ONLY_METHODS) is dropped with its reason, as is a step that only makes sense after a dropped one. Every
rewrite and drop is in coverage.json and in the case's `untested`. A tour `features` list cannot reach the
launch (case-v1 has no launch-feature field): it is a precondition and a coverage.json `launch_gaps` entry.

Usage:
  gen_tours.py [--out DIR] [--tours DIR]           write the cases and coverage.json into DIR
  gen_tours.py [--out DIR] [--tours DIR] --check   exit 1 when DIR differs from a fresh generation
  gen_tours.py --selftest                          offline tests
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Any, Dict, List, Mapping, Optional, Sequence, Tuple

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
MEDIA = HERE.parent / "media"
for _path in (str(HERE), str(MEDIA)):
    if _path not in sys.path:
        sys.path.insert(0, _path)

import tour  # noqa: E402  (scripts/cmux-next/media/tour.py: load_tour, slug, STEP_KEYS)

GENERATOR = "scripts/cmux-next/oracle/gen_tours.py"
SUITE = "tours"
TASK = "p15-oracle-091"
TOURS_DIR = MEDIA / "tours"
DEFAULT_OUT = REPO / "tests" / "oracle" / "corpus" / SUITE
COVERAGE = "coverage.json"
CASE_SCHEMA = REPO / "schemas" / "oracle" / "case-v1.schema.json"
SCHEMA_REF = "../../../../schemas/oracle/case-v1.schema.json"
VIEWPORT = {"width": 1440, "height": 900}

# Waits. EXPECT_WAIT_MS is gen_actions.py's; a tour step that waited WIDE_WAIT_S or more (a page load, an agent
# start) gets WIDE_MS for its waitFor and its settle barrier.
WAIT_MS = 5000
WIDE_WAIT_S = 3
WIDE_MS = 10000

WORKSPACES = "/topology/topology/workspaces"
TAB_COUNT = "/topology/tab_count"
FOCUS_TAB = "/topology/topology/focus/tab"
TERMINALS = "/terminals/list"
SIDEBAR_HIDDEN = "/sidebar/hidden"
PALETTE_OPEN = "/overlays/palette/open"
SETTINGS_HASH = "/settings/effectiveSha256"
HOVER_TARGET = "/overlays/hoverCard/target"
FIRST_PAGE_LOAD = "/tabs/panes/0/tabs/0/loadState"
LOAD_FINISHED = "finished"

# `cmux action run NAME`: the value NAME is sure to change. An action missing here (a page, a panel, a menu, a
# directional focus that may have no neighbor) gets the settle barrier alone.
ACTION_WAITS = {
    "splitRight": WORKSPACES,
    "splitDown": WORKSPACES,
    "closePane": WORKSPACES,
    "palette.toggleTabPin": WORKSPACES,
    "newSurface": TAB_COUNT,
    "closeOtherTabsInPane": TAB_COUNT,
    "nextSurface": FOCUS_TAB,
    "toggleSidebar": SIDEBAR_HIDDEN,
    "commandPalette": PALETTE_OPEN,
}
# `cmux tab VERB`: new tabs.
TAB_VERBS = {"new-page": TAB_COUNT}

# App control methods only a DEBUG build registers (`#if DEBUG` in CmuxNextApp): the oracle runs the bench build.
DEBUG_ONLY_METHODS = {
    "debug.terminal.links": "CmuxNextApp/DebugTerminalLinks.swift registers it in DEBUG builds only",
    "debug.update_surfaces": "CmuxNextApp/Control/AppControl+Updates.swift registers it in DEBUG builds only",
}
# Steps that only make sense after a dropped step: (tour, 1-based step number) -> why. A number, not a title:
# main-pane has two steps titled "Focus the chat", and only the second goes.
DEPENDS_ON_LINKS = "it acts on the column a dropped debug.terminal.links step opens"
DROPPED = {
    ("main-pane", 8): DEPENDS_ON_LINKS,
    ("main-pane", 10): DEPENDS_ON_LINKS,
    ("main-pane", 11): "it only sets up the dropped debug.terminal.links step after it",
    ("main-pane", 12): "it only sets up the dropped debug.terminal.links step after it",
}

# Remote URLs -> a page of the loopback web fixture (scripts/cmux-next/oracle/webfixture.py).
URL_REWRITES = {
    "https://example.com": "$WEB/load.html",
    "https://example.org": "$WEB/other.html",
    "https://example.net": "$WEB/index.html",
}
URL = re.compile(r"\b(?:https?|wss?|ftp)://[^\s'\"]+")

# Terminal text -> (text, why). The tour's text sleeps or prints host-dependent output.
HOLD = "cat >/dev/null"
HOST_OUTPUT = ("host output (uname, the macOS app list) differs by host and OS; a golden baseline needs fixed text")
TEXT_REWRITES = {
    "clear; printf '\\033]9;4;3\\007'; sleep 900\r": (
        f"clear; printf '\\033]9;4;3\\007'; {HOLD}\r",
        "the shell holds the progress state by reading stdin, not by a timed wait"),
    ("clear; printf '\\033]7501;state=working\\033\\\\'; sleep 8; printf '\\033]7501;state=done\\033\\\\'; "
     "sleep 900\r"): (
        "clear; printf '\\033]7501;state=working\\033\\\\'; head -n 1 >/dev/null; "
        f"printf '\\033]7501;state=done\\033\\\\'; {HOLD}\r",
        "the agent state holds until a later step writes a line, not for 8 timed seconds; then the shell reads stdin"),
    "clear; uname -sm; echo; ls /System/Applications | head -12\r": (
        "clear; printf '%s\\n' 'cmux launch clip' infra docs-site app\r", HOST_OUTPUT),
}
SLEEP = re.compile(r"\bsleep\b")

# Tour steps replaced by another tour step: (tour, title) -> (step, why).
REWRITES = {
    ("core", "The agent finishes: done mark in the spinner's place"): (
        {"title": "The agent finishes: done mark in the spinner's place", "daemon": True,
         "cmux": ["workspace", "name:Agent", "screen", "current", "pane", "current", "tab", "current", "terminal",
                  "current", "write", "--text", "done\r"]},
        "the tour waited 8 timed seconds for the agent to finish; this line ends the agent's wait, so the done state "
        "follows the step, not a clock (its echo is the terminal change the step waits on)"),
}

CLI_NO_RECEIPT = "a tour step: the bundle's cmux prints no ActionEffect kind (driver_app.py op_cli)"
OPTIONAL_NOTE = "tour.py optional ({reason}): the settle barrier alone, since the step may not do its work"


class GenError(Exception):
    pass


# ------------------------------------------------------------------------------------------------ conversion


def leaf_settings(settings: Mapping[str, Any], prefix: str = "") -> List[Tuple[str, str]]:
    """A tour's `settings` document as (dotted key, CLI value text), in document order."""
    out: List[Tuple[str, str]] = []
    for key, value in settings.items():
        path = f"{prefix}{key}"
        if isinstance(value, dict):
            out.extend(leaf_settings(value, path + "."))
        elif isinstance(value, bool):
            out.append((path, "true" if value else "false"))
        elif isinstance(value, (int, float, str)):
            out.append((path, str(value)))
        else:
            raise GenError(f"settings {path}: {value!r} has no `cmux settings set` spelling")
    return out


def rewrite_text(argv: List[str], where: str) -> Tuple[List[str], List[str]]:
    """argv with TEXT_REWRITES and URL_REWRITES applied, and why each applied. A sleep or a remote URL left over
    is a GenError: the generator never writes either into a case."""
    out, notes = [], []
    for word in argv:
        if word in TEXT_REWRITES:
            word, why = TEXT_REWRITES[word]
            notes.append(why)
        for url in URL.findall(word):
            if url not in URL_REWRITES:
                raise GenError(f"{where}: {url} is not loopback and has no URL_REWRITES entry")
            word = word.replace(url, URL_REWRITES[url])
            notes.append(f"the tour's remote page is {URL_REWRITES[url]} (the loopback web fixture)")
        if SLEEP.search(word):
            raise GenError(f"{where}: {word!r} sleeps; add a TEXT_REWRITES entry that waits on a signal")
        out.append(word)
    return out, notes


class TourState:
    """What the generator knows of the app while it walks a tour: the config document the case's `settings`
    commands change, the hover target, and whether a browser or page tab was opened yet."""

    def __init__(self) -> None:
        self.document: Dict[str, str] = {}
        self.hover: Optional[str] = None
        self.paged = False

    def settings_change(self, argv: Sequence[str]) -> Optional[bool]:
        """Whether a `settings set|unset` argv changes the document (None: not a settings command)."""
        if len(argv) >= 3 and argv[0] == "settings" and argv[1] == "set" and len(argv) == 4:
            key, value = argv[2], argv[3]
            changed = self.document.get(key) != value
            self.document[key] = value
            return changed
        if len(argv) == 3 and argv[0] == "settings" and argv[1] == "unset":
            return self.document.pop(argv[2], None) is not None
        return None


def changed(pointer: str, max_ms: int) -> Dict[str, Any]:
    return {"pointer": pointer, "predicate": "changed", "maxMs": max_ms}


def wait_for(argv: Sequence[str], state: TourState, max_ms: int) -> Tuple[Optional[Dict[str, Any]], str]:
    """The waitFor of a cli step, or None and why the settle barrier alone ends it."""
    settings = state.settings_change(argv)
    if settings is not None:
        if settings:
            return changed(SETTINGS_HASH, max_ms), ""
        return None, "the setting already has this value, so the document does not change"
    if argv[:2] == ["workspace", "new"]:
        return changed(WORKSPACES, max_ms), ""
    if argv[:1] == ["workspace"] and "write" in argv:
        return changed(TERMINALS, max_ms), ""
    if argv[:2] == ["action", "run"] and len(argv) >= 3:
        pointer = ACTION_WAITS.get(argv[2])
        if pointer:
            return changed(pointer, max_ms), ""
        return None, f"no snapshot value {argv[2]} is sure to change"
    if argv[:2] == ["tab", "new-browser"]:
        if state.paged:
            return changed(TAB_COUNT, max_ms), ""
        state.paged = True
        return {"pointer": FIRST_PAGE_LOAD, "equals": LOAD_FINISHED, "maxMs": max_ms}, ""
    if argv[:1] == ["tab"] and len(argv) >= 2 and argv[1] in TAB_VERBS:
        state.paged = True
        return changed(TAB_VERBS[argv[1]], max_ms), ""
    if argv[:3] == ["app", "call", "debug.pointer_hover"]:
        target = argv[3] if len(argv) > 3 else "{}"
        if target != state.hover:
            state.hover = target
            return changed(HOVER_TARGET, max_ms), ""
        return None, "the pointer stays on the same mark, so the hover target does not change"
    return None, "no snapshot value this command is sure to change"


def step_id(number: int, title: str) -> str:
    return f"{number:02d}-{tour.slug(title)}".rstrip("-")


def cli_step(sid: str, argv: List[str], *, daemon: bool, wait: Optional[Dict[str, Any]], bound: Optional[int],
             notes: Sequence[str]) -> Dict[str, Any]:
    step: Dict[str, Any] = {"id": sid, "op": "cli",
                            "target": {"session": "current"} if daemon else {"window": "current"},
                            "args": {"argv": argv},
                            "expect": {"outcome": "ok", "noReceiptReason": CLI_NO_RECEIPT}}
    if wait:
        step["waitFor"] = wait
    if bound:
        step["settleMaxMs"] = bound
    if notes:
        step["note"] = "; ".join(notes)
    return step


def runner_step(sid: str, shot: bool, bound: Optional[int], note: str) -> Dict[str, Any]:
    step: Dict[str, Any] = {"id": sid, "op": "snapshot" if shot else "settle"}
    if bound:
        step["settleMaxMs"] = bound
    if note:
        step["note"] = note
    return step


def command_of(step: Mapping[str, Any]) -> Optional[List[str]]:
    """The tour step's cmux argv, an rpc as `app call`, or None for a wait-only step."""
    if step.get("cmux") is not None:
        return list(step["cmux"])
    rpc = step.get("rpc")
    if rpc is not None:
        return ["app", "call", rpc["method"], json.dumps(rpc.get("params") or {}, sort_keys=True,
                                                         separators=(",", ":"))]
    return None


def convert(path: Path) -> Tuple[Dict[str, Any], Dict[str, Any]]:
    """One tour as (case, its coverage.json entry)."""
    loaded = tour.load_tour(path)
    name = loaded["name"]
    state = TourState()
    steps: List[Dict[str, Any]] = []
    entry: Dict[str, Any] = {"tour": path.relative_to(REPO).as_posix() if path.is_relative_to(REPO) else path.name,
                             "case": f"{SUITE}/{name}", "tour_steps": len(loaded["steps"]), "waitFor": 0,
                             "settle": 0, "dropped": {}, "rewritten": {}, "launch_gaps": []}
    untested = ["pixels: the tour's screenshots and video (scripts/cmux-next/media/tour.py); a case compares model "
                "state, and its reviewed baseline stands in for each picture"]
    preconditions = ["private scratch config", "tagged bench build", "no unrelated app instance",
                     "the main window is 1440 x 900 pt"]
    for number, (key, value) in enumerate(leaf_settings(loaded.get("settings") or {}), 1):
        argv = ["settings", "set", key, value]
        wait, why = wait_for(argv, state, WAIT_MS)
        steps.append(cli_step(f"setup-{number:02d}-{tour.slug(key)}", argv, daemon=False, wait=wait, bound=None,
                              notes=["the tour launches with this setting; case-v1 has no launch config"]
                              + ([why] if why else [])))
    features = loaded.get("features") or []
    if features:
        gap = (f"the tour launches with the features {', '.join(features)} on; case-v1 has no launch-feature field, "
               "so the driver launches with them at their defaults")
        entry["launch_gaps"].append(gap)
        preconditions.append(f"the app launches with the features {', '.join(features)} on (CMUX_ENABLE_FEATURES)")
        untested.append(gap)
    for index, raw in enumerate(loaded["steps"]):
        number = index + 1
        title = raw["title"].strip()
        where = f"{path.name} step {number}"
        sid = step_id(number, title)
        drop = DROPPED.get((name, number))
        rpc = raw.get("rpc") or {}
        argv_raw = command_of(raw)
        method = rpc.get("method") or (argv_raw[2] if argv_raw and argv_raw[:2] == ["app", "call"] else None)
        if not drop and method in DEBUG_ONLY_METHODS:
            drop = f"{method}: {DEBUG_ONLY_METHODS[method]}, and the tours suite runs the bench build"
        if drop:
            entry["dropped"][sid] = drop
            untested.append(f"tour step {number} ({title}): {drop}")
            continue
        notes: List[str] = []
        if (name, title) in REWRITES:
            raw, why = REWRITES[(name, title)]
            entry["rewritten"][sid] = why
            notes.append(why)
        shot = raw.get("shot", True) is not False
        long_wait = float(raw.get("wait", tour.DEFAULT_WAIT)) >= WIDE_WAIT_S
        max_ms = WIDE_MS if long_wait else WAIT_MS
        bound = WIDE_MS if long_wait else None
        argv = command_of(raw)
        if argv is None:
            entry["settle"] += 1
            steps.append(runner_step(sid, shot, bound, "; ".join(notes)))
            continue
        argv, text_notes = rewrite_text(argv, where)
        if text_notes:
            entry["rewritten"].setdefault(sid, "; ".join(text_notes))
            notes.extend(text_notes)
        if raw.get("optional"):
            # The value the step would change still moves the generator's view of the app.
            wait_for(argv, state, max_ms)
            wait = None
            notes.append(OPTIONAL_NOTE.format(reason=raw["optional"].strip()))
        else:
            wait, why = wait_for(argv, state, max_ms)
            if why:
                notes.append(why)
        entry["waitFor" if wait else "settle"] += 1
        steps.append(cli_step(sid, argv, daemon=bool(raw.get("daemon")), wait=wait, bound=bound, notes=notes))
    web = "$WEB" in json.dumps(steps)
    if web:
        preconditions.append("the loopback web fixture server ($WEB, webfixture.py)")
    fixture: Dict[str, Any] = {"seed": f"tours-{name}-v1", "network": "offline", "clock": "fixed", "agent": "mock"}
    if web:
        fixture["web"] = True
    case = {
        "$schema": SCHEMA_REF,
        "corpusVersion": 1,
        "id": name,
        "suite": SUITE,
        "title": f"Tour: {loaded['title']}"[:200],
        "priority": "P2",
        "surface": "cmux-next-native",
        "source": {"repo": "manaflow-ai/cmux", "ref": "$RUN", "artifact": "$RUN"},
        "environment": {"viewport": dict(VIEWPORT)},
        "fixture": fixture,
        "preconditions": preconditions,
        "requires": ["gui"],
        "platforms": ["mac"],
        "steps": steps,
        "invariants": [
            "each step's settled snapshot is the model state of the tour's picture of that step",
            "no step waits on a clock: each ends on its waitFor value or the settle barrier",
        ],
        "teardown": ["quit the tagged app the run started", "verify its debug socket is gone"],
        "untested": untested,
    }
    entry["steps"] = len(steps)
    return case, entry


def generate(tours_dir: Path) -> Dict[str, Any]:
    """Every file of the suite: one case per tour and coverage.json."""
    paths = sorted(tours_dir.glob("*.json"))
    if not paths:
        raise GenError(f"{tours_dir}: no tours")
    files: Dict[str, Any] = {}
    tours: Dict[str, Any] = {}
    for path in paths:
        try:
            case, entry = convert(path)
        except tour.TourError as error:
            raise GenError(str(error)) from None
        if f"{case['id']}.json" in files:
            raise GenError(f"{path.name}: case {case['id']} is generated twice")
        files[f"{case['id']}.json"] = case
        tours[case["id"]] = entry
    files[COVERAGE] = {
        "generator": GENERATOR,
        "suite": SUITE,
        "task": TASK,
        "tours": "scripts/cmux-next/media/tours",
        "total": len(tours),
        "covered": len(tours),
        "excluded": {},
        "missing": [],
        "verdicts": "not run",
        "cases": len(tours),
        "steps": {key: sum(t[key] for t in tours.values()) for key in ("waitFor", "settle")},
        "launch_gaps": {k: t["launch_gaps"] for k, t in tours.items() if t["launch_gaps"]},
        "by_tour": tours,
    }
    return files


# ------------------------------------------------------------------------------------------------ files


def render(value: Any) -> str:
    return json.dumps(value, indent=2, ensure_ascii=False) + "\n"


def owned_files(out: Path) -> List[str]:
    """The case files the last generation wrote (from its coverage.json)."""
    path = out / COVERAGE
    if not path.is_file():
        return []
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except ValueError:
        return []
    return sorted(f"{case}.json" for case in (data.get("by_tour") or {}))


def drift(out: Path, files: Mapping[str, Any]) -> List[str]:
    problems = []
    for name, value in sorted(files.items()):
        path = out / name
        if not path.is_file():
            problems.append(f"{name}: missing")
        elif path.read_text(encoding="utf-8") != render(value):
            problems.append(f"{name}: differs from a fresh generation")
    for name in owned_files(out):
        if name not in files and (out / name).exists():
            problems.append(f"{name}: generated earlier, its tour is gone")
    return problems


def write(out: Path, files: Mapping[str, Any]) -> Tuple[int, int]:
    """Writes changed files and removes the cases of tours that are gone; refuses to overwrite a case file it did
    not write."""
    out.mkdir(parents=True, exist_ok=True)
    owned = set(owned_files(out))
    for name in files:
        if name != COVERAGE and (out / name).exists() and name not in owned:
            raise GenError(f"{out / name}: exists and was not written by this generator")
    written = 0
    for name, value in sorted(files.items()):
        path = out / name
        text = render(value)
        if not path.is_file() or path.read_text(encoding="utf-8") != text:
            path.write_text(text, encoding="utf-8")
            written += 1
    removed = 0
    for name in sorted(owned - set(files)):
        (out / name).unlink(missing_ok=True)
        removed += 1
    return written, removed


# ------------------------------------------------------------------------------------------------ self tests


def validation_errors(case: Mapping[str, Any]) -> List[str]:
    """The corpus checks `oracle.py check` runs on one case: the case-v1 schema (normalize.validate) and the
    semantic rules (oracle.check_case)."""
    import normalize
    import oracle
    schema = json.loads(CASE_SCHEMA.read_text(encoding="utf-8"))
    errors = list(normalize.validate(case, schema))
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / SUITE / f"{case['id']}.json"
        path.parent.mkdir()
        path.write_text(render(case), encoding="utf-8")
        loaded, error = oracle.load_case(path, f"{SUITE}/{case['id']}")
        if error:
            return errors + [error]
        errors.extend(oracle.check_case(loaded, oracle.mutation_operations()))
    return errors


def tour_file(directory: Path, name: str, data: Mapping[str, Any]) -> Path:
    path = directory / f"{name}.json"
    path.write_text(json.dumps(data), encoding="utf-8")
    return path


class GenToursSelfTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.files = generate(TOURS_DIR)
        cls.cases = {k[:-5]: v for k, v in cls.files.items() if k != COVERAGE}

    def test_every_tour_is_a_case(self) -> None:
        tours = sorted(p.stem for p in TOURS_DIR.glob("*.json"))
        self.assertEqual(sorted(self.cases), [tour.slug(t) for t in tours])
        self.assertEqual(len(tours), 23, "the spec's tours suite is the 23 media tours")
        coverage = self.files[COVERAGE]
        self.assertEqual((coverage["covered"], coverage["total"]), (23, 23))

    def test_cases_pass_the_corpus_checks(self) -> None:
        for name, case in self.cases.items():
            with self.subTest(case=name):
                self.assertEqual(validation_errors(case), [])

    def test_no_case_waits_on_a_clock(self) -> None:
        for name, case in self.cases.items():
            text = json.dumps(case)
            with self.subTest(case=name):
                self.assertIsNone(SLEEP.search(text), "a case never sleeps, in the runner or a shell")
                for step in case["steps"]:
                    self.assertNotIn("wait", step)
                    self.assertIn(step["op"], ("cli", "snapshot", "settle"))

    def test_no_remote_url(self) -> None:
        for name, case in self.cases.items():
            with self.subTest(case=name):
                self.assertEqual(URL.findall(json.dumps(case)), [])
                self.assertEqual("$WEB" in json.dumps(case["steps"]), case["fixture"].get("web", False))

    def test_core_is_mapped(self) -> None:
        core = {s["id"]: s for s in self.cases["core"]["steps"]}
        self.assertEqual(core["01-launch"]["op"], "snapshot")
        self.assertEqual(core["02-new-workspace"]["waitFor"], changed(WORKSPACES, WAIT_MS))
        self.assertEqual(core["05-split-right"]["waitFor"], changed(WORKSPACES, WAIT_MS))
        self.assertEqual(core["07-new-terminal-tab"]["waitFor"], changed(TAB_COUNT, WAIT_MS))
        browser = core["08-browser-tab"]
        self.assertEqual(browser["args"]["argv"], ["tab", "new-browser", "--url", "$WEB/load.html"])
        self.assertEqual(browser["waitFor"], {"pointer": FIRST_PAGE_LOAD, "equals": LOAD_FINISHED, "maxMs": WIDE_MS})
        self.assertEqual(browser["settleMaxMs"], WIDE_MS)
        self.assertEqual(core["09-hide-the-sidebar"]["waitFor"], changed(SIDEBAR_HIDDEN, WAIT_MS))
        self.assertNotIn("waitFor", core["12-notifications-panel"], "an optional step ends on the settle barrier")
        self.assertIn("optional", core["12-notifications-panel"]["note"])
        self.assertEqual(core["03-type-in-the-terminal"]["target"], {"session": "current"})
        self.assertEqual(core["03-type-in-the-terminal"]["waitFor"], changed(TERMINALS, WAIT_MS))
        finish = core["17-the-agent-finishes-done-mark-in-the-spin"]
        self.assertEqual(finish["args"]["argv"][-2:], ["--text", "done\r"])
        self.assertEqual(finish["waitFor"], changed(TERMINALS, WAIT_MS))
        self.assertIn("17-the-agent-finishes-done-mark-in-the-spin", self.files[COVERAGE]["by_tour"]["core"]["rewritten"])
        self.assertTrue(self.cases["core"]["fixture"]["web"])

    def test_rpc_becomes_app_call(self) -> None:
        home = {s["id"]: s for s in self.cases["home"]["steps"]}
        dark = home["04-dark"]
        self.assertEqual(dark["args"]["argv"], ["app", "call", "debug.appearance", '{"mode":"dark"}'])
        self.assertNotIn("waitFor", dark)
        rail = [s for s in self.cases["rail-card-top"]["steps"] if "pointer_hover" in json.dumps(s)]
        self.assertEqual(rail[0]["waitFor"], changed(HOVER_TARGET, WAIT_MS))
        self.assertNotIn("waitFor", rail[1], "the second hover on the same mark changes no target")

    def test_settings_waits_follow_the_document(self) -> None:
        glass = self.cases["glass"]["steps"]
        setup = [s for s in glass if s["id"].startswith("setup-")]
        self.assertEqual([s["args"]["argv"][2:] for s in setup],
                         [["appearance.background", "hokusai-great-wave"], ["appearance.theme", "Clay Orange"]])
        self.assertTrue(all(s["waitFor"] == changed(SETTINGS_HASH, WAIT_MS) for s in setup))
        launch = glass[len(setup)]
        self.assertEqual((launch["id"], launch["op"], launch["settleMaxMs"]), ("01-launch-over-art", "snapshot", WIDE_MS))
        state = TourState()
        self.assertEqual(wait_for(["settings", "set", "a.b", "x"], state, 1)[0], changed(SETTINGS_HASH, 1))
        self.assertIsNone(wait_for(["settings", "set", "a.b", "x"], state, 1)[0])
        self.assertEqual(wait_for(["settings", "unset", "a.b"], state, 1)[0], changed(SETTINGS_HASH, 1))
        self.assertIsNone(wait_for(["settings", "unset", "a.b"], state, 1)[0])

    def test_debug_only_steps_are_dropped_with_a_reason(self) -> None:
        by_tour = self.files[COVERAGE]["by_tour"]
        main = by_tour["main-pane"]
        self.assertEqual(sorted(main["dropped"]), ["07-a-link-clicked-in-the-lone-chat-the-chat", "08-focus-the-chat-again",
                                                   "09-a-second-link-opens-as-a-tab-in-the-same",
                                                   "10-closing-the-right-column-again-the-chat",
                                                   "11-main-pane-off-debug-override-a-link-from",
                                                   "12-focus-the-chat", "13-with-main-pane-off-the-link-is-a-tab-in"])
        self.assertEqual([s["id"] for s in self.cases["main-pane"]["steps"]][-1], "06-focus-the-chat")
        self.assertTrue(all(main["dropped"].values()))
        update = [s["args"]["argv"] for s in self.cases["update-card"]["steps"] if s["op"] == "cli"]
        self.assertFalse(any("debug.update_surfaces" in argv for argv in update))
        self.assertEqual(len(by_tour["update-card"]["dropped"]), 2)
        for name, case in self.cases.items():
            dropped = by_tour[name]["dropped"]
            ids = {s["id"] for s in case["steps"]}
            with self.subTest(case=name):
                self.assertFalse(ids & set(dropped))
                self.assertEqual(by_tour[name]["tour_steps"], len(dropped) + sum(
                    1 for s in case["steps"] if not s["id"].startswith("setup-")))
                self.assertEqual(sum(1 for u in case["untested"] if u.startswith("tour step ")), len(dropped))

    def test_launch_features_are_a_reported_gap(self) -> None:
        self.assertEqual(sorted(self.files[COVERAGE]["launch_gaps"]), ["host-pressure"])
        self.assertTrue(any("hostPressure" in p for p in self.cases["host-pressure"]["preconditions"]))

    def test_refuses_a_sleep_and_a_remote_url(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tours = Path(tmp)
            tour_file(tours, "a", {"title": "A", "steps": [{"title": "Launch", "wait": 2}, {
                "title": "Sleep", "daemon": True, "cmux": ["workspace", "current", "write", "--text", "sleep 3\r"]}]})
            with self.assertRaisesRegex(GenError, "sleeps"):
                generate(tours)
            tour_file(tours, "a", {"title": "A", "steps": [{"title": "Launch"}, {
                "title": "Web", "cmux": ["tab", "new-browser", "--url", "https://cmux.com"]}]})
            with self.assertRaisesRegex(GenError, "not loopback"):
                generate(tours)

    def test_write_check_and_removal(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tours, out = Path(tmp) / "tours", Path(tmp) / "out"
            tours.mkdir()
            tour_file(tours, "one", {"title": "One", "steps": [{"title": "Launch"}]})
            tour_file(tours, "two", {"title": "Two", "steps": [{"title": "Launch", "shot": False}]})
            files = generate(tours)
            self.assertEqual(write(out, files), (3, 0))
            self.assertEqual(drift(out, files), [])
            self.assertEqual(json.loads((out / "two.json").read_text())["steps"][0]["op"], "settle")
            (tours / "two.json").unlink()
            files = generate(tours)
            self.assertEqual(drift(out, files), ["coverage.json: differs from a fresh generation",
                                                 "two.json: generated earlier, its tour is gone"])
            self.assertEqual(write(out, files), (1, 1))
            self.assertFalse((out / "two.json").exists())
            (out / "stray.json").write_text("{}")
            tour_file(tours, "stray", {"title": "Stray", "steps": [{"title": "Launch"}]})
            with self.assertRaisesRegex(GenError, "not written by this generator"):
                write(out, generate(tours))

    def test_checked_in_suite_is_fresh(self) -> None:
        self.assertEqual(drift(DEFAULT_OUT, self.files), [])


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT, help="the suite directory (default: the corpus)")
    parser.add_argument("--tours", type=Path, default=TOURS_DIR, help="the media tours directory")
    parser.add_argument("--check", action="store_true", help="exit 1 when --out differs from a fresh generation")
    parser.add_argument("--selftest", action="store_true", help="run the offline self tests")
    args = parser.parse_args(argv)
    if args.selftest:
        suite = unittest.defaultTestLoader.loadTestsFromTestCase(GenToursSelfTest)
        return 0 if unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful() else 1
    try:
        files = generate(args.tours)
        if args.check:
            problems = drift(args.out, files)
            for problem in problems:
                print(f"gen_tours: {args.out / problem}")
            return 1 if problems else 0
        written, removed = write(args.out, files)
    except GenError as error:
        print(f"gen_tours: {error}", file=sys.stderr)
        return 2
    coverage = files[COVERAGE]
    print(f"gen_tours: {coverage['cases']} cases ({coverage['steps']['waitFor']} waitFor, "
          f"{coverage['steps']['settle']} settle), {written} written, {removed} removed, into {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
