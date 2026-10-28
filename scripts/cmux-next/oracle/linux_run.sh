#!/usr/bin/env bash
# linux_run.sh: daemon-side oracle builds and suite runs on the Linux VM, every one through the
# runnerd.py queue (spec plans/cmux-next/chrome-parity/p15-oracle.md 3F, 3G).
#
#   linux_run.sh build REF [--profile P] [--features F] [--mutant PATCH] [--coverage] [--leaf-rebuild] [--receipt FILE] [--fresh]
#       Builds cmux-tui at REF. The last stdout line is the binary path.
#       The build receipt (cmux-oracle-build-v1: sha, every gitlink, rustc, cold or warm, times, binary
#       sha256) is build.json next to the binary, copied to FILE. --leaf-rebuild also times a rebuild
#       after touching crates/cmux-tui/src/main.rs (task 201's incremental number). --mutant applies a seeded
#       fault (tests/oracle/mutants/daemon/<name>.patch) to the job worktree before cargo runs;
#       the receipt's `mutant` names it, and mutant builds share one target dir per SHA, apart from the clean one.
#       --coverage builds with `-C instrument-coverage` for the host target only (build scripts and proc
#       macros stay plain), in its own target dir; the receipt's `coverage` names the llvm-profdata and
#       llvm-cov of the SHA's own toolchain and the source root to strip from the mapped paths.
#   linux_run.sh run REF [--suite S] [--arm A] [--side L] [--profile P] [--features F] [--mutant PATCH] [--coverage] [--receipt FILE] [--fresh] [-- ORACLE_RUN_ARGS...]
#       Builds REF, then `oracle.py run --binary BIN --ref SHA` in the queue. The last stdout line is the
#       run directory; the exit code is oracle.py's. --arm is NAME=old|new, launch-config or - (default).
#       --side names one of two otherwise identical runs (a diff of one SHA against itself). --receipt
#       copies the build receipt (exact SHA, every gitlink) to FILE (`oracle.py diff --base --head`, task 112).
#       --coverage runs the instrumented build with LLVM_PROFILE_FILE in the job (hermetic_env.py passes it
#       to every case process) and merges the counters into RUN_DIR/coverage.profdata; coverage.py reads it.
#   linux_run.sh diff BASE HEAD [--suite S] [--profile P] [--features F] [--mutant PATCH] [--out DIR] [--fresh] [-- ORACLE_RUN_ARGS...]
#       Both runs (builds and suites in parallel, joined with any identical request), then
#       `oracle.py diff --base-run --head-run --builds DIR/builds.json --out DIR` (default
#       /tmp/oracle/runs/linux-<time>-<pid>, never in the checkout; comparison.json gets both builds). DIR/linux-run.json (cmux-oracle-linux-run-v1) holds both build receipts
#       (exact SHAs, every gitlink), both run dirs and the comparison. Exit code is oracle.py diff's.
#       --mutant builds the head side with the patch: `diff SHA SHA --mutant PATCH` is one mutant's catch check
#       (exit 1, divergences, means the oracle caught it).
#       The base side builds `overlay`'s buildSha, both sides run v0 facets when its plan says v0, and the
#       comparison masks what is not comparable (`oracle.py diff --overlay`); linux-run.json holds the plan.
#   linux_run.sh overlay BASE HEAD [--product P] [--profile P] [--features F] [--out FILE] [--fresh]
#       The base build of a base/head diff (overlay.py prepare): head's oracle commits applied
#       to the base (an overlay commit, built here to prove it builds), the base itself when it has them
#       (native), or v0 facets on both sides when a commit does not apply or the overlay does not build.
#       The last stdout line is the plan file (cmux-oracle-overlay-v1; default
#       /tmp/oracle/overlay/<base12>-<head12>-<product>.json).
#   linux_run.sh walks REF [--profile P] [--features F] [--timeout SEC] [--fresh] [-- WALKS_OPTIONS...]
#       The walks profile: builds REF, then one queued job runs walks_scale.py run on that
#       binary: 100,000 seeded walks of length 30 on arm old and arm new of every daemon switch
#       (oracle.py diff --switch per chunk of 10,000, one build), and every failure minimized (ddmin)
#       before the report. Once the report is written, the minimized walks are copied into
#       tests/oracle/corpus/walks/ of this checkout (to commit). The last stdout line is the job's walks
#       dir (receipt.json, index.md; or unminimized.json and exit 3, with nothing copied). The exit code is
#       walks_scale.py's: 0 clean, 1 failures (all minimized), 2 infrastructure, 3 refused or unminimized.
#       WALKS_OPTIONS: --switch, --seeds, --first-seed, --length, --chunk, --jobs, --minimize-all,
#       --minimize-jobs, --keep. --timeout defaults to 86400 s.
#   linux_run.sh status [--json] | gc [--budget-gb N]
#
# Each job is keyed (sha, suite, arm, profile) plus the content of this script and the oracle sources,
# so 20 submits of one BASE/HEAD pair build twice and run each side once. A finished build is reused;
# a run is reused only when oracle.py exited 0 (a run with unexpected results, flakes or infra errors
# runs again on the next request), and --fresh reruns one anyway. --shuffle without --seed gets a
# random seed, which is then part of the key. Builds run in RUNNERD_SCRATCH/wt (a `git clone --shared`
# of this repo that runnerd removes when the job ends) with the SHA's VT submodule initialized from its own
# gitlink: ghostty-next, or ghostty for a SHA from before ghostty-next (the cmux-tui tags that
# gen_upgrades.py builds); CMUX_GHOSTTY_SRC is never used. The cargo target dir is
# runnerd's per-SHA, per-feature cache.
# Defaults: profile and feature `oracle`, cargo -j 240. Linux only.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
SELF="$HERE/linux_run.sh"
DEFAULT_PROFILE=oracle
DEFAULT_FEATURES=oracle
CARGO_JOBS=240
BUILD_TIMEOUT=7200
RUN_TIMEOUT=14400
WALKS_TIMEOUT=86400

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
  [[ -n "${RUNNERD_JOB:-}" && -n "${RUNNERD_OUT:-}" ]] || die "$1 runs only inside a runnerd job (use build, run, diff or walks)"
}

