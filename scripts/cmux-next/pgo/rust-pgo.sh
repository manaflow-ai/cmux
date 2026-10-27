#!/usr/bin/env bash
# Profile-guided optimization for the app's Rust code (plans/cmux-next/chrome-parity/p08-startup.md, section F,
# task 056): the daemon (cmux-tui, with cmux-tui-host from the same cargo invocation) and the app's one static
# library (cmux-app-ffi). Chrome's flow without its CI builders (docs/pgo.md, tools/pgo/generate_profile.py,
# build/config/compiler/pgo/pgo.gni): an instrumented build, fixed scenarios on it, an indexed profile pinned by
# sha256, and -Cprofile-use only when that exact profile is present.
#
#   rust-pgo.sh llvm-check [--install]
#   rust-pgo.sh generate [--out DIR]
#   rust-pgo.sh run [--out DIR] [--rounds N] [--tabs N] [--storm-tag TAG]
#   rust-pgo.sh merge [--out DIR] [--pin]
#   rust-pgo.sh rustflags cmux-tui|cmux-app-ffi [--target TRIPLE] [--strict]
#   rust-pgo.sh ab [--out DIR] [--profile FILE] [--rounds N] [--tabs N]
#
# llvm-check  prints the llvm-profdata of the pinned rustc (rustup component llvm-tools) and fails unless its
#             LLVM major is rustc's: rustc reads only profiles of its own LLVM (rustc book, "Profile-guided
#             Optimization"). --install adds the component first.
# generate    builds both parts with -Cprofile-generate into DIR/generate: cmux-tui, cmux-tui-host and
#             libcmux_app_ffi.{dylib,so} (the static library linked whole into a shared library for the scenario
#             driver). Each part writes its .profraw files into DIR/profraw/<part>, baked into the binary.
# run         the scenarios (rust_pgo_scenarios.py). cmux-app-ffi: every C ABI the app calls (the palette, the
#             focus rules and machine, motion, the sidebar mirror and reducer ops, the remote desktop core and the
#             remote tab client), then a check that each of them has counts. cmux-tui: a headless daemon serving
#             the app's requests (start, identify, new-tab, the list and layout reads, close-terminal, shutdown).
#             With --storm-tag, the CLI storm against a running app of that tag that bundles the instrumented
#             cmux-tui. A scenario that leaves no profile fails the run.
# merge       llvm-profdata merge per part into DIR/<part>.profdata, copied into the profile cache. --pin also
#             writes the part's pointer (below) and names where to upload the profile.
# rustflags   the RUSTFLAGS a Release build of the part adds: -Cprofile-use=<profile> when the part's pointer
#             names a profile for this target (default: the host) and rustc's LLVM major, and the profile with
#             that sha256 is in the cache or at its source. Otherwise nothing: no pointer silently (as before
#             this script), a pointer that cannot be used with a warning. --strict (the builds that publish)
#             fails when the pinned profile for this target and LLVM cannot be fetched, so a published binary
#             depends only on its tree. CMUX_RUST_PGO=off prints nothing. The builds that ask, per target:
#             scripts/cmux-next/build-app-ffi.sh (the app FFI xcframework), and for the daemon
#             scripts/ci/macos-cross.sh all and cmux-tui-build-package.yml (the published cmux-tui tree and commit
#             artifacts the app bundles) and nightly.yml's fast build.
# ab          the test phase: the regular cmux-tui of this checkout and one built the same way with the merged
#             profile (default DIR/cmux-tui.profdata, so no pointer or commit is needed) run the daemon scenario
#             in alternation; prints p50/p95 per request and the change.
#
# Pointers (key=value: sha256, llvm, rustc, target, commit), as Chrome's chrome/build/mac-arm.pgo.txt names one
# profile per revision. Each is inside its crate, so a new profile changes the inputs of what is built with it:
# the cmux-tui tree key (scripts/ci/cmux_tui_tree_key.py) and the app FFI pin (scripts/cmux-next/check-app-ffi-pin.sh).
# None is committed until a profile is pinned, so every build is as before:
#   cmux-tui      cmux-tui/crates/cmux-tui/pgo.txt
#   cmux-app-ffi  cmux-tui/crates/cmux-app-ffi/pgo.txt
# Profiles: ${CMUX_PGO_CACHE_DIR:-~/Library/Caches/cmux/pgo}/rust/<part>/<sha256>.profdata, fetched when missing
# from ${CMUX_RUST_PGO_SOURCE:-${CI_CACHE_R2_PUBLIC_URL:-https://ci-cache.cmux.com}/pgo}/<part>/<sha256>.profdata
# (a URL or a directory). DIR defaults to cmux-tui/target/rust-pgo.
#
# Cargo runs only on a build host (a fleet step, CI, nx-remote, or any machine that is not a Mac), never on a
# person's Mac:
#   cmux-ci run --class isolated --script "scripts/cmux-next/pgo/rust-pgo.sh generate" --ref SHA
# Every build passes an explicit --target, so RUSTFLAGS never reach build scripts or proc macros, and the generate
# and use builds of a part differ only in the profile flag.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "$script_dir/../../.." && pwd -P)"
tui_root="$repo_root/cmux-tui"
ffi_dir="$tui_root/crates/cmux-app-ffi"
scenarios="$script_dir/rust_pgo_scenarios.py"
rustc_bin="${RUSTC:-rustc}"

