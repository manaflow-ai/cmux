# build-nightly-app: Install Zig for fast cmux-tui client

Where: the `build-nightly-app` job in `.github/workflows/nightly.yml`, above `- name: Install Zig for fast cmux-tui client`.

A fast branch dogfood build only needs the arm64 client that is bundled
in this macOS app. Building it here avoids waiting for the full
cross-platform R2 artifact matrix. Main and release keep the immutable
manifest path below, so their machine and distribution artifacts stay
complete.
