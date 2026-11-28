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
#   candidates only for a clean 404, and the newest published tree as fallback=.
#   scripts/ci/nightly-steps/app-bundle-cmux-tui-client.sh installs the build
#   commit's tree when one look finds it, else the fallback tree right away
#   (RFD 0021 row 1), and the marker gate accepts that fallback tree's publisher.
# No network: a curl shim serves the CDN from files, the GitHub API is file://.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
source "$ROOT/scripts/cmux-next/tests/lib/fake-clock.sh"
fake_clock_install "$TMP/clock"
fail=0
check() { if eval "$1"; then echo "ok   $2"; else echo "FAIL $2"; fail=1; fi; }
# git_q, and no background git maintenance in the scratch repositories.
# shellcheck source=scripts/cmux-next/tests/lib/git-fixture.sh
source "$ROOT/scripts/cmux-next/tests/lib/git-fixture.sh"

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
# The daemon source and the app's capability list nightly_fallback_covers.py reads: `own` adds
# language-packs-v1 to both, the way #45928 did, so the client of `base` lacks it.
caps_json() { printf '{"required": ["identify-v1"], "optional": [%s], "unservedByBundledDaemon": []}\n' "$1" \
  > "$TMP/src/plans/cmux-next/daemon-capabilities.json"; }
mkdir -p "$TMP/src/cmux-tui/crates/cmux-tui-core/src/server" "$TMP/src/plans/cmux-next"
printf '[workspace]\nmembers = ["crates/cmux-tui-core"]\n' > "$TMP/src/cmux-tui/Cargo.toml"
printf '[package]\nname = "cmux-tui-core"\n' > "$TMP/src/cmux-tui/crates/cmux-tui-core/Cargo.toml"
printf 'pub const LIST: &[&str] = &["identify-v1", "history-v1"];\n' > "$TMP/src/cmux-tui/crates/cmux-tui-core/src/server/capabilities.rs"
caps_json '"history-v1"'
git_q -C "$TMP/src" add -A; git_q -C "$TMP/src" commit -m base
base=$(git -C "$TMP/src" rev-parse HEAD)
echo two > "$TMP/src/cmux-tui/a"
printf 'pub(crate) const CAPABILITY: &str = "language-packs-v1";\n' > "$TMP/src/cmux-tui/crates/cmux-tui-core/src/language_packs.rs"
caps_json '"history-v1", "language-packs-v1"'
git_q -C "$TMP/src" add -A; git_q -C "$TMP/src" commit -m own
own=$(git -C "$TMP/src" rev-parse HEAD)
echo app > "$TMP/src/app.swift"
git_q -C "$TMP/src" add -A; git_q -C "$TMP/src" commit -m app
app=$(git -C "$TMP/src" rev-parse HEAD)
echo takeover > "$TMP/src/takeover.swift"
git_q -C "$TMP/src" add -A; git_q -C "$TMP/src" commit -m takeover
takeover=$(git -C "$TMP/src" rev-parse HEAD)
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
mkdir -p "$TMP/api/repos/o/r/actions/runs/2"
printf '%s\n' '{"jobs":[{"name":"cmux-tui tree preflight","status":"in_progress","runner_name":"linux-2"}]}' > "$TMP/api/repos/o/r/actions/runs/2/jobs"
client "$own" "$app"
check '[[ $status == 1 && $took -ge 600 ]] && grep -q "is building tree" "$TMP/err"' "a candidate's own active run counts as a publisher (took $took s)"
rm -f "$runs_dir/runs-$own"

# 5c-5f. The wait follows the publisher's jobs, not only "active" (2026-11-18: nightly
# 44243166776 waited blind on owner 44240874997, whose Linux build had failed, and on a
# takeover run whose Linux builds sat queued on Blacksmith with no runner).
# Job times are relative to the fake clock, which earlier cases advanced: ago <seconds>.
ago() { date -u -d "@$(( $(awk '{ printf "%d", $1 }' "$FAKE_CLOCK_FILE") - $1 ))" +%Y-%m-%dT%H:%M:%SZ; }
jobs_file() { mkdir -p "$TMP/api/repos/o/r/actions/runs/$1"; printf '%s\n' "$2" > "$TMP/api/repos/o/r/actions/runs/$1/jobs"; }
# own_run <commit> <run id> [attempt]: an in-progress artifacts run of <commit>.
own_run() { printf '%s\n' "{\"total_count\":1,\"workflow_runs\":[{\"id\":$2,\"status\":\"in_progress\",\"run_attempt\":${3:-1},\"head_sha\":\"$1\",\"head_branch\":\"feat-cmux-next\",\"created_at\":\"2023-11-14T22:00:00Z\"}]}" > "$runs_dir/runs-$1"; }
failed_jobs='{"jobs":[{"name":"build / build aarch64-apple-darwin","status":"in_progress","runner_name":"mac-1","created_at":"2023-11-14T22:00:00Z"},{"name":"build-linux / build aarch64-unknown-linux-musl","status":"completed","conclusion":"failure","runner_name":"bs-1","created_at":"2023-11-14T22:00:00Z"}]}'
reset_cdn; set_runs "$no_runs"; own_run "$own" 3 3; jobs_file 3 "$failed_jobs"
client "$own" "$app"
check '[[ $status == 1 && $took -ge 120 && $took -lt 300 ]] && grep -q "making progress" "$TMP/err" && grep -q "failed build-linux" "$TMP/err"' "a publisher whose build failed on its last attempt fails fast, not at the limit (took $took s)"