die() { echo "error: rust-pgo: $*" >&2; exit 1; }
warn() {
  if [[ "${GITHUB_ACTIONS:-}" == true ]]; then echo "::warning::rust-pgo: $*" >&2; else echo "warning: rust-pgo: $*" >&2; fi
}
usage() { sed -n '2,56p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}

require_build_host() {
  [[ "$(uname -s)" != Darwin || -n "${CMUX_CI_STEP_KEY:-}${CI:-}${GITHUB_ACTIONS:-}${CMUX_FLEET_BUILD_TAG:-}${NX_JOB_ID:-}" ]] \
    || die "this Mac never runs Cargo; run it as a fleet step: cmux-ci run --class isolated --script \"scripts/cmux-next/pgo/rust-pgo.sh $*\" --ref SHA"
}

pointer_of() {
  case "$1" in
    cmux-tui) printf '%s\n' "$tui_root/crates/cmux-tui/pgo.txt" ;;
    cmux-app-ffi) printf '%s\n' "$ffi_dir/pgo.txt" ;;
    *) die "unknown part '$1' (cmux-tui or cmux-app-ffi)" ;;
  esac
}

# field FILE KEY: the value of the last KEY= line, comments skipped.
field() { awk -F= -v k="$2" '/^[[:space:]]*#/ {next} $1==k {sub(/^[^=]*=/, ""); v=$0} END {printf "%s", v}' "$1"; }

# The pinned toolchain's rustc: run from cmux-tui so its rust-toolchain.toml applies.
rustc_vv() { (cd "$tui_root" && "$rustc_bin" -vV); }
rustc_field() { rustc_vv | awk -F': ' -v k="$1" '$1==k {print $2}'; }
rustc_llvm_major() { rustc_field "LLVM version" | cut -d. -f1; }
host_triple() { rustc_field host; }

cache_root() { printf '%s\n' "${CMUX_PGO_CACHE_DIR:-${HOME:?HOME is not set}/Library/Caches/cmux/pgo}/rust"; }
source_root() {
  local base="${CI_CACHE_R2_PUBLIC_URL:-https://ci-cache.cmux.com}"
  printf '%s\n' "${CMUX_RUST_PGO_SOURCE:-${base%/}/pgo}"
}

