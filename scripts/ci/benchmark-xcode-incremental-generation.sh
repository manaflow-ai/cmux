#!/usr/bin/env bash
set -euo pipefail

mode="${1:?seed or consumer}"
base_sha="${2:?base sha}"
head_sha="${3:?head sha}"
artifact_dir="${4:?artifact directory}"

repo_url="https://github.com/manaflow-ai/cmux.git"
root="/tmp/cmux-incgen-canary"
alt_root="/tmp/cmux-incgen-canary-relocated"
worktree="$root/worktree"
derived="$root/derived-data"
source_packages="$root/source-packages"
cas="$root/xcode-compilation-cas"
generation_archive="$artifact_dir/generation-A.tar.zst"
support_archive="$artifact_dir/support-A.tar.zst"
seed_manifest="$artifact_dir/seed-swift-stat.tsv"
results="$artifact_dir/results.jsonl"
mtime_results="$artifact_dir/mtime-results.jsonl"
environment="$artifact_dir/environment.txt"
cache_limit_bytes=3221225472
transport_cap_bytes=$((6 * 1024 * 1024 * 1024))

mkdir -p "$artifact_dir"
touch "$results" "$mtime_results"

now() {
  python3 -c 'import time; print(time.monotonic())'
}

elapsed() {
  python3 - "$1" "$2" <<'PY'
import sys
print(round(float(sys.argv[2]) - float(sys.argv[1]), 6))
PY
}

json_metric() {
  python3 - "$results" "$@" <<'PY'
import json, sys
path = sys.argv[1]
payload = json.loads(sys.argv[2])
with open(path, "a", encoding="utf-8") as f:
    f.write(json.dumps(payload, sort_keys=True) + "\n")
print(json.dumps(payload, sort_keys=True))
PY
}

bytes_for() {
  python3 - "$@" <<'PY'
import os, sys
total = 0
for root in sys.argv[1:]:
    if not os.path.lexists(root):
        continue
    if os.path.isfile(root) or os.path.islink(root):
        total += os.lstat(root).st_size
        continue
    for base, dirs, files in os.walk(root, followlinks=False):
        for name in files:
            p = os.path.join(base, name)
            try:
                total += os.lstat(p).st_size
            except FileNotFoundError:
                pass
        for name in dirs:
            p = os.path.join(base, name)
            if os.path.islink(p):
                try:
                    total += os.lstat(p).st_size
                except FileNotFoundError:
                    pass
print(total)
PY
}

record_environment() {
  {
    echo "runner_name=${RUNNER_NAME:-}"
    echo "runner_os=${RUNNER_OS:-}"
    echo "runner_arch=${RUNNER_ARCH:-}"
    echo "home=$HOME"
    echo "pwd=$PWD"
    echo "root=$root"
    echo "alt_root=$alt_root"
    echo "base_sha=$base_sha"
    echo "head_sha=$head_sha"
    echo "developer_dir=${DEVELOPER_DIR:-}"
    xcodebuild -version
    xcrun swift --version
    sw_vers
    uname -a
    df -h /tmp
  } > "$environment"
}

clone_at() {
  local sha="$1" dest="$2"
  rm -rf "$dest"
  git clone --filter=blob:none --no-checkout --depth 1 "$repo_url" "$dest"
  git -C "$dest" fetch --depth 2 origin "$sha"
  git -C "$dest" checkout --detach "$sha"
  git -C "$dest" submodule update --init --recursive --depth 1 ||     git -C "$dest" submodule update --init --recursive
}

prepare_ghostty() {
  local wt="$1"
  (
    cd "$wt"
    ./scripts/download-prebuilt-ghosttykit.sh
  )
}

resolve_packages() {
  local wt="$1" dd="$2"
  mkdir -p "$source_packages" "$dd"
  (
    cd "$wt"
    xcodebuild -project cmux.xcodeproj -scheme cmux-unit -configuration Debug       -derivedDataPath "$dd"       -clonedSourcePackagesDirPath "$source_packages"       -resolvePackageDependencies
  )
}

