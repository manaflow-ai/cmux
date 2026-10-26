#!/usr/bin/env bash
# Developer ID sign a cmux NEXT DEV .app bundle on Linux with stock rcodesign.
#
# Usage: scripts/ci/rcodesign-sign-bundle-dev.sh <app-path> <app-entitlements>
#
# This is the Linux counterpart of scripts/sign-cmux-bundle.sh, which the DEV
# sign job runs on a Mac with /usr/bin/codesign. It uses the stock apple-codesign
# release (scripts/ci/install-rcodesign.sh pins 0.29.0 by sha256), so a public
# workflow on a Linux runner can sign without a Mac or a private toolchain.
#
# Env:
#   APPLE_CERTIFICATE_BASE64    the Developer ID PKCS#12, base64 (required)
#   APPLE_CERTIFICATE_PASSWORD  its password (required)
#   APPLE_SIGNING_IDENTITY      optional; the certificate must match it as codesign
#                               --sign matches (common-name substring, or SHA-1)
#   RCODESIGN                   the rcodesign binary (default: rcodesign on PATH)
#   CMUX_HELPER_ENTITLEMENTS    default cmux-helper.entitlements
#   CMUX_TIMESTAMP              "none": no time stamp, no notarization checks (tests)
#
# The key material is written only into a mktemp -d directory created with
# umask 077, which the EXIT trap removes. Neither the key, the PKCS#12 nor its
# password is ever on a command line: openssl reads the PKCS#12 from stdin and
# the password with -passin env:, and rcodesign reads the PEM file by path.
#
# Each component gets what sign-cmux-bundle.sh gives it. rcodesign signs the
# whole bundle in one pass, nested code before its parent, so the per-component
# settings are path-scoped options (--entitlements-xml-file <path>:<file>,
# --code-signature-flags <path>:runtime):
#   - Mach-O executables in Contents/Resources/bin and libexec: the helper
#     entitlements. Scripts there stay unsigned and sealed by the bundle, as
#     signing them would put the signature in an xattr that breaks Sparkle's
#     BinaryDelta.
#   - The cmux-tui SSH payloads: signed on their own with the helper
#     entitlements, re-pinned in their manifest.json (as
#     sign-cmux-tui-ssh-payloads.sh does), then excluded from the bundle pass so
#     their bytes keep matching the pin.
#   - The Computer Use helper app: its executable gets the helper entitlements.
#   - Everything under Contents/PlugIns and Contents/Frameworks (codesign --deep,
#     no entitlements): no entitlements. That includes the CEF helpers, so GPU
#     and Renderer get no allow-jit, the same as on the Mac today.
#   - The main executable: the app entitlements reconciled with the embedded
#     profile by reconcile-entitlements-with-profile.py.
#   - Contents/Library/SystemExtensions is removed when the entitlements do not
#     request the Cloud tunnel, and this script refuses a channel that does.
#   - Sparkle's sandbox XPC services are removed first.
# Every Mach-O gets the hardened runtime, and --for-notarization makes
# rcodesign require a Developer ID certificate and Apple's time stamp server.
#
# rcodesign keeps the entitlements of an existing signature when a Mach-O is
# given none, where codesign --force drops them. Each Mach-O under PlugIns and
# Frameworks whose current signature has entitlements (embed-cef.sh's ad hoc
# allow-jit on the CEF helpers, Sparkle's Autoupdate) is therefore given an
# empty set: an empty entitlements blob where codesign writes none. Mach-O
# files that sign-cmux-bundle.sh leaves alone (other executables in
# Contents/MacOS, Contents/Helpers, nested code inside the Computer Use app)
# rcodesign must re-sign as well; they keep the entitlements they were built
# with, as they do on the Mac, and gain the hardened runtime.
#
# The output differs from codesign only in bytes that codesign --verify --deep
# --strict accepts: 4 KiB code page hashes on arm64, the LC_CODE_SIGNATURE
# reservation and an unrounded __LINKEDIT vmsize, DER instead of BER CMS framing,
# re-serialized entitlements XML (the DER entitlements are the same), the
# nested requirement text in CodeResources, and the signing time, time stamp
# and RSA signature, which differ between any two signing runs. The workflow's
# verify job checks this output with Apple's codesign on a Mac. The checks
# sign-cmux-bundle.sh makes with codesign -d after signing (entitlements,
# sidecar) belong to the workflow, not to this script.
# Every signed Mach-O is checked with rcodesign verify at the end; any failure
# exits non-zero.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <app-path> <app-entitlements>" >&2
  exit 2
