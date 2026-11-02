#!/usr/bin/env bash
# Mints a new cmux VM service key (src/auth/service-keys.ts) for a service that calls this API, and
# puts each half where it belongs without anyone seeing it:
#   - the raw key goes to the calling service's Worker secret (wrangler secret put, on stdin);
#   - its entry, the JSON array [{id, sha256, scopes, labels, teams: null}], goes to a GitHub
#     environment secret of manaflow-ai/cmux (gh secret set, on stdin), which deploy.sh appends to
#     the cmux-vm Worker's CMUX_VM_SERVICE_KEYS on the next deploy of that environment.
# The key and its hash live only in this shell's memory: never in argv, a file or the output.
# It refuses when the GitHub secret already exists (it never overwrites a write-only entry), and
# when the Worker secret exists unless --replace-worker-secret says to replace it.
#
#   bash scripts/mint-service-key.sh --id cloud-platform-staging --github-env cmux-vm-staging \
#     --github-secret CMUX_VM_SERVICE_KEYS_CLOUD_PLATFORM_STAGING \
#     --worker cmux-platform-staging --worker-secret CLOUD_VM_API_SERVICE_KEY
#
# The cmux-vm Worker learns the hash only when that environment deploys again (deploy.sh), so the
# calling service gets 401 from the moment its Worker secret changes until then. A new service id
# also has to be listed wherever images or the mesh name services (wrangler.jsonc).
# Needs gh (signed in, admin on the repo), wrangler signed in to the calling Worker's account
# (WRANGLER overrides the command), openssl and jq.
set -euo pipefail

repo="manaflow-ai/cmux"
id="" github_env="" github_secret="" worker="" worker_secret="" replace_worker=0
# The calls cmux-platform's Cloud driver makes (src/server/cloud/vmapi in cmux-platform): VMs,
# exec, files, HTTPS proxies, snapshots and the team mesh. It only ever touches VMs labelled role=cloud.
scopes="vm:read,vm:write,vm:exec,vm:files,vm:network,snapshot:*,mesh:read,mesh:write"
labels="role=cloud"

usage() {
  echo "usage: $0 --id ID --github-env ENV --github-secret NAME --worker WORKER --worker-secret NAME [--scopes a,b] [--labels k=v,...] [--repo OWNER/REPO] [--replace-worker-secret]" >&2
  exit 2
}
while [ "$#" -gt 0 ]; do
  case "$1" in
    --id) id="${2:-}"; shift 2 ;;
    --github-env) github_env="${2:-}"; shift 2 ;;
    --github-secret) github_secret="${2:-}"; shift 2 ;;
    --worker) worker="${2:-}"; shift 2 ;;
    --worker-secret) worker_secret="${2:-}"; shift 2 ;;
    --scopes) scopes="${2:-}"; shift 2 ;;
    --labels) labels="${2:-}"; shift 2 ;;
    --repo) repo="${2:-}"; shift 2 ;;
    --replace-worker-secret) replace_worker=1; shift ;;
    *) usage ;;
  esac
done
for v in id github_env github_secret worker worker_secret scopes labels; do
  [ -n "${!v}" ] || usage
done

die() { echo "mint-service-key: $*" >&2; exit 1; }
[[ "$id" =~ ^[a-z][a-z0-9-]{0,39}$ ]] || die "--id must match ^[a-z][a-z0-9-]{0,39}\$"
[[ "$github_secret" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "--github-secret is not a secret name"
[[ "$worker_secret" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "--worker-secret is not a secret name"
scopes_json="$(jq -cn --arg s "$scopes" '$s | split(",") | map(select(length > 0))')"
jq -e 'length > 0 and (index("admin") | not)' <<<"$scopes_json" >/dev/null || die "--scopes needs at least one scope and never admin"
labels_json="$(jq -cn --arg l "$labels" '$l | split(",") | map(select(length > 0) | capture("^(?<key>[^=]+)=(?<value>.+)$")) | from_entries')" \
  || die "--labels must be k=v pairs"
jq -e 'length > 0' <<<"$labels_json" >/dev/null || die "--labels needs at least one k=v (a key with none would reach every VM)"
for tool in gh jq openssl; do command -v "$tool" >/dev/null || die "$tool is not installed"; done
here="$(cd "$(dirname "$0")/.." && pwd)"
if [ -z "${WRANGLER:-}" ]; then
  [ -x "$here/node_modules/.bin/wrangler" ] || die "run bun install in workers/cmux-vm first (or set WRANGLER)"
  WRANGLER="$here/node_modules/.bin/wrangler"
fi

# Refuse before minting anything.
existing="$(gh secret list --env "$github_env" --repo "$repo" --json name --jq '.[].name')" \
  || die "could not list the $github_env secrets of $repo"
if grep -qx -- "$github_secret" <<<"$existing"; then
  die "$github_secret already exists in $repo environment $github_env; refusing to overwrite it (append another secret instead)"
fi
# wrangler runs outside this package so the cmux-vm config never applies to the other Worker.
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
worker_names="$(cd "$scratch" && $WRANGLER secret list --name "$worker" --format json </dev/null | jq -r '.[].name')" \
  || die "could not list the secrets of Worker $worker"
if grep -qx -- "$worker_secret" <<<"$worker_names" && [ "$replace_worker" -ne 1 ]; then
  die "Worker $worker already has $worker_secret; pass --replace-worker-secret to replace it"
fi

# cmuxvm_sk_ + 32 random bytes, base64url without padding (src/auth/credentials.ts generateApiKey).
key="cmuxvm_sk_$(openssl rand 32 | openssl base64 -A | tr '+/' '-_' | tr -d '=')"
[[ "$key" =~ ^cmuxvm_sk_[A-Za-z0-9_-]{43}$ ]] || die "generated key has the wrong shape"
# Lowercase hex SHA-256 of the whole key string (src/auth/credentials.ts hashApiKey).
sha="$(printf '%s' "$key" | openssl dgst -sha256 -r | cut -c1-64)"
[[ "$sha" =~ ^[0-9a-f]{64}$ ]] || die "could not hash the key"

# The entry first: if the Worker secret then fails, nothing calls with a key cmux-vm will not know,
# and the GitHub secret is the one to delete before a retry.
printf '%s' "$sha" | jq -Rc --arg id "$id" --argjson scopes "$scopes_json" --argjson labels "$labels_json" \
  '[{id: $id, sha256: ., scopes: $scopes, labels: $labels, teams: null}]' \
  | gh secret set "$github_secret" --env "$github_env" --repo "$repo" >/dev/null
echo "set $repo environment $github_env secret $github_secret (service key id $id)"
printf '%s' "$key" | (cd "$scratch" && $WRANGLER secret put "$worker_secret" --name "$worker" >/dev/null)
echo "set Worker $worker secret $worker_secret"
unset key sha
echo "ok"
