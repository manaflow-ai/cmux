#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./scripts/sign-release-app.sh --app-path <path> --signing-identity <identity> --entitlements <plist>

Normalizes the release app bundle layout, explicitly signs nested code in
standard macOS bundle locations, signs bundled helper executables, then signs
the app bundle without relying on codesign --deep.
EOF
}

APP_PATH=""
SIGNING_IDENTITY=""
ENTITLEMENTS=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app-path)
      APP_PATH="${2:-}"
      shift 2
      ;;
    --signing-identity)
      SIGNING_IDENTITY="${2:-}"
      shift 2
      ;;
    --entitlements)
      ENTITLEMENTS="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "$APP_PATH" || -z "$SIGNING_IDENTITY" || -z "$ENTITLEMENTS" ]]; then
  usage >&2
  exit 1
fi

if [[ ! -d "$APP_PATH/Contents" ]]; then
  echo "Cannot sign release app because $APP_PATH does not look like a macOS app bundle" >&2
  exit 1
fi

if [[ ! -f "$ENTITLEMENTS" ]]; then
  echo "Cannot sign release app because entitlements file $ENTITLEMENTS does not exist" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
"$SCRIPT_DIR/harden-release-app-layout.sh" "$APP_PATH"

codesign_nested_path() {
  local nested_path="$1"
  if [[ ! -e "$nested_path" ]]; then
    return 0
  fi
  /usr/bin/codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$nested_path"
}

codesign_helper_executable() {
  local helper_path="$1"
  if [[ ! -e "$helper_path" ]]; then
    return 0
  fi
  /usr/bin/codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" --entitlements "$ENTITLEMENTS" "$helper_path"
}

SIGNABLE_BUNDLES=()
while IFS= read -r -d '' signable_path; do
  SIGNABLE_BUNDLES+=("$signable_path")
done < <(
  find "$APP_PATH/Contents" \
    -type d \
    \( -name '*.framework' -o -name '*.app' -o -name '*.plugin' -o -name '*.appex' -o -name '*.xpc' \) \
    ! -path "$APP_PATH" \
    -print0 |
    perl -0ne '
      @items = split(/\0/, $_);
      @items = grep { length $_ } @items;
      @items = sort { () = $b =~ m{/}g <=> () = $a =~ m{/}g || $a cmp $b } @items;
      print join("\0", @items), "\0" if @items;
    '
)

for signable_bundle in "${SIGNABLE_BUNDLES[@]}"; do
  codesign_nested_path "$signable_bundle"
done

for helper_name in cmux ghostty; do
  codesign_helper_executable "$APP_PATH/Contents/Helpers/$helper_name"
done

/usr/bin/codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" --entitlements "$ENTITLEMENTS" "$APP_PATH"
/usr/bin/codesign --verify --strict --verbose=2 "$APP_PATH"

echo "Signed release app bundle at $APP_PATH"
