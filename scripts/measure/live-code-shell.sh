#!/usr/bin/env bash
# Live code, measured end to end in the view shell (Prototypes/ViewShell/README.md, "Live code"):
# builds the Debug shell, runs it headless with a live folder, edits Badge.swift (a padding and a
# colour, which also changes the badge's view type), compiles and drops the patch, and times the
# edit to the redrawn badge's pixels. Then a stored property edit, which must not apply live.
#   scripts/measure/live-code-shell.sh OUT     (OUT: a folder for the log, the PNGs and result.json)
set -euo pipefail
out="${1:?usage: live-code-shell.sh OUT}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
package="$root/Prototypes/ViewShell"
mkdir -p "$out"
now() { python3 -c 'import time; print(f"{time.time():.3f}")'; }

build_start=$(now)
swift build --package-path "$package" --product cmux-view-shell 2>&1 | tail -3
build_end=$(now)
bin="$(swift build --package-path "$package" --show-bin-path)/cmux-view-shell"

live="$(mktemp -d "${TMPDIR:-/tmp}/live-code.XXXXXX")"
"$bin" --headless --live "$live" --live-render "$out" >"$out/shell.log" 2>&1 &
shell=$!
restore() {
  kill "$shell" 2>/dev/null || true
  [[ -f "$out/Badge.swift.orig" ]] && cp "$out/Badge.swift.orig" "$package/Sources/ViewShell/Badge.swift"
  rm -rf "$live"
}
trap restore EXIT
wait_for() { # PATTERN SECONDS
  for _ in $(seq 1 $(( $2 * 10 ))); do grep -q "$1" "$out/shell.log" && return 0; sleep 0.1; done
  echo "timed out waiting for: $1" >&2; cat "$out/shell.log" >&2
  if kill -0 "$shell" 2>/dev/null; then
    echo "the shell is still running; its main thread:" >&2
    sample "$shell" 1 -mayDie 2>/dev/null | sed -n '/Call graph/,/Total number/p' | head -60 >&2 || true
  else
    local code=0; wait "$shell" || code=$?; echo "the shell exited with $code" >&2
    report="$(ls -t ~/Library/Logs/DiagnosticReports/cmux-view-shell* 2>/dev/null | head -1)"
    [[ -n "$report" ]] && head -c 6000 "$report" >&2
  fi
  return 1
}
wait_for "redrawn generation=0" 30
cp "$package/Sources/ViewShell/Badge.swift" "$out/Badge.swift.orig"

# 1. A value and type change inside the view: applies live.
edit=$(now)
sed -i '' -e 's/\.padding(\.horizontal, 8)/.padding(.horizontal, 24)/' -e 's/\.foregroundStyle(\.secondary)/.foregroundStyle(.red)/' \
  "$package/Sources/ViewShell/Badge.swift"
"$package/inject.sh" --live "$live" "$package/Sources/ViewShell/Badge.swift" | tee "$out/inject-1.log"
compiled=$(now)
wait_for "redrawn generation=1" 30
drawn=$(grep "redrawn generation=1" "$out/shell.log" | sed 's/.*at=//')

# 2. The same file again, warm: the second patch must replace the first one's code.
edit2=$(now)
sed -i '' -e 's/\.padding(\.horizontal, 24)/.padding(.horizontal, 40)/' "$package/Sources/ViewShell/Badge.swift"
"$package/inject.sh" --live "$live" "$package/Sources/ViewShell/Badge.swift" | tee "$out/inject-2.log"
wait_for "redrawn generation=2" 30
drawn2=$(grep "redrawn generation=2" "$out/shell.log" | sed 's/.*at=//')
repatched="no: generation 2 drew the same picture as generation 1"
cmp -s "$out/generation-1.png" "$out/generation-2.png" || repatched="yes"

# 3. A new stored property: a layout change the running code cannot take.
sed -i '' -e 's/    let text: String/    let text: String\n    var extra = 0/' "$package/Sources/ViewShell/Badge.swift"
"$package/inject.sh" --live "$live" "$package/Sources/ViewShell/Badge.swift" | tee "$out/inject-3.log" || true
sleep 3
stored="not applied"
grep -q "redrawn generation=3" "$out/shell.log" && stored="applied (unsafe: layout changed)"
grep -q "refused" "$out/shell.log" && stored="refused"
kill -0 "$shell" 2>/dev/null || stored="shell exited"
cp "$out/Badge.swift.orig" "$package/Sources/ViewShell/Badge.swift"

python3 - "$out" "$build_start" "$build_end" "$edit" "$compiled" "$drawn" "$edit2" "$drawn2" "$repatched" "$stored" <<'PY'
import json, sys
out, b0, b1, edit, compiled, drawn, edit2, drawn2, repatched, stored = sys.argv[1:]
r = {
  "debug_build_s": round(float(b1) - float(b0), 2),
  "edit_to_compiled_s": round(float(compiled) - float(edit), 2),
  "edit_to_pixels_s": round(float(drawn) - float(edit), 2),
  "warm_edit_to_pixels_s": round(float(drawn2) - float(edit2), 2),
  "second_patch_redrew": repatched,
  "stored_property_edit": stored,
}
json.dump(r, open(f"{out}/result.json", "w"), indent=2)
print(json.dumps(r))
PY
grep "live code" "$out/shell.log"
