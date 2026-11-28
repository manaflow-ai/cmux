#!/usr/bin/env bash
# request-nightly-next.sh: feat-cmux-next asks main to promote a commit to
# nightly-next only when that commit's cmux-tui tree is published and
# verified. Its daemon tests are not awaited (2026-10-28). The build fleet's
# existing Release verdict is prechecked before the nightly starts its Mac
# build, signing and notarization.
# cmux-next.yml still asks after its Release compile, and cmux-tui-artifacts.yml
# and nightly-next-tick after the publication, so nightly-next always points at
# a commit the nightly can build with its own workflow and its own daemon.
#
# Regression: nightly-next runs 37767816879 and 37769010617 (2026-10-08) were
# promoted to 0b7998925b6c and 273cd24a512b, whose tree 4573d47a0116 was still
# building. The resolver fell back to older published trees, but every one of
# them sat before 0b7998925b6c's nightly.yml edit, so the tip's workflow could
# not build any of them and the run failed. No network: stub curl and gh.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
# git_q, and no background git maintenance in the scratch repositories.
# shellcheck source=scripts/cmux-next/tests/lib/git-fixture.sh
source "$ROOT/scripts/cmux-next/tests/lib/git-fixture.sh"
fail() { printf '%s\n' "$@" >&2; exit 1; }
sha() { shasum -a 256 "$1" | awk '{print $1}'; }
bin=cmux-tui-aarch64-apple-darwin

src="$TMP/src"
git_q init "$src"
mkdir -p "$src/cmux-tui" "$src/scripts/cmux-next" "$src/scripts/ci"
cp "$ROOT/scripts/cmux-next/pin-cmux-tui.sh" "$ROOT/scripts/cmux-next/tree-commit-marker.sh" "$src/scripts/cmux-next/"
[[ -f "$ROOT/scripts/cmux-next/request-nightly-next.sh" ]] \
  && cp "$ROOT/scripts/cmux-next/request-nightly-next.sh" "$src/scripts/cmux-next/"
cp "$ROOT/scripts/ci/cmux_tui_tree_key.py" "$src/scripts/ci/"
cp "$ROOT/scripts/cmux-next/nightly_quarantine.py" "$src/scripts/cmux-next/"
cp "$ROOT/scripts/cmux-next/cmux-tui-tree-inputs.txt" "$src/scripts/cmux-next/"
echo reducer > "$src/scripts/cmux-next/build-layout-reducer-ffi.sh"
"$ROOT/scripts/cmux-next/tests/lib/tree-inputs-fixture.sh" "$src"
echo one > "$src/cmux-tui/a"
mkdir -p "$src/.github/workflows"
# A real nightly.yml is large and names the gate early: a reader that stops at
# the first match must not turn that into a failure (feat-cmux-next push run
# 37818675501 refused 551654ba57bc, whose nightly.yml has the gate).
{ echo "env: {NIGHTLY_NEXT_NOTARY_PAUSED: x}"; for i in $(seq 1 20000); do echo "# filler line $i of a large workflow"; done; } > "$src/.github/workflows/nightly.yml"
git_q -C "$src" add -A
git_q -C "$src" commit -m one
git_q -C "$src" update-index --add --cacheinfo 160000,"$(git -C "$src" rev-parse HEAD)",ghostty
git_q -C "$src" commit -m gitlink
# origin is the fixture itself: nightly-next is read from it (absent until set).
git -C "$src" remote add origin "$src"
key() { (cd "$src" && python3 scripts/ci/cmux_tui_tree_key.py --version v2 "$1" 2>/dev/null); }

cdn="$TMP/cdn"
publish() { # <commit>: publish its tree, built by that commit
  local k; k=$(key "$1")
  mkdir -p "$cdn/tree/$k" "$cdn/$1"
  echo "build of $1" > "$cdn/tree/$k/$bin"
  sha "$cdn/tree/$k/$bin" > "$cdn/tree/$k/$bin.sha256"
  printf '{"key": "%s", "commit": "%s"}\n' "$k" "$1" > "$cdn/tree/$k/source.json"
  printf '{"commit": "%s", "binaries": {"%s": "%s"}}\n' "$1" "$bin" "$(sha "$cdn/tree/$k/$bin")" > "$cdn/$1/manifest.json"
}

mkdir -p "$TMP/bin" "$TMP/precheck"
# The CDN. With -w (tree-commit-marker.sh) it prints the HTTP status: 404 for a
# missing object, 500 for a path listed in $cdn/FAIL (or, for -w reads only, $cdn/FAILW). A tree-commit marker is
# served for every commit whose tree is published (the writer marks every ready
# commit), unless $cdn/unmarked lists the commit or $cdn/NOAUTO exists (the writer's own test).
cat > "$TMP/bin/curl" <<STUB
#!/usr/bin/env bash
out="" url="" fmt="" ua="" failflag=0
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    -o) out="\$2"; shift 2 ;;
    -w) fmt="\$2"; shift 2 ;;
    -A|--user-agent) ua="\$2"; shift 2 ;;
    -f*|--fail|--fail-with-body) failflag=1; shift ;;
    --proto|--retry|--retry-delay|--connect-timeout|--max-time) shift 2 ;;
    -*) shift ;;
    *) url="\$1"; shift ;;
  esac
done
# The build fleet's compile results service (the precheck): a passing record for every commit, unless
# $TMP/precheck/<sha> names another state, 404 (no record) or down (no answer).
if [[ "\$url" == https://gh-events.cmux.com/compile-checks/v1/* ]]; then
  echo "\$url" >> "$TMP/precheck.log"
  echo "\$ua" >> "$TMP/precheck-user-agents.log"
  [[ "\$ua" == cmux-ci-fleet-compile-result/1 ]] || { printf 403; exit 0; }
  c="\${url#https://gh-events.cmux.com/compile-checks/v1/}"; c="\${c%%\?*}"
  st=pass; [[ ! -f "$TMP/precheck/\$c" ]] || st="\$(cat "$TMP/precheck/\$c")"
  case "\$st" in
    down) printf 000; exit 7 ;;
    404) printf 404; exit 0 ;;
    429|503) printf "\$st"; exit 0 ;;
  esac
  printf '{"sha": "%s", "repo": "o/r", "recipe_version": 2, "configuration": "release-onone", "state": "%s"}\n' "\$c" "\$st" > "\${out:-/dev/stdout}"
  printf 200; exit 0
fi
path="\${url#https://files.cmux.com/cmux-tui/}"; path="\${path%%\?*}"
# A -w read of a path listed in $cdn/TRUNC transfers, reports its status, then
# fails (curl exit 18, a truncated transfer).
if [[ "\$path" != "\$url" && -n "\$fmt" ]] && grep -qxF "\$path" "$cdn/TRUNC" 2>/dev/null; then
  if [[ -f "$cdn/\$path" ]]; then [[ -z "\$out" ]] || cp "$cdn/\$path" "\$out"; printf 200; else printf 404; fi
  exit 18
fi
if [[ "\$path" != "\$url" ]] && { grep -qxF "\$path" "$cdn/FAIL" 2>/dev/null || { [[ -n "\$fmt" ]] && grep -qxF "\$path" "$cdn/FAILW" 2>/dev/null; }; }; then
  [[ -n "\$fmt" ]] && { printf 500; exit 0; }
  exit 22
fi
if [[ "\$path" == tree-commits/*.json && ! -f "$cdn/\$path" && ! -f "$cdn/NOAUTO" ]]; then
  c="\${path#tree-commits/}"; c="\${c%.json}"
  if ! grep -qxF "\$c" "$cdn/unmarked" 2>/dev/null \
     && k=\$(cd "$src" && python3 scripts/ci/cmux_tui_tree_key.py --version v2 "\$c" 2>/dev/null) \
     && [[ -f "$cdn/tree/\$k/source.json" ]]; then
    mkdir -p "$cdn/tree-commits"
    printf '{"commit": "%s", "key": "%s", "publishedBy": "%s", "markedBy": "u"}\n' "\$c" "\$k" "\$c" > "$cdn/\$path"
  fi
fi
if [[ "\$path" == "\$url" || ! -f "$cdn/\$path" ]]; then
  # curl --fail reports a 404 in -w output and exits 22. The downloader uses
  # that combination to distinguish a missing object from a transport error.
  if [[ -n "\$fmt" ]]; then
    printf 404
    (( failflag )) && exit 22
    exit 0
  fi
  exit 22
fi
if [[ -n "\$out" ]]; then cp "$cdn/\$path" "\$out"; else cat "$cdn/\$path"; fi
[[ -z "\$fmt" ]] || printf 200
STUB
# gh: records every call; the script reads no API (candidates come from git).
# The backfill's active-run counts (`api .../cmux-tui-artifacts.yml/runs`, one
# per status) print $TMP/gh-runs for in_progress and 0 for the other states, or
# fail when that file is missing (an unreadable list) or the status is not one
# the REST API knows. `run list` prints $TMP/gh-runs.
cat > "$TMP/bin/gh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP/gh.log"
if [[ "\$1 \$2" == "run list" ]]; then
  # \$TMP/gh-runs-json (a run list as JSON) is filtered by the call's own --jq.
  if [[ -f "$TMP/gh-runs-json" && " \$* " == *" --json status,conclusion,event "* ]]; then
    q=""; prev=""; for a in "\$@"; do [[ "\$prev" == --jq ]] && q="\$a"; prev="\$a"; done
    jq -r "\$q" "$TMP/gh-runs-json"; exit 0
  fi
  [[ -f "$TMP/gh-runs" ]] || exit 1
  cat "$TMP/gh-runs"; exit 0
fi
# The backfill's last-dispatch read: $TMP/gh-last-dispatch (a created_at), else no dispatch yet.
if [[ "\$1" == api && "\$2" == repos/*/actions/workflows/cmux-tui-artifacts.yml/runs\?branch=feat-cmux-next\&event=workflow_dispatch\&per_page=1 ]]; then
  [[ -f "$TMP/gh-last-dispatch" ]] && cat "$TMP/gh-last-dispatch"
  exit 0
fi
# The starved-run read (queued runs of one event for one commit): the ids of the
# "<id> <head_sha> <event>" lines of $TMP/gh-starved that match, else none. A
# run's jobs: $TMP/gh-jobs-<id> (the first job's created_at when it waits with no
# runner, as the --jq prints it), or a failed read when that file is missing.
if [[ "\$1" == api && "\$2" == repos/*/actions/workflows/cmux-tui-artifacts.yml/runs\?*"&event="* ]]; then
  q="\$2"; want_sha="\${q#*head_sha=}"; want_sha="\${want_sha%%&*}"; want_event="\${q#*&event=}"; want_event="\${want_event%%&*}"
  [[ -f "$TMP/gh-starved" ]] || exit 0
  while read -r id s e; do [[ "\$s" == "\$want_sha" && "\$e" == "\$want_event" ]] && echo "\$id"; done < "$TMP/gh-starved"
  exit 0
fi
if [[ "\$1" == api && "\$2" == repos/*/actions/runs/*/jobs\?* ]]; then
  id="\${2#repos/*/actions/runs/}"; id="\${id%%/*}"
  [[ -f "$TMP/gh-jobs-\$id" ]] || exit 1
  cat "$TMP/gh-jobs-\$id"; exit 0
fi
if [[ "\$1" == api && "\$2" == repos/*/actions/workflows/cmux-tui-artifacts.yml/runs\?* ]]; then
  if [[ -f "$TMP/gh-active-runs" ]]; then
    python3 - "\$2" "$TMP/gh-active-runs" <<'PY'
import json, sys
from urllib.parse import parse_qs, urlsplit
query = parse_qs(urlsplit(sys.argv[1]).query)
runs = json.load(open(sys.argv[2]))
print(sum(run['status'] == query['status'][0]
          and ('head_sha' not in query or run['head_sha'] == query['head_sha'][0])
          for run in runs))
