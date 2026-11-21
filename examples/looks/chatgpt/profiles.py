#!/usr/bin/env python3
"""Generate preview.json for setups whose installation reads adjacent files.

Run with --check to compare checked-in profiles to their source files.
Setups containing only settings and inline files can be previewed directly.
"""

import argparse
import json
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parent
STYLES = ("agent-pane", "markdown", "diff", "picker", "fileViewer")


def sidecars(folder):
    # cmux-customize's setup::repo_files scans these paths during install.
    paths = [folder / "keybindings.json"]
    paths.extend(folder / style / "theme.css" for style in STYLES)
    for part, pattern in (("themes", "*.json"), ("customize", "*")):
        for path in (folder / part).rglob(pattern):
            if any(
                name.startswith(".") or name.endswith("~") or name == "node_modules"
                for name in path.relative_to(folder).parts
            ):
                continue
            paths.append(path)
    return sorted(path for path in paths if path.is_file())


def preview(manifest):
    setup = json.loads(manifest.read_text(encoding="utf-8"))
    folder = manifest.parent
    paths = sidecars(folder)
    if not paths:
        return None
    files = dict(setup.get("files", {}))
    for path in paths:
        logical = path.relative_to(folder).as_posix()
        if logical in files:
            raise ValueError(f"{manifest}: {logical} appears both inline and on disk")
        files[logical] = path.read_bytes().decode("utf-8")
    profile = {
        "cmuxProfile": setup["cmuxProfile"],
        "name": setup["name"],
        "description": setup.get("description", ""),
        "settings": setup.get("settings", {}),
        "files": dict(sorted(files.items())),
    }
    return json.dumps(profile, indent=2, ensure_ascii=False) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="report differences without writing")
    args = parser.parse_args()
    stale = []
    for manifest in sorted(ROOT.glob("*/cmux-setup.json")):
        output = manifest.with_name("preview.json")
        expected = preview(manifest)
        if expected is None:
            if output.exists():
                stale.append(f"{output.relative_to(ROOT)}: obsolete; preview cmux-setup.json directly")
            continue
        if args.check:
            if not output.exists() or output.read_bytes() != expected.encode("utf-8"):
                stale.append(f"{output.relative_to(ROOT)}: regenerate with {Path(__file__).name}")
        else:
            output.write_text(expected, encoding="utf-8")
    for message in stale:
        print(message, file=sys.stderr)
    return int(bool(stale))


if __name__ == "__main__":
    sys.exit(main())
