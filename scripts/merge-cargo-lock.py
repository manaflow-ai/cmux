#!/usr/bin/env python3
"""Cargo.lock merge driver: a package-wise three-way merge, written the way cargo writes it.

Leo, 2026-11-25: "my original ask was wrt fixing up conflicts in code architecture and just improving the
codebase and speed and ergonomics of working inside it and general anything non-visible we can just improve
and merge".

Why: cmux-tui/Cargo.lock conflicted on 27 of 198 PRs that touched it in 14 days (conflict_hotspots.py
replay, 2026-11-25), and every one sampled was two PRs adding packages next to each other in the sorted list
(two new workspace crates) or adding neighbouring names to one crate's `dependencies`. Line merging sees two
insertions at the same spot; package-wise they never touch.

How: each side is parsed into packages keyed by (name, version, source), with every dependency resolved to
such a key in that side's own lockfile. Packages and dependency sets merge three-way; the result is written in
cargo's order (packages by name, then semver, then source; dependencies sorted) with cargo's shortest
unambiguous dependency names, so `cargo build --locked` reads it as up to date. A dependency on a package the
other side removed is pointed at the one package of that name left; packages nothing reaches any more are
dropped, as cargo drops them. A real conflict (one package changed both ways, or a package one side deleted and
the other changed) or a file this does not understand falls back to `git merge-file`, so git reports it as
usual.

  merge-cargo-lock.py %O %A %B [%P]    the git merge driver (writes %A; exit 0 merged, 1 conflict)
  merge-cargo-lock.py --check FILE     exit 0 when FILE is written exactly as this driver would write it

Registered by scripts/install-git-hooks.sh (merge.cmux-cargo-lock-v1) and by the cmux-next generated
catch-up, for `**/Cargo.lock` in .gitattributes. Tests: tests/test_merge_cargo_lock.py.
"""
from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

DEP_RE = re.compile(r'^(?P<name>[^ ()]+)(?: (?P<version>[^ ()]+))?(?: \((?P<source>.+)\))?$')
FIELD_RE = re.compile(r'^(?P<key>[A-Za-z_-]+) = "(?P<value>(?:[^"\\]|\\.)*)"$')
# The order cargo writes a package's fields in (EncodableDependency).
FIELD_ORDER = ("name", "version", "source", "checksum")


class Unsupported(Exception):
    """The file is not a lockfile this driver knows how to write back."""


class Conflict(Exception):
    """Both sides changed the same thing differently."""


Key = tuple  # (name, version, source or "")


def parse(text: str) -> tuple[str, dict[Key, dict], str]:
    """(header, packages, tail). Each package: {"fields": {k: v}, "deps": [raw dep strings]}."""
    if "\r" in text:
        raise Unsupported("CRLF line endings")
    parts = text.split("\n[[package]]\n")
    header = parts[0]
    if not header.endswith("\n"):
        header += "\n"
    if len(parts) == 1 or "[[" in header or "[" in "".join(
            line for line in header.splitlines() if not line.startswith("#")):
        raise Unsupported("no [[package]] list after the header")
    tail = ""
    blocks = parts[1:]
    # A section after the packages ([[patch.unused]], [metadata]) stays as text after the last package.
    last = blocks[-1]
    m = re.search(r"\n\[", last)
    if m:
        blocks[-1], tail = last[:m.start() + 1], last[m.start() + 1:]
    packages: dict[Key, dict] = {}
    for block in blocks:
        fields: dict[str, str] = {}
        deps: list[str] | None = None
        lines = block.rstrip("\n").split("\n")
        i = 0
        while i < len(lines):
            line = lines[i]
            if line == "dependencies = [":
                deps = []
                i += 1
                while i < len(lines) and lines[i] != "]":
                    dm = re.match(r'^ "(.*)",$', lines[i])
                    if not dm:
                        raise Unsupported(f"dependency line {lines[i]!r}")
                    deps.append(dm.group(1))
                    i += 1
                if i == len(lines):
                    raise Unsupported("unterminated dependencies")
            elif line == "":
                pass
            else:
                fm = FIELD_RE.match(line)
                if not fm or fm.group("key") not in FIELD_ORDER:
                    raise Unsupported(f"package line {line!r}")
                fields[fm.group("key")] = fm.group("value")
            i += 1
        if "name" not in fields or "version" not in fields:
            raise Unsupported("a package without name or version")
        key = (fields["name"], fields["version"], fields.get("source", ""))
        if key in packages:
            raise Unsupported(f"duplicate package {key}")
        packages[key] = {"fields": fields, "deps": deps}
    return header, packages, tail


