#!/usr/bin/env bash
# The app FFI release workflow builds on a push that changes an FFI input:
# every input that scripts/cmux-next/check-app-ffi-pin.sh derives from the
# Cargo path dependencies of cmux-app-ffi must be one of its push paths. The
# hand list lacked cmux-remote-browser, so the rb-client push cf25b525a03b
# started no build (2026-10-07). A crate's tests/, benches/ and examples/
# (--list-excluded) are not inputs: a push changing only them builds nothing,
# and a push changing a tests/ directory a library file names still builds.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
workflow="$root/.github/workflows/app-ffi-release.yml"
check="$root/scripts/cmux-next/check-app-ffi-pin.sh"
inputs="$(bash "$check" --list-inputs)"
excluded="$(bash "$check" --list-excluded)"
# GitHub's push path filter: the last matching pattern decides, a leading ! excludes, * stays in one folder, ** does not.
python3 -I - "$workflow" "$root" "$inputs" "$excluded" <<'PY'
import re, sys
from pathlib import Path

workflow, root, inputs, excluded = sys.argv[1], Path(sys.argv[2]), sys.argv[3].split(), sys.argv[4].split()
text = Path(workflow).read_text(encoding="utf-8")
block = re.search(r"^  push:\n(?:    .*\n)*?    paths:\n((?:      (?:- .*|#.*)\n)+)", text, re.M).group(1)
patterns = [m.group(1) for m in re.finditer(r'^      - "([^"]+)"$', block, re.M)]


def regex(glob):
    out = ""
    for part in re.split(r"(\*\*|\*)", glob):
        out += ".*" if part == "**" else "[^/]*" if part == "*" else re.escape(part)
    return re.compile(out + r"\Z")


def builds(path):
    hit = False
    for pattern in patterns:
        negate = pattern.startswith("!")
        if regex(pattern.lstrip("!")).match(path):
            hit = not negate
    return hit


crates = [i for i in inputs if (root / i / "Cargo.toml").is_file()]
kept = [f"{c}/{n}" for c in crates for n in ("tests", "benches", "examples") if f"{c}/{n}" not in excluded]
fail = [f"input {i}" for i in inputs if not builds(f"{i}/src/lib.rs" if i in crates else i)]
fail += [f"crate manifest {c}/Cargo.toml" for c in crates if not builds(f"{c}/Cargo.toml")]
fail += [f"named test directory {k}" for k in kept if not builds(f"{k}/x.rs")]
fail += [f"excluded {d} builds" for d in excluded if builds(f"{d}/x.rs")]
if fail:
    print("FAIL: .github/workflows/app-ffi-release.yml push paths disagree with check-app-ffi-pin.sh:", file=sys.stderr)
    for line in fail:
        print(f"  {line}", file=sys.stderr)
    sys.exit(1)
PY
echo "app-ffi-release-paths.test.sh: ok"
