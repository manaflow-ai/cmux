#!/usr/bin/env bash
# The Cloud inner loop: put this worktree's backend on your own dev Worker and run the Cloud journey on it.
#
#   scripts/cmux-next/cloud-dev-loop.sh --tag leo1                          # cmux-api from this worktree
#   scripts/cmux-next/cloud-dev-loop.sh --tag leo1 --platform-checkout ~/w/cmux-platform-branch
#   scripts/cmux-next/cloud-dev-loop.sh --tag leo1 --no-deploy -- --skip chat,pause   # journey only
#
# 1. --platform-checkout DIR: deploys that cmux-platform worktree as cmux-platform-preview-<tag> on its
#    development config (`wrangler deploy --env development --name ...`; its own Durable Object state).
# 2. Deploys backend/apps/api as cmux-api-preview-<tag> (backend/scripts/deploy-worker.sh preview-<tag>,
#    development config; with step 1 its PLATFORM binding and CLOUD_DO point at that platform preview).
# 3. Runs `bun scripts/cmux-next/cloud-journey.ts --backend preview-<tag>` with the words after `--`.
# Each part's seconds and the total are printed at the end (the loop time this exists to keep small).
# Machine-side changes (cmux-tui, cmux-host, acpmux) iterate on one kept Cloud machine instead:
# scripts/cmux-next/cloud-devloop.ts (build on fleet Linux, patch-push, restart, journey on that machine).
#
# Needs: the cf CLI signed in (deploy-worker.sh reads its OAuth token) or CLOUDFLARE_API_TOKEN;
# ~/.secrets/cmux-next-api-preview.env (JWT_PRIVATE_JWK), as for any preview; the agent test account in
# CMUX_DOGFOOD_STACK_EMAIL/_PASSWORD or --credentials FILE (the dev Stack project's pair). Remove the
# Workers when done: `wrangler delete --name cmux-api-preview-<tag>` (and the platform one).
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tag="" platform="" deploy=1 creds=""
while [ $# -gt 0 ]; do
  case "$1" in
    --tag) tag="$2"; shift 2 ;;
    --platform-checkout) platform="$2"; shift 2 ;;
    --no-deploy) deploy=0; shift ;;
    --credentials) creds="$2"; shift 2 ;;
    --) shift; break ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "unknown argument $1 (journey arguments go after --)" >&2; exit 2 ;;
  esac
done
case "$tag" in ""|*[!a-z0-9-]*) echo "--tag NAME: lowercase letters, digits and -" >&2; exit 2 ;; esac
now() { python3 -c 'import time; print(time.time())'; }
secs() { python3 -c "print(f'{$2 - $1:.1f}')"; }
t0="$(now)"; tp="$t0"; ta="$t0"
if [ "$deploy" = 1 ] && [ -n "$platform" ]; then
  echo "== deploy cmux-platform-preview-$tag from $platform"
  (cd "$platform" && bun install --frozen-lockfile >/dev/null && ./node_modules/.bin/wrangler deploy --env development --name "cmux-platform-preview-$tag" --var "COMMIT_SHA:$(git rev-parse HEAD)")
  export CMUX_PREVIEW_PLATFORM_WORKER="cmux-platform-preview-$tag"
fi
tp="$(now)"
if [ "$deploy" = 1 ]; then
  echo "== deploy cmux-api-preview-$tag"
  (cd "$root/backend" && bun install --frozen-lockfile >/dev/null && bash scripts/deploy-worker.sh "preview-$tag")
fi
ta="$(now)"
echo "== journey on preview-$tag"
status=0
bun "$root/scripts/cmux-next/cloud-journey.ts" --backend "preview-$tag" ${creds:+--credentials "$creds"} "$@" || status=$?
t1="$(now)"
echo "loop: platform deploy $(secs "$t0" "$tp") s, api deploy $(secs "$tp" "$ta") s, journey $(secs "$ta" "$t1") s, total $(secs "$t0" "$t1") s"
exit "$status"
