#!/usr/bin/env bash
set -euo pipefail

mode="${1:-}"
base_sha="${2:-}"
candidate_sha="${3:-}"

if [[ -z "$mode" || -z "$base_sha" ]]; then
  echo "usage: $0 seed <base-sha> | consume <base-sha> <candidate-sha>" >&2
  exit 64
fi
if [[ "$mode" == "consume" && -z "$candidate_sha" ]]; then
  echo "consume requires candidate sha" >&2
  exit 64
fi

origin="https://github.com/manaflow-ai/cmux.git"
mount_fixed="/private/tmp/cmux-incremental-generation-canary"
mount_relocated="/private/tmp/cmux-incremental-generation-canary-relocated"
support_root="/private/tmp/cmux-incremental-generation-support"
spm="$support_root/source-packages"
cas="$support_root/xcode-compilation-cas"
results="${CMUX_CANARY_RESULTS:?CMUX_CANARY_RESULTS is required}"
generation_archive="${CMUX_CANARY_GENERATION_ARCHIVE:?CMUX_CANARY_GENERATION_ARCHIVE is required}"
support_archive="${CMUX_CANARY_SUPPORT_ARCHIVE:?CMUX_CANARY_SUPPORT_ARCHIVE is required}"
seed_image="${CMUX_CANARY_SEED_IMAGE:-${RUNNER_TEMP:?}/cmux-incremental-seed.sparsebundle}"
work_image="${CMUX_CANARY_WORK_IMAGE:-${RUNNER_TEMP:?}/cmux-incremental-work.sparsebundle}"

mkdir -p "$results"
export PATH="$HOME/.cargo/bin:$PATH"
export CMUX_SKIP_ZIG_BUILD=1

now() {
  python3 - <<'PY'
import time
print(f"{time.monotonic():.9f}")
PY
}

elapsed() {
  python3 - "$1" "$2" <<'PY'
import sys
print(f"{float(sys.argv[2]) - float(sys.argv[1]):.3f}")
PY
}

bytes_of() {
  python3 - "$1" <<'PY'
import os, sys
print(os.path.getsize(sys.argv[1]))
PY
}

du_kib() {
  if [[ -e "$1" ]]; then
    du -sk "$1" | awk '{print $1}'
  else
    echo 0
  fi
}

detach_mount() {
  local mount="$1"
  if mount | grep -Fq " on $mount "; then
    hdiutil detach "$mount" -quiet || hdiutil detach "$mount" -force -quiet || true
  fi
}

attach_image() {
  local image="$1" mount="$2"
  detach_mount "$mount"
  rm -rf "$mount"
  mkdir -p "$mount"
  hdiutil attach -quiet -nobrowse -mountpoint "$mount" "$image"
}

clone_source() {
  local ref="$1" destination="$2"
  rm -rf "$destination"
  git clone --quiet --filter=blob:none --no-checkout "$origin" "$destination"
  git -C "$destination" -c advice.detachedHead=false checkout --quiet --detach "$ref"
  git -C "$destination" submodule update --quiet --init vendor/bonsplit
}

materialize_ghosttykit() {
  local source="$1"
  local ghostty_sha
  ghostty_sha="$(git -C "$source" rev-parse HEAD:ghostty)"
  (
    cd "$source"
    GHOSTTY_SHA="$ghostty_sha" ./scripts/download-prebuilt-ghosttykit.sh
  )
}

resolve_packages() {
  local source="$1" derived="$2"
  (
    cd "$source"
    ./scripts/ci/compile-app-host-test-product.sh resolve "$derived" "$spm"
  )
}

snapshot_identity() {
  local source="$1" label="$2"
  local unchanged=""
  if [[ -f "$source/Sources/Workspace.swift" ]]; then
    unchanged="Sources/Workspace.swift"
  else
    unchanged="$(git -C "$source" ls-files 'Sources/*.swift' | grep -v '^Sources/AppDelegate.swift$' | head -n 1 || true)"
  fi
  {
    echo "label=$label"
    echo "head=$(git -C "$source" rev-parse HEAD)"
    for rel in "Sources/AppDelegate.swift" "$unchanged"; do
      [[ -n "$rel" && -e "$source/$rel" ]] || continue
      stat -f 'path=%N mtime=%m inode=%i device=%d' "$source/$rel"
    done
  } >> "$results/source-identities.txt"
}

