#!/usr/bin/env bash
# Nightly idea ledger: rebuild the page from the latest merged script and put it in the ledger issue.
#
# Runs idea-ledger.py as it is on origin/feat-cmux-next (so a merged fix takes effect the next
# night), inside LEDGER_CHECKOUT so merge ancestry is answered by local git, not the API. Waits for
# the shared GraphQL quota (as glaeda-gh last saw it) instead of draining it, keeps each night's
# output under LEDGER_STATE/<date>, and replaces the body of LEDGER_ISSUE (OWNER/REPO#N) with the
# Markdown page. With LEDGER_ISSUE unset it only writes the files.
#
# Env: LEDGER_CHECKOUT (a manaflow-ai/cmux clone, default ~/Projects/cmux), LEDGER_STATE
# (default ~/.local/state/cmux-idea-ledger), LEDGER_ISSUE, LEDGER_CLUSTERS (curated clusters JSON),
# BEADS_SSH_HOST (read-only board access, as for bead-autoclose.py).
set -euo pipefail
checkout="${LEDGER_CHECKOUT:-$HOME/Projects/cmux}"
state="${LEDGER_STATE:-$HOME/.local/state/cmux-idea-ledger}"
night="$(date -u +%Y-%m-%d)"
out="$state/$night"
mkdir -p "$out"

git -C "$checkout" fetch --quiet origin feat-cmux-next nightly-next
git -C "$checkout" show origin/feat-cmux-next:scripts/cmux-next/idea-ledger.py > "$state/idea-ledger.py"

# The page costs a few hundred GraphQL points; wait for the reset rather than starve other sessions.
for _ in $(seq 1 90); do
  left="$(glaeda-gh budget --json 2>/dev/null | python3 -c 'import json,sys,time; g=json.load(sys.stdin)["budget"]["graphql"]; print(int(g["remaining"]) if g["reset"] > time.time() else 5000)' 2>/dev/null || echo 5000)"
  [ "${left%.*}" -ge 1500 ] && break
  sleep 60
done

args=(--out "$out")
[ -n "${LEDGER_CLUSTERS:-}" ] && args+=(--clusters "$LEDGER_CLUSTERS")
(cd "$checkout" && python3 "$state/idea-ledger.py" "${args[@]}")
ln -sfn "$out" "$state/latest"

if [ -n "${LEDGER_ISSUE:-}" ]; then
  repo="${LEDGER_ISSUE%#*}"
  number="${LEDGER_ISSUE#*#}"
  { echo "Rebuilt every night by \`scripts/cmux-next/idea-ledger-nightly.sh\` in manaflow-ai/cmux; edits here are overwritten."
    echo
    cat "$out/ledger.md"; } > "$out/issue-body.md"
  gh issue edit "$number" --repo "$repo" --body-file "$out/issue-body.md" > /dev/null
fi
