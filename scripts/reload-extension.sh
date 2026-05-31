#!/usr/bin/env bash
set -euo pipefail

# reload-extension.sh — build a CMUX sample sidebar extension scoped to a dev build tag.
#
# A tagged cmux dev app (built by reload.sh --tag <t>) declares a per-tag sidebar
# extension point com.manaflow.cmux.sidebar.<TAG_ID> (see reload.sh
# inject_tagged_extension_point and CMUXSidebarExtensionPoint.identifier). For that
# host to have something to host, the sample extension must register against the SAME
# tagged point and carry per-tag bundle ids so it can coexist with other tags'
# extensions. This script builds an Examples extension, rewrites the built bundle to
# the tagged point id + tagged bundle ids (build output only; tracked source keeps the
# base id), re-signs, installs to ~/Applications, and launches it once to register.
#
# Usage:
#   scripts/reload-extension.sh --tag <tag> [--example sample|tabs|both] [--no-launch]
#
# The TAG_ID derivation matches reload.sh exactly (reverse-DNS sanitize) so the host
# and extension always agree on the point id.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE_POINT_ID="com.manaflow.cmux.sidebar"

TAG=""
EXAMPLE="both"
LAUNCH=1

usage() {
  cat <<EOF
Usage: scripts/reload-extension.sh --tag <tag> [--example sample|tabs|both] [--no-launch]

  --tag <tag>        Required. Same tag you pass to reload.sh, so the extension's
                     point id matches the tagged host's.
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
TAGGED_POINT_ID="${BASE_POINT_ID}.${TAG_ID}"

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

  local derived="/tmp/cmux-ext-${which}-${TAG_ID}"
  echo "==> building ${app_name} for tag ${TAG} (point ${TAGGED_POINT_ID})"
  rm -rf "$derived"
  xcodebuild -project "$REPO_ROOT/$project" -scheme "$scheme" -configuration Debug \
    -derivedDataPath "$derived" \
    CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
    build > "$derived.log" 2>&1 || { echo "error: build failed; see $derived.log" >&2; tail -20 "$derived.log" >&2; return 1; }

  local built_app
  built_app="$(find "$derived/Build/Products/Debug" -maxdepth 1 -name "*.app" | head -1)"
  [[ -z "$built_app" || ! -d "$built_app" ]] && { echo "error: no .app produced for $which" >&2; return 1; }

  # Stage under the tagged install name so multiple tags coexist in ~/Applications.
  local tagged_app_name="${app_name} ${TAG}"
  local staging="$derived/Build/Products/Debug/.${tagged_app_name}.stage.app"
  rm -rf "$staging"
  cp -R "$built_app" "$staging"

  local app_info="$staging/Contents/Info.plist"
  local appex="$staging/$appex_rel"
  local appex_info="$appex/Contents/Info.plist"
  [[ -f "$appex_info" ]] || { echo "error: appex Info.plist missing at $appex_info" >&2; return 1; }

  # 1) Point the appex at the tagged extension point id.
  /usr/libexec/PlistBuddy -c "Set :EXAppExtensionAttributes:EXExtensionPointIdentifier ${TAGGED_POINT_ID}" "$appex_info"

  # 2) Per-tag bundle ids so tagged copies don't collide with base or other tags.
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier ${app_bundle_id}.${TAG_ID}" "$app_info"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier ${appex_bundle_id}.${TAG_ID}" "$appex_info"

  # 3) Tagged display name so the Sidebar Extensions browser disambiguates.
  /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName ${tagged_app_name}" "$app_info" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string ${tagged_app_name}" "$app_info"

  # 4) Re-sign appex first (inside-out), then the app.
  xattr -cr "$staging" 2>/dev/null || true
  codesign --force --sign - --timestamp=none --generate-entitlement-der "$appex" >/dev/null 2>&1 \
    || { echo "error: codesign appex failed for $which" >&2; return 1; }
  codesign --force --sign - --timestamp=none --generate-entitlement-der "$staging" >/dev/null 2>&1 \
    || { echo "error: codesign app failed for $which" >&2; return 1; }

  # 5) Install to ~/Applications under the tagged name.
  local dest="$HOME/Applications/${tagged_app_name}.app"
  pkill -f "${tagged_app_name}.app/Contents/MacOS" 2>/dev/null || true
  rm -rf "$dest"
  ditto "$staging" "$dest"
  rm -rf "$staging"
  echo "==> installed ${dest}"

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