parse_build_metrics() {
  local label="$1" log="$2" build_seconds="$3" prep_seconds="$4" arm_seconds="$5" source="$6" derived="$7" mountpoint="$8" exit_code="$9"
  local source_kib derived_kib volume_kib
  source_kib="$(du_kib "$source")"
  derived_kib="$(du_kib "$derived")"
  volume_kib="$(du_kib "$mountpoint")"
  python3 - "$label" "$log" "$build_seconds" "$prep_seconds" "$arm_seconds" "$source_kib" "$derived_kib" "$volume_kib" "$exit_code" <<'PY'
import json
import pathlib
import re
import sys

label, log_path = sys.argv[1], pathlib.Path(sys.argv[2])
text = log_path.read_text(encoding="utf-8", errors="replace") if log_path.exists() else ""
lines = text.splitlines()

swift_compile_lines = sum(1 for line in lines if re.match(r"^\s*SwiftCompile\b", line))
swift_emit_lines = sum(1 for line in lines if re.match(r"^\s*SwiftEmitModule\b", line))

compile_tasks = 0
compile_seconds = 0.0
emit_tasks = 0
emit_seconds = 0.0
for line in lines:
    m = re.search(r"^\s*SwiftCompile\s+\((\d+)\s+tasks?\)\s*\|\s*([0-9.]+)\s+seconds", line)
    if m:
        compile_tasks += int(m.group(1))
        compile_seconds += float(m.group(2))
    m = re.search(r"^\s*SwiftEmitModule\s+\((\d+)\s+tasks?\)\s*\|\s*([0-9.]+)\s+seconds", line)
    if m:
        emit_tasks += int(m.group(1))
        emit_seconds += float(m.group(2))

cache_lines = [line.strip() for line in lines if "cache" in line.lower() and ("hit" in line.lower() or "miss" in line.lower())]
cache_hits = None
cache_misses = None
patterns = [
    re.compile(r"(\d[\d,]*)\s+(?:cache\s+)?hits?\D{1,80}(\d[\d,]*)\s+(?:cache\s+)?misses?", re.I),
    re.compile(r"hits?\s*[:=]\s*(\d[\d,]*)\D{1,80}misses?\s*[:=]\s*(\d[\d,]*)", re.I),
]
for line in cache_lines:
    for pattern in patterns:
        m = pattern.search(line)
        if m:
            cache_hits = int(m.group(1).replace(",", ""))
            cache_misses = int(m.group(2).replace(",", ""))

payload = {
    "schema": "cmux-incremental-generation-canary/v1",
    "label": label,
    "build_seconds": float(sys.argv[3]),
    "preparation_seconds": float(sys.argv[4]),
    "arm_wall_seconds": float(sys.argv[5]),
    "swift_compile_log_lines": swift_compile_lines,
    "swift_compile_tasks": compile_tasks,
    "swift_compile_timing_seconds": round(compile_seconds, 3),
    "swift_emit_module_log_lines": swift_emit_lines,
    "swift_emit_module_tasks": emit_tasks,
    "swift_emit_module_seconds": round(emit_seconds, 3),
    "compilation_cas_hits": cache_hits,
    "compilation_cas_misses": cache_misses,
    "source_kib": int(sys.argv[6]),
    "derived_data_kib": int(sys.argv[7]),
    "mounted_generation_kib": int(sys.argv[8]),
    "exit_code": int(sys.argv[9]),
}
with open(log_path.parent / "metrics.jsonl", "a", encoding="utf-8") as f:
    f.write(json.dumps(payload, sort_keys=True) + "\n")
with open(log_path.parent / f"{label}-cache-lines.txt", "w", encoding="utf-8") as f:
    for line in cache_lines[-400:]:
        f.write(line + "\n")
print(json.dumps(payload, sort_keys=True))
PY
}

