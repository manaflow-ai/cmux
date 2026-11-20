#!/usr/bin/env bash
# base-autofix-repair.sh runs cargo clippy --fix (autofix-clippy.sh) on the changed paths before
# base-autofix.sh when CLIPPY=true, passes over it otherwise, and a failing fixer never stops the
# other repairs. Stubs stand in for both scripts (no cargo build).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repair="$here/../base-autofix-repair.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/repo" "$work/bin"
printf '#!/usr/bin/env bash\necho "clippy-stub $1 $(tr "\\n" " ")"\n' >"$work/clippy-ok"
printf '#!/usr/bin/env bash\ncat >/dev/null; exit 1\n' >"$work/clippy-fails"
printf '#!/usr/bin/env bash\necho "autofix-stub ${*: -1}"\n' >"$work/autofix"
printf '#!/usr/bin/env bash\nexit 0\n' >"$work/bin/cargo"
chmod +x "$work/clippy-ok" "$work/clippy-fails" "$work/autofix" "$work/bin/cargo"
printf 'cmux-tui/crates/a/src/lib.rs\n' >"$work/changed.txt"
fail=0
check() { # name, expected regex, output
  if grep -Eq "$2" <<<"$3"; then echo "ok: $1"; else echo "FAIL: $1"; printf '%s\n' "$3"; fail=1; fi
}
run() { PATH="$work/bin:$PATH" CMUX_BASE_AUTOFIX_SCRIPT="$work/autofix" "$@" "$repair" "$work/repo"; }

out="$(run env CLIPPY=true CLIPPY_CHANGED="$work/changed.txt" CMUX_BASE_AUTOFIX_CLIPPY="$work/clippy-ok")"
check "clippy runs first, on the changed paths" "$(printf 'clippy-stub %s/repo cmux-tui/crates/a/src/lib.rs' "$work")" "$(head -1 <<<"$out")"
check "the other repairs still run" "^autofix-stub " "$(tail -1 <<<"$out")"

out="$(run env CLIPPY=false CLIPPY_CHANGED="$work/changed.txt" CMUX_BASE_AUTOFIX_CLIPPY="$work/clippy-ok")"
check "CLIPPY=false skips it" "^autofix-stub [^ ]+$" "$out"
[[ "$out" != *clippy-stub* ]] || { echo "FAIL: clippy ran with CLIPPY=false"; fail=1; }

out="$(run env CLIPPY=true CLIPPY_CHANGED="$work/missing.txt" CMUX_BASE_AUTOFIX_CLIPPY="$work/clippy-ok")"
[[ "$out" != *clippy-stub* ]] || { echo "FAIL: clippy ran with no changed list"; fail=1; }

out="$(run env CLIPPY=true CLIPPY_CHANGED="$work/changed.txt" CMUX_BASE_AUTOFIX_CLIPPY="$work/clippy-fails")"
check "a failing fixer is reported" "^left: cargo clippy --fix did not run" "$out"
check "and the other repairs still run" "^autofix-stub " "$(tail -1 <<<"$out")"
exit "$fail"
