#!/usr/bin/env bash
# Infinite items on Linux (CMUX-571): the daemons (scripts/measure/infinite-items.py) and the headless
# chat pages (webviews/bench/chat-pages-memory.bench.ts, RELEASE=1), at each count. Run at a pushed head:
#   cmux-ci test -- bash -c 'scripts/measure/infinite-items-linux.sh [counts=10,100,1000] [days=3] [pages=0]; echo rc=$?'
#   infinite-items-linux.sh build-only: only the release build.
#   infinite-items-linux.sh before=own-exe ...: first runs the same build with no cmux-tui-host beside its daemon (a
#     copy of cmux-tui alone), so every terminal host re-execs the daemon's own file as before host_exe/linux.rs: the
#     slim host's before (BEFORE lines) and after from one build on one runner in one job.
#   infinite-items-linux.sh before=ref:REF repeat=3 ...: also builds REF (a commit or branch, e.g. the merge base) in a
#     worktree of its own and runs it and this head in turn, REPEAT times each (BEFORE rI and AFTER rI lines): a
#     change's before and after from one harness on one runner in one job.
#   infinite-items-linux.sh before=hosts ...: first runs the same build with CMUX_TUI_TERMINAL_HOST_MODEL=hosts (a
#     cmux-tui-host per terminal), then the product default (also hosts while the holder is off by default).
#   infinite-items-linux.sh ... --terminal-host-model=holder: measures the one holder (the harness ignores the caller's env).
#   infinite-items-linux.sh live=1 ...: first runs the same build with idle hibernation off (ACPMUX_IDLE_CHILD_SECS=0, so
#     every chat keeps its agent) and no simulated day (LIVE lines): what an item costs live, beside what it costs
#     hibernated, from one build on one runner in one job. live_counts=50,200 gives the live pass its own counts
#     (each live chat holds an agent host and an agent, so 1,000 of them need tens of GB).
#   infinite-items-linux.sh freed=1 ...: last, runs the same build with every tab parked after the open and each day
#     (--park-idle, FREED lines): what an item costs once the app's freeing tier (workspaces.freeing, a day idle) took it.
#   infinite-items-linux.sh alloc_ab=1 [alloc_budget=3000] [alloc_caps=64,off] ...: acpmux several ways from this head
#     (glibc's malloc, the gnu build's own: arms system and glibc; mimalloc, the musl packages' allocator: feature
#     mimalloc-gnu; mimalloc2: its v2 line; dhat-heap) and one cmux-tui, run in turn REPEAT times (ALLOC arm=A rI
#     lines). glibc-* arms run the glibc binary with a malloc setting in acpmux's environment (alloc_env below), so one
#     build measures each knob. alloc_caps=64,off runs every arm at each --resident-cap (off: none) and tags the arm
#     A@capN or A@off. The dhat arm writes its profile after the last sample (--heap-profile) and
#     its live bytes by allocation site print as DHAT lines. A round starts only while the last round's time still
#     fits in alloc_budget seconds from the start, so a job cap cuts repeats, not counts. Answers whether the
#     daemon's heap is live data (dhat's bytes near mimalloc's heap) or the allocator's retention. alloc_arms=A,B
#     runs a subset (dhat alone in a job of its own: it records slowly and writes at the budget's end if not done).
#   infinite-items-linux.sh musl=1 ...: builds the shipped musl flavor (cargo-zigbuild, x86_64-unknown-linux-musl) and
#     measures those binaries (not with before=ref:, which builds REF for the host).
# Builds release acpmux and cmux-tui (cmux-tui/) (musl=1: acpmux-standalone, staged as acpmux, as the package does), then prints INFINITE and PERF_ROW lines.
set -euo pipefail
counts="10,100,1000"
days=3
pages=1
page_counts=""
build_only=0
before=""
musl=0
repeat=1
live=0
live_counts=""
freed=0
cap_ab=""
alloc_ab=0
alloc_budget=3000
alloc_arms="mimalloc system dhat"
alloc_caps=""
extra=()
for arg in "$@"; do
  case "$arg" in
    counts=*) counts="${arg#counts=}" ;;
    days=*) days="${arg#days=}" ;;
    pages=*) pages="${arg#pages=}" ;;
    build-only) build_only=1 ;;
    before=*) before="${arg#before=}" ;;
    musl=*) musl="${arg#musl=}" ;;
    repeat=*) repeat="${arg#repeat=}" ;;
    live=*) live="${arg#live=}" ;;
    live_counts=*) live_counts="${arg#live_counts=}" ;;
    freed=*) freed="${arg#freed=}" ;;
    cap_ab=*) cap_ab="${arg#cap_ab=}" ;;
    alloc_ab=*) alloc_ab="${arg#alloc_ab=}" ;;
    alloc_budget=*) alloc_budget="${arg#alloc_budget=}" ;;
    alloc_arms=*) alloc_arms="${arg#alloc_arms=}"; alloc_arms="${alloc_arms//,/ }" ;;
    alloc_caps=*) alloc_caps="${arg#alloc_caps=}"; alloc_caps="${alloc_caps//,/ }" ;;
    page_counts=*) page_counts="${arg#page_counts=}" ;;
    --*) extra+=("$arg") ;;
    *) echo "infinite-items-linux.sh: unknown argument $arg" >&2; exit 2 ;;
  esac