# mutant_patch PATCH: the absolute path of a daemon mutant, after patch_mutants.py validated its header and scope.
mutant_patch() {
  local patch="$1"
  [[ -f "$patch" ]] || die "--mutant $patch: no such patch"
  patch="$(cd "$(dirname "$patch")" && pwd)/$(basename "$patch")"
  python3 -I "$HERE/patch_mutants.py" validate "$patch" --product daemon >/dev/null \
    || die "--mutant $patch: not a daemon mutant (tests/oracle/mutants/daemon/<name>.patch)"
  echo "$patch"
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
  local ref="" profile="$DEFAULT_PROFILE" features="$DEFAULT_FEATURES" leaf=0 receipt="" fresh=() mutant="" coverage=0
  while (($#)); do
    case "$1" in
      --profile) profile="${2:?--profile needs a value}"; shift 2 ;;
      --features) features="${2?--features needs a value}"; shift 2 ;;
      --mutant) mutant="${2:?--mutant needs a patch}"; shift 2 ;;
      --coverage) coverage=1; shift ;;
      --leaf-rebuild) leaf=1; shift ;;
      --receipt) receipt="${2:?--receipt needs a file}"; shift 2 ;;
      --fresh) fresh=(--fresh); shift ;;
      -*) die "build: unknown option $1" ;;
      *) [[ -z "$ref" ]] || die "build: one REF"; ref="$1"; shift ;;
    esac
  done
  [[ -n "$ref" ]] || die "build needs REF"
  local sha binary
  sha="$(resolve_sha "$ref")"
  # Features select the artifact, so they select the target dir too; runnerd never runs two jobs in one.
  local tag="feat-${features:-none}"
  # A mutant build keys on the patch's content and builds in the SHA's mutant target dir, so the clean
  # build's cache never holds a mutated crate.
  local mutant_args=()
  if [[ -n "$mutant" ]]; then
    mutant="$(mutant_patch "$mutant")"
    tag="$tag+mutant"
    mutant_args=(--key-path "$mutant" --extra "mutant=$(basename "$mutant" .patch)")
  fi
  # Instrumented objects never share a target dir with plain ones.
  ((coverage)) && tag="$tag+cov"
  binary="$(runnerd submit --sha "$sha" --suite build --profile "$profile" --target-cache --target-tag "${tag//,/+}" \
    --timeout "$BUILD_TIMEOUT" --key-path "$SELF" --extra "features=$features" --extra "leaf=$leaf" \
    --extra "coverage=$coverage" "${mutant_args[@]}" "${fresh[@]}" \
    -- bash "$SELF" _build "$sha" "$profile" "$features" "$leaf" "${mutant:--}" "$coverage" | tail -n 1)"
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
  local sha="$1" profile="$2" features="$3" leaf="$4" mutant="${5:--}" coverage="${6:-0}"
  local target="${RUNNERD_TARGET_DIR:?_build needs runnerd --target-cache}"
  # runnerd removes its scratch dir when the job ends, a timeout or a recovery included.
  local JOB_WT="${RUNNERD_SCRATCH:?_build needs the runnerd scratch dir}/wt"
  unset CMUX_GHOSTTY_SRC
  local common refdir gitlink module=ghostty-next
  common="$(git -C "$REPO" rev-parse --path-format=absolute --git-common-dir)"
  git clone --quiet --shared --no-checkout "$common" "$JOB_WT" >&2
  git -C "$JOB_WT" -c advice.detachedHead=false checkout --quiet --detach "$sha" >&2
  # ghostty-vt-sys builds from ghostty-next; a SHA that predates it builds from ghostty.
  git -C "$JOB_WT" rev-parse --verify --quiet "HEAD:ghostty-next" >/dev/null || module=ghostty
  gitlink="$(git -C "$JOB_WT" rev-parse "HEAD:$module")"
  refdir="$common/modules/$module"
  git -C "$JOB_WT" submodule init "$module" >&2
  local update=(git -C "$JOB_WT" -c protocol.file.allow=always submodule update --checkout)
  if [[ -d "$refdir" ]]; then
    update+=(--reference "$refdir")
    # The local module copy has most gitlinks already; clone from it without the network when it does.
    if git -C "$refdir" cat-file -e "$gitlink^{commit}" 2>/dev/null; then
      git -C "$JOB_WT" config "submodule.$module.url" "$refdir"
    fi
  fi
  "${update[@]}" "$module" >&2
  [[ "$(git -C "$JOB_WT/$module" rev-parse HEAD)" == "$gitlink" ]] || die "$module is not at its gitlink $gitlink"
  # The seeded fault goes into this job's worktree only; the copy in the job output is what was built.
  # The receipt stores patch_mutants.py's own parse of the header, so validation and the record cannot disagree.
  local mutant_copy="" mutant_json=""
  if [[ "$mutant" != - ]]; then
    mutant_json="$(python3 -I "$HERE/patch_mutants.py" validate "$mutant" --product daemon --json)" \
      || die "mutant $mutant is no longer a valid daemon mutant"
    mutant_copy="$RUNNERD_OUT/mutant.patch"
    cp "$mutant" "$mutant_copy"
    git -C "$JOB_WT" apply --check "$mutant_copy" >&2 || die "mutant $(basename "$mutant") does not apply at $sha"
    git -C "$JOB_WT" apply "$mutant_copy" >&2
    echo "linux_run.sh: applied mutant $(basename "$mutant" .patch) at $sha" >&2
  fi

  case "$profile" in
    dev | release | test | bench) ;;
    *) grep -q "^\[profile\.$profile\]" "$JOB_WT/cmux-tui/Cargo.toml" \
         || die "$sha has no [profile.$profile] in cmux-tui/Cargo.toml (the oracle profile is p15-oracle-201)" ;;
  esac
  local cargo_args=(build --locked --profile "$profile" -p cmux-tui -j "$CARGO_JOBS")
  [[ -z "$features" ]] || cargo_args+=(--features "$features")
  local out_dir="$target" cargo_env=() coverage_json=""
  if ((coverage)); then
    # An explicit --target keeps RUSTFLAGS off build scripts and proc macros, which would otherwise write
    # counters into the job worktree while cargo runs them.
    local host sysroot tools
    host="$(cd "$JOB_WT/cmux-tui" && rustc -vV | sed -n 's/^host: //p')"
    [[ -n "$host" ]] || die "rustc -vV names no host triple"
    sysroot="$(cd "$JOB_WT/cmux-tui" && rustc --print sysroot)"
    tools="$sysroot/lib/rustlib/$host/bin"
    if [[ ! -x "$tools/llvm-profdata" || ! -x "$tools/llvm-cov" ]]; then
      # The profile format follows rustc's LLVM, so the tools come from the SHA's own toolchain.
      (cd "$JOB_WT/cmux-tui" && rustup component add llvm-tools) >&2
    fi
    [[ -x "$tools/llvm-profdata" && -x "$tools/llvm-cov" ]] || die "no llvm-profdata and llvm-cov in $tools"
    cargo_args+=(--target "$host")
    out_dir="$target/$host"
    cargo_env=(RUSTFLAGS="-C instrument-coverage")
    coverage_json="$(python3 -I -c 'import json, sys; print(json.dumps(dict(zip(
      ("llvmProfdata", "llvmCov", "sourceRoot", "target"), sys.argv[1:]))))' \
      "$tools/llvm-profdata" "$tools/llvm-cov" "$(cd "$JOB_WT" && pwd -P)" "$host")"
  fi
  local built state=cold t0 build_ms leaf_ms=""
  built="$out_dir/$(profile_dir "$profile")/cmux-tui"
  [[ -e "$built" ]] && state=warm
  t0="$(now)"
  (cd "$JOB_WT/cmux-tui" && env "${cargo_env[@]}" CARGO_TARGET_DIR="$target" cargo "${cargo_args[@]}") >&2
  build_ms="$(elapsed_ms "$t0" "$(now)")"
  echo "linux_run.sh: $state build of $sha in ${build_ms} ms" >&2
  if ((leaf)); then
    touch "$JOB_WT/cmux-tui/crates/cmux-tui/src/main.rs"
    t0="$(now)"
    (cd "$JOB_WT/cmux-tui" && env "${cargo_env[@]}" CARGO_TARGET_DIR="$target" cargo "${cargo_args[@]}") >&2
    leaf_ms="$(elapsed_ms "$t0" "$(now)")"
    echo "linux_run.sh: leaf rebuild of $sha in ${leaf_ms} ms" >&2
  fi

  local binary="$RUNNERD_OUT/cmux-tui"
  [[ -x "$built" ]] || die "cargo finished without $built"
  cp "$built" "$binary"
  git -C "$JOB_WT" ls-tree -r HEAD | awk '$2 == "commit" { print $4 "\t" $3 }' > "$RUNNERD_OUT/gitlinks.tsv"
  # An overlay commit (overlay.py) names its base, head and oracle commits in its trailers.
  local overlay_json
  overlay_json="$(python3 -I "$HERE/overlay.py" describe "$sha" --repo "$JOB_WT")" || die "overlay.py describe $sha failed"
  python3 -I - "$RUNNERD_OUT/build.json" "$sha" "$module" "$gitlink" "$profile" "$features" "$target" "$state" \
    "$build_ms" "$leaf_ms" "$binary" "$RUNNERD_OUT/gitlinks.tsv" "$(cd "$JOB_WT/cmux-tui" && rustc --version)" \
    "$mutant_copy" "$mutant_json" "$coverage_json" "$overlay_json" <<'PY'
