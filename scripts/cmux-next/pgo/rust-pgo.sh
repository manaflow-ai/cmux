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
#   rust-pgo.sh rustflags cmux-tui|cmux-app-ffi [--target TRIPLE]
#   rust-pgo.sh build-use [--print-path]
#   rust-pgo.sh bundle-source
#   rust-pgo.sh ab [--out DIR] [--rounds N] [--tabs N]
#
# llvm-check  prints the llvm-profdata of the pinned rustc (rustup component llvm-tools) and fails unless its
#             LLVM major is rustc's: rustc reads only profiles of its own LLVM (rustc book, "Profile-guided
#             Optimization"). --install adds the component first.
# generate    builds both parts with -Cprofile-generate into DIR/generate: cmux-tui, cmux-tui-host and
#             libcmux_app_ffi.{dylib,so} (the static library linked whole into a shared library for the scenario
#             driver). Each part writes its .profraw files into DIR/profraw/<part>, baked into the binary.
# run         the scenarios (rust_pgo_scenarios.py). cmux-app-ffi: the palette ranker corpus, the focus rule corpus
#             and the per-frame motion steps through the C ABI. cmux-tui: a headless daemon serving the app's
#             requests (start, identify, new-tab, the list and layout reads, close-terminal, shutdown). With
#             --storm-tag, the CLI storm against a running app of that tag that bundles the instrumented
#             cmux-tui. A scenario that leaves no profile fails the run.
# merge       llvm-profdata merge per part into DIR/<part>.profdata, copied into the profile cache. --pin also
#             writes the part's pointer (below) and names where to upload the profile.
# rustflags   the RUSTFLAGS a Release build of the part adds: -Cprofile-use=<profile> when the part's pointer
#             names a profile for this target (default: the host) and rustc's LLVM major, and the profile with
#             that sha256 is in the cache or at its source. Otherwise nothing: no pointer silently (as before
#             this script), a pointer that cannot be used with a warning. CMUX_RUST_PGO=off prints nothing.
#             scripts/cmux-next/build-app-ffi.sh asks it for each target slice.
# build-use   builds cmux-tui and cmux-tui-host with that flag into
#             cmux-tui/target/rust-pgo-use/<tree key>-<profile sha256 12>/, next to the other companions of the
#             same tree (build-cmux-tui-client.sh). Fails without a usable profile or with uncommitted cmux-tui
#             changes.
# bundle-source  prints that build's cmux-tui when it exists for this checkout's tree key, the pinned profile and
#             this Mac's architecture, else nothing. The Release "Bundle cmux-tui" phase of cmux.xcodeproj bundles
#             it through CMUX_NEXT_TUI_BIN; Debug never asks. It never runs cargo or rustc.
# ab          the test phase: the regular and the PGO cmux-tui of this tree, built the same way, run the daemon
#             scenario in alternation; prints p50/p95 per request and the change.
#
# Pointers (key=value: sha256, llvm, rustc, target, commit), as Chrome's chrome/build/mac-arm.pgo.txt names one
# profile per revision. None is committed until a profile is pinned, so every build is as before:
#   cmux-tui      scripts/cmux-next/pgo/cmux-tui.pgo.txt
#   cmux-app-ffi  cmux-tui/crates/cmux-app-ffi/pgo.txt (inside the crate: a new profile is an input of the app FFI
#                 pin, scripts/cmux-next/check-app-ffi-pin.sh, so the next FFI release is built with it)
# Profiles: ${CMUX_PGO_CACHE_DIR:-~/Library/Caches/cmux/pgo}/rust/<part>/<sha256>.profdata, fetched when missing
# from ${CMUX_RUST_PGO_SOURCE:-${CI_CACHE_R2_PUBLIC_URL:-https://ci-cache.cmux.com}/pgo}/<part>/<sha256>.profdata
# (a URL or a directory). DIR defaults to cmux-tui/target/rust-pgo.
#
# Cargo runs only on a build host (a fleet step, CI, nx-remote, or any machine that is not a Mac), never on a
# person's Mac:
#   cmux-ci run --class isolated --script "scripts/cmux-next/pgo/rust-pgo.sh generate" --ref SHA
# Both builds pass an explicit --target, so RUSTFLAGS never reach build scripts or proc macros, and the generate
# and use builds of a part differ only in the profile flag.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "$script_dir/../../.." && pwd -P)"
tui_root="$repo_root/cmux-tui"
ffi_dir="$tui_root/crates/cmux-app-ffi"
scenarios="$script_dir/rust_pgo_scenarios.py"
pin_script="$repo_root/scripts/cmux-next/pin-cmux-tui.sh"
client_script="$repo_root/scripts/cmux-next/build-cmux-tui-client.sh"
rustc_bin="${RUSTC:-rustc}"

