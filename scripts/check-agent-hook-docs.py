#!/usr/bin/env python3
"""Keep the public agent-hook setup list aligned with the CLI catalog."""

from pathlib import Path
import re
import sys


ROOT = Path(__file__).resolve().parents[1]
CATALOG = ROOT / "CLI" / "CMUXCLI+AgentHookCatalog.swift"
DOCS = ROOT / "docs" / "agent-hooks.md"


def catalog_agent_names(source: str) -> set[str]:
    definitions = list(re.finditer(r'AgentHookDef\(\s*name:\s*"([^"]+)"', source))
    names: set[str] = set()

    for index, definition in enumerate(definitions):
        end = definitions[index + 1].start() if index + 1 < len(definitions) else len(source)
        block = source[definition.start() : end]
        names.add(definition.group(1))

        aliases = re.search(r"\baliases:\s*\[([^\]]*)\]", block)
        if aliases:
            names.update(re.findall(r'"([^"]+)"', aliases.group(1)))

    if not definitions:
        raise ValueError(f"No AgentHookDef entries found in {CATALOG.relative_to(ROOT)}")
    return names


def documented_agent_names(source: str) -> list[str]:
    setup_list = re.search(
        r"Supported agent names are(?P<names>.*?)\. `cmux hooks setup` skips",
        source,
        re.DOTALL,
    )
    if not setup_list:
        raise ValueError("Could not find the supported agent names paragraph in docs/agent-hooks.md")
    return re.findall(r"`([^`]+)`", setup_list.group("names"))


def main() -> int:
    catalog_names = catalog_agent_names(CATALOG.read_text(encoding="utf-8"))
    documented_names = documented_agent_names(DOCS.read_text(encoding="utf-8"))
    documented_set = set(documented_names)
    missing = sorted(catalog_names - documented_set)
    unknown = sorted(documented_set - catalog_names)
    duplicates = sorted(name for name in documented_set if documented_names.count(name) > 1)

    if missing or unknown or duplicates:
        if missing:
            print(f"Missing from docs/agent-hooks.md: {', '.join(missing)}", file=sys.stderr)
        if unknown:
            print(f"Not present in the hook catalog: {', '.join(unknown)}", file=sys.stderr)
        if duplicates:
            print(f"Duplicated in docs/agent-hooks.md: {', '.join(duplicates)}", file=sys.stderr)
        return 1

    print(f"Agent hook docs match the catalog ({len(catalog_names)} names and aliases).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
