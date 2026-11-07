#!/usr/bin/env bash
# Live code, measured end to end in the view shell (Prototypes/ViewShell/README.md, "Live code"):
# builds the Debug shell, runs it headless with a live folder, edits Badge.swift (a padding and a
# colour, which also changes the badge's view type), compiles and drops the patch, and times the
# edit to the redrawn badge's pixels. Then a new file the badge uses (named nowhere: inject.sh takes
# it along), and a stored property edit, which must not apply live. A redraw is judged by the badge's
# rendered width (each edit widens it), not by the PNG's bytes, which differ for the same pixels.
#   scripts/measure/live-code-shell.sh OUT     (OUT: a folder for the log, the PNGs and result.json)
set -euo pipefail
out="${1:?usage: live-code-shell.sh OUT}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
package="$root/Prototypes/ViewShell"
mkdir -p "$out"
probe="$package/Sources/ViewShell/LiveCodeProbeDot.swift"
if [[ -e "$probe" || -L "$probe" ]]; then  # -L: a dangling link too, which `cat >` would follow
  echo "live-code-shell: $probe already exists; this measurement writes and deletes that file" >&2
  exit 1
fi
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
  # Only this run's backup: an OUT reused from an earlier run may hold an older Badge.swift.
  [[ -n "$backed_up" ]] && cp "$out/Badge.swift.orig" "$package/Sources/ViewShell/Badge.swift"
  [[ -n "$probe_written" ]] && rm -f "$probe"
  rm -rf "$live"
}
probe_written=""
backed_up=""
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
# The badge's rendered width in generation N, in pixels (empty when it was not drawn).
width_of() { grep "rendered .*generation-$1\.png" "$out/shell.log" | sed -n 's/.*width=\([0-9]*\).*/\1/p' | tail -1; }
# "yes" when generation $2 was drawn wider or narrower than generation $1, else why not.
width_changed() {
  local before after
  before="$(width_of "$1")"; after="$(width_of "$2")"
  if [[ -z "$before" ]]; then echo "unknown: no rendered width for generation $1"
  elif [[ -z "$after" ]]; then echo "unknown: no rendered width for generation $2"
  elif [[ "$before" != "$after" ]]; then echo "yes"
  else echo "no: generation $2 is as wide as generation $1 ($after px)"; fi
}
wait_for "redrawn generation=0" 30
cp "$package/Sources/ViewShell/Badge.swift" "$out/Badge.swift.orig"
backed_up=1

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
repatched="$(width_changed 1 2)"

# 3. A new file with a new view, used by the badge. Only Badge.swift is named; the build never
# compiled the new file, so inject.sh links it into the patch too.
edit3=$(now)
probe_written=1
cat >"$probe" <<'SWIFT'
import SwiftUI

// Written by scripts/measure/live-code-shell.sh and removed when it ends: a new file in a patch.
struct LiveCodeProbeDot: View {
    var body: some View { Circle().fill(.green).frame(width: 6, height: 6) }
}
SWIFT
sed -i '' -e 's/^        Text(text)$/        HStack(spacing: 4) { LiveCodeProbeDot(); Text(text) }/' "$package/Sources/ViewShell/Badge.swift"
refusals=$(grep -c "refused" "$out/shell.log" || true)
newfile="not applied"
drawn3=""
if ! "$package/inject.sh" --live "$live" "$package/Sources/ViewShell/Badge.swift" | tee "$out/inject-3.log"; then
  newfile="inject.sh failed (see inject-3.log)"
else
  # Either the redraw or the refusal, whichever comes first.
  for _ in $(seq 1 300); do
    grep -q "redrawn generation=3" "$out/shell.log" && break
    (( $(grep -c "refused" "$out/shell.log" || true) > refusals )) && { newfile="refused"; break; }
    kill -0 "$shell" 2>/dev/null || { newfile="shell exited"; break; }
    sleep 0.1
  done
  if grep -q "redrawn generation=3" "$out/shell.log"; then
    drawn3=$(grep "redrawn generation=3" "$out/shell.log" | sed 's/.*at=//')
    newfile="$(width_changed 2 3)"
    [[ "$newfile" == yes ]] && newfile="applied"
  fi
fi

# 4. A new stored property (a SwiftUI `@State`, whose layout the runtime fills in): refused.
# The generation it would draw is the next one (a refused patch draws none).
next=$(( $(grep -o "redrawn generation=[0-9]*" "$out/shell.log" | tail -1 | sed 's/.*=//') + 1 ))
refusals=$(grep -c "refused" "$out/shell.log" || true)
sed -i '' -e 's/    let text: String/    let text: String\n    @State private var extra = 0/' "$package/Sources/ViewShell/Badge.swift"
stored="not applied"
if ! "$package/inject.sh" --live "$live" "$package/Sources/ViewShell/Badge.swift" | tee "$out/inject-4.log"; then
  stored="inject.sh failed (see inject-4.log)"
else
  sleep 3
  grep -q "redrawn generation=$next" "$out/shell.log" && stored="applied (unsafe: layout changed)"
  (( $(grep -c "refused" "$out/shell.log" || true) > refusals )) && stored="refused"
  kill -0 "$shell" 2>/dev/null || stored="shell exited"
fi
cp "$out/Badge.swift.orig" "$package/Sources/ViewShell/Badge.swift"

python3 - "$out" "$build_start" "$build_end" "$edit" "$compiled" "$drawn" "$edit2" "$drawn2" "$repatched" "$edit3" "$drawn3" "$newfile" "$stored" "$(width_of 0),$(width_of 1),$(width_of 2),$(width_of 3)" <<'PY'
import json, sys
out, b0, b1, edit, compiled, drawn, edit2, drawn2, repatched, edit3, drawn3, newfile, stored, widths = sys.argv[1:]
r = {
  "debug_build_s": round(float(b1) - float(b0), 2),
  "edit_to_compiled_s": round(float(compiled) - float(edit), 2),
  "edit_to_pixels_s": round(float(drawn) - float(edit), 2),
  "warm_edit_to_pixels_s": round(float(drawn2) - float(edit2), 2),
  "second_patch_redrew": repatched,
  "new_file_edit": newfile,
  "new_file_edit_to_pixels_s": round(float(drawn3) - float(edit3), 2) if drawn3 else None,
  "stored_property_edit": stored,
  "badge_widths_px": [int(w) if w else None for w in widths.split(",")],  # null: not drawn
}
json.dump(r, open(f"{out}/result.json", "w"), indent=2)
print(json.dumps(r))
PY
grep "live code" "$out/shell.log"