PY
    exit \$?
  fi
  [[ -f "$TMP/gh-runs" ]] || exit 1
  case "\$2" in
    *"&status=in_progress&"*) cat "$TMP/gh-runs" ;;
    *"&status=queued&"*|*"&status=waiting&"*|*"&status=pending&"*|*"&status=requested&"*) echo 0 ;;
    *) echo "gh stub: unknown status in \$2" >&2; exit 1 ;;
  esac
  exit 0
fi
# The direct-push quarantine's history read: $TMP/gh-graphql's answer, else no status anywhere.
if [[ "\$1 \$2" == "api graphql" ]]; then
  if [[ -f "$TMP/gh-graphql" ]]; then cat "$TMP/gh-graphql"; else echo '{"data":{"repository":{}}}'; fi
  exit 0
fi
# A commit's full status list (REST, newest first): $TMP/gh-statuses-<sha>, else none.
if [[ "\$1" == api && "\$2" == repos/*/commits/*/statuses\?* ]]; then
  sha="\${2#repos/*/commits/}"; sha="\${sha%%/*}"
  if [[ -f "$TMP/gh-statuses-\$sha" && "\$2" == *"&page=1" ]]; then cat "$TMP/gh-statuses-\$sha"; else echo '[]'; fi
  exit 0
fi
[[ "\$1" == api ]] || exit 0
echo "gh stub: unexpected api call \$*" >&2; exit 1
STUB
chmod +x "$TMP/bin/curl" "$TMP/bin/gh"

request() { # <args...> -> output in $out, exit in $status
  status=0
  : > "$TMP/gh.log"
  out=$(cd "$src" && env -u GITHUB_STEP_SUMMARY -u GITHUB_OUTPUT -u CMUX_TUI_TREE_DISPATCH PATH="$TMP/bin:$PATH" \
    RUNNER_TEMP="$TMP/runner" GITHUB_RUN_ID="${RUN_ID:-1}" NIGHTLY_NEXT_PROMOTE="${PROMOTE-1}" \
    bash scripts/cmux-next/request-nightly-next.sh --repo o/r "$@" 2>&1) || status=$?
}
mkdir -p "$TMP/runner"
dispatched() { grep -qx "workflow run nightly.yml --repo o/r --ref main -f promote_nightly_next_sha=$1" "$TMP/gh.log"; }
backfilled() { grep -qx "workflow run cmux-tui-artifacts.yml --repo o/r --ref feat-cmux-next" "$TMP/gh.log"; }

# A cmux-tui change whose tree is still building is never promoted, even with
# a green Release compile: the nightly would have no daemon for it.
echo two > "$src/cmux-tui/a"; git_q -C "$src" add -A; git_q -C "$src" commit -m "tui two"
head=$(git -C "$src" rev-parse HEAD)
request --sha "$head" --release-compile-green
[[ "$status" == 0 ]] || fail "an unpublished tree is not an error (exit $status):" "$out"
! dispatched "$head" || fail "a commit whose tree is not published must not be promoted:" "$(cat "$TMP/gh.log")"
grep -q "not published" <<<"$out" || fail "the skip must say the tree is not published:" "$out"

# Once the tree publishes, the same green commit is promotable. Landings (cmux-next.yml,
# cmux-tui-artifacts.yml) only report it: N of them within one window dispatch nothing,
# and the 30-minute tick, the one caller that sets NIGHTLY_NEXT_PROMOTE=1, promotes once.
publish "$head"
for landing in 1 2 3; do
  PROMOTE="" request --sha "$head" --release-compile-green
  [[ "$status" == 0 ]] || fail "a landing's request must not fail (exit $status):" "$out"
  ! grep -q "workflow run nightly.yml" "$TMP/gh.log" || fail "a landing must not promote (landing $landing):" "$(cat "$TMP/gh.log")"
  grep -q "^promotable ${head:0:12}: .*30-minute nightly-next tick" <<<"$out" || fail "the landing must name the tick:" "$out"
done
PROMOTE=0 request --sha "$head" --release-compile-green
! grep -q "workflow run nightly.yml" "$TMP/gh.log" || fail "only NIGHTLY_NEXT_PROMOTE=1 promotes:" "$(cat "$TMP/gh.log")"
request --sha "$head" --release-compile-green
[[ "$status" == 0 ]] && dispatched "$head" || fail "a green commit with a published tree must be promoted (exit $status):" "$out" "$(cat "$TMP/gh.log")"
[[ "$(grep -c "workflow run nightly.yml" "$TMP/gh.log")" == 1 ]] || fail "the tick requests one promotion:" "$(cat "$TMP/gh.log")"
grep -q '^cmux-ci-fleet-compile-result/1$' "$TMP/precheck-user-agents.log" \
  || fail "the precheck must identify its fleet compile client:" "$(cat "$TMP/precheck-user-agents.log")"

# A red Release verdict refuses the candidate before the strings, tree marker
# and promotion dispatch. Busy service answers are also deferred to a later
# tick, while a confirmed outage keeps the cache from blocking promotion.
echo fail > "$TMP/precheck/$head"
RUN_ID=2 request --sha "$head" --release-compile-green
[[ "$status" == 0 ]] && ! dispatched "$head" || fail "a red fleet verdict must refuse promotion:" "$out" "$(cat "$TMP/gh.log")"
grep -q "precheck red" <<<"$out" || fail "the refusal must identify a red precheck:" "$out"
run_id=3
for busy in 429 503; do
  echo "$busy" > "$TMP/precheck/$head"
  RUN_ID=$run_id request --sha "$head" --release-compile-green
  [[ "$status" == 0 ]] && ! dispatched "$head" || fail "HTTP $busy must defer promotion:" "$out" "$(cat "$TMP/gh.log")"
  grep -q "not prechecked yet" <<<"$out" || fail "HTTP $busy must be reported as pending:" "$out"
  run_id=$((run_id + 1))
done
rm -f "$TMP/precheck/$head"

# A notes-only child with no own record can reuse the nearest passing ancestor
# because the nightly app and bundled cmux-tui tree are unchanged. An app
# change cannot reuse that verdict, even though it has the same cmux-tui key.
cat > "$src/scripts/ci/nightly_build_inputs.py" <<'PY'
import json
import sys

paths = [line.strip() for line in sys.stdin if line.strip()]
hit = [path for path in paths if path == "App.swift"]
print(json.dumps({"build_inputs_changed": bool(hit),
                  "reason": f"{hit[0]} reaches the app" if hit else "no app input changed"}))
PY
echo notes > "$src/NOTES.md"
git_q -C "$src" add -A
git_q -C "$src" commit -m "notes-only precheck child"
child=$(git -C "$src" rev-parse HEAD)
publish "$child"
echo 404 > "$TMP/precheck/$child"
RUN_ID=5 request --sha "$child" --release-compile-green
[[ "$status" == 0 ]] && dispatched "$child" || fail "a same-app ancestor pass must be reusable:" "$out" "$(cat "$TMP/gh.log")"
grep -q "nothing that reaches the app changed since" <<<"$out" && grep -q "compiled .* in Release" <<<"$out" \
  || fail "the reused ancestor must be named in the precheck reason:" "$out"

echo app-change > "$src/App.swift"
git_q -C "$src" add -A
git_q -C "$src" commit -m "app change without own precheck"
changed=$(git -C "$src" rev-parse HEAD)
publish "$changed"
echo 404 > "$TMP/precheck/$changed"
RUN_ID=6 request --sha "$changed" --release-compile-green
[[ "$status" == 0 ]] && ! dispatched "$changed" || fail "an app change must not reuse an ancestor verdict:" "$out" "$(cat "$TMP/gh.log")"
grep -q "not prechecked yet" <<<"$out" || fail "the changed app must remain pending:" "$out"

echo down > "$TMP/precheck/$changed"
RUN_ID=7 NIGHTLY_NEXT_PRECHECK_DEPTH=0 request --sha "$changed" --release-compile-green
[[ "$status" == 0 ]] && dispatched "$changed" || fail "a confirmed results outage must not block promotion:" "$out" "$(cat "$TMP/gh.log")"
grep -q "results service did not answer" <<<"$out" || fail "the outage warning must be visible:" "$out"
grep -q "answered HTTP 000 (curl exit 7)" <<<"$out" || fail "the outage warning must name the HTTP code and curl exit:" "$out"

echo fail > "$TMP/precheck/$changed"
RUN_ID=8 NIGHTLY_NEXT_PRECHECK=0 request --sha "$changed" --release-compile-green
[[ "$status" == 0 ]] && dispatched "$changed" || fail "the explicit precheck opt-out must preserve promotion:" "$out" "$(cat "$TMP/gh.log")"
grep -q "precheck is off" <<<"$out" || fail "the opt-out reason must be visible:" "$out"

# A superseded record (the controller checked a newer push tip instead, and that check covers this
# push's commits) is covered by the first checked tip after it on feat-cmux-next when that tip passed.
# Most feat-cmux-next commits are superseded and the tree publisher keeps one push per window, so
# requiring both on one commit left the dedicated Macs idle for hours (11-25). Here the covering tip's
# own tree is not published, so only the superseded commit can be promoted.
echo superseded-app > "$src/App.swift"
git_q -C "$src" add -A
git_q -C "$src" commit -m "app change superseded by a later push tip"
covered=$(git -C "$src" rev-parse HEAD)
publish "$covered"
echo superseded > "$TMP/precheck/$covered"
echo three > "$src/cmux-tui/a"
git_q -C "$src" add -A
git_q -C "$src" commit -m "the push tip the controller checked"
checked=$(git -C "$src" rev-parse HEAD)
git_q -C "$src" update-ref refs/heads/feat-cmux-next "$checked"
git_q -C "$src" checkout -q --detach "$covered"
RUN_ID=9 request --sha "$covered" --release-compile-green
[[ "$status" == 0 ]] && dispatched "$covered" || fail "a superseded commit whose covering tip passed must be promoted:" "$out" "$(cat "$TMP/gh.log")"
grep -q "superseded by ${checked:0:12}" <<<"$out" || fail "the covering tip must be named in the precheck reason:" "$out"
run_id=10
for word in fail running; do
  echo "$word" > "$TMP/precheck/$checked"
  RUN_ID=$run_id request --sha "$covered" --release-compile-green
  [[ "$status" == 0 ]] && ! dispatched "$covered" || fail "a superseded commit whose covering tip is $word must wait:" "$out" "$(cat "$TMP/gh.log")"
  grep -q "${covered:0:12}: not prechecked yet" <<<"$out" || fail "the $word covering tip must leave it pending:" "$out"
  run_id=$((run_id + 1))
done
git_q -C "$src" update-ref -d refs/heads/feat-cmux-next
git_q -C "$src" checkout -q --detach "$head"