done
root="$(git rev-parse --show-toplevel)"
cd "$root"
# before=ref: swaps the base's cmux-tui/ into this checkout and its cleanup puts HEAD's back, not what was there:
# refuse, before any build, a checkout whose cmux-tui/ holds staged or unstaged edits rather than lose them
# (untracked files survive a restore).
if [[ "$before" == ref:* ]] && [ -n "$(git status --porcelain --untracked-files=no -- cmux-tui)" ]; then
  echo "infinite-items-linux.sh: cmux-tui/ has uncommitted changes; before=ref: swaps it out, so commit or stash them first" >&2
  git status --short --untracked-files=no -- cmux-tui >&2
  exit 2
fi
# cmux-tui's terminal engine builds from the ghostty-next submodule, which a fast-checks snapshot leaves empty.
[ -f ghostty-next/build.zig ] || [ -n "${CMUX_GHOSTTY_SRC:-}" ] || git submodule update --init --depth 1 ghostty-next
# A bare runner (the perf cron's Linux part): the pinned Rust and Zig and the native build tools.
command -v cargo >/dev/null || ./scripts/install-rust-ci.sh
if ! command -v zig >/dev/null && [ -z "${ZIG:-}${CMUX_ZIG:-}" ]; then
  # The pinned Zig is ghostty-next's (the classic submodule is not checked out). A runner without passwordless
  # sudo gets it under RUNNER_TEMP, published only through GITHUB_ENV: read CMUX_ZIG back from a file of our own.
  zig_env="$(mktemp)"
  GHOSTTY_ZIG_SOURCE=ghostty-next GITHUB_ENV="$zig_env" GITHUB_PATH=/dev/null ./scripts/install-zig-ci.sh
  zig_line="$(grep '^CMUX_ZIG=' "$zig_env" | tail -n 1 || true)"
  rm -f "$zig_env"
  [ -z "$zig_line" ] || export "$zig_line"
fi
command -v clang >/dev/null || { sudo apt-get update -qq && sudo apt-get install -y -qq clang libclang-dev pkg-config; }
export PATH="$HOME/.cargo/bin:$PATH"
started_at=$SECONDS
# alloc_ab=1 builds acpmux three times. The release profile (thin LTO, one codegen unit) took 25 min for one build
# and 15 min for each rebuild (job e45696a9: 3400 s of builds, no round run), so every arm, the shipped allocator's
# too, builds with no LTO and 16 codegen units into a target directory of its own (the cached one is left as it is).
# The heap a run holds is the program's data, not its code, and all three arms share the one profile.
if [[ "$alloc_ab" == 1 ]]; then
  export CARGO_PROFILE_RELEASE_LTO=false CARGO_PROFILE_RELEASE_CODEGEN_UNITS=16
  export CARGO_TARGET_DIR="${RUNNER_TEMP:-/tmp}/infinite-alloc-ab-target"
