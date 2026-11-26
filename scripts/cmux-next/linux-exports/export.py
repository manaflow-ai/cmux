"""Write or check the settings exports off the Mac (see export-settings-linux.sh).

Exit codes: 0 written / fresh, 1 stale (--check; the stale paths on stderr), 2 cannot decide
(the Swift changed shape, a catalog key is missing, or anything else): CI falls back to the Mac.
"""
from __future__ import annotations

import argparse
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import mdm  # noqa: E402
import settings_schema  # noqa: E402

SETTINGS_SCHEMA = "schemas/settings/settings-schema.json"
DEFAULT_LIST = "scripts/cmux-next/settings-exports.txt"


def repo_root():
    out = subprocess.run(["git", "rev-parse", "--show-toplevel"], cwd=HERE, check=True,
                         stdout=subprocess.PIPE, universal_newlines=True)
    return out.stdout.strip()


def listed(root):
    path = os.environ.get("CMUX_SETTINGS_EXPORTS_LIST") or os.path.join(root, DEFAULT_LIST)
    names = []
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if line and not line.startswith("#"):
                names.append(line)
    return names


def settings_files(root):
    document = settings_schema.Schema(root).document()
    out = {SETTINGS_SCHEMA: settings_schema.djson.dumps(document, pretty=True) + "\n"}
    out.update(mdm.files(root, document))
    wanted = listed(root)
    unknown = [name for name in wanted if name not in out]
    if unknown:
        raise RuntimeError("the settings exports list names files this exporter does not write: "
                           + ", ".join(unknown))
    return {name: out[name] for name in wanted}


def current(root, rel):
    try:
        with open(os.path.join(root, rel), encoding="utf-8", newline="") as handle:
            return handle.read()
    except FileNotFoundError:
        return None


def main(argv=None):
    parser = argparse.ArgumentParser(prog="export-settings-linux.sh")
    parser.add_argument("--check", action="store_true", help="exit 1 listing stale files; write nothing")
    args = parser.parse_args(argv)
    try:
        root = repo_root()
        files = settings_files(root)
    except Exception as error:  # every failure is "cannot decide": the Mac does it
        print("export-settings-linux: cannot decide (%s: %s); run the Swift export on a Mac"
              % (type(error).__name__, error), file=sys.stderr)
        return 2
    stale = [rel for rel, text in sorted(files.items()) if current(root, rel) != text]
    if args.check:
        for rel in stale:
            print("stale: %s" % rel, file=sys.stderr)
        return 1 if stale else 0
    for rel in stale:
        path = os.path.join(root, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8", newline="") as handle:
            handle.write(files[rel])
        print("wrote %s" % rel)
    return 0


if __name__ == "__main__":
    sys.exit(main())
