#!/usr/bin/env bash
# request-nightly-next.sh: feat-cmux-next asks main to promote a commit to
# nightly-next only when that commit's cmux-tui tree is published AND its
# "cmux-next Release compile (Xcode 26)" passed. Whichever of the two finishes
# last asks (cmux-next.yml after the Release compile, cmux-tui-artifacts.yml
# after the publication), so nightly-next always points at a commit the
# nightly can build with its own workflow and its own daemon.
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
job_name="cmux-next Release compile (Xcode 26)"

src="$TMP/src"
git_q init "$src"
mkdir -p "$src/cmux-tui" "$src/scripts/cmux-next" "$src/scripts/ci"
cp "$ROOT/scripts/cmux-next/pin-cmux-tui.sh" "$src/scripts/cmux-next/"
[[ -f "$ROOT/scripts/cmux-next/request-nightly-next.sh" ]] \
  && cp "$ROOT/scripts/cmux-next/request-nightly-next.sh" "$src/scripts/cmux-next/"
cp "$ROOT/scripts/ci/cmux_tui_tree_key.py" "$src/scripts/ci/"
cp "$ROOT/scripts/cmux-next/cmux-tui-tree-inputs.txt" "$src/scripts/cmux-next/"
echo reducer > "$src/scripts/cmux-next/build-layout-reducer-ffi.sh"
echo one > "$src/cmux-tui/a"
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
# gh: records every call; `api` serves the fixtures under $TMP/api.
cat > "$TMP/bin/gh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP/gh.log"
[[ "\$1" == api ]] || exit 0
for arg in "\$@"; do
  case "\$arg" in
    repos/*/actions/workflows/cmux-next.yml/runs*) cat "$TMP/api/runs.json"; exit 0 ;;
    repos/*/actions/runs/*/jobs*) id="\${arg#*/actions/runs/}"; cat "$TMP/api/jobs-\${id%%/*}.json"; exit 0 ;;
  esac
done
echo "gh stub: unexpected api call \$*" >&2; exit 1
STUB
chmod +x "$TMP/bin/curl" "$TMP/bin/gh"
mkdir -p "$TMP/api"

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

# From the artifacts workflow the Release compile is looked up: in progress
# or red means no request (cmux-next.yml asks once it is green) ...
printf '[{"workflow_runs": [{"id": 11, "head_sha": "%s", "head_branch": "feat-cmux-next", "event": "push"}]}]\n' "$app" > "$TMP/api/runs.json"
printf '[{"jobs": [{"name": "%s", "status": "in_progress", "conclusion": null}]}]\n' "$job_name" > "$TMP/api/jobs-11.json"
request --sha "$app"
[[ "$status" == 0 ]] || fail "a pending Release compile is not an error (exit $status):" "$out"
! dispatched "$app" || fail "a commit without a green Release compile must not be promoted:" "$(cat "$TMP/gh.log")"
grep -q "Release compile" <<<"$out" || fail "the skip must name the Release compile:" "$out"
printf '[{"jobs": [{"name": "%s", "status": "completed", "conclusion": "failure"}]}]\n' "$job_name" > "$TMP/api/jobs-11.json"
request --sha "$app"
! dispatched "$app" || fail "a red Release compile must not be promoted"
# ... and a green one is promoted.
printf '[{"jobs": [{"name": "other", "status": "completed", "conclusion": "failure"}, {"name": "%s", "status": "completed", "conclusion": "success"}]}]\n' "$job_name" > "$TMP/api/jobs-11.json"
request --sha "$app"
[[ "$status" == 0 ]] && dispatched "$app" || fail "a published tree with a green Release compile must be promoted:" "$out" "$(cat "$TMP/gh.log")"

# A run for another commit or branch never counts.
printf '[{"workflow_runs": [{"id": 11, "head_sha": "%s", "head_branch": "other", "event": "push"}]}]\n' "$app" > "$TMP/api/runs.json"
request --sha "$app"
! dispatched "$app" || fail "a Release compile on another branch must not count"

# The checkout must be the commit it asks for; bad input is a usage error.
request --sha "$head" --release-compile-green
[[ "$status" == 2 ]] || fail "a --sha other than HEAD must exit 2, got $status:" "$out"
request --sha nothex --release-compile-green
[[ "$status" == 2 ]] || fail "a malformed --sha must exit 2, got $status:" "$out"
echo "PASS: nightly-next promotion waits for both the published tree and the green Release compile"
