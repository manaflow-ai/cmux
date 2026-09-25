#!/usr/bin/env bash
# The cmux-tui SSH payloads under Contents/Resources/bin/cmux-tui-ssh/ are
# builds for other hosts, one per platform. Nightly broke on them twice
# (runs 35956151820, 35958983153):
#   - thin-app-bundle.sh rejected the x86_64 payload when thinning to arm64;
#   - notarization rejected both darwin payloads as unsigned.
# Thinning must leave them alone, and signing must Developer ID sign the Mach-O
# payloads and re-pin their checksums so cmux-tui still accepts them.
# Runs anywhere: lipo, file and codesign are faked.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cmux-tui-ssh-payloads.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
sha() { python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"; }

TOOLS="$TMP_DIR/tools"
mkdir -p "$TOOLS"
# Test binaries are text: "MACHO <arch>..." or "ELF".
cat > "$TOOLS/file" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == -b ]] && shift
read -r kind archs < "$1" || true
case "$kind" in
  MACHO) if [[ "$archs" == *" "* ]]; then echo "Mach-O universal binary with 2 architectures"; else echo "Mach-O 64-bit executable $archs"; fi ;;
  ELF) echo "ELF 64-bit LSB executable" ;;
  *) echo "ASCII text" ;;
esac
EOF
cat > "$TOOLS/lipo" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == -archs ]]; then read -r _ archs < "$2"; echo "$archs"; exit 0; fi
path="$1"; shift
read -r _ archs < "$path"
case "$1" in
  -verify_arch) [[ " $archs " == *" $2 "* ]] ;;
  -thin) printf 'MACHO %s\n' "$2" > "$4" ;;
  *) exit 64 ;;