import hashlib, json, os, platform, sys
(out, sha, module, gitlink, profile, features, target_dir, state, build_ms, leaf_ms, binary, gitlinks,
 rustc, mutant, mutant_json, coverage, overlay_json) = sys.argv[1:]
def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()
mutant_record = None
if mutant:
    parsed = json.loads(mutant_json)
    mutant_record = {key: parsed[key] for key in ("id", "suite", "exercises", "fault", "files")}
    mutant_record.update(patch=mutant, sha256=sha256(mutant))
with open(gitlinks, encoding="utf-8") as handle:
    links = dict(line.rstrip("\n").split("\t") for line in handle if line.strip())
receipt = {
    "schema": "cmux-oracle-build-v1",
    "sha": sha,
    "ghosttyNext": gitlink if module == "ghostty-next" else None,
    "vtModule": module,
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
    "binarySha256": sha256(binary),
    "mutant": mutant_record,
    "coverage": json.loads(coverage) if coverage else None,
    "overlay": json.loads(overlay_json),
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
  OPT_SUITE=all OPT_ARM=- OPT_SIDE="" OPT_PROFILE="$DEFAULT_PROFILE" OPT_FEATURES="$DEFAULT_FEATURES" OPT_OUT="" OPT_MUTANT=""
  OPT_RECEIPT="" OPT_COVERAGE=() OPT_FRESH=() OPT_REFS=() OPT_PASS=()
  while (($#)); do
    case "$1" in
      --suite) OPT_SUITE="${2:?--suite needs a value}"; shift 2 ;;
      --arm) OPT_ARM="${2:?--arm needs a value}"; shift 2 ;;
      --side) OPT_SIDE="${2:?--side needs a value}"; shift 2 ;;
      --profile) OPT_PROFILE="${2:?--profile needs a value}"; shift 2 ;;
      --features) OPT_FEATURES="${2?--features needs a value}"; shift 2 ;;
      --mutant) OPT_MUTANT="${2:?--mutant needs a patch}"; shift 2 ;;
      --coverage) OPT_COVERAGE=(--coverage); shift ;;
      --out) OPT_OUT="${2:?--out needs a value}"; shift 2 ;;
      --receipt) OPT_RECEIPT="${2:?--receipt needs a file}"; shift 2 ;;
      --fresh) OPT_FRESH=(--fresh); shift ;;
      --) shift; OPT_PASS=("$@"); break ;;
      -*) die "unknown option $1 (oracle.py run options go after --)" ;;
      *) OPT_REFS+=("$1"); shift ;;
    esac
  done
  [[ "$OPT_SIDE" =~ ^[A-Za-z0-9._-]*$ ]] || die "--side $OPT_SIDE: letters, digits and . _ - only"
  local arg seeded=0 shuffled=0
  for arg in "${OPT_PASS[@]}"; do
    case "$arg" in
      --out | --out=* | --binary | --binary=* | --ref | --ref=* | --suite | --suite=* | --switch | --switch=* | --arm | --arm=*)
        die "$arg: set by linux_run.sh (use --suite, --arm and --out before --)" ;;
      --seed | --seed=*) seeded=1 ;;
      --shuffle) shuffled=1 ;;
    esac
  done
  # The order is part of the result, so its seed is part of the key: a later --shuffle request gets
  # its own order instead of the first one's receipt, and both sides of a diff run one order.
  if ((shuffled && !seeded)); then
    OPT_PASS+=(--seed "$(python3 -I -c 'import random; print(random.SystemRandom().randrange(1, 2**31))')")
  fi
}

