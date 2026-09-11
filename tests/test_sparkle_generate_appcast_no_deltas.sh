#!/usr/bin/env bash
# Behavioral test for scripts/sparkle_generate_appcast.sh on the stable release
# path, where no previous archives exist and therefore no delta arguments.
#
# Release dry run 34227505375 (2026-09-08) uploaded a DMG with no appcast: the
# script expanded an empty array as "${delta_args[@]}", which is an "unbound
# variable" error under `set -u` in bash 3.2 (macOS /bin/bash), and the EXIT
# trap made bash 3.2 exit 0 anyway, so the workflow step passed. Nightly never
# hit it because it always has previous archives. Drive the script with fake
# git/xcodebuild/generate_appcast tools under every bash on this machine
# (macOS /bin/bash 3.2 reproduces the bug; bash 4.4+ never did) and require a
# signed appcast to land at the requested output path.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/sparkle_generate_appcast.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cmux-appcast-no-deltas.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT
FAKE_BIN="$TMP_DIR/bin"
mkdir -p "$FAKE_BIN"
fail() { echo "FAIL: $*" >&2; exit 1; }

# `git clone ... <dest>`: pretend the Sparkle checkout exists.
cat > "$FAKE_BIN/git" <<'GIT'
#!/usr/bin/env bash
set -euo pipefail
[ "${1:-}" = "clone" ] || { echo "fake git: unexpected $*" >&2; exit 1; }
mkdir -p "${@: -1}"
GIT

# `xcodebuild ... -scheme <tool> ... -derivedDataPath <dir> ... build`: drop a
# fake tool binary where the script expects the Release product.
cat > "$FAKE_BIN/xcodebuild" <<'XC'
#!/usr/bin/env bash
set -euo pipefail
scheme=""; derived=""
while [ $# -gt 0 ]; do
  case "$1" in
    -scheme) scheme="$2"; shift ;;
    -derivedDataPath) derived="$2"; shift ;;
  esac
  shift
done
[ -n "$scheme" ] && [ -n "$derived" ] || { echo "fake xcodebuild: missing -scheme/-derivedDataPath" >&2; exit 1; }
mkdir -p "$derived/Build/Products/Release"
cp "$CMUX_TEST_FAKE_TOOLS/$scheme" "$derived/Build/Products/Release/$scheme"
chmod +x "$derived/Build/Products/Release/$scheme"
XC

FAKE_TOOLS="$TMP_DIR/tools"
mkdir -p "$FAKE_TOOLS"
# generate_appcast: record argv (one per line, so an empty argument is visible),
# then write a signed feed for the DMG found in the archives dir (last argument).
cat > "$FAKE_TOOLS/generate_appcast" <<'GA'
#!/usr/bin/env bash
set -euo pipefail
: > "$CMUX_TEST_ARGV_LOG"
for arg in "$@"; do printf '%s\n' "$arg" >> "$CMUX_TEST_ARGV_LOG"; done
archives="${@: -1}"
dmg="$(find "$archives" -maxdepth 1 -name '*.dmg' | sort | tail -n 1)"
[ -n "$dmg" ] || { echo "fake generate_appcast: no dmg in $archives" >&2; exit 1; }
name="$(basename "$dmg")"
cat > "$archives/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <item>
      <sparkle:version>102</sparkle:version>
      <enclosure url="https://example.invalid/${name}" sparkle:version="102" sparkle:edSignature="fixture-signature" length="3" type="application/octet-stream"/>
    </item>
  </channel>
