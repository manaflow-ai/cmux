#!/usr/bin/env bash
# A per-tag cmux-next backend on the GCP dev VM: this worktree's unmerged Workers under one `wrangler dev`
# (real workerd, local Durable Objects), reached over the tailnet. Zero Workers deployed. The stack runs all
# three Workers a dev build talks to: the cmux API (backend/apps/api), the mobile Worker
# (cmux-next-ios/backend) and the device hub (workers/device-hub), on three consecutive ports of one host.
#
#   scripts/cmux-next/cloud-dev-stack.sh up --tag T [--platform-checkout DIR] [--db auto|shared|branch]
#                                           [--idle-min N] [--journey [-- JOURNEY ARGS]]
#   scripts/cmux-next/cloud-dev-stack.sh status [--tag T]
#   scripts/cmux-next/cloud-dev-stack.sh url --tag T [--service api|mobile|hub] [--public]
#                                           # print the stack's https origin, tailnet or public (exit 3: none)
#   scripts/cmux-next/cloud-dev-stack.sh public-setup [--slots N]   # operator, once: the public origins (below)
#   scripts/cmux-next/cloud-dev-stack.sh journey --tag T [-- JOURNEY ARGS]
#   scripts/cmux-next/cloud-dev-stack.sh logs --tag T [-n LINES]
#   scripts/cmux-next/cloud-dev-stack.sh touch --tag T        # count as activity (keeps an idle stack up)
#   scripts/cmux-next/cloud-dev-stack.sh stop --tag T         # stop its workerd now; its next request wakes it
#   scripts/cmux-next/cloud-dev-stack.sh down --tag T         # stop, delete the stack, its credentials and branches
#   scripts/cmux-next/cloud-dev-stack.sh gc                   # clean up after stacks the VM reaped
#
# up: syncs backend/, libs/, clients/ts/, workers/cmux-vm/sdk/, cmux-next-ios/backend/ and workers/device-hub/
# of this worktree (tracked and untracked, not ignored; uncommitted edits included) to the VM, installs each
# project's dependencies there, starts one `wrangler dev` of the three Workers (the API's env development, the
# mobile Worker's and the hub's env dev) on three free consecutive tailnet ports and prints their origins:
# https://<vm>.<tailnet>.ts.net:P (API), :P+1 (mobile), :P+2 (device hub). The API origin is the one a build
# takes (review.sh --backend tag-stack): its /v1/client-config names the other two, and the iPhone app derives
# them from it (the next two ports). Run it again after an edit: same tag, same ports and Durable Object state,
# new code. --platform-checkout DIR runs that cmux-platform worktree in the same workerd session, as the API's
# PLATFORM service and CLOUD_DO.
# --journey runs scripts/cmux-next/cloud-journey.ts against the stack afterwards.
#
# Data: Durable Objects, R2 and workflows are local to the stack (the mobile Worker's team hubs and the device
# hub's users and sessions too). Postgres and Vitess are PlanetScale (the mobile Worker's mobile_* tables are
# Vitess, as on the shared dev deployment):
# by default the shared `development` branches (as the shared dev Worker and previews use them), through
# a credential made for this stack with a 14 h TTL. When this branch adds a migration (backend/db/migrations
# or backend/db/drizzle-mysql changed since the merge-base with origin/feat-cmux-next; --db branch forces
# it, --db shared refuses it), the stack gets its own branch `lane-wd-<tag>` of that database, made from
# development and migrated with this tree; `down` deletes it.
# Credentials go from pscale straight into the VM over SSH stdin, mode 0600 there; nothing is printed or
# written on this Mac.
#
# Team keys: each stack's mobile Worker serves /v1/ice with TURN, as the shared dev Worker does, from the team's
# Cloudflare TURN key (1Password "Cloudflare TURN Server API Key", vault Shared). The VM keeps one copy for every
# stack (<base>/secrets/turn.json, mode 0600). An up sends it from `op` over SSH stdin only when the VM has none or
# Cloudflare refuses the one it has (a rotated key); without op, or with op signed out, the up goes on and says
# ICE is STUN only (a phone on another network than its Mac may not link). The API's Stack server key, which it
# needs to learn a person's teams (a team-scoped token mint), is the development project's key the VM's classic
# dev backend already keeps (cmuxterm-hq skills/infra/dev-backend); nothing sends it.
#
# Lifetime: as long as a dogfooded build may use it. Every stack port goes through the VM's router
# (cloud-dev-stack/router.mjs), which counts each request as activity. After 2 h with no request and no
# up/touch (--idle-min, or CMUX_WDEV_IDLE_SECS on the VM) the stack's workerd stops, keeping its files, Durable
# Object data, credentials and ports; its next request wakes it (the router holds that request until the stack
# answers, about 6 s measured). The VM keeps at most 16 running: a start or wake that does not fit stops the least
# recently used running stack. A stack is released 7 days after its last `up` (CMUX_WDEV_RETAIN_SECS), or
# earlier when the VM keeps more than 48 stopped ones or runs short of disk (least recently used first); a
# released stack keeps only its registry entry, and the next up/down/gc from any Mac deletes its credentials and
# branch. Its database credentials live 8 days, past the retention.
#
# Public origins: a stack with a public slot also answers on https://api.<slot>.wdev.cmux.dev, mobile.<slot>...
# and hub.<slot>..., reachable off the tailnet (a phone away from home). The Worker cmux-wdev-gateway
# (cloud-dev-stack/gateway) answers them: it admits a request only with a credential it verified (a verified
# cmux-team account of the Stack development project, or a token that stack issued; cmux-next-ios/SECURITY.md),
# then sends it through the Cloudflare Tunnel cmux-wdev (cloudflared on the VM, cmux-wdev-tunnel.service) and the
# Workers VPC service cmux-wdev-router to the VM's router, which routes by host. A slot stays with its stack until
# the stack is released. public-setup (an operator with the cmux Cloudflare login, once, and again to add slots)
# deploys the gateway, makes the slots' custom domains and tells the VM which slots exist.
#
# Host: CMUX_DEV_STACK_HOST (default cmux-dev-backend-1, hq's dev-backend VM; any tailnet Linux host with
# sudo, systemd and Tailscale Serve works) or --host. The VM side is scripts/cmux-next/cloud-dev-stack/vm_stack.py.
# Not Workers previews: those count against the account's ~400-Worker cap (cloud-dev-loop.sh deploys them).
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
helper="$root/scripts/cmux-next/cloud-dev-stack/vm_stack.py"
router="$root/scripts/cmux-next/cloud-dev-stack/router.mjs"
HOST="${CMUX_DEV_STACK_HOST:-cmux-dev-backend-1}"
VM_USER="${CMUX_DEV_STACK_USER:-ubuntu}"
BASE="${CMUX_DEV_STACK_BASE:-/srv/cmux-dev/wrangler}"
BASE_REF="${CMUX_DEV_STACK_BASE_REF:-origin/feat-cmux-next}"
PG_DB="${CMUX_DEV_STACK_PG_DB:-cmux-next-deprecated}"   # PlanetScale Postgres `cmux-next` (renamed)
MYSQL_DB="${CMUX_DEV_STACK_MYSQL_DB:-cmux-next-vitess}"
PS_ORG=cmux
DEV_BRANCH=development
CRED_TTL=192h  # outlives the 7 d retention; an up keeps a credential only while it does (vm_stack.py cred_fresh)
TURN_ITEM="${CMUX_DEV_STACK_TURN_ITEM:-lqvg75d4awzbveq7ny5gyfeyd4}"  # 1Password "Cloudflare TURN Server API Key" (vault Shared)
SYNC_PATHS=(backend libs clients/ts workers/cmux-vm/sdk cmux-next-ios/backend workers/device-hub)

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; }
die() { echo "cloud-dev-stack: $*" >&2; exit 1; }
cmd="${1:-}"; [ $# -gt 0 ] && shift
tag="" platform="" db_mode=auto idle_min=0 journey=0 lines=80 creds="" service=api public=0 slots=24
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
    --service) service="$2"; shift 2 ;;
    --public) public=1; shift ;;
    --slots) slots="$2"; shift 2 ;;
    -n) lines="$2"; shift 2 ;;
    --) shift; journey_args=("$@"); break ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument $1 (journey arguments go after --)" ;;
  esac
