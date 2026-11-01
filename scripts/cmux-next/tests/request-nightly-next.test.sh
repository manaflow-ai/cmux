#!/usr/bin/env bash
# request-nightly-next.sh: feat-cmux-next asks main to promote a commit to
# nightly-next only when that commit's cmux-tui tree is published and
# verified. Its daemon tests are not awaited (2026-10-28) and neither is its
# Release compile (2026-10-26): the nightly
# build compiles the commit itself and publishes nothing when that fails.
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
git_q() { git -c user.name=t -c user.email=t@example.com -c init.defaultBranch=main "$@" >/dev/null 2>&1; }
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

mkdir -p "$TMP/bin"
# The CDN. With -w (tree-commit-marker.sh) it prints the HTTP status: 404 for a
# missing object, 500 for a path listed in $cdn/FAIL (or, for -w reads only, $cdn/FAILW). A tree-commit marker is
# served for every commit whose tree is published (the writer marks every ready
# commit), unless $cdn/unmarked lists the commit or $cdn/NOAUTO exists (the writer's own test).
cat > "$TMP/bin/curl" <<STUB
#!/usr/bin/env bash
out="" url="" fmt=""
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    -o) out="\$2"; shift 2 ;;
    -w) fmt="\$2"; shift 2 ;;
    --proto|--retry|--retry-delay|--connect-timeout|--max-time) shift 2 ;;
    -*) shift ;;
    *) url="\$1"; shift ;;
  esac
done
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
  [[ -n "\$fmt" ]] && { printf 404; exit 0; }
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
  [[ -f "$TMP/gh-runs" ]] || exit 1
  cat "$TMP/gh-runs"; exit 0
fi
if [[ "\$1" == api && "\$2" == repos/*/actions/workflows/cmux-tui-artifacts.yml/runs\?* ]]; then
  [[ -f "$TMP/gh-runs" ]] || exit 1
  case "\$2" in
    *"&status=in_progress&"*) cat "$TMP/gh-runs" ;;
    *"&status=queued&"*|*"&status=waiting&"*|*"&status=pending&"*|*"&status=requested&"*) echo 0 ;;
    *) echo "gh stub: unknown status in \$2" >&2; exit 1 ;;
  esac
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
no_api() { ! grep -q '^api' "$TMP/gh.log" || fail "--tree-ready must read no GitHub API:" "$(cat "$TMP/gh.log")"; }
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
real_git=$(command -v git)
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
echo 2 > "$TMP/gh-runs"
RUN_ID=12 request --sha "$other" --release-compile-green
! backfilled && grep -q "queued or running" <<<"$out" \
  || fail "no backfill while an artifacts run is active:" "$out" "$(cat "$TMP/gh.log")"
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
git_q -C "$src" checkout -q --detach "$head"

# The checkout must be the commit it asks for; bad input is a usage error.
request --sha "$app" --release-compile-green
[[ "$status" == 2 ]] || fail "a --sha other than HEAD must exit 2, got $status:" "$out"
request --sha nothex --release-compile-green
[[ "$status" == 2 ]] || fail "a malformed --sha must exit 2, got $status:" "$out"
request --sha "$head"
[[ "$status" == 2 ]] || fail "--sha without --release-compile-green must exit 2, got $status:" "$out"
: "$other"
echo "PASS: nightly-next promotion waits for the published tree, not its daemon tests or the Release compile"