# profile_path PART SHA: the cached profile with that sha256, fetched from its source when missing. Prints the
# path, or says why on stderr and returns 1.
profile_path() {
  local part="$1" sha="$2" dir dest src tmp
  dir="$(cache_root)/$part"
  dest="$dir/$sha.profdata"
  if [[ -f "$dest" && "$(sha256_of "$dest")" == "$sha" ]]; then
    printf '%s\n' "$dest"
    return 0
  fi
  src="$(source_root)/$part/$sha.profdata"
  mkdir -p "$dir" 2>/dev/null || { echo "cannot create $dir" >&2; return 1; }
  tmp="$(mktemp "$dir/.$sha.XXXXXX")" || { echo "cannot write in $dir" >&2; return 1; }
  if [[ "$src" == *://* ]]; then
    curl --fail --silent --show-error --location --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 600 \
      -o "$tmp" "$src" || { rm -f "$tmp"; echo "could not download $src" >&2; return 1; }
  else
    cp -f "$src" "$tmp" 2>/dev/null || { rm -f "$tmp"; echo "no profile at $src" >&2; return 1; }
  fi
  if [[ "$(sha256_of "$tmp")" != "$sha" ]]; then
    rm -f "$tmp"
    echo "$src does not have sha256 $sha" >&2
    return 1
  fi
  mv -f "$tmp" "$dest"
  printf '%s\n' "$dest"
}

# Prints llvm-profdata when its LLVM major is rustc's; fails otherwise.
cmd_llvm_check() {
  local install=0 tool rustc_major tool_major
  [[ "${1:-}" == --install ]] && install=1
  tool="$(cd "$tui_root" && "$rustc_bin" --print sysroot)/lib/rustlib/$(host_triple)/bin/llvm-profdata"
  if [[ ! -x "$tool" && "$install" -eq 1 ]]; then
    (cd "$tui_root" && rustup component add llvm-tools >&2)
  fi
  [[ -x "$tool" ]] || die "no llvm-profdata in the pinned toolchain ($tool); run: (cd cmux-tui && rustup component add llvm-tools)"
  rustc_major="$(rustc_llvm_major)"
  tool_major="$("$tool" --version | sed -n 's/.*LLVM version \([0-9][0-9]*\).*/\1/p' | head -n 1)"
  [[ -n "$rustc_major" ]] || die "rustc -vV reports no LLVM version"
  [[ "$tool_major" == "$rustc_major" ]] || die "llvm-profdata is LLVM ${tool_major:-unknown}, rustc is LLVM $rustc_major"
  printf '%s\n' "$tool"
}

cmd_rustflags() {
  local part="${1:-}" target="" strict=0 pointer sha llvm profiled profile rustc_major
  [[ -n "$part" ]] || die "rustflags needs a part (cmux-tui or cmux-app-ffi)"
  shift
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --target) target="${2:?--target needs a triple}"; shift 2 ;;
      --strict) strict=1; shift ;;
      *) die "unknown argument: $1" ;;
    esac
  done
  pointer="$(pointer_of "$part")"
  [[ "${CMUX_RUST_PGO:-auto}" == off ]] && return 0
  [[ -f "$pointer" ]] || return 0
  sha="$(field "$pointer" sha256)"
  llvm="$(field "$pointer" llvm)"
  profiled="$(field "$pointer" target)"
  if [[ ! "$sha" =~ ^[0-9a-f]{64}$ ]]; then
    [[ "$strict" -eq 0 ]] || die "$pointer has no sha256"
    warn "$pointer has no sha256; building $part without PGO"
    return 0
  fi
  target="${target:-$(host_triple)}"
  # Chrome keeps one profile per target (mac-arm.pgo.txt, mac.pgo.txt): another target's code differs.
  if [[ "$target" != "$profiled" ]]; then
    echo "note: rust-pgo: the $part profile is for ${profiled:-no target}; building $target without PGO" >&2
    return 0
  fi
  # A toolchain bump leaves the profile unreadable until it is refreshed; the tree key covers both.
  rustc_major="$(rustc_llvm_major)"
  if [[ "$llvm" != "$rustc_major" ]]; then
    warn "the $part profile is from LLVM ${llvm:-unknown}, rustc is LLVM ${rustc_major:-unknown}; building without PGO (refresh the profile)"
    return 0
  fi
  if ! profile="$(profile_path "$part" "$sha")"; then
    [[ "$strict" -eq 0 ]] || die "the pinned $part profile $sha is not available; a published build never falls back"
    warn "the $part profile $sha is not available; building without PGO"
    return 0
  fi
  # RUSTFLAGS splits on whitespace.
  if [[ "$profile" == *[[:space:]]* ]]; then
    [[ "$strict" -eq 0 ]] || die "profile path '$profile' has whitespace"
    warn "profile path '$profile' has whitespace; building $part without PGO"
    return 0
  fi
  printf '%s\n' "-Cprofile-use=$profile"
}