# A direct push red on feat-cmux-next's push runs quarantines its commit (the status cmuxterm-hq's base-red-watch
# posts, read by scripts/cmux-next/nightly_quarantine.py): it is not promoted until a later push is green. The shape is
# 11-12's e0d3bb0ec2f0 by lawrencecchen.
# The read is one lookup per first-parent commit (c0, c1, ...); only the cmux-bot app's statuses count. GraphQL names
# it as GitHub does here: login cmux-bot, __typename Bot (REST's cmux-bot[bot] is accepted too).
status_node() { # <commit> <state> [creator login] [creator type]
  printf '{"oid":"%s","author":{"user":{"login":"lawrencecchen"},"name":"Lawrence Chen"},"status":{"context":{"state":"%s","description":"red: base %s since e0d3bb0ec2f0 by lawrencecchen","creator":{"__typename":"%s","login":"%s"}}}}' \
    "$1" "$2" "$(printf '4%.0s' {1..40})" "${4:-Bot}" "${3:-cmux-bot}"
}
statuses() { # <node>...: the GraphQL answer
  local body="" i=0 node
  for node in "$@"; do body+="${body:+,}\"c$i\":$node"; i=$((i + 1)); done
  printf '{"data":{"repository":{%s}}}\n' "$body" > "$TMP/gh-graphql"
}
quarantine() { # <state> <commit>
  statuses "$(status_node "$2" "$1")"
}
quarantine FAILURE "$head"
request --sha "$head" --release-compile-green
[[ "$status" == 0 ]] || fail "a quarantined commit is not an error (exit $status):" "$out"
! dispatched "$head" || fail "a quarantined commit must not be promoted:" "$(cat "$TMP/gh.log")"
grep -q "quarantined since direct push e0d3bb0ec2f0 by lawrencecchen" <<<"$out" || fail "the skip must name the push:" "$out"
# The tick walks up to 120 commits, each a call of this script: GH_TICK_CACHE keeps the one read for the tick.
GH_TICK_CACHE="$TMP/tick" request --sha "$head" --release-compile-green
GH_TICK_CACHE="$TMP/tick" request --sha "$head" --release-compile-green
! dispatched "$head" || fail "a cached quarantine must still hold the commit:" "$(cat "$TMP/gh.log")"
[[ "$(grep -c '^api graphql ' "$TMP/gh.log")" == 0 ]] || fail "the tick's second call must read the quarantine from its cache:" "$(cat "$TMP/gh.log")"
# Anyone with write access can post the context: a status from another creator neither sets nor lifts it, and the
# script says it ignored one.
statuses "$(status_node "$head" FAILURE someone)"
request --sha "$head" --release-compile-green
[[ "$status" == 0 ]] && dispatched "$head" || fail "a failure from another creator must not quarantine:" "$out"
parent=$(git -C "$src" rev-parse "$head^")
statuses "$(status_node "$head" SUCCESS someone)" "$(status_node "$parent" FAILURE)"
request --sha "$head" --release-compile-green
! dispatched "$head" || fail "a success from another creator must not lift the quarantine:" "$(cat "$TMP/gh.log")"
log=$(cd "$src" && PATH="$TMP/bin:$PATH" python3 scripts/cmux-next/nightly_quarantine.py quarantined --repo o/r --tip "$head" 2>&1 >/dev/null)
grep -q "ignored a cmux-next/direct-push-gates status (SUCCESS) on ${head:0:12} from someone" <<<"$log" \
  || fail "the ignored status must be named with its creator:" "$log"
# GraphQL's status.context is only the latest status of the context: a SUCCESS anyone posts over the publisher's
# FAILURE must not hide it (Codex BLOCK on #42343 at 28980e76). The publisher's newest verdict is read from the
# commit's full status list, and only for a commit whose latest status is someone else's.
statuses "$(status_node "$head" SUCCESS someone User)"
printf '[{"context":"cmux-next/direct-push-gates","state":"success","description":"","creator":{"login":"someone","type":"User"}},{"context":"cmux-next/direct-push-gates","state":"failure","description":"red: base %s since e0d3bb0ec2f0 by lawrencecchen","creator":{"login":"cmux-bot[bot]","type":"Bot"}}]\n' \
  "$(printf '4%.0s' {1..40})" > "$TMP/gh-statuses-$head"
request --sha "$head" --release-compile-green
! dispatched "$head" || fail "a forged success over the publisher's failure must not lift the quarantine:" "$(cat "$TMP/gh.log")"
grep -q "^api repos/o/r/commits/$head/statuses" "$TMP/gh.log" || fail "the forged latest status must send the read to the full list:" "$(cat "$TMP/gh.log")"
rm -f "$TMP/gh-statuses-$head"
# A user who registers the bare login cmux-bot is a User, not the app: its success does not lift it either. REST's
# cmux-bot[bot] form of the app still counts (cmux#42343 review F1).
statuses "$(status_node "$head" SUCCESS cmux-bot User)" "$(status_node "$parent" FAILURE)"
request --sha "$head" --release-compile-green
! dispatched "$head" || fail "a User named cmux-bot must not lift the quarantine:" "$(cat "$TMP/gh.log")"
statuses "$(status_node "$head" FAILURE 'cmux-bot[bot]')"
request --sha "$head" --release-compile-green
! dispatched "$head" || fail "the app's REST login form must still quarantine:" "$(cat "$TMP/gh.log")"
# Only the first-parent line the nightly promotes from is read: a side branch's success does not lift it (Codex F1 on
# #42248), and the read asks for exactly those commits.
statuses "$(status_node "$(printf '5%.0s' {1..40})" SUCCESS)" "$(status_node "$parent" FAILURE)"
request --sha "$head" --release-compile-green
! dispatched "$head" || fail "a success off the first-parent line must not lift the quarantine:" "$(cat "$TMP/gh.log")"
grep -q "object(oid:\"$head\")" "$TMP/gh.log" && grep -q "object(oid:\"$parent\")" "$TMP/gh.log" \
  || fail "the read must ask for the first-parent commits:" "$(cat "$TMP/gh.log")"
quarantine SUCCESS "$head"
request --sha "$head" --release-compile-green
[[ "$status" == 0 ]] && dispatched "$head" || fail "once a push's gates pass the commit is promoted:" "$out"
rm -f "$TMP/gh-graphql"

# A later app-only commit shares the published tree (the key is content-addressed).
echo app > "$src/App.swift"; git_q -C "$src" add -A; git_q -C "$src" commit -m "app only"
app=$(git -C "$src" rev-parse HEAD)
request --sha "$app" --release-compile-green
[[ "$status" == 0 ]] && dispatched "$app" || fail "an app-only commit on a published tree must be promoted:" "$out"

# A newer cmux-tui change (another tree) whose Release compile is green.
git_q -C "$src" checkout -q -b side "$app"
echo three > "$src/cmux-tui/a"; git_q -C "$src" add -A; git_q -C "$src" commit -m "tui three"
other=$(git -C "$src" rev-parse HEAD)
git_q -C "$src" checkout -q --detach "$head"

# From the artifacts workflow, once the tree of $head is published: it asks for
# the newest feat-cmux-next commit (first-parent history) with the same tree.
# The app-only commit's own artifacts run was replaced by a newer push, so this
# is its only request.
branch() { # <commit>: feat-cmux-next's tip (the script's history, fetched or local)
  git_q -C "$src" update-ref refs/heads/feat-cmux-next "$1"
}
# No REST read. The one exception is the direct-push quarantine's single GraphQL read (its own budget, kept for the
# whole tick in GH_TICK_CACHE), made only once a candidate is about to be requested. The other allowed read is
# web_matrix_green's one commit-statuses read of the candidate (cmux-next/web-bundle-matrix, added by #61541).
no_api() {
  ! grep -v -e '^api graphql ' -e '^api repos/o/r/commits/[0-9a-f]*/statuses?per_page=100 --jq .*cmux-next/web-bundle-matrix' "$TMP/gh.log" | grep -q '^api' || fail "--tree-ready must read no GitHub REST API:" "$(cat "$TMP/gh.log")"
  (( $(grep -c '^api graphql ' "$TMP/gh.log") <= 1 )) || fail "the quarantine is read once a call:" "$(cat "$TMP/gh.log")"
}
branch "$other"
request --tree-ready "$head"
[[ "$status" == 0 ]] && dispatched "$app" || fail "the newest commit with the published tree must be promoted (exit $status):" "$out" "$(cat "$TMP/gh.log")"
no_api
! dispatched "$other" || fail "a commit with another, unpublished tree must not be promoted"
! dispatched "$head" || fail "only the newest matching commit is requested"

# Exit 127 from the tree-key helper is an operational failure, not a
# candidate to skip. Keep this guard close to the fixture so the promotion test
# fails if the fail-closed branch is removed.
grep -q 'key_rc == 127' "$ROOT/scripts/cmux-next/request-nightly-next.sh" \
  || fail "tree-key helper launch failures must fail the promotion job"

# A commit with no cmux-next.yml push run (a bot or GITHUB_TOKEN push, such as
# a base autofix, starts none) is a candidate like any other: its Release
# compile is never read (2026-10-26), its nightly compiles it.
git_q -C "$src" checkout -q -b botpush "$app"
echo autofix > "$src/Autofix.swift"; git_q -C "$src" add -A
git -c user.name=github-actions[bot] -c user.email=bot@example.com -C "$src" commit -q -m "chore(next): base autofix"
bot=$(git -C "$src" rev-parse HEAD)
git_q -C "$src" checkout -q --detach "$head"
branch "$bot"
request --tree-ready "$head"
[[ "$status" == 0 ]] && dispatched "$bot" && ! dispatched "$app" && ! dispatched "$head" \
  || fail "a bot-pushed tip with the published tree must be requested itself (exit $status):" "$out" "$(cat "$TMP/gh.log")"
no_api
branch "$other"

# A commit with the same tree that does not descend from the published one
# (an older line of history) is never requested: only commits from the tree's
# publisher onward are candidates, so the job reads a short window.
git_q -C "$src" checkout -q -b aside "$head^"
echo two > "$src/cmux-tui/a"; echo aside > "$src/Aside.swift"; git_q -C "$src" add -A; git_q -C "$src" commit -m "same tree, other line"
aside=$(git -C "$src" rev-parse HEAD)
[[ "$(key "$aside")" == "$(key "$head")" ]] || fail "fixture: the aside commit must share the tree"
git_q -C "$src" checkout -q --detach "$head"
branch "$aside"
request --tree-ready "$head"
[[ "$status" == 0 ]] && dispatched "$head" && ! dispatched "$aside" \
  || fail "a same-tree commit that does not descend from the publisher must not be requested:" "$out" "$(cat "$TMP/gh.log")"

# A commit that is not in feat-cmux-next's history never counts.
branch "$head"
request --tree-ready "$head"
[[ "$status" == 0 ]] && dispatched "$head" && ! dispatched "$app" \
  || fail "a commit off feat-cmux-next must not be requested (exit $status):" "$out" "$(cat "$TMP/gh.log")"

# A commit whose nightly.yml has no NIGHTLY_NEXT_NOTARY_PAUSED gate would
# notarize while the pause is on: never promoted, from either side.
git_q -C "$src" checkout -q -b nogate "$head"
echo "env: {}" > "$src/.github/workflows/nightly.yml"; git_q -C "$src" add -A; git_q -C "$src" commit -m "workflow without the gate"
nogate=$(git -C "$src" rev-parse HEAD)
request --sha "$nogate" --release-compile-green
[[ "$status" == 0 ]] && ! dispatched "$nogate" || fail "a commit without the notary gate must not be promoted (exit $status):" "$out" "$(cat "$TMP/gh.log")"
grep -q "NIGHTLY_NEXT_NOTARY_PAUSED" <<<"$out" || fail "the refusal must name the gate:" "$out"
branch "$nogate"
git_q -C "$src" checkout -q --detach "$head"
request --tree-ready "$head"
[[ "$status" == 0 ]] && dispatched "$head" && ! dispatched "$nogate" \
  || fail "--tree-ready must pass over a newer commit without the gate for the gated publisher:" "$out" "$(cat "$TMP/gh.log")"

