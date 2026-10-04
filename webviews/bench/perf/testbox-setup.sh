#!/usr/bin/env bash
# Testbox only: prepares ~/perf (a copy of the synced worktree, the release sidecar, bun,
# Playwright browsers and the fixture repos). Run from the synced worktree root.
set -euo pipefail
[[ "${CMUX_TESTBOX_REMOTE:-}" == 1 ]] || { echo "testbox only" >&2; exit 64; }
mkdir -p ~/perf
rsync -a --delete --exclude node_modules --exclude target --exclude .git ./ ~/perf/cmux/
cd ~/perf/cmux
if ! command -v bun >/dev/null || [[ "$(bun --version)" != 1.4.2 ]]; then
  sudo npm install -g bun@1.4.2 >/dev/null
fi
bun --version
(cd Native/DiffSidecar && cargo build --release --locked --target-dir ~/perf/target 2>&1 | tail -3)
ls -la ~/perf/target/release/cmux-diff-sidecar
(cd webviews && bun install --frozen-lockfile 2>&1 | tail -1)
if [[ ! -f ~/perf/.browsers-ok ]]; then
  (cd webviews && sudo -E env PATH="$PATH" npx playwright install-deps chromium webkit >/dev/null 2>&1 && npx playwright install chromium webkit 2>&1 | tail -2)
  touch ~/perf/.browsers-ok
fi
if [[ ! -d ~/perf/fixtures/huge ]]; then
  python3 webviews/bench/perf/make-fixtures.py ~/perf/fixtures
fi
for name in medium large huge; do
  printf '%s: ' "$name"; git -C ~/perf/fixtures/$name diff --shortstat HEAD~1 HEAD
done
