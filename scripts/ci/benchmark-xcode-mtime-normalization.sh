#!/usr/bin/env bash
set -euo pipefail

mode="${1:?seed or consumer}"
base_sha="${2:?base sha}"
head_sha="${3:?head sha}"
artifact_dir="${4:?artifact dir}"

repo_url="https://github.com/manaflow-ai/cmux.git"
root="/tmp/cmux-incgen-mtime"
worktree="$root/worktree"
derived="$root/derived-data"
source_packages="$root/source-packages"
archive="$artifact_dir/derived-A.tar.zst"
seed_manifest="$artifact_dir/seed-swift-mtimes.tsv"
results="$artifact_dir/results.jsonl"
log="$artifact_dir/${mode}.log"
transport_cap_bytes=$((4 * 1024 * 1024 * 1024))

mkdir -p "$artifact_dir"
touch "$results"

now() {
  python3 -c 'import time; print(time.monotonic())'
}

elapsed() {
  python3 - "$1" "$2" <<'PY'
import sys
print(round(float(sys.argv[2]) - float(sys.argv[1]), 6))
PY
}

dir_bytes() {
  python3 - "$1" <<'PY'
import os, sys
root = sys.argv[1]
total = 0
if os.path.exists(root):
    for base, dirs, files in os.walk(root, followlinks=False):
        for name in files:
            p = os.path.join(base, name)
            try:
                total += os.lstat(p).st_size
            except FileNotFoundError:
                pass
print(total)
PY
}

clone_at() {
  local sha="$1"
  rm -rf "$worktree"
  git clone --filter=blob:none --no-checkout --depth 1 "$repo_url" "$worktree"
  git -C "$worktree" fetch --depth 2 origin "$sha"
  git -C "$worktree" checkout --detach "$sha"
  git -C "$worktree" submodule update --init --recursive --depth 1 || \
    git -C "$worktree" submodule update --init --recursive
}

restore_spm() {
  local lock="$worktree/cmux.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
  local hash
  hash="$(shasum -a 256 "$lock" | awk '{print $1}')"
  CI_CACHE_R2_PUBLIC_URL="${CI_CACHE_R2_PUBLIC_URL:-https://ci-cache.cmux.com}" \
    "$GITHUB_WORKSPACE/scripts/ci/r2-cache.sh" restore \
    "$source_packages" "spm-$hash" "spm-"
  python3 "$worktree/scripts/ci/sanitize-xcode-source-packages-cache.py" "$source_packages"
}

prepare_inputs() {
  (
    cd "$worktree"
    ./scripts/download-prebuilt-ghosttykit.sh
    ./scripts/ci/compile-app-host-test-product.sh resolve "$derived" "$source_packages"
  )
}

normalize_repo() {
  local repo="$1"
  python3 - "$repo" <<'PY'
import os
import subprocess
import sys

repo = sys.argv[1]
base_seconds = 978_307_200
span_seconds = 15 * 365 * 24 * 60 * 60
records = subprocess.check_output(
    ["git", "-C", repo, "ls-files", "--recurse-submodules", "--stage", "-z"]
).split(b"\0")
normalized = 0
for record in records:
    if not record:
        continue
    metadata, raw_path = record.split(b"\t", 1)
    mode, object_id, stage = metadata.split()
    if mode == b"160000" or stage != b"0":
        continue
    path = os.path.join(repo, os.fsdecode(raw_path))
    if not os.path.lexists(path):
        continue
    digest = object_id.decode("ascii")
    seconds = base_seconds + int(digest[:12], 16) % span_seconds
    nanoseconds = int(digest[12:20], 16) % 1_000_000_000
    mtime_ns = seconds * 1_000_000_000 + nanoseconds
    os.utime(path, ns=(mtime_ns, mtime_ns), follow_symlinks=False)
    normalized += 1
print(f"normalized {normalized} tracked files in {repo}")
PY
}

normalize_all_sources() {
  normalize_repo "$worktree"
  if [ -d "$source_packages/checkouts" ]; then
    while IFS= read -r -d '' checkout; do
      if git -C "$checkout" rev-parse --git-dir >/dev/null 2>&1; then
        normalize_repo "$checkout"
      fi
    done < <(find "$source_packages/checkouts" -mindepth 1 -maxdepth 1 -type d -print0)
  fi
}

