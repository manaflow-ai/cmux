#!/usr/bin/env python3
"""Check that this Mac has every CI Xcode pin and every configured app path.

For a remote Mac, pass --pin and --app values and stream this file over ssh:
  ssh HOST python3 - --exact --pin 27.2 --app NAME=/Applications/Xcode_27.2.app < xcode_pin_audit.py

--exact is the fleet's one-Xcode detector (Leo, 2026-11-26: "xcode 27.2 across the fleet standardized, no
more old versions"): any installed /Applications/Xcode*.app that is not the host's pool pin is an error, so a
host that kept an old Xcode, or never got the pin, fails. Without --pin it holds the host to the pin
xcode-pins.txt names for its own macOS major (`sw_vers -productVersion`, or --macos-major).
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


def host_pin(path: Path, macos_major: str) -> str:
    """The pin xcode-pins.txt names for a macOS `macos_major` host."""
    for line in path.read_text().splitlines():
        fields = line.split("#", 1)[0].split()
        if len(fields) == 2 and fields[0] == macos_major:
            return fields[1]
    raise ValueError(f"{path} names no Xcode for macOS {macos_major}")


def macos_major() -> str:
    result = subprocess.run(["sw_vers", "-productVersion"], check=True, text=True, capture_output=True, timeout=20)
    return result.stdout.strip().split(".")[0]


def off_pin(pins: set[str], applications_dir: Path) -> list[str]:
    """Every installed Xcode whose version is not a pool pin (a symlink to a pinned app is the same app)."""
    errors: list[str] = []
    pin_text = ", ".join(sorted(pins))
    seen: set[Path] = set()
    for app in sorted(applications_dir.glob("Xcode*.app")):
        real = app.resolve()
        if real in seen:
            continue
        seen.add(real)
        found = version(app)
        if found not in pins:
            errors.append(f"{app} is Xcode {found or 'unknown'}, off the fleet pin {pin_text}; "
                          "remove it after this host's first green job on the pin")
    return errors


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
    parser.add_argument("--exact", action="store_true",
                        help="also fail on any installed Xcode that is not the pool pin (the one-Xcode detector)")
    parser.add_argument("--macos-major", help="with --exact and no --pin: the host's macOS major (default sw_vers)")
    args = parser.parse_args(argv)
    try:
        if args.pin:
            pins = set(args.pin)
        elif args.exact:
            pins = {host_pin(args.pins_file, args.macos_major or macos_major())}
        else:
            pins = pool_pins(args.pins_file)
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
        if args.exact:
            errors += off_pin(pins, args.applications_dir)
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
