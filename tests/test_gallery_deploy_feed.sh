#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/output" "$tmp/bin"
printf '<html>matrix</html>\n' > "$tmp/output/index.html"
printf '{"results":[]}\n' > "$tmp/output/results.json"

cat > "$tmp/bin/bun" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'https://cmux-lawrences-mac-mini.tail137216.ts.net:18796/matrix/test-run/'
EOF
cat > "$tmp/bin/feed-post" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$FEED_ARGS"
EOF
chmod +x "$tmp/bin/bun" "$tmp/bin/feed-post"

FEED_ARGS="$tmp/feed.args" PATH="$tmp/bin:$PATH" \
  "$ROOT/scripts/gallery-deploy.sh" --matrix test-run "$tmp/output" \
  --pr https://github.com/manaflow-ai/cmux/pull/12345 \
  --feed-post "$tmp/bin/feed-post" \
  --head 0123456789012345678901234567890123456789 >/dev/null

grep -Fx -- '--preview' "$tmp/feed.args" >/dev/null
grep -Fx -- '--diff' "$tmp/feed.args" >/dev/null
grep -Fx -- '--matrix' "$tmp/feed.args" >/dev/null
grep -Fx -- '--build' "$tmp/feed.args" >/dev/null
grep -F -- "$tmp/output/index.html=https://cmux-lawrences-mac-mini.tail137216.ts.net:18796/matrix/test-run/index.html" "$tmp/feed.args" >/dev/null
grep -F -- "$tmp/output/results.json=https://cmux-lawrences-mac-mini.tail137216.ts.net:18796/matrix/test-run/results.json" "$tmp/feed.args" >/dev/null
grep -F -- '"head":"0123456789012345678901234567890123456789"' "$tmp/feed.args" >/dev/null

echo 'PASS: gallery deploy binds exact matrix artifacts to feed-post'