done
case "$cmd" in up|down|journey|logs|touch|url|stop) [ -n "$tag" ] || die "--tag NAME is required" ;; esac
case "$tag" in *[!a-z0-9-]*|-*) die "--tag NAME: lowercase letters, digits and -" ;; esac
case "$lines" in ""|*[!0-9]*) die "-n LINES: a number" ;; esac
case "$idle_min" in ""|*[!0-9]*) die "--idle-min N: minutes" ;; esac
case "$db_mode" in auto|shared|branch) ;; *) die "--db auto|shared|branch" ;; esac
case "$service" in api|mobile|hub) ;; *) die "--service api|mobile|hub" ;; esac
case "$slots" in ""|*[!0-9]*) die "--slots N: a number" ;; esac

SSH=(ssh -o BatchMode=yes -o ConnectTimeout=20 -o ServerAliveInterval=30 "$VM_USER@$HOST")
vm() { "${SSH[@]}" python3 "$BASE/bin/vm_stack.py" "$@"; }
json() { python3 -c "import json,sys; d=json.load(sys.stdin); $1"; }
ps() { pscale "$@" --org "$PS_ORG" --format json; }

ensure_helper() {
  "${SSH[@]}" true 2>/dev/null || die "cannot reach $VM_USER@$HOST over SSH (tailnet). hq: scripts/dev-backend.sh vm-status wakes a stopped VM."
  local want have
  want="$(cat "$helper" "$router" | shasum -a 256 | cut -d' ' -f1)"
  have="$("${SSH[@]}" "cat $BASE/bin/vm_stack.py $BASE/bin/router.mjs 2>/dev/null | sha256sum | cut -d' ' -f1" || true)"
  if [ "$want" != "$have" ]; then
    "${SSH[@]}" "mkdir -p -m 700 $BASE/bin"
    # Per-caller names: two ups at once both see an old copy and both install it. The router moves first:
    # the new helper's install restarts it.
    local tmp="new.$$.$RANDOM"
    scp -q -o BatchMode=yes "$router" "$VM_USER@$HOST:$BASE/bin/router.mjs.$tmp"
    scp -q -o BatchMode=yes "$helper" "$VM_USER@$HOST:$BASE/bin/vm_stack.py.$tmp"
    "${SSH[@]}" "mv -f $BASE/bin/router.mjs.$tmp $BASE/bin/router.mjs && mv -f $BASE/bin/vm_stack.py.$tmp $BASE/bin/vm_stack.py"
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

cred_fresh() {  # cred_fresh KIND MODE: the VM holds a credential of that mode that outlives the stack's retention (8 d)
  vm cred-fresh --tag "$tag" --kind "$1" --mode "$2" | json "sys.exit(0 if d['fresh'] else 1)"
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

give_turn() {  # the team's TURN key to the VM when it has none or Cloudflare refuses its copy; never fails an up
  local state why
  read -r state why < <(vm turn-status </dev/null | json "print(d['state'], d.get('why') or '')") || state=unknown
  case "$state" in ok|unverified) echo "   TURN key: on the VM ($why)"; return 0 ;; esac
  if ! command -v op >/dev/null 2>&1; then
    echo "   TURN key: ${why:-$state}, and no 1Password CLI (op) here: ICE stays STUN only"; return 0
  fi
  # The id is the 32-hex "Turn Token ID" in the item's notes, the token its credential field
  # (cmux-next-ios/backend/README.md). Both go through the pipe only; vm_stack.py put-turn refuses an empty
  # or malformed value (a failed op) and a key Cloudflare refuses, keeping what the VM has.
  if { op item get "$TURN_ITEM" --fields notesPlain </dev/null 2>/dev/null | grep -oE '[0-9a-f]{32}' | head -1
       op read "op://Shared/$TURN_ITEM/credential" </dev/null 2>/dev/null; } | vm put-turn >/dev/null; then
    echo "   TURN key: from 1Password to the VM (mode 0600 there, nothing on this Mac's disk)"
  else
    echo "   TURN key: not stored (op signed in? the VM's reason is above): ICE stays STUN only"
  fi
  return 0
}

# Delete one stack's PlanetScale credentials and branches from its registry entry (JSON on stdin).
release_db() {
  python3 -c "
import json,sys
e=json.load(sys.stdin)
for kind,c in (e.get('db') or {}).items():
    print(kind, c.get('database') or '', c.get('branch') or '', c.get('mode') or '', c.get('cred_id') or '')" |
  while read -r kind db branch mode cred; do
    # Every command in this loop reads /dev/null, not the loop's input: ssh would swallow the next lines.
    [ -n "$db" ] || continue
    if [ "$mode" = branch ] && [[ "$branch" == lane-wd-* ]]; then
      if ps branch delete "$db" "$branch" --force </dev/null >/dev/null 2>&1; then
        echo "   deleted branch $db/$branch"
        vm ledger --drop "$db/$branch" </dev/null >/dev/null
      else echo "   branch $db/$branch: already gone or delete failed (the orphan sweep retries it)"; fi
    elif [ -n "$cred" ]; then
      if [ "$kind" = pg ]; then ps role delete "$db" "$branch" "$cred" --force </dev/null >/dev/null 2>&1 || true
      else ps password delete "$db" "$branch" "$cred" --force </dev/null >/dev/null 2>&1 || true; fi
      echo "   deleted credential $db/$branch $cred"
    fi
  done
}

do_gc() {  # do_gc [TAG TO SPARE]: up spares its own tag, whose branch and credentials it reuses
  local entries live spare="${1:-}" cutoff entry key db br
  entries="$(vm status)"
  # Stacks the VM stopped (idle, expired, a failed start after an hour) or a down or gc that did not
  # finish. Each is claimed on the VM under its registry lock first (state releasing): the claim fails
  # when an up of that tag got there first, and an up refuses a claimed tag, so a branch is never
  # deleted under an up that reuses it.
  for t in $(json "print(' '.join(s['tag'] for s in d['stacks'] if s['tag'] != '$spare' and s['state'] in ('reaped','down','failed','releasing')))" <<<"$entries"); do
    entry="$(vm claim-release --tag "$t" 2>/dev/null)" || continue
    echo "== gc $t"
    release_db <<<"$entry"
    vm forget --tag "$t" >/dev/null
  done
  # Branches this host's stacks made (its ledger) with no stack behind them: a crash between create and
  # start, or a release whose delete failed. Only a day after the host first saw them, and never one a
  # stack still holds; a branch another --host made is not in this ledger.
  live="$(vm status | json "print(' '.join('lane-wd-'+s['tag'] for s in d['stacks']) + ' lane-wd-$spare')")"
  cutoff="$(( $(date +%s) - 86400 ))"
  for key in $(vm ledger | json "print(' '.join(k for k,t in d['branches'].items() if t < $cutoff))"); do
    db="${key%%/*}"; br="${key#*/}"
    case " $live " in *" $br "*) continue ;; esac
    if ps branch show "$db" "$br" >/dev/null 2>&1; then
      if ps branch delete "$db" "$br" --force >/dev/null 2>&1; then echo "   gc: deleted orphan branch $db/$br"; else continue; fi
    fi
    vm ledger --drop "$key" >/dev/null
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
    prepared="$(vm prepare --tag "$tag")" || exit 3   # its refusal is on stderr
    up_token="$(json "print(d['token'])" <<<"$prepared")"
    # The VM allows one up of a tag at a time; this ends ours, pass or fail. A failed up leaves a
    # running stack running and marks one that never started failed.
    trap 'rc=$?; vm up-done --tag "$tag" --token "$up_token" $([ "$rc" = 0 ] || echo --failed) >/dev/null 2>&1 || true' EXIT
    sync_tree "$root" src "${SYNC_PATHS[@]}"
    if [ -n "$platform" ]; then sync_tree "$platform" platform .; fi
    kinds="$(migration_kinds)"
    for kind in pg mysql; do
      mode=shared
      if [ "$db_mode" = branch ] || grep -qx "$kind" <<<"$kinds"; then mode=branch; fi
      if [ "$db_mode" = shared ] && [ "$mode" = branch ]; then die "this branch changes $kind migrations; --db shared would run them against nothing. Drop --db shared."; fi
      give_db "$kind" "$mode"
    done
    give_turn
    if [ -n "$kinds" ] || [ "$db_mode" = branch ]; then
      echo "== migrate lane-wd-$tag with this tree"
      out="$(vm migrate --tag "$tag")" || die "migration failed (above). Fix it and run up again, or: $0 down --tag $tag"
      json "print('\n'.join(f'   {k}: '+' | '.join(v) for k,v in d['migrated'].items()))" <<<"$out"
    fi
    sha="$(git -C "$root" rev-parse --short=12 HEAD)"
    dirty=(); [ -n "$(git -C "$root" status --porcelain -- "${SYNC_PATHS[@]}")" ] && dirty=(--dirty)
    echo "== wrangler dev of the API, the mobile Worker and the device hub (install, build, boot)"
    out="$(vm start --tag "$tag" --commit "$sha" ${dirty[@]+"${dirty[@]}"} ${platform:+--platform} --idle "$((idle_min * 60))")"
    url="$(json "print(d['url'])" <<<"$out")"
    read -r mobile_url hub_url < <(json "u=d.get('urls') or {}; print(u.get('mobile') or '-', u.get('hub') or '-')" <<<"$out")
    for u in "$url" "$mobile_url" "$hub_url"; do
      curl -fsS -m 30 "$u/v1/health" >/dev/null || die "$u/v1/health does not answer from this Mac (tailnet?)"
    done
    echo "== up in $(( $(date +%s) - t0 )) s"
    echo "API:     $url   (commit $sha${dirty:+, with uncommitted changes})"
    echo "Mobile:  $mobile_url   (cmux-next-ios/backend)"
    echo "Hub:     $hub_url   (workers/device-hub)"
    pub="$(json "print((d.get('public_urls') or {}).get('api') or '')" <<<"$out")"
    if [ -n "$pub" ]; then echo "Public:  $pub   (and mobile., hub.; off the tailnet, signed-in cmux accounts only)"
    else echo "Public:  none (no free public slot; tailnet only)"; fi
    if [ -n "$platform" ]; then echo "Platform: in the same workerd session, as the API's PLATFORM binding"; fi
    read -r has_turn has_teams < <(json "k=d.get('keys') or {}; print('yes' if k.get('turn') else 'no', 'yes' if k.get('stack_teams') else 'no')" <<<"$out")
    if [ "$has_turn" = yes ]; then echo "ICE:     STUN and TURN (the team's Cloudflare TURN key), as the shared dev Worker"
    else echo "ICE:     STUN only (no TURN key on the VM): a phone on another network than its Mac may not link"; fi
    if [ "$has_teams" = yes ]; then echo "Teams:   the API reads a person's teams from Stack (the VM's development Stack server key)"
    else echo "Teams:   no Stack server key on the VM: team-scoped tokens are refused (403) until the team is known"; fi
    echo "Journey: scripts/cmux-next/cloud-dev-stack.sh journey --tag $tag"
    echo "Lifetime: idle $(( idle_min > 0 ? idle_min : 120 )) min stops it, its next request wakes it; released $(json "print(d.get('retain_days') or 7)" <<<"$out") d after this up"
    echo "Delete:  scripts/cmux-next/cloud-dev-stack.sh down --tag $tag"
    if [ "$journey" = 1 ]; then run_journey "$url" "${journey_args[@]+"${journey_args[@]}"}"; fi
    ;;
  status)
    ensure_helper
    vm status ${tag:+--tag "$tag"} | python3 -c "
