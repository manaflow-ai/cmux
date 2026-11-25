#!/usr/bin/env python3
"""Bundle each redone last-demo folder (cockpit, collection, focus, tiling) into one profile file `cmux customize use` takes.

The same bundler as examples/customize-showcase/bundle.py (imported, not copied), run on this
folder: <name>/profile.json plus the files under ~/.config/cmux become <name>.json.
`--check` exits 1 while a bundle is stale.
"""
import importlib.util
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent
SHOWCASE = ROOT.parent.parent / "customize-showcase" / "bundle.py"

spec = importlib.util.spec_from_file_location("showcase_bundle", SHOWCASE)
showcase = importlib.util.module_from_spec(spec)
spec.loader.exec_module(showcase)


def main() -> int:
    check = "--check" in sys.argv[1:]
    stale = []
    for folder in sorted(p for p in ROOT.iterdir() if (p / "profile.json").is_file()):
        out = ROOT / f"{folder.name}.json"
        text = showcase.bundle(folder)
        if check:
            if not out.is_file() or out.read_text() != text:
                stale.append(out.name)
        else:
            out.write_text(text)
    if stale:
        print("stale: " + ", ".join(stale) + "; run examples/customize-demo/last-demo/bundle.py", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
