#!/usr/bin/env python3
"""layer-gate: a push may not add a CmuxNext package edge that breaks the layer map, or an unmapped target.

The layer map is plans/cmux-next/architecture-layers.json (core < service < domain < ui < app; edges only
point down, plans/cmux-next/architecture-refactor-DESIGN.md section 2). The rule reads
Packages/macOS/CmuxNext/Package.swift at the push's base and head statically (no swift, about 90 ms for both)
and refuses only what the push adds:

  hard      a new edge A -> B where B is a ui or app target above A's layer
  soft      a new edge from a service target to a domain target, unless the map lists it under
            `exceptions` with a date and a reason
  upward    any other new edge that points up (core -> service, core -> domain); no exceptions
  unmapped  a new regular, executable or binary target that the map does not place (or a target the
            push removes from the map, gives a layer that is not in `order`, or whose entry has no
            string `layer`)
  map       a head architecture-layers.json that does not parse, is not an object or has no `order`
  relabel   a target whose layer the push changes, unless the push adds a `relayered` entry for it
            with the old and the new layer, a date and a reason AND changes a file under the target's
            sources (a relabel follows the code that moves the target; a relabel alone is the debt
            renamed). A relabel that clears a standing edge (a hard, soft or upward edge of the base becomes
            allowed) needs more: it must move the target down, and the target's sources at head must prove the
            lower layer, importing no UI framework (AppKit, Cocoa, SwiftUI, WebKit) when the new layer is
            below ui and no target the map places above the new layer (`code_proof`). Raising a target to clear
            its own upward edge is always refused: that is the debt renamed. The refusal names the edges whose
            class the relabel changes and the imports that hold the old layer. A new edge is always
            classified with the stricter of the base and head layers of each end (the lower one for the
            source, the higher for the dependency), so a relabel and a new edge that needs it cannot ride
            in one push: the relabel lands first, with its code change. A target the push renames is the same
            target: a new target whose sources are a removed target's directory (a `path:` onto it), or that
            the push moves files into from a removed target's directory (git's rename detection), keeps the
            removed target's base layer and edges
  app       a target newly placed as `app`: only CmuxNextApp, the composition root, is app
  unread    a construct the static reader cannot account for: a dependency expression it cannot
            resolve, a target constructor whose `name:` is not a string literal, a `Package(targets:)`
            entry that is not a constructor or a top-level `let X: Target`, or code that reads or
            changes `package` or a `.targets`/`.dependencies` list after it is built

An edge that is already in the base is never refused (arch-layers.py and the arch_counts layer rows report
that debt). A base map that does not parse is judged as the newest earlier map that parses
(arch_counts.placing_map), the layers the targets held before it broke, so a push that repairs it is still
refused for a relabel or a target it leaves unplaced. Test targets are ignored. Each refusal names the edge and both layers, then the fix: lift the
shared type to a core target, or define a protocol seam in the consumer and conform in the App (DESIGN
sections 2-4). The one escape (a reviewed reason only): the push adds a dated exception for ID to
plans/cmux-next/arch-ratchet.json's `exceptions` ({"date": "YYYY-MM-DD", "row": "layer-gate", "allow": <n>,
"why": "..."}); the arch ratchet loader lets that push carry n of this rule's refusals. There is no
environment-variable skip. Local pre-push only, never CI.

The manifest reader, the map reader and the edge classes are arch_counts.py's (`parse_manifest`,
`LayerMap`, `edge_class`), the same ones the layer rows count with, so the gate and the counts never
disagree about which edges exist.

Loader contract (scripts/cmux-next/arch_rules/__init__.py): `check(base, head, changes)` returns
(refusals, notes) over the ratchet's one range (a merge push starts where HEAD meets origin/feat-cmux-next);
a refusal is ("layer-gate", text, row), ROW the arch_counts row the refused change raises (a new edge's class
row, layer_unplaced for a new unplaced target; else None) so the count rule does not refuse it a second time:
one new edge, one refusal, one dated entry. It reads only `changes.files` and two files
at both ends through `changes.read` (one `git cat-file --batch`).

  scripts/cmux-next/arch_rules/layer_gate.py                  # HEAD over its merge base with origin/feat-cmux-next
  scripts/cmux-next/arch_rules/layer_gate.py --base A --head B
"""
from __future__ import annotations

import argparse
import datetime
import importlib.util
import json
import os
import re
import subprocess
import tempfile
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable


