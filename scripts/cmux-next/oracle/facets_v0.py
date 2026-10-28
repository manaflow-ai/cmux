#!/usr/bin/env python3
"""v0 facets: oracle snapshots from methods that exist at the push base (p15-oracle-006).

Spec: plans/cmux-next/chrome-parity/p15-oracle.md, section 3A ("v0 facets") and task 006. Stdlib only, safe
under `python3 -I`. The v1 facets come from `debug.oracle.snapshot` and `oracle-state` (tasks 021, 030), which
the push base does not have. The v0 facets read only methods the push base has, so the oracle captures any SHA
of the push with no source change, including the SHAs from before the new facets land:

| Facet | Push-base methods | Left out (no push-base method gives it) |
| --- | --- | --- |
| topology | `snapshot.get` | |
| daemon | `session.snapshot`, `settings.snapshot` | `journalHead`, `oracle` |
| focus | `debug.focus`, `snapshot.get` (window key to public id, the active window) | `keyWindow`, `windows[].hasSheet`, `windows[].topPage` |
| settings | `settings.snapshot` | `nonDefaultKeys`, `motion` |
| invariants | `debug.desync` (`check: true`), `debug.focus`, `snapshot.get` (window keys) | |
| switches | `debug.tunables` (`list`, `changed: true`) | `hits` |

Every other facet is not-comparable at v0, with the v1 task that gives it. `FIELDS` below names, for each kept
field, the push-base method and the JSON pointer into its reply; `check` proves with `git grep` that each method
exists at a SHA. `debug.window_snapshot` (named by the spec) is not used: its reply is an image and window
numbers, no model state, and it writes a PNG per call.

The v0 schema is the v1 schema (schemas/oracle/snapshot-v1.schema.json) with the left-out fields removed and
each kept field's `x-oracle-source` set to its push-base method. Every other annotation (volatile, order, id
kinds, precision, rewrite, time) is the v1 one, so normalize.py canonicalizes a v0 snapshot by the same rules.
A v0 snapshot is compared only with another v0 snapshot: the base and the head of a diff both use v0 facets
until both sides have `debug.oracle.snapshot` (task 202 picks; the drivers take `facet_source`).

Chrome analog: a layout test with no `-expected.txt` for a newer platform falls back to the generic baseline
(third_party/blink/tools/blinkpy/web_tests/port/base.py `baseline_search_path`); here a SHA without the new
providers falls back to the facets its own methods give, and says what it leaves out.

Usage:
  facets_v0.py check [--sha SHA]...          every v0 method at each SHA (default: the push base and HEAD)
  facets_v0.py schema [--out FILE]           print the derived v0 schema
  facets_v0.py capture --product daemon --binary B [--corpus DIR] [--suite S] [--repeat N] --out DIR
  facets_v0.py capture --product app --tag TAG [--sha SHA] [--corpus DIR] [--suite S] --out DIR    (fleet Mac)
                                             run the corpus N times (default 2) at one build; equal hashes or exit 1
"""

from __future__ import annotations

import argparse
import copy
import functools
import hashlib
import json
import platform as platform_mod
import re
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Dict, Iterable, List, Mapping, Optional, Sequence, Tuple

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
SNAPSHOT_SCHEMA = REPO / "schemas" / "oracle" / "snapshot-v1.schema.json"
TASK = "p15-oracle-006"
SCHEMA_ID = "cmux.oracle.snapshot/v1"
# The merge-base of perf/chrome-parity and feat-cmux-next: the checkout the p15 spec was verified at.
PUSH_BASE = "772cdfc45ac399e8557215eb68e720bb3c51a66b"
SHA_RE = re.compile(r"^[0-9a-f]{40}$")
DAEMON_SELECTORS = {"machine": "current", "session": "current"}


class V0Error(Exception):
    """A reply that does not have the v0 shape, or a table that does not fit the v1 schema."""


def sibling(module: str) -> Any:
    if str(HERE) not in sys.path:
        sys.path.insert(0, str(HERE))
    return __import__(module)


# ---------------------------------------------------------------------------------------------------------
# Push-base methods and the v0 field table


@dataclass(frozen=True)
class Method:
    """A push-base method: the product that answers it, the params a capture sends, and where `git grep`
    finds its registration (a literal under a pathspec)."""

    product: str
    params: Mapping[str, Any]
    pathspec: str
    literal: str


