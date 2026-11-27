#!/usr/bin/env bash
# A downloaded tagged bundle skips app build and CEF credentials. Never launches an app.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../cmux-next/tests/lib/git-fixture.sh"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/tab-switch-prebuilt.XXXXXX")"
git_fixture_trap_exit 'rm -rf -- "$tmp"'
repo="$tmp/repo"
app="$tmp/cmux DEV tab rerender.app"
sha=0123456789abcdef0123456789abcdef01234567
mkdir -p "$repo/scripts/measure" "$tmp/bin" "$tmp/home" "$app/Contents/MacOS"
cp "$here/../tab-switch.sh" "$repo/scripts/measure/tab-switch.sh"
git_fixture_init "$repo"
python3 - "$app" "$sha" <<'PY'
import pathlib, plistlib, sys
app = pathlib.Path(sys.argv[1])
with (app / 'Contents/Info.plist').open('wb') as handle:
    plistlib.dump({'CFBundleIdentifier': 'com.cmuxterm.app.debug.tab-rerender-865',
                  'CFBundleExecutable': 'cmux', 'CMUXCommit': sys.argv[2],
                  'CMUXCommitDirty': False}, handle)
(app / 'Contents/MacOS/cmux').write_text('#!/bin/sh\necho APP_MUST_NOT_LAUNCH >&2\nexit 98\n')
(app / 'Contents/MacOS/cmux').chmod(0o755)
PY
# Stop frames_main immediately after selection, before any preflight, tools compile or app launch.
cat > "$tmp/bin/mktemp" <<'SH'
#!/usr/bin/env bash
echo PAST_PREBUILT_SELECTION >&2
exit 97
SH
chmod +x "$tmp/bin/mktemp"

