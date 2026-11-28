#!/usr/bin/env bash
# The shipped Linux acpmux's allocator, A/B in one job (goal infinite-items-flat): the packages are static musl
# builds on mimalloc v3 (cmux-tui-build-package.yml, cargo-zigbuild, x86_64-unknown-linux-musl), so the arms are
#   mimalloc     the musl build as it ships (tune_allocator: purge_delay 0, arena_eager_commit 0)
#   mi-<name>    the same binary with mimalloc options from the environment (MIMALLOC_*, read at load; the two
#                tune_allocator sets win over theirs), one arm per entry of mi_arms below
#   mallocng     a musl build on musl's own malloc (bench feature musl-malloc)
#   glibc        the gnu build on glibc's malloc (cmux#58257), for reference
# Every acpmux runs beside one gnu cmux-tui and cmux-tui-host, so only the daemon's allocator differs.
# Phase 1, parked: infinite-items.py at n=COUNT, --resident-cap CAP, --park-idle, days=1, every arm, REPEAT rounds
# interleaved (MAB-P lines). Phase 2, streaming: coord-sim for SECONDS (fanin off) against mimalloc, the mi-* arm
# with the lowest median parked acpmux PSS, mallocng and glibc, REPEAT rounds interleaved (MAB-S lines, with the
# daemon's RSS at fixed times from proc.ndjson so a slope that levels off shows). All builds: no LTO, 16 codegen
# units, a target directory of their own (the heap is the program's data, not its code).
#   cmux-ci test -- bash -c 'scripts/measure/alloc-musl-ab.sh [repeat=3] [count=1000] [cap=64] [seconds=600]
#     [budget=10100] [stream=1] [open_probe=32] [arms=mimalloc,mi-lean,...]'
set -euo pipefail
repeat=3
count=1000
cap=64
seconds=600
budget=11000
stream=1
open_probe=32
only=""
for arg in "$@"; do
  case "$arg" in
    repeat=*) repeat="${arg#repeat=}" ;;
    count=*) count="${arg#count=}" ;;
    cap=*) cap="${arg#cap=}" ;;
    seconds=*) seconds="${arg#seconds=}" ;;
    budget=*) budget="${arg#budget=}" ;;
    stream=*) stream="${arg#stream=}" ;;
    open_probe=*) open_probe="${arg#open_probe=}" ;;
    arms=*) only="${arg#arms=}" ;;
    *) echo "alloc-musl-ab.sh: unknown argument $arg" >&2; exit 2 ;;
  esac
done
# mimalloc v3 (libmimalloc-sys 0.1.49) options aimed at the pages it keeps: page_full_retain (free small pages kept
# per size class per thread heap, 2), generic_collect (collect a thread heap every N generic calls, 10000),
# arena_reserve (each arena's reservation, 1 GiB), allow_thp (transparent huge pages, 1). purge_decommits is 1 by
# default (a purge decommits); v3 has no page_reset or segment_reset (deprecated), purge_delay is their successor.
mi_arms=(
  "retain0:MIMALLOC_PAGE_FULL_RETAIN=0"
  "nothp:MIMALLOC_ALLOW_THP=0"
  "lean:MIMALLOC_PAGE_FULL_RETAIN=0 MIMALLOC_GENERIC_COLLECT=1000 MIMALLOC_ARENA_RESERVE=64MiB MIMALLOC_PURGE_DECOMMITS=1"
  "leanthp:MIMALLOC_PAGE_FULL_RETAIN=0 MIMALLOC_GENERIC_COLLECT=1000 MIMALLOC_ARENA_RESERVE=64MiB MIMALLOC_PURGE_DECOMMITS=1 MIMALLOC_ALLOW_THP=0"
)
started_at=$SECONDS
root="$(git rev-parse --show-toplevel)"
# A bare runner, as infinite-items-linux.sh sets it up: the ghostty-next submodule (a fast-checks snapshot leaves it
# empty), the pinned Rust and Zig and the native build tools.
cd "$root"
[ -f ghostty-next/build.zig ] || [ -n "${CMUX_GHOSTTY_SRC:-}" ] || git submodule update --init --depth 1 ghostty-next
command -v cargo >/dev/null || ./scripts/install-rust-ci.sh
if ! command -v zig >/dev/null && [ -z "${ZIG:-}${CMUX_ZIG:-}" ]; then
  zig_env="$(mktemp)"
  GHOSTTY_ZIG_SOURCE=ghostty-next GITHUB_ENV="$zig_env" GITHUB_PATH=/dev/null ./scripts/install-zig-ci.sh
  zig_line="$(grep '^CMUX_ZIG=' "$zig_env" | tail -n 1 || true)"
  rm -f "$zig_env"
  [ -z "$zig_line" ] || export "$zig_line"
