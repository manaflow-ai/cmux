#!/usr/bin/env bash
# The idle cmux-tui daemon's memory on Linux at one or more commits, from one harness on one runner (CMUX-571,
# goal ram-baseline): scripts/measure/tui-idle-ram.py on a release build of each commit's daemon, and with dhat=1
# also a dhat-heap build's heap at exit by allocation site (scripts/measure/dhat-top.py). Run at a pushed head:
#   cmux-ci test --artifact DIR -- bash -c 'set -o pipefail; scripts/measure/tui-idle-ram.sh [dhat=1] [workspaces=1] [settle=20] [profile=release] [arenas=2] [since_days=14] [SHA...]'
# or through the registered bench: scripts/bench/cmux-bench tui-idle --build SHA --arg commits=SHA,SHA
# SHA is any unique prefix (git rev-parse). No SHA measures this checkout. Each SHA is checked out into a scratch worktree; this checkout's tui-idle-ram.py
# and dhat-top.py measure every one. Prints "TUI-IDLE-AT <sha>" before each commit's lines.
# runs=N sets the idle launches per commit (3; 0 measures no idle memory).
# latency=1 (the `daemon-latency` bench, scripts/bench/benches/daemon_latency.py) also times each commit's release
# build on its hot paths once every commit is built, in latency_rounds rounds (2) whose commit order alternates
# (A B, B A, ...), so drift on the runner lands on both sides:
#   - the daemon request path and the `cmux` CLI end to end: this checkout's cmux-tui/scripts/bench-daemon-latency.py
#     (latency_n=300, latency_cli_n=40, latency_scenarios=small,scale), each line printed as
#     `TUI-LATENCY <sha12> <round> PERF-DAEMON ...`;
#   - acpmux, an agent prompt's send to first token, cold (agent start + send) and warm (send): the commit's own
#     `cargo test --release -p acpmux --test start_under_load_bench` at no load (acpmux_samples=30; acpmux=0 skips
#     it), each summary line printed as `TUI-ACPMUX <sha12> <round> ...`.
set -uo pipefail
# The whole output also goes to $FAST_CHECKS_OUT/tui-idle-ram.log, the file `cmux-bench tui-idle` reads back
# (cmux-ci test --artifact): the run's printed log keeps only its tail.
[ -n "${FAST_CHECKS_OUT:-}" ] && exec > >(tee -a "$FAST_CHECKS_OUT/tui-idle-ram.log") 2>&1
dhat=0
workspaces=1
settle=20
profile=release
# Every commit runs with glibc capped at the arenas the tip caps itself to (malloc_arenas.rs DAEMON_ARENAS), so a
# Linux-only allocator setting does not read as a change of what the daemon holds; arenas=0 leaves glibc default.
arenas=2
# The heap profile build: release code generation without its link-time cost (Cargo.toml [profile.gate]).
dhat_profile=gate
# How far back a short commit id is looked for on feat-cmux-next.
since_days=14
runs=3
latency=0
latency_rounds=2
latency_n=300
latency_cli_n=40
latency_scenarios=small,scale
acpmux=1
acpmux_samples=30
shas=()
for arg in "$@"; do
  case "$arg" in
    dhat=*) dhat="${arg#dhat=}" ;;
    runs=*) runs="${arg#runs=}" ;;
    latency=*) latency="${arg#latency=}" ;;
    latency_rounds=*) latency_rounds="${arg#latency_rounds=}" ;;
    latency_n=*) latency_n="${arg#latency_n=}" ;;
    latency_cli_n=*) latency_cli_n="${arg#latency_cli_n=}" ;;
    latency_scenarios=*) latency_scenarios="${arg#latency_scenarios=}" ;;
    acpmux=*) acpmux="${arg#acpmux=}" ;;
    acpmux_samples=*) acpmux_samples="${arg#acpmux_samples=}" ;;
    workspaces=*) workspaces="${arg#workspaces=}" ;;
    settle=*) settle="${arg#settle=}" ;;
    profile=*) profile="${arg#profile=}" ;;
    arenas=*) arenas="${arg#arenas=}" ;;
    dhat_profile=*) dhat_profile="${arg#dhat_profile=}" ;;
    since_days=*) since_days="${arg#since_days=}" ;;
    *) shas+=("$arg") ;;
  esac
done
root="$(git rev-parse --show-toplevel)"
here="$root/scripts/measure"
scratch="$(mktemp -d)"
trees=()
cleanup() {
  for tree in ${trees[@]+"${trees[@]}"}; do git -C "$root" worktree remove --force "$tree" >/dev/null 2>&1; done
  rm -rf "$scratch"
}
trap cleanup EXIT
# A bare runner: the pinned Rust and Zig and the native build tools (as infinite-items-linux.sh).
command -v cargo >/dev/null || (cd "$root" && ./scripts/install-rust-ci.sh)
if ! command -v zig >/dev/null && [ -z "${ZIG:-}${CMUX_ZIG:-}" ]; then
  zig_env="$(mktemp)"
  (cd "$root" && [ -f ghostty-next/build.zig.zon ] || git submodule update --init --depth 1 ghostty-next)
  (cd "$root" && GHOSTTY_ZIG_SOURCE=ghostty-next GITHUB_ENV="$zig_env" GITHUB_PATH=/dev/null ./scripts/install-zig-ci.sh)
  zig_line="$(grep '^CMUX_ZIG=' "$zig_env" | tail -n 1 || true)"
  rm -f "$zig_env"
  [ -z "$zig_line" ] || export "$zig_line"