build_arm() {
  local label="$1" source="$2" derived="$3" prep_seconds="$4" arm_start="$5" mountpoint="$6"
  local log="$results/$label.log"
  local start end build_seconds arm_end arm_seconds rc=0
  mkdir -p "$derived" "$cas"
  start="$(now)"
  (
    cd "$source"
    for scheme in cmux cmux-unit cmux-numeric-locale; do
      xcodebuild -project cmux.xcodeproj -scheme "$scheme" -configuration Debug \
        -derivedDataPath "$derived" \
        -clonedSourcePackagesDirPath "$spm" \
        -disableAutomaticPackageResolution \
        -destination "platform=macOS" \
        'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) CMUX_CI_APP_HOST_ISOLATION_REQUIRED' \
        'LD_RUNPATH_SEARCH_PATHS=$(inherited) @executable_path/../Frameworks /private/tmp/cmux-app-host-package-frameworks' \
        COMPILATION_CACHE_ENABLE_CACHING=YES \
        "COMPILATION_CACHE_CAS_PATH=$cas" \
        COMPILATION_CACHE_LIMIT_SIZE=3221225472 \
        -showBuildTimingSummary \
        build-for-testing
    done
  ) >"$log" 2>&1 || rc=$?
  end="$(now)"
  build_seconds="$(elapsed "$start" "$end")"
  arm_end="$(now)"
  arm_seconds="$(elapsed "$arm_start" "$arm_end")"
  parse_build_metrics "$label" "$log" "$build_seconds" "$prep_seconds" "$arm_seconds" "$source" "$derived" "$mountpoint" "$rc"
  return 0
}

record_seed_packaging() {
  local compression_seconds="$1" support_compression_seconds="$2" generation_kib="$3" support_kib="$4"
  python3 - "$results/seed-packaging.json" "$compression_seconds" "$support_compression_seconds" "$(bytes_of "$generation_archive")" "$(bytes_of "$support_archive")" "$generation_kib" "$support_kib" <<'PY'
import json, sys
payload = {
    "schema": "cmux-incremental-generation-packaging/v1",
    "generation_compression_seconds": float(sys.argv[2]),
    "support_compression_seconds": float(sys.argv[3]),
    "generation_archive_bytes": int(sys.argv[4]),
    "support_archive_bytes": int(sys.argv[5]),
    "generation_disk_kib": int(sys.argv[6]),
    "support_disk_kib": int(sys.argv[7]),
}
with open(sys.argv[1], "w", encoding="utf-8") as f:
    json.dump(payload, f, sort_keys=True, indent=2)
    f.write("\n")
print(json.dumps(payload, sort_keys=True))
PY
}

seed() {
  rm -rf "$results" "$support_root" "$seed_image" "$generation_archive" "$support_archive"
  mkdir -p "$results" "$support_root" "$(dirname "$seed_image")" "$(dirname "$generation_archive")"
  detach_mount "$mount_fixed"
  hdiutil create -quiet -size 32g -type SPARSEBUNDLE -fs APFS -volname CMUXIncrementalCanary "$seed_image"
  attach_image "$seed_image" "$mount_fixed"

  local source="$mount_fixed/source"
  local derived="$mount_fixed/derived-data"
  local arm_start prep_start prep_end prep_seconds
  arm_start="$(now)"
  prep_start="$arm_start"
  clone_source "$base_sha" "$source"
  materialize_ghosttykit "$source"
  resolve_packages "$source" "$derived"
  prep_end="$(now)"
  prep_seconds="$(elapsed "$prep_start" "$prep_end")"
  snapshot_identity "$source" "seed-before-build"
  build_arm "seed-A" "$source" "$derived" "$prep_seconds" "$arm_start" "$mount_fixed"
  sync
  snapshot_identity "$source" "seed-after-build"
  local generation_kib support_kib
  generation_kib="$(du_kib "$mount_fixed")"
  support_kib="$(du_kib "$support_root")"
  detach_mount "$mount_fixed"

  local start end compression_seconds support_compression_seconds
  start="$(now)"
  tar -C "$(dirname "$seed_image")" -czf "$generation_archive" "$(basename "$seed_image")"
  end="$(now)"
  compression_seconds="$(elapsed "$start" "$end")"

  start="$(now)"
  tar -C "$support_root" -czf "$support_archive" source-packages xcode-compilation-cas
  end="$(now)"
  support_compression_seconds="$(elapsed "$start" "$end")"
  record_seed_packaging "$compression_seconds" "$support_compression_seconds" "$generation_kib" "$support_kib"
}

restore_support() {
  rm -rf "$support_root"
  mkdir -p "$support_root"
  tar -xzf "$support_archive" -C "$support_root"
}

clone_seed_image() {
  rm -rf "$work_image"
  local start end method
  start="$(now)"
  if cp -cR "$seed_image" "$work_image" 2>/dev/null; then
    method="apfs-clone"
  else
    cp -R "$seed_image" "$work_image"
    method="copy"
  fi
  end="$(now)"
  printf '%s\t%s\n' "$method" "$(elapsed "$start" "$end")" >> "$results/image-clone-times.tsv"
}