fi

APP_PATH="${1%/}"
APP_ENTITLEMENTS="$2"
HELPER_ENTITLEMENTS="${CMUX_HELPER_ENTITLEMENTS:-cmux-helper.entitlements}"
R="${RCODESIGN:-rcodesign}"

if [[ ! -d "$APP_PATH/Contents" ]]; then
  echo "error: app bundle not found at $APP_PATH" >&2
  exit 1
fi
if [[ ! -f "$APP_ENTITLEMENTS" ]]; then
  echo "error: app entitlements not found at $APP_ENTITLEMENTS" >&2
  exit 1
fi
if [[ ! -f "$HELPER_ENTITLEMENTS" ]]; then
  echo "error: helper entitlements not found at $HELPER_ENTITLEMENTS" >&2
  exit 1
fi
if [[ "${CMUX_SIGN_MODE:-all}" != all ]]; then
  echo "error: CMUX_SIGN_MODE=${CMUX_SIGN_MODE} is not supported here; this script signs the whole bundle" >&2
  exit 2
fi
if ! command -v "$R" >/dev/null 2>&1; then
  echo "error: rcodesign not found ($R); run scripts/ci/install-rcodesign.sh" >&2
  exit 1
fi
: "${APPLE_CERTIFICATE_BASE64:?APPLE_CERTIFICATE_BASE64 must be set}"
: "${APPLE_CERTIFICATE_PASSWORD:?APPLE_CERTIFICATE_PASSWORD must be set}"
export APPLE_CERTIFICATE_PASSWORD
APP_ENTITLEMENTS="$(cd "$(dirname "$APP_ENTITLEMENTS")" && pwd)/$(basename "$APP_ENTITLEMENTS")"
HELPER_ENTITLEMENTS="$(cd "$(dirname "$HELPER_ENTITLEMENTS")" && pwd)/$(basename "$HELPER_ENTITLEMENTS")"

secrets=""
work=""
trap 'rm -rf ${secrets:+"$secrets"} ${work:+"$work"}' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
secrets="$(umask 077 && mktemp -d "${TMPDIR:-/tmp}/cmux-rcodesign-key.XXXXXX")"
work="$(mktemp -d "${TMPDIR:-/tmp}/cmux-rcodesign-work.XXXXXX")"

# rcodesign 0.29 rejects the PBES2/AES-256 PKCS#12 a macOS keychain exports
# ("incorrect password"), so openssl converts it to one PEM file holding the
# certificate and the key. -legacy covers an older RC2-encrypted export.
(
  umask 077
  printf '%s' "$APPLE_CERTIFICATE_BASE64" | base64 -d > "$secrets/identity.p12"
) 2>/dev/null || {
  echo "error: APPLE_CERTIFICATE_BASE64 is not valid base64" >&2
  exit 1
}
pkcs12_to_pem() {
  (
    umask 077
    openssl pkcs12 "$@" -passin env:APPLE_CERTIFICATE_PASSWORD -nodes -clcerts \
      < "$secrets/identity.p12" > "$secrets/identity.pem" 2>/dev/null
  )
}
pkcs12_to_pem || pkcs12_to_pem -legacy || {
  echo "error: openssl could not open the PKCS#12 (wrong password?)" >&2
  exit 1
}
rm -f "$secrets/identity.p12"
key_count="$(grep -c -- '-----BEGIN .*PRIVATE KEY-----' < "$secrets/identity.pem" || true)"
if [[ "$key_count" != 1 ]]; then
  echo "error: the PKCS#12 must hold exactly one private key (found ${key_count:-0})" >&2
  exit 1
fi
subject="$(openssl x509 -noout -subject -nameopt multiline,utf8,-esc_msb < "$secrets/identity.pem" 2>/dev/null)" || {
  echo "error: the PKCS#12 has no certificate" >&2
  exit 1
}
common_name="$(awk '/^ *commonName *=/ { sub(/^ *commonName *= */, ""); print; exit }' <<<"$subject")"

