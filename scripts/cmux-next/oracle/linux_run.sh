#!/usr/bin/env bash
# linux_run.sh: daemon-side oracle builds and suite runs on the Linux VM, every one through the
# runnerd.py queue (p15-oracle-007, p15-oracle-024; spec plans/cmux-next/chrome-parity/p15-oracle.md 3F, 3G).
#
#   linux_run.sh build REF [--profile P] [--features F] [--leaf-rebuild] [--receipt FILE]
#       Builds cmux-tui at REF. The last stdout line is the binary path (oracle.py build_daemon reads it).
#       The build receipt (cmux-oracle-build-v1: sha, every gitlink, rustc, cold or warm, times, binary
#       sha256) is build.json next to the binary, copied to FILE. --leaf-rebuild also times a rebuild
#       after touching crates/cmux-tui/src/main.rs (task 201's incremental number).
#   linux_run.sh run REF [--suite S] [--arm A] [--profile P] [--features F] [-- ORACLE_RUN_ARGS...]
#       Builds REF, then `oracle.py run --binary BIN --ref SHA` in the queue. The last stdout line is the
#       run directory; the exit code is oracle.py's. --arm is NAME=old|new, launch-config or - (default).
#   linux_run.sh diff BASE HEAD [--suite S] [--profile P] [--features F] [--out DIR] [-- ORACLE_RUN_ARGS...]
#       Both runs (builds and suites in parallel, joined with any identical request), then
#       `oracle.py diff --base-run --head-run`. Exit code is oracle.py diff's.
#   linux_run.sh status [--json] | gc [--budget-gb N]
#
# Each job is keyed (sha, suite, arm, profile) plus the content of this script and the oracle sources,
# so 20 submits of one BASE/HEAD pair build twice and run each side once; a finished key is reused.
# Builds run in /tmp/oracle-wt/<job> (a `git clone --shared` of this repo, removed after the build) with
# ghostty-next initialized from the SHA's own gitlink; CMUX_GHOSTTY_SRC is never used. The cargo target
# dir is runnerd's per-SHA cache. Defaults: profile and feature `oracle` (p15-oracle-201), cargo -j 240.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
SELF="$HERE/linux_run.sh"
WT_BASE=/tmp/oracle-wt
DEFAULT_PROFILE=oracle
DEFAULT_FEATURES=oracle
CARGO_JOBS=240
BUILD_TIMEOUT=7200
RUN_TIMEOUT=14400

die() {
  echo "linux_run.sh: $*" >&2
  exit 2
}

runnerd() {
  python3 -I "$HERE/runnerd.py" "$@"
}

resolve_sha() {
  git -C "$REPO" rev-parse --verify --quiet "$1^{commit}" || die "$1: not a commit in $REPO"
}

in_job() {
  [[ -n "${RUNNERD_JOB:-}" && -n "${RUNNERD_OUT:-}" ]] || die "$1 runs only inside a runnerd job (use build, run or diff)"
}

# Content of everything a run's result depends on besides the binary and the arguments.
run_key_paths() {
  local path
  for path in "$HERE" "$REPO/tests/oracle" "$REPO/schemas/oracle" "$REPO/plans/cmux-next/refactor-switches"; do
    [[ -e "$path" ]] && printf -- '--key-path\n%s\n' "$path"
  done
  return 0
}

# --- build ------------------------------------------------------------------------------

cmd_build() {
  local ref="" profile="$DEFAULT_PROFILE" features="$DEFAULT_FEATURES" leaf=0 receipt=""
  while (($#)); do
    case "$1" in
      --profile) profile="${2:?--profile needs a value}"; shift 2 ;;
      --features) features="${2?--features needs a value}"; shift 2 ;;
      --leaf-rebuild) leaf=1; shift ;;
      --receipt) receipt="${2:?--receipt needs a file}"; shift 2 ;;
      -*) die "build: unknown option $1" ;;
      *) [[ -z "$ref" ]] || die "build: one REF"; ref="$1"; shift ;;
    esac
  done
  [[ -n "$ref" ]] || die "build needs REF"
  local sha binary
  sha="$(resolve_sha "$ref")"
  binary="$(runnerd submit --sha "$sha" --suite build --profile "$profile" --target-cache --timeout "$BUILD_TIMEOUT" \
    --key-path "$SELF" --extra "features=$features" --extra "leaf=$leaf" \
    -- bash "$SELF" _build "$sha" "$profile" "$features" "$leaf" | tail -n 1)"
  [[ -x "$binary" ]] || die "build of $sha gave no binary"
  if [[ -n "$receipt" ]]; then
    mkdir -p "$(dirname "$receipt")"
    cp "$(dirname "$binary")/build.json" "$receipt"
  fi
  echo "$binary"
}

