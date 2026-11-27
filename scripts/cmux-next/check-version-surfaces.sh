#!/usr/bin/env bash
# Fails when a built cmux-next app bundle's version surfaces disagree with the
# one cmux-next version (`scripts/ci/nightly_version.py next-base`, which reads
# cmux-tui/Cargo.toml [workspace.package] version).
#
# Surfaces checked:
#   - Contents/Info.plist CFBundleShortVersionString: `<V>` (dev builds) or
#     `<V>-<channel>.<build>` (nightly 1.0.0-nightly.<build>); the About
#     window, crash reports, cloud and the update UI all read it.
#   - Contents/Resources/bin/cmux and bin/cmux-tui `--version`
#     (`cmux <V> (<commit>; ghostty <commit>)`); bin/cmux is required.
#   - bin/acpmux and bin/cmux-browser-host `--version`, when bundled.
#
# scripts/reload.sh runs it on every built app (so every fleet build checks
# it) and nightly.yml runs it on the signed nightly-next app.
# Usage: scripts/cmux-next/check-version-surfaces.sh <app bundle>
set -euo pipefail
app="${1:?usage: check-version-surfaces.sh <app bundle>}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
expected="$(python3 "$root/scripts/ci/nightly_version.py" next-base --root "$root")"
# The checker body is a file, not a heredoc: bash 5.3 can block writing a
# heredoc into a pipe before python3 reads it.
exec python3 -I "$root/scripts/cmux-next/check-version-surfaces.py" "$app" "$expected"
