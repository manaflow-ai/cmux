#!/usr/bin/env bash
# A per-tag cmux-next backend on the GCP dev VM: this worktree's unmerged API (backend/apps/api) under
# `wrangler dev` (real workerd, local Durable Objects), reached over the tailnet. Zero Workers deployed.
#
#   scripts/cmux-next/cloud-dev-stack.sh up --tag T [--platform-checkout DIR] [--db auto|shared|branch]
#                                           [--idle-min N] [--journey [-- JOURNEY ARGS]]
#   scripts/cmux-next/cloud-dev-stack.sh status [--tag T]
#   scripts/cmux-next/cloud-dev-stack.sh journey --tag T [-- JOURNEY ARGS]
#   scripts/cmux-next/cloud-dev-stack.sh logs --tag T [-n LINES]
#   scripts/cmux-next/cloud-dev-stack.sh touch --tag T        # count as activity (keeps an idle stack up)
#   scripts/cmux-next/cloud-dev-stack.sh down --tag T         # stop, delete the stack, its credentials and branches
#   scripts/cmux-next/cloud-dev-stack.sh gc                   # clean up after stacks the VM reaped
#
# up: syncs backend/, libs/, clients/ts/ and workers/cmux-vm/sdk/ of this worktree (tracked and untracked,
# not ignored; uncommitted edits included) to the VM, `bun install`s there, starts `wrangler dev --env
# development` on a free tailnet port and prints https://<vm>.<tailnet>.ts.net:<port>. Run it again after
# an edit: same tag, same port and Durable Object state, new code. --platform-checkout DIR runs that
# cmux-platform worktree in the same workerd session, as the API's PLATFORM service and CLOUD_DO.
# --journey runs scripts/cmux-next/cloud-journey.ts against the stack afterwards.
#
# Data: Durable Objects, R2 and workflows are local to the stack. Postgres and Vitess are PlanetScale:
# by default the shared `development` branches (as the shared dev Worker and previews use them), through
# a credential made for this stack with a 13 h TTL. When this branch adds a migration (backend/db/migrations
# or backend/db/drizzle-mysql changed since the merge-base with origin/feat-cmux-next; --db branch forces
# it, --db shared refuses it), the stack gets its own branch `lane-wd-<tag>` of that database, made from
# development and migrated with this tree; `down` deletes it.
# Credentials go from pscale straight into the VM over SSH stdin, mode 0600 there; nothing is printed or
# written on this Mac.
#
# Lifetime: the VM stops a stack after 2 h with no request and no up/touch (--idle-min, or
# CMUX_WDEV_IDLE_SECS on the VM), and 12 h after its last `up` in any case. A reaped stack keeps only its
# registry entry; the next up/down/gc from any Mac deletes its credentials and branch.
#
# Host: CMUX_DEV_STACK_HOST (default cmux-dev-backend-1, hq's dev-backend VM; any tailnet Linux host with
# sudo, systemd and Tailscale Serve works) or --host. The VM side is scripts/cmux-next/cloud-dev-stack/vm_stack.py.
# Not Workers previews: those count against the account's ~400-Worker cap (cloud-dev-loop.sh deploys them).
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
helper="$root/scripts/cmux-next/cloud-dev-stack/vm_stack.py"
HOST="${CMUX_DEV_STACK_HOST:-cmux-dev-backend-1}"
VM_USER="${CMUX_DEV_STACK_USER:-ubuntu}"
BASE="${CMUX_DEV_STACK_BASE:-/srv/cmux-dev/wrangler}"
BASE_REF="${CMUX_DEV_STACK_BASE_REF:-origin/feat-cmux-next}"
PG_DB="${CMUX_DEV_STACK_PG_DB:-cmux-next-deprecated}"   # PlanetScale Postgres `cmux-next` (renamed)
MYSQL_DB="${CMUX_DEV_STACK_MYSQL_DB:-cmux-next-vitess}"
PS_ORG=cmux
DEV_BRANCH=development
CRED_TTL=13h
SYNC_PATHS=(backend libs clients/ts workers/cmux-vm/sdk)

