#!/usr/bin/env bash
# Every cmux-next version surface (the app's CFBundleShortVersionString and the
# bundled CLIs' `--version`) says the one cmux-next version, which lives in
# cmux-tui/Cargo.toml [workspace.package] and which
# `scripts/ci/nightly_version.py next-base` prints. A bundle where any surface
# says another version (the 0.1.0 CLI inside a 1.0.0 app) must fail.
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/root/cmux-tui" "$tmp/root/scripts/ci" "$tmp/root/scripts/cmux-next"
cp "$root_dir/scripts/ci/nightly_version.py" "$tmp/root/scripts/ci/"
cp "$root_dir/scripts/cmux-next/check-version-surfaces.sh" "$root_dir/scripts/cmux-next/check-version-surfaces.py" "$tmp/root/scripts/cmux-next/"
cat > "$tmp/root/cmux-tui/Cargo.toml" <<'EOF'
[package]
name = "cmux-tui-source-watch"
version = "0.0.0"

[workspace]
members = ["crates/cmux-tui"]

[workspace.package]
edition = "2024"
version = "3.4.5"
license = "GPL-3.0-or-later"

[workspace.dependencies]
serde = { version = "1", features = ["derive"] }
EOF

base="$(python3 "$tmp/root/scripts/ci/nightly_version.py" next-base --root "$tmp/root")"
[ "$base" = "3.4.5" ] || { echo "next-base printed '$base', want 3.4.5 from [workspace.package]" >&2; exit 1; }

# The real tree's cmux-next version is 1.0.0.
real="$(python3 "$root_dir/scripts/ci/nightly_version.py" next-base --root "$root_dir")"
[ "$real" = "1.0.0" ] || { echo "cmux-next version is '$real', want 1.0.0" >&2; exit 1; }

# The nightly marketing version derives from the same base.
marketing="$(python3 "$tmp/root/scripts/ci/nightly_version.py" marketing --track nightly-next \
  --project-version 0.65.0 --build 42 --next-base "$base")"
[ "$marketing" = "3.4.5-nightly.42" ] || { echo "marketing printed '$marketing'" >&2; exit 1; }

app="$tmp/cmux NEXT.app"
bin="$app/Contents/Resources/bin"
mkdir -p "$bin"
write_plist() {
  python3 -I - "$app/Contents/Info.plist" "$1" <<'PY'
import plistlib, sys
with open(sys.argv[1], "wb") as f:
    plistlib.dump({"CFBundleShortVersionString": sys.argv[2], "CFBundleVersion": "42"}, f)
PY
}
write_bin() {
  printf '#!/bin/sh\n[ "$1" = --version ] || exit 2\necho "%s"\n' "$2" > "$bin/$1"
  chmod +x "$bin/$1"
}
commit=0123456789abcdef0123456789abcdef01234567
write_plist "3.4.5-nightly.42"
write_bin cmux "cmux 3.4.5 ($commit; ghostty $commit)"
write_bin cmux-tui "cmux 3.4.5 ($commit; ghostty $commit)"
write_bin acpmux "acpmux 3.4.5 (0123456 2026-10-19)"
write_bin cmux-browser-host "cmux-browser-host 3.4.5 ($commit)"

check() { "$tmp/root/scripts/cmux-next/check-version-surfaces.sh" "$app" 2> "$tmp/err"; }

check || { cat "$tmp/err" >&2; echo "expected a bundle whose surfaces agree to pass" >&2; exit 1; }

# A dev build's plain version passes too.
write_plist "3.4.5"
check || { cat "$tmp/err" >&2; echo "expected plain 3.4.5 to pass" >&2; exit 1; }

# The bug the user saw: a 1.0.0 app whose bundled CLI says 0.1.0.
write_bin cmux "cmux 0.1.0 ($commit; ghostty $commit)"
if check; then echo "expected a 0.1.0 bin/cmux to fail" >&2; exit 1; fi
grep -q "bin/cmux" "$tmp/err" || { cat "$tmp/err" >&2; echo "failure must name bin/cmux" >&2; exit 1; }
write_bin cmux "cmux 3.4.5 ($commit; ghostty $commit)"

# The classic project version leaking into the app.
write_plist "0.65.0"
if check; then echo "expected app version 0.65.0 to fail" >&2; exit 1; fi
grep -q "CFBundleShortVersionString" "$tmp/err" || { cat "$tmp/err" >&2; echo "failure must name the app version" >&2; exit 1; }
write_plist "3.4.5-nightly.42"

# acpmux disagreeing fails; a bundle without it (an acpmux-less dev build) passes.
write_bin acpmux "acpmux 0.1.0 (0123456 2026-10-19)"
if check; then echo "expected a 0.1.0 acpmux to fail" >&2; exit 1; fi
rm "$bin/acpmux"
check || { cat "$tmp/err" >&2; echo "expected a bundle without acpmux to pass" >&2; exit 1; }

# The CLI is required: a bundle without bin/cmux fails.
rm "$bin/cmux"
if check; then echo "expected a bundle without bin/cmux to fail" >&2; exit 1; fi

echo "version-surfaces: ok"
