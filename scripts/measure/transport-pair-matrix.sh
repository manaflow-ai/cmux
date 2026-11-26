#!/usr/bin/env bash
# The transport pair matrix (Leo, relayed 2026-11-24: "ios to mac to ios to linux to mac to linux to mac to mac to
# anywhere and everywhere"): every client->host pair (ios-mac, ios-linux, mac-mac, mac-linux), direct and through a
# relay, under loss, latency, a cell/Wi-Fi handoff, sleep/wake, relay failover and a 60-minute session, each on an
# idle and a loaded host. A cell: time to first content, resume after the change, delta bytes, failures per n.
# Offline: real Rust clients and daemons in one process behind cmux-fault's seeded shapers, a fake agent, no network.
#
#   scripts/measure/transport-pair-matrix.sh [pairs=ios-mac,ios-linux,mac-mac,mac-linux,rtt] [paths=direct,relay]
#     [conditions=loss,latency,handoff,sleep,failover,long] [loads=idle,duress] [n=5] [seed=0] [long_minutes=60]
#     [out=PATH.md]
#   cmux-ci test --timeout 3000 -- bash scripts/measure/transport-pair-matrix.sh pairs=ios-mac n=5   # one CI runner per pair
# All four pairs plus the round-trip bench in one job take more than 55 minutes at n=3 (run 45400745409); submit one
# pair per job and merge their lines.txt with the report script.
#
# The benches (each prints PAIRCELL lines; the spec is in transport-pair-matrix-report.py's header):
#   ios-mac:   cmux-next-ios/rust/crates/cmux-mobile-host/tests/pair_matrix_ios_mac.rs
#   ios-linux: cmux-next-ios/rust/crates/cmux-mobile-host/tests/pair_matrix_ios_linux.rs
#   mac-mac, mac-linux: cmux-tui/crates/acpmux/tests/pair_matrix_desktop.rs (PAIRMATRIX_PAIR)
# A bench that is not in this tree yet prints a PAIRCELL-NA row saying so. The runner's OS is the host OS of
# every row it measures; merge a Linux and a macOS run's lines.txt with the report script.
set -euo pipefail
trap 'echo "transport-pair-matrix.sh: line $LINENO exited $? ($BASH_COMMAND)" >&2' ERR

pairs="ios-mac,ios-linux,mac-mac,mac-linux,rtt" paths="direct,relay" conditions="loss,latency,handoff,sleep,failover,long"
loads="idle,duress" n=5 seed=0 long_minutes=60 out="" before_ref=""
for kv in "$@"; do
  case "$kv" in
    pairs=*) pairs="${kv#*=}" ;;
    paths=*) paths="${kv#*=}" ;;
    conditions=*) conditions="${kv#*=}" ;;
    loads=*) loads="${kv#*=}" ;;
    n=*) n="${kv#*=}" ;;
    seed=*) seed="${kv#*=}" ;;
    long_minutes=*) long_minutes="${kv#*=}" ;;
    out=*) out="${kv#*=}" ;;
    before_ref=*) before_ref="${kv#*=}" ;;
    *) echo "transport-pair-matrix.sh: unknown arg '$kv' (pairs=, paths=, conditions=, loads=, n=, seed=, long_minutes=, out=, before_ref=)" >&2; exit 2 ;;
  esac
