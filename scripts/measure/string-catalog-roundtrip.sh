#!/usr/bin/env bash
# Mac proof that a string table kept as one file per key (<Table>.xcstrings.d/, scripts/cmux-next/string_catalogs.py)
# builds and round-trips: SwiftPM and Xcode compile the table StringCatalogsPlugin writes, with the same strings in
# every language as the directory holds, and a build (Xcode's string extraction on) writes nothing back into the
# sources.
#
#   cmux-ci run --class exclusive --script scripts/measure/string-catalog-roundtrip.sh --ref SHA --timeout 5400
# Args: targets=<comma list> (default CmuxNextSettingsWindow,CmuxNextSettings), xcode=0 to skip the xcodebuild leg.
# Output: RESULT lines; exit 0 when every check holds. Never changes anything outside this checkout's .build.
set -euo pipefail
repo="$(git rev-parse --show-toplevel)"
cd "$repo"
targets="CmuxNextSettingsWindow,CmuxNextSettings"
xcode=1
for arg in "$@"; do
  case "$arg" in
    targets=*) targets="${arg#targets=}" ;;
    xcode=*) xcode="${arg#xcode=}" ;;
    *) echo "unknown arg $arg" >&2; exit 2 ;;
  esac
done
work="$repo/.build/string-catalog-roundtrip"
rm -rf "$work"
mkdir -p "$work"
fail=0
result() { echo "RESULT $*"; }

# strings_of DIR: every <lang>.lproj/Localizable.strings(dict) under DIR as one JSON object, for comparison.
strings_of() {
  python3 - "$1" <<'PY'
import json, plistlib, sys
from pathlib import Path
out = {}
for p in sorted(Path(sys.argv[1]).rglob("*.lproj/Localizable.strings*")):
    with open(p, "rb") as handle:
        out[p.parent.name + "/" + p.name] = plistlib.load(handle)
print(json.dumps(out, sort_keys=True, ensure_ascii=False))
PY
}

before="$(git status --porcelain -- Packages/macOS/CmuxNext/Sources | sort)"
pkg="$repo/Packages/macOS/CmuxNext"
IFS=, read -r -a names <<<"$targets"
for name in "${names[@]}"; do
  dir="$pkg/Sources/$name/Localizable.xcstrings.d"
  keys="$(find "$dir" -name '*.xcstrings' | wc -l | tr -d ' ')"
  mkdir -p "$work/$name/expected"
  python3 scripts/cmux-next/string_catalogs.py cat "$dir" >"$work/$name/Localizable.xcstrings"
  xcrun xcstringstool compile "$work/$name/Localizable.xcstrings" --output-directory "$work/$name/expected"
  strings_of "$work/$name/expected" >"$work/$name/expected.json"
  result "$name keys=$keys expected_tables=$(find "$work/$name/expected" -name 'Localizable.strings*' | wc -l | tr -d ' ')"
done

# SwiftPM: the plugin's table lands in the module bundle; compile-string-catalogs.sh compiles it as `swift test` does.
(
  cd "$pkg"
  args=()
  for name in "${names[@]}"; do args+=(--target "$name"); done
  start=$SECONDS
  swift build ${args[@]+"${args[@]}"} 2>&1 | tail -20
  echo "swift build took $((SECONDS - start)) s"
  bin="$(swift build --show-bin-path)"
  CMUX_SWIFT_BIN_PATH="$bin" "$repo/scripts/cmux-next/compile-string-catalogs.sh"
  echo "$bin" >"$work/swiftpm-bin"
)
bin="$(cat "$work/swiftpm-bin")"
for name in "${names[@]}"; do
  bundle="$bin/CmuxNext_$name.bundle"
  if [ ! -d "$bundle" ]; then result "$name swiftpm=FAIL no bundle $bundle"; fail=1; continue; fi
  strings_of "$bundle" >"$work/$name/swiftpm.json"
  if cmp -s "$work/$name/expected.json" "$work/$name/swiftpm.json"; then
    result "$name swiftpm=ok tables=$(find "$bundle" -name 'Localizable.strings*' | wc -l | tr -d ' ')"
  else
    result "$name swiftpm=FAIL compiled strings differ ($(ls "$bundle" | tr '\n' ' '))"; fail=1
  fi
done

if [ "$xcode" = 1 ]; then
  dd="$work/DerivedData"
  (cd "$pkg" && xcodebuild -list 2>/dev/null | sed -n '/Schemes:/,$p' | head -40) || true
  for name in "${names[@]}"; do
    start=$SECONDS
    if (cd "$pkg" && xcodebuild -skipPackagePluginValidation -skipMacroValidation -scheme "$name" \
          -destination 'generic/platform=macOS' -derivedDataPath "$dd" -configuration Debug \
          SWIFT_EMIT_LOC_STRINGS=YES LOCALIZATION_PREFERS_STRING_CATALOGS=YES CODE_SIGNING_ALLOWED=NO build \
          >"$work/$name/xcodebuild.log" 2>&1); then
      bundle="$(find "$dd/Build/Products" -type d -name "CmuxNext_$name.bundle" | head -1)"
      strings_of "$bundle" >"$work/$name/xcode.json"
      if cmp -s "$work/$name/expected.json" "$work/$name/xcode.json"; then
        result "$name xcode=ok $((SECONDS - start)) s tables=$(find "$bundle" -name 'Localizable.strings*' | wc -l | tr -d ' ')"
      else
        result "$name xcode=FAIL compiled strings differ: $(ls -R "$bundle" | head -30 | tr '\n' ' ')"; fail=1
      fi
      # The table Xcode compiled is the plugin's; splitting it back into the directory changes no file.
      table="$(find "$dd" -path '*StringCatalogsPlugin*' -path "*$name*" -name 'Localizable.xcstrings' | head -1)"
      if [ -n "$table" ]; then
        cp -R "$pkg/Sources/$name/Localizable.xcstrings.d" "$work/$name/roundtrip.d"
        result "$name roundtrip=$(python3 scripts/cmux-next/string_catalogs.py split "$table" --into "$work/$name/roundtrip.d" --prune)"
      else
        result "$name roundtrip=FAIL no plugin table under $dd"; fail=1
      fi
    else
      result "$name xcode=FAIL build failed"; grep -E 'error:|warning: .*xcstrings' "$work/$name/xcodebuild.log" | head -20; fail=1
    fi
  done
fi

after="$(git status --porcelain -- Packages/macOS/CmuxNext/Sources | sort)"
if [ "$before" = "$after" ]; then result "sources unchanged by the builds"; else
  result "FAIL the builds changed the sources:"; diff <(echo "$before") <(echo "$after") || true; fail=1
fi
exit "$fail"
