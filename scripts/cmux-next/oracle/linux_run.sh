#!/usr/bin/env bash
# linux_run.sh: build the cmux-tui daemon the correctness oracle runs, at exact SHAs, on Linux.
#
#   linux_run.sh build [REF] [--checkout DIR] [--target-dir DIR] [--receipt FILE] [--leaf-rebuild]
#                      [--keep-src] [--profile P] [--features F]
#       With REF and no --checkout: builds REF in its own tree under ORACLE_WT_ROOT (below).
#       With --checkout DIR or no REF: builds DIR (default: this script's checkout) in place; REF,
#       when given, must be its HEAD, and its ghostty-next must be at the gitlink.
#       The last stdout line is the cmux-tui binary (the contract oracle.py's build_daemon reads);
#       logs go to stderr. --leaf-rebuild also times a rebuild after touching the leaf crate root.
#   linux_run.sh diff BASE HEAD [--out DIR] [--keep-src] [--clean] [--profile P] [--features F]
#                     [-- ORACLE_DIFF_ARGS...]
#       Builds both SHAs at once (one build when they are the same), then runs `oracle.py diff
#       --base SHA --head SHA --base-binary B --head-binary H --out DIR ARGS`, which compares the
#       two runs through diff.py. DIR/linux-run.json holds both build receipts (exact SHAs, every
#       gitlink) and the comparison. --clean also removes both target dirs. Exits with oracle.py's code.
#   linux_run.sh clean [--targets] [--all]
#       Removes source trees no build holds; --targets also the target dirs; --all all of ORACLE_WT_ROOT.
#
# Everything a REF build writes is under ORACLE_WT_ROOT (default /tmp/oracle-wt):
#   src/<key>     the tree of one build: a `git clone --shared` of this checkout at the SHA, so the
#                 checkout's .git never gets worktree or submodule entries. Removed when the build
#                 ends, also on failure, SIGINT and SIGTERM (--keep-src keeps it).
#   target/<key>  CARGO_TARGET_DIR of one (sha, profile, features, zig) plus build.json, the cache
#                 record (a matching binary hash is a hit). A build removes target dirs no build
#                 has used for ORACLE_WT_TARGET_TTL_MIN minutes (default 360).
#   ref/ghostty-next.git  the shared submodule --reference: a bare repo that borrows the
#                 checkout's submodule objects through alternates and fetches a missing gitlink.
#   cache/zig     ZIG_GLOBAL_CACHE_DIR shared by all builds (content-addressed packages).
#   locks/        one flock per build key and one for the reference.
# diff output goes to --out (default /tmp/oracle/runs/linux-<time>-<pid>), never into the checkout.
# This is depot_tools' model: one bare git cache per repo (git_cache.py) that every gclient checkout
# borrows objects from (gclient_scm.py, --reference), and a checkout per revision for bisects.
#
# Each tree initializes ghostty-next at its own SHA's gitlink, and cargo runs with CMUX_GHOSTTY_SRC
# unset, so one SHA's daemon is never built against another SHA's libghostty-vt.
#
# Environment: ORACLE_WT_ROOT, ORACLE_REPO (default: the checkout holding this script),
# ORACLE_WT_TARGET_TTL_MIN, ORACLE_CARGO_JOBS (default: cargo's for one build, half the CPUs each for
# two), ZIG. Exit codes: 0 ok, 1 build failed, 2 usage or setup error; diff: oracle.py's code.
#
# Spec: plans/cmux-next/chrome-parity/p15-oracle.md, section 3F.1, tasks 201 and 024.
set -euo pipefail
shopt -s inherit_errexit

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="${ORACLE_WT_ROOT:-/tmp/oracle-wt}"
TARGET_TTL_MIN="${ORACLE_WT_TARGET_TTL_MIN:-360}"
SUBMODULE="ghostty-next"
BUILD_SCHEMA="cmux-oracle-build-v2"
RUN_SCHEMA="cmux-oracle-linux-run-v1"

