#!/usr/bin/env bash
# NIGHTLY_NEXT_TREE_AT_INSTALL (nightly.yml): a NEXT nightly that starts before
# its tree is published.
#   scripts/cmux-next/await-tree-client.sh picks the commit whose attested
#   manifest the build installs: the tree's publisher once the tree is published,
#   before that the first candidate (oldest first) whose manifest is uploaded; it
#   fails fast when no artifacts run builds the tree, and at its limit otherwise.
#   scripts/ci/nightly-steps/await-tree-marker.sh lets publish-nightly run only
#   once the build commit's marker names the build's tree and the installed
#   client's commit as its publisher.
#   scripts/ci/nightly-steps/resolve-tree-pending.sh reports tree_pending and the
#   candidates only for a clean 404.
# No network: a curl shim serves the CDN from files, the GitHub API is file://.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
source "$ROOT/scripts/cmux-next/tests/lib/fake-clock.sh"
fake_clock_install "$TMP/clock"
fail=0
check() { if eval "$1"; then echo "ok   $2"; else echo "FAIL $2"; fail=1; fi; }
git_q() { git -c user.name=t -c user.email=t@example.com -c init.defaultBranch=main "$@" >/dev/null 2>&1; }

# A repository with three commits: base, then `own` changes the tree, then `app` keeps it.
git_q init "$TMP/src"
mkdir -p "$TMP/src/cmux-tui" "$TMP/src/scripts/cmux-next" "$TMP/src/scripts/ci/nightly-steps"
cp "$ROOT/scripts/cmux-next/pin-cmux-tui.sh" "$ROOT/scripts/cmux-next/await-tree-client.sh" \
  "$ROOT/scripts/cmux-next/tree-commit-marker.sh" "$ROOT/scripts/cmux-next/cmux-tui-tree-inputs.txt" \
  "$TMP/src/scripts/cmux-next/"
cp "$ROOT/scripts/ci/cmux_tui_tree_key.py" "$TMP/src/scripts/ci/"
cp "$ROOT/scripts/ci/nightly-steps/await-tree-marker.sh" "$ROOT/scripts/ci/nightly-steps/resolve-tree-pending.sh" \
  "$ROOT/scripts/ci/nightly-steps/recover-tree-marker-ok.sh" \
  "$TMP/src/scripts/ci/nightly-steps/"
echo reducer > "$TMP/src/scripts/cmux-next/build-layout-reducer-ffi.sh"
"$ROOT/scripts/cmux-next/tests/lib/tree-inputs-fixture.sh" "$TMP/src"
echo one > "$TMP/src/cmux-tui/a"
git_q -C "$TMP/src" add -A; git_q -C "$TMP/src" commit -m base
base=$(git -C "$TMP/src" rev-parse HEAD)
echo two > "$TMP/src/cmux-tui/a"
git_q -C "$TMP/src" add -A; git_q -C "$TMP/src" commit -m own
own=$(git -C "$TMP/src" rev-parse HEAD)
echo app > "$TMP/src/app.swift"
git_q -C "$TMP/src" add -A; git_q -C "$TMP/src" commit -m app
app=$(git -C "$TMP/src" rev-parse HEAD)
key=$(cd "$TMP/src" && python3 scripts/ci/cmux_tui_tree_key.py --version v2 HEAD)
[[ "$(cd "$TMP/src" && python3 scripts/ci/cmux_tui_tree_key.py --version v2 "$own")" == "$key" ]] || { echo "fixture: own and app differ" >&2; exit 1; }
[[ "$(cd "$TMP/src" && python3 scripts/ci/cmux_tui_tree_key.py --version v2 "$base")" != "$key" ]] || { echo "fixture: base has the key" >&2; exit 1; }

# The CDN: https://cdn.test/cmux-tui/<path> serves $TMP/cdn/<path>; -f makes a miss exit 22,
# -w '%{http_code}' prints 200 or 404.
mkdir -p "$TMP/bin" "$TMP/cdn"
real_curl=$(command -v curl)
cat > "$TMP/bin/curl" <<SHIM
#!/usr/bin/env bash
out=""; url=""; code=""; fail=""; args=("\$@")
for ((i = 0; i < \${#args[@]}; i++)); do
  case "\${args[i]}" in
    -o) out="\${args[i+1]}" ;;
    -w) code=1 ;;
    -f*|-*f) [[ "\${args[i]}" == -* && "\${args[i]}" != --* && "\${args[i]}" == *f* ]] && fail=1 ;;
    https://cdn.test/*) url="\${args[i]}" ;;
  esac