fi
cd "$root/cmux-tui"
# cmux-tui-host: the slim terminal host the daemon runs its hosts from when it sits beside it (host_exe.rs).
target="$(cargo metadata --locked --no-deps --format-version 1 | python3 -c 'import json,sys; print(json.load(sys.stdin)["target_directory"])')"
if [[ "$musl" == 1 ]]; then
  # The shipped Linux flavor: musl, built as cmux-tui-build-package.yml builds it (cargo-zigbuild).
  musl_target=x86_64-unknown-linux-musl
  # shellcheck source=../lib/rust-targets.sh
  source "$root/scripts/lib/rust-targets.sh"
  ensure_rust_targets "$musl_target" >/dev/null
  command -v cargo-zigbuild >/dev/null || cargo install --locked cargo-zigbuild@0.20.0 2>&1 | tail -n 1
  if ! command -v zig >/dev/null && [ -n "${CMUX_ZIG:-}" ]; then export CARGO_ZIGBUILD_ZIG_PATH="$CMUX_ZIG"; fi
  # The package ships acpmux-standalone (its shipping features, a cargo of its own so features do not unify) staged
  # as acpmux; `-p acpmux --bin acpmux` is not what users run, and its musl-only DT_RELR link flag (build.rs) is one
  # this zig refuses ("unsupported linker extension flag: -z pack-relative-relocs", job of run 46100970694).
  build_log="$(mktemp)"
  if ! { cargo zigbuild --locked --release --target "$musl_target" -p cmux-tui --bin cmux-tui --bin cmux-tui-host \
      && cargo zigbuild --locked --release --target "$musl_target" -p acpmux-standalone --bin acpmux-standalone \
        $("$root/scripts/ci/acpmux-build-features.sh" crates/acpmux-standalone/Cargo.toml "$musl_target"); } >"$build_log" 2>&1; then
    grep -E -A30 '^error' "$build_log" | head -n 120 >&2 || tail -n 60 "$build_log" >&2
    exit 1
  fi
  tail -n 3 "$build_log"
  bin="$target/$musl_target/release"
  cp "$bin/acpmux-standalone" "$bin/acpmux"
else
  cargo build --locked --release -p acpmux --bin acpmux -p cmux-tui --bin cmux-tui --bin cmux-tui-host 2>&1 | tail -n 3
  bin="$target/release"
fi
echo "INFINITE-BUILD flavor=$([[ "$musl" == 1 ]] && echo musl || echo glibc) bin=$bin"
# build-only: the perf cron builds in a step of its own, so the build and the run each get its 30-minute cap.
[[ "$build_only" == 1 ]] && exit 0
cd "$root"
if [ -n "${FAST_CHECKS_OUT:-}" ]; then
  out="$FAST_CHECKS_OUT"
else
  out="$(mktemp -d)"
  trap 'rm -rf "$out"' EXIT
fi
status=0
ulimit -n 65536 2>/dev/null || ulimit -n "$(ulimit -Hn)" || true
if [[ "$live" == 1 ]]; then
  echo "INFINITE-LIVE counts=${live_counts:-$counts} head=$(git rev-parse HEAD) mem_gb=$(awk '/MemTotal/ {printf "%.0f", $2 / 1048576}' /proc/meminfo)"
  python3 scripts/measure/infinite-items.py --acpmux "$bin/acpmux" --tui "$bin/cmux-tui" \
    --counts "${live_counts:-$counts}" --days 0 --idle-child-secs=0 ${extra[@]+"${extra[@]}"} 2>&1 \
    | sed -u 's/^/LIVE /' || status=$?
fi
if [[ "$before" == own-exe ]]; then
  own_dir="$(mktemp -d)"
  cp "$bin/cmux-tui" "$own_dir/cmux-tui"
  echo "INFINITE-AB before=own-exe after=cmux-tui-host head=$(git rev-parse HEAD)"
  python3 scripts/measure/infinite-items.py --acpmux "$bin/acpmux" --tui "$own_dir/cmux-tui" \
    --counts "$counts" --days "$days" ${extra[@]+"${extra[@]}"} 2>&1 | sed -u 's/^/BEFORE /' || status=$?
  rm -rf "$own_dir"
elif [[ "$before" == hosts ]]; then
  echo "INFINITE-AB before=hosts after=product head=$(git rev-parse HEAD)"
  python3 scripts/measure/infinite-items.py --acpmux "$bin/acpmux" --tui "$bin/cmux-tui" \
    --terminal-host-model=hosts --counts "$counts" --days "$days" ${extra[@]+"${extra[@]}"} 2>&1 \
    | sed -u 's/^/BEFORE /' || status=$?
