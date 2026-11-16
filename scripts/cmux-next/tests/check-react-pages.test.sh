#!/usr/bin/env bash
# Behavior test of check-react-pages.py on throwaway repositories.
set -euo pipefail
# shellcheck source=scripts/cmux-next/tests/lib/git-fixture.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-fixture.sh"  # drops inherited GIT_DIR/GIT_CONFIG redirects, no background maintenance
here="$(cd "$(dirname "$0")" && pwd)"
check="$here/../check-react-pages.py"
tmp="$(mktemp -d)"
remove_tmp() { rm -rf "$tmp"; }
git_fixture_trap_exit remove_tmp

fail() { echo "check-react-pages.test: $1" >&2; exit 1; }

repo="$tmp/repo"
mkdir -p "$repo/webviews/src/pages/settings" "$repo/webviews/src/pages/shared" "$repo/scripts/cmux-next"
git_fixture_init "$repo"
git -C "$repo" config user.email t@example.com
git -C "$repo" config user.name t
git -C "$repo" config maintenance.auto false
git -C "$repo" config gc.auto 0
printf 'settings\tpage\ta full tab page\n' > "$repo/scripts/cmux-next/react-pages.tsv"
touch "$repo/webviews/src/pages/settings/main.tsx" "$repo/webviews/src/pages/shared/x.ts"
git -C "$repo" add -A && git -C "$repo" commit -qm base
base="$(git -C "$repo" rev-parse HEAD)"

# A listed page passes; the shared directory needs no row.
python3 -I "$check" "$repo" >/dev/null || fail "a listed page was refused"

# A new page directory with no row fails.
mkdir -p "$repo/webviews/src/pages/toasts" && touch "$repo/webviews/src/pages/toasts/main.tsx"
if python3 -I "$check" "$repo" >/dev/null 2>&1; then fail "an unlisted page passed"; fi

# The same directory with a `page` row passes, also against the base.
printf 'toasts\tpage\ta full tab page\n' >> "$repo/scripts/cmux-next/react-pages.tsv"
python3 -I "$check" --base "$base" "$repo" >/dev/null || fail "a new page row was refused"

# A new `debt` row is refused against the base, and accepted with no base.
printf 'settings\tpage\ta full tab page\ntoasts\tdebt\tchrome drawn in React\n' > "$repo/scripts/cmux-next/react-pages.tsv"
if python3 -I "$check" --base "$base" "$repo" >/dev/null 2>&1; then fail "a new debt row passed against the base"; fi
python3 -I "$check" "$repo" >/dev/null || fail "an existing debt row was refused with no base"

# An unknown kind fails.
printf 'settings\tmaybe\twhy\n' > "$repo/scripts/cmux-next/react-pages.tsv"
rm -rf "$repo/webviews/src/pages/toasts"
if python3 -I "$check" "$repo" >/dev/null 2>&1; then fail "an unknown kind passed"; fi

# A row whose directory is gone is a note, not a failure.
printf 'settings\tpage\ta full tab page\ngone\tdebt\twas a bar\n' > "$repo/scripts/cmux-next/react-pages.tsv"
python3 -I "$check" "$repo" >/dev/null 2>"$tmp/err" || fail "a stale row failed"
grep -q "gone has no directory" "$tmp/err" || fail "a stale row gave no note"

# The Command Palette's target takes no web view: an import or a web view type fails; a comment does not.
printf 'settings\tpage\ta full tab page\n' > "$repo/scripts/cmux-next/react-pages.tsv"
palette="$repo/Packages/macOS/CmuxNext/Sources/CmuxNextPalette"
mkdir -p "$palette"
printf 'import AppKit\n// A WKWebView is not allowed here.\nfinal class Row: NSView {}\n' > "$palette/Row.swift"
python3 -I "$check" "$repo" >/dev/null || fail "a palette file with a comment about web views was refused"
printf 'import AppKit\npublic import WebKit\n' > "$palette/Preview.swift"
if python3 -I "$check" "$repo" >/dev/null 2>&1; then fail "a palette file that imports WebKit passed"; fi
printf 'import AppKit\nfinal class Preview: NSView { var page: PageWebView? }\n' > "$palette/Preview.swift"
if python3 -I "$check" "$repo" >/dev/null 2>"$tmp/err"; then fail "a palette file with a PageWebView passed"; fi
grep -q "Preview.swift:2: the Command Palette is Swift" "$tmp/err" || fail "the palette finding does not name the line"
rm "$palette/Preview.swift"
python3 -I "$check" "$repo" >/dev/null || fail "the palette without a web view was refused"

echo "check-react-pages: ok"
