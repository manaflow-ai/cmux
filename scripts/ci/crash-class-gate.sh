#!/usr/bin/env bash
# The cmux-next crash-class rules job (cmux-next-crash-class.yml).
#
#   scripts/ci/crash-class-gate.sh [--pr]
#
# --pr: the checkout is a pull request's merge commit, and only findings in the
# files the PR changes fail it (scripts/ci/pr_owned_findings.py), plus a generic
# class whose `generic context:` (the declaration that makes its extension
# generic) is in such a file. The base push run keeps the whole-tree verdict, so
# a violation that lands still shows red.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
if [ "${1:-}" != --pr ]; then
  CHECK_CONCURRENCY_ONLY=crash-class exec scripts/cmux-next/check-concurrency.sh "$ROOT/Packages/macOS/CmuxNext"
fi
log="$(mktemp)"
trap 'rm -f "$log"' EXIT
CHECK_CONCURRENCY_ONLY=crash-class scripts/cmux-next/check-concurrency.sh "$ROOT/Packages/macOS/CmuxNext" 2>&1 | tee "$log" \
  && exit 0
python3 scripts/ci/pr_owned_findings.py \
  --finding '^concurrency: (?P<path>[^:]+):\d+: ' \
  --context 'generic context: (?P<path>[^\s:;)]+):\d+' \
  --prefix Packages/macOS/CmuxNext/ \
  --summary '^check-concurrency: (?P<count>\d+) violation' \
  --manifests '^Packages/macOS/CmuxNext/Package\.swift$' \
  --rules '^(scripts/cmux-next/(check-concurrency\.sh|check-main-actor-work\.py|swift_scope\.py)|scripts/ci/(crash-class-gate\.sh|pr_owned_findings\.py)|Packages/macOS/CmuxNext/Package\.swift|\.github/workflows/cmux-next-crash-class\.yml)$' \
  "$log"