notarize=1
[[ "${CMUX_TIMESTAMP:-}" == none ]] && notarize=0
if [[ "$notarize" == 1 && "$common_name" != "Developer ID Application:"* ]]; then
  echo "error: the certificate ($common_name) is not a Developer ID Application certificate" >&2
  exit 1
fi
if [[ -n "${APPLE_SIGNING_IDENTITY:-}" ]]; then
  if [[ "$APPLE_SIGNING_IDENTITY" =~ ^[0-9A-Fa-f]{40}$ ]]; then
    fingerprint="$(openssl x509 -noout -fingerprint -sha1 < "$secrets/identity.pem" 2>/dev/null)"
    fingerprint="${fingerprint#*=}"
    fingerprint="${fingerprint//:/}"
    if [[ "${fingerprint^^}" != "${APPLE_SIGNING_IDENTITY^^}" ]]; then
      echo "error: the certificate ($common_name) does not have the SHA-1 APPLE_SIGNING_IDENTITY names" >&2
      exit 1
    fi
  elif [[ "$common_name" != *"$APPLE_SIGNING_IDENTITY"* ]]; then
    echo "error: the certificate ($common_name) does not match APPLE_SIGNING_IDENTITY" >&2
    exit 1
  fi
fi
echo "==> signing as $common_name"

identity_args=(--config-file /dev/null --pem-file "$secrets/identity.pem")
if [[ "$notarize" == 1 ]]; then
  identity_args+=(--for-notarization)
else
  identity_args+=(--timestamp-url none)
fi

# An unzip of a Mac archive can leave AppleDouble files, which would be sealed
# as resources.
find "$APP_PATH" -name '._*' -type f -delete
rm -rf "$APP_PATH/__MACOSX"

# Effective app entitlements, as sign-cmux-bundle.sh computes them. The profile
# is CMS-wrapped; openssl unwraps it where the Mac uses security cms -D.
profile_args=(--no-profile)
if [[ -f "$APP_PATH/Contents/embedded.provisionprofile" ]]; then
  openssl cms -verify -noverify -inform DER -in "$APP_PATH/Contents/embedded.provisionprofile" \
    -out "$work/profile.plist" 2>/dev/null || {
      echo "error: could not decode Contents/embedded.provisionprofile" >&2
      exit 1
    }
  profile_args=(--profile "$work/profile.plist")
fi
python3 "$SCRIPTS_DIR/reconcile-entitlements-with-profile.py" \
  --entitlements "$APP_ENTITLEMENTS" "${profile_args[@]}" \
  --output "$work/app.entitlements" --json > "$work/reconcile.json"