usage() { sed -n '2,40p' "$0"; }
die() { echo "cloud-dev-stack: $*" >&2; exit 1; }
cmd="${1:-}"; [ $# -gt 0 ] && shift
tag="" platform="" db_mode=auto idle_min=0 journey=0 lines=80 creds=""
journey_args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --tag) tag="$2"; shift 2 ;;
    --host) HOST="$2"; shift 2 ;;
    --platform-checkout) platform="$(cd "$2" && pwd)"; shift 2 ;;
    --db) db_mode="$2"; shift 2 ;;
    --idle-min) idle_min="$2"; shift 2 ;;
    --journey) journey=1; shift ;;
    --credentials) creds="$2"; shift 2 ;;
    -n) lines="$2"; shift 2 ;;
    --) shift; journey_args=("$@"); break ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument $1 (journey arguments go after --)" ;;
  esac
done
case "$cmd" in up|down|journey|logs|touch) [ -n "$tag" ] || die "--tag NAME is required" ;; esac
case "$tag" in *[!a-z0-9-]*|-*) die "--tag NAME: lowercase letters, digits and -" ;; esac
case "$lines" in ""|*[!0-9]*) die "-n LINES: a number" ;; esac
case "$idle_min" in ""|*[!0-9]*) die "--idle-min N: minutes" ;; esac
case "$db_mode" in auto|shared|branch) ;; *) die "--db auto|shared|branch" ;; esac

SSH=(ssh -o BatchMode=yes -o ConnectTimeout=20 -o ServerAliveInterval=30 "$VM_USER@$HOST")
vm() { "${SSH[@]}" python3 "$BASE/bin/vm_stack.py" "$@"; }
json() { python3 -c "import json,sys; d=json.load(sys.stdin); $1"; }
ps() { pscale "$@" --org "$PS_ORG" --format json; }

ensure_helper() {
  "${SSH[@]}" true 2>/dev/null || die "cannot reach $VM_USER@$HOST over SSH (tailnet). hq: scripts/dev-backend.sh vm-status wakes a stopped VM."
  local want have
  want="$(shasum -a 256 "$helper" | cut -d' ' -f1)"
  have="$("${SSH[@]}" "sha256sum $BASE/bin/vm_stack.py 2>/dev/null | cut -d' ' -f1" || true)"
  if [ "$want" != "$have" ]; then
    "${SSH[@]}" "mkdir -p -m 700 $BASE/bin"
    scp -q -o BatchMode=yes "$helper" "$VM_USER@$HOST:$BASE/bin/vm_stack.py.new"
    "${SSH[@]}" "mv $BASE/bin/vm_stack.py.new $BASE/bin/vm_stack.py"
    vm install >/dev/null
  fi
}

# The worktree's files (tracked and untracked, not ignored), so an uncommitted edit runs too.
manifest() { (cd "$1" && shift && git ls-files -co --exclude-standard -- "$@" | while IFS= read -r f; do [ -e "$f" ] && printf '%s\n' "$f"; done); }

sync_tree() {  # sync_tree DIR TREE PATHS...
  local dir="$1" tree="$2"; shift 2
  local list; list="$(mktemp)"
  manifest "$dir" "$@" > "$list"
  rsync -a --files-from="$list" -e "ssh -o BatchMode=yes" "$dir/" "$VM_USER@$HOST:$BASE/stacks/$tag/$tree/"
  vm prune --tag "$tag" --tree "$tree" < "$list" >/dev/null
  echo "   $(wc -l < "$list" | tr -d ' ') files -> $tree/"
  rm -f "$list"
}

migration_kinds() {  # prints pg and/or mysql when this branch changes that database's migrations
  local mb changed
  mb="$(git -C "$root" merge-base HEAD "$BASE_REF" 2>/dev/null || true)"
  [ -n "$mb" ] || { echo "   (no merge-base with $BASE_REF; assuming no migration)" >&2; return 0; }
  changed="$( { git -C "$root" diff --name-only "$mb" -- backend/db/migrations backend/db/drizzle-mysql; git -C "$root" ls-files -o --exclude-standard -- backend/db/migrations backend/db/drizzle-mysql; } | sort -u)"
  grep -q '^backend/db/migrations/' <<<"$changed" && echo pg
  grep -q '^backend/db/drizzle-mysql/' <<<"$changed" && echo mysql
  return 0
}