APP_SOURCES = "Packages/macOS/CmuxNext/Sources"
DAEMON_SPEC = "cmux-tui/spec/resource-operations-v2.json"
METHODS: Dict[str, Method] = {
    "snapshot.get": Method("app", {}, APP_SOURCES, '.snapshot("snapshot.get")'),
    "debug.focus": Method("app", {}, APP_SOURCES, '"debug.focus"'),
    "debug.desync": Method("app", {"check": True}, APP_SOURCES, '"debug.desync"'),
    "debug.tunables": Method("app", {"action": "list", "changed": True}, APP_SOURCES, '"debug.tunables"'),
    "session.snapshot": Method("daemon", DAEMON_SELECTORS, DAEMON_SPEC, '"session.snapshot"'),
    "settings.snapshot": Method("daemon", DAEMON_SELECTORS, DAEMON_SPEC, '"settings.snapshot"'),
}


@dataclass(frozen=True)
class Field:
    """A kept v1 field: the push-base methods its value comes from and the pointer into their reply.
    `subtree` keeps the v1 schema below it as is (its sources already name these methods)."""

    methods: Tuple[str, ...]
    path: str
    subtree: bool = False
    derive: Optional[str] = None


def F(methods: str, path: str, **extra: Any) -> Field:
    return Field(tuple(m.strip() for m in methods.split("+")), path, **extra)


# Keys are v1 pointers inside the facet ("" is the facet; "*" is an array item). A field that is not here is
# left out of the v0 schema; a container is listed before its members.
FIELDS: Dict[str, Dict[str, Field]] = {
    "topology": {"": F("snapshot.get", "/", subtree=True)},
    "daemon": {
        "": F("session.snapshot + settings.snapshot", "/"),
        "session": F("session.snapshot", "/", subtree=True),
        "settings": F("settings.snapshot", "/", subtree=True),
    },
    "focus": {
        "": F("debug.focus + snapshot.get", "/"),
        "windows": F("debug.focus", "/windows"),
        "windows/*/id": F("debug.focus + snapshot.get", "/windows/*/id"),
        "windows/*/isKey": F("debug.focus", "/windows/*/is_key"),
        # `FocusResponderClassifier.describe` is `<kind>` or `<kind>:<pane>`; the pane is model.resolvedPane.
        "windows/*/responder": F("debug.focus", "/windows/*/appkit/classified", derive="kind"),
        "windows/*/layoutFocus": F("debug.focus", "/windows/*/layout_focused_pane"),
        "windows/*/ghosttyFocused": F("debug.focus", "/ghostty_focused_tabs"),
        "windows/*/childPage": F("debug.focus", "/windows/*/appkit/child_window_page"),
        "windows/*/model": F("debug.focus", "/windows/*/model"),
        "windows/*/model/pane": F("debug.focus", "/windows/*/model/pane"),
        "windows/*/model/target": F("debug.focus", "/windows/*/model/target"),
        "windows/*/model/resolved": F("debug.focus", "/windows/*/model/resolved"),
        "windows/*/model/resolvedPane": F("debug.focus", "/windows/*/model/resolved_pane"),
        "windows/*/model/resolvedTab": F("debug.focus", "/windows/*/model/resolved_tab"),
        "windows/*/model/overlays": F("debug.focus", "/windows/*/model/overlays"),
        "windows/*/model/dragging": F("debug.focus", "/windows/*/model/dragging"),
        "windows/*/model/windowKey": F("debug.focus", "/windows/*/model/window_key"),
        "windows/*/model/sidebarHidden": F("debug.focus", "/windows/*/model/sidebar_hidden"),
        "windows/*/model/generation": F("debug.focus", "/windows/*/model/generation"),
        "windows/*/consistent": F("debug.focus", "/windows/*/consistent"),
        "activeWindow": F("snapshot.get", "/topology/focus/window"),
        "paletteOpen": F("debug.focus", "/context/palette_open"),
        "context": F("debug.focus", "/context"),
        "context/terminal": F("debug.focus", "/context/terminal_focused"),
        "context/browser": F("debug.focus", "/context/browser_focused"),
        "context/agent": F("debug.focus", "/context/agent_focused"),
    },
    "settings": {
        "": F("settings.snapshot", "/"),
        "effectiveSha256": F("settings.snapshot", "/effective", derive="sha256"),
    },
    "invariants": {
        "": F("debug.desync + debug.focus + snapshot.get", "/"),
        "violations": F("debug.desync", "/check/violations/*/invariant"),
        # `WindowInvariants.problems` names windows by model key: each id becomes `<kind>` (problem_class).
        "windowInvariants": F("debug.focus + snapshot.get", "/window_invariants", derive="problem class"),
        "checks": F("debug.desync", "/checks"),
    },
    "switches": {
        "": F("debug.tunables", "/"),
        "arms": F("debug.tunables", "/tunables"),
    },
}
# Fields only the v0 schema marks volatile: their presence races the capture, because the push base has no
# barrier for them. Keys are paths of properties in the v1 facet schema.
V0_VOLATILE: Dict[str, Dict[str, str]] = {
    "daemon/session/terminals/*/extra": {
        "reason": "holds last_output only, which appears when the shell's first output reaches the daemon, on the "
                  "shell's own schedule; the push base has no terminal-output settle (debug.oracle.settle, "
                  "p15-oracle-029)",
        "task": TASK},
}
# Step receipts (driver_cli.py p15-oracle-048, driver_mcp.py p15-oracle-209, driver_tui.py p15-oracle-234): the
# runner's record of one `cmux` or MCP call or `cmux-tui attach` frame, read from the shipped binary at any SHA,
# not from a facet method. v0 keeps their v1 schema.
STEP_RECEIPTS = frozenset({"cli", "mcp", "tui"})
PRODUCT_FACETS: Dict[str, Tuple[str, ...]] = {
    "app": ("topology", "daemon", "focus", "settings", "invariants", "switches"),
    # The daemon product's settings state is daemon.settings; the settings facet is the app's applied config.
    "daemon": ("daemon",),
}


