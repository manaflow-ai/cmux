#!/usr/bin/env bash
# Make a Homebrew package available on a CI Mac, tolerating a Homebrew prefix
# the runner user does not own.
#
# `brew install` refuses outright when the prefix belongs to another account:
# "/opt/homebrew/Cellar is not writable". On an owned Mac that refusal ended an
# E2E job after the 17-minute build had already succeeded, and the job's own
# TEST_SUMMARY and TEST_OUTPUT came back empty, so the dispatch read as a test
# failure. Retry the install as the prefix owner, and when that is not possible
# fail with an annotation naming the runner and the package to provision.
#
# Every failure path prints a line machine_failure.py can classify, so a
# dispatcher retries the run and a bisect reads it as an error rather than
# blaming the commit for a test that never started.
set -uo pipefail

package="${1:?usage: brew-ensure.sh <package> [command]}"
command_name="${2:-$package}"

have() {
  hash -r 2>/dev/null || true
  command -v "$command_name" >/dev/null 2>&1
}

fail() {
  echo "::error::[cmux-ci machine: brew-provision] $command_name is missing on ${RUNNER_NAME:-this runner}: $1"
  exit 1
}

if have; then
  echo "$command_name already present: $(command -v "$command_name")"
  exit 0
fi

brew_bin="$(command -v brew || true)"
if [ -z "$brew_bin" ]; then
  fail "there is no brew on PATH; provision $package on that machine"
fi

HOMEBREW_NO_AUTO_UPDATE=1 "$brew_bin" install --quiet "$package"

if ! have; then
  prefix="$("$brew_bin" --prefix 2>/dev/null || echo /opt/homebrew)"
  owner="$(stat -f %Su "$prefix" 2>/dev/null || true)"
  if [ -z "$owner" ]; then
    fail "brew could not install it and the owner of $prefix is unreadable; provision $package on that machine"
  elif [ "$owner" = "$(id -un)" ]; then
    fail "brew could not install it into $prefix, which this user already owns; provision $package on that machine"
  elif [ "$owner" = "root" ]; then
    # Homebrew refuses to run as root, so there is no hop that fixes this one.
    fail "$prefix is owned by root and brew will not run as root; chown it to $(id -un) on that machine"
  elif sudo -n true 2>/dev/null; then
    echo "$prefix is owned by $owner, not $(id -un); retrying the install as $owner"
    sudo -n -H -u "$owner" /usr/bin/env HOMEBREW_NO_AUTO_UPDATE=1 \
      "$brew_bin" install --quiet "$package" || true
  else
    fail "$prefix is owned by $owner and passwordless sudo is unavailable to become them; provision $package on that machine"
  fi
fi

if ! have; then
  fail "Homebrew could not install it; provision $package on that machine"
fi

echo "$command_name: $(command -v "$command_name")"
