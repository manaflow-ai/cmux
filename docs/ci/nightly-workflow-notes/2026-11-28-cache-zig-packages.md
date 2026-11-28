# 2026-11-28-cache-zig-packages

Where: `.github/workflows/nightly.yml`, Cache Zig packages.

The verified, patched Zig install itself, at its version-pinned path: a warm Mac reuses it with no download or extraction (install-zig-ci.sh ZIG_KEEP_DIR; 2.6 min cold in run 45562645699).
