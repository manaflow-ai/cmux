#!/usr/bin/env python3
"""Run every piece of a package script and fail at the end, so one red guard never hides the rest.

`bun run check` in webviews was one `&&` chain: a red text-focus guard (AddDeviceView.swift, 2026-10-22)
stopped it before fmt, lint and the type check, so a local run, the web-bundles dispatch and iroh-v2
never reported those. The chain now lives in `check:pieces`, which CI (ci-web.yml) and the pre-push
lint (scripts/web_lint_prepush.py check_pieces) already run piece by piece; `check` runs this.

  python3 ../scripts/cmux-next/run-check-pieces.py [SCRIPT]   (from the package directory; SCRIPT defaults
                                                              to check:pieces)

Prints each piece's output under a header, then one line per red piece. Exits 1 when any piece failed.
"""
import json
import os
import subprocess
import sys
from pathlib import Path


def pieces(package: Path, script: str) -> list[str]:
    body = json.loads((package / "package.json").read_text(encoding="utf-8")).get("scripts", {}).get(script)
    if not body:
        raise SystemExit(f"run-check-pieces: {package / 'package.json'} has no {script!r} script")
    return [piece.strip() for piece in body.split("&&") if piece.strip()]


def main(argv: list[str]) -> int:
    script = argv[1] if len(argv) > 1 else "check:pieces"
    package = Path.cwd()
    env = dict(os.environ, PATH=f"{package / 'node_modules' / '.bin'}{os.pathsep}{os.environ.get('PATH', '')}")
    red = []
    for piece in pieces(package, script):
        print(f"==> {piece}", flush=True)
        if subprocess.run(piece, shell=True, cwd=package, env=env).returncode != 0:
            red.append(piece)
    if red:
        print(f"\n{len(red)} red:", file=sys.stderr)
        for piece in red:
            print(f"  {piece}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
