#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
IOS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

SOURCE_ROOT="$HOME/fun/cmux"
OUT_PLIST="$IOS_ROOT/Sources/Config/LocalConfig.plist"

usage() {
    cat <<'EOF'
Usage:
  ./scripts/sync-public-convex-vars.sh [--source-root <path>] [--out <path>]

Copies ONLY public Convex/Stack settings from the cmux web repo env files:
  - .env.local
  - .env.production

Whitelisted keys:
  - CONVEX_URL
  - NEXT_PUBLIC_CONVEX_URL
  - NEXT_PUBLIC_STACK_PROJECT_ID
  - NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY
  - NEXT_PUBLIC_WWW_ORIGIN
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --source-root)
            SOURCE_ROOT="$2"
            shift 2
            ;;
        --out)
            OUT_PLIST="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

LOCAL_ENV="$SOURCE_ROOT/.env.local"
PROD_ENV="$SOURCE_ROOT/.env.production"

if [[ ! -f "$LOCAL_ENV" ]]; then
    echo "Missing $LOCAL_ENV" >&2
    exit 1
fi

if [[ ! -f "$PROD_ENV" ]]; then
    echo "Missing $PROD_ENV" >&2
    exit 1
fi

read_env_value() {
    local file="$1"
    local key="$2"

    awk -v key="$key" '
        BEGIN { FS = "=" }
        /^[[:space:]]*#/ { next }
        {
            var = $1
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", var)
            if (var != key) next
            value = substr($0, index($0, "=") + 1)
            sub(/[[:space:]]*#.*$/, "", value)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
            gsub(/^"/, "", value)
            gsub(/"$/, "", value)
            gsub(/^'\''/, "", value)
            gsub(/'\''$/, "", value)
            print value
            exit
        }
    ' "$file"
}

xml_escape() {
    printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

mkdir -p "$(dirname "$OUT_PLIST")"

CONVEX_URL_DEV="$(read_env_value "$LOCAL_ENV" "CONVEX_URL")"
CONVEX_URL_PROD="$(read_env_value "$PROD_ENV" "NEXT_PUBLIC_CONVEX_URL")"

STACK_PROJECT_ID_DEV="$(read_env_value "$LOCAL_ENV" "NEXT_PUBLIC_STACK_PROJECT_ID")"
STACK_PROJECT_ID_PROD="$(read_env_value "$PROD_ENV" "NEXT_PUBLIC_STACK_PROJECT_ID")"

STACK_KEY_DEV="$(read_env_value "$LOCAL_ENV" "NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY")"
STACK_KEY_PROD="$(read_env_value "$PROD_ENV" "NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY")"

API_BASE_URL_DEV="$(read_env_value "$LOCAL_ENV" "NEXT_PUBLIC_WWW_ORIGIN")"
API_BASE_URL_PROD="$(read_env_value "$PROD_ENV" "NEXT_PUBLIC_WWW_ORIGIN")"

cat > "$OUT_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CONVEX_URL_DEV</key>
    <string>$(xml_escape "$CONVEX_URL_DEV")</string>
    <key>CONVEX_URL_PROD</key>
    <string>$(xml_escape "$CONVEX_URL_PROD")</string>
    <key>STACK_PROJECT_ID_DEV</key>
    <string>$(xml_escape "$STACK_PROJECT_ID_DEV")</string>
    <key>STACK_PROJECT_ID_PROD</key>
    <string>$(xml_escape "$STACK_PROJECT_ID_PROD")</string>
    <key>STACK_PUBLISHABLE_CLIENT_KEY_DEV</key>
    <string>$(xml_escape "$STACK_KEY_DEV")</string>
    <key>STACK_PUBLISHABLE_CLIENT_KEY_PROD</key>
    <string>$(xml_escape "$STACK_KEY_PROD")</string>
    <key>API_BASE_URL_DEV</key>
    <string>$(xml_escape "$API_BASE_URL_DEV")</string>
    <key>API_BASE_URL_PROD</key>
    <string>$(xml_escape "$API_BASE_URL_PROD")</string>
</dict>
</plist>
EOF

echo "Wrote $OUT_PLIST"
echo "Copied public keys only:"
echo "  CONVEX_URL_DEV, CONVEX_URL_PROD"
echo "  STACK_PROJECT_ID_DEV, STACK_PROJECT_ID_PROD"
echo "  STACK_PUBLISHABLE_CLIENT_KEY_DEV, STACK_PUBLISHABLE_CLIENT_KEY_PROD"
echo "  API_BASE_URL_DEV, API_BASE_URL_PROD"
