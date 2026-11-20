#!/usr/bin/env bash
# CMUX-570 (goal bundle-size-falls): bytes of bin/cmux (cmux-tui) for aarch64-apple-darwin, cross-built on Linux as
# scripts/ci/macos-cross.sh does, under one opt-level variant. Fleet only:
#   cmux-ci test --timeout 7200 -- bash scripts/measure/optlevel-size.sh VARIANT
# VARIANT: A (as shipped), B (s except hot), C (z except hot), D (s everywhere), E (z everywhere).
# cmux-tui's own manifest override (opt-level "z") stays in every variant. The variants are cargo --config
# profile settings, which take precedence over the manifest's [profile.release] (not its package overrides).
# Falls back to x86_64-unknown-linux-gnu when the cross toolchain cannot be set up (OPT-TARGET says which).
# Lines: OPT-TARGET, OPT-BUILD <s>, OPT-SIZE <variant> <raw|strip-x|strip-all> <bytes>, OPT-SEG (llvm-size -m).
set -uo pipefail
variant="${1:?variant A-E}"
root="$(git rev-parse --show-toplevel)"
[[ "$(uname -s)" == Linux ]] || { echo "optlevel-size.sh runs only on Linux" >&2; exit 2; }
[ -n "${FAST_CHECKS_OUT:-}" ] && exec > >(tee -a "$FAST_CHECKS_OUT/optlevel-$variant.log") 2>&1
# Hot path: cmux-tui-core (render/diff), ghostty vt, tokio, and what the dev profile comment says does the render
# heavy lifting (ratatui/crossterm) plus cmux-api-compat ("sits on every translated daemon message").
hot=(cmux-tui-core ghostty-vt ghostty-vt-sys tokio ratatui ratatui-core crossterm cmux-api-compat)
cfg=()
case "$variant" in
  A) ;;
  B|C) lvl=s; [[ $variant == C ]] && lvl=z
       cfg+=(--config "profile.release.opt-level=\"$lvl\"")
       for c in "${hot[@]}"; do cfg+=(--config "profile.release.package.$c.opt-level=3"); done ;;
  D) cfg+=(--config 'profile.release.opt-level="s"') ;;
  E) cfg+=(--config 'profile.release.opt-level="z"') ;;
  *) echo "unknown variant $variant" >&2; exit 2 ;;
esac
echo "OPT-VARIANT $variant hot=${hot[*]} cfg=${cfg[*]:-none}"

command -v cargo >/dev/null || (cd "$root" && ./scripts/install-rust-ci.sh)
export PATH="$HOME/.cargo/bin:$PATH"
if ! command -v zig >/dev/null; then
  if [ -z "${CMUX_ZIG:-}" ]; then
    zig_env="$(mktemp)"
    (cd "$root" && [ -f ghostty-next/build.zig.zon ] || git submodule update --init --depth 1 ghostty-next)
    (cd "$root" && GHOSTTY_ZIG_SOURCE=ghostty-next GITHUB_ENV="$zig_env" GITHUB_PATH=/dev/null ./scripts/install-zig-ci.sh)
    zig_line="$(grep '^CMUX_ZIG=' "$zig_env" | tail -n 1 || true)"
    [ -z "$zig_line" ] || export "$zig_line"
  fi
  [ -n "${CMUX_ZIG:-}" ] && export PATH="$(dirname "$CMUX_ZIG"):$PATH"
fi
[ -f "$root/ghostty-next/build.zig" ] || git -C "$root" submodule update -q --init --depth 1 ghostty-next || exit 1
command -v clang >/dev/null || { sudo apt-get update -qq && sudo apt-get install -y -qq clang libclang-dev pkg-config; }
zig version; cargo --version

