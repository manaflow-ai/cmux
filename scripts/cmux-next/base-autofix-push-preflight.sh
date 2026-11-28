#!/usr/bin/env bash
# Whether base autofix's push to BRANCH can land, read before any repair job starts (cmux-next-base-autofix.yml,
# push-preflight). Prints push=ok|refused and why=..., for $GITHUB_OUTPUT.
#
# 2026-11-27: ruleset 28260267 put a pull_request rule on feat-cmux-next with no bypass for the push App, so every run
# repaired for ~45 min (autofix 3,122 runner-min/day, Mac exports 1,208) and then had its push refused: 93 of 99 autofix
# runs and 78 of 79 Mac export runs red, with nothing new to fix. A run whose push GitHub will refuse now ends here.
#
# GH_TOKEN is the push App's installation token, so current_user_can_bypass answers for the App. Every ruleset with a
# pull_request rule on the branch must say "always" or "exempt" (a direct push may bypass it); "never" or
# "pull_requests_only" refuses the push. Anything unread (an API error, no field) fails open: push=ok, as before.
# BASE_AUTOFIX_PUSH_PREFLIGHT=0 (the repo variable CMUX_NEXT_BASE_AUTOFIX_PUSH_PREFLIGHT) turns the check off.
set -uo pipefail
branch="${1:?branch}"
repo="${GITHUB_REPOSITORY:?}"

ok() { echo "push=ok"; echo "why=$*"; exit 0; }

[[ "${BASE_AUTOFIX_PUSH_PREFLIGHT:-1}" == "0" ]] && ok "preflight off (CMUX_NEXT_BASE_AUTOFIX_PUSH_PREFLIGHT=0)"
[[ -n "${GH_TOKEN:-}" ]] || ok "no App token to read the rules with; repairing as before"

ids="$(gh api "repos/$repo/rules/branches/$branch" --paginate \
  --jq '.[] | select(.type == "pull_request") | .ruleset_id' 2>/dev/null)" \
  || ok "could not read the rules on $branch; repairing as before"
ids="$(sort -u <<<"$ids" | grep -E '^[0-9]+$' || true)"
[[ -n "$ids" ]] || ok "no pull_request rule on $branch"

refused=()
for id in $ids; do
  can="$(gh api "repos/$repo/rulesets/$id" --jq '.current_user_can_bypass // ""' 2>/dev/null)" \
    || ok "could not read ruleset $id; repairing as before"
  case "$can" in
    always|exempt) ;;
    never|pull_requests_only) refused+=("$id ($can)") ;;
    *) ok "ruleset $id gave no bypass answer; repairing as before" ;;
  esac
done
[[ ${#refused[@]} -eq 0 ]] && ok "the push App may bypass every pull_request rule on $branch"
echo "push=refused"
echo "why=ruleset ${refused[*]} requires a pull request on $branch and the push App (CMUX_PR_AUTOFIX_APP) has no bypass; a repo admin adds the App to the ruleset's bypass list, or sets CMUX_NEXT_BASE_AUTOFIX_PUSH_PREFLIGHT=0"
