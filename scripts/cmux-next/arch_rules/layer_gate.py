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
            renamed). The refusal names the edges whose class the relabel changes. A new edge is always
            classified with the stricter of the base and head layers of each end (the lower one for the
            source, the higher for the dependency), so a relabel and a new edge that needs it cannot ride
            in one push: the relabel lands first, with its code change
  app       a target newly placed as `app`: only CmuxNextApp, the composition root, is app
  unread    a construct the static reader cannot account for: a dependency expression it cannot
            resolve, a target constructor whose `name:` is not a string literal, a `Package(targets:)`
            entry that is not a constructor or a top-level `let X: Target`, or code that reads or
            changes `package` or a `.targets`/`.dependencies` list after it is built

An edge that is already in the base is never refused (arch-layers.py and the arch_counts layer rows report
that debt). Test targets are ignored. Each refusal names the edge and both layers, then the fix: lift the
shared type to a core target, or define a protocol seam in the consumer and conform in the App (DESIGN
sections 2-4). Escape once: ARCH_RATCHET_SKIP_REASON="layer-gate: <why>" (the arch ratchet loader applies it
by ID; `skip_reason()` reads it for callers that do not). Local pre-push only, never CI.

The manifest reader, the map reader and the edge classes are arch_counts.py's (`parse_manifest`,
`LayerMap`, `edge_class`), the same ones the layer rows count with, so the gate and the counts never
disagree about which edges exist.

Loader contract (scripts/cmux-next/arch_rules/__init__.py): `check(base, head, changes)` returns
(refusals, notes); a refusal is ("layer-gate", text, key), KEY naming what is refused (("edge", A, B),
("relabel", T), ...) so a merge push matches it over both ranges. It reads only `changes.files` and two files
at both ends through `changes.read` (one `git cat-file --batch`).

  scripts/cmux-next/arch_rules/layer_gate.py                  # HEAD over its merge base with origin/feat-cmux-next
  scripts/cmux-next/arch_rules/layer_gate.py --base A --head B
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
import subprocess
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
SKIP_ENV = "ARCH_RATCHET_SKIP_REASON"
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
    # The arch_counts row that counts the same debt (the count rule may refuse the push under it too).
    row: str = "layer_hard"
    # What is refused, independent of the base: matches the same refusal over the ranges of a merge push.
    key: tuple = ()

    def __str__(self) -> str:
        return f"[{self.rule}] {self.path}:{self.number}: {self.text}"


def relabels(base_map, head_map, base, head, changed: Iterable[str]) -> tuple[set[str], dict[str, str]]:
    """The targets whose relabel the push justifies, and {target: why} for the `relayered` entries it adds
    that do not count.

    A relabel is justified by a `relayered` entry the push adds that matches the base and head layers, with a
    YYYY-MM-DD `date` and a `reason`, AND by a change to a file under the target's sources in the same push
    (its `path:` or Sources/<target>, at either end): the layer follows the code."""
    old = {json.dumps(e, sort_keys=True) for e in base_map.relayered}
    paths = list(changed)
    justified, invalid = set(), {}
    for entry in head_map.relayered:
        if json.dumps(entry, sort_keys=True) in old:
            continue
        name = str(entry.get("target", ""))
        reason = str(entry.get("reason", "")).strip()
        was, now = base_map.placed(name), head_map.placed(name)
        matches = was is not None and now is not None and entry.get("from") == was and entry.get("to") == now
        if not (matches and counts.valid_date(entry.get("date")) and reason):
            invalid[name] = (f" (its `relayered` entry does not count: it needs `from` {was!r}, `to` {now!r}, "
                             f"a YYYY-MM-DD `date` and a `reason`)")
            continue
        dirs = sorted({m.source_dir(name) for m in (head, base) if name in m.targets})
        if not any(path.startswith(d + "/") for d in dirs for path in paths):
            invalid[name] = (f" (its `relayered` entry does not count: the push changes no file under "
                             f"{' or '.join(d + '/' for d in dirs)}, and a relabel follows a change to the "
                             f"target's code that moves its layer)")
            continue
        justified.add(name)
    return justified, invalid