profile_dir() {
  case "$1" in
    dev | test) echo debug ;;
    bench) echo release ;;
    *) echo "$1" ;;
  esac
}

now() {
  echo "${EPOCHREALTIME/,/.}"
}

elapsed_ms() {
  python3 -I -c 'import sys; print(round((float(sys.argv[2]) - float(sys.argv[1])) * 1000))' "$1" "$2"
}

job_build() {
  in_job _build
  local sha="$1" profile="$2" features="$3" leaf="$4"
  local target="${RUNNERD_TARGET_DIR:?_build needs runnerd --target-cache}"
  JOB_WT="$WT_BASE/$RUNNERD_JOB"  # global: the EXIT trap runs after this function returns
  unset CMUX_GHOSTTY_SRC
  mkdir -p "$WT_BASE"
  rm -rf "$JOB_WT"
  trap 'rm -rf "$JOB_WT"' EXIT
  local common refdir gitlink
  common="$(git -C "$REPO" rev-parse --path-format=absolute --git-common-dir)"
  git clone --quiet --shared --no-checkout "$common" "$JOB_WT" >&2
  git -C "$JOB_WT" -c advice.detachedHead=false checkout --quiet --detach "$sha" >&2
  gitlink="$(git -C "$JOB_WT" rev-parse "HEAD:ghostty-next")"
  refdir="$common/modules/ghostty-next"
  git -C "$JOB_WT" submodule init ghostty-next >&2
  local update=(git -C "$JOB_WT" -c protocol.file.allow=always submodule update --checkout)
  if [[ -d "$refdir" ]]; then
    update+=(--reference "$refdir")
    # The local module copy has most gitlinks already; clone from it without the network when it does.
    if git -C "$refdir" cat-file -e "$gitlink^{commit}" 2>/dev/null; then
      git -C "$JOB_WT" config "submodule.ghostty-next.url" "$refdir"
    fi
  fi
  "${update[@]}" ghostty-next >&2
  [[ "$(git -C "$JOB_WT/ghostty-next" rev-parse HEAD)" == "$gitlink" ]] || die "ghostty-next is not at its gitlink $gitlink"

  case "$profile" in
    dev | release | test | bench) ;;
    *) grep -q "^\[profile\.$profile\]" "$JOB_WT/cmux-tui/Cargo.toml" \
         || die "$sha has no [profile.$profile] in cmux-tui/Cargo.toml (the oracle profile is p15-oracle-201)" ;;
  esac
  local feature_args=()
  [[ -z "$features" ]] || feature_args=(--features "$features")
  local built state=cold t0 build_ms leaf_ms=""
  built="$target/$(profile_dir "$profile")/cmux-tui"
  [[ -e "$built" ]] && state=warm
  t0="$(now)"
  (cd "$JOB_WT/cmux-tui" && CARGO_TARGET_DIR="$target" cargo build --locked --profile "$profile" \
    "${feature_args[@]}" -p cmux-tui -j "$CARGO_JOBS") >&2
  build_ms="$(elapsed_ms "$t0" "$(now)")"
  echo "linux_run.sh: $state build of $sha in ${build_ms} ms" >&2
  if ((leaf)); then
    touch "$JOB_WT/cmux-tui/crates/cmux-tui/src/main.rs"
    t0="$(now)"
    (cd "$JOB_WT/cmux-tui" && CARGO_TARGET_DIR="$target" cargo build --locked --profile "$profile" \
      "${feature_args[@]}" -p cmux-tui -j "$CARGO_JOBS") >&2
    leaf_ms="$(elapsed_ms "$t0" "$(now)")"
    echo "linux_run.sh: leaf rebuild of $sha in ${leaf_ms} ms" >&2
  fi

  local binary="$RUNNERD_OUT/cmux-tui"
  [[ -x "$built" ]] || die "cargo finished without $built"
  cp "$built" "$binary"
  git -C "$JOB_WT" ls-tree -r HEAD | awk '$2 == "commit" { print $4 "\t" $3 }' > "$RUNNERD_OUT/gitlinks.tsv"
  python3 -I - "$RUNNERD_OUT/build.json" "$sha" "$gitlink" "$profile" "$features" "$target" "$state" \
    "$build_ms" "$leaf_ms" "$binary" "$RUNNERD_OUT/gitlinks.tsv" "$(cd "$JOB_WT/cmux-tui" && rustc --version)" <<'PY'
