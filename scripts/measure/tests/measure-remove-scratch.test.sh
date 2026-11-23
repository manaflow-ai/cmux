#!/usr/bin/env bash
# measure_remove_scratch removes a bench's scratch folder that holds a build at a commit, whose Go module cache
# (.build/go-path/pkg/mod) Go writes read-only: a plain `rm -rf` in the EXIT trap failed on it and its status became the
# step's, so every cef-tab bench with --build-at ended exit 1 after it had printed and saved its results (2026-11-18).
set -euo pipefail
lib="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/app-at-commit.sh"
root="$(mktemp -d)"
trap 'chmod -R u+w "$root" 2>/dev/null; rm -rf "$root"' EXIT

# A step whose body succeeds: the trap removes the read-only cache and the step exits 0.
cat >"$root/step.sh" <<STEP
set -euo pipefail
. "$lib"
out="\$(mktemp -d "$root/scratch.XXXXXX")"
trap 'measure_remove_scratch "\$out"' EXIT
mkdir -p "\$out/at/.build/go-path/pkg/mod/golang.org/toolchain/src"
touch "\$out/at/.build/go-path/pkg/mod/golang.org/toolchain/src/reader.go"
chmod -R a-w "\$out/at/.build/go-path/pkg/mod"
echo "\$out" >"$root/out.path"
\${1:-true}
STEP
status=0; bash "$root/step.sh" true 2>"$root/err" || status=$?
[[ "$status" == 0 ]] || { echo "measure-remove-scratch: a step whose body passed exited $status: $(head -3 "$root/err")" >&2; exit 1; }
[[ ! -e "$(cat "$root/out.path")" ]] || { echo "measure-remove-scratch: the scratch folder is still there" >&2; exit 1; }

# A step whose body fails keeps its failure.
status=0; bash "$root/step.sh" false 2>/dev/null || status=$?
[[ "$status" != 0 ]] || { echo "measure-remove-scratch: a failing body exited 0" >&2; exit 1; }
[[ ! -e "$(cat "$root/out.path")" ]] || { echo "measure-remove-scratch: a failed step left its scratch folder" >&2; exit 1; }
echo "measure-remove-scratch: ok"
