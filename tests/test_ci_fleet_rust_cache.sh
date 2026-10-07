#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
bin="$tmp/bin"
manifest="$tmp/cmux-tui"
mkdir -p "$bin" "$manifest"

cat > "$bin/rustc" <<'STUB'
#!/usr/bin/env bash
cat <<'OUT'
rustc 1.88.0 (stable)
binary: rustc
commit-hash: test
commit-date: test
host: aarch64-apple-darwin
release: 1.88.0
LLVM version: 20.1.8
OUT
STUB
cat > "$bin/rustup" <<'STUB'
#!/usr/bin/env bash
[[ "$*" == "show active-toolchain" ]] && echo '1.88.0-aarch64-apple-darwin (directory override)' || exit 0
STUB
chmod +x "$bin"/*

# Resolver uses the manifest-selected toolchain, compiler identity, project and
# target triple, and never reads a worker secret or mutates cache credentials.
out="$(env -i PATH="$bin:/usr/bin:/bin" HOME="$tmp/home" \
  CMUX_FLEET_RUST_TARGET_ROOT="$tmp/rust-targets" \
  bash -c 'source "$1/scripts/ci/fleet-rust-cache.sh"; \
    [[ -z "${RUSTC_WRAPPER:-}" && -z "${AWS_SECRET_ACCESS_KEY:-}" ]]; \
    fleet_rust_target_dir acpmux aarch64-apple-darwin "$2"; \
    fleet_rust_target_dir acpmux x86_64-apple-darwin "$2"; \
    fleet_rust_target_dir chief aarch64-apple-darwin "$2"' _ "$root" "$manifest" 2>/dev/null)"
expected="$tmp/rust-targets/acpmux/1.88.0-aarch64-apple-darwin-1.88.0-aarch64-apple-darwin/aarch64-apple-darwin"
expected_x86="$tmp/rust-targets/acpmux/1.88.0-aarch64-apple-darwin-1.88.0-aarch64-apple-darwin/x86_64-apple-darwin"
expected_chief="$tmp/rust-targets/chief/1.88.0-aarch64-apple-darwin-1.88.0-aarch64-apple-darwin/aarch64-apple-darwin"
[[ "$(printf '%s\n' "$out" | sed -n '1p')" == "$expected" ]] || { echo "unexpected acpmux target: $out" >&2; exit 1; }
[[ "$(printf '%s\n' "$out" | sed -n '2p')" == "$expected_x86" ]] || { echo "unexpected cross target: $out" >&2; exit 1; }
[[ "$(printf '%s\n' "$out" | sed -n '3p')" == "$expected_chief" ]] || { echo "unexpected chief target: $out" >&2; exit 1; }
[[ ! -e "$tmp/rust-targets" ]] || { echo "resolver created target directories" >&2; exit 1; }

# Slugs cannot escape the configured root, and missing manifest toolchains fail.
if env -i PATH="$bin:/usr/bin:/bin" HOME="$tmp/home" CMUX_FLEET_RUST_TARGET_ROOT="$tmp/rust-targets" \
    bash -c 'source "$1/scripts/ci/fleet-rust-cache.sh"; fleet_rust_target_dir ../escape aarch64-apple-darwin "$2"' _ "$root" "$manifest" >/dev/null 2>&1; then
  echo "accepted a path-like project name" >&2
  exit 1
fi
if env -i PATH="$bin:/usr/bin:/bin" HOME="$tmp/home" CMUX_FLEET_RUST_TARGET_ROOT="$tmp/rust-targets" \
    bash -c 'source "$1/scripts/ci/fleet-rust-cache.sh"; fleet_rust_target_dir acpmux "$2" "$3"' _ "$root" 'x/y' "$manifest" >/dev/null 2>&1; then
  echo "accepted a path-like target" >&2
  exit 1
fi

# Managed integration is explicit; no worker marker leaves existing defaults in
# place. These checks protect against restoring global CARGO_TARGET_DIR exports.
grep -q 'CMUX_FLEET_WORKER_TRUSTED' "$root/scripts/cmux-next/build-acpmux.sh"
grep -q 'CMUX_FLEET_WORKER_TRUSTED' "$root/scripts/cmux-next/build-optchat-chief.sh"
grep -q 'CMUX_FLEET_WORKER_TRUSTED' "$root/scripts/ci/cmux-tui-rust-check.sh"
! grep -q 'CMUX_FLEET_RUST_CACHE_SECRET_FILE' "$root/scripts/ci/fleet-rust-cache.sh"
! grep -q 'SCCACHE_NAMESPACE' "$root/scripts/ci/fleet-rust-cache.sh"

echo "fleet Rust target resolver tests passed"
