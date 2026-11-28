#!/usr/bin/env bash
# base-autofix-push-preflight.sh: a push GitHub's rulesets will refuse ends the run before any repair; anything the
# check can't read repairs as before. gh is a stub serving fixed rules and rulesets answers.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/../base-autofix-push-preflight.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

mkdir -p "$tmp/bin"
cat > "$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_STUB_LOG"
case "$2" in
  */rules/branches/*) [[ -n "${STUB_RULES_FAIL:-}" ]] && exit 1; printf '%s' "${STUB_RULE_IDS:-}" | tr ' ' '\n' ;;
  */rulesets/*) id="${2##*/}"; v="STUB_BYPASS_$id"; [[ "${!v-}" == FAIL ]] && exit 1; printf '%s\n' "${!v-}" ;;
esac
STUB
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH" GH_STUB_LOG="$tmp/gh.log" GITHUB_REPOSITORY=o/r GH_TOKEN=app
unset BASE_AUTOFIX_PUSH_PREFLIGHT STUB_RULES_FAIL STUB_RULE_IDS

expect() { # expect PUSH WHY_SUBSTRING
  local out; : > "$tmp/gh.log"; out="$(bash "$script" feat-cmux-next)"
  grep -qx "push=$1" <<<"$out" || fail "want push=$1 ($2): $out"
  grep -q "^why=.*$2" <<<"$out" || fail "want why naming '$2': $out"
}

# 1. No pull_request rule: the push lands.
STUB_RULE_IDS="" expect ok "no pull_request rule"
grep -q 'repos/o/r/rules/branches/feat-cmux-next' "$tmp/gh.log" || fail "read the wrong rules: $(cat "$tmp/gh.log")"

# 2. The 2026-11-27 case: ruleset 28260267 needs a PR and the App can't bypass it.
STUB_RULE_IDS="28260267" STUB_BYPASS_28260267=never expect refused "ruleset 28260267 (never)"
STUB_RULE_IDS="28260267" STUB_BYPASS_28260267=pull_requests_only expect refused "28260267 (pull_requests_only)"

# 3. The App on the bypass list: the push lands; one refusing ruleset among bypassed ones still refuses.
STUB_RULE_IDS="28260267" STUB_BYPASS_28260267=always expect ok "may bypass every"
STUB_RULE_IDS="28260267 28260267" STUB_BYPASS_28260267=exempt expect ok "may bypass every"
STUB_RULE_IDS="1 2" STUB_BYPASS_1=always STUB_BYPASS_2=never expect refused "ruleset 2 (never)"

# 4. Anything unread fails open.
STUB_RULES_FAIL=1 expect ok "could not read the rules"
STUB_RULE_IDS="7" STUB_BYPASS_7=FAIL expect ok "could not read ruleset 7"
STUB_RULE_IDS="7" STUB_BYPASS_7="" expect ok "no bypass answer"
GH_TOKEN="" STUB_RULE_IDS="7" STUB_BYPASS_7=never expect ok "no App token"

# 5. The revert switch: no API read at all.
BASE_AUTOFIX_PUSH_PREFLIGHT=0 STUB_RULE_IDS="7" STUB_BYPASS_7=never expect ok "preflight off"
[[ ! -s "$tmp/gh.log" ]] || fail "the switch still read the API: $(cat "$tmp/gh.log")"

echo "base-autofix-push-preflight: ok"