def refusals(base_manifest: str | None, head_manifest: str | None,
             base_layers: str | None, head_layers: str | None, changed: Iterable[str] = ()) -> list[Refusal]:
    """One refusal per new hard or upward edge, new unexcepted soft edge, new unmapped target, unjustified
    relabel, new non-root `app` target and new construct the reader cannot account for in HEAD over BASE (the
    texts of Package.swift and architecture-layers.json; CHANGED is the push's changed paths)."""
    if head_manifest is None or base_manifest is None:
        return []  # nothing to compare against (a deleted or brand-new manifest): fail open
    head_map = counts.LayerMap.parse(head_layers)
    if head_map.error:
        return [Refusal(LAYERS_JSON, 1, f"{LAYERS_JSON} does not parse: {head_map.error}; the gate cannot place any "
                                        f"target, so fix the file (an object with `order`, a list of layer names, "
                                        f"and `targets`, {{name: {{\"layer\": ...}}}})",
                        row="layer_unplaced", key=("map",))]
    head, base = counts.parse_manifest(head_manifest), counts.parse_manifest(base_manifest)
    # A base map that does not parse places nothing: then only the head's layers judge the push.
    base_map = counts.LayerMap.parse(base_layers)
    order = head_map.order
    justified, invalid = relabels(base_map, head_map, base, head, changed)
    out = []

    def refuse(name: str, text: str, row: str, key: tuple) -> None:
        out.append(Refusal(PACKAGE_SWIFT, head.targets[name].line, text, row=row, key=key))

    def span(name: str) -> tuple[str, str] | None:
        """(lowest, highest) layer of NAME over the base and head maps. A new edge takes the source's lowest
        and the dependency's highest, so a relabel in the same push (justified or not) cannot clear it."""
        now, was = head_map.placed(name), base_map.placed(name)
        if now is None:
            return None
        if was is None or was not in order or was == now:
            return now, now
        return (was, now) if order[was] < order[now] else (now, was)

    def moved(name: str) -> str:
        was, now = base_map.placed(name), head_map.placed(name)
        if was is None or was == now:
            return ""
        return (f"; {name} is {was} in the base and {now} here, and the gate takes the stricter of the two "
                f"(land the relabel with the code change that moves {name} in its own push first)")

    for name in sorted(head_map.unmapped(head) - base_map.unmapped(base)):
        layer = head_map.layers.get(name)
        state = (f"has layer {layer!r}, which is not in `order`," if layer is not None else "has no layer")
        refuse(name, f"target {name} ({head.targets[name].kind}) {state} in {LAYERS_JSON}: add it under "
                     f"`targets` as {{\"layer\": ...}} with the layer it holds (core, service, domain, ui or app; a "
                     f"target that mixes layers takes its highest one and lists the others in `mixes`)",
               "layer_unplaced", ("unmapped", name))
    for name, target in sorted(head.targets.items()):
        if target.kind not in MAPPED_KINDS:
            continue
        was, now = base_map.placed(name), head_map.placed(name)
        if now == "app" and name != COMPOSITION_ROOT and was != "app":
            refuse(name, f"target {name} is placed as app in {LAYERS_JSON}: only {COMPOSITION_ROOT}, the "
                         f"composition root, is app (DESIGN section 4); give {name} the layer its code holds "
                         f"(core, service, domain or ui)", "layer_hard", ("app", name))
        if was is None or now is None or was == now or name in justified:
            continue
        changed_edges = []
        for source, dep in sorted(head.edges()):
            if name in (source, dep):
                before, after = base_map.classify(source, dep), head_map.classify(source, dep)
                if before != after:
                    changed_edges.append(f"{source} -> {dep} {before or 'allowed'} -> {after or 'allowed'}")
        effect = ("; it changes " + ", ".join(changed_edges)) if changed_edges else "; it changes no edge's class"
        refuse(name, f"target {name} moves from {was} to {now} in {LAYERS_JSON}{effect}{invalid.get(name, '')}: "
                     f"a relabel goes with the code change that moves the target (a file under its sources in the "
                     f"same push) and a dated reason the push adds under `relayered`: {{\"target\": \"{name}\", "
                     f"\"from\": \"{was}\", \"to\": \"{now}\", \"date\": \"YYYY-MM-DD\", \"reason\": what changed "
                     f"in its code}}; a relabel that only clears an edge is the debt renamed: {FIX}",
               "layer_hard", ("relabel", name))
    for source, dep in sorted(head.edges() - base.edges()):
        ends, deps = span(source), span(dep)
        if ends is None or deps is None:
            continue
        a, b = ends[0], deps[1]
        kind = counts.edge_class(order, a, b)
        if kind is None:
            continue
        note, key = moved(source) + moved(dep), ("edge", source, dep)
        if kind == "hard":
            refuse(source, f"new edge {source} ({a}) -> {dep} ({b}): {a_layer(a)} target may not depend on "
                           f"{a_layer(b)} target{note}; {FIX}", ROW_OF_CLASS[kind], key)
        elif kind == "upward":
            refuse(source, f"new edge {source} ({a}) -> {dep} ({b}): edges only point down, so {a_layer(a)} "
                           f"target may not depend on {a_layer(b)} target{note}; {FIX}", ROW_OF_CLASS[kind], key)
        else:
            ok, why = excepted(head_map, source, dep)
            if not ok:
                refuse(source, f"new edge {source} ({a}) -> {dep} ({b}): a service may not depend on a domain "
                               f"target{note}{why}; {FIX}; or, if it must stay for now, list it under `exceptions` "
                               f"in {LAYERS_JSON} with a date and a reason", ROW_OF_CLASS[kind], key)
    for name, target in sorted(head.targets.items()):
        if target.kind == "testTarget":
            continue
        before = base.targets.get(name)
        for expr in sorted(target.unresolved - (before.unresolved if before else set())):
            refuse(name, f"{name}'s dependencies hold `{shown(expr)}`, which the gate cannot read without swift: use "
                         f"string literals, `.target(name:)`/`.product(...)` entries or a top-level "
                         f"`let` `[Target.Dependency]` variable", "layer_hard", ("unresolved", name, expr))
    for expr, (line, why) in sorted(head.unreadable.items(), key=lambda item: item[1][0]):
        if expr in base.unreadable:
            continue
        out.append(Refusal(PACKAGE_SWIFT, line, f"`{shown(expr)}`: the gate cannot read this without swift ({why}): "
                                                f"declare each target as a `.target(name: \"...\", dependencies: "
                                                f"[...])` call in `Package(targets:)` or a top-level `let X: Target`, "
                                                f"with string-literal names and dependencies, and never change "
                                                f"`package` after it is built", row="layer_hard",
                           key=("unreadable", expr)))
    return out