# Before the last attempt cmux-tui-artifacts-retry re-runs the failed job (tree 453a2f94
# published on such a retry): the wait goes on.
reset_cdn; set_runs "$no_runs"; own_run "$own" 7 1; jobs_file 7 "$failed_jobs"
client "$own" "$app"
check '[[ $status == 1 && $took -ge 600 ]] && grep -q "is building tree" "$TMP/err"' "a failed build that a retry will re-run keeps the wait (took $took s)"

# A failed primary macOS leg is rebuilt by build-darwin-fallback: not final either.
reset_cdn; set_runs "$no_runs"; own_run "$own" 8 3
jobs_file 8 '{"jobs":[{"name":"build / build aarch64-apple-darwin","status":"completed","conclusion":"failure","runner_name":"mac-1","created_at":"2023-11-14T22:00:00Z"}]}'
client "$own" "$app"
check '[[ $status == 1 && $took -ge 600 ]] && grep -q "is building tree" "$TMP/err"' "a failed primary macOS leg (the fallback rebuilds it) keeps the wait (took $took s)"

reset_cdn; set_runs "$no_runs"; own_run "$own" 4
jobs_file 4 '{"jobs":[{"name":"build / build aarch64-apple-darwin","status":"in_progress","runner_name":"mac-1","created_at":"'"$(ago 1000)"'"},{"name":"build / build aarch64-unknown-linux-musl","status":"queued","runner_name":null,"labels":["blacksmith-16vcpu-ubuntu-2404"],"created_at":"'"$(ago 1000)"'"}]}'
client "$own" "$app"
check '[[ $status == 1 && $took -ge 120 && $took -lt 300 ]] && grep -Eq "queued 1[6-9] min for blacksmith-16vcpu-ubuntu-2404" "$TMP/err"' "a publisher whose build has no runner past the stall bound fails fast (took $took s)"

reset_cdn; set_runs "$no_runs"; own_run "$own" 5
jobs_file 5 '{"jobs":[{"name":"build / build aarch64-unknown-linux-musl","status":"queued","runner_name":null,"labels":["blacksmith-16vcpu-ubuntu-2404"],"created_at":"'"$(ago 0)"'"}]}'
client "$own" "$app"
check '[[ $status == 1 && $took -ge 600 ]] && grep -q "is building tree" "$TMP/err"' "a build queued under the stall bound keeps the wait (took $took s)"

# A job that does not hold the tree back (a shadow) may queue past the bound.
reset_cdn; set_runs "$no_runs"; own_run "$own" 9
jobs_file 9 '{"jobs":[{"name":"build / build aarch64-unknown-linux-musl","status":"in_progress","runner_name":"bs-2","created_at":"'"$(ago 1000)"'"},{"name":"macOS cross-compile shadow (Linux, compare only)","status":"queued","runner_name":null,"labels":["blacksmith-16vcpu-ubuntu-2404"],"created_at":"'"$(ago 1000)"'"}]}'
client "$own" "$app"
check '[[ $status == 1 && $took -ge 600 ]] && grep -q "is building tree" "$TMP/err"' "a queued job that holds no tree back keeps the wait (took $took s)"

# Preflight gates every build: the incident had only this job, queued without a runner.
reset_cdn; set_runs "$no_runs"; own_run "$own" 10
jobs_file 10 '{"jobs":[{"name":"cmux-tui tree preflight","status":"queued","runner_name":null,"labels":["cmux-gcp-lane-build-x64"],"created_at":"'"$(ago 1000)"'"}]}'
client "$own" "$app"
check '[[ $status == 1 && $took -ge 120 && $took -lt 300 ]] && grep -q "stalled cmux-tui tree preflight queued" "$TMP/err" && grep -q "cmux-gcp-lane-build-x64" "$TMP/err" && grep -q "/actions/runs/10" "$TMP/err"' "a preflight with no runner past the stall bound fails fast with its state and run (took $took s)"

preflight_failed='{"jobs":[{"name":"cmux-tui tree preflight","status":"completed","conclusion":"failure","runner_name":"linux-1","created_at":"2023-11-14T22:00:00Z"}]}'
reset_cdn; set_runs "$no_runs"; own_run "$own" 11 3; jobs_file 11 "$preflight_failed"
client "$own" "$app"
check '[[ $status == 1 && $took -ge 120 && $took -lt 300 ]] && grep -q "failed cmux-tui tree preflight" "$TMP/err" && grep -q "/actions/runs/11" "$TMP/err"' "a terminal preflight failure fails fast with its state and run (took $took s)"