die() { echo "error: rust-pgo: $*" >&2; exit 1; }
warn() {
  if [[ "${GITHUB_ACTIONS:-}" == true ]]; then echo "::warning::rust-pgo: $*" >&2; else echo "warning: rust-pgo: $*" >&2; fi
}
usage() { sed -n '2,52p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

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
    cmux-tui) printf '%s\n' "$repo_root/scripts/cmux-next/pgo/cmux-tui.pgo.txt" ;;
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
  local part="${1:-}" target="" pointer sha llvm profiled profile rustc_major
  [[ -n "$part" ]] || die "rustflags needs a part (cmux-tui or cmux-app-ffi)"
  shift
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --target) target="${2:?--target needs a triple}"; shift 2 ;;
      *) die "unknown argument: $1" ;;
    esac
  done
  pointer="$(pointer_of "$part")"
  [[ "${CMUX_RUST_PGO:-auto}" == off ]] && return 0
  [[ -f "$pointer" ]] || return 0
  sha="$(field "$pointer" sha256)"
  llvm="$(field "$pointer" llvm)"
  profiled="$(field "$pointer" target)"
  [[ "$sha" =~ ^[0-9a-f]{64}$ ]] || { warn "$pointer has no sha256; building $part without PGO"; return 0; }
  target="${target:-$(host_triple)}"
  # Chrome keeps one profile per target (mac-arm.pgo.txt, mac.pgo.txt): another target's code differs.
  if [[ "$target" != "$profiled" ]]; then
    echo "note: rust-pgo: the $part profile is for ${profiled:-no target}; building $target without PGO" >&2
    return 0
  fi
  rustc_major="$(rustc_llvm_major)"
  if [[ "$llvm" != "$rustc_major" ]]; then
    warn "the $part profile is from LLVM ${llvm:-unknown}, rustc is LLVM ${rustc_major:-unknown}; building without PGO (refresh the profile)"
    return 0
  fi
  if ! profile="$(profile_path "$part" "$sha")"; then
    warn "the $part profile $sha is not available; building without PGO"
    return 0
  fi
  # RUSTFLAGS splits on whitespace.
  [[ "$profile" != *[[:space:]]* ]] || { warn "profile path '$profile' has whitespace; building $part without PGO"; return 0; }
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
  git -C "$repo_root" rev-parse --verify -q HEAD:ghostty-next >/dev/null && vt=ghostty-next
  git -C "$repo_root/$vt" rev-parse HEAD 2>/dev/null || true
}

