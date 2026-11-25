#!/usr/bin/env python3
"""Bundle a nightly part that built in the background, or its last good copy, so one part never stops the nightly.

    nightly_stale_part.py bundle --state DIR --job NAME --name PART --built PATH --report FILE \
        --bin-env VAR --require-env VAR -- BUNDLE_COMMAND...

Leo, 2026-11-25 06:35Z, after a cmux-mobile-link compile error held the NEXT nightly for hours: "are we able to
decouple or". The iPhone host and the Screen Sharing helper are parts of the app, not the app: the app runs
without either (Settings says the feature is unavailable). So:

1. `background_build.py join` the part's build. If it built and BUNDLE_COMMAND bundles it (VAR=PATH, the require
   variable set), the part is current: it is copied to this Mac's last-good store (CMUX_NIGHTLY_LAST_GOOD, default
   ~/Library/Caches/cmux-nightly-last-good) and nothing else happens.
2. Otherwise the store's copy is bundled the same way (the bundle script still checks it is a Mach-O with the
   app's architectures), and the part is recorded as stale.
3. With no usable copy the app is bundled without the part (the variable unset, not required), recorded as missing.

A stale or missing part is a `::warning title=nightly stale part` in the run summary and an entry in FILE, which
nightly_fix_forward_issue.py outputs merges into the fix-forward issue. Only a failure to bundle with no part at
all (no app to bundle into) fails the step.
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent


def store_dir() -> Path:
    return Path(os.environ.get("CMUX_NIGHTLY_LAST_GOOD") or Path.home() / "Library/Caches/cmux-nightly-last-good")


def run(cmd: list[str], env: dict[str, str]) -> int:
    return subprocess.run(cmd, env=env).returncode


def bundle_env(bin_env: str, require_env: str, path: str | None) -> dict[str, str]:
    env = dict(os.environ)
    if path:
        env[bin_env], env[require_env] = path, "1"
    else:
        env.pop(bin_env, None)
        env[require_env] = ""
    return env


def keep(built: Path, name: str) -> None:
    """Copy a part that bundled to the store (temp file, then rename, so a reader never sees half a binary)."""
    try:
        store = store_dir()
        store.mkdir(parents=True, exist_ok=True)
        for src, dest in ((built, store / name), (Path(f"{built}.ref"), store / f"{name}.ref")):
            if src.is_file():
                tmp = dest.with_name(f".{dest.name}.{os.getpid()}")
                shutil.copy2(src, tmp)
                os.replace(tmp, dest)
    except OSError as exc:  # the store is a convenience: never the nightly's failure
        print(f"::warning title=nightly stale part::could not keep {name} as the last good copy: {exc}")


def record(report: Path, name: str, findings: list[str]) -> None:
    try:
        data = json.loads(report.read_text()) if report.is_file() else {}
    except (OSError, ValueError):
        data = {}
    failed = [item for item in data.get("failed") or [] if item.get("check") != f"stale part: {name}"]
    failed.append({"check": f"stale part: {name}", "findings": findings})
    report.parent.mkdir(parents=True, exist_ok=True)
    report.write_text(json.dumps({"failed": failed}, indent=2) + "\n", encoding="utf-8")
    print(f"::warning title=nightly stale part {name}::{findings[0]} -- the nightly ships")


def bundle(args: argparse.Namespace) -> int:
    joined = run([sys.executable, str(HERE / "background_build.py"), "join", "--state", args.state, args.job],
                 dict(os.environ)) == 0
    built = Path(args.built)
    why = f"{args.name}'s build failed (background job {args.job}; its log is above)"
    if joined and built.is_file():
        if run(args.command, bundle_env(args.bin_env, args.require_env, str(built))) == 0:
            keep(built, args.name)
            return 0
        why = f"{args.name} built but did not bundle (the bundle step's error is above)"
    elif joined:
        why = f"{args.name}'s build finished without {built}"
    last = store_dir() / args.name
    if last.is_file():
        ref = Path(f"{last}.ref")
        source = ref.read_text().strip()[:80] if ref.is_file() else "an earlier build"
        if run(args.command, bundle_env(args.bin_env, args.require_env, str(last))) == 0:
            record(Path(args.report), args.name, [f"{why}; bundled the last good copy ({source})"])
            return 0
        why += f"; the last good copy ({source}) did not bundle either"
    if run(args.command, bundle_env(args.bin_env, args.require_env, None)) != 0:
        print(f"::error title=nightly stale part {args.name}::{why}; bundling without it failed too")
        return 1
    record(Path(args.report), args.name, [f"{why}; this nightly ships without {args.name}"])
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="action", required=True)
    b = sub.add_parser("bundle")
    for flag in ("--state", "--job", "--name", "--built", "--report", "--bin-env", "--require-env"):
        b.add_argument(flag, required=True)
    b.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
    if args.command[:1] == ["--"]:
        args.command = args.command[1:]
    if not args.command:
        parser.error("bundle needs a BUNDLE_COMMAND after --")
    return bundle(args)


if __name__ == "__main__":
    sys.exit(main())
