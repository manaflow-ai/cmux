#!/usr/bin/env bash
# Rift (github.com/anomalyco/rift, APFS clonefile workspaces) vs `git worktree add` for an
# agent's first green build (plans/cmux-next/rift-eval.md). Runs on a fleet Mac mini only:
#   cmux-ci run --class exclusive --script scripts/measure/rift-eval.sh --ref <sha> \
#     --artifact .build/rift-eval.md
# Workloads: webviews (bun install + bun run build), cmux-tui acpmux (cargo build -p acpmux),
# CmuxNext (swift build --product CmuxNextApp). Lanes:
#   seed  a fresh clone, cold install + build (warms the host's global caches)
#   (a)   git worktree add + install + build, then one edit + incremental build
#   (b)   rift create --copy-all from the warm seed, no-op build, then one edit + build
#   (c)   git worktree add + `cp -c -R` (clonefile) of the seed's node_modules/target/.build
# It also checks rift's git behavior (detached HEAD, own .git, linked-worktree refusal) and
# disk use (df free-space deltas; APFS clones share blocks until written).
# Everything lives in one temp dir under $HOME (one APFS volume) and is removed on exit.
set -uo pipefail
RIFT_VERSION="${RIFT_EVAL_VERSION:-v0.0.13}"
WORKLOADS="${RIFT_EVAL_WORKLOADS:-bun rust swift}"
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
out="$repo/.build/rift-eval.md"
mkdir -p "$repo/.build"
work="$(mktemp -d "$HOME/rift-eval.XXXXXX")"
work="$(cd "$work" && pwd -P)"
db="$work/rift.sqlite"
cleanup() { chmod -R u+w "$work" 2>/dev/null; rm -rf "$work"; }
trap cleanup EXIT

now() { /usr/bin/perl -MTime::HiRes=time -e 'printf "%.3f\n", time'; }
freekb() { df -k "$work" | awk 'NR==2 {print $4}'; }
rows=()
row() { rows+=("| $1 | $2 | $3 | $4 |"); echo "ROW | $1 | $2 | $3 | $4 |"; }
# timed LABEL LOG CMD...: run CMD, print seconds; rc in $last_rc.
last_rc=0
timed() {
  local log="$1"; shift
  local t0 t1; t0="$(now)"
  ( "$@" ) >> "$log" 2>&1; last_rc=$?
  t1="$(now)"
  awk -v a="$t0" -v b="$t1" 'BEGIN { printf "%.1f", b - a }'
}

echo "== host: $(scutil --get ComputerName 2>/dev/null) $(sw_vers -productVersion) $(sysctl -n machdep.cpu.brand_string) $(sysctl -n hw.ncpu) cpus"
echo "== work: $work ($(diskutil info "$(df "$work" | awk 'NR==2 {print $1}')" 2>/dev/null | awk -F: '/Type \(Bundle\)/ {gsub(/ /,"",$2); print $2}'))"

echo "== rift $RIFT_VERSION"
mkdir -p "$work/rift-dl"
base="https://github.com/anomalyco/rift/releases/download/$RIFT_VERSION"
tarball="rift-$RIFT_VERSION-aarch64-apple-darwin.tar.gz"
# sha256 of the v0.0.13 aarch64-apple-darwin archive, from the release's SHA256SUMS.
RIFT_SHA256="${RIFT_EVAL_SHA256:-4e5f6d8b5c8d8d0d91482b084d05587cd30c2e6b89a48c6bcb9bebf852a9d85a}"
curl -fsSL -o "$work/rift-dl/$tarball" "$base/$tarball" || { echo "error: rift download failed"; exit 1; }
got="$(shasum -a 256 "$work/rift-dl/$tarball" | awk '{print $1}')"
[[ "$got" == "$RIFT_SHA256" ]] || { echo "error: rift checksum mismatch ($got)"; exit 1; }
tar -xzf "$work/rift-dl/$tarball" -C "$work/rift-dl"
rift_bin="$(find "$work/rift-dl" -type f -name rift -perm -u+x | head -1)"
[[ -x "$rift_bin" ]] || { echo "error: no rift binary in $tarball"; exit 1; }
rift() { "$rift_bin" --database "$db" "$@"; }
echo "rift: $rift_bin"

# Pinned bun (webviews/package.json devEngines), from the fleet tool cache or bun's release.
bun_pin="$(python3 -c 'import json; print(json.load(open("'"$repo"'/webviews/package.json"))["devEngines"]["packageManager"]["version"])')"
for d in "$HOME/Library/Caches/cmux-ci/tools/bun-$bun_pin/bin" "$HOME/.bun/bin"; do
  [[ -x "$d/bun" && "$("$d/bun" --version)" == "$bun_pin" ]] && export PATH="$d:$PATH" && break