write_seed_manifest() {
  python3 - "$worktree" "$seed_manifest" <<'PY'
import os
import subprocess
import sys

repo, out = sys.argv[1:]
records = subprocess.check_output(
    ["git", "-C", repo, "ls-files", "--recurse-submodules", "--stage", "-z"]
).split(b"\0")
with open(out, "w", encoding="utf-8") as f:
    for record in records:
        if not record:
            continue
        metadata, raw_path = record.split(b"\t", 1)
        mode, object_id, stage = metadata.split()
        if mode == b"160000" or stage != b"0":
            continue
        rel = os.fsdecode(raw_path)
        if not rel.endswith(".swift"):
            continue
        path = os.path.join(repo, rel)
        if not os.path.lexists(path):
            continue
        st = os.stat(path, follow_symlinks=False)
        f.write(f"{rel}\t{object_id.decode('ascii')}\t{st.st_mtime_ns}\n")
PY
}

compare_seed_manifest() {
  python3 - "$worktree" "$seed_manifest" "$results" <<'PY'
import json
import os
import subprocess
import sys

repo, manifest, out = sys.argv[1:]
seed = {}
for raw in open(manifest, encoding="utf-8"):
    rel, oid, mtime = raw.rstrip("\n").split("\t")
    seed[rel] = (oid, int(mtime))

current = {}
records = subprocess.check_output(
    ["git", "-C", repo, "ls-files", "--recurse-submodules", "--stage", "-z"]
).split(b"\0")
for record in records:
    if not record:
        continue
    metadata, raw_path = record.split(b"\t", 1)
    mode, object_id, stage = metadata.split()
    if mode == b"160000" or stage != b"0":
        continue
    rel = os.fsdecode(raw_path)
    if not rel.endswith(".swift"):
        continue
    path = os.path.join(repo, rel)
    if not os.path.lexists(path):
        continue
    current[rel] = (object_id.decode("ascii"), os.stat(path, follow_symlinks=False).st_mtime_ns)

same_blob = same_blob_same_mtime = changed_blob = missing = 0
for rel, (seed_oid, seed_mtime) in seed.items():
    value = current.get(rel)
    if value is None:
        missing += 1
        continue
    oid, mtime = value
    if oid == seed_oid:
        same_blob += 1
        if mtime == seed_mtime:
            same_blob_same_mtime += 1
    else:
        changed_blob += 1

payload = {
    "kind": "mtime_identity",
    "seed_swift_files": len(seed),
    "same_blob": same_blob,
    "same_blob_same_mtime": same_blob_same_mtime,
    "changed_blob": changed_blob,
    "missing": missing,
}
with open(out, "a", encoding="utf-8") as f:
    f.write(json.dumps(payload, sort_keys=True) + "\n")
print(json.dumps(payload, sort_keys=True))
PY
}