import json,sys
d=json.load(sys.stdin); c=d['capacity']
print(f\"host: MemAvailable {c['mem_available_gib']} GiB (floor {c['min_mem_gib']}), disk free {c['disk_free_gib']} GiB (floor {c['min_disk_gib']}), running {c['stacks_running']}/{c['max_stacks']}, stopped {c.get('stacks_stopped', 0)}/{c.get('max_kept', '-')}, classic registrations {c['classic_registered']}, TURN key {'on the VM' if c.get('turn_key') else 'none'}\")
for s in d['stacks']:
    db=', '.join(f\"{k}:{v['mode']}:{v['database']}/{v['branch']}\" for k,v in s['db'].items())
    print(f\"{s['tag']:<24} {s['state']:<8} {s['url'] or '-':<52} idle {s['idle_min']}/{s['idle_limit_min']} min  mem {s['mem_mib'] or '-'} MiB  {s['commit'] or ''}{' dirty' if s['dirty'] else ''}  {db}  {s['reason'] or ''}\")"
    ;;
  journey)
    url="$(stack_url)"; [ -n "$url" ] || die "no stack $tag (up first)"
    vm touch --tag "$tag" >/dev/null
    run_journey "$url" "${journey_args[@]+"${journey_args[@]}"}"
    ;;
  url)
    # A stopped stack counts: its next request wakes it.
    field=urls; [ "$public" = 1 ] && field=public_urls
    url="$(stack_entry | json "u=d.get('$field') or ({'api': d.get('url')} if '$field' == 'urls' else {}); print(u.get('$service') or '' if d.get('state') in ('running', 'stopped') else '')")"
    if [ -z "$url" ]; then
      if [ "$public" = 1 ]; then echo "stack $tag has no public origin (no free slot, or public-setup never ran)" >&2
      else echo "no stack $tag (cloud-dev-stack.sh up --tag $tag first)" >&2; fi
      exit 3
    fi
    echo "$url"
    ;;
  logs) vm logs --tag "$tag" -n "$lines" ;;
  touch) vm touch --tag "$tag" ;;
  stop) ensure_helper; vm stop --tag "$tag" ;;
  down)
    ensure_helper
    echo "== down $tag"
    entry="$(vm down --tag "$tag" --reason down)"   # stops the stack and claims it for this release
    json "print('   VM: ' + (', '.join(d.get('actions') or []) or d.get('state','')))" <<<"$entry"
    release_db <<<"$entry"
    vm forget --tag "$tag" >/dev/null
    do_gc
    echo "== $tag is gone"
    ;;
  gc) ensure_helper; do_gc; vm reap >/dev/null; do_gc ;;
  public-setup)
    # Operator, once (again to add slots): needs the Cloudflare login of the account behind cmux.dev
    # (wrangler login). Deploys cmux-wdev-gateway, gives it the custom domains <svc>.s1..sN.wdev.cmux.dev
    # (about 150 s for new ones to get their certificates) and tells the VM which slots exist.
    ensure_helper
    gw="$root/scripts/cmux-next/cloud-dev-stack/gateway"
    WRANGLER="${CMUX_WRANGLER:-bunx wrangler@4.151.2}"
    echo "== deploy cmux-wdev-gateway"
    (cd "$gw" && $WRANGLER deploy -c wrangler.json 2>&1 | grep -E "Deployed|Uploaded|error|ERROR" || true)
    acct="$(json "print(d['account_id'])" <"$gw/wrangler.json")"
    token="$(cd "$gw" && $WRANGLER auth token 2>/dev/null | grep -Eo '[A-Za-z0-9._-]{30,}' | tail -1)"
    [ -n "$token" ] || die "no Cloudflare token from wrangler (wrangler login)"
    zone="$(CF_TOKEN="$token" python3 -I -c "