# cargo_tui TARGET_DIR RUSTFLAGS TRIPLE: the daemon and its terminal host, as build-cmux-tui-client.sh builds
# them, with an explicit --target.
cargo_tui() {
  (cd "$tui_root" && CMUX_TUI_BUILD_COMMIT="$(build_commit)" CMUX_TUI_GHOSTTY_COMMIT="$(ghostty_commit)" \
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

cmd_run() {
  local rounds=20 tabs=8 storm_tag="" gen lib
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
  # The baked -Cprofile-generate directories hold every profile.
  unset LLVM_PROFILE_FILE
  lib="$gen/libcmux_app_ffi.dylib"
  [[ -f "$lib" ]] || lib="$gen/libcmux_app_ffi.so"
  scenario cmux-app-ffi ffi python3 "$scenarios" ffi --lib "$lib" --repo "$repo_root" --rounds "$rounds"
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
    [[ -n "$(find "$out/profraw/$part" -name '*.profraw' -type f -size +0 2>/dev/null | head -n 1)" ]] \
      || die "no $part profiles in $out/profraw/$part; run rust-pgo.sh run first"
    merged="$out/$part.profdata"
    find "$out/profraw/$part" -name '*.profraw' -type f -size +0 -print0 | sort -z | xargs -0 "$tool" merge -o "$merged"
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

# The use build of this tree and the pinned cmux-tui profile.
use_dir() {
  local sha
  sha="$(field "$(pointer_of cmux-tui)" sha256)"
  printf '%s\n' "$tui_root/target/rust-pgo-use/$("$pin_script" key)-${sha:0:12}"
}

tree_dirty() {
  [[ -n "$(git -C "$repo_root" status --porcelain --untracked-files=normal -- cmux-tui first-party-apps/cloud/server ghostty-next 2>/dev/null \
    | grep -v ' cmux-tui/target/' || true)" ]]
}

cmd_build_use() {
  local print_path=0 flags triple dir stage companions name built target_dir
  [[ "${1:-}" == --print-path ]] && print_path=1
  require_build_host build-use
  [[ -f "$(pointer_of cmux-tui)" ]] || die "no cmux-tui profile is pinned ($(pointer_of cmux-tui))"
  tree_dirty && die "cmux-tui has uncommitted changes; a PGO build is keyed by the committed tree"
  triple="$(host_triple)"
  flags="$(cmd_rustflags cmux-tui --target "$triple")"
  [[ -n "$flags" ]] || die "the pinned cmux-tui profile cannot be used here (see above)"
  dir="$(use_dir)"
  if [[ -f "$dir/complete" && -x "$dir/cmux-tui" ]]; then
    echo "PGO cmux-tui already built: $dir" >&2
  else
    companions="$(dirname "$("$client_script" --print-path)")"
    target_dir="${CMUX_RUST_PGO_USE_TARGET_DIR:-$tui_root/target/rust-pgo-use-target}"
    echo "==> cmux-tui with $flags ($triple)" >&2
    cargo_tui "$target_dir" "$flags" "$triple"
    built="$target_dir/$triple/release"
    stage="$(mktemp -d "$tui_root/target/.rust-pgo-use.XXXXXX")"
    chmod 755 "$stage"
    install -m 755 "$built/cmux-tui" "$stage/cmux-tui"
    install -m 755 "$built/cmux-tui-host" "$stage/cmux-tui-host"
    for name in cmux-app-host cmux-cloud cmux-browser-host cmux-holder cmux-agent-screen-detection; do
      [[ -f "$companions/$name" ]] && install -m 755 "$companions/$name" "$stage/$name"
    done
    printf 'profile=%s\nkey=%s\ntarget=%s\n' "$(field "$(pointer_of cmux-tui)" sha256)" "$("$pin_script" key)" "$triple" \
      > "$stage/complete"
    rm -rf "$dir"
    mkdir -p "$(dirname "$dir")"
    mv "$stage" "$dir"
    echo "built PGO cmux-tui: $dir" >&2
  fi
  [[ "$print_path" -eq 0 ]] || printf '%s\n' "$dir/cmux-tui"
}

cmd_bundle_source() {
  local dir arch
  [[ "${CMUX_RUST_PGO:-auto}" == off ]] && return 0
  [[ -f "$(pointer_of cmux-tui)" ]] || return 0
  dir="$(use_dir)"
  if [[ ! -f "$dir/complete" || ! -x "$dir/cmux-tui" ]]; then
    warn "no PGO cmux-tui for this tree and profile ($dir); bundling the regular one. Build it on a build host: scripts/cmux-next/pgo/rust-pgo.sh build-use"
    return 0
  fi
  arch="${NATIVE_ARCH_ACTUAL:-$(uname -m)}"
  [[ "$arch" == arm64 ]] && arch=aarch64
  if [[ "$(field "$dir/complete" target)" != "$arch"-* ]]; then
    warn "the PGO cmux-tui is for $(field "$dir/complete" target), not $arch; bundling the regular one"
    return 0
  fi
  if tree_dirty; then
    warn "cmux-tui has uncommitted changes; bundling the regular cmux-tui, not the PGO build of the committed tree"
    return 0
  fi
  printf '%s\n' "$dir/cmux-tui"
}

cmd_ab() {
  local rounds=15 tabs=8 triple base pgo
  parse_out "$@"
  set -- ${rest[@]+"${rest[@]}"}
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --rounds) rounds="${2:?--rounds needs a number}"; shift 2 ;;
      --tabs) tabs="${2:?--tabs needs a number}"; shift 2 ;;
      *) die "unknown argument: $1" ;;
    esac
  done
  require_build_host ab
  pgo="$(cmd_build_use --print-path)"
  triple="$(host_triple)"
  echo "==> regular cmux-tui ($triple), built the same way without the profile" >&2
  cargo_tui "$out/target-base" "" "$triple"
  base="$out/target-base/$triple/release/cmux-tui"
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
  build-use) cmd_build_use "$@" ;;
  bundle-source) cmd_bundle_source "$@" ;;
  ab) cmd_ab "$@" ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
