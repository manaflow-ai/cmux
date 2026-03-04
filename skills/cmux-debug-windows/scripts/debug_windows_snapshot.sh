#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: debug_windows_snapshot.sh [--domain <defaults-domain>] [--copy]

Collect Sidebar Debug, Background Debug, Menu Bar Extra, and Browser DevTools debug values
from macOS defaults and print a combined payload. Use --copy to also copy the payload.

Examples:
  debug_windows_snapshot.sh
  debug_windows_snapshot.sh --copy
  debug_windows_snapshot.sh --domain dev.manaflow.cmux --copy
USAGE
}

domain=""
copy_flag=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain)
      shift
      [[ $# -gt 0 ]] || { echo "Missing value for --domain" >&2; exit 1; }
      domain="$1"
      ;;
    --copy)
      copy_flag=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

discover_domain() {
  defaults domains 2>/dev/null \
    | tr ',' '\n' \
    | tr -d ' ' \
    | grep -E 'cmux' \
    | head -n1 || true
}

read_value() {
  local key="$1"
  local fallback="$2"
  local value
  value=$(defaults read "$domain" "$key" 2>/dev/null || true)
  if [[ -z "$value" ]]; then
    printf '%s' "$fallback"
  else
    printf '%s' "$value"
  fi
}

format_number() {
  local raw="$1"
  local precision="$2"
  if [[ "$raw" =~ ^-?[0-9]+([.][0-9]+)?$ ]]; then
    printf "%.*f" "$precision" "$raw"
  else
    printf "%.*f" "$precision" 0
  fi
}

if [[ -z "$domain" ]]; then
  domain="$(discover_domain)"
fi

if [[ -z "$domain" ]]; then
  echo "Could not auto-detect a cmux defaults domain. Pass --domain <bundle-id>." >&2
  exit 1
fi

if ! defaults domains 2>/dev/null | tr ',' '\n' | tr -d ' ' | grep -Fxq "$domain"; then
  echo "Defaults domain '$domain' was not found on this machine." >&2
  exit 1
fi

sidebarPreset="$(read_value sidebarPreset nativeSidebar)"
sidebarMaterial="$(read_value sidebarMaterial sidebar)"
sidebarBlendMode="$(read_value sidebarBlendMode behindWindow)"
sidebarState="$(read_value sidebarState followWindow)"
sidebarBlurOpacity="$(format_number "$(read_value sidebarBlurOpacity 0.79)" 2)"
sidebarTintHex="$(read_value sidebarTintHex '#101010')"
sidebarTintOpacity="$(format_number "$(read_value sidebarTintOpacity 0.54)" 2)"
sidebarCornerRadius="$(format_number "$(read_value sidebarCornerRadius 0.0)" 1)"
sidebarActiveTabIndicatorStyle="$(read_value sidebarActiveTabIndicatorStyle solidFill)"
shortcutHintSidebarXOffset="$(format_number "$(read_value shortcutHintSidebarXOffset 0.0)" 1)"
shortcutHintSidebarYOffset="$(format_number "$(read_value shortcutHintSidebarYOffset 0.0)" 1)"
shortcutHintTitlebarXOffset="$(format_number "$(read_value shortcutHintTitlebarXOffset 4.0)" 1)"
shortcutHintTitlebarYOffset="$(format_number "$(read_value shortcutHintTitlebarYOffset 0.0)" 1)"
shortcutHintPaneTabXOffset="$(format_number "$(read_value shortcutHintPaneTabXOffset 0.0)" 1)"
shortcutHintPaneTabYOffset="$(format_number "$(read_value shortcutHintPaneTabYOffset 0.0)" 1)"
shortcutHintAlwaysShow="$(read_value shortcutHintAlwaysShow 0)"

bgGlassEnabled="$(read_value bgGlassEnabled 1)"
bgGlassMaterial="$(read_value bgGlassMaterial hudWindow)"
bgGlassTintHex="$(read_value bgGlassTintHex '#000000')"
bgGlassTintOpacity="$(format_number "$(read_value bgGlassTintOpacity 0.05)" 2)"

menubarDebugPreviewEnabled="$(read_value menubarDebugPreviewEnabled 0)"
menubarDebugPreviewCount="$(read_value menubarDebugPreviewCount 1)"
menubarDebugBadgeRectX="$(format_number "$(read_value menubarDebugBadgeRectX 5.38)" 2)"
menubarDebugBadgeRectY="$(format_number "$(read_value menubarDebugBadgeRectY 6.43)" 2)"
menubarDebugBadgeRectWidth="$(format_number "$(read_value menubarDebugBadgeRectWidth 10.75)" 2)"
menubarDebugBadgeRectHeight="$(format_number "$(read_value menubarDebugBadgeRectHeight 11.58)" 2)"
menubarDebugSingleDigitFontSize="$(format_number "$(read_value menubarDebugSingleDigitFontSize 6.70)" 2)"
menubarDebugMultiDigitFontSize="$(format_number "$(read_value menubarDebugMultiDigitFontSize 6.70)" 2)"
menubarDebugSingleDigitYOffset="$(format_number "$(read_value menubarDebugSingleDigitYOffset 0.60)" 2)"
menubarDebugMultiDigitYOffset="$(format_number "$(read_value menubarDebugMultiDigitYOffset 0.60)" 2)"
legacySingleDigitX="$(read_value menubarDebugTextRectXAdjust '')"
if [[ -n "$legacySingleDigitX" ]]; then
menubarDebugSingleDigitXAdjust="$(format_number "$legacySingleDigitX" 2)"
else
  menubarDebugSingleDigitXAdjust="$(format_number "$(read_value menubarDebugSingleDigitXAdjust -1.10)" 2)"
fi
menubarDebugMultiDigitXAdjust="$(format_number "$(read_value menubarDebugMultiDigitXAdjust 2.42)" 2)"
menubarDebugTextRectWidthAdjust="$(format_number "$(read_value menubarDebugTextRectWidthAdjust 1.80)" 2)"

browserDevToolsIconName="$(read_value browserDevToolsIconName 'wrench.and.screwdriver')"
browserDevToolsIconColor="$(read_value browserDevToolsIconColor bonsplitInactive)"

payload="$(cat <<PAYLOAD
# Defaults domain
$domain

# Sidebar Debug
sidebarPreset=$sidebarPreset
sidebarMaterial=$sidebarMaterial
sidebarBlendMode=$sidebarBlendMode
sidebarState=$sidebarState
sidebarBlurOpacity=$sidebarBlurOpacity
sidebarTintHex=$sidebarTintHex
sidebarTintOpacity=$sidebarTintOpacity
sidebarCornerRadius=$sidebarCornerRadius
sidebarActiveTabIndicatorStyle=$sidebarActiveTabIndicatorStyle
shortcutHintSidebarXOffset=$shortcutHintSidebarXOffset
shortcutHintSidebarYOffset=$shortcutHintSidebarYOffset
shortcutHintTitlebarXOffset=$shortcutHintTitlebarXOffset
shortcutHintTitlebarYOffset=$shortcutHintTitlebarYOffset
shortcutHintPaneTabXOffset=$shortcutHintPaneTabXOffset
shortcutHintPaneTabYOffset=$shortcutHintPaneTabYOffset
shortcutHintAlwaysShow=$shortcutHintAlwaysShow

# Background Debug
bgGlassEnabled=$bgGlassEnabled
bgGlassMaterial=$bgGlassMaterial
bgGlassTintHex=$bgGlassTintHex
bgGlassTintOpacity=$bgGlassTintOpacity

# Menu Bar Extra Debug
menubarDebugPreviewEnabled=$menubarDebugPreviewEnabled
menubarDebugPreviewCount=$menubarDebugPreviewCount
menubarDebugBadgeRectX=$menubarDebugBadgeRectX
menubarDebugBadgeRectY=$menubarDebugBadgeRectY
menubarDebugBadgeRectWidth=$menubarDebugBadgeRectWidth
menubarDebugBadgeRectHeight=$menubarDebugBadgeRectHeight
menubarDebugSingleDigitFontSize=$menubarDebugSingleDigitFontSize
menubarDebugMultiDigitFontSize=$menubarDebugMultiDigitFontSize
menubarDebugSingleDigitYOffset=$menubarDebugSingleDigitYOffset
menubarDebugMultiDigitYOffset=$menubarDebugMultiDigitYOffset
menubarDebugSingleDigitXAdjust=$menubarDebugSingleDigitXAdjust
menubarDebugMultiDigitXAdjust=$menubarDebugMultiDigitXAdjust
menubarDebugTextRectWidthAdjust=$menubarDebugTextRectWidthAdjust

# Browser DevTools Button
browserDevToolsIconName=$browserDevToolsIconName
browserDevToolsIconColor=$browserDevToolsIconColor
PAYLOAD
)"

printf '%s\n' "$payload"

if [[ "$copy_flag" -eq 1 ]]; then
  if command -v pbcopy >/dev/null 2>&1; then
    printf '%s' "$payload" | pbcopy
    echo "Copied debug snapshot to clipboard."
  else
    echo "pbcopy not available; skipped clipboard copy." >&2
  fi
fi
