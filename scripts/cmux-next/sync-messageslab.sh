#!/usr/bin/env bash
# Keeps Packages/Shared/CmuxMessagesLab's vendored MessagesLab files equal to
# a MessagesLab commit plus cmux's blocker patches (Patches/*.patch, one per
# edited file; every edit is also marked `cmux:` in the source).
#
#   sync-messageslab.sh <commit> [messageslab-dir]
#       Copies every file in vendor.tsv from <commit>, applies the patches
#       (fails on a patch that no longer applies), records the pin in
#       vendor.tsv and shows the diff against the previous pin's files.
#   sync-messageslab.sh --write-patches [messageslab-dir]
#       After editing a vendored file: rewrites Patches/ from the vendored
#       files against the pinned commit.
#   sync-messageslab.sh --check [messageslab-dir]
#       Fails unless every vendored file equals pin + its patch.
#
# messageslab-dir defaults to ~/fun/messageslab. Uncommitted MessagesLab work
# is never read (git show <commit>:path).
set -euo pipefail
repo="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
pkg="$repo/Packages/Shared/CmuxMessagesLab"
tsv="$pkg/vendor.tsv"
patches="$pkg/Patches"
mode=sync
case "${1:-}" in
  --write-patches) mode=write; shift ;;
  --check) mode=check; shift ;;
  ""|-h|--help) sed -n '2,19p' "$0"; exit 2 ;;
esac
if [[ "$mode" == sync ]]; then commit="$1"; shift; fi
ml="${1:-$HOME/fun/messageslab}"
pin="$(sed -n 's/^# MessagesLab commit \([0-9a-f]*\).*/\1/p' "$tsv")"
[[ "$mode" == sync ]] && commit="$(git -C "$ml" rev-parse --short "$commit")" || commit="$pin"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
name() { local n="${1#Sources/MessagesLabHome/}"; echo "${n#Vendor/}" | sed 's|/|__|g'; }
mkdir -p "$patches"
bad=0
while IFS=$'\t' read -r up local; do
  [[ -z "$up" || "$up" == \#* ]] && continue
  p="$patches/$(name "$local").patch"
  git -C "$ml" show "$commit:$up" > "$tmp/upstream"
  case "$mode" in
    write)
      if cmp -s "$tmp/upstream" "$pkg/$local"; then rm -f "$p"
      else diff -u --label "a/$local" --label "b/$local" "$tmp/upstream" "$pkg/$local" > "$p" || true; fi ;;
    check|sync)
      cp "$tmp/upstream" "$tmp/patched"
      if [[ -f "$p" ]] && ! patch -s --no-backup-if-mismatch -r - "$tmp/patched" < "$p" >/dev/null; then
        echo "patch no longer applies: $(basename "$p") (fix the file by hand, then --write-patches)"; bad=1; continue
      fi
      if [[ "$mode" == sync ]]; then cp "$tmp/patched" "$pkg/$local"
      elif ! cmp -s "$tmp/patched" "$pkg/$local"; then echo "differs from $pin + patch: $local"; bad=1; fi ;;
  esac
done < "$tsv"
if [[ "$mode" == sync && $bad == 0 ]]; then
  sed -i.bak "1s/^# MessagesLab commit [0-9a-f]*/# MessagesLab commit $commit/" "$tsv" && rm -f "$tsv.bak"
  echo "pinned MessagesLab $commit (was $pin)"
  git -C "$repo" diff --stat -- "$pkg/Sources" "$pkg/vendor.tsv"
fi
[[ "$mode" == write ]] && echo "wrote $(ls "$patches" | wc -l | tr -d ' ') patches against $pin"
[[ "$mode" == check && $bad == 0 ]] && echo "vendored files = MessagesLab $pin + $(ls "$patches" | wc -l | tr -d ' ') patches"
exit $bad
