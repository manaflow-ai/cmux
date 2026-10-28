#!/usr/bin/env bash
# Signs the Chromium engine embedded by embed-cef.sh, inside out:
#
#   Contents/Frameworks/Chromium Embedded Framework.framework/Versions/A/Libraries/*.dylib
#   Contents/Frameworks/Chromium Embedded Framework.framework
#   Contents/Frameworks/libcmux_cef_shim.dylib
#   Contents/Frameworks/libcmux_cef_shim_remote.dylib      (with the host)
#   Contents/Frameworks/<product> Helper{, (GPU), (Renderer), (Plugin), (Alerts)}.app
#   Contents/MacOS/<product> Chromium Host            (Chromium's browser process)
#
# The GPU and Renderer helpers get com.apple.security.cs.allow-jit (V8 and
# the GPU process need it under the hardened runtime); the others get no
# entitlements. One owner for these rules: embed-cef.sh calls this for dev
# builds (ad hoc), scripts/sign-cmux-bundle.sh for Developer ID release
# signing, before the main bundle is signed.
#
# The host is the app's browser process, as Chrome's main executable is
# (chrome/installer/mac/signing/parts.py: the app part keeps the base bundle
# id; only helpers get suffixed ids). It runs with the app's bundle and
# Info.plist (plans/cmux-next/cef-helper-app-DESIGN.md 3.1), so it is signed
# with the app's bundle id as its identifier: its designated requirement is
# then the app's, which the "Chromium Safe Storage" keychain ACL, TCC and the
# host adoption socket (task 150) match.
# Its entitlements are the browser-process subset of the app's, as Chrome's
# browser process gets chrome/app/app-entitlements.plist: the application and
# team identifiers, keychain-access-groups (Chromium's Touch ID passkeys keep
# their credentials in a data-protection keychain group),
# web-browser.public-key-credential (the platform passkey API checks the
# calling process), and the device.* and personal-information.* keys the
# hardened runtime checks per process. No code-signing relaxation: the browser
# process does not JIT (Renderer and GPU keep allow-jit) and loads only code of
# the app's team. The host has the app's identifier, so the app's embedded
# provisioning profile covers its restricted keys.
#
# Usage: sign-cef.sh <app> <identity> [<app entitlements>]
#   identity "-" signs ad hoc without the hardened runtime. Without the app's
#   entitlements file (dev builds, embed-cef.sh) the host gets none.
#        sign-cef.sh --verify-host <app>
#   checks a release-signed host after the app is signed (sign-cmux-bundle.sh):
#   valid, hardened runtime, the app's identifier and team, and exactly the
#   browser-process subset of the app's signed entitlements (so never allow-jit
#   or another com.apple.security.cs.* key). Exits 0 when the app carries no host.
# Env: CMUX_TIMESTAMP=none skips the secure timestamp for a real identity.
# Signing does nothing and exits 0 when the app embeds no CEF framework.
set -euo pipefail

# The app's CFBundleIdentifier, or nothing when it has no Info.plist yet.
app_bundle_id() { # <app>
  local plist="$1/Contents/Info.plist"
  [[ -f "$plist" ]] || return 0
  /usr/bin/python3 -c 'import plistlib, sys; print(plistlib.load(open(sys.argv[1], "rb")).get("CFBundleIdentifier", ""))' "$plist"
}

# `codesign -d --verbose=2` fields of <path>, one "key=value" per line:
# identifier, team and flags (the CodeDirectory flag names, comma separated).
signature_fields() { # <path>
  codesign -d --verbose=2 "$1" 2>&1 | sed -n \
    -e 's/^Identifier=\(.*\)$/identifier=\1/p' \
    -e 's/^TeamIdentifier=\(.*\)$/team=\1/p' \
    -e 's/^CodeDirectory .* flags=0x[0-9a-fA-F]*(\([^)]*\)).*$/flags=\1/p'
}
field() { # <fields> <key>
  sed -n "s/^$2=//p" <<<"$1" | head -n 1
}

# The entitlements <path> is signed with, as an XML plist (empty when none).
signed_entitlements() { # <path>
  codesign -d --entitlements :- "$1" 2>/dev/null || true
}

