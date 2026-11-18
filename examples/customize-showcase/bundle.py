#!/usr/bin/env python3
"""Bundle each showcase folder into one profile file `cmux customize use` takes.

A folder holds profile.json (name, description, settings) and the files the setup
writes under ~/.config/cmux (customize/cmux-app.json, customize/main.js). The bundle
is <name>.json next to it. Run it after an edit; cmux-customize's showcase test
fails while a bundle is stale.
"""
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent


def bundle(folder: pathlib.Path) -> str:
    meta = json.loads((folder / "profile.json").read_text())
    files = {}
    for path in sorted(folder.rglob("*")):
        rel = path.relative_to(folder).as_posix()
        if path.is_file() and rel != "profile.json":
            files[rel] = path.read_text()
    profile = {
        "cmuxProfile": 1,
        "name": meta["name"],
        "description": meta["description"],
        "created_ms": 0,
        "settings": meta["settings"],
        "files": files,
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
        print("stale: " + ", ".join(stale) + "; run examples/customize-showcase/bundle.py", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
