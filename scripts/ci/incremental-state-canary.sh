#!/usr/bin/env bash
set -euo pipefail

ROOT="${CMUX_CANARY_ROOT:-/tmp/cmux-incremental-canary}"
SRC="$ROOT/src"
DERIVED="$ROOT/derived"
PACKAGES="$ROOT/source-packages"
CAS="$ROOT/cas"
MODULE_CACHE="$ROOT/module-cache"

repo_url="${CMUX_CANARY_REPO_URL:-https://github.com/manaflow-ai/cmux.git}"

now_ns() {
  python3 - <<'PY'
import time
print(time.time_ns())
PY
}

elapsed_seconds() {
  python3 - "$1" "$2" <<'PY'
import sys
start, end = map(int, sys.argv[1:])
print(f"{(end-start)/1_000_000_000:.3f}")
PY
}

init_root() {
  rm -rf "$ROOT"
  mkdir -p "$ROOT"
}

clone_source() {
  local sha="$1"
  rm -rf "$SRC"
  git clone --filter=blob:none --no-checkout "$repo_url" "$SRC"
  git -C "$SRC" fetch --no-tags --force origin "$sha"
  git -C "$SRC" checkout --force --detach FETCH_HEAD
  git -C "$SRC" submodule update --init --recursive
}

select_xcode_here() {
  cd "$SRC"
  local xcode_env="$ROOT/xcode.env"
  : > "$xcode_env"
  GITHUB_ENV="$xcode_env" ./scripts/select-ci-xcode.sh
  while IFS= read -r assignment; do
    case "$assignment" in
      DEVELOPER_DIR=*) export "$assignment" ;;
    esac
  done < "$xcode_env"
  if [[ -n "${GITHUB_ENV:-}" && "$GITHUB_ENV" != "$xcode_env" ]]; then
    cat "$xcode_env" >> "$GITHUB_ENV"
  fi
}

setup_build_inputs() {
  mkdir -p "$DERIVED" "$PACKAGES" "$CAS" "$MODULE_CACHE"
  select_xcode_here
  cd "$SRC"
  export PATH="$HOME/.cargo/bin:$PATH"
  export CMUX_SKIP_ZIG_BUILD=1
  ./scripts/install-rust-ci.sh
  ./scripts/download-prebuilt-ghosttykit.sh
  scripts/ci/compile-app-host-test-product.sh resolve "$DERIVED" "$PACKAGES"
}

transition_to() {
  local sha="$1"
  cd "$SRC"
  local unchanged="${CMUX_CANARY_UNCHANGED_FILE:-Sources/AppDelegate.swift}"
  local changed="${CMUX_CANARY_CHANGED_FILE:-Sources/TerminalController.swift}"
  local before_unchanged before_changed after_unchanged after_changed
  before_unchanged="$(stat -f %m "$unchanged")"
  before_changed="$(stat -f %m "$changed")"
  git clean -ffd
  git fetch --no-tags --force origin "$sha"
  git checkout --force --detach FETCH_HEAD
  git submodule update --init --recursive
  after_unchanged="$(stat -f %m "$unchanged")"
  after_changed="$(stat -f %m "$changed")"
  python3 - "$sha" "$before_unchanged" "$after_unchanged" "$before_changed" "$after_changed" <<'PY'
import json, sys
sha, bu, au, bc, ac = sys.argv[1:]
print("CMUX_CANARY_MTIME " + json.dumps({
    "target_sha": sha,
    "unchanged_before": int(bu),
    "unchanged_after": int(au),
    "unchanged_preserved": bu == au,
    "changed_before": int(bc),
    "changed_after": int(ac),
    "changed_rewritten": bc != ac,
}, sort_keys=True))
PY
}

synthetic_merge() {
  local base="$1" head="$2"
  cd "$SRC"
  git fetch --no-tags --force origin "$head"
  git checkout --force --detach "$base"
  git clean -ffd
  git -c user.name='cmux canary' -c user.email='canary@invalid.example'     merge --no-ff --no-edit "$head"
  local merge_sha
  merge_sha="$(git rev-parse HEAD)"
  echo "CMUX_CANARY_SYNTHETIC_MERGE $merge_sha"
}

