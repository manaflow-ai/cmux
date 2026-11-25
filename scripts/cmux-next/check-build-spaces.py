#!/usr/bin/env python3
"""Build spaces in the cloud API Worker (backend/apps/api/src/build-space.ts; AGENTS.md "Dev builds are separate").

Usage: check-build-spaces.py ROOT

Reads the tree at ROOT (the pre-push gate's base and head trees; build-space.ts and wrangler.jsonc are in its CONTEXT,
so both sides have them) and prints one `<path>:<line>: <finding>` per violation, exit 1 when there is one:

- a Durable Object binding of wrangler.jsonc (any environment) that is in neither PER_BUILD_BINDINGS nor
  ACCOUNT_WIDE_BINDINGS of build-space.ts, or in both: every binding says whether a dev build's data in it is its own;
- an entry point that takes the spaced `Env` instead of the raw bindings (`WorkerEntrypoint<Env`,
  `WorkflowEntrypoint<Env`, `ExportedHandler<Env>`): its `this.env` would not be the request's space;
- a Durable Object class (`extends DurableObject<Env>` / `extends OwnerDO<`) whose file never calls `envForObject(`:
  its calls, alarms and outbox would leave its space;
- a raw env reaching an object (`raw.<X>_DO`), outside build-space.ts: a raw binding names objects in no space.

No build and no network: a few regexes over a handful of files.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

API = "backend/apps/api"
WRANGLER = f"{API}/wrangler.jsonc"
SPACES = f"{API}/src/build-space.ts"

BINDING = re.compile(r'\{\s*"name"\s*:\s*"([A-Z][A-Z0-9_]*)"\s*,\s*"class_name"\s*:')
LIST = re.compile(r"export const (PER_BUILD_BINDINGS|ACCOUNT_WIDE_BINDINGS)\s*=\s*\[(.*?)\]\s*as const", re.S)
NAME = re.compile(r'"([A-Z][A-Z0-9_]*)"')
SPACED_ENTRY = re.compile(r"\b(?:WorkerEntrypoint|WorkflowEntrypoint)<Env\b|\bExportedHandler<Env>")
OBJECT_CLASS = re.compile(r"\bclass\s+\w+\s+extends\s+(?:DurableObject<Env>|OwnerDO<)")
RAW_OBJECT = re.compile(r"\braw\.[A-Z][A-Z0-9_]*_DO\b")


def line_of(text: str, at: int) -> int:
    return text.count("\n", 0, at) + 1


def findings(root: Path) -> list[str]:
    out: list[str] = []
    wrangler, spaces = root / WRANGLER, root / SPACES
    if wrangler.is_file() and spaces.is_file():
        config, source = wrangler.read_text(encoding="utf-8"), spaces.read_text(encoding="utf-8")
        lists = {m.group(1): set(NAME.findall(m.group(2))) for m in LIST.finditer(source)}
        per, shared = lists.get("PER_BUILD_BINDINGS", set()), lists.get("ACCOUNT_WIDE_BINDINGS", set())
        for name in sorted(per & shared):
            out.append(f"{SPACES}:1: {name} is in both PER_BUILD_BINDINGS and ACCOUNT_WIDE_BINDINGS: it is one or the other")
        seen: set[str] = set()
        for m in BINDING.finditer(config):
            name = m.group(1)
            if name in seen:
                continue
            seen.add(name)
            if name not in per and name not in shared:
                out.append(f"{WRANGLER}:{line_of(config, m.start())}: the Durable Object binding {name} is in neither "
                           f"PER_BUILD_BINDINGS nor ACCOUNT_WIDE_BINDINGS of {SPACES}: say whether a dev build's data in it is its own")
    src = root / API / "src"
    if src.is_dir():
        for path in sorted(src.rglob("*.ts")):
            rel = path.relative_to(root).as_posix()
            text = path.read_text(encoding="utf-8", errors="replace")
            for m in SPACED_ENTRY.finditer(text):
                out.append(f"{rel}:{line_of(text, m.start())}: an entry point takes the raw bindings (RawEnv) and reaches objects "
                           f"through spacedEnv, never Env: `{m.group(0)}`")
            if OBJECT_CLASS.search(text) and "envForObject(" not in text:
                m = OBJECT_CLASS.search(text)
                out.append(f"{rel}:{line_of(text, m.start())}: a Durable Object class takes RawEnv in its constructor and passes "
                           f"envForObject(ctx, raw) to its base class, so its calls and alarms stay in its build space")
            if rel != SPACES:
                for m in RAW_OBJECT.finditer(text):
                    out.append(f"{rel}:{line_of(text, m.start())}: a raw env names objects in no build space: reach "
                               f"`{m.group(0)}` through spacedEnv(raw, space) or envForObject")
    return out


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(__doc__.strip().splitlines()[2], file=sys.stderr)
        return 2
    found = findings(Path(argv[1]))
    for line in found:
        print(line)
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
