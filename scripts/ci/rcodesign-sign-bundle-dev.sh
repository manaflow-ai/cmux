#!/usr/bin/env bash
# Developer ID sign a cmux NEXT DEV .app on Linux with our rcodesign.
#
#   scripts/ci/rcodesign-sign-bundle-dev.sh <app-path> <app-entitlements>
#
# The DEV app is a feat-cmux-next build, so this follows feat-cmux-next's
# scripts/sign-cmux-bundle.sh step by step, with rcodesign (0.29.0 and our
# patch, scripts/ci/build-rcodesign.sh) in place of /usr/bin/codesign. The job checks
# out main, where the feat-cmux-next helpers it calls do not exist, so the rules
# they own are written out here, each naming the feat-cmux-next file it mirrors.
#
# Env: APPLE_CERTIFICATE_BASE64 and APPLE_CERTIFICATE_PASSWORD (the PKCS#12),
# APPLE_SIGNING_IDENTITY (optional: the certificate must match it as codesign
# matches an identity), RCODESIGN (default rcodesign), CMUX_HELPER_ENTITLEMENTS,
# CMUX_TIMESTAMP=none (no time stamp, no notarization checks: test certificates).
# The key exists only in a mktemp -d directory (umask 077) that the EXIT trap
# removes, and is never on a command line: openssl reads the PKCS#12 on stdin
# and the password from the environment, and rcodesign reads the PEM by path.
#
# rcodesign signs the bundle in one pass, nested code first, so each component's
# codesign arguments become path-scoped options. Every Mach-O gets the hardened
# runtime, and --for-notarization requires Apple's time stamp server. rcodesign
# keeps the entitlements of an earlier signature where codesign --force drops
# them, so a component codesign signs without entitlements gets an empty set
# when its current signature has some. Code codesign leaves alone (other
# executables in Contents/MacOS, nested code in a helper app) is re-signed too,
# keeping its entitlements.
#
# Not run here: the keychain unlock (no keychain), CMUX_SIGN_MODE other than
# "all" and CMUX_NEXT_CEF_ON_DEMAND (the DEV job uses neither; both are refused),
# and the checks that need a Mac or run bundle code: codesign --verify --deep
# --strict, the diff sidecar and bundled browser host checks, and codesign -d on
# the result. The workflow's Mac verify job runs those on this output. The
# entitlement checks are made on the files that go into the signature instead.
#
# The output matches codesign's except inside each CMS blob (the signing time,
# time stamp and signature, which differ between any two runs), and so in the
# hashes of signed files sealed as plain files (Contents/Resources/bin).
set -euo pipefail
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

