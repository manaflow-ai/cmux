#!/usr/bin/env bash
# Run the CI guard suite (ci-guards.yml) locally in about a minute, no build.
#
#   scripts/ci/guards-local.sh               every guard group; stamps HEAD on a clean pass
#   scripts/ci/guards-local.sh --group ci    one group (no stamp)
#   scripts/ci/guards-local.sh --list        show the plan
#
# The "CI fast guards" check runs this same script. A clean full pass writes
# ${XDG_CACHE_HOME:-~/.cache}/cmux-guards/pass/<HEAD sha>, which the agent
# merge guard accepts for `gh pr merge --admin` on that head.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cache="${XDG_CACHE_HOME:-$HOME/.cache}/cmux-guards"
packages=(PyYAML==6.0.3 bashlex==0.18)
venv="${CMUX_GUARDS_VENV:-$cache/venv-$(printf '%s ' "${packages[@]}" | shasum | cut -c1-12)}"

if [[ ! -x "$venv/bin/python3" ]]; then
  python3 -m venv "$venv"
  "$venv/bin/python3" -m pip install --quiet --disable-pip-version-check --no-input "${packages[@]}"
fi

export PATH="$venv/bin:$PATH"
exec python3 "$root/scripts/ci/run_ci_guards.py" "$@"