def resolve(packages: dict[Key, dict]) -> dict[Key, dict]:
    """Each package's dependencies as keys of this same lockfile."""
    by_name: dict[str, list[Key]] = {}
    for key in packages:
        by_name.setdefault(key[0], []).append(key)
    out = {}
    for key, pkg in packages.items():
        deps = set()
        if pkg["deps"] is not None:
            for raw in pkg["deps"]:
                m = DEP_RE.match(raw)
                if not m:
                    raise Unsupported(f"dependency {raw!r}")
                cands = [k for k in by_name.get(m.group("name"), [])
                         if (m.group("version") is None or k[1] == m.group("version"))
                         and (m.group("source") is None or k[2] == m.group("source"))]
                if len(cands) != 1:
                    raise Unsupported(f"dependency {raw!r} of {key[0]} names {len(cands)} packages")
                deps.add(cands[0])
        out[key] = {"fields": dict(pkg["fields"]), "deps": deps}
    return out


def merge3(o, a, b):
    if a == b:
        return a
    if a == o:
        return b
    if b == o:
        return a
    raise Conflict


def merge_package(o: dict | None, a: dict | None, b: dict | None) -> dict | None:
    if a == b:
        return a
    if a == o:
        return b
    if b == o:
        return a
    if o is None or a is None or b is None:
        # Added on both sides differently, or deleted on one side and changed on the other.
        raise Conflict("added on both sides differently" if o is None else "deleted on one side, changed on the other")
    fields = {}
    for k in sorted(set(o["fields"]) | set(a["fields"]) | set(b["fields"])):
        try:
            v = merge3(o["fields"].get(k), a["fields"].get(k), b["fields"].get(k))
        except Conflict:
            raise Conflict(f"{k} changed on both sides") from None
        if v is not None:
            fields[k] = v
    od, ad, bd = o["deps"], a["deps"], b["deps"]
    deps = ((od & ad & bd) | (ad - od) | (bd - od)) - ((od - ad) | (od - bd))
    return {"fields": fields, "deps": deps}


def semver_key(v: str):
    core, _, pre = v.split("+", 1)[0].partition("-")
    nums = []
    for part in core.split("."):
        nums.append(int(part) if part.isdigit() else 0)
    while len(nums) < 3:
        nums.append(0)
    # A pre-release sorts before its release; identifiers compare numerically when numeric.
    if not pre:
        return (*nums, 1, ())
    ids = tuple((0, int(x), "") if x.isdigit() else (1, 0, x) for x in pre.split("."))
    return (*nums, 0, ids)


def package_sort_key(key: Key):
    return (key[0], semver_key(key[1]), key[2])


