# 2026-11-28-build-nightly-ghostty-cli-helper-install-zig

Where: `.github/workflows/nightly.yml`, job `build-nightly-ghostty-cli-helper`, step "Install Zig": above `export ZIG_KEEP_DIR="$HOME/Library/Caches/cmux-ci/zig"`.

The verified, patched Zig install itself, at its version-pinned path: a warm Mac reuses it with no download or extraction (install-zig-ci.sh ZIG_KEEP_DIR; 2.6 min cold in run 45562645699).