def facet_methods(facet: str) -> Tuple[str, ...]:
    return tuple(dict.fromkeys(m for field in FIELDS[facet].values() for m in field.methods))


def methods_for(facets: Iterable[str], product: str) -> List[str]:
    """The push-base methods a capture of `facets` on `product` reads, each once, in table order."""
    wanted = {m for f in facets if f in FIELDS and f in PRODUCT_FACETS.get(product, ()) for m in facet_methods(f)}
    return [name for name in METHODS if name in wanted]


# ---------------------------------------------------------------------------------------------------------
# The v0 schema


def load_v1(path: Path = SNAPSHOT_SCHEMA) -> Dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def _source(field: Field, v1: Mapping[str, Any]) -> Dict[str, Any]:
    out: Dict[str, Any] = {"method": " + ".join(field.methods), "path": field.path,
                           "from": f"v1 {v1.get('method')} {v1.get('path')}"}
    if field.derive:
        out["derive"] = field.derive
    return out


def _subtree_methods(node: Any) -> Iterable[str]:
    if isinstance(node, dict):
        source = node.get("x-oracle-source")
        if isinstance(source, dict) and isinstance(source.get("method"), str):
            yield from (m.strip() for m in source["method"].split("+"))
        for key, value in node.items():
            if key != "x-oracle-source":
                yield from _subtree_methods(value)
    elif isinstance(node, list):
        for item in node:
            yield from _subtree_methods(item)


def _prune(node: Dict[str, Any], prefix: str, fields: Mapping[str, Field], seen: set, facet: str) -> Dict[str, Any]:
    """The object schema `node` with only the listed members, each with its push-base source."""
    out = {k: copy.deepcopy(v) for k, v in node.items() if k not in ("properties", "required")}
    kept: Dict[str, Any] = {}
    for name, child in node.get("properties", {}).items():
        at = f"{prefix}/{name}" if prefix else name
        field = fields.get(at)
        if field is None:
            stray = [key for key in fields if key.startswith(at + "/")]
            if stray:
                raise V0Error(f"{facet}: {stray[0]} is listed but its container {at} is not")
            continue
        seen.add(at)
        kept[name] = _keep(child, at, field, fields, seen, facet)
    out["properties"] = kept
    out["required"] = [name for name in node.get("required", ()) if name in kept]
    return out


def _keep(child: Dict[str, Any], at: str, field: Field, fields: Mapping[str, Field], seen: set, facet: str) -> Dict[str, Any]:
    v1_source = child.get("x-oracle-source", {})
    if field.subtree:
        node = copy.deepcopy(child)
        foreign = sorted(set(_subtree_methods({k: v for k, v in node.items() if k != "x-oracle-source"}))
                         - set(field.methods) - {"oracle.runner"})
        if foreign:
            raise V0Error(f"{facet}/{at}: the kept subtree names {foreign}, which v0 does not read")
    elif "properties" in child:
        node = _prune(child, at, fields, seen, facet)
    elif isinstance(child.get("items"), dict) and "properties" in child["items"]:
        node = copy.deepcopy({k: v for k, v in child.items() if k != "items"})
        node["items"] = _prune(child["items"], f"{at}/*", fields, seen, facet)
    else:
        node = copy.deepcopy(child)
    node["x-oracle-source"] = _source(field, v1_source)
    return node