import json,os,urllib.request
r=urllib.request.Request('https://api.cloudflare.com/client/v4/zones?name=cmux.dev', headers={'Authorization':'Bearer '+os.environ['CF_TOKEN']})
print(json.load(urllib.request.urlopen(r, timeout=30))['result'][0]['id'])")" || die "cannot read the cmux.dev zone"
    echo "== custom domains for $slots slots"
    CF_TOKEN="$token" python3 -I - "$acct" "$zone" "$slots" <<'PY'
import json, os, sys, urllib.request, urllib.error
acct, zone, n = sys.argv[1], sys.argv[2], int(sys.argv[3])
h = {"Authorization": "Bearer " + os.environ["CF_TOKEN"], "Content-Type": "application/json"}
have = set()
page = 1
while True:
    r = urllib.request.Request(f"https://api.cloudflare.com/client/v4/accounts/{acct}/workers/domains?service=cmux-wdev-gateway&per_page=100&page={page}", headers=h)
    res = json.load(urllib.request.urlopen(r, timeout=60))["result"] or []
    have |= {d["hostname"] for d in res}
    if len(res) < 100:
        break
    page += 1
made = 0
for i in range(1, n + 1):
    for svc in ("api", "mobile", "hub"):
        host = f"{svc}.s{i}.wdev.cmux.dev"
        if host in have:
            continue
        body = json.dumps({"hostname": host, "service": "cmux-wdev-gateway", "zone_id": zone, "environment": "production"}).encode()
        try:
            urllib.request.urlopen(urllib.request.Request(f"https://api.cloudflare.com/client/v4/accounts/{acct}/workers/domains", data=body, headers=h, method="PUT"), timeout=60)
            made += 1
        except urllib.error.HTTPError as e:
            sys.exit(f"custom domain {host}: HTTP {e.code} {e.read()[:300]!r}")
print(f"   {len(have)} existed, {made} made")
PY
    python3 -I -c "import json,sys; print(json.dumps({'domain': 'wdev.cmux.dev', 'slots': [f's{i}' for i in range(1, int(sys.argv[1]) + 1)]}))" "$slots" | vm put-public
    echo "== the newest slot answers over HTTPS (new certificates take about 150 s)"
    for _ in $(seq 1 60); do
      code="$(curl -s -o /dev/null -w '%{http_code}' -m 10 "https://api.s$slots.wdev.cmux.dev/v1/health" || true)"
      [ "$code" != 000 ] && { echo "   https://api.s$slots.wdev.cmux.dev answers ($code)"; break; }
      sleep 5
    done
    ;;
  *) usage; exit 2 ;;
esac