build_all() {
  local arm="$1" wt="$2" dd="$3" log="$artifact_dir/${arm}.log"
  local started finished wall
  : > "$log"
  mkdir -p "$dd" "$cas"
  started="$(now)"
  (
    cd "$wt"
    for scheme in cmux cmux-unit cmux-numeric-locale; do
      xcodebuild -project cmux.xcodeproj -scheme "$scheme" -configuration Debug         -derivedDataPath "$dd"         -clonedSourcePackagesDirPath "$source_packages"         -disableAutomaticPackageResolution         -destination "platform=macOS"         'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) CMUX_CI_APP_HOST_ISOLATION_REQUIRED'         'LD_RUNPATH_SEARCH_PATHS=$(inherited) @executable_path/../Frameworks /private/tmp/cmux-app-host-package-frameworks'         COMPILATION_CACHE_ENABLE_CACHING=YES         "COMPILATION_CACHE_CAS_PATH=$cas"         "COMPILATION_CACHE_LIMIT_SIZE=$cache_limit_bytes"         -showBuildTimingSummary         build-for-testing 2>&1 | tee -a "$log"
    done
  )
  finished="$(now)"
  wall="$(elapsed "$started" "$finished")"
  python3 - "$results" "$arm" "$wall" "$log" "$wt" "$dd" "$cas" <<'PY'
import json, os, re, subprocess, sys
out, arm, wall, log, wt, dd, cas = sys.argv[1:]
text = open(log, encoding="utf-8", errors="replace").read()
lines = text.splitlines()

def dir_bytes(path):
    total = 0
    if not os.path.exists(path):
        return 0
    for base, dirs, files in os.walk(path, followlinks=False):
        for name in files:
            p = os.path.join(base, name)
            try:
                total += os.lstat(p).st_size
            except FileNotFoundError:
                pass
    return total

def timing(label):
    vals = []
    for line in lines:
        if label in line and "seconds" in line:
            m = re.search(r"([0-9]+(?:\.[0-9]+)?)\s+seconds", line)
            if m:
                vals.append(float(m.group(1)))
    return round(sum(vals), 6)

summary_hits = []
summary_misses = []
for line in lines:
    for pat, sink in [
        (r"(?i)(\d+)\s+(?:compilation\s+)?cache\s+hits?", summary_hits),
        (r"(?i)(\d+)\s+(?:compilation\s+)?cache\s+miss(?:es)?", summary_misses),
    ]:
        m = re.search(pat, line)
        if m:
            sink.append(int(m.group(1)))

payload = {
    "kind": "build",
    "arm": arm,
    "wall_seconds": float(wall),
    "swift_compile_lines": sum(1 for line in lines if line.startswith("SwiftCompile ")),
    "swift_emit_module_lines": sum(1 for line in lines if line.startswith("SwiftEmitModule ")),
    "emit_module_seconds": timing("SwiftEmitModule"),
    "link_seconds": timing("Ld "),
    "cache_hit_diagnostic_lines": sum(1 for line in lines if re.search(r"(?i)cache hit", line)),
    "cache_miss_diagnostic_lines": sum(1 for line in lines if re.search(r"(?i)cache miss", line)),
    "cache_summary_hits": max(summary_hits) if summary_hits else None,
    "cache_summary_misses": max(summary_misses) if summary_misses else None,
    "worktree_bytes": dir_bytes(wt),
    "derived_data_bytes": dir_bytes(dd),
    "cas_bytes": dir_bytes(cas),
    "log_bytes": os.path.getsize(log),
}
with open(out, "a", encoding="utf-8") as f:
    f.write(json.dumps(payload, sort_keys=True) + "\n")
print(json.dumps(payload, sort_keys=True))
PY
  zstd -q -f -3 "$log" -o "$log.zst"
  rm -f "$log"
}

write_seed_manifest() {
  local wt="$1"
  python3 - "$wt" "$seed_manifest" <<'PY'
import os, subprocess, sys
wt, out = sys.argv[1:]
paths = subprocess.check_output(
    ["git", "-C", wt, "ls-files", "*.swift"], text=True
).splitlines()
with open(out, "w", encoding="utf-8") as f:
    for rel in paths:
        p = os.path.join(wt, rel)
        try:
            st = os.stat(p, follow_symlinks=False)
        except FileNotFoundError:
            continue
        f.write(f"{rel}\t{st.st_mtime_ns}\t{st.st_dev}\t{st.st_ino}\n")
PY
}