done
[[ "$pairs" =~ ^(ios-mac|ios-linux|mac-mac|mac-linux|rtt)(,(ios-mac|ios-linux|mac-mac|mac-linux|rtt))*$ ]] || { echo "transport-pair-matrix.sh: pairs=ios-mac,ios-linux,mac-mac,mac-linux,rtt (rtt: the round-trip audit bench)" >&2; exit 2; }
[[ "$paths" =~ ^(direct|relay)(,(direct|relay))?$ ]] || { echo "transport-pair-matrix.sh: paths=direct,relay" >&2; exit 2; }
[[ "$conditions" =~ ^(loss|latency|handoff|sleep|failover|long)(,(loss|latency|handoff|sleep|failover|long))*$ ]] || { echo "transport-pair-matrix.sh: conditions=loss,latency,handoff,sleep,failover,long" >&2; exit 2; }
[[ "$loads" =~ ^(idle|duress)(,(idle|duress))?$ ]] || { echo "transport-pair-matrix.sh: loads=idle,duress" >&2; exit 2; }
[[ "$n" =~ ^[1-9][0-9]{0,2}$ ]] || { echo "transport-pair-matrix.sh: n is 1-999" >&2; exit 2; }
[[ "$seed" =~ ^[0-9]{1,9}$ ]] || { echo "transport-pair-matrix.sh: seed is a number" >&2; exit 2; }
[[ -z "$before_ref" || "$before_ref" =~ ^[0-9a-f]{7,40}$ ]] || { echo "transport-pair-matrix.sh: before_ref is a commit sha" >&2; exit 2; }
[[ "$long_minutes" =~ ^[1-9][0-9]{0,3}$ ]] || { echo "transport-pair-matrix.sh: long_minutes is 1-9999" >&2; exit 2; }

root="$(git rev-parse --show-toplevel)"
cd "$root"
export PATH="$HOME/.cargo/bin:$PATH"
command -v cargo >/dev/null || ./scripts/install-rust-ci.sh
export PATH="$HOME/.cargo/bin:$PATH"
command -v clang >/dev/null || { sudo apt-get update -qq && sudo apt-get install -y -qq clang libclang-dev pkg-config; }
work="$root/.build/transport-pair-matrix"
rm -rf "$work"
mkdir -p "$work"
host_os="$(uname -s | tr '[:upper:]' '[:lower:]' | sed 's/darwin/macos/')"
echo "PAIRMATRIX-MACHINE host=$(hostname) os=$(uname -sr) host_os=$host_os cores=$(getconf _NPROCESSORS_ONLN) rev=$(git rev-parse HEAD) load=\"$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null || sysctl -n vm.loadavg)\""

export PAIRMATRIX_N="$n" PAIRMATRIX_SEED_BASE="$seed" PAIRMATRIX_CONDITIONS="$conditions" PAIRMATRIX_LOADS="$loads" \
  PAIRMATRIX_PATHS="$paths" PAIRMATRIX_LONG_MINUTES="$long_minutes" PAIRMATRIX_HOST_OS="$host_os"

