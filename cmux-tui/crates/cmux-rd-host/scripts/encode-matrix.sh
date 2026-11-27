#!/usr/bin/env bash
# The software encoder's cost by core count, size and thread settings, on one Linux host with
# no GPU: `cmux-rd encode-selftest` pinned with taskset to 2, 4 and 8 cores (a 2, 4 or 8 vCPU
# cloud VM). Each run is one JSON line (encode_ms and convert_ms percentiles, bytes per frame,
# IDRs) with `cores_pinned` and `variant` added.
#
#   scripts/encode-matrix.sh [OUT.jsonl]       (default $FAST_CHECKS_OUT/encode-matrix.jsonl)
#
# Environment: CORES="2 4 8", SIZES="1920x1080 3840x2160", WORKLOADS="type text",
# FRAMES=200, VARIANTS (a space-separated list of NAME=OPTIONS; OPTIONS is
# `--threads N --convert-threads N --openh264-options LIST` in any mix, commas inside
# LIST, `+` for a space), CISCO=1 to also run Cisco's binary (downloaded from Cisco,
# the one the product loads) or CISCO=only for that alone. The source build (`bench`)
# compiles OpenH264 without its assembly when nasm is missing: about 3x slower than
# Cisco's binary on the fleet pool, so only Cisco rows say what a host costs.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
out="${1:-${FAST_CHECKS_OUT:-/tmp}/encode-matrix.jsonl}"
cores_list="${CORES:-2 4 8}"
sizes="${SIZES:-1920x1080 3840x2160}"
workloads="${WORKLOADS:-type text}"
frames="${FRAMES:-200}"
variants="${VARIANTS:-shipped=}"
mkdir -p "$(dirname "$out")"
: >"$out"

# No capture backend is needed (no PipeWire headers on the pool): the encoder and the bench.
cargo build --release --quiet --manifest-path "$here/Cargo.toml" --bin cmux-rd \
  --no-default-features --features "${FEATURES:-bench openh264}"
bin="$(cargo metadata --format-version 1 --no-deps --manifest-path "$here/Cargo.toml" |
  python3 -c 'import json,sys; print(json.load(sys.stdin)["target_directory"])')/release/cmux-rd"

libs=()
[ "${CISCO:-0}" = only ] || libs+=("source=")
if [ "${CISCO:-0}" != 0 ]; then
  dir="$(mktemp -d)"
  libs+=("cisco=--openh264-lib+$("$bin" openh264-install --dir "$dir")")
fi

host_cores="$(nproc)"
echo "host: $(nproc) cores, $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | xargs)," \
  "nasm: $(command -v nasm || echo none)" >&2
for lib in "${libs[@]}"; do
  for cores in $cores_list; do
    [ "$cores" -le "$host_cores" ] || continue
    for size in $sizes; do
      for workload in $workloads; do
        for variant in $variants; do
          name="${variant%%=*}"
          args="${variant#*=}"
          largs="${lib#*=}"
          # shellcheck disable=SC2086 # the variant's words are separate arguments
          taskset -c "0-$((cores - 1))" "$bin" encode-selftest --codec openh264 \
            --workload "$workload" --width "${size%x*}" --height "${size#*x}" --frames "$frames" \
            ${args//+/ } ${largs//+/ } >"$out.run" 2>"$out.err" || cat "$out.err" >>"$out.run"
          python3 -c '
import json, sys
text = open(sys.argv[4]).read().strip()
try:
    row = json.loads(text.splitlines()[-1])
except (IndexError, ValueError):
    row = {"error": text[-2000:]}
row.update(cores_pinned=int(sys.argv[1]), variant=sys.argv[2], lib=sys.argv[3], size_arg=sys.argv[5],
           workload_arg=sys.argv[6])
print(json.dumps(row))' "$cores" "$name" "${lib%%=*}" "$out.run" "$size" "$workload" | tee -a "$out"
        done
      done
    done
  done
done