read -r tunnel_requested tunnel_supported < <(python3 -I -c '
import json, sys
summary = json.load(open(sys.argv[1]))
print(int(bool(summary["tunnel_requested"])), int(bool(summary["tunnel_supported"])))
' "$work/reconcile.json")
if [[ "$tunnel_requested" == 1 && "$tunnel_supported" != 1 ]]; then
  echo "error: app entitlements require the Cloud tunnel, but the embedded app profile does not grant it" >&2
  exit 1
fi
if [[ "$tunnel_supported" == 1 ]]; then
  echo "error: this channel ships the Cloud tunnel system extension, which only scripts/sign-cmux-bundle.sh signs" >&2
  exit 1
fi
if [[ -d "$APP_PATH/Contents/Library/SystemExtensions" ]]; then
  echo "==> removing Contents/Library/SystemExtensions: this entitlement set does not request the Cloud tunnel"
  rm -rf "$APP_PATH/Contents/Library/SystemExtensions"
fi
if [[ -d "$APP_PATH/Contents/Frameworks" ]]; then
  "$SCRIPTS_DIR/remove-sparkle-sandbox-xpc-services.sh" "$APP_PATH"
fi

cat > "$work/empty.entitlements" <<'ENT'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict/>
</plist>
ENT

# Every Mach-O file in the bundle (thin, or universal with a plausible slice
# count so a Java class file is not mistaken for one), bundle-relative.
python3 -I - "$APP_PATH" > "$work/machos" <<'PY'
import os
import struct
import sys

root = sys.argv[1]
thin = {b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xce"}
fat = {b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf"}
found = []
for directory, dirs, files in os.walk(root):
    dirs.sort()
    for name in sorted(files):
        path = os.path.join(directory, name)
        if os.path.islink(path) or not os.path.isfile(path):
            continue
        with open(path, "rb") as handle:
            head = handle.read(8)
        if head[:4] in thin or (
            head[:4] in fat and len(head) == 8 and 0 < struct.unpack(">I", head[4:])[0] < 20
        ):
            found.append(os.path.relpath(path, root))
sys.stdout.write("".join(rel + "\0" for rel in found))
PY
mapfile -d '' -t machos < "$work/machos"
declare -A is_macho=()
for rel in "${machos[@]}"; do
  # A path-scoped option is <path>:<value>, and rcodesign reads <path>@<n> as
  # a slice index.
  if [[ "$rel" == *[:@]* ]]; then
    echo "error: rcodesign cannot scope settings to $rel (':' or '@' in the path)" >&2
    exit 1
  fi
  is_macho["$rel"]=1
done

plist_value() { # <plist> <key>
  python3 -I -c 'import plistlib, sys; print(plistlib.load(open(sys.argv[1], "rb"))[sys.argv[2]])' "$1" "$2"
}
main_exe="Contents/MacOS/$(plist_value "$APP_PATH/Contents/Info.plist" CFBundleExecutable)"
if [[ -z "${is_macho[$main_exe]:-}" ]]; then
  echo "error: the main executable $main_exe is not a Mach-O file" >&2
  exit 1
fi

declare -A ent=()

# 1. CLI and private helpers.
for helper_dir in bin libexec; do
  for helper in "$APP_PATH/Contents/Resources/$helper_dir"/*; do
    [[ -f "$helper" && -x "$helper" && ! -L "$helper" ]] || continue
    rel="Contents/Resources/$helper_dir/${helper##*/}"
    if [[ -z "${is_macho[$rel]:-}" ]]; then
      echo "==> leaving non-Mach-O helper ${helper##*/} to the bundle seal"
      continue
    fi
    echo "==> helper ${helper##*/}: helper entitlements"
    ent["$rel"]="$HELPER_ENTITLEMENTS"
  done
done

# The cmux-tui SSH payloads, signed first and re-pinned in their manifest.
exclude_args=()
ssh_dir="$APP_PATH/Contents/Resources/bin/cmux-tui-ssh"
if [[ -d "$ssh_dir" ]]; then
  if [[ ! -f "$ssh_dir/manifest.json" ]]; then
    echo "error: $ssh_dir has payloads but no manifest.json" >&2
    exit 1
  fi
  signed=()
  for payload in "$ssh_dir"/*; do
    [[ -f "$payload" && ! -L "$payload" ]] || continue
    name="${payload##*/}"
    [[ "$name" != manifest.json && -n "${is_macho[Contents/Resources/bin/cmux-tui-ssh/$name]:-}" ]] || continue
    echo "==> signing cmux-tui SSH payload $name"
    "$R" sign "${identity_args[@]}" --code-signature-flags runtime \
      --entitlements-xml-file "$HELPER_ENTITLEMENTS" "$payload" > "$work/payload.log" 2>&1 || {
        tail -20 "$work/payload.log" >&2
        exit 1
      }
    signed+=("$name")
  done
  python3 -I - "$ssh_dir/manifest.json" ${signed[@]+"${signed[@]}"} <<'PY'
import hashlib
import json
import os
import sys

manifest_path, signed = sys.argv[1], set(sys.argv[2:])
directory = os.path.dirname(manifest_path)
with open(manifest_path, encoding="utf-8") as handle:
    manifest = json.load(handle)
binaries = manifest.get("binaries")
if not isinstance(binaries, dict):
    sys.exit(f"error: {manifest_path} has no binaries map")

def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 16), b""):
            digest.update(chunk)
    return digest.hexdigest()

