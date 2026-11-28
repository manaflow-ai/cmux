#!/usr/bin/env python3
"""Check Swift namespace declarations without interpreting literal/comment braces."""

import os
import re
import sys
from swift_source_mask import mask_swift_source

import argparse
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('--baseline', required=True)
parser.add_argument('--general-baseline', required=True)
parser.add_argument('--enum-roots', nargs='+', required=True)
parser.add_argument('--type-roots', nargs='+', required=True)
args = parser.parse_args()
baseline_path = args.baseline
general_baseline_path = args.general_baseline
roots = args.type_roots
enum_roots = [Path(root) for root in args.enum_roots]

baseline = set()
if os.path.exists(baseline_path):
    for raw in open(baseline_path, encoding="utf-8"):
        entry = raw.strip()
        if entry and not entry.startswith("#"):
            baseline.add(entry)

general_baseline = set()
if os.path.exists(general_baseline_path):
    for raw in open(general_baseline_path, encoding="utf-8"):
        entry = raw.rstrip("\n")
        if entry and not entry.startswith("#"):
            general_baseline.add(entry)

DECL = re.compile(
    r"(?m)^(?P<indent>[ \t]*)(?P<head>(?:@\w+(?:\([^)]*\))?[ \t]+)*"
    r"(?:(?:public|package|internal|open|final|private|fileprivate)[ \t]+)*"
    r"(?P<kind>struct|class|enum|actor)[ \t]+(?P<name>\w+))"
)
EXT = re.compile(r"(?m)^[ \t]*(?:@\w+(?:\([^)]*\))?[ \t]+)*"
                 r"(?:(?:public|package|internal|private|fileprivate)[ \t]+)?"
                 r"extension[ \t]+(?P<name>[\w.]+)")
MEMBER = re.compile(
    r"\b(case|init|func|var|let|subscript|struct|class|enum|actor|typealias)\b"
)
MARKER = re.compile(r"lint:allow|TRANSITIONAL|carve-out|justification|sanctioned", re.I)
# Protocols whose requirements are static by design; conformers are
# intentionally never instantiated.
STATIC_KEY_PROTOCOLS = re.compile(
    r"\b(PreferenceKey|EnvironmentKey|FocusedValueKey|LayoutValueKey|"
    r"TransactionKey|ContainerValueKey|EntryKey)\b"
)


def body_and_end(src, brace):
    depth, i = 1, brace + 1
    while i < len(src) and depth:
        if src[i] == "{":
            depth += 1
        elif src[i] == "}":
            depth -= 1
        i += 1
    return src[brace + 1:i - 1]


def depth_prefix(s):
    d, out = 0, []
    for ch in s:
        out.append(d)
        d += (ch == "{") - (ch == "}")
    return out


def tally(body, counts):
    dp = depth_prefix(body)
    for mm in MEMBER.finditer(body):
        if dp[mm.start()] != 0:
            continue
        kw = mm.group(0)
        line_start = body.rfind("\n", 0, mm.start()) + 1
        prefix = body[line_start:mm.start()]
        if "//" in prefix:
            continue
        if kw in ("struct", "enum", "actor", "typealias"):
            continue
        if kw == "class":
            continue  # nested class decl; `class func/var` is seen by func/var
        if kw == "case":
            counts["cases"] += 1
        elif kw == "init":
            if re.search(r"\b(private|fileprivate)\b", prefix):
                counts["private_inits"] += 1
            else:
                counts["open_inits"] += 1
        elif re.search(r"\b(static|class)\b", prefix):
            counts["statics"] += 1
        else:
            counts["instances"] += 1


fail = False
for root in roots:
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in (".build", "Tests")]
        for fn in sorted(filenames):
            if not fn.endswith(".swift") or fn.endswith("Tests.swift"):
                continue
            path = os.path.join(dirpath, fn)
            original = open(path, encoding="utf-8", errors="replace").read()
            src = mask_swift_source(original)
            lines = original.split("\n")

            if any(Path(path).is_relative_to(root) for root in enum_roots):
                for enum in re.finditer(r'\benum\s+(\w+)[^{]*\{', src):
                    name = enum.group(1)
                    body = body_and_end(src, enum.end() - 1)
                    depths = depth_prefix(body)
                    top = ''.join(ch if depths[i] == 0 else ' ' for i, ch in enumerate(body))
                    if re.search(r'(^|\n)\s*(indirect\s+)?case\s', top) or 'static' not in body:
                        continue
                    line = src.count('\n', 0, enum.start()) + 1
                    context = '\n'.join(lines[max(0, line - 3):line])
                    if 'lint:allow' in context or f'namespace-enum\t{path}\t{name}' in general_baseline:
                        continue
                    print(f'ERROR   namespace-enum               {path}:{line}  enum {name} (caseless, static members) -> scope onto the owning type')
                    fail = True

            ext_counts = {}
            for em in EXT.finditer(src):
                brace = src.find("{", em.end())
                if brace < 0:
                    continue
                name = em.group("name").split(".")[-1]
                counts = ext_counts.setdefault(
                    name,
                    {"cases": 0, "private_inits": 0, "open_inits": 0,
                     "statics": 0, "instances": 0},
                )
                tally(body_and_end(src, brace), counts)

            for m in DECL.finditer(src):
                head = m.group("head")
                if "public" not in head and "package" not in head:
                    continue
                brace = src.find("{", m.end())
                if brace < 0:
                    continue
                conformances = src[m.end():brace]
                if STATIC_KEY_PROTOCOLS.search(conformances):
                    continue
                counts = {"cases": 0, "private_inits": 0, "open_inits": 0,
                          "statics": 0, "instances": 0}
                tally(body_and_end(src, brace), counts)
                ext = ext_counts.get(m.group("name"))
                if ext:
                    for key in counts:
                        counts[key] += ext[key]
                if counts["statics"] == 0 or counts["instances"] > 0:
                    continue
                if m.group("kind") == "enum":
                    if counts["cases"] > 0:
                        continue
                else:
                    if counts["open_inits"] > 0:
                        continue
                line = src.count("\n", 0, m.start()) + 1
                ctx = "\n".join(lines[max(0, line - 4):line])
                if MARKER.search(ctx):
                    continue
                if f"{path}:{m.group('name')}" in baseline:
                    continue
                if f"namespace-type\t{path}\t{m.group('name')}" in general_baseline:
                    continue
                print(
                    f"ERROR   namespace-type               {path}:{line}  "
                    f"{m.group('kind')} {m.group('name')} (all-static public "
                    "surface, not instantiable) -> extension on the receiver "
                    "type or an instantiated value with injected dependencies"
                )
                fail = True

sys.exit(1 if fail else 0)
