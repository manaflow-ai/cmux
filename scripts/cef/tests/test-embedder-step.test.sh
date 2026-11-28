#!/usr/bin/env bash
# scripts/cef/test-embedder-step.sh (the cmux-ci cef-embedder step): input
# checks, the fork-ref check against the archive's REF file, the summary line,
# and the survivor rule (a process the tests leave running from the step's
# work dir is ended and fails the step). Runs on Linux and macOS with local
# inputs (CMUX_EMBEDDER_INPUT_DIR) and a fake test runner; the real step reads
# the controller store and runs the fork's test-cmux-embedder.sh.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
step="$here/../test-embedder-step.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/embedder-step-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
sha() { shasum -a 256 "$1" | cut -c1-64; }
REF=0f475c2303b7f8f0006d7a2f513b11649bd0b127

# A CEF package: the folder test-cmux-embedder.sh expects, as a tar.xz.
mkdir -p "$work/pkg/cef-x/Chromium Embedded Framework.framework" "$work/pkg/cef-x/include" "$work/pkg/cef-x/libcef_dll"
tar -C "$work/pkg" -cJf "$work/pkg.tar.xz" cef-x
# The test sources: what the operator's git archive holds, with the fake runner.
mk_sources() { # mk_sources <ref> <runner body> -> prints sha
  rm -rf "$work/s" && mkdir -p "$work/s/src/scripts" "$work/s/src/tests/cmux_embedder"
  printf '%s\n' "$1" >"$work/s/src/REF"
  printf '#!/usr/bin/env bash\n%s\n' "$2" >"$work/s/src/scripts/test-cmux-embedder.sh"
  tar -C "$work/s" -czf "$work/src.tar.gz" src
  sha "$work/src.tar.gz"
}
inputs() { # put both archives under their sha256 in the local input dir
  rm -rf "$work/in" && mkdir -p "$work/in"
  cp "$work/pkg.tar.xz" "$work/in/$(sha "$work/pkg.tar.xz")"
  cp "$work/src.tar.gz" "$work/in/$(sha "$work/src.tar.gz")"
}
run() { CMUX_EMBEDDER_INPUT_DIR="$work/in" CMUX_EMBEDDER_WORK="$work/w" CMUX_EMBEDDER_WINDOWS=skip \
  bash "$step" "$@" >"$work/out" 2>&1; }
PKG="sha256:$(sha "$work/pkg.tar.xz")"

pass_body='for c in signals duplicate; do echo "==> case $c"; echo "    PASS ($c, exit 0, 1s)"; done'
SRC="sha256:$(mk_sources "$REF" "$pass_body")"; inputs
run "$PKG" "$SRC" "$REF" signals duplicate || { cat "$work/out"; fail "a passing run failed"; }
grep -qx 'cmux-embedder: 2/2 passed' "$work/out" || { cat "$work/out"; fail "no 2/2 summary"; }

# Bad inputs are refused before anything runs.
for args in "sha256:abc $SRC $REF" "$PKG sha256:abc $REF" "$PKG $SRC deadbeef" "v1 $SRC $REF" "$PKG $SRC $REF rm-rf"; do
  # shellcheck disable=SC2086
  if run $args; then fail "accepted: $args"; fi
done

# An archive whose REF is another commit is refused.
SRC2="sha256:$(mk_sources 1111111111111111111111111111111111111111 "$pass_body")"; inputs
if run "$PKG" "$SRC2" "$REF"; then fail "a REF mismatch was accepted"; fi
grep -q 'REF' "$work/out" || fail "REF mismatch not named"

# A content mismatch (the file under a sha256 is other bytes) is refused.
SRC="sha256:$(mk_sources "$REF" "$pass_body")"; inputs
cp "$work/pkg.tar.xz" "$work/in/${SRC#sha256:}"
if run "$PKG" "$SRC" "$REF"; then fail "a sha256 mismatch was accepted"; fi

# A failing case fails the step with the summary.
SRC="sha256:$(mk_sources "$REF" 'echo "==> case signals"; echo "    PASS (signals, exit 0, 1s)"; echo "==> case duplicate"; echo "    FAIL (duplicate, exit 1, 1s)"; exit 1')"; inputs
if run "$PKG" "$SRC" "$REF" signals duplicate; then fail "a failing case passed the step"; fi
grep -qx 'cmux-embedder: 1/2 passed' "$work/out" || { cat "$work/out"; fail "no 1/2 summary"; }

# A process the tests leave running from the work dir fails the step and is ended.
leak_body='cp "$(command -v sleep)" "$CMUX_EMBEDDER_TEST_DIR/leaky"; [ "$(uname)" != Darwin ] || codesign --force -s - "$CMUX_EMBEDDER_TEST_DIR/leaky" 2>/dev/null; nohup "$CMUX_EMBEDDER_TEST_DIR/leaky" 300 >/dev/null 2>&1 & echo "==> case signals"; echo "    PASS (signals, exit 0, 1s)"'
SRC="sha256:$(mk_sources "$REF" "$leak_body")"; inputs
if run "$PKG" "$SRC" "$REF" signals; then cat "$work/out"; fail "a leaked process passed the step"; fi
grep -q 'outlived the tests' "$work/out" || { cat "$work/out"; fail "the survivor was not named"; }
left="$(pgrep -f "$work/w/run/leaky" || true)"
if [ -n "$left" ]; then kill $left 2>/dev/null || true; fail "the survivor was not ended"; fi
echo "test-embedder-step: ok"
