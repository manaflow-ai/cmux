#!/usr/bin/env python3
"""Bundle each glass look into one profile file `cmux customize use` takes.

A look folder holds profile.json (name, description, settings), its theme file
(themes/glass-<look>.json) and, for some, an agent-pane/theme.css. The bundle is <look>.json
next to the folders. Run it after an edit; `--check` exits 1 while a bundle is stale.
"""
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent


def files_under(folder: pathlib.Path) -> dict:
    return {
        path.relative_to(folder).as_posix(): path.read_text()
        for path in sorted(folder.rglob("*"))
        if path.is_file() and path.name != "profile.json"
    }


def bundle(folder: pathlib.Path) -> str:
    meta = json.loads((folder / "profile.json").read_text())
    profile = {
        "cmuxProfile": 1,
        "name": meta["name"],
        "description": meta["description"],
        "created_ms": 0,
        "settings": meta["settings"],
        "files": dict(sorted(files_under(folder).items())),
    }
    return json.dumps(profile, indent=2, ensure_ascii=False) + "\n"


def main() -> int:
    check = "--check" in sys.argv[1:]
    stale = []
    for folder in sorted(p for p in ROOT.iterdir() if (p / "profile.json").is_file()):
        out = ROOT / f"{folder.name}.json"
        text = bundle(folder)
        if check:
            if not out.is_file() or out.read_text() != text:
                stale.append(out.name)
        else:
            out.write_text(text)
    if stale:
        print("stale: " + ", ".join(stale) + "; run examples/customize-demo/glass/bundle.py", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
