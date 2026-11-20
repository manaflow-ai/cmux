#!/usr/bin/env bash
# nightly.yml wake-nightly-next-tick: "Retry the commit that left the slot unless nightly-next moved".
# nightly-next-one's leave step (resolve-leave-build-slot.sh, IN_SLOT=1) no longer waits on the signing Mac for main's
# tick to promote: it asks the tick and leaves with pending=true. This job runs on a nightly-only mini, so the wait
# moves off the signing Mac: unless nightly-next already moved past TIP_SHA, it dispatches the loop's retry of
# TIP_SHA. That retry's resolve leaves at once once nightly-next moves (the tick promoted), else waits there up to
# YIELD_MINUTES and then builds TIP_SHA, as the leave step did before. Main's tick counts that retry of its own head
# as no holder while a newer commit waits (nightly_next_rolling.retry_of), so it never holds back the promotion.
# Env: TIP_SHA, REPOSITORY (owner/name), GH_TOKEN; RETRY (this run's nightly_next_loop_retry, empty for a push run).
set -euo pipefail
# shellcheck source=scripts/cmux-next/lib/origin-net.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../cmux-next/lib/origin-net.sh"
tries=1
if [[ "${RETRY:-}" =~ ^[0-9]+$ ]]; then tries=$(( RETRY + 1 )); fi
if (( tries > 2 )); then
  echo "::warning::the loop's last retry left the slot; the next promotion builds the newest commit"
  exit 0
fi
head=""
if refs="$(remote_refs . "${NIGHTLY_NEXT_REMOTE:-https://github.com/$REPOSITORY}" refs/heads/nightly-next)"; then
  head="$(printf '%s\n' "$refs" | cut -f1)"
fi
if [[ "$head" =~ ^[0-9a-f]{40}$ && "$head" != "$TIP_SHA" ]]; then
  echo "nightly-next moved to $head: its push run builds it, so no retry of $TIP_SHA"
  exit 0
fi
# Unread counts as not moved: a retry whose head moved leaves in resolve at once.
echo "nightly-next is ${head:-unreadable}: retry $tries of 2 builds $TIP_SHA unless the tick promotes a newer commit first"
gh workflow run nightly.yml --repo "$REPOSITORY" --ref nightly-next -f nightly_next_loop_retry="$tries"