fi
command -v clang >/dev/null || { sudo apt-get update -qq && sudo apt-get install -y -qq clang libclang-dev pkg-config; }
export PATH="$HOME/.cargo/bin:$PATH"
export CARGO_PROFILE_RELEASE_LTO=false CARGO_PROFILE_RELEASE_CODEGEN_UNITS=16
export CARGO_TARGET_DIR="${RUNNER_TEMP:-/tmp}/alloc-musl-ab-target"
ab="$(mktemp -d)"
trap 'rm -rf "$ab"' EXIT
musl_target=x86_64-unknown-linux-musl
cd "$root/cmux-tui"
t0=$SECONDS
cargo build --locked --release -p acpmux --bin acpmux -p cmux-tui --bin cmux-tui --bin cmux-tui-host 2>&1 | tail -n 3
mkdir "$ab/glibc"
cp "$CARGO_TARGET_DIR/release/acpmux" "$CARGO_TARGET_DIR/release/cmux-tui" "$CARGO_TARGET_DIR/release/cmux-tui-host" "$ab/glibc/"
echo "MAB-BUILD arm=glibc seconds=$((SECONDS - t0))"
# shellcheck source=../lib/rust-targets.sh
source "$root/scripts/lib/rust-targets.sh"
ensure_rust_targets "$musl_target" >/dev/null
command -v cargo-zigbuild >/dev/null || cargo install --locked cargo-zigbuild@0.20.0 2>&1 | tail -n 1
if ! command -v zig >/dev/null && [ -n "${CMUX_ZIG:-}" ]; then export CARGO_ZIGBUILD_ZIG_PATH="$CMUX_ZIG"; fi
for arm in mimalloc mallocng; do
  feat=(); [[ "$arm" == mallocng ]] && feat=(--features musl-malloc)
  t0=$SECONDS
  cargo zigbuild --locked --release --target "$musl_target" -p acpmux --bin acpmux ${feat[@]+"${feat[@]}"} 2>&1 | tail -n 3
  mkdir "$ab/$arm"
  cp "$CARGO_TARGET_DIR/$musl_target/release/acpmux" "$ab/$arm/"
  cp "$ab/glibc/cmux-tui" "$ab/glibc/cmux-tui-host" "$ab/$arm/"
  echo "MAB-BUILD arm=$arm seconds=$((SECONDS - t0)) file=$(file -b "$ab/$arm/acpmux" | cut -d, -f1-5 | tr ' ' _)" \
    "mimalloc_syms=$(grep -c mi_option_set "$ab/$arm/acpmux" || true)"
done
arms=(mimalloc)
for spec in "${mi_arms[@]}"; do
  name="mi-${spec%%:*}"; envs="${spec#*:}"
  # The wrapper execs the musl binary, which runs its hosts from beside itself ($ab/mimalloc).
  mkdir "$ab/$name"
  printf '#!/bin/sh\nexec env %s "%s" "$@"\n' "$envs" "$ab/mimalloc/acpmux" >"$ab/$name/acpmux"
  chmod +x "$ab/$name/acpmux"
  cp "$ab/glibc/cmux-tui" "$ab/$name/"
  echo "MAB-ARM arm=$name env=$envs"
  arms+=("$name")