def _load_counts():
    """scripts/cmux-next/arch_counts.py, the directory above this one (the installed hook copy has the same
    shape); the module arch-ratchet.py already loaded when it is there."""
    name = "cmux_next_arch_counts"
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, Path(__file__).resolve().parents[1] / "arch_counts.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module  # dataclasses resolve their module through sys.modules
    spec.loader.exec_module(module)
    return module


counts = _load_counts()

ID = "layer-gate"
UPSTREAM = "origin/feat-cmux-next"
ROOT = Path(__file__).resolve().parents[3]
PACKAGE_SWIFT = counts.MANIFEST
LAYERS_JSON = counts.LAYERS_JSON
WATCHED = (PACKAGE_SWIFT, LAYERS_JSON)
MAPPED_KINDS = counts.MAPPED_KINDS
# The one target the map may place as `app` (DESIGN section 4).
COMPOSITION_ROOT = "CmuxNextApp"
FIX = ("fix: lift the shared type to a core target, or define a protocol seam in the consumer and conform "
       "in the App (plans/cmux-next/architecture-refactor-DESIGN.md sections 2-4)")
ROW_OF_CLASS = {"hard": "layer_hard", "soft": "layer_soft", "upward": "layer_upward"}
# Frameworks that hold views: a target below ui that imports one holds the ui layer (DESIGN section 2). The
# DESIGN lets a core target import AppKit for platform value types; the proof below does not try to tell those
# apart, so such a relabel needs a dated layer-gate exception.
UI_FRAMEWORKS = ("AppKit", "Cocoa", "SwiftUI", "WebKit")
IMPORT = re.compile(r"^[ \t]*(?:@[\w.]+(?:\([^()\n]*\))?[ \t]+)*(?:(?:public|package|internal|private|fileprivate)[ \t]+)?"
                    r"import[ \t]+(?:(?:struct|class|enum|protocol|typealias|func|let|var)[ \t]+)?([A-Za-z_]\w*)", re.M)


def a_layer(layer: str) -> str:
    """LAYER with its indefinite article: "an app", "a ui" (u reads "you"), "a core"."""
    return f"{'an' if layer[:1] in ('a', 'e', 'i', 'o') else 'a'} {layer}"


def shown(expr: str, limit: int = 120) -> str:
    return expr if len(expr) <= limit else expr[:limit - 3] + "..."


def excepted(layer_map, source: str, dep: str) -> tuple[bool, str]:
    """Whether LAYER_MAP's `exceptions` lets the soft edge SOURCE -> DEP in, and why not when it lists it."""
    entry = layer_map.exceptions.get((source, dep))
    if entry is None:
        return False, ""
    date, reason = str(entry.get("date", "")), str(entry.get("reason", "")).strip()
    if not counts.valid_date(date) or not reason:
        return False, f" (its exception needs a YYYY-MM-DD `date` and a `reason`; it has date {date!r}, reason {reason!r})"
    return True, ""


@dataclass
class Refusal:
    """One refused addition: PATH and NUMBER (1-based, head side) locate it; TEXT says what and the fix."""
    path: str
    number: int
    text: str
    rule: str = ID
    # The arch_counts row whose rise this refusal answers (a new edge: its class's row; a new unplaced target:
    # layer_unplaced), or None. The ratchet's count rule does not refuse that unit again, so one new edge has
    # one refusal and one escape.
    row: str | None = None

    def __str__(self) -> str:
        return f"[{self.rule}] {self.path}:{self.number}: {self.text}"


def file_renames(repo: Path | str, base: str, head: str) -> list[tuple[str, str]]:
    """(old path, new path) of every file BASE..HEAD renames under the CmuxNext package (git's -M detection)."""
    parts = git(repo, "diff", "-M", "--name-status", "-z", base, head, "--", counts.PACKAGE_DIR + "/").split("\0")
    out, i = [], 0
    while i < len(parts):
        status = parts[i]
        if not status:
            i += 1
        elif status[0] in "RC":
            if status[0] == "R" and i + 2 < len(parts):
                out.append((parts[i + 1], parts[i + 2]))
            i += 3
        else:
            i += 2
    return out


