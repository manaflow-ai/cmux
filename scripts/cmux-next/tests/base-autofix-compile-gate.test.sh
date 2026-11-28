#!/usr/bin/env bash
# The compile gate's staging push (base-autofix-compile-gate.sh) tries again when the remote refuses it:
# run 46113326457 (2026-11-28) lost its verdict to one GitHub "workflow ... due to timeout" refusal.
# The remote is a local bare repo whose pre-receive hook refuses the first N pushes; gh is a stub that
# answers the dispatch and reports fleet/compile-check success.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/../base-autofix-compile-gate.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

mkdir -p "$tmp/bin"
cat > "$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$1" in api) echo success ;; esac
STUB
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH" GITHUB_REPOSITORY=o/r COMPILE_GATE_TOKEN=t
export CMUX_BASE_AUTOFIX_COMPILE_PUSH_DELAY=0 CMUX_BASE_AUTOFIX_COMPILE_POLL=0
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
unset CMUX_BASE_AUTOFIX_COMPILE_PUSH_ATTEMPTS

git init -q --bare "$tmp/remote.git"
cat > "$tmp/remote.git/hooks/pre-receive" <<'HOOK'
#!/usr/bin/env bash
n=$(( $(cat "$REFUSALS_LEFT") ))
if (( n > 0 )); then
  echo $((n - 1)) > "$REFUSALS_LEFT"
  echo "Unable to determine if workflow can be created or updated due to timeout" >&2
  exit 1
fi
HOOK
chmod +x "$tmp/remote.git/hooks/pre-receive"
git init -q "$tmp/work"
cd "$tmp/work"
git commit -q --allow-empty -m candidate
sha="$(git rev-parse HEAD)"
export REFUSALS_LEFT="$tmp/refusals"

# One refusal: the second attempt lands and the gate reaches a verdict.
echo 1 > "$REFUSALS_LEFT"
out="$("$script" "$tmp/remote.git" "$sha" 2>&1)" || fail "one refusal should still give a verdict: $out"
grep -q 'refused (attempt 1 of 3)' <<<"$out" || fail "the retry was not reported: $out"
grep -q "compiled" <<<"$out" || fail "no verdict after the retry: $out"

# Refused on every attempt: no verdict (exit 2) after 3 attempts.
echo 9 > "$REFUSALS_LEFT"
set +e; out="$("$script" "$tmp/remote.git" "$sha" 2>&1)"; rc=$?; set -e
[[ "$rc" == 2 ]] || fail "always refused should exit 2, got $rc: $out"
grep -q '(3 attempts); no verdict' <<<"$out" || fail "missing the attempts count: $out"
[[ "$(cat "$REFUSALS_LEFT")" == 6 ]] || fail "expected exactly 3 push attempts, $(cat "$REFUSALS_LEFT") refusals left"

echo "PASS base-autofix-compile-gate"
