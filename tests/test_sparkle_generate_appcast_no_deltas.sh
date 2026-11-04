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
# signed appcast to land at the requested output path. The source-build path
# (unpinned Sparkle versions) is covered through fake git/xcodebuild; the
# pinned release download/checksum/extraction path through fake tools.
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
# CMUX_TEST_GENERATE_UNSIGNED=1 emulates the real tool when the private key's
# public key differs from the app's SUPublicEDKey: it writes the feed but no
# sparkle:edSignature. CMUX_TEST_ENCLOSURE_LENGTH overrides the length it writes.
cat > "$FAKE_TOOLS/generate_appcast" <<'GA'
#!/usr/bin/env bash
set -euo pipefail
: > "$CMUX_TEST_ARGV_LOG"
for arg in "$@"; do printf '%s\n' "$arg" >> "$CMUX_TEST_ARGV_LOG"; done
archives="${@: -1}"
dmg="$(find "$archives" -maxdepth 1 -name '*.dmg' | sort | tail -n 1)"
[ -n "$dmg" ] || { echo "fake generate_appcast: no dmg in $archives" >&2; exit 1; }
name="$(basename "$dmg")"
length="${CMUX_TEST_ENCLOSURE_LENGTH:-$(wc -c < "$dmg" | tr -d ' ')}"
signature='sparkle:edSignature="fixture-signature" '
[ "${CMUX_TEST_GENERATE_UNSIGNED:-}" = 1 ] && signature=""
cat > "$archives/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <item>
      <sparkle:version>102</sparkle:version>
      <enclosure url="https://example.invalid/${name}" sparkle:version="102" ${signature}length="${length}" type="application/octet-stream"/>
    </item>
  </channel>
</rss>
XML
GA
# sign_update: `-p --ed-key-file KEY FILE` prints the signature; `--verify
# --ed-key-file KEY FILE SIGNATURE` checks it (CMUX_TEST_VERIFY_FAIL=1 fails).
cat > "$FAKE_TOOLS/sign_update" <<'SU'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${CMUX_TEST_SIGN_LOG:-/dev/null}"
if [ "${1:-}" = --verify ]; then
  [ "${CMUX_TEST_VERIFY_FAIL:-}" = 1 ] && { echo "fake sign_update: signature does not verify" >&2; exit 1; }
  [ "${@: -1}" = fallback-signature ] || { echo "fake sign_update: unexpected signature ${@: -1}" >&2; exit 1; }
  exit 0
fi
echo "fallback-signature"
SU
# BinaryDelta: the fixture DMGs never mount, so delta prebuilding must fall
# back to generate_appcast without calling it.
cat > "$FAKE_TOOLS/BinaryDelta" <<'BD'
#!/usr/bin/env bash
touch "$CMUX_TEST_BINARY_DELTA_MARKER"
echo "fake BinaryDelta must not run for fixture archives" >&2
exit 1
BD
# hdiutil: the fixture DMGs are plain files, so `attach -mountpoint DIR`
# lays out the app the DMG would hold, with CMUX_TEST_APP_PUBLIC_KEY as its
# SUPublicEDKey (an empty value leaves the key out).
HDI_BIN="$TMP_DIR/hdi-bin"
mkdir -p "$HDI_BIN"
cat > "$HDI_BIN/hdiutil" <<'HDI'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  detach) exit 0 ;;
  attach) ;;
  *) echo "fake hdiutil: unexpected $*" >&2; exit 1 ;;
esac
mountpoint=""
while [ $# -gt 0 ]; do
  case "$1" in -mountpoint) mountpoint="$2"; shift ;; esac
  shift
done
[ -n "$mountpoint" ] || { echo "fake hdiutil: no -mountpoint" >&2; exit 1; }
mkdir -p "$mountpoint/cmux.app/Contents"
python3 - "$mountpoint/cmux.app/Contents/Info.plist" "${CMUX_TEST_APP_PUBLIC_KEY-}" <<'PY'
import plistlib, sys
info = {"CFBundleIdentifier": "com.cmuxterm.app"}
if sys.argv[2]:
    info["SUPublicEDKey"] = sys.argv[2]
with open(sys.argv[1], "wb") as f:
    plistlib.dump(info, f)
