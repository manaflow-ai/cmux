#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Builds the upstream Cua Driver in-process library (libcua_driver_sdk.dylib,
# C ABI cua_driver_*_v1) from the pinned trycua/cua commit for the cmux
# Computer Use helper v2. Run on cmux-lawrence-2 (nx-remote) or a fleet Mac,
# never on a laptop. Upstream is untrusted: this fetches one exact commit,
# runs only `cargo build --locked`, and never runs an upstream install script.
#
#   build-cua-driver-sdk.sh [--out DIR]     (default $NX_ARTIFACTS or ./out)
#
# Output: cua-driver-sdk-macos-arm64.tar.gz with lib/libcua_driver_sdk.dylib
# (install name @rpath/libcua_driver_sdk.dylib), include/cua_driver_abi.h,
# licenses/ (upstream LICENSE, THIRD_PARTY_NOTICES.md, cargo license list),
# and build-info.json.
set -euo pipefail

UPSTREAM_REPO="https://github.com/trycua/cua.git"
UPSTREAM_TAG="cua-driver-rs-v0.34.0"
UPSTREAM_COMMIT="b0968e1b12834e485dda68789541a3cc57664a9f"
ASSET="cua-driver-sdk-macos-arm64"
# The default Xcode on cmux-lawrence-2 links with ld-27037, whose Rust dylibs
# fail dlopen ("mis-aligned LINKEDIT string pool"). Xcode 26.6 (ld-1267) works.
: "${CUA_SDK_DEVELOPER_DIR:=/Applications/Xcode_26.6.app/Contents/Developer}"

out="${NX_ARTIFACTS:-$PWD/out}"
while (( $# )); do
  case "$1" in
    --out) out="${2:?}"; shift 2 ;;
    *) echo "usage: build-cua-driver-sdk.sh [--out DIR]" >&2; exit 2 ;;
  esac
done
[[ -d "$CUA_SDK_DEVELOPER_DIR" ]] || { echo "error: $CUA_SDK_DEVELOPER_DIR is missing" >&2; exit 1; }
export DEVELOPER_DIR="$CUA_SDK_DEVELOPER_DIR"
export CUA_DRIVER_RS_TELEMETRY_ENABLED=0 CUA_TELEMETRY_ENABLED=false CUA_DRIVER_RS_UPDATE_CHECK=false

work="${CUA_SDK_WORK:-$HOME/cmux-agent-work/cua-driver-sdk/$UPSTREAM_COMMIT}"
src="$work/src"
mkdir -p "$work" "$out"
if [[ ! -d "$src/.git" ]]; then
  rm -rf "$src"
  git init -q "$src"
  git -C "$src" remote add origin "$UPSTREAM_REPO"
fi
if [[ "$(git -C "$src" rev-parse -q --verify HEAD 2>/dev/null)" != "$UPSTREAM_COMMIT" ]]; then
  git -C "$src" fetch -q --depth 1 origin "$UPSTREAM_COMMIT"
  git -C "$src" checkout -q --detach FETCH_HEAD
fi
[[ "$(git -C "$src" rev-parse HEAD)" == "$UPSTREAM_COMMIT" ]] || { echo "error: checkout is not $UPSTREAM_COMMIT" >&2; exit 1; }
# The tag (or, for an annotated tag, its peeled ^{} entry) must name the commit.
if ! git ls-remote "$UPSTREAM_REPO" "refs/tags/$UPSTREAM_TAG" "refs/tags/$UPSTREAM_TAG^{}" | awk '{print $1}' | grep -qx "$UPSTREAM_COMMIT"; then
  echo "error: tag $UPSTREAM_TAG does not resolve to $UPSTREAM_COMMIT" >&2; exit 1
fi

rust="$src/libs/cua-driver/rust"
toolchain="$(cd "$rust" && rustup show active-toolchain 2>/dev/null | awk '{print $1}')"
rustup toolchain list | awk '{print $1}' | grep -qx "$toolchain" ||
  { echo "error: rust toolchain $toolchain is not installed on this host; refusing to download one in a job" >&2; exit 1; }
(cd "$rust" && cargo build --locked --release -p cua-driver-sdk)

lib="$rust/target/release/libcua_driver_sdk.dylib"
[[ -f "$lib" ]] || { echo "error: $lib was not produced" >&2; exit 1; }
stage="$work/stage/$ASSET"
rm -rf "$stage"; mkdir -p "$stage/lib" "$stage/include" "$stage/licenses"
cp "$lib" "$stage/lib/"
install_name_tool -id @rpath/libcua_driver_sdk.dylib "$stage/lib/libcua_driver_sdk.dylib"
codesign --force --sign - "$stage/lib/libcua_driver_sdk.dylib"
cp "$rust/include/cua_driver_abi.h" "$stage/include/"
cp "$src/LICENSE.md" "$stage/licenses/LICENSE-cua.md" 2>/dev/null || cp "$src/LICENSE" "$stage/licenses/LICENSE-cua"
[[ -f "$src/libs/cua-driver/THIRD_PARTY_NOTICES.md" ]] && cp "$src/libs/cua-driver/THIRD_PARTY_NOTICES.md" "$stage/licenses/"
[[ -f "$rust/THIRD_PARTY_NOTICES.md" ]] && cp "$rust/THIRD_PARTY_NOTICES.md" "$stage/licenses/THIRD_PARTY_NOTICES-rust.md"
(cd "$rust" && cargo metadata --locked --format-version 1 --filter-platform aarch64-apple-darwin) |
  /usr/bin/python3 -I -c '
import json, sys
m = json.load(sys.stdin)
for p in sorted(m["packages"], key=lambda p: (p["name"], p["version"])):
    print(" ".join([p["name"], p["version"], p.get("license") or "(license-file)", p.get("repository") or ""]))
' > "$stage/licenses/cargo-dependencies.txt"
[[ " $(lipo -archs "$stage/lib/libcua_driver_sdk.dylib") " == *" arm64 "* ]] || { echo "error: no arm64 slice" >&2; exit 1; }
exports="$(nm -gU "$stage/lib/libcua_driver_sdk.dylib")"
for symbol in cua_driver_abi_version_v1 cua_driver_create_v1 cua_driver_invoke_v1 cua_driver_list_tools_json_v1 cua_driver_buffer_free_v1; do
  grep -q " _${symbol}\$" <<<"$exports" || { echo "error: $symbol is not exported" >&2; exit 1; }
done
/usr/bin/python3 -I - "$stage/build-info.json" "$UPSTREAM_REPO" "$UPSTREAM_TAG" "$UPSTREAM_COMMIT" "$toolchain" "$DEVELOPER_DIR" "$(cd "$rust" && rustc --version)" "$(ld -v 2>&1 | head -1)" <<'PY'
import json, sys
path, repo, tag, commit, toolchain, devdir, rustc, ld = sys.argv[1:]
json.dump({"upstream_repo": repo, "upstream_tag": tag, "upstream_commit": commit,
           "rust_toolchain": toolchain, "rustc": rustc, "developer_dir": devdir, "ld": ld,
           "crate": "cua-driver-sdk", "profile": "release"}, open(path, "w"), indent=2, sort_keys=True)
PY
tar -C "$work/stage" -czf "$out/$ASSET.tar.gz" "$ASSET"
shasum -a 256 "$out/$ASSET.tar.gz" "$stage/lib/libcua_driver_sdk.dylib" "$stage/include/cua_driver_abi.h" | tee "$out/$ASSET.sha256"