def renamed_targets(base, head, renames) -> dict[str, str]:
    """{new target: old target} for each target the push adds that continues one it removes: its sources are the
    removed target's directory (a `path:` onto it), or the push moves files from that directory into its own.

    RENAMES is [(old path, new path)] of the push's file renames, or a callable that returns it (asked only when
    the push both adds and removes a target)."""
    added = sorted(n for n, t in head.targets.items() if n not in base.targets and t.kind in MAPPED_KINDS)
    removed = sorted(n for n, t in base.targets.items() if n not in head.targets and t.kind in MAPPED_KINDS)
    if not added or not removed:
        return {}
    moves = None
    out = {}
    for new in added:
        new_dir = head.source_dir(new)
        for old in removed:
            old_dir = base.source_dir(old)
            if old_dir != new_dir:
                if moves is None:
                    moves = list(renames() if callable(renames) else renames)
                if not any(a.startswith(old_dir + "/") and b.startswith(new_dir + "/") for a, b in moves):
                    continue
            out[new] = old
            break
    return out


def code_proof(sources: dict[str, str], layer: str, head_map) -> list[str]:
    """The imports in SOURCES ({path: Swift text} of one target at head) that hold a layer above LAYER, as
    `path:line: text`: a UI framework when LAYER is below ui, or a target HEAD_MAP places above LAYER. Empty: the
    code holds LAYER (or a lower one)."""
    order = head_map.order
    held = []
    for path, text in sorted(sources.items()):
        code = counts.strip(text)
        for m in IMPORT.finditer(code):
            name = m.group(1)
            above = head_map.placed(name)
            ui = name in UI_FRAMEWORKS and order.get(layer, 0) < order.get("ui", len(order))
            if ui or (above is not None and order[above] > order.get(layer, 0)):
                line = code.count("\n", 0, m.start(1)) + 1
                held.append(f"{path}:{line}: {text.splitlines()[line - 1].strip()}")
    return held


def relabels(base_map, head_map, base, head, changed: Iterable[str],
             old_of=lambda name: name) -> tuple[set[str], dict[str, str]]:
    """The targets whose relabel the push justifies, and {target: why} for the `relayered` entries it adds
    that do not count.

    A relabel is justified by a `relayered` entry the push adds that matches the base and head layers, with a
    YYYY-MM-DD `date` and a `reason`, AND by a change to a file under the target's sources in the same push
    (its `path:` or Sources/<target>, at either end): the layer follows the code. OLD_OF names a renamed
    target's base name (renamed_targets)."""
    old = {json.dumps(e, sort_keys=True) for e in base_map.relayered}
    paths = list(changed)
    justified, invalid = set(), {}
    for entry in head_map.relayered:
        if json.dumps(entry, sort_keys=True) in old:
            continue
        name = str(entry.get("target", ""))
        reason = str(entry.get("reason", "")).strip()
        was, now = base_map.placed(old_of(name)), head_map.placed(name)
        matches = was is not None and now is not None and entry.get("from") == was and entry.get("to") == now
        if not (matches and counts.valid_date(entry.get("date")) and reason):
            invalid[name] = (f" (its `relayered` entry does not count: it needs `from` {was!r}, `to` {now!r}, "
                             f"a YYYY-MM-DD `date` and a `reason`)")
            continue
        dirs = sorted({m.source_dir(n) for m, n in ((head, name), (base, old_of(name))) if n in m.targets})
        if not any(path.startswith(d + "/") for d in dirs for path in paths):
            invalid[name] = (f" (its `relayered` entry does not count: the push changes no file under "
                             f"{' or '.join(d + '/' for d in dirs)}, and a relabel follows a change to the "
                             f"target's code that moves its layer)")
            continue
        justified.add(name)
    return justified, invalid


