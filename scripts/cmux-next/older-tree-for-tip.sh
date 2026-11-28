#!/usr/bin/env bash
# The checkout's (HEAD's) app with an older published cmux-tui tree. Leo, 2026-11-26: "man the tui thing is
# always so flakey / cant we just accept the nightly using an older tui version". When HEAD's own v2 tree is a
# confirmed 404 (pin-cmux-tui.sh verify-key exit 1), this finds the newest published, manifest-verified tree
# within CMUX_TUI_TREE_MAX_AGE_HOURS (24) and CMUX_TUI_TREE_TIP_SEARCH_COMMITS (400) commits whose
# plans/cmux-next/daemon-capabilities.json is HEAD's (the bundle checks the daemon serves every capability
# listed there), the pairing cmux-next-media.yml already uses for an unpublished base. Never waits, writes no
# summary, starts no publisher.
# Two callers ask the same question: nightly.yml's resolver (scripts/ci/resolve-cmux-tui-client-commit.sh in
# nightly-steps) builds HEAD's app and bundles that tree's client by key, and request-nightly-next.sh promotes a
# commit on the same answer, so promotion never stalls on the tui publisher (2026-11-25: none published from
# about 21:24Z; 108 commits refused in one night).
# Prints commit= (the tree's publishing commit), key=, source_commit= (HEAD: the build commit), tip_key=
# (HEAD's own tree), behind=0, behind_hours=0, and tree_from="<commit whose tree it is> <commits> <hours>"
# (how far behind HEAD that tree's commit is).
# Exit 0 found; 3 HEAD's own tree is published (or a compatibility key of it): use it; 1 none, or unknown.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
tip="$(git rev-parse HEAD)"
tip_key="$(python3 "$root/scripts/ci/cmux_tui_tree_key.py" --version v2 HEAD 2>/dev/null)" \
  || { echo "older-tree: no tree key for ${tip:0:12}" >&2; exit 1; }
rc=0
env -u CMUX_TUI_TREE_KEY bash "$here/pin-cmux-tui.sh" verify-key "$tip_key" >/dev/null 2>&1 || rc=$?
if (( rc == 0 )); then echo "older-tree: the tree $tip_key of ${tip:0:12} is published" >&2; exit 3; fi
(( rc == 1 )) || { echo "older-tree: could not tell whether tree $tip_key of ${tip:0:12} is published (verify-key exit $rc)" >&2; exit 1; }
out="$(env -u GITHUB_OUTPUT -u GITHUB_STEP_SUMMARY -u CMUX_TUI_TREE_KEY CMUX_TUI_TREE_DISPATCH='' CMUX_TUI_TREE_TIP_WAIT_SECONDS=0 \
  CMUX_TUI_TREE_SAME_PATHS=plans/cmux-next/daemon-capabilities.json \
  CMUX_TUI_TREE_SEARCH_COMMITS="${CMUX_TUI_TREE_TIP_SEARCH_COMMITS:-400}" \
  CMUX_TUI_TREE_MAX_AGE_HOURS="${CMUX_TUI_TREE_MAX_AGE_HOURS:-24}" \
  bash "$here/pin-cmux-tui.sh" resolve-newest-published </dev/null)" || out=""
# The window counts commits, not hours: at about 60 merges an hour its 400 commits are under 7 h, so a tree
# 7-24 h back is never seen. NIGHTLY sat at 1708b0ea from 2026-11-28 13:47Z while c6cd14b5's tree (ac0dea4e:
# published, verified, the tip's daemon-capabilities.json, 12.5 h back) was 831 commits behind the tip. The
# signed Linux pointer (channels/linux-feat-cmux-next.json, scripts/ci/linux-release-sign.sh) names the newest
# signed tree's commit in one read; it is taken under the same age, history, capabilities and verify checks.
signed_pointer_tree() {
  local dir commit key rev_time tip_time behind hours
  dir="$(mktemp -d)"; trap 'rm -rf "$dir"' RETURN
  curl -fsS -m 20 "https://files.cmux.com/cmux-tui/channels/linux-feat-cmux-next.json?t=$(date +%s)" -o "$dir/p.json" 2>/dev/null || return 1
  read -r commit < <(python3 -c 'import base64,json,sys; d=json.load(open(sys.argv[1])); print(json.loads(base64.b64decode(d["payload"])).get("commit") or "-")' "$dir/p.json" 2>/dev/null) || return 1
  [[ "$commit" =~ ^[0-9a-f]{40}$ ]] || return 1
  git cat-file -e "$commit^{commit}" 2>/dev/null || git fetch --no-recurse-submodules -q --no-tags --depth=1 origin "$commit" 2>/dev/null || return 1
  if [[ "$(git rev-parse --is-shallow-repository)" != true ]]; then git merge-base --is-ancestor "$commit" "$tip" || return 1; fi
  rev_time="$(git log -1 --format=%ct "$commit")" tip_time="$(git log -1 --format=%ct "$tip")"
  (( tip_time - rev_time <= ${CMUX_TUI_TREE_MAX_AGE_HOURS:-24} * 3600 )) || return 1
  git diff --quiet "$commit" "$tip" -- plans/cmux-next/daemon-capabilities.json || return 1
  key="$(python3 "$root/scripts/ci/cmux_tui_tree_key.py" --version v2 "$commit" 2>/dev/null)" || return 1
  env -u CMUX_TUI_TREE_KEY bash "$here/pin-cmux-tui.sh" verify-key "$key" >/dev/null 2>&1 || return 1
  behind="$(git rev-list --count "$commit..$tip" 2>/dev/null || echo 0)" hours=$(( (tip_time - rev_time) / 3600 ))
  printf 'commit=%s\nkey=%s\nsource_commit=%s\nbehind=%s\nbehind_hours=%s\n' "$commit" "$key" "$commit" "$behind" "$hours"
}
[[ -n "$out" ]] || out="$(signed_pointer_tree)" || {
  echo "older-tree: no published cmux-tui tree within ${CMUX_TUI_TREE_MAX_AGE_HOURS:-24} h of ${tip:0:12} has its daemon-capabilities.json (window and signed pointer)" >&2
  exit 1
}
field() { sed -n "s/^$1=//p" <<<"$out" | head -1; }
commit="$(field commit)" key="$(field key)" from="$(field source_commit)" behind="$(field behind)" hours="$(field behind_hours)"
[[ "$commit" =~ ^[0-9a-f]{40}$ && "$key" =~ ^[0-9a-f]{40}$ && "$from" =~ ^[0-9a-f]{40}$ ]] \
  || { echo "older-tree: the resolver printed no tree" >&2; exit 1; }
if [[ "$from" == "$tip" ]]; then echo "older-tree: ${tip:0:12}'s own tree is published as $key" >&2; exit 3; fi
echo "older-tree: ${tip:0:12}'s tree $tip_key is not published; its app takes tree $key of ${from:0:12} (${behind:-?} commits, ${hours:-?} h behind; same daemon-capabilities.json), published by ${commit:0:12}" >&2
printf 'commit=%s\nkey=%s\nsource_commit=%s\ntip_key=%s\nbehind=0\nbehind_hours=0\ntree_from=%s %s %s\n' \
  "$commit" "$key" "$tip" "$tip_key" "$from" "${behind:-0}" "${hours:-0}"