# run_one SHA [SIDE [RECEIPT [MUTANT]]]: builds (copying the build receipt to RECEIPT; with MUTANT applied),
# then queues the run; prints the run dir; returns oracle.py run's exit code.
run_one() {
  local sha="$1" side="${2:-}" receipt="${3:-}" mutant="${4:-}" binary dir code=0
  local receipt_args=() mutant_args=() profile="$OPT_PROFILE" features="$OPT_FEATURES"
  [[ -z "$receipt" ]] || receipt_args=(--receipt "$receipt")
  [[ -z "$mutant" ]] || mutant_args=(--mutant "$mutant")
  # A SHA from before p15-oracle-201 (a v0 base) has no oracle profile or feature. It builds the dev profile,
  # which has the debug assertions the daemon driver's per-case isolation needs; its build receipt says so.
  local cargo_toml
  cargo_toml="$(git -C "$REPO" show "$sha:cmux-tui/Cargo.toml")" || die "$sha has no cmux-tui/Cargo.toml"
  if [[ "$profile" == "$DEFAULT_PROFILE" ]] && ! grep -q "^\[profile\.$DEFAULT_PROFILE\]" <<<"$cargo_toml"; then
    echo "linux_run.sh: $sha has no [profile.$DEFAULT_PROFILE]; it builds --profile dev with no features" >&2
    profile=dev features=""
  fi
  binary="$(cmd_build "$sha" --profile "$profile" --features "$features" "${receipt_args[@]}" \
    "${mutant_args[@]}" "${OPT_COVERAGE[@]}" | tail -n 1)"
  [[ -x "$binary" ]] || die "build of $sha gave no binary"
  local key_args=() extra_args=() arg
  mapfile -t key_args < <(run_key_paths)
  for arg in "${OPT_PASS[@]}"; do
    extra_args+=(--extra "arg=$arg")
  done
  [[ -z "$side" ]] || extra_args+=(--extra "side=$side")
  [[ -z "$mutant" ]] || extra_args+=(--extra "mutant=$(basename "$mutant" .patch)")
  dir="$(runnerd submit --sha "$sha" --suite "$OPT_SUITE" --arm "$OPT_ARM" --profile "$profile" \
    --timeout "$RUN_TIMEOUT" --hold "$binary" "${key_args[@]}" --extra "binary=$binary" "${extra_args[@]}" \
    "${OPT_FRESH[@]}" -- bash "$SELF" _run "$sha" "$binary" "$OPT_SUITE" "$OPT_ARM" -- "${OPT_PASS[@]}" \
    | tail -n 1)" || code=$?
  [[ -f "$dir/receipt.json" ]] || die "run of $sha wrote no receipt (exit $code)"
  echo "$dir"
  return "$code"
}

