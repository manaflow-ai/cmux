#!/usr/bin/env bash
# publish-bot-head-tree.sh: a branch head that github-actions[bot] pushed with no
# cmux-tui artifacts run gets one dispatch; a person's head, a bot head with a
# run, and an unreadable API dispatch nothing, and nothing fails the caller.
# No network: `gh` is a stub that answers from files and records dispatches.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "api repos/o/r/commits/feat-cmux-next") [[ -f "$STUB/head" ]] || exit 1; cat "$STUB/head" ;;
  "api repos/o/r/actions/workflows/cmux-tui-artifacts.yml/runs?"*) [[ -f "$STUB/runs" ]] || exit 1; cat "$STUB/runs" ;;
  "workflow run") echo "$*" >> "$STUB/dispatched"; [[ ! -f "$STUB/refuse" ]] ;;
  *) echo "unexpected gh $*" >&2; exit 2 ;;
esac
EOF
chmod +x "$TMP/bin/gh"
sha=0123456789abcdef0123456789abcdef01234567

# case <name> <head reply or -> <runs reply or -> [refuse] -> sets out, status, dispatched
case_() {
  local stub="$TMP/$1"; mkdir -p "$stub"
  [[ "$2" == - ]] || printf '%s\n' "$2" > "$stub/head"
  [[ "$3" == - ]] || printf '%s\n' "$3" > "$stub/runs"
  [[ "${4:-}" == refuse ]] && touch "$stub/refuse"
  status=0
  out=$(PATH="$TMP/bin:$PATH" STUB="$stub" GITHUB_REPOSITORY=o/r bash "$ROOT/scripts/cmux-next/publish-bot-head-tree.sh" 2>&1) || status=$?
  dispatched=$(cat "$stub/dispatched" 2>/dev/null || true)
}
fail() { printf '%s (exit %s):\n%s\ndispatched: %s\n' "$1" "$status" "$out" "$dispatched" >&2; exit 1; }

case_ bot "$sha github-actions[bot]" 0
[[ "$status" == 0 && "$dispatched" == "workflow run cmux-tui-artifacts.yml --repo o/r --ref feat-cmux-next" ]] \
  || fail "a bot head with no run gets one dispatch"
grep -q "Dispatched cmux-tui-artifacts.yml on feat-cmux-next" <<<"$out" || fail "the dispatch is reported"

case_ person "$sha leo" 0
[[ "$status" == 0 && -z "$dispatched" ]] || fail "a person's head (its push has a run) dispatches nothing"

case_ has-run "$sha github-actions[bot]" 1
[[ "$status" == 0 && -z "$dispatched" ]] || fail "a bot head that has a run dispatches nothing"

case_ no-api - -
[[ "$status" == 0 && -z "$dispatched" ]] || fail "an unreadable head dispatches nothing and does not fail"
grep -q "^warning: cannot read the feat-cmux-next head" <<<"$out" || fail "an unreadable head is a warning"

case_ no-runs "$sha github-actions[bot]" -
[[ "$status" == 0 && -z "$dispatched" ]] || fail "unreadable runs dispatch nothing and do not fail"

case_ refused "$sha github-actions[bot]" 0 refuse
[[ "$status" == 0 && -n "$dispatched" ]] || fail "a refused dispatch does not fail the caller"
grep -q "needs actions: write" <<<"$out" || fail "a refused dispatch names the permission"

echo "publish-bot-head-tree: ok"