[[ $# -eq 2 ]] || { echo "usage: $0 <app-path> <app-entitlements>" >&2; exit 2; }
APP_PATH="${1%/}"
HELPER_ENTITLEMENTS="${CMUX_HELPER_ENTITLEMENTS:-cmux-helper.entitlements}"
R="${RCODESIGN:-rcodesign}"
# rcodesign reads every RCODESIGN_* environment variable as its own config
# (apple-codesign 0.29: Env::prefixed("RCODESIGN_")), so one the job or the
# runner image sets would fail every call. Scrub them before any call.
while IFS= read -r name; do unset "$name"; done < <(compgen -e | grep '^RCODESIGN_' || true)
[[ -d "$APP_PATH/Contents" ]] || { echo "error: app bundle not found at $APP_PATH" >&2; exit 1; }
[[ -f "$2" && -f "$HELPER_ENTITLEMENTS" ]] || { echo "error: entitlements file missing" >&2; exit 1; }
[[ "${CMUX_SIGN_MODE:-all}" == all && -z "${CMUX_NEXT_CEF_ON_DEMAND:-}" ]] ||
  { echo "error: CMUX_SIGN_MODE and CMUX_NEXT_CEF_ON_DEMAND are not supported here" >&2; exit 2; }
command -v "$R" >/dev/null || { echo "error: rcodesign not found ($R)" >&2; exit 1; }
: "${APPLE_CERTIFICATE_BASE64:?}" "${APPLE_CERTIFICATE_PASSWORD:?}"
export APPLE_CERTIFICATE_PASSWORD
APP_ENTITLEMENTS="$(realpath "$2")"
HELPER_ENTITLEMENTS="$(realpath "$HELPER_ENTITLEMENTS")"

secrets="" work=""
trap 'rm -rf ${secrets:+"$secrets"} ${work:+"$work"}' EXIT
trap 'exit 129' HUP; trap 'exit 130' INT; trap 'exit 143' TERM
secrets="$(umask 077 && mktemp -d "${TMPDIR:-/tmp}/cmux-rcodesign-key.XXXXXX")"
work="$(mktemp -d "${TMPDIR:-/tmp}/cmux-rcodesign-work.XXXXXX")"

# rcodesign 0.29 cannot read the PBES2 PKCS#12 a keychain exports; openssl
# converts it to one PEM with the certificate and the key.
(umask 077 && printf '%s' "$APPLE_CERTIFICATE_BASE64" | base64 -d > "$secrets/identity.p12") 2>/dev/null ||
  { echo "error: APPLE_CERTIFICATE_BASE64 is not valid base64" >&2; exit 1; }
pkcs12_to_pem() {
  (umask 077 && openssl pkcs12 "$@" -passin env:APPLE_CERTIFICATE_PASSWORD -nodes -clcerts \
    < "$secrets/identity.p12" > "$secrets/identity.pem" 2>/dev/null)
}
pkcs12_to_pem || pkcs12_to_pem -legacy || { echo "error: openssl could not open the PKCS#12 (wrong password?)" >&2; exit 1; }
rm -f "$secrets/identity.p12"
# Only openssl needed these; no later child (rcodesign, python3) inherits them.
unset APPLE_CERTIFICATE_PASSWORD APPLE_CERTIFICATE_BASE64
[[ "$(grep -c -- '-----BEGIN .*PRIVATE KEY-----' < "$secrets/identity.pem" || true)" == 1 ]] ||
  { echo "error: the PKCS#12 must hold exactly one private key" >&2; exit 1; }
subject="$(openssl x509 -noout -subject -nameopt multiline,utf8,-esc_msb < "$secrets/identity.pem")"
cn="$(awk '/^ *commonName *=/ { sub(/^ *commonName *= */, ""); print; exit }' <<<"$subject")"
identity_args=(--config-file /dev/null --pem-file "$secrets/identity.pem" --for-notarization)
if [[ "${CMUX_TIMESTAMP:-}" == none ]]; then
  identity_args[4]=--timestamp-url; identity_args+=(none)
elif [[ "$cn" != "Developer ID Application:"* ]]; then
  echo "error: the certificate ($cn) is not a Developer ID Application certificate" >&2; exit 1
fi
want="${APPLE_SIGNING_IDENTITY:-}"
if [[ "$want" =~ ^[0-9A-Fa-f]{40}$ ]]; then
  fp="$(openssl x509 -noout -fingerprint -sha1 < "$secrets/identity.pem")"; fp="${fp#*=}"
  [[ "${fp//:/}" == "${want^^}" || "${fp//:/}" == "${want,,}" ]] || { echo "error: the certificate ($cn) is not the SHA-1 APPLE_SIGNING_IDENTITY names" >&2; exit 1; }
elif [[ "$cn" != *"$want"* ]]; then
  echo "error: the certificate ($cn) does not match APPLE_SIGNING_IDENTITY" >&2; exit 1
fi
echo "==> signing as $cn"

find "$APP_PATH" -name '._*' -type f -delete   # AppleDouble files from an unzip
plist_get() { python3 -I -c 'import plistlib,sys; print(plistlib.load(open(sys.argv[1],"rb"))[sys.argv[2]])' "$@"; }
jit="$work/jit.entitlements" empty="$work/empty.entitlements"
printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
  '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
  '<plist version="1.0">' '<dict>' '  <key>com.apple.security.cs.allow-jit</key><true/>' '</dict>' '</plist>' > "$jit"
sed '/<key>/d' "$jit" > "$empty"

# Effective app entitlements (sign-cmux-bundle.sh:109-133). openssl unwraps the
# profile where the Mac uses security cms -D. cmux-next ships no tunnel.
profile=(--no-profile)
if [[ -f "$APP_PATH/Contents/embedded.provisionprofile" ]]; then
  openssl cms -verify -noverify -inform DER -in "$APP_PATH/Contents/embedded.provisionprofile" -out "$work/profile.plist" 2>/dev/null
  profile=(--profile "$work/profile.plist")
fi
python3 "$SCRIPTS_DIR/reconcile-entitlements-with-profile.py" --entitlements "$APP_ENTITLEMENTS" \
  "${profile[@]}" --output "$work/app.entitlements" --json > "$work/reconcile.json"
if grep -q '"tunnel_requested": true' "$work/reconcile.json" || [[ -d "$APP_PATH/Contents/Library/SystemExtensions" ]]; then
  echo "error: cmux-next ships no Cloud tunnel system extension; remove it and its entitlements" >&2; exit 1
fi
# The checks sign-cmux-bundle.sh:232-305 make with codesign -d, made on the inputs.
python3 -I - "$APP_ENTITLEMENTS" "$work/app.entitlements" "$HELPER_ENTITLEMENTS" <<'PY'
import plistlib, sys
want, app, helper = (plistlib.load(open(p, "rb")) for p in sys.argv[1:])
for key in ("com.apple.application-identifier", "com.apple.developer.web-browser.public-key-credential"):
    if key in want and app.get(key) != want[key]:
        sys.exit(f"error: effective app entitlements lack {key}")
for kind in ("addressbook", "calendars", "location", "photos-library"):
    if app.get(f"com.apple.security.personal-information.{kind}") is not True:
        sys.exit(f"error: app entitlements lack enabled personal-information.{kind}")
if any("networkextension" in key for key in app) or any("application-identifier" in key for key in helper):
    sys.exit("error: NetworkExtension in the app, or application-identifier in the helper entitlements")
PY
for alias in cmux-tui acpmux; do   # sign-cmux-bundle.sh:204-211
  link="$APP_PATH/Contents/Resources/bin/$alias"
  if [[ -e "$link" || -L "$link" ]] && [[ "$(readlink "$link" || true)" != cmux ]]; then
    echo "error: bin/$alias is not a symlink to cmux" >&2; exit 1
  fi
done

# 0. Stamp the cmux server launchd plists from the final bundle id, before the
# app signature seals them. Mirrors stamp() of feat-cmux-next
# scripts/cmux-next/bundle-server-helper.sh (blob eed69f81), with plistlib for
# plutil; both write sorted keys.
python3 -I - "$APP_PATH" <<'PY'
import os, plistlib, re, sys
contents = os.path.join(sys.argv[1], "Contents")
bundle_id = plistlib.load(open(os.path.join(contents, "Info.plist"), "rb"))["CFBundleIdentifier"]
drop = bundle_id == "com.cmuxterm.app"
if not drop and not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]", bundle_id, re.ASCII):
    sys.exit(f"error: bundle id {bundle_id!r} is not a plain reverse-DNS name")
def stamp(kind, name, program, present, label, args, extra):
    plist = os.path.join(contents, "Library", kind, name)
    if drop or not present:
        if kind == "LaunchDaemons" and os.path.lexists(os.path.join(contents, program[9:])):
            os.remove(os.path.join(contents, program[9:]))
        if os.path.exists(plist):
            os.remove(plist)
        try:
            os.rmdir(os.path.dirname(plist))
        except OSError:
            pass
        return
    os.makedirs(os.path.dirname(plist), exist_ok=True)
    job = {"Label": label, "BundleProgram": program, "AssociatedBundleIdentifiers": [bundle_id],
           "ProgramArguments": args, **extra}
    with open(plist, "wb") as handle:
        plistlib.dump(job, handle)
    print(f"==> stamped {kind}/{name}: {label}")
helper = "Contents/Resources/libexec/cmux-server-helper"
stamp("LaunchDaemons", "com.cmux.server.helper.plist", helper,
      os.path.lexists(os.path.join(contents, helper[9:])), f"{bundle_id}.server-helper",
      ["cmux-server-helper", "--app", bundle_id], {"MachServices": {f"{bundle_id}.server-helper": True}})
cli = "Contents/Resources/bin/cmux"
stamp("LaunchAgents", "com.cmux.server.plist", cli, os.path.isfile(os.path.join(contents, cli[9:])),
      f"{bundle_id}.server", [cli, "host", "run", "--mode", "user"],
      {"RunAtLoad": True, "KeepAlive": {"SuccessfulExit": False}, "ThrottleInterval": 10, "ProcessType": "Standard"})
PY
if [[ -d "$APP_PATH/Contents/Frameworks" ]]; then
  "$SCRIPTS_DIR/remove-sparkle-sandbox-xpc-services.sh" "$APP_PATH"
fi

# Every Mach-O (thin, or universal with a plausible slice count, unlike a Java
# class file), bundle-relative.
python3 -I - "$APP_PATH" > "$work/machos" <<'PY'
import os, struct, sys
thin = {b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xce"}
for directory, dirs, files in sorted(os.walk(sys.argv[1])):
    for name in sorted(files):
        path = os.path.join(directory, name)
        if os.path.islink(path) or not os.path.isfile(path):
            continue
        head = open(path, "rb").read(8)
        if head[:4] in thin or (head[:4] in (b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf")
                                and len(head) == 8 and 0 < struct.unpack(">I", head[4:])[0] < 20):
            sys.stdout.write(os.path.relpath(path, sys.argv[1]) + "\0")
PY
mapfile -d '' -t machos < "$work/machos"
declare -A is_macho=() ent=() clear=() ident=()
for rel in "${machos[@]}"; do
  # Scoped options are <path>:<value>, and rcodesign reads <path>@<n> as a slice.
  [[ "$rel" != *[:@]* ]] || { echo "error: rcodesign cannot scope settings to $rel" >&2; exit 1; }
  is_macho["$rel"]=1
done
exe_of() { # <bundle>: sets exe to the bundle-relative path of its Mach-O executable
  local name prefix="${1#"$APP_PATH"}"
  name="$(plist_get "$1/Contents/Info.plist" CFBundleExecutable)" || exit 1
  exe="${prefix#/}${prefix:+/}Contents/MacOS/$name"
  [[ -n "${is_macho[$exe]:-}" ]] || { echo "error: $exe is not a Mach-O file" >&2; exit 1; }
}
exe_of "$APP_PATH"; main_exe="$exe"

# 1. Helpers in Resources/bin and libexec (feat-cmux-next
# scripts/sign-cmux-bundle-helpers.sh, blob fb53f0b0): helper entitlements;
# cmux-server-helper none, identifier cmux-server-helper; symlinks and scripts
# are left to the bundle seal.
for helper in "$APP_PATH/Contents/Resources/"{bin,libexec}/*; do
  rel="${helper#"$APP_PATH/"}"
  [[ ! -L "$helper" && -x "$helper" && -n "${is_macho[$rel]:-}" ]] || continue
  if [[ "$rel" == Contents/Resources/libexec/cmux-server-helper ]]; then
    clear["$rel"]=1; ident["$rel"]=cmux-server-helper
  else
    ent["$rel"]="$HELPER_ENTITLEMENTS"
  fi
done

# The cmux-tui SSH payloads (scripts/sign-cmux-tui-ssh-payloads.sh): signed
# alone, re-pinned in manifest.json, then excluded from the bundle pass.
excludes=()
ssh_dir="$APP_PATH/Contents/Resources/bin/cmux-tui-ssh"
if [[ -d "$ssh_dir" ]]; then
  signed=()
  for payload in "$ssh_dir"/*; do
    [[ ! -L "$payload" && -n "${is_macho[${payload#"$APP_PATH/"}]:-}" ]] || continue
    "$R" sign "${identity_args[@]}" --code-signature-flags runtime \
      --entitlements-xml-file "$HELPER_ENTITLEMENTS" "$payload" > "$work/log" 2>&1 || { tail -20 "$work/log" >&2; exit 1; }
    signed+=("${payload##*/}")
  done
  python3 -I - "$ssh_dir/manifest.json" ${signed[@]+"${signed[@]}"} <<'PY'
import hashlib, json, os, sys
path, signed = sys.argv[1], set(sys.argv[2:])
manifest = json.load(open(path, encoding="utf-8"))
binaries = manifest["binaries"]
for name in sorted(os.listdir(os.path.dirname(path))):
    file = os.path.join(os.path.dirname(path), name)
    if name == "manifest.json" or os.path.islink(file) or not os.path.isfile(file):
        continue
    if name not in binaries:
        sys.exit(f"error: manifest.json has no checksum for payload {name}")
    sha = hashlib.sha256()
    with open(file, "rb") as payload:
        for chunk in iter(lambda: payload.read(64 * 1024), b""):
            sha.update(chunk)
    digest = sha.hexdigest()
    if name in signed:
        binaries[name] = digest
    elif binaries[name].lower() != digest:
        sys.exit(f"error: payload {name} does not match its manifest checksum")
with open(path + ".tmp", "w", encoding="utf-8") as handle:
    json.dump(manifest, handle, indent=2)
    handle.write("\n")
os.replace(path + ".tmp", path)
PY
  chmod 644 "$ssh_dir/manifest.json"
  excludes+=(--exclude 'Contents/Resources/bin/cmux-tui-ssh/**')
  echo "==> signed and re-pinned ${#signed[@]} cmux-tui SSH payload(s)"
fi

# 2. The Computer Use helper app: its executable gets the helper entitlements.
computer_use="$APP_PATH/Contents/Library/cmux Computer Use.app"
if [[ -d "$computer_use" ]]; then exe_of "$computer_use"; ent["$exe"]="$HELPER_ENTITLEMENTS"; fi

# 3. Plugins (--deep, no entitlements).
for rel in "${machos[@]}"; do [[ "$rel" == Contents/PlugIns/* ]] && clear["$rel"]=1; done

# 4. The Chromium engine (feat-cmux-next scripts/cmux-next/sign-cef.sh, blob
# 42525cf0): the framework, its Libraries and the shim get no entitlements;
# of the "<product> Helper*.app" apps, GPU and Renderer get allow-jit.
# The remote browser host in Contents/Helpers (rbh_sign of
# scripts/cmux-next/remote-browser-host-layout.sh, blob 654ee654): its helper
# apps by the same rule, the host app with no entitlements. Then every other
# framework (--deep, no entitlements).
cef_helper() { # <helper.app>
  exe_of "$1"
  case "$1" in
    *" Helper (GPU).app" | *" Helper (Renderer).app") ent["$exe"]="$jit" ;;
    *) clear["$exe"]=1 ;;
  esac
}
frameworks="$APP_PATH/Contents/Frameworks"
if [[ -d "$frameworks/Chromium Embedded Framework.framework" ]]; then
  for helper in "$frameworks"/*" Helper.app" "$frameworks"/*" Helper ("*").app"; do
    if [[ -d "$helper" ]]; then cef_helper "$helper"; fi
  done
fi
for host in "$APP_PATH/Contents/Helpers/"*.app; do
  [[ -d "$host" ]] || continue
  for helper in "$host/Contents/Frameworks/cmux-remote-browser-host Helper"*.app; do
    if [[ -d "$helper" ]]; then cef_helper "$helper"; fi
  done
  exe_of "$host"; clear["$exe"]=1
done
for rel in "${machos[@]}"; do
  [[ "$rel" == Contents/Frameworks/* && -z "${ent[$rel]:-}" ]] && clear["$rel"]=1
done

# A component signed without entitlements gets an empty set only when its
# current signature has some (rcodesign would keep them). A failed probe fails.
for rel in "${!clear[@]}"; do
  info="$("$R" print-signature-info --config-file /dev/null "$APP_PATH/$rel" 2>"$work/log")" ||
    { tail -5 "$work/log" >&2; echo "error: rcodesign print-signature-info failed for $rel" >&2; exit 1; }
  if grep -q '^ *entitlements_plist:' <<<"$info"; then
    echo "==> clearing inherited entitlements of $rel"
    ent["$rel"]="$empty"
  fi
done

# SwiftPM resource bundles hold no code: codesign seals them as resources,
# rcodesign would sign them as nested bundles.
for bundle in "$APP_PATH/Contents/Resources/"*.bundle; do
  [[ -d "$bundle" && ! -e "$bundle/Contents/MacOS" ]] && excludes+=(--exclude "${bundle#"$APP_PATH/"}")
done

# 5. The main app (its executable takes the unscoped options) and, nested
# first, everything above in one pass.
args=(--entitlements-xml-file "$work/app.entitlements" --code-signature-flags runtime)
for rel in "${!ent[@]}"; do args+=(--entitlements-xml-file "$rel:${ent[$rel]}"); done
for rel in "${!ident[@]}"; do args+=(--binary-identifier "$rel:${ident[$rel]}"); done
for rel in "${machos[@]}"; do
  [[ "$rel" == Contents/Resources/bin/cmux-tui-ssh/* ]] || args+=(--code-signature-flags "$rel:runtime")
done
echo "==> rcodesign sign ${APP_PATH##*/}: ${#machos[@]} Mach-O files, ${#ent[@]} with scoped entitlements"
"$R" sign "${identity_args[@]}" "${args[@]}" ${excludes[@]+"${excludes[@]}"} "$APP_PATH" > "$work/log" 2>&1 ||
  { tail -40 "$work/log" >&2; echo "error: rcodesign sign failed" >&2; exit 1; }

bad=0
for rel in "${machos[@]}"; do
  "$R" verify --config-file /dev/null "$APP_PATH/$rel" > "$work/log" 2>&1 ||
    { bad=$((bad + 1)); echo "error: rcodesign verify failed for $rel" >&2; tail -5 "$work/log" >&2; }
done
echo "==> rcodesign verify: $(( ${#machos[@]} - bad ))/${#machos[@]} Mach-O files OK"
(( bad == 0 ))
echo "==> signing OK: $APP_PATH"
