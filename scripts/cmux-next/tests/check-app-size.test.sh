#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/Packages/macOS/CmuxNext/Sources/CmuxNextApp" "$tmp/scripts/cmux-next"
cp "$root_dir/scripts/cmux-next/check-app-size.sh" "$tmp/scripts/cmux-next/"
cp "$root_dir/scripts/cmux-next/count-swift-code-lines.py" "$tmp/scripts/cmux-next/"
cat > "$tmp/scripts/cmux-next/app-size-baseline.txt" <<'EOF'
3
EOF
cat > "$tmp/Packages/macOS/CmuxNext/Sources/CmuxNextApp/Example.swift" <<'EOF'
let first = 1
let url = "https://example.test/*not a comment*/"
let third = 3
EOF

git -C "$tmp" init -q
git -C "$tmp" add .
git -C "$tmp" -c user.email=test@example.invalid -c user.name=Test commit -qm base

cat >> "$tmp/Packages/macOS/CmuxNext/Sources/CmuxNextApp/Example.swift" <<'EOF'

// merge-tree noise
/* another comment */
EOF

"$tmp/scripts/cmux-next/check-app-size.sh" --base HEAD "$tmp"
if "$tmp/scripts/cmux-next/check-app-size.sh" "$tmp"; then
  echo "expected the physical cap to fail without a base" >&2
  exit 1
fi

printf '10\n' > "$tmp/scripts/cmux-next/app-size-baseline.txt"
echo 'let fourth = 4' >> "$tmp/Packages/macOS/CmuxNext/Sources/CmuxNextApp/Example.swift"
if "$tmp/scripts/cmux-next/check-app-size.sh" --base HEAD "$tmp" 2> "$tmp/growth.err"; then
  echo "expected real source growth to fail against the base" >&2
  exit 1
fi
if ! grep -qF '+1 Example.swift (3 -> 4)' "$tmp/growth.err"; then
  echo "expected the growth failure to name the file that grew" >&2
  cat "$tmp/growth.err" >&2
  exit 1
fi