done
arms+=(mallocng glibc)
# arms=a,b,... keeps only those (a follow-up job on fewer arms).
if [[ -n "$only" ]]; then IFS=, read -r -a arms <<<"$only"; fi
cd "$root"
ulimit -n 65536 2>/dev/null || ulimit -n "$(ulimit -Hn)" || true
echo "MAB arms=${arms[*]} repeat=$repeat count=$count cap=$cap seconds=$seconds head=$(git rev-parse HEAD)" \
  "cpus=$(nproc) mem_gb=$(awk '/MemTotal/ {printf "%.0f", $2 / 1048576}' /proc/meminfo) thp=$(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null | tr ' ' _)" \
  "built_s=$((SECONDS - started_at))"
status=0
# One parked run: the daemon's PSS after day 1 (INFINITE-ROLE ... acpmux mb=), the total, attach and rehydrate.
parked() {
  local arm="$1" r="$2" log="$ab/p-$1-$2.log"
  python3 scripts/measure/infinite-items.py --acpmux "$ab/$arm/acpmux" --tui "$ab/$arm/cmux-tui" \
    --counts "$count" --days 1 --resident-cap "$cap" --park-idle --open-probe "$open_probe" >"$log" 2>&1 || status=$?
  python3 - "$log" "$arm" "$r" "$count" >>"$ab/parked.tsv" <<'PY'
import json, re, sys
log, arm, r, n = sys.argv[1:5]
pss = total = att = reh = None
errs = 0
for l in open(log, errors="replace"):
    m = re.match(rf"INFINITE-ROLE {n} day=(\d+) acpmux n=\d+ thr=\S+ mb=([\d.]+)", l)
    if m: pss = float(m.group(2))
    m = re.match(rf"INFINITE {n} \| ([\d.]+) ", l)
    if m: total = float(m.group(1))
    if l.startswith(f"INFINITE-OPEN {n} "):
        o = json.loads(l[l.index("{"):])
        att = o.get("p50"); reh = (o.get("rehydrate") or {}).get("p50_ms")
    if l.startswith(f"INFINITE-ERRORS {n} "): errs += 1
print(f"{arm}\t{r}\t{pss}\t{total}\t{att}\t{reh}\t{errs}")
PY
  echo "MAB-P arm=$arm r$r $(tail -n 1 "$ab/parked.tsv" | awk -F'\t' '{printf "acpmux_pss_mb=%s total_pss_mb=%s attach_p50_ms=%s rehydrate_p50_ms=%s errors=%s", $3, $4, $5, $6, $7}')"
  grep -E "^INFINITE-ERRORS " "$log" | cut -c1-400 | sed "s/^/MAB-P arm=$arm r$r /" || true
}
round_s=0
for r in $(seq 1 "$repeat"); do
  t0=$SECONDS
  for arm in "${arms[@]}"; do parked "$arm" "$r"; done
  round_s=$((SECONDS - t0))
  echo "MAB-P-ROUND r$r seconds=$round_s"
done
# The mi-* arm with the lowest median parked acpmux PSS streams beside the shipped one.
best="$(python3 - "$ab/parked.tsv" <<'PY'
import statistics, sys
by = {}
for l in open(sys.argv[1]):
    arm, _, pss = l.split("\t")[:3]
    if pss != "None": by.setdefault(arm, []).append(float(pss))
med = {a: statistics.median(v) for a, v in by.items()}
for a in sorted(med, key=med.get):
    print(f"MAB-P-MEDIAN arm={a} acpmux_pss_mb={med[a]:.1f} runs={len(by[a])}", file=sys.stderr)