stack_entry() { vm status --tag "$tag" | json "s=d['stacks']; print(json.dumps(s[0] if s else {}))"; }

cred_fresh() {  # cred_fresh KIND MODE: the VM still holds a credential of that mode valid for 2 h more
  stack_entry | python3 -c "
import json,sys,datetime
e=json.load(sys.stdin); c=(e.get('db') or {}).get('$1') or {}
exp=c.get('expires_at') or ''
# The file can be gone while the entry remains (a reaped stack's files are deleted).
ok=(e.get('secrets') or {}).get('$1') and c.get('mode')=='$2' and exp and datetime.datetime.fromisoformat(exp.replace('Z','+00:00'))>datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(hours=2)
sys.exit(0 if ok else 1)"
}

give_db() {  # give_db KIND MODE
  local kind="$1" mode="$2" db branch name
  if [ "$kind" = pg ]; then db="$PG_DB"; else db="$MYSQL_DB"; fi
  branch="$DEV_BRANCH"
  if [ "$mode" = branch ]; then
    branch="lane-wd-$tag"
    if ! ps branch show "$db" "$branch" >/dev/null 2>&1; then
      echo "   $db: branch $branch from $DEV_BRANCH (deleted by down)"
      ps branch create "$db" "$branch" --from "$DEV_BRANCH" --wait >/dev/null
      if [ "$kind" = mysql ]; then
        # A Vitess branch has development's schema but not its schema_migrations rows: a 1 h reader on
        # development lets the VM copy that history before the first migration run (vm_stack.py migrate).
        ps password create "$db" "$DEV_BRANCH" "wdev-$tag-history-$(date +%s)" --role reader --ttl 1h \
          | vm put-cred --tag "$tag" --kind mysql-parent --db-name "$db" --branch "$DEV_BRANCH" --database "$MYSQL_DB" --mode shared >/dev/null
      fi
    fi
  fi
  if cred_fresh "$kind" "$mode"; then echo "   $db/$branch: credential still valid"; return 0; fi
  name="wdev-$tag-$(date +%s)"
  if [ "$kind" = pg ]; then
    local roles=pg_read_all_data,pg_write_all_data
    [ "$mode" = branch ] && roles=postgres   # the migration runner creates tables
    stored="$(ps role create "$db" "$branch" "$name" --inherited-roles "$roles" --ttl "$CRED_TTL" \
      | vm put-cred --tag "$tag" --kind pg --db-name "$db" --branch "$branch" --mode "$mode")"
  else
    local role=readwriter
    [ "$mode" = branch ] && role=admin
    stored="$(ps password create "$db" "$branch" "$name" --role "$role" --ttl "$CRED_TTL" \
      | vm put-cred --tag "$tag" --kind mysql --db-name "$db" --branch "$branch" --database "$MYSQL_DB" --mode "$mode")"
  fi
  # The credential this one replaced (an expiring one, or a mode change): delete it now, not at its TTL,
  # and a branch the stack no longer uses (it dropped its migration). The branch in use stays.
  local old_db old_branch old_mode old_id
  read -r old_db old_branch old_mode old_id < <(json "r=d.get('replaced') or {}; print(r.get('database') or '-', r.get('branch') or '-', r.get('mode') or '-', r.get('cred_id') or '-')" <<<"$stored")
  if [ "$old_mode" = branch ] && [ "$old_branch" != "$branch" ] && [[ "$old_branch" == lane-wd-* ]]; then
    if ps branch delete "$old_db" "$old_branch" --force >/dev/null 2>&1; then echo "   deleted unused branch $old_db/$old_branch"; fi
  elif [ "$old_id" != - ]; then
    if [ "$kind" = pg ]; then ps role delete "$old_db" "$old_branch" "$old_id" --force >/dev/null 2>&1 || true
    else ps password delete "$old_db" "$old_branch" "$old_id" --force >/dev/null 2>&1 || true; fi
    echo "   deleted the credential it replaces ($old_id)"
  fi
  echo "   $db/$branch: credential $name (TTL $CRED_TTL, on the VM only)"
}

