# build-sign-notarize-nightly: ws="${GITHUB_WORKSPACE:-$PWD}"

Where: the `build-sign-notarize-nightly` job in `.github/workflows/nightly.yml`, above `ws="${GITHUB_WORKSPACE:-$PWD}"`.

Self-hosted macOS runners reuse the workspace. A job cancelled or
killed mid-checkout can leave a stale .git/modules/*/index.lock that
fails every later submodule checkout (e.g. ghostty). Clear them first.