</rss>
XML
GA
cat > "$FAKE_TOOLS/sign_update" <<'SU'
#!/usr/bin/env bash
echo "fixture-signature"
SU
chmod +x "$FAKE_BIN"/* "$FAKE_TOOLS"/*

run_script() {
  local bash_bin="$1" out="$2"
  shift 2
  PATH="$FAKE_BIN:$PATH" \
  CMUX_TEST_FAKE_TOOLS="$FAKE_TOOLS" \
  CMUX_TEST_ARGV_LOG="$TMP_DIR/argv.log" \
  SPARKLE_PRIVATE_KEY="Zml4dHVyZS1rZXk" \
  "$@" \
  "$bash_bin" "$SCRIPT" "$TMP_DIR/cmux-macos.dmg" "v0.0.0-test" "$out"
}

printf 'dmg' > "$TMP_DIR/cmux-macos.dmg"

# Every bash on this machine: /bin/bash is 3.2 on macOS runners (the bug), and
# whichever bash `env` resolves is what the shebang would pick.
candidates=()
[ -x /bin/bash ] && candidates+=(/bin/bash)
resolved="$(command -v bash)"
if [ -n "$resolved" ] && [ "$resolved" != "/bin/bash" ]; then candidates+=("$resolved"); fi
[ "${#candidates[@]}" -gt 0 ] || fail "no bash found"

for bash_bin in "${candidates[@]}"; do
  version="$("$bash_bin" -c 'echo "${BASH_VERSION%%(*}"')"
  out_dir="$TMP_DIR/out-$(echo "$bash_bin" | tr '/' '_')"
  mkdir -p "$out_dir"

  # Stable release path: no previous archives, so no delta arguments.
  if ! run_script "$bash_bin" "$out_dir/appcast.xml" env -u SPARKLE_PREVIOUS_ARCHIVES_DIR >"$out_dir/run.log" 2>&1; then
    fail "bash $version: script failed on the no-previous-archives path: $(tail -n 5 "$out_dir/run.log")"
  fi
  [ -s "$out_dir/appcast.xml" ] || fail "bash $version: no appcast written to the requested output path"
  grep -q 'sparkle:edSignature' "$out_dir/appcast.xml" || fail "bash $version: appcast lacks sparkle:edSignature"
  grep -q 'cmux-macos.dmg' "$out_dir/appcast.xml" || fail "bash $version: appcast does not reference the DMG"
  grep -q "unbound variable" "$out_dir/run.log" && fail "bash $version: script still reports an unbound variable"
  grep -qx -- "--maximum-deltas" "$TMP_DIR/argv.log" && fail "bash $version: delta arguments passed although there were no previous archives"
  grep -qx "" "$TMP_DIR/argv.log" && fail "bash $version: generate_appcast received an empty argument"

  # Nightly path: previous archives present, delta arguments still flow through.
  mkdir -p "$TMP_DIR/previous"
  printf 'old' > "$TMP_DIR/previous/cmux-macos-101.dmg"
  if ! run_script "$bash_bin" "$out_dir/appcast-deltas.xml" env SPARKLE_PREVIOUS_ARCHIVES_DIR="$TMP_DIR/previous" SPARKLE_MAXIMUM_DELTAS=1 >"$out_dir/run-deltas.log" 2>&1; then
    fail "bash $version: script failed with previous archives: $(tail -n 5 "$out_dir/run-deltas.log")"
  fi
  [ -s "$out_dir/appcast-deltas.xml" ] || fail "bash $version: no appcast written on the delta path"
  paste -sd' ' "$TMP_DIR/argv.log" | grep -q -- "--maximum-deltas 1 " || fail "bash $version: --maximum-deltas 1 not passed with previous archives: $(paste -sd' ' "$TMP_DIR/argv.log")"
  echo "ok: bash $version generates a signed appcast with and without previous archives"
done

# release.yml must not trust the generator's exit status alone (bash 3.2 masks it).
RELEASE_WORKFLOW="$ROOT_DIR/.github/workflows/release.yml"
step="$(awk '/sparkle_generate_appcast.sh cmux-macos.dmg/{p=1} p{print} p&&/^      - name:/{exit}' "$RELEASE_WORKFLOW")"
grep -q 'test -s appcast.xml' <<<"$step" || fail "release.yml must verify appcast.xml exists after generation"
grep -q "grep -q 'sparkle:edSignature' appcast.xml" <<<"$step" || fail "release.yml must verify the appcast is signed after generation"

echo "PASS: sparkle_generate_appcast.sh produces a signed appcast on the no-delta release path under every local bash"
