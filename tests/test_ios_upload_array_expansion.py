#!/usr/bin/env python3
"""ios/scripts/upload-testflight.sh must expand possibly-empty arrays safely.

The script runs under `set -euo pipefail` on a macOS runner, whose /bin/bash is
3.2.57. In bash before 4.4, expanding an empty array as "${arr[@]}" while `set -u`
is active is an unbound-variable error, not an empty list.

This is not hypothetical. On 2026-09-22 the App Store Connect upload finished --
the evidence artifact records {"uploaded": true} and "Upload committed in App
Store Connect" -- and the script then died on:

    ./ios/scripts/upload-testflight.sh: line 1741: NOTES_SOURCE_ARGS[@]: unbound variable

NOTES_SOURCE_ARGS is empty whenever the run is not in range-notes mode and the
changelog version guard is off, which is the normal appstore lane. The job was
marked failed after a successful upload, so the steps that assign the build to
testers were skipped and the build reached nobody.

The rule enforced here is the form already used elsewhere in this repository and
twice in this same script: ${arr[@]+"${arr[@]}"}. It is identical for a
non-empty array and expands to nothing when the array is empty.
"""

import os
import re
import subprocess
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(REPO_ROOT, "ios", "scripts", "upload-testflight.sh")

FAILURES = []


def _check(cond, msg):
    if not cond:
        FAILURES.append(msg)
        print(f"FAIL: {msg}")
    else:
        print(f"ok: {msg}")


def _bash_argc(snippet):
    """Return the argument count a snippet produces, under the script's own flags."""
    program = f'set -euo pipefail\ncount() {{ printf "%s" "$#"; }}\n{snippet}\n'
    result = subprocess.run(["bash", "-c", program], capture_output=True, text=True)
    if result.returncode != 0:
        return f"error: {result.stderr.strip()}"
    return result.stdout.strip()


def main():
    source = open(SCRIPT, encoding="utf-8").read()

    declared_empty = sorted(set(re.findall(r"^\s*([A-Za-z_][A-Za-z0-9_]*)=\(\)\s*$", source, re.M)))
    _check(declared_empty, "the script declares at least one empty array to check")

    for name in declared_empty:
        # The guarded form contains "${name[@]}" inside it, so remove every
        # guarded occurrence first; whatever "${name[@]}" remains is bare.
        stripped = source.replace('${%s[@]+"${%s[@]}"}' % (name, name), "")
        bare = re.findall(r'"\$\{' + re.escape(name) + r'\[@\]\}"', stripped)
        _check(
            not bare,
            f"{name} is never expanded bare (found {len(bare)}; "
            f'use ${{{name}[@]+"${{{name}[@]}}"}})',
        )

    # The guard must be a no-op for a populated array and empty for an empty one.
    _check(_bash_argc('a=(); count ${a[@]+"${a[@]}"}') == "0",
           "guarded expansion of an empty array yields no arguments")
    _check(_bash_argc('a=(one "two three"); count ${a[@]+"${a[@]}"}') == "2",
           "guarded expansion preserves argument boundaries of a populated array")

    if FAILURES:
        print(f"\n{len(FAILURES)} failure(s)")
        sys.exit(1)
    print("\nall ios upload array expansion tests passed")


if __name__ == "__main__":
    main()
