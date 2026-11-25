#!/usr/bin/env bash
# AutoCloud start's repo-ready time: the full `git clone` a Cloud-started chat used to do, vs
# the warm blobless mirror + alternates it does now (cmux-tui/crates/acpmux/src/auto_session/
# import/mirror.rs). Same git steps as the Rust, timed from an empty folder to a checked-out,
# clean branch with its upstream.
#   scripts/measure/autocloud-repo-ready.sh [REMOTE] [BRANCH] [N]
#   cmux-ci run --script scripts/measure/autocloud-repo-ready.sh --ref SHA
# Rows: before (full clone), after-cold (no mirror yet: blobless bare clone + HEAD's blobs),
# after-warm (the mirror exists: fetch what is new, borrow it). Each clone is removed after its
# row; the one warm mirror at the end. Prints a Duress line (load, cores, git version).
set -uo pipefail
R="${1:-https://github.com/manaflow-ai/cmux.git}" B="${2:-main}" N="${3:-3}"
G=(git -c core.hooksPath=/dev/null -c core.fsmonitor=false -c submodule.recurse=false)
export GIT_TERMINAL_PROMPT=0 GIT_LFS_SKIP_SMUDGE=1 LC_ALL=C
W="$(mktemp -d "${TMPDIR:-/tmp}/autocloud-ready.XXXXXX")"; W="$(cd "$W" && pwd -P)"
trap 'rm -rf "$W"' EXIT
now() { date +%s.%N; }
# Pack bytes under a folder: what git received from the remote (packs are kept as sent).
packs() { find "$@" -name '*.pack' -type f -printf '%s\n' 2>/dev/null | awk '{s+=$1} END{print s+0}'; }
mb() { awk "BEGIN{printf \"%.1f\", $1/1048576}"; }
since() { awk "BEGIN{printf \"%.2f\", $(now)-$1}"; }

before() { mkdir -p "$1"; "${G[@]}" -C "$1" clone -q --branch "$B" -- "$R" .; }

after() { # DEST MIRROR_ROOT
  local d=$1 root=$2 key m tmp c miss
  mkdir -p "$d" "$root"; key=$(printf %s "$R" | sha256sum | cut -c1-16); m="$root/$key.git"
  if [ -f "$m/HEAD" ]; then "${G[@]}" -C "$m" fetch -q --no-tags --filter=blob:none origin || return 1
  else
    tmp="$root/.tmp-$key-$$"
    "${G[@]}" clone -q --bare --filter=blob:none -- "$R" "$tmp" || return 1
    git -C "$tmp" config remote.origin.fetch '+refs/heads/*:refs/heads/*'
    git -C "$tmp" config gc.auto 0; git -C "$tmp" config gc.pruneExpire never; mv "$tmp" "$m"
  fi
  c=$(git -C "$m" rev-parse --verify "refs/heads/$B^{commit}") || return 1
  miss=$(git -C "$m" rev-list --objects --missing=print --no-walk "$c" | sed -n 's/^?//p')
  if [ -n "$miss" ]; then
    printf '%s\n' "$miss" | "${G[@]}" -C "$m" -c fetch.negotiationAlgorithm=noop fetch -q --no-tags \
      --no-write-fetch-head --recurse-submodules=no --filter=blob:none --stdin origin || return 1
  fi
  "${G[@]}" -C "$d" init -q; echo "$m/objects" > "$d/.git/objects/info/alternates"
  git -C "$d" remote add origin "$R"
  git -C "$d" config core.repositoryformatversion 1; git -C "$d" config extensions.partialClone origin
  git -C "$d" config remote.origin.promisor true
  git -C "$m" for-each-ref --format='update refs/remotes/origin/%(refname:lstrip=2) %(objectname)' refs/heads/ \
    | git -C "$d" update-ref --stdin
  "${G[@]}" -C "$d" checkout -q -b "$B" "$c" && git -C "$d" branch -q --set-upstream-to="origin/$B" "$B"
}

check() { [ -z "$(git -C "$1" status --porcelain)" ] && git -C "$1" rev-parse -q --verify '@{upstream}' >/dev/null && echo ok || echo BAD; }

echo "Duress: load $(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null || sysctl -n vm.loadavg) cores $(nproc 2>/dev/null || sysctl -n hw.ncpu) $(git --version) remote $R branch $B"
echo "| row | run | repo-ready s | from GitHub MB | clean+upstream |"; echo "|---|---|---|---|---|"
for i in $(seq "$N"); do t=$(now); before "$W/b$i"; s=$(since "$t"); echo "| before | $i | $s | $(mb "$(packs "$W/b$i")") | $(check "$W/b$i") |"; rm -rf "$W/b$i"; done
for i in $(seq "$N"); do t=$(now); after "$W/c$i" "$W/m$i"; s=$(since "$t"); echo "| after-cold | $i | $s | $(mb "$(packs "$W/m$i" "$W/c$i")") | $(check "$W/c$i") |"; rm -rf "$W/c$i"; [ "$i" = 1 ] || rm -rf "$W/m$i"; done
for i in $(seq "$N"); do p0=$(packs "$W/m1"); t=$(now); after "$W/w$i" "$W/m1"; s=$(since "$t"); echo "| after-warm | $i | $s | $(mb $(( $(packs "$W/m1" "$W/w$i") - p0 ))) | $(check "$W/w$i") |"; rm -rf "$W/w$i"; done
echo "Duress end: load $(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null || sysctl -n vm.loadavg); mirror $(du -sh "$W/m1" | cut -f1)"
