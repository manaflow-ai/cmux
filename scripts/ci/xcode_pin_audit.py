#!/usr/bin/env python3
"""Check that this Mac has every CI Xcode pin and every configured app path.

For a remote Mac, pass --pin and --app values and stream this file over ssh:
  ssh HOST python3 - --pin 26.3 --pin 26.6 --app NAME=/Applications/Xcode_26.6.app < xcode_pin_audit.py
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys


APP_NAME = re.compile(r"^Xcode_(\d+(?:\.\d+)*)\.app$")
VAR_NAME = re.compile(r"^CMUX_CI_XCODE_APP_[A-Z0-9_]+$")
DEFAULT_PINS = Path(__file__).with_name("xcode-pins.txt")


def pool_pins(path: Path) -> set[str]:
    pins: set[str] = set()
    for line in path.read_text().splitlines():
        fields = line.split("#", 1)[0].split()
        if fields:
            if len(fields) != 2 or not fields[0].isdigit() or not re.fullmatch(r"\d+(?:\.\d+)*", fields[1]):
                raise ValueError(f"invalid pool pin: {line}")
            pins.add(fields[1])
    return pins


def github_apps(repo: str) -> dict[str, str]:
    result = subprocess.run(["gh", "variable", "list", "-R", repo, "--json", "name,value"],
                            check=True, text=True, capture_output=True)
    return {item["name"]: item["value"] for item in json.loads(result.stdout)
            if VAR_NAME.fullmatch(item["name"]) and item["value"]}


def version(app: Path) -> str | None:
    developer = app / "Contents" / "Developer"
    if not developer.is_dir():
        return None
    try:
        result = subprocess.run(["xcodebuild", "-version"], env={**os.environ, "DEVELOPER_DIR": str(developer)},
                                text=True, capture_output=True, check=True, timeout=20)
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired):
        return None
    first = result.stdout.splitlines()[0] if result.stdout else ""
    return first.removeprefix("Xcode ") if first.startswith("Xcode ") else None


def audit(pins: set[str], apps: dict[str, str], applications_dir: Path) -> list[str]:
    errors: list[str] = []
    installed = {app: version(app) for app in sorted(applications_dir.glob("Xcode*.app"))}
    for pin in sorted(pins):
        if pin not in installed.values():
            errors.append(f"pool pin Xcode {pin} is missing")
    for name, path in sorted(apps.items()):
        app = Path(path)
        expected = APP_NAME.fullmatch(app.name)
        if not expected:
            errors.append(f"{name}={path} must name Xcode_<version>.app")
            continue
        found = installed.get(app)
        if found is None:
            found = version(app)
        if found != expected.group(1):
            errors.append(f"{name}={path} requires Xcode {expected.group(1)}; found {found or 'none'}")
    return errors


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pins-file", type=Path, default=DEFAULT_PINS)
    parser.add_argument("--pin", action="append", default=[], help="pool Xcode version; repeat for remote use")
    parser.add_argument("--app", action="append", default=[], metavar="NAME=PATH")
    parser.add_argument("--github-vars", metavar="OWNER/REPO", help="read CMUX_CI_XCODE_APP_* repo variables")
    parser.add_argument("--applications-dir", type=Path, default=Path("/Applications"))
    args = parser.parse_args(argv)
    try:
        pins = set(args.pin) if args.pin else pool_pins(args.pins_file)
        apps = {name: value for name, value in os.environ.items() if VAR_NAME.fullmatch(name) and value}
        if args.github_vars:
            apps.update(github_apps(args.github_vars))
        for pair in args.app:
            name, sep, path = pair.partition("=")
            if not sep or not VAR_NAME.fullmatch(name) or not path:
                parser.error(f"invalid --app: {pair}")
            apps[name] = path
        if not pins:
            parser.error("no Xcode pool pins supplied")
        errors = audit(pins, apps, args.applications_dir)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"xcode pin audit: {error}", file=sys.stderr)
        return 2
    host = os.uname().nodename
    if errors:
        for error in errors:
            print(f"{host}: {error}")
        return 1
    print(f"{host}: Xcode pins present: {', '.join(sorted(pins))}; app paths checked: {len(apps)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