def derive_schema(v1: Mapping[str, Any]) -> Dict[str, Any]:
    """The v0 schema: v1 with the facets cut to the fields of FIELDS. Raises V0Error when the table names a
    field the v1 schema does not have, or a kept subtree reads a method v0 does not read."""
    doc = copy.deepcopy(dict(v1))
    doc["$id"] = str(doc.get("$id", "")) + "#v0"
    doc["description"] = f"v0 facets (scripts/cmux-next/oracle/facets_v0.py, {TASK}): " + str(doc.get("description", ""))
    facets = doc["properties"]["facets"]["properties"]
    unknown = sorted(set(FIELDS) - set(facets))
    if unknown:
        raise V0Error(f"FIELDS names facets the v1 schema does not have: {unknown}")
    for name, node in facets.items():
        if "oneOf" not in node and node.get("x-oracle-source", {}).get("method") in STEP_RECEIPTS:
            continue
        branches = node.get("oneOf") or []
        if len(branches) != 2 or branches[1] != {"$ref": "#/definitions/notComparable"}:
            raise V0Error(f"{name}: a v1 facet is oneOf [its object, notComparable]")
        if name not in FIELDS:
            facets[name] = {"description": node.get("description", ""), "oneOf": [branches[1]],
                            "x-oracle-source": {"method": "oracle.runner", "path": f"/facets/{name}"}}
            continue
        fields = FIELDS[name]
        for field in fields.values():
            missing = [m for m in field.methods if m not in METHODS]
            if missing:
                raise V0Error(f"{name}: {missing} are not push-base methods (METHODS)")
        seen: set = set()
        body = _keep(branches[0], "", fields[""], fields, seen, name)
        seen.add("")
        unseen = sorted(set(fields) - seen)
        if unseen:
            raise V0Error(f"{name}: FIELDS lists {unseen}, which the v1 facet does not have")
        root = body.pop("x-oracle-source")
        facets[name] = {"description": node.get("description", ""), "oneOf": [body, branches[1]],
                        "x-oracle-source": {**root, "v0": root["method"], "provider": "facets_v0.py", "task": TASK}}
    for path, volatile in V0_VOLATILE.items():
        node = facets[path.split("/", 1)[0]]["oneOf"][0]
        for part in path.split("/")[1:]:
            node = node["items"] if part == "*" else node["properties"][part]
        node["x-oracle-volatile"] = dict(volatile)
    return doc


@functools.lru_cache(maxsize=4)
def v0_schema(path: str = str(SNAPSHOT_SCHEMA)) -> Any:
    """The linted v0 normalize.Schema (README contract included)."""
    normalize = sibling("normalize")
    return normalize.Schema(derive_schema(load_v1(Path(path))), origin="snapshot-v1 (v0 facets)", contract=True)


# ---------------------------------------------------------------------------------------------------------
# Facets from replies


def _integral(value: Any, where: str) -> int:
    """The control socket sends Swift Doubles; an integer field holds an integral number."""
    if isinstance(value, bool) or not isinstance(value, (int, float)) or float(value) != int(value):
        raise V0Error(f"{where}: {value!r} is not an integer")
    return int(value)


def _get(reply: Mapping[str, Any], key: str, where: str) -> Any:
    if not isinstance(reply, Mapping) or key not in reply:
        raise V0Error(f"{where}: the reply has no {key!r}")
    return reply[key]


def topology_facet(snapshot_get: Mapping[str, Any]) -> Dict[str, Any]:
    """`snapshot.get` as is; the runner sends no caller params, so `caller` and `beside` are absent."""
    return {k: v for k, v in snapshot_get.items() if k not in ("caller", "beside")}


def daemon_facet(session: Mapping[str, Any], settings: Mapping[str, Any], v1: Mapping[str, Any]) -> Dict[str, Any]:
    """`session.snapshot` and `settings.snapshot` after the v1 capture rules (`derive: sha256`); no journal
    head and no oracle-state extras (task 021 adds those)."""
    check = sibling("check_snapshot_schema")
    node = v1["properties"]["facets"]["properties"]["daemon"]["oneOf"][0]["properties"]
    return {"session": check.capture(v1, node["session"], session),
            "settings": check.capture(v1, node["settings"], settings)}


