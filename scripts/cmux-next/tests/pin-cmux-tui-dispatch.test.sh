#!/usr/bin/env bash
# pin-cmux-tui.sh finds a cmux-tui artifact by its SOURCE tree key, not by
# commit, and with CMUX_TUI_TREE_DISPATCH=1 starts at most one publisher for a
# key that nothing publishes. cmux-tui-artifacts.yml coalesces feat-cmux-next
# pushes (one group per branch since a32b17000eda), so only the tip's tree is
# published; a build of an older commit with the same cmux-tui tree uses the
# tip's artifact, and a build of a commit with a changed tree dispatches one
# workflow_dispatch run on a cmux-tui-pin-<sha12> ref (concurrency group
# sha-<sha>, which the per-branch push group never cancels).
# No network: a stub curl serves the CDN and the GitHub API and logs calls.
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
cp "$ROOT/scripts/ci/cmux_tui_tree_key.py" "$src/scripts/ci/"
cp "$ROOT/scripts/cmux-next/cmux-tui-tree-inputs.txt" "$src/scripts/cmux-next/"
echo reducer > "$src/scripts/cmux-next/build-layout-reducer-ffi.sh"
chmod 755 "$src/scripts/cmux-next/build-layout-reducer-ffi.sh"
echo one > "$src/cmux-tui/a"
git_q -C "$src" add -A
git_q -C "$src" commit -m one
git_q -C "$src" update-index --add --cacheinfo 160000,"$(git -C "$src" rev-parse HEAD)",ghostty
git_q -C "$src" commit -m gitlink
commit() { git_q -C "$src" add -A; git_q -C "$src" commit -m "$1"; git -C "$src" rev-parse HEAD; }
echo two > "$src/cmux-tui/a"; old=$(commit "tui two (an older commit)")
echo app > "$src/App.swift"; tip=$(commit "app only: the tip, same cmux-tui tree")
key() { (cd "$src" && python3 scripts/ci/cmux_tui_tree_key.py --version v2 "$1" 2>/dev/null); }
[[ "$(key "$old")" == "$(key "$tip")" ]] || fail "test setup: the app-only tip must keep the tree key"

cdn="$TMP/cdn" api="$TMP/api"
mkdir -p "$api"
publish() { # <commit>: the artifacts workflow published this commit's tree
  local k; k=$(key "$1")
  mkdir -p "$cdn/tree/$k" "$cdn/$1"
  echo "build of $1" > "$cdn/tree/$k/$bin"
  sha "$cdn/tree/$k/$bin" > "$cdn/tree/$k/$bin.sha256"
  printf '{"key": "%s", "commit": "%s"}\n' "$k" "$1" > "$cdn/tree/$k/source.json"
  printf '{"commit": "%s", "binaries": {"%s": "%s"}}\n' "$1" "$bin" "$(sha "$cdn/tree/$k/$bin")" > "$cdn/$1/manifest.json"
}
runs() { # <file name> <json>: a canned GitHub API answer
  printf '%s\n' "$2" > "$api/$1"
}

mkdir -p "$TMP/bin"
cat > "$TMP/bin/curl" <<STUB
#!/usr/bin/env bash
out="" url="" method=GET
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    -o) out="\$2"; shift 2 ;;
    -X) method="\$2"; shift 2 ;;
    -d|--data) shift 2 ;;
    -H|--proto|--retry|--retry-delay|--connect-timeout|--max-time|-w|-u) shift 2 ;;
    -*) shift ;;
    *) url="\$1"; shift ;;
  esac
done
url="\${url%%\?t=*}"
echo "\$method \$url" >> "$TMP/curl.log"
emit() { if [[ -n "\$out" ]]; then cp "\$1" "\$out"; else cat "\$1"; fi; }
case "\$url" in
  https://files.cmux.com/cmux-tui/*)
    path="\${url#https://files.cmux.com/cmux-tui/}"
    [[ -f "$cdn/\$path" ]] || exit 22
    emit "$cdn/\$path" ;;
  https://api.github.com/repos/manaflow-ai/cmux/*)
    path="\${url#https://api.github.com/repos/manaflow-ai/cmux/}"
    case "\$method \$path" in
      "GET actions/workflows/cmux-tui-artifacts.yml/runs?head_sha="*) f=runs-\${path##*head_sha=}; f=\${f%%&*} ;;
      "GET actions/workflows/cmux-tui-artifacts.yml/runs"*) f=runs-active ;;
      "POST git/refs") f=ref-created ;;
      "POST actions/workflows/cmux-tui-artifacts.yml/dispatches") exit 0 ;;
      *) exit 22 ;;
    esac
    [[ -f "$api/\$f" ]] || f=empty
    emit "$api/\$f" ;;
  *) exit 22 ;;
esac
STUB
chmod +x "$TMP/bin/curl"
runs empty '{"workflow_runs": []}'
runs ref-created '{"ref": "created"}'