import hashlib, json, os, platform, sys
(out, sha, gitlink, profile, features, target_dir, state, build_ms, leaf_ms, binary, gitlinks,
 rustc) = sys.argv[1:]
digest = hashlib.sha256()
with open(binary, "rb") as handle:
    for chunk in iter(lambda: handle.read(1 << 20), b""):
        digest.update(chunk)
with open(gitlinks, encoding="utf-8") as handle:
    links = dict(line.rstrip("\n").split("\t") for line in handle if line.strip())
receipt = {
    "schema": "cmux-oracle-build-v1",
    "sha": sha,
    "ghosttyNext": gitlink,
    "gitlinks": links,
    "profile": profile,
    "features": [f for f in features.split(",") if f],
    "package": "cmux-tui",
    "rustc": rustc,
    "host": {"name": platform.node(), "os": platform.system(), "arch": platform.machine(),
             "cpus": os.cpu_count()},
    "targetDir": target_dir,
    "state": state,
    "buildMs": int(build_ms),
    "leafRebuildMs": int(leaf_ms) if leaf_ms else None,
    "binary": binary,
    "binarySha256": digest.hexdigest(),
}
with open(out, "w", encoding="utf-8") as handle:
    json.dump(receipt, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
  echo "$binary"
}

# --- run --------------------------------------------------------------------------------

# Parses the options shared by run and diff into OPT_* globals; the rest after -- goes to oracle.py run.
parse_run_options() {
  OPT_SUITE=all OPT_ARM=- OPT_PROFILE="$DEFAULT_PROFILE" OPT_FEATURES="$DEFAULT_FEATURES" OPT_OUT=""
  OPT_REFS=() OPT_PASS=()
  while (($#)); do
    case "$1" in
      --suite) OPT_SUITE="${2:?--suite needs a value}"; shift 2 ;;
      --arm) OPT_ARM="${2:?--arm needs a value}"; shift 2 ;;
      --profile) OPT_PROFILE="${2:?--profile needs a value}"; shift 2 ;;
      --features) OPT_FEATURES="${2?--features needs a value}"; shift 2 ;;
      --out) OPT_OUT="${2:?--out needs a value}"; shift 2 ;;
      --) shift; OPT_PASS=("$@"); break ;;
      -*) die "unknown option $1 (oracle.py run options go after --)" ;;
      *) OPT_REFS+=("$1"); shift ;;
    esac
  done
  local arg
  for arg in "${OPT_PASS[@]}"; do
    case "$arg" in
      --out | --out=* | --binary | --binary=* | --ref | --ref=* | --suite | --suite=* | --switch | --switch=* | --arm | --arm=*)
        die "$arg: set by linux_run.sh (use --suite, --arm and --out before --)" ;;
    esac
  done
}

# run_one SHA: builds, then queues the run; prints the run dir; returns oracle.py run's exit code.
run_one() {
  local sha="$1" binary dir
  binary="$(cmd_build "$sha" --profile "$OPT_PROFILE" --features "$OPT_FEATURES" | tail -n 1)"
  [[ -x "$binary" ]] || die "build of $sha gave no binary"
  local key_args=() extra_args=() arg
  mapfile -t key_args < <(run_key_paths)
  for arg in "${OPT_PASS[@]}"; do
    extra_args+=(--extra "arg=$arg")
  done
  dir="$(runnerd submit --sha "$sha" --suite "$OPT_SUITE" --arm "$OPT_ARM" --profile "$OPT_PROFILE" \
    --timeout "$RUN_TIMEOUT" --hold "$binary" "${key_args[@]}" --extra "binary=$binary" "${extra_args[@]}" \
    -- bash "$SELF" _run "$sha" "$binary" "$OPT_SUITE" "$OPT_ARM" -- "${OPT_PASS[@]}" | tail -n 1)"
  [[ -f "$dir/receipt.json" ]] || die "run of $sha wrote no receipt"
  echo "$dir"
  return "$(cat "$(dirname "$dir")/oracle-exit")"
}