elif [[ "$before" == ref:* ]]; then
  if [[ "$musl" == 1 ]]; then
    echo "infinite-items-linux.sh: before=ref: builds REF for the host; drop musl=1" >&2
    exit 2
  fi
  ref="${before#ref:}"
  ab="$(mktemp -d)"
  # Each arm's three binaries side by side in a folder of its own: the daemon runs its hosts from the
  # cmux-tui-host beside it. The base's cmux-tui/ is put in place of this head's in this same checkout (a worktree
  # of a sparse checkout lacks files the crates read) and built into the same target folder, so only the changed
  # crates rebuild; this head's cmux-tui/ comes back after, and this head's harness runs both arms.
  mkdir "$ab/after" "$ab/before"
  cp "$target/release/acpmux" "$target/release/cmux-tui" "$target/release/cmux-tui-host" "$ab/after/"
  # --depth only in a checkout that is already shallow: a depth fetch in a full clone makes it shallow.
  depth=()
  [[ "$(git rev-parse --is-shallow-repository)" == true ]] && depth=(--depth=1)
  if ! git rev-parse --verify -q "$ref^{commit}" >/dev/null; then
    if [[ "$ref" =~ ^[0-9a-f]{4,39}$ ]]; then
      # GitHub fetches a commit only by its full SHA: an abbreviated one is looked up in the base branches'
      # recent history instead (the usual before=ref: is the merge base).
      git fetch -q ${depth[@]+"${depth[@]/--depth=1/--depth=500}"} origin feat-cmux-next main
      git rev-parse --verify -q "$ref^{commit}" >/dev/null || {
        echo "infinite-items-linux.sh: $ref is in neither feat-cmux-next's nor main's last 500 commits; give the full SHA" >&2
        exit 2
      }
    else
      # A fleet step's source has no origin: the helper falls back to the public repository.
      source "$root/scripts/measure/fetch-commit.sh"
      measure_fetch_commit "$root" "$ref" || exit 2
    fi
  fi
  base_sha="$(git rev-parse --verify -q "$ref^{commit}" || git rev-parse FETCH_HEAD)"
  if [ "$(git rev-parse "$base_sha:ghostty-next")" != "$(git rev-parse HEAD:ghostty-next)" ]; then
    echo "infinite-items-linux.sh: $base_sha pins another ghostty-next; before=ref: needs the same pin" >&2
    exit 2
  fi
  trap 'git restore --source=HEAD --staged --worktree -- cmux-tui; rm -rf "$ab"; [ -n "${FAST_CHECKS_OUT:-}" ] || rm -rf "$out"' EXIT
  git restore --source="$base_sha" --staged --worktree -- cmux-tui
  base_status=0
  (cd "$root/cmux-tui" && cargo build --locked --release -p acpmux --bin acpmux -p cmux-tui --bin cmux-tui \
    --bin cmux-tui-host 2>&1 | tail -n 3; exit "${PIPESTATUS[0]}") || base_status=$?
  git restore --source=HEAD --staged --worktree -- cmux-tui
  if [ "$base_status" != 0 ]; then
    echo "infinite-items-linux.sh: the build of $base_sha failed ($base_status)" >&2
    exit 1
  fi
  cp "$target/release/acpmux" "$target/release/cmux-tui" "$target/release/cmux-tui-host" "$ab/before/"
  echo "INFINITE-AB before=$base_sha after=$(git rev-parse HEAD) repeat=$repeat counts=$counts days=$days"
  for i in $(seq 1 "$repeat"); do
    for arm in before after; do
      tag="$(echo "$arm" | tr a-z A-Z) r$i"
      python3 scripts/measure/infinite-items.py --acpmux "$ab/$arm/acpmux" --tui "$ab/$arm/cmux-tui" \
        --counts "$counts" --days "$days" ${extra[@]+"${extra[@]}"} 2>&1 | sed -u "s/^/$tag /" || status=$?
    done
  done
  rm -rf "$ab"
  exit "$status"
elif [ -n "$before" ]; then
  echo "infinite-items-linux.sh: unknown before=$before (own-exe, hosts, ref:REF)" >&2
  exit 2