# The browser-process entitlements (see the top): one rule for signing and
# verifying. `derive <app plist> <out>` writes the subset of the app's
# entitlements the host gets, and exits 3 when that subset is empty.
# `check <app plist> <host plist>` exits 1, naming each key, unless the host
# carries exactly that subset of the app's signed entitlements.
browser_entitlements() { # derive|check <plist> <plist>
  /usr/bin/python3 -I - "$@" <<'PY'
import plistlib, sys

KEEP = {
    "com.apple.application-identifier",
    "com.apple.developer.team-identifier",
    "keychain-access-groups",
    "com.apple.developer.web-browser.public-key-credential",
}
KEEP_PREFIXES = ("com.apple.security.device.", "com.apple.security.personal-information.")
RELAXATION_PREFIXES = ("com.apple.security.cs.", "com.apple.security.get-task-allow")


def load(path):
    with open(path, "rb") as f:
        data = f.read()
    return plistlib.loads(data) if data.strip() else {}


def browser_set(entitlements):
    return {k: v for k, v in entitlements.items() if k in KEEP or k.startswith(KEEP_PREFIXES)}


mode, app_path, other = sys.argv[1:4]
want = browser_set(load(app_path))
if mode == "derive":
    if not want:
        sys.exit(3)
    with open(other, "wb") as f:
        plistlib.dump(want, f)
    sys.exit(0)

host = load(other)
errors = [f"carries the code-signing relaxation {k}" for k in sorted(host) if k.startswith(RELAXATION_PREFIXES)]
errors += [f"lacks the app's {k}" for k in sorted(want) if k not in host]
errors += [f"has {k}={host[k]!r}, the app has {want[k]!r}" for k in sorted(want) if k in host and host[k] != want[k]]
errors += [
    f"carries {k}, which is not in the app's browser-process set"
    for k in sorted(host)
    if k not in want and not k.startswith(RELAXATION_PREFIXES)
]
for error in errors:
    print(f"error: the Chromium host {error}", file=sys.stderr)
sys.exit(1 if errors else 0)
PY
}

verify_host() { # <app>
  local app="$1" host_binary found=0 want_id want_team host_fields id team scratch
  want_id="$(app_bundle_id "$app")"
  [[ -n "$want_id" ]] || { echo "error: $app has no CFBundleIdentifier" >&2; return 1; }
  want_team="$(field "$(signature_fields "$app")" team)"
  scratch="$(mktemp -d "${TMPDIR:-/tmp}/cmux-cef-verify-host.XXXXXX")"
  verify_scratch="$scratch"
  trap 'rm -rf "$verify_scratch"' EXIT
  signed_entitlements "$app" > "$scratch/app.plist"
  for host_binary in "$app/Contents/MacOS/"*" Chromium Host"; do
    [[ -f "$host_binary" ]] || continue
    found=1
    codesign --verify --strict --verbose=2 "$host_binary" ||
      { echo "error: the Chromium host's signature does not verify: $host_binary" >&2; return 1; }
    host_fields="$(signature_fields "$host_binary")"
    id="$(field "$host_fields" identifier)"
    team="$(field "$host_fields" team)"
    [[ ",$(field "$host_fields" flags)," == *",runtime,"* ]] ||
      { echo "error: the Chromium host is not signed with the hardened runtime: $host_binary" >&2; return 1; }
    [[ "$id" == "$want_id" ]] ||
      { echo "error: the Chromium host's identifier is '$id', not the app's '$want_id'" >&2; return 1; }
    [[ -n "$team" && "$team" != "not set" && "$team" == "$want_team" ]] ||
      { echo "error: the Chromium host's team '$team' is not the app's '$want_team'" >&2; return 1; }
    signed_entitlements "$host_binary" > "$scratch/host.plist"
    browser_entitlements check "$scratch/app.plist" "$scratch/host.plist" ||
      { echo "error: the Chromium host's entitlements are not the app's browser-process set: $host_binary" >&2; return 1; }
    echo "==> Chromium host signed as nested code: $(basename "$host_binary") ($id, team $team, hardened runtime, browser-process entitlements)"
  done
  (( found )) || echo "note: $app carries no Chromium host"
  return 0
}