scratch="$(mktemp -d)"
export CARGO_TARGET_DIR="$scratch/target"
target=aarch64-apple-darwin
cross_ok=1
bash "$root/scripts/ci/apt-ensure.sh" clang-19 lld-19 llvm-19 || cross_ok=0
. "$root/scripts/lib/rust-targets.sh"
(cd "$root/cmux-tui" && ensure_rust_targets aarch64-apple-darwin) || cross_ok=0
if ((cross_ok)); then
  # macos-cross.sh's functions without its dispatch (use_target, write_wrapper, the toolchain).
  lib="$scratch/xc-lib.sh"
  sed '/^command=\${1:-}; shift || true$/,$d' "$root/scripts/ci/macos-cross.sh" > "$lib"
  export XC_ROOT="$scratch/xc" XC_TARGETS=$target
  # shellcheck disable=SC1090
  source "$lib"
  repo_root="$root"; STUBS_DIR="$root/scripts/ci/macos-stubs"
  set +e
  (cmd_toolchain 26.5) || cross_ok=0
  ((cross_ok)) && { use_target "$target" "${MIN_OS[$target]}" || cross_ok=0; }
fi
((cross_ok)) || { target=x86_64-unknown-linux-gnu; echo "OPT-NOTE cross toolchain unavailable; x86_64 Linux proxy"; }
echo "OPT-TARGET $target"
strip_bin=$(command -v llvm-strip-19 || command -v llvm-strip || echo strip)
size_bin=$(command -v llvm-size-19 || command -v llvm-size || echo size)
unset CMUX_GHOSTTY_SRC
t0=$(date +%s)
(cd "$root/cmux-tui" && CMUX_TUI_BUILD_COMMIT="$(git rev-parse HEAD)" \
  CMUX_TUI_GHOSTTY_COMMIT="$(git -C ../ghostty-next rev-parse HEAD)" CMUX_TUI_DISTRIBUTION_VERSION=0.0.0-optlevel \
  cargo "${cfg[@]}" build -p cmux-tui --bin cmux-tui --release --locked --target "$target" 2>&1 | tail -n 15)
rc=${PIPESTATUS[0]}
echo "OPT-BUILD $variant $(( $(date +%s) - t0 )) s"
bin="$CARGO_TARGET_DIR/$target/release/cmux-tui"
[[ -f "$bin" ]] || { echo "OPT-ERROR no binary (rc=$rc)"; exit 1; }
echo "OPT-SIZE $variant $target raw $(stat -c %s "$bin")"
"$size_bin" -m "$bin" 2>/dev/null | grep -E '^Segment|Section (__text|__const|__unwind_info|__eh_frame|__gcc_except_tab|__cstring)' | sed "s/^/OPT-SEG $variant /"
cp "$bin" "$scratch/x"; "$strip_bin" -x "$scratch/x" && echo "OPT-SIZE $variant $target strip-x $(stat -c %s "$scratch/x")"
cp "$bin" "$scratch/u"; "$strip_bin" "$scratch/u" && echo "OPT-SIZE $variant $target strip-all $(stat -c %s "$scratch/u")"
[ -n "${FAST_CHECKS_OUT:-}" ] && xz -T0 -c "$scratch/x" > "$FAST_CHECKS_OUT/cmux-$variant-$target.xz" \
  && echo "OPT-SIZE $variant $target strip-x-xz $(stat -c %s "$FAST_CHECKS_OUT/cmux-$variant-$target.xz")"
if [[ "$variant" == A && "${OPT_BLOAT:-1}" == 1 ]]; then
  cargo install --locked cargo-bloat >/dev/null 2>&1 || cargo install cargo-bloat >/dev/null 2>&1
  (cd "$root/cmux-tui" && CMUX_TUI_BUILD_COMMIT="$(git rev-parse HEAD)" \
    CMUX_TUI_GHOSTTY_COMMIT="$(git -C ../ghostty-next rev-parse HEAD)" CMUX_TUI_DISTRIBUTION_VERSION=0.0.0-optlevel \
    cargo bloat --release --locked --target "$target" -p cmux-tui --bin cmux-tui --crates -n 40 2>&1 | tail -n 50 | sed 's/^/OPT-BLOAT /')
fi
rm -rf "$scratch"
exit 0