# Delete one stack's PlanetScale credentials and branches from its registry entry (JSON on stdin).
release_db() {
  python3 -c "
import json,sys
e=json.load(sys.stdin)
for kind,c in (e.get('db') or {}).items():
    print(kind, c.get('database') or '', c.get('branch') or '', c.get('mode') or '', c.get('cred_id') or '')" |
  while read -r kind db branch mode cred; do
    [ -n "$db" ] || continue
    if [ "$mode" = branch ] && [[ "$branch" == lane-wd-* ]]; then
      if ps branch delete "$db" "$branch" --force >/dev/null 2>&1; then echo "   deleted branch $db/$branch"
      else echo "   branch $db/$branch: already gone or delete failed (gc retries)"; fi
    elif [ -n "$cred" ]; then
      if [ "$kind" = pg ]; then ps role delete "$db" "$branch" "$cred" --force >/dev/null 2>&1 || true
      else ps password delete "$db" "$branch" "$cred" --force >/dev/null 2>&1 || true; fi
      echo "   deleted credential $db/$branch $cred"
    fi
  done
}

do_gc() {  # do_gc [TAG TO SPARE]: up spares its own tag, whose branch and credentials it reuses
  local entries live spare="${1:-}" cutoff
  entries="$(vm status)"
  # Stacks the VM stopped (idle, expired) or a down that did not finish: release, then forget. A failed
  # start is kept for an hour, for the agent's next up.
  for t in $(json "import time; print(' '.join(s['tag'] for s in d['stacks'] if s['tag'] != '$spare' and (s['state'] in ('reaped','down') or (s['state'] == 'failed' and time.time() - (s.get('last_up_at') or 0) > 3600))))" <<<"$entries"); do
    echo "== gc $t"
    vm status --tag "$t" | json "print(json.dumps(d['stacks'][0]))" | release_db
    vm forget --tag "$t" >/dev/null
  done
  # Branches with no stack behind them (a VM that lost its registry, a crash between create and start).
  live="$(json "print(' '.join('lane-wd-'+s['tag'] for s in d['stacks'] if s['state'] in ('running','starting','preparing','failed') or s['tag'] == '$spare'))" <<<"$entries")"
  # Only branches a day old: one being made right now by an up on another Mac has no entry yet here,
  # and a stack on another host (--host) is not in this host's registry.
  cutoff="$(python3 -c 'import datetime as d; print((d.datetime.now(d.timezone.utc)-d.timedelta(hours=24)).strftime("%Y-%m-%dT%H:%M:%S"))')"
  for db in "$PG_DB" "$MYSQL_DB"; do
    for br in $(ps branch list "$db" | json "print(' '.join(b['name'] for b in d if b['name'].startswith('lane-wd-') and (b.get('created_at') or '9')[:19] < '$cutoff'))"); do
      case " $live " in *" $br "*) ;; *) ps branch delete "$db" "$br" --force >/dev/null && echo "   gc: deleted orphan branch $db/$br" ;; esac
    done
  done
}

stack_url() { stack_entry | json "print(d.get('url') or '')"; }

run_journey() {
  local url="$1"; shift
  echo "== journey on $url"
  bun "$root/scripts/cmux-next/cloud-journey.ts" --api "$url" --stack dev ${creds:+--credentials "$creds"} "$@"
}