# A completed workflow must retain the preflight error, not only an active workflow.
completed_run() {
  own_run "$1" "$2" "${3:-3}"
  python3 - "$runs_dir/runs-$1" <<'JSON'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["workflow_runs"][0].update(status="completed", conclusion="failure")
with open(p, "w") as f:
    json.dump(d, f)
JSON
}
reset_cdn; set_runs "$no_runs"; completed_run "$own" 11; jobs_file 11 "$preflight_failed"
client "$own" "$app"
check '[[ $status == 1 && $took -ge 120 && $took -lt 300 ]] && grep -q "failed cmux-tui tree preflight" "$TMP/err" && grep -q "/actions/runs/11" "$TMP/err"' "a completed publisher retains its terminal preflight failure (took $took s)"

# Let the automatic retry become active between the two idle observations.
reset_cdn; set_runs "$no_runs"; completed_run "$own" 12 1; jobs_file 12 "$preflight_failed"
cp "$runs_dir/runs-$own" "$TMP/completed-run"
own_run "$own" 12 2; cp "$runs_dir/runs-$own" "$TMP/active-retry"
cp "$TMP/completed-run" "$runs_dir/runs-$own"
fake_clock_at 60 "cp '$TMP/active-retry' '$runs_dir/runs-$own'"
client "$own" "$app"
check '[[ $status == 1 && $took -ge 600 ]] && grep -q "is building tree" "$TMP/err"' "an active retry clears a completed preflight failure during grace (took $took s)"

for attempt in 1 2; do
  reset_cdn; set_runs "$no_runs"; own_run "$own" 12 "$attempt"; jobs_file 12 "$preflight_failed"
  client "$own" "$app"
  check '[[ $status == 1 && $took -ge 600 ]] && grep -q "is building tree" "$TMP/err"' "a preflight failure with active retry grace keeps the wait on attempt $attempt (took $took s)"
done

reset_cdn; set_runs "$no_runs"; own_run "$own" 13
jobs_file 13 '{"jobs":[{"name":"cmux-tui tree preflight","status":"queued","runner_name":null,"labels":["cmux-gcp-lane-build-x64"],"created_at":"'"$(ago 0)"'"}]}'
client "$own" "$app"
check '[[ $status == 1 && $took -ge 600 ]] && grep -q "is building tree" "$TMP/err"' "a preflight queued under the stall bound keeps the wait (took $took s)"

# The failed owner is passed over for another same-key run that is building.
reset_cdn; own_run "$own" 3 3
set_runs "{\"total_count\":2,\"workflow_runs\":[{\"id\":3,\"status\":\"in_progress\",\"head_sha\":\"$own\",\"head_branch\":\"feat-cmux-next\"},{\"id\":6,\"status\":\"in_progress\",\"head_sha\":\"$app\",\"head_branch\":\"feat-cmux-next\"}]}"
own_run "$app" 6
jobs_file 6 '{"jobs":[{"name":"cmux-tui tree preflight","status":"in_progress","runner_name":"linux-6"}]}'
client "$own"
check '[[ $status == 1 && $took -ge 600 ]] && grep -q "run of ${app:0:12} is building tree" "$TMP/err"' "a failed owner is passed over for a same-key run that builds (took $took s)"
rm -f "$runs_dir/runs-$own" "$runs_dir/runs-$app"; rm -rf "$TMP/api/repos/o/r/actions/runs"

# A stalled first alternate must not hide a second publisher that is building.
echo another-app > "$TMP/src/app.swift"
git_q -C "$TMP/src" add app.swift; git_q -C "$TMP/src" commit -m app-again
app_again=$(git -C "$TMP/src" rev-parse HEAD)
reset_cdn; own_run "$app" 10; own_run "$app_again" 14
jobs_file 10 '{"jobs":[{"name":"cmux-tui tree preflight","status":"queued","runner_name":null,"created_at":"'"$(ago 1000)"'"}]}'
jobs_file 14 '{"jobs":[{"name":"cmux-tui tree preflight","status":"in_progress","runner_name":"linux-2"}]}'
set_runs "{\"workflow_runs\":[{\"id\":10,\"status\":\"in_progress\",\"head_sha\":\"$app\",\"head_branch\":\"feat-cmux-next\"},{\"id\":14,\"status\":\"in_progress\",\"head_sha\":\"$app_again\",\"head_branch\":\"feat-cmux-next\"}]}"
client "$own"
check '[[ $status == 1 && $took -ge 600 ]] && grep -q "run of ${app_again:0:12} is building tree" "$TMP/err"' "a stalled alternate is passed over for a progressing same-key publisher (took $took s)"
rm -f "$runs_dir/runs-$app" "$runs_dir/runs-$app_again"; rm -rf "$TMP/api/repos/o/r/actions/runs"
set_runs "$no_runs"
git_q -C "$TMP/src" checkout "$app"

