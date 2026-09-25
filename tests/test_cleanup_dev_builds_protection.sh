#!/usr/bin/env bash
# Regression coverage for https://github.com/manaflow-ai/cmux/issues/4508.
# Tagged builds waiting for dogfood must survive cleanup even when they are not
# running and have old mtimes.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

home="$tmp_dir/home"
derived="$tmp_dir/derived-data"
bin="$tmp_dir/bin"
mkdir -p "$home" "$derived" "$bin"

for tag in open-pr-body open-pr-comment open-pr-commit pinned-tag disposable-tag; do
    mkdir -p "$derived/cmux-$tag"
done

cat > "$tmp_dir/pinned-tags.txt" <<'EOF'
# cmux-manager pinned tags — awaiting a human dogfood action
pinned-tag
EOF

cat > "$bin/gh" <<'EOF'
#!/usr/bin/env bash
cat <<'JSON'
[{"body":"Dogfood: http://127.0.0.1:17320/open-pr-body.","comments":[{"body":"Please check http://127.0.0.1:17320/open-pr-comment"}],"commits":[{"messageHeadline":"build http://127.0.0.1:17320/open-pr-commit","messageBody":""}]}]
JSON
EOF
chmod +x "$bin/gh"

output="$(
    HOME="$home" \
    CMUX_CLEANUP_DERIVED_DATA_ROOT="$derived" \
    CMUX_CLEANUP_APP_SUPPORT_DIR="$tmp_dir/app-support" \
    CMUX_CLEANUP_LAST_CLI_PATH="$tmp_dir/last-cli-path" \
    CMUX_CLEANUP_PINNED_TAGS_FILE="$tmp_dir/pinned-tags.txt" \
    CMUX_CLEANUP_GH_BIN="$bin/gh" \
    "$ROOT_DIR/scripts/cleanup-dev-builds.sh"
)"

for tag in open-pr-body open-pr-comment open-pr-commit pinned-tag; do
    [[ "$output" == *"$tag"* ]] || fail "protected tag $tag was not reported"
    [[ "$output" == *"$tag"*"("* ]] || fail "protected tag $tag has no skip reason"
done

[[ "$output" == *"disposable-tag"*"would delete"* || "$output" == *"would delete:"* && "$output" == *"disposable-tag"* ]] \
    || fail "unprotected tag was not planned for deletion"
[[ "$output" != *"protection unavailable"* ]] || fail "healthy protection sources were reported unavailable"

cat > "$bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "simulated GitHub outage" >&2
exit 1
EOF
chmod +x "$bin/gh"

degraded_output="$(
    HOME="$home" \
    CMUX_CLEANUP_DERIVED_DATA_ROOT="$derived" \
    CMUX_CLEANUP_APP_SUPPORT_DIR="$tmp_dir/app-support" \
    CMUX_CLEANUP_LAST_CLI_PATH="$tmp_dir/last-cli-path" \
    CMUX_CLEANUP_PINNED_TAGS_FILE="$tmp_dir/pinned-tags.txt" \
    CMUX_CLEANUP_GH_BIN="$bin/gh" \
    "$ROOT_DIR/scripts/cleanup-dev-builds.sh"
)"

[[ "$degraded_output" == *"protection unavailable"* ]] || fail "GitHub outage was not reported"
[[ "$degraded_output" != *"would delete:"* ]] || fail "cleanup planned deletion while protection source was unavailable"
[[ "$degraded_output" == *"disposable-tag"* ]] || fail "degraded run did not fail closed for disposable tag"

echo "PASS: cleanup protects pinned and open-PR tags, and fails closed on GitHub errors"