out_dir() { printf '%s\n' "${CMUX_RUST_PGO_OUT:-$tui_root/target/rust-pgo}"; }

# parse_out ARGS...: sets $out from --out and leaves the other arguments in ${rest[@]}.
parse_out() {
  out="$(out_dir)"
  rest=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --out) out="${2:?--out needs a directory}"; shift 2 ;;
      *) rest+=("$1"); shift ;;
    esac
  done
  case "$out" in ""|/) die "--out must name a directory" ;; esac
  [[ "$out" != *[[:space:]]* ]] || die "--out must not contain whitespace (it becomes a rustc flag)"
}

build_commit() { git -C "$repo_root" rev-parse HEAD; }
ghostty_commit() {
  local vt=ghostty
  git -C "$repo_root" rev-parse --verify -q HEAD:ghostty-next >/dev/null && vt="ghostty-next"
  git -C "$repo_root/$vt" rev-parse HEAD 2>/dev/null || true
}

# cargo_tui TARGET_DIR RUSTFLAGS TRIPLE: the daemon and its terminal host, as build-cmux-tui-client.sh builds
# them, with an explicit --target.
cargo_tui() {
  local commit ghostty
  commit="$(build_commit)"
  ghostty="$(ghostty_commit)"
  (cd "$tui_root" && CMUX_TUI_BUILD_COMMIT="$commit" CMUX_TUI_GHOSTTY_COMMIT="$ghostty" \
    CARGO_TARGET_DIR="$1" RUSTFLAGS="$2" \
    cargo build -p cmux-tui --bin cmux-tui --bin cmux-tui-host --release --locked --target "$3" >&2)
}