# A stuck same-key publisher found in the full runs list is passed over for a later
# same-key publisher too; a single active-publisher lookup must not abort while a
# viable takeover run exists.
reset_cdn; own_run "$app" 10 3; own_run "$takeover" 11 1
jobs_file 10 "$failed_jobs"
jobs_file 11 '{"jobs":[{"name":"build / build aarch64-apple-darwin","status":"in_progress","runner_name":"mac-1","created_at":"2023-11-14T22:00:00Z"}]}'
set_runs "{\"total_count\":2,\"workflow_runs\":[{\"id\":10,\"status\":\"in_progress\",\"head_sha\":\"$app\",\"head_branch\":\"feat-cmux-next\"},{\"id\":11,\"status\":\"in_progress\",\"head_sha\":\"$takeover\",\"head_branch\":\"feat-cmux-next\"}]}"
client "$own"
check '[[ $status == 1 && $took -ge 600 ]] && grep -q "run of ${takeover:0:12} is building tree" "$TMP/err"' "a stuck publisher is passed over for a later same-key run (took $took s)"
rm -f "$runs_dir/runs-$app" "$runs_dir/runs-$takeover"; rm -rf "$TMP/api/repos/o/r/actions/runs"

# 6. Bad usage.
status=0; (cd "$TMP/src" && bash scripts/cmux-next/await-tree-client.sh nope "$own" 2>/dev/null) || status=$?
check '[[ $status == 2 ]]' "a malformed key is a usage error"

# 7. CMUX_TUI_TREE_CLIENT_WAIT_SECONDS=0 looks once and never waits or reads a runs list.
client_once() { # <candidates...> -> out, status, took
  local started; started=$(date +%s); status=0
  out=$(cd "$TMP/src" && env "${env_common[@]}" GITHUB_API_URL="file://$TMP/no-api" CMUX_TUI_TREE_CLIENT_WAIT_SECONDS=0 \
    bash scripts/cmux-next/await-tree-client.sh "$key" "$@" 2>"$TMP/err") || status=$?
  took=$(( $(date +%s) - started ))
}
reset_cdn; set_runs "$active_run"
client_once "$own" "$app"
check '[[ $status == 1 && $took -lt 20 ]] && grep -q "looked once" "$TMP/err"' "one look at an unpublished tree misses at once (took $took s)"
reset_cdn; publish_manifest "$app"
client_once "$own" "$app"
check '[[ $status == 0 && $out == "$app" ]]' "one look takes an uploaded candidate manifest"
reset_cdn; publish_tree "$own"; publish_manifest "$own"
client_once "$own" "$app"
check '[[ $status == 0 && $out == "$own" ]]' "one look takes a published tree's publisher"

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

# A build that bundled the newest published tree (base's) instead of its own.
base_key=$(cd "$TMP/src" && python3 scripts/ci/cmux_tui_tree_key.py --version v2 "$base")
# publish_tree_as <key> <publisher>: tree <key> published by <publisher>, with its manifest.
publish_tree_as() {
  mkdir -p "$TMP/cdn/tree/$1"
  printf '%s  cmux-tui-aarch64-apple-darwin\n' "$(sha_of bin)" > "$TMP/cdn/tree/$1/cmux-tui-aarch64-apple-darwin.sha256"
  printf '{"commit":"%s","key":"%s"}\n' "$2" "$1" > "$TMP/cdn/tree/$1/source.json"
  publish_manifest "$2"
}
gate_fallback() { # <installed> <installed key> -> status, took
  local started; started=$(date +%s); status=0
  (cd "$TMP/src" && env "${env_common[@]}" BUILD_SHA="$app" KEY="$key" INSTALLED="$1" INSTALLED_KEY="$2" \
    CMUX_TREE_MARKER_WAIT_SECONDS=300 bash scripts/ci/nightly-steps/await-tree-marker.sh >"$TMP/out" 2>&1) || status=$?
  took=$(( $(date +%s) - started ))
}
reset_cdn; publish_tree_as "$base_key" "$base"; gate_fallback "$base" "$base_key"
check '[[ $status == 0 && $took -lt 20 ]] && grep -q "fallback tree" "$TMP/out"' "a fallback tree published by the installed commit passes at once, with no build-commit marker"
reset_cdn; publish_tree_as "$base_key" "$own"; gate_fallback "$base" "$base_key"
check '[[ $status == 1 ]] && grep -q "installed the client of" "$TMP/out"' "a fallback tree published by another commit refuses"
reset_cdn; gate_fallback "$base" "$base_key"
check '[[ $status == 1 && $took -lt 20 ]] && grep -q "is not published" "$TMP/out"' "an unpublished fallback tree refuses"
reset_cdn; marker "$app" "$key" "$own"; gate_fallback "$own" "$key"
check '[[ $status == 0 ]]' "INSTALLED_KEY equal to the build's tree keeps the marker gate"

