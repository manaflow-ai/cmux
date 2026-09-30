#!/usr/bin/env bash
# Make a Homebrew package available on a CI Mac, tolerating a Homebrew prefix
# the runner user does not own.
#
# `brew install` refuses outright when the prefix belongs to another account:
# "/opt/homebrew/Cellar is not writable". On an owned Mac that refusal ended
# the E2E job after the 17-minute build had already succeeded, and the job's
# own TEST_SUMMARY and TEST_OUTPUT came back empty, so nothing named the
# cause short of reading the raw log. Retry the install as the prefix owner,
# and when that is not possible fail with the runner name and the package to
# provision.
set -uo pipefail

package="${1:?usage: brew-ensure.sh <package> [command]}"
command_name="${2:-$package}"

have() {
  hash -r 2>/dev/null || true
  command -v "$command_name" >/dev/null 2>&1
}

if have; then
  echo "$command_name already present: $(command -v "$command_name")"
  exit 0
fi

brew_bin="$(command -v brew || true)"
if [ -z "$brew_bin" ]; then
  echo "::error::$command_name is missing on ${RUNNER_NAME:-this runner} and there is no brew on PATH; provision $package on that machine"
  exit 1
fi

HOMEBREW_NO_AUTO_UPDATE=1 "$brew_bin" install --quiet "$package"

if ! have; then
  prefix="$("$brew_bin" --prefix 2>/dev/null || echo /opt/homebrew)"
  owner="$(stat -f %Su "$prefix" 2>/dev/null || true)"
  if [ -n "$owner" ] && [ "$owner" != "$(id -un)" ]; then
    echo "$prefix is owned by $owner, not $(id -un); retrying the install as $owner"
    sudo -H -u "$owner" "$brew_bin" install --quiet "$package" || true
  fi
fi

if ! have; then
  echo "::error::$command_name is missing on ${RUNNER_NAME:-this runner} and Homebrew could not install it; provision $package on that machine"
  exit 1
fi

echo "$command_name: $(command -v "$command_name")"
