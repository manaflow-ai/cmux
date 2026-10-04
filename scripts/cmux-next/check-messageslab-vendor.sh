#!/usr/bin/env bash
# Prints how the vendored MessagesLab files (Packages/Shared/CmuxMessagesLab)
# differ from upstream at the pinned commit: every difference must be one of
# the blocker edits (each is marked `cmux:` in the source). Needs a MessagesLab
# checkout (default ~/fun/messageslab).
#
# Usage: scripts/cmux-next/check-messageslab-vendor.sh [--stat] [messageslab-dir]
set -euo pipefail
stat=0
[[ "${1:-}" == "--stat" ]] && { stat=1; shift; }
repo="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
pkg="$repo/Packages/Shared/CmuxMessagesLab"
ml="${1:-$HOME/fun/messageslab}"
pin="$(sed -n 's/^# MessagesLab commit \([0-9a-f]*\).*/\1/p' "$pkg/vendor.tsv")"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
changed=0
while IFS=$'\t' read -r up local; do
  [[ -z "$up" || "$up" == \#* ]] && continue
  git -C "$ml" show "$pin:$up" > "$tmp/upstream"
  if ! cmp -s "$tmp/upstream" "$pkg/$local"; then
    changed=$((changed + 1))
    if (( stat )); then
      printf '%-60s %s\n' "$local" "$(diff "$tmp/upstream" "$pkg/$local" | grep -c '^[<>]') lines"
    else
      diff -u --label "upstream/$up" --label "$local" "$tmp/upstream" "$pkg/$local" || true
    fi
  fi
done < "$pkg/vendor.tsv"
echo "check-messageslab-vendor: $changed of $(grep -vc '^#' "$pkg/vendor.tsv") files carry cmux edits (pin $pin)" >&2
