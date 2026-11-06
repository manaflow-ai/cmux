#!/usr/bin/env bash
# scripts/measure/blaze-home.sh: the BLAZE_HOME rust-dev-loop.sh gives blaze keeps the daemon socket
# (BLAZE_HOME/v2.sock) inside a Unix socket address (104 bytes on macOS), also under a fleet Mac's long
# step home, and reaches the same directory. Builds nothing. Run: bash scripts/measure/tests/rust-dev-loop-blaze-home.test.sh
set -euo pipefail
lib="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/blaze-home.sh"
fail=0
check() { if ! eval "$1"; then echo "FAIL: $2"; fail=1; fi; }

# Under /tmp, not $TMPDIR: the short home below must stay short (macOS TMPDIR is /var/folders/...).
tmp="$(mktemp -d /tmp/blaze-home-test.XXXXXX)"
# A step home as long as the one of fleet step 2b240a0d42ed3a7abd387550 (a 156-byte socket path there).
long="$tmp/$(printf 'x%.0s' {1..80})/cmux-rust-dev-loop-blaze-home-$$"
short="$tmp/cmux-rust-dev-loop-blaze-home-$$-short"
mkdir -p "$long" "$short"
trap 'rm -f "/tmp/${long##*/}"; rm -rf "$tmp"' EXIT

# shellcheck source=../blaze-home.sh
source "$lib"
home="$(blaze_home_path "$long")"
socket="$home/v2.sock"
check '(( ${#socket} < 104 ))' "the socket path fits macOS's 104 bytes (${#socket}: $socket)"
check '[[ "${home##*/}" == "${long##*/}" ]]' "the home keeps its cmux-rust-dev-loop-blaze-home-* name ($home)"
check '[[ "$(cd "$home" && pwd -P)" == "$(cd "$long" && pwd -P)" ]]' "the home reaches the run's own directory"
check '[[ "$(blaze_home_path "$long")" == "$home" ]]' "a second call gives the same home"
check '[[ "$(blaze_home_path "$short")" == "$short" ]]' "a home whose socket fits is used as it is"
blaze_home_unlink "$long"
check '[[ ! -e "/tmp/${long##*/}" ]]' "the link is removed"
check '[[ -d "$long" ]]' "removing the link keeps the home"

[ "$fail" = 0 ] && echo "rust-dev-loop-blaze-home.test.sh: all checks passed"
exit "$fail"