fi
# The malloc settings of the glibc-* arms, as the environment glibc reads them: MALLOC_ARENA_MAX wins over acpmux's
# own arena cap (malloc_arenas.rs), and a tunable fixes its threshold (glibc then stops moving it on its own).
# glibc is the build's defaults.
alloc_env() {
  local thr="glibc.malloc.mmap_threshold=131072:glibc.malloc.trim_threshold=131072"
  case "$1" in
    glibc) echo "" ;;
    glibc-a2) echo "MALLOC_ARENA_MAX=2" ;;
    glibc-a4) echo "MALLOC_ARENA_MAX=4" ;;
    glibc-a16) echo "MALLOC_ARENA_MAX=16" ;;
    glibc-notrim) echo "CMUX_MALLOC_QUIET_TRIM=0" ;;
    glibc-thr) echo "GLIBC_TUNABLES=$thr" ;;
    glibc-a4thr) echo "MALLOC_ARENA_MAX=4 GLIBC_TUNABLES=$thr" ;;
    # The daemon's tokio workers (one per core by default): tokio reads TOKIO_WORKER_THREADS when the
    # runtime sets no count, as the daemon's does (acpmux cli/entry.rs runtime_with).
    glibc-w2) echo "TOKIO_WORKER_THREADS=2" ;;
    glibc-w4) echo "TOKIO_WORKER_THREADS=4" ;;
    glibc-w8) echo "TOKIO_WORKER_THREADS=8" ;;
    *) echo "infinite-items-linux.sh: unknown glibc arm $1" >&2; exit 2 ;;
  esac
}
if [[ "$alloc_ab" == 1 ]]; then
  ab="$(mktemp -d)"
  trap 'rm -rf "$ab"; [ -n "${FAST_CHECKS_OUT:-}" ] || rm -rf "$out"' EXIT
  # The default build is glibc's (a gnu target); every other allocator is a feature build of acpmux alone.
  mkdir "$ab/system"
  cp "$bin/acpmux" "$bin/cmux-tui" "$bin/cmux-tui-host" "$ab/system/"
  for arm in $alloc_arms; do
    case "$arm" in
      system|glibc) continue ;;
      glibc-*)
        # acpmux alone gets the setting (cmux-tui keeps its own): a wrapper that execs the glibc binary.
        mkdir -p "$ab/$arm"
        cp "$ab/system/cmux-tui" "$ab/system/cmux-tui-host" "$ab/$arm/"
        printf '#!/bin/sh\nexec env %s "%s" "$@"\n' "$(alloc_env "$arm")" "$ab/system/acpmux" >"$ab/$arm/acpmux"
        chmod +x "$ab/$arm/acpmux"
        echo "INFINITE-ALLOC-BUILD arm=$arm env=$(alloc_env "$arm")"
        continue ;;
      dhat) feature=dhat-heap ;;
      mimalloc2) feature=mimalloc-v2 ;;
      mimalloc) feature=mimalloc-gnu ;;
      *) echo "infinite-items-linux.sh: unknown alloc arm $arm" >&2; exit 2 ;;
    esac
    [ -d "$ab/$arm" ] && continue
    mkdir "$ab/$arm"
    t0=$SECONDS
    (cd "$root/cmux-tui" && cargo build --locked --release -p acpmux --bin acpmux --features "$feature" 2>&1 | tail -n 3
     exit "${PIPESTATUS[0]}")
    cp "$bin/acpmux" "$ab/$arm/acpmux"
    cp "$ab/system/cmux-tui" "$ab/system/cmux-tui-host" "$ab/$arm/"
    echo "INFINITE-ALLOC-BUILD arm=$arm feature=$feature seconds=$((SECONDS - t0))"
  done
  echo "INFINITE-ALLOC arms=${alloc_arms// /,} caps=${alloc_caps:-as-given} repeat=$repeat counts=$counts days=$days budget_s=$alloc_budget head=$(git rev-parse HEAD) built_s=$((SECONDS - started_at))"
  round_s=0
  for r in $(seq 1 "$repeat"); do
    # Round 1 always runs: a job that only built measured nothing.
    if (( r > 1 && SECONDS - started_at + round_s > alloc_budget )); then
      echo "INFINITE-ALLOC-CUT before r$r: $((SECONDS - started_at)) s spent, the last round took ${round_s} s, budget ${alloc_budget} s"
      break
    fi
    t0=$SECONDS
    for cap in ${alloc_caps:-as-given}; do
    capflag=(); captag=""
    if [[ "$cap" != as-given ]]; then
      captag="@$([[ "$cap" == off ]] && echo off || echo "cap$cap")"
      [[ "$cap" == off ]] || capflag=(--resident-cap "$cap")
    fi
    for arm in $alloc_arms; do
      bin_arm="$arm"
      [[ "$arm" == glibc ]] && bin_arm=system
      # Every arm answers _acpmux/heap_profile after its last sample: dhat's live bytes, glibc's mallinfo2
      # (system), nothing more for mimalloc. dhat records slowly, so it also writes at the budget's end
      # (--heap-profile-at) and its run is cut there: what it held then, at the count it reached.
      profile=(--heap-profile); limit=()
      if [[ "$arm" == dhat ]]; then
        left=$((alloc_budget - (SECONDS - started_at)))
        profile+=(--heap-profile-at "$(( $(date +%s) + left - 240 ))"); limit=(timeout --signal=KILL "$((left - 120))")
      fi
      dhat_out="$ab/dhat-r$r.json"
      ACPMUX_DHAT_OUT="$([[ "$arm" == dhat ]] && echo "$dhat_out")" \
        ${limit[@]+"${limit[@]}"} python3 scripts/measure/infinite-items.py --acpmux "$ab/$bin_arm/acpmux" --tui "$ab/$bin_arm/cmux-tui" \
        --counts "$counts" --days "$days" ${capflag[@]+"${capflag[@]}"} ${profile[@]+"${profile[@]}"} ${extra[@]+"${extra[@]}"} 2>&1 \
        | sed -u "s/^/ALLOC arm=$arm$captag r$r /" || status=$?
      if [[ "$arm" == dhat ]]; then
        if [ -f "$dhat_out" ]; then
          python3 scripts/measure/dhat-top.py "$dhat_out" 30 | sed -u "s/^/ALLOC arm=dhat r$r /"
          rm -f "$dhat_out"
        else
          echo "ALLOC arm=dhat r$r DHAT none: $dhat_out"
        fi
      fi
    done
    done
    round_s=$((SECONDS - t0))
    echo "INFINITE-ALLOC-ROUND r$r seconds=$round_s"
  done
  exit "$status"
