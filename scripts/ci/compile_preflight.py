#!/usr/bin/env python3
"""The compile preflight's two steps (.github/workflows/cmux-next-compile-preflight.yml).

Leo, 2026-11-27: "surely we can just have legit build fail preflight checks" / "like the classes of failures before
we can analyze them".

  web-touched ROOT BASE HEAD   prints `web=true` when a file BASE..HEAD changes is one web-bundle-key.py --routed
                               names (the web bundles' own inputs, imports outside webviews/ included), else
                               `web=false`; the reason goes to stderr.
  web-build ROOT OUT           runs scripts/cmux-next/build-web-bundles.sh --out-root OUT (the build the app,
                               NIGHTLY and safe-push.sh run) and, when it fails, names each bundler error as a
                               GitHub annotation, then exits with the build's code.

A file that reaches no web bundle (a gallery is an input too: webviews/ is a whole-directory input) builds nothing.
"""
from __future__ import annotations

import importlib.util
import os
import re
import subprocess
import sys
import time
from pathlib import Path

KEY_SCRIPT = "scripts/cmux-next/web-bundle-key.py"
BUILD_SCRIPT = "scripts/cmux-next/build-web-bundles.sh"
# A bundler's error line: esbuild's `✘ [ERROR] ...` and `file:line:col: ERROR: ...`, the react-compiler plugin's
# text inside them, tsc's or a script's `error: ...` (cmux#57269: "Identifier 'layoutGeometry' has already been
# declared"; cmux#46930: `Could not resolve "../../components/SignInButton"`).
ERROR_LINE = re.compile(r"\[ERROR\]|: ERROR: |^error: |Could not resolve")
MAX_ANNOTATIONS = 10


def key_module(root: Path):
    """web-bundle-key.py of the checkout at ROOT, loaded as a module (its name has dashes)."""
    spec = importlib.util.spec_from_file_location("web_bundle_key", root / KEY_SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def changed_files(root: Path, base: str, head: str) -> list[str]:
    out = subprocess.run(["git", "-C", str(root), "diff", "--name-only", "--no-renames", base, head],
                         check=True, capture_output=True, text=True).stdout
    return [line for line in out.splitlines() if line]


def web_touched(files: list[str], routed: list[str], matcher_of) -> list[str]:
    """The FILES a web bundle reads: those any ROUTED pathspec matches (matcher_of is web-bundle-key's
    pathspec_matcher)."""
    matches = matcher_of(routed)
    return [f for f in files if matches(f)]


def cmd_web_touched(root: Path, base: str, head: str) -> int:
    module = key_module(root)
    files = changed_files(root, base, head)
    hit = web_touched(files, module.routed_inputs(str(root)), module.pathspec_matcher)
    if hit:
        more = f" and {len(hit) - 1} more" if len(hit) > 1 else ""
        print(f"web bundle sources changed: {hit[0]}{more}", file=sys.stderr)
    else:
        print(f"none of the {len(files)} changed files is a web bundle input", file=sys.stderr)
    print(f"web={'true' if hit else 'false'}")
    return 0


def error_lines(log: str) -> list[str]:
    """The bundler error lines of a failed build's LOG, deduplicated, first MAX_ANNOTATIONS."""
    seen: list[str] = []
    for line in log.splitlines():
        text = line.strip()
        if ERROR_LINE.search(text) and text not in seen:
            seen.append(text)
    return seen[:MAX_ANNOTATIONS]


def cmd_web_build(root: Path, out: str) -> int:
    started = time.monotonic()
    proc = subprocess.Popen(["bash", str(root / BUILD_SCRIPT), "--out-root", out], cwd=root,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, errors="replace")
    log = []
    for line in proc.stdout:
        sys.stdout.write(line)
        log.append(line)
    code = proc.wait()
    took = time.monotonic() - started
    if code == 0:
        print(f"compile preflight: the web bundles built in {took:.0f} s")
        return 0
    errors = error_lines("".join(log)) or [f"{BUILD_SCRIPT} exited {code}"]
    for text in errors:
        print(f"::error title=web bundle build::{text}")
    print(f"compile preflight: the web bundle build failed in {took:.0f} s (exit {code}); this change would turn "
          f"feat-cmux-next's web bundles and NIGHTLY red")
    return code or 1


def main(argv: list[str]) -> int:
    if len(argv) == 5 and argv[1] == "web-touched":
        return cmd_web_touched(Path(argv[2]).resolve(), argv[3], argv[4])
    if len(argv) == 4 and argv[1] == "web-build":
        return cmd_web_build(Path(argv[2]).resolve(), argv[3])
    print(__doc__.strip(), file=sys.stderr)
    return 2


if __name__ == "__main__":
    os.environ.setdefault("PYTHONDONTWRITEBYTECODE", "1")
    sys.exit(main(sys.argv))
