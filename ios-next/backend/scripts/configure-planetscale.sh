#!/usr/bin/env bash
# Creates the PlanetScale MySQL database for cmux-next-mobile, stores its
# credentials as Worker secrets and applies migrations.
#
#   scripts/configure-planetscale.sh --dry-run   # show the plan, change nothing
#   scripts/configure-planetscale.sh --yes       # do it (creating a database is billed)
#
# Requires: `pscale auth login` done, wrangler logged in to the Cloudflare
# account in wrangler.toml, and the Worker already deployed once.
#
# Environment overrides:
#   PSCALE_ORG            organization (default: pscale's current org)
#   PSCALE_DATABASE       database name (default: cmux-next-mobile)
#   PSCALE_REGION         region slug (default: us-west)
#   PSCALE_CLUSTER_SIZE   cluster size (default: cheapest MySQL size in the region)
#
# Secret values never reach stdout: they go from pscale's JSON output into a
# private temp file, then through stdin into `wrangler secret put`.
set -euo pipefail

BACKEND_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PSCALE="${PSCALE_BIN:-$(command -v pscale || echo /opt/homebrew/bin/pscale)}"
DB="${PSCALE_DATABASE:-cmux-next-mobile}"
BRANCH="main"
REGION="${PSCALE_REGION:-us-west}"
SIZE="${PSCALE_CLUSTER_SIZE:-}"
ORG_ARGS=()
[[ -n "${PSCALE_ORG:-}" ]] && ORG_ARGS=(--org "$PSCALE_ORG")

MODE=""
for arg in "$@"; do
  case "$arg" in
    --dry-run) MODE="dry" ;;
    --yes) MODE="run" ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done
if [[ -z "$MODE" ]]; then
  echo "Pass --dry-run to see the plan or --yes to create billed PlanetScale resources." >&2
  exit 2
fi

ps() { "$PSCALE" "$@" ${ORG_ARGS[@]+"${ORG_ARGS[@]}"}; }
wrangler() { (cd "$BACKEND_DIR" && npx --no-install wrangler "$@"); }

TMP="$(mktemp -d)"
chmod 700 "$TMP"
trap 'rm -rf "$TMP"' EXIT

# json_get FILE KEY...: prints the first present top-level key's value.
json_get() {
  node -e '
    const d = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    for (const k of process.argv.slice(2)) if (d[k] != null && d[k] !== "") { process.stdout.write(String(d[k])); process.exit(0); }
    process.exit(1);
  ' "$@"
}

cheapest_size() {
  ps size cluster list --engine mysql --region "$REGION" --format json > "$TMP/sizes.json"
  node -e '
    const list = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    const price = (s) => { for (const k of ["rate", "price", "monthly_rate", "cost", "display_price"]) { const n = parseFloat(String(s[k] ?? "").replace(/[^0-9.]/g, "")); if (!isNaN(n)) return n; } return NaN; };
    const usable = list.filter((s) => s.enabled !== false && !isNaN(price(s)));
    if (!usable.length) process.exit(1);
    usable.sort((a, b) => price(a) - price(b));
    process.stdout.write(usable[0].name ?? usable[0].slug);
  ' "$TMP/sizes.json"
}

echo "PlanetScale database: $DB (mysql, region $REGION, branch $BRANCH)"

if [[ "$MODE" == "dry" ]]; then
  cat <<PLAN
Plan (no changes made):
  1. $PSCALE auth check
  2. $PSCALE database show $DB  (skip creation when it exists)
  3. $PSCALE database create $DB --engine mysql --region $REGION --cluster-size ${SIZE:-<cheapest from 'pscale size cluster list --engine mysql --region $REGION'>} --wait
  4. $PSCALE password create $DB $BRANCH worker-<timestamp> --role readwriter --format json
  5. wrangler secret put DATABASE_HOST / DATABASE_USERNAME / DATABASE_PASSWORD  (values via stdin)
  6. $PSCALE password create $DB $BRANCH migrate-<timestamp> --role admin --ttl 1h --format json
  7. npx tsx scripts/migrate.ts  (with the admin password in its environment only)
PLAN
  (cd "$BACKEND_DIR" && npx --no-install tsx scripts/migrate.ts --dry-run)
  exit 0
fi

if ! ps auth check >/dev/null 2>&1; then
  echo "pscale is not logged in. Run: $PSCALE auth login" >&2
  exit 1
fi

if ps database show "$DB" --format json >/dev/null 2>&1; then
  echo "Database $DB already exists; reusing it."
else
  if [[ -z "$SIZE" ]]; then
    if ! SIZE="$(cheapest_size)"; then
      echo "Could not determine the cheapest MySQL cluster size. Pick one and rerun with PSCALE_CLUSTER_SIZE=<size>:" >&2
      ps size cluster list --engine mysql --region "$REGION" >&2 || true
      exit 1
    fi
  fi
  echo "Creating $DB with cluster size $SIZE (billed by PlanetScale)..."
  ps database create "$DB" --engine mysql --region "$REGION" --cluster-size "$SIZE" --wait
fi

STAMP="$(date +%Y%m%d%H%M%S)"

echo "Creating the Worker's readwriter password..."
ps password create "$DB" "$BRANCH" "worker-$STAMP" --role readwriter --format json > "$TMP/worker.json"
set_secret() {
  local name="$1"; shift
  json_get "$TMP/worker.json" "$@" | wrangler secret put "$name" >/dev/null
  echo "  set Worker secret $name"
}
set_secret DATABASE_HOST access_host_url host
set_secret DATABASE_USERNAME username
set_secret DATABASE_PASSWORD plain_text password

echo "Creating a 1-hour admin password for migrations..."
ps password create "$DB" "$BRANCH" "migrate-$STAMP" --role admin --ttl 1h --format json > "$TMP/migrate.json"
(
  cd "$BACKEND_DIR"
  DATABASE_HOST="$(json_get "$TMP/migrate.json" access_host_url host)" \
  DATABASE_USERNAME="$(json_get "$TMP/migrate.json" username)" \
  DATABASE_PASSWORD="$(json_get "$TMP/migrate.json" plain_text password)" \
    npx --no-install tsx scripts/migrate.ts
)

echo "Done. Check: curl -s https://cmux-next-mobile.cmux-presence-worker.workers.dev/v1/health"
