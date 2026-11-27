#!/usr/bin/env bash
# The cmux-next-swift-check job's cmux-tui check (`cargo check` for macOS of cmux-tui, cmux-app-host,
# cmux-browser-host and acpmux; cmuxterm-hq build-fleet/swift-linux-builder/pool/cmux-tui-mac-check.sh)
# with no compiler wrapper, as the recipe runs it today (it unsets RUSTC_WRAPPER), against the pool VM's
# kache (RUSTC_WRAPPER=/opt/kache/kache, as hq build-fleet/cmd/worker/step_kache.go sets for ci-steps).
# One harness, one pool VM, each run from an empty target dir, idle and with one busy loop per core.
# Each run prints its wall time and, from cargo's --timings report, the ghostty-vt-sys build script's
# time (its zig build of libghostty-vt) against the rest.
#
# Run (Linux pool; the image carries the check and kache):
#   cmux-ci test --route fleet -- env GHOSTTY_NEXT_SHA="$(git rev-parse HEAD:ghostty-next)" \
#     bash scripts/measure/cmux-tui-mac-check-kache.sh [full|remote]
# (--route fleet: an Actions runner has no pool image. The fleet upload carries no submodules, so the
# check's Zig lookup finds no ghostty-next; this fetches it at GHOSTTY_NEXT_SHA, the commit's pin.)
# remote: a second job on another VM, after a full one pushed this commit's units (the fresh-VM case).
set -uo pipefail
src="$(pwd)"
img=/opt/cmux-linux-pool/hq/build-fleet/swift-linux-builder/pool/cmux-tui-mac-check.sh
[[ -f "$img" ]] || { echo "no $img on this host: run on a Linux pool VM" >&2; exit 69; }
out="$src/bench-out"; mkdir -p "$out"
if [[ ! -f "$src/ghostty-next/build.zig.zon" ]]; then
  pin="${GHOSTTY_NEXT_SHA:-$(git -C "$src" rev-parse HEAD:ghostty-next 2>/dev/null)}"
  [[ -n "$pin" ]] || { echo "no ghostty-next checkout and no GHOSTTY_NEXT_SHA; no verdict" >&2; exit 69; }
  rm -rf "$src/ghostty-next"   # the empty submodule directory of the upload
  git init -q "$src/ghostty-next" \
    && git -C "$src/ghostty-next" fetch -q --depth 1 https://github.com/manaflow-ai/ghostty-next.git "$pin" \
    && git -C "$src/ghostty-next" checkout -q FETCH_HEAD \
    || { echo "ghostty-next $pin did not fetch; no verdict" >&2; exit 69; }
  echo "ghostty-next fetched at $pin"
fi
# Two copies of the image's check, the same except for the wrapper; both add --timings (stable HTML report).
sed -e 's/ RUSTC_WRAPPER$//' -e 's/^cargo check --release --locked /cargo check --timings --release --locked /' "$img" >"$out/check-kache.sh"
sed -e 's/^cargo check --release --locked /cargo check --timings --release --locked /' "$img" >"$out/check-none.sh"
# The copies look for components/lib/source-zig.sh beside themselves first, then in the image's hq copy.
grep -q -- '--timings' "$out/check-none.sh" && grep -q -- '--timings' "$out/check-kache.sh" \
  && ! grep -q 'RANLIB_aarch64_apple_darwin RUSTC_WRAPPER$' "$out/check-kache.sh" \
  || { echo "the image's check has another shape; no verdict" >&2; exit 69; }
kache_ok=0
[[ -x /opt/kache/kache && -S /run/kache/daemon.sock ]] && kache_ok=1
echo "host=$(hostname) nproc=$(nproc) mem=$(free -g | awk '/Mem/{print $2}')G kache_daemon=$kache_ok"
(( kache_ok )) || { echo "kache daemon not running here; no verdict" >&2; exit 69; }
tgt="$src/cmux-tui/target/macos-cross-fast"
split() { # the timings report's ghostty-vt-sys build-script run, and the sum of every other unit
  python3 -I - "$tgt/cargo-timings/cargo-timing.html" <<'PY'
import json, re, sys
t = open(sys.argv[1]).read()
m = re.search(r"const UNIT_DATA = (\[.*?\]);", t, re.S)
units = json.loads(m.group(1)) if m else []
gv = sum(u["duration"] for u in units if u["name"] == "ghostty-vt-sys" and u.get("mode") == "run-custom-build")
rest = sum(u["duration"] for u in units) - gv
print(f"units={len(units)} ghostty_vt_build={gv:.1f}s other_units_sum={rest:.1f}s")
PY
}
run() { # TAG none|kache
  local tag=$1 which=$2 t0 rc
  rm -rf "$tgt"
  t0=$(date +%s.%N)
  if [[ $which == kache ]]; then
    RUSTC_WRAPPER=/opt/kache/kache bash "$out/check-kache.sh" "$src" >"$out/$tag.log" 2>&1; rc=$?
  else
    bash "$out/check-none.sh" "$src" >"$out/$tag.log" 2>&1; rc=$?
  fi
  echo "RUN $tag ($which) rc=$rc wall=$(python3 -c "import time,sys;print(round(time.time()-float(sys.argv[1]),1))" "$t0")s $(split 2>/dev/null || echo split=none) load=$(cut -d' ' -f1 /proc/loadavg)"
  (( rc == 0 )) || { failed=$((failed + 1)); tail -20 "$out/$tag.log" | sed "s/^/  $tag /"; }
}
failed=0
# warm0 sets up the cross toolchain and the Zig packages (kept in ~/.cache); not counted.
# mode=remote (a second job, on another VM than the first's): the first kache run here reads what the
# first job pushed to the shared remote, so it is the fresh-VM case.
mode="${1:-full}"
run warm0 none
if [[ $mode == remote ]]; then
  run remote-kache kache
  run remote-kache-2 kache
  run remote-none none
  exit $(( failed > 0 ))
fi
run none-1 none
run kfill kache          # the first kache run of this commit: misses fill the VM's store and push to the remote
run kache-1 kache        # the local store warm
run none-2 none
run kache-2 kache
for _ in $(seq "$(nproc)"); do (while :; do :; done) & done
run load-none none
run load-kache kache
kill $(jobs -p) 2>/dev/null
exit $(( failed > 0 ))  # a run with no verdict fails the job, so a bench that measured nothing never reads as SUCCESS
