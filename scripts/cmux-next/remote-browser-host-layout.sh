# Sourced, not run. The one owner of the cmux-remote-browser-host app bundle
# layout, used by bundle-remote-browser-host.sh (a standalone host app with its
# own CEF copy) and embed-remote-browser-host.sh (the host embedded in a DEV
# cmux-next app, sharing the app's CEF framework):
#
#   <host>.app/Contents/MacOS/cmux-remote-browser-host
#   <host>.app/Contents/Frameworks/cmux-remote-browser-host Helper{, (GPU), (Renderer), (Plugin), (Alerts)}.app
#   <host>.app/Contents/Frameworks/Chromium Embedded Framework.framework   (the caller adds it)
#
# CEF looks for "<exe> Helper.app" and its variants beside its framework; the
# host binary is its own helper (rb_shim_run runs CefExecuteProcess for
# --type=). Works under Xcode's /bin/bash 3.2.

RBH_NAME=cmux-remote-browser-host
RBH_BUNDLE_ID=com.manaflow.cmux-remote-browser-host
RBH_HELPER_SUFFIXES=("" " (GPU)" " (Renderer)" " (Plugin)" " (Alerts)")

rbh_plist() { # <path> <executable> <bundle id>
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
  <key>LSUIElement</key><true/>
  <key>NSPrincipalClass</key><string>RbShimApplication</string>
</dict></plist>
PLIST
}

# Writes the host executable, its Info.plist and the five helper apps into a
# new (absent) <app>. Signs nothing.
rbh_write_bundle() { # <binary> <app>
  local bin="$1" app="$2" suffix helper_name helper id_suffix
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Frameworks"
  cp "$bin" "$app/Contents/MacOS/$RBH_NAME"
  chmod 755 "$app/Contents/MacOS/$RBH_NAME"
  rbh_plist "$app/Contents/Info.plist" "$RBH_NAME" "$RBH_BUNDLE_ID"
  for suffix in "${RBH_HELPER_SUFFIXES[@]}"; do
    helper_name="$RBH_NAME Helper$suffix"
    helper="$app/Contents/Frameworks/$helper_name.app"
    mkdir -p "$helper/Contents/MacOS"
    cp "$bin" "$helper/Contents/MacOS/$helper_name"
    chmod 755 "$helper/Contents/MacOS/$helper_name"
    id_suffix="$(printf %s "$suffix" | tr -d ' ()' | tr '[:upper:]' '[:lower:]')"
    rbh_plist "$helper/Contents/Info.plist" "$helper_name" "$RBH_BUNDLE_ID.helper${id_suffix:+.$id_suffix}"
  done
}

# Signs the helper apps, then <app>, with <identity> by the rules of
# sign-cef.sh: "-" signs ad hoc without the hardened runtime; a real identity
# adds the hardened runtime and a secure timestamp (CMUX_TIMESTAMP=none skips
# it), and the GPU and Renderer helpers get com.apple.security.cs.allow-jit.
# The CEF framework inside <app> is signed by its owner first (a copy by the
# caller, the embedded app's own framework by sign-cef.sh).
rbh_sign() { # <app> <identity>
  local app="$1" identity="$2" flags jit helper
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
  for helper in "$app/Contents/Frameworks/$RBH_NAME Helper"*.app; do
    [[ -d "$helper" ]] || continue
    case "$helper" in
      *" Helper (GPU).app"|*" Helper (Renderer).app")
        codesign "${flags[@]}" --entitlements "$jit" "$helper" || { rm -f "$jit"; return 1; } ;;
      *)
        codesign "${flags[@]}" "$helper" || { rm -f "$jit"; return 1; } ;;
    esac
  done
  rm -f "$jit"
  codesign "${flags[@]}" "$app"
}