# The --tree-ready search must finish inside its job: it fetches the branch's
# recent history in one call and reads no API. Run 37779960297's request job
# paginated every cmux-next push run, then fetched up to 30 commits one at a
# time, and hit the timeout, so nothing was promoted after 12:46Z on 2026-10-08.
branch "$other"
request --tree-ready "$head"
no_api
git -C "$src" config uploadpack.allowAnySHA1InWant true
git -C "$src" update-ref refs/heads/feat-cmux-next "$other"
shallow="$TMP/shallow"
git_q clone -q --no-local --depth=1 "file://$src" "$shallow"
# The git binary, never a wrapper on PATH that would exec this shim again (tests/real_git.py).
real_git=$(python3 "$ROOT/tests/real_git.py") || exit 2
mkdir -p "$TMP/gitbin"
cat > "$TMP/gitbin/git" <<STUB
#!/usr/bin/env bash
for arg in "\$@"; do [[ "\$arg" == fetch ]] && { printf '%s\n' "\$*" >> "$TMP/git.log"; break; }; done
exec "$real_git" "\$@"
STUB
chmod +x "$TMP/gitbin/git"
: > "$TMP/git.log"; : > "$TMP/gh.log"
status=0
out=$(cd "$shallow" && env -u GITHUB_STEP_SUMMARY -u GITHUB_OUTPUT -u CMUX_TUI_TREE_DISPATCH PATH="$TMP/gitbin:$TMP/bin:$PATH" NIGHTLY_NEXT_PROMOTE=1 \
  bash scripts/cmux-next/request-nightly-next.sh --repo o/r --tree-ready "$head" 2>&1) || status=$?
[[ "$status" == 0 ]] && dispatched "$app" || fail "a shallow checkout must still promote the newest green commit (exit $status):" "$out" "$(cat "$TMP/gh.log")"
fetches=$(grep -c . "$TMP/git.log" || true)
[[ "$fetches" -le 1 ]] || fail "the missing commits must be fetched in one call, got $fetches:" "$(cat "$TMP/git.log")"

# A commit whose generated page strings are stale fails the nightly's web
# bundle step 30 minutes in (nightly-next run 38348747848): never promoted.
# A stub node stands in for gen-strings (exit 1 = stale, or since #21946, for a
# commit that no longer tracks the tables, a missing translation).
git_q -C "$src" checkout -q -b strings "$app"
mkdir -p "$src/webviews/scripts/pages"; echo "// gen-strings" > "$src/webviews/scripts/pages/gen-strings.mjs"
git_q -C "$src" add -A; git_q -C "$src" commit -m "app with page strings"
strings=$(git -C "$src" rev-parse HEAD)
# The stub reads the commit it runs in: a STALE marker beside gen-strings.mjs means stale strings.
printf '#!/usr/bin/env bash\n[[ "$*" == *"gen-strings.mjs"* ]] || exit 9\n[[ ! -f scripts/pages/STALE ]] || exit 1\nexit "${STUB_STRINGS_EXIT:-0}"\n' > "$TMP/bin/node"; chmod +x "$TMP/bin/node"
STUB_STRINGS_EXIT=1 request --sha "$strings" --release-compile-green
[[ "$status" == 0 ]] && ! dispatched "$strings" || fail "a commit with stale page strings must not be promoted (exit $status):" "$out" "$(cat "$TMP/gh.log")"
grep -q "page strings are stale" <<<"$out" || fail "the refusal must name the stale strings:" "$out"
STUB_STRINGS_EXIT=0 request --sha "$strings" --release-compile-green
[[ "$status" == 0 ]] && dispatched "$strings" || fail "fresh page strings must not block the promotion (exit $status):" "$out" "$(cat "$TMP/gh.log")"
# --tree-ready checks every candidate, not only the checkout (cx-5hvb5): a newer
# green commit with stale strings is passed over for the older fresh one, and a
# newer fresh commit is requested. Each candidate is checked in its own tree.
echo fresh > "$src/Fresh.swift"; git_q -C "$src" add -A; git_q -C "$src" commit -m "fresh strings"
fresh=$(git -C "$src" rev-parse HEAD)
echo stale > "$src/webviews/scripts/pages/STALE"; git_q -C "$src" add -A; git_q -C "$src" commit -m "stale strings"
stale=$(git -C "$src" rev-parse HEAD)
[[ "$(key "$stale")" == "$(key "$head")" && "$(key "$fresh")" == "$(key "$head")" ]] || fail "fixture: the strings commits must share the published tree"
git_q -C "$src" checkout -q --detach "$head"
branch "$stale"
request --tree-ready "$head"
[[ "$status" == 0 ]] && dispatched "$fresh" && ! dispatched "$stale" \
  || fail "--tree-ready must pass over a newer commit with stale strings for the older fresh one (exit $status):" "$out" "$(cat "$TMP/gh.log")"
grep -q "${stale:0:12}: its generated page strings are stale" <<<"$out" || fail "the skip must name the stale commit:" "$out"
[[ "$(git -C "$src" worktree list | wc -l | tr -d ' ')" == 1 ]] || fail "the candidate worktrees must be removed:" "$(git -C "$src" worktree list)"
git_q -C "$src" checkout -q -b strings2 "$stale"
rm "$src/webviews/scripts/pages/STALE"; git_q -C "$src" add -A; git_q -C "$src" commit -m "strings fresh again"
fresh2=$(git -C "$src" rev-parse HEAD)
git_q -C "$src" checkout -q --detach "$head"
branch "$fresh2"
request --tree-ready "$head"
[[ "$status" == 0 ]] && dispatched "$fresh2" && ! dispatched "$fresh" \
  || fail "--tree-ready must request a newer commit whose strings are fresh (exit $status):" "$out" "$(cat "$TMP/gh.log")"
# At most CMUX_NIGHTLY_NEXT_MAX_REFUSED unpromotable candidates are passed over.
branch "$stale"
CMUX_NIGHTLY_NEXT_MAX_REFUSED=1 request --tree-ready "$head"
[[ "$status" == 0 ]] && ! dispatched "$fresh" && ! dispatched "$stale" \
  || fail "the search must stop after CMUX_NIGHTLY_NEXT_MAX_REFUSED refusals (exit $status):" "$out" "$(cat "$TMP/gh.log")"
rm -f "$TMP/bin/node"
# A runner with no node cannot check the strings, which is no proof they are
# fresh: the promoting run (NIGHTLY_NEXT_PROMOTE=1) fails red and requests
# nothing. A run that only reports still reports, with a warning.
nonode="$TMP/nonode"; mkdir -p "$nonode"
IFS=: read -r -a path_dirs <<<"$TMP/bin:$PATH"
for dir in "${path_dirs[@]}"; do
  for tool in "$dir"/*; do
    name="${tool##*/}"
    [[ "$name" != node && -x "$tool" && ! -e "$nonode/$name" ]] || continue
    ln -s "$tool" "$nonode/$name"
  done
done
git_q -C "$src" checkout -q --detach "$strings"
status=0; : > "$TMP/gh.log"
out=$(cd "$src" && env -u GITHUB_STEP_SUMMARY -u GITHUB_OUTPUT -u CMUX_TUI_TREE_DISPATCH PATH="$nonode" \
  RUNNER_TEMP="$TMP/runner" GITHUB_RUN_ID=1 NIGHTLY_NEXT_PROMOTE=1 \
  bash scripts/cmux-next/request-nightly-next.sh --repo o/r --sha "$strings" --release-compile-green 2>&1) || status=$?
[[ "$status" == 1 ]] && ! dispatched "$strings" \
  || fail "a promoting run without node must fail and request nothing (exit $status):" "$out" "$(cat "$TMP/gh.log")"
grep -q "no node" <<<"$out" || fail "the failure must name the missing node:" "$out"
status=0; : > "$TMP/gh.log"
out=$(cd "$src" && env -u GITHUB_STEP_SUMMARY -u GITHUB_OUTPUT -u CMUX_TUI_TREE_DISPATCH PATH="$nonode" \
  RUNNER_TEMP="$TMP/runner" GITHUB_RUN_ID=1 NIGHTLY_NEXT_PROMOTE= \
  bash scripts/cmux-next/request-nightly-next.sh --repo o/r --sha "$strings" --release-compile-green 2>&1) || status=$?
[[ "$status" == 0 ]] && ! grep -q "workflow run nightly.yml" "$TMP/gh.log" \
  || fail "a reporting run without node must not fail (exit $status):" "$out"
grep -q "not checked" <<<"$out" || fail "the report must say the strings were not checked:" "$out"
git_q -C "$src" checkout -q --detach "$head"

# A tree published before its daemon tests ended (source.json daemonTests
# "separate", chief 2026-10-13) is promoted without daemon-tests.json: since
# 2026-10-28 no nightly waits on the daemon tests (run 40651931144's failed
# Zig download held the feed for hours). Leo, 2026-10-23: "we want no smoke tests".
publish "$other"
okey=$(key "$other")
printf '{"key": "%s", "commit": "%s", "daemonTests": "separate"}\n' "$okey" "$other" > "$cdn/tree/$okey/source.json"
git_q -C "$src" checkout -q --detach "$other"
request --sha "$other" --release-compile-green
[[ "$status" == 0 ]] && dispatched "$other" \
  || fail "a published tree without its daemon-tests marker must be promoted (exit $status):" "$out" "$(cat "$TMP/gh.log")"
rc=0; tout=$(cd "$src" && PATH="$TMP/bin:$PATH" bash scripts/cmux-next/tree-commit-marker.sh tree-ready "$okey" 2>&1) || rc=$?
[[ "$rc" == 0 && "$tout" == "publishedBy=$other" ]] \
  || fail "tree-ready must answer ready for a published tree with no daemon-tests marker (exit $rc):" "$tout"

# daemon-tested (kept for its other callers) still reads the marker: 1 without
# it, 0 with it, and a read of source.json that is neither 200 nor 404 is a
# read failure (row 18 of the 2026-10-27 audit), never a pass.
rc=0; (cd "$src" && PATH="$TMP/bin:$PATH" bash scripts/cmux-next/tree-commit-marker.sh daemon-tested "$okey" >/dev/null 2>&1) || rc=$?
[[ "$rc" == 1 ]] || fail "daemon-tested without daemon-tests.json must exit 1, got $rc"
printf '{"key": "%s", "result": "success"}\n' "$okey" > "$cdn/tree/$okey/daemon-tests.json"
rc=0; (cd "$src" && PATH="$TMP/bin:$PATH" bash scripts/cmux-next/tree-commit-marker.sh daemon-tested "$okey" >/dev/null 2>&1) || rc=$?
[[ "$rc" == 0 ]] || fail "daemon-tested with daemon-tests.json must exit 0, got $rc"
echo "tree/$okey/source.json" > "$cdn/FAILW"
rc=0; (cd "$src" && PATH="$TMP/bin:$PATH" bash scripts/cmux-next/tree-commit-marker.sh daemon-tested "$okey" >/dev/null 2>&1) || rc=$?
[[ "$rc" == 3 ]] || fail "daemon-tested on a source.json read failure must exit 3, got $rc"
rm -f "$cdn/FAILW"
# A source.json transfer that fails after a 200 (curl exit 18) is a read failure too.
echo "tree/$okey/source.json" > "$cdn/TRUNC"
rc=0; (cd "$src" && PATH="$TMP/bin:$PATH" bash scripts/cmux-next/tree-commit-marker.sh daemon-tested "$okey" >/dev/null 2>&1) || rc=$?
[[ "$rc" == 3 ]] || fail "daemon-tested on a truncated read must exit 3, got $rc"
rm -f "$cdn/TRUNC"

# The tree-commit marker (tree-commit-marker.sh check): main's promote guard
# requires it, so a commit whose tree is ready but which has no marker is not
# requested, and one cmux-tui-artifacts dispatch backfills it, at most once per
# job and never while an artifacts run is queued or running.
echo "$other" > "$cdn/unmarked"; rm -f "$cdn/tree-commits/$other.json"
echo 0 > "$TMP/gh-runs"
RUN_ID=11 request --sha "$other" --release-compile-green
[[ "$status" == 0 ]] && ! dispatched "$other" && backfilled && grep -q "no tree-commit marker" <<<"$out" \
  || fail "a ready tree without its marker must backfill, not promote (exit $status):" "$out" "$(cat "$TMP/gh.log")"