def blobs(repo, specs: list[tuple[str, str]]) -> list[str | None]:
    """The text of each (rev, path) in REPO from one `git cat-file --batch`, None where the rev lacks it."""
    env = {k: v for k, v in os.environ.items() if k not in ("GIT_INDEX_FILE", "GIT_WORK_TREE")}
    request = "".join(f"{rev}:{path}\n" for rev, path in specs).encode()
    out = subprocess.run(["git", "-C", str(repo), "cat-file", "--batch"], input=request, capture_output=True,
                         env=env, check=True).stdout
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
    return refusals(*texts, changed=changed)


def check(base: str, head: str, changes: Any = None, repo: Path | str | None = None) -> tuple[list, list]:
    """arch-ratchet entry point: (refusals, notes) for the pushed range BASE..HEAD.

    A refusal is `(ID, text, key)`, so ARCH_RATCHET_SKIP_REASON="layer-gate: <why>" names it and a merge push
    matches it over both ranges by KEY. CHANGES is the loader's object (`repo`, `files` as [(status, path)],
    `read`); None reads the changed paths from git in REPO (default: the repository that holds this file).
    """
    root = Path(getattr(changes, "repo", None) or repo or ROOT)
    if changes is None:
        changed = git(root, "diff", "--name-only", "--no-renames", base, head).splitlines()
    else:
        changed = changed_paths(getattr(changes, "files", changes))
    found = check_repo(root, base, head, changed, getattr(changes, "read", None))
    return [(ID, f"{refusal}\n  Escape for this push only: {SKIP_ENV}=\"{ID}: <why>\" (say it in your report; "
                 f"when the count rule refuses the same change, name its row too: \"{ID},{refusal.row}: <why>\").",
             refusal.key)
            for refusal in found], []


def git(repo: Path | str, *args: str) -> str:
    env = {k: v for k, v in os.environ.items() if k not in ("GIT_INDEX_FILE", "GIT_WORK_TREE")}
    return subprocess.run(["git", "-C", str(repo), *args], capture_output=True, env=env, check=True,
                          text=True).stdout


def skip_reason(env: dict[str, str] | None = None) -> str | None:
    """The why of an ARCH_RATCHET_SKIP_REASON="<rule>[,<rule>]: <why>" that names this rule, else None."""
    value = (os.environ if env is None else env).get(SKIP_ENV, "").strip()
    named, colon, why = value.partition(":")
    return why.strip() if colon and why.strip() and ID in {r.strip() for r in named.split(",")} else None


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
    why = skip_reason()
    if why:
        print(f"{ID}: skipped ({SKIP_ENV}): {why}")
        return 0
    print(f'{ID}: escape once with {SKIP_ENV}="{ID}: <why>" and say it in your report')
    return 1


if __name__ == "__main__":
    sys.exit(main())
