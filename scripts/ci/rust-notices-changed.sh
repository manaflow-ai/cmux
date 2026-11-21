#!/usr/bin/env bash
# The caller checks out the merge commit on PRs. An unavailable base or
# unreadable diff must run the generator. --no-renames checks both paths.
set -eu
if [[ "${1:-}" =~ ^[0-9a-f]{40}$ ]] && git diff --no-ext-diff --no-renames --quiet "$1" "$2" -- \
    ':(glob)**/Cargo.toml' ':(glob)**/Cargo.lock' \
    scripts/cmux-next/remote-browser-host.pin.json cmux-tui/build-support/notices/ \
    scripts/cmux-next/generate-third-party-notices.sh scripts/cmux-next/notices/ \
    Packages/macOS/CmuxNext/Package.resolved scripts/ci/rust-notices-changed.sh \
    .github/workflows/cmux-next-guards.yml; then
  echo 'run=false'
else
  echo 'run=true'
fi
