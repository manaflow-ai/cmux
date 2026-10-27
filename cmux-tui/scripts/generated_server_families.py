"""Commands whose daemon `Command` variants cmux-ipc build.rs generates.

The families crates/cmux-ipc/server-families.json lists (p05-ipc-026, queue
Q15) have no hand-written variant in server.rs: `server_command_enum!` adds
one per command of the family, with params from spec/sdk-schema.json. The
checkers that read the `Command` enum's source count these commands as served,
and their request fields agree with the schema because they are made from it.
One reader for check-sdk-schema.py and check-spec-inventory.py.
"""

from __future__ import annotations

import json
from collections.abc import Mapping
from pathlib import Path
from typing import Any


class GeneratedFamiliesError(ValueError):
    pass


def generated_commands(tui: Path, sdk: Mapping[str, Any]) -> set[str]:
    """The `sdk` command names of every family server-families.json lists.
    A tree without the list (the checkers' test fixtures) generates none;
    cmux-ipc's build fails without it, so the real tree always has it."""

    path = tui / "crates/cmux-ipc/server-families.json"
    if not path.exists():
        return set()
    try:
        listed = json.loads(path.read_text(encoding="utf-8")).get("families")
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise GeneratedFamiliesError(f"cannot read {path.name}: {error}") from error
    if not isinstance(listed, list) or not all(isinstance(name, str) for name in listed):
        raise GeneratedFamiliesError(f"{path.name} families must be a list of names")
    families = sdk.get("families")
    commands = sdk.get("commands")
    if not isinstance(families, Mapping) or not isinstance(commands, Mapping):
        raise GeneratedFamiliesError("sdk-schema.json needs families and commands objects")
    ids = set()
    for name in listed:
        family = families.get(name)
        if not isinstance(family, Mapping) or not isinstance(family.get("id"), int):
            raise GeneratedFamiliesError(f"{path.name} lists unknown family {name!r}")
        ids.add(family["id"])
    return {
        name
        for name, command in commands.items()
        if isinstance(command, Mapping)
        and isinstance(command.get("method_id"), int)
        and command["method_id"] >> 8 in ids
    }
