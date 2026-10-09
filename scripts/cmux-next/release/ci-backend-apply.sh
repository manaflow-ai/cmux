#!/usr/bin/env bash
# The label apply of .github/workflows/backend-migrations.yml, routed through the release rails
# (plans/cmux-next/release-rails.md): lint, owner check, a rehearsal of the exact set on a
# throwaway PlanetScale branch in the same run, then the apply, with a receipt.
#
#   ci-backend-apply.sh staging|production <head-migrations dir>
#
# Runs from the TRUSTED base checkout (this file and the rails come from the PR base). The PR head
# gives only SQL files (data). A candidate root is built from the base's lock and role contract plus
# the head's SQL; `lint.ts --update-lock` adds new passing files and refuses edited landed ones.
# Needs CMUX_NEXT_PG_MIGRATOR_URL (owner) and a PlanetScale service token (PLANETSCALE_SERVICE_TOKEN_ID,
# PLANETSCALE_SERVICE_TOKEN; pscale reads them) for the rehearsal branch. Production needs
# CMUX_NEXT_STAGING_MIGRATOR_URL too, and db-release refuses a candidate root for production
# (production applies only landed files), so the production job refuses until that path exists.
set -euo pipefail
target="${1:?usage: ci-backend-apply.sh staging|production <head-migrations dir>}"
head_dir="${2:?head-migrations dir}"
rails="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$rails/../../.." && pwd)"

for v in CMUX_NEXT_PG_MIGRATOR_URL PLANETSCALE_SERVICE_TOKEN_ID PLANETSCALE_SERVICE_TOKEN; do
  if [ -z "${!v:-}" ]; then
    echo "::error title=Release rails::$v is not set in this environment; the rails refuse to apply without it (a PlanetScale service token is a credential: ask the chief)"
    exit 1
  fi
done

work="${RUNNER_TEMP:-$(mktemp -d)}/release-rails"
cand="$work/candidate"
rm -rf "$cand" && mkdir -p "$cand/backend/db/migrations" "$cand/scripts/cmux-next/release"
cp "$head_dir"/*.sql "$cand/backend/db/migrations/"
cp "$repo/scripts/cmux-next/release/migrations.lock.json" "$repo/scripts/cmux-next/release/role-contract.json" "$cand/scripts/cmux-next/release/"
export CMUX_RELEASE_RECEIPTS_DIR="$work/receipts"

(cd "$rails" && bun install --frozen-lockfile >/dev/null)
cd "$rails"
bun lint.ts --root "$cand" --tree backend --update-lock
args=(apply --tree backend --target "$target" --url-env CMUX_NEXT_PG_MIGRATOR_URL --root "$cand")
if [ "$target" = production ]; then args+=(--confirm-production --staging-url-env CMUX_NEXT_STAGING_MIGRATOR_URL); fi
bun db-release.ts "${args[@]}"
