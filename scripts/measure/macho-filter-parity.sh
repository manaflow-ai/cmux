#!/usr/bin/env bash
# Run the thin-app-bundle behavior tests, then compare the fat-file list of the
# old per-file `file` scan with the list-macho-candidates.py path on a real
# bundle (Xcode's), with timings. Fails on any difference.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
bash tests/test_thin_app_bundle.sh
bash tests/test_cmux_tui_ssh_payload_bundle.sh
python3 tests/test_list_macho_candidates.py
app="$(xcode-select -p)/../Applications/Instruments.app"
[ -d "$app" ] || app=/Applications/Safari.app
echo "bundle: $app"
t=$SECONDS
old="$(find "$app" -type f -exec sh -c 'file -b "$1" | grep -q "Mach-O universal" && echo "$1"' _ {} \; | sort)"
old_s=$((SECONDS - t))
t=$SECONDS
new="$(find "$app" -type f -print0 | python3 scripts/list-macho-candidates.py \
  | xargs -0 sh -c 'for f do if file -b "$f" | grep -q "Mach-O universal"; then echo "$f"; fi; done' sh | sort)"
new_s=$((SECONDS - t))
t=$SECONDS
all_macho_old="$(find "$app" -type f -exec sh -c 'file -b "$1" | grep -q "Mach-O" && echo "$1"' _ {} \; | sort)"
all_macho_new="$(find "$app" -type f -print0 | python3 scripts/list-macho-candidates.py | tr '\0' '\n' | sort)"
echo "files: $(find "$app" -type f | wc -l | tr -d ' '); Mach-O by file: $(printf '%s\n' "$all_macho_old" | grep -c . || true); candidates: $(printf '%s\n' "$all_macho_new" | grep -c . || true)"
echo "fat scan: old ${old_s} s, new ${new_s} s; fat files: $(printf '%s\n' "$old" | grep -c . || true)"
[ "$old" = "$new" ] || { echo "fat lists differ" >&2; diff <(echo "$old") <(echo "$new") >&2 || true; exit 1; }
missing="$(comm -23 <(echo "$all_macho_old") <(echo "$all_macho_new"))"
[ -z "$missing" ] || { echo "Mach-O files the filter dropped:" >&2; echo "$missing" >&2; exit 1; }
echo MACHO-FILTER-PARITY-OK