done
if [[ "$(bun --version 2>/dev/null)" != "$bun_pin" ]]; then
  mkdir -p "$work/bun" && curl -fsSL -o "$work/bun/bun.zip" "https://github.com/oven-sh/bun/releases/download/bun-v$bun_pin/bun-darwin-aarch64.zip" \
    && unzip -q "$work/bun/bun.zip" -d "$work/bun" && export PATH="$work/bun/bun-darwin-aarch64:$PATH"
fi
echo "bun: $(bun --version 2>&1)  cargo: $(cd "$repo/cmux-tui" && rustup which cargo 2>&1)  swift: $(swift --version 2>&1 | head -1)"

install_cmd() { # W DIR
  case "$1" in
    bun) (cd "$2/webviews" && bun install --frozen-lockfile) ;;
    rust) (cd "$2/cmux-tui" && env -u CARGO_TARGET_DIR cargo fetch --locked) ;;
    swift) swift package --package-path "$2/Packages/macOS/CmuxNext" resolve ;;
  esac
}
build_cmd() { # W DIR
  case "$1" in
    bun) (cd "$2/webviews" && bun run build) ;;
    rust) (cd "$2/cmux-tui" && env -u CARGO_TARGET_DIR cargo build --locked -p acpmux) ;;
    swift) swift build --package-path "$2/Packages/macOS/CmuxNext" --product CmuxNextApp ;;
  esac
}
edit_cmd() { # W DIR: one source edit an agent would make
  case "$1" in
    bun) echo "export const riftEvalEdit = $RANDOM;" >> "$2/webviews/src/agent-activity/model.ts" ;;
    rust) echo "// rift-eval $RANDOM" >> "$2/cmux-tui/crates/acpmux/src/main.rs" ;;
    swift) f="$(ls "$2"/Packages/macOS/CmuxNext/Sources/CmuxNextFiles/*.swift | head -1)"; echo "// rift-eval $RANDOM" >> "$f" ;;
  esac
}
cache_dirs() { # W: build/dependency dirs relative to the checkout
  case "$1" in
    bun) echo "webviews/node_modules" ;;
    rust) echo "cmux-tui/target" ;;
    swift) echo "Packages/macOS/CmuxNext/.build" ;;
  esac
}

echo "== seed: clone at $(git -C "$repo" rev-parse HEAD)"
t="$(timed "$work/seed.log" git clone -q --shared "$repo" "$work/seed")"
git -C "$work/seed" checkout -q --detach "$(git -C "$repo" rev-parse HEAD)" >> "$work/seed.log" 2>&1
row "seed" "git clone --shared" "${t}s" "rc=$last_rc"
for w in $WORKLOADS; do
  ti="$(timed "$work/seed-$w.log" install_cmd "$w" "$work/seed")"; ri=$last_rc
  tb="$(timed "$work/seed-$w.log" build_cmd "$w" "$work/seed")"; rb=$last_rc
  row "seed cold $w" "install / build" "${ti}s / ${tb}s" "rc=$ri/$rb"
  [[ $rb == 0 ]] || tail -30 "$work/seed-$w.log"
done
git -C "$work/seed" status --porcelain | head -5

echo "== (a) git worktree add + install + build"
f0="$(freekb)"
t="$(timed "$work/a.log" git -C "$work/seed" worktree add -q --detach "$work/wt-a" HEAD)"
row "(a) create" "git worktree add" "${t}s" "rc=$last_rc"
for w in $WORKLOADS; do
  ti="$(timed "$work/a-$w.log" install_cmd "$w" "$work/wt-a")"; ri=$last_rc
  tb="$(timed "$work/a-$w.log" build_cmd "$w" "$work/wt-a")"; rb=$last_rc
  edit_cmd "$w" "$work/wt-a"
  te="$(timed "$work/a-$w.log" build_cmd "$w" "$work/wt-a")"; re=$last_rc
  row "(a) $w" "install / first build / edit+build" "${ti}s / ${tb}s / ${te}s" "rc=$ri/$rb/$re"
  [[ $rb == 0 ]] || tail -30 "$work/a-$w.log"
done
row "(a) disk" "free space used" "$(( (f0 - $(freekb)) / 1024 )) MiB" "du $(du -sk "$work/wt-a" | awk '{printf "%d MiB", $1/1024}')"

