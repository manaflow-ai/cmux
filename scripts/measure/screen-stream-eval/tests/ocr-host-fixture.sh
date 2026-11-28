#!/usr/bin/env bash
# Mac only. The host screenshot's own OCR against the text the scene drew, on a real 1x capture: 13 pt
# Menlo on a 1920x1080 1x display (rd-ladder host-1.png of the 11-26 c9339d12 run,
# grayscale, the strip under the last whole line white as scene.swift's ocr mask now draws it).
# The old engine settings read it at about 17 % CER; the fix must read it at <= 2 %.
#
#   scripts/measure/screen-stream-eval/tests/ocr-host-fixture.sh [BEFORE_SHA]
#
# With BEFORE_SHA, that commit's ocr.swift runs on the same fixture first, for the before number.
# Prints one JSON line per engine setting, then the verdict.
set -euo pipefail
root=$(git rev-parse --show-toplevel)
eval_dir="$root/scripts/measure/screen-stream-eval"
fixture="$eval_dir/tests/fixtures/host-13pt-1x"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
limit=0.02

swiftc -O -o "$work/ocr" "$eval_dir/ocr.swift"
swiftc -typecheck "$eval_dir/scene.swift"

host_cer() { python3 -I -c 'import json, sys; print(json.load(sys.stdin)["host_cer_vs_truth"])'; }

if [[ -n "${1:-}" ]]; then
  # shellcheck source=/dev/null
  source "$root/scripts/measure/fetch-commit.sh"
  measure_fetch_commit "$root" "$1"
  git -C "$root" show "$1:scripts/measure/screen-stream-eval/ocr.swift" >"$work/ocr-before.swift"
  swiftc -O -o "$work/ocr-before" "$work/ocr-before.swift"
  before=$("$work/ocr-before" "$fixture.png" "$fixture.png" "$fixture.txt")
  echo "before $1: $before"
fi

# The settings the fix chose (the defaults), and the neighbours it was chosen over.
for setting in "default::" "old-settings:1:-1" "scale=1:1:" "scale=2,vision-min:2:-1" "scale=3:3:"; do
  IFS=: read -r name scale min <<<"$setting"
  out=$(env ${scale:+SCREEN_EVAL_OCR_SCALE=$scale} ${min:+SCREEN_EVAL_OCR_MIN_TEXT_PX=$min} \
    SCREEN_EVAL_OCR_TEXT=1 "$work/ocr" "$fixture.png" "$fixture.png" "$fixture.txt")
  echo "$name: $(python3 -I -c 'import json, sys; o = json.load(sys.stdin); print(json.dumps({k: o[k] for k in ("host_cer_vs_truth", "host_chars", "truth_chars", "cer", "engine")}))' <<<"$out")"
  [[ "$name" != default ]] || default_out=$out
done
echo "default host text:"
python3 -I -c 'import json, sys; print(json.load(sys.stdin)["host_text"])' <<<"$default_out"

got=$(host_cer <<<"$default_out")
if python3 -I -c 'import sys; sys.exit(0 if float(sys.argv[1]) <= float(sys.argv[2]) else 1)' "$got" "$limit"; then
  echo "PASS: host OCR vs drawn 13 pt text $got <= $limit"
else
  echo "FAIL: host OCR vs drawn 13 pt text $got > $limit" >&2
  exit 1
fi