fi
# cap_ab=N: ACPMUX_RESIDENT_CAP off against N, REPEAT times each, interleaved (off, N, off, N, ...) on this
# runner with this build; each INFINITE line carries its arm and repeat (CAPAB arm=off|capN rI).
if [[ -n "$cap_ab" ]]; then
  for r in $(seq 1 "$repeat"); do
    for arm in off "cap$cap_ab"; do
      flag=(); [[ "$arm" == off ]] || flag=(--resident-cap "$cap_ab")
      python3 scripts/measure/infinite-items.py --acpmux "$bin/acpmux" --tui "$bin/cmux-tui" \
        --counts "$counts" --days "$days" ${flag[@]+"${flag[@]}"} ${extra[@]+"${extra[@]}"} 2>&1 \
        | sed -u "s/^/CAPAB arm=$arm r$r /" || status=$?
    done
  done
  exit "$status"
fi
python3 scripts/measure/infinite-items.py --acpmux "$bin/acpmux" --tui "$bin/cmux-tui" \
  --counts "$counts" --days "$days" --out "$out/infinite-items.json" ${extra[@]+"${extra[@]}"} || status=$?
if [[ "$freed" == 1 ]]; then
  python3 scripts/measure/infinite-items.py --acpmux "$bin/acpmux" --tui "$bin/cmux-tui" \
    --counts "$counts" --days "$days" --park-idle ${extra[@]+"${extra[@]}"} 2>&1 | sed -u 's/^/FREED /' || status=$?
fi
if [[ "$pages" == 1 ]]; then
  cd "$root/webviews"
  if command -v bun >/dev/null; then
    [ -d node_modules ] || bun install --frozen-lockfile >/dev/null 2>&1 || bun install >/dev/null
    # The pages a renderer holds when every chat but the newest is released (the app's idle release), at each
    # count: the renderer side of the same items.
    RELEASE=1 REOPEN=10 bun bench/chat-pages-memory.bench.ts "${page_counts:-10,100}" 20 || status=$?
  else
    echo "infinite-items-linux.sh: no bun; pages skipped" >&2
  fi
fi
exit "$status"