# The resolver's pending step.
pending() { # [VAR=value...] -> status, output file
  : > "$TMP/gh-output"; : > "$TMP/summary"; status=0
  (cd "$TMP/src" && env "${env_common[@]}" "$@" TIP_SHA="$app" GITHUB_OUTPUT="$TMP/gh-output" GITHUB_STEP_SUMMARY="$TMP/summary" \
    bash scripts/ci/nightly-steps/resolve-tree-pending.sh >/dev/null 2>&1) || status=$?
}
reset_cdn; pending
check '[[ $status == 0 ]] && grep -qx "tree_pending=true" "$TMP/gh-output" && grep -qx "candidates=$own $app" "$TMP/gh-output" && grep -qx "key=$key" "$TMP/gh-output"' \
  "an unpublished tip is built with its same-key candidates, oldest first"
check 'grep -qx "fallback=" "$TMP/gh-output"' "with no published tree in the history there is no fallback"
reset_cdn; publish_tree_as "$base_key" "$base"; pending
check '[[ $status == 0 ]] && grep -qx "tree_pending=true" "$TMP/gh-output" && grep -qx "fallback=$base $base_key" "$TMP/gh-output" && grep -q "fallback client" "$TMP/summary"' \
  "an unpublished tip names the newest published tree as its fallback"
# The newest published tree past the first look's window (base is 3 commits back; run 45097887921's was 87).
reset_cdn; publish_tree_as "$base_key" "$base"; pending CMUX_TUI_TREE_SEARCH_COMMITS=2
check '[[ $status == 0 ]] && grep -qx "fallback=$base $base_key" "$TMP/gh-output"' \
  "a published tree past the first look's window is still the fallback"
reset_cdn; publish_tree_as "$base_key" "$base"; pending CMUX_TUI_TREE_SEARCH_COMMITS=2 CMUX_TUI_TREE_FALLBACK_SEARCH_COMMITS=2
check '[[ $status == 0 ]] && grep -qx "fallback=" "$TMP/gh-output"' "past the wider look's window there is no fallback"
# The capability reader is not in this copy until here: could not tell keeps the fallback (above).
# With it, base's client lacks language-packs-v1, which the tip's app lists: run 44975559258
# (2026-11-22) failed 20 min in on exactly that. The fallback is dropped at resolve time instead.
cp "$ROOT/scripts/ci/nightly_fallback_covers.py" "$TMP/src/scripts/ci/"
# check-daemon-capabilities-fresh.py loads gen-daemon-capabilities.py since #57018 (base run 46008833629).
cp "$ROOT/scripts/cmux-next/check-app-capability-references.py" "$ROOT/scripts/cmux-next/check-daemon-capabilities-fresh.py" \
  "$ROOT/scripts/cmux-next/gen-daemon-capabilities.py" "$TMP/src/scripts/cmux-next/"
pending
check '[[ $status == 0 ]] && grep -qx "tree_pending=true" "$TMP/gh-output" && grep -qx "fallback=" "$TMP/gh-output" && grep -q "lacks .language-packs-v1." "$TMP/summary"' \
  "a fallback whose client lacks a capability the tip's app lists is dropped at resolve time"
reset_cdn; publish_tree "$own"; publish_manifest "$own"; pending
check '[[ $status == 0 ]] && grep -qx "tree_pending=false" "$TMP/gh-output"' "a published tip leaves it to the resolver"
reset_cdn; mkdir -p "$TMP/cdn/tree/$key"; echo garbage > "$TMP/cdn/tree/$key/cmux-tui-aarch64-apple-darwin.sha256"; pending
check '[[ $status == 0 ]] && grep -qx "tree_pending=false" "$TMP/gh-output"' "an unverifiable tree is not taken as pending"
# Nothing will publish the tip's tree (its publisher ended without it, no same-key run is active):
# the resolver picks the newest published tree instead of a build that fails 45 min in (2026-11-09).
ended_run="{\"total_count\":1,\"workflow_runs\":[{\"id\":3,\"status\":\"completed\",\"conclusion\":\"failure\",\"head_sha\":\"$own\",\"html_url\":\"u3\"}]}"
reset_cdn; set_runs "$no_runs"; jobs_file 3 "$preflight_failed"; printf '%s\n' "$ended_run" > "$runs_dir/runs-$own"; pending
check '[[ $status == 0 ]] && grep -qx "tree_pending=false" "$TMP/gh-output" && grep -q "nothing will publish" "$TMP/summary"' \
  "a tree whose publisher ended unpublished leaves it to the resolver"
