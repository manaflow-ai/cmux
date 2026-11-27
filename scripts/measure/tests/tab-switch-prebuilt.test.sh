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
echo 'tab-switch-prebuilt: passed'