RUN_ID=11 request --sha "$other" --release-compile-green
! backfilled && grep -q "already dispatched in this job" <<<"$out" \
  || fail "the backfill must dispatch at most once per job:" "$out" "$(cat "$TMP/gh.log")"
# At most one backfill per gap (25 min since #59970; an hour before): every tick and Release compile calls
# it from its own job, so the per-job stamp alone let 51 dispatches through in 31 h (ci-min-per-pr-14).
date -u -d '-10 minutes' +%Y-%m-%dT%H:%M:%SZ > "$TMP/gh-last-dispatch"
RUN_ID=13 request --sha "$other" --release-compile-green
[[ "$status" == 0 ]] && ! backfilled && grep -q "min ago (gap 25 min)" <<<"$out" \
  || fail "no backfill within the gap of the last dispatch:" "$out" "$(cat "$TMP/gh.log")"
date -u -d '-61 minutes' +%Y-%m-%dT%H:%M:%SZ > "$TMP/gh-last-dispatch"
RUN_ID=14 request --sha "$other" --release-compile-green
[[ "$status" == 0 ]] && backfilled \
  || fail "a backfill an hour after the last dispatch must dispatch:" "$out" "$(cat "$TMP/gh.log")"
rm -f "$TMP/gh-last-dispatch"
echo 2 > "$TMP/gh-runs"
RUN_ID=12 request --sha "$other" --release-compile-green
! backfilled && grep -q "queued or running" <<<"$out" \
  || fail "no backfill while an artifacts run is active:" "$out" "$(cat "$TMP/gh.log")"
# Recovery dispatches the current branch tip, even when this request checks an
# older commit's marker. Only active runs of that dispatch source suppress it.
backfill_tip=$(git -C "$src" rev-parse refs/heads/feat-cmux-next)
branch "$other"
printf '[{"head_sha":"%s","status":"in_progress"}]\n' "$head" > "$TMP/gh-active-runs"
RUN_ID=120 request --sha "$other" --release-compile-green
[[ "$status" == 0 ]] && backfilled \
  || fail "an unrelated active tree must not suppress marker backfill:" "$out" "$(cat "$TMP/gh.log")"
for active_state in queued in_progress waiting pending requested; do
  printf '[{"head_sha":"%s","status":"%s"}]\n' "$other" "$active_state" > "$TMP/gh-active-runs"
  RUN_ID="121-$active_state" request --sha "$other" --release-compile-green
  ! backfilled && grep -q "queued or running" <<<"$out" \
    || fail "an active dispatch-source run ($active_state) must suppress backfill:" "$out" "$(cat "$TMP/gh.log")"
done
branch "$head"
printf '[{"head_sha":"%s","status":"queued"}]\n' "$head" > "$TMP/gh-active-runs"
RUN_ID=122 request --sha "$other" --release-compile-green
! backfilled && grep -q "queued or running" <<<"$out" \
  || fail "backfill must check the remote dispatch tip, not the older marker candidate:" "$out" "$(cat "$TMP/gh.log")"
branch "$backfill_tip"
rm -f "$TMP/gh-active-runs"
rm -f "$TMP/gh-runs"
RUN_ID=13 request --sha "$other" --release-compile-green
! backfilled && grep -q "could not read the cmux-tui-artifacts runs" <<<"$out" \
  || fail "no backfill when the runs cannot be read:" "$out" "$(cat "$TMP/gh.log")"
# A marker read failure never promotes and never dispatches.
rm -f "$cdn/unmarked"; echo "tree-commits/$other.json" > "$cdn/FAIL"; echo 0 > "$TMP/gh-runs"
RUN_ID=14 request --sha "$other" --release-compile-green
[[ "$status" == 0 ]] && ! dispatched "$other" && ! backfilled && grep -q "read failure on its tree-commit marker" <<<"$out" \
  || fail "a marker read failure must neither promote nor backfill (exit $status):" "$out" "$(cat "$TMP/gh.log")"
rm -f "$cdn/FAIL" "$TMP/gh-runs"
RUN_ID=15 request --sha "$other" --release-compile-green
[[ "$status" == 0 ]] && dispatched "$other" || fail "a marked commit must be promoted (exit $status):" "$out" "$(cat "$TMP/gh.log")"
git_q -C "$src" checkout -q --detach "$head"

# Candidates are bounded below by nightly-next, not by the tree's publisher
# (2026-10-14: 2e420aa7a9's tree published later from a newer push): every
# commit from nightly-next on with the tree is a candidate, and the newest one
# is requested, whatever its Release compile says.
git -C "$src" remote add origin "$src" 2>/dev/null || git -C "$src" remote set-url origin "$src"
git_q -C "$src" checkout -q -b lowerbound "$head"
echo x > "$src/GreenX.swift"; git_q -C "$src" add -A; git_q -C "$src" commit -m "green, before the publisher"
greenx=$(git -C "$src" rev-parse HEAD)
echo y > "$src/PublisherY.swift"; git_q -C "$src" add -A; git_q -C "$src" commit -m "publisher, compile replaced"
publisher=$(git -C "$src" rev-parse HEAD)
[[ "$(key "$greenx")" == "$(key "$head")" && "$(key "$publisher")" == "$(key "$head")" ]] || fail "fixture: X and Y must share the published tree"
git_q -C "$src" update-ref refs/heads/nightly-next "$head^"
git_q -C "$src" checkout -q --detach "$publisher"
branch "$publisher"
request --tree-ready "$publisher"
[[ "$status" == 0 ]] && dispatched "$publisher" && ! dispatched "$greenx" \
  || fail "the newest commit ahead of nightly-next with the tree must be requested, compile cancelled or not (exit $status):" "$out" "$(cat "$TMP/gh.log")"
branch "$greenx"
request --tree-ready "$publisher"
[[ "$status" == 0 ]] && dispatched "$greenx" \
  || fail "a commit older than the tree's publisher but ahead of nightly-next must be requested (exit $status):" "$out" "$(cat "$TMP/gh.log")"
branch "$publisher"

# A commit already on nightly-next is never requested again, from either side:
# a stale request would evict a newer waiting one in main's promote job group.
git_q -C "$src" update-ref refs/heads/nightly-next "$greenx"
request --tree-ready "$publisher"
[[ "$status" == 0 ]] && ! dispatched "$greenx" \
  || fail "a commit already on nightly-next must not be requested again (exit $status):" "$out" "$(cat "$TMP/gh.log")"
git_q -C "$src" checkout -q --detach "$greenx"
branch "$greenx"
request --sha "$greenx" --release-compile-green
[[ "$status" == 0 ]] && ! dispatched "$greenx" && grep -q "already on nightly-next" <<<"$out" \
  || fail "--release-compile-green must not re-request a promoted commit (exit $status):" "$out" "$(cat "$TMP/gh.log")"
# A Release compile that finishes after nightly-next moved past its commit
# (2026-10-27: requests dispatched at 04:41Z for a 00:30Z landing) asks for
# nothing, and one that finishes after a newer commit with its tree landed
# asks for that newer commit, never its own old one.
git_q -C "$src" update-ref refs/heads/nightly-next "$publisher"
branch "$publisher"
request --sha "$greenx" --release-compile-green
[[ "$status" == 0 ]] && [[ ! -s "$TMP/gh.log" ]] \
  || fail "a late compile of a commit nightly-next contains must request nothing (exit $status):" "$out" "$(cat "$TMP/gh.log")"
# nightly-next at a commit this history does not have (a shallow checkout
# whose fetch did not reach it): the compiled commit cannot be proven ahead of
# it, so it is not requested. The remote here has only that nightly-next.
far="$TMP/far"
git_q init "$far"; git_q -C "$far" commit --allow-empty -m "far ahead"
git_q -C "$far" branch -M nightly-next
git -C "$src" remote set-url origin "$far"
request --sha "$greenx" --release-compile-green
[[ "$status" == 0 ]] && [[ ! -s "$TMP/gh.log" ]] \
  || fail "a compiled commit not provably ahead of nightly-next must not be requested (exit $status):" "$out" "$(cat "$TMP/gh.log")"
# nightly-next cannot be read at all (origin unreachable): nothing is requested.
git -C "$src" remote set-url origin "$TMP/no-such-remote"
request --sha "$greenx" --release-compile-green
[[ "$status" == 0 ]] && [[ ! -s "$TMP/gh.log" ]] \
  || fail "a compile whose nightly-next lookup failed must request nothing (exit $status):" "$out" "$(cat "$TMP/gh.log")"
git -C "$src" remote set-url origin "$src"
git_q -C "$src" update-ref refs/heads/nightly-next "$head^"
request --sha "$greenx" --release-compile-green
[[ "$status" == 0 ]] && dispatched "$publisher" && ! dispatched "$greenx" \
  || fail "a late compile must request the newest commit with its tree, not its own (exit $status):" "$out" "$(cat "$TMP/gh.log")"
# A merge brings nightly-next in beside the compiled commit: the history lists
# the compiled commit (first parent), but nightly-next is not its ancestor, so
# it is not requested (main's promote job would refuse it as diverged). The
# merge changes the tree, so no other candidate has the published one.
git_q -C "$src" checkout -q -b side-next "$head^"
echo side > "$src/SideNext.swift"; git_q -C "$src" add -A; git_q -C "$src" commit -m "nightly-next on a side line"
side_next=$(git -C "$src" rev-parse HEAD)
git_q -C "$src" checkout -q -b merged "$greenx"
git_q -C "$src" merge --no-ff -m "merge the side line" "$side_next"
echo four > "$src/cmux-tui/a"; git_q -C "$src" add -A; git_q -C "$src" commit --amend -m "merge the side line, with a tui change"
merged=$(git -C "$src" rev-parse HEAD)
git -C "$src" merge-base --is-ancestor "$side_next" "$greenx" && fail "fixture: the side line must not be under the compiled commit"
git_q -C "$src" update-ref refs/heads/nightly-next "$side_next"
branch "$merged"
git_q -C "$src" checkout -q --detach "$greenx"
request --sha "$greenx" --release-compile-green
[[ "$status" == 0 ]] && [[ ! -s "$TMP/gh.log" ]] \
  || fail "a compiled commit nightly-next is not an ancestor of must not be requested (exit $status):" "$out" "$(cat "$TMP/gh.log")"
branch "$publisher"
git_q -C "$src" update-ref -d refs/heads/nightly-next
git_q -C "$src" checkout -q --detach "$head"

# The writer (tree-commit-marker.sh write, cmux-tui-artifacts.yml mark-tree-commits)
# marks HEAD and its first-parent ancestors in the window whose tree is published
# and verified, write-once, and nothing else. A stub upload stands in for R2.
touch "$cdn/NOAUTO"; rm -rf "$cdn/tree-commits"
cat > "$src/scripts/ci/upload-r2-object.py" <<STUB
import shutil, sys, os
args = sys.argv[1:]
file = args[args.index("--file") + 1]; key = args[args.index("--key") + 1]
dest = os.path.join("$cdn", key.removeprefix("cmux-tui/"))
if "--write-once" in args and os.path.exists(dest):
    sys.exit(1)
os.makedirs(os.path.dirname(dest), exist_ok=True)
shutil.copy(file, dest)
STUB
git_q -C "$src" checkout -q --detach "$other"
wout=$(cd "$src" && PATH="$TMP/bin:$PATH" R2_ENDPOINT=https://r2.invalid GITHUB_RUN_ID=77 \
  bash scripts/cmux-next/tree-commit-marker.sh write --window 3 2>&1) || fail "the writer failed:" "$wout"
[[ -f "$cdn/tree-commits/$other.json" ]] || fail "the writer must mark a commit whose tree is ready:" "$wout"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["commit"]==sys.argv[2] and d["key"]==sys.argv[3] and d["publishedBy"]==sys.argv[2] and d["markedBy"].endswith("/runs/77"), d' \
  "$cdn/tree-commits/$other.json" "$other" "$okey" || fail "the marker must carry commit, key, publishedBy and markedBy"
