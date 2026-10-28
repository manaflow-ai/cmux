# Sourced, not run. The one owner of the cmux-remote-browser-host layouts, used
# by bundle-remote-browser-host.sh (a standalone host app with its own CEF
# copy), embed-remote-browser-host.sh (the host embedded in a cmux-next app,
# using the app's CEF framework) and sign-cmux-bundle.sh:
#
#   standalone:  <host>.app/Contents/MacOS/cmux-remote-browser-host
#                <host>.app/Contents/Frameworks/cmux-remote-browser-host Helper{, (GPU), (Renderer), (Plugin), (Alerts)}.app
#                <host>.app/Contents/Frameworks/Chromium Embedded Framework.framework   (the caller adds a copy)
#   embedded:    <cmux>.app/Contents/MacOS/cmux-remote-browser-host                     (a second executable)
#                <cmux>.app/Contents/Frameworks/cmux-remote-browser-host Helper{...}.app
#                <cmux>.app/Contents/Frameworks/Chromium Embedded Framework.framework   (the app's own)
#
# CEF looks for "<exe> Helper.app" and its variants beside its framework; the
# host binary is its own helper (rb_shim_run runs CefExecuteProcess for
# --type=). The helpers run in Chromium's sandbox, which lets them read only
# the main bundle of the host process, so the framework and the helpers must
# be inside that bundle: an embedded host is a second executable of the app
# (as the app's Chromium host is, embed-cef.sh), never an app of its own that
# links the app's framework through a symlink. Works under Xcode's /bin/bash 3.2.

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

# Writes the five helper apps (copies of <binary>) into <frameworks dir>.
rbh_write_helpers() { # <binary> <frameworks dir>
  local bin="$1" frameworks="$2" suffix helper_name helper id_suffix
  mkdir -p "$frameworks"
  for suffix in "${RBH_HELPER_SUFFIXES[@]}"; do
    helper_name="$RBH_NAME Helper$suffix"
    helper="$frameworks/$helper_name.app"
    mkdir -p "$helper/Contents/MacOS"
    cp "$bin" "$helper/Contents/MacOS/$helper_name"
    chmod 755 "$helper/Contents/MacOS/$helper_name"
    id_suffix="$(printf %s "$suffix" | tr -d ' ()' | tr '[:upper:]' '[:lower:]')"
    rbh_plist "$helper/Contents/Info.plist" "$helper_name" "$RBH_BUNDLE_ID.helper${id_suffix:+.$id_suffix}"
  done
}

# Writes the host executable, its Info.plist and the five helper apps into a
# new (absent) standalone <app>. Signs nothing.
rbh_write_bundle() { # <binary> <app>
  local bin="$1" app="$2"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Frameworks"
  cp "$bin" "$app/Contents/MacOS/$RBH_NAME"
  chmod 755 "$app/Contents/MacOS/$RBH_NAME"
  rbh_plist "$app/Contents/Info.plist" "$RBH_NAME" "$RBH_BUNDLE_ID"
  rbh_write_helpers "$bin" "$app/Contents/Frameworks"
}

# The embedded host's files in <app> (a cmux app), one per line: the second
# executable and the five helper apps.
rbh_embedded_paths() { # <app>
  local suffix
  printf '%s\n' "$1/Contents/MacOS/$RBH_NAME"
  for suffix in "${RBH_HELPER_SUFFIXES[@]}"; do
    printf '%s\n' "$1/Contents/Frameworks/$RBH_NAME Helper$suffix.app"
  done
}

# Removes the embedded host from <app>, and the earlier layout
# (Contents/Helpers/cmux-remote-browser-host.app, whose helpers could not read
# the app's framework under the sandbox).
rbh_remove_embedded() { # <app>
  local path
  while IFS= read -r path; do rm -rf "$path"; done < <(rbh_embedded_paths "$1")
  rm -rf "$1/Contents/Helpers/$RBH_NAME.app"
  rmdir "$1/Contents/Helpers" 2>/dev/null || true
}

# Writes the embedded host into <app> (a cmux app with its CEF framework), in
# place of any earlier one. Signs nothing.
rbh_write_embedded() { # <binary> <app>
  local bin="$1" app="$2"
  rbh_remove_embedded "$app"
  mkdir -p "$app/Contents/MacOS"
  cp "$bin" "$app/Contents/MacOS/$RBH_NAME"
  chmod 755 "$app/Contents/MacOS/$RBH_NAME"
  rbh_write_helpers "$bin" "$app/Contents/Frameworks"
}

# Signs the host's helper apps in <frameworks dir>, then the host: <app> for a
# standalone host (rbh_sign), the second executable of a cmux app with the
# host's identifier for an embedded one (rbh_sign_embedded). The rules of
# sign-cef.sh: "-" signs ad hoc without the hardened runtime; a real identity
# adds the hardened runtime and a secure timestamp (CMUX_TIMESTAMP=none skips
# it), and the GPU and Renderer helpers get com.apple.security.cs.allow-jit.
# The CEF framework is signed by its owner first (a copy by the caller, the
# app's own framework by sign-cef.sh).
rbh_sign_flags() { # <identity>: sets the array RBH_SIGN_FLAGS
  RBH_SIGN_FLAGS=(--force --sign "$1")
  if [[ "$1" != "-" ]]; then
    RBH_SIGN_FLAGS+=(--options runtime)
    if [[ "${CMUX_TIMESTAMP:-}" == "none" ]]; then RBH_SIGN_FLAGS+=(--timestamp=none); else RBH_SIGN_FLAGS+=(--timestamp); fi
  fi
}

rbh_sign_helpers() { # <frameworks dir> <identity>
  local frameworks="$1" jit helper
  rbh_sign_flags "$2"
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
  for helper in "$frameworks/$RBH_NAME Helper"*.app; do
    [[ -d "$helper" ]] || continue
    case "$helper" in
      *" Helper (GPU).app"|*" Helper (Renderer).app")
        codesign "${RBH_SIGN_FLAGS[@]}" --entitlements "$jit" "$helper" || { rm -f "$jit"; return 1; } ;;
      *)
        codesign "${RBH_SIGN_FLAGS[@]}" "$helper" || { rm -f "$jit"; return 1; } ;;
    esac
  done
  rm -f "$jit"
}

rbh_sign() { # <standalone app> <identity>
  rbh_sign_helpers "$1/Contents/Frameworks" "$2" || return 1
  rbh_sign_flags "$2"
  codesign "${RBH_SIGN_FLAGS[@]}" "$1"
}

# Nested code of <app>: signed before the app's own signature.
rbh_sign_embedded() { # <cmux app> <identity>
  local exe="$1/Contents/MacOS/$RBH_NAME"
  [[ -f "$exe" ]] || return 0
  rbh_sign_helpers "$1/Contents/Frameworks" "$2" || return 1
  rbh_sign_flags "$2"
  codesign "${RBH_SIGN_FLAGS[@]}" --identifier "$RBH_BUNDLE_ID" "$exe"
}