def refusals(base_manifest: str | None, head_manifest: str | None,
             base_layers: str | None, head_layers: str | None, changed: Iterable[str] = (),
             renames=(), sources=None) -> list[Refusal]:
    """One refusal per new hard or upward edge, new unexcepted soft edge, new unmapped target, unjustified
    relabel, relabel that clears a standing edge without moving the target down to a layer its code proves, new
    non-root `app` target and new construct the reader cannot account for in HEAD over BASE (the texts of
    Package.swift and architecture-layers.json; CHANGED is the push's changed paths; RENAMES its file renames,
    see renamed_targets; SOURCES(directory) gives {path: text} of a target's Swift sources at HEAD, None: no
    relabel that clears an edge can be proved)."""
    if head_manifest is None or base_manifest is None:
        return []  # nothing to compare against (a deleted or brand-new manifest): fail open
    head_map = counts.LayerMap.parse(head_layers)
    if head_map.error:
        return [Refusal(LAYERS_JSON, 1, f"{LAYERS_JSON} does not parse: {head_map.error}; the gate cannot place any "
                                        f"target, so fix the file (an object with `order`, a list of layer names, "
                                        f"and `targets`, {{name: {{\"layer\": ...}}}})",
                        )]
    head, base = counts.parse_manifest(head_manifest), counts.parse_manifest(base_manifest)
    # A base map that does not parse places nothing (check_repo passes the newest earlier map that parses
    # instead; only when none does): then only the head's layers judge the push.
    base_map = counts.LayerMap.parse(base_layers)
    order = head_map.order
    # A renamed target is the same target: its base layer and edges are the old name's.
    renamed = renamed_targets(base, head, renames)
    new_of = {old: new for new, old in renamed.items()}

    def old_of(name: str) -> str:
        return renamed.get(name, name)

    def was_of(name: str) -> str | None:
        return base_map.placed(old_of(name))

    def named(name: str) -> str:
        return f"{name} ({renamed[name]} in the base)" if name in renamed else name

    base_edges = {(new_of.get(a, a), new_of.get(b, b)) for a, b in base.edges()}
    justified, invalid = relabels(base_map, head_map, base, head, changed, old_of)
    out = []

    def refuse(name: str, text: str, row: str | None) -> None:
        out.append(Refusal(PACKAGE_SWIFT, head.targets[name].line, text, row=row))

    def span(name: str) -> tuple[str, str] | None:
        """(lowest, highest) layer of NAME over the base and head maps. A new edge takes the source's lowest
        and the dependency's highest, so a relabel in the same push (justified or not) cannot clear it."""
        now, was = head_map.placed(name), was_of(name)
        if now is None:
            return None
        if was is None or was not in order or was == now:
            return now, now
        return (was, now) if order[was] < order[now] else (now, was)

    def moved(name: str) -> str:
        was, now = was_of(name), head_map.placed(name)
        if was is None or was == now:
            return ""
        return (f"; {name} is {was} in the base and {now} here, and the gate takes the stricter of the two "
                f"(land the relabel with the code change that moves {name} in its own push first)")

    for name in sorted(head_map.unmapped(head) - {new_of.get(n, n) for n in base_map.unmapped(base)}):
        layer = head_map.layers.get(name)
        state = (f"has layer {layer!r}, which is not in `order`," if layer is not None else "has no layer")
        refuse(name, f"target {name} ({head.targets[name].kind}) {state} in {LAYERS_JSON}: add it under "
                     f"`targets` as {{\"layer\": ...}} with the layer it holds (core, service, domain, ui or app; a "
                     f"target that mixes layers takes its highest one and lists the others in `mixes`)",
               "layer_unplaced")
    for name, target in sorted(head.targets.items()):
        if target.kind not in MAPPED_KINDS:
            continue
        was, now = was_of(name), head_map.placed(name)
        if now == "app" and name != COMPOSITION_ROOT and was != "app":
            refuse(name, f"target {name} is placed as app in {LAYERS_JSON}: only {COMPOSITION_ROOT}, the "
                         f"composition root, is app (DESIGN section 4); give {name} the layer its code holds "
                         f"(core, service, domain or ui)", None)
        if was is None or now is None or was == now:
            continue
        changed_edges, cleared = [], False
        for source, dep in sorted(head.edges()):
            if name in (source, dep):
                before = counts.edge_class(base_map.order, was_of(source), was_of(dep))
                after = head_map.classify(source, dep)
                if before != after:
                    changed_edges.append(f"{source} -> {dep} {before or 'allowed'} -> {after or 'allowed'}")
                    # An edge the push adds is judged as a new edge below; this is the standing debt.
                    cleared |= before is not None and after is None and (source, dep) in base_edges
        effect = ("; it changes " + ", ".join(changed_edges)) if changed_edges else "; it changes no edge's class"
        if name in justified and not cleared:
            continue
        if name in justified:
            # A justified relabel that clears a standing edge: the code must prove the lower layer.
            if order.get(now, 0) > order.get(was, 0):
                refuse(name, f"target {named(name)} moves from {was} to {now} in {LAYERS_JSON}{effect}: a relabel "
                             f"that raises a target to clear its own edge is that debt renamed (the code still holds "
                             f"{was}); remove the edge from Package.swift ({FIX})", None)
                continue
            held = (code_proof(sources(head.source_dir(name)), now, head_map) if sources is not None
                    else ["(no sources were given to the gate, so the code cannot prove the layer)"])
            if not held:
                continue
            refuse(name, f"target {named(name)} moves from {was} to {now} in {LAYERS_JSON}{effect}, but its code "
                         f"still holds a layer above {now}: " + "; ".join(held[:6])
                         + (f" (and {len(held) - 6} more)" if len(held) > 6 else "")
                         + f". A relabel that clears an edge lands with the code change that removes these imports "
                           f"(move the views out first), or the edge goes away ({FIX})", None)
            continue
        refuse(name, f"target {named(name)} moves from {was} to {now} in {LAYERS_JSON}{effect}{invalid.get(name, '')}: "
                     f"a relabel goes with the code change that moves the target (a file under its sources in the "
                     f"same push) and a dated reason the push adds under `relayered`: {{\"target\": \"{name}\", "
                     f"\"from\": \"{was}\", \"to\": \"{now}\", \"date\": \"YYYY-MM-DD\", \"reason\": what changed "
                     f"in its code}}; a relabel that only clears an edge is the debt renamed: {FIX}",
               None)
    for source, dep in sorted(head.edges() - base_edges):
        ends, deps = span(source), span(dep)
        if ends is None or deps is None:
            continue
        a, b = ends[0], deps[1]
        kind = counts.edge_class(order, a, b)
        if kind is None:
            continue
        note = moved(source) + moved(dep)
        if kind == "hard":
            refuse(source, f"new edge {source} ({a}) -> {dep} ({b}): {a_layer(a)} target may not depend on "
                           f"{a_layer(b)} target{note}; {FIX}", ROW_OF_CLASS[kind])
        elif kind == "upward":
            refuse(source, f"new edge {source} ({a}) -> {dep} ({b}): edges only point down, so {a_layer(a)} "
                           f"target may not depend on {a_layer(b)} target{note}; {FIX}", ROW_OF_CLASS[kind])
        else:
            ok, why = excepted(head_map, source, dep)
            if not ok:
                refuse(source, f"new edge {source} ({a}) -> {dep} ({b}): a service may not depend on a domain "
                               f"target{note}{why}; {FIX}; or, if it must stay for now, list it under `exceptions` "
                               f"in {LAYERS_JSON} with a date and a reason", ROW_OF_CLASS[kind])
    for name, target in sorted(head.targets.items()):
        if target.kind == "testTarget":
            continue
        before = base.targets.get(old_of(name))
        for expr in sorted(target.unresolved - (before.unresolved if before else set())):
            refuse(name, f"{name}'s dependencies hold `{shown(expr)}`, which the gate cannot read without swift: use "
                         f"string literals, `.target(name:)`/`.product(...)` entries or a top-level "
                         f"`let` `[Target.Dependency]` variable", None)
    for expr, (line, why) in sorted(head.unreadable.items(), key=lambda item: item[1][0]):
        if expr in base.unreadable:
            continue
        out.append(Refusal(PACKAGE_SWIFT, line, f"`{shown(expr)}`: the gate cannot read this without swift ({why}): "
                                                f"declare each target as a `.target(name: \"...\", dependencies: "
                                                f"[...])` call in `Package(targets:)` or a top-level `let X: Target`, "
                                                f"with string-literal names and dependencies, and never change "
                                                f"`package` after it is built"))
    return out


