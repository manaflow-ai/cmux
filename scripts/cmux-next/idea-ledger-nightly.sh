#!/usr/bin/env bash
# Nightly idea ledger: rebuild the page from the latest merged script and put it in the ledger issue.
#
# Runs idea-ledger.py as it is on origin/feat-cmux-next, or main with LEDGER_REF=main (so a
# merged fix takes effect the next night), inside LEDGER_CHECKOUT so merge ancestry is answered by local git, not
# the API. Waits for the shared GraphQL quota (as glaeda-gh last saw it) instead of draining it, keeps each night's
# output under LEDGER_STATE/<date>, and replaces the body of LEDGER_ISSUE (OWNER/REPO#N) with the
# Markdown page, only when that repo is private. With LEDGER_ISSUE unset it only writes the files.
#
# Env: LEDGER_CHECKOUT (a manaflow-ai/cmux clone, default ~/Projects/cmux), LEDGER_REF, LEDGER_STATE
# (default ~/.local/state/cmux-idea-ledger), LEDGER_ISSUE, LEDGER_CLUSTERS (curated clusters JSON),
# BEADS_SSH_HOST (read-only board access, as for bead-autoclose.py).
set -euo pipefail
checkout="${LEDGER_CHECKOUT:-$HOME/Projects/cmux}"
state="${LEDGER_STATE:-$HOME/.local/state/cmux-idea-ledger}"
night="$(date -u +%Y-%m-%d)"
out="$state/$night"
mkdir -p "$out"

# Only reviewed code runs here: the ledger script comes from a protected branch, never a PR branch.
ref="${LEDGER_REF:-feat-cmux-next}"
case "$ref" in
  feat-cmux-next|main) ;;
  *) echo "idea-ledger: LEDGER_REF must be feat-cmux-next or main, not $ref" >&2; exit 2 ;;
esac
git -C "$checkout" fetch --quiet origin "$ref" nightly-next
git -C "$checkout" show "origin/$ref:scripts/cmux-next/idea-ledger.py" > "$state/idea-ledger.py"

# The page costs a few hundred GraphQL points; wait for the reset rather than starve other sessions.
# If glaeda-gh can't say (not installed, daemon down), ask GitHub once per minute instead.
ready=""
for _ in $(seq 1 90); do
  left="$(glaeda-gh budget --json 2>/dev/null | python3 -c 'import json,sys,time; g=json.load(sys.stdin)["budget"]["graphql"]; print(int(g["remaining"]) if g["reset"] > time.time() else 5000)' 2>/dev/null \
    || gh api rate_limit --jq .resources.graphql.remaining 2>/dev/null || echo 0)"
  if [ "${left%.*}" -ge 1500 ]; then ready=1; break; fi
  sleep 60
done
if [ -z "$ready" ]; then
  echo "idea-ledger: GraphQL stayed under 1500 points for 90 minutes; skipping tonight" >&2
  exit 1
fi

args=(--out "$out")
[ -n "${LEDGER_CLUSTERS:-}" ] && args+=(--clusters "$LEDGER_CLUSTERS")
(cd "$checkout" && python3 "$state/idea-ledger.py" "${args[@]}")
ln -sfn "$out" "$state/latest"

if [ -n "${LEDGER_ISSUE:-}" ]; then
  repo="${LEDGER_ISSUE%#*}"
  number="${LEDGER_ISSUE#*#}"
  # The page carries board titles and assignees, which are private: never into a public repo.
  visibility="$(gh repo view "$repo" --json visibility --jq .visibility)"
  if [ "$visibility" != PRIVATE ] && [ "$visibility" != INTERNAL ]; then
    echo "idea-ledger: $repo is ${visibility:-unknown}, not private; the page stays in $out" >&2
    exit 2
  fi
  { echo "Rebuilt every night by \`scripts/cmux-next/idea-ledger-nightly.sh\` in manaflow-ai/cmux; edits here are overwritten."
    echo
    cat "$out/ledger.md"; } > "$out/issue-body.md"
  truncate -s '<65000' "$out/issue-body.md"  # GitHub refuses a body over 65,536 characters
  gh issue edit "$number" --repo "$repo" --body-file "$out/issue-body.md" > /dev/null
fi
