#!/usr/bin/env python3
"""Bundle the whole-window setups the demo previews: examples/customize-showcase (cockpit, collection,
focus, ide, right-handed, tiling) and the Leo collection (examples/customize/leo: dusk, daylight,
neon, as leo-<name>.json).

Each folder's own bundler (customize-showcase/bundle.py, customize/leo/bundle.py; imported, not
copied), so each file here is byte for byte the profile its own folder bundles.
`--check` exits 1 while a bundle is stale or a setup has no bundle.
"""
import importlib.util
import pathlib
import sys

HERE = pathlib.Path(__file__).resolve().parent
EXAMPLES = HERE.parent.parent
SHOWCASE = EXAMPLES / "customize-showcase"

LEO = EXAMPLES / "customize" / "leo"


def load(name: str, path: pathlib.Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


showcase = load("showcase_bundle", SHOWCASE / "bundle.py")
leo = load("leo_bundle", LEO / "bundle.py")


def sources() -> dict[str, tuple]:
    """Bundle name -> (source folder, the bundler that folder's own bundle.py uses)."""
    out = {}
    for folder in sorted(p for p in SHOWCASE.iterdir() if (p / "profile.json").is_file()):
        out[f"{folder.name}.json"] = (folder, showcase.bundle)
    for folder in sorted(p for p in LEO.iterdir() if (p / "profile.json").is_file()):
        out[f"leo-{folder.name}.json"] = (folder, leo.bundle)
    return out


def main() -> int:
    check = "--check" in sys.argv[1:]
    stale = []
    wanted = sources()
    for name, (folder, bundle) in wanted.items():
        out = HERE / name
        text = bundle(folder)
        if check:
            if not out.is_file() or out.read_text() != text:
                stale.append(name)
        else:
            out.write_text(text)
    extra = sorted(p.name for p in HERE.glob("*.json") if p.name not in wanted)
    if extra:
        print("no source setup for: " + ", ".join(extra), file=sys.stderr)
        return 1
    if stale:
        print("stale: " + ", ".join(stale) + "; run examples/customize-demo/showcase/bundle.py", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