compare_seed_manifest() {
  local arm="$1" wt="$2"
  python3 - "$seed_manifest" "$wt" "$mtime_results" "$arm" <<'PY'
import json, os, sys
manifest, wt, out, arm = sys.argv[1:]
total = same_mtime = same_dev_inode = same_all = missing = 0
for raw in open(manifest, encoding="utf-8"):
    rel, mtime, dev, ino = raw.rstrip("\n").split("\t")
    total += 1
    p = os.path.join(wt, rel)
    try:
        st = os.stat(p, follow_symlinks=False)
    except FileNotFoundError:
        missing += 1
        continue
    m = st.st_mtime_ns == int(mtime)
    i = st.st_dev == int(dev) and st.st_ino == int(ino)
    same_mtime += int(m)
    same_dev_inode += int(i)
    same_all += int(m and i)
payload = {
    "kind": "source_identity",
    "arm": arm,
    "tracked_swift_files": total,
    "same_mtime": same_mtime,
    "same_device_inode": same_dev_inode,
    "same_mtime_and_identity": same_all,
    "missing": missing,
}
with open(out, "a", encoding="utf-8") as f:
    f.write(json.dumps(payload, sort_keys=True) + "\n")
print(json.dumps(payload, sort_keys=True))
PY
}

compress_paths() {
  local label="$1" archive="$2"; shift 2
  local started finished seconds raw_bytes archive_bytes
  raw_bytes="$(bytes_for "$@")"
  started="$(now)"
  (
    cd "$root"
    /usr/bin/tar -cf - "${@/#$root\//}" | zstd -q -T0 -3 -o "$archive"
  )
  finished="$(now)"
  seconds="$(elapsed "$started" "$finished")"
  archive_bytes="$(stat -f %z "$archive")"
  python3 - "$results" "$label" "$seconds" "$raw_bytes" "$archive_bytes" <<'PY'
import json, sys
out, label, seconds, raw_bytes, archive_bytes = sys.argv[1:]
payload = {
    "kind": "archive",
    "arm": label,
    "compression_seconds": float(seconds),
    "raw_bytes": int(raw_bytes),
    "archive_bytes": int(archive_bytes),
    "compression_ratio": round(int(archive_bytes) / int(raw_bytes), 6) if int(raw_bytes) else None,
}
with open(out, "a", encoding="utf-8") as f:
    f.write(json.dumps(payload, sort_keys=True) + "\n")
print(json.dumps(payload, sort_keys=True))
PY
}

extract_archive() {
  local label="$1" archive="$2" dest="$3"; shift 3
  local started finished seconds
  mkdir -p "$dest"
  started="$(now)"
  if [ "$#" -eq 0 ]; then
    zstd -q -dc "$archive" | /usr/bin/tar -xf - -C "$dest"
  else
    zstd -q -dc "$archive" | /usr/bin/tar -xf - -C "$dest" "$@"
  fi
  finished="$(now)"
  seconds="$(elapsed "$started" "$finished")"
  python3 - "$results" "$label" "$seconds" <<'PY'
import json, sys
out, label, seconds = sys.argv[1:]
payload = {"kind": "extract", "arm": label, "extract_seconds": float(seconds)}
with open(out, "a", encoding="utf-8") as f:
    f.write(json.dumps(payload, sort_keys=True) + "\n")
print(json.dumps(payload, sort_keys=True))
PY
}

reset_roots() {
  rm -rf "$root" "$alt_root"
  mkdir -p "$root" "$artifact_dir"
}

restore_support() {
  extract_archive "support_restore" "$support_archive" "$root"
}

transition_to_head() {
  local wt="$1"
  git -C "$wt" fetch --depth 2 origin "$head_sha"
  git -C "$wt" checkout --detach "$head_sha"
  git -C "$wt" reset --hard "$head_sha"
  git -C "$wt" clean -ffd
  git -C "$wt" submodule update --init --recursive --depth 1 ||     git -C "$wt" submodule update --init --recursive
  git -C "$wt" submodule foreach --recursive 'git reset --hard && git clean -ffd'
}

make_synthetic_merge() {
  local wt="$1"
  git -C "$wt" fetch --depth 2 origin "$head_sha"
  git -C "$wt" checkout --detach "$base_sha"
  git -C "$wt" reset --hard "$base_sha"
  git -C "$wt" clean -ffd
  git -C "$wt" -c user.name="cmux canary" -c user.email="canary@invalid.local"     merge --no-ff --no-edit "$head_sha"
}

