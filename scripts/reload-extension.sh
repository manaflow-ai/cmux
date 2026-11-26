#!/usr/bin/env bash
set -euo pipefail

# reload-extension.sh — build a CMUX sample sidebar extension scoped to a dev build tag.
#
# A tagged cmux dev app (built by reload.sh --tag <t>) declares a host-scoped
# extension point <host-bundle-id>.cmux.sidebar (baked at build time via the
# CMUX_SIDEBAR_EXTENSION_POINT_ID build setting; see CMUXSidebarExtensionPoint).
# For that host to have something to host, the sample extension must register
# against the SAME tagged point and carry per-tag bundle ids so it can coexist
# with other tags' extensions.
#
# This script passes the tagged point id (CMUX_SIDEBAR_EXTENSION_POINT_ID) and a per-tag
# bundle-id suffix (CMUX_BUNDLE_ID_SUFFIX=.<TAG_ID>) to xcodebuild as build settings, so
# Xcode bakes EXExtensionPointIdentifier (via Info.plist variable substitution) and
# distinct app+appex bundle ids into an ad-hoc-signed bundle whose Info.plist is bound.
# pkd only records a bundle whose Info.plist is sealed AND whose appex id it has not
# already seen, so both the suffix and the signing are required. It then installs the
# .app to ~/Applications, ad-hoc re-signs as a fallback if the Info.plist did not bind,
# registers with pluginkit, and launches once.
#
# Usage:
#   scripts/reload-extension.sh --tag <tag> [--host-bundle-id <id>] [--example sample|tabs|both] [--no-launch]
#
# The TAG_ID derivation matches reload.sh exactly (reverse-DNS sanitize) so the host
# and extension always agree on the point id.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIDEBAR_POINT_NAME="cmux.sidebar"

TAG=""
EXAMPLE="both"
LAUNCH=1
HOST_BUNDLE_ID_OVERRIDE=""

usage() {
  cat <<EOF
Usage: scripts/reload-extension.sh --tag <tag> [--host-bundle-id <id>] [--example sample|tabs|both] [--no-launch]

  --tag <tag>        Required. Same tag you pass to reload.sh, so the extension's
                     point id matches the tagged host's.
  --host-bundle-id   Host app bundle id when reload.sh used --bundle-id.
                     Defaults to com.cmuxterm.app.debug.<sanitized-tag>.
  --bundle-id        Alias for --host-bundle-id.
  --example <which>  sample (CMUX ExtKit Sample Sidebar), tabs (TabsVisibleSidebar),
                     or both (default).
  --no-launch        Build and install but do not launch to register.
  -h, --help         Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag)
      TAG="${2:-}"
      [[ -z "$TAG" ]] && { echo "error: --tag requires a value" >&2; exit 1; }
      shift 2 ;;
    --host-bundle-id|--bundle-id)
      HOST_BUNDLE_ID_OVERRIDE="${2:-}"
      [[ -z "$HOST_BUNDLE_ID_OVERRIDE" ]] && { echo "error: $1 requires a value" >&2; exit 1; }
      shift 2 ;;
    --example)
      EXAMPLE="${2:-}"
      shift 2 ;;
    --no-launch)
      LAUNCH=0
      shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage; exit 1 ;;
  esac
done

[[ -z "$TAG" ]] && { echo "error: --tag is required" >&2; usage; exit 1; }
case "$EXAMPLE" in
  sample|tabs|both) ;;
  *) echo "error: --example must be sample, tabs, or both" >&2; exit 1 ;;
esac

# Reverse-DNS sanitize, identical to reload.sh sanitize_bundle: keep alnum, map
# everything else to '.', collapse repeats, trim leading/trailing dots, lowercase.
sanitize_bundle() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/./g; s/^\.+//; s/\.+$//'
}

TAG_ID="$(sanitize_bundle "$TAG")"
[[ -z "$TAG_ID" ]] && { echo "error: --tag must contain at least one alphanumeric character" >&2; exit 1; }
HOST_BUNDLE_ID="${HOST_BUNDLE_ID_OVERRIDE:-com.cmuxterm.app.debug.${TAG_ID}}"
TAGGED_POINT_ID="${HOST_BUNDLE_ID}.${SIDEBAR_POINT_NAME}"

# Each entry: project_path | scheme | app_name | app_bundle_id | appex_relpath | appex_bundle_id
example_specs() {
  case "$1" in
    sample)
      echo "Examples/SampleSidebarExtensionApp/SampleSidebarExtensionApp.xcodeproj|CMUXExtKitSampleSidebarApp|CMUX ExtKit Sample Sidebar|co.manaflow.CMUXExtKitSampleSidebarApp|Contents/Extensions/CMUX ExtKit Sample Sidebar Extension.appex|co.manaflow.CMUXExtKitSampleSidebarApp.Extension" ;;
    tabs)
      echo "Examples/TabsVisibleSidebar/TabsVisibleSidebar.xcodeproj|TabsVisibleSidebar|TabsVisibleSidebar|co.manaflow.TabsVisibleSidebar|Contents/Extensions/Tabs Visible Sidebar Extension.appex|co.manaflow.TabsVisibleSidebar.Extension" ;;
  esac
}

