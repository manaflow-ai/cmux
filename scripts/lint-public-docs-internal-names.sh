#!/usr/bin/env bash
# lint-public-docs-internal-names.sh
#
# Public Markdown names no internal ops detail: the cloud VM provider, whose
# account a service deploys in, account ids, team machine names and tailnet
# addresses, the private workspace repository or private credential files.
# That detail lives in the team's private ops notes next to the servers;
# public docs say "the VM provider", "the team Cloudflare account", "a team
# Mac".
#
# Two pattern sets, matched case-insensitively against tracked *.md files:
#   ALWAYS  matched anywhere on the line, code spans included
#   PROSE   matched outside inline code spans, link targets and fenced blocks,
#           so a doc can still name a real identifier (`CLOUD_..._SNAPSHOT`,
#           a file path) that the code carries
#
# A line containing `public-docs:allow` is skipped (reviewed exception).
#
#   scripts/lint-public-docs-internal-names.sh              every tracked *.md
#   scripts/lint-public-docs-internal-names.sh FILE...      only these files
#   scripts/lint-public-docs-internal-names.sh --self-test  the patterns catch
#                                                           and pass known lines
#
# Exit codes: 0 clean, 1 findings.
set -euo pipefail

HEX32='(^|[^0-9a-f])[0-9a-f]{32}([^0-9a-f]|$)'
ALWAYS="$HEX32.*(cloudflare|account)|(cloudflare|account).*$HEX32"
ALWAYS+='|cloudflare_account_id=[0-9a-f]'
ALWAYS+="|(lawrence|leo|austin|aziz)('s|s'|’s) (personal |own )?cloudflare"
ALWAYS+='|cloudflare account (of|owned by|belongs to) (lawrence|leo|austin|aziz)'
ALWAYS+='|cmuxterm-prod[.]env|freestyle[a-z0-9_.-]*[.](key|env)([^a-z]|$)'
ALWAYS+='|(^|[^a-z0-9-])(fs-lane-[a-z0-9]|gcp-codex-)'
ALWAYS+='|gcp lane vm'
# Tailnet DNS names and Tailscale (100.64.0.0/10) addresses of team machines.
ALWAYS+='|[.]tail[0-9a-f]+[.]ts[.]net'
ALWAYS+='|(^|[^0-9.])100[.](6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])[.][0-9]+[.][0-9]+([^/0-9]|$)'
# The VM provider, team machine names and the private workspace repository.
PROSE='(^|[^a-z0-9_-])(freestyle|huge[- ]blue|big[-]red|cmux-lawrence[a-z0-9-]*|cosmic-gray'
PROSE+='|mini-cmuxs-mac-mini[a-z0-9-]*|leo-workspace)([^a-z0-9_-]|$)'

# Print FILE:LINE: text for each finding in the given files.
scan() {
  awk -v always="$ALWAYS" -v prose="$PROSE" '
    FNR == 1 { fence = 0 }
    {
      raw = $0
      low = tolower(raw)
      # The made-up example tailnet of a settings field.
      gsub(/[.]tail1234[.]ts[.]net/, ".example.ts.net", low)
      if (low ~ /public-docs:allow/) next
      if (low ~ always) { print FILENAME ":" FNR ": " substr(raw, 1, 200); next }
      if (low ~ /^[[:space:]]*(```|~~~)/) { fence = !fence; next }
      if (fence) next
      gsub(/`[^`]*`/, "", low)
      gsub(/\]\([^)]*\)/, "]", low)
      if (low ~ prose) print FILENAME ":" FNR ": " substr(raw, 1, 200)
    }
  ' "$@"
}

if [ "${1:-}" = "--self-test" ]; then
  tmp=""
  trap '[ -z "$tmp" ] || rm -rf "$tmp"' EXIT
  tmp="$(mktemp -d)"
  # Each line must be found.
  cat > "$tmp/bad.md" <<'BAD'
Boots a Freestyle VM.
It deploys in Lawrence's Cloudflare account.
export CLOUDFLARE_ACCOUNT_ID=0123456789abcdef0123456789abcdef
Measured on cmux-lawrence-2.
Open https://mac.tail137216.ts.net:8080/ in the app.
Reach it at 100.120.48.119 over the tailnet.
Huge Blue answered first.
Credentials are in `~/.secrets/cmuxterm-prod.env`.
The dev key is `~/.secrets/freestyle-dev-20261004.key`.
See leo-workspace design/notes.md.
BAD
  # No line may be found.
  cat > "$tmp/good.md" <<'GOOD'
Boots a Cloud VM through the VM provider.
The flag is `CLOUD_FREESTYLE_SNAPSHOT`; read [the parity notes](plans/freestyle-parity.md).
Tailscale addresses are 100.64.0.0/10; a tailnet name ends in `.ts.net`, as in `mini.tail1234.ts.net`.
Commit 0123456789abcdef0123456789abcdef01234567 changed the parser.
```
freestyle vm list
```
Freestyle is listed for its license. public-docs:allow
GOOD
  want="$(wc -l < "$tmp/bad.md")"
  got="$(scan "$tmp/bad.md" | wc -l)"
  wrong="$(scan "$tmp/good.md")"
  if [ "$got" -ne "$want" ] || [ -n "$wrong" ]; then
    echo "self-test failed: $got of $want bad lines found" >&2
    scan "$tmp/bad.md" >&2 || true
    [ -z "$wrong" ] || printf 'good lines found:\n%s\n' "$wrong" >&2
    exit 1
  fi
  echo "self-test passed: $want bad lines found, no good line found"
  exit 0
fi

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

if [ "$#" -gt 0 ]; then
  files=("$@")
else
  # License notices name copyright holders verbatim.
  mapfile -t files < <(git ls-files -- '*.md' \
    ':!:THIRD_PARTY_LICENSES*' ':!:**/THIRD_PARTY_LICENSES*' ':!:cmux-tui/build-support/notices/**' \
    ':!:scripts/cmux-next/notices/hand-written.md')
fi
# A sparse checkout may lack some tracked files.
existing=()
for f in "${files[@]}"; do [ -f "$f" ] && existing+=("$f"); done
[ "${#existing[@]}" -gt 0 ] || exit 0

findings="$(scan "${existing[@]}")"
[ -z "$findings" ] && exit 0
printf '%s\n' "$findings"
cat >&2 <<'MSG'

Public docs name internal ops detail (VM provider, account owner or id, team
hosts, private credential files). Say it generically ("the VM provider", "the
team Cloudflare account", "a team Mac") and keep the specifics in the team's
private ops notes. A real code identifier may stay inside `backticks`.
MSG
exit 1
