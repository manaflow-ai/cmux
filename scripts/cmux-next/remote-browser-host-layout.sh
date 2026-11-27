# Sourced, not run. The one owner of the cmux-remote-browser-host app bundle
# layout, used by bundle-remote-browser-host.sh (a standalone host app with its
# own CEF copy) and embed-remote-browser-host.sh (the host embedded in a DEV
# cmux-next app, sharing the app's CEF framework):
#
#   <host>.app/Contents/MacOS/cmux-remote-browser-host
#   <host>.app/Contents/Frameworks/cmux-remote-browser-host Helper{, (GPU), (Renderer), (Plugin), (Alerts)}.app
#   <host>.app/Contents/Frameworks/Chromium Embedded Framework.framework   (the caller adds it)
#
# CEF looks for "<exe> Helper.app" and its variants beside its framework. The
# helpers run a small subprocess binary when the caller has one
# (cmux-rb-host-helper from build-cef-shim.sh, about 0.6 MB instead of the
# 3.6 MB host, cmux#42190); otherwise the host binary is its own helper
# (rb_shim_run runs CefExecuteProcess for --type=). Both do the same for a
# subprocess. Works under Xcode's /bin/bash 3.2.

RBH_NAME=cmux-remote-browser-host
RBH_BUNDLE_ID=com.manaflow.cmux-remote-browser-host
RBH_HELPER_SUFFIXES=("" " (GPU)" " (Renderer)" " (Plugin)" " (Alerts)")

rbh_plist() { # <path> <executable> <bundle id> [principal class]
  local principal=""
  [[ -n "${4:-}" ]] && principal="
  <key>NSPrincipalClass</key><string>$4</string>"
  cat >"$1" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>$2</string>
  <key>CFBundleIdentifier</key><string>$3</string>
  <key>CFBundleName</key><string>$2</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSUIElement</key><true/>$principal
</dict></plist>
PLIST
}

# Writes the host executable, its Info.plist and the five helper apps into a
# new (absent) <app>. The helpers run <helper binary> when given, else a copy
# of the host binary. Signs nothing.
rbh_write_bundle() { # <binary> <app> [helper binary]
  local bin="$1" app="$2" helper_bin="${3:-}" suffix helper_name helper id_suffix principal
  # The host binary as its own helper keeps its NSApplication subclass in the
  # plist, as before; the small helper has none (like the app's own helpers),
  # and CefExecuteProcess never reads it.
  principal=""
  if [[ -z "$helper_bin" ]]; then
    helper_bin="$bin"
    principal=RbShimApplication
  fi
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Frameworks"
  cp "$bin" "$app/Contents/MacOS/$RBH_NAME"
  chmod 755 "$app/Contents/MacOS/$RBH_NAME"
  rbh_plist "$app/Contents/Info.plist" "$RBH_NAME" "$RBH_BUNDLE_ID" RbShimApplication
  for suffix in "${RBH_HELPER_SUFFIXES[@]}"; do
    helper_name="$RBH_NAME Helper$suffix"
    helper="$app/Contents/Frameworks/$helper_name.app"
    mkdir -p "$helper/Contents/MacOS"
    cp "$helper_bin" "$helper/Contents/MacOS/$helper_name"
    chmod 755 "$helper/Contents/MacOS/$helper_name"
    id_suffix="$(printf %s "$suffix" | tr -d ' ()' | tr '[:upper:]' '[:lower:]')"
    rbh_plist "$helper/Contents/Info.plist" "$helper_name" "$RBH_BUNDLE_ID.helper${id_suffix:+.$id_suffix}" "$principal"
  done
}

# Signs the helper apps, then <app>, with <identity> by the rules of
# sign-cef.sh: "-" signs ad hoc without the hardened runtime; a real identity
# adds the hardened runtime and a secure timestamp (CMUX_TIMESTAMP=none skips
# it), and the plain, GPU and Renderer helpers get com.apple.security.cs.allow-jit
# (the plain one also disable-library-validation, for the Widevine CDM).
# The CEF framework inside <app> is signed by its owner first (a copy by the
# caller, the embedded app's own framework by sign-cef.sh).
rbh_sign() { # <app> <identity>
  local app="$1" identity="$2" flags jit cdm helper sign_tool
  # codesign-retry.sh: Apple's timestamp service fails for a moment now and then.
  sign_tool="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/codesign-retry.sh"
  flags=(--force --sign "$identity")
  if [[ "$identity" != "-" ]]; then
    flags+=(--options runtime)
    if [[ "${CMUX_TIMESTAMP:-}" == "none" ]]; then flags+=(--timestamp=none); else flags+=(--timestamp); fi
  fi
  jit="$(mktemp "${TMPDIR:-/tmp}/cmux-rbh-jit.XXXXXX")"
  cat >"$jit" <<'ENT'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.cs.allow-jit</key><true/>
</dict>
</plist>
ENT
  # The plain helper runs the Widevine CDM, which Google's team signs (sign-cef.sh).
  cdm="$(mktemp "${TMPDIR:-/tmp}/cmux-rbh-cdm.XXXXXX")"
  cat >"$cdm" <<'ENT'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.cs.allow-jit</key><true/>
  <key>com.apple.security.cs.disable-library-validation</key><true/>
</dict>
</plist>
ENT
  for helper in "$app/Contents/Frameworks/$RBH_NAME Helper"*.app; do
    [[ -d "$helper" ]] || continue
    case "$helper" in
      *" Helper.app")
        "$sign_tool" "${flags[@]}" --entitlements "$cdm" "$helper" || { rm -f "$jit" "$cdm"; return 1; } ;;
      *" Helper (GPU).app"|*" Helper (Renderer).app")
        "$sign_tool" "${flags[@]}" --entitlements "$jit" "$helper" || { rm -f "$jit" "$cdm"; return 1; } ;;
      *)
        "$sign_tool" "${flags[@]}" "$helper" || { rm -f "$jit" "$cdm"; return 1; } ;;
    esac
  done
  rm -f "$jit" "$cdm"
  "$sign_tool" "${flags[@]}" "$app"
}