building_jobs='{"jobs":[{"name":"cmux-tui tree preflight","status":"in_progress","runner_name":"linux-active"}]}'
own_run "$app" 30; jobs_file 30 "$building_jobs"; pending
check '[[ $status == 0 ]] && grep -qx "tree_pending=true" "$TMP/gh-output"' "a candidate's active run keeps the tip pending"
# A distinct same-tree commit is active; the failed candidate remains completed.
rm -f "$runs_dir/runs-$app"; own_run "$app_again" 31; jobs_file 31 "$building_jobs"
set_runs "{\"total_count\":1,\"workflow_runs\":[{\"id\":31,\"status\":\"in_progress\",\"head_sha\":\"$app_again\",\"head_branch\":\"feat-cmux-next\"}]}"; pending
check '[[ $status == 0 ]] && grep -qx "tree_pending=true" "$TMP/gh-output"' "an active same-key run keeps the tip pending"
rm -f "$runs_dir/runs-$own" "$runs_dir/runs-$app_again"; set_runs "$no_runs"
# The resolver reads the publisher's jobs the way await-tree-client.sh does (2026-11-18: owner
# 44223233076's build jobs sat queued 2 h with no runner; the nightly retries 44232805509 and
# 44235456054 each took the tip as pending, and 44235456054 waited the full 45 min on it).
# An active run that is not making progress publishes nothing in time: the resolver builds the
# newest published tree instead.
own_list() { set_runs "{\"total_count\":1,\"workflow_runs\":[{\"id\":$1,\"status\":\"in_progress\",\"head_sha\":\"$own\",\"head_branch\":\"feat-cmux-next\"}]}"; }
stalled_jobs() { printf '{"jobs":[{"name":"build / build x86_64-unknown-linux-musl","status":"queued","runner_name":null,"labels":["blacksmith-32vcpu-ubuntu-2404"],"created_at":"%s"}]}' "$(ago "$1")"; }
reset_cdn; own_run "$own" 11; own_list 11; jobs_file 11 "$(stalled_jobs 6000)"; pending
check '[[ $status == 0 ]] && grep -qx "tree_pending=false" "$TMP/gh-output" && grep -q "making progress" "$TMP/summary" && grep -q "blacksmith-32vcpu-ubuntu-2404" "$TMP/summary"' \
  "a tree whose only publisher has no runner past the stall bound leaves it to the resolver"
own_run "$own" 12 3; own_list 12; jobs_file 12 "$failed_jobs"; pending
check '[[ $status == 0 ]] && grep -qx "tree_pending=false" "$TMP/gh-output" && grep -q "failed build-linux" "$TMP/summary"' \
  "a tree whose only publisher failed on its last attempt leaves it to the resolver"
own_run "$own" 13; own_list 13; jobs_file 13 "$(stalled_jobs 0)"; pending
check '[[ $status == 0 ]] && grep -qx "tree_pending=true" "$TMP/gh-output"' "a publisher queued under the stall bound keeps the tip pending"
own_run "$own" 14 1; own_list 14; jobs_file 14 "$failed_jobs"; pending
check '[[ $status == 0 ]] && grep -qx "tree_pending=true" "$TMP/gh-output"' "a failed build a retry will re-run keeps the tip pending"
# Preflight is a required publisher stage on both resolver and wait surfaces.
own_run "$own" 16; own_list 16
jobs_file 16 '{"jobs":[{"name":"cmux-tui tree preflight","status":"queued","runner_name":null,"labels":["cmux-gcp-lane-build-x64"],"created_at":"'"$(ago 1000)"'"}]}'
pending
check '[[ $status == 0 ]] && grep -qx "tree_pending=false" "$TMP/gh-output" && grep -q "cmux-tui tree preflight queued" "$TMP/summary"' "a stalled preflight leaves the tip to the resolver with its state"
completed_run "$own" 17; set_runs "$no_runs"; jobs_file 17 "$preflight_failed"; pending
check '[[ $status == 0 ]] && grep -qx "tree_pending=false" "$TMP/gh-output" && grep -q "failed cmux-tui tree preflight" "$TMP/summary"' "a completed preflight failure leaves the tip to the resolver with its state"
own_run "$own" 17 2; pending
check '[[ $status == 0 ]] && grep -qx "tree_pending=true" "$TMP/gh-output"' "an active preflight retry keeps the tip pending"
# A stuck owner is passed over for a same-key run that builds: still pending.
own_run "$own" 11; jobs_file 11 "$(stalled_jobs 6000)"; own_run "$app" 15
set_runs "{\"total_count\":2,\"workflow_runs\":[{\"id\":11,\"status\":\"in_progress\",\"head_sha\":\"$own\",\"head_branch\":\"feat-cmux-next\"},{\"id\":15,\"status\":\"in_progress\",\"head_sha\":\"$app\",\"head_branch\":\"feat-cmux-next\"}]}"
jobs_file 15 "$building_jobs"; pending
check '[[ $status == 0 ]] && grep -qx "tree_pending=true" "$TMP/gh-output"' "a stuck owner passed over for a same-key run that builds keeps the tip pending"
rm -f "$runs_dir/runs-$own" "$runs_dir/runs-$app"; rm -rf "$TMP/api/repos/o/r/actions/runs"; set_runs "$no_runs"

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