build_cmux() {
  local arm="$1"
  local started finished wall
  : > "$log"
  started="$(now)"
  (
    cd "$worktree"
    xcodebuild -project cmux.xcodeproj -scheme cmux -configuration Debug \
      -derivedDataPath "$derived" \
      -clonedSourcePackagesDirPath "$source_packages" \
      -disableAutomaticPackageResolution \
      -destination "platform=macOS" \
      'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) CMUX_CI_APP_HOST_ISOLATION_REQUIRED' \
      'LD_RUNPATH_SEARCH_PATHS=$(inherited) @executable_path/../Frameworks /private/tmp/cmux-app-host-package-frameworks' \
      -showBuildTimingSummary \
      build-for-testing 2>&1 | tee "$log"
  )
  finished="$(now)"
  wall="$(elapsed "$started" "$finished")"
  python3 - "$results" "$arm" "$wall" "$log" "$derived" <<'PY'
import json
import os
import re
import sys

out, arm, wall, log, derived = sys.argv[1:]
text = open(log, encoding="utf-8", errors="replace").read()
lines = text.splitlines()

def timing(label):
    values = []
    for line in lines:
        if label in line and "seconds" in line:
            m = re.search(r"([0-9]+(?:\.[0-9]+)?)\s+seconds", line)
            if m:
                values.append(float(m.group(1)))
    return round(sum(values), 6)

def bytes_under(path):
    total = 0
    for base, dirs, files in os.walk(path, followlinks=False):
        for name in files:
            p = os.path.join(base, name)
            try:
                total += os.lstat(p).st_size
            except FileNotFoundError:
                pass
    return total

payload = {
    "kind": "build",
    "arm": arm,
    "wall_seconds": float(wall),
    "swift_compile_lines": sum(1 for line in lines if line.startswith("SwiftCompile ")),
    "cmux_swift_compile_lines": sum(
        1 for line in lines
        if line.startswith("SwiftCompile ") and "(in target 'cmux'" in line
    ),
    "swift_emit_module_lines": sum(1 for line in lines if line.startswith("SwiftEmitModule ")),
    "cmux_swift_emit_module_lines": sum(
        1 for line in lines
        if line.startswith("SwiftEmitModule ") and "(in target 'cmux'" in line
    ),
    "swift_compile_seconds": timing("SwiftCompile"),
    "emit_module_seconds": timing("SwiftEmitModule"),
    "derived_data_bytes": bytes_under(derived),
    "log_bytes": os.path.getsize(log),
}
with open(out, "a", encoding="utf-8") as f:
    f.write(json.dumps(payload, sort_keys=True) + "\n")
print(json.dumps(payload, sort_keys=True))
PY
  zstd -q -f -3 "$log" -o "$log.zst"
  rm -f "$log"
}

seed() {
  rm -rf "$root"
  mkdir -p "$root" "$artifact_dir"
  clone_at "$base_sha"
  restore_spm
  prepare_inputs
  normalize_all_sources
  write_seed_manifest
  build_cmux "normalized_seed_A"

  local raw_bytes started finished compression_seconds archive_bytes viable=true
  raw_bytes="$(dir_bytes "$derived")"
  started="$(now)"
  tar -cf - -C "$root" derived-data | zstd -q -T0 -3 -o "$archive"
  finished="$(now)"
  compression_seconds="$(elapsed "$started" "$finished")"
  archive_bytes="$(stat -f %z "$archive")"
  if [ "$archive_bytes" -gt "$transport_cap_bytes" ]; then
    viable=false
  fi
  python3 - "$results" "$raw_bytes" "$archive_bytes" "$compression_seconds" "$viable" <<'PY'
import json, sys
out, raw_bytes, archive_bytes, seconds, viable = sys.argv[1:]
payload = {
    "kind": "archive",
    "raw_bytes": int(raw_bytes),
    "archive_bytes": int(archive_bytes),
    "compression_seconds": float(seconds),
    "transport_viable": viable == "true",
}
with open(out, "a", encoding="utf-8") as f:
    f.write(json.dumps(payload, sort_keys=True) + "\n")
print(json.dumps(payload, sort_keys=True))
PY
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    {
      echo "transport_viable=$viable"
      echo "archive_bytes=$archive_bytes"
    } >> "$GITHUB_OUTPUT"
  fi
}

consumer() {
  rm -rf "$root"
  mkdir -p "$root" "$artifact_dir"
  local started finished extract_seconds
  started="$(now)"
  zstd -q -dc "$archive" | tar -xf - -C "$root"
  finished="$(now)"
  extract_seconds="$(elapsed "$started" "$finished")"
  python3 - "$results" "$extract_seconds" <<'PY'
import json, sys
out, seconds = sys.argv[1:]
payload = {"kind": "extract", "extract_seconds": float(seconds)}
with open(out, "a", encoding="utf-8") as f:
    f.write(json.dumps(payload, sort_keys=True) + "\n")
print(json.dumps(payload, sort_keys=True))
PY

  clone_at "$head_sha"
  restore_spm
  prepare_inputs
  normalize_all_sources
  compare_seed_manifest
  build_cmux "normalized_fresh_checkout_restored_dd_A_to_B"
}

case "$mode" in
  seed) seed ;;
  consumer) consumer ;;
  *) echo "usage: $0 seed|consumer BASE_SHA HEAD_SHA ARTIFACT_DIR" >&2; exit 64 ;;
esac
