#!/usr/bin/env bash
# The nightly-next tick's precheck reads (scripts/cmux-next/request-nightly-next.sh fleet_verdict) over a walk of
# N commits, the tick's own loop (.github/workflows/nightly-next-tick.yml on main: one call per first-parent commit,
# one GH_TICK_CACHE), in the request-nightly-next.test.sh fixture with a stub results service that answers every
# read after BENCH_LATENCY seconds. Prints the reads, the distinct commits read and the walk's seconds.
# Before and after: BENCH_SCRIPT=<a copy of request-nightly-next.sh at any commit>.
# Run: BENCH_COMMITS=37 BENCH_STATE=404|down BENCH_LATENCY=0.3 [BENCH_SCRIPT=FILE] bash scripts/measure/tick-precheck-reads.sh
# (or cmux-ci test -- bash scripts/measure/tick-precheck-reads.sh)
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
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BENCH_SCRIPT="${BENCH_SCRIPT:-$ROOT/scripts/cmux-next/request-nightly-next.sh}"
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
  && cp "$BENCH_SCRIPT" "$src/scripts/cmux-next/request-nightly-next.sh"
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
  sleep "${BENCH_LATENCY:-0}"
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

branch() { git_q -C "$src" update-ref refs/heads/feat-cmux-next "$1"; }
# The tick's case: a published tree some commits back, then N commits on top with no verdict of their own
# (404, ancestors read for one), the newest feat-cmux-next landing first.
publish "$(git -C "$src" rev-parse HEAD)"
git_q -C "$src" update-ref refs/heads/nightly-next HEAD
N="${BENCH_COMMITS:-37}"
for i in $(seq 1 "$N"); do
  echo "batch $i" > "$src/Batch$((i % 5)).swift"; git_q -C "$src" add -A; git_q -C "$src" commit -m "landing $i"
done
tip=$(git -C "$src" rev-parse HEAD); branch "$tip"
for c in $(git -C "$src" rev-list "$tip"); do echo "${BENCH_STATE:-404}" > "$TMP/precheck/$c"; done
: > "$TMP/precheck.log"; start=$SECONDS
for c in $(git -C "$src" rev-list --first-parent -n "$N" "$tip"); do
  git_q -C "$src" checkout -q --detach "$c"
  PROMOTE="" GH_TICK_CACHE="$TMP/tick" request --tree-ready "$c"
  [[ "$status" == 0 ]] || fail "exit $status" "$out"
done
echo "BENCH commits=$N state=${BENCH_STATE:-404} latency=${BENCH_LATENCY:-0}s reads=$(grep -c . "$TMP/precheck.log") distinct=$(sort -u "$TMP/precheck.log" | grep -c .) walk_s=$((SECONDS - start))"
echo "last: $(grep -m3 'not promoting\|promotable' <<<"$out")"