def settings_facet(settings: Mapping[str, Any]) -> Dict[str, Any]:
    check = sibling("check_snapshot_schema")
    return {"effectiveSha256": check.sha256_of(_get(settings, "effective", "settings.snapshot"))}


def focus_facet(debug_focus: Mapping[str, Any], snapshot_get: Mapping[str, Any]) -> Dict[str, Any]:
    """`debug.focus` per window, with each window's model key replaced by its public id from `snapshot.get`."""
    topology = _get(snapshot_get, "topology", "snapshot.get")
    public = {w["key"]: w["id"] for w in topology.get("windows") or () if isinstance(w, Mapping)}
    focused = list(_get(debug_focus, "ghostty_focused_tabs", "debug.focus"))
    context = _get(debug_focus, "context", "debug.focus")
    windows = []
    for index, window in enumerate(_get(debug_focus, "windows", "debug.focus")):
        where = f"debug.focus /windows/{index}"
        model = _get(window, "model", where)
        appkit = _get(window, "appkit", where)
        # Topology tabs are "<tab id>:<kind>" (DebugFocus.window); Ghostty focus is per tab id.
        own = {str(tab).rsplit(":", 1)[0] for pane in window.get("topology") or () for tab in pane.get("tabs") or ()}
        if window.get("id") not in public:
            raise V0Error(f"{where}: window {window.get('id')!r} is not in snapshot.get (read both at one settled point)")
        windows.append({
            "id": public[window["id"]],
            "isKey": _get(window, "is_key", where),
            "responder": str(_get(appkit, "classified", where)).split(":", 1)[0],
            "layoutFocus": window.get("layout_focused_pane"),
            "ghosttyFocused": sorted(tab for tab in focused if tab in own),
            "childPage": appkit.get("child_window_page"),
            "model": {
                "pane": model.get("pane"),
                "target": _get(model, "target", where),
                "resolved": _get(model, "resolved", where),
                "resolvedPane": model.get("resolved_pane"),
                "resolvedTab": model.get("resolved_tab"),
                "overlays": list(_get(model, "overlays", where)),
                "dragging": _get(model, "dragging", where),
                "windowKey": _get(model, "window_key", where),
                "sidebarHidden": _get(model, "sidebar_hidden", where),
                "generation": _integral(_get(model, "generation", where), f"{where}/model/generation"),
            },
            "consistent": _get(window, "consistent", where),
        })
    focus = topology.get("focus") or {}
    return {
        "windows": windows,
        "activeWindow": focus.get("window"),
        "paletteOpen": _get(context, "palette_open", "debug.focus /context"),
        "context": {
            "terminal": _get(context, "terminal_focused", "debug.focus /context"),
            "browser": _get(context, "browser_focused", "debug.focus /context"),
            "agent": _get(context, "agent_focused", "debug.focus /context"),
        },
    }


UUID_ANY_CASE = re.compile(r"(?<![0-9A-Za-z])[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}(?![0-9A-Za-z])")


def problem_class(problem: str, window_keys: Iterable[str]) -> str:
    """A `WindowInvariants.problems` line with each id replaced by `<kind>`: a window's model key (a per-launch
    UUID) by `<window>`, any other UUID by `<uuid>`, a public id by its kind. The ids are per run, the problem
    is the state."""
    keys = sorted({key for key in window_keys if key}, key=len, reverse=True)
    if keys:
        problem = re.sub("|".join(map(re.escape, keys)), "<window>", problem, flags=re.IGNORECASE)
    problem = UUID_ANY_CASE.sub("<uuid>", problem)
    for start, end, kind in reversed(v0_schema().id_spans(problem)):
        problem = problem[:start] + f"<{kind}>" + problem[end:]
    return problem


def invariants_facet(desync: Mapping[str, Any], debug_focus: Mapping[str, Any],
                     snapshot_get: Mapping[str, Any]) -> Dict[str, Any]:
    check = _get(desync, "check", "debug.desync {check: true}")
    topology = _get(snapshot_get, "topology", "snapshot.get")
    keys = [str(w["key"]) for w in topology.get("windows") or () if isinstance(w, Mapping) and w.get("key")]
    return {
        "violations": sorted(str(_get(v, "invariant", "debug.desync /check/violations")) for v in check.get("violations") or ()),
        "windowInvariants": sorted(problem_class(str(p), keys)
                                   for p in _get(debug_focus, "window_invariants", "debug.focus")),
        "checks": _integral(_get(desync, "checks", "debug.desync"), "debug.desync /checks"),
    }