build_once() {
  local label="$1"
  local log="${CMUX_CANARY_LOG:-${RUNNER_TEMP:-/tmp}/${label}.log}"
  mkdir -p "$DERIVED" "$PACKAGES" "$CAS" "$MODULE_CACHE"
  select_xcode_here
  cd "$SRC"
  export PATH="$HOME/.cargo/bin:$PATH"
  export CMUX_SKIP_ZIG_BUILD=1
  local start end status
  start="$(now_ns)"
  set +e
  xcodebuild -project cmux.xcodeproj -scheme cmux -configuration Debug     -derivedDataPath "$DERIVED"     -clonedSourcePackagesDirPath "$PACKAGES"     -disableAutomaticPackageResolution     -destination "platform=macOS"     -showBuildTimingSummary     'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) CMUX_CI_APP_HOST_ISOLATION_REQUIRED'     'LD_RUNPATH_SEARCH_PATHS=$(inherited) @executable_path/../Frameworks /private/tmp/cmux-app-host-package-frameworks'     COMPILATION_CACHE_ENABLE_CACHING=YES     "COMPILATION_CACHE_CAS_PATH=$CAS"     COMPILATION_CACHE_LIMIT_SIZE=3221225472     "CLANG_MODULE_CACHE_PATH=$MODULE_CACHE"     build-for-testing 2>&1 | tee "$log"
  status="${PIPESTATUS[0]}"
  set -e
  end="$(now_ns)"
  python3 - "$label" "$log" "$(elapsed_seconds "$start" "$end")" "$ROOT" "$status" <<'PY'
import json, os, re, subprocess, sys

label, log_path, wall, root, status = sys.argv[1:]
text = open(log_path, "r", errors="replace").read()
lines = text.splitlines()

def du(path):
    if not os.path.exists(path):
        return 0
    out = subprocess.check_output(["du", "-sk", path], text=True).split()[0]
    return int(out) * 1024

swift_compile = sum("SwiftCompile" in line for line in lines)
cache_hit_lines = [line.strip() for line in lines if re.search(r"\bcache\b.*\bhit\b|\bhit\b.*\bcache\b", line, re.I)]
cache_miss_lines = [line.strip() for line in lines if re.search(r"\bcache\b.*\bmiss\b|\bmiss\b.*\bcache\b", line, re.I)]
cache_evidence = [line.strip() for line in lines if re.search(r"compilation cache|cacheable|cache hit|cache miss", line, re.I)][:40]

timing = {}
timing_evidence = []
for line in lines:
    if "seconds" not in line:
        continue
    if re.search(r"Swift|EmitModule|CompileSwift", line, re.I):
        timing_evidence.append(line.strip())
    m = re.search(r"^\s*([^|]+?)\s*(?:\([^)]*\))?\s*\|\s*([0-9.]+)\s+seconds", line)
    if not m:
        m = re.search(r"^\s*([^:]+?):\s*([0-9.]+)\s+seconds", line)
    if m:
        timing[m.group(1).strip()] = float(m.group(2))

emit_candidates = [v for k, v in timing.items() if re.search(r"emit.*module|module.*emit", k, re.I)]
emit_module_seconds = sum(emit_candidates) if emit_candidates else None

payload = {
    "label": label,
    "wall_seconds": float(wall),
    "status": int(status),
    "commit": subprocess.check_output(["git", "-C", os.path.join(root, "src"), "rev-parse", "HEAD"], text=True).strip(),
    "swift_compile_lines": swift_compile,
    "emit_module_seconds": emit_module_seconds,
    "timing_summary": timing,
    "timing_evidence": timing_evidence[-30:],
    "cas_hit_lines": len(cache_hit_lines),
    "cas_miss_lines": len(cache_miss_lines),
    "cache_evidence": cache_evidence,
    "disk_bytes": {
        "source": du(os.path.join(root, "src")),
        "derived": du(os.path.join(root, "derived")),
        "source_packages": du(os.path.join(root, "source-packages")),
        "cas": du(os.path.join(root, "cas")),
        "module_cache": du(os.path.join(root, "module-cache")),
        "total": du(root),
    },
}
print("CMUX_CANARY_METRICS " + json.dumps(payload, sort_keys=True))
PY
  return "$status"
}

archive_state() {
  local archive="$1"
  local parent base start end bytes
  parent="$(dirname "$ROOT")"
  base="$(basename "$ROOT")"
  rm -f "$archive"
  start="$(now_ns)"
  COPYFILE_DISABLE=1 tar -C "$parent" -czf "$archive" "$base"
  end="$(now_ns)"
  bytes="$(stat -f %z "$archive")"
  python3 - "$archive" "$bytes" "$(elapsed_seconds "$start" "$end")" <<'PY'
import json, sys
archive, size, seconds = sys.argv[1:]
print("CMUX_CANARY_ARCHIVE " + json.dumps({
    "archive": archive,
    "archive_bytes": int(size),
    "compression_seconds": float(seconds),
}, sort_keys=True))
PY
}

extract_state() {
  local archive="$1"
  local parent start end
  parent="$(dirname "$ROOT")"
  rm -rf "$ROOT"
  mkdir -p "$parent"
  start="$(now_ns)"
  COPYFILE_DISABLE=1 tar -C "$parent" -xzf "$archive"
  end="$(now_ns)"
  python3 - "$(elapsed_seconds "$start" "$end")" "$ROOT" <<'PY'
import json, subprocess, sys
seconds, root = sys.argv[1:]
out = subprocess.check_output(["du", "-sk", root], text=True).split()[0]
print("CMUX_CANARY_EXTRACT " + json.dumps({
    "extract_seconds": float(seconds),
    "restored_bytes": int(out) * 1024,
}, sort_keys=True))
PY
}

case "${1:-}" in
  init-root)
    init_root
    ;;
  clone-source)
    clone_source "${2:?sha required}"
    ;;
  setup)
    setup_build_inputs
    ;;
  transition)
    transition_to "${2:?sha required}"
    ;;
  synthetic-merge)
    synthetic_merge "${2:?base required}" "${3:?head required}"
    ;;
  build)
    build_once "${2:?label required}"
    ;;
  archive)
    archive_state "${2:?archive required}"
    ;;
  extract)
    extract_state "${2:?archive required}"
    ;;
  *)
    echo "usage: $0 {init-root|clone-source SHA|setup|transition SHA|synthetic-merge BASE HEAD|build LABEL|archive PATH|extract PATH}" >&2
    exit 64
    ;;
esac
