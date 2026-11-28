"""Check what the composer prompt's extension registers in the slash menu."""
from __future__ import annotations

import json
from pathlib import Path


def check_composer(folder: Path) -> str | None:
    manifest = folder / "cmux-app.json"
    if not manifest.is_file():
        manifest = folder / "cmux-app.v2.json"
    try:
        app = json.loads(manifest.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        return f"could not read composer command manifest: {error}"

    try:
        commands = app["implements"]["cmux.composer.command/1"]["options"]["commands"]
    except (KeyError, TypeError):
        return "missing cmux.composer.command/1 options.commands"
    if not isinstance(commands, list):
        return "expected cmux.composer.command/1 options.commands to be a list"

    expected_insert = (
        "Review the changes on this branch: what could break, what is missing a test, "
        "and what you would rename."
    )
    for command in commands:
        if isinstance(command, dict) and command.get("name") == "review":
            if command.get("description") != "Review my changes":
                return 'expected the /review menu description to be "Review my changes"'
            if command.get("insert") != expected_insert:
                return f"expected /review to insert {expected_insert!r}"
            return None
    return "missing /review in cmux.composer.command/1 options.commands"
