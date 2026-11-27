# 2026-11-27-build-nightly-app-8

Above `ZIG_FORCE_LOCAL_INSTALL: "1"` (job `build-nightly-app`) in `.github/workflows/nightly.yml`.

Job-local install: this warm mini also runs classic jobs that need
the Zig 0.16.0 in /usr/local/bin, so never replace it from here.
