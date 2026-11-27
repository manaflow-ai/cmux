# 2026-11-26-build-nightly-app-5

Above `- name: Install Zig for fast cmux-tui client` (job `build-nightly-app`) in `.github/workflows/nightly.yml`.

A fast branch dogfood build only needs the arm64 client that is bundled
in this macOS app. Building it here avoids waiting for the full
cross-platform R2 artifact matrix. Main and release keep the immutable
manifest path below, so their machine and distribution artifacts stay
complete.
