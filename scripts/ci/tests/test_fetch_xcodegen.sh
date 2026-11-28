#!/usr/bin/env bash
# Tests scripts/ci/fetch-xcodegen.sh with curl and gh stubbed: cache hit, auth header, checksum mismatch,
# gh fallback. Run: bash scripts/ci/tests/test_fetch_xcodegen.sh
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
helper="$here/../fetch-xcodegen.sh"
t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT
mkdir -p "$t/bin" "$t/pkg/xcodegen/bin" "$t/pkg/xcodegen/share"
printf '#!/bin/sh\necho fake\n' >"$t/pkg/xcodegen/bin/xcodegen"; chmod +x "$t/pkg/xcodegen/bin/xcodegen"
(cd "$t/pkg" && zip -qr "$t/good.zip" xcodegen)
good="$(shasum -a 256 "$t/good.zip" | awk '{print $1}')"
# curl stub: logs its args, copies good.zip to the -o target, fails 403 unless STUB_CURL_FAIL is unset.
cat >"$t/bin/curl" <<STUB
#!/bin/bash
echo "\$*" >>"$t/curl.log"
[[ -z "\${STUB_CURL_FAIL:-}" ]] || exit 22
while [[ \$# -gt 0 ]]; do [[ "\$1" == -o ]] && out="\$2"; shift; done
cp "\${STUB_ZIP:-$t/good.zip}" "\$out"
STUB
cat >"$t/bin/gh" <<STUB
#!/bin/bash
echo "gh \$*" >>"$t/curl.log"
[[ "\$1" == auth ]] && exit 0
while [[ \$# -gt 0 ]]; do [[ "\$1" == -O ]] && out="\$2"; shift; done
cp "$t/good.zip" "\$out"
STUB
chmod +x "$t/bin/curl" "$t/bin/gh"
fail() { echo "FAIL: $*" >&2; exit 1; }
run() { CMUX_FLEET_TOOLS="${FLEET:-$t/nofleet}" PATH="$t/bin:$PATH" CMUX_CI_CACHE="$t/cache" HOME="$t/home" env -u GITHUB_TOKEN -u GH_TOKEN "$@" bash "$helper" 2.46.0 "$good" "$t/dest"; }

# 1. token: Bearer header, then cached
: >"$t/curl.log"
out="$(GITHUB_TOKEN=tok run env GITHUB_TOKEN=tok)" || fail "token run"
[[ "$out" == "$t/dest/xcodegen/bin/xcodegen" && -x "$out" ]] || fail "bin path $out"
grep -q -- "Authorization: Bearer tok" "$t/curl.log" || fail "no auth header"
[[ -f "$t/cache/xcodegen/2.46.0/xcodegen.zip" ]] || fail "not cached"
# 2. cache hit: no network
: >"$t/curl.log"; rm -rf "$t/dest"
STUB_CURL_FAIL=1 run env STUB_CURL_FAIL=1 >/dev/null || fail "cache hit"
[[ ! -s "$t/curl.log" ]] || fail "cache hit touched the network"
# 3. no token, curl blocked: gh fallback; anonymous curl not tried first
rm -rf "$t/cache" "$t/dest"; : >"$t/curl.log"
run >/dev/null || fail "gh fallback"
head -2 "$t/curl.log" | grep -q "^gh release download --repo yonaskolb/XcodeGen 2.46.0 -p xcodegen.zip" || fail "gh not used: $(cat "$t/curl.log")"
# 4. checksum mismatch: fails, nothing cached
rm -rf "$t/cache" "$t/dest"; echo junk >"$t/bad.zip"
if run env STUB_ZIP="$t/bad.zip" GITHUB_TOKEN=tok >"$t/o" 2>"$t/e"; then fail "mismatch accepted"; fi
grep -q "expected $good" "$t/e" || fail "no mismatch message"
[[ ! -e "$t/cache/xcodegen/2.46.0/xcodegen.zip" ]] || fail "bad zip cached"
# 5. fleet tools copy wins, no network; a wrong-version copy is skipped
rm -rf "$t/cache" "$t/dest"; : >"$t/curl.log"
mkdir -p "$t/fleet/xcodegen-2.46.0/bin" "$t/fleet/xcodegen-2.46.0/share/xcodegen"
printf '#!/bin/sh\necho "Version: 2.46.0"\n' >"$t/fleet/xcodegen-2.46.0/bin/xcodegen"; chmod +x "$t/fleet/xcodegen-2.46.0/bin/xcodegen"
out="$(FLEET="$t/fleet" run env FLEET="$t/fleet")" || fail "fleet tools"
[[ "$out" == "$t/dest/xcodegen/bin/xcodegen" && -d "$t/dest/xcodegen/share/xcodegen" ]] || fail "fleet copy $out"
[[ ! -s "$t/curl.log" ]] || fail "fleet copy touched the network"
printf '#!/bin/sh\necho "Version: 2.40.0"\n' >"$t/fleet/xcodegen-2.46.0/bin/xcodegen"; rm -rf "$t/dest"
FLEET="$t/fleet" run env FLEET="$t/fleet" >/dev/null || fail "wrong-version fleet copy"
[[ -s "$t/curl.log" ]] || fail "wrong-version fleet copy was used"
echo "ok"