cmd_generate() {
  local triple gen ffi_target native lib
  parse_out "$@"
  [[ ${#rest[@]} -eq 0 ]] || die "unknown argument: ${rest[0]}"
  require_build_host generate
  cmd_llvm_check --install >/dev/null
  command -v cargo >/dev/null 2>&1 || die "cargo is required"
  triple="$(host_triple)"
  gen="$out/generate"
  rm -rf "$out/profraw" "$gen"
  mkdir -p "$out/profraw/cmux-tui" "$out/profraw/cmux-app-ffi" "$gen"

  echo "==> instrumented cmux-tui ($triple)" >&2
  cargo_tui "$out/target-generate" "-Cprofile-generate=$out/profraw/cmux-tui" "$triple"
  install -m 755 "$out/target-generate/$triple/release/cmux-tui" "$gen/cmux-tui"
  install -m 755 "$out/target-generate/$triple/release/cmux-tui-host" "$gen/cmux-tui-host"

  # build-app-ffi.sh's settings (machine code only, no LTO, macOS 14), plus the libraries rustc names for the
  # shared library's link line.
  echo "==> instrumented cmux-app-ffi ($triple)" >&2
  ffi_target="$out/target-generate-ffi"
  native="$(cd "$ffi_dir" && CARGO_TARGET_DIR="$ffi_target" CARGO_PROFILE_RELEASE_LTO=off MACOSX_DEPLOYMENT_TARGET=14.0 \
    RUSTFLAGS="-C embed-bitcode=no -Cprofile-generate=$out/profraw/cmux-app-ffi" \
    cargo rustc --locked --release --target "$triple" -- --print native-static-libs 2>&1 | tee /dev/stderr \
    | sed -n 's/.*native-static-libs: //p' | tail -n 1)"
  lib="$ffi_target/$triple/release/libcmux_app_ffi.a"
  [[ -f "$lib" ]] || die "cargo built no $lib"
  # shellcheck disable=SC2086 # native is rustc's list of linker arguments
  if [[ "$(uname -s)" == Darwin ]]; then
    cc -dynamiclib -o "$gen/libcmux_app_ffi.dylib" -Wl,-force_load,"$lib" $native
  else
    cc -shared -o "$gen/libcmux_app_ffi.so" -Wl,--whole-archive "$lib" -Wl,--no-whole-archive $native
  fi
  {
    echo "commit=$(build_commit)"
    echo "rustc=$(rustc_field release)"
    echo "llvm=$(rustc_llvm_major)"
    echo "target=$triple"
  } > "$gen/build.txt"
  echo "instrumented build: $gen" >&2
}

# scenario PART NAME COMMAND...: runs it and fails unless a PART profile was written after it started (the
# instrumented binaries merge into one file per binary, so the count of files does not grow).
scenario() {
  local part="$1" name="$2" marker
  shift 2
  marker="$(mktemp "$out/.scenario.XXXXXX")"
  echo "==> scenario $name" >&2
  "$@" >&2 || { rm -f "$marker"; die "scenario $name failed"; }
  if [[ -z "$(find "$out/profraw/$part" -name '*.profraw' -type f -size +0 -newer "$marker" 2>/dev/null | head -n 1)" ]]; then
    rm -f "$marker"
    die "scenario $name wrote no $part profile: its process did not exit through exit(3)"
  fi
  rm -f "$marker"
}

# merge_part TOOL PART OUTPUT: every non-empty .profraw of the part into one indexed profile.
merge_part() {
  [[ -n "$(find "$out/profraw/$2" -name '*.profraw' -type f -size +0 2>/dev/null | head -n 1)" ]] \
    || die "no $2 profiles in $out/profraw/$2; run rust-pgo.sh run first"
  find "$out/profraw/$2" -name '*.profraw' -type f -size +0 -print0 | sort -z | xargs -0 "$1" merge -o "$3"
}

cmd_run() {
  local rounds=20 tabs=8 storm_tag="" gen lib tool
  parse_out "$@"
  set -- ${rest[@]+"${rest[@]}"}
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --rounds) rounds="${2:?--rounds needs a number}"; shift 2 ;;
      --tabs) tabs="${2:?--tabs needs a number}"; shift 2 ;;
      --storm-tag) storm_tag="${2:?--storm-tag needs a tag}"; shift 2 ;;
      *) die "unknown argument: $1" ;;
    esac
  done
  gen="$out/generate"
  [[ -x "$gen/cmux-tui" ]] || die "no instrumented build in $gen; run rust-pgo.sh generate first"
  tool="$(cmd_llvm_check)"
  # The baked -Cprofile-generate directories hold every profile.
  unset LLVM_PROFILE_FILE
  lib="$gen/libcmux_app_ffi.dylib"
  [[ -f "$lib" ]] || lib="$gen/libcmux_app_ffi.so"
  scenario cmux-app-ffi ffi python3 "$scenarios" ffi --lib "$lib" --repo "$repo_root" --rounds "$rounds"
  # A C ABI the app calls but no scenario reached has zero counts, and -Cprofile-use compiles it as cold code.
  merge_part "$tool" cmux-app-ffi "$out/.ffi-coverage.profdata"
  python3 "$scenarios" coverage --lib "$lib" --repo "$repo_root" --profdata "$out/.ffi-coverage.profdata" \
    --tool "$tool" >&2 || die "the FFI scenarios leave a C ABI the app calls without counts (see above)"
  rm -f "$out/.ffi-coverage.profdata"
  scenario cmux-tui daemon python3 "$scenarios" daemon --binary "$gen/cmux-tui" --rounds "$rounds" --tabs "$tabs"
  if [[ -n "$storm_tag" ]]; then
    scenario cmux-tui "cli storm" "$repo_root/scripts/cmux-next/bench-cli-storm.sh" "$storm_tag" \
      --no-fail --label rust-pgo --out "$out/storm"
  fi
}