esac
EOF
cat > "$TOOLS/codesign" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CODESIGN_LOG"
for last; do :; done
printf 'SIGNED\n' >> "$last"
EOF
chmod +x "$TOOLS"/*

make_app() {
  local app="$1"
  local dir="$app/Contents/Resources/bin/cmux-tui-ssh"
  mkdir -p "$app/Contents/MacOS" "$dir"
  printf 'MACHO arm64 x86_64\n' > "$app/Contents/MacOS/cmux"
  printf 'MACHO arm64 x86_64\n' > "$app/Contents/Resources/bin/cmux-tui"
  printf 'MACHO arm64\n' > "$dir/cmux-tui-aarch64-apple-darwin"
  printf 'MACHO x86_64\n' > "$dir/cmux-tui-x86_64-apple-darwin"
  printf 'ELF aarch64\n' > "$dir/cmux-tui-aarch64-unknown-linux-musl"
  printf 'ELF x86_64\n' > "$dir/cmux-tui-x86_64-unknown-linux-musl"
  python3 - "$dir" <<'PY'
import hashlib, json, os, sys
d = sys.argv[1]
binaries = {n: hashlib.sha256(open(os.path.join(d, n), "rb").read()).hexdigest() for n in os.listdir(d)}
json.dump({"commit": "a" * 40, "binaries": binaries}, open(os.path.join(d, "manifest.json"), "w"))
PY
}

# 1. Thinning a bundle to either architecture keeps every SSH payload intact.
for arch in arm64 x86_64; do
  APP="$TMP_DIR/thin-$arch/cmux.app"
  make_app "$APP"
  before="$(cd "$APP/Contents/Resources/bin/cmux-tui-ssh" && cat ./*)"
  CMUX_LIPO_TOOL="$TOOLS/lipo" CMUX_FILE_TOOL="$TOOLS/file" \
    "$ROOT/scripts/thin-app-bundle.sh" "$APP" "$arch" >/dev/null \
    || fail "thinning to $arch rejected the cmux-tui SSH payloads"
  [[ "$(cat "$APP/Contents/MacOS/cmux")" == "MACHO $arch" ]] || fail "app binary was not thinned to $arch"
  [[ "$(cat "$APP/Contents/Resources/bin/cmux-tui")" == "MACHO $arch" ]] || fail "cmux-tui was not thinned to $arch"
  after="$(cd "$APP/Contents/Resources/bin/cmux-tui-ssh" && cat ./*)"
  [[ "$before" == "$after" ]] || fail "thinning to $arch modified the cmux-tui SSH payloads"
done

# A foreign single-arch binary elsewhere in the bundle is still rejected.
BAD="$TMP_DIR/bad/cmux.app"
make_app "$BAD"
printf 'MACHO x86_64\n' > "$BAD/Contents/Resources/bin/cmux-tui"
if CMUX_LIPO_TOOL="$TOOLS/lipo" CMUX_FILE_TOOL="$TOOLS/file" \
  "$ROOT/scripts/thin-app-bundle.sh" "$BAD" arm64 >/dev/null 2>&1; then
  fail "thinning accepted an x86_64-only cmux-tui in an arm64 bundle"
fi

# 2. Signing signs exactly the Mach-O payloads and re-pins them in the manifest.
APP="$TMP_DIR/sign/cmux.app"
make_app "$APP"
DIR="$APP/Contents/Resources/bin/cmux-tui-ssh"
linux_before="$(sha "$DIR/cmux-tui-x86_64-unknown-linux-musl")"
[[ -x "$ROOT/scripts/sign-cmux-tui-ssh-payloads.sh" ]] || fail "scripts/sign-cmux-tui-ssh-payloads.sh is missing"
CODESIGN_LOG="$TMP_DIR/codesign.log" CMUX_CODESIGN_TOOL="$TOOLS/codesign" CMUX_FILE_TOOL="$TOOLS/file" \
  "$ROOT/scripts/sign-cmux-tui-ssh-payloads.sh" "$APP" "$ROOT/cmux-helper.entitlements" "Developer ID Application: Test" >/dev/null
signed="$(grep -o 'cmux-tui-[a-z0-9_-]*$' "$TMP_DIR/codesign.log" | sort | tr '\n' ' ')"
[[ "$signed" == "cmux-tui-aarch64-apple-darwin cmux-tui-x86_64-apple-darwin " ]] \
  || fail "signed the wrong payloads: $signed"
grep -q -- '--options runtime --timestamp --sign Developer ID Application: Test' "$TMP_DIR/codesign.log" \
  || fail "payloads were not signed with the hardened runtime and a secure timestamp"
python3 - "$DIR" <<'PY' || fail "manifest does not pin the signed payloads"
import hashlib, json, os, sys
d = sys.argv[1]
manifest = json.load(open(os.path.join(d, "manifest.json")))
assert manifest["commit"] == "a" * 40, manifest
for name, want in manifest["binaries"].items():
    got = hashlib.sha256(open(os.path.join(d, name), "rb").read()).hexdigest()
    assert got == want, (name, got, want)
PY
[[ "$(sha "$DIR/cmux-tui-x86_64-unknown-linux-musl")" == "$linux_before" ]] || fail "a Linux payload was modified"

# A payload that no longer matches its pin is refused rather than re-pinned.
APP="$TMP_DIR/tampered/cmux.app"
make_app "$APP"
printf 'ELF tampered\n' > "$APP/Contents/Resources/bin/cmux-tui-ssh/cmux-tui-aarch64-unknown-linux-musl"
if CODESIGN_LOG="$TMP_DIR/codesign2.log" CMUX_CODESIGN_TOOL="$TOOLS/codesign" CMUX_FILE_TOOL="$TOOLS/file" \
  "$ROOT/scripts/sign-cmux-tui-ssh-payloads.sh" "$APP" "$ROOT/cmux-helper.entitlements" "Developer ID Application: Test" >/dev/null 2>&1; then
  fail "signing accepted a payload that does not match its manifest checksum"
fi

# 3. The bundle signer signs the payloads before it seals the app.
grep -q 'sign-cmux-tui-ssh-payloads.sh' "$ROOT/scripts/sign-cmux-bundle.sh" \
  || fail "sign-cmux-bundle.sh does not sign the cmux-tui SSH payloads"

echo "PASS: cmux-tui SSH payloads survive thinning and are signed and re-pinned"
