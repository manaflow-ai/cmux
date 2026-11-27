#!/usr/bin/env bash
# check-generated-linux.sh compares a fresh export with the exports as they stand in the checkout, not as
# committed, and puts the checkout back as it found it. judge-action-exports.sh rechecks after it regenerates
# in place: a check against HEAD called those fresh exports stale, so a stale base read as a catalog failure
# (job 139650184065). A stand-in regenerate script writes the fresh export in place, as the real one does.
set -euo pipefail
# shellcheck source=scripts/cmux-next/tests/lib/git-fixture.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-fixture.sh"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp="$(mktemp -d)"
git_fixture_trap_exit 'rm -rf "$tmp"'
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
fail() { echo "FAIL: $*" >&2; exit 1; }
out=plans/cmux-next/action-catalog.json

# repo COMMITTED: a checkout whose committed export is COMMITTED; the fresh export is "fresh".
repo() {
  rm -rf "$tmp/r" && mkdir -p "$tmp/r/scripts/cmux-next" "$tmp/r/plans/cmux-next" && cd "$tmp/r"
  git init -q -b feat
  cp "$here/../check-generated-linux.sh" scripts/cmux-next/
  cat > scripts/cmux-next/regenerate-action-exports-linux.sh <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
echo fresh > plans/cmux-next/action-catalog.json
git diff --quiet -- plans/cmux-next/action-catalog.json || echo "regenerated: plans/cmux-next/action-catalog.json"
SH
  chmod +x scripts/cmux-next/*.sh
  echo "$1" > "$out"
  git add -A && git commit -q -m c
}
check() { bash scripts/cmux-next/check-generated-linux.sh 2>"$tmp/err"; }

# Committed fresh: passes, nothing changed.
repo fresh
check || fail "a fresh committed export failed: $(cat "$tmp/err")"
[[ "$(cat "$out")" == fresh ]] || fail "the check changed a fresh export"

# Committed stale: fails, names the file, and leaves the stale file in place.
repo stale
if check; then fail "a stale committed export passed"; fi
grep -qx "stale: $out" "$tmp/err" || fail "the stale export was not named: $(cat "$tmp/err")"
[[ "$(cat "$out")" == stale ]] || fail "the check did not put the stale export back"

# Committed stale, regenerated in the checkout (the judge's recheck): passes, and the fresh export stays.
repo stale
echo fresh > "$out"
check || fail "a regenerated checkout read as stale: $(cat "$tmp/err")"
[[ "$(cat "$out")" == fresh ]] || fail "the check put HEAD's stale export back over the regenerated one"

echo "check-generated-linux.test.sh: ok"
