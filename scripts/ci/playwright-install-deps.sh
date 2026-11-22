#!/usr/bin/env bash
# Install Playwright browsers with their system packages, and repair the runner's apt state once when that
# state, not the change under test, is what fails.
#
# The owned Linux runners are reused across refs. A job cut off mid-`apt-get install` leaves dpkg half
# configured, and every later job on that runner fails `playwright install --with-deps` with "E: Unmet
# dependencies" (job 137055727451, 2026-11-22: a pull request's "Install headless engines" went red, which
# skipped its "Test webviews" while its own change was fine). That is one ref's leftover charged to the next
# ref, so on an apt or dpkg failure this finishes the interrupted configure, fixes broken dependencies,
# refreshes the index and tries once more. Any other failure, or a second apt failure, stays red.
#
# Usage: playwright-install-deps.sh BROWSER... (run where `./node_modules/.bin/playwright` resolves, or set
# PLAYWRIGHT_CLI, e.g. "bunx --no-install playwright").
set -uo pipefail

cli="${PLAYWRIGHT_CLI:-./node_modules/.bin/playwright}"
log="$(mktemp)"
trap 'rm -f "$log"' EXIT

install() {
  # shellcheck disable=SC2086
  $cli install --with-deps "$@" 2>&1 | tee "$log"
}

if install "$@"; then exit 0; fi

apt_broken='Unmet dependencies|dpkg was interrupted|E: Sub-process /usr/bin/dpkg|Could not get lock|Unable to acquire the dpkg frontend lock|Hash Sum mismatch|Hashes of received file|Failed to fetch'
if ! grep -qE "$apt_broken" "$log"; then
  echo "error: playwright install --with-deps $* failed, not on apt state" >&2
  exit 1
fi

if [ "$(id -u)" = 0 ]; then
  as_root=()
elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
  as_root=(sudo -n)
else
  echo "error: apt state is broken and $(id -un) has no passwordless sudo to repair it" >&2
  exit 1
fi

echo "warning: apt or dpkg state on this runner is broken (left by an earlier job); repairing and trying once more" >&2
export DEBIAN_FRONTEND=noninteractive
# A lock held by an unattended upgrade clears on its own; wait for it rather than racing it.
"${as_root[@]}" timeout 300 bash -c 'while fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock >/dev/null 2>&1; do sleep 5; done' || true
"${as_root[@]}" dpkg --configure -a || true
"${as_root[@]}" apt-get -f install -y || true
"${as_root[@]}" apt-get update || true

if install "$@"; then exit 0; fi
echo "error: playwright install --with-deps $* failed again after the apt repair" >&2
exit 1
