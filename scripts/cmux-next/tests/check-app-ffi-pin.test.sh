#!/usr/bin/env bash
# scripts/cmux-next/check-app-ffi-pin.sh against a scratch repository:
#  - every crate cmux-app-ffi reaches through Cargo path dependencies is an
#    FFI input (cmux-rd-ffi pulls cmux-remote-browser; a change there left the
#    pin "current" on 2026-10-07, cf25b525a03b), and an unrelated crate is not;
#  - a checkout without an `origin` remote (a fleet ci-step worktree, step
#    6e04059b590e) still fetches the pinned source sha.
set -euo pipefail

script="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/check-app-ffi-pin.sh"
# The script reads the pin only through scripts/ci/app_ffi_pin.py, so the scratch tree carries it too.
pin_reader="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../ci" && pwd)/app_ffi_pin.py"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
fail() { echo "FAIL: $*" >&2; exit 1; }

repo="$tmp/repo"
mkdir -p "$repo/scripts/cmux-next" "$repo/scripts/ci" "$repo/Packages/macOS/CmuxNext"
cp "$script" "$repo/scripts/cmux-next/check-app-ffi-pin.sh"
cp "$pin_reader" "$repo/scripts/ci/app_ffi_pin.py"
crate() { # crate NAME [DEP...]
  local dir="$repo/cmux-tui/crates/$1"; shift
  mkdir -p "$dir/src"
  {
    printf '[package]\nname = "x"\n\n[lib]\npath = "src/lib.rs"\n\n[dependencies]\n'
    for dep in "$@"; do printf '%s = { path = "../%s" }\n' "$dep" "$dep"; done
  } > "$dir/Cargo.toml"
  echo "// $dir" > "$dir/src/lib.rs"
}
crate cmux-app-ffi cmux-rd-ffi cmux-layout-reducer-ffi
crate cmux-rd-ffi cmux-rd-core cmux-remote-browser
crate cmux-rd-core
crate cmux-layout-reducer-ffi
crate cmux-remote-browser
crate cmux-unrelated
git -C "$repo" init -q
git -C "$repo" add -A
git -C "$repo" commit -qm sources
pinned="$(git -C "$repo" rev-parse HEAD)"
python3 - "$pin_reader" "$repo/Packages/macOS/CmuxNext" "$pinned" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("app_ffi_pin", sys.argv[1])
pin = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pin)
package, sha = sys.argv[2], sys.argv[3]
open(f"{package}/Package.swift", "w").write("import Foundation\nimport PackageDescription\n\n" + pin.loader("0" * 64))
open(f"{package}/app-ffi-pin.json", "w").write(pin.render(sha, "0" * 64))
PY
git -C "$repo" add -A
git -C "$repo" commit -qm pin

out="$(cd "$repo" && bash scripts/cmux-next/check-app-ffi-pin.sh 2>&1)" || fail "a current pin failed: $out"
[[ "$out" == *"sources match $pinned"* ]] || fail "no match line: $out"

# An unrelated crate does not make the pin stale.
echo "// changed" >> "$repo/cmux-tui/crates/cmux-unrelated/src/lib.rs"
git -C "$repo" commit -qam unrelated
out="$(cd "$repo" && bash scripts/cmux-next/check-app-ffi-pin.sh 2>&1)" || fail "an unrelated crate made the pin stale: $out"

# A no-origin checkout (shallow, as a fleet step) fetches the pinned sha from
# CMUX_APP_FFI_PIN_REMOTE.
fleet="$tmp/fleet"
git init -q "$fleet"
git -C "$fleet" fetch -q --depth=1 "file://$repo" "$(git -C "$repo" rev-parse HEAD)"
git -C "$fleet" checkout -q --detach FETCH_HEAD
git -C "$fleet" cat-file -e "$pinned^{commit}" 2>/dev/null && fail "the fleet checkout already has the pinned sha"
out="$(cd "$fleet" && CMUX_APP_FFI_PIN_REMOTE="file://$repo" bash scripts/cmux-next/check-app-ffi-pin.sh 2>&1)" \
  || fail "a checkout without origin could not check the pin: $out"

# A crate reached only through cmux-rd-ffi's path dependencies is an input.
echo "// rb client" >> "$repo/cmux-tui/crates/cmux-remote-browser/src/lib.rs"
git -C "$repo" commit -qam rb
if out="$(cd "$repo" && bash scripts/cmux-next/check-app-ffi-pin.sh 2>&1)"; then
  fail "a cmux-remote-browser change kept the pin current: $out"
fi
[[ "$out" == *"cmux-remote-browser"* ]] || fail "the stale report does not name cmux-remote-browser: $out"

# A pin file off its one format, or a manifest with a pin of its own, fails
# closed, naming the reader's reason.
git -C "$repo" checkout -q HEAD~1
pin_json="$repo/Packages/macOS/CmuxNext/app-ffi-pin.json"
sed -i.bak 's/", "checksum"/",  "checksum"/' "$pin_json"
if out="$(cd "$repo" && bash scripts/cmux-next/check-app-ffi-pin.sh 2>&1)"; then
  fail "a pin file off its format passed: $out"
fi
[[ "$out" == *"no canonical cmux-app-ffi pin"* ]] || fail "the pin file report does not say so: $out"
mv "$pin_json.bak" "$pin_json"
manifest="$repo/Packages/macOS/CmuxNext/Package.swift"
# A pin file whose checksum Package.swift's checksum line does not repeat: a
# re-pin that left the manifest text (SwiftPM's manifest cache key) alone.
cp "$manifest" "$manifest.bak"
sed -i.tmp "s/^\/\/ app-ffi-pin-checksum: 0\{64\}$/\/\/ app-ffi-pin-checksum: $(printf '1%.0s' {1..64})/" "$manifest"
rm -f "$manifest.tmp"
grep -q "^// app-ffi-pin-checksum: 1\{64\}$" "$manifest" || fail "the test did not move the checksum line"
if out="$(cd "$repo" && bash scripts/cmux-next/check-app-ffi-pin.sh 2>&1)"; then
  fail "a checksum line off the pin file's checksum passed: $out"
fi
[[ "$out" == *"is not Packages/macOS/CmuxNext/app-ffi-pin.json's checksum"* ]] \
  || fail "the checksum line report does not say so: $out"
mv "$manifest.bak" "$manifest"
echo '// url: "https://github.com/manaflow-ai/cmux/releases/download/cmux-app-ffi-x"' \
  >> "$repo/Packages/macOS/CmuxNext/Package.swift"
if out="$(cd "$repo" && bash scripts/cmux-next/check-app-ffi-pin.sh 2>&1)"; then
  fail "a manifest with a pin of its own passed: $out"
fi
[[ "$out" == *"does not read the pin through its one loader block"* ]] || fail "the manifest report does not say so: $out"

echo "check-app-ffi-pin.test.sh: ok"