transition_restored_source() {
  local source="$1" target="$2"
  git -C "$source" fetch --quiet --no-tags origin "$target"
  git -C "$source" -c advice.detachedHead=false checkout --quiet --detach "$target"
  git -C "$source" reset --hard --quiet "$target"
  git -C "$source" clean -ffd >/dev/null
}

run_arm() {
  local label="$1" arm_mode="$2" mountpoint="$3"
  local arm_start prep_start prep_end prep_seconds source derived
  arm_start="$(now)"
  restore_support
  clone_seed_image
  attach_image "$work_image" "$mountpoint"
  source="$mountpoint/source"
  derived="$mountpoint/derived-data"
  prep_start="$(now)"

  snapshot_identity "$source" "$label-before-transition"

  case "$arm_mode" in
    cold)
      rm -rf "$source" "$derived"
      clone_source "$candidate_sha" "$source"
      materialize_ghosttykit "$source"
      ;;
    fresh-dd)
      rm -rf "$source"
      clone_source "$candidate_sha" "$source"
      materialize_ghosttykit "$source"
      ;;
    restored)
      transition_restored_source "$source" "$candidate_sha"
      ;;
    merge)
      git -C "$source" fetch --quiet --no-tags origin "$candidate_sha"
      git -C "$source" -c user.name='cmux incremental canary' -c user.email='canary@cmux.invalid' \
        merge --quiet --no-ff --no-edit "$candidate_sha"
      ;;
    relocated)
      transition_restored_source "$source" "$candidate_sha"
      ;;
    *)
      echo "unknown arm mode: $arm_mode" >&2
      detach_mount "$mountpoint"
      return 1
      ;;
  esac

  snapshot_identity "$source" "$label-after-transition"
  resolve_packages "$source" "$derived"
  prep_end="$(now)"
  prep_seconds="$(elapsed "$prep_start" "$prep_end")"
  build_arm "$label" "$source" "$derived" "$prep_seconds" "$arm_start" "$mountpoint"
  sync
  snapshot_identity "$source" "$label-after-build"
  detach_mount "$mountpoint"
  printf '%s\t%s\n' "$label" "$(du_kib "$work_image")" >> "$results/arm-image-physical-kib.tsv"
  rm -rf "$work_image"
}

consume() {
  rm -rf "$results" "$seed_image" "$work_image"
  mkdir -p "$results" "$(dirname "$seed_image")"
  detach_mount "$mount_fixed"
  detach_mount "$mount_relocated"

  local start end
  start="$(now)"
  tar -xzf "$generation_archive" -C "$(dirname "$seed_image")"
  end="$(now)"
  printf 'generation_extract_seconds=%s\n' "$(elapsed "$start" "$end")" > "$results/transfer-local.txt"
  printf 'generation_archive_bytes=%s\n' "$(bytes_of "$generation_archive")" >> "$results/transfer-local.txt"
  printf 'support_archive_bytes=%s\n' "$(bytes_of "$support_archive")" >> "$results/transfer-local.txt"

  run_arm "cold-fresh-B" "cold" "$mount_fixed"
  run_arm "fresh-B-restored-DD" "fresh-dd" "$mount_fixed"
  run_arm "restored-worktree-DD-B" "restored" "$mount_fixed"
  run_arm "restored-worktree-DD-merge" "merge" "$mount_fixed"
  run_arm "relocated-restored-pair-B" "relocated" "$mount_relocated"

  python3 - "$results/metrics.jsonl" "$results/summary.md" <<'PY'
import json
import pathlib
import sys
rows = [json.loads(line) for line in pathlib.Path(sys.argv[1]).read_text().splitlines() if line.strip()]
headers = [
    "label", "build_seconds", "arm_wall_seconds", "swift_compile_tasks",
    "swift_emit_module_seconds", "compilation_cas_hits", "compilation_cas_misses",
    "derived_data_kib", "exit_code"
]
with open(sys.argv[2], "w", encoding="utf-8") as f:
    f.write("| " + " | ".join(headers) + " |\n")
    f.write("|" + "|".join(["---"] * len(headers)) + "|\n")
    for row in rows:
        f.write("| " + " | ".join(str(row.get(h, "")) for h in headers) + " |\n")
PY
}

case "$mode" in
  seed) seed ;;
  consume) consume ;;
  *) echo "unknown mode: $mode" >&2; exit 64 ;;
esac