done
# A head_sha= runs query reads runs-<sha> beside the runs list (none when it is absent),
# the way the API filters by commit.
for a in "\$@"; do
  if [[ "\$a" == file://*head_sha=* ]]; then
    want="\${a##*head_sha=}"; want="\${want%%&*}"; f="\${a%%\\?*}"; f="\${f#file://}-\$want"
    if [[ -f "\$f" ]]; then cat "\$f"; else echo '{"total_count":0,"workflow_runs":[]}'; fi
    exit 0
  fi
done
if [[ -z "\$url" ]]; then exec "$real_curl" "\$@"; fi
path="$TMP/cdn/\${url#https://cdn.test/cmux-tui/}"; path="\${path%%\\?*}"
if [[ ! -f "\$path" ]]; then
  [[ -n "\$fail" ]] && exit 22
  [[ -n "\$code" ]] && printf 404
  exit 0
fi
if [[ -n "\$out" ]]; then cp "\$path" "\$out"; else cat "\$path"; fi
[[ -n "\$code" ]] && printf 200
exit 0
SHIM
chmod +x "$TMP/bin/curl"
runs_dir="$TMP/api/repos/o/r/actions/workflows/cmux-tui-artifacts.yml"
mkdir -p "$runs_dir"
set_runs() { printf '%s\n' "$1" > "$runs_dir/runs"; }
no_runs='{"total_count":0,"workflow_runs":[]}'
active_run="{\"total_count\":1,\"workflow_runs\":[{\"id\":1,\"status\":\"in_progress\",\"head_sha\":\"$own\",\"head_branch\":\"feat-cmux-next\"}]}"
sha_of() { printf '%s' "$1" | sha256sum | awk '{print $1}'; }
# publish_manifest <commit>: the commit-addressed manifest of <commit> with the darwin binary.
publish_manifest() {
  mkdir -p "$TMP/cdn/$1"
  printf '{"commit":"%s","binaries":{"cmux-tui-aarch64-apple-darwin":"%s"}}\n' "$1" "$(sha_of bin)" > "$TMP/cdn/$1/manifest.json"
}
# publish_tree <publisher>: tree $key published by <publisher>.
publish_tree() {
  mkdir -p "$TMP/cdn/tree/$key"
  printf '%s  cmux-tui-aarch64-apple-darwin\n' "$(sha_of bin)" > "$TMP/cdn/tree/$key/cmux-tui-aarch64-apple-darwin.sha256"
  printf '{"commit":"%s","key":"%s"}\n' "$1" "$key" > "$TMP/cdn/tree/$key/source.json"
}
reset_cdn() { rm -rf "$TMP/cdn"; mkdir -p "$TMP/cdn"; }
env_common=(PATH="$TMP/bin:$PATH" GITHUB_REPOSITORY=o/r GITHUB_API_URL="file://$TMP/api" GH_TOKEN=t
  CMUX_TUI_PIN_BASE=https://cdn.test/cmux-tui CMUX_TUI_DOWNLOAD_ATTEMPTS=1)
client() { # <candidates...> -> out, status, took
  local started; started=$(date +%s); status=0
  out=$(cd "$TMP/src" && env "${env_common[@]}" CMUX_TUI_TREE_CLIENT_WAIT_SECONDS=600 CMUX_TUI_TREE_CLIENT_POLL_SECONDS=20 \
    CMUX_TUI_TREE_CLIENT_RUN_CHECK_SECONDS=120 bash scripts/cmux-next/await-tree-client.sh "$key" "$@" 2>"$TMP/err") || status=$?
  took=$(( $(date +%s) - started ))
}

# 1. The tree is published: its publisher, whatever the candidates say.
reset_cdn; set_runs "$no_runs"; publish_tree "$own"; publish_manifest "$own"; publish_manifest "$app"
client "$own" "$app"
check '[[ $status == 0 && $out == "$own" ]]' "a published tree installs its publisher's client"

# 2. Not published yet; the manifest of the oldest candidate appears 90 s in.
reset_cdn; set_runs "$active_run"
fake_clock_at 90 "mkdir -p '$TMP/cdn/$own' && printf '{\"commit\":\"$own\",\"binaries\":{}}' > '$TMP/cdn/$own/manifest.json'"
client "$own" "$app"
check '[[ $status == 0 && $out == "$own" && $took -ge 90 && $took -lt 200 ]]' "an uploaded candidate manifest ends the wait (took $took s)"

# 3. Candidates are tried oldest first: only the newer one has a manifest, so it is taken.
reset_cdn; set_runs "$active_run"; publish_manifest "$app"
client "$own" "$app"
check '[[ $status == 0 && $out == "$app" ]]' "a later candidate's manifest is taken when the earlier has none"

# 4. Nothing published and no active artifacts run with the tree: fails at the second check.
reset_cdn; set_runs "$no_runs"
client "$own" "$app"
check '[[ $status == 1 && $took -ge 120 && $took -lt 300 ]] && grep -q "nothing will publish it" "$TMP/err"' "no publisher fails fast (took $took s)"

# 5. An active run that never uploads: fails at the limit, not before.
reset_cdn; set_runs "$active_run"
client "$own" "$app"
check '[[ $status == 1 && $took -ge 600 ]] && grep -q "after 10 min" "$TMP/err"' "an active run that never uploads fails at the limit (took $took s)"

# 5b. The runs list is crowded by other commits, but a candidate's own run is active:
# the wait goes on to the limit instead of failing fast.
reset_cdn; set_runs "$no_runs"
printf '%s\n' "{\"total_count\":1,\"workflow_runs\":[{\"id\":2,\"status\":\"queued\",\"head_sha\":\"$own\"}]}" > "$runs_dir/runs-$own"
client "$own" "$app"
check '[[ $status == 1 && $took -ge 600 ]] && grep -q "is building tree" "$TMP/err"' "a candidate's own active run counts as a publisher (took $took s)"
rm -f "$runs_dir/runs-$own"

# 6. Bad usage.
status=0; (cd "$TMP/src" && bash scripts/cmux-next/await-tree-client.sh nope "$own" 2>/dev/null) || status=$?
check '[[ $status == 2 ]]' "a malformed key is a usage error"

# The marker gate.
marker() { # <commit> <key> <publishedBy>
  mkdir -p "$TMP/cdn/tree-commits"
  printf '{"commit":"%s","key":"%s","publishedBy":"%s","markedBy":"https://example.test/run/1"}\n' "$1" "$2" "$3" \
    > "$TMP/cdn/tree-commits/$1.json"
}
gate() { # <installed> -> status, took
  local started; started=$(date +%s); status=0
  (cd "$TMP/src" && env "${env_common[@]}" BUILD_SHA="$app" KEY="$key" INSTALLED="$1" \
    CMUX_TREE_MARKER_WAIT_SECONDS=300 bash scripts/ci/nightly-steps/await-tree-marker.sh >"$TMP/out" 2>&1) || status=$?
  took=$(( $(date +%s) - started ))
}
reset_cdn; marker "$app" "$key" "$own"; gate "$own"
check '[[ $status == 0 ]]' "a marker naming the installed client's commit lets publication run"
reset_cdn; marker "$app" "$key" "$app"; gate "$own"
check '[[ $status == 1 ]] && grep -q "installed the client of" "$TMP/out"' "a marker naming another publisher refuses"
reset_cdn; marker "$app" "$(printf 'e%.0s' {1..40})" "$own"; gate "$own"
check '[[ $status == 1 ]] && grep -q "not the build" "$TMP/out"' "a marker naming another tree refuses"
reset_cdn; fake_clock_at 60 "mkdir -p '$TMP/cdn/tree-commits' && printf '{\"commit\":\"$app\",\"key\":\"$key\",\"publishedBy\":\"$own\",\"markedBy\":\"u\"}' > '$TMP/cdn/tree-commits/$app.json'"
gate "$own"
check '[[ $status == 0 && $took -ge 60 && $took -lt 120 ]]' "the gate waits for a marker written later (took $took s)"
reset_cdn; gate "$own"
check '[[ $status == 1 && $took -ge 300 ]] && grep -q "not written in time" "$TMP/out"' "no marker fails at the limit"

# The resolver's pending step.
pending() { # -> status, output file
  : > "$TMP/gh-output"; : > "$TMP/summary"; status=0
  (cd "$TMP/src" && env "${env_common[@]}" TIP_SHA="$app" GITHUB_OUTPUT="$TMP/gh-output" GITHUB_STEP_SUMMARY="$TMP/summary" \
    bash scripts/ci/nightly-steps/resolve-tree-pending.sh >/dev/null 2>&1) || status=$?
}
reset_cdn; pending
check '[[ $status == 0 ]] && grep -qx "tree_pending=true" "$TMP/gh-output" && grep -qx "candidates=$own $app" "$TMP/gh-output" && grep -qx "key=$key" "$TMP/gh-output"' \
  "an unpublished tip is built with its same-key candidates, oldest first"
reset_cdn; publish_tree "$own"; publish_manifest "$own"; pending
check '[[ $status == 0 ]] && grep -qx "tree_pending=false" "$TMP/gh-output"' "a published tip leaves it to the resolver"
reset_cdn; mkdir -p "$TMP/cdn/tree/$key"; echo garbage > "$TMP/cdn/tree/$key/cmux-tui-aarch64-apple-darwin.sha256"; pending
check '[[ $status == 0 ]] && grep -qx "tree_pending=false" "$TMP/gh-output"' "an unverifiable tree is not taken as pending"

# Recovery: a run's await-nightly-tree-marker must have passed (or not exist).
mkdir -p "$TMP/ghbin"
cat > "$TMP/ghbin/gh" <<'GH'
#!/usr/bin/env bash
case "$GH_MODE" in
  ok) echo success ;; skipped) echo skipped ;; none) ;; failed) echo failure ;; running) echo pending ;;
  unreadable) exit 1 ;;
esac
GH
chmod +x "$TMP/ghbin/gh"
for mode in ok skipped none failed running unreadable; do
  status=0
  why=$(cd "$TMP/src" && PATH="$TMP/ghbin:$PATH" GH_MODE=$mode GITHUB_REPOSITORY=o/r bash scripts/ci/nightly-steps/recover-tree-marker-ok.sh 123 2>&1) || status=$?
  case "$mode" in
    ok|skipped|none) check '[[ $status == 0 ]]' "recovery allows a run whose marker check is $mode" ;;
    *) check '[[ $status == 1 && -n $why ]]' "recovery refuses a run whose marker check is $mode ($why)" ;;
  esac
done

(( fail == 0 )) && echo "PASS: nightly tree at install" || { echo "FAIL: nightly tree at install"; exit 1; }