seed() {
  reset_roots
  record_environment
  clone_at "$base_sha" "$worktree"
  prepare_ghostty "$worktree"
  resolve_packages "$worktree" "$derived"
  build_all "seed_cold_A" "$worktree" "$derived"
  write_seed_manifest "$worktree"

  compress_paths "generation_A" "$generation_archive" "$worktree" "$derived"
  compress_paths "support_A" "$support_archive" "$source_packages" "$cas"

  local gen_bytes
  gen_bytes="$(stat -f %z "$generation_archive")"
  local viable=true
  if [ "$gen_bytes" -gt "$transport_cap_bytes" ]; then
    viable=false
  fi
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    {
      echo "transport_viable=$viable"
      echo "generation_archive_bytes=$gen_bytes"
    } >> "$GITHUB_OUTPUT"
  fi
  python3 - "$results" "$gen_bytes" "$transport_cap_bytes" "$viable" <<'PY'
import json, sys
out, size, cap, viable = sys.argv[1:]
payload = {
    "kind": "transport_gate",
    "generation_archive_bytes": int(size),
    "cap_bytes": int(cap),
    "transport_viable": viable == "true",
}
with open(out, "a", encoding="utf-8") as f:
    f.write(json.dumps(payload, sort_keys=True) + "\n")
print(json.dumps(payload, sort_keys=True))
PY
}

consumer() {
  record_environment

  # Arm 1: current disposable-runner analogue: fresh checkout at B, no DerivedData,
  # with the already-existing support caches restored separately.
  reset_roots
  restore_support
  clone_at "$head_sha" "$worktree"
  prepare_ghostty "$worktree"
  compare_seed_manifest "fresh_checkout_cold_dd_B" "$worktree"
  resolve_packages "$worktree" "$derived"
  build_all "fresh_checkout_cold_dd_B" "$worktree" "$derived"

  # Arm 2: fresh checkout at B plus A's DerivedData, restored at the identical path.
  reset_roots
  restore_support
  extract_archive "restore_derived_only" "$generation_archive" "$root" "derived-data"
  clone_at "$head_sha" "$worktree"
  prepare_ghostty "$worktree"
  compare_seed_manifest "fresh_checkout_restored_dd_A_to_B" "$worktree"
  resolve_packages "$worktree" "$derived"
  build_all "fresh_checkout_restored_dd_A_to_B" "$worktree" "$derived"

  # Arm 3: restore the A worktree and DerivedData together at the identical paths,
  # then advance the existing checkout to B.
  reset_roots
  restore_support
  extract_archive "restore_generation_same_path" "$generation_archive" "$root"
  transition_to_head "$worktree"
  compare_seed_manifest "restored_worktree_restored_dd_A_to_B" "$worktree"
  resolve_packages "$worktree" "$derived"
  build_all "restored_worktree_restored_dd_A_to_B" "$worktree" "$derived"

  # Arm 4: same A generation, relocated to another absolute path without a source
  # change. This isolates path sensitivity.
  reset_roots
  restore_support
  extract_archive "restore_generation_relocated" "$generation_archive" "$alt_root"
  local alt_worktree="$alt_root/worktree"
  local alt_derived="$alt_root/derived-data"
  compare_seed_manifest "relocated_same_commit_A" "$alt_worktree"
  resolve_packages "$alt_worktree" "$alt_derived"
  build_all "relocated_same_commit_A" "$alt_worktree" "$alt_derived"

  # Arm 5: synthetic PR merge commit produced by merging B into restored A.
  reset_roots
  restore_support
  extract_archive "restore_generation_for_merge" "$generation_archive" "$root"
  make_synthetic_merge "$worktree"
  compare_seed_manifest "restored_generation_synthetic_merge" "$worktree"
  resolve_packages "$worktree" "$derived"
  build_all "restored_generation_synthetic_merge" "$worktree" "$derived"
}

case "$mode" in
  seed) seed ;;
  consumer) consumer ;;
  *) echo "usage: $0 seed|consumer BASE_SHA HEAD_SHA ARTIFACT_DIR" >&2; exit 64 ;;
esac
