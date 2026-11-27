# 2026-11-26-build-nightly-app-6

Above `CARGO_PROFILE_RELEASE_DEBUG: line-tables-only` (job `build-nightly-app`) in `.github/workflows/nightly.yml`.

Line tables in a separate .dSYM next to each binary, for Sentry:
the bundled binary is stripped (strip-release-bundle.sh), so without these a
crash in cmux-tui, its host or acpmux (linked into the same binary) shows no
function, file or line. The shipped binary does not grow.