(
  cd "$repo"
  source scripts/measure/tab-switch.sh
  require_cef_read_credentials() { echo UNEXPECTED_CREDENTIAL_CHECK >&2; exit 91; }
  require_submodule_refs() { echo UNEXPECTED_SUBMODULE_FETCH >&2; exit 91; }
  tsw_build_app() { echo UNEXPECTED_APP_BUILD >&2; exit 91; }
  tsw_step() { echo UNEXPECTED_BUILD_STEP >&2; exit 91; }
  curl() { echo UNEXPECTED_DOWNLOAD >&2; exit 91; }
  app_under_test "$sha" bench "" "$tmp/unused" "$repo" tabswitch TSW "$app"
  [[ ${#APP_ARGS[@]} == 2 && ${APP_ARGS[0]} == --app && ${APP_ARGS[1]} == "$app" ]]
  [[ "$APP_LABEL" == "prebuilt $sha" ]]
)
echo 'ok   prebuilt selection preserves spaced path and actual commit without building'

check() { # NAME EXIT TEXT ARGS...
  local name="$1" want="$2" text="$3" out rc
  shift 3
  set +e
  out="$(cd "$repo" && env -i PATH="$tmp/bin:$PATH" HOME="$tmp/home" TSW_ACCOUNT_HOME="$tmp/home" \
    bash scripts/measure/tab-switch.sh "$@" 2>&1)"
  rc=$?
  set -e
  if [[ "$rc" != "$want" || "$out" != *"$text"* || "$out" == *APP_MUST_NOT_LAUNCH* ]]; then
    echo "FAIL $name: exit $rc, expected $want; $out" >&2
    exit 1
  fi
  echo "ok   $name"
}
check 'app= first enters frame mode without credentials' 97 PAST_PREBUILT_SELECTION "app=$app" "build=$sha"
check 'app= defaults report bundle commit without feed download' 97 "TSW prebuilt $sha" "app=$app"
check 'wrong exact build cannot fall back to native build' 3 'does not match build=' "app=$app" build=ffffffffffffffffffffffffffffffffffffffff
check 'missing app cannot fall back to native build' 3 'prebuilt app does not exist' "app=$tmp/missing.app" "build=$sha"
check 'empty app is invalid rather than a build request' 2 'app= takes a bundle path' app= "build=$sha"
check 'app and DMG cannot silently select different inputs' 3 'mutually exclusive' "app=$app" dmg=https://example.invalid/app.dmg
chmod -x "$app/Contents/MacOS/cmux"
check 'missing executable fails before platform work' 3 'executable is missing' "app=$app"
chmod +x "$app/Contents/MacOS/cmux"
python3 - "$app/Contents/Info.plist" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'rb') as handle:
    info = plistlib.load(handle)
info['CFBundleIdentifier'] = 'com.cmuxterm.app'
with open(sys.argv[1], 'wb') as handle:
    plistlib.dump(info, handle)
PY
check 'person bundle is not accepted as a dedicated test tag' 3 'dedicated tagged DEV bundle' "app=$app"
# Managed jobs never select a feed or compile path, including malformed and failed receipts.
job=0123456789abcdef01234567
check 'artifact job needs full ID' 2 'full job ID' artifact-job=short "build=$sha"
check 'artifact job needs explicit exact head' 2 'requires build=<full SHA>' "artifact-job=$job"
check 'artifact and local app are exclusive' 2 'excludes app=/dmg=' "artifact-job=$job" "build=$sha" "app=$app"
check 'artifact and DMG are exclusive' 2 'excludes app=/dmg=' "artifact-job=$job" "build=$sha" dmg=https://example.invalid/app.dmg
check 'managed selection skips credentials' 97 PAST_PREBUILT_SELECTION "artifact-job=$job" "build=$sha"

cat > "$tmp/bin/cmux-ci" <<'PY_CI'
#!/usr/bin/env python3
import hashlib, json, os, pathlib, sys
mode = os.environ['ARTIFACT_CASE']
with open(os.environ['ARTIFACT_CALLS'], 'a') as log:
    log.write(sys.argv[1] + '\n')
if sys.argv[1] == 'status':
    row = dict(id=sys.argv[2], kind='cmux', state='done', ref=os.environ['ARTIFACT_SHA'],
               artifact='sha256:' + hashlib.sha256(b'managed app zip').hexdigest())
    if mode in ('queued', 'running', 'failed', 'cancelled'):
        row['state'] = mode
    if mode == 'wrong-job': row['id'] = '0' * 24
    if mode == 'wrong-kind': row['kind'] = 'ci-step'
    if mode == 'wrong-ref': row['ref'] = 'f' * 40
    if mode == 'no-artifact': row.pop('artifact')
    print(json.dumps(row))
elif sys.argv[1] == 'artifact':
    if mode == 'download-failed': sys.exit(19)
    pathlib.Path(sys.argv[3]).write_bytes(b'wrong bytes' if mode == 'wrong-digest' else b'managed app zip')
else:
    sys.exit('unexpected cmux-ci call')
PY_CI
cat > "$tmp/bin/ditto" <<'PY_DITTO'
#!/usr/bin/env python3
import os, pathlib, plistlib, shutil, sys
mode = os.environ['ARTIFACT_CASE']
dest = pathlib.Path(sys.argv[-1])
if mode == 'extract-failed': sys.exit(18)
if mode == 'no-app': sys.exit(0)
app = dest / 'cmux DEV artifact.app'
shutil.copytree(os.environ['ARTIFACT_APP_FIXTURE'], app)
with (app / 'Contents/Info.plist').open('rb') as handle: info = plistlib.load(handle)
info['CFBundleIdentifier'] = 'com.cmuxterm.app.debug.test'
if mode == 'dirty': info['CMUXCommitDirty'] = True
if mode == 'wrong-app-head': info['CMUXCommit'] = 'e' * 40
if mode == 'nightly': info['CFBundleIdentifier'] = 'com.cmuxterm.app'
with (app / 'Contents/Info.plist').open('wb') as handle: plistlib.dump(info, handle)
if mode == 'two-apps': shutil.copytree(app, dest / 'second.app')
PY_DITTO
chmod +x "$tmp/bin/cmux-ci" "$tmp/bin/ditto"
artifact_check() {
  local mode="$1" want="$2" message="$3" expected_calls="$4" got rc
  : > "$tmp/artifact-calls"
  set +e
  got="$(
    exec 2>&1
    cd "$repo"
    export PATH="$tmp/bin:$PATH" ARTIFACT_CASE="$mode" ARTIFACT_SHA="$sha"
    export ARTIFACT_CALLS="$tmp/artifact-calls" ARTIFACT_APP_FIXTURE="$app" ARTIFACT_TEST_ROOT="$tmp"
    source scripts/measure/tab-switch.sh
    # The real temporary directory is owned by this runner and its EXIT trap.
    mktemp() { command /usr/bin/mktemp -d "$ARTIFACT_TEST_ROOT/managed.XXXXXX"; }
    # Stop after provenance validation, before any platform probes, preflight or launch.
    chmod() { if [[ "$1" == 0755 ]]; then echo PAST_ARTIFACT_SELECTION; exit 97; fi; command chmod "$@"; }
    require_cef_read_credentials() { echo UNEXPECTED_CREDENTIAL_CHECK; exit 91; }
    tsw_build_app() { echo UNEXPECTED_APP_BUILD; exit 91; }
    frames_main "artifact-job=$job" "build=$sha" load=idle
  )"
  rc=$?
  set -e
  [[ "$rc" == "$want" && "$got" == *"$message"* ]] || { echo "FAIL artifact $mode: $rc: $got"; exit 1; }
  [[ "$(tr '\n' ',' < "$tmp/artifact-calls")" == "$expected_calls" ]] || { echo "FAIL unexpected artifact calls: $mode"; exit 1; }
  [[ -z "$(command /usr/bin/find "$tmp" -maxdepth 1 -name 'managed.*' -print)" ]] || { echo "FAIL owned temp leaked: $mode"; exit 1; }
  echo "ok   managed artifact $mode; owned temp cleaned"
}
artifact_check success 97 PAST_ARTIFACT_SELECTION status,artifact,
for state in queued running failed cancelled wrong-job wrong-kind wrong-ref; do
  artifact_check "$state" 3 'completed cmux build' status,
done
artifact_check no-artifact 3 'no SHA256 app artifact' status,
artifact_check download-failed 3 'non-zero exit status 19' status,artifact,
artifact_check wrong-digest 3 'does not match the build receipt' status,artifact,
artifact_check extract-failed 3 'non-zero exit status 18' status,artifact,
artifact_check no-app 3 'exactly one app bundle' status,artifact,
artifact_check two-apps 3 'exactly one app bundle' status,artifact,
artifact_check dirty 3 'clean full CMUXCommit' status,artifact,
artifact_check wrong-app-head 3 'does not match build=' status,artifact,
artifact_check nightly 3 'dedicated tagged DEV bundle' status,artifact,
echo 'tab-switch-prebuilt: passed'