PY
HDI
cp "$HDI_BIN/hdiutil" "$FAKE_BIN/hdiutil"
chmod +x "$FAKE_BIN"/* "$FAKE_TOOLS"/* "$HDI_BIN"/*

# RFC 8032 test vectors 1 and 2: a real Ed25519 seed (Sparkle's private key
# format), its public key, and a different public key.
TEST_PRIVATE_KEY="nWGxne/9WmC6hEr0kuwsxERJxWl7MmkZcDusAxyuf2A"
TEST_PUBLIC_KEY="11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURo="
OTHER_PUBLIC_KEY="PUAXw+hDiVqStwqnTRt+vJyYLM8uxJaMwM1V8Sr0Zgw="

# Isolate the pinned download path from source builds and tools injection.
PINNED_BIN="$TMP_DIR/pinned-bin"
mkdir -p "$PINNED_BIN"
cat > "$PINNED_BIN/curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail
out=""
while [ $# -gt 0 ]; do
  case "$1" in -o) out="$2"; shift;; esac
  url="$1"
  shift
done
[ "$url" = "https://github.com/sparkle-project/Sparkle/releases/download/2.8.1/Sparkle-2.8.1.tar.xz" ]
[ -n "$out" ]
printf fixture-tarball > "$out"
echo download >> "$CMUX_TEST_PINNED_CALLS"
CURL
cat > "$PINNED_BIN/shasum" <<'SHA'
#!/usr/bin/env bash
set -euo pipefail
[ "$1" = -a ] && [ "$2" = 256 ]
[ "$(cat "$3")" = fixture-tarball ]
echo checksum >> "$CMUX_TEST_PINNED_CALLS"
printf '%s  %s\n' "${CMUX_TEST_PINNED_SHA:-5cddb7695674ef7704268f38eccaee80e3accbf19e61c1689efff5b6116d85be}" "$3"
SHA
cat > "$PINNED_BIN/tar" <<'TAR'
#!/usr/bin/env bash
set -euo pipefail
[ "$1" = -xf ] && [ "$3" = -C ] && [ "$5" = ./bin ]
[ "$(cat "$2")" = fixture-tarball ]
mkdir -p "$4/bin"
cp "$CMUX_TEST_FAKE_TOOLS/"* "$4/bin/"
echo extract >> "$CMUX_TEST_PINNED_CALLS"
TAR
for command in git xcodebuild; do
  printf '#!/usr/bin/env bash\necho "unexpected source build" >&2\nexit 99\n' > "$PINNED_BIN/$command"
done
chmod +x "$PINNED_BIN/"*

run_script() {
  local bash_bin="$1" out="$2"
  shift 2
  PATH="$FAKE_BIN:$PATH" \
  CMUX_TEST_FAKE_TOOLS="$FAKE_TOOLS" \
  CMUX_TEST_ARGV_LOG="$TMP_DIR/argv.log" \
  CMUX_TEST_BINARY_DELTA_MARKER="$TMP_DIR/binary-delta-called" \
  SPARKLE_PRIVATE_KEY="$TEST_PRIVATE_KEY" \
  CMUX_TEST_APP_PUBLIC_KEY="${CMUX_TEST_APP_PUBLIC_KEY-$TEST_PUBLIC_KEY}" \
  SPARKLE_VERSION="0.0.0-test" \
  SPARKLE_MINIMUM_SYSTEM_VERSION="${CMUX_TEST_MINIMUM_SYSTEM_VERSION-26.0}" \
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
  # The macOS floor reaches the new item even though the generator omitted it.
  grep -q '<sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>' "$out_dir/appcast.xml" \
    || fail "bash $version: appcast item lacks sparkle:minimumSystemVersion 26.0"
  if CMUX_TEST_MINIMUM_SYSTEM_VERSION= run_script "$bash_bin" "$out_dir/appcast-no-floor.xml" env -u SPARKLE_PREVIOUS_ARCHIVES_DIR >"$out_dir/run-no-floor.log" 2>&1; then
    fail "bash $version: generation succeeded without SPARKLE_MINIMUM_SYSTEM_VERSION"
  fi
  [ ! -e "$out_dir/appcast-no-floor.xml" ] || fail "bash $version: an appcast was written without a macOS floor"
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
  # Explicit tools-directory injection remains a separate supported path.
  if ! run_script "$bash_bin" "$out_dir/appcast-tools.xml" env SPARKLE_TOOLS_DIR="$FAKE_TOOLS" SPARKLE_PREVIOUS_ARCHIVES_DIR="$TMP_DIR/previous" SPARKLE_MAXIMUM_DELTAS=1 PATH="$HDI_BIN:/usr/bin:/bin" >"$out_dir/run-tools.log" 2>&1; then
    fail "bash $version: script failed with SPARKLE_TOOLS_DIR: $(tail -n 5 "$out_dir/run-tools.log")"
  fi
  grep -q 'sparkle:edSignature' "$out_dir/appcast-tools.xml" || fail "bash $version: SPARKLE_TOOLS_DIR appcast lacks sparkle:edSignature"
  pinned_calls="$out_dir/pinned-calls"
  : > "$pinned_calls"
  if ! run_script "$bash_bin" "$out_dir/appcast-pinned.xml" env -u SPARKLE_TOOLS_DIR -u SPARKLE_PREVIOUS_ARCHIVES_DIR SPARKLE_VERSION=2.8.1 CMUX_TEST_PINNED_CALLS="$pinned_calls" PATH="$PINNED_BIN:$HDI_BIN:$PATH" >"$out_dir/run-pinned.log" 2>&1; then
    fail "bash $version: pinned download path failed: $(tail -n 5 "$out_dir/run-pinned.log")"
  fi
  [ "$(paste -sd, "$pinned_calls")" = download,checksum,extract ] || fail "pinned tools did not download, verify, then extract"
  grep -q 'sparkle:edSignature' "$out_dir/appcast-pinned.xml" || fail "pinned download path produced no signed appcast"
  : > "$pinned_calls"
  if run_script "$bash_bin" "$out_dir/appcast-bad-checksum.xml" env -u SPARKLE_TOOLS_DIR -u SPARKLE_PREVIOUS_ARCHIVES_DIR SPARKLE_VERSION=2.8.1 CMUX_TEST_PINNED_SHA=bad CMUX_TEST_PINNED_CALLS="$pinned_calls" PATH="$PINNED_BIN:$HDI_BIN:$PATH" >"$out_dir/run-bad-checksum.log" 2>&1; then
    fail "bash $version: mismatched pinned tarball checksum was accepted"
  fi
  [ "$(paste -sd, "$pinned_calls")" = download,checksum ] || fail "mismatched pinned tarball was extracted"
  [ ! -e "$out_dir/appcast-bad-checksum.xml" ] || fail "mismatched pinned tarball produced an appcast"
  [ ! -e "$TMP_DIR/binary-delta-called" ] || fail "BinaryDelta ran for unmountable fixtures"
  echo "ok: bash $version generates a signed appcast with and without previous archives"
done

# release.yml must not trust the generator's exit status alone (bash 3.2 masks it).
RELEASE_WORKFLOW="$ROOT_DIR/.github/workflows/release.yml"
step="$(awk '/sparkle_generate_appcast.sh cmux-macos.dmg/{p=1} p{print} p&&/^      - name:/{exit}' "$RELEASE_WORKFLOW")"
grep -q 'test -s appcast.xml' <<<"$step" || fail "release.yml must verify appcast.xml exists after generation"
grep -q "grep -q 'sparkle:edSignature' appcast.xml" <<<"$step" || fail "release.yml must verify the appcast is signed after generation"

echo "PASS: sparkle_generate_appcast.sh produces a signed appcast on the no-delta release path under every local bash"

# Key checks (HQ 2906): generate_appcast leaves the feed unsigned when the
# private key's public key is not the app's SUPublicEDKey, and the sign_update
# fallback used to sign it anyway, publishing a feed every installed app rejects.
bash_bin="$(command -v bash)"
key_dir="$TMP_DIR/keys"
mkdir -p "$key_dir"
expect_refused() {
  local label="$1" out="$key_dir/$2.xml" pattern="$3"
  shift 3
  if run_script "$bash_bin" "$out" env -u SPARKLE_PREVIOUS_ARCHIVES_DIR "$@" >"$key_dir/$label.log" 2>&1; then
    fail "$label: generation succeeded: $(tail -n 5 "$key_dir/$label.log")"
  fi
  [ ! -e "$out" ] || fail "$label: an appcast was written"
  grep -q -- "$pattern" "$key_dir/$label.log" || fail "$label: missing '$pattern' in: $(tail -n 5 "$key_dir/$label.log")"
}
# The app in the DMG trusts another key: refuse before generating anything.
expect_refused mismatch mismatch "does not match the app's SUPublicEDKey" \
  CMUX_TEST_APP_PUBLIC_KEY="$OTHER_PUBLIC_KEY" CMUX_TEST_GENERATE_UNSIGNED=1
expect_refused mismatch-signed mismatch-signed "does not match the app's SUPublicEDKey" \
  CMUX_TEST_APP_PUBLIC_KEY="$OTHER_PUBLIC_KEY"
# An app with no SUPublicEDKey can never accept an update from this feed.
expect_refused no-app-key no-app-key "has no SUPublicEDKey" CMUX_TEST_APP_PUBLIC_KEY=
# A private key that is not an Ed25519 key cannot be checked: fail closed.
expect_refused bad-private-key bad-private-key "could not derive" SPARKLE_PRIVATE_KEY=Zml4dHVyZS1rZXk
# The enclosure must announce the exact DMG size.
expect_refused wrong-length wrong-length "length" CMUX_TEST_ENCLOSURE_LENGTH=4
# A fallback signature that sign_update cannot verify is never published.
expect_refused verify-fails verify-fails "signature does not verify" \
  CMUX_TEST_GENERATE_UNSIGNED=1 CMUX_TEST_VERIFY_FAIL=1

# Matching key, generator left the feed unsigned: the fallback signs it,
# verifies the signature and leaves one length attribute with the DMG size.
: > "$key_dir/sign.log"
if ! run_script "$bash_bin" "$key_dir/fallback.xml" env -u SPARKLE_PREVIOUS_ARCHIVES_DIR \
  CMUX_TEST_GENERATE_UNSIGNED=1 CMUX_TEST_SIGN_LOG="$key_dir/sign.log" >"$key_dir/fallback.log" 2>&1; then
  fail "fallback: generation failed: $(tail -n 5 "$key_dir/fallback.log")"
fi
grep -q -- "^--verify --ed-key-file .* fallback-signature$" "$key_dir/sign.log" \
  || fail "fallback: the injected signature was not verified with sign_update --verify: $(cat "$key_dir/sign.log")"
python3 - "$key_dir/fallback.xml" "$(wc -c < "$TMP_DIR/cmux-macos.dmg" | tr -d ' ')" <<'PY' || fail "fallback: enclosure is not signed with the exact DMG length"
import sys
import xml.etree.ElementTree as ET
path, size = sys.argv[1:3]
ns = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
enclosures = [e for e in ET.parse(path).iter("enclosure") if e.get("url", "").endswith("/cmux-macos.dmg")]
assert len(enclosures) == 1, enclosures
enclosure = enclosures[0]
assert enclosure.get(ns + "edSignature") == "fallback-signature", enclosure.attrib
assert enclosure.get("length") == size, enclosure.attrib
PY
echo "PASS: sparkle_generate_appcast.sh refuses a private key the app does not trust and verifies the fallback signature and length"

# Duplicate archive versions must not compete for the same output path or
# consume both slots, excluding an older distinct version.
mkdir -p "$TMP_DIR/dedup"
for archive in new-103 old-102 duplicate-102 old-101; do
  touch "$TMP_DIR/dedup/$archive.dmg"
done
cat > "$TMP_DIR/dedup/BinaryDelta" <<'BD'
#!/usr/bin/env bash
if [ "$1" = create ]; then
  basename "$4" >> "$CMUX_TEST_DELTA_CALLS"
  sleep 0.1
  touch "$4"
fi
BD
chmod +x "$TMP_DIR/dedup/BinaryDelta"
export CMUX_TEST_DELTA_CALLS="$TMP_DIR/dedup/calls"
# Supply filesystem-backed DMG/plist doubles while executing the full worker
# pipeline unchanged, including its background processes and output promotion.
bash -c '
  hdiutil() {
    [ "$1" = attach ] || return 0
    archive="$2"
    shift 2
    while [ "$1" != -mountpoint ]; do shift; done
    mkdir -p "$2/cmux.app/Contents"
    version="${archive%.dmg}"
    printf "%s" "${version##*-}" > "$2/cmux.app/Contents/Info.plist"
  }
  ditto() { cp -R "$1" "$2"; }
  function /usr/libexec/PlistBuddy() {
    case "$3" in
      *Frameworks*) echo 2041 ;;
      *) cat "$3" ;;
    esac
  }
  script="$1"
  shift
  source "$script"
' _ "$ROOT_DIR/scripts/prebuild_sparkle_deltas.sh" "$TMP_DIR/dedup/BinaryDelta" "$TMP_DIR/dedup" "$TMP_DIR/dedup/new-103.dmg" 2
[ "$(sort "$CMUX_TEST_DELTA_CALLS" | uniq | wc -l | tr -d ' ')" = 2 ] || fail "duplicate versions consumed a delta slot"
[ "$(wc -l < "$CMUX_TEST_DELTA_CALLS" | tr -d ' ')" = 2 ] || fail "duplicate delta workers ran"
[ -f "$TMP_DIR/dedup/cmux103-101.delta" ] || fail "older distinct version was excluded"
[ -f "$TMP_DIR/dedup/cmux103-102.delta" ] || fail "newest prior version was excluded"
echo "PASS: duplicate archive versions produce distinct delta workers"
