#!/usr/bin/env bash
# Regression test: on feat-cmux-next, `reload.sh --release` (the one configuration flag the fleet's
# `cmux-ci build cmux --release` passes) of a chrome-parity-* dogfood tag built plain Release, so the
# dogfood gate, the smoke and the video journeys failed at their first debug.* call (method_not_found).
# A tag that scripts/cmux-next/cmux-next.dogfood.conf names (release_bench_tags) now builds --config bench.
# This checks the tag match that reload.sh uses (scripts/cmux-next/lib/dogfood-bench-tags.sh).
# Runs anywhere (Linux included); it builds nothing.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/scripts/cmux-next/lib/dogfood-bench-tags.sh"
CONF="$ROOT_DIR/scripts/cmux-next/cmux-next.dogfood.conf"
fail() { echo "FAIL: $*" >&2; exit 1; }

[[ -f "$LIB" ]] || fail "no $LIB: reload.sh --release cannot tell a dogfood tag"
[[ -f "$CONF" ]] || fail "no $CONF: no tag builds the bench configuration on --release"
# shellcheck source=scripts/cmux-next/lib/dogfood-bench-tags.sh
source "$LIB"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# The checked-in conf: chrome-parity-* dogfood tags build bench; every other tag stays plain Release.
glob="$(dogfood_bench_glob chrome-parity-benchconf-0123456789ab-v1)" || fail "a chrome-parity-* tag does not build bench"
[[ "$glob" == 'chrome-parity-*' ]] || fail "a chrome-parity-* tag matched '$glob', not 'chrome-parity-*'"
# pr-capture's capture build (cap<sha10>, exactly ten lowercase hex digits) builds bench too.
glob="$(dogfood_bench_glob cap0123456789)" || fail "a cap<sha10> capture tag does not build bench"
[[ "$glob" == cap\[0-9a-f\]* ]] || fail "a cap<sha10> tag matched '$glob'"
for tag in nightly cmux-next-nightly release my-chrome-parity-x chrome-parity "" cap capture cap012345678 cap0123456789a capABCDEF0123 xcap0123456789 ; do
  if dogfood_bench_glob "$tag" >/dev/null; then fail "tag '$tag' builds bench"; fi
done
echo "PASS: the checked-in conf names chrome-parity-* and cap<sha10>, and no other tag"

# The value's globs match the tag, never files in the current directory.
mkdir -p "$TMP_DIR/cwd" && touch "$TMP_DIR/cwd/chrome-parity-file"
glob="$(cd "$TMP_DIR/cwd" && dogfood_bench_glob chrome-parity-x-v1)" || fail "a file in the current directory hid the glob"
[[ "$glob" == 'chrome-parity-*' ]] || fail "the glob expanded against the current directory: '$glob'"
echo "PASS: the globs are not expanded against files"

# Several globs, the last value line, comments, an empty value and no conf.
printf '%s\n' '# release_bench_tags=*' 'release_bench_tags=old-*' 'release_bench_tags=a-*  b-?' > "$TMP_DIR/two.conf"
[[ "$(dogfood_bench_glob b-1 "$TMP_DIR/two.conf")" == 'b-?' ]] || fail "the second glob of the value did not match"
if dogfood_bench_glob old-1 "$TMP_DIR/two.conf" >/dev/null; then fail "an earlier value line still counts"; fi
if dogfood_bench_glob anything "$TMP_DIR/two.conf" >/dev/null; then fail "a commented-out value counts"; fi
printf '%s\n' 'release_bench_tags=' > "$TMP_DIR/empty.conf"
if dogfood_bench_glob chrome-parity-x "$TMP_DIR/empty.conf" >/dev/null; then fail "an empty value builds bench"; fi
if dogfood_bench_glob chrome-parity-x "$TMP_DIR/missing.conf" >/dev/null; then fail "a missing conf builds bench"; fi
echo "PASS: several globs, the last value line, comments, an empty value and a missing conf"
