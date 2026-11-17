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
# Builds release acpmux and cmux-tui (cmux-tui/), then prints INFINITE and PERF_ROW lines.
set -euo pipefail
counts="10,100,1000"
days=3
pages=1
page_counts=""
build_only=0
before=""
repeat=1
extra=()
for arg in "$@"; do
  case "$arg" in
    counts=*) counts="${arg#counts=}" ;;
    days=*) days="${arg#days=}" ;;
    pages=*) pages="${arg#pages=}" ;;
    build-only) build_only=1 ;;
    before=*) before="${arg#before=}" ;;
    repeat=*) repeat="${arg#repeat=}" ;;
    page_counts=*) page_counts="${arg#page_counts=}" ;;
    --*) extra+=("$arg") ;;
    *) echo "infinite-items-linux.sh: unknown argument $arg" >&2; exit 2 ;;
  esac
done
root="$(git rev-parse --show-toplevel)"
cd "$root"
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
cd "$root/cmux-tui"
# cmux-tui-host: the slim terminal host the daemon runs its hosts from when it sits beside it (host_exe.rs).
cargo build --locked --release -p acpmux --bin acpmux -p cmux-tui --bin cmux-tui --bin cmux-tui-host 2>&1 | tail -n 3
# build-only: the perf cron builds in a step of its own, so the build and the run each get its 30-minute cap.
[[ "$build_only" == 1 ]] && exit 0
target="$(cargo metadata --locked --no-deps --format-version 1 | python3 -c 'import json,sys; print(json.load(sys.stdin)["target_directory"])')"
cd "$root"
if [ -n "${FAST_CHECKS_OUT:-}" ]; then
  out="$FAST_CHECKS_OUT"
else
  out="$(mktemp -d)"
  trap 'rm -rf "$out"' EXIT
fi
status=0
ulimit -n 65536 2>/dev/null || ulimit -n "$(ulimit -Hn)" || true
if [[ "$before" == own-exe ]]; then
  own_dir="$(mktemp -d)"
  cp "$target/release/cmux-tui" "$own_dir/cmux-tui"
  echo "INFINITE-AB before=own-exe after=cmux-tui-host head=$(git rev-parse HEAD)"
  python3 scripts/measure/infinite-items.py --acpmux "$target/release/acpmux" --tui "$own_dir/cmux-tui" \
    --counts "$counts" --days "$days" ${extra[@]+"${extra[@]}"} 2>&1 | sed -u 's/^/BEFORE /' || status=$?
  rm -rf "$own_dir"
elif [[ "$before" == ref:* ]]; then
  ref="${before#ref:}"
  ab="$(mktemp -d)"
  # Each arm's three binaries side by side in a folder of its own: the daemon runs its hosts from the
  # cmux-tui-host beside it. The base builds into the same target folder, so only the workspace crates rebuild.
  mkdir "$ab/after" "$ab/before"
  cp "$target/release/acpmux" "$target/release/cmux-tui" "$target/release/cmux-tui-host" "$ab/after/"
  git rev-parse --verify -q "$ref^{commit}" >/dev/null || git fetch -q --depth 1 origin "$ref"
  base_sha="$(git rev-parse --verify -q "$ref^{commit}" || git rev-parse FETCH_HEAD)"
  git worktree add -q --detach "$ab/src" "$base_sha"
  ghostty_src="${CMUX_GHOSTTY_SRC:-}"
  if [ "$(git -C "$ab/src" rev-parse HEAD:ghostty-next)" == "$(git rev-parse HEAD:ghostty-next)" ]; then
    ghostty_src="${ghostty_src:-$root/ghostty-next}"
  else
    git -C "$ab/src" submodule update --init --depth 1 ghostty-next
  fi
  (cd "$ab/src/cmux-tui" && CMUX_GHOSTTY_SRC="$ghostty_src" CARGO_TARGET_DIR="$target" cargo build --locked --release \
    -p acpmux --bin acpmux -p cmux-tui --bin cmux-tui --bin cmux-tui-host 2>&1 | tail -n 3)
  cp "$target/release/acpmux" "$target/release/cmux-tui" "$target/release/cmux-tui-host" "$ab/before/"
  git worktree remove --force "$ab/src"
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
  echo "infinite-items-linux.sh: unknown before=$before (own-exe, ref:REF)" >&2
  exit 2
fi
python3 scripts/measure/infinite-items.py --acpmux "$target/release/acpmux" --tui "$target/release/cmux-tui" \
  --counts "$counts" --days "$days" --out "$out/infinite-items.json" ${extra[@]+"${extra[@]}"} || status=$?
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