echo "== (b) rift create --copy-all from the warm seed"
t="$(timed "$work/b.log" rift init --here "$work/seed")"
row "(b) init" "rift init --here" "${t}s" "rc=$last_rc"
f0="$(freekb)"
t0="$(now)"; b_path="$(rift create --copy-all --no-hooks --into "$work/rifts" --name b "$work/seed" 2>>"$work/b.log" | tail -1)"
t1="$(now)"
[[ -d "$b_path" ]] || tail -20 "$work/b.log"
row "(b) create" "rift create --copy-all" "$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.1f", b-a}')s" "path=${b_path:-FAILED}"
row "(b) disk" "free space used" "$(( (f0 - $(freekb)) / 1024 )) MiB" "du (logical) $( [[ -d "$b_path" ]] && du -sk "$b_path" | awk '{printf "%d MiB", $1/1024}')"
if [[ -d "$b_path" ]]; then
  for w in $WORKLOADS; do
    tn="$(timed "$work/b-$w.log" build_cmd "$w" "$b_path")"; rn=$last_rc
    edit_cmd "$w" "$b_path"
    te="$(timed "$work/b-$w.log" build_cmd "$w" "$b_path")"; re=$last_rc
    row "(b) $w" "no-op build / edit+build" "${tn}s / ${te}s" "rc=$rn/$re"
    [[ $rn == 0 ]] || tail -30 "$work/b-$w.log"
  done
  echo "== (b) git checks"
  {
    echo "HEAD: $(git -C "$b_path" rev-parse --abbrev-ref HEAD) $(git -C "$b_path" rev-parse --short HEAD)"
    echo ".git is a dir: $([[ -d "$b_path/.git" ]] && echo yes || echo no)"
    echo "alternates: $(cat "$b_path/.git/objects/info/alternates" 2>/dev/null || echo none)"
    echo "status lines: $(git -C "$b_path" status --porcelain | wc -l | tr -d ' ')"
    echo "seed worktrees: $(git -C "$work/seed" worktree list | wc -l | tr -d ' ')"
    echo "rift's copied worktree list (seed's linked worktrees leak in): $(git -C "$b_path" worktree list | tr '\n' ';')"
    git -C "$b_path" switch -q -c rift-eval-branch && git -C "$b_path" -c user.email=e@x -c user.name=e commit -q --allow-empty -m rift-eval \
      && echo "branch+commit in rift: ok; seed sees branch: $(git -C "$work/seed" rev-parse -q --verify rift-eval-branch >/dev/null && echo yes || echo no)"
    echo "rift from linked worktree (wt-a): $(cd "$work/wt-a" && "$rift_bin" --database "$db" create --copy-all --no-hooks --into "$work/rifts" --name from-wt 2>&1 | tail -1)"
  } 2>&1 | tee "$work/git-checks.txt"
  echo "== (b) 4 concurrent rift creates"
  t0="$(now)"
  for i in 1 2 3 4; do rift create --copy-all --no-hooks --into "$work/rifts" --name "par$i" "$work/seed" > "$work/par$i.out" 2>&1 & done
  wait
  t1="$(now)"
  row "(b) 4 parallel creates" "rift create x4" "$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.1f", b-a}')s" "ok=$(ls -d "$work"/rifts/par* 2>/dev/null | wc -l | tr -d ' ')/4"
  t="$(timed "$work/b.log" rift remove --no-hooks "$b_path")"; r1=$last_rc
  t2="$(timed "$work/b.log" rift gc)"
  row "(b) cleanup" "rift remove / gc" "${t}s / ${t2}s" "rc=$r1/$last_rc"
fi

echo "== (c) git worktree add + clonefile of the seed's caches"
f0="$(freekb)"
t="$(timed "$work/c.log" git -C "$work/seed" worktree add -q --detach "$work/wt-c" HEAD)"
tc=0
for w in $WORKLOADS; do
  d="$(cache_dirs "$w")"
  if [[ -d "$work/seed/$d" ]]; then
    x="$(timed "$work/c.log" cp -c -R "$work/seed/$d" "$work/wt-c/$d")"
    tc="$(awk -v a="$tc" -v b="$x" 'BEGIN{printf "%.1f", a+b}')"
  fi
done
row "(c) create" "git worktree add / cp -c caches" "${t}s / ${tc}s" "rc=$last_rc"
row "(c) disk" "free space used" "$(( (f0 - $(freekb)) / 1024 )) MiB" ""
for w in $WORKLOADS; do
  ti="$(timed "$work/c-$w.log" install_cmd "$w" "$work/wt-c")"; ri=$last_rc
  tn="$(timed "$work/c-$w.log" build_cmd "$w" "$work/wt-c")"; rn=$last_rc
  edit_cmd "$w" "$work/wt-c"
  te="$(timed "$work/c-$w.log" build_cmd "$w" "$work/wt-c")"; re=$last_rc
  row "(c) $w" "install / no-op build / edit+build" "${ti}s / ${tn}s / ${te}s" "rc=$ri/$rn/$re"
  [[ $rn == 0 ]] || tail -30 "$work/c-$w.log"
done

{
  echo "# rift-eval $(git -C "$repo" rev-parse --short HEAD) on $(scutil --get ComputerName 2>/dev/null), $(date -u +%FT%TZ)"
  echo
  echo "| lane | step | time | notes |"
  echo "|---|---|---|---|"
  printf '%s\n' "${rows[@]}"
  echo
  echo '```'
  cat "$work/git-checks.txt" 2>/dev/null
  echo '```'
} > "$out"
cat "$out"
