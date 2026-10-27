#!/usr/bin/env bash
# request-nightly-next.sh: feat-cmux-next asks main to promote a commit to
# nightly-next only when that commit's cmux-tui tree is published and
# daemon-tested. Its Release compile is not awaited (2026-10-26): the nightly
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
cp "$ROOT/scripts/cmux-next/pin-cmux-tui.sh" "$src/scripts/cmux-next/"
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
cat > "$TMP/bin/curl" <<STUB
#!/usr/bin/env bash
out="" url=""
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    -o) out="\$2"; shift 2 ;;
    --proto|--retry|--retry-delay|--connect-timeout|--max-time|-w) shift 2 ;;
    -*) shift ;;
    *) url="\$1"; shift ;;
  esac
done
path="\${url#https://files.cmux.com/cmux-tui/}"
[[ "\$path" != "\$url" && -f "$cdn/\$path" ]] || exit 22
if [[ -n "\$out" ]]; then cp "$cdn/\$path" "\$out"; else cat "$cdn/\$path"; fi
STUB
# gh: records every call; the script reads no API (candidates come from git).
cat > "$TMP/bin/gh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP/gh.log"
[[ "\$1" == api ]] || exit 0
echo "gh stub: unexpected api call \$*" >&2; exit 1
STUB
chmod +x "$TMP/bin/curl" "$TMP/bin/gh"

request() { # <args...> -> output in $out, exit in $status
  status=0
  : > "$TMP/gh.log"
  out=$(cd "$src" && env -u GITHUB_STEP_SUMMARY -u GITHUB_OUTPUT -u CMUX_TUI_TREE_DISPATCH PATH="$TMP/bin:$PATH" \
    bash scripts/cmux-next/request-nightly-next.sh --repo o/r "$@" 2>&1) || status=$?
}
dispatched() { grep -qx "workflow run nightly.yml --repo o/r --ref main -f promote_nightly_next_sha=$1" "$TMP/gh.log"; }

# A cmux-tui change whose tree is still building is never promoted, even with
# a green Release compile: the nightly would have no daemon for it.
echo two > "$src/cmux-tui/a"; git_q -C "$src" add -A; git_q -C "$src" commit -m "tui two"
head=$(git -C "$src" rev-parse HEAD)
request --sha "$head" --release-compile-green
[[ "$status" == 0 ]] || fail "an unpublished tree is not an error (exit $status):" "$out"
! dispatched "$head" || fail "a commit whose tree is not published must not be promoted:" "$(cat "$TMP/gh.log")"
grep -q "not published" <<<"$out" || fail "the skip must say the tree is not published:" "$out"

# Once the tree publishes, the same green commit is promoted.
publish "$head"
request --sha "$head" --release-compile-green
[[ "$status" == 0 ]] && dispatched "$head" || fail "a green commit with a published tree must be promoted (exit $status):" "$out" "$(cat "$TMP/gh.log")"

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
out=$(cd "$shallow" && env -u GITHUB_STEP_SUMMARY -u GITHUB_OUTPUT -u CMUX_TUI_TREE_DISPATCH PATH="$TMP/gitbin:$TMP/bin:$PATH" \
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
git_q -C "$src" checkout -q --detach "$head"

# A tree published before its daemon tests ended (source.json daemonTests
# "separate", chief 2026-10-13) is promoted only once daemon-tests.json exists.
publish "$other"
okey=$(key "$other")
printf '{"key": "%s", "commit": "%s", "daemonTests": "separate"}\n' "$okey" "$other" > "$cdn/tree/$okey/source.json"
git_q -C "$src" checkout -q --detach "$other"
request --sha "$other" --release-compile-green
[[ "$status" == 0 ]] && ! dispatched "$other" && grep -q "daemon tests have not passed" <<<"$out" \
  || fail "a tree without its daemon-tests marker must not be promoted (exit $status):" "$out" "$(cat "$TMP/gh.log")"
printf '{"key": "%s", "result": "success"}\n' "$okey" > "$cdn/tree/$okey/daemon-tests.json"
request --sha "$other" --release-compile-green
[[ "$status" == 0 ]] && dispatched "$other" || fail "a tree with its daemon-tests marker must be promoted (exit $status):" "$out" "$(cat "$TMP/gh.log")"
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
request --sha "$greenx" --release-compile-green
[[ "$status" == 0 ]] && ! dispatched "$greenx" && grep -q "already on nightly-next" <<<"$out" \
  || fail "--release-compile-green must not re-request a promoted commit (exit $status):" "$out" "$(cat "$TMP/gh.log")"
git_q -C "$src" update-ref -d refs/heads/nightly-next
git_q -C "$src" checkout -q --detach "$head"

# The checkout must be the commit it asks for; bad input is a usage error.
request --sha "$app" --release-compile-green
[[ "$status" == 2 ]] || fail "a --sha other than HEAD must exit 2, got $status:" "$out"
request --sha nothex --release-compile-green
[[ "$status" == 2 ]] || fail "a malformed --sha must exit 2, got $status:" "$out"
request --sha "$head"
[[ "$status" == 2 ]] || fail "--sha without --release-compile-green must exit 2, got $status:" "$out"
: "$other"
echo "PASS: nightly-next promotion waits for the published, daemon-tested tree, not the Release compile"