resolve() { # <commit> [env...]: resolve-commit at <commit>
  local at="$1"; shift
  git -C "$src" checkout -q "$at"
  : > "$TMP/curl.log"
  status=0
  out=$(cd "$src" && env -u GITHUB_STEP_SUMMARY -u GITHUB_OUTPUT PATH="$TMP/bin:$PATH" GH_TOKEN=test-token \
    CMUX_TUI_TREE_WAIT_SECONDS=1 CMUX_TUI_TREE_POLL_SECONDS=1 CMUX_TUI_TREE_DISPATCH_SETTLE_SECONDS=0 "$@" \
    bash scripts/cmux-next/pin-cmux-tui.sh resolve-commit 2>"$TMP/err") || status=$?
  err=$(cat "$TMP/err")
  dispatches=$(grep -c '^POST .*/dispatches$' "$TMP/curl.log" || true)
  refs=$(grep -c '^POST .*/git/refs$' "$TMP/curl.log" || true)
}

# (a) Only the tip's tree is published. The older commit has the same cmux-tui
# tree, so it resolves to the tip's artifact and dispatches nothing.
publish "$tip"
resolve "$old" CMUX_TUI_TREE_DISPATCH=1
[[ "$status" == 0 && "$out" == "$tip" ]] || fail "(a) an older commit with the tip's tree must resolve to the tip's artifact (exit $status):" "$out" "$err"
[[ "$dispatches" == 0 && "$refs" == 0 ]] || fail "(a) a published tree must start no publisher (dispatches $dispatches, refs $refs):" "$(cat "$TMP/curl.log")"

# (b) A changed tree that no run publishes: exactly one pin ref and one dispatch.
echo three > "$src/cmux-tui/a"; changed=$(commit "tui three (never published)")
resolve "$changed" CMUX_TUI_TREE_DISPATCH=1
[[ "$status" != 0 ]] || fail "(b) the unpublished tree must still fail the bounded wait:" "$out"
[[ "$refs" == 1 && "$dispatches" == 1 ]] || fail "(b) a missing tree needs exactly one ref create and one dispatch (refs $refs, dispatches $dispatches):" "$(cat "$TMP/curl.log")" "$err"
grep -q "cmux-tui-pin-${changed:0:12}" <<<"$err" || fail "(b) the dispatch must name the cmux-tui-pin-${changed:0:12} ref:" "$err"
# Without CMUX_TUI_TREE_DISPATCH=1 nothing is dispatched (credential-free callers).
resolve "$changed"
[[ "$refs" == 0 && "$dispatches" == 0 ]] || fail "(b) dispatch must be opt-in (refs $refs, dispatches $dispatches)"

# (c) An active run for another commit with the same tree key: no dispatch.
echo app2 > "$src/App.swift"; sibling=$(commit "app only after the change: same tree as $changed")
git -C "$src" checkout -q "$changed"
runs runs-active "{\"workflow_runs\": [{\"id\": 7, \"status\": \"in_progress\", \"head_sha\": \"$sibling\"}]}"
resolve "$changed" CMUX_TUI_TREE_DISPATCH=1
[[ "$refs" == 0 && "$dispatches" == 0 ]] || fail "(c) an active run for the same key must start no publisher (refs $refs, dispatches $dispatches):" "$(cat "$TMP/curl.log")" "$err"
# (c) An active run for the exact commit: no dispatch.
runs runs-active '{"workflow_runs": []}'
runs "runs-$changed" "{\"workflow_runs\": [{\"id\": 8, \"status\": \"queued\", \"head_sha\": \"$changed\"}]}"
resolve "$changed" CMUX_TUI_TREE_DISPATCH=1
[[ "$refs" == 0 && "$dispatches" == 0 ]] || fail "(c) an active run for the commit must start no publisher (refs $refs, dispatches $dispatches):" "$(cat "$TMP/curl.log")"

# (d) A miss is never silent: it names this tree, the nearest published tree
# (informational only: its source differs) and what happens next.
runs runs-active '{"workflow_runs": []}'
rm -f "$api/runs-$changed"
git -C "$src" checkout -q "$changed"
echo four > "$src/cmux-tui/a"; four=$(commit "tui four (never published)")
resolve "$four"
# History: four -> changed -> old (case (a) checked out old before changed was
# made). The tip published old's tree, so the nearest commit is old.
grep -q "no published cmux-tui tree for $(key "$four") (head ${four:0:12}); nearest published tree: $(key "$old") from ${old:0:12} (2 commits back, cmux-tui source differs)" <<<"$err" \
  || fail "(d) a miss must name the nearest published tree $(key "$old") from ${old:0:12} 2 commits back:" "$err"
grep -q "next: no dispatch (CMUX_TUI_TREE_DISPATCH unset); waiting up to 1s for a push run, or bundle a local build with CMUX_NEXT_TUI_BIN=<path>" <<<"$err" \
  || fail "(d) a miss without dispatch must say what happens next:" "$err"
[[ "$(grep -c 'no published cmux-tui tree for' <<<"$err")" == 1 ]] || fail "(d) the miss block must print once:" "$err"
resolve "$four" CMUX_TUI_TREE_DISPATCH=1
grep -q "next: dispatching one cmux-tui-artifacts run for ${four:0:12} (CMUX_TUI_TREE_DISPATCH=1)" <<<"$err" \
  || fail "(d) a dispatching miss must say so:" "$err"
resolve "$four" CMUX_TUI_TREE_NEAREST_COMMITS=2
grep -q "no published cmux-tui tree for $(key "$four") (head ${four:0:12}); nearest published tree: none in the last 2 commits" <<<"$err" \
  || fail "(d) a history without a published tree must say none in the last 2 commits:" "$err"

echo "PASS: cmux-tui artifacts resolve by source tree key and one publisher is dispatched for a missing tree"