# bench PAIR WORKSPACE CRATE TEST [FEATURES]: one pair's bench; its PAIRCELL lines into lines.txt.
bench() {
  local pair="$1" workspace="$2" crate="$3" test="$4" features="${5:-}" log="$work/$tag$1.log" code=0
  local file="$workspace/crates/$crate/tests/$test.rs"
  if [[ ! -f "$file" ]]; then
    echo "PAIRCELL-NA {\"pair\":\"$pair\",\"path\":\"*\",\"condition\":\"*\",\"load\":\"*\",\"metric\":\"*\",\"reason\":\"no bench at this ref ($file)\"}" | tee -a "$work/lines.txt"
    return 0
  fi
  [[ "$workspace" == */cmux-tui || "$workspace" == cmux-tui ]] && (cd "$workspace/.." && git submodule update --init --depth 1 ghostty-next >/dev/null)
  # hub-carrier builds libghostty-vt with zig (cmux-remote); a fast-checks runner has none (run 45426933150).
  if [[ "$features" == *hub-carrier* ]] && ! command -v zig >/dev/null && [[ -z "${CMUX_ZIG:-}" ]]; then
    # The workspace's own tree reads the zig pin: a before_ref worktree's ghostty-next is checked out
    # above, this checkout's not yet (jobs b72ee236, f763318d: "Ghostty Zig manifest not found").
    local tree; tree="$(git -C "$workspace" rev-parse --show-toplevel)"
    CMUX_ZIG="$(MEDIA_ZIG_CACHE="$root/.build/transport-pair-matrix-zig" "$tree/scripts/ci/media_pinned_zig.sh" "$tree")"
    export CMUX_ZIG PATH="$(dirname "$CMUX_ZIG"):$PATH"
  fi
  # The libghostty-vt build as feat-parity-check.sh runs it in CI: ghostty-next's zig pin, a portable CPU.
  [[ "$features" == *hub-carrier* ]] && export GHOSTTY_ZIG_SOURCE=ghostty-next CMUX_GHOSTTY_VT_ZIG_CPU="${CMUX_GHOSTTY_VT_ZIG_CPU:-baseline}"
  # Build first, timed, so a run that hits its bound says whether the build or a cell took the time
  # (run 45428699703: 49 min silent after the zig install, no cell).
  local started=$SECONDS
  (cd "$workspace" && CARGO_TARGET_DIR="$work/target-${workspace//\//-}" \
    cargo test --release --locked -p "$crate" ${features:+--features "$features"} --test "$test" --no-run 2>&1 | tee "$work/$tag$pair.build.log" |
    { sed -un -e "s/^/PAIRMATRIX-BUILD $tag$pair /p" | grep --line-buffered -E 'PAIRMATRIX-BUILD [^ ]+ +(Compiling (acpmux|cmux|ghostty|libghostty)|Finished|error)' || true; }) || code=$?
  echo "PAIRMATRIX-BUILD-DONE $tag$pair exit=$code seconds=$((SECONDS - started))"
  (( code == 0 )) || { tail -n 40 "$work/$tag$pair.build.log" | sed "s/^/PAIRMATRIX-LOG $pair /"; return 1; }
  started=$SECONDS
  (cd "$workspace" && CARGO_TARGET_DIR="$work/target-${workspace//\//-}" PAIRMATRIX_PAIR="$pair" \
    cargo test --release --locked -p "$crate" ${features:+--features "$features"} --test "$test" -- --ignored --nocapture --test-threads 1 2>&1 | tee "$log" |
    { sed -un -e "s/^PAIRCELL/PAIRMATRIX-LIVE $tag""PAIRCELL/p" -e "s/^PAIRKINDS/PAIRMATRIX-LIVE $tag""PAIRKINDS/p" -e "s/^PAIRTIMELINE/PAIRMATRIX-LIVE $tag""PAIRTIMELINE/p" -e "/^test .* \.\.\. /s/^/PAIRMATRIX-LIVE $tag/p" || true; }) || code=$?
  echo "PAIRMATRIX-TEST-DONE $tag$pair exit=$code seconds=$((SECONDS - started))"
  grep -oE 'PAIRCELL(-NA)? \{.*' "$log" >>"$work/${tag}lines.txt" || true  # libtest can print a line after its "test ... " prefix
  echo "PAIRMATRIX-STATUS $tag$pair exit=$code log=$log"
  if (( code != 0 )); then
    tail -n 40 "$log" | sed "s/^/PAIRMATRIX-LOG $pair /"
    return 1
  fi
}