def blobs(repo, specs: list[tuple[str, str]]) -> list[str | None]:
    """The text of each (rev, path) in REPO from one `git cat-file --batch`, None where the rev lacks it."""
    env = {k: v for k, v in os.environ.items() if k not in ("GIT_INDEX_FILE", "GIT_WORK_TREE")}
    request = "".join(f"{rev}:{path}\n" for rev, path in specs).encode()
    # Through a file, never `input=`: a write into a pipe can block in the kernel past any timeout (git_batch.py).
    with tempfile.TemporaryFile() as stdin:
        stdin.write(request)
        stdin.seek(0)
        out = subprocess.run(["git", "-C", str(repo), "cat-file", "--batch"], stdin=stdin, capture_output=True,
                             env=env, check=True, timeout=60).stdout
    texts, pos = [], 0
    for _ in specs:
        newline = out.index(b"\n", pos)
        header = out[pos:newline].split()
        pos = newline + 1
        if len(header) == 3 and header[1] == b"blob":
            size = int(header[2])
            texts.append(out[pos:pos + size].decode("utf-8", "replace"))
            pos += size + 1
        else:
            texts.append(None)
    return texts


def changed_paths(changes: Any) -> list[str]:
    """The paths of CHANGES: `[(status, path)]` (the loader's `changes.files`), paths, or a mapping keyed by path."""
    if isinstance(changes, dict):
        return [str(path) for path in changes]
    return [str(change[-1] if isinstance(change, tuple) else change) for change in changes]