for name in sorted(os.listdir(directory)):
    path = os.path.join(directory, name)
    if name == "manifest.json" or os.path.islink(path) or not os.path.isfile(path):
        continue
    if name not in binaries:
        sys.exit(f"error: {manifest_path} has no checksum for payload {name}")
    actual = sha256(path)
    if name in signed:
        binaries[name] = actual
    elif binaries[name].lower() != actual:
        sys.exit(f"error: payload {name} does not match its manifest checksum")

tmp = manifest_path + ".tmp"
with open(tmp, "w", encoding="utf-8") as handle:
    json.dump(manifest, handle, indent=2)
    handle.write("\n")
os.replace(tmp, manifest_path)
PY
  chmod 644 "$ssh_dir/manifest.json"
  exclude_args+=(--exclude 'Contents/Resources/bin/cmux-tui-ssh/**')
  echo "==> re-pinned ${#signed[@]} signed cmux-tui SSH payload(s) in manifest.json"
fi

# 2. The Computer Use helper app: its executable gets the helper entitlements.
computer_use="$APP_PATH/Contents/Library/cmux Computer Use.app"
if [[ -d "$computer_use" ]]; then
  rel="Contents/Library/cmux Computer Use.app/Contents/MacOS/$(plist_value "$computer_use/Contents/Info.plist" CFBundleExecutable)"
  if [[ -z "${is_macho[$rel]:-}" ]]; then
    echo "error: the Computer Use helper executable $rel is not a Mach-O file" >&2
    exit 1
  fi
  echo "==> nested helper ${computer_use##*/}: helper entitlements"
  ent["$rel"]="$HELPER_ENTITLEMENTS"
fi

# 3 and 4. PlugIns and Frameworks: codesign --deep with no entitlements, so any
# entitlements an earlier signature carries are cleared.
for rel in "${machos[@]}"; do
  case "$rel" in
    Contents/PlugIns/* | Contents/Frameworks/*) ;;
    *) continue ;;
  esac
  # Captured first: grep -q on a pipe can fail the pipeline under pipefail.
  info="$("$R" print-signature-info --config-file /dev/null "$APP_PATH/$rel" 2>/dev/null || true)"
  if grep -q '^ *entitlements_plist:' <<<"$info"; then
    echo "==> clearing inherited entitlements of $rel"
    ent["$rel"]="$work/empty.entitlements"
  fi
done

# SwiftPM resource bundles (no code): codesign seals their files as resources
# of the app, while rcodesign would sign each one as a nested bundle. Excluded
# bundles are still sealed.
for bundle in "$APP_PATH/Contents/Resources/"*.bundle; do
  if [[ -d "$bundle" && ! -e "$bundle/Contents/MacOS" ]]; then
    exclude_args+=(--exclude "Contents/Resources/${bundle##*/}")
  fi
done

# 5. The main executable takes the unscoped entitlements; every other setting
# is scoped to its path. Hardened runtime on every Mach-O.
args=(--entitlements-xml-file "$work/app.entitlements" --code-signature-flags runtime)
for rel in "${!ent[@]}"; do
  args+=(--entitlements-xml-file "$rel:${ent[$rel]}")
done
for rel in "${machos[@]}"; do
  [[ "$rel" == Contents/Resources/bin/cmux-tui-ssh/* ]] && continue
  args+=(--code-signature-flags "$rel:runtime")
done
args+=(${exclude_args[@]+"${exclude_args[@]}"})

echo "==> rcodesign sign ${APP_PATH##*/}: ${#machos[@]} Mach-O files, ${#ent[@]} with scoped entitlements"
"$R" sign "${identity_args[@]}" "${args[@]}" "$APP_PATH" > "$work/sign.log" 2>&1 || {
  tail -40 "$work/sign.log" >&2
  echo "error: rcodesign sign failed" >&2
  exit 1
}

bad=0
for rel in "${machos[@]}"; do
  if ! "$R" verify --config-file /dev/null "$APP_PATH/$rel" > "$work/verify.log" 2>&1; then
    bad=$((bad + 1))
    echo "error: rcodesign verify failed for $rel" >&2
    tail -5 "$work/verify.log" >&2
  fi
done
echo "==> rcodesign verify: $(( ${#machos[@]} - bad ))/${#machos[@]} Mach-O files OK"
if (( bad > 0 )); then
  exit 1
fi
echo "==> signing OK: $APP_PATH"