log() { printf 'linux_run.sh: %s\n' "$*" >&2; }
die() { printf 'linux_run.sh: %s\n' "$*" >&2; exit 2; }
usage() { sed -n '2,19p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 2; }

# Git in our own trees: no hooks from the caller's config; local paths allowed as submodule URLs.
g() { git -c core.hooksPath=/dev/null -c advice.detachedHead=false -c protocol.file.allow=always "$@"; }

ms_between() { awk -v a="$1" -v b="$2" 'BEGIN { printf "%d", (b - a) * 1000 + 0.5 }'; }

check_root() {
  case "$ROOT" in /*) ;; *) die "ORACLE_WT_ROOT must be absolute: $ROOT" ;; esac
  ROOT="${ROOT%/}"
  case "$ROOT" in "" | / | /tmp | "$HOME") die "ORACLE_WT_ROOT must be a directory of its own, not $ROOT" ;; esac
  if ! [[ "$TARGET_TTL_MIN" =~ ^[0-9]+$ ]] || ((TARGET_TTL_MIN < 60)); then
    die "ORACLE_WT_TARGET_TTL_MIN must be a number of minutes >= 60: $TARGET_TTL_MIN"
  fi
}

repo_root() {
  local repo="${ORACLE_REPO:-}"
  [[ -n "$repo" ]] || repo="$(git -C "$HERE" rev-parse --show-toplevel)" || die "not inside a cmux checkout: $HERE"
  (cd "$repo" && pwd -P)
}

resolve_sha() {
  git -C "$1" rev-parse --verify --quiet "$2^{commit}" || die "unknown commit $2 in $1 (fetch it first)"
}

zig_version() {
  "${ZIG:-zig}" version 2>/dev/null || die "zig not found (\$ZIG or PATH); libghostty-vt needs it"
}

build_key() {
  local sha=$1 zig=$2 features="${FEATURES:-none}"
  printf '%s-%s-%s-zig%s\n' "$sha" "$PROFILE" "${features//[^A-Za-z0-9_]/_}" "${zig//[^A-Za-z0-9_.]/_}"
}

# cargo's output directory for a profile name.
profile_dir() {
  case "$1" in
    dev | test) echo debug ;;
    release | bench) echo release ;;
    *) echo "$1" ;;
  esac
}

# JSON receipts and hashes (stdlib only, isolated mode).
PY="$(cat <<'PY'
import hashlib, json, os, platform, subprocess, sys

def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()

def load(path):
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)

def write_atomic(path, value):
    tmp = f"{path}.tmp.{os.getpid()}"
    with open(tmp, "w", encoding="utf-8") as handle:
        json.dump(value, handle, indent=1, sort_keys=True)
        handle.write("\n")
    os.replace(tmp, path)

def gitlinks(src, sha):
    out = subprocess.run(["git", "-C", src, "ls-tree", "-r", "-z", sha], check=True,
                         stdout=subprocess.PIPE).stdout.decode()
    links = {}
    for entry in filter(None, out.split("\0")):
        meta, path = entry.split("\t", 1)
        _mode, kind, obj = meta.split()
        if kind == "commit":
            links[path] = obj
    return dict(sorted(links.items()))

def os_version():
    try:
        with open("/etc/os-release", encoding="utf-8") as handle:
            for line in handle:
                if line.startswith("PRETTY_NAME="):
                    return line.split("=", 1)[1].strip().strip('"')
    except OSError:
        pass
    return platform.release()

def cache_hit(receipt, schema, key, binary):
    try:
        doc = load(receipt)
        return (doc.get("schema") == schema and doc.get("key") == key and doc.get("binary") == binary
                and sha256(binary) == doc.get("binarySha256"))
    except (OSError, ValueError):
        return False

def build_receipt(out, f):
    links = gitlinks(f["src"], f["sha"])
    if links.get(f["submodule"]) != f["checkedOut"]:
        sys.exit(f"{f['submodule']} checked out {f['checkedOut']}, the gitlink is {links.get(f['submodule'])}")
    binary = f["binary"]
    siblings = {}
    for name in ("cmux-tui-host", "cmux-tui-hook"):
        path = os.path.join(os.path.dirname(binary), name)
        if os.path.isfile(path):
            siblings[name] = {"path": path, "sha256": sha256(path)}
    ms = {k: int(f[k]) for k in ("cloneMs", "submoduleMs", "buildMs", "totalMs")}
    ms["leafRebuildMs"] = int(f["leafRebuildMs"]) if f["leafRebuildMs"] else None
    doc = {
        "schema": f["schema"],
        "mode": f["mode"],
        "ref": f["ref"],
        "sha": f["sha"],
        "key": f["key"],
        "profile": f["profile"],
        "features": [x for x in f["features"].split(",") if x],
        "package": "cmux-tui",
        "binary": binary,
        "binarySha256": sha256(binary),
        "siblings": siblings,
        "gitlinks": links,
        "ghosttyNext": {"gitlink": links.get(f["submodule"]), "checkedOut": f["checkedOut"],
                        "reference": f["reference"] or None, "cmuxGhosttySrc": "unset"},
        "toolchain": {"cargo": f["cargo"], "rustc": f["rustc"], "zig": f["zig"]},
        "host": {"name": platform.node(), "os": platform.system(), "osVersion": os_version(),
                 "kernel": platform.release(), "arch": platform.machine(), "cpus": os.cpu_count()},
        "cargoJobs": int(f["jobs"]) if f["jobs"] else os.cpu_count(),
        "targetDir": f["target"],
        "state": f["state"],
        **ms,
        "buildLog": f["log"],
        "cached": False,
    }
    write_atomic(out, doc)

def run_receipt(out, f):
    sides = {}
    for side in ("base", "head"):
        build = load(f[side + "Receipt"])
        sides[side] = {"ref": f[side + "Ref"], "sha": build["sha"], "gitlinks": build["gitlinks"], "build": build}
    comparison = f["comparison"]
    doc = {
        "schema": f["schema"],
        **sides,
        "sameBuild": sides["base"]["build"]["key"] == sides["head"]["build"]["key"],
        "oracle": {"argv": json.loads(f["argv"]), "exit": int(f["exit"])},
        "comparison": load(comparison) if os.path.isfile(comparison) else None,
        "buildMs": int(f["buildMs"]), "oracleMs": int(f["oracleMs"]), "totalMs": int(f["totalMs"]),
    }
    write_atomic(out, doc)

def fields(argv):
    return dict(arg.split("=", 1) for arg in argv)

command, args = sys.argv[1], sys.argv[2:]
if command == "cache-hit":
    sys.exit(0 if cache_hit(*args) else 1)
elif command == "mark-cached":
    source, out, ref = args
    doc = load(source)
    doc.update(cached=True, ref=ref)
    write_atomic(out, doc)
elif command == "build-receipt":
    build_receipt(args[0], fields(args[1:]))
elif command == "run-receipt":
    run_receipt(args[0], fields(args[1:]))
elif command == "argv-json":
    print(json.dumps(args))
else:
    sys.exit(f"unknown helper command {command}")
PY
)"
py() { python3 -I -c "$PY" "$@"; }

# Makes the shared bare reference hold GITLINK and prints its path: it borrows the checkout's
# submodule objects through alternates, and fetches GITLINK from URL only when they lack it.
ensure_reference() {
  local repo=$1 gitlink=$2 url=$3
  local ref="$ROOT/ref/$SUBMODULE.git" alternates lock_fd dir
  mkdir -p "$ROOT/ref" "$ROOT/locks"
  exec {lock_fd}>"$ROOT/locks/ref.lock"
  flock "$lock_fd"
  [[ -d "$ref/objects" ]] || g init --quiet --bare "$ref"
  alternates="$ref/objects/info/alternates"
  mkdir -p "$ref/objects/info"
  touch "$alternates"
  # Append only: a running build may already borrow through an entry.
  for dir in "$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir)/modules/$SUBMODULE/objects" \
             "$(git -C "$repo" rev-parse --path-format=absolute --git-dir)/modules/$SUBMODULE/objects"; do
    if [[ -d "$dir" ]] && ! grep -qxF "$dir" "$alternates"; then
      printf '%s\n' "$dir" >>"$alternates"
    fi
  done
  if ! g --git-dir="$ref" cat-file -e "$gitlink^{commit}" 2>/dev/null; then
    log "fetching $SUBMODULE $gitlink from $url into $ref"
    g --git-dir="$ref" fetch --quiet --no-tags "$url" "$gitlink" || die "cannot fetch $SUBMODULE $gitlink from $url"
  fi
  # A ref makes the gitlink reachable, so a submodule clone from the reference carries it.
  g --git-dir="$ref" update-ref "refs/heads/oracle/$gitlink" "$gitlink"
  exec {lock_fd}>&-
  printf '%s\n' "$ref"
}

# cargo leads its own process group (setsid), so stop_cargo ends every rustc and zig with it.
# Globals, not locals: the EXIT trap runs after the job function's locals are gone.
CARGO_PID=""
JOB_TREE=""
run_cargo() {
  local src=$1 target=$2 jobs=$3 log_file=$4 status=0
  local -a args=(build --locked -p cmux-tui --profile "$PROFILE")
  [[ -z "$FEATURES" ]] || args+=(--features "$FEATURES")
  [[ -z "$jobs" ]] || args+=(-j "$jobs")
  log "cargo ${args[*]} in $src (log: $log_file)"
  (
    cd "$src/cmux-tui"
    unset CMUX_GHOSTTY_SRC
    export CARGO_TARGET_DIR="$target"
    [[ -z "$ZIG_CACHE" ]] || export ZIG_GLOBAL_CACHE_DIR="$ZIG_CACHE"
    exec setsid -w nice -n 10 cargo "${args[@]}"
  ) >>"$log_file" 2>&1 &
  CARGO_PID=$!
  wait "$CARGO_PID" || status=$?
  CARGO_PID=""
  if ((status)); then
    tail -n 40 "$log_file" >&2
    log "cargo build failed in $src (exit $status); full log: $log_file"
    exit 1
  fi
}

stop_cargo() {
  [[ -n "$CARGO_PID" ]] || return 0
  # TERM lets cargo stop its jobs; KILL then stops any rustc or zig still writing.
  kill -TERM -- "-$CARGO_PID" 2>/dev/null || true
  wait "$CARGO_PID" 2>/dev/null || true
  kill -KILL -- "-$CARGO_PID" 2>/dev/null || true
}

# The EXIT trap of a build job: stops cargo, then removes the job's source tree (none in place).
# A second signal (a process-group TERM plus the forwarded one) must not cut the cleanup short.
end_job() {
  trap '' INT TERM
  stop_cargo
  [[ -z "$JOB_TREE" ]] || rm -rf "$JOB_TREE"
}

# Builds one SHA and prints the binary on stdout. Run it only as a background job: the job owns
# its traps, so its EXIT trap stops cargo and removes the tree on every path, and a TERM sent to
# the job reaches them (bash runs a trap only after its foreground child exits).
#   MODE tree: REPO's SHA in ROOT/src/<key>, target ROOT/target/<key>.
#   MODE checkout: REPO itself in place, target TARGET (default REPO/cmux-tui/target).
build_job() {
  local mode=$1 repo=$2 ref=$3 sha=$4 jobs=$5 receipt_copy=$6 target=$7
  local zig key src pdir binary lock_fd reference="" receipt
  [[ -z "$receipt_copy" ]] || mkdir -p "$(dirname "$receipt_copy")"
  local t0 t1 t2 t3 t4 leaf_ms=""
  zig="$(zig_version)"
  pdir="$(profile_dir "$PROFILE")"
  t0=$EPOCHREALTIME

  if [[ "$mode" == tree ]]; then
    key="$(build_key "$sha" "$zig")"
    src="$ROOT/src/$key"
    target="$ROOT/target/$key"
    ZIG_CACHE="$ROOT/cache/zig"
    mkdir -p "$ROOT/src" "$ROOT/target" "$ROOT/locks" "$ZIG_CACHE"
    [[ "$KEEP_SRC" == 1 ]] || JOB_TREE="$src"
    trap end_job EXIT
    trap 'exit 143' TERM
    exec {lock_fd}>"$ROOT/locks/$key.lock"
    flock "$lock_fd"
    binary="$target/$pdir/cmux-tui"
    if ((LEAF_REBUILD == 0)) && py cache-hit "$target/build.json" "$BUILD_SCHEMA" "$key" "$binary"; then
      log "cache hit for $sha: $binary"
      touch "$target"
      [[ -z "$receipt_copy" ]] || py mark-cached "$target/build.json" "$receipt_copy" "$ref"
      printf '%s\n' "$binary"
      exit 0
    fi
    rm -f "$target/build.json"
    rm -rf "$src"
    log "cloning $sha into $src"
    g clone --quiet --shared --no-checkout "$repo" "$src"
    g -C "$src" checkout --quiet --detach "$sha"
    t1=$EPOCHREALTIME

    local gitlink url
    gitlink="$(g -C "$src" ls-tree "$sha" -- "$SUBMODULE" | awk '$2 == "commit" { print $3 }')"
    [[ -n "$gitlink" ]] || die "$sha has no $SUBMODULE gitlink"
    url="$(g -C "$src" config -f .gitmodules "submodule.$SUBMODULE.url")" || die "$sha: no $SUBMODULE url in .gitmodules"
    reference="$(ensure_reference "$repo" "$gitlink" "$url")"
    g -C "$src" submodule init --quiet -- "$SUBMODULE"
    g -C "$src" config "submodule.$SUBMODULE.url" "$reference"
    g -C "$src" submodule update --quiet --reference "$reference" -- "$SUBMODULE"
    receipt="$target/build.json"
  else
    key="checkout"
    src="$repo"
    target="${target:-$repo/cmux-tui/target}"
    ZIG_CACHE=""
    trap end_job EXIT
    trap 'exit 143' TERM
    [[ -f "$src/$SUBMODULE/build.zig" ]] \
      || die "$SUBMODULE is not checked out in $src (git submodule update --init $SUBMODULE)"
    t1=$EPOCHREALTIME
    mkdir -p "$target"
    target="$(cd "$target" && pwd -P)"
    binary="$target/$pdir/cmux-tui"
    receipt="$target/$pdir/oracle-build-receipt.json"
  fi

  local checked_out link
  checked_out="$(g -C "$src/$SUBMODULE" rev-parse HEAD)"
  link="$(g -C "$src" rev-parse "$sha:$SUBMODULE")"
  [[ "$checked_out" == "$link" ]] || die "$SUBMODULE is at $checked_out, the gitlink of $sha is $link"
  case "$PROFILE" in
    dev | release | test | bench) ;;
    *) grep -q "^\[profile\.$PROFILE\]" "$src/cmux-tui/Cargo.toml" \
         || die "$sha has no [profile.$PROFILE] in cmux-tui/Cargo.toml (it predates p15-oracle-201)" ;;
  esac
  t2=$EPOCHREALTIME

  local state=cold log_file="$target/build.log" cargo_v rustc_v
  [[ -e "$binary" ]] && state=warm
  mkdir -p "$target"
  : >"$log_file"
  cargo_v="$(cd "$src/cmux-tui" && cargo -V)"
  rustc_v="$(cd "$src/cmux-tui" && rustc -V)"
  run_cargo "$src" "$target" "$jobs" "$log_file"
  t3=$EPOCHREALTIME
  log "$state build of $sha in $(ms_between "$t2" "$t3") ms"
  if ((LEAF_REBUILD)); then
    touch "$src/cmux-tui/crates/cmux-tui/src/main.rs"
    run_cargo "$src" "$target" "$jobs" "$log_file"
    t4=$EPOCHREALTIME
    leaf_ms="$(ms_between "$t3" "$t4")"
    log "leaf rebuild of $sha in $leaf_ms ms"
  fi
  [[ -x "$binary" ]] || { log "cargo finished but $binary is missing"; exit 1; }

  mkdir -p "$(dirname "$receipt")"
  py build-receipt "$receipt" schema="$BUILD_SCHEMA" mode="$mode" ref="$ref" sha="$sha" key="$key" \
    profile="$PROFILE" features="$FEATURES" binary="$binary" src="$src" submodule="$SUBMODULE" \
    checkedOut="$checked_out" reference="$reference" cargo="$cargo_v" rustc="$rustc_v" zig="$zig" \
    jobs="$jobs" target="$target" state="$state" log="$log_file" \
    cloneMs="$(ms_between "$t0" "$t1")" submoduleMs="$(ms_between "$t1" "$t2")" \
    buildMs="$(ms_between "$t2" "$t3")" leafRebuildMs="$leaf_ms" totalMs="$(ms_between "$t0" "$EPOCHREALTIME")"
  [[ -z "$receipt_copy" ]] || cp "$receipt" "$receipt_copy"
  log "receipt $receipt"
  printf '%s\n' "$binary"
  exit 0
}

# Signals to this script go to every build job as TERM; each job's EXIT trap then cleans up.
BUILD_PIDS=()
forward_signal() {
  trap '' INT TERM
  ((${#BUILD_PIDS[@]} == 0)) || kill -TERM "${BUILD_PIDS[@]}" 2>/dev/null || true
  wait
  exit "$1"
}

# Waits for every job in BUILD_PIDS; returns the highest exit status.
await_builds() {
  local pid code worst=0
  for pid in "${BUILD_PIDS[@]}"; do
    code=0
    wait "$pid" || code=$?
    ((code <= worst)) || worst=$code
  done
  BUILD_PIDS=()
  return "$worst"
}

# Removes DIR when no build holds the lock of its key.
remove_unlocked() {
  local dir=$1 lock_fd
  mkdir -p "$ROOT/locks"
  exec {lock_fd}>"$ROOT/locks/$(basename "$dir").lock"
  if flock -n "$lock_fd"; then
    rm -rf "$dir"
    log "removed $dir"
  else
    log "kept $dir (a build holds it)"
  fi
  exec {lock_fd}>&-
}

# Removes target dirs unused for TARGET_TTL_MIN minutes (a build or a cache hit touches its dir).
# Age, not a count: a binary another run handed out minutes ago is never removed under it.
prune_targets() {
  [[ -d "$ROOT/target" ]] || return 0
  local dir
  while IFS= read -r -d '' dir; do
    remove_unlocked "$dir"
  done < <(find "$ROOT/target" -mindepth 1 -maxdepth 1 -type d -mmin "+$TARGET_TTL_MIN" -print0)
}

parse_options() {
  PROFILE="oracle" FEATURES="oracle" KEEP_SRC=0 CLEAN=0 LEAF_REBUILD=0
  RECEIPT="" OUT="" CHECKOUT="" TARGET_DIR=""
  PASSTHROUGH=() POSITIONAL=()
  while (($#)); do
    case "$1" in
      --profile) PROFILE="${2:?--profile needs a value}"; shift 2 ;;
      --features) FEATURES="${2?--features needs a value}"; shift 2 ;;
      --receipt) RECEIPT="${2:?--receipt needs a file}"; shift 2 ;;
      --out) OUT="${2:?--out needs a directory}"; shift 2 ;;
      --checkout) CHECKOUT="${2:?--checkout needs a directory}"; shift 2 ;;
      --target-dir) TARGET_DIR="${2:?--target-dir needs a directory}"; shift 2 ;;
      --keep-src) KEEP_SRC=1; shift ;;
      --clean) CLEAN=1; shift ;;
      --leaf-rebuild) LEAF_REBUILD=1; shift ;;
      --) shift; PASSTHROUGH=("$@"); break ;;
      -h | --help) usage ;;
      -*) die "unknown option $1" ;;
      *) POSITIONAL+=("$1"); shift ;;
    esac
  done
}

cmd_build() {
  parse_options "$@"
  ((${#POSITIONAL[@]} <= 1)) || die "build takes one REF"
  ((${#PASSTHROUGH[@]} == 0 && CLEAN == 0)) || die "build takes no oracle arguments and no --clean"
  [[ -z "$OUT" ]] || die "build writes its receipt to --receipt FILE"
  local ref="${POSITIONAL[0]:-}" repo sha mode=tree
  if [[ -n "$CHECKOUT" || -z "$ref" ]]; then
    mode=checkout
    repo="$(cd "${CHECKOUT:-$(repo_root)}" && pwd -P)"
    [[ -f "$repo/cmux-tui/Cargo.toml" ]] || die "$repo is not a cmux checkout (no cmux-tui/Cargo.toml)"
    sha="$(git -C "$repo" rev-parse HEAD)"
    if [[ -n "$ref" && "$(resolve_sha "$repo" "$ref")" != "$sha" ]]; then
      die "$ref is not the HEAD of $repo ($sha); drop --checkout to build it in its own tree"
    fi
  else
    [[ -z "$TARGET_DIR" ]] || die "--target-dir is for --checkout builds; a REF build uses $ROOT/target/<key>"
    repo="$(repo_root)"
    sha="$(resolve_sha "$repo" "$ref")"
  fi
  build_job "$mode" "$repo" "${ref:-HEAD}" "$sha" "${ORACLE_CARGO_JOBS:-}" "$RECEIPT" "$TARGET_DIR" &
  BUILD_PIDS=($!)
  local status=0
  await_builds || status=$?
  [[ "$mode" != tree ]] || prune_targets
  return "$status"
}

cmd_diff() {
  parse_options "$@"
  ((${#POSITIONAL[@]} == 2)) || die "diff takes BASE and HEAD"
  [[ -z "$RECEIPT$CHECKOUT$TARGET_DIR" ]] || die "diff takes no --receipt, --checkout or --target-dir (its receipt is --out DIR/linux-run.json)"
  ((LEAF_REBUILD == 0)) || die "--leaf-rebuild is a build option"
  local repo base_ref="${POSITIONAL[0]}" head_ref="${POSITIONAL[1]}" base_sha head_sha zig out
  repo="$(repo_root)"
  base_sha="$(resolve_sha "$repo" "$base_ref")"
  head_sha="$(resolve_sha "$repo" "$head_ref")"
  zig="$(zig_version)"
  out="${OUT:-/tmp/oracle/runs/linux-$(date -u +%Y%m%dT%H%M%SZ)-$$}"
  case "$out" in /*) ;; *) out="$PWD/$out" ;; esac
  case "$out/" in "$repo"/*) die "--out $out: run output stays outside the checkout" ;; esac
  mkdir -p "$out"

  local t0 t1 t2 side sha ref jobs status=0
  local -a sides=(base head)
  t0=$EPOCHREALTIME
  if [[ "$(build_key "$base_sha" "$zig")" == "$(build_key "$head_sha" "$zig")" ]]; then
    log "base and head are one build ($base_sha)"
    sides=(base)
    jobs="${ORACLE_CARGO_JOBS:-}"
  else
    jobs="${ORACLE_CARGO_JOBS:-$(($(nproc) / 2))}"
  fi
  for side in "${sides[@]}"; do
    if [[ "$side" == base ]]; then sha=$base_sha ref=$base_ref; else sha=$head_sha ref=$head_ref; fi
    rm -f "$out/build-$side.json"
    build_job tree "$repo" "$ref" "$sha" "$jobs" "$out/build-$side.json" "" \
      >"$out/build-$side.path" 2>"$out/build-$side.log" &
    BUILD_PIDS+=($!)
    log "building $side $sha (log: $out/build-$side.log)"
  done
  await_builds || status=$?
  prune_targets
  if ((status)); then
    for side in "${sides[@]}"; do
      [[ -s "$out/build-$side.json" ]] || { tail -n 40 "$out/build-$side.log" >&2; log "$side build failed"; }
    done
    exit "$status"
  fi
  if ((${#sides[@]} == 1)); then
    cp "$out/build-base.json" "$out/build-head.json"
    cp "$out/build-base.path" "$out/build-head.path"
  fi
  local base_bin head_bin
  base_bin="$(tail -n 1 "$out/build-base.path")"
  head_bin="$(tail -n 1 "$out/build-head.path")"
  t1=$EPOCHREALTIME

  # oracle.py stays in the foreground, so a Ctrl-C reaches it and its drivers tear down.
  local -a oracle_argv=(python3 -I "$HERE/oracle.py" diff --base "$base_sha" --head "$head_sha"
    --base-binary "$base_bin" --head-binary "$head_bin" --out "$out" "${PASSTHROUGH[@]}")
  log "${oracle_argv[*]}"
  "${oracle_argv[@]}" || status=$?
  t2=$EPOCHREALTIME

  py run-receipt "$out/linux-run.json" schema="$RUN_SCHEMA" \
    baseReceipt="$out/build-base.json" headReceipt="$out/build-head.json" \
    baseRef="$base_ref" headRef="$head_ref" argv="$(py argv-json "${oracle_argv[@]}")" exit="$status" \
    comparison="$out/comparison.json" buildMs="$(ms_between "$t0" "$t1")" \
    oracleMs="$(ms_between "$t1" "$t2")" totalMs="$(ms_between "$t0" "$EPOCHREALTIME")"
  log "receipt $out/linux-run.json (oracle exit $status, $(ms_between "$t0" "$EPOCHREALTIME") ms)"
  if ((CLEAN)); then
    remove_unlocked "$(dirname "$(dirname "$base_bin")")"
    [[ "$head_bin" == "$base_bin" ]] || remove_unlocked "$(dirname "$(dirname "$head_bin")")"
  fi
  exit "$status"
}

cmd_clean() {
  local targets=0 all=0 dir lock lock_fd busy=0
  while (($#)); do
    case "$1" in
      --targets) targets=1; shift ;;
      --all) targets=1 all=1; shift ;;
      *) usage ;;
    esac
  done
  [[ -d "$ROOT" ]] || return 0
  for dir in "$ROOT"/src/*; do [[ ! -e "$dir" ]] || remove_unlocked "$dir"; done
  if ((targets)); then
    for dir in "$ROOT"/target/*; do [[ ! -e "$dir" ]] || remove_unlocked "$dir"; done
  fi
  ((all)) || return 0
  for lock in "$ROOT"/locks/*.lock; do
    [[ -e "$lock" ]] || continue
    exec {lock_fd}>"$lock"
    flock -n "$lock_fd" || busy=1
    exec {lock_fd}>&-
  done
  if ((busy)); then
    log "kept $ROOT: a build is running"
  else
    rm -rf "$ROOT"
    log "removed $ROOT"
  fi
}

main() {
  (($#)) || usage
  [[ "$(uname -s)" == Linux ]] || die "the oracle daemon build runs on Linux only"
  check_root
  trap 'forward_signal 130' INT
  trap 'forward_signal 143' TERM
  local command=$1
  shift
  case "$command" in
    build) cmd_build "$@" ;;
    diff) cmd_diff "$@" ;;
    clean) cmd_clean "$@" ;;
    -h | --help | help) usage ;;
    *) die "unknown command $command (commands: build, diff, clean)" ;;
  esac
}

main "$@"