if [[ "${1:-}" == "--verify-host" ]]; then
  verify_host "${2:?usage: sign-cef.sh --verify-host <app>}"
  exit 0
fi

app="${1:?usage: sign-cef.sh <app> <identity>}"
identity="${2:?usage: sign-cef.sh <app> <identity> [<app entitlements>]}"
app_entitlements="${3:-}"
frameworks="$app/Contents/Frameworks"
framework="$frameworks/Chromium Embedded Framework.framework"
[[ -d "$framework" ]] || exit 0

flags=(--force --sign "$identity")
if [[ "$identity" != "-" ]]; then
  flags+=(--options runtime)
  if [[ "${CMUX_TIMESTAMP:-}" == "none" ]]; then
    flags+=(--timestamp=none)
  else
    flags+=(--timestamp)
  fi
fi

jit="$(mktemp "${TMPDIR:-/tmp}/cmux-cef-helper-jit.XXXXXX")"
host_entitlements="$(mktemp "${TMPDIR:-/tmp}/cmux-cef-host-entitlements.XXXXXX")"
trap 'rm -f "$jit" "$host_entitlements"' EXIT
cat > "$jit" <<'ENT'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.cs.allow-jit</key><true/>
</dict>
</plist>
ENT

for lib in "$framework/Versions/A/Libraries/"*.dylib; do
  [[ -f "$lib" ]] && codesign "${flags[@]}" "$lib"
done
codesign "${flags[@]}" "$framework"
for shim in "$frameworks/libcmux_cef_shim.dylib" "$frameworks/libcmux_cef_shim_remote.dylib"; do
  if [[ -f "$shim" ]]; then codesign "${flags[@]}" "$shim"; fi
done
for helper in "$frameworks"/*" Helper.app" "$frameworks"/*" Helper ("*").app"; do
  [[ -d "$helper" ]] || continue
  case "$helper" in
    *" Helper (GPU).app"|*" Helper (Renderer).app")
      codesign "${flags[@]}" --entitlements "$jit" "$helper" ;;
    *)
      codesign "${flags[@]}" "$helper" ;;
  esac
done
# The Chromium host (embed-cef.sh): Chromium's browser process, as the app
# itself is when it runs Chromium in process; a second executable in
# Contents/MacOS, signed last here and before the main bundle, as nested code
# must be, with the app's identifier and browser-process entitlements (see the
# top). A bundle whose host did not build has none: the glob stays literal, and
# the `if` keeps that miss from becoming the script's exit status (a bare
# `[[ ]] &&` as the loop's last command made sign-cef.sh exit 1 and failed
# Embed CEF).
# Xcode's Embed CEF phase may run before it writes Info.plist; its build
# setting names the same id.
bundle_id="$(app_bundle_id "$app")"
[[ -n "$bundle_id" ]] || bundle_id="${PRODUCT_BUNDLE_IDENTIFIER:-}"
host_flags=("${flags[@]}")
if [[ -n "$app_entitlements" ]]; then
  [[ -f "$app_entitlements" ]] || { echo "error: app entitlements not found at $app_entitlements" >&2; exit 1; }
  derive_status=0
  browser_entitlements derive "$app_entitlements" "$host_entitlements" || derive_status=$?
  case "$derive_status" in
    0) host_flags+=(--entitlements "$host_entitlements") ;;
    3) ;; # the app has no key the browser process keeps
    *) echo "error: cannot read the app entitlements $app_entitlements" >&2; exit 1 ;;
  esac
fi
for host_binary in "$app/Contents/MacOS/"*" Chromium Host"; do
  [[ -f "$host_binary" ]] || continue
  if [[ -n "$bundle_id" ]]; then
    codesign "${host_flags[@]}" --identifier "$bundle_id" "$host_binary"
  elif [[ "$identity" == "-" ]]; then
    codesign "${host_flags[@]}" "$host_binary"  # ad hoc outside Xcode, with no id to give
  else
    echo "error: $app has no CFBundleIdentifier for the Chromium host's signature" >&2
    exit 1
  fi
done
