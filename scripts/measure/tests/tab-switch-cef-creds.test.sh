#!/usr/bin/env bash
# tab-switch.sh checks the CMUX_CEF_R2_* read credentials before it builds: a build step on a Mac without them
# ran 7 to 13 minutes under the host lock and then failed fetching a pinned asset (cmux19, 2026-11-16). Here the
# script runs in a scratch repository with a mktemp stub that stops it right after the check, so each case
# takes well under a second: no credentials and a build fails with exit 3 and the TSW line; build=nightly
# never needs them; the environment, the HOME env file and the account's env file each pass, and the file
# found is exported for the build.
set -euo pipefail
# shellcheck source=scripts/cmux-next/tests/lib/git-fixture.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../cmux-next/tests/lib/git-fixture.sh"  # drops inherited GIT_DIR/GIT_CONFIG redirects; turns off background maintenance
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/../tab-switch.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/tab-switch-cef-creds.XXXXXX")"
git_fixture_trap_exit 'rm -rf -- "$tmp"'

repo="$tmp/repo"
mkdir -p "$repo/scripts/measure" "$tmp/bin" "$tmp/home" "$tmp/account/.secrets" "$tmp/empty"
cp "$script" "$repo/scripts/measure/tab-switch.sh"
git_fixture_init "$repo"
# Stops the script at its first mktemp (right after the check), saying which env file the build would read.
cat >"$tmp/bin/mktemp" <<'SH'
#!/usr/bin/env bash
echo "PAST_CHECK env_file=${CMUX_CEF_R2_ENV_FILE:-}" >&2
exit 97
SH
chmod +x "$tmp/bin/mktemp"
creds='CMUX_CEF_R2_ACCOUNT_ID=acct
CMUX_CEF_R2_ACCESS_KEY_ID="id"
export CMUX_CEF_R2_SECRET_ACCESS_KEY=secret'

fails=0
run() { # NAME EXPECT_EXIT EXPECT_TEXT [VAR=VALUE ...] -- ARGS...
  local name="$1" want="$2" text="$3" env_args=() out rc start
  shift 3
  while [[ $# -gt 0 && "$1" != -- ]]; do env_args+=("$1"); shift; done
  shift
  start=$SECONDS
  set +e
  out="$(cd "$repo" && env -i PATH="$tmp/bin:/usr/bin:/bin" HOME="$tmp/home" TSW_ACCOUNT_HOME="$tmp/empty" \
    ${env_args[@]+"${env_args[@]}"} bash scripts/measure/tab-switch.sh "$@" 2>&1)"
  rc=$?
  set -e
  if [[ "$rc" != "$want" || "$out" != *"$text"* || $((SECONDS - start)) -gt 5 ]]; then
    echo "FAIL $name: exit $rc (want $want), $((SECONDS - start)) s; output:"
    echo "$out" | head -n 20
    fails=$((fails + 1))
  else
    echo "ok   $name"
  fi
}

sha=0123456789abcdef0123456789abcdef01234567
run "no credentials, build=SHA fails before building" 3 "TSW no CMUX_CEF_R2_* read credentials" -- "build=$sha" rounds=1
run "no credentials, build=head fails before building" 3 "Not building" -- build=head
run "no credentials, --flag mode fails before building" 3 "TSW no CMUX_CEF_R2_* read credentials" -- --rounds=2
run "no credentials, no arguments fails before building" 3 "worker labeled cef-r2" --
run "build=nightly needs no credentials" 97 "PAST_CHECK" -- build=nightly
run "key=value without build= is nightly" 97 "PAST_CHECK" -- rounds=1
run "credentials in the environment" 97 "PAST_CHECK" CMUX_CEF_R2_ACCOUNT_ID=a CMUX_CEF_R2_ACCESS_KEY_ID=b \
  CMUX_CEF_R2_SECRET_ACCESS_KEY=c -- "build=$sha"
run "an endpoint stands in for the account" 97 "PAST_CHECK" CMUX_CEF_R2_ENDPOINT=https://r2.example \
  CMUX_CEF_R2_ACCESS_KEY_ID=b CMUX_CEF_R2_SECRET_ACCESS_KEY=c -- build=head
run "half the environment is not credentials" 3 "TSW no CMUX_CEF_R2_*" CMUX_CEF_R2_ACCESS_KEY_ID=b -- build=head

mkdir -p "$tmp/home/.secrets"
printf '%s\n' "$creds" >"$tmp/home/.secrets/cmux-cef.env"
run "the step HOME's env file passes and is exported" 97 "env_file=$tmp/home/.secrets/cmux-cef.env" -- build=head
rm "$tmp/home/.secrets/cmux-cef.env"

printf '%s\n' "$creds" >"$tmp/account/.secrets/cmux-cef.env"
run "the account's env file passes and is exported" 97 "env_file=$tmp/account/.secrets/cmux-cef.env" \
  TSW_ACCOUNT_HOME="$tmp/account" -- "build=$sha"
printf 'CMUX_CEF_R2_ACCOUNT_ID=acct\nCMUX_CEF_R2_ACCESS_KEY_ID=\nCMUX_CEF_R2_SECRET_ACCESS_KEY=s\n' \
  >"$tmp/account/.secrets/cmux-cef.env"
run "an env file with an empty key is not credentials" 3 "TSW no CMUX_CEF_R2_*" TSW_ACCOUNT_HOME="$tmp/account" -- build=head

printf '%s\n' "$creds" >"$tmp/named.env"
run "CMUX_CEF_R2_ENV_FILE is read first" 97 "env_file=$tmp/named.env" CMUX_CEF_R2_ENV_FILE="$tmp/named.env" -- build=head
run "a named file that does not exist falls through to none" 3 "$tmp/missing.env" \
  CMUX_CEF_R2_ENV_FILE="$tmp/missing.env" -- build=head

if ((fails)); then
  echo "tab-switch-cef-creds: $fails case(s) failed"
  exit 1
fi
echo "tab-switch-cef-creds: passed"