def encode(header: str, packages: dict[Key, dict], tail: str) -> str:
    by_name: dict[str, int] = {}
    by_name_version: dict[tuple, int] = {}
    for name, version, _ in packages:
        by_name[name] = by_name.get(name, 0) + 1
        by_name_version[(name, version)] = by_name_version.get((name, version), 0) + 1

    def dep_ref(key: Key) -> tuple:
        name, version, source = key
        if by_name[name] == 1:
            return (name, None, None)
        if by_name_version[(name, version)] == 1:
            return (name, version, None)
        return (name, version, source)

    def dep_str(ref: tuple) -> str:
        name, version, source = ref
        return name + (f" {version}" if version else "") + (f" ({source})" if source else "")

    out = [header.rstrip("\n") + "\n"]
    for key in sorted(packages, key=package_sort_key):
        pkg = packages[key]
        lines = ["", "[[package]]"]
        for k in FIELD_ORDER:
            if k in pkg["fields"]:
                lines.append(f'{k} = "{pkg["fields"][k]}"')
        if pkg["deps"]:
            lines.append("dependencies = [")
            # EncodablePackageId's derived order: name, then version, then source (None first).
            refs = sorted((dep_ref(d) for d in pkg["deps"]),
                          key=lambda r: (r[0], r[1] is not None, r[1] or "", r[2] is not None, r[2] or ""))
            lines += [f' "{dep_str(r)}",' for r in refs]
            lines.append("]")
        out.append("\n".join(lines) + "\n")
    text = "".join(out)
    if tail:
        text += "\n" + tail
    return text


def merge_text(o_text: str, a_text: str, b_text: str) -> str:
    oh, op, ot = parse(o_text)
    ah, ap, at = parse(a_text)
    bh, bp, bt = parse(b_text)
    header = merge3(oh, ah, bh)
    tail = merge3(ot, at, bt)
    o, a, b = resolve(op), resolve(ap), resolve(bp)
    merged: dict[Key, dict] = {}
    for key in set(o) | set(a) | set(b):
        try:
            pkg = merge_package(o.get(key), a.get(key), b.get(key))
        except Conflict as err:
            raise Conflict(f"{key[0]} {key[1]}: {err}") from None
        if pkg is not None:
            merged[key] = pkg
    # Dependencies on a package that is gone: the one package of that name left, else the package back.
    sides = (a, b, o)
    changed = True
    while changed:
        changed = False
        names: dict[str, list[Key]] = {}
        for k in merged:
            names.setdefault(k[0], []).append(k)
        for key, pkg in list(merged.items()):
            if not pkg["deps"]:
                continue
            for dep in list(pkg["deps"]):
                if dep in merged:
                    continue
                left = names.get(dep[0], [])
                if len(left) == 1:
                    pkg["deps"] = (pkg["deps"] - {dep}) | {left[0]}
                    continue
                back = next((side[dep] for side in sides if dep in side), None)
                if back is None:
                    raise Conflict(f"{key[0]} depends on {dep[0]} {dep[1]}, which neither side has")
                merged[dep] = {"fields": dict(back["fields"]), "deps": set(back["deps"])}
                changed = True
    # Cargo keeps only what the workspace reaches: path packages (no source) and what they depend on.
    reach = [k for k in merged if not k[2]]
    seen = set(reach)
    while reach:
        for dep in merged[reach.pop()]["deps"]:
            if dep not in seen and dep in merged:
                seen.add(dep)
                reach.append(dep)
    merged = {k: v for k, v in merged.items() if k in seen}
    return encode(header, merged, tail)


def main(argv: list[str]) -> int:
    if len(argv) == 2 and argv[0] == "--check":
        text = Path(argv[1]).read_text()
        h, p, t = parse(text)
        resolve(p)
        same = encode(h, resolve(p), t) == text
        if not same:
            print(f"{argv[1]}: not in cargo's own order or form", file=sys.stderr)
        return 0 if same else 1
    if len(argv) not in (3, 4):
        print(__doc__, file=sys.stderr)
        return 2
    o_path, a_path, b_path = argv[:3]
    label = argv[3] if len(argv) == 4 else a_path
    try:
        merged = merge_text(Path(o_path).read_text(), Path(a_path).read_text(), Path(b_path).read_text())
    except (Unsupported, Conflict, ValueError) as err:
        why = str(err) or "both sides changed one package"
        print(f"merge-cargo-lock: {label}: {why}; line merge instead", file=sys.stderr)
        r = subprocess.run(["git", "merge-file", "-L", "ours", "-L", "base", "-L", "theirs", a_path, o_path, b_path])
        return 1 if r.returncode != 0 else 0
    Path(a_path).write_text(merged)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
