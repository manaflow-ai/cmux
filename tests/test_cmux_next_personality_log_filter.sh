#!/usr/bin/env bash
# The personality checker must not turn a successful xcodebuild into a red
# job because its bounded log display reader closes the pipe early.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CHECK="$ROOT_DIR/scripts/cmux-next/check-app-personalities.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

touch "$tmp/app.bin"
cat >"$tmp/lipo" <<'TOOL'
#!/usr/bin/env bash
echo arm64
TOOL
cat >"$tmp/xcrun" <<'TOOL'
#!/usr/bin/env bash
cat <<'OUT'
Personality functions: (count = 1)
  personality[1]: 0x123
  personality[2]: 0x456
  personality[3]: 0x789
  personality[4]: 0xabc
  personality[5]: 0xdef
  personality[6]: 0x111
  personality[7]: 0x222
  personality[8]: 0x333
  personality[9]: 0x444

Top level indices:
OUT
TOOL
cat >"$tmp/sed" <<'TOOL'
#!/usr/bin/env bash
# Model macOS sed receiving SIGPIPE when head closes after eight lines.
printf '%s\n' \
  'Personality functions: (count = 1)' \
  '  personality[1]: 0x123' \
  '  personality[2]: 0x456' \
  '  personality[3]: 0x789' \
  '  personality[4]: 0xabc' \
  '  personality[5]: 0xdef' \
  '  personality[6]: 0x111' \
  '  personality[7]: 0x222' \
  '  personality[8]: 0x333' \
  '  personality[9]: 0x444' \
  '' \
  'Top level indices:'
exit 141
TOOL
chmod +x "$tmp/lipo" "$tmp/xcrun" "$tmp/sed"

PATH="$tmp:$PATH" "$CHECK" "$tmp/app.bin" >"$tmp/output"
grep -q 'app.bin arm64: 1 personality routine' "$tmp/output"
echo "PASS: personality log filtering ignores a broken-pipe reader"
