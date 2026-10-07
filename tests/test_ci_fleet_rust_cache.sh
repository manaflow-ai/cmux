#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
bin="$tmp/bin"
mkdir -p "$bin"

cat > "$bin/rustc" <<'EOF'
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
EOF
cat > "$bin/rustup" <<'EOF'
#!/usr/bin/env bash
[[ "$*" == "show active-toolchain" ]] && echo '1.88.0-aarch64-apple-darwin (default)' || exit 0
EOF
cat > "$bin/sccache" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$bin"/*
secret="$tmp/rust-cache.env"
cat > "$secret" <<'EOF'
SCCACHE_BUCKET=cmux-rust-sccache
SCCACHE_ENDPOINT=https://example.r2.cloudflarestorage.com
AWS_ACCESS_KEY_ID=dedicated-test-key
AWS_SECRET_ACCESS_KEY=dedicated-test-secret
EOF

PATH="$bin:$PATH" \
CMUX_FLEET_RUST_CACHE=1 \
CMUX_FLEET_WORKER=1 \
CMUX_FLEET_RUST_CACHE_SECRET_FILE="$secret" \
CI_SHARED_CACHE_DIR="$tmp/cache" \
bash -c 'source "$1/scripts/ci/fleet-rust-cache.sh"; [[ "$RUSTC_WRAPPER" == *sccache ]]; [[ "$CARGO_TARGET_DIR" == */rust-targets/1.88.0-aarch64-apple-darwin ]]; [[ "$SCCACHE_NAMESPACE" == cmux-rust-v1-1.88.0-aarch64-apple-darwin-aarch64-apple-darwin ]]' _ "$root"

CMUX_FLEET_RUST_CACHE=0 bash -c 'source "$1/scripts/ci/fleet-rust-cache.sh"' _ "$root"
echo "fleet Rust cache helper tests passed"
