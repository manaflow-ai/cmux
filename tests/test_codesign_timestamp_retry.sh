#!/usr/bin/env bash
# Signing survives Apple's timestamp service failing for a moment, and still fails at once on any other
# codesign error. codesign is a stub that fails its first N calls; no keychain, runs on Linux.
# Red before scripts/codesign-retry.sh: one failed timestamp turned nightly-next runs 43587666320,
# 43595656749 and 43649298848 red.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

cat > "$TMP/codesign" <<'STUB'
#!/usr/bin/env bash
# Fails its first $STUB_FAILS calls with $STUB_MESSAGE, then succeeds; logs every call.
n=$(( $(cat "$STUB_COUNT" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$STUB_COUNT"
printf '%s\n' "$*" >> "$STUB_LOG"
if (( n <= STUB_FAILS )); then echo "${@: -1}: $STUB_MESSAGE" >&2; exit 1; fi
STUB
cat > "$TMP/file" <<'STUB'
#!/usr/bin/env bash
echo "Mach-O 64-bit executable arm64"
STUB
chmod +x "$TMP/codesign" "$TMP/file"

run() { # <fails> <message> <command...>: run with a fresh stub
  rm -f "$TMP/count" "$TMP/log"
  STUB_FAILS="$1" STUB_MESSAGE="$2" STUB_COUNT="$TMP/count" STUB_LOG="$TMP/log" \
    CMUX_CODESIGN_TOOL="$TMP/codesign" CMUX_FILE_TOOL="$TMP/file" CMUX_CODESIGN_RETRY_DELAY=0 "${@:3}"
}
calls() { cat "$TMP/count" 2>/dev/null || echo 0; }

# 1. The SSH payload signer: two timestamp failures, then a signature.
app="$TMP/cmux NIGHTLY.app"; dir="$app/Contents/Resources/bin/cmux-tui-ssh"; mkdir -p "$dir"
printf 'MACHO' > "$dir/cmux-tui-aarch64-apple-darwin"
printf '{"binaries": {"cmux-tui-aarch64-apple-darwin": "%s"}}\n' \
  "$(sha256sum "$dir/cmux-tui-aarch64-apple-darwin" | cut -d' ' -f1)" > "$dir/manifest.json"
out=$(run 2 "The timestamp service is not available." \
  "$ROOT/scripts/sign-cmux-tui-ssh-payloads.sh" "$app" /dev/null "Developer ID Application: Test (TEAMID1234)" 2>&1) \
  || fail "a transient timestamp failure failed the signing: $out"
[[ "$(calls)" == 3 ]] || fail "expected 3 codesign calls (2 failed, 1 signed), got $(calls)"

# 2. The wrapper: the other message Apple's service gives (runs 43595656749, 43649298848).
run 1 "A timestamp was expected but was not found." "$ROOT/scripts/codesign-retry.sh" --force x >/dev/null 2>&1 \
  || fail "the wrapper did not retry 'A timestamp was expected but was not found.'"
[[ "$(calls)" == 2 ]] || fail "expected 2 calls, got $(calls)"

# 3. Any other codesign error exits at once with its status.
if run 5 "errSecInternalComponent" "$ROOT/scripts/codesign-retry.sh" --force x >/dev/null 2>&1; then
  fail "a non-timestamp failure was reported as success"
fi
[[ "$(calls)" == 1 ]] || fail "a non-timestamp failure was retried ($(calls) calls)"

# 4. The tries are bounded: a service that stays down fails after CMUX_CODESIGN_TIMESTAMP_TRIES calls.
if CMUX_CODESIGN_TIMESTAMP_TRIES=3 run 9 "The timestamp service is not available." \
  "$ROOT/scripts/codesign-retry.sh" --force x >/dev/null 2>&1; then
  fail "a service that stayed down was reported as success"
fi
[[ "$(calls)" == 3 ]] || fail "expected 3 bounded tries, got $(calls)"

# 5. Every Developer ID signing script goes through the wrapper (the class, not one script).
for f in scripts/sign-cmux-bundle.sh scripts/sign-cmux-bundle-helpers.sh scripts/sign-cmux-tui-ssh-payloads.sh \
  scripts/cmux-next/sign-cef.sh scripts/cmux-next/remote-browser-host-layout.sh; do
  grep -q 'codesign-retry.sh' "$ROOT/$f" || fail "$f signs without scripts/codesign-retry.sh"
  if grep -nE '^[^#]*(^|[;&|( ]|then |do )(/usr/bin/)?codesign ("\$\{(COMMON|flags)|--force)' "$ROOT/$f"; then
    fail "$f still runs codesign itself to sign"
  fi
done

echo "codesign timestamp retry tests: ok"
