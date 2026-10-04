#!/usr/bin/env bash
# Every check that keeps committed generated output in sync with its sources: the coordination
# index (plans/cmux-next/coordination/INDEX.md), the page strings
# (webviews/scripts/pages/gen-strings.mjs), the React pages bundle, the webviews app, the agent
# pane and Agent Activity. safe-push.sh runs these before a push to feat-cmux-next, and
# .github/workflows/cmux-next-web-bundles.yml runs this script on pull requests into feat-cmux-next
# and on its pushes (#17241 merged stale Settings strings because no PR check ran them).
# Every check runs; the script fails when any failed and names them.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
checks=(
  ".|python3 scripts/cmux-next/generate-coordination-index.py --check"
  "webviews|node scripts/pages/gen-strings.mjs --check"
  ".|./scripts/cmux-next/build-pages-web.sh --check"
  ".|./scripts/build-webviews-app.sh --check"
  ".|./scripts/cmux-next/build-agent-pane-web.sh --check"
  ".|./scripts/cmux-next/build-agent-activity-web.sh --check"
)
failed=()
for entry in "${checks[@]}"; do
  dir="${entry%%|*}"; command="${entry#*|}"
  echo "::group::$command (in $dir)"
  # shellcheck disable=SC2086 # each command is a fixed list of words above
  if ! (cd "$ROOT/$dir" && $command); then
    failed+=("$command (in $dir)")
  fi
  echo "::endgroup::"
done
if [ "${#failed[@]}" -gt 0 ]; then
  printf '::error::stale generated web output: %s\n' "${failed[@]}"
  echo "Regenerate in the same commit: ./scripts/cmux-next/regenerate-web-bundles.sh, ./scripts/cmux-next/build-pages-web.sh, 'node scripts/pages/gen-strings.mjs' in webviews/, and scripts/cmux-next/generate-coordination-index.py." >&2
  exit 1
fi
echo "coordination index, page strings and web bundles: up to date"