: >"$work/lines.txt"
# Copy what there is even when the run's bound kills it mid-bench.
copy_out() { [[ -z "${FAST_CHECKS_OUT:-}" ]] || { mkdir -p "$FAST_CHECKS_OUT"; cp "$work"/*.txt "$work"/*.log "$FAST_CHECKS_OUT/" 2>/dev/null || true; }; }
trap copy_out EXIT
trap 'copy_out; exit 124' TERM INT
# A fixed CPU canary beside every run (cmuxterm-hq docs/handbook/timing-on-a-busy-host.md): the same work each
# time, before and after the benches, so two runs' times are compared only at about the same canary.
canary() { python3 -I -c 'import sys, time
t = time.perf_counter(); c = time.process_time(); s = 0
for i in range(5000000): s += i
print("PAIRMATRIX-CANARY %s wall_ms=%.1f cpu_ms=%.1f" % (sys.argv[1], (time.perf_counter() - t) * 1e3, (time.process_time() - c) * 1e3))' "$1"; }
status=0
IFS=, read -r -a pair_list <<<"$pairs"
# Each pair's benches from the tree at `$1` ("" is this checkout), lines tagged `$tag`.
pairs_at() {
  local at="${1:-.}"
  for pair in "${pair_list[@]}"; do
    case "$pair" in
      ios-mac) bench ios-mac "$at/cmux-next-ios/rust" cmux-mobile-host pair_matrix_ios_mac || status=1 ;;
      ios-linux) bench ios-linux "$at/cmux-next-ios/rust" cmux-mobile-host pair_matrix_ios_linux || status=1 ;;
      mac-mac) bench mac-mac "$at/cmux-tui" acpmux pair_matrix_desktop hub-carrier || status=1 ;;
      mac-linux) bench mac-linux "$at/cmux-tui" acpmux pair_matrix_desktop hub-carrier || status=1 ;;
    esac
  done
}
tag=""
# before_ref=SHA: the same benches at that commit first, in this job, beside the same canary, so a
# before row and this head's after row are taken on one host at about the same load (the handbook
# page above). Its lines are tagged "before-" and go to before-lines.txt, not this head's report.
if [[ -n "$before_ref" ]]; then
  git cat-file -e "$before_ref^{commit}" 2>/dev/null || git fetch -q --depth 1 origin "$before_ref"
  git worktree add -q --detach "$work/before" "$before_ref"
  echo "PAIRMATRIX-BEFORE ref=$(git -C "$work/before" rev-parse HEAD)"
  canary before-start
  tag="before-"
  pairs_at "$work/before"
  tag=""
  canary before-end
fi
canary before
pairs_at ""
canary after

# Item 7, the round-trip audit: its bench prints ROUNDTRIP lines; its report writes the second table.
rtt_md=""
if [[ ",$pairs," != *,rtt,* ]]; then
  :
elif [[ -f cmux-tui/crates/acpmux/tests/round_trip_audit.rs && -f scripts/measure/round-trip-audit-report.py ]]; then
  bench rtt cmux-tui acpmux round_trip_audit || status=1
  rtt_md="$work/round-trip-audit.md"
  python3 -I "$root/scripts/measure/round-trip-audit-report.py" "$work/rtt.log" --out "$rtt_md" || status=1
  [[ -f "$rtt_md" ]] && sed 's/^/ROUNDTRIP-TABLE /' "$rtt_md"
else
  echo "ROUNDTRIP-NA no round-trip bench at this ref (cmux-tui/crates/acpmux/tests/round_trip_audit.rs)"
fi

command="scripts/measure/transport-pair-matrix.sh pairs=$pairs paths=$paths conditions=$conditions loads=$loads n=$n seed=$seed long_minutes=$long_minutes${out:+ out=$out}  # at $(git rev-parse --short=12 HEAD), host_os=$host_os"
python3 "$root/scripts/measure/transport-pair-matrix-report.py" "$work/lines.txt" \
  --markdown "$work/report.md" --json "$work/report.json" --command "$command"
sed 's/^/PAIRMATRIX-TABLE /' "$work/report.md"
[[ -z "$out" ]] || { cp "$work/report.md" "$out"; [[ -z "$rtt_md" || ! -f "$rtt_md" ]] || cp "$rtt_md" "$(dirname "$out")/round-trip-audit.md"; }
if [[ -n "${FAST_CHECKS_OUT:-}" ]]; then
  mkdir -p "$FAST_CHECKS_OUT"
  cp "$work/report.json" "$work/report.md" "$work/lines.txt" "$work"/*.log ${rtt_md:+"$rtt_md"} "$FAST_CHECKS_OUT/" 2>/dev/null || true
fi
exit "$status"