def check_repo(repo: Path | str, base: str, head: str, changed: Iterable[str], read=None) -> list[Refusal]:
    """The refusals for a push from BASE to HEAD in REPO whose changed paths are CHANGED.

    READ, when given, is the loader's `changes.read` ({(rev, path): text} for [(rev, path)]).
    """
    changed = list(changed)
    if not any(path in WATCHED for path in changed):
        return []
    specs = [(base, PACKAGE_SWIFT), (head, PACKAGE_SWIFT), (base, LAYERS_JSON), (head, LAYERS_JSON)]
    texts = [read(specs)[spec] for spec in specs] if read else blobs(repo, specs)
    # A base map that does not parse (it landed past the hook: a GitHub merge, --no-verify) still had a value:
    # the newest earlier map that parses. The push is judged against it, so a repair cannot relabel or unplace.
    texts[2] = counts.placing_map(repo, base, texts[2])

    def sources(directory: str) -> dict[str, str]:
        """{path: text} of the Swift files under DIRECTORY at HEAD (asked only for a relabel that clears an edge)."""
        paths = [p for p in git(repo, "ls-tree", "-r", "-z", "--name-only", head, "--", directory + "/").split("\0")
                 if p.endswith(".swift")]
        specs = [(head, p) for p in paths]
        found = read(specs) if read else dict(zip(specs, blobs(repo, specs)))
        return {p: found[(head, p)] for p in paths if found.get((head, p)) is not None}

    return refusals(*texts, changed=changed, renames=lambda: file_renames(repo, base, head), sources=sources)


def check(base: str, head: str, changes: Any = None, repo: Path | str | None = None) -> tuple[list, list]:
    """arch-ratchet entry point: (refusals, notes) for the pushed range BASE..HEAD.

    A refusal is `(ID, text, row)`, so a dated arch-ratchet.json exception for ID covers it, and the count rule
    does not refuse the unit of ROW (the arch_counts row the refused change raises, or None) that it answers. CHANGES is the loader's object (`repo`, `files` as [(status, path)],
    `read`); None reads the changed paths from git in REPO (default: the repository that holds this file).
    """
    root = Path(getattr(changes, "repo", None) or repo or ROOT)
    if changes is None:
        changed = git(root, "diff", "--name-only", "--no-renames", base, head).splitlines()
    else:
        changed = changed_paths(getattr(changes, "files", changes))
    found = check_repo(root, base, head, changed, getattr(changes, "read", None))
    return [(ID, f"{refusal}\n  {escape()}", refusal.row) for refusal in found], []


def escape() -> str:
    """The one escape, printed with each refusal: a dated exception for ID that the push adds. It is the only
    entry a refused edge needs: the count rule does not refuse the layer row rise that the refusal answers."""
    today = datetime.date.today().isoformat()
    return (f"The only escape (a reviewed reason, never to pass the hook): add {{\"date\": \"{today}\", \"row\": "
            f"\"{ID}\", \"allow\": 1, \"why\": \"<the reviewed reason>\"}} per refusal to the exceptions of "
            f"{counts.RATCHET_JSON} in this push.")


def git(repo: Path | str, *args: str) -> str:
    env = {k: v for k, v in os.environ.items() if k not in ("GIT_INDEX_FILE", "GIT_WORK_TREE")}
    return subprocess.run(["git", "-C", str(repo), *args], capture_output=True, env=env, check=True,
                          text=True).stdout


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo")
    parser.add_argument("--base", help="default: the merge base of HEAD and origin/feat-cmux-next")
    parser.add_argument("--head", default="HEAD")
    args = parser.parse_args(argv)
    repo = Path(args.repo) if args.repo else ROOT
    base = args.base or git(repo, "merge-base", args.head, UPSTREAM).strip()
    found = check_repo(repo, base, args.head, git(repo, "diff", "--name-only", "--no-renames", base, args.head).splitlines())
    if not found:
        print(f"{ID}: ok")
        return 0
    for refusal in found:
        print(refusal)
    print(f"{ID}: {escape()}")
    return 1


if __name__ == "__main__":
    sys.exit(main())