def switches_facet(tunables: Mapping[str, Any]) -> Dict[str, Any]:
    """The changed tunables, the push base's only runtime arms: key to the value read back (a string as is,
    any other value as canonical JSON)."""
    normalize = sibling("normalize")
    arms = {}
    for row in _get(tunables, "tunables", "debug.tunables {action: list}"):
        value = _get(row, "value", "debug.tunables /tunables")
        arms[str(_get(row, "key", "debug.tunables /tunables"))] = value if isinstance(value, str) else normalize.canonical_json(value)
    return {"arms": arms}


def not_comparable(facet: str, reason: str, v1: Mapping[str, Any]) -> Dict[str, Any]:
    task = v1["properties"]["facets"]["properties"][facet]["x-oracle-source"].get("task", TASK)
    return {"status": "not-comparable", "reason": reason, "task": task}


def build_facets(requested: Sequence[str], product: str, replies: Mapping[str, Any], v1: Mapping[str, Any]) -> Dict[str, Any]:
    """Each requested facet from the replies of `methods_for(requested, product)`, or its not-comparable form."""
    out: Dict[str, Any] = {}
    for facet in requested:
        if facet not in FIELDS:
            out[facet] = not_comparable(facet, "no push-base method gives this facet (x-oracle-source.v0 is null)", v1)
            continue
        if facet not in PRODUCT_FACETS.get(product, ()):
            out[facet] = not_comparable(facet, f"the {product} product has no {facet} state", v1)
            continue
        missing = [m for m in facet_methods(facet) if m not in replies]
        if missing:
            raise V0Error(f"{facet}: no reply of {missing}")
        r = replies
        if facet == "topology":
            out[facet] = topology_facet(r["snapshot.get"])
        elif facet == "daemon":
            out[facet] = daemon_facet(r["session.snapshot"], r["settings.snapshot"], v1)
        elif facet == "focus":
            out[facet] = focus_facet(r["debug.focus"], r["snapshot.get"])
        elif facet == "settings":
            out[facet] = settings_facet(r["settings.snapshot"])
        elif facet == "invariants":
            out[facet] = invariants_facet(r["debug.desync"], r["debug.focus"], r["snapshot.get"])
        elif facet == "switches":
            out[facet] = switches_facet(r["debug.tunables"])
    return out


def host_record() -> Dict[str, str]:
    model = platform_mod.node() or "unknown"
    if platform_mod.system() == "Darwin":
        proc = subprocess.run(["/usr/sbin/sysctl", "-n", "hw.model"], capture_output=True, text=True, check=False)
        model = proc.stdout.strip() or model
    return {"os": platform_mod.system().lower(), "arch": platform_mod.machine(), "model": model}


def snapshot(*, case: str, step: int, checkpoint: str, product: str, sha: str, facets: Mapping[str, Any],
             host: Mapping[str, str], captured_at_ms: Optional[int] = None) -> Dict[str, Any]:
    """One v0 snapshot. The push base has no virtual clock (task 185), so the clock is `wall`."""
    if not SHA_RE.match(sha):
        raise V0Error(f"meta.sha {sha!r} is not a full SHA")
    return {
        "schema": SCHEMA_ID,
        "meta": {
            "case": case, "step": step, "checkpoint": checkpoint, "product": product, "sha": sha,
            "host": dict(host), "clock": "wall",
            "capturedAtMs": int(time.time() * 1000) if captured_at_ms is None else captured_at_ms,
            "facets": list(facets),
        },
        "facets": dict(facets),
    }


def canonicalize(snapshots: Sequence[Any], *, roots: Sequence[str] = (), homes: Sequence[str] = (),
                 labels: Sequence[str] = ()) -> List[Any]:
    """The checkpoints of one case through normalize.py with the v0 schema, as one structure (ids keep their
    labels across checkpoints). Raises normalize.SnapshotInvalid when a reply does not fit the v0 schema."""
    normalize = sibling("normalize")
    ctx = normalize.Context(root=tuple(roots), home=tuple(homes))
    return [r.value for r in normalize.canonicalize_case(list(snapshots), v0_schema(), ctx, labels)]