fi
command -v clang >/dev/null || { sudo apt-get update -qq && sudo apt-get install -y -qq clang libclang-dev pkg-config; }
export PATH="$HOME/.cargo/bin:$PATH"
# One target directory per commit and build kind: a target shared by two trees built the second tree with the
# first one's generated code (E0599 in cmux-tui-core, run 43834927681).
depth=()
[[ "$(git -C "$root" rev-parse --is-shallow-repository)" == true ]] && depth=(--depth=1)
# Where a commit is fetched from: a fleet step's tree has no `origin` remote (a snapshot commit over the head), so
# origin's URL when there is one, else the repository's own (as acpmux-overhead.sh).
fetch_url="${TUI_IDLE_FETCH_URL:-$(git -C "$root" remote get-url origin 2>/dev/null || echo https://github.com/manaflow-ai/cmux.git)}"
# A commit by any unique prefix: git rev-parse resolves it. A shallow CI checkout has no other commit, and GitHub
# serves a fetch only by the full id, so a prefix it cannot resolve first deepens feat-cmux-next to its last
# since_days days (`cmux-bench tui-idle` resolves prefixes where it runs, so a run from it never needs this).
resolve() {
  local want="$1" full
  if full="$(git -C "$root" rev-parse -q --verify "$want^{commit}" 2>/dev/null)"; then echo "$full"; return 0; fi
  if [[ ${#want} -eq 40 ]]; then
    git -C "$root" fetch -q --no-tags --no-recurse-submodules ${depth[@]+"${depth[@]}"} "$fetch_url" "$want" || return 1
  else
    git -C "$root" fetch -q --no-tags --no-recurse-submodules --shallow-since="${since_days} days ago" \
      "$fetch_url" feat-cmux-next || return 1
  fi
  git -C "$root" rev-parse -q --verify "$want^{commit}"
}
[[ ${#shas[@]} -eq 0 ]] && shas=(HEAD)
status=0
timed=()
[[ "$arenas" != 0 ]] && export MALLOC_ARENA_MAX="$arenas"
for sha in ${shas[@]+"${shas[@]}"}; do
  if [[ "$sha" == HEAD ]]; then
    tree="$root"
    full="$(git -C "$root" rev-parse HEAD)"
  else
    full="$(resolve "$sha")" || { echo "TUI-IDLE-ERROR $sha: not a commit here or on feat-cmux-next's last ${since_days} days"; status=1; continue; }
    # A prefix resolved from commits only: fetch the commit itself for its tree.
    git -C "$root" fetch -q --no-tags --no-recurse-submodules ${depth[@]+"${depth[@]}"} "$fetch_url" "$full" 2>/dev/null || true
    tree="$scratch/${full:0:12}"
    git -C "$root" worktree add -q --detach "$tree" "$full" && trees+=("$tree") || { status=1; continue; }
  fi
  [ -f "$tree/ghostty-next/build.zig" ] || git -C "$tree" submodule update -q --init --depth 1 ghostty-next || { status=1; continue; }
  echo "TUI-IDLE-AT $full $(git -C "$root" log -1 --format=%s "$full" 2>/dev/null | cut -c1-80)"
  bins=(--bin cmux-tui)
  grep -q '^name = "cmux-tui-host"' "$tree/cmux-tui/crates/cmux-tui/Cargo.toml" && bins+=(--bin cmux-tui-host)
  CARGO_TARGET_DIR_RELEASE="$scratch/target-release-${full:0:12}" CARGO_TARGET_DIR_DHAT="$scratch/target-dhat-${full:0:12}"
  t0=$(date +%s)
  (cd "$tree/cmux-tui" && CARGO_TARGET_DIR="$CARGO_TARGET_DIR_RELEASE" cargo build --locked --profile "$profile" -p cmux-tui "${bins[@]}" 2>&1 | tail -n 2) || { status=1; continue; }
  out="$CARGO_TARGET_DIR_RELEASE/$profile"
  echo "TUI-IDLE-BUILD ${full:0:12} $(( $(date +%s) - t0 )) s; cmux-tui $(stat -c %s "$out/cmux-tui") bytes"
  command -v size >/dev/null && size -A "$out/cmux-tui" | grep -E '^\.(text|rodata|data|data\.rel\.ro|bss|got|tbss|tdata) ' | sed "s/^/TUI-IDLE-SECTION ${full:0:12} /"
  timed+=("${full:0:12}|$tree|$CARGO_TARGET_DIR_RELEASE")
  if [[ "$latency" == 1 && "$acpmux" == 1 ]]; then
    (cd "$tree/cmux-tui" && CARGO_TARGET_DIR="$CARGO_TARGET_DIR_RELEASE" cargo test --locked --profile "$profile" -p acpmux \
      --test start_under_load_bench --no-run 2>&1 | tail -n 2) || { echo "TUI-ACPMUX-ERROR ${full:0:12}: the bench did not build"; status=1; }
  fi
  for (( run = 1; run <= runs; run++ )); do
    python3 "$here/tui-idle-ram.py" --tui "$out/cmux-tui" --workspaces "$workspaces" --settle "$settle" --label "${full:0:12}-r$run" || status=1
  done
  if [[ "$dhat" == 1 ]]; then
    locked=(--locked)
    if ! grep -q '^dhat-heap' "$tree/cmux-tui/crates/cmux-tui/Cargo.toml"; then
      # A commit from before the feature: this checkout's heap_profile.rs, its feature and its two calls, put in the
      # scratch tree only (the lock gains the optional dep, so this one build is not --locked).
      crate="$tree/cmux-tui/crates/cmux-tui"
      cp "$root/cmux-tui/crates/cmux-tui/src/heap_profile.rs" "$crate/src/heap_profile.rs"
      sed -i '0,/^\[features\]$/s//[features]\ndhat-heap = ["dep:dhat"]/' "$crate/Cargo.toml"
      sed -i '0,/^\[dependencies\]$/s//[dependencies]\ndhat = { version = "0.3", optional = true }/' "$crate/Cargo.toml"
      sed -i '0,/^mod /s//mod heap_profile;\nmod /' "$crate/src/main.rs"
      sed -i '0,/^pub fn main() -> std::process::ExitCode {$/s//&\n    heap_profile::start();/' "$crate/src/main.rs"
      locked=()
      echo "DHAT injected: ${full:0:12}"
    fi
    (cd "$tree/cmux-tui" && CARGO_TARGET_DIR="$CARGO_TARGET_DIR_DHAT" cargo build ${locked[@]+"${locked[@]}"} --profile "$dhat_profile" -p cmux-tui "${bins[@]}" --features dhat-heap 2>&1 | tail -n 2) || { status=1; continue; }
    prof="$scratch/dhat-${full:0:12}.json"
    CMUX_TUI_DHAT_OUT="$prof" python3 "$here/tui-idle-ram.py" --tui "$CARGO_TARGET_DIR_DHAT/$dhat_profile/cmux-tui" \
      --workspaces "$workspaces" --settle "$settle" --label "${full:0:12}-dhat" || status=1
    if [ -f "$prof" ]; then python3 "$here/dhat-top.py" "$prof" 40 | sed "s/^/${full:0:12} /"; else echo "DHAT none: ${full:0:12}"; fi
    [ -n "${FAST_CHECKS_OUT:-}" ] && [ -f "$prof" ] && cp "$prof" "$FAST_CHECKS_OUT/"
  fi
done
if [[ "$latency" == 1 ]]; then
  ulimit -n "$(ulimit -Hn)" 2>/dev/null || ulimit -n 65536 2>/dev/null || true
  for (( round = 1; round <= latency_rounds; round++ )); do
    order=(${timed[@]+"${timed[@]}"})
    if (( round % 2 == 0 )); then
      order=(); for (( i = ${#timed[@]} - 1; i >= 0; i-- )); do order+=("${timed[$i]}"); done
    fi
    for entry in ${order[@]+"${order[@]}"}; do
      IFS='|' read -r sha12 tree target <<< "$entry"
      echo "TUI-LATENCY-ROUND $sha12 $round load=\"$(cut -d' ' -f1-3 /proc/loadavg)\""
      python3 "$root/cmux-tui/scripts/bench-daemon-latency.py" --bin "$target/$profile/cmux-tui" --n "$latency_n" \
        --cli-n "$latency_cli_n" --scenarios "$latency_scenarios" --out "$scratch/latency-$sha12-$round.json" 2>>"${FAST_CHECKS_OUT:-$scratch}/latency-stderr.log" \
        | grep '^PERF-DAEMON' | sed "s/^/TUI-LATENCY $sha12 $round /" || status=1
      if [[ "$acpmux" == 1 ]]; then
        (cd "$tree/cmux-tui" && CARGO_TARGET_DIR="$target" START_BENCH_LOAD=1 START_BENCH_SAMPLES="$acpmux_samples" \
          cargo test --locked --profile "$profile" -p acpmux --test start_under_load_bench -- --ignored --nocapture 2>&1) \
          | grep -E '^  (cold|warm) ' | sed "s/^ */TUI-ACPMUX $sha12 $round /" || status=1
      fi
    done
  done
fi
exit "$status"
