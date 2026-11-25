#!/usr/bin/env bash
# Builds the cmux-motion C ABI (`CCmuxMotionFFI`: cmux-app-ffi's modules over cmux-tui's cmux-motion crate) as a
# Linux static library at the commit the app's CCmuxAppFFI pin was built from, with its header and a module map. The Linux settings exporter
# (regenerate-settings-exports-linux.sh) links it in place of the xcframework, so the motion values the settings
# read (the tab strip's widths, the springs) are the pinned Rust ones, as on the Mac.
#
#   build-motion-ffi-linux.sh OUT_DIR [SHA]
#
# SHA defaults to the pin's (Packages/macOS/CmuxNext/app-ffi-pin.json). cmux-motion has no dependency once its
# `settings` feature (the system Reduce Motion reader) is off, as cmux-app-ffi builds it, so the two crates build
# alone and offline.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
out="${1:?usage: build-motion-ffi-linux.sh OUT_DIR [SHA]}"
sha="${2:-}"
if [ -z "$sha" ]; then
  sha="$(python3 -c 'import json,re,sys; u=json.load(open(sys.argv[1]))["url"]; print(re.search(r"cmux-app-ffi-([0-9a-f]{40})/", u).group(1))' \
    "$root/Packages/macOS/CmuxNext/app-ffi-pin.json")"
fi
crates=cmux-tui/crates
if ! git -C "$root" cat-file -e "$sha^{commit}" 2>/dev/null; then
  git -C "$root" fetch --quiet --no-tags --depth 1 --filter=blob:none origin "$sha"
fi
mkdir -p "$out"
out="$(cd "$out" && pwd)"
work="$out/src-$sha"
# The repository's layout, for cmux-motion's build script (it reads plans/'s design tokens by relative path).
ffi="$work/$crates/cmux-motion-ffi"
if [ ! -f "$ffi/Cargo.toml" ]; then
  rm -rf "$work.partial"
  mkdir -p "$work.partial/$crates/cmux-motion-ffi/src" "$work.partial/include"
  git -C "$root" archive "$sha" "$crates/cmux-motion" plans/cmux-next/spec-proposals/visuals/design-tokens.json | tar -x -C "$work.partial"
  # The modules over cmux-motion that SHA has (goo came after some pins); a test file is copied for its `mod`.
  modules=()
  for module in goo hover motion terminal_selection terminal_selection_tests; do
    git -C "$root" cat-file -e "$sha:$crates/cmux-app-ffi/src/$module.rs" 2>/dev/null || continue
    git -C "$root" show "$sha:$crates/cmux-app-ffi/src/$module.rs" > "$work.partial/$crates/cmux-motion-ffi/src/$module.rs"
    case "$module" in *_tests) ;; *) modules+=("$module") ;; esac
  done
  git -C "$root" show "$sha:$crates/cmux-app-ffi/include/cmux_motion_ffi.h" > "$work.partial/include/cmux_motion_ffi.h"
  # cmux-motion's manifest with the workspace keys written out, and without what only the `settings` feature, the
  # tests and the examples read.
  python3 - "$work.partial/$crates/cmux-motion/Cargo.toml" <<'PY'
import re, sys
path = sys.argv[1]
text = open(path).read()
text = text.replace("edition.workspace = true", 'edition = "2024"')
text = re.sub(r"(?m)^(rust-version|license|publish)\.workspace = true\n", "", text)
text = re.sub(r"(?ms)^\[lints\]\nworkspace = true\n", "", text)
text = re.sub(r'(?m)^settings = \[.*\]\n', "settings = []\n", text)
text = re.sub(r"(?ms)^\[(dev-dependencies|target\.[^\]]*\.dependencies)\]\n.*?(?=^\[|\Z)", "", text)
text = re.sub(r"(?ms)^\[\[(example|test|bench)\]\]\n.*?(?=^\[|\Z)", "", text)
text = text.replace("[package]\n", "[package]\nautoexamples = false\nautotests = false\nautobenches = false\n", 1)
open(path, "w").write(text)
PY
  cat > "$work.partial/$crates/cmux-motion-ffi/Cargo.toml" <<'TOML'
[package]
name = "cmux_motion_ffi"
version = "0.1.0"
edition = "2024"

[lib]
crate-type = ["staticlib"]

[dependencies]
cmux-motion = { path = "../cmux-motion", default-features = false }

[workspace]
TOML
  printf 'pub mod %s;\n' "${modules[@]}" > "$work.partial/$crates/cmux-motion-ffi/src/lib.rs"
  git -C "$root" show "$sha:cmux-tui/rust-toolchain.toml" > "$work.partial/$crates/cmux-motion-ffi/rust-toolchain.toml" 2>/dev/null || true
  mv "$work.partial" "$work"
fi
# The swift image has clang but no `cc`, which rustc links with.
if ! command -v cc >/dev/null && command -v clang >/dev/null; then
  export CC=clang
  export CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_LINKER=clang CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER=clang
fi
(cd "$ffi" && CARGO_TARGET_DIR="$out/target" cargo build --quiet --release --offline --manifest-path "$ffi/Cargo.toml")
mkdir -p "$out/lib" "$out/include"
cp "$out/target/release/libcmux_motion_ffi.a" "$out/lib/"
cp "$work/include/cmux_motion_ffi.h" "$out/include/"
cat > "$out/include/module.modulemap" <<'MAP'
module CCmuxMotionFFI {
    header "cmux_motion_ffi.h"
    link "cmux_motion_ffi"
    export *
}
MAP
echo "$sha" > "$out/sha"
echo "cmux-motion ffi at $sha: $out/lib/libcmux_motion_ffi.a"