mi = [a for a in med if a.startswith("mi-")]
print(min(mi, key=med.get) if mi else "")
PY
)"
echo "MAB-BEST arm=${best:-none}"
[[ "$stream" == 1 ]] || exit "$status"
sarms=(mimalloc ${best:+"$best"} mallocng glibc)
for r in $(seq 1 "$repeat"); do
  # Round 1 always runs; a later round only while its time still fits the budget.
  if (( r > 1 && SECONDS - started_at + round_s > budget )); then
    echo "MAB-S-CUT before r$r: $((SECONDS - started_at)) s spent, the last round took ${round_s} s, budget ${budget} s"
    break
  fi
  t0=$SECONDS
  for arm in "${sarms[@]}"; do
    run="$ab/s-$arm-$r"
    COORD_SIM_KEEP="$run" bash scripts/measure/coord-sim-linux.sh acpmux_bin="$ab/$arm/acpmux" seconds="$seconds" fanin=0 \
      >"$ab/out" 2>"$ab/err" || { status=$?; tail -n 5 "$ab/err" | sed "s/^/MAB-S arm=$arm r$r ERR /"; }
    python3 - "$ab/out" "$run" "$arm" "$r" <<'PY'
import json, sys
out, run, arm, r = sys.argv[1:5]
lines = [l for l in open(out, errors="replace") if l.startswith("{")]
rep = next((json.loads(l) for l in lines if '"coord-sim-run' in l), None)
def g(d, *ks):
    for k in ks:
        if not isinstance(d, dict): return None
        d = d.get(k)
    return d
pc = g(rep, "per_chat", "rss_mb") or {}
dl = g(rep, "delivery_ms") or {}
at = g(rep, "attach_ms") or {}
dm = g(rep, "daemon") or {}
# The daemon's RSS at fixed times (proc.ndjson, every 250 ms) and the slope of each half: does growth level off?
pts = []
try:
    for l in open(f"{run}/proc.ndjson"):
        o = json.loads(l)
        if o.get("role") == "daemon" and o.get("rss_kb"): pts.append((o["t_us"] / 1e6, o["rss_kb"] / 1024))
except OSError:
    pass
at_t = ""
half = ""
if pts:
    t0 = pts[0][0]; pts = [(t - t0, m) for t, m in pts]
    end = pts[-1][0]
    def rss(t): return min(pts, key=lambda p: abs(p[0] - t))[1]
    at_t = " ".join(f"rss@{int(t)}s={rss(t):.0f}" for t in (60, 120, 300, 450, end) if t <= end)
    def slope(a, b):
        s = [p for p in pts if a <= p[0] <= b]
        if len(s) < 2: return float("nan")
        n = len(s); mx = sum(p[0] for p in s) / n; my = sum(p[1] for p in s) / n
        den = sum((p[0] - mx) ** 2 for p in s)
        return 60 * sum((p[0] - mx) * (p[1] - my) for p in s) / den if den else float("nan")
    half = f"slope_1st_half={slope(60, end / 2):+.2f} slope_2nd_half={slope(end / 2, end):+.2f}"
print(f"MAB-S arm={arm} r{r} per_chat_rss_mb_p50={pc.get('p50')} per_chat_rss_mb_p95={pc.get('p95')} "
      f"rss_slope_mb_min={dm.get('rss_slope_mb_per_min')} rss_slope_whole_mb_min={dm.get('rss_slope_whole_run_mb_per_min')} "
      f"peak_rss_mb={dm.get('peak_rss_mb')} delivery_p50={dl.get('p50')} delivery_p95={dl.get('p95')} "
      f"delivery_p99={dl.get('p99')} attach_p50={at.get('p50')} lost={g(rep, 'events', 'lost')} {half} {at_t}", flush=True)
PY
    rm -rf "$run"
  done
  round_s=$((SECONDS - t0))
  echo "MAB-S-ROUND r$r seconds=$round_s"
done
exit "$status"