def resolve_sha(ref: str) -> str:
    """A full SHA for meta.sha: the ref itself, or `git rev-parse` of it in this checkout."""
    if SHA_RE.match(ref):
        return ref
    proc = subprocess.run(["git", "-C", str(REPO), "rev-parse", "--verify", "--quiet", f"{ref}^{{commit}}"],
                          capture_output=True, text=True, check=False)
    if proc.returncode == 0 and SHA_RE.match(proc.stdout.strip()):
        return proc.stdout.strip()
    raise V0Error(f"unknown ref {ref}")


def write_schema(directory: Path) -> Path:
    """Writes the v0 schema as `<directory>/v0-snapshot.schema.json` for a driver that loads a schema file, once
    normalize.py has linted it; returns the path."""
    v0_schema()
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / "v0-snapshot.schema.json"
    path.write_text(json.dumps(derive_schema(load_v1()), indent=1, sort_keys=True) + "\n", encoding="utf-8")
    return path


# ---------------------------------------------------------------------------------------------------------
# CLI


def method_found(name: str, sha: str) -> bool:
    method = METHODS[name]
    proc = subprocess.run(["git", "-C", str(REPO), "grep", "-q", "-F", "-e", method.literal, sha, "--", method.pathspec],
                          capture_output=True, text=True, check=False)
    if proc.returncode > 1:
        raise V0Error(f"git grep at {sha}: {proc.stderr.strip()}")
    return proc.returncode == 0


def cmd_check(args: argparse.Namespace) -> int:
    v0_schema()
    missing = 0
    for sha in args.sha or [PUSH_BASE, "HEAD"]:
        for name, method in METHODS.items():
            found = method_found(name, sha)
            missing += not found
            print(f"{sha[:12]} {name:18} {'found' if found else 'MISSING'} ({method.literal} in {method.pathspec})")
    for facet, fields in FIELDS.items():
        for at, field in fields.items():
            print(f"field {facet}/{at or '.'} <- {' + '.join(field.methods)} {field.path}")
    return 1 if missing else 0


def cmd_schema(args: argparse.Namespace) -> int:
    text = json.dumps(derive_schema(load_v1()), indent=1, sort_keys=True) + "\n"
    if args.out:
        args.out.write_text(text, encoding="utf-8")
    else:
        sys.stdout.write(text)
    return 0


def checkpoint_hashes(run_dir: Path) -> Dict[Tuple[str, int], Tuple[str, str, str]]:
    """(case, index) -> (step, checkpoint, sha256) from a run directory's checkpoints.jsonl."""
    out = {}
    for line in (run_dir / "checkpoints.jsonl").read_text(encoding="utf-8").splitlines():
        if line.strip():
            row = json.loads(line)
            out[(row["case"], int(row["index"]))] = (row["step"], row["checkpoint"], row["sha256"])
    return out


def compare_runs(runs: Sequence[Tuple[Path, Mapping[str, Any]]]) -> Dict[str, Any]:
    """Equal when every run has the same checkpoints with the same hashes and every case the same result."""
    first_dir, first = runs[0]
    base = checkpoint_hashes(first_dir)
    differences: List[Dict[str, Any]] = []
    for run_dir, receipt in runs[1:]:
        other = checkpoint_hashes(run_dir)
        for key in sorted(set(base) | set(other)):
            if base.get(key) != other.get(key):
                differences.append({"run": run_dir.name, "case": key[0], "index": key[1],
                                    "a": base.get(key), "b": other.get(key)})
        for case, record in first["cases"].items():
            theirs = receipt["cases"].get(case, {})
            if record.get("status") != theirs.get("status"):
                differences.append({"run": run_dir.name, "case": case,
                                    "status": [record.get("status"), theirs.get("status")]})
    return {"equal": not differences, "checkpoints": len(base), "cases": len(first["cases"]),
            "differences": differences}


def v0_opener(product: str, schema_path: Path) -> Callable[[Dict[str, Any]], Any]:
    """The product driver's open_session with the v0 facets and the v0 schema file in its session context."""
    driver = sibling(f"driver_{product}")

    def open_session(session_ctx: Dict[str, Any]) -> Any:
        return driver.open_session({**session_ctx, "facets": "v0", "snapshot_schema": str(schema_path)})

    return open_session


