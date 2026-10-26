#!/usr/bin/env bash
# scripts/cmux-next/check-app-ffi-pin.sh against a scratch repository:
#  - every crate cmux-app-ffi reaches through Cargo path dependencies is an
#    FFI input (cmux-rd-ffi pulls cmux-remote-browser; a change there left the
#    pin "current" on 2026-10-07, cf25b525a03b), and an unrelated crate is not;
#  - a checkout without an `origin` remote (a fleet ci-step worktree, step
#    6e04059b590e) still fetches the pinned source sha.
set -euo pipefail

script="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/check-app-ffi-pin.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
fail() { echo "FAIL: $*" >&2; exit 1; }

repo="$tmp/repo"
mkdir -p "$repo/scripts/cmux-next" "$repo/Packages/macOS/CmuxNext"
cp "$script" "$repo/scripts/cmux-next/check-app-ffi-pin.sh"
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
cat > "$repo/Packages/macOS/CmuxNext/Package.swift" <<EOF
.binaryTarget(
    name: "CCmuxAppFFI",
    url: "https://github.com/manaflow-ai/cmux/releases/download/cmux-app-ffi-$pinned/CCmuxAppFFI.xcframework.zip",
    checksum: "$(printf '0%.0s' {1..64})"
)
EOF
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

# --batch lists the refs whose own commits change an FFI input (the pin
# lander's queue), and not a ref that changes only other crates, nor a ref
# that merely sits behind HEAD's FFI commits.
trunk="$(git -C "$repo" symbolic-ref --short HEAD)"
git -C "$repo" branch -q behind HEAD~1
git -C "$repo" checkout -q -b ffi-change "$trunk"
echo "// guard" >> "$repo/cmux-tui/crates/cmux-rd-core/src/lib.rs"
git -C "$repo" commit -qam ffi-change
git -C "$repo" checkout -q -b other-change "$trunk"
echo "// other" >> "$repo/cmux-tui/crates/cmux-unrelated/src/lib.rs"
git -C "$repo" commit -qam other-change
git -C "$repo" checkout -q "$trunk"
out="$(cd "$repo" && bash scripts/cmux-next/check-app-ffi-pin.sh --batch ffi-change other-change behind 2>&1)" \
  || fail "--batch failed: $out"
[[ "$out" == *"ffi-change ("*"1 FFI input file(s)"*"cmux-tui/crates/cmux-rd-core/src/lib.rs"* ]] \
  || fail "--batch did not list ffi-change and its input: $out"
[[ "$out" != *"other-change ("* ]] || fail "--batch listed a ref that changes no FFI input: $out"
[[ "$out" != *"behind ("* ]] || fail "--batch listed a ref behind HEAD: $out"
[[ "$out" == *"app FFI batch: 1 of 3 ref(s)"* ]] || fail "--batch summary is wrong: $out"
if out="$(cd "$repo" && bash scripts/cmux-next/check-app-ffi-pin.sh --batch no-such-ref 2>&1)"; then
  fail "--batch accepted a ref that is not a commit: $out"
fi

echo "check-app-ffi-pin.test.sh: ok"