cmd_run() {
  parse_run_options "$@"
  ((${#OPT_REFS[@]} == 1)) || die "run needs one REF"
  [[ -z "$OPT_MUTANT" ]] || OPT_MUTANT="$(mutant_patch "$OPT_MUTANT")"
  run_one "$(resolve_sha "${OPT_REFS[0]}")" "$OPT_SIDE" "$OPT_RECEIPT" "$OPT_MUTANT"
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
  local out="$RUNNERD_OUT/run" code=0 profdata="" profraw="$RUNNERD_OUT/profraw"
  # An instrumented build (its receipt has `coverage`) writes counters for every process that exits:
  # one online-merged pool per binary signature (%8m) rather than a file per pid, as Chromium's
  # test runner does (testing/test_env.py, docs/testing/code_coverage.md).
  profdata="$(python3 -I -c 'import json, sys
cov = json.load(open(sys.argv[1], encoding="utf-8")).get("coverage") or {}
print(cov.get("llvmProfdata", ""))' "$(dirname "$binary")/build.json")"
  local profile_env=()
  if [[ -n "$profdata" ]]; then
    mkdir -p "$profraw"
    profile_env=(LLVM_PROFILE_FILE="$profraw/cmux-%8m.profraw")
  fi
  env "${profile_env[@]}" python3 -I "$HERE/oracle.py" run --suite "$suite" "${arm_args[@]}" --binary "$binary" \
    --ref "$sha" --out "$out" "$@" >&2 || code=$?
  # The run dir goes to every waiter whatever the exit; a non-zero exit (unexpected results, flaky cases,
  # infra errors) also makes runnerd rerun the key on the next request instead of reusing this result.
  [[ -f "$out/receipt.json" ]] || exit "$((code == 0 ? 1 : code))"
  if [[ -n "$profdata" ]]; then
    local raws=("$profraw"/*.profraw)
    if [[ -e "${raws[0]}" ]]; then
      # A pool cut short by a SIGKILL during its write is skipped, not fatal to the others.
      "$profdata" merge -sparse --failure-mode=all -o "$out/coverage.profdata" "${raws[@]}" >&2 \
        || die "llvm-profdata could not merge the counters of $sha"
      rm -rf "$profraw"
    else
      echo "linux_run.sh: no process of the $sha run wrote counters (none exited normally)" >&2
    fi
  fi
  echo "$out"
  exit "$code"
}

# --- overlay ----------------------------------------------------------------------------

plan_field() {
  python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1], encoding="utf-8")).get(sys.argv[2]) or "")' "$1" "$2"
}

cmd_overlay() {
  local refs=() product=daemon profile="$DEFAULT_PROFILE" features="$DEFAULT_FEATURES" out="" fresh=()
  while (($#)); do
    case "$1" in
      --product) product="${2:?--product needs a value}"; shift 2 ;;
      --profile) profile="${2:?--profile needs a value}"; shift 2 ;;
      --features) features="${2?--features needs a value}"; shift 2 ;;
      --out) out="${2:?--out needs a file}"; shift 2 ;;
      --fresh) fresh=(--fresh); shift ;;
      -*) die "overlay: unknown option $1" ;;
      *) refs+=("$1"); shift ;;
    esac
  done
  ((${#refs[@]} == 2)) || die "overlay needs BASE and HEAD"
  case "$product" in
    daemon | cli | mcp | tui) ;;
    *) die "overlay --product $product: the VM builds the cmux-tui products (fleet.py makes the app's overlay)" ;;
  esac
  local base head
  base="$(resolve_sha "${refs[0]}")"
  head="$(resolve_sha "${refs[1]}")"
  out="${out:-/tmp/oracle/overlay/${base:0:12}-${head:0:12}-$product.json}"
  case "$out" in /*) ;; *) out="$PWD/$out" ;; esac
  case "$out" in "$REPO"/*) die "--out $out: the plan stays outside the checkout" ;; esac
  local prepare=(python3 -I "$HERE/overlay.py" prepare --repo "$REPO" --base "$base" --head "$head"
    --product "$product" --out "$out")
  "${prepare[@]}" >/dev/null || die "overlay.py prepare $base $head failed"
  local build_sha
  build_sha="$(plan_field "$out" overlaySha)"
  # An overlay that does not build is no base at all: both sides fall back to the facets the base has.
  if [[ -n "$build_sha" ]] && ! (cmd_build "$build_sha" --profile "$profile" --features "$features" "${fresh[@]}") >/dev/null; then
    echo "linux_run.sh: the overlay commit $build_sha does not build; both sides run v0 facets" >&2
    "${prepare[@]}" --v0 "the overlay commit $build_sha does not build (linux_run.sh build --profile $profile --features $features)" \
      >/dev/null || die "overlay.py prepare --v0 $base $head failed"
  fi
  echo "$out"
}

# --- diff -------------------------------------------------------------------------------

cmd_diff() {
  parse_run_options "$@"
  ((${#OPT_REFS[@]} == 2)) || die "diff needs BASE and HEAD"
  [[ -z "$OPT_SIDE" ]] || die "diff: --side is for run (diff names its sides base and head)"
  [[ -z "$OPT_RECEIPT" ]] || die "diff: --receipt is for run (diff writes build-base.json and build-head.json in --out)"
  ((${#OPT_COVERAGE[@]} == 0)) || die "diff: --coverage is for run (coverage.py measures one SHA's runs)"
  local base head base_side="" head_side=""
  base="$(resolve_sha "${OPT_REFS[0]}")"
  head="$(resolve_sha "${OPT_REFS[1]}")"
  # A bad patch is refused before anything is queued.
  [[ -z "$OPT_MUTANT" ]] || OPT_MUTANT="$(mutant_patch "$OPT_MUTANT")"
  # One SHA against itself (a determinism check) must run twice, not join one job and compare it with itself.
  if [[ "$base" == "$head" ]]; then
    base_side=base head_side=head
  fi

  local out="${OPT_OUT:-/tmp/oracle/runs/linux-$(date -u +%Y%m%dT%H%M%SZ)-$$}"
  case "$out" in /*) ;; *) out="$PWD/$out" ;; esac
  case "$out/" in "$REPO"/*) die "--out $out: run output stays outside the checkout" ;; esac
  mkdir -p "$out"
  # Nothing from an earlier diff in the same --out may reach this one's receipt.
  rm -f "$out/linux-run.json" "$out/comparison.json" "$out/builds.json" "$out"/build-{base,head}.json \
    "$out/overlay.json"

  local t0 t1
  t0="$(now)"
  # The base side builds what the overlay plan says, and a v0 plan puts both sides on v0 facets.
  local arg product=daemon previous=""
  for arg in "${OPT_PASS[@]}"; do
    case "$arg" in
      --facets | --facets=*) die "$arg: set by linux_run.sh diff from the overlay plan" ;;
      --product=*) product="${arg#--product=}" ;;
    esac
    [[ "$previous" == --product ]] && product="$arg"
    previous="$arg"
  done
  local plan build_sha
  plan="$(cmd_overlay "$base" "$head" --product "$product" --profile "$OPT_PROFILE" --features "$OPT_FEATURES" \
    --out "$out/overlay.json" "${OPT_FRESH[@]}" | tail -n 1)"
  [[ -f "$plan" ]] || die "no overlay plan for $base $head"
  build_sha="$(plan_field "$plan" buildSha)"
  [[ "$(plan_field "$plan" facets)" == v0 ]] && OPT_PASS+=(--facets v0)
  echo "linux_run.sh: base $base builds $build_sha ($(plan_field "$plan" mode), $(plan_field "$plan" facets) facets)" >&2

  DIFF_TMP="$(mktemp -d "${TMPDIR:-/tmp}/oracle-linux-diff.XXXXXX")"
  trap 'rm -rf "$DIFF_TMP"' EXIT
  (run_one "$build_sha" "$base_side" "$out/build-base.json" > "$DIFF_TMP/base" || true) &
  local base_pid=$!
  (run_one "$head" "$head_side" "$out/build-head.json" "$OPT_MUTANT" > "$DIFF_TMP/head" || true) &
  local head_pid=$!
  wait "$base_pid" "$head_pid"
  local base_dir head_dir
  base_dir="$(tail -n 1 "$DIFF_TMP/base" 2>/dev/null || true)"
  head_dir="$(tail -n 1 "$DIFF_TMP/head" 2>/dev/null || true)"
  [[ -f "$base_dir/receipt.json" ]] || die "base run of $base failed"
  [[ -f "$head_dir/receipt.json" ]] || die "head run of $head failed"
  # Each side's ref, exact SHA and gitlinks go into comparison.json through `oracle.py diff --builds`.
  python3 -I - "$out" "${OPT_REFS[0]}" "${OPT_REFS[1]}" <<'PY'
import json, os, sys
out, base_ref, head_ref = sys.argv[1:]
builds = {}
for side, ref in (("base", base_ref), ("head", head_ref)):
    path = os.path.join(out, f"build-{side}.json")
    with open(path, encoding="utf-8") as handle:
        builds[side] = {"ref": ref, **json.load(handle), "receipt": path}
with open(os.path.join(out, "builds.json"), "w", encoding="utf-8") as handle:
    json.dump(builds, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
  local status=0
  nice -n 10 python3 -I "$HERE/oracle.py" diff --base-run "$base_dir" --head-run "$head_dir" --overlay "$plan" \
    --builds "$out/builds.json" --out "$out" || status=$?
  t1="$(now)"
  python3 -I - "$out" "${OPT_REFS[0]}" "${OPT_REFS[1]}" "$base_dir" "$head_dir" "$status" "$(elapsed_ms "$t0" "$t1")" \
    "$plan" <<'PY'
import json, os, sys
out, base_ref, head_ref, base_run, head_run, status, total_ms, plan = sys.argv[1:]
def load(path):
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)
sides = {}
for side, ref, run in (("base", base_ref, base_run), ("head", head_ref, head_run)):
    build = load(os.path.join(out, f"build-{side}.json"))
    sides[side] = {"ref": ref, "sha": build["sha"], "gitlinks": build["gitlinks"], "build": build, "run": run}
comparison = os.path.join(out, "comparison.json")
doc = {
    "schema": "cmux-oracle-linux-run-v1",
    **sides,
    "sameBuild": sides["base"]["build"]["binarySha256"] == sides["head"]["build"]["binarySha256"],
    "mutant": sides["head"]["build"].get("mutant"),
    "overlay": load(plan),
    "oracleExit": int(status),
    "comparison": load(comparison) if os.path.isfile(comparison) else None,
    "totalMs": int(total_ms),
}
tmp = os.path.join(out, ".linux-run.json.tmp")
with open(tmp, "w", encoding="utf-8") as handle:
    json.dump(doc, handle, indent=2, sort_keys=True)
    handle.write("\n")
os.replace(tmp, os.path.join(out, "linux-run.json"))
PY
  echo "linux_run.sh: receipt $out/linux-run.json (oracle exit $status)" >&2
  return "$status"
}

# --- walks ------------------------------------------------------------------------------

cmd_walks() {
  local ref="" profile="$DEFAULT_PROFILE" features="$DEFAULT_FEATURES" timeout="$WALKS_TIMEOUT" fresh=() pass=()
  while (($#)); do
    case "$1" in
      --profile) profile="${2:?--profile needs a value}"; shift 2 ;;
      --features) features="${2?--features needs a value}"; shift 2 ;;
      --timeout) timeout="${2:?--timeout needs seconds}"; shift 2 ;;
      --fresh) fresh=(--fresh); shift ;;
      --) shift; pass=("$@"); break ;;
      -*) die "walks: unknown option $1 (walks_scale.py options go after --)" ;;
      *) [[ -z "$ref" ]] || die "walks: one REF"; ref="$1"; shift ;;
    esac
  done
  [[ -n "$ref" ]] || die "walks needs REF"
  [[ "$timeout" =~ ^[1-9][0-9]*$ ]] || die "--timeout $timeout: whole seconds"
  local arg
  for arg in "${pass[@]}"; do
    case "$arg" in
      --binary | --binary=* | --sha | --sha=* | --work | --work=* | --commit-dir | --commit-dir=* | --registry | --registry=*)
        die "$arg: set by linux_run.sh walks" ;;
    esac
  done
  local sha binary
  sha="$(resolve_sha "$ref")"
  binary="$(cmd_build "$sha" --profile "$profile" --features "$features" | tail -n 1)"
  [[ -x "$binary" ]] || die "build of $sha gave no binary"
  # Seeds, length and switches are in the arguments and the registry content is a key path, so a clean
  # result (exit 0) of the same request is reused; failures, refusals and unminimized runs run again.
  local key_args=() extra_args=() dir code=0
  mapfile -t key_args < <(run_key_paths)
  for arg in "${pass[@]}"; do
    extra_args+=(--extra "arg=$arg")
  done
  dir="$(runnerd submit --sha "$sha" --suite walks-scale --arm daemon-switches --profile "$profile" \
    --timeout "$timeout" --hold "$binary" "${key_args[@]}" --extra "binary=$binary" "${extra_args[@]}" \
    "${fresh[@]}" -- bash "$SELF" _walks "$sha" "$binary" -- "${pass[@]}" | tail -n 1)" || code=$?
  [[ -n "$dir" && -d "$dir" ]] || die "the walks job of $sha wrote no walks dir (exit $code)"
  # No report means a failure is not minimized: nothing goes into the corpus then.
  if [[ -f "$dir/receipt.json" ]]; then
    local minimized corpus="$REPO/tests/oracle/corpus/walks" case_file
    minimized="$(dirname "$dir")/minimized/walks"
    for case_file in "$minimized"/*.json; do
      [[ -f "$case_file" ]] || continue
      mkdir -p "$corpus"
      cp "$case_file" "$corpus/"
      echo "linux_run.sh: minimized walk $corpus/$(basename "$case_file")" >&2
    done
  fi
  echo "linux_run.sh: walks report $dir (walks_scale.py exit $code)" >&2
  echo "$dir"
  return "$code"
}

job_walks() {
  in_job _walks
  local sha="$1" binary="$2"
  shift 2
  [[ "${1:-}" == "--" ]] && shift
  local work="$RUNNERD_OUT/walks" code=0
  python3 -I "$HERE/walks_scale.py" run --binary "$binary" --sha "$sha" --work "$work" \
    --commit-dir "$RUNNERD_OUT/minimized/walks" "$@" >&2 || code=$?
  [[ -d "$work" ]] || exit "$((code == 0 ? 1 : code))"
  echo "$work"
  exit "$code"
}

# --- main -------------------------------------------------------------------------------

main() {
  local command="${1:-}"
  (($#)) && shift
  # Builds and suite runs never start on a Mac (CLAUDE.md: no local cargo builds); the fleet runs those.
  [[ "$(uname -s)" == Linux ]] || die "the oracle queue runs on the Linux VM only; nothing was queued"
  case "$command" in
    build) cmd_build "$@" ;;
    run) cmd_run "$@" ;;
    diff) cmd_diff "$@" ;;
    overlay) cmd_overlay "$@" ;;
    walks) cmd_walks "$@" ;;
    status | gc) runnerd "$command" "$@" ;;
    _build) job_build "$@" ;;
    _run) job_run "$@" ;;
    _walks) job_walks "$@" ;;
    *) sed -n '2,/^#$/p' "$SELF" | sed '$d; s/^# \{0,1\}//' >&2; exit 2 ;;
  esac
}

main "$@"