for c in $(git -C "$src" rev-list --first-parent -n 3 "$other"); do
  [[ "$c" == "$other" ]] && continue
  k=$(key "$c")
  if [[ -f "$cdn/tree/$k/source.json" ]]; then
    [[ -f "$cdn/tree-commits/$c.json" ]] || fail "a ready ancestor in the window must be marked: $c" "$wout"
  else
    [[ ! -f "$cdn/tree-commits/$c.json" ]] || fail "an ancestor whose tree is not published must not be marked: $c"
  fi
done
before=$(cksum < "$cdn/tree-commits/$other.json")
wout=$(cd "$src" && PATH="$TMP/bin:$PATH" R2_ENDPOINT=https://r2.invalid GITHUB_RUN_ID=78 \
  bash scripts/cmux-next/tree-commit-marker.sh write --window 3 2>&1) || fail "a second writer run must succeed:" "$wout"
[[ "$(cksum < "$cdn/tree-commits/$other.json")" == "$before" ]] || fail "markers are write-once"
# A published tree whose daemon tests have not passed is ready (2026-10-28): marked.
rm -f "$cdn/tree/$okey/daemon-tests.json" "$cdn/tree-commits/$other.json"
wout=$(cd "$src" && PATH="$TMP/bin:$PATH" R2_ENDPOINT=https://r2.invalid bash scripts/cmux-next/tree-commit-marker.sh write --window 1 2>&1) \
  || fail "the writer failed:" "$wout"
[[ -f "$cdn/tree-commits/$other.json" ]] || fail "a published tree without its daemon tests must be marked:" "$wout"
# A tree that is not published is not ready: not marked.
rm -f "$cdn/tree-commits/$other.json"
mv "$cdn/tree/$okey/$bin.sha256" "$TMP/held.sha256"
wout=$(cd "$src" && PATH="$TMP/bin:$PATH" R2_ENDPOINT=https://r2.invalid bash scripts/cmux-next/tree-commit-marker.sh write --window 1 2>&1) \
  || fail "the writer must succeed when nothing is ready:" "$wout"
[[ ! -f "$cdn/tree-commits/$other.json" ]] || fail "an unpublished tree must not be marked:" "$wout"
mv "$TMP/held.sha256" "$cdn/tree/$okey/$bin.sha256"
# --tip-branch: a run that publishes a tree late marks the newer branch commits sharing
# it (their own runs ran before the tree existed and marked nothing). The run at
# $head published its tree; $app, a later app-only commit, shares the key.
rm -rf "$cdn/tree-commits"
git_q -C "$src" checkout -q --detach "$head"
wout=$(cd "$src" && PATH="$TMP/bin:$PATH" R2_ENDPOINT=https://r2.invalid bash scripts/cmux-next/tree-commit-marker.sh write --window 1 2>&1) \
  || fail "the writer failed:" "$wout"
[[ -f "$cdn/tree-commits/$head.json" && ! -f "$cdn/tree-commits/$app.json" ]] \
  || fail "without --tip-branch the writer walks only HEAD's window:" "$wout"
git_q -C "$src" update-ref refs/heads/marker-tip "$app"
wout=$(cd "$src" && PATH="$TMP/bin:$PATH" R2_ENDPOINT=https://r2.invalid bash scripts/cmux-next/tree-commit-marker.sh write --window 1 --tip-branch marker-tip 2>&1) \
  || fail "the writer with --tip-branch failed:" "$wout"
[[ "$(git -C "$src" rev-parse --is-shallow-repository)" == false ]] || fail "--tip-branch must not make a full clone shallow"
[[ -f "$cdn/tree-commits/$app.json" ]] || fail "--tip-branch must mark a newer commit that shares the published tree:" "$wout"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["commit"]==sys.argv[2] and d["key"]==sys.argv[3], d' \
  "$cdn/tree-commits/$app.json" "$app" "$(key "$head")" || fail "the tip's marker must name its own commit and the shared key"
grep -q "1 written" <<<"$wout" || fail "--tip-branch must write each commit once (HEAD was already marked):" "$wout"
rm -f "$cdn/tree-commits/$app.json"
wout=$(cd "$src" && PATH="$TMP/bin:$PATH" R2_ENDPOINT=https://r2.invalid bash scripts/cmux-next/tree-commit-marker.sh write --window 1 --tip-branch no-such-branch 2>&1) \
  || fail "a tip that does not fetch must not fail the writer:" "$wout"
[[ -f "$cdn/tree-commits/$head.json" && ! -f "$cdn/tree-commits/$app.json" ]] && grep -q "could not fetch no-such-branch" <<<"$wout" \
  || fail "a tip that does not fetch marks from HEAD alone, with a warning:" "$wout"
rc=0; (cd "$src" && PATH="$TMP/bin:$PATH" R2_ENDPOINT=https://r2.invalid bash scripts/cmux-next/tree-commit-marker.sh write --tip-branch 'bad name' >/dev/null 2>&1) || rc=$?
[[ "$rc" == 2 ]] || fail "a --tip-branch that is not a branch name is a usage error (exit 2), got $rc"
# A tip commit whose tree key definition (key script or input list) differs from
# this checkout's is not keyed here, even when this checkout's key would match.
git_q -C "$src" checkout -q -b keydef "$app"
echo "# a key definition change" >> "$src/scripts/cmux-next/cmux-tui-tree-inputs.txt"
git_q -C "$src" commit -m "key definition" scripts/cmux-next/cmux-tui-tree-inputs.txt
keydef=$(git -C "$src" rev-parse HEAD)
git_q -C "$src" checkout -q --detach "$head"
wout=$(cd "$src" && PATH="$TMP/bin:$PATH" R2_ENDPOINT=https://r2.invalid bash scripts/cmux-next/tree-commit-marker.sh write --window 2 --tip-branch keydef 2>&1) \
  || fail "the writer with a cross-definition --tip-branch failed:" "$wout"
[[ ! -f "$cdn/tree-commits/$keydef.json" ]] || fail "a tip commit with another key definition must not be marked here:" "$wout"
grep -q "key definition differs" <<<"$wout" || fail "the writer must say why it skipped the tip commit:" "$wout"
# The same holds for an ancestor in HEAD's window: run from $keydef, the older
# commits (another key definition) are not marked by it.
rm -rf "$cdn/tree-commits"
git_q -C "$src" checkout -q --detach "$keydef"
wout=$(cd "$src" && PATH="$TMP/bin:$PATH" R2_ENDPOINT=https://r2.invalid bash scripts/cmux-next/tree-commit-marker.sh write --window 3 2>&1) \
  || fail "the writer from a key definition change failed:" "$wout"
[[ ! -f "$cdn/tree-commits/$app.json" && ! -f "$cdn/tree-commits/$head.json" ]] \
  || fail "an ancestor with another key definition must not be marked:" "$wout"
grep -q "key definition differs" <<<"$wout" || fail "the writer must say why it skipped the ancestor:" "$wout"
git_q -C "$src" checkout -q --detach "$other"
# check: 200 naming the commit, 404, and anything else (another commit, a 500) a read failure (3).
printf '{"commit": "%s", "key": "%s", "publishedBy": "%s", "markedBy": "https://u"}\n' "$head" "$okey" "$other" > "$cdn/tree-commits/$other.json"
rc=0; (cd "$src" && PATH="$TMP/bin:$PATH" bash scripts/cmux-next/tree-commit-marker.sh check "$other" >/dev/null 2>&1) || rc=$?
[[ "$rc" == 3 ]] || fail "a marker naming another commit is a read failure (exit 3), got $rc"
for body in "{\"commit\": \"$other\", \"key\": \"$okey\"}" \
            "{\"commit\": \"$other\", \"key\": \"$okey\", \"publishedBy\": \"x\", \"markedBy\": \"https://u\"}" \
            "{\"commit\": \"$other\", \"key\": \"$okey\", \"publishedBy\": \"$other\"}" 'not json'; do
  printf '%s\n' "$body" > "$cdn/tree-commits/$other.json"
  rc=0; (cd "$src" && PATH="$TMP/bin:$PATH" bash scripts/cmux-next/tree-commit-marker.sh check "$other" >/dev/null 2>&1) || rc=$?
  [[ "$rc" == 3 ]] || fail "an incomplete marker is a read failure (exit 3), got $rc for $body"
done
printf '{"commit": "%s", "key": "%s", "publishedBy": "%s", "markedBy": "https://u"}\n' "$other" "$okey" "$other" > "$cdn/tree-commits/$other.json"
rc=0; (cd "$src" && PATH="$TMP/bin:$PATH" bash scripts/cmux-next/tree-commit-marker.sh check "$other" >/dev/null 2>&1) || rc=$?
[[ "$rc" == 0 ]] || fail "a complete marker reads as ready, got $rc"
# verify-key: a 404 is "not published" (1); any other failed read is a read failure (3).
rc=0; (cd "$src" && PATH="$TMP/bin:$PATH" bash scripts/cmux-next/pin-cmux-tui.sh verify-key "$(printf 'e%.0s' {1..40})" >/dev/null 2>&1) || rc=$?
[[ "$rc" == 1 ]] || fail "verify-key of an unpublished tree must exit 1, got $rc"
echo "tree/$okey/$bin.sha256" > "$cdn/FAIL"
rc=0; (cd "$src" && PATH="$TMP/bin:$PATH" bash scripts/cmux-next/pin-cmux-tui.sh verify-key "$okey" >/dev/null 2>&1) || rc=$?
[[ "$rc" == 3 ]] || fail "verify-key on a failed sha256 read must exit 3 (a read failure), got $rc"
rm -f "$cdn/FAIL"
# An interrupted transfer that reported 404 is not "not published".
echo "tree/$(printf 'e%.0s' {1..40})/$bin.sha256" > "$cdn/TRUNC"
rc=0; (cd "$src" && PATH="$TMP/bin:$PATH" bash scripts/cmux-next/pin-cmux-tui.sh verify-key "$(printf 'e%.0s' {1..40})" >/dev/null 2>&1) || rc=$?
[[ "$rc" == 3 ]] || fail "verify-key on an interrupted 404 must exit 3, got $rc"
# An interrupted marker transfer is a read failure, not missing.
echo "tree-commits/$other.json" > "$cdn/TRUNC"
rc=0; (cd "$src" && PATH="$TMP/bin:$PATH" bash scripts/cmux-next/tree-commit-marker.sh check "$other" >/dev/null 2>&1) || rc=$?
[[ "$rc" == 3 ]] || fail "an interrupted marker read must exit 3, got $rc"
rm -f "$cdn/TRUNC"
rm -f "$cdn/tree-commits/$other.json"
rc=0; (cd "$src" && PATH="$TMP/bin:$PATH" bash scripts/cmux-next/tree-commit-marker.sh check "$other" >/dev/null 2>&1) || rc=$?
[[ "$rc" == 1 ]] || fail "a missing marker is exit 1, got $rc"
rm -f "$cdn/NOAUTO" "$src/scripts/ci/upload-r2-object.py"
git_q -C "$src" checkout -q --detach "$head"

# NIGHTLY_NEXT_TREE_AT_INSTALL: the feat-cmux-next tip whose tree is still building
# is requested at once when its own nightly.yml waits for the tree at install
# and an artifacts run builds that tree; main's promote guard (G5) accepts it on
# the same line. Without the line, or with no active run, it waits as before.
git_q -C "$src" checkout -q -b pending "$app"
echo four > "$src/cmux-tui/a"; git_q -C "$src" add -A; git_q -C "$src" commit -m "tui four, no line"
noline=$(git -C "$src" rev-parse HEAD)
branch "$noline"
echo 1 > "$TMP/gh-runs"
request --tree-ready "$noline"
[[ "$status" == 0 ]] && ! dispatched "$noline" || fail "a building tree without the nightly.yml line must not be requested:" "$out"
{ echo "env:"; echo "  NIGHTLY_NEXT_TREE_AT_INSTALL: v1"; cat "$src/.github/workflows/nightly.yml"; } > "$TMP/nightly.yml"
mv "$TMP/nightly.yml" "$src/.github/workflows/nightly.yml"
echo five > "$src/cmux-tui/a"; git_q -C "$src" add -A; git_q -C "$src" commit -m "tui five, with the line"
pending=$(git -C "$src" rev-parse HEAD)
branch "$pending"
echo 0 > "$TMP/gh-runs"
request --tree-ready "$pending"
[[ "$status" == 0 ]] && ! dispatched "$pending" || fail "with no active artifacts run the building tip must wait:" "$out"
grep -q "no active cmux-tui-artifacts run builds tree" <<<"$out" || fail "the wait must say why:" "$out"
printf '[{"head_sha":"%s","status":"queued"}]\n' "$other" > "$TMP/gh-active-runs"
RUN_ID=123 request --tree-ready "$pending"
[[ "$status" == 0 ]] && backfilled && ! dispatched "$pending" \
  || fail "a tip with no publisher must backfill despite an unrelated queued tree:" "$out" "$(cat "$TMP/gh.log")"
# The tip's own push run, queued with its first job waiting for a runner past
# CMUX_TREE_RUN_STARVED_MIN (30 min), is no run: it builds no tree, so the tip
# is not requested as building and the rescue dispatch goes (2026-11-19: 40+
# feat-cmux-next preflights queued on cmux-gcp-lane-build-x64 since 04:21Z).
ago() { python3 -c 'import sys, datetime as d; print((d.datetime.now(d.timezone.utc) - d.timedelta(minutes=int(sys.argv[1]))).strftime("%Y-%m-%dT%H:%M:%SZ"))' "$1"; }
echo 1 > "$TMP/gh-runs"
printf '[{"head_sha":"%s","status":"queued"}]\n' "$pending" > "$TMP/gh-active-runs"
echo "777 $pending push" > "$TMP/gh-starved"
ago 45 > "$TMP/gh-jobs-777"
RUN_ID=124 request --tree-ready "$pending"
[[ "$status" == 0 ]] && backfilled && ! dispatched "$pending" && grep -q "waited 45 min with no runner; counted as no run" <<<"$out" \
  || fail "a tip run starved of a runner past the limit must count as no run and be rescued:" "$out" "$(cat "$TMP/gh.log")"
# Under the limit it is still the run that builds the tree: no rescue.
ago 10 > "$TMP/gh-jobs-777"
RUN_ID=125 request --tree-ready "$pending"
[[ "$status" == 0 ]] && ! backfilled && dispatched "$pending" \
  || fail "a run queued under the limit must still count as building the tree:" "$out" "$(cat "$TMP/gh.log")"
# The limit is the env's.
RUN_ID=126 CMUX_TREE_RUN_STARVED_MIN=5 request --tree-ready "$pending"
[[ "$status" == 0 ]] && backfilled && ! dispatched "$pending" \
  || fail "CMUX_TREE_RUN_STARVED_MIN must set the limit:" "$out" "$(cat "$TMP/gh.log")"
# A starved rescue dispatch is not rescued again: only push runs count as starved.
ago 45 > "$TMP/gh-jobs-777"
echo "777 $pending workflow_dispatch" > "$TMP/gh-starved"
RUN_ID=127 request --tree-ready "$pending"
[[ "$status" == 0 ]] && ! backfilled \
  || fail "a starved rescue dispatch must not start another rescue:" "$out" "$(cat "$TMP/gh.log")"
# A run whose jobs cannot be read is not starved (the careful answer).
echo "777 $pending push" > "$TMP/gh-starved"; rm -f "$TMP/gh-jobs-777"
RUN_ID=128 request --tree-ready "$pending"
[[ "$status" == 0 ]] && ! backfilled && dispatched "$pending" \
  || fail "an unreadable job list must not count the run as starved:" "$out" "$(cat "$TMP/gh.log")"
rm -f "$TMP/gh-starved" "$TMP/gh-active-runs"
# A coalesced tip: its only run succeeded and built nothing (its tree is still a
# 404), so it counts as no run and the tip is backfilled (2026-11-23: the tick
# walked past coalesced tips and cut commits 40-87 min old). A failed or running
# run still counts.
echo 0 > "$TMP/gh-runs"
echo '[{"status":"completed","conclusion":"success","event":"push"}]' > "$TMP/gh-runs-json"
RUN_ID=129 request --tree-ready "$pending"
[[ "$status" == 0 ]] && backfilled && ! dispatched "$pending" \
  || fail "a tip whose only run succeeded without a tree must be backfilled:" "$out" "$(cat "$TMP/gh.log")"
# A green backfill dispatch that published nothing is not re-dispatched every tick.
for run in '{"status":"completed","conclusion":"failure","event":"push"}' '{"status":"in_progress","conclusion":null,"event":"push"}' \
           '{"status":"completed","conclusion":"success","event":"workflow_dispatch"}'; do
  echo "[$run]" > "$TMP/gh-runs-json"
  RUN_ID=130 request --tree-ready "$pending"
  [[ "$status" == 0 ]] && ! backfilled || fail "a tip run $run must still count (no backfill):" "$out" "$(cat "$TMP/gh.log")"
done
rm -f "$TMP/gh-runs-json"
echo 1 > "$TMP/gh-runs"
request --tree-ready "$pending"
[[ "$status" == 0 ]] && dispatched "$pending" || fail "the building tip with the line and an active run must be requested:" "$out" "$(cat "$TMP/gh.log")"
grep -q "its cmux-tui tree is building" <<<"$out" || fail "the request must say the tree is building:" "$out"
# A commit behind the tip is never requested this way.
git_q -C "$src" commit --allow-empty -m "app on top"
branch "$(git -C "$src" rev-parse HEAD)"
git_q -C "$src" checkout -q --detach "$pending"
request --tree-ready "$pending"
! dispatched "$pending" || fail "only the feat-cmux-next tip is requested before its tree:" "$out"
rm -f "$TMP/gh-runs"

# An older tree (Leo, 2026-11-26: "cant we just accept the nightly using an older tui version"): a commit whose
# tree is a confirmed 404 and that no run builds is promoted when the newest published tree within 24 h has its
# daemon-capabilities.json (scripts/cmux-next/older-tree-for-tip.sh, the nightly's resolver asks the same), and
# its own nightly.yml has the line and the script. No backfill: the request is the answer.
git_q -C "$src" checkout -q -b older-tree "$pending"
cp "$ROOT/scripts/cmux-next/older-tree-for-tip.sh" "$src/scripts/cmux-next/"
mkdir -p "$src/plans/cmux-next"; echo '{"capabilities": ["a"]}' > "$src/plans/cmux-next/daemon-capabilities.json"
echo six > "$src/cmux-tui/a"; git_q -C "$src" add -A; git_q -C "$src" commit -m "tui six, published"
olderbase=$(git -C "$src" rev-parse HEAD)
publish "$olderbase"
echo seven > "$src/cmux-tui/a"; git_q -C "$src" add -A; git_q -C "$src" commit -m "tui seven, never published"
older=$(git -C "$src" rev-parse HEAD)
branch "$older"
olderkey=$(key "$olderbase")
RUN_ID=140 request --tree-ready "$older"
[[ "$status" == 0 ]] && dispatched "$older" && ! backfilled \
  || fail "a commit with an older matching published tree must be promoted:" "$out" "$(cat "$TMP/gh.log")"
grep -q "older published tree ${olderkey:0:12} of ${olderbase:0:12}, same daemon-capabilities.json" <<<"$out" \
  || fail "the request must name the older tree and its commit:" "$out"
# The helper answers the nightly's resolver the same way: the tip is the build commit, the tree is the older one.
helper=$(cd "$src" && PATH="$TMP/bin:$PATH" bash scripts/cmux-next/older-tree-for-tip.sh 2>/dev/null)
grep -qx "source_commit=$older" <<<"$helper" && grep -qx "key=$olderkey" <<<"$helper" && grep -qx "commit=$olderbase" <<<"$helper" \
  && grep -qx "tree_from=$olderbase 1 0" <<<"$helper" || fail "older-tree-for-tip.sh must print the tip and the older tree:" "$helper"
# The tip's own tree published: exit 3, the resolver takes it as before.
git_q -C "$src" checkout -q --detach "$olderbase"
rc=0; (cd "$src" && PATH="$TMP/bin:$PATH" bash scripts/cmux-next/older-tree-for-tip.sh >/dev/null 2>&1) || rc=$?
[[ "$rc" == 3 ]] || fail "a published own tree must exit 3, got $rc"
git_q -C "$src" checkout -q older-tree
# Another daemon-capabilities.json: no older tree serves this app, so it waits as before.
echo '{"capabilities": ["a", "b"]}' > "$src/plans/cmux-next/daemon-capabilities.json"
echo eight > "$src/cmux-tui/a"; git_q -C "$src" add -A; git_q -C "$src" commit -m "tui eight, new capability"
newcaps=$(git -C "$src" rev-parse HEAD)
branch "$newcaps"
RUN_ID=141 request --tree-ready "$newcaps"
[[ "$status" == 0 ]] && ! dispatched "$newcaps" \
  || fail "a commit whose capabilities no published tree matches must not be promoted:" "$out" "$(cat "$TMP/gh.log")"
grep -q "not promoting ${newcaps:0:12}: the nightly cannot resolve" <<<"$out" || fail "the skip must say why:" "$out"
git_q -C "$src" checkout -q --detach "$head"
git_q -C "$src" checkout -q --detach "$head"

# A commit whose app is the one the feed already publishes is not requested: nothing that
# reaches the app changed since the commit the nightly-next tag names. The classifier
# (scripts/ci/nightly_build_inputs.py) is stubbed: only App.swift reaches the app, so a
# cmux-tui change is caught by its tree key alone.
git_q -C "$src" checkout -q -b app-identical "$head"
git_q -C "$src" tag -f nightly-next "$head"
cat > "$src/scripts/ci/nightly_build_inputs.py" <<'PY'
import json, sys
paths = [line.strip() for line in sys.stdin if line.strip()]
hit = [p for p in paths if p == "App.swift"]
print(json.dumps({"build_inputs_changed": bool(hit),
                  "reason": f"{hit[0]} reaches the app" if hit else "no changed path reaches the app the Nightly publishes"}))
PY
echo notes > "$src/NOTES.md"; git_q -C "$src" add -A; git_q -C "$src" commit -m "notes only"
same=$(git -C "$src" rev-parse HEAD)
request --sha "$same" --release-compile-green
[[ "$status" == 0 ]] && ! dispatched "$same" || fail "an app-identical commit must not be promoted:" "$out" "$(cat "$TMP/gh.log")"
grep -q "nothing that reaches the app changed since the published ${head:0:12} (no changed path reaches" <<<"$out" \
  && grep -q "already on nightly-next" <<<"$out" || fail "the skip must name the published commit and stop the tick's walk:" "$out"
# The next app change is promoted at once: a skip never holds a real update back.
echo app2 > "$src/App.swift"; git_q -C "$src" add -A; git_q -C "$src" commit -m "app change"
changed=$(git -C "$src" rev-parse HEAD)
request --sha "$changed" --release-compile-green
[[ "$status" == 0 ]] && dispatched "$changed" || fail "an app change since the published commit must be promoted:" "$out" "$(cat "$TMP/gh.log")"
# A change to the bundled cmux-tui binaries' inputs that the classifier calls neutral is
# promoted: its tree key differs from the published commit's.
git_q -C "$src" tag -f nightly-next "$changed"
echo tui-runtime > "$src/cmux-tui/a"; git_q -C "$src" add -A; git_q -C "$src" commit -m "tui input the classifier misses"
tuichange=$(git -C "$src" rev-parse HEAD)
publish "$tuichange"
request --sha "$tuichange" --release-compile-green
[[ "$status" == 0 ]] && dispatched "$tuichange" || fail "a cmux-tui tree change must be promoted even when the classifier finds nothing:" "$out" "$(cat "$TMP/gh.log")"
git_q -C "$src" checkout -q --detach "$changed"
# A move out of the app (App.swift into docs/) removes an app input: promoted, never read as docs only.
git_q -C "$src" tag -f nightly-next "$changed"
mkdir -p "$src/docs"; git_q -C "$src" mv App.swift docs/App.swift; git_q -C "$src" commit -m "move the app file into docs"
moved=$(git -C "$src" rev-parse HEAD)
request --sha "$moved" --release-compile-green
[[ "$status" == 0 ]] && dispatched "$moved" || fail "a move out of an app path must be promoted:" "$out" "$(cat "$TMP/gh.log")"
git_q -C "$src" tag -f nightly-next "$head"
# A revert of a promotion still building is promoted at once: its app matches the published
# one but not the one nightly-next is about to publish.
git_q -C "$src" checkout -q --detach "$same"
git_q -C "$src" tag -f nightly-next "$same"
echo pending-app > "$src/App.swift"; git_q -C "$src" add -A; git_q -C "$src" commit -m "app change still building"
building=$(git -C "$src" rev-parse HEAD)
git_q -C "$src" update-ref refs/heads/nightly-next "$building"
git_q -C "$src" revert --no-edit HEAD
reverted=$(git -C "$src" rev-parse HEAD)
request --sha "$reverted" --release-compile-green
[[ "$status" == 0 ]] && dispatched "$reverted" || fail "a revert of an outstanding promotion must be promoted:" "$out" "$(cat "$TMP/gh.log")"
# A docs-only commit on top of that promotion is still promoted: the published app differs from it.
git_q -C "$src" checkout -q --detach "$building"
echo more > "$src/NOTES.md"; git_q -C "$src" add -A; git_q -C "$src" commit -m "notes on the building app"
notes_on_building=$(git -C "$src" rev-parse HEAD)
request --sha "$notes_on_building" --release-compile-green
[[ "$status" == 0 ]] && dispatched "$notes_on_building" || fail "a commit whose app differs from the published one must be promoted:" "$out"
git_q -C "$src" update-ref -d refs/heads/nightly-next
git_q -C "$src" tag -f nightly-next "$head"
git_q -C "$src" checkout -q --detach "$same"
# A classifier that cannot answer, or no published commit, promotes as before.
git_q -C "$src" checkout -q --detach "$same"
echo 'raise SystemExit(3)' > "$src/scripts/ci/nightly_build_inputs.py"
request --sha "$same" --release-compile-green
[[ "$status" == 0 ]] && dispatched "$same" || fail "an unreadable classifier must not hold back a promotion:" "$out" "$(cat "$TMP/gh.log")"
git -C "$src" checkout -q -- scripts/ci/nightly_build_inputs.py
git_q -C "$src" tag -d nightly-next
request --sha "$same" --release-compile-green
[[ "$status" == 0 ]] && dispatched "$same" || fail "with no published commit the promotion is requested:" "$out" "$(cat "$TMP/gh.log")"
git_q -C "$src" checkout -q --detach "$head"

# The checkout must be the commit it asks for; bad input is a usage error.
request --sha "$app" --release-compile-green
[[ "$status" == 2 ]] || fail "a --sha other than HEAD must exit 2, got $status:" "$out"
request --sha nothex --release-compile-green
[[ "$status" == 2 ]] || fail "a malformed --sha must exit 2, got $status:" "$out"
request --sha "$head"
[[ "$status" == 2 ]] || fail "--sha without --release-compile-green must exit 2, got $status:" "$out"

# The tick's walk over many commits whose trees are not published reads origin once, not once a commit.
# Regression: tick 45696501186 (2026-11-25) refused 35 such commits in 29 minutes, each call
# making three anonymous ls-remotes of github.com that GitHub held 50-107 s before answering.
real_git="$(command -v git)"
mkdir -p "$TMP/gitlog"
# A wrapper that is itself named git (a lane VM's ~/.local/bin/git guard) takes the first other git
# on PATH as the real one, which is this stub again: log a call once, on its first pass only.
cat > "$TMP/gitlog/git" <<STUB
#!/usr/bin/env bash
if [[ -z "\${GITLOG_SEEN:-}" ]]; then
  for a in "\$@"; do
    case "\$a" in ls-remote|fetch) printf '%s\n' "\$a" >> "$TMP/git-network.log"; break ;; esac
  done
fi
export GITLOG_SEEN=1
exec "$real_git" "\$@"
STUB
chmod +x "$TMP/gitlog/git"
git_q -C "$src" checkout -q --detach "$head"
git_q -C "$src" update-ref refs/heads/nightly-next "$head"
for i in $(seq 1 12); do
  echo "unpublished $i" > "$src/cmux-tui/a"; git_q -C "$src" add -A; git_q -C "$src" commit -m "unpublished tree $i"
done
walk_tip=$(git -C "$src" rev-parse HEAD)
branch "$walk_tip"
rm -f "$TMP/gh-runs" "$TMP/gh-runs-json"
walk() { # <tick cache>: the tick's loop, newest first; stops at a request
  local c
  : > "$TMP/git-network.log"; : > "$TMP/gh.log"; walked=0
  for c in $(git -C "$src" rev-list --first-parent -n 12 "$walk_tip"); do
    git_q -C "$src" checkout -q --detach "$c"
    PATH="$TMP/gitlog:$PATH" GH_TICK_CACHE="$1" request --tree-ready "$c"
    walked=$((walked + 1))
    [[ "$status" == 0 ]] || fail "a walked commit must not fail (exit $status):" "$out"
    ! grep -q '^requested nightly-next promotion' <<<"$out" || break
  done
}
walk "$TMP/walk-tick-1"
(( walked == 12 )) || fail "the walk must pass over every unpublished commit, walked $walked"
grep -q "cannot resolve a published cmux-tui tree" <<<"$out" || fail "an unpublished commit must be refused:" "$out"
! grep -q 'workflow run nightly.yml' "$TMP/gh.log" || fail "no unpublished commit may be promoted:" "$(cat "$TMP/gh.log")"
[[ "$(grep -c . "$TMP/git-network.log")" == 1 ]] \
  || fail "a walk over 12 unpublished commits must read origin once, got:" "$(cat "$TMP/git-network.log")"
# Once an older commit's tree is published the walk requests it, still reading and fetching origin once each.
publish "$(git -C "$src" rev-parse "$walk_tip~5")"
walk "$TMP/walk-tick-2"
dispatched "$(git -C "$src" rev-parse "$walk_tip~5")" || fail "the walk must request the published commit:" "$out" "$(cat "$TMP/gh.log")"
(( $(grep -c '^ls-remote$' "$TMP/git-network.log") == 1 && $(grep -c '^fetch$' "$TMP/git-network.log") <= 1 )) \
  || fail "the walk must read origin once and fetch at most once, got:" "$(cat "$TMP/git-network.log")"
# Without GH_TICK_CACHE (a landing's single call) every call reads origin for itself.
: > "$TMP/git-network.log"
git_q -C "$src" checkout -q --detach "$walk_tip"
PATH="$TMP/gitlog:$PATH" request --tree-ready "$walk_tip"
PATH="$TMP/gitlog:$PATH" request --tree-ready "$walk_tip"
(( $(grep -c '^ls-remote$' "$TMP/git-network.log") == 2 )) || fail "without a tick cache each call reads origin:" "$(cat "$TMP/git-network.log")"
git_q -C "$src" update-ref -d refs/heads/nightly-next

# The tick's precheck reads do not grow with the commits it walks. Regression: tick 45858069814
# (2026-11-26) took 14 minutes over 39 commits, each call reading the compile results service for
# its candidates and the same ancestors again, or waiting out its own 20 s timeout while it was down.
git_q -C "$src" checkout -q --detach "$walk_tip~5"
for i in $(seq 1 12); do
  echo "batch $i" > "$src/NOTES.md"; git_q -C "$src" add -A; git_q -C "$src" commit -m "same tree $i"
done
batch_tip=$(git -C "$src" rev-parse HEAD)
branch "$batch_tip"
[[ "$(key "$batch_tip")" == "$(key "$walk_tip~5")" ]] || fail "fixture: the batch commits must share the published tree"
batch_walk() { # <commits> <tick cache> <run id>: the tick's loop over the newest <commits>; prints the precheck reads
  local c
  : > "$TMP/precheck.log"
  for c in $(git -C "$src" rev-list --first-parent -n "$1" "$batch_tip"); do
    git_q -C "$src" checkout -q --detach "$c"
    PROMOTE="" RUN_ID="$3" GH_TICK_CACHE="$2" request --tree-ready "$c"
    [[ "$status" == 0 ]] || fail "a walked commit must not fail (exit $status):" "$out"
    printf '%s\n' "$out" > "$TMP/batch-out"
  done
  grep -c . "$TMP/precheck.log" || true
}
# No verdict anywhere: every candidate searches its ancestors and finds none.
for c in $(git -C "$src" rev-list "$batch_tip"); do echo 404 > "$TMP/precheck/$c"; done
reads4=$(batch_walk 4 "$TMP/batch-tick-4" 41)
reads12=$(batch_walk 12 "$TMP/batch-tick-12" 42)
grep -q "not prechecked yet" "$TMP/batch-out" || fail "a commit with no verdict must be refused as not prechecked:" "$(cat "$TMP/batch-out")"
distinct=$(sort -u "$TMP/precheck.log" | grep -c .)
(( reads12 == distinct )) || fail "a walk must read each commit's verdict once, read $reads12 for $distinct commits:" "$(sort "$TMP/precheck.log" | uniq -c | sort -rn | head)"
(( reads12 - reads4 <= 8 )) || fail "8 more commits walked may cost at most 8 more reads, got $reads4 then $reads12"
# A long walk does not re-read: by default an answer holds for the whole tick, an hour old or not.
for f in "$TMP/batch-tick-12/precheck/"*; do read -r _ w < "$f"; echo "$(( $(date +%s) - 3600 )) $w" > "$f"; done
reads_again=$(batch_walk 12 "$TMP/batch-tick-12" 42)
(( reads_again == 0 )) || fail "within one tick a commit's answer must not be read again, got $reads_again"
# Without the tick cache the same walk reads the same ancestors again (what the cache saves).
reads_uncached=$(batch_walk 12 "" 43)
(( reads_uncached > 3 * reads12 )) || fail "fixture: without the tick cache the walk must read far more, got $reads_uncached vs $reads12"
# The service down: one read for the whole walk, every commit still promotable unprechecked.
for c in $(git -C "$src" rev-list "$batch_tip"); do echo down > "$TMP/precheck/$c"; done
reads_down=$(batch_walk 12 "$TMP/batch-tick-down" 44)
(( reads_down == 1 )) || fail "a walk while the results service is down must read it once, got $reads_down"
grep -q "^promotable " "$TMP/batch-out" || fail "an outage must not block a commit:" "$(cat "$TMP/batch-out")"
# A window later the service is read again.
reads_down0=$(CMUX_NIGHTLY_NEXT_PRECHECK_TICK_TTL=0 batch_walk 3 "$TMP/batch-tick-down" 45)
(( reads_down0 == 3 )) || fail "past its window an outage must be read again, got $reads_down0"
for c in $(git -C "$src" rev-list "$batch_tip"); do rm -f "$TMP/precheck/$c"; done
git_q -C "$src" checkout -q --detach "$head"
: "$other"
echo "PASS: nightly-next promotion waits for a published tree and a usable fleet Release precheck, not daemon tests"
