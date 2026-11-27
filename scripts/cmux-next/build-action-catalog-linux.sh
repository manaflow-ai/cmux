#!/usr/bin/env bash
# Builds cmux-tui's action catalog crate (cmux-action-catalog) as a Linux static library at the commit
# the app's CCmuxAppFFI pin was built from, with its header and a module map for `CCmuxActionCatalogFFI`.
# The action exporter on Linux (regenerate-action-exports-linux.sh's scratch package) links it in place
# of the xcframework, so its exports read the same Rust catalog the Mac's do: the pinned one, not this
# checkout's (an unpinned catalog change waits for the re-pin, docs/ci/app-ffi-release.md).
#
#   build-action-catalog-linux.sh OUT_DIR [SHA]
#
# SHA defaults to the pin's (Packages/macOS/CmuxNext/app-ffi-pin.json, tag cmux-app-ffi-<sha>). The
# crate depends only on serde_json, so it builds alone, with SHA's Cargo.lock for its versions (cargo
# prunes the workspace's other packages from the copy; the versions it keeps are the lock's).
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
out="${1:?usage: build-action-catalog-linux.sh OUT_DIR [SHA]}"
sha="${2:-}"
if [ -z "$sha" ]; then
  sha="$(python3 -c 'import json,re,sys; u=json.load(open(sys.argv[1]))["url"]; print(re.search(r"cmux-app-ffi-([0-9a-f]{40})/", u).group(1))' \
    "$root/Packages/macOS/CmuxNext/app-ffi-pin.json")"
fi
crate=cmux-tui/crates/cmux-action-catalog
if ! git -C "$root" cat-file -e "$sha^{commit}" 2>/dev/null; then
  depth=()
  [[ "$(git -C "$root" rev-parse --is-shallow-repository)" == true ]] && depth=(--depth 1)
  git -C "$root" fetch --no-recurse-submodules --quiet --no-tags ${depth[@]+"${depth[@]}"} --filter=blob:none origin "$sha"
fi
mkdir -p "$out"
out="$(cd "$out" && pwd)"
work="$out/src-$sha"
if [ ! -f "$work/Cargo.toml" ]; then
  rm -rf "$work.partial"
  mkdir -p "$work.partial"
  git -C "$root" archive "$sha" "$crate" | tar -x -C "$work.partial" --strip-components=3
  # The workspace keys the crate inherits, written out: edition, rust-version and serde_json's
  # requirement at SHA, no lints (a warning is not this build's to fail on).
  python3 - "$work.partial/Cargo.toml" <<'PY'
import re, sys
path = sys.argv[1]
text = open(path).read()
text = text.replace("edition.workspace = true", 'edition = "2024"')
text = re.sub(r"(?m)^(rust-version|license|publish)\.workspace = true\n", "", text)
text = text.replace("serde_json.workspace = true", 'serde_json = "1"')
text = re.sub(r"(?ms)^\[lints\]\nworkspace = true\n", "", text)
text += '\n[lib]\ncrate-type = ["staticlib"]\n\n[workspace]\n'
open(path, "w").write(text)
PY
  git -C "$root" show "$sha:cmux-tui/Cargo.lock" > "$work.partial/Cargo.lock"
  # SHA's toolchain pin: rustup reads it from the directory cargo runs in (below).
  git -C "$root" show "$sha:cmux-tui/rust-toolchain.toml" > "$work.partial/rust-toolchain.toml" 2>/dev/null || true
  mv "$work.partial" "$work"
fi
# The swift image has clang but no `cc`, which rustc links with and build scripts compile with by default.
if ! command -v cc >/dev/null && command -v clang >/dev/null; then
  export CC=clang
  export CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_LINKER=clang CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER=clang
fi
(cd "$work" && CARGO_TARGET_DIR="$out/target" cargo build --quiet --release --manifest-path "$work/Cargo.toml")
mkdir -p "$out/lib" "$out/include"
cp "$out/target/release/libcmux_action_catalog.a" "$out/lib/"
cp "$work/include/cmux_action_catalog.h" "$out/include/"
cat > "$out/include/module.modulemap" <<'MAP'
module CCmuxActionCatalogFFI {
    header "cmux_action_catalog.h"
    link "cmux_action_catalog"
    export *
}
MAP
echo "$sha" > "$out/sha"
echo "cmux-action-catalog at $sha: $out/lib/libcmux_action_catalog.a"