cmd_run() {
  parse_run_options "$@"
  ((${#OPT_REFS[@]} == 1)) || die "run needs one REF"
  run_one "$(resolve_sha "${OPT_REFS[0]}")"
}

job_run() {
  in_job _run
  local sha="$1" binary="$2" suite="$3" arm="$4"
  shift 4
  [[ "${1:-}" == "--" ]] && shift
  local arm_args=()
  case "$arm" in
    -) ;;
    launch-config | default) arm_args=(--arm "$arm") ;;
    *=*) arm_args=(--switch "${arm%%=*}" --arm "${arm#*=}") ;;
    *) die "--arm $arm: NAME=old|new, launch-config or -" ;;
  esac
  local out="$RUNNERD_OUT/run" code=0
  python3 -I "$HERE/oracle.py" run --suite "$suite" "${arm_args[@]}" --binary "$binary" --ref "$sha" \
    --out "$out" "$@" >&2 || code=$?
  # A run with unexpected results is still a result to reuse; only a run with no receipt failed.
  [[ -f "$out/receipt.json" ]] || exit "$((code == 0 ? 1 : code))"
  echo "$code" > "$RUNNERD_OUT/oracle-exit"
  echo "$out"
}

# --- diff -------------------------------------------------------------------------------

cmd_diff() {
  parse_run_options "$@"
  ((${#OPT_REFS[@]} == 2)) || die "diff needs BASE and HEAD"
  local base head
  base="$(resolve_sha "${OPT_REFS[0]}")"
  head="$(resolve_sha "${OPT_REFS[1]}")"
  local arg seeded=0 shuffled=0
  for arg in "${OPT_PASS[@]}"; do
    case "$arg" in
      --seed | --seed=*) seeded=1 ;;
      --shuffle) shuffled=1 ;;
    esac
  done
  # Both sides must run one order, and the seed is part of both keys.
  if ((shuffled && !seeded)); then
    OPT_PASS+=(--seed "$(python3 -I -c 'import random; print(random.SystemRandom().randrange(1, 2**31))')")
  fi

  DIFF_TMP="$(mktemp -d "${TMPDIR:-/tmp}/oracle-linux-diff.XXXXXX")"
  trap 'rm -rf "$DIFF_TMP"' EXIT
  (run_one "$base" > "$DIFF_TMP/base" || true) &
  local base_pid=$!
  (run_one "$head" > "$DIFF_TMP/head" || true) &
  local head_pid=$!
  wait "$base_pid" "$head_pid"
  local base_dir head_dir
  base_dir="$(tail -n 1 "$DIFF_TMP/base" 2>/dev/null || true)"
  head_dir="$(tail -n 1 "$DIFF_TMP/head" 2>/dev/null || true)"
  [[ -f "$base_dir/receipt.json" ]] || die "base run of $base failed"
  [[ -f "$head_dir/receipt.json" ]] || die "head run of $head failed"
  local out_args=()
  [[ -z "$OPT_OUT" ]] || out_args=(--out "$OPT_OUT")
  nice -n 10 python3 -I "$HERE/oracle.py" diff --base-run "$base_dir" --head-run "$head_dir" "${out_args[@]}"
}

# --- main -------------------------------------------------------------------------------

main() {
  local command="${1:-}"
  (($#)) && shift
  case "$command" in
    build) cmd_build "$@" ;;
    run) cmd_run "$@" ;;
    diff) cmd_diff "$@" ;;
    status | gc) runnerd "$command" "$@" ;;
    _build) job_build "$@" ;;
    _run) job_run "$@" ;;
    *) sed -n '2,13p' "$SELF" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
  esac
}

main "$@"