case "$cmd" in
  up)
    t0=$(date +%s)
    ensure_helper
    do_gc "$tag"
    echo "== $tag on $HOST"
    vm prepare --tag "$tag" >/dev/null
    sync_tree "$root" src "${SYNC_PATHS[@]}"
    if [ -n "$platform" ]; then sync_tree "$platform" platform .; fi
    kinds="$(migration_kinds)"
    for kind in pg mysql; do
      mode=shared
      if [ "$db_mode" = branch ] || grep -qx "$kind" <<<"$kinds"; then mode=branch; fi
      if [ "$db_mode" = shared ] && [ "$mode" = branch ]; then die "this branch changes $kind migrations; --db shared would run them against nothing. Drop --db shared."; fi
      give_db "$kind" "$mode"
    done
    if [ -n "$kinds" ] || [ "$db_mode" = branch ]; then
      echo "== migrate lane-wd-$tag with this tree"
      out="$(vm migrate --tag "$tag")" || die "migration failed (above). Fix it and run up again, or: $0 down --tag $tag"
      json "print('\n'.join(f'   {k}: '+' | '.join(v) for k,v in d['migrated'].items()))" <<<"$out"
    fi
    sha="$(git -C "$root" rev-parse --short=12 HEAD)"
    dirty=(); [ -n "$(git -C "$root" status --porcelain -- "${SYNC_PATHS[@]}")" ] && dirty=(--dirty)
    echo "== wrangler dev (bun install, build, boot)"
    out="$(vm start --tag "$tag" --commit "$sha" ${dirty[@]+"${dirty[@]}"} ${platform:+--platform} --idle "$((idle_min * 60))")"
    url="$(json "print(d['url'])" <<<"$out")"
    curl -fsS -m 30 "$url/v1/health" >/dev/null || die "$url/v1/health does not answer from this Mac (tailnet?)"
    echo "== up in $(( $(date +%s) - t0 )) s"
    echo "API:     $url   (commit $sha${dirty:+, with uncommitted changes})"
    if [ -n "$platform" ]; then echo "Platform: in the same workerd session, as the API's PLATFORM binding"; fi
    echo "Journey: scripts/cmux-next/cloud-dev-stack.sh journey --tag $tag"
    echo "Stop:    scripts/cmux-next/cloud-dev-stack.sh down --tag $tag   (else the VM stops it after $(( idle_min > 0 ? idle_min : 120 )) min without a request)"
    if [ "$journey" = 1 ]; then run_journey "$url" "${journey_args[@]+"${journey_args[@]}"}"; fi
    ;;
  status)
    ensure_helper
    vm status ${tag:+--tag "$tag"} | python3 -c "
import json,sys
d=json.load(sys.stdin); c=d['capacity']
print(f\"host: MemAvailable {c['mem_available_gib']} GiB (floor {c['min_mem_gib']}), disk free {c['disk_free_gib']} GiB (floor {c['min_disk_gib']}), stacks {c['stacks_running']}/{c['max_stacks']}, classic registrations {c['classic_registered']}\")
for s in d['stacks']:
    db=', '.join(f\"{k}:{v['mode']}:{v['database']}/{v['branch']}\" for k,v in s['db'].items())
    print(f\"{s['tag']:<24} {s['state']:<8} {s['url'] or '-':<52} idle {s['idle_min']}/{s['idle_limit_min']} min  mem {s['mem_mib'] or '-'} MiB  {s['commit'] or ''}{' dirty' if s['dirty'] else ''}  {db}  {s['reason'] or ''}\")"
    ;;
  journey)
    url="$(stack_url)"; [ -n "$url" ] || die "no stack $tag (up first)"
    vm touch --tag "$tag" >/dev/null
    run_journey "$url" "${journey_args[@]+"${journey_args[@]}"}"
    ;;
  logs) vm logs --tag "$tag" -n "$lines" ;;
  touch) vm touch --tag "$tag" ;;
  down)
    ensure_helper
    echo "== down $tag"
    entry="$(vm down --tag "$tag" --reason down)"
    json "print('   VM: ' + (', '.join(d.get('actions') or []) or d.get('state','')))" <<<"$entry"
    release_db <<<"$entry"
    vm forget --tag "$tag" >/dev/null
    do_gc
    echo "== $tag is gone"
    ;;
  gc) ensure_helper; do_gc; vm reap >/dev/null; do_gc ;;
  *) usage; exit 2 ;;
esac