# The bundle step's choice (app-bundle-cmux-tui-client.sh), with the installer and the wait stubbed:
# STUB_EXACT is what one look (WAIT_SECONDS=0) finds; STUB_WAIT_EXACT what a bounded wait (a set
# WAIT_SECONDS) finds; STUB_LATE_EXACT what only the unbounded default wait finds; STUB_INSTALL_FAIL a
# commit the installer refuses.
B="$TMP/bundle"; mkdir -p "$B/scripts/ci/nightly-steps" "$B/scripts/cmux-next" "$B/build-universal/Build/Products/Release/cmux.app"
cp "$ROOT/scripts/ci/nightly-steps/app-bundle-cmux-tui-client.sh" "$B/scripts/ci/nightly-steps/"
cat > "$B/scripts/cmux-next/await-tree-client.sh" <<'STUB'
#!/usr/bin/env bash
echo "await wait=${CMUX_TUI_TREE_CLIENT_WAIT_SECONDS:-default} $*" >> "$STUB_LOG"
w="${CMUX_TUI_TREE_CLIENT_WAIT_SECONDS:-default}"
if [[ "$w" == 0 ]]; then [[ -n "${STUB_EXACT:-}" ]] && { echo "$STUB_EXACT"; exit 0; }; exit 1; fi
found="${STUB_EXACT:-${STUB_WAIT_EXACT:-}}"
[[ "$w" == default && -z "$found" ]] && found="${STUB_LATE_EXACT:-}"
[[ -n "$found" ]] && { echo "$found"; exit 0; }; exit 1
STUB
cat > "$B/scripts/install-cmux-tui-client.sh" <<'STUB'
#!/usr/bin/env bash
while (( $# )); do [[ "$1" == --expected-commit ]] && c="$2"; shift; done
echo "install $c" >> "$STUB_LOG"; [[ "$c" != "${STUB_INSTALL_FAIL:-none}" ]]
STUB
printf '#!/usr/bin/env bash\necho "version $*" >> "$STUB_LOG"\n' > "$B/scripts/cmux-next/write-cmux-tui-version.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$B/scripts/strip-release-bundle.sh"
# STUB_CAPS_FAIL: a commit whose client lacks a capability the app needs (the last install is checked).
cat > "$B/scripts/cmux-next/check-daemon-capabilities.sh" <<'STUB'
#!/usr/bin/env bash
c=$(grep '^install ' "$STUB_LOG" | tail -1); echo "caps ${c#install }" >> "$STUB_LOG"; [[ "${c#install }" != "${STUB_CAPS_FAIL:-none}" ]]
STUB
chmod +x "$B/scripts/cmux-next/"*.sh "$B/scripts/"*.sh
bundle() { # [VAR=value...] -> status; outputs in $TMP/bundle-out, calls in $TMP/bundle-log
  : > "$TMP/bundle-out"; : > "$TMP/bundle-log"; status=0
  (cd "$B" && env -u STUB_EXACT RUNNER_TEMP="$TMP/rt" GITHUB_OUTPUT="$TMP/bundle-out" GITHUB_STEP_SUMMARY="$TMP/bundle-summary" \
    STUB_LOG="$TMP/bundle-log" CMUX_TUI_CLIENT_COMMIT="" CMUX_TUI_CLIENT_KEY="$key" CMUX_TUI_CLIENT_CACHE="$TMP/rt/cache" \
    TREE_PENDING=true TREE_CANDIDATES="$own $app" TREE_FALLBACK="$base $base_key" "$@" \
    bash scripts/ci/nightly-steps/app-bundle-cmux-tui-client.sh >"$TMP/bundle-stdout" 2>&1) || status=$?
}
bundle STUB_EXACT="$own"
check '[[ $status == 0 ]] && grep -qx "commit=$own" "$TMP/bundle-out" && grep -qx "key=$key" "$TMP/bundle-out" && grep -qx "tree=exact" "$TMP/bundle-out" && grep -q "^await wait=1500 " "$TMP/bundle-log" && ! grep -q "await wait=default" "$TMP/bundle-log"' \
  "the bundle installs the build commit's tree when it is already published"
bundle
check '[[ $status == 0 ]] && grep -qx "commit=$base" "$TMP/bundle-out" && grep -qx "key=$base_key" "$TMP/bundle-out" && grep -qx "tree=fallback" "$TMP/bundle-out" && grep -qx "version build-universal/Build/Products/Release/cmux.app $base $base_key" "$TMP/bundle-log" && grep -q "^await wait=1500 " "$TMP/bundle-log" && ! grep -q "await wait=default" "$TMP/bundle-log" && grep -q "bundling the newest published tree" "$TMP/bundle-stdout"' \
  "a tree still unpublished after the bounded wait bundles the fallback tree, and says which"
# Run 45825165164 (cec1e3c, 2026-11-26): the tip's tree published 24 min after the one look, and the
# NIGHTLY shipped a client 75 commits behind its app. A tree that publishes within the bounded wait ships.
bundle STUB_WAIT_EXACT="$app"
check '[[ $status == 0 ]] && grep -qx "commit=$app" "$TMP/bundle-out" && grep -qx "key=$key" "$TMP/bundle-out" && grep -qx "tree=exact" "$TMP/bundle-out" && ! grep -q "install $base" "$TMP/bundle-log"' \
  "a tree published within the bounded wait is bundled instead of the fallback (run 45825165164)"
bundle STUB_WAIT_EXACT="$app" CMUX_TUI_TREE_CLIENT_FALLBACK_WAIT_SECONDS=0
check '[[ $status == 0 ]] && grep -qx "tree=fallback" "$TMP/bundle-out" && grep -q "^await wait=0 " "$TMP/bundle-log"' \
  "CMUX_TUI_TREE_CLIENT_FALLBACK_WAIT_SECONDS=0 keeps the single look"
bundle CMUX_TUI_TREE_CLIENT_FALLBACK_WAIT_SECONDS=soon
check '[[ $status == 2 ]]' "a fallback wait that is not whole seconds is refused"
bundle TREE_FALLBACK="" STUB_WAIT_EXACT="$app"
check '[[ $status == 0 ]] && grep -qx "commit=$app" "$TMP/bundle-out" && grep -qx "tree=exact" "$TMP/bundle-out" && grep -q "await wait=default" "$TMP/bundle-log"' \
  "with no fallback tree the bundle waits for the build commit's tree as before"
bundle CMUX_TUI_TREE_CLIENT_FALLBACK=off STUB_WAIT_EXACT="$app"
check '[[ $status == 0 ]] && grep -qx "tree=exact" "$TMP/bundle-out" && ! grep -q "await wait=0 " "$TMP/bundle-log"' "CMUX_TUI_TREE_CLIENT_FALLBACK=off keeps the wait"
bundle STUB_LATE_EXACT="$app" STUB_INSTALL_FAIL="$base"
check '[[ $status == 0 ]] && grep -qx "commit=$app" "$TMP/bundle-out" && grep -qx "key=$key" "$TMP/bundle-out" && grep -qx "tree=exact" "$TMP/bundle-out" && grep -qx "install $base" "$TMP/bundle-log" && grep -qx "install $app" "$TMP/bundle-log"' \
  "a fallback tree the installer refuses falls back to waiting for the build commit's tree"
bundle STUB_LATE_EXACT="$app" STUB_CAPS_FAIL="$base"
check '[[ $status == 0 ]] && grep -qx "commit=$app" "$TMP/bundle-out" && grep -qx "tree=exact" "$TMP/bundle-out" && grep -qx "caps $base" "$TMP/bundle-log" && grep -qx "install $app" "$TMP/bundle-log" && grep -qx "caps $app" "$TMP/bundle-log"' \
  "a fallback tree missing a capability the app needs (run 44975559258) falls back to waiting for the build commit's tree"
bundle TREE_PENDING=false CMUX_TUI_CLIENT_COMMIT="$own"
check '[[ $status == 0 ]] && grep -qx "commit=$own" "$TMP/bundle-out" && grep -qx "tree=exact" "$TMP/bundle-out" && ! grep -q "^await" "$TMP/bundle-log"' "a resolved tree installs without any wait"

# A fallback stops only the pending client prefetch; other background helpers (webview-checks) live on.
state="$TMP/rt/nightly-helper-builds"; rm -rf "$state"
python3 "$ROOT/scripts/ci/background_build.py" start --state "$state" cmux-tui-client -- python3 -c "import time; time.sleep(300)" >/dev/null
python3 "$ROOT/scripts/ci/background_build.py" start --state "$state" webview-checks -- python3 -c "import time; time.sleep(300)" >/dev/null
cp "$ROOT/scripts/ci/background_build.py" "$B/scripts/ci/"
bundle
other=$(cat "$state/webview-checks.pid")
check '[[ $status == 0 ]] && grep -qx "tree=fallback" "$TMP/bundle-out" && kill -0 "$other" 2>/dev/null && grep -q "cmux-tui-client" "$TMP/bundle-stdout" && ! grep -q "to webview-checks" "$TMP/bundle-stdout"' \
  "a fallback stops only the client prefetch, not other helpers"
python3 "$ROOT/scripts/ci/background_build.py" stop --state "$state" >/dev/null

(( fail == 0 )) && echo "PASS: nightly tree at install" || { echo "FAIL: nightly tree at install"; exit 1; }