def capture_runs(args: argparse.Namespace, sha: str) -> List[Tuple[Path, Dict[str, Any]]]:
    """`args.repeat` oracle.py runs of the selection with v0 facets, each in `<out>/run-<n>`."""
    oracle = sibling("oracle")
    schema_path = write_schema(args.out)
    runs = []
    for index in range(1, args.repeat + 1):
        argv = ["run", "--product", args.product, "--ref", sha, "--retry-limit", "0", "--corpus", str(args.corpus),
                "--out", str(args.out / f"run-{index}"), "--run-id", f"{oracle.new_run_id()}-v0-{index}"]
        for value, flag in ((args.binary, "--binary"), (args.tag, "--tag"), (args.jobs, "--jobs")):
            if value is not None:
                argv += [flag, str(value)]
        for suite in args.suite or ():
            argv += ["--suite", suite]
        for pattern in args.filter or ():
            argv += ["--filter", pattern]
        parsed = oracle.build_parser().parse_args(argv)
        options = oracle.options_from_args(parsed, retry_default=None, out=parsed.out, run_id=parsed.run_id,
                                           switch=None, arm=None, switches={}, ref=sha, binary=parsed.binary)
        try:
            receipt, _ = oracle.run_one(options, open_session=v0_opener(args.product, schema_path))
        except oracle.UsageError as error:
            raise V0Error(str(error)) from None
        oracle.print_run(receipt, options, False)
        runs.append((options.out, receipt))
    return runs


def cmd_capture(args: argparse.Namespace) -> int:
    sha = resolve_sha(args.sha or PUSH_BASE)
    if not args.corpus.is_dir():
        raise V0Error(f"no corpus at {args.corpus}: its suites' generators have not written it; pass --corpus DIR")
    runs = capture_runs(args, sha)
    result: Dict[str, Any] = (compare_runs(runs) if len(runs) > 1
                              else {"equal": None, "checkpoints": None, "cases": None, "differences": []})
    binary = Path(args.binary) if args.binary else None
    capture = {
        "schema": "cmux-oracle-v0-capture-v1",
        "task": TASK,
        "sha": sha,
        "product": args.product,
        "facets": "v0",
        "binary": str(binary) if binary else None,
        "binarySha256": hashlib.sha256(binary.read_bytes()).hexdigest() if binary and binary.is_file() else None,
        "tag": args.tag,
        "selection": {"suites": args.suite or ["all"], "filters": args.filter or []},
        "runs": [str(r) for r, _ in runs],
        "counts": [receipt.get("counts") for _, receipt in runs],
        "unexpected": sorted({c for _, receipt in runs for c in receipt.get("unexpected") or ()}),
        **result,
    }
    (args.out / "capture.json").write_text(json.dumps(capture, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    if len(runs) > 1:
        verdict = "equal hashes" if result["equal"] else f"{len(result['differences'])} differences"
        print(f"facets_v0 capture {sha[:12]} {args.product}: {result['cases']} cases, {result['checkpoints']} "
              f"checkpoints, {len(runs)} runs, {verdict}; {args.out / 'capture.json'}")
    # A base capture is the oracle's reference: every case must run as expected, and repeat runs must agree.
    return 0 if result["equal"] is not False and not capture["unexpected"] else 1


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(prog="facets_v0.py", description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)
    check = sub.add_parser("check", help="every v0 method at each SHA, and the v0 schema")
    check.add_argument("--sha", action="append", help="a commit (repeat; default the push base and HEAD)")
    check.set_defaults(func=cmd_check)
    schema = sub.add_parser("schema", help="the derived v0 schema")
    schema.add_argument("--out", type=Path)
    schema.set_defaults(func=cmd_schema)
    capture = sub.add_parser("capture", help="oracle.py runs with v0 facets; with --repeat 2+, equal hashes or exit 1")
    capture.add_argument("--product", choices=sorted(PRODUCT_FACETS), default="daemon")
    capture.add_argument("--binary", help="daemon: the cmux-tui built at --sha")
    capture.add_argument("--tag", help="app: the tagged bench build of --sha")
    capture.add_argument("--sha", help=f"the SHA the build is of (default the push base {PUSH_BASE[:12]})")
    capture.add_argument("--corpus", type=Path, default=REPO / "tests" / "oracle" / "corpus")
    capture.add_argument("--suite", action="append")
    capture.add_argument("--filter", action="append")
    capture.add_argument("--jobs", type=int)
    capture.add_argument("--repeat", type=int, default=2, help="runs of the selection (default 2: the base check)")
    capture.add_argument("--out", type=Path, required=True)
    capture.set_defaults(func=cmd_capture)
    args = parser.parse_args(argv)
    if getattr(args, "repeat", 1) < 1:
        parser.error("--repeat must be >= 1")
    try:
        return args.func(args)
    except V0Error as error:
        print(f"facets_v0: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