build_install_example() {
  local which="$1"
  local spec project scheme app_name app_bundle_id appex_rel appex_bundle_id
  spec="$(example_specs "$which")"
  IFS='|' read -r project scheme app_name app_bundle_id appex_rel appex_bundle_id <<< "$spec"

  local tagged_app_name="${app_name} ${TAG}"

  local derived="/tmp/cmux-ext-${which}-${TAG_ID}"
  echo "==> building ${app_name} for tag ${TAG} (point ${TAGGED_POINT_ID})"
  rm -rf "$derived"

  # Bake the tagged point id at build time: CMUX_SIDEBAR_EXTENSION_POINT_ID feeds the
  # appex Info.plist EXExtensionPointIdentifier via Xcode's $(VAR) substitution, so the
  # extension registers against the tagged host's point.
  #
  # Scope the bundle ids per tag via CMUX_BUNDLE_ID_SUFFIX (a default-empty build
  # setting the example projects insert into PRODUCT_BUNDLE_IDENTIFIER: app
  # <appBase>$(CMUX_BUNDLE_ID_SUFFIX), appex <appBase>$(CMUX_BUNDLE_ID_SUFFIX).Extension).
  # The suffix sits before the appex leaf so the appex id stays app-prefixed. Without
  # distinct bundle ids every tag's install shares one appex id and pkd keeps the first
  # one it saw, so the tagged copy never registers.
  #
  # Scope the visible name per tag via CMUX_DISPLAY_NAME_SUFFIX (default empty), appended
  # to the appex CFBundleDisplayName. The OS groups extensions by display name for the
  # enable/disable + availability counts the host reads, so two same-named appexes (a base
  # and a tagged copy installed side by side) are treated as one logical extension and
  # toggling one perturbs the other. A per-tag display name keeps them distinct. Leading
  # space so it reads "CMUX ExtKit Sample Sidebar <tag>".
  #
  # Ad-hoc sign (CODE_SIGN_IDENTITY="-") so resources and Info.plist are bound.
  # CODE_SIGNING_ALLOWED=NO produces a bundle whose Info.plist is "not bound", which
  # pkd refuses to ingest.
  xcodebuild -project "$REPO_ROOT/$project" -scheme "$scheme" -configuration Debug \
    -derivedDataPath "$derived" \
    CMUX_SIDEBAR_EXTENSION_POINT_ID="$TAGGED_POINT_ID" \
    CMUX_BUNDLE_ID_SUFFIX=".${TAG_ID}" \
    CMUX_DISPLAY_NAME_SUFFIX=" ${TAG}" \
    CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=YES CODE_SIGNING_ALLOWED=YES \
    CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" PROVISIONING_PROFILE_SPECIFIER="" \
    build > "$derived.log" 2>&1 || { echo "error: build failed; see $derived.log" >&2; tail -20 "$derived.log" >&2; return 1; }

  local built_app
  built_app="$(find "$derived/Build/Products/Debug" -maxdepth 1 -name "*.app" | head -1)"
  [[ -z "$built_app" || ! -d "$built_app" ]] && { echo "error: no .app produced for $which" >&2; return 1; }

  # Install to ~/Applications under the tagged name so multiple tags coexist.
  local dest="$HOME/Applications/${tagged_app_name}.app"
  pkill -f "${tagged_app_name}.app/Contents/MacOS" 2>/dev/null || true
  rm -rf "$dest"
  ditto "$built_app" "$dest"
  echo "==> installed ${dest}"

  # Delete the throwaway build output. macOS auto-registers ANY extension bundle it
  # sees on disk, so leaving the /tmp-built .app around makes pkd register a second copy
  # of this extension alongside the ~/Applications install. That duplicate then shows up
  # in the sidebar extension browser and, because the OS groups by display name, toggling
  # it perturbs the real one. Removing the build dir keeps exactly one registered copy.
  rm -rf "$derived" "$derived.log"

  # Do NOT re-sign. xcodebuild already ad-hoc signs with the appex's entitlements
  # (App Sandbox + the co.manaflow.cmux.sidebar app group) bound in. Those entitlements
  # are required for the extension's XPC connection to the host; a bare
  # `codesign --force --sign -` re-sign strips them, and the extension then connects and
  # immediately drops ("Extension Blocked / lost the connection") with no recovery.
  # pkd ingests the as-built bundle fine because its bundle id is per-tag distinct
  # (CMUX_BUNDLE_ID_SUFFIX); resealing the Info.plist is unnecessary.
  local appex
  appex="$(find "$dest/Contents/Extensions" -maxdepth 1 -name "*.appex" | head -1)"
  if [[ -n "$appex" ]]; then
    pluginkit -a "$appex" 2>/dev/null || true
  else
    echo "warning: no .appex found in $dest/Contents/Extensions" >&2
  fi

  if [[ "$LAUNCH" -eq 1 ]]; then
    open "$dest" && echo "==> launched ${tagged_app_name} to register"
  fi
}

case "$EXAMPLE" in
  sample) build_install_example sample ;;
  tabs)   build_install_example tabs ;;
  both)   build_install_example sample; build_install_example tabs ;;
esac

echo "==> done. Tagged extension(s) register against ${TAGGED_POINT_ID}."
echo "    Enable them in the tagged host's Sidebar Extensions browser."