cmd_merge() {
  local pin=0 tool part merged sha cache target commit arg
  parse_out "$@"
  for arg in ${rest[@]+"${rest[@]}"}; do
    case "$arg" in
      --pin) pin=1 ;;
      *) die "unknown argument: $arg" ;;
    esac
  done
  tool="$(cmd_llvm_check)"
  [[ -f "$out/generate/build.txt" ]] || die "no $out/generate/build.txt; run rust-pgo.sh generate first"
  target="$(field "$out/generate/build.txt" target)"
  commit="$(field "$out/generate/build.txt" commit)"
  [[ "$(field "$out/generate/build.txt" llvm)" == "$(rustc_llvm_major)" ]] \
    || die "the instrumented build is from another LLVM than this rustc; generate again"
  for part in cmux-tui cmux-app-ffi; do
    merged="$out/$part.profdata"
    merge_part "$tool" "$part" "$merged"
    sha="$(sha256_of "$merged")"
    cache="$(cache_root)/$part"
    mkdir -p "$cache"
    cp -f "$merged" "$cache/$sha.profdata"
    echo "$part $sha $merged" >&2
    if [[ "$pin" -eq 1 ]]; then
      {
        echo "# The $part PGO profile (scripts/cmux-next/pgo/rust-pgo.sh merge --pin). Its file is"
        echo "# <source>/$part/<sha256>.profdata; rust-pgo.sh rustflags gives -Cprofile-use only for this target and LLVM."
        echo "sha256=$sha"
        echo "llvm=$(rustc_llvm_major)"
        echo "rustc=$(rustc_field release)"
        echo "target=$target"
        echo "commit=$commit"
      } > "$(pointer_of "$part")"
      echo "pinned $part: $(pointer_of "$part"); upload $merged to $(source_root)/$part/$sha.profdata" >&2
    fi
  done
}

cmd_ab() {
  local rounds=15 tabs=8 profile="" triple base pgo
  parse_out "$@"
  set -- ${rest[@]+"${rest[@]}"}
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --profile) profile="${2:?--profile needs a file}"; shift 2 ;;
      --rounds) rounds="${2:?--rounds needs a number}"; shift 2 ;;
      --tabs) tabs="${2:?--tabs needs a number}"; shift 2 ;;
      *) die "unknown argument: $1" ;;
    esac
  done
  profile="${profile:-$out/cmux-tui.profdata}"
  [[ -f "$profile" ]] || die "no cmux-tui profile at $profile; run rust-pgo.sh merge first (or pass --profile)"
  [[ "$profile" != *[[:space:]]* ]] || die "--profile must not contain whitespace (it becomes a rustc flag)"
  require_build_host ab
  triple="$(host_triple)"
  if [[ -f "$out/generate/build.txt" && "$(field "$out/generate/build.txt" llvm)" != "$(rustc_llvm_major)" ]]; then
    die "the profile is from another LLVM than this rustc; generate again"
  fi
  # Both builds of this checkout, the same cargo invocation; only the profile flag differs.
  echo "==> regular cmux-tui ($triple)" >&2
  cargo_tui "$out/target-base" "" "$triple"
  echo "==> cmux-tui with -Cprofile-use=$profile ($triple)" >&2
  cargo_tui "$out/target-pgo" "-Cprofile-use=$profile" "$triple"
  base="$out/target-base/$triple/release/cmux-tui"
  pgo="$out/target-pgo/$triple/release/cmux-tui"
  python3 "$scenarios" ab --base "$base" --pgo "$pgo" --rounds "$rounds" --tabs "$tabs"
}

command="${1:-}"
[[ $# -gt 0 ]] && shift
case "$command" in
  llvm-check) cmd_llvm_check "$@" ;;
  generate) cmd_generate "$@" ;;
  run) cmd_run "$@" ;;
  merge) cmd_merge "$@" ;;
  rustflags) cmd_rustflags "$@" ;;
  ab) cmd_ab "$@" ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
